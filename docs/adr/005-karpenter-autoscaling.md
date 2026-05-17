# ADR-005: Karpenter for node autoscaling

## Status
Accepted

## Context
The cluster needs to scale nodes up when pods are pending and down when idle to control costs.

## Decision
Karpenter with on-demand t3.small/medium nodes. Spot rejected.

## Alternatives considered
- **Cluster Autoscaler** — the original K8s autoscaler, works with managed node groups. Rejected because Karpenter is faster (seconds vs minutes), more flexible (any instance type), and supports consolidation which Cluster Autoscaler does not.
- **Spot instances** — 70% cost saving. Rejected because payment-service handles financial transactions. A spot interruption mid-payment would require idempotency guarantees and retry logic across all services. On-demand provides predictable availability.
- **Fixed node count** — simplest option. Rejected because it wastes money during off-peak hours and can't handle traffic spikes.

## Consequences
- Karpenter requires additional IAM permissions and SQS queue for interruption handling
- New nodes provisioned in seconds when pods are pending
- Idle nodes consolidated and terminated after 1 minute
- On-demand only adds ~$0.02/hour per node vs spot