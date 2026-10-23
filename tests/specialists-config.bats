#!/usr/bin/env bats
# Specialist definitions, the house-style skill and the planted-defect cases
# (ccplugin#128). Structural checks only: the verbatim wording against
# appendix D is checked by the document reviewer in the PR. No network.

load helpers/design-format

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  AGENTS="$ROOT/agents"
  CFG="$ROOT/config/thresholds.json"
  ROLES="analyst readiness-reviewer design-reviewer builder code-reviewer technical-writer document-reviewer acceptance-reviewer incident-reviewer investigator"
  REVIEWERS="readiness design code document acceptance incident"
  PRECEDENT_CASES="code-only doctrine-only missing none-alternatives none-one-option not-covering owner-decision valid"
  PDIR="$ROOT/tests/specialists/design-precedent"
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
  for c in "$PDIR"/*/; do
    if grep -qiE 'seed|plant|expected defect|sound part|deliberate' "$c/case.md"; then
      echo "hint in design-precedent/$(basename "$c")"
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

# --- CCW-157: the design reviewer's precedent step -------------------------

# The approved wording, verbatim (issue 157, "Precedent step wording"; Alfred's
# approval is issues/146#issuecomment-6355574027). Each is one line in the file.
precedent_step() {
  cat <<'WORDING'
4. Precedent. The design note carries one line that begins `Precedent: `: either `Precedent: <link> | "<quoted passage>"` or `Precedent: none declared`. With a link, check that the precedent exists and covers the work: it is an accepted ADR or a baseline doc, and its passage covers the work. [Alfred, answer 3] An accepted ADR is a file under a repo's `docs/adr/` or `docs/decisions/` whose status reads Accepted, read together with its amendment notes; a baseline doc is a file under `docs/baseline/` on the default branch. Code counts only when a baseline doc describes it. A doctrine informs a design and is not a precedent. An owner decision recorded only on an issue is not a precedent. Check the passage at the link where you can read it; where you cannot, check the passage the brief carries and record "passage carried, not read at source". Where you cannot read the link and the brief carries no passage, the precedent is invalid. A note with no `Precedent:` line, or with a precedent that fails these checks, has an invalid precedent. With `Precedent: none declared`, judge whether a real alternative exists: the design lists alternatives, or says why only one option is viable and you decide whether that holds.
WORDING
}

precedent_output_intro() {
  cat <<'WORDING'
**Output.** Pass or fail. Each is at the start of a line and appears once. When you quote a line of the design note, prefix every quoted line with `> `, so that a quoted `Precedent:` line is never mistaken for yours:
WORDING
}

precedent_output_line() {
  cat <<'WORDING'
`Precedent: valid | invalid | none declared — <reason>`. `valid` only when step 4 holds. `none declared` when the note declares none. `invalid` otherwise, including a note with no `Precedent:` line and a link that could not be read with no passage carried. An invalid precedent is a blocker; `none declared` is not a blocker on its own. When the link could not be read, the reason says "passage carried, not read at source".
WORDING
}

alternatives_output_line() {
  cat <<'WORDING'
`Real alternatives: yes | no — <reason>`, only when the precedent is `invalid` or `none declared`. `no` when the design shows no viable alternative, or only alternatives dismissed by a reason that holds: the item goes ahead and its design is recorded in a baseline doc (AP-ADR0035 item 7). `yes` otherwise: the item goes to the owner for architectural review (AP-ADR0035 item 2).
WORDING
}

@test "design-reviewer: Order step 4 is the approved Precedent step, verbatim" {
  f="$AGENTS/design-reviewer.md"
  want=$(precedent_step)
  [ "$(grep -c '^4\. ' "$f")" -eq 1 ] || { echo "not exactly one step 4"; return 1; }
  [ "$(grep -c '^4\. Precedent\.' "$f")" -eq 1 ] || { echo "step 4 is not Precedent."; return 1; }
  [ "$(grep -F -x -c -- "$want" "$f")" -eq 1 ] || { echo "step 4 text differs from the approved wording"; return 1; }
}

@test "design-reviewer: the old steps 4 to 6 are now 5 to 7 and the order has seven steps" {
  f="$AGENTS/design-reviewer.md"
  [ "$(grep -c '^[0-9]\. ' "$f")" -eq 7 ] || { echo "not seven steps"; return 1; }
  [ "$(grep -c '^3\. Read every ADR it relies on or changes; flag each conflict\.$' "$f")" -eq 1 ] || { echo "step 3 changed"; return 1; }
  [ "$(grep -c '^5\. Each dismissed alternative has a reason that holds; name a plausible alternative that is missing\.$' "$f")" -eq 1 ] || { echo "step 5"; return 1; }
  [ "$(grep -c '^6\. Boundaries, interfaces and the success state are explicit enough for a builder to work without asking\.$' "$f")" -eq 1 ] || { echo "step 6"; return 1; }
  [ "$(grep -c '^7\. The expected effect is stated and measurable\.$' "$f")" -eq 1 ] || { echo "step 7"; return 1; }
}

@test "design-reviewer: both Output lines and the quote-prefix sentence are present once, verbatim" {
  f="$AGENTS/design-reviewer.md"
  want=$(precedent_output_line)
  [ "$(grep -F -x -c -- "$want" "$f")" -eq 1 ] || { echo "Precedent output line differs or is not once"; return 1; }
  want=$(alternatives_output_line)
  [ "$(grep -F -x -c -- "$want" "$f")" -eq 1 ] || { echo "Real alternatives output line differs or is not once"; return 1; }
  want=$(precedent_output_intro)
  [ "$(grep -F -x -c -- "$want" "$f")" -eq 1 ] || { echo "Output intro differs or is not once"; return 1; }
}

@test "design-reviewer: no 'authorised by' line" {
  f="$AGENTS/design-reviewer.md"
  n=$(grep -i -c 'authori[sz]ed by' "$f" || true)
  [ "$n" -eq 0 ] || { echo "found an 'authorised by' line"; return 1; }
}

sentence_always_own_lines() {
  cat <<'WORDING'
Always write your own two lines, even when you quote the design's; put the reason, including `passage carried, not read at source`, on the same line.
WORDING
}

sentence_invalid_fails() {
  cat <<'WORDING'
`Precedent: invalid` makes the verdict fail; `none declared` does not fail on its own.
WORDING
}

@test "design-reviewer: the sentence 'Always write your own two lines' follows the two Output lines, verbatim, once" {
  f="$AGENTS/design-reviewer.md"
  want=$(sentence_always_own_lines)
  [ "$(grep -F -x -c -- "$want" "$f")" -eq 1 ] || { echo "sentence differs or is not once"; return 1; }
  n=$(grep -n -F -x -- "$want" "$f" | cut -d: -f1)
  m=$(grep -n -F -x -- "$(alternatives_output_line)" "$f" | cut -d: -f1)
  [ "$n" -gt "$m" ] || { echo "sentence is not after the Real alternatives line"; return 1; }
}

@test "design-reviewer: the sentence 'Precedent: invalid makes the verdict fail' follows the first sentence, verbatim, once" {
  f="$AGENTS/design-reviewer.md"
  want=$(sentence_invalid_fails)
  [ "$(grep -F -x -c -- "$want" "$f")" -eq 1 ] || { echo "sentence differs or is not once"; return 1; }
  n=$(grep -n -F -x -- "$want" "$f" | cut -d: -f1)
  m=$(grep -n -F -x -- "$(sentence_always_own_lines)" "$f" | cut -d: -f1)
  [ "$n" -gt "$m" ] || { echo "sentence is not after the first sentence"; return 1; }
}

# --- CCW-157: the eight design-precedent cases -----------------------------

@test "design-precedent: exactly the eight cases, each with a case.md and an expected.json" {
  [ "$(ls "$PDIR" | tr '\n' ' ')" = "$PRECEDENT_CASES " ] || { echo "case directories differ: $(ls "$PDIR" | tr '\n' ' ')"; return 1; }
  for c in $PRECEDENT_CASES; do
    [ -s "$PDIR/$c/case.md" ] || { echo "no case.md in $c"; return 1; }
    [ -s "$PDIR/$c/expected.json" ] || { echo "no expected.json in $c"; return 1; }
  done
}

@test "design-precedent: each expected.json has the schema, and its fields agree with each other" {
  for c in $PRECEDENT_CASES; do
    e="$PDIR/$c/expected.json"
    run jq -e '(keys == ["alternatives","blocker","precedent","sound","source_note","verdict"])
      and (.precedent | IN("valid","invalid","none declared"))
      and (.alternatives | IN("yes","no",null))
      and (.verdict | IN("pass","fail"))
      and (.source_note | type == "boolean")
      and (.sound | has("where") and has("summary"))
      and ((.alternatives == null) == (.precedent == "valid"))
      and (.source_note == (.precedent == "valid"))
      and ((.blocker == null) == (.verdict == "pass"))
      and ((.verdict == "fail") == (.precedent == "invalid"))
      and (.blocker == null or (.blocker | type == "string" and length > 0))' "$e"
    [ "$status" -eq 0 ] || { echo "schema or consistency fails in $c: $output"; return 1; }
  done
}

@test "design-precedent: each case expects what the table says" {
  want='valid|valid|null|pass
missing|invalid|yes|fail
code-only|invalid|no|fail
not-covering|invalid|yes|fail
owner-decision|invalid|yes|fail
doctrine-only|invalid|yes|fail
none-alternatives|none declared|yes|pass
none-one-option|none declared|no|pass'
  while IFS='|' read -r c prec alt verdict; do
    got=$(jq -r '[.precedent, (.alternatives // "null"), .verdict] | join("|")' "$PDIR/$c/expected.json")
    [ "$got" = "$prec|$alt|$verdict" ] || { echo "$c: expected $prec|$alt|$verdict, file has $got"; return 1; }
  done <<<"$want"
}

@test "design-precedent: every case.md except missing has a Precedent line that passes the helper" {
  for c in $PRECEDENT_CASES; do
    if [ "$c" = missing ]; then continue; fi
    run design_format_ok "$PDIR/$c/case.md"
    [ "$status" -eq 0 ] || { echo "$c: $output"; return 1; }
  done
}

@test "design-precedent: the missing case has no Precedent line and fails the helper" {
  n=$(grep -c '^Precedent: ' "$PDIR/missing/case.md" || true)
  [ "$n" -eq 0 ] || { echo "missing has $n Precedent lines"; return 1; }
  run design_format_ok "$PDIR/missing/case.md"
  [ "$status" -ne 0 ] || { echo "helper accepted the missing case"; return 1; }
  [[ "$output" == *"found 0"* ]] || { echo "message does not name the count: $output"; return 1; }
}

@test "the existing design case has a Precedent: none declared line at the start of its design note" {
  f="$ROOT/tests/specialists/design/case.md"
  run design_format_ok "$f"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # The line follows the design note heading directly (one blank line between).
  got=$(awk '/^## Design note/ {h=NR} h && NR == h + 2 {print; exit}' "$f")
  [ "$got" = "Precedent: none declared" ] || { echo "line after the design note heading is: $got"; return 1; }
}

@test "design-precedent: a case with a link carries the passage under its own heading; the others do not" {
  for c in $PRECEDENT_CASES; do
    f="$PDIR/$c/case.md"
    has=$(grep -c '^## Precedent passage carried in the brief$' "$f" || true)
    link=$(grep -c '^Precedent: https://' "$f" || true)
    [ "$has" -eq "$link" ] || { echo "$c: passage sections $has, link lines $link"; return 1; }
  done
}

@test "design_format_ok: a quoted Precedent line (starting with > ) is not counted" {
  f="$BATS_TEST_TMPDIR/quoted.md"
  printf '%s\n' '> Precedent: https://x/y | "q"' 'Precedent: none declared' > "$f"
  run design_format_ok "$f"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# design_format_ok on hand-written texts: one test per rule.
fmt() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/note.md"; design_format_ok "$BATS_TEST_TMPDIR/note.md"; }

@test "design_format_ok: accepts a link line, with and without checked lines" {
  run fmt 'Precedent: https://h/p | "a passage"'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run fmt 'Precedent: none declared' 'checked: a | b | c'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "design_format_ok: two Precedent lines fail and the message gives the count" {
  run fmt 'Precedent: none declared' 'Precedent: none declared'
  [ "$status" -ne 0 ] || { echo "accepted two lines"; return 1; }
  [[ "$output" == *"found 2"* ]] || { echo "$output"; return 1; }
}

@test "design_format_ok: a malformed Precedent line fails and the message names the line" {
  run fmt 'text' 'Precedent: https://h/p without a quoted passage'
  [ "$status" -ne 0 ] || { echo "accepted a bad line"; return 1; }
  [[ "$output" == *"line 2"* ]] || { echo "$output"; return 1; }
  run fmt 'Precedent: two words | "x"'
  [ "$status" -ne 0 ] || { echo "accepted a link with a space"; return 1; }
  run fmt 'Precedent: https://h/p | ""'
  [ "$status" -ne 0 ] || { echo "accepted an empty passage"; return 1; }
  run fmt 'Precedent: none declared, because'
  [ "$status" -ne 0 ] || { echo "accepted a none declared with a tail"; return 1; }
}

@test "design_format_ok: a malformed checked line fails and the message names the line" {
  run fmt 'Precedent: none declared' 'checked: only | two'
  [ "$status" -ne 0 ] || { echo "accepted a two-part checked line"; return 1; }
  [[ "$output" == *"line 2"* ]] || { echo "$output"; return 1; }
}

# --- CCW-157: run.sh design-precedent and run.sh check design-precedent ----

# A recording stub claude: it logs its arguments and the listing of its working
# directory (one line per call), then answers like make_stub.
make_recording_stub() {
  STUB="$BATS_TEST_TMPDIR/claude-rec-stub"
  STUB_ARGS="$BATS_TEST_TMPDIR/stub-args.log"
  STUB_LS="$BATS_TEST_TMPDIR/stub-ls.log"
  export STUB_ARGS STUB_LS
  cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$*" >> "$STUB_ARGS"
ls -A | tr '\n' ' ' >> "$STUB_LS"
echo >> "$STUB_LS"
echo '{"result":"found things","is_error":false,"session_id":"s1","num_turns":1,"usage":{}}'
STUBEOF
  chmod +x "$STUB"
}

@test "run.sh design-precedent: a good run with --runs 1 writes sixteen result files and exits 0" {
  make_stub
  R="$BATS_TEST_TMPDIR/results"
  run env CLAUDE_BIN="$STUB" STUB_MODE=ok SPECIALISTS_RESULTS="$R" "$ROOT/tests/specialists/run.sh" design-precedent --runs 1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for c in $PRECEDENT_CASES; do
    [ "$(cat "$R/design-precedent-$c-run1.md")" = "found things" ] || { echo "no .md for $c"; return 1; }
    [ "$(jq -r .session_id "$R/design-precedent-$c-run1.json")" = s1 ] || { echo "no .json for $c"; return 1; }
  done
  [ "$(ls "$R" | wc -l)" -eq 16 ] || { echo "not sixteen files: $(ls "$R")"; return 1; }
}

@test "run.sh design-precedent: error, empty and fail print FAILED for all eight cases, leave no result file and exit non-zero" {
  make_stub
  R="$BATS_TEST_TMPDIR/results"
  for mode in error empty fail; do
    mkdir -p "$R"
    echo stale > "$R/design-precedent-valid-run1.md"
    echo stale > "$R/design-precedent-valid-run1.json"
    run env CLAUDE_BIN="$STUB" STUB_MODE=$mode SPECIALISTS_RESULTS="$R" "$ROOT/tests/specialists/run.sh" design-precedent --runs 1
    [ "$status" -ne 0 ] || { echo "$mode: exit 0"; return 1; }
    for c in $PRECEDENT_CASES; do
      [[ "$output" == *"FAILED design-precedent/$c run 1"* ]] || { echo "$mode: no FAILED line for $c"; return 1; }
    done
    [ "$(ls "$R" | wc -l)" -eq 0 ] || { echo "$mode: result files left: $(ls "$R")"; return 1; }
  done
}

@test "run.sh all: with every run failing, FAILED lines for the six reviewers and the eight cases, exit non-zero" {
  make_stub
  run env CLAUDE_BIN="$STUB" STUB_MODE=error SPECIALISTS_RESULTS="$BATS_TEST_TMPDIR/results" "$ROOT/tests/specialists/run.sh" all --runs 1
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  for r in $REVIEWERS; do
    [[ "$output" == *"FAILED $r run 1"* ]] || { echo "no FAILED line for $r"; return 1; }
  done
  for c in $PRECEDENT_CASES; do
    [[ "$output" == *"FAILED design-precedent/$c run 1"* ]] || { echo "no FAILED line for $c"; return 1; }
  done
}

@test "run.sh design-precedent: the agent is alfred-agent:design-reviewer and the run directory holds only case.md" {
  make_recording_stub
  run env CLAUDE_BIN="$STUB" SPECIALISTS_RESULTS="$BATS_TEST_TMPDIR/results" "$ROOT/tests/specialists/run.sh" design-precedent --runs 1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$STUB_ARGS")" -eq 8 ] || { echo "not eight calls"; return 1; }
  [ "$(grep -c -F -e '--agent alfred-agent:design-reviewer' "$STUB_ARGS")" -eq 8 ] || { echo "agent argument differs: $(cat "$STUB_ARGS")"; return 1; }
  [ "$(sort -u "$STUB_LS")" = "case.md " ] || { echo "listing differs: $(sort -u "$STUB_LS")"; return 1; }
}

@test "run.sh design-precedent: the default is two runs per case" {
  make_recording_stub
  run env CLAUDE_BIN="$STUB" SPECIALISTS_RESULTS="$BATS_TEST_TMPDIR/results" "$ROOT/tests/specialists/run.sh" design-precedent
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$STUB_ARGS")" -eq 16 ] || { echo "not sixteen calls"; return 1; }
}

# make_results <dir>: one hand-written result per case that matches its
# expected.json, with a quoted design line above the reviewer's own lines.
make_results() {
  local dir=$1 c p a s
  mkdir -p "$dir"
  for c in $PRECEDENT_CASES; do
    p=$(jq -r .precedent "$PDIR/$c/expected.json")
    a=$(jq -r '.alternatives // empty' "$PDIR/$c/expected.json")
    s=$(jq -r .source_note "$PDIR/$c/expected.json")
    {
      echo "Verdict: fine."
      if [ "$s" = true ]; then
        echo "Precedent: $p — the ADR is accepted; passage carried, not read at source."
      else
        echo "Precedent: $p — reason."
      fi
      if [ -n "$a" ]; then echo "Real alternatives: $a — reason."; fi
    } > "$dir/design-precedent-$c-run1.md"
  done
}

check_env() { env SPECIALISTS_RESULTS="$BATS_TEST_TMPDIR/res" "$ROOT/tests/specialists/run.sh" check design-precedent "$@"; }

@test "check design-precedent: a matching set exits 0 and prints eight MATCH lines" {
  make_results "$BATS_TEST_TMPDIR/res"
  run check_env
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c '^MATCH design-precedent/' <<<"$output")" -eq 8 ] || { echo "$output"; return 1; }
  [ "$(grep -c MISMATCH <<<"$output" || true)" -eq 0 ] || { echo "$output"; return 1; }
}

@test "check design-precedent: a wrong Precedent value is a MISMATCH naming the case" {
  make_results "$BATS_TEST_TMPDIR/res"
  sed -i 's/^Precedent: valid/Precedent: invalid/' "$BATS_TEST_TMPDIR/res/design-precedent-valid-run1.md"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/valid run 1"* ]] || { echo "$output"; return 1; }
  [ "$(grep -c '^MATCH ' <<<"$output")" -eq 7 ] || { echo "the other seven should match: $output"; return 1; }
}

@test "check design-precedent: a missing Precedent line is a MISMATCH" {
  make_results "$BATS_TEST_TMPDIR/res"
  sed -i '/^Precedent: /d' "$BATS_TEST_TMPDIR/res/design-precedent-code-only-run1.md"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/code-only run 1"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: identical repeated Precedent lines count as one" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-none-alternatives-run1.md"
  grep '^Precedent: ' "$f" > "$f.dup"
  cat "$f.dup" >> "$f"
  run check_env
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"MATCH design-precedent/none-alternatives run 1"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: two different Precedent values fail closed as invalid" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-valid-run1.md"
  echo 'Precedent: invalid — the link could not be read.' >> "$f"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/valid run 1: expected: Precedent=valid; got: Precedent=invalid"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"conflicting Precedent lines"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: a conflict with none declared also reads as invalid" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-none-alternatives-run1.md"
  echo 'Precedent: valid — the link is an accepted ADR.' >> "$f"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/none-alternatives run 1: expected: Precedent=none declared;Real alternatives=yes; got: Precedent=invalid;Real alternatives=yes;"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: a conflicting pair is invalid, so an invalid case still matches" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-code-only-run1.md"
  echo 'Precedent: valid — looks fine.' >> "$f"
  run check_env
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"MATCH design-precedent/code-only run 1"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: a result whose only Precedent line is quoted is a MISMATCH (no Precedent line)" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-missing-run1.md"
  sed -i 's/^Precedent: /> Precedent: /' "$f"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/missing run 1: no Precedent line"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: a quoted Precedent line besides the reviewer's own correct one still matches" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-owner-decision-run1.md"
  { echo '> Precedent: https://h/p | "the note says"'; cat "$f"; } > "$f.new"
  mv "$f.new" "$f"
  run check_env
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"MATCH design-precedent/owner-decision run 1"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: every Real alternatives line is ignored when the precedent is valid" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-valid-run1.md"
  printf '%s\n' 'Real alternatives: no — reason.' 'Real alternatives: not applicable, the precedent is valid.' >> "$f"
  run check_env
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"MATCH design-precedent/valid run 1"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: the first Real alternatives line with a value wins" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-code-only-run1.md"
  echo 'Real alternatives: yes — a later line.' >> "$f"
  run check_env
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"MATCH design-precedent/code-only run 1"* ]] || { echo "$output"; return 1; }
  g="$BATS_TEST_TMPDIR/res/design-precedent-code-only-run1.md"
  { echo 'Real alternatives: yes — first.'; cat "$g"; } > "$g.new"
  mv "$g.new" "$g"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0 with a first line of yes"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/code-only run 1"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: a value must be a whole word (not applicable is no value)" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-code-only-run1.md"
  sed -i 's/^Real alternatives: .*/Real alternatives: not applicable./' "$f"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/code-only run 1"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: a missing Real alternatives line is a MISMATCH" {
  make_results "$BATS_TEST_TMPDIR/res"
  sed -i '/^Real alternatives: /d' "$BATS_TEST_TMPDIR/res/design-precedent-doctrine-only-run1.md"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/doctrine-only run 1"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: a valid result without the phrase is a MISMATCH" {
  make_results "$BATS_TEST_TMPDIR/res"
  printf '%s\n' 'Precedent: valid — the ADR is accepted and covers the work.' > "$BATS_TEST_TMPDIR/res/design-precedent-valid-run1.md"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/valid run 1: the Precedent line lacks"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: the phrase is read on the Precedent line only" {
  make_results "$BATS_TEST_TMPDIR/res"
  printf '%s\n' 'Precedent: valid — the ADR is accepted.' 'Elsewhere: passage carried, not read at source' > "$BATS_TEST_TMPDIR/res/design-precedent-valid-run1.md"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/valid run 1"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: a case with no result file is a MISMATCH" {
  make_results "$BATS_TEST_TMPDIR/res"
  rm "$BATS_TEST_TMPDIR/res/design-precedent-none-one-option-run1.md"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/none-one-option: no result file"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent --runs 2: a run that has no file is a MISMATCH" {
  make_results "$BATS_TEST_TMPDIR/res"
  run check_env --runs 2
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/valid run 2: no result file"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: does not call claude" {
  make_results "$BATS_TEST_TMPDIR/res"
  run env CLAUDE_BIN=/nonexistent SPECIALISTS_RESULTS="$BATS_TEST_TMPDIR/res" "$ROOT/tests/specialists/run.sh" check design-precedent
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# --- CCW-157: check reads presentation variants, never loosens the content --

# variant_test <name> <sed expression applied to the reviewer's own lines>
check_variant() {
  make_results "$BATS_TEST_TMPDIR/res"
  sed -i -E "$1" "$BATS_TEST_TMPDIR/res/design-precedent-$2-run1.md"
  run check_env
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"MATCH design-precedent/$2 run 1"* ]] || { echo "$output"; return 1; }
  [ "$(grep -c '^MATCH ' <<<"$output")" -eq 8 ] || { echo "$output"; return 1; }
}

@test "check design-precedent: bold Precedent and Real alternatives lines match" {
  check_variant 's/^(Precedent: [a-z ]+)( —.*)$/**\1**\2/; s/^(Real alternatives:) ([a-z]+)/**\1** \2/' missing
}

@test "check design-precedent: indented lines match" {
  check_variant 's/^(Precedent|Real alternatives): /    \1: /' doctrine-only
}

@test "check design-precedent: listed lines match (dash, star and number)" {
  check_variant 's/^Precedent: /- Precedent: /; s/^Real alternatives: /2. Real alternatives: /' owner-decision
  check_variant 's/^Precedent: /* Precedent: /' not-covering
}

@test "check design-precedent: bold inside a list, indented, matches" {
  check_variant 's/^(Precedent: [a-z ]+)( —.*)$/  - **\1**\2/; s/^(Real alternatives:) ([a-z]+)/  - **\1** \2/' doctrine-only
}

@test "check design-precedent: underscore emphasis matches" {
  check_variant 's/^(Precedent: [a-z ]+)( —.*)$/__\1__\2/' code-only
}

@test "check design-precedent: a quoted bold line is still ignored (no Precedent line besides the quote)" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-missing-run1.md"
  sed -i 's/^Precedent: .*/> **Precedent: invalid** - quoted/' "$f"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/missing run 1: no Precedent line"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: an indented quoted line is still ignored" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-missing-run1.md"
  sed -i 's/^Precedent: .*/   > Precedent: invalid - quoted/' "$f"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/missing run 1: no Precedent line"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: presentation tolerance does not loosen the value" {
  make_results "$BATS_TEST_TMPDIR/res"
  sed -i -E 's/^Precedent: valid/- **Precedent: invalid**/' "$BATS_TEST_TMPDIR/res/design-precedent-valid-run1.md"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/valid run 1"* ]] || { echo "$output"; return 1; }
}

@test "check design-precedent: a line wrapped in backticks, whole or at the leading token, matches" {
  check_variant 's/^(Precedent: .*)$/`\1`/; s/^(Real alternatives: .*)$/`\1`/' doctrine-only
  check_variant 's/^(Precedent: [a-z ]+)( —.*)$/`\1`\2/' code-only
}

@test "check design-precedent: a backtick-wrapped quoted line is still ignored" {
  make_results "$BATS_TEST_TMPDIR/res"
  f="$BATS_TEST_TMPDIR/res/design-precedent-missing-run1.md"
  sed -i 's/^Precedent: .*/> `Precedent: invalid — quoted`/' "$f"
  run check_env
  [ "$status" -ne 0 ] || { echo "exit 0"; return 1; }
  [[ "$output" == *"MISMATCH design-precedent/missing run 1: no Precedent line"* ]] || { echo "$output"; return 1; }
}
