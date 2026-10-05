defmodule Letflow.Api.PromoteSourceTenantTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 item 20, NAMED TEST `promote_route_source_tenant_equals_own`,
  A1 variant (spec `test/specs/ISS-0993-A1.md`): row 34, `POST /tenants/:test_tenant_id/promote/:process_key`.

  A1 asserts the LEGACY outcome only. The denial rule (a non-operator may name only its own tenant
  as source; any other id yields the same 404 bytes before any lookup) is covered at unit level by
  `test/letflow/api/tenant_target_test.exs` (design item 11); handlers do not call
  `Letflow.Api.TenantTarget` in A1, so there is no assertion on a shadow-position call and no
  assertion on queries against another tenant's schema here. The A2 variant (`async: false`, real
  Postgres) replaces the legacy expectations below with: (a) own id proceeds, (b)/(c) another
  tenant, nonexistent or malformed id -> identical 404 bytes with zero queries against the source
  schema, (d) the platform operator may name another tenant.

  Legacy results, each with a process key that no tenant defines:

    (a) an ordinary tenant's `PLATFORM_ADMIN` naming its own id: reaches the domain logic (404,
        source definition missing);
    (b) naming another EXISTING tenant: the same 404 (legacy: no ownership check);
    (c) a malformed id, a slug, an over-long string: the same 404;
    (d) the platform tenant's `PLATFORM_ADMIN` naming another tenant: the same 404.

  Also asserted: every response is the zero-detail 404 (identical bytes across the cases above),
  other roles get 403, and no log line is emitted (a tenant-scope key trips no shadow line).
  Not asserted: a never-provisioned (random) tenant id, which today raises inside the handler.

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  defp promote(fixture, source_id, roles) do
    Letflow.Routers.Tenants.call(
      Fixture.router_conn(
        :post,
        "/#{URI.encode(source_id, &URI.char_unreserved?/1)}/promote/no-such-process",
        fixture,
        roles,
        nil
      ),
      Letflow.Routers.Tenants.init([])
    )
  end

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  test "(a)-(d): the legacy outcome is the zero-detail 404 for every named source", ctx do
    {responses, log} =
      ExUnit.CaptureLog.with_log([level: :warning], fn ->
        [
          {"(a) own id", promote(ctx.a, ctx.a.tenant_id, ["PLATFORM_ADMIN"])},
          {"(a) own id, upper-case",
           promote(ctx.a, String.upcase(ctx.a.tenant_id), ["PLATFORM_ADMIN"])},
          {"(b) another existing tenant", promote(ctx.a, ctx.b.tenant_id, ["PLATFORM_ADMIN"])},
          {"(c) slug", promote(ctx.a, ctx.b.tenant.slug, ["PLATFORM_ADMIN"])},
          {"(c) not a uuid", promote(ctx.a, "not-a-uuid", ["PLATFORM_ADMIN"])},
          {"(c) over-long", promote(ctx.a, String.duplicate("x", 300), ["PLATFORM_ADMIN"])},
          {"(d) operator names another tenant",
           promote(ctx.p, ctx.b.tenant_id, ["PLATFORM_ADMIN"])},
          {"(d) operator names its own tenant",
           promote(ctx.p, ctx.p.tenant_id, ["PLATFORM_ADMIN"])}
        ]
      end)

    for {label, resp} <- responses do
      assert resp.status == 404, "#{label}: #{resp.status}"
    end

    bodies =
      responses
      |> Enum.map(fn {_l, r} -> Map.delete(Jason.decode!(r.resp_body), "trace_id") end)
      |> Enum.uniq()

    assert [%{"status" => 404, "title" => "Not Found"}] = bodies

    assert Fixture.shadow_lines(log) == []
  end

  test "pin unset: the outcome for the would-be operator is unchanged", ctx do
    Fixture.unpin!()
    assert promote(ctx.p, ctx.b.tenant_id, ["PLATFORM_ADMIN"]).status == 404
  end

  test "other roles are denied 403 whatever source they name", ctx do
    for roles <- [["PROCESS_DESIGNER"], ["TASK_WORKER"], []],
        fixture <- [ctx.a, ctx.p],
        source <- [fixture.tenant_id, ctx.b.tenant_id] do
      assert promote(fixture, source, roles).status == 403
    end
  end

  test "the route declares :PromotionsManage (tenant scope), not an unclassified key" do
    assert {"POST", "/:test_tenant_id/promote/:process_key", :PromotionsManage} in Letflow.Routers.Tenants.__authz_routes__()

    assert Letflow.Api.Authorization.permission_scope(:PromotionsManage) == :tenant
  end
end
