// @vitest-environment jsdom
/**
 * Unit tests — REQ-369 AC5: OidcCallbackPage.tsx's post-login `navigate()`
 * call becomes role-conditional. PLATFORM_ADMIN lands on
 * `/platform-dashboard`; every other role's destination is unchanged (`/`).
 * See lib/letflow/design/req369-platform-dashboard-page.md §3/§3.1 (this file
 * had no pre-existing test — Open Q3 flagged this for TEST-DESIGNER to create
 * one, following this codebase's `__tests__/` colocation convention, e.g.
 * router.iss-0289.test.tsx under web/src/__tests__/).
 *
 * TC-REQ369-05: PLATFORM_ADMIN role in the decoded token payload -> navigate
 *   called with ('/platform-dashboard', { replace: true }).
 * TC-REQ369-06: a non-PLATFORM_ADMIN role (PROCESS_OPERATOR) -> navigate
 *   called with ('/', { replace: true }), the pre-existing unchanged behavior.
 */

import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

const mockNavigate = vi.fn()
const mockSetSession = vi.fn()
const mockSigninRedirectCallback = vi.fn()

vi.mock('react-router-dom', () => ({
  useNavigate: () => mockNavigate,
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ setSession: mockSetSession }),
}))

vi.mock('@/auth/OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({
    signinRedirectCallback: mockSigninRedirectCallback,
  })),
}))

vi.mock('@/api/client', () => ({
  setToken: vi.fn(),
}))

vi.mock('@/auth/tenantConfig', () => ({
  resolveRealmFromUrl: vi.fn(() => null),
}))

vi.mock('@/api/tenants', () => ({
  tenantsApi: {
    getBySlug: vi.fn(),
  },
}))

// Real decodeTokenPayload is pure and safe to use unmocked -- it only needs
// a well-formed JWT-shaped string, built below via base64Url helpers
// matching the module's own atob-based decode.
import { decodeTokenPayload } from '@/auth/tokenUtils'

function fakeToken(roles: string[]): string {
  const header = { alg: 'none', typ: 'JWT' }
  const payload = { roles, sub: 'user-1', preferred_username: 'tester' }
  const b64 = (obj: unknown) => btoa(JSON.stringify(obj)).replace(/=+$/, '')
  return `${b64(header)}.${b64(payload)}.sig`
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-369 AC5 — OidcCallbackPage role-conditional navigation', () => {
  // OidcCallbackPage.tsx guards against React StrictMode's double-invoked
  // effect with a MODULE-SCOPE `let _callbackStarted` flag (see the file's
  // own comment above it) that only resets on a fresh module load. Each test
  // below therefore resets the module registry and re-imports the component
  // fresh, so the second test's render is not silently a no-op because the
  // first test already flipped that flag.
  it('TC-REQ369-05: PLATFORM_ADMIN role navigates to /platform-dashboard', async () => {
    vi.resetModules()
    const token = fakeToken(['PLATFORM_ADMIN'])
    // Sanity: confirm this test's fixture actually decodes the way the
    // component itself will decode it (same helper, same token string).
    expect(decodeTokenPayload(token)?.roles).toEqual(['PLATFORM_ADMIN'])

    mockSigninRedirectCallback.mockResolvedValue({ access_token: token })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/platform-dashboard', { replace: true })
    })
    expect(mockNavigate).not.toHaveBeenCalledWith('/', { replace: true })
  })

  it('TC-REQ369-06: a non-PLATFORM_ADMIN role (PROCESS_OPERATOR) navigates to / unchanged', async () => {
    vi.resetModules()
    const token = fakeToken(['PROCESS_OPERATOR'])
    expect(decodeTokenPayload(token)?.roles).toEqual(['PROCESS_OPERATOR'])

    mockSigninRedirectCallback.mockResolvedValue({ access_token: token })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/', { replace: true })
    })
    expect(mockNavigate).not.toHaveBeenCalledWith('/platform-dashboard', { replace: true })
  })
})

/**
 * ISS-0726 — restore-side priority logic in OidcCallbackPage.tsx: a
 * validated `user.state` (round-tripped through oidc-client-ts's `state`
 * option) wins over the role-based fallback, including for PLATFORM_ADMIN.
 * See lib/letflow/design/iss-0726-oidc-redirect-path-restore.md §3.1, §6.1
 * and test/specs/ISS-0726.md.
 */
describe('ISS-0726 — OidcCallbackPage restore-priority navigation', () => {
  it('TC-ISS0726-04: a validated user.state wins over the PROCESS_OPERATOR fallback', async () => {
    vi.resetModules()
    const token = fakeToken(['PROCESS_OPERATOR'])

    mockSigninRedirectCallback.mockResolvedValue({ access_token: token, state: '/exam' })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/exam', { replace: true })
    })
    expect(mockNavigate).not.toHaveBeenCalledWith('/', { replace: true })
  })

  it('TC-ISS0726-05: a validated user.state wins over PLATFORM_ADMIN\'s dashboard fallback', async () => {
    vi.resetModules()
    const token = fakeToken(['PLATFORM_ADMIN'])

    mockSigninRedirectCallback.mockResolvedValue({ access_token: token, state: '/exam' })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/exam', { replace: true })
    })
    expect(mockNavigate).not.toHaveBeenCalledWith('/platform-dashboard', { replace: true })
  })

  it('TC-ISS0726-06: an unsafe user.state (open-redirect-shaped) is rejected — falls back to role-based destination', async () => {
    vi.resetModules()
    const token = fakeToken(['PROCESS_OPERATOR'])

    mockSigninRedirectCallback.mockResolvedValue({ access_token: token, state: '//evil.com' })

    const { default: OidcCallbackPage } = await import('@/pages/OidcCallbackPage')
    render(<OidcCallbackPage />)

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/', { replace: true })
    })
    expect(mockNavigate).not.toHaveBeenCalledWith('//evil.com', { replace: true })
  })
})
