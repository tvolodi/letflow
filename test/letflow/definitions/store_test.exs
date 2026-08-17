defmodule Letflow.Definitions.StoreTest do
  @moduledoc """
  Tests for REQ-030's `Letflow.Definitions` CRUD functions: `create/2`, `get_by_id/2`,
  `get_active_by_name/2`, `list/2`, `activate/2`, `deprecate/2`, `archive/2`. See
  `test/specs/REQ-030.md` for the full test-case rationale, including the AC5
  9-vs-4-forbidden-cells reconciliation this file follows.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file.

  ## Why this is a separate file from `test/letflow/definitions_test.exs`

  `definitions_test.exs` (REQ-041) is `async: true` and deliberately pure -- no `Repo`
  connection, no tenant provisioning. Every one of REQ-030's 7 functions does real I/O
  against a real tenant schema's `process_definitions` table, so none of this file's
  coverage belongs there. This mirrors the split already established for this same
  context module: `pack_update_migration_test.exs` (DB-backed, GLOBAL tables, plain
  `Letflow.DataCase` sandbox) and `snapshot_store_test.exs`
  (DB-backed, per-tenant-schema tables, `provisioned_tenant/1` + Sandbox `:auto`) both
  live under `test/letflow/definitions/`, not folded into the top-level
  `definitions_test.exs`. `process_definitions` is a per-tenant-schema table (REQ-027),
  so this file follows `snapshot_store_test.exs`'s pattern, not
  `pack_update_migration_test.exs`'s GLOBAL-table one.

  Two pure, doc-content checks for AC6 (the `service_scope_validator` hook is
  documented in the moduledoc) and part of AC9 (the tenant_id-derivation contract is
  documented) live in `definitions_test.exs` instead, alongside REQ-041's own
  moduledoc-content tests -- consistent with that file's existing
  `normalized_moduledoc/1` pattern, no DB needed for a doc-content assertion.

  ## Fixture strategy -- read before adding a test here

  Mirrors `test/letflow/definitions/snapshot_store_test.exs`'s and
  `test/letflow/event_store_test.exs`'s established `provisioned_tenant/1` pattern
  exactly: each test provisions its own tenant (real `CREATE SCHEMA` via
  `TenantProvisioning.provision_tenant_schema/1`, real
  `TenantProvisioning.replay_migrations/2`, which includes REQ-027's
  `process_definitions` migration). `Ecto.Migrator` needs a second real DB connection
  the sandbox can't hand out, hence Sandbox `:auto` mode and manual `on_exit/1` cleanup
  instead of the normal rolled-back transaction. `async: false` for the whole module --
  required for the same reason those two files are `async: false`: the `:auto`-mode
  switch is only safe because ExUnit fully drains every `async: true` module before
  running any `async: false` module, and runs `async: false` modules one at a time.

  Every test provisions its own tenant and uses `unique_name/1`
  (`System.unique_integer/1`-suffixed) for every definition `name` and a fresh
  `Ecto.UUID.generate()` for every `created_by` -- no shared or hard-coded identifiers,
  no test depends on another test's data or on execution order, no wall-clock
  dependency anywhere (`docs/guides/test_developer_guide.md` §1's determinism rule).

  ## Fixture graphs

  `valid_graph/0` is the minimal graph that passes all three of `Graph.validate_graph/1`,
  `.validate_node_attributes/1` and `.validate_edge_conditions/1`: one START node with
  an outgoing edge to one END node with an incoming edge -- satisfies CHK-01/02 (exactly
  one START, at least one END) and CHK-04 (START only needs outgoing, END only needs
  incoming), no dangling/duplicate/cyclic structure, and carries no node types or edge
  conditions that CHK-09..17 would flag. The other `graph_*` fixtures each deliberately
  fail exactly one specific check, confirmed by direct reading of `graph.ex`'s check
  implementations (not guessed), so each AC1-adjacent test proves the *specific* pipeline
  phase (`validate_graph/1` vs `validate_node_attributes/1` vs `validate_edge_conditions/1`)
  that rejects it, per the design doc's §0/§4.1 note that REQ-030's own
  `requirements.yaml` text names only one of REQ-029's two validators by name and the
  design closes that gap explicitly (P8/P9).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ProcessDefinition
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
        slug: "req030-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-030 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # Mirrors snapshot_store_test.exs's/event_store_test.exs's provisioned_tenant/1
  # exactly -- see this file's moduledoc for the full reasoning.
  defp provisioned_tenant(_context \\ %{}) do
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

  defp unique_name(prefix \\ "req030-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # Minimal structurally-valid graph -- see moduledoc "Fixture graphs".
  defp valid_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  # Fails CHK-02 (missing_end_node) AND CHK-04 (the lone START node is isolated --
  # no outgoing edge) -- validate_graph/1's own phase (P7), never reaches P8/P9.
  defp graph_missing_end_node do
    %{"nodes" => [%{"id" => "start", "node_type" => "START"}], "edges" => []}
  end

  # Structurally valid (passes validate_graph/1: one START, one END, the HUMAN_TASK
  # node has both incoming and outgoing edges so CHK-04 doesn't fire) but the
  # HUMAN_TASK node carries no "role" attribute -- CHK-09 (validate_node_attributes/1,
  # P8) fires :missing_role.
  defp graph_missing_human_task_role do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # Structurally valid, no node-attribute problem (only START/END, no
  # HUMAN_TASK/SERVICE_TASK/TIMER), but the START->END edge (non-gateway-sourced)
  # carries a non-null "condition" -- CHK-14 (validate_edge_conditions/1, P9) fires
  # :unexpected_edge_condition.
  defp graph_with_unexpected_edge_condition do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "end", "condition" => "some_condition"}
      ]
    }
  end

  @structural_violation_codes [
    :missing_start_node,
    :multiple_start_nodes,
    :missing_end_node,
    :dangling_edge,
    :isolated_node,
    :duplicate_node_id,
    :cycle_without_gateway,
    :node_limit_exceeded,
    :edge_limit_exceeded
  ]

  defp create_attrs(overrides) do
    Map.merge(
      %{
        name: unique_name(),
        version: "1.0.0",
        graph: valid_graph(),
        created_by: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp create!(schema_name, overrides \\ %{}) do
    assert {:ok, definition} = Definitions.create(create_attrs(overrides), prefix: schema_name)
    definition
  end

  defp activate!(schema_name, id, opts \\ []) do
    assert {:ok, result} = Definitions.activate(id, Keyword.merge([prefix: schema_name], opts))
    result.definition
  end

  defp deprecate!(schema_name, id) do
    assert {:ok, definition} = Definitions.deprecate(id, prefix: schema_name)
    definition
  end

  defp archive!(schema_name, id) do
    assert {:ok, definition} = Definitions.archive(id, prefix: schema_name)
    definition
  end

  defp active!(schema_name, overrides \\ %{}) do
    definition = create!(schema_name, overrides)
    activate!(schema_name, definition.id)
  end

  defp deprecated!(schema_name, overrides \\ %{}) do
    definition = active!(schema_name, overrides)
    deprecate!(schema_name, definition.id)
  end

  defp archived!(schema_name, overrides \\ %{}) do
    definition = deprecated!(schema_name, overrides)
    archive!(schema_name, definition.id)
  end

  defp reread!(schema_name, id) do
    Repo.get!(ProcessDefinition, id, prefix: schema_name)
  end

  defp count_by_name(schema_name, name) do
    ProcessDefinition
    |> where([d], d.name == ^name)
    |> Repo.aggregate(:count, prefix: schema_name)
  end

  defp count_active_by_name(schema_name, name) do
    ProcessDefinition
    |> where([d], d.name == ^name and d.status == :active)
    |> Repo.aggregate(:count, prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "create/1 with a graph that fails REQ-028's
  # validateGraph() writes zero rows and returns the collected violations, not a
  # generic error" -- plus the design doc's explicit note that validate_node_attributes/1
  # and validate_edge_conditions/1 (REQ-029, P8/P9) must ALSO gate create/2, not only
  # validate_graph/1.
  # ---------------------------------------------------------------------------------

  describe "create/2 (AC1) -- graph validation failure writes zero rows" do
    test "a graph missing an END node (validate_graph/1, P7) is rejected with {:error, {:graph_validation_failed, violations}} and writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      name = unique_name("ac1-missing-end")

      assert {:error, {:graph_validation_failed, violations}} =
               Definitions.create(
                 create_attrs(%{name: name, graph: graph_missing_end_node()}),
                 prefix: schema_name
               )

      assert is_list(violations)
      assert violations != []

      assert Enum.any?(violations, &(&1.code == :missing_end_node)),
             "expected a :missing_end_node violation, got: #{inspect(violations)}"

      assert count_by_name(schema_name, name) == 0
    end

    test "a structurally-valid graph with a HUMAN_TASK missing 'role' (validate_node_attributes/1, P8) is rejected and writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      name = unique_name("ac1-missing-role")

      assert {:error, {:graph_validation_failed, violations}} =
               Definitions.create(
                 create_attrs(%{name: name, graph: graph_missing_human_task_role()}),
                 prefix: schema_name
               )

      assert Enum.any?(violations, &(&1.code == :missing_role)),
             "expected a :missing_role violation, got: #{inspect(violations)}"

      # No structural violation fired -- proves validate_graph/1 (P7) passed and it
      # was specifically validate_node_attributes/1 (P8) that rejected this graph,
      # not a coincidental structural failure.
      refute Enum.any?(violations, &(&1.code in @structural_violation_codes)),
             "expected no structural violation, got: #{inspect(violations)}"

      assert count_by_name(schema_name, name) == 0
    end

    test "a structurally-valid graph with an unexpected non-gateway edge condition (validate_edge_conditions/1, P9) is rejected and writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      name = unique_name("ac1-unexpected-condition")

      assert {:error, {:graph_validation_failed, violations}} =
               Definitions.create(
                 create_attrs(%{name: name, graph: graph_with_unexpected_edge_condition()}),
                 prefix: schema_name
               )

      assert Enum.any?(violations, &(&1.code == :unexpected_edge_condition)),
             "expected an :unexpected_edge_condition violation, got: #{inspect(violations)}"

      refute Enum.any?(violations, &(&1.code in @structural_violation_codes)),
             "expected no structural violation, got: #{inspect(violations)}"

      assert count_by_name(schema_name, name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2: "two concurrent create/1 calls with identical
  # (name, version) result in exactly one success and one duplicate-error" -- a real
  # concurrent test (Task.async, real Postgres via Sandbox :auto mode), not merely
  # citing the ON CONFLICT code path.
  # ---------------------------------------------------------------------------------

  describe "create/2 (AC2) -- concurrent identical (name, version) creates" do
    test "exactly one succeeds, the other gets :duplicate_name_version, exactly one row lands" do
      %{schema_name: schema_name} = provisioned_tenant()
      name = unique_name("ac2-race")
      attrs = create_attrs(%{name: name, version: "1.0.0"})

      task1 = Task.async(fn -> Definitions.create(attrs, prefix: schema_name) end)
      task2 = Task.async(fn -> Definitions.create(attrs, prefix: schema_name) end)

      [result1, result2] = Task.await_many([task1, task2], 15_000)
      results = [result1, result2]

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      duplicate_errors = Enum.filter(results, &(&1 == {:error, :duplicate_name_version}))

      assert length(successes) == 1,
             "expected exactly one success out of two concurrent identical creates, got: #{inspect(results)}"

      assert length(duplicate_errors) == 1,
             "expected exactly one :duplicate_name_version error, got: #{inspect(results)}"

      assert count_by_name(schema_name, name) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 9: "a row written by create/1 has tenant_id equal to the
  # tenant whose schema the write targeted, derived internally -- not equal to a
  # caller-supplied tenant_id when the two are deliberately made to disagree in a
  # test, which must fail loudly (not silently attribute to the wrong tenant) rather
  # than succeed."
  # ---------------------------------------------------------------------------------

  describe "create/2 (AC9) -- tenant_id always derived internally, never caller-supplied" do
    test "a created row's tenant_id equals the tenant whose schema was written into" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      definition = create!(schema_name)

      assert definition.tenant_id == tenant_id
      assert reread!(schema_name, definition.id).tenant_id == tenant_id
    end

    test "a disagreeing atom :tenant_id key is rejected with :tenant_id_not_accepted, writes zero rows" do
      %{schema_name: schema_name, tenant_id: real_tenant_id} = provisioned_tenant()
      other_tenant_id = Ecto.UUID.generate()
      refute other_tenant_id == real_tenant_id

      name = unique_name("ac9-atom-key")
      attrs = create_attrs(%{name: name, tenant_id: other_tenant_id})

      assert {:error, :tenant_id_not_accepted} = Definitions.create(attrs, prefix: schema_name)
      assert count_by_name(schema_name, name) == 0
    end

    test "attrs containing a string \"tenant_id\" key is also rejected with {:error, :tenant_id_not_accepted}, and writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      other_tenant_id = Ecto.UUID.generate()
      name = unique_name("ac9-string-key")
      attrs = Map.put(create_attrs(%{name: name}), "tenant_id", other_tenant_id)

      assert {:error, :tenant_id_not_accepted} = Definitions.create(attrs, prefix: schema_name)
      assert count_by_name(schema_name, name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "activate/1 on a DRAFT definition atomically deprecates
  # any prior ACTIVE version of the same name in the same transaction, verified by
  # reading both rows after the call."
  # ---------------------------------------------------------------------------------

  describe "activate/2 (AC3) -- deprecates prior ACTIVE of the same name atomically" do
    test "a second DRAFT activation deprecates the first ACTIVE version, both rows re-read from Postgres" do
      %{schema_name: schema_name} = provisioned_tenant()
      name = unique_name("ac3-shared-name")

      definition_1 = create!(schema_name, %{name: name, version: "1.0.0"})
      assert %{status: :active} = activate!(schema_name, definition_1.id)

      definition_2 = create!(schema_name, %{name: name, version: "2.0.0"})
      assert %{status: :active} = activate!(schema_name, definition_2.id)

      reread_1 = reread!(schema_name, definition_1.id)
      reread_2 = reread!(schema_name, definition_2.id)

      assert reread_1.status == :deprecated
      assert reread_2.status == :active
      assert count_active_by_name(schema_name, name) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4: "activate/1 called twice on the same already-ACTIVE
  # definition returns the no-op/AlreadyActive result both times, never an error."
  # ---------------------------------------------------------------------------------

  describe "activate/2 (AC4) -- idempotent no-op on ACTIVE, never an error" do
    test "calling activate/2 repeatedly on an already-ACTIVE definition always returns the AlreadyActive no-op, never an error" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = create!(schema_name)

      assert {:ok, %{already_active: false, definition: %{status: :active}}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert {:ok, %{already_active: true, definition: %{status: :active}}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert {:ok, %{already_active: true, definition: %{status: :active}}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert count_active_by_name(schema_name, definition.name) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 5: every one of the 9 forbidden-transition cells in
  # definition.md's authoritative state transition table (design doc §6.1) is
  # tested and rejected -- NOT the 4 requirements.yaml's own AC5 text names.
  # CODE-DESIGN-VALIDATOR and SECURITY-REVIEWER both independently confirmed the
  # real table has 9 off-diagonal forbidden (X) cells:
  #
  #   DRAFT->DEPRECATED, DRAFT->ARCHIVED, ACTIVE->DRAFT, ACTIVE->ARCHIVED,
  #   DEPRECATED->DRAFT, DEPRECATED->ACTIVE, ARCHIVED->DRAFT, ARCHIVED->ACTIVE,
  #   ARCHIVED->DEPRECATED
  #
  # Six of these are directly attemptable by calling the "wrong" function against a
  # row in the wrong status (a single {:error, _} assertion each). The remaining
  # three (X->DRAFT) have NO function in this module's public API that ever sets an
  # existing row's status back to :draft -- create/2 is the only writer of :draft,
  # and it only ever INSERTs a fresh row (design doc INV-DS-4, "by construction, not
  # by enumeration"). Those three cells are each tested by driving a row to the
  # relevant starting status and confirming NONE of activate/2, deprecate/2, or
  # archive/2 ever produces status :draft -- the strongest statement obtainable
  # about a transition target with no direct code path to attempt it. Each of the 9
  # cells below is its own explicit test, not a generic loop over a list.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- all 9 forbidden-transition cells, tested individually" do
    test "cell DRAFT -> DEPRECATED: deprecate/2 on a DRAFT row returns {:error, :invalid_status_transition}, status unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = create!(schema_name)

      assert {:error, :invalid_status_transition} =
               Definitions.deprecate(definition.id, prefix: schema_name)

      assert reread!(schema_name, definition.id).status == :draft
    end

    test "cell DRAFT -> ARCHIVED: archive/2 on a DRAFT row returns {:error, :invalid_status_transition}, status unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = create!(schema_name)

      assert {:error, :invalid_status_transition} =
               Definitions.archive(definition.id, prefix: schema_name)

      assert reread!(schema_name, definition.id).status == :draft
    end

    test "cell ACTIVE -> DRAFT: activate/2, deprecate/2, archive/2 on an ACTIVE row never yield status :draft" do
      %{schema_name: schema_name} = provisioned_tenant()

      active_1 = active!(schema_name)
      active_2 = active!(schema_name)
      active_3 = active!(schema_name)

      # activate/2 on ACTIVE: AC4 no-op, stays :active.
      assert {:ok, %{already_active: true}} = Definitions.activate(active_1.id, prefix: schema_name)
      assert reread!(schema_name, active_1.id).status != :draft

      # deprecate/2 on ACTIVE: the one legal edge from ACTIVE, becomes :deprecated.
      assert {:ok, %{status: :deprecated}} = Definitions.deprecate(active_2.id, prefix: schema_name)
      assert reread!(schema_name, active_2.id).status != :draft

      # archive/2 on ACTIVE: forbidden (cell ACTIVE -> ARCHIVED, tested below too).
      assert {:error, :invalid_status_transition} =
               Definitions.archive(active_3.id, prefix: schema_name)

      assert reread!(schema_name, active_3.id).status != :draft
    end

    test "cell ACTIVE -> ARCHIVED: archive/2 on an ACTIVE row returns {:error, :invalid_status_transition}, status unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active!(schema_name)

      assert {:error, :invalid_status_transition} =
               Definitions.archive(definition.id, prefix: schema_name)

      assert reread!(schema_name, definition.id).status == :active
    end

    test "cell DEPRECATED -> DRAFT: activate/2, deprecate/2, archive/2 on a DEPRECATED row never yield status :draft" do
      %{schema_name: schema_name} = provisioned_tenant()

      deprecated_1 = deprecated!(schema_name)
      deprecated_2 = deprecated!(schema_name)
      deprecated_3 = deprecated!(schema_name)

      # activate/2 on DEPRECATED: forbidden (cell DEPRECATED -> ACTIVE, tested below too).
      assert {:error, :not_draft} = Definitions.activate(deprecated_1.id, prefix: schema_name)
      assert reread!(schema_name, deprecated_1.id).status != :draft

      # deprecate/2 on DEPRECATED (self): also forbidden, bonus coverage beyond the
      # 9 off-diagonal cells, folded into this fixture rather than a separate test.
      assert {:error, :invalid_status_transition} =
               Definitions.deprecate(deprecated_2.id, prefix: schema_name)

      assert reread!(schema_name, deprecated_2.id).status != :draft

      # archive/2 on DEPRECATED: the one legal edge from DEPRECATED, becomes :archived.
      assert {:ok, %{status: :archived}} = Definitions.archive(deprecated_3.id, prefix: schema_name)
      assert reread!(schema_name, deprecated_3.id).status != :draft
    end

    test "cell DEPRECATED -> ACTIVE: activate/2 on a DEPRECATED row returns {:error, :not_draft}, status unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = deprecated!(schema_name)

      assert {:error, :not_draft} = Definitions.activate(definition.id, prefix: schema_name)
      assert reread!(schema_name, definition.id).status == :deprecated
    end

    test "cell ARCHIVED -> DRAFT: activate/2, deprecate/2, archive/2 on an ARCHIVED (terminal) row never yield status :draft" do
      %{schema_name: schema_name} = provisioned_tenant()

      archived_1 = archived!(schema_name)
      archived_2 = archived!(schema_name)
      archived_3 = archived!(schema_name)

      assert {:error, :not_draft} = Definitions.activate(archived_1.id, prefix: schema_name)
      assert reread!(schema_name, archived_1.id).status != :draft

      assert {:error, :invalid_status_transition} =
               Definitions.deprecate(archived_2.id, prefix: schema_name)

      assert reread!(schema_name, archived_2.id).status != :draft

      # archive/2 on ARCHIVED (self): also forbidden, bonus coverage as above.
      assert {:error, :invalid_status_transition} =
               Definitions.archive(archived_3.id, prefix: schema_name)

      assert reread!(schema_name, archived_3.id).status != :draft
    end

    test "cell ARCHIVED -> ACTIVE: activate/2 on an ARCHIVED row returns {:error, :not_draft}, status unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = archived!(schema_name)

      assert {:error, :not_draft} = Definitions.activate(definition.id, prefix: schema_name)
      assert reread!(schema_name, definition.id).status == :archived
    end

    test "cell ARCHIVED -> DEPRECATED: deprecate/2 on an ARCHIVED row returns {:error, :invalid_status_transition}, status unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = archived!(schema_name)

      assert {:error, :invalid_status_transition} =
               Definitions.deprecate(definition.id, prefix: schema_name)

      assert reread!(schema_name, definition.id).status == :archived
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 6: "activate/1's signature includes a nil-able/optional
  # service-scope-validation hook parameter that REQ-031 wires in" -- the hook is a
  # real parameter now, so both its :ok and {:error, reason} outcomes must actually
  # take effect (design doc §6.2 step 6, §7).
  # ---------------------------------------------------------------------------------

  describe "activate/2 (AC6) -- service_scope_validator hook takes effect" do
    test "a hook returning :ok lets activation proceed and is called with the graph and tenant_id" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      definition = create!(schema_name)
      test_pid = self()

      validator = fn graph, hook_tenant_id ->
        send(test_pid, {:hook_called, graph, hook_tenant_id})
        :ok
      end

      assert {:ok, %{already_active: false, definition: %{status: :active}}} =
               Definitions.activate(definition.id,
                 prefix: schema_name,
                 service_scope_validator: validator
               )

      assert_receive {:hook_called, %Graph{} = graph, ^tenant_id}
      assert Enum.any?(graph.nodes, &(&1.node_type == :START))
      refute_received {:hook_called, _graph, _tenant_id}
    end

    test "a hook returning {:error, reason} aborts activation as {:service_scope_violation, reason}, stays DRAFT" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = create!(schema_name)

      validator = fn _graph, _tenant_id -> {:error, :service_not_registered} end

      assert {:error, {:service_scope_violation, :service_not_registered}} =
               Definitions.activate(definition.id,
                 prefix: schema_name,
                 service_scope_validator: validator
               )

      assert reread!(schema_name, definition.id).status == :draft
      assert count_active_by_name(schema_name, definition.name) == 0
    end

    test "the hook is never called on the already-ACTIVE no-op path" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = create!(schema_name)
      assert {:ok, %{already_active: false}} = Definitions.activate(definition.id, prefix: schema_name)

      exploding_validator = fn _graph, _tenant_id ->
        raise "hook must not be called on the already-active no-op path"
      end

      assert {:ok, %{already_active: true}} =
               Definitions.activate(definition.id,
                 prefix: schema_name,
                 service_scope_validator: exploding_validator
               )
    end

    test "the hook is never called on a rejected non-draft transition" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = deprecated!(schema_name)

      exploding_validator = fn _graph, _tenant_id ->
        raise "hook must not be called on a rejected non-draft transition"
      end

      assert {:error, :not_draft} =
               Definitions.activate(definition.id,
                 prefix: schema_name,
                 service_scope_validator: exploding_validator
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 7: "get_active_by_name/1 against a name with an ACTIVE
  # version returns that definition; against a name with only DRAFT/DEPRECATED/
  # ARCHIVED versions (no ACTIVE row) returns a not-found error, not the most
  # recent non-active row."
  # ---------------------------------------------------------------------------------

  describe "get_active_by_name/2 (AC7)" do
    test "a name with an ACTIVE version returns that definition" do
      %{schema_name: schema_name} = provisioned_tenant()
      name = unique_name("ac7-active")
      definition = create!(schema_name, %{name: name})
      activate!(schema_name, definition.id)

      assert {:ok, found} = Definitions.get_active_by_name(name, prefix: schema_name)
      assert found.id == definition.id
      assert found.status == :active
    end

    test "a name with only a DRAFT version (never activated) returns {:error, :not_found}" do
      %{schema_name: schema_name} = provisioned_tenant()
      name = unique_name("ac7-draft-only")
      create!(schema_name, %{name: name})

      assert {:error, :not_found} = Definitions.get_active_by_name(name, prefix: schema_name)
    end

    test "a name whose only version was activated then deprecated returns {:error, :not_found} -- never the most recent non-active row" do
      %{schema_name: schema_name} = provisioned_tenant()
      name = unique_name("ac7-deprecated-only")
      definition = deprecated!(schema_name, %{name: name})

      # Sanity: the deprecated row genuinely exists and is the only row for this
      # name -- so a buggy fallback-to-most-recent implementation would have
      # something to wrongly return here.
      assert reread!(schema_name, definition.id).status == :deprecated
      assert count_by_name(schema_name, name) == 1

      assert {:error, :not_found} = Definitions.get_active_by_name(name, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 8: "list/1 with a stage filter returns only rows whose
  # stage column exactly matches the filter value, combinable with a simultaneous
  # name and/or status filter in the same call."
  # ---------------------------------------------------------------------------------

  describe "list/2 (AC8) -- stage filter exact-match, combinable with other filters" do
    test "stage filter matches exactly, excludes a longer same-prefix stage, combines via AND" do
      %{schema_name: schema_name} = provisioned_tenant()
      base_name = unique_name("ac8")

      prod_draft = create!(schema_name, %{name: base_name <> "-prod-draft", stage: "prod"})
      prod_active = create!(schema_name, %{name: base_name <> "-prod-active", stage: "prod"})
      activate!(schema_name, prod_active.id)
      production_draft = create!(schema_name, %{name: base_name <> "-production-draft", stage: "production"})
      no_stage_draft = create!(schema_name, %{name: base_name <> "-no-stage"})

      # stage alone: exact match. "prod" must not also match "production" -- if it
      # did (e.g. an accidental ILIKE/substring implementation), this assertion
      # catches it.
      assert {:ok, results} = Definitions.list(%{stage: "prod"}, prefix: schema_name)
      result_ids = MapSet.new(results, & &1.id)

      assert MapSet.member?(result_ids, prod_draft.id)
      assert MapSet.member?(result_ids, prod_active.id)

      refute MapSet.member?(result_ids, production_draft.id),
             "stage filter 'prod' matched 'production' -- exact-match contract violated"

      refute MapSet.member?(result_ids, no_stage_draft.id)

      # stage + status combined in the same call (AND).
      assert {:ok, [only]} = Definitions.list(%{stage: "prod", status: :active}, prefix: schema_name)
      assert only.id == prod_active.id

      # stage + name + status combined in the same call (AND, all three at once).
      assert {:ok, [only_named]} =
               Definitions.list(
                 %{stage: "prod", status: :draft, name: prod_draft.name},
                 prefix: schema_name
               )

      assert only_named.id == prod_draft.id
    end
  end

  # ---------------------------------------------------------------------------------
  # Regression coverage (not one of the 9 numbered acceptance criteria): design doc
  # §6.2's documented "genuine cross-row race" and SECURITY-REVIEWER's filed,
  # REVIEWER-accepted, non-blocking finding -- activate/2's TOCTOU between two
  # DIFFERENT DRAFT rows sharing the same `name`, activated concurrently. Cheap to
  # demonstrate given AC2's test already exercises the same Task.async machinery.
  # ---------------------------------------------------------------------------------

  describe "Regression -- activate/2 cross-row TOCTOU (design doc §6.2)" do
    # Note: kept short deliberately -- ExUnit derives a compiled function name
    # (atom) from "test " <> describe-name <> " " <> test-name, and Erlang atoms
    # are capped at 255 bytes. The full rationale lives in the comments above
    # and in test/specs/REQ-030.md, not in this string.
    test "concurrent activation of two DRAFT rows sharing a name never yields a double-ACTIVE state" do
      %{schema_name: schema_name} = provisioned_tenant()
      name = unique_name("toctou")

      definition_1 = create!(schema_name, %{name: name, version: "1.0.0"})
      definition_2 = create!(schema_name, %{name: name, version: "2.0.0"})

      task1 = Task.async(fn -> Definitions.activate(definition_1.id, prefix: schema_name) end)
      task2 = Task.async(fn -> Definitions.activate(definition_2.id, prefix: schema_name) end)

      [result1, result2] = Task.await_many([task1, task2], 15_000)

      # Every outcome must be either a real success or the documented
      # {:transaction_failed, _} fallback (design doc §6.2's "genuine cross-row
      # race" note and §4.0's TransactionFailed catch-all) -- never a silent,
      # differently-shaped error, and never a raised exception escaping the test.
      for result <- [result1, result2] do
        assert match?({:ok, %{already_active: false}}, result) or
                 match?({:error, {:transaction_failed, _reason}}, result),
               "unexpected activate/2 outcome under the race: #{inspect(result)}"
      end

      # The core safety invariant, regardless of exactly which interleaving occurred
      # (inherently timing-dependent, per the design doc's own note that this
      # ports R-Co's identical unhandled-race fallback): at most one row is ever
      # ACTIVE for this name -- never a corrupted double-ACTIVE state.
      assert count_active_by_name(schema_name, name) == 1
    end
  end
end
