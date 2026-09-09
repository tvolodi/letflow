# REQ-281 — `GET /api/tenant-config`: a third response key, `branding`

Status: design (CODE-DESIGNER). Implements the web half of
`docs/migration/decisions/0020-frontend-architecture.md`'s Sequencing step 5.
THIS IS A SECURITY CHANGE, per `lib/letflow/routers/tenant_config.ex`'s own
moduledoc. Depends on REQ-280 (`lib/letflow/design/req280-tenant-settings-store.md`),
already merged (`46d43a5d`, PR #1118) — `tenants.settings` (`Letflow.Identity.TenantSettings`,
closed 5-key vocabulary) exists and is readable today.

## 1. Re-verification (against the live tree, not the requirement text's claims)

**Current response-building function**, `lib/letflow/routers/tenant_config.ex:217-222`,
quoted verbatim:

```
defp config_map(realm_id) do
  %{
    "oidc_authority" => idp_base_url() <> "/realms/" <> realm_id,
    "client_id" => client_id()
  }
end
```

Confirmed: exactly two keys, hand-built map literal, `realm_id` is a bare string
threaded in from `resolve_realm/2` — no `%Tenant{}` struct or `Map.from_struct/1`
anywhere in this function or its callers. INV-2 holds today.

**Current moduledoc "security change" paragraph**, `tenant_config.ex:58-66`,
quoted verbatim (the "What this endpoint discloses..." section):

> It returns exactly two values: an OIDC authority URL (which embeds a realm
> id) and a public client id. Both are values the browser must learn *before*
> authenticating, and both are visible to any user of that tenant. It must
> **never** return a tenant id, slug, display name, status, user count, or any
> other tenant attribute — the response map is hand-built with exactly the two
> keys and is **never** derived from `%Letflow.Identity.Tenant{}` (INV-2).
> **Adding a third key to this response is a security change, not a feature.**

**Sole caller**, `web/src/auth/tenantConfig.ts:41-46`, confirmed by direct read:
`fetchTenantConfig/1` resolves a realm slug (`resolveRealmFromUrl/0`, sessionStorage
or `?realm=` URL param), builds `params = realmSlug ? {realm: realmSlug} : {host: hostname}`,
and calls `client.get<TenantConfig>('/api/tenant-config', params)`. No other
caller of this path exists in `web/`.

**Mount point, confirmed pre-authentication**: `Letflow.Router` forwards
`/api/tenant-config` to `Letflow.Routers.TenantConfig` ahead of the `/api/v1`
forward, outside `Letflow.Plugs.ApiPipeline` and therefore outside
`Letflow.Plugs.AuthPipeline` — no bearer token is required or checked
(`tenant_config.ex:12-33`'s moduledoc section, re-verified against
`Letflow.Router`'s own forward list — unchanged by this requirement).

**Never-error mechanism today**, confirmed by reading `resolve_realm/2`
(`tenant_config.ex:186-202`) and `Identity.safe_get_tenant_by_slug/2`: every
branch — resolvable slug, unknown slug (`{:error, :not_found}`), malformed/empty
slug (`non_empty/1` normalizes to `nil` before lookup is even attempted), and a
raised exception during lookup (`safe_get_tenant_by_slug/2`'s `rescue` clause,
`{:error, :lookup_failed}`) — converges on the same `resolve_realm(nil, host)` /
`@default_realm` path and calls `config_map/1` exactly once, unconditionally,
at `handle_tenant_config/1`'s single `Response.ok(conn, config_map(realm_id))`
call site. There is no branch anywhere in this router that returns a different
status code or skips building the map.

## 2. Scope question — which settings keys does `branding` disclose?

**Decision: three keys only — `app_name`, `logo_url`, `brand_colors`.**
`locales` and `default_locale` are **excluded** from this endpoint's `branding`
key.

Justification, from the requirement's own framing (constraint 2, quoted in
REQ-281's `docs/requirements.yaml` entry): "acceptable for an app name, a logo
URL and a brand colour and unacceptable for anything else." This is an
enumerated three-item list, not a pointer to "whatever REQ-280 stores." REQ-280's
five-key vocabulary is a **superset** built for the union of both bootstrap
endpoints' eventual needs (mobile's existing 5-key response already discloses
locale information via its own `locales`/`default_locale` fields, sourced today
from static config, not yet from this store — that reconciliation is REQ-282's
job, not this one). This endpoint (`GET /api/tenant-config`) has never disclosed
locale information and REQ-281's requirement text does not ask it to start —
"acceptable... unacceptable for anything else" is a closed allowlist statement,
and locale codes are not on it. Widening to all five keys here would be scope
creep beyond what REQ-281 was asked to build, and would need its own
security-change justification the requirement text does not supply.

**Consequence for the closed allowlist (constraint 2 / AC4):** the `branding`
key's own inner allowlist is `["app_name", "logo_url", "brand_colors"]` —
narrower than `TenantSettings`'s five-key vocabulary. `locales` and
`default_locale`, even if present in a tenant's stored `settings` map, must
never appear inside `branding` or anywhere else in this endpoint's response.

## 3. Shape of the third key

**Key name:** `"branding"` (string key, matching the existing two keys' string-key
convention and matching mobile's existing `"branding"` key name in
`mobile_tenant_config.ex` — same name, deliberately, since both disclose the
same *kind* of information, even though this endpoint's `branding` sub-shape and
mobile's differ per §4 below).

**Value shape**, expressed as a type (no implementation):

```
%{
  required(String.t()) => String.t() | nil | %{required(String.t()) => String.t()}
}
```

Concretely, always exactly these three sub-keys, always present regardless of
what is or isn't stored:

| Sub-key | Type | Source when tenant has stored settings | Source when absent/miss/error |
|---|---|---|---|
| `"app_name"` | `String.t()` | `tenant.settings["app_name"]` if present | platform default (§4) |
| `"logo_url"` | `String.t() \| nil` | `tenant.settings["logo_url"]` if present | platform default (§4) |
| `"brand_colors"` | `%{"primary" => String.t()}` | `tenant.settings["brand_colors"]` if present | platform default (§4) |

`brand_colors`' own inner shape is unconditionally `%{"primary" => <hex color>}`
— `TenantSettings`' own `@brand_colors_allowed_keys` is `~w(primary)` today
(`tenant.ex:252`), so there is exactly one inner slot; this design does not
invent additional slots.

**Per-sub-key fallback, not all-or-nothing.** A tenant may have stored a
`settings` map that sets `app_name` but not `logo_url` or `brand_colors` (REQ-280's
changeset allows a partial map — see req280 design §4, "may be called with an
empty or partial map"). The `branding` block must fill each **missing sub-key
independently** from the platform default for that sub-key, not fall back to
the platform default for the whole block whenever any one sub-key is unset.
This mirrors `TenantSettings`' own per-key-optional storage model and is the
only reading consistent with AC3 ("a tenant with stored branding gets its own
values") applying per-tenant-per-field, not per-tenant-all-or-nothing.

## 4. Never-error mechanism for the new key

**Single unconditional call site, same as today.** `config_map/1` (or its
renamed/re-arity'd successor — naming is ELIXIR-DEV's call, but it must remain
the **one and only** place the response map literal is built) must resolve the
`branding` value through a helper that:

1. Takes the already-resolved tenant lookup result (or `nil`/miss/error) as
   input — the same `Identity.safe_get_tenant_by_slug/2` result already computed
   for `resolve_realm/2` in `handle_tenant_config/1` (do not perform a second,
   independent DB lookup for branding — see open question OQ-1 below on
   threading this value through).
2. On a lookup hit with a non-nil `settings` map: build the three-sub-key
   `branding` map, filling each sub-key from `tenant.settings` when the key is
   present in that map, else from the platform default for that sub-key (§3's
   per-sub-key fallback).
3. On a lookup hit with `settings == nil` (tenant exists, never configured
   anything): the platform-default `branding` map, all three sub-keys.
4. On a lookup miss (`{:error, :not_found}`), a malformed/absent slug (`nil`
   input, same as `resolve_realm(nil, ...)`'s existing branch), or a lookup
   failure (`{:error, :lookup_failed}`): the platform-default `branding` map,
   all three sub-keys — **identical map, by construction**, to case 3, since
   both paths call the same "no settings available" branch of the same helper
   function with no argument that could make them diverge.

Because cases 3 and 4 route through the identical function clause with no
distinguishing input, the response is structurally incapable of differing in
key set, key count, or shape between "resolvable slug, no branding stored,"
"unknown slug," "malformed slug," and "simulated DB failure" — the four AC2
paths. Only case 2 (a genuine settings hit) can ever differ, and only in the
three sub-keys' *values*, never in the top-level `branding` key's *presence*
or the response's overall 3-key set (`oidc_authority`, `client_id`, `branding`)
or key count. HTTP status stays 200 unconditionally — `handle_tenant_config/1`
retains its single `Response.ok/2` call site with no new branch.

**OQ-1 (open, for ELIXIR-DEV to resolve, not silently picked here):**
`resolve_realm/2` today returns a bare `realm_id` string, discarding the
matched `%Tenant{}` struct after extracting `idp_realm_id`. To read `settings`
without a second `Repo` call, `resolve_realm/2` (or a new sibling function)
needs to either (a) return the full lookup result/`%Tenant{}` alongside
`realm_id` so `handle_tenant_config/1` can pass `tenant.settings` to the
branding helper, or (b) perform its own independent
`Identity.safe_get_tenant_by_slug/2` call scoped to the branding lookup only.
This design mandates (a) — a second independent lookup for the same slug in
the same request is wasteful and, more importantly, creates a window where the
two lookups could theoretically observe different data (TOCTOU-adjacent, however
unlikely for a read-only path) — but leaves the exact refactor of
`resolve_realm/2`'s return shape (tuple vs. threading a struct through an
accumulator) to ELIXIR-DEV, since that is an internal-only signature change
with no observable behavior difference and multiple equally-valid shapes exist.
Constraint: whatever shape is chosen must still make `resolve_realm(nil, host)`'s
existing default-realm branches (steps 2/3 of the moduledoc's "Precedence"
section) reachable with a `nil`-equivalent "no tenant" branding input, so cases
3 and 4 above stay provably identical.

## 5. Platform-default values

**Decision: a new, endpoint-local module attribute in
`lib/letflow/routers/tenant_config.ex`, NOT a reference to
`mobile_tenant_config.ex`'s `@default_branding`, and NOT byte-identical to it.**

Values:

| Sub-key | Platform default | Source |
|---|---|---|
| `"app_name"` | `"Letflow"` | matches mobile's existing `@default_branding["app_name"]` value — no reason to diverge on the name string itself |
| `"logo_url"` | `nil` | matches mobile's existing `@default_branding["logo_url"]` value (also `nil`) |
| `"brand_colors"` | `%{"primary" => "#228be6"}` | **REQ-280's re-verified canonical value** (`web/src/styles/tokens.css:18`, `--color-brand-600`), NOT mobile's `#0B5FFF` |

Justification: REQ-280 design §6 already re-verified `#228be6` as canonical and
explicitly flagged mobile's `#0B5FFF` as a **stale, not-yet-reconciled** value
whose correction is REQ-282's job — "Reconciling this literal to `#228be6` is a
live-public-endpoint response-body change and is explicitly REQ-282's job."
This requirement (REQ-281) is a **different, independent** endpoint reaching
its platform-default branding value for the **first time** (this endpoint has
never had a `branding` key before REQ-281). There is no existing wrong value
here to preserve for backward-compatibility, so there is no reason to copy
mobile's known-stale `#0B5FFF` into a second location — doing so would
manufacture a second inconsistency in the same commit that REQ-280 just spent a
full section documenting. This endpoint's brand-color default is `#228be6`
from day one.

This does create a **second copy** of default-branding-shaped data across the
two router modules (mobile's `@default_branding` with `"primary_color"` as its
single color key, at `#0B5FFF`; this endpoint's new default with `"brand_colors"
=> %{"primary" => ...}` as its nested shape, at `#228be6`) — deliberately, per
the scope fence below. Sharing a single default-values module between the two
routers is exactly the kind of cross-endpoint coupling REQ-124's design already
rejected in favor of two independent, separately-auditable allowlists (restated
in both modules' moduledocs: "each response allowlist is auditable in
isolation"); introducing a shared constants module now would undercut that
precedent for a requirement whose own scope fence forbids touching the mobile
module at all. REQ-282 is the correct place to either reconcile mobile's value
to `#228be6` in place, or to decide at that point whether a shared module is
now warranted once both endpoints agree on the value — not this requirement's
call to make unilaterally.

**Note on key-name shape mismatch (informational, not an open question):**
mobile's default uses a flat `"primary_color"` string key; this endpoint's
`brand_colors` sub-key is a nested map (`%{"primary" => ...}`), because it
mirrors `TenantSettings`' own stored shape exactly (§3). This is an existing,
REQ-280-documented mismatch between the two endpoints' branding shapes, already
named in REQ-280 design §6 as unreconciled and explicitly owned by REQ-282 —
not a new mismatch introduced by this design and not this requirement's job to
fix.

## 6. Closed-allowlist mechanism (AC4)

**Confirmed: no additional enforcement code is needed in this router.**
Reasoning, verified against the live `TenantSettings` module
(`lib/letflow/identity/tenant_settings.ex:44-58` `cast/1`, `:79-88` `dump/1`):
any attempt to write an out-of-allowlist top-level key (e.g. `"foo"`) into
`tenants.settings` is rejected **at write time** by `TenantSettings.cast/1`
(returns `{:error, [...]}`, which `Ecto.Changeset.cast/3` surfaces as a
changeset error — the write never reaches the DB) and defensively again by
`dump/1` for any path that bypasses the changeset. There is therefore no
code path by which `tenant.settings` can ever contain an out-of-allowlist
top-level key in the first place — the branding-building helper (§4) reads
only the three named sub-keys (`app_name`, `logo_url`, `brand_colors`) off
whatever map `tenant.settings` holds, by explicit `Map.get/2`/pattern-match on
those three literal string keys, never by iterating or passing through
`tenant.settings`' own key set. Even if `tenant.settings` somehow held an
extra key (it structurally cannot, per the above), the helper's explicit
three-key read would not surface it. Both layers — write-time rejection
(REQ-280, already shipped) and read-time explicit-key selection (this
design) — independently guarantee AC4; a test can (and per AC4 must) exercise
this by calling `Letflow.Identity.update_tenant_settings/2` directly (the
existing, already-shipped context function — REQ-280 design §8 confirms it has
"no HTTP-reachable write path" is fine for this purpose; the test does not go
through an HTTP endpoint to store the value) with an out-of-allowlist key and
asserting the update itself is rejected (`{:error, %Ecto.Changeset{}}`) —
proving the value can never even reach storage, let alone this response.

No new validation code belongs in `tenant_config.ex` for this AC; adding a
second, redundant allowlist check there would duplicate `TenantSettings`'
enforcement for no behavioral gain and is explicitly **not** part of this
design.

## 7. Updated moduledoc paragraph — before/after

**Before** (`tenant_config.ex:58-66`, quoted in §1 above).

**After** (replacement prose for the "What this endpoint discloses, and what
it must never disclose" section):

> It returns exactly three values: an OIDC authority URL (which embeds a realm
> id), a public client id, and a `branding` block. Both of the first two are
> values the browser must learn *before* authenticating; the third is display
> information the login page renders before authentication as well. All three
> are visible to any user of that tenant. The `branding` block is itself a
> closed, explicit allowlist of exactly three sub-keys — `app_name`,
> `logo_url`, `brand_colors` — sourced from the tenant's own stored settings
> (`Letflow.Identity.Tenant`'s `:settings` column, REQ-280) where set, and from
> a platform-default value per sub-key where not. It must **never** return a
> tenant id, slug, display name, status, user count, locale/language
> configuration, or any other tenant attribute — the response map is
> hand-built with exactly these three top-level keys, and the `branding` block
> is hand-built with exactly its three sub-keys, both **never** derived from
> `%Letflow.Identity.Tenant{}` (INV-2) or from that struct's `:settings` field
> by anything other than an explicit, named-key read. A non-default `branding`
> block is itself a signal that a slug is real — the same bounded inference
> this endpoint already makes via a non-default realm id in `oidc_authority`;
> it is exactly what any user of that tenant already sees on their own login
> page. **Adding a fourth top-level key to this response, or a fourth sub-key
> to `branding`, is a security change, not a feature.**

## 8. Scope fence confirmation

`lib/letflow/routers/mobile_tenant_config.ex` is **not** part of this design
and must not be edited by this requirement's implementation. Nothing in §§1-7
above references changing that file's `@default_branding`, its
`mobile_config_map/1`, or its moduledoc. `git diff --stat` scoped to this
requirement's commits (AC7) must show zero lines touched in that file — the
same file untouched by REQ-280 (design §7) stays untouched by REQ-281 too;
its reconciliation (`#0B5FFF` → `#228be6`, and any key-shape alignment) is
REQ-282's named scope per `docs/requirements.yaml`'s REQ-281 entry ("the
mobile endpoint is REQ-282").

## 9. Cross-module dependencies and invariants

- **Depends on:** `Letflow.Identity.Tenant` (`:settings` field), `Letflow.Identity.TenantSettings`
  (closed-vocabulary enforcement, already shipped), `Letflow.Identity.safe_get_tenant_by_slug/2`
  (already shared with mobile's router) — no new dependency added.
- **New/changed public surface in `lib/letflow/routers/tenant_config.ex`:**
  - The response-map-building function gains a `branding` key; its function
    name/arity may change per OQ-1's resolution but there remains exactly one
    such function.
  - A new private helper resolving the `branding` sub-map from an optional
    `tenant.settings`-shaped map (or its absence) to the always-3-sub-key
    output shape (§3/§4) — name is ELIXIR-DEV's choice.
  - Two or three new module attributes for the platform-default sub-values
    (§5) — naming ELIXIR-DEV's choice, e.g. `@default_branding`, matching
    mobile's naming convention for readability, understanding it is a
    **different constant** with different values and a different nested shape,
    not a shared reference to mobile's attribute (which lives in a different
    module entirely and cannot be referenced across modules as a compile-time
    attribute regardless).
- **Invariant (unchanged):** the response is always HTTP 200, always exactly
  three top-level keys, always identical in key set/count across all
  never-error paths (INV-5).
- **Invariant (unchanged):** the response map, and the `branding` sub-map, are
  each hand-built with an explicit, closed key list — never derived from a
  struct or from iterating an arbitrary stored map's keys (INV-2).
- **Invariant (new, stated in the moduledoc per §7):** `branding`'s three
  sub-keys are the ceiling — `locales`/`default_locale`, though present in
  `TenantSettings`' storage vocabulary, are permanently out of scope for this
  endpoint's disclosure surface unless a future requirement explicitly revisits
  this decision with its own security-change justification.
- **Invariant (unchanged):** no tenant-scoping call (`scoped_repo_opts/1`) —
  `tenants` remains a global table; reading `.settings` off the same struct
  already fetched by `resolve_realm/2` requires no new `:prefix` handling.

## 10. Open questions

- **OQ-1 (§4):** exact internal refactor shape of `resolve_realm/2` (or its
  replacement) to thread the matched `%Tenant{}`/its `settings` field through
  to the branding helper without a second DB lookup. Left to ELIXIR-DEV; the
  constraint (both "genuinely absent" branches must be provably identical) is
  stated in §4 and is not negotiable, but the Elixir-level mechanism (tuple
  return, accumulator, refactored function boundary) is an implementation
  choice with no single design-mandated answer.
- **OQ-2 (informational, not blocking):** whether a future requirement should
  introduce a shared branding-defaults module once REQ-282 reconciles mobile's
  value — explicitly deferred to REQ-282/later, not decided here (§5).
