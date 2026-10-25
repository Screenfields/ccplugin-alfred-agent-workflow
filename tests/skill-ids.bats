#!/usr/bin/env bats
# CCW-122 criterion 2: the skills that create or name issues and PRs use IDs as
# the issue-and-pr-titles-carry-codes rule states. Mechanical greps only.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  S="$ROOT/skills"
  RULE="$ROOT/rules/routed/issue-and-pr-titles-carry-codes.md"
  EIGHT="develop drop-issue file-escalation-when-blocked autonomous-worker-loop release merge review git-commit"
  FIVE="develop drop-issue file-escalation-when-blocked autonomous-worker-loop release"
}

has() { grep -qF -- "$2" "$1"; }

@test "no placeholder title survives in skills/" {
  if grep -rnF -- '--title "{' "$S"; then false; fi
  for t in '{short title}' '{same title}' '{one-line title}'; do
    if grep -rnF -- "$t" "$S"; then false; fi
  done
}

@test "develop: three gh pr create calls, each with the coded title" {
  [ "$(grep -c 'gh pr create' "$S/develop/SKILL.md")" -eq 3 ]
  [ "$(grep -cF -- '--title "<CODE>-<n>: ' "$S/develop/SKILL.md")" -eq 3 ]
}

@test "autonomous-worker-loop and release carry the coded title once; release states its sources" {
  [ "$(grep -cF -- '--title "<CODE>-<n>: ' "$S/autonomous-worker-loop/SKILL.md")" -eq 1 ]
  [ "$(grep -cF -- '--title "<CODE>-<n>: ' "$S/release/SKILL.md")" -eq 1 ]
  has "$S/release/SKILL.md" 'cache-only'
  has "$S/release/SKILL.md" '^[A-Z]{2,5}-[0-9]+: '
}

@test "drop-issue and escalation: one create, one coded edit, the URL segment and CCW-140 note" {
  for k in drop-issue file-escalation-when-blocked; do
    f="$S/$k/SKILL.md"
    [ "$(grep -c 'gh issue create' "$f")" -eq 1 ]
    [ "$(grep -cF -- 'gh issue edit <n> --title "<CODE>-<n>: ' "$f")" -eq 1 ]
    has "$f" 'last path segment'
    has "$f" 'CCW-140'
  done
}

@test "all eight skills and the rule carry the CODE source sentence" {
  for k in $EIGHT; do has "$S/$k/SKILL.md" 'CODE comes from alfred-code-lookup' || { echo "$k"; return 1; }; done
  has "$RULE" 'CODE comes from alfred-code-lookup'
}

@test "the five creating skills and the rule carry the lookup outcomes and the CL invocation" {
  for f in $(for k in $FIVE; do echo "$S/$k/SKILL.md"; done) "$RULE"; do
    for t in 'exit 1' 'exit 2' 'repo has no registry code' 'registry unreachable; title not coded' 'CLAUDE_PLUGIN_ROOT'; do
      has "$f" "$t" || { echo "$f lacks: $t"; return 1; }
    done
  done
}

@test "the five creating skills capture RC right after the lookup; release never uses the config code" {
  for k in $FIVE; do
    grep -qE 'CODE=\$\("\$CL" .*\); RC=\$\?$' "$S/$k/SKILL.md" || { echo "$k"; return 1; }
    has "$S/$k/SKILL.md" 'Branch on RC'
  done
  has "$S/release/SKILL.md" 'never applies in this step'
  has "$S/release/SKILL.md" 'Do not substitute the config `code`'
  has "$S/release/SKILL.md" 'Cache-only bump with no item'
}

@test "init: strips userinfo, handles a missing origin, removes its temp file" {
  f="$ROOT/commands/init.md"
  has "$f" "sed -E 's#^(https?://)[^@/]*@#\\1#'"
  has "$f" 'no origin remote'
  has "$f" "trap 'rm -f \"\$ERRF\"' EXIT"
  has "$f" 'ERR=$(cat "$ERRF")'
}

@test "merge and review name PRs as <CODE>#<n>; no old forms" {
  has "$S/merge/SKILL.md" '<CODE>#<n>'
  if has "$S/merge/SKILL.md" 'PR #{N}'; then false; fi
  has "$S/review/SKILL.md" '<CODE>#<n>'
  has "$S/review/SKILL.md" 'strip the code'
  if has "$S/review/SKILL.md" '`#N` was supplied'; then false; fi
  if has "$S/review/SKILL.md" 'review #N'; then false; fi
}

@test "git-commit: coded subject line" {
  has "$S/git-commit/SKILL.md" '<CODE>-<n>: <what changed>'
}
