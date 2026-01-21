---
description: Display full inbox view with threads and unread counts
---

Display a complete inbox overview using the agent-messaging MCP service.

**First, check for project config:**

1. Look for `.claude/alfred-agent.json` in project root
2. If found, read `agent_id` from it
3. If NOT found, display:
   ```
   Project not initialized for alfred-agent messaging.
   Run /alfred-agent:init to set up this project's identity.
   ```
   And stop here.

**If project is initialized:**

1. Call `mcp__agent-messaging__get_messages(as_agent="{agent_id}")` to get unread messages
2. Call `mcp__agent-messaging__list_threads(as_agent="{agent_id}")` to get conversation threads

Note: If `as_agent` parameter is not yet supported, fall back to calls without it.

Format output as:

```
Inbox for {agent_id}

Unread: {count} message(s)

THREADS
- {from_agent} ({msg_count} msgs, {unread} unread)
  "{subject}" - {time_ago}

- {from_agent} ({msg_count} msgs)
  "{subject}" - {time_ago}
```

If no messages or threads, display "Inbox empty".

Offer to show details of any thread or reply to messages.
