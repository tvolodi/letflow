defmodule Letflow.Iss0979AuditChainLockTest do
  @moduledoc """
  Regression test for ISS-0979 -- `Letflow.Audit.insert_entry/3`'s pre-fix
  unlocked `fetch_chain_tail/2` read. See
  `lib/letflow/design/iss0979-audit-chain-lock.md` section 0 for the full
  defect: two independent `insert_entry/3` calls for the SAME tenant but
  DIFFERENT resource rows (so no shared business-row lock serializes them)
  could both read the same chain tail before either committed, both compute a
  `chain_hash`/`prev_chain_hash` pair against it, and both insert
  successfully -- forking the chain with no constraint violation to catch it.
  Running this test's `describe "concurrent inserts cannot fork the chain"`
  block against the pre-fix `fetch_chain_tail/2` (no lock) is expected to
  intermittently produce two entries sharing the same `prev_chain_hash`,
  failing the no-duplicate assertion below (design §5.3) -- intermittently,
  not deterministically, because it is a genuine race; the delay-injection
  test below forces the interleaving deterministically instead of relying on
  that alone.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database,
  and genuine concurrency: every `Task.async` body below runs against a real,
  separately-checked-out Postgres connection, not a simulated interleaving.
  `provisioned_tenant/0` below mirrors
  `test/letflow/engine_concurrency_test.exs`'s own `SandboxAutoMode.
  enter_auto_mode!/1` + `exit_auto_mode!/1` pairing (registered in that order
  so ExUnit's LIFO `on_exit/1` ordering runs cleanup before the mode is
  restored) rather than `SandboxAutoMode.provision!/2` (used by
  `test/letflow/audit_test.exs`), because this file's tests deliberately keep
  Sandbox `:auto` mode alive across real `Task.async` calls that run AFTER
  `provisioned_tenant/0` returns -- `provision!/2` would restore to `:manual`
  too early for that. Self-contained: provisions its own tenant schema, does
  not share fixtures with `test/letflow/audit_test.exs` or
  `test/letflow/engine_concurrency_test.exs` (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.SandboxAutoMode

  # N >= 8 per the design's own suggestion (design §7 OQ-1) -- this codebase
  # has no closer existing precedent for "how many racers make a race-window
  # miss implausible" than `engine_concurrency_test.exs`'s @instance_count
  # (100, chosen for pool-size/isolation reasons unrelated to this race), so
  # 8 is used as the floor the design itself names, not a borrowed number.
  @racer_count 8

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "iss0979-chainlock",
        display_name: "ISS-0979 Audit Chain Lock Test Tenant",
        teardown: false
      )

    # Registered FIRST so it runs LAST (ExUnit on_exit/1 is LIFO) -- this
    # file's tests keep :auto mode alive across real Task.async calls that
    # run after this function returns, same reasoning as
    # engine_concurrency_test.exs's own provisioned_tenant/0.
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Letflow.Repo) end)

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  defp base_attrs(overrides) do
    Map.merge(
      %{
        actor_id: nil,
        action: "iss0979.concurrent_write",
        resource_type: "definition",
        before_state: nil,
        after_state: %{"probe" => true},
        trace_id: nil
      },
      Map.new(overrides)
    )
  end

  # Loads every chain_hash/prev_chain_hash pair for the tenant, oldest first.
  defp load_entries(schema_name) do
    from(e in Entry, order_by: [asc: e.timestamp, asc: e.id])
    |> Repo.all(prefix: schema_name)
  end

  describe "concurrent inserts cannot fork the chain (design §5.1)" do
    test "N racers writing distinct resource rows for the same tenant never share a prev_chain_hash" do
      %{schema_name: schema_name} = provisioned_tenant()

      tasks =
        for n <- 1..@racer_count do
          Task.async(fn ->
            Audit.insert_entry(
              Repo,
              base_attrs(resource_id: "iss0979-res-#{n}"),
              schema_name
            )
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # No call should error under contention with this fix in place.
      assert Enum.all?(results, &match?({:ok, %Entry{}}, &1))

      entries = load_entries(schema_name)
      assert length(entries) == @racer_count

      prev_hashes = Enum.map(entries, & &1.prev_chain_hash)
      non_nil_prev_hashes = Enum.reject(prev_hashes, &is_nil/1)

      # A fork looks exactly like two entries both claiming the same
      # prev_chain_hash -- assert the multiset has no duplicates.
      assert length(non_nil_prev_hashes) == length(Enum.uniq(non_nil_prev_hashes))

      # Exactly one entry has a nil prev_chain_hash (the first of the N,
      # since the tenant's chain was empty going in).
      assert length(prev_hashes) - length(non_nil_prev_hashes) == 1

      assert {:ok, :valid} = Audit.verify_chain(schema_name)
    end
  end

  describe "the lock is actually exercised, not coincidentally missed (design §5.2)" do
    test "racers genuinely block on the chain lock, proven via an injected post-lock delay" do
      %{schema_name: schema_name} = provisioned_tenant()

      delay_ms = 200

      Application.put_env(
        :letflow,
        :audit_chain_lock_post_lock_delay_fun,
        fn -> Process.sleep(delay_ms) end
      )

      on_exit(fn ->
        Application.delete_env(:letflow, :audit_chain_lock_post_lock_delay_fun)
      end)

      started_at = System.monotonic_time(:millisecond)

      tasks =
        for n <- 1..@racer_count do
          Task.async(fn ->
            Audit.insert_entry(
              Repo,
              base_attrs(resource_id: "iss0979-delay-res-#{n}"),
              schema_name
            )
          end)
        end

      results = Task.await_many(tasks, 30_000)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert Enum.all?(results, &match?({:ok, %Entry{}}, &1))

      # If the lock were not actually serializing these racers, all N
      # `delay_fun` calls would overlap and total elapsed time would stay
      # close to one `delay_ms` window. With the lock genuinely held across
      # each racer's own delay, the racers are serialized at the lock, so
      # total elapsed time must be at least N delay windows.
      assert elapsed_ms >= @racer_count * delay_ms

      entries = load_entries(schema_name)
      assert length(entries) == @racer_count

      prev_hashes = Enum.map(entries, & &1.prev_chain_hash)
      non_nil_prev_hashes = Enum.reject(prev_hashes, &is_nil/1)
      assert length(non_nil_prev_hashes) == length(Enum.uniq(non_nil_prev_hashes))

      assert {:ok, :valid} = Audit.verify_chain(schema_name)
    end
  end
end
