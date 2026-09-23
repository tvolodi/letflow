# Design: REQ-393 — Entity List Query Browser UI

**Owner:** CODE-DESIGNER  
**Status:** READY  
**Requirement:** REQ-393 — Generic, tenant-agnostic entity-list browse screen with filter builder, sort control, and page-size control wired to `POST /entities/query`.  
**Stage:** S8

---

## 1. Component Architecture Decision

### Decision: New component — `EntityListBrowserPage.tsx`

**Rationale:**

`EntityCrudPage.tsx` (REQ-343) is BilimBaga-owned. It carries a compile-time `EXCLUDE_DELETED_FILTERS` constant, a fixed `PAGE_SIZE = 25`, client-side sort via `DataTable`'s internal `SortState`, and no filter builder. Modifying it for REQ-393's requirements would require:

1. Making `EXCLUDE_DELETED_FILTERS` optional (a prop or undefined), which changes existing BilimBaga behaviour under any refactor error.
2. Replacing the DataTable's internal sort with an external sort clause — changing how columns are passed to `DataTable`.
3. Adding a filter builder UI that BilimBaga callers would need to guard with a prop.

All three changes risk a BilimBaga regression. The requirement explicitly states "BilimBaga regression" as out of scope, and the source says this is FRONTEND-DEV's design call. A new component is the clean option.

**New files:**
- `web/src/pages/entities/EntityListBrowserPage.tsx` — top-level page component
- `web/src/components/entities/EntityFilterBuilder.tsx` — filter-row UI (field / operator / value)

**No changes to** `EntityCrudPage.tsx`, `DataTable.tsx`, `FilterBar.tsx`, or `BilimBagaEntityRoute.tsx`.

---

## 2. TypeScript Interface Shapes

These are type shapes only, matching `web/src/types/api.ts` exactly. FRONTEND-DEV must import from `@/types/api` and **must not redeclare** `EntityQueryFilterClause` or `EntityQuerySortClause`.

### 2.1 Existing shared types (already in `web/src/types/api.ts` — import, do not duplicate)

```
EntityQueryFilterClause:
  field: string
  op: 'eq' | 'ne' | 'lt' | 'lte' | 'gt' | 'gte' | 'in' | 'not_in' | 'contains' | 'is_null' | 'is_not_null'
  value?: unknown

EntityQuerySortClause:
  field: string
  dir: 'asc' | 'desc'          ← NOTE: "dir", not "direction"
```

The `dir` field name is the source of truth in `api.ts:352` and must match `POST /entities/query`'s body exactly. Any interface in this feature that names the sort direction field **must use `dir`**.

### 2.2 Component-local state shapes (EntityListBrowserPage internal, not exported)

```
FilterRow (local state shape, not sent to API directly):
  id: string                   ← stable React key
  field: string
  op: EntityQueryFilterClause['op']
  value: string                ← always string in the input; parsed to typed value before API call

SortControl (local state shape):
  field: string | null         ← null = no sort (server returns natural order)
  dir: 'asc' | 'desc'
```

### 2.3 Props

```
EntityListBrowserPageProps:
  entityType: string           ← from useParams(), passed in by the router

EntityFilterBuilderProps:
  fields: EntityFieldDef[]     ← only queried===true fields from the active definition
  rows: FilterRow[]
  onChange: (rows: FilterRow[]) => void
```

`tenantId` is **not a prop** — it is resolved internally via the existing `useTenantScopedQueryKeys()` hook, matching `EntityCrudPage.tsx`'s pattern exactly (INV-1 in the router prohibits caller-supplied tenant ids anyway).

---

## 3. Route / URL Plan

### 3.1 New route

```
path: 'entities/:entityType'
element: <EntityListBrowserPage />
```

Added to `web/src/router.tsx` in the authenticated-shell children array, alongside the existing BilimBaga routes.

### 3.2 Coexistence with BilimBaga

`/admin/bilimbaga/:entityType` (rendered by `BilimBagaEntityRoute` → `EntityCrudPage`) is **unchanged**. The two routes are independent. There is no redirect from one to the other and no shared URL segment. BilimBaga entity types are accessible at both URLs simultaneously — the `/entities/:entityType` screen is the query-browser view; `/admin/bilimbaga/:entityType` is the CRUD view.

### 3.3 Navigation entry point

`EntityListBrowserPage` does not need a nav-menu entry in REQ-393. The E2E spec will navigate directly by URL. A nav entry is a separate requirement.

### 3.4 router.tsx change summary

Single addition to the `children` array in `createBrowserRouter`:
```
{ path: 'entities/:entityType', element: <EntityListBrowserPage /> }
```

One new import line for `EntityListBrowserPage`.

---

## 4. Filter Builder UI

### 4.1 Available fields

On mount, `EntityListBrowserPage` fetches the active definition for `entityType` (same `GET /entities/definitions/active/:name` call `EntityCrudPage` already uses, same TanStack query key). Only fields with `queried === true` are shown in the field-selector dropdown in `EntityFilterBuilder`. Fields with `queried` absent or `false` are excluded — selecting them would produce a `:field_not_allowed` 422, which the E2E spec exercises explicitly using a non-queried field injected into the filter rows directly (bypassing the UI dropdown restriction).

### 4.2 Filter row shape (per row)

| UI element | Width | Notes |
|---|---|---|
| Field `<select>` | ~35% | queried fields only |
| Operator `<select>` | ~25% | operator list filtered by field type (see §4.3) |
| Value `<input type="text">` | ~30% | hidden when op is `is_null` or `is_not_null` |
| Remove button | ~10% | removes this row |

"Add filter" button at bottom of the filter section. Maximum: no limit imposed by this design (the backend accepts any number; if a query grows unwieldy, that is the caller's concern).

### 4.3 Operator list by field type

| Field type | Allowed ops |
|---|---|
| `string`, `localized_text` | `eq`, `ne`, `contains`, `is_null`, `is_not_null` |
| `integer`, `decimal`, `date`, `datetime` | `eq`, `ne`, `lt`, `lte`, `gt`, `gte`, `is_null`, `is_not_null` |
| `boolean` | `eq`, `ne` |
| `enum` | `eq`, `ne`, `in`, `not_in` |
| `json` | `eq`, `is_null`, `is_not_null` |

OPEN QUESTION OQ-1: `in` and `not_in` require a list value. For this REQ, a comma-separated string input parsed into a JSON array is sufficient for the E2E spec. A richer multi-value picker is a later enhancement.

### 4.4 Value coercion before API call

Before building the `filters` array sent to `POST /entities/query`, string values from the input are coerced:
- `boolean` fields: `"true"` → `true`, `"false"` → `false`
- `integer` fields: `parseInt(value, 10)`
- `decimal` fields: `parseFloat(value)`
- `in` / `not_in` ops: value split by comma, each item trimmed and coerced to the field's type
- `is_null` / `is_not_null`: `value` is omitted from the clause (backend expects no `value` key)

Invalid coercions (e.g. `NaN`) should be excluded from the filter array silently at build time — the field input should use `type="text"` with a placeholder hint, and validation is left to server error responses.

### 4.5 "Apply" trigger

The filter + sort + page-size query is **not live** (no debounced auto-fire). The user builds the query and presses an explicit "Search" button. This avoids hammering `POST /entities/query` on every keystroke while building multi-clause filters.

---

## 5. Sort Control

### 5.1 Location

Separate from the filter builder — a compact row above or below the FilterBar section, with two dropdowns: "Sort field" and "Direction".

### 5.2 Shape

```
Sort field: <select>
  options: [{ value: '', label: '(none)' }, ...definition.fields.map(f => ({ value: f.name, label: f.name }))]
  Note: all fields are valid sort targets, not just queried fields — the backend accepts any field as a sort key

Sort direction: <select>
  options: [{ value: 'asc', label: 'Ascending' }, { value: 'desc', label: 'Descending' }]
```

When "Sort field" is `''` (none), no `sort` key is included in the query body. When a field is chosen, the sort array sent to the API is `[{ field: selectedField, dir: selectedDir }]`. Only single-field sort is exposed in this UI; multi-field sort is a later enhancement.

### 5.3 DataTable columns — no client-side sort

All `DataTableColumn` entries passed to `DataTable` in `EntityListBrowserPage` omit the `sortable` prop (defaults to `undefined` → `false`). The DataTable's internal `SortState` will remain at `{ columnId: null, direction: 'asc' }` and `getSortedRowModel()` will return the rows in server-supplied order. This is the correct pattern: server-driven sort must not be re-sorted client-side after fetch.

### 5.4 Pagination interaction with sort

When the sort clause changes and "Search" is pressed, `cursorStack` is reset to `[]` (page 1). This prevents a cursor from a prior sort order being used with a new one, which the backend would reject as `:resume_key_arity_mismatch`.

---

## 6. Page-Size Control

### 6.1 UI element

A `<select>` with predefined options: `[25, 50, 100, 250]`. This avoids the user accidentally triggering `:page_size_too_large` during normal use. The E2E spec injects an oversized value by programmatically submitting a query with `page_size` beyond the server limit, not through the dropdown.

OPEN QUESTION OQ-2: What is the server's `MAX_PAGE_SIZE`? `Letflow.Entities.Query.Cursor` enforces this limit — ELIXIR-DEV must confirm the exact value before FRONTEND-DEV chooses the upper dropdown option. If 250 exceeds `MAX_PAGE_SIZE`, the dropdown must be capped. The E2E spec for this error scenario (AC4) will submit a raw oversized value via direct API call (Playwright `request` fixture) rather than through the UI dropdown.

### 6.2 Error surfacing for `:page_size_too_large` (400)

When `POST /entities/query` returns HTTP 400 with body `"page_size out of range"`, the error is classified as an `ApiError` by the existing `client.ts` error path. The page renders an inline error message below the page-size control:

```
"Page size is too large. Choose a smaller value."
```

This is an inline message adjacent to the control that caused it, not a toast. Toasts are ephemeral and the user needs to see the message while correcting the value.

---

## 7. Error Handling

### 7.1 `:field_not_allowed` (422)

`POST /entities/query` returns HTTP 422 with body `"field is not queryable: <field>"`.

Surfaced as: a red inline error banner in the results area (below the Search button, above the table), displaying the server's message verbatim. This message is visible next to the filter builder where the offending field was entered.

Not a toast — the user needs to see which field to fix before resubmitting.

### 7.2 `:page_size_too_large` (400)

Surfaced as: inline message below the page-size control (see §6.2).

### 7.3 Other query errors (400 / 422 / 404)

Surfaced as: the same red inline error banner, showing the server's message. The complete set of `render_query_error/2` clauses in `entities.ex` produces human-readable strings — they are safe to show verbatim to an admin-level user.

### 7.4 Loading / error state wrapper

`EntityListBrowserPage` uses a `QueryStateBoundary` for the definition fetch (the guard suite forbids queries without one). The records query (`useQuery` for `queryRecords`) is also wrapped. The guard: `web/tests/guards/forbidlist.ts` blocks "no query without a QueryStateBoundary".

---

## 8. Query Key Registration

The guard suite forbids inline query keys. Two new entries must be added to `web/src/api/queryKeys.ts`:

```
queryKeys.entities.browserRecords(tenantId, entityType, { filters, sort, pageSize, cursor })
  key shape: ['tenant', tenantId, 'entities', 'browser', entityType, { filters, sort, pageSize, cursor }]
```

The existing `queryKeys.entities.records(...)` (used by `EntityCrudPage`) is **not reused** for the browser page, to avoid query cache collisions between the two screens (different filter shapes, including the presence/absence of `EXCLUDE_DELETED_FILTERS`).

---

## 9. E2E Spec Structure

**File:** `web/tests/e2e/pipelines/entity-list-query.pipeline.e2e.spec.ts`

**Entity type for spec:** `tag` — the simplest BilimBaga entity (single `name` field, confirmed `queried: true` in the entity definition pack at `priv/packs/bilimbaga/entity_definitions/tag.json`). The spec targets `/entities/tag`.

OPEN QUESTION OQ-3: ELIXIR-DEV / TEST-DESIGNER must confirm that `tag` has at least 2 pages of records provisioned in the test/QA instance (for scenario 2's "page to second page" step). If not, the spec must CREATE sufficient records in a `beforeAll` hook.

OPEN QUESTION OQ-4: Confirm what field on `tag` is NOT queried (i.e., `queried: false` or absent) for use in scenario 3. If `tag` has no non-queried fields, use a different entity type for that scenario (e.g., `category`), or inject a filter for a field name that does not exist on the definition at all.

### Scenario 1 — Filter and verify results

```
navigate to /entities/tag
add filter: field=name, op=contains, value=<known-prefix>
press Search
assert: DataTable rows all have name containing <known-prefix>
assert: row count > 0
```

### Scenario 2 — Server-driven sort, cross-page order

```
navigate to /entities/tag
set sort field=name, direction=asc
press Search
capture first page's last row name value
press Next page (PaginationControls)
capture second page's first row name value
assert: second page's first row name >= first page's last row name (alphabetical order preserved across pages)
```

### Scenario 3 — Filter on non-queryable field → rejection message

```
navigate to /entities/tag
[inject a filter row targeting a non-queried field name — Playwright fills the field input directly or calls entitiesApi.queryRecords via page.evaluate]
press Search
assert: error banner is visible containing "field is not queryable"
```

### Scenario 4 — Page size too large → rejection message

```
navigate to /entities/tag
[submit query with page_size=9999 via Playwright request fixture directly to POST /api/v1/entities/query]
assert: HTTP 400 response body contains "page_size out of range"
[or: interact via UI if OQ-2 reveals the dropdown max can be exceeded via a hidden input]
assert: error message rendered in UI containing "Page size is too large"
```

---

## 10. Acceptance Criteria Traceability

| AC | Design Element |
|---|---|
| Component architecture decision stated | §1: new `EntityListBrowserPage.tsx`, rationale stated |
| FilterClause and SortClause TypeScript shapes specified | §2.1: import from `api.ts`; `dir` field confirmed; §2.2: local state shapes |
| Route/URL plan described | §3: `/entities/:entityType`, one router.tsx addition, BilimBaga coexistence |
| All ACs mapped to design elements | §10 (this table) |
| No implementation code | confirmed — signatures and shapes only throughout |

### REQ-393 requirement-level ACs mapped:

| Requirement AC | Design §|
|---|---|
| (1) Filter builder (field/op/value, driven by EntityDefinition queried:true fields) | §4 |
| (2) Sort control (field+direction) sent as sort array to server | §5 |
| (3) Page-size control surfacing :page_size_too_large 400 as readable message | §6 |
| (4) :field_not_allowed 422 as readable message | §7.1 |
| (5) Playwright spec at web/tests/e2e/pipelines/entity-list-query.pipeline.e2e.spec.ts | §9 |
| Out of scope: Vortex provisioning, REQ-394 authorization, BilimBaga regression | §1 rationale, §3.2 |

---

## 11. Open Questions

| ID | Question | Blocking? | Owner |
|---|---|---|---|
| OQ-1 | `in`/`not_in` value input: comma-separated string is the REQ-393 minimum; richer multi-value picker is a later req | No (comma-split specified) | — |
| OQ-2 | What is the exact `MAX_PAGE_SIZE` value enforced by `Letflow.Entities.Query.Cursor`? The dropdown's top option (250) must not exceed it. | Yes — cap dropdown before shipping | ELIXIR-DEV to confirm |
| OQ-3 | Does the QA/test instance have ≥2 pages of `tag` records for E2E scenario 2? | Yes — spec needs pagination to work | TEST-DESIGNER to verify or add beforeAll seed |
| OQ-4 | Which field on `tag` (or another BilimBaga entity) is non-queried for E2E scenario 3? | Yes — spec scenario 3 needs a concrete non-queried field name | TEST-DESIGNER to verify against definition JSON |
