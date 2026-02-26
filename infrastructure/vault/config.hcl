# Vault Server Configuration
# PoC Note: This configuration is optimized for local demonstration.
# Production differences are documented in DESIGN_DECISIONS.md.

# Storage backend: file-based for PoC simplicity
# Production: Use Consul or integrated Raft storage for HA
storage "file" {
  path = "/vault/data"
}

# Listener: TLS disabled for PoC convenience
# Production: TLS MUST be enabled with valid certificates
# See: https://developer.hashicorp.com/vault/docs/configuration/listener/tcp#tls_cert_file
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true  # PoC only — never disable TLS in production
}

# API address — used by Vault for redirect and clustering
api_addr = "http://vault:8200"

# Cluster address for HA (not used in PoC single-node mode)
cluster_addr = "http://vault:8201"

# Audit logging — enabled at runtime by init-vault.sh via `vault audit enable file`
# Vault audit devices are runtime-configured (not in this HCL file).
# The init script enables a file audit device writing to /vault/logs/audit.log.
# This satisfies PCI-DSS Requirement 10: Track and monitor all access to
# network resources and cardholder data.
#
# Production: ship audit logs to a SIEM (Splunk/Datadog) via the syslog
# audit backend or a log shipper reading the file backend output.

# Disable mlock for containerized environments (mlock requires elevated privileges)
# Production: Consider running with IPC_LOCK capability and setting disable_mlock = false
disable_mlock = true

# UI enabled for local demonstration (disable in production or restrict with ACL)
ui = true
