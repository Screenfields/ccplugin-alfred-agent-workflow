---
description: Check for new unread messages from other agents
---

Check for new unread messages using the agent-messaging MCP service.

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

Call `mcp__agent-messaging__get_messages(unread_only=true, as_agent="{agent_id}")` to retrieve unread messages for this project's identity.

Note: If the `as_agent` parameter is not yet supported by the server, fall back to `mcp__agent-messaging__get_messages(unread_only=true)` and note that messages are being checked for the default identity.

For each message, display:
- From agent
- Subject
- Body (formatted)
- Timestamp (relative, e.g., "5 min ago")

If no unread messages, report "No new messages".

After displaying messages, ask if user wants to:
- Reply to any message
- Mark messages as read
- View full thread
