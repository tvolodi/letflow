// @vitest-environment jsdom
/**
 * REQ-432 §5/§8 — rebind action on InstancePinsPanel: gating, dialog
 * validation, real-hook wiring (Idempotency-Key, refetch of pins), error
 * texts, key lifetime; plus the EO-001/EO-002/EO-004 component-level proofs
 * that the panel reads per-instance data.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { EffectivePin } from '@/types/api'
expect.extend(jestDomMatchers)

const getPins = vi.fn()
const rebindPins = vi.fn()
const listAllServices = vi.fn()
const retireService = vi.fn()

vi.mock('@/api/instances', () => ({
  instancesApi: {
    getPins: (...args: unknown[]) => getPins(...args),
    rebindPins: (...args: unknown[]) => rebindPins(...args),
  },
}))

// Independent API module: the services catalog. The pins panel and the
// services page share NO mock state, only the QueryClient, exactly like prod.
vi.mock('@/api/services', () => ({
  servicesApi: {
    listAll: (...a: unknown[]) => listAllServices(...a),
    listForTenant: vi.fn(),
    publishVersion: vi.fn(),
    retire: (...a: unknown[]) => retireService(...a),
  },
}))

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: { token: 't', display_name: 'Admin', roles: ['PLATFORM_ADMIN'], loginSource: 'oidc' as const, tenant_slug: null, tenant_display_name: null, tenant_id: 'tid-rebind-panel-fixture', tenant_type: null, production_tenant_display_name: null },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import { InstancePinsPanel } from '@/components/instances/InstancePinsPanel'
import ServicesPage from '@/pages/admin/services/ServicesPage'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function pin(overrides: Partial<EffectivePin> = {}): EffectivePin {
  return { kind: 'catalog_entry', ref: 'svc-a', resolved_id: 'r1', version: '1', source: 'resolved', ...overrides }
}

const BTN = 'pin-rebind-btn-catalog_entry:svc-a'
const REASON = 'External system retires the old endpoint at month end.'

function renderPanel(props: { canRebind?: boolean; instanceActive?: boolean; instanceId?: string } = {}) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <InstancePinsPanel instanceId={props.instanceId ?? 'inst-1'} canRebind={props.canRebind} instanceActive={props.instanceActive} />
    </QueryClientProvider>,
  )
}

async function openDialog() {
  const user = userEvent.setup()
  await user.click(await screen.findByTestId(BTN))
  await screen.findByTestId('pin-rebind-dialog')
  return user
}

describe('REQ-432 rebind — gating', () => {
  it('no Rebind button without canRebind (REQ-399 read-only behaviour preserved)', async () => {
    getPins.mockResolvedValue({ instance_id: 'inst-1', pins: [pin()] })
    renderPanel({ instanceActive: true })
    await screen.findByTestId('data-table')
    expect(screen.queryByTestId(BTN)).not.toBeInTheDocument()
  })

  it('no Rebind button when the instance is not active', async () => {
    getPins.mockResolvedValue({ instance_id: 'inst-1', pins: [pin()] })
    renderPanel({ canRebind: true, instanceActive: false })
    await screen.findByTestId('data-table')
    expect(screen.queryByTestId(BTN)).not.toBeInTheDocument()
  })

  it('shows one Rebind button per pin when permitted and active', async () => {
    getPins.mockResolvedValue({ instance_id: 'inst-1', pins: [pin(), pin({ kind: 'module', ref: 'mod-x' })] })
    renderPanel({ canRebind: true, instanceActive: true })
    expect(await screen.findByTestId(BTN)).toBeInTheDocument()
    expect(screen.getByTestId('pin-rebind-btn-module:mod-x')).toBeInTheDocument()
  })
})

describe('REQ-432 rebind — dialog validation', () => {
  it('blocks submit on empty reason and on an unchanged version', async () => {
    getPins.mockResolvedValue({ instance_id: 'inst-1', pins: [pin()] })
    renderPanel({ canRebind: true, instanceActive: true })
    const user = await openDialog()

    const submit = screen.getByTestId('pin-rebind-submit')
    expect(submit).toBeDisabled()

    await user.type(screen.getByTestId('pin-rebind-new-version-input'), '2')
    expect(submit).toBeDisabled() // reason still empty

    await user.type(screen.getByTestId('pin-rebind-reason-input'), '   ')
    expect(submit).toBeDisabled() // whitespace-only reason

    await user.clear(screen.getByTestId('pin-rebind-new-version-input'))
    await user.type(screen.getByTestId('pin-rebind-new-version-input'), '1')
    await user.type(screen.getByTestId('pin-rebind-reason-input'), 'why')
    expect(submit).toBeDisabled()
    expect(screen.getByText('Choose a different version')).toBeInTheDocument()
    expect(rebindPins).not.toHaveBeenCalled()
  })
})

describe('REQ-432 rebind — submit', () => {
  it('sends body + Idempotency-Key, refetches pins, shows the new version and the success line', async () => {
    getPins
      .mockResolvedValueOnce({ instance_id: 'inst-1', pins: [pin({ version: '1' })] })
      .mockResolvedValue({ instance_id: 'inst-1', pins: [pin({ version: '2', source: 'rebound' })] })
    rebindPins.mockResolvedValue({
      instance_id: 'inst-1',
      changes: [{ kind: 'catalog_entry', ref: 'svc-a', prior_version: '1', new_version: '2' }],
      rebound_at: '2026-09-30T00:00:00Z',
    })
    renderPanel({ canRebind: true, instanceActive: true })
    const user = await openDialog()

    await user.type(screen.getByTestId('pin-rebind-new-version-input'), '2')
    await user.type(screen.getByTestId('pin-rebind-reason-input'), REASON)
    await user.click(screen.getByTestId('pin-rebind-submit'))

    await waitFor(() => expect(rebindPins).toHaveBeenCalledTimes(1))
    const [id, body, key] = rebindPins.mock.calls[0]
    expect(id).toBe('inst-1')
    expect(body).toEqual({ reason: REASON, entries: [{ kind: 'catalog_entry', ref: 'svc-a', version: '2' }] })
    expect(typeof key).toBe('string')
    expect((key as string).length).toBeGreaterThan(0)

    expect(await screen.findByTestId('pin-rebind-success')).toHaveTextContent('Moved svc-a from 1 to 2')
    await waitFor(() => expect(getPins).toHaveBeenCalledTimes(2))
    expect(await screen.findByText('Changed via rebind')).toBeInTheDocument()
    expect(screen.queryByTestId('pin-rebind-dialog')).not.toBeInTheDocument()
  })

  it('an empty changes array renders the "No change" line', async () => {
    getPins.mockResolvedValue({ instance_id: 'inst-1', pins: [pin()] })
    rebindPins.mockResolvedValue({ instance_id: 'inst-1', changes: [], rebound_at: 'x' })
    renderPanel({ canRebind: true, instanceActive: true })
    const user = await openDialog()
    await user.type(screen.getByTestId('pin-rebind-new-version-input'), '2')
    await user.type(screen.getByTestId('pin-rebind-reason-input'), 'r')
    await user.click(screen.getByTestId('pin-rebind-submit'))
    expect(await screen.findByTestId('pin-rebind-success')).toHaveTextContent('No change: already on that version')
  })

  it.each([
    [404, 'Case not found.'],
    [409, 'This case can no longer be rebound (finished, or being modified by someone else). Refresh and try again.'],
    [422, 'That version is not valid for this dependency, or the reason is missing.'],
    [403, 'You do not have permission to rebind this case.'],
    [500, 'Failed to rebind dependency.'],
  ])('status %i shows its message and keeps the dialog open', async (status, message) => {
    getPins.mockResolvedValue({ instance_id: 'inst-1', pins: [pin()] })
    rebindPins.mockRejectedValue({ status, message: 'x' })
    renderPanel({ canRebind: true, instanceActive: true })
    const user = await openDialog()
    await user.type(screen.getByTestId('pin-rebind-new-version-input'), '2')
    await user.type(screen.getByTestId('pin-rebind-reason-input'), 'r')
    await user.click(screen.getByTestId('pin-rebind-submit'))

    expect(await screen.findByTestId('pin-rebind-error')).toHaveTextContent(message)
    expect(screen.getByTestId('pin-rebind-dialog')).toBeInTheDocument()
  })

  it('a retry in the same open dialog reuses the key; reopening generates a new key', async () => {
    getPins.mockResolvedValue({ instance_id: 'inst-1', pins: [pin()] })
    rebindPins.mockRejectedValue({ status: 500 })
    renderPanel({ canRebind: true, instanceActive: true })
    const user = await openDialog()
    await user.type(screen.getByTestId('pin-rebind-new-version-input'), '2')
    await user.type(screen.getByTestId('pin-rebind-reason-input'), 'r')
    await user.click(screen.getByTestId('pin-rebind-submit'))
    await screen.findByTestId('pin-rebind-error')
    await user.click(screen.getByTestId('pin-rebind-submit'))
    await waitFor(() => expect(rebindPins).toHaveBeenCalledTimes(2))
    expect(rebindPins.mock.calls[1][2]).toBe(rebindPins.mock.calls[0][2])

    await user.click(screen.getByTestId('pin-rebind-cancel'))
    await user.click(screen.getByTestId(BTN))
    await user.type(screen.getByTestId('pin-rebind-new-version-input'), '2')
    await user.type(screen.getByTestId('pin-rebind-reason-input'), 'r')
    await user.click(screen.getByTestId('pin-rebind-submit'))
    await waitFor(() => expect(rebindPins).toHaveBeenCalledTimes(3))
    expect(rebindPins.mock.calls[2][2]).not.toBe(rebindPins.mock.calls[0][2])
  })
})

describe('REQ-432 EO-001/EO-002/EO-004 — per-instance pin display', () => {
  it('two cases each show their own pinned version (EO-001/EO-002)', async () => {
    getPins.mockImplementation(async (id: string) =>
      id === 'inst-old'
        ? { instance_id: id, pins: [pin({ version: '1' })] }
        : { instance_id: id, pins: [pin({ version: '2' })] },
    )
    renderPanel({ instanceId: 'inst-old' })
    renderPanel({ instanceId: 'inst-new' })

    await waitFor(() => expect(screen.getAllByTestId('instance-pins-panel')).toHaveLength(2))
    await waitFor(() => {
      const [oldPanel, newPanel] = screen.getAllByTestId('instance-pins-panel')
      expect(oldPanel).toHaveTextContent('svc-a')
      expect(oldPanel.textContent).toMatch(/svc-a.*1/)
      expect(oldPanel.textContent).not.toMatch(/Service2/)
      expect(newPanel.textContent).toMatch(/Service2/)
    })
  })

  it('retiring a service from the Services page leaves the running case pins panel, old version and Rebind action intact (EO-004, UI half)', async () => {
    // Scope, stated honestly: this proves the UI half of EO-004 only -- the
    // retire flow must not disturb, refetch-into-error, or hide the running
    // case's pin display. "The in-flight step completes" is a backend/pipeline
    // matter (pipeline step 03, and backend gap M5) and is NOT proven here.
    const svcRow = (status: string) => ({
      service_id: 'svc-a', endpoint_url: 'https://example.invalid/a', request_schema: '{}',
      response_schema: '{}', required_auth: 'NONE', timeout_ms: 5000, max_retries: 0, scope: 'global',
      owner_tenant_id: null, created_at: 'x', updated_at: 'x', version: '1', version_id: 'v1',
      status, published_at: 'x', retired_at: null,
    })
    listAllServices
      .mockResolvedValueOnce({ items: [svcRow('ACTIVE')], next_cursor: null })
      .mockResolvedValue({ items: [svcRow('RETIRED')], next_cursor: null })
    retireService.mockResolvedValue(svcRow('RETIRED'))
    getPins.mockResolvedValue({ instance_id: 'inst-1', pins: [pin({ version: '1' })] })

    const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    render(
      <QueryClientProvider client={qc}>
        <ServicesPage />
        <InstancePinsPanel instanceId="inst-1" canRebind instanceActive />
      </QueryClientProvider>,
    )
    const user = userEvent.setup()

    const panel = await screen.findByTestId('instance-pins-panel')
    await screen.findByTestId(BTN)
    expect(panel.textContent).toMatch(/svc-a.*1/)
    expect(getPins).toHaveBeenCalledTimes(1)

    await user.click(await screen.findByTestId('service-retire-btn-svc-a'))
    await user.click(screen.getByTestId('service-retire-confirm'))

    await waitFor(() => expect(retireService).toHaveBeenCalledWith('svc-a'))
    await waitFor(() => expect(screen.getByTestId('service-status-svc-a')).toHaveTextContent('RETIRED'))

    // The retire must not have invalidated/refetched the running case's pins,
    // and the panel must still show the old version, the Rebind action, and
    // no error surface.
    expect(getPins).toHaveBeenCalledTimes(1)
    expect(screen.getByTestId('instance-pins-panel').textContent).toMatch(/svc-a.*1/)
    expect(screen.getByTestId(BTN)).toBeInTheDocument()
    expect(screen.queryByText('Retry')).not.toBeInTheDocument()
    expect(screen.queryByText('Something went wrong loading this content.')).not.toBeInTheDocument()
  })
})
