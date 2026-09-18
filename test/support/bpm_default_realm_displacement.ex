defmodule Letflow.Support.BpmDefaultRealmDisplacement do
  @moduledoc """
  REQ-370 rework (TEST-RUNNER report `test/reports/report-20260918-WF02REQ370-20260918.yaml`,
  group A): `priv/repo/migrations/20260918173137_seed_default_tenant.exs` now
  permanently binds exactly one tenant to `idp_realm_id: "bpm-default"` in every
  migrated database (`tenants_idp_realm_id_partial_index` enforces at most one row per
  `idp_realm_id`, REQ-019). Several pre-existing test files need EXCLUSIVE, test-owned
  control of that binding for one test's duration — a fresh, empty schema they alone
  write to (`test/letflow/plugs/auth_pipeline_test.exs`'s AC1 tests,
  `test/letflow/plugs/api_pipeline_integration_test.exs`'s AC2/AC4/AC5 tests,
  `test/letflow/routers/req077_promotion_pipeline_test.exs`'s design §12.9 smoke test),
  or, for one case (`auth_pipeline_test.exs`'s AC4 "tenant resolution fails" test), no
  binding at all. `test/letflow/identity_test.exs`'s
  `resolve_tenant_by_realm/1`/`resolve_realm_by_tenant/1` tests only need a
  consistent READ of whichever tenant currently holds the binding.

  `displace!/0` deletes whatever tenant currently holds the `"bpm-default"` binding
  (normally the migration-seeded row) and registers an `on_exit/1` that re-inserts a
  row with the SAME `slug`/`display_name`/`idp_realm_id`, so every later test still
  finds the permanently-seeded tenant it expects.

  ## Mutual exclusion (REQUIRED — do not remove)

  **Two escalating bugs fixed while building this, both reproduced live, neither
  merely suspected:**

  1. First cut assumed `async: false` alone gave full mutual exclusion against every
     other test in the suite — it does not (only against other `async: false`
     modules, and even that boundary is not the whole story once other genuinely
     concurrent processes are touching the same database).
  2. Second cut used a plain BEAM-process `Agent` as a mutex — this correctly
     serializes every test PROCESS within one `mix test` VM, but this project
     routinely has **multiple separate `mix test`/`scripts/test_parallel.sh`
     invocations running as distinct OS processes against the same shared,
     non-partitioned default test database** (confirmed live via
     `SELECT application_name, count(*) FROM pg_stat_activity GROUP BY
     application_name`, which showed two distinct `letflow_mixtest_*` connections
     simultaneously while diagnosing this). An `Agent` is per-VM state — it cannot
     serialize across OS processes at all, so this still raced.

  The actual fix: a real Postgres session-scoped advisory lock
  (`pg_advisory_lock`/`pg_advisory_unlock`), held on a **dedicated `Postgrex`
  connection opened outside Ecto's own pool** (`Postgrex.start_link/1`, config
  copied from `Letflow.Repo.config/0`) — deliberately NOT `Repo.query!/2`, since
  Ecto's pool checks out a (potentially different) physical connection per call, and
  advisory locks are tied to the specific session/connection that acquired them: a
  release attempted from a different connection than the one that acquired the lock
  silently does nothing, leaking the lock for the life of that connection. Owning one
  dedicated connection end to end (acquire on it, release on that exact same one)
  sidesteps that hazard entirely, and — being a real Postgres lock, not BEAM state —
  correctly serializes across any number of concurrently-running `mix test` OS
  processes sharing the same database, which is the actual scope this problem needs
  covering at.

  Switches `Ecto.Adapters.SQL.Sandbox` to global `:auto` mode itself (idempotent to
  call again if the caller already has) — the migration-seeded row is real, committed
  Postgres state, invisible to/unreachable from a normal sandboxed transaction.
  """

  alias Letflow.Identity.Tenant
  alias Letflow.Repo

  # A fixed, arbitrary 63-bit-safe integer -- pg_advisory_lock's key, scoped to this
  # one purpose only (any other advisory-lock use elsewhere in this codebase must
  # pick its own distinct key to avoid an unrelated collision).
  @lock_key 847_331_009

  @doc """
  Removes whatever tenant currently holds the `"bpm-default"` `idp_realm_id` binding
  (a no-op if none does), and schedules its restoration via `ExUnit.Callbacks.on_exit/1`
  — the lock acquired here is held on its own dedicated connection until that
  restoration completes, then released and that connection closed, as the very last
  step. Must be called from within a running ExUnit test process.
  """
  @spec displace!() :: :ok
  def displace! do
    lock_conn = acquire_dedicated_lock!()
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    case Repo.get_by(Tenant, idp_realm_id: "bpm-default") do
      nil ->
        ExUnit.Callbacks.on_exit(fn -> release_dedicated_lock!(lock_conn) end)
        :ok

      %Tenant{} = existing ->
        restore_attrs = %{
          slug: existing.slug,
          display_name: existing.display_name,
          idp_realm_id: existing.idp_realm_id
        }

        ExUnit.Callbacks.on_exit(fn ->
          Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

          %Tenant{}
          |> Tenant.create_changeset(restore_attrs, :enabled)
          |> Repo.insert!()

          release_dedicated_lock!(lock_conn)
        end)

        Repo.delete!(existing)
        :ok
    end
  end

  @doc """
  Runs `fun` (typically a read of whichever tenant currently holds the `"bpm-default"`
  binding) while holding the same advisory lock `displace!/0` uses, on its own
  dedicated connection released immediately after — for a caller that only needs a
  consistent snapshot, not exclusive ownership for a whole test's duration.
  """
  @spec with_lock((-> result)) :: result when result: term()
  def with_lock(fun) when is_function(fun, 0) do
    lock_conn = acquire_dedicated_lock!()

    try do
      fun.()
    after
      release_dedicated_lock!(lock_conn)
    end
  end

  defp acquire_dedicated_lock! do
    # Repo.config/0 includes :pool (config/test.exs's Ecto.Adapters.SQL.Sandbox, this
    # repo's own sandbox pool adapter) and :pool_size -- neither is a valid Postgrex
    # pool option (Postgrex.start_link/1 raises UndefinedFunctionError against
    # Ecto.Adapters.SQL.Sandbox.child_spec/1 if passed through unchanged, confirmed
    # empirically). Dropped here so this dedicated connection is a genuinely separate,
    # unpooled Postgrex connection outside Ecto's own pool machinery entirely.
    opts = Repo.config() |> Keyword.drop([:pool, :pool_size])
    {:ok, lock_conn} = Postgrex.start_link(opts)
    Postgrex.query!(lock_conn, "SELECT pg_advisory_lock($1)", [@lock_key])
    lock_conn
  end

  defp release_dedicated_lock!(lock_conn) do
    Postgrex.query!(lock_conn, "SELECT pg_advisory_unlock($1)", [@lock_key])
    GenServer.stop(lock_conn)
  end
end
