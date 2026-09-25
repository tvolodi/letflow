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
 * src/api/__tests__/identity.members.test.ts (T4/T5/T5b/T5c); this file covers
 * the consequence at the component level.
 *
 * ── WHERE THE DISCRIMINATION LIVES (read before editing anything below) ─────
 *
 * WF-03 Step 4 measured this file against the pre-fix page (`queryFn` reverted
 * to `groupsApi.members(activeGroupId)`) in a throwaway worktree. In its
 * ORIGINAL form only ONE of its four cases went red — "the page queries the
 * drain" — and the design's own nominated headline assertion ("a second-page
 * member is not offered in the dropdown") stayed GREEN against the unfixed
 * page. The reason is structural: `useQuery` is mocked here (see below), so a
 * test that hands the component a ready-made complete member set exercises
 * `availableUsers`' set difference — which this fix did not change — rather
 * than the thing ISS-0816 fixed, that the page OBTAINS a complete set.
 *
 * The headline case below therefore no longer takes member data as an input.
 * It stubs the WIRE instead — `groupsApi.members`, the single-page call, is
 * the only thing doubled — and renders twice, the way react-query itself
 * works: pass one lets the page run its OWN `queryFn` and captures the promise
 * it returns; pass two feeds back exactly the value that `queryFn` produced.
 * The member set under assertion is thus whatever the PAGE fetched, not
 * whatever the test supplied. A page that dials `groupsApi.members` once sees
 * 50 members and offers `u-51` as addable; a page that dials the drain sees 51
 * and does not. Measured: both discriminating cases go red against the pre-fix
 * page, 2 of 4 rather than 1 of 4.
 *
 * Mocking pattern: `useQuery`/`useMutation`/`useQueryClient` mocked directly,
 * the EntityCrudPage.test.tsx / DlqPage.pagination.test.tsx precedent. The
 * `@/api/identity` module is NOT module-mocked — it is the real module with
 * `vi.spyOn` applied per test, because `listAllMembers` reaches its page fetch
 * through `groupsApi.members`, so doubling that one property lets the REAL
 * drain run against a stubbed wire. No msw, no axios-mock-adapter, no raw
 * fetch (DIRECTIVE T-2).
 *
 * NOTE for whoever writes the next GroupsPage test: rendering this page's
 * member dialog against REAL `@tanstack/react-query` under jsdom spins the
 * event loop indefinitely — measured on this branch against the UNMODIFIED
 * page as well as the modified one, so it predates ISS-0816 and is not caused
 * by the drain. Filed as ISS-0824; not fixed here (out of scope). If ISS-0824
 * is ever fixed, promote this file to a real `QueryClientProvider` and the
 * two-pass helper below becomes unnecessary.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, fireEvent } from '@testing-library/react'
import type { GroupMember, GroupMemberPage, User } from '@/types/api'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), isPending: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))

import { useQuery } from '@tanstack/react-query'
import { groupsApi } from '@/api/identity'
import GroupsPage from '@/pages/admin/GroupsPage'

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

/** The cursor page one advertises. Only a drain that FORWARDS it ever sees
 *  `u-51`; a single-page call stops at the fifty. */
const PAGE_TWO_CURSOR = 'cursor-page-2'

/** One genuine non-member, so a populated dropdown is distinguishable from an
 *  empty one — a missing `u-51` option must not be satisfiable by a dropdown
 *  that renders nothing at all. */
const NON_MEMBER_ID = 'u-99'

type MembersData = { items: GroupMember[]; truncated?: boolean }

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

/**
 * Dispatches on `queryKey[3]`, the sub-group segment of
 * `['tenant', <id>, 'admin', <kind>, ...]` (web/src/api/queryKeys.ts:130-145).
 *
 * `onMembersQueryFn` decides what happens to the page's OWN members `queryFn`.
 * The default invokes and discards it, which is what the spy-based cases want.
 * The two-pass helper below supplies a capture instead, so the value the page
 * produced can be fed back as the query's data.
 */
function installUseQuery(
  members: MembersData | undefined,
  users: User[],
  onMembersQueryFn: (queryFn: () => unknown) => void = (queryFn) => void queryFn(),
) {
  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey, queryFn, enabled } = opts as QueryOpts
    switch (queryKey[3]) {
      case 'groups':
        return result({ items: [GROUP], total: 1 })
      case 'group-members':
        if (enabled !== false && queryFn) onMembersQueryFn(queryFn)
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

/**
 * Doubles ONLY the single-page wire call `groupsApi.members`, leaving
 * `groupsApi.listAllMembers` real. Page one holds the first fifty members and
 * advertises `PAGE_TWO_CURSOR`; page two holds `u-51` and terminates.
 *
 * Because the drain reaches its fetch through `groupsApi.members` (see
 * web/src/api/identity.ts), this stub serves BOTH the fixed page (which dials
 * the drain, so both pages are fetched) and the pre-fix page (which dials
 * `members` once with no cursor, so only page one is). That is the whole
 * mechanism by which the headline assertion discriminates.
 */
function stubMembersWire() {
  return vi
    .spyOn(groupsApi, 'members')
    .mockImplementation(async (_id: string, params?: { cursor?: string; page_size?: number }) => {
      const page: GroupMemberPage =
        params?.cursor === undefined
          ? {
              items: FIRST_PAGE_MEMBER_IDS.map(groupMember),
              next_cursor: PAGE_TWO_CURSOR,
              count: FIRST_PAGE_MEMBER_IDS.length,
            }
          : { items: [groupMember(SECOND_PAGE_MEMBER_ID)], next_cursor: null, count: 1 }
      return page
    })
}

/**
 * Renders the member dialog twice, the way react-query itself resolves a
 * query: pass one lets the page run its own `queryFn` and captures the promise
 * it returned; pass two feeds the value that `queryFn` actually produced back
 * in as the query's `data`.
 *
 * This is what keeps the assertions honest under the mocked-`useQuery`
 * constraint ISS-0824 forces: the member set the component renders from is the
 * one the PAGE fetched, never one the test handed it.
 */
async function renderWithPageFetchedMembers(users: User[]) {
  let produced: unknown

  installUseQuery(undefined, users, (queryFn) => {
    produced = queryFn()
  })
  openMembersDialog()
  cleanup()

  expect(produced).toBeInstanceOf(Promise)
  const data = (await produced) as MembersData

  // Pass two: no re-invocation, so the drain runs exactly once per test.
  installUseQuery(data, users, () => {})
  return { container: openMembersDialog(), data }
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('ISS-0816 AC3 (T6) — GroupsPage derives the Add-member list from the COMPLETE member set', () => {
  it('a second-page member is not offered in the Add member dropdown', async () => {
    // DISCRIMINATING — measured red against the pre-fix page. Do not "simplify"
    // this case by handing `installUseQuery` a ready-made member list: that is
    // precisely the form that stayed green against `groupsApi.members` and
    // tested only `availableUsers`' set difference, which this fix never
    // touched. The member set below is produced by the page's own queryFn
    // against a stubbed wire.
    const wire = stubMembersWire()

    const { container, data } = await renderWithPageFetchedMembers(
      [...ALL_MEMBER_IDS, NON_MEMBER_ID].map(directoryUser),
    )
    const values = optionValues(container)

    // The control is populated: the one genuine non-member IS offered.
    expect(values).toContain(NON_MEMBER_ID)

    // THE REGRESSION ASSERTION — the design's own nominated one (§7 row T6),
    // and it is deliberately FIRST among the substantive checks so that it is
    // the assertion that fires against a pre-fix page rather than one of the
    // mechanism checks below. `u-51` only ever appears on the SECOND page of
    // the members response; pre-fix it was offered here as an addable user.
    // Measured under mutation M1: "expected [ '', 'u-51', 'u-99' ] not to
    // contain 'u-51'".
    expect(values).not.toContain(SECOND_PAGE_MEMBER_ID)

    // ...and no first-page member is offered either.
    expect(values).not.toContain('u-1')
    expect(values).not.toContain('u-50')

    // Exactly the placeholder plus the single non-member.
    expect(values).toEqual(['', NON_MEMBER_ID])

    // Corroboration of the mechanism behind the assertion above: the page
    // followed the cursor — two wire calls, the second carrying page one's
    // `next_cursor` — and held 51 members, not 50.
    expect(wire).toHaveBeenCalledTimes(2)
    expect(wire.mock.calls[0][1]?.cursor).toBeUndefined()
    expect(wire.mock.calls[1][1]?.cursor).toBe(PAGE_TWO_CURSOR)
    expect(data.items.map((member) => member.id)).toEqual(ALL_MEMBER_IDS)
  })

  it('the page queries the drain, never the single-page members call', () => {
    // DISCRIMINATING — and until WF-03 Step 4 rebuilt the case above, this was
    // the ONLY case in this file that went red against the pre-fix page
    // (measured: 1 failed, 3 passed). It is not boilerplate and it is not
    // redundant with the case above: this one pins WHICH function the page
    // dials, by spying on the identity module while the `useQuery` double
    // invokes the page's real `queryFn`; the case above pins the CONSEQUENCE
    // of dialing the right one. Deleting either leaves ISS-0816's behavioural
    // claim resting on a single assertion. See REVIEWER OBS-1,
    // handoffs/WF03-ISS0816-20260925/step-03d-reviewer.json.
    const drain = vi
      .spyOn(groupsApi, 'listAllMembers')
      .mockResolvedValue({ items: [groupMember('u-1')], truncated: false })
    const singlePage = stubMembersWire()

    installUseQuery({ items: [groupMember('u-1')], truncated: false }, [directoryUser(NON_MEMBER_ID)])
    openMembersDialog()

    expect(drain).toHaveBeenCalledWith('g-1')
    expect(singlePage).not.toHaveBeenCalled()
  })

  it('renders no truncation notice on the normal path', () => {
    // The wire is stubbed in every case in this file, including the two
    // non-discriminating ones, so no test here can reach `window.fetch` under
    // any mutation of the page.
    stubMembersWire()
    vi.spyOn(groupsApi, 'listAllMembers').mockResolvedValue({
      items: ALL_MEMBER_IDS.map(groupMember),
      truncated: false,
    })
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
    // NON-DISCRIMINATING by construction: the pre-fix page has no `truncated`
    // to report, so this case asserts the notice's own wiring, not the fix.
    stubMembersWire()
    vi.spyOn(groupsApi, 'listAllMembers').mockResolvedValue({
      items: ALL_MEMBER_IDS.map(groupMember),
      truncated: true,
    })
    installUseQuery(
      { items: ALL_MEMBER_IDS.map(groupMember), truncated: true },
      [directoryUser(NON_MEMBER_ID)],
    )

    openMembersDialog()

    expect(screen.getByText(/this list is capped/i)).toBeInTheDocument()
  })
})
