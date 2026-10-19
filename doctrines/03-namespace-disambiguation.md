---
type: doctrine
status: active
updated: 2026-05-22
description: "Artifact names that exist in multiple systems are ambiguous by default; prefix with system+context from the first mention onward."
read_when: "When a name (smoke, gate, PR number, App identity, phase number) could refer to artifacts in more than one system in current scope."
---

# 03. Namespace cross-system artifact names

## Rule

Names that exist in multiple systems are ambiguous by default. When an artifact name (smoke, MARKER, gate, sync, App identity, Phase numbering, PR number) exists in more than one system in current scope, prefix with system+context from the first mention onward.

## Why it exists

Cross-system naming collisions cause derailment. Two different artifacts called "smoke" each have their own design, triggers, purpose; reasoning across them as if they're the same thing leads to wasted work and wrong-direction commits. The same applies to PR numbers (PM has its own numbering vs alfred-platform), GitHub App identities (`alfred-worker-agent` vs `alfred-project-manager`), and any other identifier-class shared between projects.

The cost surfaces late. A discussion proceeds for several rounds with the implicit assumption that "the smoke test" refers to one artifact, then halfway through it becomes clear the two sides have been talking about different artifacts the whole time. By that point, design decisions have been made on top of the wrong identification.

Prefixing from the first mention is cheaper than back-disambiguating. The discipline is to default to prefixed, not to wait for ambiguity to surface.

## How to apply

- Prefix from first mention. "alfred-platform connectivity smoke (#377)" not "smoke (#377)". "PM PR #233" not "PR #233". "alfred-project-manager App" not "the App".
- The trigger: is this identifier-class shared across projects/systems in current scope? If yes, prefix.
- When in doubt, add the prefix. The overhead of explicit prefixing is much smaller than the overhead of back-disambiguating after derailment.
- Responsibility: every agent at every mention. New shared names get added to the implicit list as they emerge.

## Worked examples

**"smoke" conflation.** alfred-platform used "smoke" undifferentiated when PM smoke spec (`e2e/smoke.spec.ts`) and alfred-platform connectivity smoke (`#377`) are distinct artifacts with different designs and triggers. User had to explicitly partition: "Make a distinction between the alfred-platform smoke test and PM smoke test. Do not worry about PM smoke test, I will get rid of this." Takeaway: undifferentiated shared names always require an external party to partition them.

**PM's `alfred-worker-agent` mis-reference.** When discussing Phase 3 catalog-writer identity grants, PM referenced `alfred-worker-agent` but the correct App was `alfred-project-manager`. The mis-reference would have led to a wrong-target permission proposal. Both Apps exist; both are in scope; both needed prefix-discrimination. Takeaway: GitHub App identities are exactly the kind of identifier-class that needs prefixing — easy to confuse, expensive to act on the wrong one.

**"PR #233".** Exists on the PM repo; calling it "PR #233" without "PM" prefix could be confused with an alfred-platform PR. Takeaway: PR numbers are per-repo; cross-repo discussion needs the repo prefix.

## Related doctrines

- [01-verify-claims-about-state.md](./01-verify-claims-about-state.md) — verifying the identity of the artifact being discussed is a special case of verifying claims.
- [05-sweep-open-uses-after-correction.md](./05-sweep-open-uses-after-correction.md) — once a naming collision is surfaced, sweep open uses of the bare name to prefix them.

## Cross-side note

Cross-side, symmetric. Both sides do this for shared names. The set of shared names is open-ended and grows over time — App identities, PR numbers, phase numbers, test artifact names, sync semantics. New shared names get added to the discipline as they emerge.
