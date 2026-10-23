#!/usr/bin/env bats
# hooks/routed-context.sh at SessionStart (ccplugin#127): the lead agreement
# and the role-routed rules, by level. Black box: hook JSON on stdin, the
# hook JSON on stdout. No network.

setup() {
  HOOK="$BATS_TEST_DIRNAME/../hooks/routed-context.sh"
  ROOT="$BATS_TEST_DIRNAME/.."
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/.alfred"
  unset ALFRED_ROLE
}

# session <agent_id|none> — run the hook for a project with that agent id.
session() {
  rm -f "$PROJ/.alfred/config.json"
  if [ "$1" != none ]; then
    jq -n --arg id "$1" '{agent_id: $id}' > "$PROJ/.alfred/config.json"
  fi
  jq -cn --arg c "$PROJ" '{hook_event_name: "SessionStart", cwd: $c}' | "$HOOK"
}

ctx_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext'; }

# body <rule-name> — the rule text after the frontmatter, one line.
body() { awk 'c >= 2 {print} /^---$/ {c++}' "$ROOT/rules/routed/$1.md" | tr '\n' ' ' | sed 's/[[:space:]]*$//'; }

# tag <rule-name> <key> — a frontmatter value.
tag() { sed -n "s/^$2: *//p" "$ROOT/rules/routed/$1.md" | head -1; }

ALL_RULES="deployment-is-not-evidence parallel-only-when-independent wait-for-the-decider report-failing-platform-services"
LEAD_RULES="memory-holds-only-lessons message-hub-for-cross-project-results feedback-and-bugs-become-work-items work-and-review-in-pairs author-gitops-pr-never-self-approve issue-and-pr-titles-carry-codes"
WORKER_RULES="unclear-brief-goes-back workers-change-rules-only-when-briefed hand-back-fields workers-never-merge-or-delegate"

@test "lead: the agreement in full, then the all and lead rules in full (AC 1)" {
  run session some-lead
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.hookEventName)" = "SessionStart" ]
  ctx=$(ctx_of "$output")
  [[ "$ctx" == *"# Lead agreement"* ]]
  # Every sentence of appendix A is still there, verbatim.
  while IFS= read -r line; do
    [[ "$ctx" == *"$line"* ]] || { echo "missing: $line"; return 1; }
  done < "$BATS_TEST_DIRNAME/fixtures/agreement/appendix-a-sentences.txt"
  for r in $ALL_RULES $LEAD_RULES; do
    [[ "$ctx" == *"- $(body "$r")"* ]] || { echo "missing rule: $r"; return 1; }
  done
  for r in $WORKER_RULES; do
    [[ "$ctx" != *"$(body "$r")"* ]] || { echo "worker rule leaked to a lead: $r"; return 1; }
  done
}

@test "hub and alfred: the all rules only, no agreement and no lead-only rule (AC 1)" {
  for id in hub alfred; do
    run session "$id"
    [ "$status" -eq 0 ]
    ctx=$(ctx_of "$output")
    [[ "$ctx" != *"Lead agreement"* ]]
    [[ "$ctx" != *"**Purpose.**"* ]]
    for r in $ALL_RULES; do
      [[ "$ctx" == *"- $(body "$r")"* ]] || { echo "$id: missing $r"; return 1; }
    done
    for r in $LEAD_RULES $WORKER_RULES; do
      [[ "$ctx" != *"$(body "$r")"* ]] || { echo "$id: leaked $r"; return 1; }
    done
  done
}

@test "no .alfred/config.json: nothing at all (AC 1)" {
  run session none
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unknown id is a lead, not nothing (AC 1)" {
  run session brand-new-agent
  [[ "$(ctx_of "$output")" == *"**Purpose.**"* ]]
}

@test "ALFRED_ROLE=worker: the worker rules, never the agreement, whatever the config says" {
  export ALFRED_ROLE=worker
  run session some-lead
  ctx=$(ctx_of "$output")
  [[ "$ctx" != *"Lead agreement"* ]]
  for r in $ALL_RULES $WORKER_RULES; do
    [[ "$ctx" == *"- $(body "$r")"* ]] || { echo "missing $r"; return 1; }
  done
  for r in $LEAD_RULES; do
    [[ "$ctx" != *"$(body "$r")"* ]]
  done
}

@test "malformed hook input and an unknown event give no output and exit 0" {
  run bash -c 'printf "not json" | "$1"' _ "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash -c 'printf "{\"hook_event_name\":\"Stop\"}" | "$1"' _ "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the owner addition is in the agreement: next actionable item, waiting status, release, decision recorded (AC 8)" {
  run session some-lead
  ctx=$(ctx_of "$output")
  [[ "$ctx" == *"After each item, take the next actionable one"* ]]
  [[ "$ctx" == *"not waiting on the owner and fits within wip-limit and worker-limit"* ]]
  [[ "$ctx" == *"gets the status named by waiting-label and keeps its state, which frees its work-in-progress slot"* ]]
  [[ "$ctx" == *"When the owner answers, remove the status and record the decision on the item."* ]]
  [[ "$ctx" == *"The loop ends only when no actionable item is left"* ]]
}

@test "routed rules: name, roles, work and severity match the tag table (AC 4)" {
  table='deployment-is-not-evidence|all|code, operations|major
parallel-only-when-independent|all|code, operations|critical
wait-for-the-decider|all|work item, design|major
memory-holds-only-lessons|lead|work item|minor
report-failing-platform-services|all|operations|major
message-hub-for-cross-project-results|lead|work item|minor
feedback-and-bugs-become-work-items|lead|work item|major
unclear-brief-goes-back|worker|work item, code|major
workers-change-rules-only-when-briefed|worker|work item|major
hand-back-fields|worker|work item|minor
workers-never-merge-or-delegate|worker|code, work item|major
work-and-review-in-pairs|lead|code, design, work item|major
author-gitops-pr-never-self-approve|lead|operations|critical
issue-and-pr-titles-carry-codes|lead|work item|minor'
  [ "$(ls "$ROOT"/rules/routed/*.md | wc -l)" -eq 14 ]
  while IFS='|' read -r name roles work sev; do
    f="$ROOT/rules/routed/$name.md"
    [ -f "$f" ] || { echo "no file for $name"; return 1; }
    [ "$(tag "$name" name)" = "$name" ]
    [ "$(tag "$name" roles)" = "[$roles]" ]
    [ "$(tag "$name" work)" = "[$work]" ]
    [ "$(tag "$name" severity)" = "$sev" ]
    [ -n "$(body "$name")" ]
    # name is the first key, body follows the closing marker.
    [ "$(sed -n 1p "$f")" = "---" ]
  done <<< "$table"
}

@test "the GitOps rule: lead output only, not in rules/ and not in doctrines-context (AC 5)" {
  gitops=$(body author-gitops-pr-never-self-approve)
  [[ "$gitops" == *"sends the hub a gate ask with the head SHA"* ]]
  [[ "$gitops" == *"never approves its own"* ]]
  [[ "$gitops" != *"internal"* && "$gitops" != *"external"* ]]
  [ ! -e "$ROOT/rules/check-lead-environment-before-self-serve-gitops.md" ]
  run session some-lead
  [[ "$(ctx_of "$output")" == *"$gitops"* ]]
  run session hub
  [[ "$(ctx_of "$output")" != *"$gitops"* ]]
  run "$ROOT/hooks/doctrines-context.sh"
  [[ "$(ctx_of "$output")" != *"gate ask with the head SHA"* ]]
  [[ "$(ctx_of "$output")" != *"self-serve gitops"* ]]
}

@test "the 12 old rules still reach every session through doctrines-context (AC 7)" {
  [ "$(ls "$ROOT"/rules/*.md | wc -l)" -eq 12 ]
  run "$ROOT/hooks/doctrines-context.sh"
  ctx=$(ctx_of "$output")
  for f in "$ROOT"/rules/*.md; do
    [[ "$ctx" == *"$(tr '\n' ' ' < "$f" | cut -c1-60)"* ]]
  done
}

@test "hook strings stay under the cap with headroom (AC 7)" {
  run session some-lead
  [ "${#output}" -lt 9500 ]
  [ "$(printf '%s' "$(ctx_of "$output")" | wc -c)" -lt 9500 ]
  run session hub
  [ "${#output}" -lt 9500 ]
  run "$ROOT/hooks/doctrines-context.sh"
  [ "${#output}" -lt 9500 ]
}
