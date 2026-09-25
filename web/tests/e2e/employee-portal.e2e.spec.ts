/**
 * Employee Portal E2E tests — REQ-346 port of BilimBaga's employee-portal.spec.ts
 *
 * PORT, NOT TRANSLITERATION. BilimBaga's original 8 tests drove a candidate
 * "portal" area and its own results sub-route — routes that do not exist in
 * Letflow (its own token-based sign-in screen was removed too — see
 * `web/tests/e2e/helpers.ts`'s own doc comment). Letflow's real
 * candidate-facing surface is `/exam` (ExamListPage, REQ-338), which this file
 * targets instead, bound to that page's actual `data-testid` hooks
 * (`exam-list-page`, `exam-list`, `exam-list-empty`,
 * `exam-list-provisional-notice`, `exam-list-item-<id>`,
 * `exam-list-start-<id>`) rather than BilimBaga's CSS-class/localized-text
 * selectors.
 *
 * Of the 8 source tests, only 3 have a real Letflow counterpart:
 *   - "01 — Portal loads" -> the list renders the REQ-345 seeded fixture exams.
 *   - "02 — Empty portal state" -> rewritten: with the fixture guaranteeing two
 *     active exams, the honest counterpart is proving the empty-state message
 *     does NOT render while real exams exist (ExamListPage has no route to a
 *     genuinely empty state without deleting the fixture other requirements
 *     depend on).
 *   - "05 — Start Exam modal confirm -> navigates to session" -> rewritten:
 *     ExamListPage's "Start" button (`exam-list-start-<id>`) has no modal at
 *     all (`web/src/pages/exam/ExamListPage.tsx` renders a single Button that
 *     calls `navigate()` directly on click) — this replaces the
 *     open-modal/confirm sequence with a direct click-and-navigate assertion.
 *
 * Tests 03 ("Start Exam modal opens"), 04 ("modal cancel"), 06 ("Continue CTA"),
 * 07 ("View Result CTA") and 08 ("My Results page") are deliberately NOT
 * ported — see this requirement's close-out for the specific missing
 * behaviour behind each one. None is stubbed as `test.skip`/`test.fixme`.
 *
 * NOTE ON TEST 05's SCOPE. This companion requirement's other source file,
 * exam-taking.spec.ts, could not be ported at all (see the close-out): every
 * one of its 11 tests needs `ExamSessionPage` to actually render a question,
 * and doing so crashes the app today (`<h3>{currentQuestion.stem}</h3>`
 * interpolates the raw `{en: "..."}` localized-text object the backend
 * really returns, which React refuses to render as a child). Test 05 below
 * therefore only proves navigation reaches the session route, exactly what
 * the source test itself literally checked — it does not additionally
 * require the destination to render successfully, since that is exactly the
 * code path this defect breaks.
 *
 * Authentication: `web/tests/e2e/helpers.ts`'s `getKeycloakToken`/
 * `loginWithToken` (real Keycloak password grant against `admin-user`, the
 * only realm user holding the `PLATFORM_ADMIN` catch-all role — the
 * dedicated `CANDIDATE` role has no Keycloak realm user provisioned today,
 * and `PLATFORM_ADMIN`'s `role_allows?/2` clause covers every `ExamSession*`
 * permission unconditionally, per `lib/letflow/api/authorization.ex`).
 */

import { test, expect, type APIRequestContext, type Page } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

// ---------------------------------------------------------------------------
// REQ-345 fixture lookup + cleanup helpers
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

/** Submits every still-open (in_progress) session against the given exam, via
 *  the same raw HTTP route ExamSessionPage's own "Submit exam" button calls
 *  (`POST /modules/exam/exam-sessions/:id/submit`) — never touching the exam-result UI
 *  itself (that is REQ-349's scope). This is cleanup, not a covered
 *  behaviour: `lib/letflow/exam/session.ex`'s `check_no_open_session/1`
 *  blocks a second `create/3` call for the same (candidate, exam) pair while
 *  one session is still `in_progress`, so leaving a session open here would
 *  fail every later re-run of this file's own "start" test. */
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
    await request.post(`/api/v1/modules/exam/exam-sessions/${item.record_id}/submit`, {
      headers: { Authorization: `Bearer ${token}` },
    })
  }
}

async function waitForListReady(page: Page): Promise<void> {
  await expect(page.getByTestId('exam-list-page')).toBeVisible({ timeout: 15_000 })
  // Either the list or the empty-state message must settle — never both, and
  // never neither (a bare loading/error state would fail both assertions
  // below, which is the point of waiting on this rather than a fixed sleep).
  await expect(page.getByTestId('exam-list')).toBeVisible({ timeout: 15_000 })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe('Employee Portal (REQ-346 port onto /exam)', () => {
  let token: string
  let mixedExamId: string
  let scoreableExamId: string

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    const exams = await queryActiveExams(request, token)
    mixedExamId = findExamByTitle(exams, 'REQ-345 E2E Mixed Exam')
    scoreableExamId = findExamByTitle(exams, 'REQ-345 E2E Scoreable Exam')
    // Defensive: a prior interrupted run may have left a session open.
    await submitOpenSessionsForExam(request, token, scoreableExamId)
  })

  test.afterAll(async ({ request }) => {
    // This file's own "start" test (below) opens a session on the scoreable
    // exam and never submits it through the UI (submission/result assertions
    // are REQ-349's scope) — close it out via the raw API so a later re-run
    // of this file does not hit check_no_open_session/1.
    await submitOpenSessionsForExam(request, token, scoreableExamId)
    await submitOpenSessionsForExam(request, token, mixedExamId)
  })

  test.beforeEach(async ({ page }) => {
    await loginWithToken(page, token)
  })

  test('01 — exam list renders the REQ-345 seeded published exams', async ({ page }) => {
    await page.goto('/exam', { waitUntil: 'domcontentloaded' })
    await waitForListReady(page)

    // Provisional-notice hook (ExamListPage's own honest disclosure that
    // exam_assignment does not exist yet — see the page's moduledoc) must be
    // present regardless of list contents.
    await expect(page.getByTestId('exam-list-provisional-notice')).toBeVisible()

    await expect(page.getByTestId(`exam-list-item-${mixedExamId}`)).toBeVisible({ timeout: 10_000 })
    await expect(page.getByTestId(`exam-list-item-${scoreableExamId}`)).toBeVisible()
    await expect(page.getByTestId(`exam-list-start-${mixedExamId}`)).toBeVisible()
  })

  test('02 — empty-state message does not render while active exams exist', async ({ page }) => {
    await page.goto('/exam', { waitUntil: 'domcontentloaded' })
    await waitForListReady(page)

    // Rewritten from the source's "either empty-state or cards, both
    // acceptable" tolerance: this fixture guarantees the list is non-empty,
    // so the honest assertion is that exam-list-empty is exactly the
    // complement of exam-list-item-* being present, proven in the direction
    // this suite can actually exercise.
    await expect(page.getByTestId('exam-list-empty')).toHaveCount(0)
    await expect(page.getByTestId(`exam-list-item-${mixedExamId}`)).toBeVisible()
    await expect(page.getByTestId(`exam-list-item-${scoreableExamId}`)).toBeVisible()
  })

  test('05 — Start action navigates directly to the exam session route', async ({ page }) => {
    await page.goto('/exam', { waitUntil: 'domcontentloaded' })
    await waitForListReady(page)

    // ExamListPage's Start button (exam-list-start-<id>) calls
    // navigate(`/exam/${id}/session`) synchronously on click — there is no
    // confirm modal to open first, unlike BilimBaga's source flow. This is
    // deliberately a URL-only assertion, matching the source test's own
    // literal check ("navigates to the session-taking route") rather than
    // also requiring ExamSessionPage to finish rendering: a real, separate
    // defect independently confirmed while building the companion
    // exam-taking port (`ExamSessionPage.tsx`'s `<h3>{currentQuestion.stem}</h3>`
    // interpolates the raw `{en: "..."}` localized-text object the backend
    // actually returns, which React refuses to render as a child and which
    // crashes into the app's generic ErrorBoundary — see this requirement's
    // close-out) means the destination route does not reliably reach either
    // `exam-session-page` or `exam-start-error` today. That defect is a
    // pre-existing ExamSessionPage/types/exam.ts bug (REQ-338), not
    // something this port authorizes fixing.
    await page.getByTestId(`exam-list-start-${scoreableExamId}`).click()
    await expect(page).toHaveURL(new RegExp(`/exam/${scoreableExamId}/session$`), { timeout: 10_000 })
  })
})
