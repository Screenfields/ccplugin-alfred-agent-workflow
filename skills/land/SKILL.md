---
name: land
description: >
  Land the plane — complete session close-out. Runs /retro for learnings capture,
  then ensures all work is committed, pushed, and next steps documented.
  Use when the user says "land", "land the plane", "wrap up", "close out",
  or before clearing context.
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

### Step 4: Update next-steps memory (canonical file)

Write the full end-of-session next-steps memory to the **canonical** filename:

```
~/.claude/projects/<project-slug>/memory/project_next_steps.md
```

Do NOT use a dated suffix (`project_next_steps_april.md`, etc.). Dated snapshots cause stale-file bugs in SessionStart hooks that hardcode older filenames — a real failure mode that has bitten previous sessions. The hook should be reading the rolling canonical file; this skill's responsibility is to keep that file fresh.

The file MUST include, at minimum:

- **A session-boundary continuity banner at the top** instructing future-you to verify the source path + mtime printed by the SessionStart hook against the current canonical filename. If the hook surfaces a non-canonical or stale-mtime file, STOP and reconcile against the GitHub Issues queue + recent git log before treating any item as current.
- A clear "what landed this session" summary (PRs merged by repo, issues changed state)
- A clear "what's next" pick-up list, ranked by priority and ownership (yours, user's, other agents')
- Pending external/user actions explicitly called out (e.g., dashboard edits, manual approvals)
- Cross-references to baseline docs and key 1Password secrets touched

The frontmatter `name` and `description` should reflect the current session's outcome. Re-running `/land` should produce a fresh `mtime` on this file every time — that mtime is the SessionStart hook's primary freshness signal.

**Every open action must be a GitHub Issue.** Before landing, verify that all next steps, pending tasks, and follow-ups have a corresponding GitHub Issue with a priority label. If an action only exists in memory or conversation but not as an issue, create it now. The memory file is for handoff context (what landed, what's next at a glance, what's the operational state); the GitHub Issues queue is the authoritative work list.

**Also verify that all open issues in GitHub are actually open and not already done.** Issues silently staying open after their work has shipped is a recurring failure mode — it inflates the queue, hides what's actually pending, and confuses future sessions. For every issue this session's work landed against (PR merged, decision made, scope clarified), explicitly close the issue with an evidence comment linking to the PR(s) and any baseline doc updates. Do NOT rely on `Closes #N` in commit messages alone — the close-with-evidence-comment is the durable artifact that proves to a future reader why the issue closed.

Concretely, for each issue mentioned in this session's work or this session's PR descriptions, run `gh issue view N` and ask: is this still open? If yes, was the work that resolves it already done this session? If yes, close it with a multi-line comment containing PR refs + acceptance-criteria checkmarks + any deferred sub-scopes (which become their own issues per the rule above).

### Step 4a: Verify SessionStart hook will surface the right file

Before declaring the landing complete, confirm the chain that future-you will see on `/clear`:

1. Read the SessionStart hook script (`.claude/hooks/session-start-status.sh` or equivalent) and confirm it points at the **canonical** `project_next_steps.md`, not a dated snapshot.
2. Check the file's mtime is from this session (`stat -c '%y' <path>`).
3. If either check fails, fix the hook OR rewrite the file before clearing — otherwise the next session will resume from stale context.

This step is the durable defense against the cross-session-state-loss failure mode (alfred-platform#275 originating incident).

### Step 5: Confirm to User

Report:
- Retro completed (summary of learnings captured)
- All changes committed and pushed
- Next-steps memory file path + mtime (proves the file is fresh)
- SessionStart hook verification result (will surface the canonical file)
- Next session starting point

## Output Format

```
## Landing Complete — {date}

### Retro
[summary from /retro — corrections, discoveries, updates applied]

### Git Status
- alfred-platform: clean, pushed (commit: {sha})
- gitops changes: [list any API-pushed changes]

### Next-steps memory
- File: memory/project_next_steps.md
- Mtime: {timestamp from this session}
- SessionStart hook verified: [✓ canonical file / ✗ needs fix]

### Next Session
- Pick up: [topic]
- Open decisions: [list]
- Pending external actions (user-side): [list]

Ready for context clear.
```
