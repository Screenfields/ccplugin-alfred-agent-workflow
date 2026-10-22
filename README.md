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
| `/alfred-agent:land` | Session close-out: health-check gate + retro + git push + reconcile work to issues + Metis capture. `--mode=team` skips the inline retro |
| `/alfred-agent:git-commit` | Authoritative commit procedure (always invoke before `git commit`) |
| `/alfred-agent:documentation` | Apply baseline-vs-delta + ADR discipline when writing docs |
| `/alfred-agent:messaging` | Inter-agent messaging skill (MCP tool reference) |

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
| **agent-messaging** inbox (unread for your `AGENT_ID`, direct and topic messages) | MCP JSON-RPC over HTTP (`initialize` → `notifications/initialized` → `tools/call get_messages`), polled with backoff. It asks for exactly the messages after a stored cursor (`since` / `next_cursor` / `has_more`, alfred-platform#849), so a backlog of any size neither replays nor hides a wake. A server without that API falls back to diffing a 5-message window, re-tried hourly | Yes — the service offers no push |
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
Bash(command: "alfred-wake wait", run_in_background: true)
```

If `~/.local/bin` is not on `PATH`, use the full path:
`${CLAUDE_PLUGIN_ROOT}/bin/alfred-wake wait`.

`wait` is one-shot: it stays silent while nothing is new, prints the news
line(s) as soon as there is news, and exits. The harness re-invokes the session
on that exit; the session handles the news and starts `wait` again. There is no
30-minute expiry to re-arm, and each wait leaves a normal completion record, so
a restart no longer reports a pile of unfinished background tasks. How the
session reacts to each line, and the rule that a wake without news produces no
model text, are in `commands/check-messages.md`.

Only one `wait`/`run` runs per state dir. Starting a new one stops the previous
one (SIGTERM, then SIGKILL after `ALFRED_WAKE_STOP_GRACE` seconds), which prints
`WAKE-STOPPED replaced by=<pid>` and exits 0.

There is no polling fallback: a scheduled check may not consume tokens
(platform doctrine 22). If the wait cannot start, or `WAKE-ERROR
agent-messaging` repeats, the session tells the user once and messages
`hub` ("wake bridge down on <agent_id>"); the hub's nudge-watcher
catches deaf leads deterministically.

### Verifying it

```bash
alfred-wake check     # one dry-run pass: never writes cursors, explains itself on stderr
alfred-wake status    # config + whether a wait/run process is alive (exit 0 = armed)
```

`check` is safe to run at any time: it resolves config, proves auth against both
sources, prints what it *would* have woken you with — and writes no cursor, so
it cannot swallow news that the running bridge should deliver.

### Modes

| Invocation | Behaviour |
|---|---|
| `alfred-wake wait [interval]` | One-shot: polls like `run`, prints the first news and exits 0 (2 if a `WAKE-ERROR` was printed). A first-ever run seeds cursors without a `WAKE-INIT` line, but reports mail already unread at that moment once (`pending-at-start`) |
| `alfred-wake run --until-wake` | Same as `wait` |
| `alfred-wake run [interval]` | Legacy watch loop for a `Monitor`. Default tick 20s (Buzz), agent-messaging every 60s with failure backoff to 600s |
| `alfred-wake check` | One dry-run pass, diagnostics on stderr, exit 0 |
| `alfred-wake install` | Symlink into `~/.local/bin` (override with `ALFRED_WAKE_BIN_DIR`) |
| `alfred-wake status` | Print config; exit 0 only while a live `wait`/`run` process holds the pidfile |
| `alfred-wake --version` | Print the version |
| `alfred-wake status --json` | Machine-readable state for probes: `{"armed", "state": "waiting"\|"handling"\|"down", "pid", "lastWakeExitAt", "lastWakeExitAgoSeconds", "graceSeconds", "version"}`. A lead whose `wait` exited with news (any WAKE line, WAKE-ERROR included) less than `ALFRED_WAKE_HANDLING_GRACE` s ago (default 600; a non-integer value falls back to 600), with no wait started since, is `handling` and counts as armed. Exit 0 when armed. The plain `status` exit code stays strict (a live wait only), because the hooks rely on it |
| `alfred-wake unread` | Print the agent-messaging unread count (one request; for the SessionStart check) |
| `alfred-wake notify <to> <subject> <body>` | Send one agent-messaging message as this agent; exit 0 when accepted. For deterministic callers, e.g. the devbox boot reporting Remote Control off (alfred-devbox#70) |

**Self-upgrade.** At launch, `wait` and `run` check which alfred-agent version Claude Code has
installed (`installed_plugins.json`, user scope). If that version's `alfred-wake` is newer than the
running one, they exec it with the same arguments and point the `~/.local/bin` link at it. This
needs no network and no model call. It means a devbox whose plugins were updated in the
background runs the new bridge on the next relaunch, without a restart (ccplugin#107). The upgrade
is logged as `upgrade: <old> -> <new>` in `alfred-wake.log`; stdout is unchanged. To switch it
off, set `ALFRED_WAKE_NO_UPGRADE=1`. The newer script must start (`--version`), or the upgrade is
skipped and logged; the `~/.local/bin` link is swapped atomically.

### Event lines (the stdout contract)

Only these shapes are ever printed to stdout. Anything else there is a bug.

| Line | Meaning |
|---|---|
| `WAKE am unread=<n> from=<a,b>` | New unread agent-messaging item(s); `n` = current total unread |
| `WAKE am unread=<n> from=<a,b> cursor-reset` | The server no longer knew the stored cursor: it was reseated without replaying history; `n` is what is unread now |
| `WAKE am unread=<n> from=<a,b> pending-at-start` | `wait` only: the inbox already had unread mail when the cursors were first seeded |
| `WAKE buzz <label> new=<n> from=<…> last=<HH:MM TZ>` | New non-self posts in that Buzz channel |
| `… no-mark` (suffix on any `WAKE am`/`WAKE buzz` line) | The current session has no work item mark: run `alfred-workitem mark <owner>/<repo>#<n>` (see [Tokens per work item](#tokens-per-work-item-binalfred-workitem)) |
| `WAKE-INIT …` | Legacy `run` only, first ever run: cursors seeded, history deliberately not replayed |
| `WAKE-ERROR <source>: <reason>` | A source failed 5 consecutive passes (repeats at most hourly) |
| `WAKE-RECOVERED <source>` | A previously-failing source succeeded again |
| `WAKE-STOPPED replaced by=<pid>` | `wait` only: a newer instance took over; nothing to do |
| `WAKE-STOPPED signal=<TERM\|INT\|HUP>` | `wait` only: stopped by a signal after cleaning up; start a new wait |

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
| `ALFRED_WAKE_STOP_GRACE` | `5` | Seconds a new instance waits for the previous one to exit after SIGTERM before SIGKILL |
| `ALFRED_WAKE_FAIL_THRESHOLD` | `5` | Consecutive failed passes before a source raises `WAKE-ERROR` |
| `ALFRED_WAKE_STATE_DIR` | `/workspace/.alfred-wake`, else `$XDG_STATE_HOME/alfred-wake` | Where cursors live |
| `ALFRED_WAKE_TZ` | `Europe/Amsterdam` | Timezone for `last=` timestamps |
| `ALFRED_WAKE_BIN_DIR` | `$HOME/.local/bin` | Target of `alfred-wake install`, and the link self-upgrade repoints |
| `ALFRED_WAKE_NO_UPGRADE` | — | `1` = never exec a newer installed alfred-wake |
| `ALFRED_WAKE_PLUGINS_JSON` | `$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json` | Where self-upgrade looks up the installed plugin |

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
| **hub** (`hub`; repo alfred-platform) | Its own `scripts/hub/wake-bridge.sh` on platform-ops, live since 2026-09-10; polls agent-messaging + Buzz channels via the `buzz` CLI |
| **Metis** | In-session Monitor polling its buzz-mcp sidecar (20 s) + inbox, re-armed at bootstrap — the pattern this script generalises |
| **Zelda** | Out of scope: the Hermes runtime holds its own relay socket |
| **every other lead** | 15-minute inbox loops — this is what `alfred-wake` replaces |

Pilot order (alfred-platform#835): the RRReis lead first (agent-messaging only —
that devbox has no Buzz identity), then all leads.

## Owner communication (SessionStart hook)

The plugin ships a `SessionStart` hook (`hooks/hooks.json` →
`hooks/owner-communication.sh`) that adds the rules in
`hooks/owner-communication.md` to every session's context: a fresh
Europe/Amsterdam timestamp line at the top of each chat reply to the owner,
local time for anything shown to the owner, full-URL links for every
GitHub record, and how to ask the owner a question without blocking the
session on a menu (owner-join instead; alfred-platform#917). The
hook is deterministic (`jq` only, no model call). Edit the `.md` file to
change the rules.

Note: files in `rules/` are **not** loaded into session context by Claude Code
(verified on 2.1.296); anything every session must see goes through this hook.

## Watcher and inbox check at every session start (SessionStart hook)

A watcher is a background task of the session that started it, so it dies with that session:
`/exit` + `claude -c`, a crash, or a pod restart. This was seen live on 2026-10-14, when the hub's
bridge stayed down for 80 minutes after a session restart. `hooks/session-check.sh` runs at every
session start (`startup`, `resume`, `clear`, `compact`):
1. It checks the watcher with `alfred-wake status`, or with `ALFRED_WATCHER_STATUS_CMD` on a
   session with another bridge, such as the hub's `hub-wake-bridge status`. Both watcher
   variables are shell command lines, run with `bash -c`. It also gets the unread count
   from `alfred-wake unread`.
2. It adds both to the session context. When the watcher is down or mail is waiting, it adds:
   relaunch the watcher (`ALFRED_WATCHER_START_CMD`, default `alfred-wake wait`), run
   `/alfred-agent:check-messages`, and report in one line.
3. After a `startup`/`resume` in tmux with the watcher down, it starts the one-shot
   `hooks/session-nudge.sh`. It never does this on `clear` or `compact`, where the session is
   already taking a turn. SessionStart context only acts on a first turn, and a session nobody
   types into never gets one. Up to 4 times, 20 s apart, the helper:
   - exits if the watcher runs;
   - exits if a tmux client is attached. Someone is there, and the context acts on their own
     first prompt.
   - waits if a turn is running, the prompt has input (it checks the cursor, not the ghost text),
     or a dialog or menu is on screen;
   - otherwise types a fixed `[substrate wake]` prompt into this session's own pane, re-checks all
     of the above, then presses Enter. If anything changed, it clears its text instead.

The hook only runs when a session starts, so a dormant lead is never woken by it, and nothing here
polls. It only acts in projects with `.alfred/config.json` (an `agent_id`).
- `ALFRED_SESSION_CHECK=0` switches it off.
- `ALFRED_SESSION_NUDGE=0` keeps the context but never types into the pane.

## Rules and doctrines in every session (SessionStart hook)

`hooks/doctrines-context.sh` puts two things into every session's context
(ccplugin#121, AP-ADR0021):
- every `rules/*.md` file **in full**. Each is one short judgment.
- an **index of the 22 doctrines** in `doctrines/`: one line per doctrine (number, title, its
  one-line rule), plus the path of the full texts, which the agent reads on demand.

Claude Code does not load a plugin's `rules/` folder by itself (ccplugin#110), so this hook is
how the rules reach a session. The doctrines are owned in `Screenfields/alfred-platform`
`docs/doctrines/` and copied here verbatim; see `doctrines/README.md`. The context stays under the
10,000-character hook cap, and a test enforces 9,500.

## Bridge check at the end of every turn (Stop hook)

A lead relaunches `alfred-wake wait` after every wake. If a turn ends without that, the session
stays up but deaf. This was seen live on screenfields-ai on 2026-10-14: about three hours with no
bridge, until a nudge. The plugin therefore ships a `Stop` hook, `hooks/bridge-check.sh`, which
runs `alfred-wake status` when a turn ends. That is a pid check, with no network and no model call.
- **Bridge down:** it blocks the stop once with "relaunch `alfred-wake wait`", so the same turn re-arms it.
- **Still down after that relaunch:** it lets the stop through with a visible `WARNING` instead of blocking again, so it never loops.

The hook only acts on Alfred devboxes (marker: the image's `/usr/local/lib/alfred/start-helpers.sh`),
in projects with `.alfred/config.json` (an `agent_id`). The hub and workstations run other bridges
and are left alone. `ALFRED_WAKE_STOP_CHECK=1` forces the check on; `=0` switches it off.

## Tokens per work item (`bin/alfred-workitem`)

Every action links to a work item (AP-ADR0017). The central agent-run store counts the tokens;
`bin/alfred-workitem` (bash, curl and jq, no model call) tells the store which item a session works
on and reads the totals back. It is **tracked, not gated**: nothing here stops or blocks work, and
nothing notifies on an overrun.

```bash
alfred-workitem mark <owner>/<repo>#<n>   # mark this session ($CLAUDE_CODE_SESSION_ID); `mark none` clears it
alfred-workitem check <item> [--estimate <text>] [--from D] [--to D]   # report: actual against estimate, always exit 0
alfred-workitem report <item>             # markdown table for the closing comment, one row per role x model
alfred-workitem line <item>               # one line for the review record
alfred-workitem deviations                # unmarked sessions: local record, plus the store's amounts
```

- **All token types, no unit.** Input, output, cache_read and cache_write are shown separately, with
  totals with and without cache reads. The `Estimate-tokens:` line of the item body is read once at
  `mark` and shown exactly as written (no unit conversion); the percentage is computed against the
  number and its `k`/`M` suffix, for both totals.
- **Subagents.** Brief a subagent with a `Work item: <owner>/<repo>#<n>` line and its requests book
  to that item (a `SubagentStop` hook sends the request ids). Without the line they book to the
  session's mark. `mark` itself is denied inside a subagent (`PreToolUse` guard on `agent_id`).
- **Unmarked sessions** are a deviation, not a bucket. A `UserPromptSubmit` reminder and the `no-mark`
  flag on `alfred-wake` lines ask for the mark; the `Stop` hook records the session in
  `deviations.jsonl`; the detached run at `SessionEnd` sends the hub one `[deviation] <session_id>`
  notice (`alfred-wake notify hub`). A resumed session is re-marked at `SessionStart`.
- **Operational work** without its own item goes on the standing item of objective 1 (AP-ADR0028).
  The hub names its number; it is not recorded here yet.
- **Store env** (set by the hub in gitops): `AGENT_RUNS_OTLP_LOGS_ENDPOINT`, `AGENT_RUNS_OTLP_HEADERS`
  (`Name: value`, comma-separated), `AGENT_RUNS_READER_URL`, `AGENT_RUNS_TOKEN`. Hooks cannot see
  `OTEL_*` (Claude Code strips it). **Every command fails open**: a missing env, an unreachable store
  or bad JSON gives a stderr warning, exit 0 and "unknown" in the output.
- **Local state** is under `${CLAUDE_CONFIG_DIR:-~/.claude}/alfred-workitem/`: one mark file per
  session (removed after 90 days unused), a sent-count state file, and `deviations.jsonl`. Nothing is
  written into a repository.
- Marker and read formats: `tests/fixtures/workitem/` (`marker-*.json`, `workitems*.json`).

## Theme: owner prompts stand out (`themes/owner-prompts.json`)

The plugin ships a Claude Code theme, **Owner prompts**: the dark preset with the owner's own
prompts on a blue background (`userMessageBackground: #1e3a5f`), so they are easy to find in a
long lead transcript. It appears in `/theme` as "Owner prompts from alfred-agent". Selecting it
stores `"theme": "custom:alfred-agent:owner-prompts"` in the user `settings.json`.
- **On Alfred devboxes,** the lead start (alfred-devbox) selects it when no theme has been chosen
  yet. A theme someone already picked is never overridden.
- **Anywhere else,** pick it once with `/theme`, or set that line in `~/.claude/settings.json`.

Owner suggestion (via zeus and the hub), 2026-10-15. Hooks and status lines cannot recolour
prompts; a theme can.

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
| `no wake bridge running` from `/alfred-agent:check-messages` | No live `alfred-wake wait` process for this state dir | Start one: `Bash(command: "alfred-wake wait", run_in_background: true)`; `alfred-wake status` shows the pidfile PID and last-pass age |
| Wake bridge silent while messages arrive | Wrong or missing `AGENT_MESSAGING_TOKEN` / `AGENT_ID` | `alfred-wake check` — it prints the resolved URL, auth mode and agent id, and any `WAKE-ERROR` reason |
| Buzz never wakes you | No buzz-mcp sidecar in the pod, or no Buzz identity | `alfred-wake check` says `buzz: no sidecar …`. Expected for leads without a Buzz identity — it is not an error |

## Related

- [agent-messaging service source](https://github.com/Screenfields/alfred-agent-messaging) — the MCP server this plugin talks to
- [alfred-cc-tools marketplace](https://github.com/Screenfields/alfred-cc-tools) — the marketplace this plugin is published to
