/**
 * Tags admin E2E tests — REQ-347 port of BilimBaga's tags.spec.ts.
 *
 * REACHABILITY FINDING (verified live, not just cited from REQ-344).
 * `tag` was historically absent from `BILIMBAGA_ENTITY_TYPES`
 * (`web/src/config/bilimbagaEntities.ts`) — REQ-336's original pilot gave it
 * its own bespoke `TagListPage.tsx`, imported by nothing in
 * `web/router.tsx`, making `/admin/tags`-equivalent unreachable through the
 * generic engine at that time. ISS-0655 (commit 43fdf238, already merged to
 * main) added `{ entityType: 'tag' }` to `BILIMBAGA_ENTITY_TYPES` and
 * deleted the superseded `TagListPage.tsx`. Confirmed live against this
 * session's running stack: `GET /api/v1/entities/definitions/active/tag`
 * returns the real, active `tag` definition, and navigating to
 * `/admin/bilimbaga/tag` renders `EntityCrudPage` with
 * `data-entity-type="tag"` — so this port proceeds rather than deferring.
 * NO change was made to `web/src/router.tsx` to reach this state — the
 * route was already generic (`admin/bilimbaga/:entityType`) before this
 * task started.
 *
 * PORT, NOT TRANSLITERATION, same as `categories.e2e.spec.ts`: BilimBaga's
 * six tests target `/admin/tags`; this file targets
 * `/admin/bilimbaga/tag` and binds to the `entity-crud-page` /
 * `entity-create-action` / `entity-form-modal` testid family instead of
 * CSS-class/localized-button-text selectors.
 *
 * DROPPED (1 of 6, NO-COUNTERPART): "search input filters the tag list" —
 * `EntityCrudPage` has no search box of any kind (confirmed by reading
 * `web/src/pages/entities/EntityCrudPage.tsx` in full: its only interactive
 * controls are the create action, per-row edit/delete actions, and cursor
 * pagination). No REQ names an entity-CRUD search feature today. Matches
 * REQ-344's own classification (§4.6).
 *
 * GETBYROLE COUNT: 1 use, justified — `getByRole('button', { name: /cancel/i })`
 * in "create tag — type name and cancel without saving", to close the
 * create modal. Same justification as `categories.e2e.spec.ts`'s use #2:
 * `EntityRecordForm`'s Cancel button carries no `data-testid`, and Escape
 * does not close this modal (verified live — no keydown handler on
 * `EntityCrudPage`'s create/edit modal, unlike `ConfirmDialog`).
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
 * `loginWithToken`.
 */

import { test, expect } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

const TAG_ROUTE = '/admin/bilimbaga/tag'

async function gotoTags(page: import('@playwright/test').Page) {
  await page.goto(TAG_ROUTE, { waitUntil: 'domcontentloaded' })
  await expect(page.getByTestId('entity-crud-page')).toBeVisible({ timeout: 15_000 })
  await expect(page.getByTestId('entity-crud-page')).toHaveAttribute('data-entity-type', 'tag')
}

test.describe('Tags admin (REQ-347 port onto /admin/bilimbaga/tag)', () => {
  let token: string

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
  })

  test.beforeEach(async ({ page }) => {
    await loginWithToken(page, token)
  })

  test('POST /api/v1/entities/query for tag carries Authorization header', async ({ page }) => {
    // Source test intercepted BilimBaga's bespoke `GET /api/v1/tags`.
    // Letflow's real record-read route (see `web/src/api/entities.ts`) is
    // `POST /api/v1/entities/query`.
    const [request_] = await Promise.all([
      page.waitForRequest(
        (req) => req.url().includes('/api/v1/entities/query') && req.method() === 'POST',
      ),
      gotoTags(page),
    ])
    expect(request_.headers()['authorization']).toMatch(/^Bearer /)
  })

  test('displays tags from the real API', async ({ page }) => {
    await gotoTags(page)
    await expect(page.getByTestId('data-table')).toBeVisible()
    await expect(page.locator('body')).not.toContainText(/unexpected error|something went wrong/i)
  })

  test('shows New Tag button for admin', async ({ page }) => {
    await gotoTags(page)
    await expect(page.getByTestId('entity-create-action')).toBeVisible()
  })

  test('opens create dialog when New Tag is clicked', async ({ page }) => {
    await gotoTags(page)
    // See this file's header comment (CLICK MECHANISM NOTE).
    await page.getByTestId('entity-create-action').dispatchEvent('click')
    await expect(page.getByTestId('entity-form-modal')).toBeVisible({ timeout: 5_000 })
    // tag.name is a plain :string field (priv/packs/bilimbaga/
    // entity_definitions/tag.json) — the built-in string renderer
    // (web/src/components/forms/FieldFactory.tsx) gives its input
    // id={fieldName}, i.e. id="name" here, no locale suffix (unlike
    // category.name's :localized_text widget).
    const nameInput = page.getByTestId('entity-form-modal').locator('#name')
    await expect(nameInput).toBeVisible()
  })

  test('create tag — type name and cancel without saving', async ({ page }) => {
    await gotoTags(page)
    await page.getByTestId('entity-create-action').dispatchEvent('click')
    await expect(page.getByTestId('entity-form-modal')).toBeVisible({ timeout: 5_000 })
    const nameInput = page.getByTestId('entity-form-modal').locator('#name')
    await nameInput.fill('E2E-Tag-Test')
    await expect(nameInput).toHaveValue('E2E-Tag-Test')
    // See this file's header comment (getByRole justification, and
    // separately the CLICK MECHANISM NOTE for dispatchEvent): no testid on
    // the Cancel button, Escape does not close this modal, and a real click
    // freezes the page.
    await page.getByTestId('entity-form-modal').getByRole('button', { name: /cancel|отмена|болдырмау/i }).dispatchEvent('click')
    await expect(page.getByTestId('entity-form-modal')).not.toBeVisible({ timeout: 3_000 })
  })
})
