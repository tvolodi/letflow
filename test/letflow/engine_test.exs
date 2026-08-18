defmodule Letflow.EngineTest do
  @moduledoc """
  Tests for REQ-045's `Letflow.Engine.create/2` (EE-01 — instance start). See
  `test/specs/REQ-045.md` for the full test-case rationale, including the
  WF-02 Step 3 scope-test verdict.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. `create/2`'s entire
  algorithm is I/O (resolves a real `process_definitions` row, calls
  `SnapshotStore.create/3`, runs a real `Ecto.Multi` against
  `instance_projections`/`tokens`/`events`), so there is no meaningful pure-layer
  split the way `lib/letflow/engine/transition.ex` had.

  Mirrors `test/letflow/definitions/store_test.exs`'s and
  `test/letflow/definitions/snapshot_store_test.exs`'s established
  `provisioned_tenant/1` + Sandbox `:auto` + `async: false` pattern exactly --
  `Ecto.Migrator` needs a second real DB connection the sandbox can't hand out.

  Every fixture definition is created via `Definitions.create/2` +
  `Definitions.activate/2` (REQ-030), never a raw `Repo.insert!/2` -- so each test
  exercises `create/2` against a definition that genuinely passed REQ-028/029's
  structural/attribute validation, matching `store_test.exs`'s own discipline.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Engine.TokenRecord
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
        slug: "req045-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-045 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # Mirrors store_test.exs's/snapshot_store_test.exs's provisioned_tenant/1
  # exactly -- see this file's moduledoc for the full reasoning. Also replays
  # migrations via the real default manifest (not a caller-supplied one), which
  # is load-bearing here: it is what triggers
  # TenantProvisioning.maybe_seed_platform_event_types/2 to seed the
  # "INSTANCE_STARTED" event_type_registry row create/2's own event-append step
  # (M3) depends on (design doc §9 OQ-3a).
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

  defp unique_name(prefix \\ "req045-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> END directly. First non-START node is :END (design §9 OQ-1a's
  # second success case).
  defp graph_start_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  # START -> HUMAN_TASK("role": "approver") -> END. First non-START node is
  # :HUMAN_TASK.
  defp graph_start_human_task_end do
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

  # START -> EXCLUSIVE_GATEWAY -> END. First non-START node is
  # :EXCLUSIVE_GATEWAY -- now auto-advances via REQ-050's dispatch and
  # activate/3's own hop loop (design §9 OQ-1a, superseded).
  # is_default: true on the gateway's one outgoing edge so CHK-13/CHK-16 (which
  # would otherwise require a condition on a non-default gateway edge) don't
  # reject this fixture at Definitions.create/2 time -- this graph must itself
  # be structurally valid; the point under test is create/2's own dispatch
  # failure, not a REQ-029 validation failure.
  defp graph_start_gateway_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gw"},
        %{"id" => "e2", "source" => "gw", "target" => "end", "is_default" => true}
      ]
    }
  end

  defp create_definition_attrs(graph, overrides) do
    Map.merge(
      %{
        name: unique_name(),
        version: "1.0.0",
        graph: graph,
        created_by: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp active_definition!(schema_name, graph, overrides \\ %{}) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph, overrides), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp draft_definition!(schema_name, graph, overrides \\ %{}) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph, overrides), prefix: schema_name)

    definition
  end

  defp deprecated_definition!(schema_name, graph, overrides \\ %{}) do
    definition = active_definition!(schema_name, graph, overrides)
    assert {:ok, deprecated} = Definitions.deprecate(definition.id, prefix: schema_name)
    deprecated
  end

  defp archived_definition!(schema_name, graph, overrides \\ %{}) do
    definition = deprecated_definition!(schema_name, graph, overrides)
    assert {:ok, archived} = Definitions.archive(definition.id, prefix: schema_name)
    archived
  end

  defp base_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: "req045-#{System.unique_integer([:positive, :monotonic])}"
      },
      overrides
    )
  end

  defp projection_count(schema_name) do
    Repo.aggregate(InstanceProjection, :count, prefix: schema_name)
  end

  defp snapshot_count(schema_name) do
    Repo.aggregate(InstanceDefinitionSnapshot, :count, prefix: schema_name)
  end

  defp token_count(schema_name) do
    Repo.aggregate(TokenRecord, :count, prefix: schema_name)
  end

  defp event_count(schema_name) do
    %{rows: [[count]]} =
      Repo.query!(~s[SELECT COUNT(*) FROM "#{schema_name}"."events"], [])

    count
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1
  # ---------------------------------------------------------------------------------

  describe "create/2 (AC1) -- ACTIVE definition, HUMAN_TASK first node" do
    test "inserts instance_projections, tokens, and instance_definition_snapshots rows with the right shape" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition, %{initial_variables: %{"amount" => 42}})

      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)

      assert result.definition_id == definition.id
      assert result.status == :active
      assert result.current_nodes == ["task"]
      assert result.variables == %{"amount" => 42}
      assert %DateTime{} = result.started_at

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.status == :active
      assert projection.definition_id == definition.id
      assert projection.current_nodes == ["task"]
      assert projection.variables == %{"amount" => 42}

      assert token_count(schema_name) == 1
      [token] = Repo.all(TokenRecord, prefix: schema_name)
      assert token.instance_id == result.instance_id
      assert token.node_id == "task"
      assert token.branch_id == result.instance_id

      assert {:ok, snapshot} =
               Letflow.Definitions.SnapshotStore.get_by_instance_id(result.instance_id,
                 prefix: schema_name
               )

      assert snapshot.definition_id == definition.id
      assert snapshot_count(schema_name) == 1
    end

    test "the snapshot is written strictly before the INSTANCE_STARTED event -- a Multi failure leaves the snapshot as a surviving orphan, zero rows elsewhere" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      # A missing actor_id fails EventStore.append/2's own required-field guard
      # (M3 of this module's own Multi), forcing the whole Multi to roll back
      # while leaving the already-committed snapshot (a separate, earlier
      # transaction, design §5/§9 OQ-4) in place.
      attrs = base_attrs(definition) |> Map.delete(:actor_id)

      assert {:error, {:event_append_failed, :missing_actor_id}} =
               Engine.create(attrs, prefix: schema_name)

      assert projection_count(schema_name) == 0
      assert token_count(schema_name) == 0
      assert event_count(schema_name) == 0
      assert snapshot_count(schema_name) == 1
    end

    test "a definition whose first non-START node is :END completes in the same call" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_end())

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert result.current_nodes == []

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.status == :completed
      assert projection.current_nodes == []

      # REQ-044's own :END dispatch removes the token before this module's
      # persist/7 even builds the tokens insert -- no tokens row for this
      # instance at all, not a token stranded at "end".
      assert token_count(schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2
  # ---------------------------------------------------------------------------------

  describe "create/2 (AC2) -- non-ACTIVE definitions rejected, zero rows" do
    test "a DRAFT definition returns {:error, :definition_not_active} and writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = draft_definition!(schema_name, graph_start_human_task_end())

      assert {:error, :definition_not_active} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
      assert event_count(schema_name) == 0
    end

    test "a DEPRECATED definition returns {:error, :definition_not_active} and writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = deprecated_definition!(schema_name, graph_start_human_task_end())

      assert {:error, :definition_not_active} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
      assert event_count(schema_name) == 0
    end

    test "an ARCHIVED definition returns {:error, :definition_not_active} and writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = archived_definition!(schema_name, graph_start_human_task_end())

      assert {:error, :definition_not_active} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
      assert event_count(schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3 -- three explicit tests
  # ---------------------------------------------------------------------------------

  describe "create/2 (AC3) -- initial_variables: nil / list rejected, %{} accepted" do
    test "initial_variables: nil is rejected with {:error, :invalid_initial_variables}, writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition, %{initial_variables: nil})

      assert {:error, :invalid_initial_variables} = Engine.create(attrs, prefix: schema_name)
      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
    end

    test "initial_variables set to a list is rejected with {:error, :invalid_initial_variables}, writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition, %{initial_variables: ["not", "a", "map"]})

      assert {:error, :invalid_initial_variables} = Engine.create(attrs, prefix: schema_name)
      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
    end

    test "initial_variables: %{} (empty map) is accepted" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition, %{initial_variables: %{}})

      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)
      assert result.variables == %{}

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.variables == %{}
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4
  # ---------------------------------------------------------------------------------

  describe "create/2 (AC4) -- duplicate correlation_key rejected, nil correlation_key unconstrained" do
    test "a second create/2 with the same (definition_id, correlation_key) returns {:error, :duplicate_correlation_key} and writes no second row" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      correlation_key = "corr-#{System.unique_integer([:positive, :monotonic])}"

      attrs1 = base_attrs(definition, %{correlation_key: correlation_key})
      assert {:ok, _first} = Engine.create(attrs1, prefix: schema_name)
      assert projection_count(schema_name) == 1

      attrs2 = base_attrs(definition, %{correlation_key: correlation_key})

      assert {:error, :duplicate_correlation_key} = Engine.create(attrs2, prefix: schema_name)

      # No partial row from the rejected second call -- still exactly 1.
      assert projection_count(schema_name) == 1
      assert token_count(schema_name) == 1
    end

    test "two create/2 calls with correlation_key: nil both succeed" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      assert {:ok, first} =
               Engine.create(base_attrs(definition, %{correlation_key: nil}),
                 prefix: schema_name
               )

      assert {:ok, second} =
               Engine.create(base_attrs(definition, %{correlation_key: nil}),
                 prefix: schema_name
               )

      refute first.instance_id == second.instance_id
      assert projection_count(schema_name) == 2
    end
  end

  # ---------------------------------------------------------------------------------
  # Design §9 OQ-1a (superseded by REQ-050/051) -- gateways now auto-advance;
  # activate/3 loops to a stable resting state instead of assuming a fixed hop
  # count. See test/specs/REQ-045.md for the updated rationale.
  # ---------------------------------------------------------------------------------

  describe "design §9 OQ-1a (superseded) -- a definition whose first non-START node is a gateway now completes via the activation loop" do
    test "a definition whose first non-START node is :EXCLUSIVE_GATEWAY (default edge -> END) completes in the same call" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_gateway_end())

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert result.status == :completed
      assert result.current_nodes == []

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.status == :completed
      assert projection.current_nodes == []

      # REQ-044's own :END dispatch removes the token before persist/7 builds
      # the tokens insert -- no tokens row for this instance at all, matching
      # the START->END fixture's own assertion above.
      assert token_count(schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Disclosed limitation that genuinely remains today: node types no
  # dispatch clause implements yet (:SERVICE_TASK/:TIMER/:SUB_PROCESS).
  # ---------------------------------------------------------------------------------

  describe "a definition whose first non-START node is a type with no dispatch clause yet fails create/2 entirely" do
    test "returns {:error, {:activation_failed, {:node_type_not_yet_implemented, :SERVICE_TASK, _}}}, writing zero rows except the benign snapshot orphan" do
      %{schema_name: schema_name} = provisioned_tenant()

      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "svc",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"endpoint" => "https://example.test/svc", "timeout_ms" => 5000}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "svc"},
          %{"id" => "e2", "source" => "svc", "target" => "end"}
        ]
      }

      definition = active_definition!(schema_name, graph)

      assert {:error,
              {:activation_failed, {:node_type_not_yet_implemented, :SERVICE_TASK, "svc"}}} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert projection_count(schema_name) == 0
      assert token_count(schema_name) == 0
      assert event_count(schema_name) == 0

      # Same benign snapshot-orphan exception as before (design §5 step 7 /
      # §9 OQ-4): the snapshot call runs -- and commits -- before the pure
      # activate/3 dispatch that fails.
      assert snapshot_count(schema_name) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # OQ-3b / INV-8 -- actor_id/idempotency_key missing-value behavior
  # ---------------------------------------------------------------------------------

  describe "actor_id/idempotency_key missing-value behavior (OQ-3b, INV-8)" do
    test "missing :actor_id returns {:error, {:event_append_failed, :missing_actor_id}}, never raises" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition) |> Map.delete(:actor_id)

      assert {:error, {:event_append_failed, :missing_actor_id}} =
               Engine.create(attrs, prefix: schema_name)
    end

    test "missing :idempotency_key returns {:error, {:event_append_failed, :missing_idempotency_key}}, never raises" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition) |> Map.delete(:idempotency_key)

      assert {:error, {:event_append_failed, :missing_idempotency_key}} =
               Engine.create(attrs, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criteria 5, 6, 7 -- moduledoc content assertions
  # ---------------------------------------------------------------------------------

  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  describe "AC5 -- moduledoc states which module is superseded vs. generalized, and TransitionEvent's disposition" do
    test "states process_instance.ex is superseded, not extended, and points to REQ-046 for its actual removal" do
      doc = normalized_moduledoc(Engine)

      assert doc =~ "process_instance.ex` is **superseded, not extended**"
      assert doc =~ "REQ-046 owns physically removing it"
    end

    test "states instance_supervisor.ex is generalized, not superseded, and untouched by this requirement" do
      doc = normalized_moduledoc(Engine)

      assert doc =~ "instance_supervisor.ex` is **generalized, not superseded**"
      assert doc =~ "`Letflow.Engine` does not modify `instance_supervisor.ex` at all"
    end

    test "states TransitionEvent is deliberately kept, not retired by this requirement" do
      doc = normalized_moduledoc(Engine)

      assert doc =~
               "TransitionEvent` (and its migration) is **deliberately kept in place, not retired by this requirement.**"
    end
  end

  describe "AC6 -- moduledoc names the process-vs-row open question, cites the stage doc, leaves later engine subsystems to their own decision" do
    test "names the question as this stage's largest open design question and cites stage-3-instance-engine.md's second Early finding" do
      doc = normalized_moduledoc(Engine)

      assert doc =~
               "was this stage's largest open design question"

      assert doc =~ "stage-3-instance-engine.md`'s second Early"
    end

    test "states this module resolves it for EE-01's own scope only, and does not pre-empt REQ-056/REQ-057's own decision" do
      doc = normalized_moduledoc(Engine)

      assert doc =~ "resolves it for EE-01's own scope only"
      assert doc =~ "does not pre-empt those requirements' own decisions"
    end
  end

  describe "AC7 -- moduledoc states POST /api/v1/instances is S4 scope, this module builds a context-module function only" do
    test "states the HTTP route belongs to S4 and this module returns tagged tuples only" do
      doc = normalized_moduledoc(Engine)

      assert doc =~ "POST /api/v1/instances` and every other HTTP route belong to S4"
      assert doc =~ "this module builds a context-module function only"
    end
  end
end
