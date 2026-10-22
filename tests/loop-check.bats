#!/usr/bin/env bats
# bin/alfred-loop-check and hooks/stop.sh (ccplugin#127): the Stop-hook loop
# check, its combination with bridge-check.sh, and its fail-open behaviour.
# gh is replaced by tests/stub/gh, agreement-messaging by tests/stub/curl
# (through alfred-wake unread --direct). No network, no model call.
# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  LC="$ROOT/bin/alfred-loop-check"
  STOP="$ROOT/hooks/stop.sh"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub" GH_STUB_DIR="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$STUB_DIR" "$GH_STUB_DIR" "$BATS_TEST_TMPDIR/bin"
  ln -s "$BATS_TEST_DIRNAME/stub/gh" "$BATS_TEST_TMPDIR/bin/gh"
  ln -s "$BATS_TEST_DIRNAME/stub/curl" "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  export ALFRED_WAKE_STATE_DIR="$BATS_TEST_TMPDIR/wake"
  export AGENT_MESSAGING_URL="http://stub.invalid/mcp/" AGENT_MESSAGING_TOKEN=t AGENT_ID=tester
  export ALFRED_WAKE_BUZZ=off ALFRED_WAKE_PLUGINS_JSON="$BATS_TEST_TMPDIR/no-plugins.json"
  export ALFRED_WAKE_STOP_CHECK=0
  unset ALFRED_ROLE ALFRED_LOOP_CHECK CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT
  T0=1000000
  export ALFRED_LOOP_NOW=$T0
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/.alfred"
  echo '{"agent_id":"lead-x","repos":["o/a"]}' > "$PROJ/.alfred/config.json"
  THR="$BATS_TEST_TMPDIR/thresholds.json"
  cp "$ROOT/config/thresholds.json" "$THR"
  # The plugin entry reads config/thresholds.json next to the script; tests
  # that need other values copy the plugin to a private root instead.
  PLUG="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$PLUG"
  cp -r "$ROOT/bin" "$ROOT/hooks" "$ROOT/config" "$PLUG/"
  LCP="$PLUG/bin/alfred-loop-check"
  STOPP="$PLUG/hooks/stop.sh"
  echo '{"messages":[],"total_unread":0}' > "$STUB_DIR/inbox.json"
  STATEDIR="$CLAUDE_CONFIG_DIR/alfred-loop"
}

# --- helpers -----------------------------------------------------------------

# issues <owner/name> <num>:<title>:<label,label> ...
issues() {
  local repo="$1" arr="[]" e num title labels
  shift
  for e in "$@"; do
    num="${e%%:*}"; e="${e#*:}"; title="${e%%:*}"; labels="${e#*:}"
    arr=$(jq -c --argjson n "$num" --arg t "$title" --arg l "$labels" --arg r "$repo" \
      '. + [{number: $n, title: $t, url: "https://github.com/\($r)/issues/\($n)",
             labels: ($l | split(",") | map(select(. != "") | {name: .}))}]' <<< "$arr")
  done
  echo "$arr" > "$GH_STUB_DIR/${repo//\//__}.json"
}

# inbox <source>:<id> ... — unread messages (source direct|topic).
inbox() {
  local msgs="[]" e
  for e in "$@"; do
    msgs=$(jq -c --arg s "${e%%:*}" --arg i "${e#*:}" '. + [{id: $i, from_agent: "bob", source: $s}]' <<< "$msgs")
  done
  jq -cn --argjson m "$msgs" '{messages: $m, total_unread: ($m | length)}' > "$STUB_DIR/inbox.json"
}

# hook_json [active] [session] — a Stop hook input.
hook_json() { jq -cn --arg c "$PROJ" --arg s "${2:-s1}" --argjson a "${1:-false}" '{session_id: $s, stop_hook_active: $a, cwd: $c}'; }

# lc [active] [session] — run the check the way the plugin entry does.
lc() { run --separate-stderr bash -c 'printf "%s" "$1" | "$2" --hook --thresholds "$3"' _ "$(hook_json "$@")" "$LC" "$THR"; }

# at <seconds after T0>
at() { export ALFRED_LOOP_NOW=$((T0 + $1)); }

# bats does not fail a test on a bare `! cmd`; `not cmd` does.
not() { if "$@"; then return 1; fi; }
blocked() { [ "$(jq -r .decision <<< "$output")" = "block" ]; }
silent() { [ "$status" -eq 0 ] && [ -z "$output" ]; }
allowed_with_msg() { [ "$status" -eq 0 ] && not blocked && [ -n "$(jq -r '.systemMessage // empty' <<< "$output")" ]; }
frictions() { cat "$STATEDIR/friction.jsonl" 2>/dev/null; }
state_of() { jq -r "$1" "$STATEDIR/s1.json"; }

# --- planted sequence (AC 10) ---------------------------------------------------

@test "one actionable item blocks, naming the item and both ways on" {
  issues o/a "7:Fix the thing:status:ready"
  lc
  [ "$status" -eq 0 ]
  blocked
  reason=$(jq -r .reason <<< "$output")
  [[ "$reason" == *"o/a#7"* && "$reason" == *"Fix the thing"* && "$reason" == *"https://github.com/o/a/issues/7"* ]]
  [[ "$reason" == *"Continue with the next one"* ]]
  [[ "$reason" == *"status:waiting-on-owner"* && "$reason" == *"comment the question"* ]]
}

@test "the same item parked as waiting on owner, and none other, is allowed" {
  issues o/a "7:Fix the thing:status:ready,status:waiting-on-owner"
  lc
  silent
}

@test "no items is allowed, silently" {
  issues o/a
  lc
  silent
  [ -z "$stderr" ]
}

@test "items without a workable state label do not count (and the blind spot is a warning)" {
  issues o/a "3:Idea:bug" "4:Unrefined:status:new"
  lc
  silent
  [[ "$stderr" == *"no status labels in o/a"* ]]
}

@test "in-review, needs-platform-review and blocked count as workable" {
  for s in in-review needs-platform-review blocked; do
    rm -rf "$STATEDIR"
    issues o/a "9:Waiting on a gate:status:$s"
    lc
    blocked || { echo "state $s did not block"; return 1; }
  done
}

@test "wip-limit reached: only the not-ready items count" {
  issues o/a "1:One:status:in-progress" "2:Two:status:in-review" "3:Three:status:ready"
  lc
  blocked
  reason=$(jq -r .reason <<< "$output")
  [[ "$reason" == *"o/a#1"* && "$reason" == *"o/a#2"* && "$reason" != *"o/a#3"* ]]
}

@test "below wip-limit the ready items count too" {
  issues o/a "1:One:status:in-progress" "3:Three:status:ready"
  lc
  reason=$(jq -r .reason <<< "$output")
  [[ "$reason" == *"o/a#1"* && "$reason" == *"o/a#3"* ]]
}

@test "waiting items free their slot: two parked in-progress plus one ready blocks on the ready one" {
  issues o/a "1:One:status:in-progress,status:waiting-on-owner" "2:Two:status:in-progress,status:waiting-on-owner" "3:Three:status:ready"
  lc
  blocked
  reason=$(jq -r .reason <<< "$output")
  [[ "$reason" == *"o/a#3"* && "$reason" != *"o/a#1"* ]]
}

# --- no loop (AC 11) -----------------------------------------------------------------

@test "a block, then the same set inside the chain: allowed with a visible warning and a friction line" {
  issues o/a "7:Fix:status:ready"
  lc; blocked
  at 5
  lc true
  allowed_with_msg
  [[ "$(jq -r .systemMessage <<< "$output")" == *"no progress since the last block"* ]]
  [[ "$stderr" == *"no progress since the last block"* ]]
  [ "$(frictions | jq -r .kind)" = "loop-check-no-progress" ]
  [ "$(frictions | jq -r .session_id)" = "s1" ]
  [ "$(frictions | jq -r .agent_id)" = "lead-x" ]
  [ "$(frictions | jq -r .level)" = "lead" ]
}

@test "progress inside the chain re-blocks: item moved, opened, parked (another remains), message received" {
  issues o/a "7:Fix:status:ready" "8:Other:status:ready"
  lc; blocked
  issues o/a "7:Fix:status:in-progress" "8:Other:status:ready"      # moved
  at 5; lc true; blocked
  issues o/a "7:Fix:status:in-progress" "8:Other:status:ready" "9:New:status:ready"   # opened
  at 6; lc true; blocked
  issues o/a "7:Fix:status:in-progress,status:waiting-on-owner" "8:Other:status:ready" "9:New:status:ready"   # parked
  at 7; lc true; blocked
  issues o/a "8:Other:status:ready"                                # 9 closed
  at 8; lc true; blocked
  inbox direct:m1                                                  # message received
  at 9; lc true; blocked
  [[ "$(jq -r .reason <<< "$output")" == *"read and handle the inbox first"* ]]
}

@test "three stops with no progress: block, allow, allow" {
  issues o/a "7:Fix:status:ready"
  lc; blocked
  at 1; lc true; allowed_with_msg
  at 2; lc true; allowed_with_msg
  [ "$(frictions | wc -l)" -eq 2 ]
}

@test "across turns an unchanged set is allowed inside the chase interval and blocks again once it is stale" {
  issues o/a "7:Fix:status:ready"
  lc; blocked
  at 300; lc false; allowed_with_msg
  at 601; lc false; blocked
}

@test "inside a chain a stale state allows with a warning (expiry never causes a second block)" {
  issues o/a "7:Fix:status:ready"
  lc; blocked
  at 601; lc true
  allowed_with_msg
  [[ "$stderr" == *"no state for this chain"* ]]
}

@test "inside a chain with no state at all: allowed with a warning" {
  issues o/a "7:Fix:status:ready"
  lc true
  allowed_with_msg
}

@test "chase: at chase-max-tries unchanged blocks the reason says escalate to the hub; a label change resets" {
  issues o/a "7:Fix:status:ready"
  lc; blocked; [[ "$(jq -r .reason <<< "$output")" != *"escalate"* ]]
  at 601; lc; blocked; [[ "$(jq -r .reason <<< "$output")" != *"escalate"* ]]
  at 1202; lc; blocked
  reason=$(jq -r .reason <<< "$output")
  [[ "$reason" == *"escalate to the hub and record the escalation on the item"* ]]
  issues o/a "7:Fix:status:in-progress"
  at 1803; lc; blocked
  [[ "$(jq -r .reason <<< "$output")" != *"escalate"* ]]
  [ "$(state_of '.items["o/a#7"].tries')" = "1" ]
}

@test "session cap: after loop-check-max-blocks-per-hour blocks the check allows with friction" {
  for n in 1 2 3 4 5 6; do
    issues o/a "$n:Item $n:status:ready"
    at "$n"; lc; blocked || { echo "block $n missing"; return 1; }
  done
  issues o/a "7:Item 7:status:ready"
  at 7; lc
  allowed_with_msg
  [[ "$stderr" == *"block cap reached"* ]]
  [ "$(frictions | tail -1 | jq -r .kind)" = "loop-check-cap" ]
  at 3700; lc; blocked
}

# --- fails open (AC 12) --------------------------------------------------------------

@test "a gh error allows with a warning" {
  touch "$GH_STUB_DIR/fail-o__a"
  lc
  [ "$status" -eq 0 ]
  not blocked
  [[ "$stderr" == *"o/a: gh failed"* ]]
}

@test "a gh timeout allows with a warning, within the timeout" {
  issues o/a "7:Fix:status:ready"
  echo 20 > "$GH_STUB_DIR/slow-o__a"
  jq '.["loop-check-timeout-seconds"] = 1' "$THR" > "$THR.n" && mv "$THR.n" "$THR"
  start=$SECONDS
  lc
  [ $((SECONDS - start)) -lt 8 ]
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"o/a: gh timed out"* ]]
  not blocked
}

@test "gh output that is not JSON allows with a warning" {
  touch "$GH_STUB_DIR/garbage-o__a"
  lc
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not a JSON list"* ]]
  not blocked
}

@test "an unreachable inbox is a warning, never a silent pass" {
  touch "$STUB_DIR/fail"
  issues o/a
  lc
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"inbox unreachable"* ]]
  not blocked
}

@test "an unreachable inbox does not hide an actionable item" {
  touch "$STUB_DIR/fail"
  issues o/a "7:Fix:status:ready"
  lc
  blocked
  [[ "$stderr" == *"inbox unreachable"* ]]
}

@test "a missing thresholds file allows with a warning" {
  THR="$BATS_TEST_TMPDIR/none.json"
  issues o/a "7:Fix:status:ready"
  lc
  allowed_with_msg
  [[ "$stderr" == *"thresholds file missing or malformed"* ]]
}

@test "malformed thresholds, and thresholds without a core key, allow with a warning" {
  issues o/a "7:Fix:status:ready"
  echo 'not json' > "$THR"
  lc; allowed_with_msg
  echo '{"wip-limit": 2}' > "$THR"
  lc; allowed_with_msg
  [[ "$stderr" == *"thresholds file missing or malformed"* ]]
}

@test "malformed hook input allows with a warning; empty input too" {
  run --separate-stderr bash -c 'printf "not json" | "$1" --hook --thresholds "$2"' _ "$LC" "$THR"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"bad hook input"* ]]
  not blocked
  run --separate-stderr bash -c '"$1" --hook --thresholds "$2" < /dev/null' _ "$LC" "$THR"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"bad hook input"* ]]
}

@test "no session id in the input allows with a warning" {
  issues o/a "7:Fix:status:ready"
  run --separate-stderr bash -c 'jq -cn --arg c "$1" "{cwd: \$c}" | "$2" --hook --thresholds "$3"' _ "$PROJ" "$LC" "$THR"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no session_id"* ]]
}

@test "a malformed project config allows with a warning" {
  echo 'oops' > "$PROJ/.alfred/config.json"
  lc
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"config malformed"* ]]
}

@test "every source failing allows and keeps the stored state" {
  issues o/a "7:Fix:status:ready"
  lc; blocked
  touch "$GH_STUB_DIR/fail-o__a" "$STUB_DIR/fail"
  at 5; lc true
  allowed_with_msg
  [[ "$stderr" == *"all sources failed"* ]]
  [ -f "$STATEDIR/s1.json" ]
}

@test "some sources failed and a fresh state exists: allowed with a warning" {
  issues o/a "7:Fix:status:ready"
  lc; blocked
  touch "$GH_STUB_DIR/fail-o__a"
  at 5; lc false
  allowed_with_msg
  [[ "$stderr" == *"some sources failed"* ]]
}

@test "a block, a fail-open stop, then a stop inside the chain: allowed" {
  issues o/a "7:Fix:status:ready"
  lc; blocked
  touch "$GH_STUB_DIR/fail-o__a" "$STUB_DIR/fail"
  at 5; lc true; allowed_with_msg
  rm "$GH_STUB_DIR/fail-o__a" "$STUB_DIR/fail"
  at 6; lc true
  allowed_with_msg
}

@test "a block, more than the chase interval, then a stop inside the chain: allowed" {
  issues o/a "7:Fix:status:ready"
  lc; blocked
  at 700; lc true
  allowed_with_msg
}

@test "a corrupt state file counts as no state" {
  issues o/a "7:Fix:status:ready"
  mkdir -p "$STATEDIR"; echo 'garbage' > "$STATEDIR/s1.json"
  lc
  blocked
}

@test "missing binaries: allowed with a warning (stripped PATH)" {
  bin="$BATS_TEST_TMPDIR/stripped"
  mkdir -p "$bin"
  for t in bash cat date mkdir mv rm mktemp readlink dirname sort tr head sed grep find ls git curl jq gh timeout; do
    p=$(command -v "$t") && ln -sf "$p" "$bin/$t"
  done
  issues o/a "7:Fix:status:ready"
  for missing in jq gh timeout; do
    rm -f "$bin/$missing"
    run --separate-stderr env PATH="$bin" bash -c 'printf "%s" "$1" | "$2" --hook --thresholds "$3"' _ "$(hook_json)" "$LC" "$THR"
    [ "$status" -eq 0 ] || { echo "$missing: exit $status"; return 1; }
    [[ "$stderr" == *"missing binary: $missing"* ]] || { echo "$missing: $stderr"; return 1; }
    [[ "$output" != *'"block"'* ]]
    ln -sf "$(command -v "$missing")" "$bin/$missing"
  done
}

# --- silence (AC 13) and the switches ----------------------------------------------------

@test "no .alfred/config.json: no output at all" {
  rm "$PROJ/.alfred/config.json"
  issues o/a "7:Fix:status:ready"
  lc
  silent
  [ -z "$stderr" ]
}

@test "a config without agent_id, a hub id under the plugin entry, a worker role: silent" {
  issues o/a "7:Fix:status:ready"
  echo '{"repos":["o/a"]}' > "$PROJ/.alfred/config.json"; lc; silent
  echo '{"agent_id":"hub","repos":["o/a"]}' > "$PROJ/.alfred/config.json"; lc; silent
  echo '{"agent_id":"alfred","repos":["o/a"]}' > "$PROJ/.alfred/config.json"; lc; silent
  echo '{"agent_id":"lead-x","repos":["o/a"]}' > "$PROJ/.alfred/config.json"
  ALFRED_ROLE=worker lc; silent
}

@test "kill switches: ALFRED_LOOP_CHECK=0 and loop-check-enabled false are silent" {
  issues o/a "7:Fix:status:ready"
  ALFRED_LOOP_CHECK=0 lc; silent
  jq '.["loop-check-enabled"] = false' "$THR" > "$THR.n" && mv "$THR.n" "$THR"
  lc; silent
}

# --- the owner is present (O1) -------------------------------------------------------------

# note <prompt> [entrypoint] — run UserPromptSubmit note-turn.
note() {
  CLAUDE_CODE_ENTRYPOINT="${2-cli}" "$LC" note-turn < <(jq -cn --arg c "$PROJ" --arg p "$1" '{session_id: "s1", cwd: $c, prompt: $p}')
}

@test "owner turn: interactive session, plain prompt: a soft note, never a block" {
  issues o/a "7:Fix:status:ready"
  note "please look at the board"
  [ "$(state_of .last_turn)" = "owner" ]
  lc
  allowed_with_msg
  [[ "$(jq -r .systemMessage <<< "$output")" == *"o/a#7"* ]]
}

@test "machine turns block: known prefixes, a non-interactive session, and no note at all" {
  issues o/a "7:Fix:status:ready"
  for prefix in "<task-notification>x" "<cross-session-message from=hub>" "[substrate wake] new mail" "<scheduled-task>"; do
    rm -rf "$STATEDIR"
    note "$prefix"
    [ "$(state_of .last_turn)" = "machine" ] || { echo "$prefix"; return 1; }
    lc; blocked
  done
  rm -rf "$STATEDIR"; note "hello" sdk-cli
  [ "$(state_of .last_turn)" = "machine" ]
  rm -rf "$STATEDIR"
  lc; blocked
}

@test "a block keeps the last_turn note; note-turn writes nothing outside an Alfred project or for a worker" {
  issues o/a "7:Fix:status:ready"
  note "machine" sdk-cli
  lc; blocked
  [ "$(state_of .last_turn)" = "machine" ]
  rm -rf "$STATEDIR"
  rm "$PROJ/.alfred/config.json"; note "hi"
  [ ! -e "$STATEDIR/s1.json" ]
  echo '{"agent_id":"lead-x"}' > "$PROJ/.alfred/config.json"
  ALFRED_ROLE=worker note "hi"
  [ ! -e "$STATEDIR/s1.json" ]
}

@test "note-turn exits 0 on garbage input" {
  run bash -c 'printf "garbage" | "$1" note-turn' _ "$LC"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- standalone use by the hub and Alfred (AC 15) -----------------------------------------------

@test "run directly as hub with a fixture config: prints items, direct_unread and warnings" {
  hubcfg="$BATS_TEST_TMPDIR/hub.json"
  echo '{"agent_id":"hub","repos":["o/a"]}' > "$hubcfg"
  issues o/a "7:Fix:status:ready" "8:Parked:status:ready,status:waiting-on-owner"
  inbox direct:m1 topic:t1
  run "$LC" --level hub --config "$hubcfg" --thresholds "$THR"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.items | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.items[0].number' <<< "$output")" -eq 7 ]
  [ "$(jq -r .direct_unread <<< "$output")" -eq 1 ]
  [ "$(jq -r '.warnings | type' <<< "$output")" = "array" ]
}

@test "run as hub with --hook, its own thresholds and config: blocks like a lead" {
  hubcfg="$BATS_TEST_TMPDIR/hub.json"
  echo '{"agent_id":"hub","repos":["o/a"]}' > "$hubcfg"
  mythr="$BATS_TEST_TMPDIR/hub-thr.json"
  jq -n '{"waiting-label":"action:owner","workable-states":["ready"],"ready-state":"ready","wip-limit":3}' > "$mythr"
  issues o/a "7:Fix:ready" "8:Parked:ready,action:owner"
  run --separate-stderr bash -c 'printf "%s" "$1" | "$2" --level hub --config "$3" --thresholds "$4" --hook' _ "$(hook_json)" "$LC" "$hubcfg" "$mythr"
  blocked
  reason=$(jq -r .reason <<< "$output")
  [[ "$reason" == *"o/a#7"* && "$reason" != *"o/a#8"* && "$reason" == *"action:owner"* ]]
  [ -e "$STATEDIR/s1.json" ]
}

@test "usage errors exit 2 outside hook mode and 0 in hook mode" {
  run "$LC" --bogus
  [ "$status" -eq 2 ]
  run "$LC" --level
  [ "$status" -eq 2 ]
  run bash -c '"$1" --hook --bogus < /dev/null' _ "$LC"
  [ "$status" -eq 0 ]
  run "$LC" --level hub --config "$BATS_TEST_TMPDIR/none.json"
  [ "$status" -eq 2 ]
}

# --- repos ----------------------------------------------------------------------------------------

@test "repos: items from two repos count together and both are asked" {
  echo '{"agent_id":"lead-x","repos":["o/a","o/b"]}' > "$PROJ/.alfred/config.json"
  issues o/a "1:In a:status:in-progress"
  issues o/b "2:In b:status:in-progress"
  lc
  blocked
  reason=$(jq -r .reason <<< "$output")
  [[ "$reason" == *"o/a#1"* && "$reason" == *"o/b#2"* ]]
  grep -q -- '-R o/a' "$GH_STUB_DIR/calls.log"
  grep -q -- '-R o/b' "$GH_STUB_DIR/calls.log"
  grep -q -- '--limit 500' "$GH_STUB_DIR/calls.log"
}

@test "repos: wip-limit counts across repos together" {
  echo '{"agent_id":"lead-x","repos":["o/a","o/b"]}' > "$PROJ/.alfred/config.json"
  issues o/a "1:In a:status:in-progress" "3:Ready a:status:ready"
  issues o/b "2:In b:status:in-progress" "4:Ready b:status:ready"
  lc
  reason=$(jq -r .reason <<< "$output")
  [[ "$reason" == *"o/a#1"* && "$reason" == *"o/b#2"* && "$reason" != *"#3"* && "$reason" != *"#4"* ]]
}

@test "repos: one repo failing drops only that repo, with a warning" {
  echo '{"agent_id":"lead-x","repos":["o/a","o/b"]}' > "$PROJ/.alfred/config.json"
  issues o/b "2:In b:status:ready"
  touch "$GH_STUB_DIR/fail-o__a"
  lc
  blocked
  [[ "$stderr" == *"o/a: gh failed"* ]]
}

@test "repos: without a repos key the origin remote is used (https and ssh forms)" {
  echo '{"agent_id":"lead-x"}' > "$PROJ/.alfred/config.json"
  git -C "$PROJ" init -q .
  issues o/x "5:From origin:status:ready"
  git -C "$PROJ" remote add origin https://github.com/o/x.git
  lc; blocked
  git -C "$PROJ" remote set-url origin git@github.com:o/x.git
  rm -rf "$STATEDIR"; lc; blocked
  grep -q -- '-R o/x' "$GH_STUB_DIR/calls.log"
}

@test "repos: neither a repos key nor a remote: a warning, and the inbox still counts" {
  echo '{"agent_id":"lead-x"}' > "$PROJ/.alfred/config.json"
  lc
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no repos to check"* ]]
  not blocked
  inbox direct:m1
  lc; blocked
}

@test "a repo with 500 open items warns that later ones are not seen" {
  arr=$(jq -cn '[range(1;501) | {number: ., title: "t", url: "u", labels: [{name: "bug"}]}]')
  echo "$arr" > "$GH_STUB_DIR/o__a.json"
  lc
  [[ "$stderr" == *"500 open items"* ]]
}

# --- inbox (AC 17) ------------------------------------------------------------------------------------

@test "one unread direct message blocks with 'read and handle the inbox first'; once read, allowed" {
  issues o/a
  inbox direct:m1
  lc
  blocked
  [[ "$(jq -r .reason <<< "$output")" == *"read and handle the inbox first"* ]]
  inbox
  at 5; lc true
  [ "$status" -eq 0 ]
  not blocked
  [ ! -e "$STATEDIR/s1.json" ]
}

@test "an unread topic post alone is allowed" {
  issues o/a
  inbox topic:t1
  lc
  silent
}

@test "a direct message among topic posts blocks" {
  issues o/a
  inbox topic:t1 topic:t2 direct:m1
  lc
  blocked
  [[ "$(jq -r .reason <<< "$output")" == *"1 unread direct message"* ]]
}

@test "more unread than one page and no direct message on it: a partial-scan warning" {
  issues o/a
  args=(); for i in $(seq 1 101); do args+=("topic:t$i"); done
  inbox "${args[@]}"
  lc
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"inbox scan partial"* ]]
  not blocked
}

@test "alfred-wake unread --direct counts direct messages only" {
  inbox direct:m1 topic:t1 direct:m2
  run "$ROOT/bin/alfred-wake" unread --direct
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  run "$ROOT/bin/alfred-wake" unread
  [ "$output" = "3" ]
  touch "$STUB_DIR/fail"
  run "$ROOT/bin/alfred-wake" unread --direct
  [ "$status" -eq 1 ]
  [ "$output" = "?" ]
}

# --- the combined Stop decision (AC 14) -------------------------------------------------------------------

# bridge up|down — what `alfred-wake status` answers for bridge-check.sh.
bridge() {
  printf '#!/bin/sh\nexit %s\n' "$([ "$1" = up ] && echo 0 || echo 1)" > "$BATS_TEST_TMPDIR/wake-status"
  chmod +x "$BATS_TEST_TMPDIR/wake-status"
  export ALFRED_WAKE_STOP_CHECK=1 ALFRED_WAKE_CHECK_BIN="$BATS_TEST_TMPDIR/wake-status"
}

# stop [active] — run hooks/stop.sh of the private plugin copy.
stop() {
  run --separate-stderr bash -c 'printf "%s" "$1" | "$2"' _ "$(hook_json "$@")" "$STOPP"
}

one_object() { [ "$(jq -s length <<< "$output")" -le 1 ]; }

@test "stop: bridge down and an actionable item, first stop: one block naming both" {
  bridge down; issues o/a "7:Fix:status:ready"
  stop
  [ "$status" -eq 0 ]; one_object; blocked
  reason=$(jq -r .reason <<< "$output")
  [[ "$reason" == *"alfred-wake bridge is not running"* && "$reason" == *"o/a#7"* ]]
}

@test "stop: bridge down, no items, first stop: a bridge block only" {
  bridge down; issues o/a
  stop
  blocked
  reason=$(jq -r .reason <<< "$output")
  [[ "$reason" == *"alfred-wake bridge"* && "$reason" != *"actionable"* ]]
}

@test "stop: bridge down inside the chain, items changed since the block: block (items) plus the bridge warning" {
  bridge up; issues o/a "7:Fix:status:ready"
  stop; blocked
  bridge down; issues o/a "7:Fix:status:ready" "8:More:status:ready"
  at 5; stop true
  [ "$status" -eq 0 ]; one_object; blocked
  [[ "$(jq -r .reason <<< "$output")" == *"o/a#8"* ]]
  [[ "$(jq -r .systemMessage <<< "$output")" == *"bridge is still not running"* ]]
}

@test "stop: inside the chain with no stored state: allowed with a warning, bridge up or down" {
  issues o/a "7:Fix:status:ready"
  bridge up; stop true
  [ "$status" -eq 0 ]; ! blocked
  [[ "$(jq -r .systemMessage <<< "$output")" == *"no stored state"* ]]
  bridge down; stop true
  not blocked
  msg=$(jq -r .systemMessage <<< "$output")
  [[ "$msg" == *"no stored state"* && "$msg" == *"bridge is still not running"* ]]
}

@test "stop: bridge up and a new item: a block for the items only" {
  bridge up; issues o/a "7:Fix:status:ready"
  stop; one_object; blocked
  [[ "$(jq -r .reason <<< "$output")" != *"alfred-wake bridge"* ]]
}

@test "stop: bridge up, same signature: allowed with friction" {
  bridge up; issues o/a "7:Fix:status:ready"
  stop; blocked
  at 5; stop false
  not blocked
  one_object
  [ "$(frictions | wc -l)" -eq 1 ]
}

@test "stop: bridge up, no items: silent" {
  bridge up; issues o/a
  stop
  silent
}

@test "stop: bridge down inside the chain, same signature: allowed with both warnings" {
  bridge up; issues o/a "7:Fix:status:ready"
  stop; blocked
  bridge down; at 5; stop true
  not blocked
  msg=$(jq -r .systemMessage <<< "$output")
  [[ "$msg" == *"bridge is still not running"* && "$msg" == *"no progress"* ]]
}

@test "stop: bridge down inside the chain, no items: allowed with the bridge warning" {
  bridge down; issues o/a
  stop true
  not blocked
  [[ "$(jq -r .systemMessage <<< "$output")" == *"bridge is still not running"* ]]
}

@test "stop: three consecutive stops with no progress end in an allowed stop, not a loop" {
  bridge down; issues o/a "7:Fix:status:ready"
  stop; blocked
  at 1; stop true; ! blocked
  at 2; stop true; ! blocked
}

@test "stop: both stdin copies are the same bytes, and bridge-check sees stop_hook_active through stop.sh" {
  printf '#!/bin/sh\ncat > "%s/in-bridge"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/b.sh"
  printf '#!/bin/sh\ncat > "%s/in-loop"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/l.sh"
  chmod +x "$BATS_TEST_TMPDIR/b.sh" "$BATS_TEST_TMPDIR/l.sh"
  ALFRED_STOP_BRIDGE_BIN="$BATS_TEST_TMPDIR/b.sh" ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/l.sh" stop true
  cmp "$BATS_TEST_TMPDIR/in-bridge" "$BATS_TEST_TMPDIR/in-loop"
  [ "$(jq -r .stop_hook_active "$BATS_TEST_TMPDIR/in-bridge")" = "true" ]
}

@test "stop: TERM mid-loop kills the children and still prints the bridge block" {
  printf '#!/bin/sh\necho {\\"decision\\":\\"block\\",\\"reason\\":\\"bridge down\\"}\n' > "$BATS_TEST_TMPDIR/b.sh"
  printf '#!/bin/sh\nexec sleep 31.27\n' > "$BATS_TEST_TMPDIR/l.sh"
  chmod +x "$BATS_TEST_TMPDIR/b.sh" "$BATS_TEST_TMPDIR/l.sh"
  export ALFRED_STOP_BRIDGE_BIN="$BATS_TEST_TMPDIR/b.sh" ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/l.sh"
  set -m
  hook_json > "$BATS_TEST_TMPDIR/in.json"
  "$STOPP" < "$BATS_TEST_TMPDIR/in.json" > "$BATS_TEST_TMPDIR/out.txt" 2>/dev/null 3>&- &
  pid=$!
  sleep 1
  kill -TERM "$pid"
  wait "$pid"; rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .reason "$BATS_TEST_TMPDIR/out.txt")" = "bridge down" ]
  sleep 0.5
  not pgrep -f "sleep 31.27" >/dev/null
}

@test "stop: a hanging loop part is cut at its deadline: allowed with a warning" {
  printf '#!/bin/sh\nexec sleep 31.28\n' > "$BATS_TEST_TMPDIR/l.sh"; chmod +x "$BATS_TEST_TMPDIR/l.sh"
  ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/l.sh" ALFRED_STOP_LOOP_SECONDS=1 bridge up
  start=$SECONDS
  ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/l.sh" ALFRED_STOP_LOOP_SECONDS=1 stop
  [ $((SECONDS - start)) -lt 8 ]
  [ "$status" -eq 0 ]; ! blocked
  [[ "$(jq -r .systemMessage <<< "$output")" == *"loop part timed out"* ]]
  not pgrep -f "sleep 31.28" >/dev/null
}

@test "stop: garbage from a part is a warning, never raw output and never a block" {
  printf '#!/bin/sh\necho "this is not json"\n' > "$BATS_TEST_TMPDIR/g.sh"; chmod +x "$BATS_TEST_TMPDIR/g.sh"
  ALFRED_STOP_BRIDGE_BIN="$BATS_TEST_TMPDIR/g.sh" ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/g.sh" stop
  [ "$status" -eq 0 ]
  one_object
  not blocked
  msg=$(jq -r .systemMessage <<< "$output")
  [[ "$msg" == *"bridge part gave unusable output"* && "$msg" == *"loop part gave unusable output"* ]]
  [[ "$output" != *"this is not json"* ]]
}

@test "stop: a corrupt child script (syntax error) gives exit 0 and no block" {
  printf '#!/bin/bash\nif then fi (\n' > "$BATS_TEST_TMPDIR/c.sh"; chmod +x "$BATS_TEST_TMPDIR/c.sh"
  ALFRED_STOP_BRIDGE_BIN="$BATS_TEST_TMPDIR/c.sh" ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/c.sh" stop
  [ "$status" -eq 0 ]
  not blocked
}

@test "stop: a child that exits 2 or is missing does not block" {
  printf '#!/bin/sh\nexit 2\n' > "$BATS_TEST_TMPDIR/e.sh"; chmod +x "$BATS_TEST_TMPDIR/e.sh"
  ALFRED_STOP_BRIDGE_BIN="$BATS_TEST_TMPDIR/e.sh" ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/e.sh" stop
  [ "$status" -eq 0 ]; ! blocked
  ALFRED_STOP_BRIDGE_BIN="$BATS_TEST_TMPDIR/nope" ALFRED_STOP_LOOP_BIN="$BATS_TEST_TMPDIR/nope" stop
  [ "$status" -eq 0 ]; ! blocked
}

# --- wiring and the exit-code audit --------------------------------------------------------------------------

@test "hooks.json: Stop runs stop.sh (not bridge-check.sh directly), #131's entries stay, note-turn is on UserPromptSubmit" {
  h="$ROOT/hooks/hooks.json"
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$h")" = '"${CLAUDE_PLUGIN_ROOT}/hooks/stop.sh"' ]
  [ "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$h")" = "20" ]
  not grep -q 'Stop' <(jq -r '.hooks.Stop[].hooks[].command' "$h" | grep bridge-check)
  [ "$(jq -r '[.hooks.Stop[0].hooks[].command] | map(select(test("alfred-workitem"))) | length' "$h")" = "1" ]
  [ "$(jq -r '[.hooks.UserPromptSubmit[0].hooks[].command] | map(select(test("alfred-loop-check\" note-turn"))) | length' "$h")" = "1" ]
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$h")" = "Bash" ]
  [ -n "$(jq -r '.hooks.SubagentStop' "$h")" ]
}

@test "audit: hook-mode scripts hold no set -e/-u and no non-zero exit outside the cli-only lines" {
  for f in "$ROOT/hooks/stop.sh" "$ROOT/bin/alfred-loop-check"; do
    not grep -nE '^\s*set\s+-[a-z]*[eu]' "$f"
    bad=$(grep -nE '\bexit +[1-9]' "$f" | grep -v 'cli-only' || true)
    [ -z "$bad" ] || { echo "$f: $bad"; return 1; }
  done
}
