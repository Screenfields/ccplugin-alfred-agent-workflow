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
assert_context "PostToolUse injects once at a tier" s-cap PostToolUse "soft threshold 20%"
printf 'last_tier=soft\nlast_nag_ts=%s\nptu_tier=soft\n' "$(($(date +%s) - 601))" >"${CTX_DIR}/s-cap.budget"
assert_silent "PostToolUse stays silent at the same tier after the window" s-cap PostToolUse
assert_context "UserPromptSubmit still nags after the window" s-cap UserPromptSubmit \
    "soft threshold 20%"

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
export ALFRED_CONTEXT_SOFT_PCT="twenty" ALFRED_CONTEXT_HARD_PCT=""
assert_context "non-numeric thresholds fall back to 20/35 silently" s-bad UserPromptSubmit \
    "soft threshold 20%"
export ALFRED_CONTEXT_SOFT_PCT=20 ALFRED_CONTEXT_HARD_PCT=35

echo
echo "----"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
