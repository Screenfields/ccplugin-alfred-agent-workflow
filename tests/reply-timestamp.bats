#!/usr/bin/env bats
# hooks/reply-timestamp.sh and lib/owner-turn.sh (CCW-141): the Europe/Amsterdam
# time line injected on owner prompts. `date` is replaced by a fake on PATH
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
  [ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" = "Owner prompt received at _[$1]_. Start your reply with this time line; if the turn runs longer than a few minutes, use a fresh TZ=Europe/Amsterdam time instead." ]
}

# --- AC 1: an owner prompt gets the line ---------------------------------------------------------------

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

# --- AC 2: no line on machine turns --------------------------------------------------------------------

@test "sdk-cli entrypoint: no output" {
  CLAUDE_CODE_ENTRYPOINT=sdk-cli hook "$(prompt_json "hello" user)"
  silent
}

@test "unset entrypoint: no output" {
  unset CLAUDE_CODE_ENTRYPOINT
  hook "$(prompt_json "hello" user)"
  silent
}

@test "source system: no output" {
  hook "$(prompt_json "hello" system)"; silent
}

@test "source loop_wakeup: no output" {
  hook "$(prompt_json "hello" loop_wakeup)"; silent
}

@test "source schedule_wakeup: no output" {
  hook "$(prompt_json "hello" schedule_wakeup)"; silent
}

@test "source poll_event: no output" {
  hook "$(prompt_json "hello" poll_event)"; silent
}

@test "machine prefix <task-notification>: no output" {
  hook "$(prompt_json "<task-notification>x" user)"; silent
}

@test "machine prefix <cross-session-message: no output" {
  hook "$(prompt_json "<cross-session-message from=hub>" user)"; silent
}

@test "machine prefix [substrate wake]: no output" {
  hook "$(prompt_json "[substrate wake] new mail" user)"; silent
}

@test "machine prefix <scheduled-task: no output" {
  hook "$(prompt_json "<scheduled-task>" user)"; silent
}

@test "machine prefix [scheduled-task: no output" {
  hook "$(prompt_json "[scheduled-task] x" user)"; silent
}

@test "a machine prefix after leading whitespace: no output" {
  hook "$(prompt_json $'  \n[substrate wake] x' user)"; silent
}

@test "ALFRED_ROLE=worker: no output" {
  ALFRED_ROLE=worker hook "$(prompt_json "hello" user)"; silent
}

@test "empty and whitespace-only prompts: no output" {
  hook "$(prompt_json "" user)"; silent
  hook "$(prompt_json "   " user)"; silent
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

@test "a lib that fails to source: exit 0, no output" {
  mkdir -p "$BATS_TEST_TMPDIR/p/hooks" "$BATS_TEST_TMPDIR/p/lib"
  cp "$HOOK" "$BATS_TEST_TMPDIR/p/hooks/"
  echo 'if (' > "$BATS_TEST_TMPDIR/p/lib/owner-turn.sh"
  run --separate-stderr "$BATS_TEST_TMPDIR/p/hooks/reply-timestamp.sh" <<< "$(prompt_json "hello" user)"
  silent
}

# --- debug log -----------------------------------------------------------------------------------------

@test "ALFRED_REPLY_TS_LOG appends {ts, source, entrypoint, owner} for owner and machine turns" {
  export ALFRED_REPLY_TS_LOG="$BATS_TEST_TMPDIR/ts.log"
  hook "$(prompt_json "hello" user)"
  hook "$(prompt_json "[substrate wake] x")"
  [ "$(wc -l < "$ALFRED_REPLY_TS_LOG")" -eq 2 ]
  [ "$(jq -sc 'map({source, entrypoint, owner})' "$ALFRED_REPLY_TS_LOG")" = '[{"source":"user","entrypoint":"cli","owner":true},{"source":"","entrypoint":"cli","owner":false}]' ]
  [ "$(jq -r '.ts | test("^[0-9]{4}-")' < <(head -1 "$ALFRED_REPLY_TS_LOG"))" = "true" ]
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

@test "owner-communication.md says the time line is injected" {
  grep -q 'injected line' "$ROOT/hooks/owner-communication.md"
  run ! grep -q 'Take the time fresh for each reply' "$ROOT/hooks/owner-communication.md"
}
