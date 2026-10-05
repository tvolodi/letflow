defmodule Letflow.Routers.PlatformScopeShadowTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 items 5, 14 and 19, A2 ENFORCING variants (converted
  in place from the A1 legacy + shadow-log assertions; the file name is kept so the A2 diff stays
  reviewable, TEST-DESIGNER may rename it): the 21 platform-scope routes (design 7.1) and the
  router catch-alls under enforcement. A2 deleted the legacy forcing and the shadow log.

  Cases per route (tenants: P = platform tenant, A = ordinary):

    * A `PLATFORM_ADMIN`, pin set to P: 403, no row written;
    * P `PLATFORM_ADMIN`: reaches the handler (not 403);
    * P and A `PROCESS_DESIGNER`: 403;
    * pin unset, P `PLATFORM_ADMIN`: 403 (fail closed).

  Handlers are reached only with nonexistent ids and empty bodies, so no row is written; the
  tenant row count is asserted unchanged around every group.

  Item 19 (`uniform_403_platform_prefixes_for_non_operators`) lives in the second `describe`: for
  the five prefixes the 403 of a matched route, a matched route with a nonexistent resource, an
  unmatched sub-path and a bare unmatched path are byte-identical for every non-operator
  (`PROCESS_DESIGNER`, a tenant `PLATFORM_ADMIN`, an unpinned platform `PLATFORM_ADMIN`), while the
  platform-tenant `PLATFORM_ADMIN` keeps the router's 404 on an unmatched path.

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @unused_uuid "00000000-0000-4000-8000-000000000001"

  # {router, method, declared local pattern, concrete local path, body, policy key}
  @routes [
    {Letflow.Routers.Tenants, :post, "/", "/", %{}, :TenantsManage},
    {Letflow.Routers.Tenants, :get, "/", "/", nil, :TenantsManage},
    {Letflow.Routers.Tenants, :get, "/:slug", "/no-such-slug", nil, :TenantsManage},
    {Letflow.Routers.Tenants, :patch, "/:slug", "/no-such-slug", %{}, :TenantsManage},
    {Letflow.Routers.Tenants, :post, "/:slug/deactivate", "/no-such-slug/deactivate", nil,
     :TenantsManage},
    {Letflow.Routers.Tenants, :post, "/:slug/reactivate", "/no-such-slug/reactivate", nil,
     :TenantsManage},
    {Letflow.Routers.Onboarding, :post, "/", "/", %{}, :TenantsManage},
    {Letflow.Routers.Onboarding, :get, "/:id", "/" <> @unused_uuid, nil, :TenantsManage},
    {Letflow.Routers.Onboarding, :get, "/", "/", nil, :TenantsManage},
    {Letflow.Routers.PlatformMigrations, :post, "/rollouts", "/rollouts", %{}, :TenantsManage},
    {Letflow.Routers.PlatformMigrations, :get, "/rollouts/:id", "/rollouts/" <> @unused_uuid, nil,
     :TenantsManage},
    {Letflow.Routers.PlatformMigrations, :post, "/rollouts/:id/resume",
     "/rollouts/" <> @unused_uuid <> "/resume", nil, :TenantsManage},
    {Letflow.Routers.EventRetention, :get, "/summary", "/summary", nil, :TenantsManage},
    {Letflow.Routers.EventRetention, :post, "/retirements", "/retirements", %{}, :TenantsManage},
    {Letflow.Routers.EventRetention, :get, "/retirements/:id", "/retirements/" <> @unused_uuid,
     nil, :TenantsManage},
    {Letflow.Routers.AdminServices, :get, "/", "/", nil, :AdminServicesRead},
    {Letflow.Routers.AdminServices, :post, "/", "/", %{}, :AdminServicesManage},
    {Letflow.Routers.AdminServices, :patch, "/:service_id", "/no-such-service", %{},
     :AdminServicesManage},
    {Letflow.Routers.AdminServices, :delete, "/:service_id", "/no-such-service", nil,
     :AdminServicesManage},
    {Letflow.Routers.AdminServices, :post, "/:service_id/versions", "/no-such-service/versions",
     %{}, :AdminServicesManage},
    {Letflow.Routers.AdminServices, :post, "/:service_id/retire", "/no-such-service/retire", nil,
     :AdminServicesManage}
  ]

  @groups @routes |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  defp dispatch(router, conn), do: router.call(conn, router.init([]))

  defp request({router, method, _pattern, path, body, _key}, fixture, roles) do
    dispatch(router, Fixture.router_conn(method, path, fixture, roles, body))
  end

  defp tenant_count, do: Repo.aggregate(Tenant, :count, :id)

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  describe "declared routes" do
    test "the 21 snapshot rows declare the expected policy keys" do
      assert length(@routes) == 21

      for {router, method, pattern, _path, _body, key} <- @routes do
        verb = method |> Atom.to_string() |> String.upcase()

        assert {verb, pattern, key} in router.__authz_routes__(),
               "#{inspect(router)} does not declare #{verb} #{pattern} with #{inspect(key)}"
      end
    end
  end

  for router <- @groups do
    @router router

    describe "items 5 A2 enforcing: #{inspect(router)} platform routes" do
      test "A PLATFORM_ADMIN (a tenant that is not the platform tenant) is denied 403 on every route, no row written",
           ctx do
        before = tenant_count()

        for route <- @routes, elem(route, 0) == @router do
          resp = request(route, ctx.a, ["PLATFORM_ADMIN"])
          label = "#{elem(route, 1)} #{elem(route, 3)}"

          assert resp.status == 403, "#{label}: A's PLATFORM_ADMIN answered #{resp.status}"

          for secret <- [ctx.a.tenant_id, ctx.b.tenant_id, ctx.p.tenant_id, ctx.a.tenant.slug] do
            refute resp.resp_body =~ secret, "the 403 must carry no identifier: #{label}"
          end
        end

        assert tenant_count() == before
      end

      test "the platform tenant's PLATFORM_ADMIN reaches the handler (not 403)", ctx do
        before = tenant_count()

        for route <- @routes, elem(route, 0) == @router do
          resp = request(route, ctx.p, ["PLATFORM_ADMIN"])
          label = "#{elem(route, 1)} #{elem(route, 3)}"

          refute resp.status == 403, label
          assert resp.status < 500, "#{label} answered #{resp.status}"
        end

        assert tenant_count() == before
      end

      test "a PROCESS_DESIGNER of the platform tenant or of an ordinary tenant is denied 403",
           ctx do
        for route <- @routes, elem(route, 0) == @router, fixture <- [ctx.p, ctx.a] do
          resp = request(route, fixture, ["PROCESS_DESIGNER"])
          label = "#{elem(route, 1)} #{elem(route, 3)}"

          assert resp.status == 403, label

          body = Jason.decode!(resp.resp_body)
          assert body["status"] == 403
          refute Map.has_key?(body, "items")
          refute resp.resp_body =~ ctx.a.tenant.slug
          refute resp.resp_body =~ ctx.b.tenant.slug
        end
      end

      test "pin unset: the would-be operator is denied 403 on every route (fail closed)", ctx do
        Fixture.unpin!()
        before = tenant_count()

        for route <- @routes, elem(route, 0) == @router do
          resp = request(route, ctx.p, ["PLATFORM_ADMIN"])
          assert resp.status == 403, "#{elem(route, 1)} #{elem(route, 3)}"
        end

        assert tenant_count() == before
      end
    end
  end

  describe "item 14 (A2): GET /tenants through the full pipeline, no shadow log any more" do
    test "A PLATFORM_ADMIN gets 403; P PLATFORM_ADMIN gets 200; no shadow line is logged", ctx do
      token_a = Fixture.mint_token!(ctx.a, ["PLATFORM_ADMIN"])
      token_p = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])

      {resp_a, log_a} =
        ExUnit.CaptureLog.with_log([level: :warning], fn ->
          Fixture.api_conn(:get, "/api/v1/tenants", token_a, ctx.a.tenant.slug, nil)
          |> Fixture.dispatch_api()
        end)

      assert resp_a.status == 403
      refute log_a =~ "platform_scope_shadow_deny"

      {resp_p, log_p} =
        ExUnit.CaptureLog.with_log([level: :warning], fn ->
          Fixture.api_conn(:get, "/api/v1/tenants", token_p, ctx.p.tenant.slug, nil)
          |> Fixture.dispatch_api()
        end)

      assert resp_p.status == 200
      refute log_p =~ "platform_scope_shadow_deny"
    end

    test "a tenant-scope route stays 200 for a tenant PLATFORM_ADMIN", ctx do
      token_a = Fixture.mint_token!(ctx.a, ["PLATFORM_ADMIN"])

      resp =
        Fixture.api_conn(:get, "/api/v1/promotions", token_a, ctx.a.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert resp.status == 200
    end
  end

  describe "item 5(e): a token minted in tenant A presented with the platform tenant's slug" do
    test "is rejected 401 and does not reach any platform route", ctx do
      token_a = Fixture.mint_token!(ctx.a, ["PLATFORM_ADMIN"])

      for path <- ["/api/v1/tenants", "/api/v1/admin/services", "/api/v1/onboarding"] do
        resp =
          Fixture.api_conn(:get, path, token_a, ctx.p.tenant.slug, nil) |> Fixture.dispatch_api()

        assert resp.status == 401, "#{path}: #{resp.status}"
      end
    end
  end

  describe "item 19 (A2): the five platform prefixes" do
    # {router, existing-resource path, nonexistent-resource path, unmatched sub-path}
    @prefixes [
      {Letflow.Routers.Tenants, :slug_of_b, "/no-such-slug", "/x/y/z/w"},
      {Letflow.Routers.Onboarding, "/", "/" <> @unused_uuid, "/x/y/z/w"},
      {Letflow.Routers.PlatformMigrations, "/rollouts/" <> @unused_uuid,
       "/rollouts/" <> @unused_uuid, "/x/y/z/w"},
      {Letflow.Routers.EventRetention, "/summary", "/retirements/" <> @unused_uuid, "/x/y/z/w"},
      {Letflow.Routers.AdminServices, "/", "/no-such-service", "/x/y/z/w"}
    ]

    defp prefix_requests(router, existing, nonexistent, unmatched, fixture, roles, ctx) do
      existing = if existing == :slug_of_b, do: "/" <> ctx.b.tenant.slug, else: existing

      [
        {:matched_existing, :get, existing},
        {:matched_nonexistent, :get, nonexistent},
        {:unmatched_subpath, :get, unmatched},
        {:unmatched_bare, :delete, "/"}
      ]
      |> Enum.map(fn {label, method, path} ->
        {label, dispatch(router, Fixture.router_conn(method, path, fixture, roles, nil))}
      end)
    end

    test "PROCESS_DESIGNER callers get the same 403 problem+json bytes on all four request shapes",
         ctx do
      for {router, existing, nonexistent, unmatched} <- @prefixes,
          fixture <- [ctx.a, ctx.p] do
        responses =
          prefix_requests(
            router,
            existing,
            nonexistent,
            unmatched,
            fixture,
            ["PROCESS_DESIGNER"],
            ctx
          )

        for {label, resp} <- responses do
          assert resp.status == 403, "#{inspect(router)} #{label}: #{resp.status}"
        end

        bodies = responses |> Enum.map(fn {_l, r} -> r.resp_body end) |> Enum.uniq()

        types =
          responses
          |> Enum.map(fn {_l, r} -> get_resp_header(r, "content-type") end)
          |> Enum.uniq()

        assert length(bodies) == 1, "#{inspect(router)}: bodies differ #{inspect(bodies)}"
        assert length(types) == 1
        assert hd(hd(types)) =~ ~r/application\/problem\+json/
      end
    end

    test "non-operators get the same 403 bytes on matched and unmatched paths; the operator keeps 404",
         ctx do
      for {router, existing, nonexistent, unmatched} <- @prefixes do
        Fixture.pin!(ctx.p.tenant_id)

        # reference body: a PROCESS_DESIGNER denial (same denial builder)
        [{_l, reference} | _] =
          prefix_requests(
            router,
            existing,
            nonexistent,
            unmatched,
            ctx.a,
            ["PROCESS_DESIGNER"],
            ctx
          )

        # a tenant PLATFORM_ADMIN (A): identical 403 bytes on every request shape
        for {label, resp} <-
              prefix_requests(
                router,
                existing,
                nonexistent,
                unmatched,
                ctx.a,
                ["PLATFORM_ADMIN"],
                ctx
              ) do
          assert resp.status == 403, "#{inspect(router)} #{label}: #{resp.status}"
          assert resp.resp_body == reference.resp_body, "#{inspect(router)} #{label}"
        end

        # the platform tenant's PLATFORM_ADMIN keeps the router's 404 on unmatched paths
        for {label, method, path} <- [
              {:subpath, :get, unmatched},
              {:bare, :delete, "/"},
              {:post, :post, "/x/y/z/w"}
            ] do
          resp =
            dispatch(router, Fixture.router_conn(method, path, ctx.p, ["PLATFORM_ADMIN"], %{}))

          assert resp.status == 404, "#{inspect(router)} operator #{label}: #{resp.status}"
        end

        # pin unset: nobody is the operator, the would-be operator gets the uniform 403
        Fixture.unpin!()

        for {label, resp} <-
              prefix_requests(
                router,
                existing,
                nonexistent,
                unmatched,
                ctx.p,
                ["PLATFORM_ADMIN"],
                ctx
              ) do
          assert resp.status == 403, "#{inspect(router)} unpinned #{label}: #{resp.status}"
          assert resp.resp_body == reference.resp_body
        end
      end
    end

    test "ordinary routers (:UnmatchedRoute): PLATFORM_ADMIN reaches the 404, other roles get 403",
         ctx do
      ordinary = [
        Letflow.Routers.Identity,
        Letflow.Routers.Audit,
        Letflow.Routers.Definitions,
        Letflow.Routers.Promotions,
        Letflow.Routers.Services,
        Letflow.Routers.TenantSettings
      ]

      for router <- ordinary, fixture <- [ctx.a, ctx.p] do
        admin =
          dispatch(
            router,
            Fixture.router_conn(:get, "/x/y/z/w", fixture, ["PLATFORM_ADMIN"], nil)
          )

        assert admin.status == 404, "#{inspect(router)}: #{admin.status}"

        denied =
          dispatch(
            router,
            Fixture.router_conn(:get, "/x/y/z/w", fixture, ["PROCESS_DESIGNER"], nil)
          )

        assert denied.status == 403, "#{inspect(router)}: #{denied.status}"
      end
    end

    test "the 404 an administrator reaches on an unmatched path is the zero-detail not-found response",
         ctx do
      resp =
        dispatch(
          Letflow.Routers.Tenants,
          Fixture.router_conn(:get, "/x/y/z/w", ctx.p, ["PLATFORM_ADMIN"], nil)
        )

      body = Jason.decode!(resp.resp_body)
      assert body["status"] == 404
      assert body["title"] == "Not Found"
    end
  end
end
