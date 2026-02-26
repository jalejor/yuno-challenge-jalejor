# =============================================================================
# FlexPay Payment Service - Multi-Stage Dockerfile
# =============================================================================
# PCI-DSS Compliance Notes:
#   - NO secrets, credentials, or API keys at any build stage
#   - Non-root user (PCI-DSS Requirement 6.3)
#   - Minimal attack surface via multi-stage build
#   - All credentials injected at RUNTIME via Vault AppRole (not baked in)
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Builder
# Install production dependencies only — no dev tools in final image
# -----------------------------------------------------------------------------
FROM node:20-alpine AS builder

WORKDIR /app

# Copy dependency manifests first to leverage Docker layer cache
# If package.json doesn't change, npm ci is skipped on rebuild
COPY package*.json ./

# Install production dependencies only
# npm ci ensures reproducible builds (uses package-lock.json exactly)
RUN npm ci --only=production

# Copy application source AFTER dependencies (cache efficiency)
COPY src/ ./src/

# -----------------------------------------------------------------------------
# Stage 2: Production Runtime
# Only the artifacts needed to run — no build tools, no npm, no package manager
# -----------------------------------------------------------------------------
FROM node:20-alpine

# Create a dedicated non-root user and group (PCI-DSS best practice)
# Using fixed UIDs/GIDs for reproducibility across hosts
RUN addgroup -g 1001 -S appgroup && \
    adduser -S appuser -u 1001 -G appgroup

WORKDIR /app

# Copy only what's needed from the builder stage
# This ensures no intermediate build artifacts or dev dependencies are included
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/src ./src
COPY --from=builder /app/package.json ./

# Drop root privileges before running the application
# All subsequent commands (including CMD) run as appuser
USER appuser

# Document the port the service listens on (informational only)
EXPOSE 3000

# Built-in health check used by Docker and orchestrators to gate traffic routing
# Service returns HTTP 200 only after secrets are successfully loaded from Vault
# This is critical for zero-downtime rolling updates
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
    CMD wget -qO- http://localhost:3000/health || exit 1

# Start the application
# Using exec form (JSON array) to ensure SIGTERM is passed directly to node
# This enables graceful shutdown handling in index.js
CMD ["node", "src/index.js"]

# =============================================================================
# Security Verification (run after build to confirm no secrets in layers):
#   docker history flexpay-service --no-trunc
#   docker inspect flexpay-service | grep -i env
#   docker save flexpay-service | tar -xO | strings | grep -iE "api_key|secret|token|password"
# =============================================================================
