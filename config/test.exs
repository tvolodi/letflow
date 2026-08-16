import Config

config :letflow, Letflow.Repo,
  username: "letflow",
  password: "letflow",
  database: "letflow_test#{System.get_env("MIX_TEST_PARTITION")}",
  hostname: "localhost",
  port: 5462,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Placeholder — no real Keycloak instance exists yet. Replace with a real
# per-environment issuer URL once realm provisioning (deferred past S1, see
# the S1 section note in docs/requirements.yaml) exists.
# Duplicated from config/dev.exs: this repo's config files don't cascade
# (each env file loads independently via config.exs's
# import_config "#{config_env()}.exs"), so the :oidc key must be set here
# too or it's absent under MIX_ENV=test.
config :letflow, :oidc,
  issuer: "https://placeholder-keycloak.invalid/realms/bpm-default",
  provider_name: Letflow.Oidc.DefaultProvider

# Duplicated from config/dev.exs (this repo's config files don't cascade —
# see the :oidc key's comment above for the same note). Per-realm
# claim-path configuration for Letflow.Oidc.ClaimMapping, distinct from the
# :oidc key. A realm with no entry here falls back to
# Letflow.Oidc.ClaimMappingConfig.default/1.
config :letflow, :oidc_claim_mapping, %{
  "bpm-default" => %{
    tenant_id_claim: "tenant_id",
    roles_claim_paths: ["realm_access.roles", "roles"],
    email_claim: "email",
    preferred_username_claim: "preferred_username",
    display_name_claim: "name"
  }
}

# Duplicated from config/dev.exs (this repo's config files don't cascade —
# see the :oidc key's comment above for the same note). Per-realm JIT
# user-provisioning configuration for Letflow.Identity.provision_oidc_user/3,
# distinct from the :oidc and :oidc_claim_mapping keys. A realm with no entry
# here falls back to Letflow.Oidc.JitProvisioningConfig.default/1.
config :letflow, :oidc_jit_provisioning, %{
  "bpm-default" => %{
    enabled: true,
    default_status: :active,
    default_roles: []
  }
}
