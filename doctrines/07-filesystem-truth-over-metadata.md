---
type: doctrine
status: active
updated: 2026-05-22
description: "Prefer fresh ground-truth queries (stat, kubectl get, git log, gh api) over in-body metadata that may have drifted."
read_when: "When verifying a state claim that could be answered by either stored metadata or a fresh query."
---

# 07. Filesystem/kubectl truth over in-body metadata

## Rule

When verifying a state claim, prefer fresh ground-truth queries over in-body metadata that may have drifted. `stat` beats file frontmatter date. `kubectl get` beats ArgoCD `.status.summary`. `git log` beats commit-message date. `gh api` beats PR-body references.

## Why it exists

In-body metadata (frontmatter, summary fields, env vars baked at deployment, body claims) is a point-in-time observation. The thing it describes can change without the metadata updating. Trusting metadata as-if-it-were-current is exactly the same pattern as trusting a peer's unverified claim — except the deceiver is your own past output, not someone else's.

This doctrine is a specialization of [01-verify-claims-about-state.md](./01-verify-claims-about-state.md) applied to our own outputs. The category of failure is identical: relying on a state claim without re-verifying. The distinction is worth naming because in-body metadata feels authoritative — it's written down, in the artifact, presented as fact — and that feeling defeats the verification instinct. Naming the trap makes it easier to spot.

The 2026-05-22 retro surfaced this in both directions: PM concluded a file was 5 days old based on a body string, when filesystem mtime showed it had just been written; alfred-platform's memory frontmatter `last-updated` field was being treated as current state when it was a point-in-time capture.

## How to apply

- When verifying, explicitly choose ground-truth queries: `stat`, `kubectl get -o yaml`, `git log -1`, `gh api`, ArgoCD `/resource` (live manifest).
- Treat in-body metadata as "this is what someone thought at the time of writing"; not "this is true now".
- The trigger: am I about to act on a date, version, status, or identifier embedded in a document body? If yes, pull the ground-truth equivalent first.
- Responsibility: the agent about to act on the metadata. The author of the metadata isn't responsible for keeping it current after write — readers are responsible for re-verifying.

## Worked examples

**PM's "file dated 5 days ago".** PM looked at a "Drafted 2026-05-14" string in a draft file's body and concluded the file was 5 days stale. `stat` showed the mtime was that morning (file body was pasted from an older draft). PM's claim "this is 5 days old, want to send anyway?" was based on the body string, not on filesystem truth. Takeaway: body strings about dates are author-supplied claims, not filesystem facts.

**alfred-platform memory frontmatter age.** Memory files have a `last-updated` field. Reading the memory at session start treats that date as current state; if the memory was point-in-time captured and the underlying reality drifted, reading it as authoritative misleads. Takeaway: frontmatter is a write-time snapshot, not a current-state assertion.

## Related doctrines

- [01-verify-claims-about-state.md](./01-verify-claims-about-state.md) — 07 is a specialization of 01 applied to our own past outputs. Same principle, more specific surface.
- [05-sweep-open-uses-after-correction.md](./05-sweep-open-uses-after-correction.md) — when ground-truth disagrees with metadata, sweep other uses of the metadata before propagating the correction.

## Cross-side note

Cross-side, symmetric. Both sides have drift-prone metadata sources: memory frontmatter, ArgoCD summary, pod env baked at deploy time, file body dates, PR body references. Same underlying anti-pattern, different artifact surfaces.
