---
type: doctrine
status: active
updated: 2026-05-22
description: "When a PR's effective scope expands beyond the original intent, stop and split into a separate branch/PR instead of bundling."
read_when: "When tempted to add a 'while I'm here' change to an open PR or branch."
---

# 08. PR scope discipline — split when scope expands

## Rule

When a PR's effective scope expands beyond the original commit's intent, stop and split into a separate branch/PR rather than continue bundling. Two clean PRs beat one bundled PR for review, rollback, and history clarity.

## Why it exists

Bundled concerns slow review because the reviewer must mentally split before assessing each. Rollback of one concern becomes complicated when it's mixed with unrelated changes. Git history loses semantic meaning when one merge represents multiple concerns. The "while I'm here" addition is the canonical antipattern — it feels efficient in the moment and is expensive at review, landing, and rollback.

The 2026-05-22 retro caught this shape on both sides within hours of each other. PM PR #236 started as a smoke spec and grew to bundle a helper-routing fix and a CLAUDE.md doc update. alfred-platform PR #237 started as an e2e-smoke.yml workflow and grew to include a workflow rename and a new e2e-release workflow. Both were caught and de-tangled, but the catching was reactive; the doctrine is to be proactive — notice the scope expansion as it happens and split immediately.

## How to apply

- During work, if you notice "while I'm here" or a tangentially-related fix arising, stop.
- Stash the current change. Open a separate branch for the new concern.
- Two clean PRs beat one bundled. The marginal cost of a second PR is much smaller than the marginal cost of a bundled review + rollback.
- The trigger: am I about to add a file/change that isn't required by the original commit's intent? If yes, branch out.
- Responsibility: the agent doing the work. Reviewer can challenge a bundled PR but should not be the first line of defense.

## Worked examples

**PM PR #236.** Started as adding a smoke spec. Grew to include the smoke spec + a helper-routing fix (different bug in different file) + a CLAUDE.md doc update (different concern entirely). Three concerns in one PR. Diagnostic at landing time was harder; review was slower. Takeaway: each "while I'm here" addition multiplies review cost.

**alfred-platform PR #237.** Started as adding an e2e-smoke.yml workflow. Grew to include the e2e-smoke add + a rename of e2e-regression to e2e-release + the e2e-release workflow. Three concerns. Was de-tangled mid-session via redirect. Takeaway: notice the scope expansion at the second concern, not at the third — split early.

## Related doctrines

- [02-scope-discipline.md](./02-scope-discipline.md) — 02 is about coordination scope; 08 is about PR scope. Same underlying scope-failure principle, different artifact.
- [04-validation-scope-matching.md](./04-validation-scope-matching.md) — narrow PRs deserve narrow validation; wide PRs need wide validation. The two together prevent both "bundled scope, narrow validation" and "narrow scope, bloated validation".
- [09-diagnostic-cleanup-contract.md](./09-diagnostic-cleanup-contract.md) — both about not letting work bleed beyond its intended boundary.

## Cross-side note

Cross-side, both sides bit. Same shape on PM-side (PR #236) and alfred-platform-side (PR #237) within hours. The discipline is identical on both sides.
