#!/usr/bin/env bats
# Specialist definitions, the house-style skill and the planted-defect cases
# (ccplugin#128). Structural checks only: the verbatim wording against
# appendix D is checked by the document reviewer in the PR. No network.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  AGENTS="$ROOT/agents"
  CFG="$ROOT/config/thresholds.json"
  ROLES="analyst readiness-reviewer design-reviewer builder code-reviewer technical-writer document-reviewer acceptance-reviewer incident-reviewer investigator"
  REVIEWERS="readiness design code document acceptance incident"
}

# fm <role> <key> — a frontmatter value ("" when the line is absent).
fm() { awk -v k="$2" '/^---$/ {n++; next} n == 1 && index($0, k ": ") == 1 {sub(k ": ", ""); print; exit}' "$AGENTS/$1.md"; }

# config_role <role> — the key in model-setting-per-role for a definition.
config_role() {
  case "$1" in
    analyst) echo analyst ;;
    builder) echo builder ;;
    technical-writer) echo technical-writer ;;
    incident-reviewer) echo incident-reviewer ;;
    investigator) echo investigator ;;
    *-reviewer) echo reviewer ;;
  esac
}

tier_to_model() {
  case "$1" in
    light) echo haiku ;;
    medium) echo sonnet ;;
    strong) echo opus ;;
    default) echo "" ;;
  esac
}

effort_to_field() {
  case "$1" in
    low | medium | high) echo "$1" ;;
    highest) echo max ;;
    default) echo "" ;;
  esac
}

@test "there are exactly the ten definitions" {
  [ "$(ls "$AGENTS" | wc -l)" -eq 10 ]
  for r in $ROLES; do [ -f "$AGENTS/$r.md" ]; done
}

@test "every definition has name, description and tools in its frontmatter" {
  for r in $ROLES; do
    [ "$(fm "$r" name)" = "$r" ]
    [ -n "$(fm "$r" description)" ]
    [ -n "$(fm "$r" tools)" ]
  done
}

@test "model and effort match model-setting-per-role through the tier and effort maps" {
  for r in $ROLES; do
    key=$(config_role "$r")
    tier=$(jq -r --arg k "$key" '."model-setting-per-role"[$k].tier' "$CFG")
    effort=$(jq -r --arg k "$key" '."model-setting-per-role"[$k].effort' "$CFG")
    [ "$(fm "$r" model)" = "$(tier_to_model "$tier")" ]
    [ "$(fm "$r" effort)" = "$(effort_to_field "$effort")" ]
  done
}

@test "model and effort lines are omitted exactly when the config says default" {
  for r in $ROLES; do
    key=$(config_role "$r")
    tier=$(jq -r --arg k "$key" '."model-setting-per-role"[$k].tier' "$CFG")
    if [ "$tier" = default ]; then
      if grep -q '^model: ' "$AGENTS/$r.md"; then echo "model line in $r"; return 1; fi
    else
      grep -q '^model: ' "$AGENTS/$r.md"
    fi
  done
}

@test "every body has the Job, Order, Never and Output headings" {
  for r in $ROLES; do
    f="$AGENTS/$r.md"
    grep -q '^\*\*Job\.\*\*' "$f"
    grep -q '^\*\*Order\.\*\*' "$f"
    grep -q '^\*\*Never\.\*\*' "$f"
    grep -qE '^\*\*Output( adds)?\.\*\*' "$f"
    grep -q '^\*\*Pairs with\.\*\*' "$f"
  done
}

@test "the investigator has no Bash or write tool, and only read-only Metis tools (AC 3)" {
  tools=$(fm investigator tools)
  allowed="mcp__metis__query mcp__metis__search_notes mcp__metis__read_note mcp__metis__get_dependants mcp__metis__get_provenance mcp__metis__get_vault_profile mcp__metis__list_zone"
  for t in Bash Edit Write NotebookEdit; do
    [[ ", $tools," != *", $t,"* ]]
  done
  for w in capture_note lease_staged release_lease quarantine_staged release_quarantine withhold_staged purge_quarantine list_inbox list_staged list_quarantine read_quarantine; do
    if [[ "$tools" == *"$w"* ]]; then echo "writer or queue tool $w"; return 1; fi
  done
  IFS=',' read -ra entries <<<"$tools"
  for e in "${entries[@]}"; do
    e=${e# }
    case "$e" in
      Read | Grep | Glob | WebFetch) ;;
      mcp__*) [[ " $allowed " == *" $e "* ]] || { echo "mcp tool not allowed: $e"; return 1; } ;;
      *) echo "unexpected tool: $e"; return 1 ;;
    esac
  done
  for m in $allowed; do [[ "$tools" == *"$m"* ]]; done
}

@test "the investigator body says what to do without Metis" {
  grep -q 'Metis unavailable' "$AGENTS/investigator.md"
}

@test "the investigator body does not claim to be read-only by instruction (its limit is the tool list)" {
  ! grep -q 'Read-only by instruction' "$AGENTS/investigator.md"
}

@test "reviewers, analyst and incident reviewer have Bash and carry the read-only-by-instruction sentence" {
  for r in analyst readiness-reviewer design-reviewer code-reviewer document-reviewer acceptance-reviewer incident-reviewer; do
    [[ ", $(fm "$r" tools)," == *", Bash,"* ]]
    grep -q 'Read-only by instruction' "$AGENTS/$r.md"
    [[ ", $(fm "$r" tools)," != *", Write,"* ]]
    [[ ", $(fm "$r" tools)," != *", Edit,"* ]]
  done
}

@test "builder and technical writer may write" {
  for r in builder technical-writer; do
    [[ ", $(fm "$r" tools)," == *", Edit,"* ]]
    [[ ", $(fm "$r" tools)," == *", Write,"* ]]
  done
}

@test "the house-style skill has frontmatter and its eight rules" {
  f="$ROOT/skills/house-style/SKILL.md"
  [ "$(sed -n 's/^name: //p' "$f" | head -1)" = house-style ]
  grep -q '^description:' "$f"
  [ "$(grep -c '^- \*\*' "$f")" -eq 8 ]
}

@test "each reviewer case has a case.md and a well-formed expected.json" {
  for r in $REVIEWERS; do
    [ -s "$ROOT/tests/specialists/$r/case.md" ]
    e="$ROOT/tests/specialists/$r/expected.json"
    jq -e '(.defects | length >= 3 and length <= 4)
      and all(.defects[]; has("id") and has("summary") and has("where"))
      and (.sound | has("where") and has("summary"))' "$e"
  done
}

@test "a case does not hint at its defects" {
  for r in $REVIEWERS; do
    if grep -qiE 'seed|plant|expected defect|sound part|deliberate' "$ROOT/tests/specialists/$r/case.md"; then
      echo "hint in $r"
      return 1
    fi
  done
}

@test "run.sh builds deny rules in the // absolute form" {
  run "$ROOT/tests/specialists/run.sh" deny-rules
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read(//"*"/**)"* ]]
  [[ "$output" == *"Grep(//"*"/**)"* ]]
  [[ "$output" == *"Glob(//"*"/**)"* ]]
  [[ "$output" == *$'\nBash'* || "$output" == Bash* ]]
  [[ "$output" == *WebFetch* ]]
  # No rule uses a single slash after the tool name.
  ! grep -E '^(Read|Grep|Glob)\(/[^/]' <<<"$output"
}

# A stub claude: STUB_MODE=ok|error|fail|empty.
make_stub() {
  STUB="$BATS_TEST_TMPDIR/claude-stub"
  cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
case "$STUB_MODE" in
  ok) echo '{"result":"found things","is_error":false,"session_id":"s1","num_turns":1,"usage":{}}' ;;
  error) echo '{"result":"API Error","is_error":true,"session_id":"s1"}' ;;
  empty) echo '{"result":"","is_error":false,"session_id":"s1"}' ;;
  fail) exit 124 ;;
esac
STUBEOF
  chmod +x "$STUB"
}

@test "run.sh: a run that fails, errors or returns nothing is reported FAILED and leaves no result files" {
  make_stub
  R="$BATS_TEST_TMPDIR/results"
  for mode in error empty fail; do
    mkdir -p "$R"
    echo stale > "$R/readiness-reviewer-run1.md"
    echo stale > "$R/readiness-reviewer-run1.json"
    run env CLAUDE_BIN="$STUB" STUB_MODE=$mode SPECIALISTS_RESULTS="$R" "$ROOT/tests/specialists/run.sh" readiness --runs 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAILED readiness run 1"* ]]
    [ ! -e "$R/readiness-reviewer-run1.md" ]
    [ ! -e "$R/readiness-reviewer-run1.json" ]
  done
}

@test "run.sh: a good run writes the result files and exits 0" {
  make_stub
  R="$BATS_TEST_TMPDIR/results"
  run env CLAUDE_BIN="$STUB" STUB_MODE=ok SPECIALISTS_RESULTS="$R" "$ROOT/tests/specialists/run.sh" readiness --runs 1
  [ "$status" -eq 0 ]
  [ "$(cat "$R/readiness-reviewer-run1.md")" = "found things" ]
  [ "$(jq -r .session_id "$R/readiness-reviewer-run1.json")" = s1 ]
}

@test "run.sh: all keeps going after a failure and exits non-zero at the end" {
  make_stub
  run env CLAUDE_BIN="$STUB" STUB_MODE=error SPECIALISTS_RESULTS="$BATS_TEST_TMPDIR/results" "$ROOT/tests/specialists/run.sh" all --runs 1
  [ "$status" -ne 0 ]
  for r in readiness design code document acceptance incident; do [[ "$output" == *"FAILED $r run 1"* ]]; done
}

@test "run.sh builds the plugin copy from git archive without tests/" {
  grep -q 'git -C "\$REPO" archive HEAD' "$ROOT/tests/specialists/run.sh"
  grep -q 'rm -rf "\$dir/tests"' "$ROOT/tests/specialists/run.sh"
  grep -q 'ALFRED_ROLE=worker' "$ROOT/tests/specialists/run.sh"
}
