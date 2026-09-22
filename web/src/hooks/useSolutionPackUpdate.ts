/** useSolutionPackUpdate — REQ-381 design §4.5
 *
 *  `useSolutionPackUpdateReview` is a `useQuery` wrapping a `POST` body
 *  (`solutionPacksApi.updateReview`) — the same pattern the codebase already
 *  accepts for `compute_pack_update_plan/5`'s pure/read-only classification
 *  (REQ-380 design §3.1's own "read-only, :DefinitionsRead" framing).
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { solutionPacksApi } from '@/api/solutionPacks'
import type { PackUpdateApplyRequest, PackUpdateReviewResponse, PackArtefactInput } from '@/api/solutionPacks'
import { queryKeys } from '@/api/queryKeys'
import type { ApiError } from '@/types/api'

export function useSolutionPackUpdateReview(
  packId: string,
  targetVersion: string,
  theirsArtefacts: PackArtefactInput[],
  incomingArtefacts: PackArtefactInput[],
) {
  return useQuery<PackUpdateReviewResponse, ApiError>({
    queryKey: queryKeys.solutionPackUpdate.review(packId, targetVersion),
    queryFn: () =>
      solutionPacksApi.updateReview(packId, {
        target_version: targetVersion,
        theirs_artefacts: theirsArtefacts,
        incoming_artefacts: incomingArtefacts,
      }),
    enabled: !!targetVersion,
  })
}

export function useSolutionPackUpdateApply() {
  const qc = useQueryClient()
  return useMutation<
    Awaited<ReturnType<typeof solutionPacksApi.updateApply>>,
    ApiError,
    { packId: string; body: PackUpdateApplyRequest }
  >({
    mutationFn: ({ packId, body }) => solutionPacksApi.updateApply(packId, body),
    onSuccess: (_data, { packId, body }) => {
      // EO-004/EO-005: force the re-fetch that makes "after apply" on-screen
      // assertions real, not a locally-patched cache guess (design §4.5).
      void qc.invalidateQueries({
        queryKey: queryKeys.solutionPackUpdate.review(packId, body.target_version),
      })
    },
  })
}
