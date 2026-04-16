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

### Step 4: Next Steps Summary

Ensure memory has a clear "pick up here" for the next session:
- What was completed this session
- What to work on next
- Any open decisions or blockers
- Reference the relevant memory file (e.g., `memory/project_next_steps_april.md`)

**Every open action must be a GitHub Issue.** Before landing, verify that all next steps, pending tasks, and follow-ups have a corresponding GitHub Issue with a priority label. If an action only exists in memory or conversation but not as an issue, create it now. The next session should be able to start by looking at the issue list — not by reading memory files to discover untracked work.

### Step 5: Confirm to User

Report:
- Retro completed (summary of learnings captured)
- All changes committed and pushed
- Next session starting point

## Output Format

```
## Landing Complete — {date}

### Retro
[summary from /retro — corrections, discoveries, updates applied]

### Git Status
- alfred-platform: clean, pushed (commit: {sha})
- gitops changes: [list any API-pushed changes]

### Next Session
- Pick up: [topic]
- Open decisions: [list]

Ready for context clear.
```
