#!/usr/bin/env bash
# Live check for CCW-170 (not run by CI; `bats tests/` does not enter
# subdirectories): does `alfred-wake` find its owning Claude Code process on the
# real harness, and does a plain resume (`claude -c`) reuse the session id?
#
#   owner-discovery.sh <branch-dir>
#
# Prints `owner=<pid> ancestor=<pid>` (exit 1 when they differ or are missing)
# and then `session-id=same|different` with both values (information only).
#
# Isolation:
#   - everything lives in T=$(mktemp -d /tmp/ccw170-live-XXXXXX); the live state
#     dir is never touched: claude gets ALFRED_WAKE_STATE_DIR=$T/state and
#     ALFRED_WAKE_NO_UPGRADE=1 (no self-upgrade exec of the installed copy), and
#     the real HOME (Claude Code reads its login from ~/.claude);
#   - the wait runs against tests/stub (an `env` prefix on that one command, not
#     in claude's environment), so a non-empty real inbox cannot make it exit
#     and remove the owner file early;
#   - every claude call runs from $T/work, so `-c` can only continue sessions of
#     this run;
#   - on exit the wait is stopped by the pid in $T/state/alfred-wake.pid, T is
#     removed, and so is the session directory Claude Code made for $T/work.
#
# `claude -p` does not exit while its background task runs, and the wait would
# run for ever on an empty inbox. So the script runs claude in the background,
# waits for the step-2 marker file ($T/step2-done, touched by the step-2
# command after it printed its line), stops the wait by its pid, and then waits
# for claude to finish.
set -uo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <branch-dir>" >&2; exit 2; }
BRANCH=$(cd "$1" && pwd -P) || exit 2
[ -x "$BRANCH/bin/alfred-wake" ] || { echo "no bin/alfred-wake in $BRANCH" >&2; exit 2; }

T=$(mktemp -d /tmp/ccw170-live-XXXXXX) || exit 2
case "$T" in /tmp/ccw170-live-??????) ;; *) echo "unexpected temp dir $T" >&2; exit 2 ;; esac

# stop_wait — TERM the wait recorded in the pidfile, by pid, if it is one.
stop_wait() {
  local pid
  pid=$(cat "$T/state/alfred-wake.pid" 2>/dev/null || true)
  if [[ "$pid" =~ ^[0-9]+$ ]] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'alfred-wake'; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
}

CLAUDE_PID=""
cleanup() {
  trap '' EXIT TERM INT HUP
  stop_wait
  if [ -n "$CLAUDE_PID" ]; then kill -TERM "$CLAUDE_PID" 2>/dev/null || true; fi
  rm -rf "$HOME/.claude/projects/$(printf '%s' "$T/work" | tr / -)"
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' TERM INT HUP

mkdir "$T/work" "$T/stub" "$T/state" || exit 2
printf '{"messages":[],"total_unread":0}' > "$T/stub/inbox.json"

export ALFRED_WAKE_STATE_DIR="$T/state"
export ALFRED_WAKE_NO_UPGRADE=1

# claude_p <prompt> [-c] — one `claude -p` call from $T/work, the prompt on
# stdin (from a file, so that the subshell can exec claude and `$!` is claude's
# own pid). A -c continues the last session of $T/work.
claude_p() {
  local prompt="$1"
  shift
  printf '%s' "$prompt" > "$T/prompt.txt"
  ( cd "$T/work" && exec claude "$@" -p --plugin-dir "$BRANCH" --permission-mode bypassPermissions < "$T/prompt.txt" )
}

WAIT_CMD="env PATH=\"$BRANCH/tests/stub:\$PATH\" STUB_DIR=\"$T/stub\" AGENT_MESSAGING_URL=http://stub.invalid/mcp/ AGENT_MESSAGING_TOKEN=test-token AGENT_ID=owner-live-check ALFRED_WAKE_BUZZ=off $BRANCH/bin/alfred-wake wait"
read -r -d '' WALK <<'EOF2'
sleep 2; p=$$; while [ "$p" -gt 1 ]; do [ "$(cat /proc/$p/comm)" = claude ] && break; p=$(sed 's/.*) //' /proc/$p/stat | awk '{print $2}'); done; echo "owner=$(cut -d' ' -f1 "$ALFRED_WAKE_STATE_DIR/alfred-wake.owner") ancestor=$p"; touch STEP2_MARKER
EOF2
WALK=${WALK%$'\n'}
WALK=${WALK//STEP2_MARKER/$T/step2-done}

PROMPT="Do these two steps in order.
Step 1: start this command as a background Bash task (run_in_background: true), exactly as written:
$WAIT_CMD
Step 2: in a second Bash call, run this command exactly as written and reply with its output line only:
$WALK
Your final reply is that output line only, also after the background task has ended."

claude_p "$PROMPT" > "$T/out.txt" &
CLAUDE_PID=$!
i=0
while [ ! -e "$T/step2-done" ] && kill -0 "$CLAUDE_PID" 2>/dev/null && [ "$i" -lt 1200 ]; do
  sleep 0.2
  i=$((i + 1))
done
stop_wait
i=0
while kill -0 "$CLAUDE_PID" 2>/dev/null && [ "$i" -lt 600 ]; do
  sleep 0.2
  i=$((i + 1))
done
if kill -0 "$CLAUDE_PID" 2>/dev/null; then
  echo "claude (pid $CLAUDE_PID) did not exit after the wait was stopped" >&2
  exit 1
fi
CLAUDE_PID=""

o="" a=""
read -r o a < <(sed -n 's/^owner=\([0-9]*\) ancestor=\([0-9]*\)$/\1 \2/p' "$T/out.txt" | tail -1)
if [ -z "$o" ] || [ "$o" != "$a" ]; then
  echo "owner=${o:-} ancestor=${a:-}"
  exit 1
fi
echo "owner=$o ancestor=$a"

# shellcheck disable=SC2016  # the backticks and $ are for claude, not this shell
SID_PROMPT='run `echo "$CLAUDE_CODE_SESSION_ID"` in Bash and reply with that output only'
claude_p "$SID_PROMPT" > "$T/sid1.txt"
claude_p "$SID_PROMPT" -c > "$T/sid2.txt"
s1=$(tail -1 "$T/sid1.txt")
s2=$(tail -1 "$T/sid2.txt")
if [ -n "$s1" ] && [ "$s1" = "$s2" ]; then
  echo "session-id=same first=$s1 resumed=$s2"
else
  echo "session-id=different first=$s1 resumed=$s2"
fi
