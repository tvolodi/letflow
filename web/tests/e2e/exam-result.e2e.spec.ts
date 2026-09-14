/**
 * Exam Result E2E tests — REQ-349 port of BilimBaga's exam-result.spec.ts
 * (5 blocks) and my-results.spec.ts (6 blocks) -- 11 source blocks total.
 *
 * THE BINDING CONSTRAINT (REQ-349's own text, restated here because it
 * dictates this file's whole shape): the three result testids --
 * `exam-result-page`, `exam-result-pending`, `exam-result-score`, all in
 * `web/src/pages/exam/ExamSessionPage.tsx`'s one `phase.kind === 'result'`
 * render guard (:291-311) -- are reachable ONLY by driving the live
 * start -> answer -> submit flow in one browser session. `phase` becomes
 * `'result'` at exactly two call sites (:226 anti-cheat forced submit, :253
 * `handleSubmit`), both inside the live flow; the mount effect (:112-127)
 * calls `examApi.startSession` UNCONDITIONALLY, so navigating a browser to
 * an existing session's URL starts a NEW session rather than opening it.
 * There is no result-by-id route and no results-list route in
 * `web/src/router.tsx`. Every test below therefore starts one of REQ-345's
 * two seeded exams, answers it, submits it, and asserts on the result phase
 * that follows -- never on a pre-existing seeded session.
 *
 * lib/letflow/routers/exam_sessions.ex's own moduledoc states the backend
 * scope fence verbatim, under "Deliberately NOT routed here, and why
 * (REQ-335's own scope fence)":
 *
 *   "**Cross-session history / results-list views**
 *   (`GetExamHistory`/`HandleGetMyResults`, FR-BB41/FR-BB46) -- outside
 *   REQ-330's five analysed behaviours (start, autosave, submit, anti-cheat
 *   signal, and this route's own state read); `GetSessionResult` is also
 *   not routed here for the same reason -- a *result* view is a sixth
 *   behaviour this requirement's own dependency chain (REQ-330's five)
 *   never authorized, not a subset of the *state* read this module does
 *   implement."
 *
 * CLASSIFICATION OF ALL 11 SOURCE BLOCKS
 * ---------------------------------------------------------------------
 * exam-result.spec.ts (5 blocks):
 *
 *   01 "Passed result screen renders" -- PORTED, as this file's
 *      'Exam Result — passed (scoreable exam)' describe block. Drives
 *      "REQ-345 E2E Scoreable Exam" with the documented PASSING combination
 *      (R1 correct, R2 correct, R3 both correct options), submits, and
 *      asserts `exam-result-page` + `exam-result-score` + the "Passed"
 *      message + a working "Back to exam list" navigation (source test 01's
 *      own "Back to my exams" assertion, folded in here rather than
 *      duplicated as its own describe block -- see block 05 below).
 *
 *   02 "Failed result screen renders" -- PORTED, as
 *      'Exam Result — failed (scoreable exam)'. Drives the same exam with
 *      the documented FAILING combination (R1 incorrect, R2 incorrect, R3
 *      left unanswered), submits, and asserts `exam-result-score` + the
 *      "Not passed" message.
 *
 *   03 "Pending grading state (submitted session)" -- PORTED, as
 *      'Exam Result — pending (mixed exam)'. The BilimBaga source looked up
 *      a pre-existing submitted session via
 *      `GET /api/v1/portal/sessions?status=submitted` and navigated to
 *      `/portal/sessions/:id/result` -- both unavailable here (no
 *      results-list endpoint, no result-by-id route). The honest
 *      counterpart drives "REQ-345 E2E Mixed Exam" live: because that exam
 *      always carries a `short_text` question,
 *      `lib/letflow/exam/scoring.ex`'s `build_outcome/3` (:255/:257) forces
 *      every one of its sessions to `status: :grading_pending` regardless
 *      of answers, so submitting it deterministically reaches
 *      `exam-result-pending` (never `exam-result-score`).
 *
 *   04 "Result detail page (/portal/sessions/:id/result)" -- DROPPED.
 *      This is exactly the "result-by-id view" the scope-fence text above
 *      names: `GetSessionResult` is "not routed here for the same reason"
 *      as the results-list views, and no route in `web/src/router.tsx`
 *      opens a session by id. `GET /exam-sessions/:id` does return a
 *      submitted session's own state at the HTTP level, but no screen
 *      renders it, and this requirement's own text is explicit that
 *      driving to a *fresh* result via the live flow (blocks 01/02/03
 *      above) is not a substitute for this block's actual assertion, which
 *      was specifically about opening an EXISTING session by id after the
 *      fact. No ported spec attempts this.
 *
 *   05 "Back to Portal navigation from result screen" -- PORTED, folded
 *      into the 'Exam Result — passed (scoreable exam)' describe block's
 *      final test rather than given its own describe block and its own
 *      live session (every distinct describe block below drives one full
 *      session lifecycle, and this assertion needs nothing that block
 *      doesn't already have on screen after asserting the score).
 *
 * my-results.spec.ts (6 blocks) -- ALL DROPPED. Every one of them targets
 * `/portal` or `/portal/results`, BilimBaga's cross-session results-LIST
 * view (FR-BB46, named explicitly in this file's own `describe` title).
 * `web/src/router.tsx` serves no `/portal` route at all (Letflow's real
 * candidate-facing list is `/exam`, REQ-338's `ExamListPage`), and a
 * results-list across sessions is precisely what the scope-fence text
 * above excludes as "Cross-session history / results-list views
 * (`GetExamHistory`/`HandleGetMyResults`, FR-BB41/FR-BB46)". This is not a
 * single missing route to swap in -- it is a surface Letflow does not
 * serve, at any URL, today:
 *
 *   "shows My Results tab and navigates to /portal/results" -- DROPPED,
 *     no `/portal` route, no results-list route.
 *   "results page renders without error" -- DROPPED, no `/portal/results`
 *     route.
 *   "shows exam results when sessions exist" -- DROPPED, cross-session
 *     results-list view, scope-fenced out.
 *   "shows score percentage for completed sessions" -- DROPPED, same
 *     results-list view.
 *   "shows Passed or Failed badge for graded sessions" -- DROPPED, same
 *     results-list view.
 *   "My Exams tab navigates back to /portal" -- DROPPED, no `/portal`
 *     route exists to navigate back to.
 *
 * TOTAL: 4 ported (01, 02, 03, 05 -- 05 folded into 01's describe block, not
 * a separate file entry), 7 dropped (04, and all 6 of my-results.spec.ts).
 * 4 + 7 = 11, the re-measured source-block total.
 *
 * OPEN QUESTION FOR ORCH, NOT RESOLVED HERE. Whether Letflow should serve a
 * candidate result/results-list surface at all is unresolved -- REQ-335
 * fenced it out deliberately and no decision record in
 * `docs/migration/decisions/` settles it. This port does not build one; it
 * documents the gap above and leaves the decision to ORCH.
 *
 * FIXTURE DEPENDENCY (REQ-345), EXAM CONTENT ONLY. This file needs BOTH of
 * REQ-345's seeded exams present and published in the bpm-default tenant
 * (`LETFLOW_DEV_DB_CONFIRMED=1 mix letflow.seed.exam_fixtures`):
 *
 *   "REQ-345 E2E Mixed Exam" -- 5 questions, one per type, including a
 *     `short_text` question ("REQ-345 Mixed Q5 (shorttext)") that forces
 *     `grading_pending` regardless of answers.
 *   "REQ-345 E2E Scoreable Exam" -- passing_score_pct 60.0, 3 questions,
 *     none `short_text`: "REQ-345 Scoreable R1 (single)" (option A
 *     correct), "REQ-345 Scoreable R2 (truefalse)" (option "True" correct),
 *     "REQ-345 Scoreable R3 (multiple)" (options A+B correct out of A/B/C).
 *
 * This file does NOT consume REQ-345's own pre-submitted session (against
 * the mixed exam) -- no screen can open it, so no ported spec asserts on
 * it. Each describe block below opens and finishes its OWN fresh session.
 *
 * SESSION-PER-EXAM CONSTRAINT, same reasoning as
 * `exam-taking.e2e.spec.ts`'s own doc comment:
 * `lib/letflow/exam/session.ex`'s `check_no_open_session/1` rejects a
 * second `POST /exam-sessions` for the same (candidate, exam) pair while
 * one is still `in_progress`. The scoreable exam needs two full live
 * sessions in this file (one passing, one failing); each describe block
 * below closes its own session in `afterAll` (defensively, in case a test
 * fails mid-flow) before the next describe block that targets the same
 * exam runs, and `test.describe.serial`+workers:1 in `playwright.config.ts`
 * keeps this file's describe blocks from overlapping.
 *
 * SELECTOR NOTE. All result-phase assertions use `getByTestId` against the
 * real `exam-*` hooks. `getByRole('button', { name: ... })` is used only
 * for "Back to exam list" (no testid exists on that button) and for the
 * option inputs' Previous/Next-free direct clicks, which use
 * `getByTestId(/^exam-option-/)` locators (a testid DOES exist for
 * options), consistent with `exam-taking.e2e.spec.ts`.
 *
 * Authentication: `web/tests/e2e/helpers.ts`'s `getKeycloakToken`/
 * `loginWithToken` (admin-user / PLATFORM_ADMIN, same as the sibling
 * REQ-346 e2e files -- covers every ExamSession* permission).
 */

import { test, expect, type APIRequestContext, type Page, type BrowserContext } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

// ---------------------------------------------------------------------------
// REQ-345 fixture lookup + cleanup helpers (same shapes as
// employee-portal.e2e.spec.ts / exam-taking.e2e.spec.ts)
// ---------------------------------------------------------------------------

interface ExamRecord {
  record_id: string
  field_values: { title?: { en?: string }; status?: string }
}

async function queryActiveExams(request: APIRequestContext, token: string): Promise<ExamRecord[]> {
  const res = await request.post('/api/v1/entities/query', {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: {
      entity_type: 'exam',
      filters: [{ field: 'status', op: 'eq', value: 'active' }],
      page_size: 100,
    },
  })
  if (!res.ok()) {
    throw new Error(`POST /api/v1/entities/query (exam) failed: ${res.status()} ${await res.text()}`)
  }
  const body = (await res.json()) as { items: ExamRecord[] }
  return body.items
}

function findExamByTitle(exams: ExamRecord[], titleEn: string): string {
  const match = exams.find((e) => e.field_values.title?.en === titleEn)
  if (!match) {
    throw new Error(
      `REQ-345 fixture exam "${titleEn}" not found among active exams. ` +
        'Run `mix letflow.seed.exam_fixtures` against the dev DB first.',
    )
  }
  return match.record_id
}

/** Submits every still-open (in_progress) session against the given exam --
 *  cleanup only, avoiding check_no_open_session/1 blocking a later run. */
async function submitOpenSessionsForExam(request: APIRequestContext, token: string, examId: string): Promise<void> {
  const res = await request.post('/api/v1/entities/query', {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: {
      entity_type: 'session',
      filters: [
        { field: 'exam_id', op: 'eq', value: examId },
        { field: 'status', op: 'eq', value: 'in_progress' },
      ],
      page_size: 100,
    },
  })
  if (!res.ok()) return
  const body = (await res.json()) as { items: Array<{ record_id: string }> }
  for (const item of body.items) {
    await request.post(`/api/v1/exam-sessions/${item.record_id}/submit`, {
      headers: { Authorization: `Bearer ${token}` },
    })
  }
}

// ---------------------------------------------------------------------------
// Page-level helper, against ExamSessionPage.tsx's real testids
// ---------------------------------------------------------------------------

/** Rewinds to question 1 via "Previous", then advances via "Next" until the
 *  visible question's stem contains `stemSubstring` -- identifying a
 *  question by its real, distinct seeded stem text rather than by position,
 *  since both fixture exams' `exam_question_rule` uses `mode: "random"`. */
async function goToQuestionByStem(page: Page, stemSubstring: string, maxQuestions: number): Promise<void> {
  const prevButton = page.getByRole('button', { name: 'Previous' })
  for (let i = 0; i < maxQuestions; i++) {
    if (await prevButton.isDisabled()) break
    await prevButton.click()
  }

  const heading = page.locator('[data-testid^="exam-question-"] h3')
  const nextButton = page.getByRole('button', { name: 'Next' })
  for (let i = 0; i < maxQuestions; i++) {
    const text = await heading.textContent()
    if (text?.includes(stemSubstring)) return
    if (await nextButton.isDisabled()) break
    await nextButton.click()
  }
  throw new Error(`goToQuestionByStem: no question containing "${stemSubstring}" found within ${maxQuestions} questions`)
}

// ---------------------------------------------------------------------------
// 'Exam Result — pending (mixed exam)' -- ports block 03
// ---------------------------------------------------------------------------

test.describe.serial('Exam Result — pending (mixed exam, REQ-349 port of exam-result.spec.ts block 03)', () => {
  let context: BrowserContext
  let page: Page
  let token: string
  let mixedExamId: string

  test.beforeAll(async ({ browser, request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    const exams = await queryActiveExams(request, token)
    mixedExamId = findExamByTitle(exams, 'REQ-345 E2E Mixed Exam')
    await submitOpenSessionsForExam(request, token, mixedExamId)

    context = await browser.newContext()
    page = await context.newPage()
    await loginWithToken(page, token)

    await page.goto(`/exam/${mixedExamId}/session`, { waitUntil: 'domcontentloaded' })
    await expect(page.getByTestId('exam-session-page')).toBeVisible({ timeout: 15_000 })
  })

  test.afterAll(async ({ request }) => {
    await submitOpenSessionsForExam(request, token, mixedExamId)
    await context?.close()
  })

  test('submitting the mixed exam (a short_text question forces grading) reaches exam-result-pending, never exam-result-score', async () => {
    // No answers are required to reach the assertion this test cares about
    // (an unanswered short_text question still forces grading_pending, per
    // scoring.ex's own rule) -- submit directly, same as REQ-345's own
    // seeded-session behaviour.
    await page.getByTestId('exam-submit-action').click()

    await expect(page.getByTestId('exam-result-page')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('exam-result-pending')).toBeVisible()
    await expect(page.getByTestId('exam-result-score')).toHaveCount(0)
    await expect(page.getByText('Grading in progress')).toBeVisible()
  })
})

// ---------------------------------------------------------------------------
// 'Exam Result — passed (scoreable exam)' -- ports blocks 01 and 05
// ---------------------------------------------------------------------------

test.describe.serial('Exam Result — passed (scoreable exam, REQ-349 port of exam-result.spec.ts blocks 01 + 05)', () => {
  let context: BrowserContext
  let page: Page
  let token: string
  let scoreableExamId: string

  test.beforeAll(async ({ browser, request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    const exams = await queryActiveExams(request, token)
    scoreableExamId = findExamByTitle(exams, 'REQ-345 E2E Scoreable Exam')
    await submitOpenSessionsForExam(request, token, scoreableExamId)

    context = await browser.newContext()
    page = await context.newPage()
    await loginWithToken(page, token)

    await page.goto(`/exam/${scoreableExamId}/session`, { waitUntil: 'domcontentloaded' })
    await expect(page.getByTestId('exam-session-page')).toBeVisible({ timeout: 15_000 })
  })

  test.afterAll(async ({ request }) => {
    await submitOpenSessionsForExam(request, token, scoreableExamId)
    await context?.close()
  })

  test('01 — answering every question correctly and submitting reaches exam-result-score with the Passed message', async () => {
    await goToQuestionByStem(page, '(single)', 3)
    // R1: option A (sort_order 0) is the documented correct option.
    await page.locator('[data-testid^="exam-option-"]').first().click()
    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })

    await goToQuestionByStem(page, '(truefalse)', 3)
    // R2: option "True" (sort_order 0) is the documented correct option.
    await page.locator('[data-testid^="exam-option-"]').first().click()
    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })

    await goToQuestionByStem(page, '(multiple)', 3)
    // R3: options A and B (sort_order 0 and 1) are the documented correct
    // pair out of A/B/C.
    const r3options = page.locator('[data-testid^="exam-option-"]')
    await r3options.nth(0).click()
    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })
    await r3options.nth(1).click()
    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })

    await page.getByTestId('exam-submit-action').click()

    await expect(page.getByTestId('exam-result-page')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('exam-result-score')).toBeVisible()
    await expect(page.getByTestId('exam-result-pending')).toHaveCount(0)
    await expect(page.getByText('Passed', { exact: true })).toBeVisible()
  })

  test('05 — "Back to exam list" navigates from the result screen back to /exam', async () => {
    const backButton = page.getByRole('button', { name: 'Back to exam list' })
    await expect(backButton).toBeVisible({ timeout: 10_000 })
    await backButton.click()

    await expect(page).toHaveURL(/\/exam$/, { timeout: 10_000 })
    await expect(page.getByTestId('exam-list-page')).toBeVisible({ timeout: 10_000 })
  })
})

// ---------------------------------------------------------------------------
// 'Exam Result — failed (scoreable exam)' -- ports block 02
// ---------------------------------------------------------------------------

test.describe.serial('Exam Result — failed (scoreable exam, REQ-349 port of exam-result.spec.ts block 02)', () => {
  let context: BrowserContext
  let page: Page
  let token: string
  let scoreableExamId: string

  test.beforeAll(async ({ browser, request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    const exams = await queryActiveExams(request, token)
    scoreableExamId = findExamByTitle(exams, 'REQ-345 E2E Scoreable Exam')
    await submitOpenSessionsForExam(request, token, scoreableExamId)

    context = await browser.newContext()
    page = await context.newPage()
    await loginWithToken(page, token)

    await page.goto(`/exam/${scoreableExamId}/session`, { waitUntil: 'domcontentloaded' })
    await expect(page.getByTestId('exam-session-page')).toBeVisible({ timeout: 15_000 })
  })

  test.afterAll(async ({ request }) => {
    await submitOpenSessionsForExam(request, token, scoreableExamId)
    await context?.close()
  })

  test('02 — answering incorrectly (and leaving one question unanswered) and submitting reaches exam-result-score with the Not passed message', async () => {
    await goToQuestionByStem(page, '(single)', 3)
    // R1: option B (sort_order 1) is documented incorrect.
    await page.locator('[data-testid^="exam-option-"]').nth(1).click()
    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })

    await goToQuestionByStem(page, '(truefalse)', 3)
    // R2: option "False" (sort_order 1) is documented incorrect.
    await page.locator('[data-testid^="exam-option-"]').nth(1).click()
    await expect(page.getByTestId('exam-save-status')).toHaveText('Saved', { timeout: 8_000 })

    // R3 (multiple) is deliberately left unanswered -- scoring.ex treats an
    // unanswered question as wrong, not skipped, which is exactly the
    // documented FAILING combination (0.0/3.0, 0% < the 60% threshold).

    await page.getByTestId('exam-submit-action').click()

    await expect(page.getByTestId('exam-result-page')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('exam-result-score')).toBeVisible()
    await expect(page.getByTestId('exam-result-pending')).toHaveCount(0)
    await expect(page.getByText('Not passed', { exact: true })).toBeVisible()
  })
})
