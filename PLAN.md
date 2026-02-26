Now I have a complete picture of the existing codebase. Let me produce the implementation plan identifying what exists, what has critical bugs, and what needs improvement to maximize the score.

# Implementation Plan

## Challenge Analysis

**Challenge**: Build a PCI-DSS compliant secrets management PoC for FlexPay's payment gateway service.

**Evaluation Criteria (100 pts total)**:
| Criterion | Points | Priority |
|---|---|---|
| Secrets Management Implementation | 25 | HIGH |
| Design Decisions & Technical Communication | 25 | HIGH |
| CI/CD Pipeline Security & Compliance | 20 | HIGH |
| Zero-Downtime Deployment Design | 20 | HIGH |
| Code Quality, Documentation & Reproducibility | 10 | MEDIUM |

**Current State**: The repository already has substantial implementation across ALL deliverables. However, there are **critical bugs** that would prevent the solution from actually running, plus several improvements needed for top-quartile scoring.

## Architecture

Already implemented: HashiCorp Vault + Docker Compose + Node.js Express + GitHub Actions. The architecture is solid and well-chosen. No changes needed.

## Critical Bugs Found

1. **CRITICAL BUG - vault-client.js reads env vars, but docker-compose passes file paths**: The service reads `process.env.VAULT_ROLE_ID` and `process.env.VAULT_SECRET_ID` (env vars), but docker-compose sets `VAULT_ROLE_ID_FILE` and `VAULT_SECRET_ID_FILE` (file paths). The service will crash on startup because `VAULT_ROLE_ID` is undefined.

2. **CRITICAL BUG - No package-lock.json**: The Dockerfile runs `npm ci` which **requires** `package-lock.json`. Build will fail.

3. **MEDIUM BUG - init-vault.sh uses python3**: The `verify_setup()` function calls `python3` but the `hashicorp/vault` container image doesn't include Python. This step will silently fail or error out.

4. **MEDIUM BUG - Vault init policy path**: `create_policy` reads from `${POLICIES_DIR}/payment-service.hcl` but the docker-compose mounts the file to `/payment-service.hcl` (root), not to a policies directory.

## Project Structure

```
yuno-challenge-jalejor/          (existing repo)
├── README.md                     ← EXISTS, needs minor port fix
├── DESIGN_DECISIONS.md           ← EXISTS, comprehensive (good)
├── .github/workflows/ci-cd.yml  ← EXISTS, solid
├── .gitleaks.toml                ← EXISTS
├── .gitignore                    ← EXISTS
├── service/
│   ├── Dockerfile                ← EXISTS, good
│   ├── package.json              ← EXISTS
│   ├── package-lock.json         ← MISSING (critical)
│   ├── .dockerignore             ← EXISTS
│   └── src/
│       ├── index.js              ← EXISTS
│       ├── vault-client.js       ← EXISTS, needs file-reading fix
│       ├── health.js             ← EXISTS
│       ├── processors.js         ← EXISTS
│       └── audit-logger.js       ← EXISTS
├── infrastructure/
│   ├── docker-compose.yml        ← EXISTS, needs minor fix
│   ├── deploy.sh                 ← EXISTS
│   └── vault/
│       ├── config.hcl            ← EXISTS
│       ├── policies/
│       │   └── payment-service.hcl ← EXISTS
│       └── scripts/
│           ├── init-vault.sh     ← EXISTS, needs fixes
│           └── rotate-secret.sh  ← EXISTS
└── scripts/
    ├── validate-image.sh         ← EXISTS
    ├── validate-logs.sh          ← EXISTS
    └── run-security-scan.sh      ← EXISTS
```

## Tasks

### TASK 1: Fix Critical Bug — vault-client.js File-Based Credential Reading
**files**: `service/src/vault-client.js`
**depends_on**: none
**description**:
The vault-client.js currently reads `VAULT_ROLE_ID` and `VAULT_SECRET_ID` from environment variables (lines 18-19), but docker-compose.yml passes `VAULT_ROLE_ID_FILE` and `VAULT_SECRET_ID_FILE` which are file paths. The service will crash because `VAULT_ROLE_ID` is undefined.

**Fix**:
- Add a `readFileSync` helper at the top of vault-client.js that reads credential values from files
- Change lines 18-19 to first try reading from `VAULT_ROLE_ID_FILE`/`VAULT_SECRET_ID_FILE` environment variables (which contain file paths), falling back to `VAULT_ROLE_ID`/`VAULT_SECRET_ID` direct env vars
- Implementation:
```javascript
const fs = require('fs');

function readCredential(envVar, fileEnvVar) {
  // Prefer file-based reading (more secure — avoids exposure in docker inspect/process listings)
  const filePath = process.env[fileEnvVar];
  if (filePath) {
    try {
      return fs.readFileSync(filePath, 'utf8').trim();
    } catch (err) {
      // Fall through to env var
    }
  }
  return process.env[envVar] || null;
}

const VAULT_ROLE_ID = readCredential('VAULT_ROLE_ID', 'VAULT_ROLE_ID_FILE');
const VAULT_SECRET_ID = readCredential('VAULT_SECRET_ID', 'VAULT_SECRET_ID_FILE');
```
- This is the **most critical fix** — without it, `docker compose up` will fail entirely

**Scoring criteria addressed**: Secrets Management (25pts) — service must actually retrieve credentials at runtime; Code Quality (10pts) — solution must actually work

### TASK 2: Generate package-lock.json
**files**: `service/package-lock.json`
**depends_on**: none
**description**:
The Dockerfile uses `npm ci --only=production` which **requires** `package-lock.json` to exist. Without it, the Docker build fails immediately.

**Fix**:
- Run `cd service && npm install` to generate `package-lock.json`
- Commit the lock file to the repo
- This is a **blocking bug** — nothing works without this file

**Scoring criteria addressed**: Code Quality & Reproducibility (10pts) — evaluator must be able to build the image

### TASK 3: Fix init-vault.sh — Policy Path and Python Dependency
**files**: `infrastructure/vault/scripts/init-vault.sh`
**depends_on**: none
**description**:
Two bugs in init-vault.sh:

1. **Policy path mismatch**: `create_policy()` reads from `${POLICIES_DIR}/payment-service.hcl` (defaults to `/vault/policies/payment-service.hcl`), but docker-compose.yml mounts the policy file to `/payment-service.hcl` (root). Either fix the mount path in docker-compose.yml or fix the default POLICIES_DIR.

   **Fix**: Change the docker-compose vault-init volume mount from `./vault/policies/payment-service.hcl:/payment-service.hcl:ro` to `./vault/policies/payment-service.hcl:/vault/policies/payment-service.hcl:ro`, OR change `POLICIES_DIR` default to `/` in init-vault.sh. The cleanest fix is updating docker-compose to mount to `/vault/policies/payment-service.hcl`.

2. **python3 not in Vault container**: The `verify_setup()` function calls `python3` to parse JSON, but `hashicorp/vault` Alpine image doesn't have Python. Replace with `jq` (available in Vault image) or `grep`-based counting.

   **Fix**: Replace the python3 command with:
   ```sh
   SECRET_COUNT=$(vault kv get -address="${VAULT_ADDR}" -format=json secret/flexpay/processors | \
     grep -o '"PROCESSOR_' | wc -l | tr -d ' ')
   ```
   Or simply use vault's `-field` option to verify specific fields exist.

**Scoring criteria addressed**: Code Quality & Reproducibility (10pts), Secrets Management (25pts)

### TASK 4: Fix docker-compose.yml — Volume Mounts and Port Mapping
**files**: `infrastructure/docker-compose.yml`
**depends_on**: none
**description**:
Several issues in docker-compose.yml:

1. **Policy mount path**: The vault-init service mounts `./vault/policies/payment-service.hcl:/payment-service.hcl:ro` but init-vault.sh expects it at `/vault/policies/payment-service.hcl`. Fix the mount to match.

2. **Port mapping `3000-3002:3000`**: With `deploy.replicas: 3`, Docker Compose (non-Swarm) doesn't use the deploy block. When using `--scale`, port range mapping `3000-3002:3000` should work but may cause port conflicts. Consider adding an nginx reverse proxy/load balancer service for cleaner access, OR document that individual replicas are accessible at different ports.

   For simplicity, keep the port range mapping but add a comment explaining the behavior.

3. **The `deploy` block is ignored in non-Swarm mode**: Docker Compose without Swarm ignores `deploy.replicas`, `update_config`, etc. The README and deploy.sh already handle this correctly via `--scale`, but add a clearer comment.

**Scoring criteria addressed**: Zero-Downtime Deployment (20pts), Code Quality (10pts)

### TASK 5: End-to-End Validation and Smoke Test
**files**: none (validation only)
**depends_on**: TASK 1, TASK 2, TASK 3, TASK 4
**description**:
After all fixes are applied, run the full stack to validate everything works:

1. `cd infrastructure && docker compose up -d`
2. Wait for services to become healthy: `docker compose ps`
3. Test health endpoint: `curl http://localhost:3000/health`
4. Test mock payment: `curl -X POST http://localhost:3000/pay -H "Content-Type: application/json" -d '{"processor":"A","amount":100}'`
5. Run `./scripts/validate-image.sh` to confirm no secrets in image
6. Test secret rotation: `./infrastructure/vault/scripts/rotate-secret.sh PROCESSOR_A_API_KEY "pk_live_rotated_test_123"`
7. Verify service picks up new secret (wait 60s or hit `/admin/refresh-secrets`)
8. Run `docker compose down -v` to clean up

If any step fails, debug and fix before marking complete.

**Scoring criteria addressed**: ALL criteria — this validates the entire submission works end-to-end

### TASK 6: README Polish — Fix Port References and Add Troubleshooting
**files**: `README.md`
**depends_on**: TASK 5
**description**:
Minor README improvements after validation:

1. Fix Quick Start port references if they changed during testing
2. Add note about first-run time (Vault image pull may take a minute)
3. Ensure all validation commands use the correct paths
4. Add a "Prerequisites Verification" section with version-check commands
5. Ensure the `docker compose down -v` cleanup step is clearly documented

**Scoring criteria addressed**: Code Quality, Documentation & Reproducibility (10pts)

## Acceptance Criteria

1. **[Secrets Management - 25pts]**: `docker compose up -d` succeeds. Service authenticates to Vault via AppRole, fetches 6 credentials for 3 processors at runtime. `validate-image.sh` passes. Vault policy is least-privilege (read-only, single path).

2. **[CI/CD Security - 20pts]**: GitHub Actions workflow includes gitleaks + Trivy + layer inspection. Pipeline YAML references zero payment credentials. Build output contains no secrets.

3. **[Zero-Downtime Deployment - 20pts]**: `deploy.sh` performs rolling update. Health check returns 503 until secrets loaded, 200 after. At least 1 replica remains healthy during update.

4. **[Design Decisions - 25pts]**: DESIGN_DECISIONS.md covers: Vault choice with alternatives, per-requirement satisfaction, PoC vs production trade-offs (8 in table), 8-step rotation workflow, 5 failure scenarios, multi-environment isolation.

5. **[Code Quality & Reproducibility - 10pts]**: Evaluator runs `docker compose up -d` + `curl localhost:3000/health` and gets a working response. All validation scripts are executable and pass. Repo structure is clean.
