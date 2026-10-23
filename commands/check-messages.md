---
description: Check for new unread messages from other agents
---

Check for new unread messages using the agent-messaging MCP service.

## Session-start mandate

**Before anything else in a session, start the wake bridge.** `alfred-wake` is
deterministic bash (no LLM anywhere in it). It runs as a background Bash task,
stays silent while there is nothing new, and exits as soon as there is news;
the harness then re-invokes the session with its output.

```bash
command -v alfred-wake >/dev/null 2>&1 || "${CLAUDE_PLUGIN_ROOT}/bin/alfred-wake" install
```

```
Bash(command: "alfred-wake wait", run_in_background: true)
```

Do **not** arm it with `Monitor`: a Monitor expires every 30 minutes, needs a
re-arm turn each time, and leaves an unfinished task behind per re-arm.

Then **call `get_messages` once** to pick up whatever arrived before the bridge
came up (the bridge seeds its cursors silently on first run and never replays
history).

## When the `alfred-wake wait` task exits

Act on its output line(s) exactly as follows. "Relaunch" means the same
`Bash(command: "alfred-wake wait", run_in_background: true)` call; a new wait
replaces any previous one, so relaunching is always safe.

| Output | Action | Text to the user |
|---|---|---|
| `WAKE am …` | `get_messages`, handle per the rules below, relaunch | Only what the messages themselves warrant |
| `WAKE buzz …` | Read that channel, handle, relaunch | Only what the posts warrant |
| `… no-mark` (a trailing ` no-mark` on a `WAKE am`/`WAKE buzz` line) | This session has no work-item mark. Run `alfred-workitem mark <owner>/<repo>#<n>` (operational turns with no specific item go on the shared standing item Screenfields/alfred-platform#1173, AP-1173, or `alfred-workitem mark none`), then handle the wake as usual with the row above | None |
| `WAKE-ERROR …` (exit 2) | Relaunch. If it is `WAKE-ERROR alfred-wake`, or the second `WAKE-ERROR agent-messaging` this session: see "Bridge down" | One line, once per source per session |
| `WAKE-RECOVERED …` | Relaunch | None |
| `WAKE-STOPPED signal=…` | Relaunch | None |
| `WAKE-STOPPED replaced …` | Nothing — a newer wait is already running | None |

## Hard rule: no news, no text

A wake, relaunch, re-arm or stop that brings no new message produces **no model
text at all**. No "restarted the watcher", no "still waiting on …", no recap of
open items: make the tool call and end the turn. The same applies when the
`get_messages` after a `WAKE am` turns up nothing that needs handling. Only real
news — a message that needs a reply or a decision, or a `WAKE-ERROR` — gets text.

## Wake-armed check (run this every time this command runs)

```bash
alfred-wake status >/dev/null 2>&1 || echo "no wake bridge running"
```

`status` exits 0 only while a live `wait`/`run` process holds the bridge's
pidfile. If it prints, relaunch the wait silently.

## Bridge down: tell the user once, notify the hub, never poll

The bridge is down when the wait cannot start (the task exits with no `WAKE`
line, or prints `WAKE-ERROR alfred-wake`), or when `WAKE-ERROR agent-messaging`
comes back a second time in a session. Then, once per session:

1. Tell the user in one line: `wake bridge down: <the error line>`.
2. Send `hub` the subject `wake bridge down on <agent_id>`, with
   the error line as the body. If agent-messaging itself is what is down, the
   send fails; the user line is then the whole report.

Do **not** fall back to `/loop`, `ScheduleWakeup`, cron or any other periodic
check-messages: a scheduled check may not consume tokens (platform doctrine
22). The hub fixes the bridge, and its nudge-watcher catches deaf leads
deterministically.

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

If no unread messages: when the user ran this command, report "No new messages" — that's the full answer. When a wake or session start triggered the check, say nothing (see "no news, no text").

**After displaying messages:**

1. **Automatically mark all displayed messages as read** using `mcp__agent-messaging__mark_read_batch(message_ids=[...], as_agent="{agent_id}")` with all message IDs in a single call. This is the default behavior since reading a message implies acknowledgment.

2. **Reply directly if you have a clear answer.** If a message asks a question or requests information that you can answer confidently based on your current context and knowledge, reply immediately without asking the user for permission.

3. **Validate with user first if unsure.** Ask for user input when:
   - The answer requires decisions outside your authority
   - You're uncertain about the correct response
   - The message involves commitments, deadlines, or significant actions
   - Multiple valid approaches exist and user preference matters

4. Offer to view full thread if relevant context might be needed.

**Unread means "not yet delivered to the session" and nothing else.** Mark
every displayed message read, including messages that still need action. A
to-do that outlives the turn goes into an issue (`/alfred-agent:drop-issue`, or
the repo it belongs to) or gets answered on its thread. Never leave a message
unread as a reminder: the platform's unread-age metric and nudge-watcher read a
message that stays unread as a deaf lead.

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
