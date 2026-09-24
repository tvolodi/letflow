import { client } from './client'
import type {
  User,
  Group,
  GroupListResponse,
  GroupMemberAddResult,
  GroupMemberPage,
  Role,
  RolePermission,
  ApiToken,
  IssuedToken,
  PagedResponse,
} from '@/types/api'

// ── Users ──────────────────────────────────────────────────────────────────────

export const usersApi = {
  list: (params?: { page?: number; page_size?: number; search?: string; status?: string }) =>
    client.get<PagedResponse<User>>('/api/v1/identity/users', params as Record<string, unknown>),

  get: (id: string) =>
    client.get<User>(`/api/v1/identity/users/${id}`),

  create: (body: { username: string; email: string; display_name: string; password: string; role_ids?: string[] }) =>
    client.post<User>('/api/v1/identity/users', body),

  update: (id: string, body: Partial<{ display_name: string; email: string; status: 'active' | 'inactive'; is_active: boolean; role_ids: string[]; group_ids: string[] }>) =>
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

  members: (id: string) =>
    client.get<GroupMemberPage>(`/api/v1/identity/groups/${id}/members`),
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
