---
name: long-commands-wait-by-notification-only
roles: [worker]
work: [code]
severity: major
---
A long command (test suite, build, render) is started once under `timeout` with a bound above its expected run time, and its exit notification is the only wait, with no polling of any kind such as `pgrep`, a `sleep` or `until` loop, a log tail, a file poll or a second waiter, because every waiter outlives the work it watches.
