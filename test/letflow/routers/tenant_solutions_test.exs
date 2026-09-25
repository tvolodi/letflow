defmodule Letflow.Routers.TenantSolutionsTest do
  @moduledoc """
  Tests for `POST /api/v1/tenant/solutions` (REQ-415) — HTTP layer for
  `Letflow.Modules.Solutions.install/3`.

  Covers:
  - AC4 (HTTP): 201 for PLATFORM_ADMIN; 403 for other 5 roles; 409 when exam
    already installed; 404 for path-traversal and unknown solution ids.
  - AC5 (HTTP): two-tenant isolation — solution install by tenant A writes
    rows only in tenant A's schema.

  Dispatch strategy: real `Letflow.Routers.TenantSolutions.call/2`, matching
  `test/letflow/routers/tenant_modules_test.exs`'s established convention
  (real authorization plug over a real Plug.Conn). `async: false` — tenant
  provisioning/migration replay needs `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Modules.Installs
  alias Letflow.TenantFixture

  @opts Letflow.Routers.TenantSolutions.init([])

  defp build_conn(tenant_id, roles, body) do
    conn(:post, "/")
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req415-tenant-solutions-test-trace-id")
  end

  defp install_solution(tenant_id, roles, body) do
    build_conn(tenant_id, roles, body)
    |> Letflow.Routers.TenantSolutions.call(@opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 — 201 for PLATFORM_ADMIN, 403 for every other role
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC4 -- role gate" do
    test "201 for PLATFORM_ADMIN; 403 for every other role; no row written on 403" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req415-ac4-role")

      for role <- Authorization.roles(), role != :PLATFORM_ADMIN do
        conn =
          install_solution(tenant_id, [Atom.to_string(role)], %{"solution_id" => "fixture-bundle"})

        assert conn.status == 403,
               "expected 403 for role #{inspect(role)}, got #{conn.status}"
      end

      # Confirm no rows were written by the 403 attempts
      assert Installs.list_installed(prefix: prefix) == []

      conn = install_solution(tenant_id, ["PLATFORM_ADMIN"], %{"solution_id" => "fixture-bundle"})
      assert conn.status == 201

      body = json(conn)
      assert is_list(body["installed_modules"])
      assert length(body["installed_modules"]) == 2

      module_ids = Enum.map(body["installed_modules"], & &1["module_id"])
      assert "fixture" in module_ids
      assert "fixture_dependent" in module_ids
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 — 409 when a module in the solution is already installed
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC4 -- 409 when exam already installed" do
    test "returns 409 when exam is already installed in the tenant" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req415-ac4-409")

      # Clean up solution_pack_installs (global FK to tenants) AFTER
      # provisioned_tenant!'s teardown is registered so ExUnit's LIFO ordering
      # runs this cleanup FIRST, satisfying the FK before the tenants row is
      # deleted. Same pattern as backfill_exam_tenant_modules_test.exs.
      on_exit(fn ->
        import Ecto.Query, only: [from: 2]
        Letflow.Repo.delete_all(from(s in SolutionPackInstall, where: s.tenant_id == ^tenant_id))
      end)

      actor_id = Ecto.UUID.generate()
      assert {:ok, _} = Installs.install("exam", actor_id, prefix: prefix)

      conn = install_solution(tenant_id, ["PLATFORM_ADMIN"], %{"solution_id" => "bilimbaga"})
      assert conn.status == 409
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 — 404 for path traversal, uppercase, and unknown ids
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC4 -- 404 for invalid/unknown solution ids" do
    test "404 for path traversal attempt '../config'" do
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req415-ac4-traversal")

      conn = install_solution(tenant_id, ["PLATFORM_ADMIN"], %{"solution_id" => "../config"})
      assert conn.status == 404
    end

    test "404 for uppercase solution id 'BILIMBAGA'" do
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req415-ac4-upper")

      conn = install_solution(tenant_id, ["PLATFORM_ADMIN"], %{"solution_id" => "BILIMBAGA"})
      assert conn.status == 404
    end

    test "404 for unknown solution id 'nope'" do
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req415-ac4-nope")

      conn = install_solution(tenant_id, ["PLATFORM_ADMIN"], %{"solution_id" => "nope"})
      assert conn.status == 404
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC5 — two-tenant isolation
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC5 -- tenant isolation" do
    test "solution install by tenant A writes rows only in tenant A's schema" do
      %{tenant_id: tenant_id_a, schema_name: prefix_a} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req415-ac5-a")

      %{schema_name: prefix_b} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req415-ac5-b")

      conn =
        install_solution(tenant_id_a, ["PLATFORM_ADMIN"], %{"solution_id" => "fixture-bundle"})

      assert conn.status == 201

      installed_a = Installs.list_installed(prefix: prefix_a)
      installed_b = Installs.list_installed(prefix: prefix_b)

      assert length(installed_a) == 2
      assert installed_b == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Malformed request body
  # ═══════════════════════════════════════════════════════════════════════

  describe "malformed request body" do
    test "422 when solution_id is missing from the body" do
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req415-body-missing")

      conn = install_solution(tenant_id, ["PLATFORM_ADMIN"], %{})
      assert conn.status == 422
    end

    test "422 when solution_id is not a string" do
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req415-body-type")

      conn = install_solution(tenant_id, ["PLATFORM_ADMIN"], %{"solution_id" => 42})
      assert conn.status == 422
    end
  end
end
