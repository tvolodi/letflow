defmodule Letflow.Definitions.SolutionPackTest do
  @moduledoc """
  Tests for REQ-304 (`lib/letflow/design/req304-solution-pack-entity-definitions-export.md`,
  `docs/migration/decisions/0026-solution-pack-entity-definitions-section.md`) --
  the `entity_definitions` section added to `Letflow.Definitions.SolutionPack`'s
  export path (`export/4`, `pack_each_entity_definition/2`, `pack_entity_definition/1`).
  See `test/specs/REQ-304.md` for the acceptance-criterion-to-test-case mapping.

  Context-module level (not router level, unlike
  `test/letflow/routers/req078_supporting_routes_test.exs`'s solution-pack coverage):
  0026/REQ-304's own scope fence leaves `lib/letflow/routers/solution_packs.ex`
  untouched, so there is no HTTP surface yet for `export/4` or the
  `entity_definition_names` parameter -- the only way to exercise this behavior is
  to call `Letflow.Definitions.SolutionPack.export/3` and `.export/4` directly.

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture` for real provisioned tenant schemas,
  mirroring `req078_supporting_routes_test.exs`'s own fixture conventions.
  `async: false` -- same reasoning as that file (tenant provisioning/migration
  replay needs `Sandbox.mode(Letflow.Repo, :auto)`).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.SolutionPack
  alias Letflow.Entities.Definitions, as: EntityDefinitions
  alias Letflow.TenantFixture

  # ── Shared helpers ─────────────────────────────────────────────────────────

  defp unique(prefix),
    do: prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))

  # Process-definition fixture -- mirrors req078_supporting_routes_test.exs's own
  # graph_start_end/0 + create_definition_attrs/2 + active_definition!/2 pattern,
  # trimmed to what this file needs (a definition whose id can be named to
  # export/3's `definition_ids`).
  defp graph_start_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp active_process_definition!(schema_name) do
    attrs = %{
      name: unique("req304-pd"),
      version: "1.0.0",
      graph: graph_start_end(),
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Letflow.Definitions.create(attrs, prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Letflow.Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # Entity-definition fixture -- same field shape as
  # test/letflow/entities/definitions_test.exs's valid_definition/1, generated
  # under a fresh, name-format-legal (`^[a-z][a-z0-9_]{0,63}$`) unique name per
  # call so tests don't collide with each other (DIRECTIVE 4, no test pollution).
  defp valid_entity_definition(overrides \\ %{}) do
    Map.merge(
      %{
        name: unique("req304_entity"),
        display_name: "REQ-304 Entity Fixture",
        fields: [
          %{name: "email", type: :string, required: true, queried: true}
        ]
      },
      overrides
    )
  end

  defp create_entity_definition!(schema_name, overrides \\ %{}) do
    attrs = %{definition: valid_entity_definition(overrides), created_by: Ecto.UUID.generate()}

    assert {:ok, entity_definition} = EntityDefinitions.create_definition(attrs, schema_name)
    entity_definition
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC5 -- export/3 (old arity) is byte-for-byte unchanged, entity_definitions: []
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC5: export/3 is unchanged and always carries entity_definitions: []" do
    test "process-definitions-only export/3 call still succeeds, with entity_definitions: [] and no other regression" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac5")
      definition = active_process_definition!(tenant.schema_name)

      assert {:ok, doc} =
               SolutionPack.export([definition.id], "1.0.0", prefix: tenant.schema_name)

      # Every pre-existing key/shape is untouched -- this is what makes AC5
      # "byte-for-byte compatible" true, not just "still returns 200-shaped
      # data": the exact same assertions req078_supporting_routes_test.exs's
      # AC1 "POST /solution-packs/export" test makes against the route-layer
      # equivalent, plus the new key.
      assert Map.keys(doc) |> Enum.sort() ==
               Enum.sort([
                 :pack_id,
                 :version,
                 :bpm_export_schema_version,
                 :exported_at,
                 :definitions,
                 :service_catalog_entries,
                 :variable_schemas,
                 :entity_definitions,
                 :manifest
               ])

      expected_id = definition.id
      assert [%{definition_id: ^expected_id}] = doc.definitions
      assert doc.service_catalog_entries == []
      assert doc.variable_schemas == []
      assert doc.manifest == %{required_roles: []}

      # The new key: always present, empty when nothing was named.
      assert doc.entity_definitions == []
    end

    test "export/3 with zero definition_ids is still {:error, :empty_definition_ids} (unchanged)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac5-empty")

      assert SolutionPack.export([], "1.0.0", prefix: tenant.schema_name) ==
               {:error, :empty_definition_ids}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC1/AC2 -- pack_document's entity_definitions key, packed_entity_definition
  # shape, real data round-tripped through export/4
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC1/AC2: export/4 packs a named entity definition with the designed shape" do
    test "naming one real entity definition returns it under entity_definitions with name/display_name/definition_json (+ id/logical_shape_version)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac2")
      created = create_entity_definition!(tenant.schema_name)

      # Re-fetch the same row the way export/4 itself will (through
      # get_definition_by_name/2) rather than comparing against the
      # just-inserted, in-memory `created` struct: `definition_json` is a
      # jsonb column, and Ecto's :map type round-trips it through Postgres
      # with STRING keys on read, whereas the atom-keyed map handed to
      # `create_definition/2` is what Repo.insert/1 hands back unchanged on
      # the insert path itself. Comparing against a real read is also the
      # more faithful assertion: it proves export/4 emits exactly what a
      # fresh read produces, not what the write-path happened to echo back.
      assert {:ok, entity_definition} =
               EntityDefinitions.get_definition_by_name(created.name, tenant.schema_name)

      assert {:ok, doc} =
               SolutionPack.export([], [entity_definition.name], "1.0.0", prefix: tenant.schema_name)

      assert doc.definitions == []
      assert [packed] = doc.entity_definitions

      # Exact five-field shape the design specifies (§2.2's table) -- a test
      # asserting only `Map.has_key?` would pass even if extra storage-only
      # fields (tenant_id, content_hash, artifact_version_id, status) leaked
      # into the document, which INV-2 forbids; asserting the full key set
      # AND each value catches both a missing field and a leaked one.
      assert Map.keys(packed) |> Enum.sort() ==
               Enum.sort([
                 :entity_definition_id,
                 :name,
                 :display_name,
                 :definition_json,
                 :logical_shape_version
               ])

      assert packed.entity_definition_id == entity_definition.id
      assert packed.name == entity_definition.name
      assert packed.display_name == entity_definition.display_name
      assert packed.definition_json == entity_definition.definition_json
      assert packed.logical_shape_version == entity_definition.logical_shape_version

      # And the required-minimum (AC2) fields carry the real, human-authored
      # content -- not just structurally-present placeholders.
      assert packed.name == created.name
      assert packed.display_name == "REQ-304 Entity Fixture"
      assert packed.definition_json["name"] == created.name
    end

    test "naming zero definition_ids but a non-empty entity_definition_names list is a legitimate entity-only export" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac2-entity-only")
      entity_definition = create_entity_definition!(tenant.schema_name)

      assert {:ok, doc} =
               SolutionPack.export([], [entity_definition.name], nil, prefix: tenant.schema_name)

      assert doc.definitions == []
      assert [%{name: name}] = doc.entity_definitions
      assert name == entity_definition.name
    end

    test "naming both a process definition and an entity definition populates both lists independently" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac2-both")
      definition = active_process_definition!(tenant.schema_name)
      entity_definition = create_entity_definition!(tenant.schema_name)

      assert {:ok, doc} =
               SolutionPack.export(
                 [definition.id],
                 [entity_definition.name],
                 "1.0.0",
                 prefix: tenant.schema_name
               )

      expected_definition_id = definition.id
      expected_entity_name = entity_definition.name
      assert [%{definition_id: ^expected_definition_id}] = doc.definitions
      assert [%{name: ^expected_entity_name}] = doc.entity_definitions
    end

    test "zero definition_ids and zero entity_definition_names is still {:error, :empty_definition_ids}" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac2-both-empty")

      assert SolutionPack.export([], [], "1.0.0", prefix: tenant.schema_name) ==
               {:error, :empty_definition_ids}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC3/AC4 -- tenant isolation (INV-1) and the not-found error shape
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC3/AC4: entity-definition export is tenant-isolated; unresolved names are typed not-found errors" do
    test "two tenants each own an entity definition of the SAME name -- export under A's opts returns only A's row, never B's" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac3-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac3-b")

      shared_name = unique("req304_shared")

      entity_a =
        create_entity_definition!(tenant_a.schema_name, %{
          name: shared_name,
          display_name: "Tenant A's definition"
        })

      _entity_b =
        create_entity_definition!(tenant_b.schema_name, %{
          name: shared_name,
          display_name: "Tenant B's definition"
        })

      assert {:ok, doc} =
               SolutionPack.export([], [shared_name], "1.0.0", prefix: tenant_a.schema_name)

      assert [packed] = doc.entity_definitions
      assert packed.entity_definition_id == entity_a.id
      assert packed.display_name == "Tenant A's definition"
      refute packed.display_name == "Tenant B's definition"
    end

    test "naming a wholly nonexistent name -- {:error, {:entity_definition_not_found, name}}" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac4-missing")
      missing_name = unique("req304_missing")

      assert SolutionPack.export([], [missing_name], "1.0.0", prefix: tenant.schema_name) ==
               {:error, {:entity_definition_not_found, missing_name}}
    end

    test "naming another tenant's entity definition (by name, no definition of that name in the caller's own schema) -- SAME not-found shape, no leak" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac4-cross-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac4-cross-b")

      entity_b = create_entity_definition!(tenant_b.schema_name)

      result = SolutionPack.export([], [entity_b.name], "1.0.0", prefix: tenant_a.schema_name)

      # Must be the identical typed error a genuine miss produces -- proves
      # this is not a leak of tenant B's row (e.g. no {:ok, doc} branch, and
      # no distinct error shape that would let a caller distinguish "exists
      # elsewhere" from "doesn't exist anywhere").
      assert result == {:error, {:entity_definition_not_found, entity_b.name}}

      assert result ==
               SolutionPack.export([], [entity_b.name], "1.0.0", prefix: tenant_a.schema_name)
    end

    test "first offending name wins deterministically when multiple names are given" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac4-order")
      real = create_entity_definition!(tenant.schema_name)
      missing_first = unique("req304_missing_first")
      missing_second = unique("req304_missing_second")

      assert SolutionPack.export(
               [],
               [missing_first, real.name, missing_second],
               "1.0.0",
               prefix: tenant.schema_name
             ) == {:error, {:entity_definition_not_found, missing_first}}
    end
  end
end
