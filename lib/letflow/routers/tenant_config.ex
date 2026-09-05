defmodule Letflow.Routers.TenantConfig do
  @moduledoc """
  Public login-bootstrap sub-router (REQ-078, design
  `lib/letflow/design/req078-supporting-routes.md` §12). Ports
  `src/api/routes/tenant_config.zig`'s `handleTenantConfig` (L52).

  | Handler | Method/path            | Delegate                                | Auth     | Response |
  |---------|------------------------|-----------------------------------------|----------|----------|
  | config  | `GET /api/tenant-config` | `Letflow.Identity.get_tenant_by_slug/1` | **none** | always 200, `{oidc_authority, client_id}` |

  ## Why this is mounted on `Letflow.Router`, NOT in `Letflow.Plugs.ApiPipeline`

  R-Co's endpoint is **explicitly public** — `tenant_config.zig:3` says
  "Public endpoint (no auth required)" and `main.zig:462` carries the same
  comment. Its purpose is login-page bootstrap: the SPA calls it to learn
  which OIDC authority to redirect to, **before** it has any token.
  `web/src/auth/tenantConfig.ts:46` calls exactly `/api/tenant-config`.

  REQ-070 reserved this module at `/tenant-config` **inside**
  `Letflow.Plugs.ApiPipeline`, i.e. behind `Letflow.Plugs.AuthPipeline`. Read
  in full, that plug has **no public-path allowlist, no bypass and no `skip`
  option** — every request reaching it without a valid bearer token gets 401.
  A login-bootstrap endpoint behind auth is unreachable by the only caller
  that needs it. That is not a preference; it is a functional defect in the
  reserved mount point.

  So this module is forwarded from **`Letflow.Router`** —
  `forward("/api/tenant-config", to: Letflow.Routers.TenantConfig)`, declared
  before the `/api/v1` forward, exactly as `GET /health` is. The module file
  did not move; only its mount did. The `/tenant-config` forward inside
  `ApiPipeline` was removed.

  ## The never-error rule is LOAD-BEARING, not an R-Co quirk

  `tenant_config.zig:50-51` states it outright: *"Never returns an error to
  the caller — DB failures fall through to the default tenant config so the
  frontend login page always renders."* Ported **exactly**, for two
  independent reasons:

    1. **Availability.** The login page cannot render without a config. A 500
       here locks every tenant out.
    2. **INV-5 / anti-oracle.** A miss, an unprovisioned host, a malformed
       slug and a database outage all produce **the same 200 with the same
       default body**. There is no status code, no error body and no absent
       field from which a prober could learn whether a given hostname or slug
       corresponds to a real tenant. Returning 404 for an unknown host — the
       "tidier" REST answer — would turn this endpoint into a tenant-existence
       oracle for anyone with a wordlist.

  A caller **can** still infer that a slug is bound to *some* realm when it
  gets back a non-default realm id. That is unavoidable: telling the browser
  which realm to use is the endpoint's entire purpose, and it is the same
  information any user of that tenant sees on their own login page.

  ## What this endpoint discloses, and what it must never disclose

  It returns exactly two values: an OIDC authority URL (which embeds a realm
  id) and a public client id. Both are values the browser must learn *before*
  authenticating, and both are visible to any user of that tenant. It must
  **never** return a tenant id, slug, display name, status, user count, or any
  other tenant attribute — the response map is hand-built with exactly the two
  keys and is **never** derived from `%Letflow.Identity.Tenant{}` (INV-2).
  **Adding a third key to this response is a security change, not a feature.**

  ## Precedence

    1. `?realm=<slug>` present — resolve the tenant by slug; if it resolves and
       has a non-nil `idp_realm_id`, that wins and the host branch is
       **skipped**.
    2. Otherwise `?host=<hostname>` — see below; today this always falls
       through to the default realm.
    3. Otherwise, or on any miss, or on **any** error — the default realm.

  ## `?host=` is accepted, and today always falls through to the default

  R-Co resolves `?host=` by joining `tenant_hostnames` -> `tenant`
  (`tenant_config.zig:167-207`). **Letflow has no host->tenant binding of any
  kind** — `grep -rn "tenant_hostname\\|hostname" lib/ priv/repo/migrations/`
  returns zero hits. Letflow has only realm->tenant and slug->tenant.

  Adding a `tenant_hostnames` table, Ecto schema and migration here was
  **considered and rejected**: no acceptance criterion asks for it, nothing in
  this requirement would ever write to it, and a table with no writer is a
  partial backing subsystem shipped with no producer — the **REQ-056 failure
  mode**, which REQ-078's own text invokes twice as the reason
  `sandbox_access.zig` is not ported. We cannot decline to port a guard with
  no caller in one paragraph and add a table with no writer in the next.
  **REQ-078 therefore adds NO migration at all.**

  So `?host=` is honoured syntactically and produces the default config —
  which is **byte-identical to what R-Co produces for an unbound hostname**
  (`tenant_config.zig:81-102` leaves `realm_id = "bpm-default"`). Since
  Letflow has no bindings at all, every hostname is unbound, and the default
  config is the one served — a graceful degradation of an unimplemented
  feature, not a functional non-port.

  This works today for the only caller:
  `web/src/auth/tenantConfig.ts:43-45` resolves a realm slug from
  `sessionStorage`/the URL **first** and passes `{realm: slug}`, falling back
  to `{host: hostname}` only when no slug is known. The supported branch is
  the preferred branch.

  **Owner of hostname->tenant binding: REQ-076 (tenant onboarding)** — the
  point at which a tenant acquires an identity a hostname could be bound to.
  **A later reader must not "fix" this by adding a migration without an owning
  requirement.**

  ## No trace id on this endpoint

  Because this module is mounted outside `Letflow.Plugs.ApiPipeline`, it does
  not get `Plug.Parsers`, `Letflow.Plugs.AuthPipeline`,
  `Letflow.Plugs.TenantStatus`, or
  `Letflow.Api.Context.assign_trace_id/1` — so `conn.assigns[:trace_id]` is
  absent and no `x-trace-id` response header is set. Harmless today (this
  endpoint emits no problem document, ever), but it is an inconsistency with
  every other Letflow endpoint. It is **not** fixed by mounting
  `assign_trace_id/1` on `Letflow.Router`, because that would change
  `GET /health`'s response headers, which `deploy/redeploy-test.sh` pins (see
  `Letflow.Router`'s moduledoc). It is a `GET` with no body, so `Plug.Parsers`
  is not needed; this module calls `Plug.Conn.fetch_query_params/1` itself.

  ## No tenant scoping call, deliberately

  This is the one REQ-078 route that does **not** call
  `Letflow.Api.Context.scoped_repo_opts/1`. It is unauthenticated by design
  and reads only the **global** `tenants` table, which lives outside every
  per-tenant schema — there is no prefix to derive and no per-tenant row to
  reach.
  """

  use Plug.Router

  alias Letflow.Api.Response
  alias Letflow.Identity
  alias Letflow.Identity.Tenant

  # Ported from tenant_config.zig:59/:60/:62, then corrected under REQ-133:
  # the literal ported defaults named R-Co's nginx gateway port (8081) and
  # client id (bpm-platform-api) verbatim, both stale against Letflow's own
  # Keycloak -- REQ-128's docker-compose.yml/config/keycloak_port.exs default
  # to port 8082, and REQ-128's config/dev.exs :oidc client_id is
  # "letflow-web" (priv/keycloak/realms/bpm-default.json's only client).
  # This endpoint is what the SPA actually calls at runtime (its own
  # web/src/auth/{OidcManager,tenantConfig}.ts defaults are a same-value
  # fallback for when this call fails, not the effective source of truth),
  # so a stale default here silently overrides a correct SPA-side default.
  @default_idp_base_url "http://localhost:8082"
  @default_client_id "letflow-web"
  @default_realm "bpm-default"

  plug(:match)
  plug(:dispatch)

  get "/" do
    handle_tenant_config(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── GET /api/tenant-config (design §12) ───────────────────────────────────
  #
  # There is no error map by design: EVERY path returns 200 with either the
  # resolved config or the default config. See the moduledoc.

  defp handle_tenant_config(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    realm_id =
      resolve_realm(non_empty(Map.get(query, "realm")), non_empty(Map.get(query, "host")))

    Response.ok(conn, config_map(realm_id))
  end

  # Step 1: ?realm=<slug>. A hit with a non-nil idp_realm_id wins outright and
  # the host branch is skipped.
  defp resolve_realm(slug, host) when is_binary(slug) do
    case Identity.safe_get_tenant_by_slug(slug, "tenant-config") do
      {:ok, %Tenant{idp_realm_id: realm_id}} when is_binary(realm_id) and realm_id != "" ->
        realm_id

      _miss_or_nil_realm_or_error ->
        resolve_realm(nil, host)
    end
  end

  # Step 2: ?host=<hostname>. Letflow has no host->tenant binding, so this
  # always falls through to the default -- which is exactly what R-Co returns
  # for an unbound hostname. See the moduledoc; do NOT add a table here.
  defp resolve_realm(nil, host) when is_binary(host), do: @default_realm

  # Step 3: neither parameter.
  defp resolve_realm(nil, _absent_host), do: @default_realm

  # The never-raise, INV-4-compliant lookup wrapper itself is shared with
  # Letflow.Routers.MobileTenantConfig via Letflow.Identity.safe_get_tenant_by_slug/2
  # (hoisted there per REVIEWER's REQ-124 rework -- see that function's @doc).

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value
  defp non_empty(_other), do: nil

  # ── Response allowlist (INV-2) ────────────────────────────────────────────

  # EXACTLY two keys, hand-built, never derived from %Tenant{}. Adding a third
  # key here is a security change -- see the moduledoc.
  defp config_map(realm_id) do
    %{
      "oidc_authority" => idp_base_url() <> "/realms/" <> realm_id,
      "client_id" => client_id()
    }
  end

  # Read at the point of use via System.get_env/1, never threaded through a
  # struct field and never logged (INV-4). None of these is secret material --
  # an OIDC authority URL and a public client id are values the browser must
  # learn in order to log in at all -- but the resolution style follows INV-4
  # regardless.
  defp idp_base_url do
    System.get_env("BPM_IDP_BASE_URL") || System.get_env("KEYCLOAK_BASE_URL") ||
      oidc_issuer_base() ||
      @default_idp_base_url
  end

  # Derive the IDP base URL from the compiled :oidc issuer, which is already
  # set correctly via config/keycloak_port.exs for every workspace.
  defp oidc_issuer_base do
    case Application.get_env(:letflow, :oidc, [])[:issuer] do
      nil -> nil
      issuer -> issuer |> String.split("/realms/") |> List.first()
    end
  end

  defp client_id, do: System.get_env("OIDC_CLIENT_ID") || @default_client_id
end
