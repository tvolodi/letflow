/** usePlatformMigrations — REQ-375 §3.2: hooks for the platform migration
 *  rollout console. Same shape as `useDefinitions.ts`'s own hooks.
 *
 *  See `lib/letflow/design/req375-rollout-status-screen.md` §3.2.
 */

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { platformMigrationsApi } from '@/api/platformMigrations'
import type { RolloutResult, StartRolloutRequest } from '@/api/platformMigrations'
import { queryKeys } from '@/api/queryKeys'
import type { ApiError } from '@/types/api'

export function useStartRollout() {
  const qc = useQueryClient()
  return useMutation<RolloutResult, ApiError, StartRolloutRequest>({
    mutationFn: (body: StartRolloutRequest) => platformMigrationsApi.start(body),
    onSuccess: (data: RolloutResult) => {
      qc.invalidateQueries({ queryKey: queryKeys.platformMigrations.status(data.rollout.id) })
    },
  })
}

export function useRolloutStatus(rolloutId: string | null) {
  return useQuery<RolloutResult, ApiError>({
    queryKey: queryKeys.platformMigrations.status(rolloutId ?? ''),
    queryFn: () => platformMigrationsApi.status(rolloutId as string),
    enabled: !!rolloutId,
    // §3.2 — no polling: start/resume are synchronous (REQ-374 design §1),
    // so nothing but an explicit operator action ever advances rollout state.
    refetchInterval: false,
  })
}

export function useResumeRollout() {
  const qc = useQueryClient()
  return useMutation<RolloutResult, ApiError, string>({
    mutationFn: (rolloutId: string) => platformMigrationsApi.resume(rolloutId),
    onSuccess: (data: RolloutResult) => {
      qc.invalidateQueries({ queryKey: queryKeys.platformMigrations.status(data.rollout.id) })
    },
  })
}
