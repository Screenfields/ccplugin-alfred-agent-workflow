#!/usr/bin/env bash
# SessionStart hook: after any (re)start of a lead or hub session, make sure
# its wake watcher runs and its inbox is read.
#
# A watcher is a background task of the session that ran it, so it dies with
# that session: /exit + `claude -c`, a crash, or a pod restart all leave the
# new session deaf until a turn relaunches it. Seen live on 2026-10-14: the
# hub's bridge was down 09:49-11:11 CEST after a session restart, until the
# owner typed. This hook:
#   1. checks the watcher (`alfred-wake status`, or the status_cmd of the
#      `watcher` object in the checkout's own .alfred/config.json, e.g.
#      hub-wake-bridge on the hub) and the agent-messaging unread count;
#   2. adds both to the session context, with "relaunch the watcher, read the
#      inbox, report in one line" when the watcher is down or mail is waiting;
#   3. when the watcher is down after a startup/resume in tmux, starts a
#      one-shot helper (session-nudge.sh) that types a fixed prompt into this
#      session's pane once the session is idle, nobody is attached and the
#      prompt is empty (never on clear or compact). SessionStart context alone
#      acts only on a first turn, and a session nobody types into never has
#      one. The helper gives up as soon as the watcher runs (for example
#      because a start prompt or the owner already got it going).
#
# Deterministic: one pid check and one agent-messaging request, only when a
# session starts. Nothing here polls, and a dormant lead has no session start,
# so it never wakes because of this. Only in projects with .alfred/config.json
# (an agent_id). ALFRED_SESSION_CHECK=0 switches the hook off;
# ALFRED_SESSION_NUDGE=0 keeps the context but never types into the pane.
#
# Watcher override (CCW-201): the status and start commands come only from
# .alfred/config.json in the `cwd` of the hook input:
#   "watcher": {"status_cmd": "<shell line>", "start_cmd": "<shell line>"}
# Absent or null: the defaults (`alfred-wake status`, `alfred-wake wait`). Not
# usable (not an object, a key missing, not a string, empty, whitespace only or
# with a control character): both defaults, plus one stderr line. The old
# environment variables are ignored (never read): ALFRED_WATCHER_STATUS_CMD is
# ignored, and so is ALFRED_WATCHER_START_CMD. An environment is shared by
# agents on one host and one checkout, and it carried the hub's pair into
# another agent's session. See docs/baseline/watcher-override.md.
set -u

input=$(cat)
[ "${ALFRED_SESSION_CHECK:-1}" = "0" ] && exit 0

field() { printf '%s' "$input" | jq -r ".$1 // empty" 2>/dev/null; }
source=$(field source)
cwd=$(field cwd)
[ -n "$cwd" ] || cwd="$PWD"
jq -e '.agent_id // empty' "$cwd/.alfred/config.json" >/dev/null 2>&1 || exit 0

here=$(cd "$(dirname "$0")" && pwd)
agent_id=$(jq -r '.agent_id // empty' "$cwd/.alfred/config.json" 2>/dev/null)
wake="${ALFRED_WAKE_CHECK_BIN:-$here/../bin/alfred-wake}"
# Both commands are shell command lines (run with `bash -c`).
cfg="$cwd/.alfred/config.json"
wstate=$(jq -r '
  def why: if type != "string" then "missing or not a string"
    elif gsub("^\\s+|\\s+$"; "") == "" then "empty"
    elif test("[[:cntrl:]]") then "contains a control character"
    else null end;
  if .watcher == null then "absent"
  elif (.watcher | type) != "object" then "bad:watcher:not an object"
  elif (.watcher.status_cmd | why) != null then "bad:status_cmd:" + (.watcher.status_cmd | why)
  elif (.watcher.start_cmd | why) != null then "bad:start_cmd:" + (.watcher.start_cmd | why)
  else "ok" end' "$cfg" 2>/dev/null) || wstate="bad:watcher:unreadable"
default_status="$(printf '%q status' "$wake")"
default_start="alfred-wake wait"
case "$wstate" in
  absent) status_cmd="$default_status" start_cmd="$default_start" ;;
  ok)
    status_cmd=$(jq -r '.watcher.status_cmd' "$cfg") && start_cmd=$(jq -r '.watcher.start_cmd' "$cfg") \
      || wstate="bad:watcher:unreadable" ;;
esac
case "$wstate" in
  absent|ok) ;;
  *)
    status_cmd="$default_status" start_cmd="$default_start"
    bad=${wstate#bad:}; [ "$bad" != "$wstate" ] || bad="watcher:unreadable"
    echo "alfred-agent session-check: watcher in .alfred/config.json is not usable (${bad%%:*}: ${bad#*:}); using alfred-wake defaults" >&2 ;;
esac
[ -n "${ALFRED_WATCHER_STATUS_CMD+x}${ALFRED_WATCHER_START_CMD+x}" ] && echo "alfred-agent session-check: ALFRED_WATCHER_STATUS_CMD and ALFRED_WATCHER_START_CMD are ignored; set watcher.status_cmd and watcher.start_cmd in .alfred/config.json" >&2

armed=no
if timeout 10 bash -c "$status_cmd" >/dev/null 2>&1; then armed=yes; fi
unread=$(timeout 15 "$wake" unread 2>/dev/null) || unread="?"
[ -n "$unread" ] || unread="?"

if [ "$armed" = yes ] && [ "$unread" = 0 ]; then
  ctx="Wake watcher: running. Inbox: 0 unread. Nothing to do for this check; do not mention it."
else
  if [ "$armed" = yes ]; then w="running"; else w="NOT running"; fi
  checked=""
  [ "$armed" = no ] && checked="Checked: $status_cmd (agent $agent_id).
"
  ctx="Session ${source:-start} check: the wake watcher is $w and the inbox has $unread unread.
${checked}Do this now, before anything else:"
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
