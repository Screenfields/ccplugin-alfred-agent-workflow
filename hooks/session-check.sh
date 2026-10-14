#!/usr/bin/env bash
# SessionStart hook: after any (re)start of a lead or hub session, make sure
# its wake watcher runs and its inbox is read.
#
# A watcher is a background task of the session that ran it, so it dies with
# that session: /exit + `claude -c`, a crash, or a pod restart all leave the
# new session deaf until a turn relaunches it. Seen live on 2026-10-14: the
# hub's bridge was down 09:49-11:11 CEST after a session restart, until the
# owner typed. This hook:
#   1. checks the watcher (`alfred-wake status`, or ALFRED_WATCHER_STATUS_CMD,
#      e.g. hub-wake-bridge on the hub) and the agent-messaging unread count;
#   2. adds both to the session context, with "relaunch the watcher, read the
#      inbox, report in one line" when the watcher is down or mail is waiting;
#   3. when the watcher is down after a startup/resume in tmux, starts a
#      one-shot helper (session-nudge.sh) that types a fixed prompt into this
#      session's pane once the session is idle. SessionStart context alone
#      acts only on a first turn, and a session nobody types into never has
#      one. The helper gives up as soon as the watcher runs (for example
#      because a start prompt or the owner already got it going).
#
# Deterministic: one pid check and one agent-messaging request, only when a
# session starts. Nothing here polls, and a dormant lead has no session start,
# so it never wakes because of this. Only in projects with .alfred/config.json
# (an agent_id). ALFRED_SESSION_CHECK=0 switches the hook off;
# ALFRED_SESSION_NUDGE=0 keeps the context but never types into the pane.
set -u

input=$(cat)
[ "${ALFRED_SESSION_CHECK:-1}" = "0" ] && exit 0

field() { printf '%s' "$input" | jq -r ".$1 // empty" 2>/dev/null; }
source=$(field source)
cwd=$(field cwd)
[ -n "$cwd" ] || cwd="$PWD"
jq -e '.agent_id // empty' "$cwd/.alfred/config.json" >/dev/null 2>&1 || exit 0

here=$(cd "$(dirname "$0")" && pwd)
wake="${ALFRED_WAKE_CHECK_BIN:-$here/../bin/alfred-wake}"
status_cmd="${ALFRED_WATCHER_STATUS_CMD:-$wake status}"
start_cmd="${ALFRED_WATCHER_START_CMD:-alfred-wake wait}"

armed=no
# shellcheck disable=SC2086  # the status command is a configured command line
if timeout 10 $status_cmd >/dev/null 2>&1; then armed=yes; fi
unread=$(timeout 15 "$wake" unread 2>/dev/null) || unread="?"
[ -n "$unread" ] || unread="?"

if [ "$armed" = yes ] && [ "$unread" = 0 ]; then
  ctx="Wake watcher: running. Inbox: 0 unread. Nothing to do for this check; do not mention it."
else
  if [ "$armed" = yes ]; then w="running"; else w="NOT running"; fi
  ctx="Session ${source:-start} check: the wake watcher is $w and the inbox has $unread unread.
Do this now, before anything else:"
  n=1
  if [ "$armed" = no ]; then
    ctx="$ctx
$n. Relaunch the watcher as a background task: Bash(command: \"$start_cmd\", run_in_background: true)."
    n=$((n + 1))
  fi
  ctx="$ctx
$n. Run /alfred-agent:check-messages and handle what is there.
$((n + 1)). Report the watcher and inbox state to the owner in one line."
fi

if [ "$armed" = no ] && [ -n "${TMUX_PANE:-}" ] && [ "${ALFRED_SESSION_NUDGE:-1}" != "0" ]; then
  case "$source" in
    startup|resume)
      setsid nohup "$here/session-nudge.sh" "$TMUX_PANE" "$status_cmd" "$start_cmd" \
        >/dev/null 2>&1 < /dev/null &
      ;;
  esac
fi

jq -n --arg ctx "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
