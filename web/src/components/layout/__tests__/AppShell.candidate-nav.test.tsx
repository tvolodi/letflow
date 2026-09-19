// @vitest-environment jsdom
/**
 * ISS-0728 — CANDIDATE has no in-app navigation path to /exam.
 *
 * Mirrors AppShell.bilimbaga.test.tsx's sessionWithRoles/renderAppShellAs
 * fixture and mocking shape verbatim (file-local, self-sufficient per
 * TEST-DESIGN-VALIDATOR's "self-sufficient fixtures" check) --
 * lib/letflow/design/iss0728-candidate-exam-nav.md §5.1.
 *
 * Cases:
 *   1. CANDIDATE sees the "Exams" nav entry, linking to /exam.
 *   2. CANDIDATE does NOT see any other nav entry.
 *   3. No-regression: the other four roles (PLATFORM_ADMIN, PROCESS_DESIGNER,
 *      PROCESS_OPERATOR, TASK_WORKER) do NOT see "Exams", while each still
 *      sees its own already-established nav entry.
 */
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

async function renderAppShellAs(roles: string[]) {
  vi.resetModules()

  const { useAuth } = await import('@/auth/AuthContext')
  vi.mocked(useAuth).mockReturnValue({
    session: sessionWithRoles(roles),
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
  })

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

describe('ISS-0728 — CANDIDATE Exams nav entry', () => {
  it('CANDIDATE sees the "Exams" nav entry, linking to /exam', async () => {
    await renderAppShellAs(['CANDIDATE'])
    await waitFor(() => expect(screen.getByText('Exams')).toBeInTheDocument())
    expect(screen.getByRole('link', { name: 'Exams' })).toHaveAttribute('href', '/exam')
  })

  it('CANDIDATE does NOT see any other nav entry', async () => {
    await renderAppShellAs(['CANDIDATE'])
    await waitFor(() => expect(screen.getByText('Exams')).toBeInTheDocument())
    expect(screen.queryByText('Instances')).not.toBeInTheDocument()
    expect(screen.queryByText('My Tasks')).not.toBeInTheDocument()
    expect(screen.queryByText('Definitions')).not.toBeInTheDocument()
    expect(screen.queryByText('DLQ')).not.toBeInTheDocument()
    expect(screen.queryByText('Webhooks')).not.toBeInTheDocument()
    expect(screen.queryByText('Users')).not.toBeInTheDocument()
    expect(screen.queryByText('Question Bank')).not.toBeInTheDocument()
  })

  it('PLATFORM_ADMIN does NOT see "Exams"', async () => {
    await renderAppShellAs(['PLATFORM_ADMIN'])
    await waitFor(() => expect(screen.getByText('Question Bank')).toBeInTheDocument())
    expect(screen.queryByText('Exams')).not.toBeInTheDocument()
  })

  it('PROCESS_DESIGNER does NOT see "Exams"', async () => {
    await renderAppShellAs(['PROCESS_DESIGNER'])
    await waitFor(() => expect(screen.getByText('Definitions')).toBeInTheDocument())
    expect(screen.queryByText('Exams')).not.toBeInTheDocument()
  })

  it('PROCESS_OPERATOR does NOT see "Exams"', async () => {
    await renderAppShellAs(['PROCESS_OPERATOR'])
    await waitFor(() => expect(screen.getByText('Question Bank')).toBeInTheDocument())
    expect(screen.queryByText('Exams')).not.toBeInTheDocument()
  })

  it('TASK_WORKER does NOT see "Exams"', async () => {
    await renderAppShellAs(['TASK_WORKER'])
    await waitFor(() => expect(screen.getByText('My Tasks')).toBeInTheDocument())
    expect(screen.queryByText('Exams')).not.toBeInTheDocument()
  })
})
