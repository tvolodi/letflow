defmodule Letflow.EngineSubProcessTest do
  @moduledoc """
  DB-integration tests for REQ-062's SPC-01 sub-process runtime half -- real child
  instance creation via `Letflow.Engine.create/2`'s activation loop, completion
  propagation via `Letflow.Engine.complete_task/3`'s hop chain, and the four SPC-01
  failure modes, all driven through the real public `Letflow.Engine`/`Letflow.Definitions`
  surface (never a direct `Letflow.Engine.SubProcess` call) so these tests exercise the
  exact transaction shape a real caller would trigger. See
  `lib/letflow/design/req062-sub-process-runtime.md` and `test/specs/REQ-062.md` for the
  full design/AC-to-test-case mapping. Pure-layer coverage (input/output filtering,
  `Transition`'s new `:SUB_PROCESS` dispatch clauses, the AC5 GH-428 struct-update
  regression) lives in `test/letflow/engine/sub_process_test.exs`.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. Mirrors
  `test/letflow/engine_complete_task_test.exs`'s own `provisioned_tenant/0` + Sandbox
  `:auto` + `async: false` pattern, registering the extra event types this module's own
  new code appends (`SUB_PROCESS_COMPLETED`) alongside the pre-existing
  `TASK_COMPLETED`/`EXECUTION_ERROR` every failure-mode/completion test needs.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

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
        slug: Letflow.TenantSlugFixture.unique_slug("req062"),
        display_name: "REQ-062 Test Tenant"
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

    # INSTANCE_STARTED, TASK_COMPLETED, EXECUTION_ERROR, SUB_PROCESS_COMPLETED, and
    # INSTANCE_CANCELLED are now all auto-seeded by replay_migrations/2's default
    # manifest (REQ-045 §9 OQ-3a, extended by ISS-0072/GH#257) -- this fixture used to
    # self-register the latter four against a permissive `%{"type" => "object"}`
    # schema (ISS-0073/GH#267: that duplicate registration now collides with
    # provisioning's own seed and hard-fails). Removed rather than reconciled: this
    # file's actual event payloads are produced by the same production writers
    # (Engine.complete_task/3, ExecutionError.append_execution_error_event/2, the
    # SUB_PROCESS_COMPLETED and cancel_instance/3 paths) that provisioning's own
    # stricter schema was written to validate, so relying on the real seed here isn't
    # a coverage loss -- see this module's own passing runs post-ISS-0073-fix as
    # confirmation the stricter schema still accepts every payload this file writes.
    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req062-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix \\ "req062-idk") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
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

  # A 2-step child: START -> HUMAN_TASK("work") -> END. Deliberately does NOT complete
  # synchronously at creation time -- every test needs to observe the parent's
  # waiting_child_instance_id/:waiting state, and independently drive the child's own
  # completion via a real Engine.complete_task/3 call.
  defp graph_child_two_step do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "work", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "worker"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "work"},
        %{"id" => "e2", "source" => "work", "target" => "end"}
      ]
    }
  end

  # START -> SUB_PROCESS("sp") -> END. sp's own attributes (definition_name, optionally
  # interface) are injected by each test via `sp_attributes`.
  defp graph_parent_subprocess_root(child_definition_name, interface \\ nil) do
    sp_attributes =
      case interface do
        nil -> %{"definition_name" => child_definition_name}
        iface -> %{"definition_name" => child_definition_name, "interface" => iface}
      end

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "sp", "node_type" => "SUB_PROCESS", "attributes" => sp_attributes},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sp"},
        %{"id" => "e2", "source" => "sp", "target" => "end"}
      ]
    }
  end

  # START -> SUB_PROCESS("sp") -> HUMAN_TASK("after") -> END -- used by AC5's set/clear
  # test, which needs a surviving parent token row to inspect post-completion (the
  # 2-node root-SUB_PROCESS graph above removes the token outright on :END).
  defp graph_parent_subprocess_then_task(child_definition_name, interface \\ nil) do
    sp_attributes =
      case interface do
        nil -> %{"definition_name" => child_definition_name}
        iface -> %{"definition_name" => child_definition_name, "interface" => iface}
      end

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "sp", "node_type" => "SUB_PROCESS", "attributes" => sp_attributes},
        %{"id" => "after", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "closer"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sp"},
        %{"id" => "e2", "source" => "sp", "target" => "after"},
        %{"id" => "e3", "source" => "after", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN_TASK("gate") -> SUB_PROCESS("sp") -> END -- used by the two
  # activation-time (input) failure-mode tests, which need the SUB_PROCESS node to be
  # reached via a task-completion hop chain (Engine.complete_task/3), not create/2's own
  # root-node path, so the failure has an already-persisted parent instance to route into
  # ExecutionError against (AC8) -- create/2's own root-SUB_PROCESS path has no persisted
  # parent yet for a failure there to attach to (design doc §3.3).
  defp graph_parent_task_then_subprocess(child_definition_name, interface) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gate", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "gater"}},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_definition_name, "interface" => interface}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gate"},
        %{"id" => "e2", "source" => "gate", "target" => "sp"},
        %{"id" => "e3", "source" => "sp", "target" => "end"}
      ]
    }
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

  defp child_projection!(schema_name, parent_instance_id) do
    InstanceProjection
    |> where([p], p.parent_instance_id == ^parent_instance_id)
    |> Repo.one!(prefix: schema_name)
  end

  defp child_projections(schema_name, parent_instance_id) do
    InstanceProjection
    |> where([p], p.parent_instance_id == ^parent_instance_id)
    |> Repo.all(prefix: schema_name)
  end

  defp instance_projection_count(schema_name) do
    Repo.aggregate(InstanceProjection, :count, :instance_id, prefix: schema_name)
  end

  defp pending_task_for_instance!(schema_name, instance_id) do
    EngineTask
    |> where([t], t.instance_id == ^instance_id and t.status == :pending)
    |> Repo.one!(prefix: schema_name)
  end

  defp sub_process_completed_events(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "SUB_PROCESS_COMPLETED")
    |> Repo.all(prefix: schema_name)
  end

  defp execution_error_events(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "EXECUTION_ERROR")
    |> Repo.all(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- filtered input, only the declared inputs reach the child
  # ---------------------------------------------------------------------------------

  describe "AC1 -- a declared interface filters the child's initial variables to ONLY the named inputs" do
    test "a parent variable not named in inputs is demonstrably absent from the child" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "inputs" => [%{"name" => "amount", "json_schema" => %{"type" => "number"}}]
      }

      parent_def =
        active_definition!(schema_name, graph_parent_subprocess_root(child_def.name, interface))

      attrs = start_attrs(parent_def, %{initial_variables: %{"amount" => 5, "secret" => "x"}})
      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)

      child = child_projection!(schema_name, result.instance_id)
      assert child.variables == %{"amount" => 5}
      refute Map.has_key?(child.variables, "secret")
      assert child.parent_instance_id == result.instance_id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- no declared interface -> full parent variable map copied (EXT-05)
  # ---------------------------------------------------------------------------------

  describe "AC2 -- a SUB_PROCESS node with no declared interface copies the full parent variable map" do
    test "the child's initial variables equal the parent's full initial_variables map" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())
      parent_def = active_definition!(schema_name, graph_parent_subprocess_root(child_def.name))

      initial_variables = %{"amount" => 5, "secret" => "x", "nested" => %{"a" => 1}}
      attrs = start_attrs(parent_def, %{initial_variables: initial_variables})
      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)

      child = child_projection!(schema_name, result.instance_id)
      assert child.variables == initial_variables
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- the two activation-time failure modes: ZERO child instances created, routed
  # through ExecutionError against the already-persisted parent (AC8), gate task stays
  # pending (no partial completion).
  # ---------------------------------------------------------------------------------

  describe "AC3/AC8 -- SUB_PROCESS_MISSING_REQUIRED_INPUT: zero children created, routed into set_instance_error" do
    test "the gate task's own completion is rejected: parent flips to :error, zero child instance rows, gate task stays pending" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "inputs" => [
          %{"name" => "amount", "required" => true, "json_schema" => %{"type" => "number"}}
        ]
      }

      parent_def =
        active_definition!(
          schema_name,
          graph_parent_task_then_subprocess(child_def.name, interface)
        )

      assert {:ok, created} = Engine.create(start_attrs(parent_def), prefix: schema_name)
      gate_task = pending_task_for_instance!(schema_name, created.instance_id)

      before_count = instance_projection_count(schema_name)

      # complete_task/3 itself returns {:error, {:instance_execution_error, ...}} directly
      # -- the same, single conversion every EE-10-routed complete_task/3 call goes
      # through (interpret_complete_result/1's leading clause, engine.ex:1916-1918;
      # mirrors AC4a's own shape/style, engine_execution_error_test.exs:410). There is no
      # code path that returns {:ok, %{instance_status: :error, ...}} -- complete_result()'s
      # own @spec restricts instance_status to :active | :completed, never :error.
      assert {:error,
              {:instance_execution_error, :subprocess_interface_violation, {:field, "amount"}}} =
               Engine.complete_task(gate_task.id, complete_attrs(), prefix: schema_name)

      projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert projection.status == :error
      assert projection.error_detail["error_type"] == "subprocess_interface_violation"
      assert projection.error_detail["details"]["code"] == "SUB_PROCESS_MISSING_REQUIRED_INPUT"

      # Zero child instances created -- structural, not a rollback (AC's own wording).
      assert instance_projection_count(schema_name) == before_count
      assert child_projections(schema_name, created.instance_id) == []

      # The gate task itself never completed -- "no partial merge" extends to "no
      # partial task completion" here too.
      still_pending = Repo.get!(EngineTask, gate_task.id, prefix: schema_name)
      assert still_pending.status == :pending

      assert [event] = execution_error_events(schema_name, created.instance_id)
      assert event.payload["error_type"] == "subprocess_interface_violation"
    end
  end

  describe "AC3/AC8 -- SUB_PROCESS_INPUT_SCHEMA_VIOLATION: zero children created, routed into set_instance_error" do
    test "a present input failing its own json_schema behaves identically to the missing-required case" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "inputs" => [%{"name" => "amount", "json_schema" => %{"type" => "number"}}]
      }

      parent_def =
        active_definition!(
          schema_name,
          graph_parent_task_then_subprocess(child_def.name, interface)
        )

      assert {:ok, created} =
               Engine.create(
                 start_attrs(parent_def, %{initial_variables: %{"amount" => "not-a-number"}}),
                 prefix: schema_name
               )

      gate_task = pending_task_for_instance!(schema_name, created.instance_id)

      # complete_task/3 itself returns {:error, {:instance_execution_error, ...}} directly
      # -- same shape/rationale as the SUB_PROCESS_MISSING_REQUIRED_INPUT case above
      # (mirrors AC4a's own shape/style, engine_execution_error_test.exs:410).
      assert {:error,
              {:instance_execution_error, :subprocess_interface_violation, {:field, "amount"}}} =
               Engine.complete_task(gate_task.id, complete_attrs(), prefix: schema_name)

      projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert projection.status == :error
      assert projection.error_detail["error_type"] == "subprocess_interface_violation"
      assert projection.error_detail["details"]["code"] == "SUB_PROCESS_INPUT_SCHEMA_VIOLATION"
      assert child_projections(schema_name, created.instance_id) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3/AC4/AC8 -- the two completion-time failure modes: the child already exists and
  # completes normally, but the parent's merge is rejected -- parent's own variable map
  # is left unmodified (no partial merge), routed into set_instance_error.
  # ---------------------------------------------------------------------------------

  describe "AC3/AC8 -- SUB_PROCESS_MISSING_REQUIRED_OUTPUT: parent's variables unmodified, routed into set_instance_error" do
    test "the child completes normally but the parent's own merge never applies" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "outputs" => [
          %{"name" => "result", "required" => true, "json_schema" => %{"type" => "boolean"}}
        ]
      }

      parent_def =
        active_definition!(
          schema_name,
          graph_parent_subprocess_root(child_def.name, interface)
        )

      parent_initial_variables = %{"seed" => 1}

      assert {:ok, created} =
               Engine.create(
                 start_attrs(parent_def, %{initial_variables: parent_initial_variables}),
                 prefix: schema_name
               )

      child = child_projection!(schema_name, created.instance_id)
      child_task = pending_task_for_instance!(schema_name, child.instance_id)

      # "result" deliberately omitted from the child's own output_variables.
      assert {:ok, child_result} =
               Engine.complete_task(child_task.id, complete_attrs(), prefix: schema_name)

      # The child itself completes successfully -- only the PARENT's own merge is
      # rejected; the two are not the same transaction's success/failure verdict.
      assert child_result.instance_status == :completed

      parent_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent_projection.status == :error
      assert parent_projection.variables == parent_initial_variables

      assert parent_projection.error_detail["details"]["code"] ==
               "SUB_PROCESS_MISSING_REQUIRED_OUTPUT"

      assert [event] = execution_error_events(schema_name, created.instance_id)
      assert event.payload["error_type"] == "subprocess_interface_violation"

      # No SUB_PROCESS_COMPLETED event on the parent's own stream -- the completion
      # event is only appended on the success path (design doc §3.4 point 4).
      assert sub_process_completed_events(schema_name, created.instance_id) == []
    end
  end

  describe "AC3/AC8 -- SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION: parent's variables unmodified, routed into set_instance_error" do
    test "a present output failing its own json_schema behaves identically to the missing-required-output case" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "outputs" => [%{"name" => "result", "json_schema" => %{"type" => "boolean"}}]
      }

      parent_def =
        active_definition!(
          schema_name,
          graph_parent_subprocess_root(child_def.name, interface)
        )

      parent_initial_variables = %{"seed" => 1}

      assert {:ok, created} =
               Engine.create(
                 start_attrs(parent_def, %{initial_variables: parent_initial_variables}),
                 prefix: schema_name
               )

      child = child_projection!(schema_name, created.instance_id)
      child_task = pending_task_for_instance!(schema_name, child.instance_id)

      output_attrs = complete_attrs(%{output_variables: %{"result" => "not-a-boolean"}})

      assert {:ok, child_result} =
               Engine.complete_task(child_task.id, output_attrs, prefix: schema_name)

      assert child_result.instance_status == :completed

      parent_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent_projection.status == :error
      assert parent_projection.variables == parent_initial_variables

      assert parent_projection.error_detail["details"]["code"] ==
               "SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- successful completion: only the named outputs merge into the parent
  # ---------------------------------------------------------------------------------

  describe "AC4 -- on child completion, only the named outputs merge into the parent" do
    test "a child variable not named in outputs is demonstrably absent from the parent afterwards" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "outputs" => [%{"name" => "result", "json_schema" => %{"type" => "boolean"}}]
      }

      parent_def =
        active_definition!(schema_name, graph_parent_subprocess_root(child_def.name, interface))

      assert {:ok, created} =
               Engine.create(
                 start_attrs(parent_def, %{initial_variables: %{"seed" => 1}}),
                 prefix: schema_name
               )

      child = child_projection!(schema_name, created.instance_id)
      child_task = pending_task_for_instance!(schema_name, child.instance_id)

      output_attrs =
        complete_attrs(%{output_variables: %{"result" => true, "junk" => "never merged"}})

      assert {:ok, _child_result} =
               Engine.complete_task(child_task.id, output_attrs, prefix: schema_name)

      parent_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent_projection.status == :completed
      assert parent_projection.variables == %{"seed" => 1, "result" => true}
      refute Map.has_key?(parent_projection.variables, "junk")

      assert [event] = sub_process_completed_events(schema_name, created.instance_id)
      assert event.payload["child_instance_id"] == child.instance_id
      assert event.payload["output_variables"] == %{"result" => true}
      refute Map.has_key?(event.payload["output_variables"], "junk")
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- waiting_child_instance_id set while the child runs, cleared on completion
  # ---------------------------------------------------------------------------------

  describe "AC5 -- the parent token's waiting_child_instance_id is set while the child runs and cleared on completion" do
    test "set at child-creation time, cleared once the child completes, token survives at its next node" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      parent_def =
        active_definition!(schema_name, graph_parent_subprocess_then_task(child_def.name))

      assert {:ok, created} = Engine.create(start_attrs(parent_def), prefix: schema_name)

      parent_token_while_running =
        TokenRecord
        |> where([t], t.instance_id == ^created.instance_id and t.status == :waiting)
        |> Repo.one!(prefix: schema_name)

      child = child_projection!(schema_name, created.instance_id)
      assert parent_token_while_running.waiting_child_instance_id == child.instance_id
      assert parent_token_while_running.node_id == "sp"

      child_task = pending_task_for_instance!(schema_name, child.instance_id)

      assert {:ok, _result} =
               Engine.complete_task(child_task.id, complete_attrs(), prefix: schema_name)

      parent_token_after =
        Repo.get!(TokenRecord, parent_token_while_running.id, prefix: schema_name)

      assert parent_token_after.waiting_child_instance_id == nil
      assert parent_token_after.status == :active
      assert parent_token_after.node_id == "after"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- child creation is not reachable through create/2's own public create_attrs()
  # shape (inspection: create_attrs() has no parent_instance_id key at all -- see
  # lib/letflow/engine.ex's @type create_attrs; functional half below).
  # ---------------------------------------------------------------------------------

  describe "AC6 -- child instance creation is not reachable through create/2's public path" do
    test "a caller-supplied parent_instance_id in attrs is silently ignored -- the created instance is never a child" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = active_definition!(schema_name, graph_child_two_step())

      # REQ-059 (merged into this branch after this test was originally
      # written) reads attrs[:parent_instance_id] for pin-inheritance lookup
      # (Letflow.Engine.PinResolver.reconstruct_effective_pins/2, design doc
      # §8/§9 OQ-4's own admittedly-speculative seam) -- a value that does not
      # resolve to a real instance now fails create/2 outright with
      # {:parent_pin_lookup_failed, :instance_not_found} before ever reaching
      # instance_projections insertion, which is a different failure mode
      # than the one this test exercises. Using a real (but otherwise
      # unrelated) instance's id keeps this test's actual invariant intact --
      # create/2's own insert_instance_projection/8 never reads
      # attrs[:parent_instance_id] to populate the parent_instance_id/
      # parent_token_id columns, regardless of whether pin resolution itself
      # consults that key for an unrelated purpose.
      unrelated_definition = active_definition!(schema_name, graph_child_two_step())

      assert {:ok, unrelated} =
               Engine.create(start_attrs(unrelated_definition), prefix: schema_name)

      forged_parent_id = unrelated.instance_id

      attrs =
        start_attrs(definition)
        |> Map.put(:parent_instance_id, forged_parent_id)
        |> Map.put("parent_instance_id", forged_parent_id)

      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.parent_instance_id == nil
      assert projection.parent_token_id == nil
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- cancelling a parent does not cancel its running child (EE-08)
  # ---------------------------------------------------------------------------------

  describe "AC7 -- cancelling a parent instance does not cancel its running child" do
    test "the child's own projection/task/token rows are completely unaffected by the parent's cancellation" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())
      parent_def = active_definition!(schema_name, graph_parent_subprocess_root(child_def.name))

      assert {:ok, created} = Engine.create(start_attrs(parent_def), prefix: schema_name)
      child = child_projection!(schema_name, created.instance_id)
      child_task = pending_task_for_instance!(schema_name, child.instance_id)

      cancel_attrs = %{
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("cancel")
      }

      assert {:ok, cancel_result} =
               Engine.cancel_instance(created.instance_id, cancel_attrs, prefix: schema_name)

      assert cancel_result.status == :cancelled

      parent_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent_projection.status == :cancelled

      # The child is entirely untouched: still active, its own task still pending.
      child_projection_after =
        Repo.get!(InstanceProjection, child.instance_id, prefix: schema_name)

      assert child_projection_after.status == :active

      child_task_after = Repo.get!(EngineTask, child_task.id, prefix: schema_name)
      assert child_task_after.status == :pending

      child_token =
        TokenRecord
        |> where([t], t.instance_id == ^child.instance_id)
        |> Repo.one!(prefix: schema_name)

      assert child_token.status == :active
    end
  end
end
