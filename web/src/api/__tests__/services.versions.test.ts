// @vitest-environment jsdom
/**
 * REQ-432 build item 1 — publish/retire client functions hit the real,
 * already-shipped REQ-373 routes with the designed bodies (design §2.2).
 * Follows the window.fetch-spy convention of identity.removeMembers.test.ts.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { servicesApi } from '../services'
import { setToken, clearToken } from '../client'

const originalFetch = window.fetch

function jsonResponse(body: unknown, status = 200) {
  return Promise.resolve(
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }),
  )
}

const RECORD = { service_id: 'svc-a', version: '2', status: 'ACTIVE' }

beforeEach(() => setToken('test-token'))
afterEach(() => {
  window.fetch = originalFetch
  clearToken()
  vi.restoreAllMocks()
})

describe('REQ-432 servicesApi.publishVersion', () => {
  it('POSTs /api/v1/admin/services/:id/versions with the body as JSON', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse(RECORD, 201))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    const body = { version: '2', endpoint_url: 'https://example.invalid/x', timeout_ms: 5000, auth_method: 'NONE' }
    const out = await servicesApi.publishVersion('svc-a', body)

    expect(out).toEqual(RECORD)
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toMatch(/\/api\/v1\/admin\/services\/svc-a\/versions$/)
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual(body)
  })
})

describe('REQ-432 servicesApi.retire', () => {
  it('POSTs /api/v1/admin/services/:id/retire with no body', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ ...RECORD, status: 'RETIRED' }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    const out = await servicesApi.retire('svc-a')

    expect(out.status).toBe('RETIRED')
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toMatch(/\/api\/v1\/admin\/services\/svc-a\/retire$/)
    expect(init.method).toBe('POST')
    expect(init.body).toBeUndefined()
  })
})
