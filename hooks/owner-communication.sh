#!/usr/bin/env bash
# SessionStart hook: put the owner-communication rules into the session
# context. Deterministic, no model call.
set -euo pipefail
rules="$(dirname "$0")/owner-communication.md"
jq -n --rawfile ctx "$rules" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
