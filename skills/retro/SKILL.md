---
name: retro
description: >
  Session retrospective for recursive self-improvement (RSI). Run at the end of a session
  to capture learnings, update instructions, and prepare context for the next session.
  Use when the user says "retro", "retrospective", "capture learnings", "what did we learn",
  or before clearing context.
allowed-tools: Read, Edit, Write, Glob, Grep, Bash, Agent, AskUserQuestion
---

# Session Retrospective (RSI)

Structured reflection at the end of a session to capture learnings and improve future sessions.

## When to Use

- User explicitly asks for a retro or retrospective
- Before clearing context / ending a session
- After completing a significant piece of work
- When the user says "capture learnings" or "what did we learn"

## Retrospective Process

### Step 1: Review the Session

Scan the conversation for:
- **Corrections**: Times the user said "no", "actually", "stop", "I told you", "look at how we did this before"
- **Failures**: Things that didn't work on the first try (wrong API versions, missing configs, bad assumptions)
- **Surprises**: Things discovered that weren't in the docs or instructions
- **Wins**: Approaches that worked well and should be reinforced

**Under-spawn check (required on every retro):** Ask explicitly:

> "Was there work this session that should have been a worker but wasn't?"

Work qualifies as worker-appropriate if it has a known output shape and can run in an isolated context without ongoing judgment from the lead. Concrete examples:
- "Scan 40+ files for a pattern" — search work with a defined output shape; no lead judgment needed during execution
- "Summarize a long log or large inbox dump" — mechanical reduction; the lead only needs the result, not the process
- "Draft a templated document from a set of inputs" — narrow, isolated-context-safe; inputs are known up front

If any such work was done inline by the lead, file a learning under **Instruction improvement** in Step 2 and consider updating CLAUDE.md or the relevant skill. See cross-project doctrine 06 (lead-worker pattern) for the authoritative guidance on spawn boundaries.

### Step 2: Categorize Findings

For each finding, determine:

| Category | Where to update | Example |
|----------|----------------|---------|
| **Rule violation** | CLAUDE.md (project or global) | "I was told to check existing patterns but didn't" |
| **Missing context** | Memory files | "The ArgoCD cluster is named 'production' not 'prod'" |
| **Process gap** | Onboarding docs / checklists | "Need to verify API version before using CRDs" |
| **New capability** | Memory / baseline docs | "ArgoCD API is accessible from dev-server" |
| **Instruction improvement** | CLAUDE.md or skill files | "Instructions should say to use rancher/k3s image" |

### Step 3: Abstract, Generalize, and Assign a Concrete Action

For each learning, abstract it:
- **Bad**: "Don't use bitnami/kubectl:1.31 because the tag doesn't exist"
- **Good**: "Always verify image tags exist before using them. Check the registry, don't assume version tags follow a pattern"

Then assign EXACTLY ONE concrete action. Every finding MUST result in a change to one of:

| Action type | What changes | Example |
|-------------|-------------|---------|
| **CLAUDE.md rule** | Add/update rule in project or global CLAUDE.md | "Add rule: always use ArgoCD API before asking user for kubectl" |
| **Skill update** | Modify a SKILL.md file | "Update ECR skill to auto-fetch CF Access headers" |
| **Doc update** | Modify a baseline doc, onboarding doc, or checklist | "Add service selector pitfall to deployment checklist" |
| **Template update** | Modify a scaffold/devbox template | "Add component:app label to default deployment template" |
| **Memory rule** | Add feedback memory (only if not covered by above) | "Save as feedback: timestamps in local time" |

**No finding without an action.** If you can't identify a concrete action, ask the user what should change. Don't drop findings — every correction or failure has a root cause that can be prevented.

### Step 4: Execute All Actions

For each finding, execute the concrete action immediately:

1. Make the actual file change (Edit/Write)
2. Verify the change is correct
3. Mark it as done

Do NOT defer actions to "later" or create issues for things that can be done now. Only create issues for actions that require infrastructure changes, user intervention, or significant implementation work.

After all actions are executed:
5. **Commit and push** all changes in a single commit

### Step 5: File GitHub Issues for Outstanding Actions

**Do NOT write forward-looking content to memory files.** GitHub Issues are the only forward-looking source of truth (see `alfred-agent:land`, Step 4).

For every outstanding action, deferred sub-scope, follow-up, or open decision that was not completed this session:

1. Check whether a GitHub Issue already exists for it
2. If not, file one now — with a clear title, body with context and acceptance criteria, and a priority label (P1–P4)
3. Cross-reference related PRs or issues

**What stays in memory (backwards-pointing):** learnings, feedback notes, doctrine references, gotcha records, and other persistent knowledge that a future session needs for context. These are historical artifacts, not work queue entries.

**What does NOT go in memory:** next steps, pending tasks, items to "pick up next session", open decisions that require action. Those must be Issues.

If you find yourself drafting a "next steps" or "what to pick up" memory block — stop. File Issues instead.

## Output Format

Present the retro as:

```
## Session Retrospective — {date}

### Corrections Made (things the user had to fix)
1. [correction] → [generalized rule]

### Discoveries (new things learned)
1. [discovery] → [where documented]

### What Worked Well
1. [pattern to reinforce]

### Updates Applied
- [ ] CLAUDE.md: [change]
- [ ] Memory: [file]
- [ ] Docs: [file]

### Issues Filed
- #N1 [P?]: [title]
- #N2 [P?]: [title]
(File an Issue for each outstanding action; do not write next-steps to memory — see `alfred-agent:land` Step 4)
```

## Anti-Patterns

- **Don't just list what happened** — extract the generalizable lesson
- **Don't add rules for one-off issues** — only for patterns that will recur
- **Don't bloat CLAUDE.md** — if it can be derived from the code, don't write a rule
- **Don't skip the abstraction step** — "use X not Y" is worse than "verify Z before assuming"
- **Don't write "next steps" or "pick up next" to memory files** — that pattern causes stale-snapshot bugs and work that never reaches the issue tracker. File GitHub Issues instead (`alfred-agent:land` Step 4 is the authority on this).
