---
name: merge
description: >
  Merge a pull request with CI and label-gate checks. ALWAYS use this skill to merge PRs —
  never run `gh pr merge` directly. Enforces: (1) CI must be green, (2) GitHub's own review
  verdict must allow the merge (alfred-review check), (3) PRs labeled
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

**The hub does not merge through this skill.** If the identity is `alfred-platform-manager`, stop and report: "the hub merges with platform-gh, not this skill". There is no path in this skill where that identity merges, and the review gate below has no identity skip.

`alfred-project-manager` is a lead like the others: it merges its own PRs through `develop` and this skill. It is not refused, and it is the only identity with the elevated-merge override in the label gate.

## Step 3 — Fetch PR state

Name the PR in every report as `<CODE>#<n>` (for example `CCW#136`). CODE comes from alfred-code-lookup `<owner/repo>`; the `code` in `.alfred/config.json` is the fallback for the session's own repo only. With exit 1 or 2 and no usable config `code`, write `#<n>`.

```bash
gh pr view {N} --json number,title,labels,statusCheckRollup,headRefName,state,mergeStateStatus
```

- If `state` is already `MERGED` → report "<CODE>#<n> is already merged." and stop.
- If `state` is `CLOSED` → report "<CODE>#<n> is closed and cannot be merged." and stop.

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

## Step 5 — Review gate (hard)

GitHub's own verdict decides. This step recounts no approvals and has no identity skip. It asks `alfred-review check`, which reads `reviewDecision` with the active role and needs no review token:

```bash
AR=$(command -v alfred-review || echo "${CLAUDE_PLUGIN_ROOT}/bin/alfred-review")
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
CHECK=$("$AR" check "$REPO#{N}"); RC=$?
printf '%s\n' "$CHECK"
echo "alfred-review exit: $RC"
[ "$RC" -eq 0 ] || exit "$RC"
echo "head: $(printf '%s\n' "$CHECK" | sed -n 's/^head: //p')"
```

**Stop on any non-zero exit** and show the check's message. Do not merge, and never work around it with `--admin` or a direct `gh pr merge`:

| Exit | Meaning | What to do |
|---|---|---|
| 10 | review required, or approved but BLOCKED | get the review at the current head (`/alfred-agent:review-panel`, Step 4); the message says which case |
| 11 | a change request is outstanding | fix it, push with the lead role, and ask the reviewer to re-review |
| 5 | no read access to the PR | report it; the repo may be outside this token |
| 6 | GitHub API failure | wait and run the step again; then report the failing service |
| 2 | argument or environment error | fix the cause named in the message |

On exit 0, note the `head:` line the block printed: its 40-hex SHA is the checked head, and Step 7 merges pinned to it. Shell variables do not persist between tool calls, so carry the literal SHA into Step 7 yourself. Where the repo's rules require no review, the check says "approval not required by this repo's rules" and the merge continues, unless a reviewer has requested changes, which blocks there too (the message then says the plugin, not GitHub, blocks).

## Step 6 — Label gate (role-authorization)

Inspect the `labels` array for the label `requires-elevated-merge`.

**If the label is present AND the agent identity is NOT `alfred-project-manager`:**

Refuse merge with this message:

```
Merge blocked: this PR is labeled requires-elevated-merge.
Your identity ({agent_id}) does not have elevated merge authority.
The hub merges PRs with this label outside this skill (with platform-gh); alfred-project-manager may merge them here.
```

Stop. Do not proceed.

**If the label is present AND the identity IS privileged:** proceed (privileged override). Note the override in output.

**If the label is absent:** proceed normally.

## Step 7 — Merge

Put the literal 40-hex SHA from Step 5's `head:` line in `HEAD` below. If Step 5 gave you no `head:` line, you have no checked head: refuse to merge and go back to Step 5.

```bash
HEAD=<the 40-hex head: value from Step 5>
[[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || { echo "no checked head; refusing"; exit 2; }
gh pr merge {N} --squash --match-head-commit "$HEAD"
```

`--match-head-commit` pins the merge to the head the review gate read. If a push landed since, GitHub refuses the merge instead of merging unreviewed code: start again from Step 3.

## Step 8 — Branch cleanup

```bash
git checkout main && git pull
git branch -d {headRefName} 2>/dev/null || true
```

Fetch the merge commit SHA:

```bash
gh pr view {N} --json mergeCommit --jq '.mergeCommit.oid'
```

Report: the PR as `<CODE>#<n>`, its title, and the merge SHA.

## Rules

- **CI gate is absolute** — any check with conclusion `FAILURE`, `CANCELLED`, or `TIMED_OUT` = refuse merge. No exceptions, no `--admin` bypass. Empty `statusCheckRollup` (no CI configured) is not a failure — it is explicitly permitted with a distinct "No CI configured" message.
- **Review gate is absolute** — any non-zero `alfred-review check` = refuse merge. GitHub's `reviewDecision` is the source; the merge is pinned with `--match-head-commit`. No `--admin`, no direct `gh pr merge`.
- **Label gate applies to regular agents** — `requires-elevated-merge` = refuse unless identity is `alfred-project-manager`; the hub merges such PRs outside this skill.
- **`requires-coverage-decision` does NOT block merge** — it is informational only; proceed normally when this label is present.
- **Never use `--admin`** to bypass checks or the review gate. If checks can't be bypassed legitimately, escalate.
- **If unsure whether CI is complete**, query `gh pr checks {N}` and wait before proceeding.
- **Always squash merge** — use `--squash` flag. Do not use `--merge` or `--rebase` unless the user explicitly overrides.
