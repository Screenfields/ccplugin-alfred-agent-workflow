#!/usr/bin/env bash
# SessionStart hook: put the platform rules and the doctrine index into every
# session's context (ccplugin#121, AP-ADR0021: rules are delivered by hooks).
#
# Claude Code does not load a plugin's rules/ directory into a session
# (verified 2026-10-12, ccplugin#110), so this hook is the delivery:
#   - rules/*.md, in full: each is one short judgment;
#   - doctrines/NN-*.md, as an index: one line per doctrine (number, title,
#     its one-line rule from the `description` frontmatter) plus the path of
#     the full text in the installed plugin, read on demand. The full set is
#     ~125 KB, too large to inject every session.
# A hook string is capped at 10,000 characters; tests/alfred-wake.bats checks
# the output stays under it. Deterministic: file reads only, no model call.
set -u

root="${ALFRED_PLUGIN_ROOT_OVERRIDE:-$(cd "$(dirname "$0")/.." && pwd)}"

ctx="# Platform rules and doctrines (alfred-agent default)

## Rules
"
for f in "$root"/rules/*.md; do
  [ -f "$f" ] || continue
  ctx="$ctx
- $(tr '\n' ' ' < "$f" | sed 's/[[:space:]]*$//')"
done

ctx="$ctx

## Doctrines
Cross-project doctrines, owned in alfred-platform (docs/doctrines). One line
each. The full text of DNN, with why it exists and how to apply it, is
$root/doctrines/NN-*.md: read it when a doctrine bears on what you are doing.
"
for f in "$root"/doctrines/[0-9][0-9]-*.md; do
  [ -f "$f" ] || continue
  num=$(basename "$f" | cut -c1-2)
  # H1 is "# 01. Title" or "# Doctrine 18 — Title".
  title=$(grep -m1 '^# ' "$f" | sed -E 's/^# (Doctrine )?[0-9]+(\.|[[:space:]]+—)[[:space:]]*//')
  desc=$(sed -n 's/^description: *"\(.*\)"$/\1/p' "$f" | head -1)
  ctx="$ctx
- D$num $title: $desc"
done

jq -n --arg ctx "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
