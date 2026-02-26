---

```
COHERENCE_CHECK_COMPLETE
CHECKS_RUN: 27
INCONSISTENCIES_FOUND: 3
INCONSISTENCIES_FIXED: 3
REMAINING_ISSUES: none

FILES_MODIFIED:
  - .github/workflows/ci-cd.yml
  - README.md
```

## Checks Performed

| # | Check | Result |
|---|---|---|
| 1 | JS module imports vs exports (index.js → all modules) | ✅ All match |
| 2 | vault-client exports vs callers (health.js, processors.js, index.js) | ✅ All match |
| 3 | audit-logger exports vs callers (vault-client, index.js) | ✅ All match |
| 4 | Secret key names: init-vault.sh seeds vs processors.js schema | ✅ 6/6 match |
| 5 | Secret key names: processors.js schema vs rotate-secret.sh validator | ✅ 6/6 match |
| 6 | Vault path: vault-client.js SECRETS_PATH vs policy HCL | ✅ `secret/data/flexpay/processors` |
| 7 | Vault path: init-vault.sh `kv put` CLI path vs API path | ✅ Correct KV v2 path convention |
| 8 | Volume mounts: init-vault.sh POLICIES_DIR vs docker-compose mount | ✅ Both `/vault/policies/` |
| 9 | Volume mounts: init-vault.sh CREDENTIALS_DIR vs payment-service env | ✅ Both `/vault/credentials/` |
| 10 | File names: role_id/secret_id — init vs vault-client vs docker-compose | ✅ Consistent |
| 11 | Port 3000: index.js, docker-compose, Dockerfile, deploy.sh, README | ✅ Consistent |
| 12 | Health endpoint path `/health`: all callers | ✅ Consistent |
| 13 | Image name `flexpay-payment-service`: ci-cd.yml, docker-compose, deploy.sh, validate-image.sh | ✅ Consistent |
| 14 | Service name `payment-service`: docker-compose vs deploy.sh | ✅ Consistent |
| 15 | Container name `flexpay-vault`: docker-compose vs rotate-secret.sh | ✅ Consistent |
| 16 | Vault address `http://vault:8200`: docker-compose, vault-client, init-vault | ✅ Consistent |
| 17 | CI/CD DOCKERFILE_PATH and SERVICE_DIR vs actual file locations | ✅ Correct |
| 18 | CI/CD script presence checks vs actual files | ✅ All 3 scripts exist |
| 19 | **CI/CD artifact upload name vs download name** | ❌ **FIXED** — download used `image-tag && ''` expression (→ `docker-image-`) instead of `short-sha`; added `short-sha` to build outputs |
| 20 | Audit log path `/vault/logs/audit.log`: init-vault.sh vs rotate-secret.sh vs README | ✅ Consistent |
| 21 | Dockerfile HEALTHCHECK vs docker-compose healthcheck command | ✅ Both `wget -qO- http://localhost:3000/health` |
| 22 | deploy.sh COMPOSE_FILE path derivation | ✅ Correct (resolves to infrastructure/docker-compose.yml) |
| 23 | Health response schema: health.js vs README example vs CI/CD docs | ✅ Consistent (README shows abbreviated subset, acceptable) |
| 24 | **README rotation verification: `/health` claimed to "trigger refresh"** | ❌ **FIXED** — `/health` is read-only; corrected to `POST /admin/refresh-secrets` |
| 25 | **README `docker compose stop/start` without compose file** | ❌ **FIXED** — added `-f infrastructure/docker-compose.yml` |
| 26 | All README file paths reference existing files | ✅ All paths exist |
| 27 | Network membership: all services on `backend` network | ✅ All three services included |
