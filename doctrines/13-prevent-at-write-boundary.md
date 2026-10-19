---
type: doctrine
status: active
updated: 2026-05-23
description: "When a leak or bug class recurs, fix where the wrong choice is made (refuse at the write boundary) rather than improving cleanup after the fact."
read_when: "When an incident produces a 'we need to clean up X' conclusion."
---

# 13. Prevent at the write boundary (not cleanup after)

## Rule

When a leak or bug class recurs, look at **where the wrong choice was made** — the write boundary — not at where cleanup after the fact failed. Boundary-refusal at write time has higher operator-friction-per-incident but lower TCO than cleanup-after, which compounds badly.

The discipline: when an incident produces "we need to clean up X", treat that as a signal to ask "where was X created, and can we refuse it there?" — not as a signal to write better cleanup logic. Cleanup is a downstream symptom; the boundary refusal is the upstream cure.

## Why it exists

Cleanup-after patterns look cheaper per-incident (small change, narrow blast radius) but compound badly over time. Each recurrence of the bug class produces a new orphan, a new partially-cleaned state, a new variant the cleanup didn't account for. The cleanup logic itself grows complex; it acquires its own edge cases; eventually cleanup is its own source of bugs.

Boundary refusal has higher friction per incident — every wrong input gets rejected, including ambiguous-but-recoverable ones, including legitimate operator workflows that look superficially like the bug. Operators will hit the refusal more often than a cleanup-after path would have failed. But the bug class is *closed*. Recurrences don't produce orphans; they produce explicit errors at the source, with context.

PM's 81-leak class (PM#249) is the canonical worked case for both sides of the tradeoff. Multiple prior fixes were cleanup-after (clean up orphan scaffolds, retry-with-better-logging, scheduled CronJob to sweep). Each was reasonable per-incident, none closed the class. The class kept recurring because the write boundary (`routes/projects.ts:77` defaulting to the wrong org) was never refused. PM PR #250 is the worked fix: 15 lines + 4 unit tests refuse wrong-org pmtest at create-time. Class closed. Tradeoff: more boundary errors when operators submit ambiguous inputs; zero new orphans, zero further sweep costs, zero recurrences.

## How to apply

Three questions when an incident lands:

1. **Where was the wrong artefact created?** (not "where was it detected"). The detection point is where cleanup pressure lives; the creation point is where prevention lives.

2. **Can the creator refuse this class of input?** A boundary refusal needs: explicit constraint (regex / schema / contract), validation at the creator's entry point, actionable error message that names the constraint. If you can't articulate the constraint, you cannot refuse at the boundary — but that is the work to do, not a reason to fall back to cleanup-after.

3. **What's the operator-friction tradeoff?** Boundary refusal will fire more often than cleanup-after would have failed. Count: how many legitimate operator workflows produce ambiguous inputs in this class? If the count is high, you may need a richer boundary check (allowed shapes + targeted overrides) — but the answer is still boundary refusal of unambiguously-wrong inputs, not full retreat to cleanup-after.

The trigger: when you find yourself writing cleanup logic for a recurring class, stop and ask whether refusing-at-write is feasible. If it is, that's the right fix. If it isn't, document why (genuinely ambiguous inputs the system can't disambiguate) — but the documentation is itself a write boundary on the design space.

Cleanup-after is correct as a **safety net layered on top of** prevent-at-write, not as a substitute for it. K8up backups, schedule sweeps, retry hooks — all good belts-and-braces. None of them close a bug class on their own.

## Worked examples

**PM PR #250 — RFC 1123 boundary refusal (2026-05-23).** The 81 `pmtest--*` orphan repos in Screenfields (instead of screenfields-tests) traced to a silent-default-org behaviour at `src/routes/projects.ts:77`. PR #250 refuses the wrong-org-at-create-time: an explicit guard rejects any `pmtest--*` name targeting a non-tests org, returning an error that names the constraint. 15 lines + 4 unit tests. The bug class — wrong-org leaks — is closed at the write boundary.

**PM PR #246 — cleanup-on-failure counter-example.** ~45 lines + a memory file. Addressed a different failure mode (test-failure cleanup completeness) but did *not* close the wrong-org-at-create-time class. Reasonable per-incident; insufficient as a class-closer. Same author, same project, different shape of fix. The two PRs together are the textbook contrast: PR #246 is "cleanup did the right thing more reliably"; PR #250 is "the wrong thing was refused at the source." Both have their place; only the second one is class-closing.

**alfred-cc-tools marketplace.json validation (parallel example).** Currently a checklist step: run `/plugin validate .` before committing changes to `marketplace.json`. A bad version pin can land in `marketplace.json` and fail silently 24h later when a downstream agent tries to install the plugin. The class is: bad-pin-in-marketplace. The cleanup-after pattern would be: monitoring + alerting on plugin-install failures + manual revert. The write-boundary pattern: a CI workflow that validates `marketplace.json` on every PR touching it, refusing the PR if validation fails. The boundary fix is in the alfred-cc-tools backlog; this doctrine is the justification for prioritising it over richer cleanup-after monitoring.

## Friction tradeoff (explicit)

| Pattern | Operator friction per incident | TCO over time | Class closure |
|---|---|---|---|
| Boundary refusal | High (more rejections, including ambiguous-but-recoverable) | Low (class closed; recurrences impossible by construction) | Yes |
| Cleanup-after | Low (most paths succeed; cleanup is silent) | High (compounds — each new variant adds cleanup edge cases) | No |
| Cleanup-after as safety net atop boundary refusal | Same as boundary refusal | Same as boundary refusal + small additive cost | Yes (boundary closes the class; cleanup catches the rare residual) |

The right shape is row 3 for most production systems: boundary refusal does the class-closing work, cleanup-after is a defence-in-depth layer underneath. The wrong shape — too common — is row 2: cleanup-after framed as the primary fix because it's cheaper per-incident.

## Related doctrines

- [09-diagnostic-cleanup-contract.md](./09-diagnostic-cleanup-contract.md) — diagnostics declare teardown upfront. This doctrine is the production-side analogue: prevent the state from being created in the wrong shape in the first place.
- [12-shared-dependency-interface-contract.md](./12-shared-dependency-interface-contract.md) — boundary validation at a tool's own input is exactly the prevent-at-write-boundary pattern; PR #250 is the worked example for both doctrines (the same fix discharges both responsibilities).
- [01-verify-claims-about-state.md](./01-verify-claims-about-state.md) — boundary refusal verifies a claim about the input at the moment it arrives; cleanup-after assumes the claim was true and discovers it wasn't.

## Cross-side note

Cross-side, behavioural. The recurring-class signal applies to every spoke: PM (project scaffolds), alfred-cc-tools (plugin pins), alfred-platform (gitops manifest entries), secret-service (secret writes), agent-messaging (message payloads). Each tool that accepts input is a write boundary; each recurring class of "we cleaned up X again" is a candidate for boundary refusal.
