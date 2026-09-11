defmodule Letflow.TenantProvisioning.TaskCompletedBackfillTest do
  @moduledoc """
  Regression tests for ISS-0583 (GH#1200): `Letflow.TenantProvisioning.Backfill.run/1`
  backfills TASK_COMPLETED to schema_version 2 for tenants provisioned before
  REQ-292 bumped the type (v1: `merged_variable_events.items.event` enum only
  admits `"variable_overwritten"`; v2 adds `"computed_field_disagreement"` and
  `"visible_when_false_value_discarded"`).

  Unlike `test/letflow/tenant_provisioning/backfill_test.exs` (which asserts at
  the `Registry.get_type/2`/`Registry.validate_payload/3` level), this file
  drives the REAL `Letflow.Engine.complete_task/3` path end-to-end -- AC2 of
  GH#1200 explicitly wants the genuine engine-level reproduction: a v1-pinned
  tenant's task completion that triggers REQ-292's server-side form-expression
  re-evaluation genuinely FAILS before the backfill runs, and genuinely
  SUCCEEDS after.

  Per the design doc (`lib/letflow/design/iss0583-task-completed-schema-version-backfill.md`
  §5.2), this file duplicates (rather than imports) the handful of
  engine-plumbing helpers it needs from
  `test/letflow/engine_form_expression_reevaluation_test.exs` -- no
  `test/support/` module currently exports them for cross-file reuse, and this
  codebase does not reach into another test module's private functions.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1. `async: false` -- required because `provisioned_tenant/0`
  switches `Letflow.Repo` to Sandbox `:auto` mode for real schema creation, same
  reasoning as `test/letflow/tenant_provisioning/backfill_test.exs`.

  `provisioned_tenant/0` uses `Letflow.Test.SandboxAutoMode.provision!/2`
  (ISS-0580) rather than a raw, unrestored `Ecto.Adapters.SQL.Sandbox.mode/2`
  call -- `Sandbox.mode/2` is pool-wide, not process-scoped, so leaving it at
  `:auto` after this helper returns corrupts isolation for every other
  `async: true` test in the suite (the exact `ColumnPromotionTest` AC1 flake
  ISS-0580 fixed). Matches
  `test/letflow/tenant_provisioning/column_promotion_test.exs`'s own
  `provisioned_tenant/0` pattern exactly (SECURITY-REVIEWER-flagged rework).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Backfill
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.SandboxAutoMode

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- duplicated from
  # test/letflow/engine_form_expression_reevaluation_test.exs per design doc §5.2,
  # with provisioned_tenant/0's sandbox-mode handling brought in line with
  # test/letflow/tenant_provisioning/column_promotion_test.exs's ISS-0580-safe
  # pattern instead (SECURITY-REVIEWER rework -- see moduledoc).
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("iss0583"),
        display_name: "ISS-0583 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    SandboxAutoMode.provision!(Letflow.Repo, fn ->
      tenant = insert_tenant!()

      on_exit(fn ->
        # ISS-0580 rework: this callback runs AFTER the test process (and thus
        # SandboxAutoMode.provision!/2's own restore-to-:manual-plus-checkout,
        # scoped to that now-gone process) is gone -- so it must not assume
        # :manual mode still has a connection checked out for THIS
        # (OnExitHandler) process. Force :auto mode first so the DROP
        # SCHEMA/delete_all cleanup below always gets a real, checked-in
        # connection regardless of what mode the test process left the pool
        # in. Mirrors column_promotion_test.exs's own on_exit/1 handling of
        # this exact hazard.
        Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

        case TenantProvisioning.schema_name_for_tenant(tenant.id) do
          {:ok, schema_name} -> drop_schema!(schema_name)
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))

        # REVIEWER fix (ISS-0580): restore :manual after cleanup -- leaving the
        # force-:auto above unrestored would reopen this exact leak, once per
        # test in this file instead of once ever. No checkout needed (same
        # reasoning as SandboxAutoMode.exit_auto_mode!/1's own doc: this
        # OnExitHandler process is not going to issue another Repo call).
        SandboxAutoMode.exit_auto_mode!(Letflow.Repo)
      end)

      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantProvisioning.provision_tenant_schema(tenant.id)

      assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

      %{tenant_id: tenant.id, schema_name: schema_name}
    end)
  end

  defp unique_name(prefix \\ "iss0583-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> task(HUMAN_TASK, form_schema) -> END.
  defp graph_with_form_schema(form_schema) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver", "form_schema" => form_schema}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp create_definition_attrs(name, version, graph) do
    %{
      name: name,
      version: version,
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  defp active_definition!(schema_name, graph, name, version) do
    assert {:ok, definition} =
             Definitions.create(
               create_definition_attrs(name || unique_name(), version, graph),
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp start_attrs(definition, overrides) do
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

  defp start_instance_with_pending_task!(schema_name, graph, opts \\ []) do
    name = Keyword.get(opts, :name)
    version = Keyword.get(opts, :version, "1.0.0")
    initial_variables = Keyword.get(opts, :initial_variables, %{"seed" => "value"})

    definition = active_definition!(schema_name, graph, name, version)

    assert {:ok, result} =
             Engine.create(
               start_attrs(definition, %{initial_variables: initial_variables}),
               prefix: schema_name
             )

    [task] = Repo.all(EngineTask, prefix: schema_name)
    assert task.status == :pending

    {result.instance_id, task, definition}
  end

  defp complete_attrs(overrides) do
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

  # Shared schema for the computed/visible_when scenarios -- copied verbatim
  # from engine_form_expression_reevaluation_test.exs's
  # schema_computed_and_visible_when/0.
  defp schema_computed_and_visible_when do
    %{
      "type" => "object",
      "properties" => %{
        "amount" => %{"type" => "number"},
        "bonus" => %{"type" => "number", "x-ui" => %{"computed" => "amount + 1"}},
        "note" => %{"type" => "string", "x-ui" => %{"visible_when" => "amount > 0"}}
      }
    }
  end

  # V2 attrs: exact copy of lib/letflow/tenant_provisioning.ex lines ~788-821 --
  # independently transcribed from tenant_provisioning.ex, not from the mix
  # task's own @task_completed_v2_attrs nor from backfill_test.exs's copy, per
  # design doc §5.1/§5.2 ("each must copy from tenant_provisioning.ex directly").
  defp task_completed_v2_attrs do
    %{
      "name" => "TASK_COMPLETED",
      "schema_version" => 2,
      "description" => "ISS-0583 v2 test fixture",
      "json_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "output_variables" => %{"type" => "object"},
          "merged_variable_events" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "event" => %{
                  "type" => "string",
                  "enum" => [
                    "variable_overwritten",
                    "computed_field_disagreement",
                    "visible_when_false_value_discarded"
                  ]
                },
                "key" => %{"type" => "string"},
                "field" => %{"type" => "string"},
                "old_value" => %{},
                "new_value" => %{},
                "submitted_value" => %{},
                "server_value" => %{},
                "discarded_value" => %{}
              },
              "required" => ["event"]
            }
          },
          "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["task_id", "node_id", "output_variables", "activated_nodes"]
      }
    }
  end

  # Removes all TASK_COMPLETED entries from the tenant's event_type_registry and
  # inserts a fresh v1 row, simulating a pre-REQ-292 provisioned tenant.
  defp downgrade_task_completed_to_v1!(schema_name) do
    from(e in EventType, where: e.name == "TASK_COMPLETED")
    |> Repo.delete_all(prefix: schema_name)

    EventType.changeset(%EventType{}, %{
      "name" => "TASK_COMPLETED",
      "schema_version" => 1,
      "description" => "ISS-0583 v1 test fixture",
      "json_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "output_variables" => %{"type" => "object"},
          "merged_variable_events" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "event" => %{"type" => "string", "enum" => ["variable_overwritten"]},
                "key" => %{"type" => "string"}
              },
              "required" => ["event", "key"]
            }
          },
          "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["task_id", "node_id", "output_variables", "activated_nodes"]
      }
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- computed_field_disagreement: real Engine.complete_task/3 fails against
  # a v1-pinned tenant, then succeeds after Backfill.run/1.
  # ---------------------------------------------------------------------------------

  describe "TASK_COMPLETED backfill fixes computed_field_disagreement (ISS-0583 AC2)" do
    test "complete_task/3 fails with payload_validation_failed before backfill, succeeds after" do
      %{schema_name: schema_name} = provisioned_tenant()

      downgrade_task_completed_to_v1!(schema_name)

      {_instance_id, task, _definition} =
        start_instance_with_pending_task!(
          schema_name,
          graph_with_form_schema(schema_computed_and_visible_when())
        )

      attrs =
        complete_attrs(%{output_variables: %{"amount" => 5, "bonus" => 999, "note" => "ok"}})

      # BEFORE backfill: v1 schema rejects the computed_field_disagreement event
      # kind, exactly this issue's reported defect. Per design doc §1, the
      # caller-visible shape is {:event_append_failed, {:payload_validation_failed,
      # failures}} -- one level deeper than the issue text's own shorthand.
      assert {:error, {:event_append_failed, {:payload_validation_failed, failures}}} =
               Engine.complete_task(task.id, attrs, prefix: schema_name)

      assert failures != []

      # No partial commit -- the task stays pending.
      untouched_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert untouched_task.status == :pending

      assert {:ok, %{updated: updated, skipped: _skipped}} =
               Backfill.run(task_completed_v2_attrs())

      assert updated >= 1

      # AFTER backfill: the SAME task, re-submitted (fresh idempotency_key via
      # complete_attrs/1), now succeeds.
      retry_attrs =
        complete_attrs(%{output_variables: %{"amount" => 5, "bonus" => 999, "note" => "ok"}})

      assert {:ok, result} = Engine.complete_task(task.id, retry_attrs, prefix: schema_name)
      assert result.variables["bonus"] == 6

      assert [event] = task_completed_events(schema_name, task.instance_id)

      disagreement_events =
        Enum.filter(
          event.payload["merged_variable_events"],
          &(&1["event"] == "computed_field_disagreement")
        )

      assert [
               %{
                 "event" => "computed_field_disagreement",
                 "field" => "bonus",
                 "submitted_value" => 999,
                 "server_value" => 6
               }
             ] = disagreement_events

      completed_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert completed_task.status == :completed
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- visible_when_false_value_discarded: same before/after shape, second
  # event kind (design doc §5.2 step 8 -- covering both kinds rather than
  # descoping to one, since the fixtures already exist verbatim).
  # ---------------------------------------------------------------------------------

  describe "TASK_COMPLETED backfill fixes visible_when_false_value_discarded (ISS-0583 AC2)" do
    test "complete_task/3 fails with payload_validation_failed before backfill, succeeds after" do
      %{schema_name: schema_name} = provisioned_tenant()

      downgrade_task_completed_to_v1!(schema_name)

      {_instance_id, task, _definition} =
        start_instance_with_pending_task!(
          schema_name,
          graph_with_form_schema(schema_computed_and_visible_when())
        )

      attrs =
        complete_attrs(%{output_variables: %{"amount" => -1, "note" => "secret"}})

      # BEFORE backfill: v1 schema rejects the visible_when_false_value_discarded
      # event kind.
      assert {:error, {:event_append_failed, {:payload_validation_failed, failures}}} =
               Engine.complete_task(task.id, attrs, prefix: schema_name)

      assert failures != []

      untouched_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert untouched_task.status == :pending

      assert {:ok, %{updated: updated, skipped: _skipped}} =
               Backfill.run(task_completed_v2_attrs())

      assert updated >= 1

      retry_attrs =
        complete_attrs(%{output_variables: %{"amount" => -1, "note" => "secret"}})

      assert {:ok, result} = Engine.complete_task(task.id, retry_attrs, prefix: schema_name)
      refute Map.has_key?(result.variables, "note")

      assert [event] = task_completed_events(schema_name, task.instance_id)

      discard_events =
        Enum.filter(
          event.payload["merged_variable_events"],
          &(&1["event"] == "visible_when_false_value_discarded")
        )

      assert [
               %{
                 "event" => "visible_when_false_value_discarded",
                 "field" => "note",
                 "discarded_value" => "secret"
               }
             ] = discard_events

      completed_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert completed_task.status == :completed
    end
  end
end
