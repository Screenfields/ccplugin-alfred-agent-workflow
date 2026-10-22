#!/usr/bin/env bats
# hooks/routed-context.sh at SubagentStart (ccplugin#127): a fresh subagent
# receives the worker rules (worker and all level) and nothing for leads.

setup() {
  HOOK="$BATS_TEST_DIRNAME/../hooks/routed-context.sh"
  ROOT="$BATS_TEST_DIRNAME/.."
  unset ALFRED_ROLE
}

body() { awk 'c >= 2 {print} /^---$/ {c++}' "$ROOT/rules/routed/$1.md" | tr '\n' ' ' | sed 's/[[:space:]]*$//'; }

sub() { # sub <agent_type> [cwd]
  jq -cn --arg t "$1" --arg c "${2:-$BATS_TEST_TMPDIR}" \
    '{hook_event_name: "SubagentStart", agent_type: $t, agent_id: "a1", cwd: $c}' | "$HOOK"
}

@test "a fresh subagent gets the all and worker rules and no lead rule or agreement (AC 2)" {
  for t in builder code-reviewer general-purpose; do
    run sub "$t"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.hookEventName)" = "SubagentStart" ]
    ctx=$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)
    for r in deployment-is-not-evidence parallel-only-when-independent wait-for-the-decider report-failing-platform-services \
             unclear-brief-goes-back workers-change-rules-only-when-briefed hand-back-fields workers-never-merge-or-delegate; do
      [[ "$ctx" == *"- $(body "$r")"* ]] || { echo "$t: missing $r"; return 1; }
    done
    for r in memory-holds-only-lessons message-hub-for-cross-project-results feedback-and-bugs-become-work-items \
             work-and-review-in-pairs author-gitops-pr-never-self-approve; do
      [[ "$ctx" != *"$(body "$r")"* ]] || { echo "$t: lead rule leaked: $r"; return 1; }
    done
    [[ "$ctx" != *"**Purpose.**"* && "$ctx" != *"Lead agreement"* ]]
  done
}

@test "subagent delivery does not depend on the project having a config" {
  mkdir -p "$BATS_TEST_TMPDIR/bare"
  run sub builder "$BATS_TEST_TMPDIR/bare"
  [[ "$output" == *"hand-back"* || "$output" == *"Hand back"* ]]
}

@test "subagent string stays under the cap with headroom" {
  run sub builder
  [ "${#output}" -lt 9500 ]
}
