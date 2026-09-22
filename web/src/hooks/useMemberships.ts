/** REQ-384 §6.1 — thin useQuery wrapper over GET /api/v1/me/memberships.
 *
 *  Query key `queryKeys.me.memberships()` — deliberately NOT tenant-prefixed
 *  (see `web/src/api/queryKeys.ts`'s moduledoc): its whole purpose is to
 *  list tenants OTHER than the active one, and a stale entry surviving a
 *  switch is not a cross-tenant business-data leak in the sense AC2/AC3
 *  guard against — it is a list of tenant names/slugs the user is already
 *  authorized to see regardless of which one is active.
 */
import { useQuery } from '@tanstack/react-query'
import { membershipsApi } from '@/api/memberships'
import { queryKeys } from '@/api/queryKeys'
import { useAuth } from '@/auth/AuthContext'

export function useMemberships() {
  const { isAuthenticated } = useAuth()
  return useQuery({
    queryKey: queryKeys.me.memberships(),
    queryFn: () => membershipsApi.list(),
    enabled: isAuthenticated,
    select: (data) => data.memberships,
  })
}
