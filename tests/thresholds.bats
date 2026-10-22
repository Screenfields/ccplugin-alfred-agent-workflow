#!/usr/bin/env bats
# config/thresholds.json and bin/alfred-config (ccplugin#127): thresholds are
# read by name; the new texts name them and never carry a literal number.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  CFG="$ROOT/bin/alfred-config"
  unset ALFRED_THRESHOLDS
  # The new texts: the agreement and the routed rules (the 12 old rules in
  # rules/ are out of scope, they contain digits such as "mode-600").
  TEXTS=("$ROOT/agreement/lead.md" "$ROOT"/rules/routed/*.md)
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

@test "the loop-check names resolve" {
  for n in ready-state workable-states loop-check-enabled loop-check-timeout-seconds loop-check-deadline-seconds \
           chase-interval-minutes chase-max-tries loop-check-max-blocks-per-hour; do
    run "$CFG" get "$n"
    [ "$status" -eq 0 ] || { echo "no $n"; return 1; }
  done
  [ "$("$CFG" get workable-states | jq -r length)" = "5" ]
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
