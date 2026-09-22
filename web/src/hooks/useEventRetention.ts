/** useEventRetention — REQ-377 §3.3: hooks for the operator-facing
 *  history-retirement screen. Same shape as `usePlatformMigrations.ts`'s own
 *  hooks, except `useRetirementStatus` polls while `retirement.status ===
 *  'running'` — the backend's start endpoint is async (202, §1 of the
 *  design), unlike platform-migrations' synchronous start/resume.
 *
 *  See `lib/letflow/design/req377-history-retirement-screen.md` §3.3.
 */

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { eventRetentionApi } from '@/api/eventRetention'
import type { Retirement, RetirementResult, RetentionSummary } from '@/api/eventRetention'
import { queryKeys } from '@/api/queryKeys'
import type { ApiError } from '@/types/api'

export function useRetentionSummary() {
  return useQuery<RetentionSummary, ApiError>({
    queryKey: queryKeys.eventRetention.summary(),
    queryFn: eventRetentionApi.summary,
  })
}

export function useStartRetirement() {
  const qc = useQueryClient()
  return useMutation<Retirement, ApiError, void>({
    mutationFn: () => eventRetentionApi.start(),
    onSuccess: (data: Retirement) => {
      qc.invalidateQueries({ queryKey: queryKeys.eventRetention.retirement(data.id) })
    },
  })
}

// §1's async design's frontend half: poll while status === 'running', stop
// once 'completed'/'failed' -- this IS the "no full-page blocking spinner
// tied to the retirement's own duration" requirement (EO-001) realized in
// the UI: the page stays interactive, this hook's own refetchInterval
// callback just checks in periodically rather than the mutation itself
// blocking until completion.
export function useRetirementStatus(retirementId: string | null) {
  return useQuery<RetirementResult, ApiError>({
    queryKey: queryKeys.eventRetention.retirement(retirementId ?? ''),
    queryFn: () => eventRetentionApi.status(retirementId as string),
    enabled: !!retirementId,
    refetchInterval: (query) =>
      query.state.data?.retirement.status === 'running' ? 2000 : false,
  })
}
