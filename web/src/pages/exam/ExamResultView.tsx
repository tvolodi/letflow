/** ExamResultView — REQ-351
 *
 *  The result-phase rendering EXTRACTED verbatim (same testids, same markup,
 *  same message ids) out of `ExamSessionPage.tsx`'s own
 *  `if (phase.kind === 'result')` branch, so that branch and the new
 *  `ExamSessionResultPage.tsx` (REQ-351, opens an existing session by id)
 *  render identically instead of maintaining two copies of the same JSX.
 *
 *  `ExamSessionPage.tsx` reaches `phase.kind === 'result'` from the LIVE flow
 *  (a real `ExamSubmissionOutcome` returned by `submitSession`/anti-cheat
 *  forced-submit); `ExamSessionResultPage.tsx` reaches it from a session
 *  LOADED via `examApi.getSessionState`, which does not carry
 *  `ExamSubmissionOutcome`'s score fields for an already-submitted session
 *  (see that file's own doc comment for the tracked gap). Both callers must
 *  already be rendering inside `ExamIntlProvider` -- this component does not
 *  wrap itself in one, matching every other inner exam component
 *  (`ExamSessionPageInner`, `ExamListPageInner`).
 */

import { useIntl } from 'react-intl'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import type { ExamSubmissionOutcome } from '@/types/exam'

export interface ExamResultViewProps {
  outcome: ExamSubmissionOutcome
  onBackToList: () => void
}

export function ExamResultView({ outcome, onBackToList }: ExamResultViewProps) {
  const intl = useIntl()
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
        <Button variant="secondary" size="md" onClick={onBackToList}>
          {intl.formatMessage({ id: 'exam.result.backToList' })}
        </Button>
      </PageLayout>
    </div>
  )
}
