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
  # Never pick up the machine's real installed plugin (self-upgrade).
  export ALFRED_WAKE_PLUGINS_JSON="$BATS_TEST_TMPDIR/no-plugins.json"
  export ALFRED_WAKE_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  # No session id and a private config dir: the no-mark flag (ccplugin#126)
  # must not depend on the session these tests happen to run in.
  unset CLAUDE_CODE_SESSION_ID
  # A name no real process has: a real `claude` above the bats run is never the owner.
  export ALFRED_WAKE_OWNER_COMM="no-real-owner-comm"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  inbox
  # Job control: without it, `&` jobs of a non-interactive shell start with
  # SIGINT ignored, and an ignored-at-start signal cannot be trapped.
  set -m
}

teardown() {
  local pid
  for pid in "${FAKE_PIDS[@]:-}"; do
    if [ -n "$pid" ]; then kill -KILL "$pid" 2>/dev/null || true; fi
  done
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
FAKE_PIDS=()
# fake_claude <name> <cmd...> — an executable called <name> (the owner name that
# alfred-wake looks for) that starts <cmd> as its child, output to $FAKE_OUT
# (default $BATS_TEST_TMPDIR/fake.out), and stays up while the child runs.
# Sets fake_pid; teardown kills it by that pid.
fake_claude() {
  local name="$1" f
  shift
  f="$BATS_TEST_TMPDIR/fake/$name"
  mkdir -p "${f%/*}"
  printf '#!/bin/bash\n"$@" > "%s" 2>&1 3>&- &\nwait\n' "${FAKE_OUT:-$BATS_TEST_TMPDIR/fake.out}" > "$f"
  chmod +x "$f"
  "$f" "$@" 3>&- &
  fake_pid=$!
  FAKE_PIDS+=("$fake_pid")
}
pidfile_set() { [ -s "$STATE/alfred-wake.pid" ]; }
pidfile_not() { [ -s "$STATE/alfred-wake.pid" ] && [ "$(cat "$STATE/alfred-wake.pid")" != "$1" ]; }
# owned_wait <owner-name> — a wait under a fake claude of that name; sets
# fake_pid and wait_pid once the wait holds the pidfile.
owned_wait() {
  export ALFRED_WAKE_OWNER_COMM="$1"
  fake_claude "$1" "$WAKE" wait
  until_true 50 pidfile_set || return 1
  wait_pid=$(cat "$STATE/alfred-wake.pid")
}
# orphan_wait — owned_wait, then SIGKILL the fake claude: the wait survives.
orphan_wait() {
  owned_wait fake-owner-a || return 1
  kill -KILL "$fake_pid"
  wait "$fake_pid" 2>/dev/null || true
  until_true 30 gone "$fake_pid" || return 1
  alive "$wait_pid"
}
no_leftovers() {
  [ ! -e "$STATE/alfred-wake.pid" ] &&
    [ ! -e "$STATE/alfred-wake.owner" ] &&
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

@test "a first wait over a non-empty inbox reports the backlog once, then stays quiet" {
  inbox m1:bob m2:carol
  run timeout 5 "$WAKE" wait
  [ "$status" -eq 0 ]
  [ "$output" = "WAKE am unread=2 from=bob,carol pending-at-start" ]

  start a wait
  sleep 2.5
  alive "$a_pid"
  [ -z "$(out_of a)" ]
}

@test "ccplugin#126: a WAKE line carries no-mark while the session has no work item mark" {
  export CLAUDE_CODE_SESSION_ID=sess-wake-1
  start a wait
  sleep 2.5
  inbox m1:bob
  reap "$a_pid"
  [ "$rc" -eq 0 ]
  [ "$(out_of a)" = "WAKE am unread=1 from=bob no-mark" ]
  no_leftovers
}

@test "ccplugin#126: no no-mark flag once the session is marked" {
  export CLAUDE_CODE_SESSION_ID=sess-wake-2
  mkdir -p "$CLAUDE_CONFIG_DIR/alfred-workitem"
  echo '{"item":"acme/widgets#7","marked_at":"2026-10-22T08:00:00Z","estimate":null}' \
    > "$CLAUDE_CONFIG_DIR/alfred-workitem/sess-wake-2.json"
  start a wait
  sleep 2.5
  inbox m1:bob
  reap "$a_pid"
  [ "$rc" -eq 0 ]
  [ "$(out_of a)" = "WAKE am unread=1 from=bob" ]
  no_leftovers
}

@test "legacy run still seeds with WAKE-INIT only, never a pending-at-start line" {
  inbox m1:bob
  start a run
  until_true 30 test -s "$BATS_TEST_TMPDIR/a.out"
  sleep 1.5
  [ "$(out_of a | cut -d' ' -f1)" = "WAKE-INIT" ]
  [ "$(out_of a | wc -l)" -eq 1 ]
}

@test "a relaunched wait does not re-report old unread mail, only new mail" {
  mkdir -p "$STATE" && touch "$STATE/.initialized"
  echo '{"cursor":"c1"}' > "$STATE/am_state.json"
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
  echo '{"cursor":"c0"}' > "$STATE/am_state.json"
  inbox m1:bob
  run timeout 5 "$WAKE" run --until-wake
  [ "$status" -eq 0 ]
  [ "$output" = "WAKE am unread=1 from=bob" ]
}

@test "#849: with 8 unread and 1 new, exactly one wake naming only the new sender" {
  mkdir -p "$STATE" && touch "$STATE/.initialized"
  echo '{"cursor":"c7"}' > "$STATE/am_state.json"
  inbox m1:a m2:b m3:c m4:d m5:e m6:f m7:g m8:zed
  run timeout 5 "$WAKE" wait
  [ "$status" -eq 0 ]
  [ "$output" = "WAKE am unread=8 from=zed" ]

  start a wait
  sleep 2.5
  alive "$a_pid"
  [ -z "$(out_of a)" ]
}

@test "a cursor the server no longer knows is reseated without replaying history" {
  mkdir -p "$STATE" && touch "$STATE/.initialized"
  echo '{"cursor":"not-a-cursor"}' > "$STATE/am_state.json"
  inbox m1:bob m2:carol
  run timeout 5 "$WAKE" wait
  [ "$status" -eq 0 ]
  [ "$output" = "WAKE am unread=2 from=bob,carol cursor-reset" ]
  [ "$(jq -r .cursor "$STATE/am_state.json")" = "c2" ]
}

@test "more new mail than one page: one wake, every page read, cursor at the end" {
  local i ids=()
  mkdir -p "$STATE" && touch "$STATE/.initialized"
  echo '{"cursor":"c0"}' > "$STATE/am_state.json"
  for i in $(seq 1 59); do ids+=("m$i:bulk"); done
  inbox "${ids[@]}" m60:late
  run timeout 10 "$WAKE" wait
  [ "$status" -eq 0 ]
  [ "$output" = "WAKE am unread=60 from=bulk,late" ]
  [ "$(jq -r .cursor "$STATE/am_state.json")" = "c60" ]
}

@test "a server without the cursor API falls back to the window and is re-tried hourly" {
  touch "$STUB_DIR/legacy"
  start a wait
  sleep 2.5
  [ -z "$(out_of a)" ]
  [ "$(cat "$STATE/alfred-wake.lock" >/dev/null; cat "$STATE/am_legacy_until")" -gt "$(date +%s)" ]
  inbox m1:bob
  reap "$a_pid"
  [ "$rc" -eq 0 ]
  [ "$(out_of a)" = "WAKE am unread=1 from=bob" ]
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
  [ "$(out_of a)" = "WAKE-STOPPED replaced by=$b_pid" ] || { echo "a printed: $(out_of a)"; false; }
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
  [ -z "$(out_of a)" ] || { echo "a printed: $(out_of a)"; false; }
}

# holders_of <file> — pids that have <file> open (any fd).
holders_of() {
  local fd
  for fd in /proc/[0-9]*/fd/*; do
    [ "$(readlink "$fd" 2>/dev/null)" = "$1" ] && { fd="${fd#/proc/}"; echo "${fd%%/*}"; }
  done | sort -u
  return 0
}

@test "a signal between forking the pass and recording its pid leaves no orphan pass (CCW-139)" {
  mkdir -p "$STATE" && touch "$STATE/.initialized"
  echo '{"unread_ids":[]}' > "$STATE/am_state.json"
  echo 5 > "$STUB_DIR/slow"                  # the pass outlives the bridge if orphaned
  export ALFRED_WAKE_TEST_FORK_DELAY=3       # test-only: hold the fork window open
  start a run
  until_true 50 test -e "$STATE/fork_window"  # a is now inside the window
  kill -TERM "$a_pid"
  reap "$a_pid"
  [ "$rc" -eq 0 ]
  [ -z "$(out_of a)" ] || { echo "a printed: $(out_of a)"; false; }
  local holders
  holders=$(holders_of "$BATS_TEST_TMPDIR/a.out")
  [ -z "$holders" ] || { echo "orphans still hold a.out: $(echo $holders) -> $(ps -o pid,ppid,cmd -p $(echo $holders | tr ' ' ',') 2>&1)"; false; }
  no_leftovers
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

# --- owner: status needs the Claude Code process that started the wait ------

@test "wait records its owner" {
  local name i=0 body own pid
  mkdir -p "$BATS_TEST_TMPDIR/fake"
  printf '#!/bin/bash\n"$@"\nrc=$?\nexit "$rc"\n' > "$BATS_TEST_TMPDIR/fake/wrap (y)"
  chmod +x "$BATS_TEST_TMPDIR/fake/wrap (y)"
  for name in "fake (x) claude" "claude-fake-long-name"; do
    i=$((i + 1))
    inbox
    export ALFRED_WAKE_OWNER_COMM="$name"
    fake_claude "$name" "$BATS_TEST_TMPDIR/fake/wrap (y)" "$WAKE" wait
    until_true 50 pidfile_set
    [ "$(cut -d' ' -f1 "$STATE/alfred-wake.owner")" = "$fake_pid" ]
    [ "$(cut -d' ' -f2 "$STATE/alfred-wake.owner")" = "$(sed 's/.*) //' /proc/$fake_pid/stat | awk '{print $20}')" ]
    inbox "m$i:bob"
    until_true 100 gone "$fake_pid"
    [ ! -e "$STATE/alfred-wake.owner" ]
    no_leftovers
  done
  body=$(sed -n '/^take_over()/,/^}/p' "$WAKE")
  own=$(printf '%s\n' "$body" | grep -n '> "$OWNER_FILE"' | tail -1 | cut -d: -f1)
  pid=$(printf '%s\n' "$body" | grep -n '> "$PID_FILE"' | head -1 | cut -d: -f1)
  [ -n "$own" ]
  [ -n "$pid" ]
  [ "$own" -lt "$pid" ]
}

@test "an orphaned wait is not armed" {
  orphan_wait
  export CLAUDE_CODE_SESSION_ID=dead-session
  run "$WAKE" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"armed:      no"*"owner"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"pid $wait_pid"* ]] || { echo "$output"; return 1; }
  alive "$wait_pid"
}

@test "a wait with a live owner is armed" {
  owned_wait fake-owner-a
  run "$WAKE" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"armed:      yes (pid $wait_pid"* ]]
}

@test "a new wait replaces an orphan and takes over the owner" {
  orphan_wait
  local orphan="$wait_pid"
  FAKE_OUT="$BATS_TEST_TMPDIR/b.out" fake_claude fake-owner-a "$WAKE" wait
  until_true 50 pidfile_not "$orphan"
  wait_pid=$(cat "$STATE/alfred-wake.pid")
  reap "$orphan"
  [ "$(cat "$BATS_TEST_TMPDIR/fake.out")" = "WAKE-STOPPED replaced by=$wait_pid" ] || { echo "orphan printed: $(cat "$BATS_TEST_TMPDIR/fake.out")"; false; }
  [ "$(cut -d' ' -f1 "$STATE/alfred-wake.owner")" = "$fake_pid" ]
  run "$WAKE" status
  [ "$status" -eq 0 ]
}

@test "a reused owner pid with another start time is not an owner" {
  owned_wait fake-owner-a
  echo "$$ 1" > "$STATE/alfred-wake.owner"
  alive "$$"
  run "$WAKE" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"armed:      no"*"owner"* ]] || { echo "$output"; return 1; }
}

@test "no owner and no session id: no owner file, status as before" {
  mkdir -p "$STATE"
  echo "999999 1" > "$STATE/alfred-wake.owner"
  start a wait
  until_true 30 pidfile_is "$a_pid"
  [ ! -e "$STATE/alfred-wake.owner" ]
  run "$WAKE" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"armed:      yes (pid $a_pid"* ]]
}

@test "no owner but a session id: owner unknown, status fails closed" {
  export CLAUDE_CODE_SESSION_ID=sess-no-owner
  start a wait
  until_true 30 pidfile_is "$a_pid"
  [ "$(cat "$STATE/alfred-wake.owner")" = "unknown" ]
  run "$WAKE" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"armed:      no"*"no owner"* ]] || { echo "$output"; return 1; }
  alive "$a_pid"
}

@test "status --json: an orphan or unknown owner is down" {
  orphan_wait
  run "$WAKE" status --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r .state)" = "down" ]
  [ "$(printf '%s' "$output" | jq -r .armed)" = "false" ]
  [ "$(printf '%s' "$output" | jq -r .pid)" = "null" ]
  echo unknown > "$STATE/alfred-wake.owner"
  run "$WAKE" status --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r .state)" = "down" ]
  [ "$(printf '%s' "$output" | jq -r .armed)" = "false" ]
  [ "$(printf '%s' "$output" | jq -r .pid)" = "null" ]
}

@test "status --json: handling survives a dead owner" {
  orphan_wait
  date +%s > "$STATE/last_wake_exit"
  run "$WAKE" status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .state)" = "handling" ]
  [ "$(printf '%s' "$output" | jq -r .armed)" = "true" ]
}

# --- self-upgrade (ccplugin#107) ----------------------------------------------

# fake_install <version>: an installed plugin whose alfred-wake reports itself.
fake_install() {
  local root="$BATS_TEST_TMPDIR/cache/$1"
  mkdir -p "$root/bin"
  cat > "$root/bin/alfred-wake" <<EOF
#!/bin/bash
VERSION="$1"
[ "\${1:-}" = --version ] && { echo "alfred-wake $1"; exit 0; }
echo "ran $1 args=\$* from=\${ALFRED_WAKE_UPGRADED_FROM:-}"
EOF
  chmod +x "$root/bin/alfred-wake"
  jq -n --arg p "$root" '{plugins: {"alfred-agent@alfred-cc-tools": [{scope: "user", installPath: $p}]}}' \
    > "$ALFRED_WAKE_PLUGINS_JSON"
}

@test "wait execs the installed alfred-wake when it is newer, and relinks ~/.local/bin" {
  fake_install 9.9.0
  mkdir -p "$ALFRED_WAKE_BIN_DIR"
  ln -s "$(readlink -f "$WAKE")" "$ALFRED_WAKE_BIN_DIR/alfred-wake"
  run "$ALFRED_WAKE_BIN_DIR/alfred-wake" wait 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran 9.9.0 args=wait 5 from=1.9.0"* ]]
  [ "$(readlink -f "$ALFRED_WAKE_BIN_DIR/alfred-wake")" = "$BATS_TEST_TMPDIR/cache/9.9.0/bin/alfred-wake" ]
  grep -q "upgrade: 1.9.0 -> 9.9.0" "$STATE/alfred-wake.log"
}

@test "an older or equal installed alfred-wake is not used" {
  for v in 1.0.0 1.9.0; do
    fake_install "$v"
    run timeout 3 "$WAKE" wait
    [[ "$output" != *"ran $v"* ]]
  done
}

@test "ALFRED_WAKE_NO_UPGRADE=1 keeps the running version" {
  fake_install 9.9.0
  ALFRED_WAKE_NO_UPGRADE=1 run timeout 3 "$WAKE" wait
  [[ "$output" != *"ran 9.9.0"* ]]
}

@test "a newer installed alfred-wake that does not start is skipped" {
  fake_install 9.9.0
  printf '#!/bin/bash\nVERSION="9.9.0"\nif then\n' > "$BATS_TEST_TMPDIR/cache/9.9.0/bin/alfred-wake"
  mkdir -p "$ALFRED_WAKE_BIN_DIR"
  ln -s "$(readlink -f "$WAKE")" "$ALFRED_WAKE_BIN_DIR/alfred-wake"
  run timeout 3 "$ALFRED_WAKE_BIN_DIR/alfred-wake" wait
  [[ "$output" != *"ran 9.9.0"* ]]
  [ "$(readlink -f "$ALFRED_WAKE_BIN_DIR/alfred-wake")" = "$(readlink -f "$WAKE")" ]
  grep -q "upgrade skipped" "$STATE/alfred-wake.log"
}

@test "--version prints the version" {
  run "$WAKE" --version
  [ "$status" -eq 0 ]
  [ "$output" = "alfred-wake 1.9.0" ]
}

# --- Stop hook: never end a turn with the bridge down -----------------------

hook() {  # hook <stop_hook_active> — run bridge-check.sh for a lead project
  local proj="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$proj/.alfred"
  echo '{"agent_id":"tester"}' > "$proj/.alfred/config.json"
  printf '{"cwd":"%s","stop_hook_active":%s}' "$proj" "${1:-false}" \
    | ALFRED_WAKE_CHECK_BIN="$WAKE" ALFRED_DEVBOX_MARKER="${MARKER-$BATS_TEST_DIRNAME/alfred-wake.bats}" \
      "$BATS_TEST_DIRNAME/../hooks/bridge-check.sh"
}

@test "stop hook stays out of a lead that is not on a devbox (the hub runs another bridge)" {
  MARKER="$BATS_TEST_TMPDIR/not-a-devbox" run hook false
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # ...unless forced on.
  MARKER="$BATS_TEST_TMPDIR/not-a-devbox" ALFRED_WAKE_STOP_CHECK=1 run hook false
  [ "$(printf '%s' "$output" | jq -r .decision)" = "block" ]
}

@test "stop hook blocks the stop when the bridge is not running" {
  run hook false
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .decision)" = "block" ]
  [[ "$(printf '%s' "$output" | jq -r .reason)" == *"alfred-wake wait"* ]]
}

@test "stop hook stays silent while the bridge is armed" {
  start a wait
  until_true 30 pidfile_is "$a_pid"
  run hook false
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop hook never blocks twice: a failed relaunch lets the stop through with a warning" {
  run hook true
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision // "none"')" = "none" ]
  [[ "$(printf '%s' "$output" | jq -r .systemMessage)" == WARNING:*"still not running"* ]]
}

@test "stop hook after a successful relaunch is silent" {
  start a wait
  until_true 30 pidfile_is "$a_pid"
  run hook true
  [ -z "$output" ]
}

@test "stop hook stays out of non-lead projects and can be switched off" {
  run bash -c 'printf "{\"cwd\":\"/nonexistent\"}" | "$1"' _ "$BATS_TEST_DIRNAME/../hooks/bridge-check.sh"
  [ -z "$output" ]
  ALFRED_WAKE_STOP_CHECK=0 run hook false
  [ -z "$output" ]
}

# --- SessionStart check: watcher and inbox after a (re)start ----------------

# fake tmux: logs send-keys, shows $STUB_DIR/pane as the screen
fake_tmux() {
  cat > "$BATS_TEST_TMPDIR/tmux" <<'EOF'
#!/bin/bash
case "$1" in
  capture-pane) cat "$STUB_DIR/pane" 2>/dev/null; true ;;
  send-keys) shift; echo "$*" >> "$STUB_DIR/keys" ;;
  display-message)
    case "$*" in
      *session_attached*) cat "$STUB_DIR/attached" 2>/dev/null || echo 0 ;;
      *cursor_x*) cat "$STUB_DIR/cursor" 2>/dev/null || echo "2 1" ;;
    esac ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/tmux"
  printf 'Claude Code\n❯ Try "write a test"\n' > "$STUB_DIR/pane"
}

session_hook() {  # session_hook <source> — run session-check.sh in a lead project
  local proj="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$proj/.alfred"
  echo '{"agent_id":"tester"}' > "$proj/.alfred/config.json"
  printf '{"cwd":"%s","source":"%s"}' "$proj" "$1" \
    | ALFRED_WAKE_CHECK_BIN="$WAKE" ALFRED_TMUX_BIN="$BATS_TEST_TMPDIR/tmux" \
      ALFRED_NUDGE_DELAY=0.2 ALFRED_NUDGE_TRIES=3 TMUX_PANE="%9" \
      "$BATS_TEST_DIRNAME/../hooks/session-check.sh"
}
ctx_of() { printf '%s' "$1" | jq -r .hookSpecificOutput.additionalContext; }

@test "session start with an orphaned wait: NOT running, relaunch, one nudge" {
  fake_tmux
  orphan_wait
  export CLAUDE_CODE_SESSION_ID=dead-session
  run session_hook resume
  [ "$status" -eq 0 ]
  [[ "$(ctx_of "$output")" == *"NOT running"* ]]
  [[ "$(ctx_of "$output")" == *'Bash(command: "alfred-wake wait", run_in_background: true)'* ]]
  until_true 30 test -s "$STUB_DIR/keys"
  sleep 1
  [ "$(grep -c 'substrate wake' "$STUB_DIR/keys")" -eq 1 ]
}

@test "stop hook blocks the stop when the wait is an orphan" {
  orphan_wait
  export CLAUDE_CODE_SESSION_ID=dead-session
  run hook false
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .decision)" = "block" ]
}

@test "unread prints the agent-messaging unread count" {
  inbox m1:alice m2:bob
  run "$WAKE" unread
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "session start with the watcher down: context says relaunch, read, report; one nudge typed" {
  fake_tmux
  inbox m1:alice
  run session_hook resume
  [ "$status" -eq 0 ]
  [[ "$(ctx_of "$output")" == *"watcher is NOT running and the inbox has 1 unread"* ]]
  [[ "$(ctx_of "$output")" == *'Bash(command: "alfred-wake wait", run_in_background: true)'* ]]
  [[ "$(ctx_of "$output")" == *"/alfred-agent:check-messages"* ]]
  until_true 30 test -s "$STUB_DIR/keys"
  sleep 1
  [ "$(grep -c 'substrate wake' "$STUB_DIR/keys")" -eq 1 ]
  grep -q '^-t %9 Enter$' "$STUB_DIR/keys"
}

@test "nudge waits while a turn runs, and gives up once the watcher is up" {
  fake_tmux
  echo "  esc to interrupt" > "$STUB_DIR/pane"
  run session_hook startup
  sleep 0.5
  [ ! -s "$STUB_DIR/keys" ]
  start a wait
  until_true 30 pidfile_is "$a_pid"
  : > "$STUB_DIR/pane"
  sleep 1
  [ ! -s "$STUB_DIR/keys" ]
}

@test "nudge never types when someone is attached, the prompt has input, or a dialog is open" {
  fake_tmux
  echo 1 > "$STUB_DIR/attached"
  run session_hook startup
  sleep 1
  [ ! -s "$STUB_DIR/keys" ]
  echo 0 > "$STUB_DIR/attached"
  echo "17 1" > "$STUB_DIR/cursor"
  run session_hook startup
  sleep 1
  [ ! -s "$STUB_DIR/keys" ]
  echo "2 1" > "$STUB_DIR/cursor"
  printf 'Do you want to proceed?\n❯ 1. Yes\n  Enter to confirm · Esc to cancel\n' > "$STUB_DIR/pane"
  run session_hook startup
  sleep 1
  [ ! -s "$STUB_DIR/keys" ]
}

@test "nudge erases its text instead of pressing Enter when someone attaches meanwhile" {
  fake_tmux
  # Attach as soon as the prompt has been typed.
  cat >> "$BATS_TEST_TMPDIR/tmux" <<'EOF'
[[ "$*" == *"-l "* ]] && { echo 1 > "$STUB_DIR/attached"; printf '❯ %s%s\n──────\n' "${!#}" "$(cat "$STUB_DIR/typed_after" 2>/dev/null)" > "$STUB_DIR/pane"; }
true
EOF
  run session_hook startup
  until_true 30 test -s "$STUB_DIR/keys"
  sleep 1.5
  grep -q 'substrate wake' "$STUB_DIR/keys"
  grep -q -- '-N [0-9]* BSpace' "$STUB_DIR/keys"
  ! grep -q ' Enter$' "$STUB_DIR/keys"
}

@test "nudge leaves its text alone when someone typed after it: no erase, no Enter" {
  fake_tmux
  cat >> "$BATS_TEST_TMPDIR/tmux" <<'EOF'
[[ "$*" == *"-l "* ]] && { echo 1 > "$STUB_DIR/attached"; printf '❯ %s%s\n──────\n' "${!#}" "$(cat "$STUB_DIR/typed_after" 2>/dev/null)" > "$STUB_DIR/pane"; }
true
EOF
  echo " hello there" > "$STUB_DIR/typed_after"
  run session_hook startup
  until_true 30 test -s "$STUB_DIR/keys"
  sleep 1.5
  grep -q 'substrate wake' "$STUB_DIR/keys"
  if grep -q 'BSpace' "$STUB_DIR/keys"; then return 1; fi
  if grep -q ' Enter$' "$STUB_DIR/keys"; then return 1; fi
  [ "$(wc -l < "$STUB_DIR/keys")" -eq 1 ]
}

@test "session start with the watcher up and no mail: one quiet line, no nudge" {
  fake_tmux
  start a wait
  until_true 30 pidfile_is "$a_pid"
  run session_hook resume
  [[ "$(ctx_of "$output")" == "Wake watcher: running. Inbox: 0 unread."* ]]
  sleep 1
  [ ! -s "$STUB_DIR/keys" ]
}

@test "compact never types into the pane; non-lead projects and the switch stay silent" {
  fake_tmux
  run session_hook compact
  [[ "$(ctx_of "$output")" == *"NOT running"* ]]
  sleep 1
  [ ! -s "$STUB_DIR/keys" ]
  run bash -c 'printf "{\"cwd\":\"/nonexistent\",\"source\":\"startup\"}" | "$1"' _ "$BATS_TEST_DIRNAME/../hooks/session-check.sh"
  [ -z "$output" ]
  ALFRED_SESSION_CHECK=0 run session_hook startup
  [ -z "$output" ]
}

@test "notify sends one message as this agent and prints nothing" {
  run "$WAKE" notify hub "[login] x: Remote Control off" "line 1
line 2"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r .to "$STUB_DIR/sent.jsonl")" = "hub" ]
  [ "$(jq -r .subject "$STUB_DIR/sent.jsonl")" = "[login] x: Remote Control off" ]
  [ "$(jq -r .body "$STUB_DIR/sent.jsonl")" = "line 1
line 2" ]
}

@test "notify fails cleanly: missing arguments exit 2, server down exit 1" {
  run "$WAKE" notify hub "subject only"
  [ "$status" -eq 2 ]
  touch "$STUB_DIR/fail"
  run "$WAKE" notify hub s b
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_DIR/sent.jsonl" ]
}

# --- status --json: a just-woken lead is "handling", still armed -------------

@test "status --json: waiting while a wait runs, handling after a wake, down after the grace" {
  run "$WAKE" status --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.armed,.state,.pid,.lastWakeExitAt' | paste -sd' ' -)" = "false down null null" ]

  start a wait
  until_true 30 pidfile_is "$a_pid"
  run "$WAKE" status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.armed,.state' | paste -sd' ' -)" = "true waiting" ]
  [ "$(printf '%s' "$output" | jq -r .pid)" = "$a_pid" ]

  inbox m1:alice
  reap "$a_pid"
  [ "$rc" -eq 0 ]
  run "$WAKE" status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.armed,.state,.pid' | paste -sd' ' -)" = "true handling null" ]
  [ "$(printf '%s' "$output" | jq -r '.lastWakeExitAgoSeconds')" -le 5 ]
  # The plain status stays strict: the hooks must still see "not running".
  run "$WAKE" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"handling:   yes"* ]]

  ALFRED_WAKE_HANDLING_GRACE=0 run "$WAKE" status --json
  sleep 1
  ALFRED_WAKE_HANDLING_GRACE=0 run "$WAKE" status --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.armed,.state' | paste -sd' ' -)" = "false down" ]
}

@test "status --json: a new wait ends handling; stopping it gives down, not stale handling" {
  start a wait
  until_true 30 pidfile_is "$a_pid"
  inbox m1:alice
  reap "$a_pid"
  run "$WAKE" status --json
  [ "$(printf '%s' "$output" | jq -r .state)" = "handling" ]
  start b wait
  until_true 30 pidfile_is "$b_pid"
  kill -TERM "$b_pid"
  reap "$b_pid"
  run "$WAKE" status --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.armed,.state,.lastWakeExitAt' | paste -sd' ' -)" = "false down null" ]
}

@test "status --json: a bad grace falls back to 600, a future stamp never gives a negative age" {
  mkdir -p "$STATE"
  echo $(( $(date +%s) + 3600 )) > "$STATE/last_wake_exit"
  ALFRED_WAKE_HANDLING_GRACE=10m run "$WAKE" status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.graceSeconds,.state,.lastWakeExitAgoSeconds' | paste -sd' ' -)" = "600 handling 0" ]
}

# --- doctrines and rules in the session context (ccplugin#121) ---------------

@test "doctrines hook: every rule in full, one index line per doctrine, under the hook cap" {
  run "$BATS_TEST_DIRNAME/../hooks/doctrines-context.sh"
  [ "$status" -eq 0 ]
  ctx=$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)
  [ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.hookEventName)" = "SessionStart" ]
  # Every rules/ file appears in full (first 60 characters checked).
  for f in "$BATS_TEST_DIRNAME"/../rules/*.md; do
    head_txt=$(tr '\n' ' ' < "$f" | cut -c1-60)
    [[ "$ctx" == *"$head_txt"* ]]
  done
  # One "- DNN <title>: <rule>" line per doctrine file, none with an empty title or rule.
  n_files=$(ls "$BATS_TEST_DIRNAME"/../doctrines/[0-9][0-9]-*.md | wc -l)
  [ "$(printf '%s\n' "$ctx" | grep -cE '^- D[0-9]{2} [^:]+: .+')" -eq "$n_files" ]
  if printf '%s\n' "$ctx" | grep -qE '^- D[0-9]{2} :'; then return 1; fi
  # Hook strings are capped at 10,000 characters; keep headroom.
  [ "${#ctx}" -lt 9500 ]
}
