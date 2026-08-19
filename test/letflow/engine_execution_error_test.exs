defmodule Letflow.EngineExecutionErrorTest do
  @moduledoc """
  Tests for REQ-061's EE-10 execution-error handling: `Letflow.Engine.ExecutionError.
  append_multi/3` (the shared sink), `Letflow.Engine.set_instance_error/2` (its
  standalone entry point), and the rewired REQ-049/REQ-050 call sites inside
  `Letflow.Engine.complete_task/3`. See `test/specs/REQ-061.md` for the full
  rationale and the CONFIRMED GAP this file documents rather than papers over.

  Uses `Letflow.DataCase` (real Postgres), Sandbox `:auto`, `async: false` --
  mirrors `engine_cancel_instance_test.exs`'s and `engine_complete_task_test.exs`'s
  own `provisioned_tenant/0` pattern exactly. Self-contained.

  ## CONFIRMED GAP -- read before trusting any "REQ-050 via complete_task/3" claim

  Verified by direct code read AND by actually running the scenario against real
  Postgres (not asserted from the design doc's own text):

  1. `Letflow.Engine.dispatch_task_completion_hop_chain/5`'s own rewired
     `{:error, {:no_matching_edge, node_id, evaluated_conditions}}` clause
     (`lib/letflow/engine.ex` line ~1157) only intercepts a no-match on the
     *completing task's own* outgoing edges (`Letflow.Engine.Transition`'s
     `dispatch_task_completion/4`, called for the literal `{:complete_task,
     token_id}` event). It does **not** intercept a no-match discovered on a
     *later* hop -- e.g. an `:EXCLUSIVE_GATEWAY` reached one hop downstream of
     the completing task, which is dispatched via `advance_until_stable/4`'s own
     internal worklist loop (`{:advance_token, token_id}` events), a completely
     separate code path whose `{:error, reason}` is wrapped as `{:error,
     {:activation_failed, reason}}` (line 383) and returned **unrewired** --
     the whole transaction still aborts, exactly the pre-REQ-061 bug.
  2. The one scenario where the rewired clause fires directly (a `:HUMAN_TASK`
     whose own outgoing edges fail to resolve) is **structurally unreachable**
     via the public API: `Letflow.Definitions.create/2` runs `Graph.
     validate_edge_conditions/1` (CHK-19, `check_human_task_fallback_edge/1`)
     before any row is written, which rejects a `:HUMAN_TASK` with a
     really-conditioned outgoing edge and no fallback -- confirmed directly:
     `Letflow.Definitions.Graph.validate_edge_conditions(g)` on such a graph
     returns `%{valid: false, violations: [%{code: :human_task_no_fallback_edge,
     ...}]}`. A zero-outgoing-edges `:HUMAN_TASK` is independently rejected by
     `Graph.validate_graph/1`'s `check_isolated_nodes/1` (`:isolated_node`).

  **Net effect: REQ-050's no-matching-gateway-edge case, reached the way any
  real process definition would reach it (the gateway one or more hops after
  the completing task), is NOT actually routed into `ExecutionError.
  append_multi/3` by the shipped code -- `AC4a` below demonstrates this
  precisely, with the transaction still aborting and zero `ERROR` state
  persisted.** This is a confirmed defect in the shipped `complete_task/3`
  rewiring, not something this test file works around by picking an
  artificial trigger -- flagged in this run's handoff `issues` for
  ORCH/ISSUE-FIXER, since REVIEWER's AC4 sign-off ("2 of 2 currently-shippable
  callers wired") assumed both REQ-049's and REQ-050's call sites were
  reachable through `complete_task/3`, and REQ-049's is independently
  unreachable too (see `AC4b`'s test below).

  What DOES work, and is tested here with real coverage: `Letflow.Engine.
  ExecutionError.append_multi/3` and `Letflow.Engine.set_instance_error/2`
  themselves -- the shared sink's own mechanics (event payload shape,
  atomicity, eligibility/concurrency, and `complete_task/3`'s own
  already-shipped-pre-REQ-061 M2 rejection of a further call against an
  `:error` instance) are all genuinely reachable via the public API and
  verified below against real Postgres.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ExecutionError
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Registry
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: "req061-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-061 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp register_event_type!(name, tenant_id) do
    assert {:ok, _event_type} =
             Registry.register_type(
               %{
                 "name" => name,
                 "schema_version" => 1,
                 "json_schema" => %{"type" => "object"},
                 "description" => "REQ-061 test fixture -- permissive schema"
               },
               tenant_id
             )

    :ok
  end

  # Registers "EXECUTION_ERROR" -- every AC except AC2 needs it (AC2 is the one
  # test that deliberately omits it, to force EventStore.append/2's own
  # :unknown_event_type rejection and prove the atomicity claim).
  defp provisioned_tenant do
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

    :ok = register_event_type!("EXECUTION_ERROR", tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  # AC2's own fixture -- identical except "EXECUTION_ERROR" is never registered.
  defp provisioned_tenant_without_execution_error_type do
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

  defp unique_name(prefix \\ "req061-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix \\ "req061-idk") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp create_definition_attrs(graph) do
    %{name: unique_name(), version: "1.0.0", graph: graph, created_by: Ecto.UUID.generate()}
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
        idempotency_key: unique_idempotency_key("start")
      },
      overrides
    )
  end

  defp complete_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("complete")
      },
      overrides
    )
  end

  # error_attrs/2 -- Letflow.Engine.set_instance_error/2's own standalone_error_attrs()
  # shape (design doc §4).
  defp error_attrs(instance_id, overrides \\ %{}) do
    Map.merge(
      %{
        instance_id: instance_id,
        error_type: :variable_schema_rejected,
        affected: {:field, "approved_amount"},
        reason: "variable 'approved_amount' failed schema validation",
        variables: %{"approved_amount" => "not-a-number"},
        details: %{rejected_value: 999_999, failures: []},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("set-error")
      },
      overrides
    )
  end

  defp execution_error_events(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "EXECUTION_ERROR")
    |> Repo.all(prefix: schema_name)
  end

  defp event_count(schema_name) do
    %{rows: [[count]]} = Repo.query!(~s[SELECT COUNT(*) FROM "#{schema_name}"."events"], [])
    count
  end

  # START -> task(HUMAN_TASK) -> END. The instance's only open task.
  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # START -> task(HUMAN_TASK) -> gw(EXCLUSIVE_GATEWAY) -> [end_a | end_b], neither
  # edge's condition can ever be true (both reference an undefined variable,
  # treated as false per REQ-050 AC4), no default edge -- the REALISTIC shape
  # REQ-050's own requirement text describes (a gateway a completing task feeds
  # into). This graph IS valid/activatable (CHK-19 only constrains a HUMAN_TASK's
  # OWN edges, not a downstream EXCLUSIVE_GATEWAY's) -- see this file's moduledoc
  # for why the resulting no-match is nonetheless NOT routed into ExecutionError
  # today (AC4a, the confirmed gap).
  defp graph_task_then_gateway_no_match do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "end_a", "node_type" => "END"},
        %{"id" => "end_b", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "gw"},
        %{"id" => "e3", "source" => "gw", "target" => "end_a", "condition" => "variables.x == 1"},
        %{"id" => "e4", "source" => "gw", "target" => "end_b", "condition" => "variables.x == 2"}
      ]
    }
  end

  defp start_instance!(schema_name, graph) do
    definition = active_definition!(schema_name, graph)
    assert {:ok, result} = Engine.create(start_attrs(definition), prefix: schema_name)
    result.instance_id
  end

  defp find_task(schema_name, node_id) do
    EngineTask
    |> where([t], t.node_id == ^node_id)
    |> Repo.one!(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- EXECUTION_ERROR event payload carries all four AC1-mandated fields.
  # Exercised via the public set_instance_error/2 entry point -- genuinely
  # reachable, real Postgres, real ExecutionError.append_multi/3 underneath.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- set_instance_error/2 appends one EXECUTION_ERROR event" do
    test "the event payload carries error_type, affected, reason, and the variable snapshot" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_human_task_end())

      attrs =
        error_attrs(instance_id, %{
          error_type: :no_matching_gateway_edge,
          affected: {:node, "gw"},
          reason: "no outgoing edge matched conditions and no default edge configured for gateway node 'gw'",
          variables: %{"seed" => 1}
        })

      assert {:ok, result} = Engine.set_instance_error(attrs, prefix: schema_name)
      assert result.status == :error
      assert result.error_type == :no_matching_gateway_edge

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :error
      assert projection.error_detail["error_type"] == "no_matching_gateway_edge"
      assert projection.error_detail["affected"] == %{"kind" => "node", "node_id" => "gw"}

      assert [event] = execution_error_events(schema_name, instance_id)
      assert event.payload["error_type"] == "no_matching_gateway_edge"
      assert event.payload["affected"] == %{"kind" => "node", "node_id" => "gw"}
      assert event.payload["reason"] =~ "gw"
      assert event.payload["reason"] =~ "no outgoing edge matched"
      # variables: the instance variable-map snapshot at the moment of the error --
      # AC1's fourth mandatory field, read back verbatim.
      assert event.payload["variables"] == %{"seed" => 1}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- atomicity: status flip and EXECUTION_ERROR append commit together.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- forcing the EXECUTION_ERROR append to fail leaves status unchanged" do
    test "an unregistered EXECUTION_ERROR event type rolls back the whole transaction" do
      %{schema_name: schema_name} = provisioned_tenant_without_execution_error_type()
      instance_id = start_instance!(schema_name, graph_human_task_end())

      events_before = event_count(schema_name)

      assert {:error, {:event_append_failed, :unknown_event_type}} =
               Engine.set_instance_error(error_attrs(instance_id), prefix: schema_name)

      # Nothing committed -- status stays :active (unchanged), zero new events, both
      # read back independently, not inferred from the return value alone (INV-EE61-5).
      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
      assert projection.error_detail == nil

      assert event_count(schema_name) == events_before
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- an instance in ERROR rejects task completion with a distinct conflict.
  # Already-shipped REQ-048 M2 behavior (design doc §6) -- exercised here via
  # set_instance_error/2 to reach :error (independent of the broken complete_task/3
  # rewiring, AC4a), then a real complete_task/3 call against the still-PENDING task.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- complete_task/3 against an ERROR instance" do
    test "returns {:error, {:instance_not_active, :error}}, instance and task untouched" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_human_task_end())
      task = find_task(schema_name, "task")

      assert {:ok, _result} =
               Engine.set_instance_error(error_attrs(instance_id), prefix: schema_name)

      assert Repo.get!(InstanceProjection, instance_id, prefix: schema_name).status == :error

      # The distinct conflict AC3 asks for -- {:instance_not_active, :error} is a
      # different third element than {:instance_not_active, :completed}/:cancelled.
      assert {:error, {:instance_not_active, :error}} =
               Engine.complete_task(task.id, complete_attrs(), prefix: schema_name)

      # Remains in ERROR afterwards -- the rejected call wrote nothing.
      assert Repo.get!(InstanceProjection, instance_id, prefix: schema_name).status == :error

      untouched = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert untouched.status == :pending
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- see this file's moduledoc for the confirmed gap in full. AC4a documents
  # the actual (broken) shipped behavior for REQ-050's realistic trigger; AC4b
  # proves the one part of AC4 that does hold: REQ-049's and REQ-050's own
  # error_args() shapes both commit through the identical, single append_multi/3.
  # ---------------------------------------------------------------------------------

  describe "AC4a -- CONFIRMED GAP: REQ-050's realistic downstream-gateway no-match" do
    test "complete_task/3 still aborts unrewired, zero ERROR state persisted" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_task_then_gateway_no_match())
      task = find_task(schema_name, "task")

      events_before = event_count(schema_name)

      # NOT {:error, {:instance_execution_error, :no_matching_gateway_edge, _}} --
      # the pre-REQ-061 shape, confirming the rewiring did not intercept this call.
      assert {:error, {:activation_failed, {:no_matching_edge, "gw", _evaluated_conditions}}} =
               Engine.complete_task(task.id, complete_attrs(), prefix: schema_name)

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
      assert projection.error_detail == nil

      assert event_count(schema_name) == events_before

      untouched = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert untouched.status == :pending
    end
  end

  describe "AC4b -- REQ-049's and REQ-050's own error_args() shapes, same sink function" do
    test "set_instance_error/2 commits status:error identically for both error_type values" do
      %{schema_name: schema_name} = provisioned_tenant()
      req049_instance_id = start_instance!(schema_name, graph_human_task_end())
      req050_instance_id = start_instance!(schema_name, graph_human_task_end())

      # Mirrors lib/letflow/engine.ex lines 1093-1106 verbatim -- the exact
      # error_args() shape merge_output_variables/5's own (currently unreachable
      # via complete_task/3, see AC4a and this file's moduledoc) rejection clause
      # builds.
      req049_attrs =
        error_attrs(req049_instance_id, %{
          error_type: :variable_schema_rejected,
          affected: {:field, "approved_amount"},
          reason: "variable 'approved_amount' failed schema validation"
        })

      # Mirrors lib/letflow/engine.ex lines 1157-1170 verbatim -- the exact
      # error_args() shape dispatch_task_completion_hop_chain/5's own rewired
      # clause builds (reachable only via the direct same-hop trigger, itself
      # structurally unreachable -- see this file's moduledoc point 2).
      req050_attrs =
        error_attrs(req050_instance_id, %{
          error_type: :no_matching_gateway_edge,
          affected: {:node, "gw"},
          reason: "no outgoing edge matched conditions and no default edge configured for gateway node 'gw'"
        })

      assert {:ok, req049_result} = Engine.set_instance_error(req049_attrs, prefix: schema_name)
      assert {:ok, req050_result} = Engine.set_instance_error(req050_attrs, prefix: schema_name)

      assert req049_result.error_type == :variable_schema_rejected
      assert req050_result.error_type == :no_matching_gateway_edge

      assert Repo.get!(InstanceProjection, req049_instance_id, prefix: schema_name).status ==
               :error

      assert Repo.get!(InstanceProjection, req050_instance_id, prefix: schema_name).status ==
               :error

      assert [req049_event] = execution_error_events(schema_name, req049_instance_id)
      assert req049_event.payload["error_type"] == "variable_schema_rejected"

      assert [req050_event] = execution_error_events(schema_name, req050_instance_id)
      assert req050_event.payload["error_type"] == "no_matching_gateway_edge"

      # SAME function commits both -- ExecutionError.append_multi/3 is the one
      # function both call_sites' shapes route through (both calls above went
      # through Engine.set_instance_error/2, whose own body calls nothing else
      # to reach ERROR -- confirmed by direct read of lib/letflow/engine.ex,
      # design doc §4's `Multi.new() |> ExecutionError.append_multi(...)`).
      assert {:append_multi, 3} in ExecutionError.__info__(:functions)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- two concurrent EE-10 triggers on one instance, run truly concurrently.
  # The general row-lock-queueing mechanism (design doc §3), exercised via two
  # concurrent set_instance_error/2 calls -- genuinely reachable (unlike the
  # complete_task/3-specific race the design doc §5.5 also describes, which
  # inherits AC4a's gap and cannot itself be exercised end to end today).
  # ---------------------------------------------------------------------------------

  describe "AC5 -- two concurrent set_instance_error/2 calls target the same instance" do
    test "exactly one commits EXECUTION_ERROR, the other observes {:instance_already_error, _}" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_human_task_end())

      attrs_a =
        error_attrs(instance_id, %{
          error_type: :variable_schema_rejected,
          affected: {:field, "a"},
          reason: "race participant A"
        })

      attrs_b =
        error_attrs(instance_id, %{
          error_type: :no_matching_gateway_edge,
          affected: {:node, "gw"},
          reason: "race participant B"
        })

      # Real separate Postgres connections -- sandbox mode is :auto, so these two
      # processes genuinely race for the same instance_projections row lock
      # (mirrors engine_cancel_instance_test.exs's own AC4 race).
      task_a =
        Elixir.Task.async(fn -> {:a, Engine.set_instance_error(attrs_a, prefix: schema_name)} end)

      task_b =
        Elixir.Task.async(fn -> {:b, Engine.set_instance_error(attrs_b, prefix: schema_name)} end)

      results = Elixir.Task.await_many([task_a, task_b], 10_000)
      assert length(results) == 2

      winners = Enum.filter(results, &match?({_which, {:ok, _}}, &1))
      losers = Enum.filter(results, &match?({_which, {:error, {:instance_already_error, _}}}, &1))

      assert length(winners) == 1
      assert length(losers) == 1

      final_projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert final_projection.status == :error

      # Exactly one EXECUTION_ERROR event was ever appended -- the loser wrote
      # nothing (INV-EE61-3).
      assert [_one_event] = execution_error_events(schema_name, instance_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- moduledoc content: OBS-05/S6/S4 out of scope, no partial DLQ, ERROR
  # explicitly non-terminal unlike CANCELLED/COMPLETED. Pure, no DB.
  # ---------------------------------------------------------------------------------

  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  describe "AC6 -- moduledoc names OBS-05/S6/S4 as the out-of-scope operator action" do
    test "names the dead-letter hook, confirms no partial DLQ was built" do
      doc = normalized_moduledoc(ExecutionError)

      assert doc =~ "OBS-05"
      assert doc =~ "S6"
      assert doc =~ "S4"
      assert doc =~ "this module builds no partial version of either."
      assert doc =~ "No retry-queue table, no discard endpoint, no background sweep"
    end
  end

  describe "AC6 -- moduledoc states ERROR is non-terminal in a way CANCELLED/COMPLETED are not" do
    test "the exact contrast sentence is present" do
      doc = normalized_moduledoc(ExecutionError)

      assert doc =~ "`ERROR` is explicitly NOT terminal, unlike `CANCELLED` and `COMPLETED`"
    end
  end
end
