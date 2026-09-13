#!/usr/bin/env bash
# context-budget.sh — actuator for the context budget rule.
#
# The lead lands and clears once the session has burned its token budget. No hook
# event carries context usage, so the fleet status line (alfred-devbox
# share/alfred/statusline-command.sh) writes it to a state file; this script reads
# that file, turns it into in-session pressure, and — once the session has landed
# with --clear/--compact — types the clear into the session's own tmux pane.
#
# Thresholds are in TOKENS, not percent. Degradation and cost scale with the
# absolute number of tokens in the window, so a percentage silently moves the
# goalposts whenever the window size changes (20% of 1M is 200k). The older
# percentage thresholds (ALFRED_CONTEXT_SOFT_PCT / _HARD_PCT) survive only as a
# fallback for status lines that write no `used` field, or write `used: 0`.
#
#   check         read a hook payload on stdin: inject a reminder
#                 (UserPromptSubmit / PostToolUse), block the turn once (Stop), or
#                 spawn the detached self-clear sender (Stop, after a landing).
#   landed        write the landed marker, clearing the Stop block for this
#                 crossing, and record whether the session should self-clear.
#   sender        detached child spawned by the Stop hook: wait for an idle input
#                 box, then type /clear or /compact into the pane. Not for humans.
#   session-start read a SessionStart payload; after a self-clear, inject one line
#                 telling the fresh session where to pick up.
#   pre-compact   read a PreCompact payload; record a harness auto-compaction so
#                 the next prompt is told the handover may be incomplete.
#
# Contract: nothing but the hook JSON ever reaches stdout, and the only non-zero
# exit is the intentional Stop block (exit 2). Any other problem is silent.

set -uo pipefail

SOFT_TOKENS="${ALFRED_CONTEXT_SOFT_TOKENS:-80000}"
HARD_TOKENS="${ALFRED_CONTEXT_HARD_TOKENS:-120000}"
SOFT_PCT="${ALFRED_CONTEXT_SOFT_PCT:-20}"
HARD_PCT="${ALFRED_CONTEXT_HARD_PCT:-35}"
STALE_SECONDS=7200  # 2 h — an older reading says nothing about the current turn
NAG_INTERVAL=600    # 10 min — one injection per tier per session
SENDER_DEADLINE=90  # s the sender waits for an idle input box before giving up
SENDER_POLL=2       # s between idle polls; idle must hold for two in a row
CLEAR_MAX_ATTEMPTS=2
HANDOVER_WINDOW=900 # 15 min — an older marker says nothing about this start
SENDER_LOG="/dev/null"

# A malformed override must not make the arithmetic below fail (and, with an
# unguarded comparison, block a turn). Fall back to the default, silently.
case "$SOFT_TOKENS" in '' | *[!0-9]*) SOFT_TOKENS=80000 ;; esac
case "$HARD_TOKENS" in '' | *[!0-9]*) HARD_TOKENS=120000 ;; esac
case "$SOFT_PCT" in '' | *[!0-9]*) SOFT_PCT=20 ;; esac
case "$HARD_PCT" in '' | *[!0-9]*) HARD_PCT=35 ;; esac

STATE_DIR="${ALFRED_STATE_DIR:-$HOME/.cache/alfred}/context"
SESSION_POINTER="${STATE_DIR}/current-session"
LAST_CLEAR="${STATE_DIR}/last-clear.json"

# Absolute path to this script, so the block reason can name a runnable command
# rather than a path relative to whatever cwd the session happens to be in — and
# so the Stop hook can spawn the sender by absolute path.
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

usage_phrase() {
    # usage_phrase <used> <pct_int> — report the budget in the unit the tier was
    # actually decided in, so the number shown is the number that was compared.
    if [ "$1" -gt 0 ]; then
        printf '%s tokens (%s%%)' "$1" "$2"
    else
        printf '%s%%' "$2"
    fi
}

threshold_phrase() {
    # threshold_phrase <used> <tier>
    if [ "$1" -gt 0 ]; then
        if [ "$2" = "hard" ]; then
            printf '%s tokens' "$HARD_TOKENS"
        else
            printf '%s tokens' "$SOFT_TOKENS"
        fi
    else
        if [ "$2" = "hard" ]; then
            printf '%s%%' "$HARD_PCT"
        else
            printf '%s%%' "$SOFT_PCT"
        fi
    fi
}

emit_context() {
    # emit_context <hookEventName> <text>
    jq -cn \
        --arg event "$1" \
        --arg ctx "$2" \
        '{hookSpecificOutput: {hookEventName: $event, additionalContext: $ctx}}'
}

stop_reason() {
    # stop_reason <usage phrase> <threshold phrase>
    cat <<EOF
CONTEXT BUDGET: $1 used — above the hard threshold of $2. This turn cannot end
until the session is landed. Run /alfred-agent:land --mode=light now:
  a. Offload every decision/state item of this session to its GitHub issue (comment),
     and knowledge/background to Metis via capture_note.
  b. Prune the handover memory to pointers only (issue URL, capture id).
  c. Push all trees; remove worker worktrees.
  d. Run: ${SELF} landed --clear --summary "<one line: what was landed, where to pick up>"
  e. End the turn with one short line: "landed at $1 — clearing now". The Stop hook
     types /clear into this pane once the input box is idle.
This block fires once per crossing; the next Stop passes either way.
EOF
}

# --- self-clear (Stop side) -------------------------------------------------

stop_self_clear() {
    # stop_self_clear <session_id> <budget_file> — runs only after the Stop block
    # logic has decided not to block. Either spawns the detached sender and stays
    # silent, or explains once why this session must be cleared by hand.
    local session_id="$1" budget_file="$2"
    local mode attempts

    mode=$(read_budget "$budget_file" clear_mode)
    case "$mode" in clear | compact) ;; *) return 0 ;; esac

    attempts=$(read_budget "$budget_file" clear_attempts)
    case "$attempts" in '' | *[!0-9]*) attempts=0 ;; esac

    if [ -z "${TMUX_PANE:-}" ] || ! command -v tmux >/dev/null 2>&1; then
        # Typing into the pane is the only path there is: without tmux the
        # landing still stands, but the clear is the owner's to make.
        write_budget "$budget_file" clear_mode none
        emit_context Stop "CONTEXT BUDGET: self-clear is not possible in this session (no tmux pane). Ask the owner to run /clear now; the landing is complete."
        exit 0
    fi

    if [ "$attempts" -ge "$CLEAR_MAX_ATTEMPTS" ]; then
        write_budget "$budget_file" clear_mode none
        emit_context Stop "CONTEXT BUDGET: self-clear gave up after ${CLEAR_MAX_ATTEMPTS} attempts — the input box never went idle in time. Ask the owner to run /clear now; the landing is complete."
        exit 0
    fi

    attempts=$((attempts + 1))
    write_budget "$budget_file" clear_attempts "$attempts" sender_ts "$(now_epoch)"

    # Fully detached: the Stop hook must return immediately, and the child has to
    # outlive it to type into the pane the hook is ending a turn in.
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$SELF" sender "$session_id" "$TMUX_PANE" "$mode" >/dev/null 2>&1 </dev/null &
    else
        nohup "$SELF" sender "$session_id" "$TMUX_PANE" "$mode" >/dev/null 2>&1 </dev/null &
    fi
    exit 0
}

# --- check -----------------------------------------------------------------

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
        jq -r '[.session_id // "", .hook_event_name // "", .tool_name // "", .agent_id // "", (.stop_hook_active // false | tostring)] | join("")' 2>/dev/null) || exit 0
    IFS=$'\037' read -r session_id event tool_name agent_id stop_active <<<"$fields"
    [ -n "${session_id:-}" ] || exit 0

    # Guard against a session_id that would escape the state directory.
    case "$session_id" in
    */* | *..*) exit 0 ;;
    esac

    local state_file="${STATE_DIR}/${session_id}.json"
    local budget_file="${STATE_DIR}/${session_id}.budget"
    local now
    now=$(now_epoch)

    # The prompt timestamp is the self-clear race guard: a prompt submitted after
    # the landing means the context is no longer landed, so a queued clear must
    # abort. Recorded only where a budget file already exists — on a host without
    # the fleet status line this script still creates nothing.
    if [ "$event" = "UserPromptSubmit" ] && [ -f "$budget_file" ]; then
        write_budget "$budget_file" last_prompt_ts "$now"
    fi

    local have_state=0 pct_int=0 used=0 tier="" pct ts
    if [ -f "$state_file" ]; then
        # Persist the session id the hooks are actually firing for, so `landed`
        # can mark the right session when the land skill invokes it without an
        # argument. Written only once a state file exists — on a host without the
        # fleet status line this script still creates nothing.
        if printf '%s\n' "$session_id" >"${SESSION_POINTER}.tmp.$$" 2>/dev/null; then
            mv -f "${SESSION_POINTER}.tmp.$$" "$SESSION_POINTER" 2>/dev/null ||
                rm -f "${SESSION_POINTER}.tmp.$$" 2>/dev/null
        fi

        pct=$(jq -r '.pct // empty' "$state_file" 2>/dev/null) || pct=""
        ts=$(jq -r '.ts // empty' "$state_file" 2>/dev/null) || ts=""
        used=$(jq -r '.used // empty' "$state_file" 2>/dev/null) || used=""
        case "$pct" in '' | *[!0-9.]*) pct="" ;; esac
        case "$ts" in '' | *[!0-9]*) ts="" ;; esac
        case "$used" in '' | *[!0-9]*) used=0 ;; esac

        if [ -n "$pct" ] && [ -n "$ts" ] && [ $((now - ts)) -le "$STALE_SECONDS" ]; then
            have_state=1
            # Round to a whole percent; compare and display the same number.
            pct_int=$(awk -v p="$pct" 'BEGIN { printf "%d", int(p + 0.5) }')
            if [ "$used" -gt 0 ]; then
                if [ "$used" -ge "$HARD_TOKENS" ]; then
                    tier="hard"
                elif [ "$used" -ge "$SOFT_TOKENS" ]; then
                    tier="soft"
                fi
            else
                # Fallback only: a status line too old to report a token count.
                if [ "$pct_int" -ge "$HARD_PCT" ]; then
                    tier="hard"
                elif [ "$pct_int" -ge "$SOFT_PCT" ]; then
                    tier="soft"
                fi
            fi
        fi
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

    if [ "$have_state" = "1" ]; then
        if [ "$tier" = "hard" ]; then
            # A crossing opens when the session first reaches the hard tier and
            # stays open until usage drops back below it (a fresh crossing
            # re-arms Stop).
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
    fi

    if [ "$event" = "Stop" ]; then
        # `stop_hook_active` is Claude Code's own loop guard: true when this Stop
        # is already the result of a hook-blocked stop. Honouring it is what makes
        # "blocks once" hold even if our own per-crossing state is unreadable.
        if [ "$have_state" = "1" ] && [ "$tier" = "hard" ] &&
            [ "${stop_active:-false}" != "true" ] &&
            [ "$stop_blocked" != "1" ] && [ "$landed" -lt "$crossing" ]; then
            # Fail open. If the "I have blocked once" flag cannot be persisted,
            # the block would repeat on every Stop and the session could never
            # end — a worse failure than not nagging. Write it, read it back, and
            # only block when it is definitely recorded.
            if write_budget "$budget_file" stop_blocked 1 &&
                [ "$(read_budget "$budget_file" stop_blocked)" = "1" ]; then
                stop_reason "$(usage_phrase "$used" "$pct_int")" "$(threshold_phrase "$used" hard)" >&2
                exit 2
            fi
        fi
        # Not blocking: this is where a landed session clears itself.
        stop_self_clear "$session_id" "$budget_file"
        exit 0
    fi

    if [ "$event" = "UserPromptSubmit" ]; then
        # A harness auto-compaction is the failure signal for this whole rule: the
        # budget ran out before a landing did. Say so once, at any tier.
        local ac ac_nag ac_at
        ac=$(read_budget "$budget_file" autocompact_ts)
        ac_nag=$(read_budget "$budget_file" autocompact_nagged_ts)
        if [ -n "$ac" ] && [ "$ac" != "$ac_nag" ]; then
            if [ "$used" -gt 0 ]; then
                ac_at="${used} tokens"
            else
                ac_at="an unknown number of tokens"
            fi
            write_budget "$budget_file" autocompact_nagged_ts "$ac"
            emit_context UserPromptSubmit "CONTEXT BUDGET: the harness auto-compacted this session at ${ac_at} before a landing ran. The handover may be incomplete — reconcile decisions from the transcript before continuing."
            exit 0
        fi
    fi

    [ "$have_state" = "1" ] || exit 0
    [ -n "$tier" ] || exit 0

    case "$event" in
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

    local text usage threshold
    usage=$(usage_phrase "$used" "$pct_int")
    threshold=$(threshold_phrase "$used" "$tier")
    if [ "$tier" = "hard" ]; then
        text="CONTEXT BUDGET: ${usage} used — hard threshold ${threshold}. LAND NOW: run /alfred-agent:land --mode=light before anything else."
    else
        text="CONTEXT BUDGET: ${usage} used — soft threshold ${threshold}. Land at the next natural boundary: run /alfred-agent:land --mode=light."
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
    local mode="none" summary="" arg_session=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
        --clear) mode="clear" ;;
        --compact) mode="compact" ;;
        --no-clear) mode="none" ;;
        --summary)
            shift
            summary="${1:-}"
            ;;
        --summary=*) summary="${1#--summary=}" ;;
        --) ;;
        -*) ;; # unknown flag: ignored rather than fail a landing over it
        *) arg_session="$1" ;;
        esac
        shift || break
    done

    # A multi-line summary would corrupt the key=value budget file and, typed into
    # the pane, would submit halfway. One line, always.
    summary=$(printf '%s' "$summary" | tr '\n\r\t' '   ')

    # Resolution order, most authoritative first. Marking the wrong session is
    # worse than marking none: it would clear another session's Stop block.
    #   1. explicit argument
    #   2. CLAUDE_SESSION_ID from the environment
    #   3. the session id `check` last saw — the session whose hooks are actually
    #      firing against this state dir
    #   4. newest state file, with a warning: ambiguous when several sessions
    #      share the state dir
    local session_id="${arg_session:-${CLAUDE_SESSION_ID:-}}"
    local resolved_via="argument"
    [ -n "$arg_session" ] || resolved_via="CLAUDE_SESSION_ID"

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
    write_budget "$budget_file" landed_ts "$now" stop_blocked 0 \
        clear_mode "$mode" clear_summary "$summary" clear_attempts 0

    local state_file="${STATE_DIR}/${session_id}.json"
    local at="" pct="" used=""
    if [ -f "$state_file" ] && command -v jq >/dev/null 2>&1; then
        pct=$(jq -r '.pct // empty' "$state_file" 2>/dev/null) || pct=""
        used=$(jq -r '.used // empty' "$state_file" 2>/dev/null) || used=""
        case "$used" in '' | *[!0-9]*) used=0 ;; esac
        case "$pct" in '' | *[!0-9.]*) pct="" ;; esac
        if [ -n "$pct" ]; then
            at=" at $(usage_phrase "$used" "$(awk -v p="$pct" 'BEGIN { printf "%d", int(p + 0.5) }')")"
        fi
    fi

    local tail_msg
    case "$mode" in
    clear) tail_msg="clear_mode=clear — the Stop hook types /clear into this pane once the input box is idle." ;;
    compact) tail_msg="clear_mode=compact — the Stop hook types /compact into this pane once the input box is idle." ;;
    *) tail_msg="clear_mode=none — no self-clear; the owner clears." ;;
    esac
    [ -n "$summary" ] && tail_msg="${tail_msg} clear_summary=\"${summary}\""

    echo "context-budget: landed${at} (session ${session_id}, via ${resolved_via}) — Stop block cleared; ${tail_msg} clear_attempts=0."
    exit 0
}

# --- sender ----------------------------------------------------------------

sender_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$SENDER_LOG" 2>/dev/null
}

pane_idle() {
    # pane_idle <pane> — the input box is empty (cursor at column 2) and the
    # session is not mid-turn ("esc to interrupt" absent from the last lines).
    local pane="$1" cx busy
    cx=$(tmux display-message -p -t "$pane" '#{cursor_x}' 2>/dev/null) || return 1
    [ "$cx" = "2" ] || return 1
    busy=$(tmux capture-pane -p -t "$pane" 2>/dev/null | tail -4 | grep -c 'esc to interrupt') || busy=0
    [ "$busy" = "0" ]
}

do_sender() {
    local session_id="${1:-}" pane="${2:-}" mode="${3:-}"
    [ -n "$session_id" ] && [ -n "$pane" ] || exit 0
    case "$session_id" in */* | *..*) exit 0 ;; esac
    case "$mode" in clear | compact) ;; *) exit 0 ;; esac
    command -v tmux >/dev/null 2>&1 || exit 0

    local budget_file="${STATE_DIR}/${session_id}.budget"
    SENDER_LOG="${STATE_DIR}/${session_id}.sender.log"
    sender_log "start pane=${pane} mode=${mode} deadline=${SENDER_DEADLINE}s"

    local deadline idle=0 lp landed now keys summary
    deadline=$(($(now_epoch) + SENDER_DEADLINE))

    while :; do
        now=$(now_epoch)
        [ "$now" -lt "$deadline" ] || break

        # Race guard: a prompt submitted after the landing means the session has
        # picked work up again and the context is no longer landed. Clearing then
        # would destroy live work.
        lp=$(read_budget "$budget_file" last_prompt_ts)
        landed=$(read_budget "$budget_file" landed_ts)
        case "$lp" in '' | *[!0-9]*) lp=0 ;; esac
        case "$landed" in '' | *[!0-9]*) landed=0 ;; esac
        if [ "$lp" -gt "$landed" ]; then
            sender_log "abort: prompt at ${lp} came after the landing at ${landed}"
            write_budget "$budget_file" clear_aborted "new-prompt" clear_mode none
            exit 0
        fi

        if pane_idle "$pane"; then
            idle=$((idle + 1))
        else
            idle=0
        fi

        if [ "$idle" -ge 2 ]; then
            summary=$(read_budget "$budget_file" clear_summary)
            if [ "$mode" = "compact" ]; then
                if [ -n "$summary" ]; then
                    keys="/compact Preserve: ${summary}"
                else
                    keys="/compact"
                fi
            else
                keys="/clear"
            fi

            # Written before the keystrokes, not after: the session clears within
            # milliseconds of the Enter, and its SessionStart hook has to find
            # this file already there.
            if command -v jq >/dev/null 2>&1; then
                if jq -cn --arg p "$session_id" --arg m "$mode" --arg s "$summary" \
                    --argjson ts "$(now_epoch)" \
                    '{prev_session_id:$p,mode:$m,summary:$s,ts:$ts}' >"${LAST_CLEAR}.tmp.$$" 2>/dev/null; then
                    mv -f "${LAST_CLEAR}.tmp.$$" "$LAST_CLEAR" 2>/dev/null ||
                        rm -f "${LAST_CLEAR}.tmp.$$" 2>/dev/null
                else
                    rm -f "${LAST_CLEAR}.tmp.$$" 2>/dev/null
                fi
            fi

            sender_log "idle confirmed — sending ${mode}"
            # Two send-keys a second apart: typing the command opens the slash
            # autocomplete, and an Enter in the same burst can land on the menu
            # before it has settled.
            tmux send-keys -t "$pane" "$keys" 2>/dev/null
            sleep 1
            tmux send-keys -t "$pane" C-m 2>/dev/null
            write_budget "$budget_file" cleared_ts "$(now_epoch)" clear_mode none
            sender_log "sent"
            exit 0
        fi

        sleep "$SENDER_POLL"
    done

    # Leave clear_mode as it is: the next Stop gets the second and last attempt.
    sender_log "timeout after ${SENDER_DEADLINE}s — the input box never went idle"
    exit 0
}

# --- session-start ----------------------------------------------------------

do_session_start() {
    command -v jq >/dev/null 2>&1 || exit 0

    local payload source
    payload=$(cat 2>/dev/null) || exit 0
    [ -n "$payload" ] || exit 0
    source=$(printf '%s' "$payload" | jq -r '.source // ""' 2>/dev/null) || exit 0
    case "$source" in clear | compact) ;; *) exit 0 ;; esac

    [ -f "$LAST_CLEAR" ] || exit 0

    local ts now prev mode summary when
    ts=$(jq -r '.ts // empty' "$LAST_CLEAR" 2>/dev/null) || exit 0
    case "$ts" in '' | *[!0-9]*) exit 0 ;; esac
    now=$(now_epoch)
    if [ $((now - ts)) -gt "$HANDOVER_WINDOW" ]; then
        rm -f "$LAST_CLEAR" 2>/dev/null
        exit 0
    fi

    prev=$(jq -r '.prev_session_id // ""' "$LAST_CLEAR" 2>/dev/null)
    mode=$(jq -r '.mode // ""' "$LAST_CLEAR" 2>/dev/null)
    summary=$(jq -r '.summary // ""' "$LAST_CLEAR" 2>/dev/null)
    when=$(date -d "@${ts}" '+%H:%M' 2>/dev/null) || when=""

    printf 'CONTEXT BUDGET: previous session %s self-%sed at %s local after landing — "%s". Continue from the handover memory and GitHub issues, not from recollection of the previous conversation.\n' \
        "$prev" "$mode" "$when" "$summary"
    rm -f "$LAST_CLEAR" 2>/dev/null
    exit 0
}

# --- pre-compact ------------------------------------------------------------

do_pre_compact() {
    command -v jq >/dev/null 2>&1 || exit 0

    local payload trigger session_id
    payload=$(cat 2>/dev/null) || exit 0
    [ -n "$payload" ] || exit 0
    trigger=$(printf '%s' "$payload" | jq -r '.trigger // ""' 2>/dev/null) || exit 0
    # Never block a compaction; only an automatic one is a signal at all.
    [ "$trigger" = "auto" ] || exit 0

    session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
    if [ -z "$session_id" ] && [ -f "$SESSION_POINTER" ]; then
        session_id="$(head -n 1 "$SESSION_POINTER" 2>/dev/null)"
        session_id="${session_id%%[[:space:]]*}"
    fi
    [ -n "$session_id" ] || exit 0
    case "$session_id" in */* | *..*) exit 0 ;; esac

    write_budget "${STATE_DIR}/${session_id}.budget" autocompact_ts "$(now_epoch)"
    exit 0
}

# --- dispatch --------------------------------------------------------------

case "${1:-}" in
check) do_check ;;
landed)
    shift
    do_landed "$@"
    ;;
sender)
    shift
    do_sender "$@"
    ;;
session-start) do_session_start ;;
pre-compact) do_pre_compact ;;
*)
    echo "usage: context-budget.sh {check | landed [--clear|--compact|--no-clear] [--summary <line>] [session_id] | sender <session_id> <pane> <mode> | session-start | pre-compact}" >&2
    exit 0
    ;;
esac
