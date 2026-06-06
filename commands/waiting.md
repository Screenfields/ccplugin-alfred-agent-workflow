---
description: Walk through blocked and 'waiting for' items one-by-one. For each item, summarize and simplify for a user decision. Move to the next item only when the current one is resolved or the user says to skip.
---

**First, check for project config:**

1. Look for `.alfred/config.json` in project root
2. If found, read `agent_id` from it
3. If NOT found, display:
   ```
   Project not initialized for alfred-agent messaging.
   Run /alfred-agent:init to set up this project's identity.
   ```
   And stop here.

Interactively resolve blocked and waiting items one at a time.

## Step 1: Gather waiting items

Collect from all sources:

- Issues labeled `blocked`, `waiting`, or `needs-decision`
- Open PRs awaiting your action (approve, merge, review, respond)
- Unread inbox messages that require a decision before you can proceed
- Items noted in the current session as "waiting on user" or "waiting on [actor]"
- Any open question you asked the user earlier that was not answered

Deduplicate. Order by: **user-blocked first** (user must act), then **agent-blocked** (peer agent must act), then **self-blocked** (you are waiting on something you triggered).

If there are no waiting items, report: "Nothing blocked. No waiting items found." and stop.

## Step 2: For each item

Present a concise summary — 3–5 lines max:

```
Item {N}/{total}: {one-line title}

What: {one sentence on what this is}
Needed: {what decision or action unblocks it}
From: {who must act — "you (user)", "alfred-platform", "CI", etc.}
Stakes: {what's downstream — what's waiting on this}
```

Then **stop and wait** for the user to respond. Do not continue to the next item.

**User responses and how to handle them:**

| User says | Action |
|---|---|
| Makes a decision / gives direction | Take the appropriate action, confirm in one line ("Done — [what you did]."), then move to next item |
| Asks a question | Answer it fully, then re-present the item and wait again |
| "skip" / "next" / "not now" | Note as skipped, move to next item |
| "done" / "stop" / "enough" | End the session; report summary |

## Step 3: Closing summary

After all items are processed (or user stops):

```
Waiting session complete.
Resolved: {N} | Skipped: {M} | Remaining: {K}
```

If any item opened new follow-up work during the session, list it briefly.

## Notes

- Do not ask for permission to move to the next item — wait for the user's resolution of the current one, then move automatically.
- If resolving an item requires sending a message or merging a PR, do it inline before confirming and moving on.
- Do not summarise items that were not raised (no padding).
