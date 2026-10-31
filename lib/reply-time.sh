# shellcheck shell=bash
# Shared reply-time line and idle gate (CCW-180). Sourced by
# hooks/reply-timestamp.sh and hooks/stop.sh, so the wording, the CET/CEST
# check, the clock and the per-session state live in one place. Defines
# functions and the RT_* result variables below; sets nothing else, never exits.
#
# --- the line -------------------------------------------------------------
#   reply_time_stamp [epoch]
#       stdout: "YYYY-MM-DD HH:MM CEST" (or CET), Europe/Amsterdam. With no
#       argument it is now, or the instant in ALFRED_REPLY_TS_NOW (epoch
#       seconds; the DST test uses it). Return 1, nothing on stdout and one line
#       on stderr, when %Z is not CET or CEST (tzdata missing).
#   reply_time_line [epoch]
#       stdout: the injected text, one line. Return 1 with nothing on stdout
#       when ALFRED_ROLE=worker or reply_time_stamp fails (its stderr line
#       passes through).
#   reply_time_log <source> <entrypoint> <owner: true|false|null> <emitted: true|false> [gap]
#       Appends {ts, source, entrypoint, owner, emitted, gap} to
#       ALFRED_REPLY_TS_LOG when that is set (gap: seconds as an integer, default
#       null); needs jq; silent on any failure.
#
# --- clock and state ------------------------------------------------------
#   reply_time_now
#       stdout: epoch seconds. ALFRED_REPLY_TS_NOW when it is an epoch (below),
#       else `date +%s`. Return 1, nothing on stdout, when neither gives one.
#       Callers read it ONCE per hook run and pass that one value on.
#
# An epoch is a whole number of seconds from 1000000000 to 9999999999 (ten
# digits). Every epoch the lib reads (clock, environment, stored state) must pass
# that range before any shell arithmetic runs on it; jq checks stored values, and
# bash checks them again (_rt_epoch). Out of range stored state is "unusable": the
# gate shows the line with one stderr line and the next write drops the bad keys.
#   reply_time_state_file <session_id>
#       stdout: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/alfred-reply-ts/<sid>.json,
#       every character of <sid> outside A-Za-z0-9._- replaced by _ (the way
#       bin/alfred-loop-check does). Return 1, no output, for an empty id.
#   reply_time_gate <session_id> <now>
#       Does this prompt start a new set of actions? Return 0: show the line.
#       Return 1: do not (also for ALFRED_ROLE=worker, which reads no state).
#       Sets RT_GAP (now - last_activity as an integer, else "null") and
#       RT_ANOMALY (1 when it wrote its stderr line). When it cannot
#       decide it returns 0, and for an anomaly (no session id, no clock,
#       unwritable state directory, unusable state, unreadable threshold, last
#       activity in the future) writes one line to stderr. Absent state and an
#       absent last_activity are the normal "cannot tell" and write nothing.
#   reply_time_note_prompt <session_id> <now> <emitted: true|false>
#       Records a non-worker prompt: last_prompt, open:true, and line_at when a
#       line was injected. Return 1 (one stderr line) when it cannot write.
#   reply_time_note_stop <now> <stop-input-file>
#       Records a Stop from its JSON input: last_stop, stop_nonempty, open:false,
#       and last_activity when last_assistant_message holds a non-whitespace
#       character. Silent and 0 for a worker, an empty session id or unusable
#       input; one stderr line and 1 when it cannot write.
#
# The state file alfred-reply-ts/<sid>.json holds one JSON object. Fields CCW-180
# owns (all epochs are integer seconds from reply_time_now):
#   last_prompt    epoch of the latest non-worker prompt
#   line_at        epoch of the latest injection; absent until one was made
#   open           true after a prompt, false after a Stop (an interrupted turn
#                  never writes the Stop, so it stays true; see the gate)
#   last_stop      epoch (start clock of stop.sh) of the latest Stop
#   stop_nonempty  whether that Stop's final message was non-empty
#   last_activity  last_stop of the latest Stop whose final message was non-empty
# Fields the stamp audit (CCW-184) owns, declared here once and described with its
# functions at the end of this file:
#   injected       epochs injected in this turn, newest 8 (restarted by a prompt
#                  that finds open false; extended by a prompt that injects)
#   flagged        a flag was issued this turn (cleared by every non-worker prompt;
#                  set only by reply_time_note_flag)
# Every write merges into the stored object, so keys of other writers survive.
#
# Idle gate: emit when (last_activity is absent or now - last_activity >= T) and
# not (open and now - line_at is in 0..T-1), with T = reply-time-idle-minutes * 60.

# Message prefix of the gate's anomaly line.
_RT_GATE_MSG="reply-timestamp: idle gate cannot decide"

reply_time_stamp() {
  local at="${1:-${ALFRED_REPLY_TS_NOW:-}}" now
  if [ -n "$at" ]; then
    now=$(TZ=Europe/Amsterdam date -d "@$at" '+%F %H:%M %Z' 2>/dev/null)
  else
    now=$(TZ=Europe/Amsterdam date '+%F %H:%M %Z' 2>/dev/null)
  fi
  case "$now" in
    *" CET"|*" CEST") printf '%s\n' "$now" ;;
    *) echo "reply-timestamp: no Europe/Amsterdam time (tzdata missing?), no time line" >&2; return 1 ;;
  esac
}

reply_time_line() {
  local stamp
  [ "${ALFRED_ROLE:-}" = "worker" ] && return 1
  stamp=$(reply_time_stamp "$@") || return 1
  printf 'Time now _[%s]_. A new set of actions starts: start your first reply of this turn with this time line. Put none on later replies until a line is injected again. If the turn runs longer than a few minutes, use a fresh TZ=Europe/Amsterdam time instead.\n' "$stamp"
}

reply_time_log() {
  [ -n "${ALFRED_REPLY_TS_LOG:-}" ] || return 0
  jq -cn --arg ts "$(date -u +%FT%TZ 2>/dev/null)" --arg s "${1:-}" --arg e "${2:-}" \
    --argjson o "${3:-null}" --argjson m "${4:-false}" --argjson g "${5:-null}" \
    '{ts: $ts, source: $s, entrypoint: $e, owner: $o, emitted: $m, gap: $g}' >> "$ALFRED_REPLY_TS_LOG" 2>/dev/null
  return 0
}

# _rt_epoch <value>: 0 for ten digits starting with 1 to 9 (1000000000 to
# 9999999999), 1 for anything else. The only gate in front of shell arithmetic.
_rt_epoch() { case "${1:-}" in [1-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;; esac; return 1; }

reply_time_now() {
  local n="${ALFRED_REPLY_TS_NOW:-}"
  _rt_epoch "$n" || n=$(date +%s 2>/dev/null)
  _rt_epoch "$n" || return 1
  printf '%s\n' "$n"
}

reply_time_state_file() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/alfred-reply-ts/${1//[^A-Za-z0-9._-]/_}.json"
}

# _rt_anomaly <reason>: the one stderr line of a gate that cannot decide.
_rt_anomaly() { RT_ANOMALY=1; echo "$_RT_GATE_MSG ($1), time line shown" >&2; }

reply_time_gate() {
  local sid="${1:-}" now="${2:-}" f dir vals la line_at open mins t idle=1 d
  RT_GAP=null
  RT_ANOMALY=0
  [ "${ALFRED_ROLE:-}" = "worker" ] && return 1
  f=$(reply_time_state_file "$sid") || { _rt_anomaly "no session_id"; return 0; }
  _rt_epoch "$now" || { _rt_anomaly "no clock"; return 0; }
  dir=${f%/*}
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
  if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then _rt_anomaly "state directory not writable"; return 0; fi
  [ -e "$f" ] || return 0
  [ -d "$f" ] && { _rt_anomaly "state is a directory"; return 0; }
  vals=$(jq -r '
    def num: type == "number" and . >= 1000000000 and . <= 9999999999 and . == floor;
    if type != "object" then "bad"
    elif ([.last_activity, .line_at] | map(select(. != null and (num | not))) | length) > 0
         or (.open != null and (.open | type) != "boolean") then "bad"
    else [(.last_activity // "-"), (.line_at // "-"), (.open // false)] | map(tostring) | join(" ") end' "$f" 2>/dev/null)
  case "$vals" in ''|bad) _rt_anomaly "state unreadable"; return 0 ;; esac
  read -r la line_at open <<< "$vals"
  # jq vetted these; bash vets them again before any arithmetic.
  for d in "$la" "$line_at"; do
    [ "$d" = "-" ] || _rt_epoch "$d" || { _rt_anomaly "state unreadable"; return 0; }
  done
  case "$open" in true|false) ;; *) _rt_anomaly "state unreadable"; return 0 ;; esac
  mins=$("${BASH_SOURCE[0]%/*}/../bin/alfred-config" get reply-time-idle-minutes 2>/dev/null)
  case "$mins" in [0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]) ;; *) _rt_anomaly "reply-time-idle-minutes unreadable"; return 0 ;; esac
  t=$((10#$mins * 60))
  if [ "$la" != "-" ]; then
    RT_GAP=$((now - la))
    if [ "$RT_GAP" -lt 0 ]; then _rt_anomaly "last activity is in the future"; return 0; fi
    [ "$RT_GAP" -ge "$t" ] || idle=0
  fi
  if [ "$idle" = 1 ] && [ "$open" = true ] && [ "$line_at" != "-" ]; then
    d=$((now - line_at))
    if [ "$d" -ge 0 ] && [ "$d" -lt "$t" ]; then return 1; fi
  fi
  [ "$idle" = 1 ]
}

# _rt_prune <dir>: files a day old or older (the state files of ended sessions
# and stale temp files). Runs only when a session's file is first created.
_rt_prune() { find "$1" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null; return 0; }

# _rt_merge <session_id> <json object> [jq filter]: merge the object into the stored
# one (temp file, then mv). A missing, garbage or non-object file is replaced; an
# owned key with a bad type or an out of range epoch is dropped; keys of other
# writers are kept. The optional filter runs on the healed object, with $m (the
# object) in scope, before `. + $m` (CCW-184: the audit's list and flag are computed
# there, from the merge's own read). A state that is a directory is refused.
_rt_merge() {
  local f dir tmp prog
  f=$(reply_time_state_file "$1") || return 1
  dir=${f%/*}
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || { echo "reply-timestamp: state directory not writable" >&2; return 1; }
  # mv would move the temp file INTO a directory, so refuse before making one.
  [ -d "$f" ] && { echo "reply-timestamp: state is a directory, not written" >&2; return 1; }
  [ -e "$f" ] || _rt_prune "$dir"
  tmp="$f.tmp.$$"
  # shellcheck disable=SC2016  # $k and $m are jq variables
  prog='def ok: type == "number" and . >= 1000000000 and . <= 9999999999 and . == floor;
        (if type == "object" then . else {} end)
        | reduce ("last_prompt", "last_stop", "last_activity", "line_at") as $k (.; if has($k) and (.[$k] | ok | not) then del(.[$k]) else . end)
        | reduce ("open", "stop_nonempty", "flagged") as $k (.; if has($k) and ((.[$k] | type) != "boolean") then del(.[$k]) else . end)
        | if has("injected") and (((.injected | type) != "array") or (.injected | all(ok) | not)) then del(.injected) else . end
        | ('"${3:-.}"')
        | . + $m'
  if { { { [ -f "$f" ] && jq -c --argjson m "$2" "$prog" "$f" > "$tmp"; } \
         || jq -nc --argjson m "$2" "{} | $prog" > "$tmp"; } && mv -f "$tmp" "$f"; } 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  echo "reply-timestamp: state not written" >&2
  return 1
}

reply_time_note_prompt() {
  local m filter
  [ "${ALFRED_ROLE:-}" = "worker" ] && return 0
  _rt_epoch "${2:-}" || return 1
  m="{\"last_prompt\":$2,\"open\":true"
  [ "${3:-}" = true ] && m="$m,\"line_at\":$2"
  # The audit's fields (CCW-184), computed from the merge's own read. A Stop
  # recorded since the list was last extended is `open` false: restart the list.
  # An injection adds its epoch (newest 8). Every prompt clears the flag.
  # shellcheck disable=SC2016  # $stopped and $m are jq variables
  filter='(.open == false) as $stopped
    | .injected = (if $stopped then [] else (.injected // []) end)
    | if $m.line_at != null then .injected = ((.injected + [$m.line_at]) | unique | .[-8:]) else . end
    | .flagged = false'
  # The gate has already written its one stderr line when it hit an anomaly.
  if [ "${RT_ANOMALY:-0}" = 1 ]; then _rt_merge "${1:-}" "$m}" "$filter" 2>/dev/null; else _rt_merge "${1:-}" "$m}" "$filter"; fi
}

reply_time_note_stop() {
  local now="${1:-}" out sid fin m
  [ "${ALFRED_ROLE:-}" = "worker" ] && return 0
  _rt_epoch "$now" || return 1
  out=$(jq -r '[((.last_assistant_message // "") | if type == "string" and test("\\S") then "1" else "0" end), ((.session_id // "") | tostring)] | join(" ")' "${2:-/dev/null}" 2>/dev/null) || return 0
  fin=${out%% *}
  sid=${out#* }
  [ -n "$sid" ] && [ "$fin" != "$out" ] || return 0
  if [ "$fin" = 1 ]; then
    m="{\"last_stop\":$now,\"stop_nonempty\":true,\"open\":false,\"last_activity\":$now}"
  else
    m="{\"last_stop\":$now,\"stop_nonempty\":false,\"open\":false}"
  fi
  _rt_merge "$sid" "$m"
}

# --- the stamp audit (CCW-184) ----------------------------------------------
# hooks/reply-audit.sh, run by hooks/stop.sh as its third part, uses these. The
# audit owns two more keys of the state file: `injected` (the epochs injected in
# this turn, newest 8, written by reply_time_note_prompt) and `flagged` (a flag
# was issued this turn). A prompt after a recorded Stop (stored open false)
# restarts `injected` and clears `flagged`; the audit itself only ever sets
# `flagged`, and only through reply_time_note_flag.
#   reply_time_audit_off
#       Return 0 when ALFRED_REPLY_TS_AUDIT=0 (exactly 0): the audit is off.
#   reply_time_audit_state <session_id>
#       stdout: "<flagged>|<epoch> <epoch> ..." (flagged true or false, the epochs
#       space separated, possibly none). Return 1 with no output when the state is
#       absent, a directory, not an object, or an owned audit key is unusable (not
#       a boolean, not an array of epochs). Epochs are vetted by _rt_epoch.
#   reply_time_note_flag <session_id>
#       Record flagged:true (merge write). Return 1 when it cannot be written.
#   reply_time_stamp_head <text>
#       stdout: "<Y> <M> <D> <h> <m> <CET|CEST>" of a leading stamp, with or without
#       the "Time now " prefix, after optional whitespace; else nothing, return 1.
#   reply_time_stamp_epoch <Y> <M> <D> <h> <m> <zone>
#       stdout: the epoch of that wall time; the zone token decides the offset (CET
#       +3600, CEST +7200). Return 1 on an invalid date or an epoch out of range.
#   reply_time_verdict <stamp_epoch> <now_epoch> <tolerance_min> [injected_epoch...]
#       stdout: ok | future | stale. Both sides are floored to the minute first.
#       future: the stamp's minute is after now's. ok: within the tolerance of now's
#       minute or of any injected epoch's minute. stale: neither. All arguments must
#       be vetted epochs (the callers do).
reply_time_audit_off() { [ "${ALFRED_REPLY_TS_AUDIT:-}" = 0 ]; }

reply_time_audit_state() {
  local f out e
  f=$(reply_time_state_file "${1:-}") || return 1
  [ -f "$f" ] || return 1
  out=$(jq -r '
    def ok: type == "number" and . >= 1000000000 and . <= 9999999999 and . == floor;
    if type != "object" then "bad"
    elif .flagged != null and (.flagged | type) != "boolean" then "bad"
    elif .injected != null and ((.injected | type) != "array" or (.injected | all(ok) | not)) then "bad"
    else [(.flagged // false | tostring), ((.injected // []) | map(tostring) | join(" "))] | join("|") end' "$f" 2>/dev/null)
  case "$out" in ''|bad) return 1 ;; esac
  for e in ${out#*|}; do _rt_epoch "$e" || return 1; done
  printf '%s\n' "$out"
}

reply_time_note_flag() { _rt_merge "${1:-}" '{"flagged":true}'; }

reply_time_stamp_head() {
  local re='^[[:space:]]*(Time now )?_\[([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}) (CEST|CET)\]_'
  [[ "${1:-}" =~ $re ]] || return 1
  printf '%s %s %s %s %s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" \
    "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}" "${BASH_REMATCH[7]}"
}

reply_time_stamp_epoch() {
  local utc off
  utc=$(date -u -d "$1-$2-$3 $4:$5:00" +%s 2>/dev/null) || return 1
  case "$6" in CEST) off=7200 ;; CET) off=3600 ;; *) return 1 ;; esac
  _rt_epoch "$utc" || return 1
  utc=$((utc - off))
  _rt_epoch "$utc" || return 1
  printf '%s\n' "$utc"
}

reply_time_verdict() {
  local s=$(($1 / 60)) n=$(($2 / 60)) tol=$3 e d
  shift 3
  if [ "$s" -gt "$n" ]; then echo future; return 0; fi
  d=$((n - s))
  if [ "$d" -le "$tol" ]; then echo ok; return 0; fi
  for e in "$@"; do
    d=$((e / 60 - s))
    if [ "${d#-}" -le "$tol" ]; then echo ok; return 0; fi
  done
  echo stale
}
