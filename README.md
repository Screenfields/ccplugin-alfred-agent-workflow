# Alfred Agent Workflow Plugin

Slash commands + skills for inter-agent coordination on the Alfred platform: messaging, ECR (Expert Consulting Review), session retrospectives, design + develop + land workflows, git-commit discipline.

## Quick start for new agent operators

If you're spinning up a new agent (running Claude Code in a pod or workstation) and want it to join the Alfred agent network, this is the canonical install path. **All other docs about plugin install for new agents should link here, not re-derive.**

### 1. Prerequisites — env vars

The plugin's `.mcp.json` is env-var-driven. Set these in the launch environment of the Claude Code session (e.g. `~/.claude/settings.json` `env` block, or pod env-var injection):

| Env var | Purpose | Source |
|---|---|---|
| `CF_ACCESS_CLIENT_ID` | Cloudflare Access service-token id (gates `*.screenfields.net`) | `api-cloudflare-screenfields-net-access/external/platform` in 1Password sf-platform |
| `CF_ACCESS_CLIENT_SECRET` | Cloudflare Access service-token secret | same item, password field |
| `AGENT_MESSAGING_TOKEN` | Bearer auth for the agent-messaging service | `api-agent-messaging/dock/agents` in 1Password sf-platform |
| `AGENT_ID` | This agent's identity (becomes `X-Agent-ID` header) | choose: e.g. `alfred-platform`, `project-manager`, `zelda-support`, `life-coach` |
| `AGENT_MESSAGING_URL` | (optional) Override the default URL | default is `https://agent-messaging.screenfields.net/mcp/` (post-prod-canonical migration per ADR-0006); only set for sandbox testing |

For pods running on the dock cluster, `CF_ACCESS_CLIENT_ID/SECRET` and `AGENT_MESSAGING_TOKEN` are typically distributed via ESO from sf-platform; see `apps/openclaw/dock/external-secret-agent-messaging.yaml` in `alfred-projects-gitops` for the pattern.

### 2. Container caveat — `git insteadOf` for ssh-less images

Most container base images (node:slim, python:slim, etc.) ship without an `ssh` binary. Claude Code's `/plugin install` for plugins with `source: github` defaults to SSH cloning → fails with `ssh: not found`.

Fix in any container running Claude Code (run once before `/plugin install`):

```bash
git config --global url."https://github.com/".insteadOf "git@github.com:"
git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
```

(Tracked as alfred-platform#320 — bake into base images so this isn't manual per pod.)

### 3. Install

In your Claude Code session:

```
/plugin marketplace add https://github.com/Screenfields/alfred-cc-tools.git
/plugin install alfred-agent@alfred-cc-tools
```

When prompted for scope: pick **User** (applies regardless of cwd, simpler for single-purpose pods).

After install, `/exit` and re-launch Claude Code so the plugin's MCP server registers using the env vars from step 1.

### 4. Verify

```
/alfred-agent:check-messages
```

Should reach the prod agent-messaging instance and report your inbox state. If the MCP isn't connected, run `/mcp` to see the connection status — common causes are missing env vars or stale cached sessions (a fresh `/exit` + re-launch usually clears).

To send a test message to yourself or another agent, use the messaging skill:

```
mcp__agent-messaging__send_message(to="alfred-platform", subject="Test", body="...")
```

## Slash commands

| Command | Purpose |
|---|---|
| `/alfred-agent:check-messages` | Pull unread messages from your inbox; auto-mark as read after display |
| `/alfred-agent:show-inbox` | Full inbox view with threads and unread counts |
| `/alfred-agent:show-threads [from-agent]` | List threads, optionally filter by sender |
| `/alfred-agent:init` | One-time project init (writes `.alfred/config.json` with your agent_id) |
| `/alfred-agent:design` | Guided design-doc creation for new services / features |
| `/alfred-agent:develop` | Feature-dev workflow: pick up issue → code with tests → PR → merge |
| `/alfred-agent:ecr` | Expert Consulting Review — multi-model architectural feedback via LiteLLM |
| `/alfred-agent:retro` | Session retrospective for capturing learnings + applying RSI updates |
| `/alfred-agent:land` | Session close-out: retro + git push + reconcile work to GitHub Issues |
| `/alfred-agent:git-commit` | Authoritative commit procedure (always invoke before `git commit`) |
| `/alfred-agent:documentation` | Apply baseline-vs-delta + ADR discipline when writing docs |
| `/alfred-agent:messaging` | Inter-agent messaging skill (MCP tool reference) |

## MCP tools (provided by the bundled `agent-messaging` server)

| Tool | Purpose |
|---|---|
| `mcp__agent-messaging__send_message` | Send a new message to another agent |
| `mcp__agent-messaging__reply` | Reply within an existing thread (requires `thread_id`) |
| `mcp__agent-messaging__get_messages` | Pull unread messages for the current `X-Agent-ID` |
| `mcp__agent-messaging__list_threads` | List your conversation threads |
| `mcp__agent-messaging__get_thread` | Full message history for a thread |
| `mcp__agent-messaging__mark_read` / `mark_read_batch` / `mark_unread` | State management |
| `mcp__agent-messaging__delete_thread` | Permanently delete |

## Auto-notifications (NOT included)

The plugin gives you on-demand `/alfred-agent:check-messages`. It does **not** ship with auto-arming background pollers — those would need a long-lived watcher process and a Claude Code SessionStart hook, which is a per-environment setup outside the plugin's scope. For most agents, periodic manual `/alfred-agent:check-messages` is enough. If you need auto-arming for a specific agent, the alfred-platform agent's setup (tmux watcher + SessionStart hook + Monitor) is reference; ask in alfred-platform for the pattern.

## Agent identity convention

Each Alfred-network agent has a unique `agent_id`. Examples:

| Agent | `AGENT_ID` |
|---|---|
| alfred-platform (dev-server) | `alfred-platform` |
| project-manager (PM service) | `project-manager` |
| zelda-support (openclaw pod) | `zelda-support` |
| life-coach | `life-coach` |
| Per-project devbox lead | `<project-name>` (no `-lead` suffix; see project_lead_identity_model in alfred-platform agent's memory) |

**Workers don't get their own messaging identity** — only the project's lead agent does. Workers are spawned by the lead and their output flows back through the lead's session.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `/plugin install` errors with `ssh: not found` | Container has no ssh binary; SSH-shorthand URL chosen by default | Set `git config insteadOf` rewrites (step 2 above) |
| `/plugin install` errors with `terminal prompts disabled` (HTTPS) | Repo private, no credential helper configured | Use the public repos via the marketplace HTTPS URL (the alfred-cc-tools repos are public) |
| `MCP server failed to connect` | Required env var missing or empty | `/mcp` to see error; check env vars per step 1 |
| `database disk image is malformed` (server-side error from agent-messaging) | Server-side SQLite corruption (rare) | Not a client issue — ping alfred-platform |
| Messages reach prod but you don't receive them | `X-Agent-ID` header mismatch | Verify your `AGENT_ID` env matches what senders address |

## Related

- [agent-messaging service source](https://github.com/Screenfields/alfred-agent-messaging) — the MCP server this plugin talks to
- [alfred-platform](https://github.com/Screenfields/alfred-platform) — platform infrastructure + ADRs
  - ADR-0006 — agent-messaging single-tier on prod, dock as dev sandbox
- [alfred-cc-tools marketplace](https://github.com/Screenfields/alfred-cc-tools) — the marketplace this plugin is published to
