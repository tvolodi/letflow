// @vitest-environment jsdom
/**
 * REQ-371 §8.1 — definitionRollbackApi.rollback() hits the exact URL and
 * body shape the real backend route expects
 * (`POST /api/v1/definitions/:process_key/rollback`, body
 * `{target_version}` — `lib/letflow/routers/definitions.ex:1122-1195`).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { definitionRollbackApi } from '../definitionRollback'
import { setToken, clearToken } from '../client'

const originalFetch = window.fetch

function jsonResponse(body: unknown, init: { status?: number; headers?: Record<string, string> } = {}) {
  return Promise.resolve(
    new Response(JSON.stringify(body), {
      status: init.status ?? 200,
      headers: { 'Content-Type': 'application/json', ...(init.headers ?? {}) },
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

describe('definitionRollbackApi.rollback', () => {
  it('POSTs to /api/v1/definitions/:name/rollback with body {target_version}', async () => {
    const fetchSpy = vi.fn().mockImplementation(() =>
      jsonResponse({
        definition_id: 'd1',
        version: '1.0.0',
        rolled_back_from_version: '2.0.0',
        superseded_review_id: null,
        event_id: 'evt-1',
      }),
    )
    window.fetch = fetchSpy as unknown as typeof window.fetch

    const result = await definitionRollbackApi.rollback('approvals', { target_version: '1.0.0' })

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/definitions/approvals/rollback')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({ target_version: '1.0.0' })
    expect(result.version).toBe('1.0.0')
    expect(result.rolled_back_from_version).toBe('2.0.0')
    expect(result.event_id).toBe('evt-1')
  })

  it('URL-encodes a process key containing characters needing encoding', async () => {
    const fetchSpy = vi.fn().mockImplementation(() =>
      jsonResponse({
        definition_id: 'd1',
        version: '1.0.0',
        rolled_back_from_version: '2.0.0',
        superseded_review_id: null,
        event_id: 'evt-1',
      }),
    )
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await definitionRollbackApi.rollback('a name/with special?chars', { target_version: '1.0.0' })

    const [url] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toBe(`/api/v1/definitions/${encodeURIComponent('a name/with special?chars')}/rollback`)
  })
})
