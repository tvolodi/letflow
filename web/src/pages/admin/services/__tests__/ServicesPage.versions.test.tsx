// @vitest-environment jsdom
/** REQ-432 §3 — publish/retire controls on ServicesPage, PLATFORM_ADMIN-gated. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

const listAll = vi.fn()
const listForTenant = vi.fn()
const publishVersion = vi.fn()
const retire = vi.fn()
let roles: string[] = ['PLATFORM_ADMIN']

vi.mock('@/api/services', () => ({
  servicesApi: {
    listAll: (...a: unknown[]) => listAll(...a),
    listForTenant: (...a: unknown[]) => listForTenant(...a),
    publishVersion: (...a: unknown[]) => publishVersion(...a),
    retire: (...a: unknown[]) => retire(...a),
  },
}))

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: { token: 't', display_name: 'Admin', roles, loginSource: 'oidc' as const, tenant_slug: null, tenant_display_name: null, tenant_id: 'tid-services-fixture', tenant_type: null, production_tenant_display_name: null },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import ServicesPage from '../ServicesPage'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  roles = ['PLATFORM_ADMIN']
})

function svc(overrides: Record<string, unknown> = {}) {
  return {
    service_id: 'svc-a',
    endpoint_url: 'https://example.invalid/a',
    request_schema: '{}',
    response_schema: '{}',
    required_auth: 'NONE',
    timeout_ms: 5000,
    max_retries: 0,
    scope: 'global',
    owner_tenant_id: null,
    created_at: 'x',
    updated_at: 'x',
    version: '1',
    version_id: 'v1',
    status: 'ACTIVE',
    published_at: 'x',
    retired_at: null,
    ...overrides,
  }
}

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <ServicesPage />
    </QueryClientProvider>,
  )
}

describe('ServicesPage — REQ-432 publish/retire', () => {
  it('PLATFORM_ADMIN sees Version/Status cells and both buttons', async () => {
    listAll.mockResolvedValue({ items: [svc()], next_cursor: null })
    renderPage()
    expect(await screen.findByTestId('service-publish-btn-svc-a')).toBeInTheDocument()
    expect(screen.getByTestId('service-retire-btn-svc-a')).toBeInTheDocument()
    expect(screen.getByTestId('service-version-svc-a')).toHaveTextContent('1')
    expect(screen.getByTestId('service-status-svc-a')).toHaveTextContent('ACTIVE')
  })

  it('a non-admin sees neither button and "—" for missing version/status', async () => {
    roles = ['TASK_WORKER']
    listForTenant.mockResolvedValue({ items: [svc({ version: undefined, status: undefined })], next_cursor: null })
    renderPage()
    expect(await screen.findByTestId('service-version-svc-a')).toHaveTextContent('—')
    expect(screen.getByTestId('service-status-svc-a')).toHaveTextContent('—')
    expect(screen.queryByTestId('service-publish-btn-svc-a')).not.toBeInTheDocument()
    expect(screen.queryByTestId('service-retire-btn-svc-a')).not.toBeInTheDocument()
  })

  it('publish submits (serviceId, body) with prefilled fields and refreshes the list', async () => {
    listAll
      .mockResolvedValueOnce({ items: [svc()], next_cursor: null })
      .mockResolvedValue({ items: [svc({ version: '2' })], next_cursor: null })
    publishVersion.mockResolvedValue(svc({ version: '2' }))
    renderPage()
    const user = userEvent.setup()

    await user.click(await screen.findByTestId('service-publish-btn-svc-a'))
    expect(screen.getByTestId('service-publish-endpoint-input')).toHaveValue('https://example.invalid/a')
    await user.type(screen.getByTestId('service-publish-version-input'), '2')
    await user.click(screen.getByTestId('service-publish-submit'))

    await waitFor(() => expect(publishVersion).toHaveBeenCalledTimes(1))
    expect(publishVersion).toHaveBeenCalledWith('svc-a', {
      version: '2',
      endpoint_url: 'https://example.invalid/a',
      timeout_ms: 5000,
      auth_method: 'NONE',
      request_schema: '{}',
      response_schema: '{}',
    })
    await waitFor(() => expect(screen.getByTestId('service-version-svc-a')).toHaveTextContent('2'))
    expect(listAll).toHaveBeenCalledTimes(2)
    expect(screen.queryByTestId('service-publish-modal')).not.toBeInTheDocument()
  })

  it('publish 409 shows the duplicate-version message and keeps the modal open', async () => {
    listAll.mockResolvedValue({ items: [svc()], next_cursor: null })
    publishVersion.mockRejectedValue({ status: 409 })
    renderPage()
    const user = userEvent.setup()
    await user.click(await screen.findByTestId('service-publish-btn-svc-a'))
    await user.type(screen.getByTestId('service-publish-version-input'), '1')
    await user.click(screen.getByTestId('service-publish-submit'))
    expect(await screen.findByTestId('service-publish-error')).toHaveTextContent('That version already exists for this service.')
    expect(screen.getByTestId('service-publish-modal')).toBeInTheDocument()
  })

  it('retire confirm calls retire(serviceId) and refreshes the list', async () => {
    listAll
      .mockResolvedValueOnce({ items: [svc()], next_cursor: null })
      .mockResolvedValue({ items: [svc({ status: 'RETIRED' })], next_cursor: null })
    retire.mockResolvedValue(svc({ status: 'RETIRED' }))
    renderPage()
    const user = userEvent.setup()
    await user.click(await screen.findByTestId('service-retire-btn-svc-a'))
    expect(screen.getByTestId('service-retire-modal')).toHaveTextContent('Cases already running keep the version they started with')
    await user.click(screen.getByTestId('service-retire-confirm'))

    await waitFor(() => expect(retire).toHaveBeenCalledWith('svc-a'))
    await waitFor(() => expect(screen.getByTestId('service-status-svc-a')).toHaveTextContent('RETIRED'))
  })

  it('retire 409 shows the already-retired message', async () => {
    listAll.mockResolvedValue({ items: [svc()], next_cursor: null })
    retire.mockRejectedValue({ status: 409 })
    renderPage()
    const user = userEvent.setup()
    await user.click(await screen.findByTestId('service-retire-btn-svc-a'))
    await user.click(screen.getByTestId('service-retire-confirm'))
    expect(await screen.findByTestId('service-retire-error')).toHaveTextContent('This service is already retired.')
  })

  it('Retire is disabled (not hidden) on a RETIRED row', async () => {
    listAll.mockResolvedValue({ items: [svc({ status: 'RETIRED' })], next_cursor: null })
    renderPage()
    expect(await screen.findByTestId('service-retire-btn-svc-a')).toBeDisabled()
  })
})
