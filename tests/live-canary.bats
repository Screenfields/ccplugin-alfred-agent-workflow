#!/usr/bin/env bats
# The --canary mode of tests/live/reply-timestamp.sh, on synthetic transcripts (no
# model call). It must judge the cross-session message's own turn only: a time line
# injected for a LATER prompt is not credited to it (CCW-180, review round 1).

LIVE="$BATS_TEST_DIRNAME/live/reply-timestamp.sh"

setup() {
  TR="$BATS_TEST_TMPDIR/tr.jsonl"
  LOG="$BATS_TEST_TMPDIR/ts.log"
}

msg='{"type":"user","timestamp":"2026-10-31T19:00:00.100Z","message":{"role":"user","content":"Another Claude session sent a message: <cross-session-message from=\"x\">hi</cross-session-message>"}}'
line_att='{"type":"attachment","timestamp":"2026-10-31T19:00:00.150Z","attachment":{"type":"hook_additional_context","hookEvent":"UserPromptSubmit","content":["Time now _[2026-10-31 20:00 CET]_. A new set of actions starts"]}}'
reply_plain='{"type":"assistant","timestamp":"2026-10-31T19:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hello without a line"}]}}'
reply_line='{"type":"assistant","timestamp":"2026-10-31T19:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"_[2026-10-31 20:00 CET]_ hello"}]}}'
tool_use='{"type":"assistant","timestamp":"2026-10-31T19:00:02.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}'
tool_res='{"type":"user","timestamp":"2026-10-31T19:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
later_prompt='{"type":"user","timestamp":"2026-10-31T21:00:00.000Z","message":{"role":"user","content":"later typed prompt"}}'
later_line='{"type":"attachment","timestamp":"2026-10-31T21:00:00.050Z","attachment":{"type":"hook_additional_context","hookEvent":"UserPromptSubmit","content":["Time now _[2026-10-31 22:00 CET]_. A new set of actions starts"]}}'
later_reply='{"type":"assistant","timestamp":"2026-10-31T21:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"_[2026-10-31 22:00 CET]_ later"}]}}'

log_line() { printf '{"ts":"2026-10-31T19:00:00Z","source":"","entrypoint":"cli","owner":false,"emitted":%s,"gap":5000}\n' "$1" > "$LOG"; }
tr_of() { printf '%s\n' "$@" > "$TR"; }
canary() { run "$LIVE" --canary "$LOG" "$TR"; }

@test "canary: emitted true and the line in the message's own turn: consistent, exit 0" {
  log_line true; tr_of "$msg" "$line_att" "$reply_line"
  canary
  [ "$status" -eq 0 ]
  [[ "$output" == *"emitted=true"*"line-in-context=yes"*"reply-starts-with-line=yes"* ]]
}

@test "canary: emitted false and no line in its turn: consistent, exit 0" {
  log_line false; tr_of "$msg" "$reply_plain"
  canary
  [ "$status" -eq 0 ]
  [[ "$output" == *"emitted=false"*"line-in-context=no"* ]]
}

@test "canary: false pass closed. emitted true but no line in its own turn, a later prompt got one: exit 1" {
  log_line true; tr_of "$msg" "$reply_plain" "$later_prompt" "$later_line" "$later_reply"
  canary
  [ "$status" -eq 1 ]
  [[ "$output" == *"line-in-context=no"* ]]
  [[ "$output" == *"reply-starts-with-line=no"* ]]
}

@test "canary: false inconsistent closed. emitted false, no line in its own turn, a later prompt got one: exit 0" {
  log_line false; tr_of "$msg" "$reply_plain" "$later_prompt" "$later_line" "$later_reply"
  canary
  [ "$status" -eq 0 ]
  [[ "$output" == *"line-in-context=no"* ]]
}

@test "canary: a tool_result inside the turn does not end it (line and reply after it still count)" {
  log_line true; tr_of "$msg" "$line_att" "$tool_use" "$tool_res" "$reply_line" "$later_prompt" "$later_line"
  canary
  [ "$status" -eq 0 ]
  [[ "$output" == *"line-in-context=yes"*"reply-starts-with-line=yes"* ]]
}

@test "canary: nothing to prove exits 3 (no entry; log without an emitted key)" {
  log_line true; tr_of "$later_prompt"
  canary
  [ "$status" -eq 3 ]
  tr_of "$msg"; echo '{"ts":"2026-10-31T19:00:00Z"}' > "$LOG"
  canary
  [ "$status" -eq 3 ]
}
