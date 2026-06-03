---
description: Check for new unread messages from other agents
---

Check for new unread messages using the agent-messaging MCP service.

## Session-start mandate

**Call `get_messages` unconditionally at every session start**, regardless of Monitor state. Monitor armed does NOT mean messages have been delivered — the inbox-watcher is a best-effort real-time supplement, not a reliable delivery channel. Silent watcher failures (process crash, log staleness, consecutive errors) leave unread messages sitting undetected for hours. `get_messages` is the reliable baseline.

**First, check for project config:**

1. Look for `.alfred/config.json` in project root
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

## Large-inbox handling (auto-summarize)

**Threshold:** If there are more than 20 unread messages, do NOT dump full message bodies. Instead, display a one-liner summary per message:

```
[{index}] From: {from_agent} | Subject: {subject} | {timestamp_relative}
```

Then display:
```
{N} unread messages — showing summaries (> 20 threshold). Request full body for specific messages by index or subject.
```

This prevents exceeding response-token budgets on large inboxes (e.g. 41 messages ≈ 68k tokens). Let the user request full bodies explicitly.

**Below threshold:** For 20 or fewer unread messages, display each message in full:
- From agent
- Subject
- Body (formatted)
- Timestamp (relative, e.g., "5 min ago")

If no unread messages, report "No new messages" then run the watcher-liveness check below.

**After displaying messages:**

1. **Automatically mark all displayed messages as read** using `mcp__agent-messaging__mark_read_batch(message_ids=[...], as_agent="{agent_id}")` with all message IDs in a single call. This is the default behavior since reading a message implies acknowledgment.

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

## Watcher-liveness assertion

After `get_messages` returns 0 unread messages, verify that the inbox-watcher is actually healthy before reporting all-clear. Run these checks:

**1. Log freshness** — check when `/workspace/.alfred/events.log` was last modified:
```bash
stat -c %Y /workspace/.alfred/events.log 2>/dev/null
```
If the file does not exist or the last modification time is more than 600 seconds ago, flag as stale.

**2. Watcher process alive** — check whether the watcher Python process is running:
```bash
ps -ef | grep alfred-inbox-watch.py | grep -v grep
```
If no output, the watcher process is not running.

**3. Consecutive error check** — inspect `watcher.err` for repeated failures:
```bash
tail -20 /workspace/.alfred/watcher.err 2>/dev/null
```
If the last 10+ lines are identical (same error repeated), the watcher is stuck in a crash loop.

**On any failure (checks 1–3):** emit a single consolidated warning block — do NOT produce walls of debug output:

```
⚠ WATCHER POTENTIALLY UNHEALTHY
Diagnosis: {specific failure: stale log / process not found / crash loop}
Recovery: kill your current bash session to trigger a respawn via the SessionStart hook, then re-run /alfred-agent:check-messages.
Note: 0 unread may be accurate, or messages may be sitting undelivered.
```

**4. Monitor grep pattern** — verify the armed Monitor is filtering for `new_message`, not a wrong pattern that silently drops all events:
```bash
# Is a Monitor tailing events.log?
ps -ef | grep "tail.*events\.log" | grep -v grep
# Does it filter for new_message?
ps -ef | grep "grep.*new_message" | grep -v grep
```
If a `tail` process watching `events.log` is found but no `grep.*new_message` process accompanies it in the pipeline, the Monitor has the wrong grep filter. The watcher may be healthy and writing events correctly, but all real-time notifications are silently dropped.

Warn with a **distinct message** — this is a Claude-side Monitor misconfiguration, not a watcher failure:

```
⚠ MONITOR GREP PATTERN MISMATCH
Diagnosis: Monitor process found tailing events.log but grep filter does not match 'new_message' — real-time event notifications are silently dropped.
Recovery: Stop the current Monitor (TaskStop with the task ID — retrieve it via `cat /workspace/.alfred/monitor_task_id` if the sentinel file exists), then re-arm with the canonical command:
  tail -F -n 0 /workspace/.alfred/events.log | grep --line-buffered '^type=new_message '
Note: the 0-unread result above is still accurate — this only affects future real-time delivery.
```

If all four checks pass, no additional output is needed — silently confirm the watcher is healthy.
