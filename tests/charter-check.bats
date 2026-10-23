#!/usr/bin/env bats
# templates/CHARTER.md and bin/alfred-charter-check (ccplugin#162, AP-1280).
# Static fixtures under tests/fixtures/charter/; no network, no claude.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  FIX="$ROOT/tests/fixtures/charter"
  TEMPLATE="$ROOT/templates/CHARTER.md"
  CHECK="$ROOT/bin/alfred-charter-check"
  HEADINGS="## Repo owner|## Objective|## Business case|## Merge rule|## Scope"
}

# lines_under <heading> <file> — non-blank lines between the heading and the
# next "## " line or the end of the file.
lines_under() {
  awk -v h="$1" '
    /^## / { on = ($0 == h); next }
    on && $0 !~ /^[[:space:]]*$/ { n++ }
    END { print n + 0 }' "$2"
}

# fails <file> <heading>... — the check exits 1 and names every heading.
fails() {
  local f="$1" h
  shift
  run "$CHECK" "$f"
  [ "$status" -eq 1 ] || { echo "$f: status $status: $output"; return 1; }
  for h in "$@"; do
    [[ "$output" == *"$h"* ]] || { echo "$f: output does not name $h: $output"; return 1; }
  done
}

# passes <file> — the check exits 0.
passes() {
  run "$CHECK" "$1"
  [ "$status" -eq 0 ] || { echo "$1: status $status: $output"; return 1; }
}

# --- criterion 1: the template's shape ---

@test "template: five headings in order, first line is the first heading" {
  [ "$(grep '^## ' "$TEMPLATE" | paste -sd'|')" = "$HEADINGS" ]
  [ "$(head -n1 "$TEMPLATE")" = "## Repo owner" ]
}

@test "template: one line under each of the first four headings, two to four under Scope" {
  [ "$(lines_under "## Repo owner" "$TEMPLATE")" = "1" ]
  [ "$(lines_under "## Objective" "$TEMPLATE")" = "1" ]
  [ "$(lines_under "## Business case" "$TEMPLATE")" = "1" ]
  [ "$(lines_under "## Merge rule" "$TEMPLATE")" = "1" ]
  [ "$(lines_under "## Scope" "$TEMPLATE")" -ge 2 ]
  [ "$(lines_under "## Scope" "$TEMPLATE")" -le 4 ]
}

@test "template: no HTML comment and no digit" {
  [ "$(grep -c '<!--' "$TEMPLATE")" = "0" ]
  [ "$(grep -c '[0-9]' "$TEMPLATE")" = "0" ]
}

# --- criterion 2: the six template lines, verbatim (copied from the work item body by script) ---

@test "template line 1 is present verbatim" {
  grep -Fx -- 'TODO: agent id of the repo owner; for a project repo, its lead' "$TEMPLATE"
}

@test "template line 2 is present verbatim" {
  grep -Fx -- 'TODO: O<n>, <name from the register>' "$TEMPLATE"
}

@test "template line 3 is present verbatim" {
  grep -Fx -- 'TODO: the business case, in one line' "$TEMPLATE"
}

@test "template line 4 is present verbatim" {
  grep -Fx -- 'The lead merges after a passed review.' "$TEMPLATE"
}

@test "template line 5 is present verbatim" {
  grep -Fx -- 'TODO: what belongs in this repo' "$TEMPLATE"
}

@test "template line 6 is present verbatim" {
  grep -Fx -- 'TODO: what does not belong in this repo' "$TEMPLATE"
}

@test "template: six lines that are not headings, five placeholders" {
  [ "$(grep -v '^## ' "$TEMPLATE" | grep -c '[^[:space:]]')" = "6" ]
  [ "$(grep -c '^TODO: ' "$TEMPLATE")" = "5" ]
}

# --- criterion 3: exit codes ---

@test "no argument: status 2 and a usage line" {
  run "$CHECK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]] || { echo "$output"; return 1; }
}

@test "missing path: status 2 and a usage line" {
  run "$CHECK" "$BATS_TEST_TMPDIR/no-such-file.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]] || { echo "$output"; return 1; }
}

# --- criterion 4: fixture inventory ---

@test "fixture directory holds exactly the 18 fixtures" {
  [ "$(ls "$FIX" | LC_ALL=C sort | tr '\n' ' ')" = "angle-brackets-scope.md duplicate-objective.md empty-merge-rule.md empty-scope-blank.md empty-scope.md fenced-heading.md missing-business-case.md missing-merge-rule.md missing-objective.md missing-repo-owner.md missing-scope.md out-of-order.md real-alfred-platform.md trailing-space.md two-lines.md unedited-template.md valid.md wrong-case.md " ]
}

# --- criterion 5: what passes and what fails as a whole ---

@test "valid.md differs from the template; unedited-template.md equals it" {
  run cmp -s "$FIX/valid.md" "$TEMPLATE"
  [ "$status" -eq 1 ]
  run cmp -s "$FIX/unedited-template.md" "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "valid, trailing-space and angle-brackets-scope pass" {
  passes "$FIX/valid.md"
  passes "$FIX/trailing-space.md"
  passes "$FIX/angle-brackets-scope.md"
  [ "$(grep -c "<name>" "$FIX/angle-brackets-scope.md")" = "1" ]
}

@test "valid.md has no TODO: line and the filled shape" {
  [ "$(grep -ci '^[[:space:]]*todo:' "$FIX/valid.md")" = "0" ]
  [ "$(lines_under "## Scope" "$FIX/valid.md")" = "2" ]
  [ "$(lines_under "## Objective" "$FIX/valid.md")" = "1" ]
}

@test "trailing-space.md equals valid.md except for trailing whitespace on headings" {
  run diff <(sed 's/[[:space:]]*$//' "$FIX/trailing-space.md") "$FIX/valid.md"
  [ "$status" -eq 0 ]
  run cmp -s "$FIX/trailing-space.md" "$FIX/valid.md"
  [ "$status" -eq 1 ]
}

@test "the template and unedited-template.md fail, naming the four headings" {
  fails "$TEMPLATE" "## Repo owner" "## Objective" "## Business case" "## Scope"
  fails "$FIX/unedited-template.md" "## Repo owner" "## Objective" "## Business case" "## Scope"
}

# --- criterion 6: one fixture per missing heading ---

@test "missing-<slug>.md: valid.md minus that heading and its lines, exit 1, heading named" {
  local s h n d
  for s in repo-owner objective business-case merge-rule scope; do
    case "$s" in
      repo-owner) h="## Repo owner"; n=2 ;;
      objective) h="## Objective"; n=2 ;;
      business-case) h="## Business case"; n=2 ;;
      merge-rule) h="## Merge rule"; n=2 ;;
      scope) h="## Scope"; n=3 ;;
    esac
    d=$(diff "$FIX/valid.md" "$FIX/missing-$s.md" || true)
    [ "$(printf '%s\n' "$d" | grep -c '^> ')" = "0" ] || { echo "$s: diff adds lines"; return 1; }
    [ "$(printf '%s\n' "$d" | grep -c '^< .*[^[:space:]]')" = "$n" ] || { echo "$s: diff removes other than $n lines"; return 1; }
    [ "$(printf '%s\n' "$d" | grep '^< ' | head -n1)" = "< $h" ] || { echo "$s: first removed line is not $h"; return 1; }
    fails "$FIX/missing-$s.md" "$h"
  done
}

# --- criterion 7: empty headings ---

@test "empty-merge-rule.md, empty-scope.md, empty-scope-blank.md fail naming the heading" {
  fails "$FIX/empty-merge-rule.md" "## Merge rule"
  fails "$FIX/empty-scope.md" "## Scope"
  fails "$FIX/empty-scope-blank.md" "## Scope"
}

# --- criterion 8: repeated, wrong-case and fenced headings ---

@test "duplicate-objective.md: a repeat after Scope fails" {
  [ "$(tail -n2 "$FIX/duplicate-objective.md" | head -n1)" = "## Objective" ]
  fails "$FIX/duplicate-objective.md" "## Objective"
}

@test "wrong-case.md and fenced-heading.md fail naming the heading" {
  fails "$FIX/wrong-case.md" "## Repo owner"
  fails "$FIX/fenced-heading.md" "## Business case"
}

# --- criterion 9: order and one line each ---

@test "out-of-order.md names both swapped headings; two-lines.md names Business case" {
  fails "$FIX/out-of-order.md" "## Objective" "## Business case"
  fails "$FIX/two-lines.md" "## Business case"
}

# --- criterion 10: generated cases, built from valid.md ---

# gen_top <line>... — the lines, then valid.md, in $C
gen_top() {
  C="$BATS_TEST_TMPDIR/case.md"
  { printf '%s\n' "$@"; cat "$FIX/valid.md"; } > "$C"
}

# scope_lines — the lines under ## Scope in valid.md
scope_lines() { awk 'f; $0 == "## Scope" { f = 1 }' "$FIX/valid.md"; }

# gen_scope <line>... — valid.md with the lines under ## Scope replaced
gen_scope() {
  C="$BATS_TEST_TMPDIR/case.md"
  { awk '{ print } $0 == "## Scope" { exit }' "$FIX/valid.md"; printf '%s\n' "$@"; } > "$C"
}

@test "case a: Scope lines inside a backtick fence pass" {
  gen_scope '```' "$(scope_lines | sed -n 1p)" "$(scope_lines | sed -n 2p)" '```'
  passes "$C"
}

@test "case b: backtick fence at the top, never closed, fails naming Repo owner" {
  gen_top '```'
  fails "$C" "## Repo owner"
}

@test "case c: tilde fence at the top, never closed, fails naming Repo owner" {
  gen_top '~~~'
  fails "$C" "## Repo owner"
}

@test "case d: backtick fence indented by four spaces passes" {
  gen_top '    ```'
  passes "$C"
}

@test "case e: a closed backtick fence at the top passes" {
  gen_top '```' 'one text line' '```'
  passes "$C"
}

@test "case f: a tilde line does not close a backtick fence" {
  gen_top '```' '~~~'
  fails "$C" "## Repo owner"
}

@test "case g: one intro text line at the top passes" {
  gen_top 'An intro line.'
  passes "$C"
}

@test "case h: a # Title at the top passes" {
  gen_top '# Title'
  passes "$C"
}

@test "case i: ## Notes and a line appended at the end pass" {
  C="$BATS_TEST_TMPDIR/case.md"
  { cat "$FIX/valid.md"; printf '\n## Notes\nOne line.\n'; } > "$C"
  passes "$C"
}

@test "case j: ## Notes before Repo owner fails naming both" {
  gen_top '## Notes' 'One line.' ''
  fails "$C" "## Repo owner" "## Notes"
}

@test "case k: ## Notes before Scope fails naming Notes" {
  C="$BATS_TEST_TMPDIR/case.md"
  awk '$0 == "## Scope" { print "## Notes"; print "One line."; print "" } { print }' "$FIX/valid.md" > "$C"
  fails "$C" "## Notes"
}

@test "case l: six lines under Scope pass" {
  gen_scope 'one' 'two' 'three' 'four' 'five' 'six'
  passes "$C"
}

@test "case m: the template placeholder under Scope fails naming Scope" {
  gen_scope 'TODO: what belongs in this repo' "$(scope_lines | sed -n 2p)"
  fails "$C" "## Scope"
}

@test "case n: an indented TODO: line under Scope fails naming Scope" {
  gen_scope '   TODO: x' "$(scope_lines | sed -n 2p)"
  fails "$C" "## Scope"
}

@test "case o: a lower-case todo: line under Scope fails naming Scope" {
  gen_scope 'todo: x' "$(scope_lines | sed -n 2p)"
  fails "$C" "## Scope"
}

@test "case p: TODOs without a colon at the line start, TODO: mid-line, pass" {
  gen_scope 'TODOs are kept in the tracker, see TODO: in issues.' "$(scope_lines | sed -n 2p)"
  passes "$C"
}

# --- criterion 11: the first real charter ---

@test "real-alfred-platform.md starts with Repo owner and passes (comment 6360086722)" {
  [ "$(head -n1 "$FIX/real-alfred-platform.md")" = "## Repo owner" ]
  passes "$FIX/real-alfred-platform.md"
}

# --- criterion 12: shipped ---

@test "the script is executable, has no set -x; the workflow watches templates/" {
  [ -x "$CHECK" ]
  [ "$(grep -cE '^[[:space:]]*set[[:space:]]+-[a-z]*x' "$CHECK")" = "0" ]
  [ "$(grep -c "^      - 'templates/\*\*'$" "$ROOT/.github/workflows/shellcheck.yml")" = "2" ]
}

# --- criterion 13: README ---

@test "README documents the two paths and the two sentences" {
  R="$ROOT/README.md"
  grep -F '"${CLAUDE_PLUGIN_ROOT}/templates/CHARTER.md"' "$R"
  grep -F '"${CLAUDE_PLUGIN_ROOT}/bin/alfred-charter-check" CHARTER.md' "$R"
  grep -F 'The check fails on a placeholder: a line under a heading that starts with `TODO:`.' "$R"
  grep -F "Where the register has no objective for the project, write the project's own objective as one line; the check accepts any single line under \`## Objective\` that does not start with \`TODO:\`." "$R"
}
