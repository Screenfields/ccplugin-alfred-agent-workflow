#!/usr/bin/env bash
# Stop hook: one combined decision from the bridge check and the loop check
# (ccplugin#127). Replaces the direct bridge-check.sh Stop entry so the two
# checks never double-block or read each other's block as their own.
#
#   1. bridge-check.sh (unchanged): the wake bridge must be running.
#   2. alfred-loop-check --hook: no actionable item and no unread direct
#      message may be left unparked.
# Both get the same stdin bytes. At most one JSON object leaves this script:
# a block if either part blocks (one reason, a paragraph per part), and one
# systemMessage joining every warning. Garbage or a timeout from a part is a
# warning, never raw output and never a block.
#
# Fails open and always exits 0: no `set -e`, no `set -u`, the work is in a
# function, children run as `cmd & wait` so a TERM, INT or HUP trap fires at
# once and kills them. The guarantee rests on the arithmetic, not the trap: the
# bridge is capped at 5 s and the loop part at loop-check-deadline-seconds
# (10), under this entry's 20 s timeout. Kill switch for the loop part:
# ALFRED_LOOP_CHECK=0 (see bin/alfred-loop-check).
#
# It also records every Stop of a non-worker session, first thing and under the
# one clock reading it takes before any part runs: the reading, and whether the
# final message (last_assistant_message) was non-empty, go into
# alfred-reply-ts/<session_id>.json for the idle gate of hooks/reply-timestamp.sh
# (CCW-180; fields in lib/reply-time.sh). It never adds a time line to a block.
# The record runs as a background child beside the parts (no added wall time) and
# is waited for before the output; on a TERM it is allowed to finish, not killed.
#
# Test overrides: ALFRED_STOP_BRIDGE_BIN, ALFRED_STOP_LOOP_BIN,
# ALFRED_STOP_BRIDGE_SECONDS, ALFRED_STOP_LOOP_SECONDS.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BRIDGE="${ALFRED_STOP_BRIDGE_BIN:-$ROOT/hooks/bridge-check.sh}"
LOOP="${ALFRED_STOP_LOOP_BIN:-$ROOT/bin/alfred-loop-check}"
TMP=""
CHILD=""
REC=""
# shellcheck source=../lib/reply-time.sh
# shellcheck disable=SC1091
. "$ROOT/lib/reply-time.sh" 2>/dev/null || { reply_time_now() { return 1; }; reply_time_note_stop() { return 0; }; }

# shellcheck disable=SC2317  # runs from the traps below
cleanup() {
  [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null
  [ -n "$TMP" ] && rm -rf "$TMP"
}

# on_signal: a TERM, INT or HUP (the entry timed out). Kill the running child,
# print the bridge answer captured so far if it is a usable JSON object (a
# bridge block must not be lost), and leave with 0.
# shellcheck disable=SC2317  # runs from the trap below
on_signal() {
  [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null
  # The record is never killed: it ignores these signals and takes about 45 ms,
  # so let it finish. A killed write would leave a *.json.tmp.* file.
  [ -n "$REC" ] && wait "$REC" 2>/dev/null
  if [ -n "$TMP" ] && [ "$(jq -r type "$TMP/bridge.out" 2>/dev/null)" = object ]; then
    jq -c . "$TMP/bridge.out"
  fi
  cleanup
  exit 0
}

# read_part <file> <label> <var>: the part's output as one compact JSON object
# in <var>, or empty (a warning goes into WARN when the output was unusable).
read_part() {
  local f="$1" label="$2" var="$3" j
  printf -v "$var" '%s' ""
  [ -s "$f" ] || return 0
  if [ "$(jq -r type "$f" 2>/dev/null)" = object ]; then
    j=$(jq -c . "$f")
    printf -v "$var" '%s' "$j"
  else
    WARN+=("$label part gave unusable output, ignored")
  fi
}

# run_part <label> <seconds> <bin> [args]: run one part with the shared stdin.
run_part() {
  local label="$1" secs="$2" rc
  shift 2
  timeout -k 1 "$secs" "$@" < "$TMP/in" > "$TMP/$label.out" 2> "$TMP/$label.err" &
  CHILD=$!
  wait "$CHILD"
  rc=$?
  CHILD=""
  cat "$TMP/$label.err" >&2 2>/dev/null
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    WARN+=("$label part timed out, stop allowed")
    : > "$TMP/$label.out"
  fi
}

main() {
  WARN=()
  # The one clock reading of this Stop, taken before anything else runs.
  START=$(reply_time_now 2>/dev/null) || START=""
  command -v jq >/dev/null 2>&1 || { echo "stop: jq missing, checks skipped" >&2; return; }
  command -v timeout >/dev/null 2>&1 || { echo "stop: timeout missing, checks skipped" >&2; return; }
  TMP=$(mktemp -d) || return
  cat > "$TMP/in"
  # Record this Stop (CCW-180): its clock and whether the final message was empty.
  # A background child, in parallel with the parts so it adds no wall time. It
  # ignores TERM, INT and HUP (a signalled hook lets it finish rather than leave a
  # half-written temp file) and main waits for it before any output.
  ( trap '' TERM INT HUP; reply_time_note_stop "$START" "$TMP/in" ) &
  REC=$!

  local deadline
  deadline=$(jq -r '.["loop-check-deadline-seconds"] // 10 | floor' "$ROOT/config/thresholds.json" 2>/dev/null)
  case "$deadline" in ''|*[!0-9]*) deadline=10 ;; esac
  deadline="${ALFRED_STOP_LOOP_SECONDS:-$deadline}"

  run_part bridge "${ALFRED_STOP_BRIDGE_SECONDS:-5}" "$BRIDGE"
  local b l
  read_part "$TMP/bridge.out" bridge b
  run_part loop "$deadline" "$LOOP" --hook
  read_part "$TMP/loop.out" loop l

  # The record is done before anything is printed.
  wait "$REC" 2>/dev/null
  REC=""
  local msgs reason block
  block=$(jq -rn --argjson b "${b:-null}" --argjson l "${l:-null}" '[$b, $l] | map(select(. != null and .decision == "block")) | length')
  reason=$(jq -rn --argjson b "${b:-null}" --argjson l "${l:-null}" '[$b, $l] | map(select(. != null and .decision == "block") | .reason // "") | join("\n\n")')
  msgs=$(jq -rn --argjson b "${b:-null}" --argjson l "${l:-null}" --args '
    [$b, $l] | map(select(. != null) | .systemMessage // empty) + $ARGS.positional | join("\n")' "${WARN[@]}")

  if [ "${block:-0}" -gt 0 ]; then
    jq -cn --arg r "$reason" --arg m "$msgs" \
      '{decision: "block", reason: $r} + (if $m != "" then {systemMessage: $m} else {} end)'
  elif [ -n "$msgs" ]; then
    jq -cn --arg m "$msgs" '{systemMessage: $m}'
  fi
}

trap on_signal TERM INT HUP
trap cleanup EXIT
main
exit 0
