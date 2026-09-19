// @vitest-environment jsdom
/**
 * ISS-0728 — PermissionDenied's recovery link becomes role-aware for
 * CANDIDATE sessions (lib/letflow/design/iss0728-candidate-exam-nav.md §3,
 * §5.2). This file focuses only on the CANDIDATE-specific branch;
 * web/tests/unit/PermissionDenied.test.tsx already covers the fixed-copy /
 * no-leak assertions (TC-PD-01..05) for the pre-existing, non-CANDIDATE
 * (session: null) path -- not duplicated here.
 *
 * Cases:
 *   1. CANDIDATE session renders "Go to Exams" linking to /exam.
 *   2. Non-CANDIDATE session (TASK_WORKER) still renders "My Tasks" -> /tasks.
 *   3. No-session (session: null) falls back to "My Tasks" -> /tasks without
 *      throwing.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

async function renderPermissionDeniedWithSession(session: { roles: string[] } | null) {
  vi.resetModules()

  const { useAuth } = await import('@/auth/AuthContext')
  vi.mocked(useAuth).mockReturnValue({
    session,
    isAuthenticated: session != null,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
  } as ReturnType<typeof useAuth>)

  const { PermissionDenied } = await import('../PermissionDenied')

  render(
    <MemoryRouter>
      <PermissionDenied />
    </MemoryRouter>,
  )
}

describe('ISS-0728 — PermissionDenied role-aware recovery link', () => {
  it('CANDIDATE session renders "Go to Exams" linking to /exam', async () => {
    await renderPermissionDeniedWithSession({ roles: ['CANDIDATE'] })
    expect(screen.getByRole('link', { name: 'Go to Exams' })).toHaveAttribute('href', '/exam')
    expect(screen.queryByRole('link', { name: 'My Tasks' })).not.toBeInTheDocument()
  })

  it('non-CANDIDATE session (TASK_WORKER) still renders "My Tasks" linking to /tasks', async () => {
    await renderPermissionDeniedWithSession({ roles: ['TASK_WORKER'] })
    expect(screen.getByRole('link', { name: 'My Tasks' })).toHaveAttribute('href', '/tasks')
    expect(screen.queryByRole('link', { name: 'Go to Exams' })).not.toBeInTheDocument()
  })

  it('no-session (session: null) falls back to "My Tasks" linking to /tasks without throwing', async () => {
    await renderPermissionDeniedWithSession(null)
    expect(screen.getByRole('link', { name: 'My Tasks' })).toHaveAttribute('href', '/tasks')
  })
})
