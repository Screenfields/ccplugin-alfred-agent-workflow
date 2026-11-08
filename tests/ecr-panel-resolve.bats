#!/usr/bin/env bats
# CCW-193: bin/ecr-panel-resolve resolves the ECR panel from the LiteLLM gateway.
# curl is replaced by tests/stub/curl-gateway; the key is a fake. Acceptance
# criteria 1, 3 to 7, 10, 15, 17 to 21 and 23 of the design and its addendum.

load helpers/ecr-gateway

setup() {
  gw_setup
  OLD_IDS="gpt-6-astra gemini-4-argon glm-5.3 kimi-k3 deepseek-v4.1-flash gpt-6.1-sol gpt-5.4 gemini-3.1-pro"
  X="$BATS_TEST_TMPDIR/X"
  mkprompt 1000
}

# set_field <slot> <jq path under the entry> <json literal>
set_field() { gw_mod "(.data[] | select(.model_name == \"$1\") | $2) = $3"; }
del_field() { gw_mod "del(.data[] | select(.model_name == \"$1\") | $2)"; }
voice_line() { printf '%s\n' "$output" | grep "^voice=$1 "; }
panel_row() { sed -n '2,$p' "$1" | awk -F'\t' -v s="$2" '$1 == s'; }

# ---- criterion 1: the panel follows the gateway ----------------------------

@test "fixture 1: voices, served values and settings follow the stub; no old id in the output" {
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -n1)" = "ecr-panel-resolve: source=resolved external=3/3 voices=4" ]
  [[ "$(printf '%s\n' "$output" | sed -n 2p)" == panel-file=* ]]
  [[ "$output" == *"voice=ecr-openai model=ecr-openai served=alpha-model-1 provider=openai timeout=180 max_tokens=32000 origin=resolved settings=published"* ]]
  [[ "$output" == *"voice=ecr-google model=ecr-google served=gemini/beta-model-2 provider=gemini timeout=180 max_tokens=32000 origin=resolved settings=published"* ]]
  [[ "$output" == *"voice=ecr-fireworks model=ecr-fireworks served=fireworks_ai/models/gamma-3 provider=fireworks_ai timeout=590 max_tokens=48000 origin=resolved settings=published"* ]]
  for id in $OLD_IDS; do [[ "$output" != *"$id"* ]]; done
  f=$(panel_file)
  [ "$(sed -n 1p "$f")" = "$(printf '#ecr-panel\t1\tsource=resolved\texternal_expected=3\texternal_resolved=3\tvoices=4\tprompt_bytes=1000\tcost_usd=0.780800')" ] || true
  [[ "$(sed -n 1p "$f")" == $'#ecr-panel\t1\tsource=resolved\texternal_expected=3\texternal_resolved=3\tvoices=4\tprompt_bytes=1000\tcost_usd='* ]]
  [ "$(sed -n 2p "$f")" = "$(printf 'ecr-openai\tecr-openai\topenai\talpha-model-1\t180\t32000\tresolved\tpublished')" ]
  [ "$(wc -l < "$f")" -eq 4 ]
}

@test "fixture 2: a different gateway gives a different panel, with no plugin change" {
  gw_fixture2
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"voice=ecr-openai model=ecr-openai served=delta-model-9 provider=openai timeout=120 max_tokens=20000 origin=resolved settings=published"* ]]
  [[ "$output" == *"voice=ecr-google model=ecr-google served=gemini/epsilon-7 provider=gemini timeout=240 max_tokens=16000"* ]]
  [[ "$output" == *"voice=ecr-fireworks model=ecr-fireworks served=fireworks_ai/models/zeta-1 provider=fireworks_ai timeout=300 max_tokens=24000"* ]]
  for id in alpha-model-1 beta-model-2 gamma-3 $OLD_IDS; do [[ "$output" != *"$id"* ]]; done
}

@test "--slots prints the three slot names in order" {
  run "$RES" --slots
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ecr-openai\necr-google\necr-fireworks')" ]
}

# ---- criterion 3: one provider per voice ----------------------------------

@test "two slots on one provider: the later is dropped, external=2/3, exit 1" {
  set_field ecr-google .model_info.litellm_provider '"openai"'
  run "$RES" --prompt "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"external=2/3 voices=3"* ]]
  [[ "$output" == *"DROPPED: ecr-google same provider as ecr-openai"* ]]
  [[ "$output" == *"voice=ecr-fireworks "* ]]
  [[ "$output" != *"voice=ecr-google "* ]]
  [ "$(wc -l < "$(panel_file)")" -eq 3 ]
}

@test "an extra ecr-openai-b slot on the key is ignored, named and never called" {
  gw_models_mod '.data += [{id: "ecr-openai-b"}]'
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: ignored unknown ecr-* slots (count 1: ecr-openai-b)"* ]]
  [[ "$output" != *"voice=ecr-openai-b"* ]]
  [ "$(wc -l < "$(panel_file)")" -eq 4 ]
}

# ---- criterion 4: override --------------------------------------------------

@test "--models: rows are exactly the given ids, origin=override, one info GET and no models GET" {
  run "$RES" --models other-route,ecr-fireworks --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source=override external=2/2 voices=3"* ]]
  f=$(panel_file)
  [ "$(wc -l < "$f")" -eq 3 ]
  [ "$(sed -n 2p "$f")" = "$(printf 'override-1\tother-route\t-\t-\t400\t32000\toverride\tdefault')" ]
  # a slot alias given to --models takes that slot's published settings
  [ "$(sed -n 3p "$f")" = "$(printf 'override-2\tecr-fireworks\t-\t-\t590\t48000\toverride\tpublished')" ]
  [ "$(calls_count '/v1/model/info')" -eq 1 ]
  [ "$(calls_count '/v1/models$')" -eq 0 ]
  [ "$(calls_count chat)" -eq 0 ]
}

@test "--models with an invalid, repeated, empty or too long list: exit 2, id not echoed" {
  for arg in 'a b' 'a,a' '' 'a,b,c,d,e' '-x' 'x;touch' ',a' 'a,,b' "$(printf 'a\nb')"; do
    run "$RES" --models "$arg" --prompt "$P"
    [ "$status" -eq 2 ] || { echo "arg=[$arg] status=$status"; return 1; }
    [[ "$output" == *"invalid model id"* ]]
    [ ! -e "$STUB_DIR/calls" ]
  done
}

# ---- criterion 5: call settings ----------------------------------------------

@test "settings published, absent: the file and the output say which" {
  del_field ecr-openai .model_info.ecr_timeout_s
  del_field ecr-google .model_info.ecr_max_tokens
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: ecr-openai ecr_timeout_s absent; default 400"* ]]
  [[ "$output" == *"note: ecr-google ecr_max_tokens absent; default 32000"* ]]
  [[ "$output" == *"voice=ecr-openai model=ecr-openai served=alpha-model-1 provider=openai timeout=400 max_tokens=32000 origin=resolved settings=default"* ]]
  [[ "$output" == *"voice=ecr-google "*"timeout=180 max_tokens=32000 origin=resolved settings=default"* ]]
  [[ "$output" == *"voice=ecr-fireworks "*"settings=published"* ]]
}

@test "malformed ecr_timeout_s (string, boolean, null, array, object, fraction, 0, negative, huge, below 10): default 400 with a note" {
  for v in '"180"' true null '[180]' '{"a":1}' '180.5' 0 -5 1e30 9; do
    gw_fixture1
    set_field ecr-openai .model_info.ecr_timeout_s "$v"
    run "$RES" --prompt "$P"
    [ "$status" -eq 0 ] || { echo "v=$v status=$status"; return 1; }
    [[ "$output" == *"note: ecr-openai ecr_timeout_s invalid; default 400"* ]] || { echo "v=$v"; return 1; }
    [[ "$output" == *"voice=ecr-openai "*"timeout=400 max_tokens=32000 origin=resolved settings=default"* ]]
  done
}

@test "malformed ecr_max_tokens (string, boolean, null, array, fraction, 0, negative, huge, below 1024, above 65536): default 32000 with a note" {
  for v in '"32000"' false null '[1]' 2048.5 0 -5 1e30 1000 65537; do
    gw_fixture1
    set_field ecr-google .model_info.ecr_max_tokens "$v"
    run "$RES" --prompt "$P"
    [ "$status" -eq 0 ] || { echo "v=$v status=$status"; return 1; }
    [[ "$output" == *"note: ecr-google ecr_max_tokens invalid; default 32000"* ]] || { echo "v=$v"; return 1; }
    [[ "$output" == *"voice=ecr-google "*"max_tokens=32000 origin=resolved settings=default"* ]]
  done
}

@test "ecr_timeout_s of 900 is clamped to 590 with a note; the panel still counts as published" {
  set_field ecr-openai .model_info.ecr_timeout_s 900
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: ecr-openai ecr_timeout_s clamped to 590 (tool cap)"* ]]
  [[ "$output" == *"voice=ecr-openai "*"timeout=590 max_tokens=32000 origin=resolved settings=published"* ]]
}

@test "ecr_max_tokens above a valid max_output_tokens is clamped down, and the clamped value is the priced one" {
  set_field ecr-openai .model_info.max_output_tokens 20000
  run "$RES" --prompt "$P" --out "$OUTF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: ecr-openai ecr_max_tokens clamped to max_output_tokens"* ]]
  [[ "$output" == *"voice=ecr-openai "*"max_tokens=20000 "* ]]
  [ "$(panel_row "$OUTF" ecr-openai | cut -f6)" = 20000 ]
  # 200000 + 320000 + 211200 output, plus the input terms of a 1000-byte prompt
  [[ "$output" == *"cost: worst_usd=0.733"* ]]
}

@test "ecr_schema absent or not 1: every ecr_* field of the slot is ignored, defaults, named" {
  del_field ecr-openai .model_info.ecr_schema
  set_field ecr-google .model_info.ecr_schema 2
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: ecr-openai ecr_schema absent; settings default"* ]]
  [[ "$output" == *"note: ecr-google schema unsupported; defaults"* ]]
  [[ "$output" == *"voice=ecr-openai "*"timeout=400 max_tokens=32000 origin=resolved settings=default"* ]]
  [[ "$output" == *"voice=ecr-google "*"timeout=400 max_tokens=32000 origin=resolved settings=default"* ]]
}

@test "entries sharing one model_name that disagree on ecr_* fields give the defaults, with a note" {
  gw_mod '.data += [(.data[0] | .model_info.ecr_timeout_s = 200)]'
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: ecr-openai entries disagree on ecr_* fields; defaults"* ]]
  [[ "$output" == *"voice=ecr-openai "*"timeout=400 max_tokens=32000 origin=resolved settings=default"* ]]
}

# ---- criterion 6: every failure row ------------------------------------------

@test "F1 no key: exit 3, no call, both routes named" {
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/op"; chmod +x "$BATS_TEST_TMPDIR/bin/op"
  run env -u LITELLM_API_KEY "$RES" --prompt "$P"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no LiteLLM credential"* ]]
  [[ "$output" == *"LITELLM_API_KEY"* ]]
  [[ "$output" == *"op read"* ]]
  [ ! -e "$STUB_DIR/calls" ]
  no_leftovers
}

@test "F1 op is used when the env var is unset" {
  printf '#!/bin/sh\necho FAKEKEY-from-op\n' > "$BATS_TEST_TMPDIR/bin/op"; chmod +x "$BATS_TEST_TMPDIR/bin/op"
  run env -u LITELLM_API_KEY "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  grep -q 'Authorization: Bearer FAKEKEY-from-op' "$STUB_DIR/hdr.log"
}

@test "F2 HTTP 401 and 403 on either endpoint: exit 3 naming the endpoint and code" {
  printf 401 > "$STUB_DIR/models.code"
  run "$RES" --prompt "$P"
  [ "$status" -eq 3 ]
  [[ "$output" == *"GET /v1/models failed (HTTP 401)"* ]]
  rm "$STUB_DIR/models.code"; printf 403 > "$STUB_DIR/info.code"
  run "$RES" --prompt "$P"
  [ "$status" -eq 3 ]
  [[ "$output" == *"GET /v1/model/info failed (HTTP 403)"* ]]
  no_leftovers
}

@test "F3 HTTP 500 and 429: exit 3, no retry, no panel file" {
  for c in 500 429 404; do
    rm -f "$STUB_DIR/calls"; printf %s "$c" > "$STUB_DIR/models.code"
    run "$RES" --prompt "$P"
    [ "$status" -eq 3 ]
    [[ "$output" == *"(HTTP $c)"* ]]
    [ "$(calls_count '/v1/models$')" -eq 1 ]
    no_leftovers
  done
}

@test "F4 connection failure or timeout: exit 3 with the curl exit status" {
  printf 7 > "$STUB_DIR/models.exit"
  run "$RES" --prompt "$P"
  [ "$status" -eq 3 ]
  [[ "$output" == *"connection failed (curl exit 7)"* ]]
  rm "$STUB_DIR/models.exit"; printf 28 > "$STUB_DIR/info.exit"
  run "$RES" --prompt "$P"
  [ "$status" -eq 3 ]
  [[ "$output" == *"connection failed (curl exit 28)"* ]]
  no_leftovers
}

@test "F5 a body that is not JSON: exit 3" {
  echo '<html>gateway</html>' > "$STUB_DIR/models.json"
  run "$RES" --prompt "$P"
  [ "$status" -eq 3 ]
  [[ "$output" == *"response is not JSON"* ]]
  [[ "$output" != *"gateway"* ]]
  no_leftovers
}

@test "F6 an empty model list: exit 3" {
  echo '{"data":[]}' > "$STUB_DIR/models.json"
  run "$RES" --prompt "$P"
  [ "$status" -eq 3 ]
  [[ "$output" == *"empty model list"* ]]
}

@test "F7 a wrong shape on either endpoint: exit 3" {
  for body in '{"data":"x"}' '{"x":1}' '{"data":[{"id":5}]}' '{"data":[{"name":"a"}]}' '[1]'; do
    echo "$body" > "$STUB_DIR/models.json"
    run "$RES" --prompt "$P"
    [ "$status" -eq 3 ] || { echo "body=$body"; return 1; }
    [[ "$output" == *"unexpected /v1/models shape"* ]]
  done
  gw_fixture1
  echo '{"data":[{"model_name":7}]}' > "$STUB_DIR/info.json"
  run "$RES" --prompt "$P"
  [ "$status" -eq 3 ]
  [[ "$output" == *"unexpected /v1/model/info shape"* ]]
  no_leftovers
}

@test "F8 a slot not offered: dropped by name, external=2/3, exit 1; fewer than 2 gives exit 4 and no file" {
  gw_models_mod '.data |= map(select(.id != "ecr-google"))'
  run "$RES" --prompt "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DROPPED: ecr-google not offered to this key"* ]]
  [[ "$output" == *"external=2/3"* ]]
  rm -rf "${TMPDIR:?}"/*
  gw_models_mod '.data |= map(select(.id != "ecr-openai"))'
  run "$RES" --prompt "$P"
  [ "$status" -eq 4 ]
  [[ "$output" == *"DROPPED: ecr-openai not offered to this key"* ]]
  [[ "$output" == *"fewer than 2 external voices"* ]]
  no_leftovers
}

@test "F10 a slot with no info entry, or a missing, wrongly typed or hostile provider: dropped by name" {
  gw_mod '.data |= map(select(.model_name != "ecr-google"))'
  run "$RES" --prompt "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DROPPED: ecr-google provider missing"* ]]
  for v in null 7 true '"A B"' '"x;touch"' '""' '"Upper"'; do
    gw_fixture1
    set_field ecr-fireworks .model_info.litellm_provider "$v"
    run "$RES" --prompt "$P"
    [ "$status" -eq 1 ] || { echo "v=$v status=$status"; return 1; }
    [[ "$output" == *"DROPPED: ecr-fireworks provider missing"* ]]
  done
  gw_fixture1
  del_field ecr-fireworks .model_info.litellm_provider
  run "$RES" --prompt "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DROPPED: ecr-fireworks provider missing"* ]]
}

@test "entries of one slot that disagree on the provider: dropped as inconsistent" {
  gw_mod '.data += [(.data[0] | .model_info.litellm_provider = "other")]'
  run "$RES" --prompt "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DROPPED: ecr-openai inconsistent entries"* ]]
}

@test "F16 served model absent or hostile: shown as -, with a note" {
  del_field ecr-openai .litellm_params.model
  set_field ecr-google .litellm_params.model '"a b$(touch)"'
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: ecr-openai served model unknown"* ]]
  [[ "$output" == *"note: ecr-google served model unknown"* ]]
  [[ "$output" == *"voice=ecr-openai model=ecr-openai served=- "* ]]
  [[ "$output" != *"touch"* ]]
}

@test "F18 and F19 option mixes and missing arguments: exit 2 with the usage text" {
  for args in "--quick --models a" "--verify" "--list-offered --quick" "--list-offered --models a" "--slots --quick" \
              "--clean" "--models" "--prompt" "--bogus" "--clean x --slots" "--list-offered --slots"; do
    # shellcheck disable=SC2086
    run "$RES" $args --prompt "$P"
    [ "$status" -eq 2 ] || { echo "args=$args status=$status"; return 1; }
    [[ "$output" == *"usage:"* ]]
  done
  [ ! -e "$STUB_DIR/calls" ]
}

@test "F20 a missing jq, mktemp or curl: exit 2 naming the tool" {
  tools="bash readlink dirname basename cat tr wc head tail sed grep rm mkdir mv stat chmod printf touch sort"
  for missing in jq mktemp curl; do
    d="$BATS_TEST_TMPDIR/path-no-$missing"; mkdir -p "$d"
    for t in $tools jq mktemp env; do
      [ "$t" = "$missing" ] && continue
      src=$(command -v "$t") && ln -sf "$src" "$d/$t"
    done
    [ "$missing" = curl ] || ln -sf "$BATS_TEST_DIRNAME/stub/curl-gateway" "$d/curl"
    run env PATH="$d" "$(command -v bash)" "$RES" --prompt "$P"
    [ "$status" -eq 2 ] || { echo "missing=$missing status=$status out=$output"; return 1; }
    [[ "$output" == *"$missing not found"* ]]
  done
  # mktemp that fails (TMPDIR is not a directory)
  run env TMPDIR="$BATS_TEST_TMPDIR/nonexistent" "$RES" --prompt "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *"mktemp failed"* ]]
}

@test "F21 an invalid LITELLM_URL: exit 2, no call, value not echoed" {
  run env LITELLM_URL='http://x/$(touch)' "$RES" --prompt "$P"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid LITELLM_URL"* ]]
  [[ "$output" != *"touch"* ]]
  [ ! -e "$STUB_DIR/calls" ]
}

@test "F22 and F23 --list-offered: only charset-passing ids, sorted, with provider; the rest counted" {
  gw_models_mod '.data += [{id: "bad id;x"}, {id: "line\nbreak"}, {id: ("a" * 65)}, {id: "-lead"}]'
  run "$RES" --list-offered
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: 4 offered ids not shown (invalid characters)"* ]]
  [[ "$output" != *"bad id"* ]]
  [[ "$output" != *"break"* ]]
  lines=$(printf '%s\n' "$output" | grep -v '^note:')
  [ "$lines" = "$(printf '%s\n' "$lines" | sort)" ]
  [[ "$lines" == *$'ecr-google\tgemini'* ]]
  [[ "$lines" == *$'ecr-openai\topenai'* ]]
  [[ "$lines" == *$'other-route\topenai'* ]]
  echo '{"data":[{"id":"bad id"}]}' > "$STUB_DIR/models.json"
  run "$RES" --list-offered
  [ "$status" -eq 3 ]
  [[ "$output" == *"no usable ids"* ]]
}

@test "--list-offered: lookup failures exit 3, and it needs no prompt" {
  printf 500 > "$STUB_DIR/models.code"
  run "$RES" --list-offered
  [ "$status" -eq 3 ]
  rm "$STUB_DIR/models.code"; printf 7 > "$STUB_DIR/info.exit"
  run "$RES" --list-offered
  [ "$status" -eq 3 ]
  no_leftovers
}

@test "a failed run leaves no panel directory; a successful one leaves exactly one" {
  printf 500 > "$STUB_DIR/info.code"
  run "$RES" --prompt "$P"
  [ "$status" -eq 3 ]
  no_leftovers
  rm "$STUB_DIR/info.code"
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [ "$(ls -A "$TMPDIR" | wc -l)" -eq 1 ]
  [ -f "$(panel_file)" ]
}

# ---- per-run directory and --clean ------------------------------------------------

@test "two runs get two different directories at mode 700, and --clean removes only a real one" {
  run "$RES" --prompt "$P"; f1=$(panel_file)
  run "$RES" --prompt "$P"; f2=$(panel_file)
  [ "$(dirname "$f1")" != "$(dirname "$f2")" ]
  [ "$(stat -c %a "$(dirname "$f1")")" = 700 ]
  [[ "$(basename "$(dirname "$f1")")" =~ ^ecr-panel\.[A-Za-z0-9]{6}$ ]]
  mkdir "$(dirname "$f1")/called.ecr-openai"
  run "$RES" --clean "$f1"
  [ "$status" -eq 0 ]
  [ ! -e "$(dirname "$f1")" ]
  [ -e "$f2" ]
}

@test "F24 --clean refuses a symlink, a foreign name, a directory without the header, a foreign parent" {
  mkdir "$TMPDIR/real-target"; ln -s "$TMPDIR/real-target" "$TMPDIR/ecr-panel.LINK01"
  printf '#ecr-panel\t1\n' > "$TMPDIR/real-target/panel.tsv"
  run "$RES" --clean "$TMPDIR/ecr-panel.LINK01/panel.tsv"
  [ "$status" -eq 2 ]; [[ "$output" == *"refusing to remove <not a panel dir>"* ]]
  [ -e "$TMPDIR/real-target/panel.tsv" ]
  mkdir "$TMPDIR/foreign"; printf '#ecr-panel\t1\n' > "$TMPDIR/foreign/panel.tsv"
  run "$RES" --clean "$TMPDIR/foreign/panel.tsv"
  [ "$status" -eq 2 ]; [ -e "$TMPDIR/foreign/panel.tsv" ]
  mkdir "$TMPDIR/ecr-panel.NOHDR1"; echo "not a panel" > "$TMPDIR/ecr-panel.NOHDR1/panel.tsv"
  run "$RES" --clean "$TMPDIR/ecr-panel.NOHDR1/panel.tsv"
  [ "$status" -eq 2 ]; [ -e "$TMPDIR/ecr-panel.NOHDR1/panel.tsv" ]
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/ecr-panel.ELSE01"; printf '#ecr-panel\t1\t\n' > "$BATS_TEST_TMPDIR/elsewhere/ecr-panel.ELSE01/panel.tsv"
  run "$RES" --clean "$BATS_TEST_TMPDIR/elsewhere/ecr-panel.ELSE01/panel.tsv"
  [ "$status" -eq 2 ]; [ -e "$BATS_TEST_TMPDIR/elsewhere/ecr-panel.ELSE01/panel.tsv" ]
  mkdir "$TMPDIR/ecr-panel.OTHER1"; printf '#ecr-panel\t1\t\n' > "$TMPDIR/ecr-panel.OTHER1/other.tsv"
  run "$RES" --clean "$TMPDIR/ecr-panel.OTHER1/other.tsv"
  [ "$status" -eq 2 ]
}

# ---- criterion 7: hostile gateway values -----------------------------------------------

hostile() { # one JSON string per hostile value (numeric fields)
  jq -n --arg x "$X" '["$(touch \($x))", "`touch \($x)`", ";touch \($x)", "a\nb", "-1", "0", "99999999999999999999", "abc"][]' -c
}
hostile_str() { hostile | head -n 4; } # the ones that break a charset

@test "hostile ecr_timeout_s, ecr_max_tokens and prices: default or refusal, no side effect, raw value never echoed" {
  while IFS= read -r v; do
    for field in ecr_timeout_s ecr_max_tokens; do
      gw_fixture1
      set_field ecr-openai ".model_info.$field" "$v"
      run "$RES" --prompt "$P"
      [ "$status" -eq 0 ] || { echo "$field=$v status=$status"; return 1; }
      [[ "$output" == *"$field invalid; default"* ]]
      [[ "$output" != *touch* ]]
      [ ! -e "$X" ]
    done
    for field in input_cost_per_token output_cost_per_token; do
      gw_fixture1
      set_field ecr-openai ".model_info.$field" "$v"
      run "$RES" --prompt "$P"
      [ "$status" -eq 5 ] || { echo "$field=$v status=$status"; return 1; }
      [[ "$output" == *"REFUSED: cost unknown: ecr-openai $field invalid"* ]]
      [[ "$output" != *touch* ]]
      [ ! -e "$X" ]
    done
  done < <(hostile)
}

@test "hostile provider, served model and unknown ecr- names: dropped, shown as -, or counted; never echoed or run" {
  while IFS= read -r v; do
    gw_fixture1
    set_field ecr-openai .model_info.litellm_provider "$v"
    set_field ecr-google .litellm_params.model "$v"
    gw_models_mod ".data += [{id: (\"ecr-\" + $v)}]"
    run "$RES" --prompt "$P"
    [ "$status" -eq 1 ] || { echo "v=$v status=$status"; return 1; }
    [[ "$output" == *"DROPPED: ecr-openai provider missing"* ]]
    [[ "$output" == *"note: ecr-google served model unknown"* ]]
    [[ "$output" == *"ignored unknown ecr-* slots (count 1)"* ]]
    [[ "$output" != *touch* ]]
    [ ! -e "$X" ]
  done < <(hostile_str)
}

@test "hostile model_name in the info list and ids in the models list never reach a shell" {
  gw_mod ".data += [{model_name: \"\$(touch $X)\"}]"
  gw_models_mod ".data += [{id: \"\$(touch $X)\"}]"
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [ ! -e "$X" ]
}

# ---- criterion 15: --quick ----------------------------------------------------------

@test "--quick with three resolved: the first two in slot order, voices=3, exit 0" {
  run "$RES" --quick --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source=resolved external=2/2 voices=3"* ]]
  f=$(panel_file)
  [ "$(wc -l < "$f")" -eq 3 ]
  [ "$(sed -n 2p "$f" | cut -f1)" = ecr-openai ]
  [ "$(sed -n 3p "$f" | cut -f1)" = ecr-google ]
}

@test "--quick with slot 1 dropped takes slots 2 and 3 with exit 1" {
  gw_models_mod '.data |= map(select(.id != "ecr-openai"))'
  run "$RES" --quick --prompt "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DROPPED: ecr-openai not offered to this key"* ]]
  f=$(panel_file)
  [ "$(sed -n 2p "$f" | cut -f1)" = ecr-google ]
  [ "$(sed -n 3p "$f" | cut -f1)" = ecr-fireworks ]
}

@test "--quick with slot 3 dropped: exit 0 and a note; with two dropped: exit 4" {
  gw_models_mod '.data |= map(select(.id != "ecr-fireworks"))'
  run "$RES" --quick --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: ecr-fireworks not offered to this key (not needed for the quick panel)"* ]]
  [[ "$output" != *"DROPPED:"* ]]
  gw_models_mod '.data |= map(select(.id != "ecr-google"))'
  run "$RES" --quick --prompt "$P"
  [ "$status" -eq 4 ]
}

# ---- criterion 10: key handling ---------------------------------------------------------

@test "each GET sends the key through a mode-600 header file; never argv or output; temp dir removed" {
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$STUB_DIR/hdr.log")" -eq 2 ]
  [ "$(grep -c '^MODE:600 Authorization: Bearer FAKEKEY-ccw193-Zq7$' "$STUB_DIR/hdr.log")" -eq 2 ]
  grep -q -- "-H @$TMPDIR/" "$STUB_DIR/argv.log"
  if grep -q 'FAKEKEY' "$STUB_DIR/argv.log"; then false; fi
  if [[ "$output" == *FAKEKEY* ]]; then false; fi
  if grep -rq FAKEKEY "$(dirname "$(panel_file)")"; then false; fi
  [ "$(ls -A "$TMPDIR" | wc -l)" -eq 1 ]
}

@test "the temp directory is empty after each failure" {
  for setup in "printf 500 > $STUB_DIR/info.code" "echo nope > $STUB_DIR/models.json"; do
    gw_fixture1; rm -f "$STUB_DIR"/*.code
    eval "$setup"
    run "$RES" --prompt "$P"
    [ "$status" -eq 3 ]
    no_leftovers
  done
}

@test "the op path string is identical in the resolver and in the skill template" {
  skill="$BATS_TEST_DIRNAME/../skills/ecr/SKILL.md"
  a=$(grep -o 'op read "op://[^"]*"' "$RES" | sort -u)
  b=$(grep -o 'op read "op://[^"]*"' "$skill" | sort -u)
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

# ---- criteria 17 to 21 and 23: the cost cap -------------------------------------------

@test "17/21 boundary: 45000 bytes passes at 0.932200; 82665 passes at 0.999997; 82666 is refused at 1.000003 with no panel file and no chat call" {
  mkprompt 45000
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cost: worst_usd=0.932200 cap_usd=1.000000 est_prompt_tokens=15000 bytes_per_token=3 voices=3 (Claude voice not counted)"* ]]
  mkprompt 82665
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cost: worst_usd=0.999997 "* ]]
  rm -rf "${TMPDIR:?}"/*
  mkprompt 82666
  run "$RES" --prompt "$P"
  [ "$status" -eq 5 ]
  [[ "$output" == *"REFUSED: worst case cost \$1.000003 is above the cap \$1.000000. No model was called."* ]]
  no_leftovers
  [ "$(calls_count chat)" -eq 0 ]
}

@test "21 the refusal at 100000 bytes prints the figures, the byte limit and the do-not-change line" {
  mkprompt 100000
  run "$RES" --prompt "$P"
  [ "$status" -eq 5 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = 'ecr-panel-resolve: REFUSED: worst case cost $1.031204 is above the cap $1.000000. No model was called.' ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = 'prompt: 100000 bytes, est 33334 tokens (3 bytes per token)' ]
  [ "$(printf '%s\n' "$output" | sed -n 3p)" = 'voice=ecr-openai    worst_usd=0.386668 (prompt 33334 x 2e-06 + output 32000 x 1e-05)' ]
  [ "$(printf '%s\n' "$output" | sed -n 5p)" = 'voice=ecr-fireworks worst_usd=0.257868 (prompt 33334 x 1.4e-06 + output 48000 x 4.4e-06)' ]
  [[ "$output" == *"next: shorten the prompt to at most 82665 bytes (est 27555 tokens) for this panel and run again. The cap is the threshold ecr-run-cost-cap-usd; do not change it for a run."* ]]
}

@test "--quick at 100000 bytes passes at 0.773336" {
  mkprompt 100000
  run "$RES" --quick --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cost: worst_usd=0.773336 "*"voices=2 (Claude voice not counted)"* ]]
}

# limit_roundtrip <args...>: the printed byte limit passes, the limit plus one byte is refused
limit_roundtrip() {
  mkprompt 400000
  run "$RES" "$@" --prompt "$P"
  [ "$status" -eq 5 ]
  limit=$(printf '%s\n' "$output" | sed -n 's/^next: shorten the prompt to at most \([0-9]*\) bytes.*/\1/p')
  [ -n "$limit" ]
  mkprompt "$limit"
  run "$RES" "$@" --prompt "$P"
  [ "$status" -eq 0 ] || { echo "limit=$limit passed? status=$status $output"; return 1; }
  rm -rf "${TMPDIR:?}"/*
  mkprompt "$((limit + 1))"
  run "$RES" "$@" --prompt "$P"
  [ "$status" -eq 5 ]
  LIMIT=$limit
}

@test "21 the byte limit passes and the limit plus one byte is refused: full panel, --quick, another cap" {
  limit_roundtrip; [ "$LIMIT" -eq 82665 ]
  limit_roundtrip --quick; [ "$LIMIT" -eq 270000 ]
  jq '.["ecr-run-cost-cap-usd"] = 1.2' "$BATS_TEST_DIRNAME/../config/thresholds.json" > "$BATS_TEST_TMPDIR/thr.json"
  export ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/thr.json"
  limit_roundtrip; [ "$LIMIT" -gt 82665 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "a total of exactly the cap passes (quick pair: 640000 output + 4 x 90000 input = 1000000)" {
  mkprompt 270000
  run "$RES" --quick --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cost: worst_usd=1.000000 cap_usd=1.000000 est_prompt_tokens=90000 "* ]]
  mkprompt 270001
  run "$RES" --quick --prompt "$P"
  [ "$status" -eq 5 ]
  [[ "$output" == *'$1.000004'* ]]
}

@test "price text: 2e-06, 0.000002 and 2E-6 are one price; 13 decimal places round up; ordinary decimals are exact" {
  mkprompt 45000
  run "$RES" --prompt "$P"; ref=$(printf '%s\n' "$output" | grep '^cost:')
  for lit in 0.000002 2E-6 0.0000020 2.0e-6; do
    gw_fixture1
    set_field ecr-openai .model_info.input_cost_per_token "$lit"
    run "$RES" --prompt "$P"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep '^cost:')" = "$ref" ] || { echo "lit=$lit"; return 1; }
  done
  # output-only: the output part of a price with 14 significant digits rounds up
  gw_fixture1
  set_field ecr-openai .model_info.output_cost_per_token 1.0000000000005e-05
  run "$RES" --out "$OUTF"
  [[ "$output" == *"output-only worst_usd=0.851201"* ]]
  # 4.35e-06 x 48000 is exactly 208800 micro-dollars
  gw_fixture1
  set_field ecr-fireworks .model_info.output_cost_per_token 4.35e-06
  run "$RES" --out "$OUTF"
  [[ "$output" == *"output-only worst_usd=0.848800"* ]]
  # 3.3e-07 x 1000000 tokens is exactly 330000 micro-dollars
  gw_fixture1
  set_field ecr-fireworks .model_info.input_cost_per_token 3.3e-07
  mkprompt 3000000
  run "$RES" --prompt "$P"
  [ "$status" -eq 5 ]
  [[ "$output" == *"voice=ecr-fireworks worst_usd=0.541200 (prompt 1000000 x 3.3e-07 + output 48000 x 4.4e-06)"* ]]
}

@test "19 each price defect refuses the run: exit 5, slot and field named, raw value absent, no panel file" {
  for field in input_cost_per_token output_cost_per_token; do
    for v in null '"2e-06"' 0 -1e-06 true '[2e-06]' '{"a":1}' 1e-13 1 0.5 1.23456789012345678e-06 1e-02; do
      gw_fixture1
      set_field ecr-google ".model_info.$field" "$v"
      run "$RES" --prompt "$P"
      [ "$status" -eq 5 ] || { echo "$field=$v status=$status"; return 1; }
      [[ "$output" == *"REFUSED: cost unknown: ecr-google $field invalid"* ]] || { echo "$field=$v: $output"; return 1; }
      [[ "$output" != *"2e-06\""* ]]
      no_leftovers
    done
    gw_fixture1
    del_field ecr-google ".model_info.$field"
    run "$RES" --prompt "$P"
    [ "$status" -eq 5 ]
    [[ "$output" == *"REFUSED: cost unknown: ecr-google $field absent"* ]]
  done
  [ "$(calls_count chat)" -eq 0 ]
}

@test "the price limits: 1e-12 and 1e-03 are valid, 15 significant digits are valid, 16 are not" {
  for v in 1e-12 1e-03 1.23456789012345e-06; do
    gw_fixture1
    set_field ecr-google .model_info.output_cost_per_token "$v"
    run "$RES" --out "$OUTF"
    # a valid price is never reported as unknown (1e-03 x 32000 is over the cap: a refusal by cost)
    [[ "$output" != *"cost unknown"* ]] || { echo "v=$v: $output"; return 1; }
  done
}

@test "a dropped slot with a bad price does not fail the run" {
  set_field ecr-google .model_info.litellm_provider '"openai"'
  del_field ecr-google .model_info.output_cost_per_token
  run "$RES" --prompt "$P"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DROPPED: ecr-google same provider as ecr-openai"* ]]
  [[ "$output" != *"cost unknown"* ]]
}

@test "entries sharing one model_name with different prices: the higher is used, with a note" {
  gw_mod '.data += [(.data[0] | .model_info.output_cost_per_token = 1.1e-05)]'
  run "$RES" --out "$OUTF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: ecr-openai entries differ on price; the higher is used"* ]]
  [[ "$output" == *"output-only worst_usd=0.883200"* ]]
}

@test "ecr_max_tokens unpublished is priced at the default 32000" {
  del_field ecr-fireworks .model_info.ecr_max_tokens
  run "$RES" --out "$OUTF"
  [ "$status" -eq 0 ]
  # 320000 + 320000 + 32000 x 4.4e-06 = 140800
  [[ "$output" == *"output-only worst_usd=0.780800"* ]]
  [ "$(panel_row "$OUTF" ecr-fireworks | cut -f6)" = 32000 ]
}

@test "18 the max_tokens in the panel file is the published value, never higher" {
  run "$RES" --prompt "$P"
  f=$(panel_file)
  [ "$(panel_row "$f" ecr-openai | cut -f6)" = 32000 ]
  [ "$(panel_row "$f" ecr-fireworks | cut -f6)" = 48000 ]
  gw_fixture2
  run "$RES" --prompt "$P"
  f=$(panel_file)
  [ "$(panel_row "$f" ecr-openai | cut -f6)" = 20000 ]
  [ "$(panel_row "$f" ecr-google | cut -f6)" = 16000 ]
}

@test "20/19 thresholds: read through ALFRED_THRESHOLDS with a note; a lower cap refuses; bytes-per-token changes the estimate" {
  jq '.["ecr-run-cost-cap-usd"] = 0.5' "$BATS_TEST_DIRNAME/../config/thresholds.json" > "$BATS_TEST_TMPDIR/thr.json"
  run env ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/thr.json" "$RES" --prompt "$P"
  [ "$status" -eq 5 ]
  [[ "$output" == *"note: ALFRED_THRESHOLDS is set; cost thresholds are not read from the plugin's config"* ]]
  [[ "$output" == *"above the cap \$0.500000"* ]]
  [[ "$output" == *"no prompt size fits: the output budgets alone cost \$0.851200; ask llm-gateway to lower ecr_max_tokens or the lead to review the cap"* ]]
  [[ "$output" != *"$BATS_TEST_TMPDIR/thr.json"* ]]
  run "$RES" --prompt "$P"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ALFRED_THRESHOLDS"* ]]
  jq '.["ecr-bytes-per-token"] = 2' "$BATS_TEST_DIRNAME/../config/thresholds.json" > "$BATS_TEST_TMPDIR/thr2.json"
  run env ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/thr2.json" "$RES" --prompt "$P"
  [[ "$output" == *"est_prompt_tokens=500 bytes_per_token=2"* ]]
}

@test "F30 a missing or invalid threshold: exit 2, cost threshold not configured, no gateway call" {
  base="$BATS_TEST_DIRNAME/../config/thresholds.json"
  for v in 'del(.["ecr-run-cost-cap-usd"])' '.["ecr-run-cost-cap-usd"] = "1"' '.["ecr-run-cost-cap-usd"] = 0' '.["ecr-run-cost-cap-usd"] = -1' \
           '.["ecr-run-cost-cap-usd"] = 0.0000001' '.["ecr-run-cost-cap-usd"] = true' '.["ecr-run-cost-cap-usd"] = null'; do
    jq "$v" "$base" > "$BATS_TEST_TMPDIR/thr.json"
    run env ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/thr.json" "$RES" --prompt "$P"
    [ "$status" -eq 2 ] || { echo "v=$v status=$status"; return 1; }
    [[ "$output" == *"cost threshold not configured: ecr-run-cost-cap-usd"* ]]
  done
  for v in 'del(.["ecr-bytes-per-token"])' '.["ecr-bytes-per-token"] = 0' '.["ecr-bytes-per-token"] = 5' '.["ecr-bytes-per-token"] = 2.5' \
           '.["ecr-bytes-per-token"] = "3"' '.["ecr-bytes-per-token"] = -3'; do
    jq "$v" "$base" > "$BATS_TEST_TMPDIR/thr.json"
    run env ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/thr.json" "$RES" --prompt "$P"
    [ "$status" -eq 2 ] || { echo "v=$v status=$status"; return 1; }
    [[ "$output" == *"cost threshold not configured: ecr-bytes-per-token"* ]]
  done
  echo '{}' > "$BATS_TEST_TMPDIR/thr.json"
  run env ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/thr.json" "$RES" --prompt "$P"
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_DIR/calls" ]
}

@test "20 the script holds no cost default: the names come from config/thresholds.json" {
  [ "$(jq '.["ecr-run-cost-cap-usd"]' "$BATS_TEST_DIRNAME/../config/thresholds.json")" = 1 ]
  [ "$(jq '.["ecr-bytes-per-token"]' "$BATS_TEST_DIRNAME/../config/thresholds.json")" = 3 ]
  grep -q 'ecr-run-cost-cap-usd' "$RES"
  if grep -nE 'cap_micro=1000000|bpt=3' "$RES"; then false; fi
}

@test "F29 a prompt file that is missing, empty, a directory, a symlink or over 4194304 bytes: exit 2 before any call" {
  : > "$BATS_TEST_TMPDIR/empty"
  mkdir "$BATS_TEST_TMPDIR/adir"
  ln -s "$P" "$BATS_TEST_TMPDIR/link"
  head -c 4194305 /dev/zero | tr '\0' a > "$BATS_TEST_TMPDIR/big"
  for f in "$BATS_TEST_TMPDIR/missing" "$BATS_TEST_TMPDIR/empty" "$BATS_TEST_TMPDIR/adir" "$BATS_TEST_TMPDIR/link" "$BATS_TEST_TMPDIR/big"; do
    run "$RES" --prompt "$f"
    [ "$status" -eq 2 ] || { echo "f=$f status=$status"; return 1; }
    [[ "$output" == *"prompt file invalid"* ]]
  done
  [ ! -e "$STUB_DIR/calls" ]
  head -c 4194304 /dev/zero | tr '\0' a > "$BATS_TEST_TMPDIR/max"
  run "$RES" --prompt "$BATS_TEST_TMPDIR/max"
  [ "$status" -eq 5 ]
}

@test "F31 neither --prompt nor --out in a resolve mode: exit 2; --prompt with --list-offered, --slots or --clean: exit 2" {
  for args in "" "--quick" "--models other-route"; do
    # shellcheck disable=SC2086
    run "$RES" $args
    [ "$status" -eq 2 ] || { echo "args=$args"; return 1; }
    [[ "$output" == *"usage:"* ]]
  done
  for args in "--list-offered" "--slots" "--clean $TMPDIR/ecr-panel.AAAAAA/panel.tsv"; do
    # shellcheck disable=SC2086
    run "$RES" $args --prompt "$P"
    [ "$status" -eq 2 ] || { echo "args=$args"; return 1; }
  done
  [ ! -e "$STUB_DIR/calls" ]
}

@test "--out with no prompt: prompt_bytes=- and an output-only cost line; an output part above the cap or a bad price is refused" {
  run "$RES" --out "$OUTF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cost: prompt not given, output-only worst_usd=0.851200"* ]]
  [[ "$output" == *"panel-file=$OUTF"* ]]
  [[ "$(sed -n 1p "$OUTF")" == *$'\tprompt_bytes=-\tcost_usd=0.851200' ]]
  [ "$(ls -A "$BATS_TEST_TMPDIR/out" | wc -l)" -eq 1 ]
  rm "$OUTF"
  set_field ecr-openai .model_info.ecr_max_tokens 65536
  run "$RES" --out "$OUTF"
  [ "$status" -eq 5 ]
  [ ! -e "$OUTF" ]
  gw_fixture1; del_field ecr-fireworks .model_info.input_cost_per_token
  run "$RES" --out "$OUTF"
  [ "$status" -eq 5 ]
  [[ "$output" == *"cost unknown: ecr-fireworks input_cost_per_token absent"* ]]
}

# ---- 23: --models voices are priced and capped like slots ----------------------------------

@test "23 --models: an expensive id refuses, an id with no info entry refuses, a bad price refuses, no key gives exit 3" {
  set_field other-route .model_info.output_cost_per_token 1e-04
  run "$RES" --models other-route --prompt "$P"
  [ "$status" -eq 5 ]
  [[ "$output" == *"REFUSED: worst case cost"* ]]
  gw_fixture1
  run "$RES" --models not-on-the-gateway --prompt "$P"
  [ "$status" -eq 5 ]
  [[ "$output" == *"REFUSED: cost unknown: not-on-the-gateway no model info entry"* ]]
  del_field other-route .model_info.input_cost_per_token
  run "$RES" --models other-route --prompt "$P"
  [ "$status" -eq 5 ]
  [[ "$output" == *"REFUSED: cost unknown: other-route input_cost_per_token absent"* ]]
  rm -f "$STUB_DIR/calls"
  run env -u LITELLM_API_KEY "$RES" --models other-route --prompt "$P"
  [ "$status" -eq 3 ]
  [ ! -e "$STUB_DIR/calls" ]
}

@test "23 --models counts toward the cap like a slot: four voices at 32000 tokens add up" {
  # three voices at 32000 x 1e-05 and one at 48000 x 4.4e-06 is 1.17, above the cap with an empty prompt
  gw_mod '(.data[] | select(.model_name == "other-route") | .model_info.output_cost_per_token) = 1e-05'
  run "$RES" --models ecr-openai,ecr-google,other-route,ecr-fireworks --out "$OUTF"
  [ "$status" -eq 5 ]
  [[ "$output" == *"no prompt size fits"* ]]
}

@test "26 --models --verify: a missing id prints MISSING, exits 1 and makes no info call; all present continues to the cost step" {
  run "$RES" --models other-route,gone-id --verify --out "$OUTF"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ok: other-route"* ]]
  [[ "$output" == *"MISSING: gone-id"* ]]
  [ "$(calls_count '/v1/model/info')" -eq 0 ]
  [ ! -e "$OUTF" ]
  rm -f "$STUB_DIR/calls"
  run "$RES" --models other-route,ecr-google --verify --out "$OUTF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: ecr-google"* ]]
  [ "$(calls_count '/v1/models$')" -eq 1 ]
  [ "$(calls_count '/v1/model/info')" -eq 1 ]
}
