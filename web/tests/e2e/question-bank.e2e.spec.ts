/**
 * Question Bank admin E2E tests — REQ-347 port of BilimBaga's
 * question-bank.spec.ts.
 *
 * PORT, NOT TRANSLITERATION: BilimBaga's seven tests target its own bespoke
 * `/admin/questions` screen (heading + table, New-Question button that
 * navigates to a dedicated `/admin/questions/new` editor, a search box,
 * difficulty badges, Import/AI-Generate buttons). Letflow's real
 * counterpart is the generic `/admin/bilimbaga/question` screen
 * (`EntityCrudPage`, REQ-343).
 *
 * ONLY 2 OF 7 SOURCE TESTS HAVE A REAL COUNTERPART. Per REQ-344's triage
 * (§4.8), re-verified live here by reading
 * `web/src/pages/entities/EntityCrudPage.tsx` in full:
 *
 *   PORTED (2):
 *   - "displays the question bank heading and table" -> the page renders a
 *     `data-table` inside `entity-crud-page` with no crash.
 *   - "shows the New Question button" -> the generic `entity-create-action`
 *     button.
 *
 *   DROPPED (5, each with its specific missing Letflow behaviour):
 *   - "navigates to question editor on New Question click" — asserts the
 *     URL becomes `/admin/questions/new`. `entity-create-action` opens an
 *     in-page `entity-form-modal`, not a URL navigation to a dedicated
 *     editor route; no such route exists or is planned under S10 for the
 *     generic entity-CRUD engine.
 *   - "shows difficulty badges for existing questions" — the source
 *     assertion body only checks `table tbody tr` row count (no actual
 *     badge/color/style assertion), which duplicates the "heading and
 *     table" test's own coverage; genuinely testing "difficulty badge"
 *     would require asserting a styled badge component, which
 *     `EntityCrudPage` does not render (`formatCellValue` in
 *     `EntityCrudPage.tsx` renders every enum field, `difficulty` included,
 *     as a plain `String(value)` table cell — no badge/pill styling of any
 *     kind). Dropped rather than kept as a redundant row-count duplicate of
 *     the first ported test.
 *   - "search input filters questions without crashing" — `EntityCrudPage`
 *     has no search input at all (its only interactive controls are the
 *     create action, per-row edit/delete, and cursor pagination).
 *   - "shows empty state when search matches nothing" — same missing
 *     search-box behaviour as above.
 *   - "shows Import and AI Generate buttons" — no import or AI-generate
 *     feature exists anywhere in the generic entity-CRUD engine; not named
 *     in REQ-347's scope.
 *
 * GETBYROLE COUNT: 0 uses — both ported tests select purely via
 * `entity-crud-page` / `data-table` / `entity-create-action` testids.
 *
 * Authentication: `web/tests/e2e/helpers.ts`'s `getKeycloakToken`/
 * `loginWithToken`.
 */

import { test, expect } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

const QUESTION_ROUTE = '/admin/bilimbaga/question'

async function gotoQuestions(page: import('@playwright/test').Page) {
  await page.goto(QUESTION_ROUTE, { waitUntil: 'domcontentloaded' })
  await expect(page.getByTestId('entity-crud-page')).toBeVisible({ timeout: 15_000 })
  await expect(page.getByTestId('entity-crud-page')).toHaveAttribute('data-entity-type', 'question')
}

test.describe('Question Bank admin (REQ-347 port onto /admin/bilimbaga/question)', () => {
  let token: string

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
  })

  test.beforeEach(async ({ page }) => {
    await loginWithToken(page, token)
  })

  test('displays the question bank list without error', async ({ page }) => {
    await gotoQuestions(page)
    await expect(page.getByTestId('data-table')).toBeVisible()
    await expect(page.locator('body')).not.toContainText(/unexpected error|something went wrong/i)
  })

  test('shows the New Question button', async ({ page }) => {
    await gotoQuestions(page)
    await expect(page.getByTestId('entity-create-action')).toBeVisible()
  })
})
