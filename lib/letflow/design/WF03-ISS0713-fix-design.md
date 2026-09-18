# WF-03 Fix Design — ISS-0713

Run-id: WF03-ISS0713-20260918
Type: test-only fix (Playwright spec locator scoping). No `lib/`, `priv/`, or `web/src/`
changes.

## 1. Root cause (from ISSUE-FIXER, not re-derived)

`web/tests/e2e/pipelines/platform-login-routing-by-role.pipeline.e2e.spec.ts` lines
96-98 assert link visibility with an unscoped `page.getByRole('link', { name })`. On
`/platform-dashboard` as PLATFORM_ADMIN, each of the five names ('Tenants', 'Services',
'Health', 'Metrics', 'Users') is rendered twice:

- Once inside `<nav data-testid="platform-quick-links">` in
  `web/src/pages/dashboard/PlatformDashboardPage.tsx` (lines 69-75).
- Once in the sidebar `NAV_ITEMS` rendered by `web/src/components/layout/AppShell.tsx`
  (lines 19-48) — confirmed by direct read: `Users` (line 25), `Health` (29), `Metrics`
  (30), `Tenants` (32), `Services` (33) all carry `roles: ['PLATFORM_ADMIN']` and so all
  five render simultaneously alongside the quick-links nav for this exact test session.

Result: Playwright strict-mode violation (`getByRole` resolves to 2 elements) on every
name in the loop, not just one.

## 2. Fix — exact diff

File: `web/tests/e2e/pipelines/platform-login-routing-by-role.pipeline.e2e.spec.ts`,
lines 96-98.

Before:
```
    for (const name of ['Tenants', 'Services', 'Health', 'Metrics', 'Users']) {
      await expect(page.getByRole('link', { name })).toBeVisible()
    }
```

After:
```
    for (const name of ['Tenants', 'Services', 'Health', 'Metrics', 'Users']) {
      await expect(page.getByTestId('platform-quick-links').getByRole('link', { name })).toBeVisible()
    }
```

Single-line change (the `expect(...)` argument on line 97). No other lines in the file
are touched. `platform-quick-links` is an existing testid
(`PlatformDashboardPage.tsx` line 69, already asserted visible one line above at line 93
of the spec) — nothing new is introduced.

## 3. Scope confirmation

- No new public function, component, module, or route.
- No new testid needed in product code — `platform-quick-links` already exists and is
  already referenced by this same test file.
- No `web/src/...` file is touched. This is a pure test-locator scoping fix.

## 4. Fail-then-pass proof (note for TEST-DESIGNER / WF-03 Step 4)

Because the defective artefact *is* the test itself, the regression-proof pair required
by WF-03 Step 4 is this same edit, not a new test file:

- **Pre-fix (fail):** the unscoped locator at lines 96-98 already fails live with a
  Playwright strict-mode violation — captured in the issue's screenshot evidence
  (ISS-0713). No re-run is needed to produce the "fail" half of the proof; it is already
  on record.
- **Post-fix (pass):** re-running the same test (`EO-001: PLATFORM_ADMIN lands on the
  distinct platform dashboard`) after applying the diff in §2 must pass, since the
  locator now resolves to exactly one element per name (the quick-links nav entry).

TEST-DESIGNER does not need to author a new spec file for this issue; ELIXIR-DEV/
FRONTEND-DEV (whichever applies the diff) or TEST-RUNNER re-running this same test
post-fix satisfies the fail-then-pass requirement. No new test coverage is owed beyond
that re-run.

## 5. Risk / edge cases

- **Why scope all five names, not just the colliding one(s):** all five
  ('Tenants', 'Services', 'Health', 'Metrics', 'Users') independently collide today per
  the AppShell `NAV_ITEMS` read in §1 — none is a false negative. Scoping the whole loop
  to `platform-quick-links` is the correct fix for the loop as a unit, not overreach.
- **Future drift:** if AppShell's sidebar later drops one of these five labels (or
  PlatformDashboardPage's quick-links nav does), this test would silently stop exercising
  the collision case it was written to catch. No action needed now — noting only so a
  future edit to either nav list doesn't reintroduce an unscoped assumption elsewhere in
  this spec file.
- **No other assertions in this file share the defect.** Lines 90-93 already use
  testid-scoped or unique-testid locators; the sibling test at line 103
  (`TASK_WORKER`) does not reference these five link names at all, since a
  tenant-scoped role never sees the platform quick-links nav.
