// @vitest-environment jsdom
/**
 * Unit tests — REQ-371 AC1: rollback/withdraw action reachable from
 * DefinitionListPage.tsx, gated to PLATFORM_ADMIN + ACTIVE-status rows only.
 *
 * See lib/letflow/design/req371-rollback-withdrawal-screen.md §6 and
 * DefinitionListPage.tsx:211 — the exact gating condition under test is
 * `def.status === 'ACTIVE' && isPlatformAdmin`, read directly from the
 * component (not assumed). Mocks `@/hooks/useDefinitions` directly, matching
 * `DefinitionRollbackPage.test.tsx` / `DefinitionEditorPage.promote.test.tsx`'s
 * established convention of mocking the hooks module rather than the
 * underlying API client, plus `@/auth/AuthContext` and `react-router-dom`'s
 * `useNavigate`.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

// ── Mocks ────────────────────────────────────────────────────────────────────

const mockNavigate = vi.fn()

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return {
    ...actual,
    useNavigate: vi.fn(() => mockNavigate),
  }
})

vi.mock('@tanstack/react-query', async () => {
  const actual = await vi.importActual('@tanstack/react-query')
  return {
    ...(actual as object),
    useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
  }
})

vi.mock('@/hooks/useDefinitions', () => ({
  useDefinitions: vi.fn(),
  useDefinitionVersions: vi.fn(() => ({ data: undefined, isLoading: false })),
  useActivateDefinition: vi.fn(() => ({ mutate: vi.fn(), isPending: false })),
  useArchiveDefinition: vi.fn(() => ({ mutate: vi.fn(), isPending: false })),
  useCreateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
  useDefinitionSearch: vi.fn(() => ({ data: undefined, isLoading: false, isFetching: false })),
  definitionKeys: { all: ['definitions'], list: () => ['definitions', 'list'] },
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/api/definitions', () => ({
  definitionsApi: {
    importJson: vi.fn(),
  },
}))

import { useAuth } from '@/auth/AuthContext'
import { useDefinitions } from '@/hooks/useDefinitions'
import DefinitionListPage from '@/pages/definitions/DefinitionListPage'

const ACTIVE_DEF = {
  id: 'def-active-1',
  name: 'approvals',
  version: '2.0.0',
  status: 'ACTIVE' as const,
  description: '',
  graph: { nodes: [], edges: [] },
  created_by: 'admin-user',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
}

const DRAFT_DEF = { ...ACTIVE_DEF, id: 'def-draft-1', status: 'DRAFT' as const }

function mockAuth(roles: string[]) {
  vi.mocked(useAuth).mockReturnValue({
    session: {
      token: 't',
      display_name: 'op-1',
      roles,
      loginSource: null,
      tenant_slug: null,
      tenant_display_name: null,
      tenant_id: null,
      tenant_type: null,
      production_tenant_display_name: null,
    },
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  } as unknown as ReturnType<typeof useAuth>)
}

function mockDefinitions(items: Array<typeof ACTIVE_DEF | typeof DRAFT_DEF>) {
  vi.mocked(useDefinitions).mockReturnValue({
    data: { items },
    isLoading: false,
    isError: false,
    error: null,
    refetch: vi.fn(),
  } as unknown as ReturnType<typeof useDefinitions>)
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('DefinitionListPage — rollback button gating (REQ-371 AC1)', () => {
  it('TC-REQ371-07a: btn-rollback renders for an ACTIVE-status row when the session has PLATFORM_ADMIN', () => {
    mockAuth(['PLATFORM_ADMIN'])
    mockDefinitions([ACTIVE_DEF])

    render(<DefinitionListPage />)

    expect(screen.getByTestId(`btn-rollback-${ACTIVE_DEF.id}`)).toBeInTheDocument()
    expect(screen.getByTestId(`btn-rollback-${ACTIVE_DEF.id}`)).toHaveTextContent('Rollback…')
  })

  it('TC-REQ371-07b: btn-rollback is absent for a non-ACTIVE row, even as PLATFORM_ADMIN', () => {
    mockAuth(['PLATFORM_ADMIN'])
    mockDefinitions([DRAFT_DEF])

    render(<DefinitionListPage />)

    expect(screen.queryByTestId(`btn-rollback-${DRAFT_DEF.id}`)).not.toBeInTheDocument()
  })

  it('TC-REQ371-07c: btn-rollback is absent for a non-PLATFORM_ADMIN session, even on an ACTIVE row', () => {
    mockAuth(['PROCESS_DESIGNER'])
    mockDefinitions([ACTIVE_DEF])

    render(<DefinitionListPage />)

    expect(screen.queryByTestId(`btn-rollback-${ACTIVE_DEF.id}`)).not.toBeInTheDocument()
  })

  it('TC-REQ371-07d: clicking btn-rollback navigates to /definitions/:id/rollback', () => {
    mockAuth(['PLATFORM_ADMIN'])
    mockDefinitions([ACTIVE_DEF])

    render(<DefinitionListPage />)

    screen.getByTestId(`btn-rollback-${ACTIVE_DEF.id}`).click()

    expect(mockNavigate).toHaveBeenCalledWith(`/definitions/${ACTIVE_DEF.id}/rollback`)
  })
})
