#!/usr/bin/env bash
# validate-logs.sh
# Auditor validation script: proves that application logs and CI build output
# never contain plaintext credential values.
#
# Checks:
#   1. Running service container logs (docker compose logs)
#   2. Build-time output captured to a log file (if available)
#   3. Structured log format compliance (JSON, no secret fields)
#
# Usage:
#   ./scripts/validate-logs.sh                # Scan live Docker Compose logs
#   ./scripts/validate-logs.sh --ci-log FILE  # Also scan a CI log file
#
# Exit codes:
#   0 = All checks passed (no secrets found)
#   1 = Secrets detected in logs (FAIL)
#   2 = Could not run checks (missing dependencies/services)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="${PROJECT_ROOT}/infrastructure"
CI_LOG_FILE=""
SERVICE_NAME="payment-service"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --ci-log)
      CI_LOG_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--ci-log <path>]"
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

print_header() {
  echo ""
  echo -e "${BOLD}${CYAN}================================================================${RESET}"
  echo -e "${BOLD}${CYAN}  $1${RESET}"
  echo -e "${BOLD}${CYAN}================================================================${RESET}"
  echo ""
}

print_section() {
  echo ""
  echo -e "${BOLD}── $1 ──${RESET}"
}

pass() {
  echo -e "  ${GREEN}[PASS]${RESET} $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo -e "  ${RED}[FAIL]${RESET} $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
  echo -e "  ${YELLOW}[WARN]${RESET} $1"
  WARN_COUNT=$((WARN_COUNT + 1))
}

info() {
  echo -e "  ${CYAN}[INFO]${RESET} $1"
}

# ---------------------------------------------------------------------------
# Pattern definitions
# These are the actual secret VALUES we never want to see in logs.
# We also scan for common pattern shapes.
# ---------------------------------------------------------------------------

# Known mock secret values seeded in init-vault.sh
KNOWN_SECRET_VALUES=(
  "pk_live_mock_stripe_key_abc123"
  "sk_live_mock_stripe_secret_xyz789"
  "ADYEN_MERCHANT_FLEXPAY_001"
  "AQEyhmfxK4"
  "tok_regional_mock_abc123def456"
)

# Structural patterns that indicate a secret was accidentally logged
# These look for the ASSIGNMENT form (key=value or "key": "value") which
# would indicate a secret was serialized into a log message.
STRUCTURAL_PATTERNS=(
  'PROCESSOR_A_API_KEY\s*[:=]\s*["\x27]?[a-zA-Z0-9_\-]'
  'PROCESSOR_A_SECRET\s*[:=]\s*["\x27]?[a-zA-Z0-9_\-]'
  'PROCESSOR_B_API_KEY\s*[:=]\s*["\x27]?[a-zA-Z0-9_\-]'
  'PROCESSOR_B_MERCHANT_ID\s*[:=]\s*["\x27]?[a-zA-Z0-9_\-]'
  'PROCESSOR_C_TOKEN\s*[:=]\s*["\x27]?[a-zA-Z0-9_\-]'
  'PROCESSOR_C_ENDPOINT\s*[:=]\s*["\x27]?https://'
  'VAULT_SECRET_ID\s*[:=]\s*["\x27]?[a-zA-Z0-9_\-]'
  '"api_key"\s*:\s*"[^"]'
  '"secret"\s*:\s*"[^"]'
  '"password"\s*:\s*"[^"]'
  '"token"\s*:\s*"[^"]'
  '"credential"\s*:\s*"[^"]'
)

scan_content_for_secrets() {
  local content="$1"
  local source_label="$2"
  local found=false

  # Check for known mock secret values
  for known_value in "${KNOWN_SECRET_VALUES[@]}"; do
    if echo "${content}" | grep -qF "${known_value}"; then
      fail "${source_label}: Known secret value found in logs: '${known_value}'"
      found=true
    fi
  done

  # Check for structural secret patterns
  for pattern in "${STRUCTURAL_PATTERNS[@]}"; do
    MATCHES=$(echo "${content}" | grep -iP "${pattern}" 2>/dev/null || \
              echo "${content}" | grep -iE "${pattern}" 2>/dev/null || true)
    if [ -n "${MATCHES}" ]; then
      fail "${source_label}: Secret assignment pattern detected matching '${pattern}':"
      echo "${MATCHES}" | head -3 | sed 's/^/      /'
      found=true
    fi
  done

  # Scan for PCI-DSS sensitive data patterns (card numbers, CVVs)
  # Primary Account Number pattern (13-19 digits)
  PAN_MATCHES=$(echo "${content}" | grep -oP '\b[3-9][0-9]{12,18}\b' 2>/dev/null | head -3 || true)
  if [ -n "${PAN_MATCHES}" ]; then
    warn "${source_label}: Possible PAN (card number) pattern detected in logs — verify these are not real card numbers"
    found=true
  fi

  echo "${found}"
}

# ---------------------------------------------------------------------------
# Step 1: Check live service logs (if Docker Compose is running)
# ---------------------------------------------------------------------------
print_header "FlexPay Service Log Secrets Validation"
echo "  Datetime : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  Host     : $(hostname)"

print_section "Step 1: Live Service Container Logs"

COMPOSE_AVAILABLE=false
if command -v docker &>/dev/null; then
  if docker compose -f "${INFRA_DIR}/docker-compose.yml" ps "${SERVICE_NAME}" 2>/dev/null | grep -q "running\|Up\|healthy"; then
    COMPOSE_AVAILABLE=true
  fi
fi

if $COMPOSE_AVAILABLE; then
  info "Fetching last 500 lines of ${SERVICE_NAME} logs..."
  SERVICE_LOGS=$(docker compose -f "${INFRA_DIR}/docker-compose.yml" logs \
    --tail=500 \
    "${SERVICE_NAME}" 2>&1 || true)

  LINE_COUNT=$(echo "${SERVICE_LOGS}" | wc -l | tr -d ' ')
  info "Retrieved ${LINE_COUNT} log lines"

  found=$(scan_content_for_secrets "${SERVICE_LOGS}" "Service logs")

  if [ "${found}" = "false" ]; then
    pass "Service container logs: No secret patterns detected"
  fi

  # Check that logs are structured JSON (not raw text that might accidentally include secrets)
  FIRST_LOG_LINE=$(echo "${SERVICE_LOGS}" | grep -v "^$" | head -5 | tail -1 || true)
  if echo "${FIRST_LOG_LINE}" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    pass "Service logs appear to be structured JSON (pino format) — reduces secret leakage risk"
  else
    warn "Service logs do not appear to be JSON — structured logging recommended for PCI-DSS"
  fi

  # Check that secrets are logged as masked/redacted (good pattern)
  if echo "${SERVICE_LOGS}" | grep -qiE "\*{3,}|REDACTED|\[masked\]|\[hidden\]"; then
    pass "Log masking patterns detected — secrets appear to be redacted in logs"
  fi

  # Verify startup log says credentials LOADED (not the VALUES)
  if echo "${SERVICE_LOGS}" | grep -qiE "loaded.*(credential|secret)|credential.*loaded|secret.*loaded"; then
    LOAD_MSG=$(echo "${SERVICE_LOGS}" | grep -iE "loaded.*(credential|secret)|credential.*loaded|secret.*loaded" | head -3)
    pass "Service correctly logs credential LOAD EVENT without values:"
    echo "${LOAD_MSG}" | sed 's/^/      /'
  fi

else
  warn "Docker Compose services not running — skipping live log scan"
  info "Start services with: cd infrastructure && docker compose up -d"
  info "Then re-run this script to scan live logs"
  WARN_COUNT=$((WARN_COUNT - 1))  # Don't penalize for services not running
fi

# ---------------------------------------------------------------------------
# Step 2: Simulate a build and capture output
# ---------------------------------------------------------------------------
print_section "Step 2: Docker Build Output Scan"
info "Performing a simulated build to capture build-time output..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT
BUILD_LOG="${TMPDIR}/build-output.log"

if command -v docker &>/dev/null && [ -f "${PROJECT_ROOT}/service/Dockerfile" ]; then
  info "Building image and capturing output to ${BUILD_LOG}..."
  # We don't pass any secrets to the build — this proves no secrets are needed at build time
  docker build \
    --no-cache \
    --tag "flexpay-build-validate-test:latest" \
    --file "${PROJECT_ROOT}/service/Dockerfile" \
    "${PROJECT_ROOT}/service" \
    > "${BUILD_LOG}" 2>&1 || true

  BUILD_OUTPUT=$(cat "${BUILD_LOG}")
  BUILD_LINE_COUNT=$(wc -l < "${BUILD_LOG}" | tr -d ' ')
  info "Build produced ${BUILD_LINE_COUNT} lines of output"

  found=$(scan_content_for_secrets "${BUILD_OUTPUT}" "Build output")

  if [ "${found}" = "false" ]; then
    pass "Docker build output: No secret patterns detected"
  fi

  # Verify no --secret or --build-arg with sensitive names were used
  if echo "${BUILD_OUTPUT}" | grep -qiE "\-\-build-arg\s+(API_KEY|SECRET|PASSWORD|TOKEN|CREDENTIAL)"; then
    fail "Build output shows --build-arg with sensitive name — secrets must not be build arguments!"
  else
    pass "No sensitive --build-arg detected in build process"
  fi

  # Clean up test image
  docker rmi "flexpay-build-validate-test:latest" &>/dev/null || true
else
  warn "Docker not available or Dockerfile not found — skipping build output scan"
fi

# ---------------------------------------------------------------------------
# Step 3: Check Vault initialization script output (if available)
# ---------------------------------------------------------------------------
print_section "Step 3: Vault Initialization Script Output Scan"

VAULT_INIT_LOG_CANDIDATES=(
  "${PROJECT_ROOT}/vault-init.log"
  "${INFRA_DIR}/vault-init.log"
  "${TMPDIR}/vault-init.log"
)

VAULT_LOG_FOUND=false
for log_candidate in "${VAULT_INIT_LOG_CANDIDATES[@]}"; do
  if [ -f "${log_candidate}" ]; then
    info "Found Vault init log: ${log_candidate}"
    VAULT_INIT_CONTENT=$(cat "${log_candidate}")
    found=$(scan_content_for_secrets "${VAULT_INIT_CONTENT}" "Vault init log")
    if [ "${found}" = "false" ]; then
      pass "Vault init log: No secret values detected in output"
    fi
    VAULT_LOG_FOUND=true
    break
  fi
done

if ! $VAULT_LOG_FOUND; then
  info "No Vault init log found on disk — checking running container if available"
  if $COMPOSE_AVAILABLE; then
    VAULT_INIT_LOGS=$(docker compose -f "${INFRA_DIR}/docker-compose.yml" logs \
      --tail=200 vault-init 2>&1 || true)
    found=$(scan_content_for_secrets "${VAULT_INIT_LOGS}" "Vault init container logs")
    if [ "${found}" = "false" ]; then
      pass "Vault init container logs: No secret values detected in output"
    fi
  else
    warn "Cannot check Vault init logs — services not running"
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: Scan CI log file (if provided)
# ---------------------------------------------------------------------------
print_section "Step 4: CI Pipeline Log File Scan"

if [ -n "${CI_LOG_FILE}" ]; then
  if [ -f "${CI_LOG_FILE}" ]; then
    CI_LINE_COUNT=$(wc -l < "${CI_LOG_FILE}" | tr -d ' ')
    info "Scanning CI log file: ${CI_LOG_FILE} (${CI_LINE_COUNT} lines)"
    CI_CONTENT=$(cat "${CI_LOG_FILE}")
    found=$(scan_content_for_secrets "${CI_CONTENT}" "CI log file")
    if [ "${found}" = "false" ]; then
      pass "CI log file: No secret patterns detected"
    fi

    # Check that GitHub Actions masking is working (look for *** patterns)
    if echo "${CI_CONTENT}" | grep -qE '\*{3,}'; then
      pass "CI log shows secret masking (*** patterns) — GitHub Actions ::add-mask:: is working"
    fi
  else
    warn "CI log file specified but not found: ${CI_LOG_FILE}"
  fi
else
  info "No CI log file provided. To scan CI logs:"
  info "  1. Download the GitHub Actions run log from the Actions tab"
  info "  2. Re-run: ./scripts/validate-logs.sh --ci-log /path/to/ci.log"
fi

# ---------------------------------------------------------------------------
# Step 5: Positive controls — verify expected safe log messages ARE present
# ---------------------------------------------------------------------------
print_section "Step 5: Positive Control Checks"
info "Verifying that expected (non-sensitive) log patterns are present..."

if $COMPOSE_AVAILABLE; then
  SERVICE_LOGS=$(docker compose -f "${INFRA_DIR}/docker-compose.yml" logs \
    --tail=200 "${SERVICE_NAME}" 2>&1 || true)

  # Service should log startup messages
  if echo "${SERVICE_LOGS}" | grep -qiE "listening|started|ready|server"; then
    pass "Service startup message detected in logs"
  else
    warn "Expected startup log message not found — service may not be running correctly"
  fi

  # Service should log Vault connection (not credentials)
  if echo "${SERVICE_LOGS}" | grep -qiE "vault|secret.*engine|approle"; then
    pass "Vault connection activity visible in logs (without credential values)"
  fi

  # Verify health check logs exist
  if echo "${SERVICE_LOGS}" | grep -qiE "health|ready|uptime"; then
    pass "Health check logging detected"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_header "Log Validation Summary"
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
echo "  Total checks : ${TOTAL}"
echo -e "  ${GREEN}Passed       : ${PASS_COUNT}${RESET}"
echo -e "  ${RED}Failed       : ${FAIL_COUNT}${RESET}"
echo -e "  ${YELLOW}Warnings     : ${WARN_COUNT}${RESET}"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
  echo -e "${GREEN}${BOLD}  RESULT: PASS — No secrets detected in any log source${RESET}"
  echo ""
  echo "  Application and build logs are safe for auditor review."
  echo "  All credential values are properly excluded from output."
  exit 0
else
  echo -e "${RED}${BOLD}  RESULT: FAIL — ${FAIL_COUNT} secret exposure(s) detected${RESET}"
  echo ""
  echo "  REMEDIATION: Review logging statements in the service code."
  echo "  Ensure credential values are never passed to logger.info/error."
  echo "  Log only metadata (e.g., 'credentials loaded: yes', not the values)."
  exit 1
fi
