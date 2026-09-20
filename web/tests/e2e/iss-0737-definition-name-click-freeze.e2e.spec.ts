/**
 * E2E regression guard — ISS-0737: real trusted click on DefinitionListPage's
 * `def-name-${id}` span (expand version history) froze the renderer's main
 * thread, in BOTH `npm run dev` and `npm run build && vite preview` (unlike
 * ISS-0729, this is not dev/StrictMode-only).
 *
 * ISSUE-FIXER's diagnosis (docs/issues/ISS-0738.yaml — the issue's own
 * queue_ref/issue_ref is ISS-0737; the local filename differs only because
 * of a pre-existing filename collision, see that file's own NOTE) and this
 * fix's design (lib/letflow/design/WF03-ISS0737-fix-design.md) established
 * that `DefinitionListPage.tsx`'s bespoke inline `onClick` on the
 * `def-name-${def.id}` span called `setExpandedDefId`/`setExpandedDefName`
 * synchronously inside the same native trusted click's event-dispatch turn —
 * the same general trigger class ISS-0662 already confirmed and fixed via
 * `web/src/utils/deferClickState.ts`, but that original fix pass touched
 * only `DataTable.tsx`'s sort-header click and `EntityCrudPage.tsx`'s
 * handlers, never this page's own bespoke handler. The fix wraps this
 * handler's existing, unchanged body in `deferClickState(() => {...})`,
 * exactly mirroring `DataTable.tsx`'s `handleHeaderClick`.
 *
 * WHY THIS TEST USES `hover()` + `mouse.down()` + `mouse.up()`, NOT
 * `Locator.click()` OR `Locator.dispatchEvent('click')`: per the design
 * doc's §4 (citing ISS-0662's own design §3.3), `dispatchEvent('click')`
 * never reproduced the freeze class at all and would not catch a
 * regression here either. Driving the gesture directly and racing it
 * against an explicit bound gives a fast, unambiguous failure ("froze past
 * <n>ms") instead of a generic Playwright action-timeout, matching
 * `iss-0662-entity-crud-click-freeze.e2e.spec.ts`'s own convention exactly.
 *
 * FAIL-THEN-PASS (WF-03 Step 4): this file must fail against the pre-fix
 * tree (the wrap in `DefinitionListPage.tsx` reverted) and pass post-fix —
 * see this run's FRONTEND-DEV handoff for the real quoted output both ways.
 * Every bounded-click assertion below is paired with an assertion on the
 * resulting UI state (`version-history-row` visible/hidden), not merely
 * that the click resolved — guarding against a "hangs forever" bug
 * producing a false pass, and against the fix silently swallowing the
 * state update rather than merely deferring it by one tick (design §4,
 * citing ISS-0662 §4's own swallow-regression risk).
 *
 * Covers both branches ISSUE-FIXER validated as reproducing the freeze:
 * (a) unfiltered list — click a `def-name-${id}` span directly;
 * (b) filtered list — type into the search box first, then click the
 * matching row's `def-name-${id}` span. Ruling out `isSearching`/
 * `highlightText` as causal is the point of keeping both branches, not
 * just one.
 *
 * Authentication: `web/tests/e2e/helpers.ts`'s `getKeycloakToken`/
 * `loginWithToken`, same as the sibling ISS-0662/ISS-0729 specs.
 */

import { test, expect, type Locator, type Page } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

const API_PREFIX = '/api/v1'
// Generous above the fix's measured ~1s resolution, tight enough that a
// genuine sustained freeze reliably trips it — same bound and reasoning as
// the ISS-0662/ISS-0729 sibling specs use.
const BOUND_MS = 5_000

/**
 * Drives a REAL, UA-trusted click (hover -> mousedown -> mouseup) raced
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
    // already handled via the timeout branch below.
  })
  let timer: ReturnType<typeof setTimeout>
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`ISS-0737 regression: trusted click on "${label}" did not resolve within ${boundMs}ms (froze the renderer)`)),
      boundMs,
    )
  })
  try {
    await Promise.race([upPromise, timeout])
  } finally {
    clearTimeout(timer!)
  }
}

async function createTestDefinition(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  name: string,
  version: string,
): Promise<{ id: string; name: string; version: string; status: string }> {
  const response = await request.post(`${API_PREFIX}/definitions`, {
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      name,
      version,
      description: '',
      graph: {
        nodes: [
          { id: 'start', node_type: 'START', label: null, attributes: null },
          { id: 'end', node_type: 'END', label: null, attributes: null },
        ],
        edges: [
          { id: 'e1', source: 'start', target: 'end', condition: null, is_default: false },
        ],
      },
      stage: null,
    },
  })
  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`POST /definitions failed (${response.status()}): ${body}`)
  }
  return response.json() as Promise<{ id: string; name: string; version: string; status: string }>
}

async function deleteTestDefinition(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  id: string,
): Promise<void> {
  const response = await request.delete(`${API_PREFIX}/definitions/${id}`, {
    headers: { 'Authorization': `Bearer ${token}` },
  })
  if (response.status() !== 204 && response.status() !== 404) {
    console.warn(`DELETE /definitions/${id} returned ${response.status()}`)
  }
}

async function gotoDefinitions(page: Page): Promise<void> {
  await page.goto('/definitions', { waitUntil: 'domcontentloaded' })
  await expect(page.getByTestId('definition-search')).toBeVisible({ timeout: 15_000 })
}

test.describe('ISS-0737 — DefinitionListPage def-name click renderer-freeze regression', () => {
  let token: string
  const createdIds: string[] = []

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
  })

  test.beforeEach(async ({ page }) => {
    await loginWithToken(page, token)
  })

  test.afterAll(async ({ request }) => {
    for (const id of createdIds) {
      await deleteTestDefinition(request, token, id)
    }
  })

  test('TC-ISS-0737-01: real click on def-name (unfiltered list) expands and collapses version history within 5s', async ({ page, request }) => {
    const unique = `ISS-0737-unfiltered-${Date.now()}`
    const def = await createTestDefinition(request, token, unique, '1.0.0')
    createdIds.push(def.id)

    await gotoDefinitions(page)
    const nameSpan = page.getByTestId(`def-name-${def.id}`)
    await expect(nameSpan).toBeVisible({ timeout: 15_000 })

    // Expand: real trusted click must resolve within bound, and the
    // version-history row must actually appear (not merely "click resolved").
    await trustedClickBounded(nameSpan, `def-name-${def.id} (unfiltered, expand)`)
    await expect(page.getByTestId('version-history-row')).toBeVisible({ timeout: BOUND_MS })

    // Collapse: same span, same handler's else-branch.
    await trustedClickBounded(nameSpan, `def-name-${def.id} (unfiltered, collapse)`)
    await expect(page.getByTestId('version-history-row')).not.toBeVisible({ timeout: BOUND_MS })
  })

  test('TC-ISS-0737-02: real click on def-name (filtered/search-active list) expands and collapses version history within 5s', async ({ page, request }) => {
    const unique = `ISS-0737-filtered-${Date.now()}`
    const def = await createTestDefinition(request, token, unique, '1.0.0')
    createdIds.push(def.id)

    await gotoDefinitions(page)

    // Filter first — matches the platform-definition-promotion-rollback
    // pipeline spec's own flow of searching before clicking a def-name span,
    // and confirms the freeze/fix is independent of the isSearching/
    // highlightText render branch.
    const searchInput = page.getByTestId('definition-search')
    await searchInput.fill(unique)
    // Allow debounce (300ms) + fetch round-trip to settle before interacting,
    // matching this suite's sibling specs' own convention.
    await page.waitForTimeout(1500)

    const nameSpan = page.getByTestId(`def-name-${def.id}`)
    await expect(nameSpan).toBeVisible({ timeout: 15_000 })

    await trustedClickBounded(nameSpan, `def-name-${def.id} (filtered, expand)`)
    await expect(page.getByTestId('version-history-row')).toBeVisible({ timeout: BOUND_MS })

    await trustedClickBounded(nameSpan, `def-name-${def.id} (filtered, collapse)`)
    await expect(page.getByTestId('version-history-row')).not.toBeVisible({ timeout: BOUND_MS })
  })
})
