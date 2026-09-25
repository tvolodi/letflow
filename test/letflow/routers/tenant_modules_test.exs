defmodule Letflow.Routers.TenantModulesTest do
  @moduledoc """
  Tests for `Letflow.Routers.TenantModules` (REQ-403) — the HTTP install
  path onto 0039 D5. See
  `lib/letflow/design/req403-module-install-route.md` for the full design.
  ELIXIR-DEV inline coverage (this project's established convention when
  the design is fully specified — no separate TEST-DESIGNER dispatch).

  Covers AC1 (role gate, no row written on 403), AC2 (INV-1 — a
  body-supplied `tenant_id`/`tenant` never redirects the write), AC3
  (404/409/422 error mapping).

  Dispatch strategy: real `Letflow.Routers.TenantModules.call/2`, mirroring
  `test/letflow/routers/tenant_settings_test.exs`'s own established
  convention — `use Letflow.Api.AuthorizedRouter` wires
  `plug(:match) -> plug(Letflow.Plugs.Authorize) -> plug(:dispatch)`, so
  this exercises the REAL authorization plug over a real `Plug.Conn`.

  `async: false` — tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)` (`TenantFixture.provisioned_tenant!/1`'s
  own requirement).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.TenantFixture

  @opts Letflow.Routers.TenantModules.init([])

  defp build_conn(tenant_id, roles, body) do
    conn(:post, "/")
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req403-tenant-modules-test-trace-id")
  end

  defp install(tenant_id, roles, body) do
    build_conn(tenant_id, roles, body)
    |> Letflow.Routers.TenantModules.call(@opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # ═══════════════════════════════════════════════════════════════════════
  # AC1 — 201 for PLATFORM_ADMIN, 403 for every other role, no row on 403
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC1 -- role gate" do
    test "201 for PLATFORM_ADMIN, 403 for every other role, no tenant_modules row written on a 403" do
      %{tenant_id: tenant_id, schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac1")

      for role <- Authorization.roles(), role != :PLATFORM_ADMIN do
        conn = install(tenant_id, [Atom.to_string(role)], %{"module_id" => "fixture"})

        assert conn.status == 403,
               "expected 403 for role #{inspect(role)}, got #{conn.status}"

        assert Installs.list_installed(prefix: prefix) == []
      end

      conn = install(tenant_id, ["PLATFORM_ADMIN"], %{"module_id" => "fixture"})

      assert conn.status == 201
      body = json(conn)
      assert body["module_id"] == "fixture"
      assert body["version"] == "0.1.0"
      assert is_binary(body["installed_at"])

      assert [%TenantModule{module_id: "fixture"}] = Installs.list_installed(prefix: prefix)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC2 — a body-supplied tenant_id/tenant is ignored (INV-1)
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC2 -- prefix is server-derived only, a body tenant_id/tenant is ignored" do
    test "installing as tenant A's PLATFORM_ADMIN with tenant B named in the body lands only in tenant A" do
      %{tenant_id: tenant_id_a, schema_name: prefix_a} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac2-a")

      %{tenant_id: tenant_id_b, schema_name: prefix_b} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac2-b")

      conn =
        install(tenant_id_a, ["PLATFORM_ADMIN"], %{
          "module_id" => "fixture",
          "tenant_id" => tenant_id_b,
          "tenant" => tenant_id_b
        })

      assert conn.status == 201

      assert [%TenantModule{module_id: "fixture"}] = Installs.list_installed(prefix: prefix_a)
      assert Installs.list_installed(prefix: prefix_b) == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC3 — error mapping: 404 unknown module, 409 already installed,
  # 422 missing dependency
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC3 -- error mapping" do
    test "404 for an unknown module id" do
      %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac3-404")

      conn = install(tenant_id, ["PLATFORM_ADMIN"], %{"module_id" => "does-not-exist"})

      assert conn.status == 404
    end

    test "409 for a second install of the same module" do
      %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac3-409")

      assert install(tenant_id, ["PLATFORM_ADMIN"], %{"module_id" => "fixture"}).status == 201

      conn = install(tenant_id, ["PLATFORM_ADMIN"], %{"module_id" => "fixture"})

      assert conn.status == 409
    end

    test "422 for a module whose depends_on is not installed" do
      %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac3-422")

      conn = install(tenant_id, ["PLATFORM_ADMIN"], %{"module_id" => "fixture_dependent"})

      assert conn.status == 422
      assert json(conn)["detail"] =~ "fixture"
    end

    test "422 when the request body is not a JSON object or module_id is missing/not a string" do
      %{tenant_id: tenant_id} = TenantFixture.provisioned_tenant!(slug_prefix: "req403-ac3-body")

      assert install(tenant_id, ["PLATFORM_ADMIN"], %{}).status == 422
      assert install(tenant_id, ["PLATFORM_ADMIN"], %{"module_id" => 123}).status == 422
    end
  end
end
