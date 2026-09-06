defmodule Letflow.Entities.DefinitionsTest do
  @moduledoc """
  Integration tests for `Letflow.Entities.Definitions` and
  `Letflow.Entities.EntityDefinition` (REQ-226) -- `entity_definitions`
  persistence, the CRUD context module's `create_definition/2`/
  `get_definition/2`/`get_definition_by_name/2`/`list_definitions/2`/
  `activate_definition/4`, and the `:entity` `Letflow.Repository.ArtifactKind`
  extension. See
  `lib/letflow/design/req226-entity-definitions-persistence-crud.md` for the
  design this file verifies.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Self-contained: provisions its own tenant schema(s), does not share
  fixtures with any other test file (DIRECTIVE T-4), mirroring
  `test/letflow/repository_test.exs`'s own hand-rolled tenant-fixture
  pattern (REQ-202's structural sibling this design is based on).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Repository
  alias Letflow.Repository.Artifact
  alias Letflow.Repository.ArtifactKind
  alias Letflow.Repository.ArtifactVersion
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  # ---------------------------------------------------------------------------------
  # Fixtures -- same shape as test/letflow/repository_test.exs's provisioned_tenant/0.
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req226-entities"),
        display_name: "REQ-226 Entity Definitions Test Tenant"
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

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp valid_definition(overrides \\ %{}) do
    Map.merge(
      %{
        name: "customer",
        display_name: "Customer",
        fields: [
          %{name: "email", type: :string, required: true, queried: true},
          %{name: "age", type: :integer}
        ]
      },
      overrides
    )
  end

  defp invalid_definition do
    # Fails Rule 1 (name_format): uppercase leading char.
    valid_definition(%{name: "Customer"})
  end

  defp create_attrs(overrides \\ %{}) do
    Map.merge(
      %{definition: valid_definition(), created_by: Ecto.UUID.generate()},
      overrides
    )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- :entity is the 8th artifact_kind value; the existing 7 are unmodified.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- ArtifactKind's :entity extension" do
    test "values/0 includes :entity as an eighth value, with all 7 existing values unmodified" do
      values = ArtifactKind.values()

      assert length(values) == 8
      assert :entity in values

      assert values == [
               :definition,
               :form,
               :schema,
               :service_catalog,
               :script,
               :module,
               :scenario,
               :entity
             ]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- create_definition/2 rejects a structurally-invalid definition,
  # writing NEITHER an artifact_versions NOR an entity_definitions row.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- create_definition/2 rejects a structurally-invalid definition" do
    test "returns {:error, {:validation, violations}} and writes zero rows to either table" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:error, {:validation, violations}} =
               Definitions.create_definition(
                 create_attrs(%{definition: invalid_definition()}),
                 schema
               )

      assert [%Letflow.Entities.Definition.Validator.Violation{rule: :name_format} | _] =
               violations

      assert Repo.aggregate(ArtifactVersion, :count, prefix: schema) == 0
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
      assert Repo.aggregate(EntityDefinition, :count, prefix: schema) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- create_definition/2 for a valid definition calls Repository.create/2
  # with artifact_kind: :entity and creates one entity_definitions row
  # referencing the returned artifact_version_id.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- create_definition/2 for a valid definition" do
    test "creates one artifact_versions row (kind :entity) and one entity_definitions row referencing it" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, %EntityDefinition{} = entity_definition} =
               Definitions.create_definition(create_attrs(), schema)

      assert entity_definition.name == "customer"
      assert entity_definition.display_name == "Customer"
      assert entity_definition.status == :inactive
      refute is_nil(entity_definition.artifact_version_id)

      version = Repo.get!(ArtifactVersion, entity_definition.artifact_version_id, prefix: schema)
      assert version.artifact_kind == :entity
      assert version.artifact_name == "customer"
      assert version.content_hash == entity_definition.content_hash

      assert Repo.aggregate(ArtifactVersion, :count, prefix: schema) == 1
      assert Repo.aggregate(EntityDefinition, :count, prefix: schema) == 1

      # definition_json round-trips the submitted document. The freshly
      # inserted struct still carries the atom-keyed map passed into the
      # changeset (no reload); re-fetching from the DB decodes jsonb back
      # with string keys, which is what a real caller (e.g. list/get) sees.
      assert entity_definition.definition_json[:name] == "customer"

      reloaded = Repo.get!(EntityDefinition, entity_definition.id, prefix: schema)
      assert reloaded.definition_json["name"] == "customer"
    end

    test "get_definition/2 and get_definition_by_name/2 both find the created row" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, created} = Definitions.create_definition(create_attrs(), schema)

      assert {:ok, by_id} = Definitions.get_definition(created.id, schema)
      assert by_id.id == created.id

      assert {:ok, by_name} = Definitions.get_definition_by_name("customer", schema)
      assert by_name.id == created.id

      assert Definitions.get_definition(Ecto.UUID.generate(), schema) == {:error, :not_found}

      assert Definitions.get_definition_by_name("does-not-exist", schema) ==
               {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- dedup/uniqueness semantics, both scenarios from design §4.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- dedup/uniqueness semantics" do
    # NOTE (flagged for REVIEWER, not silently patched): design §4 Scenario A
    # narrates "byte-identical definition_json, different name" sharing one
    # `repository_artifacts` row. In practice this exact combination can
    # never arise through `create_definition/2`, because
    # `Letflow.Entities.Definition.Shape.content_hash/1` (REQ-225, unmodified,
    # out of this requirement's scope) hashes the *entire* definition
    # document -- including its own `:name` field, which `create_definition/2`
    # also uses verbatim as `Letflow.Repository.create/2`'s `artifact_name`
    # (design §3.3 step 3). Two definitions with different `name` values
    # therefore always hash differently; "identical content_hash, different
    # name" is unreachable via this pipeline, not merely untested. This test
    # instead verifies the two outcomes that ARE reachable and matter for
    # AC4's real intent: (a) two definitions with genuinely different content
    # get two independent `repository_artifacts` rows (no false/accidental
    # dedup), and (b) `Letflow.Repository.create/2`'s own dedup mechanism --
    # the one `create_definition/2` reuses unmodified -- still does what
    # REQ-202 promises when exercised directly with byte-identical content
    # under two different `artifact_name`s (already the AC1 case in
    # `test/letflow/repository_test.exs`; repeated narrowly here to confirm
    # `:entity` flows through the shared `artifact_kind` enum unchanged).
    test "two definitions with different content get independent repository_artifacts rows (no accidental dedup)" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, def_a} =
               Definitions.create_definition(
                 create_attrs(%{definition: valid_definition(%{name: "entity_a"})}),
                 schema
               )

      assert {:ok, def_b} =
               Definitions.create_definition(
                 create_attrs(%{
                   definition:
                     valid_definition(%{
                       name: "entity_b",
                       fields: [%{name: "different_field", type: :boolean}]
                     })
                 }),
                 schema
               )

      refute def_a.content_hash == def_b.content_hash
      refute def_a.id == def_b.id

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 2
      assert Repo.aggregate(ArtifactVersion, :count, prefix: schema) == 2
      assert Repo.aggregate(EntityDefinition, :count, prefix: schema) == 2
    end

    test "Repository.create/2 (the pipeline create_definition/2 reuses unmodified) dedups byte-identical :entity content across two artifact names" do
      %{schema_name: schema} = provisioned_tenant()

      shared_content = Jason.encode!(%{"kind" => "shared-entity-content", "value" => 1})

      assert {:ok, v1} =
               Repository.create(
                 %{
                   artifact_kind: :entity,
                   artifact_name: "raw-entity-one",
                   content_type: "application/json",
                   content: shared_content,
                   created_by: Ecto.UUID.generate()
                 },
                 schema
               )

      assert {:ok, v2} =
               Repository.create(
                 %{
                   artifact_kind: :entity,
                   artifact_name: "raw-entity-two",
                   content_type: "application/json",
                   content: shared_content,
                   created_by: Ecto.UUID.generate()
                 },
                 schema
               )

      assert v1.content_hash == v2.content_hash
      assert v1.artifact_kind == :entity
      assert v2.artifact_kind == :entity
      refute v1.artifact_id == v2.artifact_id

      assert Repo.aggregate(Artifact, :count, prefix: schema) == 1
      assert Repo.aggregate(ArtifactVersion, :count, prefix: schema) == 2
    end

    test "same name and same logical_shape_version is rejected by the UNIQUE constraint" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, _first} = Definitions.create_definition(create_attrs(), schema)

      # Identical logical shape (same name/fields) -- only display_name
      # differs, which the design's §1.2 states is excluded from the
      # logical-shape digest.
      assert {:error, {:persistence, changeset}} =
               Definitions.create_definition(
                 create_attrs(%{
                   definition: valid_definition(%{display_name: "Customer (renamed display)"})
                 }),
                 schema
               )

      assert %{name: ["has already been taken"]} = errors_on(changeset)

      # Only one entity_definitions row exists despite the rejected second
      # attempt; a second artifact_versions row WAS created though (design §4
      # Scenario B's accepted cost of reusing create/2 unmodified).
      assert Repo.aggregate(EntityDefinition, :count, prefix: schema) == 1
      assert Repo.aggregate(ArtifactVersion, :count, prefix: schema) == 2
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- list_definitions/2 is tenant-scoped and paginates via REQ-067's
  # cursor contract.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- list_definitions/2 tenant scoping and pagination" do
    test "a definition created under tenant A is absent from tenant B's list" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()

      assert {:ok, _} = Definitions.create_definition(create_attrs(), schema_a)

      assert {:ok, page_a} = Definitions.list_definitions(%{}, schema_a)
      assert length(page_a.items) == 1

      assert {:ok, page_b} = Definitions.list_definitions(%{}, schema_b)
      assert page_b.items == []
    end

    test "pagination: page_size smaller than the result set yields a non-nil next_cursor that advances" do
      %{schema_name: schema} = provisioned_tenant()

      for n <- 1..5 do
        assert {:ok, _} =
                 Definitions.create_definition(
                   create_attrs(%{definition: valid_definition(%{name: "entity_#{n}"})}),
                   schema
                 )
      end

      assert {:ok, page_1} = Definitions.list_definitions(%{page_size: 2}, schema)
      assert length(page_1.items) == 2
      assert is_binary(page_1.next_cursor)

      assert {:ok, page_2} =
               Definitions.list_definitions(%{page_size: 2, cursor: page_1.next_cursor}, schema)

      assert length(page_2.items) == 2
      assert is_binary(page_2.next_cursor)

      assert {:ok, page_3} =
               Definitions.list_definitions(%{page_size: 2, cursor: page_2.next_cursor}, schema)

      assert length(page_3.items) == 1
      assert page_3.next_cursor == nil

      all_ids =
        (page_1.items ++ page_2.items ++ page_3.items)
        |> Enum.map(& &1.id)
        |> Enum.uniq()

      assert length(all_ids) == 5
    end

    test "page_size 0 and 201 are both rejected with :page_size_too_large" do
      %{schema_name: schema} = provisioned_tenant()

      assert Definitions.list_definitions(%{page_size: 0}, schema) ==
               {:error, :page_size_too_large}

      assert Definitions.list_definitions(%{page_size: 201}, schema) ==
               {:error, :page_size_too_large}
    end

    test "a cursor minted for a different endpoint's prefix is rejected with :wrong_endpoint" do
      %{schema_name: schema} = provisioned_tenant()

      foreign_cursor =
        "RV:"
        |> Letflow.Api.Pagination.build_raw_cursor_timestamp_key(
          System.system_time(:microsecond),
          Ecto.UUID.generate(),
          1
        )
        |> Letflow.Api.Pagination.encode_cursor()

      assert Definitions.list_definitions(%{cursor: foreign_cursor}, schema) ==
               {:error, :wrong_endpoint}
    end

    test "an invalid schema-name prefix is rejected with :invalid_schema_name" do
      assert Definitions.list_definitions(%{}, "not-a-real-schema") ==
               {:error, :invalid_schema_name}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- activation reuses REQ-203's existing machinery; no new mechanism.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- activate_definition/4 reuses REQ-203's activation machinery" do
    test "activating updates entity_definitions.status and REQ-203's artifact_activations resolves to the same version" do
      %{schema_name: schema} = provisioned_tenant()

      assert {:ok, created} = Definitions.create_definition(create_attrs(), schema)
      assert created.status == :inactive

      assert {:ok, %EntityDefinition{status: :active} = activated} =
               Definitions.activate_definition(
                 "customer",
                 Ecto.UUID.generate(),
                 "go-live",
                 schema
               )

      assert activated.id == created.id

      assert {:ok, resolved_version} = Repository.Activation.resolve(:entity, "customer", schema)
      assert resolved_version.version_id == created.artifact_version_id
    end

    test "activating a non-existent definition returns {:error, :not_found}" do
      %{schema_name: schema} = provisioned_tenant()

      assert Definitions.activate_definition(
               "does-not-exist",
               Ecto.UUID.generate(),
               "go-live",
               schema
             ) == {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- no route or controller file is added or modified for this requirement.
  # ---------------------------------------------------------------------------------

  describe "AC7 -- no route/controller surface exists for entity definitions" do
    test "lib/letflow/router.ex does not forward to an entity-definitions router" do
      router_source = File.read!(Path.expand("../../../lib/letflow/router.ex", __DIR__))

      refute router_source =~ ~r/entity_definition/i
    end

    test "no lib/letflow/routers/entity_definitions.ex file exists" do
      refute File.exists?(
               Path.expand("../../../lib/letflow/routers/entity_definitions.ex", __DIR__)
             )
    end
  end
end
