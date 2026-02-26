'use strict';

const express = require('express');
const pino = require('pino');

const {
  initVaultClient,
  getSecrets,
  refreshSecrets,
  startPeriodicRefresh,
  stopPeriodicRefresh,
} = require('./vault-client');
const { processPayment, logCredentialsSummary } = require('./processors');
const { healthHandler, readinessHandler } = require('./health');
const auditLogger = require('./audit-logger');

const logger = pino({
  name: 'flexpay-service',
  level: process.env.LOG_LEVEL || 'info',
});

const PORT = parseInt(process.env.PORT || '3000', 10);
const app = express();

app.use(express.json());

// ── Request logging middleware (no credential data ever flows through here) ──
app.use((req, res, next) => {
  logger.info({ method: req.method, path: req.path }, 'Incoming request');
  next();
});

// ── Health & readiness routes ────────────────────────────────────────────────
app.get('/health', healthHandler);
app.get('/ready', readinessHandler);

// ── Mock payment endpoint ────────────────────────────────────────────────────
/**
 * POST /pay
 * Body: { processor: "A"|"B"|"C", amount: number, currency?: string }
 *
 * Demonstrates that secrets loaded from Vault are available to process payments.
 * Credential values are NEVER included in the response or logs.
 */
app.post('/pay', async (req, res) => {
  const { processor, amount, currency } = req.body;

  if (!processor || !['A', 'B', 'C'].includes(processor)) {
    return res.status(400).json({
      error: 'Invalid or missing "processor". Must be "A", "B", or "C".',
    });
  }

  if (!amount || typeof amount !== 'number' || amount <= 0) {
    return res.status(400).json({
      error: 'Invalid or missing "amount". Must be a positive number (in cents).',
    });
  }

  try {
    const result = await processPayment(processor, amount, currency || 'USD');
    if (result.success) {
      return res.status(200).json(result);
    } else {
      return res.status(422).json(result);
    }
  } catch (err) {
    logger.error({ err: err.message }, 'Unexpected error processing payment');
    return res.status(500).json({ error: 'Internal server error' });
  }
});

// ── Secret refresh endpoint (manual trigger) ─────────────────────────────────
/**
 * POST /admin/refresh-secrets
 * Triggers an immediate reload of secrets from Vault.
 * In production this would be protected by mutual TLS or an internal network policy.
 */
app.post('/admin/refresh-secrets', async (req, res) => {
  try {
    await refreshSecrets();
    logger.info('Manual secret refresh triggered via admin endpoint');
    return res.status(200).json({ message: 'Secrets refreshed successfully' });
  } catch (err) {
    logger.error({ err: err.message }, 'Manual secret refresh failed');
    return res.status(500).json({ error: 'Secret refresh failed', reason: err.message });
  }
});

// ── Audit log endpoint ────────────────────────────────────────────────────────
/**
 * GET /audit
 * Returns the last 100 application-level audit log entries.
 * Records every Vault secret access with timestamp, instance ID, KV version,
 * and outcome. Credential values are NEVER included.
 *
 * In production this endpoint would be restricted to an internal management
 * network or protected by mutual TLS. It is exposed here for auditor review.
 *
 * Query params:
 *   ?limit=N  — return last N entries (max 1000, default 100)
 */
app.get('/audit', (req, res) => {
  const limitParam = parseInt(req.query.limit || '100', 10);
  const limit = Math.min(Math.max(1, isNaN(limitParam) ? 100 : limitParam), 1000);
  const entries = auditLogger.getRecentEntries(limit);

  return res.status(200).json({
    instanceId: process.env.INSTANCE_ID || require('os').hostname(),
    totalRecorded: auditLogger.getTotalCount(),
    returned: entries.length,
    entries,
  });
});

// ── 404 handler ───────────────────────────────────────────────────────────────
app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// ── Error handler ─────────────────────────────────────────────────────────────
app.use((err, req, res, _next) => {
  logger.error({ err: err.message, stack: err.stack }, 'Unhandled application error');
  res.status(500).json({ error: 'Internal server error' });
});

// ── Graceful shutdown ─────────────────────────────────────────────────────────
let server;

function shutdown(signal) {
  logger.info({ signal }, 'Graceful shutdown initiated');

  stopPeriodicRefresh();

  if (server) {
    server.close(() => {
      logger.info('HTTP server closed');
      process.exit(0);
    });

    // Force exit if server doesn't close within 10 seconds
    setTimeout(() => {
      logger.warn('Forcing process exit after timeout');
      process.exit(1);
    }, 10_000).unref();
  } else {
    process.exit(0);
  }
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

// ── Startup sequence ──────────────────────────────────────────────────────────
async function start() {
  logger.info({ port: PORT, nodeEnv: process.env.NODE_ENV || 'production' }, 'Starting FlexPay payment service');

  try {
    // Step 1: Authenticate to Vault via AppRole
    // VAULT_ROLE_ID and VAULT_SECRET_ID are AppRole auth identifiers — NOT payment credentials
    await initVaultClient();

    // Step 2: Retrieve all payment processor credentials from Vault at runtime
    // Credentials are never in the image, environment, or compose file
    await getSecrets();

    // Step 3: Log credential summary (counts only — values never logged)
    logCredentialsSummary();

    // Step 4: Start periodic background refresh (picks up rotated secrets without restart)
    startPeriodicRefresh();

    // Step 5: Begin accepting HTTP traffic
    server = app.listen(PORT, '0.0.0.0', () => {
      logger.info(
        { port: PORT, secretsLoaded: true },
        'FlexPay payment service is ready to serve traffic'
      );
    });
  } catch (err) {
    logger.error({ err: err.message }, 'Fatal startup error — service cannot start');
    process.exit(1);
  }
}

start();
