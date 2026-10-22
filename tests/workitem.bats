#!/usr/bin/env bats
# Behaviour tests for bin/alfred-workitem (ccplugin#126, token counting per
# work item on the central agent-run store). The store is replaced by
# tests/stub/curl-workitem (records POST bodies, serves /workitems fixtures
# from tests/fixtures/workitem/); gh and `alfred-wake notify` are stubbed too.
# Transcripts are small synthetic files built here, never copies of real ones.

setup() {
  WI="$BATS_TEST_DIRNAME/../bin/alfred-workitem"
  FIX="$BATS_TEST_DIRNAME/fixtures/workitem"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  mkdir -p "$STUB_DIR" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/repo"
  ln -s "$BATS_TEST_DIRNAME/stub/curl-workitem" "$BATS_TEST_TMPDIR/bin/curl"
  ln -s "$BATS_TEST_DIRNAME/stub/gh-workitem" "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export ALFRED_WORKITEM_WAKE="$BATS_TEST_DIRNAME/stub/notify-workitem"
  export AGENT_RUNS_OTLP_LOGS_ENDPOINT="http://store.invalid/v1/logs"
  export AGENT_RUNS_OTLP_HEADERS="X-Scope-OrgID: acme, Authorization: Bearer otlp-secret"
  export AGENT_RUNS_READER_URL="http://reader.invalid"
  export AGENT_RUNS_TOKEN="reader-token"
  export CLAUDE_CODE_SESSION_ID="sess-main"
  cp "$FIX/workitems.json" "$STUB_DIR/workitems.json"
  cd "$BATS_TEST_TMPDIR/repo" || return 1
  git init -q .
  DIR="$CLAUDE_CONFIG_DIR/alfred-workitem"
}

# --- helpers -----------------------------------------------------------------

# hook_in <json> — run `alfred-workitem hook` with that stdin.
hook_in() { printf '%s' "$1" | "$WI" hook; }

# ev <event> <sid> [extra-jq-object] — a hook input.
ev() { jq -cn --arg e "$1" --arg s "$2" --arg c "$PWD" --argjson x "${3:-{\}}" \
  '{hook_event_name: $e, session_id: $s, cwd: $c} + $x'; }

# transcript <file> <brief> <n-ids> [id-prefix] — a synthetic subagent transcript.
transcript() {
  local f="$1" brief="$2" n="$3" p="${4:-req}" i
  jq -cn --arg b "$brief" '{type: "user", message: {role: "user", content: $b}}' > "$f"
  for ((i = 1; i <= n; i++)); do
    # two lines per request id: streamed lines share a requestId
    jq -cn --arg r "$p-$i" '{type: "assistant", requestId: $r, message: {role: "assistant", content: [{type: "text", text: "x"}]}}' >> "$f"
    jq -cn --arg r "$p-$i" '{type: "assistant", requestId: $r, message: {role: "assistant", content: [{type: "tool_use", id: "t", name: "Bash", input: {}}]}}' >> "$f"
  done
}

posts() { cat "$STUB_DIR/posts.jsonl" 2>/dev/null; }
attr() { jq -r --arg k "$1" '.resourceLogs[0].scopeLogs[0].logRecords[0].attributes[] | select(.key == $k) | .value.stringValue'; }
nposts() { posts | wc -l | tr -d ' '; }
mark_item() { jq -r '.item' "$DIR/sess-main.json"; }

# --- AC marker shape ------------------------------------------------------------

@test "mark sends an OTLP/HTTP JSON log record with the agreed attributes and headers" {
  run "$WI" mark acme/widgets#7
  [ "$status" -eq 0 ]
  [ "$(nposts)" -eq 1 ]
  body=$(posts)
  [ "$(jq -r '.resourceLogs | length' <<<"$body")" -eq 1 ]
  [ "$(jq -r '.resourceLogs[0].scopeLogs[0].logRecords | length' <<<"$body")" -eq 1 ]
  [ "$(attr event.name <<<"$body")" = "work_item" ]
  [ "$(attr session.id <<<"$body")" = "sess-main" ]
  [ "$(attr work_item <<<"$body")" = "acme/widgets#7" ]
  [[ "$(attr event.timestamp <<<"$body")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  # no request_ids on a session marker
  [ "$(jq -r '[.resourceLogs[0].scopeLogs[0].logRecords[0].attributes[].key] | index("request_ids")' <<<"$body")" = "null" ]
  grep -q '^POST http://store.invalid/v1/logs$' "$STUB_DIR/calls.log"
  grep -q 'Content-Type: application/json' "$STUB_DIR/headers.log"
  grep -q 'X-Scope-OrgID: acme' "$STUB_DIR/headers.log"
  grep -q 'Authorization: Bearer otlp-secret' "$STUB_DIR/headers.log"
}

@test "AGENT_RUNS_OTLP_HEADERS accepts the Name: value form (a value may hold = and :)" {
  export AGENT_RUNS_OTLP_HEADERS="X-Scope-OrgID: acme, Authorization: Basic YWJj==, X-Url: http://a/b?c=d"
  run "$WI" mark acme/widgets#7
  [ "$status" -eq 0 ]
  grep -qx 'header = "X-Scope-OrgID: acme"' "$STUB_DIR/headers.log"
  grep -qx 'header = "Authorization: Basic YWJj=="' "$STUB_DIR/headers.log"
  grep -qx 'header = "X-Url: http://a/b?c=d"' "$STUB_DIR/headers.log"
}

@test "AGENT_RUNS_OTLP_HEADERS accepts the OTLP key=value form" {
  export AGENT_RUNS_OTLP_HEADERS="x-scope-orgid=acme,authorization=Bearer abc=="
  run "$WI" mark acme/widgets#7
  [ "$status" -eq 0 ]
  grep -qx 'header = "x-scope-orgid: acme"' "$STUB_DIR/headers.log"
  grep -qx 'header = "authorization: Bearer abc=="' "$STUB_DIR/headers.log"
}

@test "the curl config with the secrets is removed after every call, failed or not" {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  "$WI" mark acme/widgets#7
  touch "$STUB_DIR/fail"
  "$WI" mark acme/widgets#7
  "$WI" check acme/widgets#7
  echo 6 > "$STUB_DIR/slow"; rm "$STUB_DIR/fail"
  timeout -s TERM 1 "$WI" line acme/widgets#7 || true
  sleep 0.5
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "check exits 0 even on a usage error, with a warning" {
  run "$WI" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage error; nothing checked"* ]]
  run "$WI" check not-an-item
  [ "$status" -eq 0 ]
}

@test "a held deviations lock times out and fails open: the Stop hook exits 0, nothing written" {
  mkdir -p "$DIR"
  ( flock 9; sleep 5 ) 9>"$DIR/deviations.jsonl.lock" &
  holder=$!
  sleep 0.3
  start=$SECONDS
  run hook_in "$(ev Stop sess-unmarked)"
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -lt 4 ]
  [[ "$output" == *"locked"* ]]
  [ ! -e "$DIR/deviations.jsonl" ]
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

@test "the marker bodies equal the shared fixtures exactly (session marker, and with request_ids)" {
  export ALFRED_WORKITEM_NOW=2026-10-22T08:00:00Z
  export CLAUDE_CODE_SESSION_ID=11111111-1111-4111-8111-111111111111
  "$WI" mark acme/widgets#7
  f="$BATS_TEST_TMPDIR/agent.jsonl"
  jq -cn '{type:"user",message:{role:"user",content:"Work item: acme/other#9"}}' > "$f"
  for i in 1 2 3; do jq -cn --arg r "req-$i" '{type:"assistant",requestId:$r,message:{role:"assistant",content:[]}}' >> "$f"; done
  hook_in "$(jq -cn --arg p "$f" '{hook_event_name:"SubagentStop",session_id:env.CLAUDE_CODE_SESSION_ID,agent_id:"a1",agent_transcript_path:$p}')"
  [ "$(nposts)" -eq 2 ]
  [ "$(posts | sed -n 1p)" = "$(jq -c . "$FIX/marker-session.json")" ]
  [ "$(posts | sed -n 2p)" = "$(jq -c . "$FIX/marker-request-ids.json")" ]
}

@test "mark none clears: work_item is the empty string" {
  "$WI" mark acme/widgets#7
  run "$WI" mark none
  [ "$status" -eq 0 ]
  [ "$(nposts)" -eq 2 ]
  last=$(posts | tail -1)
  [ "$(attr work_item <<<"$last")" = "" ]
  [ "$(jq -r '.item' "$DIR/sess-main.json")" = "" ]
}

@test "mark rejects a malformed item with usage and exit 2" {
  run "$WI" mark widgets-7
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_DIR/posts.jsonl" ]
}

# --- request_ids chunking ----------------------------------------------------------

@test "a briefed subagent sends its request ids in records of at most 500" {
  transcript "$BATS_TEST_TMPDIR/agent.jsonl" "Do the thing. Work item: acme/other#9" 1203
  hook_in "$(ev SubagentStop sess-main "$(jq -cn --arg p "$BATS_TEST_TMPDIR/agent.jsonl" '{agent_id: "a1", agent_transcript_path: $p}')")"
  [ "$(nposts)" -eq 3 ]
  [ "$(posts | sed -n 1p | attr request_ids | tr ',' '\n' | wc -l)" -eq 500 ]
  [ "$(posts | sed -n 2p | attr request_ids | tr ',' '\n' | wc -l)" -eq 500 ]
  [ "$(posts | sed -n 3p | attr request_ids | tr ',' '\n' | wc -l)" -eq 203 ]
  [ "$(posts | sed -n 1p | attr work_item)" = "acme/other#9" ]
  [ "$(posts | sed -n 1p | attr request_ids | cut -d, -f1)" = "req-1" ]
  # distinct ids: the two streamed lines per request count once
  [ "$(posts | jq -r '.resourceLogs[0].scopeLogs[0].logRecords[0].attributes[] | select(.key=="request_ids") | .value.stringValue' | tr ',' '\n' | sort -u | wc -l)" -eq 1203 ]
}

@test "a subagent whose brief has no Work item token sends nothing" {
  transcript "$BATS_TEST_TMPDIR/agent.jsonl" "Just review the diff." 4
  hook_in "$(ev SubagentStop sess-main "$(jq -cn --arg p "$BATS_TEST_TMPDIR/agent.jsonl" '{agent_id: "a1", agent_transcript_path: $p}')")"
  [ ! -e "$STUB_DIR/posts.jsonl" ]
}

@test "the brief is read from a content array and the token may sit anywhere in it" {
  f="$BATS_TEST_TMPDIR/agent.jsonl"
  jq -cn '{type: "user", message: {role: "user", content: [{type: "text", text: "intro"}, {type: "text", text: "line\nWork item: acme/widgets#12\nmore"}]}}' > "$f"
  jq -cn '{type: "assistant", requestId: "r1", message: {role: "assistant", content: []}}' >> "$f"
  hook_in "$(ev SubagentStop sess-main "$(jq -cn --arg p "$f" '{agent_id: "a1", agent_transcript_path: $p}')")"
  [ "$(nposts)" -eq 1 ]
  [ "$(posts | attr work_item)" = "acme/widgets#12" ]
  [ "$(posts | attr request_ids)" = "r1" ]
}

@test "check sends only the override ids added since the last send" {
  f="$BATS_TEST_TMPDIR/agent.jsonl"
  transcript "$f" "Work item: acme/other#9" 3
  hook_in "$(ev SubagentStop sess-main "$(jq -cn --arg p "$f" '{agent_id: "a1", agent_transcript_path: $p}')")"
  [ "$(nposts)" -eq 1 ]
  [ "$(jq -r '.agents.a1.sent' "$DIR/sess-main.state.json")" -eq 3 ]
  transcript "$f" "Work item: acme/other#9" 5
  run "$WI" check acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [ "$(nposts)" -eq 2 ]
  [ "$(posts | tail -1 | attr request_ids)" = "req-4,req-5" ]
  [ "$(jq -r '.agents.a1.sent' "$DIR/sess-main.state.json")" -eq 5 ]
  # nothing new: nothing more is sent
  run "$WI" check acme/widgets#7 --estimate 12M
  [ "$(nposts)" -eq 2 ]
}

# --- subagent guard -------------------------------------------------------------------

@test "guard denies alfred-workitem mark when the hook input carries agent_id" {
  input=$(jq -cn '{hook_event_name: "PreToolUse", session_id: "sess-main", agent_id: "a1", tool_name: "Bash",
    tool_input: {command: "alfred-workitem mark acme/widgets#7"}}')
  run bash -c 'printf "%s" "$1" | "$2" guard' _ "$input" "$WI"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "guard also denies the path spelling, and allows mark in the main session" {
  input=$(jq -cn '{hook_event_name: "PreToolUse", agent_id: "a1", tool_name: "Bash",
    tool_input: {command: "cd x && /p/bin/alfred-workitem mark none"}}')
  run bash -c 'printf "%s" "$1" | "$2" guard' _ "$input" "$WI"
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
  input=$(jq -cn '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "alfred-workitem mark acme/widgets#7"}}')
  run bash -c 'printf "%s" "$1" | "$2" guard' _ "$input" "$WI"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard lets a subagent run other commands, including check and report" {
  input=$(jq -cn '{hook_event_name: "PreToolUse", agent_id: "a1", tool_name: "Bash",
    tool_input: {command: "alfred-workitem check acme/widgets#7"}}')
  run bash -c 'printf "%s" "$1" | "$2" guard' _ "$input" "$WI"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- fail open -----------------------------------------------------------------------------

@test "fail open on a 500: mark, hooks, check, report and line all exit 0 and warn" {
  touch "$STUB_DIR/fail"
  run "$WI" mark acme/widgets#7
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker POST failed (http 500)"* ]]
  [ -e "$DIR/sess-main.json" ]
  run "$WI" check acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [[ "$output" == *"actual unknown"* ]]
  run "$WI" report acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [[ "$output" == *"Actual: unknown"* ]]
  run "$WI" line acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [[ "$output" == *"actual unknown"* ]]
  run hook_in "$(ev SessionStart sess-main '{"source":"resume"}')"
  [ "$status" -eq 0 ]
}

@test "fail open on a timeout: mark returns after the 2 s limit with exit 0" {
  echo 6 > "$STUB_DIR/slow"
  start=$SECONDS
  run "$WI" mark acme/widgets#7
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -lt 5 ]
  [[ "$output" == *"marker POST failed (http 000)"* ]]
  run "$WI" line acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [[ "$output" == *"actual unknown"* ]]
}

@test "fail open with the store env missing" {
  unset AGENT_RUNS_OTLP_LOGS_ENDPOINT AGENT_RUNS_OTLP_HEADERS AGENT_RUNS_READER_URL AGENT_RUNS_TOKEN
  run "$WI" mark acme/widgets#7
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGENT_RUNS_OTLP_LOGS_ENDPOINT not set"* ]]
  [ "$(mark_item)" = "acme/widgets#7" ]
  for sub in check report line; do
    run "$WI" "$sub" acme/widgets#7 --estimate 12M
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown"* ]]
  done
  run "$WI" deviations
  [ "$status" -eq 0 ]
  run grep -E "^(GET|POST) " "$STUB_DIR/calls.log"; [ "$status" -eq 1 ]
}

@test "fail open on bad JSON from the store" {
  echo 'not json' > "$STUB_DIR/workitems.json"
  run "$WI" line acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [[ "$output" == *"actual unknown"* ]]
}

# --- report / line / check ---------------------------------------------------------------

@test "report: role x model rows, all token types, totals with and without cache reads" {
  run "$WI" report acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  # main row (no .alfred/config.json in the repo: level "session")
  [[ "$output" == *"| main (session) | claude-opus-x | 5 | 600 | 1200 | 60000 | 4000 | 65800 | 5800 | 1 |"* ]]
  [[ "$output" == *"| builder | claude-sonnet-x | 7 | 400 | 800 | 30000 | 3000 | 34200 | 4200 | 0.5 |"* ]]
  # totals: 1000+2000+90000+7000 = 100000 with cache reads; 10000 without
  [[ "$output" == *"**100000** with cache reads, **10000** without cache reads"* ]]
  [[ "$output" == *"input 1000, output 2000, cache_read 90000, cache_write 7000"* ]]
  grep -q 'work_item=acme%2Fwidgets%237' "$STUB_DIR/calls.log"
  grep -q 'Authorization: Bearer reader-token' "$STUB_DIR/headers.log"
}

@test "report shows main as the session's level from .alfred/config.json" {
  mkdir .alfred
  echo '{"agent_id": "alfred-cc-tools"}' > .alfred/config.json
  run "$WI" report acme/widgets#7 --estimate 12M
  [[ "$output" == *"| main (lead) | claude-opus-x |"* ]]
  echo '{"agent_id": "hub"}' > .alfred/config.json
  run "$WI" report acme/widgets#7 --estimate 12M
  [[ "$output" == *"| main (hub) | claude-opus-x |"* ]]
}

@test "report falls back to separate role and model tables when the store cannot cross them" {
  cp "$FIX/workitems-uncrossed.json" "$STUB_DIR/workitems.json"
  run "$WI" report acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot be crossed"* ]]
  [[ "$output" == *"| main (session) | 5 | 600 | 1200 | 60000 | 4000 | 65800 | 5800 | 1 |"* ]]
  [[ "$output" == *"| claude-opus-x | 12 | 1000 | 2000 | 90000 | 7000 | 100000 | 10000 | 1.5 |"* ]]
}

@test "report for an item the store has no usage for says so" {
  cp "$FIX/workitems-empty.json" "$STUB_DIR/workitems.json"
  run "$WI" report acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [[ "$output" == *"No usage recorded for acme/widgets#7"* ]]
}

@test "line: actual against estimate with the percentage, estimate shown as given" {
  run "$WI" line acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [ "$output" = "acme/widgets#7: actual 100000 tokens all types (10000 without cache reads; input 1000, output 2000, cache_read 90000, cache_write 7000) vs estimate 12M: 0.8% of it with all types, 0.1% without cache reads" ]
}

@test "check is a report: exit 0 whether under or over the estimate, nothing notified" {
  run "$WI" check acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [[ "$output" == *"a report, nothing is stopped"* ]]
  [[ "$output" == *"actual: 100000 tokens (all types) / 10000 tokens (without cache reads)"* ]]
  [[ "$output" == *"estimate: 12M (as given); actual is 0.8% of it with all types, 0.1% without cache reads"* ]]
  # far over the estimate: still exit 0
  run "$WI" check acme/widgets#7 --estimate 1k
  [ "$status" -eq 0 ]
  [[ "$output" == *"actual is 10000.0% of it with all types, 1000.0% without cache reads"* ]]
  [ ! -e "$STUB_DIR/notify.jsonl" ]
  # no exit-3 path and no unit constant in the script
  run grep -E 'exit 3|UNIT=|noncache|checked unit' "$WI"; [ "$status" -eq 1 ]
}

@test "check without any estimate still reports the actual" {
  run "$WI" check acme/widgets#7
  [ "$status" -eq 0 ]
  [[ "$output" == *"estimate: none"* ]]
  [[ "$output" == *"actual: 100000 tokens"* ]]
}

@test "the Estimate-tokens line is read from the issue once at mark and shown as given" {
  cp "$FIX/issue-body.txt" "$STUB_DIR/issue-body.txt"
  run "$WI" mark acme/widgets#7
  [ "$status" -eq 0 ]
  [[ "$output" == *"(estimate: 12M)"* ]]
  [ "$(jq -r '.estimate' "$DIR/sess-main.json")" = "12M" ]
  grep -q '^gh issue view 7 -R acme/widgets' "$STUB_DIR/calls.log"
  : > "$STUB_DIR/calls.log"
  # check uses the cached estimate: no second gh call
  run "$WI" check acme/widgets#7
  [[ "$output" == *"estimate: 12M (as given)"* ]]
  run grep '^gh ' "$STUB_DIR/calls.log"; [ "$status" -eq 1 ]
}

@test "the estimate text is kept verbatim, whatever follows the number" {
  printf 'Estimate-tokens: 12M (non-cache-read)\n' > "$STUB_DIR/issue-body.txt"
  "$WI" mark acme/widgets#7
  [ "$(jq -r '.estimate' "$DIR/sess-main.json")" = "12M (non-cache-read)" ]
  run "$WI" line acme/widgets#7
  [[ "$output" == *"vs estimate 12M (non-cache-read): 0.8%"* ]]
}

@test "no Estimate-tokens line, or an unreadable issue: estimate is null" {
  printf 'No estimate here.\n' > "$STUB_DIR/issue-body.txt"
  "$WI" mark acme/widgets#7
  [ "$(jq -r '.estimate' "$DIR/sess-main.json")" = "null" ]
  rm "$STUB_DIR/issue-body.txt"
  "$WI" mark acme/other#9
  [ "$(jq -r '.estimate' "$DIR/sess-main.json")" = "null" ]
}

# --- local state, deviations -------------------------------------------------------------------

@test "AC4: nothing is written into the repository after a mark" {
  "$WI" mark acme/widgets#7
  [ -z "$(git status --porcelain)" ]
  [ -e "$DIR/sess-main.json" ]
  hook_in "$(ev Stop sess-other)"
  [ -z "$(git status --porcelain)" ]
}

@test "Stop with no mark file records the session once, silently, and keeps first and last" {
  run hook_in "$(ev Stop sess-unmarked)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(wc -l < "$DIR/deviations.jsonl")" -eq 1 ]
  [ "$(jq -r '.session_id' "$DIR/deviations.jsonl")" = "sess-unmarked" ]
  first=$(jq -r '.first_unmarked_at' "$DIR/deviations.jsonl")
  [[ "$first" =~ Z$ ]]
  sleep 1.1
  hook_in "$(ev Stop sess-unmarked)"
  [ "$(wc -l < "$DIR/deviations.jsonl")" -eq 1 ]
  [ "$(jq -r '.first_unmarked_at' "$DIR/deviations.jsonl")" = "$first" ]
  [ "$(jq -r '.last_seen_at' "$DIR/deviations.jsonl")" != "$first" ]
}

@test "Stop in a marked session records nothing" {
  "$WI" mark acme/widgets#7
  run hook_in "$(ev Stop sess-main)"
  [ "$status" -eq 0 ]
  [ ! -e "$DIR/deviations.jsonl" ]
}

@test "deviations lists the unmarked session from the local record, with store amounts" {
  hook_in "$(ev Stop sess-unmarked)"
  hook_in "$(ev Stop sess-lonely)"
  run "$WI" deviations
  [ "$status" -eq 0 ]
  [[ "$output" == *"session sess-unmarked  first "* ]]
  [[ "$output" == *"requests 3, tokens 370 all types, cost_usd 0.25"* ]]
  [[ "$output" == *"session sess-lonely  first "* ]]
  [[ "$output" == *"tokens unknown (no store amount)"* ]]
}

@test "deviations works with no network: the local list still prints" {
  hook_in "$(ev Stop sess-unmarked)"
  touch "$STUB_DIR/fail"
  run "$WI" deviations
  [ "$status" -eq 0 ]
  [[ "$output" == *"session sess-unmarked"* ]]
  [[ "$output" == *"tokens unknown"* ]]
}

@test "deviations --from/--to filters on the first unmarked day" {
  hook_in "$(ev Stop sess-unmarked)"
  run "$WI" deviations --from 2020-01-01 --to 2020-01-02
  [[ "$output" == *"no unmarked sessions recorded locally"* ]]
}

@test "check prints the deviations of the sessions involved, and only those" {
  export CLAUDE_CODE_SESSION_ID=sess-unmarked
  run "$WI" check acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [[ "$output" == *"deviation (unmarked time): session sess-unmarked"* ]]
  [[ "$output" != *"sess-other"* ]]
}

@test "UserPromptSubmit reminds an unmarked session via additionalContext, a marked one not" {
  run hook_in "$(ev UserPromptSubmit sess-main '{"prompt":"hi"}')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = "UserPromptSubmit" ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"alfred-workitem mark <owner>/<repo>#<n>"* ]]
  [ "$(jq -r 'has("decision")' <<<"$output")" = "false" ]
  "$WI" mark acme/widgets#7
  run hook_in "$(ev UserPromptSubmit sess-main '{"prompt":"hi"}')"
  [ -z "$output" ]
}

@test "SessionStart resume re-sends the marker; startup and unmarked sessions send nothing" {
  "$WI" mark acme/widgets#7
  : > "$STUB_DIR/posts.jsonl"
  hook_in "$(ev SessionStart sess-main '{"source":"startup"}')"
  [ "$(nposts)" -eq 0 ]
  hook_in "$(ev SessionStart sess-main '{"source":"resume"}')"
  [ "$(nposts)" -eq 1 ]
  [ "$(posts | attr work_item)" = "acme/widgets#7" ]
  [ "$(posts | attr session.id)" = "sess-main" ]
  : > "$STUB_DIR/posts.jsonl"
  hook_in "$(ev SessionStart sess-new '{"source":"resume"}')"
  [ "$(nposts)" -eq 0 ]
}

# --- SessionEnd -----------------------------------------------------------------------------------

@test "SessionEnd returns at once and the detached run sends one [deviation] notice to the hub" {
  hook_in "$(ev Stop sess-unmarked)"
  start=$SECONDS
  run hook_in "$(ev SessionEnd sess-unmarked '{"reason":"other"}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ $((SECONDS - start)) -lt 2 ]
  for _ in $(seq 1 50); do [ -s "$STUB_DIR/notify.jsonl" ] && break; sleep 0.1; done
  [ -s "$STUB_DIR/notify.jsonl" ]
  [ "$(jq -r '.cmd' "$STUB_DIR/notify.jsonl")" = "notify" ]
  [ "$(jq -r '.to' "$STUB_DIR/notify.jsonl")" = "hub" ]
  [ "$(jq -r '.subject' "$STUB_DIR/notify.jsonl")" = "[deviation] sess-unmarked" ]
  [[ "$(jq -r '.body' "$STUB_DIR/notify.jsonl")" == *"requests 3, tokens 370"* ]]
  # the same stretch of unmarked time is not reported twice
  for _ in $(seq 1 20); do [ -n "$(jq -r '.notified_at // empty' "$DIR/deviations.jsonl")" ] && break; sleep 0.1; done
  "$WI" check-session sess-unmarked
  [ "$(wc -l < "$STUB_DIR/notify.jsonl")" -eq 1 ]
}

@test "SessionEnd of a marked session notifies nobody, and never about an overrun" {
  "$WI" mark acme/widgets#7
  hook_in "$(ev SessionEnd sess-main '{"reason":"other"}')"
  sleep 1
  [ ! -e "$STUB_DIR/notify.jsonl" ]
  # even far over the estimate
  "$WI" check-session sess-main
  run "$WI" check acme/widgets#7 --estimate 1
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_DIR/notify.jsonl" ]
}

@test "check-session still notifies when the store is down" {
  hook_in "$(ev Stop sess-unmarked)"
  touch "$STUB_DIR/fail"
  run "$WI" check-session sess-unmarked
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.body' "$STUB_DIR/notify.jsonl")" == *"Store amounts unavailable"* ]]
}

# --- housekeeping -------------------------------------------------------------------------------------

@test "mark removes state not used for 90 days, never the current session's" {
  mkdir -p "$DIR"
  echo '{}' > "$DIR/old-sess.json"
  echo '{}' > "$DIR/old-sess.state.json"
  echo '{}' > "$DIR/sess-main.state.json"
  echo '{}' > "$DIR/fresh-sess.json"
  touch -d '100 days ago' "$DIR/old-sess.json" "$DIR/old-sess.state.json" "$DIR/sess-main.state.json"
  "$WI" mark acme/widgets#7
  [ ! -e "$DIR/old-sess.json" ]
  [ ! -e "$DIR/old-sess.state.json" ]
  [ -e "$DIR/sess-main.state.json" ]
  [ -e "$DIR/fresh-sess.json" ]
  [ -e "$DIR/sess-main.json" ]
}

@test "mark without a session id warns and exits 0" {
  unset CLAUDE_CODE_SESSION_ID
  run "$WI" mark acme/widgets#7
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE_CODE_SESSION_ID not set"* ]]
  [ ! -e "$STUB_DIR/posts.jsonl" ]
}

@test "hooks.json wires the hooks and keeps the existing ones" {
  h="$BATS_TEST_DIRNAME/../hooks/hooks.json"
  for e in UserPromptSubmit Stop SubagentStop SessionEnd; do
    jq -e --arg e "$e" '[.hooks[$e][].hooks[].command | select(endswith("alfred-workitem\" hook"))] | length == 1' "$h"
  done
  jq -e '[.hooks.SessionStart[] | select(.matcher == "resume") | .hooks[].command | select(endswith("alfred-workitem\" hook"))] | length == 1' "$h"
  jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | endswith("alfred-workitem\" guard")' "$h"
  # existing hooks are still there
  for s in owner-communication.sh session-check.sh doctrines-context.sh; do
    jq -e --arg s "$s" '[.hooks.SessionStart[].hooks[].command | select(contains($s))] | length == 1' "$h"
  done
  jq -e '[.hooks.Stop[].hooks[].command | select(contains("bridge-check.sh"))] | length == 1' "$h"
  # SessionEnd stays inside the hook runner's budget
  jq -e '.hooks.SessionEnd[].hooks[].timeout <= 1.5' "$h"
}
