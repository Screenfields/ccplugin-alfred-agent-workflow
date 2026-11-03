#!/usr/bin/env bats
# CCW-189: ECR template budget for deepseek-v4.1-flash and the output branch
# that makes a length-truncated, contentless reply visible as TRUNCATED.

setup() {
  SKILL="$BATS_TEST_DIRNAME/../skills/ecr/SKILL.md"
  # the final if/elif/else block of the template fence
  awk '/^if   \[ \$CURL_EXIT -eq 28 \]/{on=1} on{print} on&&/^fi$/{exit}' "$SKILL" > "$BATS_TEST_TMPDIR/block.sh"
}

run_block() { # json -> stdout of the template's output block
  RESULT="$1" CURL_EXIT=0 TIMEOUT=90 bash "$BATS_TEST_TMPDIR/block.sh"
}

@test "deepseek table row ends in 400s and 32000" {
  [[ "$(grep '^| `deepseek-v4.1-flash`' "$SKILL")" == *"| 400s | 32000 |" ]]
}

@test "no stale 180s or 12000 on deepseek lines except the glm remark" {
  run bash -c "grep -n deepseek '$SKILL' | grep -v '12000 left glm-5.3 and deepseek-v4.1-flash with no content' | grep -E '\\b(180s?|12000)\\b'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "the template lines carry the deepseek values" {
  grep -qF '# Timeout: 90s for OpenAI/Google; 400s glm-5.3; 600s kimi-k3; 400s deepseek-v4.1-flash' "$SKILL"
  grep -qF '# max_tokens: 8000 for OpenAI/Google; 32000 for glm-5.3 and kimi-k3 (thinking models burn' "$SKILL"
  grep -qF '# most of their tokens on reasoning; 12000 left glm-5.3 and deepseek-v4.1-flash with no content); 32000 for deepseek-v4.1-flash' "$SKILL"
  grep -qF 'TIMEOUT=90     # override per the table: 400 glm-5.3, 600 kimi-k3, 400 deepseek-v4.1-flash' "$SKILL"
  grep -qF 'MAX_TOKENS=8000  # override per the table: 32000 glm-5.3 and kimi-k3, 32000 deepseek-v4.1-flash' "$SKILL"
}

@test "the extracted output block is non-empty and ends in fi" {
  [ "$(wc -l < "$BATS_TEST_TMPDIR/block.sh")" -ge 4 ]
  [ "$(tail -n1 "$BATS_TEST_TMPDIR/block.sh")" = fi ]
}

@test "length with empty content prints TRUNCATED" {
  run run_block '{"choices":[{"finish_reason":"length","message":{"content":""}}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "TRUNCATED (reasoning used the whole budget)" ]
}

@test "length with null content prints TRUNCATED" {
  run run_block '{"choices":[{"finish_reason":"length","message":{"content":null}}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "TRUNCATED (reasoning used the whole budget)" ]
}

@test "length with partial content prints the content" {
  run run_block '{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}'
  [ "$output" = "partial" ]
}

@test "stop with content prints the content" {
  run run_block '{"choices":[{"finish_reason":"stop","message":{"content":"ok"}}]}'
  [ "$output" = "ok" ]
}

@test "stop with empty content prints an empty line" {
  out=$(run_block '{"choices":[{"finish_reason":"stop","message":{"content":""}}]}' | od -An -c | tr -d ' ')
  [ "$out" = '\n' ]
}

@test "no choices prints ERROR (unexpected response)" {
  run run_block '{"choices":[]}'
  [ "$output" = "ERROR (unexpected response)" ]
}

@test "Step 4 names TRUNCATED next to TIMEOUT" {
  grep 'TIMEOUT (>Xs)' "$SKILL" | grep -q 'TRUNCATED'
  grep 'TIMEOUT (>Xs)' "$SKILL" | grep -q 'partial panel count'
}
