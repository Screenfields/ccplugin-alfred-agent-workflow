#!/usr/bin/env bats
# Behaviour tests for bin/alfred-wake: one-shot `wait`, single instance,
# clean shutdown, and a `status` that only reports live processes.
# agent-messaging is replaced by tests/stub/curl; Buzz is off.
# shellcheck disable=SC2154  # <name>_pid variables are assigned by start() via eval

setup() {
  WAKE="$BATS_TEST_DIRNAME/../bin/alfred-wake"
  STATE="$BATS_TEST_TMPDIR/state"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  export PATH="$BATS_TEST_DIRNAME/stub:$PATH"
  export ALFRED_WAKE_STATE_DIR="$STATE"
  export ALFRED_WAKE_BUZZ=off
  export ALFRED_WAKE_INTERVAL=1
  export ALFRED_WAKE_AM_INTERVAL=1
  export AGENT_MESSAGING_URL="http://stub.invalid/mcp/"
  export AGENT_MESSAGING_TOKEN="test-token"
  export AGENT_ID="tester"
  inbox
  # Job control: without it, `&` jobs of a non-interactive shell start with
  # SIGINT ignored, and an ignored-at-start signal cannot be trapped.
  set -m
}

teardown() {
  local pid
  for pid in $(pgrep -f "alfred-wake (wait|run)" 2>/dev/null); do
    if grep -qzxF "ALFRED_WAKE_STATE_DIR=$STATE" "/proc/$pid/environ" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  pkill -f "sleep 31.4159" 2>/dev/null || true
}

# inbox [<id>:<from> ...] — set what get_messages returns as unread.
inbox() {
  local entries="" pair
  for pair in "$@"; do
    entries="${entries:+$entries,}{\"id\":\"${pair%%:*}\",\"from_agent\":\"${pair#*:}\"}"
  done
  printf '{"messages":[%s],"total_unread":%d}' "$entries" "$#" > "$STUB_DIR/inbox.json"
}

# start <name> <args...> — run alfred-wake in the background; output in $BATS_TEST_TMPDIR/<name>.out
start() {
  local name="$1"
  shift
  "$WAKE" "$@" > "$BATS_TEST_TMPDIR/$name.out" 2>&1 3>&- &
  eval "${name}_pid=$!"
}

out_of() { cat "$BATS_TEST_TMPDIR/$1.out"; }

# until_true <tenths-of-a-second> <command...>
until_true() {
  local n="$1"
  shift
  while ! "$@"; do
    n=$((n - 1))
    [ "$n" -gt 0 ] || return 1
    sleep 0.1
  done
}

gone() { [ -z "$(tr -d '\0' < "/proc/$1/cmdline" 2>/dev/null)" ]; }
# A plain `! cmd` never fails a bats test (errexit ignores it), hence alive().
alive() { ! gone "$1"; }
# reap <pid> — bounded wait for a background start to exit; sets $rc. (`run
# wait` cannot work: run uses a subshell, which cannot wait on our children.)
reap() {
  rc=0
  until_true 100 gone "$1" || return 1
  wait "$1" || rc=$?
}
pidfile_is() { [ "$(cat "$STATE/alfred-wake.pid" 2>/dev/null)" = "$1" ]; }
no_leftovers() {
  [ ! -e "$STATE/alfred-wake.pid" ] &&
    ! compgen -G "$STATE/run.*" > /dev/null &&
    ! compgen -G "$STATE/*.json.??????" > /dev/null
}

@test "wait seeds silently, stays quiet with no news, exits 0 on the first new message" {
  start a wait
  sleep 2.5
  gone "$a_pid" && { out_of a; false; }
  [ -z "$(out_of a)" ]

  inbox m1:bob
  reap "$a_pid"
  [ "$rc" -eq 0 ]
  [ "$(out_of a)" = "WAKE am unread=1 from=bob" ]
  no_leftovers
}

@test "a relaunched wait does not re-report old unread mail, only new mail" {
  mkdir -p "$STATE" && touch "$STATE/.initialized"
  echo '{"unread_ids":["m1"]}' > "$STATE/am_state.json"
  inbox m1:bob
  start a wait
  sleep 2.5
  [ -z "$(out_of a)" ]

  inbox m1:bob m2:carol
  reap "$a_pid"
  [ "$rc" -eq 0 ]
  [ "$(out_of a)" = "WAKE am unread=2 from=carol" ]
}

@test "mail that arrived between two waits wakes the next wait immediately" {
  mkdir -p "$STATE" && touch "$STATE/.initialized"
  echo '{"unread_ids":[]}' > "$STATE/am_state.json"
  inbox m1:bob
  run timeout 5 "$WAKE" run --until-wake
  [ "$status" -eq 0 ]
  [ "$output" = "WAKE am unread=1 from=bob" ]
}

@test "wait exits 2 with a WAKE-ERROR line when agent-messaging fails" {
  export ALFRED_WAKE_FAIL_THRESHOLD=1
  touch "$STUB_DIR/fail"
  run timeout 5 "$WAKE" wait
  [ "$status" -eq 2 ]
  [ "$output" = "WAKE-ERROR agent-messaging: initialize http 500" ]
  no_leftovers
}

@test "a new wait stops the previous one, which reports it was replaced" {
  start a wait
  until_true 30 pidfile_is "$a_pid"
  start b wait
  reap "$a_pid"
  [ "$rc" -eq 0 ]
  [ "$(out_of a)" = "WAKE-STOPPED replaced by=$b_pid" ]
  until_true 30 pidfile_is "$b_pid"
  alive "$b_pid"
}

@test "takeover escalates to SIGKILL when the previous instance ignores SIGTERM" {
  local fake="$BATS_TEST_TMPDIR/fake/alfred-wake"
  mkdir -p "${fake%/*}" "$STATE"
  printf '#!/usr/bin/env bash\ntrap "" TERM\nwhile :; do sleep 0.2; done\n' > "$fake"
  chmod +x "$fake"
  "$fake" wait 3>&- &
  local stubborn=$!
  echo "$stubborn" > "$STATE/alfred-wake.pid"

  export ALFRED_WAKE_STOP_GRACE=1
  start b wait
  until_true 40 gone "$stubborn"
  until_true 30 pidfile_is "$b_pid"
  grep -q "previous instance $stubborn ignored SIGTERM for 1s — SIGKILLed" "$STATE/alfred-wake.log"
}

@test "TERM, INT and HUP stop a wait mid-request within a second and clean up" {
  local sig t0
  echo 31.4159 > "$STUB_DIR/slow"
  for sig in TERM INT HUP; do
    start a wait
    until_true 50 pgrep -f "sleep 31.4159"
    t0=$(date +%s%N)
    kill "-$sig" "$a_pid"
    reap "$a_pid"
    [ "$rc" -eq 0 ]
    [ $(( ($(date +%s%N) - t0) / 1000000 )) -lt 1500 ]
    [ "$(out_of a)" = "WAKE-STOPPED signal=$sig" ]
    run pgrep -f "sleep 31.4159"
    [ "$status" -ne 0 ]
    no_leftovers
  done
}

@test "legacy run is single-instance too, and is replaced without printing" {
  mkdir -p "$STATE" && touch "$STATE/.initialized"
  echo '{"unread_ids":[]}' > "$STATE/am_state.json"
  start a run
  until_true 30 pidfile_is "$a_pid"
  start b wait
  reap "$a_pid"
  [ "$rc" -eq 0 ]
  [ -z "$(out_of a)" ]
}

@test "status is armed only while a live process holds the pidfile" {
  mkdir -p "$STATE"
  touch "$STATE/armed"
  echo 999999 > "$STATE/alfred-wake.pid"
  run "$WAKE" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"armed:      no (pid 999999 is not running"* ]]

  start a wait
  until_true 30 pidfile_is "$a_pid"
  run "$WAKE" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"armed:      yes (pid $a_pid"* ]]
}
