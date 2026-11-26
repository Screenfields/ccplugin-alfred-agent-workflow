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

# long_unmarked <sid> — Stop hook, then backdate the unmarked window to 5 minutes.
long_unmarked() {
  hook_in "$(ev Stop "$1" "${2:-{\}}")"
  jq -c --arg f "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" '.first_unmarked_at = $f' "$DIR/deviations.jsonl" > "$DIR/dev.tmp" \
    && mv "$DIR/dev.tmp" "$DIR/deviations.jsonl"
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

@test "the item regex is the store's: no leading zero, no #0, owner without _ or ." {
  for bad in acme/widgets#0 acme/widgets#07 acme/widgets#00 my_org/widgets#7 my.org/widgets#7 acme/widgets#; do
    run "$WI" mark "$bad"
    [ "$status" -eq 2 ]
    run "$WI" line "$bad"
    [ "$status" -eq 2 ]
  done
  [ ! -e "$STUB_DIR/posts.jsonl" ]
  run "$WI" mark my-org/wid_gets.x#10
  [ "$status" -eq 0 ]
  # a subagent brief with a rejected item attributes nothing
  transcript "$BATS_TEST_TMPDIR/agent.jsonl" "Work item: acme/other#07" 3
  : > "$STUB_DIR/posts.jsonl"
  hook_in "$(ev SubagentStop sess-main "$(jq -cn --arg p "$BATS_TEST_TMPDIR/agent.jsonl" '{agent_id: "a1", agent_transcript_path: $p}')")"
  [ "$(nposts)" -eq 0 ]
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

# Contract fixture: the store's real /workitems output, copied byte for byte
# from monitoring's committed fixture (monitoring #52, head 7c34474). If the
# store's response changes, refresh the file byte for byte from monitoring.
# Served compact on one line, as on the wire.
@test "report and line read the store's real /workitems response (contract fixture)" {
  jq -c . "$FIX/workitems-response.json" > "$STUB_DIR/workitems.json"
  [ "$(wc -l < "$STUB_DIR/workitems.json")" -eq 1 ]
  run "$WI" report acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [[ "$output" != *"warn"* ]]
  [[ "$output" == *"**1702** with cache reads"* ]]
  [[ "$output" == *"input 2, output 1500, cache_read 200, cache_write 0"* ]]
  [[ "$output" == *"2 requests; cost_usd 0.54."* ]]
  # role x model rows: the builder / main split (main is the session's level)
  [[ "$output" == *"| builder | claude-"* ]]
  [[ "$output" == *"| main (session) | claude-"* ]]
  [ "$(grep -c '^| \(builder\|main (session)\) |' <<<"$output")" -eq 2 ]
  # the response also holds an "unattributed" row; it never leaks into the item's figures
  [ "$(jq -r '[.work_items[].work_item] | index("unattributed") != null' "$STUB_DIR/workitems.json")" = true ]
  [[ "$output" != *"unattributed"* ]]
  grep -q 'work_item=acme%2Fwidgets%237' "$STUB_DIR/calls.log"
  # deviations: the two sessions of the response, when they are the involved ones
  mkdir -p "$DIR"
  printf '%s\n' '{"session_id":"sess-a"}' '{"session_id":"sess-b"}' > "$DIR/deviations.jsonl"
  run "$WI" report acme/widgets#7
  [ "$(grep -c '^deviation (unmarked time)' <<<"$output")" -eq 2 ]
  [[ "$output" == *"session sess-a acme 2026-10-21T07:59:00Z..2026-10-21T07:59:00Z, requests 1, tokens 106 all types, cost_usd 0.001"* ]]
  [[ "$output" == *"session sess-b acme"*"tokens 151 all types, cost_usd 0.05"* ]]
  run "$WI" line acme/widgets#7 --estimate 1702
  [ "$status" -eq 0 ]
  [[ "$output" == "acme/widgets#7: actual 1702 tokens all types (1502 without cache reads;"*"100.0% of it with all types"* ]]
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

@test "numbers print normalised: 1.0 as 1, whatever the jq version" {
  cat > "$STUB_DIR/workitems.json" <<'JSON'
{"work_items": [{"work_item": "acme/widgets#7", "requests": 2.0, "cost_usd": 2.50,
  "tokens": {"input": 10.0, "output": 20.0, "cache_read": 0.0, "cache_write": 5.0},
  "by_role_model": [{"role": "builder", "model": "m", "requests": 2.0, "cost_usd": 3.0,
    "tokens": {"input": 10.0, "output": 20.0, "cache_read": 0.0, "cache_write": 5.0}}]}],
 "deviations": [{"session_id": "sess-main", "requests": 1.0, "cost_usd": 4.0,
    "tokens": {"input": 1.0, "output": 1.0, "cache_read": 0.0, "cache_write": 0.0}}]}
JSON
  run "$WI" report acme/widgets#7 --estimate 12M
  [ "$status" -eq 0 ]
  [[ "$output" == *"| builder | m | 2 | 10 | 20 | 0 | 5 | 35 | 35 | 3 |"* ]]
  [[ "$output" == *"; 2 requests; cost_usd 2.5."* ]]
  [[ "$output" == *"requests 1, tokens 2 all types, cost_usd 4"* ]]
  cp "$FIX/workitems.json" "$STUB_DIR/workitems.json"
  run "$WI" report acme/widgets#7
  [[ "$output" != *"1.0 "* ]]
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
  export CLAUDE_CODE_ENTRYPOINT=cli
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

@test "SessionStart resume with a corrupt mark file sends nothing and warns" {
  mkdir -p "$DIR"
  : > "$STUB_DIR/posts.jsonl"
  for body in '{not json' '{}' '{"item": 7}' '{"item": "acme/widgets#07"}' ''; do
    printf '%s' "$body" > "$DIR/sess-main.json"
    run hook_in "$(ev SessionStart sess-main '{"source":"resume"}')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unreadable"* ]]
    [ "$(nposts)" -eq 0 ]
  done
  # a deliberate "none" still re-sends the empty item
  "$WI" mark none
  hook_in "$(ev SessionStart sess-main '{"source":"resume"}')"
  [ "$(nposts)" -eq 2 ]
  [ "$(posts | tail -1 | attr work_item)" = "" ]
}

@test "no unmarked reminder for a non-interactive entrypoint (sdk-cli)" {
  export CLAUDE_CODE_ENTRYPOINT=sdk-cli
  run hook_in "$(ev UserPromptSubmit sess-main '{"prompt":"hi"}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no unmarked reminder for ALFRED_ROLE=worker" {
  export CLAUDE_CODE_ENTRYPOINT=cli ALFRED_ROLE=worker
  run hook_in "$(ev UserPromptSubmit sess-main '{"prompt":"hi"}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the unmarked reminder still comes with the cli entrypoint and no role" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  unset ALFRED_ROLE
  run hook_in "$(ev UserPromptSubmit sess-main '{"prompt":"hi"}')"
  [[ "$output" == *additionalContext* ]]
}

@test "the unmarked reminder comes on the 1st prompt and then every 5th" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  got=""
  for i in 1 2 3 4 5 6 7; do
    out=$(hook_in "$(ev UserPromptSubmit sess-main '{"prompt":"hi"}')")
    if [ -n "$out" ]; then got="$got$i,"; else got="$got-,"; fi
  done
  [ "$got" = "1,-,-,-,-,6,-," ]
  # per session
  [ -n "$(hook_in "$(ev UserPromptSubmit sess-other '{"prompt":"hi"}')")" ]
}

# --- SessionEnd -----------------------------------------------------------------------------------

@test "SessionEnd returns at once and the detached run sends one [deviation] notice to the hub" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  long_unmarked sess-unmarked
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
  export CLAUDE_CODE_ENTRYPOINT=cli
  long_unmarked sess-unmarked
  touch "$STUB_DIR/fail"
  run "$WI" check-session sess-unmarked
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.body' "$STUB_DIR/notify.jsonl")" == *"Store amounts unavailable"* ]]
}

@test "a second SessionEnd for the same session starts no second detached run" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  long_unmarked sess-unmarked
  echo 2 > "$STUB_DIR/notify-slow"
  hook_in "$(ev SessionEnd sess-unmarked '{"reason":"other"}')"
  hook_in "$(ev SessionEnd sess-unmarked '{"reason":"other"}')"
  [ -d "$DIR/sess-unmarked.check.lock" ]
  # a second run would not see notified_at yet and would notify as well
  for _ in $(seq 1 60); do [ ! -d "$DIR/sess-unmarked.check.lock" ] && break; sleep 0.1; done
  [ ! -d "$DIR/sess-unmarked.check.lock" ]
  [ "$(wc -l < "$STUB_DIR/notify.jsonl")" -eq 1 ]
  # the lock is released: a later SessionEnd (a resumed session) may run again
  rm "$STUB_DIR/notify-slow"
  hook_in "$(ev Stop sess-unmarked)"
  sleep 1.1
  hook_in "$(ev Stop sess-unmarked)"
  hook_in "$(ev SessionEnd sess-unmarked '{"reason":"other"}')"
  for _ in $(seq 1 50); do [ "$(wc -l < "$STUB_DIR/notify.jsonl")" -eq 2 ] && break; sleep 0.1; done
  [ "$(wc -l < "$STUB_DIR/notify.jsonl")" -eq 2 ]
}

@test "a stale SessionEnd lock (older than the run's time limit) is cleared" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  mkdir -p "$DIR/sess-unmarked.check.lock"
  touch -d '5 minutes ago' "$DIR/sess-unmarked.check.lock"
  long_unmarked sess-unmarked
  hook_in "$(ev SessionEnd sess-unmarked '{"reason":"other"}')"
  for _ in $(seq 1 50); do [ -s "$STUB_DIR/notify.jsonl" ] && break; sleep 0.1; done
  [ -s "$STUB_DIR/notify.jsonl" ]
}

# --- suppressed deviations (ccplugin#132) ------------------------------------------------------

# suppressed <sid> <reason> — nothing was sent, but the deviation is recorded.
suppressed() {
  [ ! -e "$STUB_DIR/notify.jsonl" ]
  [ "$(jq -r --arg s "$1" 'select(.session_id == $s) | .notified' "$DIR/deviations.jsonl")" = "suppressed:$2" ]
}

# dev_rec <sid> <first-ago-s> <last-ago-s> [transcript] — a deviation record with those ages.
dev_rec() {
  jq -cn --arg s "$1" --arg f "$(date -u -d "$2 seconds ago" +%Y-%m-%dT%H:%M:%SZ)" --arg l "$(date -u -d "$3 seconds ago" +%Y-%m-%dT%H:%M:%SZ)" --arg t "${4:-}" \
    '{session_id: $s, first_unmarked_at: $f, last_seen_at: $l, cwd: "/x"} + (if $t == "" then {} else {transcript: $t} end)' > "$DIR/deviations.jsonl"
}

# ts_transcript <file> <started-ago-s> <tool-calls> — a transcript whose first entry has that age.
ts_transcript() {
  local i
  jq -cn --arg t "$(date -u -d "$2 seconds ago" +%Y-%m-%dT%H:%M:%SZ)" '{type: "user", timestamp: $t, message: {role: "user", content: "hi"}}' > "$1"
  jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: "x"}]}}' >> "$1"
  for ((i = 0; i < $3; i++)); do
    jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "t", name: "Bash", input: {}}]}}' >> "$1"
  done
}

@test "a zero-length window sends nothing but is recorded" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  mkdir -p "$DIR"
  dev_rec sess-zero 0 0
  "$WI" check-session sess-zero
  suppressed sess-zero short-window
}

@test "a 30 s window sends nothing but is recorded" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  mkdir -p "$DIR"
  dev_rec sess-short 30 0
  "$WI" check-session sess-short
  suppressed sess-short short-window
}

@test "a non-interactive entrypoint (sdk-cli) sends nothing but is recorded" {
  export CLAUDE_CODE_ENTRYPOINT=sdk-cli
  long_unmarked sess-unmarked
  "$WI" check-session sess-unmarked
  suppressed sess-unmarked non-interactive
}

@test "an unset entrypoint counts as non-interactive" {
  unset CLAUDE_CODE_ENTRYPOINT
  long_unmarked sess-unmarked
  "$WI" check-session sess-unmarked
  suppressed sess-unmarked non-interactive
}

@test "the SessionEnd hook passes the entrypoint it saw to the detached run" {
  long_unmarked sess-unmarked
  CLAUDE_CODE_ENTRYPOINT=sdk-cli hook_in "$(ev SessionEnd sess-unmarked '{"reason":"other"}')"
  for _ in $(seq 1 50); do [ -n "$(jq -r '.notified // empty' "$DIR/deviations.jsonl")" ] && break; sleep 0.1; done
  suppressed sess-unmarked non-interactive
}

@test "no store amounts and no tool calls sends nothing but is recorded" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  jq -cn '{type: "user", message: {role: "user", content: "hi"}}' > "$BATS_TEST_TMPDIR/t.jsonl"
  jq -cn '{type: "assistant", requestId: "r", message: {role: "assistant", content: [{type: "text", text: "hello"}]}}' >> "$BATS_TEST_TMPDIR/t.jsonl"
  long_unmarked sess-unmarked "$(jq -cn --arg t "$BATS_TEST_TMPDIR/t.jsonl" '{transcript_path: $t}')"
  touch "$STUB_DIR/fail"
  "$WI" check-session sess-unmarked
  suppressed sess-unmarked no-activity
}

@test "no store amounts but tool calls in the transcript still sends" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  transcript "$BATS_TEST_TMPDIR/t.jsonl" hi 1
  long_unmarked sess-unmarked "$(jq -cn --arg t "$BATS_TEST_TMPDIR/t.jsonl" '{transcript_path: $t}')"
  touch "$STUB_DIR/fail"
  "$WI" check-session sess-unmarked
  [ "$(jq -r '.subject' "$STUB_DIR/notify.jsonl")" = "[deviation] sess-unmarked" ]
  [ "$(jq -r '.notified' "$DIR/deviations.jsonl")" = "sent" ]
}

@test "a long interactive unmarked session still sends" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  long_unmarked sess-unmarked
  "$WI" check-session sess-unmarked
  [ "$(jq -r '.subject' "$STUB_DIR/notify.jsonl")" = "[deviation] sess-unmarked" ]
}

@test "one prompt then long unmarked work with many tool calls sends (window 0 s between Stops)" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  mkdir -p "$DIR"
  ts_transcript "$BATS_TEST_TMPDIR/t.jsonl" 3600 12
  dev_rec sess-unmarked 0 0 "$BATS_TEST_TMPDIR/t.jsonl"
  touch "$STUB_DIR/fail"
  "$WI" check-session sess-unmarked
  [ "$(jq -r '.subject' "$STUB_DIR/notify.jsonl")" = "[deviation] sess-unmarked" ]
}

@test "tool calls without any transcript timestamps are never suppressed as short-window" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  mkdir -p "$DIR"
  transcript "$BATS_TEST_TMPDIR/t.jsonl" hi 5
  dev_rec sess-unmarked 0 0 "$BATS_TEST_TMPDIR/t.jsonl"
  touch "$STUB_DIR/fail"
  "$WI" check-session sess-unmarked
  [ -s "$STUB_DIR/notify.jsonl" ]
}

@test "a two-turn session with Stops 30 s apart, a transcript from 1 h ago and tool calls sends" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  mkdir -p "$DIR"
  ts_transcript "$BATS_TEST_TMPDIR/t.jsonl" 3600 4
  dev_rec sess-unmarked 30 0 "$BATS_TEST_TMPDIR/t.jsonl"
  "$WI" check-session sess-unmarked
  [ -s "$STUB_DIR/notify.jsonl" ]
}

@test "a true 10 s scratch session without tool calls is still suppressed" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  mkdir -p "$DIR"
  ts_transcript "$BATS_TEST_TMPDIR/t.jsonl" 10 0
  dev_rec sess-unmarked 10 0 "$BATS_TEST_TMPDIR/t.jsonl"
  "$WI" check-session sess-unmarked
  suppressed sess-unmarked short-window
}

@test "a later Stop of a resumed session keeps the suppressed tag" {
  export CLAUDE_CODE_ENTRYPOINT=sdk-cli
  long_unmarked sess-unmarked
  "$WI" check-session sess-unmarked
  hook_in "$(ev Stop sess-unmarked)"
  [ "$(jq -r '.notified' "$DIR/deviations.jsonl")" = "suppressed:non-interactive" ]
  [ -n "$(jq -r '.notified_at // empty' "$DIR/deviations.jsonl")" ]
}

@test "the detached SessionEnd run is time-limited" {
  grep -q 'timeout "\$3" "\$0" check-session' "$WI"
  grep -q '^CHECK_TIMEOUT=30 ' "$WI"
}

@test "deviations.jsonl keeps the last 500 lines, newest included" {
  mkdir -p "$DIR"
  for i in $(seq 1 600); do
    jq -cn --arg s "old-$i" '{session_id: $s, first_unmarked_at: "2026-01-01T00:00:00Z", last_seen_at: "2026-01-01T00:00:00Z", cwd: "/x"}'
  done > "$DIR/deviations.jsonl"
  hook_in "$(ev Stop sess-unmarked)"
  [ "$(wc -l < "$DIR/deviations.jsonl")" -eq 500 ]
  [ "$(tail -1 "$DIR/deviations.jsonl" | jq -r .session_id)" = "sess-unmarked" ]
  [ "$(head -1 "$DIR/deviations.jsonl" | jq -r .session_id)" = "old-102" ]
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
  # the bridge check now runs through hooks/stop.sh (ccplugin#127), still exactly once
  jq -e '[.hooks.Stop[].hooks[].command | select(contains("hooks/stop.sh"))] | length == 1' "$h"
  jq -e '[.hooks.Stop[].hooks[].command | select(contains("bridge-check.sh"))] | length == 0' "$h"
  # SessionEnd stays inside the hook runner's budget
  jq -e '.hooks.SessionEnd[].hooks[].timeout <= 1.5' "$h"
  # SubagentStop: one POST is capped at POST_TIMEOUT per chunk of CHUNK ids
  jq -e '.hooks.SubagentStop[].hooks[].timeout >= 30' "$h"
}

# --- CCW-255: re-send the session mark once per 24 h on UserPromptSubmit -------------------------------

# RS helpers. The clock is pinned with ALFRED_WORKITEM_NOW; S is its epoch.
rs_pin() { # [epoch] — pin "now" (default: 2026-06-01T12:00:00Z)
  S=$(date -u -d 2026-06-01T12:00:00Z +%s)
  export ALFRED_WORKITEM_NOW
  ALFRED_WORKITEM_NOW=$(date -u -d "@${1:-$S}" +%Y-%m-%dT%H:%M:%SZ)
}
ups() { hook_in "$(ev UserPromptSubmit "${1:-sess-main}" '{"prompt":"hi"}')"; }
stamp() { mkdir -p "$DIR"; printf '%s\n' "$1" > "$DIR/${2:-sess-main}.resend"; }
stamp_get() { cat "$DIR/${1:-sess-main}.resend"; }
setmark() { # <item> [sid] — a mark file written by hand (no send, no stamp)
  mkdir -p "$DIR"
  jq -n --arg i "$1" '{item: $i, marked_at: "2026-01-01T00:00:00Z", estimate: null}' > "$DIR/${2:-sess-main}.json"
}
ncurl() { grep -cE '^(GET|POST) ' "$STUB_DIR/calls.log" 2>/dev/null || true; }
reset_stub() { rm -f "$STUB_DIR/posts.jsonl" "$STUB_DIR/calls.log" "$STUB_DIR/headers.log"; }

@test "RS1: a due mark is re-sent once on UserPromptSubmit, silently" {
  rs_pin; setmark acme/widgets#7; stamp $((S - 86401))
  run --separate-stderr ups
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(nposts)" -eq 1 ]
  [ "$(posts | attr work_item)" = "acme/widgets#7" ]
  [ "$(posts | attr session.id)" = "sess-main" ]
  [ "$(posts | attr event.timestamp)" = "$ALFRED_WORKITEM_NOW" ]
  [ "$(stamp_get)" = "$S" ]
}

@test "RS2: the 24 h boundary is exact" {
  rs_pin; setmark acme/widgets#7
  local pair age want
  for pair in 86400:0 86401:1 3600:0 604800:1; do
    age="${pair%%:*}"; want="${pair##*:}"
    reset_stub; stamp $((S - age))
    ups
    [ "$(nposts)" -eq "$want" ] || { echo "age $age: $(nposts) posts, want $want"; false; }
  done
}

@test "RS3: not on every prompt, and per session" {
  rs_pin; setmark acme/widgets#7; setmark acme/widgets#9 sess-other
  stamp $((S - 86401)); stamp $((S - 86401)) sess-other
  ups
  [ "$(nposts)" -eq 1 ]
  ups; ups; ups
  [ "$(nposts)" -eq 1 ]
  [ "$(stamp_get)" = "$S" ]
  stamp $((S - 100))
  ups sess-other
  [ "$(nposts)" -eq 2 ]
  [ "$(posts | tail -1 | attr session.id)" = "sess-other" ]
  [ "$(posts | tail -1 | attr work_item)" = "acme/widgets#9" ]
  [ "$(stamp_get sess-other)" = "$S" ]
  [ "$(stamp_get)" = "$((S - 100))" ]
}

@test "RS4: mark and SessionStart resume write the stamp" {
  rs_pin
  "$WI" mark acme/widgets#7
  [ "$(nposts)" -eq 1 ]
  ups
  [ "$(nposts)" -eq 1 ]
  reset_stub; rm -f "$DIR/sess-main.resend"
  setmark acme/widgets#7
  hook_in "$(ev SessionStart sess-main '{"source":"resume"}')"
  ups
  [ "$(nposts)" -eq 1 ]
}

@test "RS5: a failed mark leaves the kept mark due at the next prompt" {
  rs_pin
  # (a) the store refuses the first mark
  touch "$STUB_DIR/fail"
  run "$WI" mark acme/widgets#7
  [ ! -e "$DIR/sess-main.resend" ]
  rm -f "$STUB_DIR/fail"; reset_stub
  ups
  [ "$(nposts)" -eq 1 ]
  [ "$(posts | attr work_item)" = "acme/widgets#7" ]
  # (b) a fresh stamp, then a refused change of item
  rm -f "$DIR/sess-main.resend"; reset_stub
  "$WI" mark acme/widgets#7
  [ -e "$DIR/sess-main.resend" ]
  touch "$STUB_DIR/fail"
  run "$WI" mark acme/widgets#8
  [ ! -e "$DIR/sess-main.resend" ]
  [ "$(mark_item)" = "acme/widgets#8" ]
  rm -f "$STUB_DIR/fail"; reset_stub
  ups
  [ "$(nposts)" -eq 1 ]
  [ "$(posts | attr work_item)" = "acme/widgets#8" ]
}

@test "RS6: a missing stamp counts as due, once" {
  rs_pin; setmark acme/widgets#7
  ups
  [ "$(nposts)" -eq 1 ]
  [ "$(stamp_get)" = "$S" ]
  ups
  [ "$(nposts)" -eq 1 ]
}

@test "RS7: a corrupt stamp counts as due and never breaks the hook" {
  rs_pin; setmark acme/widgets#7
  local c nines thirteen wrap
  nines=$(printf '9%.0s' $(seq 300)); thirteen=9999999999999
  # 2**64 + S - 100 as a 20-digit value: under a bare ^[0-9]+$ guard bash arithmetic
  # wraps it to S-100 (not due, 0 POSTs); the 1-12 digit guard reads it as corrupt.
  wrap=$(python3 -c "print(2**64 + $S - 100)")
  [ "${#wrap}" -eq 20 ]
  for c in '' abc 12x -5 1e9 '1 2' "$nines" "$thirteen" 09 0000000000012 "$wrap" $((S + 864000)); do
    reset_stub
    mkdir -p "$DIR"; printf '%s' "$c" > "$DIR/sess-main.resend"
    run --separate-stderr ups
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(nposts)" -le 1 ]
    [ "$(stamp_get)" = "$S" ] || { echo "stamp '$c' -> '$(stamp_get)'"; false; }
    [[ "$stderr" != *"syntax error"* ]]
    ups
    [ "$(nposts)" -le 1 ]
    # a corrupt stamp is due: exactly one POST on that prompt
    [ "$(nposts)" -eq 1 ] || { echo "stamp '$c' sent $(nposts) times"; false; }
  done
}

@test "RS8: nothing is sent without a usable non-empty mark" {
  rs_pin
  # no mark file: nothing sent, no stamp, the reminder still works
  export CLAUDE_CODE_ENTRYPOINT=cli
  run --separate-stderr ups
  [ "$(nposts)" -eq 0 ]
  [ ! -e "$DIR/sess-main.resend" ]
  [[ "$output" == *additionalContext* ]]
  unset CLAUDE_CODE_ENTRYPOINT
  # corrupt mark files, each with a due stamp
  mkdir -p "$DIR"
  local body
  for body in '{not json' '{}' '{"item": 7}' '{"item": "acme/widgets#07"}' ''; do
    printf '%s' "$body" > "$DIR/sess-main.json"; stamp $((S - 90000))
    run --separate-stderr ups
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *unreadable* ]]
    [ "$(nposts)" -eq 0 ]
    [ "$(stamp_get)" = "$((S - 90000))" ]
  done
  # an empty item (by hand, and by mark none) is never re-sent
  setmark ""; stamp $((S - 90000))
  ups; ups; ups
  [ "$(nposts)" -eq 0 ]
  [ "$(stamp_get)" = "$((S - 90000))" ]
  stamp $((S - 90000))
  "$WI" mark none
  [ ! -e "$DIR/sess-main.resend" ]
  reset_stub; stamp $((S - 90000))
  ups; ups; ups
  [ "$(nposts)" -eq 0 ]
  [ "$(stamp_get)" = "$((S - 90000))" ]
}

@test "RS9: a failed send neither blocks, loops nor spends tokens; retry after one hour" {
  rs_pin; setmark acme/widgets#7; stamp $((S - 90000))
  cp "$DIR/sess-main.json" "$BATS_TEST_TMPDIR/mark.before"
  touch "$STUB_DIR/fail"
  run --separate-stderr ups
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"marker POST failed"* ]]
  cmp "$DIR/sess-main.json" "$BATS_TEST_TMPDIR/mark.before"
  [ "$(ncurl)" -eq 1 ]
  [ "$(stamp_get)" = "$((S - 82800))" ]
  ups
  [ "$(ncurl)" -eq 1 ]
  rs_pin $((S + 3600)); ups
  [ "$(ncurl)" -eq 1 ]
  rs_pin $((S + 3601)); ups
  [ "$(ncurl)" -eq 2 ]
}

@test "RS9: a missing endpoint makes no curl call and sets the retry stamp" {
  rs_pin; setmark acme/widgets#7; stamp $((S - 90000))
  unset AGENT_RUNS_OTLP_LOGS_ENDPOINT
  run --separate-stderr ups
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *AGENT_RUNS_OTLP_LOGS_ENDPOINT* ]]
  [ ! -e "$STUB_DIR/calls.log" ]
  [ "$(stamp_get)" = "$((S - 82800))" ]
}

@test "RS10: only UserPromptSubmit re-sends" {
  rs_pin; setmark acme/widgets#7; stamp $((S - 90000))
  local e
  for e in Stop SubagentStop SessionEnd; do
    hook_in "$(ev "$e" sess-main)"
  done
  hook_in "$(ev SessionStart sess-main '{"source":"startup"}')"
  sleep 0.3
  [ "$(nposts)" -eq 0 ]
  [ "$(stamp_get)" = "$((S - 90000))" ]
}

@test "RS11: latency of the re-send path" {
  rs_pin; setmark acme/widgets#7
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  # (a) not due: no curl call, no config file left behind
  stamp $((S - 100))
  ups
  [ ! -e "$STUB_DIR/calls.log" ]
  [ -z "$(ls -A "$TMPDIR")" ]
  # (b) store hanging, due: bounded by POST_TIMEOUT, inside the hook's 5 s budget
  echo 6 > "$STUB_DIR/slow"; stamp $((S - 90000))
  local t0 t1
  t0=$(date +%s%N); run ups; t1=$(date +%s%N)
  [ "$status" -eq 0 ]
  [ $(((t1 - t0) / 1000000)) -lt 4000 ]
  grep -qx 'max-time 2' "$STUB_DIR/calls.log"
  # (c) the throttle keeps the next prompt fast
  t0=$(date +%s%N); ups; t1=$(date +%s%N)
  [ $(((t1 - t0) / 1000000)) -lt 1000 ]
}

@test "RS12: a stamp that cannot be recorded sends nothing" {
  rs_pin; setmark acme/widgets#7
  mkdir -p "$DIR/sess-main.resend"
  local i
  for i in 1 2 3; do
    run --separate-stderr ups
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ "$(nposts)" -eq 0 ]
}

@test "RS12: a read-only state dir sends nothing" {
  rs_pin; setmark acme/widgets#7
  chmod 555 "$DIR"
  local i
  for i in 1 2 3; do
    run --separate-stderr ups
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  chmod 755 "$DIR"
  [ "$(nposts)" -eq 0 ]
  [ ! -e "$DIR/sess-main.resend" ]
}

@test "RS13: no entrypoint or role gate on the re-send" {
  rs_pin; setmark acme/widgets#7
  local ep
  for ep in sdk-cli cli UNSET; do
    reset_stub; stamp $((S - 90000))
    if [ "$ep" = UNSET ]; then unset CLAUDE_CODE_ENTRYPOINT; else export CLAUDE_CODE_ENTRYPOINT="$ep"; fi
    ups
    [ "$(nposts)" -eq 1 ] || { echo "entrypoint $ep"; false; }
  done
  reset_stub; stamp $((S - 90000))
  ALFRED_ROLE=worker ups
  [ "$(nposts)" -eq 1 ]
}

@test "RS14: cleanup removes stale stamps, never the current session's" {
  rs_pin
  mkdir -p "$DIR"
  echo "$S" > "$DIR/old-sess.resend"
  echo "$S" > "$DIR/sess-main.resend"
  echo "$S" > "$DIR/old-sess.resend.tmp.123"
  echo "$S" > "$DIR/fresh-sess.resend"
  touch -d '100 days ago' "$DIR/old-sess.resend" "$DIR/sess-main.resend"
  touch -d '2 days ago' "$DIR/old-sess.resend.tmp.123"
  "$WI" mark acme/widgets#7
  [ ! -e "$DIR/old-sess.resend" ]
  [ ! -e "$DIR/old-sess.resend.tmp.123" ]
  [ -e "$DIR/fresh-sess.resend" ]
  [ -e "$DIR/sess-main.resend" ]
  # Excluding the current session from the cleanup is defence in depth and not
  # observable black-box: the successful mark rewrites its stamp afterwards.
  [ "$(stamp_get)" = "$S" ]
}

@test "RS15: the UserPromptSubmit hook timeout stays 5" {
  jq -e '[.hooks.UserPromptSubmit[].hooks[] | select(.command | endswith("alfred-workitem\" hook")) | .timeout] == [5]' \
    "$BATS_TEST_DIRNAME/../hooks/hooks.json"
}

@test "RS16: docs" {
  local root="$BATS_TEST_DIRNAME/.." suffix sec
  "$WI" mark acme/widgets#7
  suffix=$(cd "$DIR" && ls | grep -E '\.resend$' | head -1 | sed 's/^[^.]*//')
  [ "$suffix" = .resend ]
  # (a) script header "Local state" block and the README bullet
  sed -n '/^# Local state/,/^# Nothing is ever written/p' "$root/bin/alfred-workitem" | grep -qF "<session_id>$suffix"
  grep -A6 -F -- '- **Local state**' "$root/README.md" | grep -qF "$suffix"
  # (b) the section "Tokens per work item"
  sec=$(awk '/^## Tokens per work item/{f=1;next} /^## /{f=0} f' "$root/README.md")
  [[ "$sec" == *"24 h"* || "$sec" == *86400* ]]
  # (d) the baseline doc
  grep -qF "$suffix" "$root/docs/baseline/workitem-resend.md"
  grep -qF 86400 "$root/docs/baseline/workitem-resend.md"
  grep -qi 'empty item' "$root/docs/baseline/workitem-resend.md"
}

# --- CCW-259: the plugin text stops offering `mark none`; `mark none` warns once ---------------

ROOT_MN() { echo "$BATS_TEST_DIRNAME/.."; }
DEV_LINE='count as a deviation'
# nwarn <text>: how many lines of the text contain the deviation phrase.
nwarn() { grep -cF -- "$DEV_LINE" <<<"$1" || true; }

@test "MN1: the no-mark row sends operational work to the standing item and does not offer none" {
  row=$(grep -F '| `… no-mark`' "$(ROOT_MN)/commands/check-messages.md")
  [ "$(grep -c . <<<"$row")" -eq 1 ]
  [[ "$row" == *'alfred-workitem mark <owner>/<repo>#<n>'* ]]
  [[ "$row" == *'standing item of objective 1'* ]]
  [[ "$row" == *'then handle the wake as usual with the row above'* ]]
  [ "$(tr -cd '|' <<<"$row" | wc -c)" -eq 4 ]
  cell=$(awk -F'|' '{print $3}' <<<"$row")
  [ -n "$cell" ]
  ! [[ "$cell" == *none* ]] || false
  [ "$(awk -F'|' '{gsub(/ /,"",$4); print $4}' <<<"$row")" = None ]
}

@test "MN2: the reminder does not offer none and is not longer than 287 chars" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  run hook_in "$(ev UserPromptSubmit sess-main '{"prompt":"hi"}')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = UserPromptSubmit ]
  [ "$(jq -r '.hookSpecificOutput | keys | join(",")' <<<"$output")" = "additionalContext,hookEventName" ]
  [ "$(jq -r 'has("decision")' <<<"$output")" = false ]
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  [[ "$ctx" == *'alfred-workitem mark <owner>/<repo>#<n>'* ]]
  [[ "$ctx" == *'standing item of objective 1'* ]]
  ! [[ "$ctx" == *none* ]] || false
  [ "${#ctx}" -le 287 ]
}

@test "MN3: README and the header comment state the rule once and point to it" {
  root=$(ROOT_MN)
  sec=$(awk '/^## Tokens per work item/{f=1;next} /^## /{f=0} f' "$root/README.md")
  bullet=$(awk '/^- \*\*Operational work\*\*/{f=1;print;next} /^- \*\*/{f=0} /^## /{f=0} f' <<<"$sec")
  [ -n "$bullet" ]
  [[ "$bullet" == *wakes* && "$bullet" == *triage* && "$bullet" == *waiting* ]]
  [[ "$bullet" == *'mark none'*'no further model requests'* ]]
  [[ "$bullet" == *'count as a deviation'* ]]
  [[ "$bullet" == *unattributed* ]]
  line=$(grep -F 'alfred-workitem mark <owner>/<repo>#<n>   # mark this session' <<<"$sec")
  [[ "$line" == *'`mark none` clears it'* ]]
  [[ "$line" == *'Operational work'* ]]
  # header comment: every non-empty line before `set -u` starts with `#`
  hdr=$(sed -n '1,/^set -u/p' "$root/bin/alfred-workitem" | sed '$d')
  ! grep -vE '^(#|$)' <<<"$hdr" || false
  mk=$(grep -A1 -F 'mark <owner>/<repo>#<n>|none' <<<"$hdr")
  [[ "$mk" == *'no further'* ]]
  # usage string at the malformed-argument exit is unchanged
  [ "$(grep -cF 'echo "usage: alfred-workitem mark <owner>/<repo>#<n>|none" >&2' "$root/bin/alfred-workitem")" -eq 1 ]
}

@test "MN4: no agent-read text offers mark none" {
  root=$(ROOT_MN)
  dirs=()
  for d in commands skills agents rules hooks agreement doctrines templates lib config; do
    [ -d "$root/$d" ] && dirs+=("$root/$d")
  done
  run grep -rlF 'mark none' "${dirs[@]}"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  rem=$(grep -F "REMINDER='" "$root/bin/alfred-workitem")
  [ -n "$rem" ]
  ! [[ "$rem" == *none* ]] || false
}

@test "MN5: mark none prints the deviation warning once on stderr, stdout unchanged" {
  run --separate-stderr "$WI" mark none
  [ "$status" -eq 0 ]
  [ "$output" = "marked session sess-main -> none (cleared)" ]
  [ "$(wc -l <<<"$stderr")" -eq 1 ]
  [[ "$stderr" == *"$DEV_LINE"* ]]
  [ "${#stderr}" -le 200 ]
  [[ "$stderr" == alfred-workitem:* ]]
  [ "$(nposts)" -eq 1 ]
  [ "$(attr work_item <<<"$(posts)")" = "" ]
  [ "$(mark_item)" = "" ]
}

@test "MN6: other mark calls print no deviation warning" {
  run --separate-stderr "$WI" mark acme/widgets#7
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  run --separate-stderr "$WI" mark widgets-7
  [ "$status" -eq 2 ]
  [ "$stderr" = "usage: alfred-workitem mark <owner>/<repo>#<n>|none" ]
  run --separate-stderr "$WI" mark
  [ "$status" -eq 2 ]
  [ "$(nwarn "$stderr")" -eq 0 ]
}

@test "MN7: no clear, no warning" {
  unset CLAUDE_CODE_SESSION_ID
  run --separate-stderr "$WI" mark none
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"nothing marked"* ]]
  [ "$(nwarn "$stderr")" -eq 0 ]
  export CLAUDE_CODE_SESSION_ID=sess-main
  mkdir -p "$CLAUDE_CONFIG_DIR"; : > "$CLAUDE_CONFIG_DIR/alfred-workitem"
  run --separate-stderr "$WI" mark none
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"cannot create"* ]]
  [ "$(nwarn "$stderr")" -eq 0 ]
}

@test "MN8: a store refusal still warns, once" {
  touch "$STUB_DIR/fail"
  run --separate-stderr "$WI" mark none
  [ "$status" -eq 0 ]
  [ "$output" = "marked session sess-main -> none (cleared)" ]
  [[ "$stderr" == *"did not take the marker"* ]]
  [ "$(nwarn "$stderr")" -eq 1 ]
}

@test "MN9: no hook path carries the warning" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  "$WI" mark none 2>/dev/null
  mkdir -p "$DIR"; printf '%s\n' 1 > "$DIR/sess-main.resend"
  inputs=(
    "$(ev SessionStart sess-main '{"source":"resume"}')"
    "$(ev SessionStart sess-main '{"source":"startup"}')"
    "$(ev UserPromptSubmit sess-main '{"prompt":"a"}')"
    "$(ev UserPromptSubmit sess-main '{"prompt":"b"}')"
    "$(ev UserPromptSubmit sess-main '{"prompt":"c"}')"
    "$(ev Stop sess-main)"
    "$(ev SubagentStop sess-main '{"agent_id":"a1"}')"
    "$(ev SessionEnd sess-main)"
  )
  for i in "${inputs[@]}"; do
    run --separate-stderr hook_in "$i"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(nwarn "$output$stderr")" -eq 0 ]
  done
  # an unmarked session gets only the reminder JSON
  run --separate-stderr hook_in "$(ev UserPromptSubmit sess-new '{"prompt":"hi"}')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput | keys | join(",")' <<<"$output")" = "additionalContext,hookEventName" ]
  [ "$(nwarn "$output$stderr")" -eq 0 ]
}

@test "MN10: mark none still clears and removes the resend stamp" {
  "$WI" mark acme/widgets#7
  [ -e "$DIR/sess-main.resend" ]
  "$WI" mark none 2>/dev/null
  [ ! -e "$DIR/sess-main.resend" ]
  [ "$(mark_item)" = "" ]
  [ "$(attr work_item <<<"$(posts | tail -1)")" = "" ]
}

@test "MN12a: the design record exists and states the rule" {
  f="$(ROOT_MN)/docs/baseline/workitem-mark-none.md"
  [ -f "$f" ]
  grep -qF 'no further model requests' "$f"
  grep -qi 'unattributed' "$f"
  grep -qF 'cmd_mark' "$f"
  grep -qi 'never in a hook' "$f"
}

@test "MN12b: the cannot-write path warns once" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  mkdir -p "$DIR"
  chmod a-w "$DIR"
  run --separate-stderr "$WI" mark none
  chmod u+w "$DIR"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"cannot write"* ]]
  [ "$(nwarn "$stderr")" -eq 1 ]
}

@test "MN12: hooks.json is unchanged against origin/main" {
  git -C "$(ROOT_MN)" rev-parse -q --verify origin/main >/dev/null || skip "no origin/main"
  git -C "$(ROOT_MN)" diff --quiet origin/main -- hooks/hooks.json
}
