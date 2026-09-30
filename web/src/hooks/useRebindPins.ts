/** useRebindPins — REQ-432. Mutation wrapper for POST /instances/:id/rebind-pins.
 *
 *  Exactly ONE invalidation on success: the prefix-only `instances.all()` key
 *  (same as useCancelInstance), a strict prefix of pins/detail/events/timeline
 *  keys for every case. No optimistic update — the server decides `changes`.
 *  See lib/letflow/design/req432-rebind-pins-publish-retire-ui.md §4.3.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { instancesApi } from '@/api/instances'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type { RebindPinsRequest, RebindPinsResponse } from '@/types/api'

export interface RebindPinsVariables {
  body: RebindPinsRequest
  idempotencyKey: string
}

export function useRebindPins(instanceId: string) {
  const queryClient = useQueryClient()
  const instanceKeys = useTenantScopedQueryKeys().instances

  return useMutation<RebindPinsResponse, unknown, RebindPinsVariables>({
    mutationFn: ({ body, idempotencyKey }) =>
      instancesApi.rebindPins(instanceId, body, idempotencyKey),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: instanceKeys.all() })
    },
  })
}
