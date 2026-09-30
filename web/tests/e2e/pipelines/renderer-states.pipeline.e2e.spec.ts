/**
 * Pipeline: renderer-permission-denied-surface (ISS-0899, split from ISS-0890)
 *
 * Drives `test/fixtures/uat/scenarios/platform/renderer-permission-denied-surface.yaml`'s
 * `pipeline_test:` key for UAT-RUNNER. That scenario was BLOCKED only because this
 * file did not exist — the real security gap it depends on, REQ-378 ("Tenant-admin
 * role/status revocation has no live effect on an OIDC-authenticated session"), is
 * `status: done` and merged (`lib/letflow/design/req378-oidc-live-revocation-check.md`),
 * and the `PermissionDenied.tsx` renderer contract was already confirmed correct
 * pre-fix (REQ-378's own description). This spec is pure spec-authoring against
 * already-shipped behaviour — no new frontend/backend code.
 *
 * Mechanism under test (REQ-378 design §1-§3): `Letflow.Plugs.AuthPipeline`'s OIDC
 * branch now derives `conn.assigns.auth_context.roles` from a live, uncached
 * `group_members ⋈ tenant_role` query on every request (`Identity.list_effective_role_names/2`),
 * not from the bearer JWT's claims. Removing a user from a role-bearing group via
 * Letflow's own `web/` admin GUI therefore denies that user's very next API request —
 * no sign-out, no reload, no waiting for the access token to expire (REQ-378 AC1) —
 * and the resulting 403 renders through the existing, unmodified
 * `QueryStateBoundary`/`PermissionDenied` contract (REQ-378 AC3), which leaks nothing
 * about the underlying resource (a 5-line component with no resource props threaded
 * in — `web/src/components/ui/PermissionDenied.tsx`).
 *
 * "Area" mapping. R-Co's scenario is written against SwiftRoute's tenant-specific
 * "shipment administration" screen, which has no Letflow equivalent. The closest real
 * analogue in Letflow's own seeded platform tenant (`bpm-default`) is the DLQ admin
 * screen (`/dlq`, `web/src/pages/dlq/DlqPage.tsx`): an operator-only administration
 * area, reachable via the app's own sidebar nav (`AppShell.tsx`'s `NAV_ITEMS`), whose
 * `GET /api/v1/dlq` route is gated server-side by the `:DlqOperate` permission
 * (`lib/letflow/api/authorization.ex:608-609,992`) — held only by `PROCESS_OPERATOR`/
 * `PLATFORM_ADMIN` (`core_role_allows?/2`), never `TASK_WORKER`/`PROCESS_DESIGNER`/
 * `AGENT_RUNNER`/`CANDIDATE`. This is the scenario's "operations manager" role exactly.
 *
 * Actors — real, pre-seeded Keycloak users in the `bpm-default` realm
 * (`priv/keycloak/realms/bpm-default.json`), not fixtures created by this spec:
 *   - business_user = `operator-user` / `operator-pass`, realm role `PROCESS_OPERATOR`
 *   - tenant_admin   = `admin-user` / `admin-pass`, realm role `PLATFORM_ADMIN`
 * `operator-user` is bound to the seeded `PROCESS_OPERATOR` group
 * (`Letflow.Identity.RoleRegistry.seed_default_platform_role_groups/1`, ISS-0778) via
 * REQ-378's own one-time claims-to-`group_members` sync, which already ran the first
 * time this fixture user made any authenticated request in this environment — verified
 * directly against the real running stack while writing this spec: `GET /dlq` as
 * operator-user -> 200, `DELETE /groups/:id/members/:user_id` as admin-user -> 204,
 * immediate retry of the *same* operator-user token with no sleep -> 403, re-`POST`
 * the membership -> 201, retry -> 200 again. This spec drives the identical sequence
 * through the real `web/` GUI instead of raw HTTP.
 *
 * Two independent Playwright `BrowserContext`s, not one shared `page` with an
 * identity swap: the scenario's own step 3 requires business_user's session to never
 * sign out or reload while tenant_admin acts in the background — a single shared page
 * cannot model concurrent, independent sessions without destroying the very session
 * continuity the scenario is testing.
 *
 * Client-side nav staleness is explicitly NOT tested and NOT expected to change:
 * REQ-378 design §6 scopes `AppShell.tsx`'s client-side `session.roles` nav filter
 * ("gap 3") OUT of scope — the sidebar's "DLQ" link stays visible to operator-user
 * after revocation (nothing invalidates the in-memory session), and this spec
 * deliberately clicks that still-visible link anyway: the point of REQ-378 is that
 * the *server* denies the request regardless of what stale UI the client still shows.
 *
 * EO-004 (loading-placeholder-then-content, no layout jump) is checked with a hard,
 * deterministic assertion on `SkeletonLayout`'s `aria-busy="true"` placeholder
 * transitioning to `DataTable`'s `data-testid="data-table"` — not REQ-362's two-phase
 * pixel-baseline mechanism, same reasoned choice as
 * `platform-login-routing-by-role.pipeline.e2e.spec.ts` (its own file header, §1.7).
 *
 * INTERACTION NOTE: every click below uses `locator.dispatchEvent('click')` rather
 * than `locator.click()`. Confirmed directly while writing this spec (not assumed):
 * in the dev sandbox this was authored and verified against,
 * actionability-based `.click()`/`.fill()` calls hang indefinitely at Playwright's
 * final "performing click/fill action" phase — reproduced identically against an
 * unrelated, pre-existing, already-merged spec
 * (`admin-user-lifecycle.pipeline.e2e.spec.ts`'s very first `.fill()` call), and
 * against raw `page.mouse.down()`/`.up()`, ruling out anything specific to this file
 * or to `GroupsPage.tsx` — a real-input-dispatch limitation of that sandbox's
 * headless Chromium, not a defect in this spec or in `web/`'s own code.
 * `dispatchEvent('click')` fires a real, bubbling DOM `click` event that React's
 * root-level synthetic-event delegation handles exactly the same as a trusted one
 * (confirmed end-to-end below: real fetch calls fire, real backend responses come
 * back, real UI state changes) — it only skips Playwright's own actionability
 * pre-checks (visible/stable/not-obscured), which this spec's own `waitFor()`/
 * `expect(...).toBeVisible()` calls already establish immediately beforehand.
 */

import * as fs from 'fs'
import * as path from 'path'
import { test, expect, type Page, type Locator } from '@playwright/test'
import { getKeycloakToken, loginWithToken, resolveCredential, assertServiceReadiness } from '../helpers'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const SCREENSHOTS_DIR = 'tests/screenshots/pipelines'

const OPERATOR_USERNAME = 'operator-user'
const OPERATOR_PASSWORD = resolveCredential('UAT_QA_OPERATOR_PASSWORD', 'operator-pass')
const ADMIN_USERNAME = 'admin-user'
const ADMIN_PASSWORD = resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass')

const PERMISSION_DENIED_TEXT = 'You do not have access to this area. Contact your tenant administrator.'

/** See the file header's INTERACTION NOTE. */
async function click(locator: Locator): Promise<void> {
  await locator.dispatchEvent('click')
}

async function shot(page: Page, stepName: string): Promise<void> {
  fs.mkdirSync(path.resolve(SCREENSHOTS_DIR), { recursive: true })
  await page.screenshot({
    path: path.join(SCREENSHOTS_DIR, `renderer-permission-denied-surface-${stepName}.png`),
    fullPage: true,
  })
}

/**
 * Opens the "Manage members" dialog for the group whose Name cell reads
 * `groupName`, and waits for its member list's own GET to resolve before
 * returning -- `membersPage?.items ?? []` defaults to an empty array while
 * that query is still in flight (GroupsPage.tsx renders no loading
 * indicator for this specific section), so reading membership state any
 * earlier than this races a false "empty"/"not a member" read.
 */
async function openManageMembers(adminPage: Page, groupName: string): Promise<Locator> {
  const row = adminPage.getByTestId('datatable-row').filter({ hasText: groupName })
  await row.waitFor({ timeout: 10_000 })
  const membersLoaded = adminPage.waitForResponse(
    (res) => res.request().method() === 'GET' && res.url().includes('/identity/groups/') && res.url().endsWith('/members'),
    { timeout: 10_000 },
  )
  await click(row.getByRole('button', { name: 'Manage members' }))
  const dialog = adminPage.getByRole('dialog', { name: 'Manage group members' })
  await dialog.waitFor({ timeout: 10_000 })
  await membersLoaded
  await dialog.getByRole('heading', { name: 'Current members' }).waitFor({ timeout: 15_000 })
  return dialog
}

/**
 * Idempotent precondition: ensures `memberEmail` is a member of `groupName`,
 * adding them via the real GUI if not already present. Synchronizes on the
 * real POST round trip rather than the dialog's own re-render (see step 2's
 * comment on why this spec doesn't depend on GroupsPage's post-mutation
 * reactivity timing).
 */
async function isCurrentMember(dialog: Locator, memberEmail: string): Promise<boolean> {
  // Scoped to rows that also carry a "Remove" button -- the dropdown above
  // ("Add member") lists exactly the NON-members as <option> text, which
  // would otherwise false-positive a bare getByText(memberEmail) match
  // against a person who is NOT (yet) a member. Both filters use plain
  // hasText strings (not a nested has: locator) -- a `has:` locator built
  // from the same root as the outer one does not compose the way it looks
  // like it should; confirmed directly while writing this spec (it silently
  // matched zero rows against a dialog visibly showing the member).
  return (
    (await dialog
      .locator('div')
      .filter({ hasText: memberEmail })
      .filter({ hasText: 'Remove' })
      .count()) > 0
  )
}

async function ensureGroupMembership(adminPage: Page, groupName: string, memberEmail: string, memberSelectLabel: string): Promise<void> {
  const dialog = await openManageMembers(adminPage, groupName)
  if (!(await isCurrentMember(dialog, memberEmail))) {
    const addResponse = adminPage.waitForResponse(
      (res) => res.request().method() === 'POST' && res.url().includes('/identity/groups/') && res.url().endsWith('/members'),
      { timeout: 10_000 },
    )
    await dialog.locator('select').selectOption({ label: memberSelectLabel })
    await click(dialog.getByRole('button', { name: 'Add member' }))
    const res = await addResponse
    expect(res.ok(), `adding ${memberEmail} to ${groupName} must succeed`).toBeTruthy()
  }
}

test.describe('Pipeline: renderer-permission-denied-surface (platform-renderer-permission-denied-surface)', () => {
  test.beforeAll(async ({ request }) => {
    await assertServiceReadiness(request, API_BASE_URL)
  })

  test('EO-001..EO-005: live role revocation denies the very next request and renders PermissionDenied, restoring on repeat access', async ({ browser }) => {
    // Two real actors, two logins each in a fresh browser, a real admin GUI
    // round trip, a deliberate 31s wait for staleTime to lapse (see step 3's
    // own comment), and a real live-query re-check on the very next request —
    // all real network round trips, not a single click. Generous but bounded.
    test.setTimeout(150_000)

    // ── Two independent sessions: business_user's never reloads/re-logs-in ──────
    const businessContext = await browser.newContext()
    const businessPage = await businessContext.newPage()
    const adminContext = await browser.newContext()
    const adminPage = await adminContext.newPage()

    let removed = false

    try {
      // ── Setup: log both actors in ───────────────────────────────────────────
      const operatorToken = await getKeycloakToken(businessPage.request, OPERATOR_USERNAME, OPERATOR_PASSWORD)
      await loginWithToken(businessPage, operatorToken)

      const adminToken = await getKeycloakToken(adminPage.request, ADMIN_USERNAME, ADMIN_PASSWORD)
      await loginWithToken(adminPage, adminToken)

      // ── Precondition (not one of the scenario's own 5 steps): operator-user
      // is seeded with only the PROCESS_OPERATOR realm role
      // (priv/keycloak/realms/bpm-default.json), so revoking that one
      // membership below would leave them with zero roles at all -- unable
      // to reach even "his own task list," which breaks EO-005's own premise
      // ("a way back to work he can still do"). R-Co's SwiftRoute fixture
      // presumably gave its operations manager persona task-level access
      // alongside the area-specific one; this establishes the same real
      // shape here, idempotently, via the GUI, before the scenario's own
      // steps begin.
      await adminPage.goto('/admin/groups', { waitUntil: 'domcontentloaded' })
      await adminPage.waitForURL('/admin/groups', { timeout: 10_000 })
      await adminPage.getByRole('heading', { name: 'Groups' }).waitFor({ timeout: 10_000 })
      await ensureGroupMembership(adminPage, 'TASK_WORKER', 'operator@letflow.local', 'Operator User <operator@letflow.local>')

      // ── Step 1: business_user opens the area he is currently permitted to see,
      // watched from the first loading frame to the finished layout (EO-004).
      // A local dev backend answers /dlq fast enough that the loading frame can
      // resolve before Playwright's own assertion starts polling for it (the
      // exact class of race ISS-0891 hit) — so the very first /dlq response is
      // deliberately, observably delayed once via page.route(): a real network
      // round trip slowed down for observation, not a mocked/faked response. ──
      let delayedOnce = false
      await businessPage.route('**/api/v1/dlq*', async (route) => {
        if (!delayedOnce) {
          delayedOnce = true
          await new Promise((resolve) => setTimeout(resolve, 800))
        }
        await route.continue()
      })

      const dlqNavLink = businessPage.locator('nav a[href="/dlq"]')
      await dlqNavLink.waitFor({ timeout: 10_000 })
      await click(dlqNavLink)
      await businessPage.waitForURL('/dlq', { timeout: 10_000 })

      // First frame: the shaped placeholder, not a blank/jumping screen.
      await expect(businessPage.locator('[aria-busy="true"][aria-label="Loading content"]')).toBeVisible({ timeout: 5_000 })
      // Finished layout: the real DataTable, not the placeholder any more.
      await expect(businessPage.getByTestId('data-table')).toBeVisible({ timeout: 10_000 })
      await expect(businessPage.locator('[aria-busy="true"]')).toHaveCount(0)
      await shot(businessPage, 'step1-loading-screen')

      // ── Step 2: tenant_admin removes operator-user's PROCESS_OPERATOR
      // membership via web/'s own GUI (REQ-378 §4.1's fixed GroupsPage flow) ────
      await adminPage.goto('/admin/groups', { waitUntil: 'domcontentloaded' })
      await adminPage.waitForURL('/admin/groups', { timeout: 10_000 })
      await adminPage.getByRole('heading', { name: 'Groups' }).waitFor({ timeout: 10_000 })

      const dialog = await openManageMembers(adminPage, 'PROCESS_OPERATOR')
      await dialog.getByText('operator@letflow.local').waitFor({ timeout: 10_000 })

      // Synchronize on the real DELETE round trip itself (waitForResponse),
      // not on GroupsPage's own post-invalidation re-render — REQ-378's
      // scenario has no expected_outcome tied to step 2's own dialog UI; the
      // scenario-relevant assertions are entirely business_user's screen in
      // steps 3-5 below. This is also more robust: it confirms the real
      // write happened (204) without depending on incidental UI-reactivity
      // timing this scenario does not actually require.
      const removeResponse = adminPage.waitForResponse(
        (res) => res.request().method() === 'DELETE' && res.url().includes('/identity/groups/') && res.url().includes('/members/'),
        { timeout: 10_000 },
      )
      await click(dialog.getByRole('button', { name: 'Remove' }))
      const deleteRes = await removeResponse
      expect(deleteRes.status(), 'group-membership removal must actually succeed').toBe(204)
      removed = true

      // ── Step 3: business_user, without signing out or reloading, returns to
      // the same area via the app's own navigation (still-stale nav link — gap 3
      // is deliberately out of scope, see file header). ─────────────────────────
      //
      // Two things this step must force, deliberately, not by luck:
      //   1. TanStack Query's `staleTime: 30_000` (web/src/main.tsx) means a
      //      GET already fetched in step 1 is served straight from cache on
      //      a bare remount for up to 30s -- with no network call at all,
      //      "the very next request" REQ-378 AC1 is about would never
      //      actually happen, and business_user would keep seeing the
      //      SUCCESS content he was already legitimately shown before access
      //      was revoked (not a leak -- it's data he'd already been shown --
      //      but it would make this test pass or fail by luck rather than by
      //      what it's meant to prove). Waiting out that exact, cited 30s
      //      window guarantees the cache is genuinely stale before we act.
      //   2. Business_user's browser is still sitting on `/dlq` from step 1 --
      //      clicking a NavLink whose `to` already matches the current route
      //      is a router no-op (no navigation event, no remount, nothing to
      //      even evaluate freshness against). Navigating away first (to
      //      "My Tasks") and back genuinely unmounts/remounts DlqPage, which
      //      is what makes `refetchOnMount`'s staleness check run at all.
      await businessPage.waitForTimeout(31_000)
      await click(businessPage.getByRole('link', { name: 'My Tasks' }))
      await businessPage.waitForURL('/tasks', { timeout: 10_000 })
      await click(dlqNavLink)
      await businessPage.waitForURL('/dlq', { timeout: 10_000 })
      await expect(businessPage.getByText(PERMISSION_DENIED_TEXT)).toBeVisible({ timeout: 10_000 })

      // EO-001: nothing about the DLQ area leaks — no table, no entry rows, no
      // fragment of DLQ content anywhere alongside the refusal.
      await expect(businessPage.getByTestId('data-table')).toHaveCount(0)
      await expect(businessPage.locator('[data-testid^="dlq-details-"]')).toHaveCount(0)
      // EO-003: never a partial/mixed condition — no fetch-error and no stale
      // success content are shown at the same time as the refusal.
      await expect(businessPage.getByRole('alert')).toHaveCount(0)
      const navScreen = await businessPage.locator('main').innerText()
      await shot(businessPage, 'step3-refusal-screen')

      // ── Step 4: business_user tries a second route in — the browser's address
      // bar directly, not the app's own nav — and compares what he is shown ────
      await businessPage.goto('/dlq', { waitUntil: 'domcontentloaded' })
      await businessPage.waitForURL('/dlq', { timeout: 10_000 })
      await expect(businessPage.getByText(PERMISSION_DENIED_TEXT)).toBeVisible({ timeout: 10_000 })
      await expect(businessPage.getByTestId('data-table')).toHaveCount(0)
      await expect(businessPage.locator('[data-testid^="dlq-details-"]')).toHaveCount(0)
      await shot(businessPage, 'step4-direct-route-screen')

      // EO-002: navigation and a direct address land on the identical message.
      const directScreen = await businessPage.locator('main').innerText()
      expect(directScreen).toBe(navScreen)

      // ── Step 5: follows the offered link back to his own work ───────────────
      // Scoped to <main> — the sidebar's own "My Tasks" nav item (still
      // visible per the gap-3 note above) would otherwise make this
      // ambiguous; this specifically clicks PermissionDenied.tsx's own link.
      await click(businessPage.locator('main').getByRole('link', { name: 'My Tasks' }))
      await businessPage.waitForURL('/tasks', { timeout: 10_000 })
      await expect(businessPage.getByRole('heading', { name: 'My Tasks' })).toBeVisible({ timeout: 10_000 })
      // .toBeAttached(), not .toBeVisible(): operator-user's fixture task
      // inbox is genuinely empty (0 tasks), so the list container renders
      // with zero height -- present and successfully loaded (not another
      // PermissionDenied), just visually empty. The absence of the refusal
      // text is the real assertion that this landed on his own work.
      await expect(businessPage.getByTestId('task-inbox-list')).toBeAttached({ timeout: 10_000 })
      await expect(businessPage.getByText(PERMISSION_DENIED_TEXT)).toHaveCount(0)
      await shot(businessPage, 'step5-task-list-after-link')
    } finally {
      // ── Cleanup: restore operator-user's PROCESS_OPERATOR membership so later
      // scenarios/specs find them with their normal permissions. ───────────────
      if (removed) {
        await adminPage.goto('/admin/groups', { waitUntil: 'domcontentloaded' }).catch(() => {})
        const dialog = await openManageMembers(adminPage, 'PROCESS_OPERATOR').catch(() => null)
        if (dialog) {
          const select = dialog.locator('select')
          const restored = await select
            .selectOption({ label: 'Operator User <operator@letflow.local>' })
            .then(() => true)
            .catch(() => false)
          if (restored) {
            await click(dialog.getByRole('button', { name: 'Add member' }))
            await dialog.getByText('operator@letflow.local').waitFor({ timeout: 10_000 }).catch(() => {})
          }
        }
      }
      await businessContext.close()
      await adminContext.close()
    }
  })
})
