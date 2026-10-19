---
type: doctrine
status: active
updated: 2026-06-10
description: "Procedures that cross ownership boundaries (recovery, pre-flight, backup/restore) must be executable and verifiable by a non-author, with a mechanical pass/fail signal."
read_when: "When writing or reviewing a procedure that a peer or non-author may need to run."
---

# Doctrine 20 — Boundary procedures must be runnable and verifiable without their author

**Status:** Adopted 2026-06-10 (team retro, Jochem-approved). Merges three threads: cross-spoke recovery procedures, the local pre-flight harness, and evolving-pod backup positions.

## Rule

Any procedure that crosses an ownership boundary — recovery scripts a peer may need to run, pre-flight checks that gate someone else's deployment, backup/restore paths for another team's state — must be **executable and verifiable by a non-author**: versioned, parameterized, with a mechanical pass/fail signal. "Ask the owner how" is a single point of failure, not a procedure.

## Why

The M3' pre-flight harness proved the pattern's value from the constructive side: a containerized end-to-end run (production image, scrubbed env, real inputs, exit-code verdict) let a NON-author validate the entire worker lifecycle in minutes, finding three defects before they could burn shared budgets. The inverse failure mode is the 2026-05/06 pattern of leads being unrecoverable because their restore steps lived in their author's session memory.

## How to apply

- Recovery: leads publish versioned recovery procedures the platform can execute without them.
- Pre-flight: anything Job-shaped gets a containerized self-check runnable in CI and locally (formalized for the worker in autonomous-worker#4).
- Materialization: pods that evolve state expose a mechanical readiness/manifest signal (the manifest-exposing `/readyz` is the reference — it served as the adoption Phase-E verification surface with zero author involvement).

## Worked examples

The defect #7–#9 local-harness cycle (15 min/defect, zero cluster budget); consciousness-project Phase-E verification via `/readyz`; scaffold-template default tracked via PM.
