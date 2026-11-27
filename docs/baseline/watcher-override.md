# Watcher override per agent

Baseline record of how the SessionStart hook picks the wake watcher's status and
start commands (CCW-201). The code is the source of truth:
`hooks/session-check.sh`; the nudge it feeds is `hooks/session-nudge.sh`.

## The defect

`session-check.sh` took the two commands from `ALFRED_WATCHER_STATUS_CMD` and
`ALFRED_WATCHER_START_CMD`, plain environment variables that name no agent. A
session whose hook environment held the hub's values reported the hub's bridge as
its own ("NOT running", or "running" when the hub's bridge was up, so the session
stayed deaf), and the nudge typed the hub's start command into its pane, which
takes over the hub's single-instance wake. How the values reached the other
session is not verified; the fix does not depend on it.

## What exists

- The override is a `watcher` object in the checkout's own `.alfred/config.json`:
  `status_cmd` and `start_cmd`, both shell command lines run with `bash -c`. The
  file is read from the `cwd` of the hook input, not `$PWD`, a parent or the git
  root, so two checkouts of one repository (a git worktree) each use their own.
- `watcher` absent or `null`: the defaults, `alfred-wake status` and
  `alfred-wake wait`.
- Usable means an object whose two values are strings that are not empty after
  trimming whitespace and contain no control character (a newline would mix the
  pair and act as Enter in the nudge's `send-keys`). Anything else is not usable:
  both defaults, never one of each, and one stderr line naming the failing key
  (`status_cmd` is checked before `start_cmd`).
- `ALFRED_WATCHER_STATUS_CMD` and `ALFRED_WATCHER_START_CMD` are ignored: their
  presence is tested, their values never read, and one stderr line says so. Stderr
  of a SessionStart hook that exits 0 is not shown to the model, so a third agent
  that still relies on them falls back silently. Only the hub and Alfred are
  known to use them, and both have the field.
- A malformed config file or a top-level non-object keeps the existing path: the
  `agent_id` check exits 0 with empty stdout, as for any non-lead. A broken config
  also silences the watcher check, as before.
- When the watcher is not running, the context gains
  `Checked: <status_cmd> (agent <agent_id>).` after the first sentence. The quiet
  "running, 0 unread" line is unchanged, so the common case costs no tokens.
- `session-nudge.sh` is unchanged and receives the bound pair.
- jq 1.6 (the devbox) has no `trim`; the check uses `gsub("^\\s+|\\s+$";"")` and
  `test("[[:cntrl:]]")`.

## Alternatives not chosen

- **An environment pair plus an agent-id variable.** The comparison rejects a
  foreign pair, but one environment holds one pair, and the one that reached
  Alfred's session is the hub's. Alfred could never receive its own pair; it would
  fall back to the defaults and compete with the hub's bridge on that host.
- **Per-agent variable names** (`ALFRED_WATCHER_*_<AGENT>`). Each agent's
  configuration would sit in a settings file shared by the host or repository,
  the channel that leaked, owned by whoever controls that file. Identity already
  lives in the checkout's `.alfred/config.json`; this splits one agent's
  configuration across two homes.
- **Agent-aware `alfred-wake`.** The hub and Alfred run bridges that are not
  `alfred-wake`; the plugin cannot make them agent-aware.
- **A fixed script name per agent.** The same as the field but implicit, and it
  would run a file found by name, a weaker trust boundary than a field in the
  agent's own config.

## Trust

The command comes from a project file and is run with `bash -c`. That is the
same trust as settings.local.json: the same trust as settings.local.json holds
because `.alfred/` is gitignored (`commands/init.md` adds it), so the file is
written on the host by the agent's owner and never arrives through a clone or a
pull. No owner approval is needed beyond that.

## Migration order

1. The `watcher` fields are added to the hub's and Alfred's checkouts first; an
   older hook ignores an unknown field, so this is safe.
2. This release (2.55.0) ships and the catalog pin moves.
3. Each session restarts and its SessionStart context is read while the watcher is
   still down: the "NOT running" line must name its own bridge and agent.
4. Only then does the hub remove `ALFRED_WATCHER_*` from its settings. Removing
   them earlier leaves a session on the old hook without its bridge.
