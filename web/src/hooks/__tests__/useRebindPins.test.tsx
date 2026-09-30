// @vitest-environment jsdom
/** REQ-432 §4.3 — useRebindPins invalidates exactly the instances prefix. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderHook, act, waitFor, cleanup } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'

const rebindPins = vi.fn()

vi.mock('@/api/instances', () => ({
  instancesApi: { rebindPins: (...args: unknown[]) => rebindPins(...args) },
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: { token: 't', display_name: 'A', roles: ['PLATFORM_ADMIN'], loginSource: 'oidc', tenant_id: 'tid-rebind-fixture' },
  }),
}))

import { useRebindPins } from '../useRebindPins'
import { queryKeys } from '@/api/queryKeys'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

const VARS = {
  body: { reason: 'r', entries: [{ kind: 'catalog_entry' as const, ref: 'svc-a', version: '2' }] },
  idempotencyKey: 'k1',
}

function setup() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const spy = vi.spyOn(qc, 'invalidateQueries')
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { spy, wrapper }
}

describe('useRebindPins', () => {
  it('on success calls the api with (id, body, key) and invalidates exactly the instances prefix once', async () => {
    rebindPins.mockResolvedValue({ instance_id: 'inst-1', changes: [], rebound_at: 'x' })
    const { spy, wrapper } = setup()
    const { result } = renderHook(() => useRebindPins('inst-1'), { wrapper })

    await act(async () => {
      await result.current.mutateAsync(VARS)
    })

    expect(rebindPins).toHaveBeenCalledWith('inst-1', VARS.body, 'k1')
    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith({ queryKey: queryKeys.instances.all('tid-rebind-fixture') })
    expect(queryKeys.instances.all('tid-rebind-fixture')).toEqual(['tenant', 'tid-rebind-fixture', 'instances'])
  })

  it('on failure does not invalidate', async () => {
    rebindPins.mockRejectedValue({ status: 409 })
    const { spy, wrapper } = setup()
    const { result } = renderHook(() => useRebindPins('inst-1'), { wrapper })

    await act(async () => {
      await result.current.mutateAsync(VARS).catch(() => {})
    })
    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(spy).not.toHaveBeenCalled()
  })
})
