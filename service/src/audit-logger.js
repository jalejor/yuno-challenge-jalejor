'use strict';

/**
 * audit-logger.js
 *
 * Lightweight application-level audit log for PCI-DSS compliance.
 *
 * Captures every secret access event — including timestamp, instance identity,
 * Vault path, KV version, and outcome — in newline-delimited JSON format.
 *
 * This supplements Vault's own audit log (which records every API request at
 * the Vault server side) with application-level context such as the HTTP
 * request that triggered the secret fetch and the service instance ID.
 *
 * PCI-DSS Requirement 10: "Track and monitor all access to network resources
 * and cardholder data."
 *
 * IMPORTANT: Credential VALUES are never written to this log. Only metadata
 * (path, version, success/failure) is recorded.
 */

const INSTANCE_ID = process.env.INSTANCE_ID || require('os').hostname();
const MAX_ENTRIES = 1000; // Circular buffer — keeps memory bounded

// In-memory circular buffer of audit entries
const _entries = [];

/**
 * Event types for structured filtering.
 */
const EVENT = {
  SECRET_FETCH:    'SECRET_FETCH',
  SECRET_REFRESH:  'SECRET_REFRESH',
  AUTH_SUCCESS:    'AUTH_SUCCESS',
  AUTH_FAILURE:    'AUTH_FAILURE',
  ROTATION_DETECTED: 'ROTATION_DETECTED',
};

/**
 * Append one audit entry to the in-memory buffer.
 * Older entries are evicted when the buffer exceeds MAX_ENTRIES.
 *
 * @param {string} event   - One of EVENT.*
 * @param {string} path    - Vault KV path accessed (e.g. 'secret/data/flexpay/processors')
 * @param {boolean} success - Whether the operation succeeded
 * @param {object} [meta]  - Optional extra metadata (version, error message, etc.)
 */
function record(event, path, success, meta = {}) {
  const entry = {
    timestamp:  new Date().toISOString(),
    instanceId: INSTANCE_ID,
    event,
    path,
    success,
    ...meta,
  };

  _entries.push(entry);

  // Evict oldest entries to keep the buffer bounded
  if (_entries.length > MAX_ENTRIES) {
    _entries.shift();
  }

  // Emit to stdout as JSON line so container log collectors pick it up
  // (Do NOT use process.stdout.write in tests — a logger abstraction is fine here
  //  because pino is already capturing structured logs; this is the audit channel)
  process.stdout.write(JSON.stringify({ audit: true, ...entry }) + '\n');
}

/**
 * Return the most recent N entries (newest last).
 * Used by the GET /audit endpoint.
 *
 * @param {number} [limit=100]
 * @returns {Array<object>}
 */
function getRecentEntries(limit = 100) {
  const start = Math.max(0, _entries.length - limit);
  return _entries.slice(start);
}

/**
 * Return the total number of entries recorded since process start.
 */
function getTotalCount() {
  return _entries.length;
}

// ── Convenience helpers ───────────────────────────────────────────────────────

/**
 * Record a successful Vault secret fetch.
 * @param {string} path
 * @param {number} [version] - KV version number returned by Vault
 */
function recordSecretFetch(path, version) {
  record(EVENT.SECRET_FETCH, path, true, { kvVersion: version ?? null });
}

/**
 * Record a failed Vault secret fetch.
 * @param {string} path
 * @param {string} errorMessage - Error text (must NOT contain credential values)
 */
function recordSecretFetchError(path, errorMessage) {
  record(EVENT.SECRET_FETCH, path, false, { error: errorMessage });
}

/**
 * Record a successful periodic secret refresh.
 * @param {string} path
 * @param {number} [version]
 * @param {boolean} [rotationDetected] - True when the KV version advanced
 */
function recordSecretRefresh(path, version, rotationDetected = false) {
  record(EVENT.SECRET_REFRESH, path, true, { kvVersion: version ?? null, rotationDetected });
  if (rotationDetected) {
    record(EVENT.ROTATION_DETECTED, path, true, { newKvVersion: version ?? null });
  }
}

/**
 * Record a successful AppRole authentication.
 * @param {number} leaseDuration - Token lease duration in seconds
 */
function recordAuthSuccess(leaseDuration) {
  record(EVENT.AUTH_SUCCESS, 'auth/approle/login', true, { leaseDuration });
}

/**
 * Record a failed AppRole authentication.
 * @param {string} errorMessage
 */
function recordAuthFailure(errorMessage) {
  record(EVENT.AUTH_FAILURE, 'auth/approle/login', false, { error: errorMessage });
}

module.exports = {
  EVENT,
  record,
  getRecentEntries,
  getTotalCount,
  recordSecretFetch,
  recordSecretFetchError,
  recordSecretRefresh,
  recordAuthSuccess,
  recordAuthFailure,
};
