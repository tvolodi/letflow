defmodule Letflow.Definitions.ExportImportTest do
  @moduledoc """
  Tests for REQ-034's `Letflow.Definitions.ExportImport`: `export/2`, `import/3`. See
  `test/specs/REQ-034.md` for the full test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. `export/2` reads and
  `import/3` writes (via `Letflow.Definitions.create/2`) real `process_definitions`
  rows in real per-tenant schemas, so this belongs alongside
  `test/letflow/definitions/store_test.exs`, not the pure `definitions_test.exs`.

  ## Fixture strategy -- mirrors `store_test.exs` exactly

  Each test provisions its own tenant (real `CREATE SCHEMA` via
  `TenantProvisioning.provision_tenant_schema/1`, real
  `TenantProvisioning.replay_migrations/2`). `Ecto.Adapters.SQL.Sandbox` is switched to
  `:auto` mode because `Ecto.Migrator` needs its own real DB connection the sandbox
  can't hand out -- same reasoning as `store_test.exs`'s and `snapshot_store_test.exs`'s
  own moduledocs. `async: false` for the whole module for the same reason.

  Every test uses `unique_name/1` (`System.unique_integer/1`-suffixed) for every
  definition `name` and a fresh `Ecto.UUID.generate()` for every `created_by`/
  `imported_by` -- no shared or hard-coded identifiers, no test depends on another
  test's data or on execution order, no wall-clock dependency anywhere.

  Per REVIEWER's Step 2d non-blocking note (recorded in this run's handoff chain): the
  two `create_error()` variants structurally unreachable through `import/3`'s own
  `create_attrs()` builder (`:tenant_id_not_accepted`, `:initial_status_not_draft` --
  `import/3` never includes a `:tenant_id` or `:status` key) are deliberately NOT
  covered here -- there is no code path by which `import/3` could ever produce either,
  so a test asserting against them would be manufactured, not real coverage.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.ExportImport
  alias Letflow.Definitions.ExportImport.ExportDocument
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- mirrors store_test.exs's provisioned_tenant/1 exactly.
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req034"),
        display_name: "REQ-034 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

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

  defp unique_name(prefix \\ "req034-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # Minimal structurally-valid graph, same shape as store_test.exs's valid_graph/0.
  defp valid_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  # A richer, structurally-valid graph -- one HUMAN_TASK node carrying a nested
  # "attributes" map with the required "role" key AND an extra, unrelated "note" key
  # (proving the round-trip preserves the FULL nested map, not just the keys graph.ex
  # itself happens to read). Used by AC1's round-trip test.
  defp graph_with_task_and_extra_metadata do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "label" => "Review",
          "attributes" => %{
            "role" => "approver",
            "note" => "round-trip fidelity check, unrelated to any validator"
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # Fails validate_graph/1 (P7, CHK-02 :missing_end_node) -- same fixture shape as
  # store_test.exs's graph_missing_end_node/0. Used by AC3's no-bypass test.
  defp graph_missing_end_node do
    %{"nodes" => [%{"id" => "start", "node_type" => "START"}], "edges" => []}
  end

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

  defp export!(schema_name, id) do
    assert {:ok, document} = ExportImport.export(id, prefix: schema_name)
    document
  end

  defp reread!(schema_name, id) do
    Repo.get!(ProcessDefinition, id, prefix: schema_name)
  end

  defp count_by_name(schema_name, name) do
    ProcessDefinition
    |> where([d], d.name == ^name)
    |> Repo.aggregate(:count, prefix: schema_name)
  end

  defp count_by_id(schema_name, id) do
    ProcessDefinition
    |> where([d], d.id == ^id)
    |> Repo.aggregate(:count, prefix: schema_name)
  end

  # Inserts a row directly (bypassing create/2) with a CALLER-CHOSEN id -- used only
  # by AC2's collision test, to construct the "source id already exists as a
  # definition in the target tenant" precondition. `ProcessDefinition`'s
  # `@primary_key {:id, :binary_id, autogenerate: true}` only autogenerates when the
  # struct's `:id` field is nil at insert time (confirmed by direct reading,
  # `lib/letflow/definitions/process_definition.ex`) -- a pre-set non-nil `:id` on the
  # struct passed into the changeset is preserved verbatim through `Repo.insert!/2`.
  defp insert_row_with_id!(schema_name, id, overrides) do
    attrs =
      Map.merge(
        %{
          name: unique_name("req034-collision"),
          version: "9.9.9",
          graph: valid_graph(),
          created_by: Ecto.UUID.generate()
        },
        overrides
      )

    %ProcessDefinition{id: id}
    |> ProcessDefinition.create_changeset(attrs)
    |> Repo.insert!(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC1: "export/1 on an existing definition produces a document whose graph field
  # round-trips byte-for-byte comparable back through import/1's graph field."
  # ---------------------------------------------------------------------------------

  describe "export/2 + import/3 (AC1) -- graph round-trips byte-for-byte" do
    test "the source row's graph, export/2's document graph, and the imported row's re-read graph are all structurally equal" do
      %{schema_name: source_schema} = provisioned_tenant()
      %{schema_name: target_schema} = provisioned_tenant()

      graph = graph_with_task_and_extra_metadata()
      source_definition = create!(source_schema, %{graph: graph})

      # Sanity: create/2 itself wrote back exactly what was passed in.
      assert source_definition.graph == graph

      document = export!(source_schema, source_definition.id)

      # export/2 passes the graph through unmodified (INV-EI-3).
      assert document.graph == graph

      imported_by = Ecto.UUID.generate()

      assert {:ok, imported} = ExportImport.import(document, imported_by, prefix: target_schema)

      # import/3's in-memory return value.
      assert imported.graph == graph

      # The persisted row, re-read from Postgres directly -- proves fidelity survives
      # the jsonb encode/decode round trip too, not merely the in-memory struct chain.
      assert reread!(target_schema, imported.id).graph == graph
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2: "import/1 always assigns a new id distinct from the source document's id
  # field, even when the source id happens to already exist as a definition in the
  # target tenant."
  # ---------------------------------------------------------------------------------

  describe "import/3 (AC2) -- always assigns a fresh id, distinct from document.id" do
    test "the imported row's id differs from the exported document's id (basic case, different tenant)" do
      %{schema_name: source_schema} = provisioned_tenant()
      %{schema_name: target_schema} = provisioned_tenant()

      source_definition = create!(source_schema)
      document = export!(source_schema, source_definition.id)

      assert document.id == source_definition.id

      assert {:ok, imported} =
               ExportImport.import(document, Ecto.UUID.generate(), prefix: target_schema)

      refute imported.id == document.id
    end

    test "the imported row's id differs from document.id even when document.id already exists as a definition in the target tenant, and the pre-existing row is left untouched" do
      %{schema_name: source_schema} = provisioned_tenant()
      source_definition = create!(source_schema)
      document = export!(source_schema, source_definition.id)

      %{schema_name: target_schema} = provisioned_tenant()

      # Deliberately construct the collision precondition: a row already exists in
      # the TARGET tenant whose id is exactly document.id (source's id), under an
      # unrelated name/version so the import below can't fail on the unrelated
      # uq_definition_version constraint instead.
      collision_row =
        insert_row_with_id!(target_schema, document.id, %{
          name: unique_name("req034-ac2-pre-existing"),
          version: "9.9.9"
        })

      assert collision_row.id == document.id
      assert count_by_id(target_schema, document.id) == 1

      imported_by = Ecto.UUID.generate()

      assert {:ok, imported} = ExportImport.import(document, imported_by, prefix: target_schema)

      refute imported.id == document.id,
             "import/3 must never assign the source document's id as the imported row's id"

      # The pre-existing collision row was NOT overwritten -- still exactly one row
      # under document.id, and it's still the original pre-existing row's content.
      assert count_by_id(target_schema, document.id) == 1
      reread_collision = reread!(target_schema, document.id)
      assert reread_collision.name == collision_row.name
      assert reread_collision.version == collision_row.version

      # The imported row landed under its own, freshly-assigned id, with the
      # SOURCE document's name/graph -- a distinct row, not a merge/overwrite.
      reread_imported = reread!(target_schema, imported.id)
      assert reread_imported.name == document.name
      assert reread_imported.graph == document.graph
      refute reread_imported.id == reread_collision.id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3: "import/1 on a document with a graph that fails REQ-028's validateGraph() is
  # rejected the same way REQ-030's create/1 rejects an invalid graph directly -- no
  # bypass path."
  # ---------------------------------------------------------------------------------

  describe "import/3 (AC3) -- an invalid graph is rejected identically to a direct create/2 call, no bypass" do
    test "import/3 and a direct create/2 call built from the same attrs return the identical rejection, both write zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      imported_by = Ecto.UUID.generate()

      document = %ExportDocument{
        bpm_export_schema_version: "bpm/definition/v1",
        id: Ecto.UUID.generate(),
        name: unique_name("req034-ac3"),
        version: "1.0.0",
        description: nil,
        graph: graph_missing_end_node(),
        exported_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      # Mirrors import/3's own create_attrs() construction exactly (design doc §4.3
      # step I1) -- the direct call this test compares against is not an arbitrary
      # hand-built create/2 call, it's what import/3 itself would build.
      direct_attrs = %{
        name: document.name,
        version: document.version,
        description: document.description,
        graph: document.graph,
        created_by: imported_by
      }

      import_result = ExportImport.import(document, imported_by, prefix: schema_name)
      direct_result = Definitions.create(direct_attrs, prefix: schema_name)

      assert {:error, {:graph_validation_failed, import_violations}} = import_result
      assert {:error, {:graph_validation_failed, direct_violations}} = direct_result

      assert Enum.any?(import_violations, &(&1.code == :missing_end_node))

      assert import_violations == direct_violations,
             "import/3's rejection must be identical to create/2's -- no separate, " <>
               "potentially-diverging validation path (INV-EI-2). import: " <>
               "#{inspect(import_violations)}, direct: #{inspect(direct_violations)}"

      assert import_result == direct_result

      assert count_by_name(schema_name, document.name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4: "import/1 on a document whose bpm_export_schema_version is not
  # 'bpm/definition/v1' is rejected with a distinct unknown-schema-version error."
  # ---------------------------------------------------------------------------------

  describe "import/3 (AC4) -- a schema-version mismatch is rejected with a distinct unknown-schema-version error" do
    test "an otherwise-fully-valid document with a mismatched schema version is rejected distinctly, not as a create_error(), writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()

      # Deliberately an otherwise-VALID document (valid graph, valid name/version) --
      # proves the rejection is specifically the schema-version gate (I0, runs before
      # create/2 is ever reached), not an incidental graph/attribute failure that
      # would produce a create_error() shape instead.
      document = %ExportDocument{
        bpm_export_schema_version: "bpm/definition/v0",
        id: Ecto.UUID.generate(),
        name: unique_name("req034-ac4"),
        version: "1.0.0",
        description: nil,
        graph: valid_graph(),
        exported_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      result = ExportImport.import(document, Ecto.UUID.generate(), prefix: schema_name)

      assert result == {:error, {:unknown_schema_version, "bpm/definition/v0"}}

      # Structurally distinct from every create_error() variant -- in particular not
      # {:error, {:graph_validation_failed, _}}, which is what this same, otherwise-
      # valid document would need to fail with if the schema-version gate were
      # silently skipped and create/2 were reached instead.
      refute match?({:error, {:graph_validation_failed, _}}, result)

      assert count_by_name(schema_name, document.name) == 0
    end
  end
end
