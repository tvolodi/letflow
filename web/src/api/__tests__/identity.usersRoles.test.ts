// @vitest-environment jsdom
/**
 * ISS-0782 -- regression test for the Users admin screen's real call sites
 * (see docs/issues/ISS-0782.yaml, lib/letflow/design/iss0782-identity-api-route-fix.md,
 * test/specs/ISS-0782.md).
 *
 * Before the fix, `usersApi.list/get/create/update` hit `/api/v1/users*` /
 * `/api/v1/admin/users` and `rolesApi.list` hit `/api/v1/admin/roles` --
 * none of these were ever mounted anywhere in
 * lib/letflow/plugs/api_pipeline.ex (only `/identity` is forwarded to
 * Letflow.Routers.Identity). Every call from the Users admin screen
 * (UsersPage.tsx / UserDetailPage.tsx) therefore 404'd against any real
 * backend, for every tenant. The fix corrects the five call sites to the
 * real, router-backed `/api/v1/identity/users` and `/api/v1/identity/roles`
 * paths (lib/letflow/routers/identity.ex's `authz_get/post/patch "/users"`
 * and `authz_get "/roles"`, mounted at `/identity` per
 * lib/letflow/plugs/api_pipeline.ex:141).
 *
 * Follows web/src/api/__tests__/identity.removeMembers.test.ts's established
 * convention: spy on window.fetch, call the api function, assert the exact
 * method+path hit -- real fetch-call assertions, not a mock of `client`
 * itself. This is the FAST, mocked-level complement to the live e2e proof in
 * web/tests/e2e/f5-admin-users.e2e.spec.ts (ADM-UI-01..04) -- the mocked
 * unit tests alone do NOT satisfy WF-03 Step 4's live-e2e requirement (per
 * ISS-0782's own suggested_fix, this exact gap -- mocked-only coverage -- is
 * why the bug shipped undetected), but they do give a sub-second guard
 * against any future regression reintroducing a wrong path literal.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { usersApi, rolesApi } from '../identity'
import { setToken, clearToken } from '../client'

const originalFetch = window.fetch

function jsonResponse(body: unknown, init: { status?: number; headers?: Record<string, string> } = {}) {
  return Promise.resolve(
    new Response(body === undefined ? null : JSON.stringify(body), {
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

describe('ISS-0782 -- Users admin screen call sites hit the real, router-backed /api/v1/identity/* routes', () => {
  it('usersApi.list -> GET /api/v1/identity/users, not the nonexistent /api/v1/users', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ items: [], total: 0 }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await usersApi.list({ search: 'foo' })

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const [url] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/identity/users')
    expect(url).not.toMatch(/\/api\/v1\/users(\?|$)/)
  })

  it('usersApi.get -> GET /api/v1/identity/users/:id, not the nonexistent /api/v1/users/:id', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ id: 'u-1' }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await usersApi.get('u-1')

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const [url] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/identity/users/u-1')
    expect(url).not.toContain('/api/v1/users/u-1')
  })

  it('usersApi.create -> POST /api/v1/identity/users, not the nonexistent /api/v1/admin/users', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ id: 'u-2' }, { status: 201 }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await usersApi.create({ username: 'u', email: 'u@example.com', display_name: 'U', password: 'pw' })

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/identity/users')
    expect(url).not.toContain('/api/v1/admin/users')
    expect(init).toEqual(expect.objectContaining({ method: 'POST' }))
  })

  it('usersApi.update -> PATCH /api/v1/identity/users/:id, not the nonexistent /api/v1/users/:id (shared by update + deactivate flows)', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ id: 'u-3' }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await usersApi.update('u-3', { status: 'inactive', is_active: false })

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/identity/users/u-3')
    expect(url).not.toContain('/api/v1/users/u-3')
    expect(init).toEqual(expect.objectContaining({ method: 'PATCH' }))
  })

  it('rolesApi.list -> GET /api/v1/identity/roles, not the nonexistent /api/v1/admin/roles', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ items: [], total: 0 }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await rolesApi.list()

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const [url] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/identity/roles')
    expect(url).not.toContain('/api/v1/admin/roles')
  })
})
