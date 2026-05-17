# ADR-004: External Secrets Operator for secrets management

## Status
Accepted

## Context
Services need database passwords and API keys injected at runtime without storing them in Git.

## Decision
External Secrets Operator (ESO) with AWS Secrets Manager as the backend.

## Alternatives considered
- **Secrets Store CSI Driver** — mounts secrets as files. Rejected because all nine services read env vars, not files. Migrating all services to file-based secrets would require code changes across the entire codebase.
- **Sealed Secrets** — encrypts secrets for Git storage. Rejected because it still stores secrets in Git (encrypted). If the sealing key is compromised, all secrets are exposed. Secrets Manager provides rotation, auditing and fine-grained IAM.
- **Plain K8s Secrets** — simplest option. Rejected for production because secrets are base64 not encrypted, and stored in etcd without envelope encryption by default.

## Consequences
- ESO requires IRSA role with Secrets Manager read permissions
- Secret rotation propagates within 1 hour automatically
- Native K8s Secret objects — no code changes required in services