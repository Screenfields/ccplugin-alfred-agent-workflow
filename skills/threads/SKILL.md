---
name: amsg:threads
description: List all conversation threads with other agents via agent-messaging MCP service
user-invocable: true
disable-model-invocation: true
argument-hint: [agent-id]
---

# List Agent Message Threads

List conversation threads, optionally filtered by agent.

## Arguments

`$ARGUMENTS` (optional): Agent ID to filter threads (e.g., `alfred-agent-messaging`)

## Instructions

1. If `$ARGUMENTS` provided:
   - Call `mcp__agent-messaging__list_threads(with_agent=$ARGUMENTS)`
2. Otherwise:
   - Call `mcp__agent-messaging__list_threads()`
3. For each thread, display:
   - Thread ID
   - Participants (from/to agents)
   - Subject
   - Message count
   - Last activity (relative time)
   - Unread indicator if applicable
4. If no threads found, report "No conversation threads"
5. Offer to view full thread details

## Output Format

```
💬 Conversation Threads
━━━━━━━━━━━━━━━━━━━━━━━

Thread: {thread_id}
With: {other_agent}
Subject: {subject}
Messages: {count} | Last: {relative_time}
{unread_indicator}

───────────────────

Thread: {thread_id}
...
```

## Usage Examples

```
/amsg:threads                     # All threads
/amsg:threads project-manager     # Threads with project-manager only
```

## Dependencies

Requires `agent-messaging` MCP server to be configured.
