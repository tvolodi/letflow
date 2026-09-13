/** ExamListPage — REQ-338
 *
 *  THE ASSIGNMENT-QUESTION AMBIGUITY ESCAPE — OPTION (a) CHOSEN.
 *
 *  lib/letflow/exam/session.ex's own moduledoc "FINDING" section states,
 *  verbatim: "No exam_assignment entity exists anywhere in this tenant's
 *  schema... check_assigned/3 below is a documented no-op -- every candidate
 *  is currently treated as assigned." This screen lists every exam whose
 *  status is `active`, matching that no-op's actual current behaviour
 *  honestly (a candidate "treated as assigned" to everything sees a list
 *  consistent with that), and renders `exam.list.provisionalNotice`
 *  PROMINENTLY so a later fix to `check_assigned/3` does not silently strand
 *  a stale "shows everything" list screen. Option (b) (report this
 *  requirement BLOCKED) was rejected: the requirement's own text frames (a)
 *  and (b) as "two consistent options" and this requirement's other ten
 *  acceptance criteria (start/in-progress/result screens, anti-cheat wiring)
 *  are all independently buildable and required regardless of how the list
 *  screen is resolved -- reporting the whole requirement BLOCKED over one
 *  screen's data source, when a truthful provisional list is buildable,
 *  would leave nine other acceptance criteria undone unnecessarily.
 *
 *  Read exclusively via the existing generic entity-read route
 *  (`POST /entities/query`, this requirement's OWN `examApi.queryExamRecords`
 *  in web/src/api/exam.ts) -- no new backend route is needed to list `exam`
 *  records, and none is invented here. Deliberately not REQ-336's
 *  `entitiesApi.queryRecords`: REQ-338 does not depend on REQ-336 (both
 *  requirements' own texts say so explicitly), so this page calls the same
 *  generic route through its own requirement's file instead.
 */

import { useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { examApi } from '@/api/exam'
import { queryKeys } from '@/api/queryKeys'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { ExamIntlProvider } from '@/i18n/ExamIntlProvider'

const EXAM_ENTITY_TYPE = 'exam'

function ExamListPageInner() {
  const intl = useIntl()
  const navigate = useNavigate()

  const examsQuery = useQuery({
    queryKey: queryKeys.entities.records(EXAM_ENTITY_TYPE, { page_size: 100 }),
    queryFn: () =>
      examApi.queryExamRecords({
        filters: [{ field: 'status', op: 'eq', value: 'active' }],
        page_size: 100,
      }),
  })

  const exams = useMemo(() => examsQuery.data?.items ?? [], [examsQuery.data])

  return (
    <div data-testid="exam-list-page">
      <PageLayout title={intl.formatMessage({ id: 'exam.list.title' })}>
        <div
          data-testid="exam-list-provisional-notice"
          role="note"
          style={{
            background: 'var(--color-warning-tint)',
            border: '1px solid var(--color-warning-border)',
            color: 'var(--color-warning-text)',
            borderRadius: 'var(--radius-md)',
            padding: 'var(--space-4)',
            marginBottom: 'var(--space-4)',
          }}
        >
          {intl.formatMessage({ id: 'exam.list.provisionalNotice' })}
        </div>

        <QueryStateBoundary
          state={
            (examsQuery.isLoading
              ? 'loading'
              : examsQuery.isError
                ? classifyError(examsQuery.error)
                : 'success') as RendererState
          }
          onRetry={() => {
            void examsQuery.refetch()
          }}
          columns={[{ widthPercent: 70 }, { widthPercent: 30 }]}
        >
          {examsQuery.isError && (
            <p style={{ color: 'var(--color-error-dark)' }}>
              {intl.formatMessage({ id: 'exam.list.loadError' })}
            </p>
          )}

          {exams.length === 0 && (
            <p data-testid="exam-list-empty">{intl.formatMessage({ id: 'exam.list.emptyMessage' })}</p>
          )}

          <ul data-testid="exam-list" style={{ listStyle: 'none', padding: 0, margin: 0 }}>
            {exams.map((exam) => (
              <li
                key={exam.record_id}
                data-testid={`exam-list-item-${exam.record_id}`}
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  background: 'var(--surface-card)',
                  border: '1px solid var(--border-default)',
                  borderRadius: 'var(--radius-md)',
                  padding: 'var(--space-4)',
                  marginBottom: 'var(--space-2)',
                }}
              >
                <span>{String(exam.field_values.title ?? exam.field_values.name ?? exam.record_id)}</span>
                <Button
                  variant="primary"
                  size="sm"
                  data-testid={`exam-list-start-${exam.record_id}`}
                  onClick={() => navigate(`/exam/${exam.record_id}/session`)}
                >
                  {intl.formatMessage({ id: 'exam.list.startAction' })}
                </Button>
              </li>
            ))}
          </ul>
        </QueryStateBoundary>
      </PageLayout>
    </div>
  )
}

export default function ExamListPage() {
  return (
    <ExamIntlProvider>
      <ExamListPageInner />
    </ExamIntlProvider>
  )
}
