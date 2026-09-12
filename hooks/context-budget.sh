#!/usr/bin/env bash
# context-budget.sh — actuator for the context budget rule.
#
# The lead lands and clears at ~20% context usage. No hook event carries context
# usage, so the fleet status line (alfred-devbox share/alfred/statusline-command.sh)
# writes it to a state file; this script reads that file and turns it into
# in-session pressure.
#
#   check   read a hook payload on stdin, inject a reminder (UserPromptSubmit /
#           PostToolUse) or block the turn once (Stop).
#   landed  write the landed marker, clearing the Stop block for this crossing.
#
# Contract: nothing but the hook JSON ever reaches stdout, and the only non-zero
# exit is the intentional Stop block (exit 2). Any other problem is silent.

set -uo pipefail

SOFT_PCT="${ALFRED_CONTEXT_SOFT_PCT:-20}"
HARD_PCT="${ALFRED_CONTEXT_HARD_PCT:-35}"
STALE_SECONDS=7200 # 2 h — an older reading says nothing about the current turn
NAG_INTERVAL=600   # 10 min — one injection per tier per session

STATE_DIR="${ALFRED_STATE_DIR:-$HOME/.cache/alfred}/context"

# --- helpers ---------------------------------------------------------------

now_epoch() { date +%s; }

# Read key=value state; missing keys read as empty.
read_budget() {
    local file="$1" key="$2" line
    [ -f "$file" ] || return 0
    line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1) || true
    printf '%s' "${line#*=}"
}

write_budget() {
    # write_budget <file> <key> <value> [<key> <value> ...] — replaces those
    # keys, keeps the rest, atomically. Best-effort: silent on any failure.
    local file="$1"
    shift
    local tmp="${file}.tmp.$$"
    local -a keys=() pairs=()
    local k line skip existing

    while [ "$#" -ge 2 ]; do
        keys+=("$1")
        pairs+=("$1=$2")
        shift 2
    done

    mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
    : >"$tmp" 2>/dev/null || return 0

    if [ -f "$file" ]; then
        while IFS= read -r line; do
            k="${line%%=*}"
            skip=0
            for existing in "${keys[@]}"; do
                if [ "$k" = "$existing" ]; then
                    skip=1
                    break
                fi
            done
            [ "$skip" = 0 ] && printf '%s\n' "$line" >>"$tmp"
        done <"$file"
    fi

    for line in "${pairs[@]}"; do
        printf '%s\n' "$line" >>"$tmp"
    done

    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    return 0
}

# --- check -----------------------------------------------------------------

emit_context() {
    # emit_context <hookEventName> <text>
    jq -cn \
        --arg event "$1" \
        --arg ctx "$2" \
        '{hookSpecificOutput: {hookEventName: $event, additionalContext: $ctx}}'
}

stop_reason() {
    # stop_reason <pct>
    cat <<EOF
CONTEXT BUDGET: $1% used — above the hard threshold of ${HARD_PCT}%. This turn cannot end
until the session is landed. Run /alfred-agent:land --mode=light now:
  a. Offload every decision/state item of this session to its GitHub issue (comment),
     and knowledge/background to Metis via capture_note.
  b. Prune the handover memory to pointers only (issue URL, capture id).
  c. Push all trees; remove worker worktrees.
  d. Run hooks/context-budget.sh landed.
  e. Tell the owner "landed at $1% — clear now" (you cannot clear your own context).
This block fires once per crossing; the next Stop passes either way.
EOF
}

do_check() {
    command -v jq >/dev/null 2>&1 || exit 0

    local payload session_id event
    payload=$(cat 2>/dev/null) || exit 0
    [ -n "$payload" ] || exit 0

    session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
    event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null) || exit 0
    [ -n "$session_id" ] || exit 0

    # Guard against a session_id that would escape the state directory.
    case "$session_id" in
    */* | *..*) exit 0 ;;
    esac

    local state_file="${STATE_DIR}/${session_id}.json"
    local budget_file="${STATE_DIR}/${session_id}.budget"
    [ -f "$state_file" ] || exit 0

    local pct ts now
    pct=$(jq -r '.pct // empty' "$state_file" 2>/dev/null) || exit 0
    ts=$(jq -r '.ts // empty' "$state_file" 2>/dev/null) || exit 0
    case "$pct" in '' | *[!0-9.]*) exit 0 ;; esac
    case "$ts" in '' | *[!0-9]*) exit 0 ;; esac

    now=$(now_epoch)
    [ $((now - ts)) -le "$STALE_SECONDS" ] || exit 0

    # Round to a whole percent; compare and display the same number.
    local pct_int
    pct_int=$(awk -v p="$pct" 'BEGIN { printf "%d", int(p + 0.5) }')

    local tier=""
    if [ "$pct_int" -ge "$HARD_PCT" ]; then
        tier="hard"
    elif [ "$pct_int" -ge "$SOFT_PCT" ]; then
        tier="soft"
    fi

    local last_tier last_nag crossing stop_blocked landed
    last_tier=$(read_budget "$budget_file" last_tier)
    last_nag=$(read_budget "$budget_file" last_nag_ts)
    crossing=$(read_budget "$budget_file" crossing_ts)
    stop_blocked=$(read_budget "$budget_file" stop_blocked)
    landed=$(read_budget "$budget_file" landed_ts)
    [ -n "$last_nag" ] || last_nag=0
    [ -n "$crossing" ] || crossing=0
    [ -n "$stop_blocked" ] || stop_blocked=0
    [ -n "$landed" ] || landed=0

    if [ "$tier" = "hard" ]; then
        # A crossing opens when the session first reaches the hard tier and stays
        # open until usage drops back below it (a fresh crossing re-arms Stop).
        if [ "$crossing" = "0" ]; then
            crossing="$now"
            stop_blocked=0
            write_budget "$budget_file" crossing_ts "$crossing" stop_blocked "$stop_blocked"
        fi
    elif [ "$crossing" != "0" ]; then
        crossing=0
        stop_blocked=0
        write_budget "$budget_file" crossing_ts 0 stop_blocked 0
    fi

    [ -n "$tier" ] || exit 0

    case "$event" in
    Stop)
        [ "$tier" = "hard" ] || exit 0           # never block at soft tier
        [ "$stop_blocked" = "1" ] && exit 0      # once per crossing, never twice running
        [ "$landed" -ge "$crossing" ] && exit 0  # landed since the crossing opened
        write_budget "$budget_file" stop_blocked 1
        stop_reason "$pct_int" >&2
        exit 2
        ;;
    UserPromptSubmit | PostToolUse) ;;
    *) exit 0 ;;
    esac

    # Rate limit: one injection per tier per NAG_INTERVAL. Escalating soft -> hard
    # resets the timer so the harder message is not swallowed.
    if [ "$last_tier" = "$tier" ] && [ $((now - last_nag)) -lt "$NAG_INTERVAL" ]; then
        exit 0
    fi

    local text
    if [ "$tier" = "hard" ]; then
        text="CONTEXT BUDGET: ${pct_int}% used (hard threshold ${HARD_PCT}%). LAND NOW: run /alfred-agent:land --mode=light before anything else."
    else
        text="CONTEXT BUDGET: ${pct_int}% used (soft threshold ${SOFT_PCT}%). Land at the next natural boundary: run /alfred-agent:land --mode=light."
    fi

    write_budget "$budget_file" last_tier "$tier" last_nag_ts "$now"
    emit_context "$event" "$text"
    exit 0
}

# --- landed ----------------------------------------------------------------

do_landed() {
    local session_id="${1:-${CLAUDE_SESSION_ID:-}}"

    if [ -z "$session_id" ]; then
        # Fall back to the most recently written state file — the session that
        # produced the last assistant message is the one doing the landing.
        local newest=""
        # shellcheck disable=SC2012 # session ids are UUIDs: no exotic filenames,
        # and `ls -t` is the portable way to order by mtime (find -printf is GNU-only).
        newest=$(ls -t "${STATE_DIR}"/*.json 2>/dev/null | head -n 1) || true
        if [ -n "$newest" ]; then
            session_id=$(basename "$newest" .json)
        fi
    fi

    if [ -z "$session_id" ]; then
        echo "context-budget: no session state found — nothing to mark (landing itself is unaffected)."
        exit 0
    fi

    case "$session_id" in
    */* | *..*)
        echo "context-budget: refusing session id '${session_id}'."
        exit 0
        ;;
    esac

    mkdir -p "$STATE_DIR" 2>/dev/null || true
    local budget_file="${STATE_DIR}/${session_id}.budget"
    local now
    now=$(now_epoch)
    write_budget "$budget_file" landed_ts "$now" stop_blocked 0

    local pct=""
    if [ -f "${STATE_DIR}/${session_id}.json" ] && command -v jq >/dev/null 2>&1; then
        pct=$(jq -r '.pct // empty' "${STATE_DIR}/${session_id}.json" 2>/dev/null) || pct=""
    fi
    if [ -n "$pct" ]; then
        echo "context-budget: landed at $(awk -v p="$pct" 'BEGIN { printf "%d", int(p + 0.5) }')% (session ${session_id}) — Stop block cleared."
    else
        echo "context-budget: landed (session ${session_id}) — Stop block cleared."
    fi
    exit 0
}

# --- dispatch --------------------------------------------------------------

case "${1:-}" in
check) do_check ;;
landed)
    shift
    do_landed "${1:-}"
    ;;
*)
    echo "usage: context-budget.sh {check|landed [session_id]}" >&2
    exit 0
    ;;
esac
