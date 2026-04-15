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

Ensure CI passes before proceeding.

## Step 7: Merge

Switch to the lead role (different GitHub App = different user):
```bash
switch-role lead
gh pr merge --squash
```

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
