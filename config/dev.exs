import Config

# Deliberately on port 5462, not 5432 — R-Co's own docker-compose stack
# already uses 5432 (dev) and 5433 (test), so Letflow gets its own
# ports and can run alongside R-Co without colliding. (Previously
# 5434, moved after that port turned out to already be in use.)
config :letflow, Letflow.Repo,
  username: "letflow",
  password: "letflow",
  database: "letflow_dev",
  hostname: "localhost",
  port: 5462,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Placeholder — no real Keycloak instance exists yet. Replace with a real
# per-environment issuer URL once realm provisioning (deferred past S1, see
# the S1 section note in docs/requirements.yaml) exists.
config :letflow, :oidc,
  issuer: "https://placeholder-keycloak.invalid/realms/bpm-default",
  provider_name: Letflow.Oidc.DefaultProvider

# Per-realm claim-path configuration for Letflow.Oidc.ClaimMapping — distinct
# from the :oidc key above (that one is REQ-016's provider-worker-startup
# config, consumed by Letflow.Application; this one is REQ-017's claim-mapping
# config, consumed by Letflow.Oidc.ClaimMappingConfig.for_realm/1). A realm
# with no entry here falls back to Letflow.Oidc.ClaimMappingConfig.default/1.
config :letflow, :oidc_claim_mapping, %{
  "bpm-default" => %{
    tenant_id_claim: "tenant_id",
    roles_claim_paths: ["realm_access.roles", "roles"],
    email_claim: "email",
    preferred_username_claim: "preferred_username",
    display_name_claim: "name"
  }
}
