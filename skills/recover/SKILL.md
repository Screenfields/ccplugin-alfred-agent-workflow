---
name: recover
description: >
  The single entry point after any session start — run it first, always. Reads the
  SessionStart classification (graceful / unplanned / fresh) already injected into
  context and either does a short confirm-and-continue (graceful), runs the full
  unplanned-restart recovery checklist and reports findings to the owner (unplanned),
  or does nothing (fresh). Use when the user says "recover", when a CONTEXT BUDGET
  line classifies this start as graceful or unplanned, or whenever a session opens
  after a restart and the classification has not been handled yet.
allowed-tools: Read, Bash, Monitor, Agent
---

# Recover

The land skill's counterpart. Landing makes a session's end safe; recover makes the
next session's start safe — whichever way it started. It reads the classification
`hooks/context-budget.sh session-start` already injected into this session's context
(see `skills/land/SKILL.md`'s top rule) and branches on it. It never re-derives the
classification itself — that is the hook's job, already done before this skill runs.

## The three classes

| Class | What the injected line looks like | What this skill does |
|---|---|---|
| **graceful** | `CONTEXT BUDGET: graceful <clear\|compact\|restart> after landing — previous session <id> …` | Short confirm-and-continue |
| **unplanned** | `CONTEXT BUDGET: unplanned restart detected — recovery required.` + a `RECOVERY:` line | Full checklist, report to owner |
| **fresh** | No `CONTEXT BUDGET` line at all | Nothing — proceed normally |

A `HANDOVER (written …, consumed now):` block may follow either of the first two (or
appear with neither, after `--no-clear`) — it is independent of the classification.

## Graceful — short path

1. **Re-arm the wake bridge.** Prefer the host bridge if this host has one:
   `command -v hub-wake-bridge` — if found, arm it exactly as the platform docs
   specify: `Monitor(command: "~/.local/bin/hub-wake-bridge run", persistent: true, description: "hub inbox wake: agent-messaging + Buzz")`. If `hub-wake-bridge` is not
   on `PATH`, fall back to this plugin's own bridge, the same way `alfred-wake` is
   armed at any session start (README § "Arming it"):
   ```
   command -v alfred-wake >/dev/null 2>&1 || "${CLAUDE_PLUGIN_ROOT}/bin/alfred-wake" install
   Monitor(command: "alfred-wake run", persistent: true, description: "inbox wake: agent-messaging + Buzz")
   ```
   If neither exists, say so — a silent skip is indistinguishable from a working bridge.
2. **Confirm the handover was consumed.** `test -f "${ALFRED_STATE_DIR:-$HOME/.cache/alfred}/context/handover.md"` should now be false — `session-start` deletes it the moment it injects it. If it is still there, something read the classification without going through the hook (rare); say so and read it directly instead of guessing.
3. **Continue from the handover's "first thing" item** — already in context from the injected `HANDOVER` block. No further investigation needed; the previous session already did the Drain + completeness gate before landing.

Keep this path short. It exists so a routine restart (a plugin upgrade, a planned
compact) costs one confirm, not a checklist.

## Unplanned — full recovery checklist

Everything in this section is **read-only except step 6 (the wake-bridge Monitor)
and step 7 (the Metis note)**. Never delete a worktree with uncommitted changes —
report it, do not clean it up.

1. **What was lost.** From the RECOVERY line's `last activity` / `last landing`
   times: name what a session that ended between those two timestamps could have
   had in flight — background agents, armed Monitors, an in-progress tool call. This
   session has no way to see the previous session's actual task list (it is a
   different process), so state this as "likely in flight, unconfirmed" rather than
   as fact.
2. **Git state.** Run `git status --porcelain` and `git worktree list --porcelain` in
   the project directory, and in every worktree it lists (and, if reachable, every
   worktree still present under the session's scratchpad dir). Report: uncommitted
   changes, unpushed commits (a worktree with no upstream counts as unpushed), and
   any stale worker worktree still registered. This mirrors `landed`'s own
   completeness-gate checks (Change 5a #2) — the previous session evidently never got
   past them.
3. **Open PRs.** `platform-gh pr list --author @me` (or the identity's own app — see
   this plugin's `platform-gh`/`gh` conventions) filtered to this project; report
   anything still open with its review/CI state.
4. **Inbox.** Check for unread agent-messaging threads (`/alfred-agent:check-messages`
   or the underlying MCP tools) — a peer may be waiting on a reply the previous
   session never sent.
5. **Last known state.** Read the previous session's `.budget` and `.json` state
   files under `${ALFRED_STATE_DIR:-$HOME/.cache/alfred}/context/` (the session id is
   in the RECOVERY line): tokens used, last activity time, whether it had already
   crossed the hard threshold. This is forensic context, not something to act on.
6. **Re-arm the wake bridge** — same as the graceful path's step 1.
7. **Capture a recovery note in Metis** via `capture_note`: "recovered from unplanned
   restart at `<time>`: found `<summary of 1-5>`, lost `<summary of what could not be
   confirmed>`." This is the durable record that an unplanned restart happened and
   what recovery found — useful even if the owner's next instruction makes most of it
   moot.
8. **Ask the owner where to continue.** Do not guess or resume speculatively — present
   findings 1-5 concisely and let the owner decide (continue the apparent prior work,
   start fresh, or something else). If a `HANDOVER` block was also injected (a stale
   one from before the crash, per Change 4a — "still better than none"), treat it as
   a *hint* about prior intent, not a confirmed state, and say so explicitly.

## Fresh — no action

Nothing to do. Proceed with the session normally; there is no classification to act on.

## Notes

- This skill answers "is the last start OK" before anything else happens in a new
  session — invoke it before picking up any other work, the same way `land`'s
  Drain step runs before anything else at the end.
- It never writes to git, never force-pushes, never deletes a worktree, and never
  removes another session's state files. Its only writes are the wake-bridge Monitor
  and the Metis capture — everything else is investigation and a report.
- If the classification line is not present at all (a `fresh` start, or a build of
  the plugin from before Change 4a), say so briefly and proceed — there is nothing to
  recover.
