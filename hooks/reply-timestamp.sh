#!/usr/bin/env bash
# UserPromptSubmit hook: put the current Europe/Amsterdam time into the context
# of every owner prompt, with the rule to start the reply with it (CCW-141).
# The owner rule of 2026-10-12 (hooks/owner-communication.md) used to be text at
# session start only, and it faded in long sessions.
#
# An owner turn is decided by lib/owner-turn.sh, the same test the loop check's
# note-turn uses. On a machine turn, a worker, or anything unclear, it prints
# nothing. If the time zone data is missing (%Z is not CET or CEST) it prints
# nothing and writes one line to stderr. No state is kept.
#
# ALFRED_REPLY_TS_LOG=<file> appends one JSON line per prompt
# ({ts, source, entrypoint, owner}) for the live check.
#
# Fail-open: no set -e, no set -u; every path ends with exit 0, and a missing
# jq or lib means no output.
input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=../lib/owner-turn.sh
. "$(dirname "$0")/../lib/owner-turn.sh" 2>/dev/null || exit 0

src=$(jq -r '.source // empty' <<< "$input" 2>/dev/null)
prompt=$(jq -r '.prompt // empty' <<< "$input" 2>/dev/null)
ep="${CLAUDE_CODE_ENTRYPOINT:-}"
owner=false
is_owner_turn "$ep" "$src" "$prompt" && owner=true

if [ -n "${ALFRED_REPLY_TS_LOG:-}" ]; then
  jq -cn --arg ts "$(date -u +%FT%TZ 2>/dev/null)" --arg s "$src" --arg e "$ep" --argjson o "$owner" \
    '{ts: $ts, source: $s, entrypoint: $e, owner: $o}' >> "$ALFRED_REPLY_TS_LOG" 2>/dev/null
fi
[ "$owner" = true ] || exit 0

now=$(TZ=Europe/Amsterdam date '+%F %H:%M %Z' 2>/dev/null)
case "$now" in
  *" CET"|*" CEST") ;;
  *) echo "reply-timestamp: no Europe/Amsterdam time (tzdata missing?), no time line" >&2; exit 0 ;;
esac
stamp="${now% *}"
zone="${now##* }"
jq -cn --arg t "$stamp $zone" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit",
  additionalContext: ("Owner prompt received at _[" + $t + "]_. Start your reply with this time line; if the turn runs longer than a few minutes, use a fresh TZ=Europe/Amsterdam time instead.")}}' 2>/dev/null
exit 0
