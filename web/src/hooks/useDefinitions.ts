/** TanStack Query hooks — query key factories + hooks for all APIs */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { definitionsApi } from '@/api/definitions'
import { definitionRollbackApi } from '@/api/definitionRollback'
import type { DefinitionStatus, CreateDefinitionRequest } from '@/types/api'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export function useDefinitions(params?: { status?: DefinitionStatus; name?: string }) {
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useQuery({
    queryKey: definitionKeys.list(params ?? {}),
    queryFn: () => definitionsApi.list(params),
  })
}

export function useDefinition(id: string) {
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useQuery({
    queryKey: definitionKeys.detail(id),
    queryFn: () => definitionsApi.get(id),
    enabled: !!id,
  })
}

export function useCreateDefinition() {
  const qc = useQueryClient()
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useMutation({
    mutationFn: (body: CreateDefinitionRequest) => definitionsApi.create(body),
    onSuccess: () => qc.invalidateQueries({ queryKey: definitionKeys.all() }),
  })
}

export function useDefinitionVersions(name: string) {
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useQuery({
    queryKey: definitionKeys.versions(name),
    queryFn: () => definitionsApi.getVersions(name),
    enabled: !!name,
  })
}

export function useActivateDefinition() {
  const qc = useQueryClient()
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useMutation({
    mutationFn: (id: string) => definitionsApi.activate(id),
    onSuccess: (_data, id) => {
      qc.invalidateQueries({ queryKey: definitionKeys.detail(id) })
      qc.invalidateQueries({ queryKey: definitionKeys.list({}) })
    },
  })
}

export function useArchiveDefinition() {
  const qc = useQueryClient()
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useMutation({
    mutationFn: (id: string) => definitionsApi.archive(id),
    onSuccess: (_data, id) => {
      qc.invalidateQueries({ queryKey: definitionKeys.detail(id) })
      qc.invalidateQueries({ queryKey: definitionKeys.list({}) })
    },
  })
}

/** REQ-371: rollback/withdrawal mutation. See
 *  `lib/letflow/design/req371-rollback-withdrawal-screen.md` §3 — no
 *  `onSuccess` local change-history write here (`DefinitionRollbackPage.tsx`
 *  owns that as component-local state, §7.2), only the query invalidations
 *  needed so an already-mounted `InstanceBoardPage.tsx` picks up the
 *  restored active version (§1.6/AC4).
 */
export function useRollbackDefinition() {
  const qc = useQueryClient()
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useMutation({
    mutationFn: (args: { processKey: string; targetVersion: string }) =>
      definitionRollbackApi.rollback(args.processKey, { target_version: args.targetVersion }),
    onSuccess: (_data, args) => {
      qc.invalidateQueries({ queryKey: definitionKeys.active(args.processKey) })
      qc.invalidateQueries({ queryKey: definitionKeys.list({}) })
      qc.invalidateQueries({ queryKey: definitionKeys.versions(args.processKey) })
    },
  })
}

export function useDefinitionSearch(query: string, options?: { limit?: number; offset?: number }) {
  const definitionKeys = useTenantScopedQueryKeys().definitions
  const limit = options?.limit ?? 20
  const offset = options?.offset ?? 0
  return useQuery({
    queryKey: definitionKeys.search(query, limit, offset),
    queryFn: () => definitionsApi.search({ q: query, limit, offset }),
    enabled: query.trim().length > 0,
  })
}
