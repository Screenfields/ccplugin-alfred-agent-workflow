---
type: doctrine
status: active
updated: 2026-05-27
description: "Before any operation that kills running agent sessions or restarts active-agent pods: identify affected agents, drain-check each, and signal the disruption window explicitly."
read_when: "Before pod restarts, image bumps, node reboots, or any other operation that disrupts running agent sessions."
---

# 15. Drain before disrupt

## Rule

Before any operation that will kill a running agent session or restart a pod with an active agent, **verify the affected agents' state** and **signal the disruption window** explicitly. Three elements:

1. **Identify** which agents are in active sessions inside the blast radius
2. **Drain check** per affected agent — confirm no in-flight work, or notify with a timeout-based greenlight
3. **Signal window** — explicit start/end markers so agents know when to expect disruption and when it's safe to resume

This is a **lightweight guideline, not enforcement automation**. No tooling polices it. User-approved override is always possible — for emergencies, controlled outages, or any case where the operator explicitly chooses to bypass the drain, that override stands.

## Why it exists

The 2026-05-26 incident: `alfred-projects-gitops#50` Recreated 5 spoke devboxes simultaneously without drain-check. Multiple lead agents were mid-conversation when their pods restarted. User correction: "checking that agents are in a correct state before we 'kill' the session is probably a bit more graceful."

The 2026-05-26 team retro endorsed promoting this rule to cross-side doctrine unanimously. Each spoke contributed sharpening:

- **alfred-cc-tools**: praised the wave-2 hook rollout pattern (drain-check + greenlight from each agent → pod restart) as "the right shape for session-disrupting ops"
- **alfred-agent-messaging**: framed it as "drain is not necessarily a hard block — it's a documented check with a clear escalation if the agent is busy"
- **project-manager**: directed scope to keep it lightweight — "codify the wave-2 pattern, not heavy enforcement; tools come later only if a real failure forces them"

## What counts as a "session-disrupting op"

- Pod restart of a pod containing an active Claude Code session (devbox, watcher, control-channel)
- `kubectl delete pod` on the above
- `Recreate` deployment strategy applied to the above
- GitOps changes that trigger any of the above (manifest edits in alfred-projects-gitops/alfred-platform-gitops touching a devbox or hub pod)
- Manual `tmux kill-session` on a session another agent uses

Does NOT count:

- Restarting non-agent infrastructure pods (databases, controllers, operators)
- Routine `RollingUpdate` deploys (one pod replaced at a time; sessions on the surviving replicas continue)
- Auto-flow-driven restarts (Image Updater triggering ArgoCD sync → new deployment) — covered by doctrine 14's escalation-timer model, not this gated model

## How to apply

**For the operator** (the agent performing the disrupting op):

1. Before staging the change: enumerate affected agents (`pod-status` script, ArgoCD app list, or `kubectl get pods -n <namespace>` per pod-status discipline)
2. Send a drain-check message to each affected agent via agent-messaging: "I'm about to restart <pod>; can you confirm no in-flight work, or give me a timeout?"
3. Wait for explicit greenlight from each, OR wait the timeout the agent gave
4. Signal the disruption window start: brief message to each affected agent: "starting restart now"
5. Perform the op
6. Signal end: "restart complete; resume normal operations"

**For the affected agent** (the agent whose session is at risk):

- When a drain-check message arrives: reply with one of (a) "greenlight — no in-flight work" (b) "wait X minutes — finishing Y" (c) "blocked — cannot drain because Z"
- If "blocked", the operator escalates to user for override decision

**For the user**:

- The override is always available. If the operator cannot get drain confirmation from an affected agent within reasonable bounds, the user explicitly authorises the restart anyway. The doctrine doesn't prevent this; it just makes the choice visible.

## What this doctrine does NOT do

- Does not implement enforcement automation (no admission webhook, no CI gate)
- Does not require all parties to use the same drain protocol — the pattern is short message exchanges, the format is informal
- Does not apply to RollingUpdate-shaped restarts where one replica at a time is replaced and surviving replicas hold the session

The cost ceiling is **one short message exchange before disrupting**. Anything heavier defeats the doctrine's lightweight framing.

## Worked example

**Wave-2 hook rollout (2026-05-26).** After alfred-projects-gitops#50 broke 4/5 devboxes by fan-out without drain-check, the wave-2 follow-up (PR #56 + #57) used the right pattern: alfred-platform-hub sent a drain-check message to each affected lead, waited for explicit greenlight (or timeout-based ack), then rolled the manifest changes one spoke at a time. No session was killed mid-task. alfred-cc-tools' retro contribution called this "the right shape for session-disrupting ops" — that framing led to this doctrine.

## Related doctrines

- [06-lead-worker-pattern.md](./06-lead-worker-pattern.md) — spoke leads + hub operate at different layers; this doctrine governs the hub→spoke disruption interface
- [14-auto-flow-escalation-timers.md](./14-auto-flow-escalation-timers.md) — companion doctrine for non-gated timer-driven flows
- [09-diagnostic-cleanup-contract.md](./09-diagnostic-cleanup-contract.md) — both about not letting work bleed beyond its intended boundary
