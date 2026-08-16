import Config

# Compile-time prod config — baked into the release at `mix release` time
# (MIX_ENV=prod). Runtime-environment-dependent values (DB connection,
# port) live in config/runtime.exs instead, per standard Elixir release
# convention.

# Same placeholder as config/dev.exs — no real Keycloak instance exists
# yet for any environment, deployed or local (see that file's comment and
# README's "Migration status"). Replace with a real per-environment issuer
# URL once realm provisioning (deferred past S1, see the S1 section note
# in docs/requirements.yaml) exists. Kept identical to dev on purpose so a
# Hetzner-deployed instance behaves the same as local until real OIDC
# lands — do not diverge these without updating both.
config :letflow, :oidc,
  issuer: "https://placeholder-keycloak.invalid/realms/bpm-default",
  provider_name: Letflow.Oidc.DefaultProvider,
  client_id: "letflow-placeholder-client",
  signing_algs: ["RS256"],
  token_verifier: Letflow.Oidc.TokenVerifier.Oidcc

config :letflow, :oidc_claim_mapping, %{
  "bpm-default" => %{
    tenant_id_claim: "tenant_id",
    roles_claim_paths: ["realm_access.roles", "roles"],
    email_claim: "email",
    preferred_username_claim: "preferred_username",
    display_name_claim: "name"
  }
}

config :letflow, :oidc_jit_provisioning, %{
  "bpm-default" => %{
    enabled: true,
    default_status: :active,
    default_roles: []
  }
}
