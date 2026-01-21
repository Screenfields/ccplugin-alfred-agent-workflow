# Alfred Agent Workflow Plugin for Claude Code

Agent workflow utilities for the Alfred platform - messaging, coordination, and inter-agent communication.

## Installation

### Via Marketplace (Recommended)

```bash
/plugin marketplace add screenfields/alfred-cc-tools
/plugin install alfred-agent-workflow@alfred-cc-tools
```

### Direct Installation

```bash
claude --plugin-dir /path/to/ccplugin-alfred-agent-workflow
```

## Prerequisites

This plugin requires the `agent-messaging` MCP server to be configured in your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "agent-messaging": {
      "type": "http",
      "url": "https://agent-messaging.screenfields.dev/mcp/",
      "headers": {
        "CF-Access-Client-Id": "<cloudflare-access-id>",
        "CF-Access-Client-Secret": "<cloudflare-access-secret>",
        "Authorization": "Bearer <api-token>",
        "X-Agent-ID": "<your-agent-id>"
      }
    }
  }
}
```

## Skills

### amsg:inbox

Full inbox view showing threads, unread counts, and recent messages.

**Usage:**
```
/amsg:inbox
```

**Output:**
```
📬 Inbox for alfred-platform
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Unread: 2 messages

THREADS
───────
• alfred-agent-messaging (2 msgs, 1 unread)
  └─ "Two-way communication test" - 10 min ago
```

### amsg:check

Quick check for new unread messages.

**Usage:**
```
/amsg:check
```

**Output:**
```
📨 1 new message

From: project-manager
Subject: Deployment request
Time: 5 min ago
───────────────────
Please review the deployment configuration...
```

### amsg:threads

List conversation threads, optionally filtered by agent.

**Usage:**
```
/amsg:threads                     # All threads
/amsg:threads project-manager     # Threads with specific agent
```

## Agent Identity

Each project should configure a unique `X-Agent-ID` in their MCP configuration. This identifies the agent in conversations:

| Project | X-Agent-ID |
|---------|------------|
| alfred-platform | `alfred-platform` |
| alfred-agent-messaging | `alfred-agent-messaging` |
| secret-service | `secret-service` |
| project-manager | `project-manager` |

## Related Documentation

- [agent-messaging service](https://github.com/Screenfields/alfred-agent-messaging)
- [Alfred Platform](https://github.com/Screenfields/alfred-platform)
