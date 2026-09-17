// @vitest-environment jsdom
/**
 * Unit tests — REQ-369: PlatformDashboardPage, the platform-wide landing page
 * for PLATFORM_ADMIN that replaces the tenant-branded TenantDashboardPage for
 * that role. See lib/letflow/design/req369-platform-dashboard-page.md §1,
 * §6 (AC1-AC3 mapping) and docs/requirements.yaml's REQ-369 acceptance_criteria.
 *
 * TC-REQ369-01/02: AC1 — fixed "Platform Overview" heading, never any
 *   tenant-branded copy (tenantDisplayName / "your workspace" /
 *   "Tenant name could not be loaded" / "Unknown workspace"), and the
 *   component never calls useTenantContext() (static import-scan, since the
 *   module itself is never imported by this file — see below).
 * TC-REQ369-03: AC2 — tenant-count tile renders the mocked
 *   tenantsApi.list()/useQuery `total`.
 * TC-REQ369-04: AC3 — a non-PLATFORM_ADMIN session is redirected to
 *   /instances instead of seeing platform content (mirrors
 *   HealthDashboardPage.test.tsx's TC-ISS0532-11 idiom exactly).
 */

import type { ReactNode } from 'react'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/api/tenants', () => ({
  tenantsApi: {
    list: vi.fn(),
  },
}))

vi.mock('@/api/queryKeys', () => ({
  queryKeys: {
    admin: {
      tenants: vi.fn((filters: Record<string, unknown>) => ['admin', 'tenants', filters]),
    },
  },
}))

vi.mock('react-router-dom', () => ({
  Navigate: ({ to }: { to: string }) => <div data-testid="navigate" data-to={to} />,
  Link: ({ to, children }: { to: string; children: ReactNode }) => <a href={to}>{children}</a>,
}))

import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import PlatformDashboardPage from '@/pages/dashboard/PlatformDashboardPage'
import type { TenantListResponse } from '@/api/tenants'

const mockUseQuery = vi.mocked(useQuery)
const mockUseAuth = vi.mocked(useAuth)

const PLATFORM_ADMIN_SESSION = {
  token: 'tok',
  display_name: 'Admin',
  roles: ['PLATFORM_ADMIN'],
  loginSource: null as null,
  tenant_slug: null,
  tenant_display_name: null,
  tenant_id: null,
  tenant_type: null,
  production_tenant_display_name: null,
}

const NON_ADMIN_SESSION = { ...PLATFORM_ADMIN_SESSION, roles: ['PROCESS_OPERATOR'] }

const TENANT_LIST: TenantListResponse = {
  items: [],
  total: 37,
  limit: 20,
  offset: 0,
}

function queryResult(overrides: Record<string, unknown>) {
  return {
    data: undefined,
    isLoading: false,
    isFetching: false,
    isError: false,
    error: null,
    dataUpdatedAt: 1,
    refetch: vi.fn(),
    ...overrides,
  }
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-369 — PlatformDashboardPage', () => {
  it('TC-REQ369-01: renders the fixed "Platform Overview" heading and never any tenant-branded copy', () => {
    mockUseAuth.mockReturnValue({ session: PLATFORM_ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    mockUseQuery.mockReturnValue(queryResult({ data: TENANT_LIST }) as unknown as ReturnType<typeof useQuery>)

    render(<PlatformDashboardPage />)

    // VERDICT: fixed literal heading, present verbatim.
    expect(screen.getByTestId('platform-dashboard-heading')).toHaveTextContent('Platform Overview')

    // VERDICT (AC1's literal absence-check): no tenant-branded string appears
    // anywhere in the rendered output.
    const rendered = document.body.textContent ?? ''
    expect(rendered).not.toMatch(/your workspace/i)
    expect(rendered).not.toMatch(/Tenant name could not be loaded/i)
    expect(rendered).not.toMatch(/Unknown workspace/i)
  })

  it('TC-REQ369-02: the module never imports or calls useTenantContext() (static source scan)', async () => {
    // AC1's constraint is literally about the import graph, not just render
    // output — assert directly against the module's own source text, which
    // is the checkable form the design doc (§1.2) calls for.
    const fs = await import('node:fs')
    const path = await import('node:path')
    const src = fs.readFileSync(
      path.resolve(__dirname, '../PlatformDashboardPage.tsx'),
      'utf-8',
    )
    expect(src).not.toMatch(/useTenantContext/)
  })

  it('TC-REQ369-03: tenant-count tile renders the count sourced from tenantsApi.list()\'s mocked total', () => {
    mockUseAuth.mockReturnValue({ session: PLATFORM_ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    mockUseQuery.mockReturnValue(queryResult({ data: TENANT_LIST }) as unknown as ReturnType<typeof useQuery>)

    render(<PlatformDashboardPage />)

    expect(screen.getByTestId('tile-tenant-count')).toHaveTextContent('37')
  })

  it('TC-REQ369-04: a non-PLATFORM_ADMIN session is redirected to /instances instead of seeing platform content', () => {
    mockUseAuth.mockReturnValue({ session: NON_ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    mockUseQuery.mockReturnValue(queryResult({ data: TENANT_LIST }) as unknown as ReturnType<typeof useQuery>)

    render(<PlatformDashboardPage />)

    expect(screen.getByTestId('navigate')).toHaveAttribute('data-to', '/instances')
    expect(screen.queryByTestId('platform-dashboard-heading')).not.toBeInTheDocument()
    expect(screen.queryByTestId('tile-tenant-count')).not.toBeInTheDocument()
    expect(screen.queryByTestId('platform-quick-links')).not.toBeInTheDocument()
  })
})
