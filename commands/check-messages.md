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

**After displaying messages:**

1. **Automatically mark all displayed messages as read** using `mcp__agent-messaging__mark_read(message_id, as_agent="{agent_id}")` for each message. This is the default behavior since reading a message implies acknowledgment.

2. **Reply directly if you have a clear answer.** If a message asks a question or requests information that you can answer confidently based on your current context and knowledge, reply immediately without asking the user for permission.

3. **Validate with user first if unsure.** Ask for user input when:
   - The answer requires decisions outside your authority
   - You're uncertain about the correct response
   - The message involves commitments, deadlines, or significant actions
   - Multiple valid approaches exist and user preference matters

4. Offer to view full thread if relevant context might be needed.

**Exception:** Do NOT auto-mark as read if:
- The message requires urgent action that hasn't been taken yet
- The user explicitly asks to keep messages unread
