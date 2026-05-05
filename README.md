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
      "url": "${AGENT_MESSAGING_URL:-https://agent-messaging.screenfields.dev/mcp/}",
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

## Commands

Type `/aawf:` to see available commands:

### aawf:check-messages

Quick check for new unread messages.

```
/aawf:check-messages
```

### aawf:show-inbox

Full inbox view with threads and unread counts.

```
/aawf:show-inbox
```

### aawf:show-threads

List conversation threads, optionally filtered by agent.

```
/aawf:show-threads
/aawf:show-threads project-manager
```

## Skills

### messaging

Provides context about agent messaging tools and workflows. Claude can use this automatically when working with inter-agent communication.

## Agent Identity

Each project should configure a unique `X-Agent-ID` in their MCP configuration:

| Project | X-Agent-ID |
|---------|------------|
| alfred-platform | `alfred-platform` |
| alfred-agent-messaging | `alfred-agent-messaging` |
| secret-service | `secret-service` |
| project-manager | `project-manager` |

## Related Documentation

- [agent-messaging service](https://github.com/Screenfields/alfred-agent-messaging)
- [Alfred Platform](https://github.com/Screenfields/alfred-platform)
