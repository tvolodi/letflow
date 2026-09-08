// @vitest-environment jsdom
/**
 * Unit tests — ISS-0532: healthReady() must probe the real `GET /health`
 * liveness endpoint, not the non-existent `GET /health/ready` readiness
 * endpoint (see `docs/frontend/contract-gaps.md` row 15 and
 * `lib/letflow/router.ex`'s moduledoc for why readiness isn't served).
 *
 * Prior to this fix, healthReady() called `/health/ready`, which always
 * 404'd, and the resulting error was swallowed into `false` — indistinguishable
 * from a real outage. These tests pin the corrected behaviour: healthReady()
 * calls `/health` and reflects its real result.
 */

import { afterEach, describe, expect, it, vi } from 'vitest'
import { healthReady } from '../health'

function mockFetchOnce(response: { ok: boolean; status: number; body?: unknown }): void {
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({
      ok: response.ok,
      status: response.status,
      json: async () => response.body ?? {},
      headers: new Headers(),
    }),
  )
}

describe('healthReady', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('TC-ISS0532-01: calls GET /health, not /health/ready', async () => {
    mockFetchOnce({ ok: true, status: 200, body: { status: 'ok' } })

    await healthReady()

    expect(fetch).toHaveBeenCalledTimes(1)
    const calledUrl = (fetch as ReturnType<typeof vi.fn>).mock.calls[0][0] as string
    expect(calledUrl).toContain('/health')
    expect(calledUrl).not.toContain('/health/ready')
  })

  it('TC-ISS0532-02: returns true when GET /health responds 200 {"status":"ok"}', async () => {
    mockFetchOnce({ ok: true, status: 200, body: { status: 'ok' } })

    const result = await healthReady()

    expect(result).toBe(true)
  })

  it('TC-ISS0532-03: returns false when GET /health responds with a non-2xx status', async () => {
    mockFetchOnce({ ok: false, status: 503, body: { status: 'unavailable' } })

    const result = await healthReady()

    expect(result).toBe(false)
  })

  it('TC-ISS0532-04: returns false (never throws) on a network failure', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to fetch')))

    await expect(healthReady()).resolves.toBe(false)
  })
})
