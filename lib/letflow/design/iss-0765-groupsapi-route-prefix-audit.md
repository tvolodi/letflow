# ISS-0765 — `groupsApi` route-prefix audit and response-shape correction

**Run:** `WF03-ISS0765-20260924` · **Workflow:** WF-03 Step 2 (fix design)
**Author:** `CODE-DESIGNER` · **Queue task:** Q-810 · **GitHub:** GH-1798
**Implementing role:** `FRONTEND-DEV` (Step 3). **Backend changes: NONE.**

**Files in scope for the implementation:**

| File | Change class |
|---|---|
| `web/src/api/identity.ts` | `groupsApi` only — URL literals, two deletions, signatures, return types |
| `web/src/types/api.ts` | three new exported interfaces, additive only |
| `web/src/pages/admin/GroupsPage.tsx` | consequence of §3's `.members` retype (5 edits + 1 added line) and §4's `addMember` rename (1 edit) |
| `web/src/api/__tests__/identity.groupsApi.test.ts` | new file (§7 test matrix) |

**Out of scope, and the implementer must not touch them** (each already filed):
`usersApi` and `rolesApi` (ISS-0812); `Group.is_system` / `Group.member_count` and the
GroupsPage "Members column always 0" (ISS-0811); a generic route-table↔client-literal
coupling guard (ISS-0813); `groupsApi.removeMembers` (already correct — ISS-0736).

---

## 1. Verified ground truth

Every claim in this section was re-derived from source in this step, not inherited from
the Step 1 handoff (`core-directives.md`, "a handoff's factual premises are checkable").

### 1.1 Mount chain

| Source | Effect |
|---|---|
| `lib/letflow/router.ex:130` | `forward("/api/v1", to: Letflow.Plugs.ApiPipeline)` |
| `lib/letflow/plugs/api_pipeline.ex:141` | `forward("/identity", to: Letflow.Routers.Identity)` |
| `lib/letflow/plugs/api_pipeline.ex:154` | `forward("/admin/services", …)` — the **only** `/admin/*` mount |
| `lib/letflow/plugs/api_pipeline.ex:203-205` | `match _` → `Response.not_found(conn)` |

Canonical group prefix: **`/api/v1/identity/groups`**. Nothing is mounted at
`/api/v1/admin/groups`; a request there reaches the pipeline catch-all and 404s
*after* successful authentication.

### 1.2 The six group routes that exist

Re-read at `lib/letflow/routers/identity.ex:178-204`, all `policy = :GroupsManage`:

```
POST   /api/v1/identity/groups
GET    /api/v1/identity/groups
DELETE /api/v1/identity/groups/:id
POST   /api/v1/identity/groups/:id/members
GET    /api/v1/identity/groups/:id/members
DELETE /api/v1/identity/groups/:id/members/:user_id
```

There is **no** `GET /groups/:id` and **no** `PATCH`/`PUT /groups/:id`. Confirmed a
second way: `lib/letflow/identity.ex` exposes `create_group/2`, `add_group_member/3`,
`list_groups/1`, `delete_group/2`, `list_group_members/3`, `remove_group_member/3` —
and no `get_group/*` or `update_group/*`. These two operations were never built, at any
layer; they are not a route-registration oversight.

### 1.3 Exact wire bodies

| Route | Handler | Wire body |
|---|---|---|
| `GET /groups` | `handle_list_groups/2` (`identity.ex:468-472`) | `{"items": [group_map…], "total": N}` — **no `page`, no `page_size`** |
| `POST /groups` | `handle_create_group/2` (`:452`) | `201` + one `group_map/1` object |
| `DELETE /groups/:id` | `handle_delete_group/3` (`:476`) | `204`, empty |
| `POST /groups/:id/members` | `handle_add_member/3` (`:496`) | `201` (created) or `200` (already member) + `member_result_map/3` (`:829-831`) = `{"group_id": …, "user_id": …, "created": bool}` |
| `GET /groups/:id/members` | `handle_list_group_members/3` (`:543`) | `Pagination.page_response/2` → `{"items": [user_map…], "next_cursor": string\|null, "count": N}` |
| `DELETE /groups/:id/members/:user_id` | `handle_remove_member/4` | `204`, empty |

`group_map/1` (`identity.ex:749-757`) emits exactly
`{"id", "name", "display_name", "description", "created_at"}`.

`user_map/1` (`identity.ex:729-740`) emits exactly
`{"id", "username", "display_name", "email", "status", "auth_source", "inserted_at", "updated_at"}`.

`Letflow.Api.Pagination.Page` (`lib/letflow/api/pagination.ex:81`) is
`@derive {Jason.Encoder, only: [:items, :next_cursor, :count]}` — the envelope has a
`count`, and has **no** `has_more`.

`GET /groups/:id/members` additionally accepts `page_size` (default 50, max 200) and
`cursor` query params, which the client never sends.

### 1.4 Per-function verdicts

| `groupsApi.<fn>` | `identity.ts` line | Current URL | Verdict |
|---|---|---|---|
| `list()` | 37-38 | `GET /api/v1/admin/groups` | WRONG-PREFIX + return-type lie |
| `get(id)` | 40-41 | `GET /api/v1/admin/groups/${id}` | NO BACKEND ROUTE, zero callers |
| `create(body)` | 43-44 | `POST /api/v1/admin/groups` | WRONG-PREFIX |
| `update(id, body)` | 46-47 | `PATCH /api/v1/admin/groups/${id}` | NO BACKEND ROUTE, zero callers |
| `delete(id)` | 49-50 | `DELETE /api/v1/admin/groups/${id}` | WRONG-PREFIX |
| `addMembers(id, userIds)` | 52-53 | `POST /api/v1/admin/groups/${id}/members` | WRONG-PREFIX + unhonourable plural body + return-type lie |
| `removeMembers(id, userId)` | 55-56 | `DELETE /api/v1/identity/groups/${id}/members/${userId}` | **CORRECT — do not touch** |
| `members(id)` | 58-59 | `GET /api/v1/admin/groups/${id}/members` | WRONG-PREFIX + **envelope mismatch** |

### 1.5 Caller blast radius (re-derived by grep in this step)

| `groupsApi.<fn>` | Callers |
|---|---|
| `list` | `GroupsPage.tsx:47`; `hooks/useAdminUsers.ts:47` (`useAdminGroups`) |
| `get` | none |
| `create` | `GroupsPage.tsx:67` |
| `update` | none |
| `delete` | `GroupsPage.tsx:97` |
| `addMembers` | `GroupsPage.tsx:76` — passes `[userId]`, a one-element array literal |
| `removeMembers` | `GroupsPage.tsx:87` |
| `members` | `GroupsPage.tsx:56` (query); consumed as an array at `:103`, `:223`, `:227` |

**Correction to the Step 1 diagnosis.** It recorded "No consumer of `useAdminGroups` was
found outside `web/src/hooks/useAdminUsers.ts` itself" and asked this step to re-verify.
That is **false**: `web/src/pages/admin/UserDetailPage.tsx:28` calls `useAdminGroups()`
and reads `groupsQuery.data?.items` at `:149`. So `groupsApi.list` has **three**
consumers, not two. All three read `.items` only — none reads `.total`, `.page` or
`.page_size` — which is what makes §5's type narrowing a zero-call-site change. This
correction is what makes decision (d) checkable rather than assumed.

---

## 2. Decision (a) — `.get` and `.update`: **DELETE both**

**Decision: remove `groupsApi.get` and `groupsApi.update` from `web/src/api/identity.ts`
entirely, and replace them with a comment block recording that the two operations are
unimplemented backend-side.**

Rationale, in order of weight:

1. There is no route at **any** prefix (§1.2) and no `Letflow.Identity` context
   function. "Correcting" the prefix moves the 404 from ApiPipeline's catch-all
   (`api_pipeline.ex:203-205`) to `Letflow.Routers.Identity`'s own `match _`
   (`identity.ex:227-229`) — the same dead call wearing a better prefix, which is
   precisely the defect AC3 forbids ("left pointing at a dead prefix").
2. Zero production callers (§1.5), so deletion has no blast radius.
3. Adding `GET /groups/:id` and `PATCH /groups/:id` is **new backend behaviour** — a
   WF-01 requirement, not a WF-03 fix, and explicitly out of this run's scope
   ("Backend needs NO changes").
4. AC3 allows either removal or an explicit unimplemented record. Deletion **plus** the
   comment gives both: the dead call cannot be invoked, and the reason it is absent is
   recorded where the next reader will look — which is what stops a fourth run silently
   re-adding it.

**Consequence for ISS-0765's own `fix_direction`.** That field says to "correct
`.get`/`.update` to the real prefix". It is **not satisfiable as written**, because no
such prefix exists. ISSUE-FIXER flagged this at MINOR; this design resolves it by
deletion and records the divergence here so Step 5 does not close the issue claiming a
correction it did not make.

**Exact replacement text to sit where lines 40-41 and 46-47 are today** (a comment, not
code):

> `groupsApi.get(id)` and `groupsApi.update(id, body)` were removed in ISS-0765
> (run `WF03-ISS0765-20260924`). `GET /groups/:id` and `PATCH|PUT /groups/:id` do not
> exist in `Letflow.Routers.Identity.__authz_routes__/0` at any prefix, and
> `lib/letflow/identity.ex` has no `get_group/2` or `update_group/3` — these are
> unimplemented operations, not mis-prefixed ones. Do not re-add a client function for
> either until a backend route exists; adding one is a WF-01 requirement.

---

## 3. Decision (b) — `.members`: **retype to the real envelope, do not unwrap**

**Decision: `groupsApi.members(id)` returns the backend's `Pagination.Page` envelope
verbatim. The API client performs no reshaping. `GroupsPage.tsx` reads `.items`.**

Rationale, in order of weight:

1. **`docs/guides/frontend_developer_guide.md` §4 rule 1 forbids the alternative.**
   "If `web/` expects a field, a status code, or a pagination cursor that Letflow's API
   doesn't produce, route it to CODE-DESIGNER → ELIXIR-DEV. Do **not** add a shim or
   adapter inside `web/` that normalises the mismatch — that hides the gap from every
   other client, including the mobile tier that will consume the same contract."
   Unwrapping `.items` inside `groupsApi.members` is exactly that shim. This is a
   recorded project rule, not a preference, so it decides the question on its own.
2. **The retype makes the compiler the detector for the highest-risk item in this fix.**
   The established hazard is that a prefix-only fix converts a silent 404 into
   `members.map is not a function` at `GroupsPage.tsx:227`. Under the retype, any call
   site that still treats the value as an array is a **type error**, so
   `npm run type-check` (AC3, and already wired into `npm run check`) mechanically finds
   every one. Under the unwrap, `type-check` passes whether or not anyone ever
   considered the shape — the run would have no detector at all for a missed site.
3. Unwrapping discards `next_cursor`, permanently hiding from the client that the route
   is cursor-paginated at a default `page_size` of 50.

### 3.1 New types — `web/src/types/api.ts`, additive, placed immediately after `Group`

```
export interface GroupMember {
  id: string
  username: string
  display_name: string
  email: string
  status: 'active' | 'inactive'
  auth_source: 'internal' | 'oidc'
  inserted_at: string
  updated_at: string
}

export interface GroupMemberPage {
  items: GroupMember[]
  next_cursor: string | null
  count: number
}
```

Field-by-field justification for `GroupMember` — it is `user_map/1`
(`identity.ex:729-740`) transcribed exactly, every key present, no key absent, all
required because `user_map/1` emits every one unconditionally.

**Both unions are LOWERCASE, and that is not a typo.** `user_map/1` emits
`Atom.to_string(user.status)` and `Atom.to_string(user.auth_source)`, and
`lib/letflow/identity/user.ex:41-42` declares
`field(:status, Ecto.Enum, values: [:active, :inactive])` and
`field(:auth_source, Ecto.Enum, values: [:internal, :oidc])`. `lib/letflow/routers/identity.ex`
contains no `String.upcase` anywhere, so the wire values are `"active"`/`"inactive"` and
`"internal"`/`"oidc"`. The existing `User.status?: 'ACTIVE' | 'INACTIVE'`
(`types/api.ts:435`) is therefore **also wrong** — it is not corrected here (`User` is
out of scope; §11 finding 5 reports it), and `GroupMember` must not copy it.

`GroupMemberPage` is `Letflow.Api.Pagination.Page`'s `@derive` list
(`pagination.ex:81`) transcribed exactly.

**Why a new `GroupMember` instead of reusing `User`.** `User` (`types/api.ts:429-442`)
declares `roles: string[]` and `created_at: string` as **required**; `user_map/1` emits
neither (it emits `inserted_at`/`updated_at`). Re-declaring `User[]` on the line this
fix is rewriting would re-assert a known-false shape — the same class of defect this run
exists to remove. The scope boundary explicitly places "the `Group`/member TypeScript
types where they misdescribe the wire shape" in scope. `User`'s own lie on the
`usersApi` surfaces is **not** corrected here (that would ripple into `usersApi`, which
is out of scope) — it is reported to ORCH as a new finding instead.

**Why not reuse the existing `CursorPage<T>`** (`types/api.ts:14-18`): it declares
`has_more: boolean`, which `Pagination.Page` never emits. Reusing it would substitute
one wrong envelope for another. `CursorPage<T>` has ~12 other users across `web/src/api/`
and correcting it is a separate audit — reported to ORCH as a finding, not changed here.

### 3.2 `GroupsPage.tsx` — the five lines that change

Line numbers are pre-fix, from the file as it stands at `c484800f`.

| Line | Before | After |
|---|---|---|
| 54 | `const { data: members } = useQuery({` | `const { data: membersPage } = useQuery({` |
| *new, after 58* | — | `const members = useMemo(() => membersPage?.items ?? [], [membersPage?.items])` |
| 103 | `const memberIds = new Set((members ?? []).map((user) => user.id ?? user.user_id ?? ''))` | `const memberIds = new Set(members.map((user) => user.id))` |
| 108 | `}, [members, users?.items])` | *(unchanged text; the `members` it closes over is now the derived array)* |
| 223 | `{(members ?? []).length === 0 ? (` | `{members.length === 0 ? (` |
| 227 | `{(members ?? []).map((user) => {` | `{members.map((user) => {` |
| 228 | `const id = user.id ?? user.user_id ?? ''` | `const id = user.id` |

Notes the implementer must observe:

- `useMemo` is already imported at `GroupsPage.tsx:1`; no import change.
- The derived-`members` binding keeps `availableUsers`'s `useMemo` dependency
  referentially stable (React Query returns a stable `data` reference between renders),
  so `[members, users?.items]` at `:108` stays correct as written.
- `:103` and `:228` drop the `?? user.user_id ?? ''` fallbacks because `GroupMember.id`
  is required; leaving them is a type error under the new type, which is the intended
  compiler signal.
- **No other line in `GroupsPage.tsx` may change.** In particular `groupMembers/1`
  (`:28-30`), the `is_system` guard (`:129`) and the `member_count` column (`:113`) are
  ISS-0811's scope, not this run's.

### 3.3 Known limitation, deliberately not fixed here

The members dialog shows at most the first page — 50 members
(`Pagination.default_page_size/0`, `pagination.ex:99`) — and `next_cursor` is
returned but unread. This is pre-existing behaviour the fix makes *reachable* for the
first time rather than behaviour the fix introduces; paging the dialog is UI work with
no acceptance criterion here. Reported to ORCH as a finding.

---

## 4. Decision (c) — `.addMembers` → **`addMember(id, userId: string)`**

**Decision: rename to `addMember`, narrow the signature to a single `userId: string`,
send `{ user_id: userId }`, and type the return as the real result object.**

Rationale, in order of weight:

1. **The backend's own recorded decision forbids the plural contract.**
   `resolve_member_user_id/1` (`identity.ex:525-537`) matches
   `%{"user_ids" => [first | _rest]}` and returns only `first`; everything after the
   first element is silently discarded. The comment at `identity.ex:483-489` records
   this as a deliberate R-Co port decision (that comment's own "OQ-2", from REQ-073's
   design — not this document's OQ numbering), **not** an oversight — so it will not
   change, and a client function promising bulk add can never be honoured. Under
   `core-directives.md`'s "Don't silently re-decide what a decision record already
   settled", the client is the side that must move.
2. `resolve_member_user_id/1`'s **first** clause matches `%{"user_id" => user_id}`, so
   the singular body is the backend's primary accepted shape, not a fallback.
3. **It mirrors the ISS-0736 correction exactly.** `removeMembers` had the identical
   defect — a plural array the backend could not honour — and was corrected to a single
   `userId` in the same file. Leaving `addMembers` plural would leave the two halves of
   one operation with contradictory contracts in adjacent lines.
4. **Against the scope boundary:** `groupsApi` and "the `GroupsPage.tsx` call sites that
   must change as a direct consequence" are both explicitly in scope. The sole caller
   (`GroupsPage.tsx:76`) already passes exactly one id, wrapped in an array literal
   `[userId]`; the change **removes a wrapper** and alters no behaviour. This is not
   scope creep — it is the minimum edit that makes the declared contract true.

`removeMembers` keeps its existing name. Renaming it to `removeMember` for symmetry is
**not** authorised: the scope boundary says `.removeMembers` must not be touched, and
`web/src/api/__tests__/identity.removeMembers.test.ts` asserts against it.

**Caller change — `GroupsPage.tsx:76`:**

| Before | After |
|---|---|
| `… => groupsApi.addMembers(id, [userId])` | `… => groupsApi.addMember(id, userId)` |

---

## 5. Decision (d) — `.list`: **correct the return type now**

**Decision: replace `PagedResponse<Group>` on `groupsApi.list` with a new
`GroupListResponse`. Do not modify `PagedResponse<T>` itself.**

Rationale:

1. `PagedResponse<T>` (`types/api.ts:20-26`) declares `page` and `page_size` as
   **required**; `handle_list_groups/2` never emits either (§1.3). The type is false
   today. It is benign only because all three consumers happen to read `.items` alone
   (§1.5) — a future `data.page_size` read gets `undefined` with no type error, which is
   the same silent-wrong-value class this whole run is about.
2. The cost is one new interface and zero call-site changes, **verified**: `GroupsPage.tsx:50`,
   `UserDetailPage.tsx:149` and `useAdminUsers.ts:47` read `.items` only, and `.total`
   is read nowhere. Correcting it now is strictly cheaper than a fourth pass over this
   file later.
3. `PagedResponse<T>` itself is **not** changed: it is also used by `usersApi.list` and
   `rolesApi.list`, both out of scope (ISS-0812). Narrowing only the `groupsApi.list`
   declaration keeps the change inside the boundary.

```
export interface GroupListResponse {
  items: Group[]
  total: number
}
```

`Group`'s own `is_system`-is-required lie is **not** corrected here — ISS-0811.

---

## 6. The resulting `groupsApi` surface

This is the exact post-fix shape. Signatures and types only.

```
groupsApi.list()                      => Promise<GroupListResponse>
  GET    /api/v1/identity/groups

groupsApi.create(body)                => Promise<Group>
  POST   /api/v1/identity/groups
  body: { name: string; display_name: string; description?: string }

groupsApi.delete(id: string)          => Promise<void>
  DELETE /api/v1/identity/groups/${id}

groupsApi.addMember(id: string,
                    userId: string)   => Promise<GroupMemberAddResult>
  POST   /api/v1/identity/groups/${id}/members
  body: { user_id: string }

groupsApi.removeMembers(id: string,
                        userId: string) => Promise<void>        [UNCHANGED]
  DELETE /api/v1/identity/groups/${id}/members/${userId}

groupsApi.members(id: string)         => Promise<GroupMemberPage>
  GET    /api/v1/identity/groups/${id}/members
```

Third new interface, in `web/src/types/api.ts` beside the other two — the exact shape of
`member_result_map/3` (`identity.ex:829-831`):

```
export interface GroupMemberAddResult {
  group_id: string
  user_id: string
  created: boolean
}
```

`create` keeps `Promise<Group>`: the wire body is one `group_map/1` object, and its
divergence from the `Group` interface is exactly ISS-0811's `is_system` item.
`delete` keeps `Promise<void>`: `Response.no_content/1` → HTTP 204, and `client.ts:163-165`
resolves `undefined` on 204.

### 6.1 Exact before/after URL literals

| fn | before | after |
|---|---|---|
| `list` | `'/api/v1/admin/groups'` | `'/api/v1/identity/groups'` |
| `get` | `` `/api/v1/admin/groups/${id}` `` | *function deleted* |
| `create` | `'/api/v1/admin/groups'` | `'/api/v1/identity/groups'` |
| `update` | `` `/api/v1/admin/groups/${id}` `` | *function deleted* |
| `delete` | `` `/api/v1/admin/groups/${id}` `` | `` `/api/v1/identity/groups/${id}` `` |
| `addMembers`→`addMember` | `` `/api/v1/admin/groups/${id}/members` `` | `` `/api/v1/identity/groups/${id}/members` `` |
| `removeMembers` | `` `/api/v1/identity/groups/${id}/members/${userId}` `` | *unchanged* |
| `members` | `` `/api/v1/admin/groups/${id}/members` `` | `` `/api/v1/identity/groups/${id}/members` `` |

After the change, the substring `/api/v1/admin/` must not appear anywhere in the
`groupsApi` object literal. It still appears elsewhere in `identity.ts` (`rolesApi`) —
that is ISS-0812's scope, so a whole-file absence assertion would fail and must not be
written.

---

## 7. Test matrix

**New file:** `web/src/api/__tests__/identity.groupsApi.test.ts`
**Owner:** `TEST-DESIGNER` (WF-03 Step 4). **Mirrors:**
`web/src/api/__tests__/identity.removeMembers.test.ts` — `// @vitest-environment jsdom`,
a `window.fetch` spy assigned from `vi.fn()`, `setToken`/`clearToken` in
`beforeEach`/`afterEach`, and assertions on the exact method + path actually requested.

**Guard constraint the implementer must honour.** `web/tests/guards/source-scan.spec.ts`
scans `web/src/**/*.{ts,tsx}`, which includes `__tests__/`, and
`web/tests/guards/forbidlist.ts`'s `raw-fetch-outside-client` pattern
(`/\bfetch\(|\baxios\(/`) allows only `web/src/api/client.ts`. Assign the spy
(`window.fetch = fetchSpy as unknown as typeof window.fetch`) as the ISS-0736 test does;
never write the literal text `fetch(`. Weakening the pattern is forbidden.

| # | ID | Assertion | Pre-fix | AC |
|---|---|---|---|---|
| 1 | `T-0765-LIST` | `list()` requests method `GET`, URL containing `/api/v1/identity/groups`, and **not** containing `/api/v1/admin/groups` | **FAILS** — emits `/api/v1/admin/groups` | 1, 2 |
| 2 | `T-0765-CREATE` | `create({name, display_name, description})` requests `POST` to `/api/v1/identity/groups`; parsed request body deep-equals the passed object | **FAILS** — wrong prefix | 1, 2 |
| 3 | `T-0765-DELETE` | `delete('g-1')` requests `DELETE` to `/api/v1/identity/groups/g-1` | **FAILS** — wrong prefix | 1, 2 |
| 4 | `T-0765-ADD-PATH` | `addMember('g-1','u-1')` requests `POST` to `/api/v1/identity/groups/g-1/members` | **FAILS** — function is named `addMembers` and emits the `/admin` prefix | 1, 2 |
| 5 | `T-0765-ADD-BODY` | that same request's parsed body deep-equals `{ user_id: 'u-1' }`, and `'user_ids' in body` is `false` | **FAILS** — body is `{user_ids:['u-1']}` | 1, 2 |
| 6 | `T-0765-ADD-ARITY` | `typeof groupsApi.addMember === 'function'` and `groupsApi.addMember.length === 2`; `'addMembers' in groupsApi` is `false` | **FAILS** — `addMember` is undefined | 1, 2 |
| 7 | `T-0765-MEMBERS-PATH` | `members('g-1')` requests `GET` to `/api/v1/identity/groups/g-1/members` | **FAILS** — wrong prefix | 1, 2 |
| 8 | `T-0765-MEMBERS-SHAPE` | with the spy resolving the real wire body `{"items":[<one user_map object>],"next_cursor":null,"count":1}`, the awaited value deep-equals that object — i.e. `result.items` has length 1, `result.count === 1`, `result.next_cursor === null`, and `Array.isArray(result) === false`. This is the explicit no-unwrap assertion for decision (b) | **FAILS** — the pre-fix call 404s, so `client.ts` throws `ApiError` before any body is read | 1, 2, 3 |
| 9 | `T-0765-NO-GET-UPDATE` | `'get' in groupsApi` is `false` **and** `'update' in groupsApi` is `false` | **FAILS** — both are present | 3 |
| 10 | `T-0765-SURFACE` | `Object.keys(groupsApi).sort()` deep-equals `['addMember','create','delete','list','members','removeMembers']` | **FAILS** — pre-fix keys include `get`, `update`, `addMembers` | 1, 3 |
| 11 | `T-0765-NO-ADMIN-PREFIX` | table-driven over all six surviving functions: invoke each with the spy, assert **no** captured URL contains `/api/v1/admin/`. One `it.each` row per function so a failure names the function | **FAILS** on 5 of 6 rows (`removeMembers` passes) | 1, 2 |
| 12 | `T-0765-REMOVE-UNCHANGED` | `removeMembers('g-1','u-1')` still requests `DELETE /api/v1/identity/groups/g-1/members/u-1` | **PASSES** pre-fix — see the note below | 2 |

**Row 12 is an enumeration row, not fail-first evidence.** It passes before and after the
fix by design: its job is to prove this run did not regress the ISS-0736 correction while
rewriting the object around it. WF-03 Step 4's fail-then-pass requirement is satisfied by
rows 1-11, each of which fails against the pre-fix commit. TEST-DESIGNER must state row
12's pre-fix PASS explicitly rather than letting it be read as a twelfth fail-first row.
`identity.removeMembers.test.ts` must be left exactly as it is; row 12 duplicates its
assertion deliberately so the `groupsApi` table is complete in one place.

**`.members`'s consumer change is covered by `npm run type-check`, not by a render
test — deliberately.** The failure mode is `members.map is not a function` in
`GroupsPage.tsx`'s members dialog. After §3's retype, any call site that treats
`GroupMemberPage` as an array is a compile error, so `tsc -b tsconfig.json` (AC3,
`web/package.json`'s `type-check` script, already inside `npm run check`) finds every
one on every run — a stronger and more durable detector than one render test of one
dialog. This is a decision, not an omitted test: no GroupsPage component test exists to
extend, and adding the project's first one is UI-test scope this run does not carry.

**Commands Step 4 must run and quote actual output for (AC3):**

```
cd web && npm run type-check
cd web && npm test
cd web && npm run guards
```

---

## 8. Acceptance-criterion → design-element map

| AC | Design element |
|---|---|
| **AC1** — `.addMembers/.list/.get/.update/.delete/.members` each call a URL prefix a real backend route serves, audited against the actual route table | §1.1 mount chain and §1.2 route list, both re-derived from source in this step; §1.4 per-function verdicts; §6.1 exact before/after URL literals. `.get`/`.update` are resolved by §2 (no route exists, so "calls a served prefix" is satisfied by their removal, not by a rewrite); the other four by the §6.1 substitutions. Tests: rows 1-5, 7, 11. |
| **AC2** — each corrected call has regression coverage mirroring `identity.removeMembers.test.ts` | §7: one row per corrected call — `list` (1), `create` (2), `delete` (3), `addMember` (4, 5, 6), `members` (7, 8) — in a new file that reuses the ISS-0736 file's jsdom + `window.fetch`-spy structure, plus the table-driven class guard (11) and the untouched-`removeMembers` row (12). |
| **AC3** — `npm run type-check` and the web test suite pass; any call with no backend route is removed or explicitly recorded as unimplemented | §2 removes `.get`/`.update` **and** leaves the recorded rationale comment (both halves of AC3's disjunction). §3's retype is what makes `type-check` a real detector rather than a formality; §5 removes the second type lie. §7 names the three commands whose actual output Step 4 must quote. Tests: rows 9, 10. |

---

## 9. Invariants

- **INV-A.** Every URL literal in the post-fix `groupsApi` object resolves to one of the
  six routes enumerated in §1.2. No literal under `groupsApi` contains `/api/v1/admin/`.
- **INV-B.** Every declared return type in `groupsApi` is the wire body of its route as
  transcribed in §1.3 — no shim, no unwrap, no reshaping inside `web/src/api/`
  (`frontend_developer_guide.md` §4 rule 1).
- **INV-C.** `groupsApi.removeMembers` and `identity.removeMembers.test.ts` are
  byte-unchanged by this fix.
- **INV-D.** `usersApi`, `rolesApi`, `tokensApi`, `PagedResponse<T>`, `CursorPage<T>`,
  `User` and `Group` are unmodified. Only additive interfaces are added to
  `web/src/types/api.ts`.
- **INV-E.** No file under `lib/`, `priv/repo/migrations/` or `test/` is modified.
- **INV-F.** No entry in `web/tests/guards/forbidlist.ts` is weakened, removed or
  `allowedPaths`-exempted for the new test file.

---

## 10. Open questions

**OQ-1 — the scope boundary's two clauses touch each other on `Group`.**
The boundary puts "the `Group`/member TypeScript types where they misdescribe the wire
shape" **in** scope, and the `is_system`/`member_count` absence from `group_map/1`
**out** (ISS-0811). `Group.is_system` is a member of both sets. This design resolves the
overlap in favour of the explicit carve-out: `Group` is left untouched, `GroupMember` is
new and additive, and `GroupListResponse` changes only the envelope around `Group`. If
CODE-DESIGN-VALIDATOR reads the boundary the other way, that is a rework of §5 and §3.1
only — no other section depends on it.

**OQ-2 — `GroupMemberPage.next_cursor` is typed and returned but never read.**
§3.3 records that the dialog is capped at 50 members. Whether to page the dialog, or to
send `page_size=200`, is a UI decision with no acceptance criterion in this run, and is
reported to ORCH rather than settled here. FRONTEND-DEV must **not** add a `page_size`
query param on its own initiative — that changes behaviour beyond the boundary.

---

## 11. Findings for ORCH (not fixed here, not already filed)

Each is new in this step and is **not** covered by ISS-0811/0812/0813. Reported per
`core-directives.md`'s "No Issue Left Local-Only"; CODE-DESIGNER does not allocate ids.

1. **`User.roles` and `User.created_at` are required but never emitted.**
   `web/src/types/api.ts:437,441` vs `user_map/1` (`identity.ex:729-740`), which emits
   `inserted_at`/`updated_at` and no `roles`. Affects every `usersApi` consumer. Same
   class as ISS-0811 but a different type and a different mapper, so not a duplicate.
   Suggested severity: MINOR.
2. **`CursorPage<T>.has_more` is never emitted by `Letflow.Api.Pagination.Page`**, whose
   `@derive` list (`pagination.ex:81`) is `[:items, :next_cursor, :count]`.
   `CursorPage<T>` is used by ~12 call sites across `web/src/api/` (`audit`,
   `definitions`, `dlq`, `instances`, `modules`, `promotions`, `services`, `tasks`).
   Whether every one of those routes uses `Pagination.Page` was **not** established in
   this step — the finding is that it needs its own audit, not that all 12 are wrong.
   Suggested severity: MINOR, pending that audit.
3. **The Step 1 diagnosis's `useAdminGroups` caller claim is wrong** (§1.5):
   `UserDetailPage.tsx:28,149` is a third consumer. Recorded so the handoff record does
   not carry the error forward; no separate issue needed if ORCH notes it on ISS-0765.
4. **The group-members dialog is capped at the first 50 members** (§3.3, OQ-2), with
   `next_cursor` returned and unread. Pre-existing, made reachable by this fix.
   Suggested severity: MINOR.
5. **`User.status` is declared uppercase but the wire emits lowercase.**
   `web/src/types/api.ts:435` declares `status?: 'ACTIVE' | 'INACTIVE'`, and
   `web/src/api/identity.ts:24` (`usersApi.update`) *sends* `'ACTIVE' | 'INACTIVE'`.
   `lib/letflow/identity/user.ex:41` is
   `field(:status, Ecto.Enum, values: [:active, :inactive])` and `user_map/1`
   (`lib/letflow/routers/identity.ex:735`) emits `Atom.to_string(user.status)` with no
   `String.upcase` anywhere in that router — so the wire value is `"active"`. Any
   `user.status === 'ACTIVE'` comparison in `web/` is therefore always false, and the
   uppercase value `usersApi.update` sends may not validate. This is a live
   value-domain mismatch, not only a type lie, and is distinct from findings 1-2.
   Out of scope here (`User`/`usersApi` belong to ISS-0812's surface).
   Suggested severity: MAJOR if any comparison or write depends on it — the specific
   audit ORCH should scope is "every read and write of `User.status` in `web/src/`".
