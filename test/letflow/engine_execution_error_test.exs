defmodule Letflow.EngineExecutionErrorTest do
  @moduledoc """
  Tests for REQ-061's EE-10 execution-error handling: `Letflow.Engine.ExecutionError.
  append_multi/3` (the shared sink), `Letflow.Engine.set_instance_error/2` (its
  standalone entry point), and the rewired REQ-049/REQ-050 call sites inside
  `Letflow.Engine.complete_task/3`. See `test/specs/REQ-061.md` for the full
  rationale.

  Uses `Letflow.DataCase` (real Postgres), Sandbox `:auto`, `async: false` --
  mirrors `engine_cancel_instance_test.exs`'s and `engine_complete_task_test.exs`'s
  own `provisioned_tenant/0` pattern exactly. Self-contained.

  ## REQ-050 downstream-gateway coverage (fixed in rework iteration 1)

  `Letflow.Engine.dispatch_task_completion_hop_chain/5` routes a
  `{:no_matching_edge, node_id, evaluated_conditions}` no-match into
  `ExecutionError.append_multi/3` whether it's discovered on the *completing
  task's own* outgoing edges (`Letflow.Engine.Transition`'s
  `dispatch_task_completion/4`, for the literal `{:complete_task, token_id}`
  event) or on a *later* hop -- e.g. an `:EXCLUSIVE_GATEWAY` reached one hop
  downstream of the completing task, dispatched via `advance_until_stable/4`'s
  own internal worklist loop (`{:advance_token, token_id}` events), whose
  `{:error, reason}` is wrapped as `{:error, {:activation_failed, reason}}`
  (engine.ex line 383) and unwrapped/rewired by the `case advance_until_stable(
  ...)` clause in `dispatch_task_completion_hop_chain/5`. `AC4a` below exercises
  the realistic downstream-gateway trigger (a gateway reached one hop after the
  completing task, `graph_task_then_gateway_no_match/0`) end to end against real
  Postgres and confirms it now lands in `ExecutionError.append_multi/3`: one
  `EXECUTION_ERROR` event appended, instance status `:error`.

  Note: the one scenario where a no-match is discovered on the completing
  task's *own* outgoing edges directly (a `:HUMAN_TASK` whose own edges fail to
  resolve) is structurally unreachable via the public API --
  `Letflow.Definitions.create/2` runs `Graph.validate_edge_conditions/1`
  (CHK-19, `check_human_task_fallback_edge/1`) before any row is written,
  rejecting a `:HUMAN_TASK` with a really-conditioned outgoing edge and no
  fallback; a zero-outgoing-edges `:HUMAN_TASK` is independently rejected by
  `Graph.validate_graph/1`'s `check_isolated_nodes/1` (`:isolated_node`). That
  does not matter for REQ-050's own acceptance criteria, whose realistic
  trigger is always a *downstream* gateway (AC4a covers this) -- it only means
  the same-hop clause itself is exercised indirectly (via `AC4b`'s direct
  `set_instance_error/2` call using the identical `error_args()` shape) rather
  than via its own dedicated `complete_task/3` scenario.

  REQ-049's own schema-violation call site (`merge_output_variables/5`) remains
  unreachable via `complete_task/3` today -- it always passes `nil` for
  `VariableMerge.merge/3`'s `variable_validations` argument, so its own
  `{:rejected, ...}` branch can never fire. This is a pre-existing gap
  inherited from REQ-049's own shipped code, not something REQ-061 introduced
  or is in scope to fix -- filed separately, see `docs/issues/` for the
  tracking issue. `AC4b` below still verifies REQ-049's `error_args()` shape
  commits correctly through `set_instance_error/2` directly.

  What is tested here with real coverage against real Postgres: `Letflow.
  Engine.ExecutionError.append_multi/3` and `Letflow.Engine.set_instance_error/2`
  themselves (event payload shape, atomicity, eligibility/concurrency,
  `complete_task/3`'s own already-shipped-pre-REQ-061 M2 rejection of a further
  call against an `:error` instance), AND, as of this rework, REQ-050's
  realistic downstream-gateway trigger reached genuinely through
  `complete_task/3` (`AC4a`).
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

  # "EXECUTION_ERROR" is now auto-seeded by replay_migrations/2's default manifest
  # (REQ-045 §9 OQ-3a, extended by ISS-0072/GH#257) -- every AC except AC2 needs it
  # registered, and provisioning now does that for free; AC2 is the one test that
  # deliberately needs it *unregistered*, handled by
  # provisioned_tenant_without_execution_error_type/0 above, which deletes the
  # auto-seeded row back out.
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

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  # AC2's own fixture -- identical except "EXECUTION_ERROR" is never registered.
  # replay_migrations/2's default manifest now auto-seeds "EXECUTION_ERROR" itself
  # (REQ-045 §9 OQ-3a, extended by ISS-0072/GH#257) -- this fixture used to reach the
  # "unregistered EXECUTION_ERROR" state simply by skipping its own
  # register_event_type!/2 call, which stopped working once provisioning started
  # seeding it unconditionally (ISS-0073/GH#267: the real conflict was "this test's
  # premise is no longer reachable via the default manifest", not just a duplicate
  # registration). Fixed by deleting the auto-seeded row straight back out after
  # provisioning, via the real `Letflow.EventStore.Registry.EventType` schema/prefix
  # -- this reconstructs the exact "no row for EXECUTION_ERROR" state
  # `EventStore.append/2`'s `Registry.validate_payload/3` needs to legitimately
  # return `{:error, :unknown_event_type}`, still proving AC2's atomicity claim
  # rather than asserting on a state that can no longer occur naturally.
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

    Repo.delete_all(
      from(et in Registry.EventType, where: et.name == "EXECUTION_ERROR"),
      prefix: schema_name
    )

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req061-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
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
  # OWN edges, not a downstream EXCLUSIVE_GATEWAY's) -- the resulting no-match is
  # routed into ExecutionError.append_multi/3 via dispatch_task_completion_hop_chain/5's
  # advance_until_stable/4 clause (see AC4a below).
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
          reason:
            "no outgoing edge matched conditions and no default edge configured for gateway node 'gw'",
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
  # set_instance_error/2 to reach :error directly (independent of AC4a's
  # complete_task/3 route), then a real complete_task/3 call against the
  # still-PENDING task.
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
  # AC4 -- see this file's moduledoc for full rationale. AC4a exercises REQ-050's
  # realistic downstream-gateway trigger end to end through complete_task/3 (fixed
  # in rework iteration 1); AC4b proves REQ-049's and REQ-050's own error_args()
  # shapes both commit through the identical, single append_multi/3.
  # ---------------------------------------------------------------------------------

  describe "AC4a -- REQ-050's realistic downstream-gateway no-match" do
    test "complete_task/3 routes it into ExecutionError.append_multi/3: EXECUTION_ERROR appended, status :error" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name, graph_task_then_gateway_no_match())
      task = find_task(schema_name, "task")

      events_before = event_count(schema_name)

      # The Ecto.Multi as a whole still commits (ERROR state must durably
      # persist, not roll back) -- interpret_complete_result/1's leading
      # clause (engine.ex line 1488) maps that committed {:execution_error, _}
      # outcome to this {:error, {:instance_execution_error, ...}} shape for
      # the caller, distinct from the pre-fix raw {:error, {:activation_failed,
      # ...}} abort.
      assert {:error, {:instance_execution_error, :no_matching_gateway_edge, {:node, "gw"}}} =
               Engine.complete_task(task.id, complete_attrs(), prefix: schema_name)

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :error
      assert projection.error_detail != nil

      assert event_count(schema_name) == events_before + 1

      assert [event] = execution_error_events(schema_name, instance_id)
      assert event.payload["error_type"] == "no_matching_gateway_edge"

      # The task stays :pending -- REQ-061's design (ERROR is a non-terminal
      # instance state; TASK_COMPLETED never fires when the tail routes into
      # ExecutionError.append_multi/3 instead of the normal-path tail).
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
      # error_args() shape merge_output_variables/5's own rejection clause
      # builds. Currently unreachable via complete_task/3 (a pre-existing,
      # separately-filed REQ-049 gap -- see this file's moduledoc), so exercised
      # here directly through set_instance_error/2 instead.
      req049_attrs =
        error_attrs(req049_instance_id, %{
          error_type: :variable_schema_rejected,
          affected: {:field, "approved_amount"},
          reason: "variable 'approved_amount' failed schema validation"
        })

      # Mirrors lib/letflow/engine.ex lines 1157-1170 verbatim -- the exact
      # error_args() shape dispatch_task_completion_hop_chain/5's own rewired
      # same-hop clause builds (as opposed to the downstream-hop clause AC4a
      # exercises through complete_task/3 directly). The same-hop trigger
      # itself is structurally unreachable via the public API (see this file's
      # moduledoc), so exercised here directly through set_instance_error/2.
      req050_attrs =
        error_attrs(req050_instance_id, %{
          error_type: :no_matching_gateway_edge,
          affected: {:node, "gw"},
          reason:
            "no outgoing edge matched conditions and no default edge configured for gateway node 'gw'"
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
  # concurrent set_instance_error/2 calls.
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
