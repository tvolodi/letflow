defmodule Letflow.EngineVariableSchemaMergeTest do
  @moduledoc """
  REQ-109's end-to-end criteria, every one of them driven through the real
  `Letflow.Engine.complete_task/3`:

    * **AC3** — a seeded `variable_schemas` row plus a violating overwrite leaves the
      value unmerged, the instance in ERROR, and exactly one `EXECUTION_ERROR` naming
      the offending `variable_key`.
    * **AC4** — a conforming overwrite still merges, status unchanged, token advanced.
    * **AC5** — an overwrite candidate with no row merges untouched; a brand-new key
      is inserted unvalidated even when a row exists for that exact key.
    * **AC6** — a tenant-A row has zero effect on the identical completion in tenant B.

  ## Why AC3 is the file's centre of gravity

  `test/letflow/engine_execution_error_test.exs`'s AC4b reaches REQ-049's
  `error_args()` shape through `Letflow.Engine.set_instance_error/2`, with an in-line
  comment reading "Currently unreachable via complete_task/3." That shortcut was
  legitimate: `merge_output_variables` hardcoded `variable_validations: nil`, sanctioned
  by `req049-variable-merge.md` §7.3, so `VariableMerge.merge/3`'s `{:rejected, …}`
  branch could not fire in production. **REQ-109 is the requirement that removes the
  hardcoded `nil`**, and AC3's test below is the only artefact in the suite that proves
  it: it never calls `set_instance_error/2`, and against pre-REQ-109 code the same
  completion returns `{:ok, _}` and merges the violating value.

  Real Postgres, no mocked database (`test_developer_guide.md` T-1); self-contained
  fixtures provisioning this file's own tenant schemas (T-4), mirroring
  `engine_complete_task_test.exs`'s `provisioned_tenant/0` + Sandbox `:auto` +
  `async: false` pattern. Storage-side coverage (AC1, AC2, AC7) lives in
  `test/letflow/engine/variable_schema_test.exs`; see `test/specs/REQ-109.md` for the
  full rationale, including why ACs 8-13 carry no ExUnit test.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.VariableSchema
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
        slug: Letflow.TenantSlugFixture.unique_slug("req109-merge"),
        display_name: "REQ-109 Merge Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # "TASK_COMPLETED" and "EXECUTION_ERROR" are both auto-seeded by
  # replay_migrations/2's default manifest (REQ-045 section 9 OQ-3a, extended by
  # ISS-0072/GH#257) -- no fixture-local event-type registration here, matching
  # engine_complete_task_test.exs and engine_execution_error_test.exs.
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

  defp unique_name do
    "req109-merge-def-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> task(HUMAN_TASK) -> END. Completing `task` drives the instance to
  # :completed within the same call -- used wherever the final status is irrelevant.
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

  # START -> task_a -> task_b -> END. AC4 needs a graph where completing the first
  # task leaves the instance :active, so that "status unchanged" is observable at all
  # (on graph_human_task_end/0 the instance would legitimately flip to :completed).
  defp graph_two_human_tasks do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task_a", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "a"}},
        %{"id" => "task_b", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "b"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task_a"},
        %{"id" => "e2", "source" => "task_a", "target" => "task_b"},
        %{"id" => "e3", "source" => "task_b", "target" => "end"}
      ]
    }
  end

  defp definition_attrs(graph) do
    %{
      name: unique_name(),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  defp active_definition!(schema_name, graph) do
    assert {:ok, definition} = Definitions.create(definition_attrs(graph), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # AC6 only: reproduces `definition` in another tenant schema under the SAME id, so
  # the two completions really are identical in the (definition_id, variable_key,
  # violating value) triple AC6 names. `Definitions.create/2` autogenerates an id and
  # does not cast one, so the row is inserted through the same ProcessDefinition
  # changeset with the id pre-set on the struct, then activated through the real
  # Definitions.activate/2.
  defp clone_active_definition!(schema_name, definition) do
    %ProcessDefinition{id: definition.id}
    |> ProcessDefinition.create_changeset(%{
      name: definition.name,
      version: definition.version,
      graph: definition.graph,
      created_by: definition.created_by
    })
    |> Repo.insert!(prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp start_instance!(schema_name, definition, initial_variables) do
    attrs = %{
      definition_id: definition.id,
      initial_variables: initial_variables,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique_idempotency_key("start")
    }

    assert {:ok, result} = Engine.create(attrs, prefix: schema_name)
    result.instance_id
  end

  defp complete_attrs(output_variables) do
    %{
      output_variables: output_variables,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique_idempotency_key("complete")
    }
  end

  defp find_task(schema_name, instance_id, node_id) do
    EngineTask
    |> where([t], t.instance_id == ^instance_id and t.node_id == ^node_id)
    |> Repo.one!(prefix: schema_name)
  end

  defp events_of_type(schema_name, instance_id, event_type) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == ^event_type)
    |> Repo.all(prefix: schema_name)
  end

  # REQ-109 builds no registration/INSERT path (REQ-078/REQ-082 own it, design
  # section 9.1), so rows are seeded directly against the provisioned tenant schema --
  # exactly as the requirement's own acceptance criteria specify.
  defp seed_schema_row!(schema_name, definition_id, variable_key, json_schema) do
    %VariableSchema{}
    |> VariableSchema.changeset(%{
      definition_id: definition_id,
      variable_key: variable_key,
      json_schema: json_schema
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- THE requirement's point: a violating overwrite rejected through the REAL
  # Letflow.Engine.complete_task/3 path. Engine.set_instance_error/2 is deliberately
  # never called anywhere in this describe block.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- a violating overwrite through complete_task/3" do
    test "instance lands in ERROR with one EXECUTION_ERROR naming the key, value unmerged" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_human_task_end())

      seed_schema_row!(schema_name, definition.id, "amount", %{"type" => "number"})

      # "amount" is present in the instance's variables, so the completion below is an
      # OVERWRITE candidate -- the only class REQ-109 validates (AC5, design section 4.5
      # step 2).
      instance_id = start_instance!(schema_name, definition, %{"amount" => 100})
      task = find_task(schema_name, instance_id, "task")

      assert {:error, {:instance_execution_error, :variable_schema_rejected, {:field, "amount"}}} =
               Engine.complete_task(
                 task.id,
                 complete_attrs(%{"amount" => "not-a-number"}),
                 prefix: schema_name
               )

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)

      # The rejected value is NOT in the variable map -- merge/3's validate-all-then-
      # apply two-phase semantic (R-Co ISS-202), observable in production for the
      # first time.
      assert projection.variables == %{"amount" => 100}
      assert projection.status == :error

      # EXACTLY one EXECUTION_ERROR, and its payload names the offending variable_key.
      assert [event] = events_of_type(schema_name, instance_id, "EXECUTION_ERROR")
      assert event.payload["error_type"] == "variable_schema_rejected"
      assert event.payload["affected"] == %{"kind" => "field", "key" => "amount"}
      assert event.payload["reason"] =~ "amount"
      assert event.payload["variables"] == %{"amount" => 100}

      # The completion never happened: no TASK_COMPLETED, task still pending.
      assert events_of_type(schema_name, instance_id, "TASK_COMPLETED") == []
      assert Repo.get!(EngineTask, task.id, prefix: schema_name).status == :pending
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- a conforming overwrite still merges.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- a conforming overwrite still merges" do
    test "key overwritten, status unchanged, token advanced, overwrite recorded" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_two_human_tasks())

      seed_schema_row!(schema_name, definition.id, "amount", %{"type" => "number"})

      instance_id = start_instance!(schema_name, definition, %{"amount" => 100})
      task_a = find_task(schema_name, instance_id, "task_a")

      assert {:ok, _result} =
               Engine.complete_task(
                 task_a.id,
                 complete_attrs(%{"amount" => 250}),
                 prefix: schema_name
               )

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.variables == %{"amount" => 250}
      # Unchanged -- still :active, which is why this test uses the two-task graph.
      assert projection.status == :active
      # The token advanced, verified both on the projection and by the new task row.
      assert projection.current_nodes == ["task_b"]
      assert %EngineTask{status: :pending} = find_task(schema_name, instance_id, "task_b")

      assert events_of_type(schema_name, instance_id, "EXECUTION_ERROR") == []

      # AC4 says "appends a VARIABLE_OVERWRITTEN event". There is no such event row:
      # REQ-048's INV-EE48-5 (engine.ex:2221-2224) embeds merge outcomes inside the
      # single TASK_COMPLETED event's payload and states they are "never appended as
      # their own separate rows". The real artefact is asserted here, and the absence
      # of a separate row is pinned immediately below so the divergence between AC4's
      # wording and the shipped design is recorded rather than glossed.
      assert [completed] = events_of_type(schema_name, instance_id, "TASK_COMPLETED")

      assert completed.payload["merged_variable_events"] == [
               %{
                 "event" => "variable_overwritten",
                 "key" => "amount",
                 "old_value" => 100,
                 "new_value" => 250
               }
             ]

      assert events_of_type(schema_name, instance_id, "VARIABLE_OVERWRITTEN") == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- two explicit tests.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- an overwrite candidate with no row" do
    test "merges untouched with no EXECUTION_ERROR" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_two_human_tasks())

      # A row IS seeded, but for a DIFFERENT key -- so the single SELECT genuinely runs
      # and genuinely returns a row. An empty table would pass even if fetch_schemas/3
      # returned %{} unconditionally; this pins the per-key omission rule
      # (design section 6.2 / INV-VS-4).
      seed_schema_row!(schema_name, definition.id, "other", %{"type" => "number"})

      instance_id = start_instance!(schema_name, definition, %{"amount" => 100})
      task_a = find_task(schema_name, instance_id, "task_a")

      assert {:ok, _result} =
               Engine.complete_task(
                 task_a.id,
                 complete_attrs(%{"amount" => "no schema constrains this"}),
                 prefix: schema_name
               )

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.variables == %{"amount" => "no schema constrains this"}
      assert projection.status == :active
      assert events_of_type(schema_name, instance_id, "EXECUTION_ERROR") == []
    end
  end

  describe "AC5 -- a brand-new key is never validated" do
    test "a violating value for a seeded key is still inserted when the key is new" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_two_human_tasks())

      # A row for exactly the key the completion writes.
      seed_schema_row!(schema_name, definition.id, "amount", %{"type" => "number"})

      # ...but the instance does not carry "amount", so it is a brand-new key, not an
      # overwrite candidate.
      instance_id = start_instance!(schema_name, definition, %{"seed" => 1})
      task_a = find_task(schema_name, instance_id, "task_a")

      assert {:ok, _result} =
               Engine.complete_task(
                 task_a.id,
                 complete_attrs(%{"amount" => "not-a-number"}),
                 prefix: schema_name
               )

      # THIS ASSERTS THE IMPLEMENTED BEHAVIOUR, NOT R-Co's. R-Co's Phase 1
      # (instance.zig:2390-2430) validates every key that has a schema and only then
      # checks collision; Letflow validates overwrite candidates only
      # (req049-variable-merge.md section 3.1 step 3, design section 11.1 OQ-1).
      # That divergence is tracked as ISS-0077 / GH#300 with a decision pending.
      # REQ-109 is built to AC5 as written, so this test pins AC5's semantics -- if
      # ISS-0077 is decided the other way, this is the test that must change.
      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.variables == %{"seed" => 1, "amount" => "not-a-number"}
      assert projection.status == :active
      assert events_of_type(schema_name, instance_id, "EXECUTION_ERROR") == []
    end
  end

  # ---------------------------------------------------------------------------------
  # NOT TESTED HERE, AND WHY -- {:variable_schema_lookup_failed, reason}
  # (engine.ex:1671, and a clause of complete_task/3's own @spec at :1263) has NO
  # reachable end-to-end trigger, so no test for it is written. Both members of
  # VariableSchema.error_reason() are structurally unreachable from complete_task/3:
  #
  #   * :missing_prefix -- complete_task/3 resolves the tenant from `prefix` via
  #     TenantProvisioning.tenant_id_for_schema_name/1 (engine.ex:1315) BEFORE
  #     run_complete_task/6 is entered, so a nil/empty prefix is rejected several
  #     steps earlier and never reaches the merge step.
  #   * :invalid_definition_id -- instance_projection.ex:113 types definition_id as a
  #     nullable Ecto.UUID, but the COLUMN is `null: false` and typed `uuid`
  #     (20260818110001_alter_instance_projections_add_engine_columns.exs:71).
  #     Verified by execution: forcing it via Repo.update_all raises
  #     Postgrex.Error 23502 (not_null_violation) rather than producing the state.
  #     A malformed non-UUID value is likewise rejected by the column type.
  #
  # The guard is therefore correct defence-in-depth against a state the schema
  # forbids, of the same class as ISS-0089/GH#306's non-map json_schema branch -- and
  # like that one, it is covered as a UNIT test (variable_schema_test.exs's AC7
  # block asserts {:error, :invalid_definition_id} from fetch_schemas/3 directly)
  # rather than by a DB-seeded test that would certify a path production cannot take.
  # Reported to ORCH for forward filing rather than faked here.
  # ---------------------------------------------------------------------------------

  # ---------------------------------------------------------------------------------
  # AC6 -- cross-tenant isolation (INV-1). The two completions differ in nothing but
  # which tenant schema holds the variable_schemas row: same definition_id, same
  # variable_key, same violating value, same graph.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- a tenant-A row has zero effect in tenant B" do
    test "the identical completion is rejected in A and succeeds in B" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()
      refute schema_a == schema_b

      definition_a = active_definition!(schema_a, graph_two_human_tasks())
      definition_b = clone_active_definition!(schema_b, definition_a)
      # The AC's "identical (definition_id, variable_key, violating value)" is literal:
      # isolation must come from the prefix, not from the id. definition_id values are
      # not themselves tenant-scoped (design section 7).
      assert definition_b.id == definition_a.id

      seed_schema_row!(schema_a, definition_a.id, "amount", %{"type" => "number"})

      # Rows read back in BOTH schemas before either completion runs.
      assert [%VariableSchema{variable_key: "amount"}] =
               Repo.all(VariableSchema, prefix: schema_a)

      assert Repo.all(VariableSchema, prefix: schema_b) == []

      instance_a = start_instance!(schema_a, definition_a, %{"amount" => 100})
      instance_b = start_instance!(schema_b, definition_b, %{"amount" => 100})

      task_a = find_task(schema_a, instance_a, "task_a")
      task_b = find_task(schema_b, instance_b, "task_a")

      # Tenant A: rejected.
      assert {:error, {:instance_execution_error, :variable_schema_rejected, {:field, "amount"}}} =
               Engine.complete_task(
                 task_a.id,
                 complete_attrs(%{"amount" => "not-a-number"}),
                 prefix: schema_a
               )

      # Tenant B: the identical completion succeeds.
      assert {:ok, _result} =
               Engine.complete_task(
                 task_b.id,
                 complete_attrs(%{"amount" => "not-a-number"}),
                 prefix: schema_b
               )

      projection_a = Repo.get!(InstanceProjection, instance_a, prefix: schema_a)
      assert projection_a.status == :error
      assert projection_a.variables == %{"amount" => 100}
      assert [_one] = events_of_type(schema_a, instance_a, "EXECUTION_ERROR")

      projection_b = Repo.get!(InstanceProjection, instance_b, prefix: schema_b)
      assert projection_b.status == :active
      assert projection_b.variables == %{"amount" => "not-a-number"}
      assert events_of_type(schema_b, instance_b, "EXECUTION_ERROR") == []
    end
  end
end
