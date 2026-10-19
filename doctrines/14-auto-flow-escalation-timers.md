---
type: doctrine
status: active
updated: 2026-05-27
description: "Documented completion windows and per-flow escalation actions for automated platform flows (Image Updater, ArgoCD sync, ESO refresh, ...) so leads trust the flow during the window and escalate only at the threshold."
read_when: "When an automated platform flow seems slow and you're deciding whether to wait, force, or escalate."
---

# 14. Auto-flow escalation timers

## Rule

When an automated platform flow is expected to complete within a documented window, agents trust the flow during the window and escalate only at the documented threshold. The escalation action is specific per flow.

This doctrine documents the windows + escalation actions so spoke leads can self-drive without pinging alfred-platform-hub on every auto-flow execution.

## Why it exists

The 2026-05-26 team retro flagged this gap from three independent angles: alfred-agent-messaging assumed 5 min for Image Updater but said it was undocumented; alfred-cc-tools wanted the wave-2 drain-check pattern formalized; project-manager proposed the per-flow threshold shape. The autonomy contract per [AP-ADR0003](../adr/AP-ADR0003-platform-hub-outside-cluster.md) depends on spoke leads knowing when an auto-flow is operating normally vs stuck — without documented windows, every release becomes a "should I ping alfred-platform yet?" judgment call, eroding the autonomy contract.

## Per-flow windows

Source-of-truth column links to the canonical config per the non-duplication rule in [documentation-strategy.md](../architecture/documentation-strategy.md); this table summarises for escalation purposes only.

| Flow | Expected window | Source of truth | Action if exceeded |
|---|---|---|---|
| Image Updater → kustomization write | ~2-3 min (poll interval ~2m; write + push <1m) | `infrastructure/argocd-image-updater/dock/image-updater-cr.yaml` + `alfred-platform/docs/baseline/services/argocd.md` § Image Updater | At 5 min: check Image Updater controller logs via ArgoCD API. At 15 min: ping alfred-platform-hub. |
| ArgoCD sync (gitops → cluster) | ~3 min (default reconcile interval) | `helm-values/argocd-dock-values.yaml` + `argocd.md` § Sync polling | At 5 min: hard-refresh via ArgoCD API (`PATCH /api/v1/applications/{name}` with `argocd.argoproj.io/refresh: hard`). At 15 min: ping alfred-platform-hub. |
| ArgoCD AppSet reconcile (generator-side) | ~3 min default; preview AppSet 60s | AppSet `requeueAfterSeconds` field per resource | At 5 min: check AppSet `.status.conditions[]` for `ErrorOccurred` — single invalid generated resource freezes the entire AppSet. |
| ExternalSecret refresh (1Password → K8s secret) | Per-ExternalSecret `refreshInterval` (common: 1m / 1h / 24h) | The ExternalSecret resource itself | At 2× interval: restart `external-secrets-operator` pod via ArgoCD API. At 4× interval: ping alfred-platform-hub. |
| Cert-manager renewal (LE → secret) | ~30 days before cert expiry; renewal itself <5 min | cert-manager Certificate resource + `argocd.md` cert-manager section | At cert <14 days from expiry without renewal: ping alfred-platform-hub. |
| GitHub App token refresh (in-pod) | Token TTL 1h; ExternalSecret + GithubAccessToken generator re-mints | Per-spoke `github-token-generator-*.yaml` + ExternalSecret `refreshInterval` | If 401 after secret refresh window: check App permissions via UI; ping alfred-platform-hub. |
| Pod-restart drain (session-disrupting op) | See doctrine 15 (drain-before-disrupt) — gated, not timer-driven | [15-drain-before-disrupt.md](./15-drain-before-disrupt.md) | N/A — see doctrine 15 |

## How to apply

- Before pinging alfred-platform-hub about a stuck auto-flow: check the table above; confirm the threshold has actually been exceeded
- For exceeded thresholds: try the documented mitigation first (refresh, restart pod, hard-sync) before escalating
- For brand-new flows not in this table: file an alfred-platform issue to add them; pre-existing patterns (e.g., new MCP-tool registration cycle) likely fit one of the rows

## Worked example

**alfred-agent-messaging v0.1.2 prod deploy (2026-05-26).** Lead asked alfred-platform-hub to force-sync after cutting the release. Per this doctrine: lead should have observed Image Updater (~2-3 min) → ArgoCD sync (~3 min) → pod rollout (~1 min). Total ~7-10 min. Escalation at 15 min if the prod kustomization pin hadn't moved. The force-sync was unnecessary; the auto-flow had it. The user correction ("why are you doing it and not alfred-agent-messaging?") is captured as the doctrine's motivating incident.

## Related doctrines

- [03-namespace-disambiguation.md](./03-namespace-disambiguation.md) — flow names overlap across systems; prefix with system+context when ambiguous
- [07-filesystem-truth-over-metadata.md](./07-filesystem-truth-over-metadata.md) — verify the actual cluster state (ArgoCD API, kubectl) before declaring a flow stuck
- [15-drain-before-disrupt.md](./15-drain-before-disrupt.md) — companion doctrine for session-disrupting ops (gated, not timer-driven)

## Maintenance

When an interval changes (new ArgoCD version, new ExternalSecret default, new App token TTL), update this doctrine in the same PR that changes the config. The source-of-truth column points at the canonical configuration; this table is a summary for escalation purposes, not a duplicate authority.
