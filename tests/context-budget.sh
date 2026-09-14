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

# The harness itself runs inside a Claude Code session, which exports both of
# these. Left set, they would outrank every pointer the resolution cases test.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID TMUX_PANE

export ALFRED_STATE_DIR="$TMPROOT/state"
export ALFRED_CONTEXT_SOFT_PCT=20
export ALFRED_CONTEXT_HARD_PCT=35
# The fixture writes used = pct * 2000, so these token thresholds sit exactly on
# the 20% / 35% marks of its 200k window: every pre-token case keeps its tier.
export ALFRED_CONTEXT_CONFIRM_SECONDS=3
export ALFRED_CONTEXT_SOFT_TOKENS=40000
export ALFRED_CONTEXT_HARD_TOKENS=70000
# Interactive deferral off by default: every case below this line asserts the
# unattended behaviour (block the turn, arm the sender), which is what the hook
# does whenever no human prompt is recent. The deferral cases set the window
# themselves. 0 is the off switch — `now - last_prompt_ts < 0` is never true.
export ALFRED_CONTEXT_INTERACTIVE_SECONDS=0
# landed's completeness gate (Change 5a) looks at background-task transcripts
# under this base dir. Point it at a throwaway path so the suite never touches
# the real host's /tmp/claude-<uid> tree.
export ALFRED_CLAUDE_TMP_DIR="$TMPROOT/claudetmp"
CTX_DIR="$ALFRED_STATE_DIR/context"
mkdir -p "$CTX_DIR"

# write_handover <context_dir> [bytes] — a valid (or, given bytes, deliberately
# oversized) handover.md, including a Metis capture id so the completeness
# gate's capture-id check passes by default. `landed --clear/--compact/
# --restart` refuses to arm without one, so every pre-existing test that arms
# a mode needs one present; tests of the gate itself remove, age, oversize, or
# strip the capture id around their own assertions.
write_handover() {
    local dir="$1" bytes="${2:-0}"
    if [ "$bytes" -gt 0 ] 2>/dev/null; then
        head -c "$bytes" /dev/zero | tr '\0' 'x' >"${dir}/handover.md"
    else
        printf 'landed: PR #93 merged (cap-1a2b3c4d).\nfirst thing: pick up issue #847.\n' >"${dir}/handover.md"
    fi
}

# The default context dir gets one up front so every existing --clear/--compact
# test below (which predates the handover gate) keeps working unmodified.
write_handover "$CTX_DIR"

# --- a real, disposable git repo to serve as $PWD for the completeness gate's
# git-completeness check (Change 5a #2). Clean and pushed by default; the
# dedicated git-check tests dirty/unpush/branch it and restore this baseline
# afterward so later tests in the suite are unaffected.
GITROOT="$TMPROOT/gitroot"
GITREMOTE="$TMPROOT/gitremote.git"
git init -q "$GITROOT"
git init -q --bare "$GITREMOTE"
(
    cd "$GITROOT" || exit 1
    git config user.email "test@example.com"
    git config user.name "test"
    echo "seed" >seed.txt
    git add seed.txt
    git commit -q -m seed
    git remote add origin "$GITREMOTE"
    git push -q -u origin HEAD:main
)
cd "$GITROOT" || exit 1

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

# A tmux stub that records its argv and answers the questions pane_idle asks.
#   TMUX_STUB_CURSOR   what display-message reports as cursor_x (default 2 = idle)
#   TMUX_STUB_INMODE   what display-message reports as pane_in_mode (default 0 =
#                      not in a tmux mode; 1 = copy-mode/view-mode, e.g. the
#                      owner scrolled back)
#   TMUX_STUB_INMODE_TOGGLE_AFTER / TMUX_STUB_INMODE_COUNT_FILE
#                      when set, pane_in_mode is 1 for this many display-message
#                      calls and 0 after — simulates the owner leaving the mode
#                      partway through the sender's polling, counted in the file
#   TMUX_STUB_CAPTURE  what capture-pane prints (default empty = not mid-turn)
#   TMUX_STUB_HANG_ON_ENTER / TMUX_STUB_HANG_SECONDS
#                      when set, the Enter (C-m) send-keys call sleeps this many
#                      seconds (default 5) before returning — simulates a tmux
#                      client that never gets an answer back (e.g. a
#                      command-prompt blocked on a non-interactive client)
#   TMUX_STUB_CONSUME  a file to copy-then-delete when Enter is sent, standing in
#                      for the new session's SessionStart hook consuming the marker
STUBBIN="$TMPROOT/stubbin"
mkdir -p "$STUBBIN"
cat >"$STUBBIN/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
case "${1:-}" in
display-message)
    inmode="${TMUX_STUB_INMODE:-0}"
    if [ -n "${TMUX_STUB_INMODE_TOGGLE_AFTER:-}" ]; then
        n=$(cat "$TMUX_STUB_INMODE_COUNT_FILE" 2>/dev/null || echo 0)
        n=$((n + 1))
        printf '%s' "$n" >"$TMUX_STUB_INMODE_COUNT_FILE"
        if [ "$n" -le "$TMUX_STUB_INMODE_TOGGLE_AFTER" ]; then
            inmode=1
        else
            inmode=0
        fi
    fi
    echo "${TMUX_STUB_CURSOR:-2} ${inmode}"
    ;;
capture-pane) printf '%s\n' "${TMUX_STUB_CAPTURE:-}" ;;
send-keys)
    if [ -n "${TMUX_STUB_HANG_ON_ENTER:-}" ] && [ "${*: -1}" = "C-m" ]; then
        sleep "${TMUX_STUB_HANG_SECONDS:-5}"
    fi
    if [ -n "${TMUX_STUB_CONSUME:-}" ] && [ "${*: -1}" = "C-m" ]; then
        cp "$TMUX_STUB_CONSUME" "${TMUX_STUB_CONSUME}.seen" 2>/dev/null
        rm -f "$TMUX_STUB_CONSUME"
    fi
    ;;
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

# wait_outcome <budget file> <seconds> — the sender records exactly one outcome
# timestamp, so that is the only reliable "it has finished" signal. clear_sending
# is no good: a landing writes it empty before the sender ever runs.
wait_outcome() {
    local i=0
    while [ "$i" -lt "$2" ]; do
        grep -qE '^(cleared_ts|clear_unconfirmed_ts)=[0-9]' "$1" 2>/dev/null && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# stop_with_stub <session_id> — fire a Stop hook with the tmux stub on PATH.
stop_with_stub() {
    printf '{"session_id":"%s","hook_event_name":"Stop","cwd":"/tmp"}' "$1" |
        env PATH="$STUBBIN:$PATH" TMUX_PANE='%9' "$SCRIPT" check >"$TMPROOT/out" 2>"$TMPROOT/err"
    RC=$?
    OUT_TXT="$(cat "$TMPROOT/out")"
    return 0
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

# --- Stop spawns the sender, which types /clear and is confirmed ------------
export TMUX_STUB_LOG="$TMPROOT/tmux-clear.log"
export TMUX_STUB_CONSUME="${CTX_DIR}/last-clear.json"
: >"$TMUX_STUB_LOG"
stop_with_stub s-clear
if [ "$RC" -eq 0 ] && [ -z "$OUT_TXT" ] && grep -q '^clear_attempts=1$' "$CB"; then
    ok "Stop with clear_mode=clear spawns the sender silently and counts the attempt"
else
    bad "Stop with clear_mode=clear spawns the sender silently and counts the attempt" \
        "rc=$RC out='$OUT_TXT' attempts='$(grep '^clear_attempts=' "$CB")'"
fi

if wait_for "$TMUX_STUB_LOG" 'send-keys .* C-m' 10; then
    keys_line="$(grep 'send-keys' "$TMUX_STUB_LOG" | head -n 2)"
    first="$(printf '%s\n' "$keys_line" | sed -n 1p)"
    second="$(printf '%s\n' "$keys_line" | sed -n 2p)"
    case "$first:$second" in
    *'/clear'*:*'C-m'*) ok "the sender types /clear, then Enter as a separate send-keys" ;;
    *) bad "the sender types /clear, then Enter as a separate send-keys" "log: $(cat "$TMUX_STUB_LOG")" ;;
    esac
else
    bad "the sender types /clear, then Enter as a separate send-keys" \
        "no Enter within 10s: $(cat "$TMUX_STUB_LOG")"
fi

SEEN="${CTX_DIR}/last-clear.json.seen"
if [ -f "$SEEN" ] &&
    [ "$(jq -r '.prev_session_id' "$SEEN")" = "s-clear" ] &&
    [ "$(jq -r '.mode' "$SEEN")" = "clear" ] &&
    [ "$(jq -r '.summary' "$SEEN")" = "PR #93 merged; next session starts at issue #847" ]; then
    ok "the sender writes last-clear.json before the keystrokes"
else
    bad "the sender writes last-clear.json before the keystrokes" "$(cat "$SEEN" 2>/dev/null)"
fi
rm -f "$SEEN"

if wait_outcome "$CB" 15 && grep -q '^cleared_ts=[0-9][0-9]*$' "$CB" &&
    grep -q '^clear_mode=none$' "$CB"; then
    ok "a consumed marker confirms the clear: cleared_ts written, clear_mode=none"
else
    bad "a consumed marker confirms the clear: cleared_ts written, clear_mode=none" \
        "$(cat "$CB")"
fi

# --- an unconsumed marker is never reported as a clear ----------------------
unset TMUX_STUB_CONSUME
fixture s-unconf 40
"$SCRIPT" landed --clear --summary "unconfirmed run" s-unconf >/dev/null 2>&1
UB="${CTX_DIR}/s-unconf.budget"
export TMUX_STUB_LOG="$TMPROOT/tmux-unconf.log"
: >"$TMUX_STUB_LOG"
stop_with_stub s-unconf
if wait_outcome "$UB" 25; then
    if grep -q '^clear_unconfirmed_ts=[0-9][0-9]*$' "$UB" &&
        grep -q '^clear_mode=clear$' "$UB" &&
        ! grep -q '^cleared_ts=' "$UB" &&
        [ ! -f "${CTX_DIR}/last-clear.json" ]; then
        ok "an unconsumed marker is unconfirmed: no cleared_ts, clear_mode kept, marker removed"
    else
        bad "an unconsumed marker is unconfirmed: no cleared_ts, clear_mode kept, marker removed" \
            "budget='$(cat "$UB")' marker=$([ -f "${CTX_DIR}/last-clear.json" ] && echo present || echo gone)"
    fi
else
    bad "an unconsumed marker is unconfirmed: no cleared_ts, clear_mode kept, marker removed" \
        "sender recorded no outcome: $(cat "$UB")"
fi

# --- the owner is typing: cursor_x is not 2 --------------------------------
fixture s-typing 40
"$SCRIPT" landed --clear --summary "owner is typing" s-typing >/dev/null 2>&1
export TMUX_STUB_LOG="$TMPROOT/tmux-typing.log"
: >"$TMUX_STUB_LOG"
printf '{"session_id":"s-typing","hook_event_name":"Stop","cwd":"/tmp"}' |
    env PATH="$STUBBIN:$PATH" TMUX_PANE='%9' TMUX_STUB_CURSOR=7 "$SCRIPT" check >/dev/null 2>&1
sleep 6
if ! grep -q 'send-keys' "$TMUX_STUB_LOG"; then
    ok "text in the input box (cursor_x 7) means nothing is ever typed"
else
    bad "text in the input box (cursor_x 7) means nothing is ever typed" \
        "$(cat "$TMUX_STUB_LOG")"
fi

# --- the session is mid-turn: esc to interrupt is on screen ----------------
fixture s-busy 40
"$SCRIPT" landed --clear --summary "still working" s-busy >/dev/null 2>&1
export TMUX_STUB_LOG="$TMPROOT/tmux-busy.log"
: >"$TMUX_STUB_LOG"
printf '{"session_id":"s-busy","hook_event_name":"Stop","cwd":"/tmp"}' |
    env PATH="$STUBBIN:$PATH" TMUX_PANE='%9' \
    TMUX_STUB_CAPTURE='... (esc to interrupt)' "$SCRIPT" check >/dev/null 2>&1
sleep 6
if ! grep -q 'send-keys' "$TMUX_STUB_LOG"; then
    ok "a mid-turn pane (esc to interrupt) means nothing is ever typed"
else
    bad "a mid-turn pane (esc to interrupt) means nothing is ever typed" \
        "$(cat "$TMUX_STUB_LOG")"
fi

# --- copy mode: a pane in a tmux mode is never idle, even at cursor_x=2 -----
# The 2026-09-14 incident: a send-keys into a pane the owner had scrolled back
# (copy-mode) was read as mode navigation, not session input, and tmux opened a
# command-prompt on behalf of the sender that then blocked it for over an hour.
fixture s-copymode 40
"$SCRIPT" landed --clear --summary "owner scrolled back" s-copymode >/dev/null 2>&1
export TMUX_STUB_LOG="$TMPROOT/tmux-copymode.log"
: >"$TMUX_STUB_LOG"
env PATH="$STUBBIN:$PATH" ALFRED_CONTEXT_SENDER_DEADLINE=4 TMUX_STUB_INMODE=1 \
    "$SCRIPT" sender s-copymode '%9' clear >/dev/null 2>&1
if ! grep -q 'send-keys' "$TMUX_STUB_LOG" &&
    grep -q 'tmux mode' "${CTX_DIR}/s-copymode.sender.log"; then
    ok "a pane in a tmux mode (copy-mode) is never idle: nothing is typed, and the timeout says why"
else
    bad "a pane in a tmux mode (copy-mode) is never idle: nothing is typed, and the timeout says why" \
        "tmux_log='$(cat "$TMUX_STUB_LOG")' sender_log='$(cat "${CTX_DIR}/s-copymode.sender.log" 2>/dev/null)'"
fi

# --- copy mode: leaving the mode mid-poll lets the send proceed -------------
fixture s-copymode2 40
"$SCRIPT" landed --clear --summary "owner came back" s-copymode2 >/dev/null 2>&1
export TMUX_STUB_LOG="$TMPROOT/tmux-copymode2.log"
: >"$TMUX_STUB_LOG"
env PATH="$STUBBIN:$PATH" TMUX_STUB_CONSUME="${CTX_DIR}/last-clear.json" \
    TMUX_STUB_INMODE_TOGGLE_AFTER=1 TMUX_STUB_INMODE_COUNT_FILE="$TMPROOT/copymode2-count" \
    "$SCRIPT" sender s-copymode2 '%9' clear >/dev/null 2>&1
if grep -q 'send-keys .* C-m' "$TMUX_STUB_LOG"; then
    ok "a pane that leaves the tmux mode mid-poll goes idle and the send proceeds"
else
    bad "a pane that leaves the tmux mode mid-poll goes idle and the send proceeds" \
        "$(cat "$TMUX_STUB_LOG")"
fi
rm -f "${CTX_DIR}/last-clear.json.seen"

# --- a hung tmux client cannot block the sender past its own timeout --------
# The per-call `timeout` wrapper is the fix for the same incident: even without
# the copy-mode guard above, a tmux client that never answers must not hang the
# sender forever. Simulated here on the Enter (C-m) send-keys call.
fixture s-hang 40
"$SCRIPT" landed --clear --summary "should not hang" s-hang >/dev/null 2>&1
HB="${CTX_DIR}/s-hang.budget"
export TMUX_STUB_LOG="$TMPROOT/tmux-hang.log"
: >"$TMUX_STUB_LOG"
env PATH="$STUBBIN:$PATH" ALFRED_CONTEXT_TMUX_TIMEOUT=1 \
    TMUX_STUB_HANG_ON_ENTER=1 TMUX_STUB_HANG_SECONDS=3 \
    "$SCRIPT" sender s-hang '%9' clear >/dev/null 2>&1
if grep -q 'send-keys.*C-u' "$TMUX_STUB_LOG" &&
    grep -q 'timed out' "${CTX_DIR}/s-hang.sender.log" &&
    grep -q '^clear_mode=clear$' "$HB" &&
    ! grep -q '^cleared_ts=' "$HB"; then
    ok "a hung tmux client is bounded by the per-call timeout: logged, line wiped, nothing left half-typed"
else
    bad "a hung tmux client is bounded by the per-call timeout: logged, line wiped, nothing left half-typed" \
        "tmux_log='$(cat "$TMUX_STUB_LOG")' sender_log='$(cat "${CTX_DIR}/s-hang.sender.log" 2>/dev/null)' budget='$(cat "$HB")'"
fi

# --- compact mode carries the summary --------------------------------------
fixture s-comp 40
"$SCRIPT" landed --compact --summary "decisions on #847, PR #93 open" s-comp >/dev/null 2>&1
export TMUX_STUB_LOG="$TMPROOT/tmux-comp.log"
export TMUX_STUB_CONSUME="${CTX_DIR}/last-clear.json"
: >"$TMUX_STUB_LOG"
stop_with_stub s-comp
if wait_for "$TMUX_STUB_LOG" 'send-keys .* C-m' 10; then
    if grep -q 'send-keys -t %9 /compact Preserve: decisions on #847, PR #93 open' "$TMUX_STUB_LOG"; then
        ok "compact mode types /compact with the handover summary on one line"
    else
        bad "compact mode types /compact with the handover summary on one line" \
            "$(cat "$TMUX_STUB_LOG")"
    fi
else
    bad "compact mode types /compact with the handover summary on one line" \
        "no Enter within 10s: $(cat "$TMUX_STUB_LOG")"
fi
rm -f "${CTX_DIR}/last-clear.json.seen"
unset TMUX_STUB_CONSUME

# --- race guard: a prompt after the landing aborts the clear ----------------
fixture s-race 40
"$SCRIPT" landed --clear --summary "aborted handover" s-race >/dev/null 2>&1
RB="${CTX_DIR}/s-race.budget"
# a prompt submitted after the landing -> the context is no longer landed
printf 'last_prompt_ts=%s\n' "$(($(date +%s) + 10))" >>"$RB"
export TMUX_STUB_LOG="$TMPROOT/tmux-race.log"
: >"$TMUX_STUB_LOG"
stop_with_stub s-race
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

# --- concurrency: a second sender finds the claim taken --------------------
fixture s-claim 40
"$SCRIPT" landed --clear --summary "claimed" s-claim >/dev/null 2>&1
printf 'clear_mode=none\n' >>"${CTX_DIR}/s-claim.budget"
export TMUX_STUB_LOG="$TMPROOT/tmux-claim.log"
: >"$TMUX_STUB_LOG"
env PATH="$STUBBIN:$PATH" "$SCRIPT" sender s-claim '%9' clear >/dev/null 2>&1
if ! grep -q 'send-keys' "$TMUX_STUB_LOG" &&
    grep -q "abort: clear_mode is 'none'" "${CTX_DIR}/s-claim.sender.log"; then
    ok "a sender whose clear_mode was taken over aborts without typing"
else
    bad "a sender whose clear_mode was taken over aborts without typing" \
        "log='$(cat "$TMUX_STUB_LOG")' sender='$(cat "${CTX_DIR}/s-claim.sender.log" 2>/dev/null)'"
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
stop_with_stub s-attempts
att_ctx="$(jq -r '.hookSpecificOutput.additionalContext' <"$TMPROOT/out" 2>/dev/null)"
if case "$att_ctx" in *"gave up after 2 attempts"*) true ;; *) false ;; esac &&
    grep -q '^clear_mode=none$' "$AB"; then
    ok "a third Stop after two timed-out attempts gives up and says so"
else
    bad "a third Stop after two timed-out attempts gives up and says so" \
        "out='$(cat "$TMPROOT/out")'"
fi

# ===========================================================================
# Restart mode (Change 1): landed --restart + the sender running the command
# ===========================================================================

# restart-ok stands in for hub-restart: it arms and returns immediately in
# real life, with the actual /exit + respawn happening out-of-band once the
# new session's own SessionStart hook consumes the marker. The stub does that
# consumption itself (like TMUX_STUB_CONSUME does for the tmux send-keys
# path) so the sender's confirmation wait has something to observe.
cat >"$STUBBIN/restart-ok" <<'STUB'
#!/usr/bin/env bash
printf 'called\n' >>"${RESTART_STUB_LOG:-/dev/null}"
if [ -n "${RESTART_STUB_CONSUME:-}" ]; then
    cp "$RESTART_STUB_CONSUME" "${RESTART_STUB_CONSUME}.seen" 2>/dev/null
    rm -f "$RESTART_STUB_CONSUME"
fi
exit 0
STUB
chmod +x "$STUBBIN/restart-ok"

cat >"$STUBBIN/restart-fail" <<'STUB'
#!/usr/bin/env bash
printf 'called\n' >>"${RESTART_STUB_LOG:-/dev/null}"
exit 7
STUB
chmod +x "$STUBBIN/restart-fail"

fixture s-restart 40
env PATH="$STUBBIN:$PATH" ALFRED_SESSION_RESTART_CMD=restart-ok \
    "$SCRIPT" landed --restart --summary "restart me" s-restart >"$TMPROOT/out" 2>/dev/null
RB2="${CTX_DIR}/s-restart.budget"
if grep -q '^clear_mode=restart$' "$RB2" && grep -q "clear_mode=restart" "$TMPROOT/out"; then
    ok "landed --restart records clear_mode=restart when the restart command is on PATH"
else
    bad "landed --restart records clear_mode=restart when the restart command is on PATH" \
        "budget='$(cat "$RB2")' out='$(cat "$TMPROOT/out")'"
fi

fixture s-restart-missing 40
env PATH="$STUBBIN:/usr/bin:/bin" ALFRED_SESSION_RESTART_CMD=restart-does-not-exist \
    "$SCRIPT" landed --restart --summary "no cmd" s-restart-missing >"$TMPROOT/out" 2>"$TMPROOT/err"
RM="${CTX_DIR}/s-restart-missing.budget"
if grep -q '^clear_mode=none$' "$RM" && grep -q "restart command 'restart-does-not-exist' not found" "$TMPROOT/err"; then
    ok "landed --restart with a missing command downgrades to clear_mode=none but still records"
else
    bad "landed --restart with a missing command downgrades to clear_mode=none but still records" \
        "budget='$(cat "$RM")' err='$(cat "$TMPROOT/err")'"
fi

# sender runs the restart command, logs its exit, confirms via the marker
export RESTART_STUB_LOG="$TMPROOT/restart-ok.log"
: >"$RESTART_STUB_LOG"
export RESTART_STUB_CONSUME="${CTX_DIR}/last-clear.json"
export TMUX_STUB_LOG="$TMPROOT/tmux-restart.log"
: >"$TMUX_STUB_LOG"
printf '{"session_id":"s-restart","hook_event_name":"Stop","cwd":"/tmp"}' |
    env PATH="$STUBBIN:$PATH" ALFRED_SESSION_RESTART_CMD=restart-ok TMUX_PANE='%9' "$SCRIPT" check >/dev/null 2>&1
if wait_outcome "$RB2" 15 && grep -q '^cleared_ts=[0-9][0-9]*$' "$RB2" &&
    grep -q '^clear_mode=none$' "$RB2" && grep -q 'called' "$RESTART_STUB_LOG" &&
    ! grep -q 'send-keys' "$TMUX_STUB_LOG"; then
    ok "the sender runs the restart command (not tmux send-keys) and confirms via the consumed marker"
else
    bad "the sender runs the restart command (not tmux send-keys) and confirms via the consumed marker" \
        "budget='$(cat "$RB2")' restart_log='$(cat "$RESTART_STUB_LOG" 2>/dev/null)' tmux_log='$(cat "$TMUX_STUB_LOG" 2>/dev/null)'"
fi
unset RESTART_STUB_CONSUME
rm -f "${CTX_DIR}/last-clear.json.seen"

# sender: the restart command fails (non-zero exit) — clear_mode kept for retry
fixture s-restart-fail 40
env PATH="$STUBBIN:$PATH" ALFRED_SESSION_RESTART_CMD=restart-fail \
    "$SCRIPT" landed --restart --summary "will fail" s-restart-fail >/dev/null 2>&1
RF="${CTX_DIR}/s-restart-fail.budget"
export TMUX_STUB_LOG="$TMPROOT/tmux-restart-fail.log"
: >"$TMUX_STUB_LOG"
printf '{"session_id":"s-restart-fail","hook_event_name":"Stop","cwd":"/tmp"}' |
    env PATH="$STUBBIN:$PATH" ALFRED_SESSION_RESTART_CMD=restart-fail TMUX_PANE='%9' "$SCRIPT" check >/dev/null 2>&1
if wait_for "$RF" '^clear_mode=restart$' 10 && [ ! -f "${CTX_DIR}/last-clear.json" ]; then
    ok "a failing restart command leaves clear_mode=restart for the next attempt"
else
    bad "a failing restart command leaves clear_mode=restart for the next attempt" "$(cat "$RF")"
fi

# sender: independent defensive re-check — the command named at send time is
# not the one that was on PATH at arm time (simulates a PATH/config change)
fixture s-restart-race 40
env PATH="$STUBBIN:$PATH" ALFRED_SESSION_RESTART_CMD=restart-ok \
    "$SCRIPT" landed --restart --summary "race" s-restart-race >/dev/null 2>&1
RR="${CTX_DIR}/s-restart-race.budget"
export TMUX_STUB_LOG="$TMPROOT/tmux-restart-race.log"
: >"$TMUX_STUB_LOG"
printf '{"session_id":"s-restart-race","hook_event_name":"Stop","cwd":"/tmp"}' |
    env PATH="$STUBBIN:$PATH" ALFRED_SESSION_RESTART_CMD=restart-vanished TMUX_PANE='%9' "$SCRIPT" check >/dev/null 2>&1
if wait_for "$RR" '^clear_mode=none$' 10 &&
    wait_for "${CTX_DIR}/s-restart-race.sender.log" "no restart command" 5 &&
    ! grep -q 'send-keys' "$TMPROOT/tmux-restart-race.log"; then
    ok "the sender independently re-checks the restart command and aborts if it vanished"
else
    bad "the sender independently re-checks the restart command and aborts if it vanished" \
        "budget='$(cat "$RR")' sender='$(cat "${CTX_DIR}/s-restart-race.sender.log" 2>/dev/null)'"
fi

# ===========================================================================
# Session id resolution for a landing that arms a clear
# ===========================================================================

RESOLVE="$TMPROOT/resolve"
mkdir -p "$RESOLVE/context"
printf '{"pct":40,"used":80000,"size":200000,"ts":%s}\n' "$(date +%s)" >"$RESOLVE/context/r-code.json"
printf '{"pct":40,"used":80000,"size":200000,"ts":%s}\n' "$(date +%s)" >"$RESOLVE/context/r-pane.json"
write_handover "$RESOLVE/context"

# check writes a pane-keyed pointer next to the unkeyed one
printf '{"session_id":"r-pane","hook_event_name":"UserPromptSubmit","cwd":"/tmp"}' |
    env ALFRED_STATE_DIR="$RESOLVE" TMUX_PANE='%12' "$SCRIPT" check >/dev/null 2>&1
if [ "$(cat "$RESOLVE/context/current-session.12" 2>/dev/null)" = "r-pane" ] &&
    [ "$(cat "$RESOLVE/context/current-session" 2>/dev/null)" = "r-pane" ]; then
    ok "check writes both the pane-keyed and the unkeyed session pointer"
else
    found_files=""
    for f in "$RESOLVE"/context/*; do
        [ -e "$f" ] || continue
        found_files="${found_files}${f##*/} "
    done
    bad "check writes both the pane-keyed and the unkeyed session pointer" "files: $found_files"
fi

# CLAUDE_CODE_SESSION_ID is what the Bash tool exports, and it outranks the pointer
env ALFRED_STATE_DIR="$RESOLVE" CLAUDE_CODE_SESSION_ID=r-code TMUX_PANE='%12' \
    "$SCRIPT" landed --clear --summary "from the env" >"$TMPROOT/out" 2>/dev/null
if grep -q "session r-code, via CLAUDE_CODE_SESSION_ID" "$TMPROOT/out" &&
    grep -q '^clear_mode=clear$' "$RESOLVE/context/r-code.budget"; then
    ok "CLAUDE_CODE_SESSION_ID outranks the pointers and arms the clear"
else
    bad "CLAUDE_CODE_SESSION_ID outranks the pointers and arms the clear" \
        "out='$(cat "$TMPROOT/out")'"
fi

# with no env at all, the pane-keyed pointer wins over the unkeyed one
printf 'r-stale\n' >"$RESOLVE/context/current-session"
env ALFRED_STATE_DIR="$RESOLVE" TMUX_PANE='%12' "$SCRIPT" landed --clear --summary "from the pane" \
    >"$TMPROOT/out" 2>/dev/null
if grep -q "session r-pane, via current-session (pane %12)" "$TMPROOT/out" &&
    grep -q '^clear_mode=clear$' "$RESOLVE/context/r-pane.budget"; then
    ok "the pane-keyed pointer outranks the unkeyed one"
else
    bad "the pane-keyed pointer outranks the unkeyed one" "out='$(cat "$TMPROOT/out")'"
fi

# a guessed session id must never arm a clear
GUESS="$TMPROOT/guess"
mkdir -p "$GUESS/context"
printf '{"pct":40,"used":80000,"size":200000,"ts":%s}\n' "$(date +%s)" >"$GUESS/context/g-one.json"
env ALFRED_STATE_DIR="$GUESS" "$SCRIPT" landed --clear --summary "guessed" \
    >"$TMPROOT/out" 2>"$TMPROOT/err"
if grep -q '^landed_ts=[0-9][0-9]*$' "$GUESS/context/g-one.budget" &&
    grep -q '^clear_mode=none$' "$GUESS/context/g-one.budget" &&
    grep -q "refusing --clear" "$TMPROOT/err"; then
    ok "--clear is refused when the session id was guessed from the newest state file"
else
    bad "--clear is refused when the session id was guessed from the newest state file" \
        "budget='$(cat "$GUESS/context/g-one.budget")' err='$(cat "$TMPROOT/err")'"
fi

# ===========================================================================
# Numeric hygiene
# ===========================================================================

fixture s-junk 40
printf 'crossing_ts=soon\nstop_blocked=maybe\nlanded_ts=yesterday\nlast_nag_ts=never\nclear_attempts=lots\nlast_prompt_ts=-\n' \
    >"${CTX_DIR}/s-junk.budget"
run_check s-junk Stop
junk_stop_rc=$RC
junk_stop_err="$ERR_TXT"
run_check s-junk UserPromptSubmit
if [ "$junk_stop_rc" -eq 2 ] && [ "$RC" -eq 0 ] &&
    ! printf '%s' "$junk_stop_err" | grep -qi "integer expression\|syntax error"; then
    ok "a budget file full of non-numeric values never produces an arithmetic error"
else
    bad "a budget file full of non-numeric values never produces an arithmetic error" \
        "stop_rc=$junk_stop_rc ups_rc=$RC err='$junk_stop_err'"
fi

# ===========================================================================
# session-start: classification (graceful / unplanned / fresh) + handover
# ===========================================================================

# --- graceful: marker present, no handover file yet — isolates the marker line
rm -f "${CTX_DIR}/handover.md"
printf '{"prev_session_id":"sess-old","mode":"clear","summary":"landed PR #93","ts":%s}\n' \
    "$(date +%s)" >"${CTX_DIR}/last-clear.json"
printf '{"session_id":"new-one","source":"clear","cwd":"/tmp"}' |
    "$SCRIPT" session-start >"$TMPROOT/out" 2>"$TMPROOT/err"
ss_rc=$?
ss_out="$(cat "$TMPROOT/out")"
if [ "$ss_rc" -eq 0 ] && [ "$(wc -l <"$TMPROOT/out")" -eq 1 ] &&
    case "$ss_out" in *"graceful clear after landing"*"previous session sess-old self-cleared at"*"landed PR #93"*) true ;; *) false ;; esac &&
    [ ! -f "${CTX_DIR}/last-clear.json" ]; then
    ok "graceful clear: one classified line, marker consumed"
else
    bad "graceful clear: one classified line, marker consumed" "rc=$ss_rc out='$ss_out'"
fi

printf '{"prev_session_id":"sess-old","mode":"compact","summary":"s","ts":%s}\n' \
    "$(date +%s)" >"${CTX_DIR}/last-clear.json"
printf '{"session_id":"new-one","source":"resume","cwd":"/tmp"}' |
    "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
if case "$(cat "$TMPROOT/out")" in *"graceful compact after landing"*"self-compacted"*) true ;; *) false ;; esac &&
    [ ! -f "${CTX_DIR}/last-clear.json" ]; then
    ok "graceful compact: source=resume also consumes the marker"
else
    bad "graceful compact: source=resume also consumes the marker" "out='$(cat "$TMPROOT/out")'"
fi

# restart's new session comes up via `claude -c`, which the Claude Code hooks
# docs report as source=resume — not source=startup or a dedicated "restart".
printf '{"prev_session_id":"sess-old","mode":"restart","summary":"s","ts":%s}\n' \
    "$(date +%s)" >"${CTX_DIR}/last-clear.json"
printf '{"session_id":"new-one","source":"resume","cwd":"/tmp"}' |
    "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
if case "$(cat "$TMPROOT/out")" in *"graceful restart after landing"*"restarted itself at"*) true ;; *) false ;; esac &&
    [ ! -f "${CTX_DIR}/last-clear.json" ]; then
    ok "graceful restart: claude -c (source=resume) prints the restart wording"
else
    bad "graceful restart: claude -c (source=resume) prints the restart wording" "out='$(cat "$TMPROOT/out")'"
fi

printf '{"prev_session_id":"sess-old","mode":"clear","summary":"s","ts":%s}\n' \
    "$(date +%s)" >"${CTX_DIR}/last-clear.json"
printf '{"session_id":"new-one","source":"startup","cwd":"/tmp"}' |
    "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
if [ -n "$(cat "$TMPROOT/out")" ] && [ ! -f "${CTX_DIR}/last-clear.json" ]; then
    ok "source=startup also consumes the marker (all four sources match)"
else
    bad "source=startup also consumes the marker (all four sources match)" "out='$(cat "$TMPROOT/out")'"
fi

# an unmatched source (e.g. a hook-level "fork") is not one of the four and
# never touches the marker
printf '{"prev_session_id":"sess-old","mode":"clear","summary":"s","ts":%s}\n' \
    "$(date +%s)" >"${CTX_DIR}/last-clear.json"
printf '{"session_id":"new-one","source":"fork","cwd":"/tmp"}' |
    "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
if [ ! -s "$TMPROOT/out" ] && [ -f "${CTX_DIR}/last-clear.json" ]; then
    ok "session-start ignores an unmatched source (fork) and keeps the marker"
else
    bad "session-start ignores an unmatched source (fork) and keeps the marker" "out='$(cat "$TMPROOT/out")'"
fi
rm -f "${CTX_DIR}/last-clear.json"

# Isolated dir: CTX_DIR holds many earlier fixture sessions that were never
# landed, so the unplanned-detection signal (last_prompt_ts > landed_ts on the
# most recent OTHER session) would otherwise fire here — correctly, for a dir
# that dirty, but not what this specific assertion means to isolate.
STALEMARKER_DIR="$TMPROOT/stalemarker"
mkdir -p "$STALEMARKER_DIR/context"
printf '{"prev_session_id":"sess-old","mode":"clear","summary":"s","ts":%s}\n' \
    "$(($(date +%s) - 1200))" >"$STALEMARKER_DIR/context/last-clear.json"
printf '{"session_id":"new-one","source":"clear","cwd":"/tmp"}' |
    ALFRED_STATE_DIR="$STALEMARKER_DIR" "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
if [ ! -s "$TMPROOT/out" ] && [ ! -f "$STALEMARKER_DIR/context/last-clear.json" ]; then
    ok "a marker older than 15 min prints nothing and is dropped"
else
    bad "a marker older than 15 min prints nothing and is dropped" "out='$(cat "$TMPROOT/out")'"
fi

# --- handover file: injected once under its own header, then consumed ------
write_handover "$CTX_DIR"
printf '{"session_id":"new-one","source":"startup","cwd":"/tmp"}' |
    "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
hv_out="$(cat "$TMPROOT/out")"
if case "$hv_out" in *"HANDOVER (written"*"consumed now):"*"first thing: pick up issue #847"*) true ;; *) false ;; esac &&
    [ ! -f "${CTX_DIR}/handover.md" ]; then
    ok "handover file is injected under its own header and deleted"
else
    bad "handover file is injected under its own header and deleted" "out='$hv_out'"
fi

# Isolated dir, same reason as above: CTX_DIR's other sessions would otherwise
# make this look unplanned.
SECONDSTART_DIR="$TMPROOT/secondstart"
mkdir -p "$SECONDSTART_DIR/context"
printf '{"session_id":"new-one","source":"startup","cwd":"/tmp"}' |
    ALFRED_STATE_DIR="$SECONDSTART_DIR" "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
if [ ! -s "$TMPROOT/out" ]; then
    ok "a fresh start with nothing pending injects nothing"
else
    bad "a fresh start with nothing pending injects nothing" "out='$(cat "$TMPROOT/out")'"
fi

# handover + marker together: both appear, marker line first, both consumed
write_handover "$CTX_DIR"
printf '{"prev_session_id":"sess-old","mode":"clear","summary":"both","ts":%s}\n' \
    "$(date +%s)" >"${CTX_DIR}/last-clear.json"
printf '{"session_id":"new-one","source":"clear","cwd":"/tmp"}' |
    "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
combo_out="$(cat "$TMPROOT/out")"
if case "$combo_out" in *"graceful clear after landing"*"HANDOVER (written"*) true ;; *) false ;; esac &&
    [ ! -f "${CTX_DIR}/last-clear.json" ] && [ ! -f "${CTX_DIR}/handover.md" ]; then
    ok "marker line and handover both appear, marker first, both consumed"
else
    bad "marker line and handover both appear, marker first, both consumed" "out='$combo_out'"
fi

# --- unplanned: a boot-recovery marker with no graceful marker -------------
# Isolated state dirs from here on: CTX_DIR by this point in the suite holds
# dozens of .budget files from earlier cases, and "most recent OTHER session"
# is an mtime race the shared dir should not be asked to settle.
UNPLANNED1="$TMPROOT/unplanned1"
mkdir -p "$UNPLANNED1/context"
BOOT_FILE="$UNPLANNED1/context/boot-recovery.json"
printf '{"ts":%s,"boot_ts":%s,"reason":"oom-kill","host":"dock-worker-3"}\n' \
    "$(date +%s)" "$(date +%s)" >"$BOOT_FILE"
printf '{"session_id":"new-one","source":"startup","cwd":"/tmp"}' |
    ALFRED_STATE_DIR="$UNPLANNED1" "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
boot_out="$(cat "$TMPROOT/out")"
if case "$boot_out" in *"unplanned restart detected"*"RECOVERY:"*"boot time"*"oom-kill"*"dock-worker-3"*"/alfred-agent:recover now"*) true ;; *) false ;; esac &&
    [ ! -f "$BOOT_FILE" ]; then
    ok "a boot-recovery marker classifies the start as unplanned and is consumed"
else
    bad "a boot-recovery marker classifies the start as unplanned and is consumed" "out='$boot_out'"
fi

# --- unplanned: no boot marker, but the most recent OTHER session shows
# activity after its last landing (or no landing at all) ---------------------
UNPLANNED2="$TMPROOT/unplanned2"
mkdir -p "$UNPLANNED2/context"
printf 'last_prompt_ts=%s\nlanded_ts=%s\n' "$(date +%s)" 0 >"$UNPLANNED2/context/sess-abrupt.budget"
printf '{"session_id":"new-two","source":"startup","cwd":"/tmp"}' |
    ALFRED_STATE_DIR="$UNPLANNED2" "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
abrupt_out="$(cat "$TMPROOT/out")"
if case "$abrupt_out" in *"unplanned restart detected"*"RECOVERY: previous session sess-abrupt"*"last landing never"*"/alfred-agent:recover now"*) true ;; *) false ;; esac; then
    ok "a most-recent-other-session with activity after its (never) landing is unplanned"
else
    bad "a most-recent-other-session with activity after its (never) landing is unplanned" "out='$abrupt_out'"
fi

# --- 5b: PreCompact cannot block (verified against the Claude Code hooks
# docs, both triggers) — an un-landed compaction is caught the same generic
# way, via the old session's last_prompt_ts/landed_ts, not via anything
# PreCompact itself records. Covered explicitly for both compact and clear.
COMPACT_DIR="$TMPROOT/compactflow"
mkdir -p "$COMPACT_DIR/context"
# last_prompt_ts is only ever recorded onto an EXISTING budget file (see
# do_check's UserPromptSubmit branch) — write the pre-existing state directly,
# the way a session with real prior activity would already have it, rather
# than depending on hook-call ordering the test does not otherwise need.
printf 'last_prompt_ts=%s\nlanded_ts=0\n' "$(date +%s)" >"$COMPACT_DIR/context/sess-precompact.budget"
printf '{"session_id":"sess-precompact","hook_event_name":"PreCompact","trigger":"auto","custom_instructions":""}' |
    ALFRED_STATE_DIR="$COMPACT_DIR" "$SCRIPT" pre-compact >/dev/null 2>&1
# no landed call at all — this session's compaction was never landed. Proves
# PreCompact itself records nothing that classification depends on; the
# pre-existing last_prompt_ts/landed_ts state alone drives it.
printf '{"session_id":"new-after-compact","source":"compact","cwd":"/tmp"}' |
    ALFRED_STATE_DIR="$COMPACT_DIR" "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
compact_out="$(cat "$TMPROOT/out")"
if case "$compact_out" in *"unplanned restart detected"*"RECOVERY: previous session sess-precompact"*) true ;; *) false ;; esac; then
    ok "an un-landed auto-compaction produces an unplanned next SessionStart(source=compact)"
else
    bad "an un-landed auto-compaction produces an unplanned next SessionStart(source=compact)" "out='$compact_out'"
fi

CLEARFLOW_DIR="$TMPROOT/clearflow"
mkdir -p "$CLEARFLOW_DIR/context"
printf 'last_prompt_ts=%s\nlanded_ts=0\n' "$(date +%s)" >"$CLEARFLOW_DIR/context/sess-preclear.budget"
# the owner ran a manual /clear directly — never went through `landed`
printf '{"session_id":"new-after-clear","source":"clear","cwd":"/tmp"}' |
    ALFRED_STATE_DIR="$CLEARFLOW_DIR" "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
clearflow_out="$(cat "$TMPROOT/out")"
if case "$clearflow_out" in *"unplanned restart detected"*"RECOVERY: previous session sess-preclear"*) true ;; *) false ;; esac; then
    ok "a manual /clear with no landed call produces an unplanned next SessionStart(source=clear)"
else
    bad "a manual /clear with no landed call produces an unplanned next SessionStart(source=clear)" "out='$clearflow_out'"
fi

# --- fresh: nothing known at all --------------------------------------------
FRESH_DIR="$TMPROOT/freshstart"
mkdir -p "$FRESH_DIR/context"
printf '{"session_id":"new-three","source":"startup","cwd":"/tmp"}' |
    ALFRED_STATE_DIR="$FRESH_DIR" "$SCRIPT" session-start >"$TMPROOT/out" 2>/dev/null
if [ ! -s "$TMPROOT/out" ]; then
    ok "fresh start (no marker, no boot file, no stale other session) prints nothing"
else
    bad "fresh start (no marker, no boot file, no stale other session) prints nothing" "out='$(cat "$TMPROOT/out")'"
fi

# restore the shared handover for every later test in this file that arms a
# real mode via landed --clear/--compact/--restart.
write_handover "$CTX_DIR"

# ===========================================================================
# Completeness gate (Change 5a): handover / git / running-agent / --force
# ===========================================================================
# All of these run with $PWD = $GITROOT (clean and pushed by default, see the
# top of this file) so the git-completeness check has a real, controlled tree
# to look at. Each dirtying test restores the baseline immediately after its
# own assertion so it never leaks into a later test.

# --- 1a: handover present but with no Metis capture id ----------------------
printf 'landed: PR #93 merged.\nfirst thing: pick up issue #847.\n' >"${CTX_DIR}/handover.md"
fixture s-gate-nocap 40
"$SCRIPT" landed --clear --summary "no capture id" s-gate-nocap >"$TMPROOT/out" 2>"$TMPROOT/err"
gate_rc=$?
if [ "$gate_rc" -ne 0 ] && [ ! -f "${CTX_DIR}/s-gate-nocap.budget" ] &&
    grep -q "no Metis capture id" "$TMPROOT/err"; then
    ok "a handover with no Metis capture id refuses the landing and records nothing"
else
    bad "a handover with no Metis capture id refuses the landing and records nothing" \
        "rc=$gate_rc err='$(cat "$TMPROOT/err")' budget_exists=$([ -f "${CTX_DIR}/s-gate-nocap.budget" ] && echo yes || echo no)"
fi
write_handover "$CTX_DIR"

# --- 1b: handover present, valid content, but stale (> 30 min old) ---------
write_handover "$CTX_DIR"
touch -d "40 minutes ago" "${CTX_DIR}/handover.md"
fixture s-gate-stale 40
"$SCRIPT" landed --clear --summary "stale handover" s-gate-stale >"$TMPROOT/out" 2>"$TMPROOT/err"
gate_rc=$?
if [ "$gate_rc" -ne 0 ] && [ ! -f "${CTX_DIR}/s-gate-stale.budget" ] &&
    grep -q "over the 1800s (30 min) limit" "$TMPROOT/err"; then
    ok "a handover older than 30 min refuses the landing and records nothing"
else
    bad "a handover older than 30 min refuses the landing and records nothing" \
        "rc=$gate_rc err='$(cat "$TMPROOT/err")'"
fi
write_handover "$CTX_DIR"

# --- 2a: uncommitted changes in the project tree ----------------------------
echo dirty >>"$GITROOT/seed.txt"
fixture s-gate-dirty 40
"$SCRIPT" landed --clear --summary "dirty tree" s-gate-dirty >"$TMPROOT/out" 2>"$TMPROOT/err"
gate_rc=$?
if [ "$gate_rc" -ne 0 ] && [ ! -f "${CTX_DIR}/s-gate-dirty.budget" ] &&
    grep -q "uncommitted changes" "$TMPROOT/err" && grep -q "$GITROOT" "$TMPROOT/err"; then
    ok "uncommitted changes in the project tree refuse the landing and record nothing"
else
    bad "uncommitted changes in the project tree refuse the landing and record nothing" \
        "rc=$gate_rc err='$(cat "$TMPROOT/err")'"
fi
(cd "$GITROOT" && git checkout -q -- seed.txt)

# --- 2b: a committed but unpushed change ------------------------------------
echo more >>"$GITROOT/seed.txt"
(cd "$GITROOT" && git commit -q -am "unpushed")
fixture s-gate-unpushed 40
"$SCRIPT" landed --clear --summary "unpushed" s-gate-unpushed >"$TMPROOT/out" 2>"$TMPROOT/err"
gate_rc=$?
if [ "$gate_rc" -ne 0 ] && [ ! -f "${CTX_DIR}/s-gate-unpushed.budget" ] &&
    grep -q "unpushed commits" "$TMPROOT/err"; then
    ok "an unpushed commit refuses the landing and records nothing"
else
    bad "an unpushed commit refuses the landing and records nothing" "rc=$gate_rc err='$(cat "$TMPROOT/err")'"
fi
(cd "$GITROOT" && git push -q origin HEAD:main)

# --- 2c: a worker worktree still registered ---------------------------------
WORKER_WT="$TMPROOT/worker-wt"
(cd "$GITROOT" && git worktree add -q -b worker-branch "$WORKER_WT" >/dev/null 2>&1)
fixture s-gate-wt 40
"$SCRIPT" landed --clear --summary "worktree left behind" s-gate-wt >"$TMPROOT/out" 2>"$TMPROOT/err"
gate_rc=$?
if [ "$gate_rc" -ne 0 ] && [ ! -f "${CTX_DIR}/s-gate-wt.budget" ] &&
    grep -q "worker worktree still present" "$TMPROOT/err" && grep -q "$WORKER_WT" "$TMPROOT/err"; then
    ok "a worker worktree still registered refuses the landing and names it"
else
    bad "a worker worktree still registered refuses the landing and names it" \
        "rc=$gate_rc err='$(cat "$TMPROOT/err")'"
fi
(cd "$GITROOT" && git worktree remove -f "$WORKER_WT" && git branch -D worker-branch) >/dev/null 2>&1

# --- 3a: a background agent transcript touched recently ---------------------
AGENT_SLUG=$(printf '%s' "$GITROOT" | tr '/' '-')
fixture s-gate-agent 40
AGENT_TASKS="${ALFRED_CLAUDE_TMP_DIR}/${AGENT_SLUG}/s-gate-agent/tasks"
mkdir -p "$AGENT_TASKS"
printf '{}\n' >"${AGENT_TASKS}/deadbeef123.output"
"$SCRIPT" landed --clear --summary "agent running" s-gate-agent >"$TMPROOT/out" 2>"$TMPROOT/err"
gate_rc=$?
if [ "$gate_rc" -ne 0 ] && [ ! -f "${CTX_DIR}/s-gate-agent.budget" ] &&
    grep -q "possibly still running" "$TMPROOT/err" && grep -q "deadbeef123" "$TMPROOT/err"; then
    ok "a recently-touched background-agent transcript refuses the landing and names it"
else
    bad "a recently-touched background-agent transcript refuses the landing and names it" \
        "rc=$gate_rc err='$(cat "$TMPROOT/err")'"
fi

# --- 3b: the same transcript, but stale (> 60s) — not flagged ---------------
touch -d "5 minutes ago" "${AGENT_TASKS}/deadbeef123.output"
fixture s-gate-agent-old 40
"$SCRIPT" landed --clear --summary "agent long done" s-gate-agent-old >"$TMPROOT/out" 2>"$TMPROOT/err"
gate_rc=$?
if [ "$gate_rc" -eq 0 ] && [ -f "${CTX_DIR}/s-gate-agent-old.budget" ] &&
    grep -q '^clear_mode=clear$' "${CTX_DIR}/s-gate-agent-old.budget"; then
    ok "a background-agent transcript stale beyond the window is not flagged"
else
    bad "a background-agent transcript stale beyond the window is not flagged" \
        "rc=$gate_rc err='$(cat "$TMPROOT/err")'"
fi
rm -rf "${ALFRED_CLAUDE_TMP_DIR:?}/${AGENT_SLUG:?}"

# --- --force skips git + running-agent checks, never the handover check ----
echo dirty >>"$GITROOT/seed.txt"
FORCE_TASKS="${ALFRED_CLAUDE_TMP_DIR}/${AGENT_SLUG}/s-gate-force/tasks"
mkdir -p "$FORCE_TASKS"
printf '{}\n' >"${FORCE_TASKS}/stillhot99.output"
fixture s-gate-force 40
"$SCRIPT" landed --clear --force --summary "forced past dirty tree + running agent" s-gate-force \
    >"$TMPROOT/out" 2>"$TMPROOT/err"
gate_rc=$?
FB="${CTX_DIR}/s-gate-force.budget"
if [ "$gate_rc" -eq 0 ] && grep -q '^clear_mode=clear$' "$FB" && grep -q '^forced=true$' "$FB"; then
    ok "--force skips the git and running-agent checks and records forced=true"
else
    bad "--force skips the git and running-agent checks and records forced=true" \
        "rc=$gate_rc budget='$(cat "$FB" 2>/dev/null)' err='$(cat "$TMPROOT/err")'"
fi
rm -rf "${ALFRED_CLAUDE_TMP_DIR:?}/${AGENT_SLUG:?}"
(cd "$GITROOT" && git checkout -q -- seed.txt)

# --force never skips the handover check
printf 'no capture id here\n' >"${CTX_DIR}/handover.md"
fixture s-gate-force-handover 40
"$SCRIPT" landed --clear --force --summary "forced but no handover" s-gate-force-handover \
    >"$TMPROOT/out" 2>"$TMPROOT/err"
gate_rc=$?
if [ "$gate_rc" -ne 0 ] && [ ! -f "${CTX_DIR}/s-gate-force-handover.budget" ] &&
    grep -q "no Metis capture id" "$TMPROOT/err" &&
    grep -q "force.*never skips the handover check" "$TMPROOT/err"; then
    ok "--force never skips the handover check"
else
    bad "--force never skips the handover check" "rc=$gate_rc err='$(cat "$TMPROOT/err")'"
fi
write_handover "$CTX_DIR"

# --- a genuinely clean pass records forced=false ----------------------------
fixture s-gate-clean 40
"$SCRIPT" landed --clear --summary "clean pass" s-gate-clean >"$TMPROOT/out" 2>"$TMPROOT/err"
gate_rc=$?
CLB="${CTX_DIR}/s-gate-clean.budget"
if [ "$gate_rc" -eq 0 ] && grep -q '^clear_mode=clear$' "$CLB" && grep -q '^forced=false$' "$CLB"; then
    ok "a clean pass (no --force needed) records forced=false"
else
    bad "a clean pass (no --force needed) records forced=false" \
        "rc=$gate_rc budget='$(cat "$CLB" 2>/dev/null)' err='$(cat "$TMPROOT/err")'"
fi

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

# ===========================================================================
# baseline delta + interactive deferral (Screenfields/alfred-platform#874)
# ===========================================================================
# Own state dir: these cases arm baselines and consume the handover file, and
# the shared CTX_DIR is by now full of sessions from every case above.
BASE_DIR="$TMPROOT/baseline"
mkdir -p "$BASE_DIR/context"
SAVED_STATE_DIR="$ALFRED_STATE_DIR"
SAVED_CTX_DIR="$CTX_DIR"
export ALFRED_STATE_DIR="$BASE_DIR"
CTX_DIR="$BASE_DIR/context"

# arm_baseline <session_id> — one SessionStart, the way the hook fires it.
arm_baseline() {
    printf '{"session_id":"%s","source":"startup","cwd":"/tmp"}' "$1" |
        "$SCRIPT" session-start >/dev/null 2>&1
}

# --- baseline delta ---------------------------------------------------------
# The real numbers: a hub session reports ~86000 used on a 1M window the moment
# it starts (system prompt, CLAUDE.md, memory index, tool and MCP schemas,
# SessionStart injections). Measured from zero that is already over the soft
# threshold; measured above the baseline it is zero.
arm_baseline s-base
if grep -q '^baseline_pending=1$' "${CTX_DIR}/s-base.budget"; then
    ok "session-start arms the baseline"
else
    bad "session-start arms the baseline" "budget='$(cat "${CTX_DIR}/s-base.budget" 2>/dev/null)'"
fi

fixture_tokens s-base 86000 1000000 9
assert_silent "a fresh session at its start reading (86000) does not nag" s-base UserPromptSubmit
if grep -q '^baseline=86000$' "${CTX_DIR}/s-base.budget"; then
    ok "the first reading becomes the session baseline"
else
    bad "the first reading becomes the session baseline" "budget='$(cat "${CTX_DIR}/s-base.budget")'"
fi

fixture_tokens s-base 120000 1000000 12
assert_silent "34000 tokens above the baseline is still below the soft tier" s-base UserPromptSubmit

fixture_tokens s-base 130000 1000000 13
assert_context "the soft tier is reached at baseline + soft threshold" s-base UserPromptSubmit \
    "CONTEXT BUDGET: 44000 tokens this session (130000 total, 13%) used — soft threshold 40000 tokens."

fixture_tokens s-base 160000 1000000 16
assert_context "the hard tier is reached at baseline + hard threshold" s-base UserPromptSubmit \
    "CONTEXT BUDGET: 74000 tokens this session (160000 total, 16%) used — hard threshold 70000 tokens."
run_check s-base Stop
if [ "$RC" -eq 2 ] && printf '%s' "$ERR_TXT" | grep -q "74000 tokens this session (160000 total"; then
    ok "the Stop block reports the delta it compared"
else
    bad "the Stop block reports the delta it compared" "rc=$RC stderr='$ERR_TXT'"
fi

# No armed baseline (a session that started before this build, or whose
# SessionStart hook never ran): thresholds apply to `used`, exactly as before.
fixture_tokens s-nobase 86000 1000000 9
assert_context "without an armed baseline the thresholds apply to used as before" s-nobase UserPromptSubmit \
    "CONTEXT BUDGET: 86000 tokens (9%) used — hard threshold 70000 tokens."

# A reading below the baseline means the window shrank — a compaction. The
# post-compaction reading is the new floor.
arm_baseline s-recomp
fixture_tokens s-recomp 86000 1000000 9
run_check s-recomp UserPromptSubmit
fixture_tokens s-recomp 60000 1000000 6
assert_silent "a reading below the baseline re-baselines instead of going negative" s-recomp UserPromptSubmit
if grep -q '^baseline=60000$' "${CTX_DIR}/s-recomp.budget"; then
    ok "a compacted window lowers the baseline to the new floor"
else
    bad "a compacted window lowers the baseline to the new floor" "budget='$(cat "${CTX_DIR}/s-recomp.budget")'"
fi

# --- interactive deferral ---------------------------------------------------
export ALFRED_CONTEXT_INTERACTIVE_SECONDS=600

fixture_tokens s-defer 80000 1000000 8
run_check s-defer UserPromptSubmit # stamps last_prompt_ts, nags at the hard tier
run_check s-defer Stop
defer_budget="${CTX_DIR}/s-defer.budget"
if [ "$RC" -eq 0 ] &&
    case "$(printf '%s' "$OUT_TXT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)" in
    *"Not blocking this turn: the owner prompted less than 10 min ago"*) true ;;
    *) false ;;
    esac; then
    ok "hard tier with a prompt in the window nags on Stop and does not block"
else
    bad "hard tier with a prompt in the window nags on Stop and does not block" \
        "rc=$RC stdout='$OUT_TXT'"
fi
if ! grep -q '^stop_blocked=1$' "$defer_budget" && ! grep -q '^sender_ts=' "$defer_budget"; then
    ok "the deferral spawns no sender and leaves the block armed"
else
    bad "the deferral spawns no sender and leaves the block armed" "budget='$(cat "$defer_budget")'"
fi

assert_silent "the deferred nag is rate-limited like every other injection" s-defer Stop

# ... and once the conversation goes quiet, the block fires exactly as before.
printf 'last_prompt_ts=%s\n' "$(($(date +%s) - 601))" >>"$defer_budget"
run_check s-defer Stop
if [ "$RC" -eq 2 ] && [ -z "$OUT_TXT" ] && printf '%s' "$ERR_TXT" | grep -q "land --mode=light"; then
    ok "a prompt older than the interactive window blocks the turn as today"
else
    bad "a prompt older than the interactive window blocks the turn as today" \
        "rc=$RC stdout='$OUT_TXT' stderr='$ERR_TXT'"
fi

# --- ceiling ----------------------------------------------------------------
# A conversation this long lands however live it is.
export ALFRED_CONTEXT_CEILING_TOKENS=200000
fixture_tokens s-ceil 250000 1000000 25
run_check s-ceil UserPromptSubmit
run_check s-ceil Stop
if [ "$RC" -eq 2 ]; then
    ok "above the ceiling a recent prompt no longer defers the block"
else
    bad "above the ceiling a recent prompt no longer defers the block" "rc=$RC stdout='$OUT_TXT'"
fi

# The ceiling is measured above the baseline, like every other token threshold:
# 250000 used with an 86000 baseline is 164000 this session — still deferred.
arm_baseline s-ceil-base
fixture_tokens s-ceil-base 86000 1000000 9
run_check s-ceil-base UserPromptSubmit
fixture_tokens s-ceil-base 250000 1000000 25
run_check s-ceil-base UserPromptSubmit
run_check s-ceil-base Stop
if [ "$RC" -eq 0 ]; then
    ok "the ceiling is measured above the baseline, not on the raw total"
else
    bad "the ceiling is measured above the baseline, not on the raw total" "rc=$RC"
fi
fixture_tokens s-ceil-base 300000 1000000 30
run_check s-ceil-base UserPromptSubmit
run_check s-ceil-base Stop
if [ "$RC" -eq 2 ]; then
    ok "214000 tokens above the baseline crosses the ceiling and blocks"
else
    bad "214000 tokens above the baseline crosses the ceiling and blocks" "rc=$RC"
fi

export ALFRED_CONTEXT_INTERACTIVE_SECONDS=0
unset ALFRED_CONTEXT_CEILING_TOKENS
export ALFRED_STATE_DIR="$SAVED_STATE_DIR"
CTX_DIR="$SAVED_CTX_DIR"

echo
echo "----"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
