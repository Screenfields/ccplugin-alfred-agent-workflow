---
type: doctrine
status: active
updated: 2026-05-22
description: "Validation effort matches change scope: define the minimal evidence that proves THIS change works instead of auto-importing or auto-shrinking gates."
read_when: "When choosing which tests or gates a change must pass."
---

# 04. Match validation effort to change scope

## Rule

Validation effort matches change scope. For each change, ask "what's the minimal evidence that would prove THIS change works?" Don't auto-import a full gate onto a narrow change; don't auto-shrink on a wide change because the previous one was narrow.

## Why it exists

Inheriting standard gates by inertia treats every change as if it needs the same proof. A narrow change held hostage to a flaky full regression suite is a process problem (gate misfit), not a change-quality problem. The inverse trap is also costly: wide changes pretending to be narrow get under-tested.

The 2026-05-22 retro surfaced the inertia trap: PM PR #233 was a 12-line env-var drop from a devbox deployment template, but the auto-imported gate was the full pr-e2e regression suite (~30 min, flaky). The mismatch between change surface (one env var on devbox scaffolding) and gate surface (full regression across all PM behaviors) blocked landing for reasons unrelated to the change's actual quality. The fix was not to lower the bar; it was to define a focused test that actually probed the surface the change touched.

The discipline is to design the gate after looking at the surface, not before. Default gates are starting points; surface-specific gates are landing points.

## How to apply

- Before defining the gate, ask: what's the surface this change touches? What's the minimum evidence that demonstrates correctness on THAT surface?
- The gate matches the surface. If the gate is a heavy regression suite, ask whether the change actually touches a surface that needs it.
- If the standard gate is misfit, design a focused test. Don't lower the bar; right-size it.
- Inverse check: if the change is wide, don't shrink the gate because the previous PR was narrow. Wide changes earn wide gates.
- Responsibility: the agent landing the change. Reviewer can challenge the gate choice.

## Worked examples

**PM PR #233 held on full pr-e2e.** PM PR #233 was a 12-line env-var drop from a devbox deployment template. PM auto-imported the standard pr-e2e (full regression suite, ~30 min, flaky) as the gate. alfred-platform almost accepted this. User pushback: the actual validation needed was a focused routing test — "fresh devbox scaffolded post-#233 reaches agent-messaging without CF Access creds; existing devboxes unaffected." That's a 5-minute targeted probe. The full suite was misfit; the focused test was correct. Takeaway: inherited gates are starting points, not landing points; design the gate after looking at the surface.

## Related doctrines

- [08-pr-scope-discipline.md](./08-pr-scope-discipline.md) — tightly related. Narrow PRs deserve narrow validation; wide PRs need wide validation. The two doctrines together prevent both "bundled scope, narrow validation" and "narrow scope, bloated validation".
- [01-verify-claims-about-state.md](./01-verify-claims-about-state.md) — designing a gate is a state claim ("this change is correct"); choose the verification that actually probes the surface.

## Cross-side note

Cross-side, both sides bit. Inheriting auto-gates is the trap both sides fell into. The cure is the same on both sides: surface-first gate design.
