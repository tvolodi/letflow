defmodule Letflow.Engine.TimerWiringTest do
  @moduledoc """
  Tests for REQ-187's engine wiring of `:TIMER` nodes — arming on token
  arrival, firing via `Letflow.Scheduler`'s poll-and-fire path re-entering
  `Letflow.Engine`, and cancellation on instance completion/cancellation
  (SCH-01/SCH-03). See
  `handoffs/WF02-REQ187-20260829/step-03-test-designer.json`'s own
  acceptance-criteria list and `lib/letflow/design/req187-timer-engine-wiring.md`
  (the gate-approved design this file's tests verify against).

  Does NOT re-cover ground the 4 ELIXIR-DEV-updated test files already own:
  `test/letflow/engine/transition_test.exs`'s own `"transition/3 -- :TIMER
  entry/fired"` describe block already proves `dispatch_timer_arrival/3`'s
  pure `{:timer_armed, ...}` emission (not caught by the catch-all) and
  `dispatch_timer_fired/4`'s pure hop + defensive `:token_not_at_timer`
  error, so those pure-kernel cases are not repeated here.
  `test/letflow/engine/task_activation_test.exs`'s own `"cancel_pending_timers/5"`
  describe block already proves the function's `@doc` names SCH-03 and both
  call sites textually — explicitly deferring the real DB-level coverage of
  both call sites to `test/letflow/engine_test.exs` (its own moduledoc says
  so), which never actually landed that coverage; this file is that missing
  DB-level coverage. `test/letflow/scheduler_test.exs`/`scheduler/poller_test.exs`
  already cover the scheduler-side arm/claim/fire/retry machinery generically
  (including one already-armed-TIMER-node fixture) and REQ-186's own AC9
  route/controller structural scan — this file's own AC8 test below is a
  narrower, REQ-187-specific complement, not a duplicate.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database.
  `async: false`, matching every other tenant-fixture-using file in this
  codebase (real schema creation/teardown against one shared Postgres
  instance). `TIMER_FIRED`/`INSTANCE_STARTED`/`INSTANCE_CANCELLED` are all
  auto-seeded by `TenantFixture.provisioned_tenant!/1`'s own
  `replay_migrations/1` call (confirmed by `scheduler_test.exs`'s and
  `engine_cancel_instance_test.exs`'s own moduledocs — no manual event-type
  registration needed here).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.TaskActivation
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req187-timerwiring") do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-187 Timer Wiring Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp create_definition_attrs(graph) do
    %{
      name: unique_name("req187-def"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  defp active_definition!(schema_name, graph) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp base_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req187-start")
      },
      overrides
    )
  end

  defp cancel_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req187-cancel")
      },
      overrides
    )
  end

  # START -> TIMER(duration) -> END.
  defp graph_timer_end(duration) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "tmr", "node_type" => "TIMER", "attributes" => %{"duration_iso8601" => duration}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "tmr"},
        %{"id" => "e2", "source" => "tmr", "target" => "end"}
      ]
    }
  end

  # START -> TIMER(a) -> TIMER(b) -> END -- AC3's "edge leads directly into
  # another dispatch-needing node (:TIMER -> :TIMER)" case, resolved fully in
  # one advance_after_timer_fired/3 call once TIMER(a) fires.
  defp graph_timer_timer_end(duration_a, duration_b) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "tmr_a",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration_a}
        },
        %{
          "id" => "tmr_b",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration_b}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "tmr_a"},
        %{"id" => "e2", "source" => "tmr_a", "target" => "tmr_b"},
        %{"id" => "e3", "source" => "tmr_b", "target" => "end"}
      ]
    }
  end

  # START -> TIMER -> HUMAN_TASK -> END -- firing leaves a real live token
  # parked at a HUMAN_TASK (instance stays :active), used by the
  # reconstruction-parity test and the "fired timer untouched by a later
  # cancellation" test.
  defp graph_timer_human_task_end(duration) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "tmr", "node_type" => "TIMER", "attributes" => %{"duration_iso8601" => duration}},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "tmr"},
        %{"id" => "e2", "source" => "tmr", "target" => "task"},
        %{"id" => "e3", "source" => "task", "target" => "end"}
      ]
    }
  end

  # START -> PARALLEL_GATEWAY(split) -> TIMER(a) / TIMER(b) -> PARALLEL_GATEWAY(join) -> END.
  # Both TIMER branches structurally agree on the same join (walk_to_gateway/3
  # only needs each branch's own first edge target chain to reach it, not for
  # a token to actually traverse there) -- the split resolves entirely within
  # `create/2`'s own initial hop-chain, landing 2 separate live tokens on 2
  # distinct TIMER nodes in the SAME create/2 call, which is exactly
  # prepare_timer_arms/4's own >1-timer-armed guard scenario.
  defp graph_multi_timer_parallel do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "tmr_a",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "P1D"}
        },
        %{
          "id" => "tmr_b",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "P1D"}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "tmr_a"},
        %{"id" => "e3", "source" => "split", "target" => "tmr_b"},
        %{"id" => "e4", "source" => "tmr_a", "target" => "join"},
        %{"id" => "e5", "source" => "tmr_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "end"}
      ]
    }
  end

  defp timers_for(schema_name, instance_id) do
    Timer
    |> where([t], t.instance_id == ^instance_id)
    |> Repo.all(prefix: schema_name)
  end

  defp timer_count(schema_name) do
    Repo.aggregate(Timer, :count, prefix: schema_name)
  end

  defp fired_events_for(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "TIMER_FIRED")
    |> Repo.all(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC1/AC7 -- arming on arrival: exactly one pending timers row,
  # fire_at = arrival + parsed duration.
  # ---------------------------------------------------------------------------------

  describe "AC1: a token reaching a valid :TIMER node arms exactly one pending timers row" do
    test "a date-part duration (P1D) arms fire_at = arrival + 86400s" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P1D"))

      before_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      after_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert [timer] = timers_for(schema_name, result.instance_id)
      assert timer.status == "pending"
      assert timer.node_id == "tmr"
      assert timer.timer_type == "deadline"

      assert DateTime.compare(timer.fire_at, DateTime.add(before_create, 86_400, :second)) != :lt
      assert DateTime.compare(timer.fire_at, DateTime.add(after_create, 86_400, :second)) != :gt
    end

    test "a time-part duration (PT1H) arms fire_at = arrival + 3600s" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("PT1H"))

      before_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      after_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert [timer] = timers_for(schema_name, result.instance_id)
      assert timer.status == "pending"

      assert DateTime.compare(timer.fire_at, DateTime.add(before_create, 3_600, :second)) != :lt
      assert DateTime.compare(timer.fire_at, DateTime.add(after_create, 3_600, :second)) != :gt
    end

    test "the P0D edge case arms fire_at == arrival (zero-second offset)" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P0D"))

      before_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      after_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert [timer] = timers_for(schema_name, result.instance_id)
      assert timer.status == "pending"

      assert DateTime.compare(timer.fire_at, before_create) != :lt
      assert DateTime.compare(timer.fire_at, after_create) != :gt
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- the timer row and the state-transition event are written in ONE
  # transaction: forcing the event append to fail leaves NO timers row
  # behind. Reuses the exact "missing :actor_id fails EventStore.append/2's
  # own event-append step" forced-failure technique
  # `test/letflow/engine_test.exs`'s own REQ-047 AC2 test already established.
  # ---------------------------------------------------------------------------------

  describe "AC2: timer arm + state-transition event are in one transaction" do
    test "missing :actor_id fails the event append and leaves zero timers rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P1D"))

      attrs = base_attrs(definition) |> Map.delete(:actor_id)

      assert {:error, {:event_append_failed, :missing_actor_id}} =
               Engine.create(attrs, prefix: schema_name)

      assert timer_count(schema_name) == 0
      assert Repo.aggregate(InstanceProjection, :count, prefix: schema_name) == 0
      assert Repo.aggregate(TokenRecord, :count, prefix: schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- firing advances the token off the TIMER node along its outgoing
  # edge, including a chain into another dispatch-needing :TIMER node,
  # resolved fully in one advance_after_timer_fired/3 call.
  # ---------------------------------------------------------------------------------

  describe "AC3: firing a due timer via Scheduler.poll_and_fire/1 advances the token" do
    test "TIMER -> END: the instance completes and the token is no longer at the TIMER node" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P0D"))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"}] = timers_for(schema_name, instance_id)

      assert %{fired: 1} = Scheduler.poll_and_fire(schema_name)

      assert [%Timer{status: "fired"}] = timers_for(schema_name, instance_id)
      assert [event] = fired_events_for(schema_name, instance_id)
      assert event.payload["node_id"] == "tmr"

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :completed

      [token_record] = Repo.all(TokenRecord, prefix: schema_name)
      assert token_record.status == :completed
    end

    test "TIMER -> TIMER -> END: firing the first arms a NEW pending timer for the second, in the same call" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_timer_end("P0D", "PT1H"))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{node_id: "tmr_a", status: "pending"}] = timers_for(schema_name, instance_id)

      assert %{fired: 1} = Scheduler.poll_and_fire(schema_name)

      timers = timers_for(schema_name, instance_id) |> Enum.sort_by(& &1.node_id)
      assert [%Timer{node_id: "tmr_a", status: "fired"} = fired_a, %Timer{node_id: "tmr_b", status: "pending"} = pending_b] =
               timers

      # AC1's own fire_at = arrival + duration contract holds for the
      # second, re-armed timer too -- arrival here is fired_a's own
      # fired_at (advance_after_timer_fired/3's "now", design doc §8.4).
      assert DateTime.compare(pending_b.fire_at, DateTime.add(fired_a.fired_at, 3_600, :second)) !=
               :lt

      # Instance stays :active -- the live token is parked at tmr_b, not
      # completed, and NOT at tmr_a any more.
      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active

      [token_record] = Repo.all(TokenRecord, prefix: schema_name)
      assert token_record.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- completing an instance cancels every PENDING timer via the
  # unmoved cancel_pending_timers/5 call site (finalize_instance_projection/5's
  # :completed clause). Per the design doc's own §5.2 scope note, a
  # :TIMER-parked token structurally prevents create/2's own single hop-chain
  # from EVER reaching :completed while a sibling timer is still pending --
  # this call site is real, unmoved production code that is, by the design's
  # own admission, unreachable via ordinary flow. So this test exercises the
  # exact mechanism that call site depends on (cancel_pending_timers/5 with
  # its "instance_completed" reason, real DB, real prod function) directly,
  # plus a source-text check that the call site itself still invokes it,
  # unmoved, immediately after the instance_projections row flips to
  # :completed -- matching engine_cancel_instance_test.exs's own precedent
  # for a "force the state directly, this scenario isn't reachable via a
  # public Engine call" fixture (its AC2 third test).
  # ---------------------------------------------------------------------------------

  describe "AC4: completing an instance cancels its pending timers via cancel_pending_timers/5" do
    test "cancel_pending_timers/5 with reason instance_completed cancels a real pending timer" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P1D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"} = timer] = timers_for(schema_name, instance_id)

      completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, 1} =
               TaskActivation.cancel_pending_timers(
                 Repo,
                 instance_id,
                 completed_at,
                 "instance_completed",
                 schema_name
               )

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "cancelled"
      assert reloaded.cancelled_at == completed_at
      assert reloaded.cancel_reason == "instance_completed"
    end

    test "finalize_instance_projection/5's :completed clause still calls it, unmoved, right after the projection update" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/engine.ex"))

      # Isolate the :completed clause's own body (the 2nd defp
      # finalize_instance_projection/5 clause, up to the next defp) so this
      # check can't accidentally match some unrelated call elsewhere in the
      # file.
      [_before, clause_and_rest] =
        String.split(source, "defp finalize_instance_projection(\n         repo,", parts: 2)

      [clause_body, _rest] = String.split(clause_and_rest, "\n  defp unique_violation?", parts: 2)

      assert clause_body =~ ~r/repo\.update\(prefix: prefix\)/
      assert clause_body =~ "TaskActivation.cancel_pending_timers("
      assert clause_body =~ ~s("instance_completed")

      # Ordering: the update call textually precedes the cancellation call
      # (call site "unmoved" -- immediately after the projection flips).
      update_index = :binary.match(clause_body, "repo.update(prefix: prefix)") |> elem(0)
      cancel_index = :binary.match(clause_body, "TaskActivation.cancel_pending_timers(") |> elem(0)
      assert update_index < cancel_index
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- cancel_instance/3 cancels PENDING timers in the same transaction;
  # forcing that transaction to roll back leaves timers still pending.
  # ---------------------------------------------------------------------------------

  describe "AC5: cancel_instance/3 cancels pending timers in the same transaction" do
    test "an ordinary cancel_instance/3 call cancels the instance's pending timer with reason instance_cancelled" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P1D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"} = timer] = timers_for(schema_name, instance_id)

      assert {:ok, _cancelled} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "cancelled"
      assert reloaded.cancel_reason == "instance_cancelled"
      assert reloaded.cancelled_at != nil
    end

    test "forcing the :event step to fail (idempotency_key too long) rolls back :timer_cancellations too" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P1D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"} = timer] = timers_for(schema_name, instance_id)

      # EventStore.append/2's own fetch_idempotency_key/1 pre-transaction
      # check rejects a key over 255 chars with :idempotency_key_too_long --
      # cancel_instance/3's own pre-transaction phase (fetch_actor_and_idempotency_key/1)
      # only checks for nil/presence, not length, so this reaches
      # append_instance_cancelled_event/5's own EventStore.append/2 call
      # (the :event Multi step) and fails it there, inside the already-open
      # Multi -- exactly the same class of forced-:event-failure this
      # codebase's own REQ-047 AC2 test (engine_test.exs) established,
      # adapted for a validation cancel_instance/3's own pre-check doesn't
      # already catch.
      too_long_key = String.duplicate("x", 256)

      assert {:error, {:event_append_failed, :idempotency_key_too_long}} =
               Engine.cancel_instance(
                 instance_id,
                 cancel_attrs(%{idempotency_key: too_long_key}),
                 prefix: schema_name
               )

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "pending"
      assert reloaded.cancelled_at == nil
      assert reloaded.cancel_reason == nil

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
    end

    test "run_cancel_instance/5's own Multi places :timer_cancellations between :open_tasks and :instance_projection" do
      # Design doc §6.1-§6.2: this ordering is load-bearing lock-ordering
      # (avoids an AB-BA deadlock against Scheduler.fire_timer/2's own
      # timers-then-instance_projections lock order), not cosmetic grouping
      # -- a single-process test can't observe a deadlock directly, so this
      # is a structural/source-position check instead, mirroring this
      # file's own AC8 structural tests.
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/engine.ex"))

      [_before, body] =
        String.split(source, "defp run_cancel_instance(instance_id, actor_id", parts: 2)

      [multi_body, _rest] = String.split(body, "\n  # M1 --", parts: 2)

      open_tasks_index = :binary.match(multi_body, ":open_tasks") |> elem(0)
      timer_cancellations_index = :binary.match(multi_body, ":timer_cancellations") |> elem(0)
      instance_projection_index = :binary.match(multi_body, ":instance_projection,") |> elem(0)

      assert open_tasks_index < timer_cancellations_index
      assert timer_cancellations_index < instance_projection_index
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 (SCH-03) -- a 'fired' timer is never mutated by a later cancellation;
  # no 'pending' timer of a terminal instance is later fired.
  # ---------------------------------------------------------------------------------

  describe "AC6 (SCH-03): a fired timer is never touched by a later cancellation" do
    test "TIMER -> HUMAN_TASK -> END: firing the timer then cancelling the instance leaves the fired row untouched" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_human_task_end("P0D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert %{fired: 1} = Scheduler.poll_and_fire(schema_name)

      [fired_timer] = timers_for(schema_name, instance_id)
      assert fired_timer.status == "fired"

      assert {:ok, _cancelled} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      reloaded = Repo.get!(Timer, fired_timer.id, prefix: schema_name)
      assert reloaded.status == "fired"
      assert reloaded.cancelled_at == nil
      assert reloaded.cancel_reason == nil
    end
  end

  describe "AC6 (SCH-03): no pending timer of a terminal instance is ever fired by a later poll" do
    test "cancelling the instance first, then attempting to fire its (now-cancelled) timer directly, is a no-op" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_end("P0D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert [%Timer{status: "pending"} = timer] = timers_for(schema_name, instance_id)

      assert {:ok, _cancelled} =
               Engine.cancel_instance(instance_id, cancel_attrs(), prefix: schema_name)

      cancelled_timer = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert cancelled_timer.status == "cancelled"

      # A deterministic stand-in for the concurrency race (design doc §10):
      # by the time ANY poll could reach this timer_id, cancel_instance/3's
      # own transaction has already committed the "cancelled" status --
      # fire_timer/2's own status-guard (`status != "pending" -> :already_final`)
      # is what actually prevents it from ever firing.
      assert {:ok, :already_final} = Scheduler.fire_timer(timer.id, schema_name)

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "cancelled"
      assert fired_events_for(schema_name, instance_id) == []

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :cancelled
    end
  end

  # ---------------------------------------------------------------------------------
  # Multi-timer-in-one-hop-chain guard (REVIEWER's own new item) -- a
  # PARALLEL_GATEWAY split landing two branches on distinct TIMER nodes in
  # one hop-chain surfaces prepare_timer_arms/4's typed error, not a crash
  # (Ecto.Multi would otherwise raise on the duplicate :scheduler_timer step
  # name).
  # ---------------------------------------------------------------------------------

  describe "multi-timer-in-one-hop-chain guard" do
    test "a PARALLEL_GATEWAY split arming two TIMER nodes at once returns a typed error, never raises" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_multi_timer_parallel())

      result =
        try do
          Engine.create(base_attrs(definition), prefix: schema_name)
        rescue
          exception -> {:raised, exception}
        end

      assert {:error, {:multiple_timers_in_one_hop_chain_not_supported, node_ids}} = result
      assert Enum.sort(node_ids) == ["tmr_a", "tmr_b"]

      # Nothing committed -- the whole create/2 attempt aborted before any
      # Multi ever opened (prepare_timer_arms/4 runs in start_instance/5's
      # own pre-Multi `with` chain).
      assert timer_count(schema_name) == 0
      assert Repo.aggregate(InstanceProjection, :count, prefix: schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # transition.ex purity (AC7) -- re-exercises the module's own documented
  # grep command as a standing ExUnit check, since neither
  # transition_test.exs nor any other file in this tree currently wires it
  # into a runnable test (test/specs/REQ-044.md treats it as code-inspection
  # evidence only).
  # ---------------------------------------------------------------------------------

  describe "AC7: transition.ex (+ its 2 pure siblings) gain no Repo/clock call" do
    test "the moduledoc's own grep command returns zero matches" do
      paths =
        ~w(lib/letflow/engine/instance_state.ex lib/letflow/engine/token.ex lib/letflow/engine/transition.ex)

      pattern =
        ~r/Repo\.|Logger\.|DateTime\.|System\.os_time|System\.system_time|HTTPoison|Req\.|File\.|:rand\.|:crypto\./

      # Strips each file's own leading @moduledoc heredoc before scanning --
      # transition.ex's own moduledoc quotes this exact grep command
      # (including the literal string "Logger.") as documentation, which
      # would otherwise self-trigger this check on the doc text rather than
      # on real code.
      strip_moduledoc = fn source ->
        Regex.replace(~r/@moduledoc\s+""".*?"""/s, source, "", global: false)
      end

      offending =
        for path <- paths,
            source = File.read!(Path.join(File.cwd!(), path)) |> strip_moduledoc.(),
            String.match?(source, pattern),
            do: {path, Regex.run(pattern, source)}

      assert offending == [],
             "expected zero Repo/Logger/DateTime/clock/HTTP/File/rand/crypto references in " <>
               "the pure transition kernel, found: #{inspect(offending)}"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- no route/controller/migration/web/ file needed to add this
  # coverage. scheduler_test.exs's own AC9 already runs the broader
  # lib/letflow/api/**, lib/letflow/routers/**, web/src/** wildcard scan for
  # "Letflow.Scheduler"/"timers" references (REQ-186's own scope) -- this is
  # the narrower, REQ-187-specific complement: none of the 6 files this
  # requirement actually touched are themselves route/controller-shaped, and
  # no route file references this requirement's own new engine-level names.
  # ---------------------------------------------------------------------------------

  describe "AC8: no route/controller construct added or touched by REQ-187" do
    @req187_files ~w(
      lib/letflow/engine/transition.ex
      lib/letflow/definitions/graph.ex
      lib/letflow/engine.ex
      lib/letflow/engine/task_activation.ex
      lib/letflow/scheduler.ex
      lib/letflow/engine/reconstruction.ex
    )

    test "none of the 6 files REQ-187 touched are Plug.Router/controller-shaped" do
      for path <- @req187_files do
        source = File.read!(Path.join(File.cwd!(), path))
        refute source =~ ~r/use\s+Plug\.Router/, "#{path} unexpectedly uses Plug.Router"
        refute source =~ ~r/use\s+\w*Web,\s*:controller/, "#{path} unexpectedly is a controller"
        refute source =~ ~r/\bget\s+"\//, "#{path} unexpectedly defines a route"
      end
    end

    test "no file under lib/letflow/api/ or lib/letflow/routers/ references advance_after_timer_fired or TIMER_FIRED" do
      root = File.cwd!()

      candidate_paths =
        ["lib/letflow/api/**/*.ex", "lib/letflow/routers/**/*.ex"]
        |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))

      offending =
        for path <- candidate_paths,
            source = File.read!(path),
            source =~ ~r/advance_after_timer_fired|TIMER_FIRED|timer_armed|timer_fired/,
            do: path

      assert offending == [],
             "expected no route/controller file to reference REQ-187's new engine-level " <>
               "names, found: #{inspect(offending)}"
    end
  end

  # ---------------------------------------------------------------------------------
  # Reconstruction -- replaying a persisted TIMER_FIRED event reproduces the
  # same post-fire InstanceState the live advance_after_timer_fired/3 path
  # produces, independently (the two never call each other -- design doc §9).
  # ---------------------------------------------------------------------------------

  describe "Reconstruction.reconstruct_instance/2 replays TIMER_FIRED to the same post-fire state" do
    test "the live token's post-fire node_id/status matches a pure replay from the event log" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_timer_human_task_end("P0D"))
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      assert %{fired: 1} = Scheduler.poll_and_fire(schema_name)

      [live_token] = Repo.all(TokenRecord, prefix: schema_name)
      assert live_token.node_id == "task"
      assert live_token.status == :active

      assert {:ok, %{instance_state: replayed}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

      assert replayed.status == :active
      assert [replayed_token] = replayed.tokens
      assert replayed_token.node_id == "task"
    end
  end
end
