---
type: doctrine
status: active
updated: 2026-06-04
description: "Before escalating to the user, exhaust the cheaper options in order: query-able systems, peer agents, sensible defaults — the user is the oracle for judgment calls, not lookups."
read_when: "When about to ask the user a question or escalate a blocked task."
---

# 16. Escalation gradient

## Rule

Before escalating to the user, **exhaust the cheaper-than-human options** in order:

1. **Check the API / docs / catalog** — does the answer already exist in a system the agent can query? `gh api`, `kubectl get`, `argocd app get`, secret-service search, lead-roles frontmatter, ADR catalog, gitops repos. If yes, the user is the wrong oracle for a lookup.
2. **Check whether a peer agent already has it** — PM owns project records, monitoring owns observability state, security owns ACL inventory, secret-service owns credentials. If the answer lives in a peer's domain, ask the peer.
3. **Check whether sensible defaults make the user the wrong oracle** — if all reasonable options would lead to the same conclusion, the choice is structural, not a user preference. Pick the sensible default + surface what was chosen.
4. **Only then escalate.** The user is the right oracle for **judgment calls and decisions**, not for facts that can be looked up or peer-consultations that don't need their attention.

This doctrine **operates on a different decision axis from doctrine 06 (lead-worker-pattern)** — d06 is "which agent layer handles this" (hub vs spoke vs worker), d16 is "do we involve a human at all." The two **compose** without conflict: d16 step 2 ("check whether a peer agent already has it") IS a d06 invocation, asking which agent owns the question and routing accordingly. A piece of work can be hub-fit at the d06 layer axis AND wrong-to-escalate at the d16 human-vs-agent axis simultaneously.

Same composition with **doctrine 10 (delegate-execution-not-synthesis)** — d10 is when a worker is the right tier, d16 is when the user is the right tier. They stack on different points in the workflow (d10 at execution-delegation time, d16 at escalation-decision time).

## Why it exists

The pattern emerged from multiple recurring frictions where the user was asked to provide an answer that should never have reached them:

- A lead asks the hub to do something the auto-flow already handles → hub forwards to user → user has to redirect
- The hub waits for the user to ask "what's happening with X" instead of proactively monitoring → user becomes the load-bearing dispatcher
- An agent encounters a fact (file path, image tag, secret existence, repo state) and asks the user instead of running the one-command check that returns the answer

Each instance individually is small. Cumulatively they make the user a queueing bottleneck for work that should flow agent-to-agent or agent-to-API.

Project-manager's `dont-proxy-questions-to-user` rule was the originating call-out: PM had observed that asking the user to relay information between agents (when both agents could query the source directly) makes the user a human router. The same shape applies at every agent-to-agent boundary. Doctrine 16 lifts it from PM-specific to cross-project.

## What counts as "the user" for this gradient

Three increasingly-different shapes — the doctrine fires hardest on (a):

- (a) **The human owner of the platform** (Jochem). Most escalations to this tier should be judgment calls or explicit-go-ahead asks for irreversible writes. Lookups + agent-side state-checking are the WRONG escalation for (a).
- (b) **A peer lead asking the hub** (or the hub asking a peer lead). This is mostly doctrine 06 (layer model) — the escalation-gradient question is "could I have answered this from my own state before asking?" If yes, the ask was premature.
- (c) **A worker asking its parent lead**. Workers are bounded by their brief; if a worker's brief is well-scoped they shouldn't need to ask. If they do, the brief was probably under-specified — that's a synthesis-side issue (doctrine 10), not pure escalation-gradient.

The rule applies symmetrically, but (a) is the load-bearing case in day-to-day operation.

## How to apply

**For the agent considering an escalation to the user:**

1. **Pause.** Before drafting the message, ask: "what would the cheapest verification look like?"
2. **Try the lookup.** Run the API/CLI/grep that would answer the question definitively. Most user-bound questions resolve here.
3. **Try the peer.** If the answer is owned by another agent (PM for project state, security for ACL, monitoring for observability, etc.), send a message to the peer first.
4. **Pick a default + surface it.** If the question has a clear sensible-default answer, take it and surface the choice ("picked X because Y; flag if wrong"). The user can correct, but didn't have to gate.
5. **Only then escalate** — and when you do, scope the ask to the judgment/decision part. Pre-fetch the lookups, present the options, ask the user to choose.

**For the user receiving an escalation:**

- The doctrine is *agent-side discipline*. The user is not on the hook for enforcing it; they can always answer any question. But persistent escalation-gradient violations are a signal that the agent's mental model needs correction.

## What this doctrine does NOT do

- **Does not say "never ask the user"** — judgment calls (architectural direction, irreversible writes, capability grants, user-preference questions) belong with the user. The doctrine targets *unnecessary* escalation, not all escalation.
- **Does not require all lookups before asking** — if the lookup itself would take longer than the user's response would, judgment call. The principle is "exhaust the cheaper-than-human options," not "exhaust every possible option."
- **Does not conflict with doctrine 11 (design-phase-recheckpoint)** — doctrine 11 fires on *scope drift* (the conversation has wandered N items beyond the original ask, requires a re-checkpoint). Doctrine 16 fires on *answers that don't need the user* (the agent could resolve this without escalation). Both can fire simultaneously and don't contradict: scope drift may require user re-checkpoint EVEN IF the individual items don't need them, because the cumulative drift is the user's decision. **Precedence: when d11 is firing (scope drift detected), d16 step 3 ("sensible default + proceed") is NOT available.** Scope drift always re-anchors with the user, regardless of how clear the per-item default seems — otherwise d16 becomes a cover for bypassing d11.
- **Does not apply to autonomous-loop mode standing orders** — if the user has explicitly delegated a standing pattern ("solve any lead asks proactively"), the agent operates within that grant without per-action re-asking. That's the user pre-deciding, not the agent avoiding escalation.

## Worked examples

### Example 1 — cheap lookup beats user-poll

An agent considers asking the user *"is PR #N merged yet?"*. With doctrine 16: `gh pr view N --json state,mergedAt` returns the answer in under 500ms. The user-ask never fires; the agent acts on the lookup.

This is d16 in its purest shape: a factual question with a definitive API answer. No d06 (agent-layer) decision, no d10 (worker tier) decision — just lookup-vs-escalate. The user is not the right oracle for state that's already queryable.

(Earlier draft had an auto-flow-handles-this example here, but that's primarily a doctrine-06 lesson with "user not involved" as a side effect. The lookup framing here isolates d16 from confounding axes.)

### Example 2 — proactive monitoring vs reactive prompting

The hub notices that 3 spokes merged PRs hours ago but their pods never restarted to pick up the changes. Without escalation-gradient discipline, the hub waits for the user to ask "are those PRs deployed?" — making the user the monitoring loop.

With doctrine 16: the hub proactively queries ArgoCD for merge-vs-rollout drift, flags the issue to itself, and either (a) restarts the pods (within auto-flow timer thresholds per doctrine 14) or (b) notifies the affected spokes. The user is informed by being told "I noticed X, did Y" — not by being asked "what's the state of X?"

Source: `feedback_stay_on_top_of_lead_agent_activities.md` (2026-05-25 incident).

### Example 3 — peer-vs-user oracle selection

A lead asks the hub "what's the canonical 1Password path for the LiteLLM key?" Without escalation-gradient discipline, the hub might ask the user.

With doctrine 16: the hub runs `mcp__secret-service__search_secrets(query="*litellm*")`. The answer comes back in under a second. The user is never asked. This is the most-common escalation-gradient violation in practice: factual questions where the API is the right oracle.

Source: PM's `dont-proxy-questions-to-user` rule — the originating call-out that led to this doctrine.

## Related doctrines

- [06-lead-worker-pattern.md](./06-lead-worker-pattern.md) — orthogonal axis (which agent layer handles this); 16 is the human-vs-agent axis on top
- [10-delegate-execution-not-synthesis.md](./10-delegate-execution-not-synthesis.md) — adjacent: when worker is the right tier vs when user is
- [11-design-phase-recheckpoint.md](./11-design-phase-recheckpoint.md) — companion: re-checkpoint with user on scope drift even when individual items don't need them; the two doctrines don't conflict
- [14-auto-flow-escalation-timers.md](./14-auto-flow-escalation-timers.md) — companion: when the auto-flow is the right oracle, neither agent action nor user escalation is needed
