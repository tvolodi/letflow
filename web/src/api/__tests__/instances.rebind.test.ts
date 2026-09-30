// @vitest-environment jsdom
/**
 * REQ-432 build item 2 — instancesApi.rebindPins hits the real REQ-078 route
 * with the designed body and an Idempotency-Key header (design §4.2).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { instancesApi } from '../instances'
import { setToken, clearToken } from '../client'

const originalFetch = window.fetch

beforeEach(() => setToken('test-token'))
afterEach(() => {
  window.fetch = originalFetch
  clearToken()
  vi.restoreAllMocks()
})

describe('REQ-432 instancesApi.rebindPins', () => {
  it('POSTs /api/v1/instances/:id/rebind-pins with body and Idempotency-Key header', async () => {
    const response = {
      instance_id: 'inst-1',
      changes: [{ kind: 'catalog_entry', ref: 'svc-a', prior_version: '1', new_version: '2' }],
      rebound_at: '2026-09-30T00:00:00Z',
    }
    const fetchSpy = vi.fn().mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify(response), { status: 200, headers: { 'Content-Type': 'application/json' } })),
    )
    window.fetch = fetchSpy as unknown as typeof window.fetch

    const body = { reason: 'because', entries: [{ kind: 'catalog_entry' as const, ref: 'svc-a', version: '2' }] }
    const out = await instancesApi.rebindPins('inst-1', body, 'key-123')

    expect(out).toEqual(response)
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toMatch(/\/api\/v1\/instances\/inst-1\/rebind-pins$/)
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual(body)
    const headers = new Headers(init.headers as HeadersInit)
    expect(headers.get('Idempotency-Key')).toBe('key-123')
  })
})
