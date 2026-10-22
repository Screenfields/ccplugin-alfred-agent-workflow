---
name: parallel-only-when-independent
roles: [all]
work: [code, operations]
severity: critical
---
Work runs in parallel only when independent; deployments to one environment, migrations and dependent steps run in series, because they interfere.
