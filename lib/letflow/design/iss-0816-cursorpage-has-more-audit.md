# ISS-0816 — `CursorPage<T>.has_more` audit and type correction

**Run:** WF03-ISS0816-20260925 · **Step:** WF-03 Step 2 (fix design) · **Author:** CODE-DESIGNER
**Branch:** `feature/WF03-ISS0816-20260925`
**Authority for facts:** `handoffs/WF03-ISS0816-20260925/step-01-issue-fixer.json` (ISSUE-FIXER's
verified audit), spot-re-verified here (§2.1). `docs/issues/ISS-0816.yaml` is the issue record;
its original central premise is false and is marked so inline.
**Design only.** No implementation code. Type shapes and function signatures only.

**Revision 2 (rework iteration 1, 2026-09-24T23:11Z).** CODE-DESIGN-VALIDATOR returned FAIL on
gate artefact `handoffs/WF03-ISS0816-20260925/step-02b-design-gate.json` (commit `2da52436`). Two
blockers, both about T7's guard regex, both closed by one change — see §7.1. The validator
reproduced §8 items 2 and 3 to the character in its own worktree and upheld decision (c) as
justified; decisions (a), (b), (d), (e) and the §2 route table were confirmed unchanged. Four
non-blocking corrections were also applied: decision (c)'s justification now rests on INV-D rather
than on write corruption (§3(c)); `@default_page_size` is at `pagination.ex:51`, not `:53`; the
drain's behaviour at exactly the cap is now specified (§6.1); and §10's formerly unfiled row is
**ISS-0823**. A previously unstated consequence of §6.1 was also found and is now §6.3 and T9.

**Revision 3 (rework iteration 2, 2026-09-24T23:37Z).** CODE-DESIGN-VALIDATOR returned FAIL a
second time, narrowly, on `handoffs/WF03-ISS0816-20260925/step-02b-design-gate-rework1.json`
(commit `633a854d`). **Both original blockers are confirmed closed by measurement**, BLOCKER-2 in
the stronger way — `identity.groupsApi.test.ts:63` passes untouched *and* unexempted — and
decision (c)'s INV-D restatement was verified against `identity.ex:829-831`. **BLOCKER-3: the
word-versus-field diagnosis of revision 2 was right but did not go far enough.** Revision 2's regex
enumerated three ways to write the field and missed a fourth, ES6 shorthand, which is the
*commoner* spelling — with the tell that the renamed destructure `{ has_more: hasMore }` was caught
only because it happens to contain a colon. The gap is exploitable and was exploited: the exact
ISS-0816 defect, rewritten with shorthand, passes both gates. §7.1 now carries a five-alternative
regex and the A/B measurement that discriminates it; §7's "cannot reappear" overclaim is corrected;
§6.3 now states that the second ISS-0765 guard stays **green** and under-covers silently; T8's
offender fixture gains shorthand forms; and §8 item 8's count is corrected to 14 occurrences across
7 files.

---

## 1. The refuted premise, stated first

ISS-0816 was filed claiming that `lib/letflow/audit.ex` emits `has_more` on the wire, so a single
`CursorPage<T>` was covering two incompatible wire shapes. **That is false.**

- `lib/letflow/audit.ex:276`, `:295-297` is the return of the *internal* function
  `Letflow.Audit.list_entries/1`. It never reaches HTTP.
- `lib/letflow/routers/audit.ex:203-204` consumes that internal `has_more` and passes it to the
  private `next_cursor/2`, which turns it into a cursor.
- `lib/letflow/routers/audit.ex:308-320` (`page_body/2`) then hand-builds an INV-2 allowlist of
  exactly three string keys: `"items"`, `"next_cursor"`, `"count"`.

**No route in Letflow emits `has_more`.** `CursorPage<T>.has_more` therefore covers **zero** wire
shapes, not two. Designing from the original text would have produced the wrong fix — a split that
preserved `has_more` on the audit branch.

Consequence for this design: the correction is **deletion of the field**, plus a split along the
axis the backend genuinely varies on — a two-key `{items, next_cursor}` envelope versus a
three-key `{items, next_cursor, count}` envelope.

---

## 2. Ground truth: route → wire envelope

### 2.1 Spot-checks performed by this step

ISSUE-FIXER derived the route table by runtime introspection of `__authz_routes__/0`. This step
did not redo that; it re-read each response builder named in the table and confirms every row.
Key sets, read at HEAD of this branch:

| Response builder | Keys emitted | Confirmed |
|---|---|---|
| `lib/letflow/routers/audit.ex:308-320` `page_body/2` | `"items"`, `"next_cursor"`, `"count"` | YES |
| `lib/letflow/api/pagination.ex:81-82` `@derive {Jason.Encoder, only: [:items, :next_cursor, :count]}` | `items`, `next_cursor`, `count` | YES |
| `lib/letflow/routers/definitions.ex:454-458` `render_list_result/2` | `"items"`, `"next_cursor"` | YES |
| `lib/letflow/routers/definitions.ex:539-544` `render_search_result/2` | `"items"`, `"next_cursor"` | YES |
| `lib/letflow/routers/dlq.ex:140-144` `handle_list_result/2` | `"items"`, `"next_cursor"` | YES |
| `lib/letflow/routers/services.ex:131-135` `handle_list_result/2` | `"items"`, `"next_cursor"` | YES |
| `lib/letflow/routers/admin_services.ex:198-202` `handle_list_result/2` | `"items"`, `"next_cursor"` | YES |
| `lib/letflow/routers/promotions.ex:944-948` `render_list_reviews/2` | `"items"`, `"next_cursor"` | YES |
| `lib/letflow/routers/instances.ex:954-959` `render_page_result/3` | `"items"`, `"next_cursor"`, `"count"` | YES |
| `lib/letflow/routers/tasks.ex:269-275` `handle_list_result/2` | `"items"`, `"next_cursor"`, `"count"` | YES |
| `lib/letflow/routers/identity.ex:552` `Pagination.page_response/2` | `items`, `next_cursor`, `count` | YES |

Not one of the eleven emits `has_more`.

### 2.2 The canonical mapping (AC1, AC4 — record this, do not re-derive it)

**Two-key envelope `{items, next_cursor}` — 6 routes, 7 call sites**

| Route | Builder |
|---|---|
| `GET /api/v1/definitions` | `definitions.ex:454-458` |
| `GET /api/v1/definitions/search` | `definitions.ex:539-544` |
| `GET /api/v1/dlq` | `dlq.ex:140-144` |
| `GET /api/v1/services` | `services.ex:131-135` |
| `GET /api/v1/admin/services` | `admin_services.ex:198-202` |
| `GET /api/v1/promotions` | `promotions.ex:944-948` |
| `POST /api/v1/entities/query` | `run_query/4` (already typed `EntityRecordsPage`) |

**Three-key envelope `{items, next_cursor, count}`** — where `count === items.length` for the
current page only, never a cross-page total.

| Route | Builder |
|---|---|
| `GET /api/v1/audit` | `audit.ex:308-320` (hand-built) |
| `GET /api/v1/instances` | `instances.ex:954-959` (hand-built) |
| `GET /api/v1/tasks` | `tasks.ex:269-275` (hand-built) |
| `GET /api/v1/tasks/inbox` | `tasks.ex:269-275` (hand-built) |
| `GET /api/v1/tenants` | `Pagination.page_response/2` |
| `GET /api/v1/identity/users` | `Pagination.page_response/2` |
| `GET /api/v1/identity/groups/:id/members` | `identity.ex:552` `Pagination.page_response/2` |

**No route at all** — `GET /api/v1/admin/modules`, `GET /api/v1/admin/module-shares`.
`Letflow.Routers.ProcessModules` does not exist; `lib/letflow/router.ex:82` defers it to S5.
Filed as **ISS-0822**; out of scope here except for the type decision in §3(d).

---

## 3. Decisions

### (a) The two fabrication sites — DELETE, do not rename

`web/src/api/audit.ts:71` and `web/src/api/promotions.ts:265` both compute
`has_more: Boolean(response.next_cursor)` client-side. **Both are deleted outright. No renamed
derived value replaces them.**

Justification: zero production sites read the field (ISSUE-FIXER's grep: 0 reads, 2 writes), so
there is nothing to preserve. Every real pagination consumer already computes next-page
availability inline from `next_cursor` at the point of use — `AuditLogPage.tsx:81`,
`DlqPage.tsx:202/203/220`, `InstanceBoardPage.tsx:139`, `PromotionReviewListPage.tsx:72`. A
surviving derived boolean, however honestly named, would be a second, redundant spelling of
`next_cursor !== null` sitting in the API layer — exactly the position where a reader cannot tell
by inspection whether a field came off the wire or was manufactured. That ambiguity is the defect;
renaming preserves it.

`promotions.ts` additionally loses its whole `.then(...)` mapping: once `has_more` is gone the
callback is an identity transform over a response that is already exactly
`CursorPage<PromotionReviewListItem>`. The `get` is typed directly instead.

### (b) Collapsing the hand-rolled duplicates — GroupMemberPage YES, RawAuditPage YES, TenantListResponse NO

The rule applied, stated once so it is checkable: **this fix edits what it falsifies, and leaves
alone what it does not.**

| Type | Decision | Why |
|---|---|---|
| `RawAuditPage` (`audit.ts:37-41`, module-private) | **Delete**, use `CountedCursorPage<RawAuditEntry>` | File-local, not exported, zero external blast radius, and `audit.ts` is already being edited for (a). It is character-for-character the three-key shape. |
| `GroupMemberPage` (`api.ts:478-482`) | **Collapse to an alias**, exported name retained | Its docblock (`api.ts:475-476`) says "Not `CursorPage<T>`, which declares a `has_more` the backend never emits." This fix makes that statement false, so the comment must be rewritten regardless. Given the file is open at that line anyway, an alias is the cheaper correct edit than a rewritten comment above a duplicated literal shape. Keeping the **name** means **zero call-site churn** — `identity.ts:7` and `:63` are untouched by this decision. |
| `TenantListResponse` (`tenants.ts:22-26`) | **Leave alone** | Its comment cites `total`/`limit`/`offset`, not `has_more`. Nothing in this fix falsifies it. Collapsing it would be a cosmetic edit to a third file owned by an already-resolved issue (ISS-0711), widening the diff for no correctness gain. |

`TenantListResponse` is structurally identical to `CountedCursorPage<Tenant>` and may be collapsed
by a later tidy. It is recorded here as a **deliberate non-change**, so a future reader does not
read it as an oversight. No issue is filed: it is not a defect.

ISS-0765 created `GroupMemberPage` one day before this run (dec06da7). Retaining its exported name
means that run's work is preserved verbatim at every call site; only the declaration's right-hand
side and its docblock change.

### (c) AC3 GroupsPage — FOLLOW `next_cursor`. In scope. Not merely a truncation notice.

`groupsApi.members(id)` accepts no `cursor` and no `page_size`; `GroupsPage.tsx:54-56` calls it
once, `:60` reads `membersPage?.items ?? []`, and `next_cursor` appears nowhere in the file. The
backend default page size is **50** — `lib/letflow/api/pagination.ex:51 @default_page_size 50`,
reached via `identity.ex:546-548` → `parse_page_size_param(nil)` → `validate_page_size(nil)`.

A truncation notice alone is **rejected**, on a finding this step made that raises AC3 above
cosmetic display truncation:

> `GroupsPage.tsx:103-110` computes `availableUsers` by subtracting the member id set from the
> user list. If `members` stops at 50, every member from the 51st on is **absent from that set**,
> so they are offered in the "Add member" dropdown (`:203-206`) as if they were not members.

The dropdown is a **different control from the member list**, and it is *derived* from the
truncated set rather than merely displaying it. That is what a truncation notice cannot repair: a
notice placed over the member list tells the operator that list is incomplete, while the dropdown
beside it silently presents the missing members as addable. The page must therefore hold the
complete member set, and the cursor must be followed. This is INV-D (§9).

**Deliberately *not* claimed: state corruption.** `GroupMemberAddResult` carries
`created: boolean` (`web/src/types/api.ts:498-502`, `member_result_map/3` at
`lib/letflow/routers/identity.ex:829-831`), so the backend add is idempotent — re-adding an
existing member returns `created: false` and changes nothing. An earlier revision of this design
called the defect "a wrong write path, not a wrong display"; that framing is stronger than the
evidence supports and is withdrawn. The conclusion is unchanged, because it never depended on
corruption: a set difference computed from a truncated set is simply wrong, and it misleads the
operator at a control the notice does not cover.

`.members` is `GroupMemberPage`, not `CursorPage<T>`, so AC3 is independent of §4's type change
and could in principle be deferred. It is **kept in this run's scope** because ISS-0816's own AC3
names it, it is the only AC with runtime effect, and splitting it out would leave the issue
half-closed.

Mechanism chosen: **drain inside the API layer**, not `useInfiniteQuery`. `useInfiniteQuery`
appears nowhere in `web/src` (verified by grep), so using it here would introduce a new pagination
pattern for one dialog. Draining in `identity.ts` keeps `GroupsPage`'s single `useQuery` shape and
its `QueryStateBoundary` wiring unchanged. The drain is bounded and reports its own bound, so
AC3's "or explicitly states the list is truncated" branch is still satisfied in the pathological
case rather than being silently dropped.

### (d) Rows 7 and 8 (`modulesApi.list`, `modulesApi.listShares`) — keep `CursorPage<T>`, promise the least

Both target routes do not exist (ISS-0822). With no route there is no ground truth, so the type
cannot be derived — only chosen. **Chosen: the narrowed two-key `CursorPage<T>`, which after §4
means `modules.ts` needs no type edit at all**, only a provenance comment.

Justification: a consumer written against `{items, next_cursor}` stays correct whichever envelope
S5 eventually ships, because both candidate envelopes contain those two keys. Typing them
`CountedCursorPage<T>` would assert a `count` that nothing has ever sent — re-creating, on the
only two routes with no server at all, precisely the defect this run exists to remove. Where there
is no evidence, the type must make the weakest claim.

### (e) `EntityRecordsPage` — collapse to an alias of `CursorPage<T>` (consequence of (a)/§4)

`api.ts:370-377` declares `EntityRecordsPage` with a docblock whose entire stated reason for the
type's existence is that `CursorPage<T>` "would silently claim a field the API never sends". Once
`has_more` is deleted, `CursorPage<T>` **is** `{items, next_cursor}` and `EntityRecordsPage` is a
structurally identical twin carrying a now-false rationale. By the rule in (b) — edit what the fix
falsifies — it is collapsed to an alias, preserving the exported name and its `EntityRecord`
default type argument, so every call site is untouched.

---

## 4. Target type shapes

`web/src/types/api.ts` — the two envelope types:

```
export interface CursorPage<T> {
  items: T[]
  next_cursor: string | null
}

export interface CountedCursorPage<T> {
  items: T[]
  next_cursor: string | null
  count: number
}
```

Required docblock content (prose; exact wording at FRONTEND-DEV's discretion):

- On `CursorPage<T>`: the exact two-key envelope; the six routes of §2.2 that emit it; and an
  explicit statement that **no Letflow route emits `has_more`**, with
  `lib/letflow/routers/audit.ex:308-320` named as the place the internal `has_more` is dropped, so
  the next reader does not re-file this.
- On `CountedCursorPage<T>`: the exact three-key envelope; the seven routes of §2.2; and — carried
  over from `tenants.ts:25`, where it is currently stated for one route only — that `count` is
  `length(items)` **for the current page only, never a cross-page total**.

**This prose is compatible with T7's guard, by construction.** T7 (§7.1) matches only the *code*
forms of the token — an object-literal or type-member key, a property access, or a string-literal
key — precisely so that a docblock may name the field in order to say it does not exist. The
authoring rule that keeps it that way: **in prose, write the token inside backticks and never
immediately followed by a colon.** `` no Letflow route emits `has_more` `` is clean;
`has_more: never emitted` would be caught, because it is indistinguishable from a key. Verified by
measurement — §8 item 9.

Aliases, exported names retained so no call site changes:

```
export type EntityRecordsPage<T = EntityRecord> = CursorPage<T>
export type GroupMemberPage = CountedCursorPage<GroupMember>
```

Unchanged by this design: `PagedResponse<T>`, `GroupListResponse`, `TimelinePage`,
`TenantListResponse`.

---

## 5. Exact per-site before → after

Line numbers are as at HEAD of `feature/WF03-ISS0816-20260925` (`e512c53a`).

### 5.1 `web/src/types/api.ts`

| Line | Before | After |
|---|---|---|
| 17 | `has_more: boolean` inside `CursorPage<T>` | **deleted** |
| after 18 | — | new `CountedCursorPage<T>` interface (§4) |
| 13 | `/** Cursor-paginated list response (API-13) */` | expanded docblock per §4 |
| 370-377 | `EntityRecordsPage` interface + its `has_more` rationale comment | `export type EntityRecordsPage<T = EntityRecord> = CursorPage<T>`; comment rewritten to state it is the same two-key envelope, `has_more` sentence removed |
| 473-482 | `GroupMemberPage` interface + "declares a `has_more` the backend never emits" comment | `export type GroupMemberPage = CountedCursorPage<GroupMember>`; comment keeps the `pagination.ex:81` `@derive` citation, drops the `has_more` sentence |

### 5.2 Sites that move to `CountedCursorPage<T>` (three-key routes)

| # | Site | Before | After |
|---|---|---|---|
| 1 | `web/src/api/audit.ts:2` | `import type { CursorPage }` | `import type { CountedCursorPage }` |
| 2 | `web/src/api/audit.ts:37-41` | `interface RawAuditPage {...}` | **deleted** |
| 3 | `web/src/api/audit.ts:58` | `Promise<CursorPage<AuditEntry>>` | `Promise<CountedCursorPage<AuditEntry>>` |
| 4 | `web/src/api/audit.ts:59` | `client.get<RawAuditPage>` | `client.get<CountedCursorPage<RawAuditEntry>>` |
| 5 | `web/src/api/audit.ts:71` | `has_more: Boolean(response.next_cursor),` | `count: response.count,` |
| 6 | `web/src/pages/admin/AuditLogPage.tsx:6` | `import type { CursorPage }` | `import type { CountedCursorPage }` |
| 7 | `web/src/pages/admin/AuditLogPage.tsx:35` | `UseQueryResult<CursorPage<AuditEntry>>` | `UseQueryResult<CountedCursorPage<AuditEntry>>` |
| 8 | `web/src/api/instances.ts:5` | `CursorPage,` in the import block | `CountedCursorPage,` |
| 9 | `web/src/api/instances.ts:19` | `client.get<CursorPage<ProcessInstance>>` | `client.get<CountedCursorPage<ProcessInstance>>` |
| 10 | `web/src/api/tasks.ts:2` | `CursorPage` in the import list | `CountedCursorPage` |
| 11 | `web/src/api/tasks.ts:26` | `normalizeTaskPage(page: CursorPage<RawTask>): CursorPage<Task>` | `normalizeTaskPage(page: CountedCursorPage<RawTask>): CountedCursorPage<Task>` |
| 12 | `web/src/api/tasks.ts:39` | `.get<CursorPage<RawTask>>('/api/v1/tasks', …)` | `.get<CountedCursorPage<RawTask>>(…)` |
| 13 | `web/src/api/tasks.ts:59` | `.get<CursorPage<RawTask>>('/api/v1/tasks/inbox', …)` | `.get<CountedCursorPage<RawTask>>(…)` |

`normalizeTaskPage` keeps its object-spread shape, so `count` propagates without a new field
reference.

### 5.3 Sites that stay `CursorPage<T>` (two-key routes) — narrowing only, no edit

`definitions.ts:5/17/50/53`, `dlq.ts:3/75`, `services.ts:2/40/44`, `promotions.ts:2/253`.
These become correct the moment line 17 is deleted. **No text changes**, except promotions below.

### 5.4 `web/src/api/promotions.ts`

| Line | Before | After |
|---|---|---|
| 246-252 | docblock stating "`has_more` is client-derived" | rewritten: states the envelope is exactly `{items, next_cursor}` and that `CursorPage<T>` now models it exactly; the `has_more` sentence is removed |
| 253-266 | `list: (…): Promise<CursorPage<…>> => client.get<{ items; next_cursor }>(…).then((response) => ({ items, next_cursor, has_more }))` | the inline anonymous response type, the `.then` and its callback are all removed; `client.get<CursorPage<PromotionReviewListItem>>('/api/v1/promotions', {…})` is returned directly with the same query-param object |

### 5.5 `web/src/api/modules.ts` — no type change (decision (d))

Add one comment above `modulesApi.list` (`:44`) and `modulesApi.listShares` (`:61`) recording that
`/api/v1/admin/modules` and `/api/v1/admin/module-shares` have no server (`router.ex:82`, deferred
to S5, tracked as **ISS-0822**), and that `CursorPage<T>` here is the deliberate weakest claim
pending that route's arrival, not a verified shape.

### 5.6 `web/src/pages/dlq/__tests__/DlqPage.pagination.test.tsx` — compile-forced

`:78`, `:79`, `:80` drop their `has_more` keys. **This is not the ISS-0821 fix** — ISS-0821 is
about fixtures asserting a fictional wire shape and the absence of any fixture-to-contract
coupling. This one file is edited here because it is a **hard compile blocker**: its literals are
contextually typed by `Record<string, CursorPage<DlqEntry>>` at `:77`, and `tsconfig.app.json`'s
`include: ["src"]` puts `src/**/__tests__` inside `npm run type-check`. Measured — see §8 item 2.

The other three ISS-0821 sites are **not** touched: `PromotionReviewListPage.test.tsx:119/:270`
and `TaskInboxPage.test.tsx:134/:160` are cast through `as unknown as …` or fed to an untyped
`vi.fn()`, so excess-property checking never applies; `web/tests/e2e/obs04.timeline.e2e.spec.ts:72`
is outside `include: ["src"]`. All three were measured as non-breaking (§8 item 4).

---

## 6. AC3 — GroupsPage members drain

### 6.1 `web/src/api/identity.ts`

Current (`:62-63`):

```
members: (id: string) => Promise<GroupMemberPage>
```

Target — two exported functions on `groupsApi`:

```
members: (
  id: string,
  params?: { cursor?: string; page_size?: number },
) => Promise<GroupMemberPage>

listAllMembers: (
  id: string,
) => Promise<{ items: GroupMember[]; truncated: boolean }>
```

- `members/2` is the faithful single-page wire call. `params` is passed through as the query
  object in the same style as `usersApi.list`. Its return type is unchanged (`GroupMemberPage`,
  which §4 re-expresses as `CountedCursorPage<GroupMember>`). Existing callers passing only `id`
  keep compiling.
- `listAllMembers/1` is the bounded drain. Behaviour, stated as a contract rather than as code:
  - Requests successive pages with `page_size: 200` (`pagination.ex:50 @max_page_size 200` — the
    largest value the server accepts, so the fewest round trips).
  - Feeds each response's `next_cursor` into the next request's `cursor`.
  - Stops when `next_cursor` is `null`, concatenating every page's `items` in request order.
  - Never issues more than **20 requests** (a 4 000-member ceiling). The cap exists so a malformed
    or non-advancing cursor cannot spin the browser; it is a safety bound, not the expected path.
  - **`truncated` at exactly the cap.** `truncated` reports *whether members were left unfetched*,
    not whether the cap was reached. So after the 20th response: if its `next_cursor` is `null`,
    the drain terminated normally on its last permitted request and `truncated` is **`false`** —
    a group of exactly 4 000 members is complete, not truncated. `truncated` is **`true`** only
    when the 20th response's `next_cursor` is non-null, i.e. the server had more to give and the
    cap stopped the drain asking. A 21st request is never issued in either case. On every
    termination before the cap, `truncated` is `false`. T5 asserts the `true` branch; T5b asserts
    the boundary case.
  - Rejects on the first failed request, so `useQuery`'s existing error handling is unchanged.

`GroupMember` must be imported into `identity.ts` if it is not already.

### 6.2 `web/src/pages/admin/GroupsPage.tsx`

| Line | Before | After |
|---|---|---|
| 54-57 | `queryFn: () => groupsApi.members(activeGroupId)` | `queryFn: () => groupsApi.listAllMembers(activeGroupId)` |
| 60 | `const members = useMemo(() => membersPage?.items ?? [], [membersPage?.items])` | unchanged in shape — reads `.items` off the drain result |
| 103-110 | `availableUsers` subtracts `members` from the user list | unchanged — now correct, because `members` is complete |
| ~223 ("Current members" heading block) | no truncation affordance | when the drain returns `truncated: true`, render an explicit notice above the member list stating the list is capped and how many are displayed |

The query key `tenantKeys.admin.groupMembers(activeGroupId)` is unchanged. No new react-query
pattern is introduced.

**Separate defect, NOT fixed here — reported to ORCH for filing.** `GroupsPage.tsx:62-66` fetches
`usersApi.list({ page_size: 200 })` and never follows that response's `next_cursor` either. A
tenant with more than 200 users gets an "Add member" dropdown missing everyone past the 200th.
That is the same class as AC3 but a different query, a different endpoint, and outside ISS-0816's
stated scope. It has since been filed as **ISS-0823** (queue task 823, GH #1814, commit
`ea1a43a4`); it is not fixed by this run.

### 6.3 `web/src/api/__tests__/identity.groupsApi.test.ts` — two ISS-0765 tests must be extended, and **only one of them will tell you so**

Adding `listAllMembers` to `groupsApi` is a **seventh** key on that object. Two ISS-0765 tests are
affected, and **they behave differently — that asymmetry is the whole point of this subsection.**
Both are read directly from the file, not inferred.

**1. `:229` T-0765-SURFACE — goes RED. You cannot miss it.**

```
expect(Object.keys(groupsApi).sort()).toEqual(
  ['addMember','create','delete','list','members','removeMembers'])
```

An exact-equality assertion over the live object's keys, so a seventh key fails it immediately.
Fix: insert `'listAllMembers'` in sort order, **between `'list'` and `'members'`**.

**2. `:252-259` T-0765-NO-ADMIN-PREFIX — stays GREEN, and silently under-covers.**

It drives `it.each(surfaceRows)` over a **hand-maintained array**, not over `Object.keys(groupsApi)`.
A seventh function on the object therefore never produces a seventh case: the suite goes from 16 to
16 green tests, nothing turns red, and the new function is simply never checked for the
`/api/v1/admin/` prefix. **The row must be added deliberately, not in response to a failing test.**
An implementer who fixes only the one assertion that went red ships a `groupsApi` function outside
ISS-0765's prefix guard with no signal anywhere that coverage was lost — which is precisely the
quiet-degradation failure mode this run exists to stop.

The array's own comment states the intent it cannot itself enforce: it "must enumerate EVERY
surviving function, so that adding a seventh one with a bad prefix is caught without anyone
remembering to write a bespoke row for it." Honouring it requires
`['listAllMembers', () => groupsApi.listAllMembers('g-1')]`. That row works unmodified: the shared
spy returns `WIRE_MEMBER_PAGE`, whose `next_cursor` is `null`, so the drain terminates after a
single request and the row's two URL assertions apply exactly as they do for `members`.

Neither test is a defect; both are ISS-0765's guards behaving as written. They are named here so
FRONTEND-DEV does not meet the red one as a surprise **and does not miss the green one entirely** —
this is T9. Applied as specified, the file goes 16 → 17 green.

`:63` of the same file carries the prose comment ``No `has_more` — Pagination.Page never emits
one.`` It is **truthful, in scope for T7's glob, and deliberately left untouched.** It is the
concrete case that proved T7's original bare-token regex wrong; see §7.1.

---

## 7. Test matrix

Every row is runnable under `web/`. T1-T3 are the gate for AC4; T4, T5, T5b and T6 cover AC3's new
behaviour and T9 keeps ISS-0765's surface guards green alongside it; T7-T8 close the recurrence
class that let this defect survive five written sightings.

| ID | AC | What it proves | How | Location |
|---|---|---|---|---|
| **T1** | AC2, AC4 | The narrowed and new types compile across all 15 call sites | `npm run type-check` (`tsc -b tsconfig.json`) exits 0 | CI + local |
| **T2** | AC2 | No behavioural regression from the retype | `npm run test` — the full vitest suite stays green (890 tests at baseline) | existing suite |
| **T3** | AC2 | The guard suite still passes with the new forbid-list entry | `npm run guards` | `web/tests/guards/` |
| **T4** | AC3 | `listAllMembers` concatenates across pages and forwards the cursor | Unit test: stub `client.get` to return page 1 `{items:[m1], next_cursor:'c2', count:1}` then page 2 `{items:[m2], next_cursor:null, count:1}`; assert the result is `{items:[m1,m2], truncated:false}` and that the second request carried `cursor: 'c2'` | new `web/src/api/__tests__/identity.members.test.ts` |
| **T5** | AC3 | The drain's bound holds and reports itself | Unit test: stub `client.get` to always return a non-null `next_cursor`; assert exactly 20 requests are made and the result is `truncated: true` | same file as T4 |
| **T6** | AC3 | The re-add bug is gone — a second-page member is excluded from the dropdown | Component test on `GroupsPage`: mock `groupsApi.listAllMembers` to resolve a member set spanning two pages including user `u-51`, mock `usersApi.list` to include `u-51`; assert `u-51` is **not** rendered as an `<option>` in the "Add member" select | new `web/src/pages/admin/__tests__/GroupsPage.members.test.tsx` |
| **T5b** | AC3 | The cap boundary reports honestly | Unit test: stub `client.get` so the 20th response has `next_cursor: null`; assert exactly 20 requests and `truncated: false` — reaching the cap is not by itself truncation (§6.1) | same file as T4 |
| **T7** | AC2, AC4 | Every realistic *code* spelling of a reintroduced `has_more` field is caught in production source, while prose naming the field stays legal. **This is a backstop, not a proof of impossibility** — see §7.1's "What this guard does and does not prove" | New `PATTERNS` entry in `web/tests/guards/forbidlist.ts` — full spec in §7.1 | `web/tests/guards/forbidlist.ts` |
| **T8** | AC2 | T7's pattern is itself two-sided, per GRD-UI-04 | `web/tests/guards/meta-control.spec.ts` iterates every `PATTERNS` entry and requires both fixtures — full spec in §7.1 | `web/tests/guards/fixtures/{offender,bystander}/has-more-wire-field.txt` |
| **T9** | AC3 | ISS-0765's surface guards still *cover* a seventh `groupsApi` function — not merely still pass | Two edits, and **only the first is prompted by a red test**: (i) extend `identity.groupsApi.test.ts:229`'s exact-equality key list with `'listAllMembers'`, in sort order between `'list'` and `'members'` — this one goes red on its own; (ii) add `['listAllMembers', () => groupsApi.listAllMembers('g-1')]` to the hand-maintained `surfaceRows` array at `:252-259` — **this one never goes red**, because `it.each` iterates the array, not the object, so omitting it silently drops the new function from ISS-0765's `/api/v1/admin/` prefix coverage. Per §6.3. Applied as specified: 16 → 17 green | `web/src/api/__tests__/identity.groupsApi.test.ts` |

### 7.1 T7 — the guard pattern, corrected (rework iteration 1)

**What was wrong.** Revision 1 specified T7 as a **bare-token** match on `has_more`. That produced
two defects the gate caught, both real:

1. **It contradicted §4.** §4 requires the `CursorPage<T>` docblock in `web/src/types/api.ts` to
   state that no route emits `has_more`. A bare-token guard forbids writing that sentence.
   FRONTEND-DEV following both sections literally would write the docblock and then fail
   `npm run guards`.
2. **Its exemption list was incomplete.** `web/src/api/__tests__/identity.groupsApi.test.ts:63`
   carries the truthful prose comment ``No `has_more` — Pagination.Page never emits one.`` It is
   inside `source-scan.spec.ts`'s glob (`web/src/**/*.{ts,tsx,css}` — there is **no** `__tests__`
   exclusion), it is never edited by §5, and it was not exempted. §8 item 8 missed it because that
   grep was filtered with `grep -v __tests__` while T7 is `appliesTo: 'source'`; §5.6 had already
   reasoned correctly that `src/**/__tests__` is inside tsc's scope but did not carry the same
   reasoning across to the guard.

**The correction: match the code form, not the token.** One change closes both, because both
defects are the same mistake — banning a *word* when the invariant is about a *field*.

**What revision 2 then got wrong (BLOCKER-3), and why it mattered.** Revision 2 applied that
correction but enumerated only *three* code forms. ES6 **shorthand** is a fourth, and it is the
commoner spelling of the two. The asymmetry gives the gap away: the *renamed* destructure
`{ has_more: hasMore }` was caught, but only incidentally, because it happens to contain a colon —
while plain `{ ..., has_more }` was not. That is not a theoretical hole. The exact ISS-0816 defect,
respelled with shorthand in the very `.then` callback §5.4 removes, **passes both gates**:

```ts
const has_more = Boolean(response.next_cursor)
return { items: response.items, next_cursor: response.next_cursor, has_more }
```

Measured independently by this step, not inherited — §8 item 12. Under revision 2's regex,
`source-scan` reported **zero** violations and `tsc -b --force` exited **0**. The `tsc` half is not
a surprise: it is the same behaviour §8 item 3 already recorded, that this return position is not
freshness-checked. **T7 is therefore the only guard standing at the one spot where the type system
provably cannot help, and as written it did not fire there.**

**The corrected pattern — five alternatives:**

```
name:        'has-more-wire-field'
regex:       /\.has_more\b|\bhas_more\s*\??\s*:|["']has_more["']|\bhas_more\s*[,}]|\b(?:const|let|var)\s+has_more\b/
appliesTo:   'source'
rationale:   'ISS-0816'
allowedPaths: [
  'web/src/pages/promotions/__tests__/PromotionReviewListPage.test.tsx',
  'web/src/pages/tasks/__tests__/TaskInboxPage.test.tsx',
]
```

One alternative per way TypeScript can write the field:

| # | Alternative | Catches |
|---|---|---|
| 1 | `\.has_more\b` | property access — `response.has_more`, `page?.has_more` |
| 2 | `\bhas_more\s*\??\s*:` | object-literal key, type member, optional member, renamed destructure — `has_more: false`, `has_more: boolean`, `has_more?: boolean`, `{ has_more: hasMore }` |
| 3 | `["']has_more["']` | string-literal key — `page['has_more']`, `"has_more"` |
| 4 | `\bhas_more\s*[,}]` | **ES6 shorthand** — `{ items, next_cursor, has_more }`, `{ has_more }`, `const { has_more } = page`, `function f({ has_more })`, and the multi-line form where the closing brace is on a later line (`\s` spans newlines, and `source-scan` tests whole-file content before locating a line) |
| 5 | `\b(?:const\|let\|var)\s+has_more\b` | a local binding of that name, which is how shorthand gets something to be shorthand *for* |

Alternatives 4 and 5 are deliberately both present rather than either alone: 5 catches the defect at
its declaration even when the literal is built somewhere the other four cannot see, and 4 catches a
shorthand whose binding came from a destructure or a parameter rather than a declaration.

**Prose stays unaffected, by construction.** A comment names the field inside backticks, and the
character after a closing backtick is a backtick — which is neither whitespace, nor a colon, nor a
comma, nor a brace. `` Not `has_more`, which no route sends `` and `` `has_more`: never emitted ``
are both clean; verified as explicit cases in §8 item 12's must-not set.

**What this guard does and does not prove.** It catches every realistic code spelling of the field
— that is what §8 item 12's 42-form battery and item 13's A/B reintroduction measure. It is **not**
a proof that the field can never reappear: a binding obtained from a function parameter typed only
by inference, or a key assembled by string concatenation, would evade it. Those are not how this
defect has ever been written, here or in the five prior sightings, and widening the regex far
enough to cover them would start matching prose again — which is what caused BLOCKER-1. T7 is a
backstop against recurrence, and the durable fix for the class remains ISS-0813's mechanical
coupling of `web/src/types/api.ts` to the routers' real response bodies. Revision 2's claim that
T7 shows `has_more` "cannot reappear as a field in production source" was an overclaim and is
withdrawn; §7's T7 row now states the weaker, true thing.

**Final exemption set: exactly the two ISS-0821 files above, unchanged from revision 1.** Both
still fabricate `has_more: false`, which is a code form, so both still need exempting. `api.ts` and
`identity.groupsApi.test.ts` need **no** exemption under the narrowed regex — that is the whole
point of the narrowing. The `allowedPaths` entry carries an inline comment saying the two
exemptions are deleted when ISS-0821 lands.

**The cost of narrowing, stated rather than hidden.** A bare `has_more` in prose *outside*
backticks and not followed by `:`, `,` or `}` — for instance "the internal has_more never reaches
HTTP" — is not caught. That is accepted: it is prose, it cannot make a request or type a response,
and the invariant T7 defends (INV-A) is about declared and accessed fields. A guard that also
policed prose is what created BLOCKER-1.

**T8's two fixtures**, required by GRD-UI-04 (`meta-control.spec.ts` demands an offender and a
bystander for every `PATTERNS` entry, and asserts the regex matches the first and not the second):

- `fixtures/offender/has-more-wire-field.txt` — must exercise **all five** alternatives, so that
  each one is mechanically pinned rather than merely present in this document. Required contents:
  an object-literal key (`has_more: false`), a property access (`page.has_more`), a `const`
  declaration, an **ES6 shorthand** literal (`{ items, next_cursor, has_more }`), and a renamed
  destructure (`const { has_more: renamed } = body`). Alternative 4 is the one BLOCKER-3 was about;
  without a fixture form for it, it would be the only alternative no test protects, and the next
  edit to this regex could silently drop it again.
- `fixtures/bystander/has-more-wire-field.txt` — must contain everything the guard must never
  catch: the prose form inside backticks, prose with a backtick immediately followed by a comma and
  by a colon (the two forms alternatives 2 and 4 come closest to mis-firing on), a clean
  `{ items, next_cursor, count }` literal, and `TimelineFeed`'s camelCase `hasMore` as a type
  member, as a bare `const`, as an object shorthand and as a JSX attribute.

**The bystander's `hasMore` content is load-bearing.**
`web/src/components/instances/TimelineFeed.tsx:7/15/37` has a camelCase `hasMore: boolean` prop,
passed from `InstanceDetailPage.tsx:369` as
`hasMore={Boolean(timelineQuery.data?.next_cursor)}`. It is derived from `next_cursor` and is
entirely unrelated to `CursorPage<T>.has_more`. **It must not be touched, and T7's regex must not
match it.** The bystander fixture is the mechanical, permanent guarantee of that — not a comment
asking the next agent to be careful. Note that under the five-alternative regex this fixture now
also has to survive alternatives 4 and 5, which is why it carries `const hasMore = …` and
`{ items, hasMore }` as well as the type member and the JSX attribute.

Measured green end to end — §8 items 9 and 10 (revision 2's three-alternative form) and items 12,
13 and 14 (this revision's five-alternative form, including the A/B that discriminates them).

**No backend test changes.** Nothing in `lib/` changes under this design; §2.1 is verification of
existing behaviour, not a change to it.

---

## 8. Measured evidence (so §5 and §7 are not predictions)

This step trial-applied §4/§5's type edits in the working tree, measured, and reverted
(`git checkout -- web/`; tree confirmed clean before this document was written). Nothing from the
probe is committed. Results, on `feature/WF03-ISS0816-20260925` @ `e512c53a`:

1. **Baseline** — `npx tsc -b tsconfig.json --force` → exit 0.
2. **Deleting `api.ts:17` alone** → exit 2, exactly four errors, all `TS2353`:
   `src/api/audit.ts(71,7)`, `src/pages/dlq/__tests__/DlqPage.pagination.test.tsx(78,63)`,
   `(79,64)`, `(80,58)`. This is the complete compile-forced edit set, and it is why §5.6 must be
   in scope while the rest of ISS-0821 is not.
3. **`promotions.ts:265` did NOT error** — the `.then` callback's object literal is not
   freshness-checked in that position. Its removal is therefore a correctness/clarity edit under
   decision (a), not a compile requirement. Recorded so CODE-DESIGN-VALIDATOR does not read it as
   one.
4. **Full target shape applied** (new `CountedCursorPage<T>`; rows 1-13 of §5.2;
   `EntityRecordsPage` and `GroupMemberPage` aliases; both fabrications deleted; the three DlqPage
   fixture keys removed) → `tsc -b --force` exit **0**, zero errors.
5. **`npm run test` with that shape applied** → **125 test files, 890 tests, all passed**, 27.70 s.
6. **`npm run guards` with that shape applied** → **4 files, 48 tests, all passed** (this is the
   pre-T7 baseline; with T7 and its two fixtures added the count becomes 52 — item 10).
7. **Collapsing `TenantListResponse` into `CountedCursorPage<Tenant>` also type-checks clean** — so
   decision (b)'s "leave it alone" is a scope choice, not a technical constraint. Stated explicitly
   so the next reader knows it was tried, not merely skipped.
8. ~~**`grep -rn has_more web/src … | grep -v __tests__`** returned only three stale comments, so
   T7's guard is satisfiable with zero exemptions outside `__tests__`.~~ **WITHDRAWN — this claim
   was false, and the gate proved it.** The `grep -v __tests__` filter was the error: it excluded
   files that T7, being `appliesTo: 'source'`, does scan, because `source-scan.spec.ts`'s glob is
   `web/src/**/*.{ts,tsx,css}` with no `__tests__` exclusion. The unfiltered grep over `web/src` —
   T7's actual scope, and nothing wider — returns **14 occurrences across 7 files**, re-counted in
   rework 2 after the gate found the figure still slightly off. (Revision 2 said "eight files";
   that was `web/src` **plus** `web/tests`, whose only contributor is
   `web/tests/e2e/obs04.timeline.e2e.spec.ts:72` — outside `src/**` and therefore never scanned by
   `source-scan`. Mixing the two scopes in the paragraph whose whole job is to replace a bad
   measurement was worth correcting.) With §5's edits applied, the ones that
   survive are: the new `api.ts` docblock prose (required by §4), `identity.groupsApi.test.ts:63`'s
   truthful prose comment, and the four ISS-0821 fixture literals in two files. Under revision 1's
   bare-token regex the validator measured **two** source-scan violations —
   `web/src/types/api.ts:14` and `web/src/api/__tests__/identity.groupsApi.test.ts:63`. Under the
   narrowed regex of §7.1, both are clean and the correct exemption set is the two ISS-0821 files
   only — item 10.

**Rework iteration 1 added the following measurements.** The probe was re-applied with §4's real
docblock prose, §5's full edit set, §7.1's narrowed `PATTERNS` entry and T8's two fixtures, then
reverted (`git checkout -- web/`, `git clean -fd web/tests/guards/fixtures`; tree confirmed clean).

9. **The narrowed regex was checked against 20 hand-built strings before being wired in** — 10 that
   must match and 10 that must not. All 20 behaved correctly. The must-match set covers
   `has_more: boolean`, `has_more?: boolean`, `has_more: Boolean(...)`, three real fixture
   literals, `response.has_more`, `page['has_more']`, `if (page.has_more)` and `"has_more" =>`.
   The must-not set covers all four real prose comments in the tree, the two docblock sentences
   §4 requires, a backtick-then-colon prose form, and three `hasMore` forms from `TimelineFeed`.
10. **`npm run guards` with the narrowed T7, its fixtures and §5 applied → 4 files, 52 tests, all
    passed** (up from 48; the 4 new ones are T8's fixture assertions). `source-scan` reported
    **zero** violations with `api.ts` carrying §4's required `has_more` prose and
    `identity.groupsApi.test.ts:63` untouched and unexempted. This is the direct proof that
    BLOCKER-1 and BLOCKER-2 are both closed by the single narrowing.
11. **`tsc -b --force` → exit 0 and `npm run test` → 125 files / 890 tests passed** on that same
    probe, which also carried the fuller `promotions.ts` restructure of §5.4 (the whole `.then`
    and its inline anonymous response type removed, not just the `has_more` key).

**Rework iteration 2 re-measured the regex from scratch rather than inheriting the gate's numbers,
and added the A/B that discriminates the two versions.** Same probe discipline: applied, measured,
reverted with `git checkout -- web/` plus `git clean -fdq web/tests/guards/fixtures`, tree confirmed
clean before this revision was written.

12. **The five-alternative regex was checked against a 42-form battery** — 27 must-match, 15
    must-not. **0 missed, 0 false positives.** The must-match set covers all five alternatives
    explicitly, including eight shorthand and declaration forms revision 2's regex would have let
    through (`{ items, next_cursor, has_more }`, `{ has_more }`, `return {has_more}`,
    `const { has_more } = page`, `function f({ has_more })`, `const`/`let`/`var` declarations, and
    the multi-line literal where the closing brace is two lines below the field). The must-not set
    covers all four real prose comments in the tree, the two docblock sentences §4 requires,
    backtick-then-colon **and** backtick-then-comma **and** backtick-then-brace prose forms — the
    three shapes alternatives 2 and 4 come closest to mis-firing on — and six `TimelineFeed`
    `hasMore` forms including the shorthand and `const` spellings that only alternatives 4 and 5
    could have caught.
13. **The A/B reintroduction — the discriminating measurement.** The exact ISS-0816 defect was
    written back into `promotions.ts`'s `list`, in the `.then` callback §5.4 removes, spelled with
    shorthand (`const has_more = Boolean(response.next_cursor)` then
    `return { items: …, next_cursor: …, has_more }`).
    - **A — revision 2's three-alternative regex:** `tsc -b --force` exit **0** *and* `source-scan`
      **0 violations**. Both gates pass the reintroduced defect. BLOCKER-3 reproduced exactly.
    - **B — this revision's five-alternative regex, same defect, nothing else changed:**
      `source-scan` **FAILS** — `Source scan found 1 violation(s): has-more-wire-field @
      web/src/api/promotions.ts:262` — while `tsc -b --force` still exits **0**.

    The `tsc` result being identical in both arms is the point, not an aside: it is the same
    non-freshness-checked return position §8 item 3 already recorded, so the type system cannot
    help here in either arm. T7 is the only gate that moves, and only under the corrected regex.
14. **Clean tree under the corrected regex** (defect removed, everything else as in B):
    `tsc -b --force` exit **0**; `npm run guards` → **4 files, 52 tests, all passed** with
    `source-scan` at **zero** violations and all four `has-more-wire-field` fixture assertions
    green against the extended offender; `npm run test` → **125 files, 890 tests, all passed**.

The probe did **not** include §6 (the GroupsPage drain and the `groupsApi` surface), which is new
behaviour rather than a retype; T4, T5, T5b, T6 and T9 are its evidence and FRONTEND-DEV must
produce them. §6.3's two assertions are read verbatim from
`web/src/api/__tests__/identity.groupsApi.test.ts` at `:229` and `:252-259` rather than measured,
and are stated as such — including the claim that the second one stays green, which follows from
`it.each` iterating `surfaceRows` rather than `Object.keys(groupsApi)`, visible at `:261`.

---

## 9. Invariants

- **INV-A.** No frontend type may declare, and no frontend code may read, a field that no
  `lib/letflow/routers/*.ex` response builder emits. This is the invariant ISS-0816 violated. T7
  **backstops** the `has_more` instance of it, across every realistic code spelling (§7.1); §7.1's
  narrowing is what keeps T7 aimed at declared, bound and accessed fields rather than at prose that
  merely names one, and §7.1's "what this guard does and does not prove" states where the backstop
  ends. The general mechanism remains missing and is ISS-0813 (MAJOR, open) — this design does not
  close it and does not claim to. BLOCKER-3 is the evidence for why that distinction matters: a
  guard is only as good as its enumeration of the forms it scans for, and enumeration is exactly
  what a generated client would not need.
- **INV-B.** `count` is `length(items)` for the current page. It is never a cross-page total and
  must never be rendered as one — that is exactly what ISS-0711 was. `CountedCursorPage<T>`'s
  docblock carries this.
- **INV-C.** Next-page availability is derived from `next_cursor !== null` at the point of use.
  No API-layer function may return a pre-derived boolean for it.
- **INV-D.** A control that is *derived* from a fetched collection — a set difference, a count, an
  availability check, such as `GroupsPage.availableUsers` — must be derived from the **complete**
  collection, not from one page of it. A truncation notice does not satisfy this: the notice sits
  on the list, while the wrong value is presented at a different control the notice says nothing
  about. This is the whole of decision (c)'s justification; it does not depend on any claim about
  corrupted writes, and the backend add is in fact idempotent (`GroupMemberAddResult.created`).
- **INV-E (INV-2, backend, unchanged).** Response bodies stay hand-built allowlists. Nothing in
  this design touches `lib/`.

---

## 10. Out of scope — filed, do not fix here

| Issue | Subject |
|---|---|
| **ISS-0820** | Dead `limit`/`offset` params on `definitionsApi.search` (`definitions.ts:50`); `handle_search/1` reads only `q`, `cursor`, `page_size` |
| **ISS-0821** | Four fixtures hand-writing `has_more`. Only `DlqPage.pagination.test.tsx` is touched here, and only because it will not compile otherwise (§5.6) |
| **ISS-0822** | `Letflow.Routers.ProcessModules` does not exist; `modulesApi.list`/`listShares` call routes with no server |
| **ISS-0813** | No mechanism couples `web/src/types/api.ts` to real router response bodies |
| ISS-0811, ISS-0812, ISS-0814, ISS-0815 | Same symptom class, separate endpoints |
| **ISS-0823** | `GroupsPage.tsx:62-66` `usersApi.list({page_size: 200})` never follows `next_cursor`, so the Add-member dropdown omits everyone past the 200th user — §6.2. Found by this step, filed mid-gate (queue task 823, GH #1814, commit `ea1a43a4`). Same INV-D class as decision (c), different query and endpoint |

---

## 11. Open questions

**OQ-1 — `count` on `AuditLogPage`: display it, or leave it unused?** §5.2 row 5 replaces the
fabricated `has_more` with the real `count: response.count`, making `auditApi.list` a faithful
mirror of the wire body. No consumer currently reads it. FRONTEND-DEV should **not** invent a UI
for it in this run; whether the audit table should show a per-page count is a product question,
not a defect. Recorded rather than silently decided.

**OQ-2 — the drain's 20-request cap.** 20 × 200 = 4 000 members is chosen as a safety bound, not
derived from any measured group size; no requirement states a maximum group size. If a real
deployment exceeds it, the dialog degrades to a truncation notice rather than failing. If a
maximum group size is ever specified, this constant should be re-derived from it. The *behaviour*
at the cap is not an open question — §6.1 specifies it exactly, including the boundary case where
the 20th response is the last one, and T5b tests it.

**OQ-3 — should the two-key/three-key split be generated rather than hand-maintained?** §2.2's
table is correct today and will drift the moment a router changes its response builder. Closing
that is ISS-0813's job, not this run's; noted so the mapping is not mistaken for a durable
guarantee.

---

## 12. Acceptance-criteria coverage

| AC (queue task 816) | Where satisfied | Concrete element |
|---|---|---|
| **AC1** — every `CursorPage<T>` call site audited and mapped to the route it consumes, recording whether that route emits `has_more` | §2.1, §2.2, §5.2, §5.3 | 15 sites carried forward from ISSUE-FIXER's table; all 11 response builders re-read and confirmed here; per-site before/after given at file:line |
| **AC2** — the type or types corrected so no call site is promised a `has_more` the route never sends | §3(a), §4, §5.1-§5.6 | `has_more` deleted from `CursorPage<T>`; `CountedCursorPage<T>` added; 13 sites retyped; both fabrications removed; measured exit-0 in §8 item 4 |
| **AC3** — the GroupsPage members dialog either follows `next_cursor` or explicitly states the list is truncated | §3(c), §6, §6.3 | `groupsApi.members/2` gains `cursor`/`page_size`; `groupsApi.listAllMembers/1` drains; GroupsPage consumes the drain; explicit truncation notice on the bounded-cap path, with the boundary case specified in §6.1; T4, T5, T5b, T6, T9 |
| **AC4** — `npm run type-check` passes and the route-to-shape mapping is recorded so a later reader need not re-derive it | §2.2, §4, §7 T1, §7.1, §8 | Mapping recorded as a table in this document **and** in the `CursorPage<T>`/`CountedCursorPage<T>` docblocks required by §4 — which §7.1's narrowed guard is specifically shaped to permit; `tsc -b` measured exit 0 in §8 items 4 and 11 |

No element of this design is TBD. Every open question in §11 is a question this fix deliberately
does *not* resolve, with the reason stated — none of them blocks implementation.
