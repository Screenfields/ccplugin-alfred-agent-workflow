# shellcheck shell=bash
# Shared reply-time line (CCW-180). Sourced by hooks/reply-timestamp.sh and
# hooks/stop.sh, so the wording and the CET/CEST check live in one place.
# Defines functions only; sets nothing, never exits.
#
#   reply_time_stamp [epoch]
#       stdout: "YYYY-MM-DD HH:MM CEST" (or CET), Europe/Amsterdam. With no
#       argument it is now, or the instant in ALFRED_REPLY_TS_NOW (epoch
#       seconds; the DST test uses it). Return 1, nothing on stdout and one line
#       on stderr, when %Z is not CET or CEST (tzdata missing).
#   reply_time_line [epoch]
#       stdout: the injected text, one line. Return 1 with nothing on stdout
#       when ALFRED_ROLE=worker or reply_time_stamp fails (its stderr line
#       passes through).
#   reply_time_log <source> <entrypoint> <owner: true|false|null> <emitted: true|false>
#       Appends {ts, source, entrypoint, owner, emitted} to ALFRED_REPLY_TS_LOG
#       when that is set; needs jq; silent on any failure.
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
  printf 'Time now _[%s]_. Start your reply with this time line; if the turn runs longer than a few minutes, use a fresh TZ=Europe/Amsterdam time instead.\n' "$stamp"
}

reply_time_log() {
  [ -n "${ALFRED_REPLY_TS_LOG:-}" ] || return 0
  jq -cn --arg ts "$(date -u +%FT%TZ 2>/dev/null)" --arg s "${1:-}" --arg e "${2:-}" \
    --argjson o "${3:-null}" --argjson m "${4:-false}" \
    '{ts: $ts, source: $s, entrypoint: $e, owner: $o, emitted: $m}' >> "$ALFRED_REPLY_TS_LOG" 2>/dev/null
  return 0
}
