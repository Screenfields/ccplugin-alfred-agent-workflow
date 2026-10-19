---
type: doctrine
status: active
updated: 2026-05-23
description: "Workers do execution, the lead keeps synthesis: a brief is worker-fit only if writable in 3-5 sentences with a known output shape and interpretation of findings stays with the lead."
read_when: "When writing a worker brief or deciding whether a task is delegable."
---

# 10. Delegate execution, not synthesis

## Rule

Workers do **execution**; the lead keeps **synthesis**. A brief is worker-fit when (a) it's writable in 3–5 sentences with a known output shape, AND (b) synthesis of the worker's output stays with the lead. If either fails, do the work inline.

This refines doctrine 06 by naming the *boundary* of what gets delegated. "Lead/worker pattern" is the right model; the refinement is that "delegate exploration" can be misread as "delegate decisions." It is not. The lead delegates **mechanical execution** of a well-shaped task. The lead does **not** delegate the decision of what the worker's findings mean, or what fix should follow from them.

## Why it exists

Two parallel worked examples from retro #2 (2026-05-23) showed the failure mode:

- When the lead writes a tight brief and synthesises the worker's output explicitly, the pattern works.
- When the lead compresses synthesis into the brief itself ("based on findings, fix the issue"), the worker improvises synthesis from a position of partial context — and produces fixes that introduce new bugs.

The brief-with-synthesis-baked-in is the trap. It looks economical (fewer round-trips) but pushes the part of the work that most benefits from full session context (synthesis) onto the agent with the least context (the worker). Workers have no memory of prior decisions, prior corrections, prior user pushback. The lead has all of that. Synthesis is exactly the work that needs that context.

There's a secondary effect: when the lead synthesises, the synthesis becomes part of the lead's own session record. Future decisions in the same session can build on it. When the worker synthesises, the reasoning is lost the moment the worker returns — only the artefact (the fix) lands in the lead's context, with no audit trail.

## How to apply

The two conditions, both required:

1. **Writable in 3–5 sentences with a known output shape.** If the brief sprawls past 5 sentences or you can't picture the worker's output before it starts, the task is exploratory in a way that needs the lead's judgement at runtime — not worker-fit.
2. **Synthesis stays with the lead.** The worker returns *findings* or *artefacts*. The lead interprets them, decides what they mean, and chooses the next action. Do not write a brief that asks the worker to both find AND act on its findings.

Canonical good briefs:

- "Run the test suite. Report which tests failed and the first 5 lines of each failure. Do not investigate the failures." → execution only; lead synthesises.
- "Open PRs adding the new repo to these 3 ExternalSecret files. Use this commit message style. Do not merge." → mechanical execution; lead reviews + merges.
- "Read these 4 files. Summarise the request-shape contract each one assumes. Do not propose changes." → reading + summarisation; lead decides what to change.

Canonical anti-pattern briefs:

- "Investigate why PR #X is failing and fix it." → synthesis embedded; worker has to decide what's broken AND what the fix is.
- "Look at the spec failures and address them." → both find-and-act; same problem.
- "Read the codebase and refactor the auth flow." → exploratory + synthesis + execution all in one brief; worker is set up to fail.

The retro-diagnostic from doctrine 06 (5+ sequential mechanical tool calls with no decisions = signal that cluster could have been a worker brief) still applies — but the signal triggers worker-fit *only* if the work also passes both conditions above. Mechanical sequence without synthesis-staying-with-lead is not delegate-fit; it's a brief that needs reshaping first.

## Worked examples

**PM parallel RCA on the 81-leak class (PM#249).** PM ran two investigation agents in parallel: one on e2e specs, one on scaffold-flow + org-resolution. Both converged on the same root cause (`routes/projects.ts:77` silent-default-org default behaviour). Where PM kept synthesis explicit (one parallel brief per concern, then synthesis in PM's own context), the converging finding held and the fix (PM PR #250) was on-point. Where PM compressed synthesis into a "based on findings, fix the issue" brief, the worker generated a fix that introduced new bugs — same domain, different problem. The two conditions were violated in the second pattern (synthesis was delegated, not retained). Takeaway: parallel workers are good for *finding*; the lead synthesises the findings.

**alfred-cc-tools D-series (D0–D6) on 2026-05-23.** alfred-cc-tools ran 4 worker spawns across the day. The pattern that held: brief writable in 3–5 sentences, known output shape, lead reviews + merges. Clearest "chose not to spawn" decision: cc-tools read 9 alfred-platform-docs doctrines inline before designing the D2 review skill — because the *output* of reading those doctrines (which patterns to apply, which to skip) shaped the brief for the skill design. Delegating the read would have forced the lead to either trust the worker's filter or re-read everything anyway. Takeaway: when the output of reading is the brief itself, don't delegate the read — that's the synthesis happening, not the execution.

## Related doctrines

- [06-lead-worker-pattern.md](./06-lead-worker-pattern.md) — the parent doctrine. This one refines its boundary; both are load-bearing together.
- [02-scope-discipline.md](./02-scope-discipline.md) — synthesis is exactly the work the lead must not delegate; delegating it is a scope-discipline failure at the role layer.
- [01-verify-claims-about-state.md](./01-verify-claims-about-state.md) — worker findings are claims that the lead verifies during synthesis; the verify-claims discipline applies to the worker's summary just as it applies to peer-agent assertions.

## Cross-side note

Cross-side, behavioural. Every lead-agent across the platform (alfred-platform, PM, alfred-cc-tools-lead, future platform-routing / litellm / cluster-ops leads) runs its own L2 worker pattern. The execution-vs-synthesis boundary is the same on every side; the worked examples above came from two different sides on the same day, with identical shape.
