# ADR-002: ArgoCD for GitOps

## Status
Accepted

## Context
We needed a deployment mechanism that treats Git as the source of truth.

## Decision
ArgoCD with App-of-Apps pattern. Dev environment auto-syncs, prod requires manual approval.

## Alternatives considered
- **GitHub Actions only** — simpler, no extra tooling. Rejected because it has no drift detection. A manual kubectl change would silently persist with no reconciliation.
- **Flux** — similar GitOps tool. Rejected because ArgoCD has a visual UI which is valuable for demo and debugging. Flux is CLI-only.

## Consequences
- ArgoCD runs in cluster consuming ~500Mi memory
- Git revert is the rollback mechanism — clean and auditable
- Drift is detected and corrected automatically