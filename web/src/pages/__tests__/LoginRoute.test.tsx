// @vitest-environment jsdom
/** REQ-438 -- /login honours VITE_EMAIL_FIRST_LOGIN: off redirects to `/`. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AuthContext } from '@/auth/AuthContext'
import type { AuthContextValue } from '@/auth/AuthContext'
expect.extend(jestDomMatchers)

const { mockLookup, mockSigninRedirect, mockGetManager } = vi.hoisted(() => {
  const signin = vi.fn()
  return {
    mockLookup: vi.fn(),
    mockSigninRedirect: signin,
    mockGetManager: vi.fn(async () => ({ signinRedirect: signin })),
  }
})
vi.mock('@/api/loginDiscovery', () => ({ loginDiscoveryApi: { lookup: mockLookup } }))
vi.mock('@/auth/tenantOidcRegistry', () => ({ getOrCreateManagerForTenant: mockGetManager }))

import { LoginRoute } from '../LoginPage'

const auth: AuthContextValue = {
  session: null,
  isAuthenticated: false,
  isLoading: false,
  loginSource: null,
  login: vi.fn(),
  logout: vi.fn(),
  setSession: vi.fn(),
  switchTenant: vi.fn(),
  switchingToTenantSlug: null,
}

function renderAt() {
  return render(
    <AuthContext.Provider value={auth}>
      <MemoryRouter initialEntries={['/login']}>
        <Routes>
          <Route path="/login" element={<LoginRoute />} />
          <Route path="/" element={<div data-testid="home" />} />
        </Routes>
      </MemoryRouter>
    </AuthContext.Provider>,
  )
}

afterEach(() => {
  cleanup()
  vi.unstubAllEnvs()
  mockLookup.mockReset()
  mockSigninRedirect.mockReset()
  mockGetManager.mockClear()
})

describe('LoginRoute flag gate', () => {
  it('flag off: /login redirects to / with no page, no discovery call, no signinRedirect', () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', '')
    renderAt()
    expect(screen.getByTestId('home')).toBeInTheDocument()
    expect(screen.queryByLabelText('Email address')).toBeNull()
    expect(screen.queryByTestId('login-submit')).toBeNull()
    expect(mockLookup).not.toHaveBeenCalled()
    expect(mockGetManager).not.toHaveBeenCalled()
    expect(mockSigninRedirect).not.toHaveBeenCalled()
  })

  it('flag on: the discovery page renders', () => {
    vi.stubEnv('VITE_EMAIL_FIRST_LOGIN', 'true')
    renderAt()
    expect(screen.getByLabelText('Email address')).toBeInTheDocument()
    expect(screen.queryByTestId('home')).toBeNull()
  })
})
