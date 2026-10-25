#!/usr/bin/env bash
# Live check for CCW-176 (not run by CI; `bats tests/` does not enter
# subdirectories): on the real harness, does the Stop check of the branch keep
# its note off the owner's screen, and does the next prompt hand it to the model?
#
#   owner-note.sh [--route p|tmux] <branch-dir> <main-dir>
#
# <branch-dir> is the checkout under test, <main-dir> a checkout of origin/main
# (the control: it still prints "Stop says"). Default route is p.
#
# Prints, and exits 0 only when all four hold:
#   stop-says-branch=0          branch, turn 1: no informational message with
#                               "Stop says" or "alfred-loop-check" (the harness
#                               shows a hook's systemMessage that way)
#   note-delivered=yes          branch, turn 2: the UserPromptSubmit hook output
#                               holds the note line and o/a#7
#   note-redelivered-fresh=yes  after turn 2 the state holds no pending_note, or
#                               one with another ts than after turn 1
#   stop-says-control>=1        control, turn 1: at least one "Stop says" (a
#                               count of 0 fails the run: the check above could
#                               not fail then)
# Exit 1: a check failed. Exit 2: usage. Exit 3: the run cannot prove anything
# (the branch plugin is not the one that loaded, no pending_note after turn 1,
# the session ids differ, a turn timed out).
#
# Route p (claude -p, stream-json). Turn 1 is `--session-id <uuid>`, turn 2 is
# `--resume <uuid>` from the same directory, the control is turn 1 again in
# $T/work2 with another uuid and --plugin-dir <main-dir>. Each call is under
# `timeout 120`, one at a time, the prompt on stdin.
#
# Route tmux, the fallback when -p mode does not keep CLAUDE_CODE_ENTRYPOINT=cli
# (then the Stop blocks instead of storing a note, and the script exits 3 with
# "owner marker not produced in -p mode; rerun with --route tmux"). An
# interactive claude runs in `tmux -L ccw176-$$` (a private socket, TMUX unset,
# the lead's own tmux is never reached). The folder-trust dialog is answered
# when the pane shows "Do you trust the files in this folder"; each prompt goes
# in with send-keys -l and Enter; a Stop is done when the state file shows a
# last_stop_ts newer than before and not older than last_turn_ts. "Stop says" is
# counted in the whole scrollback; turn 2 is read from the transcript
# (attachment hook_additional_context).
#
# Isolation:
#   - everything lives in T=$(mktemp -d /tmp/ccw176-live-XXXXXX); claude runs
#     from $T/work (the control from $T/work2), each with its own
#     .alfred/config.json {"agent_id":"live-check","repos":["o/a"]};
#   - both runs get the same environment: the checks and the wake bridge are
#     off or pointed into $T (ALFRED_SESSION_CHECK=0, ALFRED_SESSION_NUDGE=0,
#     ALFRED_WAKE_STOP_CHECK=0, ALFRED_WAKE_STATE_DIR=$T/wake,
#     ALFRED_WAKE_NO_UPGRADE=1, ALFRED_WAKE_BUZZ=off, ALFRED_WAKE_PLUGINS_JSON
#     an empty file), ALFRED_ROLE, ALFRED_LOOP_CHECK, CLAUDE_CODE_SESSION_ID and
#     every AGENT_RUNS_* are unset (the workitem hooks would post markers), and
#     so are the variables that tie a child to the parent's bridge and message
#     socket; CLAUDE_CODE_ENTRYPOINT=cli (the owner-turn test needs it); gh and
#     curl are the tests/stub copies on PATH over GH_STUB_DIR=$T/gh (one ready
#     issue 7 in o/a) and STUB_DIR=$T/stub (an empty inbox). HOME stays real
#     because the login is in ~/.claude;
#   - only the branch's hooks may fire: an enabled --plugin-dir plugin replaces
#     a same-named installed one, and the script proves it (system/init lists
#     alfred-agent with path <branch-dir> and no plugin_errors; the branch's
#     Stop stored a pending_note, a field no older copy writes) and exits 3
#     otherwise;
#   - on exit the running claude (or timeout) is stopped by the pid from $!,
#     the tmux server of this run is killed, T and the session directories
#     Claude Code made for $T/work and $T/work2 are removed, and so are the
#     loop state files (and .tmp.* beside them) of exactly the two session ids
#     of this run. The workitem hooks may write session files under
#     ~/.claude/alfred-workitem/; the run does not prevent that.
set -uo pipefail

ROUTE=p
if [ "${1:-}" = "--route" ]; then
  [ $# -ge 2 ] || { echo "usage: $0 [--route p|tmux] <branch-dir> <main-dir>" >&2; exit 2; }
  ROUTE="$2"
  shift 2
fi
case "$ROUTE" in p|tmux) ;; *) echo "usage: $0 [--route p|tmux] <branch-dir> <main-dir>" >&2; exit 2 ;; esac
[ $# -eq 2 ] || { echo "usage: $0 [--route p|tmux] <branch-dir> <main-dir>" >&2; exit 2; }
BRANCH=$(cd "$1" && pwd -P) || exit 2
MAIN=$(cd "$2" && pwd -P) || exit 2
for d in "$BRANCH" "$MAIN"; do
  [ -x "$d/bin/alfred-loop-check" ] || { echo "no bin/alfred-loop-check in $d" >&2; exit 2; }
done
command -v claude >/dev/null 2>&1 || { echo "claude not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
[ "$ROUTE" = p ] || command -v tmux >/dev/null 2>&1 || { echo "tmux not found" >&2; exit 2; }

T=$(mktemp -d /tmp/ccw176-live-XXXXXX) || exit 2
case "$T" in /tmp/ccw176-live-??????) ;; *) echo "unexpected temp dir $T" >&2; exit 2 ;; esac

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE="$CFG/alfred-loop"
SOCK="ccw176-$$"
UUID1=$(cat /proc/sys/kernel/random/uuid)
UUID2=$(cat /proc/sys/kernel/random/uuid)
CHILD=""

# stop_child — stop the claude (or timeout) started from this script, by pid.
stop_child() {
  if [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
    kill -TERM "$CHILD" 2>/dev/null || true
  fi
  CHILD=""
}

# shellcheck disable=SC2317  # runs from the traps below
cleanup() {
  trap '' EXIT TERM INT HUP
  stop_child
  if [ "$ROUTE" = tmux ]; then
    tmux -L "$SOCK" kill-server 2>/dev/null || true
  fi
  rm -rf "$CFG/projects/$(printf '%s' "$T/work" | tr / -)" "$CFG/projects/$(printf '%s' "$T/work2" | tr / -)"
  rm -f "$STATE/$UUID1.json" "$STATE/$UUID2.json" "$STATE/$UUID1.json.tmp."* "$STATE/$UUID2.json.tmp."*
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' TERM INT HUP

mkdir "$T/work" "$T/work2" "$T/bin" "$T/gh" "$T/stub" "$T/wake" "$T/work/.alfred" "$T/work2/.alfred" || exit 2
for d in work work2; do
  printf '{"agent_id":"live-check","repos":["o/a"]}\n' > "$T/$d/.alfred/config.json"
done
: > "$T/plugins.json"
printf '{"messages":[],"total_unread":0}' > "$T/stub/inbox.json"
printf '[{"number":7,"title":"Live check item","url":"https://github.com/o/a/issues/7","labels":[{"name":"status:ready"}]}]\n' > "$T/gh/o__a.json"
ln -s "$BRANCH/tests/stub/gh" "$T/bin/gh"
ln -s "$BRANCH/tests/stub/curl" "$T/bin/curl"

# The same environment for the branch and the control.
for v in $(compgen -e | grep '^AGENT_RUNS_'); do unset "$v"; done
unset ALFRED_ROLE ALFRED_LOOP_CHECK CLAUDE_CODE_SESSION_ID TMUX
unset CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN
export ALFRED_SESSION_CHECK=0 ALFRED_SESSION_NUDGE=0 ALFRED_WAKE_STOP_CHECK=0
export ALFRED_WAKE_STATE_DIR="$T/wake" ALFRED_WAKE_NO_UPGRADE=1 ALFRED_WAKE_BUZZ=off
export ALFRED_WAKE_PLUGINS_JSON="$T/plugins.json"
export CLAUDE_CODE_ENTRYPOINT=cli
export PATH="$T/bin:$PATH"
export GH_STUB_DIR="$T/gh" STUB_DIR="$T/stub"
export AGENT_MESSAGING_URL=http://stub.invalid/mcp/ AGENT_MESSAGING_TOKEN=test-token AGENT_ID=live-check

PROMPT="reply with the word ok"
NOTE_LINE="alfred-loop-check note (from the previous turn,"
printf '%s' "$PROMPT" > "$T/prompt.txt"

# turn_p <dir> <stream-file> <claude args...> — one claude -p call under timeout
# 120 from <dir>. `$!` is the timeout process, stopped by pid in cleanup.
turn_p() {
  local dir="$1" out="$2"
  shift 2
  ( cd "$dir" && exec timeout 120 claude -p "$@" --output-format stream-json --verbose --include-hook-events < "$T/prompt.txt" ) > "$out" 2> "$out.err" &
  CHILD=$!
  wait "$CHILD"
  local rc=$?
  CHILD=""
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "claude timed out ($out)" >&2
    exit 3
  fi
  return 0
}

# informational <stream-file> <pattern> — count of informational system messages
# whose content matches.
informational() {
  jq -c --arg re "$2" 'select(.type == "system" and .subtype == "informational" and ((.content // "" | tostring) | test($re)))' "$1" 2>/dev/null | wc -l | tr -d ' '
}

# state_ts <uuid> — pending_note.ts of the session state, or "none".
state_ts() {
  jq -r '.pending_note.ts // "none"' "$STATE/$1.json" 2>/dev/null || echo none
}

MARKER_MSG="owner marker not produced in -p mode; rerun with --route tmux"
CONTROL=0
DELIVERED=no

if [ "$ROUTE" = p ]; then
  turn_p "$T/work" "$T/t1.jsonl" --session-id "$UUID1" --plugin-dir "$BRANCH"
  # -s with any(): a plain `jq -e` over the stream reads the exit status from the
  # last input line only, and the init event is not the last line.
  jq -e -s --arg p "$BRANCH" 'any(.[]; .type == "system" and .subtype == "init" and ((.plugin_errors // []) | length == 0) and any(.plugins[]?; .name == "alfred-agent" and .path == $p))' "$T/t1.jsonl" > /dev/null 2>&1 \
    || { echo "the branch plugin is not the alfred-agent that loaded (system/init of turn 1); see $T" >&2; head -c 2000 "$T/t1.jsonl.err" >&2; exit 3; }
  TS1=$(state_ts "$UUID1")
  [[ "$TS1" =~ ^[0-9]+$ ]] || { echo "$MARKER_MSG" >&2; exit 3; }
  turn_p "$T/work" "$T/t2.jsonl" --resume "$UUID1" --plugin-dir "$BRANCH"
  s1=$(jq -r 'select(.type == "system" and .subtype == "init") | .session_id' "$T/t1.jsonl" | head -1)
  s2=$(jq -r 'select(.type == "system" and .subtype == "init") | .session_id' "$T/t2.jsonl" | head -1)
  if [ -z "$s1" ] || [ "$s1" != "$s2" ] || [ "$s1" != "$UUID1" ]; then
    echo "session ids differ: turn1=$s1 turn2=$s2 expected=$UUID1" >&2
    exit 3
  fi
  BRANCH_SAYS=$(informational "$T/t1.jsonl" 'Stop says|alfred-loop-check')
  if [ "$(jq -c --arg n "$NOTE_LINE" 'select(.type == "system" and .subtype == "hook_response" and .hook_event == "UserPromptSubmit" and ((.stdout // "") | contains($n)) and ((.stdout // "") | contains("o/a#7")))' "$T/t2.jsonl" | wc -l | tr -d ' ')" -ge 1 ]; then
    DELIVERED=yes
  fi
  turn_p "$T/work2" "$T/c1.jsonl" --session-id "$UUID2" --plugin-dir "$MAIN"
  CONTROL=$(informational "$T/c1.jsonl" 'Stop says')
else
  TM() { tmux -L "$SOCK" "$@"; }
  mangle() { printf '%s' "$1" | tr / -; }

  # tm_start <dir> <uuid> <plugin-dir> — an interactive claude in a new tmux
  # session; answer the folder-trust dialog when it shows.
  tm_start() {
    TM -f /dev/null new-session -d -s live -x 200 -y 50 -c "$1" "claude --session-id $2 --plugin-dir $3"
    CHILD=$(TM display-message -p -t live '#{pane_pid}')
    local i=0
    while [ "$i" -lt 120 ]; do
      if TM capture-pane -p -t live | grep -qi 'Do you trust the files in this folder'; then
        TM send-keys -t live Enter
        break
      fi
      # past the dialog, or no dialog: the input box shows
      if TM capture-pane -p -t live | grep -qE '^[[:space:]]*(>|❯)'; then break; fi
      sleep 1
      i=$((i + 1))
    done
    sleep 3
  }
  # tm_prompt <uuid> — send the prompt and wait for the Stop that follows.
  tm_prompt() {
    local prev i=0
    prev=$(jq -r '.last_stop_ts // 0' "$STATE/$1.json" 2>/dev/null || echo 0)
    TM send-keys -t live -l "$PROMPT"
    sleep 1
    TM send-keys -t live Enter
    while [ "$i" -lt 120 ]; do
      if jq -e --argjson p "$prev" '.last_stop_ts > $p and .last_stop_ts >= .last_turn_ts' "$STATE/$1.json" > /dev/null 2>&1; then return 0; fi
      sleep 1
      i=$((i + 1))
    done
    echo "no Stop within 120 s" >&2
    exit 3
  }
  tm_stop() { stop_child; TM kill-server 2>/dev/null || true; sleep 1; }

  unset TMUX
  tm_start "$T/work" "$UUID1" "$BRANCH"
  tm_prompt "$UUID1"
  TS1=$(state_ts "$UUID1")
  [[ "$TS1" =~ ^[0-9]+$ ]] || { echo "no pending_note after turn 1 in the tmux route" >&2; exit 3; }
  BRANCH_SAYS=$(TM capture-pane -p -S - -t live | grep -c 'Stop says')
  tm_prompt "$UUID1"
  TR="$CFG/projects/$(mangle "$T/work")/$UUID1.jsonl"
  if jq -e -s --arg n "$NOTE_LINE" 'any(.[]; .attachment.type == "hook_additional_context" and (tojson | contains($n)))' "$TR" > /dev/null 2>&1; then
    DELIVERED=yes
  fi
  tm_stop
  tm_start "$T/work2" "$UUID2" "$MAIN"
  tm_prompt "$UUID2"
  CONTROL=$(TM capture-pane -p -S - -t live | grep -c 'Stop says')
  tm_stop
fi

TS2=$(state_ts "$UUID1")
FRESH=yes
[ "$TS2" != "$TS1" ] || FRESH=no

RC=0
echo "route=$ROUTE"
echo "stop-says-branch=$BRANCH_SAYS"
[ "$BRANCH_SAYS" = 0 ] || RC=1
echo "note-delivered=$DELIVERED"
[ "$DELIVERED" = yes ] || RC=1
echo "note-redelivered-fresh=$FRESH"
[ "$FRESH" = yes ] || RC=1
if [ "$CONTROL" -ge 1 ] 2>/dev/null; then
  echo "stop-says-control>=1"
else
  echo "stop-says-control=0"
  RC=1
fi
exit "$RC"
