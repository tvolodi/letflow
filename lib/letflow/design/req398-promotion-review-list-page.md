# Design: REQ-398 — Promotion-review list/queue page + nav entry

**Requirement:** REQ-398 (`docs/requirements.yaml`, search `id: REQ-398`, stage S8,
`depends_on: [REQ-397]`)
**Owner (implementer):** FRONTEND-DEV
**This document produces:** the typed list API client + hook shape, the new page's
component/prop/state shapes, the route + nav-entry wiring (with the explicit
supersession statement REQ-398's AC7 requires), the empty-vs-fetch-failure state
design, and a test-coverage map against all 8 acceptance criteria. **No
implementation code** — no function bodies, no `.tsx`/`.ts` files.

---

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-398 entry in full (title, description, all 8
  acceptance criteria, `depends_on: [REQ-397]`), and REQ-397's entry (`status: done`,
  its description items 1–5 and OUT OF SCOPE section) — confirms REQ-397 already
  shipped and this design's API-shape assumptions must match the real, live route,
  not REQ-397's own design doc's proposal (checked both, they agree — see §1).
- `lib/letflow/design/req397-promotion-review-list-route.md` (full read) — REQ-397's
  own design: cursor pagination (`page_size`/`cursor` query params, `{"items":
  [...], "next_cursor": ...}` envelope), `status` filter as a single comma-separated
  query param (one or more of the six enum values), `def_id`/`def_type` exact-match
  filters, and the exact 7-key response-item allowlist (§4.5 of that doc): `id`,
  `status`, `def_type`, `def_id`, `requested_by`, `inserted_at`, `updated_at`.
- `lib/letflow/routers/promotions.ex` (`handle_list_reviews/1`,
  `render_list_reviews/2`, `parse_status_filter_param/1`,
  `promotion_review_list_item_map/1`, lines 911–1030, read directly, not assumed) —
  confirms the live route matches its own design doc exactly: `GET /` (mounted
  `GET /api/v1/promotions`), query params `status` (comma-separated), `def_id`,
  `def_type`, `page_size`, `cursor`; response `{"items": [<7-key map>], "next_cursor":
  string | null}`; PLATFORM_ADMIN-only (`:Unknown` policy, `Deny403` otherwise); an
  unrecognised `status` token is rejected `400`, naming the allowed set.
- `docs/issues/ISS-0734.yaml` (full read) — the issue this requirement (and REQ-397)
  were filed from. `fix_direction` names two separable pieces: piece 1 (the
  review-queue/list screen — REQ-397 + REQ-398, this requirement) and piece 2
  (whether a submit-time conflict refusal should be durably recorded at all —
  explicitly undecided, tracked separately). REQ-398's own AC8 requires this design
  to carry piece 2's open status forward explicitly (see §8).
- `lib/letflow/design/iss0730-promotion-review-page-routing.md` (full read) — the
  earlier fix that built the existing detail route/page. §1 ("Decision: no nav entry,
  no contextual link — direct URL only") gave two reasons, both now stale: "no list
  endpoint exists" (REQ-397 closed this) and "would 404 or need a placeholder list
  page nobody asked for" (this requirement builds the real page, not a placeholder).
  §3.1's client-side PLATFORM_ADMIN redirect pattern and §3.2's
  `QueryStateBoundary`/`classifyError` state table are the two patterns this design
  reuses verbatim (see §5, §6).
- `web/src/pages/definitions/PromotionReviewPage.tsx` (full read, the real,
  already-merged implementation of ISS-0730's design) — confirms the redirect is
  exactly `if (!isPlatformAdmin) return <Navigate to="/instances" replace />`,
  computed from `Boolean(session?.roles.includes('PLATFORM_ADMIN'))`, evaluated
  **after** all hooks have already run (rules-of-hooks — the early return sits below
  every `useQuery`/`useMutation`/`useMemo` call, never above one).
- `web/src/api/promotions.ts` (full read) — existing typed-client convention: a
  `promotionsApi` object of arrow functions, one exported request/response
  `interface` per route, a documented `Raw*`-to-public adapter only where the wire
  shape and the desired shape diverge (this requirement's list route does **not**
  need one — see §2.2).
- `web/src/hooks/usePromotions.ts` (full read) — existing hook convention: one
  `useQuery`/`useMutation` per route, `useTenantScopedQueryKeys().promotions` for
  cache keys, no manual `tenantId` threading.
- `web/src/api/queryKeys.ts` (`promotions:` block, lines 172–175) and
  `web/src/api/useTenantScopedQueryKeys.ts` (`promotions:` block) — today expose only
  `all`/`context`; this design adds `list` to both, following the `dlq.list`/
  `admin.audit` sibling pattern (`[...promotions.all(tenantId), 'list', filters ??
  {}]`).
- `web/src/pages/admin/AuditLogPage.tsx` (full read) — the closest existing
  precedent for a cursor-paginated, filterable, PLATFORM_ADMIN-gated list page:
  filter `useState`s that reset `cursorStack` on change, `classifyError`/
  `QueryStateBoundary` composition, an inline "no results" message rendered
  **inside** `QueryStateBoundary`'s `success` children (not a distinct
  `RendererState`), and `PaginationControls` fed by `hasNextPage: Boolean(nextCursor)`
  since `totalItems` is unknown under cursor pagination. This design's page follows
  the same shape (§4, §6).
- `web/src/components/ui/QueryStateBoundary.tsx` and `web/src/utils/classifyError.ts`
  (both full read) — confirms `RendererState` is a **closed union**
  (`'loading' | 'success' | 'fetch-failure' | 'permission-denied' | 'stale-version' |
  'rate-limit'`) with no `'empty'` member; `QueryStateBoundary`'s `switch` is
  exhaustive (`const _exhaustive: never = state`), so an empty-result state cannot be
  a new `RendererState` value without touching that shared component, which is out of
  this requirement's scope. Empty-vs-fetch-failure must therefore be a page-level
  render decision inside the `'success'` branch, exactly as `AuditLogPage.tsx`
  already does it (§6).
- `web/src/components/ui/PaginationControls.tsx` (full read) — `page`/`pageSize`/
  `totalItems: null`/`hasNextPage`/`onPageChange`/`onPageSizeChange` props; confirmed
  cursor-pagination-mode usage (`totalItems: null`) is exactly `AuditLogPage.tsx`'s
  own usage, reused unchanged.
- `web/src/types/api.ts` (`CursorPage<T>` interface, lines 14–18) — `{ items: T[];
  next_cursor: string | null; has_more: boolean }`. Note `has_more` has **no**
  backend source on this route (REQ-397's envelope is exactly `{items, next_cursor}`,
  §4.5 of its design) — same situation `auditApi.list` already handles by deriving
  `has_more: Boolean(next_cursor)` client-side (§2.2 follows this unchanged).
- `web/src/router.tsx` (full read) — confirmed the only existing promotion-related
  entry is `definitions/:id/promotions/:reviewId` (line 62); import-block and
  `children`-array ordering convention (grouped by feature, inline comments cite the
  owning `REQ-NNN`).
- `web/src/components/layout/AppShell.tsx` (full read) — `NAV_ITEMS: NavItem[]`
  (lines 20–65), each entry `{ to, label, roles }`. Confirms a directly-applicable
  precedent for "reversing an earlier no-nav-entry decision": the REQ-381 entry
  (line 54–60) has an inline comment stating exactly this move for
  `/solution-packs`, citing `PromotionReviewPage.tsx`'s own no-nav-entry choice as
  the contrast case this design must now supersede for a different route.
- `docs/agents/instructions/security-invariants.md` — this requirement adds no new
  backend route and reads no new tenant-scoped data path beyond what REQ-397's own
  route already exposes and was already SECURITY-REVIEWER-approved for (REQ-397 AC8).
  No new SECURITY-REVIEWER gate is triggered by this requirement on its own — noted
  explicitly so REVIEWER doesn't need to re-derive this.
- `docs/anti-patterns.md` — no directly-applicable entry found for this change.

---

## 1. Scope boundary

Four files change, one file is new:

1. **`web/src/api/promotions.ts`** — add a typed `list` function + two new exported
   interfaces (§2).
2. **`web/src/hooks/usePromotions.ts`** — add `usePromotionReviewList` (§3).
3. **New file: `web/src/pages/promotions/PromotionReviewListPage.tsx`** — the routed
   list page (§4–§6).
4. **`web/src/router.tsx`** — one import, one route entry (§7.1).
5. **`web/src/components/layout/AppShell.tsx`** — one new `NAV_ITEMS` entry (§7.2),
   with the explicit ISS-0730 §1 supersession statement (§8).

Also, two small additive changes to shared query-key plumbing, following the
existing `dlq.list`/`admin.audit` pattern exactly (no new pattern introduced):

6. **`web/src/api/queryKeys.ts`** — add `promotions.list` (§3.2).
7. **`web/src/api/useTenantScopedQueryKeys.ts`** — bind `promotions.list` to the
   active tenant id (§3.2).

**Explicitly OUT OF SCOPE** (restated from REQ-398's own text so FRONTEND-DEV
doesn't second-guess it): the backend endpoint itself (REQ-397, already done); any
GUI flow for *creating* a new promotion; `ConflictRejectionAlert.tsx`
reshaping/wiring; a dedicated "refused submission" row or filter value (no
`promotion_reviews` row is ever created for a submit-time-refused submission today —
this page can only ever list what REQ-397's endpoint returns, see §8); any change to
`PromotionReviewPage.tsx`, `usePromotionContext`, or the three existing mutation
hooks (§0's read of `usePromotions.ts` confirms they are untouched).

## 2. `web/src/api/promotions.ts` additions

### 2.1 New exported types

```
ReviewStatus            ← already exists (line 54), reused unchanged, no new enum

PromotionReviewListFilters:
  status?: ReviewStatus                  // single value only — see §5.2's decision
  def_id?: string
  def_type?: string
  cursor?: string
  page_size?: number

PromotionReviewListItem:
  id: string              // the review's own id — the :reviewId path param (§7.1)
  status: ReviewStatus
  def_type: string
  def_id: string           // the :id path param (§7.1) — NOT a UUID, see REQ-397 §3.3
  requested_by: string
  inserted_at: string       // ISO8601, per iso8601/1 (REQ-397 §4.5)
  updated_at: string        // ISO8601
```

`PromotionReviewListItem`'s seven fields are a **direct**, unadapted match to
`promotion_review_list_item_map/1`'s live 7-key response allowlist (§0) — unlike
`getContext`'s `RawPromotionContext` → `PromotionContext` adapter (ISS-0731), this
route needs no field-renaming/reshaping step, because REQ-397's own AC5 named these
exact field names and the router confirms them verbatim. No `Raw*` interface, no
adapter function.

### 2.2 New client function

```
promotionsApi.list: (filters: PromotionReviewListFilters) => Promise<CursorPage<PromotionReviewListItem>>
```

Behavior, in prose (mirrors `auditApi.list`'s shape in §0 exactly): calls
`client.get<{ items: PromotionReviewListItem[]; next_cursor: string | null }>(
'/api/v1/promotions', { status: filters.status, def_id: filters.def_id, def_type:
filters.def_type, cursor: filters.cursor, page_size: filters.page_size ?
String(filters.page_size) : undefined })`, then returns `{ items: response.items,
next_cursor: response.next_cursor, has_more: Boolean(response.next_cursor) }` —
`has_more` is client-derived, not a wire field (§0's `CursorPage<T>` note). No field
renaming needed inside `items` (§2.1). Satisfies AC1 ("gains a typed list client...
matching this codebase's existing API-client/hook conventions").

`client.get<T>(path, params?)` already strips `undefined` query values before
building the query string (existing `client.ts` behavior, unchanged) — an absent
filter is simply omitted from the request, matching REQ-397's own "empty/absent
param == no filter" convention (§0).

## 3. `web/src/hooks/usePromotions.ts` addition

### 3.1 New hook

```
usePromotionReviewList(filters: PromotionReviewListFilters): UseQueryResult<CursorPage<PromotionReviewListItem>>
```

Behavior: `const promotionKeys = useTenantScopedQueryKeys().promotions;
useQuery({ queryKey: promotionKeys.list(filters), queryFn: () =>
promotionsApi.list(filters) })` — same shape as `usePromotionContext` (§0), no
`enabled` guard needed (unlike `usePromotionContext`'s `enabled: !!reviewId`, this
query has no required path param that could be empty). Satisfies AC1's hook half.

No `refetchInterval` — REQ-398 does not ask for live polling the way `AuditLogPage`
(30s) or `AppShell`'s DLQ badge (15s) do; a manual re-query on filter change (§5) is
what AC3 actually requires. Not adding one is a considered omission, not an
oversight — flagged so a future reader doesn't assume it was forgotten.

### 3.2 Query-key plumbing (two small additive changes, not a new pattern)

`web/src/api/queryKeys.ts`, inside the existing `promotions:` block (§0, lines
172–175), add one sibling to `context`:

```
list: (tenantId: string, filters?: PromotionReviewListFilters) =>
  [...queryKeys.promotions.all(tenantId), 'list', filters ?? {}] as const
```

— byte-for-byte the same shape as `dlq.list`'s own definition (§0).

`web/src/api/useTenantScopedQueryKeys.ts`, inside the existing `promotions:` block,
add:

```
list: queryKeys.promotions.list.bind(null, tenantId)
```

## 4. `web/src/pages/promotions/PromotionReviewListPage.tsx` — new file

### 4.1 Location decision

**New top-level directory `web/src/pages/promotions/`, not nested under
`pages/definitions/`.** REQ-398's own text offers both as options and instructs
"follow this codebase's existing page-location convention for a top-level list ...
whichever is the closer precedent." The two named precedents —
`web/src/pages/admin/AuditLogPage.tsx` and `web/src/pages/tasks/TaskInboxPage.tsx` —
both live in their **own** feature-named top-level directory (`admin/`, `tasks/`),
not nested inside another feature's detail-page folder, even though `AuditLogPage`
is reachable only from `/admin/*` and could have been placed under, say,
`pages/admin/users/`. This list page is not scoped to one definition (a reviewer
browses reviews across every definition, filtering by `def_id` only optionally,
§5.3) — nesting it under `pages/definitions/` would misleadingly imply a
definition-scoped view the way `DefinitionEditorPage.tsx` is. `pages/promotions/`
matches the "own feature, own top-level folder" convention those two precedents
establish.

### 4.2 Top-level shape

- **Default export, no props**: `export default function PromotionReviewListPage():
  React.ReactElement` — same shape as `PromotionReviewPage`/`AuditLogPage` (§0), no
  `PromotionReviewListPageProps` type needed (the route takes no path params).
- `useAuth()` → `{ session }`; `isPlatformAdmin = Boolean(session?.roles.includes(
  'PLATFORM_ADMIN'))` — identical to `PromotionReviewPage.tsx`'s own line (§0).
- `useTenantScopedQueryKeys()` — not needed directly in the page body (the hook
  itself resolves it, §3.1), listed here only to note the page does **not**
  duplicate that resolution.

### 4.3 Local component state (not exported types — page-internal only)

```
statusFilter: ReviewStatus | ''       // '' = "All statuses" (no filter, §5.2)
cursorStack: string[]                  // page-history stack, mirrors AuditLogPage.tsx
pageSize: number                       // one of 25 | 50 | 100, default 25
```

`defIdFilter`/`defTypeFilter` are **not** part of this page's local state — REQ-398's
AC3 names only a *status* filter control as required; `def_id`/`def_type` filtering
exists in the backend (REQ-397) and in `PromotionReviewListFilters` (§2.1) for a
future requirement to surface if needed, but this page does not render a `def_id`/
`def_type` input. Stated explicitly as a deliberate scope line, not an omission (see
§9 Open Question 1).

### 4.4 Derived values

```
filters: PromotionReviewListFilters =
  { status: statusFilter || undefined, cursor: cursorStack[cursorStack.length - 1], page_size: pageSize }

state: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

hasResults: boolean = (data?.items.length ?? 0) > 0
nextCursor: string | null | undefined = data?.next_cursor
```

Identical derivation shape to `AuditLogPage.tsx`'s own `rendererState`/`hasResults`/
`nextCursor` (§0).

## 5. Status filter control (AC3)

### 5.1 Control shape

A single `<select>`, one option per `ReviewStatus` value plus a leading "All
statuses" option bound to `''`. Not a multi-select/checkbox group.

### 5.2 Decision: single-value filter, not REQ-397's full comma-separated multi-status capability

**Decision:** `PromotionReviewListFilters.status` is `ReviewStatus | undefined`
(one value), even though the backend route accepts a comma-separated list of one or
more statuses (REQ-397 §4.3). REQ-398's AC3 wording is singular — "the page offers a
status filter control that re-queries with the selected status" (one selected
value) — and the description's item 2 lists only "a status filter control," not a
multi-select one. Building multi-status selection UI is real additional scope
(a checkbox group or multi-select widget, plus comma-joining logic) that no
acceptance criterion asks for. `PromotionReviewListFilters.status`'s type is
intentionally singular to match, not because the backend can't do more — a later
requirement can widen it to `ReviewStatus[]` without a breaking change to this
page's own state shape, since `statusFilter` is already page-local.

### 5.3 Re-query behavior

`onChange` on the `<select>` sets `statusFilter` to the newly selected value and
resets `cursorStack` to `[]` — identical to every filter `onChange` in
`AuditLogPage.tsx` (§0: `setActor(...)`, `setCursorStack([])` paired in every input
handler). `usePromotionReviewList(filters)`'s `queryKey` (`promotionKeys.list(
filters)`) includes `filters` itself, so TanStack Query re-fetches automatically on
any `filters` object identity change — no manual `refetch()` call needed for the
filter-change path (only `PaginationControls`' own page-change handler,
§6.3, manipulates `cursorStack` directly rather than calling `refetch`, same as
`AuditLogPage.tsx`). This satisfies AC3's "query param/request changes when the
filter changes" — the request's `status` query param value changes because
`filters.status` changes, which changes the query key, which triggers a real new
`GET /api/v1/promotions?status=...` request.

## 6. Table, empty state, and pagination (AC2, AC4, AC6)

### 6.1 Columns (AC2)

One `<table>` (native markup, matching `AuditLogPage.tsx`'s own choice over
`DataTable` — no expandable-subrow requirement here either, so either would work,
but native `<table>` keeps this page consistent with the one existing cursor-paginated
admin list page rather than introducing `DataTable` for a fifth time with a
different convention): columns, in order — **Status**, **Definition** (renders
`def_type` and `def_id` together, e.g. as two stacked/adjacent text spans, exact
layout is FRONTEND-DEV's call), **Requested By**, **Requested At** (renders
`inserted_at` via the existing `formatDateTime` helper from `@/i18n/format`, the
same helper `AuditLogPage.tsx` already uses for its own timestamp column, §0). One
row per `PromotionReviewListItem`, `key={item.id}`.

`updated_at` is fetched (§2.1) but not required to be its own column — REQ-398's
description item 2 names "status, def_type/def_id, requested_by, and a timestamp"
(singular "a timestamp"), satisfied by the Requested At column alone. Rendering
`updated_at` as a second column is allowed but not required; not deciding this
either way beyond "at least one timestamp column is mandatory" since it's a
non-functional layout choice with no acceptance criterion attached.

### 6.2 Row → detail-route link (AC4)

Each row wraps in (or contains) a `<Link to={\`/definitions/${item.def_id}/promotions/${item.id}\`}>` — `react-router-dom`'s `Link`, matching the codebase's
existing in-table navigation convention. Per REQ-398's own description item 2: the
route's `:id` segment is the row's own `def_id` (not a separate definition lookup),
and `:reviewId` is the row's own `id` — exactly the param mapping
`PromotionReviewPage.tsx`'s `useParams<{ id: string; reviewId: string }>()` already
expects (§0), so no change to that page or its route pattern is needed.

### 6.3 Pagination

`PaginationControls` (§0), wired identically to `AuditLogPage.tsx`: `page={
cursorStack.length + 1}`, `pageSize={pageSize}`, `totalItems={null}`, `hasNextPage={
Boolean(nextCursor)}`, `onPageChange` pushes/pops `cursorStack` the same way, no
`onPageSizeChange` is required by any AC but may be included (optional, matching
`AuditLogPage.tsx`'s own page-size `<select>`) — FRONTEND-DEV's call, not
acceptance-criteria-bearing either way.

### 6.4 Empty-vs-fetch-failure state (AC6)

**No new `RendererState` value** (§0 — the union is closed/exhaustive in
`QueryStateBoundary.tsx`, changing it is out of this requirement's scope). Instead,
mirror `AuditLogPage.tsx`'s own pattern exactly: inside `QueryStateBoundary`'s
`children` (i.e. only reachable when `state === 'success'`), render a plain message
—  e.g. "No promotion reviews found." — when `!hasResults`, and render the `<table>`
+ `PaginationControls` only when `hasResults` (or always render the table shell with
an empty `<tbody>` plus the message above it — either satisfies AC6, FRONTEND-DEV's
call, since AC6 only requires the empty state be *visibly distinct from* the
fetch-failure state, not that the table disappear entirely).

This structurally guarantees AC6: a `'fetch-failure'` state renders
`QueryStateBoundary`'s `<FetchError onRetry={...} />` (§0's `QueryStateBoundary`
`switch`), which is a completely different component tree than the
`success`-branch's plain-text "no reviews" message — the two states can never be
confused because they come from different branches of `QueryStateBoundary`'s own
exhaustive `switch`, not from an `if/else` this page has to get right on its own.

## 7. Route + nav-entry wiring (AC7)

### 7.1 `web/src/router.tsx`

One new import, grouped with the other `promotions`/`definitions`-adjacent imports
(placed after the `PromotionReviewPage` import, before `DefinitionRollbackPage`, to
keep the promotion-related imports adjacent):

```
import PromotionReviewListPage from '@/pages/promotions/PromotionReviewListPage'
```

One new leaf route entry in the `children` array. Placement: **top-level path
`promotions`**, not nested under `definitions/*` (§4.1's directory decision extends
to the URL — `/promotions`, matching `/definitions`, `/instances`, `/tasks` as a
sibling top-level section, not `/definitions/promotions`). Inserted after the
`definitions/:id/rollback` entry and before the `instances` group, keeping the
`definitions/*` block intact immediately above it and introducing the new
`promotions` top-level section right after, with an inline comment citing REQ-398:

```
{ path: 'promotions', element: <PromotionReviewListPage /> },
```

The existing `definitions/:id/promotions/:reviewId` entry is unchanged — this is an
**additional** route, not a replacement.

### 7.2 `web/src/components/layout/AppShell.tsx`

One new `NAV_ITEMS` entry, `{ to: '/promotions', label: 'Promotion Reviews', roles:
['PLATFORM_ADMIN'] }` — same `roles: ['PLATFORM_ADMIN']`-only class as every other
review/admin-surface entry in the array (`/admin/audit`, `/admin/health`, etc., §0),
consistent with this route's own server-side `:Unknown`/PLATFORM_ADMIN-only
authorization (REQ-397 §5) and this page's own client-side redirect (§7.3). Placed
near `/definitions` (the nearest related existing entry) for discoverability,
exact array position is FRONTEND-DEV's call — `visibleNav`'s role-filter behavior
(§0) doesn't depend on array order.

### 7.3 Redirect for non-PLATFORM_ADMIN sessions (AC5)

Identical pattern to `PromotionReviewPage.tsx` (§0, verbatim): computed after every
hook call (`useAuth`, `usePromotionReviewList`, any `useState`/`useMemo`) —

```
if (!isPlatformAdmin) {
  return <Navigate to="/instances" replace />
}
```

No new redirect target, no new gating mechanism — this is the same
`AuditLogPage.tsx`/`PromotionReviewPage.tsx` client-side check already established
by ISS-0730 §3.1, reused unchanged. (A non-PLATFORM_ADMIN caller who somehow issues
the underlying `GET /api/v1/promotions` request directly still gets the server-side
`Deny403` REQ-397 §5 already enforces — this client-side redirect is UX-only, not
the security boundary, exactly as ISS-0730's own design states for the detail page.)

## 8. Supersession of ISS-0730 §1 and the ISS-0734 piece-2 cross-reference (AC7, AC8)

**This design explicitly supersedes `lib/letflow/design/
iss0730-promotion-review-page-routing.md` §1's "Decision: no nav entry, no
contextual link — direct URL only."** That decision's own stated rationale was two
reasons, both now resolved:

1. *"No list endpoint exists... so a static nav entry would 404 or need a
   placeholder list page nobody asked for."* — REQ-397 (done, §0) built the list
   endpoint; this requirement builds the real page it points to, not a placeholder.
2. *"`PromoteResult` carries no `review_id`... contextual link... out of scope."* —
   unaffected either way: this requirement adds a **global nav entry** to a list
   page, not a contextual per-definition link, so ISS-0730 §1's second reason was
   never about this kind of entry point and doesn't need to be revisited.

ISS-0730 §1 itself called this "a closed decision, not an open question" **at the
time it was written** — this document is the explicit re-decision REQ-398's own AC7
requires, made because the fact that made it closed (no list endpoint) no longer
holds, not a silent second-guess. `AppShell.tsx`'s own REQ-381 comment (§0) already
establishes the precedent for stating this kind of supersession inline at the call
site — this design's §7.2 change should carry an equivalent inline comment at
implementation time, citing REQ-398 and this document.

**ISS-0734 fix_direction piece 2 remains open and out of this requirement's scope.**
ISS-0734 named two separable pieces: piece 1 (the review-queue/list screen — REQ-397
+ REQ-398, both now done once this requirement lands) and piece 2 (whether a
submit-time conflict refusal should be durably recorded at all — no
`promotion_reviews` row, or any other row, is ever created for a submit-time
conflict refusal today; see ISS-0734's own description item 1 and REQ-397's OUT OF
SCOPE section, both cited in §0). This page can only ever render what REQ-397's
endpoint returns, which is exactly zero rows for a refused-at-submit-time
proposal — **this is expected, not a bug this requirement introduces or must fix.**
Per REQ-398's AC8, FRONTEND-DEV must carry this forward as a code comment at the new
page's top (mirroring `PromotionReviewPage.tsx`'s own header-comment style, §0),
e.g.: *"This list can only show reviews that have a `promotion_reviews` row.
Submit-time conflict refusals never create one (ISS-0734 fix_direction piece 2 —
undecided, out of REQ-398's scope) and so never appear here; that absence is not a
bug."* The exact wording is FRONTEND-DEV's call; the cross-reference to ISS-0734
piece 2 and the "not a bug" framing are both required content, not optional.

## 9. Acceptance-criteria traceability

| # | REQ-398 acceptance criterion | Design section(s) |
|---|---|---|
| AC1 | Typed list client + hook, matching existing conventions | §2 (client), §3 (hook) |
| AC2 | List page renders rows (status, def_type/def_id, requested_by, timestamp), 2+-row test | §4 (page shape), §6.1 (columns) |
| AC3 | Status filter control re-queries on change | §5 (control shape, decision, re-query mechanics) |
| AC4 | Each row links to the existing detail route with correct ids | §6.2 |
| AC5 | Non-PLATFORM_ADMIN redirected the same way as `PromotionReviewPage.tsx` | §7.3 |
| AC6 | Empty result set renders a distinct plain state, not fetch-failure | §6.4 |
| AC7 | Nav entry reaches the new route; design states supersession of ISS-0730 §1 and why | §7.1 (route), §7.2 (nav entry), §8 (supersession statement) |
| AC8 | Cross-reference: ISS-0734 piece 2 remains open/out of scope | §8 (second half), required page-header comment content specified |

Test-file/AC mapping for TEST-DESIGNER (not written here — design only): AC1–AC7 are
each independently testable against `PromotionReviewListPage.tsx` with
`promotionsApi.list` mocked/stubbed (per AC2's own wording), following
`PromotionReviewPage.tsx`'s existing test file's role-gate/QueryStateBoundary
assertion style for AC5/AC6, and `AuditLogPage.tsx`'s existing filter-changes-the-
query-key test style (if one exists in its test file) for AC3. AC8 is documentation-
only (a code comment), verified by reading the file, not a runtime test.

## 10. Open questions (do not silently resolve — FRONTEND-DEV/REVIEWER to weigh in)

1. **§4.3/§5.2: no `def_id`/`def_type` filter UI, no multi-status selection.**
   Both are real backend capabilities (REQ-397) this page's `filters` type could
   carry but its UI does not expose, because no acceptance criterion names either.
   If a future requirement wants "scope to one definition's reviews" or "select
   multiple statuses at once" from this list page, that is new UI scope, not a gap
   this design silently left unfinished.
2. **Table markup vs. `DataTable` (§6.1).** Chosen for consistency with the one
   existing cursor-paginated admin list page (`AuditLogPage.tsx`) rather than for
   any functional reason — `DataTable` (REQ-274) would also work here since no
   expandable-subrow behavior is needed. Not a settled codebase-wide rule either
   way; flagged so a future reviewer doesn't read this as evidence `DataTable` is
   deprecated for new list pages.
3. **Nav entry exact array position in `NAV_ITEMS` (§7.2).** No acceptance
   criterion constrains ordering; placed near `/definitions` for discoverability,
   FRONTEND-DEV may place it wherever reads best.
