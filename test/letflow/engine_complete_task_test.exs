defmodule Letflow.EngineCompleteTaskTest do
  @moduledoc """
  Tests for REQ-048's `Letflow.Engine.complete_task/3` (EE-04 — task completion). See
  `test/specs/REQ-048.md` for the full test-case rationale, including why case 1 is
  regression coverage for the `really_conditioned?/1` fix documented in
  `lib/letflow/engine/transition.ex`'s `dispatch_task_completion/4` comment.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. Self-contained: does not
  share fixtures with `test/letflow/engine_test.exs` (REQ-045's `create/2` tests) even
  though several helpers below are structurally similar, matching
  `docs/guides/test_developer_guide.md` DIRECTIVE T-4's "no test pollution" / isolated
  fixtures expectation -- each test file provisions its own tenant schema.

  Mirrors `engine_test.exs`'s own `provisioned_tenant/0` + Sandbox `:auto` +
  `async: false` pattern exactly. `"TASK_COMPLETED"` no longer needs a fixture-local
  registration here: `TenantProvisioning.replay_migrations/2`'s default manifest now
  auto-seeds it (REQ-045 §9 OQ-3a, extended by ISS-0072/GH#257), so
  `EventStore.append/2`'s own `Registry.validate_payload/3` call (M9 of
  `Engine.complete_task/3`'s own `Ecto.Multi`) already has a registered type to
  validate against by the time `provisioned_tenant/0` returns. A prior version of this
  fixture self-registered a second, permissive `%{"type" => "object"}` copy of
  `"TASK_COMPLETED"`; that duplicate registration started colliding with
  provisioning's own seed once ISS-0072 landed (ISS-0073/GH#267) and was removed
  rather than reconciled, since production's own `Engine.complete_task/3` writer is
  exactly what provisioning's stricter schema was written to validate.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req048"),
        display_name: "REQ-048 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

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

    # TASK_COMPLETED is now auto-seeded by replay_migrations/2's default manifest
    # (REQ-045 §9 OQ-3a, extended by ISS-0072/GH#257) -- this fixture used to
    # self-register it again against a permissive `%{"type" => "object"}` schema
    # (ISS-0073/GH#267: that duplicate registration now collides with provisioning's
    # own seed and hard-fails). Removed rather than reconciled: every payload this
    # file writes is produced by the real Engine.complete_task/3 path
    # (lib/letflow/engine.ex M9), the exact writer provisioning's stricter schema was
    # written to validate, so relying on the real seed here isn't a coverage loss.
    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req048-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> task_a(HUMAN_TASK) -> task_b(HUMAN_TASK) -> END. Single, ordinary,
  # unconditioned edges throughout -- no `condition`, no `is_default` anywhere. This
  # is deliberately the plainest possible HUMAN_TASK->HUMAN_TASK shape (AC1's own
  # scenario, and the exact shape `really_conditioned?/1`'s fix makes work at all --
  # see this file's moduledoc and test/specs/REQ-048.md case 1).
  defp graph_two_human_tasks do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
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
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task_a"},
        %{"id" => "e2", "source" => "task_a", "target" => "task_b"},
        %{"id" => "e3", "source" => "task_b", "target" => "end"}
      ]
    }
  end

  # START -> task(HUMAN_TASK) -> END. Single ordinary unconditioned edge from
  # task -> end -- completing `task` should drive the instance straight to
  # :completed within the same call.
  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp create_definition_attrs(graph) do
    %{
      name: unique_name(),
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
        initial_variables: %{"seed" => "value"},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("start")
      },
      overrides
    )
  end

  # Starts an instance and returns {instance_id, pending_task}, where
  # pending_task is the single PENDING `tasks` row created at activation --
  # every test in this file needs exactly this shape as its starting point.
  defp start_instance_with_pending_task!(schema_name, graph) do
    definition = active_definition!(schema_name, graph)

    assert {:ok, result} = Engine.create(start_attrs(definition), prefix: schema_name)

    [task] = Repo.all(EngineTask, prefix: schema_name)
    assert task.status == :pending

    {result.instance_id, task}
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

  defp task_completed_events(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "TASK_COMPLETED")
    |> Repo.all(prefix: schema_name)
  end

  # ISS-0784 site 2 fixture -- START -> task_a(HUMAN_TASK, well-formed) ->
  # task_b(HUMAN_TASK, malformed form_schema) -> END. Completing task_a
  # drives activation of task_b, which rejects at
  # `TaskActivation.append_multi_from_existing_records/7` inside
  # `complete_task/3`'s own Multi (design §2 row 2) -- the whole point being
  # that `instance_id` for the rejection-audit call is read from
  # `changes.task.instance_id` (the already-fetched `:task` step, task_a's
  # own row), NOT from any argument complete_task/3 was called with
  # directly, which is the one genuinely different code path vs. site 1's
  # create/2 (where instance_id is create/2's own 2nd positional arg).
  defp graph_human_task_then_malformed_form_schema_task_end(form_schema) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task_a",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_a"}
        },
        %{
          "id" => "task_b",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_b", "form_schema" => form_schema}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task_a"},
        %{"id" => "e2", "source" => "task_a", "target" => "task_b"},
        %{"id" => "e3", "source" => "task_b", "target" => "end"}
      ]
    }
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- merges output_variables, flips task to COMPLETED, activates the next node,
  # appends exactly one TASK_COMPLETED event. Also the really_conditioned?/1 regression
  # case (see moduledoc and test/specs/REQ-048.md case 1).
  # ---------------------------------------------------------------------------------

  describe "AC1 -- completing a PENDING task at an ordinary unconditioned-edge HUMAN_TASK" do
    test "merges output_variables, completes the task, activates the next HUMAN_TASK, appends one event" do
      %{schema_name: schema_name} = provisioned_tenant()

      {instance_id, task_a} =
        start_instance_with_pending_task!(schema_name, graph_two_human_tasks())

      assert task_a.node_id == "task_a"

      attrs = complete_attrs(%{output_variables: %{"decision" => "approved"}})

      assert {:ok, result} = Engine.complete_task(task_a.id, attrs, prefix: schema_name)

      assert result.task_id == task_a.id
      assert result.instance_id == instance_id
      assert result.instance_status == :active
      assert result.current_nodes == ["task_b"]
      assert result.variables == %{"seed" => "value", "decision" => "approved"}
      assert %DateTime{} = result.completed_at

      completed_task = Repo.get!(EngineTask, task_a.id, prefix: schema_name)
      assert completed_task.status == :completed
      assert completed_task.completed_by == attrs.actor_id
      assert completed_task.completed_at != nil
      assert completed_task.output_variables == %{"decision" => "approved"}

      tasks = Repo.all(EngineTask, prefix: schema_name)
      assert length(tasks) == 2
      task_b = Enum.find(tasks, &(&1.node_id == "task_b"))
      assert task_b.status == :pending

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
      assert projection.current_nodes == ["task_b"]
      assert projection.variables == %{"seed" => "value", "decision" => "approved"}

      assert [%TokenRecord{node_id: "task_b", status: :active}] =
               Repo.all(TokenRecord, prefix: schema_name)

      assert [event] = task_completed_events(schema_name, instance_id)
      assert event.event_type == "TASK_COMPLETED"
      assert event.payload["task_id"] == task_a.id
      assert event.payload["node_id"] == "task_a"
      assert event.payload["output_variables"] == %{"decision" => "approved"}
    end
  end

  describe "AC1 -- completing the last PENDING task drives the instance to :completed" do
    test "instance_projections flips to :completed, the token row is reconciled to :completed, exactly one event" do
      %{schema_name: schema_name} = provisioned_tenant()

      {instance_id, task} = start_instance_with_pending_task!(schema_name, graph_human_task_end())

      attrs = complete_attrs()

      assert {:ok, result} = Engine.complete_task(task.id, attrs, prefix: schema_name)

      assert result.instance_status == :completed
      assert result.current_nodes == []

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :completed
      assert projection.current_nodes == []
      assert projection.completed_at != nil

      # reconcile_token_records/5 (engine.ex M10) marks a token whose final position
      # is "removed" (reached :END) as status: :completed on its existing row -- it
      # never deletes the row (that only happens for tokens never inserted in the
      # first place, create/2's own :END-on-first-hop case). No live (:active)
      # token remains.
      assert [%TokenRecord{status: :completed, node_id: "task"}] =
               Repo.all(TokenRecord, prefix: schema_name)

      assert [_one_event] = task_completed_events(schema_name, instance_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- output_variables: %{} succeeds; nil is a distinct, typed error.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- output_variables: %{} succeeds, distinct from missing/invalid" do
    test "an empty output_variables map completes the task normally" do
      %{schema_name: schema_name} = provisioned_tenant()

      {_instance_id, task} =
        start_instance_with_pending_task!(schema_name, graph_human_task_end())

      attrs = complete_attrs(%{output_variables: %{}})

      assert {:ok, result} = Engine.complete_task(task.id, attrs, prefix: schema_name)
      assert result.variables == %{"seed" => "value"}

      completed_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert completed_task.status == :completed
      assert completed_task.output_variables == %{}
    end
  end

  describe "AC2 -- output_variables: nil is rejected before any I/O, distinctly from %{}" do
    test "returns {:error, :invalid_output_variables} and leaves the task row untouched" do
      %{schema_name: schema_name} = provisioned_tenant()

      {_instance_id, task} =
        start_instance_with_pending_task!(schema_name, graph_human_task_end())

      attrs = complete_attrs(%{output_variables: nil})

      assert {:error, :invalid_output_variables} =
               Engine.complete_task(task.id, attrs, prefix: schema_name)

      untouched = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert untouched.status == :pending
      assert untouched.completed_at == nil
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- non-existent task_id vs. already-COMPLETED task return two distinct,
  # separately pattern-matchable errors.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- a non-existent task_id returns a distinct error from an already-COMPLETED task" do
    test "task_not_found for an unknown task_id" do
      %{schema_name: schema_name} = provisioned_tenant()

      unknown_task_id = Ecto.UUID.generate()

      assert {:error, :task_not_found} =
               Engine.complete_task(unknown_task_id, complete_attrs(), prefix: schema_name)
    end

    test "task_not_pending with the terminal status for an already-COMPLETED task, not task_not_found" do
      %{schema_name: schema_name} = provisioned_tenant()

      {_instance_id, task} =
        start_instance_with_pending_task!(schema_name, graph_human_task_end())

      assert {:ok, _result} = Engine.complete_task(task.id, complete_attrs(), prefix: schema_name)

      assert {:error, {:task_not_pending, :completed}} =
               Engine.complete_task(task.id, complete_attrs(), prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- two concurrent complete_task/3 calls on the same task_id: exactly one
  # success, one conflict.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- two concurrent complete_task/3 calls on the same task_id" do
    test "exactly one commits :completed, the other observes {:task_not_pending, :completed}" do
      %{schema_name: schema_name} = provisioned_tenant()
      {instance_id, task} = start_instance_with_pending_task!(schema_name, graph_human_task_end())

      # Real separate Postgres connections -- sandbox mode is :auto for this fixture
      # (provisioned_tenant/0 above), not the shared-connection :manual sandbox mode,
      # so these two processes genuinely race for the same FOR UPDATE row lock rather
      # than being serialized by the test's own sandbox ownership.
      task_1 =
        Task.async(fn ->
          Engine.complete_task(
            task.id,
            complete_attrs(%{idempotency_key: unique_idempotency_key("concurrent-1")}),
            prefix: schema_name
          )
        end)

      task_2 =
        Task.async(fn ->
          Engine.complete_task(
            task.id,
            complete_attrs(%{idempotency_key: unique_idempotency_key("concurrent-2")}),
            prefix: schema_name
          )
        end)

      results = Task.await_many([task_1, task_2], 10_000)

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      conflicts = Enum.filter(results, &match?({:error, {:task_not_pending, :completed}}, &1))

      assert length(successes) == 1
      assert length(conflicts) == 1
      assert length(results) == 2

      final_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert final_task.status == :completed

      assert [_one_event] = task_completed_events(schema_name, instance_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- moduledoc states the S4 (HTTP status mapping / IDN-03 assignee
  # authorization) scope boundary. Pure, no DB.
  # ---------------------------------------------------------------------------------

  # ---------------------------------------------------------------------------------
  # ISS-0784 site 2 -- interpret_complete_result/3's catch-all clause. Already
  # covered end-to-end at site 1 (`engine_test.exs`'s "create/2 (ISS-0784)"
  # describe block, real actor_id, instance_id read straight from create/2's
  # own 2nd positional arg). This block does NOT re-derive the audit-entry
  # field-shape assertions (action/resource_type/before_state/after_state
  # encoding) that block already proves -- it exists solely to prove the one
  # thing genuinely different about this call site per design §2 row 2:
  # `instance_id` here is read out of `changes.task.instance_id` (the
  # already-fetched `:task` Multi step, task_a's row) rather than from any
  # argument threaded directly into complete_task/3 -- a real, distinct
  # sourcing path worth its own assertion, not a "structurally identical,
  # skip it" case.
  # ---------------------------------------------------------------------------------

  describe "complete_task/3 (ISS-0784) -- a cascade task-activation rejection is recorded with instance_id from changes.task" do
    test "completing task_a triggers task_b's malformed-form_schema rejection; the audit entry's resource_id is task_a's own instance_id" do
      %{schema_name: schema_name} = provisioned_tenant()

      graph =
        graph_human_task_then_malformed_form_schema_task_end(%{"properties" => "not-an-object"})

      {instance_id, task_a} = start_instance_with_pending_task!(schema_name, graph)
      assert task_a.node_id == "task_a"

      attrs = complete_attrs()

      assert {:error, {:invalid_form_schema, "task_b", {:not_well_formed, ["properties"]}}} =
               Engine.complete_task(task_a.id, attrs, prefix: schema_name)

      # INV-ISS0784-3 -- task_a itself must not have been left COMPLETED by
      # the rolled-back attempt; the whole Multi (including task_a's own
      # completion step) rolled back with it.
      reloaded_task_a = Repo.get!(EngineTask, task_a.id, prefix: schema_name)
      assert reloaded_task_a.status == :pending

      # No task_b row was ever committed either.
      refute Enum.any?(Repo.all(EngineTask, prefix: schema_name), &(&1.node_id == "task_b"))

      assert [entry] =
               Enum.filter(
                 Repo.all(Audit.Entry, prefix: schema_name),
                 &(&1.action == "task_activation.rejected")
               )

      assert entry.resource_type == "instance"
      # The genuinely distinct assertion this test exists for: resource_id
      # equals task_a's own instance_id, sourced from
      # `changes.task.instance_id` inside interpret_complete_result/3's
      # catch-all clause -- not from any argument complete_task/3 itself
      # received directly (complete_task/3 is called with only a task_id).
      assert entry.resource_id == instance_id
      assert entry.actor_id == attrs.actor_id
      assert entry.after_state["node_id"] == "task_b"

      assert entry.after_state["reason"] == %{
               "code" => "not_well_formed",
               "path" => ["properties"]
             }
    end
  end

  describe "AC5 -- moduledoc states the S4 scope boundary for complete_task/3" do
    test "names both HTTP status-code mapping and IDN-03 assignee authorization as out of scope" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine)

      assert moduledoc =~ "complete_task/3"
      assert moduledoc =~ "S4"
      assert moduledoc =~ "IDN-03"
      assert moduledoc =~ "assignee"
      assert moduledoc =~ "404"
      assert moduledoc =~ "not checked anywhere in this module"
    end
  end
end
