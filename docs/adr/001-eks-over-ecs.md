# ADR-001: EKS over ECS Fargate

## Status
Accepted

## Context
We needed a container orchestration platform for nine services on AWS.

## Decision
EKS with managed node groups.

## Alternatives considered
- **ECS Fargate** — no node management, simpler ops. Rejected because Kubernetes is the industry standard, the brief explicitly requires EKS, and the ecosystem (Helm, ArgoCD, Karpenter, Prometheus) integrates natively.
- **ECS EC2** — more control than Fargate but still ECS. Rejected for same reasons.

## Consequences
- $72/month control plane cost regardless of usage
- More operational complexity than ECS
- Full Kubernetes ecosystem available