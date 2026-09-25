// @vitest-environment jsdom
/**
 * ISS-0816 AC3 — `groupsApi.listAllMembers`, the bounded member drain.
 *
 * Authority: lib/letflow/design/iss-0816-cursorpage-has-more-audit.md §6.1
 * (the drain's contract) and §7 rows T4, T5 and T5b.
 *
 * Why the drain exists rather than a truncation notice: `GroupsPage` derives
 * its "Add member" dropdown by subtracting the member id set from the user
 * list. Computed from one page of 50, that set difference offers every member
 * past the 50th as if they were not members — at a control a notice on the
 * member LIST says nothing about (design INV-D). T6
 * (src/pages/admin/__tests__/GroupsPage.members.test.tsx) covers that
 * consequence at the component level; this file covers the drain itself.
 *
 * Harness: mirrors src/api/__tests__/identity.groupsApi.test.ts (ISS-0765)
 * exactly — jsdom, a `window.fetch` spy ASSIGNED from `vi.fn()`, never
 * installed through a helper call, because web/tests/guards/source-scan.spec.ts
 * applies `raw-fetch-outside-client` to the whole content of every file under
 * web/src/ and permits it only in web/src/api/client.ts. No forbidlist entry
 * may be weakened and no allowedPaths exemption may be added for this file.
 * No msw, no axios-mock-adapter (DIRECTIVE T-2).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { groupsApi } from '../identity'
import { setToken, clearToken } from '../client'

const originalFetch = window.fetch

/** One `user_map/1` object (lib/letflow/routers/identity.ex:729-740). */
function member(id: string) {
  return {
    id,
    username: id,
    display_name: `User ${id}`,
    email: `${id}@example.test`,
    status: 'active',
    auth_source: 'internal',
    inserted_at: '2026-09-01T00:00:00Z',
    updated_at: '2026-09-02T00:00:00Z',
  }
}

/** The exact `Letflow.Api.Pagination.Page` envelope — `@derive {Jason.Encoder,
 *  only: [:items, :next_cursor, :count]}` (lib/letflow/api/pagination.ex:81).
 *  Three keys, and no fabricated fourth: no route in Letflow ever sent one. */
function page(ids: string[], nextCursor: string | null) {
  const items = ids.map(member)
  return { items, next_cursor: nextCursor, count: items.length }
}

function jsonResponse(body: unknown) {
  return Promise.resolve(
    new Response(JSON.stringify(body), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }),
  )
}

/** Assigns a `window.fetch` double driven by `respond(callIndex, url)`, and
 *  returns the spy. Assignment, never a call to the real thing. */
function installSpy(respond: (callIndex: number, url: string) => unknown) {
  let callIndex = 0
  const spy = vi.fn().mockImplementation((url: string) => {
    const body = respond(callIndex, url)
    callIndex += 1
    return jsonResponse(body)
  })
  window.fetch = spy as unknown as typeof window.fetch
  return spy
}

function requestedUrls(spy: ReturnType<typeof vi.fn>): string[] {
  return spy.mock.calls.map((call) => (call as [string, RequestInit | undefined])[0])
}

beforeEach(() => {
  setToken('test-token')
})

afterEach(() => {
  window.fetch = originalFetch
  clearToken()
  vi.restoreAllMocks()
})

describe('ISS-0816 AC3 — groupsApi.listAllMembers drains the member cursor', () => {
  // ── T4 ───────────────────────────────────────────────────────────────────
  it('T4: concatenates across pages in request order and forwards next_cursor as the next cursor', async () => {
    const spy = installSpy((callIndex) =>
      callIndex === 0 ? page(['m1'], 'c2') : page(['m2'], null),
    )

    const result = await groupsApi.listAllMembers('g-1')

    expect(result).toEqual({
      items: [member('m1'), member('m2')],
      truncated: false,
    })

    const urls = requestedUrls(spy)
    expect(urls).toHaveLength(2)
    // Page one carries no cursor: `client.get` drops undefined params.
    expect(urls[0]).toContain('/api/v1/identity/groups/g-1/members')
    expect(urls[0]).not.toContain('cursor=')
    expect(urls[0]).toContain('page_size=200')
    // Page two carries page one's next_cursor.
    expect(urls[1]).toContain('cursor=c2')
    expect(urls[1]).toContain('page_size=200')
    // ISS-0765's prefix invariant holds for the drain too.
    expect(urls.every((url) => !url.includes('/api/v1/admin/'))).toBe(true)
  })

  it('T4b: a single page that ends immediately issues exactly one request', async () => {
    const spy = installSpy(() => page(['m1'], null))

    const result = await groupsApi.listAllMembers('g-1')

    expect(result).toEqual({ items: [member('m1')], truncated: false })
    expect(spy).toHaveBeenCalledTimes(1)
  })

  // ── T5 ───────────────────────────────────────────────────────────────────
  it('T5: the 20-request cap holds and reports itself as truncated', async () => {
    // Every response advertises more. Without the cap this would not terminate.
    const spy = installSpy((callIndex) => page([`m${callIndex}`], `c${callIndex + 1}`))

    const result = await groupsApi.listAllMembers('g-1')

    expect(spy).toHaveBeenCalledTimes(20)
    expect(result.truncated).toBe(true)
    expect(result.items).toHaveLength(20)
  })

  // ── T5b ──────────────────────────────────────────────────────────────────
  it('T5b: reaching the cap is not by itself truncation — a 20th response with a null cursor is complete', async () => {
    // Responses 1..19 advertise more; the 20th terminates the drain normally on
    // its last permitted request. §6.1: `truncated` reports whether members were
    // left UNFETCHED, not whether the cap was reached.
    const spy = installSpy((callIndex) =>
      callIndex === 19 ? page([`m${callIndex}`], null) : page([`m${callIndex}`], `c${callIndex + 1}`),
    )

    const result = await groupsApi.listAllMembers('g-1')

    expect(spy).toHaveBeenCalledTimes(20)
    expect(result.truncated).toBe(false)
    expect(result.items).toHaveLength(20)
  })

  it('T5c: a 21st request is never issued', async () => {
    const spy = installSpy((callIndex) => page([`m${callIndex}`], `c${callIndex + 1}`))

    await groupsApi.listAllMembers('g-1')

    expect(spy.mock.calls.length).toBeLessThanOrEqual(20)
  })

  // ── Error propagation (§6.1's last bullet) ───────────────────────────────
  it('rejects on the first failed request, leaving useQuery error handling unchanged', async () => {
    const spy = vi.fn().mockImplementation((url: string) => {
      if (String(url).includes('cursor=c2')) {
        return Promise.resolve(
          new Response(JSON.stringify({ message: 'boom', code: 'internal_error' }), {
            status: 500,
            headers: { 'Content-Type': 'application/json' },
          }),
        )
      }
      return jsonResponse(page(['m1'], 'c2'))
    })
    window.fetch = spy as unknown as typeof window.fetch

    await expect(groupsApi.listAllMembers('g-1')).rejects.toBeTruthy()
    expect(spy).toHaveBeenCalledTimes(2)
  })
})
