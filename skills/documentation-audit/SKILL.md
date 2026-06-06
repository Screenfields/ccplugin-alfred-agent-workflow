---
name: documentation-audit
description: >
  Audit internal and published documentation against the production-released state of the project.
  Detects baseline drift, undocumented shipped functionality, documented-but-unshipped content,
  and ADR health. Rates each dimension and proposes improvements. Run periodically or after a release.
allowed-tools: Bash, Read, WebFetch
---

# Documentation Audit

Scan internal and published documentation against the production-released state of the project. Produce a rated report with improvement proposals.

## Step 1: Establish the production baseline

Identify what is actually shipped to production.

```bash
# Latest release tag (if using git tags)
git tag --sort=-version:refname | head -5

# Commits merged to main since last tag (unreleased changes)
git log $(git describe --tags --abbrev=0)..HEAD --oneline 2>/dev/null || git log --oneline -20

# GitHub releases
gh release list --limit 5

# For plugin repos: what version is pinned in the marketplace catalog?
gh api repos/Screenfields/alfred-cc-tools/contents/.claude-plugin/marketplace.json \
  --jq '.content' | base64 -d | jq '.plugins[] | {name, version}'
```

This is the **production anchor** — everything that follows compares docs against this state, not against HEAD or planned work.

## Step 2: Enumerate shipped functionality since last audit

Build a list of what was delivered.

```bash
# PRs merged to main since the last release tag
git log $(git describe --tags --abbrev=0)..origin/main --merges --oneline 2>/dev/null

# Or if no tags, all merged PRs in the last N days
gh pr list --state merged --limit 30 --json number,title,mergedAt,body \
  | jq '.[] | {number, title, mergedAt, firstLine: (.body // "" | split("\n")[0])}'
```

For each merged PR, note: what user-visible behavior, configuration, or architectural decision did it introduce or change?

## Step 3: Audit internal documentation

Check each doc class against the production anchor.

### CLAUDE.md
- Does it reflect the current repo structure, conventions, and tooling?
- Are there references to commands, paths, or patterns that no longer exist?
- Any speculative content (future / roadmap / planned / will be / TBD)?

```bash
grep -rn "TODO\|FIXME\|future\|roadmap\|planned\|will be\|TBD\|coming soon" CLAUDE.md
```

### README.md
- Does the setup/usage section match the current install path and commands?
- Does the feature list match what's shipped (nothing more, nothing less)?

### docs/ and ADRs
Check for baseline/delta discipline violations:

```bash
# Speculative language in baseline docs
grep -rn "future\|roadmap\|Phase [0-9]\|planned\|we will\|TBD\|coming soon" docs/ 2>/dev/null

# Decision logs embedded in baseline (should be ADRs)
grep -rn "We decided\|Decision:\|Resolved:" docs/ 2>/dev/null

# ADR health: check for Proposed ADRs that should be Accepted or superseded
grep -rn "^status: Proposed" docs/ 2>/dev/null

# ADRs with multiple numbered decisions (should be split)
grep -rn "^## [0-9]\." docs/adr/ 2>/dev/null || grep -rn "^### [0-9]\." docs/adr/ 2>/dev/null
```

### Coverage gap: shipped but undocumented
For each item from Step 2 that introduced a user-visible change or architectural decision:
- Is it reflected in CLAUDE.md, README, or a doc in docs/?
- If it was an architectural decision: does an ADR exist?

### Coverage gap: documented but unshipped
- Are there sections describing features/behaviors not present in the production-anchored codebase?
- Compare doc claims against the actual code/config at the production tag.

## Step 4: Audit published documentation

Check the project's presence in alfred-platform-docs.

```bash
# Search for project references in platform docs
gh api repos/Screenfields/alfred-platform-docs/contents/ --jq '.[].name'

# Fetch relevant sections (plugin catalog, architecture references, etc.)
# Replace <path> with the relevant file found above
gh api repos/Screenfields/alfred-platform-docs/contents/<path> \
  --jq '.content' | base64 -d
```

Validate:
- Are version numbers / plugin pins in platform docs current with the production release?
- Are capability descriptions accurate (no removed features still listed, no new features missing)?
- Does the platform doc link to the correct source repo paths (not renamed or moved files)?
- Non-duplication: does the platform doc reference the internal doc, or does it restate content that has drifted?

## Step 5: Rate and report

For each dimension, assign: **GREEN** (accurate, complete) / **AMBER** (minor drift, fixable) / **RED** (significant gaps or violations).

```
## Documentation Audit Report — {project} — {date}

### Production anchor
- Version / tag: {version}
- Last release: {date}
- Shipped PRs since last audit: {N}

### Internal documentation
| Document | Rating | Finding |
|---|---|---|
| CLAUDE.md | GREEN/AMBER/RED | {one-line finding or "accurate"} |
| README.md | GREEN/AMBER/RED | {one-line finding} |
| docs/adr/ | GREEN/AMBER/RED | {one-line finding} |

### Published documentation (alfred-platform-docs)
| Document | Rating | Finding |
|---|---|---|
| {path} | GREEN/AMBER/RED | {one-line finding} |

### Coverage gaps
**Shipped but undocumented:**
- PR #{N}: {title} — {what's missing}

**Documented but unshipped:**
- {doc} § {section}: describes {X} which is not in production

### ADR health
- Stale Proposed: {list or "none"}
- Multi-decision ADRs (should split): {list or "none"}
- Decisions in baseline prose (should be ADRs): {list or "none"}

### Overall rating: GREEN / AMBER / RED

### Improvement proposals
1. {specific, actionable improvement — file, section, what to change}
2. ...
```

## Notes

- Run after every release and quarterly between releases.
- The authoritative documentation strategy is at `alfred-platform/docs/baseline/platform/documentation-strategy.md` — consult it for baseline/delta discipline rules.
- **To fix findings**: use `/alfred-agent:documentation` — it operationalises the same strategy for creating, updating, and quality-gating individual docs. This skill finds the gaps; the `documentation` skill closes them.
- For per-doc drift checks during active writing (not a periodic audit), use Step 3 of `/alfred-agent:documentation` directly.
- File improvement proposals as GitHub issues with label `docs` + `audit` for tracking, so they surface in future `/alfred-agent:waiting` sessions.
