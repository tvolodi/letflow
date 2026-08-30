defmodule Letflow.Routers.AdminServicesTest do
  @moduledoc """
  Router-level tests for `Letflow.Routers.AdminServices`'s `GET /`
  (list-all) handler (REQ-192). See `test/specs/REQ-192.md` for the
  acceptance-criterion -> test-case mapping and rationale. Design authority:
  `lib/letflow/design/req192-service-catalog-routes.md` §5 (the `list_all/1`
  addition) and §13 (the 403 test pattern).

  **Scope, deliberately narrow** (per the WF02-REQ192-20260830 Step 3
  handoff, which re-scoped TEST-DESIGNER's work to only what's new/different
  for `list_all/1` and this one endpoint's admin gate): only
  `GET /admin/services` is covered here -- its authorization enforcement,
  its cross-tenant visibility end to end through the HTTP layer, and its
  `SCA:`/`SC:` cursor cross-endpoint isolation (INV-9) as exercised through
  this router specifically. `POST`/`PATCH`/`DELETE /admin/services...` and
  `Letflow.Routers.Services`'s `GET /services` are explicitly OUT of this
  file's scope -- not yet covered by any test file as of this handoff, and
  not requested by the Step 3 task that produced this file. A future
  test-design pass should add them separately.

  Uses `Letflow.DataCase` (real Postgres, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1). Dispatch is direct
  `Letflow.Routers.AdminServices.call/2` with `conn.assigns[:auth_context]`
  set directly (bypassing `Letflow.Plugs.AuthPipeline` entirely) --
  matching `test/letflow/routers/tenants_test.exs`'s and
  `test/letflow/routers/dlq_test.exs`'s own established idiom for this class
  of router test: `Letflow.Plugs.Authorize` (mounted by `use
  Letflow.Api.AuthorizedRouter`) reads `conn.assigns.auth_context` directly,
  so nothing about the handler under test depends on how that assign got
  populated. There is no `401 Unauthorized` concept in
  `Letflow.Plugs.Authorize` (see its own moduledoc) -- an unauthenticated
  caller is represented here, same as elsewhere in this codebase's router
  tests, by an `auth_context` whose `roles` list is empty, which this plug
  denies with the identical `403` a wrong-but-authenticated role gets.

  `async: false`: `service_catalog` is a GLOBAL table with no tenant schema
  and no sandboxed-transaction isolation across it -- same reasoning
  `test/letflow/service_catalog_test.exs` documents for itself. Every row
  this file creates is deleted in `on_exit/1`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Identity.Tenant
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry

  @opts Letflow.Routers.AdminServices.init([])

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ── Shared test dispatch helper (matches tenants_test.exs's build_conn/4 shape) ──

  defp build_conn(method, path, tenant_id, fields) do
    roles = Keyword.get(fields, :roles, [])

    conn(method, path)
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.AdminServices.call(conn, @opts)

  # ── Fixture helpers (mirrors test/letflow/service_catalog_test.exs's own precedent) ──

  defp unique_service_id(prefix \\ "req192-admin-router-svc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp insert_tenant!(slug_prefix \\ "req192-admin-router-tenant") do
    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug(slug_prefix),
          display_name: "REQ-192 AdminServices Router Test Tenant"
        },
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn -> Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id)) end)

    tenant
  end

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp register!(overrides) do
    attrs =
      %{
        service_id: unique_service_id(),
        endpoint_url: "https://example.test/svc",
        required_auth: :NONE,
        timeout_ms: 5_000,
        scope: :global
      }
      |> Map.merge(overrides)

    on_exit(fn -> cleanup_entry!(attrs.service_id) end)
    assert {:ok, entry} = ServiceCatalog.register(attrs)
    entry
  end

  # ══════════════════════════════════════════════════════════════════════
  # GET /admin/services authorization enforcement (Step 3 handoff item #3)
  # ══════════════════════════════════════════════════════════════════════

  describe "GET /admin/services as a non-PLATFORM_ADMIN caller" do
    test "returns 403 before ever reaching list_all/1 -- no service data leaked in the body" do
      tenant = insert_tenant!()
      entry = register!(%{scope: :global})

      resp =
        build_conn(:get, "/", tenant.id, roles: ["PROCESS_DESIGNER"])
        |> dispatch()

      assert resp.status == 403

      assert Jason.decode!(resp.resp_body) == %{
               "type" => "https://bpm.example.com/problems/forbidden",
               "title" => "Forbidden",
               "status" => 403,
               "detail" => "insufficient permissions",
               "trace_id" => "fixed-test-trace-id"
             }

      refute resp.resp_body =~ entry.service_id
      refute resp.resp_body =~ "items"
    end

    test "a caller with :ServicesRead's backing role (e.g. PROCESS_OPERATOR) is still denied -- :AdminServicesRead requires :UsersGroupsRolesManage, held only by PLATFORM_ADMIN" do
      tenant = insert_tenant!()

      resp = build_conn(:get, "/", tenant.id, roles: ["PROCESS_OPERATOR"]) |> dispatch()

      assert resp.status == 403
    end

    test "a caller with no roles at all (this codebase's proxy for 'unauthenticated', per Letflow.Plugs.Authorize's own moduledoc) is denied identically" do
      tenant = insert_tenant!()

      resp = build_conn(:get, "/", tenant.id, roles: []) |> dispatch()

      assert resp.status == 403

      assert Jason.decode!(resp.resp_body)["detail"] == "insufficient permissions"
    end
  end

  describe "GET /admin/services as PLATFORM_ADMIN" do
    test "succeeds (200) and the response body includes rows owned by tenants other than the caller's own -- list_all/1's cross-tenant visibility, end to end through the HTTP layer" do
      caller_tenant = insert_tenant!("req192-admin-router-caller")
      other_tenant_a = insert_tenant!("req192-admin-router-other-a")
      other_tenant_b = insert_tenant!("req192-admin-router-other-b")

      entry_a = register!(%{scope: :tenant, owner_tenant_id: other_tenant_a.id})
      entry_b = register!(%{scope: :tenant, owner_tenant_id: other_tenant_b.id})

      resp =
        build_conn(:get, "/?page_size=200", caller_tenant.id, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Map.keys(body) |> Enum.sort() == ["items", "next_cursor"]

      ids = Enum.map(body["items"], & &1["service_id"])

      # Neither entry is owned by caller_tenant, yet both are present in the
      # response -- list_all/1 performs no tenant filtering whatsoever,
      # unlike list_for_tenant/2 (Letflow.Routers.Services's GET /services).
      assert entry_a.service_id in ids
      assert entry_b.service_id in ids

      owner_ids_seen =
        body["items"]
        |> Enum.filter(&(&1["service_id"] in [entry_a.service_id, entry_b.service_id]))
        |> Enum.map(& &1["owner_tenant_id"])
        |> Enum.uniq()
        |> Enum.sort()

      assert owner_ids_seen == Enum.sort([other_tenant_a.id, other_tenant_b.id])
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # SC:/SCA: cross-endpoint cursor isolation (INV-9), exercised through this
  # router specifically (Step 3 handoff item #2). The context-module-level
  # version of this same guarantee lives in test/letflow/service_catalog_test.exs.
  # ══════════════════════════════════════════════════════════════════════

  describe "GET /admin/services INV-9: a list_for_tenant/2-minted (SC:) cursor is rejected" do
    test "a cursor minted via Letflow.ServiceCatalog.list_for_tenant/2 is rejected with 400 'invalid cursor' when replayed against this endpoint" do
      tenant = insert_tenant!()
      register!(%{scope: :global})
      register!(%{scope: :global})

      assert {:ok, %{next_cursor: sc_cursor}} =
               ServiceCatalog.list_for_tenant(%{page_size: 1}, tenant.id)

      assert is_binary(sc_cursor)

      resp =
        build_conn(
          :get,
          "/?page_size=1&cursor=#{sc_cursor}",
          tenant.id,
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert resp.status == 400
      assert Jason.decode!(resp.resp_body)["detail"] == "invalid cursor"
    end

    test "a cursor minted via this same endpoint (SCA:) round-trips successfully -- confirms the 400 above is about cross-endpoint isolation, not a broken cursor pipeline" do
      tenant = insert_tenant!()
      register!(%{scope: :global})
      register!(%{scope: :global})

      first_resp =
        build_conn(:get, "/?page_size=1", tenant.id, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert first_resp.status == 200
      %{"next_cursor" => sca_cursor} = Jason.decode!(first_resp.resp_body)
      assert is_binary(sca_cursor)

      second_resp =
        build_conn(
          :get,
          "/?page_size=1&cursor=#{sca_cursor}",
          tenant.id,
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert second_resp.status == 200
    end
  end
end
