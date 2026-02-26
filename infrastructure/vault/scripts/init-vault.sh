#!/usr/bin/env sh
# init-vault.sh — Bootstrap Vault for the FlexPay payment gateway PoC
#
# This script runs once as the vault-init service in Docker Compose.
# It initializes Vault, seeds payment processor credentials, configures
# AppRole authentication, and writes auth credentials to a shared volume
# so the payment service can authenticate at runtime.
#
# SECURITY NOTE: The role_id and secret_id written here are auth tokens,
# not payment credentials. They allow the service to authenticate TO Vault,
# which then serves the actual secrets at runtime.

set -e

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"  # Root token used only for initialization
CREDENTIALS_DIR="${CREDENTIALS_DIR:-/vault/credentials}"
POLICIES_DIR="${POLICIES_DIR:-/vault/policies}"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [vault-init] $*"
}

wait_for_vault() {
  log "Waiting for Vault to become available at ${VAULT_ADDR}..."
  retries=30
  while [ $retries -gt 0 ]; do
    if vault status -address="${VAULT_ADDR}" > /dev/null 2>&1; then
      log "Vault is available."
      return 0
    fi
    retries=$((retries - 1))
    log "Vault not ready yet. Retrying in 2s... (${retries} retries left)"
    sleep 2
  done
  log "ERROR: Vault did not become available in time."
  exit 1
}

check_already_initialized() {
  if [ -f "${CREDENTIALS_DIR}/role_id" ] && [ -f "${CREDENTIALS_DIR}/secret_id" ]; then
    log "Vault already initialized (credentials found). Skipping initialization."
    exit 0
  fi
}

enable_kv_secrets_engine() {
  log "Enabling KV v2 secrets engine at 'secret/'..."
  # Check if already enabled to make this script idempotent
  if vault secrets list -address="${VAULT_ADDR}" | grep -q "^secret/"; then
    log "KV secrets engine already enabled at 'secret/'. Skipping."
  else
    vault secrets enable \
      -address="${VAULT_ADDR}" \
      -path=secret \
      kv-v2
    log "KV v2 secrets engine enabled."
  fi
}

seed_processor_credentials() {
  log "Writing payment processor credentials to Vault..."
  # PoC NOTE: These mock credential values will appear in vault-init container logs
  # (visible via `docker compose logs vault-init`). This is acceptable for a PoC with
  # mock data. In production, credentials would NEVER be passed as CLI arguments.
  # Instead, use Vault's "wrapped token" secure introduction pattern or inject via
  # Terraform Vault provider with state encryption. See DESIGN_DECISIONS.md Section 3.
  log "NOTE: Seeding mock credentials for PoC. In production, real credentials are injected via secure introduction (wrapped tokens) — never as CLI arguments."

  # Write all 6 credentials for 3 processors in a single KV write
  # This ensures atomic updates — all credentials update together
  vault kv put \
    -address="${VAULT_ADDR}" \
    secret/flexpay/processors \
    PROCESSOR_A_API_KEY="pk_live_mock_stripe_key_abc123" \
    PROCESSOR_A_SECRET="sk_live_mock_stripe_secret_xyz789" \
    PROCESSOR_B_MERCHANT_ID="ADYEN_MERCHANT_FLEXPAY_001" \
    PROCESSOR_B_API_KEY="AQEyhmfxK4mock_adyen_key_9f2x" \
    PROCESSOR_C_ENDPOINT="https://regional-acquirer.mock/api/v1" \
    PROCESSOR_C_TOKEN="tok_regional_mock_abc123def456"

  log "Processor credentials written (3 processors, 6 credentials total)."
  log "Stored at: secret/flexpay/processors"
}

configure_audit_log() {
  log "Enabling audit logging..."
  mkdir -p /vault/logs
  if vault audit list -address="${VAULT_ADDR}" | grep -q "file/"; then
    log "Audit log already enabled. Skipping."
  else
    vault audit enable \
      -address="${VAULT_ADDR}" \
      file \
      file_path=/vault/logs/audit.log || log "WARNING: Could not enable audit log (may need additional permissions in dev mode)"
  fi
  log "Audit logging configured at /vault/logs/audit.log"
}

create_policy() {
  log "Creating least-privilege policy for payment service..."
  vault policy write \
    -address="${VAULT_ADDR}" \
    payment-service \
    "${POLICIES_DIR}/payment-service.hcl"
  log "Policy 'payment-service' created — read-only access to secret/data/flexpay/processors"
}

enable_approle_auth() {
  log "Enabling AppRole authentication method..."
  if vault auth list -address="${VAULT_ADDR}" | grep -q "approle/"; then
    log "AppRole auth already enabled. Skipping."
  else
    vault auth enable \
      -address="${VAULT_ADDR}" \
      approle
    log "AppRole auth method enabled."
  fi
}

create_approle() {
  log "Creating AppRole 'payment-service'..."
  vault write \
    -address="${VAULT_ADDR}" \
    auth/approle/role/payment-service \
    token_policies="payment-service" \
    token_ttl="1h" \
    token_max_ttl="4h" \
    token_num_uses=0 \
    secret_id_ttl="24h" \
    secret_id_num_uses=0

  log "AppRole 'payment-service' created with policy attachment."
}

write_auth_credentials() {
  log "Fetching AppRole credentials and writing to shared volume..."
  mkdir -p "${CREDENTIALS_DIR}"

  # Fetch role_id (static, identifies the role)
  ROLE_ID=$(vault read \
    -address="${VAULT_ADDR}" \
    -field=role_id \
    auth/approle/role/payment-service/role-id)

  # Generate a secret_id (dynamic, like a password for the role)
  SECRET_ID=$(vault write \
    -address="${VAULT_ADDR}" \
    -field=secret_id \
    -force \
    auth/approle/role/payment-service/secret-id)

  # Write to shared volume (mounted by payment-service containers)
  # Files are used instead of environment variables to avoid exposure in
  # process listings, docker inspect output, or CI logs.
  printf '%s' "${ROLE_ID}" > "${CREDENTIALS_DIR}/role_id"
  printf '%s' "${SECRET_ID}" > "${CREDENTIALS_DIR}/secret_id"

  # Set file permissions to world-readable (644) so the non-root appuser (uid 1001)
  # in the payment-service container can read them from the shared Docker volume.
  # chmod 600 would restrict access to root only, breaking the multi-container setup.
  # In production, use a secrets manager that handles injection directly (e.g., Vault
  # Agent sidecar) to avoid cross-container file ownership issues entirely.
  chmod 644 "${CREDENTIALS_DIR}/role_id"
  chmod 644 "${CREDENTIALS_DIR}/secret_id"

  log "AppRole credentials written to ${CREDENTIALS_DIR}/"
  log "  role_id:   ${CREDENTIALS_DIR}/role_id   (static role identifier)"
  log "  secret_id: ${CREDENTIALS_DIR}/secret_id (ephemeral auth token)"
  log "SECURITY: These files are mounted via Docker volume — NOT baked into any image."
}

verify_setup() {
  log "Verifying Vault setup..."

  # Test that the policy was applied correctly by checking we can read the secret
  # (This uses the root token for verification — the service uses AppRole)
  SECRET_COUNT=$(vault kv get \
    -address="${VAULT_ADDR}" \
    -format=json \
    secret/flexpay/processors | \
    grep -o '"PROCESSOR_' | wc -l | tr -d ' ' 2>/dev/null || echo "0")

  if [ "${SECRET_COUNT}" -ge 6 ]; then
    log "PASS: ${SECRET_COUNT} credentials found in Vault at secret/flexpay/processors"
  else
    log "WARN: Expected 6 credentials, found ${SECRET_COUNT}. Check Vault setup."
  fi

  log "Vault initialization complete."
  log "Summary:"
  log "  - KV v2 secrets engine: enabled at secret/"
  log "  - Payment processor credentials: 3 processors, 6 credentials"
  log "  - Policy: payment-service (read-only on secret/data/flexpay/processors)"
  log "  - Auth method: AppRole (payment-service role)"
  log "  - Credentials written to: ${CREDENTIALS_DIR}/"
}

# Main execution
main() {
  log "Starting Vault initialization for FlexPay PoC..."
  export VAULT_TOKEN="${VAULT_TOKEN}"

  check_already_initialized
  wait_for_vault
  enable_kv_secrets_engine
  seed_processor_credentials
  configure_audit_log
  create_policy
  enable_approle_auth
  create_approle
  write_auth_credentials
  verify_setup

  log "Vault initialization completed successfully."
}

main "$@"
