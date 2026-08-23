# ISS-0289 — Wire up `UserDetailPage.tsx`, retire `UsersPage.tsx`'s inline duplicate

Status: design for CODE-DESIGN-VALIDATOR review. No implementation code below —
interfaces/props/signatures/route shapes only.

## 1. Decision

**Option 1 (adopt `UserDetailPage.tsx` as the single detail/edit view; delete the
inline branch in `UsersPage.tsx`).** Confirmed independently — see §2 for my own
grep sweep, which agrees with ISSUE-FIXER's "zero other references" claim.

Rationale, beyond ISSUE-FIXER's framing:

- `UserDetailPage.tsx` is strictly more complete: it uses `QueryStateBoundary` +
  `classifyError` for loading/error rendering (the project's established pattern —
  `AuditLogPage.tsx`, `HealthDashboardPage.tsx`, `MetricsPage.tsx` all follow it),
  has a real extracted `DeactivateUserDialog` component, and fully implements
  group-membership editing (checkboxes bound to `groupsQuery`/`selectedGroupIds`),
  which `UsersPage.tsx`'s inline branch explicitly does not (line ~169: "Group
  membership editing is available in a dedicated follow-up iteration").
- `UsersPage.tsx`'s inline branch carries a real hack that Option 1 also removes:
  `createUser`'s `onError` calls `navigate('/admin/users/temp-${Date.now()}')`
  purely to force `selectedUserId` to a truthy value so the inline branch's `error`
  paragraph renders — a fake user id is pushed into the URL bar just to surface a
  create-form error. This has no equivalent need once the detail view is its own
  route and `UsersPage` keeps its own local `error` state scoped to the create form.
- Deleting `UserDetailPage.tsx` (Option 2) would delete already-built,
  functionally-superior code and permanently drop group-membership editing
  capability, to keep an inline implementation whose own comment says it's an
  interim stand-in. That is strictly worse than finishing the wiring.
- Both e2e specs (`web/tests/e2e/f5-admin-users.e2e.spec.ts`,
  `web/tests/e2e/pipelines/admin-user-lifecycle.pipeline.e2e.spec.ts`) drive the
  detail view purely by `data-testid`, not by import — see §2. They pass against
  either component today because the testids are identical; they will keep passing
  unchanged after the swap because `UserDetailPage.tsx` implements every testid
  they touch (`admin-user-detail-form`, `admin-user-display-name`,
  `admin-user-email`, `admin-user-status`, `admin-user-save`,
  `admin-user-deactivate`, `admin-user-submit-message`).

## 2. Independent verification (own grep sweep, not inherited from ISSUE-FIXER)

Per `docs/anti-patterns.md`'s "Inheriting a claim from a record instead of
re-deriving it from the source," ISSUE-FIXER's "zero other references" claim was
re-derived directly rather than trusted:

```
grep -rn "useAdminUsers|UserDetailPage|DeactivateUserDialog" web/src
  -> web/src/pages/admin/UserDetailPage.tsx        (self / imports)
  -> web/src/hooks/useAdminUsers.ts                (self)
  -> web/src/components/admin/users/DeactivateUserDialog.tsx (self)
  (no other web/src file references any of the three)

grep -rni "admin-user-detail-form|admin-user-display-name|admin-user-email|
           admin-user-status|admin-user-save|admin-user-deactivate|
           admin-user-submit-message|admin-user-username|useAdminUsers|
           UserDetailPage|DeactivateUserDialog" web
  -> web/README.md                                             (prose mention)
  -> web/tests/e2e/pipelines/sim-company-onboarding.pipeline.e2e.spec.ts
  -> web/tests/e2e/pipelines/sim-admin-processes.pipeline.e2e.spec.ts
  -> web/tests/e2e/pipelines/admin-user-lifecycle.pipeline.e2e.spec.ts
  -> web/tests/e2e/f5-admin-users.e2e.spec.ts
  -> (plus the three source files above)
```

Confirmed by reading the two lifecycle-relevant spec files directly (not just the
grep hit list): every reference is `page.getByTestId('admin-user-*')` /
`navigateSpa(page, '/admin/users/${id}')` — testid- and URL-driven, no import of
either component, no reference to `admin-user-username` (the one testid
`UserDetailPage.tsx` has that `UsersPage.tsx`'s inline branch does not — a
read-only username `<input disabled>`). So: no test asserts on
`admin-user-username`, meaning no test needs updating for that field's addition,
and no test imports either page component directly, meaning nothing breaks by
routing `:id`/`:userId` to a different component as long as the shared testids
keep working — which they will, per the file-by-file plan below.

`queryKeys.admin.userDetail(id)` (in `web/src/api/queryKeys.ts`) and the
`usersApi.get`/`usersApi.update` signatures (in `web/src/api/identity.ts`) are
already shared between `UsersPage.tsx`'s inline branch and `useAdminUsers.ts` — no
API-client change needed. `User` type fields consulted by `UserDetailPage.tsx`
(`role_ids?`, `group_ids?`, `status?: 'ACTIVE' | 'INACTIVE'`) already exist in
`web/src/types/api.ts`. `useAuth`/`session.roles.includes('PLATFORM_ADMIN')` is the
same gating pattern already used by `AuditLogPage.tsx`, `HealthDashboardPage.tsx`,
`MetricsPage.tsx` — consistent, not a new pattern.

## 3. Route param naming decision

`UserDetailPage.tsx` destructures `useParams()` as `{ userId: routeUserId = '' }`
(line 20); `router.tsx` currently registers `admin/users/:id`. Decision: **rename
the route param to `:userId`** in `router.tsx`, rather than changing
`UserDetailPage.tsx`'s destructure key to `id`.

Why this side is less invasive:

- `UserDetailPage.tsx`'s internal variable is already named `routeUserId` and is
  threaded through five call sites (`useAdminUser(routeUserId)`,
  `useUpdateAdminUser(routeUserId)`, `useDeactivateAdminUser(routeUserId)`, the
  `pageUserId` memo fallback, the `DeactivateUserDialog` `displayName` fallback).
  Keeping the destructure key as `userId` means **zero lines change inside
  `UserDetailPage.tsx`** — only the router's path string changes.
  Changing `UserDetailPage.tsx` to destructure `id` instead would require renaming
  every one of those five call sites' bound variable too (or introduce a confusing
  `const { id: routeUserId }` alias, no real savings).
- Grep of `router.tsx` for `:id` as a route param confirms every other detail
  route already uses a route-specific/entity-specific param name, not a bare `:id`
  reused across unrelated routes: `definitions/:id` (but that page's own
  `useParams` reads generic `id`, scoped to its own route only — no collision),
  `instances/:id`, `admin/tenants/:slug/edit`, `admin/onboarding/:onboardingId/...`.
  Nothing else in `router.tsx` reads a route param named `id` in a way that
  `admin/users/:userId` would collide with — route params are scoped per-route in
  React Router, so renaming `admin/users/:id` to `admin/users/:userId` cannot
  affect `definitions/:id` or `instances/:id`, which are separate route entries.
  No other file in `web/src` references the `admin/users/:id` param by name (the
  e2e specs build the URL by string interpolation, `` `/admin/users/${id}` ``, and
  never read the param name back out) — confirmed by the same grep sweep in §2.

So the only file changed for this decision is `router.tsx`'s route path string.

## 4. File-by-file change list

### 4.1 `web/src/router.tsx`

- Add import: `import UserDetailPage from '@/pages/admin/UserDetailPage'`
  (alongside the existing `UsersPage` import, same directory convention as every
  other admin page import in this file).
- Change the route entry at line 59 from:
  `{ path: 'admin/users/:id', element: <UsersPage /> }`
  to:
  `{ path: 'admin/users/:userId', element: <UserDetailPage /> }`
- Line 58 (`{ path: 'admin/users', element: <UsersPage /> }`) is unchanged.
- No other route entries change.

### 4.2 `web/src/pages/admin/UserDetailPage.tsx`

- No changes. Its `useParams()` destructure of `userId` now matches the router's
  `:userId` param (§3), so it starts receiving a real value instead of always
  `''`. Everything downstream (`useAdminUser(routeUserId)` etc.) already handles
  the previously-always-empty case correctly (`useAdminUser`'s `enabled:
  userId.length > 0` guard in `useAdminUsers.ts` — no query fired for `''`), so no
  behavior change is needed for the "now it actually receives an id" transition.

### 4.3 `web/src/pages/admin/UsersPage.tsx`

Remove the entire inline detail/edit branch and everything that exists only to
support it. Concretely:

- **Remove** state: `[showDeactivateConfirm, setShowDeactivateConfirm]`,
  `[detailForm, setDetailForm]`.
- **Remove** the `selectedUserId` `useMemo` (path-parsing regex against
  `location.pathname`) — `UsersPage` no longer needs to know about a selected
  user at all.
- **Remove** the `userDetail` query (`useQuery` keyed on
  `queryKeys.admin.userDetail(selectedUserId ?? '')`).
- **Remove** the `saveUser` mutation.
- **Remove** the `useEffect` that syncs `userDetail.data` into `detailForm`.
- **Remove** the `if (selectedUserId) { return (...) }` early-return block in
  full — the whole inline detail/edit JSX (back button, `admin-user-detail-form`
  div, all its fields, the group-membership placeholder paragraph, the Save/
  Deactivate buttons, the inline deactivate-confirm dialog block).
- **Keep**: `toggleRole` (still used by the create-user role checkboxes),
  `useLocation()`'s `location` import can be dropped entirely since nothing reads
  `location.pathname` anymore — remove the `useLocation` import/call if nothing
  else in the file uses it (confirm at implementation time; today nothing else
  does).
- **Change** `createUser`'s `onError` handler: remove the
  `navigate('/admin/users/temp-${Date.now()}')` call (the "fake id to force the
  inline branch to render" hack — no longer applicable since there is no inline
  branch). Keep `setError((e as Error).message)` — `UsersPage`'s own `error` state
  already renders inside the `creating` panel's `{error && <p>...}` block (line
  267), which is unaffected.
- **Keep** unchanged: `creating`/`searchDraft`/`searchApplied`/`form`/
  `createRoleIds`/`error`/`submitMessage` state, the `data`/`isLoading`/`isError`
  list query, the `roles` query, `createUser`'s `onSuccess` (already does
  `navigate('/admin/users/${createdUser.id}')` — this becomes the *only* way into
  the detail route from here on, and it now lands on `UserDetailPage` instead of
  the removed inline branch, which is exactly the desired behavior), the full
  list-page JSX (search bar, `+ New User` panel, `admin-users-table`).
- Net effect: `UsersPage` returns to being purely a list+create page. Its list rows
  do not currently navigate on row click — confirm at implementation time whether
  a row click should also `navigate('/admin/users/${u.id}')` (not in ISSUE-FIXER's
  diagnosis or this issue's affected_files; flagged as an open question below
  rather than silently added).

### 4.4 `web/src/hooks/useAdminUsers.ts`, `web/src/components/admin/users/DeactivateUserDialog.tsx`

No changes. Both become live (no longer dead code) purely as a consequence of
`UserDetailPage.tsx` being wired into the router — nothing in either file needs
editing.

### 4.5 Test files

No changes required. `web/tests/e2e/f5-admin-users.e2e.spec.ts` and
`web/tests/e2e/pipelines/admin-user-lifecycle.pipeline.e2e.spec.ts` drive the
detail view purely by shared `data-testid`s and by navigating to
`/admin/users/${id}` (URL string, not param name) — both keep working unchanged
against `UserDetailPage.tsx` (§2). TEST-DESIGNER should still run these specs
post-implementation per the normal WF-03 gate sequence to confirm rather than
assume, but no new test code or edits are dictated by this design.

## 5. Preserved behavior

- **List** (`GET` users, search, table render): unchanged — `UsersPage`'s list
  query, `roles` query, and table JSX are untouched by this design.
- **Create-user navigation**: unchanged in effect — `createUser.onSuccess` already
  calls `navigate('/admin/users/${createdUser.id}')`; that URL now resolves to
  `UserDetailPage` instead of the old inline branch. The create-error path drops
  its `temp-${Date.now()}` URL hack (§4.3) but keeps showing the error message,
  now inside the still-open `creating` panel instead of by faking a navigation.
- **Deactivate**: preserved, via `DeactivateUserDialog` + `useDeactivateAdminUser`
  (`UserDetailPage.tsx`, unchanged) instead of the inline branch's
  `showDeactivateConfirm` block (removed). Both call
  `usersApi.update(id, { is_active: false, status: 'INACTIVE' })` shaped mutations
  and invalidate the same `queryKeys.admin.users()` / `userDetail(id)` keys — same
  observable effect (list refetches, detail's own status flips to INACTIVE, a
  "User deactivated" `submitMessage` renders under `admin-user-submit-message`).
  The confirmation dialog's copy is slightly reworded between the two
  implementations (inline: "Active tasks assigned to this user remain assigned. /
  Users cannot complete them while INACTIVE." — `DeactivateUserDialog`: same two
  facts in one paragraph, plus an optional "Reason" field the inline version
  didn't have). Neither e2e spec asserts on the confirmation dialog's exact
  copy (§2), so this is not a behavior regression against any existing test.
- **Group membership editing**: gained, not merely preserved — the inline branch
  explicitly punted on it; `UserDetailPage.tsx` already implements it fully
  (checkboxes bound to `groupsQuery.data.items`, `selectedGroupIds` submitted as
  `group_ids` in the update mutation body, which `usersApi.update`'s type already
  accepts).

## 6. Open questions for FRONTEND-DEV / REVIEWER

1. Should a click on a table row in `UsersPage.tsx`'s list navigate to
   `/admin/users/${id}`? Today the list has no such handler in either the current
   code or this design — the only entry points into the detail route are (a)
   direct URL navigation (as the e2e specs do) and (b) post-create navigation.
   ISS-0289's `affected_files` names only `UserDetailPage.tsx` and `router.tsx`,
   not a new list-affordance, so this design does not add one. If product intent
   is for the list to be clickable into detail, that is a separate, new
   requirement — not silently bundled into this fix.
2. `UserDetailPage.tsx` gates on `PLATFORM_ADMIN` (line 23); the removed inline
   branch in `UsersPage.tsx` had no such gate. This means a non-`PLATFORM_ADMIN`
   user who could previously reach the inline detail view (if any such user could
   reach `/admin/users` at all — not verified here, out of this issue's scope)
   will now see `UserDetailPage`'s "You do not have permission to manage users."
   message instead. This is consistent with the other admin-only pages
   (`AuditLogPage`, `HealthDashboardPage`, `MetricsPage` all gate the same way)
   and is treated here as intentional hardening, not a regression — flagged
   explicitly rather than silently accepted, since no acceptance criterion in
   ISS-0289 mentions authorization.
