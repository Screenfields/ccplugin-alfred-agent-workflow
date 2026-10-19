---
type: doctrine
status: active
updated: 2026-07-25
description: "Projects whose source repo lives outside the platform's primary org are first-class deployable workloads; existing platform primitives handle them without an org transfer."
read_when: "When onboarding or deploying a project whose repo lives outside the Screenfields org."
---

# 17. External-repo projects are a first-class deployment shape

## Rule

A project whose source repo lives outside the platform's primary org (today: `Screenfields`) is a **first-class deployable workload** on the Alfred platform. No org-extension is required to support it. The platform's existing primitives — per-project `repos[]` field on the PM record, namespace-agnostic image-pull via classic-PAT, gitops manifests in the Screenfields-owned `alfred-platform-gitops` repo — handle the external-repo case by construction.

## Why it exists

External-repo projects come up naturally:

- Personal repos (e.g. `jheuvel/playlist-creator`, `jheuvel/consciousness-project`) deployed on the platform without requiring a transfer to the org
- Forked projects that retain their upstream identity
- Cross-organization collaborations where one side owns the source repo and the other operates the deployment

Without this doctrine, the temptation is to either (a) force-migrate every deployable workload into the primary org (high-friction, sometimes-impossible for personal/shared repos), or (b) extend org-credential infrastructure for each new external org (high cost, scales poorly). Neither is necessary: the platform's existing per-project + namespace-scoped primitives compose to handle external repos without org-level changes.

The pattern was empirically validated by `playlist-creator` (deployed from `jheuvel/playlist-creator` since 2026-03-22; Synced + Healthy on dock + prod throughout) but went undocumented until 2026-06-05, when `consciousness-project` adoption surfaced the need to make the pattern explicit + canonicalize it.

## How to apply

When a new project's source repo is outside Screenfields:

1. **PM record**: set `repos: ["https://github.com/<external-org>/<repo>"]` directly. PM's supervisor derives walk URLs from `repos[0]` (per PM PR #371) — no `orgCredentials` extension needed.

2. **Image namespace**: published under the repo-owner's namespace (e.g. `ghcr.io/<external-org>/<repo>`). Per `docs/baseline/workflows/github-container-registry.md` in `alfred-platform`: image lives where the repo lives.

3. **Pull-secret**: the existing classic PAT at `op://sf-platform/api-github-jheuvel-packages/external/readonly` is user-scoped and covers any namespace its owner can read. Mounted as `ghcr-secret` per-namespace via standard ESO + manifest patterns.

4. **Gitops manifests**: lived under `alfred-platform-gitops/apps/<project>/{base,dock,prod}/` regardless of source-repo namespace. Same shape as Screenfields-source projects.

5. **CI side**: the workflow uses the automatic `GITHUB_TOKEN` provided by GitHub Actions in the external repo. No PAT needed for push (image-publish runs in the source repo's own workflows).

## What this doctrine is NOT

- **Not "support arbitrary orgs as managed orgs."** No PM-side `orgCredentials` extension is required or recommended. The `repos[]` field on the project record carries the source location; that's sufficient.
- **Not a recommendation to keep things external.** If transfer to Screenfields is operationally cheap and politically fine, that's also valid. The doctrine just says external is structurally OK.
- **Not a license to skip platform conventions.** External-repo projects follow the same gitops shape, deployment lifecycle, naming conventions, and review discipline as Screenfields-source projects. The only thing that's relaxed is the source-namespace assumption.

## Worked examples

**playlist-creator** (precedent, since 2026-03-22). Source: `jheuvel/playlist-creator`. Image: `ghcr.io/jheuvel/playlist-creator-backend`. Gitops: `alfred-platform-gitops/apps/playlist-creator/`. Pull-secret: `ghcr-secret` mounted from `op://sf-platform/api-github-jheuvel-packages/external/readonly`. ArgoCD apps `playlist-creator-dock` + `playlist-creator-prod`: Synced + Healthy throughout. PM record was historically misregistered with `Screenfields/playlist-creator` URL; corrected as part of canonicalizing this doctrine 2026-06-05.

**consciousness-project** (adoption 2026-06-05). Source: `jheuvel/consciousness-project`. zeus-codex is the operator-class lead building the web-app for it. PM record adopted directly with the external URL after PM PR #371 (`getRepoPath()` helper) landed. Image will publish at `ghcr.io/jheuvel/consciousness-project`. Same gitops + pull-secret pattern as playlist-creator.

## Related references

- **PM PR #371** — `getRepoPath()` helper deriving walk URL from `project.repos[0]`, enabling external-org support without `orgCredentials` extension. The worked-example evidence for the doctrine.
- **`alfred-platform/docs/baseline/workflows/github-container-registry.md`** — image-namespace + classic-PAT + per-namespace `ghcr-secret` pattern. The pull-secret mechanism that makes cross-namespace pull tractable.
- **ADR-0007** (alfred-platform-docs) — project-manager-single-canonical-with-dev-sandbox. Classifies playlist-creator as a sandbox project record (i.e. not load-bearing for production project lifecycle) — historically reflected the misregistration, now obsolete given the record is being corrected.

## Cross-side note

Symmetric: a project does not become "more Screenfields-y" by being a managed deployment. The deployment substrate is Screenfields-owned; the source repo remains in its native namespace. PM, supervisor, gh-aw, agent-messaging, and the rest of the substrate are all repo-namespace-agnostic by construction.
