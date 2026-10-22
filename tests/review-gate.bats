#!/usr/bin/env bats
# Behaviour tests for the review gate (CCW-145, AP-1230): bin/alfred-review and the
# skill and agent text that calls it. GitHub is replaced by tests/stub/gh-review
# (served as both `gh` and `gh-as`; it logs every call to $STUB_DIR/calls.log);
# fixtures are in tests/fixtures/review/, named after the probe steps S0 to S5 of the
# issue (S1 approved, S2 stale approval, S4 build push, S5 approver is last pusher).
# No network, no real token: a fake token is planted and must never be printed.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  AR="$ROOT/bin/alfred-review"
  FIX="$BATS_TEST_DIRNAME/fixtures/review"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  export ALFRED_SECRETS_DIR="$BATS_TEST_TMPDIR/secrets"
  export ALFRED_REVIEW_BACKOFF=0
  export ALFRED_REVIEW_TIMEOUT=1
  unset GH_TOKEN
  TOKEN="ghs_FAKEPLANTEDTOKEN0123456789abcdef"
  LOGF="$CLAUDE_CONFIG_DIR/alfred-review/runs.jsonl"
  SHA=87a4f59000000000000000000000000000000001
  REF="acme/widget#7"
  mkdir -p "$STUB_DIR" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/work/.alfred" "$ALFRED_SECRETS_DIR/gh-review"
  printf '%s' "$TOKEN" > "$ALFRED_SECRETS_DIR/gh-review/token"
  ln -s "$BATS_TEST_DIRNAME/stub/gh-review" "$BATS_TEST_TMPDIR/bin/gh"
  ln -s "$BATS_TEST_DIRNAME/stub/gh-review" "$BATS_TEST_TMPDIR/bin/gh-as"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  cp "$FIX/pull.json" "$STUB_DIR/pull.json"
  cp "$FIX/graphql-S1-approved.json" "$STUB_DIR/graphql.json"
  cp "$FIX/reviews-page1.json" "$STUB_DIR/reviews-page1.json"
  cp "$FIX/reviews-page2.json" "$STUB_DIR/reviews-page2.json"
  echo '{"agent_id": "lead-a"}' > "$BATS_TEST_TMPDIR/work/.alfred/config.json"
  printf 'Blocker: none.\nWarning: the retry is unbounded.\n' > "$BATS_TEST_TMPDIR/body.md"
  cd "$BATS_TEST_TMPDIR/work" || return 1
}

# --- helpers -----------------------------------------------------------------

post() { "$AR" post "$REF" --sha "$SHA" --verdict "${1:-approve}" --body-file "${2:-$BATS_TEST_TMPDIR/body.md}"; }
calls() { cat "$STUB_DIR/calls.log" 2>/dev/null; }
ncalls() { calls | wc -l | tr -d ' '; }
count_of() { cat "$STUB_DIR/$1" 2>/dev/null || echo 0; }
no_reviews() { echo '[]' > "$STUB_DIR/reviews-page1.json"; rm -f "$STUB_DIR/reviews-page2.json"; }
# gql <decision-json> <merge-state> [author] [file]: write the GraphQL verdict
gql() {
  printf '{"data":{"repository":{"pullRequest":{"reviewDecision":%s,"headRefOid":"%s","mergeStateStatus":"%s","author":{"login":"%s"}}}}}\n' \
    "$1" "$SHA" "$2" "${3:-alfred-lead-agent}" > "${4:-$STUB_DIR/graphql.json}"
}
# review <id> <login> <state> <agent|-> [file]: append one review to a list
review() {
  local f="${5:-$STUB_DIR/reviews-page1.json}" body="findings"
  [ "$4" != "-" ] && body="Reviewed by: $4 (alfred-agent:review)\n\nfindings"
  jq -c --argjson id "$1" --arg l "$2" --arg s "$3" --arg b "$(printf "$body")" --arg sha "$SHA" \
    '. + [{id: $id, user: {login: $l}, state: $s, commit_id: $sha, body: $b}]' "$f" > "$f.new" && mv "$f.new" "$f"
}
BOT='alfred-worker-agent[bot]'

# =============================================================================
# post: criteria 1 to 4, 16, 24
# =============================================================================

@test "post sends commit_id, event and prefixed body" {
  run post approve
  [ "$status" -eq 0 ]
  run jq -r '.commit_id' "$STUB_DIR/post-body.json"; [ "$output" = "$SHA" ]
  run jq -r '.event' "$STUB_DIR/post-body.json"; [ "$output" = APPROVE ]
  run jq -r '.body' "$STUB_DIR/post-body.json"
  [[ "${lines[0]}" == "Reviewed by: lead-a (alfred-agent:review)" ]]
  [[ "$output" == *"Warning: the retry is unbounded."* ]]
  rm "$STUB_DIR/post-body.json"
  run post request-changes
  [ "$status" -eq 0 ]
  run jq -r '.event' "$STUB_DIR/post-body.json"; [ "$output" = REQUEST_CHANGES ]
}

@test "post names an unknown agent when the config has none" {
  echo '{}' > "$BATS_TEST_TMPDIR/work/.alfred/config.json"
  run post approve
  [ "$status" -eq 0 ]
  run jq -r '.body' "$STUB_DIR/post-body.json"
  [[ "${lines[0]}" == "Reviewed by: unknown (alfred-agent:review)" ]]
}

@test "post uses the post response and does no read-back" {
  echo '{"id": 4242, "state": "APPROVED", "commit_id": "'$SHA'"}' > "$STUB_DIR/post-response.json"
  run post approve
  [ "$status" -eq 0 ]
  [ "$output" = "posted review 4242 APPROVED at $SHA" ]
  # exactly two calls: the head read and the POST; no GET of the reviews afterwards
  [ "$(ncalls)" -eq 2 ]
  [ "$(calls | grep -c -- '-X POST')" -eq 1 ]
  ! calls | grep -q 'paginate'
}

@test "post refuses a response that is not at the reviewed sha" {
  echo '{"id": 4242, "state": "APPROVED", "commit_id": "ffffffffffffffffffffffffffffffffffffffff"}' > "$STUB_DIR/post-response.json"
  run post approve
  [ "$status" -eq 6 ]
}

@test "post uses gh-as review for every call" {
  run post approve
  [ "$status" -eq 0 ]
  [ "$(ncalls)" -ge 2 ]
  [ "$(calls | grep -vc '^gh-as review ')" -eq 0 ]
}

@test "post refuses with exit 2 when GH_TOKEN is set" {
  GH_TOKEN=ghs_something run post approve
  [ "$status" -eq 2 ]
  [[ "$output" == *"GH_TOKEN is set"* ]]
  [ "$(ncalls)" -eq 0 ]
}

@test "post refuses when head moved" {
  echo '{"head": {"sha": "ffffffffffffffffffffffffffffffffffffffff"}}' > "$STUB_DIR/pull.json"
  run post approve
  [ "$status" -eq 3 ]
  [[ "$output" == *"head moved: reviewed $SHA, now ffffffffffffffffffffffffffffffffffffffff; review again"* ]]
  [ ! -e "$STUB_DIR/post-body.json" ]
  [ "$(count_of post.count)" -eq 0 ]
}

@test "argument errors exit 2" {
  b="$BATS_TEST_TMPDIR/body.md"; : > "$BATS_TEST_TMPDIR/empty.md"
  run "$AR" post "acme/widget" --sha "$SHA" --verdict approve --body-file "$b"; [ "$status" -eq 2 ]
  run "$AR" post "acme/widget#0" --sha "$SHA" --verdict approve --body-file "$b"; [ "$status" -eq 2 ]
  run "$AR" post "$REF" --sha abc123 --verdict approve --body-file "$b"; [ "$status" -eq 2 ]
  run "$AR" post "$REF" --sha "${SHA^^}" --verdict approve --body-file "$b"; [ "$status" -eq 2 ]
  run "$AR" post "$REF" --sha "$SHA" --verdict comment --body-file "$b"; [ "$status" -eq 2 ]
  run "$AR" post "$REF" --sha "$SHA" --verdict approve; [ "$status" -eq 2 ]
  run "$AR" post "$REF" --sha "$SHA" --verdict approve --body-file "$BATS_TEST_TMPDIR/missing.md"; [ "$status" -eq 2 ]
  run "$AR" post "$REF" --sha "$SHA" --verdict approve --body-file "$BATS_TEST_TMPDIR/empty.md"; [ "$status" -eq 2 ]
  run "$AR" post "$REF" --sha "$SHA" --verdict request-changes --body-file "$BATS_TEST_TMPDIR/empty.md"; [ "$status" -eq 2 ]
  run "$AR" post "$REF" --sha "$SHA" --verdict approve --body-file "$b" --extra x; [ "$status" -eq 2 ]
  run "$AR" check "acme/widget"; [ "$status" -eq 2 ]
  run "$AR" check; [ "$status" -eq 2 ]
  run "$AR" bogus; [ "$status" -eq 2 ]
  # nothing was posted and no GitHub call was made
  [ "$(ncalls)" -eq 0 ]
}

@test "GH_TOKEN set exits 2" {
  GH_TOKEN=ghs_something run post approve
  [ "$status" -eq 2 ]
  [ "$(ncalls)" -eq 0 ]
}

@test "no token file exits 4" {
  rm "$ALFRED_SECRETS_DIR/gh-review/token"
  run post approve
  [ "$status" -eq 4 ]
  [[ "$output" == *"no review token on this devbox"* ]]
  [ "$(ncalls)" -eq 0 ]
  : > "$ALFRED_SECRETS_DIR/gh-review/token"
  run post approve
  [ "$status" -eq 4 ]
  [ "$(ncalls)" -eq 0 ]
}

@test "404 exits 5 with the widen ask" {
  echo 404 > "$STUB_DIR/fail-pull"
  run post approve
  [ "$status" -eq 5 ]
  [[ "$output" == *"the review token has no access to acme/widget"* ]]
  [[ "$output" == *"[review-access] lead-a -> acme/widget"* ]]
  [[ "$output" == *"ESO refresh"* ]]
  [[ "$output" == *"never build"* ]]
  [ "$(count_of fail-pull.count)" -eq 1 ]
  [ ! -e "$STUB_DIR/post-body.json" ]
}

@test "403 on the POST exits 5 with the widen ask and not 4" {
  echo 403 > "$STUB_DIR/fail-post"
  run post approve
  [ "$status" -eq 5 ]
  [[ "$output" == *"[review-access] lead-a -> acme/widget"* ]]
  [[ "$output" != *"no review token on this devbox"* ]]
  echo 403 > "$STUB_DIR/fail-pull"; rm "$STUB_DIR/fail-post"
  run post approve
  [ "$status" -eq 5 ]
}

@test "422 exits 6" {
  echo 422 > "$STUB_DIR/fail-post"
  run post approve
  [ "$status" -eq 6 ]
  [[ "$output" == *"Validation Failed: custom"* ]]
  [ "$(count_of fail-post.count)" -eq 1 ]
  echo 401 > "$STUB_DIR/fail-pull"; rm "$STUB_DIR/fail-post"
  run post approve
  [ "$status" -eq 6 ]
  [ "$(count_of fail-pull.count)" -eq 1 ]
}

@test "no output contains the token" {
  all=""
  for scen in "pull 404" "post 403" "post 422" "pull 401" "pull 502"; do
    set -- $scen
    rm -f "$STUB_DIR"/fail-* "$STUB_DIR"/fail-*.count
    echo "$2" > "$STUB_DIR/fail-$1"
    run post approve
    all+="$output"
  done
  run post approve; all+="$output"
  rm -f "$STUB_DIR"/fail-*
  run "$AR" check "$REF"; all+="$output"
  [[ "$all" != *"$TOKEN"* ]]
  [[ "$all" != *"FAKEPLANTED"* ]]
  ! grep -q "FAKEPLANTED" "$LOGF"
  [ -s "$LOGF" ]
}

@test "no reference to gh-readonly" {
  ! grep -q 'gh-readonly' "$AR"
  ! grep -q 'gh-token' "$AR"
}

@test "post without review token exits 4 and calls nothing" {
  rm "$ALFRED_SECRETS_DIR/gh-review/token"
  run post approve
  [ "$status" -eq 4 ]
  [ "$(ncalls)" -eq 0 ]
}

@test "post with only gh-readonly present exits 4" {
  rm "$ALFRED_SECRETS_DIR/gh-review/token"
  mkdir -p "$ALFRED_SECRETS_DIR/gh-readonly" "$ALFRED_SECRETS_DIR/gh-token"
  echo ghs_readonly > "$ALFRED_SECRETS_DIR/gh-readonly/token"; echo ghs_other > "$ALFRED_SECRETS_DIR/gh-token/token"
  rm "$BATS_TEST_TMPDIR/bin/gh-as"
  ln -s "$BATS_TEST_DIRNAME/stub/gh-as-fallback" "$BATS_TEST_TMPDIR/bin/gh-as"
  run post approve
  [ "$status" -eq 4 ]
  [[ "$output" == *"no review token on this devbox"* ]]
  # the fallback stub was never called, and neither was the gh stub
  [ "$(ncalls)" -eq 0 ]
}

@test "flow script continues without a post when no review is required" {
  rm "$ALFRED_SECRETS_DIR/gh-review/token"
  gql null CLEAN; no_reviews
  run "$BATS_TEST_DIRNAME/stub/review-flow" "$REF" "$SHA" approve "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [[ "$output" == "continue: "* ]]
  [ ! -e "$STUB_DIR/post-body.json" ]
}

@test "flow script stops when a review is required and there is no token" {
  rm "$ALFRED_SECRETS_DIR/gh-review/token"
  cp "$FIX/graphql-S0-review-required.json" "$STUB_DIR/graphql.json"
  run "$BATS_TEST_DIRNAME/stub/review-flow" "$REF" "$SHA" approve "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stop: no review token on this devbox, and a review is required on acme/widget: ask the hub"* ]]
}

@test "flow script passes the widen ask on exit 5 and does not call it no token" {
  echo 404 > "$STUB_DIR/fail-pull"
  run "$BATS_TEST_DIRNAME/stub/review-flow" "$REF" "$SHA" approve "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[review-access]"* ]]
  [[ "$output" != *"no review token on this devbox"* ]]
}

@test "flow script posts when the token is there" {
  run "$BATS_TEST_DIRNAME/stub/review-flow" "$REF" "$SHA" approve "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [[ "$output" == "posted: posted review "* ]]
}

@test "body over limit is truncated with a note" {
  head -c 70000 /dev/zero | tr '\0' 'a' > "$BATS_TEST_TMPDIR/big.md"
  run --separate-stderr post approve "$BATS_TEST_TMPDIR/big.md"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"characters were cut"* ]]
  [ "$(jq -r '.body | length' "$STUB_DIR/post-body.json")" -eq 65000 ]
  note=$(jq -r '.body' "$STUB_DIR/post-body.json" | tail -n 1)
  [[ "$note" =~ ^\[truncated\ by\ alfred-review:\ ([0-9]+)\ characters\ omitted\]$ ]]
  n="${BASH_REMATCH[1]}"
  prefix=$'Reviewed by: lead-a (alfred-agent:review)\n\n'
  total=$(( ${#prefix} + 70000 ))
  # kept text + note is exactly the limit, and N is what was left out
  [ "$(( total - n + ${#note} + 2 ))" -eq 65000 ]
  [ "$(jq -r .event "$STUB_DIR/post-body.json")" = APPROVE ]
}

@test "body at limit is unchanged" {
  prefix=$'Reviewed by: lead-a (alfred-agent:review)\n\n'
  head -c $(( 65000 - ${#prefix} )) /dev/zero | tr '\0' 'b' > "$BATS_TEST_TMPDIR/edge.md"
  run --separate-stderr post approve "$BATS_TEST_TMPDIR/edge.md"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq -r '.body | length' "$STUB_DIR/post-body.json")" -eq 65000 ]
  [[ "$(jq -r .body "$STUB_DIR/post-body.json")" != *truncated* ]]
}

@test "multibyte body counts characters" {
  # 40000 two-byte characters: 80000 bytes, but under the limit in characters
  yes é | head -n 40000 | tr -d '\n' > "$BATS_TEST_TMPDIR/mb.md"
  run --separate-stderr post approve "$BATS_TEST_TMPDIR/mb.md"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  prefix=$'Reviewed by: lead-a (alfred-agent:review)\n\n'
  [ "$(jq -r '.body | length' "$STUB_DIR/post-body.json")" -eq $(( 40000 + ${#prefix} )) ]
  # 66000 of them are over the limit and are cut to 65000 characters
  yes é | head -n 66000 | tr -d '\n' > "$BATS_TEST_TMPDIR/mb2.md"
  rm "$STUB_DIR/post-body.json"
  run --separate-stderr post approve "$BATS_TEST_TMPDIR/mb2.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.body | length' "$STUB_DIR/post-body.json")" -eq 65000 ]
}

# =============================================================================
# retries: criterion 6
# =============================================================================

@test "retries then succeeds" {
  echo "502 2" > "$STUB_DIR/fail-graphql"
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: approved"* ]]
  [ "$(count_of fail-graphql.count)" -eq 3 ]
  rm "$STUB_DIR/fail-graphql" "$STUB_DIR/fail-graphql.count"
  echo "403-rate 1" > "$STUB_DIR/fail-graphql"
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
  rm "$STUB_DIR/fail-graphql" "$STUB_DIR/fail-graphql.count"
  echo "timeout 1" > "$STUB_DIR/fail-graphql"
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
}

@test "gives up after 3 retries with exit 6" {
  echo "502" > "$STUB_DIR/fail-graphql"
  run "$AR" check "$REF"
  [ "$status" -eq 6 ]
  [[ "$output" == *"after 3 retries"* ]]
  [ "$(count_of fail-graphql.count)" -eq 4 ]
  echo "502" > "$STUB_DIR/fail-pull"
  run post approve
  [ "$status" -eq 6 ]
  [ "$(count_of fail-pull.count)" -eq 4 ]
  [ ! -e "$STUB_DIR/post-body.json" ]
}

@test "does not retry a 404" {
  echo 404 > "$STUB_DIR/fail-graphql"
  run "$AR" check "$REF"
  [ "$status" -eq 5 ]
  [ "$(count_of fail-graphql.count)" -eq 1 ]
}

@test "fails closed on garbage json" {
  echo '<html>not json</html>' > "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "$status" -eq 6 ]
  echo '{"data": {"repository": {"pullRequest": {"reviewDecision": "APPROVED"}}}}' > "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "$status" -eq 6 ]
  echo 'garbage' > "$STUB_DIR/pull.json"
  run post approve
  [ "$status" -eq 6 ]
  [ ! -e "$STUB_DIR/post-body.json" ]
}

@test "post timeout does not double-post" {
  rm "$STUB_DIR"/reviews-page*.json
  echo "timeout-after-record 1" > "$STUB_DIR/fail-post"
  run post approve
  [ "$status" -eq 0 ]
  [ "$output" = "posted review 9001 APPROVED at $SHA" ]
  [ "$(count_of post.count)" -eq 1 ]
}

@test "post timeout without a record retries the post" {
  rm "$STUB_DIR"/reviews-page*.json
  echo "timeout 1" > "$STUB_DIR/fail-post"
  run post approve
  [ "$status" -eq 0 ]
  [ "$(count_of post.count)" -eq 2 ]
}

@test "post gives up when it cannot tell whether the review landed" {
  echo "502" > "$STUB_DIR/fail-post"
  echo "502" > "$STUB_DIR/fail-reviews"
  run post approve
  [ "$status" -eq 6 ]
  [ "$(count_of post.count)" -eq 1 ]
}

# =============================================================================
# check: criteria 5, 7, 15, 18, 20, 21, 22
# =============================================================================

@test "check maps null" {
  gql null CLEAN; no_reviews
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: not-required"* ]]
  [[ "$output" == *"github-verdict: none"* ]]
  [[ "$output" == *"approval not required by this repo's rules"* ]]
}

@test "check maps APPROVED (probe S1)" {
  cp "$FIX/graphql-S1-approved.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: approved"* ]]
  [[ "$output" == *"head: $SHA"* ]]
  [[ "$output" == *"approved at $SHA"* ]]
}

@test "check maps CHANGES_REQUESTED" {
  cp "$FIX/graphql-changes-requested.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "$status" -eq 11 ]
  [[ "$output" == *"decision: changes-requested"* ]]
  [[ "$output" == *"review 305 by $BOT"* ]]
  [[ "$output" == *"Reviewed by: lead-b (alfred-agent:review)"* ]]
  [[ "$output" != *"review 302"* ]]
}

@test "check maps REVIEW_REQUIRED (probe S0)" {
  cp "$FIX/graphql-S0-review-required.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "$status" -eq 10 ]
  [[ "$output" == *"decision: review-required"* ]]
  [[ "$output" == *"github-verdict: REVIEW_REQUIRED"* ]]
  [[ "$output" == *"Likely reasons"* ]]
}

@test "null with a change request exits 11" {
  gql null CLEAN
  run "$AR" check "$REF"
  [ "$status" -eq 11 ]
  [[ "$output" == *"github-verdict: none"* ]]
  [[ "$output" == *"plugin-policy: change-request-blocks"* ]]
  [[ "$output" == *"GitHub does not require a review here; the plugin blocks because a reviewer requested changes"* ]]
}

@test "null with a change request by another login exits 11" {
  gql null CLEAN; no_reviews
  review 20 some-human CHANGES_REQUESTED -
  run "$AR" check "$REF"
  [ "$status" -eq 11 ]
  [[ "$output" == *"by some-human"* ]]
}

@test "null with a dismissed change request exits 0" {
  gql null CLEAN; no_reviews
  review 20 "$BOT" DISMISSED lead-b
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: not-required"* ]]
}

@test "null with a later approve by the same login exits 0" {
  gql null CLEAN; no_reviews
  review 20 "$BOT" CHANGES_REQUESTED lead-b
  review 21 "$BOT" APPROVED lead-b
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"approval not required by this repo's rules"* ]]
}

@test "unexpected value fails closed with 6" {
  gql '"SOMETHING_NEW"' CLEAN
  run "$AR" check "$REF"
  [ "$status" -eq 6 ]
  [[ "$output" == *"decision: error"* ]]
}

@test "reviews are read across pages ordered by id" {
  cp "$FIX/graphql-changes-requested.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  # review 305 is on page 1, the older approval 302 on page 2: the latest by id wins
  [ "$status" -eq 11 ]
  calls | grep -q -- '--paginate'
  # a third page is read too
  echo '[]' > "$STUB_DIR/reviews-page3.json"
  review 310 "$BOT" APPROVED lead-b "$STUB_DIR/reviews-page3.json"
  gql null CLEAN
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
}

@test "output separates github-verdict and plugin-policy" {
  cp "$FIX/graphql-S1-approved.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "${lines[0]}" = "decision: approved" ]
  [ "${lines[1]}" = "github-verdict: APPROVED" ]
  [ "${lines[2]}" = "plugin-policy: ok" ]
  [ "${lines[3]}" = "head: $SHA" ]
  [ "${lines[4]}" = "merge-state: CLEAN" ]
}

@test "check reads only the graphql verdict and reviews" {
  gql null CLEAN
  run "$AR" check "$REF"
  ! calls | grep -q 'rules/branches'
  ! calls | grep -q 'events'
  ! calls | grep -q -- '-X POST'
  [ "$(calls | grep -vc -E 'api graphql|/pulls/7/reviews')" -eq 0 ]
}

@test "check works without a review token" {
  rm -rf "$ALFRED_SECRETS_DIR/gh-review"
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
}

@test "check does not call gh-as" {
  gql null CLEAN
  run "$AR" check "$REF"
  [ "$(ncalls)" -ge 1 ]
  [ "$(calls | grep -c '^gh-as')" -eq 0 ]
  [ "$(calls | grep -vc '^gh ')" -eq 0 ]
}

@test "check on unreadable pr exits 5" {
  cp "$FIX/graphql-not-found.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "$status" -eq 5 ]
  [[ "$output" == *"no read access to acme/widget#7"* ]]
  rm "$STUB_DIR/graphql.json"; echo 403 > "$STUB_DIR/fail-graphql"
  run "$AR" check "$REF"
  [ "$status" -eq 5 ]
}

@test "check names who must act on a change request" {
  cp "$FIX/graphql-changes-requested.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "$status" -eq 11 ]
  [[ "$output" == *"review 305"* ]]
  [[ "$output" == *"Reviewed by: lead-b (alfred-agent:review)"* ]]
  [[ "$output" == *"changes were requested at ${SHA:0:12}"* ]]
  [[ "$output" == *"re-review at $SHA"* ]]
  [[ "$output" == *"ask the hub, which dismisses the review with a written reason"* ]]
}

@test "a later approve by the same login is not listed" {
  cp "$FIX/graphql-changes-requested.json" "$STUB_DIR/graphql.json"
  review 310 "$BOT" APPROVED lead-a
  run "$AR" check "$REF"
  [ "$status" -eq 11 ]
  [[ "$output" != *"review 305"* ]]
  [[ "$output" == *"GitHub reports changes requested"* ]]
}

@test "no dismissals call" {
  cp "$FIX/graphql-changes-requested.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  run post request-changes
  ! calls | grep -q 'dismissals'
  ! grep -rqi 'dismissals' "$AR" "$ROOT/skills" "$ROOT/agents" "$ROOT/commands"
}

@test "unknown merge state is retried" {
  gql '"APPROVED"' UNKNOWN "" "$STUB_DIR/graphql.1.json"
  gql '"APPROVED"' CLEAN "" "$STUB_DIR/graphql.2.json"
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [ "$(count_of graphql.count)" -eq 2 ]
  [[ "$output" != *"still UNKNOWN"* ]]
  [[ "$output" == *"merge-state: CLEAN"* ]]
}

@test "unknown merge state persists and verdict stands" {
  gql '"APPROVED"' UNKNOWN
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [ "$(count_of graphql.count)" -eq 4 ]
  [[ "$output" == *"merge state still UNKNOWN"* ]]
  cp "$FIX/graphql-S2-stale-unknown.json" "$STUB_DIR/graphql.json"; rm "$STUB_DIR/graphql.count"
  run "$AR" check "$REF"
  [ "$status" -eq 10 ]
  [[ "$output" == *"merge state still UNKNOWN"* ]]
  cp "$FIX/graphql-S4-build-push-unknown.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "$status" -eq 10 ]
}

@test "approved and blocked exits 10" {
  gql '"APPROVED"' BLOCKED
  run "$AR" check "$REF"
  [ "$status" -eq 10 ]
  [[ "$output" == *"decision: blocked"* ]]
  [[ "$output" == *"plugin-policy: merge-state-blocked"* ]]
  [[ "$output" == *"another rule is unmet"* ]]
}

@test "approved and clean exits 0" {
  cp "$FIX/graphql-S1-approved.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [[ "$output" != *"another rule"* ]]
}

@test "behind is informational with guidance" {
  gql '"APPROVED"' BEHIND
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the branch is behind its base; updating it is a push, so make it with the lead role and re-review"* ]]
}

@test "dirty is informational with guidance" {
  gql '"APPROVED"' DIRTY
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge conflicts; resolve them, push with the lead role, and re-review"* ]]
}

@test "draft has hooks unstable are informational" {
  for ms in DRAFT HAS_HOOKS UNSTABLE; do
    gql '"APPROVED"' $ms
    run "$AR" check "$REF"
    [ "$status" -eq 0 ]
    [[ "$output" == *"merge-state: $ms"* ]]
  done
  gql '"APPROVED"' DRAFT
  run "$AR" check "$REF"
  [[ "$output" == *"the PR is a draft; mark it ready"* ]]
}

@test "blocked with another decision is informational" {
  gql null BLOCKED; no_reviews
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
}

@test "unexpected merge state exits 6" {
  gql '"APPROVED"' SOMETHING_NEW
  run "$AR" check "$REF"
  [ "$status" -eq 6 ]
}

@test "query includes author" {
  run "$AR" check "$REF"
  calls | grep -q 'author { login }'
  calls | grep -q 'reviewDecision headRefOid mergeStateStatus'
}

@test "author is the review identity gives the author message" {
  cp "$FIX/graphql-author-review-identity.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "$status" -eq 10 ]
  [[ "$output" == *"PR author is the review identity: recreate the PR with the lead role"* ]]
  [[ "$output" != *"Likely reasons"* ]]
}

@test "check names the author case for certain" {
  cp "$FIX/graphql-author-review-identity.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [[ "$output" == *"GitHub forbids self-approval"* ]]
  [[ "$output" != *"may be"* ]]
}

@test "other author gives the likely reasons" {
  cp "$FIX/graphql-S5-approved-by-last-pusher.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [ "$status" -eq 10 ]
  [[ "$output" == *"Likely reasons"* ]]
  [[ "$output" != *"PR author is the review identity"* ]]
}

@test "check words the last pusher as likely" {
  cp "$FIX/graphql-S4-build-push-unknown.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"
  [[ "$output" == *"the last pusher may be the review identity (push the final commit with the lead role)"* ]]
  ! calls | grep -q 'events'
}

@test "warns when a different agent supersedes a change request" {
  cp "$FIX/graphql-S1-approved.json" "$STUB_DIR/graphql.json"; no_reviews
  review 10 "$BOT" CHANGES_REQUESTED lead-b
  review 11 "$BOT" APPROVED lead-a
  run --separate-stderr "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"the change request by lead-b was superseded by an approval by lead-a: same GitHub login, confirm with lead-b"* ]]
  [ "$(tail -n 1 "$LOGF" | jq -r .warning)" = shared-login ]
}

@test "no warning when the same agent re-reviews" {
  cp "$FIX/graphql-S1-approved.json" "$STUB_DIR/graphql.json"; no_reviews
  review 10 "$BOT" CHANGES_REQUESTED lead-a
  review 11 "$BOT" APPROVED lead-a
  run --separate-stderr "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(tail -n 1 "$LOGF" | jq -r .warning)" = "" ]
}

@test "warning also fires where no review is required" {
  gql null CLEAN; no_reviews
  review 10 "$BOT" CHANGES_REQUESTED lead-b
  review 11 "$BOT" APPROVED lead-a
  run --separate-stderr "$AR" check "$REF"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"superseded"* ]]
}

@test "a failing review read never changes an approved verdict" {
  cp "$FIX/graphql-S1-approved.json" "$STUB_DIR/graphql.json"
  echo 500 > "$STUB_DIR/fail-reviews"
  run "$AR" check "$REF"
  [ "$status" -eq 0 ]
}

@test "a failing review read where none is required fails closed" {
  gql null CLEAN
  echo 500 > "$STUB_DIR/fail-reviews"
  run "$AR" check "$REF"
  [ "$status" -eq 6 ]
}

@test "check has no identity branch" {
  body=$(sed -n '/^cmd_check()/,/^# --- main/p' "$AR")
  [ -n "$body" ]
  ! grep -qE 'agent_id|platform-manager|project-manager' <<<"$body"
  ! grep -qE 'platform-manager|project-manager' "$AR"
}

# =============================================================================
# the local log: criterion 17
# =============================================================================

@test "log line per run" {
  run post approve
  run "$AR" check "$REF"
  [ "$(wc -l < "$LOGF" | tr -d ' ')" -eq 2 ]
  run jq -r '[.cmd, .repo, (.pr | tostring), (.exit | tostring), .reason] | join(" ")' "$LOGF"
  [ "${lines[0]}" = "post acme/widget 7 0 ok" ]
  [ "${lines[1]}" = "check acme/widget 7 0 ok" ]
  jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' <(tail -n 1 "$LOGF")
  [ "$(tail -n 1 "$LOGF" | jq -r .decision)" = approved ]
}

@test "log reason matches the exit code for each code" {
  expect() { # <exit> <reason>
    [ "$(tail -n 1 "$LOGF" | jq -r .exit)" -eq "$1" ]
    [ "$(tail -n 1 "$LOGF" | jq -r .reason)" = "$2" ]
  }
  run "$AR" check "$REF"; [ "$status" -eq 0 ]; expect 0 ok
  run "$AR" check nonsense; [ "$status" -eq 2 ]
  [ "$(tail -n 1 "$LOGF" | jq -r .reason)" = argument ]
  run "$AR" bogus; [ "$status" -eq 2 ]
  echo '{"head": {"sha": "ffffffffffffffffffffffffffffffffffffffff"}}' > "$STUB_DIR/pull.json"
  run post approve; [ "$status" -eq 3 ]; expect 3 head-moved
  cp "$FIX/pull.json" "$STUB_DIR/pull.json"
  mv "$ALFRED_SECRETS_DIR/gh-review/token" "$BATS_TEST_TMPDIR/tok"
  run post approve; [ "$status" -eq 4 ]; expect 4 no-token
  mv "$BATS_TEST_TMPDIR/tok" "$ALFRED_SECRETS_DIR/gh-review/token"
  echo 404 > "$STUB_DIR/fail-pull"
  run post approve; [ "$status" -eq 5 ]; expect 5 access
  echo 422 > "$STUB_DIR/fail-pull"; rm "$STUB_DIR/fail-pull.count"
  run post approve; [ "$status" -eq 6 ]; expect 6 api
  rm "$STUB_DIR/fail-pull"
  cp "$FIX/graphql-S0-review-required.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"; [ "$status" -eq 10 ]; expect 10 ok
  [ "$(tail -n 1 "$LOGF" | jq -r .decision)" = review-required ]
  cp "$FIX/graphql-changes-requested.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"; [ "$status" -eq 11 ]; expect 11 ok
  jq -e 'has("ts") and has("cmd") and has("repo") and has("pr") and has("exit") and has("reason") and has("decision") and has("warning")' <(tail -n 1 "$LOGF")
}

@test "log has no token or body" {
  run post approve
  run "$AR" check "$REF"
  echo 422 > "$STUB_DIR/fail-post"
  run post approve
  ! grep -q "$TOKEN" "$LOGF"
  ! grep -q 'Warning: the retry' "$LOGF"
  ! grep -q 'Reviewed by' "$LOGF"
}

# =============================================================================
# shell hygiene: criterion 12
# =============================================================================

@test "every documented exit path is produced and matches the readme table" {
  codes=""
  add() { codes+=" $1"; }
  run "$AR" check "$REF"; add "$status"                                   # 0
  run "$AR" check bad; add "$status"                                      # 2
  echo '{"head": {"sha": "ffffffffffffffffffffffffffffffffffffffff"}}' > "$STUB_DIR/pull.json"
  run post approve; add "$status"                                         # 3
  cp "$FIX/pull.json" "$STUB_DIR/pull.json"
  mv "$ALFRED_SECRETS_DIR/gh-review/token" "$BATS_TEST_TMPDIR/tok"
  run post approve; add "$status"                                         # 4
  mv "$BATS_TEST_TMPDIR/tok" "$ALFRED_SECRETS_DIR/gh-review/token"
  echo 404 > "$STUB_DIR/fail-pull"
  run post approve; add "$status"                                         # 5
  echo 422 > "$STUB_DIR/fail-pull"; rm "$STUB_DIR/fail-pull.count"
  run post approve; add "$status"                                         # 6
  rm "$STUB_DIR/fail-pull"
  cp "$FIX/graphql-S0-review-required.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"; add "$status"                                   # 10
  cp "$FIX/graphql-changes-requested.json" "$STUB_DIR/graphql.json"
  run "$AR" check "$REF"; add "$status"                                   # 11
  got=$(printf '%s\n' $codes | sort -n | uniq | tr '\n' ' ')
  # the table in the README, between its heading and the next heading
  doc=$(sed -n '/^### Exit codes/,/^### /p' "$ROOT/README.md" | grep -oE '^\| [0-9]+ \|' | grep -oE '[0-9]+' | sort -n | uniq | tr '\n' ' ')
  [ "$got" = "0 2 3 4 5 6 10 11 " ]
  [ "$doc" = "$got" ]
}

# =============================================================================
# skills and agent text: criteria 8, 9, 10, 11, 14, 19, 20, 23 (greps; prose cannot be run)
# =============================================================================

MERGE() { echo "$ROOT/skills/merge/SKILL.md"; }
DEV() { echo "$ROOT/skills/develop/SKILL.md"; }
line_of() { grep -n -m1 -- "$1" "$2" | cut -d: -f1; }

@test "merge skill calls alfred-review check before the label gate" {
  f=$(MERGE)
  ci=$(line_of '^## Step 4 — CI gate' "$f"); rv=$(line_of '^## Step 5 — Review gate' "$f"); lb=$(line_of '^## Step 6 — Label gate' "$f")
  chk=$(line_of 'check "\$REPO#{N}"' "$f")
  [ -n "$ci" ] && [ -n "$rv" ] && [ -n "$lb" ] && [ -n "$chk" ]
  [ "$ci" -lt "$rv" ] && [ "$rv" -lt "$chk" ] && [ "$chk" -lt "$lb" ]
}

@test "merge skill stops on any non-zero exit" {
  f=$(MERGE)
  grep -q '\*\*Stop on any non-zero exit\*\*' "$f"
  for c in 10 11 5 6 2; do grep -qE "^\| $c \|" "$f"; done
  grep -q 'never work around it with `--admin`' "$f"
}

@test "merge skill passes --match-head-commit from the check" {
  f=$(MERGE)
  grep -q "sed -n 's/^head: //p'" "$f"
  grep -q 'gh pr merge {N} --squash --match-head-commit "\$HEAD"' "$f"
  [ "$(grep -c 'gh pr merge {N}' "$f")" -eq 1 ]
}

@test "merge skill refuses alfred-platform-manager" {
  f=$(MERGE)
  grep -q 'the hub merges with platform-gh, not this skill' "$f"
  grep -q 'If the identity is `alfred-platform-manager`, stop' "$f"
}

@test "merge skill does not refuse alfred-project-manager" {
  f=$(MERGE)
  # the refusal line names only the hub; project-manager is described as merging here
  grep 'the hub merges with platform-gh, not this skill' "$f" | grep -vq 'project-manager'
  grep -q '`alfred-project-manager` is a lead like the others' "$f"
  ! grep -qE 'stop.*alfred-project-manager' "$f"
}

@test "review skill posts in interactive mode only" {
  f="$ROOT/skills/review/SKILL.md"
  grep -q 'alfred-review' "$f"
  grep -q '^## Step 4 — Submit the review (interactive mode only)' "$f"
  grep -q 'Skip this step in headless mode' "$f"
  grep -q 'headRefOid' "$f"
}

@test "headless section has no post" {
  f="$ROOT/skills/review/SKILL.md"
  # everything from the headless output heading to the Step 4 heading
  sec=$(sed -n '/^### Headless mode output/,/^## Step 4/p' "$f")
  [ -n "$sec" ]
  ! grep -q 'alfred-review' <<<"$sec"
  grep -q 'headless mode never calls `alfred-review post`' "$f"
  grep -q 'Do not post the PR comment yourself in headless mode' "$f"
}

@test "review-panel posts through alfred-review at the head sha" {
  f="$ROOT/skills/review-panel/SKILL.md"
  grep -q 'alfred-review' "$f"
  grep -q '^\*\*Head SHA' "$f"
  grep -q 'Reviewed at:' "$f"
  grep -q 'Never forward raw worker text' "$f"
  ! grep -q 'Post synthesized findings as a PR review comment' "$f"
}

@test "develop calls alfred-review post and merges through the merge skill" {
  f=$(DEV)
  grep -q 'alfred-review post' "$f"
  grep -q '/alfred-agent:merge' "$f"
  ! grep -q 'gh pr merge' "$f"
}

@test "develop switches to lead before every git push" {
  f=$(DEV)
  awk_check "$f" 'git push'
}

@test "develop creates the PR with the lead role" {
  f=$(DEV)
  awk_check "$f" 'gh pr create'
  # in the multi-role Step 6 block, the role switch is the line before the push
  grep -B1 -m1 'git push -u origin' "$f" | head -1 | grep -q 'switch-role lead'
}

@test "develop review comes after the final push" {
  f=$(DEV)
  push6=$(line_of 'git push -u origin' "$f"); rev=$(line_of 'alfred-review post' "$f"); mrg=$(line_of '/alfred-agent:merge {PR}' "$f")
  [ -n "$push6" ] && [ -n "$rev" ] && [ -n "$mrg" ]
  [ "$push6" -lt "$rev" ] && [ "$rev" -lt "$mrg" ]
  grep -q 'The loop is review, fix, review again' "$f"
}

@test "develop switches to lead before the merge skill" {
  f=$(DEV)
  sec=$(sed -n '/^\*\*3\. Merge through the merge skill/,/^Then clean up/p' "$f")
  sw=$(grep -n 'switch-role lead' <<<"$sec" | head -1 | cut -d: -f1)
  mg=$(grep -n 'run `/alfred-agent:merge {PR}`' <<<"$sec" | head -1 | cut -d: -f1)
  [ -n "$sw" ] && [ -n "$mg" ] && [ "$sw" -lt "$mg" ]
}

@test "develop single-role branch has no switch-role" {
  f=$(DEV)
  # every code block under a "If single-role devbox" line
  run awk '
    /^```/ { if (inf) { inf=0 } else { inf=1; single=(prev ~ /If single-role devbox/) } next }
    { if (!inf && $0 !~ /^[[:space:]]*$/) prev=$0 }
    inf && single && /switch-role/ { print NR": "$0; bad=1 }
    END { exit bad }' "$f"
  [ "$status" -eq 0 ]
}

@test "develop old build-creates rule is gone" {
  f=$(DEV)
  ! grep -q 'never merge with the same role that created the PR' "$f"
  ! grep -q 'Build role creates, lead role merges' "$f"
}

@test "develop states the lead-pushes rule" {
  f=$(DEV)
  grep -q 'The lead role pushes, creates the PR and merges; the review identity reviews' "$f"
  grep -q 'Workers may commit with any author, but every push uses the lead role' "$f"
  grep -q 'the reviewer must differ from the PR.s author and from its last pusher' "$f"
}

@test "develop has the author case sequence" {
  f=$(DEV)
  sec=$(sed -n '/^\*\*The PR author is the review identity\*\*/,/^\*\*Only the last push/p' "$f")
  for needle in 'switch-role lead' 'gh pr close {old} --comment "Recreated as lead-authored PR"' 'git commit --allow-empty' 'git push' 'gh pr create' 'Replaces #{old}' 'gh pr comment {old}'; do
    grep -qF -- "$needle" <<<"$sec"
  done
}

@test "develop has the last-pushed case sequence" {
  f=$(DEV)
  sec=$(sed -n '/^\*\*Only the last push was made by/,/^## Rules/p' "$f")
  for needle in 'switch-role lead' 'git checkout {branch} && git pull' 'git commit --allow-empty' 'git push'; do
    grep -qF -- "$needle" <<<"$sec"
  done
  grep -q '^## PRs already in flight' "$f"
}

@test "develop says workers only commit" {
  f=$(DEV)
  grep -q 'Workers only commit, with any author' "$f"
  grep -q 'There is no bulk migration' "$f"
}

@test "code-reviewer names the reviewed sha and stays read-only" {
  f="$ROOT/agents/code-reviewer.md"
  grep -q 'Reviewed at: <sha>' "$f"
  grep -q 'Read-only by instruction' "$f"
  ! grep -q 'gh pr review' "$f"
  ! grep -q 'alfred-review post' "$f"
}

@test "review-panel has the another-lead section" {
  f="$ROOT/skills/review-panel/SKILL.md"
  grep -q '^## Review by another lead' "$f"
  grep -qF '[review-access] <reviewing-lead> -> <owner/repo>' "$f"
  grep -q 'ESO refresh' "$f"
  grep -q 'same login' "$f"
  grep -q 'the PR.s lead asks the lead who requested it to re-review' "$f"
  grep -q 'ask the hub to dismiss the review with a written reason' "$f"
}

@test "no text calls another lead a distinct github reviewer" {
  ! grep -rniE 'distinct (github )?reviewer|separate (github )?(login|reviewer)|different github (login|reviewer)' \
    "$ROOT/skills" "$ROOT/agents" "$ROOT/README.md" "$AR"
}

@test "readme says the hub merges elevated prs outside the skill" {
  grep -q 'requires-elevated-merge' "$ROOT/README.md"
  grep -qiE 'hub merges.*outside the (merge )?skill' "$ROOT/README.md"
}

@test "readme says another leads review is observability" {
  grep -qi 'another lead.s review is observability' "$ROOT/README.md"
}

@test "readme runbook covers exits 4 5 6 10 11" {
  sec=$(sed -n '/^### Runbook/,/^## /p' "$ROOT/README.md")
  [ -n "$sec" ]
  for c in 4 5 6 10 11; do grep -qE "^\| $c \|" <<<"$sec"; done
  grep -q 'author' <<<"$sec"; grep -q 'last pusher' <<<"$sec"; grep -q 'BLOCKED' <<<"$sec"
  grep -q 'written reason' <<<"$sec"
}

@test "readme notes persistent unknown" {
  grep -q 'APPROVED. with a persistent .UNKNOWN. passes on .reviewDecision.' "$ROOT/README.md"
  grep -q "GitHub's merge still enforces the rule" "$ROOT/README.md"
}

@test "readme rollout notes the content repo is already live" {
  grep -q 'Screenfields/ccplugin-alfred-content' "$ROOT/README.md"
  grep -q '25678306' "$ROOT/README.md"
}

# =============================================================================
# push-site audit: criterion 23
# =============================================================================

awk_check() { # <file> <pattern>: every site has switch-role lead before it in its code block
  awk -v pat="$2" '
    /^[[:space:]]*```/ { if (inf) { inf=0 } else { inf=1; seen=0; single=(prev ~ /single-role/) } next }
    { if (!inf && $0 !~ /^[[:space:]]*$/) prev=$0 }
    /switch-role lead/ { seen=1 }
    $0 ~ pat {
      if (!inf) { print FILENAME": "NR": outside a code block"; bad=1 }
      else if (!seen && !single) { print FILENAME": "NR": no switch-role lead before the site"; bad=1 }
    }
    END { exit bad }' "$1"
}

@test "every push and pr create site is classified" {
  list="$FIX/push-sites.txt"
  # found: file|command|count over the directories the item names (and lib/, which holds shared shell)
  found=$(cd "$ROOT" && for cmd in 'git push' 'gh pr create'; do
      grep -rIcF -- "$cmd" skills commands agents hooks lib bin 2>/dev/null | grep -v ':0$' | while IFS=: read -r f n; do echo "$f|$cmd|$n"; done
    done | sort)
  listed=$(grep -v '^#' "$list" | awk -F'|' '{print $1"|"$2"|"$3}' | sort)
  [ "$found" = "$listed" ]
  # every entry has a class and a reason
  ! grep -v '^#' "$list" | awk -F'|' '($4 != "lead" && $4 != "other") || $5 == ""' | grep -q .
}

@test "lead-role sites switch to lead first" {
  list="$FIX/push-sites.txt"
  while IFS='|' read -r f cmd n cls reason; do
    [ "$cls" = lead ] || continue
    awk_check "$ROOT/$f" "$cmd"
  done < <(grep -v '^#' "$list")
}
