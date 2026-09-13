/** ExamSessionPage — REQ-338
 *
 *  The candidate exam-taking flow: start/eligibility, in-progress (one
 *  question at a time, autosave, server-re-anchored countdown), and
 *  submit/result -- as one page component sharing one `phase` state machine,
 *  because all three screens share the same session identity and the
 *  anti-cheat listeners must be torn down exactly when the flow leaves the
 *  in-progress phase (REQ-333 wiring below).
 *
 *  SCREEN 1 -- start/eligibility. On mount, calls `examApi.startSession`.
 *  A failure renders one of REQ-332's six eligibility errors as a distinct
 *  translated message (`utils/examErrors.ts`'s `classifyStartError`), never
 *  one generic string.
 *
 *  SCREEN 2 -- in-progress. One question at a time. Selecting an answer
 *  autosaves immediately via `examApi.saveAnswer`; the countdown
 *  (`remainingSeconds` state) is SET DIRECTLY from every save response's
 *  `remaining_seconds` field -- never left to free-run from a client-only
 *  timer, per REQ-332's server-authoritative-clock property. A local
 *  `setInterval` only ticks the DISPLAYED value down by one second between
 *  saves; it never overrides a value the server has not itself sent. An
 *  autosave rejected because the session's server-side deadline has passed
 *  (`isDeadlinePassedError`) moves the whole flow to phase 'expired' -- a
 *  terminal state, not a retry loop.
 *
 *  SCREEN 3 -- submit/result. A `grading_pending` outcome
 *  (`Session.submission_outcome`'s own `status`) renders the pending copy
 *  and NEVER a numeric score; any other status renders the real
 *  score/percentage/passed.
 *
 *  ANTI-CHEAT. `useAntiCheatSignals` is enabled only while `phase ===
 *  'in_progress'`; its `warn` outcome surfaces a visible warning with the
 *  running `event_count`, and its `submit` outcome moves `phase` to
 *  'result' using the SERVER's own `submission` payload (never by
 *  continuing to show the in-progress screen) -- which also flips `enabled`
 *  to false, tearing the listeners down (see the hook's own doc comment).
 *
 *  Known gap, flagged rather than silently worked around: REQ-335's
 *  `@autosave_schema` (lib/letflow/routers/exam_sessions.ex) and
 *  `Letflow.Exam.Session.answer_attrs()` carry no `text_answer` field at
 *  all -- there is currently no route-level way to persist a short-text
 *  answer's actual text through autosave. This screen renders a short-text
 *  question's stem but does not offer a text input that would silently fail
 *  to save; it shows an explicit "not yet supported" note instead. Routed to
 *  ORCH/CODE-DESIGNER as a follow-on gap, not shimmed around here.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useIntl } from 'react-intl'
import { examApi } from '@/api/exam'
import { classifyStartError, isDeadlinePassedError, type ExamEligibilityErrorKind } from '@/utils/examErrors'
import { useAntiCheatSignals } from '@/hooks/useAntiCheatSignals'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { ExamIntlProvider } from '@/i18n/ExamIntlProvider'
import type {
  AntiCheatSignalOutcome,
  ExamAnswerState,
  ExamQuestionState,
  ExamSessionStateResponse,
  ExamSubmissionOutcome,
} from '@/types/exam'

type Phase =
  | { kind: 'starting' }
  | { kind: 'error'; error: ExamEligibilityErrorKind }
  | { kind: 'in_progress' }
  | { kind: 'expired' }
  | { kind: 'result'; outcome: ExamSubmissionOutcome }

function formatRemaining(totalSeconds: number): { minutes: string; seconds: string } {
  const clamped = Math.max(0, totalSeconds)
  const minutes = Math.floor(clamped / 60)
  const seconds = clamped % 60
  return { minutes: String(minutes).padStart(2, '0'), seconds: String(seconds).padStart(2, '0') }
}

function ExamSessionPageInner() {
  const intl = useIntl()
  const navigate = useNavigate()
  const { examId } = useParams<{ examId: string }>()

  const [phase, setPhase] = useState<Phase>({ kind: 'starting' })
  const [session, setSession] = useState<ExamSessionStateResponse | null>(null)
  const [answers, setAnswers] = useState<Record<string, ExamAnswerState>>({})
  const [remainingSeconds, setRemainingSeconds] = useState<number>(0)
  const [saveStatus, setSaveStatus] = useState<'idle' | 'saving' | 'saved' | 'error'>('idle')
  const [warning, setWarning] = useState<{ eventCount: number } | null>(null)
  const [questionIndex, setQuestionIndex] = useState(0)

  const startedRef = useRef(false)

  // ── Screen 1: start ──────────────────────────────────────────────────
  useEffect(() => {
    if (!examId || startedRef.current) return
    startedRef.current = true

    examApi
      .startSession(examId)
      .then((state) => {
        setSession(state)
        setAnswers(state.answers)
        setRemainingSeconds(state.remaining_seconds)
        setPhase({ kind: 'in_progress' })
      })
      .catch((err: unknown) => {
        setPhase({ kind: 'error', error: classifyStartError(err) })
      })
  }, [examId])

  // Local between-saves ticking only -- never authoritative on its own.
  useEffect(() => {
    if (phase.kind !== 'in_progress') return undefined
    const id = window.setInterval(() => {
      setRemainingSeconds((prev) => Math.max(0, prev - 1))
    }, 1000)
    return () => window.clearInterval(id)
  }, [phase.kind])

  const currentQuestion: ExamQuestionState | undefined = session?.questions[questionIndex]

  const saveAnswer = useCallback(
    (question: ExamQuestionState, selectedOptionIds: string[]) => {
      if (!session) return
      setSaveStatus('saving')
      examApi
        .saveAnswer(session.session.id, question.question_id, {
          selected_option_ids: selectedOptionIds,
          time_spent_seconds: answers[question.question_id]?.time_spent_seconds ?? 0,
        })
        .then((response) => {
          // Re-anchor to the server's value directly -- not asymptotically.
          setRemainingSeconds(response.remaining_seconds)
          setAnswers((prev) => ({
            ...prev,
            [question.question_id]: {
              selected_option_ids: selectedOptionIds,
              text_answer: prev[question.question_id]?.text_answer ?? null,
              time_spent_seconds: prev[question.question_id]?.time_spent_seconds ?? 0,
              saved_at: new Date().toISOString(),
            },
          }))
          setSaveStatus('saved')
        })
        .catch((err: unknown) => {
          if (isDeadlinePassedError(err)) {
            setPhase({ kind: 'expired' })
            return
          }
          setSaveStatus('error')
        })
    },
    [session, answers],
  )

  const handleOptionToggle = (question: ExamQuestionState, optionId: string) => {
    const isMulti = question.type === 'multi_choice'
    const current = answers[question.question_id]?.selected_option_ids ?? []
    const next = isMulti
      ? current.includes(optionId)
        ? current.filter((id) => id !== optionId)
        : [...current, optionId]
      : [optionId]
    saveAnswer(question, next)
  }

  const handleAntiCheatOutcome = useCallback(
    (outcome: AntiCheatSignalOutcome) => {
      if (outcome.action_taken === 'warn') {
        setWarning({ eventCount: outcome.event_count })
        return
      }
      if (outcome.action_taken === 'submit' && outcome.submission) {
        setPhase({ kind: 'result', outcome: outcome.submission })
      }
      // 'log' -> no visible UI change, per this requirement's own spec.
    },
    [],
  )

  useAntiCheatSignals(session?.session.id ?? null, phase.kind === 'in_progress', handleAntiCheatOutcome)

  const handleSubmit = () => {
    if (!session) return
    examApi.submitSession(session.session.id).then((outcome) => {
      setPhase({ kind: 'result', outcome })
    })
  }

  // ── Render ───────────────────────────────────────────────────────────

  if (phase.kind === 'starting') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.session.remainingTime' }, { minutes: '--', seconds: '--' })}>
        <p data-testid="exam-starting">{intl.formatMessage({ id: 'exam.start.starting' })}</p>
      </PageLayout>
    )
  }

  if (phase.kind === 'error') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.list.title' })}>
        <p data-testid="exam-start-error" style={{ color: 'var(--color-error-dark)' }}>
          {intl.formatMessage({ id: `exam.start.error.${phase.error}` })}
        </p>
        <Button variant="secondary" size="md" onClick={() => navigate('/exam')}>
          {intl.formatMessage({ id: 'exam.start.retryAction' })}
        </Button>
      </PageLayout>
    )
  }

  if (phase.kind === 'expired') {
    return (
      <PageLayout title={intl.formatMessage({ id: 'exam.session.expired.title' })}>
        <p data-testid="exam-expired">{intl.formatMessage({ id: 'exam.session.expired.body' })}</p>
        <Button variant="secondary" size="md" onClick={() => navigate('/exam')}>
          {intl.formatMessage({ id: 'exam.result.backToList' })}
        </Button>
      </PageLayout>
    )
  }

  if (phase.kind === 'result') {
    const { outcome } = phase
    const isPending = outcome.status === 'grading_pending'
    return (
      <div data-testid="exam-result-page">
        <PageLayout title={intl.formatMessage({ id: 'exam.result.title' })}>
          {isPending ? (
            <div data-testid="exam-result-pending">
              <h2>{intl.formatMessage({ id: 'exam.result.gradingPending.title' })}</h2>
              <p>{intl.formatMessage({ id: 'exam.result.gradingPending.body' })}</p>
            </div>
          ) : (
            <div data-testid="exam-result-score">
              <p>
                {intl.formatMessage(
                  { id: 'exam.result.score' },
                  { score: outcome.total_score, maxScore: outcome.total_max_score, percentage: outcome.percentage },
                )}
              </p>
              <p>{intl.formatMessage({ id: outcome.passed ? 'exam.result.passed' : 'exam.result.failed' })}</p>
            </div>
          )}
          <Button variant="secondary" size="md" onClick={() => navigate('/exam')}>
            {intl.formatMessage({ id: 'exam.result.backToList' })}
          </Button>
        </PageLayout>
      </div>
    )
  }

  // phase.kind === 'in_progress'
  const { minutes, seconds } = formatRemaining(remainingSeconds)

  return (
    <div data-testid="exam-session-page">
      <PageLayout
        title={intl.formatMessage({ id: 'exam.session.remainingTime' }, { minutes, seconds })}
        actions={
          <Button variant="primary" size="md" data-testid="exam-submit-action" onClick={handleSubmit}>
            {intl.formatMessage({ id: 'exam.session.submitAction' })}
          </Button>
        }
      >
        {warning && (
          <div
            data-testid="exam-anticheat-warning"
            role="alert"
            style={{
              background: 'var(--color-warning-tint)',
              border: '1px solid var(--color-warning-border)',
              color: 'var(--color-warning-text)',
              borderRadius: 'var(--radius-md)',
              padding: 'var(--space-4)',
              marginBottom: 'var(--space-4)',
            }}
          >
            {intl.formatMessage({ id: 'exam.anticheat.warning' }, { count: warning.eventCount })}
          </div>
        )}

        {session && currentQuestion && (
          <div data-testid={`exam-question-${currentQuestion.question_id}`}>
            <p>
              {intl.formatMessage(
                { id: 'exam.session.questionOf' },
                { current: questionIndex + 1, total: session.questions.length },
              )}
            </p>
            <h3>{currentQuestion.stem}</h3>

            {currentQuestion.type === 'short_text' ? (
              <p data-testid="exam-short-text-unsupported">
                {intl.formatMessage({ id: 'exam.session.shortTextUnsupported' })}
              </p>
            ) : (
              <div>
                {currentQuestion.options.map((option) => {
                  const selected = (answers[currentQuestion.question_id]?.selected_option_ids ?? []).includes(
                    option.id,
                  )
                  return (
                    <label key={option.id} style={{ display: 'block', marginBottom: 'var(--space-2)' }}>
                      <input
                        type={currentQuestion.type === 'multi_choice' ? 'checkbox' : 'radio'}
                        name={currentQuestion.question_id}
                        checked={selected}
                        data-testid={`exam-option-${option.id}`}
                        onChange={() => handleOptionToggle(currentQuestion, option.id)}
                      />{' '}
                      {option.text}
                    </label>
                  )
                })}
              </div>
            )}

            <p data-testid="exam-save-status">
              {saveStatus === 'saving' && intl.formatMessage({ id: 'exam.session.saveStatus.saving' })}
              {saveStatus === 'saved' && intl.formatMessage({ id: 'exam.session.saveStatus.saved' })}
              {saveStatus === 'error' && intl.formatMessage({ id: 'exam.session.saveStatus.error' })}
            </p>

            <div style={{ display: 'flex', gap: 'var(--space-2)' }}>
              <Button
                variant="secondary"
                size="sm"
                disabled={questionIndex === 0}
                onClick={() => setQuestionIndex((i) => Math.max(0, i - 1))}
              >
                {intl.formatMessage({ id: 'exam.session.prevQuestion' })}
              </Button>
              <Button
                variant="secondary"
                size="sm"
                disabled={!session || questionIndex >= session.questions.length - 1}
                onClick={() => setQuestionIndex((i) => Math.min((session?.questions.length ?? 1) - 1, i + 1))}
              >
                {intl.formatMessage({ id: 'exam.session.nextQuestion' })}
              </Button>
            </div>
          </div>
        )}
      </PageLayout>
    </div>
  )
}

export default function ExamSessionPage() {
  return (
    <ExamIntlProvider>
      <ExamSessionPageInner />
    </ExamIntlProvider>
  )
}
