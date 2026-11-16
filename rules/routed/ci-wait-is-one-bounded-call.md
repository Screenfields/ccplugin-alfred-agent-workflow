---
name: ci-wait-is-one-bounded-call
roles: [all]
work: [code]
severity: major
---
A CI wait is one bounded call, `timeout <bound> gh pr checks <number> --watch`, with a bound above the usual CI run time, because a watch without a bound never ends when a check hangs.
