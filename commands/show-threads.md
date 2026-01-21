---
description: List all conversation threads with other agents
---

List conversation threads using the agent-messaging MCP service.

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

If arguments provided, filter by agent: `mcp__agent-messaging__list_threads(with_agent=$ARGUMENTS, as_agent="{agent_id}")`
Otherwise list all: `mcp__agent-messaging__list_threads(as_agent="{agent_id}")`

Note: If `as_agent` parameter is not yet supported, fall back to calls without it.

For each thread, display:
- Thread ID
- Participants (from/to agents)
- Subject
- Message count
- Last activity (relative time)
- Unread indicator if applicable

If no threads found, report "No conversation threads".

Offer to view full thread details if user wants.
