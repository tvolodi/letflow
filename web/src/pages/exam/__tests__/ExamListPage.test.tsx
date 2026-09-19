// @vitest-environment jsdom
/**
 * REQ-338 AC8 — the assignment-question ambiguity escape, option (a):
 * lib/letflow/exam/session.ex's FINDING records check_assigned/3 as a
 * documented no-op ("every candidate is currently treated as assigned").
 * This screen lists every active exam and renders the provisional-pending-
 * decision-record notice PROMINENTLY -- this test asserts that exact notice
 * text is present, per the acceptance criterion's own wording ("shows the
 * provisional-pending-decision-record copy actually rendered in the list
 * screen, proven by a test asserting that text is present").
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(() => ({
    data: {
      items: [
        { record_id: 'exam-1', field_values: { title: 'Algebra basics', status: 'active' }, deleted: false, entity_def_version: 'v1', last_event_global_seq: 1 },
      ],
      next_cursor: null,
    },
    isLoading: false,
    isError: false,
  })),
}))

vi.mock('@/api/exam', () => ({
  examApi: {
    listAvailableExams: vi.fn(),
  },
}))

import ExamListPage from '@/pages/exam/ExamListPage'
import { examMessages } from '@/i18n/examMessages'

beforeEach(() => {
  vi.clearAllMocks()
})

afterEach(() => {
  cleanup()
})

describe('REQ-338 AC8 — provisional exam list, option (a)', () => {
  it('renders the provisional-pending-decision-record notice text', () => {
    render(
      <MemoryRouter>
        <ExamListPage />
      </MemoryRouter>,
    )

    const notice = screen.getByTestId('exam-list-provisional-notice')
    expect(notice.textContent).toBe(examMessages.en['exam.list.provisionalNotice'])
    expect(notice.textContent).toMatch(/provisional/i)
  })

  it('lists the active exam and offers a Start action', () => {
    render(
      <MemoryRouter>
        <ExamListPage />
      </MemoryRouter>,
    )

    expect(screen.getByTestId('exam-list-item-exam-1')).toBeInTheDocument()
    expect(screen.getByTestId('exam-list-start-exam-1')).toBeInTheDocument()
  })
})

describe('ISS-0728 -- localized exam title resolution', () => {
  it('resolves a LocalizedText title object to the current-locale string, not "[object Object]"', async () => {
    vi.resetModules()
    vi.doMock('@tanstack/react-query', () => ({
      useQuery: vi.fn(() => ({
        data: {
          items: [
            {
              record_id: 'exam-2',
              field_values: {
                title: {
                  en: 'Safety Certification Exam',
                  kk: 'Qauipsizdik sertifikaty',
                  ru: 'Sertifikat bezopasnosti',
                },
                status: 'active',
              },
              deleted: false,
              entity_def_version: 'v1',
              last_event_global_seq: 1,
            },
          ],
          next_cursor: null,
        },
        isLoading: false,
        isError: false,
      })),
    }))
    vi.doMock('@/api/exam', () => ({
      examApi: { listAvailableExams: vi.fn() },
    }))

    const { default: ExamListPageFresh } = await import('@/pages/exam/ExamListPage')

    render(
      <MemoryRouter>
        <ExamListPageFresh />
      </MemoryRouter>,
    )

    const item = screen.getByTestId('exam-list-item-exam-2')
    expect(item.textContent).toContain('Safety Certification Exam')
    expect(item.textContent).not.toContain('[object Object]')
    expect(item.textContent).not.toContain('[object LocalizedText]')
  })
})
