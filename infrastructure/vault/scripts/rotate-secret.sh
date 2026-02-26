#!/usr/bin/env sh
# rotate-secret.sh — Demonstrate zero-downtime secret rotation in Vault
#
# Usage:
#   ./rotate-secret.sh <FIELD_NAME> <NEW_VALUE>
#
# Examples:
#   ./rotate-secret.sh PROCESSOR_A_API_KEY "pk_live_new_key_abc999"
#   ./rotate-secret.sh PROCESSOR_B_API_KEY "AQEyhmfxNewKey123"
#   ./rotate-secret.sh PROCESSOR_C_TOKEN "tok_regional_new_456xyz"
#
# HOW ZERO-DOWNTIME ROTATION WORKS:
#   1. This script writes the new value to Vault (KV v2 creates a new version)
#   2. The OLD version is still accessible to clients reading the previous version
#   3. Running payment service containers will pick up the new value on their
#      next secret refresh cycle (configurable, default: 60 seconds)
#   4. No container restart required — no downtime
#   5. If the new credential is invalid, rollback with:
#      vault kv rollback secret/flexpay/processors -version=<prev_version>
#
# PCI-DSS Audit Trail:
#   Every rotation is logged with timestamp, field name, and operator identity.
#   The Vault audit log captures the full request/response for compliance.

set -e

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
VAULT_CONTAINER="${VAULT_CONTAINER:-flexpay-vault}"
SECRET_PATH="secret/flexpay/processors"

# Determine how to run vault CLI: prefer local binary, fall back to docker exec.
# This allows the script to work without a local Vault installation.
if command -v vault > /dev/null 2>&1; then
  VAULT_CMD="vault"
elif command -v docker > /dev/null 2>&1 && docker inspect "${VAULT_CONTAINER}" > /dev/null 2>&1; then
  # log() is defined below; use echo here since log() isn't available yet
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [rotation] Local 'vault' CLI not found — using docker exec ${VAULT_CONTAINER}"
  VAULT_CMD="docker exec -e VAULT_ADDR=${VAULT_ADDR} -e VAULT_TOKEN=${VAULT_TOKEN} ${VAULT_CONTAINER} vault"
else
  echo "ERROR: Neither 'vault' CLI nor Docker container '${VAULT_CONTAINER}' is available." >&2
  echo "Install the Vault CLI or ensure the flexpay-vault container is running." >&2
  exit 1
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [rotation] $*"
}

log_success() {
  printf "${GREEN}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [rotation] [SUCCESS] %s${NC}\n" "$*"
}

log_warn() {
  printf "${YELLOW}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [rotation] [WARN] %s${NC}\n" "$*"
}

log_error() {
  printf "${RED}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [rotation] [ERROR] %s${NC}\n" "$*" >&2
}

usage() {
  echo "Usage: $0 <FIELD_NAME> <NEW_VALUE>"
  echo ""
  echo "Valid field names:"
  echo "  PROCESSOR_A_API_KEY    - Processor A (Stripe-like) API key"
  echo "  PROCESSOR_A_SECRET     - Processor A secret key"
  echo "  PROCESSOR_B_MERCHANT_ID - Processor B (Adyen-like) merchant ID"
  echo "  PROCESSOR_B_API_KEY    - Processor B API key"
  echo "  PROCESSOR_C_ENDPOINT   - Processor C regional acquirer endpoint"
  echo "  PROCESSOR_C_TOKEN      - Processor C auth token"
  echo ""
  echo "Examples:"
  echo "  $0 PROCESSOR_A_API_KEY 'pk_live_rotated_key_xyz'"
  echo "  $0 PROCESSOR_C_TOKEN 'tok_regional_rotated_abc'"
  exit 1
}

validate_field_name() {
  FIELD="$1"
  case "${FIELD}" in
    PROCESSOR_A_API_KEY|\
    PROCESSOR_A_SECRET|\
    PROCESSOR_B_MERCHANT_ID|\
    PROCESSOR_B_API_KEY|\
    PROCESSOR_C_ENDPOINT|\
    PROCESSOR_C_TOKEN)
      return 0
      ;;
    *)
      log_error "Unknown field name: '${FIELD}'"
      log_error "Run '$0 --help' to see valid field names."
      exit 1
      ;;
  esac
}

get_current_version() {
  # Use -field flag to extract current_version directly — no python3 dependency
  ${VAULT_CMD} kv metadata get \
    -address="${VAULT_ADDR}" \
    -field=current_version \
    "${SECRET_PATH}" 2>/dev/null || echo "unknown"
}

rotate_secret() {
  FIELD_NAME="$1"
  NEW_VALUE="$2"

  log "============================================"
  log "Starting secret rotation"
  log "  Field:    ${FIELD_NAME}"
  log "  Path:     ${SECRET_PATH}"
  log "  Time:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  # SECURITY: Never log the actual credential value
  log "  Value:    [REDACTED — ${#NEW_VALUE} characters]"
  log "============================================"

  # Record the current version before rotation for rollback reference
  PREV_VERSION=$(get_current_version)
  log "Current Vault KV version before rotation: ${PREV_VERSION}"

  # Read all current values so we can patch just the target field
  # This is required for KV v2 — writes replace the entire secret
  # Using vault kv get -field=<name> avoids a python3 / jq dependency
  log "Reading current processor credentials for patch update..."

  # Verify connectivity by reading one field; exit early if Vault is unreachable
  if ! ${VAULT_CMD} kv get -address="${VAULT_ADDR}" -field=PROCESSOR_A_API_KEY "${SECRET_PATH}" > /dev/null 2>&1; then
    log_error "Could not read current secrets from Vault. Is Vault running?"
    exit 1
  fi

  # Extract each field individually — vault kv get -field returns the raw value
  PROCESSOR_A_API_KEY=$(${VAULT_CMD} kv get -address="${VAULT_ADDR}" -field=PROCESSOR_A_API_KEY "${SECRET_PATH}" 2>/dev/null || echo "")
  PROCESSOR_A_SECRET=$(${VAULT_CMD} kv get -address="${VAULT_ADDR}" -field=PROCESSOR_A_SECRET "${SECRET_PATH}" 2>/dev/null || echo "")
  PROCESSOR_B_MERCHANT_ID=$(${VAULT_CMD} kv get -address="${VAULT_ADDR}" -field=PROCESSOR_B_MERCHANT_ID "${SECRET_PATH}" 2>/dev/null || echo "")
  PROCESSOR_B_API_KEY=$(${VAULT_CMD} kv get -address="${VAULT_ADDR}" -field=PROCESSOR_B_API_KEY "${SECRET_PATH}" 2>/dev/null || echo "")
  PROCESSOR_C_ENDPOINT=$(${VAULT_CMD} kv get -address="${VAULT_ADDR}" -field=PROCESSOR_C_ENDPOINT "${SECRET_PATH}" 2>/dev/null || echo "")
  PROCESSOR_C_TOKEN=$(${VAULT_CMD} kv get -address="${VAULT_ADDR}" -field=PROCESSOR_C_TOKEN "${SECRET_PATH}" 2>/dev/null || echo "")

  # Update the target field with the new value
  eval "${FIELD_NAME}=\"${NEW_VALUE}\""

  log "Writing updated credentials to Vault (patch operation)..."
  ${VAULT_CMD} kv put \
    -address="${VAULT_ADDR}" \
    "${SECRET_PATH}" \
    PROCESSOR_A_API_KEY="${PROCESSOR_A_API_KEY}" \
    PROCESSOR_A_SECRET="${PROCESSOR_A_SECRET}" \
    PROCESSOR_B_MERCHANT_ID="${PROCESSOR_B_MERCHANT_ID}" \
    PROCESSOR_B_API_KEY="${PROCESSOR_B_API_KEY}" \
    PROCESSOR_C_ENDPOINT="${PROCESSOR_C_ENDPOINT}" \
    PROCESSOR_C_TOKEN="${PROCESSOR_C_TOKEN}"

  NEW_VERSION=$(get_current_version)
  log_success "Secret rotated successfully!"
  log "  Previous version: ${PREV_VERSION}"
  log "  New version:      ${NEW_VERSION}"
}

print_rollback_instructions() {
  PREV_VERSION="$1"
  NEW_VERSION="$2"
  log "============================================"
  log "ROLLBACK INSTRUCTIONS (if new credential is invalid):"
  log ""
  log "  Option 1 — Vault KV rollback:"
  log "    vault kv rollback -version=${PREV_VERSION} ${SECRET_PATH}"
  log ""
  log "  Option 2 — Manual revert:"
  log "    Run this script again with the previous credential value."
  log ""
  log "  Running services will pick up the rollback on their next"
  log "  refresh cycle (default: 60 seconds) — no restart needed."
  log "============================================"
}

print_verification_instructions() {
  log "============================================"
  log "VERIFICATION STEPS:"
  log ""
  log "  1. Wait for payment services to refresh (up to 60s):"
  log "     watch -n 5 'curl -s http://localhost:3000/health | python3 -m json.tool'"
  log ""
  log "  2. Verify health endpoint still shows 'healthy':"
  log "     curl http://localhost:3000/health"
  log ""
  log "  3. Test a payment with the new credential:"
  log "     curl -X POST http://localhost:3000/pay \\"
  log "       -H 'Content-Type: application/json' \\"
  log "       -d '{\"processor\": \"A\", \"amount\": 1}'"
  log ""
  log "  4. Check audit log for rotation event:"
  log "     docker exec flexpay-vault cat /vault/logs/audit.log | tail -5"
  log "============================================"
}

# Main execution
main() {
  # Handle help flags
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
  fi

  # Validate arguments
  if [ $# -ne 2 ]; then
    log_error "Expected 2 arguments, got $#."
    usage
  fi

  FIELD_NAME="$1"
  NEW_VALUE="$2"

  if [ -z "${NEW_VALUE}" ]; then
    log_error "NEW_VALUE cannot be empty."
    usage
  fi

  export VAULT_TOKEN="${VAULT_TOKEN}"

  validate_field_name "${FIELD_NAME}"

  # Capture prev version before rotation
  PREV_VERSION=$(get_current_version)

  rotate_secret "${FIELD_NAME}" "${NEW_VALUE}"

  NEW_VERSION=$(get_current_version)

  print_rollback_instructions "${PREV_VERSION}" "${NEW_VERSION}"
  print_verification_instructions

  log_success "Rotation complete. No container restart required."
  log "Running containers will pick up the new credential on their next"
  log "Vault poll cycle without any downtime or service interruption."
}

main "$@"
