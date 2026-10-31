#!/usr/bin/env bats
# config/thresholds.json and bin/alfred-config (ccplugin#127): thresholds are
# read by name; the new texts name them and never carry a literal number.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  CFG="$ROOT/bin/alfred-config"
  unset ALFRED_THRESHOLDS
  # The new texts: the agreement and the routed rules (the 12 old rules in
  # rules/ are out of scope, they contain digits such as "mode-600"), and the
  # refine skill (ccplugin#155).
  TEXTS=("$ROOT/agreement/lead.md" "$ROOT"/rules/routed/*.md "$ROOT/skills/refine/SKILL.md")
}

# literals_in <file> — digits or % left after removing the allowed references
# (AP-ADRnnnn, AP-nnnn, AP#nnnn, doctrine NN). The frontmatter is not text.
literals_in() {
  awk '/^---$/ && !seen {inside = !inside; if (!inside) seen = 1; next} !inside' "$1" \
    | sed -E 's/AP-ADR[0-9]{4}//g; s/AP-[0-9]+//g; s/AP#[0-9]+//g; s/[Dd]octrines? [0-9]+//g' \
    | grep -nE '[0-9%]' || true
}

# names_in <file> — threshold-looking names used in a text.
names_in() {
  grep -oE '\b[a-z]+(-[a-z]+)*-(pct|limit|max|minutes|days|min|label)\b' "$1" | sort -u
}

@test "the appendix C names all resolve, with their start values" {
  [ "$("$CFG" get overrun-pct)" = "50" ]
  [ "$("$CFG" get wip-limit)" = "2" ]
  [ "$("$CFG" get worker-limit)" = "4" ]
  [ "$("$CFG" get failed-review-max)" = "2" ]
  [ "$("$CFG" get recovery-inform-minutes)" = "30" ]
  [ "$("$CFG" get unread-flag-minutes)" = "30" ]
  [ "$("$CFG" get inactive-flag-days)" = "7" ]
  [ "$("$CFG" get several-leads-min)" = "2" ]
  [ "$("$CFG" get model-setting-per-role | jq -r .builder.tier)" = "medium" ]
  [ "$("$CFG" get model-setting-per-role | jq -r '.["incident-reviewer"].effort')" = "highest" ]
}

@test "the status name resolves (AC 9)" {
  [ "$("$CFG" get waiting-label)" = "status:waiting-on-owner" ]
}

@test "parked-labels resolves" {
  "$CFG" get parked-labels | jq -e 'index("status:waiting-on-peer") and index("status:waiting-on-owner")'
  [ "$("$CFG" get waiting-label)" = "status:waiting-on-owner" ]
}

@test "the loop-check names resolve" {
  for n in ready-state workable-states loop-check-enabled loop-check-timeout-seconds loop-check-deadline-seconds \
           chase-interval-minutes chase-max-tries loop-check-max-blocks-per-hour parked-labels owner-note-max-age-minutes; do
    run "$CFG" get "$n"
    [ "$status" -eq 0 ] || { echo "no $n"; return 1; }
  done
  [ "$("$CFG" get workable-states | jq -r length)" = "5" ]
}

@test "reply-time-idle-minutes resolves to a whole number (CCW-180), start value 15" {
  run "$CFG" get reply-time-idle-minutes
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" = "15" ]
}

@test "an unknown name exits 2 and prints nothing on stdout" {
  out=$("$CFG" get no-such-threshold 2>/dev/null) && return 1
  [ -z "$out" ]
  run "$CFG" get no-such-threshold
  [ "$status" -eq 2 ]
  run "$CFG" get
  [ "$status" -eq 2 ]
  run "$CFG"
  [ "$status" -eq 2 ]
}

@test "a missing or malformed file exits 2; --file and ALFRED_THRESHOLDS override" {
  run "$CFG" get wip-limit --file "$BATS_TEST_TMPDIR/none.json"
  [ "$status" -eq 2 ]
  echo 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  run "$CFG" get wip-limit --file "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  echo '{"wip-limit": 9}' > "$BATS_TEST_TMPDIR/own.json"
  run "$CFG" get wip-limit --file "$BATS_TEST_TMPDIR/own.json"
  [ "$output" = "9" ]
  ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/own.json" run "$CFG" get wip-limit
  [ "$output" = "9" ]
}

@test "names lists every key" {
  run "$CFG" names
  [ "$status" -eq 0 ]
  [[ "$output" == *"overrun-pct"* && "$output" == *"waiting-label"* ]]
}

@test "the new texts carry no literal threshold (AC 3)" {
  for f in "${TEXTS[@]}"; do
    out=$(literals_in "$f")
    [ -z "$out" ] || { echo "$f: $out"; return 1; }
  done
}

@test "the literal check does catch a planted number and a percent sign" {
  printf -- '---\nname: x\n---\nStop after 3 rounds.\n' > "$BATS_TEST_TMPDIR/a.md"
  printf 'Stop at 50%%, see AP-ADR0022 and doctrine 10.\n' > "$BATS_TEST_TMPDIR/b.md"
  printf 'Stop at the limit, see AP-ADR0022, AP-1161, AP#5 and doctrine 10.\n' > "$BATS_TEST_TMPDIR/c.md"
  [ -n "$(literals_in "$BATS_TEST_TMPDIR/a.md")" ]
  [ -n "$(literals_in "$BATS_TEST_TMPDIR/b.md")" ]
  [ -z "$(literals_in "$BATS_TEST_TMPDIR/c.md")" ]
}

@test "every threshold name used in the new texts resolves in the config (AC 3)" {
  seen=0
  for f in "${TEXTS[@]}"; do
    for n in $(names_in "$f"); do
      "$CFG" get "$n" >/dev/null || { echo "$f: $n does not resolve"; return 1; }
      seen=$((seen + 1))
    done
  done
  [ "$seen" -ge 6 ]
}

@test "the agreement and the pairs rule name the thresholds they depend on" {
  for n in overrun-pct wip-limit worker-limit failed-review-max waiting-label; do
    grep -q "\b$n\b" "$ROOT/agreement/lead.md" || { echo "agreement lacks $n"; return 1; }
  done
  grep -q 'failed-review-max' "$ROOT/rules/routed/work-and-review-in-pairs.md"
}

@test "the waiting walkthrough reads the status name from the config and records the decision (AC 9)" {
  f="$ROOT/commands/waiting.md"
  grep -q 'alfred-config get waiting-label' "$f"
  grep -q -- '--remove-label' "$f"
  grep -q 'post the decision as a comment' "$f"
  grep -q 'action:jochem' "$f"
  grep -q 'alfred-config get' "$f"
  grep -q -- '--add-label "<ready-state>"' "$f"
  grep -q 'no label from `workable-states`' "$f"
}

@test "model-setting-per-role holds reviewer-light with tier medium and effort medium (ccplugin#129)" {
  s=$("$CFG" get model-setting-per-role)
  [ "$(jq -r 'has("reviewer-light")' <<<"$s")" = "true" ]
  [ "$(jq -r '.["reviewer-light"].tier' <<<"$s")" = "medium" ]
  [ "$(jq -r '.["reviewer-light"].effort' <<<"$s")" = "medium" ]
  # next to the existing reviewer setting, which is unchanged
  [ "$(jq -r '.reviewer.tier' <<<"$s")" = "medium" ]
  [ "$(jq -r '.reviewer.effort' <<<"$s")" = "high" ]
}

@test "model-setting-per-role holds the designer row, strong and high (ccplugin#158)" {
  s=$("$CFG" get model-setting-per-role)
  [ "$(jq -c '.designer' <<<"$s")" = '{"tier":"strong","effort":"high"}' ]
}

@test "designer-enabled is a boolean switch, false by default (ccplugin#158)" {
  run "$CFG" get designer-enabled
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
  [ "$(jq -r '.["designer-enabled"] | type' "$ROOT/config/thresholds.json")" = boolean ]
}

@test "the designer and its skill carry no percent sign and name only thresholds that resolve (ccplugin#158)" {
  for f in "$ROOT/agents/designer.md" "$ROOT/skills/platform-design-basis/SKILL.md"; do
    if grep -q '%' "$f"; then echo "percent sign in $f"; return 1; fi
    for n in $(names_in "$f"); do
      "$CFG" get "$n" >/dev/null || { echo "$f: $n does not resolve"; return 1; }
    done
  done
  grep -q 'failed-review-max' "$ROOT/skills/platform-design-basis/SKILL.md"
}

@test "reply-time-tolerance-minutes resolves to 2 and is a number (CCW-184)" {
  run "$CFG" get reply-time-tolerance-minutes
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  [ "$(jq -r '.["reply-time-tolerance-minutes"] | type' "$ROOT/config/thresholds.json")" = number ]
}
