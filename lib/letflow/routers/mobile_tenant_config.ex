defmodule Letflow.Routers.MobileTenantConfig do
  @moduledoc """
  Public mobile-bootstrap sub-router (REQ-124, design
  `lib/letflow/design/req124-mobile-tenant-config.md`), gate for MOB-2
  (`docs/mobile/requirements.md`) — the single blocking dependency for the
  entire mobile tier per `docs/mobile/build-order.md` phase M-0.

  | Handler | Method/path                    | Delegate                                | Auth     | Response |
  |---------|---------------------------------|------------------------------------------|----------|----------|
  | config  | `GET /api/mobile/tenant-config` | `Letflow.Identity.get_tenant_by_slug/1`  | **none** | always 200, `{realm_url, locales, default_locale, branding, environment_kind}` |

  This is a **second, independent** module from `Letflow.Routers.TenantConfig`
  (REQ-078), not a discriminator on its route — see design §1 for why: the
  existing module's 2-key allowlist and this module's 5-key allowlist are each
  easier to audit in isolation than one handler branching between two response
  contracts. `Letflow.Routers.TenantConfig`'s existing route, behavior and
  response shape are **untouched** by this module.

  ## Why this is mounted on `Letflow.Router`, NOT in `Letflow.Plugs.ApiPipeline`

  This route's caller is the mobile app **before it holds any token** —
  resolving tenant identity and fetching config is a precondition for
  starting the OIDC Authorization-Code+PKCE flow, so a token cannot exist
  yet. `Letflow.Plugs.AuthPipeline`, read in full, has **no public-path
  allowlist and no bypass/skip option** — its `call/2` `with` chain always
  requires `extract_bearer_token/1` to succeed. Mounting this route inside
  `Letflow.Plugs.ApiPipeline` (and therefore behind `AuthPipeline`) would make
  it unreachable by the only caller that needs it — exactly the defect
  `Letflow.Routers.TenantConfig`'s moduledoc already documents for the web
  SPA case. This module restates that reasoning locally rather than only
  cross-referencing REQ-078's, since a reader of this module alone must not
  have to chase a second file to find load-bearing reasoning.

  So this module is forwarded from **`Letflow.Router`** —
  `forward("/api/mobile/tenant-config", to: Letflow.Routers.MobileTenantConfig)`,
  declared immediately after the existing `/api/tenant-config` forward and
  still before the `/api/v1` forward, exactly mirroring
  `Letflow.Routers.TenantConfig`'s mount. `Letflow.Plugs.Cors` is mounted on
  `Letflow.Router` itself, ahead of `plug(:match)`, and is origin- not
  path-based, so it covers this route automatically with no change needed.

  ## The never-error rule is LOAD-BEARING here too

  Every path — resolvable slug, unknown slug, missing `?slug=` param, DB
  error/exception — returns **200** with the full 5-field body. There is no
  `404`, no partial body, no absent field:

    1. **Availability.** The mobile app cannot get past its bootstrap screen
       without a config; a `404`/`500` here strands the user before they ever
       reach a login screen — the one failure mode MOB-2 exists to prevent.
    2. **Anti-enumeration.** A miss (`{:error, :not_found}`), a slug with no
       `idp_realm_id` set, a lookup exception, and a missing `?slug=` param
       all produce the byte-identical default body. A caller with a wordlist
       cannot distinguish "this slug does not exist" from "this slug exists
       but has no realm bound" from "the DB call failed" — none of them
       functions as an existence oracle.

  A caller **can** still infer that a slug is bound to some realm when it
  gets back a non-default `realm_url` — unavoidable, since telling the app
  which realm to authenticate against is this endpoint's entire purpose, and
  it is the same information any user of that tenant already sees at their
  own login screen. `locales`, `default_locale`, `branding` and
  `environment_kind` are never tenant-derived (see below), so only one of the
  five fields varies by slug at all — the other four are byte-identical
  across every branch by construction.

  ## What this endpoint discloses, and what it must never disclose

  It returns exactly five keys: `realm_url`, `locales`, `default_locale`,
  `branding`, `environment_kind`. All are values the mobile app must learn
  before it can even start authenticating, and none identifies the tenant
  beyond the realm URL a user of that tenant already sees at login. The
  response map is hand-built with exactly these five keys and is **never**
  derived from `%Letflow.Identity.Tenant{}` (INV-2) — it must never return a
  tenant id, slug, display name, status, user count, or any other tenant
  attribute. **Adding a sixth key to this response is a security change, not
  a feature.**

  ## `locales` / `default_locale` / `branding` / `environment_kind` are global, not per-tenant

  `Letflow.Identity.Tenant`'s schema has no locale, branding, or environment
  column, and this module adds none (no migration — see design §5 OQ-1).
  These four fields are sourced from application config/env, the same
  `System.get_env/1`-at-point-of-use style as `Letflow.Routers.TenantConfig`'s
  `idp_base_url/0`, with hardcoded defaults. Consequently every tenant on
  this backend currently gets identical `locales`/`default_locale`/
  `branding` values — this is a deliberate, explicitly-flagged placeholder
  (design OQ-1), not a bug, pending a future requirement that would give
  tenant branding its own schema/migration/admin UI. Only `realm_url` varies
  by resolved slug.

  ## Slug resolution — `?slug=` only, no `?host=` branch (design OQ-2)

  Unlike `Letflow.Routers.TenantConfig`'s web-SPA `?host=` fallback (used
  when no slug is known yet), MOB-2's mobile callers always resolve a slug
  (deep-link subdomain or manual entry) before calling this endpoint. This
  route therefore accepts a single `?slug=<tenant_slug>` parameter and has no
  `?host=` parameter or branch. If a future requirement needs server-side
  host resolution for mobile, that is a new parameter on this module, not a
  retrofit of `Letflow.Routers.TenantConfig`'s `?host=` handling — Letflow
  still has no host->tenant binding of any kind.

  ## No trace id on this endpoint

  Same as `Letflow.Routers.TenantConfig`: mounted outside
  `Letflow.Plugs.ApiPipeline`, so `Letflow.Api.Context.assign_trace_id/1`
  never runs and `conn.assigns[:trace_id]` is absent. Harmless — this module
  never emits a problem document.

  ## No tenant scoping call, deliberately

  Unauthenticated by design, reads only the **global** `tenants` table (via
  `Letflow.Identity.get_tenant_by_slug/1`) — outside every per-tenant schema,
  so there is no `:prefix` to derive and INV-1 does not apply.
  """

  use Plug.Router

  alias Letflow.Api.Response
  alias Letflow.Identity
  alias Letflow.Identity.Tenant

  # Ported in the same spirit as Letflow.Routers.TenantConfig's own
  # @default_idp_base_url/@default_realm -- adjustable placeholders (design
  # OQ-1/OQ-3), not load-bearing values.
  @default_idp_base_url "http://localhost:8081"
  @default_realm "bpm-default"
  @default_locales ["en"]
  @default_locale "en"
  @default_branding %{
    "app_name" => "Letflow",
    "logo_url" => nil,
    "primary_color" => "#0B5FFF"
  }
  @default_environment_kind "development"

  plug(:match)
  plug(:dispatch)

  get "/" do
    handle_mobile_tenant_config(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── GET /api/mobile/tenant-config (design §3) ─────────────────────────────
  #
  # There is no error map by design: EVERY path returns 200 with the full
  # 5-field body. See the moduledoc's never-error rule.

  @spec handle_mobile_tenant_config(conn :: Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_mobile_tenant_config(conn) do
    conn = fetch_query_params(conn)
    slug = non_empty(Map.get(conn.query_params, "slug"))

    realm_id = resolve_realm_id(slug)

    Response.ok(conn, mobile_config_map(realm_id))
  end

  # Keyed only on ?slug= -- no ?host= branch (design OQ-2). A hit with a
  # non-nil, non-empty idp_realm_id wins; every other case (miss, nil realm,
  # lookup error, missing/absent slug) falls through to the default realm.
  @spec resolve_realm_id(slug :: String.t() | nil) :: String.t()
  defp resolve_realm_id(nil), do: @default_realm

  defp resolve_realm_id(slug) when is_binary(slug) do
    case Identity.safe_get_tenant_by_slug(slug, "mobile-tenant-config") do
      {:ok, %Tenant{idp_realm_id: realm_id}} when is_binary(realm_id) and realm_id != "" ->
        realm_id

      _miss_or_nil_realm_or_error ->
        @default_realm
    end
  end

  # The never-raise, INV-4-compliant lookup wrapper itself is shared with
  # Letflow.Routers.TenantConfig via Letflow.Identity.safe_get_tenant_by_slug/2
  # (hoisted there per REVIEWER's REQ-124 rework -- see that function's @doc).

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value
  defp non_empty(_other), do: nil

  # ── Response allowlist (INV-2) ────────────────────────────────────────────

  # EXACTLY five keys, hand-built, never derived from %Tenant{}. Adding a
  # sixth key here is a security change -- see the moduledoc.
  @doc """
  Builds the hand-built 5-key mobile tenant-config response map for the
  given (already-resolved) `realm_id`. Never derived from
  `%Letflow.Identity.Tenant{}` or `Map.from_struct/1` -- see the moduledoc's
  INV-2 allowlist statement. `locales`, `default_locale` and `branding` are
  global static defaults (design OQ-1); `environment_kind` is env-derived.
  """
  @spec mobile_config_map(realm_id :: String.t()) :: %{
          required(String.t()) => String.t() | [String.t()] | map()
        }
  def mobile_config_map(realm_id) do
    %{
      "realm_url" => idp_base_url() <> "/realms/" <> realm_id,
      "locales" => @default_locales,
      "default_locale" => @default_locale,
      "branding" => @default_branding,
      "environment_kind" => environment_kind()
    }
  end

  # Read at the point of use via System.get_env/1, never threaded through a
  # struct field and never logged (INV-4). Neither is secret material -- an
  # OIDC realm URL, locale defaults and an environment label are all values
  # the mobile app must learn before it can authenticate -- but the
  # resolution style follows INV-4 regardless.
  @spec idp_base_url() :: String.t()
  defp idp_base_url do
    System.get_env("BPM_IDP_BASE_URL") || System.get_env("KEYCLOAK_BASE_URL") ||
      @default_idp_base_url
  end

  @spec environment_kind() :: String.t()
  defp environment_kind,
    do: System.get_env("LETFLOW_ENVIRONMENT_KIND") || @default_environment_kind
end
