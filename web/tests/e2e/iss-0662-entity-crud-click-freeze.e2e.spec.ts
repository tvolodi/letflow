/**
 * E2E regression suite — ISS-0662: real trusted click freezes EntityCrudPage's
 * renderer.
 *
 * ISSUE-FIXER's diagnosis (docs/issues/ISS-0662.yaml) and this fix's design
 * (docs/frontend/iss-0662-entity-crud-page-click-freeze-fix.md) established
 * that ANY real, UA-trusted click or keyboard activation of ANY
 * state-changing action button on `EntityCrudPage` (create, edit, delete,
 * cancel) — and `DataTable`'s sort-header, wherever it renders inside that
 * page's tree — froze the entire browser tab's main thread. Confirmed
 * genuine (an unrelated CDP call issued on a separate channel also hung
 * during the freeze), not a Playwright-`dispatchEvent`-vs-`click` artifact:
 * `Locator.dispatchEvent('click')` never reproduced it, only a real trusted
 * gesture did. The fix (`web/src/utils/deferClickState.ts`, commit
 * 14b04903) defers every affected `setState` call by one macrotask so it
 * never runs synchronously inside the native click's own event-dispatch
 * turn. A follow-up fix (commit 0bf883fc) closed a double-submit race the
 * deferral itself introduced in `confirmDelete` (see that commit's message
 * and `EntityCrudPage.tsx`'s `deleteInFlightRef` comment).
 *
 * WHY THIS TEST USES `page.mouse.down()`/`page.mouse.up()`, NOT
 * `Locator.click()` OR `Locator.dispatchEvent('click')`: `dispatchEvent`
 * never exhibited the freeze at all (ISSUE-FIXER/this design's own finding)
 * and would not catch a regression. `Locator.click()` *is* a real trusted
 * gesture under the hood, but its actionability-wait/retry machinery makes
 * it hard to bound the exact hang to a tight timeout distinct from
 * Playwright's own action-timeout defaults. Driving `hover()` +
 * `mouse.down()` + `mouse.up()` directly, raced against an explicit
 * millisecond bound, matches the design doc's own tests 1-13 mechanism
 * exactly and gives a clear, fast, unambiguous failure
 * ("froze past <n>ms") instead of a generic 30s Playwright timeout error.
 *
 * FAIL-THEN-PASS (WF-03 Step 4): this file must fail against the pre-fix
 * tree and pass post-fix — see this run's TEST-DESIGNER handoff for the
 * exact commits checked out and the real quoted output both ways. A
 * "hangs forever" bug could produce a false pass if a test only checked
 * for absence-of-timeout without checking the resulting UI state, so every
 * bounded-click assertion below is paired with an assertion that the
 * correct end state actually appeared (modal visible, sort indicator
 * visible, dialog gone) — not merely that the click resolved.
 *
 * Authentication: `web/tests/e2e/helpers.ts`'s `getKeycloakToken`/
 * `loginWithToken`, same as `categories.e2e.spec.ts`/`tags.e2e.spec.ts`.
 */

import { test, expect, type Locator, type Page, type APIRequestContext } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

const CATEGORY_ROUTE = '/admin/bilimbaga/category'
const TAG_ROUTE = '/admin/bilimbaga/tag'
const BOUND_MS = 5_000

/**
 * Drives a REAL, UA-trusted click (hover -> mousedown -> mouseup, exactly
 * the gesture ISS-0662's design doc used in its own reproduction), raced
 * against `boundMs`. If the freeze regresses, `mouse.up()` never resolves
 * and this rejects with a clear message well before Playwright's own
 * (much longer) default action/test timeout would trip.
 */
async function trustedClickBounded(locator: Locator, label: string, boundMs = BOUND_MS): Promise<void> {
  await locator.hover()
  await locator.page().mouse.down()
  const upPromise = locator.page().mouse.up()
  upPromise.catch(() => {
    // Swallow a late rejection/resolution racing past the bound below —
    // already handled via the timeout branch; this only prevents an
    // unhandled-rejection warning if the underlying gesture errors after
    // this function has already returned.
  })
  let timer: ReturnType<typeof setTimeout>
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`ISS-0662 regression: trusted click on "${label}" did not resolve within ${boundMs}ms (froze the renderer)`)),
      boundMs,
    )
  })
  try {
    await Promise.race([upPromise, timeout])
  } finally {
    clearTimeout(timer!)
  }
}

async function gotoCategories(page: Page): Promise<void> {
  await page.goto(CATEGORY_ROUTE, { waitUntil: 'domcontentloaded' })
  await expect(page.getByTestId('entity-crud-page')).toBeVisible({ timeout: 15_000 })
  await expect(page.getByTestId('entity-crud-page')).toHaveAttribute('data-entity-type', 'category')
}

async function gotoTags(page: Page): Promise<void> {
  await page.goto(TAG_ROUTE, { waitUntil: 'domcontentloaded' })
  await expect(page.getByTestId('entity-crud-page')).toBeVisible({ timeout: 15_000 })
  await expect(page.getByTestId('entity-crud-page')).toHaveAttribute('data-entity-type', 'tag')
}

/** Creates a `tag` record directly via the API (bypassing the UI's own
 *  create flow, which this suite already exercises elsewhere) so the
 *  delete-focused tests have a real row to act on. `tag.name` is a plain
 *  `:string` field (see `tags.e2e.spec.ts`'s own comment on this). */
async function apiCreateTag(request: APIRequestContext, token: string, name: string): Promise<string> {
  const response = await request.post('/api/v1/entities/records/tag', {
    headers: { Authorization: `Bearer ${token}` },
    data: { field_values: { name } },
  })
  expect(response.ok(), `apiCreateTag failed: ${response.status()} ${await response.text()}`).toBe(true)
  const body = await response.json() as { record_id: string }
  return body.record_id
}

/** Deletes a `tag` record directly via the API. Used as teardown for tests
 *  (TC-ISS-0662-03) that only exercise a non-destructive UI path (the
 *  confirm-dialog CANCEL button) on a record `apiCreateTag` created, so the
 *  record is never removed by the UI flow itself and would otherwise leak
 *  into the shared dev tenant on every run. Tolerant of a record that is
 *  already gone (e.g. a test that deleted it itself before this ran). */
async function apiDeleteTag(request: APIRequestContext, token: string, recordId: string): Promise<void> {
  const response = await request.delete(`/api/v1/entities/records/tag/${recordId}`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  expect(
    response.ok() || response.status() === 404,
    `apiDeleteTag cleanup failed for ${recordId}: ${response.status()} ${await response.text()}`,
  ).toBe(true)
}

test.describe('ISS-0662 — EntityCrudPage real-click renderer-freeze regression', () => {
  let token: string
  // Tracks any tag record created via apiCreateTag whose test only exercises
  // a non-destructive UI path (e.g. confirm-dialog CANCEL), so afterEach can
  // clean it up via the API and no run leaks an `ISS-0662-*` row into the
  // shared dev tenant. Each test that needs cleanup sets this before it
  // creates the record's UI-visible state; afterEach clears it after use.
  let recordIdToCleanUp: string | undefined

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
  })

  test.beforeEach(async ({ page }) => {
    recordIdToCleanUp = undefined
    await loginWithToken(page, token)
  })

  test.afterEach(async ({ request }) => {
    if (recordIdToCleanUp !== undefined) {
      await apiDeleteTag(request, token, recordIdToCleanUp)
      recordIdToCleanUp = undefined
    }
  })

  test('TC-ISS-0662-01: real click on entity-create-action opens the create modal within 5s', async ({ page }) => {
    await gotoCategories(page)
    await trustedClickBounded(page.getByTestId('entity-create-action'), 'entity-create-action')
    // Guards against the fix silently swallowing the state update (deferred
    // forever) rather than merely deferring it by one tick.
    await expect(page.getByTestId('entity-form-modal')).toBeVisible({ timeout: BOUND_MS })
  })

  test('TC-ISS-0662-02: real click on the create modal Cancel button closes it within 5s', async ({ page }) => {
    await gotoCategories(page)
    // Bounded, not a plain `.click()`: this setup step is itself one of
    // ISS-0662's originally-filed freeze paths, so it must not be allowed to
    // fall through to Playwright's own (much longer) test-timeout on a
    // regression — see this file's header comment.
    await trustedClickBounded(page.getByTestId('entity-create-action'), 'entity-create-action (setup)')
    await expect(page.getByTestId('entity-form-modal')).toBeVisible({ timeout: BOUND_MS })

    const cancelButton = page.getByTestId('entity-form-modal').getByRole('button', { name: /cancel|отмена|болдырмау/i })
    await trustedClickBounded(cancelButton, 'entity-form-modal cancel button')
    await expect(page.getByTestId('entity-form-modal')).not.toBeVisible({ timeout: BOUND_MS })
  })

  test('TC-ISS-0662-03: real click on a row entity-delete action opens the confirm dialog within 5s', async ({ page, request }) => {
    const recordId = await apiCreateTag(request, token, `ISS-0662-delete-${Date.now()}`)
    // This test only exercises the CANCEL path (by design — it proves the
    // confirm dialog opens on a real click, not that delete completes), so
    // the record is never removed by the UI itself. Register it for the
    // afterEach hook to remove via the API once this test finishes.
    recordIdToCleanUp = recordId

    await gotoTags(page)
    const deleteButton = page.getByTestId(`entity-delete-${recordId}`)
    await expect(deleteButton).toBeVisible({ timeout: 15_000 })

    await trustedClickBounded(deleteButton, `entity-delete-${recordId}`)
    await expect(page.getByTestId('confirm-dialog')).toBeVisible({ timeout: BOUND_MS })

    // Dismiss without deleting — that's this test's own assertion intent
    // (real click opens the confirm dialog); actual record removal is
    // handled by afterEach's apiDeleteTag cleanup above, not the UI.
    await page.getByTestId('confirm-dialog-cancel').click()
  })

  test('TC-ISS-0662-04: real click on the DataTable sort header applies sorting within 5s', async ({ page }) => {
    await gotoCategories(page)
    const sortHeader = page.getByTestId('datatable-header-name')
    await expect(sortHeader).toBeVisible({ timeout: 15_000 })

    await trustedClickBounded(sortHeader, 'datatable-header-name')
    // Guards against the deferred setState never actually landing: the
    // sort indicator must actually appear, not just "the click resolved".
    await expect(page.getByTestId('datatable-sort-indicator-name')).toBeVisible({ timeout: BOUND_MS })
  })

  test('TC-ISS-0662-05 (double-submit race, commit 0bf883fc): a rapid real double-click on confirm-dialog-confirm fires exactly one DELETE request', async ({ page, request }) => {
    const recordId = await apiCreateTag(request, token, `ISS-0662-doubleclick-${Date.now()}`)
    // Register for afterEach cleanup immediately, before any UI interaction
    // that could throw (same pattern as TC-ISS-0662-03 above). This test's
    // own assertion path deletes the record itself via a real UI double-click,
    // but if the test fails partway (env flake, a timing regression, or the
    // exact double-submit bug recurring) before that delete lands, the
    // record must still be reclaimed rather than leaking into the shared dev
    // tenant. apiDeleteTag tolerates an already-deleted (404) record, so a
    // successful run's own UI delete does not cause a spurious afterEach
    // failure here.
    recordIdToCleanUp = recordId

    await gotoTags(page)
    const deleteButton = page.getByTestId(`entity-delete-${recordId}`)
    await expect(deleteButton).toBeVisible({ timeout: 15_000 })
    // Bounded, not a plain `.click()` — same reasoning as TC-ISS-0662-02's
    // setup click above.
    await trustedClickBounded(deleteButton, `entity-delete-${recordId} (setup)`)
    await expect(page.getByTestId('confirm-dialog')).toBeVisible({ timeout: BOUND_MS })

    const deleteRequests: string[] = []
    page.on('request', (req) => {
      if (req.method() === 'DELETE' && req.url().includes(`/api/v1/entities/records/tag/${recordId}`)) {
        deleteRequests.push(req.url())
      }
    })

    const confirmButton = page.getByTestId('confirm-dialog-confirm')
    // Two real trusted clicks, back to back, as fast as this script can
    // issue them — the exact shape SECURITY-REVIEWER flagged: a second
    // click/Enter landing inside the macrotask window between "confirm
    // clicked" and "mutate() actually called" (see commit 0bf883fc's
    // message and EntityCrudPage.tsx's deleteInFlightRef comment).
    await confirmButton.hover()
    await page.mouse.down()
    await page.mouse.up()
    await page.mouse.down()
    await page.mouse.up()

    // Let the deferred mutate() call(s) actually reach the network before
    // counting — deferClickState's macrotask plus the mutation round-trip.
    await expect(page.getByTestId('confirm-dialog')).not.toBeVisible({ timeout: 10_000 })
    await page.waitForTimeout(500)

    expect(deleteRequests.length, `expected exactly one DELETE for ${recordId}, saw ${deleteRequests.length}: ${JSON.stringify(deleteRequests)}`).toBe(1)
  })
})
