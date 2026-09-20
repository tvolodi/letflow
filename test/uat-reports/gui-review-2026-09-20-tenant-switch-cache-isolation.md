# GUI review: `tenant-switch-cache-isolation` (PW-15)

Date: 2026-09-20
Agent: ORCH
Sweep position: 12th of ~15 scenarios in today's systematic GUI-review sweep.
Scenario: `test/fixtures/uat/scenarios/platform/tenant-switch-cache-isolation.yaml`
Process applied: "review real screens/source before writing a blind Playwright
spec" — same process as the earlier scenarios in this sweep.

## Outcome: hybrid — one real BLOCKER found and fixed, one feature confirmed absent, two confirmed satisfied, one gap filed

This is security-relevant (cross-tenant data isolation), so it got the same
care as `renderer-permission-denied-surface`'s ISS-0736 finding: verify the
underlying mechanism from source before assuming anything from the
scenario's own stale-looking NOTE, and route any real defect through
SECURITY-REVIEWER.

## What was checked, per expected outcome

**EO-001 (mid-session switch to a second company, without reload, no stale
rows even mid-transition).** No underlying feature exists. Grepped
`web/src/` exhaustively: no `switchCompany`/`switchTenant`/`CompanySelector`
symbol anywhere, `AppShell.tsx` does not even display the current tenant's
name, and `web/src/auth/useTenantContext.ts` only ever reads
`session.tenant_slug` — a value set once, at login, from the OIDC JWT's own
claim (`AuthProvider.login`, `resolveTenantSlug`). Tenant identity is fixed
for the life of an OIDC session; changing company requires a fresh sign-in
against a different Keycloak realm, a full browser navigation
(`signinRedirect`/`signoutRedirect` via `OidcManager.ts`) that destroys the
entire JS heap — including the React Query `QueryClient` created once in
`main.tsx` — by construction. There is nothing to click. The scenario
fixture's own NOTE ("this spec file does not exist ... an aspirational
forward-reference ... gated on the same missing feature") turns out to be
**correct, not stale**, for this specific expected outcome. Filed as
**REQ-384** (owner FRONTEND-DEV) rather than attempted. That requirement
also flags, as a load-bearing design note for whoever builds it: today's
query keys (`web/src/api/queryKeys.ts`) are NOT tenant-scoped at all — safe
only because a tenant change is always currently accompanied by a full
reload — so building a switcher without also tenant-keying the cache would
ship exactly the leak this scenario's EO-001 exists to catch.

**EO-002 (signing out leaves nothing behind).** This is the flow the app
actually supports, and it had a real, currently-shipped defect — found,
fixed, and verified live. See "Fixed vs filed" below for the full trace.

**EO-003 (a task shows the form it was created against, not a newer
published version).** Satisfied by construction, confirmed by reading
`lib/letflow/engine/task_activation.ex` (`resolve_form_schema/1` freezes
`form_schema` onto the `tasks` row from the graph snapshot at activation
time) and `lib/letflow/design/req126-form-version-pinning.md` (REQ-126,
`status: done`, pins `form_id`/`form_version` from the write-once
`instance_definition_snapshots.definition_ver` row). `TaskInboxPage.tsx`
renders `task.form_schema` directly from the task payload — no live
re-fetch/re-resolve step exists anywhere in this path. This had ExUnit
coverage (`test/letflow/routers/tasks_test.exs`, REQ-126 AC3) but no proof
the real SPA screen itself renders the pinned fields rather than a
newly-promoted definition's fields — that gap is now closed by this
scenario's own Playwright spec (see "Spec status" below), run for real
against a live stack: create v1 with a field unique to v1, start an
instance, open the real Task Inbox, promote v2 with a *different* field
under the same process name, reopen the *same* task, and prove it still
shows only v1's field. Passed.

**EO-004 (explicit "out of date" fallback when a version match can't be
confirmed).** No implementation anywhere — grepped exhaustively; the only
adjacent-looking component, `web/src/components/ui/StaleVersionError.tsx`,
is a genuinely different, already-shipped concept (REQ-379/380/381's
optimistic-concurrency 409-conflict banner for record *edits*, unrelated to
task-form version pinning). Because REQ-126's design freezes `form_schema`
onto the task row at creation time and never re-resolves it against a live
catalog at read time, there is today no code path that performs a "does the
version returned match the version requested" comparison at all — this
expected outcome describes a failure mode of a resolution step that doesn't
exist in this architecture. Filed as **REQ-385** (owner ELIXIR-DEV), scoped
as a CODE-DESIGNER question first ("does EO-004 even have a real analog
under this design, and if so what is it") rather than a mechanical retrofit.

**EO-005 (frequently-changing lists refetch on return).** Already has
working, independently-read coverage: `web/src/hooks/usePolling.ts`
invalidates its query-key prefix on a timer AND on `visibilitychange`
(tab refocus), and `useTaskInbox` polls independently. MINOR severity in
the scenario itself (`suggested_action: none`) — out of scope for this
spec's own regression focus, not separately re-verified live.

## Fixed vs filed

**Fixed — `ISS-0737` (BLOCKER, matching EO-002's own severity), two-part fix:**

`web/src/auth/tenantConfig.ts`'s `resolveRealmFromUrl()` deliberately
persists a `?realm=` URL parameter into `sessionStorage` under
`bpm_realm_slug` (OIDC-F-06), so in-SPA navigations don't need to repeat the
query string. `AuthProvider.logout()` never cleared it. On a shared browser
tab (a dispatch desk, a hot desk — exactly EO-002's own `business_impact`
prose), signing out of one tenant and signing in as a different tenant's
user on the same tab left the first tenant's realm slug in place, so the
next sign-in's `fetchTenantConfig()` call resolved branding/`oidc_authority`
against the WRONG tenant.

Fix, part 1: added `resetTenantConfigCache()` (clears the in-memory
`_cachedConfig` and removes `bpm_realm_slug`), called from
`AuthProvider.logout()`.

Fix, part 2 — found only by actually running the e2e spec against a live
stack, not by reading source: the first fix alone was insufficient. The
instant `logout()` sets the session to `null`, `ProtectedRoute`'s
`isAuthenticated` flips to `false` on the next render, and *that* render's
own effect calls `getOidcManager()` again — which calls
`resolveRealmFromUrl()` again. If the address bar still literally reads
`?realm=<slug>` at that moment (nothing in this app ever strips it), that
call silently re-derives the same slug from the URL and writes it straight
back into `sessionStorage`, undoing part 1 a tick later. Confirmed as a
real, reproducible failure (not theoretical) — the e2e spec's EO-002 test
failed consistently with the stale slug still present before this second
fix landed, then passed cleanly across 3 consecutive runs after
`resetTenantConfigCache()` was extended to also strip `?realm=` from the
URL via `history.replaceState` (no navigation).

Files changed:
- `web/src/auth/tenantConfig.ts` — `resetTenantConfigCache()`.
- `web/src/auth/AuthProvider.tsx` — calls it from `logout()`.
- `web/src/auth/tenantConfig.test.ts` — TC-EO002-01..04 (unit).
- `web/src/auth/__tests__/AuthProvider.logout-clears-realm.test.tsx` — new
  file, TC-EO002-03/04 (unit, real `AuthProvider` render + mocked
  `OidcManager`/`api/client`).
- `web/tests/e2e/pipelines/tenant-cache.pipeline.e2e.spec.ts` — new file,
  real regression coverage (see "Spec status").

Routed through SECURITY-REVIEWER before merge (cross-tenant session
residue, a tenant-data path per
`docs/agents/instructions/security-invariants.md`). **Verdict: PASS.**
SECURITY-REVIEWER independently traced the mechanism further than this
report does above and confirmed the race is real in production, not an
e2e-harness artifact: `web/src/auth/oidcRedirectArgs.ts`'s
`buildRedirectArgs()` calls `resolveRealmFromUrl()` directly (independent of
`OidcManager.ts`'s `_resolvedManager` memoization), and `ProtectedRoute.tsx`
calls exactly `signinRedirect(buildRedirectArgs(...))` on every
`isAuthenticated → false` transition — so without part 2 of the fix, a real
post-logout re-render really would both rewrite the stale slug into
`sessionStorage` AND bake it into the next `signinRedirect`'s
`redirect_uri`. No BLOCKER found; one non-blocking coverage nicety noted
(URL-stripping is unit-tested at `tenantConfig.test.ts`'s level but not
re-asserted through the `AuthProvider.logout()` call site specifically —
the same underlying function, so not a defect).

**Filed:**

- `docs/requirements.yaml` **REQ-384** (owner FRONTEND-DEV, stage S8,
  `depends_on: []`) — build the in-app tenant switcher AND tenant-key the
  React Query cache in the same requirement, explicitly to avoid shipping a
  switcher that leaks the moment it exists. Flags SECURITY-REVIEWER as
  mandatory.
- `docs/requirements.yaml` **REQ-385** (owner ELIXIR-DEV, stage S9,
  `depends_on: [REQ-126]`) — decide whether EO-004's guarantee has a real
  analog under REQ-126's frozen-at-creation design, and if so build the
  matching fallback; explicitly fenced against retrofitting the unrelated
  409-conflict UI or against manufacturing a failure mode that doesn't
  exist for this requirement's own sake.
- `docs/issues/ISS-0737.yaml` — full defect trace and fix record for the
  EO-002 finding above (`status: fixed`, fix lands in this same PR).

## What was NOT done, and why

No live sign-in was driven against `https://qa.bizdala.com` — a local stack
was used instead (docker compose Keycloak/Postgres already running from a
prior session, a `LETFLOW_DEV_DB_CONFIRMED=1 mix run --no-halt` backend on
port 4000, and a `vite`/Playwright frontend, all started for this
verification pass and torn down afterward). This still satisfies the
project's "no speculation" rule — real HTTP, a real browser (Chromium),
real backend/DB state throughout — and is what actually surfaced the second
part of the EO-002 fix above; a source-only review would very plausibly
have missed the `ProtectedRoute` re-render race.

EO-001 was not attempted live — there is no in-app control anywhere to
drive; see REQ-384. EO-004 was not attempted live — there is no fallback UI
anywhere to drive; see REQ-385. EO-005 was not independently re-verified
live in this pass (MINOR, `suggested_action: none`, and `usePolling.ts`'s
mechanism was already confirmed correct by direct source reading).

**Process note on shared local infrastructure:** starting the local backend
required `LETFLOW_DEV_DB_CONFIRMED=1` (the shared `letflow_dev` database
guard) — used deliberately, with additive-only, randomly-suffixed fixture
data (process names/labels salted with a random 8-hex id) to avoid
colliding with any concurrent sibling session's own state, consistent with
how this repo's other e2e pipeline specs already assume this exact database
to be reachable. Separately: cleanup at the end of this pass used
`taskkill //IM node.exe //F` to stop the ad-hoc `vite` dev server, which is
overly broad — it would have killed **any** other Node process on the host,
including a sibling session's own tooling, if one had been running at that
moment. No such collision was observed, but this was a mistake in method,
not a considered choice; a future pass should target the specific PID
instead (as was correctly done for the `mix run` backend process).

## Spec status

`web/tests/e2e/pipelines/tenant-cache.pipeline.e2e.spec.ts` — authored and
run for real against a live local stack (Keycloak on `:8093`, backend on
`:4000`, SPA dev server on `:4173`). Both tests pass, confirmed across 3
consecutive clean runs:

- `EO-002: sign-out clears same-tab tenant-selection residue (bpm_realm_slug)`
- `EO-003: a task shows the form it was created against, not a later
  published version`

EO-001 and EO-004 have no corresponding test in this spec — there is
nothing shipped to drive for either (see REQ-384/REQ-385). This is stated
explicitly in the spec file's own header comment rather than left silent.
The scenario fixture's own `pipeline_test` NOTE was left in place (not
removed) — unlike `tenant-branding-applied`'s finding, this scenario's core
premise (EO-001) genuinely does not exist yet, so the NOTE's "BLOCKED /
UNBUILT_FEATURE" framing for the frontend leg remains accurate, not stale.

## Status housekeeping

- `mix letflow.check_issue_refs`: one pre-existing violation on
  `docs/issues/ISS-0728-exam-title-object-object-sibling-wip-rescued.yaml`
  from a concurrent sibling session's WIP, not introduced by this run — no
  issue file this run touched is implicated.
- `web/`'s full `vitest` suite: 73 files / 521 tests, all passing, run
  before and after this change (no regression).
- `npx tsc --noEmit -p tsconfig.app.json`: clean.
