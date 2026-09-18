# ISS-0711 — `TenantListResponse` field-shape mismatch (`total` never existed)

**Modules:** `web/src/api/tenants.ts`, `web/src/pages/dashboard/PlatformDashboardPage.tsx`,
`web/src/pages/admin/tenants/TenantsPage.tsx`, `web/src/api/queryKeys.ts`, and each file's
test doubles.
**Issue:** ISS-0711 / GH-1519 / letflow-queue Q-711
**Related:** REQ-369 (AC6), ISS-0704 (unrelated — confirms `body["count"]` is the real
backend field name from the router/handler side; no overlap in files touched)
**Stage:** S10 (bug fix — frontend/backend contract correction, no backend behavior change)
**Author:** CODE-DESIGNER, 2026-09-18

## Confirmed diagnosis (re-verified against current code, not taken on the issue's word)

Read directly, current `main`:

- `lib/letflow/api/pagination.ex`'s `Page` struct: `@derive {Jason.Encoder, only: [:items,
  :next_cursor, :count]}`, `defstruct [:items, :next_cursor, count: 0]`. `count` is always
  `length(items)`, computed inside `page_response/2` — there is no separate `total` concept
  anywhere in this module, historical or current. There is no `limit`/`offset` field either.
- `lib/letflow/routers/tenants.ex`'s `handle_list/1` builds its response via
  `Pagination.page_response(Enum.map(tenants, &tenant_map/1), next_cursor)` and returns it
  through `Response.ok/2` unchanged — no extra top-level key is added at the router layer.
  Query-side, `handle_list/1` reads `page_size`, `cursor`, `search` from `query_params` —
  it does not read or recognize `limit`/`offset` at all.
- Live QA confirmation quoted in the issue (`{"items":[...],"next_cursor":null,"count":2}`)
  matches this code exactly.
- `web/src/api/tenants.ts`'s `TenantListResponse` declares `{ items, total, limit, offset }`
  — none of `total`, `limit`, `offset` is ever present on a real response. `total` reads as
  `undefined` at runtime; both call sites below default it to `0` (`PlatformDashboardPage`)
  or otherwise treat it as `0` (`TenantsPage`).
- `tenantsApi.list`'s params (`{ search?, limit?, offset? }`) are sent as query-string keys
  `search`, `limit`, `offset`. The backend only recognizes `search`, `page_size`, `cursor`.
  `search` happens to line up (both sides use that literal name) so search filtering works
  today; `limit`/`offset` do not — they are silently dropped by the router (unrecognized
  query params are ignored), so every request always gets the default `page_size = 50`,
  `cursor = nil`. This is confirmed by reading `handle_list/1`'s `with` chain — there is no
  fallback path that maps `limit`/`offset` onto `page_size`/`cursor`.

**Conclusion: the issue's fix_direction (b) is correct and is the only side that needs to
change.** The backend contract (`items` / `next_cursor` / `count`, `page_size` + `cursor`
query params) is internally consistent, matches `Letflow.Api.Pagination`'s design doc, and
needs no change. Every mismatch is on the frontend's declared type and the two real call
sites that consume it.

## Other real call sites of `TenantListResponse` (the "does anything else use `total`"
check)

`grep -rn "TenantListResponse\|tenantsApi\.list" web/src` turns up exactly two production
call sites and two test files, no others:

1. `web/src/pages/dashboard/PlatformDashboardPage.tsx` — the one ISS-0711 names. Reads
   `tenantsQuery.data?.total ?? 0` for the tile (line 61).
2. `web/src/pages/admin/tenants/TenantsPage.tsx` — **not named in the issue's
   `affected_files`, but genuinely broken by the same type/contract mismatch** and must be
   fixed in this same change for consistency (see next section). Reads `data?.total ?? 0`
   (line 74) to drive `PaginationControls`' `totalItems` prop, and constructs
   `listParams = { search, limit: PAGE_SIZE, offset }` (line 46) that `tenantsApi.list`
   sends as ignored `limit`/`offset` query params.
3. `web/src/pages/dashboard/__tests__/PlatformDashboardPage.test.tsx` — mocks
   `TENANT_LIST: TenantListResponse = { items: [], total: 37, limit: 20, offset: 0 }`. This
   is REQ-369's own AC2 test the issue calls out as the coverage gap: it mocks a shape the
   real API never sends, so it could not have caught this bug. Must be rewritten (below).
4. `web/src/pages/admin/tenants/__tests__/TenantsPage.test.tsx` — mocks the same fictional
   `{ items, total: 2, limit: 20, offset: 0 }` shape for its `[TEST]`-badge test (TC-ENV04-08).
   That test only asserts on badge rendering, not on the count/pagination tile, but its fixture
   must still be updated to the real shape so it stays representative and keeps compiling
   once `TenantListResponse` changes (TypeScript would otherwise reject the excess/missing
   fields).

No other file in `web/src` imports `TenantListResponse` or calls `tenantsApi.list`.

## Why `TenantsPage.tsx` must be fixed here too, not deferred

Swapping only `total` → `count` on `TenantListResponse` without touching `TenantsPage.tsx`
would leave it reading a field (`count`) that means something different from what its
pagination math assumes: `count` is `length(items)` **for the current page only** (at most
`page_size` items), never a total across all pages. `TenantsPage.tsx`'s existing
`total > PAGE_SIZE` / `PaginationControls totalItems={total}` logic requires a true
cross-page total, which the real API has never provided and structurally cannot provide
today (S4's tenant-list endpoint is cursor-paginated, not offset/total-paginated — see
`Letflow.Api.Pagination`'s moduledoc). Silently renaming the field to `count` would compile
and "work" only by coincidence while the real tenant count (2, per live QA) stays under
`PAGE_SIZE` (20) — the exact same class of bug as ISS-0711 itself, just latent instead of
visible. This is precisely the "leave other callers silently broken or still reading a field
that never existed" failure mode the task calls out.

The fix: bring `TenantsPage.tsx`'s pagination onto the same cursor-based
`PaginationControls` usage already established elsewhere in this codebase for exactly this
situation — `web/src/pages/admin/AuditLogPage.tsx` (`totalItems={null}`,
`hasNextPage={Boolean(nextCursor)}`, a `cursorStack: string[]` for backward navigation) is
the live precedent, documented in `PaginationControls`' own moduledoc ("neither AuditLogPage
nor InstanceBoardPage can provide a total row count, only a 'does another page exist'
boolean"). `TenantsPage.tsx` joins that same category — it is not a special case.

## Design

### 1. `web/src/api/tenants.ts` — fix the type and the request params

Replace the fictional envelope with the real one, following the same
raw-response/mapped-response split `web/src/api/audit.ts` already uses (`RawAuditPage` →
`CursorPage<AuditEntry>`), since `web/src/types/api.ts`'s existing `CursorPage<T>` shape
(`{ items, next_cursor, has_more }`) does not match this endpoint's real field name
(`count`, not `has_more`) — same reasoning `EntityRecordsPage<T>`'s own doc comment gives
for not reusing `CursorPage<T>` where the real field doesn't match.

```
// New type, replaces the current TenantListResponse body:
interface TenantListPage {
  items: Tenant[]
  next_cursor: string | null
  count: number          // length(items) for the current page only — never a
                          // cross-page total; see design doc.
}
```

- Remove `total: number`, `limit: number`, `offset: number` from the exported type
  entirely — they have never been real fields on this endpoint's response body.
- Keep the exported type name `TenantListResponse` for the mapped/public type (minimizes
  import churn at the two call sites and their tests) but give it this real shape:
  `{ items: Tenant[]; next_cursor: string | null; count: number }`.
- `tenantsApi.list`'s parameter type changes from `{ search?: string; limit?: number;
  offset?: number }` to `{ search?: string; cursor?: string; page_size?: number }`,
  matching `handle_list/1`'s actual recognized query params
  (`lib/letflow/routers/tenants.ex`). Query-string keys sent: `search`, `cursor`,
  `page_size` — same naming convention `auditApi.list` already uses for `cursor`/
  `page_size`.
- `tenantsApi.list`'s return type: `Promise<TenantListResponse>` (the corrected shape
  above). No raw/mapped split is needed for the `items` array itself since `Tenant` already
  matches `tenant_map/1`'s six-key allowlist field-for-field — only the envelope's
  three keys needed correcting.

### 2. `web/src/api/queryKeys.ts` — keep in sync with the new params shape

`queryKeys.admin.tenants`'s `filters` parameter type
(`{ search?: string; limit?: number; offset?: number }`, line 92) must be updated to
`{ search?: string; cursor?: string; page_size?: number }` to match `tenantsApi.list`'s new
parameter type — it is purely a cache-key shape, no behavior beyond what goes into the key
tuple, but leaving it on the old shape would either fail to typecheck against the new call
sites or silently accept a shape nothing sends any more.

### 3. `web/src/pages/dashboard/PlatformDashboardPage.tsx` — read `count`

- Line 61: `String(tenantsQuery.data?.total ?? 0)` → `String(tenantsQuery.data?.count ?? 0)`.
- No other change to this file. `tenantsApi.list()` is still called with no arguments
  (default `page_size`/`cursor`/`search`), which is correct here: this tile only ever
  needs "how many tenants are on this page," and since the tenant list is small in
  practice, page 1's `count` is an accurate enough total for a dashboard tile — same
  judgment call the issue's own `fix_direction` makes explicitly ("more likely correct
  today, since ... the tenant list is small/unpaginated in practice"). If the platform ever
  needs a tile that reflects an exact cross-page total, that is new scope, not this fix —
  flag as an open question below rather than solving it here.

### 4. `web/src/pages/admin/tenants/TenantsPage.tsx` — switch to cursor-based pagination

Following `AuditLogPage.tsx`'s established pattern exactly:

- State: replace `const [offset, setOffset] = useState<number>(0)` with
  `const [cursorStack, setCursorStack] = useState<string[]>([])`. Derive
  `const cursor = cursorStack[cursorStack.length - 1]` (same as `AuditLogPage.tsx`).
- `listParams` becomes `{ search: search || undefined, page_size: PAGE_SIZE, cursor }`
  (drop `limit`/`offset`).
- `handleSearchChange` resets `setCursorStack([])` instead of `setOffset(0)` (same
  "changing the filter restarts pagination" intent, cursor-stack form).
- Drop `const total = data?.total ?? 0` and `const currentPage = Math.floor(offset /
  PAGE_SIZE) + 1`. Replace with `const nextCursor = data?.next_cursor` and
  `const currentPage = cursorStack.length + 1` (1-indexed, matching
  `AuditLogPage.tsx`'s `page={cursorStack.length + 1}`).
- Pagination-controls gating: replace `{total > PAGE_SIZE && (...)}` with a condition that
  does not depend on a total that no longer exists — render `PaginationControls` whenever
  there is more than one page to show, i.e. `{(cursorStack.length > 0 ||
  Boolean(nextCursor)) && (...)}` (mirrors "show controls once there's a previous page or a
  next page available"; on a first, full page with no `next_cursor` and an empty
  `cursorStack`, controls stay hidden exactly as they do today for a short list).
- `PaginationControls` props: `page={currentPage}`, `pageSize={PAGE_SIZE}`,
  `totalItems={null}`, `hasNextPage={Boolean(nextCursor)}`, and an `onPageChange` callback
  of shape `(newPage: number) => void` with the following contract — identical in behavior
  to `AuditLogPage.tsx`'s existing `onPageChange`:

  | Trigger (argument received) | State transition |
  |---|---|
  | `newPage` less than `currentPage` (the Previous button; `PaginationControls` only ever calls this with `page - 1` or `page + 1`) | Pop the last entry off `cursorStack` (go back one page). |
  | `newPage` greater than `currentPage`, and `nextCursor` is present | Push `nextCursor` onto `cursorStack` (go forward one page). |
  | `newPage` greater than `currentPage`, and `nextCursor` is absent | No state change — `PaginationControls` already disables the Next button whenever `hasNextPage` is false, so this case is not reachable through the UI; the callback need not special-case it beyond doing nothing. |

  This is the same trigger/transition contract `AuditLogPage.tsx`'s own `onPageChange`
  already implements — FRONTEND-DEV/ELIXIR-DEV writes the literal closure body from this
  table plus that file's existing implementation, not from any code in this design doc.
- `data.items ?? []` (DataTable's `data` prop) is unaffected — `items`' shape is unchanged.
- No other part of the file (search input, `DataTable` columns, lifecycle mutation,
  confirm dialog) changes.

### 5. Test doubles to update (both, so the type change keeps compiling and both mocked
fixtures reflect a real response shape)

- `web/src/pages/dashboard/__tests__/PlatformDashboardPage.test.tsx`: change
  `TENANT_LIST: TenantListResponse` fixture from `{ items: [], total: 37, limit: 20, offset:
  0 }` to `{ items: [], next_cursor: null, count: 37 }`. Rename TC-REQ369-03's own
  description away from "...mocked `total`" to "...mocked `count`" (it currently says so
  explicitly — line 131/14 both reference `total`) and update the file's own top-of-file
  comment (lines 13-14, "AC2 — tenant-count tile renders the mocked
  tenantsApi.list()/useQuery `total`") to say `count`. Assertion itself
  (`toHaveTextContent('37')`) is unchanged in form — same mocked value, different field
  name driving it, which is exactly the regression coverage ISS-0711 asks for: this test
  now fails if `PlatformDashboardPage.tsx` reads any field the real API doesn't send.
- `web/src/pages/admin/tenants/__tests__/TenantsPage.test.tsx`: change `TENANT_LIST:
  TenantListResponse` fixture from `{ items: [...], total: 2, limit: 20, offset: 0 }` to
  `{ items: [...], next_cursor: null, count: 2 }`. This test's own assertions (TEST badge
  presence) are unaffected by the field rename; only the fixture's shape needs to compile
  against the corrected type.

### 6. New regression test — the exact gap ISS-0711 names

Add one new test case to `PlatformDashboardPage.test.tsx` (or extend TC-REQ369-03,
CODE-DESIGNER leaves the choice to TEST-DESIGNER since both satisfy the same acceptance
gap) that:

- Mocks `tenantsApi`/`useQuery`'s resolved data as the **exact real backend shape**, with no
  `total` key present at all: `{ items: [ /* 2 fixture tenant objects, or any 2 items */ ],
  next_cursor: null, count: 2 }` — a TypeScript object literal that would be a compile
  error today under the old `TenantListResponse` type (missing `total`/`limit`/`offset`),
  which is itself part of the regression signal: this test can only exist once the type is
  corrected.
- Renders `PlatformDashboardPage` and asserts `screen.getByTestId('tile-tenant-count')` has
  text content `'2'` — a real, correctly-shaped mocked count, not the old fictional `37`
  chosen precisely because it was distinguishable from an accidental `0`.
- This closes the exact gap the issue names: REQ-369's original AC2 test mocked `total`
  (a field the real API never sends) and therefore could not detect that the component was
  reading a field that would always be `undefined` against a real response. A test built
  from the real response shape does detect it — swap `count` back out for `total` in
  `PlatformDashboardPage.tsx` locally and this new test fails.

## Cross-module dependencies

- No backend (`lib/letflow/`) file changes. `lib/letflow/api/pagination.ex` and
  `lib/letflow/routers/tenants.ex` are both confirmed correct and unchanged by this design.
- Frontend-only: `web/src/api/tenants.ts`, `web/src/api/queryKeys.ts`,
  `web/src/pages/dashboard/PlatformDashboardPage.tsx`,
  `web/src/pages/admin/tenants/TenantsPage.tsx`, and their two test files.
- No new dependency on `web/src/types/api.ts`'s `CursorPage<T>` — kept as a distinct local
  type per the `EntityRecordsPage<T>` precedent (field-name mismatch: `count` vs
  `has_more`).

## Invariants

- The corrected `TenantListResponse` type must never declare a field the real
  `GET /api/v1/tenants` response does not send (`items`, `next_cursor`, `count` — exactly
  the three keys `Letflow.Api.Pagination.Page`'s `@derive {Jason.Encoder, only: [...]}`
  allowlists). Any future frontend change adding a field to this type must be justified
  against `lib/letflow/api/pagination.ex`'s `Page` struct and `tenant_map/1`'s allowlist,
  not assumed.
- `count` is per-page, never cross-page — no code may treat it as a total tenant count
  across all pages. `PlatformDashboardPage.tsx`'s tile is a deliberate, documented exception
  (page-1 count as a "good enough for a dashboard tile" proxy, not a cross-page total claim)
  — see the open question below for the actual accuracy boundary.
- Every mocked `TenantListResponse`/`TenantListPage` fixture in test code must use the real
  three-key shape (`items`, `next_cursor`, `count`) — never resurrect `total`/`limit`/
  `offset` in a new test fixture.

## Open questions (explicitly unresolved — do not guess)

- **OQ-1:** `PlatformDashboardPage.tsx`'s tile shows page-1 `count`, which is only an exact
  tenant total while the platform has ≤ `default_page_size` (50) tenants (or fewer, if the
  route is ever called with a smaller explicit `page_size`). Today's live QA count is 2, so
  this is not currently wrong, but it will silently under-report once tenant count exceeds
  the page size, with no visual indicator that the number is a floor rather than an exact
  total. Not fixed here (issue's own `fix_direction` scopes the tile fix to "read `count`
  instead of `total`," not to guaranteeing exactness past one page) — flagging so a future
  requirement can decide whether the tile needs an exact aggregate count endpoint, an
  "50+" style display, or is accepted as-is indefinitely.
- **Resolved — `TenantsPage.tsx`'s pagination fix (§4) is bundled into this same change,
  not split into a separate issue.** `web/src/pages/admin/tenants/TenantsPage.tsx`'s fix
  ships in the same PR as `TenantListResponse`'s correction, despite ISS-0711's own
  `affected_files` naming only `PlatformDashboardPage.tsx` and `tenants.ts`.

  The narrower alternative was considered and rejected: keep `TenantListResponse.total` as
  an optional back-compat alias (e.g. `total?: number`, left unpopulated by the real
  backend) so `TenantsPage.tsx` keeps compiling untouched, and defer its pagination
  behavior to a follow-up issue. This was rejected because it reintroduces the exact defect
  class ISS-0711 exists to eliminate — a field on the type that does not correspond to
  anything the real endpoint ever sends, kept alive purely to dodge scope. That is
  indistinguishable in kind from the original bug (`total` was always `undefined` against
  a real response); an optional `total?` would still always resolve to `undefined` and
  still let `TenantsPage.tsx`'s `total > PAGE_SIZE` gate and `PaginationControls
  totalItems={total}` silently misbehave once tenant count exceeds `PAGE_SIZE`, exactly as
  today's real `.total ?? 0` misbehaves — the same bug, just re-hidden behind an
  `?`  instead of fixed.

  Bundling is the only option that removes `total`/`limit`/`offset` from
  `TenantListResponse` cleanly (per this doc's own invariant: the type must never declare a
  field the real response doesn't send) without leaving a real, still-imported call site
  either broken at compile time or silently wrong at runtime. It is accepted as in-scope for
  this fix, not flagged for further confirmation.
