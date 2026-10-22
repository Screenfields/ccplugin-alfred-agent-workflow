Review the work item below for the ready transition. The sources it is checked against are quoted after it.

## Work item (repo Screenfields/ccplugin-alfred-agent-workflow, issue #140)

**Title:** Weekly stale-branch report for the plugin repo

**Objective**

Supports O7, "Keep the plugin repo lean".

**Benefit and who notices it**

The lead sees stale branches at the weekly retro and deletes them. Fewer dead branches means less noise when listing branches.

**If nothing is done**

Stale branches pile up and nobody notices them.

**Estimate**

Class: **small**. The change adds one script and one threshold name to the thresholds config.

| Role | Tier / effort | Tokens | Derived from |
|---|---|---|---|
| Lead | default (Opus) | 0.2M | brief, merge |
| Builder | medium / medium (Sonnet) | 0.6M | script 0.4 · threshold 0.1 · README 0.1 |
| Code reviewer | medium / high (Sonnet) | 0.3M | 1 PR, 2 rounds |
| **Total counted** | | **1.1M** | Opus 0.2M · Sonnet 0.9M |

- Weighted, factor unit: 0.07M. Assumes 10% of counted tokens are not cache reads; weights Opus 1.0, Sonnet 0.6.
- Notional cost: 0.07M x EUR 0.21 = **EUR 0.02** (`factor: initial-guess-2026-10-22`).
- Additional spending: none.

**Success state**

The lead gets a list of branches that have had no commit for a long time.

**Acceptance criteria**

1. `bin/alfred-stale-branches` lists every remote branch of the repo whose last commit is older than `stale-branch-days` days, newest first, with the branch name, the last commit date and the author.
2. The report is fast and easy to read.
3. `stale-branch-days` is a new name in `config/thresholds.json` and is read through `alfred-config get`.
4. The script exits 0 when it lists branches or when none are stale, and exits 2 when the repo cannot be read.

**Bounds**

- In scope: the script, the new threshold name, a README paragraph.
- Out of scope: deleting branches; reporting on forks.
- Blocked by: none. The script reads `alfred-config`, which landed in #131 (merged, version 2.25.0).

**Test structure**

Not decided yet.

## Source: objectives register (test fixture, complete for this case)

| ID | Objective | Status |
|---|---|---|
| O1 | Operate the platform reliably | approved |
| O2 | A way of working that is enforced and improves itself | approved |
| O3 | Every agent session starts with the rules it needs | approved |
| O4 | Spend is tracked per work item | approved |

## Source: item template (test fixture)

Objective; Benefit and who notices it; If nothing is done; Estimate (tokens per role and model tier, with derived parts and the reason for the class); Success state; Acceptance criteria (each testable by a named check); Bounds (in scope, out of scope, blocked by); Test structure (runner, style, file).

## Source: sizing rule (AP-ADR0026, as applied in this repo)

A change that hits many projects, Proxmox, a threshold or a core rule is medium at least. Small takes the light path. Large and very large need the owner at ready and at designed.

## Source: state of linked items

| Item | State |
|---|---|
| #131 Work-item marks on the agent-run store | closed, merged in 2.25.0 |
