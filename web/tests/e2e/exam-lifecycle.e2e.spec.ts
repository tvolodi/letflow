/**
 * Exam Lifecycle admin E2E tests — REQ-347 port of BilimBaga's
 * exam-lifecycle.spec.ts.
 *
 * PORT, NOT TRANSLITERATION: BilimBaga's eight tests target its own bespoke
 * `/admin/exams` list plus a dedicated multi-step `/admin/exams/:id/edit`
 * wizard. Letflow's real counterpart for the list half is the generic
 * `/admin/bilimbaga/exam` screen (`EntityCrudPage`, REQ-343); there is no
 * wizard counterpart anywhere in the generic entity-CRUD engine.
 *
 * "STATUS BADGE" RE-VERIFICATION (deviates from REQ-344's own wording,
 * re-derived live rather than copied). REQ-344's triage (§4.9) files the
 * three status-text tests as PORTABLE-AFTER-REQ-347 citing a "no
 * badge-rendering gap" (`EntityCrudPage` renders every enum field,
 * `status` included, as a plain table cell via `String(value)` — see
 * `EntityCrudPage.tsx`'s `formatCellValue`, confirmed by reading the file
 * in full). That citation is correct: there is no colored/pill-styled
 * badge. But re-reading the SOURCE tests' own assertion bodies (not just
 * their titles) shows none of them actually asserts badge styling either —
 * each one greps a table row for the literal, un-styled substring
 * "active"/"draft"/"archived" (case-insensitive, with a Cyrillic
 * alternative BilimBaga needed and Letflow's plain enum string never
 * carries). Since `formatCellValue` renders `status`'s raw enum value
 * (`"active"`, `"draft"`, `"archived"`) as an unstyled cell, that literal
 * substring genuinely appears in the row — confirmed live below, not
 * assumed. The three tests are therefore ported as literal-text checks,
 * with "badge" language dropped from their titles and this note left in
 * place of REQ-344's gap citation so a later reader does not assume a
 * badge-styling feature was added here (none was; this requirement builds
 * no such thing).
 *
 * FIXTURE EXAMS. `REQ-345 E2E Mixed Exam` / `REQ-345 E2E Scoreable Exam`
 * (`mix letflow.seed.exam_fixtures`) supply the seeded "active" row.
 * Draft/archived rows are created directly through
 * `POST /api/v1/entities/records/exam` with `status: "draft"` /
 * `"archived"` in the same beforeEach/afterEach pattern the source file's
 * `createTestExam`/`deleteTestExam` used against BilimBaga's bespoke
 * `/api/v1/exams` — Letflow has no separate "archive" action endpoint
 * (`status` is a plain field on the generic entity, not a workflow state
 * machine), so archiving is just creating the record with that field
 * value already set, not a two-step create-then-archive call.
 *
 * PORTED (6 of 8, rewritten against `entity-crud-page` /
 * `entity-edit-<record_id>` and the live text-cell behaviour above):
 *   - "exams list renders without error and shows status badges" ->
 *     rewritten as "... without error" (title's "badges" clause dropped —
 *     see the note above); its own assertion body only ever checked
 *     no-crash-text + row-count, matching the rewrite exactly.
 *   - "seeded active exam shows 'active' badge" -> row-scoped literal-text
 *     check.
 *   - "draft exam shows 'draft' badge" -> row-scoped literal-text check,
 *     draft exam created/deleted via the API helper above.
 *   - "archived exam shows 'archived' status" -> row-scoped literal-text
 *     check, archived exam created directly with `status: "archived"`
 *     (no separate archive-endpoint call — see note above) and deleted via
 *     the API helper.
 *   - "all exam rows have an Edit action link" -> rewritten onto
 *     `[data-testid^="entity-edit-"]` (real per-row edit action), replacing
 *     the source's `getByRole('link').filter({ has: svg })` heuristic
 *     (`EntityCrudPage`'s edit action is a `<button>`, not an `<a>`, so no
 *     ARIA `link` role exists to query in the first place).
 *   - "exams list shows multiple statuses when multiple exams exist" ->
 *     row-scoped literal-text checks for both "active" and "draft",
 *     draft exam created/deleted via the API helper.
 *
 * DROPPED (2 of 8, NO-COUNTERPART — matches REQ-344 §4.9 exactly):
 *   - "editing the seeded mixed exam loads Step 1 with pre-populated
 *     title" — asserts a dedicated multi-step wizard page
 *     (`/admin/exams/:id/edit`, "Step 1", "Basic Settings"). No wizard of
 *     any kind exists in the generic entity-CRUD engine, and none is
 *     planned under S10 for it (`EntityCrudPage`'s edit action opens the
 *     same single-step `entity-form-modal` as create).
 *   - "exams list page navigates to edit wizard on clicking edit" — same
 *     wizard-only missing behaviour; `entity-edit-<id>` opens
 *     `entity-form-modal` in place, it does not navigate to any URL.
 *
 * GETBYROLE COUNT: 0 uses — every ported test selects via
 * `entity-crud-page` / `data-table` testids, a `[data-testid^="entity-edit-"]`
 * attribute-prefix locator, or plain text-content assertions scoped to a
 * `data-table` row (`getByRole('row')` was deliberately NOT used — the row
 * is located by its own `data-testid="datatable-row"`, and text is scoped
 * within it via `.filter({ hasText })`, not by ARIA row role).
 *
 * Authentication: `web/tests/e2e/helpers.ts`'s `getKeycloakToken`/
 * `loginWithToken`.
 */

import { test, expect, type APIRequestContext, type Page } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

const EXAM_ROUTE = '/admin/bilimbaga/exam'
const MIXED_EXAM_TITLE = 'REQ-345 E2E Mixed Exam'

interface ExamRecord {
  record_id: string
  field_values: { title?: { en?: string }; status?: string }
}

function baseExamFieldValues(titleEn: string, status: string): Record<string, unknown> {
  return {
    title: { en: titleEn },
    status,
    time_limit_minutes: 30,
    passing_score_pct: 60,
    max_attempts: 3,
    shuffle_questions: false,
    shuffle_options: false,
    show_answers: 'never',
    on_tab_switch: 'log',
    certificate_enabled: false,
  }
}

async function createExam(request: APIRequestContext, token: string, titleEn: string, status: string): Promise<string> {
  const res = await request.post('/api/v1/entities/records/exam', {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: { field_values: baseExamFieldValues(titleEn, status) },
  })
  if (!res.ok()) {
    throw new Error(`POST /api/v1/entities/records/exam failed: ${res.status()} ${await res.text()}`)
  }
  const body = (await res.json()) as { record_id: string }
  return body.record_id
}

async function deleteExam(request: APIRequestContext, token: string, recordId: string): Promise<void> {
  await request.delete(`/api/v1/entities/records/exam/${recordId}`, {
    headers: { Authorization: `Bearer ${token}` },
  })
}

async function queryExams(request: APIRequestContext, token: string): Promise<ExamRecord[]> {
  const res = await request.post('/api/v1/entities/query', {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: { entity_type: 'exam', page_size: 100 },
  })
  if (!res.ok()) {
    throw new Error(`POST /api/v1/entities/query (exam) failed: ${res.status()} ${await res.text()}`)
  }
  const body = (await res.json()) as { items: ExamRecord[] }
  return body.items.filter((item) => !(item as unknown as { deleted?: boolean }).deleted)
}

function findExamByTitle(exams: ExamRecord[], titleEn: string): string {
  const match = exams.find((e) => e.field_values.title?.en === titleEn)
  if (!match) {
    throw new Error(
      `Fixture exam "${titleEn}" not found among exams. Run \`mix letflow.seed.exam_fixtures\` against the dev DB first.`,
    )
  }
  return match.record_id
}

async function gotoExams(page: Page): Promise<void> {
  await page.goto(EXAM_ROUTE, { waitUntil: 'domcontentloaded' })
  await expect(page.getByTestId('entity-crud-page')).toBeVisible({ timeout: 15_000 })
  await expect(page.getByTestId('entity-crud-page')).toHaveAttribute('data-entity-type', 'exam')
}

/** Row containing the given exam title, scoped within the real DataTable
 *  body (`datatable-row`, not an ARIA row role — see this file's header
 *  comment). */
function examRow(page: Page, titleEn: string) {
  return page.getByTestId('datatable-row').filter({ hasText: titleEn })
}

test.describe('Exam Lifecycle admin (REQ-347 port onto /admin/bilimbaga/exam)', () => {
  let token: string

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    // Confirms the REQ-345 fixture exam exists before any test relies on it
    // — fails fast with a clear message rather than every dependent test
    // failing on a missing row.
    const exams = await queryExams(request, token)
    findExamByTitle(exams, MIXED_EXAM_TITLE)
  })

  test.beforeEach(async ({ page }) => {
    await loginWithToken(page, token)
  })

  test('exams list renders without error', async ({ page }) => {
    await gotoExams(page)
    await expect(page.locator('body')).not.toContainText(/unexpected error|something went wrong/i)
    const hasTable = await page.getByTestId('data-table').isVisible().catch(() => false)
    if (hasTable) {
      const count = await page.getByTestId('datatable-row').count()
      expect(count).toBeGreaterThan(0)
    }
  })

  test('seeded active exam shows the "active" status text', async ({ page }) => {
    await gotoExams(page)
    await expect(examRow(page, MIXED_EXAM_TITLE)).toBeVisible({ timeout: 10_000 })
    await expect(examRow(page, MIXED_EXAM_TITLE).getByTestId('datatable-cell-status')).toHaveText(/active/i)
  })

  test('draft exam shows the "draft" status text', async ({ request, page }) => {
    const title = `REQ-347 E2E Draft ${Date.now()}`
    const examId = await createExam(request, token, title, 'draft')
    try {
      await gotoExams(page)
      await expect(examRow(page, title)).toBeVisible({ timeout: 10_000 })
      await expect(examRow(page, title).getByTestId('datatable-cell-status')).toHaveText(/draft/i)
    } finally {
      await deleteExam(request, token, examId)
    }
  })

  test('archived exam shows the "archived" status text', async ({ request, page }) => {
    const title = `REQ-347 E2E Archived ${Date.now()}`
    const examId = await createExam(request, token, title, 'archived')
    try {
      await gotoExams(page)
      await expect(examRow(page, title)).toBeVisible({ timeout: 10_000 })
      await expect(examRow(page, title).getByTestId('datatable-cell-status')).toHaveText(/archived/i)
    } finally {
      await deleteExam(request, token, examId)
    }
  })

  test('all exam rows have an Edit action', async ({ page }) => {
    await gotoExams(page)
    const hasTable = await page.getByTestId('data-table').isVisible({ timeout: 10_000 }).catch(() => false)
    expect(hasTable).toBeTruthy()
    const editActions = page.locator('[data-testid^="entity-edit-"]')
    const count = await editActions.count()
    expect(count).toBeGreaterThan(0)
  })

  test('exams list shows multiple statuses when multiple exams exist', async ({ request, page }) => {
    const title = `REQ-347 E2E Draft Multi ${Date.now()}`
    const examId = await createExam(request, token, title, 'draft')
    try {
      await gotoExams(page)
      await expect(page.locator('body')).not.toContainText(/unexpected error/i)
      await expect(examRow(page, MIXED_EXAM_TITLE).getByTestId('datatable-cell-status')).toHaveText(/active/i)
      await expect(examRow(page, title).getByTestId('datatable-cell-status')).toHaveText(/draft/i)
    } finally {
      await deleteExam(request, token, examId)
    }
  })
})
