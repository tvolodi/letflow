# REQ-283 — Apply tenant branding as CSS custom-property overrides on `tokens.css` (0020 D1c, theming half)

Status: design (CODE-DESIGNER). Implements the theming half of
`docs/migration/decisions/0020-frontend-architecture.md`'s Sequencing step 6
(D1-theming). Frontend-only; no backend change. Depends on REQ-279 (page
migration — literal-colour guard's `pages/` exemption deleted) and REQ-281
(`GET /api/tenant-config`'s `branding` key), both merged.

Scope fence, carried from the requirement: theming only. The `x-ui` widget
vocabulary and `fieldRegistry` population (the forms half of step 6) is
REQ-284, already done — this design does not touch `fieldRegistry.ts`,
`FieldFactory.tsx`, or any widget file. No tenant-authored JavaScript
execution mechanism of any kind. No browser-side expression evaluator (that
is decision 0014's domain, server-side only).

## 0. Re-verification against the live tree

**`web/src/auth/tenantConfig.ts`** (read in full) — `fetchTenantConfig(hostname)`
calls `GET /api/tenant-config`, caches the result in module-level
`_cachedConfig`, and on any thrown error (network failure, non-2xx — the
underlying endpoint itself never errors, but the client call can still
reject, e.g. on a timeout or a network partition) falls back to
`{ oidc_authority: DEFAULT_AUTHORITY, client_id: DEFAULT_CLIENT_ID }`, still
caching that fallback. `getCachedTenantConfig()` returns the cache or the
same default synchronously. The `TenantConfig` interface today has **only**
`oidc_authority` and `client_id` — no `branding` field is typed, even though
the endpoint has returned one since REQ-281. This is the gap this
requirement's frontend half closes.

**`lib/letflow/routers/tenant_config.ex`** (read in full) — `GET
/api/tenant-config` always returns 200 with exactly three top-level keys:
`oidc_authority`, `client_id`, `branding`. `branding` is itself a closed,
exactly-three-key map, **always present with all three sub-keys**, each
individually defaulted server-side when the tenant has not set it:
`app_name` (string, default `"Letflow"`), `logo_url` (string or `null`,
default `null`), and `brand_colors` (an object with exactly the one sub-key
`"primary"` holding a `#RRGGBB` string, default `{"primary": "#228be6"}`).

`brand_colors` is server-validated (`lib/letflow/identity/tenant.ex`,
`@brand_colors_allowed_keys ~w(primary)`) to contain **only** the key
`"primary"`, whose value is always a 6-digit hex colour. The server never
sends a `brand_colors` map with any other key, and never omits `"primary"`
when `brand_colors` is present — but the frontend must not rely on that
invariant (see §3, defence in depth) and must independently ignore any key
outside its own allowlist.

Note the platform default `"#228be6"` is exactly `tokens.css`'s
`--color-brand-600` (confirmed by direct read of both files) — REQ-281 chose
this value specifically to be consistent with `tokens.css`, per that
requirement's design §6. This is what makes the CSS override 1:1 and
lossless: the server's "no override" value and the CSS token's compiled-in
default are the same colour.

**`web/src/styles/tokens.css`** (read in full) — `:root` defines
`--color-brand-400/500/600/700` as literal hex values, and other tokens
(`--border-focus`, etc.) reference `--color-brand-500` via `var()`. Only
`--color-brand-600` corresponds to the server's `brand_colors.primary` key.
The other three brand shades (400/500/700) have **no** server-side
counterpart today — overriding them is out of scope and NOT invented here
(open question, §7).

**Existing branding/theming code** — grepped `web/src/` for `brand`, `theme`,
`logo` (case-insensitive): no branding/theming provider, hook, or CSS
custom-property-setting code exists anywhere. The only near-miss is
`TenantHeader.tsx`, which renders `tenantDisplayName` (a *user's tenant's
display name*, sourced from `Letflow.Identity.Tenant.display_name` via the
JWT/`/tenants/:slug` lookup) — an entirely different concept from
`branding.app_name` (a *marketing/product name* a tenant sets for its own
login/shell chrome). `TenantHeader` is untouched by this requirement.

**Hard-coded product name locations** — grepped for the literal `Letflow` in
`web/src/**/*.{ts,tsx}` (excluding tests): exactly two hits:
  - `web/index.html:7` — `<title>Letflow</title>` (static HTML, outside
    `web/src/`, not React-rendered — out of scope for a component-level
    override; see §6 for why this is not touched).
  - `web/src/components/layout/AppShell.tsx:67` — a literal `Letflow` text
    node in the sidebar header, the one hard-coded product name that is
    actually React-rendered and therefore assertable by a render test. This
    is the file AC6 targets.

There is no dedicated login page component (`find web/src -iname "*login*"`
returns nothing) — authentication is an external redirect to Keycloak
(`AuthProvider.tsx`'s `signinRedirect`). `AppShell` — the shell every
authenticated route renders inside (`web/src/router.tsx`, not re-quoted here)
— is therefore the "login/bootstrap surface" AC6 refers to: it is the first
and only branded chrome the SPA itself renders.

**Bootstrap sequence** (`web/src/main.tsx`, read in full) — module-level,
before `ReactDOM.createRoot(...).render(...)`:
```
void fetchTenantConfig(window.location.hostname)   // pre-warms _cachedConfig
registerBuiltinWidgets()                             // REQ-284, unrelated
```
then renders `<QueryClientProvider><RouterProvider router={router} /></QueryClientProvider>`.
`fetchTenantConfig`'s promise is deliberately not awaited before the first
render (existing behaviour, unchanged) — the OIDC redirect must not be
blocked on this call. The branding mechanism must fit into this same
never-block shape.

## 1. Files touched or added

| File | Change |
|---|---|
| `web/src/auth/tenantConfig.ts` | Type-only: add optional `branding` field to `TenantConfig`. No logic change — the endpoint already returns it. |
| `web/src/theming/brandingDefaults.ts` (new) | Platform-default branding constant, the closed CSS-property allowlist map, and shared types. No hex literal (see §3.4 for why the allowlist map contains no colour values). |
| `web/src/theming/applyBranding.ts` (new) | Pure-ish function(s) that read a `Branding` object and set/leave CSS custom properties on `document.documentElement`. No React. |
| `web/src/theming/BrandingContext.tsx` (new) | `createContext` + `useBranding()` hook, default value = platform defaults. |
| `web/src/theming/BrandingProvider.tsx` (new) | Component: on mount, awaits `fetchTenantConfig`, calls `applyBrandingColors`, publishes `{ appName, logoUrl }` via context. |
| `web/src/main.tsx` | Wrap `<RouterProvider>` in `<BrandingProvider>`. |
| `web/src/components/layout/AppShell.tsx` | Replace the literal `Letflow` text node (line 67) with `useBranding().appName`; render the tenant logo via an `<img>` when `logoUrl` is non-null. |
| `web/src/theming/__tests__/applyBranding.test.ts` (new) | AC1, AC2, AC3. |
| `web/src/theming/__tests__/BrandingProvider.test.tsx` (new) | AC2 (endpoint-failure case), AC4 (logo markup-injection). |
| `web/src/components/layout/__tests__/AppShell.branding.test.tsx` (new) | AC6, and AC4's rendered-`<img>` assertion. |

No file outside this table is touched. `fieldRegistry.ts`, `FieldFactory.tsx`,
and everything under `web/src/components/forms/` are untouched (scope fence).

## 2. Bootstrap mechanism — where/when/what triggers it

**Trigger: component mount of `<BrandingProvider>`, wrapping the router at
the app root — not a bare module-level side effect in `main.tsx`.**

Rationale for this choice over the "call it straight from `main.tsx`" option
the requirement flags as an alternative: AC1/AC2/AC3's tests render the app
(or a subtree) and assert on `document.documentElement`'s computed style
after the branding call resolves — that requires an effect the test's
`render()` call actually triggers. A bare module-level call in `main.tsx`
never runs under a component-level test (Testing Library never executes
`main.tsx`), so it would be untestable by the acceptance criteria's own
wording ("a test renders the app with a branding block"). A mounted
provider component is the mechanism that is both idiomatic React and
satisfies the tests as literally specified.

`main.tsx` keeps its existing `void fetchTenantConfig(...)` pre-warm call
(unchanged, still serves its original purpose of having the OIDC config
ready before the auth redirect) and additionally wraps the tree:

```
<QueryClientProvider client={queryClient}>
  <BrandingProvider>
    <RouterProvider router={router} />
  </BrandingProvider>
</QueryClientProvider>
```

`BrandingProvider`'s effect:

1. On mount, call `fetchTenantConfig(window.location.hostname)`. Because
   `_cachedConfig` is a module-level singleton in `tenantConfig.ts`, this is
   the *same* in-flight promise/cache `main.tsx`'s pre-warm call created or
   will create — no duplicate network request, no race: whichever call
   started the fetch first wins, the other resolves against the same
   promise (the existing `fetchTenantConfig` short-circuits on
   `_cachedConfig` set, and while a fetch is in flight there is exactly one
   `fetch` call in progress because `main.tsx` calls it first, before
   `BrandingProvider` ever mounts).
2. On resolution (success or the function's own internal fallback — recall
   `fetchTenantConfig` **never rejects**, it catches internally and resolves
   to the fallback object), read `config.branding` (may be `undefined` if the
   fallback object shape omits it — see §4).
3. Call `applyBrandingColors(config.branding?.brand_colors)` — sets CSS
   custom properties on `document.documentElement` (§3).
4. Call the context state setter with
   `{ appName: config.branding?.app_name ?? PLATFORM_DEFAULT_APP_NAME, logoUrl: config.branding?.logo_url ?? null }`.
5. Until step 4 completes, `useBranding()` returns the platform-default
   context value (`BrandingContext`'s `createContext` default, not a
   `Provider`-supplied one) — so the sidebar renders `"Letflow"` and no
   `<img>` for the one render before the effect resolves, then re-renders
   with the tenant's values once they arrive. This matches
   `tenantConfig.ts`'s own "never unstyled, never blocked" contract: the
   shell is never blank or broken while branding is in flight, and colours
   never flash from "unstyled" to styled because the *colour* override (step
   3, CSS custom properties) is independent of component re-render — it is
   set directly on `document.documentElement` the instant the promise
   resolves, without waiting for React to re-render `AppShell`.

`applyBrandingColors` and `BrandingContext`'s default value are two
independent fallback paths (colours vs. text/logo) that both resolve to the
same platform defaults — see §4 for why this is one rule, not two.

## 3. The closed allowlist of settable CSS custom properties

**Exactly one entry**, matching REQ-281's response shape exactly (`brand_colors`
has exactly one server-recognized sub-key, `"primary"`, confirmed in §0).
`web/src/theming/brandingDefaults.ts` defines a single frozen lookup table,
`BRAND_COLOR_CSS_PROPERTY`, of type `Readonly<Record<'primary', string>>`,
holding exactly one mapping: the `brand_colors` sub-key `"primary"` maps to
the CSS custom-property name `--color-brand-600`. No other key exists in
this table. Extending it is the change described at the end of this section.

`applyBrandingColors(brandColors: Record<string, string> | undefined): void`
in `applyBranding.ts`:

- Iterates only the keys of `BRAND_COLOR_CSS_PROPERTY` (never
  `Object.keys(brandColors)`) — for each allowlisted key, if
  `brandColors?.[key]` is a non-empty string, sets the corresponding CSS
  custom property (via `document.documentElement.style.setProperty`) to that
  value; if the key is absent/falsy, does nothing (leave whatever
  `tokens.css`'s cascade already provides — see §4).
- Never reads or writes any property name not present in
  `BRAND_COLOR_CSS_PROPERTY`, regardless of what extra keys a (malformed,
  bypassing-the-server-validator, or future) `brandColors` object might
  carry. This is the mechanism AC3's test exercises: supply a `brand_colors`
  object with a key outside the map (e.g. `{ primary: '#123456', evilKey:
  '#ffffff' }` or a key crafted to look like a CSS custom property such as
  `{'--totally-unrelated-var': '#ffffff'}`) and assert
  `document.documentElement.style.getPropertyValue('--totally-unrelated-var')`
  is empty / the guard property was never called with that name.
- Defence in depth, independent of the server's own `@brand_colors_allowed_keys`
  enforcement (§0): even if the server allowlist were ever loosened, this
  client-side allowlist is a second, independent gate — a property name
  reaching `document.documentElement.style.setProperty` can only ever be
  `--color-brand-600`, because that is the only string literal that function
  is ever called with in this codebase.
- No hex-colour literal appears in `applyBranding.ts` or
  `brandingDefaults.ts` — the allowlist maps a *key name* string
  (`'primary'`) to a *CSS property name* string (`'--color-brand-600'`),
  never to a colour value, so this file is not a `literal-colour`-guard
  violator and needs no `allowedPaths` addition to
  `web/tests/guards/forbidlist.ts`.

**Extending this allowlist later** (e.g. if the server ever adds a second
`brand_colors` sub-key, or exposes `--color-brand-400/500/700` for tenant
override) requires: (a) the server-side `@brand_colors_allowed_keys` change
first (a security change per `tenant_config.ex`'s own moduledoc), (b) a new
entry in `BRAND_COLOR_CSS_PROPERTY`, (c) new test coverage. Not invented
here — see §7.

## 4. Fallback behaviour — one rule, three triggering cases

**Single rule:** at every level (top-level `branding` object, and each
individual key inside it, and each individual `brand_colors` sub-key), an
**absent** value means "do not override; the platform default already in
`tokens.css` / the hard-coded frontend default wins." There is no second,
different fallback path for "missing" versus "present but a sub-key is
missing" versus "whole call failed" — all three collapse to the same
optional-chaining reads described in §2 step 2–4 and the allowlist iteration
in §3, because `fetchTenantConfig` guarantees a resolved value in every case
(it never rejects) and every read of a branding field uses `?.` / `??`
against a possibly-absent object.

The three cases named by AC1/AC2, walked through explicitly:

1. **Branding block absent entirely** (`config.branding === undefined` — the
   shape `fetchTenantConfig`'s own internal catch-fallback object has today,
   since that fallback literal is `{ oidc_authority, client_id }` with no
   `branding` key at all — see §5's required tenantConfig.ts change note
   below). `config.branding?.brand_colors` is `undefined` →
   `applyBrandingColors(undefined)` finds no allowlisted key with a truthy
   value → sets nothing → `--color-brand-600` keeps whatever `tokens.css`'s
   cascade already defines (`#228be6`). `config.branding?.app_name` is
   `undefined` → `?? PLATFORM_DEFAULT_APP_NAME` (`"Letflow"`, a plain string
   constant, not a CSS/colour value) wins. `logo_url` → `?? null` → no `<img>`
   rendered.
2. **Branding block present, a given key missing** (e.g. server response
   has `branding.brand_colors = {}` or omits `app_name` — should not happen
   given the server's own defaulting per §0, but the frontend must not
   assume it): identical to case 1 at the level of the missing key only —
   other present keys still apply normally.
3. **The `/api/tenant-config` call fails outright** (network error, timeout):
   `fetchTenantConfig`'s existing `try/catch` (unchanged) catches it and
   resolves to its fallback object. Case reduces to case 1, because that
   fallback object has no `branding` key (see §5).

All three converge on `tokens.css`'s already-compiled-in defaults for
colours and the frontend's own `PLATFORM_DEFAULT_APP_NAME` / `null` for
text/logo — matching `tenantConfig.ts`'s existing degrade-gracefully
contract verbatim (never unstyled, never blocked).

## 5. Required `tenantConfig.ts` change (type-only)

```
export interface Branding {
  app_name: string
  logo_url: string | null
  brand_colors: Record<string, string>
}

export interface TenantConfig {
  oidc_authority: string
  client_id: string
  branding?: Branding
}
```

`fetchTenantConfig`'s success path already returns whatever the endpoint
sends (typed as `TenantConfig` in the `client.get<TenantConfig>(...)` call) —
no code change needed there, only the type gains the `branding?` field. The
catch-path fallback literal (`{ oidc_authority: DEFAULT_AUTHORITY, client_id:
DEFAULT_CLIENT_ID }`) is **left exactly as-is** — it deliberately omits
`branding`, which is what makes case 3 in §4 collapse into case 1 with no
extra code. `getCachedTenantConfig()`'s fallback literal is likewise
unchanged.

## 6. Logo rendering mechanism — image `src`, never markup

**Mechanism: a plain `<img>` element's `src` attribute**, not a
`background-image` CSS custom property. Justification for picking this over
the CSS-custom-property alternative the requirement flags as arguably also
safe: `logo_url` is a URL string a tenant can set to (nearly) any value.
Routing it through `element.style.setProperty('--brand-logo-url', logoUrl)`
and consuming it via `background-image: var(--brand-logo-url)` would still
be a URL *reference*, never HTML — so it would not itself be an XSS vector
either — but it adds an indirection with no benefit here (no other page
needs the logo as a background image, there is exactly one consumer,
`AppShell`'s sidebar header) and would require constructing a `url(...)`
wrapper string, which is unnecessary string-building around a value that
`<img src>` already consumes natively and safely. `<img src={logoUrl}>` is
the simpler, more idiomatic, and more directly testable choice (a test can
assert the rendered `<img>` element's `src` DOM property equals the supplied
string with no interpretation).

`AppShell.tsx` change, described (no implementation code — this is the shape,
not the diff):

- Replace the literal `Letflow` text node at line 67 with an expression
  reading `appName` from `useBranding()`.
- Directly below/beside it, conditionally render an `<img>` element when
  `logoUrl` (from the same hook) is non-null: `src={logoUrl}`, an `alt`
  attribute derived from `appName` (never from raw HTML), sized via existing
  `tokens.css`-based inline style values (no new colour literal). When
  `logoUrl` is `null` (the default/no-branding case), no `<img>` is rendered
  and only the `appName` text shows — identical to today's visual result
  when the tenant has not set a logo.
- **No** `dangerouslySetInnerHTML`, **no** `innerHTML` assignment, **no**
  `eval`, **no** `new Function`, anywhere in this file or any file this
  requirement adds. `src={logoUrl}` passes the string to the DOM's own `src`
  IDL attribute setter, which the browser interprets strictly as a URL to
  fetch as an image resource — even a value containing `<script>` or
  `"><img onerror=...>` is treated as a literal (almost certainly invalid,
  failing-to-load) URL string, never parsed as markup, because `<img>`'s
  `src` is not an HTML-parsing sink. This is exactly what AC4/AC5's
  markup-injection test exercises: supply `logo_url:
  '"><img src=x onerror=alert(1)>'` (or `javascript:alert(1)` — also worth
  covering, since a raw string could in principle be assigned to `src` and
  trigger the `javascript:` URL scheme in some sink types, though not
  through the `src` IDL setter's URL-parsing path for `<img>`; called out
  explicitly as a case the test should include even though `<img src>` does
  not execute `javascript:` URLs, unlike `<a href>` or navigation) and
  assert (a) no extra element with `onerror`/`onclick` etc. is present in
  the DOM, (b) the rendered `<img>`'s `src` DOM property equals the literal
  string passed in (proving no HTML parsing occurred), (c) `document.body`
  contains no injected script/element beyond the single expected `<img>`.
- **`web/index.html`'s `<title>Letflow</title>` is deliberately NOT
  touched by this requirement.** It is static HTML outside `web/src/`, has
  no React render path a component test can exercise, and AC6's own wording
  ("a test rendering with a non-default app name") can only be satisfied by
  a component-level assertion — `AppShell.tsx` is the one hard-coded,
  React-rendered instance and is sufficient to satisfy AC6 literally.
  Updating `document.title` at runtime (e.g. via a `useEffect` in
  `BrandingProvider` calling `document.title = appName`) is a reasonable
  follow-on but is **not required by any acceptance criterion** and is
  flagged as an open question (§7) rather than silently added as
  unrequested scope.

**Grep confirmation this design's own file list is clean** (a design-time
claim, re-verified again by SECURITY-REVIEWER at implementation per the
task brief): none of `tenantConfig.ts`, `brandingDefaults.ts`,
`applyBranding.ts`, `BrandingContext.tsx`, `BrandingProvider.tsx`,
`main.tsx`, or `AppShell.tsx` as designed above calls `eval(`, `new
Function`, `dangerouslySetInnerHTML`, or `innerHTML` with any value —
tenant-supplied or otherwise. `applyBranding.ts`'s only DOM write is
`element.style.setProperty(name, value)` where `name` is always one of the
literal strings in `BRAND_COLOR_CSS_PROPERTY`'s values (never
tenant-supplied) and `value` is a CSS custom-property *value* (a colour
string), which the CSSOM `setProperty` API does not parse as HTML under any
input — the worst a malicious `value` can do is fail validation as a colour
and be ignored by the browser's own CSS engine, not execute anything.

## 7. Open questions (flagged, not silently resolved)

- **`--color-brand-400/500/700` have no server-side override today.** If a
  later requirement wants tenants to control the full brand ramp, that is a
  server-side change first (new `brand_colors` sub-keys, `tenant.ex`
  validator change, `tenant_config.ex` moduledoc security-change process)
  before any allowlist-map extension here. Not invented in this design.
- **`document.title` is not updated at runtime.** No acceptance criterion
  requires it; `web/index.html`'s static `<title>Letflow</title>` stays as
  the initial tab title regardless of tenant. Left as a candidate follow-on,
  not built here.
- **`javascript:`-scheme `logo_url` values.** `<img src="javascript:...">`
  does not execute in any current browser (validated behaviour, not
  first-party-tested by this design), but the test plan (§8) includes a
  `logo_url` value using that scheme anyway as an explicit regression
  anchor, precisely because "current browsers don't execute this" is an
  environment fact, not a guarantee this codebase should rely on silently.
- **Whether `BrandingProvider` should also surface a loading flag** (e.g.
  `isBrandingLoaded`) for pages that want to avoid a name/logo "pop-in" on
  first paint. No acceptance criterion asks for it; the one-render pop-in
  described in §2 step 5 is accepted as-is, matching the existing
  `tenantConfig.ts` pattern of never blocking render on the network call.

## 8. Test coverage plan (maps to every AC)

All tests run under `web/`'s existing Vitest + Testing Library setup,
`// @vitest-environment jsdom`, following `tenantConfig.test.ts`'s existing
style (no MSW/`fetch` mocking — the `literal-colour`/`msw-import`/
`http-mock-adapter` guards and DIRECTIVE T-2 forbid it; mock
`web/src/api/client.ts`'s `client.get` directly, as other suites in this
codebase already do for endpoint-backed hooks).

1. **AC1 — computed-value override test.** Mock `client.get` to resolve
   `branding.brand_colors = { primary: '#ff00ff' }` (a value that differs
   from `tokens.css`'s `#228be6` default). Render `<BrandingProvider>`
   (or the full app root), await the effect, then assert
   `getComputedStyle(document.documentElement).getPropertyValue('--color-brand-600').trim()`
   equals `'#ff00ff'` — the *resolved computed value*, not merely that
   `setProperty` was called (satisfies the AC's explicit "not just 'was
   set'" wording).
2. **AC2a — no-branding fallback.** Mock `client.get` to resolve with a
   `TenantConfig` that omits `branding` entirely. Assert
   `getComputedStyle(document.documentElement).getPropertyValue('--color-brand-600').trim()`
   equals `tokens.css`'s compiled-in default (`'#228be6'`) — read the
   expected value from the stylesheet at test time (e.g. via a fixture
   constant kept next to the CSS's own value, documented in the test file
   as "must track `tokens.css`'s `--color-brand-600`"), not hard-coded blind.
3. **AC2b — endpoint-failure fallback.** Mock `client.get` to reject
   (`Promise.reject(new Error('network'))`). Assert the same
   `--color-brand-600` resolves to the platform default, matching case 3 in
   §4, and assert `useBranding()`'s consumer (`AppShell`) still renders
   `"Letflow"` with no thrown error and no unstyled/blank shell.
4. **AC3 — out-of-allowlist rejection.** Mock `client.get` to resolve
   `branding.brand_colors = { primary: '#ff00ff', notAllowed: '#000000' }`
   (also cover a key crafted as a raw custom-property name, e.g.
   `'--some-other-var': '#000000'`). Assert
   `getComputedStyle(document.documentElement).getPropertyValue('--some-other-var').trim()`
   is `''` (never set) while `--color-brand-600` still resolves to
   `'#ff00ff'` — proving the allowlist is selective, not a blanket reject.
5. **AC4/AC5 — logo markup-injection test.** Mock `client.get` to resolve
   `branding.logo_url = '"><img src=x onerror=window.__pwned=true>'` (and a
   second case with a `javascript:` value, per §7). Render `AppShell` (or
   the relevant subtree) inside a container attached to `document.body`,
   await the branding effect, then assert: `window.__pwned` is `undefined`;
   `container.querySelectorAll('img')` has exactly one element; that
   element's `.src` DOM property equals the literal string supplied (proof
   it was treated as an opaque URL, not parsed as markup); no
   `[onerror]`/`[onclick]` attribute exists anywhere in the rendered
   subtree.
6. **AC6 — app-name replacement test.** Mock `client.get` to resolve
   `branding.app_name = 'Acme Robotics'`. Render `AppShell` inside its
   required providers/router context, await the effect, and assert the
   sidebar no longer contains the text `Letflow` and does contain `Acme
   Robotics`.
7. **AC7 — full command output.** `npm run type-check && npm run lint &&
   npm test && npm run guards` all run from `web/` at implementation time,
   with real quoted output, including `npm run guards` with REQ-279's
   `pages/` exemption already removed (already true on this branch's base,
   confirmed by REQ-279 being `done` and a dependency here).

Every test above is a **new** test in a **new** file per §1's table — no
existing test's assertions are altered to accommodate this change, since no
existing component currently asserts on `--color-brand-600`'s value or on
the literal text `Letflow` in `AppShell` (only a plain render/smoke check, if
any exists today — to be confirmed at implementation time by TEST-DESIGNER
reading `AppShell`'s current test file, if one exists; `find` above showed
none, so this is likely a wholly new coverage area for `AppShell`).
