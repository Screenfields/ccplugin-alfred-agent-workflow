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
| `--mode=light` | Between-boundaries landing driven by the context budget — offload, prune, push, mark landed. No retro, no health-check gate, no issue reconciliation sweep. See **Light Mode** below |
| `--no-clear` | Do not self-clear after the landing: the marker is written with `--no-clear`, the session stays as it is, and the owner decides when to clear. Composes with every mode |

Flags compose: `--mode=team` and the health-check gate (Step 0) both apply simultaneously regardless of which mode is active.
`--mode=light` is the exception — it is a different, shorter procedure and runs the Light Mode steps below instead of the full Process.

## When to Use

- User says "land", "land the plane", "wrap up", "close out"
- Before clearing context
- End of a work session

## Light Mode (`--mode=light`)

The landing you do **between** natural boundaries, when the context-budget hook says
you are at or above the soft threshold (default 80000 tokens) — a merged PR, a resolved
walkthrough item, a reviewed worker result. It is deliberately cheap: no retro, no
health-check gate, no full issue reconciliation. Those belong to a real session end
(default mode). The point of a light landing is to get *content* out of context and
leave *pointers* behind.

Run these five steps in order.

| Step | What |
|------|------|
| a | **Offload every decision and state item of this session.** Each one goes as a comment on its GitHub issue. Knowledge and background go to Metis via `capture_note`. Large verbatim payloads (transcripts, logs, dumps) go through `scripts/hub/metis_capture_file.py` — never retyped through the model, which truncates and fabricates |
| b | **Prune the handover memory to pointers only.** Every line whose content is now on an issue or in Metis is replaced by its issue URL or capture id. Keep `MEMORY.md` under its size limit — a light landing that grows memory has failed |
| c | **Push every tree.** All working trees committed and pushed; worker worktrees removed |
| d | **Mark the landing and arm the clear:** run `${CLAUDE_PLUGIN_ROOT}/hooks/context-budget.sh landed --clear --summary "<one line: what was landed and where the next session starts>" "$CLAUDE_CODE_SESSION_ID"`. Always pass the session id as that last argument — it is what the Bash tool exports, and it is the only fully unambiguous way to say which session is being landed. This clears the Stop block for the current crossing and records that the session should clear itself. The block reason printed by the hook names the absolute path — use that if you have it. Use `--no-clear` instead when the user asked for no clear |
| e | **End the turn with exactly one short line:** `landed at <used> tokens — clearing now`. Open no new work in the same turn. The Stop hook then types `/clear` into this pane as soon as the input box is idle; a prompt sent before that happens cancels the clear, because the context is no longer landed |

### Notes

- Step d is what stops the hook from blocking the turn again. Skipping it means the
  next Stop above the hard threshold blocks once more.
- The summary in step d is the whole handover the next session gets injected at
  `SessionStart`. Write it as one line that names what landed and which issue or
  memory pointer the next session opens first.
- The clear is best-effort and bounded: two attempts, 90 s each, and it never fires
  while the owner has text in the input box or while the session is mid-turn. If it
  cannot run at all (no tmux pane), the hook says so and asks the owner to clear.
- If `$CLAUDE_CODE_SESSION_ID` is not set and the hook has to guess the session from
  the newest state file, it refuses to arm the clear and says so on stderr — a guessed
  id could name another session, whose pane would then get the keystrokes. The landing
  itself is still recorded; pass the id explicitly and re-run to arm the clear.
- If step a finds nothing to offload, say so explicitly rather than skipping the step —
  "nothing to offload" is a claim about the session, and it is usually wrong.
- A light landing is not a session end — it is a context boundary. The work continues
  in the next session, which opens on the handover summary from step d, the handover
  memory and the issue queue.

## Process

### Step 0: Health-Check Gate (always runs, regardless of mode)

Before proceeding further, assert the following three conditions. If any assertion fails, **surface the specific failure and recovery steps immediately and do NOT continue with land**. Do not silently skip a failing assertion.

#### Assertion 1 — Armed Monitor tasks produced recent activity or have a documented quiet reason

For each Monitor task that was armed during this session:

1. Determine when the Monitor was last armed (check transcript / task list).
2. Check whether it produced ≥1 event in the last hour.
   - If yes: assertion passes for this task.
   - If no: a documented reason why the monitor is legitimately quiet (e.g., "no deployments were triggered, no events expected") must be noted.
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

#### Assertion 2 — REMOVED 2026-06-09

The inbox-watcher process this assertion checked was retired 2026-06-09.
There is no longer a long-lived `alfred-inbox-watch.py` process or a
periodically-updated `events.log` to validate. Real-time message delivery
is no longer a concern of `/land`.

If you care about pending inbound messages at land time, run
`/alfred-agent:check-messages` explicitly — that's the only delivery path
now.

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
- Watcher + events.log: N/A — retired 2026-06-09
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

Full mode also runs `${CLAUDE_PLUGIN_ROOT}/hooks/context-budget.sh landed --clear --summary "<one line: what was landed and where the next session starts>" "$CLAUDE_CODE_SESSION_ID"` here, after the report — same marker as light mode step d. If the user invoked `/alfred-agent:land --no-clear`, pass `--no-clear` instead of `--clear --summary …` and leave the clear to the owner.

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
- Watcher + events.log: N/A — retired 2026-06-09
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

Landed; clearing this session now.
```
