// @vitest-environment jsdom
/**
 * Unit tests — ISS-0532: HealthDashboardPage must not fabricate per-subsystem
 * readiness data from the non-existent GET /health/ready endpoint. It must
 * degrade to an honest liveness-only view: real backend liveness (from
 * GET /health, via healthReady()) plus a plain statement that per-subsystem
 * readiness (database/scheduler) is not available yet (pending S6).
 */

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

vi.mock('@/api/queryKeys', () => ({
  queryKeys: {
    admin: {
      health: vi.fn(() => ['admin', 'health']),
    },
  },
}))

vi.mock('react-router-dom', () => ({
  Navigate: ({ to }: { to: string }) => <div data-testid="navigate" data-to={to} />,
}))

import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import HealthDashboardPage from '@/pages/admin/HealthDashboardPage'

const mockUseQuery = vi.mocked(useQuery)
const mockUseAuth = vi.mocked(useAuth)

const PLATFORM_ADMIN_SESSION = {
  token: 'tok',
  display_name: 'Admin',
  roles: ['PLATFORM_ADMIN'],
  loginSource: null,
  tenant_slug: 'platform',
  tenant_display_name: 'Platform',
  tenant_id: 'tid-platform',
  tenant_type: 'production' as const,
  production_tenant_display_name: null,
}

const NON_ADMIN_SESSION = { ...PLATFORM_ADMIN_SESSION, roles: ['TASK_WORKER'] }

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

describe('HealthDashboardPage', () => {
  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
  })

  it('TC-ISS0532-11: redirects non-PLATFORM_ADMIN users away, without calling the health query', () => {
    mockUseAuth.mockReturnValue({ session: NON_ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    mockUseQuery.mockReturnValue(queryResult({ data: true }) as unknown as ReturnType<typeof useQuery>)

    render(<HealthDashboardPage />)

    expect(screen.getByTestId('navigate')).toHaveAttribute('data-to', '/instances')
  })

  it('TC-ISS0532-12: never renders fabricated per-subsystem database/scheduler status', () => {
    mockUseAuth.mockReturnValue({ session: PLATFORM_ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    mockUseQuery.mockReturnValue(queryResult({ data: true }) as unknown as ReturnType<typeof useQuery>)

    render(<HealthDashboardPage />)

    expect(screen.queryByText(/^database$/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/^scheduler$/i)).not.toBeInTheDocument()
  })

  it('TC-ISS0532-13: honestly states readiness is not available yet, instead of showing fake data', () => {
    mockUseAuth.mockReturnValue({ session: PLATFORM_ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    mockUseQuery.mockReturnValue(queryResult({ data: true }) as unknown as ReturnType<typeof useQuery>)

    render(<HealthDashboardPage />)

    expect(screen.getByTestId('readiness-not-available')).toBeInTheDocument()
    expect(screen.getByTestId('readiness-not-available')).toHaveTextContent(/not available yet/i)
  })

  it('TC-ISS0532-14: shows LIVE when the real liveness check (GET /health) succeeds', () => {
    mockUseAuth.mockReturnValue({ session: PLATFORM_ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    mockUseQuery.mockReturnValue(queryResult({ data: true }) as unknown as ReturnType<typeof useQuery>)

    render(<HealthDashboardPage />)

    expect(screen.getByTestId('liveness-badge')).toHaveTextContent('LIVE')
  })

  it('TC-ISS0532-15: shows UNREACHABLE when the real liveness check fails, without crashing', () => {
    mockUseAuth.mockReturnValue({ session: PLATFORM_ADMIN_SESSION } as unknown as ReturnType<typeof useAuth>)
    mockUseQuery.mockReturnValue(queryResult({ data: false }) as unknown as ReturnType<typeof useQuery>)

    render(<HealthDashboardPage />)

    expect(screen.getByTestId('liveness-badge')).toHaveTextContent('UNREACHABLE')
    expect(screen.getByTestId('readiness-not-available')).toBeInTheDocument()
  })
})
