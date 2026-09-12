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

# run_check <session_id> <hook_event_name> — sets RC / OUT_TXT / ERR_TXT.
# Deliberately not a command substitution: RC must survive.
run_check() {
    printf '{"session_id":"%s","hook_event_name":"%s","cwd":"/tmp"}' "$1" "$2" |
        "$SCRIPT" check >"$TMPROOT/out" 2>"$TMPROOT/err"
    RC=$?
    OUT_TXT="$(cat "$TMPROOT/out")"
    ERR_TXT="$(cat "$TMPROOT/err")"
    return 0
}

# assert_silent <label> <session_id> <event>
assert_silent() {
    run_check "$2" "$3"
    if [ -n "$OUT_TXT" ]; then
        bad "$1" "expected no stdout, got: $OUT_TXT"
    elif [ "$RC" -ne 0 ]; then
        bad "$1" "expected exit 0, got $RC"
    else
        ok "$1"
    fi
}

# assert_context <label> <session_id> <event> <expected substring>
assert_context() {
    local ctx
    run_check "$2" "$3"
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
    "CONTEXT BUDGET: 25% used (soft threshold 20%). Land at the next natural boundary: run /alfred-agent:land --mode=light."
assert_silent "25% second call within 10 min is silent" s-soft UserPromptSubmit
assert_silent "25% PostToolUse within the same window is silent too" s-soft PostToolUse
assert_silent "25% Stop never blocks at soft tier" s-soft Stop

# --- PostToolUse carries its own hookEventName ------------------------------
fixture s-ptu 25
assert_context "PostToolUse injection is labelled PostToolUse" s-ptu PostToolUse \
    "soft threshold 20%"

# --- rate-limit window expiry ----------------------------------------------
fixture s-window 25
run_check s-window UserPromptSubmit
printf 'last_tier=soft\nlast_nag_ts=%s\n' "$(($(date +%s) - 601))" >"${CTX_DIR}/s-window.budget"
assert_context "soft reminder returns after the 10 min window" s-window UserPromptSubmit \
    "soft threshold 20%"

# --- tier escalation resets the timer --------------------------------------
fixture s-esc 25
run_check s-esc UserPromptSubmit
fixture s-esc 40
assert_context "soft -> hard escalation injects immediately" s-esc UserPromptSubmit \
    "hard threshold 35%"

# --- 40% : hard tier + Stop blocks exactly once -----------------------------
fixture s-hard 40
assert_context "40% injects the hard reminder verbatim" s-hard UserPromptSubmit \
    "CONTEXT BUDGET: 40% used (hard threshold 35%). LAND NOW: run /alfred-agent:land --mode=light before anything else."

run_check s-hard Stop
if [ "$RC" -eq 2 ] && [ -z "$OUT_TXT" ] && printf '%s' "$ERR_TXT" | grep -q "LAND NOW\|land --mode=light"; then
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
export ALFRED_CONTEXT_SOFT_PCT=10 ALFRED_CONTEXT_HARD_PCT=15
assert_context "ALFRED_CONTEXT_SOFT_PCT override applies" s-env UserPromptSubmit \
    "soft threshold 10%"
export ALFRED_CONTEXT_SOFT_PCT=20 ALFRED_CONTEXT_HARD_PCT=35

# --- malformed input --------------------------------------------------------
printf 'not json' | "$SCRIPT" check >"$TMPROOT/out" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMPROOT/out" ]; then
    ok "malformed stdin is silent and exits 0"
else
    bad "malformed stdin is silent and exits 0" "rc=$rc out='$(cat "$TMPROOT/out")'"
fi

echo
echo "----"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
