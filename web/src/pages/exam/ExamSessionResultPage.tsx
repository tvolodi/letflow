/** ExamSessionResultPage — REQ-351
 *
 *  Opens an EXISTING exam session by id and renders its result phase,
 *  WITHOUT starting anything. This is a deliberate SIBLING of
 *  `ExamSessionPage.tsx` (REQ-338), not a branch folded into it -- see
 *  REQ-351's own description for why: `ExamSessionPage.tsx`'s mount effect
 *  (:112-127) unconditionally calls `examApi.startSession`, and this
 *  screen's own acceptance criteria forbid the by-id path from ever reaching
 *  `startSession` under any code path. This file therefore imports
 *  `examApi.getSessionState` ONLY -- grep confirms no `startSession` call
 *  anywhere below.
 *
 *  Reuses `ExamSessionPage.tsx`'s result-phase rendering via the shared
 *  `ExamResultView` component (extracted for exactly this reuse) rather than
 *  duplicating its JSX/testids.
 *
 *  URL SHAPE IS PROVISIONAL (REQ-351's own text, restated here so it is not
 *  read anywhere as a settled contract). REQ-350's numbered questions (2)
 *  and (3) may later decide Letflow serves a cross-session results-LIST; if
 *  so, this route becomes that list's detail view and its URL may be
 *  RENAMED by the requirement that implements the list. Nothing here or in
 *  `web/src/router.tsx` should be read as fixing `/exam/sessions/:sessionId/
 *  result` as a permanent contract.
 *
 *  THE TRACKED GAP THIS FILE DOES NOT WORK AROUND. `GET /exam-sessions/:id`
 *  (`Letflow.Exam.Session.get_session_state_for_user/3`, wrapped by
 *  `examApi.getSessionState`) returns `session_state_view()` --
 *  `{session, remaining_seconds, questions, answers}` -- and
 *  `session_view()` itself (lib/letflow/exam/session.ex:1151-1160) carries
 *  only `id/exam_id/candidate_id/status/seed/started_at/expires_at`. It
 *  never carries `total_score`/`total_max_score`/`percentage`/`passed` --
 *  those live only in `ExamSubmissionOutcome`, produced by
 *  `POST /exam-sessions/:id/submit`'s response or by
 *  `Letflow.Exam.Session`'s own private `outcome_from_session/1` helper
 *  (session.ex:1087-1098, used only inside `submit_session`'s idempotent
 *  re-submit path -- never reachable from the GET route). The backend's own
 *  moduledoc names this precisely: "a *result* view is a sixth behaviour
 *  this requirement's own dependency chain (REQ-330's five) never
 *  authorized, not a subset of the *state* read this module does
 *  implement" (lib/letflow/routers/exam_sessions.ex, "Deliberately NOT
 *  routed here" section).
 *
 *  So: for a `grading_pending` session, `session.status` alone is enough to
 *  render `exam-result-pending` honestly (no score field is ever displayed
 *  in that branch -- see `ExamResultView`). For a `submitted`/
 *  `auto_submitted` session, this screen cannot honestly construct the
 *  `total_score`/`percentage`/`passed` triple `exam-result-score` displays,
 *  and REFUSES to fabricate one -- see this project's own FRONTEND-DEV
 *  scope ("never a shim that normalises a backend contract mismatch").
 *  Instead it renders `exam-result-scoreUnavailable`, a distinct,
 *  honestly-labelled state, and the gap is reported in REQ-351's close-out
 *  as a follow-up for ELIXIR-DEV (extend `session_view`/
 *  `session_state_json` to surface the session's own persisted `score_pct`/
 *  `passed` once status is no longer `in_progress` -- NOT built here, since
 *  this requirement's own scope fence forbids touching anything under
 *  `lib/letflow/`).
 */

import { useEffect, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useIntl } from 'react-intl'
import { examApi } from '@/api/exam'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { ExamIntlProvider } from '@/i18n/ExamIntlProvider'
import { ExamResultView } from './ExamResultView'
import type { ExamSessionStateResponse, ExamSubmissionOutcome } from '@/types/exam'

type LoadState =
  | { kind: 'loading' }
  | { kind: 'not_found' }
  | { kind: 'pending'; outcome: ExamSubmissionOutcome }
  | { kind: 'score_unavailable' }

function ExamSessionResultPageInner() {
  const intl = useIntl()
  const navigate = useNavigate()
  const { sessionId } = useParams<{ sessionId: string }>()

  const [state, setState] = useState<LoadState>({ kind: 'loading' })

  useEffect(() => {
    if (!sessionId) return

    let cancelled = false

    // NOTE, load-bearing for REQ-351's own acceptance criteria: the ONLY
    // exam-session API call this file makes is getSessionState. There is no
    // startSession call anywhere in this component, under any branch.
    examApi
      .getSessionState(sessionId)
      .then((response: ExamSessionStateResponse) => {
        if (cancelled) return
        if (response.session.status === 'grading_pending') {
          setState({
            kind: 'pending',
            outcome: {
              status: 'grading_pending',
              total_score: 0,
              total_max_score: 0,
              percentage: 0,
              passed: null,
            },
          })
        } else {
          // 'submitted' | 'auto_submitted' | 'in_progress' -- none of these
          // carry the score fields this session-state read never returns.
          // See this file's top doc comment for why this is a tracked
          // backend gap rather than something worked around here.
          setState({ kind: 'score_unavailable' })
        }
      })
      .catch(() => {
        if (cancelled) return
        // get_session_state_for_user/3's {:error, :session_not_found} and
        // {:error, :not_owner} both render through the same
        // Response.not_found/1 call (lib/letflow/routers/exam_sessions.ex's
        // own "Ownership and tenant isolation" doc comment) -- a candidate
        // probing another candidate's session id observes the exact same
        // 404 as a genuinely-missing session, by design. Any other error
        // status is treated the same way here: this screen never renders
        // another candidate's content under any response shape.
        setState({ kind: 'not_found' })
      })

    return () => {
      cancelled = true
    }
  }, [sessionId])

  if (state.kind === 'loading') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.result.title' })}>
        <p data-testid="exam-result-byid-loading">{intl.formatMessage({ id: 'exam.result.byId.loading' })}</p>
      </PageLayout>
    )
  }

  if (state.kind === 'not_found') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.result.title' })}>
        <p data-testid="exam-result-byid-not-found" style={{ color: 'var(--color-error-dark)' }}>
          {intl.formatMessage({ id: 'exam.result.byId.notFound' })}
        </p>
        <Button variant="secondary" size="md" onClick={() => navigate('/exam')}>
          {intl.formatMessage({ id: 'exam.result.backToList' })}
        </Button>
      </PageLayout>
    )
  }

  if (state.kind === 'score_unavailable') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.result.title' })}>
        <p data-testid="exam-result-scoreUnavailable">{intl.formatMessage({ id: 'exam.result.byId.scoreUnavailable' })}</p>
        <Button variant="secondary" size="md" onClick={() => navigate('/exam')}>
          {intl.formatMessage({ id: 'exam.result.backToList' })}
        </Button>
      </PageLayout>
    )
  }

  // state.kind === 'pending'
  return <ExamResultView outcome={state.outcome} onBackToList={() => navigate('/exam')} />
}

export default function ExamSessionResultPage() {
  return (
    <ExamIntlProvider>
      <ExamSessionResultPageInner />
    </ExamIntlProvider>
  )
}
