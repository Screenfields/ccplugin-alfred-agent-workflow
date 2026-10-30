#!/usr/bin/env bats
# hooks/reply-timestamp.sh, lib/reply-time.sh and lib/owner-turn.sh (CCW-141,
# CCW-180): the Europe/Amsterdam time line injected on every prompt. `date` is replaced by a fake on PATH
# (FAKE_DATE is what it prints for the TZ format). No network, no model call.
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
  unset ALFRED_ROLE ALFRED_REPLY_TS_LOG CLAUDE_CODE_ENTRYPOINT
  export CLAUDE_CODE_ENTRYPOINT=cli
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
  [ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" = "Time now _[$1]_. Start your reply with this time line; if the turn runs longer than a few minutes, use a fresh TZ=Europe/Amsterdam time instead." ]
}

# --- AC 1: every non-worker prompt gets the line ---------------------------------------------------------------

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
    echo "$ep"
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

# --- AC 1 (continued): machine turns get the line too -------------------------------------------------

@test "sdk-cli entrypoint: the line" {
  CLAUDE_CODE_ENTRYPOINT=sdk-cli hook "$(prompt_json "hello" user)"
  line_is "2026-10-22 18:40 CEST"
}

@test "unset entrypoint: the line" {
  unset CLAUDE_CODE_ENTRYPOINT
  hook "$(prompt_json "hello" user)"
  line_is "2026-10-22 18:40 CEST"
}

@test "source system, loop_wakeup, schedule_wakeup, poll_event: the line" {
  for src in system loop_wakeup schedule_wakeup poll_event; do
    echo "$src"
    hook "$(prompt_json "hello" "$src")"
    line_is "2026-10-22 18:40 CEST"
  done
}

@test "machine prefix <task-notification>: the line" {
  hook "$(prompt_json "<task-notification>x" user)"; line_is "2026-10-22 18:40 CEST"
}

@test "machine prefix <cross-session-message: the line" {
  hook "$(prompt_json "<cross-session-message from=hub>" user)"; line_is "2026-10-22 18:40 CEST"
}

@test "machine prefix [substrate wake]: the line" {
  hook "$(prompt_json "[substrate wake] new mail" user)"; line_is "2026-10-22 18:40 CEST"
}

@test "machine prefix <scheduled-task: the line" {
  hook "$(prompt_json "<scheduled-task>" user)"; line_is "2026-10-22 18:40 CEST"
}

@test "machine prefix [scheduled-task: the line" {
  hook "$(prompt_json "[scheduled-task] x" user)"; line_is "2026-10-22 18:40 CEST"
}

@test "a machine prefix after leading whitespace: the line" {
  hook "$(prompt_json $'  \n[substrate wake] x' user)"; line_is "2026-10-22 18:40 CEST"
}

@test "source absent plus a machine prefix: the line" {
  hook "$(prompt_json "[substrate wake] x")"; line_is "2026-10-22 18:40 CEST"
}

@test "empty and whitespace-only prompts: the line" {
  hook "$(prompt_json "" user)"; line_is "2026-10-22 18:40 CEST"
  hook "$(prompt_json "   " user)"; line_is "2026-10-22 18:40 CEST"
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

# --- AC 3: the exact text ------------------------------------------------------------------------------

@test "exact text, CEST" {
  hook "$(prompt_json "hello" user)"
  [ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" = 'Time now _[2026-10-22 18:40 CEST]_. Start your reply with this time line; if the turn runs longer than a few minutes, use a fresh TZ=Europe/Amsterdam time instead.' ]
  run ! grep -q 'Owner prompt received' <<< "$output"
}

@test "exact text, CET" {
  FAKE_DATE="2026-12-01 09:05 CET" hook "$(prompt_json "hello" user)"
  [ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" = 'Time now _[2026-12-01 09:05 CET]_. Start your reply with this time line; if the turn runs longer than a few minutes, use a fresh TZ=Europe/Amsterdam time instead.' ]
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

@test "ALFRED_REPLY_TS_LOG appends {ts, source, entrypoint, owner, emitted} for owner and machine turns" {
  export ALFRED_REPLY_TS_LOG="$BATS_TEST_TMPDIR/ts.log"
  hook "$(prompt_json "hello" user)"
  hook "$(prompt_json "[substrate wake] x")"
  [ "$(wc -l < "$ALFRED_REPLY_TS_LOG")" -eq 2 ]
  [ "$(jq -sc 'map({source, entrypoint, owner, emitted})' "$ALFRED_REPLY_TS_LOG")" = '[{"source":"user","entrypoint":"cli","owner":true,"emitted":true},{"source":"","entrypoint":"cli","owner":false,"emitted":true}]' ]
  [ "$(jq -r '.ts | test("^[0-9]{4}-")' < <(head -1 "$ALFRED_REPLY_TS_LOG"))" = "true" ]
}

@test "log: the worker line and the tzdata-missing line give emitted false, owner still filled" {
  export ALFRED_REPLY_TS_LOG="$BATS_TEST_TMPDIR/ts.log"
  ALFRED_ROLE=worker hook "$(prompt_json "hello" user)"
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
  grep -q 'Start your reply with this time line' "$ROOT/lib/reply-time.sh"
  run ! grep -q 'Start your reply with this time line' "$HOOK"
  run ! grep -q 'Start your reply with this time line' "$ROOT/hooks/stop.sh"
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

@test "owner-communication.md says every reply starts with the injected time line, wake replies included" {
  md="$ROOT/hooks/owner-communication.md"
  grep -q 'Time now' "$md"
  grep -q 'wake replies included' "$md"
  grep -q 'A reply to a wake turn is still a chat reply the owner reads' "$md"
  grep -q 'A wake with no news produces no reply at all' "$md"
  run ! grep -q 'Owner prompt received' "$md"
  run ! grep -q 'Take the time fresh for each reply' "$md"
}

@test "README describes the per-prompt line for every prompt and names lib/reply-time.sh" {
  grep -q 'lib/reply-time.sh' "$ROOT/README.md"
  run ! grep -q 'every owner prompt' "$ROOT/README.md"
}
