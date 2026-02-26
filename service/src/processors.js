'use strict';

const pino = require('pino');
const { getCachedSecrets } = require('./vault-client');

const logger = pino({ name: 'processors', level: process.env.LOG_LEVEL || 'info' });

/**
 * Processor schema — defines which Vault secret keys belong to each processor.
 * Values are never hard-coded here; they are fetched from Vault at runtime.
 */
const PROCESSOR_SCHEMA = {
  A: {
    name: 'ProcessorA (Stripe-like)',
    requiredKeys: ['PROCESSOR_A_API_KEY', 'PROCESSOR_A_SECRET'],
  },
  B: {
    name: 'ProcessorB (Adyen-like)',
    requiredKeys: ['PROCESSOR_B_MERCHANT_ID', 'PROCESSOR_B_API_KEY'],
  },
  C: {
    name: 'ProcessorC (Regional acquirer)',
    requiredKeys: ['PROCESSOR_C_ENDPOINT', 'PROCESSOR_C_TOKEN'],
  },
};

/**
 * Retrieve credentials for a specific processor from the in-memory secret cache.
 * Throws if secrets have not been loaded or a required key is missing.
 * NEVER logs credential values.
 */
function getProcessorCredentials(processorName) {
  const schema = PROCESSOR_SCHEMA[processorName];
  if (!schema) {
    throw new Error(`Unknown processor: "${processorName}". Valid processors: A, B, C`);
  }

  const secrets = getCachedSecrets();
  if (!secrets) {
    throw new Error('Secrets not yet loaded from Vault. Service is not ready.');
  }

  const credentials = {};
  for (const key of schema.requiredKeys) {
    if (!secrets[key]) {
      throw new Error(`Required credential "${key}" is missing from Vault secrets.`);
    }
    credentials[key] = secrets[key];
  }

  return credentials;
}

/**
 * Simulate a payment against a specific processor.
 * Uses live credentials fetched from Vault (proves secrets are available at runtime).
 *
 * @param {string} processorName - "A", "B", or "C"
 * @param {number} amount        - Payment amount in cents
 * @param {string} [currency]    - ISO 4217 currency code (default: "USD")
 * @returns {object} Mock payment result
 */
async function processPayment(processorName, amount, currency = 'USD') {
  const schema = PROCESSOR_SCHEMA[processorName];
  if (!schema) {
    return {
      success: false,
      error: `Unknown processor: "${processorName}". Valid options: A, B, C`,
    };
  }

  let credentials;
  try {
    credentials = getProcessorCredentials(processorName);
  } catch (err) {
    logger.error({ processorName, err: err.message }, 'Failed to retrieve processor credentials');
    return { success: false, error: err.message };
  }

  // Confirm credentials are present without logging their values
  const credentialKeys = Object.keys(credentials);
  logger.info(
    { processorName, processor: schema.name, credentialKeys, amount, currency },
    'Processing payment — credentials verified (values not logged)'
  );

  // Mock processing logic — in production this would call the real processor API
  // using the credential values from `credentials`
  const transactionId = `txn_${processorName}_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;

  // Simulate occasional network latency
  await new Promise((r) => setTimeout(r, Math.random() * 50));

  const result = {
    success: true,
    transactionId,
    processor: processorName,
    processorName: schema.name,
    amount,
    currency,
    status: 'captured',
    timestamp: new Date().toISOString(),
    // Confirm which credential keys were used — NOT the values
    credentialsUsed: credentialKeys,
  };

  logger.info(
    { transactionId, processor: processorName, amount, currency },
    'Payment processed successfully'
  );

  return result;
}

/**
 * Return the list of processor names that have all required credentials
 * currently available in the secret cache.
 */
function getAvailableProcessors() {
  const secrets = getCachedSecrets();
  if (!secrets) return [];

  return Object.keys(PROCESSOR_SCHEMA).filter((name) => {
    try {
      getProcessorCredentials(name);
      return true;
    } catch {
      return false;
    }
  });
}

/**
 * Log a summary of loaded credentials (counts only, no values).
 * Called once at startup for audit trail.
 */
function logCredentialsSummary() {
  const secrets = getCachedSecrets();
  if (!secrets) {
    logger.warn('No secrets in cache — credential summary unavailable');
    return;
  }

  const totalCredentials = Object.keys(secrets).length;
  const processorSummary = Object.entries(PROCESSOR_SCHEMA).map(([name, schema]) => ({
    processor: name,
    name: schema.name,
    expectedKeys: schema.requiredKeys.length,
    keysPresent: schema.requiredKeys.filter((k) => !!secrets[k]).length,
  }));

  logger.info(
    { totalCredentials, processorCount: processorSummary.length, processorSummary },
    `Loaded ${totalCredentials} credentials for ${processorSummary.length} processors`
  );
}

module.exports = {
  processPayment,
  getAvailableProcessors,
  logCredentialsSummary,
  PROCESSOR_SCHEMA,
};
