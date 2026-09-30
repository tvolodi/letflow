// @vitest-environment jsdom
/**
 * REQ-432 §6.2 — the page joins the timeline feed's actor_display_name onto
 * INSTANCE_PINS_REBOUND history rows by event_id (EO-005 on ONE view).
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor, within } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

const INSTANCE_ID = 'inst-1'
const timeline = vi.fn()

vi.mock('@/api/instances', () => ({
  instancesApi: {
    get: vi.fn(async () => ({
      instance_id: INSTANCE_ID,
      definition_id: 'def-1',
      status: 'ACTIVE',
      current_nodes: ['n2'],
      variables: {},
      started_at: '2026-09-20T00:00:00Z',
    })),
    timeline: (...a: unknown[]) => timeline(...a),
    getPins: vi.fn(async () => ({ instance_id: INSTANCE_ID, pins: [] })),
    events: vi.fn(async () => [
      {
        event_id: 'ev-rebound',
        event_type: 'INSTANCE_PINS_REBOUND',
        sequence_number: 3,
        created_at: '2026-09-30T10:00:00Z',
        payload: {
          entries: [{ kind: 'catalog_entry', ref: 'svc-a', prior_version: '1', new_version: '2' }],
          actor: 'abcdef12-0000-0000-0000-000000000000',
          reason: 'why',
        },
      },
      {
        event_id: 'ev-task',
        event_type: 'TASK_COMPLETED',
        sequence_number: 2,
        created_at: '2026-09-30T09:00:00Z',
        payload: {},
      },
    ]),
  },
}))

vi.mock('@/api/definitions', () => ({
  definitionsApi: { get: vi.fn(async () => ({ id: 'def-1', name: 'd', version: '1', status: 'ACTIVE', graph: { nodes: [], edges: [] } })) },
}))
vi.mock('@/api/tasks', () => ({ tasksApi: { list: vi.fn(async () => ({ items: [], next_cursor: null })) } }))
vi.mock('@/hooks/usePolling', () => ({
  usePolling: vi.fn(() => ({ lastRefreshedAt: null, refreshNow: vi.fn(), refreshCount: 0 })),
}))
vi.mock('@/hooks/useHistoryScrubber', () => ({
  useHistoryScrubber: vi.fn(() => ({
    currentSeqNum: 0, totalEvents: 0, reconstructedState: null, isLoading: false,
    isLiveMode: true, error: null, goToEvent: vi.fn(), resumeLive: vi.fn(),
  })),
}))
vi.mock('@/components/instances/CancelInstanceDialog', () => ({ CancelInstanceDialog: () => null }))
vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: { token: 't', display_name: 'Admin', roles: ['PLATFORM_ADMIN'], loginSource: 'oidc' as const, tenant_slug: null, tenant_display_name: null, tenant_id: 'tid-actor-fixture', tenant_type: null, production_tenant_display_name: null },
      isAuthenticated: true, isLoading: false, loginSource: 'oidc' as const,
      login: vi.fn(), logout: vi.fn(), setSession: vi.fn(),
    }),
  }
})

import InstanceDetailPage from '@/pages/instances/InstanceDetailPage'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('InstanceDetailPage — rebound actor names on the History tab', () => {
  it('requests the timeline with page_size 200 and joins the rebound entry name by event_id only', async () => {
    timeline.mockResolvedValue({
      items: [
        { event_type: 'INSTANCE_PINS_REBOUND', event_id: 'ev-rebound', actor_display_name: 'Admin User', timestamp: 't', description: 'd', instance_id: INSTANCE_ID, sequence_num: 3, task_id: null, node_id: null, metadata: {} },
        { event_type: 'TASK_COMPLETED', event_id: 'ev-task', actor_display_name: 'Someone Else', timestamp: 't', description: 'd', instance_id: INSTANCE_ID, sequence_num: 2, task_id: null, node_id: null, metadata: {} },
      ],
      count: 2,
      next_cursor: null,
    })
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={qc}>
        <MemoryRouter initialEntries={[`/instances/${INSTANCE_ID}`]}>
          <Routes><Route path="/instances/:id" element={<InstanceDetailPage />} /></Routes>
        </MemoryRouter>
      </QueryClientProvider>,
    )

    const row = await screen.findByTestId('event-row-ev-rebound')
    await waitFor(() => expect(within(row).getByTestId('pins-rebound-actor')).toHaveTextContent('Admin User'))
    expect(within(row).getByTestId('event-actor-ev-rebound')).toHaveTextContent('Admin User')
    expect(timeline).toHaveBeenCalledWith(INSTANCE_ID, { cursor: undefined, page_size: 200 })

    // non-rebind events are not joined
    expect(screen.getByTestId('event-actor-ev-task')).toHaveTextContent('system')
    expect(screen.queryByText('Someone Else')).not.toBeInTheDocument()
  })
})
