defmodule Letflow.Routers.TenantConfigTest do
  @moduledoc """
  Tests for REQ-281 (`lib/letflow/design/req281-tenant-config-branding-key.md`) —
  the new `branding` third key on `GET /api/tenant-config`. The pre-existing
  2-key coverage for this endpoint (oidc_authority/client_id shape,
  no-Authorization-header reachability) lives in
  `test/letflow/routers/req078_supporting_routes_test.exs`; this file covers
  only what REQ-281 added.

  Uses `Letflow.DataCase` (real Postgres, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1) — every fixture here
  inserts into the *global* `tenants` table only (this endpoint never touches
  a per-tenant provisioned schema — see the module's own moduledoc, "No
  tenant scoping call"), so plain `Letflow.DataCase`'s rolled-back sandboxed
  transaction is sufficient and `async: true` is safe, mirroring
  `mobile_tenant_config_test.exs`'s own reasoning.

  ## Dispatch strategy

  Every test dispatches through `Letflow.Router` itself, not directly against
  `Letflow.Routers.TenantConfig`'s own `Plug.Router`, because the property
  under test includes that the route is reachable with no `Authorization`
  header through the real mount chain — mirrors
  `req078_supporting_routes_test.exs` AC1's own `GET /api/tenant-config` case
  and `mobile_tenant_config_test.exs`'s established convention for this
  endpoint family.
  """

  use Letflow.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.TenantSlugFixture

  @router_opts Letflow.Router.init([])

  @expected_keys ["branding", "client_id", "oidc_authority"]
  @expected_branding_keys ["app_name", "brand_colors", "logo_url"]

  @default_app_name "Letflow"
  @default_logo_url nil
  @default_brand_colors %{"primary" => "#228be6"}

  defp call(conn), do: Letflow.Router.call(conn, @router_opts)

  defp unique_slug(prefix), do: TenantSlugFixture.unique_slug(prefix)

  defp unique_realm(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp insert_tenant!(attrs) do
    %Tenant{}
    |> Tenant.create_changeset(attrs, :disabled)
    |> Repo.insert!()
  end

  defp get_config(realm_slug \\ :none) do
    path =
      case realm_slug do
        :none -> "/api/tenant-config"
        slug -> "/api/tenant-config?realm=#{URI.encode_www_form(slug)}"
      end

    conn = conn(:get, path)
    assert get_req_header(conn, "authorization") == []

    conn = call(conn)
    {conn, Jason.decode!(conn.resp_body)}
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC1 — exactly 3 top-level keys, response map hand-built not derived from
  # %Tenant{}
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC1: exactly 3 top-level keys; response map hand-built, never derived from %Tenant{}" do
    test "GET /api/tenant-config returns exactly oidc_authority, client_id and branding" do
      {conn, body} = get_config()

      assert conn.status == 200
      assert Map.keys(body) |> Enum.sort() == @expected_keys
      assert Map.keys(body["branding"]) |> Enum.sort() == @expected_branding_keys
    end

    test "config_map/2 is the sole, hand-built constructor -- quoted verbatim from source" do
      source = File.read!("lib/letflow/routers/tenant_config.ex")

      assert source =~ "defp config_map(realm_id, tenant) do"
      assert source =~ "\"oidc_authority\" => idp_base_url() <> \"/realms/\" <> realm_id,"
      assert source =~ "\"client_id\" => client_id(),"
      assert source =~ "\"branding\" => branding_map(tenant)"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC2 — identical shape/status/key-presence across all 4 never-error paths
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC2: all four never-error paths produce byte-identical branding (and full response shape)" do
    test "resolvable slug with no branding stored, unknown slug, malformed slug, and a simulated DB failure all agree" do
      tenant_no_settings =
        insert_tenant!(%{
          slug: unique_slug("req281-no-settings"),
          display_name: "REQ-281 No Settings Tenant",
          idp_realm_id: unique_realm("req281-no-settings")
        })

      {conn_resolvable, body_resolvable} = get_config(tenant_no_settings.slug)
      {conn_unknown, body_unknown} = get_config(unique_slug("req281-unknown"))
      # A malformed/empty slug -- non_empty/1 normalizes "" to nil before any
      # lookup is attempted (same branch as no slug at all).
      {conn_malformed, body_malformed} = get_config("")

      # Simulated DB failure: Identity.safe_get_tenant_by_slug/2's rescue
      # clause is triggered by a slug value Postgrex cannot encode as a
      # query parameter (a null byte is invalid inside a Postgres text
      # value) -- exactly the mechanism identity_test.exs's own
      # "a raise inside get_tenant_by_slug/1 is swallowed" test exercises,
      # reached here through the real HTTP path via a URL-encoded null byte.
      {conn_db_failure, body_db_failure} = get_config(<<0>>)

      for conn <- [conn_resolvable, conn_unknown, conn_malformed, conn_db_failure] do
        assert conn.status == 200
      end

      for body <- [body_resolvable, body_unknown, body_malformed, body_db_failure] do
        assert Map.keys(body) |> Enum.sort() == @expected_keys
        assert Map.keys(body["branding"]) |> Enum.sort() == @expected_branding_keys
      end

      # The three "no tenant"/"no settings" paths are byte-identical to each
      # other in their branding block (design §4 cases 3/4).
      assert body_resolvable["branding"] == body_unknown["branding"]
      assert body_unknown["branding"] == body_malformed["branding"]
      assert body_malformed["branding"] == body_db_failure["branding"]

      assert body_resolvable["branding"] == %{
               "app_name" => @default_app_name,
               "logo_url" => @default_logo_url,
               "brand_colors" => @default_brand_colors
             }

      # Full response bodies agree too, apart from oidc_authority (which
      # legitimately differs by realm id) -- client_id and branding must be
      # identical across all four.
      assert body_resolvable["client_id"] == body_db_failure["client_id"]
      assert body_unknown["oidc_authority"] == body_malformed["oidc_authority"]
      assert body_unknown["oidc_authority"] == body_db_failure["oidc_authority"]
      assert body_unknown["oidc_authority"] =~ "/realms/bpm-default"
      refute body_resolvable["oidc_authority"] =~ "/realms/bpm-default"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC3 — a tenant WITH stored branding gets its own values (per-sub-key
  # fallback), a tenant WITHOUT gets platform defaults -- proves the store is
  # actually read
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC3: stored settings are actually read; per-sub-key fallback, not all-or-nothing" do
    test "a tenant with a full stored branding block gets its own values for all three sub-keys" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req281-full-branding"),
          display_name: "REQ-281 Full Branding Tenant",
          idp_realm_id: unique_realm("req281-full-branding")
        })

      assert {:ok, _updated} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{
                   "app_name" => "Acme Corp",
                   "logo_url" => "https://acme.example.com/logo.png",
                   "brand_colors" => %{"primary" => "#ff00aa"}
                 }
               })

      {conn, body} = get_config(tenant.slug)

      assert conn.status == 200

      assert body["branding"] == %{
               "app_name" => "Acme Corp",
               "logo_url" => "https://acme.example.com/logo.png",
               "brand_colors" => %{"primary" => "#ff00aa"}
             }
    end

    test "a tenant with a PARTIAL stored settings map (only app_name) falls back independently for the other two sub-keys" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req281-partial-branding"),
          display_name: "REQ-281 Partial Branding Tenant",
          idp_realm_id: unique_realm("req281-partial-branding")
        })

      assert {:ok, _updated} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{"app_name" => "Only App Name Co"}
               })

      {conn, body} = get_config(tenant.slug)

      assert conn.status == 200

      assert body["branding"] == %{
               "app_name" => "Only App Name Co",
               "logo_url" => @default_logo_url,
               "brand_colors" => @default_brand_colors
             }
    end

    test "a tenant with NO stored settings at all (settings == nil) gets the full platform-default branding block" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req281-nil-settings"),
          display_name: "REQ-281 Nil Settings Tenant",
          idp_realm_id: unique_realm("req281-nil-settings")
        })

      assert tenant.settings == nil

      {conn, body} = get_config(tenant.slug)

      assert conn.status == 200

      assert body["branding"] == %{
               "app_name" => @default_app_name,
               "logo_url" => @default_logo_url,
               "brand_colors" => @default_brand_colors
             }
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC4 — closed allowlist: an out-of-allowlist value stored through whatever
  # path can reach the settings store does NOT appear in the response
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC4: closed allowlist -- an out-of-allowlist settings key can never reach the response" do
    test "Identity.update_tenant_settings/2 rejects an unrecognized top-level key outright (write-time enforcement, TenantSettings.cast/1)" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req281-allowlist-reject"),
          display_name: "REQ-281 Allowlist Reject Tenant",
          idp_realm_id: unique_realm("req281-allowlist-reject")
        })

      assert {:error, %Ecto.Changeset{} = changeset} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{"app_name" => "Fine", "secret_admin_token" => "leak-me"}
               })

      refute changeset.valid?

      # The value never even reaches storage -- reload and confirm settings
      # is unaffected (still nil, the update was rejected wholesale).
      reloaded = Repo.get_by!(Tenant, slug: tenant.slug)
      assert reloaded.settings == nil

      {conn, body} = get_config(tenant.slug)
      assert conn.status == 200
      refute body["branding"] |> Map.keys() |> Enum.member?("secret_admin_token")
      refute Jason.encode!(body) =~ "leak-me"
      refute Jason.encode!(body) =~ "secret_admin_token"
    end

    test "an out-of-allowlist inner key inside brand_colors is also rejected at write time (Tenant.settings_changeset/2)" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug("req281-brandcolors-reject"),
          display_name: "REQ-281 Brand Colors Reject Tenant",
          idp_realm_id: unique_realm("req281-brandcolors-reject")
        })

      assert {:error, %Ecto.Changeset{} = changeset} =
               Identity.update_tenant_settings(tenant.slug, %{
                 "settings" => %{
                   "brand_colors" => %{"primary" => "#123456", "secondary" => "#abcdef"}
                 }
               })

      refute changeset.valid?

      {conn, body} = get_config(tenant.slug)
      assert conn.status == 200
      refute Map.has_key?(body["branding"]["brand_colors"], "secondary")
      refute Jason.encode!(body) =~ "secondary"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC5 — moduledoc paragraph updated (before/after quoted; the "before" text
  # must be GONE and the "after" text present)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC5: moduledoc's security-change paragraph names the third key and states the fourth-key rule" do
    test "moduledoc no longer says 'exactly two values' and now documents branding's 3 sub-keys and the 4th-key rule" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Letflow.Routers.TenantConfig)

      refute moduledoc =~ "It returns exactly two values"
      assert moduledoc =~ "It returns exactly three values"
      assert moduledoc =~ "`branding` block"
      assert moduledoc =~ "app_name"
      assert moduledoc =~ "logo_url"
      assert moduledoc =~ "brand_colors"
      assert moduledoc =~ "Letflow.Identity.Tenant"
      assert moduledoc =~ "Adding a fourth top-level key to this response"
      assert moduledoc =~ "fourth sub-key"
      assert moduledoc =~ "is a security change, not a feature."
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC7 — mobile_tenant_config.ex is untouched (also re-verified at the repo
  # level; this is a fast in-suite sanity check)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC7: mobile_tenant_config.ex is not this requirement's concern" do
    test "Letflow.Routers.MobileTenantConfig still discloses 5 keys, unaffected by the branding key added here" do
      assert Code.ensure_loaded?(Letflow.Routers.MobileTenantConfig)

      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Letflow.Routers.MobileTenantConfig)

      assert moduledoc =~ "exactly five keys"
    end
  end
end
