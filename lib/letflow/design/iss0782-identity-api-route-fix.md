# ISS-0782 — `identity.ts` Users/Roles route fix (design)

Run: `WF03-ISS0782-20260923`. Fixes the Users admin screen calling
nonexistent `/api/v1/users*` / `/api/v1/admin/*` paths instead of the real,
router-backed `/api/v1/identity/*` paths. Source: ISSUE-FIXER's diagnosis
(`handoffs/WF03-ISS0782-20260923/step-01-issue-fixer-diagnose.json`),
reproduced live against a running backend (see that handoff for the
404-vs-403 proof). This document designs the fix only; it contains no
implementation code.

## Scope decision

Per the diagnosis's flagged option (a) vs (b): this fix covers **only** the
5 call sites below. `groupsApi.list` (also broken, also reachable from
`UserDetailPage.tsx` via `useAdminGroups`) is **left to ISS-0765**, which is
already open and filed against `groupsApi`'s entire broken-prefix set.
Rationale: ISS-0782's own scope (per its `affected_files`/title) is the
Users/Roles routing defect; folding in one `groupsApi` call site here would
either leave ISS-0765 partially pre-empted (confusing its own fix diff) or
require touching lines outside this issue's already-reviewed diagnosis.
**Known residual gap, explicitly noted, not fixed here:** `UserDetailPage.tsx`
will still throw when rendering a user's group memberships until ISS-0765 is
worked — the Users *list* and user *create/edit* flows are fully fixed by
this change, but the detail page's group-membership section is not.

## File changed

`web/src/api/identity.ts` only. No other file changes.

## Call-site changes (exact before/after)

All five are pure string-literal edits to the path argument of an existing
`client.<verb>()` call. No change to: function signatures, parameter types,
return types (`PagedResponse<User>`, `User`, etc.), request body shape, or
any caller in `useAdminUsers.ts` / `UsersPage.tsx` / `UserDetailPage.tsx`.

1. **`usersApi.list`** (line 16)
   - Before: `client.get<PagedResponse<User>>('/api/v1/users', params as Record<string, unknown>)`
   - After: `client.get<PagedResponse<User>>('/api/v1/identity/users', params as Record<string, unknown>)`
   - Verb unchanged (GET). `params` argument unchanged.

2. **`usersApi.get`** (line 19)
   - Before: `` client.get<User>(`/api/v1/users/${id}`) ``
   - After: `` client.get<User>(`/api/v1/identity/users/${id}`) ``
   - Verb unchanged (GET). Template-literal `${id}` interpolation unchanged.

3. **`usersApi.create`** (line 22)
   - Before: `client.post<User>('/api/v1/admin/users', body)`
   - After: `client.post<User>('/api/v1/identity/users', body)`
   - Verb unchanged (POST). `body` argument unchanged. Note this moves off
     the `/api/v1/admin/*` prefix entirely (not just off `/api/v1/users`) —
     confirmed by the diagnosis's router read that `/admin/users` was never
     mounted either.

4. **`usersApi.update`** (line 25)
   - Before: `` client.patch<User>(`/api/v1/users/${id}`, body) ``
   - After: `` client.patch<User>(`/api/v1/identity/users/${id}`, body) ``
   - Verb unchanged (PATCH). `body` argument unchanged. This is the single
     call site shared by both `useUpdateAdminUser` and
     `useDeactivateAdminUser` (both route through `usersApi.update` per the
     diagnosis) — one edit fixes both hooks.

5. **`rolesApi.list`** (line 66)
   - Before: `client.get<PagedResponse<Role>>('/api/v1/admin/roles')`
   - After: `client.get<PagedResponse<Role>>('/api/v1/identity/roles')`
   - Verb unchanged (GET). No arguments either before or after.

## Explicitly unchanged in this file (do not touch)

- `usersApi.resetPassword` (line 28, `/api/v1/users/:id/reset-password`) and
  `usersApi.delete` (line 31, `/api/v1/users/:id`) — no caller in the Users
  admin screen, and no matching backend route exists at *any* prefix per the
  diagnosis (missing-backend-endpoint gap, a different class of problem —
  changing the path here would not make these functional).
- `groupsApi.*` (lines 37-59) — ISS-0765's scope, see "Scope decision" above.
- `rolesApi.get/.create/.update/.delete/.grantPermission/.revokePermission`
  (lines 69-84) — not called by the Users admin screen.
- `tokensApi.*` (lines 90-98) — not called by the Users admin screen, zero
  callers outside `TokensPage.tsx`.

## Confirmation: pure string-literal change

- No new TypeScript types introduced or modified. `User`, `Role`,
  `PagedResponse<T>`, request-body types (`body`, `params`) are all
  untouched — only the URL path literal passed to `client.get/post/patch`
  changes.
- No change to `web/src/api/client.ts` or any HTTP wrapper — the fix is
  entirely inside the five path string literals listed above.
- No change to request or response JSON shape. The real backend routes
  (`GET/POST /api/v1/identity/users`, `GET /api/v1/identity/users/:id`,
  `PATCH /api/v1/identity/users/:id`, `GET /api/v1/identity/roles`, per
  `lib/letflow/routers/identity.ex`, confirmed live in the diagnosis) already
  return the same `User`/`Role`/paged-list shapes these functions'
  TypeScript return types declare — this is a routing correction, not a
  contract change.
- No new hook, component, or prop wiring changes in `useAdminUsers.ts`,
  `UsersPage.tsx`, or `UserDetailPage.tsx` — they call `usersApi.*` /
  `rolesApi.*` by function name only and are unaffected by the internal path
  literal changing.

## No shim/adapter introduced

Per FRONTEND-DEV's mandate, this is a **direct fix** to the five hardcoded
path literals so they match the real backend contract — not a compatibility
shim, path-rewriting layer, request interceptor, or normalization function
sitting between `identity.ts` and `client.ts`. There is exactly one place
each path string is written (the literal itself), and the fix edits that
literal in place. No new file, module, or abstraction is introduced by this
design.

## Existing test asset (informational — not this doc's job to design)

`web/tests/e2e/f5-admin-users.e2e.spec.ts` (last touched 2026-09-17, matched
by `web/playwright.config.ts`'s `testMatch: '**/*.e2e.spec.ts'`) already
drives the real Users admin screen end-to-end against a real backend
(creates a user via the UI, real login) — it was apparently not run against
a live backend recently enough to catch this regression before it shipped
(see diagnosis's "why existing tests didn't catch it"). TEST-DESIGNER
(Step 4) decides whether this existing spec already serves as the
fail-then-pass regression test (re-run it against pre-fix code to confirm it
fails, then against the fix to confirm it passes) or needs augmentation —
flagging it here only so TEST-DESIGNER doesn't duplicate it with a redundant
new e2e spec. A mocked fetch-URL assertion test in the style of
`web/src/api/__tests__/identity.removeMembers.test.ts` (spy on
`window.fetch`, assert exact path/method) is also a reasonable complementary
addition per the diagnosis's own suggestion, but is TEST-DESIGNER's call.

## Acceptance-criteria mapping

| ISS-0782 concern | Design element |
|---|---|
| `usersApi.list` wrong path | Call-site change (1) |
| `usersApi.get` wrong path (used by `UserDetailPage.tsx`) | Call-site change (2) |
| `usersApi.create` wrong path (used by `UsersPage.tsx` create flow) | Call-site change (3) |
| `usersApi.update` wrong path (used by update + deactivate flows) | Call-site change (4) |
| `rolesApi.list` wrong path (used by both Users pages) | Call-site change (5) |
| No regression to request/response contract | "Confirmation: pure string-literal change" |
| No normalization layer per FRONTEND-DEV mandate | "No shim/adapter introduced" |
| Avoid duplicating existing e2e coverage | "Existing test asset" note |
| Adjacent `groupsApi` gap not silently dropped | "Scope decision" |

## Open questions

None — all five call sites, their exact before/after values, and the scope
boundary were fully resolved by the diagnosis handoff; no unstated
assumptions remain for ELIXIR-DEV/FRONTEND-DEV to guess at.
