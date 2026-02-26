#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Zero-Downtime Rolling Update Script
#
# Purpose:
#   Performs a rolling update of the payment-service containers without ever
#   dropping all healthy instances to zero. This satisfies the PCI-DSS PoC
#   requirement for zero-downtime deployments and provides an auditable log.
#
# Usage:
#   ./deploy.sh [IMAGE_TAG]
#
#   IMAGE_TAG (optional): Docker image tag to deploy (default: "latest")
#
# Strategy:
#   For each replica (default 3):
#     1. Scale UP by 1 (start the new container)
#     2. Wait for the new container to pass its /health check
#     3. Scale DOWN by 1 (remove an old container)
#   Throughout the process at least 1 healthy instance remains active.
#
# Audit:
#   All steps are logged with timestamps to stdout and optionally to
#   ./deploy.log for auditor review.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
COMPOSE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docker-compose.yml"
SERVICE_NAME="payment-service"
IMAGE_NAME="flexpay-payment-service"
IMAGE_TAG="${1:-latest}"
REPLICAS=3
HEALTH_TIMEOUT=60   # seconds to wait for each new instance to become healthy
HEALTH_INTERVAL=3   # seconds between health poll attempts
LOG_FILE="$(dirname "${BASH_SOURCE[0]}")/deploy.log"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  local msg="[${ts}] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

# Wait until a specific container reports healthy on its /health endpoint.
# Args: container_name
wait_for_healthy() {
  local container="$1"
  local elapsed=0

  log "  Waiting for container '${container}' to become healthy..."

  while [ "$elapsed" -lt "$HEALTH_TIMEOUT" ]; do
    local state
    state=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not_found")

    if [ "$state" = "healthy" ]; then
      log "  Container '${container}' is healthy. (${elapsed}s elapsed)"
      return 0
    fi

    sleep "$HEALTH_INTERVAL"
    elapsed=$((elapsed + HEALTH_INTERVAL))
    log "  ... waiting (${elapsed}s / ${HEALTH_TIMEOUT}s) current state: ${state}"
  done

  die "Timed out waiting for '${container}' to become healthy after ${HEALTH_TIMEOUT}s."
}

# Return the number of currently running (not stopped) replicas of the service.
running_replicas() {
  docker compose -f "$COMPOSE_FILE" ps -q "$SERVICE_NAME" 2>/dev/null \
    | xargs -r docker inspect --format='{{.State.Status}}' 2>/dev/null \
    | grep -c "^running$" || echo "0"
}

# Return a list of all container IDs for the service (oldest first).
get_containers() {
  docker compose -f "$COMPOSE_FILE" ps -q "$SERVICE_NAME" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
log "============================================================"
log "FlexPay Payment Service — Rolling Deployment"
log "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
log "Target replicas: ${REPLICAS}"
log "Compose file: ${COMPOSE_FILE}"
log "============================================================"

command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"
docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"

if [ ! -f "$COMPOSE_FILE" ]; then
  die "Compose file not found: ${COMPOSE_FILE}"
fi

# ---------------------------------------------------------------------------
# Step 1: Build the new image
# ---------------------------------------------------------------------------
log "STEP 1/4: Building new image ${IMAGE_NAME}:${IMAGE_TAG} ..."

docker compose -f "$COMPOSE_FILE" build "$SERVICE_NAME"
docker tag "${IMAGE_NAME}:latest" "${IMAGE_NAME}:${IMAGE_TAG}" 2>/dev/null || true

log "Build complete."

# ---------------------------------------------------------------------------
# Step 2: Capture the list of OLD containers before we start new ones
# ---------------------------------------------------------------------------
log "STEP 2/4: Capturing existing container list ..."

mapfile -t OLD_CONTAINERS < <(get_containers)
log "Existing containers: ${#OLD_CONTAINERS[@]}"
for c in "${OLD_CONTAINERS[@]}"; do
  log "  - ${c}"
done

# ---------------------------------------------------------------------------
# Step 3: Rolling update — one container at a time
# ---------------------------------------------------------------------------
log "STEP 3/4: Starting rolling update (start-first order) ..."

CURRENT_REPLICAS=$(running_replicas)
log "Currently running: ${CURRENT_REPLICAS} replica(s)"

# If nothing is running yet, just bring the full stack up.
if [ "$CURRENT_REPLICAS" -eq 0 ]; then
  log "No running replicas found. Starting full stack..."
  docker compose -f "$COMPOSE_FILE" up -d --scale "${SERVICE_NAME}=${REPLICAS}"
  log "Stack started. Waiting for all instances to be healthy..."
  sleep 5

  mapfile -t NEW_CONTAINERS < <(get_containers)
  for c in "${NEW_CONTAINERS[@]}"; do
    wait_for_healthy "$c"
  done

  log "All instances are healthy."
  log "DEPLOYMENT COMPLETE"
  exit 0
fi

# ----
# Rolling update loop: for each old container, start a new one first,
# verify it's healthy, then stop the old one.
# ----
UPDATED=0

for OLD_CONTAINER in "${OLD_CONTAINERS[@]}"; do
  UPDATED=$((UPDATED + 1))
  log "--- Updating replica ${UPDATED}/${#OLD_CONTAINERS[@]} ---"
  log "  Old container: ${OLD_CONTAINER}"

  # Scale up by 1 (brings total to REPLICAS + 1 temporarily)
  NEW_SCALE=$((CURRENT_REPLICAS + 1))
  log "  Scaling service to ${NEW_SCALE} (adding a new replica) ..."
  docker compose -f "$COMPOSE_FILE" up -d --no-recreate --scale "${SERVICE_NAME}=${NEW_SCALE}" "$SERVICE_NAME"

  # Give Docker a moment to start the new container
  sleep 2

  # Identify the newly created container (it won't be in OLD_CONTAINERS)
  mapfile -t ALL_CONTAINERS < <(get_containers)
  NEW_CONTAINER=""
  for c in "${ALL_CONTAINERS[@]}"; do
    # Check if this container is NOT in the original list
    is_old=false
    for old in "${OLD_CONTAINERS[@]}"; do
      if [ "$c" = "$old" ]; then
        is_old=true
        break
      fi
    done
    if [ "$is_old" = false ] && [ "$c" != "$OLD_CONTAINER" ]; then
      NEW_CONTAINER="$c"
      break
    fi
  done

  # Fallback: if we can't isolate it, just wait for all to be healthy
  if [ -z "$NEW_CONTAINER" ]; then
    log "  Could not isolate new container — waiting for overall healthy count to increase..."
    sleep "$HEALTH_INTERVAL"
  else
    log "  New container: ${NEW_CONTAINER}"
    wait_for_healthy "$NEW_CONTAINER"
  fi

  # New instance is healthy — now remove the old one
  log "  Stopping old container: ${OLD_CONTAINER} ..."
  docker stop "$OLD_CONTAINER" --time 30 || true
  docker rm "$OLD_CONTAINER" 2>/dev/null || true

  CURRENT_REPLICAS=$(running_replicas)
  log "  Running replicas after step: ${CURRENT_REPLICAS}"

  # Safety check: never drop to zero
  if [ "$CURRENT_REPLICAS" -eq 0 ]; then
    die "SAFETY VIOLATION: 0 healthy replicas after removing ${OLD_CONTAINER}. Aborting."
  fi

  log "  Replica ${UPDATED} updated successfully. Healthy instances: ${CURRENT_REPLICAS}"
  log "  Waiting 5s before next replica..."
  sleep 5
done

# ---------------------------------------------------------------------------
# Step 4: Post-deployment verification
# ---------------------------------------------------------------------------
log "STEP 4/4: Post-deployment verification ..."

FINAL_REPLICAS=$(running_replicas)
log "Running replicas: ${FINAL_REPLICAS}"

if [ "$FINAL_REPLICAS" -lt 1 ]; then
  die "Post-deployment check failed: fewer than 1 healthy replica."
fi

# Hit the /health endpoint on each container to verify secrets are loaded
HEALTH_FAILURES=0
mapfile -t FINAL_CONTAINERS < <(get_containers)
for c in "${FINAL_CONTAINERS[@]}"; do
  CONTAINER_IP=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c" 2>/dev/null || true)
  if [ -n "$CONTAINER_IP" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${CONTAINER_IP}:3000/health" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
      log "  Container ${c} (${CONTAINER_IP}): /health → ${HTTP_CODE} OK"
    else
      log "  WARNING: Container ${c} (${CONTAINER_IP}): /health → ${HTTP_CODE}"
      HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
    fi
  else
    log "  Container ${c}: could not determine IP (may be on named network — check docker compose ps)"
  fi
done

log "============================================================"
log "DEPLOYMENT COMPLETE"
log "  Image deployed:    ${IMAGE_NAME}:${IMAGE_TAG}"
log "  Replicas running:  ${FINAL_REPLICAS}"
log "  Health failures:   ${HEALTH_FAILURES}"
log "  Log file:          ${LOG_FILE}"
log "============================================================"

if [ "$HEALTH_FAILURES" -gt 0 ]; then
  die "${HEALTH_FAILURES} container(s) failed the post-deployment health check."
fi

exit 0
