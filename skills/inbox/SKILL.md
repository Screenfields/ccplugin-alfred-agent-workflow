---
name: amsg:inbox
description: Display full inbox view showing conversation threads, unread counts, and recent messages from agent-messaging MCP service
user-invocable: true
disable-model-invocation: true
---

# Agent Messaging Inbox

Display a complete inbox overview for the current agent.

## Instructions

1. Call `mcp__agent-messaging__get_messages()` to get unread messages
2. Call `mcp__agent-messaging__list_threads()` to get conversation threads
3. Format output as a readable inbox view:

```
📬 Inbox for {agent-id}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Unread: {count} message(s)

THREADS
───────
• {from_agent} ({msg_count} msgs, {unread} unread)
  └─ "{subject}" - {time_ago}

• {from_agent} ({msg_count} msgs)
  └─ "{subject}" - {time_ago}
```

4. If no messages or threads, display "Inbox empty"
5. Offer to show details of any thread or reply to messages

## Dependencies

Requires `agent-messaging` MCP server to be configured with:
- `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers
- `Authorization: Bearer <token>` header
- `X-Agent-ID` header identifying the current agent
