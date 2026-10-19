---
type: doctrine
status: active
updated: 2026-05-22
description: "After any correction, sweep the session for analogous uses of the same pattern — one correction is incomplete until applied to siblings."
read_when: "Immediately after receiving or discovering a correction."
---

# 05. Sweep open uses after correction

## Rule

After any correction (from user, peer, or self-discovered), sweep this session for analogous uses of the same pattern. One correction is incomplete until applied to siblings.

## Why it exists

The same anti-pattern often appears in multiple places in the same session. Fixing only the instance the corrector pointed at leaves the analogs unaddressed; they surface as the next correction (or worse, as silent drift that surfaces hours or days later). The discipline is to proactively scan for siblings rather than wait for the next correction.

The cost of not sweeping is visible in the 2026-05-22 retro: the same `.net` vs `.dev` confusion happened three hours apart in the same session, because the first correction was applied as a point fix rather than triggering a sweep. The second instance was identical in shape and could have been prevented by 30 seconds of grep at the time of the first correction.

The CLAUDE.md Correction Protocol already has acknowledge → ask-if-pattern → apply-correction. This doctrine adds the missing fourth step: SWEEP.

## How to apply

- When a correction lands, treat it as triggering a sweep, not just a point fix.
- Grep this session (file edits, messages, draft PR bodies, in-flight tool calls) for analogous patterns.
- Apply the same fix to siblings before continuing forward work.
- The sweep is cheap (one grep, a few minutes); the next correction is expensive (context-switch, lost momentum, possible silent drift in the interim).
- Responsibility: the agent receiving the correction. The corrector doesn't need to re-identify each sibling.

## Worked examples

**PM's `.net`/`.dev` mistake — repeated 3h apart.** PM was corrected on a `.net` vs `.dev` confusion. Three hours later in the same session, PM made the exact same mistake on a different hostname. Root cause: didn't sweep open `.net` usages after the first correction; treated it as a point fix. Takeaway: the second instance was preventable by 30s of grep at correction time.

**alfred-platform CF-tokens-on-argocd.** After setting up the dnsmasq bridge to route `litellm.screenfields.net` internally (no CF Access needed), alfred-platform continued using CF Access tokens for `argocd.screenfields.dev` ArgoCD API calls in the same session. User spotted it: "I noticed you're still using the Cloudflare service tokens. Why?" Same anti-pattern: didn't sweep callsites after the dnsmasq change made an alternative available. Takeaway: when a capability change lands (new routing, new identity, new gate), sweep callsites that were working around the old constraint.

## Related doctrines

- [01-verify-claims-about-state.md](./01-verify-claims-about-state.md) — same verification axis, different timing: 01 fires before acting, 05 fires after being corrected.
- [03-namespace-disambiguation.md](./03-namespace-disambiguation.md) — when a naming collision is surfaced, the sweep is the way the prefix gets back-applied to open uses.

## Cross-side note

Cross-side, symmetric. Both sides bit by the same pattern in the same session — PM on hostname suffixes, alfred-platform on auth-token callsites. Same doctrine, different artifact types.
