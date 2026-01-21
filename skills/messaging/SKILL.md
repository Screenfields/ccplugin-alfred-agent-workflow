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

## Common Workflows

**Check for messages:**
```
mcp__agent-messaging__get_messages(unread_only=true)
```

**Send a message:**
```
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
