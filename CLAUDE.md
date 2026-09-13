# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Repository Purpose

This is a Claude Code plugin providing agent workflow utilities for the Alfred platform. It enables inter-agent communication through the agent-messaging MCP service.

## Repository Structure

```
ccplugin-alfred-agent-workflow/
├── .claude-plugin/
│   └── plugin.json          # Plugin metadata (name: alfred-agent)
├── commands/
│   ├── check-messages.md    # /alfred-agent:check-messages
│   ├── show-inbox.md        # /alfred-agent:show-inbox
│   └── show-threads.md      # /alfred-agent:show-threads
├── bin/
│   └── alfred-wake          # Deterministic inbox wake bridge (Monitor-armed)
├── hooks/
│   ├── hooks.json           # Hook registrations
│   └── context-budget.sh    # Context-budget actuator + self-clear
├── tests/
│   └── context-budget.sh    # Plain-bash test suite for the hook
├── skills/
│   └── messaging/
│       └── SKILL.md         # General messaging context
├── CLAUDE.md                # This file
└── README.md                # User documentation
```

## Commands vs Skills

- **Commands** (`commands/*.md`) → User-invoked via `/alfred-agent:*` menu
- **Skills** (`skills/*/SKILL.md`) → Context Claude can use automatically

## Naming Convention

- Plugin name: `alfred-agent`
- Commands: `alfred-agent:check-messages`, `alfred-agent:show-inbox`, `alfred-agent:show-threads`
- Command filenames use hyphens: `check-messages.md`

## Dependencies

Commands depend on the `agent-messaging` MCP server being configured. The MCP provides these tools:
- `mcp__agent-messaging__send_message`
- `mcp__agent-messaging__get_messages`
- `mcp__agent-messaging__mark_read`
- `mcp__agent-messaging__reply`
- `mcp__agent-messaging__get_thread`
- `mcp__agent-messaging__list_threads`
- `mcp__agent-messaging__delete_thread`

## Publishing

This plugin is published via the alfred-cc-tools marketplace:

1. Ensure changes are committed and pushed to this repo
2. Marketplace entry exists in `alfred-cc-tools/.claude-plugin/marketplace.json`
3. Users install via: `/plugin install alfred-agent@alfred-cc-tools`

## Session startup checklist

At the start of every session using this plugin, agents MUST, in this order:

1. **Arm the wake bridge before anything else.**

   ```bash
   command -v alfred-wake >/dev/null 2>&1 || "${CLAUDE_PLUGIN_ROOT}/bin/alfred-wake" install
   ```

   ```
   Monitor(command: "alfred-wake run", persistent: true,
           description: "inbox wake: agent-messaging + Buzz")
   ```

   `bin/alfred-wake` is deterministic bash — no LLM call anywhere in it. It
   prints a `WAKE …` line only when something genuinely new arrives, and the
   harness turns that line into a wake-up. Silence burns no tokens.

   **Fall back to `/loop 15m /alfred-agent:check-messages` only if arming
   fails**, and say out loud that you fell back.

2. **Run `/alfred-agent:check-messages` once** to pick up anything that arrived
   before the bridge came up. The bridge seeds its cursors on first run and
   never replays history, so this one-shot is what closes that gap.

3. **For active multi-turn conversations**, if you need to wait synchronously on a peer reply, use the bounded ad-hoc poll pattern documented in `commands/check-messages.md` (Ad-hoc poll loop section). Never spin an unbounded background poller.

## bin/alfred-wake

The wake bridge ships with the plugin at `bin/alfred-wake` (executable, bash +
curl + jq only). It watches agent-messaging always, and Buzz when — and only
when — the pod has a buzz-mcp sidecar; a lead with no Buzz identity runs
agent-messaging-only with no error.

Invariants to preserve when editing it:

- **No secret in argv, stdout, stderr or the log.** curl auth goes through a
  `-K` config file in a `umask 077` temp dir. Never add `set -x`.
- **The Buzz private key is never read by the script.** Buzz goes through the
  pod-local sidecar, which is the sole key holder and does NIP-42 AUTH.
- **Read-only.** No mark-as-read, no sends, no posts — the session decides what
  to do after being woken.
- **stdout is the wake channel.** Only `WAKE …`, `WAKE-INIT`, `WAKE-ERROR` and
  `WAKE-RECOVERED` lines may be printed there; diagnostics go to stderr and
  only in `check` mode.
- **Cursors live on the workspace volume** (`/workspace/.alfred-wake` when
  writable) so a pod restart never replays history.
- **shellcheck-clean** — CI enforces this (`.github/workflows/shellcheck.yml`).

## hooks/context-budget.sh

The context-budget actuator. It reads the context usage the fleet status line writes
to `${ALFRED_STATE_DIR:-$HOME/.cache/alfred}/context/<session_id>.json`, turns it into
in-session pressure, and — once the session has landed with `--clear` — clears the
session itself by typing into its own tmux pane.

**Thresholds are in tokens** (`ALFRED_CONTEXT_SOFT_TOKENS`, default 80000;
`ALFRED_CONTEXT_HARD_TOKENS`, default 120000), decided from the `used` field.
Degradation and cost scale with absolute tokens, so a percentage moves the goalposts
whenever the window size changes. `ALFRED_CONTEXT_SOFT_PCT` / `_HARD_PCT` remain as a
fallback for a status line that writes no `used` field — do not promote them back.

The self-clear flow, end to end:

```
land --mode=light
  → context-budget.sh landed --clear --summary "<one line>"    (clear_mode=clear)
  → Stop hook, after it decides not to block: spawns the detached sender
  → sender: idle input box on two polls 2 s apart → /clear, sleep 1, Enter
  → SessionStart (source=clear): one handover line injected, marker consumed
```

Invariants to preserve when editing it:

- **stdout carries hook JSON and nothing else**, and the only non-zero exit is the
  intentional `Stop` block (exit 2). Every other failure is silent.
- **Never an unendable turn.** `Stop` honours `stop_hook_active` and refuses to block
  unless the once-per-crossing flag was definitely persisted.
- **The sender is fully detached** (`setsid nohup … >/dev/null 2>&1 </dev/null &`).
  The hook must return immediately and the child must outlive it.
- **Never type into a pane the owner is using.** Idle means `cursor_x` 2 and no
  `esc to interrupt` in the last pane lines, twice in a row. A `last_prompt_ts` newer
  than `landed_ts` aborts the send: the context is no longer landed. It is re-read
  before the command and again before the Enter; if it moves in between, `C-u` wipes
  the typed command so the owner is not left with half a slash command.
- **A send is not a clear.** The sender checks both `send-keys` exit statuses and waits
  for `SessionStart` to consume `last-clear.json` before recording `cleared_ts`. No
  consumption means `unconfirmed` and the second attempt, never a success claim.
- **One sender at a time.** `clear_mode` is re-read before the first keystroke; the
  sender then claims the send with `clear_mode=none` + `clear_sending=<pid>` and
  re-checks the claim before the Enter.
- **Never guess which session to clear.** Resolution is argument →
  `CLAUDE_CODE_SESSION_ID` → `CLAUDE_SESSION_ID` → the pane-keyed pointer → the unkeyed
  pointer → the newest state file, and a landing resolved from that last one refuses to
  arm a clear at all. `CLAUDE_CODE_SESSION_ID` is the spelling the Bash tool exports.
- **Bounded**: two attempts of 90 s. After that the hook says so and the owner clears.
  No tmux pane means the same message, not a silent no-op.
- **`PreCompact` is recorded, never blocked.** An automatic compaction is the failure
  signal for this rule, and the next prompt is told the handover may be incomplete.
- **A session must run inside tmux** for the self-clear to work at all — fleet-wide
  this is already the case.
- Tests: `bash tests/context-budget.sh`. Every behaviour above has a case; keep it
  that way. shellcheck-clean, like `bin/alfred-wake`.

## Development

When modifying commands/skills:
1. Edit the relevant `.md` file
2. Test locally with `/plugin validate .`
3. Commit and push changes
4. Marketplace picks up changes automatically

### Versioning convention

Every PR that changes plugin contents (skills, commands, rules, MCP config) **must bump the version in `.claude-plugin/plugin.json`**. Use semantic versioning: patch for fixes, minor for new skills/commands/rules, major for breaking changes.

After merging here, open a follow-up PR in `Screenfields/alfred-cc-tools` to bump the `version` field for `alfred-agent` in `.claude-plugin/marketplace.json` to match. This is what triggers cache-invalidation and distributes the new version to devboxes on next cold-restart.

The two version numbers must stay in sync. If they drift, devboxes load stale skill versions without any warning (see ccplugin-alfred-agent-workflow#51 for the detection work).
