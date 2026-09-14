/**
 * Exam Result BY ID E2E tests — REQ-351
 *
 * Covers `ExamSessionResultPage.tsx` (`web/src/router.tsx`'s
 * `exam/sessions/:sessionId/result` route, PROVISIONAL -- see that file's own
 * doc comment and REQ-351's close-out): opens an EXISTING session by id via
 * `examApi.getSessionState` and renders its result phase WITHOUT ever calling
 * `examApi.startSession`.
 *
 * TWO OF THE THREE REQUIRED SCENARIOS ARE HERE. REQ-351's own acceptance
 * criteria ask for three live scenarios: (1) a shorttext-free ("scoreable")
 * exam rendering `exam-result-score` from a LOADED session, (2) the MIXED
 * exam rendering `exam-result-pending` (never `exam-result-score`) from a
 * LOADED session, (3) a not-owner request not receiving another candidate's
 * session content. Scenario (2) and (3) are implemented below and PASS for
 * real, verified live. Scenario (1) is NOT implemented here -- see
 * `ExamSessionResultPage.tsx`'s own top-of-file doc comment and REQ-351's
 * close-out for why: `GET /exam-sessions/:id` (`session_state_json`,
 * `session_view` -- lib/letflow/exam/session.ex:1151-1160) never returns
 * `total_score`/`total_max_score`/`percentage`/`passed`; those fields exist
 * ONLY in `ExamSubmissionOutcome`, produced by `POST /exam-sessions/:id/
 * submit`'s response or by `outcome_from_session/1`
 * (lib/letflow/exam/session.ex:1087-1098), which is private and reachable
 * only from `submit_session`'s own idempotent re-submit path -- never from
 * the GET route. Constructing `exam-result-score` from the by-id route today
 * would mean fabricating score data client-side, which this project's own
 * FRONTEND-DEV scope forbids ("never a shim that normalises a backend
 * contract mismatch"). This is a genuine, code-verified backend gap, not a
 * client omission -- flagged in REQ-351's close-out as a follow-up for
 * ELIXIR-DEV, not worked around here.
 *
 * FIXTURE DEPENDENCY (REQ-345), same as exam-result.e2e.spec.ts /
 * exam-taking.e2e.spec.ts: `LETFLOW_DEV_DB_CONFIRMED=1 mix
 * letflow.seed.exam_fixtures` against the dev DB, seeding "REQ-345 E2E Mixed
 * Exam" (used below) and its own pre-submitted session owned by a fixed
 * fixture candidate (`req345-e2e-candidate`), used by the not-owner scenario.
 *
 * NOT-OWNER SCENARIO, HOW IT AVOIDS NEEDING A SECOND CANDIDATE LOGIN. This
 * realm's static fixtures (`priv/keycloak/realms/bpm-default.json`) define
 * NO user holding the `CANDIDATE` role and only ONE `PLATFORM_ADMIN` account
 * (`admin-user`) -- `Letflow.Api.Authorization.role_allows?/2`'s own source
 * shows only `:PLATFORM_ADMIN` and `:CANDIDATE` ever grant
 * `ExamSessionRead`, so there is no second real login available in this
 * environment that could start its own exam session to prove ownership
 * isolation the way `rnd-ui-06.conflict-resolver.e2e.spec.ts` does with
 * `worker-user`/`worker-user-2` (itself an optional fixture that spec
 * defensively skips without). Rather than skip this scenario, it uses
 * `mix letflow.seed.exam_fixtures`'s OWN pre-submitted mixed-exam session --
 * owned by a fixed fixture candidate id that is provably NOT admin-user's own
 * mapped candidate id (discovered live below via a real, immediately-cleaned-up
 * probe session) -- to exercise the exact same
 * `get_session_state_for_user/3` `{:error, :not_owner}` branch a second real
 * candidate login would, without fabricating a login that does not exist in
 * this environment.
 *
 * Authentication: `web/tests/e2e/helpers.ts`'s `getKeycloakToken`/
 * `loginWithToken` (admin-user / PLATFORM_ADMIN, same as every other exam e2e
 * file in this suite).
 */

import { test, expect, type APIRequestContext, type Page, type BrowserContext } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

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
 *  cleanup only, same shape as exam-result.e2e.spec.ts's own helper. */
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

interface SessionRecord {
  record_id: string
  field_values: { user_id?: string; status?: string }
}

async function querySessionsForExam(request: APIRequestContext, token: string, examId: string): Promise<SessionRecord[]> {
  const res = await request.post('/api/v1/entities/query', {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: { entity_type: 'session', filters: [{ field: 'exam_id', op: 'eq', value: examId }], page_size: 200 },
  })
  if (!res.ok()) {
    throw new Error(`POST /api/v1/entities/query (session) failed: ${res.status()} ${await res.text()}`)
  }
  const body = (await res.json()) as { items: SessionRecord[] }
  return body.items
}

/** Starts and immediately submits a throwaway session on `examId` purely to
 *  learn the caller's own mapped `candidate_id` (`session.candidate_id` in
 *  the start response -- `Letflow.Exam.Session.session_view/1`'s own field,
 *  NOT the raw Keycloak JWT `sub`, which this app does not use directly as
 *  the session-ownership key). Cleans up after itself immediately. */
async function discoverOwnCandidateId(request: APIRequestContext, token: string, examId: string): Promise<string> {
  await submitOpenSessionsForExam(request, token, examId)
  const startRes = await request.post('/api/v1/exam-sessions', {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: { exam_id: examId },
  })
  if (!startRes.ok()) {
    throw new Error(`probe startSession failed: ${startRes.status()} ${await startRes.text()}`)
  }
  const body = (await startRes.json()) as { session: { id: string; candidate_id: string } }
  await request.post(`/api/v1/exam-sessions/${body.session.id}/submit`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  return body.session.candidate_id
}

// ---------------------------------------------------------------------------
// 'Exam Result by id — pending (mixed exam)'
// ---------------------------------------------------------------------------

test.describe.serial('Exam Result by id — pending (mixed exam, REQ-351)', () => {
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
  })

  test.afterAll(async ({ request }) => {
    await submitOpenSessionsForExam(request, token, mixedExamId)
    await context?.close()
  })

  test('starting, submitting, then navigating to the by-id route in the SAME browser session renders exam-result-pending from the LOADED session, never exam-result-score', async () => {
    const startResponse = page.waitForResponse(
      (res) => res.url().includes('/api/v1/exam-sessions') && !res.url().includes('/answers/') && res.request().method() === 'POST',
    )
    await page.goto(`/exam/${mixedExamId}/session`, { waitUntil: 'domcontentloaded' })
    await expect(page.getByTestId('exam-session-page')).toBeVisible({ timeout: 15_000 })

    const startBody = (await (await startResponse).json()) as { session: { id: string } }
    const sessionId = startBody.session.id
    expect(sessionId, 'startSession response must carry session.id').toBeTruthy()

    // Submit through the live flow first (no answers required -- the mixed
    // exam's short_text question forces grading_pending regardless).
    await page.getByTestId('exam-submit-action').click()
    await expect(page.getByTestId('exam-result-page')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('exam-result-pending')).toBeVisible()

    // Now navigate AWAY, in the SAME page/browser session, to the new by-id
    // route -- a fresh mount, fresh getSessionState call, no in-memory
    // `phase` state carried over from the flow above.
    await page.goto(`/exam/sessions/${sessionId}/result`, { waitUntil: 'domcontentloaded' })

    await expect(page.getByTestId('exam-result-page')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('exam-result-pending')).toBeVisible()
    await expect(page.getByTestId('exam-result-score')).toHaveCount(0)
    await expect(page.getByText('Grading in progress')).toBeVisible()
  })
})

// ---------------------------------------------------------------------------
// 'Exam Result by id — not owner'
// ---------------------------------------------------------------------------

test.describe('Exam Result by id — not owner (REQ-351)', () => {
  test('a candidate requesting another candidate\'s session id does not receive that session\'s content', async ({ browser, request }) => {
    const token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    const exams = await queryActiveExams(request, token)
    const mixedExamId = findExamByTitle(exams, 'REQ-345 E2E Mixed Exam')

    // Learn admin-user's OWN mapped candidate_id (not the raw JWT sub -- see
    // discoverOwnCandidateId's own doc comment), via a real, immediately
    // cleaned-up probe session.
    const ownCandidateId = await discoverOwnCandidateId(request, token, mixedExamId)

    // REQ-345's seed task (lib/mix/tasks/letflow.seed.exam_fixtures.ex:134-136,
    // 178) pre-creates and submits a session against the mixed exam owned by
    // a FIXED fixture candidate ("req345-e2e-candidate"), whose mapped
    // candidate_id is provably not admin-user's own (discovered above).
    const sessions = await querySessionsForExam(request, token, mixedExamId)
    const foreignSession = sessions.find((s) => s.field_values.user_id && s.field_values.user_id !== ownCandidateId)
    if (!foreignSession) {
      throw new Error(
        'No session against "REQ-345 E2E Mixed Exam" owned by a candidate other than admin-user was found -- ' +
          'run `mix letflow.seed.exam_fixtures` against the dev DB first (it seeds req345-e2e-candidate\'s own ' +
          'pre-submitted session).',
      )
    }

    // 1) Raw HTTP check: admin-user's own token against a session it does
    // NOT own. get_session_state_for_user/3 (lib/letflow/exam/session.ex:342)
    // returns {:error, :not_owner} here, which
    // lib/letflow/routers/exam_sessions.ex's own "Ownership and tenant
    // isolation" doc comment says renders through the exact same
    // Response.not_found/1 call as a genuinely-missing session (no
    // distinguishing body, by design) -- observed status: 404.
    const rawRes = await request.get(`/api/v1/exam-sessions/${foreignSession.record_id}`, {
      headers: { Authorization: `Bearer ${token}` },
    })
    expect(rawRes.status(), 'GET /exam-sessions/:id on a session owned by another candidate must not return 200').toBe(404)

    // 2) Same check through the real UI: the by-id screen must not render
    // that session's content, only its own not-found state.
    const context = await browser.newContext()
    const page = await context.newPage()
    await loginWithToken(page, token)
    await page.goto(`/exam/sessions/${foreignSession.record_id}/result`, { waitUntil: 'domcontentloaded' })

    await expect(page.getByTestId('exam-result-byid-not-found')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('exam-result-page')).toHaveCount(0)
    await context.close()
  })
})
