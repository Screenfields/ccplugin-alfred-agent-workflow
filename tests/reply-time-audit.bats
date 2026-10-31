#!/usr/bin/env bats
# hooks/reply-audit.sh and the audit part of lib/reply-time.sh (CCW-184): the Stop part
# that checks the time stamp at the head of the final reply. The clock is pinned with
# ALFRED_REPLY_TS_NOW and the real `date` does the arithmetic (Europe/Amsterdam tzdata
# needed for the cases that quote a time); a fake `date` on PATH covers the missing-date,
# the +%s and the tzdata cases. A private CLAUDE_CONFIG_DIR per test. No network, no model call.
# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  AUDIT="$ROOT/hooks/reply-audit.sh"
  STOP="$ROOT/hooks/stop.sh"
  HOOK="$ROOT/hooks/reply-timestamp.sh"
  [ -e /usr/share/zoneinfo/Europe/Amsterdam ] || skip "no Europe/Amsterdam tzdata"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset ALFRED_ROLE ALFRED_REPLY_TS_LOG ALFRED_REPLY_TS_NOW ALFRED_THRESHOLDS ALFRED_REPLY_TS_AUDIT CLAUDE_CODE_ENTRYPOINT
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  STATE="$CLAUDE_CONFIG_DIR/alfred-reply-ts"
  SF="$STATE/s1.json"
  Q="$BATS_TEST_TMPDIR/quiet.sh"
  printf '#!/bin/sh\nexit 0\n' > "$Q"; chmod +x "$Q"
  export ALFRED_STOP_BRIDGE_BIN="$Q" ALFRED_STOP_LOOP_BIN="$Q"
}

# ep "<Europe/Amsterdam wall time>" — epoch.
ep() { TZ=Europe/Amsterdam /usr/bin/date -d "$1" +%s; }
# state <json> [sid] — the state file of a session.
state() { mkdir -p "$STATE"; printf '%s\n' "$1" > "$STATE/${2:-s1}.json"; }
# st_inj <epoch>... — a state with an injected list and no flag.
st_inj() { state "{\"injected\":[$(IFS=,; echo "$*")],\"flagged\":false}"; }
# sj <message> [active] [sid] — Stop hook input.
sj() { jq -cn --arg m "$1" --argjson a "${2:-false}" --arg s "${3:-s1}" '{session_id: $s, stop_hook_active: $a, last_assistant_message: $m}'; }
# audit <now epoch> <message> [active] — the script alone, with --now.
audit() { run --separate-stderr "$AUDIT" --now "$1" <<< "$(sj "$2" "${3:-false}")"; }
# stopsh <start epoch> <message> [active] — the whole stop.sh, quiet parts.
stopsh() { ALFRED_REPLY_TS_NOW="$1" run --separate-stderr "$STOP" <<< "$(sj "$2" "${3:-false}")"; }
# prompt <now epoch> [source] — the real prompt hook.
prompt() { ALFRED_REPLY_TS_NOW="$1" run --separate-stderr "$HOOK" <<< "$(jq -cn '{session_id: "s1", prompt: "hello", source: "user"}')"; }
silent() { [ "$status" -eq 0 ]; [ -z "$output" ]; }
flagged() { [ "$status" -eq 0 ]; [ "$(jq -r .decision <<< "$output")" = block ]; [[ "$(jq -r .reason <<< "$output")" == *"Time check:"* ]]; }
sget() { if [ "$1" = -c ]; then jq -c "$2" "$SF"; else jq -rc "$1" "$SF"; fi; }
# audit_fields — the audit's own fields, byte for byte.
audit_fields() { jq -c '{injected, flagged}' "$SF"; }

# --- AC 1: verdicts ----------------------------------------------------------------------------------------

@test "verdict: 3 minutes ahead (07:24 at 07:21) is flagged, quoting the stamp and the correct time" {
  st_inj "$(ep '2026-10-30 07:21:05')"
  audit "$(ep '2026-10-30 07:21:20')" '_[2026-10-30 07:24 CET]_ hello'
  flagged
  r=$(jq -r .reason <<< "$output")
  [[ "$r" == *"_[2026-10-30 07:24 CET]_"* && "$r" == *"3 minute(s) ahead"* && "$r" == *"_[2026-10-30 07:21 CET]_"* ]]
  [ "$(wc -l <<< "$output")" -eq 1 ]
}

@test "verdict: a stamp equal to the injected time passes, even 10 minutes later" {
  st_inj "$(ep '2026-10-30 07:00:10')"
  audit "$(ep '2026-10-30 07:10:30')" '_[2026-10-30 07:00 CET]_ hello'
  silent
}

@test "verdict: a stamp within the tolerance of the clock passes" {
  st_inj "$(ep '2026-10-30 07:00:10')"
  audit "$(ep '2026-10-30 07:20:30')" '_[2026-10-30 07:19 CET]_ hello'
  silent
}

@test "verdict: a reading 5 minutes old, not the injected time, is flagged" {
  st_inj "$(ep '2026-10-30 07:00:10')"
  audit "$(ep '2026-10-30 07:20:30')" '_[2026-10-30 07:15 CET]_ hello'
  flagged
  [[ "$(jq -r .reason <<< "$output")" == *"5 minute(s) behind"* ]]
}

@test "verdict: more than 2 minutes behind both is flagged, exactly 2 passes" {
  st_inj "$(ep '2026-10-30 07:00:10')"
  audit "$(ep '2026-10-30 07:20:30')" '_[2026-10-30 07:17 CET]_ x'
  flagged
  st_inj "$(ep '2026-10-30 07:00:10')"
  audit "$(ep '2026-10-30 07:20:30')" '_[2026-10-30 07:18 CET]_ x'
  silent
}

@test "verdict: a stamp ahead of the clock is flagged at any distance, no tolerance" {
  st_inj "$(ep '2026-10-30 07:00:10')"
  audit "$(ep '2026-10-30 07:20:30')" '_[2026-10-30 07:21 CET]_ x'
  flagged
  [[ "$(jq -r .reason <<< "$output")" == *"1 minute(s) ahead"* ]]
}

@test "verdict: truncation, the stamp and the references are floored to the minute" {
  st_inj
  audit "$(ep '2026-10-30 07:20:59')" '_[2026-10-30 07:20 CET]_ x'
  silent
  audit "$(ep '2026-10-30 07:20:59')" '_[2026-10-30 07:21 CET]_ x'
  flagged
}

@test "verdict: both stamp forms, leading whitespace or blank lines, a blank line after the stamp" {
  for m in '_[2026-10-30 07:24 CET]_ x' 'Time now _[2026-10-30 07:24 CET]_ x' $'  \n\n_[2026-10-30 07:24 CET]_\n\nbody' $'\nTime now _[2026-10-30 07:24 CET]_\n\nbody'; do
    st_inj
    audit "$(ep '2026-10-30 07:21:20')" "$m"
    flagged
  done
}

@test "verdict: a stamp that is not at the start, or in another shape, is silent" {
  st_inj
  for m in 'Time is _[2026-10-30 07:24 CET]_' 'ok _[2026-10-30 07:24 CET]_' '[2026-10-30 07:24 CET]' '_[2026-10-30 07:24 UTC]_' '_[2026-10-30 7:24 CET]_' 'hello'; do
    audit "$(ep '2026-10-30 07:21:20')" "$m"
    silent
  done
}

# --- AC 2: reference times ---------------------------------------------------------------------------------

@test "references: any epoch injected this turn counts (07:00 and 07:08, clock 07:10)" {
  st_inj "$(ep '2026-10-30 07:00:10')" "$(ep '2026-10-30 07:08:10')"
  audit "$(ep '2026-10-30 07:10:30')" '_[2026-10-30 07:00 CET]_ x'; silent
  audit "$(ep '2026-10-30 07:10:30')" '_[2026-10-30 07:08 CET]_ x'; silent
  audit "$(ep '2026-10-30 07:10:30')" '_[2026-10-30 07:05 CET]_ x'; flagged
}

@test "references: an empty list, a stamp passes only within the tolerance of the clock" {
  st_inj
  audit "$(ep '2026-10-30 07:20:30')" '_[2026-10-30 07:00 CET]_ x'; flagged
  state '{"last_activity":1792800000}'
  audit "$(ep '2026-10-30 07:20:30')" '_[2026-10-30 07:19 CET]_ x'; silent
}

@test "references: the prompt hook records the injected epoch, the stored epoch is the one behind the stamp" {
  n=$(ep '2026-10-30 07:00:10')
  prompt "$n"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" == *"_[2026-10-30 07:00 CET]_"* ]]
  [ "$(sget '.injected | length')" -eq 1 ]
  [ "$(sget '.injected[0]')" -eq "$n" ]
  [ "$(sget .flagged)" = false ]
  [ "$(sget .line_at)" -eq "$n" ]
}

@test "references: the list keeps the newest 8" {
  state "{\"injected\":[1792800001,1792800002,1792800003,1792800004,1792800005,1792800006,1792800007,1792800008],\"open\":true,\"line_at\":1792800008,\"last_activity\":1700000000}"
  prompt 1792809000
  [ "$(sget '.injected | length')" -eq 8 ]
  [ "$(sget '.injected[0]')" -eq 1792800002 ]
  [ "$(sget '.injected[7]')" -eq 1792809000 ]
}

@test "restart: a prompt after a recorded Stop restarts the list, injecting or not" {
  t=$(ep '2026-10-30 07:00:10')
  prompt "$t"                                          # idle, injects
  stopsh "$((t + 300))" "reply"                        # a Stop is recorded (open false)
  [ "$(sget .open)" = false ]
  prompt "$((t + 600))"                                # 10 min later: not idle, no line
  [ -z "$output" ]
  [ "$(sget '.injected | length')" -eq 0 ]
  # and an injecting prompt after a Stop restarts to just its own epoch
  state "{\"injected\":[$t],\"open\":false,\"last_activity\":$((t - 7200)),\"line_at\":$t}"
  prompt "$((t + 3600))"
  [ "$(sget '.injected')" = "[$((t + 3600))]" ]
}

@test "restart: a mid-turn prompt (open true) keeps the list; an injecting one appends (D2)" {
  t=$(ep '2026-10-30 07:00:10')
  prompt "$t"
  prompt "$((t + 300))"                                # mid-turn, suppressed
  [ "$(sget '.injected')" = "[$t]" ]
  prompt "$((t + 900))"                                # threshold reached: injects again
  [ "$(sget '.injected')" = "[$t,$((t + 900))]" ]
}

@test "restart: a non-injecting prompt never adds an epoch" {
  t=$(ep '2026-10-30 07:00:10')
  state "{\"last_activity\":$((t - 60)),\"open\":false,\"injected\":[]}"
  prompt "$t"
  [ -z "$output" ]
  [ "$(sget '.injected')" = "[]" ]
}

@test "restart: a Stop (record and audit) never changes the list, a blocking part in parallel cannot clear it" {
  t=$(ep '2026-10-30 07:00:10')
  prompt "$t"
  before=$(sget -c .injected)
  stopsh "$((t + 60))" "reply"
  [ "$(sget -c .injected)" = "$before" ]
  # a Stop that another part blocks: still the same list
  printf '#!/bin/sh\necho {\\"decision\\":\\"block\\",\\"reason\\":\\"open work\\"}\n' > "$BATS_TEST_TMPDIR/b.sh"; chmod +x "$BATS_TEST_TMPDIR/b.sh"
  ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/b.sh" stopsh "$((t + 120))" "reply"
  [ "$(sget -c .injected)" = "$before" ]
}

@test "pinned: injected at 07:00, a Stop, a non-injecting prompt at 07:10 with the stamp 07:00 carried over: flagged" {
  t=$(ep '2026-10-30 07:00:10')
  prompt "$t"
  stopsh "$((t + 300))" "_[2026-10-30 07:00 CET]_ first reply"
  silent
  prompt "$((t + 600))"
  [ -z "$output" ]
  stopsh "$((t + 660))" "_[2026-10-30 07:00 CET]_ carried over"
  flagged
}

@test "pinned false negative: injected at 07:00 and interrupted (no Stop), a prompt at 07:10, the stamp 07:00 passes" {
  t=$(ep '2026-10-30 07:00:10')
  prompt "$t"
  prompt "$((t + 600))"
  [ -z "$output" ]
  [ "$(sget '.injected')" = "[$t]" ]
  stopsh "$((t + 660))" "_[2026-10-30 07:00 CET]_ carried over"
  silent
}

@test "same second: a Stop and an injection in one second, both orders, follow the order of the writes, not a comparison of epochs" {
  t=$(ep '2026-10-30 07:00:10')
  # prompt (injects), then Stop, same second: the turn is closed, the next prompt restarts the list
  prompt "$t"; stopsh "$t" "reply"
  [ "$(sget .open)" = false ]
  prompt "$((t + 5))"
  [ "$(sget -c .injected)" = "[]" ]
  # Stop (empty final, so the session stays idle), then prompt (injects), same second: the turn is open, a later prompt keeps the list
  rm -rf "$STATE"
  stopsh "$t" ""; prompt "$t"
  [ "$(sget .open)" = true ]
  [ "$(sget -c .injected)" = "[$t]" ]
  prompt "$((t + 5))"
  [ "$(sget -c .injected)" = "[$t]" ]
}

@test "fall-back hour: 02:30 CEST and 02:30 CET are two instants, resolved by the zone token" {
  st_inj
  audit 1792888260 '_[2026-10-25 02:30 CEST]_ x'; silent       # 00:31 UTC
  audit 1792888260 '_[2026-10-25 02:30 CET]_ x'; flagged       # 59 minutes ahead
  st_inj
  audit 1792891860 '_[2026-10-25 02:30 CET]_ x'; silent        # 01:31 UTC
  audit 1792891860 '_[2026-10-25 02:30 CEST]_ x'; flagged      # 61 minutes behind
}

# --- AC 3: once per turn -----------------------------------------------------------------------------------

@test "once: a flag is one paragraph in stop.sh's one block, first in the reason, with flagged recorded" {
  t=$(ep '2026-10-30 07:00:10')
  prompt "$t"
  printf '#!/bin/sh\necho {\\"decision\\":\\"block\\",\\"reason\\":\\"open work\\"}\n' > "$BATS_TEST_TMPDIR/b.sh"; chmod +x "$BATS_TEST_TMPDIR/b.sh"
  ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/b.sh" stopsh "$((t + 60))" '_[2026-10-30 07:24 CET]_ x'
  [ "$(wc -l <<< "$output")" -eq 1 ]
  r=$(jq -r .reason <<< "$output")
  [[ "$r" == "Time check:"* ]]
  [[ "$r" == *$'\n\n'"open work" ]]
  [ "$(grep -c 'Time check:' <<< "$r")" -eq 1 ]
  [ "$(sget .flagged)" = true ]
}

@test "once: a second Stop in the same turn is silent even if still wrong, with stop_hook_active either way" {
  t=$(ep '2026-10-30 07:00:10')
  prompt "$t"
  stopsh "$((t + 60))" '_[2026-10-30 07:24 CET]_ x'; flagged
  stopsh "$((t + 70))" '_[2026-10-30 07:24 CET]_ x' true; silent
  stopsh "$((t + 80))" '_[2026-10-30 07:24 CET]_ x' false; silent
}

@test "once: a new prompt clears the flag and restarts the list, the next Stop is audited again" {
  t=$(ep '2026-10-30 07:00:10')
  prompt "$t"
  stopsh "$((t + 60))" '_[2026-10-30 07:24 CET]_ x'; flagged
  prompt "$((t + 120))"
  [ "$(sget .flagged)" = false ]
  stopsh "$((t + 180))" '_[2026-10-30 07:24 CET]_ x'; flagged
}

@test "once: a reply written after another part's block, with no flag before it, is audited" {
  t=$(ep '2026-10-30 07:00:10')
  prompt "$t"
  printf '#!/bin/sh\necho {\\"decision\\":\\"block\\",\\"reason\\":\\"open work\\"}\n' > "$BATS_TEST_TMPDIR/b.sh"; chmod +x "$BATS_TEST_TMPDIR/b.sh"
  ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/b.sh" stopsh "$((t + 60))" "no stamp here"   # first Stop: blocked by the loop part
  [ "$(jq -r .reason <<< "$output")" = "open work" ]
  stopsh "$((t + 120))" '_[2026-10-30 07:24 CET]_ final' true                          # the continuation's reply
  flagged
}

@test "once: a passing and a silent Stop leave the audit's fields byte for byte; a second, wrong stamp is then flagged once" {
  t=$(ep '2026-10-30 07:00:10')
  prompt "$t"
  b=$(audit_fields)
  stopsh "$((t + 60))" "_[2026-10-30 07:01 CET]_ ok"; silent; [ "$(audit_fields)" = "$b" ]
  stopsh "$((t + 70))" "no stamp"; silent; [ "$(audit_fields)" = "$b" ]
  stopsh "$((t + 75))" "   "; silent; [ "$(audit_fields)" = "$b" ]
  stopsh "$((t + 80))" '_[2026-10-30 07:24 CET]_ x'; flagged
  stopsh "$((t + 90))" '_[2026-10-30 07:24 CET]_ x'; silent
}

@test "clock: stop.sh reads its clock once before any part; a lagging part does not age a stamp (07:22:59 passes 07:20, 07:23:00 flags it)" {
  cat > "$BATS_TEST_TMPDIR/bin/date" <<FAKE
#!/usr/bin/env bash
if [ "\$1" = "+%s" ]; then
  n=\$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0); echo \$((n+1)) > "$BATS_TEST_TMPDIR/n"
  echo \$(( \$(cat "$BATS_TEST_TMPDIR/start") + n * 130 ))
else exec /usr/bin/date "\$@"; fi
FAKE
  chmod +x "$BATS_TEST_TMPDIR/bin/date"
  printf '#!/bin/sh\ndate +%%s >/dev/null\ndate +%%s >/dev/null\nexit 0\n' > "$BATS_TEST_TMPDIR/lag.sh"; chmod +x "$BATS_TEST_TMPDIR/lag.sh"
  export ALFRED_STOP_BRIDGE_BIN="$BATS_TEST_TMPDIR/lag.sh" ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/lag.sh"
  st_inj
  ep '2026-10-30 07:22:59' > "$BATS_TEST_TMPDIR/start"; rm -f "$BATS_TEST_TMPDIR/n"
  run --separate-stderr "$STOP" <<< "$(sj '_[2026-10-30 07:20 CET]_ x')"
  silent
  [ "$(cat "$BATS_TEST_TMPDIR/n")" -ge 5 ]            # the parts did read the clock, the audit used the first reading
  st_inj
  ep '2026-10-30 07:23:00' > "$BATS_TEST_TMPDIR/start"; rm -f "$BATS_TEST_TMPDIR/n"
  run --separate-stderr "$STOP" <<< "$(sj '_[2026-10-30 07:20 CET]_ x')"
  flagged
  [[ "$(jq -r .reason <<< "$output")" == *"The time now is _[2026-10-30 07:23 CET]_"* ]]
}

@test "clock: stop.sh passes --now to the audit; without a start clock the part is not started" {
  printf '#!/bin/sh\necho "$@" >> "%s/args"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/stub.sh"; chmod +x "$BATS_TEST_TMPDIR/stub.sh"
  export ALFRED_STOP_AUDIT_BIN="$BATS_TEST_TMPDIR/stub.sh"
  stopsh 1792800000 "x"
  [ "$(cat "$BATS_TEST_TMPDIR/args")" = "--now 1792800000" ]
  rm -f "$BATS_TEST_TMPDIR/args"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/date"; chmod +x "$BATS_TEST_TMPDIR/bin/date"
  run --separate-stderr "$STOP" <<< "$(sj x)"
  [ ! -e "$BATS_TEST_TMPDIR/args" ]
}

@test "clock: the script alone, with no --now, reads the clock itself" {
  st_inj
  ALFRED_REPLY_TS_NOW="$(ep '2026-10-30 07:21:20')" run --separate-stderr "$AUDIT" <<< "$(sj '_[2026-10-30 07:24 CET]_ x')"
  flagged
}

@test "once: a flag that cannot be recorded flags nothing (read-only state directory)" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  st_inj
  chmod 555 "$STATE"
  audit "$(ep '2026-10-30 07:21:20')" '_[2026-10-30 07:24 CET]_ x'
  chmod 755 "$STATE"
  silent
  [ "$(sget .flagged)" = false ]
}

@test "wiring: the audit is the last part, with its own 1 s limit; garbage and a hang are warnings, never a block, and the process is gone" {
  printf '#!/bin/sh\necho "this is not json"\n' > "$BATS_TEST_TMPDIR/g.sh"; chmod +x "$BATS_TEST_TMPDIR/g.sh"
  ALFRED_STOP_AUDIT_BIN="$BATS_TEST_TMPDIR/g.sh" stopsh 1792800000 x
  [ "$(jq -r '.decision // "none"' <<< "$output")" = none ]
  [[ "$(jq -r .systemMessage <<< "$output")" == *"audit part gave unusable output"* ]]
  printf '#!/bin/sh\nexec sleep 31.84\n' > "$BATS_TEST_TMPDIR/h.sh"; chmod +x "$BATS_TEST_TMPDIR/h.sh"
  start=$SECONDS
  ALFRED_STOP_AUDIT_BIN="$BATS_TEST_TMPDIR/h.sh" stopsh 1792800000 x
  [ $((SECONDS - start)) -lt 6 ]
  [ "$(jq -r '.decision // "none"' <<< "$output")" = none ]
  [[ "$(jq -r .systemMessage <<< "$output")" == *"audit part timed out"* ]]
  ! pgrep -f "sleep 31.84" > /dev/null
}

@test "wiring: hooks.json has one Stop entry naming stop.sh and none naming reply-audit; stop.sh names it; the header carries the 19 s arithmetic" {
  h="$ROOT/hooks/hooks.json"
  [ "$(jq -r '[.hooks.Stop[].hooks[].command | select(test("stop.sh"))] | length' "$h")" = 1 ]
  [ "$(jq -r '[.hooks.Stop[].hooks[].command | select(test("reply-audit"))] | length' "$h")" = 0 ]
  grep -q 'reply-audit.sh' "$ROOT/hooks/stop.sh"
  grep -q 'ALFRED_STOP_AUDIT_BIN' "$ROOT/hooks/stop.sh"
  grep -q '6 + 11 + 2 = 19 s' "$ROOT/hooks/stop.sh"
}

# --- AC 4: silent cases ------------------------------------------------------------------------------------

@test "silent: a worker" {
  st_inj
  ALFRED_ROLE=worker audit "$(ep '2026-10-30 07:21:20')" '_[2026-10-30 07:24 CET]_ x'
  silent
}

@test "silent: an empty, whitespace, missing or non-string message, a no-news wake" {
  st_inj
  audit "$(ep '2026-10-30 07:21:20')" ''; silent
  audit "$(ep '2026-10-30 07:21:20')" '   '; silent
  run --separate-stderr "$AUDIT" --now "$(ep '2026-10-30 07:21:20')" <<< '{"session_id":"s1"}'; silent
  run --separate-stderr "$AUDIT" --now "$(ep '2026-10-30 07:21:20')" <<< '{"session_id":"s1","last_assistant_message":42}'; silent
}

@test "silent: state absent, garbage, empty, an array, a directory, wrong-typed audit keys, an out of range epoch" {
  n="$(ep '2026-10-30 07:21:20')"
  m='_[2026-10-30 07:24 CET]_ x'
  audit "$n" "$m"; silent                                       # absent
  state 'not json'; audit "$n" "$m"; silent
  state ''; audit "$n" "$m"; silent
  state '[1,2]'; audit "$n" "$m"; silent
  state '{"injected":"x"}'; audit "$n" "$m"; silent
  state '{"injected":[1e30]}'; audit "$n" "$m"; silent
  state '{"injected":[99999999999999999999]}'; audit "$n" "$m"; silent
  state '{"flagged":"yes"}'; audit "$n" "$m"; silent
  rm -f "$SF"; mkdir -p "$SF"; audit "$n" "$m"; silent; [ -d "$SF" ] && [ -z "$(ls -A "$SF")" ]
}

@test "silent: an unreadable state file (permissions)" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file permissions"
  st_inj; chmod 000 "$SF"
  audit "$(ep '2026-10-30 07:21:20')" '_[2026-10-30 07:24 CET]_ x'
  chmod 644 "$SF"
  silent
}

@test "silent: no session_id" {
  st_inj
  run --separate-stderr "$AUDIT" --now "$(ep '2026-10-30 07:21:20')" <<< '{"last_assistant_message":"_[2026-10-30 07:24 CET]_ x"}'
  silent
}

@test "silent: missing jq, missing date, a missing or a broken lib" {
  st_inj
  in="$(sj '_[2026-10-30 07:24 CET]_ x')"
  nojq="$BATS_TEST_TMPDIR/nojq"; mkdir -p "$nojq"
  for t in cat dirname date; do ln -s "$(command -v "$t")" "$nojq/$t"; done
  run --separate-stderr env PATH="$nojq" "$BASH" "$AUDIT" --now "$(ep '2026-10-30 07:21:20')" <<< "$in"; silent
  nodate="$BATS_TEST_TMPDIR/nodate"; mkdir -p "$nodate"
  for t in cat dirname jq; do ln -s "$(command -v "$t")" "$nodate/$t"; done
  run --separate-stderr env PATH="$nodate" "$BASH" "$AUDIT" --now "$(ep '2026-10-30 07:21:20')" <<< "$in"; silent
  P="$BATS_TEST_TMPDIR/plug"; mkdir -p "$P"; cp -r "$ROOT/hooks" "$ROOT/bin" "$ROOT/config" "$P/"
  run --separate-stderr "$P/hooks/reply-audit.sh" --now "$(ep '2026-10-30 07:21:20')" <<< "$in"; silent   # lib absent
  mkdir -p "$P/lib"; echo 'if (' > "$P/lib/reply-time.sh"
  run --separate-stderr "$P/hooks/reply-audit.sh" --now "$(ep '2026-10-30 07:21:20')" <<< "$in"; silent   # lib broken
}

@test "silent: empty, garbage, two objects and an array on stdin" {
  st_inj
  for in in '' 'garbage' '{"session_id":"s1"}{"session_id":"s1"}' '[{"session_id":"s1","last_assistant_message":"_[2026-10-30 07:24 CET]_ x"}]'; do
    run --separate-stderr "$AUDIT" --now "$(ep '2026-10-30 07:21:20')" <<< "$in"; silent
  done
}

@test "silent: an invalid date in the stamp (month 13, day 31 of a 30-day month, hour 25)" {
  st_inj
  for m in '_[2026-13-30 07:24 CET]_ x' '_[2026-11-31 07:24 CET]_ x' '_[2026-10-30 25:24 CET]_ x' '_[0001-01-01 00:00 CET]_ x'; do
    audit "$(ep '2026-10-30 07:21:20')" "$m"; silent
  done
}

@test "silent: no Europe/Amsterdam time to quote (tzdata missing), the verdict is flag but nothing is printed" {
  st_inj
  printf '#!/usr/bin/env bash\ncase "$*" in\n  *"%%F %%H:%%M %%Z"*) echo "2026-10-30 06:21 UTC" ;;\n  *) exec /usr/bin/date "$@" ;;\nesac\n' > "$BATS_TEST_TMPDIR/bin/date"; chmod +x "$BATS_TEST_TMPDIR/bin/date"
  audit 1793341280 '_[2026-10-30 07:24 CET]_ x'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(sget .flagged)" = false ]
}

@test "silent: an unreadable tolerance, with a wrong stamp that reaches the read: one stderr line, no flag" {
  n="$(ep '2026-10-30 07:21:20')"
  m='_[2026-10-30 07:00 CET]_ x'
  expect='reply-audit: reply-time-tolerance-minutes unreadable, no audit'
  for t in '{"other":1}' 'not json' '{"reply-time-tolerance-minutes":"x"}' '{"reply-time-tolerance-minutes":-1}' '{"reply-time-tolerance-minutes":2.5}'; do
    st_inj
    printf '%s\n' "$t" > "$BATS_TEST_TMPDIR/th.json"
    ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/th.json" audit "$n" "$m"
    silent
    [ "$stderr" = "$expect" ]
  done
  # alfred-config absent
  P="$BATS_TEST_TMPDIR/plug"; mkdir -p "$P"; cp -r "$ROOT/hooks" "$ROOT/lib" "$ROOT/config" "$P/"
  st_inj
  run --separate-stderr "$P/hooks/reply-audit.sh" --now "$n" <<< "$(sj "$m")"
  silent; [ "$stderr" = "$expect" ]
}

@test "silent through stop.sh: no block and no warning in the systemMessage for the silent cases" {
  st_inj
  for m in '' 'no stamp' '_[2026-13-30 07:24 CET]_ x'; do
    stopsh "$(ep '2026-10-30 07:21:20')" "$m"
    silent
  done
  ALFRED_ROLE=worker stopsh "$(ep '2026-10-30 07:21:20')" '_[2026-10-30 07:24 CET]_ x'; silent
}

@test "silent through stop.sh: an unreadable tolerance leaves only the stderr line" {
  st_inj
  echo '{"x":1}' > "$BATS_TEST_TMPDIR/th.json"
  ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/th.json" stopsh "$(ep '2026-10-30 07:21:20')" '_[2026-10-30 07:00 CET]_ x'
  silent
  [[ "$stderr" == *"reply-audit: reply-time-tolerance-minutes unreadable, no audit"* ]]
}

@test "a stamp in a reply to a turn with no injected line is checked for accuracy only, never for being there" {
  state '{"last_activity":1792800000,"open":false,"injected":[]}'
  audit "$(ep '2026-10-30 07:20:30')" '_[2026-10-30 07:20 CET]_ x'; silent
  audit "$(ep '2026-10-30 07:20:30')" 'no stamp at all'; silent
}

# --- AC 5: tolerance ---------------------------------------------------------------------------------------

@test "tolerance: another value of the name changes the verdict" {
  n="$(ep '2026-10-30 07:20:30')"
  m='_[2026-10-30 07:15 CET]_ x'
  st_inj; audit "$n" "$m"; flagged
  jq '. + {"reply-time-tolerance-minutes": 5}' "$ROOT/config/thresholds.json" > "$BATS_TEST_TMPDIR/th.json"
  st_inj; ALFRED_THRESHOLDS="$BATS_TEST_TMPDIR/th.json" audit "$n" "$m"; silent
}

@test "tolerance: read only when the stamp is not in the minute of the clock or of an injected time" {
  P="$BATS_TEST_TMPDIR/plug"; mkdir -p "$P/bin"; cp -r "$ROOT/hooks" "$ROOT/lib" "$ROOT/config" "$P/"
  printf '#!/bin/sh\ntouch "%s/read"\necho 2\n' "$BATS_TEST_TMPDIR" > "$P/bin/alfred-config"; chmod +x "$P/bin/alfred-config"
  st_inj "$(ep '2026-10-30 07:00:10')"
  run --separate-stderr "$P/hooks/reply-audit.sh" --now "$(ep '2026-10-30 07:20:30')" <<< "$(sj '_[2026-10-30 07:20 CET]_ x')"; silent
  run --separate-stderr "$P/hooks/reply-audit.sh" --now "$(ep '2026-10-30 07:20:30')" <<< "$(sj '_[2026-10-30 07:00 CET]_ x')"; silent
  [ ! -e "$BATS_TEST_TMPDIR/read" ]
  run --separate-stderr "$P/hooks/reply-audit.sh" --now "$(ep '2026-10-30 07:20:30')" <<< "$(sj '_[2026-10-30 07:19 CET]_ x')"; silent
  [ -e "$BATS_TEST_TMPDIR/read" ]
}

# --- AC 7: kill switch -------------------------------------------------------------------------------------

@test "kill switch: the audit is silent and reads no state (a jq spy), the control run reads" {
  in="$(sj '_[2026-10-30 07:24 CET]_ x')"; n="$(ep '2026-10-30 07:21:20')"
  st_inj
  printf '#!/bin/sh\necho called >> "%s/spy"\nexec /usr/bin/jq "$@"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/jq"; chmod +x "$BATS_TEST_TMPDIR/bin/jq"
  ALFRED_REPLY_TS_AUDIT=0 run --separate-stderr "$AUDIT" --now "$n" <<< "$in"
  silent
  [ ! -e "$BATS_TEST_TMPDIR/spy" ]
  run --separate-stderr "$AUDIT" --now "$n" <<< "$in"
  [ "$(/usr/bin/jq -r .decision <<< "$output")" = block ]
  [ -e "$BATS_TEST_TMPDIR/spy" ]
}

@test "kill switch: only the exact value 0 turns the audit off" {
  for v in 1 '' no 00 ' 0'; do
    st_inj
    ALFRED_REPLY_TS_AUDIT="$v" audit "$(ep '2026-10-30 07:21:20')" '_[2026-10-30 07:24 CET]_ x'
    flagged
  done
}

@test "kill switch: stop.sh does not start the part (a stub); the control run starts it" {
  printf '#!/bin/sh\ntouch "%s/ran"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/stub.sh"; chmod +x "$BATS_TEST_TMPDIR/stub.sh"
  export ALFRED_STOP_AUDIT_BIN="$BATS_TEST_TMPDIR/stub.sh"
  ALFRED_REPLY_TS_AUDIT=0 stopsh 1792800000 x
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
  stopsh 1792800000 x
  [ -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "kill switch: the idle gate keeps reading and writing its state" {
  t=$(ep '2026-10-30 07:00:10')
  ALFRED_REPLY_TS_AUDIT=0 prompt "$t"
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" == *"Time now"* ]]
  [ "$(sget .open)" = true ]
  [ "$(sget .last_prompt)" -eq "$t" ]
  ALFRED_REPLY_TS_AUDIT=0 stopsh "$((t + 60))" "reply"
  [ "$(sget .open)" = false ]
  [ "$(sget .last_activity)" -eq "$((t + 60))" ]
  ALFRED_REPLY_TS_AUDIT=0 prompt "$((t + 120))"
  [ -z "$output" ]                                      # not idle: the gate still decides from the state
}

# --- AC 6 and the lib: rule text, docs, interface ---------------------------------------------------------

@test "lib: reply_time_stamp_head, reply_time_stamp_epoch, reply_time_verdict and reply_time_audit_state by table" {
  # shellcheck disable=SC1091
  . "$ROOT/lib/reply-time.sh"
  [ "$(reply_time_stamp_head 'Time now _[2026-10-30 08:20 CET]_ hi')" = "2026 10 30 08 20 CET" ]
  [ "$(reply_time_stamp_head $'  \n_[2026-07-01 12:00 CEST]_')" = "2026 07 01 12 00 CEST" ]
  ! reply_time_stamp_head 'x _[2026-10-30 08:20 CET]_'
  [ "$(reply_time_stamp_epoch 2026 10 25 02 30 CEST)" = 1792888200 ]
  [ "$(reply_time_stamp_epoch 2026 10 25 02 30 CET)" = 1792891800 ]
  ! reply_time_stamp_epoch 2026 13 30 07 24 CET
  [ "$(reply_time_verdict 1792884600 1792884600 2)" = ok ]
  [ "$(reply_time_verdict 1792884720 1792884600 2)" = future ]
  [ "$(reply_time_verdict 1792884000 1792884600 2)" = stale ]
  [ "$(reply_time_verdict 1792884000 1792884600 2 1792884010)" = ok ]
  state '{"injected":[1792884600],"flagged":true}'
  [ "$(reply_time_audit_state s1)" = "true|1792884600" ]
  state '{}'
  [ "$(reply_time_audit_state s1)" = "false|" ]
  rm -f "$SF"
  ! reply_time_audit_state s1
}

@test "state: the prompt merge keeps keys of other writers and heals a bad audit key" {
  t=$(ep '2026-10-30 07:00:10')
  state '{"foreign":{"a":1},"injected":"bad","flagged":"bad"}'
  prompt "$t"
  [ "$(sget -c .foreign)" = '{"a":1}' ]
  [ "$(sget -c .injected)" = "[$t]" ]
  [ "$(sget .flagged)" = false ]
}

@test "state: injected and flagged are computed inside the merge's own read (a Stop that lands between the gate and the write is seen)" {
  t=$(ep '2026-10-30 07:00:10')
  # the gate saw open true; by the write the Stop has recorded open false: the merge restarts
  state "{\"injected\":[$((t - 5000))],\"open\":false,\"last_activity\":$((t - 7200))}"
  prompt "$t"
  [ "$(sget -c .injected)" = "[$t]" ]
}

@test "state: a session id with unsafe characters reaches one file from the prompt hook, the Stop record and the audit" {
  t=$(ep '2026-10-30 07:00:10')
  sid='a/b c..d'
  ALFRED_REPLY_TS_NOW="$t" run --separate-stderr "$HOOK" <<< "$(jq -cn --arg s "$sid" '{session_id: $s, prompt: "hi", source: "user"}')"
  [ "$(ls "$STATE")" = "a_b_c..d.json" ]
  ALFRED_REPLY_TS_NOW="$((t + 60))" run --separate-stderr "$STOP" <<< "$(sj '_[2026-10-30 07:24 CET]_ x' false "$sid")"
  flagged
  [ "$(ls "$STATE")" = "a_b_c..d.json" ]
  [ "$(jq -r .flagged "$STATE/a_b_c..d.json")" = true ]
}
