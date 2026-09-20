// @vitest-environment jsdom
/**
 * Unit tests for tenantConfig.ts — resolveRealmFromUrl pure-logic tests.
 *
 * Covers: OIDC-F-06
 * Test cases: TC-OIDC-F06-01, TC-OIDC-F06-02
 *
 * DIRECTIVE T-2 note: these tests cover a pure URL/sessionStorage utility function
 * with no HTTP calls. No backend is required and no HTTP mocking is used.
 *
 * Environment: jsdom (required for sessionStorage + window.location)
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { resolveRealmFromUrl, resetTenantConfigCache } from './tenantConfig'

describe('resolveRealmFromUrl', () => {
  beforeEach(() => {
    // Clear sessionStorage before each test to ensure isolation.
    sessionStorage.clear()
    // Default: no realm in URL.
    vi.stubGlobal('location', { search: '' })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    sessionStorage.clear()
  })

  it('TC-OIDC-F06-01: returns slug from ?realm= URL param and writes to sessionStorage', () => {
    // Arrange: URL contains ?realm=swiftroute; sessionStorage is empty.
    vi.stubGlobal('location', { search: '?realm=swiftroute' })

    // Act
    const result = resolveRealmFromUrl()

    // Assert: slug returned and persisted
    expect(result).toBe('swiftroute')
    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('swiftroute')
  })

  it('TC-OIDC-F06-02: returns slug from sessionStorage when key is already set', () => {
    // Arrange: sessionStorage already has the slug from a previous page load.
    sessionStorage.setItem('bpm_realm_slug', 'meridian')
    // URL has no ?realm= param.
    vi.stubGlobal('location', { search: '' })

    // Act
    const result = resolveRealmFromUrl()

    // Assert: sessionStorage key wins; URL is not consulted.
    expect(result).toBe('meridian')
  })
})

/**
 * gui-review-2026-09-20-tenant-switch-cache-isolation (EO-002): resolveRealmFromUrl's
 * sessionStorage persistence is deliberate (OIDC-F-06), but nothing previously cleared
 * it on sign-out -- a realm slug left behind by one company's session survived into the
 * next person's sign-in on the same browser tab. resetTenantConfigCache is the fix,
 * wired into AuthProvider.logout() (see AuthProvider.logout-clears-realm.test.tsx).
 */
describe('resetTenantConfigCache', () => {
  beforeEach(() => {
    sessionStorage.clear()
  })

  afterEach(() => {
    sessionStorage.clear()
  })

  it('TC-EO002-01: removes bpm_realm_slug from sessionStorage', () => {
    sessionStorage.setItem('bpm_realm_slug', 'swiftroute')

    resetTenantConfigCache()

    expect(sessionStorage.getItem('bpm_realm_slug')).toBeNull()
  })

  it('TC-EO002-02: a subsequent resolveRealmFromUrl call with no URL param and no prior sessionStorage falls through to null (fresh resolution, not the cleared value)', () => {
    sessionStorage.setItem('bpm_realm_slug', 'swiftroute')
    resetTenantConfigCache()
    vi.stubGlobal('location', { search: '' })

    const result = resolveRealmFromUrl()

    expect(result).toBeNull()
    vi.unstubAllGlobals()
  })

  it("TC-EO002-03: strips a ?realm= query param from the address bar via history.replaceState, so ProtectedRoute's own re-render (which fires the instant logout() sets isAuthenticated to false, per AuthProvider.tsx) cannot re-derive and re-write the same slug from the URL a tick later", () => {
    const originalUrl = window.location.href
    window.history.pushState({}, '', '/?realm=swiftroute-fixture')
    sessionStorage.setItem('bpm_realm_slug', 'swiftroute-fixture')

    resetTenantConfigCache()

    expect(new URLSearchParams(window.location.search).has('realm')).toBe(false)
    // resolveRealmFromUrl() must now fall through to null -- neither
    // sessionStorage (already cleared) nor the URL (just stripped) name a
    // realm any more.
    expect(resolveRealmFromUrl()).toBeNull()

    window.history.pushState({}, '', originalUrl)
  })

  it('TC-EO002-04: a call with no ?realm= query param present does nothing to the URL (no-op path)', () => {
    const originalUrl = window.location.href
    window.history.pushState({}, '', '/tasks')

    expect(() => resetTenantConfigCache()).not.toThrow()
    expect(window.location.pathname).toBe('/tasks')
    expect(window.location.search).toBe('')

    window.history.pushState({}, '', originalUrl)
  })
})
