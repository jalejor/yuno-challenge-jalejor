# FlexPay Secrets Management PoC

A PCI-DSS compliant secrets management proof-of-concept for FlexPay's payment gateway service. Demonstrates runtime secret injection via HashiCorp Vault with zero-downtime rolling deployments and security-gated CI/CD.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    GitHub Actions CI/CD                         │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐ │
│  │ Secret Scan  │  │ Build Image  │  │  Deploy (main only)   │ │
│  │ (gitleaks)   │→ │ + Trivy Scan │→ │  rolling update       │ │
│  └──────────────┘  └──────────────┘  └───────────────────────┘ │
│        NO payment credentials in pipeline                       │
└─────────────────────────────────────────────────────────────────┘
                              │ image (no secrets)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Docker Compose Stack                         │
│                                                                 │
│  ┌─────────────────┐     ┌──────────────────────────────────┐  │
│  │   HashiCorp     │     │        vault-init                │  │
│  │   Vault         │◄────│  seeds secrets + creates         │  │
│  │   :8200         │     │  AppRole credentials             │  │
│  └────────┬────────┘     └──────────────────────────────────┘  │
│           │                                                     │
│           │ AppRole Auth (role_id + secret_id)                 │
│           │ ← secrets fetched at RUNTIME, not baked in         │
│           ▼                                                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              payment-service (3 replicas)                │  │
│  │                                                          │  │
│  │  replica-1 :3000   replica-2 :3001   replica-3 :3002    │  │
│  │  ┌──────────────────────────────────────────────────┐   │  │
│  │  │  On startup: authenticate → fetch credentials    │   │  │
│  │  │  /health → 503 until secrets loaded              │   │  │
│  │  │  /pay    → uses credentials from Vault           │   │  │
│  │  └──────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘

Key: Vault stores 3 processor credential sets (6 values total)
     Service retrieves them at runtime via AppRole authentication
     CI/CD pipeline NEVER has access to payment credentials
```

## Prerequisites

| Tool | Version | Required |
|------|---------|----------|
| Docker | 20.10+ | **Required** |
| Docker Compose v2 | 2.0+ | **Required** |
| Git | any | **Required** |
| Trivy | 0.40+ | Optional (for local security scans) |
| gitleaks | 8.0+ | Optional (for local secret scanning) |

Install optional tools:
```bash
# Trivy (macOS)
brew install trivy

# gitleaks (macOS)
brew install gitleaks
```

### Prerequisites Verification

Run these commands to confirm your environment is ready before starting:

```bash
# Check Docker version (must be 20.10+)
docker --version
# Expected: Docker version 20.10.x or higher

# Check Docker Compose v2 (must be 2.0+)
docker compose version
# Expected: Docker Compose version v2.x.x

# Verify Docker daemon is running
docker info --format '{{.ServerVersion}}'
# Expected: prints a version string (errors mean daemon is not running)

# Check Git
git --version
# Expected: git version 2.x.x

# Optional: Check Trivy (for local CVE scanning)
trivy --version 2>/dev/null || echo "trivy not installed (optional)"

# Optional: Check gitleaks (for local secret scanning)
gitleaks version 2>/dev/null || echo "gitleaks not installed (optional)"
```

## Quick Start

> **First-run note**: Docker will pull the `hashicorp/vault` image (~200 MB) and build the `payment-service` image on first run. Allow 2–5 minutes depending on your connection. Subsequent starts are fast (images are cached).

```bash
# 1. Clone the repo
git clone <repo> && cd flexpay-secrets-poc

# 2. Start the full stack (Vault + Payment Service — 3 replicas)
cd infrastructure && docker compose up --scale payment-service=3 -d

# 3. Wait for all services to become healthy (~30–60 seconds on first run)
docker compose ps  # All services should show "healthy" or "exited (0)" for vault-init

# 4. Test the health endpoint on replica 1 (port 3000)
curl http://localhost:3000/health

# Expected response:
# {"status":"healthy","secretsLoaded":true,"processors":["A","B","C"],"uptime":12}

# 5. Test a mock payment
curl -X POST http://localhost:3000/pay \
  -H "Content-Type: application/json" \
  -d '{"processor": "A", "amount": 100}'

# 6. When done, stop and remove all containers and volumes
cd infrastructure && docker compose down -v
# The -v flag removes named volumes (clears Vault data and AppRole credentials)
# This ensures a clean state for the next run
```

> **Note**: The service returns HTTP 503 on `/health` until it has successfully authenticated to Vault and retrieved all credentials. This gates traffic during rolling deployments. With `--scale payment-service=3`, replicas are accessible on host ports **3000** (replica 1), **3001** (replica 2), and **3002** (replica 3).

## Validation Commands (Auditor Checklist)

### 1. Verify NO secrets in the container image

```bash
# Run from repository root
./scripts/validate-image.sh

# What it checks:
# - docker history shows no secrets in layer commands
# - Image export grep finds no credential patterns in layers
# - docker inspect shows no secret environment variables
# Expected: All checks PASS
```

### 2. Verify NO secrets in service logs

```bash
# Run from repository root — or omit -f flag if already in infrastructure/
docker compose -f infrastructure/docker-compose.yml logs payment-service \
  | grep -iE "api_key|secret|token|password|credential"

# Expected: No matches (logs show "Loaded 6 credentials for 3 processors"
# but NEVER the actual values)
```

### 3. Run full security scan (Trivy + gitleaks)

```bash
./scripts/run-security-scan.sh

# What it runs:
# - gitleaks: scans entire repo for committed secrets
# - Trivy: scans container image for CVEs (fails on HIGH/CRITICAL)
# Expected: 0 secrets found, 0 critical vulnerabilities
```

### 4. Demonstrate zero-downtime rolling update

```bash
# In one terminal, watch health checks continuously
watch -n1 'curl -s http://localhost:3000/health | jq .'

# In another terminal, trigger a rolling update
./infrastructure/deploy.sh

# Expected: Health endpoint remains responsive throughout update.
# At least 1 replica is always healthy. Never a gap in service.
```

### 5. Demonstrate secret rotation (no container restart)

```bash
# Rotate Processor A's API key
./infrastructure/vault/scripts/rotate-secret.sh PROCESSOR_A_API_KEY "new_rotated_key_123"

# The service picks up the new secret on its next refresh cycle (60s)
# or trigger an immediate refresh:
curl -X POST http://localhost:3000/admin/refresh-secrets

# Expected: Service remains healthy, continues processing payments
# with the new credential — no restart required
```

### 6. Inspect Vault audit log

```bash
# View all secret access events (Vault audit backend)
docker compose -f infrastructure/docker-compose.yml exec vault \
  cat /vault/logs/audit.log | jq .

# Or view application-level audit events (service audit logger)
curl -s http://localhost:3000/audit | jq .

# Each entry shows: timestamp, operation, path, auth method
# Secret VALUES are hashed in audit log (HMAC) — never in plaintext
```

### 7. Verify AppRole least-privilege policy

```bash
# Export the Vault root token from the init container log
VAULT_TOKEN=$(docker compose -f infrastructure/docker-compose.yml logs vault-init \
  | grep "Root Token" | awk '{print $NF}')

# Try to access a path outside the policy (should fail)
curl -H "X-Vault-Token: <payment-service-token>" \
  http://localhost:8200/v1/secret/data/other-path
# Expected: 403 Forbidden

# Access the allowed path (should succeed)
curl -H "X-Vault-Token: <payment-service-token>" \
  http://localhost:8200/v1/secret/data/flexpay/processors
# Expected: 200 with credentials
```

## Stopping the Stack

```bash
# Stop all containers and remove named volumes (full cleanup)
cd infrastructure && docker compose down -v

# The -v flag is important: it removes the vault-credentials volume that holds
# the AppRole role_id and secret_id. Without -v, stale credentials from the
# previous run persist, which can cause authentication failures on restart.

# To stop without removing data (e.g., to pause and resume):
docker compose -f infrastructure/docker-compose.yml stop
# Then resume with:
docker compose -f infrastructure/docker-compose.yml start
```

## File Structure

```
flexpay-secrets-poc/
│
├── README.md                          ← This file
├── DESIGN_DECISIONS.md                ← Architecture decisions (500-1000 words)
│
├── .github/
│   └── workflows/
│       └── ci-cd.yml                  ← GitHub Actions pipeline (security-gated)
│
├── .gitleaks.toml                     ← Secret scanning rules
│
├── service/                           ← Node.js payment gateway service
│   ├── Dockerfile                     ← Multi-stage build, no secrets, non-root user
│   ├── package.json
│   ├── .dockerignore                  ← Excludes .env, node_modules, logs
│   └── src/
│       ├── index.js                   ← Express server, graceful shutdown
│       ├── vault-client.js            ← AppRole auth + secret retrieval
│       ├── health.js                  ← Health/readiness handlers (gates traffic)
│       ├── processors.js              ← Mock payment processor handlers
│       └── audit-logger.js            ← Secret access audit trail
│
├── infrastructure/
│   ├── docker-compose.yml             ← Full stack: Vault + 3 service replicas
│   ├── deploy.sh                      ← Rolling update script (zero-downtime)
│   └── vault/
│       ├── config.hcl                 ← Vault server config + audit logging
│       ├── policies/
│       │   └── payment-service.hcl    ← Least-privilege policy (read-only, 1 path)
│       └── scripts/
│           ├── init-vault.sh          ← Bootstraps Vault: secrets + AppRole
│           └── rotate-secret.sh       ← Credential rotation without restart
│
└── scripts/
    ├── validate-image.sh              ← Proves no secrets in Docker image layers
    ├── validate-logs.sh               ← Proves no secrets in service logs
    └── run-security-scan.sh           ← Trivy + gitleaks security gates
```

## How It Works (Technical Summary)

### Secret Flow (Runtime, Not Build Time)

1. **Vault starts** with KV v2 engine and AppRole auth enabled
2. **vault-init** seeds 6 credentials for 3 payment processors into `secret/flexpay/processors`
3. **vault-init** creates an AppRole (`payment-service`) with a least-privilege policy
4. **vault-init** writes `role_id` and `secret_id` to a shared Docker volume (ephemeral, not in image)
5. **payment-service** reads `role_id` + `secret_id` from the volume at startup
6. **payment-service** authenticates to Vault with AppRole → receives a short-lived token
7. **payment-service** reads `secret/data/flexpay/processors` → loads 6 credentials into memory
8. **Health check** returns `200 OK` → orchestrator begins routing traffic
9. **Every 60 seconds**: service polls Vault for updated secrets (supports rotation without restart)

### What Is Never in the Image or Pipeline

| Item | Location | Why Safe |
|------|----------|----------|
| `PROCESSOR_A_API_KEY` | Vault only | Never written to image/env/logs |
| `PROCESSOR_B_API_KEY` | Vault only | Never written to image/env/logs |
| `PROCESSOR_C_TOKEN` | Vault only | Never written to image/env/logs |
| AppRole `secret_id` | Shared volume | Ephemeral, not in image or CI |
| AppRole `role_id` | Shared volume | Not secret, but still isolated |

### CI/CD Secret Separation

```
Build Phase:          NO Vault tokens, NO payment credentials
                      Only: source code + public base image

Security Gates:       gitleaks (committed secrets scan)
                      Trivy (CVE scan on built image)
                      docker history grep (verify no secrets in layers)

Deploy Phase:         Triggers rolling update script
                      Vault provides secrets to containers at RUNTIME
                      Pipeline never reads or logs payment credentials
```

## PCI-DSS Compliance Notes

| PCI-DSS Requirement | Implementation |
|---------------------|---------------|
| Req 3: Protect stored cardholder data | Credentials stored only in Vault (encrypted at rest) |
| Req 6: Develop secure systems | Multi-stage Docker build, non-root container user |
| Req 7: Restrict access to cardholder data | AppRole policy: read-only, single Vault path |
| Req 8: Identify and authenticate access | AppRole auth — each service instance has unique identity |
| Req 10: Track and monitor all access | Vault audit log records every secret access with HMAC values |
| Req 11: Regularly test security systems | Trivy CVE scanning + gitleaks in CI pipeline |
| Req 12: Maintain information security policy | `DESIGN_DECISIONS.md` documents all trade-offs and rotation procedures |

## Troubleshooting

**Mock credential values visible in vault-init logs**
```bash
# EXPECTED BEHAVIOR for PoC: Running `docker compose logs vault-init` will show
# mock credential values in plaintext. This is intentional — the init script uses
# `vault kv put` with inline mock values for PoC simplicity.
#
# In production: credentials would NEVER appear in CLI arguments or logs.
# Instead, use Vault's "wrapped token" secure introduction pattern:
#   1. Terraform Vault provider provisions secrets (state encrypted at rest)
#   2. Vault Agent sidecar injects secrets via template rendering
#   3. Init containers use wrapped tokens with single-use TTL
# See DESIGN_DECISIONS.md Section 3 for full PoC vs Production comparison.
```

**Service shows unhealthy / 503**
```bash
# Check if Vault is reachable
docker compose -f infrastructure/docker-compose.yml logs vault-init
# Look for "AppRole configured successfully"
```

**Vault sealed after restart**
```bash
# Vault starts in dev mode for this PoC (auto-unsealed)
# For production, auto-unseal via KMS is documented in DESIGN_DECISIONS.md
```

**Port 3000 already in use**
```bash
# The compose file maps replicas to host ports 3000, 3001, 3002 (container port 3000).
# If any of these ports are taken, you'll see a "bind: address already in use" error.
# Find and stop the conflicting process:
lsof -i :3000    # macOS/Linux: shows which process is using port 3000
# Or update the port range in docker-compose.yml:
#   ports: - "4000-4002:3000"
# then access the service on http://localhost:4000/health
```

**gitleaks not found for local scan**
```bash
brew install gitleaks   # macOS
# or use the Docker image:
docker run --rm -v $(pwd):/repo zricethezav/gitleaks:latest detect --source /repo
```
