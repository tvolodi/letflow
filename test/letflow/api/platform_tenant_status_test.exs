defmodule Letflow.Api.PlatformTenantStatusTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 item 9 (spec `test/specs/ISS-0993-A2.md`): the platform
  tenant cannot be deactivated, and the deactivated-tenant exemption belongs to the platform
  operator only.

    * `POST /tenants/<P slug>/deactivate` (as the operator) answers 409 and the row is unchanged;
    * `Identity.deactivate_tenant/1` called directly with P's slug returns
      `{:error, :platform_tenant_protected}` and the row is unchanged (the guard is in the context,
      not only in the router);
    * with no platform tenant configured nothing is protected: deactivating (and reactivating) a
      tenant still works, including the tenant that would have been the platform tenant;
    * `PATCH /tenants/<P slug>` with `status: inactive` ignores `status` (it is not in the PATCH
      allowlist) and leaves the row unchanged;
    * a `PLATFORM_ADMIN` of an INACTIVE non-platform tenant is halted 403 `tenant_inactive` by
      `Letflow.Plugs.TenantStatus`, with the pin set and with the pin unset, both when the plug is
      called directly and through the full `Letflow.Router` with a real bearer token; the platform
      tenant's `PLATFORM_ADMIN` stays exempt; every other role of an inactive tenant is halted too.

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn, only: [assign: 3]
  import Plug.Test, only: [conn: 2]

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Plugs.TenantStatus
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  defp tenants_call(method, path, fixture, roles, body) do
    Letflow.Routers.Tenants.call(
      Fixture.router_conn(method, path, fixture, roles, body),
      Letflow.Routers.Tenants.init([])
    )
  end

  defp row(fixture), do: Repo.get!(Tenant, fixture.tenant_id)

  defp set_status!(fixture, status) do
    fixture.tenant |> Tenant.status_changeset(%{status: status}) |> Repo.update!()
  end

  defp status_plug(fixture, roles) do
    conn(:get, "/whatever")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: fixture.tenant_id,
      roles: roles
    })
    |> TenantStatus.call(TenantStatus.init([]))
  end

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  describe "the platform tenant cannot be deactivated" do
    test "POST /tenants/<P slug>/deactivate is 409 and the row is unchanged", ctx do
      before = row(ctx.p)

      resp =
        tenants_call(:post, "/#{ctx.p.tenant.slug}/deactivate", ctx.p, ["PLATFORM_ADMIN"], nil)

      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["status"] == 409
      refute resp.resp_body =~ ctx.p.tenant_id

      assert row(ctx.p) == before
      assert row(ctx.p).status == :active
    end

    test "Identity.deactivate_tenant/1 on P returns :platform_tenant_protected, row unchanged",
         ctx do
      before = row(ctx.p)

      assert Identity.deactivate_tenant(ctx.p.tenant.slug) == {:error, :platform_tenant_protected}
      assert row(ctx.p) == before
    end

    test "an ordinary tenant is deactivated and reactivated through the same path", ctx do
      assert {:ok, %Tenant{status: :inactive}} = Identity.deactivate_tenant(ctx.a.tenant.slug)
      assert row(ctx.a).status == :inactive

      assert {:ok, %Tenant{status: :active}} = Identity.reactivate_tenant(ctx.a.tenant.slug)
      assert row(ctx.a).status == :active

      resp =
        tenants_call(:post, "/#{ctx.b.tenant.slug}/deactivate", ctx.p, ["PLATFORM_ADMIN"], nil)

      assert resp.status == 200
      assert row(ctx.b).status == :inactive
    end

    test "reactivating the platform tenant is allowed (it only ever sets :active)", ctx do
      assert {:ok, %Tenant{status: :active}} = Identity.reactivate_tenant(ctx.p.tenant.slug)
    end

    test "with no platform tenant configured nothing is protected", ctx do
      Fixture.unpin!()

      assert {:ok, %Tenant{status: :inactive}} = Identity.deactivate_tenant(ctx.p.tenant.slug)
      assert row(ctx.p).status == :inactive

      assert {:ok, %Tenant{status: :inactive}} = Identity.deactivate_tenant(ctx.a.tenant.slug)
      assert row(ctx.a).status == :inactive
    end

    test "the guard follows the configuration: pinning another tenant frees P and protects it",
         ctx do
      Fixture.pin!(ctx.a.tenant_id)

      assert Identity.deactivate_tenant(ctx.a.tenant.slug) == {:error, :platform_tenant_protected}
      assert {:ok, %Tenant{status: :inactive}} = Identity.deactivate_tenant(ctx.p.tenant.slug)
    end

    test "an unknown slug is :not_found, not :platform_tenant_protected" do
      assert Identity.deactivate_tenant("no-such-slug-iss0993") == {:error, :not_found}
    end
  end

  describe "PATCH /tenants/<P slug> cannot deactivate" do
    test "a status key is ignored; the row's status is unchanged", ctx do
      before = row(ctx.p)

      resp =
        tenants_call(:patch, "/#{ctx.p.tenant.slug}", ctx.p, ["PLATFORM_ADMIN"], %{
          "status" => "inactive",
          "display_name" => "Renamed Platform"
        })

      assert resp.status == 200
      after_row = row(ctx.p)
      assert after_row.status == :active
      assert after_row.status == before.status
      assert after_row.slug == before.slug
      assert after_row.display_name == "Renamed Platform"
    end

    test "a body of only the status key changes nothing", ctx do
      before = row(ctx.p)

      resp =
        tenants_call(:patch, "/#{ctx.p.tenant.slug}", ctx.p, ["PLATFORM_ADMIN"], %{
          "status" => "inactive"
        })

      assert resp.status in [200, 422]
      assert row(ctx.p).status == before.status
      assert row(ctx.p).display_name == before.display_name
    end
  end

  describe "TenantStatus: the deactivated-tenant exemption is for the platform operator only" do
    test "a PLATFORM_ADMIN of an inactive ordinary tenant is halted 403 tenant_inactive (pin set and unset)",
         ctx do
      set_status!(ctx.a, :inactive)

      for pinned? <- [true, false] do
        if pinned?, do: Fixture.pin!(ctx.p.tenant_id), else: Fixture.unpin!()

        conn = status_plug(ctx.a, ["PLATFORM_ADMIN"])

        assert conn.halted, "pinned: #{pinned?}"
        assert conn.status == 403
        assert Jason.decode!(conn.resp_body)["error"] == "tenant_inactive"
      end
    end

    test "the same through the full pipeline with a real token (pin set and unset)", ctx do
      token = Fixture.mint_token!(ctx.a, ["PLATFORM_ADMIN"])
      set_status!(ctx.a, :inactive)

      for pinned? <- [true, false], path <- ["/api/v1/promotions", "/api/v1/tenants"] do
        if pinned?, do: Fixture.pin!(ctx.p.tenant_id), else: Fixture.unpin!()

        resp =
          Fixture.api_conn(:get, path, token, ctx.a.tenant.slug, nil) |> Fixture.dispatch_api()

        assert resp.status == 403, "#{path} pinned #{pinned?}: #{resp.status}"
        assert Jason.decode!(resp.resp_body)["error"] == "tenant_inactive"
      end
    end

    test "every other role of an inactive tenant is halted as well", ctx do
      set_status!(ctx.a, :inactive)

      for roles <- [["PROCESS_DESIGNER"], ["TASK_WORKER"], []] do
        conn = status_plug(ctx.a, roles)
        assert conn.halted and conn.status == 403, inspect(roles)
      end
    end

    test "the platform tenant's PLATFORM_ADMIN is exempt (control: the exemption still exists)",
         ctx do
      set_status!(ctx.p, :inactive)

      conn = status_plug(ctx.p, ["PLATFORM_ADMIN"])
      refute conn.halted

      # ... and only while the platform tenant is configured: with no pin nobody is exempt
      Fixture.unpin!()
      halted = status_plug(ctx.p, ["PLATFORM_ADMIN"])
      assert halted.halted and halted.status == 403
    end

    test "an active tenant's PLATFORM_ADMIN is not touched", ctx do
      refute status_plug(ctx.a, ["PLATFORM_ADMIN"]).halted
    end
  end
end
