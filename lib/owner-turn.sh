# shellcheck shell=bash
# Shared owner-turn test (CCW-141, D12). Sourced by bin/alfred-loop-check
# (note-turn) and hooks/reply-timestamp.sh, so both agree on what an owner
# turn is. Defines one function and sets nothing else; it never exits.
#
#   is_owner_turn <entrypoint> <source> <prompt>
#
# Returns 0 for an owner turn, 1 for a machine turn:
#   - the entrypoint is an interactive one (cli, claude-vscode, claude-desktop);
#   - `source` is not one of the four machine values. `user`, `sdk` and absent
#     count as owner, because the source of Remote Control prompts is unverified;
#   - the prompt has no machine prefix and is not empty;
#   - ALFRED_ROLE is not worker.
# Unknown is machine.
is_owner_turn() {
  local ep="${1:-}" src="${2:-}" prompt="${3:-}"
  [ "${ALFRED_ROLE:-}" = "worker" ] && return 1
  case "$ep" in cli|claude-vscode|claude-desktop) ;; *) return 1 ;; esac
  case "$src" in system|loop_wakeup|schedule_wakeup|poll_event) return 1 ;; esac
  prompt="${prompt#"${prompt%%[![:space:]]*}"}"
  case "$prompt" in
    "<task-notification>"*|"<cross-session-message"*|"[substrate wake]"*|"<scheduled-task"*|"[scheduled-task"*|"") return 1 ;;
  esac
  return 0
}
