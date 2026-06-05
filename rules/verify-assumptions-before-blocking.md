---
name: verify-assumptions-before-blocking
description: "Before declaring a blocker — escalating to user, filing a tracking issue, halting your own work, or relaying a peer's diagnosis — verify the blocking premise via the cheapest state-check available."
---

## The rule

**Verify the blocking premise before declaring it.**

False-positive blockers propagate widely: the user takes wrong action, peers reshape plans, follow-up work is scoped around the wrong ceiling. Verification is non-optional for blocker-class claims.

Applies symmetrically to your own diagnoses and to peer-agent diagnoses you're about to relay. No exemption for trusted peers — verify their cited identifiers (App IDs, install IDs, secret paths) before propagating.

## How

Run the cheapest state-check that confirms or refutes the premise:

| Premise | Verify with |
|---|---|
| GitHub App install scope / permissions | `gh api /orgs/<org>/installations` |
| Live token scope | `gh api /` with the token, check `X-OAuth-Scopes` header |
| Gitops token-generator request | read the manifest in the gitops repo |
| Secret presence | `mcp__secret-service__search_secrets` or `get_secret` |
| K8s resource state | ArgoCD resource API or `kubectl get` |
| Branch protection / CI gate | `gh api .../branches/.../protection` or read the workflow file |

Verified → declare. Refuted → re-diagnose; route back to the source agent.

Composes with d01 (verify-claims-about-state, broader) and d16 (escalation-gradient, applies AFTER blocker is verified real).
