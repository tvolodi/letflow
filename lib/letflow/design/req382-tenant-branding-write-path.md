# REQ-382 — HTTP-reachable tenant-branding write path: design

**Requirement:** REQ-382 (stage S8, queue task 742, GH#1630). Adds (1) an
authenticated PATCH endpoint for `tenants.settings`, (2) a WCAG 2.1 AA
colour-contrast refusal inside `Tenant.settings_changeset/2`'s
`validate_brand_colors/2`, and (3) audit recording of rejected out-of-scope
keys on a partially-applied request. No migration — reuses the existing
`tenants.settings` JSONB column (REQ-280) and `audit_entries` table
(REQ-195).

**Status:** design only, no implementation code below — signatures, data
shapes, and algorithm steps in prose.

---

## 0. Confirmed premises (read from source, not inherited from this doc's own
   prompt)

* `Tenant.settings_changeset/2` (`lib/letflow/identity/tenant.ex:188`) casts
  only `:settings`; `TenantSettings` (`lib/letflow/identity/tenant_settings.ex`)
  enforces the closed 5-key top-level vocabulary
  (`app_name, logo_url, brand_colors, locales, default_locale`) at
  `cast/1`/`dump/1`; `validate_brand_colors/2` (`tenant.ex:255`) additionally
  restricts `brand_colors` to exactly the sub-key `"primary"` today
  (`@brand_colors_allowed_keys ~w(primary)`, `tenant.ex:252`) with a 6-digit
  hex format check only (`@hex_color_regex`, `tenant.ex:253`).
* `Identity.update_tenant_settings/2` (`lib/letflow/identity.ex:1010-1022`)
  is `Repo.get_by(Tenant, slug: slug) |> Tenant.settings_changeset(attrs) |>
  Repo.update()` — **not itself wrapped in an `Ecto.Multi`**, no audit call
  inside it, and no route calls it today (confirmed:
  `grep -rn "update_tenant_settings" lib/letflow/routers/` → zero hits).
* `Ecto.Changeset.cast/3` on a `:map`-typed field (`:settings`) **replaces
  the field's value wholesale** — it does not deep-merge with the
  currently-persisted map. `TenantSettings.cast/1` operates on whatever map
  `cast/3` hands it; it has no notion of "the previous value."
* Every existing tenant-admin route family (`Letflow.Routers.Tenants`,
  `Letflow.Routers.Identity`'s `/users`, `/groups`) is declared with
  `use Letflow.Api.AuthorizedRouter` and `authz_<verb> path, :PolicyKey do
  ... end`. The 5-role permission matrix
  (`lib/letflow/api/authorization.ex:196-200`) has exactly `PLATFORM_ADMIN,
  PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, AGENT_RUNNER` — **there is
  no dedicated "tenant admin" role**. `role_allows?/2` grants `:TenantsManage`
  and `:UsersManage`/`:GroupsManage` to `PLATFORM_ADMIN` only (lines 944-1048
  — neither appears in any of the other four roles' permission lists). So
  "tenant-admin-class role" (the requirement's own phrase) resolves,
  structurally, to `PLATFORM_ADMIN` — the only role capable of managing
  another tenant record or another tenant's users today. This is stated as a
  confirmed fact, not a new policy choice.
* `Letflow.Audit.insert_entry/3` takes an explicit `repo` and can be called
  directly (not only via `append_multi/4` inside a caller's own `Multi`) —
  see its own `@doc` (`lib/letflow/audit.ex:192-211`).
* `web/src/styles/tokens.css:66-67`: `--surface-page: var(--color-neutral-50)`
  = `#f8f9fa`; `--surface-card: var(--color-neutral-0)` = `#ffffff`. Both are
  the two background surfaces `--color-brand-600` (the CSS custom property
  `brand_colors.primary` overrides, per
  `web/src/theming/brandingDefaults.ts:25`) is rendered against as
  interactive/link text (`--interactive-primary`, `tokens.css:83`).
* `web/src/pages/admin/AuditLogPage.tsx` queries via `auditApi.list` →
  `GET /api/v1/audit` → `Letflow.Routers.Audit.list_entries/1` →
  `Letflow.Audit.list_entries/1`, rendering exactly the 8
  `audit_item/1` keys (`lib/letflow/routers/audit.ex:325-336`):
  `audit_id, actor_id, action, resource_type, resource_id, timestamp,
  before_state, after_state`. No frontend change is needed as long as the new
  entry is a normal `Letflow.Audit.Entry` row inserted the same way every
  other covered mutation inserts one (REQ-195/196 own this shape; REQ-377's
  status-history page and REQ-376's partitioning both already prove new
  `audit_entries` rows surface through this same query/page with zero
  frontend change — same precedent this design follows).

---

## 1. New route

`PATCH /api/v1/tenant/settings` — mounted via a new forward in
`Letflow.Plugs.ApiPipeline`:

```
forward("/tenant/settings", to: Letflow.Routers.TenantSettings)
```

placed alongside the other `forward/2` calls (`lib/letflow/plugs/api_pipeline.ex:141-153`
region) — ordering among forwards is not significant (each is a distinct,
non-overlapping prefix), so any position in that block is correct; placing it
near `forward("/tenants", ...)` groups it with its nearest sibling for
readability only.

### `Letflow.Routers.TenantSettings` (new module)

```
use Letflow.Api.AuthorizedRouter

authz_patch "/", :TenantsManage do
  handle_patch(conn)
end
```

Only one route. `match _` falls through to `Response.not_found/1`, matching
every other router in this tree.

**Why reuse `:TenantsManage` rather than mint a new permission atom.** Three
existing precedents in `lib/letflow/api/authorization.ex` reuse
`:TenantsManage` for a new endpoint whose data is tenant-registry-adjacent
rather than minting a new atom + `role_allows?/2` clause set: `POST
/onboarding` (`:582-585`, "same risk class and same PLATFORM_ADMIN-only
intent as `Letflow.Routers.Tenants`"), `POST /platform-migrations/rollouts`
(`:592-599`, identical comment), and `GET /event-retention/summary` (`:604-610`,
identical comment). `tenants.settings` is a column on the exact same
`Tenant` schema `:TenantsManage` already governs, mutated via the exact same
"only `PLATFORM_ADMIN` may touch this" risk class — no separate role exists
that should reasonably get this and not the rest of `:TenantsManage`'s
surface (confirmed in §0 above: no tenant-admin role exists). Reusing the
permission means **no change to `role_allows?/2`, `permissions/0`'s count
assertion, or `required_permission/1`'s clause set** — only one new
`endpoint_policy_key/2` clause:

```
def endpoint_policy_key("PATCH", "/tenant/settings"), do: :TenantsManage
```

placed in the `:TenantsManage`-cluster region (`authorization.ex:568-578`).
`required_permission(:TenantsManage)` already exists (`:880`) — no new clause
needed there.

**Difference from `Letflow.Routers.Tenants`'s own `:TenantsManage` routes,
stated explicitly so ELIXIR-DEV does not copy the wrong half of that
pattern.** `Tenants`'s six routes are **not** `:prefix`-scoped (moduledoc:
"entirely outside REQ-072's per-tenant `:prefix`-scoping mechanism") because
they operate on the global tenant registry and the target tenant is
caller-selected (`:slug` path param). This endpoint is different: **there is
no target-tenant path parameter at all** — the tenant being patched is always
the caller's own (`conn.assigns.auth_context.tenant_id`), exactly like
`Letflow.Routers.Identity`'s `/users`/`/groups` routes derive their `:prefix`
from the caller's own token. `conn.assigns.scoped_opts` (`[prefix: schema]`,
populated by `Letflow.Plugs.Authorize` for every `authz_*`-declared route) is
used here **only** to scope the audit-entry write (`audit_entries` lives in
the tenant's own schema, REQ-195) — never to scope the `tenants` row lookup
itself, which stays global-table (`Repo.get`, no `:prefix`), matching
`Tenant`'s own placement outside any tenant schema (§0 above, `Tenants`
moduledoc).

---

## 2. New/changed function signatures

### 2.1 `Letflow.Identity.get_tenant/1` (new)

```
@spec get_tenant(id :: Ecto.UUID.t() | String.t()) ::
        {:ok, Tenant.t()} | {:error, :not_found}
```

Mirrors `get_tenant_by_slug/1` (`identity.ex:925-932`) exactly, keyed by `id`
instead of `slug` — `Repo.get(Tenant, id)`. This is the one new context
function this requirement adds to `Letflow.Identity`; it resolves
`conn.assigns.auth_context.tenant_id` (a UUID) to the tenant's `slug`, which
`update_tenant_settings/2` requires as its own first argument (§0 — that
function's signature is not changed). Added rather than widening
`update_tenant_settings/2` to accept an id, because the requirement's own
instruction is "delegate to `update_tenant_settings/2` exactly as it exists
today."

### 2.2 `Letflow.Identity.TenantSettings.allowed_keys/0` (new, made public)

```
@spec allowed_keys() :: [String.t()]
def allowed_keys, do: @allowed_keys
```

Exposes the existing private `@allowed_keys` module attribute
(`tenant_settings.ex:29`) so the router can partition a raw request body into
recognized/rejected top-level keys **using the same list `cast/1` itself
enforces** — never a second, independently-drifting copy of
`~w(app_name logo_url brand_colors locales default_locale)` in the router.
`first_unrecognized_key/1` (private, unchanged) continues to use
`@allowed_keys` directly; this accessor changes nothing about `cast/1`'s own
behavior.

### 2.3 `Letflow.Identity.Tenant.brand_colors_allowed_keys/0` (new, made
   public)

```
@spec brand_colors_allowed_keys() :: [String.t()]
def brand_colors_allowed_keys, do: @brand_colors_allowed_keys
```

Same reasoning as 2.2, for the nested `brand_colors` sub-key allowlist
(`tenant.ex:252`, currently `~w(primary)`). `validate_brand_colors/2`
(private, unchanged in its own signature) continues to reference
`@brand_colors_allowed_keys` directly.

### 2.4 `Letflow.Identity.Tenant.settings_changeset/2` — behavior addition,
   same signature

```
@spec settings_changeset(t :: %__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
```

Signature is unchanged. `validate_brand_colors/2`'s existing `cond` (currently:
unrecognized-key branch, then an `Enum.reduce` checking hex-format per
recognized key) gains a **second check inside the per-key `Enum.reduce`
branch**, run only when the hex-format check already passed for that key:

* For each recognized `brand_colors` key (today only `"primary"`) whose value
  is a syntactically valid `#RRGGBB` hex string, additionally check contrast
  against **both** `tokens.css` reference backgrounds (§3) via
  `Letflow.Identity.ColorContrast.meets_wcag_aa_normal_text?/2` (§3.3).
* If contrast fails against **either** background, append one new plain-language
  error to the `:settings` field (same `{:settings, message}` tuple shape
  every other branch already uses — this is what makes it "a plain-language
  error message the caller can surface verbatim" per AC2, not a bare
  validation atom):

  ```
  "brand_colors.primary does not meet the WCAG AA contrast minimum " <>
  "(4.5:1) against the page/card background; computed contrast ratio is " <>
  "<ratio, 2 decimal places> against #f8f9fa and <ratio> against #ffffff"
  ```

  (exact wording is ELIXIR-DEV's to finalize — the design requirement is:
  plain language, names the failing threshold, names which background(s)
  failed, states the computed ratio so the caller isn't left guessing how
  close it was.)
* A hex-format failure and a contrast failure are mutually exclusive per key
  (contrast is only checked once the format check already passed), so no key
  ever contributes two errors.
* **This still fails the whole `:settings` changeset** (Ecto's
  `validate_change/3` marks the entire field invalid on any error added to
  it) — `Repo.update()` returns `{:error, changeset}`, and **nothing in
  `attrs["settings"]` is persisted**, which is exactly AC2's "previously-stored
  colour stays in effect" requirement. This is pre-existing `validate_change`
  behavior, unchanged by this requirement — stated here so ELIXIR-DEV does not
  mistake it for something that needs new code to guarantee.

### 2.5 `Letflow.Identity.ColorContrast` (new module)

Pure, no `Ecto`/`Plug`/I/O dependency — a small standalone module so the
WCAG math is unit-testable in isolation from `Tenant`'s changeset plumbing.

```
@moduledoc "WCAG 2.1 relative-luminance / contrast-ratio math (REQ-382 §1.4.3)."

@type hex_color :: String.t()  # "#RRGGBB", already regex-validated by the caller

@spec relative_luminance(hex_color()) :: float()
# Standard sRGB relative luminance: for each of R,G,B, normalize to [0,1],
# then apply the piecewise sRGB-to-linear transform
# (c <= 0.03928 -> c / 12.92 ; else -> ((c + 0.055) / 1.055) ** 2.4),
# then L = 0.2126*R_lin + 0.7152*G_lin + 0.0722*B_lin. This is the WCAG 2.1
# "relative luminance" definition verbatim (§1.4.3 formula), not an
# approximation.

@spec contrast_ratio(hex_color(), hex_color()) :: float()
# (L_lighter + 0.05) / (L_darker + 0.05), where L_lighter/L_darker are the
# two colors' relative_luminance/1 values with the larger one in the
# numerator -- symmetric in its two arguments (order of the two hex colors
# passed in does not change the result), matching WCAG 2.1's own ratio
# definition.

@aa_normal_text_min_ratio 4.5

@spec meets_wcag_aa_normal_text?(foreground :: hex_color(), background :: hex_color()) :: boolean()
# contrast_ratio(foreground, background) >= @aa_normal_text_min_ratio
```

**Threshold and formula, stated explicitly per the requirement's own
instruction:** WCAG 2.1 Success Criterion 1.4.3 (AA), "normal text" class,
minimum contrast ratio **4.5:1**, using the standard sRGB relative-luminance
formula above. No "large text" (3:1) allowance is implemented — `--color-brand-600`
is used as ordinary link/interactive text size in `web/`, not exclusively
large-text-sized UI, so the stricter 4.5:1 threshold is the correct one and
is not a judgment call left open.

### 2.6 Reference background colors (module attributes on `Tenant`, or on
   `ColorContrast` — ELIXIR-DEV's call which module hosts the literals; both
   are consumers of `tokens.css`'s values, not of each other)

```
@surface_page_hex "#F8F9FA"   # tokens.css:66 --surface-page -> --color-neutral-50
@surface_card_hex "#FFFFFF"   # tokens.css:67 --surface-card -> --color-neutral-0
```

**Both** backgrounds are checked (not just one) — `brand_colors.primary`
renders as text on both surfaces in `web/` (cards sit on the page background;
both are live surfaces the same interactive color appears against), and the
requirement's own text says "page/card background" (plural). A colour must
pass **both** checks to be accepted; failing either is a rejection (§2.4).

**Known duplication, flagged rather than silently accepted.** These two hex
literals are typed once here and are not read live from `tokens.css` (no
CSS-parsing mechanism exists in this Elixir codebase, and building one for two
literals would be disproportionate — see the *"Duplicating an
`Ecto.Query.fragment/1` SQL literal"* anti-patterns entry for the same
"duplication is sometimes the only available answer" shape, here crossing a
language boundary rather than an Ecto constraint). **If `tokens.css`'s
`--surface-page`/`--surface-card` values ever change, these two module
attributes must be updated in lockstep** — there is no automated check tying
them together today. Recorded as an open question in §6 for whether a future
requirement should add a drift-detecting test (mirroring
`web/theming/__tests__/applyBranding.test.ts:27-32`'s own existing pattern of
reading the literal `--color-brand-600` value out of `tokens.css`'s file
contents at test time) — out of scope to build here, since REQ-382's own
acceptance criteria do not ask for it.

---

## 3. Request-handling algorithm (`Letflow.Routers.TenantSettings.handle_patch/1`,
   prose — no implementation code)

1. `raw = conn.body_params`. If `raw` is not a map (e.g. the body decoded to
   a list, string, number, `true`/`false`, or `nil` — `Letflow.Plugs.SafeJsonParser`
   already guarantees *some* decoded JSON term, per `Letflow.Api.Validation`'s
   own moduledoc, but not that it's an object), respond
   `Response.unprocessable(conn, "request body must be a JSON object")` and
   stop. (INV-8: no bare-map-function call on unvalidated input.)
2. `tenant_id = conn.assigns.auth_context.tenant_id`. Call
   `Identity.get_tenant(tenant_id)` (§2.1).
   * `{:error, :not_found}` — structurally shouldn't happen for a token that
     already passed `AuthPipeline`/`Authorize` (mirrors
     `Letflow.Routers.Tenants.handle_promote/3`'s own "this branch is not
     realistically reachable, still handled defensively" precedent) — respond
     `Response.internal_error(conn)`.
   * `{:ok, tenant}` — continue.
3. Partition `raw`'s top-level keys against `TenantSettings.allowed_keys/0`
   (§2.2):
   * `recognized_top = Map.take(raw, TenantSettings.allowed_keys())`
   * `rejected_top_keys = Map.keys(raw) -- TenantSettings.allowed_keys()`
4. If `recognized_top["brand_colors"]` is present and is a map, partition its
   keys against `Tenant.brand_colors_allowed_keys/0` (§2.3):
   * `recognized_brand_colors = Map.take(recognized_top["brand_colors"], Tenant.brand_colors_allowed_keys())`
   * `rejected_brand_colors_keys = Map.keys(recognized_top["brand_colors"]) -- Tenant.brand_colors_allowed_keys()`
   * Replace `recognized_top["brand_colors"]` with `recognized_brand_colors`
     (may be `%{}` — a legal input, §0/existing `validate_brand_colors/2`
     behavior). If `recognized_top["brand_colors"]` is present but not a map,
     leave it untouched — the existing "brand_colors must be a map" changeset
     error (`tenant.ex:277-279`) still fires downstream unchanged; this is not
     a key-rejection case.
   * If `recognized_top["brand_colors"]` is absent, `rejected_brand_colors_keys = []`.
5. **Merge decision (stated explicitly — see §6 OQ-1 for why this needed a
   judgment call).** `current_settings = tenant.settings || %{}}`.
   `merged_settings = Map.merge(current_settings, recognized_top)` — a
   **shallow, top-level merge**: any of the 5 allowed top-level keys present
   in the (filtered) request replaces that key's previous value entirely;
   every top-level key **absent** from the request keeps its previously-stored
   value untouched. This is a deliberate design decision, not
   `update_tenant_settings/2`'s own behavior (that function, and
   `cast/3` underneath it, replace the whole `:settings` value with whatever
   map it's handed — §0) — without this merge step, a PATCH containing only
   `app_name` would silently erase a previously-set `brand_colors`/`logo_url`/
   `locales`/`default_locale`, which contradicts both the requirement's own
   "partial settings map" language and ordinary PATCH semantics. The merge
   happens in the **router**, not inside `update_tenant_settings/2` itself —
   satisfying "do not change that function's own casting discipline" literally:
   the function's cast list, validations, and replace-whole-field behavior are
   all untouched; only the *input map the router builds* changes.
   `brand_colors` itself is replaced wholesale when present in the request
   (not deep-merged against the previous `brand_colors` map) — correct today
   because it has exactly one allowed sub-key (§0), so there is nothing else
   inside it to preserve; §6 OQ-2 flags this for re-examination only if
   `brand_colors` ever grows a second allowed sub-key (explicitly out of this
   requirement's scope per its own "explicitly out of scope" list).
6. `attrs = %{"settings" => merged_settings}`. Call
   `Identity.update_tenant_settings(tenant.slug, attrs)` (§0 — unchanged
   function, called exactly as it exists).
7. On `{:error, %Ecto.Changeset{} = changeset}` — extract the `:settings`
   field's error message(s) via `Ecto.Changeset.traverse_errors/2` (or
   equivalent — ELIXIR-DEV's choice of exact extraction mechanism, the
   design requirement is: surface the changeset's own plain-language
   message(s) verbatim, joined if more than one, never just `"validation
   failed"` the way `Letflow.Routers.Tenants.handle_patch/2` does for
   `display_name` today — that generic message is explicitly insufficient
   for AC2's "plain-language message the caller can surface verbatim, naming
   why"). Respond `Response.unprocessable(conn, <message>)`. **Stop — no
   audit write on this path** (a value-validation failure, e.g. a
   WCAG-failing colour, is not an out-of-scope-*key* rejection; §0/§2.4
   already establish this is a full-request failure, and AC4's audit
   obligation is scoped to out-of-scope *keys*, not out-of-scope *values*).
8. On `{:error, :not_found}` — same defensive branch as step 2; respond
   `Response.internal_error(conn)`.
9. On `{:ok, updated_tenant}`:
   a. If `rejected_top_keys != []` or `rejected_brand_colors_keys != []`:
      write one audit entry (§4) via `Letflow.Audit.insert_entry/3`, called
      directly with `Letflow.Repo` (§0 — that function accepts an explicit
      `repo` and does not require being inside a caller's own `Ecto.Multi`).
      **This write is sequential, after the settings write has already
      committed — not the same transaction.** §6 OQ-3 states the tradeoff
      this implies and why it was accepted rather than building a new
      Multi-wrapping variant of `update_tenant_settings/2`.
      * On `{:ok, _entry}` — continue to (b).
      * On `{:error, reason}` — log an error (`Logger.error/1`, no tenant
        secret material, INV-4) naming the tenant id and the failure reason;
        **do not fail the HTTP response** — the settings mutation the caller
        asked for already succeeded and must not appear to have failed
        because of an unrelated audit-write hiccup. Still respond 200 (b).
   b. Respond `Response.ok(conn, settings_response_map(updated_tenant))` —
      200. `settings_response_map/1` (new, private, router-local) is a
      hand-built two-key map:
      ```
      %{"tenant_id" => tenant.id, "settings" => updated_tenant.settings || %{}}
      ```
      matching this codebase's established response-allowlist convention
      (`Letflow.Routers.Tenants.tenant_map/1`,
      `Letflow.Routers.TenantConfig.branding_from_settings/1` — never a
      `Jason.Encoder` derivation over `%Tenant{}` as a whole, INV-2-adjacent
      discipline even though INV-2 itself is scoped to S4-and-later
      cross-tenant field exposure, not this same-tenant admin response).

---

## 4. Audit entry shape (REQ-195 `entry_attrs()`, written via
   `Letflow.Audit.insert_entry/3`)

```
%{
  actor_id: conn.assigns.auth_context.user_id,
  action: "tenant_settings.reject_unrecognized_keys",
  resource_type: "tenant_settings",
  resource_id: tenant.id,
  before_state: nil,
  after_state: %{
    "rejected_top_level_keys" => Map.take(raw, rejected_top_keys),
    "rejected_brand_colors_keys" =>
      Map.take(raw["brand_colors"] || %{}, rejected_brand_colors_keys)
  },
  trace_id: conn.assigns[:trace_id]
}
```

called as `Audit.insert_entry(Letflow.Repo, attrs, prefix)` where `prefix`
comes from `conn.assigns.scoped_opts[:prefix]` (§1's "difference from
`Tenants`" note — this is the **one** place this endpoint uses the
`:prefix`-scoped opts, because `audit_entries` is a tenant-schema table,
REQ-195).

* `actor_id` — names the actor (AC4 "naming ... the actor").
* `resource_type "tenant_settings"` / `resource_id tenant.id` — names the
  tenant (AC4 "naming the tenant") via the row's own `tenant_id` column,
  which `insert_entry/3` resolves from `prefix` itself (§0) — not a second,
  redundant tenant-id field inside `after_state`.
* `after_state["rejected_top_level_keys"]` / `["rejected_brand_colors_keys"]`
  — names the rejected key(s) and their exact attempted (raw, unfiltered)
  value(s), satisfying AC4's "the rejected key(s), and the attempted
  value(s)" in one structured, JSON-serializable shape — both are plain maps
  of `key => raw_value`, taken directly from `raw`/`raw["brand_colors"]`
  before any filtering, so the exact submitted value is preserved verbatim
  (not the post-cast/validated form, which for a rejected key never exists).
* Either sub-map may be `%{}` (e.g. a request that only had a rejected
  top-level key and no `brand_colors` at all) — never omitted as a key, so a
  reader of `after_state` always sees the same two-key shape.
* `Letflow.Audit.Entry.changeset/2`'s own `@required_fields` (`id, tenant_id,
  action, resource_type, resource_id, timestamp, chain_hash`) are all
  supplied by `insert_entry/3` itself (§0) — this call site supplies exactly
  the `entry_attrs()` map `insert_entry/3`'s own `@spec` requires, nothing
  more.
* **Exactly one entry per request** (AC4) — step 9(a) above is a single
  `insert_entry/3` call, gated by one `if`, not a per-rejected-key loop; both
  categories of rejection are folded into that one entry's `after_state`.

`AuditLogPage.tsx` surfaces this with zero frontend change per §0's
confirmation — `audit_item/1` (`lib/letflow/routers/audit.ex:326-336`) already
renders `resource_type`/`resource_id`/`action`/`actor_id`/`after_state`
generically for any row, regardless of which context module wrote it.

---

## 5. DB — no new migration

Reuses:
* `tenants.settings` (JSONB, REQ-280's `CreateTenants`/settings-column
  migration) — no schema change.
* `audit_entries` (REQ-195) — no schema change; this is simply a new
  **caller** of `Letflow.Audit.insert_entry/3`, exactly like `create_user/2`,
  `create_token/3`, etc. already are.

---

## 6. Open questions (not silently resolved)

* **OQ-1 (resolved above, flagged for CODE-DESIGN-VALIDATOR/SECURITY-REVIEWER
  confirmation, not silently assumed).** §3 step 5's shallow top-level merge
  is new behavior beyond what any single acceptance criterion names in so
  many words — it is this design's own judgment call to avoid a data-loss
  footgun (a `brand_colors`-only PATCH silently erasing a previously-set
  `app_name`). It does not change `update_tenant_settings/2`'s own casting
  discipline (the function itself is untouched); it changes what map the
  router builds before calling it. Flagged explicitly per this workflow
  step's own instruction not to silently resolve an ambiguity — please
  confirm this reading of "partial settings map" is the intended one rather
  than "the request body is the full intended settings state, and `PATCH`
  here means 'not all 5 keys are required to be present' only."
* **OQ-2.** `brand_colors` is replaced wholesale (not deep-merged) when
  present in the request — correct today because it has exactly one allowed
  sub-key. If a future requirement adds a second `brand_colors` sub-key,
  this merge step must be revisited to decide whether a partial
  `brand_colors` update (setting `primary` without needing to resend the
  hypothetical second key) is expected. Out of this requirement's scope
  (its own "explicitly out of scope" list already excludes extending the
  `brand_colors` allowlist) — not resolved here, only flagged for whichever
  future requirement does extend it.
* **OQ-3.** The settings write (step 6) and the audit write (step 9a) are two
  separate, non-transactional `Repo` operations — not wrapped in one
  `Ecto.Multi`/`Repo.transaction/1`, because achieving that would require
  either changing `update_tenant_settings/2`'s own internals (forbidden by
  the requirement's explicit instruction) or reimplementing its
  changeset-plus-update logic a second time inside a new Multi-based sibling
  function (a duplicated, independently-drifting copy of that function's own
  body — the exact anti-pattern the *"Duplicating an
  `Ecto.Query.fragment/1` SQL literal"* anti-patterns entry warns against in
  spirit). Accepted consequence: on the rare case where the settings write
  succeeds but the subsequent audit write then fails (a real DB error, not a
  validation failure), the settings change is retained and no audit entry
  exists for that one request's rejected keys — logged as an error (step 9a)
  rather than silently dropped. Flagged for SECURITY-REVIEWER: is this
  acceptable for a first HTTP-reachable write path onto `tenant.settings`,
  or does this specific case warrant a dedicated Multi-based variant after
  all? Not resolved unilaterally here.
* **OQ-4.** Exact wording of the WCAG-failure error message (§2.4) is left to
  ELIXIR-DEV to finalize within the stated constraints (plain language,
  names the 4.5:1 threshold, names the ratio computed, names which
  background(s) failed) — the requirement asks for "a plain-language error
  message," not a byte-exact string, and no downstream test in this
  requirement's own acceptance criteria depends on an exact wording (only on
  it being present, plain-language, and causing the previously-stored colour
  to remain in effect).

---

## 7. Invariant mapping (security-invariants.md, per REQ-382's own
   instruction to design with INV-4/INV-7/INV-8 explicitly in mind)

* **INV-1 (tenant data isolation).** The `tenants` row read/write itself is
  global-table (not `:prefix`-scoped, matching `Tenant`'s existing placement
  — §0/§1), gated entirely by `:TenantsManage` (`PLATFORM_ADMIN`-only). The
  **audit-entry write** is the one tenant-schema-scoped operation this
  endpoint performs, and it is scoped via `conn.assigns.scoped_opts[:prefix]`
  — derived solely from `conn.assigns.auth_context.tenant_id` (never a path/
  query/body value, matching `Letflow.Api.Context.scoped_repo_opts/1`'s own
  "no function here takes a tenant/schema/prefix argument" invariant, §0).
  There is no path parameter naming a target tenant at all (§1) — the
  written-to tenant is structurally always the caller's own.
* **INV-4 (secrets by reference only).** Nothing this endpoint touches is
  secret material — `brand_colors`/`app_name`/`logo_url`/`locales` are all
  already-public branding values (`GET /api/tenant-config` already serves
  them unauthenticated, per `TenantConfig`'s own moduledoc). The one INV-4
  touchpoint is step 9(a)'s failure-path log line, which must name only the
  tenant id and error reason — never the raw exception term (mirrors
  `safe_get_tenant_by_slug/2`'s own "never the exception itself" discipline,
  §0/`identity.ex:949-963`).
* **INV-7 (no SQL string interpolation).** No raw SQL anywhere in this
  design — `Repo.get`, `Repo.update` via changeset, and `Audit.insert_entry/3`
  (itself parameterized `Ecto.Query`/`Repo.insert`) are the only DB calls.
* **INV-8 (no unhandled crashes on realistic failure paths).** §3 step 1
  guards the non-map-body case explicitly (no bare `Map.keys/1` call on
  unvalidated input). Every branch of `Identity.get_tenant/1` and
  `Identity.update_tenant_settings/2`'s return values is matched (no bare
  `{:ok, x} =`). The audit-write failure path (step 9a) is itself a case this
  design handles rather than lets crash the request.

---

## 8. Cross-module dependencies

```
Letflow.Routers.TenantSettings (new)
  -> Letflow.Identity.get_tenant/1 (new)
  -> Letflow.Identity.TenantSettings.allowed_keys/0 (new accessor)
  -> Letflow.Identity.Tenant.brand_colors_allowed_keys/0 (new accessor)
  -> Letflow.Identity.update_tenant_settings/2 (existing, unchanged)
       -> Letflow.Identity.Tenant.settings_changeset/2 (existing signature,
            validate_brand_colors/2 internals gain a contrast check)
            -> Letflow.Identity.ColorContrast (new module)
  -> Letflow.Audit.insert_entry/3 (existing, unchanged)
  -> Letflow.Api.Authorization (new endpoint_policy_key/2 clause only)

Letflow.Plugs.ApiPipeline
  -> forward("/tenant/settings", to: Letflow.Routers.TenantSettings) (new)
```

No change to `Letflow.Identity.TenantSettings.cast/1`/`load/1`/`dump/1`, no
change to `Letflow.Audit.Entry`'s schema, no change to
`Letflow.Routers.TenantConfig`/`Letflow.Routers.MobileTenantConfig` (the read
side REQ-382 explicitly does not touch), no migration.

`test/letflow/api/authorization_enforcement_test.exs` (REQ-131) introspects
every `use Letflow.Api.AuthorizedRouter` router's `__authz_routes__/0` — this
new router and its one `authz_patch` route are automatically covered by that
existing mechanism; no new test-infrastructure change is implied by this
design, only that ELIXIR-DEV's new router correctly `use`s
`Letflow.Api.AuthorizedRouter` (§1) rather than plain `Plug.Router`.

---

## 9. Acceptance-criteria → design-element map

| AC | Design element |
|---|---|
| AC1 — authenticated tenant-admin-scoped PATCH; valid `brand_colors.primary` round-trips through `GET /api/tenant-config` | §1 route + `authz_patch "/", :TenantsManage`; §3 steps 1-9(b); §0 confirms `GET /api/tenant-config` already reads `tenant.settings` live via `TenantConfig.branding_from_settings/1` — no read-side change needed, so a successful `Repo.update` (step 6/9) is visible on the very next `GET` call by construction |
| AC2 — WCAG-AA-failing colour refused with plain-language message; previous colour unchanged | §2.4 (contrast check + message), §2.5 (`ColorContrast` module + 4.5:1 threshold + formula), §3 step 7 (message surfaced verbatim), §2.4's note that `validate_change/3` failure leaves nothing persisted |
| AC3 — out-of-allowlist top-level key or `brand_colors` sub-key applies only the recognized/valid part, never 500s or rejects the whole request for that reason alone | §3 steps 3-6 (partition + shallow merge + delegate); §3 step 7 is explicitly a *different* failure class (value validation, not key rejection) and does not contradict AC3 |
| AC4 — same rejected-key request writes exactly one `Letflow.Audit` entry naming tenant/actor/rejected key(s)/attempted value(s); `AuditLogPage` surfaces it with zero frontend change | §4 (entry shape), §3 step 9(a) (exactly one call, gated by one `if`), §0's confirmation of `AuditLogPage.tsx`'s generic rendering of any `audit_entries` row |
| AC5 — `settings_changeset/2`'s cast list stays `[:settings]` only; `TenantSettings`' closed vocabulary unchanged; endpoint cannot touch `:status`/`:slug`/`:idp_realm_id`/`:display_name` | §2.4 states the signature and cast list are unchanged; §1/§3 never call `update_changeset/2`, `admin_patch_changeset/2`, or `status_changeset/2` — the only Tenant-mutating call this endpoint ever makes is `update_tenant_settings/2`, whose own changeset (`settings_changeset/2`) is structurally incapable of touching those four fields (per that changeset's own existing `@doc`, §0) |
| AC6 — `mix compile --warnings-as-errors` / `mix test` pass; SECURITY-REVIEWER sign-off mandatory (INV-4/INV-7/INV-8 + others) | §7 states the invariant mapping explicitly, including a stated-not-hidden tradeoff (OQ-3) for SECURITY-REVIEWER to rule on; no design element here can be verified until ELIXIR-DEV implements it — this row is downstream of this design step, not satisfied by it |
