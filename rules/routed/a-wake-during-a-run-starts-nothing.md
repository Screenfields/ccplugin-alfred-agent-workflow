---
name: a-wake-during-a-run-starts-nothing
roles: [worker]
work: [code]
severity: major
---
A notification or message that arrives before the exit notification of a long command started earlier starts nothing and ends the turn, with only a re-run after a fix and after the earlier run has ended counting as a new run, because a waiter started on each arrival multiplies the waiters on one process.
