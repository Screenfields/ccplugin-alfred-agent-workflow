#!/usr/bin/env bats
# hooks/reply-timestamp.sh, lib/reply-time.sh and lib/owner-turn.sh (CCW-141,
# CCW-180): the Europe/Amsterdam time line injected when a prompt starts a new set of
# actions (the idle gate and its per-session state). `date` is replaced by a fake on PATH
# (FAKE_DATE is what it prints for the TZ format; `date +%s` is the real one).
# ALFRED_REPLY_TS_NOW pins the clock. No network, no model call.
# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  HOOK="$ROOT/hooks/reply-timestamp.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/date" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"%F %H:%M %Z"*) printf '%s\n' "${FAKE_DATE-2026-10-22 18:40 CEST}" ;;
  *) exec /usr/bin/date "$@" ;;
esac
FAKE
  chmod +x "$BATS_TEST_TMPDIR/bin/date"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset ALFRED_ROLE ALFRED_REPLY_TS_LOG CLAUDE_CODE_ENTRYPOINT ALFRED_REPLY_TS_NOW ALFRED_THRESHOLDS
  export CLAUDE_CODE_ENTRYPOINT=cli
  # A private config dir: the hook writes alfred-reply-ts/<sid>.json there, never into ~/.claude.
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  STATE="$CLAUDE_CONFIG_DIR/alfred-reply-ts"
  SF="$STATE/s1.json"
  T0=1792800000
}

# at <seconds after T0> — pin the clock.
at() { export ALFRED_REPLY_TS_NOW=$((T0 + $1)); }
# seed <json> [sid] — the state file of a session.
seed() { mkdir -p "$STATE"; printf '%s\n' "$1" > "$STATE/${2:-s1}.json"; }
# seed_gap <seconds> — a closed state whose last activity is <seconds> before the pinned clock.
seed_gap() { seed "{\"last_activity\":$((ALFRED_REPLY_TS_NOW - $1)),\"open\":false}"; }
sget() { jq -r "$1" "$SF"; }
# stop_turn <seconds after T0> <final message> [session] — run the real stop.sh with quiet parts.
stop_turn() {
  jq -cn --arg m "$2" --arg s "${3:-s1}" '{session_id: $s, stop_hook_active: false, last_assistant_message: $m}' \
    | ALFRED_REPLY_TS_NOW=$((T0 + $1)) ALFRED_STOP_BRIDGE_BIN=/bin/true ALFRED_STOP_LOOP_BIN=/bin/true "$ROOT/hooks/stop.sh" > /dev/null
}

# hook <json> — run the hook with the given stdin.
hook() { run --separate-stderr "$HOOK" <<< "$1"; }
# prompt_json <prompt> [source] — UserPromptSubmit input; source omitted when not given.
prompt_json() {
  if [ $# -ge 2 ]; then jq -cn --arg p "$1" --arg s "$2" '{session_id: "s1", prompt: $p, source: $s}'
  else jq -cn --arg p "$1" '{session_id: "s1", prompt: $p}'; fi
}
silent() { [ "$status" -eq 0 ]; [ -z "$output" ]; }
line_is() {
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" = "UserPromptSubmit" ]
  [ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" = "Time now _[$1]_. A new set of actions starts: start your first reply of this turn with this time line. Put none on later replies until a line is injected again. If the turn runs longer than a few minutes, use a fresh TZ=Europe/Amsterdam time instead." ]
}

# --- AC 1: the idle gate ----------------------------------------------------------------------------------------

# reset — forget the session's state (a test that runs the hook several times as one fresh session each).
reset() { rm -rf "$STATE"; }

@test "owner prompt, source user: the line with the CEST time" {
  hook "$(prompt_json "please look" user)"
  line_is "2026-10-22 18:40 CEST"
}

@test "owner prompt, source sdk: the line (pins the intent)" {
  hook "$(prompt_json "please look" sdk)"
  line_is "2026-10-22 18:40 CEST"
}

@test "owner prompt, source absent: the line" {
  hook "$(prompt_json "please look")"
  line_is "2026-10-22 18:40 CEST"
}

@test "the other interactive entrypoints count as owner" {
  for ep in claude-vscode claude-desktop; do
    echo "$ep"; reset
    CLAUDE_CODE_ENTRYPOINT=$ep hook "$(prompt_json "hello")"
    line_is "2026-10-22 18:40 CEST"
  done
}

@test "CET: the line carries CET" {
  FAKE_DATE="2026-12-01 09:05 CET" hook "$(prompt_json "hello" user)"
  line_is "2026-12-01 09:05 CET"
}

@test "real date: the line matches the CET/CEST format" {
  [ -e /usr/share/zoneinfo/Europe/Amsterdam ] || skip "no Europe/Amsterdam tzdata"
  rm "$BATS_TEST_TMPDIR/bin/date"
  hook "$(prompt_json "hello" user)"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" =~ _\[[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}\ CES?T\]_ ]]
}

@test "DST boundary 2026-10-25 (real date, fixed instant): 00:30 UTC is 02:30 CEST, 01:30 UTC is 02:30 CET" {
  [ -e /usr/share/zoneinfo/Europe/Amsterdam ] || skip "no Europe/Amsterdam tzdata"
  rm "$BATS_TEST_TMPDIR/bin/date"
  ALFRED_REPLY_TS_NOW=$(date -u -d '2026-10-25 00:30' +%s) hook "$(prompt_json "hello" user)"
  line_is "2026-10-25 02:30 CEST"
  ALFRED_REPLY_TS_NOW=$(date -u -d '2026-10-25 01:30' +%s) hook "$(prompt_json "hello" user)"
  line_is "2026-10-25 02:30 CET"
}

@test "missing tzdata (zone is not CET or CEST): no output, one line on stderr" {
  FAKE_DATE="2026-10-22 16:40 UTC" hook "$(prompt_json "hello" user)"
  silent
  [ "$(wc -l <<< "$stderr")" -eq 1 ]
  [ -n "$stderr" ]
}

@test "a date that prints nothing: no output" {
  FAKE_DATE="" hook "$(prompt_json "hello" user)"
  silent
}

# --- AC 1 (continued): the gate counts seconds, and does not look at the wake type -----------------------

@test "gate: no state (a first prompt of a session): the line" {
  at 0; hook "$(prompt_json "hello" user)"; line_is "2026-10-22 18:40 CEST"
}

@test "gate: 899 s idle none, 900 s idle the line, 1 s none, 2 hours the line" {
  at 100000
  seed_gap 899;  hook "$(prompt_json "hello" user)"; silent
  seed_gap 900;  hook "$(prompt_json "hello" user)"; line_is "2026-10-22 18:40 CEST"
  seed_gap 1;    hook "$(prompt_json "hello" user)"; silent
  seed_gap 7200; hook "$(prompt_json "hello" user)"; line_is "2026-10-22 18:40 CEST"
}

@test "gate: the gap is measured from last_activity, not from last_prompt" {
  at 100000
  seed "{\"last_activity\":$((ALFRED_REPLY_TS_NOW - 3600)),\"last_prompt\":$((ALFRED_REPLY_TS_NOW - 5)),\"open\":false}"
  hook "$(prompt_json "hello" user)"; line_is "2026-10-22 18:40 CEST"
}

@test "gate: the threshold is read through alfred-config (another value changes the verdict)" {
  at 100000
  jq '.["reply-time-idle-minutes"] = 1' "$ROOT/config/thresholds.json" > "$BATS_TEST_TMPDIR/thr.json"
  export ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/thr.json"
  seed_gap 59; hook "$(prompt_json "hello" user)"; silent
  seed_gap 60; hook "$(prompt_json "hello" user)"; line_is "2026-10-22 18:40 CEST"
}

# idle_fresh <json> — the same prompt twice: after 2 hours idle (the line), then 60 s after a reply (none).
idle_fresh() {
  at 100000
  seed_gap 7200; hook "$1"; line_is "2026-10-22 18:40 CEST"
  seed_gap 60;   hook "$1"; silent
}

@test "wake types: sdk-cli entrypoint, unset entrypoint: the line when idle, none when fresh" {
  CLAUDE_CODE_ENTRYPOINT=sdk-cli idle_fresh "$(prompt_json "hello" user)"
  unset CLAUDE_CODE_ENTRYPOINT
  idle_fresh "$(prompt_json "hello" user)"
}

@test "wake types: source system, loop_wakeup, schedule_wakeup, poll_event" {
  for src in system loop_wakeup schedule_wakeup poll_event; do
    echo "$src"
    idle_fresh "$(prompt_json "hello" "$src")"
  done
}

@test "wake types: the five machine prefixes, with a source and without" {
  for pre in '<task-notification>x' '<cross-session-message from=hub>' '[substrate wake] new mail' '<scheduled-task>' '[scheduled-task] x'; do
    echo "$pre"
    idle_fresh "$(prompt_json "$pre" user)"
    idle_fresh "$(prompt_json "$pre")"
  done
}

@test "wake types: a machine prefix after leading whitespace" {
  idle_fresh "$(prompt_json $'  \n[substrate wake] x' user)"
}

@test "wake types: the empty and whitespace-only prompts" {
  idle_fresh "$(prompt_json "" user)"
  idle_fresh "$(prompt_json "   " user)"
}

# --- AC 3: the prompt record ------------------------------------------------------------------------------------

@test "record: every non-worker prompt writes last_prompt and open; line_at only when a line was injected" {
  at 0
  hook "$(prompt_json "hello" user)"; line_is "2026-10-22 18:40 CEST"
  [ "$(sget '{last_prompt, open, line_at}|tojson')" = "{\"last_prompt\":$T0,\"open\":true,\"line_at\":$T0}" ]
  at 30
  hook "$(prompt_json "again" user)"; silent
  [ "$(sget '{last_prompt, open, line_at}|tojson')" = "{\"last_prompt\":$((T0 + 30)),\"open\":true,\"line_at\":$T0}" ]
}

@test "record: one clock reading is the gap's now, the stored time and the stamp" {
  [ -e /usr/share/zoneinfo/Europe/Amsterdam ] || skip "no Europe/Amsterdam tzdata"
  rm "$BATS_TEST_TMPDIR/bin/date"
  e=$(date -u -d '2026-10-25 01:30' +%s)
  ALFRED_REPLY_TS_NOW=$e hook "$(prompt_json "hello" user)"
  line_is "2026-10-25 02:30 CET"
  [ "$(sget .line_at)" = "$e" ]
  [ "$(sget .last_prompt)" = "$e" ]
}

@test "record: the hook reads the clock once (date +%s is called once)" {
  cat > "$BATS_TEST_TMPDIR/bin/date" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"%F %H:%M %Z"*) printf '%s\n' "2026-10-22 18:40 CEST" ;;
  *"+%s"*) echo x >> "$CALLS"; exec /usr/bin/date "$@" ;;
  *) exec /usr/bin/date "$@" ;;
esac
FAKE
  export CALLS="$BATS_TEST_TMPDIR/calls"
  hook "$(prompt_json "hello" user)"
  line_is "2026-10-22 18:40 CEST"
  [ "$(wc -l < "$CALLS")" -eq 1 ]
}

@test "record: written to a temp file, then moved (no temp file is left)" {
  cat > "$BATS_TEST_TMPDIR/bin/mv" <<'SPY'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MVLOG"
exec /usr/bin/mv "$@"
SPY
  chmod +x "$BATS_TEST_TMPDIR/bin/mv"
  export MVLOG="$BATS_TEST_TMPDIR/mv.log"
  hook "$(prompt_json "hello" user)"
  [ "$(wc -l < "$MVLOG")" -eq 1 ]
  [[ "$(cat "$MVLOG")" == *"/s1.json.tmp."*" "*"/s1.json" ]]
  [ "$(ls "$STATE")" = "s1.json" ]
}

@test "record: only epochs and flags are stored, never prompt or reply text" {
  hook "$(prompt_json "SECRET-PROMPT-TEXT" user)"
  stop_turn 5 "SECRET-REPLY-TEXT"
  [ "$(jq -r '[.[] | type] | unique | join(",")' "$SF")" = "array,boolean,number" ]
  run ! grep -q 'SECRET' "$SF"
}

@test "record: the session id is sanitised like alfred-loop-check does (slash and spaces)" {
  hook "$(jq -cn '{session_id: "a/b c..d", prompt: "hi"}')"
  line_is "2026-10-22 18:40 CEST"
  [ "$(ls "$STATE")" = "a_b_c..d.json" ]
}

@test "record: an empty session id gets no state file, and the line is shown" {
  hook "$(jq -cn '{session_id: "", prompt: "hi"}')"
  line_is "2026-10-22 18:40 CEST"
  [ ! -e "$STATE" ]
  [ "$(wc -l <<< "$stderr")" -le 1 ]
}

@test "record: files older than a day are pruned when a session's file is first created, not otherwise" {
  mkdir -p "$STATE"
  echo '{}' > "$STATE/old.json"; touch -d '25 hours ago' "$STATE/old.json"
  echo '{}' > "$STATE/old2.json.tmp.1"; touch -d '30 hours ago' "$STATE/old2.json.tmp.1"
  echo '{}' > "$STATE/young.json"; touch -d '23 hours ago' "$STATE/young.json"
  hook "$(prompt_json "hello" user)"                    # s1.json is created: prune
  [ ! -e "$STATE/old.json" ]; [ ! -e "$STATE/old2.json.tmp.1" ]; [ -e "$STATE/young.json" ]; [ -e "$SF" ]
  echo '{}' > "$STATE/old3.json"; touch -d '25 hours ago' "$STATE/old3.json"
  hook "$(prompt_json "again" user)"                    # s1.json exists: no prune
  [ -e "$STATE/old3.json" ]
}

@test "record: a key of another writer survives a prompt and a Stop" {
  seed '{"other":[1,2],"keep":true,"last_activity":1700000000,"open":false}'
  at 100000
  hook "$(prompt_json "hello" user)"
  stop_turn 100010 "ok"
  [ "$(sget '{other, keep}|tojson')" = '{"other":[1,2],"keep":true}' ]
}

# --- AC 4: Stop record, silent turns, mid-turn wakes, interrupted turns -------------------------------------------

@test "turn: a non-empty final message sets last_activity and closes the turn; an empty one leaves last_activity" {
  at 0; hook "$(prompt_json "hello" user)"
  stop_turn 30 "done"
  [ "$(sget '{last_stop, stop_nonempty, last_activity, open}|tojson')" = "{\"last_stop\":$((T0 + 30)),\"stop_nonempty\":true,\"last_activity\":$((T0 + 30)),\"open\":false}" ]
  at 100; hook "$(prompt_json "wake" user)"; silent
  stop_turn 130 ""
  [ "$(sget '{last_stop, stop_nonempty, last_activity, open}|tojson')" = "{\"last_stop\":$((T0 + 130)),\"stop_nonempty\":false,\"last_activity\":$((T0 + 30)),\"open\":false}" ]
}

@test "turn: a whitespace-only or missing final message counts as empty" {
  seed "{\"last_activity\":1700000000,\"open\":true}"
  stop_turn 100 $' \n '
  [ "$(sget '.stop_nonempty')" = "false" ]; [ "$(sget .last_activity)" = "1700000000" ]
  jq -cn '{session_id: "s1", stop_hook_active: false}' | ALFRED_REPLY_TS_NOW=$((T0 + 200)) ALFRED_STOP_BRIDGE_BIN=/bin/true ALFRED_STOP_LOOP_BIN=/bin/true "$ROOT/hooks/stop.sh"
  [ "$(sget '.stop_nonempty')" = "false" ]; [ "$(sget .last_activity)" = "1700000000" ]
}

@test "turn: a silent wake turn does not use up the line (seeded 40 minutes idle)" {
  seed "{\"last_activity\":$((T0 - 2400)),\"open\":false}"
  at 0; hook "$(prompt_json "[substrate wake] x")"; line_is "2026-10-22 18:40 CEST"
  stop_turn 20 ""                                         # a wake with no news ends with an empty final message
  [ "$(sget .last_activity)" = "$((T0 - 2400))" ]
  at 300; hook "$(prompt_json "[substrate wake] y")"; line_is "2026-10-22 18:40 CEST"
}

@test "turn: a prompt inside a turn whose injection is less than the threshold old gets no second line; at the threshold it does" {
  seed "{\"last_activity\":$((T0 - 2400)),\"open\":false}"
  at 0;   hook "$(prompt_json "[substrate wake] x")"; line_is "2026-10-22 18:40 CEST"
  at 5;   hook "$(prompt_json "<task-notification>x")"; silent
  at 899; hook "$(prompt_json "<task-notification>y")"; silent
  at 900; hook "$(prompt_json "<task-notification>z")"; line_is "2026-10-22 18:40 CEST"
  at 1799; hook "$(prompt_json "<task-notification>w")"; silent
  at 1800; hook "$(prompt_json "<task-notification>v")"; line_is "2026-10-22 18:40 CEST"
}

@test "turn: an interrupted turn leaves no Stop; a prompt at minute 5 gets none, at minute 20 one, and it is never open for good" {
  seed "{\"last_activity\":$((T0 - 2400)),\"open\":false}"
  at 0;    hook "$(prompt_json "hello" user)"; line_is "2026-10-22 18:40 CEST"
  at 300;  hook "$(prompt_json "next" user)"; silent
  at 1200; hook "$(prompt_json "later" user)"; line_is "2026-10-22 18:40 CEST"
  [ "$(sget .open)" = "true" ]
  stop_turn 1230 "ok"                                      # any later Stop closes it
  [ "$(sget .open)" = "false" ]
  at 1300; hook "$(prompt_json "more" user)"; silent       # last_activity is fresh again
}

@test "turn: same second, a Stop then a prompt: the order is the write order, not the epoch" {
  seed "{\"last_activity\":$((T0 - 2400)),\"open\":false}"
  at 0; hook "$(prompt_json "wake" user)"; line_is "2026-10-22 18:40 CEST"
  stop_turn 0 ""                                           # the Stop lands in the same second as the injection
  [ "$(sget .open)" = "false" ]
  at 1; hook "$(prompt_json "wake" user)"; line_is "2026-10-22 18:40 CEST"   # closed: the empty turn does not suppress
}

@test "turn: same second, a prompt right after a Stop: the open turn suppresses the next one" {
  seed "{\"last_activity\":$((T0 - 2400)),\"open\":false}"
  stop_turn 0 ""
  at 0; hook "$(prompt_json "wake" user)"; line_is "2026-10-22 18:40 CEST"
  at 1; hook "$(prompt_json "wake" user)"; silent
}

@test "turn: a second session has its own state (a Stop of s2 does not close s1)" {
  at 0; hook "$(prompt_json "hello" user)"
  stop_turn 5 "ok" s2
  [ "$(sget .open)" = "true" ]
  [ "$(jq -r .open "$STATE/s2.json")" = "false" ]
}

# --- AC 2: workers get nothing -------------------------------------------------------------------------

@test "ALFRED_ROLE=worker: no output" {
  ALFRED_ROLE=worker hook "$(prompt_json "hello" user)"; silent
}

@test "ALFRED_ROLE=worker with a log: emitted false, owner false" {
  export ALFRED_REPLY_TS_LOG="$BATS_TEST_TMPDIR/ts.log"
  ALFRED_ROLE=worker hook "$(prompt_json "hello" user)"; silent
  [ "$(jq -c '{emitted, owner}' "$ALFRED_REPLY_TS_LOG")" = '{"emitted":false,"owner":false}' ]
}

@test "worker: reads no state, writes none, and runs no threshold read" {
  at 100000
  seed_gap 7200
  before=$(cat "$SF"); ls -l --time-style=+%s "$STATE" > "$BATS_TEST_TMPDIR/ls.before"
  mkdir -p "$BATS_TEST_TMPDIR/p/hooks" "$BATS_TEST_TMPDIR/p/lib" "$BATS_TEST_TMPDIR/p/bin"
  cp "$HOOK" "$BATS_TEST_TMPDIR/p/hooks/"; cp "$ROOT"/lib/*.sh "$BATS_TEST_TMPDIR/p/lib/"
  printf '#!/bin/sh\ntouch "%s/config-read"\necho 15\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/p/bin/alfred-config"; chmod +x "$BATS_TEST_TMPDIR/p/bin/alfred-config"
  ALFRED_ROLE=worker run --separate-stderr "$BATS_TEST_TMPDIR/p/hooks/reply-timestamp.sh" <<< "$(prompt_json "hello" user)"
  silent
  [ ! -e "$BATS_TEST_TMPDIR/config-read" ]
  [ "$(cat "$SF")" = "$before" ]
  [ "$(ls -l --time-style=+%s "$STATE")" = "$(cat "$BATS_TEST_TMPDIR/ls.before")" ]
}

@test "worker: with no state yet, no state directory is made" {
  ALFRED_ROLE=worker hook "$(prompt_json "hello" user)"; silent
  [ ! -e "$STATE" ]
}

@test "worker: stop.sh writes no state" {
  ALFRED_ROLE=worker stop_turn 5 "ok"
  [ ! -e "$STATE" ]
}

# --- AC 8: when the gate cannot decide, the line is shown --------------------------------------------------------

# undecided <label> — the line is shown and at most one stderr line.
undecided() {
  hook "$(prompt_json "hello" user)"
  line_is "2026-10-22 18:40 CEST"
  [ "$(wc -l <<< "$stderr")" -le 1 ] || { echo "$1: $stderr"; return 1; }
}

@test "cannot decide: garbage state" {
  at 100000; mkdir -p "$STATE"; echo 'not json {' > "$SF"
  undecided garbage; [ -n "$stderr" ]
  [ "$(sget .open)" = "true" ]                              # the next write replaces the garbage
}

@test "cannot decide: state that is a JSON array, or has a wrong-typed field" {
  at 100000; seed '[1,2]'; undecided array
  seed '{"last_activity":"soon","open":false}'; undecided string
  seed '{"last_activity":100000,"open":"yes"}'; undecided open
}

@test "cannot decide: the state is a directory: refused, the line shows, one stderr line, no temp file, nothing moved into it" {
  at 100000; mkdir -p "$SF"
  undecided dir; [ -n "$stderr" ]
  [ -d "$SF" ]
  [ -z "$(ls -A "$SF")" ]                                   # mv must not have moved a temp file into the directory
  [ "$(ls "$STATE")" = "s1.json" ]                           # and no s1.json.tmp.* beside it
  stop_turn 100 "ok"                                         # the Stop refuses too, exit 0, nothing written
  [ -z "$(ls -A "$SF")" ]; [ "$(ls "$STATE")" = "s1.json" ]
}

# oob <json> — a state with an out of range or wrong-typed owned key: the line shows, status 0, at most one
# stderr line (and no bash error text), the prompt is recorded, and the bad key is gone after the write.
oob() {
  at 100000; seed "$1"
  hook "$(prompt_json "hello" user)"
  [ "$status" -eq 0 ]
  line_is "2026-10-22 18:40 CEST"
  [ "$(wc -l <<< "$stderr")" -le 1 ]
  [[ "$stderr" != *"syntax error"* && "$stderr" != *"value too great"* && "$stderr" != *"unbound"* && "$stderr" != *"arithmetic"* ]]
  [ "$(sget .last_prompt)" = "$((T0 + 100000))" ]
  [ "$(jq -r '(.last_activity // 0) | tostring | length < 11' "$SF")" = "true" ]
}

@test "cannot decide: out of range epochs are unusable state, never arithmetic (1e30, 99999999999999999999, 1790000000000000000, line_at 1e30)" {
  oob '{"last_activity":1e30,"open":false}'
  oob '{"last_activity":99999999999999999999,"open":false}'
  oob '{"last_activity":1790000000000000000,"open":false}'
  oob '{"last_activity":1,"open":true,"line_at":1e30}'
  [ -n "$stderr" ]
}

@test "cannot decide: other bad epochs (negative, zero, below ten digits, fractional, string) and bad flags" {
  oob '{"last_activity":-5}'
  oob '{"last_activity":0,"open":false}'
  oob '{"last_activity":999999999,"open":false}'
  oob '{"last_activity":1790000000.5,"open":false}'
  oob '{"last_activity":"1790000000"}'
  oob '{"last_activity":1790000000,"open":"true"}'
  oob '{"last_activity":1790000000,"open":true,"line_at":"x"}'
}

@test "cannot decide: after an out of range key the state heals: the key is dropped, other keys stay, the next prompt is gated normally" {
  at 100000; seed '{"last_activity":1e30,"open":false,"other":[1,2]}'
  hook "$(prompt_json "hello" user)"; line_is "2026-10-22 18:40 CEST"
  [ "$(sget 'has("last_activity")')" = "false" ]
  [ "$(sget '.other|tojson')" = "[1,2]" ]
  at 100030; hook "$(prompt_json "again" user)"; silent       # open, line_at just written: suppressed
}

@test "an out of range ALFRED_REPLY_TS_NOW is not used as the clock (the real date takes over)" {
  ALFRED_REPLY_TS_NOW=99999999999999999999 hook "$(prompt_json "hello" user)"
  line_is "2026-10-22 18:40 CEST"
  [ "$(wc -l <<< "$stderr")" -le 1 ]
  [ "$(sget .last_prompt | wc -c)" -eq 11 ]
}

@test "an out of range threshold (too many digits) is unreadable: the line shows" {
  at 100000
  jq '.["reply-time-idle-minutes"] = 99999999999999999999' "$ROOT/config/thresholds.json" > "$BATS_TEST_TMPDIR/thr.json"
  export ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/thr.json"
  seed_gap 60; undecided hugethreshold; [ -n "$stderr" ]
}

@test "cannot decide: unreadable state" {
  [ "$(id -u)" -ne 0 ] || skip "root reads everything"
  at 100000; seed_gap 60; chmod 000 "$SF"; undecided unreadable; [ -n "$stderr" ]
  chmod 600 "$SF"
}

@test "cannot decide: the threshold is unreadable (missing name, malformed file, no alfred-config)" {
  at 100000
  jq 'del(.["reply-time-idle-minutes"])' "$ROOT/config/thresholds.json" > "$BATS_TEST_TMPDIR/thr.json"
  export ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/thr.json"
  seed_gap 60; undecided missing; [ -n "$stderr" ]
  echo '{' > "$BATS_TEST_TMPDIR/thr.json"
  seed_gap 60; undecided malformed
  jq '.["reply-time-idle-minutes"] = "soon"' "$ROOT/config/thresholds.json" > "$BATS_TEST_TMPDIR/thr.json"
  seed_gap 60; undecided notnumber
  unset ALFRED_THRESHOLDS
  mkdir -p "$BATS_TEST_TMPDIR/p/hooks" "$BATS_TEST_TMPDIR/p/lib"
  cp "$HOOK" "$BATS_TEST_TMPDIR/p/hooks/"; cp "$ROOT"/lib/*.sh "$BATS_TEST_TMPDIR/p/lib/"
  seed_gap 60
  run --separate-stderr "$BATS_TEST_TMPDIR/p/hooks/reply-timestamp.sh" <<< "$(prompt_json "hello" user)"
  line_is "2026-10-22 18:40 CEST"
}

@test "cannot decide: the state directory is unwritable (a file stands where it should be), the line still shows" {
  at 100000
  mkdir -p "$CLAUDE_CONFIG_DIR"; echo x > "$STATE"
  undecided unwritable; [ -n "$stderr" ]
}

@test "cannot decide: a read-only state directory with fresh state still shows the line" {
  [ "$(id -u)" -ne 0 ] || skip "root writes everywhere"
  at 100000; seed_gap 60; chmod 555 "$STATE"
  undecided readonly; [ -n "$stderr" ]
  chmod 755 "$STATE"
}

@test "cannot decide: no session_id, and last activity in the future" {
  at 100000
  hook "$(jq -cn '{prompt: "hi"}')"; line_is "2026-10-22 18:40 CEST"; [ -n "$stderr" ]; [ ! -e "$STATE/.json" ]
  seed "{\"last_activity\":$((ALFRED_REPLY_TS_NOW + 600)),\"open\":false}"; undecided future
}

@test "cannot decide: no clock (date +%s prints nothing): the line is shown, nothing is stored" {
  printf '#!/usr/bin/env bash\ncase "$*" in\n  *"%%F %%H:%%M %%Z"*) echo "2026-10-22 18:40 CEST" ;;\n  *"+%%s"*) ;;\n  *) exec /usr/bin/date "$@" ;;\nesac\n' > "$BATS_TEST_TMPDIR/bin/date"
  undecided noclock; [ ! -e "$SF" ]
}

# --- AC 3: the exact text ------------------------------------------------------------------------------

@test "exact text, CEST" {
  hook "$(prompt_json "hello" user)"
  [ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" = 'Time now _[2026-10-22 18:40 CEST]_. A new set of actions starts: start your first reply of this turn with this time line. Put none on later replies until a line is injected again. If the turn runs longer than a few minutes, use a fresh TZ=Europe/Amsterdam time instead.' ]
  run ! grep -q 'Owner prompt received' <<< "$output"
}

@test "exact text, CET" {
  FAKE_DATE="2026-12-01 09:05 CET" hook "$(prompt_json "hello" user)"
  [ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" = 'Time now _[2026-12-01 09:05 CET]_. A new set of actions starts: start your first reply of this turn with this time line. Put none on later replies until a line is injected again. If the turn runs longer than a few minutes, use a fresh TZ=Europe/Amsterdam time instead.' ]
}

# --- AC 3: fail-open -----------------------------------------------------------------------------------

@test "malformed stdin: exit 0, no output" {
  hook "garbage {"
  silent
  hook ""
  silent
}

@test "missing jq: exit 0, no output" {
  nojq="$BATS_TEST_TMPDIR/nojq"; mkdir -p "$nojq"
  for t in cat dirname date; do ln -s "$(command -v "$t")" "$nojq/$t"; done
  run --separate-stderr env PATH="$nojq" "$BASH" "$HOOK" <<< "$(prompt_json "hello" user)"
  silent
}

@test "missing lib: exit 0, no output" {
  cp -r "$ROOT/hooks" "$BATS_TEST_TMPDIR/plugin-hooks"
  run --separate-stderr "$BATS_TEST_TMPDIR/plugin-hooks/reply-timestamp.sh" <<< "$(prompt_json "hello" user)"
  silent
}

# plugin_copy <owner-turn: present|absent|broken> <reply-time: present|absent|broken> — a private plugin copy
# in $BATS_TEST_TMPDIR/p with the hook and the chosen libs.
plugin_copy() {
  mkdir -p "$BATS_TEST_TMPDIR/p/hooks" "$BATS_TEST_TMPDIR/p/lib"
  cp "$HOOK" "$BATS_TEST_TMPDIR/p/hooks/"
  case "$1" in
    present) cp "$ROOT/lib/owner-turn.sh" "$BATS_TEST_TMPDIR/p/lib/" ;;
    broken) echo 'if (' > "$BATS_TEST_TMPDIR/p/lib/owner-turn.sh" ;;
  esac
  case "$2" in
    present) cp "$ROOT/lib/reply-time.sh" "$BATS_TEST_TMPDIR/p/lib/" ;;
    broken) echo 'if (' > "$BATS_TEST_TMPDIR/p/lib/reply-time.sh" ;;
  esac
}

@test "owner-turn.sh absent: the line still shows, owner false" {
  export ALFRED_REPLY_TS_LOG="$BATS_TEST_TMPDIR/ts.log"
  plugin_copy absent present
  run --separate-stderr "$BATS_TEST_TMPDIR/p/hooks/reply-timestamp.sh" <<< "$(prompt_json "hello" user)"
  line_is "2026-10-22 18:40 CEST"
  [ "$(jq -c '{owner, emitted}' "$ALFRED_REPLY_TS_LOG")" = '{"owner":false,"emitted":true}' ]
}

@test "owner-turn.sh broken: the line still shows, owner false" {
  export ALFRED_REPLY_TS_LOG="$BATS_TEST_TMPDIR/ts.log"
  plugin_copy broken present
  run --separate-stderr "$BATS_TEST_TMPDIR/p/hooks/reply-timestamp.sh" <<< "$(prompt_json "hello" user)"
  line_is "2026-10-22 18:40 CEST"
  [ "$(jq -c '{owner, emitted}' "$ALFRED_REPLY_TS_LOG")" = '{"owner":false,"emitted":true}' ]
}

@test "reply-time.sh absent: exit 0, no output" {
  plugin_copy present absent
  run --separate-stderr "$BATS_TEST_TMPDIR/p/hooks/reply-timestamp.sh" <<< "$(prompt_json "hello" user)"
  silent
}

@test "reply-time.sh broken: exit 0, no output" {
  plugin_copy present broken
  run --separate-stderr "$BATS_TEST_TMPDIR/p/hooks/reply-timestamp.sh" <<< "$(prompt_json "hello" user)"
  silent
}

# --- debug log -----------------------------------------------------------------------------------------

@test "ALFRED_REPLY_TS_LOG appends {ts, source, entrypoint, owner, emitted, gap}: gap null with no state, the seconds otherwise" {
  export ALFRED_REPLY_TS_LOG="$BATS_TEST_TMPDIR/ts.log"
  at 100000
  hook "$(prompt_json "hello" user)"
  seed_gap 120
  hook "$(prompt_json "[substrate wake] x")"
  seed_gap 7200
  hook "$(prompt_json "hello" user)"
  [ "$(wc -l < "$ALFRED_REPLY_TS_LOG")" -eq 3 ]
  [ "$(jq -sc 'map({source, entrypoint, owner, emitted, gap})' "$ALFRED_REPLY_TS_LOG")" = '[{"source":"user","entrypoint":"cli","owner":true,"emitted":true,"gap":null},{"source":"","entrypoint":"cli","owner":false,"emitted":false,"gap":120},{"source":"user","entrypoint":"cli","owner":true,"emitted":true,"gap":7200}]' ]
  [ "$(jq -r '.ts | test("^[0-9]{4}-")' < <(head -1 "$ALFRED_REPLY_TS_LOG"))" = "true" ]
}

@test "log: the worker line and the tzdata-missing line give emitted false, owner still filled" {
  export ALFRED_REPLY_TS_LOG="$BATS_TEST_TMPDIR/ts.log"
  ALFRED_ROLE=worker hook "$(prompt_json "hello" user)"
  reset
  FAKE_DATE="2026-10-22 16:40 UTC" hook "$(prompt_json "hello" user)"
  [ "$(jq -sc 'map({owner, emitted})' "$ALFRED_REPLY_TS_LOG")" = '[{"owner":false,"emitted":false},{"owner":true,"emitted":false}]' ]
}

@test "no log file is written without ALFRED_REPLY_TS_LOG" {
  mkdir "$BATS_TEST_TMPDIR/cwd"; cd "$BATS_TEST_TMPDIR/cwd"
  hook "$(prompt_json "hello" user)"
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/cwd")" ]
}

# --- AC 4: one owner-turn definition -------------------------------------------------------------------

@test "the hook and note-turn both source lib/owner-turn.sh; the list lives only there" {
  grep -q 'lib/owner-turn.sh' "$HOOK"
  grep -q 'lib/owner-turn.sh' "$ROOT/bin/alfred-loop-check"
  run ! grep -q 'substrate wake' "$HOOK"
  run ! grep -q 'substrate wake' "$ROOT/bin/alfred-loop-check"
  grep -q 'substrate wake' "$ROOT/lib/owner-turn.sh"
}

@test "lib/reply-time.sh: reply_time_stamp <epoch> with the real date" {
  [ -e /usr/share/zoneinfo/Europe/Amsterdam ] || skip "no Europe/Amsterdam tzdata"
  rm "$BATS_TEST_TMPDIR/bin/date"
  run bash -c '. "$1/lib/reply-time.sh" && reply_time_stamp 1792884600' _ "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-10-25 01:30 CEST" ]
}

@test "the wording lives only in lib/reply-time.sh; both hooks source it" {
  grep -q 'A new set of actions starts: start your first reply of this turn with this time line' "$ROOT/lib/reply-time.sh"
  run ! grep -q 'start your first reply of this turn' "$HOOK"
  run ! grep -q 'start your first reply of this turn' "$ROOT/hooks/stop.sh"
  grep -q 'lib/reply-time.sh' "$HOOK"
  grep -q 'lib/reply-time.sh' "$ROOT/hooks/stop.sh"
}

# --- AC 5: wired ---------------------------------------------------------------------------------------

@test "hooks.json: reply-timestamp.sh is a UserPromptSubmit entry with a 5 s timeout; the existing entries stay" {
  h="$ROOT/hooks/hooks.json"
  jq -e '[.hooks.UserPromptSubmit[].hooks[] | select(.command | endswith("hooks/reply-timestamp.sh\""))] | length == 1' "$h"
  jq -e '[.hooks.UserPromptSubmit[].hooks[] | select(.command | endswith("hooks/reply-timestamp.sh\"")) | .timeout] == [5]' "$h"
  jq -e '[.hooks.UserPromptSubmit[].hooks[] | select(.command | endswith("alfred-loop-check\" note-turn"))] | length == 1' "$h"
  jq -e '[.hooks.UserPromptSubmit[].hooks[] | select(.command | endswith("alfred-workitem\" hook"))] | length == 1' "$h"
}

@test "the hook script is executable and the README names it" {
  [ -x "$HOOK" ]
  grep -q 'hooks/reply-timestamp.sh' "$ROOT/README.md"
}

@test "owner-communication.md says the first reply of a set starts with the injected time line, and no other reply does" {
  md="$ROOT/hooks/owner-communication.md"
  flat=$(tr '\n' ' ' < "$md" | tr -s ' ')       # the md is wrapped; the greps read it as running text
  grep -q 'Time now' "$md"
  grep -q "only when this turn's context carries an injected \`Time now\` line (a new set of actions)" <<< "$flat"
  grep -q 'Otherwise a reply carries no time line' <<< "$flat"
  grep -qF "a fresh \`TZ=Europe/Amsterdam date '+%F %H:%M %Z'\` reading" <<< "$flat"
  grep -q 'never a guessed one' <<< "$flat"
  run ! grep -q 'wake replies included' "$md"
  run ! grep -qi 'continuation' "$md"
  grep -q 'A reply to a wake turn is still a chat reply the owner reads' "$md"
  grep -q 'A wake with no news produces no reply at all' "$md"
  run ! grep -q 'Owner prompt received' "$md"
  run ! grep -q 'Take the time fresh for each reply' "$md"
}

@test "owner-communication.md names reply-time-idle-minutes and carries no literal 15" {
  md="$ROOT/hooks/owner-communication.md"
  grep -q 'reply-time-idle-minutes' "$md"
  run ! grep -q '15' "$md"
}

@test "README describes the idle-gated line, names lib/reply-time.sh, the threshold and the state directory" {
  r="$ROOT/README.md"
  grep -q 'lib/reply-time.sh' "$r"
  grep -q 'reply-time-idle-minutes' "$r"
  grep -q 'alfred-reply-ts/' "$r"
  grep -q 'that carries it' "$r"
  run ! grep -q 'every owner prompt' "$r"
  run ! grep -q 'at the top of each chat reply' "$r"
  run ! grep -q 'puts the same line at the head of its block reason' "$r"
}

@test "the injected text and the template carry no literal 15; the rendered text carries none with a fixed stamp" {
  tmpl=$(grep -F 'Time now _[%s]_' "$ROOT/lib/reply-time.sh")
  [ -n "$tmpl" ]
  run ! grep -q '15' <<< "$tmpl"
  at 100000
  hook "$(prompt_json "hello" user)"        # fake date: 2026-10-22 18:40 CEST
  line_is "2026-10-22 18:40 CEST"
  run ! grep -q '15' <<< "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")"
}

# --- CCW-184: rule text, README, baseline doc and lib header greps ---------------------------------------

@test "rule text: owner-communication.md states the accuracy rule and names the threshold, no literal number" {
  f="$ROOT/hooks/owner-communication.md"
  txt=$(tr '\n' ' ' < "$f" | tr -s ' ')
  [[ "$txt" == *"never estimated, extrapolated or carried over from an earlier turn or reading"* ]]
  [[ "$txt" == *"no older than the tolerance (\`reply-time-tolerance-minutes\`)"* ]]
  [[ "$txt" == *"A Stop-hook check compares the time line with the clock and flags a wrong one once per turn"* ]]
  [[ "$txt" == *"never a guessed one"* && "$txt" == *"A wake with no news produces no reply at all"* ]]
  bullet=$(awk '/^- A reply starts/ {f=1} /^- Show the owner/ {f=0} f' "$f" | sed 's/2026-10-12 08:30//')
  [ -n "$bullet" ]
  ! grep -qE '[0-9]' <<< "$bullet"
}

@test "README: names the script, the state directory, the switch with its exact value, the threshold, the limits and the arithmetic" {
  r=$(tr '\n' ' ' < "$ROOT/README.md" | tr -s ' ')
  for s in 'hooks/reply-audit.sh' 'alfred-reply-ts/' 'ALFRED_REPLY_TS_AUDIT=0' 'only the exact value `0`' 'reply-time-tolerance-minutes' \
           'an interrupted turn (no Stop recorded) leaves its epoch in the list' 'a Stop that blocks leaves the stored `open` false' \
           'a long turn may end with its first injected time' 'a time read at 07:20:58' 'third part of the Stop entry' \
           '(19 s)' '<bridge|loop|audit> part gave unusable output, ignored' '<bridge|loop|audit> part timed out, stop allowed'; do
    [[ "$r" == *"$s"* ]] || { echo "README lacks: $s"; return 1; }
  done
  [[ "$r" != *"never flags"* ]]
}

@test "baseline doc: the audit section is there and the CCW-180 'neither read nor written here' sentence is gone" {
  f="$ROOT/docs/baseline/reply-time-line.md"
  txt=$(tr '\n' ' ' < "$f" | tr -s ' ')
  run ! grep -q 'neither' "$f"
  run ! grep -q 'read nor written here' <<< "$txt"
  run ! grep -qi 'reserved for CCW-184' "$f"
  for s in '## Stamp audit' '| `injected` |' '| `flagged` |' 'Restart rule.' 'Limits (also in the README)' 'reply-time-tolerance-minutes' 'ALFRED_REPLY_TS_AUDIT=0' \
           'An interrupted turn (no Stop recorded)' 'Late-reading window' 'bounded (10 polls of 0.1 s'; do
    [[ "$txt" == *"$s"* ]] || { echo "baseline lacks: $s"; return 1; }
  done
}

@test "lib: the Reserved-for-CCW-184 comment is replaced, the audit's keys are declared once in the header" {
  f="$ROOT/lib/reply-time.sh"
  run ! grep -qi 'Reserved for CCW-184' "$f"
  run ! grep -q 'neither read nor written here' "$f"
  [ "$(grep -c '^#   injected  ' "$f")" -eq 1 ]
  [ "$(grep -c '^#   flagged  ' "$f")" -eq 1 ]
}
