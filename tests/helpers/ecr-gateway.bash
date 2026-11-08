# Shared fixtures for the ECR bats files (CCW-193): a stubbed LiteLLM gateway
# (tests/stub/curl-gateway) and a fake key. Source from setup().

gw_setup() {
  RES="$BATS_TEST_DIRNAME/../bin/ecr-panel-resolve"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"
  export TMPDIR="$BATS_TEST_TMPDIR/t"
  mkdir -p "$STUB_DIR" "$TMPDIR" "$BATS_TEST_TMPDIR/bin"
  ln -sf "$BATS_TEST_DIRNAME/stub/curl-gateway" "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export LITELLM_URL="http://litellm.invalid"
  export LITELLM_API_KEY="FAKEKEY-ccw193-Zq7"
  unset ALFRED_THRESHOLDS
  OUTF="$BATS_TEST_TMPDIR/out/panel.tsv"
  mkdir -p "$BATS_TEST_TMPDIR/out"
  gw_fixture1
}

# gw_entry name provider served timeout maxtok inprice outprice -> one /v1/model/info entry
gw_entry() {
  jq -n --arg n "$1" --arg p "$2" --arg s "$3" --argjson t "$4" --argjson m "$5" --argjson i "$6" --argjson o "$7" '
    {model_name: $n, litellm_params: {model: $s, max_tokens: 32000},
     model_info: {litellm_provider: $p, max_output_tokens: 128000, ecr_schema: 1, ecr_timeout_s: $t, ecr_max_tokens: $m,
                  input_cost_per_token: $i, output_cost_per_token: $o}}'
}

# Fixture 1: the G8 prices, with ecr-fireworks at 48000 tokens (the numbers of
# the addendum's cost examples). Extra routes carry old ids so a leak shows.
gw_fixture1() {
  {
    gw_entry ecr-openai openai alpha-model-1 180 32000 2e-06 1e-05
    gw_entry ecr-google gemini gemini/beta-model-2 180 32000 2e-06 1e-05
    gw_entry ecr-fireworks fireworks_ai fireworks_ai/models/gamma-3 590 48000 1.4e-06 4.4e-06
    gw_entry other-route openai gpt-other 100 8000 1e-06 1e-06
  } | jq -s '{data: .}' > "$STUB_DIR/info.json"
  jq '{data: [.data[].model_name | {id: .}]}' "$STUB_DIR/info.json" > "$STUB_DIR/models.json"
}

# Fixture 2: different models, providers, settings and prices.
gw_fixture2() {
  {
    gw_entry ecr-openai openai delta-model-9 120 20000 3e-06 6e-06
    gw_entry ecr-google gemini gemini/epsilon-7 240 16000 1e-06 2e-06
    gw_entry ecr-fireworks fireworks_ai fireworks_ai/models/zeta-1 300 24000 5e-07 1e-06
  } | jq -s '{data: .}' > "$STUB_DIR/info.json"
  jq '{data: [.data[].model_name | {id: .}]}' "$STUB_DIR/info.json" > "$STUB_DIR/models.json"
}

# gw_mod <jq filter> : edit info.json in place
gw_mod() { jq -c "$1" "$STUB_DIR/info.json" > "$STUB_DIR/info.tmp" && mv "$STUB_DIR/info.tmp" "$STUB_DIR/info.json"; }
# gw_models_mod <jq filter> : edit models.json in place
gw_models_mod() { jq -c "$1" "$STUB_DIR/models.json" > "$STUB_DIR/models.tmp" && mv "$STUB_DIR/models.tmp" "$STUB_DIR/models.json"; }

# mkprompt <bytes> [file]
mkprompt() {
  P="${2:-$BATS_TEST_TMPDIR/prompt.txt}"
  head -c "$1" /dev/zero | tr '\0' 'a' > "$P"
}

# panel_file : the panel-file= value from $output
panel_file() { printf '%s\n' "$output" | sed -n 's/^panel-file=//p' | head -n1; }

# no_leftovers : the temp directory holds nothing
no_leftovers() { [ -z "$(ls -A "$TMPDIR")" ]; }

# calls_count <pattern> : lines of the stub's call log that match
calls_count() { { grep -c -- "$1" "$STUB_DIR/calls" 2>/dev/null || true; } | head -n1; }
