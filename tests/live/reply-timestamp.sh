#!/usr/bin/env bash
# Live check for CCW-180 slice A (not run by CI; `bats tests/` does not enter
# subdirectories): on the real harness, does every kind of turn get the
# Europe/Amsterdam time line in its context?
#
#   reply-timestamp.sh <branch-dir>                      the builder's run
#   reply-timestamp.sh --canary <ts.log> <transcript>    the lead's run (below)
#
# <branch-dir> is the checkout under test. Both modes read only; the default
# mode makes real `claude` calls (about 8 short turns, one run).
#
# One line per row:
#   wake=<name> origin=<real|synthetic-typed|stop-stub|canary> real-type=<proven|unproven>
#   ups-fired=<yes|no> source=<..> prompt-head=<first 40 chars, \n escaped>
#   hook-owner=<true|false|none> lib-owner=<true|false|none> emitted=<true|false|none>
#   line-from=<this-event|turn-prompt|stop-feedback|none> line-in-context=<yes|no>
#   reply-starts-with-line=<yes|no|no-text>
# A row is proven only from what the transcript and the logs hold; a timeout
# never counts as proof either way. reply-starts-with-line is reported, not gated.
#
# Exit codes, default run:
#   0  every row other than the cross-session one is proven and has a line in
#      its context. Prints cross-session=pending-canary: the typed
#      cross-session variants (origin=synthetic-typed real-type=unproven) prove
#      only that the hook emits for that text; the real type is the lead's
#      --canary run.
#   1  at least one row was exercised and definitively lacks a line in its
#      context (the hand-back case; takes precedence over 3).
#   2  usage.
#   3  the run cannot prove a row: a row was not exercised, the branch hooks did
#      not load (no `emitted` key in ts.log after the typed row), or a wait
#      timed out.
#
# Exit codes, --canary (run it on a session started with the branch plugin and
# ALFRED_REPLY_TS_LOG=<ts.log>, after it received one real message from another
# session):
#   0  proven: a transcript user entry starting "Another Claude session sent a
#      message:" exists, a ts.log line with an `emitted` key matches it within
#      5 s and has emitted:true, and a hook_additional_context attachment
#      (hookEvent UserPromptSubmit) holding the time line follows the entry.
#   1  the line is missing: the entry exists and the log is usable, but no log
#      line matches within 5 s, or the match has emitted:false, or no such
#      attachment follows the entry.
#   2  usage.
#   3  nothing to prove: no matching entry, or the log is unreadable or holds no
#      line with an `emitted` key.
# It prints only the first 40 characters of the entry.
#
# Recording (default run): `--settings $T/settings.json` adds two passive hooks
# beside the plugin's: UserPromptSubmit appends the raw event to ups-in.jsonl,
# Stop appends {stop_hook_active, last_assistant_message} to stop-in.jsonl. If
# those settings hooks do not merge with the plugin's (no ups-in record after the
# typed row), ups-fired falls back to the event's ts.log line (the script prints
# settings-hooks-merged=no and loses the raw prompt text).
#
# Isolation (the pattern of tests/live/owner-note.sh):
#   - everything lives in T=$(mktemp -d /tmp/ccw180-live-XXXXXX); the claude
#     sessions run from $T/work and $T/work2 (no .alfred/config.json, so the
#     loop and bridge checks are silent);
#   - a private tmux socket (-L ccw180-$$, TMUX unset); the lead's own tmux and
#     the default socket are never reached; sessions run one at a time with
#     kill-server between them; the folder-trust dialog is answered;
#   - the checks and the wake bridge are off or pointed into $T, ALFRED_ROLE,
#     CLAUDE_CODE_SESSION_ID and every AGENT_RUNS_* are unset, gh and curl are
#     the tests/stub copies; HOME stays real because the login is in ~/.claude;
#   - every wait is bounded to 120 s; cleanup stops the session by pid, kills
#     the tmux server of this run, and removes T and the session directories
#     Claude Code made for $T/work and $T/work2. The workitem hooks may write
#     session files under ~/.claude/alfred-workitem/; the run does not prevent
#     that.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
USAGE="usage: $0 <branch-dir> | $0 --canary <ts.log> <transcript>"
# The injected line, as a jq/ERE pattern.
LINE_RE='Time now _\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} CES?T\]_'
REPLY_RE='^_\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} CES?T\]_'
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }

# lib_owner <libdir> <source> <prompt> — true|false: what is_owner_turn says for
# an interactive entrypoint. Read-only; the lib is not changed.
lib_owner() {
  # shellcheck disable=SC1091
  if ( set +u; . "$1/owner-turn.sh" 2>/dev/null && is_owner_turn cli "$2" "$3" ); then echo true; else echo false; fi
}

# head40 <text> — the first 40 characters, newlines escaped.
head40() { jq -rn --arg t "$1" '$t[0:40] | gsub("\n"; "\\n")'; }

# ---------------------------------------------------------------------------
# --canary
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--canary" ]; then
  [ $# -eq 3 ] || { echo "$USAGE" >&2; exit 2; }
  LOG="$2"
  TR="$3"
  if [ ! -r "$LOG" ] || [ ! -r "$TR" ]; then echo "cannot read the log or the transcript" >&2; exit 3; fi
  entry=$(jq -c -s '
    [to_entries[] | select(.value.type == "user")
     | {i: .key, ts: .value.timestamp,
        text: (.value.message.content | if type == "string" then . else (map(.text? // "") | join("")) end)}
     | select(.text | startswith("Another Claude session sent a message:"))] | last // empty' "$TR" 2>/dev/null)
  [ -n "$entry" ] || { echo "no 'Another Claude session sent a message:' entry in the transcript" >&2; exit 3; }
  if [ "$(jq -s 'map(select(type == "object" and has("emitted"))) | length' "$LOG" 2>/dev/null || echo 0)" -lt 1 ]; then
    echo "the log holds no line with an emitted key (not enabled, or the branch hook did not run)" >&2
    exit 3
  fi
  match=$(jq -c -s --argjson e "$entry" '
    def abs: if . < 0 then -. else . end;
    ($e.ts | sub("\\.[0-9]+"; "") | fromdateiso8601) as $et
    | [.[] | select(type == "object" and has("emitted") and .source != "stop")
       | . + {d: (((.ts | fromdateiso8601) - $et) | abs)}]
    | map(select(.d <= 5)) | sort_by(.d) | first // empty' "$LOG" 2>/dev/null)
  idx=$(jq -r '.i' <<< "$entry")
  text=$(jq -r '.text' <<< "$entry")
  attach=$(jq -s --argjson i "$idx" --arg re "$LINE_RE" '
    [to_entries[] | select(.key > $i) | .value
     | select(.attachment.type == "hook_additional_context" and .attachment.hookEvent == "UserPromptSubmit"
              and ((.attachment.content | tojson) | test($re)))] | length' "$TR" 2>/dev/null || echo 0)
  m_owner=none; m_emitted=none; m_source=none
  if [ -n "$match" ]; then
    m_owner=$(jq -r '.owner' <<< "$match"); m_emitted=$(jq -r '.emitted' <<< "$match"); m_source=$(jq -r '.source' <<< "$match")
  fi
  rc=0
  [ -n "$match" ] && [ "$m_emitted" = true ] && [ "${attach:-0}" -ge 1 ] || rc=1
  printf 'wake=cross-session origin=canary real-type=%s entry=%s source=%s owner=%s emitted=%s lib-owner=%s line-in-context=%s\n' \
    "$([ "$rc" -eq 0 ] && echo proven || echo unproven)" "$(head40 "$text")" "$m_source" "$m_owner" "$m_emitted" \
    "$(lib_owner "$HERE/../../lib" "" "$text")" "$([ "${attach:-0}" -ge 1 ] && echo yes || echo no)"
  exit "$rc"
fi

# ---------------------------------------------------------------------------
# default run
# ---------------------------------------------------------------------------
[ $# -eq 1 ] || { echo "$USAGE" >&2; exit 2; }
BRANCH=$(cd "$1" 2>/dev/null && pwd -P) || { echo "$USAGE" >&2; exit 2; }
for f in lib/reply-time.sh lib/owner-turn.sh hooks/reply-timestamp.sh hooks/stop.sh; do
  [ -e "$BRANCH/$f" ] || { echo "no $f in $BRANCH" >&2; exit 2; }
done
command -v claude >/dev/null 2>&1 || { echo "claude not found" >&2; exit 2; }
command -v tmux >/dev/null 2>&1 || { echo "tmux not found" >&2; exit 2; }

T=$(mktemp -d /tmp/ccw180-live-XXXXXX) || exit 2
case "$T" in /tmp/ccw180-live-??????) ;; *) echo "unexpected temp dir $T" >&2; exit 2 ;; esac

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SOCK="ccw180-$$"
UUID1=$(cat /proc/sys/kernel/random/uuid)
UUID2=$(cat /proc/sys/kernel/random/uuid)
CHILD=""

TM() { tmux -L "$SOCK" "$@"; }
mangle() { printf '%s' "$1" | tr / -; }

# stop_child — stop the claude started from this script, by pid.
stop_child() {
  if [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
    kill -TERM "$CHILD" 2>/dev/null || true
  fi
  CHILD=""
}

# shellcheck disable=SC2317  # runs from the traps below
cleanup() {
  trap '' EXIT TERM INT HUP
  stop_child
  TM kill-server 2>/dev/null || true
  rm -rf "$CFG/projects/$(mangle "$T/work")" "$CFG/projects/$(mangle "$T/work2")"
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' TERM INT HUP

mkdir "$T/work" "$T/work2" "$T/bin" "$T/gh" "$T/stub" "$T/wake" || exit 2
: > "$T/plugins.json"
: > "$T/ups-in.jsonl"
: > "$T/stop-in.jsonl"
: > "$T/ts.log"
printf '{"messages":[],"total_unread":0}' > "$T/stub/inbox.json"
ln -s "$BRANCH/tests/stub/gh" "$T/bin/gh"
ln -s "$BRANCH/tests/stub/curl" "$T/bin/curl"

# Passive recorders beside the plugin's hooks, and the permissions the
# background-task rows need.
jq -n --arg u "jq -c . >> $T/ups-in.jsonl" --arg s "jq -c '{stop_hook_active, last_assistant_message}' >> $T/stop-in.jsonl" '{
  permissions: {allow: ["Bash(sleep *)", "Bash(echo *)", "Bash(python3 *)"]},
  hooks: {
    UserPromptSubmit: [{hooks: [{type: "command", command: $u}]}],
    Stop: [{hooks: [{type: "command", command: $s}]}]}}' > "$T/settings.json"

# The Stop-stub of the continuation row: blocks once, when stop_hook_active is false.
cat > "$T/stub-bridge.sh" <<EOF
#!/usr/bin/env bash
in=\$(cat)
if [ "\$(jq -r '.stop_hook_active // false' <<< "\$in")" = false ]; then
  touch "$T/stub-bridge.blocked"
  printf '{"decision":"block","reason":"Live check: reply with the word ok."}\n'
fi
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/stub-loop.sh"
chmod +x "$T/stub-bridge.sh" "$T/stub-loop.sh"

for v in $(compgen -e | grep '^AGENT_RUNS_'); do unset "$v"; done
unset ALFRED_ROLE ALFRED_LOOP_CHECK CLAUDE_CODE_SESSION_ID TMUX
unset CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN
export ALFRED_SESSION_CHECK=0 ALFRED_SESSION_NUDGE=0 ALFRED_WAKE_STOP_CHECK=0
export ALFRED_WAKE_STATE_DIR="$T/wake" ALFRED_WAKE_NO_UPGRADE=1 ALFRED_WAKE_BUZZ=off
export ALFRED_WAKE_PLUGINS_JSON="$T/plugins.json"
export CLAUDE_CODE_ENTRYPOINT=cli
export ALFRED_REPLY_TS_LOG="$T/ts.log"
export PATH="$T/bin:$PATH"
export GH_STUB_DIR="$T/gh" STUB_DIR="$T/stub"
export AGENT_MESSAGING_URL=http://stub.invalid/mcp/ AGENT_MESSAGING_TOKEN=test-token AGENT_ID=live-check

TR=""
LIBDIR="$BRANCH/lib"
RC_FAIL=0
RC_NOTEX=0
UPS_SRC=upsfile

lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# tm_start <dir> <uuid> [env VAR=value ...] — an interactive claude in a new tmux
# session of the private socket; answer the folder-trust dialog when it shows.
tm_start() {
  local dir="$1" uuid="$2" envs="${3:-}" i=0 pane
  TR="$CFG/projects/$(mangle "$dir")/$uuid.jsonl"
  TM -f /dev/null new-session -d -s live -x 200 -y 50 -c "$dir" \
    "env $envs claude --session-id $uuid --plugin-dir $BRANCH --settings $T/settings.json"
  CHILD=$(TM display-message -p -t live '#{pane_pid}')
  while [ "$i" -lt 120 ]; do
    pane=$(TM capture-pane -p -t live 2>/dev/null)
    if grep -qiE 'Do you trust the files in this folder|Yes, I trust this folder' <<< "$pane"; then
      # The cursor may sit on "No, exit": move to "Yes" unless it is there already.
      grep -qE '^[[:space:]]*(>|❯)[[:space:]]*(1\. )?Yes' <<< "$pane" || { TM send-keys -t live Down; sleep 1; }
      TM send-keys -t live Enter
      sleep 2
    elif grep -q 'Claude Code v' <<< "$pane" && grep -qE '^[[:space:]]*(>|❯)' <<< "$pane"; then
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  sleep 3
}
tm_stop() { stop_child; TM kill-server 2>/dev/null || true; sleep 1; }

# send <text> — type a single-line prompt and submit it.
send() {
  TM send-keys -t live -l "$1"
  sleep 1
  TM send-keys -t live Enter
}

# wait_stops <count> — until stop-in.jsonl holds more than <count> lines; bounded
# to 120 s. Returns 1 on a timeout.
wait_stops() {
  local i=0
  while [ "$i" -lt 120 ]; do
    [ "$(lines "$T/stop-in.jsonl")" -gt "$1" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# snap — the line counts before a trigger.
snap() {
  M_TR=$(lines "$TR"); M_UPS=$(lines "$T/ups-in.jsonl"); M_TS=$(lines "$T/ts.log"); M_STOP=$(lines "$T/stop-in.jsonl")
}

# ctx_count <file> — time-line attachments of UserPromptSubmit in a transcript window.
ctx_count() {
  jq -s --arg re "$LINE_RE" '[.[] | select(.attachment.type == "hook_additional_context" and .attachment.hookEvent == "UserPromptSubmit"
    and ((.attachment.content | tojson) | test($re)))] | length' "$1" 2>/dev/null || echo 0
}

# evaluate <name> <origin> <kind: typed|idle|mid|stop> — compute and print one row
# from the window that starts at the snap. Sets ROW (proven|fail|notex).
evaluate() {
  local name="$1" origin="$2" kind="$3" win="$T/win.jsonl" skip=0
  local n_ctx n_target rec tsl src prompt hown emit from line reply notex=no
  case "$kind" in mid|stop) skip=1 ;; esac
  sed -n "$((M_TR + 1)),\$p" "$TR" 2>/dev/null > "$win"
  tail -n +"$((M_UPS + 1))" "$T/ups-in.jsonl" 2>/dev/null > "$T/wups.jsonl"
  tail -n +"$((M_TS + 1))" "$T/ts.log" 2>/dev/null | jq -c 'select(type == "object" and has("emitted") and .source != "stop")' 2>/dev/null > "$T/wts.jsonl"

  # ups-fired, and the event's record
  rec=""
  if [ "$UPS_SRC" = upsfile ]; then
    n_target=$(( $(lines "$T/wups.jsonl") - skip ))
    rec=$(jq -c -s --argjson k "$skip" '.[$k] // empty' "$T/wups.jsonl" 2>/dev/null)
  else
    n_target=$(( $(lines "$T/wts.jsonl") - skip ))
  fi
  [ "$n_target" -ge 1 ] || n_target=0
  tsl=$(jq -c -s --argjson k "$skip" '.[$k] // empty' "$T/wts.jsonl" 2>/dev/null)
  src=none; prompt=""
  if [ -n "$rec" ]; then src=$(jq -r '.source // ""' <<< "$rec"); prompt=$(jq -r '.prompt // ""' <<< "$rec"); fi
  [ -n "$rec" ] || { [ -n "$tsl" ] && src=$(jq -r '.source // ""' <<< "$tsl"); }
  [ "$kind" = stop ] && tsl=$(tail -n +"$((M_TS + 1))" "$T/ts.log" 2>/dev/null | jq -c 'select(.source == "stop")' 2>/dev/null | head -1)
  hown=none; emit=none
  if [ -n "$tsl" ]; then
    hown=$(jq -r '.owner | if . == null then "none" else tostring end' <<< "$tsl")
    emit=$(jq -r '.emitted | tostring' <<< "$tsl")
  fi

  # the line in the context
  from=none
  n_ctx=$(ctx_count "$win")
  case "$kind" in
    typed) [ "$n_ctx" -ge 1 ] && from=this-event ;;
    idle)
      if jq -e -s 'any(.[]; .type == "user" and ((.message.content | if type == "string" then . else (map(.text? // "") | join("")) end) | startswith("<task-notification>")))' "$win" >/dev/null 2>&1; then
        [ "$n_ctx" -ge 1 ] && from=this-event
      else notex=yes; fi ;;
    mid)
      if jq -e -s 'any(.[]; .attachment.type == "queued_command" and .attachment.commandMode == "task-notification" and ((.attachment.prompt // "") | startswith("<task-notification>")))' "$win" >/dev/null 2>&1; then
        if [ "$n_target" -ge 1 ] && [ "$n_ctx" -ge 2 ]; then from=this-event
        elif [ "$n_ctx" -ge 1 ]; then from=turn-prompt; fi
      else notex=yes; fi ;;
    stop)
      if [ ! -e "$T/stub-bridge.blocked" ]; then notex=yes
      elif jq -e -s --arg re "$LINE_RE" 'any(.[]; .attachment.type == "hook_blocking_error" and ((.attachment.blockingError.blockingError // "") | tostring | test($re)))' "$win" >/dev/null 2>&1; then
        from=stop-feedback
      fi ;;
  esac
  line=no; [ "$from" != none ] && line=yes

  # the reply
  reply=no-text
  local last
  last=$(tail -n +"$((M_STOP + 1))" "$T/stop-in.jsonl" 2>/dev/null | jq -rs 'last | .last_assistant_message // ""' 2>/dev/null)
  if [ -n "$last" ]; then
    if jq -en --arg t "$last" --arg re "$REPLY_RE" '$t | test($re)' >/dev/null 2>&1; then reply=yes; else reply=no; fi
  fi

  local ups=no real=unproven
  [ "$n_target" -ge 1 ] && ups=yes
  if [ "$notex" = yes ]; then ROW=notex
  elif [ "$line" = yes ]; then ROW=proven
  else ROW=fail; fi
  [ "$ROW" = proven ] && [ "$origin" != synthetic-typed ] && real=proven
  if [ "$kind" = stop ] && [ "$notex" = yes ]; then ups=no; fi
  printf 'wake=%s origin=%s real-type=%s ups-fired=%s source=%s prompt-head=%s hook-owner=%s lib-owner=%s emitted=%s line-from=%s line-in-context=%s reply-starts-with-line=%s%s\n' \
    "$name" "$origin" "$real" "$ups" "$src" "$(head40 "$prompt")" "$hown" \
    "$(if [ -n "$rec" ]; then lib_owner "$LIBDIR" "$src" "$prompt"; else echo none; fi)" \
    "$emit" "$from" "$line" "$reply" "$([ "$notex" = yes ] && echo ' note=not-exercised')"
  case "$ROW" in fail) RC_FAIL=1 ;; notex) RC_NOTEX=1 ;; esac
  # A row that is not proven shows what its window held, so the finding can be
  # read without the (removed) transcript: entry type, attachment type, command
  # mode, time, and the first 50 characters of the text.
  if [ "$ROW" != proven ]; then
    jq -rc '"  window: " + ([.type, (.attachment.type // ""), (.attachment.commandMode // ""), (.timestamp // ""),
      ((.attachment.prompt // .attachment.content // .message.content // "") | tojson | .[0:50])] | join(" | "))' "$win" 2>/dev/null | head -40
  fi
}

# typed_row <name> <origin> <text> — type a prompt, wait for its Stop, print the row.
typed_row() {
  snap
  send "$3"
  if ! wait_stops "$M_STOP"; then
    echo "wake=$1: no Stop within 120 s" >&2
    RC_NOTEX=1
    return 1
  fi
  sleep 2
  evaluate "$1" "$2" typed
  sleep 4
}

# --- session 1 ------------------------------------------------------------------------

unset TMUX
tm_start "$T/work" "$UUID1"

typed_row typed real "reply with the word ok" || { tm_stop; exit 3; }
if [ "$(lines "$T/ts.log")" -lt 1 ] || ! jq -e -s 'any(.[]; type == "object" and has("emitted"))' "$T/ts.log" >/dev/null 2>&1; then
  echo "the branch hooks did not load: no emitted key in ts.log after the typed row (see $T)" >&2
  exit 3
fi
if [ "$(lines "$T/ups-in.jsonl")" -ge 1 ]; then
  echo "settings-hooks-merged=yes"
else
  echo "settings-hooks-merged=no (ups-fired falls back to the ts.log line)"
  UPS_SRC=tslog
fi

typed_row substrate-wake real "[substrate wake] live check: reply with the word ok"
typed_row cross-session-1 synthetic-typed '<cross-session-message from="live-check">ping</cross-session-message>'
typed_row cross-session-2 synthetic-typed 'Another Claude session sent a message: <cross-session-message from="live-check">ping</cross-session-message>'

# idle <task-notification>: end the turn, then wait for the notification to start a new one.
snap
send "Run the shell command: sleep 8; echo IDLE-MARK with the Bash tool, in the background (run_in_background true). Then reply with the word started and end your turn."
if wait_stops "$M_STOP"; then
  snap
  i=0
  while [ "$i" -lt 90 ]; do
    if tail -n +"$((M_TR + 1))" "$TR" 2>/dev/null | jq -e -s 'any(.[]; .type == "user" and ((.message.content | if type == "string" then . else (map(.text? // "") | join("")) end) | startswith("<task-notification>")))' >/dev/null 2>&1; then
      break
    fi
    sleep 2
    i=$((i + 2))
  done
  wait_stops "$M_STOP" || echo "wake=idle-task-notification: no Stop after the notification within 120 s" >&2
  sleep 2
  evaluate idle-task-notification real idle
else
  echo "wake=idle-task-notification: the starting turn gave no Stop within 120 s" >&2
  RC_NOTEX=1
fi
sleep 4

# mid-turn queued <task-notification>
snap
send "Start the shell command: sleep 5; echo MID-MARK with the Bash tool in the background (run_in_background true). Then run the shell command: python3 -c \"import time; time.sleep(25)\" with the Bash tool in the foreground (a standalone sleep is blocked by the harness). Then reply with the word done."
if wait_stops "$M_STOP"; then
  sleep 3
  evaluate mid-turn-task-notification real mid
else
  echo "wake=mid-turn-task-notification: no Stop within 120 s" >&2
  RC_NOTEX=1
fi
tm_stop

# --- session 2: the Stop-hook continuation ---------------------------------------------------

mkdir -p "$T/work2"
tm_start "$T/work2" "$UUID2" "ALFRED_STOP_BRIDGE_BIN=$T/stub-bridge.sh ALFRED_STOP_LOOP_BIN=$T/stub-loop.sh"
snap
send "say hi"
if wait_stops "$((M_STOP + 1))"; then
  sleep 3
  evaluate stop-continuation stop-stub stop
else
  if [ -e "$T/stub-bridge.blocked" ]; then
    echo "wake=stop-continuation: the stub blocked but no continuation Stop within 120 s" >&2
  else
    echo "wake=stop-continuation: the stub never blocked" >&2
  fi
  RC_NOTEX=1
fi
tm_stop

echo "cross-session=pending-canary"
if [ "$RC_FAIL" -eq 1 ]; then exit 1; fi
if [ "$RC_NOTEX" -eq 1 ]; then exit 3; fi
exit 0
