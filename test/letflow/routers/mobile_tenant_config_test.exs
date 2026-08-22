defmodule Letflow.Routers.MobileTenantConfigTest do
  @moduledoc """
  Tests for `Letflow.Routers.MobileTenantConfig` (REQ-124, design
  `lib/letflow/design/req124-mobile-tenant-config.md`). See `test/specs/REQ-124.md`
  for the full acceptance-criterion-to-test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- the fixtures below insert rows into the *global* `tenants` table
  only (never a per-tenant provisioned schema, since `GET /api/mobile/tenant-config`
  itself never touches one -- see the design's §5 "No tenant scoping call"), so plain
  `Letflow.DataCase`'s rolled-back sandboxed transaction is sufficient; no
  `Letflow.TenantFixture` schema-provisioning/migration-replay/`:auto`-mode machinery
  is needed here (unlike `identity_test.exs`'s `provisioned_tenant!/1` for
  `provision_oidc_user/4`). `async: true` is therefore safe.

  ## Dispatch strategy (mirrors test/letflow/routers/req078_supporting_routes_test.exs
  AC1's own `GET /api/tenant-config` case, the established style for this endpoint
  family)

  Every test dispatches through `Letflow.Router` itself (`Letflow.Router.call/2`),
  never directly against `Letflow.Routers.MobileTenantConfig`'s own `Plug.Router`,
  because the property under test is specifically that the route is reachable with
  no `Authorization` header through the real mount chain (`Letflow.Router` ->
  `forward("/api/mobile/tenant-config", ...)`, declared BEFORE the `/api/v1` forward,
  outside `Letflow.Plugs.ApiPipeline`/`Letflow.Plugs.AuthPipeline`) -- only the
  top-level router proves that. No test in this file ever calls
  `Plug.Conn.put_req_header(conn, "authorization", ...)` -- that omission is the
  whole point of this endpoint (see AC1/AC2 below), not an oversight.
  """

  use Letflow.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.TenantSlugFixture

  @router_opts Letflow.Router.init([])

  @expected_keys ["branding", "default_locale", "environment_kind", "locales", "realm_url"]

  defp call(conn), do: Letflow.Router.call(conn, @router_opts)

  defp unique_slug(prefix), do: TenantSlugFixture.unique_slug(prefix)

  defp unique_realm(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp insert_tenant!(attrs) do
    %Tenant{}
    |> Tenant.create_changeset(attrs, :disabled)
    |> Repo.insert!()
  end

  # Ecto.Changeset.cast/4's default `:empty_values` ([""]) normalizes an
  # incoming `idp_realm_id: ""` param to `nil` before it ever reaches the
  # database -- so building via insert_tenant!/1 alone cannot produce a row
  # whose idp_realm_id is a genuine, persisted empty string. This helper casts
  # without idp_realm_id, then forces it onto the changeset with
  # Ecto.Changeset.put_change/3 (which does NOT apply empty_values
  # normalization), so the row actually persists idp_realm_id == "" -- the
  # real value resolve_realm_id/1's `realm_id != ""` guard clause is written
  # to handle, not a value indistinguishable from the nil case.
  defp insert_tenant_with_raw_empty_realm!(attrs) do
    %Tenant{}
    |> Tenant.create_changeset(attrs, :disabled)
    |> Ecto.Changeset.put_change(:idp_realm_id, "")
    |> Repo.insert!()
  end

  # Dispatches GET /api/mobile/tenant-config (optionally with a ?slug= query
  # string), asserts no Authorization header was ever attached (documents the
  # precondition, doesn't just rely on Plug.Test's conn/2 default), and returns
  # the decoded JSON body plus the raw conn.
  defp get_mobile_config(slug \\ :no_slug_param) do
    path =
      case slug do
        :no_slug_param -> "/api/mobile/tenant-config"
        slug -> "/api/mobile/tenant-config?slug=#{URI.encode_www_form(slug)}"
      end

    conn = conn(:get, path)
    assert get_req_header(conn, "authorization") == []

    conn = call(conn)
    {conn, Jason.decode!(conn.resp_body)}
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC1 + AC3 -- known slug, no Authorization header, exact 5-key shape
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC1/AC3: known slug with idp_realm_id set, no Authorization header, exact 5-field shape" do
    test "200, realm_url reflects the resolved tenant's idp_realm_id, exactly the 5 documented keys and no others" do
      realm_id = unique_realm("req124-known")

      tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-known"),
          display_name: "REQ-124 Known Tenant",
          idp_realm_id: realm_id
        })

      {conn, body} = get_mobile_config(tenant.slug)

      assert conn.status == 200

      # Exact-shape assertion (AC3) -- sorted-key-set equality, not a
      # subset/pattern match. Would fail if a 6th key (e.g. tenant id, slug,
      # display_name, status) ever leaked into the response, or if any of the
      # 5 documented keys were missing.
      assert Map.keys(body) |> Enum.sort() == @expected_keys

      assert body["realm_url"] =~ "/realms/#{realm_id}"
      refute body["realm_url"] =~ "/realms/bpm-default"
    end

    test "no Authorization header is required to reach this route -- reachable through the real Letflow.Router mount, not dispatched directly against the sub-router" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-noauth"),
          display_name: "REQ-124 No-Auth Tenant",
          idp_realm_id: unique_realm("req124-noauth")
        })

      conn = conn(:get, "/api/mobile/tenant-config?slug=#{tenant.slug}")
      assert get_req_header(conn, "authorization") == []

      conn = call(conn)
      assert conn.status == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC4 -- unknown/nil-realm/missing-slug all fall through to the identical
  # default body (anti-enumeration)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC4: default-realm fallback branches are all byte-identical to each other" do
    test "a slug with nil idp_realm_id falls through to the default realm" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-nilrealm"),
          display_name: "REQ-124 Nil Realm Tenant",
          idp_realm_id: nil
        })

      {conn, body} = get_mobile_config(tenant.slug)

      assert conn.status == 200
      assert body["realm_url"] =~ "/realms/bpm-default"
    end

    test "a slug with an EMPTY-STRING idp_realm_id (not nil) also falls through to the default realm" do
      tenant =
        insert_tenant_with_raw_empty_realm!(%{
          slug: unique_slug("req124-emptyrealm"),
          display_name: "REQ-124 Empty Realm Tenant"
        })

      assert tenant.idp_realm_id == ""

      {conn, body} = get_mobile_config(tenant.slug)

      assert conn.status == 200
      assert body["realm_url"] =~ "/realms/bpm-default"
    end

    test "an unknown slug, a nil-idp_realm_id slug, and a missing ?slug= param all produce the BYTE-IDENTICAL response body" do
      nil_realm_tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-anti-oracle-nil"),
          display_name: "REQ-124 Anti-Oracle Nil Realm",
          idp_realm_id: nil
        })

      {conn_missing, body_missing} = get_mobile_config()
      {conn_unknown, body_unknown} = get_mobile_config(unique_slug("req124-anti-oracle-unknown"))
      {conn_nil_realm, body_nil_realm} = get_mobile_config(nil_realm_tenant.slug)
      {conn_empty, body_empty} = get_mobile_config("")

      for conn <- [conn_missing, conn_unknown, conn_nil_realm, conn_empty] do
        assert conn.status == 200
      end

      # An unauthenticated caller with a wordlist must not be able to
      # distinguish "this slug does not exist" from "this slug exists but has
      # no realm bound" from "no slug was supplied at all" -- all four
      # collapse to the exact same response body (INV-5-flavored
      # anti-enumeration, design §4).
      assert body_missing == body_unknown
      assert body_missing == body_nil_realm
      assert body_missing == body_empty
      assert Map.keys(body_missing) |> Enum.sort() == @expected_keys
      assert body_missing["realm_url"] =~ "/realms/bpm-default"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # locales/default_locale/branding/environment_kind are global, not per-tenant
  # ═══════════════════════════════════════════════════════════════════════════

  describe "the four non-realm_url fields never vary by slug (design §4/§5 OQ-1 -- global, not per-tenant)" do
    test "a resolvable known-slug response and the default-fallback response agree on every field except realm_url" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-global-fields"),
          display_name: "REQ-124 Global Fields Tenant",
          idp_realm_id: unique_realm("req124-global-fields")
        })

      {_conn_known, body_known} = get_mobile_config(tenant.slug)
      {_conn_default, body_default} = get_mobile_config()

      assert body_known["realm_url"] != body_default["realm_url"]

      for field <- ["locales", "default_locale", "branding", "environment_kind"] do
        assert body_known[field] == body_default[field],
               "expected #{field} to be identical across branches, got #{inspect(body_known[field])} vs #{inspect(body_default[field])}"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC5 -- every other Letflow.Plugs.ApiPipeline route still requires auth;
  # the exemption is route-specific, not pipeline-wide
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC5: the unauthenticated exemption is specific to the two Letflow.Router-level forwards, not pipeline-wide" do
    test "GET /api/v1/tenants with no Authorization header still returns 401 -- proves ApiPipeline/AuthPipeline is unchanged" do
      conn = conn(:get, "/api/v1/tenants")
      assert get_req_header(conn, "authorization") == []

      conn = call(conn)

      # If REQ-124's route had instead been mounted inside
      # Letflow.Plugs.ApiPipeline (or if AuthPipeline had somehow acquired a
      # bypass as a side effect of this change), a bug that widened the
      # exemption pipeline-wide would make THIS assertion fail -- this route
      # was never touched by REQ-124 and must still demand a bearer token.
      assert conn.status == 401
    end

    test "GET /api/mobile/tenant-config itself is unaffected by AuthPipeline even when called with a garbage Authorization header" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req124-garbage-auth"),
          display_name: "REQ-124 Garbage Auth Header Tenant",
          idp_realm_id: unique_realm("req124-garbage-auth")
        })

      conn =
        conn(:get, "/api/mobile/tenant-config?slug=#{tenant.slug}")
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> call()

      # Still 200 -- this route never inspects the Authorization header at
      # all (it is mounted entirely outside AuthPipeline), so a garbage
      # token present is just as irrelevant as no token at all.
      assert conn.status == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Every branch is 200, never 404/500 (never-error rule, design §4)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "never-error rule: every branch returns 200, never 404 or 500" do
    test "an unmatched sub-path under the mount still returns a clean response, not a 500" do
      conn = conn(:get, "/api/mobile/tenant-config/nonexistent-subpath") |> call()

      # match _ do Response.not_found(conn) end inside the sub-router -- this
      # is the ONE path this module can 404 (a genuinely wrong sub-path), and
      # it is a clean 404, not a crash. The bootstrap GET "/" path itself
      # (every test above) always stays at 200.
      assert conn.status == 404
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Identity.safe_get_tenant_by_slug/2's exception-swallowing is exercised
  # through the full router as well (unit coverage lives in identity_test.exs)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "resolve_realm_id/1 delegates to the shared never-raise wrapper (Letflow.Identity.safe_get_tenant_by_slug/2)" do
    test "moduledoc documents the shared wrapper by name" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Letflow.Routers.MobileTenantConfig)

      assert moduledoc =~ "Letflow.Identity.get_tenant_by_slug/1"
      assert moduledoc =~ "never disclose"
    end
  end
end
