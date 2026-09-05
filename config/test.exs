import Config

# REQ-190 (docs/migration/decisions/0016-secrets-storage-backend.md §B):
# config/runtime.exs's LETFLOW_SECRETS_MASTER_KEY startup check runs in
# EVERY environment, including test/CI -- it must never be weakened to make
# tests pass. config/test.exs runs (as part of config/config.exs's
# import_config chain) before config/runtime.exs at boot, so System.put_env/2
# here is what supplies a real, valid, test-only 64-hex-char value ahead of
# that check -- one of the two mechanisms the design doc leaves open
# (config/test.exs vs. a System.put_env/2 call in test/test_helper.exs);
# config/test.exs is chosen since it runs strictly before runtime.exs is
# evaluated, which test_helper.exs (loaded only after the application has
# already started) cannot guarantee. Only set if not already present in the
# real environment, so a host that deliberately exports its own value (e.g.
# CI secrets) is not silently overridden. Non-all-zeros, non-all-f's (an
# arbitrary real 32-byte value, hex-encoded) so it also passes the
# literal-value rejection check.
System.get_env("LETFLOW_SECRETS_MASTER_KEY") ||
  System.put_env(
    "LETFLOW_SECRETS_MASTER_KEY",
    "3f1c9a2e7b4d6081f5a3c8e2b7d4f6091a3c5e7b9d2f4a6c8e1b3d5f7a9c2e4b"
  )

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

# REQ-186: don't start Letflow.Scheduler.Poller under test at all -- its
# very first tick runs with zero delay and queries Letflow.Repo from a
# process no test process is an ancestor of, which under
# Ecto.Adapters.SQL.Sandbox's default :manual mode raises
# DBConnection.OwnershipError repeatedly until Letflow.Supervisor's own
# restart intensity is exceeded and the whole application (Letflow.Repo
# included) shuts down. See lib/letflow/application.ex's
# scheduler_children/0. Letflow.Scheduler's own tests call
# poll_and_fire/1 directly; a test of the Poller GenServer itself starts
# its own instance explicitly.
config :letflow, start_scheduler: false

# REQ-214: don't start Letflow.Engine.ServiceTaskDispatcher.Poller under
# test either -- identical DBConnection.OwnershipError hazard as
# start_scheduler above (its own first tick runs with zero delay and
# queries Letflow.Repo from a process no test process is an ancestor of).
# A distinct, independent config key from :start_scheduler -- see
# lib/letflow/application.ex's service_task_dispatcher_children/0.
# Letflow.Engine.ServiceTaskDispatcher's own tests call poll_and_dispatch/1
# directly; a test of the Poller GenServer itself starts its own instance
# explicitly.
config :letflow, start_service_task_dispatcher: false

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
  #
  # ISS-0217: scripts/test_parallel.sh's own N sibling partitions are each a
  # distinct OS pid too, so ISS-0110's tag alone made every partition look like an
  # unrelated external invocation to every OTHER partition, deferring the reaper's
  # sweep unconditionally for the whole run. TEST_PARALLEL_GROUP, when set, is one
  # value shared by every partition a single test_parallel.sh invocation launches
  # (exported once before forking them) -- folding it into the tag lets the reaper
  # recognise same-group connections as expected siblings rather than external
  # hazards, while a connection with no matching group (a genuinely separate
  # invocation, nested or otherwise) still reads as external exactly as before.
  parameters: [
    application_name:
      "letflow_mixtest_#{System.pid()}" <>
        case System.get_env("TEST_PARALLEL_GROUP") do
          nil -> ""
          group -> "_grp#{group}"
        end
  ]

# ISS-0480 (design iss0113-tenant-fixture-sandbox-restore-opt-in.md §10.3.4): a
# second, dedicated Ecto.Repo used only by
# Letflow.TenantFixture.provisioned_tenant!/1 for tenant-schema provisioning,
# on its own pool/DBConnection.Ownership.Manager entirely separate from
# Letflow.Repo's own -- so a Sandbox.mode/2 call made during provisioning can
# never check in a connection belonging to some other, unrelated async test
# that never calls TenantFixture at all (the structural fix for ISS-0480's
# blast radius). Same physical database as Letflow.Repo (same
# database:/hostname:/port:, same MIX_TEST_PARTITION scoping) -- provisioning
# still needs to see and be seen by the same per-partition database
# Letflow.Repo connections use, only through a different connection/pool.
#
# pool_size is a FIXED constant (2), not schedulers_online()-derived --
# design §10.2.2: TenantProvisioning.provision_tenant_schema/1 already
# serializes concurrent provisioning attempts at the Postgres advisory-lock
# level, so this pool does not need scheduler-wide concurrency, only enough
# headroom (one in-flight provisioning call plus one spare) that a second
# concurrent TenantFixture caller queues rather than blocking on a pool of
# exactly 1. Kept in sync with scripts/test_parallel.sh's own
# PROVISIONING_POOL_SIZE bash constant (design §10.2.2's closing bullet,
# OQ-8) -- update both if this ever changes.
#
# ISS-0110/ISS-0217: application_name carries the exact same tag-derivation
# logic as Letflow.Repo's own block above (same System.pid()/
# TEST_PARALLEL_GROUP inputs), so every connection this repo opens reports
# the SAME application_name as this invocation's Letflow.Repo connections --
# Letflow.TenantSchemaReaper's pg_stat_activity-based liveness guard
# (test/support/tenant_schema_reaper.ex) matches connections by tag, not by
# a one-connection-per-test-process assumption, so this repo's connections
# are correctly recognised as belonging to the same invocation/partition-group,
# never counted as an unexpected external one (design §10.7 OQ-6, checked
# directly against that module's real source, not assumed).
config :letflow, Letflow.Test.ProvisioningRepo,
  username: "letflow",
  password: "letflow",
  database: "letflow_test#{System.get_env("MIX_TEST_PARTITION")}",
  hostname: "localhost",
  port: db_port,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 2,
  parameters: [
    application_name:
      "letflow_mixtest_#{System.pid()}" <>
        case System.get_env("TEST_PARALLEL_GROUP") do
          nil -> ""
          group -> "_grp#{group}"
        end
  ]

# REQ-128: real local Keycloak issuer, same as config/dev.exs (see that
# file's comment for the full rationale and docker-compose.yml's keycloak
# service). Duplicated from config/dev.exs: this repo's config files don't
# cascade (each env file loads independently via config.exs's
# import_config "#{config_env()}.exs"), so the :oidc key must be set here
# too or it's absent under MIX_ENV=test.
#
# token_verifier is overridden here (unlike dev/prod's real
# Letflow.Oidc.TokenVerifier.Oidcc adapter) to Letflow.Oidc.TokenVerifierDouble
# — mix test/scripts/test_parallel.sh runs do not depend on a real Keycloak
# being up (see lib/letflow/design/req021-auth-plug-pipeline.md §3.2); the
# issuer string is still updated to the real local one (rather than left as
# the old placeholder) purely so Oidcc.ProviderConfiguration.Worker has a
# real host to resolve discovery against on the rare run where Keycloak
# happens to be reachable, and so dev/test stay in sync.
{keycloak_port, _bindings} = Code.eval_file(Path.expand("keycloak_port.exs", __DIR__))

config :letflow, :oidc,
  issuer: "http://localhost:#{keycloak_port}/realms/bpm-default",
  provider_name: Letflow.Oidc.DefaultProvider,
  client_id: "letflow-web",
  signing_algs: ["RS256"],
  token_verifier: Letflow.Oidc.TokenVerifierDouble,
  # Same as config/dev.exs -- see lib/letflow/application.ex's
  # provider_configuration_opts comment. Not set in config/prod.exs.
  allow_unsafe_http: true

# Duplicated from config/dev.exs (this repo's config files don't cascade —
# see the :oidc key's comment above for the same note). Per-realm
# claim-path configuration for Letflow.Oidc.ClaimMapping, distinct from the
# :oidc key. A realm with no entry here falls back to
# Letflow.Oidc.ClaimMappingConfig.default/1.
# Key unchanged (REQ-128 deliberately keeps the realm name "bpm-default" --
# see the :oidc issuer comment in config/dev.exs).
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
# Key unchanged (REQ-128), same reason as :oidc_claim_mapping above.
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

# REQ-155: shorter-than-production default so a test exercising the 2-arity
# execute_with_manifest/2 default path (rather than /3's explicit :timeout_ms) does
# not wait out the full production default on a timeout. Tests that need a specific
# timeout value use the 3-arity overload directly rather than mutating this global.
#
# REQ-155 rework 1 (RELEASE-VALIDATOR step-05 FAIL): 200ms had no headroom under
# scripts/test_parallel.sh's 8-way parallel load and intermittently timed out
# unrelated 2-arity tests that do real (if small) Lua work -- e.g. "manifest hash
# correctness ... returns the SHA-256 of the script source on success" -- not just
# the near-zero-work mismatch-error path RELEASE-VALIDATOR originally reproduced.
# 1500ms still measured a timeout under real 8-way parallel load (elixir-dev rework
# 1, observed run), so raised further to 5000ms for real headroom against BEAM
# scheduler contention across 8 concurrent partitions. REQ-155's own timing tests
# (T1/T2/T4/T5) already pass an explicit :timeout_ms via the 3-arity overload and
# are unaffected by this default.
config :letflow, lua_wallclock_timeout_ms: 5000

# REQ-203 Step 2d rework2 (REVIEWER recheck1 FAIL item 1): compile-time kill
# switch for Letflow.Repository.Activation's test-only pause seam
# (`maybe_add_test_pause_step/4`, see that module's `@typep test_opts` doc).
# Resolved via `Application.compile_env/3` (this codebase's own established
# pattern for a test-only production seam -- see
# lib/letflow/design/req021-auth-plug-pipeline.md's OQ-5), defaulting to
# `false` everywhere this key is absent (config/dev.exs, config/prod.exs).
# Only set to `true` here, so the pause step can execute only under
# MIX_ENV=test.
config :letflow, activation_test_hooks_enabled?: true
