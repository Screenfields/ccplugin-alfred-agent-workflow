#!/usr/bin/env bats
# Behaviour tests for bin/ecr-models-check (CCW-106, rewritten in CCW-193): a
# thin caller of ecr-panel-resolve. curl is replaced by tests/stub/curl-gateway;
# the key is a fake.

load helpers/ecr-gateway

setup() {
  gw_setup
  CHK="$BATS_TEST_DIRNAME/../bin/ecr-models-check"
}

@test "no key: prints skipped, exits 0, makes no call, in both modes" {
  unset LITELLM_API_KEY
  run "$CHK"
  [ "$status" -eq 0 ]
  [ "$output" = "skipped: no LITELLM_API_KEY" ]
  run "$CHK" --models other-route
  [ "$status" -eq 0 ]
  [ "$output" = "skipped: no LITELLM_API_KEY" ]
  [ ! -e "$STUB_DIR/calls" ]
  no_leftovers
}

@test "all slots present and priced: exit 0, the output-only cost line shows" {
  run "$CHK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source=resolved external=3/3 voices=4"* ]]
  [[ "$output" == *"cost: prompt not given, output-only worst_usd=0.851200"* ]]
  no_leftovers
}

@test "a missing slot: exit 1 and the DROPPED line names it" {
  gw_models_mod '.data |= map(select(.id != "ecr-google"))'
  run "$CHK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DROPPED: ecr-google not offered to this key"* ]]
  no_leftovers
}

@test "fewer than two slots (resolver exit 4) maps to exit 1" {
  gw_models_mod '.data |= map(select(.id != "ecr-google" and .id != "ecr-openai"))'
  run "$CHK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fewer than 2 external voices"* ]]
  no_leftovers
}

@test "a slot without a price (resolver exit 5) maps to exit 1 with the REFUSED line" {
  gw_mod 'del(.data[] | select(.model_name == "ecr-google") | .model_info.input_cost_per_token)'
  run "$CHK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED: cost unknown: ecr-google input_cost_per_token absent"* ]]
  no_leftovers
}

@test "HTTP error, connection failure and a non-JSON body: exit 2, temp dir empty" {
  printf 401 > "$STUB_DIR/models.code"
  run "$CHK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"HTTP 401"* ]]
  rm "$STUB_DIR/models.code"; printf 7 > "$STUB_DIR/info.exit"
  run "$CHK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"connection failed (curl exit 7)"* ]]
  rm "$STUB_DIR/info.exit"; echo 'not json' > "$STUB_DIR/models.json"
  run "$CHK"
  [ "$status" -eq 2 ]
  no_leftovers
}

@test "--models, all present and priced: exit 0" {
  run "$CHK" --models other-route,ecr-openai
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: other-route"* ]]
  [[ "$output" == *"ok: ecr-openai"* ]]
  no_leftovers
}

@test "--models with one id absent: exit 1, MISSING first, no /v1/model/info call" {
  run "$CHK" --models other-route,gone-id
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING: gone-id"* ]]
  [ "$(calls_count '/v1/model/info')" -eq 0 ]
  no_leftovers
}

@test "--models with an id that is offered but has no info entry: exit 1, no model info entry" {
  gw_mod 'del(.data[] | select(.model_name == "other-route"))'
  run "$CHK" --models other-route
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED: cost unknown: other-route no model info entry"* ]]
  no_leftovers
}

@test "--models with an id whose output budget alone is above the cap: exit 1, REFUSED" {
  gw_mod '(.data[] | select(.model_name == "other-route") | .model_info.output_cost_per_token) = 1e-04'
  run "$CHK" --models other-route
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED: worst case cost"* ]]
  no_leftovers
}

@test "--models with a bad id: exit 2; with an HTTP 500: exit 2" {
  run "$CHK" --models 'bad id'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid model id"* ]]
  printf 500 > "$STUB_DIR/models.code"
  run "$CHK" --models other-route
  [ "$status" -eq 2 ]
  no_leftovers
}

@test "the retired options --list and --skill, and any other option, are usage errors (exit 2)" {
  for args in "--list" "--skill x" "--bogus" "--models"; do
    # shellcheck disable=SC2086
    run "$CHK" $args
    [ "$status" -eq 2 ] || { echo "args=$args"; return 1; }
    [[ "$output" == *"usage:"* ]]
  done
}

@test "each call sends the key through a mode-600 header file, never argv or output" {
  run "$CHK"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^MODE:600 Authorization: Bearer FAKEKEY-ccw193-Zq7$' "$STUB_DIR/hdr.log")" -eq 2 ]
  grep -q -- "-H @$TMPDIR/" "$STUB_DIR/argv.log"
  if grep -q FAKEKEY "$STUB_DIR/argv.log"; then false; fi
  if [[ "$output" == *FAKEKEY* ]]; then false; fi
  grep -q '/v1/models$' "$STUB_DIR/calls"
  grep -q '/v1/model/info$' "$STUB_DIR/calls"
  run "$CHK" --models other-route
  [ "$(grep -c '^MODE:600 ' "$STUB_DIR/hdr.log")" -eq 4 ]
}

@test "the temp directory is empty after a success and after a failure" {
  run "$CHK"
  [ "$status" -eq 0 ]
  no_leftovers
  echo 'not json' > "$STUB_DIR/info.json"
  run "$CHK"
  [ "$status" -eq 2 ]
  no_leftovers
}

@test "plugin version is 2.44.0" {
  [ "$(jq -r .version "$BATS_TEST_DIRNAME/../.claude-plugin/plugin.json")" = 2.44.0 ]
}

@test "no file under tests or .claude-plugin still carries the previous version" {
  run grep -rn '2\.43\.[01]' "$BATS_TEST_DIRNAME" "$BATS_TEST_DIRNAME/../.claude-plugin"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
