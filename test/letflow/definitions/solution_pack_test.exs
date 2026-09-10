defmodule Letflow.Definitions.SolutionPackTest do
  @moduledoc """
  Tests for REQ-304 (`lib/letflow/design/req304-solution-pack-entity-definitions-export.md`)
  AND REQ-305 (`lib/letflow/design/req305-solution-pack-entity-definitions-install.md`),
  both governed by `docs/migration/decisions/0026-solution-pack-entity-definitions-section.md`
  -- the `entity_definitions` section added to `Letflow.Definitions.SolutionPack`'s
  export path (`export/4`, `pack_each_entity_definition/2`, `pack_entity_definition/1`)
  AND install path (`install/3`'s `parse_entity_definitions/1`,
  `create_packed_entity_definitions/3`). See `test/specs/REQ-304.md` (export) and
  `test/specs/REQ-306.md` (round-trip/install coverage, REQ-306) for the
  acceptance-criterion-to-test-case mapping.

  Extended (not split into a new file) for REQ-306: REQ-306's own scope fence names
  this file explicitly as the default target ("extend
  `test/letflow/definitions/solution_pack_test.exs`, or create a new file only if
  the existing file's structure genuinely doesn't fit"). It fits: REQ-306 tests the
  same module's other half (install) using the identical fixture/tenant conventions
  already established here for export, so a second file would only duplicate the
  helper section below.

  Context-module level (not router level, unlike
  `test/letflow/routers/req078_supporting_routes_test.exs`'s solution-pack coverage):
  0026/REQ-304's own scope fence leaves `lib/letflow/routers/solution_packs.ex`
  untouched, so there is no HTTP surface yet for `export/4` or the
  `entity_definition_names` parameter -- the only way to exercise this behavior is
  to call `Letflow.Definitions.SolutionPack.export/3`, `.export/4`, and `.install/3`
  directly. REQ-305 likewise never touched the router.

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture` for real provisioned tenant schemas,
  mirroring `req078_supporting_routes_test.exs`'s own fixture conventions.
  `async: false` -- same reasoning as that file (tenant provisioning/migration
  replay needs `Sandbox.mode(Letflow.Repo, :auto)`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Engine.VariableSchema
  alias Letflow.Entities.Definitions, as: EntityDefinitions
  alias Letflow.Entities.EntityDefinition
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
  defp valid_entity_definition(overrides) do
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

  # ── REQ-305/REQ-306 install-side helpers ─────────────────────────────────────
  #
  # Same hand-built-raw-JSON-document idiom `req078_supporting_routes_test.exs`'s
  # `pack_document/2`/`packed_definition_json/3`/`packed_variable_schema_json/3`
  # already establish for exercising `install/3` (string keys throughout --
  # `install/3`'s own moduledoc: "document is the raw decoded JSON body"), extended
  # with an `entity_definitions` key. `pack_document/1` takes a fields map instead
  # of positional args specifically so a caller can OMIT the `:entity_definitions`
  # key entirely (AC4 old-pack-compatibility -- Map.fetch/2 below only adds the
  # `"entity_definitions"` wire key when the caller supplied one, never defaulting
  # it to `[]` itself).

  defp pack_document(fields) when is_map(fields) do
    base = %{
      "pack_id" => Ecto.UUID.generate(),
      "version" => "1.0.0",
      "bpm_export_schema_version" => Letflow.Definitions.ExportImport.export_schema_version(),
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "definitions" => Map.get(fields, :definitions, []),
      "service_catalog_entries" => [],
      "variable_schemas" => Map.get(fields, :variable_schemas, [])
    }

    case Map.fetch(fields, :entity_definitions) do
      {:ok, entity_definitions} -> Map.put(base, "entity_definitions", entity_definitions)
      :error -> base
    end
    |> Map.put("manifest", %{"required_roles" => []})
  end

  defp packed_definition_json(source_id, process_key, graph \\ nil) do
    %{
      "definition_id" => source_id,
      "process_key" => process_key,
      "name" => process_key,
      "version" => "1.0.0",
      "graph" => graph || graph_start_end()
    }
  end

  defp packed_variable_schema_json(definition_id, schema_name, schema_content) do
    %{
      "definition_id" => definition_id,
      "schema_name" => schema_name,
      "schema_content" => schema_content
    }
  end

  # Builds a raw, string-keyed `entity_definitions` wire entry -- the shape
  # `parse_entity_definition/1` (solution_pack.ex) requires. `definition_json`
  # must itself be string-keyed throughout (it is re-atomized on install via
  # `atomize_definition_json/1`'s static whitelist), matching what a real JSON
  # decode or a real `EntityDefinition.definition_json` DB read produces --
  # never an atom-keyed map, which would make `translate_keys/2` reject every
  # key as unrecognized.
  defp packed_entity_definition_json(overrides \\ %{}) do
    default_name = unique("req306_entity")

    Map.merge(
      %{
        "entity_definition_id" => Ecto.UUID.generate(),
        "name" => default_name,
        "display_name" => "REQ-306 Entity Fixture",
        "logical_shape_version" => "req306-shape-" <> default_name,
        "definition_json" => %{
          "name" => default_name,
          "display_name" => "REQ-306 Entity Fixture",
          "fields" => [
            %{"name" => "email", "type" => "string", "required" => true, "queried" => true}
          ]
        }
      },
      overrides
    )
  end

  # Same LIFO on_exit reasoning as req078_supporting_routes_test.exs's own
  # cleanup_solution_pack_installs!/1 -- solution_pack_installs is a REQ-041
  # GLOBAL table TenantFixture has no knowledge of, so it must be cleaned up
  # before TenantFixture's own on_exit drops the tenants row it references
  # (solution_pack_installs_tenant_id_fkey). Register this AFTER the tenant
  # fixture call in test body order so ExUnit's LIFO on_exit runs this first.
  # Recursively turns every atom map key into a string key -- what a real JSON
  # decode of a route's request body would hand `install/3` (its own moduledoc:
  # "the raw decoded JSON body"), applied here to `export/4`'s atom-keyed
  # in-process return value so the round-trip test crosses the same key-shape
  # boundary a real export->install trip would. Deliberately NOT
  # `Jason.encode!/1 |> Jason.decode!/1`: `packed_entity_definition/1`
  # (solution_pack.ex) embeds `EntityDefinition.logical_shape_version` --
  # `field(:logical_shape_version, :binary)`, a raw (non-UTF-8-safe) digest
  # from `Letflow.Entities.Definition.Shape.logical_shape_of/1`'s SHA-256 hash
  # -- verbatim into the pack document, which is not valid JSON input and
  # makes `Jason.encode!/1` raise `Jason.EncodeError` on any real entity
  # definition (confirmed: this test raised `** (Jason.EncodeError) invalid
  # byte 0xEC` on first write, before this workaround was added). That is a
  # genuine latent defect in REQ-304's export shape, reported separately per
  # the incidental-issue process (see this requirement's completion report) --
  # not fixed here (scope fence: test code only). `fetch_string/2`
  # (solution_pack.ex, install-side) only requires `is_binary/1`, which a raw
  # byte sequence satisfies regardless of UTF-8 validity, so this stringify
  # step is a faithful stand-in for the key-shape half of real JSON transport
  # without tripping the unrelated encoding bug.
  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp cleanup_solution_pack_installs!(tenant_id) do
    on_exit(fn ->
      Repo.delete_all(from(s in SolutionPackInstall, where: s.tenant_id == ^tenant_id))
    end)
  end

  defp process_definition_count(schema_name, name) do
    Repo.aggregate(from(d in ProcessDefinition, where: d.name == ^name), :count, :id,
      prefix: schema_name
    )
  end

  defp entity_definition_count(schema_name, name) do
    Repo.aggregate(from(e in EntityDefinition, where: e.name == ^name), :count, :id,
      prefix: schema_name
    )
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
               SolutionPack.export([], [entity_definition.name], "1.0.0",
                 prefix: tenant.schema_name
               )

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

  # ═══════════════════════════════════════════════════════════════════════════
  # REQ-306 -- REQ-305's install path: round-trip, name-collision rollback,
  # malformed-entry rejection, old-pack compatibility, :inactive-only install.
  # See test/specs/REQ-306.md for the full acceptance-criterion mapping. The
  # cross-tenant-export criterion (REQ-306 AC5) is covered by the existing
  # "AC3/AC4" describe block above (REQ-304's own coverage) rather than
  # duplicated here -- same export/3 code path, same not-found error shape.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "REQ-306 round-trip: export from tenant A, install into tenant B, byte-identical row" do
    test "installed entity definition's definition_json/display_name/logical_shape_version match the exported source exactly, status :inactive" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req306-roundtrip-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req306-roundtrip-b")
      cleanup_solution_pack_installs!(tenant_b.tenant_id)

      source = create_entity_definition!(tenant_a.schema_name)

      assert {:ok, source} =
               EntityDefinitions.get_definition_by_name(source.name, tenant_a.schema_name)

      # AC1 -- via REQ-304's real export path.
      assert {:ok, exported} =
               SolutionPack.export([], [source.name], "1.0.0", prefix: tenant_a.schema_name)

      # Simulate the key-shape boundary between export and install -- the same
      # one a route layer's decoded request body would cross -- rather than
      # handing install/3 the atom-keyed Elixir map export/4 returns
      # in-process. install/3's own moduledoc requires string keys. See
      # stringify_keys/1's own comment for why this is NOT a real
      # Jason.encode!/decode! round-trip.
      wire_document = stringify_keys(exported)

      actor_id = Ecto.UUID.generate()

      # AC1 -- via REQ-305's real install path, into a DIFFERENT tenant schema.
      assert {:ok, result} =
               SolutionPack.install(wire_document, actor_id, prefix: tenant_b.schema_name)

      assert [installed] = result.installed_entity_definitions
      assert installed.source_entity_definition_id == source.id
      assert installed.name == source.name
      assert installed.status == "installed"
      assert is_binary(installed.new_entity_definition_id)
      refute installed.new_entity_definition_id == source.id

      # Query the ACTUAL row Postgres now holds in tenant B, not just the
      # in-memory install result -- proves the write really landed and with
      # the right content, not merely that install/3 claimed success.
      assert {:ok, installed_row} =
               EntityDefinitions.get_definition_by_name(source.name, tenant_b.schema_name)

      assert installed_row.id == installed.new_entity_definition_id
      assert installed_row.definition_json == source.definition_json
      assert installed_row.display_name == source.display_name
      assert installed_row.logical_shape_version == source.logical_shape_version
      assert installed_row.name == source.name

      # AC6 (0026 SS2) -- :inactive-only, no activate_definition/4 call.
      assert installed_row.status == :inactive

      # Never installed into the SOURCE tenant a second time.
      assert entity_definition_count(tenant_a.schema_name, source.name) == 1
    end
  end

  describe "REQ-306 name-collision rollback: whole install fails, nothing from the pack lands" do
    test "an entity_definitions entry colliding with an existing row aborts the WHOLE transaction -- zero new rows in process_definitions, variable_schemas, entity_definitions" do
      target = TenantFixture.provisioned_tenant!(slug_prefix: "req306-collision")
      cleanup_solution_pack_installs!(target.tenant_id)

      # Pre-existing entity definition already in the TARGET tenant.
      existing = create_entity_definition!(target.schema_name)

      assert {:ok, existing} =
               EntityDefinitions.get_definition_by_name(existing.name, target.schema_name)

      # A colliding entry: same name, and IDENTICAL definition_json content as
      # the existing row, so create_definition/2's own freshly-recomputed
      # logical_shape_version (Shape.logical_shape_of/1, derived from content,
      # never from the pack's own logical_shape_version field) matches the
      # existing row's -- the real (tenant_id, name, logical_shape_version)
      # collision 0026 SS2 specifies, not merely a same-name coincidence.
      colliding_entity_json =
        packed_entity_definition_json(%{
          "name" => existing.name,
          "display_name" => existing.display_name,
          "definition_json" => existing.definition_json
        })

      process_key = unique("req306-collision-pd")
      pd_source_id = Ecto.UUID.generate()
      schema_content = Jason.encode!(%{"type" => "string"})

      document =
        pack_document(%{
          definitions: [packed_definition_json(pd_source_id, process_key)],
          variable_schemas: [
            packed_variable_schema_json(pd_source_id, "order_id", schema_content)
          ],
          entity_definitions: [colliding_entity_json]
        })

      actor_id = Ecto.UUID.generate()

      assert {:error, {:persistence, %Ecto.Changeset{}}} =
               SolutionPack.install(document, actor_id, prefix: target.schema_name)

      # Query every affected table directly -- don't just trust the error tuple.
      assert process_definition_count(target.schema_name, process_key) == 0

      assert Repo.aggregate(VariableSchema, :count, :id, prefix: target.schema_name) == 0

      # Still exactly the ONE pre-existing row -- no duplicate, no partial
      # second row from the aborted attempt.
      assert entity_definition_count(target.schema_name, existing.name) == 1

      # The global solution_pack_installs row this install attempted to write
      # also rolled back (same transaction).
      assert Repo.aggregate(
               from(s in SolutionPackInstall, where: s.pack_id == ^document["pack_id"]),
               :count,
               :id
             ) == 0
    end
  end

  describe "REQ-306 malformed entity_definitions entries: typed rejection, zero rows written" do
    test "missing name -- {:error, :invalid_pack_document}, nothing written" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req306-malformed-name")

      bad_entry = packed_entity_definition_json() |> Map.delete("name")
      document = pack_document(%{entity_definitions: [bad_entry]})

      assert SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name) ==
               {:error, :invalid_pack_document}

      assert Repo.aggregate(EntityDefinition, :count, :id, prefix: tenant.schema_name) == 0
    end

    test "missing definition_json -- {:error, :invalid_pack_document}, nothing written" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req306-malformed-defjson")

      bad_entry = packed_entity_definition_json() |> Map.delete("definition_json")
      document = pack_document(%{entity_definitions: [bad_entry]})

      assert SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name) ==
               {:error, :invalid_pack_document}

      assert Repo.aggregate(EntityDefinition, :count, :id, prefix: tenant.schema_name) == 0
    end

    test "wrong field type -- definition_json as a string, not an object -- {:error, :invalid_pack_document}, nothing written" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req306-malformed-type")

      bad_entry = packed_entity_definition_json(%{"definition_json" => "not-an-object"})
      document = pack_document(%{entity_definitions: [bad_entry]})

      assert SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name) ==
               {:error, :invalid_pack_document}

      assert Repo.aggregate(EntityDefinition, :count, :id, prefix: tenant.schema_name) == 0
    end
  end

  describe "REQ-306 old-pack compatibility: entity_definitions key OMITTED entirely (not [])" do
    test "a document with no entity_definitions key at all still installs its other sections exactly as before" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req306-old-pack")
      cleanup_solution_pack_installs!(tenant.tenant_id)

      process_key = unique("req306-oldpack-pd")
      pd_source_id = Ecto.UUID.generate()
      schema_content = Jason.encode!(%{"type" => "string"})

      # Built via pack_document/1 with NO :entity_definitions key in `fields`
      # -- pack_document/1 only adds the "entity_definitions" wire key when a
      # caller supplies one (see its own comment above), so the resulting map
      # genuinely has no such key, not merely an empty list under it.
      document =
        pack_document(%{
          definitions: [packed_definition_json(pd_source_id, process_key)],
          variable_schemas: [
            packed_variable_schema_json(pd_source_id, "customer_id", schema_content)
          ]
        })

      refute Map.has_key?(document, "entity_definitions")

      actor_id = Ecto.UUID.generate()

      assert {:ok, result} = SolutionPack.install(document, actor_id, prefix: tenant.schema_name)

      assert [%{process_key: ^process_key, status: "installed"}] = result.installed_definitions
      assert result.installed_entity_definitions == []
      assert result.variable_schemas_written == 1

      assert process_definition_count(tenant.schema_name, process_key) == 1
      assert Repo.aggregate(VariableSchema, :count, :id, prefix: tenant.schema_name) == 1
    end
  end
end
