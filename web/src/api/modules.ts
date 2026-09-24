import { client } from './client'
import type { CursorPage } from '@/types/api'

// PLC-01 — Process Module Catalog entry shape
export type ModuleStatus = 'DRAFT' | 'ACTIVE' | 'DEPRECATED'

export interface ProcessModuleCatalogEntry {
  module_id: string
  version: string
  owning_tenant_id: string
  owning_definition_id: string
  interface_schema: Record<string, unknown>
  exportable: boolean
  status: ModuleStatus
  created_at: string
  updated_at: string
}

// PLC-03 — Compatibility warning
export interface CompatibilityWarning {
  module_id: string
  new_version: string
  previous_version: string
  breaking_changes: string[]
}

// PLC-02 — Publish result
export interface PublishModuleResult {
  entry: ProcessModuleCatalogEntry
  compatibility_warning: CompatibilityWarning | null
}

// PLC-04 — Share grant
export interface ModuleShare {
  grant_id: string
  granting_tenant_id: string
  module_id: string
  receiving_tenant_id: string
  granted_at: string
  granted_by: string
}

// NOTE (ISS-0813): lib/letflow/plugs/api_pipeline.ex mounts no /modules or
// /module-shares sub-router. These paths will 404 until the backend is
// implemented. Only the /admin/services sub-router is mounted under /admin;
// the prefix corrected here from the wrong /admin/modules form (ISS-0813).
// Expected future prefix: /api/v1/modules.

export const modulesApi = {
  list: (params?: { cursor?: string; page_size?: number }) =>
    client.get<CursorPage<ProcessModuleCatalogEntry>>('/api/v1/modules', params as Record<string, unknown>),

  get: (moduleId: string, version: string) =>
    client.get<ProcessModuleCatalogEntry>(`/api/v1/modules/${moduleId}/${version}`),

  register: (body: {
    module_id: string
    version: string
    owning_definition_id: string
    interface_schema?: Record<string, unknown>
    exportable?: boolean
  }) => client.post<ProcessModuleCatalogEntry>('/api/v1/modules', body),

  publish: (moduleId: string, version: string) =>
    client.post<PublishModuleResult>(`/api/v1/modules/${moduleId}/${version}/publish`, {}),

  listShares: (moduleId: string) =>
    client.get<CursorPage<ModuleShare>>(`/api/v1/module-shares?module_id=${encodeURIComponent(moduleId)}`),

  grantShare: (body: {
    granting_tenant_id: string
    module_id: string
    receiving_tenant_id: string
  }) => client.post<ModuleShare>('/api/v1/module-shares', body),

  revokeShare: (grantId: string) =>
    client.delete<void>(`/api/v1/module-shares/${grantId}`),
}
