import { client } from './client'
import type { CursorPage } from '@/types/api'

export type ServiceScope = 'global' | 'tenant'

/** REQ-373 service_catalog version lifecycle status. */
export type ServiceVersionStatus = 'ACTIVE' | 'RETIRED'

export interface ServiceRecord {
  service_id: string
  endpoint_url: string
  request_schema: string
  response_schema: string
  required_auth: string
  timeout_ms: number
  max_retries: number
  scope: ServiceScope
  owner_tenant_id: string | null
  created_at: string
  updated_at: string
  // REQ-373 version lifecycle fields, emitted by the admin routes only (the
  // tenant-scoped list projection may omit them — render "—" when undefined).
  version?: string
  version_id?: string
  status?: ServiceVersionStatus
  published_at?: string
  retired_at?: string | null
}

/** Wire names (`auth_method`, not `required_auth`) — mirrors RegisterServiceBody. */
export interface PublishServiceVersionBody {
  version: string
  endpoint_url: string
  timeout_ms: number
  auth_method?: string
  request_schema?: string
  response_schema?: string
  retry_policy?: string
}

export interface RegisterServiceBody {
  service_id: string
  endpoint_url: string
  scope: ServiceScope
  owner_tenant_id?: string
  auth_method: string
  timeout_ms: number
  max_retries?: number
  request_schema: string
  response_schema: string
}

export interface UpdateServiceScopeBody {
  scope: ServiceScope
  owner_tenant_id?: string
}

export const servicesApi = {
  /** GET /api/v1/services — tenant-scoped list (any authenticated user) */
  listForTenant: (params?: Record<string, unknown>) =>
    client.get<CursorPage<ServiceRecord>>('/api/v1/services', params),

  /** GET /api/v1/admin/services — all entries (platform-admin only) */
  listAll: (params?: Record<string, unknown>) =>
    client.get<CursorPage<ServiceRecord>>('/api/v1/admin/services', params),

  /** POST /api/v1/admin/services — register new service (platform-admin only) */
  register: (body: RegisterServiceBody) =>
    client.post<ServiceRecord>('/api/v1/admin/services', body),

  /** PATCH /api/v1/admin/services/:service_id — update scope (platform-admin only) */
  updateScope: (serviceId: string, body: UpdateServiceScopeBody) =>
    client.patch<ServiceRecord>(`/api/v1/admin/services/${serviceId}`, body),

  /** POST /api/v1/admin/services/:service_id/versions — publish a new version (REQ-373; platform-admin only) */
  publishVersion: (serviceId: string, body: PublishServiceVersionBody) =>
    client.post<ServiceRecord>(`/api/v1/admin/services/${serviceId}/versions`, body),

  /** POST /api/v1/admin/services/:service_id/retire — retire the current version (REQ-373; platform-admin only) */
  retire: (serviceId: string) =>
    client.post<ServiceRecord>(`/api/v1/admin/services/${serviceId}/retire`),

  /** DELETE /api/v1/admin/services/:service_id — remove service (platform-admin only) */
  delete: (serviceId: string) =>
    client.delete<void>(`/api/v1/admin/services/${serviceId}`),
}
