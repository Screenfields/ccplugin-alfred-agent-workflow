#!/usr/bin/env bats
# The phase skills and their pairs (ccplugin#129, slice 1 C2): design, develop,
# retro, waiting, troubleshoot, the README gate sentence and the Gate 2 mapping
# table, the reviewer-light key (its own case is in thresholds.bats). Greps on
# the texts; prose cannot be run. No network. The live merge (criterion 13) is
# recorded in the PR.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  README="$ROOT/README.md"
  DESIGN="$ROOT/skills/design/SKILL.md"
  DEVELOP="$ROOT/skills/develop/SKILL.md"
  RETRO="$ROOT/skills/retro/SKILL.md"
  WAITING="$ROOT/commands/waiting.md"
  TROUBLE="$ROOT/skills/troubleshoot/SKILL.md"
  MERGE="$ROOT/skills/merge/SKILL.md"
}

# sect <file> <heading line> — the heading line (exact) up to, not including, the next
# heading of the same or a higher level. Prints nothing when the heading is absent.
sect() {
  awk -v h="$2" '
    function level(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    $0 == h { on = 1; lv = level($0); print; next }
    on && /^#+ / && level($0) <= lv { on = 0 }
    on { print }' "$1"
}

# has <text> <literal> — the literal (fixed string) occurs in the text.
has() {
  grep -qF -- "$2" <<<"$1" || { echo "missing: $2"; return 1; }
}

# lacks <text> <literal> — the literal does not occur. grep exit 1 is "no match"; 2 is an error.
lacks() {
  run grep -nF -- "$2" <<<"$1"
  [ "$status" -eq 1 ] || { echo "found: $output"; return 1; }
}

# literals_in <text> — digits or % left after removing the allowed references (AP-ADRnnnn,
# AP-nnnn, AP#nnnn, doctrine NN) and the step references ("Step 6", "Steps 2 to 5").
literals_in() {
  sed -E 's/AP-ADR[0-9]{4}//g; s/AP-[0-9]+//g; s/AP#[0-9]+//g; s/[Dd]octrines? [0-9]+//g; s/Steps? [0-9]+(\.[0-9]+)?[a-z]?( to [0-9]+)?//g' <<<"$1" \
    | grep -nE '[0-9%]' || true
}

# semis_in <text> — lines with a semicolon outside double quotes (quoted text is verbatim).
semis_in() { sed -E 's/"[^"]*"//g' <<<"$1" | grep -n ';' || true; }

# line_of <literal> <file> — the first line number holding the literal.
line_of() { grep -nF -m1 -- "$1" "$2" | cut -d: -f1; }

# --- criterion 1: no second review mechanism ---------------------------------

@test "no second review mechanism" {
  [ ! -e "$ROOT/bin/alfred-review-gate" ]
  run grep -rniE 'review/verdict|Review panel verdict' "$ROOT/skills" "$ROOT/commands" "$ROOT/agents" "$ROOT/bin" "$ROOT/hooks"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  n=$(jq '[.. | objects | keys[] | select(test("gate|verdict|allowlist"))] | length' "$ROOT/config/thresholds.json")
  [ "$n" -eq 0 ]
  # the same pass finds a key it should find, so a zero above is not an empty pass
  w=$(jq '[.. | objects | keys[] | select(test("wip-limit"))] | length' "$ROOT/config/thresholds.json")
  [ "$w" -eq 1 ]
  grep -qF 'alfred-review' "$MERGE"
  grep -qF -- '--match-head-commit' "$MERGE"
  grep -qF 'check "$REPO#{N}"' "$MERGE"
}

# --- criterion 2: the README says which gate applies -------------------------

@test "one README paragraph names review/verdict, AP-1230, change-gates.md and the lead-repo gate" {
  n=$(awk -v RS= '/review\/verdict/ && /AP-1230/ && /change-gates\.md/ && /alfred-platform and alfred-platform-docs only/ && /lead-review/ && /reviewDecision/ && /including `review\/verdict`/ && /Gate 2 mapping \(lead repos\)/ {n++} END {print n + 0}' "$README")
  [ "$n" -eq 1 ]
}

# --- criterion 2a: the Gate 2 mapping table -----------------------------------

GATE2='### Gate 2 mapping (lead repos)'

# gate2_range — the subsection, from its heading to the next ### heading.
gate2_range() { sect "$README" "$GATE2"; }

@test "the Gate 2 subsection is a sibling of Exit codes and Runbook, outside their ranges" {
  [ "$(grep -cxF -- "$GATE2" "$README")" -eq 1 ]
  ec=$(sed -n '/^### Exit codes/,/^### /p' "$README")
  rb=$(sed -n '/^### Runbook/,/^## /p' "$README")
  lacks "$ec" 'Gate 2 mapping'
  lacks "$rb" 'Gate 2 mapping'
}

@test "the Gate 2 table has one row for each of the seven keywords" {
  r=$(gate2_range)
  [ -n "$r" ]
  for row in '| 1 | **head SHA** |' '| 2 | **other than the PR author** |' '| 3 | **allowlist** |' \
             '| 4 | **ADVISORY** |' '| 5 | **regardless of CI** |' '| 6 | **author ≠ reviewer ≠ merger** |' \
             '| 7 | **Review panel verdict** comment |'; do
    c=$(grep -cF -- "$row" <<<"$r")
    [ "$c" -eq 1 ] || { echo "rows for '$row': $c"; return 1; }
  done
  [ "$(grep -cE '^\| [0-9]+ \| \*\*' <<<"$r")" -eq 7 ]
}

@test "every Gate 2 row carries an evidence token and each test title exists in review-gate.bats" {
  r=$(gate2_range)
  [ -n "$r" ]
  rows=0
  while IFS= read -r line; do
    rows=$((rows + 1))
    ev=$(awk -F'|' '{print $5}' <<<"$line")
    tokens=0
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      tokens=$((tokens + 1))
      if [ "$t" = gap ]; then continue; fi
      grep -qF "@test \"$t\"" "$ROOT/tests/review-gate.bats" || { echo "no such test title: $t"; return 1; }
    done < <(grep -oE '`[^`]+`' <<<"$ev" | sed -E 's/^`//; s/`$//')
    live=$(grep -oE 'CCW-145 6353161637 steps? [A-H]' <<<"$ev" | wc -l)
    [ $((tokens + live)) -ge 1 ] || { echo "no evidence token: $line"; return 1; }
  done < <(grep -E '^\| [0-9]+ \| \*\*' <<<"$r")
  [ "$rows" -eq 7 ]
}

@test "the Gate 2 title check does catch a title that is not in review-gate.bats" {
  # the loop above skips only the literal gap; a made-up title must not be found
  run grep -F '@test "check has no such behaviour"' "$ROOT/tests/review-gate.bats"
  [ "$status" -eq 1 ]
  run grep -F '@test "check has no identity branch"' "$ROOT/tests/review-gate.bats"
  [ "$status" -eq 0 ]
}

# --- criterion 3: design -------------------------------------------------------

@test "design sends the design to the design-reviewer pair and parks a large item for the owner" {
  s=$(sect "$DESIGN" '## Design review and the owner'"'"'s approval')
  [ -n "$s" ]
  has "$s" '`design-reviewer`'
  has "$s" 'Start a fresh `design-reviewer` specialist (`agents/design-reviewer.md`) with the Agent tool'
  has "$s" 'large or very large'
  has "$s" '`alfred-config get waiting-label`'
  has "$s" '`alfred-agent:ecr`'
  has "$s" 'Large and very large need the owner at ready and at designed, and an expert consulting review'
  has "$s" 'work-and-review-in-pairs'
  has "$s" '`alfred-config get failed-review-max`'
  has "$s" 'separate from the critical-review pass of Step 4.5b'
  has "$s" 'add one `Precedent:` line to the design note, in the format that `agents/design-reviewer.md` defines'
  has "$s" "Act on the reviewer's \`Precedent:\` and \`Real alternatives:\` lines"
  has "$s" '`Real alternatives: yes` with no valid precedent sends the item to the owner for architectural review (AP-ADR0035, item two)'
  has "$s" 'SendMessage to its agent ID'
  has "$s" 'add its verdict to the Decision Log'
  has "$s" 'remove the status and record the decision on the item'
  lacks "$s" 'Precedent: <link>'
  # the ECR runs before the item is parked for the owner
  before=${s%%park the item with the status*}
  [ "$before" != "$s" ] || { echo "no parking sentence"; return 1; }
  has "$before" 'run `alfred-agent:ecr`'
}

@test "design: Step 4.5 exits go to the design review and completion needs its pass" {
  s=$(sect "$DESIGN" '## Step 4.5: Coupled-ADR review gate')
  [ -n "$s" ]
  [ "$(grep -cF 'proceed directly to the design review below' <<<"$s")" -eq 1 ]
  [ "$(grep -cF 'and proceed to the design review below' <<<"$s")" -eq 1 ]
  lacks "$s" 'to Step 5'
  has "$s" 'the design reviewer has passed it'
  has "$s" 'for a large or very large item, the owner has approved it'
  lacks "$s" 'Only after all findings have dispositions'
}

@test "design: the section comes after the coupled-ADR gate and before the prerequisites" {
  a=$(line_of '## Step 4.5' "$DESIGN")
  b=$(grep -nxF -m1 -- "## Design review and the owner's approval" "$DESIGN" | cut -d: -f1)
  c=$(grep -nxF -m1 -- '## Step 5: Prerequisites' "$DESIGN" | cut -d: -f1)
  [ -n "$a" ]
  [ -n "$b" ]
  [ -n "$c" ]
  [ "$a" -lt "$b" ]
  [ "$b" -lt "$c" ]
}

# --- criterion 4: develop --------------------------------------------------------

@test "develop gives the builder and code reviewer pair and the same-builder fix loop" {
  s=$(sect "$DEVELOP" '## The builder and code reviewer pair')
  [ -n "$s" ]
  has "$s" '`builder`'
  has "$s" 'agents/builder.md'
  has "$s" 'The brief links the work item and carries the purpose'
  has "$s" 'commit on the branch, do not push, because `agents/builder.md` otherwise ends with a push'
  has "$s" "Every push stays the lead's (Step 6)"
  has "$s" 'The lead does the role switch and the `git checkout main` steps of Step 2 first'
  lacks "$s" "are the builder's work"
  lacks "$s" 'no design document'
  [ "$(grep -oF 'same builder' <<<"$s" | wc -l)" -eq 1 ]
  has "$s" '`code-reviewer`'
  has "$s" '`document-reviewer` for documents only'
  has "$s" 'Findings go back to the same builder'
  has "$s" 'the fix goes to the same reviewer'
  has "$s" '`alfred-config get failed-review-max`'
  has "$s" 'escalates to the hub'
  has "$s" 'The builder commits each fix and the lead pushes it'
  has "$s" 'refresh the Head SHA and the diff as in review-panel Step 1, then send the new brief to the same reviewer with SendMessage to its agent ID'
}

@test "develop spells out the light path through reviewer-light, read from the config" {
  s=$(sect "$DEVELOP" '### The light path')
  [ -n "$s" ]
  has "$s" 'Small work (AP-ADR0017) skips the designed state and has a lighter reviewer, but every transition it does take still passes a review'
  has "$s" '`reviewer-light`'
  has "$s" '`model-setting-per-role`'
  has "$s" '`alfred-config get model-setting-per-role`'
  has "$s" 'the tier map in the README'
  has "$s" 'medium is sonnet'
  has "$s" 'the Size paragraph of `agreement/lead.md`'
  has "$s" 'Effort is passed as is, except `highest`, which is `max`'
  has "$s" 'Add `model` and `effort` to the Agent call in review-panel Step 3'
  has "$s" 'Fix rounds follow the loop above, with the builder committing and the lead pushing'
}

@test "develop light-path text: no digit follows the words tier or effort" {
  s=$(sect "$DEVELOP" '### The light path')
  [ -n "$s" ]
  run grep -niE '(tier|effort)[^[:alpha:]]*[0-9]' <<<"$s"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  # the same pattern does catch a planted digit
  run grep -niE '(tier|effort)[^[:alpha:]]*[0-9]' <<<'start the reviewer at tier 2'
  [ "$status" -eq 0 ]
}

@test "develop keeps Step 7: review-panel, alfred-review post and the merge skill" {
  has "$(sect "$DEVELOP" '## Step 7: Review, then merge')" 'Run the review as in `/alfred-agent:review-panel` and post it at the head with `alfred-review post`'
  has "$(sect "$DEVELOP" '## Step 7: Review, then merge')" 'run `/alfred-agent:merge {PR}`'
  has "$(cat "$DEVELOP")" 'alfred-review post'
  has "$(cat "$DEVELOP")" '/alfred-agent:merge'
}

@test "develop: the new text names no push command and no merge command" {
  s=$(sect "$DEVELOP" '## The builder and code reviewer pair')
  [ -n "$s" ]
  lacks "$s" 'git push'
  lacks "$s" 'gh pr merge'
  lacks "$s" 'switch-role'
}

@test "develop lists SendMessage in allowed-tools for the same-builder loop" {
  fm=$(awk '/^---$/ {n++; next} n == 1' "$DEVELOP" | grep -E '^allowed-tools:')
  [[ "$fm" =~ (:|,)\ *SendMessage(,|$) ]] || { echo "$fm"; return 1; }
}

# --- criterion 5 and 6: retro ----------------------------------------------------

@test "retro: the agenda section holds the seven points, in order, before the first step" {
  s=$(sect "$RETRO" '## The agenda')
  [ -n "$s" ]
  has "$s" 'lighter going down'
  prev=0
  for p in 'results, end states reached and reviews failed' 'cost, actual against estimate' \
           'friction per rule, role and instruction' 'rebalancing' 'pruning' 'improvement proposals' 'the loop itself'; do
    n=$(grep -nF -- "$p" <<<"$s" | head -n1 | cut -d: -f1)
    [ -n "$n" ] || { echo "missing: $p"; return 1; }
    [ "$n" -gt "$prev" ] || { echo "out of order: $p"; return 1; }
    prev=$n
  done
  a=$(line_of '## The agenda' "$RETRO")
  st=$(line_of '### Step 1' "$RETRO")
  [ -n "$a" ]
  [ -n "$st" ]
  [ "$a" -lt "$st" ]
}

@test "retro keeps its existing steps and output format" {
  for h in '### Step 1: Review the Session' '### Step 2: Categorize Findings' '### Step 3: Abstract, Generalize, and Assign a Concrete Action' \
           '### Step 4: Execute All Actions' '### Step 5: File GitHub Issues for Outstanding Actions' '## Output Format' '## Anti-Patterns'; do
    [ "$(grep -cxF -- "$h" "$RETRO")" -eq 1 ] || { echo "heading: $h"; return 1; }
  done
}

@test "retro says where the retro goes: friction line, standing retro item, plugin changes to the hub" {
  s=$(sect "$RETRO" '### Where the retro goes')
  [ -n "$s" ]
  has "$s" "A small item's friction line is its retro"
  has "$s" 'gets a retro comment on the repo'"'"'s standing retro item'
  has "$s" 'Propose plugin changes to the hub'
  has "$s" 'change your own repo rules yourself'
  has "$s" 'The friction line is the "friction" part of an item'"'"'s closing comment (the Done paragraph of `agreement/lead.md`)'
  has "$s" 'The standing retro item is "the repo'"'"'s standing retro item" of the Learn paragraph'
  has "$s" 'apply to the repo'"'"'s own files'
  has "$s" 'A change to a plugin is proposed to the hub, not made here'
}

@test "retro: each agenda point is answered in the retro comment, and the output format says so" {
  s=$(sect "$RETRO" '## The agenda')
  has "$s" 'Answer each point in the retro comment'
  lacks "$s" 'nothing'
  o=$(sect "$RETRO" '## Output Format')
  has "$o" 'Answer each agenda point in the retro comment'
}

# --- criterion 7: waiting ----------------------------------------------------------

@test "waiting references the owner-communication section and carries the urgent-request rule" {
  s=$(sect "$WAITING" '## Owner-join, owner questions and urgent requests')
  [ -n "$s" ]
  has "$s" 'Asking the owner something'
  has "$s" '`hooks/owner-communication.md`'
  has "$s" '[owner-join]'
  has "$s" 'the Escalate paragraph of `agreement/lead.md`'
  has "$s" 'Remote Control'
  has "$s" 'from the hub and Alfred only'
  has "$s" 'Telegram'
  has "$s" 'a security incident, a user-visible outage beyond the bounds, a risk of data loss or a decision that blocks recovery'
  has "$s" 'every reply of the sending session ends with the request, its reason and a link'
  has "$s" '(AP-ADR0031, decision three)'
  has "$s" 'This applies when something has to reach the owner outside this walkthrough'
  has "$s" 'the item format of Step 3 governs'
  has "$s" 'the owner-communication text injected at SessionStart governs owner-joins and questions'
  has "$s" 'send an owner-join only if the decision blocks you and a written question is not enough'
  lacks "$s" 'A lead is not the hub or Alfred'
  a=$(grep -nxF '## Owner-join, owner questions and urgent requests' "$WAITING" | cut -d: -f1)
  c=$(grep -nxF '## Step 6: Closing summary' "$WAITING" | cut -d: -f1)
  [ -n "$a" ]
  [ -n "$c" ]
  [ "$a" -lt "$c" ]
}

@test "waiting does not restate the owner-join format, and the target has it complete" {
  s=$(sect "$WAITING" '## Owner-join, owner questions and urgent requests')
  [ -n "$s" ]
  lacks "$s" 'Options'
  lacks "$s" 'Blocked'
  t=$(sect "$ROOT/hooks/owner-communication.md" '## Asking the owner something')
  [ -n "$t" ]
  has "$t" '`[owner-join] <project>: <decision>`'
  has "$t" '(Decision, Options, Blocked, Session)'
  has "$t" '[owner-join] resolved: <decision>'
}

@test "waiting keeps its existing reads" {
  has "$(cat "$WAITING")" '`alfred-config get waiting-label`'
  has "$(cat "$WAITING")" 'post the decision as a comment'
}

# --- criterion 8: troubleshoot -----------------------------------------------------

@test "troubleshoot has a separate Incident handling (hub) section with the incident-reviewer" {
  [ "$(grep -cxF '## Incident handling (hub)' "$TROUBLE")" -eq 1 ]
  s=$(sect "$TROUBLE" '## Incident handling (hub)')
  has "$s" '`incident-reviewer`'
  has "$s" 'agents/incident-reviewer.md'
  has "$s" 'the Size paragraph of `agreement/lead.md`'
  d=$(line_of '**Diagnose.**' "$TROUBLE")
  m=$(line_of '**Mitigate.**' "$TROUBLE")
  i=$(line_of '**`incident-reviewer`.**' "$TROUBLE")
  g=$(line_of '**Apply on go.**' "$TROUBLE")
  f=$(line_of '**A sized fix.**' "$TROUBLE")
  [ -n "$d" ]
  [ -n "$m" ]
  [ -n "$i" ]
  [ -n "$g" ]
  [ -n "$f" ]
  [ "$d" -lt "$m" ]
  [ "$m" -lt "$i" ]
  [ "$i" -lt "$g" ]
  [ "$g" -lt "$f" ]
  has "$s" 'The order is: diagnose, choose the mitigation, the incident reviewer reviews it, apply it on go, then a sized fix.'
  has "$s" 'Step 0'"'"'s cleanup contract applies'
  has "$s" '"Never implement a fix" does not apply to an approved mitigation'
  has "$s" 'the production evidence the reviewer cannot read'
  has "$s" 'send the new mitigation to the same reviewer with SendMessage to its agent ID'
  has "$s" 'After `alfred-config get failed-review-max` rounds that end in stop, escalate to Alfred'
  has "$s" 'it follows design and develop as the class requires'
  fm=$(awk '/^---$/ {n++; next} n == 1' "$TROUBLE" | grep -E '^allowed-tools:')
  [[ "$fm" =~ (:|,)\ *SendMessage(,|$) ]] || { echo "$fm"; return 1; }
}

@test "troubleshoot keeps the lead flow headings" {
  for h in '## Step 0 — Cleanup contract (do this first)' '## Step 1 — State the symptom precisely' '## Step 2 — Gather ground truth' \
           '## Step 3 — Form hypotheses' '## Step 4 — Probe narrowly' '## Step 5 — Conclude or escalate' '## Step 6 — Teardown' '## Rules'; do
    [ "$(grep -cxF -- "$h" "$TROUBLE")" -eq 1 ] || { echo "heading: $h"; return 1; }
  done
}

# --- no literal threshold in the new texts -----------------------------------------

@test "the new texts carry no literal threshold number" {
  for spec in "$DESIGN|## Design review and the owner's approval" "$DEVELOP|## The builder and code reviewer pair" \
              "$RETRO|## The agenda" "$WAITING|## Owner-join, owner questions and urgent requests" \
              "$TROUBLE|## Incident handling (hub)"; do
    f=${spec%%|*}
    h=${spec#*|}
    s=$(sect "$f" "$h")
    [ -n "$s" ] || { echo "no section $h in $f"; return 1; }
    out=$(literals_in "$s")
    [ -z "$out" ] || { echo "$f: $out"; return 1; }
  done
}

@test "the new prose has no semicolon, apart from quoted text" {
  for spec in "$DESIGN|## Design review and the owner's approval" "$DEVELOP|## The builder and code reviewer pair" \
              "$RETRO|## The agenda" "$WAITING|## Owner-join, owner questions and urgent requests" \
              "$TROUBLE|## Incident handling (hub)" "$README|### Phase skills and their pairs"; do
    f=${spec%%|*}
    h=${spec#*|}
    s=$(sect "$f" "$h")
    [ -n "$s" ] || { echo "no section $h in $f"; return 1; }
    out=$(semis_in "$s")
    [ -z "$out" ] || { echo "$f: $out"; return 1; }
  done
  # README: the Gate 2 intro, the Thresholds section and the gate paragraph; table rows are the spec's own text
  out=$(semis_in "$(sect "$README" "$GATE2" | grep -v '^|')")
  [ -z "$out" ] || { echo "$out"; return 1; }
  out=$(semis_in "$(sect "$README" '## Thresholds (`config/thresholds.json`, `bin/alfred-config`)')")
  [ -z "$out" ] || { echo "$out"; return 1; }
  out=$(semis_in "$(awk -v RS= '/including `review\/verdict`/' "$README")")
  [ -z "$out" ] || { echo "$out"; return 1; }
}

@test "the semicolon check does catch a planted semicolon and keeps a quoted one" {
  [ -n "$(semis_in 'one; two')" ]
  [ -z "$(semis_in 'the rule says "one; two" and no more')" ]
}

@test "the literal check does catch a planted number, a percent sign and a step range it should keep" {
  [ -n "$(literals_in 'Stop after 3 rounds.')" ]
  [ -n "$(literals_in 'Stop at 50%.')" ]
  [ -z "$(literals_in 'See AP-ADR0022, AP-1230, AP#1140, doctrine 10 and Steps 2 to 5, then Step 6.')" ]
}

# --- criterion 9: the README Thresholds section --------------------------------------

@test "the README Thresholds section names reviewer-light" {
  s=$(sect "$README" '## Thresholds (`config/thresholds.json`, `bin/alfred-config`)')
  [ -n "$s" ]
  has "$s" '`reviewer-light`'
  has "$s" '{"tier":"medium","effort":"medium"}'
}

# --- criterion 10: the named specialists exist ----------------------------------------

@test "every specialist named in the five texts has an agents file and a README specialists row" {
  names=$(cat "$DESIGN" "$DEVELOP" "$RETRO" "$WAITING" "$TROUBLE" \
    | grep -oE '`[a-z]+(-[a-z]+)*`' | tr -d '`' \
    | grep -xE 'builder|analyst|technical-writer|investigator|[a-z]+-reviewer' | sort -u)
  for want in builder code-reviewer design-reviewer document-reviewer incident-reviewer; do
    grep -qxF -- "$want" <<<"$names" || { echo "not found in the texts: $want"; return 1; }
  done
  spec=$(sect "$README" '## Specialists (`agents/`)')
  for n in $names; do
    [ -f "$ROOT/agents/$n.md" ] || { echo "no agents/$n.md"; return 1; }
    c=$(grep -cE "^\| \`$n\` \|" <<<"$spec")
    [ "$c" -eq 1 ] || { echo "README rows for $n: $c"; return 1; }
  done
}

# --- criterion 12: the README documents the phase pairs --------------------------------

@test "the README has Phase skills and their pairs under Specialists, naming the five skills" {
  [ "$(grep -cxF '### Phase skills and their pairs' "$README")" -eq 1 ]
  spec=$(sect "$README" '## Specialists (`agents/`)')
  has "$spec" '### Phase skills and their pairs'
  s=$(sect "$README" '### Phase skills and their pairs')
  [ -n "$s" ]
  for k in design develop retro waiting troubleshoot; do
    c=$(grep -cE "^\| \`$k\` " <<<"$s")
    [ "$c" -eq 1 ] || { echo "rows for $k: $c"; return 1; }
  done
}
