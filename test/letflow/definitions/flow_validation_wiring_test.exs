defmodule Letflow.Definitions.FlowValidationWiringTest do
  @moduledoc """
  DB-backed tests proving REQ-455's flow checks are wired into the real call paths:
  `Definitions.create/2`, `Definitions.update/3`, `Definitions.activate/2` (a DRAFT
  stored before the checks existed cannot be activated) and
  `Definitions.validate_definition_graph/2`, plus the OQ-1 default (an already ACTIVE
  definition is not re-validated at activate and is not deactivated). See
  `test/specs/REQ-455.md`.

  Uses `Letflow.DataCase` (real Postgres), one provisioned tenant per test, unique
  names, no wall-clock-dependent assertion.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Repo
  alias Letflow.TenantFixture

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp attrs(graph) do
    %{
      name: unique("req455-wiring"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  # ISS-0928 shape: a gateway whose only outgoing edges are conditional.
  defp gateway_without_default do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "kyc-routing", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "approved", "node_type" => "END"},
        %{"id" => "rejected", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "kyc-routing"},
        %{
          "id" => "e2",
          "source" => "kyc-routing",
          "target" => "approved",
          "condition" => "risk == \"low\""
        },
        %{
          "id" => "e3",
          "source" => "kyc-routing",
          "target" => "rejected",
          "condition" => "risk == \"high\""
        }
      ]
    }
  end

  defp gateway_with_default do
    put_in(gateway_without_default(), ["edges"], [
      %{"id" => "e1", "source" => "start", "target" => "kyc-routing"},
      %{
        "id" => "e2",
        "source" => "kyc-routing",
        "target" => "approved",
        "condition" => "risk == \"low\""
      },
      %{"id" => "e3", "source" => "kyc-routing", "target" => "rejected", "is_default" => true}
    ])
  end

  # Connected island x<->y beside a valid start->end.
  defp island_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"},
        %{"id" => "x", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "y", "node_type" => "EXCLUSIVE_GATEWAY"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "end"},
        %{"id" => "e2", "source" => "x", "target" => "y", "condition" => "amount > 100"},
        %{"id" => "e3", "source" => "y", "target" => "x", "is_default" => true},
        %{"id" => "e4", "source" => "x", "target" => "end", "is_default" => true}
      ]
    }
  end

  # Bypasses create/2 -- stands for a DRAFT stored before REQ-455's checks existed.
  defp insert_legacy_draft!(schema_name, graph) do
    %ProcessDefinition{}
    |> ProcessDefinition.create_changeset(attrs(graph))
    |> Repo.insert!(prefix: schema_name)
  end

  defp definition_count(schema_name),
    do:
      Repo.aggregate(from(d in ProcessDefinition, select: d.id), :count, :id, prefix: schema_name)

  describe "create/2 and update/3 refuse the new violations" do
    test "ISS-0928 gateway shape is rejected by create/2 with :no_default_route naming the gateway, and writes no row" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-create")

      assert {:error, {:graph_validation_failed, violations}} =
               Definitions.create(attrs(gateway_without_default()), prefix: tenant.schema_name)

      assert [%{code: :no_default_route, message: message}] = violations
      assert message =~ "Node 'kyc-routing'"
      assert definition_count(tenant.schema_name) == 0
    end

    test "valid neighbour: the same gateway with a default edge is accepted by create/2" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-create-ok")

      assert {:ok, _definition} =
               Definitions.create(attrs(gateway_with_default()), prefix: tenant.schema_name)
    end

    test "an unreachable island is rejected by create/2 with one :unreachable_node per island node" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-create-island")

      assert {:error, {:graph_validation_failed, violations}} =
               Definitions.create(attrs(island_graph()), prefix: tenant.schema_name)

      assert Enum.map(violations, & &1.code) == [:unreachable_node, :unreachable_node]
      assert Enum.any?(violations, &(&1.message =~ "Node 'x'"))
      assert Enum.any?(violations, &(&1.message =~ "Node 'y'"))
    end

    test "update/3 refuses a graph that introduces a missing default route, leaving the stored graph unchanged" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-update")

      assert {:ok, definition} =
               Definitions.create(attrs(gateway_with_default()), prefix: tenant.schema_name)

      assert {:error, {:graph_validation_failed, violations}} =
               Definitions.update(definition.id, %{graph: gateway_without_default()},
                 prefix: tenant.schema_name
               )

      assert Enum.map(violations, & &1.code) == [:no_default_route]

      assert {:ok, reread} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert reread.graph == definition.graph
    end
  end

  describe "activate/2 and validate_definition_graph/2" do
    test "a legacy DRAFT with a missing default route is refused at activate with :no_default_route and stays :draft" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-activate")
      draft = insert_legacy_draft!(tenant.schema_name, gateway_without_default())

      assert {:error, {:semantic_validation_failed, violations}} =
               Definitions.activate(draft.id, prefix: tenant.schema_name)

      assert [%{code: :no_default_route, message: message}] = violations
      assert message =~ "Node 'kyc-routing'"

      assert {:ok, reread} = Definitions.get_by_id(draft.id, prefix: tenant.schema_name)
      assert reread.status == :draft
    end

    test "a legacy DRAFT with an unreachable island is refused at activate" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-activate-island")
      draft = insert_legacy_draft!(tenant.schema_name, island_graph())

      assert {:error, {:semantic_validation_failed, violations}} =
               Definitions.activate(draft.id, prefix: tenant.schema_name)

      assert Enum.map(violations, & &1.code) == [:unreachable_node, :unreachable_node]
    end

    test "valid neighbour: a legacy-style DRAFT whose gateway has a default activates" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-activate-ok")
      draft = insert_legacy_draft!(tenant.schema_name, gateway_with_default())

      assert {:ok, %{definition: %{status: :active}, already_active: false}} =
               Definitions.activate(draft.id, prefix: tenant.schema_name)
    end

    test "validate_definition_graph/2 reports the new violation for a stored definition" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-validate-read")
      draft = insert_legacy_draft!(tenant.schema_name, gateway_without_default())

      assert {:ok, %{valid: false, violations: violations}} =
               Definitions.validate_definition_graph(draft.id, prefix: tenant.schema_name)

      assert Enum.map(violations, & &1.code) == [:no_default_route]
    end

    test "OQ-1: an already ACTIVE definition that now fails a new check is not re-validated at activate and is not deactivated" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-oq1")

      assert {:ok, definition} =
               Definitions.create(attrs(gateway_with_default()), prefix: tenant.schema_name)

      assert {:ok, %{already_active: false}} =
               Definitions.activate(definition.id, prefix: tenant.schema_name)

      # Simulate a definition that was valid when activated but fails today's checks.
      {1, _} =
        Repo.update_all(
          from(d in ProcessDefinition, where: d.id == ^definition.id),
          [set: [graph: gateway_without_default()]],
          prefix: tenant.schema_name
        )

      assert {:ok, %{definition: still_active, already_active: true}} =
               Definitions.activate(definition.id, prefix: tenant.schema_name)

      assert still_active.status == :active

      assert {:ok, reread} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert reread.status == :active
    end
  end
end
