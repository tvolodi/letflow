# ISS-0728 — CANDIDATE has no in-app navigation path to `/exam`

Design only. No implementation code below — signatures and prose diffs only, per
CODE-DESIGNER's own scope fence. Source of truth is `docs/issues/ISS-0728.yaml` (queue
task 725), re-verified directly against `web/src/components/layout/AppShell.tsx`,
`web/src/pages/dashboard/TenantDashboardPage.tsx`,
`web/src/components/ui/PermissionDenied.tsx`, `web/src/components/ui/QueryStateBoundary.tsx`,
`web/src/utils/classifyError.ts`, `web/src/router.tsx`,
`web/src/components/layout/__tests__/AppShell.bilimbaga.test.tsx`,
`web/src/types/api.ts`, and `lib/letflow/api/authorization.ex` (all read in full or in the
relevant section) — not re-derived from the issue's own description alone.

This is UI-only (frontend nav-gating + a shared fallback component's CTA target). No
migration, no route/permission change on the backend. Baseline commit for this design:
`9ef91dcf` (origin/main tip at session start).

---

## 0. Root cause, confirmed by direct read

`AppShell.tsx:11` declares:

```
type Role = 'PLATFORM_ADMIN' | 'PROCESS_DESIGNER' | 'PROCESS_OPERATOR' | 'TASK_WORKER'
```

`CANDIDATE` is not a member. `NAV_ITEMS` (`AppShell.tsx:19-42`) is an array of
`{ to, label, roles: Role[] }`; `visibleNav` (`AppShell.tsx:66-68`) filters it via
`n.roles.some((r) => session?.roles.includes(r))`. `session.roles` itself is typed
`string[]` (`types/api.ts:340` et al, `UserSession.roles`) — **not** `Role[]` — so
`Role` is purely a closed set of *known, nav-gateable* role strings; it does not
constrain what a real session can actually contain. A CANDIDATE session's roles array
contains the string `"CANDIDATE"`, which matches zero `NAV_ITEMS` entries today, so
`visibleNav` is empty for that role. The sidebar renders no links; only "Sign out" is
always rendered (`AppShell.tsx:143-158`, outside `visibleNav`).

Separately, `TenantDashboardPage.tsx` (the `/` / `index` route, per `router.tsx:44`)
fires three queries unconditionally (`definitionsApi.list`, `instancesApi.list`,
`tasksApi.list`). CANDIDATE holds none of the permissions those three endpoints require
(confirmed: `lib/letflow/api/authorization.ex`'s `role_allows?(:CANDIDATE, ...)` clause,
lines 1033-1042, is the ISS-0646/decision-0013 closed six-permission set — it does not
include `:EntitiesQuery`/instance-read/task-read grants), so `definitionsApi.list`
403s. `TenantDashboardPage.tsx:41` derives `rendererState` from **only** the
definitions query's error (`errorDefs ? classifyError(defsError) : 'success'`);
`classifyError` (`utils/classifyError.ts`) maps a 403 to `'permission-denied'`;
`QueryStateBoundary` (`components/ui/QueryStateBoundary.tsx:56-57`) renders
`<PermissionDenied />` for that state. `PermissionDenied.tsx` is a hardcoded,
role-agnostic component: "You do not have access to this area. Contact your tenant
administrator." plus a `<Link to="/tasks">My Tasks</Link>` — which CANDIDATE also
cannot usefully reach for the same permission reason, and which is not where exams
live anyway. This is the "generic no-access message" the issue describes.

`/exam` itself is a real, working, router-registered, `ProtectedRoute`-gated route
(`router.tsx:59`, `{ path: 'exam', element: <ExamListPage /> }`) — confirmed already
fixed for hard-navigation by ISS-0726 (resolved, commit `073a17c9`) and already reading
via a CANDIDATE-reachable backend route per ISS-0718
(`lib/letflow/design/iss0718-candidate-exam-list-route.md`, gated on CANDIDATE's
existing `:ExamSessionStart` permission). **This issue is discoverability only** — the
destination works once reached; nothing here touches the route, the backend, or
`ExamListPage.tsx`.

---

## 1. `Role` type: add `CANDIDATE`

`AppShell.tsx:11` changes from:

```
type Role = 'PLATFORM_ADMIN' | 'PROCESS_DESIGNER' | 'PROCESS_OPERATOR' | 'TASK_WORKER'
```

to:

```
type Role = 'PLATFORM_ADMIN' | 'PROCESS_DESIGNER' | 'PROCESS_OPERATOR' | 'TASK_WORKER' | 'CANDIDATE'
```

**Exhaustiveness check (performed, not assumed):** `Role` is declared and used
exclusively within `AppShell.tsx` — grepped `web/src/**/*.{ts,tsx}` for `type Role`,
`: Role`, and `Role[]`; the only three matches in the whole tree are the declaration
itself and the `NAV_ITEMS: NavItem[]`/`roles: Role[]` field, both in this file. There
is no `switch`/exhaustive-match over `Role`'s member set anywhere (the file's only
`switch` is `QueryStateBoundary.tsx`'s, which switches over `RendererState`, an
unrelated type). `session.roles` (the array actually compared against) is `string[]`
(`types/api.ts`), so widening `Role`'s union does not change the type of anything the
session object carries — it only widens what `NAV_ITEMS` entries may declare.
**Adding this member is additive-only; no other call site requires a new case.**

---

## 2. `NAV_ITEMS`: new entry gated on `CANDIDATE`

Add one entry to the `NAV_ITEMS` array (`AppShell.tsx:19-42`):

```
{ to: '/exam', label: 'Exams', roles: ['CANDIDATE'] }
```

- **`to: '/exam'`** — the existing, already-working route (`router.tsx:59`); not a new
  path.
- **`label: 'Exams'`** — matches this file's existing label convention (plural noun for
  a list screen: "Instances", "Definitions"; "My Tasks" is the one first-person
  exception, kept because it names an inbox rather than a catalog — "Exams" fits the
  catalog naming, since `ExamListPage` lists every currently-startable exam, not "my"
  exams specifically).
- **No icon** — confirmed by reading the full `NAV_ITEMS` render (`AppShell.tsx:99-127`
  via the `<NavLink>` map): no existing entry carries an icon field; `NavItem` has no
  icon field at all. Following that convention exactly — not introducing an icon field
  for one entry only.
- **Ordering:** insert immediately after the existing `{ to: '/tasks', label: 'My
  Tasks', ... }` entry (currently `AppShell.tsx:21`) and before `{ to: '/definitions',
  ... }`. Rationale: `NAV_ITEMS`' existing order groups general-workspace items first
  (Instances, My Tasks, Definitions, DLQ, Webhooks) ahead of the `/admin/*` block
  (Users, Groups, Tokens, ... Question Bank) which is `PLATFORM_ADMIN`/`PROCESS_OPERATOR`
  territory. "Exams" is CANDIDATE's own equivalent of a task inbox — the one and only
  screen that role has any reason to open — so it belongs in that first workspace group,
  directly beside "My Tasks" (the item it is conceptually closest to: "the work items
  assigned to me"), not mixed into the admin block below it.

No other `NAV_ITEMS` entry's `roles` array changes. No other route or component
changes are made by this section.

---

## 3. `TenantDashboardPage` / `PermissionDenied`: CTA fix, not a new dashboard view

**Decision: do not build a CANDIDATE-specific `TenantDashboardPage` view. Instead, make
the existing shared `PermissionDenied` component's link role-aware.** Reasoning:

- A bespoke CANDIDATE dashboard view is unnecessary to solve the actual bug (missing
  *discoverability*): once §2's nav entry exists, CANDIDATE never needs the dashboard's
  tiles to find `/exam` — the sidebar link is always present regardless of which page is
  currently showing. Building a second dashboard variant would be scope beyond what the
  issue actually requires, and `docs/anti-patterns.md`/WF-02's scope-creep guard applies.
- The dashboard's current behavior (three tiles requiring permissions CANDIDATE lacks,
  driven by `rendererState` derived from the definitions query alone) is a **pre-existing,
  role-general** pattern — `PermissionDenied` is not this page's private component. It is
  rendered by every page in the `grep` result at the top of this doc (22 pages) wherever
  `QueryStateBoundary` classifies a query error as `permission-denied`. **It IS, however,
  the concrete surface the issue's own description quotes** ("You do not have access to
  this area... with a single My Tasks link that doesn't mention exams") — so it is in
  scope to fix, just not by forking the dashboard.
- The specific defect in `PermissionDenied.tsx` is that its `<Link to="/tasks">My
  Tasks</Link>` is a **hardcoded, role-blind guess at "the one place everyone can go."**
  That guess is wrong for CANDIDATE (who cannot reach `/tasks` either — TASK_WORKER/
  PLATFORM_ADMIN/PROCESS_OPERATOR-only per `AppShell.tsx:21`'s own `roles` array) and,
  now that §2 exists, there is a real, correct answer for CANDIDATE specifically: `/exam`.

**Change:** `PermissionDenied.tsx` becomes role-aware via the existing `useAuth()` hook
(already used identically in `AppShell.tsx` and elsewhere — no new auth-reading
mechanism introduced):

```
import { useAuth } from '@/auth/AuthContext'
```

Component body logic (prose, not code): read `session` from `useAuth()`. If
`session?.roles.includes('CANDIDATE')` is true, render `<Link to="/exam">Go to
Exams</Link>` in place of the current `<Link to="/tasks">My Tasks</Link>`; the
surrounding `<p>` text ("You do not have access to this area. Contact your tenant
administrator.") is **unchanged** for every role including CANDIDATE — CANDIDATE
genuinely lacks access to *this particular query's* resource (definitions), so the
sentence is still accurate; only the recovery link target changes, from a dead end to
a real, reachable screen. Every other role's rendered output (text and `/tasks` link)
is **byte-for-byte unchanged** — this is an `if`/ternary on the link target only, not a
rewrite of the component.

**Why this belongs in `PermissionDenied`, not conditionally in
`TenantDashboardPage` alone:** any other page a CANDIDATE session might reach that
403s (e.g. if a future change linked a CANDIDATE session toward `/instances`) would hit
the same dead-end "My Tasks" link today. Fixing it at the shared component is the
narrower, more correct fix — one call site — versus duplicating role-aware branching
into every one of the 22 pages that use `QueryStateBoundary`. This is analogous to
ISS-0718's own reasoning for preferring the narrower, reusable fix over a page-local
one.

**No regression for other roles:** confirmed by reading every other
`QueryStateBoundary`/`PermissionDenied` call site's role expectations — none of the
other 21 pages are CANDIDATE-reachable today (CANDIDATE's closed six-permission set,
`authorization.ex:1033-1042`, does not grant read access to instances, definitions,
DLQ, webhooks, users, groups, tokens, audit, health, metrics, onboarding, tenants,
services, or process modules — the only CANDIDATE-reachable API surface at all is the
`ExamSession*` family per ISS-0646/ISS-0718), so the new branch is **dead code for
every session except a CANDIDATE one** on every page except the dashboard itself, where
it is exactly the fix needed. A PLATFORM_ADMIN/PROCESS_DESIGNER/PROCESS_OPERATOR/
TASK_WORKER session's `session.roles` never contains `'CANDIDATE'`, so the ternary's
existing branch — the current `/tasks` link — is what every one of them still renders.

---

## 4. No-regression confirmation for the other four roles (nav)

`visibleNav = NAV_ITEMS.filter((n) => n.roles.some((r) => session?.roles.includes(r)))`
(`AppShell.tsx:66-68`) is a pure filter over the (now 15-entry, was 14) array. §2 adds
one array element whose `roles` is `['CANDIDATE']` only — it matches for a CANDIDATE
session and for no other, by construction (no existing entry gained or lost a role;
no existing entry's `to`/`label` changed). `AppShell.bilimbaga.test.tsx`'s four existing
cases (PLATFORM_ADMIN, PROCESS_OPERATOR both see "Question Bank"; PROCESS_DESIGNER,
TASK_WORKER both don't) exercise exactly this filter and are unaffected — none of those
four sessions ever contains `'CANDIDATE'`, so the new entry never enters their
`visibleNav`. This is additive-only, confirmed by inspection of the filter's logic, not
asserted from confidence alone — §5 specifies the test that makes this an executable
check, not just a design claim.

---

## 5. Test strategy (Vitest)

Two files, following `AppShell.bilimbaga.test.tsx`'s established pattern exactly (same
`vi.mock('@/auth/AuthContext', ...)`/`vi.mock('@tanstack/react-query', ...)`/
`vi.mock('@/api/client', ...)` mocking shape — Directive T-2, no `msw`/raw-fetch, per
`docs/guides/frontend_developer_guide.md` §3's guard suite and the existing test file's
own header comment):

### 5.1 `web/src/components/layout/__tests__/AppShell.candidate-nav.test.tsx` (new)

Mirrors `AppShell.bilimbaga.test.tsx`'s `renderAppShellAs(roles)` helper and
`sessionWithRoles(roles)` fixture verbatim (both are file-local, not exported — this
new file duplicates them, same as the existing convention of each `AppShell` test file
being self-sufficient per TEST-DESIGN-VALIDATOR's "self-sufficient fixtures" check).

Cases:
1. **`CANDIDATE` sees the "Exams" nav entry, linking to `/exam`.** Render with
   `roles: ['CANDIDATE']`; assert `screen.getByText('Exams')` is present; assert the
   rendered `<a>`'s `href` attribute (via `screen.getByText('Exams').closest('a')` or
   equivalent `getByRole('link', { name: 'Exams' })`) is `/exam`.
2. **`CANDIDATE` does NOT see any other nav entry.** Same render; assert
   `screen.queryByText('Instances')`, `'My Tasks'`, `'Definitions'`, `'DLQ'`,
   `'Webhooks'`, `'Users'`, `'Question Bank'` are all `not.toBeInTheDocument()` — proves
   the new entry doesn't accidentally widen CANDIDATE's visibility beyond the one
   intended item.
3. **No-regression, the other four roles do NOT see "Exams".** Four cases (one per
   existing role: `PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`,
   `TASK_WORKER`), each asserting `screen.queryByText('Exams')` is
   `not.toBeInTheDocument()` while that role's own already-established nav entry (e.g.
   `'My Tasks'` for `TASK_WORKER`) is still present — reuses the exact assertions
   `AppShell.bilimbaga.test.tsx` already makes for three of these four roles, extended
   with the new negative assertion.

### 5.2 `web/src/components/ui/__tests__/PermissionDenied.test.tsx` (new, or extend an
existing `PermissionDenied` test file if `Explore`/`FRONTEND-DEV` finds one at
implementation time — none exists as of this design; grepped
`web/src/components/ui/__tests__/` for `PermissionDenied` and found no match)

Cases:
1. **CANDIDATE session renders a link to `/exam` labeled "Go to Exams".** Mock
   `useAuth` to return a CANDIDATE session (same `sessionWithRoles`-shaped fixture);
   render `<PermissionDenied />` inside a `MemoryRouter` (required for `<Link>`);
   assert `screen.getByRole('link', { name: 'Go to Exams' })` has `href="/exam"`.
2. **Non-CANDIDATE session (e.g. `TASK_WORKER`) still renders the unchanged `/tasks`
   link.** Same render shape with a `TASK_WORKER` session; assert
   `screen.getByRole('link', { name: 'My Tasks' })` has `href="/tasks"` — proves the
   existing behavior is untouched for every role that isn't CANDIDATE.
3. **No-session case (`session: null`)** — `useAuth()` can return `session: null`
   before the session loads; assert the component still renders without throwing and
   falls back to the existing `/tasks` link (i.e. `session?.roles.includes('CANDIDATE')`
   is `false`/`undefined`-safe, not a crash on `null`).

### 5.3 Why no `TenantDashboardPage`-specific test is added

§3 deliberately made no change to `TenantDashboardPage.tsx` itself (only to the shared
`PermissionDenied` it renders through `QueryStateBoundary`) — there is no new
dashboard-local behavior to test. `TenantDashboardPage`'s existing tests (if any;
not modified by this design) are unaffected.

### 5.4 Live-QA / UAT-RUNNER follow-up

**A live re-check against `qa.bizdala.com` is a reasonable, and recommended, follow-up
— same precedent ISS-0726 itself established** (that issue's own resolution was
verified by a live re-run against the real deployment, not unit coverage alone, per
`docs/issues/ISS-0726.yaml`'s `resolution.resolved_in_run` entry). Unit coverage here
(§5.1-5.2) proves the nav-filtering logic and the fallback-link logic are each correct
in isolation, under mocked `useAuth`/`react-query` — it does **not** prove:
- that a real CANDIDATE Keycloak session's `roles` claim actually surfaces as the
  literal string `"CANDIDATE"` by the time it reaches `session.roles` in the live
  deployment (an OIDC claim-mapping question, outside what a Vitest unit test with a
  hand-built fixture can exercise);
- that the real `/api/v1/tenants/<slug>` 403 (the "cosmetic noise" banner the issue
  also mentions, `useTenantContext`'s `isUnknown` path) doesn't interact visually with
  the new nav entry in some way a unit test's jsdom render wouldn't catch.

Recommending a live-QA GUI re-check scoped narrowly to: sign in as `candidate-user`,
confirm "Exams" appears in the sidebar, confirm clicking it lands on a working
`ExamListPage`, confirm the dashboard's fallback link (if the 403 tile still renders,
which it will — §3 didn't remove that trigger) now reads "Go to Exams" and goes to
`/exam`. This mirrors ISS-0726's own documented distinction between what unit/e2e
coverage can and cannot prove about the live deployment specifically — flagged here as
a recommendation for ORCH/UAT-RUNNER scheduling, not performed by this design.

---

## 6. Security-review scoping

**Assessed: this qualifies for the lighter review path — SECURITY-REVIEWER sign-off is
not genuinely required, though flagging the reasoning explicitly rather than silently
skipping the gate, per WF-02 Step 2c's own scope test.**

Reasoning, checked against `docs/agents/instructions/security-invariants.md`'s
applicability notes and this design's own two changes:

1. **`Role`/`NAV_ITEMS` (§1-§2) is client-side nav *visibility* only.** Confirmed by
   reading `AppShell.tsx` in full: `Role`/`NAV_ITEMS`/`visibleNav` are consumed
   **exclusively** by the sidebar's own `<NavLink>` rendering (`AppShell.tsx:99-127`) —
   nothing in this file, or anywhere else in `web/src` (per the §1 grep), uses `Role` or
   `NAV_ITEMS` to gate an API call, a component's data-fetching, or any authorization
   decision. Hiding/showing a sidebar link changes what a user is *shown a shortcut to*,
   not what they are *authorized to do* — the router itself (`router.tsx`) mounts
   `/exam` unconditionally behind only `ProtectedRoute` (authentication, not
   role-authorization — confirmed by reading `ProtectedRoute.tsx` in full: it checks
   `isAuthenticated` only, no role check), same as it already did before this change,
   and every actual authorization decision for what a CANDIDATE session can read or
   write happens server-side in `Letflow.Api.Authorization.role_allows?/2`
   (`authorization.ex:1033-1042`, the ISS-0646 closed six-permission set), which this
   design does not touch. A CANDIDATE session already had the same access to `/exam`
   (and everything downstream of it) via a typed URL before this fix — ISS-0726's
   report explicitly confirms this ("a hand-typed `/exam` URL still works"). This
   design changes *discoverability*, never *authorization*.
2. **`PermissionDenied.tsx` (§3) reads `session.roles` (already loaded, already
   client-visible data — the same array `AppShell.tsx`'s own sidebar already renders at
   `data-testid="user-roles"`) to pick a link's `href`.** No new data is fetched, no new
   field is exposed, no token handling changes (`FNFR-06` — untouched), no tenant
   resolution changes. This is a presentational branch on data the component's own
   caller tree already holds.
3. Neither change touches a migration, a Plug route, a response-shaping function, or
   any of `security-invariants.md`'s INV-1..INV-8 applicability triggers (tenant-scoped
   query, raw SQL, secret handling, cross-tenant data exposure) — there is no
   tenant-data *path* here at all in the sense that term is used in that document; this
   is entirely `web/`-local presentation logic.

**Conclusion, stated for the record per WF-02 Step 2c's own procedure:** this diff's
scope test answer is **NO** ("out of scope — no tenant-data path touched"), same
verdict SECURITY-REVIEWER would reach performing its own Step 2c scope test — recorded
here so REVIEWER (idiom gate, still mandatory) can proceed without an extra round trip,
not as a substitute for SECURITY-REVIEWER independently confirming it. This is a
design-time observation, not a gate SECURITY-REVIEWER itself is skipped from making its
own re-derivation of if/when this reaches Step 2c.

---

## 7. Open questions

None. Every element of §1-§5 is fully specified (exact type addition, exact array
entry with all three fields, exact component-level branch, exact new test files with
case-level assertions) — no "TBD" left for ELIXIR-DEV/FRONTEND-DEV to silently resolve.
§5.4's live-QA recommendation is a follow-up **suggestion**, not an unresolved design
question blocking this fix.

---

## 8. Acceptance-criteria / obligation mapping

ISS-0728 is an issue record, not a `docs/requirements.yaml` entry with a structured
`acceptance_criteria` list — the mapping below is against its own stated resolution
obligations (its description's explicit ask: "add CANDIDATE to Role, add a NAV_ITEMS
entry gated on it, and/or a candidate-specific TenantDashboardPage view").

| Obligation (ISS-0728, derived) | Design element |
|---|---|
| `CANDIDATE` added to `AppShell.tsx`'s `Role` type | §1 |
| Confirmed no exhaustive switch/match elsewhere breaks | §1 ("Exhaustiveness check") |
| `NAV_ITEMS` entry gated on `CANDIDATE`, pointing at `/exam` | §2 |
| Label/icon/ordering decided per existing conventions | §2 |
| Decision made on dashboard-specific view vs. nav-item-alone, with reasoning | §3 |
| No regression to the other four roles' nav behavior | §4, §5.1 case 3 |
| Test strategy: nav rendering for CANDIDATE + no-regression for the other four | §5.1 |
| Live-QA/UAT-RUNNER follow-up assessed, per ISS-0726 precedent | §5.4 |
| SECURITY-REVIEWER scoping assessed, with reasoning | §6 |
| No open question silently resolved by guessing | §7 |
