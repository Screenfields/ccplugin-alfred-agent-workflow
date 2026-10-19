---
type: doctrine
status: active
updated: 2026-05-24
description: "Tools that become shared dependencies must declare and validate their interface contract at their own boundary, not defer discovery to downstream consumers at runtime."
read_when: "When building or adopting a tool that other agents' workflows depend on."
---

# 12. Shared tools declare and validate their interface contracts

## Rule

When a tool becomes a **shared dependency** (other agents' workflows depend on its accepted inputs and produced outputs), its interface contract must be **explicit** and **validated at the tool's own boundary** — not deferred to downstream consumers to discover at runtime.

The contract has two sides: (a) what inputs the tool accepts, with what shape constraints; (b) what outputs it produces, with what guarantees. Downstream adopters verify the contract before depending on it. Skipping either side produces cascade-class incidents — failure modes that compound across consumers and surface far from the source.

## Why it exists

Doctrine 01 (verify claims about state) covers verification of *claims* between agents. This doctrine covers a different surface: verification of *tools* as shared dependencies. Once a tool is treated as a dependency by other agents' workflows, its accepted-input contract becomes load-bearing for those workflows — and the cost of that contract being wrong rises quadratically with consumer count.

The 2026-05-20 cascade is the canonical example. PM's scaffold flow accepted `pauseDt` (camelCase) for a project name. The downstream consumer (ArgoCD generating K8s resources from the project name) required RFC 1123 (lowercase-hyphen). PM accepted the wrong-shape input silently; the failure surfaced 47 ApplicationSet-generated resources later, looked like a routing regression, and burned 3 hours of misdiagnosis as a Phase 2 routing issue. The actual root cause was an interface mismatch between PM-as-tool and the platform that depended on PM's outputs.

The repair (PM PR #250) added boundary validation at PM's input layer: reject names that wouldn't survive RFC 1123 downstream. **That is the right shape of fix** — boundary validation at the tool that creates the artifact, not pattern-matching error recovery at the downstream consumer.

The doctrine generalises: every tool that produces artefacts consumed by other systems must declare the constraints those systems impose, and validate at its own boundary. "We'll handle it downstream" is the path to cascades.

## How to apply

Four parts, each load-bearing:

1. **When a tool becomes a shared dependency, its accepted-input contract must be explicit.** Document what shapes the tool accepts. The documentation must be machine-checkable where possible (regex, JSON schema, validation function) — prose-only contracts drift.

2. **Validate at the tool's own boundary.** Reject malformed inputs at the entry point, with an actionable error. Do not defer the constraint to downstream consumers; they have less context to give a useful error, and the cost of the rejection rises with how far the malformed input travels.

3. **Downstream adoption requires interface verification.** Before a workflow depends on a shared tool, the consumer reads + verifies the contract. The verification covers: what shapes are accepted (does the consumer's use-case fit?), what guarantees the outputs satisfy (does the downstream system's contract match?), what failure modes are surfaced explicitly vs swallowed silently.

4. **Cost-of-skipping is cascade-class.** This is what justifies the friction. Skipping (1)+(2) at the tool's boundary, or (3) at the consumer's adoption, produces failure modes that compound across multiple consumers, surface far from the source, and look like other categories of bug (routing regressions, race conditions, infrastructure flakiness) during diagnosis.

## Worked example

**PM scaffold + ArgoCD RFC 1123 (2026-05-20).** PM's API accepted project name `pauseDt` — a structurally valid camelCase string. PM's scaffold flow generated K8s resources from this name, which ArgoCD then applied. ArgoCD rejected the resources because Kubernetes requires RFC 1123 names (lowercase, hyphen-separated, no camelCase). The first invalid ApplicationSet froze its reconciler. Once the reconciler was frozen, the entire AppSet stopped reconciling — 47 orphans accumulated across other projects that had nothing to do with `pauseDt`. The visible symptoms looked like a Phase 2 internal-routing regression: services not reaching each other, DNS confusion, intermittent connectivity. Three hours of investigation went into the wrong direction before user pushback surfaced "have you checked the AppSet conditions?" and one API call (`.status.conditions[].ErrorOccurred`) showed the actual root cause.

PM PR #250 is the worked fix: a boundary-validation function at `src/routes/projects.ts:78-92` that rejects names not matching RFC 1123 at API entry, with the error message naming the constraint explicitly. 15 lines + 4 unit tests. The contract is now explicit (regex + tests), validated at PM's own boundary (not deferred to ArgoCD), and the failure mode that bridged "PM accepts" to "ArgoCD rejects" is closed.

The doctrine generalises beyond PM specifically: anywhere one platform component produces artefacts another consumes, the producer is responsible for validating inputs against the consumer's contract. PM is now a shared dependency for project lifecycle; any future tool that becomes a shared dependency for any artefact class inherits the same responsibility.

## Related doctrines

- [01-verify-claims-about-state.md](./01-verify-claims-about-state.md) — claims between agents get verified before propagation. This doctrine extends the same principle to *tools* — a tool's interface contract is itself a claim about state ("this input is valid"), and a downstream consumer treats it as such.
- [13-prevent-at-write-boundary.md](./13-prevent-at-write-boundary.md) — boundary validation at the tool's own input is exactly the prevent-at-write-boundary pattern; PR #250 is the worked example for both doctrines.
- [04-validation-scope-matching.md](./04-validation-scope-matching.md) — scope of validation matches scope of change. For a tool-contract change, the validation scope is "every downstream consumer's contract"; that determines what gates the tool's release.

## Cross-side note

Cross-side, structural. PM is the most-load-bearing example today (every spoke onboarding runs through PM's scaffold), but the doctrine applies to any tool that becomes a shared dependency: alfred-platform's gitops manifest generators, alfred-cc-tools' plugin catalog, secret-service's API, agent-messaging's wire protocol. Each will have its own contract surface; each is on the hook for validating at its own boundary once consumers depend on it.
