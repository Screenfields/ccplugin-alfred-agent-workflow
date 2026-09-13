#!/usr/bin/env bash
# tests/context-budget.sh — plain bash, no framework.
#
#   ./tests/context-budget.sh
#
# Each case gets its own session id under a throwaway ALFRED_STATE_DIR, so the
# rate limiter and the Stop-block state of one case cannot leak into another.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../hooks/context-budget.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export ALFRED_STATE_DIR="$TMPROOT/state"
export ALFRED_CONTEXT_SOFT_PCT=20
export ALFRED_CONTEXT_HARD_PCT=35
# The fixture writes used = pct * 2000, so these token thresholds sit exactly on
# the 20% / 35% marks of its 200k window: every pre-token case keeps its tier.
export ALFRED_CONTEXT_SOFT_TOKENS=40000
export ALFRED_CONTEXT_HARD_TOKENS=70000
CTX_DIR="$ALFRED_STATE_DIR/context"
mkdir -p "$CTX_DIR"

PASS=0
FAIL=0
RC=0
OUT_TXT=""
ERR_TXT=""

ok() {
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$1"
}

bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n' "$1"
    [ "$#" -ge 2 ] && printf '      %s\n' "$2"
    return 0
}

# fixture <session_id> <pct> [age_seconds]
fixture() {
    local sid="$1" pct="$2" age="${3:-0}" ts
    ts=$(($(date +%s) - age))
    printf '{"pct":%s,"used":%s,"size":200000,"ts":%s}\n' \
        "$pct" "$((pct * 2000))" "$ts" >"${CTX_DIR}/${sid}.json"
}

# fixture_tokens <session_id> <used> <size> <pct> — the token tiers, decided from
# `used` alone; pct is deliberately far below every percentage threshold.
fixture_tokens() {
    printf '{"pct":%s,"used":%s,"size":%s,"ts":%s}\n' \
        "$4" "$2" "$3" "$(date +%s)" >"${CTX_DIR}/${1}.json"
}

# fixture_nopct <session_id> <pct> — a status line too old to report `used`.
fixture_nousd() {
    printf '{"pct":%s,"size":200000,"ts":%s}\n' "$2" "$(date +%s)" >"${CTX_DIR}/${1}.json"
}

# run_check <session_id> <hook_event_name> [extra_json] — sets RC / OUT_TXT / ERR_TXT.
# extra_json is appended verbatim, e.g. ',"tool_name":"Agent"'.
# Deliberately not a command substitution: RC must survive.
run_check() {
    printf '{"session_id":"%s","hook_event_name":"%s","cwd":"/tmp"%s}' "$1" "$2" "${3:-}" |
        "$SCRIPT" check >"$TMPROOT/out" 2>"$TMPROOT/err"
    RC=$?
    OUT_TXT="$(cat "$TMPROOT/out")"
    ERR_TXT="$(cat "$TMPROOT/err")"
    return 0
}

# assert_silent <label> <session_id> <event> [extra_json]
assert_silent() {
    run_check "$2" "$3" "${4:-}"
    if [ -n "$OUT_TXT" ]; then
        bad "$1" "expected no stdout, got: $OUT_TXT"
    elif [ "$RC" -ne 0 ]; then
        bad "$1" "expected exit 0, got $RC"
    else
        ok "$1"
    fi
}

# assert_context <label> <session_id> <event> <expected substring> [extra_json]
assert_context() {
    local ctx
    run_check "$2" "$3" "${5:-}"
    if [ "$RC" -ne 0 ]; then
        bad "$1" "expected exit 0, got $RC"
        return 0
    fi
    if [ -z "$OUT_TXT" ]; then
        bad "$1" "expected an injection, got nothing"
        return 0
    fi
    if ! printf '%s' "$OUT_TXT" | jq -e . >/dev/null 2>&1; then
        bad "$1" "stdout is not valid JSON: $OUT_TXT"
        return 0
    fi
    if [ "$(printf '%s' "$OUT_TXT" | jq -r '.hookSpecificOutput.hookEventName')" != "$3" ]; then
        bad "$1" "hookEventName mismatch: $OUT_TXT"
        return 0
    fi
    ctx="$(printf '%s' "$OUT_TXT" | jq -r '.hookSpecificOutput.additionalContext')"
    case "$ctx" in
    *"$4"*) ok "$1" ;;
    *) bad "$1" "additionalContext missing '$4': $ctx" ;;
    esac
    return 0
}

echo "== context-budget.sh =="

# --- 10% : below soft, nothing happens -------------------------------------
fixture s-low 10
assert_silent "10% UserPromptSubmit is silent" s-low UserPromptSubmit
assert_silent "10% PostToolUse is silent" s-low PostToolUse
assert_silent "10% Stop does not block" s-low Stop

# --- 25% : soft tier, once per 10 min --------------------------------------
fixture s-soft 25
assert_context "25% injects the soft reminder verbatim" s-soft UserPromptSubmit \
    "CONTEXT BUDGET: 50000 tokens (25%) used — soft threshold 40000 tokens. Land at the next natural boundary: run /alfred-agent:land --mode=light."
assert_silent "25% second call within 10 min is silent" s-soft UserPromptSubmit
assert_silent "25% PostToolUse within the same window is silent too" s-soft PostToolUse
assert_silent "25% Stop never blocks at soft tier" s-soft Stop

# --- PostToolUse carries its own hookEventName ------------------------------
fixture s-ptu 25
assert_context "PostToolUse injection is labelled PostToolUse" s-ptu PostToolUse \
    "soft threshold 40000 tokens"

# --- rate-limit window expiry ----------------------------------------------
fixture s-window 25
run_check s-window UserPromptSubmit
printf 'last_tier=soft\nlast_nag_ts=%s\n' "$(($(date +%s) - 601))" >"${CTX_DIR}/s-window.budget"
assert_context "soft reminder returns after the 10 min window" s-window UserPromptSubmit \
    "soft threshold 40000 tokens"

# --- tier escalation resets the timer --------------------------------------
fixture s-esc 25
run_check s-esc UserPromptSubmit
fixture s-esc 40
assert_context "soft -> hard escalation injects immediately" s-esc UserPromptSubmit \
    "hard threshold 70000 tokens"

# --- 40% : hard tier + Stop blocks exactly once -----------------------------
fixture s-hard 40
assert_context "40% injects the hard reminder verbatim" s-hard UserPromptSubmit \
    "CONTEXT BUDGET: 80000 tokens (40%) used — hard threshold 70000 tokens. LAND NOW: run /alfred-agent:land --mode=light before anything else."

run_check s-hard Stop
if [ "$RC" -eq 2 ] && [ -z "$OUT_TXT" ] && printf '%s' "$ERR_TXT" | grep -q "land --mode=light"; then
    ok "40% first Stop blocks: exit 2, reason on stderr, nothing on stdout"
else
    bad "40% first Stop blocks: exit 2, reason on stderr, nothing on stdout" \
        "rc=$RC stdout='$OUT_TXT' stderr='$ERR_TXT'"
fi

assert_silent "40% second Stop passes (never two blocks in a row)" s-hard Stop
assert_silent "40% third Stop still passes" s-hard Stop

# --- landed marker clears the block ----------------------------------------
fixture s-landed 40
run_check s-landed UserPromptSubmit
"$SCRIPT" landed s-landed >"$TMPROOT/landed.out" 2>"$TMPROOT/landed.err"
landed_rc=$?
landed_lines="$(wc -l <"$TMPROOT/landed.out")"
if [ "$landed_rc" -eq 0 ] && [ "$landed_lines" -eq 1 ] && grep -q "landed" "$TMPROOT/landed.out"; then
    ok "landed exits 0 and prints exactly one line"
else
    bad "landed exits 0 and prints exactly one line" \
        "rc=$landed_rc lines=$landed_lines out='$(cat "$TMPROOT/landed.out")'"
fi
assert_silent "Stop after landed does not block" s-landed Stop

# landed also clears a block that has already fired
fixture s-landed2 40
run_check s-landed2 Stop
"$SCRIPT" landed s-landed2 >/dev/null
assert_silent "Stop after a fired block + landed stays clear" s-landed2 Stop

# --- missing state file -----------------------------------------------------
assert_silent "missing state file is silent (UserPromptSubmit)" s-absent UserPromptSubmit
assert_silent "missing state file is silent (PostToolUse)" s-absent PostToolUse
assert_silent "missing state file is silent (Stop)" s-absent Stop

# --- stale state file -------------------------------------------------------
fixture s-stale 40 10800 # 3 h old
assert_silent "stale (>2 h) state file is silent (UserPromptSubmit)" s-stale UserPromptSubmit
assert_silent "stale (>2 h) state file is silent (Stop)" s-stale Stop

# --- threshold overrides ----------------------------------------------------
fixture s-env 12
export ALFRED_CONTEXT_SOFT_TOKENS=20000 ALFRED_CONTEXT_HARD_TOKENS=30000
assert_context "ALFRED_CONTEXT_SOFT_TOKENS override applies" s-env UserPromptSubmit \
    "soft threshold 20000 tokens"
export ALFRED_CONTEXT_SOFT_TOKENS=40000 ALFRED_CONTEXT_HARD_TOKENS=70000

# --- malformed input --------------------------------------------------------
printf 'not json' | "$SCRIPT" check >"$TMPROOT/out" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMPROOT/out" ]; then
    ok "malformed stdin is silent and exits 0"
else
    bad "malformed stdin is silent and exits 0" "rc=$rc out='$(cat "$TMPROOT/out")'"
fi

# --- crossing reset and re-arm ---------------------------------------------
fixture s-rearm 40
run_check s-rearm Stop
first_rc=$RC
fixture s-rearm 10 # usage drops back below the hard threshold
run_check s-rearm UserPromptSubmit
fixture s-rearm 40 # and crosses again
run_check s-rearm Stop
if [ "$first_rc" -eq 2 ] && [ "$RC" -eq 2 ]; then
    ok "a fresh crossing re-arms the Stop block"
else
    bad "a fresh crossing re-arms the Stop block" "first=$first_rc second=$RC"
fi
assert_silent "re-armed block still fires only once" s-rearm Stop

# --- stop_hook_active loop guard -------------------------------------------
fixture s-active 40
assert_silent "Stop with stop_hook_active=true never blocks" s-active Stop \
    ',"stop_hook_active":true'
run_check s-active Stop
if [ "$RC" -eq 2 ]; then
    ok "stop_hook_active=true did not consume the one block"
else
    bad "stop_hook_active=true did not consume the one block" "rc=$RC"
fi

# --- fail open when the block flag cannot be persisted ----------------------
if [ "$(id -u)" != "0" ]; then
    RO="$TMPROOT/ro"
    mkdir -p "$RO/context"
    printf '{"pct":40,"used":80000,"size":200000,"ts":%s}\n' "$(date +%s)" >"$RO/context/s-ro.json"
    chmod 555 "$RO/context"
    printf '{"session_id":"s-ro","hook_event_name":"Stop","cwd":"/tmp"}' |
        ALFRED_STATE_DIR="$RO" "$SCRIPT" check >"$TMPROOT/out" 2>/dev/null
    ro_rc=$?
    chmod 755 "$RO/context"
    if [ "$ro_rc" -eq 0 ]; then
        ok "unwritable state dir fails open on Stop (never an unendable turn)"
    else
        bad "unwritable state dir fails open on Stop (never an unendable turn)" "rc=$ro_rc"
    fi
else
    ok "unwritable state dir fails open on Stop (skipped: running as root)"
fi

# --- sub-agent tool calls ---------------------------------------------------
fixture s-sub 40
assert_silent "PostToolUse from the Agent tool is ignored" s-sub PostToolUse ',"tool_name":"Agent"'
assert_silent "PostToolUse from the Task tool is ignored" s-sub PostToolUse ',"tool_name":"Task"'
assert_silent "PostToolUse carrying agent_id (sub-agent context) is ignored" s-sub PostToolUse \
    ',"tool_name":"Bash","agent_id":"a1b2c3","agent_type":"Explore"'
assert_context "PostToolUse from a normal tool still injects" s-sub PostToolUse \
    "LAND NOW" ',"tool_name":"Bash"'

# --- PostToolUse is capped at once per tier ---------------------------------
fixture s-cap 25
assert_context "PostToolUse injects once at a tier" s-cap PostToolUse "soft threshold 40000 tokens"
printf 'last_tier=soft\nlast_nag_ts=%s\nptu_tier=soft\n' "$(($(date +%s) - 601))" >"${CTX_DIR}/s-cap.budget"
assert_silent "PostToolUse stays silent at the same tier after the window" s-cap PostToolUse
assert_context "UserPromptSubmit still nags after the window" s-cap UserPromptSubmit \
    "soft threshold 40000 tokens"

# --- landed session resolution ----------------------------------------------
POINTER_DIR="$TMPROOT/pointer"
mkdir -p "$POINTER_DIR/context"
printf '{"pct":40,"used":80000,"size":200000,"ts":%s}\n' "$(date +%s)" >"$POINTER_DIR/context/sess-A.json"
printf '{"pct":40,"used":80000,"size":200000,"ts":%s}\n' "$(date +%s)" >"$POINTER_DIR/context/sess-B.json"
# sess-B is the newest file, but sess-A is the session whose hooks fire.
printf '{"session_id":"sess-A","hook_event_name":"UserPromptSubmit","cwd":"/tmp"}' |
    ALFRED_STATE_DIR="$POINTER_DIR" "$SCRIPT" check >/dev/null 2>&1
if [ "$(cat "$POINTER_DIR/context/current-session" 2>/dev/null)" = "sess-A" ]; then
    ok "check persists the session id to current-session"
else
    bad "check persists the session id to current-session" \
        "got '$(cat "$POINTER_DIR/context/current-session" 2>/dev/null)'"
fi
touch "$POINTER_DIR/context/sess-B.json" # make the wrong session the newest file
ALFRED_STATE_DIR="$POINTER_DIR" "$SCRIPT" landed >"$TMPROOT/out" 2>"$TMPROOT/err"
if grep -q "sess-A" "$TMPROOT/out" && [ ! -s "$TMPROOT/err" ] &&
    [ -f "$POINTER_DIR/context/sess-A.budget" ] && [ ! -f "$POINTER_DIR/context/sess-B.budget" ]; then
    ok "landed without an argument uses current-session, not the newest file"
else
    bad "landed without an argument uses current-session, not the newest file" \
        "out='$(cat "$TMPROOT/out")' err='$(cat "$TMPROOT/err")'"
fi

# explicit argument and CLAUDE_SESSION_ID outrank the pointer
ALFRED_STATE_DIR="$POINTER_DIR" "$SCRIPT" landed sess-B >"$TMPROOT/out" 2>/dev/null
if grep -q "sess-B" "$TMPROOT/out" && [ -f "$POINTER_DIR/context/sess-B.budget" ]; then
    ok "explicit argument outranks current-session"
else
    bad "explicit argument outranks current-session" "out='$(cat "$TMPROOT/out")'"
fi
rm -f "$POINTER_DIR/context/sess-B.budget"
ALFRED_STATE_DIR="$POINTER_DIR" CLAUDE_SESSION_ID=sess-B "$SCRIPT" landed >"$TMPROOT/out" 2>/dev/null
if grep -q "sess-B" "$TMPROOT/out"; then
    ok "CLAUDE_SESSION_ID outranks current-session"
else
    bad "CLAUDE_SESSION_ID outranks current-session" "out='$(cat "$TMPROOT/out")'"
fi

# no pointer at all: newest file, with a warning on stderr
FALLBACK_DIR="$TMPROOT/fallback"
mkdir -p "$FALLBACK_DIR/context"
printf '{"pct":40,"used":80000,"size":200000,"ts":%s}\n' "$(date +%s)" >"$FALLBACK_DIR/context/old-one.json"
sleep 1
printf '{"pct":40,"used":80000,"size":200000,"ts":%s}\n' "$(date +%s)" >"$FALLBACK_DIR/context/new-one.json"
ALFRED_STATE_DIR="$FALLBACK_DIR" "$SCRIPT" landed >"$TMPROOT/out" 2>"$TMPROOT/err"
if grep -q "new-one" "$TMPROOT/out" && grep -q "warning" "$TMPROOT/err" &&
    [ "$(wc -l <"$TMPROOT/out")" -eq 1 ]; then
    ok "no pointer falls back to the newest state file and warns on stderr"
else
    bad "no pointer falls back to the newest state file and warns on stderr" \
        "out='$(cat "$TMPROOT/out")' err='$(cat "$TMPROOT/err")'"
fi

# --- non-numeric threshold overrides fall back to defaults ------------------
fixture s-bad 25
export ALFRED_CONTEXT_SOFT_TOKENS="eighty thousand" ALFRED_CONTEXT_HARD_TOKENS=""
assert_silent "non-numeric token thresholds fall back to 80000/120000 silently" s-bad UserPromptSubmit
export ALFRED_CONTEXT_SOFT_PCT="twenty" ALFRED_CONTEXT_HARD_PCT=""
fixture_nousd s-badpct 25
assert_context "non-numeric pct thresholds fall back to 20/35 silently" s-badpct UserPromptSubmit \
    "soft threshold 20%"
export ALFRED_CONTEXT_SOFT_PCT=20 ALFRED_CONTEXT_HARD_PCT=35
export ALFRED_CONTEXT_SOFT_TOKENS=40000 ALFRED_CONTEXT_HARD_TOKENS=70000

# ===========================================================================
# Token thresholds
# ===========================================================================

export ALFRED_CONTEXT_SOFT_TOKENS=80000 ALFRED_CONTEXT_HARD_TOKENS=120000
# size 1000000 and pct 7/9/13 — every one of these is below the 20% soft PCT, so
# a passing tier assertion can only have come from the token count.
fixture_tokens s-tok-none 70000 1000000 7
assert_silent "70000 tokens in a 1M window is below the soft token threshold" s-tok-none UserPromptSubmit
assert_silent "70000 tokens does not block Stop" s-tok-none Stop

fixture_tokens s-tok-soft 90000 1000000 9
assert_context "90000 tokens is the soft tier, reported in tokens" s-tok-soft UserPromptSubmit \
    "CONTEXT BUDGET: 90000 tokens (9%) used — soft threshold 80000 tokens."

fixture_tokens s-tok-hard 130000 1000000 13
assert_context "130000 tokens is the hard tier, reported in tokens" s-tok-hard UserPromptSubmit \
    "CONTEXT BUDGET: 130000 tokens (13%) used — hard threshold 120000 tokens."
run_check s-tok-hard Stop
if [ "$RC" -eq 2 ]; then
    ok "130000 tokens blocks Stop once even at 13% of the window"
else
    bad "130000 tokens blocks Stop once even at 13% of the window" "rc=$RC"
fi

# pct fallback: no `used` field at all -> the percentage thresholds decide
fixture_nousd s-pctfall 25
assert_context "state file without 'used' falls back to the pct thresholds" s-pctfall UserPromptSubmit \
    "CONTEXT BUDGET: 25% used — soft threshold 20%."
fixture_nousd s-pctfall2 40
run_check s-pctfall2 Stop
if [ "$RC" -eq 2 ] && printf '%s' "$ERR_TXT" | grep -q "40% used — above the hard threshold of 35%"; then
    ok "pct fallback still blocks Stop at the hard percentage"
else
    bad "pct fallback still blocks Stop at the hard percentage" "rc=$RC err='$ERR_TXT'"
fi
export ALFRED_CONTEXT_SOFT_TOKENS=40000 ALFRED_CONTEXT_HARD_TOKENS=70000

# ===========================================================================
# Self-clear
# ===========================================================================

# A tmux stub that records its argv and reports an idle, quiet pane.
STUBBIN="$TMPROOT/stubbin"
mkdir -p "$STUBBIN"
cat >"$STUBBIN/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
case "${1:-}" in
display-message) echo 2 ;;
capture-pane) : ;;
esac
exit 0
STUB
chmod +x "$STUBBIN/tmux"

# wait_for <file> <pattern> <seconds>
wait_for() {
    local i=0
    while [ "$i" -lt "$3" ]; do
        grep -q "$2" "$1" 2>/dev/null && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# --- landed --clear records the self-clear intent ---------------------------
fixture s-clear 40
"$SCRIPT" landed --clear --summary "PR #93 merged; next session starts at issue #847" s-clear \
    >"$TMPROOT/out" 2>/dev/null
CB="${CTX_DIR}/s-clear.budget"
if [ "$(grep -c '^clear_mode=clear$' "$CB")" = "1" ] &&
    grep -q '^clear_summary=PR #93 merged; next session starts at issue #847$' "$CB" &&
    grep -q '^clear_attempts=0$' "$CB" &&
    grep -q 'clear_mode=clear' "$TMPROOT/out"; then
    ok "landed --clear --summary records clear_mode, clear_summary, clear_attempts"
else
    bad "landed --clear --summary records clear_mode, clear_summary, clear_attempts" \
        "budget='$(cat "$CB")' out='$(cat "$TMPROOT/out")'"
fi

"$SCRIPT" landed s-clear2 >/dev/null 2>&1
if grep -q '^clear_mode=none$' "${CTX_DIR}/s-clear2.budget"; then
    ok "landed with no flag defaults to clear_mode=none (old callers unchanged)"
else
    bad "landed with no flag defaults to clear_mode=none (old callers unchanged)" \
        "$(cat "${CTX_DIR}/s-clear2.budget")"
fi

"$SCRIPT" landed --compact --summary "handover" s-clear3 >/dev/null 2>&1
"$SCRIPT" landed --no-clear s-clear4 >/dev/null 2>&1
if grep -q '^clear_mode=compact$' "${CTX_DIR}/s-clear3.budget" &&
    grep -q '^clear_mode=none$' "${CTX_DIR}/s-clear4.budget"; then
    ok "--compact and --no-clear set their modes"
else
    bad "--compact and --no-clear set their modes" "compact/no-clear budgets wrong"
fi

# --- Stop spawns the sender, which types /clear into the pane ---------------
export TMUX_STUB_LOG="$TMPROOT/tmux-clear.log"
: >"$TMUX_STUB_LOG"
printf '{"session_id":"s-clear","hook_event_name":"Stop","cwd":"/tmp"}' |
    env PATH="$STUBBIN:$PATH" TMUX_PANE='%9' "$SCRIPT" check >"$TMPROOT/out" 2>"$TMPROOT/err"
spawn_rc=$?
if [ "$spawn_rc" -eq 0 ] && [ ! -s "$TMPROOT/out" ] &&
    grep -q '^clear_attempts=1$' "$CB"; then
    ok "Stop with clear_mode=clear spawns the sender silently and counts the attempt"
else
    bad "Stop with clear_mode=clear spawns the sender silently and counts the attempt" \
        "rc=$spawn_rc out='$(cat "$TMPROOT/out")' attempts='$(grep '^clear_attempts=' "$CB")'"
fi

# wait for the Enter, which is the last of the two send-keys
if wait_for "$TMUX_STUB_LOG" 'send-keys .* C-m' 10; then
    keys_line="$(grep -n 'send-keys' "$TMUX_STUB_LOG" | head -n 2)"
    first="$(printf '%s\n' "$keys_line" | sed -n 1p)"
    second="$(printf '%s\n' "$keys_line" | sed -n 2p)"
    case "$first:$second" in
    *'/clear'*:*'C-m'*) ok "the sender types /clear, then Enter as a separate send-keys" ;;
    *) bad "the sender types /clear, then Enter as a separate send-keys" "log: $(cat "$TMUX_STUB_LOG")" ;;
    esac
else
    bad "the sender types /clear, then Enter as a separate send-keys" \
        "no send-keys within 10s: $(cat "$TMUX_STUB_LOG")"
fi

if [ -f "${CTX_DIR}/last-clear.json" ] &&
    [ "$(jq -r '.prev_session_id' "${CTX_DIR}/last-clear.json")" = "s-clear" ] &&
    [ "$(jq -r '.mode' "${CTX_DIR}/last-clear.json")" = "clear" ]; then
    ok "the sender writes last-clear.json for the next session"
else
    bad "the sender writes last-clear.json for the next session" \
        "$(cat "${CTX_DIR}/last-clear.json" 2>/dev/null)"
fi
if wait_for "$CB" '^clear_mode=none$' 5; then
    ok "the sender resets clear_mode after sending"
else
    bad "the sender resets clear_mode after sending" "$(grep '^clear_mode=' "$CB")"
fi

# --- race guard: a prompt after the landing aborts the clear ----------------
fixture s-race 40
"$SCRIPT" landed --clear --summary "aborted handover" s-race >/dev/null 2>&1
RB="${CTX_DIR}/s-race.budget"
# a prompt submitted after the landing -> the context is no longer landed
printf 'last_prompt_ts=%s\n' "$(($(date +%s) + 10))" >>"$RB"
export TMUX_STUB_LOG="$TMPROOT/tmux-race.log"
: >"$TMUX_STUB_LOG"
printf '{"session_id":"s-race","hook_event_name":"Stop","cwd":"/tmp"}' |
    env PATH="$STUBBIN:$PATH" TMUX_PANE='%9' "$SCRIPT" check >/dev/null 2>&1
if wait_for "$RB" '^clear_aborted=new-prompt$' 10; then
    if ! grep -q 'send-keys' "$TMUX_STUB_LOG" && grep -q '^clear_mode=none$' "$RB"; then
        ok "a prompt after the landing aborts the sender before any keystroke"
    else
        bad "a prompt after the landing aborts the sender before any keystroke" \
            "log='$(cat "$TMUX_STUB_LOG")' budget='$(cat "$RB")'"
    fi
else
    bad "a prompt after the landing aborts the sender before any keystroke" \
        "clear_aborted never written: $(cat "$RB")"
fi

# --- UserPromptSubmit records last_prompt_ts --------------------------------
fixture s-lpts 10
"$SCRIPT" landed --clear --summary "x" s-lpts >/dev/null 2>&1
run_check s-lpts UserPromptSubmit
if grep -q '^last_prompt_ts=[0-9][0-9]*$' "${CTX_DIR}/s-lpts.budget"; then
    ok "UserPromptSubmit records last_prompt_ts"
else
    bad "UserPromptSubmit records last_prompt_ts" "$(cat "${CTX_DIR}/s-lpts.budget")"
fi

# --- no tmux pane: say so instead of silently doing nothing -----------------
fixture s-notmux 40
"$SCRIPT" landed --clear --summary "no pane here" s-notmux >/dev/null 2>&1
printf '{"session_id":"s-notmux","hook_event_name":"Stop","cwd":"/tmp"}' |
    env PATH="$STUBBIN:$PATH" TMUX_PANE= "$SCRIPT" check >"$TMPROOT/out" 2>/dev/null
notmux_rc=$?
notmux_ctx="$(jq -r '.hookSpecificOutput.additionalContext' <"$TMPROOT/out" 2>/dev/null)"
if [ "$notmux_rc" -eq 0 ] &&
    [ "$(jq -r '.hookSpecificOutput.hookEventName' <"$TMPROOT/out" 2>/dev/null)" = "Stop" ] &&
    case "$notmux_ctx" in *"self-clear is not possible"*) true ;; *) false ;; esac &&
    grep -q '^clear_mode=none$' "${CTX_DIR}/s-notmux.budget"; then
    ok "Stop with clear_mode but no TMUX_PANE returns additionalContext and exits 0"
else
    bad "Stop with clear_mode but no TMUX_PANE returns additionalContext and exits 0" \
        "rc=$notmux_rc out='$(cat "$TMPROOT/out")'"
fi

# --- two attempts is the limit ----------------------------------------------
fixture s-attempts 40
"$SCRIPT" landed --clear --summary "twice is enough" s-attempts >/dev/null 2>&1
AB="${CTX_DIR}/s-attempts.budget"
printf 'clear_attempts=2\n' >>"$AB"
export TMUX_STUB_LOG="$TMPROOT/tmux-attempts.log"
: >"$TMUX_STUB_LOG"
printf '{"session_id":"s-attempts","hook_event_name":"Stop","cwd":"/tmp"}' |
    env PATH="$STUBBIN:$PATH" TMUX_PANE='%9' "$SCRIPT" check >"$TMPROOT/out" 2>/dev/null
att_ctx="$(jq -r '.hookSpecificOutput.additionalContext' <"$TMPROOT/out" 2>/dev/null)"
if case "$att_ctx" in *"gave up after 2 attempts"*) true ;; *) false ;; esac &&
    grep -q '^clear_mode=none$' "$AB"; then
    ok "a third Stop after two timed-out attempts gives up and says so"
else
    bad "a third Stop after two timed-out attempts gives up and says so" \
        "out='$(cat "$TMPROOT/out")'"
fi

# --- session-start injection -------------------------------------------------
printf '{"prev_session_id":"sess-old","mode":"clear","summary":"landed PR #93","ts":%s}\n' \
    "$(date +%s)" >"${CTX_DIR}/last-clear.json"
printf '{"session_id":"new-one","source":"clear","cwd":"/tmp"}' |
    "$SCRIPT" session-start >"$TMPROOT/out" 2>"$TMPROOT/err"
ss_rc=$?
ss_out="$(cat "$TMPROOT/out")"
if [ "$ss_rc" -eq 0 ] && [ "$(wc -l <"$TMPROOT/out")" -eq 1 ] &&
    case "$ss_out" in *"previous session sess-old self-cleared at"*"landed PR #93"*) true ;; *) false ;; esac &&
    [ ! -f "${CTX_DIR}/last-clear.json" ]; then
    ok "session-start prints one handover line for source=clear and consumes the marker"
else
    bad "session-start prints one handover line for source=clear and consumes the marker" \
        "rc=$ss_rc out='$ss_out'"
fi

printf '{"prev_session_id":"sess-old","mode":"compact","summary":"s","ts":%s}\n' \
    "$(date +%s)" >"${CTX_DIR}/last-clear.json"
printf '{"session_id":"new-one","source":"startup","cwd":"/tmp"}' |
    "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
if [ ! -s "$TMPROOT/out" ] && [ -f "${CTX_DIR}/last-clear.json" ]; then
    ok "session-start prints nothing for source=startup and keeps the marker"
else
    bad "session-start prints nothing for source=startup and keeps the marker" \
        "out='$(cat "$TMPROOT/out")'"
fi

printf '{"prev_session_id":"sess-old","mode":"clear","summary":"s","ts":%s}\n' \
    "$(($(date +%s) - 1200))" >"${CTX_DIR}/last-clear.json"
printf '{"session_id":"new-one","source":"clear","cwd":"/tmp"}' |
    "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
if [ ! -s "$TMPROOT/out" ]; then
    ok "session-start prints nothing for a marker older than 15 min"
else
    bad "session-start prints nothing for a marker older than 15 min" "out='$(cat "$TMPROOT/out")'"
fi
rm -f "${CTX_DIR}/last-clear.json"

# --- pre-compact records the auto-compaction --------------------------------
fixture s-ac 15
printf 'landed_ts=0\n' >"${CTX_DIR}/s-ac.budget"
printf '{"session_id":"s-ac","hook_event_name":"PreCompact","trigger":"auto","custom_instructions":""}' |
    "$SCRIPT" pre-compact >"$TMPROOT/out" 2>/dev/null
pc_rc=$?
if [ "$pc_rc" -eq 0 ] && [ ! -s "$TMPROOT/out" ] &&
    grep -q '^autocompact_ts=[0-9][0-9]*$' "${CTX_DIR}/s-ac.budget"; then
    ok "pre-compact with trigger=auto records autocompact_ts and stays silent"
else
    bad "pre-compact with trigger=auto records autocompact_ts and stays silent" \
        "rc=$pc_rc out='$(cat "$TMPROOT/out")' budget='$(cat "${CTX_DIR}/s-ac.budget")'"
fi

assert_context "the next UserPromptSubmit reports the auto-compaction" s-ac UserPromptSubmit \
    "the harness auto-compacted this session at 30000 tokens before a landing ran"
assert_silent "the auto-compaction is reported once per compaction" s-ac UserPromptSubmit

printf '{"session_id":"s-ac2","hook_event_name":"PreCompact","trigger":"manual","custom_instructions":"keep X"}' |
    "$SCRIPT" pre-compact >"$TMPROOT/out" 2>/dev/null
if [ ! -f "${CTX_DIR}/s-ac2.budget" ] && [ ! -s "$TMPROOT/out" ]; then
    ok "pre-compact ignores a manual compaction"
else
    bad "pre-compact ignores a manual compaction" "budget exists or stdout not empty"
fi

echo
echo "----"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
