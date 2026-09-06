---
description: >
  Guided walkthrough of everything that is waiting on the human owner — decisions, approvals and
  actions only they can take. Presents one item at a time in plain language, lays out the options
  with pros and cons and a clear recommendation, gives step-by-step instructions with direct links,
  waits for the answer, then acts on it (delegating execution to sub-agents) and moves on. Use this
  whenever the user asks "what needs my decision", "what's waiting on me", "walk me through the open
  items", "interview me", "what do you need from me", or when several items have piled up on the
  owner during a session — do not dump a list, run this instead.
---

**First, check for project config:**

1. Look for `.alfred/config.json` in the project root.
2. If found, read `agent_id` from it.
3. If NOT found, display:
   ```
   Project not initialized for alfred-agent messaging.
   Run /alfred-agent:init to set up this project's identity.
   ```
   And stop here.

## What this command is for

The owner is one person with limited attention. Items that need them tend to pile up across
issues, threads and chat, each described in the jargon of the moment. This command turns that
pile into a conversation: one item at a time, explained simply, with the choice or the steps made
concrete, and nothing moving until the owner has answered. The agent does all the reading,
comparing and executing; the owner only decides and clicks.

Two things make this work, and both are easy to get wrong:

- **Wait for the answer.** A walkthrough that keeps going ("...and after that, you could also...")
  is a list again. After presenting an item, or a step whose result you need, stop. The next thing
  you say depends on what the owner says.
- **Only real owner items.** If the agent can do it itself, it is not an owner item: do it and do
  not ask. Owner items are decisions the agent is not authorised to make (access grants, money,
  policy, anything the project marks as an owner decision), actions the agent cannot reach
  (consoles, logins, physical hardware, accounts only the owner holds), and confirmations for
  disruptive or hard-to-reverse steps.

## Step 1: Gather

Sweep every source. When the sweep is more than two or three calls, run the sources in parallel
via read-only sub-agents so the owner is not kept waiting; the lead only merges. **Do not make the
owner wait for the sweep:** if you already know two or three genuine owner items from the session or
the last handover, show the agenda with those and present item 1 while the sweep runs, then fold the
sweep's additions into the agenda at the next natural pause ("sweep landed; added X, dropped Y").
The first live run stalled for minutes on a background sweep and the owner said so. Say plainly
that the agenda may still change ("sweep still running; the list can grow"), and if the sweep lands a
security or data-loss item, name it at the next pause and offer to jump to it — do not silently
append it to the end.

- **GitHub issues** carrying the project's owner-action label (alfred-platform uses
  `action:jochem`), plus open issues whose most recent comments contain an explicit owner ask
  ("owner decision", "Waiting on you", "Owner:", a numbered decision list) that has not been
  answered in a later comment.
- **Open PRs** that need the owner: labelled `requires-elevated-merge`, review requested from the
  owner, or blocked on a policy call the PR body names.
- **Agent-messaging inbox**: unread or unanswered threads where a peer relays or requests an owner
  decision, approval or credential.
- **This session**: questions you asked earlier that were never answered, and "waiting on you"
  lines in your own recent messages.

Then:

1. **Deduplicate** — the same decision often exists as an issue comment, a thread and a chat line.
   One item, with all its references. Scope each item to the **whole** ask in its latest
   owner-facing record: if a comment asks the owner to rotate seven credentials and change one
   password, the item is all eight, not the last line you read.
2. **Classify** each item as one of:
   - **DECISION** — the owner picks between alternatives.
   - **ACTION** — the owner performs steps outside the agent's reach.
   - **CONFIRMATION** — a yes/no go for something the agent will then execute.
3. **Order** by consequence: security and data-loss items first; then items that block the most
   other work (count the dependents); then the rest. Within a group, oldest first.
4. **Cap the session** at roughly eight items. Tell the owner how many more are queued; they can
   ask for the rest.

If nothing is found, say "Nothing is waiting on you." and stop — no padding, no "but you could
consider...".

## Step 2: Agenda

Before the first item, show the agenda: one line per item with its number, type and a five-word
title. This lets the owner reorder or drop items ("skip 3", "do 5 first") before you invest in
explaining them. Wait for the owner's reaction only if they give one; otherwise start with item 1.

## Step 3: Present one item, then wait

Every item starts the same way:

```
Item {N}/{T} — {title}

In plain words: {2–3 sentences: what this is, why it needs you and not the agent,
and what happens if it keeps waiting. No jargon; expand every acronym on first use.}
```

Say only what the record says. Every status statement in this paragraph ("already rotated",
"verified clean", "merged") must trace to something you read in the issue, thread or PR — the
owner will act on it, and a reassuring sentence you inferred ("everything else is done") shrinks
their real task and hides a live risk. When the record is silent, say so ("the issue does not
say whether X happened") rather than guess.

Then, by type:

**DECISION** — lay out the alternatives, each in the same shape:

```
Option A — {name}
  What it means: {one sentence}
  Pros: {one or two}
  Cons: {one or two}
Option B — ...

My recommendation: {A/B/none}, because {one or two sentences}.
```

State the recommendation explicitly even when you have none ("no preference — it comes down to
X, which only you know"). When the AskUserQuestion tool is available, present the options through
it with the recommended option first and marked "(Recommended)", and the pros/cons in each option's
description — the owner then answers with a click. Without the tool, the text above is the format.

**ACTION** — give numbered steps the owner can follow without thinking:

- One action per step, in the order the owner will actually do them.
- A direct link to the exact page or screen for every step that has one (the settings page, not
  the service's home page).
- If a later step depends on the result of an earlier one (a value to paste, a confirmation that
  something worked, a choice that appears on screen), **stop after that step** and ask for the
  result. Do not print the remaining steps yet — they may change.
- End with what you need back: "tell me when done", "paste the new ID", etc.
- **One diagnostic step per failed action, then file and move on.** When an owner step fails
  unexpectedly ("the app will not connect", "ssh says not allowed"), take at most one cheap
  read-only check to name the cause; if that does not close it, record the item as parked with the
  diagnosis, file a quick-log issue for the fix, and present the next item. Chasing a fix inside the
  walkthrough (a certificate project, an ACME error hunt) turns the owner's decision session into a
  debugging session — the first live run did exactly that and the owner called it drift.

**CONFIRMATION** — state exactly what will happen, the blast radius (who or what is affected, for
how long), whether it can be undone, and what you will verify afterwards. Ask for the go.

**Then stop.** Do not present the next item, do not add "meanwhile", do not pre-answer.

## Step 4: Handle the answer

| Owner says | You do |
|---|---|
| Decides / confirms / says "done" | Record it, act on it (Step 5), confirm in one line, move to the next item |
| Asks a question | Answer it fully, in plain words, then re-present the choice or step and wait again |
| Gives partial feedback on a multi-step action | Give only the next step(s) that this unlocks; wait again |
| Answers part of a bundled item ("yes to 1–5, not 6–8") | Record and act on the answered parts; the rest stays the same item, re-presented with only the open parts; wait again |
| "skip" / "next" / "later" | Note it as skipped (with the reason if given), move on |
| "stop" / "enough" / "done for now" | Go to the closing summary |
| Changes the question ("actually, what about...") | Follow the owner; the agenda is theirs to change |

Never treat silence, a background-task notification or your own earlier message as the owner's
answer.

## Step 5: Act on the answer

1. **Record first.** Put the decision where it will be found later: a comment on the issue or PR,
   a reply in the thread, in the owner's own words where wording matters. Durable records are
   in English even if the walkthrough ran in another language.
2. **Execute the agent's part, without stalling the walkthrough.** Anything that takes more than a
   single call — opening a PR, a verification sweep, a multi-file rewrite — goes to a sub-agent
   with a written brief (worktree isolation for repo work, read-only for checks). Tell the owner in
   one line that it is running, then present the next item. When a sub-agent finishes, report its
   result in one line at the next natural pause; if it failed, that becomes a new item.
3. **Owner-only steps get verified.** "Done" from the owner is the signal to check, not the proof:
   run the cheap read-only verification you named in the instructions (the tag is on the device,
   the setting reads "on", the token works) before you mark the item resolved. If verification is
   not possible, say so and record the item as "done, unverified".
4. Never widen scope on the back of an answer: a "yes" to one item is not a "yes" to the chain it
   implies. New work that surfaces becomes a new item or a new issue.

## Step 6: Closing summary

```
Walkthrough complete — {resolved} resolved, {skipped} skipped, {remaining} still queued.
```

Then, briefly:
- where each decision was recorded (issue/thread links),
- what is still running in the background and what will report back,
- new items or issues that surfaced,
- what remains on the owner, in one line each.

## Style

- Plain language throughout; the owner should understand each item without opening anything.
  Explain the why behind a recommendation — a bare "I recommend A" is not a recommendation.
- Local time (Europe/Amsterdam), never UTC. Links to GitHub records as clickable markdown links.
- No timelines, no "by Friday" — sequence and dependencies only.
- Mirror the owner's language in chat (Dutch or English); keep durable records in English.
- Keep each item under roughly fifteen lines before the wait. If it needs more, the item is
  probably two items.
