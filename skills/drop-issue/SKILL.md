---
name: drop-issue
description: >
  Quick-log a follow-up idea as a GitHub Issue without derailing current work. Use when
  something interesting comes up mid-task that isn't in current scope: "that's worth tracking",
  "I should follow up on this", "note this for later". Applies the quick-log label so the
  issue is clearly marked as unrefined. Lightweight by design — no heavy issue guidelines
  until the issue is picked up.
allowed-tools: Bash, Read
---

## When to use

- Mid-task discovery that's out of current scope
- Interesting follow-up worth tracking but not worth derailing current work
- "I'll note this but keep going" moments

## What it produces

A minimal GitHub Issue with:
- `quick-log` label (marks it as unrefined, exempt from heavy issue guidelines until pickup)
- Short title (from the user's description)
- Minimal body: what was observed, why it might matter, current task context

## Step 1 — Capture the idea

Ask if the user hasn't already stated it clearly:
- What's the follow-up? (one sentence)
- Which repo does it belong to? (default: current repo from `git remote get-url origin`)

## Step 2 — Ensure quick-log label exists

```bash
gh label create "quick-log" --color "#0075ca" --description "Unrefined quick-log item; refine at pickup time" --repo {owner/repo} 2>/dev/null || true
```

## Step 3 — Create the issue

```bash
gh issue create \
  --repo {owner/repo} \
  --title "{one-line title}" \
  --label "quick-log" \
  --body "$(cat <<'EOF'
## Quick log

{What was observed / the idea}

## Context

Logged during: {current task or PR description — one line}

---
*Quick-log: refine acceptance criteria at pickup time.*
EOF
)"
```

## Step 4 — Report and continue

Print the issue URL and number. Keep the current task going — do not context-switch.

## Rules

- Keep it fast: 30 seconds maximum. If it takes longer to log than to remember, the mechanism is broken.
- Title must be self-contained — someone reading the issue list cold should understand it.
- No acceptance criteria required at log time — that's for pickup.
- Do not add priority labels at log time — triage happens at pickup.
- Never derail the current task. Log and return.
