import { client } from './client'
import type {
  User,
  Group,
  GroupListResponse,
  GroupMember,
  GroupMemberAddResult,
  GroupMemberPage,
  Role,
  RolePermission,
  ApiToken,
  IssuedToken,
  PagedResponse,
} from '@/types/api'

/** `@max_page_size` (`lib/letflow/api/pagination.ex:50`) — the largest page the
 *  server accepts, so `groupsApi.listAllMembers` makes the fewest round trips. */
const MEMBER_DRAIN_PAGE_SIZE = 200

/** Safety bound on `groupsApi.listAllMembers`: 20 x 200 = 4 000 members. Chosen
 *  as a bound, not derived from any measured group size (ISS-0816 OQ-2); it
 *  exists so a malformed or non-advancing cursor cannot spin the browser. */
const MEMBER_DRAIN_MAX_REQUESTS = 20

// ── Users ──────────────────────────────────────────────────────────────────────

export const usersApi = {
  list: (params?: { page?: number; page_size?: number; search?: string; status?: string }) =>
    client.get<PagedResponse<User>>('/api/v1/identity/users', params as Record<string, unknown>),

  get: (id: string) =>
    client.get<User>(`/api/v1/identity/users/${id}`),

  create: (body: { username: string; email: string; display_name: string; password: string; role_ids?: string[] }) =>
    client.post<User>('/api/v1/identity/users', body),

  update: (id: string, body: Partial<{ display_name: string; email: string; status: 'ACTIVE' | 'INACTIVE'; is_active: boolean; role_ids: string[]; group_ids: string[] }>) =>
    client.patch<User>(`/api/v1/identity/users/${id}`, body),

  resetPassword: (id: string, newPassword: string) =>
    client.post<void>(`/api/v1/users/${id}/reset-password`, { password: newPassword }),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/users/${id}`),
}

// ── Groups ─────────────────────────────────────────────────────────────────────

export const groupsApi = {
  list: () =>
    client.get<GroupListResponse>('/api/v1/identity/groups'),

  // `groupsApi.get(id)` and `groupsApi.update(id, body)` were removed in ISS-0765
  // (run `WF03-ISS0765-20260924`). `GET /groups/:id` and `PATCH|PUT /groups/:id` do not
  // exist in `Letflow.Routers.Identity.__authz_routes__/0` at any prefix, and
  // `lib/letflow/identity.ex` has no `get_group/2` or `update_group/3` — these are
  // unimplemented operations, not mis-prefixed ones. Do not re-add a client function for
  // either until a backend route exists; adding one is a WF-01 requirement.

  create: (body: { name: string; display_name: string; description?: string }) =>
    client.post<Group>('/api/v1/identity/groups', body),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/identity/groups/${id}`),

  addMember: (id: string, userId: string) =>
    client.post<GroupMemberAddResult>(`/api/v1/identity/groups/${id}/members`, { user_id: userId }),

  removeMembers: (id: string, userId: string) =>
    client.delete<void>(`/api/v1/identity/groups/${id}/members/${userId}`),

  /** One page of `GET /api/v1/identity/groups/:id/members`, faithfully. The
   *  envelope is `Pagination.Page`'s three keys (`GroupMemberPage`), returned
   *  unreshaped — no `.items` unwrap inside web/src/api/ (ISS-0765 INV-B).
   *  `params` is forwarded as the query object, same style as `usersApi.list`. */
  members: (id: string, params?: { cursor?: string; page_size?: number }) =>
    client.get<GroupMemberPage>(
      `/api/v1/identity/groups/${id}/members`,
      params as Record<string, unknown> | undefined,
    ),

  /**
   * ISS-0816 AC3 — the bounded drain. Follows `next_cursor` until it is null and
   * concatenates every page's items in request order, so callers hold the
   * COMPLETE member set.
   *
   * Why this exists rather than a truncation notice: `GroupsPage` derives its
   * "Add member" dropdown by subtracting the member id set from the user list.
   * A set difference computed from one page of 50 offers every member past the
   * 50th as if they were not members — and a notice placed on the member list
   * says nothing about that separate control (design INV-D).
   *
   * Bounds, stated as a contract:
   *   - `page_size: MEMBER_DRAIN_PAGE_SIZE` (200) — `@max_page_size` at
   *     `lib/letflow/api/pagination.ex:50`, the largest the server accepts, so
   *     the fewest round trips.
   *   - never more than `MEMBER_DRAIN_MAX_REQUESTS` (20) requests — a 4 000-member
   *     ceiling. A safety bound against a malformed or non-advancing cursor
   *     spinning the browser, not the expected path.
   *   - `truncated` reports whether members were left UNFETCHED, not whether the
   *     cap was reached. After the 20th response: `next_cursor === null` means the
   *     drain terminated normally on its last permitted request, so `truncated` is
   *     `false` (a group of exactly 4 000 is complete, not truncated); a non-null
   *     `next_cursor` means the server had more and the cap stopped the asking, so
   *     `truncated` is `true`. A 21st request is never issued either way.
   *   - rejects on the first failed request, leaving `useQuery`'s error handling
   *     unchanged.
   */
  listAllMembers: async (id: string): Promise<{ items: GroupMember[]; truncated: boolean }> => {
    const items: GroupMember[] = []
    let cursor: string | undefined

    for (let request = 0; request < MEMBER_DRAIN_MAX_REQUESTS; request += 1) {
      const page = await groupsApi.members(id, {
        cursor,
        page_size: MEMBER_DRAIN_PAGE_SIZE,
      })
      items.push(...page.items)

      if (page.next_cursor === null) {
        return { items, truncated: false }
      }
      cursor = page.next_cursor
    }

    // Cap reached with a non-null cursor still outstanding: the server had more
    // to give and this drain stopped asking.
    return { items, truncated: true }
  },
}

// ── Roles ──────────────────────────────────────────────────────────────────────

export const rolesApi = {
  list: () =>
    client.get<PagedResponse<Role>>('/api/v1/identity/roles'),

  get: (id: string) =>
    client.get<Role>(`/api/v1/admin/roles/${id}`),

  create: (body: { name: string; description?: string }) =>
    client.post<Role>('/api/v1/admin/roles', body),

  update: (id: string, body: Partial<{ description: string }>) =>
    client.patch<Role>(`/api/v1/admin/roles/${id}`, body),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/admin/roles/${id}`),

  grantPermission: (id: string, perm: Omit<RolePermission, 'id'>) =>
    client.post<RolePermission>(`/api/v1/admin/roles/${id}/permissions`, perm),

  revokePermission: (id: string, permId: string) =>
    client.delete<void>(`/api/v1/admin/roles/${id}/permissions/${permId}`),
}

// ── API Tokens ─────────────────────────────────────────────────────────────────

export const tokensApi = {
  list: () =>
    client.get<{ items: ApiToken[] }>('/api/v1/auth/tokens'),

  /** Returns the raw token value once — store it immediately */
  create: (body: { user_id: string; roles: string[]; expires_at?: string }) =>
    client.post<IssuedToken>('/api/v1/auth/tokens', body),

  revoke: (id: string) =>
    client.delete<void>(`/api/v1/auth/tokens/${id}`),
}
