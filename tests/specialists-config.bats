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
    if [ "$tier" = default ]; then ! grep -q '^model: ' "$AGENTS/$r.md"; else grep -q '^model: ' "$AGENTS/$r.md"; fi
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

@test "the investigator has no Bash, Edit, Write or NotebookEdit (AC 3)" {
  tools=$(fm investigator tools)
  [ "$tools" = "Read, Grep, Glob, WebFetch" ]
  for t in Bash Edit Write NotebookEdit; do
    [[ ", $tools," != *", $t,"* ]]
  done
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
