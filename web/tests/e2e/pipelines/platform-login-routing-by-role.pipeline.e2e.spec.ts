/**
 * Pipeline: Platform login routing by role
 *
 * Drives `test/fixtures/uat/scenarios/platform/platform-login-routing-by-role.yaml`'s
 * `pipeline_test:` key (ISS-0702) for UAT-RUNNER.
 *
 * Covers the scenario's three mutually-exclusive branches, each with its own
 * single EO-001. These are independent alternatives of the same login flow —
 * not a sequential chain — so each is modelled as its own self-contained
 * `test()` case rather than forced through `createPipeline()`'s
 * forward-state-accumulation shape (see
 * lib/letflow/design/iss-0702-uat-runner-pipeline-test-gap-fix.md §1.3):
 *
 *   1. PLATFORM_ADMIN lands on workspace root with admin nav (§1.4)
 *   2. Tenant-scoped role (TASK_WORKER) lands on workspace root, narrower nav (§1.5)
 *   3. Unauthenticated visitor sees auth-loading, then redirects off-origin (§1.6)
 *
 * Uses `helpers.ts`'s two-arg `getKeycloakToken`/`loginWithToken` (always
 * `bpm-default` realm) — NOT `pipeline.ts`'s three-arg realm-taking overload,
 * per the design's §1.1: every credential this spec needs (`admin-user`,
 * `worker-user`) lives in `bpm-default`.
 *
 * Each branch's `gui_screen` EO-001 is checked via hard, deterministic
 * `expect()` assertions rather than REQ-362's two-phase pixel-baseline
 * mechanism — see design §1.7 for the reasoned decision. The
 * `page.screenshot()` call in each branch is supplementary evidence attached
 * to a PASS/FAIL already decided by assertion, same convention as
 * `req133-ac2-ac5.e2e.spec.ts` and `uat-alice-login.e2e.spec.ts`.
 */

import * as fs from 'fs'
import * as path from 'path'
import { test, expect } from '@playwright/test'
import { getKeycloakToken, loginWithToken, BPM_IDP_BASE_URL } from '../helpers'

const APP_BASE_URL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:4173'
const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'

const SCREENSHOTS_DIR = 'tests/screenshots/pipelines'

async function shot(page: import('@playwright/test').Page, stepName: string): Promise<void> {
  fs.mkdirSync(path.resolve(SCREENSHOTS_DIR), { recursive: true })
  await page.screenshot({
    path: path.join(SCREENSHOTS_DIR, `platform-login-routing-by-role-${stepName}.png`),
    fullPage: true,
  })
}

test.describe('Pipeline: platform-login-routing-by-role', () => {
  test.beforeAll(async ({ request }) => {
    // Reachability precheck, mirroring admin-user-lifecycle.pipeline.e2e.spec.ts.
    const idpOk = await request.fetch(
      `${BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`,
    )
    if (!idpOk.ok()) throw new Error(`Keycloak not reachable: ${idpOk.status()}`)

    // No backend call is required by this scenario (login/routing is IdP + SPA
    // only), but the precheck is included anyway for convention parity with
    // other pipeline specs — see design §1.2.
    const backendOk = await request.fetch(`${API_BASE_URL}/health/ready`).catch(() => null)
    if (backendOk && !backendOk.ok()) {
      console.warn(`[platform-login-routing-by-role] backend not ready: ${backendOk.status()} (non-blocking)`)
    }
  })

  test('EO-001: PLATFORM_ADMIN lands on workspace root with admin nav', async ({ page, request }) => {
    const token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    await loginWithToken(page, token)

    // Core routing claim: PLATFORM_ADMIN lands on the shared workspace root,
    // not a distinct platform-admin dashboard.
    await expect(page).toHaveURL('/')

    // PLATFORM_ADMIN-only nav entries are visible — proves the admin nav is present.
    for (const name of ['Users', 'Tenants', 'Health', 'Metrics']) {
      await expect(page.getByRole('link', { name })).toBeVisible()
    }

    // Entries shared with tenant-scoped roles are ALSO visible — proves this
    // is the same workspace root, not a distinct admin-only screen.
    for (const name of ['Instances', 'My Tasks']) {
      await expect(page.getByRole('link', { name })).toBeVisible()
    }

    await shot(page, 'admin')
  })

  test('EO-001: tenant-scoped role (TASK_WORKER) lands on workspace root with narrower nav', async ({ page, request }) => {
    const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
    await loginWithToken(page, token)

    // Core routing claim: tenant-scoped roles land on the SAME root, not a
    // different route.
    await expect(page).toHaveURL('/')

    // The nav entry a TASK_WORKER needs.
    await expect(page.getByRole('link', { name: 'My Tasks' })).toBeVisible()

    // PLATFORM_ADMIN-only entries must NOT be visible — proves the nav is
    // narrower than PLATFORM_ADMIN's, per EO-001's "narrower nav" wording.
    for (const name of ['Users', 'Tenants', 'Register Tenant', 'Audit', 'Health', 'Metrics']) {
      await expect(page.getByRole('link', { name })).not.toBeVisible()
    }

    await shot(page, 'tenant-scoped')
  })

  test('EO-001: unauthenticated visitor sees auth-loading then redirects off-origin to Keycloak', async ({ page }) => {
    // Deliberately no loginWithToken/getKeycloakToken call — matches the
    // scenario's own precondition ("no token, no cookie").
    //
    // Real, verified-against-QA timing finding: on both a local loopback
    // stack AND the real https://qa.bizdala.com deployment, the
    // ProtectedRoute → signinRedirect() chain completes so fast that any
    // observation attempted from OUTSIDE the page (an external CDP poll
    // started after `page.goto()` resolves, or even one started just before
    // it, per Playwright's own `waitForSelector`) consistently loses the race
    // to the redirect — confirmed by driving this exact spec against real
    // QA. The fix is to observe from INSIDE the page, at native JS speed: an
    // `addInitScript` MutationObserver watches for the placeholder and
    // records the fact in `window.name`, which (unlike page-level JS state)
    // survives a cross-origin navigation, so it can be read back after the
    // browser has landed on Keycloak's page. This is pure observation, not a
    // mock — it changes nothing about what the app does, only how reliably
    // we can see a transition too fast for external polling to catch.
    await page.addInitScript(() => {
      const mark = () => {
        if (document.querySelector('[data-testid="auth-loading"]')) {
          window.name = 'auth-loading-seen'
        }
      }
      // Observe `document` itself, not `document.documentElement` — this
      // script runs at document-start (before HTML parsing), so
      // `documentElement` does not exist yet and would make `.observe()`
      // throw. `document` always exists.
      new MutationObserver(mark).observe(document, { childList: true, subtree: true })
      mark()
    })
    await page.goto(APP_BASE_URL, { waitUntil: 'commit' })

    // "redirected off-origin to the configured OIDC authority's own hosted
    // login page" — the browser's URL origin changes away from the app's own
    // origin within a bounded wait.
    const appOrigin = new URL(APP_BASE_URL).origin
    await page.waitForURL((url) => url.origin !== appOrigin, { timeout: 20_000 })
    expect(new URL(page.url()).origin).not.toBe(appOrigin)

    // "briefly shows... the placeholder" — this IS the assertion, not a soft
    // check: a false result here is a real failure, not swallowed.
    const authLoadingSeen = await page.evaluate(() => window.name)
    expect(authLoadingSeen, 'expected the auth-loading placeholder to have rendered before the off-origin redirect').toBe('auth-loading-seen')

    await shot(page, 'unauthenticated')
  })
})
