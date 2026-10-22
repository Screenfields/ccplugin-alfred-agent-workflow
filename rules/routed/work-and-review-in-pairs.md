---
name: work-and-review-in-pairs
roles: [lead]
work: [code, design, work item]
severity: major
---
Every output that changes a work item's state is worked and reviewed in a pair: the starting session briefs the author, the author hands back its output, and the starting session sends it to the paired reviewer, a fresh subagent; on a fail the findings go back to the same author and the fix to the same reviewer, until the reviewer passes it on the acceptance criteria, and after failed-review-max failed rounds the starting session stops and escalates. Every state change passes a review (AP-ADR0022); a small item skips designed and gets the lighter reviewer setting. The starting session runs the loop because workers never delegate and talk only to the session that started them, and the pair stays the same because the author keeps its context for the fix and the reviewer checks against its own findings.
