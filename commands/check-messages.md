---
description: Check for new unread messages from other agents
---

Check for new unread messages using the agent-messaging MCP service.

## Session-start mandate

**Before anything else in a session, arm the wake bridge.** It is a deterministic
bash watcher (no LLM anywhere in it) that wakes the session only when there is
genuinely new news, replacing the 15-minute inbox loop and its ~96 empty model
turns per day:

```bash
command -v alfred-wake >/dev/null 2>&1 || "${CLAUDE_PLUGIN_ROOT}/bin/alfred-wake" install
```

```
Monitor(command: "alfred-wake run", persistent: true,
        description: "inbox wake: agent-messaging + Buzz")
```

Then **call `get_messages` once** to pick up whatever arrived before the bridge
came up (the bridge seeds its cursors on first run and deliberately never
replays history).

**Only if arming fails** — the `Monitor` tool errors, or
`alfred-wake check` reports `WAKE-ERROR agent-messaging` — fall back to the old
cadence: `/loop 15m /alfred-agent:check-messages`. Say so explicitly when you
fall back; a silent fallback looks identical to a working bridge.

## Wake-armed check (run this every time this command runs)

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/alfred-wake" status >/dev/null 2>&1 || \
  echo "WARNING: no wake bridge armed — this inbox is poll-only. Arm it: Monitor(command: \"alfred-wake run\", persistent: true)"
```

`alfred-wake status` exits 0 only while a `run` loop has touched its marker file
within the last 5 minutes. **Surface that warning line to the user verbatim** —
an unarmed lead misses messages until someone manually checks, which is exactly
the failure this bridge exists to remove.

See the `alfred-wake` section of the plugin README for configuration, state
layout, and how to verify with `alfred-wake check`.

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

If no unread messages, report "No new messages" — that's the full answer, nothing else needed.

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

## Ad-hoc poll loop when actively waiting on a reply

If you are mid-conversation and need to wait for a peer agent's reply before continuing, you may run a **bounded** poll loop using the Bash tool with `run_in_background: true`:

```bash
deadline=$(( $(date +%s) + 300 ))  # 5-minute ceiling
while [ "$(date +%s)" -lt "$deadline" ]; do
  result=$(mcp_call get_messages '{"unread_only":true,"limit":5}' | jq '.messages | length')
  [ "$result" -gt 0 ] && break
  sleep 30
done
```

Rules:
- **Always bounded.** Never an unbounded `while true` — that's how we got the failure mode we just retired.
- **Polite cadence.** 30s minimum between polls.
- **Timeout reported back.** If the deadline elapses with no reply, surface that to the user rather than silently giving up.
- **Not the default.** Only spin one up when you explicitly need a synchronous round-trip; one-shot `get_messages` at session start handles 90% of cases.
