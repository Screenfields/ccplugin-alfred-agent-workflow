---
type: doctrine
status: active
updated: 2026-06-10
description: "On first evidence of automated-loop malfunction, pull its work items out of the eligible set within one decision cycle — diagnosis happens on a parked system."
read_when: "When an automated loop shows evidence of malfunction (failed runs, wrong outputs, budget burn)."
---

# Doctrine 19 — Park fast on bad evidence

**Status:** Adopted 2026-06-10 (team retro, Jochem-approved). Origin: PM's operator discipline during the M3' incident series.

## Rule

When an automated loop shows evidence of malfunction, **pull its work items out of the eligible set within one decision cycle** — strip the triggering labels, pause the queue — BEFORE diagnosing. Diagnosis happens on a parked system; budgets and blast radius are capped at the moment of first bad evidence, not after understanding.

## Why

During M3' (2026-06-09/10), every issue budget that survived ten consecutive defects survived because labels came off within a tick of bad evidence. The one sequencing mistake in the other direction (un-parked retries on a known-broken image) burned three attempt budgets in 15 minutes. Parking costs seconds and is fully reversible; un-parked diagnosis costs budgets, audit noise, and cleanup.

## How to apply

- Bad evidence = repeated identical failures, spawn churn, state resets on completed work — anything that smells like a systematic (not work-content) failure.
- Park first, then investigate; un-park only after the fix is DEPLOYED (not merged — deployed), and after any token/secret refresh windows have elapsed.
- Design corollary: every loop needs a label-cheap park mechanism as a first-class feature — if parking requires a deploy, the loop is unsafe.

## Worked examples

PM's corpus parks (takes 2→3→4), the refile-over-budget-gymnastics decision (#36/#37/#38), the take-5 un-park held for the ESO token-refresh window.
