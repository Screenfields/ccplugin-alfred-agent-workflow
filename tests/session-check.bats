#!/usr/bin/env bats
# CCW-201: hooks/session-check.sh takes the wake watcher's status and start
# commands from the checkout's own .alfred/config.json (`watcher` object), and
# ignores ALFRED_WATCHER_STATUS_CMD / ALFRED_WATCHER_START_CMD. Black-box on the
# real hooks; stub bridges, stub alfred-wake, stub tmux; nothing touches the
# real home or state dir.

bats_require_minimum_version 1.5.0

HOOK="$BATS_TEST_DIRNAME/../hooks/session-check.sh"
DEFAULT_START='Bash(command: "alfred-wake wait", run_in_background: true)'

setup() {
  unset ALFRED_WATCHER_STATUS_CMD ALFRED_WATCHER_START_CMD
  T="$BATS_TEST_TMPDIR"
  KEYS="$T/keys"
  mkdir -p "$T/stub"
  for who in hub alfred; do
    cat > "$T/bridge-$who" <<STUB
#!/bin/bash
echo "bridge-$who \$*" >> "$T/log-$who"
case "\$1" in status) exit \$(cat "$T/rc-$who" 2>/dev/null || echo 1) ;; esac
exit 0
STUB
    chmod +x "$T/bridge-$who"
    echo 1 > "$T/rc-$who"
  done
  cat > "$T/wake" <<STUB
#!/bin/bash
echo "alfred-wake \$*" >> "$T/log-wake"
case "\$1" in
  unread) echo 0 ;;
  status) exit \$(cat "$T/rc-wake" 2>/dev/null || echo 1) ;;
esac
STUB
  chmod +x "$T/wake"
  echo 1 > "$T/rc-wake"
  cat > "$T/tmux" <<STUB
#!/bin/bash
case "\$1" in
  capture-pane) cat "$T/pane" 2>/dev/null; true ;;
  send-keys) shift; echo "\$*" >> "$KEYS" ;;
  display-message)
    case "\$*" in
      *session_attached*) echo 0 ;;
      *cursor_x*) echo "2 1" ;;
    esac ;;
esac
STUB
  chmod +x "$T/tmux"
  printf 'Claude Code\n❯ Try "write a test"\n' > "$T/pane"
}

# mkproj <dir> <agent_id> [watcher-json]: a checkout with its own config
mkproj() {
  mkdir -p "$1/.alfred"
  if [ -n "${3:-}" ]; then
    jq -n --arg a "$2" --argjson w "$3" '{agent_id:$a, watcher:$w}' > "$1/.alfred/config.json"
  else
    jq -n --arg a "$2" '{agent_id:$a}' > "$1/.alfred/config.json"
  fi
}
# wcfg <hub|alfred>: the watcher object for a stand-in bridge
wcfg() {
  jq -n --arg s "$T/bridge-$1 status" --arg r "$T/bridge-$1 run --until-wake" \
    '{status_cmd:$s, start_cmd:$r}'
}
hub_env() {
  export ALFRED_WATCHER_STATUS_CMD="$T/bridge-hub status"
  export ALFRED_WATCHER_START_CMD="$T/bridge-hub run --until-wake"
}
alfred_env() {
  export ALFRED_WATCHER_STATUS_CMD="$T/bridge-alfred status"
  export ALFRED_WATCHER_START_CMD="$T/bridge-alfred run --until-wake"
}
# run_hook <cwd> [source]: process working directory is neutral
run_hook() {
  cd "$T" || return 1
  printf '{"cwd":"%s","source":"%s"}' "$1" "${2:-startup}" \
    | ALFRED_WAKE_CHECK_BIN="$T/wake" ALFRED_TMUX_BIN="$T/tmux" \
      ALFRED_NUDGE_DELAY=0.2 ALFRED_NUDGE_TRIES=3 TMUX_PANE="%9" "$HOOK"
}
ctx_of() { printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext; }
one_object() { printf '%s' "$output" | jq -e 'type == "object"' >/dev/null; }
until_true() {
  local n="$1"; shift
  while ! "$@"; do
    n=$((n - 1)); [ "$n" -gt 0 ] || return 1
    sleep 0.1
  done
}
# past ALFRED_NUDGE_DELAY x ALFRED_NUDGE_TRIES (0.6 s), plus one second
settle() { sleep 1.7; }

@test "SC1: a session with an override gets its own bridge, with the hub's values set" {
  mkproj "$T/p" agent-zed "$(wcfg alfred)"
  hub_env
  echo 1 > "$T/rc-alfred"; echo 0 > "$T/rc-hub"
  run --separate-stderr run_hook "$T/p"
  [ "$status" -eq 0 ]
  one_object
  [[ "$(ctx_of)" == *"$T/bridge-alfred run --until-wake"* ]]
  [[ "$(ctx_of)" == *"agent-zed"* ]]
  [[ "$(ctx_of)" != *"bridge-hub"* ]]
  [ ! -s "$T/log-hub" ]
  until_true 30 test -s "$KEYS"
  settle
  grep -q -- "$T/bridge-alfred run --until-wake" "$KEYS"
  ! grep -q bridge-hub "$KEYS" || false
}

@test "SC2: a second agent gets its own bridge, with the other's values leaked the other way" {
  mkproj "$T/p" agent-yarn "$(wcfg hub)"
  alfred_env
  run --separate-stderr run_hook "$T/p"
  [ "$status" -eq 0 ]
  one_object
  [[ "$(ctx_of)" == *"$T/bridge-hub run --until-wake"* ]]
  [[ "$(ctx_of)" == *"agent-yarn"* ]]
  [[ "$(ctx_of)" != *"bridge-alfred"* ]]
  [ ! -s "$T/log-alfred" ]
}

@test "SC3: a lead without an override gets the defaults, with and without the hub's values" {
  mkproj "$T/p" agent-lead
  run --separate-stderr run_hook "$T/p"
  [ "$status" -eq 0 ]
  one_object
  [[ "$(ctx_of)" == *"$DEFAULT_START"* ]]
  grep -q '^alfred-wake status' "$T/log-wake"
  [ ! -s "$T/log-hub" ]
  : > "$T/log-wake"
  hub_env
  run --separate-stderr run_hook "$T/p"
  [ "$status" -eq 0 ]
  one_object
  [[ "$(ctx_of)" == *"$DEFAULT_START"* ]]
  grep -q '^alfred-wake status' "$T/log-wake"
  [ ! -s "$T/log-hub" ]
}

@test "SC4: liveness is the session's own, in both directions" {
  mkproj "$T/p" agent-zed "$(wcfg alfred)"
  hub_env
  echo 1 > "$T/rc-alfred"; echo 0 > "$T/rc-hub"
  run --separate-stderr run_hook "$T/p"
  [ "$status" -eq 0 ]
  [[ "$(ctx_of)" == *"NOT running"* ]]
  until_true 30 test -s "$KEYS"
  settle
  [ "$(grep -c 'substrate wake' "$KEYS")" -eq 1 ]
  rm -f "$KEYS"
  echo 0 > "$T/rc-alfred"; echo 1 > "$T/rc-hub"
  run --separate-stderr run_hook "$T/p"
  [ "$status" -eq 0 ]
  [[ "$(ctx_of)" == "Wake watcher: running."* ]]
  settle
  [ ! -s "$KEYS" ]
}

@test "SC5: two checkouts of one repository, different agent ids" {
  git -c user.name=t -c user.email=t@example.invalid init -q "$T/main"
  git -C "$T/main" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
  git -C "$T/main" worktree add -q "$T/wt" -b other
  mkproj "$T/main" agent-yarn "$(wcfg hub)"
  mkproj "$T/wt" agent-zed "$(wcfg alfred)"
  echo 1 > "$T/rc-hub"; echo 1 > "$T/rc-alfred"

  alfred_env
  run --separate-stderr run_hook "$T/main"
  [ "$status" -eq 0 ]
  [[ "$(ctx_of)" == *"$T/bridge-hub run --until-wake"* ]]
  [[ "$(ctx_of)" == *"agent-yarn"* ]]
  [[ "$(ctx_of)" != *"bridge-alfred"* ]]
  [[ "$(ctx_of)" != *"agent-zed"* ]]
  until_true 30 test -s "$KEYS"
  settle
  grep -q "bridge-hub run --until-wake" "$KEYS"
  ! grep -q bridge-alfred "$KEYS" || false
  [ ! -s "$T/log-alfred" ]

  rm -f "$KEYS"; : > "$T/log-hub"
  hub_env
  run --separate-stderr run_hook "$T/wt"
  [ "$status" -eq 0 ]
  [[ "$(ctx_of)" == *"$T/bridge-alfred run --until-wake"* ]]
  [[ "$(ctx_of)" == *"agent-zed"* ]]
  [[ "$(ctx_of)" != *"bridge-hub"* ]]
  [[ "$(ctx_of)" != *"agent-yarn"* ]]
  until_true 30 test -s "$KEYS"
  settle
  grep -q "bridge-alfred run --until-wake" "$KEYS"
  ! grep -q bridge-hub "$KEYS" || false
  [ ! -s "$T/log-hub" ]
}

@test "SC6: the bridge and agent are named when down; the quiet line is unchanged" {
  mkproj "$T/p" agent-zed "$(wcfg alfred)"
  echo 1 > "$T/rc-alfred"
  run --separate-stderr run_hook "$T/p" clear
  [ "$status" -eq 0 ]
  [[ "$(ctx_of)" == *"agent-zed"* ]]
  [[ "$(ctx_of)" == *"$T/bridge-alfred status"* ]]
  [[ "$(ctx_of)" == *"Checked: $T/bridge-alfred status (agent agent-zed)."* ]]
  echo 0 > "$T/rc-alfred"
  run --separate-stderr run_hook "$T/p" clear
  [ "$status" -eq 0 ]
  [ "$(ctx_of)" = "Wake watcher: running. Inbox: 0 unread. Nothing to do for this check; do not mention it." ]
}

@test "SC7: the old variables are ignored and said so, off the model's channel" {
  mkproj "$T/p" agent-lead
  hub_env
  run --separate-stderr run_hook "$T/p" clear
  [ "$status" -eq 0 ]
  one_object
  [[ "$(ctx_of)" == *"$DEFAULT_START"* ]]
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
  [[ "$stderr" == *ALFRED_WATCHER_STATUS_CMD* ]]
  [[ "$stderr" == *ALFRED_WATCHER_START_CMD* ]]
  [[ "$stderr" == *ignored* ]]
  [[ "$(ctx_of)" != *ignored* ]]
  unset ALFRED_WATCHER_STATUS_CMD ALFRED_WATCHER_START_CMD
  run --separate-stderr run_hook "$T/p" clear
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# broken_case <watcher-json> <failing-key>
broken_case() {
  mkproj "$T/p" agent-zed "$1"
  hub_env
  : > "$T/log-wake"
  run --separate-stderr run_hook "$T/p" clear
  [ "$status" -eq 0 ]
  one_object
  [[ "$(ctx_of)" == *"$DEFAULT_START"* ]]
  [[ "$(ctx_of)" != *"bridge-"* ]]
  grep -q '^alfred-wake status' "$T/log-wake"
  [ ! -s "$T/log-hub" ]
  [ ! -s "$T/log-alfred" ]
  printf '%s\n' "$stderr" | grep -q "not usable ($2:"
  [[ "$stderr" == *ignored* ]]
}

@test "SC8: a broken override falls back to the defaults, whole" {
  S="$T/bridge-alfred status" R="$T/bridge-alfred run --until-wake"
  broken_case "$(jq -n --arg r "$R" '{start_cmd:$r}')" status_cmd
  broken_case "$(jq -n --arg s "$S" '{status_cmd:$s}')" start_cmd
  broken_case "$(jq -n --arg r "$R" '{status_cmd:"", start_cmd:$r}')" status_cmd
  broken_case "$(jq -n --arg r "$R" '{status_cmd:"   ", start_cmd:$r}')" status_cmd
  broken_case "$(jq -n --arg s "$S" '{status_cmd:$s, start_cmd:"a\nb run"}')" start_cmd
  broken_case "$(jq -n --arg s "$S" '{status_cmd:$s, start_cmd:7}')" start_cmd
  broken_case '"watcher-string"' watcher
  broken_case '{}' status_cmd
  broken_case '{"status_cmd":"","start_cmd":""}' status_cmd
  # null counts as absent: the defaults and no stderr line
  unset ALFRED_WATCHER_STATUS_CMD ALFRED_WATCHER_START_CMD
  mkproj "$T/p" agent-zed null
  run --separate-stderr run_hook "$T/p" clear
  [ "$status" -eq 0 ]
  one_object
  [[ "$(ctx_of)" == *"$DEFAULT_START"* ]]
  [ -z "$stderr" ]
}

@test "SC8b: a malformed config or a top-level non-object exits 0 with empty stdout" {
  mkdir -p "$T/p/.alfred"
  echo '{not json' > "$T/p/.alfred/config.json"
  run --separate-stderr run_hook "$T/p"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo '["agent_id"]' > "$T/p/.alfred/config.json"
  run --separate-stderr run_hook "$T/p"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "SC9: the nudge types one prompt, once" {
  mkproj "$T/p" agent-zed "$(wcfg alfred)"
  hub_env
  run --separate-stderr run_hook "$T/p"
  [ "$status" -eq 0 ]
  until_true 30 test -s "$KEYS"
  settle
  [ "$(grep -c 'substrate wake' "$KEYS")" -eq 1 ]
  grep -q '^-t %9 Enter$' "$KEYS"
}

@test "SC10: the docs say what the code does" {
  cd "$BATS_TEST_DIRNAME/.."
  run grep -n ALFRED_WATCHER README.md hooks/session-check.sh
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ "$line" == *ignored* ]] || { echo "no 'ignored': $line"; false; }
  done <<< "$output"
  sec=$(awk '/^## /{p=($0 ~ /Watcher and inbox check at every session start/)} p' README.md)
  [[ "$sec" == *status_cmd* ]]
  [[ "$sec" == *start_cmd* ]]
  [[ "$sec" == *watcher* ]]
  [ -f docs/baseline/watcher-override.md ]
  grep -q status_cmd docs/baseline/watcher-override.md
  grep -q start_cmd docs/baseline/watcher-override.md
  grep -q 'same trust as settings.local.json' docs/baseline/watcher-override.md
}

@test "SC11: the version is 2.55.0" {
  [ "$(jq -r .version "$BATS_TEST_DIRNAME/../.claude-plugin/plugin.json")" = "2.55.0" ]
}
