---
name: messaging
description: >
  Inter-agent communication via agent-messaging MCP service. Use when sending messages
  to other agents, checking inbox, or coordinating work across projects.
---

# Agent Messaging

Send and receive messages between Alfred platform agents via MCP.

## Available MCP Tools

| Tool | Purpose |
|------|---------|
| `mcp__agent-messaging__send_message` | Send message to another agent |
| `mcp__agent-messaging__get_messages` | Get messages for current agent |
| `mcp__agent-messaging__mark_read` | Mark a message as read |
| `mcp__agent-messaging__reply` | Reply to an existing thread |
| `mcp__agent-messaging__get_thread` | Get full conversation history |
| `mcp__agent-messaging__list_threads` | List conversation threads |
| `mcp__agent-messaging__delete_thread` | Delete a thread |

## Agent Identities

Each project has a unique agent ID configured in `.mcp.json`:

| Project | X-Agent-ID |
|---------|------------|
| alfred-platform | `alfred-platform` |
| alfred-agent-messaging | `alfred-agent-messaging` |
| secret-service | `secret-service` |
| project-manager | `project-manager` |

## Mandatory pre-send rule

**Before every `send_message` call, check the inbox first.** No exceptions.

1. `mcp__agent-messaging__get_messages(unread_only=true, as_agent="{agent_id}")`
2. Display and mark-read any unread messages (full check-messages flow)
3. Only then: proceed with `send_message`

**Why:** Prevents message crossing — sending before reading a reply that makes your send redundant or incorrect. The inbox check also surfaces context that should inform what you write.

**If there are unread messages:** Process them fully (display, reply if you can, mark read) before proceeding with the send.

Use `/alfred-agent:send` to run this two-step flow as a single invocable command.

## Common Workflows

**Check for messages:**
```
mcp__agent-messaging__get_messages(unread_only=true)
```

**Send a message (always check inbox first):**
```
# Step 1: Check inbox
mcp__agent-messaging__get_messages(unread_only=true, as_agent="{agent_id}")
# … display and mark-read any unread messages …

# Step 2: Send
mcp__agent-messaging__send_message(
  to="project-manager",
  subject="Deployment request",
  body="Please review the configuration..."
)
```

**Reply to a thread:**
```
mcp__agent-messaging__reply(
  thread_id="<thread-id>",
  body="Thanks, I'll look into it."
)
```

## Prerequisites

Requires `agent-messaging` MCP server configured in `.mcp.json` with:
- CF-Access headers for Cloudflare Access
- Authorization bearer token
- X-Agent-ID header

## Discipline reminders

- **Namespace disambiguation.** When referencing cross-system artifact names (PR numbers, GitHub App identities, env names, phase labels) in a message, prefix with system+context at first mention — e.g. "PM PR #233" not "PR #233", "alfred-lead-agent App" not "the App" (Doctrine 03).
- **Scope filter.** When sending a coordination message, filter to cross-team-relevant content only — don't leak internal project work into a coordination channel (Doctrine 02).
