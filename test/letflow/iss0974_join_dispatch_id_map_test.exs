defmodule Letflow.ISS0974JoinDispatchIdMapTest do
  @moduledoc """
  Regression coverage for ISS-0974 -- a `PARALLEL_GATEWAY` join firing within
  the same hop chain and leading directly into a `:SERVICE_TASK` (or a
  `:TIMER`-start node) minted a dispatch/timer row with the join's own
  synthetic, non-UUID `token_id` (`Transition.fire_join/5`'s
  `"<origin>/<join_node>/joined"` string), instead of the real, persisted
  `TokenRecord` id. See `docs/issues/ISS-0974.yaml` and the gate-approved
  design, `lib/letflow/design/iss0974-join-dispatch-id-map-fix.md`.

  Root cause (confirmed by direct reading, design doc §0/§2): unlike
  `build_task_activation_and_reconciliation_multi/4` (ISS-0408's fix, which
  already threads the real `id_map` `insert_hop_chain_new_token_records/5`
  produces into the task-activation/reconciliation Multi steps), the two
  SIBLING `Multi.merge/2` blocks immediately after it -- one for
  `prepared_timers`/`build_timer_arms_multi/4`, one for
  `prepared_service_task_dispatches`/`build_service_task_dispatch_multi/5` --
  each independently built their own id_map as a pure IDENTITY map
  (`Map.new(prepared, fn t -> {t, t} end)`), on the stale assumption that
  every token_id reaching them is already a real, persisted `TokenRecord`
  id. That assumption breaks exactly when a `PARALLEL_GATEWAY` join fires
  same-hop-chain and its own outgoing edge leads directly to a
  `:SERVICE_TASK` or `:TIMER` node -- the join-merged token's id is still
  the synthetic string at that point, and `Ecto.UUID.cast/1` (via
  `ServiceTaskDispatch.arm_changeset/2` / `Letflow.Scheduler.Timer`'s own
  changeset) rejects it.

  THE FIX (`lib/letflow/engine.ex`, 4 call sites, 8 `Multi.merge/2`
  callbacks total): each sibling merge now reads the real id_map back out
  of the transaction's accumulated `changes` (already computed earlier in
  the same pipe by `insert_hop_chain_new_token_records/5`, keyed
  `{:hop_chain_token_records, <instance_id>}`) and falls back to identity
  only for token_ids that map doesn't cover (design doc §2.1's sparse-map
  argument) -- `build_timer_arms_multi/4` and
  `build_service_task_dispatch_multi/5` themselves are unchanged, they were
  always handed a wrong `id_map`.

  This file covers site 1 only
  (`build_complete_task_tail_multi/6`, reached via `complete_task/3` --
  the design doc's own §2.2 confirms all 4 sites share the identical
  expression-level fix, so this is not 4x redundant coverage, just the one
  call site a real `complete_task/3` hop chain can reach without also
  needing a TIMER-fired/escalation-timer-fired/SERVICE_TASK-outcome
  re-entry scaffold).

  Fail-then-pass proof (WF-02 Step 2a): both describe blocks below were run
  against the pre-fix commit (`git stash` of this branch's own
  `lib/letflow/engine.ex` changes, confirmed identical to `origin/main` at
  the branch point) and failed with a real `Ecto.Changeset` cast error on
  `:token_id` (`{"is invalid", [type: Ecto.UUID, validation: :cast]}`);
  then run again with the fix restored and confirmed to pass. See this
  run's own final report for the verbatim command output.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked
  database. `async: false`, matching every other tenant-fixture-using file
  in this codebase. Self-contained: fixtures are duplicated here rather
  than shared with `test/letflow/iss0408_join_token_record_test.exs` (this
  file's own direct structural model) or
  `test/letflow/engine/service_task_wiring_test.exs`/`timer_wiring_test.exs`,
  per this codebase's established "each test file provisions its own
  fixtures" discipline.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture
  alias Letflow.WebhookTestServer

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "ISS-0974 Join Dispatch Id Map Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp enable_ssrf_bypass do
    Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
    on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)
  end

  # START -> PARALLEL_GATEWAY(split) -> HUMAN_TASK(a) / HUMAN_TASK(b) ->
  # PARALLEL_GATEWAY(join) -> SERVICE_TASK(svc) -> END.
  # Distinguishing feature vs. iss0408_join_token_record_test.exs's own
  # `graph_join_then_human_task/0`: the join's own outgoing edge leads
  # directly to a dispatch-needing :SERVICE_TASK node, not another
  # :HUMAN_TASK (which already goes through the already-fixed
  # task-activation/reconciliation path, not build_service_task_dispatch_multi/5).
  defp graph_join_then_service_task(endpoint) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "task_a",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_a"}
        },
        %{
          "id" => "task_b",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_b"}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => endpoint, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "task_a"},
        %{"id" => "e3", "source" => "split", "target" => "task_b"},
        %{"id" => "e4", "source" => "task_a", "target" => "join"},
        %{"id" => "e5", "source" => "task_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "svc"},
        %{"id" => "e7", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # Same split/join shape, but the join's outgoing edge leads directly to a
  # :TIMER node instead -- the structurally-identical generalized-bug-class
  # case the design doc (and ISS-0974's own acceptance criteria) calls out
  # explicitly: build_timer_arms_multi/4 has the exact same
  # Map.fetch!(id_map, token_id) shape as build_service_task_dispatch_multi/5.
  defp graph_join_then_timer(duration) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "task_a",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_a"}
        },
        %{
          "id" => "task_b",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_b"}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "task_a"},
        %{"id" => "e3", "source" => "split", "target" => "task_b"},
        %{"id" => "e4", "source" => "task_a", "target" => "join"},
        %{"id" => "e5", "source" => "task_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "tmr"},
        %{"id" => "e7", "source" => "tmr", "target" => "end"}
      ]
    }
  end

  defp create_definition_attrs(graph) do
    %{
      name: unique_name("iss0974-def"),
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

  defp start_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("iss0974-start")
      },
      overrides
    )
  end

  defp complete_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("iss0974-complete")
      },
      overrides
    )
  end

  defp task_by_node_id(schema_name, node_id) do
    schema_name
    |> tasks_for()
    |> Enum.find(&(&1.node_id == node_id))
  end

  defp tasks_for(schema_name) do
    Repo.all(EngineTask, prefix: schema_name)
  end

  defp dispatches_for(schema_name, instance_id) do
    ServiceTaskDispatch
    |> where([d], d.instance_id == ^instance_id)
    |> Repo.all(prefix: schema_name)
  end

  defp timers_for(schema_name, instance_id) do
    Timer
    |> where([t], t.instance_id == ^instance_id)
    |> Repo.all(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # Case 1 -- join -> SERVICE_TASK (build_service_task_dispatch_multi/5 sibling)
  # ---------------------------------------------------------------------------------

  describe "join -> SERVICE_TASK via complete_task/3 (same hop chain)" do
    test "the second complete_task/3 call fires the join and creates a real service_task_dispatches row, not a 422/cast error" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant("iss0974-svc")
      definition = active_definition!(schema_name, graph_join_then_service_task(server_url))

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_id = created.instance_id
      assert Enum.sort(created.current_nodes) == ["task_a", "task_b"]

      task_a = task_by_node_id(schema_name, "task_a")
      task_b = task_by_node_id(schema_name, "task_b")

      # First branch: join does not fire yet -- succeeded pre-fix and
      # post-fix alike.
      assert {:ok, after_a} =
               Engine.complete_task(task_a.id, complete_attrs(), prefix: schema_name)

      assert after_a.instance_status == :active

      # Second branch: fires the join, whose own outgoing edge leads
      # directly to the SERVICE_TASK node "svc" -- the exact ISS-0974
      # scenario. Pre-fix: {:error, %Ecto.Changeset{}} with a :token_id
      # cast error (Ecto.UUID rejecting the join's synthetic string id).
      # Post-fix: succeeds, a real dispatch row is created.
      result = Engine.complete_task(task_b.id, complete_attrs(), prefix: schema_name)

      assert {:ok, after_b} = result
      assert after_b.instance_status == :active
      assert after_b.current_nodes == ["svc"]

      # Exactly one new service_task_dispatches row exists for "svc", whose
      # token_id is a real UUID backed by a real, persisted TokenRecord row
      # (not the join's own synthetic "<origin>/join/joined" string).
      assert [dispatch] = dispatches_for(schema_name, instance_id)
      assert dispatch.node_id == "svc"
      assert dispatch.status == "pending"
      assert {:ok, _} = Ecto.UUID.cast(dispatch.token_id)

      token_records = Repo.all(TokenRecord, prefix: schema_name)
      assert [joined_record] = Enum.filter(token_records, &(&1.node_id == "svc"))
      assert joined_record.id == dispatch.token_id
      assert joined_record.branch_id == nil
      assert joined_record.status == :active

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # Case 2 -- join -> TIMER (build_timer_arms_multi/4 sibling) -- the
  # generalized bug class ISS-0974's own acceptance criteria name explicitly.
  # ---------------------------------------------------------------------------------

  describe "join -> TIMER via complete_task/3 (same hop chain)" do
    test "the second complete_task/3 call fires the join and arms a real timers row, not a 422/cast error" do
      %{schema_name: schema_name} = provisioned_tenant("iss0974-tmr")
      definition = active_definition!(schema_name, graph_join_then_timer("P1D"))

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_id = created.instance_id
      assert Enum.sort(created.current_nodes) == ["task_a", "task_b"]

      task_a = task_by_node_id(schema_name, "task_a")
      task_b = task_by_node_id(schema_name, "task_b")

      assert {:ok, after_a} =
               Engine.complete_task(task_a.id, complete_attrs(), prefix: schema_name)

      assert after_a.instance_status == :active

      # Fires the join, whose own outgoing edge leads directly to the
      # :TIMER node "tmr". Pre-fix: the same {:error, %Ecto.Changeset{}}
      # :token_id cast-error class as case 1, surfaced instead from
      # Letflow.Scheduler.Timer's own changeset (build_timer_arms_multi/4).
      # Post-fix: succeeds, a real timers row is armed.
      result = Engine.complete_task(task_b.id, complete_attrs(), prefix: schema_name)

      assert {:ok, after_b} = result
      assert after_b.instance_status == :active
      assert after_b.current_nodes == ["tmr"]

      assert [timer] = timers_for(schema_name, instance_id)
      assert timer.node_id == "tmr"
      assert {:ok, _} = Ecto.UUID.cast(timer.token_id)

      token_records = Repo.all(TokenRecord, prefix: schema_name)
      assert [joined_record] = Enum.filter(token_records, &(&1.node_id == "tmr"))
      assert joined_record.id == timer.token_id
      assert joined_record.branch_id == nil
      assert joined_record.status == :active

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
    end
  end
end
