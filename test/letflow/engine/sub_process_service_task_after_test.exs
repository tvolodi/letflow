defmodule Letflow.Engine.SubProcessServiceTaskAfterTest do
  @moduledoc """
  ISS-0929 / Q-929 engine regression (E1-E6 of
  `lib/letflow/design/q929-vortex-8d-corrective-action-subprocess.md` section 8.2).

  When a child instance completes, `Letflow.Engine.SubProcess` advances the parent past the
  SUB_PROCESS node. Pre-fix it discarded the hop chain's pending events, so a SERVICE_TASK /
  TIMER / escalation HUMAN_TASK reached right after the SUB_PROCESS never got its
  `service_task_dispatches` / `timers` rows and the parent hung `:active` forever.

    * E1 -- SUB_PROCESS -> SERVICE_TASK -> END: exactly one pending dispatch row after the child
      completes; after the stubbed outcome the parent is COMPLETED.
    * E2 -- SUB_PROCESS -> TIMER: one pending timer row for the parent token.
    * E3 -- SUB_PROCESS -> HUMAN_TASK with escalation: the task AND one pending escalation timer.
    * E4 -- SUB_PROCESS -> HUMAN_TASK -> END unchanged.
    * E5 -- SERVICE_TASK after the SUB_PROCESS whose endpoint renders empty: the failure is routed
      to an ERROR (EXECUTION_ERROR event) instead of a crash or silent hang.
    * E6 -- the REAL Vortex fixtures end to end (critical severity -> 8D child -> close-deviation
      -> COMPLETED).

  No HTTP: the dispatcher is not run; the test performs the poller's re-entry (`mark advanced` +
  `advance_after_service_task_outcome/4`) itself, as `regulatory_review_timer_path_test.exs` does.
  Real Postgres, `async: false`. See `test/specs/ISS-0929.md`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  @parent_fixture Path.expand(
                    "../../fixtures/qa/vortex_supplier_quality_deviation_process_definition.json",
                    __DIR__
                  )
  @child_fixture Path.expand(
                   "../../fixtures/qa/vortex_8d_corrective_action_definition.json",
                   __DIR__
                 )

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ---------------------------------------------------------------------------------
  # Helpers (no optional-argument defaults -- anti-patterns.md ISS-0069)
  # ---------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp provision!, do: TenantFixture.provisioned_tenant!(slug_prefix: "iss0929").schema_name

  defp create_active!(schema, name, version, graph) do
    assert {:ok, definition} =
             Definitions.create(
               %{name: name, version: version, graph: graph, created_by: Ecto.UUID.generate()},
               prefix: schema
             )

    assert {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)
    active
  end

  defp start!(schema, definition, variables) do
    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: variables,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss0929-start")
               },
               prefix: schema
             )

    result.instance_id
  end

  defp child_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "child-task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "role-x"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "c0", "source" => "start", "target" => "child-task"},
        %{"id" => "c1", "source" => "child-task", "target" => "end"}
      ]
    }
  end

  # START -> SUB_PROCESS(child_name) -> <after_node> -> END
  defp parent_graph(child_name, after_node) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        after_node,
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "p0", "source" => "start", "target" => "sub"},
        %{"id" => "p1", "source" => "sub", "target" => after_node["id"]},
        %{"id" => "p2", "source" => after_node["id"], "target" => "end"}
      ]
    }
  end

  defp service_node(endpoint) do
    %{
      "id" => "after",
      "node_type" => "SERVICE_TASK",
      "attributes" => %{"endpoint" => endpoint, "method" => "POST", "timeout_ms" => 300_000}
    }
  end

  # Provision a tenant, activate child + parent, start the parent, return the child's pending
  # task and the ids. The child task is NOT yet completed.
  defp parent_with_child!(after_node) do
    schema = provision!()
    child_name = unique("iss0929-child")
    create_active!(schema, child_name, "1.0", child_graph())

    parent =
      create_active!(
        schema,
        unique("iss0929-parent"),
        "1.0",
        parent_graph(child_name, after_node)
      )

    parent_id = start!(schema, parent, %{"deviation_id" => "dev-1"})
    child_task = child_task!(schema, parent_id, "child-task")
    {schema, parent_id, child_task}
  end

  defp child_task!(schema, parent_instance_id, node_id) do
    child_ids =
      InstanceProjection
      |> where([p], p.parent_instance_id == ^parent_instance_id)
      |> select([p], p.instance_id)
      |> Repo.all(prefix: schema)

    assert [child_id] = child_ids
    pending_task!(schema, child_id, node_id)
  end

  defp pending_task!(schema, instance_id, node_id) do
    tasks =
      EngineTask
      |> where([t], t.instance_id == ^instance_id and t.node_id == ^node_id)
      |> Repo.all(prefix: schema)

    assert [task] = tasks
    task
  end

  defp complete!(schema, task, output) do
    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: output,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss0929-complete")
               },
               prefix: schema
             )
  end

  defp projection(schema, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema)

  defp dispatches(schema, instance_id) do
    ServiceTaskDispatch
    |> where([d], d.instance_id == ^instance_id)
    |> order_by([d], asc: d.created_at)
    |> Repo.all(prefix: schema)
  end

  defp timers(schema, instance_id) do
    Timer |> where([t], t.instance_id == ^instance_id) |> Repo.all(prefix: schema)
  end

  defp event_types(schema, instance_id) do
    assert {:ok, events} = Reconstruction.read_full_log(instance_id, schema, 1)
    Enum.map(events, & &1.event_type)
  end

  # Reproduce attempt_dispatch/2's precondition (status "advanced") -- no HTTP.
  defp mark_advanced!(schema, row) do
    row |> Ecto.Changeset.change(%{status: "advanced"}) |> Repo.update!(prefix: schema)
  end

  defp stub_advance!(schema, row) do
    assert {:ok, :advanced} =
             Engine.advance_after_service_task_outcome(
               mark_advanced!(schema, row).id,
               {:advance, %{}},
               Repo,
               schema
             )
  end

  # ---------------------------------------------------------------------------------
  # E1 -- the engine regression
  # ---------------------------------------------------------------------------------

  test "E1 SUB_PROCESS -> SERVICE_TASK: child completion creates exactly one pending dispatch; stub outcome completes parent" do
    {schema, parent_id, child_task} =
      parent_with_child!(service_node("https://example.test/close/{{variables.deviation_id}}"))

    complete!(schema, child_task, %{})

    proj = projection(schema, parent_id)
    assert proj.status == :active
    assert proj.current_nodes == ["after"]

    assert [row] = dispatches(schema, parent_id)
    assert row.node_id == "after"
    assert row.status == "pending"
    assert row.config_snapshot["rendered_url"] == "https://example.test/close/dev-1"

    stub_advance!(schema, row)

    assert projection(schema, parent_id).status == :completed
    assert Enum.all?(dispatches(schema, parent_id), &(&1.status != "pending"))

    types = event_types(schema, parent_id)
    assert "SUB_PROCESS_COMPLETED" in types
    refute "EXECUTION_ERROR" in types
  end

  # ---------------------------------------------------------------------------------
  # E2 / E3 -- timer halves of the fix
  # ---------------------------------------------------------------------------------

  test "E2 SUB_PROCESS -> TIMER: child completion arms exactly one pending timer for the parent token" do
    timer_node = %{
      "id" => "after",
      "node_type" => "TIMER",
      "attributes" => %{"duration_iso8601" => "PT1H"}
    }

    {schema, parent_id, child_task} = parent_with_child!(timer_node)
    complete!(schema, child_task, %{})

    assert projection(schema, parent_id).status == :active
    assert [%Timer{} = timer] = timers(schema, parent_id)
    assert timer.node_id == "after"
    assert timer.status == "pending"
    assert timer.token_id != nil
  end

  test "E3 SUB_PROCESS -> HUMAN_TASK with escalation: the task is created AND one pending escalation timer is armed" do
    human_node = %{
      "id" => "after",
      "node_type" => "HUMAN_TASK",
      "attributes" => %{
        "role" => "role-y",
        "escalation_timer_duration" => "PT2H",
        "escalation_role" => "role-z"
      }
    }

    {schema, parent_id, child_task} = parent_with_child!(human_node)
    complete!(schema, child_task, %{})

    assert projection(schema, parent_id).current_nodes == ["after"]
    assert %EngineTask{status: :pending} = pending_task!(schema, parent_id, "after")

    assert [%Timer{} = timer] = timers(schema, parent_id)
    assert timer.timer_type == "escalation"
    assert timer.node_id == "after"
    assert timer.status == "pending"
  end

  # ---------------------------------------------------------------------------------
  # E4 -- unchanged path
  # ---------------------------------------------------------------------------------

  test "E4 SUB_PROCESS -> plain HUMAN_TASK -> END still works: task pending, no dispatch, no timer" do
    human_node = %{
      "id" => "after",
      "node_type" => "HUMAN_TASK",
      "attributes" => %{"role" => "role-y"}
    }

    {schema, parent_id, child_task} = parent_with_child!(human_node)
    complete!(schema, child_task, %{})

    assert projection(schema, parent_id).status == :active
    after_task = pending_task!(schema, parent_id, "after")
    assert after_task.status == :pending
    assert dispatches(schema, parent_id) == []
    assert timers(schema, parent_id) == []

    complete!(schema, after_task, %{})
    assert projection(schema, parent_id).status == :completed
  end

  # ---------------------------------------------------------------------------------
  # E5 -- error channel
  # ---------------------------------------------------------------------------------

  test "E5 SERVICE_TASK after SUB_PROCESS with an empty rendered endpoint is routed to an ERROR, not a hang or crash" do
    {schema, parent_id, child_task} = parent_with_child!(service_node("{{variables.missing}}"))

    # Whatever the exact return shape of the failed completion, the observable contract is:
    # no pending dispatch row, parent flipped to :error, EXECUTION_ERROR recorded.
    _ =
      Engine.complete_task(
        child_task.id,
        %{
          output_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("iss0929-complete")
        },
        prefix: schema
      )

    assert Enum.all?(dispatches(schema, parent_id), &(&1.status != "pending"))
    assert projection(schema, parent_id).status == :error
    assert "EXECUTION_ERROR" in event_types(schema, parent_id)
  end

  # ---------------------------------------------------------------------------------
  # E6 -- the real Vortex fixtures end to end
  # ---------------------------------------------------------------------------------

  test "E6 real Vortex fixtures: critical deviation -> 8D child -> close-deviation dispatch -> COMPLETED" do
    schema = provision!()
    parent_doc = @parent_fixture |> File.read!() |> Jason.decode!()
    child_doc = @child_fixture |> File.read!() |> Jason.decode!()

    create_active!(schema, child_doc["name"], child_doc["version"], child_doc["graph"])

    parent =
      create_active!(schema, parent_doc["name"], parent_doc["version"], parent_doc["graph"])

    parent_id = start!(schema, parent, %{"batch_ref" => "b-1", "deviation_id" => "dev-9"})

    # quarantine-batch dispatch, stub-advanced.
    assert [quarantine] = dispatches(schema, parent_id)
    assert quarantine.node_id == "quarantine-batch"
    stub_advance!(schema, quarantine)

    complete!(
      schema,
      pending_task!(schema, parent_id, "severity-classification"),
      %{"severity" => "critical", "false_positive" => false}
    )

    # Parent parked at the sub-process; the 8D child task belongs to the child instance.
    proj = projection(schema, parent_id)
    assert proj.status == :active
    assert proj.current_nodes == ["corrective-action-subprocess"]

    child_task = child_task!(schema, parent_id, "corrective-action-8d")
    assert child_task.status == :pending
    complete!(schema, child_task, %{})

    # The ISS-0929 fix: close-deviation dispatch exists (pre-fix: parent hung with none).
    assert projection(schema, parent_id).current_nodes == ["close-deviation"]
    pending = Enum.filter(dispatches(schema, parent_id), &(&1.status == "pending"))
    assert [close] = pending
    assert close.node_id == "close-deviation"

    assert close.config_snapshot["rendered_url"] ==
             "https://httpbin.org/anything/quality/deviations/dev-9/close"

    stub_advance!(schema, close)

    assert projection(schema, parent_id).status == :completed
    types = event_types(schema, parent_id)
    assert "SUB_PROCESS_COMPLETED" in types
    refute "EXECUTION_ERROR" in types
  end
end
