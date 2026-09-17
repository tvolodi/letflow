// @vitest-environment jsdom
/**
 * Router-level test — REQ-369 AC4: web/src/router.tsx gains a new
 * `platform-dashboard` route alongside the existing `{ index: true }` and
 * `{ path: 'dashboard' }` TenantDashboardPage entries, which stay unchanged.
 *
 * The mechanical "diff shows only an addition" check is performed directly
 * by REVIEWER against `git diff` (see step-02d-reviewer.json,
 * `router_tsx_addition_only`) per the design doc §2's own note that this
 * does not require a new test. This test instead asserts the resulting
 * *route table* is correct — the actual thing AC4 cares about — following
 * router.iss-0289.test.tsx's established `router.routes` idiom.
 *
 * TC-REQ369-07: `platform-dashboard` maps to PlatformDashboardPage, and the
 *   pre-existing `index`/`dashboard` entries still map to TenantDashboardPage.
 */

import type { ReactElement } from 'react'
import { describe, it, expect, vi } from 'vitest'

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(() => ({ data: undefined, isLoading: false, isError: false, error: null, refetch: vi.fn() })),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), isPending: false, isError: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

import { router } from '@/router'
import TenantDashboardPage from '@/pages/dashboard/TenantDashboardPage'
import PlatformDashboardPage from '@/pages/dashboard/PlatformDashboardPage'

function rootChildren() {
  const root = router.routes.find((r) => r.path === '/')
  if (!root?.children) throw new Error('root route with children not found in router.routes')
  return root.children
}

describe('REQ-369 AC4 — router.tsx platform-dashboard route wiring', () => {
  it('TC-REQ369-07: platform-dashboard maps to PlatformDashboardPage; index/dashboard entries remain TenantDashboardPage', () => {
    const children = rootChildren()

    const indexRoute = children.find((c) => c.index === true)
    expect(indexRoute).toBeDefined()
    expect((indexRoute!.element as ReactElement).type).toBe(TenantDashboardPage)

    const dashboardRoute = children.find((c) => c.path === 'dashboard')
    expect(dashboardRoute).toBeDefined()
    expect((dashboardRoute!.element as ReactElement).type).toBe(TenantDashboardPage)

    const platformRoute = children.find((c) => c.path === 'platform-dashboard')
    expect(platformRoute).toBeDefined()
    expect((platformRoute!.element as ReactElement).type).toBe(PlatformDashboardPage)
    expect((platformRoute!.element as ReactElement).type).not.toBe(TenantDashboardPage)
  })
})
