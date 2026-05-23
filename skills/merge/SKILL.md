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

First, determine how many checks are configured on this PR:

```bash
gh pr view {N} --json statusCheckRollup --jq '.statusCheckRollup | length'
```

Then apply exactly one of the four cases below based on the result:

**Case A — No CI configured (empty `statusCheckRollup`, length = 0):**

- Output: "No CI configured on this repo — merging without check verification."
- This is distinct from "all checks passed." There are zero checks, not passing checks.
- Proceed. Do not block.

**Case B — Checks still running (any check with state `PENDING`, `IN_PROGRESS`, or `QUEUED`):**

- Output: "CI checks are still pending. Wait for checks to complete before merging."
- Stop. Do not merge yet. The agent may re-run this skill once checks finish, or run `gh pr checks {N}` to monitor progress.

**Case C — All checks passed (all checks in `SUCCESS` or `SKIPPED` state, count > 0):**

- Output: "All {N} checks passed."
- Proceed normally.

**Case D — Checks failed (any check with conclusion `FAILURE`, `CANCELLED`, or `TIMED_OUT`):**

- Collect the names of all failing/cancelled/timed-out checks.
- Output: "CI checks failed: {list of failing check names}. Halting merge."
- Halt. Do not proceed under any circumstances. Never merge on red CI. No exceptions.

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

- **CI gate is absolute** — any check with conclusion `FAILURE`, `CANCELLED`, or `TIMED_OUT` = refuse merge. No exceptions, no `--admin` bypass. Empty `statusCheckRollup` (no CI configured) is not a failure — it is explicitly permitted with a distinct "No CI configured" message.
- **Label gate applies to regular agents** — `requires-elevated-merge` = refuse unless identity is `alfred-platform-manager` or `alfred-project-manager`.
- **`requires-coverage-decision` does NOT block merge** — it is informational only; proceed normally when this label is present.
- **Never use `--admin`** to bypass checks. If checks can't be bypassed legitimately, escalate.
- **If unsure whether CI is complete**, query `gh pr checks {N}` and wait before proceeding.
- **Always squash merge** — use `--squash` flag. Do not use `--merge` or `--rebase` unless the user explicitly overrides.
