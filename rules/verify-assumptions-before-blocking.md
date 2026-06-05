---
name: verify-assumptions-before-blocking
description: "A BLOCKER should never be based on false assumptions. Before declaring something blocked — escalating to the user, filing a tracking issue, asking for setup work, halting your own progress — verify the blocking assumption via the cheapest available state-check. Never relay a peer agent's diagnosed blocker on faith."
---

## The rule

**A blocker must be empirically verified before it is declared.**

Before any of the following, run the cheapest state-check that confirms or refutes the blocking premise:

- Escalating to the human user with an action ask
- Filing a tracking issue for "blocked on X"
- Halting forward progress because you believe X is broken
- Propagating a peer agent's diagnosis as a blocker in your own outputs

A blocker propagated on an unverified assumption multiplies the cost of being wrong: the user reads it, peers act on it, follow-up work gets scoped around it. False-positive blockers are the most expensive class of state-claim because they pull others into wrong-direction action, not just the originating agent.

## Why this rule exists

Blockers carry outsized propagation weight. A regular state-claim is wrong in one place; a blocker is wrong in many places at once:

- The user reads it and may take action that wouldn't have helped
- Peer agents read it and may reshape their own plans around the false ceiling
- Tracking issues created on the false premise pollute the backlog
- The original cause (the *actual* root) stays undiagnosed because the team is acting on the wrong one

Doctrine 01 (`verify-claims-about-state`) already covers state-claim verification broadly. This rule is its stricter form for the blocker case: when the cost of being wrong is multiplied by all downstream actors, the verification step is non-optional.

The pattern that triggered this rule (2026-06-05): a peer agent diagnosed an MCP tool 401 as "GitHub App install repo_selection is 'selected', not 'all'", cited a specific install ID. The next agent in the chain relayed the diagnosis to the user as Step 1 of a "walk through your actions" sequence. The user pushed back ("PM already has access to all repos") — a single `gh api /orgs/<org>/installations` call would have shown all 5 Apps were `repo_selection: "all"`, AND the cited install ID belonged to a different App than the diagnosis claimed. Both the original diagnosis AND the relay were operating on unverified assumptions; both were wrong.

## How to apply

**Step 1 — identify the blocking premise.** What specific claim makes this a blocker? Examples:

- "App install scope excludes repo X" → premise is the install's `repository_selection`
- "Token is missing scope Y" → premise is the App's `permissions` block AND the gitops generator manifest's request
- "Secret is not in 1Password" → premise is the secret's presence at a known path
- "Branch protection blocks force-push" → premise is the protection ruleset on the branch
- "CI gate requires label Z" → premise is the workflow definition

**Step 2 — run the cheapest verification.** The trigger ratio from doctrine 01 applies: `cost(verification) << cost(being wrong about the blocker)`.

| Blocking premise | Verify via |
|---|---|
| GitHub App install scope | `gh api /orgs/<org>/installations` |
| GitHub App permissions | same, then `.permissions` on the install |
| Gitops token-generator scope | read the manifest in the gitops repo |
| Live token introspection | `gh api /` with the suspected token, check `X-OAuth-Scopes` |
| 1Password item presence | `mcp__secret-service__search_secrets` / `get_secret` |
| K8s resource state | ArgoCD resource API or `kubectl get` |
| GitHub branch protection | `gh api /repos/<r>/branches/<b>/protection` |
| Workflow / CI gate config | read `.github/workflows/*.yml` from main |

**Step 3 — only if verification confirms the premise, declare the blocker.** If verification refutes the premise, route back to the diagnosing agent (or your own past output) for re-diagnosis. The actual root cause is somewhere else.

## Peer-agent diagnoses count

The rule applies symmetrically to your own diagnoses and to peer-agent diagnoses you're about to propagate. A peer's confident state-claim is still a point-in-time observation made under their own visibility constraints. Re-verify at the moment of acting on it. No asymmetric exemption for "trusted" peer agents.

If a peer cites specific identifiers (install ID, app ID, secret path, branch name), verify those identifiers actually map to what the diagnosis claims — peer agents in a multi-App / multi-identity environment can conflate similarly-named entities, especially under fatigue or in fast back-and-forth.

## Exceptions

- **Self-blocker on your own runtime state**: when the blocker is "MY tool just returned a 401" / "MY connection just failed", you observed it directly — that's verified already. Apply the rule to the *downstream propagation* (when you're about to tell someone else about it), not to your own immediate observation.
- **Cascading blockers within the same verification chain**: if you've already verified layer 1 and it cleanly refutes the premise, you don't need to verify layers 2+ to refuse the blocker. Verification stops as soon as the blocker is refuted.

## Scope

Cross-agent, cross-tool. Fires anywhere an agent is about to:

- Tell the user "you need to do X to unblock this"
- File a tracking issue or sub-task titled "blocked on X"
- Pause its own work pending external action
- Relay another agent's blocking diagnosis without independently verifying it

This rule operates upstream of doctrine 16 (escalation gradient): step 1 of d16 is "check the API/docs/catalog before escalating" — this rule extends that to "check the API/docs/catalog before *declaring* a blocker at all, regardless of whether escalation is the next step."
