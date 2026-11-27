#!/usr/bin/env bash
# Live check for CCW-170 (not run by CI; `bats tests/` does not enter
# subdirectories): does `alfred-wake` find its owning Claude Code process on the
# real harness, and does a plain resume (`claude -c`) reuse the session id?
#
#   owner-discovery.sh <branch-dir>
#
# Prints `owner=<pid> ancestor=<pid> status=<n>`: owner is the first field of
# alfred-wake.owner, ancestor the pid find_owner returns from the step-2 shell,
# n the exit code of `alfred-wake status` run there while the wait runs. Exit 1
# unless owner is a pid, owner equals ancestor and status is 0; exit 2 when a
# piece of the owner rule is missing from bin/alfred-wake. Then it prints
# `session-id=same|different` with both values (information only).
#
# The owner rule has one home, bin/alfred-wake. This script extracts stat_rest,
# owner_versioned, find_owner and the OWNER_COMM= line from it (bin/alfred-wake
# ends in an unconditional main, so it cannot be sourced) and calls them.
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

# claude_p <prompt> [-c] — one foreground `claude -p` call from $T/work, the
# prompt on stdin. A -c continues the last session of $T/work.
claude_p() {
  local prompt="$1"
  shift
  printf '%s' "$prompt" > "$T/prompt.txt"
  ( cd "$T/work" && exec claude "$@" -p --plugin-dir "$BRANCH" --permission-mode bypassPermissions < "$T/prompt.txt" )
}

WAIT_CMD="env PATH=\"$BRANCH/tests/stub:\$PATH\" STUB_DIR=\"$T/stub\" AGENT_MESSAGING_URL=http://stub.invalid/mcp/ AGENT_MESSAGING_TOKEN=test-token AGENT_ID=owner-live-check ALFRED_WAKE_BUZZ=off $BRANCH/bin/alfred-wake wait"
# The bridge's own owner rule, extracted from bin/alfred-wake into $T/owner-rule.sh.
RULE="$T/owner-rule.sh"
: > "$RULE"
for fn in stat_rest owner_versioned find_owner; do
  piece=$(sed -n "/^$fn() {\$/,/^}\$/p" "$BRANCH/bin/alfred-wake")
  case "$piece" in
    "$fn() {"*"}") printf '%s\n' "$piece" >> "$RULE" ;;
    *) echo "bin/alfred-wake: $fn is missing or incomplete" >&2; exit 2 ;;
  esac
done
oc=$(grep '^OWNER_COMM=' "$BRANCH/bin/alfred-wake")
case "$oc" in
  OWNER_COMM=*) [ "$(printf '%s\n' "$oc" | wc -l)" -eq 1 ] || { echo "bin/alfred-wake: more than one OWNER_COMM= line" >&2; exit 2; } ;;
  *) echo "bin/alfred-wake: the OWNER_COMM= line is missing" >&2; exit 2 ;;
esac
printf '%s\n' "$oc" >> "$RULE"
bash -n "$RULE" || { echo "bin/alfred-wake: the extracted owner rule does not parse" >&2; exit 2; }

read -r -d '' WALK <<'EOF2'
i=0; while [ ! -s "$ALFRED_WAKE_STATE_DIR/alfred-wake.owner" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done; . OWNER_RULE; a=$(find_owner); a=${a%% *}; BRANCH_DIR/bin/alfred-wake status >/dev/null 2>&1; s=$?; echo "owner=$(cut -d' ' -f1 "$ALFRED_WAKE_STATE_DIR/alfred-wake.owner" 2>/dev/null) ancestor=$a status=$s"; touch STEP2_MARKER
EOF2
WALK=${WALK%$'\n'}
WALK=${WALK//STEP2_MARKER/$T/step2-done}
WALK=${WALK//OWNER_RULE/$RULE}
WALK=${WALK//BRANCH_DIR/$BRANCH}

PROMPT="Do these two steps in order.
Step 1: start this command as a background Bash task (run_in_background: true), exactly as written:
$WAIT_CMD
Step 2: in a second Bash call, run this command exactly as written and reply with its output line only:
$WALK
Your final reply is that output line only, also after the background task has ended."

# The background call is a subshell that execs claude, started with `&` right
# here (not through a function, which would add a wrapper process): `$!` is
# claude's own pid, so cleanup kills claude and not a wrapper.
printf '%s' "$PROMPT" > "$T/prompt.txt"
( cd "$T/work" && exec claude -p --plugin-dir "$BRANCH" --permission-mode bypassPermissions < "$T/prompt.txt" ) > "$T/out.txt" &
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

o="" a="" st=""
IFS='|' read -r o a st < <(sed -n 's/^owner=\([0-9a-z]*\) ancestor=\([0-9]*\) status=\([0-9]*\)$/\1|\2|\3/p' "$T/out.txt" | tail -1)
echo "owner=${o:-} ancestor=${a:-} status=${st:-}"
if ! [[ "$o" =~ ^[0-9]+$ ]] || [ "$o" != "$a" ] || [ "$st" != 0 ]; then
  exit 1
fi

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
