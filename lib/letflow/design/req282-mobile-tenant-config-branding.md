# REQ-282 — `GET /api/mobile/tenant-config`: `branding`/`locales`/`default_locale` become per-tenant, `@default_branding` reconciled

Status: design (CODE-DESIGNER). Implements the mobile half of
`docs/migration/decisions/0020-frontend-architecture.md`'s Sequencing step 5.
THIS IS A SECURITY CHANGE, per `lib/letflow/routers/mobile_tenant_config.ex`'s
own moduledoc. Depends on REQ-280 (`lib/letflow/design/req280-tenant-settings-store.md`,
merged) — `tenants.settings` (`Letflow.Identity.TenantSettings`, closed 5-key
vocabulary) exists and is readable today. Sibling of REQ-281
(`lib/letflow/design/req281-tenant-config-branding-key.md`) — same mechanism
family, different response shape and a different kind of security change (see
below).

**Shape of the change, restated up front, because it is easy to get backwards:**
REQ-281 added a brand-new key (`branding`) to an endpoint that previously
lacked one. REQ-282 adds **no** key — the response keeps its existing five
keys — but makes **three already-existing** keys (`branding`, `locales`,
`default_locale`) vary by tenant for the first time, when the moduledoc
currently states, and relies on, their being global constants. The security
review here is about invalidating an existing invariance claim, not about a
new disclosure surface appearing from nothing.

## 1. Re-verification (against the live tree, not the requirement text's claims)

**Current moduledoc invariance claim**, `mobile_tenant_config.ex:79-90`
("`locales` / `default_locale` / `branding` / `environment_kind` are global,
not per-tenant"), quoted verbatim:

> `Letflow.Identity.Tenant`'s schema has no locale, branding, or environment
> column, and this module adds none (no migration — see design §5 OQ-1).
> These four fields are sourced from application config/env, the same
> `System.get_env/1`-at-point-of-use style as `Letflow.Routers.TenantConfig`'s
> `idp_base_url/0`, with hardcoded defaults. Consequently every tenant on
> this backend currently gets identical `locales`/`default_locale`/
> `branding` values — this is a deliberate, explicitly-flagged placeholder
> (design OQ-1), not a bug, pending a future requirement that would give
> tenant branding its own schema/migration/admin UI. Only `realm_url` varies
> by resolved slug.

This claim is **false as of REQ-280** (merged before this design was written):
`Letflow.Identity.Tenant` now has a `:settings` column (`TenantSettings` Ecto
type) that stores exactly `app_name`, `logo_url`, `brand_colors`, `locales`,
`default_locale` per tenant. The sentence "This module adds none (no
migration...)" is stale — REQ-280 added the migration, just not in this
module's own commits, and not yet wired to this endpoint. This paragraph must
be replaced (§4 below), not merely amended.

**Current "byte-identical by construction" claim**, `mobile_tenant_config.ex:58-65`
(the "never-error rule" section's closing sentences), quoted verbatim:

> `locales`, `default_locale`, `branding` and `environment_kind` are never
> tenant-derived (see below), so only one of the five fields varies by slug
> at all — the other four are byte-identical across every branch by
> construction.

This must also be rewritten (§4): after this requirement, three of the four
"byte-identical" fields (`branding`, `locales`, `default_locale`) can differ
by tenant when a tenant has stored settings; only `environment_kind` remains
a true global constant, alongside the pre-existing `realm_url` variance.

**Current 5-key response-building function**, `mobile_tenant_config.ex:199-210`,
quoted verbatim:

> ```
> def mobile_config_map(realm_id) do
>   %{
>     "realm_url" => idp_base_url() <> "/realms/" <> realm_id,
>     "locales" => @default_locales,
>     "default_locale" => @default_locale,
>     "branding" => @default_branding,
>     "environment_kind" => environment_kind()
>   }
> end
> ```

Confirmed: single-arity, takes only `realm_id` (a bare string) — it has no
parameter through which a tenant's `settings` could reach it today. Any
implementation must change this function's arity/parameter list to receive
the resolved tenant (or its `settings`), the same shape change REQ-281 made
to `config_map/1` → `config_map/2`.

**`@default_branding`'s exact current value**, `mobile_tenant_config.ex:130-134`,
quoted verbatim:

> ```
> @default_branding %{
>   "app_name" => "Letflow",
>   "logo_url" => nil,
>   "primary_color" => "#0B5FFF"
> }
> ```

Confirmed: three keys, flat (not nested) `primary_color`, `"#0B5FFF"` — this
is the value the task's requirement text and REQ-280 design §6 both flag as
stale against `tokens.css`'s canonical `#228be6`.

**Current tenant-resolution mechanism**, `mobile_tenant_config.ex:166-177`
(`resolve_realm_id/1`), quoted verbatim:

> ```
> defp resolve_realm_id(nil), do: @default_realm
>
> defp resolve_realm_id(slug) when is_binary(slug) do
>   case Identity.safe_get_tenant_by_slug(slug, "mobile-tenant-config") do
>     {:ok, %Tenant{idp_realm_id: realm_id}} when is_binary(realm_id) and realm_id != "" ->
>       realm_id
>
>     _miss_or_nil_realm_or_error ->
>       @default_realm
>   end
> end
> ```

**This differs materially from `tenant_config.ex`'s `resolve_realm/2`,** which
REQ-281 threaded a full `{realm_id, tenant}` tuple through (that design's
OQ-1). Here, `resolve_realm_id/1` returns a **bare `String.t()`** (just
`realm_id`) and — critically — its `{:ok, %Tenant{idp_realm_id: realm_id}}`
match clause **guards on `idp_realm_id` being non-nil/non-empty**; a tenant
that resolves successfully but has a nil/empty `idp_realm_id` falls into the
`_miss_or_nil_realm_or_error` catch-all and is treated identically to an
unknown slug — even though the tenant row (and its `settings`) was
successfully fetched. This module therefore needs its own OQ-1-equivalent
refactor (§2 below), independent of REQ-281's, because the exact branch
structure differs (REQ-281's `tenant_config.ex` matched only on the realm
being present; this module's realm-nil branch would otherwise discard a
legitimately-resolved tenant's settings).

**Mounting/route, confirmed unchanged and pre-auth**: `Letflow.Router`
forwards `/api/mobile/tenant-config` to `Letflow.Routers.MobileTenantConfig`
ahead of the `/api/v1` forward, outside `Letflow.Plugs.ApiPipeline` and
therefore outside `Letflow.Plugs.AuthPipeline` — no bearer token required or
checked. This requirement makes no route or mount change; the `?slug=`-only
parameter contract (design OQ-2 of REQ-124) is untouched.

## 2. The mechanism — threading `settings` through without a second lookup

**Decision: `resolve_realm_id/1` is replaced by a function that returns both
the resolved `realm_id` and the tenant's `settings` (or `nil`)**, mirroring
REQ-281's OQ-1 resolution but adapted to this module's different branch
structure (bare-string return, and a match guard that currently conflates
"nil realm" with "no tenant found").

**New/changed private function**, name and exact arity ELIXIR-DEV's choice,
replacing `resolve_realm_id/1`'s bare-string contract:

```
@spec resolve_tenant_config(slug :: String.t() | nil) ::
        {realm_id :: String.t(), settings :: map() | nil}
```

Behavior, restated as a table so no branch is silently invented:

| Input | Lookup result | `realm_id` | `settings` |
|---|---|---|---|
| `nil` (no `?slug=`) | not attempted | `@default_realm` | `nil` |
| non-nil slug | `{:ok, %Tenant{idp_realm_id: id, settings: s}}`, `id` non-nil/non-empty | `id` | `s` (may itself be `nil` — tenant exists, never configured settings) |
| non-nil slug | `{:ok, %Tenant{idp_realm_id: nil_or_empty, settings: s}}` | `@default_realm` | **`s`**, not discarded — see below |
| non-nil slug | `{:error, :not_found}` | `@default_realm` | `nil` |
| non-nil slug | `{:error, :lookup_failed}` | `@default_realm` | `nil` |

**Open question OQ-A (flagged, not resolved here) — does a resolved tenant
with a nil/empty `idp_realm_id` still get its own branding?** The current
code's guard clause treats "tenant found but `idp_realm_id` is nil/empty" as
equivalent to "tenant not found" for `realm_id` purposes (both fall to
`@default_realm`). This design does not silently decide whether that same
tenant's `settings` should still be surfaced in `branding`/`locales`/
`default_locale` while `realm_url` falls back to default, or whether the
whole row should be treated as absent for all three fields uniformly (i.e.
`settings` also forced to `nil` in that branch, matching row 3 to row 4/5 in
the table above). Arguments both ways:

- **For surfacing settings anyway:** the tenant genuinely exists and
  configured branding; `idp_realm_id` and `settings` are independent columns,
  and there is no reason a missing realm binding should suppress an unrelated,
  already-fetched field.
- **For suppressing it (forcing `settings = nil` in that branch, matching the
  existing "unbound realm = not usably provisioned" treatment):** the existing
  code already treats "found but no usable realm" as failure-equivalent for
  `realm_url`; treating it as failure-equivalent across the board keeps the
  tenant's overall "resolved or not" status singular rather than split
  per-field, and avoids a caller learning "this slug has stored branding" for
  a tenant that cannot even complete authentication against it.

**This design's recommendation, not a silent pick:** suppress it (second
option) — force `settings = nil` in the nil/empty-`idp_realm_id` branch, so
row 3 of the table above collapses into row 4/5's behavior exactly. This
keeps the never-error/anti-enumeration argument (§5) single-threaded through
one boolean condition ("did we get a usable tenant, yes or no") instead of
two independently-varying ones, which is the simpler and more conservative
reading of the anti-enumeration argument for a case with no test coverage
named in the ACs either way. ELIXIR-DEV may implement this recommendation
directly; if a reviewer disagrees, escalate rather than silently diverging,
since neither AC1–AC8 nor `docs/requirements.yaml`'s REQ-282 entry states
this branch's expected behavior explicitly.

**Response-map-building function** — `mobile_config_map/1` is replaced by a
new arity taking the resolved `settings` (or `nil`) alongside `realm_id`:

```
@spec mobile_config_map(realm_id :: String.t(), settings :: map() | nil) :: %{
        required(String.t()) => String.t() | [String.t()] | map()
      }
```

It builds all five keys, exactly as today, except `locales`, `default_locale`,
and `branding` are each resolved through the per-key-fallback helper below
instead of read directly from `@default_locales`/`@default_locale`/
`@default_branding`.

**Per-key fallback helper(s)** — following REQ-281's `branding_from_settings/1`
pattern exactly, but covering three independently-resolved keys instead of one
three-sub-key block. Two shapes are needed because `branding` is itself a
sub-map (mirroring REQ-281's structure) while `locales`/`default_locale` are
each a single top-level value (not previously true for REQ-281, which never
disclosed locale data at all):

```
@spec branding_from_settings(settings :: map() | nil) :: %{
        required(String.t()) => String.t() | nil | map()
      }
```

```
@spec locales_from_settings(settings :: map() | nil) :: [String.t()]
```

```
@spec default_locale_from_settings(settings :: map() | nil) :: String.t()
```

Each reads its own named key(s) off `settings` via explicit `Map.get/3` with
the corresponding platform default as the third argument, exactly the
per-sub-key (not all-or-nothing) fallback discipline REQ-281 §3 established —
a tenant that has stored `locales` but not `branding` gets its own `locales`
and the platform-default `branding`, and vice versa. `settings == nil`
(tenant absent/miss/error/no-settings-ever-written) makes every one of these
three helpers return its full platform-default value, by the same "one input,
no other branch," structurally-identical-response argument REQ-281 §4 uses.

## 3. THE RECONCILIATION — `@default_branding`'s shape and value

**Decision: `primary_color` stays a flat key (does NOT become a nested
`brand_colors` map), and its value changes from `"#0B5FFF"` to `"#228be6"`.**

Justification for keeping the flat shape (not mirroring REQ-281's nested
`%{"primary" => ...}`):

1. **AC1 pins the key set, not the sub-shape, but pins it as a closed
   allowlist that must not gain a new top-level structure without cause.**
   AC1 requires "the response map still hand-built and never derived from
   `%Letflow.Identity.Tenant{}}`" and that the endpoint "still returns exactly
   five keys." It says nothing about restructuring the `branding` block's
   internal shape, and no AC asks for `branding`'s inner shape to change to
   match the web endpoint's. Changing `primary_color` (flat) to a nested
   `brand_colors` map purely for cross-endpoint symmetry would be a shape
   change with no requesting AC — exactly the kind of unrequested scope
   REQ-281 §5 itself declined when it chose not to touch this file's shape at
   all ("This requirement adds no sixth key... it makes three existing keys
   vary").
2. **REQ-281 §5's own "Note on key-name shape mismatch" explicitly deferred
   this exact question to REQ-282, without prejudging the answer.** It says
   the mismatch is "already-documented... not this requirement's job to fix,"
   leaving REQ-282 free to reconcile the *value* without also reconciling the
   *shape*. Nothing in REQ-282's `docs/requirements.yaml` entry (quoted in
   full above) mentions restructuring `branding`'s internal keys — its three
   constraints are the never-error rule, the anti-enumeration re-statement,
   and the closed five-key top-level allowlist; "ALSO IN SCOPE" names
   reconciling `primary_color`'s *value*, not its *shape*, to the canonical
   default: "reconciling `@default_branding`'s `primary_color` to the
   canonical platform default REQ-280 named."
3. **A shape change here is also a breaking response-body change for any
   existing/future mobile consumer keyed on `branding.primary_color`,**
   whereas a same-shape value change is not. Since `apps/mobile/` does not
   exist yet (dormant MOBILE-DEV, confirmed §6), there is no live consumer to
   break either way, but "no consumer yet" is a reason a scope-fenced value
   change is safe, not a license to also silently widen the change into a
   shape migration nothing asked for.
4. **When a tenant's stored `brand_colors` (nested, REQ-280 shape) needs to
   populate this endpoint's flat `primary_color`,** the response-building
   helper reads the tenant's stored `settings["brand_colors"]["primary"]`
   (the one currently-allowed inner key, per `Tenant.settings_changeset/2`'s
   `@brand_colors_allowed_keys`) and maps it to the flat `"primary_color"`
   output key — an explicit, named-key translation at the read boundary, not
   a structural copy of the stored shape. This is the same "explicit
   named-key read, never a wholesale merge" discipline INV-2 already requires
   of REQ-281's `branding_from_settings/1`.

**Reconciled `@default_branding` value**, described (not written as
implementation code): the same three-key flat map as today —
`"app_name" => "Letflow"`, `"logo_url" => nil` — with only
`"primary_color"`'s value changed, from `"#0B5FFF"` to `"#228be6"`. The key
set, key count, and flat shape are unchanged from today's constant. This
matches REQ-280 design §6's re-verified canonical source
(`web/src/styles/tokens.css:18`, `--color-brand-600: #228be6`) — the same
value REQ-281 used for its own (differently-shaped) default, confirmed still
current by this design's own re-read of that line (§ above, "confirm still
canonical" check performed via direct file read, not inherited from either
sibling design doc's claim).

**`branding_from_settings/1`'s per-tenant read**, restated as a fallback
table:

| Output key | Source when tenant has stored settings | Source when absent/miss/error/no-settings |
|---|---|---|
| `"app_name"` | `settings["app_name"]` if present | `@default_branding["app_name"]` (`"Letflow"`) |
| `"logo_url"` | `settings["logo_url"]` if present | `@default_branding["logo_url"]` (`nil`) |
| `"primary_color"` | `settings["brand_colors"]["primary"]` if `settings["brand_colors"]` is present and itself has a `"primary"` key | `@default_branding["primary_color"]` (`"#228be6"`) |

The third row's two-level `Map.get/3`-of-`Map.get/3` read is the one place
this module's translation differs mechanically from REQ-281's — because the
stored shape (nested) and this endpoint's disclosed shape (flat) genuinely
differ, unlike `app_name`/`logo_url` which pass through unchanged. Missing
either level (no `brand_colors` key at all, or a `brand_colors` map without
`"primary"`) falls through to the flat default in the same expression — no
separate error path, no partial `nil` leaking into `primary_color` in place
of a string.

## 4. THE MODULEDOC REWRITE (AC4)

Both cited sections must be replaced. Draft replacement prose below —
ELIXIR-DEV should use this verbatim or near-verbatim, since AC4's "re-stated,
not inherited" bar is a documentation-content bar this design is positioned
to satisfy directly.

### Replacement for "`locales` / `default_locale` / `branding` / `environment_kind` are global, not per-tenant" (§ header itself must also change — the claim it names is no longer true)

**New section header:** `## locales / default_locale / branding are per-tenant; environment_kind remains global`

**New body:**

> `Letflow.Identity.Tenant`'s `:settings` column (`Letflow.Identity.TenantSettings`,
> REQ-280) stores a tenant's own `app_name`, `logo_url`, `brand_colors`,
> `locales` and `default_locale`, written through
> `Letflow.Identity.update_tenant_settings/2` and validated at write time by
> `Tenant.settings_changeset/2`. As of REQ-282, this endpoint reads that
> column: `locales`, `default_locale` and `branding` each resolve per
> sub-key from the resolved tenant's stored `settings` where set, and from a
> platform default (`@default_locales`, `@default_locale`, `@default_branding`)
> where not. A tenant that never wrote any settings, an unresolvable slug, a
> lookup failure, and a missing `?slug=` parameter all still produce the
> platform-default values for these three fields — see the never-error
> section below for why that convergence is exact, not approximate.
> `environment_kind` remains the one field genuinely sourced from application
> config/env (`LETFLOW_ENVIRONMENT_KIND`), unrelated to any tenant, unchanged
> by this requirement — it is global in the sense the whole paragraph used to
> claim of all four fields; the other three no longer are.

### Replacement for the never-error section's closing "byte-identical by construction" sentences (`mobile_tenant_config.ex:58-65`)

**New body** (replacing "`locales`, `default_locale`, `branding` and
`environment_kind` are never tenant-derived... byte-identical across every
branch by construction"):

> A caller can also infer, from a non-default `branding`, `locales` or
> `default_locale` value, that a resolved slug belongs to a tenant that
> configured its own settings — this is the same bounded, unavoidable
> inference this endpoint already makes via a non-default `realm_url`
> (record 0020's anti-enumeration argument, restated here rather than
> assumed carried over from the pre-REQ-282 text above): telling the mobile
> app which realm, branding, and locale defaults apply to a tenant is this
> endpoint's entire purpose, and every one of those values is exactly what
> any user of that tenant already sees at their own login/bootstrap screen —
> none of them is information withheld from a legitimate user of the tenant
> in question. What remains invariant is not "four of five fields never
> vary" (that claim no longer holds after REQ-282) but the **never-error
> guarantee itself**: an unknown slug, a lookup failure, and a missing
> `?slug=` parameter are structurally indistinguishable from each other and
> from "a resolved tenant that never configured any settings" — all four
> converge on the identical platform-default values for `branding`,
> `locales`, and `default_locale`, because all four route through the same
> `settings = nil` input to the same fallback helpers (§2/§3). Only a genuine
> settings hit — a resolvable slug bound to a tenant that has written its own
> `app_name`/`logo_url`/`brand_colors`/`locales`/`default_locale` — can ever
> produce a non-default value for these three fields, exactly mirroring how
> only a resolvable slug with a bound realm can ever produce a non-default
> `realm_url`. `environment_kind` is the one field that is still, and
> remains, byte-identical across every branch by construction (env-derived,
> not tenant-derived, not touched by this requirement).

## 5. Never-error verification plan (all 4 paths, AC2)

| Path | `?slug=` | Lookup result | `realm_id` | `settings` fed to helpers | Response |
|---|---|---|---|---|---|
| Resolvable slug, tenant has settings | valid, bound slug | `{:ok, %Tenant{idp_realm_id: <realm>, settings: <map>}}` | `<realm>` | `<map>` | 200, 5 keys, `branding`/`locales`/`default_locale` reflect stored values per-key (§3 table), `realm_url` non-default |
| Resolvable slug, tenant has no settings | valid, bound slug | `{:ok, %Tenant{idp_realm_id: <realm>, settings: nil}}` | `<realm>` | `nil` | 200, 5 keys, `branding`/`locales`/`default_locale` = platform defaults, `realm_url` non-default |
| Unknown slug | unresolvable | `{:error, :not_found}` | `@default_realm` | `nil` | 200, 5 keys, all defaults, identical body to "missing slug" row |
| Missing `?slug=` | absent | not attempted | `@default_realm` | `nil` | 200, 5 keys, all defaults — identical body to "unknown slug" row |
| Simulated lookup failure | valid-looking slug | `{:error, :lookup_failed}` (raised exception path) | `@default_realm` | `nil` | 200, 5 keys, all defaults — identical body to "unknown slug"/"missing slug" rows |

**AC2's exact assertion target:** the last three rows (unknown slug, missing
param, simulated failure) must produce **byte-identical response bodies** —
same key set, same key count, same values — because all three converge on
`resolve_tenant_config/1`'s `{@default_realm, nil}` output with no
distinguishing input reaching `mobile_config_map/2` or its fallback helpers.
This is the same "cases 3 and 4 route through the identical function clause"
argument REQ-281 §4 makes, extended to a third converging case (missing
param) that REQ-281's own table didn't need to separately enumerate because
its sibling endpoint's `?realm=`/`?host=` precedence chain already collapsed
to the same shape. A test simulating "lookup failure" should follow REQ-281's
own precedent: exercise `Identity.safe_get_tenant_by_slug/2`'s existing
`rescue` path (e.g. via whatever fixture/mock mechanism the existing test
suite for `mobile_tenant_config_test.exs`/`tenant_config_test.exs` already
uses to force that branch — check that test file for the established
technique rather than inventing a new one).

**AC3's exact assertion target:** a tenant with stored `branding`/`locales`/
`default_locale` must get its own per-key values (first two rows of the table
differ from each other and from the default-rows only in these three fields'
values, never in key set/count/status), proving the settings store is read
per-request rather than a constant being emitted regardless of input — the
test should assert against two distinctly-configured tenants (or one
configured, one bare) to rule out the fallback helper accidentally always
returning the default regardless of `settings`.

## 6. Scope fence confirmation

- **`lib/letflow/routers/tenant_config.ex` is NOT touched by this design.**
  Nothing in §§1–5 above references editing that file's `config_map/2`,
  `branding_from_settings/1`, its own `@default_app_name`/`@default_logo_url`/
  `@default_brand_colors` attributes, or its moduledoc. REQ-281 already
  reconciled that endpoint's own default to `#228be6` independently (its own
  design §5) — this requirement does not re-touch it, does not merge the two
  endpoints' default-value constants into a shared module (REQ-281 §5/§9
  explicitly left that question open and unresolved by either requirement),
  and does not change its response shape in any way. ELIXIR-DEV's own AC7-
  equivalent verification here should be `git diff --stat` scoped to this
  requirement's commits showing zero lines touched in `tenant_config.ex`.
- **No file under `apps/mobile/` is created or edited.** That tier does not
  exist (dormant `MOBILE-DEV`, per `docs/mobile/build-order.md` phase M-0 and
  `docs/agents/AGENT_SYSTEM.md`'s roster note); this requirement is entirely
  a backend response-shaping change to an existing Elixir router module. Do
  not activate `MOBILE-DEV` for this requirement.
- **No new migration.** `tenants.settings` already exists from REQ-280; this
  requirement only adds a read path to an already-shipped column, exactly as
  REQ-281 did for the web endpoint.
- **No change to `?slug=`-only parameter contract or route/mount.** Design
  OQ-2 (REQ-124) — no `?host=` branch — is unaffected; this requirement adds
  no new query parameter.

## 7. Cross-module dependencies and invariants

- **Depends on:** `Letflow.Identity.Tenant` (`:settings` field, REQ-280),
  `Letflow.Identity.TenantSettings` (closed-vocabulary enforcement, already
  shipped), `Letflow.Identity.safe_get_tenant_by_slug/2` (already shared with
  `tenant_config.ex`) — no new dependency added.
- **New/changed public/private surface in `mobile_tenant_config.ex`:**
  - `resolve_realm_id/1` replaced by a function returning
    `{realm_id, settings}` (§2) — exact name ELIXIR-DEV's choice.
  - `mobile_config_map/1` becomes `mobile_config_map/2`, taking `settings` as
    a second parameter.
  - Three new private per-key fallback helpers: `branding_from_settings/1`,
    `locales_from_settings/1`, `default_locale_from_settings/1` (names
    ELIXIR-DEV's choice, but three separate concerns per §2 — do not collapse
    into one function that returns a 3-tuple, since that would make `AC3`'s
    per-tenant/per-key assertions harder to test independently and diverges
    from REQ-281's one-helper-per-disclosed-block precedent, which used one
    helper because `branding` was REQ-281's *only* new key; here there are
    three independently-varying keys).
  - `@default_branding`'s `"primary_color"` value changes to `"#228be6"`
    (§3); its key set/shape (flat, three keys) is unchanged.
- **Invariant (unchanged):** response is always HTTP 200, always exactly five
  top-level keys (`realm_url`, `locales`, `default_locale`, `branding`,
  `environment_kind`), always identical key set/count across all never-error
  paths (INV-5).
- **Invariant (unchanged):** the response map, and the `branding` sub-map,
  are each hand-built with an explicit, closed key list — never derived from
  `%Tenant{}` as a whole or from iterating `settings`' own key set (INV-2).
- **Invariant (new, stated in the moduledoc rewrite per §4):** `branding`,
  `locales`, `default_locale` are no longer byte-identical-by-construction
  across every branch — only a genuine per-tenant settings hit can vary them,
  exactly mirroring `realm_url`'s existing variance rule. `environment_kind`
  remains the sole field genuinely invariant across all branches.
- **Invariant (unchanged):** no tenant-scoping call (`scoped_repo_opts/1`) —
  `tenants` remains a global table; reading `.settings` off the same struct
  already fetched by the realm-resolution lookup requires no new `:prefix`
  handling.

## 8. Open questions

- **OQ-A (§2):** whether a resolved tenant with a nil/empty `idp_realm_id`
  should still surface its own `branding`/`locales`/`default_locale`, or have
  `settings` forced to `nil` in that branch (this design recommends the
  latter, but flags it as a genuine unstated-in-ACs decision point rather
  than silently picking it without saying so).
- **OQ-B (informational, not blocking):** whether a future requirement should
  reconcile `branding`'s flat-vs-nested shape mismatch between this endpoint
  and `tenant_config.ex` once `apps/mobile/` exists and has a concrete
  consumer need — this design explicitly declines to do so now (§3), for the
  same "no requesting AC" reason REQ-281 declined it for this endpoint.
