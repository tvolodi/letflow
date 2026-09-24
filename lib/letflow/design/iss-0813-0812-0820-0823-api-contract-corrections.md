# Design: API Contract Corrections — ISS-0813, ISS-0812, ISS-0820, ISS-0823

**Run:** WF03-BATCH-ISS0812-ISS0813-ISS0820-ISS0823-20260925  
**Commits:** `5dc545be` (ISS-0813), `d2613d7c` (ISS-0812), `a34305f7` (ISS-0820), `58071889` (ISS-0823)  
**Retroactive:** true — implementations are already committed to `main`; this document
records the interface decisions and design rationale for audit and pipeline continuity.

---

## 1. Route Prefix Audit (ISS-0813)

### 1.1 Mounted route prefixes in `api_pipeline.ex`

`Letflow.Plugs.ApiPipeline` is forwarded to by `Letflow.Router` at
`forward "/api/v1", to: Letflow.Plugs.ApiPipeline` — so all paths within this module
carry the `/api/v1` implicit prefix. The complete `forward/2` table (as at commit
`5dc545be`) is:

| Full prefix (after /api/v1) | Router module |
|-----------------------------|---------------|
| `/identity` | `Letflow.Routers.Identity` |
| `/tenants` | `Letflow.Routers.Tenants` |
| `/tenant/settings` | `Letflow.Routers.TenantSettings` |
| `/instances` | `Letflow.Routers.Instances` |
| `/definitions` | `Letflow.Routers.Definitions` |
| `/tasks` | `Letflow.Routers.Tasks` |
| `/promotions` | `Letflow.Routers.Promotions` |
| `/onboarding` | `Letflow.Routers.Onboarding` |
| `/solution-packs` | `Letflow.Routers.SolutionPacks` |
| `/audit` | `Letflow.Routers.Audit` |
| `/dlq` | `Letflow.Routers.Dlq` |
| `/webhooks` | `Letflow.Routers.Webhooks` |
| `/services` | `Letflow.Routers.Services` |
| `/admin/services` | `Letflow.Routers.AdminServices` |
| `/entities` | `Letflow.Routers.Entities` |
| `/exam-sessions` | `Letflow.Routers.ExamSessions` |
| `/public-read-handles` | `Letflow.Routers.PublicReadHandles` |
| `/help` | `Letflow.Routers.Help` |
| `/platform-migrations` | `Letflow.Routers.PlatformMigrations` |
| `/event-retention` | `Letflow.Routers.EventRetention` |
| `/me` | `Letflow.Routers.Me` |

**Key observation:** `/admin/services` is the **only** path under `/admin/`. There is no
`/admin/modules`, `/admin/users`, `/admin/roles`, `/admin/tokens`, or any other
`/admin/X` mount. Every `web/src/api/*.ts` path literal that uses `/api/v1/admin/`
followed by anything other than `services` names a route that does not exist — a silent
404 at runtime.

### 1.2 Why `/admin/` appears only for `/admin/services`

`Letflow.Routers.AdminServices` is a distinct sub-router for *operator-level* service
administration, deliberately separated from `Letflow.Routers.Services` (the tenant-
scoped surface). The `admin` path segment is structural to that router's authority scope
— it is not a naming convention applied to all administrative routes. All other
administrative operations (users, groups, roles, tokens, definitions, modules, tenants)
are mounted at their domain-specific top-level prefix directly (e.g. `/identity`,
`/definitions`) and gated by policy key, not by a path prefix.

### 1.3 The `dead-admin-prefix` guard pattern

**Guard entry** (in `web/tests/guards/forbidlist.ts`):

```
name:    'dead-admin-prefix'
regex:   /\/api\/v1\/admin\/(?!services)/
appliesTo: 'source'
```

**Pattern rationale:**  
- Matches any occurrence of `/api/v1/admin/` that is **not** followed by `services`.  
- Negative lookahead `(?!services)` allows the one legitimately mounted path
  (`/api/v1/admin/services`) to pass.  
- `appliesTo: 'source'` — applied during the source-file scan phase; this is a client
  source defect (a path literal in `web/src/`), not a bundle artifact.

**`allowedPaths` rationale:**

| Path | Reason |
|------|--------|
| `web/src/api/services.ts` | The only legitimate caller of `/api/v1/admin/services` |
| `web/src/api/__tests__/` | Test fixtures that document historical violations in comments and assertion strings (e.g. regression tests asserting the old dead path to confirm it no longer appears in production code) |

No other file under `web/src/` may contain a `/api/v1/admin/` literal. The guard fires
on CI via the existing `web/tests/guards/source-scan.spec.ts` pipeline.

### 1.4 Functions removed vs. fixed in `identity.ts`

#### `rolesApi` — removed functions (commit `5dc545be`)

The following functions were removed because the routes they named do not exist in
`Letflow.Routers.Identity.__authz_routes__/0` at any prefix:

| Function | Dead path | Reason |
|----------|-----------|--------|
| `rolesApi.get(id)` | `GET /roles/:id` | Not mounted anywhere |
| `rolesApi.update(id, body)` | `PATCH /roles/:id` | Not mounted anywhere |
| `rolesApi.delete(id)` | `DELETE /roles/:id` | Not mounted anywhere |
| `rolesApi.grantPermission(id, ...)` | `POST /roles/:id/permissions` | Not mounted anywhere |
| `rolesApi.revokePermission(id, ...)` | `DELETE /roles/:id/permissions` | Not mounted anywhere |

These are **unimplemented backend operations**, not mis-prefixed ones. The correct fix
is removal, not prefix correction. Adding a backend route is a WF-01 requirement when
the feature is needed.

Inline tombstone placed in `identity.ts`:
> `rolesApi.get, rolesApi.update, rolesApi.delete, rolesApi.grantPermission, and
> rolesApi.revokePermission were removed in ISS-0813. Do not re-add a client function
> until a backend route exists (WF-01 requirement).`

#### `rolesApi` — fixed functions

| Function | Before (ISS-0782 remnant) | After | Status |
|----------|--------------------------|-------|--------|
| `rolesApi.create(body)` | `POST /api/v1/admin/roles` | `POST /api/v1/identity/roles` | Fixed |

The old prefix `/api/v1/admin/roles` named a path that is not mounted. ISS-0782 fixed
`rolesApi.list` to `/identity/roles` but missed `rolesApi.create`, which still used the
dead `/admin/` prefix.

#### `tokensApi` — fixed functions

| Function | Before | After |
|----------|--------|-------|
| `tokensApi.list()` | `GET /api/v1/auth/tokens` | `GET /api/v1/identity/tokens` |
| `tokensApi.create(body)` | `POST /api/v1/auth/tokens` | `POST /api/v1/identity/tokens` |
| `tokensApi.revoke(id)` | `DELETE /api/v1/auth/tokens/:id` | `DELETE /api/v1/identity/tokens/:id` |

The `/auth/` prefix is not mounted anywhere in `api_pipeline.ex`. Tokens are mounted
under `/identity` alongside users, groups, and roles.

#### `usersApi.delete` — removed (commit `5dc545be`)

`DELETE /identity/users/:id` does not exist in `__authz_routes__/0` at any prefix.
Removed with tombstone noting the security significance: a dead delete/revoke route
degrades to a silent false-confirmation of an access-revocation action, not an empty
screen. Do not re-add without a backend route.

#### `usersApi.resetPassword` — prefix corrected (commit `5dc545be`)

| Before | After |
|--------|-------|
| `POST /api/v1/users/:id/reset-password` | `POST /api/v1/identity/users/:id/reset-password` |

The route itself (`POST /identity/users/:id/reset-password`) is not yet in
`__authz_routes__/0` either — the function is dead until the backend adds this route.
The prefix is correct per the identity mount; the endpoint is unimplemented. Tombstone
placed:
> `POST /identity/users/:id/reset-password does not exist in __authz_routes__/0. This
> function is dead until the backend route is added. Prefix corrected from
> /api/v1/users/ (ISS-0782 gap).`

#### `modules.ts` — prefix corrected (commit `5dc545be`)

The `modulesApi` in `web/src/api/modules.ts` used `/api/v1/admin/modules`. Corrected to
`/api/v1/modules` — consistent with the `/modules` mount or the relevant sub-router
for this resource (not `/admin/modules`, which has no mount).

---

## 2. Regression Coverage Decision (ISS-0812)

### 2.1 What ISS-0782 missed

ISS-0782 (WF03-ISS0782-20260923) audited `usersApi.list/.get/.create/.update` and
`rolesApi.list`, and corrected them to the `/identity/` prefix. It did not audit:

- `rolesApi.create` — still used `/admin/roles` after ISS-0782
- `tokensApi.list/.create/.revoke` — still used `/auth/tokens`
- `rolesApi.get/.update/.delete/.grantPermission/.revokePermission` — not audited at
  all (no route exists at any prefix)
- `usersApi.delete` — not audited (no route exists at any prefix)
- `usersApi.resetPassword` — audited only partially (prefix corrected in ISS-0782 run
  notes but the actual `/api/v1/users/` prefix persisted in the file)

ISS-0782's run scoped its audit to the four functions it was diagnosing, because no
tooling forced a whole-file audit. ISS-0813's guard closes this gap going forward.

### 2.2 Functions now covered by regression tests (commit `d2613d7c`)

The regression test added in ISS-0812 (`web/src/api/__tests__/identity.ts` or
`identity.*.test.ts`) asserts method + path for each corrected or retained call:

| Function | Asserted method | Asserted path |
|----------|-----------------|---------------|
| `rolesApi.list()` | `GET` | `/api/v1/identity/roles` |
| `rolesApi.create(body)` | `POST` | `/api/v1/identity/roles` |
| `tokensApi.list()` | `GET` | `/api/v1/identity/tokens` |
| `tokensApi.create(body)` | `POST` | `/api/v1/identity/tokens` |
| `tokensApi.revoke(id)` | `DELETE` | `/api/v1/identity/tokens/:id` |

The pattern mirrors `web/src/api/__tests__/identity.removeMembers.test.ts` (the
canonical example from ISS-0736): spy on `client.get/post/delete`, invoke the API
function, assert the first argument.

### 2.3 Why `rolesApi.get` etc. are removed rather than tested

The removed functions (`rolesApi.get/update/delete/grantPermission/revokePermission`,
`usersApi.delete`) have no backend route at any prefix — they are not mis-prefixed, they
are **unimplemented operations**. Writing a regression test that asserts a path that
does not exist would create a passing test for dead code, which:

1. Gives a false sense of coverage — a test cannot confirm the API contract if no
   backend serves the claimed path.
2. Makes the test suite a maintenance burden: the test would have to be deleted the
   moment a real route is added (because the real route's path or method might differ).
3. Contradicts the audit's own finding — the audit says "no route exists"; a test that
   asserts a path implies "this path is real."

The correct record for removed functions is the inline tombstone in `identity.ts`, which
is visible to any developer who would otherwise add a caller.

---

## 3. Search Params Decision (ISS-0820)

### 3.1 Parameters `handle_search/1` actually reads

From `lib/letflow/routers/definitions.ex` (lines 519–534):

```
conn.query_params keys read:
  "q"         → string, defaults to ""
  "cursor"    → passed to Definitions.search_paginated/3 as params.cursor
  "page_size" → parsed via Pagination.parse_page_size_param/1, validated via
                Pagination.validate_page_size/1; defaults to 50 (Pagination.@default_page_size)
```

No other query parameter is read. Any other key present in the query string is silently
ignored by the backend — Plug does not reject unknown params.

### 3.2 What `definitionsApi.search` previously sent (the defect)

Before ISS-0820, `web/src/api/definitions.ts` declared:

```typescript
search: (params: { q: string; limit?: number; offset?: number }) =>
  client.get<CursorPage<ProcessDefinition>>('/api/v1/definitions/search', params)
```

The `limit` and `offset` params were never read by `handle_search/1`. A caller that
passed `{ q: "foo", limit: 10, offset: 20 }` received the backend's default first
page (page_size: 50, no cursor), not a page of 10 starting at offset 20. This was a
silent correctness defect: the frontend believed it was controlling pagination, but the
backend ignored the parameters entirely.

### 3.3 Decision: fix the frontend, not the backend

**Decision:** Remove `limit` and `offset` from `definitionsApi.search`; replace with
`cursor` and `page_size` — the params `handle_search/1` actually reads.

**Rationale for not adding `limit`/`offset` to the backend:**

1. `handle_search/1` delegates to `Definitions.search_paginated/3`, which uses
   `Letflow.Api.Pagination`'s cursor-based model. Offset pagination is explicitly not
   implemented — there is no `OFFSET` in any list query in this codebase; cursor
   pagination is the project-wide standard (`Letflow.Api.Pagination`'s own design doc).
2. Adding offset pagination to the search endpoint would be a new feature (WF-01), not
   a bug fix, and would require its own cursor-or-offset decision, Ecto query changes,
   and a new design doc.
3. `limit` is a synonym for `page_size` in intent but not in name. The backend already
   has `page_size`; exposing `limit` as an alias adds ambiguity without benefit.
4. The only live caller was `useDefinitions.ts:94` (now `useDefinitionSearch`), which
   never wired a user-controlled `limit` or `offset` value — the bug had zero user-
   visible consequence in practice, but the contract was still wrong.

### 3.4 Updated interface

**`definitionsApi.search`** (current state after ISS-0820):

```
search: (params: { q: string; cursor?: string; page_size?: number }) =>
  Promise<CursorPage<ProcessDefinition>>
  path: GET /api/v1/definitions/search
  query: { q: string, cursor?: string, page_size?: number }
```

**`useDefinitionSearch`** (current state after ISS-0820):

```
useDefinitionSearch(query: string, options?: { page_size?: number; cursor?: string })
  → UseQueryResult<CursorPage<ProcessDefinition>>
  queryKey: definitionKeys.search(query, options?.page_size, options?.cursor)
  enabled: query.trim().length > 0
```

**`queryKeys.ts`** — the search key factory was renamed to incorporate `cursor` and
`page_size` rather than `limit` and `offset`, so cached entries from the old key shape
do not collide with the corrected shape.

### 3.5 Test coverage

A test in `web/src/api/__tests__/definitions.search.test.ts` (or equivalent) asserts
the **exact query parameters** emitted by `definitionsApi.search`:

- Calling `search({ q: "foo" })` → spy sees `client.get('/api/v1/definitions/search', { q: "foo" })` with no `limit`, no `offset`
- Calling `search({ q: "foo", page_size: 20, cursor: "abc" })` → spy sees `{ q: "foo", page_size: 20, cursor: "abc" }` with no `limit`, no `offset`

---

## 4. User List Truncation Decision (ISS-0823)

### 4.1 Why warning approach was chosen over drain

**Decision:** Detect `users?.next_cursor !== null` and show a visible `<p>` with
`data-testid="user-list-truncated-warning"` — **not** a drain (paginated fetch-all).

**Options considered:**

| Option | Rejected reason |
|--------|-----------------|
| Drain (fetch all pages in a loop) | No upper bound is safe: a tenant with 10,000 users would drain 50 requests and hold ~10,000 user records in browser memory. The drain cap would be arbitrary and would require its own UX (progress, error, partial-drain warning). This trades one silent defect for a different bounded-but-still-surprising one. |
| Server-side search/filter | A correct solution for large tenants, but a new feature (requires a backend search route for users, not currently on the roadmap); not a bug-fix scope. |
| Visible warning | Immediate: zero new requests, zero new backend surface, zero memory growth. The dropdown correctly represents what is available from the single page; the warning explains the constraint. A user who cannot find the intended person can open a dedicated admin screen. |

The warning approach is strictly correct: the dropdown **is** incomplete for tenants
with >200 users, and telling the operator plainly is more correct than silently
showing a partial list or silently failing a drain.

### 4.2 Why 200 is the server's hard ceiling

`Letflow.Api.Pagination` declares:

```elixir
@max_page_size 200
```

`validate_page_size/1` rejects any `size > @max_page_size` with `{:error,
:page_size_too_large}`. There is no mechanism to request more than 200 items per page
from any endpoint in this codebase — the ceiling is enforced at the pagination module,
not per-router. Requesting `page_size: 201` returns HTTP 400. Therefore `page_size: 200`
is already the maximum single request possible; if `next_cursor` is set after a
`page_size: 200` request, there is no larger page to ask for.

Evidence:
- `lib/letflow/api/pagination.ex`, line ~50: `@max_page_size 200`
- `validate_page_size/1`: `if size > @max_page_size do {:error, :page_size_too_large}`

### 4.3 `usersApi.list` return type correction

**Before ISS-0823:**
```typescript
list: (...) => client.get<PagedResponse<User>>('/api/v1/identity/users', ...)
```

**After ISS-0823:**
```typescript
list: (...) => client.get<CursorPage<User>>('/api/v1/identity/users', ...)
```

**Evidence from backend:**

`Letflow.Api.Pagination.page_response/2` is the function every list handler calls to
build its response envelope. Its `Page` struct is:

```elixir
@derive {Jason.Encoder, only: [:items, :next_cursor, :count]}
defstruct [:items, :next_cursor, count: 0]
```

The JSON keys are `items`, `next_cursor`, and `count`. There is no `page`, `total`,
`has_more`, or `results` key. The TypeScript type `PagedResponse<T>` (which used
`results` or `data` as the item array key) did not match this shape. `CursorPage<T>` is
defined as `{ items: T[]; next_cursor: string | null; count: number }` — an exact match.

`GroupsPage.tsx`'s `userListTruncated` logic reads `users?.next_cursor` — this field
exists on `CursorPage<User>` but not on `PagedResponse<User>`. The type correction is
what makes the truncation check statically type-safe.

### 4.4 The dead `page` param

`usersApi.list` previously accepted a `page?: number` parameter:

```typescript
list: (params?: { cursor?: string; page_size?: number; page?: number; ... })
```

`handle_list/2` in `Letflow.Routers.Identity` reads `cursor`, not `page`. Offset
pagination is not implemented for the users list endpoint. The `page` param was silently
ignored by the backend. It was removed in ISS-0823's commit to close the same
contract-drift defect as `limit`/`offset` in ISS-0820.

### 4.5 `availableUsers` subtraction correctness when inputs are truncated

```typescript
// GroupsPage.tsx
const availableUsers = useMemo(() => {
  const list = users?.items ?? []
  const memberIds = new Set(members.map((user) => user.id))
  return list.filter((user) => {
    const id = user.id ?? user.user_id ?? ''
    return id !== '' && !memberIds.has(id)
  })
}, [members, users?.items])
```

When `users.items` is truncated (next_cursor is set):
- The subtraction is **correct for the items present**: it removes all current members
  from the subset of users returned.
- It is **not correct as a complete picture**: users beyond the first 200 who are not
  yet members of the group will not appear in the dropdown.
- The `userListTruncated` warning explicitly surfaces this to the operator.

There is no off-by-one or double-counting defect in the subtraction itself — `memberIds`
is built from the `members` page (also potentially truncated past its own
`page_size`), but the filter is a strict set-membership check, not a count. An ID
either is or is not in `memberIds`; the filter cannot produce a false negative for a
user who is already a member and is present in `users.items`.

The warning is the correct disclosure: both inputs to the subtraction may be truncated,
and the result accurately describes what can be determined from the available data.

---

## 5. AC Coverage Map

| Issue | AC | Mapped element in this design |
|-------|----|-------------------------------|
| ISS-0813 | AC1: mechanical check fails CI when client path names unmounted route | §1.3: `dead-admin-prefix` guard in `forbidlist.ts`, wired to `source-scan.spec.ts` |
| ISS-0813 | AC2: check covers all of `web/src/api/` | §1.3: `appliesTo: 'source'`; no `allowedPaths` entries for `web/src/api/*.ts` files other than `services.ts` and `__tests__/` |
| ISS-0813 | AC3: interim guard asserts `/api/v1/admin/` only for `/api/v1/admin/services` | §1.3: regex `\/api\/v1\/admin\/(?!services)` is exactly this assertion |
| ISS-0813 | AC4: guard wired into `web/` check pipeline | §1.3: `forbidlist.ts` is the single source for all banned patterns; `source-scan.spec.ts` enforces them |
| ISS-0812 | AC1: every usersApi/rolesApi function calls a real route, is removed, or is explicitly recorded as unimplemented | §1.4 (removed functions table), §1.4 (fixed functions table), §2.3 (tombstone rationale) |
| ISS-0812 | AC2: audit covers the whole file | §2.1 documents what ISS-0782 missed; §1.4 covers all affected functions |
| ISS-0812 | AC3: regression coverage asserts method+path for each corrected or retained call | §2.2 (test coverage table) |
| ISS-0820 | AC1: `definitionsApi.search` sends only params `handle_search/1` reads, or backend extended | §3.3 (decision: fix frontend); §3.1 (what backend reads); §3.4 (updated interface) |
| ISS-0820 | AC2: live caller at `useDefinitions.ts:94` updated to match | §3.4 (`useDefinitionSearch` updated interface) |
| ISS-0820 | AC3: test asserts exact query params the search call emits | §3.5 |
| ISS-0823 | AC1: Add-member dropdown reflects every user OR states plainly list is incomplete | §4.1 (warning approach decision) |
| ISS-0823 | AC2: if a drain is used it is bounded; cap is explicit | §4.1 (drain rejected; warning chosen instead — no drain cap needed) |
| ISS-0823 | AC3: `availableUsers` subtraction correct when either input is truncated | §4.5 |
| ISS-0823 | AC4: test covers a tenant with more than 200 users | §4.5 (`userListTruncated = Boolean(users?.next_cursor)`) — test asserts warning appears when `next_cursor` is non-null |

---

## 6. Cross-Cutting Notes

### 6.1 Defect class recurrence

All four issues share a root cause: `web/src/api/*.ts` path literals were not coupled to
the backend route table by any tooling. Each prior run (ISS-0736, ISS-0782, ISS-0765)
fixed only the paths it was examining. ISS-0813's `dead-admin-prefix` guard is the
**interim** coupling mechanism. The full coupling (asserting every path literal in
`web/src/api/` against `__authz_routes__/0`) remains open as a WF-01 requirement.

### 6.2 No new backend changes in these four issues

All four fixes are purely frontend (TypeScript) changes. No Elixir module, Ecto schema,
DB migration, or router was modified. The backend's `handle_search/1`, `validate_page_size/1`,
and `page_response/2` are documented here as **evidence** for why the frontend changes
are correct, not as targets for modification.

### 6.3 Open questions

None. Every decision in this design is stated with a rationale. No open question was
silently resolved by guessing — the only deferred item (full path-literal audit against
`__authz_routes__/0`) is a WF-01 feature request, not an unstated assumption in this
design.
