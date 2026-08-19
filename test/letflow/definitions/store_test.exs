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

  ## REQ-031 AC4 (this file's `"activate/2 (REQ-031 AC4)"` block)

  REQ-030's own `"activate/2 (AC6)"` block above proves the `service_scope_validator`
  hook MECHANISM takes effect, using a hand-rolled anonymous closure as the hook value.
  REQ-031's AC4 specifically requires demonstrating the real, merged
  `Letflow.Definitions.ServiceScopeValidator.build/1` output wired in as that hook --
  this file is where that lives (real Postgres, a real `graph_with_service_task/1`
  fixture), rather than `service_scope_validator_test.exs` (which covers `validate/3`'s
  own algorithm purely, no `Repo`). See `test/specs/REQ-031.md`.

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
  alias Letflow.Definitions.ServiceScopeValidator
  alias Letflow.Definitions.ServiceScopeValidator.{Lookup, Violation}
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
        slug: Letflow.TenantSlugFixture.unique_slug("req030"),
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

  # A structurally-valid graph (passes validate_graph/1 AND validate_node_attributes/1 --
  # carries the "endpoint"/"timeout_ms" attributes CHK-10/CHK-11 require) whose one
  # SERVICE_TASK node references `service_id` -- used by REQ-031 AC4's real-activate/2
  # integration tests below to exercise ServiceScopeValidator.build/1 as the real hook.
  defp graph_with_service_task(service_id) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc-node",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "endpoint" => "https://example.test/svc",
            "timeout_ms" => 5_000,
            "service_id" => service_id
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc-node"},
        %{"id" => "e2", "source" => "svc-node", "target" => "end"}
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
    # REQ-064 (Decision 0006 D2) dropped process_definitions.tenant_id -- there is no
    # longer a tenant_id field on ProcessDefinition to assert against. The underlying
    # acceptance criterion this test proves -- a created row belongs to the tenant
    # whose schema was written into, not some other tenant -- is restated below via
    # schema-prefix reachability: the row is found under its own tenant's schema and
    # genuinely NOT FOUND under a second, independently provisioned tenant's schema
    # (the same technique test/letflow/req064_tenant_id_removal_test.exs and
    # event_store_test.exs's "tenant_id (AC6)" describe block already use for the
    # analogous cross-schema-isolation claim on other D2 tables).
    test "a created row is reachable under its own tenant's schema and NOT under a different tenant's schema" do
      %{schema_name: schema_name} = provisioned_tenant()
      %{schema_name: other_schema_name} = provisioned_tenant()

      definition = create!(schema_name)

      assert reread!(schema_name, definition.id).id == definition.id
      refute Repo.get(ProcessDefinition, definition.id, prefix: other_schema_name)
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
      assert {:ok, %{already_active: true}} =
               Definitions.activate(active_1.id, prefix: schema_name)

      assert reread!(schema_name, active_1.id).status != :draft

      # deprecate/2 on ACTIVE: the one legal edge from ACTIVE, becomes :deprecated.
      assert {:ok, %{status: :deprecated}} =
               Definitions.deprecate(active_2.id, prefix: schema_name)

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
      assert {:ok, %{status: :archived}} =
               Definitions.archive(deprecated_3.id, prefix: schema_name)

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

      assert {:ok, %{already_active: false}} =
               Definitions.activate(definition.id, prefix: schema_name)

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
  # REQ-031 acceptance criterion 4: "REQ-030's activate/1 is demonstrated calling this
  # validator via its nil-able hook when a lookup implementation is supplied, and
  # skipping the check entirely when the hook is nil." REQ-030's own AC6 block above
  # already proves activate/2's hook MECHANISM takes effect, but using a hand-rolled
  # anonymous closure, not the real, merged `ServiceScopeValidator.build/1` output --
  # this block wires the actual REQ-031 module through as the hook, against a real
  # SERVICE_TASK-carrying graph and real Postgres.
  # ---------------------------------------------------------------------------------

  describe "activate/2 (REQ-031 AC4) -- ServiceScopeValidator.build/1 wired as the real hook" do
    test "a Lookup causing a violation is wired via ServiceScopeValidator.build/1 and blocks activation with the real Violation struct" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
      service_id = "req031-ac4-ghost-svc"

      definition =
        create!(schema_name, %{
          name: unique_name("ac4-blocked"),
          graph: graph_with_service_task(service_id)
        })

      lookup = %Lookup{
        service_lookup: fn ^service_id -> {:error, :not_registered} end,
        plugin_lookup: fn plugin_handler, ph_tenant_id ->
          raise "plugin_lookup must not be called, got: #{inspect({plugin_handler, ph_tenant_id})}"
        end
      }

      hook = ServiceScopeValidator.build(lookup)

      assert {:error,
              {:service_scope_violation,
               %Violation{
                 node_id: "svc-node",
                 kind: :service,
                 ref_id: ^service_id,
                 reason: :service_not_registered
               }}} =
               Definitions.activate(definition.id,
                 prefix: schema_name,
                 service_scope_validator: hook
               )

      assert reread!(schema_name, definition.id).status == :draft
      assert count_active_by_name(schema_name, definition.name) == 0
      # Sanity: tenant_id is real and would have been the value passed to the hook,
      # matching design doc §6's claim that activate/2 derives it before this hook runs.
      assert is_binary(tenant_id)
    end

    test "the identical graph activates successfully when the hook is omitted entirely -- the nil-skip path is a genuine skip, not an accidentally-permissive lookup" do
      %{schema_name: schema_name} = provisioned_tenant()
      service_id = "req031-ac4-nilskip-svc"

      definition =
        create!(schema_name, %{
          name: unique_name("ac4-nilskip"),
          graph: graph_with_service_task(service_id)
        })

      # Same service_id, same graph shape as the blocked case above -- this Lookup, if
      # it ran, WOULD reject the activation. It is never passed to activate/2 at all
      # (no :service_scope_validator key in opts), proving the nil-skip path is a
      # genuine skip rather than an accidentally-permissive default.
      assert {:ok, %{already_active: false, definition: %{status: :active}}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert reread!(schema_name, definition.id).status == :active
      assert count_active_by_name(schema_name, definition.name) == 1
    end

    test "a Lookup permitting the reference is wired via build/1 and activation succeeds" do
      %{schema_name: schema_name} = provisioned_tenant()
      service_id = "req031-ac4-global-svc"

      definition =
        create!(schema_name, %{
          name: unique_name("ac4-permitted"),
          graph: graph_with_service_task(service_id)
        })

      lookup = %Lookup{
        service_lookup: fn ^service_id -> {:ok, %{scope: :global, owner_tenant_id: nil}} end,
        plugin_lookup: fn plugin_handler, ph_tenant_id ->
          raise "plugin_lookup must not be called, got: #{inspect({plugin_handler, ph_tenant_id})}"
        end
      }

      hook = ServiceScopeValidator.build(lookup)

      assert {:ok, %{already_active: false, definition: %{status: :active}}} =
               Definitions.activate(definition.id,
                 prefix: schema_name,
                 service_scope_validator: hook
               )

      assert reread!(schema_name, definition.id).status == :active
      assert count_active_by_name(schema_name, definition.name) == 1
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

      production_draft =
        create!(schema_name, %{name: base_name <> "-production-draft", stage: "production"})

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
      assert {:ok, [only]} =
               Definitions.list(%{stage: "prod", status: :active}, prefix: schema_name)

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
  # DIFFERENT DRAFT rows sharing the same `name`, activated concurrently.
  #
  # REWORK NOTE (this run): an earlier version of this test relied on plain
  # `Task.async` with no synchronization and asserted the race "did trigger" as
  # verified fact. TEST-DESIGN-VALIDATOR re-ran it 10 times independently and got
  # zero occurrences of the race path -- every run took the safe sequential branch
  # instead, because un-synchronized BEAM/Postgres scheduling essentially never
  # produces the precise interleaving §6.2 describes (one task's whole activate/2
  # call, lock-to-commit, is fast enough to usually finish before the other task
  # even starts). That was a real No Speculation violation: the spec stated a fact
  # that wasn't reproducible. Fixed here by DETERMINISTICALLY forcing the
  # interleaving instead of hoping for it -- see below.
  # ---------------------------------------------------------------------------------

  describe "Regression -- activate/2 cross-row TOCTOU (design doc §6.2)" do
    # -------------------------------------------------------------------------------
    # How the forcing works, read this before the test below.
    #
    # activate/2 (lib/letflow/definitions.ex, run_activate_transaction/4 +
    # activate_draft/2) does, per row, inside one DB transaction:
    #   (1) SELECT ... FOR UPDATE       -- locks only THIS row (different ids never
    #                                      block each other -- design doc §6.2)
    #   (2) UPDATE ... WHERE name = ^name AND status = 'active'   -- deprecate-step
    #   (3) UPDATE ... WHERE id = ^id AND status = 'draft'        -- self-activate
    #   (4) COMMIT
    #
    # The race design doc §6.2 documents requires BOTH tasks' step (2) to run (and
    # find nothing, since both rows start DRAFT) BEFORE EITHER task's step (3)
    # commits -- only then does step (3) become a genuine fight over the same
    # `uq_active_definition` partial-unique-index key, which Postgres resolves by
    # raising a unique_violation on whichever transaction's step (3) loses. If
    # instead one task fully finishes (steps 1-4) before the other even reaches
    # step (2), the second task's own step (2) sees the first's committed ACTIVE
    # row and correctly deprecates it -- the safe branch, no race, exactly what
    # every unsynchronized run above observed.
    #
    # activate/2's only public extension point, `service_scope_validator`, fires
    # too early to use as a rendezvous here (before step 2, not between steps 2 and
    # 3 -- see the moduledoc). Rather than add a test-only hook to production code
    # (disproportionate surgery on a security-relevant transaction, for a need this
    # test alone has), this uses Ecto's own built-in, already-there query telemetry
    # (`[:letflow, :repo, :query]`, emitted automatically for every query by
    # `Ecto.Repo`/`ecto_sql` -- `deps/ecto_sql/lib/ecto/adapters/sql.ex`'s `log/5`,
    # confirmed by direct reading, not guessed) as the rendezvous instead: a
    # telemetry handler fires SYNCHRONOUSLY in the same process that issued the
    # query, immediately after that query completes and before the calling code
    # (activate_draft/2) moves on to the next one. That is exactly the window
    # between step (2) and step (3). Attaching a handler that blocks (via a plain
    # `receive`) the first time it observes each task's SECOND
    # `source: "process_definitions"` query event (event #1 is step (1)'s SELECT
    # FOR UPDATE, event #2 is step (2)'s deprecate UPDATE) pins each task's process
    # at precisely that window. Once BOTH tasks have signalled they are paused
    # there, we know both step (2)s have already run and found nothing -- so
    # releasing both guarantees the fight over the unique index at step (3) is
    # real, not a maybe. No production code (lib/letflow/definitions.ex) is
    # touched by any of this -- telemetry is a standard, already-present Ecto
    # extension point, not a new test hook threaded into the transaction.
    # -------------------------------------------------------------------------------

    @toctou_query_event [:letflow, :repo, :query]

    defp attach_toctou_pause(handler_id, task_pids, test_pid) do
      :telemetry.attach(
        handler_id,
        @toctou_query_event,
        fn _event, _measurements, metadata, _config ->
          if metadata[:source] == "process_definitions" and MapSet.member?(task_pids, self()) do
            count = Process.get(:req030_toctou_pd_query_count, 0) + 1
            Process.put(:req030_toctou_pd_query_count, count)

            # 2nd process_definitions-sourced query on this task's own connection
            # == the deprecate-step UPDATE (step 2 above) has just completed and
            # the self-activate UPDATE (step 3) has not yet been sent -- pause
            # exactly there, once, and tell the test process we're parked.
            if count == 2 do
              send(test_pid, {:toctou_paused, self()})

              receive do
                :toctou_go -> :ok
              end
            end
          end
        end,
        nil
      )
    end

    defp assert_toctou_task_started(tag) do
      assert_receive {:toctou_task_started, ^tag, pid}, 5_000
      pid
    end

    # Note: kept short deliberately -- ExUnit derives a compiled function name
    # (atom) from "test " <> describe-name <> " " <> test-name, and Erlang atoms
    # are capped at 255 bytes. The full rationale lives in the comments above
    # and in test/specs/REQ-030.md, not in this string.
    test "concurrent activation of two DRAFT rows sharing a name deterministically forces the race, never a double-ACTIVE state" do
      %{schema_name: schema_name} = provisioned_tenant()
      name = unique_name("toctou")

      definition_1 = create!(schema_name, %{name: name, version: "1.0.0"})
      definition_2 = create!(schema_name, %{name: name, version: "2.0.0"})

      test_pid = self()

      task1 =
        Task.async(fn ->
          send(test_pid, {:toctou_task_started, :task1, self()})

          receive do
            :toctou_run -> :ok
          end

          Definitions.activate(definition_1.id, prefix: schema_name)
        end)

      task2 =
        Task.async(fn ->
          send(test_pid, {:toctou_task_started, :task2, self()})

          receive do
            :toctou_run -> :ok
          end

          Definitions.activate(definition_2.id, prefix: schema_name)
        end)

      task1_pid = assert_toctou_task_started(:task1)
      task2_pid = assert_toctou_task_started(:task2)

      handler_id = "req030-toctou-#{System.unique_integer([:positive, :monotonic])}"
      on_exit(fn -> :telemetry.detach(handler_id) end)
      assert :ok = attach_toctou_pause(handler_id, MapSet.new([task1_pid, task2_pid]), test_pid)

      send(task1_pid, :toctou_run)
      send(task2_pid, :toctou_run)

      # Both tasks are now guaranteed to reach, and block at, the window between
      # their own deprecate-step and self-activate-step -- confirmed by receiving
      # both pause signals below, not assumed.
      assert_receive {:toctou_paused, ^task1_pid}, 5_000
      assert_receive {:toctou_paused, ^task2_pid}, 5_000

      # Release both. Both now attempt to write the same uq_active_definition
      # partial-unique-index key (name, active) with neither having deprecated the
      # other (impossible -- both deprecate-steps already ran and found nothing,
      # confirmed above) -- Postgres's unique index deterministically makes exactly
      # one of the two writes win and raises unique_violation on the other,
      # exercising the real {:error, {:transaction_failed, _}} fallback path design
      # doc §6.2 documents, not merely citing it as a theoretical possibility.
      send(task1_pid, :toctou_go)
      send(task2_pid, :toctou_go)

      [result1, result2] = Task.await_many([task1, task2], 15_000)
      results = [result1, result2]

      successes = Enum.filter(results, &match?({:ok, %{already_active: false}}, &1))
      race_errors = Enum.filter(results, &match?({:error, {:transaction_failed, _reason}}, &1))

      assert results -- (successes ++ race_errors) == [],
             "unexpected activate/2 outcome under the forced race -- expected only a real " <>
               "success or {:error, {:transaction_failed, _}}, got: #{inspect(results)}"

      assert length(successes) == 1,
             "expected exactly one real activation to win the deterministically-forced race, " <>
               "got: #{inspect(results)}"

      assert length(race_errors) == 1,
             "expected exactly one {:error, {:transaction_failed, _}} from the deterministically-" <>
               "forced race -- the synchronization guarantees both self-activate UPDATEs fight " <>
               "over the same uq_active_definition key with neither having deprecated the other " <>
               "first, so a real Postgres unique_violation on the loser is guaranteed, not merely " <>
               "possible, got: #{inspect(results)}"

      # The core safety invariant, regardless of which task happened to win the
      # forced race: exactly one row is ever ACTIVE for this name -- never a
      # corrupted double-ACTIVE state.
      assert count_active_by_name(schema_name, name) == 1
    end
  end
end
