#!/usr/bin/env bash
# Stop part: audit the time stamp at the head of the final reply (CCW-184).
# Run by hooks/stop.sh as its third part, with the Stop hook JSON on stdin and
# `--now <epoch>`, the one clock reading stop.sh took before it ran any part.
#
# Prints one {decision: "block", reason: <one paragraph>} when the reply starts
# with a stamp that is in the future, or more than reply-time-tolerance-minutes
# behind both the clock and every time injected this turn; nothing otherwise. It
# never asks for a stamp: a reply without one is silent. The injected times and the
# flag are in the state file (lib/reply-time.sh, `injected` and `flagged`): a flag
# is recorded before it is printed, and if it cannot be recorded nothing is
# flagged. A passing or silent Stop writes nothing. stop_hook_active is ignored.
# Silent when: ALFRED_REPLY_TS_AUDIT=0 (nothing is read), ALFRED_ROLE=worker,
# jq/date/lib missing, stdin not one JSON object, no session_id, an empty reply, a
# reply with no leading stamp, an absent or unusable state file, flagged already
# true, an invalid date in the stamp, no Europe/Amsterdam time to quote, an
# unreadable tolerance (one stderr line).
#
# Fail-open: no set -e, no set -u; every path ends with exit 0.
# shellcheck source=../lib/reply-time.sh
# shellcheck disable=SC1091
. "$(dirname "$0")/../lib/reply-time.sh" 2>/dev/null || exit 0
reply_time_audit_off && exit 0
[ "${ALFRED_ROLE:-}" = "worker" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v date >/dev/null 2>&1 || exit 0
now=""
[ "${1:-}" = "--now" ] && now="${2:-}"

# One jq call: the session id and the first 200 characters of the reply, line
# breaks and tabs folded to spaces.
parsed=$(jq -rs 'if length == 1 and (.[0] | type) == "object"
    then .[0] | [((.session_id // "") | tostring | gsub("[^A-Za-z0-9._-]"; "_")),
                 ((.last_assistant_message // "") | if type == "string" then .[0:200] | gsub("[\\r\\n\\t]+"; " ") else "" end)]
      | join("|")
    else empty end' 2>/dev/null) || exit 0
sid=${parsed%%|*}
text=${parsed#*|}
[ -n "$sid" ] && [ "$sid" != "$parsed" ] || exit 0
read -r y mo d h mi z <<< "$(reply_time_stamp_head "$text")"
[ -n "$z" ] || exit 0
stamp_epoch=$(reply_time_stamp_epoch "$y" "$mo" "$d" "$h" "$mi" "$z") || exit 0
state=$(reply_time_audit_state "$sid") || exit 0
flagged=${state%%|*}
injected=${state#*|}
[ "$flagged" = true ] && exit 0
# The clock is the one stop.sh took before it ran any part; a lagging part must
# not age a stamp that was fresh when the Stop began. Without a usable --now
# (standalone use) the script reads the clock itself.
_rt_epoch "$now" || now=$(reply_time_now) || exit 0
# The tolerance is read only when the stamp is not in the minute of the clock or of
# an injected time (the common pass), through alfred-config.
tol=0
# shellcheck disable=SC2086  # $injected is a list of epochs
verdict=$(reply_time_verdict "$stamp_epoch" "$now" "$tol" $injected)
if [ "$verdict" = stale ]; then
  tol=$("$(dirname "$0")/../bin/alfred-config" get reply-time-tolerance-minutes 2>/dev/null)
  case "$tol" in [0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]) ;; *) echo "reply-audit: reply-time-tolerance-minutes unreadable, no audit" >&2; exit 0 ;; esac
  tol=$((10#$tol))
  # shellcheck disable=SC2086
  verdict=$(reply_time_verdict "$stamp_epoch" "$now" "$tol" $injected)
fi
[ "$verdict" = ok ] && exit 0

correct=$(reply_time_stamp "$now") || exit 0
shown="$y-$mo-$d $h:$mi $z"
if [ "$verdict" = future ]; then
  why="is $(( (stamp_epoch / 60) - (now / 60) )) minute(s) ahead of the clock"
else
  why="is $(( (now / 60) - (stamp_epoch / 60) )) minute(s) behind the clock and more than $tol minute(s) from every time injected this turn"
fi
reply_time_note_flag "$sid" 2>/dev/null || exit 0
jq -cn --arg s "$shown" --arg w "$why" --arg c "$correct" \
  '{decision: "block", reason: ("Time check: your reply started with _[" + $s + "]_, which " + $w + ". The time now is _[" + $c + "]_. The time line is the injected value of this turn, or a fresh TZ=Europe/Amsterdam date reading; never estimated, extrapolated or carried over. Answer with one short line that starts with _[" + $c + "]_ and says the earlier time was wrong; do not repeat the rest of your reply.")}' 2>/dev/null
exit 0
