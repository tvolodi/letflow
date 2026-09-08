// @vitest-environment jsdom
/**
 * Unit tests — ISS-0532: the connectivity banner's backing hook must reflect
 * real backend liveness (GET /health) rather than latch to a permanent false
 * positive from a 404 on the non-existent GET /health/ready.
 */

import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'

vi.mock('@/api/health', () => ({
  healthReady: vi.fn(),
}))

import { healthReady } from '@/api/health'
import { useApiConnectivity } from '../useApiConnectivity'

const mockHealthReady = vi.mocked(healthReady)

describe('useApiConnectivity', () => {
  afterEach(() => {
    vi.clearAllMocks()
  })

  it('TC-ISS0532-05: isOnline becomes true when healthReady() resolves true (real GET /health success)', async () => {
    mockHealthReady.mockResolvedValue(true)

    const { result } = renderHook(() => useApiConnectivity({ intervalMs: 1_000_000 }))

    expect(result.current.isOnline).toBeNull()

    await waitFor(() => expect(result.current.isOnline).toBe(true))
    expect(result.current.outageSince).toBeNull()
  })

  it('TC-ISS0532-06: isOnline becomes false and outageSince is set when healthReady() resolves false', async () => {
    mockHealthReady.mockResolvedValue(false)

    const { result } = renderHook(() => useApiConnectivity({ intervalMs: 1_000_000 }))

    await waitFor(() => expect(result.current.isOnline).toBe(false))
    expect(result.current.outageSince).not.toBeNull()
  })

  it('TC-ISS0532-07: recovers to isOnline=true after a subsequent successful check', async () => {
    mockHealthReady.mockResolvedValueOnce(false).mockResolvedValueOnce(true)

    const { result, rerender } = renderHook(
      (props: { intervalMs: number }) => useApiConnectivity(props),
      { initialProps: { intervalMs: 1_000_000 } },
    )

    await waitFor(() => expect(result.current.isOnline).toBe(false))

    // Simulate a fresh mount-time check (e.g. user navigating back) picking up recovery.
    mockHealthReady.mockResolvedValue(true)
    act(() => {
      rerender({ intervalMs: 999_999 })
    })

    await waitFor(() => expect(result.current.isOnline).toBe(true))
    expect(result.current.outageSince).toBeNull()
  })
})
