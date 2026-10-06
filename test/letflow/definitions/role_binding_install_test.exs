defmodule Letflow.Definitions.RoleBindingInstallTest do
  @moduledoc """
  DB-backed tests for REQ-455 check 4 (unbound task roles): `SolutionPack.install/3`,
  `Definitions.validate_definition_graph/2` and `POST /definitions/:id/validate`
  report every role a human task routes to that has no `tenant_role` row in the
  tenant, as a warning, and never bind anything. See `test/specs/REQ-455.md`.

  Uses `Letflow.DataCase` (real Postgres), one freshly provisioned tenant per test,
  `System.unique_integer/1`-suffixed names, no wall-clock-dependent assertion.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.Definitions.RoleBinding
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @definitions_opts Letflow.Routers.Definitions.init([])

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # solution_pack_installs / solution_pack_artefact_bases are GLOBAL tables holding an
  # FK to tenants; same LIFO on_exit cleanup solution_pack_test.exs documents.
  defp cleanup_solution_pack_installs!(tenant_id) do
    on_exit(fn ->
      Repo.delete_all(from(s in SolutionPackInstall, where: s.tenant_id == ^tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
    end)
  end

  defp role_row_count(schema_name),
    do: Repo.aggregate(TenantRole, :count, :id, prefix: schema_name)

  # start -> t1 (role) -> t2 (role, escalation_role) -> end : defaults satisfied, every
  # existing validator and every REQ-455 flow check passes, so only check 4 has anything
  # to say.
  defp two_task_graph(role_1, role_2, escalation_role) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "t1", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => role_1}},
        %{
          "id" => "t2",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{
            "role" => role_2,
            "escalation_role" => escalation_role,
            "escalation_timer_duration" => "PT2H"
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "t1"},
        %{"id" => "e2", "source" => "t1", "target" => "t2"},
        %{"id" => "e3", "source" => "t2", "target" => "end"}
      ]
    }
  end

  defp pack_document(definitions) do
    %{
      "pack_id" => Ecto.UUID.generate(),
      "version" => "1.0.0",
      "bpm_export_schema_version" => Letflow.Definitions.ExportImport.export_schema_version(),
      "exported_at" => "2026-01-01T00:00:00Z",
      "definitions" => definitions,
      "service_catalog_entries" => [],
      "variable_schemas" => [],
      "manifest" => %{"required_roles" => []}
    }
  end

  defp packed_definition(name, graph) do
    %{
      "definition_id" => Ecto.UUID.generate(),
      "process_key" => name,
      "name" => name,
      "version" => "1.0.0",
      "graph" => graph
    }
  end

  defp bind_role!(schema_name, role_name) do
    {:ok, group} = RoleRegistry.get_or_create_group_by_name(role_name, prefix: schema_name)

    assert {:ok, _} =
             RoleRegistry.upsert_role(role_name, :process_routing_role, group.id,
               prefix: schema_name
             )
  end

  defp warning_lines(warnings),
    do: Enum.filter(warnings, &String.starts_with?(&1, "unbound_task_role:"))

  describe "SolutionPack.install/3 -- unbound task roles are warned about, never bound" do
    test "an installed definition routing to unbound roles lists each role name (incl. escalation_role) in warnings; tenant_role row count is unchanged" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-install")
      cleanup_solution_pack_installs!(tenant.tenant_id)

      name = unique("req455-pack-def")
      unbound_1 = unique("role-unbound-a")
      unbound_2 = unique("role-unbound-b")
      unbound_esc = unique("role-unbound-esc")
      before_count = role_row_count(tenant.schema_name)

      document =
        pack_document([
          packed_definition(name, two_task_graph(unbound_1, unbound_2, unbound_esc))
        ])

      assert {:ok, result} =
               SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name)

      # The install itself still succeeds (advisory, not a gate).
      assert [%{status: "installed"}] = result.installed_definitions

      lines = warning_lines(result.warnings)
      assert length(lines) == 3
      assert Enum.any?(lines, &(&1 =~ unbound_1 and &1 =~ "t1" and &1 =~ name))
      assert Enum.any?(lines, &(&1 =~ unbound_2 and &1 =~ "t2"))
      assert Enum.any?(lines, &(&1 =~ unbound_esc and &1 =~ "t2"))

      # Binds nothing.
      assert role_row_count(tenant.schema_name) == before_count
      names = [prefix: tenant.schema_name] |> RoleRegistry.list_roles() |> Enum.map(& &1.name)
      refute unbound_1 in names
    end

    test "valid neighbour: roles already bound in the tenant are not warned about, only the unbound one is" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-install-bound")
      cleanup_solution_pack_installs!(tenant.tenant_id)

      bound = unique("role-bound")
      loose = unique("role-loose")
      bind_role!(tenant.schema_name, bound)
      before_count = role_row_count(tenant.schema_name)

      document =
        pack_document([
          packed_definition(unique("req455-pack-def"), two_task_graph(bound, bound, loose))
        ])

      assert {:ok, result} =
               SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name)

      lines = warning_lines(result.warnings)
      assert [line] = lines
      assert line =~ loose
      refute Enum.any?(result.warnings, &(&1 =~ bound))
      assert role_row_count(tenant.schema_name) == before_count
    end

    test "valid neighbour: a pack whose human tasks route only to bound roles yields no unbound_task_role warning" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-install-allbound")
      cleanup_solution_pack_installs!(tenant.tenant_id)

      bound = unique("role-bound")
      bind_role!(tenant.schema_name, bound)

      document =
        pack_document([
          packed_definition(unique("req455-pack-def"), two_task_graph(bound, bound, bound))
        ])

      assert {:ok, result} =
               SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name)

      assert warning_lines(result.warnings) == []
    end

    test "tenant isolation: a role bound in ANOTHER tenant does not count as bound" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req455-iso-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req455-iso-b")
      cleanup_solution_pack_installs!(tenant_b.tenant_id)

      role = unique("role-only-in-a")
      bind_role!(tenant_a.schema_name, role)

      document =
        pack_document([
          packed_definition(unique("req455-pack-def"), two_task_graph(role, role, role))
        ])

      assert {:ok, result} =
               SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant_b.schema_name)

      assert [line] = warning_lines(result.warnings)
      assert line =~ role
    end
  end

  describe "validate (context and HTTP) -- warnings are additive and advisory" do
    test "validate_definition_graph/2 returns valid: true with the unbound role in :warnings, and binds nothing" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-validate")
      role = unique("role-unbound-v")
      before_count = role_row_count(tenant.schema_name)

      assert {:ok, definition} =
               Definitions.create(
                 %{
                   name: unique("req455-def"),
                   version: "1.0.0",
                   graph: two_task_graph(role, role, role),
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: tenant.schema_name
               )

      assert {:ok, %{valid: true, violations: [], warnings: warnings}} =
               Definitions.validate_definition_graph(definition.id, prefix: tenant.schema_name)

      assert [line] = warnings

      assert line ==
               RoleBinding.format_warning(definition.name, %{
                 role_name: role,
                 node_ids: ["t1", "t2"]
               })

      assert role_row_count(tenant.schema_name) == before_count
    end

    test "valid neighbour: with the role bound, :warnings is []" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-validate-bound")
      role = unique("role-bound-v")
      bind_role!(tenant.schema_name, role)

      assert {:ok, definition} =
               Definitions.create(
                 %{
                   name: unique("req455-def"),
                   version: "1.0.0",
                   graph: two_task_graph(role, role, role),
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: tenant.schema_name
               )

      assert {:ok, %{valid: true, warnings: []}} =
               Definitions.validate_definition_graph(definition.id, prefix: tenant.schema_name)
    end

    test "POST /definitions/:id/validate 200 body carries the unbound role in \"warnings\" next to empty \"findings\"" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req455-http")
      role = unique("role-unbound-http")

      assert {:ok, definition} =
               Definitions.create(
                 %{
                   name: unique("req455-def"),
                   version: "1.0.0",
                   graph: two_task_graph(role, role, role),
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: tenant.schema_name
               )

      resp =
        conn(:post, "/#{definition.id}/validate")
        |> assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: tenant.tenant_id,
          roles: ["PLATFORM_ADMIN"]
        })
        |> assign(:trace_id, "req455-test-trace-id")
        |> Letflow.Routers.Definitions.call(@definitions_opts)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["status"] == "valid"
      assert body["findings"] == []
      assert [line] = body["warnings"]
      assert line =~ "unbound_task_role: #{role}"
    end
  end
end
