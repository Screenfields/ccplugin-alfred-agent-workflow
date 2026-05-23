---
name: design
description: >
  Guided design document creation for new services, features, or integrations. Use when the
  user says "let's build X", "design this", "plan for X", or when you're about to implement
  something involving multiple components, a new service, or unfamiliar technology. Also
  trigger when the user asks to scaffold, bootstrap, or create a new project. This skill
  prevents common failures: missing UI, wrong target environment, missing deployment setup.
allowed-tools: Bash, Read, Write, Glob, Grep, Agent
---

# Design Document

Structured design workflow before implementation. Do not write code until this process completes.

## Step 1: Understand the problem

Ask these three questions. Do not proceed until answered.

1. **What** are we building? (one sentence)
2. **Who** uses it? Pick one: humans / agents / both
3. **Why** now? What problem does it solve?

Before continuing, search the codebase for related work:
- `docs/baseline/` for similar services
- Memory files for relevant context
- Gitops repos for similar deployment patterns

Present what you found: "I found these existing patterns: [X]. Should we follow the same approach?"

- **Verify live state before designing.** Run the cheapest ground-truth query (gh api, kubectl get, git log) to confirm existing infrastructure before proposing designs that depend on it. A design built on an unverified state claim is wrong when that claim is stale (Doctrine 01).

## Step 2: Cover all dimensions

Work through each section. State "N/A" with a reason if one doesn't apply — don't skip silently.

### Users & Frontend

If humans use it (from Step 1), a UI is required. Ask:
- What pages/views are needed?
- Tech stack? (recommend based on existing patterns)
- How is it served? (SPA via same server, separate deployment?)

If agents-only, state: "No UI — agents interact via API."

### Backend

- Tech stack (language, framework, database)
- Key API endpoints (method, path, purpose)
- Integration points (other services it talks to)
- Data model (what state does it manage?)

### Target Environment

Fill in every row:

| Question | Answer |
|----------|--------|
| Where is it developed? | |
| Where does it run (dev)? | |
| Where does it run (prod)? | |
| How is it deployed? | |
| What gitops entries are needed? | |
| What secrets are needed? | |
| What domain/DNS? | |
| Prerequisites to create first? | |

### CI/CD

- Build pipeline and triggers
- Image tagging strategy
- How do image updates reach the cluster?

### Security

- Authentication (CF Access, API tokens, both?)
- Authorization (who can call what?)
- Secret management approach

## Step 3: Write the document

Create `docs/design.md` in the project repo. Use this structure:

```markdown
# {Name} Design Document

**Status:** Draft — pending review
**Date:** {today}

## Overview
## Tech Stack
## Architecture
## API Design
## Frontend
## Target Environment
## Security
## Implementation Phases
## Open Questions
## Decision Log
```

### Decision Log

Every significant design choice gets an entry in the Decision Log. This is the project's ADR (Architecture Decision Record). Format:

```markdown
## Decision Log

| # | Decision | Rationale | Alternatives considered |
|---|----------|-----------|----------------------|
| 1 | Node.js + Express | Consistent with existing platform services | Python FastAPI, Go |
| 2 | Per-project PostgreSQL | Isolation, simple teardown | Shared instance, operator |
```

When an ECR is run, add the ECR verdict and model consensus to the rationale. Decisions made during implementation also go here — not just design-time choices.

Scaffold all sections first with placeholders, then fill from Step 2 answers. Ask the user to review: "Please read through this. What should change?"

## Step 4: Validate

If there are open questions or significant design decisions, ask: "Want to run an ECR on this?"

Recommend ECR when multiple valid approaches exist or the technology is unfamiliar. Skip if the design follows an established pattern exactly.

## Step 4.5: Coupled-ADR review gate

Before declaring the design complete, count how many ADRs (Decision Log entries) were produced in this session.

**Single-ADR bypass:** If the Decision Log contains exactly one entry, skip this gate entirely — no review pass required, proceed directly to Step 5.

**When ≥2 ADRs are present**, check for coupling before proceeding:

### Coupling detection heuristic

Two ADRs are coupled if either condition holds:

1. **Cross-reference:** one ADR entry's Decision or Rationale text explicitly names or references another ADR by number, topic, or component name.
2. **Shared boundary:** both ADRs touch the same component, interface, or contract (e.g., two decisions that both affect the API shape, the same database schema, or the same deployment unit).

If no coupling is detected among the ≥2 ADRs, document that finding ("ADRs are independent — gate skipped") and proceed to Step 5.

If coupling is detected, **the following mandatory review pass is required before the design is marked complete.**

### Mandatory critical-review pass (coupled ADRs only)

**a. `file_refs_verified` lint**

Collect every file path referenced anywhere in the ADRs (and in the design document). For each path run:

```bash
ls <path>   # or: find . -path "<path>" -maxdepth 5
```

Produce a table:

| Referenced path | Exists? |
|-----------------|---------|
| `docs/baseline/foo.md` | yes / NO |

Any missing path is a blocking finding that must be resolved or explicitly deferred before the design is marked complete.

**b. Critical-review agent pass**

Dispatch a reviewer using the Agent tool. The reviewer must evaluate the coupled ADRs across three angles:

- **Architecture** — are the coupled decisions internally consistent? Do they create a hidden dependency or circular constraint?
- **Security / correctness** — does the coupling introduce an attack surface, a race, or a correctness gap that neither ADR addresses alone?
- **Operability** — can the decisions be deployed, rolled back, and debugged independently, or does coupling create an operational blast radius?

Suggested Agent prompt:

```
You are a critical reviewer. Review the following coupled ADRs:

[paste ADR entries]

Evaluate across three angles: architecture consistency, security/correctness, operability.
For each finding, state:
- Angle (architecture | security | operability)
- Severity (blocking | advisory)
- Finding (one sentence)
- Suggested resolution (one sentence)

Return a structured findings list only. No preamble.
```

**c. Structured findings list and dispositions**

Collect all findings (from the `file_refs_verified` lint and the Agent reviewer) into a single list:

| # | Source | Angle | Severity | Finding | Disposition |
|---|--------|-------|----------|---------|-------------|
| 1 | file_refs_verified | — | blocking | `docs/baseline/foo.md` does not exist | addressed / deferred-to-PR |
| 2 | critical-review | architecture | advisory | ADR-1 and ADR-3 both own the API contract with no clear precedence | addressed / deferred-to-PR |

Each finding requires an explicit disposition of **"addressed"** (fix applied now) or **"deferred-to-PR"** (tracked as a GitHub Issue or PR comment) before the design may be marked complete. A finding may not remain blank.

Only after all findings have dispositions is the design considered complete.

## Step 5: Prerequisites

Before any implementation, present this checklist and complete each item:

- [ ] Repository exists?
- [ ] Development environment ready? (devbox pod, not dev-server)
- [ ] Secrets created in 1Password?
- [ ] Gitops entries for deployment?
- [ ] GitHub Issues created for implementation tasks?
- [ ] CI workflow in place?

Do not start coding until all prerequisites are done.
