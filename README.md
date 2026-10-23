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
| `/alfred-agent:refine` | The analyst and readiness reviewer pair, new to ready: loops the pair until the reviewer passes or the failed-review-max limit sends it to the hub. Hands the pass to the lead. Edits nothing. |
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
alfred-wake status    # config + whether a wait/run process is alive (exit 0 = a live wait with a live owner, or one with no owner file: a human shell, or a wait from an older version)
```

`status` means a live wait whose owner Claude Code process is also alive. A wait that
survived a crash of its session (an orphan) is reported as not running, so the revived session
launches its own. The one exception: a wait with no owner file (a human shell, or a wait from an
older version) counts as running, as before. An orphan can still consume
news before the revive (CCW-172 fixes that), so the unread count that SessionStart shows comes from
the service, not from what the orphan already printed.

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
| `alfred-wake status` | Print config; exit 0 only while a live `wait`/`run` process holds the pidfile and the Claude Code process that started it (the owner, recorded in `alfred-wake.owner`) is also alive. An orphaned wait (owner gone) or one with no discoverable owner (while `CLAUDE_CODE_SESSION_ID` is set) prints `armed:      no` and exits 1 |
| `alfred-wake --version` | Print the version |
| `alfred-wake status --json` | Machine-readable state for probes: `{"armed", "state": "waiting"\|"handling"\|"down", "pid", "lastWakeExitAt", "lastWakeExitAgoSeconds", "graceSeconds", "version"}`. A lead whose `wait` exited with news (any WAKE line, WAKE-ERROR included) less than `ALFRED_WAKE_HANDLING_GRACE` s ago (default 600; a non-integer value falls back to 600), with no wait started since, is `handling` and counts as armed, whatever happened to its owner. `waiting` requires a live wait with a live owner; an orphan or an unknown owner is `down`. Exit 0 when armed. The plain `status` exit code stays strict (a live wait with a live owner only), because the hooks rely on it |
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
| `… no-mark` (suffix on any `WAKE am`/`WAKE buzz` line; `wait` mode only, not the legacy `run` loop) | The current session has no work item mark: run `alfred-workitem mark <owner>/<repo>#<n>` (see [Tokens per work item](#tokens-per-work-item-binalfred-workitem)) |
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
| `ALFRED_WAKE_OWNER_COMM` | `claude` | The command name of the process that owns a wait (the nearest ancestor with this name, compared on its first 15 characters). Set it only when the harness binary has another name |
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
| `alfred-wake.owner` | The Claude Code process that started the running wait: `<pid> <starttime>`, or `unknown`. Removed with the pidfile. `unknown` means owner discovery failed (no ancestor has the owner name), not that the owner died. The rules are in the header of `bin/alfred-wake` |
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

The timestamp itself is injected per prompt (CCW-141): the `UserPromptSubmit`
hook `hooks/reply-timestamp.sh` adds the current Europe/Amsterdam time line to
every owner prompt (not machine turns or workers; the test is
`lib/owner-turn.sh`, shared with the loop check's `note-turn`). Debug log:
`ALFRED_REPLY_TS_LOG=<file>`.

Note: files in `rules/` are **not** loaded into session context by Claude Code
(verified on 2.1.296); anything every session must see goes through this hook.

## Watcher and inbox check at every session start (SessionStart hook)

A watcher is a background task of the session that started it, so it dies with that session:
`/exit` + `claude -c`, a crash, or a pod restart. This was seen live on 2026-10-14, when the hub's
bridge stayed down for 80 minutes after a session restart. `hooks/session-check.sh` runs at every
session start (`startup`, `resume`, `clear`, `compact`):
1. It checks the watcher with `alfred-wake status`, or with `ALFRED_WATCHER_STATUS_CMD` on a
   session with another bridge, such as the hub's `hub-wake-bridge status`. A wait whose owner
   Claude Code process is gone (an orphan after a crash) counts as not running. Both watcher
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
bridge, until a nudge. The plugin therefore ships a `Stop` check, `hooks/bridge-check.sh` (called
through `hooks/stop.sh`, see the loop check below), which runs `alfred-wake status` when a turn ends. That is a pid and owner check, with no network and no model call.
- **Bridge down:** it blocks the stop once with "relaunch `alfred-wake wait`", so the same turn re-arms it.
- **Still down after that relaunch:** it lets the stop through with a visible `WARNING` instead of blocking again, so it never loops.

The hook only acts on Alfred devboxes (marker: the image's `/usr/local/lib/alfred/start-helpers.sh`),
in projects with `.alfred/config.json` (an `agent_id`). The hub and workstations run other bridges
and are left alone. `ALFRED_WAKE_STOP_CHECK=1` forces the check on; `=0` switches it off.

## Lead agreement and routed rules (SessionStart and SubagentStart hook)

`hooks/routed-context.sh` delivers the lead agreement and the role-routed rules (ccplugin#127,
AP-ADR0021, AP-ADR0031). It is a separate hook from `doctrines-context.sh`, so neither string
grows past the hook cap (a test enforces 9,500 characters for each).
- **Lead** (any `agent_id` in `.alfred/config.json` other than `hub` and `alfred`): the agreement
  from `agreement/lead.md`, then the `all` and `lead` rules.
- **Hub and Alfred:** the `all` rules only. Their process part lives in the hub charter and
  `alfred/INSTRUCTIONS.md`.
- **No `.alfred/config.json`:** nothing.
- **`ALFRED_ROLE=worker`** (set by worker and test launchers): the worker rules, never the agreement
  and never the loop check.
- **Subagents** (SubagentStart, every agent type): the `all` and `worker` rules, nothing for leads.

The rules are `rules/routed/*.md`, one file each, in AP-ADR0021 format (frontmatter `name`,
`roles`, `work`, `severity`, then one statement with its reason). They sit outside the
`rules/*.md` glob of `doctrines-context.sh`, so nothing is delivered twice. The GitOps rule lives
there too (`author-gitops-pr-never-self-approve`, lead only).

## Thresholds (`config/thresholds.json`, `bin/alfred-config`)

All thresholds live in one file and are read by name, so no rule or skill text carries a number:
`alfred-config get wip-limit`. An unknown name, or a missing or malformed file, exits 2.
`alfred-config names` lists the keys. A bats test fails when a new text contains a digit or a
percent sign (other than `AP-ADRnnnn`, `AP-nnnn`, `AP#nnnn` and `doctrine NN`) or names a
threshold that does not resolve.

`model-setting-per-role` holds one tier and effort per role. `reviewer-light` is the lighter reviewer
setting for small items: the light path of `develop` starts the reviewer with it. No document defines
that setting as a value, so it is one named key next to `reviewer`, with the value
`{"tier":"medium","effort":"medium"}` (the choice recorded in ccplugin#129). The tier and the effort map
to the `model` and `effort` of a specialist as described under "Specialists (`agents/`)".

## Loop check at the end of every turn (Stop hook)

A lead keeps working while it has actionable items or unread direct messages. At the end of a
turn `bin/alfred-loop-check --hook` decides, with `gh` and one inbox call and no model call,
whether to block the stop once. Items waiting on the owner never hold the loop open.

- **Actionable set:** open issues in the lead's repos that carry a label in `workable-states` and
  not the `waiting-label` (`status:waiting-on-owner`). Once the not-ready items number at least
  `wip-limit` (counted over all repos together), only they count; below it the ready ones count
  too. An unread **direct** agent-messaging message counts as well (`alfred-wake unread --direct`);
  topic posts do not. `worker-limit` is not used: the hook cannot see a builder bound.
- **Parking:** add the `waiting-label` and comment the question. The item keeps its state label.
  `/alfred-agent:waiting` lists these items and, once the owner answers, records the decision and
  removes the label.
- **`repos` key:** `.alfred/config.json` takes `{"agent_id": "...", "repos": ["owner/name", ...]}`.
  Without `repos` the check uses the working directory's `origin` remote. The label names must
  exist in each repo; a repo that has open issues but none with a state or waiting label gives a
  warning and counts as empty.
- **Block, at most once per unchanged set.** The signature is the sorted actionable items with their
  labels plus the unread direct count. The same signature does not block again inside
  `chase-interval-minutes`. Inside a chain (`stop_hook_active`) the stored state is the guard
  whatever its age: a different signature blocks, the same one is allowed with friction, and a
  missing state is allowed, so expiry or a fail-open stop can never cause a second block. Only
  outside a chain does an old state (past the chase interval) let the same set block again.
  Issue titles in the block reason are untrusted: control characters, backticks and quotes are
  removed and each is cut to about 100 characters, and the list is labelled as data.
  If the state cannot be written, the stop is allowed with a warning.
  A stop that is allowed because nothing changed prints a warning and appends one line to
  `${CLAUDE_CONFIG_DIR:-~/.claude}/alfred-loop/friction.jsonl` (local only).
- **Chase, then escalate:** an item that is still unchanged after `chase-max-tries` blocks makes
  the block reason say to escalate to the hub and record it on the item. The count resets when the
  item's labels change.
- **Owner present:** `bin/alfred-loop-check note-turn` (UserPromptSubmit) records whether the turn
  started with the owner. In an interactive session (`CLAUDE_CODE_ENTRYPOINT` is `cli`, `claude-vscode` or
  `claude-desktop`; anything else, or unset, is a machine), a prompt without a machine prefix
  (`<task-notification>`, `<cross-session-message`, `[substrate wake]`, `<scheduled-task`) is an
  owner turn. The next stop then only adds a one-line note and consumes the marker, so a later
  stop without a new prompt blocks normally. Unknown counts as a machine turn.
- **Cap:** at most `loop-check-max-blocks-per-hour` blocks per session.
- **Kill switch:** `ALFRED_LOOP_CHECK=0` or `"loop-check-enabled": false` in the thresholds.
- **Silent** without `.alfred/config.json`, for the `hub` and `alfred` ids under the plugin entry,
  and for `ALFRED_ROLE=worker`.

### One Stop entry

`hooks/stop.sh` is the plugin's only Stop entry for this: it runs `bridge-check.sh` (unchanged)
and the loop check with the same stdin, and emits **at most one JSON object**. Precedence: a block
from either part blocks, with one reason (a paragraph for the bridge, then the items and inbox);
all warnings are joined into one `systemMessage`. Garbage or a timeout from a part becomes a
warning, never raw output and never a block. Worst case is 5 s for the bridge plus
`loop-check-deadline-seconds` for the loop part, under the entry's 20 s timeout. Hook-mode scripts
use no `set -e`/`set -u` and always exit 0 (CI audits this); a syntax error would exit 2, which
blocks, so CI also runs `bash -n` on every hook.

### Required binaries

`jq`, `gh` (authenticated), `timeout` (coreutils) and `alfred-wake` (with `curl`). If one is
missing, the check allows the stop with `skipped, missing binary: <name>`.

### Warning strings

Printed on stderr as `alfred-loop-check: <text>` (and, where the stop decision changed, in the
`systemMessage`). Stable text, for grep:
`skipped, missing binary: <name>` · `bad hook input, stop allowed` · `config malformed (<path>), stop allowed` ·
`thresholds file missing or malformed (<path>), stop allowed` · `no session_id in the hook input, stop allowed` ·
`<repo>: gh timed out` · `<repo>: gh failed (exit N): ...` · `<repo>: gh output is not a JSON list` ·
`<repo>: 500 open items, later ones are not seen` · `no status labels in <repo>` ·
`no repos to check (no repos key in the config, no origin remote)` · `inbox unreachable (...)` ·
`inbox scan partial: ...` · `all sources failed, stop allowed` · `some sources failed, stop allowed` ·
`block cap reached, stop allowed` · `no state for this chain, stop allowed` ·
`no progress since the last block, stop allowed`. From `stop.sh`: `<bridge|loop> part gave unusable output, ignored`
and `<bridge|loop> part timed out, stop allowed`.

### Known false blocks

- A change from outside the session (a teammate moves or opens an item) changes the signature, so
  the next stop can block once for work the lead did not cause.
- An item that waits on someone without the `waiting-label` (a hub gate, a background builder)
  stays actionable and is chased every `chase-interval-minutes` until it is parked or escalated.
- With several repos, when one repo call fails and no state exists yet, the set from the repos
  that answered can still block.

### Known false allows

- A repo whose issues carry none of the state labels is read as empty (the warning above says so).
- A direct message behind more than 100 unread messages that are all topic posts is missed (the
  partial-scan warning says so).
- Items past the 500th open issue of a repo are not seen.
- A stop that fails open (any error, timeout, missing input) is allowed.

### Reusing the check from the hub and Alfred

The script runs outside the plugin's hook entry with an explicit config path, thresholds and level.
The hub and Alfred keep their own actionable sets by passing their own `workable-states` and
`waiting-label` in their own thresholds file (required keys: `waiting-label`, `workable-states`,
`wip-limit`; optional: `ready-state`, `loop-check-timeout-seconds`, `chase-interval-minutes`,
`chase-max-tries`, `loop-check-max-blocks-per-hour`, `loop-check-enabled`). From another Stop setup:

```bash
alfred-loop-check --level hub --config /path/config.json --thresholds /path/thresholds.json --hook
```

with the Stop hook JSON on stdin; it prints Stop hook JSON or nothing and always exits 0. Without
`--hook` it prints `{items, direct_unread, warnings}`. Combine it with another Stop check the way
`hooks/stop.sh` does: one stdin copy per part, one JSON object out, children killed in a trap.

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
  The reminder is skipped for non-interactive sessions and for `ALFRED_ROLE=worker` (they cannot mark).
  No notice is sent (the deviation is still recorded in `deviations.jsonl` with `notified: suppressed:<reason>`)
  when the unmarked window is under `deviation-min-seconds` (60), the session is non-interactive
  (`CLAUDE_CODE_ENTRYPOINT` not `cli`, `claude-vscode` or `claude-desktop`, or unset), or there are no store
  amounts and the transcript shows no tool calls.
- **Operational work.** Each lead opens its own standing issue in its main repo, titled `Standing: <project> operations (objective 1)` (with the repo's code prefix, as for any issue), and marks operational turns on it with `alfred-workitem mark <owner>/<repo>#<n>`. Operational turns are inbox handling, wakes, reviews, merges, and pin bumps with no item of their own (AP-ADR0028).
  The hub names its number; it is not recorded here yet.
- **Store env** (set by the hub in gitops): `AGENT_RUNS_OTLP_LOGS_ENDPOINT`, `AGENT_RUNS_OTLP_HEADERS`
  (comma-separated, each `Name: value` or the OTLP form `key=value`), `AGENT_RUNS_READER_URL`, `AGENT_RUNS_TOKEN`. Hooks cannot see
  `OTEL_*` (Claude Code strips it). **Every command fails open**: a missing env, an unreachable store
  or bad JSON gives a stderr warning, exit 0 and "unknown" in the output.
- **Local state** is under `${CLAUDE_CONFIG_DIR:-~/.claude}/alfred-workitem/`: one mark file per
  session (removed after 90 days unused), a sent-count state file, and `deviations.jsonl`. Nothing is
  written into a repository.
- Marker and read formats: `tests/fixtures/workitem/` (`marker-*.json`, `workitems*.json`).

## Review gate (`bin/alfred-review`)

The review flow posts a real GitHub review at the head that was reviewed, with the `review` token. The
merge skill asks GitHub for its own verdict and merges pinned to that head. This is what lets the
`lead-review` ruleset (AP-1230) run on a repo without blocking its lead. `bin/alfred-review` is bash,
`gh` and `jq`, with no model call.

Gate 1 and Gate 2 of `change-gates.md` in alfred-platform, including `review/verdict`, apply to alfred-platform and alfred-platform-docs only (v1 scope), and for lead repos AP-1230 is the review gate: the `lead-review` ruleset plus `reviewDecision`, as `alfred-review` and the merge skill implement it. The table "Gate 2 mapping (lead repos)" below shows how each Gate 2 requirement is met there.

```bash
alfred-review post <owner>/<repo>#<n> --sha <40-hex> --verdict approve|request-changes --body-file <file>
alfred-review check <owner>/<repo>#<n>
```

- **`post`** sends `commit_id` (always the reviewed SHA), the event and the body, through `gh-as review`
  only. It never uses the lead token or another role. A moved head posts nothing (exit 3). The first body
  line is `Reviewed by: <agent_id> (alfred-agent:review)`. A body over 65,000 characters is cut to fit,
  with a note, and the verdict is still posted. A timeout on the POST is not retried blindly: it lists the
  reviews first and does not post twice.
- **`check`** reads GitHub's verdict (`reviewDecision`, `headRefOid`, `mergeStateStatus`, the PR author)
  with the active role and recounts nothing. Its output separates GitHub's verdict from the plugin's
  policy:

  ```
  decision: approved|not-required|review-required|changes-requested|blocked|error
  github-verdict: APPROVED|REVIEW_REQUIRED|CHANGES_REQUESTED|none
  plugin-policy: ok|change-request-blocks|merge-state-blocked
  head: <40-hex>      (the merge skill merges with --match-head-commit of this value)
  merge-state: <mergeStateStatus>
  ```

  `UNKNOWN` merge state (right after a push) is retried 3 times. `BEHIND`, `DIRTY` and `DRAFT` pass with
  guidance; `BLOCKED` with an approval exits 10; any value it does not know fails closed (6).

### Exit codes

Both commands. Transient errors (HTTP 5xx, rate limit, timeout, connection failure) are retried 3 times
(1, 2, 4 s) before exit 6.

| Code | Meaning |
|---|---|
| 0 | ok: posted, or approved, or approval not required |
| 2 | argument or environment error (malformed reference, SHA not 40 hex, unknown verdict, missing or empty body file, `GH_TOKEN` set) |
| 3 | head moved (`post`): reviewed one SHA, the PR is at another; review again |
| 4 | no review token file on this devbox (`post`), and only then |
| 5 | access: 404 or 403 (`post` prints the widen ask; `check`: no read access to the PR) |
| 6 | API failure: transient error after retries, bad JSON, unexpected value, 401, 422 |
| 10 | not approved, or approved but BLOCKED (`check`) |
| 11 | a change request is outstanding (`check`) |

### Identities and tokens

- `build`, `spec` and `review` come from one app, `alfred-worker-agent`, so on GitHub they are one login,
  `alfred-worker-agent[bot]`, on every devbox. `lead` and `gitops-lead` come from `alfred-lead-agent`.
- GitHub counts no approval from the PR's author or its last pusher. So **the lead role pushes, creates
  the PR and merges; the review identity reviews**. Workers only commit, with any author. A push made
  with `build` makes the reviewer the last pusher, and then no approval counts. `develop` switches to the
  lead role before every `git push` and `gh pr create`.
- The `review` token is `/var/run/secrets/gh-review/token` (`ALFRED_SECRETS_DIR`), used through `gh-as
  review`. It reaches the lead's own repos by default. `post` tests for that file itself, because on a
  single-role devbox `gh-as` would silently fall back to a read-only token. `gh-as` refuses to run with
  `GH_TOKEN` set; `post` reports that (exit 2) and never works around it.
- **Another lead's review is observability.** That lead reviews from its own devbox and posts with the
  same command, but on GitHub it is the same login as any other lead's review, so any lead's review token
  can supersede a change request left by another. The body's `Reviewed by:` line is how people tell them
  apart, and `check` warns (stderr, never the exit code) when an approval by one agent supersedes a change
  request by another. The shared-login risk is accepted on AP-1230; a dedicated review app is the remedy.
- **Widen ask.** When `post` reports no access (exit 5), message `hub` with the subject
  `[review-access] <reviewing-lead> -> <owner/repo>`, the reviewing lead, the target repo, the PR URL or
  reason, and whether the access is standing or for this PR only. The new token takes effect after the
  ESO refresh, so access is not immediate.

### Change requests

A reviewer's no means no, even where GitHub requires no review. `check` exits 11 when the latest decisive
review (APPROVED, CHANGES_REQUESTED or DISMISSED) by any reviewer is CHANGES_REQUESTED, whether
`reviewDecision` is CHANGES_REQUESTED or `null`; the output then says that the plugin, not GitHub, blocks
when GitHub requires nothing. The reviews list is read to decide only in those two cases (and, as a
warning-only check, when the decision is approved). A change request is cleared by its author
re-reviewing at the new head. Nothing in the plugin dismisses a review: the hub does, with a written
reason.

### Merge and the hub

`/alfred-agent:merge` runs `alfred-review check` between the CI gate and the label gate, stops on any
non-zero exit, and merges with `--match-head-commit`. It refuses `alfred-platform-manager` ("the hub
merges with platform-gh, not this skill"); `alfred-project-manager` merges its own PRs through it like
any lead. The hub merges a PR labelled `requires-elevated-merge` outside the skill.

### Gate 2 mapping (lead repos)

One row per requirement of Gate 2 in `change-gates.md`, with the AP-1230 mechanism and its evidence. Evidence is a `tests/review-gate.bats` test title, a live step of the CCW-145 closing comment, or `gap`. A gap is accepted by the owner's option A (ccplugin#129, 2026-10-23).

| # | Keyword | AP-1230 mechanism | Evidence |
|---|---|---|---|
| 1 | **head SHA** | `reviewDecision` at the current head; the ruleset dismisses stale approvals; the merge skill merges with `--match-head-commit` | `post refuses when head moved`, `merge skill passes --match-head-commit from the check`, CCW-145 6353161637 step C. Dismissal of stale approvals is a ruleset setting, shown live only. |
| 2 | **other than the PR author** | GitHub forbids self-approval; the ruleset requires last-push approval | `author is the review identity gives the author message`, `check words the last pusher as likely`, CCW-145 6353161637 steps E and F |
| 3 | **allowlist** | none; any identity with review rights counts | `gap`, accepted by option A |
| 4 | **ADVISORY** | an approval passes; APPROVE WITH COMMENTS posts as `approve` (`skills/review-panel/SKILL.md`); a change request blocks with exit 11. A later approval by the same login supersedes a change request, so a failure is not sticky per SHA. | `check maps APPROVED (probe S1)`, `check maps CHANGES_REQUESTED`, `null with a later approve by the same login exits 0`. The non-sticky failure is a `gap`, accepted by option A. |
| 5 | **regardless of CI** | merge Step 5 is a hard gate that stops on any non-zero exit, with no identity branch | `merge skill calls alfred-review check before the label gate`, `merge skill stops on any non-zero exit`, `check has no identity branch` |
| 6 | **author ≠ reviewer ≠ merger** | the reviewer (`alfred-worker-agent[bot]`) differs from both the author and the merger, which is the lead role | `author is the review identity gives the author message`. Author ≠ merger is a `gap` (the lead authors and merges), accepted by option A. |
| 7 | **Review panel verdict** comment | none; the review body is the record (`post` writes a `Reviewed by:` first line) | `gap`, accepted by option A |

### Runbook

| Exit | Symptom | Cause | Remedy |
|---|---|---|---|
| 4 | "no review token on this devbox" | no `gh-review/token` file (for example a single-role devbox) | where `check` says approval is not required, continue without a post; otherwise ask the hub for a review token |
| 5 | "the review token has no access to <repo>" (`post`), or "no read access" (`check`) | the token's repo list does not include the repo | send the widen ask (above) and wait for the ESO refresh; meanwhile use the lead's own review sub-agent |
| 6 | API failure after 3 retries, bad JSON, 401, 422 | GitHub or network trouble, or a rejected request | wait and run again; if it persists, report the failing service and do not work around it |
| 10 | `review-required` | no approval at the head; the PR author is the review identity (recreate the PR with the lead role); the last pusher may be the review identity (push the final commit with the lead role); too few approvals | review at the current head and post; for the author and last-pusher cases follow `develop`, section "PRs already in flight". BLOCKED (decision `blocked`): GitHub reports the review as approved but another rule is unmet (a required check or an unresolved conversation); see `gh pr view` |
| 11 | `changes-requested` | a reviewer's latest decisive review is CHANGES_REQUESTED | fix, push with the lead role, and ask the lead who requested the changes to re-review; if they are gone or do not respond, ask the hub, which dismisses the review with a written reason |

`APPROVED` with a persistent `UNKNOWN` passes on `reviewDecision`, and GitHub's merge still enforces the rule.

### Local log and measures

Each run appends one JSON line `{ts, cmd, repo, pr, exit, reason, decision, warning}` to
`${CLAUDE_CONFIG_DIR:-~/.claude}/alfred-review/runs.jsonl` (never a token or a body; it is not rotated).
`reason` is `ok`, `argument`, `head-moved`, `no-token`, `access` or `api`. Weekly counts of exits 2, 4, 5,
6, 10 and 11 by `reason` show API trouble (6), token scope gaps (5) and merges attempted unreviewed (10,
11). The measure the hub reads is GitHub refusals of a merge for the review rule after rollout (target
0); refusals for other reasons, such as failing checks or conflicts, do not count.

### Rollout (hub-owned)

Staged: canary (`ccplugin-alfred-agent-workflow`), then one multi-lead repo, then wider. Before a repo's
`lead-review` ruleset goes on it needs no open PR authored by the review identity, a review token on the
lead's devbox, and this plugin version installed. Turning the repo's ruleset off is the rollback.
`Screenfields/ccplugin-alfred-content` already has `lead-review` (ruleset 25678306) live, with manual
`review` approvals until this version ships.

## Specialists (`agents/`)

Eleven specialist definitions (ccplugin#128, AP-ADR0030, AP-ADR0031). A lead starts a specialist by
name instead of writing role text into each brief. Each definition holds the role's job, order,
what it never does, and what its output carries. The work-and-review pattern (author, then paired
reviewer, then the fix to the same pair) is the routed rule `work-and-review-in-pairs`.

| Specialist | Paired reviewer | Tools | Model, effort |
|---|---|---|---|
| `analyst` | `readiness-reviewer` | read-only, edits the item body in the brief | sonnet, high |
| `readiness-reviewer` | `analyst` | read-only | sonnet, high |
| `designer` | `design-reviewer` | read-only, edits the `## Design` section named in the brief | opus, high |
| `design-reviewer` | designer (when enabled), otherwise the lead or Alfred | read-only | sonnet, high |
| `builder` | `code-reviewer` (code), `document-reviewer` (docs only) | read and write | sonnet, medium |
| `code-reviewer` | `builder` | read-only | sonnet, high |
| `technical-writer` | `document-reviewer` | read and write | sonnet, medium |
| `document-reviewer` | `technical-writer`, or the session that wrote the document | read-only | sonnet, high |
| `acceptance-reviewer` | the lead, who claims done | read-only | sonnet, high |
| `incident-reviewer` | the hub, who chooses the mitigation | read-only | opus, max |
| `investigator` | none | `Read, Grep, Glob, WebFetch`, read-only Metis tools | haiku, low |

`designer` writes the design for a ready item, naming its precedent or the alternatives; pairs with the design reviewer; opt-in (`designer-enabled`). The switch `designer-enabled` is a boolean in `config/thresholds.json`, default `false`, read with `alfred-config get designer-enabled` like `loop-check-enabled`. Until `skills/design` reads the switch, a lead uses the designer by starting `alfred-agent:designer` with the Agent tool. The switch changes nothing yet. The designer's brief carries the work item, whose `## Design` section is the write target, the precedent link with its passage, the installed `doctrines/` path, the absolute path to `skills/platform-design-basis/SKILL.md` as the fallback, and passages for any platform references the skill points at. A lead that uses the designer does not add its own `Precedent:` line. The designer writes it. The designer preloads the core skill `skills/platform-design-basis/SKILL.md`. Its model and effort (`opus`, `high`) are an unmeasured starting candidate with no source.

`model` and `effort` follow `model-setting-per-role` in `config/thresholds.json`
(`light`/`medium`/`strong` are `haiku`/`sonnet`/`opus`; effort `highest` is `max`). A role whose
config entry is `default` has no `model` or `effort` line. `tests/specialists-config.bats` fails
when a definition drifts from the config.

### Phase skills and their pairs

Each phase skill names the specialist or the format that belongs to its phase. The rule for the pair lives in the routed rule `work-and-review-in-pairs` and the lead agreement. The skill carries the steps.

| Skill | Gains | Specialists it names |
|---|---|---|
| `refine` | the analyst and readiness reviewer pair, new to ready | `analyst`, `readiness-reviewer` |
| `design` | the design reviewer pair, and the owner's approval of a large item's design before it is marked complete, with `alfred-agent:ecr` for the expert consulting review | `design-reviewer` |
| `develop` | the builder and code reviewer pair, and the light path for small items, which starts the reviewer with the `reviewer-light` setting | `builder`, `code-reviewer`, `document-reviewer` |
| `merge` | the review-record check (`alfred-review check`, see "Review gate") | none |
| `retro` | one agenda for every level, and the friction line for small items | none |
| `waiting` (`/alfred-agent:waiting`) | the owner-join and owner-question format, by reference to `hooks/owner-communication.md`, and urgent requests for the hub and Alfred | none |
| `troubleshoot` | the section "Incident handling (hub)", with diagnose, mitigate, incident reviewer, then a sized fix | `incident-reviewer` |

### Starting one

From a lead session, use the Agent tool with the specialist's name, for example
`alfred-agent:code-reviewer` (the plugin lists them in the `--agent` error message; the bare
`code-reviewer` resolves too). From the command line:

```bash
claude -p --agent alfred-agent:code-reviewer "Review PR 12 against issue 9 ..."
```

A subagent receives its definition, the `all` and `worker` rules (SubagentStart) and its brief.
Nothing for leads.

The investigator reads Metis through the read-only tools in its `tools:` list
(`mcp__metis__query`, `search_notes`, `read_note`, `get_dependants`, `get_provenance`,
`get_vault_profile`, `list_zone`); GitHub records come in through the lead's brief. Known
coupling: the allowlist names assume a project `.mcp.json` server key `metis`. A plugin-shipped
Metis server would be named `mcp__plugin_<plugin>_metis__*` and would match nothing; there are
no alias names. Where no Metis tool is available the investigator reports "Metis unavailable".

### Read-only by instruction

Only the investigator is read-only by tool list: it has no `Bash`, `Edit`, `Write` or
`NotebookEdit`, and a `tools:` allowlist leaves out every MCP tool it does not name. The analyst, the designer and the
reviewers keep `Bash` because they need `gh`, `git log` and the test runner to check claims, so
they are read-only by instruction: the definition says not to change files, branches, issues or
other state, and nothing in the tool list stops it. The analyst may edit the body of the item named in the
brief. The designer may edit the `## Design` section of that item. The code reviewer may run tests in its own scratch worktree and commit nothing.

### House style

`skills/house-style/SKILL.md` holds the writing rules. The technical writer loads it first; any
session writing a record loads it too.

### Planted-defect cases

`tests/specialists/<reviewer>/` holds one case per reviewer (`readiness`, `design`, `code`,
`document`, `acceptance`, `incident`): `case.md` is a small self-contained piece of work with
its sources quoted, and `expected.json` lists the seeded defects and names the sound part. A
reviewer passes when it finds every seeded defect and leaves the sound part alone, in both runs.

```bash
tests/specialists/run.sh probe                    # prove the answer files are unreachable; run first
tests/specialists/run.sh code --runs 2            # one reviewer
tests/specialists/run.sh design-precedent --runs 2  # the eight precedent cases against the design reviewer
tests/specialists/run.sh all                      # the six reviewers and the design-precedent cases, two runs each
tests/specialists/run.sh check design-precedent   # compare the Precedent lines of the results with expected.json
```

`run.sh` is a live runner (`claude -p`), not part of the bats job. It copies only `case.md` into
a fresh temp directory, builds the plugin from `git archive HEAD` without `tests/`, sets
`ALFRED_ROLE=worker`, and disallows `Bash`, `WebFetch` and Read, Grep and Glob on the checkout
(`Read(//abs/path/**)`: an absolute path in a rule needs the double slash, a single slash fails
open). Outputs go to `tests/specialists/results/<role>-reviewer-run<N>.md`, with usage and the session id
in the matching `.json`. The runner only collects; the starting session compares each output with
`expected.json` and records found or missed per defect and run. Run it from a commit that includes the
definitions: the plugin copy is built from `HEAD`.

`tests/specialists/design-precedent/<case>/` holds the eight precedent cases of the design
reviewer (`valid`, `missing`, `code-only`, `not-covering`, `owner-decision`, `doctrine-only`,
`none-alternatives`, `none-one-option`), each with `case.md` and `expected.json`
(`precedent`, `alternatives`, `verdict`, `blocker`, `source_note`, `sound`). `run.sh all` runs the
six reviewers and then these cases, with the same `--runs`. Result files are
`design-precedent-<case>-run<N>.md` and `.json` in `tests/specialists/results/`; a run that fails
prints `FAILED design-precedent/<case> run <N>` and the loop goes on.
`run.sh check design-precedent` needs no network and no `claude`: for each result file it
compares the `Precedent:` and `Real alternatives:` lines with `expected.json`. It reads presentation
loosely and content strictly: a line that starts with `> ` (after any indentation) is a quote of
the design note and is ignored first; then leading whitespace, one list marker (`- `, `* `, `N. `)
one pair of backticks around the whole line or the leading token, and `**…**` or `__…__` around
the leading token are stripped. It then reads by meaning (Alfred, CCW-157
comment 6356942867): identical repeated lines count once; two `Precedent:` lines with different values
conflict and read as `invalid` (fail closed, as the consumers do); when the precedent is `valid`
every `Real alternatives:` line is ignored; otherwise the first `Real alternatives:` line with a
value wins. A value must be a whole word, so `Real alternatives: not applicable` has none. The
values and the phrase must still match exactly. For `valid` it looks for `passage`, `carried` and `not read
at source` on the `Precedent:` line, in that order, case-insensitive, with an optional "the" or "was"
between them (so "The passage was carried, not read at source" counts; Alfred, CCW-157 comment
6357259459). It prints `MATCH` or `MISMATCH` per case and run and
exits non-zero on any mismatch or any case without a result file; `--runs N` also requires
`run1` to `runN`. The verdict, the blocker text and the sound part stay with the starting session.
The format of the `Precedent:` line is defined once, in `tests/helpers/design-format.bash`.

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

## Charter template and check (`templates/CHARTER.md`, `bin/alfred-charter-check`)

Every repo has a `CHARTER.md` in its root (AP-ADR0024). The leads add theirs from this template (AP-1280). Copy the template, fill the five sections, and run the check on the file:

```bash
cp "${CLAUDE_PLUGIN_ROOT}/templates/CHARTER.md" CHARTER.md
"${CLAUDE_PLUGIN_ROOT}/bin/alfred-charter-check" CHARTER.md
```

If the plugin's `bin/` is on your `PATH`, or `CLAUDE_PLUGIN_ROOT` is not set in your shell, resolve the script first:

```bash
CC=$(command -v alfred-charter-check || echo "${CLAUDE_PLUGIN_ROOT}/bin/alfred-charter-check")
"$CC" CHARTER.md
```

The five headings are `## Repo owner`, `## Objective`, `## Business case`, `## Merge rule` and `## Scope`, in that order, each once. The first four have exactly one non-blank line each. `## Scope` has at least one. Extra `##` headings are allowed only after `## Scope`. A heading needs a space, a tab or the end of the line after the hashes, so `##Notes` and `#764 ...` are ordinary lines. HTML comments are removed first, and an unclosed `<!--` fails. A fence opens on a line whose trimmed start is three backticks or three tildes. An unterminated fence runs to the end of the file, and a tilde line does not close a backtick fence. The header of `bin/alfred-charter-check` has the full rules.

The check fails on a placeholder: a line under a heading that starts with `TODO:`.

The `TODO:` match is case-insensitive, allows leading whitespace, and counts lines inside fences. It looks only under the five headings, not under extra headings after `## Scope`.

Where the register has no objective for the project, write the project's own objective as one line; the check accepts any single line under `## Objective` that does not start with `TODO:`.

The check prints `ok: <file>` and exits 0 when the charter is valid. It prints one line per fault, `<file>: <fault>: ## <Heading>` (except the unclosed-comment fault, which names the line), and exits 1 when it is not. It exits 2, with an error line and a usage line, for no argument, more than one argument, a missing or unreadable file, or a directory.

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
| `no wake bridge running` from `/alfred-agent:check-messages` | No live `alfred-wake wait` process, with a live owner, for this state dir | Start one: `Bash(command: "alfred-wake wait", run_in_background: true)`; `alfred-wake status` shows the pidfile PID and last-pass age |
| `alfred-wake status` prints `armed:      no … no owner could be found` while a wait is alive | `CLAUDE_CODE_SESSION_ID` is set but no ancestor of the wait has the owner name (`claude` by default), so `alfred-wake.owner` holds `unknown` | Set `ALFRED_WAKE_OWNER_COMM` to your Claude Code binary's process name (see `ps -o comm= -p <pid of the session>`). It must be in the environment of the process that runs `alfred-wake wait`, for example exported in the shell profile, not only set in an interactive shell. Then relaunch `alfred-wake wait` |
| Wake bridge silent while messages arrive | Wrong or missing `AGENT_MESSAGING_TOKEN` / `AGENT_ID` | `alfred-wake check` — it prints the resolved URL, auth mode and agent id, and any `WAKE-ERROR` reason |
| Buzz never wakes you | No buzz-mcp sidecar in the pod, or no Buzz identity | `alfred-wake check` says `buzz: no sidecar …`. Expected for leads without a Buzz identity — it is not an error |

## Related

- [agent-messaging service source](https://github.com/Screenfields/alfred-agent-messaging) — the MCP server this plugin talks to
- [alfred-cc-tools marketplace](https://github.com/Screenfields/alfred-cc-tools) — the marketplace this plugin is published to
