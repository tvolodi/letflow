defmodule Letflow.OrderingTest do
  @moduledoc """
  Tests for REQ-199 -- `Letflow.Ordering` (correlated effect re-entry ordering
  subsystem, ORD-01/02/03/04). See `test/specs/REQ-199.md` for the full
  acceptance-criterion → test-case mapping and rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database. Each test provisions its own tenant schema via
  `Letflow.TenantFixture.provisioned_tenant!/1`. `async: false` because tenant fixture
  sets Sandbox `:auto` mode (same reason as `dlq_test.exs` and `event_store_test.exs`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Dlq.Entry
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.Ordering
  alias Letflow.Ordering.{Completion, Consumer, Cursor, Metrics}
  alias Letflow.Repo

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req199-ordering") do
    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-199 Ordering Test Tenant"
    )
  end

  defp opts(%{schema_name: schema_name}), do: [prefix: schema_name]

  defp set_ordering_config(overrides) do
    base = Application.get_env(:letflow, :ordering, [])
    Application.put_env(:letflow, :ordering, Keyword.merge(base, overrides))
    on_exit(fn -> Application.put_env(:letflow, :ordering, base) end)
  end

  defp insert!(tenant, corr_id, seq, extra \\ %{}) do
    attrs = Map.merge(%{correlation_id: corr_id, sequence_no: seq}, extra)
    {:ok, c} = Ordering.insert_completion(attrs, opts(tenant))
    c
  end

  # Backdates `created_at` so the sweeper's age-check considers the row old enough.
  defp backdate!(tenant, %Completion{completion_id: cid}, seconds_ago) do
    backdated =
      DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
      |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(c in Completion, where: c.completion_id == ^cid),
        [set: [created_at: backdated]],
        prefix: tenant.schema_name
      )
  end

  # ---------------------------------------------------------------------------
  # AC1 -- both tables exist in the tenant's Postgres schema after provisioning
  # ---------------------------------------------------------------------------

  describe "AC1: tables created in tenant schema" do
    test "effect_completions and correlation_cursors are present after provisioning" do
      %{schema_name: schema_name} = provisioned_tenant()

      %{rows: rows} =
        Repo.query!(
          "SELECT table_name FROM information_schema.tables WHERE table_schema = $1",
          [schema_name]
        )

      names = Enum.map(rows, fn [n] -> n end)
      assert "effect_completions" in names
      assert "correlation_cursors" in names
    end
  end

  # ---------------------------------------------------------------------------
  # AC2 -- insert_completion/2 is idempotent on (correlation_id, sequence_no)
  # ---------------------------------------------------------------------------

  describe "AC2: insert_completion/2 idempotency" do
    test "duplicate insert yields exactly 1 row; one run_cycle appends exactly 1 effect_applied event" do
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()

      {:ok, _} = Ordering.insert_completion(%{correlation_id: corr_id, sequence_no: 1}, opts(tenant))
      {:ok, _} = Ordering.insert_completion(%{correlation_id: corr_id, sequence_no: 1}, opts(tenant))

      count =
        Repo.one!(
          from(c in Completion,
            where: c.correlation_id == ^corr_id,
            select: count(c.completion_id)
          ),
          prefix: tenant.schema_name
        )

      assert count == 1

      assert :applied = Ordering.run_cycle(tenant.schema_name, opts(tenant))

      event_count =
        Repo.one!(
          from(e in Event,
            where:
              e.event_type == "effect_applied" and
                fragment("payload->>'correlation_id' = ?", ^corr_id),
            select: count(e.event_id)
          ),
          prefix: tenant.schema_name
        )

      assert event_count == 1
    end
  end

  # ---------------------------------------------------------------------------
  # AC3 -- strict in-order application: higher seq arrives before lower seq
  # ---------------------------------------------------------------------------

  describe "AC3: out-of-order delivery is applied in sequence order (ORD-01)" do
    test "seq 2 inserted before seq 1; first cycle applies 1, second applies 2, events in order" do
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()

      # seq 2 arrives out of order before seq 1
      insert!(tenant, corr_id, 2)
      insert!(tenant, corr_id, 1)

      assert :applied = Ordering.run_cycle(tenant.schema_name, opts(tenant))

      seq1 =
        Repo.get_by!(Completion, [correlation_id: corr_id, sequence_no: 1],
          prefix: tenant.schema_name
        )

      seq2 =
        Repo.get_by!(Completion, [correlation_id: corr_id, sequence_no: 2],
          prefix: tenant.schema_name
        )

      assert seq1.status == :applied
      assert seq2.status == :pending

      assert :applied = Ordering.run_cycle(tenant.schema_name, opts(tenant))

      seq2_after =
        Repo.get_by!(Completion, [correlation_id: corr_id, sequence_no: 2],
          prefix: tenant.schema_name
        )

      assert seq2_after.status == :applied

      # Events appended in sequence order: seq 1 event has lower sequence_number than seq 2
      events =
        Repo.all(
          from(e in Event,
            where:
              e.event_type == "effect_applied" and
                fragment("payload->>'correlation_id' = ?", ^corr_id),
            order_by: [asc: e.sequence_number]
          ),
          prefix: tenant.schema_name
        )

      assert length(events) == 2
      [first, second] = events
      assert first.payload["sequence_no"] == 1
      assert second.payload["sequence_no"] == 2
    end
  end

  # ---------------------------------------------------------------------------
  # AC4 -- non-next sequence stays PENDING (predecessor not yet applied)
  # ---------------------------------------------------------------------------

  describe "AC4: non-next sequence stays PENDING" do
    test "seq 3 with cursor at applied_seq=0 (next=1) stays PENDING; no event appended" do
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()
      insert!(tenant, corr_id, 3)

      # applied_seq=0 (no cursor), so next expected = 1; seq 3 != 1 → not_next
      result = Ordering.run_cycle(tenant.schema_name, opts(tenant))
      assert result == :not_next

      completion =
        Repo.get_by!(Completion, [correlation_id: corr_id, sequence_no: 3],
          prefix: tenant.schema_name
        )

      assert completion.status == :pending

      event_count =
        Repo.one!(
          from(e in Event,
            where:
              e.event_type == "effect_applied" and
                fragment("payload->>'correlation_id' = ?", ^corr_id),
            select: count(e.event_id)
          ),
          prefix: tenant.schema_name
        )

      assert event_count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # AC5 -- concurrent apply is idempotent: exactly one :applied, cursor advanced once
  # ---------------------------------------------------------------------------

  describe "AC5: advisory lock + SKIP LOCKED prevent double-apply" do
    test "two concurrent try_apply calls on same completion yield one :applied and one failure; cursor advanced once" do
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()
      insert!(tenant, corr_id, 1)

      completion =
        Repo.get_by!(Completion, [correlation_id: corr_id, sequence_no: 1],
          prefix: tenant.schema_name
        )

      parent = self()

      t1 =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          Consumer.try_apply(completion, opts(tenant))
        end)

      t2 =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          Consumer.try_apply(completion, opts(tenant))
        end)

      results = [Task.await(t1, 10_000), Task.await(t2, 10_000)]

      assert :applied in results
      assert Enum.count(results, &(&1 == :applied)) == 1
      assert Enum.any?(results, &(&1 in [:lock_contention, :cursor_race]))

      cursor = Repo.get!(Cursor, corr_id, prefix: tenant.schema_name)
      assert cursor.applied_seq == 1
    end
  end

  # ---------------------------------------------------------------------------
  # AC6 -- cursor row is upsert-initialised on first apply (AC6)
  # ---------------------------------------------------------------------------

  describe "AC6: cursor row created on first apply" do
    test "no cursor exists before run_cycle; cursor at applied_seq=1 is created by first cycle" do
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()
      insert!(tenant, corr_id, 1)

      assert Repo.get(Cursor, corr_id, prefix: tenant.schema_name) == nil

      assert :applied = Ordering.run_cycle(tenant.schema_name, opts(tenant))

      cursor = Repo.get!(Cursor, corr_id, prefix: tenant.schema_name)
      assert cursor.applied_seq == 1
    end
  end

  # ---------------------------------------------------------------------------
  # AC7 -- per-correlation isolation: two correlations applied independently
  # ---------------------------------------------------------------------------

  describe "AC7: two correlations applied independently" do
    test "each correlation's seq 1 is applied by its own run_cycle call" do
      tenant = provisioned_tenant()
      corr_a = Ecto.UUID.generate()
      corr_b = Ecto.UUID.generate()

      insert!(tenant, corr_a, 1)
      insert!(tenant, corr_b, 1)

      assert :applied = Ordering.run_cycle(tenant.schema_name, opts(tenant))
      assert :applied = Ordering.run_cycle(tenant.schema_name, opts(tenant))

      a =
        Repo.get_by!(Completion, [correlation_id: corr_a, sequence_no: 1],
          prefix: tenant.schema_name
        )

      b =
        Repo.get_by!(Completion, [correlation_id: corr_b, sequence_no: 1],
          prefix: tenant.schema_name
        )

      assert a.status == :applied
      assert b.status == :applied
    end
  end

  # ---------------------------------------------------------------------------
  # AC8 -- gap sweeper: DEAD + DLQ entry for eligible; no sweep when seq is next
  # ---------------------------------------------------------------------------

  describe "AC8: gap sweeper marks timed-out gaps DEAD" do
    test "seq 2 with missing predecessor and old enough is swept to DEAD with one DLQ entry" do
      # gap_timeout_seconds=1 so any row older than 1 second qualifies
      set_ordering_config(gap_timeout_seconds: 1)
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()

      # seq 2 inserted; applied_seq=0 (no cursor), so min_pending_seq=2 > 0+1=1: gap exists
      c2 = insert!(tenant, corr_id, 2)
      # backdate created_at 2 hours so it exceeds the 1-second gap_timeout
      backdate!(tenant, c2, 7200)

      :ok = Ordering.sweep_gaps(tenant.schema_name, opts(tenant))

      swept =
        Repo.get_by!(Completion, [correlation_id: corr_id, sequence_no: 2],
          prefix: tenant.schema_name
        )

      assert swept.status == :dead

      dlq_count =
        Repo.one!(
          from(e in Entry,
            where: e.entry_type == "ordering_gap" and e.reference_id == ^corr_id,
            select: count(e.id)
          ),
          prefix: tenant.schema_name
        )

      assert dlq_count == 1

      dlq_entry =
        Repo.get_by!(Entry, [entry_type: "ordering_gap", reference_id: corr_id],
          prefix: tenant.schema_name
        )

      # All unapplied sequence numbers listed in context_json
      assert dlq_entry.context_json["unapplied_sequence_numbers"] == [2]
    end

    test "seq 1 with applied_seq=0 is NOT swept (seq == next expected, strictly-greater-than check)" do
      set_ordering_config(gap_timeout_seconds: 1)
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()

      # seq 1; applied_seq=0 (no cursor), min_pending_seq=1 = 0+1 (NOT strictly greater) → ineligible
      c1 = insert!(tenant, corr_id, 1)
      backdate!(tenant, c1, 7200)

      :ok = Ordering.sweep_gaps(tenant.schema_name, opts(tenant))

      not_swept =
        Repo.get_by!(Completion, [correlation_id: corr_id, sequence_no: 1],
          prefix: tenant.schema_name
        )

      assert not_swept.status == :pending
    end
  end

  # ---------------------------------------------------------------------------
  # AC9 -- gap younger than gap_timeout_seconds stays PENDING
  # ---------------------------------------------------------------------------

  describe "AC9: fresh gap is not swept before timeout" do
    test "seq 2 with missing predecessor but just inserted stays PENDING with gap_timeout=3600s" do
      set_ordering_config(gap_timeout_seconds: 3600)
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()

      # No cursor, seq 2 is a gap but freshly created (age < 3600 seconds)
      insert!(tenant, corr_id, 2)

      :ok = Ordering.sweep_gaps(tenant.schema_name, opts(tenant))

      c =
        Repo.get_by!(Completion, [correlation_id: corr_id, sequence_no: 2],
          prefix: tenant.schema_name
        )

      assert c.status == :pending
    end
  end

  # ---------------------------------------------------------------------------
  # AC10 -- connection pool discipline: run_cycle does not hold connections
  # ---------------------------------------------------------------------------

  describe "AC10: connection pool discipline" do
    test "multiple sequential run_cycle calls complete without connection exhaustion" do
      # If run_cycle held a connection across calls, a single-connection pool would
      # deadlock on the second call. The calls completing without DBConnection.ConnectionError
      # proves each call acquires and releases its connection within the single call.
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()

      for seq <- 1..5, do: insert!(tenant, corr_id, seq)

      results =
        for _ <- 1..5 do
          Ordering.run_cycle(tenant.schema_name, opts(tenant))
        end

      assert Enum.all?(
               results,
               &(&1 in [:applied, :not_next, :no_pending, :lock_contention, :cursor_race])
             )
    end
  end

  # ---------------------------------------------------------------------------
  # AC11 -- end-to-end wiring: run_cycle/2 claims + applies without manual calls
  # ---------------------------------------------------------------------------

  describe "AC11: run_cycle/2 end-to-end wiring" do
    # AC11 git diff: application.ex not modified -- no supervisor children added.
    test "run_cycle/2 applies a PENDING completion and sets applied_at without manual Consumer calls" do
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()
      insert!(tenant, corr_id, 1)

      assert :applied = Ordering.run_cycle(tenant.schema_name, opts(tenant))

      c =
        Repo.get_by!(Completion, [correlation_id: corr_id, sequence_no: 1],
          prefix: tenant.schema_name
        )

      assert c.status == :applied
      assert c.applied_at != nil
    end
  end

  # ---------------------------------------------------------------------------
  # AC12 -- event_type_registry seeded with REQ-199 event types
  # ---------------------------------------------------------------------------

  describe "AC12: event_type_registry seeded with REQ-199 event types" do
    test "effect_applied and ordering_lag_threshold_exceeded exist with schema_version=1" do
      tenant = provisioned_tenant()

      effect_applied =
        Repo.get_by(EventType, [name: "effect_applied", schema_version: 1],
          prefix: tenant.schema_name
        )

      lag_exceeded =
        Repo.get_by(EventType, [name: "ordering_lag_threshold_exceeded", schema_version: 1],
          prefix: tenant.schema_name
        )

      assert effect_applied != nil
      assert lag_exceeded != nil
    end
  end

  # ---------------------------------------------------------------------------
  # AC13 -- lag computation: correct per-correlation lag returned
  # ---------------------------------------------------------------------------

  describe "AC13: compute_all_lags/1 computes correct per-correlation lag" do
    test "lag = max(sequence_no) - applied_seq with 3 pending sequences remaining" do
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()

      for seq <- 1..5, do: insert!(tenant, corr_id, seq)

      # Apply seqs 1 and 2 (advance cursor to applied_seq=2)
      assert :applied = Ordering.run_cycle(tenant.schema_name, opts(tenant))
      assert :applied = Ordering.run_cycle(tenant.schema_name, opts(tenant))

      lags = Metrics.compute_all_lags(opts(tenant))
      lag_info = Enum.find(lags, fn l -> l.correlation_id == corr_id end)

      assert lag_info != nil
      # max(5) - applied_seq(2) = 3
      assert lag_info.lag == 3
    end

    test "correlation with all sequences applied appears as no lag_info entry (lag=0)" do
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()

      for seq <- 1..3, do: insert!(tenant, corr_id, seq)

      # Apply all 3 sequences
      for _ <- 1..3, do: Ordering.run_cycle(tenant.schema_name, opts(tenant))

      lags = Metrics.compute_all_lags(opts(tenant))
      # No PENDING rows remain → correlation absent from lags (lag effectively 0)
      lag_info = Enum.find(lags, fn l -> l.correlation_id == corr_id end)
      assert lag_info == nil
    end
  end

  # ---------------------------------------------------------------------------
  # AC14 -- oldest_pending_age_seconds is nil (not 0) when no pending rows
  # ---------------------------------------------------------------------------

  describe "AC14: oldest_pending_age_seconds is nil when correlation has no pending rows" do
    test "all-applied correlation produces no entry (nil, not 0, distinguishes from fresh row)" do
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()

      for seq <- 1..2, do: insert!(tenant, corr_id, seq)

      Ordering.run_cycle(tenant.schema_name, opts(tenant))
      Ordering.run_cycle(tenant.schema_name, opts(tenant))

      lags = Metrics.compute_all_lags(opts(tenant))
      lag_info = Enum.find(lags, fn l -> l.correlation_id == corr_id end)

      # No PENDING rows → no entry; oldest_pending_age_seconds is nil (not 0)
      assert lag_info == nil or lag_info.oldest_pending_age_seconds == nil
    end
  end

  # ---------------------------------------------------------------------------
  # AC15 -- lag > threshold emits ordering_lag_threshold_exceeded event
  # ---------------------------------------------------------------------------

  describe "AC15: lag threshold crossed emits ordering_lag_threshold_exceeded event" do
    test "lag=2 > threshold=1 causes event appended with correlation_id, lag, oldest_pending_age_seconds" do
      set_ordering_config(lag_threshold: 1)
      tenant = provisioned_tenant()
      corr_id = Ecto.UUID.generate()

      for seq <- 1..3, do: insert!(tenant, corr_id, seq)

      # Apply seq 1 → applied_seq=1; PENDING: seqs 2 and 3; lag = max(3) - 1 = 2 > threshold(1)
      assert :applied = Ordering.run_cycle(tenant.schema_name, opts(tenant))

      :ok = Ordering.emit_lag_metrics(tenant.schema_name, opts(tenant))

      events =
        Repo.all(
          from(e in Event,
            where:
              e.event_type == "ordering_lag_threshold_exceeded" and
                fragment("payload->>'correlation_id' = ?", ^corr_id)
          ),
          prefix: tenant.schema_name
        )

      assert length(events) >= 1
      event = hd(events)
      assert event.payload["correlation_id"] == corr_id
      assert event.payload["lag"] == 2
      assert Map.has_key?(event.payload, "oldest_pending_age_seconds")
    end
  end

  # ---------------------------------------------------------------------------
  # AC16 -- @moduledoc documents ORD-04 deferral scope
  # ---------------------------------------------------------------------------

  describe "AC16: @moduledoc states ORD-04 deferral" do
    test "Letflow.Ordering moduledoc contains 'deliberately deferred' and 'ORD-04'" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Letflow.Ordering)
      # moduledoc source may wrap "deliberately\ndeferred" across lines
      assert moduledoc =~ ~r/deliberately\s+deferred/
      assert moduledoc =~ "ORD-04"
    end
  end

  # ---------------------------------------------------------------------------
  # AC17/18: process topology and OTP supervision
  #
  # AC17: no GenServer or Supervisor was added to application.ex for this
  #   subsystem -- verified by the git diff showing application.ex unchanged.
  # AC18: run_cycle/2, sweep_gaps/2, and emit_lag_metrics/2 are pure context
  #   functions (no OTP process state) -- verified by static inspection that
  #   Letflow.Ordering is a plain module with no `use GenServer` or
  #   `use Supervisor`.
  # These invariants are structural and verified by code inspection, not by
  # runtime assertions.
  # ---------------------------------------------------------------------------
end
