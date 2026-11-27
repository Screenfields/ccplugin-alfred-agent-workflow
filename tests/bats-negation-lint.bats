#!/usr/bin/env bats
# Self-test for tests/lint/bats-negation.py (CCW-148). Fixtures live in
# tests/fixtures/bats-lint/ as *.bats.fixture so no bats run collects them.
# The fixtures are the vacuous and valid forms; each assertion names the
# fixture's file:line, so a lint that exits 0 or 1 unconditionally fails here.

LINT="$BATS_TEST_DIRNAME/lint/bats-negation.py"
FX="$BATS_TEST_DIRNAME/fixtures/bats-lint"

lint() { python3 -I "$LINT" "$@"; }

# Expect exit 1, exactly the listed line numbers of one fixture, and the rule text.
assert_flagged() {
  local fixture="$1"; shift
  run lint "$FX/$fixture.bats.fixture"
  [ "$status" -eq 1 ]
  local l
  for l in "$@"; do
    [[ "$output" == *"$fixture.bats.fixture:$l: "* ]]
  done
  [[ "$output" == *"$# finding(s)"* ]]
  [[ "$output" == *'run ! cmd'* ]]
  [[ "$output" == *'! cmd || false'* ]]
  [[ "$output" == *'if cmd; then false; fi'* ]]
}

assert_clean() {
  run lint "$FX/$1.bats.fixture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked 1 file(s), 0 finding(s)"* ]]
}

@test "valid forms pass mid-test and as last command (run !, || false, if/then false, not-a-command text)" {
  assert_clean ok_forms
}

@test "multi-line valid forms pass (continuation, trailing ||, broken pipeline, last command)" {
  assert_clean ok_multiline
}

@test "bang text in heredocs, quotes and comments is not a command" {
  assert_clean ok_text
}

@test "helpers: last-command ! and a trailing && chain pass" {
  assert_clean ok_helper
}

@test "bare ! followed by another command is flagged" {
  assert_flagged v_bare 3
}

@test "a && ! cmd followed by another command is flagged" {
  assert_flagged v_andand 3
}

@test "then ! cmd followed by another command is flagged" {
  assert_flagged v_then 2
}

@test "a bare ! last in a for or while loop is flagged when the test continues" {
  assert_flagged v_loop 3 9
}

@test "a one-line test with a mid ! is flagged" {
  assert_flagged v_oneline 1
}

@test "|| true, || : and && false do not rescue a mid-test !" {
  assert_flagged v_or_true 2 6 10
}

@test "a multi-line bare ! followed by another command is flagged once, at its first line" {
  assert_flagged v_multiline 2
}

@test "heredoc bodies hide nothing: the later ! is flagged, body lines are not" {
  assert_flagged v_heredoc 6 27 32
}

@test "helpers, setup, teardown and one-line helpers are checked" {
  assert_flagged v_helper 2 6 10 13
}

@test "an unterminated heredoc exits 2 naming file and start line" {
  run lint "$FX/err_heredoc.bats.fixture"
  [ "$status" -eq 2 ]
  [[ "$output" == *"err_heredoc.bats.fixture:2: unterminated heredoc"* ]]
}

@test "an unterminated quote exits 2 naming file and start line" {
  run lint "$FX/err_quote.bats.fixture"
  [ "$status" -eq 2 ]
  [[ "$output" == *"err_quote.bats.fixture:2: unterminated quote"* ]]
}

@test "a @test with no closing brace exits 2" {
  run lint "$FX/err_noclose.bats.fixture"
  [ "$status" -eq 2 ]
  [[ "$output" == *"err_noclose.bats.fixture:1: test has no closing }"* ]]
}

@test "a parse error wins over findings in the same run" {
  run lint "$FX/v_bare.bats.fixture" "$FX/err_quote.bats.fixture"
  [ "$status" -eq 2 ]
  [[ "$output" == *"v_bare.bats.fixture:3: "* ]]
}

@test "explicit paths replace the globs; a missing file exits 2" {
  run lint "$FX/does-not-exist.bats.fixture"
  [ "$status" -eq 2 ]
  [[ "$output" == *"does-not-exist"* ]]
}

@test "a directory argument exits 2" {
  run lint "$FX"
  [ "$status" -eq 2 ]
}

@test "no arguments and no matching file exits 2, not success" {
  cd "$BATS_TEST_TMPDIR"
  run lint
  [ "$status" -eq 2 ]
  [[ "$output" == *"no tests/*.bats"* ]]
}

@test "no arguments covers tests/*.bats and tests/*/*.bats" {
  cd "$BATS_TEST_TMPDIR"
  mkdir -p tests/sub
  printf '@test "ok" {\n  true\n}\n' > tests/a.bats
  printf '@test "vacuous" {\n  ! false\n  true\n}\n' > tests/sub/x.bats
  run lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/sub/x.bats:2: "* ]]
  [[ "$output" == *"checked 2 file(s), 1 finding(s)"* ]]
}

@test "no arguments on a clean tree exits 0 with a file count" {
  cd "$BATS_TEST_TMPDIR"
  mkdir -p tests
  printf '@test "ok" {\n  true\n}\n' > tests/a.bats
  run lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked 1 file(s), 0 finding(s)"* ]]
}

@test "|| false followed by || or && is flagged mid-test and for ||, last" {
  assert_flagged v_orfalse_tail 2 6 11
}

@test "|| false; and a last && chain after || false pass" {
  assert_clean ok_orfalse_tail
}

@test "a ! mid-subshell or mid-brace-group is flagged, one line and multi-line" {
  assert_flagged v_subshell 2 7 13
}

@test "a ! last in a subshell passes, one line and multi-line (both mirrors)" {
  assert_clean ok_subshell
  assert_clean ok_subshell2
}

@test "a ! in a case arm followed by more is flagged" {
  assert_flagged v_case 4 12
}

@test "case arms with ! last pass, one-line and multi-line, case last" {
  assert_clean ok_case
  assert_clean ok_case2
}

@test "helpers with the brace on the next line are checked (name(), function name, setup())" {
  assert_flagged v_helper_brace 3 8 13
}

@test "a last ! in a next-line-brace helper passes" {
  assert_clean ok_helper_brace
}

@test "name() with no brace after it is not a function head" {
  assert_flagged v_notfunc 7
}

@test "if/elif/else branches with ! last pass when the if is last" {
  assert_clean ok_ifelse_last
}

@test "if/else branches followed by another command are flagged" {
  assert_flagged v_ifelse_mid 3 5
}

@test "a ! mid-compound is flagged when the compound is itself the last command" {
  assert_flagged v_last_compound 3 7 10 15
}

@test "form 5 pinned: last ! in a multi-line \$( is flagged (plain and local)" {
  assert_flagged v_subst 4 11
}

@test "arithmetic shift by a name is not a heredoc" {
  assert_clean ok_arith
  assert_flagged v_arith 5
}

@test "nested quotes inside \$( inside double quotes parse" {
  assert_clean ok_quotes
  assert_flagged v_quotes 3
}

@test "a really unterminated nested quote exits 2 naming file and start line" {
  run lint "$FX/err_quote_nested.bats.fixture"
  [ "$status" -eq 2 ]
  [[ "$output" == *"err_quote_nested.bats.fixture:2: unterminated quote"* ]]
}

@test "the lint is green on this self-test and on the real tests tree" {
  cd "$BATS_TEST_DIRNAME/.."
  run lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 finding(s)"* ]]
}
