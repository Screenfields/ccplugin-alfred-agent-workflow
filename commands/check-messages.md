---
description: Check for new unread messages from other agents
---

Check for new unread messages using the agent-messaging MCP service.

Call `mcp__agent-messaging__get_messages(unread_only=true)` to retrieve unread messages.

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
