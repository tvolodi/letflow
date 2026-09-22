defmodule Letflow.EventStore.PartitionMaintenanceTest do
  @moduledoc """
  Tests for `Letflow.EventStore.PartitionMaintenance` (REQ-376) —
  `ensure_future_partitions/2` (AC5) and `retire_month/3` (AC2/AC3/AC4,
  EO-001/EO-002/EO-003), plus `Letflow.EventStore.read/2`'s union-with-
  `events_archive` extension (EO-003) as it's exercised through this
  module's own retirement path. See `test/specs/REQ-376.md` for the full
  test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database
  anywhere in this file. Self-contained per DIRECTIVE T-4: every fixture
  helper below is defined in this file, not imported from
  `test/letflow/event_store_test.exs`, even though several mirror that
  file's own helpers of the same name/shape (`provisioned_tenant/1`,
  `seed_event!/5`, `seed_instance_sequence!/2,3`, `table_count/2`) —
  deliberate duplication, not drift: this file must stand on its own.

  ## Sandbox `:auto` mode, same reason as `event_store_test.exs`

  `Letflow.TenantProvisioning.replay_migrations/2` needs a second real DB
  connection the DataCase sandbox can't hand out, and several tests here
  spawn a genuinely concurrent `Task` against the same tenant schema
  (the EO-001 concurrent-write proof, and the `:pending_detach`
  crash-recovery induction) — both need Sandbox `:auto` mode, not the
  ordinary rolled-back-transaction mode. `async: false` for the whole
  module, for the identical reason `event_store_test.exs`'s own moduledoc
  states in full (ExUnit fully drains every `async: true` module before
  running any `async: false` module, and runs `async: false` modules one at
  a time) — this file's `capture_repo_queries/1` helper additionally
  depends on that guarantee: `:telemetry.attach/4` on
  `[:letflow, :repo, :query]` is process-global, not scoped to this test's
  own connection, so it is only a reliable signal when nothing else in the
  suite can be issuing a query concurrently.

  ## Fixture strategy — direct `Event`/`ArchivedEvent`/`InstanceSequence` seeding

  `retire_month/3` operates on `created_at` month boundaries `append/2`
  cannot backdate into (it always stamps `DateTime.utc_now()`, and no test
  here may depend on wall-clock time, `docs/guides/test_developer_guide.md`
  principle 3) — every fixture below seeds rows directly via each schema's
  own `insert_changeset/2` + `Repo.insert!/2`, the same idiom
  `event_store_test.exs` already established for the identical reason.

  ## Why `min_partition_age_days` is overridden to `1`, not left at the real default

  The real default (`PartitionMaintenance.min_partition_age_days/0`, 400
  days) would force every eligibility-dependent fixture to seed events with
  a `created_at` over a year in the past, which still works but adds no
  coverage over a much shorter, equally-real override — `eligible?/2`'s
  logic (`today >= last_day(month) + min_partition_age_days`) is exercised
  identically either way. Every override uses
  `with_event_retention_override/2` below, which restores the previous
  config in an `after` block unconditionally (including on test failure) —
  never leaks across tests, matching `event_store_test.exs`'s own
  `on_exit/1` cleanup discipline for a different global (`event_retention_policies`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EventStore
  alias Letflow.EventStore.ArchivedEvent
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.EventStore.PartitionMaintenance
  alias Letflow.EventStore.RetentionPolicy
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ===========================================================================
  # Tenant / schema fixtures — mirrors event_store_test.exs's own
  # provisioned_tenant/1 exactly (see that file's moduledoc for the full
  # ExUnit-ordering proof this relies on); duplicated here per DIRECTIVE T-4.
  # ===========================================================================

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req376"),
        display_name: "REQ-376 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant(_context \\ %{}) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  # No default argument: every call site below passes its own prefix
  # explicitly (see docs/anti-patterns.md's "a test helper's default argument
  # goes dead" entry, ISS-0069) -- confirmed by the compiler catching exactly
  # that dead-default warning when this previously carried `\\ "PM"`.
  defp unique_type_name(prefix) do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix \\ "IDK") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp table_count(schema, schema_name) do
    Repo.aggregate(schema, :count, prefix: schema_name)
  end

  defp seed_instance_sequence!(schema_name, instance_id, next_seq \\ 1) do
    %InstanceSequence{}
    |> InstanceSequence.insert_changeset(%{instance_id: instance_id, next_seq: next_seq})
    |> Repo.insert!(prefix: schema_name)
  end

  defp seed_event!(schema_name, instance_id, event_type, seq, created_at) do
    %Event{}
    |> Event.insert_changeset(%{
      event_id: Ecto.UUID.generate(),
      created_at: created_at,
      instance_id: instance_id,
      event_type: event_type,
      payload: %{"seeded" => true},
      actor_id: Ecto.UUID.generate(),
      sequence_number: seq,
      idempotency_key: unique_idempotency_key()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # Direct insert against the events_archive PARENT table (never a named
  # partition) -- Postgres itself routes it into events_archive_default,
  # since (per design §3.2 revised) no dedicated events_archive partition
  # exists for an as-yet-unretired month. This is the exact destination
  # archive/1's own ordinary early per-row moves land in, so this fixture
  # legitimately stands in for "rows archive/1 already moved before this
  # month became retirement-eligible" without needing archive/1 itself.
  defp seed_archived_default_event!(schema_name, instance_id, event_type, seq, created_at) do
    %ArchivedEvent{}
    |> ArchivedEvent.insert_changeset(%{
      event_id: Ecto.UUID.generate(),
      created_at: created_at,
      instance_id: instance_id,
      event_type: event_type,
      payload: %{"seeded" => true},
      actor_id: Ecto.UUID.generate(),
      sequence_number: seq,
      idempotency_key: unique_idempotency_key(),
      global_seq: seq,
      archived_at: created_at
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # event_retention_policies is GLOBAL (no :prefix) -- this file's tests run
  # under Sandbox :auto mode (via provisioned_tenant/1), so a row inserted
  # here is a real commit needing explicit on_exit/1 cleanup, exactly as
  # event_store_test.exs's own seed_retention_policy!/1 already established.
  defp seed_retention_policy!(attrs) do
    policy =
      %RetentionPolicy{}
      |> RetentionPolicy.insert_changeset(attrs)
      |> Repo.insert!()

    on_exit(fn ->
      Repo.delete_all(from(r in RetentionPolicy, where: r.id == ^policy.id))
    end)

    policy
  end

  # ===========================================================================
  # Month / partition-naming helpers -- deliberately independent
  # reimplementations of PartitionMaintenance's own private naming logic
  # (its month_bounds/2, partition_name/3 etc. aren't exported), so these
  # tests build fixtures the module under test did not itself compute.
  # ===========================================================================

  defp current_month do
    today = Date.utc_today()
    {today.year, today.month}
  end

  defp shift_months({year, month}, offset) do
    total = year * 12 + (month - 1) + offset
    {div(total, 12), rem(total, 12) + 1}
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp events_partition_name(year, month), do: "events_y#{year}m#{pad2(month)}"

  # String form, for inline DDL interpolation -- Postgres partition-bound
  # clauses reject bind parameters (see PartitionMaintenance's own
  # create_partition!/5 comment for the empirically-confirmed reason).
  defp month_bounds_str(year, month) do
    from = "#{year}-#{pad2(month)}-01"
    {next_year, next_month} = shift_months({year, month}, 1)
    to = "#{next_year}-#{pad2(next_month)}-01"
    {from, to}
  end

  # DateTime form, for genuine Postgrex bind parameters -- Postgrex's
  # timestamp encoder requires a %NaiveDateTime{}/%DateTime{} struct, not a
  # plain string (same constraint PartitionMaintenance's own month_bounds/2
  # comment documents empirically).
  defp month_bounds_dt(year, month) do
    from = NaiveDateTime.new!(year, month, 1, 0, 0, 0) |> DateTime.from_naive!("Etc/UTC")
    {next_year, next_month} = shift_months({year, month}, 1)
    to = NaiveDateTime.new!(next_year, next_month, 1, 0, 0, 0) |> DateTime.from_naive!("Etc/UTC")
    {from, to}
  end

  defp mid_month_timestamp(year, month) do
    NaiveDateTime.new!(year, month, 15, 12, 0, 0) |> DateTime.from_naive!("Etc/UTC")
  end

  # A month that is always eligible once min_partition_age_days is
  # overridden down to 1 (see this file's moduledoc) -- last calendar
  # month, regardless of which day "today" happens to be.
  defp eligible_past_month, do: shift_months(current_month(), -1)

  # Directly creates a month partition attached to `events`, matching
  # priv/repo/migrations/20260922000002_create_events_p_initial_partitions.exs's
  # own create_month_partition!/3 shape -- fabricates a past-month fixture
  # ensure_future_partitions/2 (which only ever looks forward from "now")
  # would never create on its own.
  defp create_events_month_partition!(schema_name, year, month) do
    partition = events_partition_name(year, month)
    {from_bound, to_bound} = month_bounds_str(year, month)

    Repo.query!(
      ~s{CREATE TABLE "#{schema_name}"."#{partition}" PARTITION OF "#{schema_name}".events FOR VALUES FROM ('#{from_bound}') TO ('#{to_bound}')}
    )

    partition
  end

  # ===========================================================================
  # Config-override helper (§4.4b's reconciliation_batch_size, §4.2's
  # min_partition_age_days) -- restores the previous value unconditionally.
  # ===========================================================================

  defp with_event_retention_override(overrides, fun) do
    previous = Application.get_env(:letflow, :event_retention, [])
    Application.put_env(:letflow, :event_retention, Keyword.merge(previous, overrides))

    try do
      fun.()
    after
      Application.put_env(:letflow, :event_retention, previous)
    end
  end

  # ===========================================================================
  # Catalog-inspection helpers -- direct pg_inherits queries, independent
  # reimplementations of PartitionMaintenance's own private catalog checks
  # (child_of?/3, pending_detach?/2, default_partition_attached?/1 aren't
  # exported) -- this file must verify real Postgres state itself, not trust
  # the module under test's own report of it.
  # ===========================================================================

  defp child_of?(schema_name, partition_name, parent_relname) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT 1
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class p ON p.oid = i.inhparent
        JOIN pg_namespace pn ON pn.oid = p.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2 AND pn.nspname = $1 AND p.relname = $3
        """,
        [schema_name, partition_name, parent_relname]
      )

    rows != []
  end

  defp pending_detach?(schema_name, partition_name) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT 1
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2 AND i.inhdetachpending = true
        """,
        [schema_name, partition_name]
      )

    rows != []
  end

  defp default_partition_attached?(schema_name) do
    child_of?(schema_name, "events_default", "events")
  end

  # Whether a real Postgres backend is still (or again) running the
  # DETACH ... CONCURRENTLY statement for `partition_name`, per
  # pg_stat_activity -- used to confirm a killed detacher Task's
  # underlying connection has actually been torn down server-side, not
  # just that the owning Elixir process is gone (DBConnection's teardown
  # of the checked-out connection is asynchronous with the Task's death).
  defp alter_partition_backend_active?(schema_name, partition_name) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        ~s{SELECT 1 FROM pg_stat_activity WHERE query ILIKE $1},
        ["%DETACH PARTITION \"#{schema_name}\".\"#{partition_name}\"%"]
      )

    rows != []
  end

  # ===========================================================================
  # Query-log capture -- real :telemetry, the same [:letflow, :repo, :query]
  # event test/letflow/metrics/registry_test.exs's own
  # "handle_repo_query/3 derives query_type..." test confirms carries a
  # %{query: <raw SQL text>} metadata shape. See this file's moduledoc for
  # why this is only a reliable signal under async: false.
  # ===========================================================================

  defp capture_repo_queries(fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      fn _event, _measurements, metadata, agent ->
        Agent.update(agent, fn queries -> [metadata[:query] | queries] end)
      end,
      agent
    )

    try do
      result = fun.()
      {result, Agent.get(agent, &Enum.reverse/1)}
    after
      :telemetry.detach(handler_id)
      Agent.stop(agent)
    end
  end

  defp mentions_row_scoped_statement?(query, needle) when is_binary(query) do
    String.contains?(query, needle) and
      (String.contains?(query, "DELETE FROM") or
         (String.contains?(query, "INSERT INTO") and String.contains?(query, "SELECT ")))
  end

  defp mentions_row_scoped_statement?(_query, _needle), do: false

  # Bounded poll for a real system condition (pg_inherits.inhdetachpending
  # actually flipping true) -- not a blind Process.sleep, and not the kind
  # of "unseeded randomness"/wall-clock dependency DIRECTIVE 3 forbids: the
  # thing being waited on is a real, externally-observable Postgres catalog
  # state, and a timeout is a genuine test failure (the interrupted-detach
  # state was never reached), not a flaky pass/fail coin flip.
  defp wait_until(check_fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(check_fun, deadline)
  end

  defp do_wait_until(check_fun, deadline) do
    cond do
      check_fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        do_wait_until(check_fun, deadline)
    end
  end

  defp protected_count_across_both_tables(schema_name, event_type) do
    live =
      Event
      |> where([e], e.event_type == ^event_type)
      |> Repo.aggregate(:count, prefix: schema_name)

    archived =
      ArchivedEvent
      |> where([a], a.event_type == ^event_type)
      |> Repo.aggregate(:count, prefix: schema_name)

    live + archived
  end

  defp events_archive_default_count_in_range(schema_name, year, month) do
    {from_bound, to_bound} = month_bounds_dt(year, month)

    %Postgrex.Result{rows: [[count]]} =
      Repo.query!(
        ~s{SELECT count(*) FROM "#{schema_name}"."events_archive_default" WHERE created_at >= $1 AND created_at < $2},
        [from_bound, to_bound]
      )

    count
  end

  # ===========================================================================
  # AC5 -- ensure_future_partitions/2 (design §3, coverage map §8 row 5)
  # ===========================================================================

  describe "ensure_future_partitions/2 (AC5)" do
    test "creates exactly the additional months beyond the default lookahead, idempotent on a second call" do
      %{schema_name: schema_name} = provisioned_tenant()

      {cy, cm} = current_month()

      expected_new =
        for offset <- 3..5 do
          {y, m} = shift_months({cy, cm}, offset)
          events_partition_name(y, m)
        end

      assert {:ok, %{events_created: created, archive_created: []}} =
               PartitionMaintenance.ensure_future_partitions(schema_name, months_ahead: 5)

      assert Enum.sort(created) == Enum.sort(expected_new)

      for partition <- expected_new do
        assert child_of?(schema_name, partition, "events")
      end

      assert {:ok, %{events_created: [], archive_created: []}} =
               PartitionMaintenance.ensure_future_partitions(schema_name, months_ahead: 5)
    end
  end

  # ===========================================================================
  # AC2/EO-001 -- whole-partition DDL only, concurrent-write-safe
  # (design §4.3.3/§5 test shape)
  # ===========================================================================

  describe "AC2/EO-001 -- whole-partition DDL only" do
    test "issues zero per-row DELETE/row-scoped INSERT when nothing needs reconciling" do
      %{schema_name: schema_name} = provisioned_tenant()

      with_event_retention_override([min_partition_age_days: 1], fn ->
        {year, month} = eligible_past_month()
        partition = create_events_month_partition!(schema_name, year, month)

        {result, queries} =
          capture_repo_queries(fn ->
            PartitionMaintenance.retire_month(schema_name, year, month)
          end)

        assert {:ok,
                %{
                  retired_partition: ^partition,
                  protected_rows_relocated: 0,
                  default_partition_rows_reconciled: 0,
                  resumed_from: :not_started
                }} = result

        refute Enum.any?(queries, &String.contains?(&1, "DELETE FROM"))
        refute Enum.any?(queries, &mentions_row_scoped_statement?(&1, partition))
        refute Enum.any?(queries, &mentions_row_scoped_statement?(&1, "events_archive_default"))

        assert child_of?(schema_name, partition, "events_archive")
      end)
    end

    test "a concurrent write to a different, live partition completes while retirement runs" do
      %{schema_name: schema_name} = provisioned_tenant()

      with_event_retention_override([min_partition_age_days: 1], fn ->
        {year, month} = eligible_past_month()
        create_events_month_partition!(schema_name, year, month)

        {cy, cm} = current_month()
        live_instance_id = Ecto.UUID.generate()
        live_type = unique_type_name("LIVE")

        concurrent_write =
          Task.async(fn ->
            seed_event!(schema_name, live_instance_id, live_type, 1, mid_month_timestamp(cy, cm))
          end)

        assert {:ok, %{resumed_from: :not_started}} =
                 PartitionMaintenance.retire_month(schema_name, year, month)

        # Bounded wait -- if retire_month/3's DDL had blocked concurrent DML
        # against the live (current-month) partition, this Task.await/2
        # itself is what would time out (EO-001's own claim), not merely
        # run slow.
        assert %Event{} = Task.await(concurrent_write, 5_000)

        assert table_count(Event, schema_name) == 1
      end)
    end
  end

  # ===========================================================================
  # Crash-recovery / idempotent resume (design §4.3.1/§4.3.3, 3 sub-cases)
  # ===========================================================================

  describe "crash-recovery / idempotent resume" do
    test "resumed from :detached_standalone (stopped after DETACH, before ATTACH)" do
      %{schema_name: schema_name} = provisioned_tenant()

      with_event_retention_override([min_partition_age_days: 1], fn ->
        {year, month} = eligible_past_month()
        partition = create_events_month_partition!(schema_name, year, month)

        # Steps run by hand, OUTSIDE retire_month/3 -- the exact sequence
        # detach_partition!/2 itself performs (events_default must be
        # detached first; Postgres rejects DETACH ... CONCURRENTLY outright
        # while a DEFAULT partition is attached).
        Repo.query!(
          ~s{ALTER TABLE "#{schema_name}"."events" DETACH PARTITION "#{schema_name}"."events_default"}
        )

        Repo.query!(
          ~s{ALTER TABLE "#{schema_name}"."events" DETACH PARTITION "#{schema_name}"."#{partition}" CONCURRENTLY}
        )

        Repo.query!(
          ~s{ALTER TABLE "#{schema_name}"."events" ATTACH PARTITION "#{schema_name}"."events_default" DEFAULT}
        )

        refute child_of?(schema_name, partition, "events")
        refute child_of?(schema_name, partition, "events_archive")

        assert {:ok,
                %{
                  retired_partition: ^partition,
                  resumed_from: :detached_standalone,
                  default_partition_rows_reconciled: 0
                }} = PartitionMaintenance.retire_month(schema_name, year, month)

        assert child_of?(schema_name, partition, "events_archive")
      end)
    end

    test "idempotent no-op resumed from :already_retired, no ATTACH/DETACH re-issued" do
      %{schema_name: schema_name} = provisioned_tenant()

      with_event_retention_override([min_partition_age_days: 1], fn ->
        {year, month} = eligible_past_month()
        partition = create_events_month_partition!(schema_name, year, month)

        assert {:ok, %{resumed_from: :not_started}} =
                 PartitionMaintenance.retire_month(schema_name, year, month)

        {result, queries} =
          capture_repo_queries(fn ->
            PartitionMaintenance.retire_month(schema_name, year, month)
          end)

        assert {:ok,
                %{
                  retired_partition: ^partition,
                  protected_rows_relocated: 0,
                  default_partition_rows_reconciled: 0,
                  resumed_from: :already_retired
                }} = result

        refute Enum.any?(queries, &String.contains?(&1, "DETACH PARTITION"))
        refute Enum.any?(queries, &String.contains?(&1, "ATTACH PARTITION"))

        assert child_of?(schema_name, partition, "events_archive")
      end)
    end

    @tag timeout: 30_000
    test "resumed from :pending_detach, a genuinely interrupted DETACH CONCURRENTLY" do
      %{schema_name: schema_name} = provisioned_tenant()

      with_event_retention_override([min_partition_age_days: 1], fn ->
        {year, month} = eligible_past_month()
        partition = create_events_month_partition!(schema_name, year, month)

        Repo.query!(
          ~s{ALTER TABLE "#{schema_name}"."events" DETACH PARTITION "#{schema_name}"."events_default"}
        )

        # A held-open transaction on a SEPARATE connection with a snapshot
        # predating the CONCURRENTLY detach below -- this is what forces
        # Postgres's own two-phase DETACH CONCURRENTLY to block in its
        # second (wait-for-old-snapshots) phase after committing phase 1
        # (inhdetachpending = true), giving a real window to interrupt it in.
        #
        # The holder and detacher are two independently-scheduled BEAM
        # processes with no inherent ordering guarantee between "holder
        # launched" and "holder's transaction has actually opened and taken
        # its snapshot" -- without a real handshake, the detacher can (and,
        # empirically, sometimes does) run its whole DETACH CONCURRENTLY to
        # completion before the holder's snapshot even exists, so the
        # interrupted state is never reached. test_pid explicitly hands off
        # to a message send only AFTER the holder's SELECT has executed
        # inside the open transaction, and the detacher is not started until
        # that message is received -- a genuine ready-signal, not a timing
        # guess.
        test_pid = self()

        {:ok, holder} =
          Task.start(fn ->
            Repo.transaction(fn ->
              Repo.query!(~s{SELECT count(*) FROM "#{schema_name}"."events"})
              send(test_pid, :holder_snapshot_open)

              receive do
                :release -> :ok
              after
                10_000 -> :ok
              end
            end)
          end)

        assert_receive :holder_snapshot_open,
                       5_000,
                       "holder transaction never reported its snapshot as open"

        detacher =
          Task.async(fn ->
            Repo.query!(
              ~s{ALTER TABLE "#{schema_name}"."events" DETACH PARTITION "#{schema_name}"."#{partition}" CONCURRENTLY}
            )
          end)

        assert wait_until(fn -> pending_detach?(schema_name, partition) end, 5_000),
               "DETACH ... CONCURRENTLY never reached pg_inherits.inhdetachpending = true"

        # Phase 1 already committed -- killing the still-blocked connection
        # now leaves a genuine, real interrupted-detach state behind, the
        # same shape a crashed BEAM node would leave mid-retirement.
        Task.shutdown(detacher, :brutal_kill)

        # Killing the detacher's Elixir process is not synchronous with its
        # underlying Postgres backend actually disconnecting -- DBConnection
        # tears down the checked-out connection asynchronously after
        # noticing the owner died. If the holder's blocking transaction is
        # released too soon, the still-technically-alive backend can finish
        # the DETACH for real before the disconnect reaches it, so the
        # "interrupted" state is never actually reached (the detach just
        # completes instead) -- empirically reproduced. Confirm, via a real,
        # externally-observable Postgres fact (the backend running this
        # exact ALTER statement is no longer present in pg_stat_activity),
        # that the kill has actually taken effect before releasing holder.
        assert wait_until(
                 fn -> not alter_partition_backend_active?(schema_name, partition) end,
                 3_000
               ),
               "detacher's Postgres backend was still running the ALTER after Task.shutdown/2"

        send(holder, :release)

        assert wait_until(fn -> pending_detach?(schema_name, partition) end, 5_000),
               "pending-detach state did not persist after interrupting the detach"

        assert {:ok,
                %{
                  retired_partition: ^partition,
                  resumed_from: :pending_detach
                }} = PartitionMaintenance.retire_month(schema_name, year, month)

        assert child_of?(schema_name, partition, "events_archive")
        refute pending_detach?(schema_name, partition)
      end)
    end
  end

  # ===========================================================================
  # EO-002 (design §4.4/§4.5 test shape)
  # ===========================================================================

  describe "EO-002 -- keep_forever count identical before/after retirement" do
    test "a keep_forever row's count across events UNION events_archive is unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()

      with_event_retention_override([min_partition_age_days: 1], fn ->
        {year, month} = eligible_past_month()
        create_events_month_partition!(schema_name, year, month)

        protected_type = unique_type_name("KEEP")
        ordinary_type = unique_type_name("ORD")
        seed_retention_policy!(%{event_type: protected_type, policy: :keep_forever})

        instance_id = Ecto.UUID.generate()
        ts = mid_month_timestamp(year, month)

        seed_event!(schema_name, instance_id, protected_type, 1, ts)
        seed_event!(schema_name, instance_id, ordinary_type, 2, ts)

        before_count = protected_count_across_both_tables(schema_name, protected_type)
        assert before_count == 1

        assert {:ok, %{protected_rows_relocated: 1, resumed_from: :not_started}} =
                 PartitionMaintenance.retire_month(schema_name, year, month)

        after_count = protected_count_across_both_tables(schema_name, protected_type)
        assert after_count == before_count

        # The relocation moved it OUT of events before the whole-partition
        # DETACH ran -- direct evidence, not just the summed count.
        assert table_count(Event, schema_name) == 0
      end)
    end
  end

  # ===========================================================================
  # §4.4b reconciliation, batched (design §4.4b test shape)
  # ===========================================================================

  describe "§4.4b -- events_archive_default reconciliation, batched" do
    test "pre-accumulated events_archive_default rows are swept in more than one batch" do
      %{schema_name: schema_name} = provisioned_tenant()

      with_event_retention_override(
        [min_partition_age_days: 1, reconciliation_batch_size: 3],
        fn ->
          {year, month} = eligible_past_month()
          partition = create_events_month_partition!(schema_name, year, month)

          instance_id = Ecto.UUID.generate()
          ts = mid_month_timestamp(year, month)
          event_type = unique_type_name("DFLT")

          # 7 rows at batch_size 3 -- ceil(7/3) == 3 batches, deliberately
          # more than the 5000-default single-batch case would ever exercise.
          for seq <- 1..7 do
            seed_archived_default_event!(schema_name, instance_id, event_type, seq, ts)
          end

          assert events_archive_default_count_in_range(schema_name, year, month) == 7

          assert {:ok,
                  %{
                    retired_partition: ^partition,
                    default_partition_rows_reconciled: 7,
                    resumed_from: :not_started
                  }} = PartitionMaintenance.retire_month(schema_name, year, month)

          assert events_archive_default_count_in_range(schema_name, year, month) == 0

          archived_count =
            ArchivedEvent
            |> where([a], a.event_type == ^event_type)
            |> Repo.aggregate(:count, prefix: schema_name)

          assert archived_count == 7
        end
      )
    end
  end

  # ===========================================================================
  # EO-003 (design §6 test shape)
  # ===========================================================================

  describe "EO-003 -- replay after retirement, no gap, no error" do
    test "an instance spanning two months returns every event, in order, after the older month retires" do
      %{schema_name: schema_name} = provisioned_tenant()

      with_event_retention_override([min_partition_age_days: 1], fn ->
        {old_year, old_month} = eligible_past_month()
        create_events_month_partition!(schema_name, old_year, old_month)

        {cy, cm} = current_month()

        instance_id = Ecto.UUID.generate()
        event_type = unique_type_name("EO3")
        seed_instance_sequence!(schema_name, instance_id, 4)

        old_ts = mid_month_timestamp(old_year, old_month)
        new_ts = mid_month_timestamp(cy, cm)

        seed_event!(schema_name, instance_id, event_type, 1, old_ts)
        seed_event!(schema_name, instance_id, event_type, 2, old_ts)
        seed_event!(schema_name, instance_id, event_type, 3, new_ts)

        assert {:ok, events_before} = EventStore.read(instance_id, prefix: schema_name)
        assert Enum.map(events_before, & &1.sequence_number) == [1, 2, 3]

        assert {:ok, %{resumed_from: :not_started}} =
                 PartitionMaintenance.retire_month(schema_name, old_year, old_month)

        assert {:ok, events_after} = EventStore.read(instance_id, prefix: schema_name)
        assert Enum.map(events_after, & &1.sequence_number) == [1, 2, 3]
        assert Enum.map(events_after, & &1.event_id) == Enum.map(events_before, & &1.event_id)
      end)
    end
  end

  # ===========================================================================
  # REVIEWER-accepted implementation corrections -- both now real,
  # load-bearing Postgres-behavior dependencies (decision 0037's
  # "Implementation-discovered corrections" section), each deserving its
  # own explicit test.
  # ===========================================================================

  describe "correction (a) -- events_default self-heals" do
    test "stays attached as DEFAULT after retirement, and a far-future write still lands there" do
      %{schema_name: schema_name} = provisioned_tenant()

      with_event_retention_override([min_partition_age_days: 1], fn ->
        {year, month} = eligible_past_month()
        create_events_month_partition!(schema_name, year, month)

        assert {:ok, %{resumed_from: :not_started}} =
                 PartitionMaintenance.retire_month(schema_name, year, month)

        assert default_partition_attached?(schema_name)

        # Functioning, not just cataloged: a created_at far outside every
        # dedicated partition's range must still insert successfully,
        # routed into events_default by Postgres itself.
        far_future_instance = Ecto.UUID.generate()
        far_future_ts = DateTime.utc_now() |> DateTime.add(3650 * 86_400, :second)

        event =
          seed_event!(schema_name, far_future_instance, unique_type_name("FAR"), 1, far_future_ts)

        # Repo.query!/3 is raw SQL -- it bypasses Ecto.Query's schema-driven
        # UUID casting, so a canonical dashed-string UUID must be dumped to
        # its 16-byte binary form by hand before use as a `uuid`-typed bind
        # parameter, or Postgrex rejects it with a DBConnection.EncodeError.
        %Postgrex.Result{rows: [[relname]]} =
          Repo.query!(
            ~s{SELECT tableoid::regclass::text FROM "#{schema_name}"."events" WHERE event_id = $1},
            [Ecto.UUID.dump!(event.event_id)]
          )

        assert relname =~ "events_default"
      end)
    end
  end

  describe "correction (b) -- archived_at real and non-null, excluded from read/2" do
    test "every retired row has a non-null archived_at, never exposed on the Event struct" do
      %{schema_name: schema_name} = provisioned_tenant()

      with_event_retention_override([min_partition_age_days: 1], fn ->
        {year, month} = eligible_past_month()
        partition = create_events_month_partition!(schema_name, year, month)

        instance_id = Ecto.UUID.generate()
        event_type = unique_type_name("ARC")
        seed_instance_sequence!(schema_name, instance_id)
        ts = mid_month_timestamp(year, month)

        seed_event!(schema_name, instance_id, event_type, 1, ts)
        seed_event!(schema_name, instance_id, event_type, 2, ts)

        assert {:ok, %{resumed_from: :not_started}} =
                 PartitionMaintenance.retire_month(schema_name, year, month)

        %Postgrex.Result{rows: [[null_count]]} =
          Repo.query!(
            ~s{SELECT count(*) FROM "#{schema_name}"."#{partition}" WHERE archived_at IS NULL}
          )

        assert null_count == 0

        assert {:ok, events} = EventStore.read(instance_id, prefix: schema_name)
        assert length(events) == 2

        for event <- events do
          refute Map.has_key?(Map.from_struct(event), :archived_at)
        end
      end)
    end
  end

  # ===========================================================================
  # Error cases
  # ===========================================================================

  describe "error cases" do
    test ":partition_not_eligible -- the current month, under the real default min_partition_age_days" do
      %{schema_name: schema_name} = provisioned_tenant()
      {year, month} = current_month()

      # No config override here -- exercises the real default (400 days).
      assert {:error, :partition_not_eligible} =
               PartitionMaintenance.retire_month(schema_name, year, month)
    end

    test ":partition_not_found -- a month with no partition under events, events_archive, or standalone" do
      %{schema_name: schema_name} = provisioned_tenant()
      {year, _month} = current_month()

      assert {:error, :partition_not_found} =
               PartitionMaintenance.retire_month(schema_name, year + 50, 1)
    end
  end
end
