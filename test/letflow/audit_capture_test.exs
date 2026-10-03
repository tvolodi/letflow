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
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.SandboxAutoMode

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366),
  # teardown: false because this file wraps provisioning in
  # SandboxAutoMode.provision!/2 and needs its own on_exit to force :auto mode
  # back on before the drop/delete cleanup and restore :manual afterward (the
  # ISS-0580 leak fix) -- TenantFixture's own default teardown does not do that
  # composition, so it stays disabled and this file's pre-existing on_exit is
  # kept untouched, matching category A's documented pattern.
  # ---------------------------------------------------------------------------------

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    SandboxAutoMode.provision!(Letflow.Repo, fn ->
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "req195-capture",
          display_name: "REQ-195 Audit Capture Test Tenant",
          teardown: false
        )

      on_exit(fn ->
        # ISS-0580 rework: this callback runs AFTER the test process (and thus
        # SandboxAutoMode.provision!/2's own restore-to-:manual-plus-checkout,
        # scoped to that now-gone process) is gone -- so it must not assume
        # :manual mode still has a connection checked out for THIS (OnExitHandler)
        # process. Force :auto mode first so the DROP SCHEMA/delete_all cleanup
        # below always gets a real, checked-in connection regardless of what mode
        # the test process left the pool in. Mirrors role_registry_test.exs's own
        # on_exit/1 handling of this exact hazard.
        Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> drop_schema!(schema_name)
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))

        # REVIEWER fix (ISS-0580): restore :manual after cleanup -- leaving the
        # force-:auto above unrestored would reopen this exact leak, once per
        # test in this file instead of once ever. No checkout needed (same
        # reasoning as SandboxAutoMode.exit_auto_mode!/1's own doc: this
        # OnExitHandler process is not going to issue another Repo call).
        SandboxAutoMode.exit_auto_mode!(Letflow.Repo)
      end)

      %{tenant_id: tenant_id, schema_name: schema_name}
    end)
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

      # ISS-0981: Engine.run_complete_task/6 (the Multi-building boundary
      # function behind complete_task/3) is now rescue-hardened the same way
      # Definitions.activate/2 already was -- a raise from the
      # same-transaction Audit.insert_entry/3 call no longer escapes
      # uncaught, it converts into {:error, {:transaction_failed, exception}},
      # mirroring the "definition activation" test immediately above. Ecto's
      # Repo.transaction/1 still rolls back the DB transaction before the
      # raise reaches this function's own rescue clause -- that rollback,
      # not a clean {:error, _} return, remains the AC3 guarantee this test
      # checks.
      assert {:error, {:transaction_failed, _exception}} =
               Engine.complete_task(
                 task.id,
                 %{
                   output_variables: %{"decision" => "approved"},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_idempotency_key("complete-fail")
                 },
                 prefix: schema_name
               )

      reloaded_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert reloaded_task.status == :pending

      projection =
        Repo.get!(Letflow.EventStore.InstanceProjection, instance_id, prefix: schema_name)

      assert projection.status == :active
    end

    test "instance creation: a failed audit insert leaves no instance_projections/tokens rows" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = draft_definition!(schema_name)

      assert {:ok, %{definition: activated}} =
               Definitions.activate(definition.id, prefix: schema_name)

      Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

      # ISS-0981: Engine.persist/14 (the Multi-building boundary function
      # behind create/2's own atomic phase) is now rescue-hardened the same
      # way -- record_instance_create_audit/4's same-transaction
      # Audit.insert_entry/3 call raises against the dropped table, and
      # persist/14 converts that into {:error, {:transaction_failed,
      # exception}} instead of letting it escape uncaught.
      assert {:error, {:transaction_failed, _exception}} =
               Engine.create(start_attrs(activated), prefix: schema_name)

      assert Repo.aggregate(Letflow.EventStore.InstanceProjection, :count, prefix: schema_name) ==
               0

      assert Repo.aggregate(Letflow.Engine.TokenRecord, :count, prefix: schema_name) == 0
    end
  end
end
