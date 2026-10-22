---
name: author-gitops-pr-never-self-approve
roles: [lead]
work: [operations]
severity: critical
---
A lead authors the GitOps pull request and sends the hub a gate ask with the head SHA, and never approves its own, because the hub gates and merges GitOps.
