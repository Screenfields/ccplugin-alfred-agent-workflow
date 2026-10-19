---
type: doctrine
status: active
updated: 2026-06-02
description: "Operate at the right level: the platform-architecture layer coordinates, specialized projects are autonomous peers, and mechanical multi-step work delegates to worker subagents with isolated context."
read_when: "When deciding whether to do work inline, delegate to a worker, or route to a peer project."
---

# 06. Lead-agent / worker-agent pattern

## Rule

Operate at the right level. alfred-platform is the platform-architecture layer (cross-cutting concerns, roadmap, architectural decisions). Specialized projects are autonomous peers with their own roadmaps and backlogs. Mechanical multi-step work within a session delegates to worker subagents (Agent tool) with isolated context.

## Why it exists

Lead-in-the-weeds is the dominant failure mode. When the lead personally edits configs, debugs IP conflicts, composes commits inline, it stops doing coordination — and that's when scope-creep, premise-acceptance, and derail happen. Workers absorb the mechanical work; the lead retains the helicopter view.

There's also a technical payoff: worker context is isolated from the lead's. Only the brief in and summary out enter the lead's context, which keeps the lead's cache warm and compaction-risk down. A lead that personally executes 30 tool calls in a debugging session loses context budget that should have been reserved for synthesis.

The 2026-05-22 retro made the L1/L2 distinction explicit. L1 is system-level: alfred-platform as architectural layer, specialized agents as autonomous peers. L2 is within-session: lead delegates to workers via the Agent tool. The two levels have different mechanisms (issues + messages at L1; Agent tool at L2) but share the same underlying principle: the lead does coordination, not mechanical work.

## How to apply

**L1 (system level):**
- alfred-platform = architectural layer; specialized project-agents (PM, alfred-cc-tools, platform-routing, litellm, cluster-ops, alfred-platform-docs) = autonomous peers.
- Coordination is lightweight (issues, agent-messaging). No workflow orchestration.
- alfred-platform stays at L1 — does NOT do L2 specialized deep work; that goes to the relevant spoke.

**L2 (within a session):**
- Each project's lead-agent delegates mechanical work to worker subagents via the Agent tool.
- Spawn a worker when ALL of: task >3 tool calls, brief writable in 3-5 sentences, output shape known before starting, no mid-stream decisions.
- Don't spawn for: single-step tasks, exploratory work where surface area changes the conclusion, decisions requiring user input, cross-agent coordination.
- **Retro-time diagnostic**: if you find yourself making 5+ sequential mechanical tool calls with no decisions in between, that's a signal the cluster could have been a worker brief. Not a runtime trigger (counting beats judging at trigger-time), but a self-audit signal afterward.
- **Concrete formulation**: workers author PRs (and any multi-step bounded mechanical work); lead reviews and merges. The lead's responsibility is the brief in + decision out (synthesize worker output → merge or revise). "Workers create PRs, lead merges" is the most common application of this pattern in practice — when in doubt about whether something is worker-fit, ask: "could I write a worker brief whose output is 'open this PR, don't merge'?"

**Worker identity:**
- Workers have no agent-messaging identity. Only the lead communicates cross-agent.
- The lead synthesises the worker's summary back into the conversation; the worker's intermediate reasoning doesn't propagate.

## Worked examples

**dnsmasq + SKILL.md + inventory work.** alfred-platform spent ~30-40 inline tool calls editing dnsmasq config, debugging the 127.0.0.54 conflict, writing SKILL.md edits, composing commits, updating inventory doc. Done as 3 worker briefs (one per concern: setup, SKILL.md, inventory), the lead-context cost would have been ~1.5K tokens (briefs in + summaries out) instead of ~15-30K (every tool output in context). The lead would have stayed at coordination level instead of dropping into bash debugging. Takeaway: multi-step mechanical work with a known output shape is a worker job, not a lead job.

**Item 10 reframe (L1 topology).** User surfaced: "Alfred platform can send requests to individual projects, but also the individual projects will have their own lifecycle and just follow their own roadmap. Platform will look at the bigger picture for the Platform as a whole." This reframe changed the L1 topology from "hub orchestrates all" to "architectural layer + autonomous peers". Communication is lightweight delegation (issues + messages), not workflow orchestration. Takeaway: at L1, the lead's role is architectural, not operational; spokes own their own roadmaps.

**Token-scope-fix PR done inline (2026-05-22, post-doctrine commit).** alfred-platform agent fixed the alfred-cc-tools token-scope issue by editing 2 files in alfred-projects-gitops (`github-token-generator-readonly.yaml` + `-lead.yaml`), committing, pushing, opening PR, merging. ~10 inline tool calls. The brief was writable in 3 sentences with no mid-stream decisions ("add alfred-platform-docs to repositories list in these 2 files; commit with this message style; open + merge PR"). Output shape was known before starting (PR merged, 2-line diff). Strictly worker-fit per the trigger conditions, but I did it inline because it "felt small." The 5+ sequential mechanical calls retro-diagnostic catches exactly this pattern: medium-sized actions that don't trigger the "big work" instinct but still meet worker-fit criteria. Takeaway: the worker-fit calibration is "predictable + multi-step + no mid-stream decisions", not "feels big enough to delegate." The 5+ calls retro-diagnostic surfaces medium-sized work that the "feels big" instinct misses.

**Under-delegation despite knowing the doctrine (2026-06-01 PM session).** PM the lead spawned **1 worker subagent** across a full-day session while making **715 direct tool calls**. Eighteen PRs shipped across the project in that span; none of the eighteen routed mechanical work through workers. The doctrine had been read, internalised, and cited in conversation that same day. The failure was not knowledge.

The clearest in-session miss was the lead-roles catalog at `alfred-platform-docs/architecture/lead-roles/`. Six of eight entries needed filling against a known schema (role / owned_apps / owned_repos / cross_lead_edges / etc.). Bulk drafting against a fixed output shape is the exact criterion doctrine 10 names for worker-fit: brief writable in 3-5 sentences, output shape known before starting, synthesis (the schema's structure, the cross-edge calls) already settled. PM wrote all eight entries inline. The work was canonically worker-fit and was done direct anyway.

User correction, mid-session, verbatim: *"Communication SHOULD be the main role for the lead. The fact that they're getting clogged up is that they are not using sub-agents most effectively."* The diagnosis names the mechanism — the lead's coordination bandwidth degrades in proportion to its direct-execution load — and inverts the default. Communication is not a distraction from the lead's "real work"; communication *is* the lead's work, and direct execution that crowds it out is the failure.

The inversion held the same session. After the correction, subsequent multi-source work — rules-mechanics research, memory-file audit, alfred-platform-side inventory — fanned out across 3-4 parallel workers with PM synthesising results inline. Same lead, same doctrine, same day; the only change was the structural default flipping from "do it myself unless the work is heavy" to "delegate unless the work is trivial." With the new default load-bearing, the 1:715 ratio reversed within hours. Takeaway: knowing the lead-worker pattern is not sufficient — the default has to be flipped at the action layer, or the lead silently reverts to direct execution and the ratio stays inverted until someone counts.

One adjacent trap worth naming: doctrine 10's "synthesis stays with the lead" is sometimes misread as license to do everything inline ("if I can't delegate the synthesis, I might as well do the whole thing"). Doctrine 10 prohibits delegating *synthesis*, not delegating *exploration*. The catalog-fill above is exactly that misread in action — the schema-settled rows were exploration-shaped (mechanical fill against known structure), not synthesis-shaped, and were delegate-fit on doctrine 10's own terms.

## Related doctrines

- All others — the lead/worker pattern is how the other doctrines get enforced. Workers carry the briefs that include doctrine adherence; leads do the synthesis + scope decisions.
- [02-scope-discipline.md](./02-scope-discipline.md) — lead-level filtering happens at the coordination layer; this is exactly the work the lead must NOT delegate.
- [10-delegate-execution-not-synthesis.md](./10-delegate-execution-not-synthesis.md) — the boundary refinement. The 2026-06-01 under-delegation example is the lead-side mirror of doctrine 10's worker-side failure modes, and the "synthesis-stays-with-lead = do everything inline" misread named in that example is the most common way doctrine 10 gets folded into a justification for direct execution.
- [AP-ADR0015](../adr/AP-ADR0015-hub-operator-gatekeeper-critical-change-protocol.md) — hardens the platform-repo edge of this doctrine into a rule: the hub (alfred-platform) does not build on `alfred-platform`/`alfred-platform-gitops` at all, only coordinates/gates; leads build, a review sub-agent reviews, the hub merges or rejects. Direct response to the 2026-10-01 single-actor RCA ([#939](https://github.com/Screenfields/alfred-platform/issues/939)).

## Cross-side note

Cross-side, structural. alfred-platform is the L1 architectural layer (singular role). Each project-agent (PM, alfred-cc-tools, future spokes) is an autonomous peer at L1 and runs its own L2 worker pattern within sessions. alfred-platform stays at L1 — does NOT do L2 specialized deep work; that goes to the relevant spoke.
