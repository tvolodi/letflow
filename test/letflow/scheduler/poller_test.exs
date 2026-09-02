defmodule Letflow.Scheduler.PollerTest do
  @moduledoc """
  Tests for REQ-186's `Letflow.Scheduler.Poller` `GenServer` ticker itself.
  See `test/specs/REQ-186.md` (AC8) for the full acceptance-criterion ->
  test-case mapping.

  `config/test.exs` sets `start_scheduler: false` (see
  `lib/letflow/application.ex`'s own `scheduler_children/0` comment) --
  the Poller is deliberately never started under the ordinary test
  supervision tree, because its very first tick runs with zero delay and
  queries `Letflow.Repo` from a process no test process is an ancestor of,
  which under `Ecto.Adapters.SQL.Sandbox`'s default `:manual` mode raises
  `DBConnection.OwnershipError` repeatedly. This file starts its own Poller
  instance explicitly, per
  `handoffs/WF02-REQ186-20260829/step-03-test-designer.json`'s own
  instruction -- made safe here because `use Letflow.DataCase, async: false`
  puts `Ecto.Adapters.SQL.Sandbox` into `{:shared, self()}` mode for the
  whole test (see `test/support/data_case.ex`), so the Poller's own process
  (not a descendant of the test process) shares the same sandboxed
  connection as the test without needing an explicit `Sandbox.allow/3` call.

  `Letflow.SchedulerTest` (`test/letflow/scheduler_test.exs`) covers every
  other REQ-186 acceptance criterion by calling `Letflow.Scheduler`'s own
  functions directly, matching this codebase's established "context module
  tested without its process wrapper" precedent -- not duplicated here.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.ArchivedEvent
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Poller
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture
  alias Letflow.WebhookTestServer

  defp provisioned_tenant(slug_prefix \\ "req186-poller") do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-186 Poller Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # REQ-187: task's own node_type is TIMER (not HUMAN_TASK) -- firing a
  # timer now re-enters Letflow.Engine to advance the token off the :TIMER
  # node it's found sitting on via the timer's own token_id, so a timer
  # this file expects to actually *fire* successfully must be armed with
  # `token_id: live_token_id!/2`, matching this graph's own real live
  # token. `duration_iso8601` is far in the future (`P1D`) so
  # start_instance!/1's own automatic REQ-187 timer-arm never becomes due
  # during this test.
  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "P1D"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp live_token_id!(schema_name, instance_id) do
    TokenRecord
    |> where([t], t.instance_id == ^instance_id and t.status == :active)
    |> select([t], t.id)
    |> Repo.one!(prefix: schema_name)
    |> to_string()
  end

  defp start_instance!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name("req186-poller-def"),
                 version: "1.0.0",
                 graph: graph_human_task_end(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: activated.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_name("req186-poller-start")
               },
               prefix: schema_name
             )

    result.instance_id
  end

  defp put_scheduler_config(overrides) do
    original = Application.get_env(:letflow, :scheduler)
    Application.put_env(:letflow, :scheduler, overrides)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:letflow, :scheduler)
        val -> Application.put_env(:letflow, :scheduler, val)
      end
    end)
  end

  describe "AC8: Poller.handle_info(:tick, _) reads config fresh and uses the overridden poll_interval_ms" do
    test "a timer armed after the Poller's own first tick is still fired well within the overridden interval, far faster than the 5000ms default would allow" do
      put_scheduler_config(
        poll_interval_ms: 30,
        jitter_ms: 0,
        max_timers_per_cycle: 64,
        max_fire_retries: 3
      )

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)

      start_supervised!(Poller)

      # Let the Poller's own immediate (zero-delay) first tick run and
      # complete -- at this point no due timer exists yet, so it's a no-op.
      Process.sleep(20)

      fire_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      assert {:ok, timer} =
               Scheduler.create(
                 Letflow.Repo,
                 %{
                   instance_id: instance_id,
                   timer_type: "deadline",
                   node_id: "poller-ac8",
                   fire_at: fire_at,
                   token_id: live_token_id!(schema_name, instance_id)
                 },
                 prefix: schema_name
               )

      # Only a SECOND tick, scheduled at (overridden) poll_interval_ms after
      # the first, can pick this timer up. 300ms comfortably fits ~10 ticks
      # at the 30ms override, but is nowhere near one tick at the 5000ms
      # documented default -- if the Poller ignored the override (e.g. a
      # mutation hardcoding the default, or caching poll_interval_ms/0's
      # value at init/1 time instead of reading it fresh every tick), this
      # timer would still be pending when we check.
      Process.sleep(300)

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "fired"
    end
  end

  # ===================================================================================
  # REQ-188 Part 2 -- the periodic retention runner (ACs 5-7). See
  # test/specs/REQ-188.md for the full acceptance-criterion -> test-case map.
  # `Poller.handle_info(:tick, state)` is called directly as a plain function
  # (it is a public `@impl true` function, callable without starting the
  # GenServer process), matching the design doc's own §2.4 "Default-disabled
  # proof" note -- this sidesteps the Ecto.Sandbox ownership issue
  # `application.ex`'s own comment documents for why the Poller is disabled
  # by default in `config/test.exs`, and lets these tests assert on real row
  # counts (no mocking library exists in this codebase) rather than a call
  # count on a mock.
  # ===================================================================================

  defp table_count(schema, schema_name) do
    Repo.aggregate(schema, :count, prefix: schema_name)
  end

  defp unique_idempotency_key(prefix \\ "req188-poller-idk"),
    do: prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp seed_instance_sequence!(schema_name, instance_id, next_seq \\ 1) do
    %InstanceSequence{}
    |> InstanceSequence.insert_changeset(%{instance_id: instance_id, next_seq: next_seq})
    |> Repo.insert!(prefix: schema_name)
  end

  # Direct events row seeding with a caller-chosen created_at (deliberately in
  # the past for retention-eligibility), mirroring
  # test/letflow/event_store_test.exs's own seed_event!/7 fixture idiom (this
  # file's own copy since that one is private to its own module).
  defp seed_event!(schema_name, instance_id, created_at, seq \\ 1) do
    %Event{}
    |> Event.insert_changeset(%{
      event_id: Ecto.UUID.generate(),
      created_at: created_at,
      instance_id: instance_id,
      event_type: "req188_poller_test_event",
      payload: %{"seeded" => true},
      actor_id: Ecto.UUID.generate(),
      sequence_number: seq,
      idempotency_key: unique_idempotency_key()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  describe "AC5: the retention runner is disabled by default -- zero archive/1 calls over a full poll cycle" do
    test "an old, otherwise-eligible event is untouched after a tick, with no :retention_enabled config set" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      seed_instance_sequence!(schema_name, instance_id)

      old_created_at = ~U[2020-01-01 00:00:00.000000Z]
      seed_event!(schema_name, instance_id, old_created_at)

      assert table_count(Event, schema_name) == 1
      assert table_count(ArchivedEvent, schema_name) == 0

      assert Application.get_env(:letflow, :scheduler) == nil
      assert Scheduler.retention_enabled?() == false

      assert {:noreply, new_state} = Poller.handle_info(:tick, %{last_retention_run_at: nil})

      assert new_state.last_retention_run_at == nil
      assert table_count(Event, schema_name) == 1
      assert table_count(ArchivedEvent, schema_name) == 0
    end

    test "the guard stays closed across several ticks, regardless of how much wall-clock time has elapsed" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      seed_instance_sequence!(schema_name, instance_id)
      seed_event!(schema_name, instance_id, ~U[2020-01-01 00:00:00.000000Z])

      state =
        Enum.reduce(1..5, %{last_retention_run_at: nil}, fn _, state ->
          assert {:noreply, next_state} = Poller.handle_info(:tick, state)
          next_state
        end)

      assert state.last_retention_run_at == nil
      assert table_count(Event, schema_name) == 1
      assert table_count(ArchivedEvent, schema_name) == 0
    end
  end

  describe "AC6: enabling retention invokes archive/1 and moves rows older than the configured retention" do
    test "a tick moves the old event into events_archive and leaves the recent one in events" do
      put_scheduler_config(retention_enabled: true, retention_interval_ms: 0, retention_days: 30)

      %{schema_name: schema_name} = provisioned_tenant()
      old_instance_id = Ecto.UUID.generate()
      recent_instance_id = Ecto.UUID.generate()
      seed_instance_sequence!(schema_name, old_instance_id)
      seed_instance_sequence!(schema_name, recent_instance_id)

      old_created_at =
        DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:microsecond)

      recent_created_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      seed_event!(schema_name, old_instance_id, old_created_at)
      seed_event!(schema_name, recent_instance_id, recent_created_at)

      assert table_count(Event, schema_name) == 2
      assert table_count(ArchivedEvent, schema_name) == 0

      assert {:noreply, new_state} = Poller.handle_info(:tick, %{last_retention_run_at: nil})
      assert %DateTime{} = new_state.last_retention_run_at

      assert table_count(Event, schema_name) == 1
      assert table_count(ArchivedEvent, schema_name) == 1

      assert [remaining] = Repo.all(Event, prefix: schema_name)
      assert remaining.instance_id == recent_instance_id
    end

    test "retention_due?/1 gates a second tick from re-sweeping before its own interval elapses" do
      put_scheduler_config(
        retention_enabled: true,
        retention_interval_ms: 86_400_000,
        retention_days: 30
      )

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      seed_instance_sequence!(schema_name, instance_id)

      old_created_at =
        DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:microsecond)

      seed_event!(schema_name, instance_id, old_created_at)

      assert {:noreply, state_after_first} =
               Poller.handle_info(:tick, %{last_retention_run_at: nil})

      assert %DateTime{} = first_run_at = state_after_first.last_retention_run_at
      assert table_count(Event, schema_name) == 0
      assert table_count(ArchivedEvent, schema_name) == 1

      # A second event, old enough that it WOULD be archived if the guard
      # re-swept -- retention_interval_ms: 86_400_000 (24h) has not elapsed
      # since first_run_at, so this second tick must be a no-op.
      seed_event!(schema_name, instance_id, old_created_at, 2)
      assert table_count(Event, schema_name) == 1

      assert {:noreply, state_after_second} = Poller.handle_info(:tick, state_after_first)

      assert DateTime.compare(state_after_second.last_retention_run_at, first_run_at) == :eq
      assert table_count(Event, schema_name) == 1
      assert table_count(ArchivedEvent, schema_name) == 1
    end
  end

  # ===================================================================================
  # ISS-0429 -- a dispatched alert-hook delivery mid-backoff must not block the
  # Poller's own subsequent :tick. See
  # lib/letflow/design/iss0429-async-alert-hook-delivery.md §6 for the full test
  # rationale this describe block implements.
  # ===================================================================================

  defp put_alert_config(overrides) do
    original = Application.get_env(:letflow, :alert_hooks)
    Application.put_env(:letflow, :alert_hooks, overrides)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:letflow, :alert_hooks)
        val -> Application.put_env(:letflow, :alert_hooks, val)
      end
    end)
  end

  describe "ISS-0429: a dispatched hook delivery mid-backoff does not block a subsequent :tick" do
    test "the Poller's own last_tick_started_at advances more than once while the only " <>
           "configured hook is still retrying its (slow) backoff schedule" do
      # Always-500 server -- deliver_with_retry/4 enters its Process.sleep(backoff_delay/2)
      # branch on every attempt. base_backoff_ms/max_backoff_ms are both 2_000ms (test-local
      # RetryPolicy override, not the production default) so the mid-backoff window is
      # comfortably wide -- long enough to straddle several real ticks at the overridden
      # poll_interval_ms below, but short enough this test still finishes in well under a
      # second either way (pass or fail-first).
      server = WebhookTestServer.start(500, "internal error")

      put_alert_config(
        enabled: true,
        thresholds: [dlq_depth_threshold: 5],
        hooks: [
          [
            hook_id: "iss0429-poller-block-hook",
            enabled: true,
            destination_url: server.url,
            timeout_ms: 1_000,
            auth_secret_ref: nil,
            retry_policy: [
              max_attempts: 5,
              base_backoff_ms: 2_000,
              max_backoff_ms: 2_000,
              multiplier: 2.0
            ]
          ]
        ]
      )

      # Short poll interval so several real ticks fall well inside the hook's
      # still-in-progress 2_000ms backoff window from the first tick's dispatch.
      put_scheduler_config(poll_interval_ms: 40, jitter_ms: 0, max_timers_per_cycle: 64)

      %{schema_name: schema_name} = provisioned_tenant("iss0429-poller-block")

      # Push dlq_count over the threshold=5 BEFORE the Poller starts, so its very
      # first (zero-delay) tick's alert detection pass fires the hook immediately.
      for _ <- 1..6 do
        assert {:ok, _entry} =
                 Dlq.enqueue(%{entry_type: "iss0429_poller_block_test"}, prefix: schema_name)
      end

      pid = start_supervised!(Poller)

      # Let the first tick (and its synchronous check_and_record_emission/4 commit +
      # fire-and-forget dispatch) run and settle.
      Process.sleep(30)

      timestamps =
        for _ <- 1..8 do
          Process.sleep(40)
          state = :sys.get_state(pid)
          state.last_tick_started_at
        end

      distinct_timestamps = Enum.uniq(timestamps)

      # Regression proof: at least two DIFFERENT last_tick_started_at values must have
      # been observed within this ~350ms sampling window, which is well inside the
      # hook's still-mid-backoff 2_000ms window from the first dispatch. Pre-fix, the
      # Poller's own handle_info(:tick, _) call ran deliver_with_retry/4 synchronously
      # and would still be blocked inside Process.sleep(2_000) at this point --
      # schedule_next_tick/0 is only ever reached AFTER that call returns, so
      # last_tick_started_at would never have advanced past its first value.
      assert length(distinct_timestamps) >= 2,
             "expected the Poller to process more than one :tick within #{8 * 40}ms while " <>
               "the dispatched hook was still mid-backoff (2_000ms); observed only " <>
               "#{length(distinct_timestamps)} distinct last_tick_started_at value(s) -- " <>
               "the Poller's own tick appears to be blocked on hook delivery"
    end
  end

  describe "no second ticker -- lib/letflow/scheduler/ has exactly one GenServer module" do
    test "lib/letflow/scheduler/ contains exactly one GenServer module (Poller) -- no second ticker" do
      root = File.cwd!()
      files = Path.wildcard(Path.join(root, "lib/letflow/scheduler/**/*.ex"))

      genserver_files =
        for path <- files,
            source = File.read!(path),
            source =~ ~r/use\s+GenServer/,
            do: path

      assert genserver_files == [Path.join(root, "lib/letflow/scheduler/poller.ex")]
    end
  end
end
