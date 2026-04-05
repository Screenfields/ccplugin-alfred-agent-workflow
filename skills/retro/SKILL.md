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

### Step 2: Categorize Findings

For each finding, determine:

| Category | Where to update | Example |
|----------|----------------|---------|
| **Rule violation** | CLAUDE.md (project or global) | "I was told to check existing patterns but didn't" |
| **Missing context** | Memory files | "The ArgoCD cluster is named 'production' not 'prod'" |
| **Process gap** | Onboarding docs / checklists | "Need to verify API version before using CRDs" |
| **New capability** | Memory / baseline docs | "ArgoCD API is accessible from dev-server" |
| **Instruction improvement** | CLAUDE.md or skill files | "Instructions should say to use rancher/k3s image" |

### Step 3: Abstract and Generalize

For each learning, abstract it:
- **Bad**: "Don't use bitnami/kubectl:1.31 because the tag doesn't exist"
- **Good**: "Always verify image tags exist before using them. Check the registry, don't assume version tags follow a pattern"

- **Bad**: "Use 'production' not 'prod' for the destination name"
- **Good**: "Always verify naming conventions by checking the actual resource (cluster secrets, labels, etc.) rather than assuming"

### Step 4: Apply Updates

1. **Update CLAUDE.md** for rules that prevent recurring mistakes
2. **Update memory files** for project-specific context
3. **Update baseline docs** for system state changes
4. **Update onboarding checklists** for process improvements
5. **Commit and push** all changes

### Step 5: Prepare Next Session

Write a clear "next steps" summary in memory so the next session knows:
- What was completed
- What's in progress
- What to pick up next
- Any open decisions

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

### Next Session
- Pick up: [topic]
- Open decisions: [list]
```

## Anti-Patterns

- **Don't just list what happened** — extract the generalizable lesson
- **Don't add rules for one-off issues** — only for patterns that will recur
- **Don't bloat CLAUDE.md** — if it can be derived from the code, don't write a rule
- **Don't skip the abstraction step** — "use X not Y" is worse than "verify Z before assuming"
