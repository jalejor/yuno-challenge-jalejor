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
│  │  replica-1 :3001   replica-2 :3002   replica-3 :3003    │  │
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

## Quick Start

```bash
# 1. Clone the repo
git clone <repo> && cd flexpay-secrets-poc

# 2. Start the full stack (Vault + Payment Service — 3 replicas)
cd infrastructure && docker compose up -d

# 3. Wait for all services to become healthy (~30 seconds)
docker compose ps  # All services should show "healthy"

# 4. Test the health endpoint (returns 503 until secrets are loaded)
curl http://localhost:3000/health

# Expected response:
# {"status":"healthy","secretsLoaded":true,"processors":["A","B","C"],"uptime":12}

# 5. Test a mock payment
curl -X POST http://localhost:3000/pay \
  -H "Content-Type: application/json" \
  -d '{"processor": "A", "amount": 100}'
```

> **Note**: The service returns HTTP 503 on `/health` until it has successfully authenticated to Vault and retrieved all credentials. This gates traffic during rolling deployments.

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
# Check running service logs for any credential leakage
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
# or trigger immediate check:
curl http://localhost:3000/health

# Expected: Service remains healthy, continues processing payments
# with the new credential — no restart required
```

### 6. Inspect Vault audit log

```bash
# View all secret access events (Vault audit backend)
docker exec $(docker compose -f infrastructure/docker-compose.yml ps -q vault) \
  cat /vault/logs/audit.log | jq .

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
cd infrastructure && docker compose down -v
# -v removes volumes (clears Vault data and AppRole credentials)
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
# The compose file maps replicas to 3001, 3002, 3003 individually
# An nginx or traefik load balancer can front them on 3000
# Or: change PORT in docker-compose.yml
```

**gitleaks not found for local scan**
```bash
brew install gitleaks   # macOS
# or use the Docker image:
docker run --rm -v $(pwd):/repo zricethezav/gitleaks:latest detect --source /repo
```
