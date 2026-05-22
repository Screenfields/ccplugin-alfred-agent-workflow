---
name: review
description: >
  Structured PR review with doctrine-aligned angles. Two modes: interactive (conversational,
  agent-triggered) and headless (structured markdown output for CI/PR comment, exit code).
  Use when reviewing a PR for correctness, doctrine adherence, and scope hygiene.
  Invoke as: /alfred-agent:review [#N] [--mode=headless]
allowed-tools: Bash, Read, WebFetch
---

# PR Review

Structured review workflow covering 9 doctrine-aligned angles. Runs in two modes:

- **Interactive** (default): conversational summary with a merge recommendation. Use when a human or agent invokes this skill directly in a Claude Code session.
- **Headless** (`--mode=headless`): emits a structured markdown block to stdout and exits with a machine-readable exit code. Intended for GH Actions CI jobs that post the output as a PR comment. The caller is responsible for posting; this skill only produces the text.

Do not skip angles. Do not auto-approve without completing all steps.

## Step 1 — Resolve the PR

If a PR number `#N` was supplied in the invocation, use it. Otherwise infer from the current branch:

```bash
gh pr view --json number,title
```

If no PR is found (no `#N` and branch has no associated PR), stop and report: "No PR found. Provide a PR number with /alfred-agent:review #N."

If the diff is empty or the PR is already merged, report that fact and stop.

Fetch full PR data:

```bash
gh pr view {N} --json number,title,body,baseRefName,headRefName,author,additions,deletions,changedFiles,labels,statusCheckRollup
gh pr diff {N}
```

Hold this data in context for all subsequent steps.

## Step 2 — Apply review angles

Work through ALL nine angles below. For each angle, scan the diff and PR body for violations. Record every finding with:

- **Severity** — one of: `BLOCKER`, `WARNING`, `NOTE`
- **Angle label** — e.g. `doctrine-01`
- **Location** — `path/to/file:line` where determinable
- **Description** — what the problem is and why it matters

Severity definitions:
- **BLOCKER** — must be fixed before merge; constitutes a genuine defect, security issue, or doctrine violation with real consequences
- **WARNING** — should be fixed; may degrade quality or cause future pain but is not merge-blocking
- **NOTE** — suggestion or question; purely informational

### Angle 1 — Doctrine 01: State verification

Does any code act on state claims (config values, API responses, live resource state) that are unverified at act-time? Look specifically for:

- Multi-layer chains (e.g., permission at App layer → manifest layer → live token) where the code checks one layer and assumes a single PASS propagates through all subsequent layers
- Hardcoded references to state that should be queried live (e.g., hardcoded role ARNs, static cluster names, baked environment assumptions)
- Cached or memoized values being acted on without staleness checks when the underlying resource may have changed

Flag any instance where the code makes an assumption about live state without verifying it at act-time.

### Angle 2 — Doctrine 02: Scope discipline

Compare the PR title and body description against the actual diff.

- Does the PR do more than it claims?
- Are there changes that go beyond the stated intent — "while I'm here" additions (refactors, formatting sweeps, unrelated config changes)?
- Are there changes the body claims but the diff does not show?

Flag discrepancies in either direction.

### Angle 3 — Doctrine 03: Namespace disambiguation

Skip this angle unless the PR body, title, or diff explicitly shows cross-system artifact names (PR numbers, GitHub App identities, environment names, phase labels). If the pattern is not present, do not force-fit. If it is present:

- Are identifiers that exist in multiple systems (e.g., PR #42 in repo A vs repo B, "staging" in cluster A vs cluster B) properly prefixed with system+context?
- Are bare identifiers used in places where ambiguity could cause misdirected actions?

Flag bare identifiers that are genuinely ambiguous in context.

### Angle 4 — Doctrine 04: Validation scope matching

Review the test plan in the PR body (if present) against the surface area of the diff.

- **Over-tested narrow change:** heavy test gates (E2E suites, broad integration runs) blocking a one-line or trivially bounded change
- **Under-tested wide change:** narrow or absent test plan for a diff that touches multiple modules, external integrations, or critical paths

Flag mismatches in either direction.

### Angle 5 — Doctrine 05: Sweep completeness

If this PR fixes a bug or corrects a pattern:

- Does the diff fix only the pointed-at instance, while leaving analogous uses of the same pattern in the same files or modules untouched?
- Are there other call sites, similar functions, or parallel code paths that exhibit the same defect?

Flag partial fixes. If the PR body explicitly acknowledges the remaining instances and defers them, note that as a NOTE rather than a BLOCKER.

### Angle 6 — Doctrine 07: Filesystem/ground-truth over metadata

Does the code read live state (filesystem reads, live API calls, database queries) or does it rely on in-body metadata (frontmatter dates, summary fields, env vars baked at deploy time, committed config snapshots) as if that metadata were current ground truth?

Flag any place where metadata is treated as authoritative for decisions that require live verification.

### Angle 7 — Doctrine 08: PR scope discipline

Does this PR bundle multiple separable logical concerns?

- Separate bug fixes that are unrelated to each other
- Feature additions alongside unrelated doc updates
- Refactors mixed with behavioral changes

Note: bundling is acceptable when concerns are cohesive (e.g., a single feature touching multiple layers together). Flag only when concerns are genuinely separable AND separation would benefit review clarity or rollback safety.

### Angle 8 — Doctrine 09: Cleanup contract

Does any change create persistent state that outlives the operation?

- Kubernetes resources, host config file modifications, scaffolded repositories, `/tmp` artifacts intended to persist, database records, cloud resources

If yes: is the teardown path declared in the same diff (deletion logic, TTL, cleanup job, documented manual step)?

Flag state creation without a declared teardown.

### Angle 9 — Standard technical review

**Security:**
- Secrets or tokens hardcoded in source or config files?
- Command injection via unquoted shell variables?
- SQL or template injection via unsanitized user input?
- Unvalidated external input at system boundaries (HTTP endpoints, CLI args, file paths from external sources)?

**Correctness:**
- Obvious logic errors (inverted conditions, wrong operator, incorrect variable)?
- Off-by-one in loops or index operations?
- Missing error handling at actual system boundaries (network calls, subprocess invocations, file I/O) — do not flag missing error handling for internal pure functions where it adds no value

**Dead code:**
- Unused variables or imports left after a refactor?
- Unreachable branches (conditions that are always true/false given context)?

**Naming:**
- Are new identifiers (functions, variables, files, flags) clear and consistent with the repo's established conventions?

## Step 3 — Synthesize findings

Collect all findings recorded during Step 2. Group by severity: BLOCKERs first, then WARNINGs, then NOTEs.

Determine the merge recommendation:
- **APPROVE** — zero BLOCKERs and zero WARNINGs (or only NOTEs)
- **APPROVE WITH COMMENTS** — zero BLOCKERs, one or more WARNINGs
- **REQUEST CHANGES** — one or more BLOCKERs

### Interactive mode output (default)

Produce a conversational summary:

1. One-sentence verdict: "Clean — no blockers found." or "N blocker(s), M warning(s) found."
2. Findings grouped by severity. For each finding include the angle label, file:line where available, and a plain-language explanation.
3. Merge recommendation on its own line: `Recommendation: APPROVE / APPROVE WITH COMMENTS / REQUEST CHANGES`

### Headless mode output (`--mode=headless`)

Emit the following markdown block to stdout, fully filled in:

```markdown
## Review — alfred-agent:review

**Verdict:** APPROVE | APPROVE WITH COMMENTS | REQUEST CHANGES
**Blockers:** N | **Warnings:** M | **Notes:** K

### Blockers
- [doctrine-08] `path/to/file:42` — description of the issue.

### Warnings
- [doctrine-05] `path/to/file:17` — description of the issue.

### Notes
- [technical] `path/to/file:88` — suggestion or question.

---
*Reviewed by alfred-agent:review against alfred-platform-docs doctrines 01–09.*
```

If a section has no findings, omit it or write `_None._` under the heading.

After emitting the markdown block, exit with the appropriate code:
- `exit 0` — no BLOCKER findings
- `exit 1` — one or more BLOCKER findings

## Rules

- Never auto-approve without running all 9 angles.
- BLOCKER findings must block the merge recommendation. Do not soften a BLOCKER to a WARNING because the fix looks easy.
- In headless mode, the exit code is the only machine-readable signal — always exit explicitly. Do not omit the exit statement.
- Do not post the PR comment yourself in headless mode. Emit the markdown to stdout only; the GH Actions caller posts it.
- Doctrines 03 (namespace) and 06 (lead-worker pattern) do not naturally surface in code diffs. Skip Angle 3 and omit Doctrine 06 entirely unless the PR body or title explicitly exhibits those patterns. Do not force-fit.
- If the diff is empty or the PR is already merged, report and stop — do not produce a verdict.
- File:line references are best-effort. If a finding is pattern-level (across multiple locations) rather than a single line, describe the pattern and list representative locations.
