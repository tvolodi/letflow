// @vitest-environment jsdom
/**
 * Unit tests — ISS-0532: the banner must not show when the backend is
 * actually reachable. Previously it probed the non-existent
 * `GET /health/ready`, always 404'd, and rendered a permanent false-positive
 * "Platform is currently unavailable" banner. Backed now by the real
 * `GET /health` liveness check via `useApiConnectivity`.
 */

import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

vi.mock('@/hooks/useApiConnectivity', () => ({
  useApiConnectivity: vi.fn(),
}))

import { useApiConnectivity } from '@/hooks/useApiConnectivity'
import { ApiConnectivityBanner } from '../ApiConnectivityBanner'

const mockUseApiConnectivity = vi.mocked(useApiConnectivity)

describe('ApiConnectivityBanner', () => {
  afterEach(() => {
    vi.clearAllMocks()
  })

  it('TC-ISS0532-08: renders nothing when the real backend liveness check succeeds (isOnline=true)', () => {
    mockUseApiConnectivity.mockReturnValue({
      isOnline: true,
      lastOnlineAt: new Date().toISOString(),
      outageSince: null,
    })

    render(<ApiConnectivityBanner />)

    expect(screen.queryByTestId('connectivity-banner')).not.toBeInTheDocument()
  })

  it('TC-ISS0532-09: renders nothing during the initial not-yet-checked state (isOnline=null)', () => {
    mockUseApiConnectivity.mockReturnValue({ isOnline: null, lastOnlineAt: null, outageSince: null })

    render(<ApiConnectivityBanner />)

    expect(screen.queryByTestId('connectivity-banner')).not.toBeInTheDocument()
  })

  it('TC-ISS0532-10: renders the unavailable banner only when isOnline=false (a real outage)', async () => {
    mockUseApiConnectivity.mockReturnValue({
      isOnline: false,
      lastOnlineAt: null,
      outageSince: new Date().toISOString(),
    })

    render(<ApiConnectivityBanner />)

    await waitFor(() => {
      expect(screen.getByTestId('connectivity-banner')).toBeInTheDocument()
    })
    expect(screen.getByText(/Platform is currently unavailable/i)).toBeInTheDocument()
  })
})
