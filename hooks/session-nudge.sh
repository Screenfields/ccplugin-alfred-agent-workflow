#!/usr/bin/env bash
# session-nudge.sh <tmux-pane> <status-cmd> <start-cmd>
#
# One-shot helper started by session-check.sh after a session (re)start with
# the wake watcher down. It gives the session one real turn, so the
# SessionStart instructions are acted on even when nobody types. It does that
# by typing a fixed prompt into the session's own pane, as the devbox start
# and nudge-watcher already do.
#
# It runs once per session start and is bounded: up to ALFRED_NUDGE_TRIES
# checks (default 4), ALFRED_NUDGE_DELAY seconds apart (default 20), then it
# exits. It is not a recurring poll. Each check:
#   - watcher running (a start prompt, the owner or the agent got it going):
#     exit, nothing to do;
#   - a tmux client is attached: exit. Someone is there, and the SessionStart
#     context acts on their own first prompt; typing could merge into their
#     half-written message;
#   - not safe to type (a turn running, input in the prompt, or a dialog,
#     menu or selector on screen): wait for the next check;
#   - otherwise: type the prompt, re-check everything, press Enter, exit.
#
# <status-cmd> is a shell command line, run with `bash -c`.
set -u

pane="$1" status_cmd="$2" start_cmd="$3"
tries="${ALFRED_NUDGE_TRIES:-4}"
delay="${ALFRED_NUDGE_DELAY:-20}"
tmux_bin="${ALFRED_TMUX_BIN:-tmux}"
prompt="[substrate wake] session restarted with the wake watcher down. Start it (Bash run_in_background: $start_cmd), run /alfred-agent:check-messages once, and report the watcher and inbox state in one line."

attached() {
  [ "$("$tmux_bin" display-message -p -t "$pane" '#{session_attached}' 2>/dev/null || echo 1)" != "0" ]
}

# safe_to_type <expect_empty>: no turn running and no dialog. With
# expect_empty=yes also the cursor on the prompt line at column 2, right after
# "❯ ", so the input is empty; placeholder text is ghost text, so the cursor
# decides, not the screen text. (After typing, the long prompt wraps, so the
# re-check before Enter uses expect_empty=no.)
safe_to_type() {
  local screen pos x y line
  screen=$("$tmux_bin" capture-pane -p -t "$pane" 2>/dev/null) || return 1
  if printf '%s\n' "$screen" | grep -qE 'esc to interrupt|Enter to confirm|Esc to cancel|to navigate|Do you want to|Enter to select'; then
    return 1
  fi
  [ "$1" = yes ] || return 0
  pos=$("$tmux_bin" display-message -p -t "$pane" '#{cursor_x} #{cursor_y}' 2>/dev/null) || return 1
  read -r x y <<< "$pos"
  line=$(printf '%s\n' "$screen" | sed -n "$((y + 1))p")
  case "$line" in
    "❯"*|">"*) ;;
    *) return 1 ;;
  esac
  [ "$x" = 2 ]
}

for _ in $(seq "$tries"); do
  sleep "$delay"
  if bash -c "$status_cmd" >/dev/null 2>&1; then exit 0; fi
  if attached; then exit 0; fi
  safe_to_type yes || continue
  "$tmux_bin" send-keys -t "$pane" -l "$prompt" || exit 0
  sleep 1
  # Re-check right before Enter. If the state changed (someone attached, a
  # dialog opened, the watcher started), erase our text instead of submitting.
  if bash -c "$status_cmd" >/dev/null 2>&1 || attached || ! safe_to_type no; then
    "$tmux_bin" send-keys -t "$pane" -N "${#prompt}" BSpace
    exit 0
  fi
  "$tmux_bin" send-keys -t "$pane" Enter
  exit 0
done
exit 0
