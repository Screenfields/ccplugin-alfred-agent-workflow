---
name: merge
description: >
  Merge a pull request with CI and label-gate checks. ALWAYS use this skill to merge PRs —
  never run `gh pr merge` directly. Enforces: (1) CI must be green, (2) PRs labeled
  requires-elevated-merge cannot be merged by regular agent identities.
  Use when the user says "merge", "merge this PR", "merge #N", or when a develop workflow
  reaches the merge step.
allowed-tools: Bash, Read
---

# alfred-agent:merge

Authoritative merge procedure. Invoked via `/alfred-agent:merge [PR-number]`.

## Step 1 — Resolve PR

If a PR number argument was provided (e.g. `/alfred-agent:merge 42`), use that number.

Otherwise, infer from the current branch:

```bash
gh pr view --json number,title
```

If no PR is found, stop and report: "No PR found for the current branch. Provide a PR number explicitly."

## Step 2 — Read agent identity

Read `.alfred/config.json` in the project root:

```bash
cat .alfred/config.json 2>/dev/null || echo "{}"
```

Extract the `agent_id` field. If the file is missing or the field is absent, treat identity as unknown (non-privileged).

Privileged identities: `alfred-platform-manager`, `alfred-project-manager`.

## Step 3 — Fetch PR state

```bash
gh pr view {N} --json number,title,labels,statusCheckRollup,headRefName,state,mergeStateStatus
```

- If `state` is already `MERGED` → report "PR #{N} is already merged." and stop.
- If `state` is `CLOSED` → report "PR #{N} is closed and cannot be merged." and stop.

## Step 4 — CI gate (hard)

Inspect `statusCheckRollup`. Find any check where `conclusion` is `FAILURE`, `CANCELLED`, or `TIMED_OUT`.

If any such check exists:

- **Refuse merge.** Print the names of the failing/cancelled/timed-out checks.
- Report: "Merge blocked: CI is not green. Fix the following checks before merging: {check names}."
- Stop. Do not proceed under any circumstances. Never merge on red CI. No exceptions.

If all checks are `SUCCESS` or `SKIPPED`, proceed.

If checks are still pending (`IN_PROGRESS`, `QUEUED`), report: "CI checks are still running. Re-run this skill once they complete, or query `gh pr checks {N}` to monitor progress." Stop.

## Step 5 — Label gate (role-authorization)

Inspect the `labels` array for the label `requires-elevated-merge`.

**If the label is present AND the agent identity is NOT `alfred-platform-manager` or `alfred-project-manager`:**

Refuse merge with this message:

```
Merge blocked: this PR is labeled requires-elevated-merge.
Your identity ({agent_id}) does not have elevated merge authority.
A privileged agent (alfred-platform-manager or alfred-project-manager) must merge this PR.
```

Stop. Do not proceed.

**If the label is present AND the identity IS privileged:** proceed (privileged override). Note the override in output.

**If the label is absent:** proceed normally.

## Step 6 — Merge

```bash
gh pr merge {N} --squash
```

## Step 7 — Branch cleanup

```bash
git checkout main && git pull
git branch -d {headRefName} 2>/dev/null || true
```

Fetch the merge commit SHA:

```bash
gh pr view {N} --json mergeCommit --jq '.mergeCommit.oid'
```

Report: PR number, title, and merge SHA.

## Rules

- **CI gate is absolute** — any check with conclusion `FAILURE`, `CANCELLED`, or `TIMED_OUT` = refuse merge. No exceptions, no `--admin` bypass.
- **Label gate applies to regular agents** — `requires-elevated-merge` = refuse unless identity is `alfred-platform-manager` or `alfred-project-manager`.
- **`requires-coverage-decision` does NOT block merge** — it is informational only; proceed normally when this label is present.
- **Never use `--admin`** to bypass checks. If checks can't be bypassed legitimately, escalate.
- **If unsure whether CI is complete**, query `gh pr checks {N}` and wait before proceeding.
- **Always squash merge** — use `--squash` flag. Do not use `--merge` or `--rebase` unless the user explicitly overrides.
