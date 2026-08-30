defmodule Letflow.AuditCaptureTest do
  @moduledoc """
  Integration tests for REQ-195's AC2 (definition activation, instance
  cancellation, and task completion each write exactly one `audit_entries`
  row with real, non-null `before_state`/`after_state` content) and AC3 (an
  audit-write failure rolls back the business mutation it accompanies) --
  exercised against the actual covered context functions
  (`Letflow.Definitions.activate/2`, `Letflow.Engine.cancel_instance/3`,
  `Letflow.Engine.complete_task/3`), not against `Letflow.Audit` directly
  (see `test/letflow/audit_test.exs` for that).

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1. Self-contained: does
  not share fixtures with any other test file (DIRECTIVE T-4) -- the
  provisioning/graph/instance helpers below are a deliberately-narrowed copy
  of the shape `test/letflow/engine_complete_task_test.exs` already
  establishes, kept local rather than shared per that file's own stated
  precedent.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
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
        slug: Letflow.TenantSlugFixture.unique_slug("req195-capture"),
        display_name: "REQ-195 Audit Capture Test Tenant"
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

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req195-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

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

  defp draft_definition!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph_human_task_end()),
               prefix: schema_name
             )

    definition
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

  defp start_instance_with_pending_task!(schema_name) do
    definition = draft_definition!(schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    assert {:ok, result} = Engine.create(start_attrs(activated), prefix: schema_name)

    [task] = Repo.all(EngineTask, prefix: schema_name)
    assert task.status == :pending

    {result.instance_id, task}
  end

  defp audit_rows_for(schema_name, action) do
    Entry
    |> where([e], e.action == ^action)
    |> Repo.all(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- definition activation
  # ---------------------------------------------------------------------------------

  describe "AC2 -- definition activation writes exactly one audit row with real before/after" do
    test "captures the DRAFT before_state and ACTIVE after_state" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = draft_definition!(schema_name)

      assert {:ok, %{definition: activated}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert [entry] = audit_rows_for(schema_name, "definition.activate")
      assert entry.resource_type == "definition"
      assert entry.resource_id == definition.id
      assert entry.actor_id == nil

      assert entry.before_state["status"] == "draft"
      assert entry.before_state["id"] == definition.id
      assert entry.before_state["name"] == definition.name

      assert entry.after_state["status"] == "active"
      assert entry.after_state["id"] == activated.id
      assert entry.after_state["name"] == definition.name
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- instance cancellation
  # ---------------------------------------------------------------------------------

  describe "AC2 -- instance cancellation writes exactly one audit row with real before/after" do
    test "captures the pre-cancel and post-cancel instance projection content" do
      %{schema_name: schema_name} = provisioned_tenant()

      {instance_id, _task} = start_instance_with_pending_task!(schema_name)

      actor_id = Ecto.UUID.generate()

      assert {:ok, _result} =
               Engine.cancel_instance(
                 instance_id,
                 %{actor_id: actor_id, idempotency_key: unique_idempotency_key("cancel")},
                 prefix: schema_name
               )

      assert [entry] = audit_rows_for(schema_name, "instance.cancel")
      assert entry.resource_type == "instance"
      assert entry.resource_id == instance_id
      assert entry.actor_id == actor_id

      assert entry.before_state["status"] == "active"
      assert entry.after_state["status"] == "cancelled"
      assert entry.after_state["instance_id"] == instance_id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- task completion
  # ---------------------------------------------------------------------------------

  describe "AC2 -- task completion writes exactly one audit row with real before/after" do
    test "captures the pre-complete and post-complete task row content" do
      %{schema_name: schema_name} = provisioned_tenant()

      {_instance_id, task} = start_instance_with_pending_task!(schema_name)

      actor_id = Ecto.UUID.generate()

      assert {:ok, _result} =
               Engine.complete_task(
                 task.id,
                 %{
                   output_variables: %{"decision" => "approved"},
                   actor_id: actor_id,
                   idempotency_key: unique_idempotency_key("complete")
                 },
                 prefix: schema_name
               )

      assert [entry] = audit_rows_for(schema_name, "task.complete")
      assert entry.resource_type == "task"
      assert entry.resource_id == task.id
      assert entry.actor_id == actor_id

      assert entry.before_state["status"] == "pending"
      assert entry.before_state["id"] == task.id

      assert entry.after_state["status"] == "completed"
      assert entry.after_state["output_variables"] == %{"decision" => "approved"}
      assert entry.after_state["completed_by"] == actor_id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- an audit-write failure rolls back the business mutation it
  # accompanies. Forced by dropping audit_entries out from under a live
  # transaction -- the insert step then fails for a real reason (undefined
  # table), the same as any other audit-write failure would.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- an audit-write failure rolls back the accompanying mutation" do
    test "definition activation: a failed audit insert leaves the definition unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = draft_definition!(schema_name)

      Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

      assert {:error, {:transaction_failed, _exception}} =
               Definitions.activate(definition.id, prefix: schema_name)

      reloaded = Repo.get!(ProcessDefinition, definition.id, prefix: schema_name)
      assert reloaded.status == :draft
    end

    test "task completion: a failed audit insert leaves the task and instance unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()

      {instance_id, task} = start_instance_with_pending_task!(schema_name)

      Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

      # Unlike Definitions.activate/2 (which wraps its transaction in its own
      # try/rescue, per design §8's note that ELIXIR-DEV must not silently
      # add exception-safety this codebase's existing functions don't
      # already have), Engine.complete_task/3 has no try/rescue of its own
      # today -- an unexpected DB-level failure at any Multi step already
      # propagates as a raised exception, pre-existing behavior this
      # requirement does not change. Ecto's Repo.transaction/1 still rolls
      # back the DB transaction before re-raising (that rollback, not a
      # clean {:error, _} return, is the AC3 guarantee this test checks).
      assert_raise Postgrex.Error, ~r/audit_entries.*does not exist/, fn ->
        Engine.complete_task(
          task.id,
          %{
            output_variables: %{"decision" => "approved"},
            actor_id: Ecto.UUID.generate(),
            idempotency_key: unique_idempotency_key("complete-fail")
          },
          prefix: schema_name
        )
      end

      reloaded_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert reloaded_task.status == :pending

      projection =
        Repo.get!(Letflow.EventStore.InstanceProjection, instance_id, prefix: schema_name)

      assert projection.status == :active
    end
  end
end
