---
name: platform-design-basis
description: "Load when writing or checking a design for the Alfred platform: what counts as a precedent, the doctrines to read, the platform's patterns, the loop, the owner triggers and how to write."
---

- **Precedent.** An accepted ADR or a baseline doc. Code counts only when a baseline doc describes it. Doctrines inform a design but are not a precedent (AP-ADR0035 item 7). An owner decision recorded only on an issue is not a precedent (hub answer 2). **[Alfred]** Neither is a memory note.
- **Doctrines.** Read the doctrines that bear on the design: the doctrines at the path the brief names (AP-ADR0035 item 7, "Designers also read the doctrines").
- **Platform patterns.** **[Alfred]** The patterns are the accepted ADRs and baseline docs: the project's own under `docs/adr/` and `docs/baseline/`, and the platform's as passages carried in the brief (answer 4). The plugin's routed rules are the way of working. A design never relies on state that exists only in a draft, a branch or a conversation.
- **The loop.** States proposed, ready, designed, built, done (AP-ADR0022). Every state change passes a fresh reviewer; the designer's pair is the design reviewer. After failed-review-max failed rounds the starting session escalates (AP-ADR0031).
- **Owner triggers** (AP-ADR0035 items 2 and 3): no precedent with real alternatives; a change to an accepted ADR or the target architecture; additional spending above zero, except ECR spending within its standing budget; objective 2's escalation triggers; a reservation in an objective or an ADR.
- **Large and very large items** get an ECR after the design review, with or without precedent (AP-ADR0035 item 4c).
- **Need before solution.** State the functional need before naming a product. **[Alfred: from the platform's working style]**
- **Writing.** Follow the house-style skill.
