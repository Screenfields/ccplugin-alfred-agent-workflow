#!/usr/bin/env bash
# Stop hook: a lead must never end a turn without its wake bridge running.
#
# A lead re-arms `alfred-wake wait` after every wake. When a turn ends without
# that (the step was skipped, or the bridge was signalled away), the session
# stays up but no mail can wake it until someone notices, possibly hours
# later. At the end of every turn this hook checks `alfred-wake status` (a pid
# check, no network, no model call). If the bridge is not armed, it blocks the
# stop once with an instruction to relaunch it, so the same turn re-arms it.
#
# It never loops: when the stop it is checking was itself caused by this hook
# (stop_hook_active) and the bridge is still down, the relaunch failed; the
# stop goes through with a visible warning instead of a second block.
#
# Silent (allows the stop) when:
#   - this is not an Alfred devbox, where alfred-wake is the lead's bridge.
#     The marker is the image's start-helpers.sh. The hub and workstations
#     run other bridges (hub-wake-bridge) and must never be pushed to start a
#     competing alfred-wake. ALFRED_WAKE_STOP_CHECK=1 forces the check on,
#     =0 forces it off.
#   - the project has no .alfred/config.json with an agent_id (not a lead),
#   - the bridge is armed (it may take a moment after a relaunch, so the check
#     retries for about 3 s first).
# Seen live 2026-10-14 on screenfields-ai: a wake turn ended without the
# relaunch and the lead was deaf for three hours until nudged.
set -u

input=$(cat)
case "${ALFRED_WAKE_STOP_CHECK:-auto}" in
  0) exit 0 ;;
  1) ;;
  *) [ -r "${ALFRED_DEVBOX_MARKER:-/usr/local/lib/alfred/start-helpers.sh}" ] || exit 0 ;;
esac
again=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"
jq -e '.agent_id // empty' "$cwd/.alfred/config.json" >/dev/null 2>&1 || exit 0

wake="${ALFRED_WAKE_CHECK_BIN:-$(dirname "$0")/../bin/alfred-wake}"
[ -x "$wake" ] || exit 0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  "$wake" status >/dev/null 2>&1 && exit 0
  sleep 0.3
done

if [ "$again" = "true" ]; then
  jq -n '{systemMessage: "WARNING: the alfred-wake bridge is still not running after a relaunch attempt. This lead cannot be woken by mail until it runs: start `alfred-wake wait` as a background task, or check `alfred-wake status`."}'
  exit 0
fi
jq -n '{
  decision: "block",
  reason: "The alfred-wake bridge is not running, so new mail cannot wake this session. Relaunch it now with Bash(command: \"alfred-wake wait\", run_in_background: true). Write no text about it unless the relaunch fails."
}'
