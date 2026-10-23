## Repo owner
hub

## Objective
O1, A stable, secure and well-performing platform that measures and publishes its key KPIs, and improves itself based on them (standing)

## Business case
The tooling, checks and baseline for operating the platform.

## Merge rule
The repo owner (hub) merges after a passed fresh-context review (AP-ADR0022, AP-ADR0024).

## Scope
This repo holds the hub's tooling (`scripts/platform-ops/`), the baseline docs that describe what runs on the platform, and the hub's role instructions. It also holds the strategy records (vision, objectives register, ADRs), which Alfred writes and the hub merges after a passed review and the owner's approval. Application code, deployment manifests and per-project material belong in the owning project repo or in alfred-platform-gitops.
