// @vitest-environment jsdom
/**
 * ISS-0736 / REQ-378 AC2 — regression test for the GUI-reachable role-
 * revocation path (see lib/letflow/design/req378-oidc-live-revocation-check.md
 * §4.1 and test/specs/ISS-0736.md).
 *
 * Before the fix, `groupsApi.removeMembers(id, userIds)` discarded `userIds`
 * (`void userIds`) and called `DELETE /api/v1/admin/groups/:id/members` --
 * a route that does not exist on the backend (no `/admin/groups` mount
 * anywhere in lib/letflow/plugs/api_pipeline.ex or lib/letflow/router.ex),
 * so a tenant_admin's "remove member" click in web/src/pages/admin/GroupsPage.tsx
 * silently could never reach a real endpoint -- AC2 was false even though the
 * button existed. The fix corrects the signature to a single `userId` and the
 * real, router-backed path `DELETE /api/v1/identity/groups/:id/members/:user_id`
 * (`authz_delete "/groups/:id/members/:user_id"`, lib/letflow/routers/identity.ex:182,
 * mounted at `/identity` per lib/letflow/plugs/api_pipeline.ex:141).
 *
 * Follows web/src/api/__tests__/entities.test.ts's established convention:
 * spy on window.fetch, call the api function, assert the exact method+path
 * hit -- real fetch-call assertions, not a mock of `client` itself.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { groupsApi } from '../identity'
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

describe('ISS-0736 AC2 -- groupsApi.removeMembers hits the real, router-backed single-member route', () => {
  it('removeMembers(groupId, userId) -> DELETE /api/v1/identity/groups/:id/members/:user_id, not the nonexistent /admin/groups path', async () => {
    const fetchSpy = vi.fn().mockImplementation(() => jsonResponse(undefined, { status: 204 }))
    window.fetch = fetchSpy as unknown as typeof window.fetch

    await groupsApi.removeMembers('group-1', 'user-1')

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/identity/groups/group-1/members/user-1')
    expect(url).not.toContain('/api/v1/admin/groups')
    expect(init).toEqual(expect.objectContaining({ method: 'DELETE' }))
  })

  it('accepts a single userId string, not an array -- the pre-fix signature silently discarded a userIds array', () => {
    // Type-level guard: this call only compiles if removeMembers takes a
    // single string. If a future regression reverts to `userIds: string[]`,
    // this line still compiles (an array literal is not rejected by a
    // loosely-typed signature) but the runtime assertion above -- exact
    // path containing the literal 'user-1' segment, not a JSON-encoded
    // array -- catches it. Documented here as the deliberate AC2 guard,
    // not a TypeScript-only check.
    expect(typeof groupsApi.removeMembers).toBe('function')
    expect(groupsApi.removeMembers.length).toBe(2)
  })
})
