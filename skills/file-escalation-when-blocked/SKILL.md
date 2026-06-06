---
name: file-escalation-when-blocked
description: >
  File a structured level:1 escalation issue when you cannot continue working on the
  current issue due to a structural block. Use when stuck on a ready issue and
  verification confirms the block is real.
allowed-tools: Bash, Read
---

# File Escalation When Blocked

When you cannot continue working on a `ready` issue due to a structural block, file a `level:1` escalation issue so PM-supervisor can route unblocking.

## Pre-flight — do not skip

**1. Verify the block is real.**
Apply `verify-assumptions-before-blocking` — run the cheapest available state-check that confirms the blocking premise before filing. If the premise is refuted, re-diagnose instead.

**2. Check for circular dependency.**
Check whether your intended `Suggested actor` already appears in the source issue's `blockedBy` ancestry:

```bash
gh api repos/{owner}/{repo}/issues/{N}/dependencies --jq '.blockedBy[].url'
```

If the `Suggested actor` is upstream in the blocking chain, do NOT file a `level:1` — surface the circular escalation to the user for manual judgment. (`level:2` handling is out of this skill's scope.)

## File the escalation issue

Create the issue in the **source repo** (same repo as the blocked issue):

```bash
gh issue create \
  --repo {owner}/{repo} \
  --title "Escalation: {one-line description of block}" \
  --label "escalation,level:1,urgency:p3" \
  --body "$(cat /tmp/escalation-body.md)"
```

**Body format (escalation-schema: v1):**

```
<!-- escalation-schema: v1 -->

## Escalation: blocked on {one-line description}

**Blocked issue**: {owner}/{repo}#{N} — {title}
**What I can't do**: {specific action blocked — one sentence}
**Suggested actor**: {agent-id or team who should unblock}
**Suggested approach**: {how to unblock — optional, one sentence}

### Verifiable claims
- {claim-type}: {value}
```

**Supported claim types:**

| Type | Example |
|---|---|
| `repo-exists` | `repo-exists: Screenfields/alfred-devbox` |
| `issue-open` | `issue-open: Screenfields/alfred-platform#230` |
| `pr-open` | `pr-open: Screenfields/ccplugin#67` |
| `app-scope` | `app-scope: write:issues missing on alfred-lead-agent install` |

Include only claims verifiable at file-time. Omit the `### Verifiable claims` section entirely if none apply.

## After filing

1. Mark the source issue blocked: `gh issue edit {N} --repo {owner}/{repo} --add-label blocked`
2. Note the escalation issue number in session context.
3. Watch the escalation issue's comments for PM-supervisor's response — do not poll. Continue other available work and check when you next review session state.
