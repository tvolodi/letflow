// @vitest-environment jsdom
/**
 * ISS-0816 AC3, test row T6 — the re-add bug is gone.
 *
 * Authority: lib/letflow/design/iss-0816-cursorpage-has-more-audit.md §3(c),
 * §6.2 and §7 row T6.
 *
 * The defect: `GroupsPage` fetched ONE page of group members (backend default
 * page size 50, `lib/letflow/api/pagination.ex:51`) and computed
 * `availableUsers` by subtracting that set from the user list. Every member
 * from the 51st on was therefore absent from the member id set and was offered
 * in the "Add member" dropdown as if they were not a member. A truncation
 * notice cannot repair that: the notice sits on the member LIST, while the
 * wrong value is presented at a DIFFERENT control (design INV-D).
 *
 * The fix: the page consumes `groupsApi.listAllMembers`, which follows
 * `next_cursor` to exhaustion under a bounded cap, so the set difference is
 * computed from the complete collection. The drain itself is covered by
 * src/api/__tests__/identity.members.test.ts (T4/T5/T5b); this file covers the
 * consequence at the component level.
 *
 * Mocking pattern: `useQuery`/`useMutation`/`useQueryClient` mocked directly,
 * the EntityCrudPage.test.tsx / DlqPage.pagination.test.tsx precedent. No msw,
 * no axios-mock-adapter, no raw fetch (DIRECTIVE T-2). The `useQuery` double
 * dispatches on the query key AND invokes the real `queryFn`, so the assertion
 * that the page queries the DRAIN (not a single page) is carried by a spy on
 * `groupsApi.listAllMembers` rather than by inspection of the source.
 *
 * NOTE for whoever writes the next GroupsPage test: rendering this page's
 * member dialog against REAL `@tanstack/react-query` under jsdom spins the
 * event loop indefinitely — measured on this branch against the UNMODIFIED
 * page as well as the modified one, so it predates ISS-0816 and is not caused
 * by the drain. Reported to ORCH; not fixed here (out of scope).
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, fireEvent } from '@testing-library/react'
import type { GroupMember, User } from '@/types/api'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), isPending: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))

const listAllMembers = vi.fn()
const listMembersPage = vi.fn()

vi.mock('@/api/identity', () => ({
  groupsApi: {
    list: vi.fn(),
    listAllMembers: (...args: unknown[]) => listAllMembers(...args),
    members: (...args: unknown[]) => listMembersPage(...args),
    create: vi.fn(),
    delete: vi.fn(),
    addMember: vi.fn(),
    removeMembers: vi.fn(),
  },
  usersApi: { list: vi.fn() },
}))

/** Synthetic, clearly-fake tenant id — not a real platform tenant. The page
 *  never renders it; `useTenantScopedQueryKeys` just needs a session. */
const FIXTURE_TENANT_ID = 'tid-groups-members-fixture-tenant'

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: {
      token: 't',
      display_name: 'Admin',
      roles: ['PLATFORM_ADMIN'],
      loginSource: 'oidc',
      tenant_slug: null,
      tenant_display_name: null,
      tenant_id: FIXTURE_TENANT_ID,
      tenant_type: null,
      production_tenant_display_name: null,
    },
    isAuthenticated: true,
  }),
}))

import { useQuery } from '@tanstack/react-query'
import GroupsPage from '@/pages/admin/GroupsPage'

const mockUseQuery = vi.mocked(useQuery)

const GROUP = {
  id: 'g-1',
  group_id: 'g-1',
  name: 'ops',
  display_name: 'Operations',
  description: 'Ops team',
  is_system: false,
  member_count: 51,
}

function groupMember(id: string): GroupMember {
  return {
    id,
    username: id,
    display_name: `User ${id}`,
    email: `${id}@example.test`,
    status: 'active',
    auth_source: 'internal',
    inserted_at: '2026-09-01T00:00:00Z',
    updated_at: '2026-09-02T00:00:00Z',
  }
}

function directoryUser(id: string): User {
  return {
    id,
    username: id,
    email: `${id}@example.test`,
    display_name: `User ${id}`,
    status: 'ACTIVE',
  } as User
}

/** A member set spanning two backend pages: fifty on page one, `u-51` on page
 *  two. Pre-fix, `u-51` was invisible to `availableUsers`. */
const FIRST_PAGE_MEMBER_IDS = Array.from({ length: 50 }, (_, i) => `u-${i + 1}`)
const SECOND_PAGE_MEMBER_ID = 'u-51'
const ALL_MEMBER_IDS = [...FIRST_PAGE_MEMBER_IDS, SECOND_PAGE_MEMBER_ID]

/** One genuine non-member, so a populated dropdown is distinguishable from an
 *  empty one — a missing `u-51` option must not be satisfiable by a dropdown
 *  that renders nothing at all. */
const NON_MEMBER_ID = 'u-99'

interface QueryOpts {
  queryKey: readonly unknown[]
  queryFn?: () => unknown
  enabled?: boolean
}

function result(data: unknown) {
  return {
    data,
    isLoading: false,
    isFetching: false,
    isError: false,
    error: null,
    refetch: vi.fn(),
  } as never
}

/** Dispatches on `queryKey[3]`, the sub-group segment of
 *  `['tenant', <id>, 'admin', <kind>, ...]` (web/src/api/queryKeys.ts:130-145),
 *  and invokes the page's own `queryFn` for the members query so the spy sees
 *  which API function the page actually calls. */
function installUseQuery(members: { items: GroupMember[]; truncated: boolean }, users: User[]) {
  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey, queryFn, enabled } = opts as QueryOpts
    switch (queryKey[3]) {
      case 'groups':
        return result({ items: [GROUP], total: 1 })
      case 'group-members':
        if (enabled !== false && queryFn) void queryFn()
        return result(members)
      default:
        return result({ items: users, total: users.length, page: 1, page_size: 200 })
    }
  })
}

function openMembersDialog() {
  const { container } = render(<GroupsPage />)
  const manage = Array.from(container.querySelectorAll('button')).find((button) =>
    button.textContent?.includes('Manage members'),
  )
  expect(manage).toBeDefined()
  fireEvent.click(manage as HTMLButtonElement)
  return container
}

function optionValues(container: HTMLElement): string[] {
  return Array.from(container.querySelectorAll('option')).map((option) => option.value)
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('ISS-0816 AC3 (T6) — GroupsPage derives the Add-member list from the COMPLETE member set', () => {
  it('a second-page member is not offered in the Add member dropdown', () => {
    installUseQuery(
      { items: ALL_MEMBER_IDS.map(groupMember), truncated: false },
      [...ALL_MEMBER_IDS, NON_MEMBER_ID].map(directoryUser),
    )

    const values = optionValues(openMembersDialog())

    // The control is populated: the one genuine non-member IS offered.
    expect(values).toContain(NON_MEMBER_ID)

    // The regression assertion. `u-51` only ever appears on the SECOND page of
    // the members response; pre-fix it was offered here as an addable user.
    expect(values).not.toContain(SECOND_PAGE_MEMBER_ID)

    // ...and no first-page member is offered either.
    expect(values).not.toContain('u-1')
    expect(values).not.toContain('u-50')

    // Exactly the placeholder plus the single non-member.
    expect(values).toEqual(['', NON_MEMBER_ID])
  })

  it('the page queries the drain, never the single-page members call', () => {
    installUseQuery({ items: [groupMember('u-1')], truncated: false }, [directoryUser(NON_MEMBER_ID)])

    openMembersDialog()

    expect(listAllMembers).toHaveBeenCalledWith('g-1')
    expect(listMembersPage).not.toHaveBeenCalled()
  })

  it('renders no truncation notice on the normal path', () => {
    installUseQuery(
      { items: ALL_MEMBER_IDS.map(groupMember), truncated: false },
      [directoryUser(NON_MEMBER_ID)],
    )

    openMembersDialog()

    expect(screen.getByText(/current members/i)).toBeInTheDocument()
    expect(screen.queryByText(/this list is capped/i)).not.toBeInTheDocument()
  })

  it('states the list is capped when the bounded drain reports truncated', () => {
    // AC3's "or explicitly states the list is truncated" branch, reached only in
    // the pathological case where the 20-request cap stopped the drain asking
    // (design §6.1). The notice does not replace the fix — it reports the bound.
    installUseQuery(
      { items: ALL_MEMBER_IDS.map(groupMember), truncated: true },
      [directoryUser(NON_MEMBER_ID)],
    )

    openMembersDialog()

    expect(screen.getByText(/this list is capped/i)).toBeInTheDocument()
  })
})
