---
name: develop
description: >
  Feature development workflow: pick up an issue, write code with tests, create PR, merge.
  Use when the user says "work on issue #X", "implement this", "pick up the next issue",
  "start developing", or when you need to make code changes that should go through a PR.
  This is the standard development procedure for all code changes in devbox environments.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Agent
---

# Feature Development

Standard workflow for implementing features in a devbox. Every code change follows this flow.

## Step 1: Pick up the issue

- Read the issue: `gh issue view {N}`
- Understand acceptance criteria before writing any code
- If acceptance criteria are unclear, ask the user (or message the platform agent)

## Step 2: Create a branch

```bash
switch-role build
git checkout main && git pull
git checkout -b feature/issue-{N}-{short-description}
```

Always branch from up-to-date main. Use `feature/` prefix for new work, `fix/` for bug fixes.

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

```bash
git push -u origin feature/issue-{N}-{short-description}
gh pr create --title "{short title}" --body "Closes #{N}

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

If CI is green, proceed to Step 7. If any check reports FAILURE / CANCELLED / TIMED_OUT, see Step 6.5.

## Step 6.5: When CI fails

**Red CI blocks merge-ready, no exceptions.** A PR with a failing check is not merge-ready regardless of merge-conflict status, diff size, or how unrelated the failure "seems." A mergeable-per-git PR with red CI is still not mergeable.

Your options when CI is red:

1. **Investigate and fix the root cause.** `gh run view {run-id} --log-failed` shows the actual failure — read it fully before deciding what to change.
2. **Escalate to the user** with the failure output and a description of what you've tried, if you cannot confidently identify the fix.

Never merge on red CI. Never declare the PR ready to merge while CI is red.

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

## Step 7: Merge

Switch to the lead role and merge only if CI is green:

```bash
switch-role lead
gh pr merge --squash
```

If CI is red, go back to Step 6.5. **Never merge on red CI** — no exceptions, regardless of urgency, diff size, or how confident you are the failure is unrelated.

Then clean up:
```bash
switch-role build
git checkout main && git pull
git branch -d feature/issue-{N}-{short-description}
```

## Rules

- **Every feature needs tests.** No exceptions. If you can't figure out how to test it, ask.
- **Tests run before PR.** Don't create a PR with failing tests.
- **Build must pass.** `npm run build` clean before PR.
- **One issue per PR.** Keep changes focused and reviewable.
- **Build role creates, lead role merges.** Never merge with the same role that created the PR.
- **Token expired?** Run `switch-role build` (or `lead`) to refresh. Try this first when git auth fails.
- **CI status is queried, never inferred.** ALWAYS run `gh pr checks {PR}` before claiming a PR is merge-ready. NEVER reason from diff size, change complexity, or author intuition to CI outcome.
- **Red CI blocks merge-ready.** FAILURE / CANCELLED / TIMED_OUT on any required check means the PR is NOT ready to merge — regardless of merge-conflict status or diff size. Either fix the root cause or escalate.
- **If an API seems unavailable, verify by calling it.** NEVER claim "not visible in this context" without trying the call first.
- **Read the full file before patching scaffold-generated or platform-owned files.** State a one-sentence theory of the file's intent. If you can't state it confidently, escalate rather than guess.
- **Scaffold-template bugs belong upstream.** Fixing only the local copy of a scaffold-generated file hides the bug from every future project. Prefer filing the upstream template bug + narrow local workaround over silent local patching.
- **Test image-affecting changes locally before pushing.** When a change affects container/image runtime behaviour (Dockerfile, entrypoint, init container, deployment manifest, scaffold-rendered templates that land in a pod), reproduce the change in a real environment *before* the commit. Options in order of preference: (a) `docker run` the image with the modified script bind-mounted, (b) execute the script directly in a shell with the right env vars and mounts, (c) `kubectl apply` a one-off pod manifest with the change inline. The full CI → image build → Image Updater → ArgoCD sync cycle takes ~10 minutes per iteration. A single local repro catches the same class of bugs without that latency. If you have already pushed a fix and the new pod fails, re-run locally before pushing the second attempt — do not iterate through CI more than once on the same fix.
