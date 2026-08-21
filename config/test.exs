import Config

# ISS-0015 (GH#71): don't start the HTTP listener under test at all -- no
# test drives Letflow.Router over a real socket (it's exercised via
# Plug.Test conn structs throughout this suite), so there is nothing to
# gain from binding a port here and a real collision risk to lose: two
# concurrent `mix test` runs (this project's two-worktree setup) previously
# both tried to bind the same hardcoded port 4000. Sidesteps the collision
# entirely rather than just relocating it (e.g. deriving a per-partition
# port), and shaves the listener's startup cost off every run. See
# lib/letflow/application.ex's http_child/0.
config :letflow, start_http: false

# Same per-workspace host port as config/dev.exs (this repo's config files
# don't cascade — each env file loads independently). See config/db_port.exs.
{db_port, _bindings} = Code.eval_file(Path.expand("db_port.exs", __DIR__))

config :letflow, Letflow.Repo,
  username: "letflow",
  password: "letflow",
  database: "letflow_test#{System.get_env("MIX_TEST_PARTITION")}",
  hostname: "localhost",
  port: db_port,
  pool: Ecto.Adapters.SQL.Sandbox,
  # ISS-0194: scripts/test_parallel.sh computes and exports TEST_POOL_SIZE so
  # N concurrently-launched partitions don't jointly exceed Postgres
  # max_connections (schedulers_online()*2 per partition, multiplied by N,
  # regularly did). A plain `mix test` (no test_parallel.sh, TEST_POOL_SIZE
  # unset) keeps the original sizing unchanged. See
  # docs/migration/decisions/0009-test-parallel-pool-sizing.md.
  pool_size:
    (case System.get_env("TEST_POOL_SIZE") do
       nil -> System.schedulers_online() * 2
       value -> String.to_integer(value)
     end),
  # ISS-0110: tags every Postgres connection this `mix test` invocation opens with
  # this invocation's own OS pid, so Letflow.TenantSchemaReaper.sweep_orphans/2 can
  # tell "another mix test invocation is currently connected to this database" from
  # pg_stat_activity alone, with no new table/column and no change to any of the
  # existing tenant-provisioning call sites. A nested invocation (ISS-0107) gets its
  # own distinct OS pid (Port.open spawns a new OS process), so this tag reliably
  # distinguishes invocations even when they share one database. See
  # test/support/tenant_schema_reaper.ex's moduledoc for how the tag is used.
  parameters: [application_name: "letflow_mixtest_#{System.pid()}"]

# Placeholder — no real Keycloak instance exists yet. Replace with a real
# per-environment issuer URL once realm provisioning (deferred past S1, see
# the S1 section note in docs/requirements.yaml) exists.
# Duplicated from config/dev.exs: this repo's config files don't cascade
# (each env file loads independently via config.exs's
# import_config "#{config_env()}.exs"), so the :oidc key must be set here
# too or it's absent under MIX_ENV=test.
#
# token_verifier is overridden here (unlike dev/prod's real
# Letflow.Oidc.TokenVerifier.Oidcc adapter) to Letflow.Oidc.TokenVerifierDouble
# — no real, Letflow-provisioned Keycloak issuer is reachable in this
# environment (see lib/letflow/design/req021-auth-plug-pipeline.md §3.2).
config :letflow, :oidc,
  issuer: "https://placeholder-keycloak.invalid/realms/bpm-default",
  provider_name: Letflow.Oidc.DefaultProvider,
  client_id: "letflow-placeholder-client",
  signing_algs: ["RS256"],
  token_verifier: Letflow.Oidc.TokenVerifierDouble

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
#
# "jit-disabled-test-realm" is a REQ-021 test-only fixture entry (see
# test/specs/REQ-021.md's "JIT-disabled realm fixture" section) — the only
# way test/letflow/plugs/auth_pipeline_test.exs can exercise the
# :jit_disabled -> 403 branch without mutating this file's config at
# runtime (unsafe under async: true). Not used by any other test.
config :letflow, :oidc_jit_provisioning, %{
  "bpm-default" => %{
    enabled: true,
    default_status: :active,
    default_roles: []
  },
  "jit-disabled-test-realm" => %{
    enabled: false,
    default_status: :active,
    default_roles: []
  }
}

# Small on purpose (REQ-039): fast, deterministic exercising of the
# quota-exhausted/blocking-wait acceptance criterion against the application's
# own singleton pool. A test needing its own independent quota starts a
# separately-named Letflow.SandboxPool instance instead (design doc §4.7
# INV-SP-7) rather than mutating this global default.
config :letflow, :sandbox_pool, max_concurrent_sandboxes: 1
