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

# A malformed override must not make the arithmetic below fail (and, with an
# unguarded comparison, block a turn). Fall back to the default, silently.
case "$SOFT_PCT" in '' | *[!0-9]*) SOFT_PCT=20 ;; esac
case "$HARD_PCT" in '' | *[!0-9]*) HARD_PCT=35 ;; esac

STATE_DIR="${ALFRED_STATE_DIR:-$HOME/.cache/alfred}/context"
SESSION_POINTER="${STATE_DIR}/current-session"

# Absolute path to this script, so the block reason can name a runnable command
# rather than a path relative to whatever cwd the session happens to be in.
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"
[ -n "$SELF" ] || SELF="${BASH_SOURCE[0]}"

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

    if mv -f "$tmp" "$file" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
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
  d. Run: ${SELF} landed
  e. Tell the owner "landed at $1% — clear now" (you cannot clear your own context).
This block fires once per crossing; the next Stop passes either way.
EOF
}

do_check() {
    command -v jq >/dev/null 2>&1 || exit 0

    local payload fields session_id event tool_name agent_id stop_active
    payload=$(cat 2>/dev/null) || exit 0
    [ -n "$payload" ] || exit 0

    # One jq pass for every field we need, so a malformed payload costs one
    # failure not five. Joined on US (0x1f), not tab: tab is an IFS whitespace
    # character, so `read` would collapse two empty fields into one and shift
    # every value left.
    fields=$(printf '%s' "$payload" |
        jq -r '[.session_id // "", .hook_event_name // "", .tool_name // "", .agent_id // "", (.stop_hook_active // false | tostring)] | join("\u001f")' 2>/dev/null) || exit 0
    IFS=$'\037' read -r session_id event tool_name agent_id stop_active <<<"$fields"
    [ -n "${session_id:-}" ] || exit 0

    # Guard against a session_id that would escape the state directory.
    case "$session_id" in
    */* | *..*) exit 0 ;;
    esac

    local state_file="${STATE_DIR}/${session_id}.json"
    local budget_file="${STATE_DIR}/${session_id}.budget"
    [ -f "$state_file" ] || exit 0

    # Persist the session id the hooks are actually firing for, so `landed` can
    # mark the right session when the land skill invokes it without an argument.
    # Written only once a state file exists — on a host without the fleet status
    # line this script still creates nothing.
    if printf '%s\n' "$session_id" >"${SESSION_POINTER}.tmp.$$" 2>/dev/null; then
        mv -f "${SESSION_POINTER}.tmp.$$" "$SESSION_POINTER" 2>/dev/null ||
            rm -f "${SESSION_POINTER}.tmp.$$" 2>/dev/null
    fi

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

    local last_tier last_nag ptu_tier crossing stop_blocked landed
    last_tier=$(read_budget "$budget_file" last_tier)
    last_nag=$(read_budget "$budget_file" last_nag_ts)
    ptu_tier=$(read_budget "$budget_file" ptu_tier)
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
        [ "$tier" = "hard" ] || exit 0 # never block at soft tier

        # Claude Code's own loop guard: true when this Stop is already the result
        # of a hook-blocked stop. Honouring it is what makes "blocks once" hold
        # even if our own per-crossing state is unreadable.
        [ "${stop_active:-false}" = "true" ] && exit 0

        [ "$stop_blocked" = "1" ] && exit 0          # once per crossing
        [ "$landed" -ge "$crossing" ] && exit 0      # landed since the crossing opened

        # Fail open. If the "I have blocked once" flag cannot be persisted, the
        # block would repeat on every Stop and the session could never end — a
        # worse failure than not nagging. Write it, read it back, and only block
        # when it is definitely recorded.
        write_budget "$budget_file" stop_blocked 1 || exit 0
        [ "$(read_budget "$budget_file" stop_blocked)" = "1" ] || exit 0

        stop_reason "$pct_int" >&2
        exit 2
        ;;
    UserPromptSubmit) ;;
    PostToolUse)
        # A sub-agent's tool calls fire PostToolUse under the PARENT session_id,
        # so without a filter every worker turn would be told to land a session it
        # does not own, and would burn the parent's nag slot doing it.
        #
        # The hook input does identify a sub-agent context: `agent_id` and
        # `agent_type` are present ONLY for sub-agent tool calls. `agent_id` is
        # the primary filter. `tool_name` is the secondary one — the parent's own
        # Agent/Task call carries no agent_id, and nagging on "you spawned a
        # worker" is noise at the moment the lead is doing the right thing.
        [ -n "$agent_id" ] && exit 0
        case "$tool_name" in
        Agent | Task) exit 0 ;;
        esac
        # PostToolUse fires far more often than UserPromptSubmit, and a tool
        # result is a worse place to interrupt than a prompt boundary: cap it at
        # once per tier for the whole session. UserPromptSubmit keeps the 10 min
        # cadence, so the reminder still recurs where the model can act on it.
        [ "$ptu_tier" = "$tier" ] && exit 0
        ;;
    *) exit 0 ;;
    esac

    # Rate limit: one injection per tier per NAG_INTERVAL, shared by both events.
    # Escalating soft -> hard resets the timer so the harder message is not
    # swallowed by a soft nag sent moments earlier.
    if [ "$last_tier" = "$tier" ] && [ $((now - last_nag)) -lt "$NAG_INTERVAL" ]; then
        exit 0
    fi

    local text
    if [ "$tier" = "hard" ]; then
        text="CONTEXT BUDGET: ${pct_int}% used (hard threshold ${HARD_PCT}%). LAND NOW: run /alfred-agent:land --mode=light before anything else."
    else
        text="CONTEXT BUDGET: ${pct_int}% used (soft threshold ${SOFT_PCT}%). Land at the next natural boundary: run /alfred-agent:land --mode=light."
    fi

    if [ "$event" = "PostToolUse" ]; then
        write_budget "$budget_file" last_tier "$tier" last_nag_ts "$now" ptu_tier "$tier"
    else
        write_budget "$budget_file" last_tier "$tier" last_nag_ts "$now"
    fi
    emit_context "$event" "$text"
    exit 0
}

# --- landed ----------------------------------------------------------------

do_landed() {
    # Resolution order, most authoritative first. Marking the wrong session is
    # worse than marking none: it would clear another session's Stop block.
    #   1. explicit argument
    #   2. CLAUDE_SESSION_ID from the environment
    #   3. the session id `check` last saw — the session whose hooks are actually
    #      firing against this state dir
    #   4. newest state file, with a warning: ambiguous when several sessions
    #      share the state dir
    local session_id="${1:-${CLAUDE_SESSION_ID:-}}"
    local resolved_via="argument"
    [ -n "${1:-}" ] || resolved_via="CLAUDE_SESSION_ID"

    if [ -z "$session_id" ] && [ -f "$SESSION_POINTER" ]; then
        session_id="$(head -n 1 "$SESSION_POINTER" 2>/dev/null)"
        session_id="${session_id%%[[:space:]]*}"
        [ -n "$session_id" ] && resolved_via="current-session"
    fi

    if [ -z "$session_id" ]; then
        local newest=""
        # shellcheck disable=SC2012 # session ids are UUIDs: no exotic filenames,
        # and `ls -t` is the portable way to order by mtime (find -printf is GNU-only).
        newest=$(ls -t "${STATE_DIR}"/*.json 2>/dev/null | head -n 1) || true
        if [ -n "$newest" ]; then
            session_id=$(basename "$newest" .json)
            resolved_via="newest-state-file"
            echo "context-budget: warning — no session id given and no ${SESSION_POINTER##*/} pointer; falling back to the most recently written state file (${session_id}). Pass the session id explicitly if more than one session shares this state directory." >&2
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
        echo "context-budget: landed at $(awk -v p="$pct" 'BEGIN { printf "%d", int(p + 0.5) }')% (session ${session_id}, via ${resolved_via}) — Stop block cleared."
    else
        echo "context-budget: landed (session ${session_id}, via ${resolved_via}) — Stop block cleared."
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
