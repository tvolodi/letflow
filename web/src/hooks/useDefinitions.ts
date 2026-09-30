/** TanStack Query hooks — query key factories + hooks for all APIs */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { definitionsApi } from '@/api/definitions'
import { definitionRollbackApi } from '@/api/definitionRollback'
import type { ApiError, DefinitionStatus, CreateDefinitionRequest, ProcessDefinition } from '@/types/api'
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

/** ISS-0911: exact-name active-definition lookup, keyed on the CALLER-supplied
 *  name — used by any input that must resolve a name the user is actively
 *  typing (not a page-level filter). `name` is trimmed before being used as
 *  both the query key and the request argument, so two inputs differing only
 *  in leading/trailing whitespace share one cache entry/request. `enabled` is
 *  false for a blank/whitespace-only name, so no request fires for an empty
 *  dialog input. Does not retry on a 404 — a 404 here means "no active
 *  definition with this exact name," an expected outcome while the user is
 *  still typing, not a transient failure. See
 *  lib/letflow/design/iss0911-start-instance-dialog-exact-lookup.md §3. */
export function useActiveDefinitionByName(name: string) {
  const definitionKeys = useTenantScopedQueryKeys().definitions
  const trimmedName = name.trim()
  return useQuery<ProcessDefinition, ApiError>({
    queryKey: definitionKeys.active(trimmedName),
    queryFn: () => definitionsApi.getActive(trimmedName),
    enabled: trimmedName.length > 0,
    // ISS-0911 §3: design calls for staleTime 0 "(or left at the query
    // client's default)" — left at the global default here (main.tsx) since
    // an inline staleTime literal is guarded (CAC-UI-01, inline-stale-time)
    // and only queryKeys.ts/main.tsx are exempted from it.
    retry: (failureCount, error) => {
      if (error.status === 404) return false
      return failureCount < 2
    },
  })
}

// ISS-0820: limit/offset removed — handle_search/1 only reads q, cursor, page_size.
export function useDefinitionSearch(query: string, options?: { page_size?: number; cursor?: string }) {
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useQuery({
    queryKey: definitionKeys.search(query, options?.page_size, options?.cursor),
    queryFn: () => definitionsApi.search({ q: query, page_size: options?.page_size, cursor: options?.cursor }),
    enabled: query.trim().length > 0,
  })
}
