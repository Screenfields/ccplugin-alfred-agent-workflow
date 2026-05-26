---
description: Send a message to another agent — checks inbox first to prevent message crossing
---

Send a message to another agent. Always checks inbox first before sending.

**First, check for project config:**

1. Look for `.alfred/config.json` in project root
2. If found, read `agent_id` from it
3. If NOT found, display:
   ```
   Project not initialized for alfred-agent messaging.
   Run /alfred-agent:init to set up this project's identity.
   ```
   And stop here.

## Step 1 — Check inbox

Call `mcp__agent-messaging__get_messages(unread_only=true, as_agent="{agent_id}")`.

- If there are unread messages: display them in full (or summary if >20), mark them all read, and reply to any you can answer directly. Only after all unread messages are processed, proceed to Step 2.
- If there are no unread messages: proceed immediately to Step 2.

## Step 2 — Send the message

Collect from the user (or caller):
- `to` — recipient agent ID
- `subject` — message subject
- `body` — message body
- `thread_id` — optional, if replying to an existing thread

Then call:
- For new messages: `mcp__agent-messaging__send_message(to=..., subject=..., body=..., as_agent="{agent_id}")`
- For replies: `mcp__agent-messaging__reply(thread_id=..., body=..., from_agent="{agent_id}")`

## Rules

- Never skip Step 1. Even if you believe there are no new messages, always call `get_messages` — the watcher is best-effort, not reliable delivery.
- If Step 1 surfaces a message that makes your intended send unnecessary or changes what you should write, revise accordingly before sending.
