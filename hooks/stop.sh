#!/usr/bin/env bash
# Stop hook: one combined decision from the bridge check and the loop check
# (ccplugin#127). Replaces the direct bridge-check.sh Stop entry so the two
# checks never double-block or read each other's block as their own.
#
#   1. bridge-check.sh (unchanged): the wake bridge must be running.
#   2. alfred-loop-check --hook: no actionable item and no unread direct
#      message may be left unparked.
#   3. reply-audit.sh (CCW-184): a time stamp at the head of the final reply must
#      be true. It runs last, with its own limit, and gets the clock this script
#      read before any part ran (--now), so a slow part cannot age a fresh stamp.
# All get the same stdin bytes. At most one JSON object leaves this script:
# a block if any part blocks (one reason, a paragraph per part), and one
# systemMessage joining every warning. Garbage or a timeout from a part is a
# warning, never raw output and never a block.
#
# Fails open and always exits 0: no `set -e`, no `set -u`, the work is in a
# function, children run as `cmd & wait` so a TERM, INT or HUP trap fires at
# once and kills them. The guarantee rests on the arithmetic, not the trap: the
# bridge is capped at 5 s, the loop part at loop-check-deadline-seconds (10) and
# the audit at 1 s; each part may live one kill-grace second more (timeout -k 1),
# so 6 + 11 + 2 = 19 s, under this entry's 20 s timeout. Kill switch for the loop part:
# ALFRED_LOOP_CHECK=0 (see bin/alfred-loop-check).
#
# It also records every Stop of a non-worker session, first thing and under the
# one clock reading it takes before any part runs: the reading, and whether the
# final message (last_assistant_message) was non-empty, go into
# alfred-reply-ts/<session_id>.json for the idle gate of hooks/reply-timestamp.sh
# (CCW-180; fields in lib/reply-time.sh). It never adds a time line to a block.
# The record runs as a background child beside the parts (no added wall time) and
# is waited for before the audit starts (the audit's flag write must not race the
# record's write of the same file) and before the output. On a TERM it is not
# killed: on_signal waits for it at most about 1 s (rec.done marker, polled), then
# goes on. A record still unfinished then is left to finish by itself, as it
# ignores the signals: its write completes after this script has exited, unless
# the input file it still had to read is gone, in which case that Stop is simply
# not recorded (the gate then sees the older state: at worst one extra or one
# missing time line). It never leaves a half-written state file.
#
# Kill switch for the audit: ALFRED_REPLY_TS_AUDIT=0 (the part is not started).
#
# Test overrides: ALFRED_STOP_BRIDGE_BIN, ALFRED_STOP_LOOP_BIN, ALFRED_STOP_AUDIT_BIN,
# ALFRED_STOP_BRIDGE_SECONDS, ALFRED_STOP_LOOP_SECONDS, ALFRED_STOP_AUDIT_SECONDS.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BRIDGE="${ALFRED_STOP_BRIDGE_BIN:-$ROOT/hooks/bridge-check.sh}"
LOOP="${ALFRED_STOP_LOOP_BIN:-$ROOT/bin/alfred-loop-check}"
AUDIT="${ALFRED_STOP_AUDIT_BIN:-$ROOT/hooks/reply-audit.sh}"
TMP=""
CHILD=""
REC=""
# shellcheck source=../lib/reply-time.sh
# shellcheck disable=SC1091
. "$ROOT/lib/reply-time.sh" 2>/dev/null || { reply_time_now() { return 1; }; reply_time_note_stop() { return 0; }; reply_time_audit_off() { return 0; }; }

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
  # so give it up to about 1 s to finish. A killed write would leave a
  # *.json.tmp.* file. A record still running after that is left alone.
  wait_rec_bounded
  if [ -n "$TMP" ] && [ "$(jq -r type "$TMP/bridge.out" 2>/dev/null)" = object ]; then
    jq -c . "$TMP/bridge.out"
  fi
  cleanup
  exit 0
}

# wait_rec_bounded: wait for the record child at most 10 x 0.1 s. `wait` has no
# time limit, so the child marks its end with $TMP/rec.done and this polls for it.
# shellcheck disable=SC2317  # called from on_signal
wait_rec_bounded() {
  local i=0
  [ -n "$REC" ] && [ -n "$TMP" ] || return 0
  while [ ! -e "$TMP/rec.done" ] && [ "$i" -lt 10 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$TMP/rec.done" ] && wait "$REC" 2>/dev/null
  return 0
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
  ( trap '' TERM INT HUP; reply_time_note_stop "$START" "$TMP/in"; { : > "$TMP/rec.done"; } 2>/dev/null ) &
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

  # The record is done before the audit starts (both merge the same state file,
  # and a flag written between the record's read and move would be lost) and
  # before anything is printed. It ran beside the quiet parts, so this is
  # normally no wait at all.
  wait "$REC" 2>/dev/null
  REC=""
  # The audit runs last, with the clock taken at the top of main (before any part).
  local a=""
  if ! reply_time_audit_off && [ -n "$START" ]; then
    run_part audit "${ALFRED_STOP_AUDIT_SECONDS:-1}" "$AUDIT" --now "$START"
    read_part "$TMP/audit.out" audit a
  fi
  local msgs reason block
  block=$(jq -rn --argjson a "${a:-null}" --argjson b "${b:-null}" --argjson l "${l:-null}" '[$a, $b, $l] | map(select(. != null and .decision == "block")) | length')
  reason=$(jq -rn --argjson a "${a:-null}" --argjson b "${b:-null}" --argjson l "${l:-null}" '[$a, $b, $l] | map(select(. != null and .decision == "block") | .reason // "") | join("\n\n")')
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
