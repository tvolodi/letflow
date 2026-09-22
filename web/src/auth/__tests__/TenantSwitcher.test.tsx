// @vitest-environment jsdom
/**
 * REQ-384 §6.1 — TenantSwitcher.tsx, the component AC1 is actually about
 * ("a signed-in user whose account holds membership in more than one tenant
 * sees an in-app control to select which tenant they are acting as" / a
 * single-membership user sees no such control). TEST-DESIGNER audit gap:
 * neither ELIXIR-DEV nor FRONTEND-DEV's inline coverage included a dedicated
 * test file for this component -- `useTenantScopedQueryKeys.test.ts`,
 * `AuthProvider.switchTenant.test.tsx`, and `AuthenticatedShellRoot.test.tsx`
 * cover the cache-isolation/remount mechanisms (AC2/AC3) but nothing
 * exercises the switcher's own render-gate or its wiring to `switchTenant`'s
 * three outcomes. This file closes that gap.
 *
 * TC-REQ384-16: renders nothing for a single-membership user (memberships
 *   length 1 -- the caller's own home tenant only, per design §6.1).
 * TC-REQ384-17: renders nothing while memberships are still loading
 *   (`data: undefined`) -- must not flash a control that then disappears.
 * TC-REQ384-18: renders the trigger for a multi-membership user, and the
 *   menu lists every OTHER membership (not the currently-active one), using
 *   display_label when set and falling back to tenant_display_name.
 * TC-REQ384-19: selecting an option calls switchTenant(slug) with the
 *   selected membership's tenant_slug.
 * TC-REQ384-20: on 'interaction_required', shows the explicit sign-in
 *   affordance instead of silently failing; clicking it drives
 *   getOrCreateManagerForTenant + manager.signinRedirect (§5.2 fallback).
 * TC-REQ384-21: on 'error', shows a retry affordance rather than a raw
 *   error/blob.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, cleanup, screen, fireEvent, waitFor } from '@testing-library/react'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'

expect.extend(jestDomMatchers)

const mockUseAuth = vi.fn()
const mockUseMemberships = vi.fn()
const mockGetOrCreateManagerForTenant = vi.fn()
const mockBuildRedirectArgs = vi.fn().mockReturnValue(undefined)

vi.mock('../AuthContext', () => ({
  useAuth: (...args: unknown[]) => mockUseAuth(...args),
}))

vi.mock('@/hooks/useMemberships', () => ({
  useMemberships: (...args: unknown[]) => mockUseMemberships(...args),
}))

vi.mock('../tenantOidcRegistry', () => ({
  getOrCreateManagerForTenant: (...args: unknown[]) => mockGetOrCreateManagerForTenant(...args),
}))

vi.mock('../oidcRedirectArgs', () => ({
  buildRedirectArgs: (...args: unknown[]) => mockBuildRedirectArgs(...args),
}))

import { TenantSwitcher } from '../TenantSwitcher'

const HOME = { tenant_id: 'tid-a', tenant_slug: 'tenant-a', tenant_display_name: 'Tenant A', display_label: null }
const OTHER = { tenant_id: 'tid-b', tenant_slug: 'tenant-b', tenant_display_name: 'Tenant B', display_label: 'Beta Co' }
const THIRD = { tenant_id: 'tid-c', tenant_slug: 'tenant-c', tenant_display_name: 'Tenant C', display_label: null }

function mockSession(tenantId = 'tid-a') {
  return { tenant_id: tenantId }
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('TenantSwitcher — REQ-384 §6.1 (AC1 render-gate + outcome wiring)', () => {
  it('TC-REQ384-16: renders null for a single-membership user', () => {
    mockUseAuth.mockReturnValue({ session: mockSession(), switchTenant: vi.fn() })
    mockUseMemberships.mockReturnValue({ data: [HOME] })

    const { container } = render(<TenantSwitcher />)

    expect(container).toBeEmptyDOMElement()
    expect(screen.queryByTestId('tenant-switcher')).toBeNull()
  })

  it('TC-REQ384-17: renders null while memberships are still loading (data undefined)', () => {
    mockUseAuth.mockReturnValue({ session: mockSession(), switchTenant: vi.fn() })
    mockUseMemberships.mockReturnValue({ data: undefined })

    const { container } = render(<TenantSwitcher />)

    expect(container).toBeEmptyDOMElement()
  })

  it('TC-REQ384-18: renders the trigger + menu of OTHER memberships for a multi-membership user, using display_label fallback', () => {
    mockUseAuth.mockReturnValue({ session: mockSession(), switchTenant: vi.fn() })
    mockUseMemberships.mockReturnValue({ data: [HOME, OTHER, THIRD] })

    render(<TenantSwitcher />)

    expect(screen.getByTestId('tenant-switcher-trigger')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('tenant-switcher-trigger'))

    // The active tenant (HOME) must NOT appear as a selectable option.
    expect(screen.queryByTestId('tenant-switcher-option-tenant-a')).toBeNull()

    // OTHER has a display_label -- shown instead of tenant_display_name.
    const otherOption = screen.getByTestId('tenant-switcher-option-tenant-b')
    expect(otherOption).toHaveTextContent('Beta Co')

    // THIRD has no display_label -- falls back to tenant_display_name.
    const thirdOption = screen.getByTestId('tenant-switcher-option-tenant-c')
    expect(thirdOption).toHaveTextContent('Tenant C')
  })

  it('TC-REQ384-19: selecting an option calls switchTenant with that membership\'s tenant_slug', async () => {
    const switchTenant = vi.fn().mockResolvedValue('ok')
    mockUseAuth.mockReturnValue({ session: mockSession(), switchTenant })
    mockUseMemberships.mockReturnValue({ data: [HOME, OTHER] })

    render(<TenantSwitcher />)
    fireEvent.click(screen.getByTestId('tenant-switcher-trigger'))
    fireEvent.click(screen.getByTestId('tenant-switcher-option-tenant-b'))

    await waitFor(() => expect(switchTenant).toHaveBeenCalledWith('tenant-b'))
  })

  it('TC-REQ384-20: interaction_required shows an explicit sign-in affordance; clicking it drives the per-tenant manager\'s signinRedirect', async () => {
    const switchTenant = vi.fn().mockResolvedValue('interaction_required')
    const manager = { signinRedirect: vi.fn() }
    mockGetOrCreateManagerForTenant.mockResolvedValue(manager)
    mockUseAuth.mockReturnValue({ session: mockSession(), switchTenant })
    mockUseMemberships.mockReturnValue({ data: [HOME, OTHER] })

    render(<TenantSwitcher />)
    fireEvent.click(screen.getByTestId('tenant-switcher-trigger'))
    fireEvent.click(screen.getByTestId('tenant-switcher-option-tenant-b'))

    await waitFor(() =>
      expect(screen.getByTestId('tenant-switcher-interaction-required')).toBeInTheDocument(),
    )
    // No raw error dumped -- a plain-language, user-initiated affordance.
    expect(screen.queryByTestId('tenant-switcher-error')).toBeNull()

    fireEvent.click(screen.getByTestId('tenant-switcher-sign-in'))

    await waitFor(() => expect(mockGetOrCreateManagerForTenant).toHaveBeenCalledWith('tenant-b'))
    await waitFor(() => expect(manager.signinRedirect).toHaveBeenCalled())
  })

  it('TC-REQ384-21: error outcome shows a retry affordance, not a raw error blob', async () => {
    const switchTenant = vi.fn().mockResolvedValue('error')
    mockUseAuth.mockReturnValue({ session: mockSession(), switchTenant })
    mockUseMemberships.mockReturnValue({ data: [HOME, OTHER] })

    render(<TenantSwitcher />)
    fireEvent.click(screen.getByTestId('tenant-switcher-trigger'))
    fireEvent.click(screen.getByTestId('tenant-switcher-option-tenant-b'))

    await waitFor(() => expect(screen.getByTestId('tenant-switcher-error')).toBeInTheDocument())
    expect(screen.getByTestId('tenant-switcher-error')).toHaveTextContent('Could not switch tenant.')
    expect(screen.getByTestId('tenant-switcher-retry')).toBeInTheDocument()
  })
})
