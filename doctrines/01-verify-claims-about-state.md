---
type: doctrine
status: active
updated: 2026-05-22
description: "Claims about state that can be verified must be verified before propagating, acting on, or designing on top of them — applies to own past outputs and peer-agent assertions alike."
read_when: "Before relying on an unverified claim about live state — from a peer agent, a prior session, or your own earlier output."
---

# 01. Verify claims about live cluster state

## Rule

Claims about state that are not certain but can be verified should be verified — before propagating in a reply, before acting on them, before designing on top of them. This applies symmetrically to your own past outputs and to peer-agent assertions.

## Why it exists

Both peer-agent assertions and our own past outputs drift from reality. A claim that was true at write-time is not necessarily true at read-time, and a peer-agent's confident statement is still a point-in-time observation made under their own visibility constraints. Verification at the moment of relying on a claim catches drift cheaply; not verifying lets stale claims accumulate into wrong-direction work.

The trigger ratio is the same one from `empirical-verification.md`: `cost(verification) << cost(being wrong about the commitment)`. A 30-second `kubectl get` or `gh api` call is almost always cheaper than a 3-hour wrong-direction implementation.

The originating user correction (2026-05-21/22 retro) surfaced two distinct shapes of this failure in a single session: trusting a peer's hostname-based claim on faith, and designing a new component when an existing one already covered the role. Both would have been caught by a single verification step at the boundary of acting.

## How to apply

- Fires whenever you're about to act on, propagate, or design against a state claim that wasn't verified by you in the current session.
- The concrete action: run the cheapest ground-truth query (kubectl, gh api, ArgoCD API, stat, git log) that confirms or refutes the claim. Then act.
- Responsibility: the agent about to rely on the claim. Sender of a claim re-verifies before sending; receiver re-verifies before acting. No asymmetric exemption for "trusted" peer agents.
- Don't verify what you don't need to act on — this is not "verify everything"; it's "verify the load-bearing claims before they bear load".
- When the state being verified has multiple structural layers (e.g., App install scope + gitops manifest scope + live token state), walk all the layers — a PASS at one layer doesn't preclude FAIL at a subsequent one.

## Worked examples

**PM "live PM at 296c774".** PM asked alfred-platform to bump the PM-deployment image, claiming the live pod was at SHA `296c774`. alfred-platform almost did it on faith; instead walked the chain (Image Updater state → kustomization.yaml → ArgoCD `.status.summary.images` → pod manifest), discovered Image Updater had already updated to `sha-099a07b` over 3 hours earlier. PM's claim came from curling `.net` (prod) instead of `.dev` (dock). Takeaway: peer claims about live state get re-verified at the boundary of acting, even when the peer is credible.

**alfred-platform missing alfred-lead-agent.** When designing the spoke gitops auth model, alfred-platform proposed a new GitHub App without first verifying which Apps already exist in the Screenfields org. A sweep caught it: `alfred-lead-agent` already existed for exactly this role. The whole "Option A new App" framing was based on incomplete state info that one `gh api` call would have surfaced. Takeaway: design proposals are state claims too — verify the state before designing on top of it.

**alfred-cc-tools access to alfred-platform-docs — multi-layer verification missed.** alfred-cc-tools reported a 404 when their App token tried to read `Screenfields/alfred-platform-docs`. alfred-platform verified ONE layer of the access chain — `gh api repos/...` from `alfred-platform-manager` succeeded, and `repository_selection: "all"` was confirmed on `alfred-lead-agent` (the App alfred-cc-tools uses) — and concluded the issue must be a UI grant gap. Asked the user to grant install access in the GitHub UI.

The user pushed back: alfred-lead-agent already has access to all repos. Re-verifying surfaced the actual gap: the gitops token-generator manifests in `apps/alfred-cc-tools-devbox/dock/github-token-generator-*.yaml` explicitly scope minted tokens to just 3 constellation repos, excluding alfred-platform-docs. Even with App-level "All repositories" install scope, the actual minted tokens were narrower because the gitops manifest defines the per-token scope. The verification chain has multiple layers (App install → gitops generator scope → minted token); checking ONE layer (App install) and stopping doesn't catch failures at other layers. Takeaway: multi-layer state has multi-layer verification. When a verification chain has known layers (App install scope → gitops manifest scope → live token state), check ALL applicable layers, not just the first one that looks clean. A clean PASS at layer 1 doesn't preclude failures at layer 2+.

**Layered access chain — App permission vs gitops generator request (2026-05-22 PM + alfred-cc-tools incidents).** After granting `workflows: write` to `alfred-lead-agent` App, both PM agent and alfred-cc-tools agent remained blocked from pushing workflow files. Verifying ONLY the App-level permission (Layer 1) showed "✓ alfred-lead-agent has workflows: write" — looked clean. But minted tokens didn't carry the permission, because the gitops manifest layer wasn't aligned:

- **PM**: the default token-generator manifest requested `packages: read` (inherited from a prior alfred-worker-agent setup). alfred-lead-agent App doesn't have `packages` permission → GitHub rejected token-mint → ExternalSecret reported `SecretSyncedError` → Secret never materialized → pod mount stayed stale → push still refused with the same `workflows` permission error.
- **alfred-cc-tools**: the lead-role token-generator manifest didn't list `workflows: write` in its permissions block. Token-mint succeeded, but the minted token didn't carry the workflow permission (generators only request what the manifest lists) → push rejected with the same error.

Both incidents shared a structure: the token is the AND of (what the App has) AND (what the manifest requests). Verifying only the App ceiling gives a false positive. The gitops generator layer is its own state with its own failure mode (over-requesting = mint rejection; under-requesting = silently narrower token). Takeaway: multi-layer state has multi-layer verification. Walk ALL the layers (App permission set, gitops generator manifest, live token introspection). One PASS at the ceiling doesn't preclude FAIL at a request layer below.

## Related doctrines

- [05-sweep-open-uses-after-correction.md](./05-sweep-open-uses-after-correction.md) — same verification axis, different timing: 01 is before-acting, 05 is after-being-corrected.
- [06-lead-worker-pattern.md](./06-lead-worker-pattern.md) — the verify-access skill candidate (D6 in alfred-cc-tools backlog) is doctrine 01 enforcement as structured tooling: it walks the App-permission → gitops-generator-manifest → live-token chain mechanically. Both 2026-05-22 layered-access incidents (PM + alfred-cc-tools) would have surfaced at Layer 2 via that skill instead of relying on the lead-agent's own diagnostic walk.
- [07-filesystem-truth-over-metadata.md](./07-filesystem-truth-over-metadata.md) — 07 is a specialization of 01 applied to our own outputs (frontmatter, summary fields, baked env vars).

## Cross-side note

Symmetric. Sender of a claim re-verifies before sending; receiver re-verifies before acting. No asymmetric exemption for "trusted" peer agents — the alfred-platform-side and project-manager-side both bit by this in the same session, in both directions.
