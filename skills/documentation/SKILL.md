---
name: documentation
description: >
  Apply baseline-vs-delta discipline + ADR conventions when creating, updating, or auditing
  project documentation. Use when about to write/update files in `docs/` (especially baseline,
  decisions/, or adr/), when about to merge a PR that changes behavior, when capturing an
  architectural decision, or when auditing a doc for drift. Operationalizes the cross-project
  strategy at alfred-platform/docs/baseline/platform/documentation-strategy.md.
allowed-tools: Read, Write, Edit, Bash, Grep, Glob
---

# Documentation Discipline

Authoritative reference: `alfred-platform/docs/baseline/platform/documentation-strategy.md`. Read it once if you haven't recently. This skill operationalizes that strategy at the moment of writing or auditing a doc.

## Step 0 — Branch on what you're doing

1. **Writing/updating baseline** (functional, technical) → Step 1
2. **Writing an ADR** (capturing an architectural decision) → Step 2
3. **Auditing an existing doc for drift** → Step 3
4. **PR quality gate** (about to merge a behavior change) → Step 4

If two apply (e.g. a PR ships a feature + needs an ADR), do them in order: ADR first (Step 2), then baseline updates (Step 1), then quality-gate check (Step 4).

## Step 1 — Writing/updating baseline

Before writing a single line, ask: **does this content describe what's on `main` right now, or what we plan/want?**

If "plan/want" — STOP. This is delta. It belongs in:
- GitHub issues (proposals, acceptance criteria)
- Feature branches (design docs travelling with the code, until they merge)
- Agent-messaging threads (cross-agent design discussion)
- NOT in baseline.

**Speculative-content patterns to refuse**:
- Section titles: `## Future Improvements`, `## Roadmap`, `## Implementation Phases`, `## Phase N (planned)`, `## TODO`, `## Coming soon`, `## Resolved Questions` (process residue), `## ECR Decisions Log` (decisions belong in ADRs)
- Prose: "we will / we plan to / in v2.5 this will / next we'll add"
- Unimplemented designs documented in present tense

If the content describes shipped behavior, place it correctly:
- **Functional** (requirements, scenarios, user-visible behavior) → `requirements.md` or `docs/baseline/functional/`
- **Technical** (architecture, APIs, data model, deployment, configuration) → `design.md` or `docs/baseline/technical/`
- **Decisions** (the *why*) → see Step 2 (ADR)

The three dimensions are non-overlapping. A new feature usually touches all three; if you only update one, you've left the others in drift.

## Step 2 — Writing an ADR

Template: `alfred-platform/docs/templates/adr.md`. Canonical examples: `alfred-platform/docs/decisions/`.

**Mandatory checks before writing**:

- **One decision per ADR.** State the decision in one sentence ("We use X over Y"). If you need two sentences ("We use X for component A and Y for component B"), split.
- **Title = the decision, not the feature.** "Use `templatePatch` over inline structural directives" — NOT "AppSet template improvements" or "Project Lifecycle v2".
- **Real alternatives.** Name at least one runner-up with a one-sentence rejection rationale. If you can only name the chosen path, you haven't done the analysis — go back and consider 2-3 real alternatives before writing.
- **Status lifecycle**: start `Proposed`, promote to `Accepted` when the code lands. Once Accepted, the body is **immutable**.

**Amending an existing ADR**: never edit an Accepted ADR in place. Write a new ADR that supersedes it. Cross-link both directions:
- New ADR header: `Status: Accepted (supersedes ADR-NNNN)`
- Old ADR header: `Status: Superseded by ADR-NNNN` (header only — body stays unchanged as historical record)

**Where the file lives**:
- Cross-project / platform-level decisions → `alfred-platform/docs/decisions/`
- Service-level decisions → `<service>/docs/adr/` or `<service>/docs/decisions/`

**Length sanity check**: well-scoped ADRs are 30-60 lines. If yours is past 100, you probably packed multiple decisions or your "Context" is bleeding into specification (which belongs in technical baseline, not in an ADR).

## Step 3 — Auditing for drift

Open the doc. Run grep / read through and flag each occurrence of the patterns below. For each flag, propose the fix.

| Pattern | Fix |
|---|---|
| `## Future`, `## Roadmap`, `## Phase`, `## TODO`, `## Coming`, "we will", "we plan", "in v" | Move to GH issue / epic. Delete from baseline. |
| Sections named `## Decisions`, `## Decision Log`, `## ECR Decisions` inside functional/technical baseline files | Promote each entry to its own ADR in `decisions/` or `adr/`. Delete the section. |
| `Amended <date>` line in an Accepted ADR header | Split: revert ADR to its original Accepted body, write a new ADR superseding it with the amendment. |
| Multiple `### 1.`, `### 2.`, `### 3.` under a single `## Decisions` heading in one ADR | Split into N single-decision ADRs. The original becomes a Superseded index. |
| ADR titled after a feature/version (`Project X v2`, `Auth Module`) | Rename around the actual decision. If multiple decisions share the title, split first. |
| `## Resolved Questions` sections | Either delete (resolved → the design itself reflects the answer, no Q&A frame needed) or promote the resolution to an ADR if non-obvious to a future reader. |

If the doc is large, use grep to surface candidates fast:

```bash
grep -nE '^## (Future|Roadmap|Phase|TODO|Coming|Resolved Questions|Decisions Log|ECR Decisions|Implementation Phases)' <file>
grep -nE 'we (will|plan)|in v[0-9]|coming soon|TODO|FIXME' <file>
```

## Step 4 — PR quality gate

When about to merge a PR that changes behavior, verify in the same PR:

1. **Functional match** — if user-visible behavior changed, baseline functional doc reflects it.
2. **Technical match** — if architecture / API / data-model / deployment changed, baseline technical doc reflects it.
3. **Decisions captured** — if a real architectural choice was made (one with alternatives that were considered), an ADR exists for it.

If any of the three is missing — **block the merge**. The strategy doc explicitly says no exceptions to the PR quality gate. Drift starts here.

Exception: pure refactor with zero behavior change. State that explicitly in the PR description so reviewers know the absence of doc updates is intentional.

## Cross-references

- Strategy doc: `alfred-platform/docs/baseline/platform/documentation-strategy.md`
- ADR template: `alfred-platform/docs/templates/adr.md`
- Example ADRs: `alfred-platform/docs/decisions/`
- Related skills: `design` (for TOBE design docs on a feature branch — that's delta), `git-commit` (don't commit doc-less PRs)
