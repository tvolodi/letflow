import Config

# Compile-time prod config — baked into the release at `mix release` time
# (MIX_ENV=prod). Runtime-environment-dependent values (DB connection,
# port) live in config/runtime.exs instead, per standard Elixir release
# convention. (start_http itself defaults to true in
# lib/letflow/application.ex's http_child/0 — no override needed here;
# only http_port, the runtime-dependent value, is set, in runtime.exs.)

# :oidc issuer/client_id moved to config/runtime.exs (env-var driven,
# OIDC_ISSUER/OIDC_CLIENT_ID) so a real per-environment Keycloak can be
# pointed at without rebuilding the release image — see runtime.exs for
# the current default (still the placeholder issuer until a deployment
# sets the env vars). provider_name/signing_algs/token_verifier stay here
# since they don't vary per environment.
config :letflow, :oidc,
  provider_name: Letflow.Oidc.DefaultProvider,
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

# Same default as config/dev.exs -- see that file's comment (REQ-039).
config :letflow, :sandbox_pool, max_concurrent_sandboxes: 5

# REQ-193: disable legacy :logger backends in prod (structured JSON via
# OTP default_handler only). Not set in config/test.exs so CaptureLog works.
config :logger, backends: []
config :logger, :default_handler, formatter: {Letflow.Obs.Logger, []}
