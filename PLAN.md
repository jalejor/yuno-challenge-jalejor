Now let me produce the implementation plan.

# Implementation Plan

## Challenge Analysis

**Challenge**: Build a PCI-DSS compliant secrets management PoC for FlexPay's payment gateway service within a 2-hour window.

**Evaluation Criteria (100 pts total)**:
| Criterion | Points | Priority |
|---|---|---|
| Secrets Management Implementation | 25 | HIGH |
| Design Decisions & Technical Communication | 25 | HIGH |
| CI/CD Pipeline Security & Compliance | 20 | HIGH |
| Zero-Downtime Deployment Design | 20 | HIGH |
| Code Quality, Documentation & Reproducibility | 10 | MEDIUM |

**Key Requirements**:
1. **Core R1**: Secrets manager with 3+ processor credentials, runtime retrieval, build/runtime separation
2. **Core R2**: CI/CD pipeline with no credential exposure, security gates, image scanning
3. **Core R3**: Zero-downtime rolling updates, health checks verifying secret loading, rotation documentation
4. **Stretch**: Rotation automation, audit logging, multi-environment isolation

## Architecture

**Tech Stack Choices** (optimized for local demonstrability in 2 hours):

| Component | Choice | Justification |
|---|---|---|
| **Secrets Manager** | HashiCorp Vault (dev mode + production-like config) | Industry standard, free, runs locally, rich policy engine, auditors know it |
| **Orchestration** | Docker Compose with rolling updates | Fully local, no cloud account needed, evaluators can run it immediately |
| **Service** | Node.js (Express) minimal payment gateway | Matches the scenario description, fast to write, easy health checks |
| **CI/CD** | GitHub Actions workflow | Industry standard, clear YAML, easy to validate log masking |
| **Security Gate** | Trivy (image scanning) + gitleaks (secret detection) | Free, well-known, runs in CI and locally |
| **Container Runtime** | Docker with multi-stage builds | Proves no secrets in layers |

**Architecture Flow**:
```
[GitHub Actions CI] → builds image (NO secrets) → pushes to registry
                                                        ↓
[Docker Compose] → starts Vault → seeds secrets → deploys service (3 replicas)
                                                        ↓
[Payment Service] → authenticates to Vault via AppRole → retrieves credentials at runtime
                                                        ↓
[Health Check] → /health verifies secrets loaded → rolling update proceeds
```

**Key Design Decisions**:
- Vault AppRole auth for service-to-Vault authentication (least-privilege, no human tokens)
- Vault policies scoped to only payment processor paths
- Secrets never in Dockerfile, compose file, or CI logs
- Health endpoint returns `ready` only after secrets successfully loaded
- Docker Compose `deploy.update_config` for rolling updates

## Project Structure
```
flexpay-secrets-poc/
├── README.md                          # Setup & validation instructions
├── DESIGN_DECISIONS.md                # Architecture document (500-1000 words)
├── .github/
│   └── workflows/
│       └── ci-cd.yml                  # GitHub Actions pipeline
├── .gitleaks.toml                     # Gitleaks config for secret scanning
├── service/
│   ├── Dockerfile                     # Multi-stage, no secrets
│   ├── package.json                   # Node.js dependencies
│   ├── src/
│   │   ├── index.js                   # Express server entry point
│   │   ├── vault-client.js            # Vault integration (AppRole auth + secret fetch)
│   │   ├── health.js                  # Health/readiness check handler
│   │   └── processors.js             # Mock payment processor handlers
│   └── .dockerignore                  # Exclude sensitive files from build context
├── infrastructure/
│   ├── docker-compose.yml             # Full stack: Vault + payment service (3 replicas)
│   ├── vault/
│   │   ├── config.hcl                 # Vault server configuration
│   │   ├── policies/
│   │   │   └── payment-service.hcl    # Least-privilege Vault policy
│   │   └── scripts/
│   │       ├── init-vault.sh          # Initialize Vault, enable AppRole, seed secrets
│   │       └── rotate-secret.sh       # Secret rotation demonstration script
│   └── deploy.sh                      # Rolling update deployment script
├── scripts/
│   ├── validate-image.sh              # Prove no secrets in container image layers
│   ├── validate-logs.sh               # Prove no secrets in CI logs
│   └── run-security-scan.sh           # Run Trivy + gitleaks locally
└── .gitignore
```

## Tasks

### TASK 1: Project Initialization & Dependencies
**files**: `package.json, .gitignore, .dockerignore, .gitleaks.toml, service/package.json`
**depends_on**: none
**description**:
Initialize the Git repository and project scaffolding:
- Create root `.gitignore` (node_modules, .env, *.log, vault-data/, tokens/)
- Create `service/package.json` with dependencies: `express`, `node-vault` (Vault client), `pino` (structured logging)
- Create `service/.dockerignore` excluding `.env`, `node_modules`, `*.log`
- Create `.gitleaks.toml` with rules to detect API keys, passwords, and common secret patterns
- **Scoring criteria addressed**: Code Quality & Reproducibility (10pts)

### TASK 2: Minimal Payment Gateway Service
**files**: `service/src/index.js, service/src/vault-client.js, service/src/health.js, service/src/processors.js`
**depends_on**: TASK 1
**description**:
Build the Node.js Express service:

**`service/src/vault-client.js`**:
- Export `initVaultClient()` that authenticates to Vault using AppRole (reads `VAULT_ROLE_ID` and `VAULT_SECRET_ID` from environment — these are auth tokens, NOT payment secrets)
- Export `getSecrets()` that reads from Vault path `secret/data/flexpay/processors` and returns an object with all 3 processor credentials
- Export `refreshSecrets()` for on-demand secret reload (stretch: periodic refresh)
- Handle Vault unavailable gracefully (retry with backoff, log error, set unhealthy state)
- Environment variables needed: `VAULT_ADDR`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID` (auth only, not payment credentials)

**`service/src/processors.js`**:
- Define 3 mock processor configurations:
  - Processor A (Stripe-like): `PROCESSOR_A_API_KEY`, `PROCESSOR_A_SECRET`
  - Processor B (Adyen-like): `PROCESSOR_B_MERCHANT_ID`, `PROCESSOR_B_API_KEY`
  - Processor C (Regional acquirer): `PROCESSOR_C_ENDPOINT`, `PROCESSOR_C_TOKEN`
- Export `processPayment(processorName, amount)` that returns mock response using loaded credentials (proves secrets are available)
- NEVER log credential values — only log that credentials were loaded (e.g., `"Loaded 6 credentials for 3 processors"`)

**`service/src/health.js`**:
- Export health check handler for GET `/health` — returns `{ status: "healthy", secretsLoaded: true, processors: ["A","B","C"], uptime: X }` when secrets are loaded
- Returns HTTP 503 with `{ status: "unhealthy", secretsLoaded: false }` if secrets haven't been loaded yet
- This is CRITICAL for zero-downtime deploys — orchestrator won't route traffic until health passes

**`service/src/index.js`**:
- On startup: call `initVaultClient()` then `getSecrets()`
- Routes: `GET /health` (health check), `POST /pay` (mock payment endpoint that uses processors), `GET /ready` (readiness probe)
- Graceful shutdown handling (SIGTERM)
- Start listening on port from `PORT` env var (default 3000)
- Log startup with structured JSON (pino), never log secret values

- **Scoring criteria addressed**: Secrets Management (25pts), Zero-Downtime Deployment (20pts)

### TASK 3: Dockerfile (Multi-Stage, No Secrets)
**files**: `service/Dockerfile`
**depends_on**: TASK 1
**description**:
Create a multi-stage Dockerfile that provably contains NO secrets:

```dockerfile
# Stage 1: Build
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY src/ ./src/

# Stage 2: Production
FROM node:20-alpine
RUN addgroup -g 1001 -S appgroup && adduser -S appuser -u 1001 -G appgroup
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/src ./src
COPY --from=builder /app/package.json ./
USER appuser
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "src/index.js"]
```

Key points:
- NO `ENV` instructions with secrets
- NO `COPY` of `.env` files
- Non-root user (PCI-DSS best practice)
- Built-in HEALTHCHECK
- Multi-stage to minimize attack surface
- `.dockerignore` prevents accidental secret inclusion

- **Scoring criteria addressed**: Secrets Management (25pts), CI/CD Security (20pts)

### TASK 4: Vault Configuration & Initialization Scripts
**files**: `infrastructure/vault/config.hcl, infrastructure/vault/policies/payment-service.hcl, infrastructure/vault/scripts/init-vault.sh, infrastructure/vault/scripts/rotate-secret.sh`
**depends_on**: none
**description**:
Create Vault server configuration and bootstrapping:

**`infrastructure/vault/config.hcl`**:
- Storage backend: file (for PoC; note in design doc that production uses Consul/integrated storage)
- Listener: TCP on 0.0.0.0:8200, TLS disabled (PoC only; document this trade-off)
- Enable audit logging to file at `/vault/logs/audit.log`
- API address: http://vault:8200

**`infrastructure/vault/policies/payment-service.hcl`**:
- Least-privilege policy: only allow `read` on `secret/data/flexpay/processors`
- Deny access to all other paths
- This demonstrates the principle of least privilege for auditors
```hcl
path "secret/data/flexpay/processors" {
  capabilities = ["read"]
}
path "secret/data/flexpay/*" {
  capabilities = ["deny"]
}
```
Wait — Vault policies don't use deny like that. Correct approach:
```hcl
path "secret/data/flexpay/processors" {
  capabilities = ["read"]
}
```
(Default deny — Vault denies everything not explicitly allowed)

**`infrastructure/vault/scripts/init-vault.sh`**:
- Wait for Vault to be ready
- Enable KV v2 secrets engine at `secret/`
- Write 3 processor credentials to `secret/flexpay/processors`:
  - `PROCESSOR_A_API_KEY=pk_live_mock_stripe_key_abc123`
  - `PROCESSOR_A_SECRET=sk_live_mock_stripe_secret_xyz789`
  - `PROCESSOR_B_MERCHANT_ID=ADYEN_MERCHANT_FLEXPAY_001`
  - `PROCESSOR_B_API_KEY=AQEyhmfxK4...mock_adyen_key`
  - `PROCESSOR_C_ENDPOINT=https://regional-acquirer.mock/api/v1`
  - `PROCESSOR_C_TOKEN=tok_regional_mock_abc123def456`
- Enable AppRole auth method
- Create policy from `payment-service.hcl`
- Create AppRole `payment-service` with the policy attached
- Fetch role_id and secret_id, write them to a shared Docker volume (NOT to image)
- Output role_id and secret_id paths for the compose service to mount

**`infrastructure/vault/scripts/rotate-secret.sh`**:
- Takes a processor name and new credential value as arguments
- Updates the secret in Vault: `vault kv put secret/flexpay/processors ...`
- Demonstrates that running containers can detect new values on next `getSecrets()` call
- Logs the rotation event with timestamp
- Does NOT require container restart (key auditor requirement)

- **Scoring criteria addressed**: Secrets Management (25pts), Zero-Downtime Deployment (20pts)

### TASK 5: Docker Compose Infrastructure
**files**: `infrastructure/docker-compose.yml, infrastructure/deploy.sh`
**depends_on**: TASK 3, TASK 4
**description**:
Create the full orchestration stack:

**`infrastructure/docker-compose.yml`**:
- **vault service**: HashiCorp Vault (latest), exposed on 8200, with config volume mount, health check (`vault status`), `IPC_LOCK` capability
- **vault-init service**: Runs `init-vault.sh`, depends on vault healthy, writes AppRole credentials to shared volume, exits after completion
- **payment-service** (3 replicas via `deploy.replicas: 3`):
  - Depends on vault-init (completed)
  - Environment: `VAULT_ADDR=http://vault:8200` (not a secret — just the address)
  - Reads `VAULT_ROLE_ID` and `VAULT_SECRET_ID` from files on shared volume (not env vars in compose file)
  - Health check: `wget -qO- http://localhost:3000/health || exit 1`
  - Deploy configuration:
    ```yaml
    deploy:
      replicas: 3
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
        failure_action: rollback
      rollback_config:
        parallelism: 1
    ```
  - `start-first` order ensures new instance is healthy before old one stops (zero-downtime)

Note: Docker Compose v2 with `docker compose up` supports deploy config in Swarm mode. For local demo, we'll use `docker compose up --scale payment-service=3` and the `deploy.sh` script for rolling updates.

Actually, for local Docker Compose (non-Swarm), rolling updates need to be handled via the `deploy.sh` script that does:
1. Build new image
2. For each replica: stop one → start new one → wait for health → proceed
OR use `docker compose up -d --no-deps --scale payment-service=3 payment-service` which recreates containers one at a time.

**`infrastructure/deploy.sh`**:
- Builds new image
- Performs rolling update: scales up a new instance, waits for it to pass health check, then removes an old instance
- Repeats for each replica
- Logs each step for audit trail
- Validates zero healthy instances never drops below 1

- **Scoring criteria addressed**: Zero-Downtime Deployment (20pts), Code Quality (10pts)

### TASK 6: GitHub Actions CI/CD Pipeline
**files**: `.github/workflows/ci-cd.yml`
**depends_on**: TASK 3
**description**:
Create the compliant CI/CD pipeline:

**`.github/workflows/ci-cd.yml`**:
```yaml
name: FlexPay Payment Service CI/CD
on: [push, pull_request]
```

**Jobs**:

1. **secret-scan** (runs first):
   - Uses `gitleaks/gitleaks-action` to scan the repository for leaked secrets
   - Fails the pipeline if any secrets are detected in code
   - This is a security gate (required for top-quartile CI/CD score)

2. **build**:
   - Checks out code
   - Builds Docker image using multi-stage Dockerfile
   - **Image scanning**: Runs `aquasecurity/trivy-action` on the built image
     - Fail on HIGH/CRITICAL vulnerabilities
   - **Credential verification**: Runs `docker history` and `docker save | tar` to prove no secrets in layers
     - `docker save flexpay-service | tar -xO | grep -rn "API_KEY\|SECRET\|TOKEN\|PASSWORD" && exit 1 || echo "PASS: No secrets in image layers"`
   - Tags image with commit SHA
   - **Key**: NO secrets are available in this job. No `secrets.` references for payment credentials. Only uses GitHub's built-in `GITHUB_TOKEN` for registry auth.

3. **deploy** (depends on build + secret-scan):
   - Only runs on `main` branch
   - Uses GitHub environment with protection rules (documented, not implemented in PoC)
   - Runs `infrastructure/deploy.sh` for rolling deployment
   - Deployment uses runtime Vault injection — pipeline never touches payment secrets
   - Post-deploy: hits `/health` endpoint to verify deployment succeeded

**Critical elements for scoring**:
- `add-mask` for any dynamic values
- No `echo` of secrets
- Security gates: gitleaks + trivy
- Clear separation: CI builds image, runtime gets secrets from Vault
- Comments in YAML explaining WHY each step exists (auditor-friendly)

- **Scoring criteria addressed**: CI/CD Pipeline Security (20pts)

### TASK 7: Validation Scripts
**files**: `scripts/validate-image.sh, scripts/validate-logs.sh, scripts/run-security-scan.sh`
**depends_on**: TASK 3
**description**:
Create scripts that auditors can run to verify compliance:

**`scripts/validate-image.sh`**:
- Builds the Docker image
- Runs `docker history` to show all layers (no secrets in commands)
- Exports image and greps all layers for secret patterns (API_KEY, SECRET, TOKEN, PASSWORD, credentials)
- Runs `docker inspect` to show no secret env vars
- Outputs PASS/FAIL for each check
- Clear, human-readable output format

**`scripts/validate-logs.sh`**:
- Simulates a CI build (or reads recent build logs)
- Greps for any secret patterns in output
- Verifies structured logs from service don't contain credential values

**`scripts/run-security-scan.sh`**:
- Runs Trivy scan on the built image
- Runs gitleaks on the repository
- Outputs results in a format auditors can review

- **Scoring criteria addressed**: Code Quality & Reproducibility (10pts), CI/CD Security (20pts)

### TASK 8: Design Decisions Document
**files**: `DESIGN_DECISIONS.md`
**depends_on**: none
**description**:
Write a 500-1000 word markdown document covering ALL required topics. This is worth 25 points — equal to secrets management itself. Structure:

**1. Secrets Management Approach (Why Vault)**:
- Chose HashiCorp Vault over AWS Secrets Manager (cloud-agnostic, runs locally, free), over SOPS (no runtime API), over Kubernetes Secrets (not encrypted at rest by default)
- AppRole auth chosen over Token auth (machine-friendly, supports auto-renewal, least-privilege)
- KV v2 engine for versioning support (enables rollback of bad rotations)

**2. How Each Core Requirement Is Satisfied**:
- R1: Vault stores 3 processor credential sets; service authenticates via AppRole at runtime; CI never has Vault production tokens
- R2: Multi-stage Docker build, gitleaks scanning, Trivy image scan, `docker history` verification, no secrets in compose file
- R3: Rolling update with `start-first` order, health checks gate traffic, credentials fetched at boot (not baked in)

**3. PoC vs Production Trade-offs**:
- PoC: Vault dev mode / single-node, TLS disabled, file storage backend, shared volume for AppRole credentials
- Production: Vault HA cluster with Consul backend, TLS everywhere, auto-unseal with KMS, AppRole via secure introduction (CI generates wrapped token)
- PoC: Docker Compose; Production: Kubernetes with Vault Agent Injector sidecar
- PoC: Manual rotation script; Production: Vault dynamic secrets or automated rotation with lambda/CronJob

**4. Credential Rotation Workflow (Step-by-Step)**:
1. Security team runs rotation script (or automated CronJob triggers)
2. Script generates new credential with payment processor's API
3. Script writes new value to Vault (`vault kv put`) — old version preserved in KV v2
4. Running containers either: (a) periodic poll Vault for fresh secrets, or (b) Vault Agent sidecar detects change and signals app
5. Service reloads credentials without restart — no downtime
6. If new credential is invalid, rollback to previous KV version
7. Audit log records who rotated, when, and which path

**5. Failure Scenarios**:
- Vault unavailable at startup: service retries with exponential backoff, health check returns 503, orchestrator doesn't route traffic
- Vault unavailable during operation: service uses cached credentials, logs warning, alerts ops team
- Expired/invalid credential: processor returns auth error, service logs it (not the credential), triggers alert; rotation script can quickly update
- Bad rotation: KV v2 versioning enables instant rollback; old instances still have working cached credentials
- Network partition: service continues operating with cached secrets; reconnects to Vault when network restores

- **Scoring criteria addressed**: Design Decisions & Technical Communication (25pts)

### TASK 9: README & Setup Instructions
**files**: `README.md`
**depends_on**: TASK 5, TASK 6, TASK 7
**description**:
Write comprehensive README with:

**Header**: Project name, one-line description, architecture diagram (ASCII)

**Prerequisites**: Docker, Docker Compose v2, Git, (optional) Trivy, gitleaks

**Quick Start** (numbered steps):
```bash
# 1. Clone the repo
git clone <repo> && cd flexpay-secrets-poc

# 2. Start the infrastructure (Vault + Payment Service)
cd infrastructure && docker compose up -d

# 3. Wait for services to be healthy
docker compose ps  # All should show "healthy"

# 4. Test the health endpoint
curl http://localhost:3000/health

# 5. Test a mock payment
curl -X POST http://localhost:3000/pay -H "Content-Type: application/json" -d '{"processor": "A", "amount": 100}'
```

**Validation Commands** (auditor-focused):
```bash
# Verify NO secrets in container image
./scripts/validate-image.sh

# Verify NO secrets in service logs  
docker compose logs payment-service | grep -i "api_key\|secret\|token\|password"

# Run security scans
./scripts/run-security-scan.sh

# Demonstrate rolling update (zero-downtime)
./infrastructure/deploy.sh

# Demonstrate secret rotation
./infrastructure/vault/scripts/rotate-secret.sh PROCESSOR_A_API_KEY "new_rotated_key_123"
curl http://localhost:3000/health  # Still healthy, new secret loaded
```

**Architecture Diagram** (ASCII art showing Vault → Service flow)

**File Structure** explanation

- **Scoring criteria addressed**: Code Quality, Documentation & Reproducibility (10pts)

### TASK 10: Stretch Goals (Audit Logging & Rotation Automation)
**files**: `service/src/audit-logger.js, infrastructure/vault/config.hcl (modify)`
**depends_on**: TASK 2, TASK 4
**description**:
If time permits, implement stretch goals:

**Audit Logging**:
- Enable Vault audit log backend (file) in `config.hcl`
- In `service/src/audit-logger.js`: log every secret access with timestamp, service instance ID, Vault path accessed, and success/failure
- Format: JSON lines, exportable for auditor review
- Add `GET /audit` endpoint that returns recent access logs (last 100 entries)

**Periodic Secret Refresh**:
- In `vault-client.js`, add a `setInterval` that calls `getSecrets()` every 60 seconds
- If new version detected (compare Vault KV version number), update in-memory credentials
- Log rotation detection event
- This proves containers don't need restart for rotation

**Multi-Environment** (documentation only):
- Add to DESIGN_DECISIONS.md a section explaining how Vault namespaces or separate Vault instances per environment isolate dev/staging/prod secrets
- Show sample policy differences

- **Scoring criteria addressed**: Stretch goals (bonus), Secrets Management (25pts), Design Decisions (25pts)

## Acceptance Criteria

1. **[Secrets Management - 25pts]**: `validate-image.sh` passes — no credentials in image layers, env vars, or build history. Service fetches all 6 credentials from Vault at runtime via AppRole auth. Vault policy restricts service to read-only on single path.

2. **[CI/CD Security - 20pts]**: GitHub Actions workflow includes gitleaks secret scan + Trivy image scan as security gates. Pipeline YAML contains zero payment credential references. `validate-logs.sh` confirms clean logs.

3. **[Zero-Downtime Deployment - 20pts]**: `deploy.sh` performs rolling update maintaining ≥1 healthy instance. Health endpoint returns 503 until secrets loaded. `docker compose ps` shows replicas cycling during update without all going down simultaneously.

4. **[Design Decisions - 25pts]**: `DESIGN_DECISIONS.md` is 500-1000 words covering: Vault choice rationale with alternatives, requirement-by-requirement satisfaction mapping, PoC vs production trade-offs (≥5), step-by-step rotation workflow (≥5 steps), failure scenario handling (≥4 scenarios).

5. **[Code Quality & Reproducibility - 10pts]**: Evaluator can run `docker compose up -d` and `curl localhost:3000/health` within 3 commands. README has all validation commands. Repo structure is clean with logical organization. All scripts are executable and documented.
