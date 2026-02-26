'use strict';

const vault = require('node-vault');
const pino = require('pino');
const auditLogger = require('./audit-logger');

const logger = pino({ name: 'vault-client', level: process.env.LOG_LEVEL || 'info' });

// Internal state — never exposed outside this module
let vaultClient = null;
let clientToken = null;
let _secretsLoaded = false;
let _cachedSecrets = null;
let _refreshTimer = null;
let _lastKvVersion = null; // Track KV version for rotation detection

const VAULT_ADDR = process.env.VAULT_ADDR || 'http://vault:8200';
const VAULT_ROLE_ID = process.env.VAULT_ROLE_ID;
const VAULT_SECRET_ID = process.env.VAULT_SECRET_ID;
const SECRETS_PATH = 'secret/data/flexpay/processors';
const REFRESH_INTERVAL_MS = 60_000; // 60 seconds

/**
 * Retry helper with exponential backoff.
 */
async function withRetry(fn, { maxAttempts = 5, baseDelayMs = 1000, label = 'operation' } = {}) {
  let lastError;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err;
      const delay = baseDelayMs * Math.pow(2, attempt - 1);
      logger.warn(
        { attempt, maxAttempts, delayMs: delay, label, err: err.message },
        'Retrying after failure'
      );
      if (attempt < maxAttempts) {
        await new Promise((r) => setTimeout(r, delay));
      }
    }
  }
  throw lastError;
}

/**
 * Initialise the Vault client and authenticate via AppRole.
 * Sets the internal client token so subsequent requests are authenticated.
 *
 * Reads VAULT_ROLE_ID and VAULT_SECRET_ID from environment (these are
 * AppRole authentication identifiers, NOT payment processor credentials).
 */
async function initVaultClient() {
  if (!VAULT_ROLE_ID || !VAULT_SECRET_ID) {
    throw new Error(
      'VAULT_ROLE_ID and VAULT_SECRET_ID must be set. ' +
      'These are Vault AppRole auth identifiers — do not confuse with payment credentials.'
    );
  }

  logger.info({ vaultAddr: VAULT_ADDR }, 'Initialising Vault client');

  vaultClient = vault({ endpoint: VAULT_ADDR });

  // Authenticate with AppRole — retry in case Vault is still starting
  let authResult;
  try {
    authResult = await withRetry(
      () => vaultClient.approleLogin({
        role_id: VAULT_ROLE_ID,
        secret_id: VAULT_SECRET_ID,
      }),
      { maxAttempts: 5, baseDelayMs: 2000, label: 'vault-approle-login' }
    );
  } catch (err) {
    auditLogger.recordAuthFailure(err.message);
    throw err;
  }

  clientToken = authResult.auth.client_token;

  // Attach token for all subsequent requests
  vaultClient = vault({ endpoint: VAULT_ADDR, token: clientToken });

  const leaseDuration = authResult.auth.lease_duration;
  logger.info({ leaseDuration }, 'Vault AppRole authentication successful');
  auditLogger.recordAuthSuccess(leaseDuration);

  return vaultClient;
}

/**
 * Fetch all processor credentials from Vault.
 * Returns a plain object with all credential keys.
 * NEVER logs credential values.
 */
async function getSecrets() {
  if (!vaultClient) {
    throw new Error('Vault client not initialised. Call initVaultClient() first.');
  }

  const response = await withRetry(
    () => vaultClient.read(SECRETS_PATH),
    { maxAttempts: 3, baseDelayMs: 1000, label: 'vault-read-secrets' }
  );

  if (!response || !response.data || !response.data.data) {
    throw new Error(`No data found at Vault path: ${SECRETS_PATH}`);
  }

  const secrets = response.data.data;
  const credentialCount = Object.keys(secrets).length;
  // KV v2 metadata lives in response.data.metadata
  const kvVersion = response.data.metadata ? response.data.metadata.version : null;

  // Log count only — never log values
  logger.info(
    { path: SECRETS_PATH, credentialCount, kvVersion },
    `Loaded ${credentialCount} credentials for payment processors`
  );

  auditLogger.recordSecretFetch(SECRETS_PATH, kvVersion);

  _cachedSecrets = secrets;
  _secretsLoaded = true;
  _lastKvVersion = kvVersion;

  return secrets;
}

/**
 * On-demand secret reload. Fetches fresh values from Vault.
 * Updates the internal cache. Used by the periodic refresh timer
 * and can be called manually (e.g. after receiving a SIGHUP).
 */
async function refreshSecrets() {
  if (!vaultClient) {
    throw new Error('Vault client not initialised.');
  }

  logger.info('Refreshing secrets from Vault');

  const previousVersion = _lastKvVersion;

  try {
    const fresh = await getSecrets();
    const rotationDetected = previousVersion !== null && _lastKvVersion !== previousVersion;

    if (rotationDetected) {
      logger.info(
        { previousVersion, newVersion: _lastKvVersion },
        'Secret rotation detected — in-memory credentials updated without restart'
      );
    } else {
      logger.info({ kvVersion: _lastKvVersion }, 'Secrets refreshed successfully (no rotation)');
    }

    // Override the fetch audit entry with a more specific refresh entry
    auditLogger.recordSecretRefresh(SECRETS_PATH, _lastKvVersion, rotationDetected);

    return fresh;
  } catch (err) {
    logger.error({ err: err.message }, 'Failed to refresh secrets — retaining cached values');
    auditLogger.recordSecretFetchError(SECRETS_PATH, err.message);
    // Keep cached secrets so the service stays operational
    return _cachedSecrets;
  }
}

/**
 * Start the periodic background refresh so that secret rotations
 * are picked up without a container restart.
 */
function startPeriodicRefresh(intervalMs = REFRESH_INTERVAL_MS) {
  if (_refreshTimer) {
    clearInterval(_refreshTimer);
  }
  _refreshTimer = setInterval(async () => {
    try {
      await refreshSecrets();
    } catch (err) {
      logger.error({ err: err.message }, 'Periodic secret refresh failed');
    }
  }, intervalMs);

  // Don't keep the process alive solely for this timer
  if (_refreshTimer.unref) {
    _refreshTimer.unref();
  }

  logger.info({ intervalMs }, 'Periodic secret refresh scheduled');
}

/**
 * Stop the periodic refresh timer (used during graceful shutdown).
 */
function stopPeriodicRefresh() {
  if (_refreshTimer) {
    clearInterval(_refreshTimer);
    _refreshTimer = null;
    logger.info('Periodic secret refresh stopped');
  }
}

/**
 * Return the current cached secrets without hitting Vault.
 * Returns null if secrets have not been loaded yet.
 */
function getCachedSecrets() {
  return _cachedSecrets;
}

/**
 * Whether secrets have been successfully loaded at least once.
 */
function areSecretsLoaded() {
  return _secretsLoaded;
}

module.exports = {
  initVaultClient,
  getSecrets,
  refreshSecrets,
  startPeriodicRefresh,
  stopPeriodicRefresh,
  getCachedSecrets,
  areSecretsLoaded,
};
