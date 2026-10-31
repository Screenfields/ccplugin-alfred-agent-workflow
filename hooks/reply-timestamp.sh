#!/usr/bin/env bash
# UserPromptSubmit hook: when a prompt starts a new set of actions, put the
# current Europe/Amsterdam time into the context of its turn, with the rule to
# start the first reply with it (CCW-141, CCW-180). The owner rule of 2026-10-12
# (hooks/owner-communication.md) used to be text at session start only, and it
# faded in long sessions.
#
# A new set of actions is a prompt that finds the session idle for
# reply-time-idle-minutes or more, or that the gate cannot judge (first prompt,
# no or unusable state, no session id, unwritable state directory). The gate
# looks at the clock and the per-session state only, never at the wake type.
# Every non-worker prompt with a session id is recorded in
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/alfred-reply-ts/<session_id>.json; hooks/
# stop.sh records the end of each turn there. The gate, the state fields, the
# wording and the zone check live in lib/reply-time.sh. lib/owner-turn.sh (the
# loop check's note-turn test) only fills the `owner` field of the debug log.
#
# One clock reading per run (reply_time_now): the gap's "now", the stored time and
# the stamp in the text. ALFRED_ROLE=worker: no output, no state read or written.
# Stdin that is not a single JSON object, or missing time zone data (%Z is not
# CET or CEST, one line on stderr), gives no output.
#
# ALFRED_REPLY_TS_LOG=<file> appends one JSON line per prompt
# ({ts, source, entrypoint, owner, emitted, gap}) for the live check.
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

# One jq reads the whole input: valid (stdin is exactly one JSON object), source,
# session id and prompt, one per line, the prompt last (it may span lines). Newlines
# in source and session id become spaces (the state file name is sanitised anyway).
valid=false
{
  IFS= read -r valid; IFS= read -r src; IFS= read -r sid; prompt=$(cat)
} < <(jq -rs '(if length == 1 and (.[0] | type) == "object" then .[0] else null end) as $o
  | ($o != null | tostring),
    (($o.source // "") | tostring | gsub("\n"; " ")),
    (($o.session_id // "") | tostring | gsub("\n"; " ")),
    (($o.prompt // "") | tostring)' <<< "$input" 2>/dev/null)
[ "$valid" = true ] || valid=false
ep="${CLAUDE_CODE_ENTRYPOINT:-}"
owner=false
is_owner_turn "$ep" "$src" "$prompt" && owner=true
emitted=false
line=""
now=$(reply_time_now)
if [ "$valid" = true ]; then
  if reply_time_gate "$sid" "$now"; then
    line=$(reply_time_line ${now:+"$now"}) && emitted=true
  fi
  [ -n "$sid" ] && [ -n "$now" ] && reply_time_note_prompt "$sid" "$now" "$emitted"
fi
reply_time_log "$src" "$ep" "$owner" "$emitted" "${RT_GAP:-null}"
[ "$emitted" = true ] || exit 0
jq -cn --arg c "$line" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' 2>/dev/null
exit 0
