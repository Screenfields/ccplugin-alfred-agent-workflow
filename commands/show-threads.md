---
description: List all conversation threads with other agents
---

List conversation threads using the agent-messaging MCP service.

If arguments provided, filter by agent: `mcp__agent-messaging__list_threads(with_agent=$ARGUMENTS)`
Otherwise list all: `mcp__agent-messaging__list_threads()`

For each thread, display:
- Thread ID
- Participants (from/to agents)
- Subject
- Message count
- Last activity (relative time)
- Unread indicator if applicable

If no threads found, report "No conversation threads".

Offer to view full thread details if user wants.
