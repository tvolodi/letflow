/** TanStack Query hook for an instance's effective dependency pins — REQ-399
 *
 *  No `refetchInterval`: pins are set once at instance start and only change
 *  via an explicit PIN-05 rebind (a separate, infrequent, out-of-scope
 *  action), so polling this route on the interval `InstanceDetailPage.tsx`
 *  already drives for the instance itself is unnecessary.
 */
import { useQuery } from '@tanstack/react-query'
import { instancesApi } from '@/api/instances'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export function useInstancePins(instanceId: string) {
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useQuery({
    queryKey: instanceKeys.pins(instanceId),
    queryFn: () => instancesApi.getPins(instanceId),
    enabled: !!instanceId,
  })
}
