#!/usr/bin/env bats
# CCW-189 and CCW-191: ECR template budgets, the output branch that makes a
# length-truncated, contentless reply visible as TRUNCATED, and (CCW-191) the
# option A panel: gpt-6-astra, gemini-4-argon, gpt-6.1-sol fallback, Claude voice on fable.

setup() {
  SKILL="$BATS_TEST_DIRNAME/../skills/ecr/SKILL.md"
  # the final if/elif/else block of the template fence
  awk '/^if   \[ \$CURL_EXIT -eq 28 \]/{on=1} on{print} on&&/^fi$/{exit}' "$SKILL" > "$BATS_TEST_TMPDIR/block.sh"
}

run_block() { # json -> stdout of the template's output block
  RESULT="$1" CURL_EXIT=0 TIMEOUT=180 bash "$BATS_TEST_TMPDIR/block.sh"
}

@test "deepseek table row ends in 400s and 32000" {
  [[ "$(grep '^| `deepseek-v4.1-flash`' "$SKILL")" == *"| 400s | 32000 |" ]]
}

@test "no stale 180s or 12000 on deepseek lines except the glm remark and the two template lines that carry the new OpenAI/Google default" {
  run bash -c "grep -n deepseek '$SKILL' | grep -v '12000 left glm-5.3 and deepseek-v4.1-flash with no content' | grep -v ':# Timeout: 180s for OpenAI/Google;' | grep -v ':TIMEOUT=180 ' | grep -E '\\b(180s?|12000)\\b'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "the template lines carry the deepseek values" {
  grep -qF '# Timeout: 180s for OpenAI/Google; 400s glm-5.3; 600s kimi-k3; 400s deepseek-v4.1-flash' "$SKILL"
  grep -qF '# max_tokens: 8000 for OpenAI/Google; 32000 for glm-5.3 and kimi-k3 (thinking models burn' "$SKILL"
  grep -qF '# most of their tokens on reasoning; 12000 left glm-5.3 and deepseek-v4.1-flash with no content); 32000 for deepseek-v4.1-flash' "$SKILL"
  grep -qF 'TIMEOUT=180    # override per the table: 400 glm-5.3, 600 kimi-k3, 400 deepseek-v4.1-flash' "$SKILL"
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

# CCW-191: option A panel, Claude voice and timeout decision

@test "CCW-191: runtime table row names Fable 5.1 and the fable alias" {
  grep -qxF '| Claude Code | Fable 5.1 (`claude-fable-5-1`) | `fable` |' "$SKILL"
}

@test "CCW-191: the Agent example has model fable and no other model line" {
  awk '/^Agent\(/{on=1} on{print} on&&/^\)/{exit}' "$SKILL" > "$BATS_TEST_TMPDIR/agent.txt"
  [ -s "$BATS_TEST_TMPDIR/agent.txt" ]
  [ "$(grep -c 'model:' "$BATS_TEST_TMPDIR/agent.txt")" -eq 1 ]
  grep -qxF '  model: "fable",' "$BATS_TEST_TMPDIR/agent.txt"
}

@test "CCW-191: the sub-agent prose, Step 4 table and full flow name Fable 5.1" {
  grep -q '^The sub-agent runs at `fable` (Fable 5\.1, `claude-fable-5-1`' "$SKILL"
  grep -qF '| Claude Fable 5.1 | Anthropic (sub-agent) |' "$SKILL"
  grep -qF 'spawns Claude Fable 5.1 sub-agent' "$SKILL"
}

@test "CCW-191: the only claude- id is claude-fable-5-1 and opus appears nowhere" {
  [ "$(grep -o 'claude-[a-z0-9-]*' "$SKILL" | sort -u)" = claude-fable-5-1 ]
  [ "$(grep -ci opus "$SKILL")" -eq 0 ]
}

@test "CCW-191: template timeout is 180 and no line starts with TIMEOUT=90" {
  grep -qF '# Timeout: 180s for OpenAI/Google; 400s glm-5.3; 600s kimi-k3; 400s deepseek-v4.1-flash' "$SKILL"
  grep -qF 'TIMEOUT=180    # override per the table: 400 glm-5.3, 600 kimi-k3, 400 deepseek-v4.1-flash' "$SKILL"
  if grep -q '^TIMEOUT=90' "$SKILL"; then false; fi
  grep -q '^MAX_TOKENS=8000 ' "$SKILL"
  grep -q '^# max_tokens: 8000 for OpenAI/Google; 32000 for glm-5.3 and kimi-k3' "$SKILL"
  grep -q '^# most of their tokens on reasoning; 12000 left glm-5.3' "$SKILL"
}

@test "CCW-191: the quota rule names gpt-6-astra and gpt-6.1-sol" {
  grep -qF 'Quota failures are provider-wide:** if gpt-6-astra returns RateLimitError, gpt-6.1-sol will too — substitute a Fireworks model instead, not gpt-6.1-sol' "$SKILL"
}

@test "CCW-191: Step 4 table starts with the GPT-6 Astra and Gemini 4 Argon rows" {
  grep -A2 '^|-------|----------|' "$SKILL" | sed -n 2p | grep -q '^| GPT-6 Astra |'
  grep -A2 '^|-------|----------|' "$SKILL" | sed -n 3p | grep -q '^| Gemini 4 Argon |'
}

@test "CCW-191: the available-models block lists the same ids in the same order as --list" {
  awk '/^Available top-tier models:/{f=1;next} f&&/^```$/{n++; if(n==2)exit; next} f&&n==1{print $1}' "$SKILL" > "$BATS_TEST_TMPDIR/block-ids.txt"
  run "$BATS_TEST_DIRNAME/../bin/ecr-models-check" --list
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/block-ids.txt")" = "$output" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/block-ids.txt")" -eq 6 ]
}

@test "CCW-191: no stale model name in skills, bin, commands, agents, README" {
  cd "$BATS_TEST_DIRNAME/.."
  run grep -rnE 'gpt-5\.4|gemini-3\.1|claude-opus-4-8|Opus 4\.8|\bo3\b' skills bin commands agents README.md
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
