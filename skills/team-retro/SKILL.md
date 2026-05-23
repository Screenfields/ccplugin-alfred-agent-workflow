---
name: team-retro
description: >
  Orchestrate a trilateral+ retrospective across three or more platform agents.
  Use when the session involves cross-project scope, shared infrastructure decisions,
  or a shared infrastructure incident post-mortem. NOT for single-agent session retros
  (use alfred-agent:retro for those).
allowed-tools: Read, Edit, Write, Glob, Grep, Bash, Agent, AskUserQuestion, Skill
---

# Team Retrospective

Structured trilateral+ retrospective for cross-project sessions. Three rounds: parallel honest
reflections, hub synthesis, and convergence. Hub agent (the agent running this skill) is the
arbiter for unresolved disagreements.

## When to Use

Use this skill when **any one** of the following holds:

1. **Three or more agents were involved** in the session or sprint being reviewed
2. **Cross-project scope** — the work affected shared infrastructure, platform-wide decisions,
   or capabilities that multiple projects depend on
3. **Shared infrastructure incident** — a post-mortem for an outage, regression, or security
   event that crossed project boundaries

Do NOT use for single-agent session retros — use `alfred-agent:retro` for those.

**`alfred-agent:land --mode=team` pairing:** Spokes participating in a team retro MUST run
`/alfred-agent:land --mode=team` (not plain `/land`) during and after the team retro. The
`--mode=team` flag skips the inline `/retro` step, preventing a duplicate solo retro from
running alongside the team retro. Hub coordinates; spokes `--mode=team` land.

## Roles

| Role | Who | Responsibilities |
|------|-----|-----------------|
| **Hub** | The agent running `alfred-agent:team-retro` | Sends kickoff, receives R1 outputs, produces synthesis table, drives convergence, arbitrates tie-breaks, confirms issue filing |
| **Spoke** | Each participating agent (≥2) | Responds to R1 prompt, critiques synthesis table, files GitHub Issues from agreed actions, runs `/alfred-agent:land --mode=team` |

## Three-Round Process

---

### Round 1 (R1) — Parallel Honest Reflections

**Hub action:** Send the following prompt to every spoke simultaneously via `alfred-agent:messaging`.
Each spoke receives the **same** prompt.

#### R1 Kickoff Prompt Template

```
Subject: Team Retro — R1 Kickoff ({scope label})

We are running a team retrospective covering {scope: session / sprint / incident}.

Please reply with your R1 reflection. Format: bullet points only — honest reflection,
NOT polished prose. One response only (not a thread).

Prompts:
- What worked well in this session/sprint? (What should we reinforce?)
- What didn't work? (What caused friction, delay, or errors?)
- What surprised you? (Things not in the docs, unexpected blockers, hidden dependencies)

Scope constraint: this {session / sprint} only. Do not surface older issues.

Reply to this thread with your R1. Then run `/alfred-agent:land --mode=team`.
```

**Spoke constraint:** R1 is a single response per spoke. Not a thread. Bullet points only.

**Hub waits:** Collect all R1 responses before proceeding to R2. Do not synthesize partial inputs.

---

### Round 2 (R2) — Hub Synthesis

Hub receives all R1 outputs and produces a **per-topic action table**.

#### Synthesis Table Schema

| Topic | Framing | Proposed action | Owning project | Priority |
|-------|---------|-----------------|----------------|----------|
| (e.g., "Token auth silent failure") | (e.g., "Embedded-token clones read fine but push silently fails") | (e.g., "Add auth-verify step to develop skill after clone") | `ccplugin-alfred-agent-workflow` | P2 |

**Schema field definitions:**

- **Topic** — short label for the failure mode, surprise, or improvement area
- **Framing** — one-sentence description of the root cause or pattern (not a complaint — a generalizable diagnosis)
- **Proposed action** — concrete change: a SKILL.md edit, a CLAUDE.md rule, a GitHub Issue, a doc update. Must name the artifact to change.
- **Owning project** — the repo or project responsible for executing the action
- **Priority** — P1 (urgent, blocks work) / P2 (important, next sprint) / P3 (nice to have) / P4 (backlog)

#### R2 Spoke Critique Prompt Template

```
Subject: Team Retro — R2 Synthesis for Critique ({scope label})

Hub synthesis table below. Please critique each row:
- Agree: "Row N: agree"
- Disagree: "Row N: disagree — [your framing / alternative action]"
- Amend: "Row N: amend — [specific change to Proposed action or Priority]"

If you have rows to add (items in your R1 not captured), list them at the end.

{synthesis table here}

Reply once. Hub will iterate if needed, or invoke arbiter rule if disagreement persists.
```

---

### Round 3 (R3) — Convergence

**Convergence definition:** All spokes have explicitly acknowledged the final table (each spoke
replies with "Agree" or "Accepted" to the final version). Silence is NOT convergence.

**Iteration:** Hub incorporates spoke critiques and re-sends the updated table if substantive
changes are made. Repeat until all spokes acknowledge.

**Arbiter model:** The hub agent is the arbiter. If a spoke and hub disagree after **2 full
rounds** of critique:

1. Hub decides and documents the reason in a "Arbiter Decision" note appended to the row
2. Hub notifies the spoke of the decision and the documented reason
3. Spoke acknowledges receipt (disagreement on record; convergence proceeds)

Arbiter decisions are part of the permanent retro record. Document them explicitly — do not
silently override.

#### Convergence Confirmation Prompt Template

```
Subject: Team Retro — Final Table + Convergence Confirmation ({scope label})

Final action table after incorporating all feedback:

{final synthesis table}

{If any arbiter decisions: "Arbiter decisions: [Row N] — Hub decided: [reason]"}

Please confirm convergence by replying: "Convergence confirmed — {your project name}"

Once all spokes confirm, each spoke should file GitHub Issues from the rows it owns,
then confirm filing to hub.
```

---

### Filing Phase — GitHub Issues

After convergence:

1. **Each spoke** files GitHub Issues on its own project backlog for every row where it is the
   Owning project. Use priority label (P1–P4), include the Topic and Framing from the table as
   context, and cross-reference the team retro thread ID in the issue body.

2. **Hub** files Issues for rows it owns.

3. **Hub** sends a final confirmation message to each spoke:

```
Subject: Team Retro — Issue Filing Confirmation ({scope label})

Please confirm all issues are filed for your rows.

Hub rows filed: {list of issues with numbers}

Awaiting confirmation from: {spoke names}
```

4. Hub waits for each spoke to confirm issue filing before closing the retro.

5. Once all spokes confirm, hub posts a retro-close summary to the thread.

---

## Output Format

At retro close, hub produces:

```
## Team Retro Close — {scope label} — {date}

### Participants
- Hub: {hub project}
- Spokes: {spoke project 1}, {spoke project 2}, ...

### Rounds completed
- R1: {date/time} — {N} spokes responded
- R2: {date/time} — {N} synthesis iterations
- R3: {date/time} — convergence confirmed by all spokes

### Final Action Table
{final synthesis table}

### Arbiter Decisions
{list, or "None"}

### Issues Filed
{per project: issue number + title}

### Retro closed.
```

## Anti-Patterns

- **Do not synthesize partial R1 inputs.** Wait for all spokes before producing R2.
- **Silence is not convergence.** Explicitly collect acknowledgment from every spoke.
- **Do not use plain `/land` during a team retro.** Spokes must use `/alfred-agent:land --mode=team`.
- **Do not drop arbiter decisions.** Document them even when they feel minor.
- **Do not file issues for rows that belong to another project's backlog.** Each spoke owns its own issue filing.
- **Do not close the retro before confirming all issues are filed.** The retro is not done until the action table is fully in the issue tracker.

## Worked Example — Team Retro #2 (2026-05-23)

**Participants:** hub = `alfred-cc-tools`, spokes = `alfred-platform`, `project-manager`

**Scope:** 2026-05-22 cross-project sprint — platform doctrines sweep, messaging reliability, plugin constellation standup.

**R1 kickoff:** Hub sent identical R1 prompt to `alfred-platform` and `project-manager` via agent-messaging. Both replied within the session with bullet-point reflections. Key items surfaced:

- `alfred-platform`: "Token auth silent failure on embedded-token clones was not documented; took 2 sessions to diagnose"
- `alfred-platform`: "Doctrine 01 (verify claims about state) was violated repeatedly by all agents — need enforcement point in develop skill"
- `project-manager`: "PR squash-merge silently bypasses `Closes #N` keywords — issues stayed open after work shipped"
- `alfred-cc-tools`: "Self-bootstrap rhythm (author → release-bump → restart → use) not captured; caused session confusion about skill availability"

**R2 synthesis:** Hub produced a 5-row table. Notable rows:

| Topic | Framing | Proposed action | Owning project | Priority |
|-------|---------|-----------------|----------------|----------|
| Token auth silent failure | Embedded-token clones read fine but `git push` fails silently — no error surfaced until PR time | Add auth-verify step to `alfred-agent:develop` post-clone; document in all CLAUDE.mds | `ccplugin-alfred-agent-workflow` | P1 |
| Doctrine 01 enforcement | All agents violated verify-before-act in the same sprint; existing CLAUDE.md rule not triggering | Add explicit verify gate to `alfred-agent:develop` Step 2 with Doctrine 01 callout | `ccplugin-alfred-agent-workflow` | P1 |
| Squash-merge issue close | `Closes #N` keywords silently fail on squash merges; issues stay open | Add close-with-evidence-comment step to `alfred-agent:land` Step 4b | `ccplugin-alfred-agent-workflow` | P2 |
| Self-bootstrap rhythm | New skills not immediately available post-author; agent confused why skill wasn't loaded | Document rhythm in CLAUDE.md with latency callout | `alfred-cc-tools` | P3 |
| Session startup reliability | Explicit inbox check needed at session start; Monitor is best-effort only | Add explicit check-messages step to all project CLAUDE.md session startup checklists | all spokes | P2 |

**R3 convergence:** `alfred-platform` amended Row 5 priority from P2 to P1 (citing an incident where a missed message caused a wasted half-session). Hub accepted the amendment. `project-manager` agreed all rows. Convergence confirmed after 1 iteration — no arbiter decisions needed.

**Filing:** Each project filed Issues for its owned rows. Hub confirmed receipt of all filing confirmations and posted retro-close summary.

**Outcome:** 5 issues filed across 3 repos; 2 SKILL.md updates landed in the same session (Rows 1–2 were P1).
