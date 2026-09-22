// @vitest-environment jsdom
/**
 * REQ-384 §5.3/§7.3.1 — AuthProvider.switchTenant's cache-clear mechanism,
 * the core property AC3 depends on: on a successful silent switch, the
 * OUTGOING tenant's whole query-cache subtree is REMOVED (not merely
 * invalidated) BEFORE the new session is set. Full TEST-DESIGNER coverage
 * comes later in the pipeline; this file proves the load-bearing mechanism
 * directly against a real QueryClient (only the OIDC/token/tenant-lookup
 * boundary is mocked), per this codebase's own DIRECTIVE T-2 "mock the layer
 * directly beneath the unit under test" convention.
 *
 * TC-REQ384-07: a tenant-A-keyed cache entry populated before the switch is
 *   GONE (getQueryData returns undefined, not stale data) after a successful
 *   switch — proving removeQueries, not invalidateQueries, ran.
 * TC-REQ384-08: the session's tenant_id actually changes to the target
 *   tenant after a successful switch.
 * TC-REQ384-09: on 'interaction_required', the outgoing tenant's cache is
 *   left completely untouched — switchTenant's cache-clear step must only
 *   run after a CONFIRMED successful silent switch (design §6.1's own
 *   "a failed switch must not leave the user logged into neither tenant"
 *   guarantee, checked here at the cache layer).
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, act } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

const { mockSetToken, mockAttemptSilentSwitch, mockGetBySlug } = vi.hoisted(() => ({
  mockSetToken: vi.fn(),
  mockAttemptSilentSwitch: vi.fn(),
  mockGetBySlug: vi.fn(),
}))

vi.mock('@/api/client', () => ({
  clearToken: vi.fn(),
  setToken: mockSetToken,
  tryRestoreE2eSession: vi.fn(() => ({
    token: 'tok-a',
    display_name: 'Alice',
    roles: ['PLATFORM_ADMIN'],
    tenant_slug: 'tenant-a',
    tenant_display_name: 'Tenant A',
    tenant_id: 'tid-a',
    tenant_type: 'production',
    production_tenant_display_name: null,
  })),
}))

vi.mock('../OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({
    signoutRedirect: vi.fn(),
    signinRedirect: vi.fn(),
    events: { addAccessTokenExpiring: vi.fn(), removeAccessTokenExpiring: vi.fn() },
    startSilentRenew: vi.fn(),
  })),
}))

vi.mock('../tenantOidcRegistry', () => ({
  attemptSilentSwitch: mockAttemptSilentSwitch,
}))

vi.mock('@/api/tenants', () => ({
  tenantsApi: {
    getBySlug: mockGetBySlug,
  },
}))

// A minimal, real-shaped (base64url header.payload.signature) JWT so
// decodeTokenPayload (the real, unmocked implementation) parses it. Payload:
// { roles: ["PLATFORM_ADMIN"], tenant_id: "tenant-b", sub: "u1" }
const TENANT_B_TOKEN =
  'eyJhbGciOiJub25lIn0.' +
  'eyJyb2xlcyI6WyJQTEFURk9STV9BRE1JTiJdLCJ0ZW5hbnRfaWQiOiJ0ZW5hbnQtYiIsInN1YiI6InUxIn0.' +
  'sig'

import { AuthProvider } from '../AuthProvider'
import { AuthContext } from '../AuthContext'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function renderAuthProvider(queryClient: QueryClient) {
  let captured: import('../AuthContext').AuthContextValue | null = null

  function Capture() {
    return (
      <AuthContext.Consumer>
        {(value) => {
          captured = value ?? null
          return null
        }}
      </AuthContext.Consumer>
    )
  }

  render(
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <Capture />
      </AuthProvider>
    </QueryClientProvider>,
  )

  return () => captured
}

describe('AuthProvider.switchTenant — REQ-384 §5.3/§7.3.1 cache-clear mechanism', () => {
  it('TC-REQ384-07/08: a successful switch REMOVES the outgoing tenant\'s cache subtree and updates session.tenant_id', async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    // Seed a tenant-A-keyed cache entry, mirroring what a real screen would
    // have populated via useInstances() before the switch.
    const tenantAKey = ['tenant', 'tid-a', 'instances', 'list', {}] as const
    queryClient.setQueryData(tenantAKey, { items: [{ instance_id: 'tenant-a-only' }], next_cursor: null })
    expect(queryClient.getQueryData(tenantAKey)).toBeDefined()

    mockAttemptSilentSwitch.mockResolvedValue({
      outcome: 'silent_ok',
      user: { access_token: TENANT_B_TOKEN },
    })
    mockGetBySlug.mockResolvedValue({
      slug: 'tenant-b',
      tenant_id: 'tid-b',
      display_name: 'Tenant B',
      tenant_type: 'production',
      production_tenant_display_name: null,
    })

    const getCaptured = renderAuthProvider(queryClient)

    let outcome: string | undefined
    await act(async () => {
      outcome = await getCaptured()!.switchTenant('tenant-b')
    })

    expect(outcome).toBe('ok')

    // The load-bearing assertion: removeQueries ran (data is GONE), not
    // invalidateQueries (which would leave getQueryData still returning the
    // stale tenant-A rows synchronously while a background refetch runs —
    // exactly the "stale row in a placeholder frame" AC3 forbids).
    expect(queryClient.getQueryData(tenantAKey)).toBeUndefined()

    // Session now reflects tenant B.
    expect(getCaptured()!.session?.tenant_id).toBe('tid-b')
    expect(mockSetToken).toHaveBeenCalledWith(TENANT_B_TOKEN)
  })

  it('TC-REQ384-09: interaction_required leaves the outgoing tenant\'s cache and session completely untouched', async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const tenantAKey = ['tenant', 'tid-a', 'instances', 'list', {}] as const
    queryClient.setQueryData(tenantAKey, { items: [{ instance_id: 'tenant-a-only' }], next_cursor: null })

    mockAttemptSilentSwitch.mockResolvedValue({ outcome: 'interaction_required' })

    const getCaptured = renderAuthProvider(queryClient)

    let outcome: string | undefined
    await act(async () => {
      outcome = await getCaptured()!.switchTenant('tenant-b')
    })

    expect(outcome).toBe('interaction_required')
    // Cache-clear must not have run: a failed/incomplete switch must not
    // leave the user logged into neither tenant.
    expect(queryClient.getQueryData(tenantAKey)).toBeDefined()
    expect(getCaptured()!.session?.tenant_id).toBe('tid-a')
    expect(mockSetToken).not.toHaveBeenCalled()
  })
})
