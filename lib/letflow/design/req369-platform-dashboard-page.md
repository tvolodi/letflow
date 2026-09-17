# REQ-369 — PlatformDashboardPage + role-conditional login routing

**Status:** design (Step 1, WF-02)
**Owner (implementation):** FRONTEND-DEV
**Scope:** `web/` only — no backend/API changes. No new endpoint. No DB.

## 0. Summary of change surface

Three files change, all already enumerated in `owned_modules`:

1. NEW `web/src/pages/dashboard/PlatformDashboardPage.tsx`
2. MODIFIED `web/src/router.tsx` — one new route added, two existing entries untouched
3. MODIFIED `web/src/pages/OidcCallbackPage.tsx` — `navigate('/', ...)` becomes
   role-conditional

Plus one non-code artefact updated as part of this requirement's own close-out (owned by
FRONTEND-DEV at Step 2b, not a separate design unit, but described in §5 below):

4. MODIFIED `test/fixtures/uat/scenarios/platform/platform-login-routing-by-role.yaml`
   — `platform_admin_lands_on_workspace_root` branch updated

No Ecto schema, no gen_statem, no migration — this design doc accordingly has no "DB
tables/columns" or "cross-module Elixir dependency" section beyond noting the existing
API contract this page consumes is unchanged.

## 1. `PlatformDashboardPage.tsx`

### 1.1 Module shape

Default-exported function component, no props (matches `TenantDashboardPage`'s and
`HealthDashboardPage`'s own shape — route-level page component, reads auth/session from
context, not from router props).

```
export default function PlatformDashboardPage(): JSX.Element
```

### 1.2 Imports (contract, not implementation)

- `useAuth` from `@/auth/AuthContext` — for `session.roles` (self-gating; see §1.4).
  This is the ONLY session/auth-related hook used. **`useTenantContext()` from
  `@/auth/useTenantContext` must NOT be imported anywhere in this file** — this is a
  literal, checkable constraint (AC1), not just a style preference; TEST-DESIGNER's test
  can assert this by static import-scan or by asserting no tenant-context provider is
  required for the component to render in test.
- `useQuery` from `@tanstack/react-query` — for the tenant-count tile.
- `tenantsApi` from `@/api/tenants` — existing module, existing `list()` function,
  no changes to `web/src/api/tenants.ts` in this requirement.
- `queryKeys` from `@/api/queryKeys` — reuse `queryKeys.admin.tenants(filters)`
  (already exists, used by `TenantsPage.tsx`; see design §1.3 for the exact call).
- `QueryStateBoundary` from `@/components/ui/QueryStateBoundary` — existing
  loading/error boundary pattern already used by `TenantDashboardPage`/`TenantsPage`;
  the `no query without a QueryStateBoundary` guard (frontend guide §3) applies to the
  tenant-count query.
- `classifyError` / `RendererState` from `@/utils/classifyError` — same
  loading/error/success derivation pattern as the two existing dashboards.
- `Link` from `react-router-dom` — for the quick-links section (router `<Link>`, not
  a bare `<a>`, matching `TenantsPage.tsx`'s "+ Add Tenant" link precedent).
- `Navigate` from `react-router-dom` — for the not-authorized self-gate (matches
  `TenantsPage.tsx` / `HealthDashboardPage.tsx` precedent, §1.4).

### 1.3 Data: tenant-count tile

Single query, no new API surface. Query shape (signature/config, not a call site):

| Aspect | Value |
|---|---|
| Hook | `useQuery<TenantListResponse, ApiError>` |
| `queryKey` | `queryKeys.admin.tenants({})` — same key helper `TenantsPage.tsx` uses, called with an empty filter object (see Open Q1 on whether an empty/no-args call returns an accurate platform-wide `total`) |
| `queryFn` source | `tenantsApi.list`, invoked with no filter params — an existing zero-argument-compatible call, not a new function; the design does not introduce a new fetcher |
| Return type | `TenantListResponse` (existing, `web/src/api/tenants.ts`) |
| Error type | `ApiError` (existing) |

- Response shape: existing `TenantListResponse` (`web/src/api/tenants.ts`) —
  `{ items: Tenant[]; total: number; limit: number; offset: number }`.
- Rendered value: `data?.total` (do not derive count from `items.length`, which is
  page-limited — `total` is the actual platform-wide count per the existing contract
  `TenantsPage.tsx` already relies on for its own pagination).
- Render states, mirroring `TenantDashboardPage`'s `rendererState` pattern:
  - `isLoading` → `QueryStateBoundary` loading skeleton (reuse existing pattern; a
    local `SkeletonBox`-equivalent is acceptable, or share `TenantDashboardPage`'s —
    implementation's call, not a design constraint)
  - `isError` → `classifyError(error)` fed into `QueryStateBoundary`
  - success → tile renders `data.total`
- Tile markup contract (AC2):
  - Wrapper `data-testid="tile-tenant-count"`
  - Numeric value rendered as text content inside that element (or a nested node under
    it) equal to `String(total)` — TEST-DESIGNER's test mocks `/api/v1/tenants` and
    asserts the rendered text matches the mocked `total`.

### 1.4 Self-gating (AC3)

Gating rule, mirroring `TenantsPage.tsx` line 69 / `HealthDashboardPage.tsx` line 30-35
precedent — same pattern, PLATFORM_ADMIN-only page, redirect-based gate (not a
"not authorized" inline message — the two existing precedents both use
`<Navigate replace />`, so this page follows the SAME precedent for consistency rather
than inventing a third gating idiom), stated declaratively:

| Aspect | Value |
|---|---|
| Input | `session.roles` (from `useAuth()`, type `AuthContextValue['session']`) |
| Predicate | `isPlatformAdmin` := `session?.roles` contains `'PLATFORM_ADMIN'`; absent session ⇒ `false` |
| Consequence when predicate is `false` | component's render output is a redirect element targeting `/instances`, replacing history (not pushing) |
| Consequence when predicate is `true` | component proceeds to render its normal content (§1.5–1.6) |
| Hook-ordering constraint | `useAuth()` and the `useQuery` call of §1.3 are both invoked unconditionally, before the predicate is evaluated for gating purposes — same ordering `HealthDashboardPage.tsx` already uses for its own `useAuth()` + `useAdminHealthSnapshot()` pair ahead of its own gate |

- The redirect element itself, and the ordering constraint above, are the full
  specification of this rule — FRONTEND-DEV derives the exact statement form (early
  `if`/return vs. other equivalent control flow) at implementation time.
- Redirect target: `/instances` — chosen for consistency with both existing
  precedents (`TenantsPage.tsx`, `HealthDashboardPage.tsx`), which both redirect a
  non-PLATFORM_ADMIN to `/instances` rather than `/`. This is an explicit design
  decision, not a guess — see Open Q2 for the one edge this raises.
- AC3's test: render with a session whose `roles` is `['PROCESS_OPERATOR']` (or similar
  non-PLATFORM_ADMIN role) and assert `platform-dashboard-heading` /
  `tile-tenant-count` / `platform-quick-links` are NOT present (a `<Navigate>` renders
  no DOM in a plain render, or — in a router-mounted test — assert the resulting
  location is `/instances`, matching whichever pattern this codebase's existing
  `TenantsPage.tsx` test already uses for its own equivalent assertion; TEST-DESIGNER
  should read that existing test file for the established assertion idiom rather than
  invent a new one).

### 1.5 Heading (AC1)

```
<h1 data-testid="platform-dashboard-heading">Platform Overview</h1>
```

- Fixed string literal, never interpolated from any tenant/session field.
- No `tenantDisplayName`, no `isUnknown` banner, no "Tenant name could not be loaded"
  string, no "your workspace" copy anywhere in this file — this is a literal
  affirmative constraint TEST-DESIGNER's test asserts as an absence-check across the
  full rendered output (`queryByText`/`container.textContent` scan for those exact
  substrings), matching AC1's wording exactly.

### 1.6 Quick-links section (part of the 8 ACs via the requirement's scope text, not
a separately numbered AC, but load-bearing for AC1/AC3's "platform-wide, non-tenant
content only" framing)

```
<nav data-testid="platform-quick-links">
  <Link to="/admin/tenants">Tenants</Link>
  <Link to="/admin/services">Services</Link>
  <Link to="/admin/health">Health</Link>
  <Link to="/admin/metrics">Metrics</Link>
  <Link to="/admin/users">Users</Link>
</nav>
```

- Section heading text: "Platform Admin Links" (per requirement text verbatim), e.g. a
  sibling `<h2>` or `<div>` label above the `<nav>` — exact markup/copy for the label
  itself is an implementation choice, the FIVE `<Link>` targets and their `to=` values
  are NOT (they must be exactly these five existing, already-built, already-gated
  routes — no new route content, no duplicate logic, per the requirement's explicit
  "OUT OF SCOPE" list).
- These five paths already exist unchanged in `router.tsx` (see §2) and are already
  independently self-gated to PLATFORM_ADMIN by their own page components
  (`TenantsPage.tsx`, `ServicesPage.tsx`, `HealthDashboardPage.tsx`, `MetricsPage.tsx`,
  `UsersPage.tsx`) — this page does not duplicate or re-verify that gating, it only
  links to them.

### 1.7 Structural outline (hooks, gating rule, markup contract — not an executable body)

Hooks called, unconditionally, in this order:

| Order | Hook | Input | Output used |
|---|---|---|---|
| 1 | `useAuth()` | — | `session: AuthContextValue['session']` |
| 2 | `useQuery<TenantListResponse, ApiError>` (§1.3 config) | `queryKey`, `queryFn` per §1.3 | `tenantsQuery: { data, isLoading, isError, error, refetch }` |

Derived values (declarative, not statement order):

| Name | Type | Derivation |
|---|---|---|
| `isPlatformAdmin` | `boolean` | per §1.4's predicate |
| `rendererState` | `RendererState` | `'loading'` while `tenantsQuery.isLoading`; `classifyError(tenantsQuery.error)` while `tenantsQuery.isError`; otherwise `'success'` — same three-way derivation `TenantDashboardPage` already uses |

Gating rule: per §1.4 — when `isPlatformAdmin` is `false`, the component's output is the
`/instances` redirect element and none of the markup below renders.

Render output when `isPlatformAdmin` is `true` (markup contract — structural literals
under direct test, already isolated in §1.5/§1.6, composed here only as an outline of
containment, not a JSX tree to paste):

- Root container
  - Heading element per §1.5 (`data-testid="platform-dashboard-heading"`, fixed text)
  - `QueryStateBoundary` wrapping the tenant-count tile
    - `state` prop: `rendererState`
    - retry affordance: wired to `tenantsQuery.refetch` (exact prop/handler form is
      implementation's call — `QueryStateBoundary`'s existing `onRetry` contract already
      takes a no-arg callback per its own existing type, same as
      `TenantDashboardPage`'s usage)
    - child: tile element per §1.3's markup contract (`data-testid="tile-tenant-count"`,
      text content = `String(tenantsQuery.data?.total)`)
  - Quick-links `<nav>` per §1.6 (`data-testid="platform-quick-links"`, five `<Link>`
    entries with the exact `to=` values listed there)

## 2. `router.tsx` diff shape (AC4)

**Addition only** — one new line inside the existing authenticated `children` array
(same array `TenantDashboardPage`'s two entries live in, so the new route inherits the
same `ProtectedRoute`/`AppShell`/`ErrorBoundary` wrapper — no new top-level route tree
needed since self-gating happens inside the page component per §1.4, matching how
`admin/tenants` etc. are already unguarded at the router level):

```
import PlatformDashboardPage from '@/pages/dashboard/PlatformDashboardPage'   // new import

children: [
  { index: true, element: <TenantDashboardPage /> },       // UNCHANGED
  { path: 'dashboard', element: <TenantDashboardPage /> },  // UNCHANGED
  { path: 'platform-dashboard', element: <PlatformDashboardPage /> },  // NEW
  ...  // every other existing entry unchanged
]
```

- Exact insertion point in the array is not load-bearing (react-router doesn't care
  about order among sibling static paths) — placing it directly after the two
  `TenantDashboardPage` entries is the natural spot for readability, not a requirement.
- **Verification for AC4** ("both old entries are provably unchanged"): the diff
  FRONTEND-DEV produces must show only an added line (plus the added import line) —
  `git diff` on `router.tsx` must contain zero `-` lines touching the `index: true` or
  `path: 'dashboard'` entries. This is a mechanical diff-inspection check
  FRONTEND-DEV/REVIEWER perform directly, not something requiring a new test (existing
  router-level tests, if any, continue to pass unmodified).

## 3. `OidcCallbackPage.tsx` change (AC5)

Current unconditional line (line 72, read in full above): `navigate('/', { replace: true })`.

New behavior — role-conditional, using the SAME `payload` already decoded at line 38
(`decodeTokenPayload(token)`) and already validated non-empty at line 39
(`payload.roles.length === 0` early-return already exists above this point, so by the
time this navigate call is reached, `payload.roles` is guaranteed a non-empty
`string[]`), stated as a decision table (same pattern as §4's precedent table):

| Input | Condition | Navigate target | `replace` |
|---|---|---|---|
| `payload.roles` | contains `'PLATFORM_ADMIN'` | `/platform-dashboard` | `true` |
| `payload.roles` | does not contain `'PLATFORM_ADMIN'` | `/` (unchanged current behavior) | `true` |

- `payload.roles` is `string[]` per `decodeTokenPayload`'s existing return type
  (`@/auth/tokenUtils`); the membership check uses the same `.includes('PLATFORM_ADMIN')`
  idiom already used at `TenantsPage.tsx` line 69 and `HealthDashboardPage.tsx` line 30,
  applied here to the JWT-decoded payload instead of the session object (session doesn't
  exist yet at this point in the callback flow — `setSession` is called on the line
  immediately above, so `payload.roles` is the only available source, not
  `session.roles`).
- Placed at the exact call site of the current line 72 `navigate('/', { replace: true })`
  — after `setSession(...)` completes, same as today. No change to any other line in
  this file (the `window.location.replace('/')` fallback paths on lines 41 and 75 stay
  untouched — those are the invalid-token and callback-exception paths, both explicitly
  out of scope: a PLATFORM_ADMIN whose callback errors never reaches the point where
  role is known, so those two paths correctly stay role-agnostic).

### 3.1 Test shape (AC5 — "two component/integration tests, one per branch")

- Test A: mock `signinRedirectCallback()` to resolve with a token whose decoded
  payload includes `PLATFORM_ADMIN`; assert the test's `navigate` mock/spy was called
  with `('/platform-dashboard', { replace: true })`.
- Test B: same mock shape, decoded payload role e.g. `['PROCESS_OPERATOR']`; assert
  `navigate` was called with `('/', { replace: true })`.
- This file has no existing test file confirmed in this design pass — Open Q3 flags
  this for TEST-DESIGNER to confirm/create
  (`web/src/pages/__tests__/OidcCallbackPage.test.tsx` or sibling location matching
  this codebase's existing test-colocation convention).

## 4. Self-gating precedent cross-reference (ties §1.4 to AC3 explicitly)

| Existing precedent | Guard expression | Redirect target |
|---|---|---|
| `TenantsPage.tsx:69` | `!session?.roles.includes('PLATFORM_ADMIN')` | `/instances` |
| `HealthDashboardPage.tsx:30,33-35` | `!isPlatformAdmin` (derived via `Boolean(session?.roles.includes('PLATFORM_ADMIN'))`) | `/instances` |
| **`PlatformDashboardPage.tsx` (new)** | same `Boolean(session?.roles.includes('PLATFORM_ADMIN'))` derivation | `/instances` (same target, for consistency) |

## 5. UAT scenario update (AC7) — shape only, not this design's file to write

`test/fixtures/uat/scenarios/platform/platform-login-routing-by-role.yaml`'s
`platform_admin_lands_on_workspace_root` branch (lines 47-76 as currently written):

- `name` may stay or be renamed (e.g. to `platform_admin_lands_on_platform_dashboard`)
  — cosmetic, FRONTEND-DEV's call at Step 2b, not a design constraint.
- `expected_outcomes[0].description` and `.verification.detail` must be rewritten to
  assert: route is `/platform-dashboard` (not `/`), rendering `PlatformDashboardPage`
  (not `TenantDashboardPage`), with the tenant-count tile visible and populated from
  the real `/api/v1/tenants` `total`.
- The scenario's top-level `description:` block (lines 23-35) documents "real observed
  behavior" — it must be updated too, since AC7/REQ-369's own text says this
  requirement is what makes the OLD description stale again "in the intended
  direction." Both the two-role-same-destination framing AND the
  `platform_admin_lands_on_workspace_root` branch's own body need the update; the
  `tenant_scoped_role_lands_on_workspace_root` and `unauthenticated_redirects_to_...`
  branches are explicitly UNCHANGED (per REQ-369's own scope text) — do not touch them.
- This file is a UAT fixture, not `lib/letflow/design/`'s concern to draft in full;
  FRONTEND-DEV (or whichever agent owns Step 2b's actual edit) writes the exact new
  YAML text. This design doc's job is only to state which fields change and which
  branches don't, which is done above.

## 6. Acceptance-criteria → design-element map

| AC # | Design element |
|---|---|
| AC1 (heading fixed text, no tenant context/copy) | §1.5, §1.2 (no `useTenantContext` import), §1.7 |
| AC2 (tenant-count tile from `tenantsApi.list().total`) | §1.3, §1.7 |
| AC3 (self-gating for non-PLATFORM_ADMIN) | §1.4, §4 |
| AC4 (router.tsx addition, two existing entries untouched) | §2 |
| AC5 (OidcCallbackPage role-conditional navigate) | §3, §3.1 |
| AC6 (live QA E2E run, screenshot evidence) | Not a design-time element — this is a Step-2b/UAT-RUNNER execution activity against the shipped page; design's job is only to ensure §1/§2/§3 produce a page/route/redirect that CAN be exercised live, which they do (route `/platform-dashboard` reachable, tile sourced from the real endpoint, no mock in the component itself per the guard suite's "no mock HTTP adapters" rule) |
| AC7 (UAT scenario YAML branch update + re-run) | §5 |
| AC8 (close-out states ISS-0700 stays open; "Unknown workspace" gap stays out of scope) | Not a code-design element — a close-out/DOC-UPDATER-time statement. Flagged here so CODE-DESIGN-VALIDATOR/FRONTEND-DEV don't lose track of it: this requirement's Step 6 (DOC-UPDATER) and Step Final PR description must explicitly say ISS-0700 remains `open` and name the "Unknown workspace" banner gap as separately unresolved, per the requirement text's own OUT-OF-SCOPE section. No file changes are attributed to this AC beyond that stated close-out text. |

## 7. Invariants

- `PlatformDashboardPage.tsx` never imports `@/auth/useTenantContext`.
- `PlatformDashboardPage.tsx` never renders any of: `tenantDisplayName`,
  `"your workspace"`, `"Tenant name could not be loaded"`, `"Unknown workspace"`.
- `router.tsx`'s pre-existing `{ index: true }` and `{ path: 'dashboard' }` entries are
  byte-identical before/after this change.
- `OidcCallbackPage.tsx`'s two `window.location.replace('/')` fallback paths (invalid
  token, callback exception) are untouched — only the post-`setSession` success-path
  `navigate(...)` call becomes role-conditional.
- No new backend endpoint, no change to `web/src/api/tenants.ts`.
- Guard-suite compliance: the tenant-count query goes through `useQuery` +
  `QueryStateBoundary` (no bare query), uses `queryKeys.admin.tenants(...)` (no inline
  query key), and issues no direct `fetch`/`axios` call (goes through `tenantsApi` →
  `client.ts`, per existing pattern).

## 8. Cross-module dependencies

- `web/src/auth/AuthContext.tsx` (`useAuth`, `AuthContextValue.session.roles`) — read
  only, no change.
- `web/src/auth/tokenUtils.ts` (`decodeTokenPayload`) — read only, no change; return
  shape (`{ roles: string[]; ... }`) already assumed by `OidcCallbackPage.tsx`'s
  existing lines 38-39.
- `web/src/api/tenants.ts` (`tenantsApi.list`, `TenantListResponse`) — read only, no
  change.
- `web/src/api/queryKeys.ts` (`queryKeys.admin.tenants`) — read only, no change.
- `web/src/components/ui/QueryStateBoundary.tsx` — read only, no change.
- `web/src/components/layout/AppShell.tsx` (`NAV_ITEMS`) — NOT modified by this
  requirement (the requirement text is explicit that the five linked `/admin/*` routes
  are "already gated to PLATFORM_ADMIN in AppShell.tsx's NAV_ITEMS" — this requirement
  adds a new nav destination `/platform-dashboard` is NOT added to `AppShell`'s own nav
  by this design; see Open Q4).

## 9. Open questions (not silently resolved)

1. **`queryKeys.admin.tenants(filters)` call shape for a full-list/count-only fetch.**
   `TenantsPage.tsx` always calls it with `{ search, limit, offset }`. This design
   proposes calling `tenantsApi.list()` with no params (or `{}`) purely to read
   `.total`, using `queryKeys.admin.tenants({})` as the query key. If the backend's
   `/api/v1/tenants` requires explicit `limit`/`offset` to return a correct `total`
   (vs. defaulting server-side), FRONTEND-DEV should verify against the real endpoint
   during Step 2b — this design assumes the no-params call still returns an accurate
   `total` for the full platform, matching `TenantListResponse.total`'s documented
   meaning, but that assumption is unverified against the live API in this design pass.

2. **Redirect target `/instances` for a non-PLATFORM_ADMIN hitting `/platform-dashboard`
   directly.** This matches the two existing precedents exactly, but neither precedent
   explains WHY `/instances` specifically (vs. `/` or `/dashboard`) was chosen as the
   catch-all redirect for a disallowed platform-admin-only page. This design keeps that
   precedent rather than inventing a different target, but flags that the "why
   `/instances`" reasoning itself is unrecorded anywhere in this codebase's history.

3. **`OidcCallbackPage.tsx` test file location/existence.** This design assumes a test
   file will be created or extended for AC5's two navigate-branch tests, but did not
   find (and did not exhaustively search for) an existing `OidcCallbackPage` test file
   in this design pass. TEST-DESIGNER should confirm whether one exists at Step 3 and
   extend it, or create one, following this codebase's established colocation
   convention (check sibling `__tests__/` dirs or `*.test.tsx` next to other page
   components first).

4. **`AppShell.tsx` NAV_ITEMS — whether `/platform-dashboard` needs its own nav
   entry.** The requirement text does not ask for one (it only asks for the quick-links
   section INSIDE the new page, and for OidcCallbackPage's redirect to reach it). This
   design deliberately does NOT add a `/platform-dashboard` entry to `AppShell.tsx`'s
   nav, since the requirement's `owned_modules` list does not include `AppShell.tsx`
   and its scope text names only the three files in §0. A PLATFORM_ADMIN who navigates
   away from `/platform-dashboard` has no persistent nav link back to it (other than
   browser back, or re-triggering login). If that is an unwanted UX gap, it is out of
   this requirement's stated scope, not silently added here.
