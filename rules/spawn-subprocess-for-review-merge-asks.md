---
name: spawn-subprocess-for-review-merge-asks
description: "When a peer agent asks for a code review or a merge of work they don't own merge-auth on, dispatch the review/merge as a background subprocess (Agent tool worker) rather than handling inline. Keeps the asking agent unblocked while you continue other work."
---

## The rule

**When another agent asks you to review a PR or merge a PR they can't merge themselves, dispatch the work as a background subprocess immediately. Don't queue it for inline handling.**

Concretely: when an inbox message lands asking for review or merge, spawn an Agent-tool subagent (with `run_in_background: true`) right away. The subagent handles the review/merge end-to-end; you continue other work and get a completion notification when done.

The asking agent doesn't wait while you finish unrelated work. Reviews land in roughly the time it takes the subagent to read the diff + form a verdict + post the review — independent of your main-thread cadence.

## Why this rule exists

Peer agents waiting on review/merge of their work is a recurring fleet-wide latency source. The asker's session is often blocked behind the review (CI gates, downstream PRs, dependent rollouts all hold). Handling these inline means they wait for you to finish whatever's in your current turn — possibly multiple message exchanges or substantial drafting — before their review even starts.

Subagents run in their own context. Spawning one for a review costs ~5-10s of lead-thread time (writing the brief) and unblocks the asker on a near-parallel timeline. The cost asymmetry is large: 5s of brief-writing vs minutes-to-hours of asker-side blocking.

Variant: even if the review itself is fast (1-line diff, obvious LGTM), spawning a subprocess is still preferable when the lead has other in-flight work — because the subprocess takes none of the lead's attention away from its current synthesis loop.

## How to apply

When you receive an inbox message of the form:

- "PR #N ready for review"
- "Can you approve PR #N so I can merge?"
- "Asking alfred-platform to merge #N since I lack the permission"
- Any equivalent shape that asks for your action on a PR

**Default move**: dispatch an Agent-tool subagent with `run_in_background: true`. Brief the subagent with the PR number, the asking-agent's review focus (if specified), and your default-merge policy (typically: merge if LGTM, comment + approve if minor advisory, request-changes if concerns).

The lead continues whatever it was doing. The subagent emits a completion notification when the review/merge lands. The lead then sends a brief ack to the asking agent.

Pattern:

1. Inbox message arrives asking for review/merge
2. Lead briefly reads the message to understand scope
3. Lead spawns subagent with brief: "Review PR #N on Screenfields/<repo>. <context-1-line>. Approve+merge if LGTM, comment+approve if minor advisory, request-changes if concerns. <any-version-sequencing-or-merge-gates-noted>."
4. Lead marks the inbox message as read (the work is dispatched)
5. Lead continues other work
6. On subagent completion notification: lead acks the asking agent

## Exceptions

- **Dependent-PR chains**: if the same lead is asking for review of multiple PRs that depend on each other (e.g., 3-PR plugin.json version-bump chain where each PR's merge changes the base for the next), spawning 3 parallel subagents won't work — they'd interfere with each other. Handle inline-but-sequential in that case. (The trigger is the dependency, not the size or triviality of the batch — independent PRs from the same asker still get parallel-subagent treatment.)
- **Judgment-density-heavy reviews**: when the PR touches load-bearing architecture, the lead may want to do the review personally rather than delegate to a subagent. Identify these by the size + criticality of the change, not by who's asking.
- **No-context cases**: if the lead lacks the context to write a useful subagent brief (the PR touches code/conventions the lead doesn't know), don't spawn — ask the asking agent for context first, then either spawn with the better brief or escalate elsewhere.
- **Active in-context drafting**: if the lead is actively in the middle of drafting a thoughtful response on the same conceptual thread (so a context-switch would cost more than the inline review), finish the current thought first, then dispatch. But don't queue indefinitely.

## Scope

This rule is Claude-Code-specific — it references the Agent-tool background-subprocess pattern. Other coding-agent runtimes (Codex, Gemini, etc.) have different parallel-execution primitives and would carry their own version of this rule in their respective tool layers.

This rule composes with:

- `pre-send-inbox-check.md` — the lead checks inbox before sending the post-review ack message (ensures the asking agent hasn't sent a follow-up in the interim).
- `retry-on-anthropic-rate-limit.md` — subagents are themselves a Case-2 (main-inference rate-limit) mitigation. Spawning a subagent for a review means even if the lead's main loop gets throttled, the review still completes.
