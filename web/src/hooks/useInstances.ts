/** TanStack Query hooks for process instances */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { instancesApi } from '@/api/instances'
import type { InstanceStatus, StartInstanceRequest } from '@/types/api'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export interface EventFilters {
  event_type?: string
  from?: string
  to?: string
}

export function useInstances(params?: {
  status?: InstanceStatus[]
  definition_id?: string
  cursor?: string
  page_size?: number
}) {
  const instanceKeys = useTenantScopedQueryKeys().instances
  const filters = {
    status: params?.status,
    definition_id: params?.definition_id,
    cursor: params?.cursor,
    page_size: params?.page_size,
  }

  return useQuery({
    queryKey: instanceKeys.list(filters),
    queryFn: () => instancesApi.list(params),
  })
}

export function useInstance(id: string) {
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useQuery({
    queryKey: instanceKeys.detail(id),
    queryFn: () => instancesApi.get(id),
    enabled: !!id,
  })
}

export function useInstanceEvents(id: string, filters?: EventFilters) {
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useQuery({
    queryKey: instanceKeys.events(id, filters),
    queryFn: () => instancesApi.events(id, filters),
    enabled: !!id,
  })
}

export function useInstanceTimeline(
  id: string,
  params?: { cursor?: string; page_size?: number },
  enabled = true,
) {
  const instanceKeys = useTenantScopedQueryKeys().instances
  const cursor = params?.cursor ?? null
  const pageSize = params?.page_size ?? 50

  return useQuery({
    queryKey: instanceKeys.timeline(id, cursor, pageSize),
    queryFn: () => instancesApi.timeline(id, params),
    enabled: !!id && enabled,
  })
}

export function useStartInstance() {
  const qc = useQueryClient()
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useMutation({
    mutationFn: (body: StartInstanceRequest) => instancesApi.start(body),
    onSuccess: () => qc.invalidateQueries({ queryKey: instanceKeys.all() }),
  })
}

export function useCancelInstance() {
  const qc = useQueryClient()
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useMutation({
    mutationFn: ({ id, reason }: { id: string; reason?: string }) =>
      instancesApi.cancel(id, reason),
    onMutate: async ({ id }) => {
      await qc.cancelQueries({ queryKey: instanceKeys.detail(id) })
      const previous = qc.getQueryData(instanceKeys.detail(id))
      qc.setQueryData(instanceKeys.detail(id), (old: unknown) =>
        old ? { ...(old as object), status: 'CANCELLED' } : old,
      )
      return { previous }
    },
    onError: (_err, { id }, ctx) => {
      qc.setQueryData(instanceKeys.detail(id), ctx?.previous)
    },
    onSettled: (_data, _err, { id }) => {
      qc.invalidateQueries({ queryKey: instanceKeys.detail(id) })
      qc.invalidateQueries({ queryKey: instanceKeys.all() })
    },
  })
}
