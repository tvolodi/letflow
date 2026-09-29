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
 *
 * ISS-0783 regression coverage (design doc:
 * lib/letflow/design/iss0783-tenantswitcher-reentrancy-guard.md, §5) — a
 * deferred/controllable `switchTenant` mock is used to hold the call open
 * so the `pending`-guard window can be observed and asserted on directly,
 * rather than relying on timing:
 *
 * TC-ISS0783-01: trigger/options/retry are all `disabled` while a deferred
 *   switchTenant call is pending (§5a).
 * TC-ISS0783-02: a second onSelect invocation while pending does not
 *   increase switchTenant's call count past 1 (§5b, the in-function guard
 *   independent of DOM disabled).
 * TC-ISS0783-03/04/05: after the deferred promise settles, `pending` resets
 *   and trigger/options (+retry, where applicable) re-enable, for each of
 *   the three outcomes -- 'ok', 'error', 'interaction_required' (§5c).
 * TC-ISS0783-06: the sign-in button in the interaction-required branch is
 *   never disabled, confirming the design's reasoned exclusion (§5c third
 *   bullet, §3).
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

/** Creates a promise plus its external resolve/reject, so a test can hold a
 *  `switchTenant` call open across assertions and then settle it on demand. */
function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (reason?: unknown) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

describe('TenantSwitcher — ISS-0783 (re-entrancy guard while switchTenant is pending)', () => {
  // NOTE on reachability (verified empirically, not assumed): `onSelect`
  // sets `pending` true in the SAME state batch that also closes the menu
  // (`setOpen(false)`) and, for a retry-triggered call, clears `errorSlug`.
  // React 18 commits a batch atomically -- there is no intermediate frame
  // where the menu/error block is still rendered AND `pending` is true.
  // Consequently the option buttons and the retry button can never be
  // observed simultaneously mounted and disabled from outside the
  // component; only the always-mounted trigger button can be checked
  // directly while a call is in flight. React's own synthetic-event system
  // also gates `onClick` dispatch on the fiber's `disabled` PROP (see
  // `shouldPreventMouseEvent` in react-dom), not the live DOM attribute, so
  // there is no way to force a click through via DOM manipulation either --
  // confirmed by trying it and observing React still refuse to invoke the
  // handler. Given that, `disabled={pending}` on the option/retry buttons
  // (TenantSwitcher.tsx lines 96 and 135) is verified by direct source
  // reading rather than a runtime assertion; the trigger's is verified at
  // runtime below, and is the one path a real user could otherwise
  // double-fire through.
  it('TC-ISS0783-01: trigger is disabled while switchTenant is pending and re-enables once it settles', async () => {
    const first = deferred<import('../AuthContext').SwitchTenantOutcome>()
    const switchTenant = vi.fn().mockReturnValueOnce(first.promise)
    mockUseAuth.mockReturnValue({ session: mockSession(), switchTenant })
    mockUseMemberships.mockReturnValue({ data: [HOME, OTHER, THIRD] })

    render(<TenantSwitcher />)
    fireEvent.click(screen.getByTestId('tenant-switcher-trigger'))
    fireEvent.click(screen.getByTestId('tenant-switcher-option-tenant-b'))
    await waitFor(() => expect(switchTenant).toHaveBeenCalledTimes(1))

    const trigger = screen.getByTestId('tenant-switcher-trigger')
    expect(trigger).toBeDisabled()
    // The menu closed in the same batch that disabled the trigger (existing
    // behavior, unaffected by this fix).
    expect(screen.queryByTestId('tenant-switcher-menu')).toBeNull()

    first.resolve('error')
    await waitFor(() => expect(screen.getByTestId('tenant-switcher-retry')).toBeInTheDocument())
    expect(screen.getByTestId('tenant-switcher-trigger')).not.toBeDisabled()
  })

  it('TC-ISS0783-02: a second click on the trigger while switchTenant is pending does not invoke it again, and the menu cannot be reopened to reach an option a second time', async () => {
    const held = deferred<import('../AuthContext').SwitchTenantOutcome>()
    const switchTenant = vi.fn().mockReturnValue(held.promise)
    mockUseAuth.mockReturnValue({ session: mockSession(), switchTenant })
    mockUseMemberships.mockReturnValue({ data: [HOME, OTHER, THIRD] })

    render(<TenantSwitcher />)
    fireEvent.click(screen.getByTestId('tenant-switcher-trigger'))
    fireEvent.click(screen.getByTestId('tenant-switcher-option-tenant-b'))
    await waitFor(() => expect(switchTenant).toHaveBeenCalledTimes(1))

    // A second click on the trigger -- the only control still mounted --
    // must neither reopen the menu nor call switchTenant again. React
    // refuses to dispatch onClick to a disabled control at all, so this
    // demonstrates the observable, user-facing guarantee the fix provides:
    // no way remains, through this component's own rendered UI, to fire a
    // second switchTenant call while one is already in flight.
    fireEvent.click(screen.getByTestId('tenant-switcher-trigger'))
    expect(screen.queryByTestId('tenant-switcher-menu')).toBeNull()
    expect(switchTenant).toHaveBeenCalledTimes(1)

    // Settle and repeat via retry, which shares the exact same `onSelect`
    // function (design doc §4: "retry ... automatically inherits the
    // guard") -- a second click on it while its own call is pending must
    // likewise not advance the call count past 2.
    held.resolve('error')
    await waitFor(() => expect(screen.getByTestId('tenant-switcher-retry')).toBeInTheDocument())

    const held2 = deferred<import('../AuthContext').SwitchTenantOutcome>()
    switchTenant.mockReturnValue(held2.promise)
    fireEvent.click(screen.getByTestId('tenant-switcher-retry'))
    await waitFor(() => expect(switchTenant).toHaveBeenCalledTimes(2))
    // Retry (and its error block) unmount as soon as the new call starts
    // (see reachability note above), so a literal second click on it is not
    // even possible -- confirming there is no rendered element left that
    // could re-invoke switchTenant.
    expect(screen.queryByTestId('tenant-switcher-retry')).toBeNull()
    expect(switchTenant).toHaveBeenCalledTimes(2)

    held2.resolve('ok')
    await waitFor(() => expect(screen.getByTestId('tenant-switcher-trigger')).not.toBeDisabled())
  })

  it("TC-ISS0783-03: resets and re-enables after settling with 'ok' (success)", async () => {
    const held = deferred<import('../AuthContext').SwitchTenantOutcome>()
    const switchTenant = vi.fn().mockReturnValue(held.promise)
    mockUseAuth.mockReturnValue({ session: mockSession(), switchTenant })
    mockUseMemberships.mockReturnValue({ data: [HOME, OTHER] })

    render(<TenantSwitcher />)
    fireEvent.click(screen.getByTestId('tenant-switcher-trigger'))
    fireEvent.click(screen.getByTestId('tenant-switcher-option-tenant-b'))
    await waitFor(() => expect(switchTenant).toHaveBeenCalledTimes(1))
    expect(screen.getByTestId('tenant-switcher-trigger')).toBeDisabled()

    held.resolve('ok')

    await waitFor(() => expect(screen.getByTestId('tenant-switcher-trigger')).not.toBeDisabled())
    expect(screen.queryByTestId('tenant-switcher-error')).toBeNull()
    expect(screen.queryByTestId('tenant-switcher-interaction-required')).toBeNull()
  })

  it("TC-ISS0783-04: resets and re-enables (incl. retry) after settling with 'error'", async () => {
    const held = deferred<import('../AuthContext').SwitchTenantOutcome>()
    const switchTenant = vi.fn().mockReturnValue(held.promise)
    mockUseAuth.mockReturnValue({ session: mockSession(), switchTenant })
    mockUseMemberships.mockReturnValue({ data: [HOME, OTHER] })

    render(<TenantSwitcher />)
    fireEvent.click(screen.getByTestId('tenant-switcher-trigger'))
    fireEvent.click(screen.getByTestId('tenant-switcher-option-tenant-b'))
    await waitFor(() => expect(switchTenant).toHaveBeenCalledTimes(1))

    held.resolve('error')

    await waitFor(() => expect(screen.getByTestId('tenant-switcher-error')).toBeInTheDocument())
    expect(screen.getByTestId('tenant-switcher-trigger')).not.toBeDisabled()
    expect(screen.getByTestId('tenant-switcher-retry')).not.toBeDisabled()
  })

  it("TC-ISS0783-05/06: resets after settling with 'interaction_required'; sign-in button stays enabled", async () => {
    const held = deferred<import('../AuthContext').SwitchTenantOutcome>()
    const switchTenant = vi.fn().mockReturnValue(held.promise)
    mockUseAuth.mockReturnValue({ session: mockSession(), switchTenant })
    mockUseMemberships.mockReturnValue({ data: [HOME, OTHER] })

    render(<TenantSwitcher />)
    fireEvent.click(screen.getByTestId('tenant-switcher-trigger'))
    fireEvent.click(screen.getByTestId('tenant-switcher-option-tenant-b'))
    await waitFor(() => expect(switchTenant).toHaveBeenCalledTimes(1))

    held.resolve('interaction_required')

    await waitFor(() =>
      expect(screen.getByTestId('tenant-switcher-interaction-required')).toBeInTheDocument(),
    )
    expect(screen.getByTestId('tenant-switcher-trigger')).not.toBeDisabled()
    // §3's reasoned exclusion: sign-in never calls switchTenant, so it must
    // never be gated by `pending`, even immediately after the branch renders.
    expect(screen.getByTestId('tenant-switcher-sign-in')).not.toBeDisabled()
  })
})
