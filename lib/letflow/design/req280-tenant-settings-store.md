# REQ-280 — `Letflow.Identity.Tenant` settings store: schema, migration, changeset

Status: design (CODE-DESIGNER). Implements
`docs/migration/decisions/0020-frontend-architecture.md` D1/D1a, Sequencing step 4.
Store-only: no route/response-shape change (that is REQ-281/282), no SPA theming
(REQ-283).

## 0. Scope recap and non-goals

- Adds a **write-and-read store** for a closed set of tenant-settings keys on
  `Letflow.Identity.Tenant`: a migration, a schema field, a narrowly-cast changeset,
  and per-key type/format validation.
- Does **not** touch `lib/letflow/routers/tenant_config.ex` or
  `lib/letflow/routers/mobile_tenant_config.ex` (including `@default_branding`) — see
  §7.
- Does **not** add an HTTP route, an admin UI, or SPA theme application.
- Does **not** reconcile `@default_branding` (`#0B5FFF`) to `tokens.css`'s
  `#228be6` — that is REQ-282's job against the public response body, not this
  store's.

## 1. Storage shape — column on `tenants`, not a new table

**Decision: a single nullable `:map` (JSONB) column, `settings`, added directly to
the existing `tenants` table.** No new table.

Reasoning:

- The vocabulary is closed and small (5 named keys total, one nested one level for
  brand colours) — it is a fixed-shape record, not an open collection needing its
  own identity, foreign key, or independent lifecycle. A child table would need a
  1:1 (or 1:0..1) relationship to `tenants` with no additional cardinality to
  express, which is exactly the case Ecto's embedded-schema-in-a-JSONB-column shape
  exists for.
- `tenants` is a **global** table (outside every per-tenant Postgres schema — see
  `Letflow.Identity.Tenant`'s moduledoc: "This schema targets Ecto's single default
  schema"). A settings column here needs no tenant-scoping, no `prefix:` option, and
  no interaction with `Letflow.TenantProvisioning`'s per-tenant-schema migration
  manifest at all.
- One row per tenant, read on every `GET /api/mobile/tenant-config` /
  `GET /api/tenant-config` call path (once REQ-281/282 wire it in) — a plain column
  read avoids a join for what will become a hot, unauthenticated path.

**AC6 (`tenant_fixture.ex` oracle) answer: does not apply, stated explicitly.**
`test/support/tenant_fixture.ex`'s `@expected_tenant_tables` oracle enumerates the
tables a **tenant-scoped** migration creates inside a per-tenant Postgres schema
(`prefix: schema`-scoped tables, driven by
`Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s manifest — see
`docs/anti-patterns.md`'s "A new tenant-scoped migration's tables must be added to
`@expected_tenant_tables`..." entry). This design adds neither a new table nor a
tenant-scoped one: `tenants` is a **global**, unprefixed table, already excluded
from that oracle's universe (the oracle's own list contains no `tenants` row today).
Because the change is (a) a column, not a table, and (b) on a global table, not a
tenant-scoped one, `@expected_tenant_tables` is not touched by this design and does
not need updating — both halves of AC6's "did not apply" branch are true
independently, not just one.

## 2. Migration

- **File:** `priv/repo/migrations/20260908000001_add_settings_to_tenants.exs`.
  Version-prefix check: the last migration in `priv/repo/migrations/` at design
  time is `20260907020001_add_scan_status_to_instance_attachments.exs`
  (2026-09-07). `20260908000001` (2026-09-08, matching the branch date) sorts after
  every existing file and collides with none — confirmed by listing the directory
  in full at design time; ELIXIR-DEV must re-run
  `ls priv/repo/migrations/ | sort | tail -5` immediately before creating the file
  to catch any migration added on `main` since this design was written, per
  `docs/anti-patterns.md`'s two-branches-same-version entry.
- **Change:** `alter table(:tenants)`, add one column:
  `add :settings, :map, null: true` (Postgres `jsonb` — Ecto's `:map` type maps to
  `jsonb` on Postgres by default in this codebase's existing migrations; no
  `:default` value — see §"No default is invented" below).
- **No index.** Nothing in the 8 ACs queries tenants *by* a settings value; an index
  would be speculative scope.
- **No `NOT NULL` / no default.** An existing tenant row that has never had its
  settings written must read back `nil`, not an invented empty map or a set of
  platform-default values baked into the column — inventing a default at the
  storage layer would blur the line between "this tenant configured nothing" and
  "this tenant configured empty branding," and REQ-281/282's response-building code
  is where the actual platform-default fallback belongs (mirroring
  `mobile_tenant_config.ex`'s own existing `@default_branding` fallback pattern,
  which this design does not disturb — see §7). This also matches REQ-047's
  established discipline, cited already in decision 0020 for `tasks.form_schema`:
  "no default is invented for an absent key."
- **Down:** plain `remove(:settings)` (Ecto migration reversibility — standard
  `alter`/`add` is auto-reversible; no custom `down/0` needed).

## 3. Closed key vocabulary — mechanism

**Mechanism: an `Ecto.Type` custom type, `Letflow.Identity.TenantSettings`,
implementing the `Ecto.Type` behaviour, used as the field's Ecto type in the
schema in place of a bare `:map`.** This is the concrete "typed map with an
explicit allowed-keys list" option named in the task brief, chosen over a full
embedded schema for one reason: embedding via `embeds_one` would require its own
nested changeset call (`cast_embed/3`) with its own separate error-key-naming
path, which is heavier than this vocabulary needs, while a custom `Ecto.Type`
gives a single load/dump/cast boundary that can enforce the closed key set
exactly once, in exactly one place, for both directions (write and read).

Cast-time contract (type signatures, no bodies):

- `type/0 :: :map` — underlying Ecto/DB representation is still JSONB.
- `cast/1 :: (term()) -> {:ok, map()} | {:error, keyword()}` — the enforcement
  point. Given a map whose keys are not a subset of `@allowed_keys` (below),
  returns `{:error, [message: "unrecognized tenant setting key: \"<key>\"",
  validation: :unrecognized_key]}` naming the **first** offending key
  encountered (deterministic key order: iterate `@allowed_keys`'-complement of
  `Map.keys(input)` in the input's own key order) — never silently drops the key
  and never silently stores it. `Ecto.Changeset.cast/3`'s own error-surfacing
  mechanism (a `{:error, keyword()}` return from a custom type's `cast/1`)
  attaches this as a changeset error on the field being cast, giving
  ELIXIR-DEV's changeset function a typed, field-scoped error rather than a
  raised exception — matching this schema's existing changesets, none of which
  raise on bad input.
- `load/1 :: (term()) -> {:ok, map()}` — trusts the DB (already validated at
  write time); passes the stored map through unchanged, symmetric with every
  other `:map`-backed field in this codebase.
- `dump/1 :: (term()) -> {:ok, map()} | :error` — re-validates the same allowed-key
  set defensively before writing (belt-and-braces against any future write path
  that bypasses the changeset, e.g. a raw `Repo.insert!/2` with a struct literal);
  `:error` on an unrecognized key, which Ecto surfaces as a `Ecto.QueryError`-class
  failure at the `Repo` boundary rather than a silent write.
- `equal?/2 :: (term(), term()) -> boolean()` — default map equality is
  sufficient; no custom definition needed beyond the behaviour's default.

**Allowed-keys list** (module attribute, `@allowed_keys`, in
`Letflow.Identity.TenantSettings`) — exactly five string keys, no more, no fewer:
`"app_name"`, `"logo_url"`, `"brand_colors"`, `"locales"`, `"default_locale"`.

String keys, matching how the value arrives after JSON-decoding at the (future,
out-of-scope-here) HTTP boundary and matching this codebase's existing convention
for `:map`-typed fields reaching the DB as JSONB (e.g. `tasks.form_schema`,
decision 0020 D3a item 2, is also an untyped map keyed by string). `brand_colors`
is itself a nested map (§5) — its own inner-key closure is a second, narrower
allowed-keys check, stated in §5, not delegated to a second `Ecto.Type`.

## 4. The new changeset — `settings_changeset/2`

Following `Tenant`'s existing narrowly-cast-changeset convention **exactly**, citing
the three existing changesets by name and showing the structural parallel:

| Changeset | Casts (only) | Cannot reach | Existing? |
|---|---|---|---|
| `create_changeset/3` | `:slug`, `:display_name`, `:status`, `:idp_realm_id` | — (creation path) | yes |
| `update_changeset/2` | `:display_name`, `:status` | `:slug`, `:idp_realm_id` | yes |
| `admin_patch_changeset/2` | `:display_name` | `:status`, `:slug`, `:idp_realm_id` | yes |
| `status_changeset/2` | `:status` | `:display_name`, `:slug`, `:idp_realm_id` | yes |
| **`settings_changeset/2`** | **`:settings`** | **`:status`, `:slug`, `:idp_realm_id`, `:display_name`** | **new (this design)** |

`settings_changeset/2` parallels `admin_patch_changeset/2` and `status_changeset/2`
structurally: a one-field `cast/3` list containing only `:settings`, so — exactly as
those two docstrings state for their own field — the field this changeset was not
built to touch is **structurally absent** from its `cast/3` call, not merely
unchanged by convention. No `validate_required/2` call for `:settings` (a `nil`
settings value, i.e. "tenant configured nothing yet," is a legal, expected state —
see §2's "no default invented" reasoning; the whole point of this changeset is that
it may be called with an empty or partial map, or to clear settings back to `nil`).

Signature:

```
@spec settings_changeset(t :: %__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
```

Its `@doc` must state the same structural-impossibility framing as the three
existing changesets' docs (per the existing module's own convention), naming
exactly which fields it cannot reach and why (mirrors `status_changeset/2`'s
"Mirrors `admin_patch_changeset/2`'s structural-impossibility discipline in the
other direction" framing).

**Test-observable AC2 shape:** passing `%{settings: %{...}, status: :inactive,
slug: "x", idp_realm_id: "y"}` through `settings_changeset/2` must produce a
changeset whose only possible change is to `:settings` — `status`/`slug`/
`idp_realm_id` are absent from the `cast/3` list, so `Ecto.Changeset.get_change/2`
for each of those three keys is `nil` regardless of what `attrs` contains, exactly
as `admin_patch_changeset/2`'s existing test convention already checks for
`:status`.

## 5. Per-key type/format validation

All validation runs inside `settings_changeset/2`, after `cast/3`, using
`Ecto.Changeset.validate_change/3` scoped to `:settings` (the field's own custom
`Ecto.Type.cast/1` already rejects unrecognized keys per §3; this layer validates
the **values** of recognized keys). One `validate_change(:settings, fn :settings,
settings -> ... end)` call, internally dispatching per present key — not five
separate `validate_change` calls, since they all read from the same nested map and
Ecto's changeset error accumulation lets one function return a combined error list.

| Key | Type/format required | Validation approach | Error (illustrative, exact wording is ELIXIR-DEV's) |
|---|---|---|---|
| `app_name` | non-empty string, reasonable max length | `is_binary/1` + `String.length/1` bound (existing pattern: mirrors `validate_length/3`'s own semantics — use `validate_length(:app_name-equivalent-check inside the custom validator, max: n)` reasoning, or, if the nested-map shape makes `validate_length/3` inapplicable directly to a submap, replicate its bound check by hand inside the `validate_change/3` callback) | `"app_name must be a non-empty string of at most N characters"` |
| `logo_url` | absolute URL string (`http`/`https` scheme) or `nil` | `URI.parse/1` + scheme check — reuse `URI.parse/1`, Elixir's own standard-library URL parser, rather than a hand-rolled regex; reject relative URLs and non-http(s) schemes | `"logo_url must be an absolute http(s) URL"` |
| `brand_colors` | a map whose keys are drawn from **its own** closed sub-vocabulary (e.g. `"primary"`, and any additional slot(s) decision 0020 D1a's "small fixed set" implies — see Open Question OQ-1 below) and whose values are each a `#RRGGBB` (6 hex digit) hex color string | closed-sub-key check structurally identical in shape to §3's outer check (reject an unrecognized inner key, naming it); per-value format check via a hex-color regex (`~r/^#[0-9A-Fa-f]{6}$/`) — no existing Ecto/stdlib helper validates CSS hex colors, so this one hand-rolled regex is justified as "no existing helper" | `"brand_colors.primary must be a 6-digit hex color (#RRGGBB)"` / `"unrecognized brand_colors key: \"<key>\""` |
| `locales` | a non-empty list of BCP-47-shaped locale strings (e.g. `"en"`, `"en-US"`) | `is_list/1` + per-element regex (`~r/^[a-z]{2,3}(-[A-Z]{2})?$/` — a light-weight shape check, not a full BCP-47 validator, since no stdlib/Ecto BCP-47 validator exists and full compliance is not an AC) | `"locales must be a non-empty list of locale codes"` |
| `default_locale` | a single locale string, **and** (cross-field) must be a member of `locales` if `locales` is also present in the same write | same per-element regex as `locales`, plus a cross-field `Enum.member?/2` check against the `locales` value being written in the same changeset call | `"default_locale must be one of the supplied locales"` |

All five checks are Ecto/Elixir-stdlib mechanisms (`is_binary/1`, `String.length/1`,
`URI.parse/1`, `is_list/1`, `Enum.member?/2`, `Regex.match?/2`) plus
`Ecto.Changeset.validate_change/3` as the attachment point — no hand-rolled type
system beyond the two regexes noted, both justified by "no existing helper exists
for this exact format" (hex-color and locale-code shape), consistent with the task
brief's "existing Ecto validation helpers, not hand-rolled where one already
exists."

**AC4 test-shape implication:** a valid value for each key must round-trip
(insert with `settings_changeset/2`, `Repo.update/1`, re-`Repo.get/2`, assert
equality on the nested value) and an invalid value of the wrong type for each key
must produce `{:error, changeset}` from `Repo.update/1` with a changeset error
attached to `:settings` (or, per key, whatever error-path shape ELIXIR-DEV's
`validate_change/3` implementation attaches errors under — this design mandates
that an error exists and is field-scoped to `:settings`, not the exact nested
error key structure, which is an implementation-level choice within Ecto's
changeset error shape).

## 6. Canonical platform-default brand colour — re-verified, not inherited

**Canonical value:** `--color-brand-600: #228be6`, `web/src/styles/tokens.css:18`
(re-read directly for this design: line 18 of that file is
`  --color-brand-600: #228be6;` under the `/* Brand */` comment block — confirmed,
not inherited from the requirement text's own claim).

**The three-way inconsistency, restated with each value's disposition:**

| Value | Source | Disposition |
|---|---|---|
| `#228be6` | `web/src/styles/tokens.css:18` (`--color-brand-600`) | **Canonical** — REQ-120 already settled `tokens.css` as the single design-token source of truth (decision 0020 D1a). This design treats it as the platform default a tenant's `brand_colors` falls back to when unset, though the *fallback wiring itself* (where in the response-building code the fallback is applied) belongs to REQ-282, not this store. |
| `#0B5FFF` | `lib/letflow/routers/mobile_tenant_config.ex:133` (`@default_branding["primary_color"]`) | **Not touched by this design.** Reconciling this literal to `#228be6` is a live-public-endpoint response-body change and is explicitly REQ-282's job (decision 0020 D1a, and REQ-280's own acceptance criteria: "closed by REQ-282"). |
| `#2563EB` | `design-tokens/letflow.tokens.json` | **Superseded and absent — re-verified now, not assumed.** `find . -path ./node_modules -prune -o -name "*.tokens.json" -print` returns zero matches, and `design-tokens/` does not exist as a directory in this repository at all (`ls design-tokens` → "No such file or directory"). The file is genuinely absent, confirming REQ-120 superseded it; no requirement needs to "close" a divergence that no longer exists on disk. If a future reader finds this directory has reappeared, that is a new fact to report, not something this design can anticipate. |

This design's own `brand_colors` schema (§5) does not hard-code `#228be6` anywhere
in `lib/letflow/identity/tenant.ex` or the new `TenantSettings` type — the type only
validates hex-color *format*, it does not know or enforce a specific default value.
The default-value fallback (what a tenant with no `brand_colors` set actually
receives) is response-shaping behavior, owned by REQ-281/282, not by this store.

## 7. Confirmed untouched by this design

- `lib/letflow/routers/tenant_config.ex` — no edit. Continues returning exactly
  `{"oidc_authority", "client_id"}`, still never derived from `%Tenant{}`.
- `lib/letflow/routers/mobile_tenant_config.ex` — no edit, including
  `@default_branding` (line ~130-134, `#0B5FFF`) and `mobile_config_map/1`'s
  hand-built 5-key response, which continues to source `locales`/`default_locale`/
  `branding` from its own module attributes, not from the new `tenants.settings`
  column. Wiring this router to read the new column is REQ-281/282's scope, named
  explicitly in that module's own moduledoc ("pending a future requirement...") and
  now in decision 0020 as this requirement's own Sequencing successor.
- `test/support/tenant_fixture.ex`'s `@expected_tenant_tables` — unchanged; see §1.

ELIXIR-DEV's own acceptance-criterion verification (AC5) is a `git diff --stat`
scoped to this requirement's commits confirming zero lines touched in either
router file.

## 8. Cross-module dependencies and invariants

- **Depends on:** nothing new — `Letflow.Identity.Tenant` and
  `Letflow.Identity` (context module) already exist; this design adds to both.
- **New public surface:**
  - `Letflow.Identity.Tenant.settings_changeset/2` (schema module).
  - `Letflow.Identity.TenantSettings` (new `Ecto.Type` module) — `type/0`,
    `cast/1`, `load/1`, `dump/1`.
  - A context function, `Letflow.Identity.update_tenant_settings/2` (name chosen to
    parallel `patch_tenant/2`'s existing shape — `slug, attrs -> {:ok, Tenant.t()} |
    {:error, :not_found} | {:error, Ecto.Changeset.t()}`), mirroring
    `patch_tenant/2`'s and `set_tenant_status/2`'s existing
    `Repo.get_by(Tenant, slug: slug)` → changeset → `Repo.update/1` shape exactly
    (see `lib/letflow/identity.ex:797-809` for the pattern being followed). This
    function is **not itself an acceptance criterion** of REQ-280 (no AC asks for an
    HTTP-reachable write path) but is included here because a changeset with no
    context-module caller at all would be a partial subsystem shipped with no
    producer — the same REQ-056 failure mode decision 0020 itself invokes for a
    different case. Whether this function is called from any route is explicitly
    out of scope until REQ-281/282.
- **Invariant:** `settings_changeset/2` can never change `:status`, `:slug`,
  `:idp_realm_id`, or `:display_name` — enforced structurally (absent from
  `cast/3`), not by runtime check, matching every existing changeset in this module.
- **Invariant:** an unrecognized top-level key, or an unrecognized `brand_colors`
  sub-key, is rejected at write time with a changeset error naming the key — never
  silently dropped, never silently stored.
- **Invariant:** `tenants.settings` is nullable with no DB-level default; absence
  means "not configured," never "configured to platform defaults" (§2).

## 9. Open questions (flagged, not resolved)

- **OQ-1 — exact `brand_colors` inner-key set.** Decision 0020 D1a says "a small
  fixed set of brand colours" and its own "What this record does not decide"
  section explicitly declines to name them, deferring to REQ-280's acceptance
  criteria — but REQ-280's ACs also do not enumerate them, only naming "brand
  colour(s)" generically. This design assumes at minimum a `"primary"` key
  (matching `@default_branding`'s single `"primary_color"` today) but does not
  invent additional slot names (e.g. `"secondary"`, `"accent"`) without evidence.
  ELIXIR-DEV must either implement exactly `["primary"]` as the closed
  `brand_colors` sub-vocabulary (simplest, defensible reading of "the current
  system has exactly one brand colour today") or escalate to REQ-ANALYST/REVIEWER
  for a decision-record amendment before inventing additional keys — do not
  silently pick a multi-key set.
- **OQ-2 — `app_name` max length bound.** No AC or decision-record text states a
  specific character limit. ELIXIR-DEV should pick a conservative bound (e.g. 100
  chars, matching typical display-name-class fields already in this schema, such
  as `display_name` which has no explicit length validation itself today either)
  and record the chosen number in the changeset's own `@doc`, rather than treating
  "some reasonable bound" as self-evident.
- **OQ-3 — locale code strictness.** This design specifies a light shape check
  (`~r/^[a-z]{2,3}(-[A-Z]{2})?$/`), not full BCP-47/CLDR validation or a check
  against a canonical locale registry. If a future requirement needs stricter
  locale validation (e.g. rejecting shape-valid but non-existent locale codes),
  that is new scope, not an REQ-280 gap.
