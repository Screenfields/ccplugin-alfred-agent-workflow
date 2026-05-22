---
name: land
description: >
  Land the plane — complete session close-out. Runs /retro for learnings capture,
  ensures all work is committed and pushed, and reconciles open work to GitHub
  Issues (file new ones; close ones whose work has shipped). Use when the user
  says "land", "land the plane", "wrap up", "close out", or before clearing
  context.
allowed-tools: Read, Edit, Write, Glob, Grep, Bash, Agent, AskUserQuestion, Skill
---

# Land the Plane

Full session close-out: capture learnings, commit everything, prepare for next session.

## When to Use

- User says "land", "land the plane", "wrap up", "close out"
- Before clearing context
- End of a work session

## Process

### Step 1: Run Retrospective

Execute `/retro` first — capture corrections, discoveries, and apply updates.

### Step 2: Git Housekeeping

After the retro, ensure ALL changes are committed and pushed:

```bash
git status                    # Check for uncommitted changes
git add . && git commit -m "..." # Commit any remaining changes
git push                      # MUST succeed — verify remote is up to date
```

If there are changes across multiple repos (e.g., gitops repos updated via API), verify those are also pushed:
- Check alfred-platform-gitops for pending changes
- Check alfred-projects-gitops for pending changes
- Check any project repos that were modified

### Step 3: Verify Clean State

```bash
git status                    # Must show "nothing to commit, working tree clean"
git log --oneline -3          # Show recent commits for confirmation
```

### Step 4: Reconcile work to GitHub Issues — the only forward-looking source of truth

**GitHub Issues is the authoritative work list.** Memory files capture historical/learning content; they do NOT track forward-looking work. Earlier patterns wrote next-steps to memory files (`project_next_steps*.md` and similar) — that pattern is retired. It caused stale-file bugs (hooks reading old snapshots, untracked work piling up in memory while issues drifted Open after their PRs shipped). Don't reintroduce it.

#### Step 4a — Every open action must be a GitHub Issue

Verify that all next steps, pending tasks, follow-ups, deferred sub-scopes, structural debt items, doctrine adoption tasks, and external dependencies have a corresponding GitHub Issue with a priority label (P1–P4).

If an action only exists in conversation, in your task list, in a PR comment, in a memory file, or in your head — and not as an issue — **create the issue now**. Use a clear title, body with context + acceptance criteria, and link any related work via cross-refs.

#### Step 4b — Every open issue must actually still be open

Issues silently staying open after their work has shipped is a recurring failure mode. It inflates the queue, hides what's actually pending, and confuses future sessions about scope.

For every issue this session's work touched (any issue referenced in commits, PRs, comments, or conversation), run `gh issue view N` and ask:

- Is it still open?
- If yes, was the work that resolves it already done this session?
- If yes, close it with a multi-line comment containing PR refs + acceptance-criteria checkmarks + any deferred sub-scopes (which become their own issues per Step 4a).

Do NOT rely on `Closes #N` keywords in commit messages alone — those silently fail when PRs squash-merge differently than expected, when work spans multiple PRs, or when commit messages get edited. The close-with-evidence-comment is the durable artifact that proves to a future reader why the issue closed.

Before marking any issue closed, re-verify the actual merge state via `gh pr view {N}` — do not rely on memory or "Closes #N" keywords alone; squash merges may not trigger keyword closes (Doctrine 01 + 07).

#### Why no memory file write step

Future sessions read GitHub Issues to know what's next. They don't read memory files for forward-looking content. Memory files in this project's `memory/` directory are for: doctrine context, identity history, retrospective learnings, gotcha references, and other persistent knowledge that doesn't fit the issue-tracker model. If you find yourself wanting to write a "next steps" memory file, that's a signal to file issues instead.

### Step 5: Confirm to User

Report:
- Retro completed (summary of learnings captured)
- All changes committed and pushed
- Issues filed this session (count + numbers)
- Issues closed this session with evidence comments (count + numbers)
- Top of the open-issue queue at session close (P1/P2 by number + title)

## Output Format

```
## Landing Complete — {date}

### Retro
[summary from /retro — corrections, discoveries, updates applied]

### Git Status
- alfred-platform: clean, pushed (commit: {sha})
- gitops changes: [list any API-pushed changes]

### Issues
- Filed this session: #N1, #N2, … ({count} total)
- Closed with evidence: #M1, #M2, … ({count} total)
- Top of queue at session close: #X1 [P1/P2] (one-line summary), #X2 [P1/P2] …

Ready for context clear.
```
