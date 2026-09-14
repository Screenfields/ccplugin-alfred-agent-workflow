# Alfred Agent Workflow Plugin

Slash commands + skills for inter-agent coordination: messaging, ECR (Expert Consulting Review), session retrospectives, design / develop / land workflows, git-commit discipline.

Bundles an `agent-messaging` MCP server pointed at the platform's messaging service, plus a set of slash commands and skills that wrap common agent workflows.

## Quick start

### 1. Required environment variables

The plugin's MCP config is env-var driven. Set these in the launch environment of the Claude Code session (e.g. `~/.claude/settings.json` `env` block, or the surrounding shell). Your platform team should provide values for the secrets.

| Env var | Purpose |
|---|---|
| `AGENT_MESSAGING_TOKEN` | Bearer token for agent-messaging |
| `AGENT_ID` | This agent's identity (becomes the `X-Agent-ID` header) — e.g. `my-agent` |
| `AGENT_MESSAGING_URL` | Optional override of the default messaging URL |

> **Off-platform deployments:** Cloudflare Service tokens (`CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`) will be required to reach the messaging endpoint. Contact your platform team for values.

### 2. Container caveat — `git insteadOf` for ssh-less images

Most slim container base images (node:slim, python:slim, etc.) ship without an `ssh` binary. Claude Code's `/plugin install` defaults to SSH cloning → fails with `ssh: not found`.

Run once before `/plugin install` in any container without ssh:

```bash
git config --global url."https://github.com/".insteadOf "git@github.com:"
git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
```

### 3. Install

```
/plugin marketplace add https://github.com/Screenfields/alfred-cc-tools.git
/plugin install alfred-agent@alfred-cc-tools
```

When prompted for scope: pick **User**.

After install, `/exit` and re-launch Claude Code so the plugin's MCP server registers using the env vars from step 1.

### 4. Verify

```
/alfred-agent:check-messages
```

Then arm the wake bridge so the session is woken on new mail instead of polling
every 15 minutes — see [`alfred-wake` — the wake bridge](#alfred-wake--the-wake-bridge):

```bash
command -v alfred-wake >/dev/null 2>&1 || "${CLAUDE_PLUGIN_ROOT}/bin/alfred-wake" install
alfred-wake check     # dry run: proves auth + config before you arm it
```

Should reach the messaging service and report your inbox state. If the MCP isn't connected, run `/mcp` to see the connection status — common causes are missing env vars or stale cached sessions (a fresh `/exit` + re-launch usually clears).

## Slash commands

| Command | Purpose |
|---|---|
| `/alfred-agent:check-messages` | Pull unread messages from your inbox; auto-mark as read after display |
| `/alfred-agent:show-inbox` | Full inbox view with threads and unread counts |
| `/alfred-agent:show-threads [from-agent]` | List threads, optionally filter by sender |
| `/alfred-agent:init` | One-time project init (writes `.alfred/config.json` with your agent_id) |
| `/alfred-agent:design` | Guided design-doc creation for new services / features |
| `/alfred-agent:develop` | Feature-dev workflow: pick up issue → code with tests → PR → merge |
| `/alfred-agent:ecr` | Expert Consulting Review — multi-model architectural feedback |
| `/alfred-agent:retro` | Session retrospective for capturing learnings |
| `/alfred-agent:land` | Session close-out: retro + git push + reconcile work to issues. `--mode=light` = the short between-boundaries landing driven by the context budget. `--restart`/`--compact` land into a restart/compact instead of a clear; `--force` skips the git/running-agent completeness checks (never the handover check) |
| `/alfred-agent:recover` | Run first in any new session: reads the SessionStart classification (graceful/unplanned/fresh) and either confirms-and-continues, runs the full unplanned-restart recovery checklist, or does nothing |
| `/alfred-agent:git-commit` | Authoritative commit procedure (always invoke before `git commit`) |
| `/alfred-agent:documentation` | Apply baseline-vs-delta + ADR discipline when writing docs |
| `/alfred-agent:messaging` | Inter-agent messaging skill (MCP tool reference) |

## Context budget

The lead lands and clears once the session has burned its token budget. The plugin
ships a hook that measures that, acts on it, and — after a landing — clears the
session itself, so the rule does not depend on anyone remembering it.

**Thresholds are in tokens, not percent.** Degradation and cost scale with the
absolute number of tokens in the window, so a percentage silently moves the goalposts
whenever the window changes (20% of 1M is 200k). The percentage thresholds survive
only as a fallback for a status line whose state file carries no `used` field.

**Thresholds are measured above the session baseline.** A fresh session is not at
zero: system prompt, `CLAUDE.md`, memory index, tool and MCP schemas and the
`SessionStart` injections are in the window before the conversation has said anything
(~86000 tokens on the hub). `SessionStart` arms a baseline, the first reading after it
records `used` as this session's floor, and every tier is decided on `used - baseline`
— so the budget measures what *this conversation* burns. A session with no armed
baseline (one that started before this build, or whose `SessionStart` hook never ran)
falls back to measuring `used` itself, exactly as before.

**A live conversation is nagged, not cut off.** The hard tier blocks the turn and arms
the self-clear only when the box has been quiet: while a human prompt is younger than
`ALFRED_CONTEXT_INTERACTIVE_SECONDS` (default 10 min) the `Stop` hook says the same
thing and lets the turn end. Wake-bridge wakes arrive as `Monitor` output, not as user
prompts, so an unattended session is unaffected. Above
`ALFRED_CONTEXT_CEILING_TOKENS` (default 200000 above the baseline) even a live
conversation lands.

**Requirement: the session runs inside tmux.** Typing into the session's own pane is
the only way a session can clear itself, and `$TMUX_PANE` is where the hook aims.
Fleet sessions already run in tmux; a session outside it lands normally and is told
to ask the owner for the clear.

| Piece | Where |
|---|---|
| Sensor | The **fleet status line** from [alfred-devbox](https://github.com/Screenfields/alfred-devbox) (`share/alfred/statusline-command.sh`) writes `${ALFRED_STATE_DIR:-$HOME/.cache/alfred}/context/<session_id>.json` — `{"pct","used","size","ts"}` — on every assistant message. No hook event carries context usage; the status line is the only surface that does |
| Actuator | `hooks/hooks.json` + `hooks/context-budget.sh` on `UserPromptSubmit`, `PostToolUse` (all tools), `Stop`, `SessionStart` (`startup\|resume\|clear\|compact`) and `PreCompact` (`auto`) |
| Procedure | `/alfred-agent:land --mode=light` — offload to issues/Metis (`capture_note`), write the handover file, push, mark landed with `--clear`/`--compact`/`--restart` once the completeness gate passes |
| Recovery | `/alfred-agent:recover` — run first at every session start; reads the classification the hook injected and either confirms-and-continues, runs the unplanned-restart checklist, or does nothing |

Behaviour:

- **Soft tier** (default 80000 tokens) — injects `CONTEXT BUDGET: n tokens (p%) used … Land at the next natural boundary`.
- **Hard tier** (default 120000 tokens) — injects `… LAND NOW`, and the first `Stop` after crossing is blocked once with the light-landing checklist. Never two blocks in a row, never a block at soft tier.
- **Interactive deferral** — at the hard tier, with a `UserPromptSubmit` in the last `ALFRED_CONTEXT_INTERACTIVE_SECONDS` (default 600) and usage below `ALFRED_CONTEXT_CEILING_TOKENS` (default 200000, measured above the baseline too), the `Stop` hook injects the hard nag and exits 0: no block, no sender. The once-per-crossing block flag is left unset, so the block still fires on the first `Stop` after the conversation goes quiet, or as soon as the ceiling is crossed. Token mode only — the percentage fallback has no ceiling to compare against and keeps blocking as before.
- **Session baseline** — `SessionStart` writes `baseline_pending=1`; the first `check` with a fresh reading records `baseline=<used>` and every token tier is then decided on `used - baseline`. A reading *below* the baseline (the window was compacted) lowers the baseline to that new floor rather than going negative. All four `SessionStart` sources arm it, `resume` included, so a session that comes back via `claude -c` measures from where it resumed. The injected line names both numbers: `44000 tokens this session (130000 total, 13%) used`.
- **Rate limit** — one injection per tier per session per 10 minutes; escalating soft → hard resets the timer so the harder message is not swallowed. `PostToolUse` is capped harder: once per tier for the whole session, since a tool result is a worse place to interrupt than a prompt boundary.
- **Sub-agents are skipped** — a worker's tool calls fire `PostToolUse` under the parent's `session_id`, so the hook ignores any event carrying `agent_id` (present only in sub-agent context) and any `Agent`/`Task` tool call. Workers are never told to land a session they do not own.
- **Fails open** — `Stop` honours `stop_hook_active`, and refuses to block unless the once-per-crossing flag was definitely persisted. A broken state directory means no nagging, never an unendable turn.
- **Silent by default** — no state file, or a reading older than 2 hours, means the hook does nothing. A host without the fleet status line simply never sees it.

### Self-clear (and self-compact, and self-restart) after a landing

```
/alfred-agent:land --mode=light
  └─ context-budget.sh landed --clear --summary "<one line>"   # completeness gate, then clear_mode=clear
       └─ Stop hook (the turn that ends the landing)
            └─ detached sender:  idle input box?  →  type /clear  →  Enter
                 └─ SessionStart (source=clear)  →  classified "graceful clear" + handover injected
```

`--restart` runs the same way except the sender runs a restart command
(`ALFRED_SESSION_RESTART_CMD`, default `hub-restart`) instead of typing `/clear`; the
new session comes up via `claude -c`, which reports `source=resume` at `SessionStart`
— matched the same as the other three sources.

- **The completeness gate** (`landed --clear`/`--compact`/`--restart`, any mode but `--no-clear`) refuses to arm — recording nothing at all — unless: (1) `${ALFRED_STATE_DIR:-$HOME/.cache/alfred}/context/handover.md` exists, is ≤4096 bytes, ≤30 min old, and contains a Metis capture id (`cap-[0-9a-f]{8}`); (2) the project git tree and every worktree `git worktree list --porcelain` knows about is clean and pushed (a still-registered worker worktree counts as not cleaned up on its own); (3) no background sub-agent looks like it is still running (best-effort: a task transcript under `/tmp/claude-<uid>/<project-slug>/<session-id>/tasks/*.output` touched in the last 60s — not authoritative, since Claude Code slugs that directory by the session's original launch cwd, not a worktree's, and a long-running tool call leaves no recent write while very much still running; the land skill's own Drain step is the authoritative check). `--force` skips (2) and (3) only, never (1), and is recorded as `forced=true`/`false` in the budget file. `--no-handover` skips (1) alone, for the rare landing that truly has nothing to hand over.
- **`landed [--clear|--compact|--restart|--no-clear] [--force] [--no-handover] [--summary "<line>"] [session_id]`** records the intent. No flag means `clear_mode=none`, so callers written before this existed behave exactly as they did, and `--no-clear` is the only mode the completeness gate does not apply to.
- **Which session is being landed** resolves in this order: explicit argument, `CLAUDE_CODE_SESSION_ID` (what the Bash tool exports), `CLAUDE_SESSION_ID`, the pane-keyed pointer `check` writes at `<state dir>/context/current-session.<pane>`, the unkeyed pointer, then the newest state file. The pane-keyed pointer exists because a pane hosts exactly one session, so it stays unambiguous where the unkeyed one does not. **A session id resolved from the newest state file cannot arm a clear**: the hook refuses `--clear`/`--compact`, says why on stderr, and still records the landing — a guess could name another session, whose pane would get the keystrokes. `/alfred-agent:land` therefore passes `"$CLAUDE_CODE_SESSION_ID"` explicitly.
- **The `Stop` hook spawns the sender** — a fully detached child of this same script — *after* it has decided not to block. The hook returns immediately; the child outlives it.
- **The sender waits for an idle input box**: `cursor_x` is 2 and `esc to interrupt` is absent from the last pane lines, on two consecutive polls 2 s apart. It types the command, waits a second for the slash autocomplete to settle, then sends Enter separately.
- **Race guard** — the sender re-reads the budget file before every poll. A `last_prompt_ts` newer than `landed_ts` means the owner (or a wake) submitted a prompt after the landing, the context is no longer landed, and the sender aborts without typing anything (`clear_aborted=new-prompt`).
- **Confirmed, not assumed** — the sender checks both `tmux send-keys` exit statuses, then waits up to 15 s for `last-clear.json` to be consumed by the new session's `SessionStart` hook. Only then does it record `cleared_ts`. If the marker is still there it removes it, logs `unconfirmed`, and leaves `clear_mode` set for the second attempt. A session running an older plugin build has no `SessionStart` hook to consume the marker, so its clears always read as `unconfirmed` and the second attempt is spent on an already-cleared session — harmless, but it is why an old build looks noisier in the sender log.
- **Concurrency** — `clear_mode` is re-read immediately before the first keystroke and the sender aborts if another actor changed it. It then claims the send by writing `clear_mode=none` plus `clear_sending=<pid>`, so a second sender aborts instead of typing a second `/clear`; the claim is re-checked before the Enter. `last_prompt_ts` is re-read before the command *and* again before the Enter — if a prompt arrives in between, the sender sends `C-u` to wipe the typed command before exiting, so the owner is not left with half a slash command in their input box.
- **Two attempts, 90 s each.** A sender that hits its deadline, or comes back unconfirmed, leaves `clear_mode` set so the next `Stop` retries once. After the second, the hook gives up and injects a line asking the owner to clear.
- **No tmux pane** (or no `tmux` on `PATH`) — the hook resets `clear_mode` and injects `CONTEXT BUDGET: self-clear is not possible in this session (no tmux pane). Ask the owner to run /clear now; the landing is complete.`
- **`SessionStart` (all four sources: `startup`/`resume`/`clear`/`compact`) classifies every start:**
  - **graceful** — a fresh (≤15 min) last-clear marker is present: injects `CONTEXT BUDGET: graceful <mode> after landing — previous session <id> …`, naming the previous session, the mode, the local time and the summary, and telling the fresh session to continue from the handover file and GitHub issues rather than from recollection. The marker is consumed on read.
  - **unplanned** — no marker, but either a `boot-recovery.json` (written by the host's boot supervisor before recreating a session that died without landing — crash, OOM-kill, power loss; fields `ts`/`boot_ts`/`reason`/`host`, consumed on read) or the most recent OTHER session's budget file shows activity (`last_prompt_ts`) after its last landing (`landed_ts`), or no landing at all: injects `CONTEXT BUDGET: unplanned restart detected — recovery required.` plus a `RECOVERY:` line (previous session, last activity, last landing or "never", boot time if known) and `Run /alfred-agent:recover now, before any other work.`
  - **fresh** — neither of the above: nothing is injected.
  - **The handover file** (`context/handover.md`) is injected under its own `HANDOVER (written …, consumed now):` header and deleted, independent of the classification above — a stale handover after an unplanned restart is still better than none.
- **`PreCompact` (`auto` only — manual compaction is not hooked, and neither can block: verified against the [Claude Code hooks docs](https://docs.claude.com/en/docs/claude-code/hooks), exit code 2 and any JSON decision are ignored for this event on both triggers)** records the auto-compaction for one thing: the next `UserPromptSubmit` injects once — `the harness auto-compacted this session at n tokens before a landing ran. The handover may be incomplete — reconcile decisions from the transcript before continuing.` An un-landed compaction (manual or auto) or `/clear` is caught the same generic way as any other unplanned ending — via the `last_prompt_ts`/`landed_ts` comparison above, not via anything `PreCompact` itself records.

| Env var | Default | Purpose |
|---|---|---|
| `ALFRED_CONTEXT_SOFT_TOKENS` | `80000` | Soft threshold, in tokens used (input + output) |
| `ALFRED_CONTEXT_HARD_TOKENS` | `120000` | Hard threshold — the tier that can block a `Stop` |
| `ALFRED_CONTEXT_INTERACTIVE_SECONDS` | `600` | How recent a `UserPromptSubmit` must be for the hard tier to nag instead of blocking. `0` turns the deferral off |
| `ALFRED_CONTEXT_CEILING_TOKENS` | `200000` | Above this (measured above the baseline), the block fires however live the conversation is |
| `ALFRED_CONTEXT_SOFT_PCT` | `20` | Fallback soft threshold, used only when the state file reports no `used` |
| `ALFRED_CONTEXT_HARD_PCT` | `35` | Fallback hard threshold, same condition |
| `ALFRED_CONTEXT_CONFIRM_SECONDS` | `15` | How long the sender waits for `SessionStart` to consume the handover marker before calling the clear unconfirmed |
| `ALFRED_STATE_DIR` | `$HOME/.cache/alfred` | Root of the state directory shared with the status line |

A non-numeric threshold override falls back to the default silently, and every number read back from a budget file is validated the same way — a hand-edited or half-written state file never turns into an arithmetic error on a hook path.

State written under `<state dir>/context/`: `<session_id>.budget` (key=value: tiers, crossing, `landed_ts`, `clear_mode`, `clear_summary`, `clear_attempts`, `clear_sending`, `clear_aborted`, `cleared_ts`, `clear_unconfirmed_ts`, `last_prompt_ts`, `defer_nag_ts`, `baseline_pending`, `baseline`, `autocompact_ts`, `forced`), `<session_id>.sender.log` (one timestamped line per sender decision), `current-session` plus `current-session.<pane>` (session pointers), `last-clear.json` (the self-clear/compact/restart marker, consumed by the next `SessionStart`), `handover.md` (the land skill's handover content, consumed the same way, independent of the marker), and `boot-recovery.json` (written externally by the host's boot supervisor, consumed by the next `SessionStart`'s unplanned-restart classification).

Tests: `./tests/context-budget.sh` (plain bash, no framework).

Design and rationale: [Screenfields/alfred-platform#847](https://github.com/Screenfields/alfred-platform/issues/847); baseline delta and interactive deferral: [Screenfields/alfred-platform#874](https://github.com/Screenfields/alfred-platform/issues/874).

## MCP tools (provided by the bundled `agent-messaging` server)

| Tool | Purpose |
|---|---|
| `mcp__agent-messaging__send_message` | Send a new message to another agent |
| `mcp__agent-messaging__reply` | Reply within an existing thread |
| `mcp__agent-messaging__get_messages` | Pull unread messages for the current `X-Agent-ID` |
| `mcp__agent-messaging__list_threads` | List your conversation threads |
| `mcp__agent-messaging__get_thread` | Full message history for a thread |
| `mcp__agent-messaging__mark_read` / `mark_read_batch` / `mark_unread` | State management |
| `mcp__agent-messaging__delete_thread` | Permanently delete |

## Delivery model

Two layers, and you want both:

1. **`alfred-wake` — the wake bridge (arm this first).** A deterministic bash
   watcher shipped at `bin/alfred-wake`. It polls agent-messaging (and Buzz, if
   the pod has a Buzz identity) and prints a line on stdout **only** when
   something genuinely new arrives; the harness turns that line into a wake-up
   for the session. Silence costs nothing — no LLM runs, no tokens burn. This
   replaces the 15-minute `/loop 15m /alfred-agent:check-messages` cron and its
   ~96 empty model turns per agent per day.
2. **`/alfred-agent:check-messages` — the one-shot read.** Still run it once at
   session start (the bridge seeds cursors on first run and never replays
   history), and any time you want to read your inbox on purpose.

An earlier always-on in-pod background-poller architecture was retired
2026-06-09 due to instability. `alfred-wake` is a different shape: no sidecar
container, no heartbeat self-suicide, no per-check LLM cost — a subprocess of
the agent's own session that the agent starts and stops.

For active conversations where you need a synchronous round-trip, the
`check-messages` command documents a bounded ad-hoc poll pattern.

## `alfred-wake` — the wake bridge

### What it watches

| Source | Transport | Always on? |
|---|---|---|
| **agent-messaging** inbox (unread for your `AGENT_ID`) | MCP JSON-RPC over HTTP (`initialize` → `notifications/initialized` → `tools/call get_messages`), polled with backoff | Yes — the service offers no push |
| **Buzz** channels visible to your identity | MCP JSON-RPC against the **pod-local `buzz-mcp` sidecar** (`buzz_whoami` / `buzz_channels` / `buzz_read`), polled on the tick | **Optional.** No sidecar → agent-messaging only, logged once, no error |

Buzz is deliberately reached through the sidecar rather than the relay directly:
the sidecar is the only holder of the Nostr key and performs the NIP-42 AUTH
that every relay subscription requires. `alfred-wake` never reads a key.

### Arming it

```bash
# once per pod — puts alfred-wake on PATH via ~/.local/bin
command -v alfred-wake >/dev/null 2>&1 || "${CLAUDE_PLUGIN_ROOT}/bin/alfred-wake" install
```

```
Monitor(command: "alfred-wake run", timeout_ms: 1800000,
        description: "inbox wake: agent-messaging + Buzz")
```

If `~/.local/bin` is not on `PATH`, arm the full path instead:
`Monitor(command: "${CLAUDE_PLUGIN_ROOT}/bin/alfred-wake run", timeout_ms: 1800000, …)`.

There is no `persistent` parameter on the `Monitor` tool — the schema only
accepts `command`, `ws`, `description`, and `timeout_ms` (capped at
1800000 ms / 30 minutes). The Monitor always expires after 30 minutes and
must be re-armed on each expiry notification; nothing re-arms it
automatically, so an unnoticed expiry is a silent wake-coverage gap.

Fall back to `/loop 15m /alfred-agent:check-messages` **only** when arming
fails, and say so — a silent fallback is indistinguishable from a working
bridge.

### Verifying it

```bash
alfred-wake check     # one dry-run pass: never writes cursors, explains itself on stderr
alfred-wake status    # config + whether a run loop is currently armed (exit 0 = armed)
```

`check` is safe to run at any time: it resolves config, proves auth against both
sources, prints what it *would* have woken you with — and writes no cursor, so
it cannot swallow news that the running bridge should deliver.

### Modes

| Invocation | Behaviour |
|---|---|
| `alfred-wake run [interval]` | Watch loop. Default tick 20s (Buzz), agent-messaging every 60s with failure backoff to 600s |
| `alfred-wake check` | One dry-run pass, diagnostics on stderr, exit 0 |
| `alfred-wake install` | Symlink into `~/.local/bin` (override with `ALFRED_WAKE_BIN_DIR`) |
| `alfred-wake status` | Print config; exit 0 only if a `run` loop touched its marker in the last 5 min |

### Event lines (the stdout contract)

Only these shapes are ever printed to stdout. Anything else there is a bug.

| Line | Meaning |
|---|---|
| `WAKE am unread=<n> from=<a,b>` | New unread agent-messaging item(s); `n` = current total unread |
| `WAKE buzz <label> new=<n> from=<…> last=<HH:MM TZ>` | New non-self posts in that Buzz channel |
| `WAKE-INIT …` | First ever run: cursors seeded, history deliberately not replayed |
| `WAKE-ERROR <source>: <reason>` | A source failed 5 consecutive passes (repeats at most hourly) |
| `WAKE-RECOVERED <source>` | A previously-failing source succeeded again |

`<source>` is `agent-messaging`, `buzz`, or `buzz-<label>` per channel.

### Configuration

Everything is env-driven; the defaults are correct for a standard devbox pod.

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_MESSAGING_TOKEN` | — | Bearer token. **Required** unless `ALFRED_WAKE_MCP_JSON` supplies one |
| `AGENT_ID` | — | Sent as `X-Agent-ID`; your messaging identity |
| `AGENT_MESSAGING_URL` | `https://agent-messaging.screenfields.net/mcp/` | MCP endpoint |
| `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` | — | Sent when set (off-platform / CF Access paths) |
| `ALFRED_WAKE_MCP_JSON` | — | Optional path to a `.mcp.json` to source URL + headers from instead of the env. `${VAR}` and `${VAR:-default}` placeholders are expanded from the environment |
| `ALFRED_WAKE_BUZZ` | `auto` | `auto` (watch Buzz if a sidecar answers), `on` (require it — failures raise `WAKE-ERROR`), `off` |
| `ALFRED_WAKE_BUZZ_MCP_URL` | `http://127.0.0.1:8765/mcp` | The pod-local buzz-mcp sidecar |
| `ALFRED_WAKE_BUZZ_CHANNELS` | *(all visible)* | Restrict to `<channel-id>[:<label>],…` |
| `ALFRED_WAKE_BUZZ_NAMES` | — | `<pubkey>:<name>,…` to make `from=` readable (the sidecar exposes no name lookup) |
| `ALFRED_WAKE_INTERVAL` | `20` | Tick seconds |
| `ALFRED_WAKE_AM_INTERVAL` / `ALFRED_WAKE_AM_MAX_INTERVAL` | `60` / `600` | agent-messaging poll interval and failure-backoff ceiling |
| `ALFRED_WAKE_BUZZ_CHANNEL_REFRESH` | `900` | How often the channel list is re-read and an absent sidecar re-probed |
| `ALFRED_WAKE_STATE_DIR` | `/workspace/.alfred-wake`, else `$XDG_STATE_HOME/alfred-wake` | Where cursors live |
| `ALFRED_WAKE_TZ` | `Europe/Amsterdam` | Timezone for `last=` timestamps |
| `ALFRED_WAKE_BIN_DIR` | `$HOME/.local/bin` | Target of `alfred-wake install` |

### State

State dir defaults to **`/workspace/.alfred-wake`** when `/workspace` is
writable, because in a devbox pod only the workspace PVC is reliably
persistent — `$HOME` comes from the image on scaffolded-project devboxes.
Cursors on ephemeral storage mean a restarted lead replays its whole history as
"new". Mode 700; created on first run.

| File | Purpose |
|---|---|
| `am_state.json` | Sorted unread agent-messaging ids from the last pass — diffed to find genuinely new arrivals |
| `buzz_channel_<channel-id>.json` | Per-channel `last_created_at` cursor + `seeded` flag. One file per channel, so channels never clobber each other |
| `buzz_identity.json` | Own Buzz pubkey (used to filter out your own posts) |
| `failures.json` | Per-source consecutive-failure count + last-reported timestamp |
| `armed` | Touched every pass by `run`; `status` and `/alfred-agent:check-messages` read its mtime |
| `.initialized` | Marker — its absence means "first run, seed only, don't replay" |
| `alfred-wake.log` | One line per pass: timestamp + counts only, never bodies, never secrets. Rotated at ~1 MB |

Delete the state dir to force a fresh seed.

### Security invariants

- No token, header value, private key or message body is ever printed, logged
  or placed in argv. curl auth goes through a `-K` config file written in a
  `umask 077` temp dir and removed on exit.
- No `set -x`, ever.
- The Buzz private key is never read by this script; the sidecar holds it.
- Read-only against both services — no mark-as-read, no sends, no posts. The
  woken session decides what to do.

### Status of the roll-out

| Agent | Today |
|---|---|
| **hub** (`alfred-platform`) | Its own `scripts/hub/wake-bridge.sh` on platform-ops, live since 2026-09-10; polls agent-messaging + Buzz channels via the `buzz` CLI |
| **Metis** | In-session Monitor polling its buzz-mcp sidecar (20 s) + inbox, re-armed at bootstrap — the pattern this script generalises |
| **Zelda** | Out of scope: the Hermes runtime holds its own relay socket |
| **every other lead** | 15-minute inbox loops — this is what `alfred-wake` replaces |

Pilot order (alfred-platform#835): the RRReis lead first (agent-messaging only —
that devbox has no Buzz identity), then all leads.

## Agent identity convention

Each agent has a unique `agent_id` set via the `AGENT_ID` env var. Choose a stable identifier — other agents will address you by that name.

In multi-agent project setups, only the project's lead agent typically gets a messaging identity. Worker agents are spawned by the lead and their output flows back through the lead's session.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `/plugin install` errors with `ssh: not found` | Container has no ssh binary; SSH default chosen | `git config insteadOf` rewrites (step 2) |
| `/plugin install` errors with `terminal prompts disabled` (HTTPS) | Repo private / no credential helper | The marketplace + plugin repos are public; verify you're using the HTTPS URL form in step 3 |
| `MCP server failed to connect` | Required env var missing or empty | `/mcp` to see error; check env vars per step 1 |
| Messages reach the service but you don't receive them | `X-Agent-ID` header mismatch | Verify your `AGENT_ID` env matches what senders address |
| `WARNING: no wake bridge armed` from `/alfred-agent:check-messages` | No `alfred-wake run` Monitor in this session | Arm it (see [Arming it](#arming-it)); `alfred-wake status` shows the marker age |
| Wake bridge silent while messages arrive | Wrong or missing `AGENT_MESSAGING_TOKEN` / `AGENT_ID` | `alfred-wake check` — it prints the resolved URL, auth mode and agent id, and any `WAKE-ERROR` reason |
| Buzz never wakes you | No buzz-mcp sidecar in the pod, or no Buzz identity | `alfred-wake check` says `buzz: no sidecar …`. Expected for leads without a Buzz identity — it is not an error |

## Related

- [agent-messaging service source](https://github.com/Screenfields/alfred-agent-messaging) — the MCP server this plugin talks to
- [alfred-cc-tools marketplace](https://github.com/Screenfields/alfred-cc-tools) — the marketplace this plugin is published to
