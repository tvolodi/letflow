// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import type { UserSession } from '@/types/api'

expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(() => ({ data: undefined })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/hooks/useInstalledModules', () => ({
  useInstalledModules: vi.fn(),
}))

vi.mock('@/api/client', () => ({
  client: { get: vi.fn(() => Promise.resolve({ items: [] })) },
}))

function sessionWithRoles(roles: string[]): UserSession {
  return {
    token: 'tok',
    display_name: 'Test User',
    roles,
    loginSource: null,
    tenant_slug: 'acme',
    tenant_display_name: 'Acme Co',
    tenant_id: 'tid-acme',
    tenant_type: 'production',
    production_tenant_display_name: null,
  }
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

async function renderAppShellAs(roles: string[], installedModules: Array<{ module_id: string; version: string }> = []) {
  vi.resetModules()

  const { useAuth } = await import('@/auth/AuthContext')
  const { useInstalledModules } = await import('@/hooks/useInstalledModules')
  vi.mocked(useAuth).mockReturnValue({
    session: sessionWithRoles(roles),
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  })
  vi.mocked(useInstalledModules).mockReturnValue({
    data: installedModules,
    isLoading: false,
    error: null,
    isError: false,
    isSuccess: true,
    status: 'success',
    fetchStatus: 'idle',
    isFetched: true,
    isFetchedAfterMount: true,
    isPending: false,
    isRefetching: false,
    isLoadingError: false,
    isPlaceholderData: false,
    isRefetchError: false,
    refetch: vi.fn(),
    failureCount: 0,
    failureReason: null,
    isInitialLoading: false,
    isPaused: false,
    dataUpdatedAt: 0,
    errorUpdatedAt: 0,
    receive: vi.fn(),
    promise: Promise.resolve({ data: installedModules }),
  } as never)

  const { BrandingProvider } = await import('@/theming/BrandingProvider')
  const { AppShell } = await import('../AppShell')

  render(
    <MemoryRouter initialEntries={['/instances']}>
      <BrandingProvider>
        <AppShell />
      </BrandingProvider>
    </MemoryRouter>,
  )
}

describe('AppShell installed-module nav', () => {
  it('shows an installed module nav item for the roles it grants', async () => {
    await renderAppShellAs(['CANDIDATE'], [{ module_id: 'sample', version: '1.0.0' }])
    await waitFor(() => expect(screen.getByText('Sample')).toBeInTheDocument())
    expect(screen.getByRole('link', { name: 'Sample' })).toHaveAttribute('href', '/sample')
  })

  it('hides a module nav item when the tenant has not installed it', async () => {
    await renderAppShellAs(['CANDIDATE'], [])
    await waitFor(() => expect(screen.getByTestId('logout-button')).toBeInTheDocument())
    // With no installed modules, neither module-provided nav item appears.
    expect(screen.queryByText('Sample')).not.toBeInTheDocument()
    expect(screen.queryByText('Exams')).not.toBeInTheDocument()
  })
})
