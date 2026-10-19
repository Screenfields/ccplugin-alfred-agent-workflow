---
type: doctrine
status: active
updated: 2026-08-13
description: "Every diagnostic that creates state declares its cleanup as part of the same sequence; intentionally persistent state is an explicit commit decision. Includes the test-repo end-of-life policy."
read_when: "Before running a diagnostic that creates cluster resources, host config, scaffolded repos, or /tmp files."
---

# 09. Diagnostic experiments declare cleanup contracts upfront

## Rule

Every diagnostic that creates state (Kubernetes resources, persistent host config, scaffolded GitHub repos, /tmp files outliving the session) declares its cleanup as part of the same sequence — not as a separate later pass. If state is intentionally persistent (new IaC), that's an explicit commit decision, not a side-effect.

## Why it exists

State from diagnostics tends to accumulate silently, become drift sources, and require cleanup passes that are forgotten or done partially. Same-sequence cleanup is the only way to keep "state created" and "state tracked" at 1:1 ratio.

The accumulation is cheap per-incident and expensive in aggregate. PM's `pmtest-*` projects accumulated dozens of orphans over weeks because each diagnostic run left 1-3 if it exited early; the cleanup pass took multiple days when finally tackled. The host-local dnsmasq config on dev-server is a different shape of the same anti-pattern: state created during a diagnostic, intended-but-not-promised to become persistent, sitting outside IaC where a host rebuild would lose it.

The discipline is to declare the teardown before starting, bundle it into the diagnostic itself, and treat "persistent" as an explicit commit decision (with IaC reference) rather than a side-effect of "I didn't get around to cleanup".

## How to apply

- Before starting a diagnostic, declare what state will be created + what the teardown is.
- Bundle teardown in the same script (trap handlers, finally blocks, explicit cleanup steps after the assertion).
- For persistent infrastructure that should outlive the diagnostic: explicitly commit it to IaC + reference the IaC path in the diagnostic write-up. Don't leave bare host-local config as the contract.
- The trigger: am I about to create state (K8s resource, host file, scaffolded repo, persistent service) as part of a diagnostic? If yes, write the teardown first.
- Responsibility: the agent creating the state. Other agents are not responsible for cleaning up your diagnostic state.

## Worked examples

**PM's orphan `pmtest-*` projects.** Each diagnostic run that scaffolded test projects left 1-3 orphan scaffolds in PM's DB if the diagnostic exited early or timed out. Over weeks: dozens of orphans accumulated. Cleanup was a multi-day pass through PM API + GitHub repo deletes. Could have been zero-cost if every diagnostic script declared its teardown as part of the same execution. Takeaway: per-incident accumulation is cheap; aggregate is expensive — same-sequence teardown is the only way to keep the ratio at 1:1.

**alfred-platform host-local dnsmasq.** During Phase 4 ECR consumer cleanup, alfred-platform set up dnsmasq + systemd-resolved overrides on dev-server to bridge `litellm.screenfields.net` to the prod Traefik via Tailscale. Lives in `/etc/dnsmasq.d/internal-routing.conf` + `/etc/systemd/resolved.conf.d/internal-routing.conf`. NOT IaC-tracked. If dev-server is rebuilt, this configuration is lost; same diagnostic would need to be redone. The cleanup contract was implicit (the comment in the file points to alfred-platform#362) but not enforced as IaC. Takeaway: "persistent" is an explicit commit decision; bare host-local config is not a contract.

**Test-repo end-of-life policy (agreed alfred-platform × project-manager, 2026-08-13).**
Authoritative copy of the standing policy for test-pattern repos in the
screenfields-tests org (`pmtest--*` and successors):

- Teardown of a test repo belongs to the same run that created it (the rule
  above). A run that fails or times out before teardown leaks its repo — three
  such leaks accumulated over 2026-05..07.
- **Safety net:** an age/prefix sweep owns cleanup regardless of the creating
  run's fate (PM#708). Sweeps must not depend on the run that leaked.
- **Archived test repos older than 30 days are deleted.** Archiving is a
  transition state, not an end state — 12 archived `pmtest--*` repos sat for
  three months before the 2026-08-13 cleanup.
- Deletions run under the test-runner app identity (`delete_repo` on the tests
  org). PM's e2e docs point here rather than duplicating the policy.

## Related doctrines

- [08-pr-scope-discipline.md](./08-pr-scope-discipline.md) — both about not letting work bleed beyond its intended boundary. PR scope discipline keeps code changes contained; cleanup contract keeps state changes contained.
- [01-verify-claims-about-state.md](./01-verify-claims-about-state.md) — verify state before assuming a diagnostic cleaned up; orphans accumulate when assumption replaces verification.

## Cross-side note

Cross-side, with different shapes. PM creates K8s state (pmtest projects); alfred-platform creates host-local config (dnsmasq, /etc/hosts) — same underlying anti-pattern, different artifact types. The cure (declare teardown upfront, promote to IaC if persistent) is the same.
