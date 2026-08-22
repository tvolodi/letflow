# REQ-124 — Mobile tenant-config bootstrap (design)

**Status:** design, pre-implementation. **Stage:** S9 (mobile tier, `docs/mobile/`).
**Gate for:** MOB-2 (`docs/mobile/requirements.md`), the single blocking dependency for
the entire mobile tier per `docs/mobile/build-order.md` phase M-0.

## 0. Corrected premises (per this run's task.description)

`Letflow.Routers.TenantConfig` is **not** a stub — REQ-078 fully implemented it at
`GET /api/tenant-config`, forwarded from `Letflow.Router` **ahead of and outside**
`Letflow.Plugs.ApiPipeline`, so it never passes through `Letflow.Plugs.AuthPipeline`.
That placement pattern is done, correct, and **not redesigned here** — it is reused
verbatim for the new mobile route (§2).

What REQ-124 actually adds: the existing endpoint's response is a 2-field shape
(`{oidc_authority, client_id}`) built for the web SPA's OIDC bootstrap. MOB-2 needs a
**different 5-field shape** (`{realm_url, locales, default_locale, branding,
environment_kind}`) for mobile bootstrap. This design covers only that delta.

## 1. Decision: new route + new module, not a discriminator on the existing route

**Chosen: a second module, `Letflow.Routers.MobileTenantConfig`, mounted at a second
path, `GET /api/mobile/tenant-config`**, forwarded from `Letflow.Router` the same way
`Letflow.Routers.TenantConfig` is — ahead of the `/api/v1` forward, outside
`Letflow.Plugs.ApiPipeline`.

**Rejected alternative: `?client=mobile`-style discriminator on the existing
`/api/tenant-config` route.** Reasons against:

- `Letflow.Routers.TenantConfig`'s `config_map/1` is a hand-built 2-key allowlist
  (INV-2) whose moduledoc states outright *"Adding a third key to this response is a
  security change, not a feature."* Branching the same handler function between a
  2-key and a 5-key response map means every future change to either shape has to be
  read against a shared function to confirm it didn't leak a key across branches. Two
  functions in two modules means each allowlist is visually and structurally isolated
  — a reviewer (or SECURITY-REVIEWER) auditing the 2-key shape never has to reason
  about the 5-key branch at all, and vice versa.
- The existing moduledoc's entire "What this endpoint discloses" section is written
  in terms of exactly two keys. Overloading the same route would require rewriting
  that section to describe two shapes under one path, weakening a document that is
  currently unambiguous.
- `docs/mobile/requirements.md` MOB-2's caller is a fresh mobile client with no
  existing integration to preserve — there is no cost to giving it its own path, and
  a distinct path is one fewer thing for a mobile client to get wrong (no query
  param whose absence silently degrades behavior — see `?host=`'s fallback pattern in
  the existing module, which is exactly the kind of implicit branching this decision
  avoids repeating).
- This mirrors the project's own established pattern: one small, single-purpose
  router module per concern (`Letflow.Routers.Identity`, `.Tenants`, `.Instances`,
  …), rather than one module serving multiple response contracts keyed off a
  parameter.

Cost accepted: two moduledocs each restate the never-error/anti-oracle reasoning
(§4) instead of one. This is intentional — REQ-078's own moduledoc is the load-bearing
precedent both must independently satisfy, and duplication here is cheaper than a
shared abstraction that would couple two otherwise-independent response contracts.

## 2. Mount / auth-pipeline placement (explicit resolution, AC2)

`Letflow.Router` gains one new line, declared immediately after the existing
`/api/tenant-config` forward and still before `/api/v1`:

```
forward("/api/mobile/tenant-config", to: Letflow.Routers.MobileTenantConfig)
```

**Mechanism chosen: unauthenticated variant mounted ahead of `Letflow.Plugs.ApiPipeline`
(and therefore ahead of `Letflow.Plugs.AuthPipeline`)** — identical mechanism to
`Letflow.Routers.TenantConfig` and `GET /health`.

**Why, stated explicitly for this route (not silently inherited):** MOB-2's caller is
the mobile app before it holds any token — resolving tenant identity and fetching
config is a precondition for starting the OIDC Authorization-Code+PKCE flow, so a
token cannot exist yet. `Letflow.Plugs.AuthPipeline` has no public-path allowlist or
skip option (confirmed by reading it in full — `call/2`'s `with` chain has no branch
that bypasses `extract_bearer_token/1`), so mounting this route inside
`Letflow.Plugs.ApiPipeline` would make it unreachable by the only caller that needs
it, exactly as REQ-078's moduledoc already established for the web SPA case. This
design's module's own moduledoc must restate this reasoning locally (see §7's
moduledoc outline) rather than only cross-referencing REQ-078's, per the task's
explicit instruction not to let it "silently assume it carries over."

`Letflow.Plugs.Cors` (mounted on `Letflow.Router` itself, ahead of `plug(:match)`,
covering every route matched by the router — confirmed by reading
`lib/letflow/plugs/cors.ex` and `Letflow.Router`) requires **no change**: it is
origin-based, not path-based, so `/api/mobile/tenant-config` is covered automatically,
the same way `/api/tenant-config` already is.

No trace id: same reasoning as `Letflow.Routers.TenantConfig` — mounted outside
`Letflow.Plugs.ApiPipeline`, so `Letflow.Api.Context.assign_trace_id/1` never runs and
`conn.assigns[:trace_id]` is absent. Harmless (this module also never emits a problem
document — see §4).

## 3. Public function signatures

```
defmodule Letflow.Routers.MobileTenantConfig do
  use Plug.Router

  # GET /api/mobile/tenant-config?slug=<tenant_slug>
  @spec handle_mobile_tenant_config(conn :: Plug.Conn.t()) :: Plug.Conn.t()

  # Resolves realm_id the same way Letflow.Routers.TenantConfig's resolve_realm/2
  # does, but keyed only on ?slug= (no ?host= branch -- see §5 Open question OQ-2).
  # Returns the realm id string on any resolvable slug with a non-nil idp_realm_id;
  # falls through to the default realm id on every other case.
  @spec resolve_realm_id(slug :: String.t() | nil) :: String.t()

  # Hand-built 5-key allowlist (INV-2). Never derived from %Letflow.Identity.Tenant{}.
  # realm_id: String.t() -- either a resolved tenant's idp_realm_id or the default
  # realm id constant.
  @spec mobile_config_map(realm_id :: String.t()) :: %{
          required(String) => String.t() | [String.t()] | map()
        }
  # concretely:
  # %{
  #   "realm_url"        => String.t(),           # idp_base_url() <> "/realms/" <> realm_id
  #   "locales"          => [String.t()],          # global static list, see §5 OQ-1
  #   "default_locale"   => String.t(),            # global static value, see §5 OQ-1
  #   "branding"         => %{"app_name" => String.t(), "logo_url" => String.t() | nil,
  #                            "primary_color" => String.t()},  # see §5 OQ-1
  #   "environment_kind" => String.t()              # "development" | "staging" | "production"
  # }

  # Same failure-swallowing shape as Letflow.Routers.TenantConfig.safe_get_tenant_by_slug/1
  # -- rescues any exception from the DB call, logs the (caller-supplied, therefore
  # safe-to-log) slug only, never the exception (INV-4), and reduces to {:error, _}.
  @spec safe_get_tenant_by_slug(slug :: String.t()) ::
          {:ok, Letflow.Identity.Tenant.t()} | {:error, :not_found | :lookup_failed}

  # Env-read helpers, same style as idp_base_url/0 and client_id/0 in
  # Letflow.Routers.TenantConfig -- read at point of use, never threaded through a
  # struct field, never logged (INV-4).
  @spec idp_base_url() :: String.t()
  @spec environment_kind() :: String.t()
end
```

No other public functions. `match _ do Response.not_found(conn) end` for any path
under this forward other than `GET /`, mirroring `Letflow.Routers.TenantConfig`.

## 4. Never-error rule and unknown-slug behavior (AC1, AC4)

**The never-error rule applies identically to this route.** Every code path —
resolvable slug, unknown slug, missing `?slug=` param, DB error/exception — returns
`200` with a full 5-field body. There is no `404`, no partial body, no absent field.

**Unknown-slug / missing-slug decision: falls through to the default-realm config,
same status code and same body shape as any resolvable slug, mirroring
`Letflow.Routers.TenantConfig`'s `?realm=` handling exactly.**

Justification (mirrors the existing moduledoc's INV-5/anti-oracle reasoning, restated
for this shape rather than assumed to carry over):

1. **Availability.** The mobile app cannot proceed past its bootstrap screen without
   a config. A `404`/`500` here strands the user before they ever see a login screen
   — the one failure mode MOB-2 exists to prevent.
2. **Anti-enumeration (INV-5-flavored, applied to an unauthenticated per-tenant
   endpoint).** A miss (`{:error, :not_found}` from `get_tenant_by_slug/1`), a slug
   with no `idp_realm_id` set, a lookup exception, and a missing `?slug=` param all
   produce the byte-identical default body. A caller with a wordlist cannot
   distinguish "this slug does not exist" from "this slug exists but has no realm
   bound" from "the DB call failed" — all three collapse to one answer, so none of
   them functions as an existence oracle.
3. **What remains inferable, and why it's accepted (same boundary as the existing
   endpoint).** A caller who supplies a *real* slug bound to a non-default realm gets
   back a non-default `realm_url` in a shape different from the default-tenant
   response. That is unavoidable — the endpoint's whole purpose is telling the app
   which realm to authenticate against — and is the same information any user of that
   tenant already sees at their own login screen. It is not a *new* disclosure beyond
   what `Letflow.Routers.TenantConfig` already accepts for the same reason.

`locales`, `default_locale`, `branding`, and `environment_kind` are **never**
tenant-derived (see §5 OQ-1) — only `realm_url` varies by slug at all, so the
unknown-slug question only actually affects one of the five fields; the other four
are byte-identical across every branch by construction, which further narrows the
enumeration surface versus the two-field web shape.

## 5. DB reads / no migration (per task: no tenant_hostnames-style table here either)

**Global `tenants` table only** (same table `Letflow.Routers.TenantConfig` reads),
via `Letflow.Identity.get_tenant_by_slug/1` — no new query function needed, no new
migration. Columns read: `slug` (lookup key), `idp_realm_id` (only field consumed).
No other tenant column (`display_name`, `status`, `id`) is read or ever placed in the
response body.

**No tenant scoping call** — same reasoning as `Letflow.Routers.TenantConfig`: this
route is unauthenticated by design, reads only the global `tenants` table (outside
every per-tenant schema), so there is no `:prefix` to derive and INV-1 does not apply
(no business-data table is touched).

**Open question OQ-1 — `locales` / `default_locale` / `branding` / `environment_kind`
have no backing column, and this design does NOT add one.** Verified: `Letflow.Identity.Tenant`'s
schema (`lib/letflow/identity/tenant.ex`) has exactly `slug`, `display_name`, `status`,
`idp_realm_id` — no locale, branding, or environment field of any kind. Per the task's
explicit instruction ("no migration... the same reasoning applies here"), this design
does **not** add `tenants` columns for these four fields. Consequence, stated
explicitly rather than silently assumed:

- These four fields are **global, not per-tenant**, sourced from application
  config/env (same `System.get_env/1`-at-point-of-use style as `idp_base_url/0` and
  `client_id/0` in the existing module), with hardcoded defaults ported in the same
  spirit as `@default_idp_base_url`/`@default_client_id`/`@default_realm`.
- This is consistent with `docs/frontend/frontend-requirements.md`'s REQ-127 finding
  (cited in `docs/mobile/requirements.md` MOB-7): **the web platform has no locale
  policy today** — no `{locale: value}` tenant-content map, no configured locale set.
  Mobile therefore cannot inherit a per-tenant locale/branding policy that does not
  exist upstream; defining one per-tenant is out of this requirement's scope (it would
  require its own schema change, migration, and admin UI — a separate requirement).
- Concretely: `locales` defaults to `["en"]`, `default_locale` defaults to `"en"`,
  `branding` defaults to a minimal static map (`app_name`, `logo_url: nil`,
  `primary_color`), `environment_kind` defaults to `"development"` and is overridable
  via `LETFLOW_ENVIRONMENT_KIND` (mirroring `BPM_IDP_BASE_URL`/`KEYCLOAK_BASE_URL`'s
  env-first-then-default pattern). **CODE-DESIGN-VALIDATOR / a later requirement
  should confirm this "global for now" framing is acceptable** — it is the only way
  to satisfy MOB-2's exact field list without an out-of-scope schema change, but it
  means two tenants sharing this backend currently get identical branding/locale
  data, which may need revisiting once tenant branding is a real requirement. Not
  silently resolved: flagged here as an explicit open question for
  CODE-DESIGN-VALIDATOR / REVIEWER to accept or reject before ELIXIR-DEV builds it.

**Open question OQ-2 — no `?host=` branch on the mobile route.** MOB-2 describes slug
resolution as "deep-link subdomain or manual slug entry" — both resolve to a slug
before the app calls this endpoint, unlike the web SPA's `?host=` fallback (used when
no slug is known yet, e.g. a bare browser hit). This design therefore gives the mobile
route a single `?slug=<tenant_slug>` parameter and no `?host=` parameter/branch.
CODE-DESIGN-VALIDATOR should confirm this matches MOB-2's intended caller behavior; if
a future requirement needs subdomain-based host resolution server-side, that is a new
parameter, not a retrofit of `Letflow.Routers.TenantConfig`'s existing (currently
always-default-falling-through) `?host=` handling, since **Letflow still has no
host→tenant binding of any kind** — same constraint the existing module documents,
unchanged by this requirement.

## 6. Response shape per branch (exhaustive)

| Branch | `realm_url` | `locales` | `default_locale` | `branding` | `environment_kind` | Status |
|---|---|---|---|---|---|---|
| `?slug=` resolves, `idp_realm_id` set | `<idp_base_url>/realms/<idp_realm_id>` | global default | global default | global default | env-derived | 200 |
| `?slug=` resolves, `idp_realm_id` nil/empty | `<idp_base_url>/realms/bpm-default` | global default | global default | global default | env-derived | 200 |
| `?slug=` does not resolve (`:not_found`) | `<idp_base_url>/realms/bpm-default` | global default | global default | global default | env-derived | 200 |
| `?slug=` absent/empty | `<idp_base_url>/realms/bpm-default` | global default | global default | global default | env-derived | 200 |
| DB call raises | `<idp_base_url>/realms/bpm-default` | global default | global default | global default | env-derived | 200 |

No branch returns a status other than 200; no branch returns a body with fewer or
more than 5 keys.

## 7. Moduledoc outline (ELIXIR-DEV must include, not optional prose)

`Letflow.Routers.MobileTenantConfig`'s moduledoc must contain, at minimum, sections
answering: (a) why mounted ahead of `Letflow.Plugs.ApiPipeline`/`AuthPipeline` (§2,
restated locally); (b) the never-error rule and why (§4, restated locally — do not
only cross-reference `Letflow.Routers.TenantConfig`'s moduledoc, since a reader of
this module alone must not have to chase a second file to find load-bearing
reasoning); (c) exactly which fields are disclosed and the INV-2 hand-built-allowlist
statement, matching `config_map/1`'s "adding a third key is a security change"
framing but for a fifth/sixth key on this shape; (d) the unknown-slug justification
(§4); (e) OQ-1's explicit "these four fields are global, not per-tenant" framing,
so a later reader does not mistake the static defaults for a bug.

## 8. Invariants

- **INV-2.** `mobile_config_map/1` is a hand-built map literal with exactly 5 keys,
  never `Map.from_struct/1` or similar derivation from `%Letflow.Identity.Tenant{}`.
  Adding a 6th key is a security-relevant change requiring SECURITY-REVIEWER, same as
  the existing module's rule.
- **INV-5-flavored (anti-oracle).** Every failure/miss/absence branch in §6 is
  byte-identical; no branch is distinguishable by status code, body shape, or
  presence/absence of a field.
- **INV-4.** No secret material exists in this response (an OIDC realm URL and
  locale/branding metadata are all pre-auth-required public values, same class as the
  existing module's `oidc_authority`/`client_id`) but the env-read style (read at
  point of use, never threaded through a struct field, never logged) is followed
  regardless, matching the existing module's stated policy.
- **INV-1.** Not applicable — no business-data table touched, no `:prefix` to derive
  (§5).
- No migration added (§5, OQ-1) — confirmed no new columns needed for `realm_url`
  (derived, same mechanism as `oidc_authority`); the other four fields are global
  config, not schema fields.

## 9. Acceptance-criteria resolution map

| # | Acceptance criterion | Resolved by |
|---|---|---|
| 1 | 5-field response, no `Authorization` header, known slug | §2 mount placement (unauthenticated, ahead of `ApiPipeline`); §3 `mobile_config_map/1`; §6 row 1 |
| 2 | Auth-pipeline placement stated explicitly in moduledoc for the mobile shape, not assumed inherited | §2 (explicit local reasoning required); §7(a) |
| 3 | Exact-shape test (no field beyond the five) | §3 `mobile_config_map/1`'s fixed 5-key map; §8 INV-2 — test strategy: `assert Map.keys(body) |> Enum.sort() == ["branding", "default_locale", "environment_kind", "locales", "realm_url"]`, an exact-set assertion, not `assert_subset`/pattern match on a few keys |
| 4 | Unknown-slug behavior decided, tested, justified against enumeration | §4; §6 rows 2-5 all byte-identical to the default branch |
| 5 | Every other `Letflow.Plugs.ApiPipeline` route still requires auth | No change to `Letflow.Plugs.ApiPipeline`'s plug chain (§2 — new route mounted only on `Letflow.Router`, never inside `ApiPipeline`); test strategy: an existing/representative `ApiPipeline`-mounted route (e.g. `GET /api/v1/tenants`) called with no `Authorization` header still returns 401 — proves the exemption is route-specific to the two `Letflow.Router`-level forwards, not pipeline-wide |

## 10. Cross-module dependencies

- `Letflow.Router` — one new `forward/2` line (§2).
- `Letflow.Identity.get_tenant_by_slug/1` — read-only, unchanged, reused.
- `Letflow.Api.Response` — `Response.ok/2` for the 200 body (reused, same as
  `Letflow.Routers.TenantConfig`), `Response.not_found/1` for any unmatched sub-path.
- No change to `Letflow.Plugs.ApiPipeline`, `Letflow.Plugs.AuthPipeline`, or
  `Letflow.Plugs.Cors`.
- No change to `Letflow.Routers.TenantConfig` (existing 2-field shape untouched).

## 11. Open questions (explicit, not silently resolved)

- **OQ-1** (§5): the four global (non-per-tenant) fields' exact default values and
  the `LETFLOW_ENVIRONMENT_KIND` env var name are this design's proposal, not a
  value pinned by any existing config or requirement text — CODE-DESIGN-VALIDATOR
  should confirm these are acceptable placeholders, and ELIXIR-DEV should treat the
  literal default strings as adjustable-on-review, not load-bearing.
- **OQ-2** (§5): no `?host=` branch on the mobile route — confirm this matches
  MOB-2's intended slug-resolution flow before implementation.
- **OQ-3**: `branding`'s internal shape (`app_name`/`logo_url`/`primary_color`) is
  this design's proposal only — MOB-2's acceptance criteria name the top-level field
  `branding` but specify no sub-schema. If a later mobile-tier requirement defines a
  concrete branding contract, this map's internal keys are revised then, not
  guessed further now.
