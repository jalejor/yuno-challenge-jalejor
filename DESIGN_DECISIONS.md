# Design Decisions: FlexPay Secrets Management PoC

## 1. Secrets Management Approach

### Why HashiCorp Vault

HashiCorp Vault was selected after evaluating three alternatives:

**vs. AWS Secrets Manager**: Excellent production choice, but requires an AWS account and cannot run locally. Vault runs in Docker with zero dependencies, making this PoC reproducible by any evaluator in minutes. The same AppRole auth pattern translates directly to cloud-hosted Vault without code changes.

**vs. SOPS**: Encrypts secrets at rest in version control but provides no runtime API — secrets exist as plaintext on disk or in environment variables after decryption. Vault's HTTP API allows on-demand secret retrieval without disk exposure.

**vs. Kubernetes Secrets**: Base64-encoded, not encrypted at rest by default. Requires additional KMS/etcd encryption for PCI-DSS compliance. Vault provides encryption at rest, fine-grained policies, and audit logging out of the box.

### Why AppRole Authentication

AppRole was chosen over static token auth because it is machine-friendly (two-part credential: RoleID + SecretID), supports least-privilege policies (our role can only read `secret/data/flexpay/processors`), issues short-lived renewable tokens (limiting compromise blast radius), and eliminates static root tokens from production.

### Why KV v2 (Versioned Secrets)

KV v2 maintains version history for every secret, enabling safe rotation (previous version remains retrievable; `vault kv rollback` restores instantly) and audit compliance (PCI-DSS Req 10: which version was read, by whom, and when).

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

Zero-downtime rotation works because secrets are fetched at runtime, not baked into images:

1. **Trigger**: Security team runs `rotate-secret.sh PROCESSOR_A_API_KEY "new_key_value"` (or automated CronJob per PCI-DSS 8.3.9 — every 90 days).
2. **Provision**: Generate new credential at payment processor API. Both old and new are valid during transition.
3. **Write to Vault**: `vault kv patch secret/flexpay/processors PROCESSOR_A_API_KEY="new_value"` → creates version N+1, preserving N.
4. **Container detection**: Service polls Vault every 60s, compares KV version metadata, reloads only when version advances.
5. **In-memory swap**: Service atomically updates credential cache. No restart, no downtime.
6. **Validation**: Health check + test transaction confirm new credential works.
7. **Revoke old**: After grace period (~5 min), old credential revoked at processor level. Vault retains version for audit.
8. **Audit**: Vault logs the `kv/patch` with actor identity, timestamp, path (PCI-DSS Req 10).

Rollback: `vault kv rollback -version=N secret/flexpay/processors` restores previous value instantly.

---

## 5. Failure Scenario Handling

**Vault unavailable at startup**: Service retries with exponential backoff (5 attempts, 2s base). `/health` returns 503 until secrets load — orchestrator never routes traffic to unready instances. After exhausting retries, container exits non-zero for rescheduling.

**Vault unavailable during operation**: Service continues on cached credentials, logs warnings (never values), alerts ops team. Cache remains valid until next successful Vault poll — resilient to transient network issues.

**Expired/invalid credential**: Processor returns auth error → service logs error code (not value), raises alert. Engineer runs rotation script; MTTR < 2 minutes (5s Vault write + 60s container pickup).

**Bad rotation**: KV v2 enables instant rollback (`vault kv rollback`). Running containers still hold previous valid credentials in cache. Zero user-visible impact.

**Network partition**: Service operates in degraded mode on cached secrets. Cannot pick up rotated credentials until connectivity restores, but existing credentials remain valid and confidential (never leave process memory).

---

## 6. Multi-Environment Secrets Isolation

Production requires strict isolation between dev/staging/prod secrets — mixing is a common PCI-DSS audit failure. Two patterns apply:

**Vault Enterprise (Namespaces)**: Each environment gets an isolated namespace (`dev/`, `staging/`, `prod/`) sharing one HA cluster but with independent secret engines, policies, and audit logs. A dev-scoped token cannot read any `prod/` path. Policies tighten per environment — dev allows `secret/data/flexpay/*` (wildcard), prod allows only `secret/data/flexpay/processors` (single path, read-only).

**Vault OSS (Separate Instances)**: One Vault cluster per environment, each independently sealed and network-isolated. `VAULT_ADDR` in service config points to the correct cluster; AppRole SecretIDs are cluster-scoped (dev credentials are invalid against prod Vault).

Each environment's audit log ships to a dedicated stream — prod logs feed the SIEM with 1-year retention per PCI-DSS Req 10.5; dev/staging logs are retained 30 days outside PCI scope.
