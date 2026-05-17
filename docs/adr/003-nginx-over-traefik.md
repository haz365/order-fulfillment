# ADR-003: NGINX Ingress over Traefik

## Status
Accepted

## Context
The brief specifies Traefik. We used NGINX instead.

## Decision
NGINX Ingress Controller behind AWS NLB.

## Alternatives considered
- **Traefik** — brief requirement, native Kubernetes integration, automatic service discovery. Would have been the correct choice per the brief. NGINX was used due to familiarity and simpler initial configuration.
- **AWS Load Balancer Controller** — native ALB per ingress, WAF integration. Rejected because it creates one ALB per ingress rule which is expensive. NGINX creates one NLB for all services.

## Consequences
- Does not fully meet the brief (Traefik specified)
- NGINX is more widely used and documented
- Single NLB for all services keeps cost low
- Would migrate to Traefik for production submission