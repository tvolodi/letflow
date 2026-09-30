// @vitest-environment jsdom
/** REQ-432 §6 / EO-005 — INSTANCE_PINS_REBOUND row in the History tab. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

const events = vi.fn()

vi.mock('@/api/instances', () => ({
  instancesApi: { events: (...args: unknown[]) => events(...args) },
}))

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: { token: 't', display_name: 'Admin', roles: ['PLATFORM_ADMIN'], loginSource: 'oidc' as const, tenant_slug: null, tenant_display_name: null, tenant_id: 'tid-history-fixture', tenant_type: null, production_tenant_display_name: null },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import { EventHistoryPanel } from '../EventHistoryPanel'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

const ACTOR_UUID = 'abcdef12-0000-0000-0000-000000000000'
const REASON = 'External system retires the old endpoint at month end.'

const REBOUND_EVENT = {
  event_id: 'ev-rebound',
  event_type: 'INSTANCE_PINS_REBOUND',
  sequence_number: 5,
  created_at: '2026-09-30T10:00:00Z',
  payload: {
    entries: [{ kind: 'catalog_entry', ref: 'svc-a', prior_version: '1', new_version: '2' }],
    actor: ACTOR_UUID,
    reason: REASON,
  },
}
const OTHER_EVENT = {
  event_id: 'ev-other',
  event_type: 'TASK_COMPLETED',
  sequence_number: 4,
  created_at: '2026-09-30T09:00:00Z',
  payload: { node_id: 'n2' },
}

function renderPanel(names?: Record<string, string>) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <EventHistoryPanel instanceId="inst-1" actorNamesByEventId={names} />
    </QueryClientProvider>,
  )
}

describe('EventHistoryPanel — INSTANCE_PINS_REBOUND', () => {
  it('shows operator name, prior version, new version and reason in the SAME row', async () => {
    events.mockResolvedValue([OTHER_EVENT, REBOUND_EVENT])
    renderPanel({ 'ev-rebound': 'Admin User' })

    const row = await screen.findByTestId('event-row-ev-rebound')
    expect(within(row).getByTestId('event-actor-ev-rebound')).toHaveTextContent('Admin User')
    expect(within(row).getByTestId('pins-rebound-actor')).toHaveTextContent('Admin User')
    const entry = within(row).getByTestId('pins-rebound-entry-svc-a')
    expect(entry).toHaveTextContent('1')
    expect(entry).toHaveTextContent('2')
    expect(within(row).getByTestId('pins-rebound-reason')).toHaveTextContent(REASON)
    // raw JSON is kept for audit
    expect(within(row).getByTestId('pins-rebound-summary')).toBeInTheDocument()
  })

  it('without a resolved name shows the payload actor UUID (8-char prefix in the cell), never "system"', async () => {
    events.mockResolvedValue([REBOUND_EVENT])
    renderPanel({})

    const cell = await screen.findByTestId('event-actor-ev-rebound')
    expect(cell).toHaveTextContent(ACTOR_UUID.slice(0, 8))
    expect(cell).not.toHaveTextContent('system')
    expect(screen.getByTestId('pins-rebound-actor')).toHaveTextContent(ACTOR_UUID)
  })

  it('leaves other event types unchanged (Actor "system", no summary)', async () => {
    events.mockResolvedValue([OTHER_EVENT, REBOUND_EVENT])
    renderPanel({ 'ev-rebound': 'Admin User' })

    await waitFor(() => expect(screen.getByTestId('event-row-ev-other')).toBeInTheDocument())
    const other = screen.getByTestId('event-row-ev-other')
    expect(within(other).getByTestId('event-actor-ev-other')).toHaveTextContent('system')
    expect(within(other).queryByTestId('pins-rebound-summary')).not.toBeInTheDocument()
  })
})
