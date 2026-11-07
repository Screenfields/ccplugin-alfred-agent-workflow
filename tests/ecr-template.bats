#!/usr/bin/env bats
# CCW-189 and CCW-191: ECR template budgets, the output branch that makes a
# length-truncated, contentless reply visible as TRUNCATED, and (CCW-191) the
# option A panel: gpt-6-astra, gemini-4-argon, gpt-6.1-sol fallback, Claude voice on opus.

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

@test "CCW-191: runtime table row names Opus 5.5 and the opus alias" {
  grep -qxF '| Claude Code | Opus 5.5 (`claude-opus-5-5`) | `opus` |' "$SKILL"
}

@test "CCW-191: the Agent example has model opus and no other model line" {
  awk '/^Agent\(/{on=1} on{print} on&&/^\)/{exit}' "$SKILL" > "$BATS_TEST_TMPDIR/agent.txt"
  [ -s "$BATS_TEST_TMPDIR/agent.txt" ]
  [ "$(grep -c 'model:' "$BATS_TEST_TMPDIR/agent.txt")" -eq 1 ]
  grep -qxF '  model: "opus",' "$BATS_TEST_TMPDIR/agent.txt"
}

@test "CCW-191: the sub-agent prose, Step 4 table and full flow name Opus 5.5" {
  grep -q '^The sub-agent runs at `opus` (Opus 5\.5, `claude-opus-5-5`' "$SKILL"
  grep -qF '| Claude Opus 5.5 | Anthropic (sub-agent) |' "$SKILL"
  grep -qF 'spawns Claude Opus 5.5 sub-agent' "$SKILL"
}

@test "CCW-196: the only claude- id is claude-opus-5-5 and no Fable or fable remains" {
  [ "$(grep -o 'claude-[a-z0-9-]*' "$SKILL" | sort -u)" = claude-opus-5-5 ]
  [ "$(grep -ci fable "$SKILL")" -eq 0 ]
  [ "$(grep -ci highest "$SKILL")" -eq 0 ]
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

# CCW-194: the gateway key stays off curl's command line.

@test "CCW-194: no argv Authorization header in the ecr or onboard skill" {
  ONBOARD="$BATS_TEST_DIRNAME/../skills/onboard/SKILL.md"
  run grep -nE -e "-H \"Authorization|-H 'Authorization" "$SKILL" "$ONBOARD"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "CCW-194: the ecr template passes the header as a file" {
  grep -qF -e '-H @"$tmp/hdr"' "$SKILL"
}

@test "CCW-194: onboard has no curl or --header line with Bearer \$ or \$(cat, and uses -H @" {
  ONBOARD="$BATS_TEST_DIRNAME/../skills/onboard/SKILL.md"
  if grep -E 'curl|--header' "$ONBOARD" | grep -qE -e 'Bearer \$|\$\(cat'; then false; fi
  grep -qF -e '-H @' "$ONBOARD"
}

# The whole template fence: from the '# LITELLM_URL:' line to the closing fence line.
setup_template() {
  awk '/^# LITELLM_URL:/{on=1} on&&/^```/{exit} on{print}' "$SKILL" \
    | sed 's/MODEL_ID/fixture-model/' > "$BATS_TEST_TMPDIR/template.sh"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/template.sh")" -ge 30 ]
  [ "$(tail -n1 "$BATS_TEST_TMPDIR/template.sh")" = fi ]
  mkdir -p "$BATS_TEST_TMPDIR/t" "$BATS_TEST_TMPDIR/bin"
  ln -sf "$BATS_TEST_DIRNAME/stub/curl-argv" "$BATS_TEST_TMPDIR/bin/curl"
  export CURL_ARGV_LOG="$BATS_TEST_TMPDIR/curl-argv.log" # outside $BATS_TEST_TMPDIR/t
  : > "$CURL_ARGV_LOG"
  SAVED=""
  if [ -e /tmp/ecr-prompt.txt ]; then SAVED="$BATS_TEST_TMPDIR/prompt.saved"; cp -p /tmp/ecr-prompt.txt "$SAVED"; fi
  echo "fixture prompt" > /tmp/ecr-prompt.txt
}

teardown_template() {
  if [ -n "${SAVED:-}" ]; then cp -p "$SAVED" /tmp/ecr-prompt.txt; else rm -f /tmp/ecr-prompt.txt; fi
}

@test "CCW-194: template run keeps the key out of argv, header file is mode 600 under TMPDIR, temp dir is gone" {
  setup_template
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" LITELLM_API_KEY=FAKEKEY-ccw194-Zq7 TMPDIR="$BATS_TEST_TMPDIR/t" bash "$BATS_TEST_TMPDIR/template.sh"
  teardown_template
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ -s "$CURL_ARGV_LOG" ]
  if grep -q 'FAKEKEY-ccw194-Zq7' "$CURL_ARGV_LOG"; then false; fi
  grep -q ' MODE: 600$' "$CURL_ARGV_LOG"
  grep -q "^HDRFILE: $BATS_TEST_TMPDIR/t/" "$CURL_ARGV_LOG"
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/t")" ]
}

@test "CCW-194: template without a credential exits 1, makes no curl call, leaves no temp dir" {
  setup_template
  run env -u LITELLM_API_KEY PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" TMPDIR="$BATS_TEST_TMPDIR/t" bash "$BATS_TEST_TMPDIR/template.sh"
  teardown_template
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: no LiteLLM credential available for the ECR skill."* ]]
  [ ! -s "$CURL_ARGV_LOG" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/t")" ]
}
