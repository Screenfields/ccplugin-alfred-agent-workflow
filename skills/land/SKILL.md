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

## Flags

| Flag | Effect |
|------|--------|
| *(none)* | Default mode — inline `/retro` runs as Step 1 |
| `--mode=team` | Skip inline `/retro`; note that team retro is in progress async; proceed directly to health-check then git housekeeping + issue reconciliation |

Flags compose: `--mode=team` and the health-check gate (Step 0) both apply simultaneously regardless of which mode is active.

## When to Use

- User says "land", "land the plane", "wrap up", "close out"
- Before clearing context
- End of a work session

## Process

### Step 0: Health-Check Gate (always runs, regardless of mode)

Before proceeding further, assert the following three conditions. If any assertion fails, **surface the specific failure and recovery steps immediately and do NOT continue with land**. Do not silently skip a failing assertion.

#### Assertion 1 — Armed Monitor tasks produced recent activity or have a documented quiet reason

For each Monitor task that was armed during this session:

1. Determine when the Monitor was last armed (check transcript / task list).
2. Check whether it produced ≥1 event in the last hour.
   - If yes: assertion passes for this task.
   - If no: a documented reason why the monitor is legitimately quiet (e.g., "no deployments were triggered", "inbox-watcher only fires on incoming messages — none expected") must be noted.
3. If a Monitor is silent with no documented reason, **fail this assertion**.

Failure diagnosis template:
```
HEALTH CHECK FAILURE — Monitor silent with no documented reason
  Monitor: <task description>
  Armed at: <time>
  Last event: <time or "none recorded">
Recovery: document why the monitor is legitimately quiet, or re-arm the monitor
  and confirm it fires on a known event, then re-run /land.
```

#### Assertion 2 — Inbox-watcher process alive and events.log recently modified

Run the following checks:

```bash
# Check that the watcher process is alive
pgrep -f "alfred-inbox-watcher" && echo "watcher: alive" || echo "watcher: DEAD"

# Check last modification time of events.log
stat /workspace/.alfred/events.log 2>/dev/null \
  && find /workspace/.alfred/events.log -mmin -10 -print \
  || echo "events.log: NOT FOUND or NOT MODIFIED in last 10 min"
```

Assertion passes if:
- The watcher process is alive, AND
- `/workspace/.alfred/events.log` exists and was modified within the last 10 minutes.

Failure diagnosis template:
```
HEALTH CHECK FAILURE — Watcher process or events.log stale
  Watcher alive: <yes/no>
  events.log last modified: <timestamp or "not found">
Recovery:
  - If watcher dead: restart with `alfred-inbox-watcher-hook.sh` or re-arm the
    SessionStart hook and reopen the session.
  - If events.log stale (>10 min): check whether any monitored process wrote
    events; if the project truly has no events, document that as the quiet reason
    and re-run /land.
```

#### Assertion 3 — No stale pendingOperation records

This assertion is **conditional on the project stack**. Apply it only if the project uses a system that tracks `pendingOperation` records (e.g., a task queue, job scheduler, or platform workflow engine with operation-state storage).

- If the project stack does not use such a system: mark this assertion as **N/A** and note "no pendingOperation system in this stack" in the health-check summary.
- If the project stack does use such a system: query the relevant store and confirm no records have been in a pending/in-progress state beyond the expected threshold (threshold is project-specific; use 30 minutes as a safe default if no project-specific value is defined).

Failure diagnosis template:
```
HEALTH CHECK FAILURE — Stale pendingOperation records found
  Records found: <count>
  Oldest record age: <duration>
  Threshold: <threshold>
Recovery: investigate why those operations are stuck, resolve or manually close
  them, then re-run /land.
```

#### Health-check summary

After evaluating all three assertions, output a compact summary before proceeding:

```
## Health-Check Gate
- Monitor activity: PASS | FAIL | (description)
- Watcher + events.log: PASS | FAIL | (description)
- Stale pendingOperations: PASS | FAIL | N/A | (description)
```

If all assertions pass (or are N/A), proceed to Step 1. If any assertion fails, stop here and surface recovery steps.

---

### Step 1: Run Retrospective (skipped in --mode=team)

**Default mode:** Execute `/retro` — capture corrections, discoveries, and apply updates.

**`--mode=team`:** Skip inline `/retro`. Output the following notice instead and proceed directly to Step 2:

```
NOTE: --mode=team active — team retro is in progress async. Retro step skipped.
When the team retro output is finalised, it may produce additional GitHub Issues;
those should be filed against this repo at that time.
```

### Step 2: Git Housekeeping

After the retro (or retro-skip notice), ensure ALL changes are committed and pushed:

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
- Health-check gate result (pass/fail per assertion)
- Retro completed (summary of learnings captured) — or retro-skip notice if `--mode=team`
- All changes committed and pushed
- Issues filed this session (count + numbers)
- Issues closed this session with evidence comments (count + numbers)
- Top of the open-issue queue at session close (P1/P2 by number + title)

## Output Format

```
## Landing Complete — {date}

### Health-Check Gate
- Monitor activity: PASS | (description)
- Watcher + events.log: PASS | (description)
- Stale pendingOperations: PASS | N/A | (description)

### Retro
[summary from /retro — corrections, discoveries, updates applied]
— OR —
[NOTE: --mode=team — team retro in progress async; retro step skipped]

### Git Status
- alfred-platform: clean, pushed (commit: {sha})
- gitops changes: [list any API-pushed changes]

### Issues
- Filed this session: #N1, #N2, … ({count} total)
- Closed with evidence: #M1, #M2, … ({count} total)
- Top of queue at session close: #X1 [P1/P2] (one-line summary), #X2 [P1/P2] …

Ready for context clear.
```
