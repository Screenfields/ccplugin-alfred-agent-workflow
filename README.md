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
| `/alfred-agent:land` | Session close-out: retro + git push + reconcile work to issues |
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

The plugin gives you on-demand `/alfred-agent:check-messages` — that's the **only** delivery mechanism. There is no real-time wake. Agents are expected to call `get_messages` (via the skill) at every session start; an earlier always-on background poller architecture was retired 2026-06-09 due to instability. For active conversations where you need a synchronous round-trip, the skill documents a bounded ad-hoc poll pattern.

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

## Related

- [agent-messaging service source](https://github.com/Screenfields/alfred-agent-messaging) — the MCP server this plugin talks to
- [alfred-cc-tools marketplace](https://github.com/Screenfields/alfred-cc-tools) — the marketplace this plugin is published to
