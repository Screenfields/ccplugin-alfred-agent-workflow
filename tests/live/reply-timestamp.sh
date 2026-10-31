#!/usr/bin/env bash
# Live check for CCW-180 (idle gate; not run by CI, `bats tests/` does not enter
# subdirectories): on the real harness, does the hook inject the Europe/Amsterdam
# time line when the session was idle, and only then?
#
#   reply-timestamp.sh <branch-dir>                      the builder's run
#   reply-timestamp.sh --canary <ts.log> <transcript>    the lead's run (below)
#
# <branch-dir> is the checkout under test. The default mode makes real `claude`
# calls (about 14 short turns, one run); --canary reads only.
#
# Seeding: the gate reads $CFG/alfred-reply-ts/<session-uuid>.json (CFG is
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}). Before each row the script writes it:
#   idle   {"last_activity":<now-7200>,"open":false}   expect a line
#   fresh  {"last_activity":<now-60>,"open":false}     expect none
# so no row waits for the real 15 minutes. Cleanup removes both session files.
#
# One line per row:
#   wake=<name> variant=<idle|fresh|mid|stop> expect=<line|none|line-first-prompt-only>
#   origin=<real|synthetic-typed|stop-stub> real-type=<proven|unproven>
#   ups-fired=<yes|no> source=<..> prompt-head=<first 40 chars, \n escaped>
#   hook-owner=<true|false|none> lib-owner-on-stored-text=<true|false|none>
#   emitted=<true|false|none> gap=<seconds|null|none>
#   line-from=<this-event|turn-prompt|stop-feedback|none> line-in-context=<yes|no>
#   reply-starts-with-line=<yes|no|no-text>
# lib-owner-on-stored-text is is_owner_turn computed here on the stored prompt
# text, not the hook's own value (that is hook-owner).
# A row is proven only from what the transcript and the logs hold; a timeout
# never counts as proof either way.
#
# Gating: the exit code gates on HOOK FACTS only: UserPromptSubmit fired, the
# line is in the context or absent from it as the row expects, and the log's
# `emitted` agrees. reply-starts-with-line is REPORTED per row and never gated: it
# measures the model, and the lead's canary judges the reply text.
#
# Exit codes, default run:
#   0  every row is proven. Prints cross-session=pending-canary: the typed
#      cross-session variants (origin=synthetic-typed real-type=unproven) prove
#      only that the hook gates that text as any other; the real type is the
#      lead's --canary run.
#   1  at least one row was exercised and its hook facts contradict its
#      expectation (the hand-back case; takes precedence over 3). A prompt hook
#      that did not fire for an idle row counts here.
#      A UserPromptSubmit that fired for the Stop continuation counts here too
#      (it contradicts the coverage table), with a message on stderr.
#   2  usage.
#   3  the run cannot prove a row: a row was not exercised, the branch hooks did
#      not load (no `emitted` key in ts.log after the first row), or a wait
#      timed out.
#
# Rows: typed prompt, [substrate wake] and two synthetic <cross-session-message>
# variants, each idle and fresh; idle <task-notification> idle and fresh; a
# mid-turn queued <task-notification> (seeded idle for the turn's first prompt:
# the line comes from that prompt only, the queued arrival has emitted:false and
# no line); a Stop-hook continuation (no line in the block reason).
#
# Exit codes, --canary (run it on a session started with the branch plugin and
# ALFRED_REPLY_TS_LOG=<ts.log>, after it received one real message from another
# session). A consistency check: a real message in a fresh session legitimately
# gets no line, so the line is not required.
#   0  consistent: a transcript user entry starting "Another Claude session sent a
#      message:" exists, a ts.log line with an `emitted` key matches it within
#      5 s, and its `emitted` equals whether a hook_additional_context
#      attachment (hookEvent UserPromptSubmit) holding the time line follows the
#      entry.
#   1  inconsistent: the log says one thing and the context the other, or no log
#      line matches within 5 s.
#   2  usage.
#   3  nothing to prove: no matching entry, or the log is unreadable or holds no
#      line with an `emitted` key.
# It prints the first 40 characters of the entry, the gap, emitted, and whether
# the first reply starts with a time line (reported, not gated).
#
# Recording (default run): `--settings $T/settings.json` adds two passive hooks
# beside the plugin's: UserPromptSubmit appends the raw event to ups-in.jsonl,
# Stop appends {stop_hook_active, last_assistant_message} to stop-in.jsonl. If
# those settings hooks do not merge with the plugin's (no ups-in record after the
# first row), ups-fired falls back to the event's ts.log line (the script prints
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
#     the tmux server of this run, removes the two seeded state files and their
#     .tmp.*, and removes T and the session directories Claude Code made for
#     $T/work and $T/work2. The workitem hooks may write session files under
#     ~/.claude/alfred-workitem/; the run does not prevent that.
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
    | [.[] | select(type == "object" and has("emitted"))
       | . + {d: (((.ts | fromdateiso8601) - $et) | abs)}]
    | map(select(.d <= 5)) | sort_by(.d) | first // empty' "$LOG" 2>/dev/null)
  idx=$(jq -r '.i' <<< "$entry")
  text=$(jq -r '.text' <<< "$entry")
  # Both queries look only at the message's own turn: the entries after it up to
  # the next real user entry (a prompt; an attachment or a tool_result does not
  # end the turn). A line injected for a later prompt is not credited to it.
  # shellcheck disable=SC2016  # a jq program, not shell
  WIN='def isprompt: .value.type == "user" and (.value.message.content | if type == "string" then true else any(.[]?; .type != "tool_result") end);
    def turn($i): [to_entries[] | select(.key > $i)] as $a | ($a | map(isprompt) | index(true)) as $n | (if $n == null then $a else $a[:$n] end) | map(.value);'
  attach=$(jq -s --argjson i "$idx" --arg re "$LINE_RE" "$WIN"'
    [turn($i)[]
     | select(.attachment.type == "hook_additional_context" and .attachment.hookEvent == "UserPromptSubmit"
              and ((.attachment.content | tojson) | test($re)))] | length' "$TR" 2>/dev/null || echo 0)
  # The first assistant text of that turn (reported, not gated).
  first_reply=$(jq -r -s --argjson i "$idx" "$WIN"'
    [turn($i)[] | select(.type == "assistant")
     | (.message.content | if type == "string" then . else (map(.text? // "") | join("")) end)
     | select(length > 0)] | first // ""' "$TR" 2>/dev/null)
  reply=no-text
  if [ -n "$first_reply" ]; then
    if jq -en --arg t "$first_reply" --arg re "$REPLY_RE" '$t | test($re)' >/dev/null 2>&1; then reply=yes; else reply=no; fi
  fi
  m_owner=none; m_emitted=none; m_source=none; m_gap=none
  if [ -n "$match" ]; then
    m_owner=$(jq -r '.owner' <<< "$match"); m_emitted=$(jq -r '.emitted' <<< "$match"); m_source=$(jq -r '.source' <<< "$match")
    m_gap=$(jq -r '.gap | if . == null then "null" else tostring end' <<< "$match")
  fi
  in_ctx=no; [ "${attach:-0}" -ge 1 ] && in_ctx=yes
  rc=0
  [ -n "$match" ] || rc=1
  if [ -n "$match" ]; then
    { [ "$m_emitted" = true ] && [ "$in_ctx" = yes ]; } || { [ "$m_emitted" = false ] && [ "$in_ctx" = no ]; } || rc=1
  fi
  printf 'wake=cross-session origin=canary real-type=%s entry=%s source=%s hook-owner=%s emitted=%s gap=%s lib-owner-on-stored-text=%s line-in-context=%s reply-starts-with-line=%s\n' \
    "$([ "$rc" -eq 0 ] && echo proven || echo unproven)" "$(head40 "$text")" "$m_source" "$m_owner" "$m_emitted" "$m_gap" \
    "$(lib_owner "$HERE/../../lib" "" "$text")" "$in_ctx" "$reply"
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
RTS="$CFG/alfred-reply-ts"
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
  rm -f "$RTS/$UUID1.json" "$RTS/$UUID2.json" "$RTS/$UUID1.json.tmp."* "$RTS/$UUID2.json.tmp."*
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
# ALFRED_REPLY_TS_NOW is unset so the seeding here and the hook share the real clock.
unset ALFRED_ROLE ALFRED_LOOP_CHECK CLAUDE_CODE_SESSION_ID TMUX ALFRED_REPLY_TS_NOW
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

# seed <session-uuid> <idle|fresh> — write the gate's state file. Idle: last
# activity two hours ago. Fresh: a minute ago. Only the epochs and flags the gate
# reads; nothing else.
seed() {
  local now age
  now=$(date +%s)
  case "$2" in idle) age=7200 ;; *) age=60 ;; esac
  mkdir -p "$RTS" && jq -nc --argjson t "$((now - age))" '{last_activity: $t, open: false}' > "$RTS/$1.json"
}

# evaluate <name> <origin> <kind: typed|idle|mid|stop> <variant> <expect> — compute
# and print one row from the window that starts at the snap. Sets ROW
# (proven|fail|notex). The verdict uses hook facts only: the hook fired, the line
# is in the context or not, the log's `emitted` agrees. The reply is reported.
evaluate() {
  local name="$1" origin="$2" kind="$3" variant="$4" expect="$5" win="$T/win.jsonl" skip=0
  local n_ctx n_target rec tsl tsl0 src prompt hown emit emit0 gap from line reply notex=no
  case "$kind" in mid|stop) skip=1 ;; esac
  sed -n "$((M_TR + 1)),\$p" "$TR" 2>/dev/null > "$win"
  tail -n +"$((M_UPS + 1))" "$T/ups-in.jsonl" 2>/dev/null > "$T/wups.jsonl"
  tail -n +"$((M_TS + 1))" "$T/ts.log" 2>/dev/null | jq -c 'select(type == "object" and has("emitted"))' 2>/dev/null > "$T/wts.jsonl"

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
  tsl0=$(jq -c -s '.[0] // empty' "$T/wts.jsonl" 2>/dev/null)
  src=none; prompt=""
  if [ -n "$rec" ]; then src=$(jq -r '.source // ""' <<< "$rec"); prompt=$(jq -r '.prompt // ""' <<< "$rec"); fi
  [ -n "$rec" ] || { [ -n "$tsl" ] && src=$(jq -r '.source // ""' <<< "$tsl"); }
  hown=none; emit=none; emit0=none; gap=none
  if [ -n "$tsl" ]; then
    hown=$(jq -r '.owner | if . == null then "none" else tostring end' <<< "$tsl")
    emit=$(jq -r '.emitted | tostring' <<< "$tsl")
    gap=$(jq -r '.gap | if . == null then "null" else tostring end' <<< "$tsl")
  fi
  [ -n "$tsl0" ] && emit0=$(jq -r '.emitted | tostring' <<< "$tsl0")

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
        if [ "$n_ctx" -ge 2 ]; then from=this-event
        elif [ "$n_ctx" -ge 1 ]; then from=turn-prompt; fi
      else notex=yes; fi ;;
    stop)
      if [ ! -e "$T/stub-bridge.blocked" ]; then notex=yes
      elif jq -e -s --arg re "$LINE_RE" 'any(.[]; .attachment.type == "hook_blocking_error" and ((.attachment.blockingError.blockingError // "") | tostring | test($re)))' "$win" >/dev/null 2>&1; then
        from=stop-feedback
      fi ;;
  esac
  line=no; [ "$from" != none ] && line=yes

  # the reply (reported, not gated)
  reply=no-text
  local last
  last=$(tail -n +"$((M_STOP + 1))" "$T/stop-in.jsonl" 2>/dev/null | jq -rs 'last | .last_assistant_message // ""' 2>/dev/null)
  if [ -n "$last" ]; then
    if jq -en --arg t "$last" --arg re "$REPLY_RE" '$t | test($re)' >/dev/null 2>&1; then reply=yes; else reply=no; fi
  fi

  local ups=no real=unproven
  [ "$n_target" -ge 1 ] && ups=yes
  # The verdict, from hook facts.
  ROW=proven
  if [ "$notex" = yes ]; then ROW=notex
  else
    case "$kind:$expect" in
      typed:line|idle:line)
        { [ "$line" = yes ] && [ "$emit" = true ]; } || ROW=fail ;;
      typed:none|idle:none)
        if [ "$ups" = no ] || [ "$emit" = none ]; then ROW=notex
        elif [ "$line" = yes ] || [ "$emit" != false ]; then ROW=fail; fi ;;
      mid:*)
        if [ "$n_target" -lt 1 ]; then ROW=notex
        elif [ "$from" = turn-prompt ] && [ "$emit0" = true ] && [ "$emit" = false ]; then ROW=proven
        else ROW=fail; fi ;;
      stop:*)
        if [ "$from" = stop-feedback ]; then ROW=fail
        elif [ "$ups" = yes ]; then
          # A UserPromptSubmit for a Stop continuation contradicts the coverage
          # table (a continuation is not a prompt): a hook fact, so exit 1.
          echo "wake=$name: UserPromptSubmit fired for the Stop continuation; the coverage table says it does not (hand back to the lead)" >&2
          ROW=fail
        fi ;;
    esac
  fi
  [ "$ROW" = proven ] && [ "$origin" != synthetic-typed ] && real=proven
  if [ "$kind" = stop ] && [ "$notex" = yes ]; then ups=no; fi
  printf 'wake=%s variant=%s expect=%s origin=%s real-type=%s ups-fired=%s source=%s prompt-head=%s hook-owner=%s lib-owner-on-stored-text=%s emitted=%s gap=%s line-from=%s line-in-context=%s reply-starts-with-line=%s%s\n' \
    "$name" "$variant" "$expect" "$origin" "$real" "$ups" "$src" "$(head40 "$prompt")" "$hown" \
    "$(if [ -n "$rec" ]; then lib_owner "$LIBDIR" "$src" "$prompt"; else echo none; fi)" \
    "$emit" "$gap" "$from" "$line" "$reply" "$([ "$notex" = yes ] && echo ' note=not-exercised')"
  case "$ROW" in fail) RC_FAIL=1 ;; notex) RC_NOTEX=1 ;; esac
  # A row that is not proven shows what its window held, so the finding can be
  # read without the (removed) transcript: entry type, attachment type, command
  # mode, time, and the first 50 characters of the text.
  if [ "$ROW" != proven ]; then
    jq -rc '"  window: " + ([.type, (.attachment.type // ""), (.attachment.commandMode // ""), (.timestamp // ""),
      ((.attachment.prompt // .attachment.content // .message.content // "") | tojson | .[0:50])] | join(" | "))' "$win" 2>/dev/null | head -40
  fi
}

# row_expect <variant: idle|fresh> — the expectation the variant carries.
row_expect() { if [ "$1" = idle ]; then echo line; else echo none; fi; }

# typed_row <name> <origin> <text> <idle|fresh> — seed, type a prompt, wait for
# its Stop, print the row.
typed_row() {
  seed "$CUR" "$4"
  snap
  send "$3"
  if ! wait_stops "$M_STOP"; then
    echo "wake=$1 variant=$4: no Stop within 120 s" >&2
    RC_NOTEX=1
    return 1
  fi
  sleep 2
  evaluate "$1" "$2" typed "$4" "$(row_expect "$4")"
  sleep 4
}

# idle_notification_row <idle|fresh> — end a turn that started a background
# command, then wait for the <task-notification> to start a new one. The seed is
# written again after the starting turn's Stop, which moves last_activity.
idle_notification_row() {
  local variant="$1" i=0
  seed "$CUR" "$variant"
  snap
  send "Run the shell command: sleep 20; echo IDLE-MARK with the Bash tool, in the background (run_in_background true). Then reply with the word started and end your turn."
  if wait_stops "$M_STOP"; then
    sleep 3
    seed "$CUR" "$variant"
    snap
    while [ "$i" -lt 90 ]; do
      if tail -n +"$((M_TR + 1))" "$TR" 2>/dev/null | jq -e -s 'any(.[]; .type == "user" and ((.message.content | if type == "string" then . else (map(.text? // "") | join("")) end) | startswith("<task-notification>")))' >/dev/null 2>&1; then
        break
      fi
      sleep 2
      i=$((i + 2))
    done
    wait_stops "$M_STOP" || echo "wake=idle-task-notification variant=$variant: no Stop after the notification within 120 s" >&2
    sleep 2
    evaluate idle-task-notification real idle "$variant" "$(row_expect "$variant")"
  else
    echo "wake=idle-task-notification variant=$variant: the starting turn gave no Stop within 120 s" >&2
    RC_NOTEX=1
  fi
  sleep 4
}

# --- session 1 ------------------------------------------------------------------------

unset TMUX
CUR="$UUID1"
tm_start "$T/work" "$UUID1"

typed_row typed real "reply with the word ok" idle || { tm_stop; exit 3; }
if [ "$(lines "$T/ts.log")" -lt 1 ] || ! jq -e -s 'any(.[]; type == "object" and has("emitted"))' "$T/ts.log" >/dev/null 2>&1; then
  echo "the branch hooks did not load: no emitted key in ts.log after the first row (see $T)" >&2
  exit 3
fi
if [ "$(lines "$T/ups-in.jsonl")" -ge 1 ]; then
  echo "settings-hooks-merged=yes"
else
  echo "settings-hooks-merged=no (ups-fired falls back to the ts.log line)"
  UPS_SRC=tslog
fi
typed_row typed real "reply with the word ok" fresh

typed_row substrate-wake real "[substrate wake] live check: reply with the word ok" idle
typed_row substrate-wake real "[substrate wake] live check: reply with the word ok" fresh
typed_row cross-session-1 synthetic-typed '<cross-session-message from="live-check">ping</cross-session-message>' idle
typed_row cross-session-1 synthetic-typed '<cross-session-message from="live-check">ping</cross-session-message>' fresh
typed_row cross-session-2 synthetic-typed 'Another Claude session sent a message: <cross-session-message from="live-check">ping</cross-session-message>' idle
typed_row cross-session-2 synthetic-typed 'Another Claude session sent a message: <cross-session-message from="live-check">ping</cross-session-message>' fresh

idle_notification_row idle
idle_notification_row fresh

# mid-turn queued <task-notification>: idle for the turn's first prompt only.
seed "$CUR" idle
snap
send "Start the shell command: sleep 5; echo MID-MARK with the Bash tool in the background (run_in_background true). Then run the shell command: python3 -c \"import time; time.sleep(25)\" with the Bash tool in the foreground (a standalone sleep is blocked by the harness). Then reply with the word done."
if wait_stops "$M_STOP"; then
  sleep 3
  evaluate mid-turn-task-notification real mid mid line-first-prompt-only
else
  echo "wake=mid-turn-task-notification: no Stop within 120 s" >&2
  RC_NOTEX=1
fi
tm_stop

# --- session 2: the Stop-hook continuation ---------------------------------------------------

mkdir -p "$T/work2"
CUR="$UUID2"
tm_start "$T/work2" "$UUID2" "ALFRED_STOP_BRIDGE_BIN=$T/stub-bridge.sh ALFRED_STOP_LOOP_BIN=$T/stub-loop.sh"
seed "$CUR" idle
snap
send "say hi"
if wait_stops "$((M_STOP + 1))"; then
  sleep 3
  evaluate stop-continuation stop-stub stop stop none
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
