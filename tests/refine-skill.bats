#!/usr/bin/env bats
# skills/refine/SKILL.md (ccplugin#155): the analyst and readiness reviewer
# pair, new to ready. Greps on the skill, the agent files and the README; no
# network. The live run (criterion 5) is recorded in the PR.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  SKILL="$ROOT/skills/refine/SKILL.md"
}

# fm_key <key> — the value of a frontmatter key (first block only).
fm_key() {
  awk '/^---$/ {n++; next} n == 1' "$SKILL" | grep -E "^$1:" | head -n1
}

@test "the skill file exists with name, description and allowed-tools" {
  [ -f "$SKILL" ]
  [ "$(head -n1 "$SKILL")" = "---" ]
  [ "$(fm_key name)" = "name: refine" ]
  # a non-empty description body, inline or folded (description: >)
  d=$(awk '/^---$/ {n++; next} n == 1' "$SKILL" \
        | awk '/^description:/ {on=1; sub(/^description:[[:space:]]*>?[[:space:]]*/, ""); print; next} on && /^[[:space:]]/ {print; next} {on=0}')
  [ -n "$(printf '%s' "$d" | tr -d '[:space:]')" ] || { echo "empty description"; return 1; }
  [ -n "$(fm_key allowed-tools)" ]
}

@test "allowed-tools includes Agent and SendMessage" {
  t=$(fm_key allowed-tools)
  [[ "$t" =~ (:|,)\ *Agent(,|$) ]] || { echo "no Agent: $t"; return 1; }
  [[ "$t" =~ (:|,)\ *SendMessage(,|$) ]] || { echo "no SendMessage: $t"; return 1; }
}

@test "the README slash-commands table has the refine row" {
  awk '/^## Slash commands/ {on=1; next} /^## / {on=0} on' "$ROOT/README.md" \
    | grep -qE '^\| `/alfred-agent:refine` \|'
}

@test "the pair's definitions exist and the README pairs table names them as a pair" {
  [ -f "$ROOT/agents/analyst.md" ]
  [ -f "$ROOT/agents/readiness-reviewer.md" ]
  grep -qE '^\| `analyst` \| `readiness-reviewer` \|' "$ROOT/README.md"
  grep -qE '^\| `readiness-reviewer` \| `analyst` \|' "$ROOT/README.md"
}

@test "the skill runs the pair: both specialists, the same-analyst loop, the limit and the hub" {
  grep -q '`analyst`' "$SKILL"
  grep -q '`readiness-reviewer`' "$SKILL"
  grep -q 'fresh `readiness-reviewer`' "$SKILL"
  grep -q 'SendMessage to the analyst.s agent ID' "$SKILL"
  grep -q 'Do not start a new analyst' "$SKILL"
  grep -q 'SendMessage to the reviewer.s agent ID' "$SKILL"
  grep -q 'alfred-config get failed-review-max' "$SKILL"
  grep -q 'escalation to the hub with the messaging skill' "$SKILL"
  grep -q 'failed-review-max limit sends it to the hub' "$SKILL"
  grep -q 'hit a review or overrun limit' "$SKILL"
}

@test "the skill carries the appendix E row wording" {
  grep -q 'the analyst and readiness reviewer pair, new to ready' "$SKILL"
}

@test "the brief returns the body as output and does not edit the item" {
  grep -q 'return the new body as the output' "$SKILL"
  grep -q 'Do not edit the item' "$SKILL"
  grep -q 'open questions and split proposals go to the lead' "$SKILL"
  grep -q 'do not open the split items' "$SKILL"
}

@test "the skill ends with the hand-over sentence" {
  grep -q 'Hand the pass to the lead' "$SKILL"
  last=$(grep -v '^[[:space:]]*$' "$SKILL" | tail -n1)
  [[ "$last" == "Hand the pass to the lead"* ]] || { echo "last line: $last"; return 1; }
}

@test "the skill never edits the item or sets a label" {
  if grep -q -- '--add-label' "$SKILL"; then echo "add-label in skill"; return 1; fi
  if grep -q 'gh issue edit' "$SKILL"; then echo "gh issue edit in skill"; return 1; fi
}

@test "the loop counts before it sends, and large items missing only approval are not looped" {
  c=$(grep -n -m1 'first count the failed rounds, before sending any findings' "$SKILL" | cut -d: -f1)
  m=$(grep -n -m1 'send the reviewer.s findings to the same analyst' "$SKILL" | cut -d: -f1)
  [ -n "$c" ] && [ -n "$m" ] && [ "$c" -lt "$m" ]
  grep -q 'only failed check is the missing owner approval is not looped' "$SKILL"
  grep -q 'checks the carried body and not the item' "$SKILL"
  grep -q "analyst's latest open questions and split proposals" "$SKILL"
}

@test "the check for forbidden calls does catch them" {
  printf 'gh issue edit 1 --add-label ready\n' > "$BATS_TEST_TMPDIR/x.md"
  grep -q -- '--add-label' "$BATS_TEST_TMPDIR/x.md"
  grep -q 'gh issue edit' "$BATS_TEST_TMPDIR/x.md"
}

@test "the skill body has no digits" {
  out=$(awk '/^---$/ && !seen {inside = !inside; if (!inside) seen = 1; next} !inside' "$SKILL" | grep -nE '[0-9]' || true)
  [ -z "$out" ] || { echo "$out"; return 1; }
}
