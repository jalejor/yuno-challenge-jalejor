'use strict';

const { areSecretsLoaded } = require('./vault-client');
const { getAvailableProcessors } = require('./processors');

/**
 * GET /health
 *
 * Liveness + readiness health check used by:
 *   - Docker HEALTHCHECK instruction
 *   - Docker Compose health check (gates rolling update traffic routing)
 *   - Load balancer readiness probes
 *
 * Returns HTTP 200 only when secrets have been successfully loaded from Vault.
 * Returns HTTP 503 when the service is still initialising or Vault is unreachable.
 *
 * This is CRITICAL for zero-downtime deployments: the orchestrator will not
 * route production traffic to a new container until this endpoint returns 200.
 */
function healthHandler(req, res) {
  const secretsLoaded = areSecretsLoaded();
  const availableProcessors = secretsLoaded ? getAvailableProcessors() : [];
  const uptime = Math.floor(process.uptime());

  if (!secretsLoaded) {
    return res.status(503).json({
      status: 'unhealthy',
      secretsLoaded: false,
      reason: 'Secrets not yet loaded from Vault',
      uptime,
      timestamp: new Date().toISOString(),
    });
  }

  const allProcessorsReady = availableProcessors.length === 3;

  if (!allProcessorsReady) {
    return res.status(503).json({
      status: 'degraded',
      secretsLoaded: true,
      processors: availableProcessors,
      reason: `Only ${availableProcessors.length}/3 processors have credentials`,
      uptime,
      timestamp: new Date().toISOString(),
    });
  }

  return res.status(200).json({
    status: 'healthy',
    secretsLoaded: true,
    processors: availableProcessors,
    processorCount: availableProcessors.length,
    uptime,
    timestamp: new Date().toISOString(),
  });
}

/**
 * GET /ready
 *
 * Kubernetes-style readiness probe (subset of /health).
 * Returns 200 when ready to serve traffic, 503 otherwise.
 */
function readinessHandler(req, res) {
  const secretsLoaded = areSecretsLoaded();

  if (!secretsLoaded) {
    return res.status(503).json({ ready: false, reason: 'Secrets not loaded' });
  }

  return res.status(200).json({ ready: true });
}

module.exports = { healthHandler, readinessHandler };
