defmodule Letflow.Engine.HumanTaskEscalationTest do
  @moduledoc """
  REQ-396 AC3: ExUnit proves that firing an escalation timer via
  `Letflow.Scheduler.fire_timer/2` (which routes to
  `Letflow.Engine.advance_after_escalation_timer_fired/3`) produces:

    (a) the original HUMAN_TASK row's `status` becomes `:cancelled`
    (b) exactly one new PENDING task exists for the escalation role
    (c) the original task's `cancelled_at` is not after the new task's
        `inserted_at` (`:cancel_original_task` Multi step runs before
        `:task_activation`, so the cancel timestamp is earlier or the
        same wall-clock instant in the same transaction)

  ## Fixture graph

      START → orig-task (HUMAN_TASK, role: "approver",
                          escalation_timer_duration: "P0D",
                          escalation_role: "role-escalation")
              ─(no condition)→ escalated-task (HUMAN_TASK, role: "role-escalation")
      escalated-task ─(no condition)→ end

  `P0D` duration makes the escalation timer due immediately, matching
  the convention every other timer-wiring test uses for poll/direct-fire
  cases (see `test/letflow/engine/timer_wiring_test.exs`).

  Real Postgres, `async: false` — tenant provisioning needs the sandbox
  in `:auto` mode across multiple test helpers.

  ## Pre-fix failure note (non-existence case per WF-02 Step 3 procedure)

  `advance_after_escalation_timer_fired/3` did not exist before REQ-396.
  Mutant M1 applied for verification: removing the `:cancel_original_task`
  Multi step from `persist_escalation_timer_fired_advance/7` causes sub-AC
  (a) to fail (task stays `:pending` instead of `:cancelled`). Mutant
  reverted after measurement.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req396-escalation",
      display_name: "REQ-396 Escalation Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp active_definition!(schema_name, graph) do
    attrs = %{
      name: unique_name("req396-def"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Definitions.create(attrs, prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp create_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("req396-start")
      },
      overrides
    )
  end

  # Minimal escalation graph: orig-task parks on arrival (HUMAN_TASK), its
  # escalation timer fires immediately (P0D), follows the single unconditioned
  # edge to escalated-task (also a HUMAN_TASK, so it parks again with a new
  # PENDING task row for role-escalation).
  defp escalation_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "orig-task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{
            "role" => "approver",
            "escalation_timer_duration" => "P0D",
            "escalation_role" => "role-escalation"
          }
        },
        %{
          "id" => "escalated-task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "role-escalation"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "orig-task"},
        %{"id" => "e2", "source" => "orig-task", "target" => "escalated-task"},
        %{"id" => "e3", "source" => "escalated-task", "target" => "end"}
      ]
    }
  end

  # ---------------------------------------------------------------------------
  # AC3 -- timer fire -> (a) non-actionable original, (b) new task, (c) ordering
  # ---------------------------------------------------------------------------

  describe "REQ-396 AC3: escalation timer fire -> cancel original task + create new task" do
    test "(a) original HUMAN_TASK becomes :cancelled, (b) exactly one new task for escalation role, (c) cancelled_at not after new task's inserted_at" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, escalation_graph())

      assert {:ok, result} = Engine.create(create_attrs(definition), prefix: schema_name)
      instance_id = result.instance_id

      # After Engine.create: instance is :active, token at orig-task, one
      # escalation timer pending (type "escalation", P0D = due immediately).
      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
      assert "orig-task" in projection.current_nodes

      escalation_timers =
        Timer
        |> where([t], t.instance_id == ^instance_id and t.timer_type == "escalation")
        |> Repo.all(prefix: schema_name)

      assert [%Timer{status: "pending", node_id: "orig-task"} = escl_timer] = escalation_timers

      # One PENDING task row for orig-task / approver role.
      all_tasks_before = Repo.all(EngineTask, prefix: schema_name)
      assert [%EngineTask{node_id: "orig-task", status: :pending} = orig_task] = all_tasks_before

      # Force-fire the escalation timer directly (bypasses poll's fire_at check,
      # same pattern timer_wiring_test.exs uses for Scheduler.fire_timer/2 calls).
      assert {:ok, :fired} = Scheduler.fire_timer(escl_timer.id, schema_name)

      # (a) original task is :cancelled.
      reloaded_orig = Repo.get!(EngineTask, orig_task.id, prefix: schema_name)

      assert reloaded_orig.status == :cancelled,
             "expected orig-task to be :cancelled, got #{inspect(reloaded_orig.status)}"

      assert reloaded_orig.cancelled_at != nil

      # (b) exactly one new task exists for the escalation role.
      all_tasks_after = Repo.all(EngineTask, prefix: schema_name)
      new_tasks = Enum.filter(all_tasks_after, &(&1.id != orig_task.id))

      assert length(new_tasks) == 1,
             "expected exactly 1 new task after escalation, got #{length(new_tasks)}: #{inspect(Enum.map(new_tasks, &{&1.node_id, &1.status}))}"

      [new_task] = new_tasks
      assert new_task.node_id == "escalated-task"
      assert new_task.status == :pending
      assert new_task.assignee_ref == "role-escalation"

      # (c) audit ordering: the cancel timestamp is not after the new task's
      # inserted_at. Both come from the same Ecto.Multi execution; the
      # :cancel_original_task step runs before :task_activation, so
      # cancelled_at <= inserted_at is guaranteed by step ordering.
      assert DateTime.compare(reloaded_orig.cancelled_at, new_task.inserted_at) != :gt,
             "expected cancelled_at (#{reloaded_orig.cancelled_at}) <= new_task.inserted_at (#{new_task.inserted_at})"

      # Post-fire state: instance still :active (escalated-task is parked).
      projection_after = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection_after.status == :active
      assert "escalated-task" in projection_after.current_nodes
      refute "orig-task" in projection_after.current_nodes
    end
  end
end
