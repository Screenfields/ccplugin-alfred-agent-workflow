#!/usr/bin/env bash
# UserPromptSubmit hook: put the current Europe/Amsterdam time into the context
# of every prompt, with the rule to start the reply with it (CCW-141, CCW-180).
# The owner rule of 2026-10-12 (hooks/owner-communication.md) used to be text at
# session start only, and it faded in long sessions.
#
# It emits on every UserPromptSubmit, wake turns included, except when
# ALFRED_ROLE=worker. Stdin that is not a single JSON object, or missing time
# zone data (%Z is not CET or CEST, one line on stderr), gives no output. The
# wording and the zone check live in lib/reply-time.sh. lib/owner-turn.sh (the
# loop check's note-turn test) now only fills the `owner` field of the debug
# log. No state is kept.
#
# ALFRED_REPLY_TS_LOG=<file> appends one JSON line per prompt
# ({ts, source, entrypoint, owner, emitted}) for the live check.
#
# Fail-open: no set -e, no set -u; every path ends with exit 0, and a missing
# jq or reply-time lib means no output.
input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=../lib/owner-turn.sh
# shellcheck disable=SC1091
. "$(dirname "$0")/../lib/owner-turn.sh" 2>/dev/null || is_owner_turn() { return 1; }
# shellcheck source=../lib/reply-time.sh
# shellcheck disable=SC1091
. "$(dirname "$0")/../lib/reply-time.sh" 2>/dev/null || exit 0

valid=false
jq -es 'length == 1 and (.[0] | type == "object")' <<< "$input" >/dev/null 2>&1 && valid=true
src=$(jq -r '.source // empty' <<< "$input" 2>/dev/null)
{ prompt=$(jq -r '.prompt // empty' <<< "$input" 2>/dev/null); } 2>/dev/null
ep="${CLAUDE_CODE_ENTRYPOINT:-}"
owner=false
is_owner_turn "$ep" "$src" "$prompt" && owner=true
emitted=false
line=""
if [ "$valid" = true ] && line=$(reply_time_line); then emitted=true; fi
reply_time_log "$src" "$ep" "$owner" "$emitted"
[ "$emitted" = true ] || exit 0
jq -cn --arg c "$line" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' 2>/dev/null
exit 0
