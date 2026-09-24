# Design: CursorPage Wire Shape and Dead-Route Removal
## Issues: ISS-0816 / ISS-0821 / ISS-0822
## Run: WF03-BATCH-ISS0816-ISS0821-ISS0822-20260925
## Status: RETROACTIVE — implementations already committed to main (commits d8fa8096, a34305f7, 65312cd9)

---

## 0. Scope

This document covers three interrelated fixes:

| Issue | Commit | Topic |
|-------|--------|-------|
| ISS-0816 | a34305f7 | `CursorPage<T>` declared `has_more: boolean`; backend never emits it |
| ISS-0821 | d8fa8096 | Four test fixtures hand-wrote `has_more` into mocks, creating self-confirming tests |
| ISS-0822 | 65312cd9 | `/admin/modules` SPA route was wired to `Letflow.Routers.ProcessModules`, which does not exist |

---

## 1. CursorPage\<T\> Wire Shape (ISS-0816)

### 1.1 Backend authoritative shape

`Letflow.Api.Pagination.Page` (lib/letflow/api/pagination.ex) is the struct backing
all `Pagination.page_response/2` routes:

```
@derive {Jason.Encoder, only: [:items, :next_cursor, :count]}
defstruct [:items, :next_cursor, count: 0]
```

Wire keys emitted by `Pagination.page_response/2` routes: **`{items, next_cursor, count}`**.
`count` is always `length(items)`, computed by `page_response/2` — there is no separate
count parameter.

### 1.2 Hand-built route responses — no count

Three route families build their list response manually rather than calling
`Pagination.page_response/2`:

| Route family | File | Response shape |
|---|---|---|
| `definitions/search` | routers/definitions.ex | `%{"items" => …, "next_cursor" => …}` |
| `dlq` list | routers/dlq.ex (commentary at ~line 70) | `%{"items" => …, "next_cursor" => …}` |
| `promotions` review list | routers/promotions.ex `render_list_reviews/2` (~line 944) | `%{"items" => …, "next_cursor" => …}` |

For these routes `count` is **absent from the wire body** — it is not emitted and
therefore not observable by the client.

### 1.3 Why `count` is optional in `CursorPage<T>`

`count?` (TypeScript optional field) correctly models both populations:

- Routes using `Pagination.page_response/2` → `count` present (always a non-negative integer)
- Hand-built routes → `count` absent (field undefined in JS, not null)

Making `count` required would force every hand-built response mock and every call site
that only consumes `items`/`next_cursor` to supply a number they cannot source from the
wire — a type lie.

### 1.4 Why `has_more` was wrong

`has_more` was never in `Pagination.Page`'s `@derive` list and was never added to any
hand-built response map in the backend. The field existed solely in:

1. `web/src/types/api.ts` — declared as `has_more: boolean` (required)
2. `web/src/api/audit.ts` — client-derived: `has_more: Boolean(response.next_cursor)`
3. `web/src/api/promotions.ts` — client-derived: `has_more: Boolean(response.next_cursor)`

Items 2 and 3 were synthetic computations added to satisfy the required field in item 1.
They derived no information from the server — they simply re-encoded what `next_cursor`
already expresses. The fix removes `has_more` from the type and removes the
client-side derivations in `audit.ts` / `promotions.ts`.

**Note on `audit.ex`**: `lib/letflow/audit.ex` builds `has_more` internally (via
`:276`, `:295-297`) but drops it before `page_body/2` sends the response. The audit
route's wire shape is a distinct concern from `CursorPage<T>`'s; `has_more` is never
on the wire for any route.

### 1.5 The corrected TypeScript interface

```typescript
/** Cursor-paginated list response (API-13).
 * Wire shape: Letflow.Api.Pagination.Page emits {items, next_cursor, count}
 * when routes use Pagination.page_response/2. Hand-built responses (e.g.
 * definitions/search, dlq, promotions) emit only {items, next_cursor}.
 * The backend never emits has_more; pagination is driven by next_cursor !== null.
 */
export interface CursorPage<T> {
  items: T[]
  next_cursor: string | null
  count?: number
}
```

**Invariants:**
- `items` — always present, may be empty array
- `next_cursor` — `null` means no further pages; a string is an opaque cursor token
- `count` — present only from `Pagination.page_response/2` routes; always equals `items.length` at that route
- `has_more` — **not a field**; must not appear in any fixture, assertion, or derived value

---

## 2. Test Fixture Integrity (ISS-0821)

### 2.1 Self-confirming vs. discriminating fixtures

A **self-confirming fixture** passes regardless of what the server actually sends,
because the mock contains invented fields the test never receives from a real response.
In this case four fixtures hand-wrote `has_more: true` into mock pagination responses:

| File | Line(s) | Fixture |
|---|---|---|
| `web/src/pages/dlq/__tests__/DlqPage.pagination.test.tsx` | 78–80 | DLQ list page mock |
| `web/src/pages/promotions/__tests__/PromotionReviewListPage.test.tsx` | 119, 270 | Promotion review list mock |
| `web/src/pages/tasks/__tests__/TaskInboxPage.test.tsx` | 134, 160 | Task inbox mock |
| `web/tests/e2e/obs04.timeline.e2e.spec.ts` | 72 | E2E timeline intercept |

These tests would pass whether or not the production server emits `has_more`, because:
1. The mock is the only source of `has_more` — the test never exercises a real request
2. The component behaviour under test was conditioned on `has_more` (via the
   client-derived value in `audit.ts`/`promotions.ts`), which always evaluated to
   `Boolean(next_cursor)` — making the test a proof of the derivation, not a proof
   of the wire contract

A **discriminating fixture** contains only the keys a real route actually emits, matched
against the documented `@derive` list or the hand-built response map. If the server were
to change its wire shape, a discriminating fixture would fail.

### 2.2 Canonical pagination check after the fix

The correct check for "more pages available" is:

```typescript
next_cursor !== null   // true → more pages; false/null → exhausted
```

`has_more` must not be used. It was never on the wire, and nothing downstream should
be conditioned on it.

### 2.3 `cursor-page-wire-shape.test.ts` — prevention mechanism

`web/src/types/__tests__/cursor-page-wire-shape.test.ts` (committed with ISS-0821)
provides a compile-time and runtime guard:

**Compile-time (TypeScript structural typing):** the test file constructs two objects of
type `CursorPage<SampleItem>` — one without `count` (hand-built route shape) and one
with `count` (Pagination.page_response shape). If `CursorPage<T>` were changed to
re-introduce `has_more: boolean` as required, the object literals would fail to
typecheck, and `tsc` / `npm run type-check` would catch the regression before any test
runs.

**Runtime (Vitest assertions):**

| Test ID | What it pins |
|---|---|
| TC-ISS0821-01 | No-count variant is structurally valid; `count` is `undefined` |
| TC-ISS0821-02 | Count variant is valid; `count` equals the supplied value |
| TC-ISS0821-03 | Neither variant has `has_more` as an own property |
| TC-ISS0821-04 | `next_cursor === null` is the correct "no more pages" signal |

TC-ISS0821-03 uses `Object.prototype.hasOwnProperty.call` rather than a truthiness
check, so it catches `has_more: false` as well as `has_more: true` — the field must
not exist at all on a conformant response, not merely be falsy.

---

## 3. /admin/modules Route Removal (ISS-0822)

### 3.1 Decision: remove the SPA route outright

Options considered:

| Option | Verdict |
|---|---|
| A. Remove `/admin/modules` route and `<ProcessModulesPage />` import from `router.tsx` | **Selected** |
| B. Gate the page with an "unavailable feature" placeholder | Rejected — adds frontend complexity with zero user value; the feature is not partially working, it is entirely absent |
| C. Implement `Letflow.Routers.ProcessModules` now | Out of scope — S5 process-module packaging is a full stage, not an issue-fix |

Rationale for A: a route that 404s on every request is indistinguishable from a broken
deployment to an operator. Removing it is the minimum change that prevents that confusion
without adding new code. `web/src/api/modules.ts` and `web/src/hooks/useModules.ts` are
retained as S5 stubs — they represent the intended future API surface and carry no
runtime cost while they are unreachable.

### 3.2 Why S6 routers were removed from router.ex's deferred table

`router.ex`'s deferred table previously listed:
- `Letflow.Routers.Dlq` — now mounted in `api_pipeline.ex` (S6 complete)
- `Letflow.Routers.Services` — now mounted
- `Letflow.Routers.PlatformMigrations` — now mounted
- `Letflow.Routers.Webhooks` — now mounted

All four S6 routers are live. Keeping them in the "deferred" table would imply they are
not yet implemented, which would make the table false. The table must reflect the current
state of `api_pipeline.ex`, not the historical schedule. ISS-0822's commit updates the
table to remove these four entries and document only the still-genuinely-deferred routers.

### 3.3 Remaining deferred routers after ISS-0822

The following routers remain in `router.ex`'s deferred table after ISS-0822:

| Module | R-Co source | Owning stage | SPA route status |
|---|---|---|---|
| `Letflow.Routers.SimulationTest` | `simulation_test.zig` | S7 — simulation harness | No SPA route |
| `Letflow.Routers.ProcessModules` | `process_modules.zig` | S5 — process-module packaging | **Removed** (ISS-0822) |
| `Letflow.Routers.AgentRequests` | `agent_task_specs.zig` | post-S6 — runtime-agent | No SPA route |
| `Letflow.Routers.AgentResponses` | `agent_sandboxes.zig` | post-S6 — runtime-agent | No SPA route |
| `Letflow.Routers.AgentEvents` | `agent_artifacts.zig` | post-S6 — runtime-agent | No SPA route |

`Letflow.Routers.ProcessModules` is the **only** router that previously had a reachable
SPA route (`/admin/modules → <ProcessModulesPage />`). That route is now removed.
No other SPA route in `web/src/router.tsx` points at a router in the deferred table —
this was verified by cross-referencing every `path:` entry in `router.tsx` against the
current `api_pipeline.ex` forward table.

### 3.4 Decision record (against S5 scope)

Decision (ISS-0822): `Letflow.Routers.ProcessModules` is not mounted in `router.ex`/
`api_pipeline.ex` and its SPA route (`/admin/modules → <ProcessModulesPage />`) has
been removed from `web/src/router.tsx` until S5 is implemented. The frontend stubs
(`web/src/api/modules.ts`, `web/src/hooks/useModules.ts`) are retained because they
carry no runtime cost while unreachable and represent the intended S5 API surface.
This decision is recorded in `router.ex`'s moduledoc.

---

## 4. Acceptance Criteria Coverage

### ISS-0816 / ISS-0821

| AC | Satisfied by |
|---|---|
| Four fixtures no longer fabricate `has_more`; each mock matches a real route's response shape | §2.1: fixtures updated to `{items, next_cursor}` or `{items, next_cursor, count}` depending on the route |
| Tests still meaningfully cover pagination via `next_cursor` | §2.2: `next_cursor !== null` is the discriminating check retained in all four tests |
| A mechanism makes this class harder to reintroduce | §2.3: TC-ISS0821-03 (hasOwnProperty check for `has_more`) + compile-time structural typing in the same file |
| Lands with or after ISS-0816's type fix | Commit a34305f7 (type fix) precedes/accompanies d8fa8096 (fixtures) |

### ISS-0822

| AC | Satisfied by |
|---|---|
| SPA route removed or explicitly gated | §3.1: route removed outright; no gating code added |
| Decision recorded against S5 scope | §3.4 above; router.ex moduledoc updated |
| Every modules.ts call audited against real route table | `modules.ts` retained as S5 stub with no live callers; the audit confirms no mounted route exists for its URL prefixes |
| No other SPA route points at a deferred router | §3.3: cross-reference confirms ProcessModules was the only offender |

---

## 5. Open Questions

None. All design decisions above are stated definitively. ISS-0816's audit of `audit.ex`'s
internal `has_more` usage (lines :276, :295-297) confirmed it is not emitted on the wire —
no further type split is needed.
