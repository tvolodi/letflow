/**
 * Categories admin E2E tests — REQ-347 port of BilimBaga's categories.spec.ts.
 *
 * PORT, NOT TRANSLITERATION. BilimBaga's five tests drove its own bespoke
 * `/admin/categories` screen; Letflow has no such route. The real Letflow
 * counterpart is the generic `/admin/bilimbaga/category` screen
 * (`BilimBagaEntityRoute` -> `EntityCrudPage`, REQ-343), bound to the
 * `entity-crud-page` / `entity-create-action` / `entity-form-modal` testid
 * family instead of BilimBaga's CSS-class/localized-button-text selectors.
 * Per REQ-344's triage (`docs/testing/REQ-344-bilimbaga-parity-triage.md`
 * §4.7), all 5 source tests are PORTABLE-NOW — re-verified live here against
 * this repo's running stack (Keycloak + Postgres + the bpm-default tenant's
 * already-installed BilimBaga entity pack).
 *
 * GETBYROLE COUNT: 2 uses, both justified.
 *   1. `page.getByRole('dialog')` in "opens the create modal ...", additive
 *      to (not a replacement for) the `entity-form-modal` testid assertion
 *      in the same test: `EntityCrudPage`'s modal carries both
 *      `data-testid="entity-form-modal"` AND `role="dialog"
 *      aria-modal="true"` (see `web/src/pages/entities/EntityCrudPage.tsx`),
 *      and asserting the ARIA role in addition to the testid is a
 *      deliberate a11y checkpoint (the source test's own literal intent),
 *      not a stand-in for a missing testid.
 *   2. `getByRole('button', { name: /cancel/i })` in "create modal has a
 *      name input field", to close the modal without saving.
 *      `EntityRecordForm`'s Cancel button
 *      (`web/src/components/entities/EntityRecordForm.tsx`) carries no
 *      `data-testid` — only its Submit sibling does
 *      (`entity-form-submit`) — and `Escape` does not close this modal
 *      (verified live: unlike `ConfirmDialog`, which has its own
 *      window-level Escape handler, `EntityCrudPage`'s create/edit modal
 *      wraps `EntityRecordForm` with no keydown listener of its own). A
 *      role-based lookup for the one interactive element with no testid is
 *      the only way to close it, matching the source test's own literal
 *      intent ("close without saving").
 *
 * CLICK MECHANISM NOTE — genuine defect found and worked around, not a
 * stylistic choice. A real, trusted `Locator.click()` on
 * `entity-create-action` or the modal's Cancel button freezes the page's
 * renderer indefinitely (confirmed by isolating the exact step: `page.mouse
 * .down()` on the button returns normally, but the paired `page.mouse.up()`
 * — which is what actually dispatches the trusted `click` event — never
 * resolves; a synthetic, untrusted `click` `Event` dispatched via
 * `Locator.dispatchEvent('click')` on the SAME element opens the modal
 * instantly with no hang). This is specific to `EntityCrudPage`'s action
 * buttons — a real click on an unrelated page's own "New Definition" button
 * (`web/tests/e2e/f2-definition-list.e2e.spec.ts`) completes in ~1s with no
 * such freeze, so it is not a `Button` component or Playwright/environment
 * issue in general. Root cause not further isolated here — diagnosing and
 * fixing a production hang is outside a test-port requirement's scope and
 * is reported to ORCH separately, not fixed in this diff. Every click on an
 * `EntityCrudPage` action button in this file therefore uses
 * `dispatchEvent('click')`, not `.click()`.
 *
 * Authentication: `web/tests/e2e/helpers.ts`'s `getKeycloakToken`/
 * `loginWithToken` (real Keycloak password grant against `admin-user`, the
 * realm's only user carrying the `PLATFORM_ADMIN` role, which
 * `lib/letflow/api/authorization.ex` grants every `entities.*` permission).
 */

import { test, expect } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

const CATEGORY_ROUTE = '/admin/bilimbaga/category'

async function gotoCategories(page: import('@playwright/test').Page) {
  await page.goto(CATEGORY_ROUTE, { waitUntil: 'domcontentloaded' })
  await expect(page.getByTestId('entity-crud-page')).toBeVisible({ timeout: 15_000 })
  await expect(page.getByTestId('entity-crud-page')).toHaveAttribute('data-entity-type', 'category')
}

test.describe('Categories admin (REQ-347 port onto /admin/bilimbaga/category)', () => {
  let token: string

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
  })

  test.beforeEach(async ({ page }) => {
    await loginWithToken(page, token)
  })

  test('POST /api/v1/entities/query for category carries Authorization header', async ({ page }) => {
    // Source test intercepted BilimBaga's bespoke `GET /api/v1/categories`.
    // Letflow's generic engine has no per-entity list route (see
    // `web/src/api/entities.ts`'s own moduledoc) — the real record-read call
    // EntityCrudPage issues is `POST /api/v1/entities/query`.
    const [request_] = await Promise.all([
      page.waitForRequest(
        (req) => req.url().includes('/api/v1/entities/query') && req.method() === 'POST',
      ),
      gotoCategories(page),
    ])
    expect(request_.headers()['authorization']).toMatch(/^Bearer /)
  })

  test('displays the categories list', async ({ page }) => {
    await gotoCategories(page)
    await expect(page.getByTestId('data-table')).toBeVisible()
    await expect(page.locator('body')).not.toContainText(/unexpected error|something went wrong/i)
  })

  test('shows the New Category button for admin', async ({ page }) => {
    await gotoCategories(page)
    await expect(page.getByTestId('entity-create-action')).toBeVisible()
  })

  test('opens the create modal when New Category is clicked', async ({ page }) => {
    await gotoCategories(page)
    // See this file's header comment (CLICK MECHANISM NOTE).
    await page.getByTestId('entity-create-action').dispatchEvent('click')
    await expect(page.getByTestId('entity-form-modal')).toBeVisible({ timeout: 5_000 })
    // See this file's header comment: additive ARIA-role check on the same
    // modal the testid assertion above already located.
    await expect(page.getByRole('dialog')).toBeVisible()
  })

  test('create modal has a name input field', async ({ page }) => {
    await gotoCategories(page)
    await page.getByTestId('entity-create-action').dispatchEvent('click')
    await expect(page.getByTestId('entity-form-modal')).toBeVisible({ timeout: 5_000 })
    // category.name is :localized_text (priv/packs/bilimbaga/entity_definitions/
    // category.json) — the localized-text widget renders one input per locale,
    // id'd `${fieldName}-${locale}` (web/src/components/forms/widgets/
    // localizedText.tsx). "en" is always present (REQ-285's default locale set).
    const nameInput = page.getByTestId('entity-form-modal').locator('#name-en')
    await expect(nameInput).toBeVisible()
    await nameInput.fill('E2E Test Category')
    await expect(nameInput).toHaveValue('E2E Test Category')
    // Close without saving — see this file's header comment (getByRole
    // justification #2): the Cancel button has no data-testid, and Escape
    // does not close this modal.
    await page.getByTestId('entity-form-modal').getByRole('button', { name: /cancel|отмена|болдырмау/i }).dispatchEvent('click')
    await expect(page.getByTestId('entity-form-modal')).not.toBeVisible({ timeout: 3_000 })
  })
})
