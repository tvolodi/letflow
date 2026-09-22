# REQ-383 — Company appearance settings screen: design

**Requirement:** REQ-383 (stage S8). Second of two requirements from the
2026-09-20 GUI-review finding whose first half, REQ-382 (merged), built the
HTTP-reachable write path this screen calls:
`PATCH /api/v1/tenant/settings` (`lib/letflow/routers/tenant_settings.ex`).
This requirement builds the tenant-admin-reachable screen itself, the
`StatusBadge` regression test, the stale-NOTE removal in
`test/fixtures/uat/scenarios/platform/tenant-branding-applied.yaml`, and the
e2e pipeline spec that fixture's `pipeline_test:` field already names.

**Status:** design only — signatures, type shapes, and algorithm steps in
prose. No implementation code below.

---

## 0. Confirmed premises (read from source)

* `PATCH /api/v1/tenant/settings` (gated `:TenantsManage`, i.e.
  `PLATFORM_ADMIN`-only) takes `{"settings": {...}}` where `settings` may
  contain any of the 5 top-level keys `TenantSettings.allowed_keys/0`
  recognizes; this screen only ever sends
  `{"settings": {"brand_colors": {"primary": "#RRGGBB"}}}`.
* Success: `200`, body `{"tenant_id": <uuid>, "settings": <full merged
  settings map>}` (`Letflow.Routers.TenantSettings.settings_response_map/2`).
* Contrast-refusal failure: `422`, RFC 9457 Problem Details body
  `{"type", "title": "Unprocessable Entity", "status": 422, "detail":
  "<plain-language WCAG message>", "trace_id"}` — `title` is the generic
  RFC 9457 title, **`detail` is the actual plain-language message** AC2/EO-003
  require ("brand_colors.primary does not meet the WCAG AA contrast minimum
  (4.5:1) against the page/card background; computed contrast ratio is
  <ratio> against #f8f9fa and <ratio> against #ffffff" — exact wording is
  ELIXIR-DEV's per REQ-382 design §2.4/OQ-4, not pinned further here).
* `web/src/api/client.ts`'s `request/1` (`client.ts:127-145`), on any non-ok,
  non-401/429/409 status, builds `ApiError` as
  `{status, message: body['title'] ?? body['message'] ?? statusText, code,
  details: body}` (since `body` has keys, `details` is the **whole decoded
  problem-details object**, including its own `detail` key). **This means
  `err.message` on a 422 is the generic string `"Unprocessable Entity"`, NOT
  the plain-language WCAG message** — that string is only reachable via
  `err.details?.detail`. This is a real, easy-to-miss footgun (confirmed by
  reading `client.ts` and `Letflow.Api.Error`'s `@derive`d field list
  together) — §3.3 below states explicitly which field the mutation's error
  handler must read. This is an existing `client.ts` behavior, not something
  this requirement changes; no `client.ts` edit is in scope here (every
  other 422 consumer in `web/` already has this same `details.detail`
  vs. generic-`message` shape available to it — this is not a new
  contract gap opened by REQ-382, just one this screen must read correctly).
* `applyBrandingColors(brandColors: Record<string,string> | undefined): void`
  (`web/src/theming/applyBranding.ts`) is a **pure DOM side-effect
  function** — no React, no fetch, no state. It iterates
  `BRAND_COLOR_CSS_PROPERTY`'s own keys (today exactly `primary` →
  `--color-brand-600`) and calls
  `document.documentElement.style.setProperty(...)` for each present,
  non-empty string value. Calling it directly is how this screen achieves
  "applied colour takes effect immediately, no full reload" (AC2) — it is
  the exact same function `BrandingProvider.tsx` calls on initial load, so
  calling it again after a successful PATCH re-applies the override live.
* `StatusBadge` (`web/src/components/ui/StatusBadge.tsx`) resolves
  `(domain, status)` pairs from fixed `STATUS_TABLES` entries, every one of
  which references `--color-success*`/`--color-warning*`/`--color-error*`/
  `--color-neutral*`/`--color-info*` custom properties — **never**
  `--color-brand-600`, confirmed by reading the full file (§ "0" of the
  handoff prompt already established this; re-confirmed here by direct
  read). `BRAND_COLOR_CSS_PROPERTY`'s allowlist has exactly one entry,
  `primary → --color-brand-600`, so `applyBrandingColors` is structurally
  incapable of ever writing to a `--color-success*`/`--color-warning*`/
  `--color-error*` custom property. This is what makes AC3/EO-002 a
  regression *test* (prove it, pin it) rather than new production code.
* Existing conventions to reuse, confirmed by reading source: TanStack Query
  `useMutation` (`EditTenantPage.tsx`), `useToast()` for the success
  confirmation (`web/src/hooks/useToast.ts`), `QueryStateBoundary` +
  `classifyError` for the initial-load state (not required here — this
  screen has no GET query to boundary-wrap; see §1), the
  `web/src/api/<domain>.ts` + `client.patch<T>()` pattern
  (`web/src/api/tenants.ts`), and `queryKeys.<group>.<key>()` naming
  (`web/src/api/queryKeys.ts`).
* Route registration: `web/src/router.tsx` imports each admin page and adds
  one `{ path: '...', element: <...Page /> }` entry inside the existing
  admin-routes array (see `admin/tenants`, `admin/tenants/:slug/edit`
  entries at `router.tsx:78-79`).

---

## 1. File layout decision

**New top-level page, not an extension of `EditTenantPage.tsx`:**
`web/src/pages/admin/AppearanceSettingsPage.tsx`, routed at
`admin/appearance` (no `:slug` param).

**Why a new page, and why not nested under `admin/tenants/`.**
`EditTenantPage.tsx` edits an arbitrary tenant **by slug**
(`PATCH /api/v1/tenants/:slug`, `PLATFORM_ADMIN` acting on any tenant row).
`PATCH /api/v1/tenant/settings` (REQ-382 §1, "difference from `Tenants`")
is structurally different: **there is no target-tenant path parameter at
all** — it always patches the caller's own tenant
(`conn.assigns.auth_context.tenant_id`). Folding this into
`EditTenantPage.tsx` would require that page to sometimes mean "the tenant
named in the URL" and sometimes mean "my own tenant," which is exactly the
kind of implicit dual-meaning a screen should not carry. A new page with no
slug param mirrors the endpoint's own caller-is-implicit design 1:1, and
keeps `EditTenantPage.tsx` (registry-admin surface) and
`AppearanceSettingsPage.tsx` (self-service branding surface) as two
separately-reasoned screens. Placed at `web/src/pages/admin/` top level
(sibling to `AuditLogPage.tsx`, `TokensPage.tsx`), not under
`admin/tenants/`, for the same reason — it is not a per-tenant-registry-row
screen.

**Route:** add to `web/src/router.tsx`'s admin-routes array:
```
{ path: 'admin/appearance', element: <AppearanceSettingsPage /> }
```
No link-in-nav design decision is made here (out of scope — this design
covers the screen and its route; wiring a nav-menu entry pointing at it is
FRONTEND-DEV's implementation detail, not an open question, since every
existing admin page in this array is reachable by direct URL at minimum and
several — e.g. `admin/services`, `admin/modules` — are not necessarily
nav-linked either).

---

## 2. Component tree

```
AppearanceSettingsPage                          (web/src/pages/admin/AppearanceSettingsPage.tsx)
├── role guard: session.roles.includes('PLATFORM_ADMIN') — else <Navigate to="/instances" replace />
│   (matches EditTenantPage.tsx's own guard; :TenantsManage is PLATFORM_ADMIN-only, §0)
├── heading ("Appearance")
├── confirmation banner (data-testid="appearance-settings-confirmation") — shown after a
│   successful save, dismissible/auto-hiding is FRONTEND-DEV's call; content is static
│   text, not a toast-only mechanism (see §3.4 for why both exist)
├── error banner (data-testid="appearance-settings-error") — shown after a 422; renders
│   `err.details?.detail` verbatim (§3.3) — never a raw changeset/validation blob
├── <form data-testid="appearance-settings-form">
│   ├── <label htmlFor="brand-color-primary">
│   ├── <input id="brand-color-primary" type="color" data-testid="appearance-settings-primary-color-input"
│   │     value={draftColor} onChange={...} />
│   │   (an HTML `type="color"` input is the ONE form control this screen has for
│   │    submitting a colour — see §5's allowlist-closure argument)
│   ├── live preview swatch (data-testid="appearance-settings-preview-swatch") — a small
│   │   element whose own inline style reads the CURRENT applied
│   │   `--color-brand-600` value (via `getComputedStyle`, §3.5), so the screen visibly
│   │   reflects "what is in effect right now" distinctly from the draft input's value
│   └── <Button type="submit" data-testid="appearance-settings-save" loading={mutation.isPending}>
│         Save
└── (no QueryStateBoundary / no GET query — see §3.1 for why the page has no
    initial-fetch step)
```

---

## 3. State shape and data flow

### 3.1 No initial GET query — where the "current colour" comes from

This screen does **not** issue its own `GET` to learn the tenant's current
`brand_colors.primary` value. Rationale: the value already reaching the
browser is whatever `BrandingProvider` applied on app load (via
`GET /api/tenant-config`, REQ-281/283, §0) — it is already live as the
`--color-brand-600` CSS custom property on `document.documentElement` by
the time any admin screen mounts (compare: EditTenantPage.tsx *does* GET,
because it edits arbitrary fields — `display_name`/`hostname`/
`redirect_uris` — that have no other live-in-DOM source; brand colour is
different, it already has one). Re-fetching tenant settings here would be a
second, redundant source of truth for the same value `BrandingProvider`
already holds, and 5 `TenantSettings` keys are not this screen's concern
(REQ-382's own merge-in-router behaviour, §0, means this screen only ever
needs to send `brand_colors`, never needs to know or preserve the other 4).

```
type AppliedColorSource = 'css-custom-property'

@spec readCurrentAppliedPrimary(): string
// getComputedStyle(document.documentElement).getPropertyValue('--color-brand-600').trim()
// Reads the SAME custom property applyBrandingColors/BrandingProvider write to —
// see brandingDefaults.ts's BRAND_COLOR_CSS_PROPERTY.primary, imported by name
// (never a second hardcoded '--color-brand-600' string literal — see §6 OQ-1).
// Returns '' if unset (tokens.css's own cascade default is then in effect, which
// is a legal state — the input still needs SOME initial value, §3.2).
```

### 3.2 Component state

```
interface AppearanceSettingsPageState {
  appliedColor: string        // last known-good, currently-in-effect colour —
                               // initialized from readCurrentAppliedPrimary() on mount,
                               // updated ONLY on a successful save (§3.4) — never on a
                               // failed one, which is what keeps AC2/EO-003's "previous
                               // colour remains visibly in effect" true structurally
                               // (nothing overwrites it on the 422 path)
  draftColor: string          // the <input type="color"> value — initialized to
                               // appliedColor, freely editable, independent of
                               // appliedColor until a successful save
  errorMessage: string | null // set from err.details?.detail on 422; cleared on next submit
  confirmationVisible: boolean // set true on success; cleared on next submit / on unmount
}
```

`useMutation`'s own `isPending`/`isError`/`isSuccess` are used for the
button's loading state; `errorMessage`/`confirmationVisible` are separate
component state (not derived solely from mutation status) because the
banner must persist across the mutation settling back to idle (TanStack
Query resets `isError`/`isSuccess` on the next `mutate()` call, before this
screen has decided whether to show a NEW banner or clear the old one) —
same pattern already used by `EditTenantPage.tsx`'s
`errorBanner`/`warningBanner` state (§0).

### 3.3 API call shape

New file `web/src/api/tenantSettings.ts` (new module — no existing module
calls this endpoint; do not add this to `tenants.ts`, whose whole surface is
slug-addressed per-tenant-registry operations, §1's "difference from
`Tenants`" argument applies here too):

```typescript
export interface TenantSettingsPatchBody {
  settings: {
    brand_colors: {
      primary: string   // "#RRGGBB" — the ONLY key this screen ever sends, §5
    }
  }
}

export interface TenantSettingsPatchResponse {
  tenant_id: string
  settings: Record<string, unknown>   // full merged settings map (REQ-382 §3 step 9b) —
                                       // typed loosely since this screen only reads back
                                       // settings.brand_colors.primary (§3.5), and the
                                       // other 4 top-level keys are out of this screen's
                                       // concern per §3.1
}

@spec tenantSettingsApi.patchBrandColorPrimary(primary: string): Promise<TenantSettingsPatchResponse>
// Single member of the tenantSettingsApi object, mirroring tenants.ts's
// client.<verb>()-wrapping convention (§0). Body sent is exactly
// { settings: { brand_colors: { primary } } } — a TenantSettingsPatchBody
// literal, constructed with client.patch<TenantSettingsPatchResponse>()
// against '/api/v1/tenant/settings' (§0's confirmed endpoint/verb). No
// other field of TenantSettingsPatchBody is ever populated; no other
// endpoint is ever called from this function.
```

`queryKeys.ts` addition (this screen has no `useQuery`, so this is not
strictly required for THIS screen's own correctness, but is added for
naming-convention consistency and in case a future requirement adds a GET
of this same resource):
```
tenantSettings: {
  all: ['tenant-settings'] as const,
}
```
(Open question — see §6 OQ-2 — whether this key group is worth adding now
with nothing consuming it, or should be deferred to whichever future
requirement actually adds a query. Flagged, not silently decided.)

### 3.4 Mutation, confirmation, and immediate local effect (AC1/AC2)

```
@spec useMutation<TenantSettingsPatchResponse, ApiError, string>({ mutationFn, onSuccess, onError }): UseMutationResult
// mutationFn input: primary: string (the draft colour submitted)
// mutationFn output: TenantSettingsPatchResponse (§3.3) — via tenantSettingsApi.patchBrandColorPrimary
// onSuccess input: (data: TenantSettingsPatchResponse, primary: string)
// onError input: (err: ApiError) — see §0 for the ApiError field shape
```

**State transitions on success (`onSuccess`):**
- Call `applyBrandingColors({ primary })` with the submitted value (immediate
  local DOM effect, no reload — §0) — this is a direct call, not a re-fetch,
  so it uses the value the mutation was already invoked with.
- `appliedColor := primary` (the "currently in effect" state variable, §3.2,
  is updated ONLY here).
- `errorMessage := null`.
- `confirmationVisible := true`.
- Show a secondary success toast (`useToast()`'s existing convention, §0) —
  additive to, not a replacement for, the confirmation banner.

**State transitions on failure (`onError`):**
- `confirmationVisible := false`.
- `errorMessage :=` `apiErr.details.detail` when that field is a string (the
  real plain-language WCAG message, per §0/§3.3's confirmed `ApiError`
  shape); otherwise falls back to `apiErr.message` as a defensive path for a
  malformed/unexpected error shape only — never reached for a well-formed
  422 per §0.
- Deliberately does **not** call `applyBrandingColors` and does **not**
  touch `appliedColor` — the DOM custom property was never written to for
  this failed request, so the previously-applied colour remains in effect
  purely because nothing overwrote it. This is what makes AC2/EO-003 hold by
  construction, not by an extra "revert" step that could itself have a bug.

**Why the `applyBrandingColors` call and the `appliedColor` update together
satisfy AC1's "confirmation is shown" and "applied colour takes effect
immediately... on the same screen" in one mutation callback:**
`applyBrandingColors` writes the DOM custom property
synchronously (no second network round-trip — it takes the value the
mutation was already called with, not a re-fetched one), so by the time
`confirmationVisible` flips true and React re-renders the banner, the
preview swatch (§3.5, which reads the same custom property) already
reflects the new colour in the same paint. No `window.location.reload()`,
no `qc.invalidateQueries` needed for THIS screen's own visual proof (AC1
does not ask for propagation to `AuditLogPage`/other screens, only "takes
effect immediately... reflected somewhere on the same screen").

### 3.5 Preview swatch — "reflected somewhere on the same screen"

```
@spec previewSwatchStyle(appliedColor: string): React.CSSProperties
// { background: appliedColor || 'var(--color-brand-600)', ... } — reads component
// state (appliedColor), not a fresh getComputedStyle call on every render (that
// state is already kept in sync with the DOM custom property per §3.2/§3.4)
```

This element is the concrete answer to AC1's "takes effect immediately
without a full page reload being required to see it reflected somewhere on
the same screen" — a swatch (or equivalently, the input's own
`background`/native colour-well rendering, FRONTEND-DEV's call on whether a
separate swatch element is needed given `<input type="color">`'s own
built-in swatch) that visibly changes the instant `onSuccess` fires.

---

## 4. Error surface (AC2/EO-003)

* On 422: `errorMessage` (from `err.details.detail`, §3.3) is rendered
  verbatim inside `data-testid="appearance-settings-error"`, `role="alert"`
  — same `role="alert"` pattern `EditTenantPage.tsx`'s banners already use.
  **Never** `JSON.stringify(err)`, `err.details` as a whole object, or any
  Ecto/changeset-shaped structure — exactly one string, the `detail` field,
  matching EO-003's "never a raw validation-error blob."
* `draftColor` is **not** reset to `appliedColor` on a 422 — the admin's
  rejected input stays visible in the input so they can see what they
  tried and adjust it, while the swatch/`appliedColor` (a **separate**
  piece of state, §3.2) is what stays pinned to the last-successful value.
  This is the concrete mechanism behind "the previously-applied colour
  remains visibly in effect" — two different state variables for two
  different things (what's being edited vs. what's actually live), never
  conflated into one.

---

## 5. Allowlist-closure argument (AC4 — "no way to submit an out-of-scope
   key")

Enumerated exhaustively — every UI element and every code path this screen
contains that could reach the network:

1. **Exactly one form control**, `<input type="color" id="brand-color-primary">`,
   bound to exactly one piece of state, `draftColor: string`.
2. **Exactly one mutation call site**, `mutation.mutate(draftColor)`
   (submit handler), which flows into `tenantSettingsApi.patchBrandColorPrimary(primary: string)`.
3. **Exactly one request-body constructor**,
   `{ settings: { brand_colors: { primary } } }` — a **literal object
   expression** with two fixed, hardcoded key names (`settings`,
   `brand_colors`) and one fixed key name holding the one variable
   (`primary`). There is no `...spread`, no `Object.assign`, no
   dynamically-keyed object (`{ [someKey]: value }`), no free-text JSON
   textarea, no "advanced/raw settings" escape hatch anywhere in this
   component tree (§2's full tree has no such element), and no other
   `client.patch`/`client.post`/`client.put` call anywhere in this file.
4. Therefore the **only** JSON shape this screen's compiled code is capable
   of producing as a request body is
   `{"settings":{"brand_colors":{"primary": <string from the one input>}}}`
   — structurally incapable of emitting any other top-level key
   (`app_name`, `logo_url`, `locales`, `default_locale`) or any other
   `brand_colors` sub-key, regardless of what the admin types into the one
   input that exists (a `type="color"` input's value is additionally
   browser-constrained to `#rrggbb` form, but even ignoring that
   constraint, changing the *value* of `draftColor` can never change which
   *keys* the literal object at (3) contains).

This satisfies AC4 by **construction/enumeration**, per the requirement's
own instruction — no server-side reject-path test is attempted here (a
same-origin form literally cannot construct the request the requirement
describes), matching AC4's own stated verification method.

---

## 6. Regression test design (AC3/EO-002 — StatusBadge colours unaffected)

**File:** extend existing `web/src/components/ui/__tests__/StatusBadge.test.tsx`
(no new test file — this is a regression case for that component, same
convention as its existing test cases) with one new `describe`/`it` block.

```
Test: "brand colour change does not alter any StatusBadge resolution"

Setup:
  1. Render <StatusBadge domain="instance" status="ACTIVE" /> (or any one
     representative case per domain table — definition/instance/task/
     rollout/rollout-outcome/event-retirement/event-retirement-outcome, one
     assertion group per domain table since each is an independent lookup
     object, §0) and capture the rendered background/text/dot inline style
     values and the badge's data-testid/data-status/data-domain attributes.
  2. Call applyBrandingColors({ primary: '#112233' }) (imported directly
     from web/src/theming/applyBranding.ts — the REAL function, not a
     mock/stub, matching the guard suite's "no mock HTTP adapters" spirit
     extended to "no faking the one function under regression test here").
  3. Re-render (or read the already-rendered DOM again — StatusBadge takes
     no branding-derived prop, so no re-render is even structurally able to
     change its output, which is itself part of what this test proves) the
     SAME <StatusBadge> instance.

Assertions:
  - Every captured style value/attribute from step 1 is IDENTICAL after
    step 2's applyBrandingColors call, for every domain/status pair tested.
  - None of StatusBadge's resolved style values equal
    'var(--color-brand-600)' before OR after (confirms the component never
    even references the one custom property applyBrandingColors is capable
    of writing to — the structural argument from §0, pinned as a test
    assertion rather than left as only a code-reading claim).

Why this is a real regression test, not busywork: it fails if a future
change ever adds a STATUS_TABLES entry that reads `--color-brand-600` (or
any BRAND_COLOR_CSS_PROPERTY-listed custom property), or if a future
requirement widens BRAND_COLOR_CSS_PROPERTY to a currently-status-adjacent
custom property name — either change would flip the "before/after
identical" assertion.
```

This satisfies AC3 — "a regression test confirms StatusBadge's ... colours
are unchanged after a tenant colour change" — directly; it needs no new
production code (per the requirement's own framing, EO-002 "already holds
structurally today").

---

## 7. `tenant-branding-applied.yaml` NOTE removal (explicit design element)

`test/fixtures/uat/scenarios/platform/tenant-branding-applied.yaml` lines
29-37 (the `NOTE (ISS-0527)` comment block, immediately under
`pipeline_test:`) is removed in full once this requirement's screen and
e2e spec exist and the spec passes — the NOTE's own text says exactly this
("treat any run of this scenario as BLOCKED/UNBUILT_FEATURE... until
FRONTEND-DEV authors it against a real shipped feature"), so its removal
condition is satisfied by this requirement's own completion. The later
`ADDENDUM (2026-09-20, GUI-review sweep, ORCH)` block (lines 39-59) is
**left in place** — it is a historical trace of the finding/filing
decision, not a stale blocker claim, and nothing in this requirement's
scope asks for its removal. Only the `NOTE (ISS-0527)` block is deleted;
`pipeline_test:` itself and every other line are unchanged.

---

## 8. E2e spec design — `web/tests/e2e/pipelines/tenant-branding.pipeline.e2e.spec.ts`

Follows the established pipeline-spec conventions confirmed by reading
`tenant-cache.pipeline.e2e.spec.ts` and `pipeline.ts`'s helpers
(`createPipeline`, `getKeycloakToken`, `loginWithToken`, `navigateSpa`,
`authHeaders`, `shot`).

```
test.describe('Pipeline: tenant-branding-applied (PW-14)', () => {

  test('EO-001/AC1: tenant admin applies a new brand colour, sees confirmation
        and immediate effect', async ({ page, request }) => {
    // 1. assertServiceReadiness, getKeycloakToken (PLATFORM_ADMIN-capable user —
    //    :TenantsManage requires PLATFORM_ADMIN, §0)
    // 2. loginWithToken, navigateSpa(page, '/admin/appearance')
    // 3. read the CURRENT swatch/computed --color-brand-600 value (baseline)
    // 4. fill the colour input with a fresh, contrast-passing hex value
    //    (test-fixture-chosen, e.g. a dark blue known to pass 4.5:1 against
    //    #f8f9fa/#ffffff — picked once, documented inline, not derived at
    //    runtime — matching REQ-382's own contrast formula so this fixture
    //    value does not need live computation in the test)
    // 5. submit; assert data-testid="appearance-settings-confirmation" becomes
    //    visible; assert the swatch/input's live background now reflects the
    //    new colour WITHOUT a page.reload() — proves AC1's "no full reload"
    //    directly (a reload would also happen to show the right colour via
    //    BrandingProvider's own effect, so the test must NOT reload here, or
    //    it would stop proving what AC1 actually requires)
    // 6. shot(page, 'tenant-branding-applied', 'ac1-confirmation-and-live-swatch')
  })

  test('EO-003/AC2: a contrast-refused colour is refused, shows the plain-
        language message, and leaves the previous colour in effect',
        async ({ page, request }) => {
    // 1-2. same login/navigate as above
    // 3. read the current applied colour (post previous test's change, or a
    //    freshly-applied known-good baseline set via API in a setup step —
    //    exact fixture-isolation mechanism is FRONTEND-DEV's call; must not
    //    depend on test execution order between the two `test()` blocks)
    // 4. fill the colour input with a WCAG-AA-failing hex value (a very pale
    //    colour, e.g. near-white, chosen to fail 4.5:1 against both
    //    #f8f9fa/#ffffff — same "picked once, documented inline" approach)
    // 5. submit; assert data-testid="appearance-settings-error" is visible
    //    and its text is non-empty plain language (assert it does NOT
    //    contain "%{" or "Ecto" or a raw changeset-shaped substring, as a
    //    belt-and-braces check against EO-003's "never a raw validation-
    //    error blob")
    // 6. assert the swatch/live --color-brand-600 value is UNCHANGED from
    //    step 3's baseline — the previous colour remains in effect
    // 7. shot(page, 'tenant-branding-applied', 'ac2-contrast-refused-error-and-unchanged-colour')
  })

  test('EO-005: first-paint vs. settled-frame colour flash is present and
        documented (MINOR, not fixed)', async ({ page, request }) => {
    // 1. Ensure the tenant already has a non-platform-default brand colour
    //    applied (via a prior successful PATCH, API call or reusing the
    //    state left by the first test above).
    // 2. Open a FRESH page/context (new browser session, matching the
    //    scenario's own step 2 "signs in fresh in a new browser session")
    //    and navigate to a authenticated screen.
    // 3. Capture a screenshot as close to first paint as Playwright allows
    //    (e.g. immediately after 'domcontentloaded', before waiting on any
    //    branding-dependent selector) — this is EXPECTED to show the
    //    platform-default colour, per EO-005's own documented mechanism
    //    (BrandingProvider's useEffect runs after first paint; main.tsx
    //    does not await the pre-warmed fetchTenantConfig promise, per the
    //    handoff prompt's own citation of BrandingProvider.tsx/main.tsx).
    // 4. Wait for the branding fetch to settle (e.g. poll the computed
    //    --color-brand-600 value until it stops being the platform
    //    default, or wait for a stable marker), then capture a second,
    //    settled-frame screenshot.
    // 5. shot(page, 'tenant-branding-applied', 'eo005-first-paint') and
    //    shot(page, 'tenant-branding-applied', 'eo005-settled-frame') — the
    //    REQUIRED screenshot PAIR the acceptance criteria names explicitly.
    // 6. This test asserts the flash EXISTS (first-paint colour !=
    //    settled-frame colour) — it is a documentation/regression-pin test
    //    for a KNOWN, accepted MINOR behavior (suggested_action: none),
    //    not a bug-fix verification. A future fix to EO-005 would need to
    //    update this assertion's polarity, not just delete the test.
  })
})
```

**Why three `test()` blocks, not one.** Mirrors
`tenant-cache.pipeline.e2e.spec.ts`'s own convention of one `test()` per
expected-outcome under test, each independently loggable/re-runnable by
Playwright, rather than one long monolithic test — and keeps the "assert
the flash exists" test (EO-005, MINOR, informational) clearly separated
from the two BLOCKER/MAJOR-severity acceptance tests (AC1/AC2) so a
Playwright report distinguishes them at a glance.

**Fixture/state isolation between tests, flagged explicitly (see §9 OQ-3):**
this design does not fully pin how the three tests share (or don't share)
tenant colour state — left to FRONTEND-DEV's implementation, with the
constraint stated above (must not depend on execution order).

---

## 9. Open questions (not silently resolved)

* **OQ-1.** §3.1 reads `--color-brand-600` via `getComputedStyle` +
  `BRAND_COLOR_CSS_PROPERTY.primary` (imported constant) rather than a
  second hardcoded string literal, to avoid a drift risk if that mapping
  ever changes. Confirm this is the intended way to avoid duplicating the
  custom-property name, versus (rejected here, flagged in case there is a
  reason preferred) adding a `getCachedTenantConfig().branding?.brand_colors?.primary`
  read instead — that path exists (`tenantConfig.ts`) but reflects the
  value as of the LAST `fetchTenantConfig` call, not necessarily the
  currently-applied DOM state if some other code path has since called
  `applyBrandingColors` directly (as THIS screen's own `onSuccess` does,
  §3.4) — the DOM read is the one source of truth that can't go stale
  relative to this screen's own writes, which is why it was chosen over the
  cache. Stated so a validator/reviewer can confirm this reasoning rather
  than discovering the DOM-read choice unexplained.
* **OQ-2.** §3.3's `queryKeys.tenantSettings` addition is written with
  nothing consuming it yet (this screen has no `useQuery`). Confirm whether
  to add it now for convention-consistency or omit it until a future
  requirement actually needs a `useQuery` for this resource — not resolved
  unilaterally here.
* **OQ-3.** §8's three e2e tests' shared-state/execution-order isolation
  mechanism (fresh tenant-colour baseline per test vs. relying on the
  suite's own natural ordering) is left to FRONTEND-DEV, constrained only
  by "must not depend on execution order between the two AC tests." Flagged
  because Playwright config's own `fullyParallel`/worker settings (not read
  as part of this design pass) may bear on which approach is safe — worth
  FRONTEND-DEV confirming against `playwright.config.ts` before choosing.
* **OQ-4.** Whether a nav-menu link to `/admin/appearance` is added
  alongside the route registration (§1) is left unresolved — REQ-383's own
  acceptance criteria describe a screen a tenant admin can reach and use,
  not a specific nav-placement requirement, and several existing admin
  pages in `router.tsx`'s array are direct-URL-reachable without a visible
  nav entry (§1). Not silently decided either way; FRONTEND-DEV's
  implementation call, non-blocking either way.

---

## 10. Cross-module dependencies

```
web/src/pages/admin/AppearanceSettingsPage.tsx (new)
  -> web/src/api/tenantSettings.ts (new) -> web/src/api/client.ts (existing, unchanged)
  -> web/src/theming/applyBranding.ts (existing, unchanged — applyBrandingColors called directly)
  -> web/src/theming/brandingDefaults.ts (existing, unchanged — BRAND_COLOR_CSS_PROPERTY.primary read)
  -> web/src/hooks/useToast.ts (existing, unchanged)
  -> web/src/auth/AuthContext.tsx (existing, unchanged — session.roles guard)
  -> web/src/components/ui/Button.tsx (existing, unchanged)

web/src/router.tsx (existing — one new route entry + one new import)

web/src/components/ui/__tests__/StatusBadge.test.tsx (existing — one new test block)
  -> web/src/theming/applyBranding.ts (existing, unchanged — imported for the regression test)

web/tests/e2e/pipelines/tenant-branding.pipeline.e2e.spec.ts (new)
  -> web/tests/e2e/pipeline.ts (existing helpers, unchanged)
  -> web/tests/e2e/helpers.ts (existing, unchanged)

test/fixtures/uat/scenarios/platform/tenant-branding-applied.yaml (existing — NOTE block removed, §7)

No backend change. No new migration. No change to lib/letflow/ at all —
REQ-382 already built and merged everything this screen calls.
```

---

## 11. Acceptance-criteria → design-element map

| AC | Design element |
|---|---|
| A tenant admin can submit a new `brand_colors.primary` value through the screen, it round-trips through REQ-382's endpoint, and a confirmation is shown (EO-001 positive half) | §2 (form/input), §3.3 (API call shape), §3.4 (mutation `onSuccess` — confirmation banner + toast), §8 test 1 |
| Submitting a contrast-refused colour shows that endpoint's plain-language message on screen and the previously-applied colour remains visibly in effect — no raw blob (EO-003) | §0 (client.ts `details.detail` footgun identified), §3.4 `onError` (reads `details.detail`), §4 (error surface, two-state-variables argument for "previous colour stays"), §8 test 2 |
| A regression test confirms StatusBadge's approved/waiting/failed colours are unchanged after a tenant colour change (EO-002) | §6 (full test design, extends `StatusBadge.test.tsx`) |
| The screen's own form has no field/control/code path capable of submitting a key this requirement did not itself add | §5 (exhaustive enumeration/closure argument) |
| The stale NOTE (ISS-0527) is removed from `tenant-branding-applied.yaml` and `web/tests/e2e/pipelines/tenant-branding.pipeline.e2e.spec.ts` exists, passes, and includes a first-paint-vs-settled-frame screenshot pair (EO-005) | §7 (NOTE removal), §8 test 3 (spec design + required screenshot pair) |
