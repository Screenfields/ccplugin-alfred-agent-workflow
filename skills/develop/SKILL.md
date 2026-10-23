---
name: develop
description: >
  Feature development workflow: pick up an issue, write code with tests, create PR, merge.
  Use when the user says "work on issue #X", "implement this", "pick up the next issue",
  "start developing", or when you need to make code changes that should go through a PR.
  This is the standard development procedure for all code changes in devbox environments.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Agent, SendMessage
---

# Feature Development

Standard workflow for implementing features in a devbox. Every code change follows this flow.

## The builder and code reviewer pair

The lead keeps design, choices, combining results and merging. Workers build, each in its own worktree. The lead does the role switch of Step 2 first. The lead creates the branch and its worktree as Step 2 shows, and the builder works in that worktree. The lead's main tree is never on that branch. The lead then briefs a `builder` (`agents/builder.md`). The brief links the work item and carries the purpose (the issue's acceptance criteria), the end state (tests first, then the implementation and the commit, as Steps 3 to 5 describe), the worktree path and branch, and the bounds. One bound is: commit on the branch, do not push, because `agents/builder.md` otherwise ends with a push. Every push stays the lead's (Step 6).

The `code-reviewer` (`agents/code-reviewer.md`, or the `document-reviewer` for documents only) reviews the builder's output. Step 7 starts it. Findings go back to the same builder with SendMessage to its agent ID, and the fix goes to the same reviewer, until the reviewer passes it or `alfred-config get failed-review-max` failed rounds have failed. After that the lead escalates to the hub (routed rule `work-and-review-in-pairs`, the Review paragraph of `agreement/lead.md`). The builder commits each fix and the lead pushes it. For each re-review, refresh the Head SHA and the diff as in review-panel Step 1, then send the new brief to the same reviewer with SendMessage to its agent ID.

### The light path

A small item (the Size paragraph of `agreement/lead.md`) takes the light path. Small work (AP-ADR0017) skips the designed state and has a lighter reviewer, but every transition it does take still passes a review (AP-ADR0022, Sizing). In practice:

- A worker still builds. The lead briefs a `builder` as above.
- The reviewer is started with the tier and effort that `reviewer-light` gives in `model-setting-per-role`. Read them with `alfred-config get model-setting-per-role`, never from memory. The tier maps to a model through the tier map in the README (section "Specialists (`agents/`)", where medium is sonnet). Effort is passed as is, except `highest`, which is `max`. Add `model` and `effort` to the Agent call in review-panel Step 3.
- Step 7 applies unchanged, and fix rounds follow the loop above.

## Step 1: Pick up the issue

- Read the issue: `gh issue view {N}`
- Understand acceptance criteria before writing any code
- If acceptance criteria are unclear, ask the user (or message the platform agent)

## Step 2: Create a branch

> **Role-switching modes:** Some devboxes (e.g., project-manager) have multiple roles and the `switch-role` command installed. Most projects use a **single-role devbox** where `switch-role` is not installed. To detect which mode applies:
> ```bash
> command -v switch-role >/dev/null 2>&1 && echo "multi-role" || echo "single-role"
> ```
> - **Multi-role devbox** (e.g., project-manager): `switch-role` is installed; run role-switch commands as shown.
> - **Single-role devbox** (most projects): `switch-role` is not installed; skip role-switch steps and use the same token throughout.

**If multi-role devbox** (`switch-role` is installed):
```bash
switch-role build
git fetch origin
git worktree add -b feature/issue-{N}-{short-description} <path> origin/main
```

**If single-role devbox** (`switch-role` is not installed — skip the role switch):
```bash
git fetch origin
git worktree add -b feature/issue-{N}-{short-description} <path> origin/main
```

This is a single-role devbox — `switch-role` is not installed. Use the same token throughout.

Always branch from up-to-date main: fetch first, then add the worktree from `origin/main`. The branch lives in the worktree at `<path>`, and the main tree is never on it. Run the commands of Steps 3 to 5 from `<path>`, and use `git -C <path>` for git commands run from elsewhere. Use `feature/` prefix for new work, `fix/` for bug fixes.

## Step 3: Write tests first

Before writing implementation code, write a test that describes the expected behavior.

**Why tests first:** Tests define what "done" looks like. Writing them first prevents implementing the wrong thing and ensures every feature has coverage. An untested feature is an unfinished feature.

**Practical approach:**
- For API endpoints: test request/response, validation, error cases
- For services: test the public interface with expected inputs/outputs
- For UI components: test that key interactions work

Run the test — it should fail (the feature doesn't exist yet):
```bash
npm test
```

## Step 4: Implement

Write the minimum code to make the test pass. Then:
```bash
npm test        # All tests pass
npm run build   # TypeScript compiles clean
```

If the feature needs multiple parts, iterate: test → implement → test → implement.

## Step 5: Commit

Use the `/commit` skill or follow commit conventions:
- Stage specific files (never `git add -A`)
- Imperative mood, max 72 chars
- No AI/Claude/Anthropic references
- Reference the issue: "fix #N" or "closes #N" in the body

## Step 6: Push and create PR

**Workers only commit, with any author. Every push, and the PR creation, uses the lead role.** The review identity (the `build`, `spec` and `review` roles are one GitHub login) reviews the PR, and GitHub does not count an approval from the PR's author or its last pusher. A push made with `build` would make the reviewer the last pusher and no approval could count.

**If multi-role devbox** (`switch-role` is installed):
```bash
switch-role lead
git -C <path> push -u origin feature/issue-{N}-{short-description}
gh pr create --head feature/issue-{N}-{short-description} --title "{short title}" --body "Closes #{N}

## Changes
- {what changed}

## Testing
- {what was tested}"
```

**If single-role devbox** (`switch-role` is not installed):
```bash
git -C <path> push -u origin feature/issue-{N}-{short-description}
gh pr create --head feature/issue-{N}-{short-description} --title "{short title}" --body "Closes #{N}

## Changes
- {what changed}

## Testing
- {what was tested}"
```

**Verify CI status before proceeding.** After the PR is created, wait for CI to complete and query the result directly:

```bash
gh pr checks {PR}                    # quick per-check status view
gh run view {run-id} --log-failed    # detail on a failed run
```

**Never infer CI status from the diff.** Phrases like "the change is small," "nothing could fail," "one-line fix," or "shouldn't be affected" are not substitutes for a check-status query. Always call `gh pr checks` and report what the tool returns.

**If an API call appears unavailable, attempt it before claiming so.** "Not visible in this context" is never an acceptable first-pass claim — try the call, report the actual error. The GitHub App token that authored the PR can read the PR's checks.

If CI is green, proceed to Step 7 (review, then merge). If any check reports FAILURE / CANCELLED / TIMED_OUT, see Step 6.5.

## Step 6.5: When CI fails

**Red CI blocks merge-ready, no exceptions.** A PR with a failing check is not merge-ready regardless of merge-conflict status, diff size, or how unrelated the failure "seems." A mergeable-per-git PR with red CI is still not mergeable.

Your options when CI is red:

1. **Investigate and fix the root cause.** `gh run view {run-id} --log-failed` shows the actual failure — read it fully before deciding what to change.
2. **Escalate to the user** with the failure output and a description of what you've tried, if you cannot confidently identify the fix.

Never merge on red CI. Never declare the PR ready to merge while CI is red.

The fix for a red check is a push, and a push is the lead's. The builder commits the fix, the lead pushes it with the lead role (the new head needs a new review):

**If multi-role devbox:**
```bash
switch-role lead
git -C <path> push
```

**If single-role devbox:**
```bash
git -C <path> push
```

### Before patching a scaffold-generated or platform-owned file

Scaffold-generated files (`.github/workflows/*.yaml`, `k8s/base/*.yaml`, `Dockerfile`, files with a `.hbs` template origin) encode intent that isn't obvious from a single failing line. Before editing, you MUST:

1. **Read the full file**, not just the failing section.
2. **State a one-sentence theory** of what the file/step does and what sub-concern is failing. Format: *"this file/section is responsible for X; the failure is in sub-concern Y; my proposed fix preserves X while resolving Y."* If you cannot state this confidently, **escalate to the user** rather than guess.
3. **Identify downstream consumers** of the file's outputs — image tags, artifacts, env vars, deployments, other workflows. A fix that turns CI green but breaks a downstream concern is a worse failure than the original, because it's silent.
4. **Prefer filing the bug upstream.** Scaffold-generated files have a template (in `project-manager` or a platform-owned repo). Fixing the template benefits every future scaffold; fixing only the local copy hides the bug. Apply a narrow local workaround only when urgent, and label it as a workaround referencing the upstream issue.

### Worked example: GHCR push fails on PR events

Observed failure in CI:
```
ERROR: unauthorized: unauthenticated: User cannot be authenticated with the token provided.
at: pushing ghcr.io/<org>/<project>:pr-<N>-<SHA>
```

A diff-level / pattern-match reading of the error leads to this **wrong fix**:
```diff
-          push: true
+          push: ${{ github.event_name != 'pull_request' }}
```

CI goes green — the push is skipped on PR events, no auth error. But the full workflow shows:

```yaml
- name: Extract metadata
  uses: docker/metadata-action@v5
  with:
    tags: |
      type=ref,event=pr,prefix=pr-,suffix=-${{ github.event.pull_request.head.sha }}
```

The metadata step explicitly emits `pr-<N>-<SHA>` tags for PR events. Why? Because the platform's `preview-environments` ApplicationSet consumes those tags to spin up per-PR preview deployments. Gating `push` on non-PR means the preview Application has nothing to pull — no preview environment, no pre-merge validation. The symptom is hidden; the feature is broken silently.

The **right fix** reads the whole workflow first and preserves the feature:

```diff
 - name: Log in to GHCR
-  if: github.event_name != 'pull_request'
   uses: docker/login-action@v3
```

The push on PR events is intended; the login conditional is the bug. Ungating the login lets the push succeed.

And since this file was scaffold-generated (from `project-manager/templates/web-app/repo/.github/workflows/ci.yaml.hbs`), the upstream bug gets filed too — every future project inherits the fix, not just this one.

## Step 7: Review, then merge

Merge only if CI is green. A review at the final head comes first; GitHub's verdict gates the merge, and the merge skill checks it.

**1. Review after the final push.** Run the review as in `/alfred-agent:review-panel` and post it at the head with `alfred-review post` (review-panel, Step 4, "Posting the review"). The review is posted with the `review` identity through `gh-as review`, which does not change the active role. The `no review token` rule of review-panel applies: on exit 4, `alfred-review check` decides whether the flow continues (`not-required`) or stops (ask the hub).

**2. Fix rounds.** The loop is review, fix, review again. After a REQUEST_CHANGES, the builder commits the fix and the lead pushes it with the lead role (each fix push is a new head, and the old approval or request is stale):

**If multi-role devbox:**
```bash
switch-role lead
git -C <path> push
```

**If single-role devbox:**
```bash
git -C <path> push
```

Review the new head and post again. The new APPROVE supersedes the old CHANGES_REQUESTED of the same login.

**3. Merge through the merge skill.** Never merge with a direct command; `/alfred-agent:merge` checks CI, GitHub's review verdict and the label gate, and merges pinned to the reviewed head.

**If multi-role devbox** (the lead role merges):
```bash
switch-role lead
```
then run `/alfred-agent:merge {PR}`.

**If single-role devbox:** run `/alfred-agent:merge {PR}` with the current token.

If CI is red, go back to Step 6.5. **Never merge on red CI** — no exceptions, regardless of urgency, diff size, or how confident you are the failure is unrelated. If the merge skill reports exit 10 or 11 from `alfred-review check`, follow its message (review required or changes requested); do not look for another way to merge.

Then clean up:

**If multi-role devbox:**
```bash
switch-role build
git worktree remove <path>
git checkout main && git pull
git branch -d feature/issue-{N}-{short-description}
```

**If single-role devbox:**
```bash
git worktree remove <path>
git checkout main && git pull
git branch -d feature/issue-{N}-{short-description}
```

## PRs already in flight

There is no bulk migration. A PR opened before this rule is handled here, before it merges. `alfred-review check` names which of the two cases applies.

**The PR author is the review identity** (the PR was opened with the `build` role). GitHub forbids self-approval, so it can never be approved. Close it and recreate it with the lead role from the same branch. The empty commit gives a new head with the lead as last pusher (pushing the same SHA would change nothing). Multi-role devbox, lead role throughout:

```bash
switch-role lead
gh pr close {old} --comment "Recreated as lead-authored PR"
git fetch origin
git worktree add <path> {branch}   # skip when the branch already has a worktree
git -C <path> pull
git -C <path> commit --allow-empty -m "<CODE>-<n>: lead re-push for review"
git -C <path> push
gh pr create --title "{same title}" --body "{same body}

Replaces #{old}."
gh pr comment {old} --body "Recreated as #{new}"
```

**Only the last push was made by `build`.** The PR keeps its author. The lead role adds the empty commit and pushes; the review then runs on the new head:

```bash
switch-role lead
git fetch origin
git worktree add <path> {branch}   # skip when the branch already has a worktree
git -C <path> pull
git -C <path> commit --allow-empty -m "<CODE>-<n>: lead re-push for review"
git -C <path> push
```

## Rules

- **Every feature needs tests.** No exceptions. If you can't figure out how to test it, ask.
- **Tests run before PR.** Don't create a PR with failing tests.
- **Build must pass.** `npm run build` clean before PR.
- **One issue per PR.** Keep changes focused and reviewable.
- **The lead role pushes, creates the PR and merges; the review identity reviews (multi-role devboxes only).** Workers may commit with any author, but every push uses the lead role, because the reviewer must differ from the PR's author and from its last pusher. In single-role devboxes, use the same token throughout — this rule does not apply.
- **Token expired?** In multi-role devboxes, run `switch-role build` (or `lead`) to refresh. Try this first when git auth fails. In single-role devboxes, re-authenticate via the platform's normal token refresh path.
- **CI status is queried, never inferred.** ALWAYS run `gh pr checks {PR}` before claiming a PR is merge-ready. NEVER reason from diff size, change complexity, or author intuition to CI outcome.
- **Red CI blocks merge-ready.** FAILURE / CANCELLED / TIMED_OUT on any required check means the PR is NOT ready to merge — regardless of merge-conflict status or diff size. Either fix the root cause or escalate.
- **If an API seems unavailable, verify by calling it.** NEVER claim "not visible in this context" without trying the call first.
- **Read the full file before patching scaffold-generated or platform-owned files.** State a one-sentence theory of the file's intent. If you can't state it confidently, escalate rather than guess.
- **Scaffold-template bugs belong upstream.** Fixing only the local copy of a scaffold-generated file hides the bug from every future project. Prefer filing the upstream template bug + narrow local workaround over silent local patching.
- **Test image-affecting changes locally before pushing.** When a change affects container/image runtime behaviour (Dockerfile, entrypoint, init container, deployment manifest, scaffold-rendered templates that land in a pod), reproduce the change in a real environment *before* the commit. Options in order of preference: (a) `docker run` the image with the modified script bind-mounted, (b) execute the script directly in a shell with the right env vars and mounts, (c) `kubectl apply` a one-off pod manifest with the change inline. The full CI → image build → Image Updater → ArgoCD sync cycle takes ~10 minutes per iteration. A single local repro catches the same class of bugs without that latency. If you have already pushed a fix and the new pod fails, re-run locally before pushing the second attempt — do not iterate through CI more than once on the same fix.
- **Sweep after fixing.** When a commit fixes a bug or pattern, grep for analogous uses in scope and fix siblings before pushing — one correction is incomplete until siblings are fixed (Doctrine 05).
- **Diagnostic cleanup contract.** State created during debugging (K8s resources, scaffolded repos, /tmp artifacts) must have its teardown declared in the same sequence — not deferred to a later pass (Doctrine 09).
