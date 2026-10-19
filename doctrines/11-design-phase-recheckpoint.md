---
type: doctrine
status: active
updated: 2026-05-23
description: "During the design phase, if scope has grown items beyond the original ask, stop and re-checkpoint with the user — the pause threshold is lower for cross-agent work."
read_when: "When a design under discussion has grown beyond the originally approved ask."
---

# 11. Re-checkpoint during design when scope grows

## Rule

During the **design phase** (before execution), if scope has grown N items beyond the original ask, stop and re-checkpoint with the user. The threshold for pause must be **lower for cross-agent design work than for solo work**, because commitment-momentum compounds across agents and no one wants to be the brake.

This doctrine sits next to doctrines 02 (scope discipline, response-time) and 08 (PR scope discipline, execution-time). The missing layer was **design-time** — the point where intent gets shaped before anything gets built. Existing doctrines catch scope-creep when responding to a message or shipping a PR; this one catches it earlier, while a design is still being expanded.

## Why it exists

Scope-creep is invisible to the creeper. Each expansion has its own local justification ("we'll need this anyway", "it's tightly coupled to the original ask", "we're already here"). The cumulative expansion is unilateral — nobody asks "wait, is this still the original ask?" — until the design lands and is bigger than what was approved.

The cross-agent amplifier is the load-bearing part. When two agents collaborate on a design:

- Each agent feels accountable for momentum, not for braking.
- Each agent assumes the other has internalised the scope.
- Each individual expansion has local justification on both sides.
- The cumulative scope drift becomes visible only after both sides have invested in execution.

By that point, pausing costs both agents' sunk work. Threshold for pause has to be lower **before** that point — during design, while the only sunk cost is text.

PM's 2026-05-23 worked example: user said "let's keep it simple" on an adoption ADR. PM shipped 3 coupled ADRs (ADR-0028, ADR-0029, plus a custom-type definition) in one session. Each expansion had a local justification ("the adoption pattern needs a custom type to express it cleanly"; "the custom type needs its own ADR to avoid burying it in ADR-0028"). Cumulative effect: a "let's keep it simple" ask became a 3-document deliverable. PM noticed in retrospect; the creeper-in-flight did not.

## How to apply

Three layers, in order:

1. **Diagnosis — scope-creep is invisible to the creeper.** Don't trust your own sense of "still within the ask" during design. Reference the original wording explicitly — re-read the user's request before adding each new item to the design.

2. **Cross-agent amplifier — momentum compounds.** When the design is being shaped jointly with another agent, the threshold for pause drops. If you've added 2 items beyond the original ask (in solo work that might be fine), in cross-agent design that is the re-checkpoint moment. Send a message: *"original ask was X; I/we have expanded to {X, Y, Z}; is the expanded scope still the right shape, or should we trim back to X?"*

3. **Prescription — explicit re-checkpoint.** When you notice scope has grown:
   - **Stop adding.** Don't justify the next expansion before the re-checkpoint lands.
   - **State the delta to the user.** Original ask vs current shape vs what was added between them.
   - **Offer a trim path.** "If you'd prefer the original simpler shape, here's what comes out." Make the no-expansion option concrete.
   - **Wait for confirmation.** Don't proceed to execution until the user confirms the expanded scope is what they want, OR reverts to the simpler shape.

The threshold to apply this:

- **Solo design work:** ~3+ items beyond the original ask, or one expansion that materially changes the deliverable shape.
- **Cross-agent design work:** ~2+ items beyond the original ask, OR any expansion that introduces a new artefact class (e.g. original ask was "an ADR"; you're now scoping "an ADR plus a custom type plus a migration plan" — re-checkpoint).

## Worked examples

**PM's "let's keep it simple" adoption ADR (2026-05-23).** User asked for a simple adoption ADR. PM shipped:
- ADR-0028 (the original adoption ADR)
- ADR-0029 (cross-cutting consequence of the adoption pattern)
- A new custom-type definition (needed to express the adoption pattern cleanly)

Each expansion had local justification. The cumulative scope vs the original "let's keep it simple" was 3:1. PM noticed during retro #2 synthesis, not during the work. The re-checkpoint moment was after the custom-type became necessary — that was the point to stop, send the user "the simple ADR needs a custom type; do we want to add it, or simplify the pattern?" — instead of inferring "yes, add it" from local logic.

**The cross-agent variant — counterfactual.** If PM had been shaping this design jointly with alfred-platform (cross-agent), the threshold would have applied earlier. The custom-type addition introduces a new artefact class (a type definition is structurally different from an ADR). That alone would have crossed the cross-agent threshold; in solo work it crossed only the second-expansion threshold. The discipline difference is real.

## Related doctrines

- [02-scope-discipline.md](./02-scope-discipline.md) — response-time scope discipline; this is the design-time variant. Both apply to the same underlying failure mode at different stages of the work.
- [08-pr-scope-discipline.md](./08-pr-scope-discipline.md) — execution-time scope discipline; together with this doctrine and 02 they cover design / response / shipping.
- [06-lead-worker-pattern.md](./06-lead-worker-pattern.md) — synthesis (including scope-checking) stays with the lead. Re-checkpoint is the lead's job, not a worker's.

## Cross-side note

Cross-side, behavioural. The cross-agent amplifier specifically targets multi-agent design work — alfred-platform + project-manager + alfred-cc-tools-lead converging on shared deliverables (retros, doctrines, joint ADRs). Solo expansion is bounded by the agent's own scope-discipline; cross-agent expansion needs the explicit re-checkpoint because no one party has full ownership of "wait, is this still the ask".
