// @vitest-environment jsdom
/**
 * REQ-336 AC2/AC6 — TagListPage:
 *  - AC2: list renders real records from POST /entities/query (mocked at the
 *    useQuery boundary, real entitiesApi.queryRecords call verified
 *    separately in entities.test.ts), paginates via the query route's
 *    cursor (not a client-side slice), and offers a create action.
 *  - AC6: delete requires an explicit confirmation step -- the DELETE
 *    mutation must NOT fire on the first (list-row) click, only after the
 *    ConfirmDialog's own confirm button is clicked.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, fireEvent, within } from '@testing-library/react'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), isPending: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))

vi.mock('@/api/entities', () => ({
  entitiesApi: {
    getActiveDefinition: vi.fn(),
    queryRecords: vi.fn(),
    createRecord: vi.fn(),
    updateRecord: vi.fn(),
    deleteRecord: vi.fn(),
  },
}))

import { useQuery, useMutation } from '@tanstack/react-query'
import TagListPage from '@/pages/entities/TagListPage'
import type { EntityDefinition, EntityRecordsPage } from '@/types/api'

const mockUseQuery = vi.mocked(useQuery)
const mockUseMutation = vi.mocked(useMutation)

const DEFINITION: EntityDefinition = {
  id: 'def-1',
  name: 'tag',
  display_name: 'Tag',
  definition: {
    name: 'tag',
    display_name: 'Tag',
    fields: [{ name: 'name', type: 'string', required: true, queried: true }],
    constraints: [{ name: 'uq_tag_name', type: 'unique', fields: ['name'] }],
  },
  content_hash: 'deadbeef',
  logical_shape_version: 'cafebabe',
  artifact_version_id: 'av-1',
  status: 'active',
  inserted_at: '2026-01-01T00:00:00Z',
}

const PAGES: Record<string, EntityRecordsPage> = {
  __page1__: {
    items: [
      { record_id: 'r1', field_values: { name: 'algebra' }, deleted: false, entity_def_version: 'v1', last_event_global_seq: 1 },
    ],
    next_cursor: 'cursor-2',
  },
  'cursor-2': {
    items: [
      { record_id: 'r2', field_values: { name: 'geometry' }, deleted: false, entity_def_version: 'v1', last_event_global_seq: 2 },
    ],
    next_cursor: null,
  },
}

let requestedCursors: (string | undefined)[]
let deleteMutateSpy: ReturnType<typeof vi.fn>

function installMocks(): void {
  requestedCursors = []
  deleteMutateSpy = vi.fn()

  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey } = opts as { queryKey: readonly unknown[] }
    if (queryKey[1] === 'definition') {
      return {
        data: DEFINITION,
        isLoading: false,
        isError: false,
        error: null,
        refetch: vi.fn(),
      } as unknown as ReturnType<typeof useQuery>
    }
    const filters = (queryKey[3] ?? {}) as { cursor?: string }
    requestedCursors.push(filters.cursor)
    const page = PAGES[filters.cursor ?? '__page1__']
    return {
      data: page,
      isLoading: false,
      isError: false,
      error: null,
      refetch: vi.fn(),
    } as unknown as ReturnType<typeof useQuery>
  })

  mockUseMutation.mockImplementation((opts: unknown) => {
    const { mutationFn } = opts as { mutationFn: (v: unknown) => unknown }
    // Route delete mutations through the spy so the test can assert whether
    // the DELETE call actually fired.
    return {
      mutate: (variables: unknown) => {
        deleteMutateSpy(variables)
        void mutationFn(variables)
      },
      isPending: false,
    } as unknown as ReturnType<typeof useMutation>
  })
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-336 AC2 — TagListPage list + pagination + create action', () => {
  it('renders real records for page 1, offers a create action, and paginates via cursor (not a client slice)', () => {
    installMocks()
    render(<TagListPage />)

    expect(screen.getByText('algebra')).toBeInTheDocument()
    expect(screen.getByTestId('tag-create-action')).toBeInTheDocument()

    const nextButton = within(screen.getByTestId('pagination-next')).getByRole('button')
    fireEvent.click(nextButton)

    expect(screen.getByText('geometry')).toBeInTheDocument()
    expect(screen.queryByText('algebra')).not.toBeInTheDocument()
    // The cursor actually sent came from the SERVER's own next_cursor, not a
    // client-side re-slice of an already-fetched page.
    expect(requestedCursors[requestedCursors.length - 1]).toBe('cursor-2')
  })
})

describe('REQ-336 AC6 — delete requires an explicit confirmation step', () => {
  it('does NOT call deleteRecord on the first (row) click; only after ConfirmDialog is confirmed', () => {
    installMocks()
    render(<TagListPage />)

    fireEvent.click(screen.getByTestId('tag-delete-r1'))

    // First click only opens the confirmation dialog -- no DELETE call yet.
    expect(deleteMutateSpy).not.toHaveBeenCalled()
    expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument()

    fireEvent.click(screen.getByTestId('confirm-dialog-confirm'))

    expect(deleteMutateSpy).toHaveBeenCalledWith('r1')
  })

  it('cancelling the confirmation dialog never calls deleteRecord', () => {
    installMocks()
    render(<TagListPage />)

    fireEvent.click(screen.getByTestId('tag-delete-r1'))
    fireEvent.click(screen.getByTestId('confirm-dialog-cancel'))

    expect(deleteMutateSpy).not.toHaveBeenCalled()
    expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument()
  })
})
