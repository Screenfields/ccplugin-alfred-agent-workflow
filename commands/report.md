---
description: Structured status overview — open/closed issues, pending PRs, inbox state, and items blocked waiting on other actors or the user.
---

**First, check for project config:**

1. Look for `.alfred/config.json` in the project root.
2. If found, read `agent_id` from it.
3. If NOT found, display:
   ```
   Project not initialized for alfred-agent messaging.
   Run /alfred-agent:init to set up this project's identity.
   ```
   And stop here.

Generate a structured status report for this agent's current work.

## Steps

**1. Read project identity**

Read `agent_id` from `.alfred/config.json`. If the file has a `repos` list use it; otherwise derive from `gh repo list` in the current org context or from recent `git remote` output.

**2. Open issues**

```bash
gh issue list --state open --limit 20 --json number,title,labels,assignees,createdAt \
  | jq '.[] | {number, title, labels: [.labels[].name], age: .createdAt}'
```

**3. Recently closed (last 7 days)**

```bash
gh issue list --state closed --limit 10 --search "closed:>$(date -d '7 days ago' +%Y-%m-%d 2>/dev/null || date -v-7d +%Y-%m-%d)" --json number,title,closedAt
```

**4. Open PRs**

```bash
gh pr list --state open --json number,title,reviewDecision,isDraft,statusCheckRollup \
  | jq '.[] | {number, title, reviewDecision, isDraft, ci: (.statusCheckRollup | map(.conclusion) | unique)}'
```

**5. Inbox**

Call `mcp__agent-messaging__get_messages(unread_only=true, as_agent="{agent_id}")`. Note sender and subject for each unread message; do not auto-mark as read.

**6. Blocked / waiting items**

Collect from:
- Issues labeled `blocked`, `waiting`, or `needs-decision`
- Open PRs where review or CI is blocked on a specific actor
- Unread inbox messages that require a decision before action
- Items from current session context explicitly noted as "waiting on [actor]" or "pending user direction"

## Output format

```
## Status Report — {agent_id} — {date}

### Recently Done
- #{number}: {title} — closed {N} days ago

### In Progress
- #{number}: {title} — {state / one-line status}

### Open PRs
- PR #{number}: {title} — {reviewDecision | CI status}

### Blocked / Waiting
- {item} — waiting on: {actor} — {reason}
  (if none: "Nothing blocked.")

### Inbox
- {N} unread from: {sender list}
  (if zero: "Inbox clear.")
```

One line per item. Flag urgency only when a known deadline exists. Do not editorialize — facts only.
