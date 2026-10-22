#!/usr/bin/env bats
# Behaviour tests for bin/ecr-models-check (CCW-106): every model named in the
# ecr skill's two tables must be on the LiteLLM key. curl is replaced by
# tests/stub/curl-models; the key is a fake.

setup() {
  CHK="$BATS_TEST_DIRNAME/../bin/ecr-models-check"
  SKILL="$BATS_TEST_DIRNAME/../skills/ecr/SKILL.md"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR" "$BATS_TEST_TMPDIR/bin"
  ln -s "$BATS_TEST_DIRNAME/stub/curl-models" "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export LITELLM_URL="http://litellm.invalid"
  export LITELLM_API_KEY="sk-fake-secret-key"
  EXPECTED="gpt-5.4 gemini-3.1-pro glm-5.3 kimi-k3 deepseek-v4.1-flash o3"
}

models_json() { # ids... -> {"data":[{"id":..}]}
  printf '%s\n' "$@" | jq -R '{id: .}' | jq -s '{data: .}' > "$STUB_DIR/models.json"
}

@test "all models present: exits 0 and reports ok" {
  # shellcheck disable=SC2086
  models_json $EXPECTED gpt-4.1 gemini
  run "$CHK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: glm-5.3"* ]]
}

@test "a model missing from the key: exits non-zero and names it" {
  models_json gpt-5.4 gemini-3.1-pro kimi-k3 deepseek-v4.1-flash o3
  run "$CHK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING: glm-5.3"* ]]
}

@test "the retired ids are reported missing when the skill still names them" {
  models_json gpt-5.4 gemini-3.1-pro o3
  sed 's/glm-5\.3/glm-5.1/' "$SKILL" > "$BATS_TEST_TMPDIR/old.md"
  run "$CHK" --skill "$BATS_TEST_TMPDIR/old.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING: glm-5.1"* ]]
}

@test "no key: prints skipped, exits 0, does not call curl" {
  unset LITELLM_API_KEY
  run "$CHK"
  [ "$status" -eq 0 ]
  [ "$output" = "skipped: no LITELLM_API_KEY" ]
  if [ -e "$STUB_DIR/argv" ]; then false; fi
}

@test "HTTP error from the endpoint: exits 2" {
  models_json o3
  printf 401 > "$STUB_DIR/code"
  run "$CHK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"HTTP 401"* ]]
}

@test "key goes through a mode-600 header file, never argv or output" {
  # shellcheck disable=SC2086
  models_json $EXPECTED
  run "$CHK"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/hdr.mode")" = 600 ]
  [ "$(cat "$STUB_DIR/hdr")" = "Authorization: Bearer sk-fake-secret-key" ]
  grep -q '^@' "$STUB_DIR/argv"
  if grep -q 'sk-fake-secret-key' "$STUB_DIR/argv"; then false; fi
  if [[ "$output" == *sk-fake-secret-key* ]]; then false; fi
  grep -qx 'http://litellm.invalid/v1/models' "$STUB_DIR/argv"
}

@test "the header file is deleted after the run" {
  # shellcheck disable=SC2086
  models_json $EXPECTED
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  run "$CHK"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "the models parsed from the skill's two tables match the expected list" {
  run "$CHK" --list
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' $EXPECTED)" ]
}

@test "every backticked model row in the skill's tables is in the list, none extra" {
  rows=$(awk '/^### (External Panel|Alternative External Models)/{on=1;next} /^#/{on=0} on&&/^\| `/' "$SKILL" | wc -l)
  [ "$rows" -eq 6 ]
  for m in $EXPECTED; do grep -q "^| \`$m\` |" "$SKILL"; done
}

@test "the skill names no retired model" {
  for m in glm-5.1 kimi-k2 deepseek-v4-pro; do
    if grep -qi -- "$m" "$SKILL"; then false; fi
  done
}

@test "panel table: glm-5.3 has 400s and 32000 and a reasoning note" {
  line=$(grep '^| `glm-5.3`' "$SKILL")
  [[ "$line" == *"reasoning"* ]]
  [[ "$line" == *"| 400s | 32000 |" ]]
  grep -q '^| `gpt-5.4`' "$SKILL"
  grep -q '^| `gemini-3.1-pro`' "$SKILL"
}

@test "alternatives table: kimi-k3 600s slow, deepseek-v4.1-flash budget, o3" {
  line=$(grep '^| `kimi-k3`' "$SKILL")
  [[ "$line" == *"slow, untested to completion"* ]]
  [[ "$line" == *"| 600s |"* ]]
  grep '^| `deepseek-v4.1-flash`' "$SKILL" | grep -qi budget
  grep -q '^| `o3`' "$SKILL"
}

@test "bash template comments match the table" {
  grep -q '^# Timeout: .*400s glm-5.3; 600s kimi-k3' "$SKILL"
  grep -q '^# max_tokens: .*32000 for glm-5.3 and kimi-k3' "$SKILL"
  grep -q '^TIMEOUT=90 .*400 glm-5.3, 600 kimi-k3' "$SKILL"
  grep -q '^MAX_TOKENS=8000 .*32000 glm-5.3 and kimi-k3' "$SKILL"
}

@test "plugin version is 2.30.0" {
  [ "$(jq -r .version "$BATS_TEST_DIRNAME/../.claude-plugin/plugin.json")" = 2.30.0 ]
}

# --- parser strictness: a reworded table must fail loudly, never drop models ---

mutate() { # sed-expr -> $BATS_TEST_TMPDIR/mut.md
  sed "$1" "$SKILL" > "$BATS_TEST_TMPDIR/mut.md"
}

@test "renamed alternatives heading: exit 2" {
  mutate 's/^### Alternative External Models/### Other Models/'
  run "$CHK" --list --skill "$BATS_TEST_TMPDIR/mut.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"heading not found"* ]]
}

@test "renamed panel heading: exit 2" {
  mutate 's/^### External Panel.*/### The Panel/'
  run "$CHK" --list --skill "$BATS_TEST_TMPDIR/mut.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"heading not found"* ]]
}

@test "a section with zero ids: exit 2" {
  mutate '/^| `\(kimi-k3\|deepseek-v4.1-flash\|o3\)`/d'
  run "$CHK" --list --skill "$BATS_TEST_TMPDIR/mut.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no model ids"* ]]
}

@test "a row with no backticked id: exit 2" {
  mutate 's/^| `o3` |/| o3 |/'
  run "$CHK" --list --skill "$BATS_TEST_TMPDIR/mut.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unparsable row"* ]]
}

@test "a bolded id is still parsed" {
  mutate 's/^| `o3` |/| **`o3`** |/'
  run "$CHK" --list --skill "$BATS_TEST_TMPDIR/mut.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' $EXPECTED)" ]
}

@test "a missing space after the pipe is still parsed" {
  mutate 's/^| `o3` |/|`o3` |/'
  run "$CHK" --list --skill "$BATS_TEST_TMPDIR/mut.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' $EXPECTED)" ]
}

# --- fetch failures and cleanup ---

@test "curl failure (code 000): exits 2" {
  models_json o3
  printf 000 > "$STUB_DIR/code"
  run "$CHK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"HTTP 000"* ]]
}

@test "non-JSON body: exits 2" {
  echo '<html>gateway</html>' > "$STUB_DIR/models.json"
  run "$CHK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no models in response"* ]]
}

@test "the header file is deleted when the run fails" {
  echo 'not json' > "$STUB_DIR/models.json"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  run "$CHK"
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}
