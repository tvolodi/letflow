defmodule Letflow.Plugs.PlatformScopeFactsTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 item 4 and section 4 (spec `test/specs/ISS-0993-A1.md`):
  the two scope facts the authentication pipeline stores in `conn.assigns.auth_context`
  (`platform_tenant?`, `platform_scope?`), on BOTH branches of `Letflow.Plugs.AuthPipeline`
  (API token and OIDC), and the rule that they are an assertion/cache only:
  `Letflow.Plugs.Authorize` recomputes `platform_tenant?` from the database-resolved tenant id.

    * pipeline value equals the value recomputed through `Letflow.PlatformTenant`;
    * platform tenant + a live `PLATFORM_ADMIN` role -> both true; platform tenant without it ->
      `platform_tenant?` true, `platform_scope?` false; ordinary tenant -> both false; pin unset ->
      both false for everyone;
    * a forged or stale stored flag changes nothing: with a hand-assigned `auth_context` (stored
      flags forged true, or absent) the A2 enforcement still sees the REAL platform fact.

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin and OIDC
  config, `bpm-default` realm displacement).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn

  alias Letflow.PlatformTenant
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture

  defp run_pipeline(headers) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(:get, "/whatever"), fn {key, value}, acc ->
        put_req_header(acc, key, value)
      end)

    AuthPipeline.call(conn, AuthPipeline.init([]))
  end

  defp token_context(fixture, roles) do
    token = Fixture.mint_token!(fixture, roles)
    context_for_token(fixture, token)
  end

  defp context_for_token(fixture, token) do
    conn =
      run_pipeline([
        {"authorization", "Bearer " <> token},
        {"x-tenant-slug", fixture.tenant.slug}
      ])

    refute conn.halted
    conn.assigns.auth_context
  end

  defp facts(auth_context),
    do: %{
      platform_tenant?: auth_context.platform_tenant?,
      platform_scope?: auth_context.platform_scope?
    }

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  describe "API-token branch" do
    test "the platform tenant's PLATFORM_ADMIN: both facts true", ctx do
      context = token_context(ctx.p, ["PLATFORM_ADMIN"])

      assert context.tenant_id == ctx.p.tenant_id
      assert facts(context) == %{platform_tenant?: true, platform_scope?: true}
    end

    test "the platform tenant without PLATFORM_ADMIN: platform_tenant? true, platform_scope? false",
         ctx do
      context = token_context(ctx.p, ["PROCESS_DESIGNER"])
      assert facts(context) == %{platform_tenant?: true, platform_scope?: false}
    end

    # REQ-447 PR 2: PLATFORM_ADMIN tokens are issuable only in the platform tenant's schema, so the
    # ordinary tenant's admin identity is TENANT_ADMIN.
    test "an ordinary tenant's TENANT_ADMIN: both facts false", ctx do
      context = token_context(ctx.a, ["TENANT_ADMIN"])

      assert context.tenant_id == ctx.a.tenant_id
      assert facts(context) == %{platform_tenant?: false, platform_scope?: false}
    end

    test "pin unset: both facts false for everyone, the would-be operator included", ctx do
      # REQ-447 PR 2: a PLATFORM_ADMIN token can be minted only in P while P is pinned, so the
      # tokens are minted first; A's admin identity is TENANT_ADMIN.
      tokens =
        for {fixture, roles} <- [
              {ctx.p, ["PLATFORM_ADMIN"]},
              {ctx.p, ["PROCESS_DESIGNER"]},
              {ctx.a, ["TENANT_ADMIN"]},
              {ctx.a, ["PROCESS_DESIGNER"]}
            ],
            do: {fixture, Fixture.mint_token!(fixture, roles)}

      Fixture.unpin!()

      for {fixture, token} <- tokens do
        assert facts(context_for_token(fixture, token)) ==
                 %{platform_tenant?: false, platform_scope?: false}
      end
    end

    test "the stored facts equal the recomputed facts for every combination", ctx do
      for pin <- [ctx.p.tenant_id, nil],
          fixture <- [ctx.p, ctx.a, ctx.b],
          # REQ-447 PR 2: PLATFORM_ADMIN is mintable only in the pinned platform tenant
          admin =
            if(fixture.tenant_id == ctx.p.tenant_id and pin == ctx.p.tenant_id,
              do: "PLATFORM_ADMIN",
              else: "TENANT_ADMIN"
            ),
          roles <- [[admin], ["PROCESS_DESIGNER"]] do
        Fixture.pin!(pin)
        context = token_context(fixture, roles)

        assert facts(context) == PlatformTenant.scope_facts_for(context)
        assert facts(context) == PlatformTenant.scope_facts(context.tenant_id, context.roles)
      end
    end

    test "a token minted in tenant A is not accepted under the platform tenant's slug", ctx do
      token = Fixture.mint_token!(ctx.a, ["TENANT_ADMIN"])

      conn =
        run_pipeline([
          {"authorization", "Bearer " <> token},
          {"x-tenant-slug", ctx.p.tenant.slug}
        ])

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "OIDC branch" do
    # `bpm-default` is the one realm the default test double claims; exclusive control of it is
    # taken through Letflow.Support.BpmDefaultRealmDisplacement (restored on exit).
    defp bind_fresh_tenant_to_default_realm! do
      Letflow.Support.BpmDefaultRealmDisplacement.displace!()

      %{tenant: tenant} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "scope-oidc",
          oidc_mode: :enabled,
          idp_realm_id: "bpm-default"
        )

      tenant
    end

    test "the realm's tenant is the platform tenant: platform_tenant? true; no live PLATFORM_ADMIN row: platform_scope? false" do
      tenant = bind_fresh_tenant_to_default_realm!()
      Fixture.pin!(tenant.id)

      conn = run_pipeline([{"authorization", "Bearer valid-test-token"}])

      refute conn.halted
      context = conn.assigns.auth_context
      assert context.tenant_id == tenant.id
      # the token claims a role, but only the live, database-resolved roles count
      assert context.roles == []
      assert facts(context) == %{platform_tenant?: true, platform_scope?: false}
      assert facts(context) == PlatformTenant.scope_facts_for(context)
    end

    test "an ordinary realm's tenant, and an unset pin: both facts false" do
      tenant = bind_fresh_tenant_to_default_realm!()

      Fixture.pin!(Ecto.UUID.generate())
      conn = run_pipeline([{"authorization", "Bearer valid-test-token"}])
      assert conn.assigns.auth_context.tenant_id == tenant.id

      assert facts(conn.assigns.auth_context) == %{
               platform_tenant?: false,
               platform_scope?: false
             }

      Fixture.unpin!()
      conn = run_pipeline([{"authorization", "Bearer valid-test-token"}])

      assert facts(conn.assigns.auth_context) == %{
               platform_tenant?: false,
               platform_scope?: false
             }
    end
  end

  describe "Authorize recomputes platform_tenant? (the stored flag is never read)" do
    defp enforce_for(fixture, auth_context_overrides) do
      conn =
        Fixture.router_conn(:get, "/", fixture, ["PLATFORM_ADMIN"], nil)
        |> update_in(
          [Access.key(:assigns), :auth_context],
          &Map.merge(&1, auth_context_overrides)
        )

      Letflow.Routers.Tenants.call(conn, Letflow.Routers.Tenants.init([]))
    end

    test "an ordinary tenant's context with forged stored flags (true) is still denied 403 (A2)",
         ctx do
      resp = enforce_for(ctx.a, %{platform_tenant?: true, platform_scope?: true})

      assert resp.status == 403
    end

    test "the platform tenant's context with stale stored flags (false) is still allowed (A2)",
         ctx do
      resp = enforce_for(ctx.p, %{platform_tenant?: false, platform_scope?: false})

      assert resp.status == 200
    end

    test "a hand-assigned context without the stored flag keys does not raise and is evaluated on the real fact",
         ctx do
      resp_a = enforce_for(ctx.a, %{})
      resp_p = enforce_for(ctx.p, %{})

      assert resp_a.status == 403
      assert resp_p.status == 200
    end
  end
end
