/**
 * E2E regression — ISS-0664: freshly created record pushed off page 1 by
 * accumulated soft-deleted rows.
 *
 * ISS-0664 (GH#1399) was discovered by TEST-DESIGNER during ISS-0662's
 * regression-test rework: with `PAGE_SIZE = 25` and no explicit sort,
 * `EntityCrudPage.tsx`'s list query could push a freshly created record off
 * page 1 once a tag/entity table accumulated >25 soft-deleted rows, because
 * `POST /api/v1/entities/query` did not filter `deleted:true` rows out of
 * the candidate set before pagination.
 *
 * Root-cause determination for THIS issue's close-out (see docs/issues/ISS-0664.yaml
 * for the full writeup): candidate fix (a) -- filtering `deleted:false` by
 * default -- already landed in ISS-0663 (commit 52fcc85a, PR #1398):
 * `EntityCrudPage.tsx`'s `recordsQuery` now sends `EXCLUDE_DELETED_FILTERS`
 * (`[{field: 'deleted', op: 'eq', value: false}]`) on every list request.
 *
 * `lib/letflow/entities/query/compiler.ex`'s `compile_plain/5` applies every
 * filter clause (deleted-exclusion included) as part of the query's `WHERE`
 * before `Letflow.Entities.Query.Cursor.paginate/5` ever adds its
 * `limit(page_size + 1)` on top of that already-filtered, not-yet-executed
 * `Ecto.Query.t()` -- i.e. filtering happens at the SQL level, strictly
 * before the LIMIT/keyset window is applied, not as a post-fetch filter on
 * an already-paginated result set. That means deleted rows no longer occupy
 * ANY slot in the page-1 candidate set at all once excluded -- they don't
 * merely get hidden after counting toward pagination math, they never enter
 * the count in the first place. So candidate fix (a) alone fully resolves
 * the specific flake this issue reports (a freshly created record pushed off
 * page 1 BY ACCUMULATED DELETED ROWS): as long as live (non-deleted) records
 * number <= PAGE_SIZE, a newly created one is guaranteed a page-1 slot
 * regardless of how many deleted rows separately accumulate, and regardless
 * of the implicit `record_id`-ordering `Cursor.paginate/5` tiebreaks on.
 *
 * Candidate fix (b) -- explicit `sort: created_at desc` -- was evaluated and
 * NOT implemented here: it would help a DIFFERENT scenario (page-1 placement
 * among many LIVE records, not deleted ones) that this issue does not
 * report, and is not needed to close the reported flake. Treated as
 * unnecessary scope creep for this MINOR issue; not implemented.
 *
 * This test proves the reported failure mode does not recur: create a
 * record, soft-delete several OTHER records after it (so they'd sort after
 * it by insertion-adjacent `record_id` in at least some runs), and confirm
 * the original record is still visible on page 1.
 */

import { test, expect, type APIRequestContext } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

const TAG_ROUTE = '/admin/bilimbaga/tag'
// Comfortably more than one page (PAGE_SIZE = 25 in EntityCrudPage.tsx) worth
// of soft-deleted rows, matching the issue's own "accumulates >25
// soft-deleted rows" reproduction shape.
const DELETED_ROW_COUNT = 30

async function apiCreateTag(request: APIRequestContext, token: string, name: string): Promise<string> {
  const response = await request.post('/api/v1/entities/records/tag', {
    headers: { Authorization: `Bearer ${token}` },
    data: { field_values: { name } },
  })
  expect(response.ok(), `apiCreateTag failed: ${response.status()} ${await response.text()}`).toBe(true)
  const body = (await response.json()) as { record_id: string }
  return body.record_id
}

async function apiDeleteTag(request: APIRequestContext, token: string, recordId: string): Promise<void> {
  const response = await request.delete(`/api/v1/entities/records/tag/${recordId}`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  expect(
    response.ok() || response.status() === 404,
    `apiDeleteTag cleanup failed for ${recordId}: ${response.status()} ${await response.text()}`,
  ).toBe(true)
}

test.describe('ISS-0664 — EntityCrudPage page-1 stability despite accumulated soft-deleted rows', () => {
  let token: string

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
  })

  test.beforeEach(async ({ page }) => {
    await loginWithToken(page, token)
  })

  test('TC-ISS-0664-01: a record created before >25 soft-deleted rows accumulate still appears on page 1', async ({ page, request }) => {
    const targetName = `ISS-0664-target-${Date.now()}`
    const targetRecordId = await apiCreateTag(request, token, targetName)

    // Accumulate more soft-deleted rows than one page holds, created AFTER
    // the target record -- the exact ordering the original flake depended on
    // ("implicit UUID/insertion ordering" could sort these anywhere relative
    // to the target).
    const churnRecordIds: string[] = []
    try {
      for (let i = 0; i < DELETED_ROW_COUNT; i++) {
        const id = await apiCreateTag(request, token, `ISS-0664-churn-${Date.now()}-${i}`)
        churnRecordIds.push(id)
      }
      for (const id of churnRecordIds) {
        await apiDeleteTag(request, token, id)
      }

      await page.goto(TAG_ROUTE, { waitUntil: 'domcontentloaded' })
      await expect(page.getByTestId('entity-crud-page')).toBeVisible({ timeout: 15_000 })

      // The target record's row (identified by its own edit/delete action
      // testids, keyed by record_id) must be present on page 1 -- no
      // pagination click needed. This is the exact assertion shape ISS-0662's
      // suite uses ("entity-delete-<id> element not found" was the original
      // symptom this issue traced that flake to).
      await expect(page.getByTestId(`entity-delete-${targetRecordId}`)).toBeVisible({ timeout: 15_000 })
      await expect(page.getByText(targetName)).toBeVisible()
    } finally {
      await apiDeleteTag(request, token, targetRecordId)
      for (const id of churnRecordIds) {
        await apiDeleteTag(request, token, id)
      }
    }
  })
})
