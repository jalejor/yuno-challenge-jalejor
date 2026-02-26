# Design Decisions: FlexPay Secrets Management PoC

## 1. Secrets Management Approach

### Why HashiCorp Vault

After evaluating several secrets management solutions, HashiCorp Vault was selected as the primary secrets store for the following reasons:

**vs. AWS Secrets Manager**: AWS Secrets Manager is an excellent production choice but requires an AWS account, imposes costs, and cannot be run locally. Vault runs in Docker with zero external dependencies, making this PoC reproducible by any evaluator in minutes. In production, the same Vault API and AppRole auth pattern translates directly to a cloud-hosted Vault cluster without code changes.

**vs. SOPS (Secrets OPerationS)**: SOPS encrypts secrets at rest in version control, which is useful for GitOps workflows. However, SOPS does not provide a runtime API — secrets must be decrypted before use, which means they exist as plaintext on disk or in environment variables. Vault provides a runtime HTTP API that allows the service to fetch secrets on demand, never touching disk outside of Vault's encrypted storage.

**vs. Kubernetes Secrets**: Kubernetes Secrets are base64-encoded, not encrypted at rest by default, and require additional configuration (KMS envelope encryption, etcd encryption) to meet PCI-DSS requirements. Vault provides encryption at rest out of the box, fine-grained access policies, and a full audit log — all required for PCI-DSS compliance.

### Why AppRole Authentication

AppRole was chosen over static token auth for service-to-Vault authentication:

- **Machine-friendly**: AppRole is designed for automated systems. It uses a two-part credential (RoleID + SecretID) where RoleID is semi-public (like a username) and SecretID is secret (like a password). Neither alone is sufficient to authenticate.
- **Least privilege**: Each AppRole is bound to a specific Vault policy. The `payment-service` role can only read from `secret/data/flexpay/processors` — nothing else.
- **Token renewal**: Vault issues short-lived tokens after AppRole login that can be renewed, limiting the blast radius if a token is compromised.
- **No static root tokens**: In production, root tokens are immediately revoked after initial setup. Services never hold elevated credentials.

### Why KV v2 (Versioned Secrets)

The KV v2 secrets engine maintains a version history for every secret. This is critical for:

- **Safe rotation**: When a new credential is written, the previous version remains accessible and retrievable. If a newly rotated credential is invalid, a single `vault kv rollback` command restores the previous value.
- **Audit trail**: Vault's audit log records which version was read, by whom, and when — meeting PCI-DSS requirement 10 (track and monitor access to network resources and cardholder data).

---

## 2. How Each Core Requirement Is Satisfied

**R1 — Secrets Manager with 3+ Processor Credentials**:
Vault stores six credentials across three payment processors (Stripe-like, Adyen-like, Regional Acquirer) at a single KV path (`secret/flexpay/processors`). The payment service authenticates to Vault via AppRole at runtime, reads all credentials in one API call, and caches them in memory. The CI/CD pipeline never possesses Vault production tokens — it only builds and scans the image. This enforces strict build/runtime separation.

**R2 — CI/CD Pipeline with No Credential Exposure**:
The GitHub Actions pipeline has three security gates: (1) gitleaks scans every commit for accidentally committed secrets before anything else runs, (2) Trivy scans the built container image for known CVEs and exposed secrets, and (3) `docker history` and layer inspection verify that no credentials appear in any image layer. The pipeline YAML references zero payment credentials — it only uses `GITHUB_TOKEN` for registry authentication. The multi-stage Dockerfile ensures build-time artifacts (dev dependencies, build tools) never reach the production image.

**R3 — Zero-Downtime Rolling Updates**:
The deployment uses `start-first` rolling update order: a new container instance starts and must pass its health check before the orchestrator terminates an old instance. The `/health` endpoint returns HTTP 503 until the service has successfully authenticated to Vault and loaded all credentials. This means traffic is never routed to an instance that hasn't confirmed its secrets are available. At minimum one healthy instance serves traffic throughout the entire update cycle.

---

## 3. PoC vs. Production Trade-offs

| Concern | PoC (This Demo) | Production |
|---|---|---|
| **Vault deployment** | Single-node, file storage backend | HA cluster (3+ nodes), Consul or integrated storage |
| **TLS** | Disabled (localhost only) | TLS everywhere; Vault certs rotated by Vault PKI engine |
| **Vault unseal** | Auto-unseal via dev mode | Auto-unseal via AWS KMS or Azure Key Vault |
| **AppRole delivery** | SecretID written to shared Docker volume | Secure introduction via CI-generated wrapped token (single-use, TTL 60s) |
| **Orchestration** | Docker Compose with manual rolling script | Kubernetes with Vault Agent Injector sidecar |
| **Secret rotation** | Manual `rotate-secret.sh` script | Vault dynamic secrets or automated rotation via CronJob/Lambda |
| **Audit log** | File in container volume | Shipped to SIEM (Splunk, Datadog) via Vault audit backend |
| **Network policy** | Docker network (implicit trust) | Kubernetes NetworkPolicy + mTLS via Istio/Linkerd |

The PoC intentionally accepts these trade-offs to remain runnable in a single `docker compose up` command. Each trade-off is documented so an evaluator can see the production path clearly.

---

## 4. Credential Rotation Workflow

Zero-downtime rotation is achievable because secrets are fetched at runtime, not baked into images or containers:

1. **Trigger**: Security team runs `rotate-secret.sh PROCESSOR_A_API_KEY "new_key_value"`, or an automated CronJob fires on a schedule (e.g., every 90 days per PCI-DSS requirement 8.3.9).
2. **New credential provisioned**: The script (or automation) calls the payment processor's API to generate a new credential. Both old and new credentials are valid simultaneously during the transition window.
3. **Write to Vault**: The script runs `vault kv patch secret/flexpay/processors PROCESSOR_A_API_KEY="new_key_value"`. Vault creates version N+1, preserving version N. The old credential remains retrievable via `vault kv get -version=N`.
4. **Running containers detect the change**: Each service instance polls Vault for fresh secrets every 60 seconds (configurable). On the next poll, `getSecrets()` fetches the new version. The Vault KV metadata endpoint allows version comparison — the service only reloads if the version number has advanced.
5. **In-memory update without restart**: The service atomically swaps its in-memory credential cache. No restart required, no downtime, no traffic interruption.
6. **Validation**: A health check call confirms the service is operational with the new credentials. A test transaction to the processor validates the new key works end-to-end.
7. **Old credential revoked**: After a grace period (configurable, e.g., 5 minutes), the old credential is revoked at the processor level. Vault's KV version history preserves the old value for audit purposes but it is no longer functionally valid.
8. **Audit record**: Vault's audit log records the `kv/patch` write operation with the actor identity, timestamp, and path — providing the immutable record required by PCI-DSS Requirement 10.

If at any step the new credential is found to be invalid, `vault kv rollback -version=N secret/flexpay/processors` restores the previous value. Running instances pick it up on the next poll cycle.

---

## 5. Failure Scenario Handling

**Vault unavailable at startup**: The service retries Vault authentication with exponential backoff (1s, 2s, 4s, 8s... up to 30s max). During retries, `/health` returns HTTP 503 with `{ "status": "unhealthy", "secretsLoaded": false }`. The orchestrator's health check gate prevents any traffic from being routed to this instance. After exhausting retries, the container exits with a non-zero code, triggering an alert and allowing the orchestrator to reschedule.

**Vault unavailable during operation**: Once secrets are loaded into memory, the service continues processing payments using its cached credentials. It logs a warning (not the credential values) and increments a metric that alerts the operations team. The cache is valid until the next successful Vault poll. This provides resilience for transient network issues while still surfacing the problem.

**Expired or invalid credential**: The payment processor returns an authentication error. The service logs the error with the processor name and error code (never the credential value), increments an error counter, and raises an alert. The on-call engineer runs the rotation script to provision a fresh credential. Because rotation is fast (< 5 seconds for Vault write, < 60 seconds for containers to pick up), the mean time to recovery is under two minutes.

**Bad rotation (new credential is invalid)**: KV v2 versioning enables instant rollback. Running containers still hold the previous valid credential in cache and continue operating normally. The engineer runs `vault kv rollback` to restore the previous Vault version. Containers will pick up the restored value on the next poll cycle. The net result is zero user-visible impact.

**Network partition between service and Vault**: The service operates in degraded mode using its in-memory credential cache. It cannot load rotated credentials until connectivity is restored, but existing credentials remain valid. Once connectivity resumes, the next Vault poll succeeds and the cache is refreshed. This is acceptable for PCI-DSS as long as the credentials themselves remain confidential — which they do, since they never leave the service process.

---

## 6. Multi-Environment Isolation

A production payment platform requires strict isolation between development, staging, and production secrets. Mixing environments is a common source of PCI-DSS audit failures (e.g., a developer using a real cardholder credential in a test environment). There are two primary patterns with Vault:

### Pattern A — Vault Namespaces (Recommended for Enterprise)

Vault Enterprise supports **namespaces**: isolated, fully-separated tenants within a single Vault cluster. Each namespace has its own secret engines, auth methods, policies, and audit log — but shares the underlying storage and HA cluster. This means:

```
vault-cluster.internal/
  namespaces/
    dev/      ← development team Vault namespace
    staging/  ← QA/staging namespace
    prod/     ← production namespace (most restricted access)
```

A developer's Vault token scoped to the `dev/` namespace cannot read any path in `prod/`, even with an identical path structure. The PCI-DSS cardholder data environment (CDE) lives exclusively in `prod/`.

**Sample policy differences by environment**:

```hcl
# dev namespace — payment-service policy
# Dev credentials are synthetic/test values; broader access is acceptable for debugging
path "secret/data/flexpay/*" {
  capabilities = ["read", "list"]
}

# staging namespace — payment-service policy
# Staging uses processor sandbox credentials; tighter scope than dev
path "secret/data/flexpay/processors" {
  capabilities = ["read"]
}
path "secret/data/flexpay/config" {
  capabilities = ["read"]
}

# prod namespace — payment-service policy
# Production: single path, read-only, no wildcards
path "secret/data/flexpay/processors" {
  capabilities = ["read"]
}
```

### Pattern B — Separate Vault Instances per Environment (Open Source)

For Vault OSS (no namespaces), the standard approach is to run one Vault cluster per environment. Each cluster is independently sealed, has its own root token (immediately revoked after setup), and is only accessible from the corresponding network segment. The `VAULT_ADDR` environment variable in the service configuration points to the correct cluster:

| Environment | `VAULT_ADDR` | Network Access |
|---|---|---|
| dev | `http://vault-dev.internal:8200` | Developer VPN only |
| staging | `https://vault-staging.internal:8200` | CI/CD runners + staging ECS/K8s |
| prod | `https://vault-prod.internal:8200` | Production K8s nodes only (NetworkPolicy enforced) |

AppRole SecretIDs are environment-scoped: a `VAULT_SECRET_ID` generated by the dev CI pipeline is invalid against the production Vault cluster because it was created under a different AppRole in a different cluster entirely.

### Audit Log Segregation

Each environment's Vault cluster ships its audit log to a dedicated log stream. In production, the audit log feeds into the SIEM (e.g., Splunk) under a dedicated PCI-DSS index with 1-year retention and tamper-evident storage — satisfying PCI-DSS Requirement 10.5 ("Secure audit trails so they cannot be altered"). Development and staging logs are retained for 30 days and are excluded from PCI-DSS scope.
