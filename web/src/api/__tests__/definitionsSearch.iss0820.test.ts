// @vitest-environment jsdom
/**
 * ISS-0820: definitionsApi.search must send only q, cursor, and page_size —
 * the three parameters handle_search/1 in lib/letflow/routers/definitions.ex:519
 * actually reads. limit and offset were dead params silently ignored by the backend.
 */

import { afterEach, describe, expect, it, vi } from 'vitest'
import { definitionsApi } from '../definitions'

function mockFetchOnce(body: unknown = { items: [], next_cursor: null }): void {
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => body,
      headers: new Headers({ 'content-type': 'application/json' }),
    }),
  )
}

describe('definitionsApi.search (ISS-0820)', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('TC-ISS0820-01: sends q and no limit/offset — only handle_search/1 params', async () => {
    mockFetchOnce()
    await definitionsApi.search({ q: 'onboarding' })

    expect(fetch).toHaveBeenCalledTimes(1)
    const calledUrl = (fetch as ReturnType<typeof vi.fn>).mock.calls[0][0] as string
    expect(calledUrl).toContain('q=onboarding')
    expect(calledUrl).not.toContain('limit=')
    expect(calledUrl).not.toContain('offset=')
  })

  it('TC-ISS0820-02: sends page_size when provided', async () => {
    mockFetchOnce()
    await definitionsApi.search({ q: 'hire', page_size: 10 })

    const calledUrl = (fetch as ReturnType<typeof vi.fn>).mock.calls[0][0] as string
    expect(calledUrl).toContain('page_size=10')
    expect(calledUrl).not.toContain('limit=')
  })

  it('TC-ISS0820-03: sends cursor when provided', async () => {
    mockFetchOnce()
    await definitionsApi.search({ q: 'hire', cursor: 'cursor-abc' })

    const calledUrl = (fetch as ReturnType<typeof vi.fn>).mock.calls[0][0] as string
    expect(calledUrl).toContain('cursor=cursor-abc')
    expect(calledUrl).not.toContain('offset=')
  })

  it('TC-ISS0820-04: calls /api/v1/definitions/search', async () => {
    mockFetchOnce()
    await definitionsApi.search({ q: 'test' })

    const calledUrl = (fetch as ReturnType<typeof vi.fn>).mock.calls[0][0] as string
    expect(calledUrl).toContain('/api/v1/definitions/search')
  })
})
