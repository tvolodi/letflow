// @vitest-environment jsdom
/**
 * gui-review-2026-09-20-tenant-switch-cache-isolation (EO-002 — "signing out
 * leaves nothing behind"): AuthProvider.logout() must clear the same-tab
 * tenant-selection residue (bpm_realm_slug in sessionStorage) a previous
 * session's `?realm=` load may have written, so the next person to sign in
 * on this browser tab resolves tenant-config fresh rather than inheriting
 * the departing user's company. See web/src/auth/tenantConfig.ts's
 * resetTenantConfigCache moduledoc and docs/issues (filed alongside this fix)
 * for the full defect trace.
 *
 * TC-EO002-03: logout() removes bpm_realm_slug from sessionStorage.
 * TC-EO002-04: logout() still clears the in-memory token/session and
 *   triggers signoutRedirect — this fix must not regress the existing path.
 */

import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, act } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

const { mockClearToken, mockSignoutRedirect } = vi.hoisted(() => ({
  mockClearToken: vi.fn(),
  mockSignoutRedirect: vi.fn(),
}))

vi.mock('@/api/client', () => ({
  clearToken: mockClearToken,
  setToken: vi.fn(),
  tryRestoreE2eSession: vi.fn(() => null),
}))

vi.mock('../OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({
    signoutRedirect: mockSignoutRedirect,
    events: { addAccessTokenExpiring: vi.fn(), removeAccessTokenExpiring: vi.fn() },
    startSilentRenew: vi.fn(),
  })),
}))

import { AuthProvider } from '../AuthProvider'
import { AuthContext } from '../AuthContext'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  sessionStorage.clear()
})

describe('AuthProvider.logout — EO-002 realm residue', () => {
  it('TC-EO002-03: clears bpm_realm_slug from sessionStorage on logout', async () => {
    sessionStorage.setItem('bpm_realm_slug', 'swiftroute')

    let captured: { logout: () => void } | null | undefined = null

    function Capture() {
      return (
        <AuthContext.Consumer>
          {(value) => {
            captured = value
            return null
          }}
        </AuthContext.Consumer>
      )
    }

    render(
      <AuthProvider>
        <Capture />
      </AuthProvider>,
    )

    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('swiftroute')

    await act(async () => {
      captured!.logout()
    })

    expect(sessionStorage.getItem('bpm_realm_slug')).toBeNull()
  })

  it('TC-EO002-04: logout still clears the token and triggers signoutRedirect (no regression)', async () => {
    let captured: { logout: () => void } | null | undefined = null

    function Capture() {
      return (
        <AuthContext.Consumer>
          {(value) => {
            captured = value
            return null
          }}
        </AuthContext.Consumer>
      )
    }

    render(
      <AuthProvider>
        <Capture />
      </AuthProvider>,
    )

    await act(async () => {
      captured!.logout()
      // flush the getOidcManager().then(...) microtask
      await Promise.resolve()
    })

    expect(mockClearToken).toHaveBeenCalled()
    expect(mockSignoutRedirect).toHaveBeenCalled()
  })
})
