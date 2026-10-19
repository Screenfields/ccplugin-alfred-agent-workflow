---
type: doctrine
status: active
updated: 2026-06-10
description: "When component A depends on component B honoring a contract, A must mechanically validate the contract at its own boundary — written instructions are documentation, never enforcement."
read_when: "When wiring components together across a contract (env names, CLI flags, section headers, model strings, token scopes)."
---

# Doctrine 18 — Never instruct what you can verify

**Status:** Adopted 2026-06-10 (team retro, Jochem-approved). Origin: the M3' ship-#1 incident series — ten consecutive defects, every one a masked interface.

## Rule

When component A depends on component B honoring a contract (env names, CLI flags, section headers, model strings, token scopes, body fields), A must **mechanically validate** the contract at its own boundary. Written instructions — in specs, prompts, comments, or PR bodies — are documentation, never enforcement.

## Why

On 2026-06-09/10 the autonomous-worker loop failed ten times before its first success. Census: declared-but-unimplemented CLI flags, an env name nothing set, case-exact matching against a differently-cased contract, an unloaded auth token, an invalid model string copied from the spec into three components, missing token scopes, a permissions flag nobody granted, and a close-reference nobody wrote. **All ten were instructed somewhere and verified nowhere.** Each was invisible until its layer first executed in the real environment, and each fix was small — the architecture was sound; only the unverified seams lied.

## How to apply

- New cross-component interface ⇒ the consumer validates inputs fail-closed and logs what it received (the wrapper's `gh_token_loaded`/`gh_token_missing` events are the reference shape).
- Reviewing a PR that *instructs* another component ("the runtime must write X") ⇒ ask where X is mechanically checked; absent check = request changes.
- A "both sides agree informally" contract (branch names, attempt counters) ⇒ one owner, one join key, validated at use (see the headRef-prefix matcher outcome, PM#440).
- Sibling: the enablement **placeholder gate** — enablement PRs grep the enabled code path for placeholder/PoC markers before first contact.

## Worked examples

autonomous-worker#5/#6/#7/#8/#10/#11, PM#435/#436/#440, gitops#224 — one incident series, ten instances, one fix shape.
