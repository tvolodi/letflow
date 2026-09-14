// @vitest-environment jsdom
/**
 * REQ-338 AC1 — web/src/api/exam.ts exposes the five named operations
 * (startSession, saveAnswer, submitSession, getSessionState, reportEvent)
 * and each hits REQ-335's real route
 * (lib/letflow/routers/exam_sessions.ex's own "Route table"):
 *
 *   POST   /api/v1/exam-sessions
 *   GET    /api/v1/exam-sessions/:id
 *   PUT    /api/v1/exam-sessions/:id/answers/:question_id
 *   POST   /api/v1/exam-sessions/:id/submit
 *   POST   /api/v1/exam-sessions/:id/events
 *
 * Plus `queryExamRecords`, this requirement's own self-contained wrapper
 * around the generic `POST /entities/query` route (used by the exam list
 * screen) -- added so REQ-338 does not import REQ-336's `entitiesApi`
 * (a separate, currently-blocked requirement); see web/src/api/exam.ts's
 * own moduledoc comment.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { examApi } from '../exam'
import { setToken, clearToken } from '../client'

const originalFetch = window.fetch

function jsonResponse(body: unknown, init: { status?: number } = {}) {
  return Promise.resolve(
    new Response(JSON.stringify(body), {
      status: init.status ?? 200,
      headers: { 'Content-Type': 'application/json' },
    }),
  )
}

beforeEach(() => {
  setToken('test-token')
})

afterEach(() => {
  window.fetch = originalFetch
  clearToken()
  vi.restoreAllMocks()
})

describe('REQ-338 AC1 — examApi shape', () => {
  it('exposes exactly the five named session operations plus queryExamRecords', () => {
    const keys = Object.keys(examApi).sort()
    expect(keys).toEqual(
      [
        'startSession',
        'getSessionState',
        'saveAnswer',
        'submitSession',
        'reportEvent',
        'queryExamRecords',
      ].sort(),
    )
  })
})

describe('REQ-338 AC1 — examApi hits REQ-335s real route table', () => {
  it('startSession -> POST /api/v1/exam-sessions with exam_id in the body', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ session: {}, remaining_seconds: 0, questions: [], answers: {} }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.startSession('exam-1')

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/exam-sessions'),
      expect.objectContaining({ method: 'POST' }),
    )
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({ exam_id: 'exam-1' })
  })

  it('getSessionState -> GET /api/v1/exam-sessions/:id', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ session: {}, remaining_seconds: 0, questions: [], answers: {} }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.getSessionState('session-1')

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/exam-sessions/session-1'),
      expect.objectContaining({}),
    )
  })

  it('saveAnswer -> PUT /api/v1/exam-sessions/:id/answers/:question_id', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ remaining_seconds: 42 }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.saveAnswer('session-1', 'question-1', { selected_option_ids: ['opt-1'], time_spent_seconds: 5 })

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/exam-sessions/session-1/answers/question-1'),
      expect.objectContaining({ method: 'PUT' }),
    )
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({ selected_option_ids: ['opt-1'], time_spent_seconds: 5 })
  })

  it('saveAnswer -> ISS-0650: carries text_answer in the body when supplied', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ remaining_seconds: 42 }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.saveAnswer('session-1', 'question-1', {
      selected_option_ids: [],
      time_spent_seconds: 5,
      text_answer: 'Paris',
    })

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({
      selected_option_ids: [],
      time_spent_seconds: 5,
      text_answer: 'Paris',
    })
  })

  it('submitSession -> POST /api/v1/exam-sessions/:id/submit', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ status: 'submitted', total_score: 1, total_max_score: 1, percentage: 100, passed: true }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.submitSession('session-1')

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/exam-sessions/session-1/submit'),
      expect.objectContaining({ method: 'POST' }),
    )
  })

  it('reportEvent -> POST /api/v1/exam-sessions/:id/events with type in the body', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ action_taken: 'log', event_count: 1, warning: false, submission: null }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await examApi.reportEvent('session-1', 'tab_switch')

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/exam-sessions/session-1/events'),
      expect.objectContaining({ method: 'POST' }),
    )
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({ type: 'tab_switch' })
  })
})
