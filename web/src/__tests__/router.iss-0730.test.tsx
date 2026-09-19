// @vitest-environment jsdom
/**
 * Regression test — ISS-0730: no reachable GUI route rendered the
 * promotion-review screens (PromotionReviewStateMachine +
 * NonSkippableApprovalGate). Components existed but were never wired into
 * router.tsx.
 *
 * TC-ISS0730-01: router.routes maps definitions/:id/promotions/:reviewId to
 *   PromotionReviewPage, and the parent definitions/:id path is untouched
 *   (still DefinitionEditorPage).
 * TC-ISS0730-02: navigating to the review URL as a non-PLATFORM_ADMIN user
 *   redirects to /instances (client-side role gate), matching the pattern
 *   used by AuditLogPage/HealthDashboardPage/MetricsPage -- per
 *   lib/letflow/design/iss0730-promotion-review-page-routing.md §3.1.
 */

import type { ReactElement } from 'react'
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { MemoryRouter, Routes, Route, matchRoutes } from 'react-router-dom'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(() => ({ data: undefined, isLoading: false, isError: false, error: null, refetch: vi.fn() })),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), mutateAsync: vi.fn(), isPending: false, isError: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

import { useAuth } from '@/auth/AuthContext'
import { router } from '@/router'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'
import PromotionReviewPage from '@/pages/definitions/PromotionReviewPage'

const mockUseAuth = vi.mocked(useAuth)

// ── Fixtures ──────────────────────────────────────────────────────────────────

const NON_ADMIN_SESSION = {
  token: 'tok',
  display_name: 'Regular User',
  roles: ['TASK_WORKER'],
  loginSource: null as null,
  tenant_slug: 'demo-co',
  tenant_display_name: 'Demo Co',
  tenant_id: 'tid-demo-co',
  tenant_type: 'production' as const,
  production_tenant_display_name: null,
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function rootChildren() {
  const root = router.routes.find((r) => r.path === '/')
  if (!root?.children) throw new Error('root route with children not found in router.routes')
  return root.children
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('ISS-0730 regression — promotion review route wiring', () => {
  it('TC-ISS0730-01: definitions/:id/promotions/:reviewId routes to PromotionReviewPage; parent definitions/:id still routes to DefinitionEditorPage', () => {
    const children = rootChildren()

    const parentRoute = children.find((c) => c.path === 'definitions/:id')
    expect(parentRoute).toBeDefined()
    expect((parentRoute!.element as ReactElement).type).toBe(DefinitionEditorPage)

    const reviewRoute = children.find((c) => c.path === 'definitions/:id/promotions/:reviewId')
    expect(reviewRoute).toBeDefined()
    expect((reviewRoute!.element as ReactElement).type).toBe(PromotionReviewPage)
    expect((reviewRoute!.element as ReactElement).type).not.toBe(DefinitionEditorPage)
  })

  it('TC-ISS0730-02: navigating to a review URL as a non-PLATFORM_ADMIN user redirects to /instances', () => {
    mockUseAuth.mockReturnValue({
      session: NON_ADMIN_SESSION,
      isAuthenticated: true,
      isLoading: false,
      loginSource: null,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    })

    const targetUrl = '/definitions/def-1/promotions/review-42'
    const matches = matchRoutes(router.routes, targetUrl)
    expect(matches).not.toBeNull()
    const leaf = matches![matches!.length - 1]

    render(
      <MemoryRouter initialEntries={[targetUrl]}>
        <Routes>
          <Route path={leaf.route.path} element={leaf.route.element as ReactElement} />
          <Route path="/instances" element={<div data-testid="instances-redirect-target" />} />
        </Routes>
      </MemoryRouter>,
    )

    expect(screen.getByTestId('instances-redirect-target')).toBeInTheDocument()
    expect(screen.queryByTestId('non-skippable-approval-gate')).not.toBeInTheDocument()
  })
})
