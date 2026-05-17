# ADR-006: PostgreSQL on StatefulSet over RDS

## Status
Accepted

## Context
Nine services share a PostgreSQL database. We needed a persistent, reliable database solution.

## Decision
PostgreSQL 16 on a Kubernetes StatefulSet with EBS gp3 PVC, encrypted with KMS CMK.

## Alternatives considered
- **RDS PostgreSQL** — managed, automatic backups, Multi-AZ failover, no operational overhead. Would be the correct production choice. Rejected for this project because RDS Multi-AZ adds $100+/month and single-AZ RDS offers no advantage over a StatefulSet at this scale.
- **RDS Aurora Serverless** — scales to zero, pay per use. Rejected because Aurora has a cold start latency of 15-30 seconds which would fail readiness probes.
- **CockroachDB** — distributed, survives AZ failures. Rejected due to operational complexity and licensing cost.

## Consequences
- StatefulSet is single replica — AZ failure requires snapshot restore (RTO 15-30 minutes)
- VolumeSnapshot provides point-in-time recovery
- gp3 EBS is cheaper than io1 at our IOPS requirements
- Production recommendation: migrate to RDS Multi-AZ