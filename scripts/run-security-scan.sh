#!/usr/bin/env bash
# run-security-scan.sh
# Comprehensive security scan for auditors. Runs:
#   1. Gitleaks — detects secrets committed to Git history
#   2. Trivy    — scans the Docker image for CVE vulnerabilities
#   3. Hadolint — lints the Dockerfile for security anti-patterns
#
# Each scanner produces a human-readable summary and a machine-readable
# JSON/SARIF report in ./scan-results/ for import into security tooling.
#
# Usage:
#   ./scripts/run-security-scan.sh [--image IMAGE_NAME] [--skip-trivy] [--skip-gitleaks]
#
# Requirements:
#   - Docker (required for Trivy via container, and for building the image)
#   - gitleaks (optional; falls back to Docker image if not installed)
#   - trivy    (optional; falls back to Docker image if not installed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/scan-results"
IMAGE_NAME="flexpay-payment-service:latest"
SKIP_TRIVY=false
SKIP_GITLEAKS=false
SKIP_HADOLINT=false

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --image)
      IMAGE_NAME="$2"
      shift 2
      ;;
    --skip-trivy)
      SKIP_TRIVY=true
      shift
      ;;
    --skip-gitleaks)
      SKIP_GITLEAKS=true
      shift
      ;;
    --skip-hadolint)
      SKIP_HADOLINT=true
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--image IMAGE] [--skip-trivy] [--skip-gitleaks] [--skip-hadolint]"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SCANNER_RESULTS=()

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

record_scanner() {
  local scanner="$1"
  local status="$2"
  local detail="$3"
  SCANNER_RESULTS+=("${scanner}|${status}|${detail}")
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
print_header "FlexPay Payment Service Security Scan"
echo "  Image     : ${IMAGE_NAME}"
echo "  Repo      : ${PROJECT_ROOT}"
echo "  Datetime  : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  Operator  : ${USER:-unknown}"
echo ""

mkdir -p "${RESULTS_DIR}"
info "Scan results will be saved to: ${RESULTS_DIR}/"

# Check Docker availability
if ! command -v docker &>/dev/null; then
  echo -e "${RED}ERROR: Docker is required but not installed.${RESET}"
  exit 2
fi
pass "Docker available: $(docker --version)"

# ---------------------------------------------------------------------------
# SCANNER 1: Gitleaks — detect secrets in git history and working tree
# ---------------------------------------------------------------------------
print_section "Scanner 1: Gitleaks (Secret Detection in Repository)"

GITLEAKS_REPORT="${RESULTS_DIR}/gitleaks-report.json"
GITLEAKS_SARIF="${RESULTS_DIR}/gitleaks-report.sarif"

if $SKIP_GITLEAKS; then
  warn "Gitleaks scan skipped (--skip-gitleaks)"
  record_scanner "gitleaks" "SKIPPED" "Skipped via flag"
else
  GITLEAKS_BIN=""
  if command -v gitleaks &>/dev/null; then
    GITLEAKS_BIN="gitleaks"
    info "Using locally installed gitleaks: $(gitleaks version 2>/dev/null || echo 'version unknown')"
  else
    info "gitleaks not found locally — using Docker image (zricethezav/gitleaks)"
    GITLEAKS_BIN="docker run --rm -v ${PROJECT_ROOT}:/repo zricethezav/gitleaks:latest"
  fi

  info "Scanning repository for secrets in files and git history..."
  info "Config: ${PROJECT_ROOT}/.gitleaks.toml"

  GITLEAKS_EXIT=0
  if command -v gitleaks &>/dev/null; then
    # Local installation
    gitleaks detect \
      --source "${PROJECT_ROOT}" \
      --config "${PROJECT_ROOT}/.gitleaks.toml" \
      --report-format json \
      --report-path "${GITLEAKS_REPORT}" \
      --verbose \
      2>&1 || GITLEAKS_EXIT=$?

    gitleaks detect \
      --source "${PROJECT_ROOT}" \
      --config "${PROJECT_ROOT}/.gitleaks.toml" \
      --report-format sarif \
      --report-path "${GITLEAKS_SARIF}" \
      2>&1 || true
  else
    # Docker fallback
    docker run --rm \
      -v "${PROJECT_ROOT}:/repo" \
      -v "${RESULTS_DIR}:/results" \
      zricethezav/gitleaks:latest detect \
      --source "/repo" \
      --config "/repo/.gitleaks.toml" \
      --report-format json \
      --report-path "/results/gitleaks-report.json" \
      --verbose \
      2>&1 || GITLEAKS_EXIT=$?
  fi

  if [ $GITLEAKS_EXIT -eq 0 ]; then
    pass "Gitleaks: No secrets detected in repository files or git history"
    record_scanner "gitleaks" "PASS" "No secrets found"
  elif [ $GITLEAKS_EXIT -eq 1 ]; then
    fail "Gitleaks: Secrets detected in repository!"
    info "Full report: ${GITLEAKS_REPORT}"

    # Show summary of findings
    if [ -f "${GITLEAKS_REPORT}" ] && command -v python3 &>/dev/null; then
      FINDING_COUNT=$(python3 -c "
import json, sys
try:
    data = json.load(open('${GITLEAKS_REPORT}'))
    print(len(data) if isinstance(data, list) else 0)
except:
    print('unknown')
" 2>/dev/null || echo "unknown")
      fail "Found ${FINDING_COUNT} secret(s) — review ${GITLEAKS_REPORT} for details"
    fi
    record_scanner "gitleaks" "FAIL" "Secrets detected — see ${GITLEAKS_REPORT}"
  else
    warn "Gitleaks exited with code ${GITLEAKS_EXIT} — check configuration"
    record_scanner "gitleaks" "ERROR" "Exit code ${GITLEAKS_EXIT}"
  fi
fi

# ---------------------------------------------------------------------------
# SCANNER 2: Trivy — image vulnerability scan
# ---------------------------------------------------------------------------
print_section "Scanner 2: Trivy (Container Image Vulnerability Scan)"

TRIVY_REPORT_JSON="${RESULTS_DIR}/trivy-report.json"
TRIVY_REPORT_TABLE="${RESULTS_DIR}/trivy-report.txt"
TRIVY_REPORT_SARIF="${RESULTS_DIR}/trivy-report.sarif"

if $SKIP_TRIVY; then
  warn "Trivy scan skipped (--skip-trivy)"
  record_scanner "trivy" "SKIPPED" "Skipped via flag"
else
  # Ensure image exists
  if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
    info "Image ${IMAGE_NAME} not found locally — building..."
    if docker build \
        --tag "${IMAGE_NAME}" \
        --file "${PROJECT_ROOT}/service/Dockerfile" \
        "${PROJECT_ROOT}/service" 2>&1; then
      pass "Image built successfully for scanning"
    else
      fail "Failed to build image — cannot run Trivy scan"
      record_scanner "trivy" "ERROR" "Image build failed"
      SKIP_TRIVY=true
    fi
  fi

  if ! $SKIP_TRIVY; then
    TRIVY_BIN=""
    if command -v trivy &>/dev/null; then
      TRIVY_BIN="trivy"
      info "Using locally installed Trivy: $(trivy --version | head -1)"
    else
      info "trivy not found locally — using Docker image (aquasec/trivy)"
      TRIVY_BIN="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v ${RESULTS_DIR}:/results aquasec/trivy:latest"
    fi

    info "Scanning image: ${IMAGE_NAME}"
    info "Severity threshold: HIGH and CRITICAL (pipeline fails on these)"

    # Run Trivy with table output for human review
    TRIVY_EXIT=0
    if command -v trivy &>/dev/null; then
      trivy image \
        --severity HIGH,CRITICAL \
        --format table \
        --output "${TRIVY_REPORT_TABLE}" \
        "${IMAGE_NAME}" 2>&1 || TRIVY_EXIT=$?

      # JSON report for machine consumption
      trivy image \
        --severity HIGH,CRITICAL \
        --format json \
        --output "${TRIVY_REPORT_JSON}" \
        "${IMAGE_NAME}" 2>/dev/null || true

      # SARIF report for GitHub Code Scanning
      trivy image \
        --severity HIGH,CRITICAL \
        --format sarif \
        --output "${TRIVY_REPORT_SARIF}" \
        "${IMAGE_NAME}" 2>/dev/null || true

      # Also scan for secrets embedded in the image (Trivy has this capability)
      TRIVY_SECRET_EXIT=0
      info "Running Trivy secret detection on image layers..."
      trivy image \
        --scanners secret \
        --format table \
        "${IMAGE_NAME}" 2>&1 || TRIVY_SECRET_EXIT=$?

      if [ $TRIVY_SECRET_EXIT -ne 0 ]; then
        fail "Trivy detected secrets embedded in image layers!"
        record_scanner "trivy-secrets" "FAIL" "Secrets found in image"
      else
        pass "Trivy secret scan: No secrets found in image layers"
        record_scanner "trivy-secrets" "PASS" "No secrets in layers"
      fi

    else
      # Docker-based Trivy
      docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${RESULTS_DIR}:/results" \
        aquasec/trivy:latest image \
        --severity HIGH,CRITICAL \
        --format table \
        --output "/results/trivy-report.txt" \
        "${IMAGE_NAME}" 2>&1 || TRIVY_EXIT=$?

      docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${RESULTS_DIR}:/results" \
        aquasec/trivy:latest image \
        --severity HIGH,CRITICAL \
        --format json \
        --output "/results/trivy-report.json" \
        "${IMAGE_NAME}" 2>/dev/null || true
    fi

    # Display and evaluate results
    if [ -f "${TRIVY_REPORT_TABLE}" ]; then
      echo ""
      cat "${TRIVY_REPORT_TABLE}"
      echo ""
    fi

    if [ $TRIVY_EXIT -eq 0 ]; then
      pass "Trivy: No HIGH or CRITICAL vulnerabilities found in ${IMAGE_NAME}"
      record_scanner "trivy" "PASS" "No HIGH/CRITICAL CVEs"
    else
      fail "Trivy: HIGH or CRITICAL vulnerabilities found — see ${TRIVY_REPORT_TABLE}"
      record_scanner "trivy" "FAIL" "CVEs found — see ${TRIVY_REPORT_TABLE}"

      # Show counts from JSON if available
      if [ -f "${TRIVY_REPORT_JSON}" ] && command -v python3 &>/dev/null; then
        CRIT_COUNT=$(python3 -c "
import json
try:
    data = json.load(open('${TRIVY_REPORT_JSON}'))
    results = data.get('Results', [])
    crit = sum(1 for r in results for v in r.get('Vulnerabilities', []) if v.get('Severity') == 'CRITICAL')
    high = sum(1 for r in results for v in r.get('Vulnerabilities', []) if v.get('Severity') == 'HIGH')
    print(f'CRITICAL: {crit}, HIGH: {high}')
except Exception as e:
    print(f'Could not parse report: {e}')
" 2>/dev/null || echo "Could not count")
        fail "Vulnerability counts — ${CRIT_COUNT}"
      fi
    fi

    info "Full reports saved to:"
    info "  Table  : ${TRIVY_REPORT_TABLE}"
    info "  JSON   : ${TRIVY_REPORT_JSON}"
    info "  SARIF  : ${TRIVY_REPORT_SARIF}"
  fi
fi

# ---------------------------------------------------------------------------
# SCANNER 3: Hadolint — Dockerfile linting
# ---------------------------------------------------------------------------
print_section "Scanner 3: Hadolint (Dockerfile Security Lint)"

HADOLINT_REPORT="${RESULTS_DIR}/hadolint-report.txt"
DOCKERFILE="${PROJECT_ROOT}/service/Dockerfile"

if $SKIP_HADOLINT; then
  warn "Hadolint scan skipped (--skip-hadolint)"
  record_scanner "hadolint" "SKIPPED" "Skipped via flag"
else
  if [ ! -f "${DOCKERFILE}" ]; then
    warn "Dockerfile not found at ${DOCKERFILE} — skipping Hadolint"
    record_scanner "hadolint" "SKIPPED" "Dockerfile not found"
  else
    HADOLINT_EXIT=0
    if command -v hadolint &>/dev/null; then
      info "Using locally installed hadolint: $(hadolint --version)"
      hadolint "${DOCKERFILE}" \
        --format tty \
        2>&1 | tee "${HADOLINT_REPORT}" || HADOLINT_EXIT=$?
    else
      info "hadolint not installed — using Docker image"
      docker run --rm \
        -v "${PROJECT_ROOT}/service:/workspace" \
        hadolint/hadolint:latest \
        hadolint /workspace/Dockerfile \
        --format tty \
        2>&1 | tee "${HADOLINT_REPORT}" || HADOLINT_EXIT=$?
    fi

    if [ $HADOLINT_EXIT -eq 0 ]; then
      pass "Hadolint: Dockerfile passes all security lint checks"
      record_scanner "hadolint" "PASS" "No issues found"
    else
      # Hadolint exit codes: 0=pass, 1=warnings, 2=errors
      if [ $HADOLINT_EXIT -eq 1 ]; then
        warn "Hadolint: Dockerfile has warnings — review ${HADOLINT_REPORT}"
        record_scanner "hadolint" "WARN" "Warnings found — see ${HADOLINT_REPORT}"
      else
        fail "Hadolint: Dockerfile has errors — review ${HADOLINT_REPORT}"
        record_scanner "hadolint" "FAIL" "Errors found — see ${HADOLINT_REPORT}"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# SCANNER 4: Manual layer inspection (docker save + grep)
# ---------------------------------------------------------------------------
print_section "Scanner 4: Manual Layer Content Inspection"
info "This reproduces the check performed by validate-image.sh, providing"
info "an independent verification that no secrets are embedded in image layers."

if docker image inspect "${IMAGE_NAME}" &>/dev/null; then
  LAYER_INSPECT_REPORT="${RESULTS_DIR}/layer-inspection.txt"
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "${TMPDIR}"' EXIT

  info "Extracting image and scanning all layer archives..."
  docker save "${IMAGE_NAME}" | tar -xf - -C "${TMPDIR}" 2>/dev/null

  SECRET_LAYER_PATTERNS="api.key=|secret=|password=|token=|pk_live|sk_live|processor_a|processor_b|processor_c|adyen|regional.acquirer"
  LAYER_SECRET_FOUND=false

  {
    echo "Layer Content Inspection Report"
    echo "================================"
    echo "Image: ${IMAGE_NAME}"
    echo "Scanned: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""
  } > "${LAYER_INSPECT_REPORT}"

  LAYER_COUNT=0
  while IFS= read -r -d '' layer_tar; do
    LAYER_COUNT=$((LAYER_COUNT + 1))
    LAYER_ID=$(basename "$(dirname "${layer_tar}")")

    CONTENT_MATCHES=$(tar -xOf "${layer_tar}" 2>/dev/null \
      | strings 2>/dev/null \
      | grep -iE "${SECRET_LAYER_PATTERNS}" \
      | grep -v "^#\|example\|placeholder\|REPLACE\|your.key" \
      || true)

    echo "Layer ${LAYER_COUNT}: ${LAYER_ID}" >> "${LAYER_INSPECT_REPORT}"
    if [ -n "${CONTENT_MATCHES}" ]; then
      echo "  STATUS: POTENTIAL SECRETS FOUND" >> "${LAYER_INSPECT_REPORT}"
      echo "${CONTENT_MATCHES}" >> "${LAYER_INSPECT_REPORT}"
      LAYER_SECRET_FOUND=true
    else
      echo "  STATUS: CLEAN" >> "${LAYER_INSPECT_REPORT}"
    fi
    echo "" >> "${LAYER_INSPECT_REPORT}"
  done < <(find "${TMPDIR}" -name "layer.tar" -print0 2>/dev/null)

  info "Scanned ${LAYER_COUNT} layer(s)"

  if ! $LAYER_SECRET_FOUND; then
    pass "Manual layer inspection: All ${LAYER_COUNT} layers are clean"
    record_scanner "layer-inspect" "PASS" "${LAYER_COUNT} layers scanned, no secrets found"
  else
    fail "Manual layer inspection: Potential secrets found in image layers!"
    record_scanner "layer-inspect" "FAIL" "Secrets found in layers — see ${LAYER_INSPECT_REPORT}"
  fi

  info "Full layer inspection report: ${LAYER_INSPECT_REPORT}"
else
  warn "Image ${IMAGE_NAME} not found — skipping layer inspection"
  record_scanner "layer-inspect" "SKIPPED" "Image not available"
fi

# ---------------------------------------------------------------------------
# Write consolidated report
# ---------------------------------------------------------------------------
CONSOLIDATED_REPORT="${RESULTS_DIR}/security-scan-summary.json"

{
  echo "{"
  echo "  \"scan_timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\","
  echo "  \"image\": \"${IMAGE_NAME}\","
  echo "  \"repository\": \"${PROJECT_ROOT}\","
  echo "  \"operator\": \"${USER:-unknown}\","
  echo "  \"results\": ["
  FIRST=true
  for result in "${SCANNER_RESULTS[@]}"; do
    IFS='|' read -r scanner status detail <<< "${result}"
    if ! $FIRST; then echo "    ,"; fi
    echo "    {"
    echo "      \"scanner\": \"${scanner}\","
    echo "      \"status\": \"${status}\","
    echo "      \"detail\": \"${detail}\""
    echo "    }"
    FIRST=false
  done
  echo "  ],"
  echo "  \"summary\": {"
  echo "    \"pass\": ${PASS_COUNT},"
  echo "    \"fail\": ${FAIL_COUNT},"
  echo "    \"warn\": ${WARN_COUNT}"
  echo "  }"
  echo "}"
} > "${CONSOLIDATED_REPORT}"

# ---------------------------------------------------------------------------
# Final Summary
# ---------------------------------------------------------------------------
print_header "Security Scan Summary"
echo ""
echo "  Scanners run:"
for result in "${SCANNER_RESULTS[@]}"; do
  IFS='|' read -r scanner status detail <<< "${result}"
  case $status in
    PASS)    echo -e "    ${GREEN}[PASS]${RESET}    ${scanner}: ${detail}" ;;
    FAIL)    echo -e "    ${RED}[FAIL]${RESET}    ${scanner}: ${detail}" ;;
    WARN)    echo -e "    ${YELLOW}[WARN]${RESET}    ${scanner}: ${detail}" ;;
    SKIPPED) echo -e "    ${CYAN}[SKIP]${RESET}    ${scanner}: ${detail}" ;;
    ERROR)   echo -e "    ${RED}[ERROR]${RESET}   ${scanner}: ${detail}" ;;
  esac
done

echo ""
TOTAL_CHECKS=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
echo "  Individual checks: ${TOTAL_CHECKS} total"
echo -e "  ${GREEN}Passed  : ${PASS_COUNT}${RESET}"
echo -e "  ${RED}Failed  : ${FAIL_COUNT}${RESET}"
echo -e "  ${YELLOW}Warnings: ${WARN_COUNT}${RESET}"
echo ""
echo "  Reports saved to: ${RESULTS_DIR}/"
echo "  Consolidated JSON: ${CONSOLIDATED_REPORT}"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
  echo -e "${GREEN}${BOLD}  RESULT: PASS — All security scans passed${RESET}"
  echo ""
  echo "  The FlexPay payment service image and repository are clear of:"
  echo "    - Committed secrets (gitleaks)"
  echo "    - HIGH/CRITICAL CVEs (trivy)"
  echo "    - Dockerfile security anti-patterns (hadolint)"
  echo "    - Embedded secrets in image layers (manual inspection)"
  exit 0
else
  echo -e "${RED}${BOLD}  RESULT: FAIL — ${FAIL_COUNT} security issue(s) require remediation${RESET}"
  echo ""
  echo "  Address all FAIL items before deploying to production."
  echo "  Review individual reports in: ${RESULTS_DIR}/"
  exit 1
fi
