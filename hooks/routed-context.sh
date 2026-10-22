#!/usr/bin/env bash
# SessionStart and SubagentStart hook: deliver the lead agreement and the
# role-routed rules (ccplugin#127, AP-ADR0021, AP-ADR0031).
#
# One hook, two events (the event name is in the stdin JSON):
#   SessionStart   by level, from .alfred/config.json agent_id:
#                    no config            nothing (not an Alfred project)
#                    hub, alfred          the `all` rules only; their process
#                                         part lives in the hub charter and
#                                         alfred/INSTRUCTIONS.md
#                    any other id (lead)  the lead agreement, then the `all`
#                                         and `lead` rules
#                  ALFRED_ROLE=worker (set by worker and test launchers)
#                  overrides this: the worker rules, never the agreement.
#   SubagentStart  every agent type: the `all` and `worker` rules, nothing
#                  for leads.
#
# Rules are rules/routed/*.md (frontmatter name, roles, work, severity, then
# the body: one statement with its reason). The routed files sit outside the
# rules/*.md glob of doctrines-context.sh, so they are never delivered twice.
# A hook string is capped at 10,000 characters; tests/agreement-rules-context.bats
# keeps this one under 9,500. Deterministic: file reads only, no model call.
set -u

root="${ALFRED_PLUGIN_ROOT_OVERRIDE:-$(cd "$(dirname "$0")/.." && pwd)}"
input=$(cat)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"

# roles_of <file>: the roles list of a routed rule, one per line.
roles_of() {
  sed -n '/^---$/,/^---$/{s/^roles: *\[\(.*\)\] *$/\1/p}' "$1" | tr ',' '\n' | tr -d ' '
}

# body_of <file>: the rule text after the frontmatter, on one line.
body_of() {
  awk 'c >= 2 {print} /^---$/ {c++}' "$1" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# rules_for <role>...: "- <body>" for every routed rule seen by one of them.
rules_for() {
  local f r want
  for f in "$root"/rules/routed/*.md; do
    [ -f "$f" ] || continue
    for r in $(roles_of "$f"); do
      for want in "$@"; do
        if [ "$r" = "$want" ]; then
          printf -- '- %s\n' "$(body_of "$f")"
          continue 3
        fi
      done
    done
  done
}

case "$event" in
  SubagentStart)
    ctx="# Worker rules (alfred-agent)

$(rules_for all worker)"
    ;;
  SessionStart)
    if [ "${ALFRED_ROLE:-}" = "worker" ]; then
      ctx="# Worker rules (alfred-agent)

$(rules_for all worker)"
    else
      id=$(jq -r '.agent_id // empty' "$cwd/.alfred/config.json" 2>/dev/null)
      [ -n "$id" ] || exit 0
      case "$id" in
        hub|alfred)
          ctx="# Routed rules (alfred-agent)

$(rules_for all)"
          ;;
        *)
          ctx="# Lead agreement (alfred-agent)

How you work as a lead. Thresholds are named, not numbered: read one with
\`alfred-config get <name>\` (config/thresholds.json in the plugin).

$(cat "$root/agreement/lead.md")

# Routed rules (alfred-agent)

$(rules_for all lead)"
          ;;
      esac
    fi
    ;;
  *) exit 0 ;;
esac

jq -n --arg e "$event" --arg ctx "$ctx" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $ctx}}'
