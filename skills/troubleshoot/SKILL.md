---
name: troubleshoot
description: >
  Structured diagnostic workflow for investigating failures, unexpected behavior, or broken
  systems. Use when something is broken and you need to find out why — NOT when you need to
  implement a feature (use alfred-agent:develop for that). Separate from develop because
  troubleshooting has its own discipline: cleanup contract upfront, hypothesis-driven probes,
  ground-truth verification, narrow interventions, conclude-or-escalate, teardown.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Agent
---

# alfred-agent:troubleshoot

Structured diagnostic workflow for investigating failures, unexpected behavior, or broken systems.

## When to use vs. develop

- **Use troubleshoot:** something is broken, behaving unexpectedly, or failing — you need to find out why
- **Use develop:** you know what to build and need to implement it
- **Never mix:** don't start troubleshoot and slide into implementation; if you find the fix, stop, document it, and invoke develop

## Step 0 — Cleanup contract (do this first)

Before touching anything, state explicitly:

1. **What you will probe** — commands, logs, and files you'll read
2. **What you will NOT change** during diagnosis
3. **Cleanup:** what will be left behind (temp files, test processes, log noise) and how you'll remove them

This prevents the common failure of leaving the system worse than you found it.

## Step 1 — State the symptom precisely

Write one sentence: "X is happening when Y is expected."

If you cannot write this sentence, you do not understand the problem yet — ask the user before proceeding. Do not begin probing until the symptom is stated clearly.

## Step 2 — Gather ground truth

Before forming hypotheses: look at actual state. Do not theorize from memory.

- Read relevant logs (last N lines, not the whole file)
- Check process state: `ps aux | grep {process}`
- Check port bindings, file existence, config values — whatever is relevant to the symptom
- State what you found: "actual state is X"

Gather facts first. Hypotheses come after.

## Step 3 — Form hypotheses

List 2–3 candidate root causes, ordered by likelihood. For each:

- **Hypothesis:** "The problem is caused by..."
- **Test:** "I can verify this by..."
- **Falsifier:** "This hypothesis is wrong if..."

Do not probe yet. Write all hypotheses before running any tests.

## Step 4 — Probe narrowly

Test hypotheses one at a time, starting with the most likely. For each probe:

1. State what you're testing
2. Run the minimal command that tests it
3. Report what you found
4. Update the hypothesis list (confirm, eliminate, or revise)

Stop when you have a confirmed root cause OR have eliminated all hypotheses (→ Step 5, escalate path).

If a probe changes system state, note it explicitly.

## Step 5 — Conclude or escalate

### Escalation thresholds (check before each probe)

Stop immediately and escalate if either threshold is breached:

- **Side-effects ≥ 5** — you have created 5 or more side-effects during this session
- **30+ minutes elapsed without progress** — 30 or more minutes have passed since the last confirmed or eliminated hypothesis

**Definition of side-effect** — any of the following counts as one side-effect:
- Created a K8s resource (Pod, Deployment, Job, Namespace, Secret, etc.)
- Scaffolded a repo or directory structure outside the working directory
- Made a persistent host config change (modified `/etc/`, systemd unit, cron entry)
- Created a `/tmp` artifact that will outlive the current troubleshoot loop
- Sent an agent-message to another agent

**Definition of progress** — a hypothesis confirmed OR eliminated by evidence:
- "Checked logs, error X is NOT present → hypothesis A eliminated" = progress
- "Reproduced the failure with input Y → hypothesis B confirmed" = progress
- Spinning in place, retrying the same command, or generating new hypotheses without confirming/eliminating old ones does NOT count as progress

**On threshold breach:**
1. Stop immediately — do not take further actions
2. Summarise current state: hypotheses tested, which were confirmed, which were eliminated
3. List all side-effects created so far (for cleanup)
4. Escalate to user before continuing:
   > "Escalation threshold reached. Summary: [state]. Side-effects: [list]. Please review before I continue."

### If root cause confirmed

- State it clearly: "Root cause: ..."
- Recommend fix: "Fix: ..." (do not implement — hand off to `alfred-agent:develop`)
- Note any side effects or risks

### If root cause not confirmed after exhausting hypotheses

- Report what was ruled out
- State what information is still missing
- Escalate to user: "I've eliminated X, Y, Z. The following would help narrow it further: ..."
- Do NOT guess and implement

## Step 6 — Teardown

Execute the cleanup contract from Step 0:

- Remove temp files created during diagnosis
- Stop any test processes started during diagnosis
- Report what was cleaned up

Leave the system in the same state it was in before diagnosis began (or better, never worse).

## Rules

- **Never implement a fix during troubleshoot** — that is develop's job
- **Cleanup contract before first probe**, no exceptions
- **Ground truth before hypotheses** — read actual state, do not recall it from memory
- **Narrow probes only** — test one hypothesis at a time
- **Conclude-or-escalate** — do not leave the user with an open-ended "maybe it's X"
- **Note state changes** — if a probe changes system state, say so explicitly
- **Escalate at threshold** — side-effects ≥ 5 or 30+ min without progress: stop, summarise, list side-effects, escalate before continuing
