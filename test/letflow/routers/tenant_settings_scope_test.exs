defmodule Letflow.Routers.TenantSettingsScopeTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 item 6 (specs `test/specs/ISS-0993-A1.md`, `ISS-0993-A2.md`):
  `PATCH /tenant/settings` is an own-tenant, tenant-scope operation (`:TenantSettingsManage`),
  not the platform registry permission.

    * an ordinary tenant's `TENANT_ADMIN` is allowed (200) and changes ONLY its own row; an
      ordinary tenant's `PLATFORM_ADMIN` holds nothing there any more (403, REQ-447 PR 2);
    * a `PROCESS_DESIGNER` of an ordinary tenant is denied 403, and its row is unchanged;
    * the platform tenant's `PLATFORM_ADMIN` is allowed on its own row;
    * no tenant-bearing request value (body or query) redirects the write to another tenant.

  The outcome does not depend on the platform pin (tenant-scope key). Existing coverage in `tenant_settings_test.exs` is untouched.

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  defp patch(fixture, roles, body, path \\ "/") do
    Letflow.Routers.TenantSettings.call(
      Fixture.router_conn(:patch, path, fixture, roles, body),
      Letflow.Routers.TenantSettings.init([])
    )
  end

  defp settings_of(fixture), do: Repo.get!(Tenant, fixture.tenant_id).settings

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  test "the route declares :TenantSettingsManage" do
    assert {"PATCH", "/", :TenantSettingsManage} in Letflow.Routers.TenantSettings.__authz_routes__()
  end

  test "an ordinary tenant's TENANT_ADMIN gets 200 and changes only its own settings", ctx do
    b_before = settings_of(ctx.b)
    p_before = settings_of(ctx.p)

    resp = patch(ctx.a, ["TENANT_ADMIN"], %{"app_name" => "Scope Test A"})

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["tenant_id"] == ctx.a.tenant_id
    assert body["settings"]["app_name"] == "Scope Test A"

    assert settings_of(ctx.a)["app_name"] == "Scope Test A"
    assert settings_of(ctx.b) == b_before
    assert settings_of(ctx.p) == p_before
  end

  test "a PROCESS_DESIGNER of an ordinary tenant gets 403 and nothing is written", ctx do
    before = settings_of(ctx.a)

    resp = patch(ctx.a, ["PROCESS_DESIGNER"], %{"app_name" => "Denied"})

    assert resp.status == 403
    assert Jason.decode!(resp.resp_body)["status"] == 403
    assert settings_of(ctx.a) == before
  end

  test "an ordinary tenant's PLATFORM_ADMIN gets 403 and nothing is written (legacy removed)",
       ctx do
    before = settings_of(ctx.a)

    resp = patch(ctx.a, ["PLATFORM_ADMIN"], %{"app_name" => "Denied"})

    assert resp.status == 403
    assert settings_of(ctx.a) == before
  end

  test "no role other than TENANT_ADMIN (or the platform tenant's PLATFORM_ADMIN) may patch settings",
       ctx do
    before = settings_of(ctx.a)

    denied = ["PROCESS_OPERATOR", "TASK_WORKER", "AGENT_RUNNER", "CANDIDATE", "PLATFORM_ADMIN"]

    for role <- denied do
      assert patch(ctx.a, [role], %{"app_name" => "Denied"}).status == 403, role
    end

    assert patch(ctx.a, [], %{"app_name" => "Denied"}).status == 403
    assert settings_of(ctx.a) == before
  end

  test "the platform tenant's PLATFORM_ADMIN gets 200 on its own row only", ctx do
    a_before = settings_of(ctx.a)

    resp = patch(ctx.p, ["PLATFORM_ADMIN"], %{"app_name" => "Scope Test P"})

    assert resp.status == 200
    assert Jason.decode!(resp.resp_body)["tenant_id"] == ctx.p.tenant_id
    assert settings_of(ctx.p)["app_name"] == "Scope Test P"
    assert settings_of(ctx.a) == a_before
  end

  test "the outcome does not depend on the platform pin (tenant scope)", ctx do
    Fixture.unpin!()

    resp = patch(ctx.a, ["TENANT_ADMIN"], %{"app_name" => "Unpinned"})
    assert resp.status == 200
    assert settings_of(ctx.a)["app_name"] == "Unpinned"
  end

  test "a tenant identifier in the body or in the query string never redirects the write", ctx do
    b_before = settings_of(ctx.b)

    resp =
      patch(
        ctx.a,
        ["TENANT_ADMIN"],
        %{"app_name" => "Own Only", "tenant_id" => ctx.b.tenant_id, "slug" => ctx.b.tenant.slug},
        "/?tenant_id=#{ctx.b.tenant_id}&slug=#{ctx.b.tenant.slug}"
      )

    assert resp.status == 200
    assert Jason.decode!(resp.resp_body)["tenant_id"] == ctx.a.tenant_id
    assert settings_of(ctx.a)["app_name"] == "Own Only"
    assert settings_of(ctx.b) == b_before
  end
end
