defmodule Letflow.Routers.PlatformScopeShadowTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 items 5, 14 and 19, A1 variants (spec
  `test/specs/ISS-0993-A1.md`): the 21 platform-scope routes (design 7.1) and the router
  catch-alls, under the A1 LEGACY enforcement plus the shadow evaluation.

  In A1 `Letflow.Plugs.Authorize` enforces with `platform_tenant?` forced to `true`, so a
  `PLATFORM_ADMIN` of ANY tenant still reaches the handler (today's behaviour, asserted here as
  "not 403"), and it ALSO evaluates the decision with the real value: when that differs, exactly
  one `platform_scope_shadow_deny key=<PolicyKey> platform_tenant=<boolean>` warning is logged,
  carrying no tenant id, user id, role, slug or token. A2 deletes the forcing and the log line;
  the A1-variant assertions flip to the enforcing ones (403 for every non-operator) there.

  Cases per route (tenants: P = platform tenant, A = ordinary):

    * A `PLATFORM_ADMIN`, pin set to P: legacy result (not 403) AND one shadow line, flag false;
    * P `PLATFORM_ADMIN`: legacy result (not 403), NO shadow line;
    * P and A `PROCESS_DESIGNER`: 403, no shadow line (both decisions agree);
    * pin unset, P `PLATFORM_ADMIN`: legacy result (not 403) AND one shadow line, flag false.

  Handlers are reached only with nonexistent ids and empty bodies, so no row is written; the
  tenant row count is asserted unchanged around every group.

  Item 19 (`uniform_403_platform_prefixes_for_non_operators`, A1 variant) lives in the second
  `describe`: for the five prefixes the `PROCESS_DESIGNER` denials of a matched route, a matched
  route with a nonexistent resource, an unmatched sub-path and a bare unmatched path are
  byte-identical (the 403 is produced by the same denial builder), and the legacy outcome of the
  `:UnmatchedPlatformPath` / `:UnmatchedRoute` markers is asserted for administrators.

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin, shared log).
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

  # Runs `fun`, returns {result, shadow lines of the captured log}.
  defp with_shadow(fun) do
    {result, log} =
      ExUnit.CaptureLog.with_log([level: :warning], fn -> fun.() end)

    {result, Fixture.shadow_lines(log)}
  end

  defp assert_shadow_line(line, key) do
    assert line =~ ~r/platform_scope_shadow_deny key=#{key} platform_tenant=false\s*$/,
           "shadow line has an unexpected shape: #{inspect(line)}"
  end

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

    describe "items 5/14 A1 variant: #{inspect(router)} platform routes" do
      test "A PLATFORM_ADMIN keeps the legacy result and trips exactly one shadow line per request",
           ctx do
        before = tenant_count()

        for route <- @routes, elem(route, 0) == @router do
          {resp, lines} = with_shadow(fn -> request(route, ctx.a, ["PLATFORM_ADMIN"]) end)
          label = "#{elem(route, 1)} #{elem(route, 3)}"

          refute resp.status == 403, "legacy: #{label} reaches the handler for A's PLATFORM_ADMIN"
          assert resp.status < 500, "#{label} answered #{resp.status}"

          assert [line] = lines,
                 "#{label}: expected exactly one shadow line, got #{inspect(lines)}"

          assert_shadow_line(line, elem(route, 5))

          for secret <- [
                ctx.a.tenant_id,
                ctx.b.tenant_id,
                ctx.p.tenant_id,
                ctx.a.tenant.slug,
                ctx.p.tenant.slug,
                "PLATFORM_ADMIN"
              ] do
            refute line =~ secret, "the shadow line must carry no identifier: #{inspect(line)}"
          end
        end

        assert tenant_count() == before
      end

      test "the platform tenant's PLATFORM_ADMIN keeps the legacy result and trips no shadow line",
           ctx do
        before = tenant_count()

        for route <- @routes, elem(route, 0) == @router do
          {resp, lines} = with_shadow(fn -> request(route, ctx.p, ["PLATFORM_ADMIN"]) end)
          label = "#{elem(route, 1)} #{elem(route, 3)}"

          refute resp.status == 403, label
          assert resp.status < 500, "#{label} answered #{resp.status}"
          assert lines == [], "#{label}: unexpected shadow lines #{inspect(lines)}"
        end

        assert tenant_count() == before
      end

      test "a PROCESS_DESIGNER of the platform tenant or of an ordinary tenant is denied 403 with no shadow line",
           ctx do
        for route <- @routes, elem(route, 0) == @router, fixture <- [ctx.p, ctx.a] do
          {resp, lines} = with_shadow(fn -> request(route, fixture, ["PROCESS_DESIGNER"]) end)
          label = "#{elem(route, 1)} #{elem(route, 3)}"

          assert resp.status == 403, label
          assert lines == [], label

          body = Jason.decode!(resp.resp_body)
          assert body["status"] == 403
          refute Map.has_key?(body, "items")
          refute resp.resp_body =~ ctx.a.tenant.slug
          refute resp.resp_body =~ ctx.b.tenant.slug
        end
      end

      test "pin unset: the legacy result stands for the would-be operator, with one shadow line",
           ctx do
        Fixture.unpin!()
        before = tenant_count()

        for route <- @routes, elem(route, 0) == @router do
          {resp, lines} = with_shadow(fn -> request(route, ctx.p, ["PLATFORM_ADMIN"]) end)
          label = "#{elem(route, 1)} #{elem(route, 3)}"

          refute resp.status == 403, label
          assert [line] = lines, label
          assert_shadow_line(line, elem(route, 5))
        end

        assert tenant_count() == before
      end
    end
  end

  describe "item 14: shadow line on GET /tenants through the full pipeline" do
    test "A PLATFORM_ADMIN gets 200 and exactly one shadow line; P PLATFORM_ADMIN gets 200 and none",
         ctx do
      token_a = Fixture.mint_token!(ctx.a, ["PLATFORM_ADMIN"])
      token_p = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])

      {resp_a, lines_a} =
        with_shadow(fn ->
          Fixture.api_conn(:get, "/api/v1/tenants", token_a, ctx.a.tenant.slug, nil)
          |> Fixture.dispatch_api()
        end)

      assert resp_a.status == 200
      assert [line] = lines_a
      assert line =~ ~r/platform_scope_shadow_deny key=TenantsManage platform_tenant=false\s*$/

      for secret <- [
            ctx.a.tenant_id,
            ctx.p.tenant_id,
            ctx.a.tenant.slug,
            "PLATFORM_ADMIN",
            token_a
          ] do
        refute line =~ secret
      end

      {resp_p, lines_p} =
        with_shadow(fn ->
          Fixture.api_conn(:get, "/api/v1/tenants", token_p, ctx.p.tenant.slug, nil)
          |> Fixture.dispatch_api()
        end)

      assert resp_p.status == 200
      assert lines_p == []
    end

    test "a request that is allowed under both evaluations (tenant-scope route) emits no line",
         ctx do
      token_a = Fixture.mint_token!(ctx.a, ["PLATFORM_ADMIN"])

      {resp, lines} =
        with_shadow(fn ->
          Fixture.api_conn(:get, "/api/v1/promotions", token_a, ctx.a.tenant.slug, nil)
          |> Fixture.dispatch_api()
        end)

      assert resp.status == 200
      assert lines == []
    end

    test "the log line carries only the policy key and one boolean (fixed form)", ctx do
      {_resp, lines} = with_shadow(fn -> request(hd(@routes), ctx.a, ["PLATFORM_ADMIN"]) end)

      assert [line] = lines
      [_prefix, tail] = String.split(line, "platform_scope_shadow_deny", parts: 2)
      assert String.trim(tail) == "key=TenantsManage platform_tenant=false"
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

  describe "item 19 A1 variant: the five platform prefixes" do
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

    test "legacy: an unmatched path answers 404 for a PLATFORM_ADMIN of any tenant (operator included, pin unset included)",
         ctx do
      for pin <- [:p, :none],
          {router, _e, _n, unmatched} <- @prefixes,
          fixture <- [ctx.p, ctx.a] do
        if pin == :none, do: Fixture.unpin!(), else: Fixture.pin!(ctx.p.tenant_id)

        for {label, method, path} <- [
              {:subpath, :get, unmatched},
              {:bare, :delete, "/"},
              {:post, :post, "/x/y/z/w"}
            ] do
          resp =
            dispatch(router, Fixture.router_conn(method, path, fixture, ["PLATFORM_ADMIN"], %{}))

          assert resp.status == 404, "#{inspect(router)} #{label} pin=#{pin}: #{resp.status}"
        end
      end
    end

    test "the platform tenant's PLATFORM_ADMIN gets 404 with no shadow line on an unmatched platform path",
         ctx do
      for {router, _e, _n, unmatched} <- @prefixes do
        {resp, lines} =
          with_shadow(fn ->
            dispatch(router, Fixture.router_conn(:get, unmatched, ctx.p, ["PLATFORM_ADMIN"], nil))
          end)

        assert resp.status == 404
        assert lines == []
      end
    end

    test "an ordinary tenant's PLATFORM_ADMIN on an unmatched platform path: legacy 404 plus one shadow line for the marker key",
         ctx do
      {resp, lines} =
        with_shadow(fn ->
          dispatch(
            Letflow.Routers.Tenants,
            Fixture.router_conn(:get, "/x/y/z/w", ctx.a, ["PLATFORM_ADMIN"], nil)
          )
        end)

      assert resp.status == 404
      assert [line] = lines
      assert_shadow_line(line, "UnmatchedPlatformPath")
    end

    test "ordinary routers (:UnmatchedRoute): PLATFORM_ADMIN reaches the 404, other roles get 403, no shadow line",
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
        {admin, admin_lines} =
          with_shadow(fn ->
            dispatch(
              router,
              Fixture.router_conn(:get, "/x/y/z/w", fixture, ["PLATFORM_ADMIN"], nil)
            )
          end)

        assert admin.status == 404, "#{inspect(router)}: #{admin.status}"
        assert admin_lines == []

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
