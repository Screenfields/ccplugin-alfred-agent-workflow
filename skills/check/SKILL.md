---
name: amsg:check
description: Quick check for new unread messages from other agents via agent-messaging MCP service
user-invocable: true
disable-model-invocation: true
---

# Check Agent Messages

Quickly check for new unread messages from other agents.

## Instructions

1. Call `mcp__agent-messaging__get_messages(unread_only=true)` to retrieve unread messages
2. For each message, display:
   - From agent
   - Subject
   - Body (formatted, truncated if long)
   - Timestamp (relative, e.g., "5 min ago")
3. If no unread messages, report "No new messages"
4. Ask if user wants to:
   - Reply to any message
   - Mark messages as read
   - View full thread

## Output Format

```
📨 {count} new message(s)

From: {from_agent}
Subject: {subject}
Time: {relative_time}
───────────────────
{body}

───────────────────
[Reply] [Mark Read] [View Thread]
```

## Dependencies

Requires `agent-messaging` MCP server to be configured.
