#!/usr/bin/env bash
# validate-image.sh
# Auditor validation script: proves no secrets are embedded in the Docker image.
# Run this script to satisfy PCI-DSS requirement that build artifacts must not
# contain credential material.
#
# Usage: ./scripts/validate-image.sh [image-name]
# Default image name: flexpay-payment-service

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
IMAGE_NAME="${1:-flexpay-payment-service}"
IMAGE_TAG="${2:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKERFILE="${PROJECT_ROOT}/service/Dockerfile"

# Secret patterns to search for in image layers
# These are the categories of secrets relevant to a payment gateway
SECRET_PATTERNS=(
  "API_KEY="
  "api_key="
  "SECRET="
  "secret="
  "PASSWORD="
  "password="
  "TOKEN="
  "token="
  "PRIVATE_KEY"
  "private_key"
  "CREDENTIALS"
  "credentials"
  "pk_live"
  "sk_live"
  "PROCESSOR_A"
  "PROCESSOR_B"
  "PROCESSOR_C"
  "flexpay"
  "ADYEN"
  "stripe"
  "regional-acquirer"
)

# Counters for summary
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------
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
# Pre-flight checks
# ---------------------------------------------------------------------------
print_header "FlexPay Docker Image Secrets Validation"
echo "  Image    : ${FULL_IMAGE}"
echo "  Datetime : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  Host     : $(hostname)"

print_section "Pre-flight Checks"

if ! command -v docker &>/dev/null; then
  fail "Docker is not installed or not in PATH"
  exit 1
fi
pass "Docker is available ($(docker --version))"

# ---------------------------------------------------------------------------
# Step 1: Build the image (if needed)
# ---------------------------------------------------------------------------
print_section "Step 1: Build Docker Image"

if docker image inspect "${FULL_IMAGE}" &>/dev/null; then
  info "Image ${FULL_IMAGE} already exists locally — skipping build"
  info "To force a fresh build, run: docker rmi ${FULL_IMAGE} first"
else
  info "Building ${FULL_IMAGE} from ${DOCKERFILE} ..."
  if docker build \
      --no-cache \
      --tag "${FULL_IMAGE}" \
      --file "${DOCKERFILE}" \
      "${PROJECT_ROOT}/service" 2>&1; then
    pass "Image built successfully"
  else
    fail "Docker build failed — cannot proceed with validation"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: Inspect image metadata for secret env vars
# ---------------------------------------------------------------------------
print_section "Step 2: Inspect Image Metadata (ENV vars)"
info "Checking ENV instructions baked into the image..."

ENV_OUTPUT=$(docker inspect "${FULL_IMAGE}" --format='{{json .Config.Env}}' 2>/dev/null || echo "[]")
info "Image ENV vars: ${ENV_OUTPUT}"

SECRET_FOUND_IN_ENV=false
for pattern in "${SECRET_PATTERNS[@]}"; do
  if echo "${ENV_OUTPUT}" | grep -qi "${pattern}"; then
    fail "Found suspicious pattern '${pattern}' in image ENV configuration!"
    SECRET_FOUND_IN_ENV=true
  fi
done

if ! $SECRET_FOUND_IN_ENV; then
  pass "No secret patterns found in image ENV configuration"
fi

# ---------------------------------------------------------------------------
# Step 3: Check docker history (build layer commands)
# ---------------------------------------------------------------------------
print_section "Step 3: Inspect Build History (Layer Commands)"
info "Running: docker history ${FULL_IMAGE} --no-trunc"
echo ""

HISTORY_OUTPUT=$(docker history "${FULL_IMAGE}" --no-trunc --format '{{.CreatedBy}}' 2>/dev/null)
echo "${HISTORY_OUTPUT}" | head -30
echo ""

SECRET_FOUND_IN_HISTORY=false
for pattern in "${SECRET_PATTERNS[@]}"; do
  if echo "${HISTORY_OUTPUT}" | grep -qi "${pattern}"; then
    fail "Found suspicious pattern '${pattern}' in image build history!"
    SECRET_FOUND_IN_HISTORY=true
  fi
done

if ! $SECRET_FOUND_IN_HISTORY; then
  pass "No secret patterns found in image build history (layer commands)"
fi

# ---------------------------------------------------------------------------
# Step 4: Export image and scan all layer tarballs
# ---------------------------------------------------------------------------
print_section "Step 4: Deep Scan Image Layer Contents"
info "Exporting image to temporary directory and scanning all layers..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

EXPORT_PATH="${TMPDIR}/image-export"
mkdir -p "${EXPORT_PATH}"

info "Saving image to tar archive..."
docker save "${FULL_IMAGE}" | tar -xf - -C "${EXPORT_PATH}" 2>/dev/null
info "Image exported. Scanning layer archives..."

# Build grep pattern from array
GREP_PATTERN=$(IFS='|'; echo "${SECRET_PATTERNS[*]}" | sed 's/=//g' | tr '[:upper:]' '[:lower:]')
LAYER_GREP_PATTERN="api.key|secret|password|token|private.key|credential|pk_live|sk_live|processor_[abc]|flexpay|adyen|stripe|regional.acquirer"

LAYER_SECRETS_FOUND=false
LAYERS_SCANNED=0

# Find all layer tarballs and scan their contents
while IFS= read -r -d '' layer_tar; do
  LAYERS_SCANNED=$((LAYERS_SCANNED + 1))
  LAYER_NAME=$(basename "$(dirname "${layer_tar}")")

  # Extract layer and grep for secrets
  LAYER_CONTENT=$(tar -tf "${layer_tar}" 2>/dev/null || true)

  # Scan file names in the layer
  if echo "${LAYER_CONTENT}" | grep -qiE "(\.env$|\.pem$|\.key$|credentials|secrets\.json)"; then
    fail "Layer ${LAYER_NAME}: Found suspicious file names: $(echo "${LAYER_CONTENT}" | grep -iE "(\.env$|\.pem$|\.key$|credentials|secrets\.json)")"
    LAYER_SECRETS_FOUND=true
  fi

  # Scan text file contents within the layer (extract and grep)
  CONTENT_HITS=$(tar -xOf "${layer_tar}" 2>/dev/null \
    | strings 2>/dev/null \
    | grep -iE "${LAYER_GREP_PATTERN}=" \
    | grep -v "^#" \
    | grep -v "example\|placeholder\|your.key.here\|changeme\|REPLACE" \
    || true)

  if [ -n "${CONTENT_HITS}" ]; then
    fail "Layer ${LAYER_NAME}: Potential secrets found in layer content!"
    echo "    Matches:"
    echo "${CONTENT_HITS}" | head -5 | sed 's/^/      /'
    LAYER_SECRETS_FOUND=true
  fi
done < <(find "${EXPORT_PATH}" -name "layer.tar" -print0 2>/dev/null)

# Also check the manifest and config JSON
CONFIG_FILE=$(find "${EXPORT_PATH}" -name "*.json" ! -name "manifest.json" -print | head -1)
if [ -n "${CONFIG_FILE}" ]; then
  CONFIG_CONTENT=$(cat "${CONFIG_FILE}" 2>/dev/null || echo "{}")
  if echo "${CONFIG_CONTENT}" | grep -qiE "${LAYER_GREP_PATTERN}="; then
    fail "Potential secrets found in image configuration JSON!"
    LAYER_SECRETS_FOUND=true
  else
    pass "Image configuration JSON contains no secret patterns"
  fi
fi

info "Scanned ${LAYERS_SCANNED} layer(s)"

if ! $LAYER_SECRETS_FOUND; then
  pass "No secret patterns found in any image layer contents"
fi

# ---------------------------------------------------------------------------
# Step 5: Verify non-root user
# ---------------------------------------------------------------------------
print_section "Step 5: Verify Security Hardening"

IMAGE_USER=$(docker inspect "${FULL_IMAGE}" --format='{{.Config.User}}' 2>/dev/null || echo "")
if [ -z "${IMAGE_USER}" ] || [ "${IMAGE_USER}" = "root" ] || [ "${IMAGE_USER}" = "0" ]; then
  fail "Image runs as root user (PCI-DSS violation: containers should not run as root)"
else
  pass "Image runs as non-root user: '${IMAGE_USER}'"
fi

# Check for HEALTHCHECK
HEALTHCHECK=$(docker inspect "${FULL_IMAGE}" --format='{{.Config.Healthcheck}}' 2>/dev/null || echo "")
if [ -z "${HEALTHCHECK}" ] || [ "${HEALTHCHECK}" = "<nil>" ]; then
  warn "No HEALTHCHECK defined in image (recommended for zero-downtime deployments)"
else
  pass "HEALTHCHECK is defined in image: ${HEALTHCHECK}"
fi

# Verify multi-stage build artifact (image should not contain build tools like npm)
BUILD_TOOLS_PRESENT=$(docker run --rm --entrypoint="" "${FULL_IMAGE}" which npm 2>/dev/null || echo "")
if [ -n "${BUILD_TOOLS_PRESENT}" ]; then
  warn "Build tool 'npm' found in production image — consider stricter multi-stage build"
else
  pass "Build tool 'npm' not present in production image (multi-stage build working)"
fi

# ---------------------------------------------------------------------------
# Step 6: Runtime smoke test (secrets NOT in environment)
# ---------------------------------------------------------------------------
print_section "Step 6: Runtime Environment Smoke Test"
info "Starting container without Vault to verify it doesn't contain hardcoded secrets..."

# Run container briefly and inspect its environment
CONTAINER_ENV=$(docker run --rm \
  --entrypoint="" \
  "${FULL_IMAGE}" \
  env 2>/dev/null || echo "")

info "Environment variables visible in running container:"
echo "${CONTAINER_ENV}" | grep -v "^PATH=\|^NODE_\|^HOME=\|^HOSTNAME=\|^TERM=\|^USER=" | head -20 | sed 's/^/    /'

RUNTIME_SECRET_FOUND=false
for pattern in "${SECRET_PATTERNS[@]}"; do
  if echo "${CONTAINER_ENV}" | grep -qi "${pattern}"; then
    fail "Found '${pattern}' in container runtime environment!"
    RUNTIME_SECRET_FOUND=true
  fi
done

if ! $RUNTIME_SECRET_FOUND; then
  pass "No payment secret patterns visible in container runtime environment"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_header "Validation Summary"
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
echo "  Total checks : ${TOTAL}"
echo -e "  ${GREEN}Passed       : ${PASS_COUNT}${RESET}"
echo -e "  ${RED}Failed       : ${FAIL_COUNT}${RESET}"
echo -e "  ${YELLOW}Warnings     : ${WARN_COUNT}${RESET}"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
  echo -e "${GREEN}${BOLD}  RESULT: PASS — Image is free of embedded secrets${RESET}"
  echo ""
  echo "  This image is safe to push to a container registry."
  echo "  All payment credentials must be injected at runtime via Vault."
  exit 0
else
  echo -e "${RED}${BOLD}  RESULT: FAIL — ${FAIL_COUNT} check(s) failed${RESET}"
  echo ""
  echo "  DO NOT push this image to a container registry."
  echo "  Investigate the failures above before proceeding."
  exit 1
fi
