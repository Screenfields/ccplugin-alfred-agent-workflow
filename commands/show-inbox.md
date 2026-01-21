---
description: Display full inbox view with threads and unread counts
---

Display a complete inbox overview using the agent-messaging MCP service.

1. Call `mcp__agent-messaging__get_messages()` to get unread messages
2. Call `mcp__agent-messaging__list_threads()` to get conversation threads

Format output as:

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

If no messages or threads, display "Inbox empty".

Offer to show details of any thread or reply to messages.
