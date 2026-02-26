# Vault Policy: payment-service
# Principle of Least Privilege — grants ONLY the minimum access required.
#
# This policy is attached to the AppRole used by the payment gateway service.
# The service can ONLY read processor credentials from the single allowed path.
# All other paths are denied by Vault's default-deny policy engine.
#
# PCI-DSS Requirement 7: Restrict access to system components and cardholder
# data to only those individuals whose job requires such access.

# Allow read-only access to the payment processor credentials
path "secret/data/flexpay/processors" {
  capabilities = ["read"]
}

# Allow reading metadata (for version checking in KV v2)
path "secret/metadata/flexpay/processors" {
  capabilities = ["read"]
}

# Vault denies all other paths by default — no explicit deny needed.
# This includes:
#   - secret/data/flexpay/* (other secrets in the same namespace)
#   - sys/* (Vault system endpoints)
#   - auth/* (authentication management)
#   - Any other path not listed above
