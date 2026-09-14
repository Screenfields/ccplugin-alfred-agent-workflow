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
# Thresholds are measured ABOVE THE SESSION BASELINE. A fresh session is not at
# zero: system prompt, CLAUDE.md, memory index, tool and MCP schemas and the
# SessionStart injections are all in the window before the conversation has said
# anything (~86k tokens on the hub, 2026-09-14). `session-start` arms a baseline;
# the first `check` with a usable reading records `used` as this session's floor,
# and every tier is decided on `used - baseline`. Where no baseline was armed —
# a session that started before this build, or one whose SessionStart hook never
# ran — the baseline stays 0 and the thresholds apply to `used` exactly as they
# did before.
#
# The hard tier does not block a turn the owner is standing in front of. Every
# UserPromptSubmit stamps `last_prompt_ts`; while that is younger than
# ALFRED_CONTEXT_INTERACTIVE_SECONDS the Stop hook nags and lets the turn end,
# instead of blocking and arming the self-clear. Wake-bridge wakes arrive as
# Monitor output, not as user prompts, so an autonomous session keeps the strict
# behaviour. Above ALFRED_CONTEXT_CEILING_TOKENS (also measured above the
# baseline) even a live conversation lands.
#
#   check         read a hook payload on stdin: inject a reminder
#                 (UserPromptSubmit / PostToolUse), block the turn once (Stop), or
#                 spawn the detached self-clear/self-restart sender (Stop, after a
#                 landing).
#   landed        write the landed marker, clearing the Stop block for this
#                 crossing, and record whether the session should self-clear,
#                 self-compact, or restart the claude process in place. Arming any
#                 of those three requires a small handover file to already exist
#                 (see HANDOVER_FILE below) unless --no-handover is passed.
#   sender        detached child spawned by the Stop hook: wait for an idle input
#                 box, then type /clear or /compact into the pane, or — for
#                 restart — run the configured restart command. Not for humans.
#   session-start read a SessionStart payload; after a self-clear/compact/restart,
#                 inject one line telling the fresh session where to pick up, and
#                 (independent of that) inject and consume the handover file.
#   pre-compact   read a PreCompact payload; record a harness auto-compaction so
#                 the next prompt is told the handover may be incomplete.
#
# The sender confirms rather than assumes: after the keystrokes it waits for the
# new session's SessionStart hook to consume ${STATE_DIR}/last-clear.json, and only
# then records the clear. A session running a plugin build without that hook has
# nothing to consume the marker, so its clears always read as `unconfirmed` and the
# second attempt is spent on an already-cleared session. That is harmless — the
# second sender finds an idle box and types /clear into a fresh session — but it is
# why an old plugin looks noisier in the sender log than a current one.
#
# Contract: nothing but the hook JSON ever reaches stdout, and the only non-zero
# exit is the intentional Stop block (exit 2). Any other problem is silent.

set -uo pipefail

SOFT_TOKENS="${ALFRED_CONTEXT_SOFT_TOKENS:-80000}"
HARD_TOKENS="${ALFRED_CONTEXT_HARD_TOKENS:-120000}"
SOFT_PCT="${ALFRED_CONTEXT_SOFT_PCT:-20}"
HARD_PCT="${ALFRED_CONTEXT_HARD_PCT:-35}"
# Above the hard tier but with a human prompt this recent, the Stop hook nags
# instead of blocking: the owner is mid-conversation and a self-clear would cut
# them off. Only real UserPromptSubmit events count — a wake-bridge wake is
# Monitor output, so an unattended session never looks interactive.
INTERACTIVE_SECONDS="${ALFRED_CONTEXT_INTERACTIVE_SECONDS:-600}"
# ... but not forever. Above this (measured above the session baseline, like
# every other token threshold) the block fires however live the conversation is.
CEILING_TOKENS="${ALFRED_CONTEXT_CEILING_TOKENS:-200000}"
STALE_SECONDS=7200  # 2 h — an older reading says nothing about the current turn
NAG_INTERVAL=600    # 10 min — one injection per tier per session
# An override exists so the test suite does not have to sit out the real
# window (mirrors CONFIRM_SECONDS below).
SENDER_DEADLINE="${ALFRED_CONTEXT_SENDER_DEADLINE:-90}"  # s the sender waits for an idle input box before giving up
SENDER_POLL=2       # s between idle polls; idle must hold for two in a row
CLEAR_MAX_ATTEMPTS=2
LANDED_GRACE=120    # s — a landing this recent counts for a crossing observed after it
HANDOVER_WINDOW=900 # 15 min — an older marker says nothing about this start
# How long the sender waits for SessionStart to consume the handover marker. An
# override exists so the test suite does not have to sit out the real window.
CONFIRM_SECONDS="${ALFRED_CONTEXT_CONFIRM_SECONDS:-15}"
# How long a single tmux client call may run before being killed. A pane left
# in a tmux mode (copy-mode/view-mode) can swallow a client's request without
# ever answering it — see pane_idle below — so every tmux call in the sender
# path is bounded by this instead of trusting tmux to always respond. An
# override exists so the test suite does not have to sit out the real window.
TMUX_CALL_TIMEOUT="${ALFRED_CONTEXT_TMUX_TIMEOUT:-10}"
SENDER_LOG="/dev/null"

# A malformed override must not make the arithmetic below fail (and, with an
# unguarded comparison, block a turn). Fall back to the default, silently.
case "$SOFT_TOKENS" in '' | *[!0-9]*) SOFT_TOKENS=80000 ;; esac
case "$HARD_TOKENS" in '' | *[!0-9]*) HARD_TOKENS=120000 ;; esac
case "$SOFT_PCT" in '' | *[!0-9]*) SOFT_PCT=20 ;; esac
case "$HARD_PCT" in '' | *[!0-9]*) HARD_PCT=35 ;; esac
case "$INTERACTIVE_SECONDS" in '' | *[!0-9]*) INTERACTIVE_SECONDS=600 ;; esac
case "$CEILING_TOKENS" in '' | *[!0-9]*) CEILING_TOKENS=200000 ;; esac
case "$CONFIRM_SECONDS" in '' | *[!0-9]*) CONFIRM_SECONDS=15 ;; esac
case "$SENDER_DEADLINE" in '' | *[!0-9]*) SENDER_DEADLINE=90 ;; esac
case "$TMUX_CALL_TIMEOUT" in '' | *[!0-9]*) TMUX_CALL_TIMEOUT=10 ;; esac

STATE_DIR="${ALFRED_STATE_DIR:-$HOME/.cache/alfred}/context"
SESSION_POINTER="${STATE_DIR}/current-session"
LAST_CLEAR="${STATE_DIR}/last-clear.json"
# The small handover file the land skill writes before arming a self-clear/
# self-compact/self-restart. Consumed (printed + deleted) by the next
# SessionStart, independent of the last-clear marker above.
HANDOVER_FILE="${STATE_DIR}/handover.md"
HANDOVER_MAX_BYTES=4096
HANDOVER_MAX_AGE=1800 # 30 min — a stale handover is not this landing's handover
RESTART_CMD_DEFAULT="hub-restart"
# Written by the host's boot supervisor before it recreates a session that
# died without landing (crash, OOM-kill, power loss); consumed by the next
# SessionStart. Fields: ts, boot_ts, reason, host.
BOOT_RECOVERY_FILE="${STATE_DIR}/boot-recovery.json"
# Base of Claude Code's per-session background-task directories:
# <dir>/<project-slug>/<session-id>/tasks/<agentId>.output. Overridable so
# tests do not touch the real host path.
CLAUDE_TMP_DIR="${ALFRED_CLAUDE_TMP_DIR:-/tmp/claude-$(id -u)}"
# A background task's transcript file is touched every time the agent appends
# a message. This is the freshness window inside which "not touched recently"
# stops being decent evidence that the agent has finished.
RUNNING_AGENT_WINDOW=60

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

    # A caller that cannot persist state must be able to tell: the Stop block
    # only fires when its flag was definitely written.
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
    : >"$tmp" 2>/dev/null || return 1

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

num_or() {
    # num_or <value> <default> — every number read back from the budget file goes
    # through this. A hand-edited or half-written file must never turn into an
    # arithmetic error on a hook path.
    case "${1:-}" in '' | *[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

write_pointer() {
    # write_pointer <file> <session_id> — atomic, best-effort, silent.
    local file="$1" id="$2"
    if printf '%s\n' "$id" >"${file}.tmp.$$" 2>/dev/null; then
        mv -f "${file}.tmp.$$" "$file" 2>/dev/null || rm -f "${file}.tmp.$$" 2>/dev/null
    fi
}

pane_key() {
    # pane_key <TMUX_PANE> — a filename-safe key for the pane, so two sessions
    # sharing a state directory each get their own session pointer.
    local p="${1:-}"
    p="${p#%}"
    printf '%s' "$p" | tr -c 'A-Za-z0-9_-' '_'
}

usage_phrase() {
    # usage_phrase <used> <pct_int> [baseline] — report the budget in the unit the
    # tier was actually decided in, so the number shown is the number that was
    # compared. With a session baseline recorded, that number is the delta above
    # it; the raw total is kept alongside because it is what the status line shows.
    local baseline
    baseline=$(num_or "${3:-0}" 0)
    if [ "$1" -gt 0 ]; then
        if [ "$baseline" -gt 0 ] && [ "$1" -ge "$baseline" ]; then
            printf '%s tokens this session (%s total, %s%%)' "$(($1 - baseline))" "$1" "$2"
        else
            printf '%s tokens (%s%%)' "$1" "$2"
        fi
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
    case "$mode" in clear | compact | restart) ;; *) return 0 ;; esac

    attempts=$(num_or "$(read_budget "$budget_file" clear_attempts)" 0)

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

    # The prompt timestamp does two jobs. It is the self-clear race guard — a
    # prompt submitted after the landing means the context is no longer landed,
    # so a queued clear must abort — and it is the interactive signal the Stop
    # handler defers on. Recorded only where the session already has state — on a
    # host without the fleet status line this script still creates nothing.
    if [ "$event" = "UserPromptSubmit" ] && { [ -f "$budget_file" ] || [ -f "$state_file" ]; }; then
        write_budget "$budget_file" last_prompt_ts "$now"
    fi

    local have_state=0 pct_int=0 used=0 baseline=0 budget_used=0 tier="" pct ts
    if [ -f "$state_file" ]; then
        # Persist the session id the hooks are actually firing for, so `landed`
        # can mark the right session when the land skill invokes it without an
        # argument. Written only once a state file exists — on a host without the
        # fleet status line this script still creates nothing.
        # The unkeyed pointer is ambiguous the moment two sessions share a state
        # directory, so it is written for old callers only; the pane-keyed one is
        # what `landed` reads first, because a pane hosts exactly one session.
        write_pointer "$SESSION_POINTER" "$session_id"
        if [ -n "${TMUX_PANE:-}" ]; then
            write_pointer "${SESSION_POINTER}.$(pane_key "$TMUX_PANE")" "$session_id"
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

            # The session baseline: what the window already cost before this
            # conversation said anything. `session-start` arms baseline_pending;
            # the first reading after that becomes the floor every token
            # threshold is measured from. Only a fresh reading may set it — a
            # stale one says nothing about this session.
            #
            # Fallback, deliberately: with nothing armed (a session that
            # predates this build, or one whose SessionStart hook never ran) the
            # baseline stays 0 and the tiers are decided on `used` exactly as
            # they were before.
            baseline=$(num_or "$(read_budget "$budget_file" baseline)" 0)
            if [ "$used" -gt 0 ]; then
                if [ "$baseline" = "0" ] &&
                    [ "$(read_budget "$budget_file" baseline_pending)" = "1" ]; then
                    baseline="$used"
                    write_budget "$budget_file" baseline "$baseline" baseline_pending 0
                elif [ "$baseline" -gt "$used" ]; then
                    # Usage below the baseline means the window shrank — a
                    # compaction, in practice. The post-compaction reading is
                    # this session's new floor, exactly as a session start is.
                    baseline="$used"
                    write_budget "$budget_file" baseline "$baseline"
                fi
                budget_used=$((used - baseline))
            fi

            if [ "$used" -gt 0 ]; then
                if [ "$budget_used" -ge "$HARD_TOKENS" ]; then
                    tier="hard"
                elif [ "$budget_used" -ge "$SOFT_TOKENS" ]; then
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
    last_nag=$(num_or "$last_nag" 0)
    crossing=$(num_or "$crossing" 0)
    stop_blocked=$(num_or "$stop_blocked" 0)
    landed=$(num_or "$landed" 0)

    if [ "$have_state" = "1" ]; then
        if [ "$tier" = "hard" ]; then
            # A crossing opens when the session first reaches the hard tier and
            # stays open until usage drops back below it (a fresh crossing
            # re-arms Stop).
            if [ "$crossing" = "0" ]; then
                crossing="$now"
                stop_blocked=0
                # A landing recorded moments before the crossing is first
                # observed belongs to this crossing: the landing turn's own
                # tool calls pushed usage over the line, and the sensor
                # reported it only at the Stop that follows `landed`. Without
                # this, landed_ts < crossing_ts by a second and the Stop blocks
                # a session that has just landed instead of letting it clear.
                if [ "$landed" -gt 0 ] && [ $((now - landed)) -le "$LANDED_GRACE" ]; then
                    crossing="$landed"
                fi
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
            # Interactive deferral. Blocking a turn and typing /clear into the
            # pane is right for an unattended session and wrong for a
            # conversation: the owner loses the thread mid-sentence. While a
            # human prompt is younger than INTERACTIVE_SECONDS, and the session
            # is still under the ceiling, say the same thing and let the turn
            # end — no exit 2, no sender. The per-crossing block flag stays
            # unset, so the block still fires on the first Stop after the
            # conversation goes quiet. Token mode only: the percentage fallback
            # has no ceiling to compare against, so it keeps blocking as before.
            local last_prompt defer_nag
            last_prompt=$(num_or "$(read_budget "$budget_file" last_prompt_ts)" 0)
            if [ "$used" -gt 0 ] && [ "$budget_used" -lt "$CEILING_TOKENS" ] &&
                [ "$last_prompt" -gt 0 ] && [ $((now - last_prompt)) -lt "$INTERACTIVE_SECONDS" ]; then
                defer_nag=$(num_or "$(read_budget "$budget_file" defer_nag_ts)" 0)
                if [ $((now - defer_nag)) -ge "$NAG_INTERVAL" ]; then
                    write_budget "$budget_file" defer_nag_ts "$now"
                    emit_context Stop "CONTEXT BUDGET: $(usage_phrase "$used" "$pct_int" "$baseline") used — above the hard threshold of $(threshold_phrase "$used" hard). Not blocking this turn: the owner prompted less than $((INTERACTIVE_SECONDS / 60)) min ago. Land at the next natural boundary (/alfred-agent:land --mode=light); the turn is blocked once the conversation goes quiet, or above ${CEILING_TOKENS} tokens."
                fi
                exit 0
            fi
            # Fail open. If the "I have blocked once" flag cannot be persisted,
            # the block would repeat on every Stop and the session could never
            # end — a worse failure than not nagging. Write it, read it back, and
            # only block when it is definitely recorded.
            if write_budget "$budget_file" stop_blocked 1 &&
                [ "$(read_budget "$budget_file" stop_blocked)" = "1" ]; then
                stop_reason "$(usage_phrase "$used" "$pct_int" "$baseline")" "$(threshold_phrase "$used" hard)" >&2
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
    usage=$(usage_phrase "$used" "$pct_int" "$baseline")
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

# --- landed ------------------------------------------------------------------
# --- completeness checks (Change 5a) ----------------------------------------

_tree_issue() {
    # _tree_issue <path> <label> — one combined issue line for the git tree at
    # <path>, or nothing at all if it is clean and pushed. "No upstream"
    # counts as unpushed: a branch nobody else can see is not pushed.
    local path="$1" label="$2" problems=""
    if [ ! -d "$path" ]; then
        printf '%s missing: %s\n' "$label" "$path"
        return 0
    fi
    (
        cd "$path" 2>/dev/null || exit 0
        git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            problems="uncommitted changes"
        fi
        local upstream
        upstream=$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null) || upstream=""
        if [ -z "$upstream" ]; then
            [ -n "$problems" ] && problems="${problems}, "
            problems="${problems}no upstream (unpushed)"
        elif [ -n "$(git log '@{u}..' --oneline 2>/dev/null)" ]; then
            [ -n "$problems" ] && problems="${problems}, "
            problems="${problems}unpushed commits"
        fi
        [ -n "$problems" ] && printf '%s (%s): %s\n' "$label" "$problems" "$path"
        exit 0
    )
}

landing_git_issues() {
    # landing_git_issues — one issue per line for the current directory's git
    # tree and every OTHER worktree `git worktree list --porcelain` knows
    # about. A worker worktree still registered is disqualifying on its own —
    # the platform convention (worktree isolation) is that a worker's worktree
    # is gone by the time a landing happens, merged or removed either way.
    command -v git >/dev/null 2>&1 || return 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    _tree_issue "$PWD" "project tree"

    local first=1 line wpath
    while IFS= read -r line; do
        case "$line" in
        "worktree "*)
            wpath="${line#worktree }"
            if [ "$first" = "1" ]; then
                first=0
                continue
            fi
            printf 'worker worktree still present: %s\n' "$wpath"
            _tree_issue "$wpath" "worktree"
            ;;
        esac
    done < <(git worktree list --porcelain 2>/dev/null)
}

landing_running_agent_issues() {
    # landing_running_agent_issues <session_id> — best-effort. A background
    # sub-agent's transcript file is touched every time it appends a message,
    # so a recent mtime is evidence of POSSIBLE activity. It is not proof of
    # absence: a tool call that runs for minutes without writing (e.g. a long
    # Bash command) leaves the file stale while the agent is still very much
    # running. And Claude Code slugs the tasks directory by the session's
    # ORIGINAL launch cwd, not the cwd of a worktree `landed` happens to run
    # from, so a `landed` invoked from inside a worker worktree looks at the
    # wrong directory and finds nothing. This check catches the common case;
    # it is not the authority. The land skill's own Drain step is — it has
    # live visibility into the running Task/Monitor list this static check
    # fundamentally cannot have.
    local session_id="$1"
    [ -n "$session_id" ] || return 0
    local slug tasks_dir now f mtime age base
    slug=$(printf '%s' "$PWD" | tr '/' '-')
    tasks_dir="${CLAUDE_TMP_DIR}/${slug}/${session_id}/tasks"
    [ -d "$tasks_dir" ] || return 0
    now=$(now_epoch)
    for f in "$tasks_dir"/*.output; do
        [ -e "$f" ] || continue
        mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
        age=$((now - mtime))
        if [ "$age" -le "$RUNNING_AGENT_WINDOW" ]; then
            base=$(basename "$f" .output)
            printf 'background agent possibly still running (touched %ss ago): %s\n' "$age" "$base"
        fi
    done
}

do_landed() {
    local mode="none" summary="" arg_session="" no_handover=0 force=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
        --clear) mode="clear" ;;
        --compact) mode="compact" ;;
        --restart) mode="restart" ;;
        --no-clear) mode="none" ;;
        --no-handover) no_handover=1 ;;
        --force) force=1 ;;
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
    # worse than marking none: it would clear another session's Stop block — and,
    # now that a landing can arm a self-clear, type /clear into someone else's
    # pane.
    #   1. explicit argument
    #   2. CLAUDE_CODE_SESSION_ID — what the Bash tool actually exports
    #   3. CLAUDE_SESSION_ID — the older spelling, kept for callers that set it
    #   4. the pane-keyed pointer `check` writes: a pane hosts one session, so
    #      this is unambiguous even when several sessions share the state dir
    #   5. the unkeyed pointer, for sessions whose hooks ran before this existed
    #   6. newest state file, with a warning — a guess, and treated as one
    local session_id="$arg_session"
    local resolved_via="argument"

    if [ -z "$session_id" ]; then
        session_id="${CLAUDE_CODE_SESSION_ID:-}"
        resolved_via="CLAUDE_CODE_SESSION_ID"
    fi
    if [ -z "$session_id" ]; then
        session_id="${CLAUDE_SESSION_ID:-}"
        resolved_via="CLAUDE_SESSION_ID"
    fi

    local pane_pointer=""
    [ -n "${TMUX_PANE:-}" ] && pane_pointer="${SESSION_POINTER}.$(pane_key "$TMUX_PANE")"
    if [ -z "$session_id" ] && [ -n "$pane_pointer" ] && [ -f "$pane_pointer" ]; then
        session_id="$(head -n 1 "$pane_pointer" 2>/dev/null)"
        session_id="${session_id%%[[:space:]]*}"
        [ -n "$session_id" ] && resolved_via="current-session (pane ${TMUX_PANE})"
    fi

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

    # A guessed session id may not be this session at all. Marking it landed is
    # recoverable; arming a self-clear against it is not — it would type /clear
    # into whichever pane that session owns.
    local refused=""
    if [ "$resolved_via" = "newest-state-file" ] && [ "$mode" != "none" ]; then
        refused="$mode"
        mode="none"
        echo "context-budget: refusing --${refused} for a session id that was guessed from the newest state file — the clear would land in whatever pane that session owns. Landing recorded; pass the session id explicitly (\$CLAUDE_CODE_SESSION_ID) to arm the clear." >&2
    fi

    # === completeness gate (Change 5a) =====================================
    # Arming a self-clear/compact/restart claims the session is actually
    # FINISHED, not just checkpointed. --no-clear (mode=none, the default)
    # skips this whole gate — it is a checkpoint, not a completeness claim,
    # and was never gated. A real mode is checked against three independent
    # bars; failing ANY of them means NOTHING is recorded — not even a
    # degraded mode=none landing, because half of "landed" is not landed. The
    # caller (the land skill) has to notice and go finish, not sail past a
    # landing that quietly downgraded itself.
    #
    # --force skips bars 2 and 3 only, never bar 1 (the handover — a landing
    # with no handover is not a landing at all, forced or not), and is
    # recorded in the budget file as forced=true for auditability. The skill
    # may only pass it when the user explicitly authorised skipping the git/
    # agent checks (e.g. a known in-flight worker whose worktree is being
    # deliberately left behind per the Drain step).
    if [ "$mode" != "none" ]; then
        local -a issues=()

        # --- 1: handover completeness (never skippable, not even by --force)
        if [ "$no_handover" != "1" ]; then
            if [ ! -f "$HANDOVER_FILE" ]; then
                issues+=("no handover file at ${HANDOVER_FILE} — write it first (Write tool, at most ~30 lines, under ${HANDOVER_MAX_BYTES} bytes) or pass --no-handover")
            else
                local hsz hmtime hage
                hsz=$(wc -c <"$HANDOVER_FILE" 2>/dev/null | tr -d '[:space:]')
                case "$hsz" in '' | *[!0-9]*) hsz=0 ;; esac
                if [ "$hsz" -gt "$HANDOVER_MAX_BYTES" ]; then
                    issues+=("handover file is ${hsz} bytes, over the ${HANDOVER_MAX_BYTES}-byte limit (${HANDOVER_FILE}) — trim it to pointers only")
                fi
                hmtime=$(stat -c %Y "$HANDOVER_FILE" 2>/dev/null)
                case "$hmtime" in '' | *[!0-9]*) hmtime=0 ;; esac
                if [ "$hmtime" -gt 0 ]; then
                    hage=$(($(now_epoch) - hmtime))
                    if [ "$hage" -gt "$HANDOVER_MAX_AGE" ]; then
                        issues+=("handover file is ${hage}s old, over the ${HANDOVER_MAX_AGE}s (30 min) limit — rewrite it now")
                    fi
                fi
                if ! grep -Eq 'cap-[0-9a-f]{8}' "$HANDOVER_FILE" 2>/dev/null; then
                    issues+=("handover file has no Metis capture id (pattern cap-[0-9a-f]{8}) — a landing without a Metis note is not finished")
                fi
            fi
        fi

        # --- 2: git completeness (skipped by --force) ------------------------
        if [ "$force" != "1" ]; then
            local gi
            while IFS= read -r gi; do
                [ -n "$gi" ] && issues+=("$gi")
            done < <(landing_git_issues)
        fi

        # --- 3: no background sub-agents still running (skipped by --force) --
        if [ "$force" != "1" ]; then
            local ai
            while IFS= read -r ai; do
                [ -n "$ai" ] && issues+=("$ai")
            done < <(landing_running_agent_issues "$session_id")
        fi

        if [ "${#issues[@]}" -gt 0 ]; then
            echo "context-budget: refusing --${mode} — landing is not complete. Nothing recorded." >&2
            local it
            for it in "${issues[@]}"; do
                echo "  - ${it}" >&2
            done
            [ "$force" = "1" ] && echo "  (--force was passed, but it never skips the handover check)" >&2
            exit 1
        fi
    fi

    # Restart additionally needs a runnable restart command. Checked here (arm
    # time, after the completeness gate above has already passed) so a missing
    # command never gets as far as the Stop hook; the sender repeats this
    # check defensively in case PATH changes between now and then. Unlike the
    # completeness gate, this one still records the landing with mode=none —
    # matching Change 1's original spec — because the session genuinely did
    # finish; it just cannot restart itself.
    local restart_cmd="${ALFRED_SESSION_RESTART_CMD:-$RESTART_CMD_DEFAULT}"
    if [ "$mode" = "restart" ] && ! command -v "$restart_cmd" >/dev/null 2>&1; then
        mode="none"
        echo "context-budget: restart command '${restart_cmd}' not found on PATH — the owner has to restart the process by hand. Landing recorded with clear_mode=none." >&2
    fi

    mkdir -p "$STATE_DIR" 2>/dev/null || true
    local budget_file="${STATE_DIR}/${session_id}.budget"
    local now
    now=$(now_epoch)
    local forced_str="false"
    [ "$force" = "1" ] && forced_str="true"
    write_budget "$budget_file" landed_ts "$now" stop_blocked 0 \
        clear_mode "$mode" clear_summary "$summary" clear_attempts 0 \
        clear_sending "" clear_aborted "" clear_unconfirmed_ts "" forced "$forced_str"

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
    restart) tail_msg="clear_mode=restart — the Stop hook runs '${restart_cmd}' once the input box is idle." ;;
    *) tail_msg="clear_mode=none — no self-clear; the owner clears." ;;
    esac
    [ -n "$refused" ] && tail_msg="${tail_msg} (--${refused} refused: session id was guessed)"
    [ -n "$summary" ] && tail_msg="${tail_msg} clear_summary=\"${summary}\""
    [ "$force" = "1" ] && tail_msg="${tail_msg} forced=true"

    echo "context-budget: landed${at} (session ${session_id}, via ${resolved_via}) — Stop block cleared; ${tail_msg} clear_attempts=0."
    exit 0
}

# --- sender ----------------------------------------------------------------

sender_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$SENDER_LOG" 2>/dev/null
}

tmux_call() {
    # tmux_call <tmux-args...> — every tmux client call in the sender path goes
    # through this instead of calling tmux directly. A pane left in a tmux mode
    # (copy-mode: the owner scrolled back) can read a client's keys as mode
    # navigation instead of answering it, and tmux can then open a
    # command-prompt on behalf of that client — which, being a non-interactive
    # command client, has no terminal to answer the prompt and hangs forever
    # (2026-09-14: a `send-keys /exit` into a scrolled-back pane triggered
    # exactly this and blocked the sender for over an hour). `timeout` bounds
    # every call so a hung tmux client can never block the sender past its own
    # deadline; fall back to a plain call only when `timeout` is not on PATH.
    if command -v timeout >/dev/null 2>&1; then
        timeout "$TMUX_CALL_TIMEOUT" tmux "$@"
    else
        tmux "$@"
    fi
}

pane_idle() {
    # pane_idle <pane> — the input box is empty (cursor at column 2), the pane
    # is not in a tmux mode (copy-mode/view-mode — see tmux_call above for why
    # that matters), and the session is not mid-turn ("esc to interrupt" absent
    # from the last lines). A pane in a mode is never idle, even with an empty
    # cursor column: sending keys into it does not reach the session.
    #
    # Sets LAST_PANE_IN_MODE (a caller-scoped local via bash's dynamic scoping)
    # as a side effect, so do_sender's own deadline message can say whether a
    # tmux mode was the last known reason nothing ever went idle.
    local pane="$1" out rc cx capture busy
    out=$(tmux_call display-message -p -t "$pane" '#{cursor_x} #{pane_in_mode}' 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        [ "$rc" -eq 124 ] && sender_log "display-message timed out after ${TMUX_CALL_TIMEOUT}s"
        LAST_PANE_IN_MODE=""
        return 1
    fi
    cx="${out%% *}"
    LAST_PANE_IN_MODE="${out#* }"
    [ "$cx" = "2" ] || return 1
    [ "$LAST_PANE_IN_MODE" = "0" ] || return 1

    capture=$(tmux_call capture-pane -p -t "$pane" 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 124 ]; then
        sender_log "capture-pane timed out after ${TMUX_CALL_TIMEOUT}s"
        return 1
    fi
    busy=$(printf '%s\n' "$capture" | tail -4 | grep -c 'esc to interrupt') || busy=0
    [ "$busy" = "0" ]
}

do_sender() {
    local session_id="${1:-}" pane="${2:-}" mode="${3:-}"
    [ -n "$session_id" ] && [ -n "$pane" ] || exit 0
    case "$session_id" in */* | *..*) exit 0 ;; esac
    case "$mode" in clear | compact | restart) ;; *) exit 0 ;; esac
    command -v tmux >/dev/null 2>&1 || exit 0

    local budget_file="${STATE_DIR}/${session_id}.budget"
    SENDER_LOG="${STATE_DIR}/${session_id}.sender.log"
    sender_log "start pane=${pane} mode=${mode} deadline=${SENDER_DEADLINE}s"

    local deadline idle=0 lp landed now keys summary mode_now owner rc waited
    local LAST_PANE_IN_MODE=""
    deadline=$(($(now_epoch) + SENDER_DEADLINE))

    while :; do
        now=$(now_epoch)
        [ "$now" -lt "$deadline" ] || break

        # Race guard: a prompt submitted after the landing means the session has
        # picked work up again and the context is no longer landed. Clearing then
        # would destroy live work.
        lp=$(num_or "$(read_budget "$budget_file" last_prompt_ts)" 0)
        landed=$(num_or "$(read_budget "$budget_file" landed_ts)" 0)
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

        [ "$idle" -ge 2 ] && break
        sleep "$SENDER_POLL"
    done

    if [ "$idle" -lt 2 ]; then
        # Leave clear_mode as it is: the next Stop gets the second and last attempt.
        if [ "$LAST_PANE_IN_MODE" = "1" ]; then
            sender_log "timeout after ${SENDER_DEADLINE}s — the input box never went idle — the pane was in a tmux mode (owner scrolled back?)"
        else
            sender_log "timeout after ${SENDER_DEADLINE}s — the input box never went idle"
        fi
        exit 0
    fi

    # --- the send ----------------------------------------------------------
    # Everything below re-reads state immediately before it acts on it. The gap
    # between deciding to send and the Enter landing is long enough (a second) for
    # the owner to type, and long enough for a second sender to be spawned.

    mode_now=$(read_budget "$budget_file" clear_mode)
    if [ "$mode_now" != "$mode" ]; then
        sender_log "abort: clear_mode is '${mode_now}', not '${mode}' — another actor owns this"
        exit 0
    fi

    lp=$(num_or "$(read_budget "$budget_file" last_prompt_ts)" 0)
    landed=$(num_or "$(read_budget "$budget_file" landed_ts)" 0)
    if [ "$lp" -gt "$landed" ]; then
        sender_log "abort: prompt at ${lp} came after the landing at ${landed}"
        write_budget "$budget_file" clear_aborted "new-prompt" clear_mode none
        exit 0
    fi

    # Restart resolves and checks its command before claiming the send: landed
    # already refused --restart at arm time when the command was missing, but
    # PATH can change between then and now, and a missing command must never
    # leave the pane mid-claim.
    local restart_cmd="" restart_path=""
    if [ "$mode" = "restart" ]; then
        restart_cmd="${ALFRED_SESSION_RESTART_CMD:-$RESTART_CMD_DEFAULT}"
        restart_path=$(command -v "$restart_cmd" 2>/dev/null) || restart_path=""
        if [ -z "$restart_path" ]; then
            sender_log "no restart command (${restart_cmd} not found on PATH)"
            write_budget "$budget_file" clear_mode none clear_sending ""
            exit 0
        fi
    fi

    summary=$(read_budget "$budget_file" clear_summary)
    if [ "$mode" = "compact" ]; then
        if [ -n "$summary" ]; then
            keys="/compact Preserve: ${summary}"
        else
            keys="/compact"
        fi
    elif [ "$mode" = "clear" ]; then
        keys="/clear"
    fi

    # Claim the send before touching the pane: a second sender now reads
    # clear_mode=none and aborts instead of typing a second /clear (or running a
    # second restart). clear_sending is this process, so the claim can be
    # re-checked between steps without the claim itself looking like someone
    # else's change.
    write_budget "$budget_file" clear_mode none clear_sending "$$"

    # Written before the action, not after: the new session (cleared, compacted,
    # or restarted via `claude -c`) has to find this file already there when its
    # SessionStart hook runs. It is also the confirmation signal — that hook
    # deletes it.
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

    if [ "$mode" = "restart" ]; then
        # hub-restart (or whatever ALFRED_SESSION_RESTART_CMD names) arms the
        # restart and returns immediately — it types /exit and respawns the pane
        # itself, asynchronously, once its own idle check passes. rc here is
        # only "armed", not "restarted"; the confirmation loop below is what
        # actually proves the new session came up.
        sender_log "idle confirmed — running restart command: ${restart_path}"
        "$restart_path" >/dev/null 2>>"$SENDER_LOG"
        rc=$?
        sender_log "restart command exited rc=${rc}"
        if [ "$rc" -ne 0 ]; then
            sender_log "restart command failed rc=${rc} — nothing was armed"
            rm -f "$LAST_CLEAR" 2>/dev/null
            write_budget "$budget_file" clear_mode "$mode" clear_sending ""
            exit 0
        fi
    else
        sender_log "idle confirmed — sending ${mode}"
        # Two send-keys a second apart: typing the command opens the slash
        # autocomplete, and an Enter in the same burst can land on the menu
        # before it has settled.
        tmux_call send-keys -t "$pane" "$keys" 2>/dev/null
        rc=$?
        if [ "$rc" -ne 0 ]; then
            if [ "$rc" -eq 124 ]; then
                sender_log "send-keys (command) timed out after ${TMUX_CALL_TIMEOUT}s — nothing was typed"
            else
                sender_log "send-keys (command) failed rc=${rc} — nothing was typed"
            fi
            rm -f "$LAST_CLEAR" 2>/dev/null
            write_budget "$budget_file" clear_mode "$mode" clear_sending ""
            exit 0
        fi
        sleep 1

        owner=$(read_budget "$budget_file" clear_sending)
        if [ "$owner" != "$$" ]; then
            sender_log "abort: clear_sending is '${owner}', not this sender — another sender took over"
            exit 0
        fi

        lp=$(num_or "$(read_budget "$budget_file" last_prompt_ts)" 0)
        landed=$(num_or "$(read_budget "$budget_file" landed_ts)" 0)
        if [ "$lp" -gt "$landed" ]; then
            # The command is sitting in the owner's input box; wipe the line so
            # their next keystroke is not prefixed by half a slash command.
            tmux_call send-keys -t "$pane" C-u 2>/dev/null
            sender_log "abort: prompt at ${lp} arrived between the command and the Enter — line wiped"
            rm -f "$LAST_CLEAR" 2>/dev/null
            write_budget "$budget_file" clear_aborted "new-prompt" clear_mode none clear_sending ""
            exit 0
        fi

        tmux_call send-keys -t "$pane" C-m 2>/dev/null
        rc=$?
        if [ "$rc" -ne 0 ]; then
            tmux_call send-keys -t "$pane" C-u 2>/dev/null
            if [ "$rc" -eq 124 ]; then
                sender_log "send-keys (Enter) timed out after ${TMUX_CALL_TIMEOUT}s — line wiped"
            else
                sender_log "send-keys (Enter) failed rc=${rc} — line wiped"
            fi
            rm -f "$LAST_CLEAR" 2>/dev/null
            write_budget "$budget_file" clear_mode "$mode" clear_sending ""
            exit 0
        fi
    fi

    # --- confirmation ------------------------------------------------------
    # A send is not a clear. The new session's SessionStart hook consumes the
    # handover marker, so the marker disappearing is the only evidence this
    # script has that the session actually restarted.
    waited=0
    while [ "$waited" -lt "$CONFIRM_SECONDS" ]; do
        [ -f "$LAST_CLEAR" ] || break
        sleep 1
        waited=$((waited + 1))
    done

    if [ -f "$LAST_CLEAR" ]; then
        # Unconfirmed: either the session did not clear, or it is running a build
        # with no SessionStart hook to consume the marker. Drop the marker rather
        # than let it greet an unrelated later clear, and leave clear_mode set so
        # the next Stop spends the second attempt.
        rm -f "$LAST_CLEAR" 2>/dev/null
        write_budget "$budget_file" clear_mode "$mode" clear_sending "" \
            clear_unconfirmed_ts "$(now_epoch)"
        sender_log "unconfirmed after ${CONFIRM_SECONDS}s — marker never consumed; clear_mode=${mode} left for the next attempt"
        exit 0
    fi

    write_budget "$budget_file" cleared_ts "$(now_epoch)" clear_mode none clear_sending ""
    sender_log "sent and confirmed"
    exit 0
}

# --- session-start ----------------------------------------------------------

do_session_start() {
    command -v jq >/dev/null 2>&1 || exit 0

    local payload source session_id
    payload=$(cat 2>/dev/null) || exit 0
    [ -n "$payload" ] || exit 0
    source=$(printf '%s' "$payload" | jq -r '.source // ""' 2>/dev/null) || exit 0
    session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
    # All four ordinary session starts are matched, regardless of which one a
    # self-clear/compact/restart actually produces: `claude -c` (the restart
    # path) reports source=resume per the Claude Code hooks docs, a plain
    # relaunch reports startup, and clear/compact report themselves. Matching
    # all four rather than guessing one is simpler and safe — the marker read
    # below is still gated on the marker's own presence and freshness, and the
    # handover-file read below is unconditional on source entirely.
    case "$source" in startup | resume | clear | compact) ;; *) exit 0 ;; esac

    local classified=0

    # --- graceful: a fresh last-clear marker is present ----------------------
    # Present only when a self-clear/compact/restart landing actually armed it,
    # so this block is a no-op on an ordinary startup/resume with nothing
    # pending.
    if [ -f "$LAST_CLEAR" ]; then
        local ts now prev mode summary when marker_valid=1
        ts=$(jq -r '.ts // empty' "$LAST_CLEAR" 2>/dev/null) || marker_valid=0
        case "$ts" in '' | *[!0-9]*) marker_valid=0 ;; esac
        if [ "$marker_valid" = "1" ]; then
            now=$(now_epoch)
            if [ $((now - ts)) -gt "$HANDOVER_WINDOW" ]; then
                rm -f "$LAST_CLEAR" 2>/dev/null
            else
                classified=1
                prev=$(jq -r '.prev_session_id // ""' "$LAST_CLEAR" 2>/dev/null)
                mode=$(jq -r '.mode // ""' "$LAST_CLEAR" 2>/dev/null)
                summary=$(jq -r '.summary // ""' "$LAST_CLEAR" 2>/dev/null)
                when=$(date -d "@${ts}" '+%H:%M' 2>/dev/null) || when=""
                local verb
                case "$mode" in
                restart) verb="restarted itself" ;;
                compact) verb="self-compacted" ;;
                *) verb="self-cleared" ;;
                esac
                printf 'CONTEXT BUDGET: graceful %s after landing — previous session %s %s at %s local — "%s". Continue from the handover memory and GitHub issues, not from recollection of the previous conversation.\n' \
                    "$mode" "$prev" "$verb" "$when" "$summary"
                rm -f "$LAST_CLEAR" 2>/dev/null
            fi
        else
            rm -f "$LAST_CLEAR" 2>/dev/null
        fi
    fi

    # --- unplanned: no graceful marker, but evidence of an abrupt end -------
    # Two independent signals, either is sufficient:
    #   (i)  a boot-recovery marker written by the host's boot supervisor
    #        before it recreated this session (crash / power loss / OOM-kill —
    #        the process never got to land or write a last-clear marker at all)
    #   (ii) the most recent OTHER session's budget file shows activity
    #        (last_prompt_ts) after its last landing (landed_ts) — that session
    #        picked work back up post-landing and then simply never landed
    #        again before it ended (owner closed the pane, host killed it,
    #        etc.)
    if [ "$classified" = "0" ]; then
        local boot_file="$BOOT_RECOVERY_FILE"
        local have_boot=0 boot_ts="" boot_reason="" boot_host=""
        if [ -f "$boot_file" ]; then
            have_boot=1
            boot_ts=$(jq -r '.boot_ts // empty' "$boot_file" 2>/dev/null)
            boot_reason=$(jq -r '.reason // empty' "$boot_file" 2>/dev/null)
            boot_host=$(jq -r '.host // empty' "$boot_file" 2>/dev/null)
        fi

        local newest_other="" f sid
        # shellcheck disable=SC2012 # session ids are UUIDs: no exotic filenames,
        # and `ls -t` is the portable way to order by mtime (find -printf is
        # GNU-only). A `while read` loop over the pipe, not `for f in $(...)`,
        # so word-splitting a filename never becomes a concern (SC2045).
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            sid=$(basename "$f" .budget)
            if [ -n "$session_id" ] && [ "$sid" = "$session_id" ]; then
                continue
            fi
            newest_other="$f"
            break
        done < <(ls -t "${STATE_DIR}"/*.budget 2>/dev/null)

        local found_stale=0 stale_sid="" stale_last=0 stale_landed=0
        if [ -n "$newest_other" ]; then
            stale_sid=$(basename "$newest_other" .budget)
            stale_last=$(num_or "$(read_budget "$newest_other" last_prompt_ts)" 0)
            stale_landed=$(num_or "$(read_budget "$newest_other" landed_ts)" 0)
            [ "$stale_last" -gt "$stale_landed" ] && found_stale=1
        fi

        if [ "$have_boot" = "1" ] || [ "$found_stale" = "1" ]; then
            classified=1
            local last_str landed_str detail
            if [ "$stale_last" -gt 0 ]; then
                last_str=$(date -d "@${stale_last}" '+%H:%M' 2>/dev/null) || last_str="$stale_last"
            else
                last_str="unknown"
            fi
            if [ "$stale_landed" -gt 0 ]; then
                landed_str=$(date -d "@${stale_landed}" '+%H:%M' 2>/dev/null) || landed_str="$stale_landed"
            else
                landed_str="never"
            fi
            detail="previous session ${stale_sid:-unknown} — last activity ${last_str} local, last landing ${landed_str} local"
            if [ "$have_boot" = "1" ]; then
                local boot_str
                if [ -n "$boot_ts" ]; then
                    boot_str=$(date -d "@${boot_ts}" '+%H:%M' 2>/dev/null) || boot_str="$boot_ts"
                else
                    boot_str="unknown"
                fi
                detail="${detail}, boot time ${boot_str} local (reason: ${boot_reason:-unknown}, host: ${boot_host:-unknown})"
            fi
            printf 'CONTEXT BUDGET: unplanned restart detected — recovery required.\nRECOVERY: %s.\nRun /alfred-agent:recover now, before any other work.\n' "$detail"
        fi

        # Consumed either way: a stale boot marker must never greet a later,
        # unrelated start once it has been read once.
        [ "$have_boot" = "1" ] && rm -f "$boot_file" 2>/dev/null
    fi

    # --- handover file: consumed by whichever session starts next -----------
    # Independent of both blocks above: a handover can exist with no pending
    # self-clear (e.g. --no-clear), and is injected regardless — a stale
    # handover after an unplanned restart is still better than none. Print,
    # then delete — it is consumed once, never accumulated.
    if [ -f "$HANDOVER_FILE" ]; then
        local hmtime
        hmtime=$(date -r "$HANDOVER_FILE" '+%H:%M' 2>/dev/null) || hmtime=""
        printf 'HANDOVER (written %s local, consumed now):\n' "$hmtime"
        cat "$HANDOVER_FILE" 2>/dev/null
        printf '\n'
        rm -f "$HANDOVER_FILE" 2>/dev/null
    fi

    # --- arm this session's baseline ----------------------------------------
    # The reading itself is not available yet — the status line writes it on the
    # first assistant message — so only the intent is recorded; the first `check`
    # with a fresh reading turns it into `baseline`. Last, so nothing above it
    # (the "most recent OTHER session" scan in particular) ever sees a budget
    # file this start created. Gated on the state directory already existing: on
    # a host without the fleet status line this script still creates nothing.
    #
    # All four sources arm it, resume included: a resumed session (the --restart
    # path's `claude -c`) gets a fresh session id and therefore a fresh budget
    # file, and its baseline is whatever the window costs at the moment it comes
    # back — which for a restart after a landing is exactly right.
    if [ -d "$STATE_DIR" ] && [ -n "$session_id" ]; then
        case "$session_id" in
        */* | *..*) ;;
        *) write_budget "${STATE_DIR}/${session_id}.budget" baseline_pending 1 ;;
        esac
    fi

    exit 0
}

# --- pre-compact ------------------------------------------------------------

do_pre_compact() {
    command -v jq >/dev/null 2>&1 || exit 0

    local payload trigger session_id
    payload=$(cat 2>/dev/null) || exit 0
    [ -n "$payload" ] || exit 0
    trigger=$(printf '%s' "$payload" | jq -r '.trigger // ""' 2>/dev/null) || exit 0
    # Never block a compaction — PreCompact cannot: per the Claude Code hooks
    # docs (https://docs.claude.com/en/docs/claude-code/hooks), exit code 2 and
    # any JSON decision are ignored for this event, for both manual and auto
    # triggers (Change 5b). A manual compaction is not hooked at all (hooks.json
    # matcher stays "auto"): there is nothing to block, and nothing needs
    # recording for it either — an un-landed compaction, manual or auto, is
    # already caught generically at the NEXT session's SessionStart by
    # comparing the old session's last_prompt_ts against its landed_ts (see
    # do_session_start's "unplanned" classification). autocompact_ts below
    # exists only to power the UserPromptSubmit nag, which is specifically
    # about the harness compacting automatically before a landing ran.
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
