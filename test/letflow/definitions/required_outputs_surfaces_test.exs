defmodule Letflow.Definitions.RequiredOutputsSurfacesTest do
  @moduledoc """
  DB-backed tests for the SURFACES of REQ-461's checks (REQ-459 design sections 1.2-1.4,
  Adjustments REQ-461): which entry point runs which check. See `test/specs/REQ-461.md`.

    * check 1 (shape): `Definitions.create/2`, `Definitions.update/3`, `SolutionPack.install/3`
    * check 2 (variable_schema): `Definitions.validate_definition_graph/2` and
      `Definitions.activate/2` only; NOT `create/2` and NOT pack install
    * check 3 (`decision_key_not_required:` WARNING): `validate_definition_graph/2` `:warnings`
      and the pack-install result `:warnings`; never a violation, never in activate's result
    * `Letflow.Definitions.ValidationWarnings.for_definitions/2` ordering and type

  `Letflow.DataCase` (real Postgres), `async: false` (tenant provisioning), one provisioned
  tenant per test, unique names via `System.unique_integer/1`, no clock, no unseeded randomness.
  No helper has a default argument (anti-patterns ISS-0069).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Definitions.ValidationWarnings
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @condition "decision == \"approved\""
  @decision_schema %{"type" => "string", "enum" => ["approved", "rejected"]}

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # start -> t (HUMAN_TASK, form collects `decision`) -> (decision == "approved") end-a
  #                                                    -> default            end-b
  # `task_attrs` is merged over the task's base attributes (role + form_schema).
  defp decision_graph(role, task_attrs) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "t",
          "node_type" => "HUMAN_TASK",
          "attributes" =>
            Map.merge(
              %{
                "role" => role,
                "form_schema" => %{"properties" => %{"decision" => %{"type" => "string"}}}
              },
              task_attrs
            )
        },
        %{"id" => "end-a", "node_type" => "END"},
        %{"id" => "end-b", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e-start", "source" => "start", "target" => "t"},
        %{"id" => "e-cond", "source" => "t", "target" => "end-a", "condition" => @condition},
        %{"id" => "e-def", "source" => "t", "target" => "end-b", "is_default" => true}
      ]
    }
  end

  defp create_attrs(name, graph),
    do: %{name: name, version: "1.0.0", graph: graph, created_by: Ecto.UUID.generate()}

  defp create!(schema, graph) do
    assert {:ok, definition} =
             Definitions.create(create_attrs(unique("req461-def"), graph), prefix: schema)

    definition
  end

  defp register_decision_schema!(schema, definition_id) do
    assert {:ok, 1} =
             Definitions.register_variable_schemas(
               definition_id,
               [%{variable_key: "decision", json_schema: @decision_schema}],
               prefix: schema
             )
  end

  defp tenant!(slug), do: TenantFixture.provisioned_tenant!(slug_prefix: slug)

  defp definition_count(schema),
    do: Repo.aggregate(Definitions.ProcessDefinition, :count, :id, prefix: schema)

  defp decision_lines(warnings),
    do: Enum.filter(warnings, &String.starts_with?(&1, "decision_key_not_required:"))

  # ---------------------------------------------------------------------------------------
  # Check 1 -- shape violations at create and update
  # ---------------------------------------------------------------------------------------

  describe "check 1 at create/2 and update/3" do
    test "create/2 rejects a non-list required_outputs with :invalid_required_outputs naming the node; nothing is stored" do
      tenant = tenant!("req461-create-bad")
      graph = decision_graph("approver", %{"required_outputs" => "decision"})

      assert {:error, {:graph_validation_failed, [violation]}} =
               Definitions.create(create_attrs(unique("req461-def"), graph),
                 prefix: tenant.schema_name
               )

      assert violation.code == :invalid_required_outputs
      assert violation.message =~ "Node 't'"
      assert definition_count(tenant.schema_name) == 0
    end

    test "create/2 rejects a duplicate key and an empty entry, one violation each" do
      tenant = tenant!("req461-create-dup")

      for {bad, label} <- [{["decision", "decision"], "duplicate"}, {[""], "empty"}] do
        graph = decision_graph("approver", %{"required_outputs" => bad})

        assert {:error, {:graph_validation_failed, [violation]}} =
                 Definitions.create(create_attrs(unique("req461-def"), graph),
                   prefix: tenant.schema_name
                 ),
               label

        assert violation.code == :invalid_required_outputs
      end

      assert definition_count(tenant.schema_name) == 0
    end

    test "create/2 rejects required_outputs on a non-HUMAN_TASK node with :required_outputs_on_non_human_task" do
      tenant = tenant!("req461-create-nonhuman")

      graph = decision_graph("approver", %{})

      graph =
        update_in(graph["nodes"], fn nodes ->
          nodes ++
            [
              %{
                "id" => "gw",
                "node_type" => "EXCLUSIVE_GATEWAY",
                "attributes" => %{"required_outputs" => ["decision"]}
              }
            ]
        end)

      graph =
        update_in(graph["edges"], fn edges ->
          Enum.map(edges, fn
            %{"id" => "e-def"} = edge -> %{edge | "source" => "gw"}
            %{"id" => "e-cond"} = edge -> %{edge | "source" => "gw"}
            other -> other
          end) ++ [%{"id" => "e-t", "source" => "t", "target" => "gw"}]
        end)

      assert {:error, {:graph_validation_failed, violations}} =
               Definitions.create(create_attrs(unique("req461-def"), graph),
                 prefix: tenant.schema_name
               )

      assert [:required_outputs_on_non_human_task] == Enum.map(violations, & &1.code)
      assert hd(violations).message =~ "Node 'gw'"
    end

    test "valid neighbour: create/2 accepts a well-shaped required_outputs (and null)" do
      tenant = tenant!("req461-create-ok")

      for value <- [["decision"], [], nil] do
        graph = decision_graph("approver", %{"required_outputs" => value})

        assert {:ok, _} =
                 Definitions.create(create_attrs(unique("req461-def"), graph),
                   prefix: tenant.schema_name
                 )
      end
    end

    test "create/2 does NOT reject a key with no variable_schema (check 2 cannot run before the schema rows exist)" do
      tenant = tenant!("req461-create-noschema")
      graph = decision_graph("approver", %{"required_outputs" => ["decision"]})

      assert {:ok, definition} =
               Definitions.create(create_attrs(unique("req461-def"), graph),
                 prefix: tenant.schema_name
               )

      assert definition.status == :draft
    end

    test "update/3 rejects a non-list required_outputs with :invalid_required_outputs and leaves the stored graph untouched" do
      tenant = tenant!("req461-update-bad")
      good_graph = decision_graph("approver", %{"required_outputs" => ["decision"]})
      definition = create!(tenant.schema_name, good_graph)

      bad_graph = decision_graph("approver", %{"required_outputs" => %{"decision" => true}})

      assert {:error, {:graph_validation_failed, [violation]}} =
               Definitions.update(definition.id, %{graph: bad_graph}, prefix: tenant.schema_name)

      assert violation.code == :invalid_required_outputs
      assert violation.message =~ "Node 't'"

      assert {:ok, reread} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert reread.graph == definition.graph
    end

    test "valid neighbour: update/3 accepts a well-shaped required_outputs" do
      tenant = tenant!("req461-update-ok")
      definition = create!(tenant.schema_name, decision_graph("approver", %{}))

      new_graph = decision_graph("approver", %{"required_outputs" => ["decision"]})

      assert {:ok, updated} =
               Definitions.update(definition.id, %{graph: new_graph}, prefix: tenant.schema_name)

      assert updated.graph["nodes"]
             |> Enum.find(&(&1["id"] == "t"))
             |> get_in(["attributes", "required_outputs"]) == ["decision"]
    end
  end

  # ---------------------------------------------------------------------------------------
  # Check 2 -- validate and activate
  # ---------------------------------------------------------------------------------------

  describe "check 2 at validate_definition_graph/2 and activate/2" do
    test "validate reports the missing variable_schema when the definition has NO variable_schemas at all (empty-declared_fields trap)" do
      tenant = tenant!("req461-v2-empty")

      definition =
        create!(
          tenant.schema_name,
          decision_graph("approver", %{"required_outputs" => ["decision"]})
        )

      assert {:ok, %{valid: false, violations: [violation]}} =
               Definitions.validate_definition_graph(definition.id, prefix: tenant.schema_name)

      assert violation.code == :required_output_without_variable_schema
      assert violation.message =~ "Node 't'"
      assert violation.message =~ "'decision'"
    end

    test "validate reports it too when OTHER variable_schemas exist (non-empty declared_fields)" do
      tenant = tenant!("req461-v2-nonempty")

      definition =
        create!(
          tenant.schema_name,
          decision_graph("approver", %{"required_outputs" => ["decision"]})
        )

      assert {:ok, 1} =
               Definitions.register_variable_schemas(
                 definition.id,
                 [%{variable_key: "note", json_schema: %{"type" => "string"}}],
                 prefix: tenant.schema_name
               )

      assert {:ok, %{valid: false, violations: [violation]}} =
               Definitions.validate_definition_graph(definition.id, prefix: tenant.schema_name)

      assert violation.code == :required_output_without_variable_schema
      assert violation.message =~ "'decision'"
    end

    test "valid neighbour: with a variable_schema for the key, validate is valid with no violations" do
      tenant = tenant!("req461-v2-ok")

      definition =
        create!(
          tenant.schema_name,
          decision_graph("approver", %{"required_outputs" => ["decision"]})
        )

      register_decision_schema!(tenant.schema_name, definition.id)

      assert {:ok, %{valid: true, violations: []}} =
               Definitions.validate_definition_graph(definition.id, prefix: tenant.schema_name)
    end

    test "activate refuses with {:semantic_validation_failed, [violation]} and the definition stays DRAFT; registering the schema then lets it activate" do
      tenant = tenant!("req461-act")

      definition =
        create!(
          tenant.schema_name,
          decision_graph("approver", %{"required_outputs" => ["decision"]})
        )

      assert {:error, {:semantic_validation_failed, [violation]}} =
               Definitions.activate(definition.id, prefix: tenant.schema_name)

      assert violation.code == :required_output_without_variable_schema
      assert violation.message =~ "Node 't'"
      assert violation.message =~ "'decision'"

      assert {:ok, %{status: :draft}} =
               Definitions.get_by_id(definition.id, prefix: tenant.schema_name)

      register_decision_schema!(tenant.schema_name, definition.id)

      assert {:ok, %{definition: %{status: :active}}} =
               Definitions.activate(definition.id, prefix: tenant.schema_name)
    end
  end

  # ---------------------------------------------------------------------------------------
  # Check 3 -- WARNING in validate and the pack-install result, not in activate
  # ---------------------------------------------------------------------------------------

  describe "check 3 at validate_definition_graph/2 and activate/2" do
    test "validate stays valid and carries the decision_key_not_required: warning naming the key, definition and edge" do
      tenant = tenant!("req461-w3-validate")
      definition = create!(tenant.schema_name, decision_graph("approver", %{}))
      register_decision_schema!(tenant.schema_name, definition.id)

      assert {:ok, %{valid: true, violations: [], warnings: warnings}} =
               Definitions.validate_definition_graph(definition.id, prefix: tenant.schema_name)

      assert [line] = decision_lines(warnings)
      assert line =~ "decision"
      assert line =~ definition.name
      assert line =~ "'e-cond'"
    end

    test "valid neighbour: required_outputs: [decision] on the task yields no decision_key_not_required: warning" do
      tenant = tenant!("req461-w3-declared")

      definition =
        create!(
          tenant.schema_name,
          decision_graph("approver", %{"required_outputs" => ["decision"]})
        )

      register_decision_schema!(tenant.schema_name, definition.id)

      assert {:ok, %{valid: true, warnings: warnings}} =
               Definitions.validate_definition_graph(definition.id, prefix: tenant.schema_name)

      assert decision_lines(warnings) == []
    end

    test "a key no HUMAN_TASK produces yields no warning (the form collects a different key)" do
      tenant = tenant!("req461-w3-noproducer")

      graph =
        decision_graph("approver", %{
          "form_schema" => %{"properties" => %{"note" => %{"type" => "string"}}}
        })

      definition = create!(tenant.schema_name, graph)

      assert {:ok, %{warnings: warnings}} =
               Definitions.validate_definition_graph(definition.id, prefix: tenant.schema_name)

      assert decision_lines(warnings) == []
    end

    test "activate succeeds for a definition that WOULD warn, and its result carries no warning" do
      tenant = tenant!("req461-w3-activate")
      definition = create!(tenant.schema_name, decision_graph("approver", %{}))
      register_decision_schema!(tenant.schema_name, definition.id)

      assert {:ok, %{warnings: [_ | _]}} =
               Definitions.validate_definition_graph(definition.id, prefix: tenant.schema_name)

      assert {:ok, result} = Definitions.activate(definition.id, prefix: tenant.schema_name)
      assert result.definition.status == :active
      refute Map.has_key?(result, :warnings)
      refute inspect(result) =~ "decision_key_not_required"
    end
  end

  # ---------------------------------------------------------------------------------------
  # ValidationWarnings.for_definitions/2
  # ---------------------------------------------------------------------------------------

  describe "ValidationWarnings.for_definitions/2" do
    defp parsed!(graph_map) do
      assert {:ok, graph} = Graph.from_map(graph_map)
      graph
    end

    test "concatenates RoleBinding warnings first, then decision-key warnings; every element is a string" do
      tenant = tenant!("req461-vw-order")
      role_1 = unique("role-unbound-1")
      role_2 = unique("role-unbound-2")
      name_1 = unique("req461-vw-def")
      name_2 = unique("req461-vw-def")

      definitions = [
        {name_1, parsed!(decision_graph(role_1, %{}))},
        {name_2, parsed!(decision_graph(role_2, %{}))}
      ]

      warnings = ValidationWarnings.for_definitions(definitions, prefix: tenant.schema_name)

      assert Enum.all?(warnings, &is_binary/1)

      role_idx =
        for {w, i} <- Enum.with_index(warnings),
            String.starts_with?(w, "unbound_task_role:"),
            do: i

      decision_idx =
        for {w, i} <- Enum.with_index(warnings),
            String.starts_with?(w, "decision_key_not_required:"),
            do: i

      assert length(role_idx) == 2
      assert length(decision_idx) == 2
      assert Enum.max(role_idx) < Enum.min(decision_idx)

      # Decision warnings follow input order of the definitions.
      [first, second] = Enum.map(decision_idx, &Enum.at(warnings, &1))
      assert first =~ name_1
      assert second =~ name_2
    end

    test "valid neighbour: an empty definition list and a clean definition both yield []" do
      tenant = tenant!("req461-vw-empty")

      assert ValidationWarnings.for_definitions([], prefix: tenant.schema_name) == []

      clean =
        {unique("req461-vw-def"),
         parsed!(decision_graph("approver", %{"required_outputs" => ["decision"]}))}

      warnings = ValidationWarnings.for_definitions([clean], prefix: tenant.schema_name)
      assert decision_lines(warnings) == []
    end
  end

  # ---------------------------------------------------------------------------------------
  # Pack install
  # ---------------------------------------------------------------------------------------

  describe "SolutionPack.install/3" do
    defp cleanup_installs!(tenant_id) do
      on_exit(fn ->
        Repo.delete_all(from(s in SolutionPackInstall, where: s.tenant_id == ^tenant_id))
        Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      end)
    end

    defp pack_document(definitions, variable_schemas) do
      %{
        "pack_id" => Ecto.UUID.generate(),
        "version" => "1.0.0",
        "bpm_export_schema_version" => Letflow.Definitions.ExportImport.export_schema_version(),
        "exported_at" => "2026-01-01T00:00:00Z",
        "definitions" => definitions,
        "service_catalog_entries" => [],
        "variable_schemas" => variable_schemas,
        "manifest" => %{"required_roles" => []}
      }
    end

    defp packed_definition(source_id, name, graph) do
      %{
        "definition_id" => source_id,
        "process_key" => name,
        "name" => name,
        "version" => "1.0.0",
        "graph" => graph
      }
    end

    defp packed_decision_schema(source_id) do
      %{
        "definition_id" => source_id,
        "schema_name" => "decision",
        "schema_content" => Jason.encode!(@decision_schema)
      }
    end

    test "the install result carries the decision_key_not_required: warning for an undeclared decision key; the install still succeeds" do
      tenant = tenant!("req461-pack-warn")
      cleanup_installs!(tenant.tenant_id)
      name = unique("req461-pack-def")
      source_id = Ecto.UUID.generate()

      document =
        pack_document(
          [packed_definition(source_id, name, decision_graph("approver", %{}))],
          [packed_decision_schema(source_id)]
        )

      assert {:ok, result} =
               SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name)

      assert [%{status: "installed"}] = result.installed_definitions
      assert [line] = decision_lines(result.warnings)
      assert line =~ "decision"
      assert line =~ name
      assert Enum.all?(result.warnings, &is_binary/1)
    end

    test "valid neighbour: with required_outputs: [decision] the install result has no decision_key_not_required: warning" do
      tenant = tenant!("req461-pack-clean")
      cleanup_installs!(tenant.tenant_id)
      source_id = Ecto.UUID.generate()

      document =
        pack_document(
          [
            packed_definition(
              source_id,
              unique("req461-pack-def"),
              decision_graph("approver", %{"required_outputs" => ["decision"]})
            )
          ],
          [packed_decision_schema(source_id)]
        )

      assert {:ok, result} =
               SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name)

      assert decision_lines(result.warnings) == []
    end

    test "check 2 does not run at install: a key with no variable_schema installs (it is caught at validate/activate)" do
      tenant = tenant!("req461-pack-check2")
      cleanup_installs!(tenant.tenant_id)
      name = unique("req461-pack-def")
      source_id = Ecto.UUID.generate()

      document =
        pack_document(
          [
            packed_definition(
              source_id,
              name,
              decision_graph("approver", %{"required_outputs" => ["decision"]})
            )
          ],
          []
        )

      assert {:ok, result} =
               SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name)

      assert [%{status: "installed"}] = result.installed_definitions

      definition =
        Repo.get_by!(Definitions.ProcessDefinition, [name: name], prefix: tenant.schema_name)

      assert {:ok, %{valid: false, violations: [violation]}} =
               Definitions.validate_definition_graph(definition.id, prefix: tenant.schema_name)

      assert violation.code == :required_output_without_variable_schema
    end

    test "check 1 runs at install: a non-list required_outputs fails the install and stores nothing" do
      tenant = tenant!("req461-pack-shape")
      cleanup_installs!(tenant.tenant_id)
      source_id = Ecto.UUID.generate()

      document =
        pack_document(
          [
            packed_definition(
              source_id,
              unique("req461-pack-def"),
              decision_graph("approver", %{"required_outputs" => "decision"})
            )
          ],
          []
        )

      assert {:error, reason} =
               SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name)

      assert inspect(reason) =~ "invalid_required_outputs"
      assert definition_count(tenant.schema_name) == 0
    end
  end
end
