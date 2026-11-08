#!/usr/bin/env bats
# ECR skill (CCW-189, CCW-191, CCW-194, CCW-196, CCW-193): the output branch that
# makes a length-truncated, contentless reply visible as TRUNCATED; the key
# staying off curl's command line; and (CCW-193) the per-voice template reading
# its model and settings from the panel file, one call per voice per run, the
# served-model line, and a skill text that holds no model id.

load helpers/ecr-gateway

setup() {
  gw_setup
  SKILL="$BATS_TEST_DIRNAME/../skills/ecr/SKILL.md"
  # the final if/elif/else block of the template fence
  awk '/^if   \[ \$CURL_EXIT -eq 28 \]/{on=1} on{print} on&&/^fi$/{exit}' "$SKILL" > "$BATS_TEST_TMPDIR/block.sh"
}

run_block() { # json -> stdout of the template's output block
  RESULT="$1" CURL_EXIT=0 TIMEOUT=180 bash "$BATS_TEST_TMPDIR/block.sh"
}

@test "the extracted output block is non-empty and ends in fi" {
  [ "$(wc -l < "$BATS_TEST_TMPDIR/block.sh")" -ge 4 ]
  [ "$(tail -n1 "$BATS_TEST_TMPDIR/block.sh")" = fi ]
}

@test "the extracted output block is exactly the CCW-189 block, character for character" {
  expected=$(cat <<'BLOCK'
if   [ $CURL_EXIT -eq 28 ]; then echo "TIMEOUT (>${TIMEOUT}s)"
elif [ -z "$RESULT" ];       then echo "ERROR (empty response)"
elif echo "$RESULT" | jq -e '.choices[0].finish_reason == "length" and ((.choices[0].message.content // "") == "")' >/dev/null 2>&1; then echo "TRUNCATED (reasoning used the whole budget)"
else echo "$RESULT" | jq -r '.choices[0].message.content // "ERROR (unexpected response)"'
fi
BLOCK
)
  [ "$(cat "$BATS_TEST_TMPDIR/block.sh")" = "$expected" ]
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

# ---- the skill text holds no model id (criteria 2, 8, 9, 16, 20, 25) ----------

DENY="gpt-6-astra gemini-4-argon glm-5.3 kimi-k3 deepseek-v4.1-flash gpt-6.1-sol gpt-5.4 gpt-5.5 gemini-3.1 gemini-3-flash gemini-2 claude-opus-4-8 glm-5.1 kimi-k2 deepseek-v4-pro Opus"

@test "2 no model id of the retired or the current panel in the skill, the resolver or the check" {
  for f in "$SKILL" "$BATS_TEST_DIRNAME/../bin/ecr-panel-resolve" "$BATS_TEST_DIRNAME/../bin/ecr-models-check"; do
    for id in $DENY; do
      if grep -qF -- "$id" "$f"; then echo "$id in $f"; return 1; fi
    done
    if grep -qiw -- 'o3' "$f"; then echo "o3 in $f"; return 1; fi
  done
}

@test "2 no stale model name in skills, bin, commands, agents, README" {
  cd "$BATS_TEST_DIRNAME/.."
  run grep -rnE 'gpt-5\.4|gemini-3\.1|claude-opus-4-8|Opus 4\.8|\bo3\b' skills bin commands agents README.md
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "2 the skill has no timeout, max_tokens or provider table of models" {
  if grep -qE '^\| `[a-z0-9.-]+` \|' "$SKILL"; then false; fi
  if grep -q 'Available top-tier models' "$SKILL"; then false; fi
  if grep -q 'Alternative External Models' "$SKILL"; then false; fi
  if grep -qE '^(TIMEOUT|MAX_TOKENS)=[0-9]' "$SKILL"; then false; fi
}

@test "9 no claude- string and no digit after Claude, Fable, Opus, Sonnet or Haiku in the skill" {
  if grep -q 'claude-' "$SKILL"; then false; fi
  if grep -qE '(Claude|Fable|Opus|Sonnet|Haiku|claude|fable|opus|sonnet|haiku)[ -]*[0-9]' "$SKILL"; then false; fi
}

@test "9 the Agent example has exactly one model line and it is opus; the runtime table row holds the alias" {
  awk '/^Agent\(/{on=1} on{print} on&&/^\)/{exit}' "$SKILL" > "$BATS_TEST_TMPDIR/agent.txt"
  [ -s "$BATS_TEST_TMPDIR/agent.txt" ]
  [ "$(grep -c 'model:' "$BATS_TEST_TMPDIR/agent.txt")" -eq 1 ]
  grep -qxF '  model: "opus",' "$BATS_TEST_TMPDIR/agent.txt"
  grep -qxF '| Claude Code | the default Claude voice, not the session model | `opus` |' "$SKILL"
}

@test "16 the word highest does not appear and the Step 4 sub-agent row names no model version" {
  if grep -qi highest "$SKILL"; then false; fi
  row=$(grep -F '| Claude sub-agent |' "$SKILL")
  [ -n "$row" ]
  if [[ "$row" =~ [0-9] ]]; then false; fi
}

@test "8 Step 4 has the Model and Source columns and the N/V voices header; TRUNCATED and the partial panel count stay" {
  grep -qF '| Voice | Provider | Model | Source | Verdict | Key insight |' "$SKILL"
  grep -qF '### Verdict (N/V voices):' "$SKILL"
  grep -qF 'V is `voices=` from the resolver' "$SKILL"
  grep -qF '`DROPPED` row' "$SKILL"
  grep -qF '`alias -> served`' "$SKILL"
}

@test "3b each voice call runs with timeout: 600000 or in the background" {
  awk '/^### Step 3/{on=1} /^### Step 4/{on=0} on' "$SKILL" > "$BATS_TEST_TMPDIR/step3.txt"
  grep -qF 'timeout: 600000' "$BATS_TEST_TMPDIR/step3.txt"
  grep -q 'background' "$BATS_TEST_TMPDIR/step3.txt"
}

@test "17 20 25 the skill names the cap threshold, says the Claude voice is not counted, exit 5 stops, and --models re-runs a TRUNCATED voice" {
  grep -qF 'ecr-run-cost-cap-usd' "$SKILL"
  grep -qF 'The Claude sub-agent is not counted' "$SKILL"
  grep -qE '^\| 5 \| the cost check refused the run \| stop' "$SKILL"
  grep -qF 'Never edit the threshold or the panel file to get past it' "$SKILL"
  grep -qF 'run it again as a new run with `ecr-panel-resolve --models <id>' "$SKILL"
  grep -qF 'A TRUNCATED voice is not continued' "$SKILL"
  if grep -qF 'Finish only the conclusion section' "$SKILL"; then false; fi
  if grep -nE '\$[0-9]' "$SKILL"; then false; fi
}

@test "the skill says it never substitutes a remembered panel, and keeps the quota rule in words" {
  grep -qF 'Never substitute a remembered panel' "$SKILL"
  grep -qF 'a substitute must come from a provider that is not already in the panel' "$SKILL"
  grep -qF 'ecr-panel-resolve --list-offered' "$SKILL"
  grep -qF 'ERROR (model alias not accepted: <alias>)' "$SKILL"
}

@test "the resolver and the check ship as executable commands" {
  [ -x "$BATS_TEST_DIRNAME/../bin/ecr-panel-resolve" ]
  [ -x "$BATS_TEST_DIRNAME/../bin/ecr-models-check" ]
}

# ---- CCW-194: the gateway key stays off curl's command line ----------------------

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

# ---- the whole template fence, run against stubs -------------------------------

# mk_panel <name> [prompt_bytes]: a fixture run directory with a panel file
mk_panel() {
  PANEL_DIR="$BATS_TEST_TMPDIR/run/$1"
  mkdir -p "$BATS_TEST_TMPDIR/run"; mkdir -m 700 "$PANEL_DIR"
  PANEL_F="$PANEL_DIR/panel.tsv"
  {
    printf '#ecr-panel\t1\tsource=resolved\texternal_expected=3\texternal_resolved=3\tvoices=4\tprompt_bytes=%s\tcost_usd=0.500000\n' "${2:-100}"
    printf 'ecr-openai\tecr-openai\topenai\talpha-model-1\t180\t32000\tresolved\tpublished\n'
    printf 'ecr-google\tecr-google\tgemini\tgemini/beta\t240\t16000\tresolved\tdefault\n'
    printf 'override-1\tother-route\t-\t-\t400\t30000\toverride\tdefault\n'
  } > "$PANEL_F"
}

# make_template <panel> <slot>: the whole fence with the two per-run edits made
make_template() {
  awk '/^# LITELLM_URL:/{on=1} on&&/^```/{exit} on{print}' "$SKILL" > "$BATS_TEST_TMPDIR/fence.sh"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/fence.sh")" -ge 30 ]
  [ "$(tail -n1 "$BATS_TEST_TMPDIR/fence.sh")" = fi ]
  : > "$BATS_TEST_TMPDIR/template.sh"
  while IFS= read -r line; do
    case "$line" in
      PANEL=*) printf 'PANEL=%q\n' "$1" >> "$BATS_TEST_TMPDIR/template.sh" ;;
      SLOT=*) printf 'SLOT=%q\n' "$2" >> "$BATS_TEST_TMPDIR/template.sh" ;;
      *) printf '%s\n' "$line" >> "$BATS_TEST_TMPDIR/template.sh" ;;
    esac
  done < "$BATS_TEST_TMPDIR/fence.sh"
}

run_template() { # panel slot -> run
  make_template "$1" "$2"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" TMPDIR="$TMPDIR" bash "$BATS_TEST_TMPDIR/template.sh"
}

save_prompt() {
  SAVED=""
  if [ -e /tmp/ecr-prompt.txt ]; then SAVED="$BATS_TEST_TMPDIR/prompt.saved"; cp -p /tmp/ecr-prompt.txt "$SAVED"; fi
  echo "fixture prompt" > /tmp/ecr-prompt.txt
}

teardown() {
  if [ -n "${SAVED+x}" ]; then
    if [ -n "$SAVED" ]; then cp -p "$SAVED" /tmp/ecr-prompt.txt; else rm -f /tmp/ecr-prompt.txt; fi
  fi
}

@test "template: model, max_tokens and the settings come from the panel file; the request body has no reasoning_effort" {
  save_prompt; mk_panel r1
  run_template "$PANEL_F" ecr-openai
  [ "$status" -eq 0 ]
  [[ "$output" == *"voice=ecr-openai model=ecr-openai timeout=180 max_tokens=32000 origin=resolved settings=published"* ]]
  [[ "$output" == *"ok"* ]]
  [ "$(calls_count chat)" -eq 1 ]
  grep -q 'POST http://litellm.invalid/v1/chat/completions model=ecr-openai max_tokens=32000$' "$STUB_DIR/calls"
  if jq -e 'has("reasoning_effort")' "$STUB_DIR/chat.body" >/dev/null; then false; fi
  [ "$(jq -r '.metadata.tags[0]' "$STUB_DIR/chat.body")" = ecr ]
  run_template "$PANEL_F" override-1
  grep -q 'model=other-route max_tokens=30000$' "$STUB_DIR/calls"
}

@test "template: CCW-194 argv proof, the key is absent from argv, the header file is mode 600 under TMPDIR, the temp dir is gone" {
  save_prompt; mk_panel r1
  ln -sf "$BATS_TEST_DIRNAME/stub/curl-argv" "$BATS_TEST_TMPDIR/bin/curl"
  export CURL_ARGV_LOG="$BATS_TEST_TMPDIR/curl-argv.log"
  : > "$CURL_ARGV_LOG"
  run_template "$PANEL_F" ecr-openai
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = ok ]
  [ -s "$CURL_ARGV_LOG" ]
  if grep -q 'FAKEKEY-ccw193-Zq7' "$CURL_ARGV_LOG"; then false; fi
  grep -q ' MODE: 600$' "$CURL_ARGV_LOG"
  grep -q "^HDRFILE: $TMPDIR/" "$CURL_ARGV_LOG"
  grep -q -- "\[-D\] \[$TMPDIR/" "$CURL_ARGV_LOG"
  no_leftovers
}

@test "template: without a credential it exits 1, makes no curl call, leaves no temp dir" {
  save_prompt; mk_panel r1
  make_template "$PANEL_F" ecr-openai
  run env -u LITELLM_API_KEY PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" TMPDIR="$TMPDIR" bash "$BATS_TEST_TMPDIR/template.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: no LiteLLM credential available for the ECR skill."* ]]
  [ ! -e "$STUB_DIR/calls" ]
  no_leftovers
}

@test "template: a panel file that is missing, a symlink, or in a symlinked directory fails closed with no call" {
  save_prompt; mk_panel r1
  run_template "$BATS_TEST_TMPDIR/run/none/panel.tsv" ecr-openai
  [ "$status" -eq 1 ]; [[ "$output" == *"ERROR (panel file invalid:"* ]]
  ln -s "$PANEL_F" "$BATS_TEST_TMPDIR/run/r1/link.tsv"
  run_template "$BATS_TEST_TMPDIR/run/r1/link.tsv" ecr-openai
  [ "$status" -eq 1 ]; [[ "$output" == *"ERROR (panel file invalid:"* ]]
  ln -s "$PANEL_DIR" "$BATS_TEST_TMPDIR/run/dirlink"
  run_template "$BATS_TEST_TMPDIR/run/dirlink/panel.tsv" ecr-openai
  [ "$status" -eq 1 ]; [[ "$output" == *"ERROR (panel file invalid:"* ]]
  [ ! -e "$STUB_DIR/calls" ]
  no_leftovers
}

@test "template: a bad header, a missing or repeated voice line, a short line: fails closed with no call" {
  save_prompt
  n=0
  for edit in "1s/^#ecr-panel\t1/#ecr-panel\t2/" "1s/^#ecr-panel/#other/" '/^ecr-openai/d' '$a ecr-openai\tx\ty\tz\t180\t32000\tresolved\tpublished' \
              's/^ecr-openai\tecr-openai\t/ecr-openai\t/' '1s/\tprompt_bytes=[0-9]*//' '1s/prompt_bytes=[0-9]*/prompt_bytes=x/'; do
    n=$((n + 1)); mk_panel "e$n"
    sed -i "$edit" "$PANEL_F"
    run_template "$PANEL_F" ecr-openai
    [ "$status" -eq 1 ] || { echo "edit=$edit status=$status"; return 1; }
    [[ "$output" == *"ERROR (panel file invalid:"* ]] || { echo "edit=$edit out=$output"; return 1; }
  done
  [ ! -e "$STUB_DIR/calls" ]
}

@test "template: prompt_bytes=- (a panel made without --prompt) is refused as no cost check" {
  save_prompt; mk_panel r1 -
  run_template "$PANEL_F" ecr-openai
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR (panel file invalid: no cost check)"* ]]
  [ ! -e "$STUB_DIR/calls" ]
}

@test "template: a non-integer or out-of-range timeout or max_tokens, and a model with hostile characters, fail closed" {
  save_prompt
  n=0
  for col_val in "5 abc" "5 9" "5 591" "5 1e3" "5 -180" "6 abc" "6 1023" "6 65537" "6 1.5" "6 +9999" "2 a;b" "2 \$(touch\\ $X)" "2 -x" "7 other" "8 other"; do
    n=$((n + 1)); mk_panel "v$n"
    col=${col_val%% *}; val=${col_val#* }
    awk -F'\t' -v OFS='\t' -v c="$col" -v v="$val" '$1 == "ecr-openai" { $(c + 0) = v } { print }' "$PANEL_F" > "$PANEL_F.new"
    # column 5 is timeout_s, 6 is max_tokens, 2 is model (awk fields are 1-based over the voice line)
    mv "$PANEL_F.new" "$PANEL_F"
    run_template "$PANEL_F" ecr-openai
    [ "$status" -eq 1 ] || { echo "col_val=$col_val status=$status out=$output"; return 1; }
    [[ "$output" == *"ERROR (panel file invalid:"* ]] || { echo "col_val=$col_val out=$output"; return 1; }
  done
  [ ! -e "$STUB_DIR/calls" ]
  [ ! -e "$X" ]
}

@test "template: a voice name with a slash, dots or a newline is refused before it is used as a name" {
  save_prompt; mk_panel r1
  for slot in "a/b" ".." "../x" $'a\nb' "" "-"; do
    run_template "$PANEL_F" "$slot"
    [ "$status" -eq 1 ] || { echo "slot=[$slot] status=$status"; return 1; }
    [[ "$output" == *"ERROR (panel file invalid: voice name)"* ]]
  done
  [ ! -e "$STUB_DIR/calls" ]
  [ -z "$(ls -A "$PANEL_DIR")" ] || [ "$(ls -A "$PANEL_DIR")" = panel.tsv ]
}

@test "template: a prompt larger than the cost check covered is refused with no call; an equal one passes" {
  save_prompt; mk_panel r1 20
  run_template "$PANEL_F" ecr-openai
  [ "$status" -eq 0 ]
  mk_panel r2 14
  run_template "$PANEL_F" ecr-openai
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR (prompt is larger than the cost check covered)"* ]]
  [ "$(calls_count chat)" -eq 1 ]
  [ ! -e "$PANEL_DIR/called.ecr-openai" ]
}

@test "24 a second call for the same voice in one run is refused, one chat line; a different voice passes" {
  save_prompt; mk_panel r1
  run_template "$PANEL_F" ecr-openai
  [ "$status" -eq 0 ]
  [ -d "$PANEL_DIR/called.ecr-openai" ]
  run_template "$PANEL_F" ecr-openai
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR (repeat call refused: ecr-openai was already called in this run; a re-run is a new resolver run)"* ]]
  [ "$(calls_count chat)" -eq 1 ]
  run_template "$PANEL_F" ecr-google
  [ "$status" -eq 0 ]
  [ "$(calls_count chat)" -eq 2 ]
}

@test "24 after a first call that times out, a second call for the same voice is refused" {
  save_prompt; mk_panel r1
  printf 28 > "$STUB_DIR/chat.exit"
  run_template "$PANEL_F" ecr-openai
  [[ "$output" == *"TIMEOUT (>180s)"* ]]
  [ -d "$PANEL_DIR/called.ecr-openai" ]
  run_template "$PANEL_F" ecr-openai
  [ "$status" -eq 1 ]
  [[ "$output" == *"repeat call refused"* ]]
  [ "$(calls_count chat)" -eq 1 ]
}

@test "24 two calls for the same voice started together: exactly one chat line" {
  save_prompt; mk_panel r1
  printf 1 > "$STUB_DIR/chat.sleep"
  make_template "$PANEL_F" ecr-openai
  env PATH="$BATS_TEST_TMPDIR/bin:$PATH" TMPDIR="$TMPDIR" bash "$BATS_TEST_TMPDIR/template.sh" > "$BATS_TEST_TMPDIR/o1" 2>&1 &
  p1=$!
  env PATH="$BATS_TEST_TMPDIR/bin:$PATH" TMPDIR="$TMPDIR" bash "$BATS_TEST_TMPDIR/template.sh" > "$BATS_TEST_TMPDIR/o2" 2>&1 &
  p2=$!
  wait "$p1" || true; wait "$p2" || true
  [ "$(calls_count chat)" -eq 1 ]
  cat "$BATS_TEST_TMPDIR/o1" "$BATS_TEST_TMPDIR/o2" | grep -q 'repeat call refused'
}

@test "24 the marker exists at the moment the chat call is made" {
  save_prompt; mk_panel r1
  printf 2 > "$STUB_DIR/chat.sleep"
  make_template "$PANEL_F" ecr-openai
  env PATH="$BATS_TEST_TMPDIR/bin:$PATH" TMPDIR="$TMPDIR" bash "$BATS_TEST_TMPDIR/template.sh" > "$BATS_TEST_TMPDIR/o1" 2>&1 &
  p=$!
  for _ in $(seq 1 40); do [ -s "$STUB_DIR/calls" ] && break; sleep 0.1; done
  kill -0 "$p"
  [ -d "$PANEL_DIR/called.ecr-openai" ]
  wait "$p"
}

@test "24 a pre-existing marker (directory or symlink) refuses the call" {
  save_prompt; mk_panel r1
  mkdir "$PANEL_DIR/called.ecr-openai"
  run_template "$PANEL_F" ecr-openai
  [ "$status" -eq 1 ]; [[ "$output" == *"repeat call refused"* ]]
  ln -s "$BATS_TEST_TMPDIR" "$PANEL_DIR/called.ecr-google"
  run_template "$PANEL_F" ecr-google
  [ "$status" -eq 1 ]; [[ "$output" == *"repeat call refused"* ]]
  [ ! -e "$STUB_DIR/calls" ]
}

@test "24 ecr-panel-resolve --clean removes a run directory with its markers" {
  save_prompt
  run "$RES" --prompt /tmp/ecr-prompt.txt
  [ "$status" -eq 0 ]
  f=$(panel_file)
  run_template "$f" ecr-openai
  [ -d "$(dirname "$f")/called.ecr-openai" ]
  run "$RES" --clean "$f"
  [ "$status" -eq 0 ]
  [ ! -e "$(dirname "$f")" ]
}

@test "18 the max_tokens in each chat request equals the panel file value for each voice" {
  save_prompt; mk_panel r1
  for v in ecr-openai ecr-google override-1; do
    run_template "$PANEL_F" "$v"
    [ "$status" -eq 0 ]
    want=$(awk -F'\t' -v s="$v" '$1 == s { print $6 }' "$PANEL_F")
    grep -q "max_tokens=$want\$" "$STUB_DIR/calls"
  done
  [ "$(calls_count chat)" -eq 3 ]
}

# ---- criteria 4 and 15: the template follows the resolver's panel file --------------------

@test "4 --models x,y: the chat stub records requests whose model is exactly x and y" {
  save_prompt
  run "$RES" --models other-route,ecr-google --prompt /tmp/ecr-prompt.txt
  [ "$status" -eq 0 ]
  f=$(panel_file)
  run_template "$f" override-1
  run_template "$f" override-2
  grep -q ' model=other-route max_tokens=32000$' "$STUB_DIR/calls"
  grep -q ' model=ecr-google max_tokens=32000$' "$STUB_DIR/calls"
  [ "$(calls_count chat)" -eq 2 ]
}

@test "15 --quick: the template run sends requests for exactly the first two slots" {
  save_prompt
  run "$RES" --quick --prompt /tmp/ecr-prompt.txt
  [ "$status" -eq 0 ]
  f=$(panel_file)
  run_template "$f" ecr-openai
  run_template "$f" ecr-google
  run_template "$f" ecr-fireworks
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR (panel file invalid: voice line)"* ]]
  grep -q ' model=ecr-openai ' "$STUB_DIR/calls"
  grep -q ' model=ecr-google ' "$STUB_DIR/calls"
  [ "$(calls_count chat)" -eq 2 ]
}

# ---- criterion 22: the served line ---------------------------------------------------

# headers <file content> : write chat.headers (the stub adds CRLF)
headers() { printf '%b' "$1" > "$STUB_DIR/chat.headers"; }

@test "22 a valid header gives served=<value> source=header, with no space or CR in the value" {
  save_prompt; mk_panel r1
  headers 'HTTP/1.1 200 OK\nContent-Type: application/json\nx-litellm-model-name: gamma-served/v1:x\n\n'
  run_template "$PANEL_F" ecr-openai
  [ "$status" -eq 0 ]
  [[ "$output" == *"served=gamma-served/v1:x source=header"* ]]
  line=$(printf '%s\n' "$output" | grep '^served=')
  [ "$line" = "served=gamma-served/v1:x source=header" ]
}

@test "22 no space after the colon, mixed-case and lowercase names, HTTP/2 and a 100 Continue block all work" {
  save_prompt
  mk_panel h1; headers 'HTTP/1.1 100 Continue\n\nHTTP/1.1 200 OK\nX-LITELLM-MODEL-NAME: after-continue\n\n'
  run_template "$PANEL_F" ecr-openai
  [[ "$output" == *"served=after-continue source=header"* ]]
  mk_panel h2; headers 'HTTP/1.1 200 OK\nx-litellm-model-name:no-space\n\n'
  run_template "$PANEL_F" ecr-openai
  [[ "$output" == *"served=no-space source=header"* ]]
  mk_panel h3; headers 'HTTP/1.1 200 OK\nX-LiteLLM-Model-Name:   mixed  \n\n'
  run_template "$PANEL_F" ecr-openai
  [[ "$output" == *"served=mixed source=header"* ]]
  mk_panel h4; headers 'HTTP/2 200\nx-litellm-model-name: h2-lower\n\n'
  run_template "$PANEL_F" ecr-openai
  [[ "$output" == *"served=h2-lower source=header"* ]]
}

@test "22 header absent: served from the lookup; lookup value - gives served=- source=none" {
  save_prompt; mk_panel r1
  run_template "$PANEL_F" ecr-openai
  [[ "$output" == *"served=alpha-model-1 source=lookup"* ]]
  run_template "$PANEL_F" override-1
  [[ "$output" == *"served=- source=none"* ]]
}

@test "22 curl exit 28: the lookup value, TIMEOUT unchanged" {
  save_prompt; mk_panel r1
  headers 'HTTP/1.1 200 OK\nx-litellm-model-name: should-not-be-used\n\n'
  printf 28 > "$STUB_DIR/chat.exit"
  run_template "$PANEL_F" ecr-openai
  [[ "$output" == *"served=alpha-model-1 source=lookup"* ]]
  [[ "$output" == *"TIMEOUT (>180s)"* ]]
  [[ "$output" != *"should-not-be-used"* ]]
}

@test "22 an invalid header value (inner space, command substitution, 129 characters, embedded CR): lookup, a note, no side effect, raw value absent" {
  save_prompt
  long=$(head -c 129 /dev/zero | tr '\0' a)
  i=0
  for v in 'two words' "\$(touch $X)" "$long" 'a\rb' '`touch X`' 'a;b'; do
    i=$((i + 1)); mk_panel "i$i"
    headers "HTTP/1.1 200 OK\nx-litellm-model-name: $v\n\n"
    run_template "$PANEL_F" ecr-openai
    [ "$status" -eq 0 ] || { echo "v=$v"; return 1; }
    [[ "$output" == *"note: served header invalid"* ]] || { echo "v=$v out=$output"; return 1; }
    [[ "$output" == *"served=alpha-model-1 source=lookup"* ]]
    [[ "$output" != *touch* ]]
    [[ "$output" != *"two words"* ]]
    [[ "$output" != *"$long"* ]]
  done
  [ ! -e "$X" ]
}

@test "22 the -D file lives under TMPDIR and is gone after the run" {
  save_prompt; mk_panel r1
  headers 'HTTP/1.1 200 OK\nx-litellm-model-name: gone-after\n\n'
  run_template "$PANEL_F" ecr-openai
  grep -q -- "-D $TMPDIR/" "$STUB_DIR/argv.log"
  no_leftovers
}
