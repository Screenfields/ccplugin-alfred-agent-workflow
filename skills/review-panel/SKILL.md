---
name: review-panel
description: >
  Lead-side skill for spawning a throwaway code-reviewer worker with a structured brief.
  Prevents vibes-based reviews by requiring spec + diff + lenses + output requirements
  before spawning. Mandatory adversarial clause for write-boundary guards (Kyverno,
  validation webhooks, admission gates). ADR-0010, Phase 1.
allowed-tools: Bash, Read
---

# Review Panel — Worker Brief

Lead-side workflow for structured code reviews delegated to a throwaway worker. Complete Steps 1–3 before spawning; deliver via Step 4.

## Step 1 — Fill the brief

Complete every field. A brief with any field left blank is invalid — do not spawn.

---

**Spec / requirements:**

> Link to the issue, ADR, design doc, or accepted spec this change implements. If no written spec exists, paste the acceptance criteria inline. Review without a spec is vibes — do not spawn without this field.

**Head SHA (lead reads it before the diff is written):**

> ```bash
> gh pr view {N} --repo {owner/repo} --json headRefOid --jq .headRefOid
> ```
>
> Read it before writing the diff, and again after. If the two differ, the PR was pushed to: fetch the diff again. The review is posted at this SHA in Step 4.

**Diff (file path — lead fetches before spawning):**

> Fetch the diff yourself before spawning and write it to a file, then pass that path:
>
> ```bash
> gh pr diff {N} --repo {owner/repo} > /tmp/review-{N}.diff
> ```
>
> Then set this field to `/tmp/review-{N}.diff`. The worker will Read it. Do not ask the worker to run `gh pr diff` — code-reviewer agent types commonly lack a Bash tool. Passing a diff inline is acceptable for small diffs (< ~200 lines).

**Lens list** (remove any that do not apply; add domain-specific lenses as needed):

- Spec conformance — does the implementation match the agreed requirements?
- Worst failure mode — what is the highest-impact way this component class could fail in production?
- Security — no secrets or tokens in source/logs; no command injection; no unvalidated input at system boundaries
- Backward compatibility — does this break existing callers, on-disk formats, or API contracts?

**Expected output:**

> High-confidence findings only. Each finding must include a `path/to/file:line` reference and a plain-language explanation of why it matters. No summaries of what the code does — findings only. Final verdict: APPROVE, APPROVE WITH COMMENTS, or REQUEST CHANGES.

---

## Step 2 — Write-boundary guard adversarial clause (mandatory when applicable)

**Skip this step if the diff does not touch a Kyverno policy, validation webhook, or other admission/write-boundary guard.**

If the diff does touch a write-boundary guard, append the following section to the brief under the heading `## Adversarial: write-boundary coverage`. Fill in the specifics for the policy or webhook being changed.

    ## Adversarial: write-boundary coverage

    For every policy / webhook / gate introduced or modified in this diff, enumerate ALL
    evaluation paths and confirm each is covered or explicitly excluded with justification.

    Kyverno policies:
    - containers — direct pod containers
    - initContainers — init containers (commonly missed in author-only checks — see 2026-06-12 devbox-ceiling regression)
    - ephemeralContainers — debug/ephemeral containers
    - autogen variants: Deployment, StatefulSet, DaemonSet, Job, CronJob (Kyverno autogenerates
      rules for these; verify the autogen policy covers all intended workload types)

    Validation webhooks / admission gates:
    - All resource kinds in rules[].resources
    - All operations in rules[].operations (CREATE, UPDATE, DELETE)
    - failurePolicy appropriateness (Fail vs Ignore) given this gate's criticality

    For each path: is it covered? If excluded, is the exclusion intentional and documented?

**Why this clause is mandatory:** The devbox-ceiling regression (2026-06-12) propagated fleet-wide because an author-only check verified `containers` but missed `initContainers`. This clause prevents that class of gap.

---

## Step 3 — Spawn the worker

Spawn via the Agent tool. Use `subagent_type: "code-reviewer"` if that type is available in the session's agent registry; otherwise omit and use the default.

Pass the completed brief (Steps 1–2, including the `Head SHA` field) as the prompt verbatim — the brief IS the prompt; do not add preamble. The diff file written in Step 1 must exist on disk before spawning; the worker will Read it.

```javascript
Agent({
  description: "Code review: <PR title or short description>",
  subagent_type: "code-reviewer",  // use if available
  prompt: "<full brief from Steps 1–2>"
})
```

> **Note:** code-reviewer agent types commonly have Read/Grep/Glob/WebFetch only — no Bash. The lead-fetches-diff pattern in Step 1 is the default for this reason. If you know the chosen agent type has Bash available, you may instead include `gh pr diff {N} --repo {owner/repo}` in the brief and let the worker fetch it.

---

## Step 4 — Filter and deliver

When the worker returns:

1. **Extract high-confidence findings only.** BLOCKERs and WARNINGs with a specific `file:line` reference qualify. NOTEs, "worth considering" items, and pattern-level suggestions without a location do not.
2. **Never forward raw worker text.** Summarize findings in your own words; cite `file:line`. The worker is a tool, not a co-author.
3. **Deliver the verdict.** Post your own synthesis as a GitHub review with `alfred-review post`, at the SHA the worker reviewed (the `Reviewed at:` line of its output, which must equal the brief's `Head SHA`), and reply to the requesting agent. State the verdict clearly: APPROVE, APPROVE WITH COMMENTS, or REQUEST CHANGES.

If the worker returns no high-confidence findings, the verdict is APPROVE — state this explicitly rather than forwarding an empty or hedged worker response.

### Posting the review

Write your synthesis (not the raw worker text) to a file and post it. APPROVE and APPROVE WITH COMMENTS go to `approve` (the warnings go in the body); REQUEST CHANGES goes to `request-changes` with the findings as the body. `post` adds the first line `Reviewed by: <agent_id> (alfred-agent:review)`.

```bash
AR=$(command -v alfred-review || echo "${CLAUDE_PLUGIN_ROOT}/bin/alfred-review")
"$AR" post {owner}/{repo}#{N} --sha {head-sha} --verdict approve|request-changes --body-file /tmp/review-{N}.md
```

- **Exit 3** (head moved): the PR was pushed to since the brief. Review the new head; do not post the old review.
- **Exit 4** (no review token on this devbox): run `"$AR" check {owner}/{repo}#{N}`. On `not-required`, skip posting and say so. On anything else, stop with "no review token on this devbox, and a review is required on {repo}: ask the hub".
- **Exit 5** (the review token does not reach the repo): `post` prints the widen ask. Pass it on. This is not "no review token".
- **Exit 6** (GitHub API failure): wait and try again, then report the failing service. **Exit 2**: an argument or environment error; read the message (`GH_TOKEN` set: unset it, never work around it).

The worker never posts: `code-reviewer` is read-only. The lead posts, with the review token, and never with the lead token.

## Review by another lead

A lead may ask another lead to review. That lead reviews from its own devbox with its own `review` token and posts with the same command. On GitHub this is the same login (`alfred-worker-agent[bot]`) as any other lead's review, so GitHub cannot tell the leads apart: the first body line `Reviewed by: <agent_id> (alfred-agent:review)` names the lead, and that is observability, not a control.

- If `post` reports no access (exit 5), the reviewing lead sends the widen ask to the hub: message `hub`, subject `[review-access] <reviewing-lead> -> <owner/repo>`, with the reviewing lead, the target repo, the PR URL or reason, and whether the access is standing or for this PR only. The hub's worker adds the repo to that lead's review token generator only, and the new token takes effect after the ESO refresh, so do not promise immediate access. Meanwhile the PR's lead can use its own review sub-agent.
- If a change request is outstanding after a fix, the PR's lead asks the lead who requested it to re-review at the new head. If that lead is gone or does not respond, ask the hub to dismiss the review with a written reason. No skill dismisses a review.
