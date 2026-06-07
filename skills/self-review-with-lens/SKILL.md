---
name: self-review-with-lens
description: >
  Diff-aware self-review prompt for autonomous worker sessions. Fed via adapter_review
  with a selected lens. Reviews the diff through the specified lens and emits a
  structured verdict: PASS, ADVISORY, or CRITICAL.
allowed-tools: Bash, Read
---

# Self-Review With Lens

You are reviewing a diff through a specific lens. Be honest and rigorous — ADVISORY and
CRITICAL verdicts are the point of this review, not a failure. A false PASS that lets a
real problem through is worse than a correct CRITICAL that blocks a merge.

Your review lens is provided in the context. Apply only the lens you were given.

---

## Lens: backwards-compat

Focus: public interfaces, exported functions, config schemas, wire formats.

Check:
- Does any existing caller of a changed public API, endpoint, or config field break?
- Are removed or renamed fields handled with deprecation or fallback?
- Is the change compatible with the oldest supported client or version?

Verdict: PASS if all public interfaces remain compatible. ADVISORY if a breaking
change is intentional, documented, and the caller base is known. CRITICAL if callers
will break without a migration path.

---

## Lens: security

Focus: auth, secrets, RBAC, input validation, injection surfaces.

Check:
- Are credentials, tokens, or secrets ever logged, returned in responses, or written
  to disk in plaintext?
- Are new input surfaces validated and sanitized against injection?
- Does the change expand privilege scope without a corresponding auth gate?
- Do new dependencies have known vulnerabilities?

Verdict: PASS if no new attack surface is introduced. ADVISORY if a hardening
improvement exists but the change is not exploitable as-is. CRITICAL if a clear
vulnerability is introduced.

---

## Lens: intentional-vs-accidental-tests

Focus: test file changes — distinguish intentional updates from accidental regressions.

For each changed test file:
- Does the change extend coverage, update a contract, or reflect a genuine spec change?
- Or does it weaken an assertion, add a skip, delete a check, or tighten a mock to
  make a failing test pass?

Signals of intentional: description updated, new assertion added, coverage extended.
Signals of accidental: assertion deleted or weakened, `skip`/`xit` added, mock
over-specified to silence a failure.

Verdict: PASS if all test changes are intentional. ADVISORY if some changes look
suspicious but no coverage is clearly lost. CRITICAL if a test was modified to hide
a regression.

---

## Lens: visual

Focus: UI changes — layout, visual regression, accessibility.

Check:
- Do diff changes touch rendering logic, CSS, or component props affecting visual output?
- Are snapshot tests updated? If so, do the snapshot diffs look intentional (not
  unexpectedly large or structurally wrong)?
- Are ARIA attributes, keyboard navigation, or color contrast affected?

Verdict: PASS if visual changes are intentional and snapshots are updated. ADVISORY
if visual changes are present without snapshot update (may be intentional, may be a
miss). CRITICAL if accessibility is broken or snapshot diffs are unexpectedly large
without justification.

---

## Lens: spec-compliance

Focus: architecture and convention — does the implementation follow the project spec,
CLAUDE.md, and established patterns?

Check:
- Does the implementation match the design in any linked spec or design doc?
- Are naming conventions, file organization, and layer boundaries respected?
- Are new patterns introduced that diverge from the existing architecture without
  a justification in the PR description?

Verdict: PASS if the implementation follows established patterns. ADVISORY if there
is a minor intentional divergence with a clear reason. CRITICAL if the implementation
contradicts the spec or introduces an unjustified architectural deviation.

---

## Output

After your review, write 2–5 sentences of rationale, then emit your verdict on its
own line:

```
<verdict>PASS</verdict>
```
```
<verdict>ADVISORY</verdict>
```
```
<verdict>CRITICAL</verdict>
```

Do not emit PASS if you found a genuine concern, even minor. Do not emit CRITICAL for
stylistic preferences that don't affect correctness or safety.
