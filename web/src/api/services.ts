import { client } from './client'
import type { CursorPage } from '@/types/api'

export type ServiceScope = 'global' | 'tenant'

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
  // REQ-373/REQ-432 — every admin_services response (`service_record_json/1`)
  // carries these, but `/api/v1/services` (non-admin tenant list) may still
  // hit an older projection that doesn't — kept optional rather than
  // asserting an unconfirmed guarantee (design §1.1 OQ-1).
  version?: string
  version_id?: string
  status?: 'ACTIVE' | 'RETIRED'
  published_at?: string
  retired_at?: string | null
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

/** POST /api/v1/admin/services/:service_id/versions body — REQ-373/REQ-432.
 *  `endpoint_url`/`timeout_ms` are marked required here even though the
 *  route itself only 422s on their absence (via `publish_attrs()`'s Ecto
 *  changeset) rather than 400ing at the route layer — design §1.1. */
export interface PublishVersionBody {
  version: string
  endpoint_url: string
  timeout_ms: number
  request_schema?: string
  response_schema?: string
  auth_method?: string
  retry_policy?: string
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

  /** DELETE /api/v1/admin/services/:service_id — remove service (platform-admin only) */
  delete: (serviceId: string) =>
    client.delete<void>(`/api/v1/admin/services/${serviceId}`),

  /** POST /api/v1/admin/services/:service_id/versions — publish a new
   *  version (platform-admin only). REQ-373/REQ-432. 201 -> ServiceRecord. */
  publishVersion: (serviceId: string, body: PublishVersionBody) =>
    client.post<ServiceRecord>(`/api/v1/admin/services/${serviceId}/versions`, body),

  /** POST /api/v1/admin/services/:service_id/retire — retire the entry's
   *  current version (platform-admin only). REQ-373/REQ-432. No request
   *  body. 200 -> ServiceRecord with status: "RETIRED". */
  retireVersion: (serviceId: string) =>
    client.post<ServiceRecord>(`/api/v1/admin/services/${serviceId}/retire`),
}
