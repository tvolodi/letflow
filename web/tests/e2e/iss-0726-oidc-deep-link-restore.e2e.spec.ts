/**
 * E2E regression suite — ISS-0726: hard navigation to /exam bounces back to /
 * instead of showing the exam list
 *
 * Modeled exactly on web/tests/e2e/iss-0063-oidc-redirect-loop.e2e.spec.ts's
 * real-Keycloak pattern (same ensurePrerequisites/assertBackendHealthy/
 * BPM_IDP_BASE_URL helpers, same completeBrowserLogin-shaped flow, same
 * oidc-callback-status intermediate wait), with the one load-bearing
 * difference: the suite starts a hard navigation at /exam instead of / and
 * asserts the final URL restores to /exam (not / or /platform-dashboard).
 *
 * This proves the fix end-to-end against a real Keycloak round trip — the
 * Vitest unit layer (web/src/auth/__tests__/safeRestorePath.test.ts,
 * web/src/auth/buildRedirectArgs.test.ts, and the ISS-0726 cases in
 * web/src/pages/__tests__/OidcCallbackPage.test.tsx) mocks
 * signinRedirectCallback entirely and never exercises the real
 * state/localStorage/Keycloak-redirect mechanics this fix depends on.
 *
 * See lib/letflow/design/iss-0726-oidc-redirect-path-restore.md §6.2 and
 * test/specs/ISS-0726.md.
 *
 * This suite uses no mocks or stubs. If BPM_TEST_DB_URL, BPM_TEST_URL, or
 * BPM_IDP_BASE_URL are missing, or if the backend / Keycloak readiness checks
 * fail, the tests throw a clear prerequisite error and fail immediately.
 */

import { test, expect, type APIRequestContext, type Page } from '@playwright/test'
import { assertBackendHealthy, BPM_IDP_BASE_URL } from './helpers'

const API_BASE_URL = (process.env.BPM_TEST_URL ?? '').replace(/\/$/, '')
const REQUIRED_DB_URL = process.env.BPM_TEST_DB_URL ?? ''
const SCREENSHOTS_DIR = 'tests/screenshots'
const KEYCLOAK_DISCOVERY_URL = `${BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`

function requireEnv(name: string, value: string): string {
  if (!value) {
    throw new Error(`ISS-0726 prerequisite not satisfied: ${name} is missing`)
  }

  return value
}

async function screenshot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: `${SCREENSHOTS_DIR}/ISS-0726-${name}.png` })
}

async function ensurePrerequisites(request: APIRequestContext): Promise<void> {
  requireEnv('BPM_TEST_DB_URL', REQUIRED_DB_URL)
  const apiBaseUrl = requireEnv('BPM_TEST_URL', API_BASE_URL)
  const keycloakBaseUrl = requireEnv('BPM_IDP_BASE_URL', BPM_IDP_BASE_URL)

  await assertBackendHealthy(request, apiBaseUrl)

  const keycloakDiscovery = await request.get(`${keycloakBaseUrl}/realms/bpm-default/.well-known/openid-configuration`)
  if (!keycloakDiscovery.ok()) {
    throw new Error(`ISS-0726 prerequisite not satisfied: Keycloak discovery check failed (${keycloakDiscovery.status()}) at ${KEYCLOAK_DISCOVERY_URL}`)
  }
}

async function completeBrowserLogin(page: Page, username: string, password: string): Promise<void> {
  const usernameInput = page.locator('input#username, input[name="username"]').first()
  const passwordInput = page.locator('input#password, input[name="password"]').first()

  await expect(usernameInput).toBeVisible({ timeout: 20_000 })
  await expect(passwordInput).toBeVisible({ timeout: 20_000 })
  await screenshot(page, 'keycloak-login-form')

  await usernameInput.fill(username)
  await passwordInput.fill(password)
  await screenshot(page, 'keycloak-credentials-filled')

  await page.locator('input[name="login"], [type="submit"]').first().click()
  await expect(page.getByTestId('oidc-callback-status')).toBeVisible({ timeout: 20_000 })
}

test.describe('ISS-0726 — OIDC deep-link path restore regression', () => {
  test('TC-ISS-0726-00: suite preflight fails fast when required backend/browser prerequisites are missing', async ({ request }) => {
    await ensurePrerequisites(request)
  })

  test('TC-ISS-0726-01: hard navigation to /exam restores /exam (not / or /platform-dashboard) after the real Keycloak round trip', async ({ request, page }) => {
    await ensurePrerequisites(request)

    // The one load-bearing difference from ISS-0063's TC-ISS-0063-02: start
    // the hard navigation at /exam, the originally-requested protected deep
    // link, instead of /.
    await page.goto('/exam')
    await screenshot(page, 'pre-login-hard-nav-to-exam')

    await completeBrowserLogin(page, 'admin-user', 'admin-pass')

    // The assertion that proves the fix end-to-end: the restored path is
    // /exam, not the pre-fix regression target (/) and not the
    // PLATFORM_ADMIN dashboard fallback (/platform-dashboard).
    await page.waitForURL('/exam', { timeout: 20_000 })

    await expect(page.getByTestId('exam-list-page')).toBeVisible({ timeout: 20_000 })
    await screenshot(page, 'exam-list-restored')
  })
})
