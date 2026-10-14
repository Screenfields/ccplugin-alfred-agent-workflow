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
#   - session busy (the pane shows a running turn): wait for the next check;
#   - otherwise: type the prompt, press Enter, exit.
set -u

pane="$1" status_cmd="$2" start_cmd="$3"
tries="${ALFRED_NUDGE_TRIES:-4}"
delay="${ALFRED_NUDGE_DELAY:-20}"
tmux_bin="${ALFRED_TMUX_BIN:-tmux}"
prompt="[substrate wake] session restarted with the wake watcher down. Start it (Bash run_in_background: $start_cmd), run /alfred-agent:check-messages once, and report the watcher and inbox state in one line."

for _ in $(seq "$tries"); do
  sleep "$delay"
  # shellcheck disable=SC2086  # the status command is a configured command line
  if timeout 10 $status_cmd >/dev/null 2>&1; then exit 0; fi
  screen=$("$tmux_bin" capture-pane -p -t "$pane" 2>/dev/null) || exit 0
  # A turn in progress shows "esc to interrupt"; leave it alone.
  if printf '%s\n' "$screen" | grep -q 'esc to interrupt'; then continue; fi
  "$tmux_bin" send-keys -t "$pane" -l "$prompt" || exit 0
  sleep 1
  "$tmux_bin" send-keys -t "$pane" Enter
  exit 0
done
exit 0
