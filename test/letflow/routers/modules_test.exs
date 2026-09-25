defmodule Letflow.Routers.ModulesTest do
  @moduledoc """
  Tests for `Letflow.Routers.Modules` (REQ-404) — the D4/D5 module-router
  dispatch mount. See `lib/letflow/design/req404-module-router-mount.md`
  §4.2 for the full design these tests implement. ELIXIR-DEV inline
  coverage (this project's established convention when the design is fully
  specified — no separate TEST-DESIGNER dispatch).

  Covers AC1 (404 before any permission check, every role including
  PLATFORM_ADMIN), AC2 (200/403 split once installed, via the fixture's own
  `role_grants`), AC3 (byte-identical 404 body for an unknown module id vs
  an uninstalled known module), AC4 (two-tenant install isolation — still
  404, not 403, for a tenant that never installed it).

  ## Full-pipeline dispatch, not the router in isolation

  Dispatched via `Letflow.Router.call/2` with a real
  `Authorization: Bearer lf_tok_...` + `X-Tenant-Slug` credential, mirroring
  `test/letflow/routers/entities_test.exs`'s own established convention --
  so `AuthPipeline -> TenantStatus -> Letflow.Routers.Modules -> (module's
  own) Authorize` genuinely all run. A preset `:scoped_opts` would prove
  nothing about the real dispatch path.

  `async: false` — `TenantFixture.provisioned_tenant!/1` switches the
  sandbox to global `:auto` mode (matching `tenant_modules_test.exs`'s own
  justification).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Fixture
  alias Letflow.Modules.Installs
  alias Letflow.TenantFixture

  # ── Full-pipeline dispatch ─────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, trace_id \\ nil) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> maybe_pin_trace_id(trace_id)
    |> dispatch()
  end

  # AC3's byte-identity assertion compares resp_body across two SEPARATE
  # requests; Letflow.Api.Error's trace_id is per-request correlation data,
  # not per-resource information, so it must be pinned to the same value
  # across the pair being compared -- otherwise every 404 would differ by
  # trace_id alone and the comparison would prove nothing. Mirrors
  # test/letflow/routers/entities_test.exs's own established convention.
  defp maybe_pin_trace_id(conn, nil), do: conn
  defp maybe_pin_trace_id(conn, trace_id), do: put_req_header(conn, "x-trace-id", trace_id)

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp insert_user!(schema_name) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req404-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-404 Modules Router Test User",
      email: "req404-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp tenant_ctx(slug_prefix) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "REQ-404 Modules Router Test Tenant"
      )

    %{tenant_id: tenant.tenant_id, schema_name: tenant.schema_name, slug: tenant.tenant.slug}
  end

  defp token_for(ctx, role) do
    user = insert_user!(ctx.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: [Atom.to_string(role)], expires_at: nil},
        prefix: ctx.schema_name
      )

    Map.merge(ctx, %{plaintext: plaintext, user_id: user.id})
  end

  defp install_fixture!(ctx) do
    {:ok, _tenant_module} =
      Installs.install("fixture", Ecto.UUID.generate(), prefix: ctx.schema_name)

    ctx
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC1 — 404 for every role, including PLATFORM_ADMIN, when not installed
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC1 -- 404 for every role when the fixture is not installed, before any permission check" do
    test "GET /api/v1/modules/fixture/items/42 is 404 for every role in Authorization.roles/0" do
      ctx = tenant_ctx("req404-ac1")

      for role <- Authorization.roles() do
        role_ctx = token_for(ctx, role)

        conn = request(:get, "/api/v1/modules/fixture/items/42", role_ctx)

        assert conn.status == 404,
               "expected 404 for role #{inspect(role)}, got #{conn.status}"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC2 — 200/403 split once installed, driven by the fixture's own
  # role_grants
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC2 -- 200 for the fixture's own granted role, 403 for a role it doesn't grant, once installed" do
    test "200 with the fixture body for a role_grants role, 403 for a role not granted" do
      ctx = tenant_ctx("req404-ac2") |> install_fixture!()

      [granted_role | _rest] = Map.keys(Fixture.manifest().role_grants)
      granted_ctx = token_for(ctx, granted_role)

      granted_conn = request(:get, "/api/v1/modules/fixture/items/42", granted_ctx)

      assert granted_conn.status == 200
      assert Jason.decode!(granted_conn.resp_body) == %{"fixture" => true, "id" => "42"}

      # PLATFORM_ADMIN's core matrix unconditionally allows every permission
      # (see Letflow.Api.Authorization.core_role_allows?/2), so it must be
      # excluded here -- this needs a role the fixture's own role_grants does
      # NOT name AND whose core matrix does not separately grant :FixtureRead.
      ungranted_role =
        Enum.find(Authorization.roles(), fn role ->
          role != :PLATFORM_ADMIN and role not in Map.keys(Fixture.manifest().role_grants)
        end)

      ungranted_ctx = token_for(ctx, ungranted_role)

      ungranted_conn = request(:get, "/api/v1/modules/fixture/items/42", ungranted_ctx)

      assert ungranted_conn.status == 403
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC3 — byte-identical 404 body for an unknown module id vs an
  # uninstalled known module
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC3 -- 404 body is byte-identical regardless of which branch produced it" do
    test "unknown module id and uninstalled known module produce the exact same resp_body" do
      ctx = tenant_ctx("req404-ac3")
      role_ctx = token_for(ctx, :PLATFORM_ADMIN)

      trace_id = "req404-ac3-shared-trace-id"

      unknown_conn = request(:get, "/api/v1/modules/does-not-exist/anything", role_ctx, trace_id)
      uninstalled_conn = request(:get, "/api/v1/modules/fixture/items/42", role_ctx, trace_id)

      assert unknown_conn.status == 404
      assert uninstalled_conn.status == 404
      assert unknown_conn.resp_body == uninstalled_conn.resp_body
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 — two-tenant isolation: installing into A doesn't leak into B
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC4 -- installing the fixture into tenant A does not make it reachable for tenant B" do
    test "tenant B's TASK_WORKER still gets 404, not 403, after tenant A installs the fixture" do
      _ctx_a = tenant_ctx("req404-ac4-a") |> install_fixture!()
      ctx_b = tenant_ctx("req404-ac4-b")

      role_ctx_b = token_for(ctx_b, :TASK_WORKER)

      conn = request(:get, "/api/v1/modules/fixture/items/42", role_ctx_b)

      assert conn.status == 404
    end
  end
end
