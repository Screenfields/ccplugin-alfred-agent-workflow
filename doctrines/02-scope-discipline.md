---
type: doctrine
status: active
updated: 2026-05-22
description: "Match response scope to ask scope: don't add items when responding to a multi-item proposal; filter outgoing proposals for cross-team relevance."
read_when: "When responding to or composing a multi-item cross-team proposal or plan."
---

# 02. Filter cross-team coordination scope

## Rule

Match response scope to ask scope. When responding to a multi-item proposal (from peer or user), don't elaborate by adding items unless directly required by the originating ask. When sending one, filter for what's actually cross-team relevant.

## Why it exists

Scope-creep enters via well-meaning elaboration on someone else's framing. A peer sends a "Full plan" listing 8 items; the receiver adds 3 more "for completeness"; soon the discussion is 11 items wide, most off the originating ask. The originator's framing imports problem-space without anyone having asked whether it fits.

The cost of unfiltered elaboration compounds: each off-scope item attracts its own follow-up, ECR, design discussion, and eventual reconciliation. By the time anyone notices the discussion has drifted, several rounds of work have been spent on items the user never asked about. The user's eventual correction in the 2026-05-22 retro session was blunt: "OMG this is a mess. What is actually related to the local routing?" — the entire structure had to be discarded and re-scoped from scratch.

The discipline is to filter on receive *and* on send. Double-filter is correct. Receiving a 10-item plan does not obligate you to engage with 10 items.

## How to apply

- When you receive a structured peer proposal, ask: "is each item in their plan mapped to the originating user ask?" Drop the items that don't map.
- When you send a structured proposal, ask: "is each item I'm sending actually cross-team relevant, or is this internal-to-my-project work I'm leaking into a coordination channel?"
- The de-tangle reply pattern is the right tool when alignment scope has crept: "we're scoping to X only; the rest is your call at your pace."
- Responsibility: both sides. Sender filters before sending; receiver filters again on receive.

## Worked examples

**PM's "Full plan + issue split".** PM proposed PM#236, PM#240, PM#241, PM#229, PM#238 close-out + alfred-platform#NEW-1, framed as a single alignment ask. Most of those items were PM-internal test/perf work, not internal-routing (the originating user ask). alfred-platform elaborated the structure further, accelerating the creep until the user discarded the entire structure with a blunt scope correction. Takeaway: importing a peer's framing without filtering doubles the scope error.

**PM acknowledged the root cause.** User direction had been "first align the full plan with alfred-platform; divide work in separate issues" — PM read "the full plan" as "every open item" rather than "the cross-team-relevant subset". Only ~2 of the 8 items were actually cross-team. Takeaway: ambiguous phrasing ("the full plan") defaults to too-wide; the receiving filter has to be active, not passive.

## Related doctrines

- [08-pr-scope-discipline.md](./08-pr-scope-discipline.md) — 02 is about coordination scope (cross-team alignment); 08 is about PR scope (single artifact). Different scope-failure modes, related principle.
- [06-lead-worker-pattern.md](./06-lead-worker-pattern.md) — lead-level filtering happens at the coordination layer; workers don't typically receive multi-item proposals.

## Cross-side note

Symmetric. Sender filters before sending; receiver filters again on receive. Both sides bit by the same shape in the 2026-05-22 retro session — PM as sender, alfred-platform as receiver-who-elaborated-further. Double-filter is the correct discipline.
