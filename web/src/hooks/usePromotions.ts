/** TanStack Query hooks for promotion reviews (PRM-02 – PRM-05) */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { promotionsApi } from '@/api/promotions'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type {
  ApprovePromotionRequest,
  ApplyPromotionRequest,
  PromotionReviewListFilters,
} from '@/api/promotions'

/** Fetch GET /api/v1/promotions/{reviewId}/context */
export function usePromotionContext(reviewId: string) {
  const promotionKeys = useTenantScopedQueryKeys().promotions
  return useQuery({
    queryKey: promotionKeys.context(reviewId),
    queryFn: () => promotionsApi.getContext(reviewId),
    enabled: !!reviewId,
  })
}

/**
 * Fetch GET /api/v1/promotions (REQ-398). No `enabled` guard — unlike
 * `usePromotionContext`, this query has no required path param that could
 * be empty. No `refetchInterval` either — a considered omission (design
 * doc §3.1): a manual re-query on filter change is what AC3 requires, not
 * live polling.
 */
export function usePromotionReviewList(filters: PromotionReviewListFilters) {
  const promotionKeys = useTenantScopedQueryKeys().promotions
  return useQuery({
    queryKey: promotionKeys.list(filters),
    queryFn: () => promotionsApi.list(filters),
  })
}

/** Mutation: POST /api/v1/promotions/{reviewId}/approve */
export function useApprovePromotion() {
  const qc = useQueryClient()
  const promotionKeys = useTenantScopedQueryKeys().promotions
  return useMutation({
    mutationFn: ({ reviewId, body }: { reviewId: string; body: ApprovePromotionRequest }) =>
      promotionsApi.approve(reviewId, body),
    onSuccess: (_data, { reviewId }) => {
      void qc.invalidateQueries({ queryKey: promotionKeys.context(reviewId) })
    },
  })
}

/** Mutation: POST /api/v1/promotions/{reviewId}/reject */
export function useRejectPromotion() {
  const qc = useQueryClient()
  const promotionKeys = useTenantScopedQueryKeys().promotions
  return useMutation({
    mutationFn: (reviewId: string) => promotionsApi.reject(reviewId),
    onSuccess: (_data, reviewId) => {
      void qc.invalidateQueries({ queryKey: promotionKeys.context(reviewId) })
    },
  })
}

/** Mutation: POST /api/v1/promotions/{reviewId}/apply */
export function useApplyPromotion() {
  const qc = useQueryClient()
  const promotionKeys = useTenantScopedQueryKeys().promotions
  return useMutation({
    mutationFn: ({ reviewId, body }: { reviewId: string; body: ApplyPromotionRequest }) =>
      promotionsApi.apply(reviewId, body),
    onSuccess: (_data, { reviewId }) => {
      void qc.invalidateQueries({ queryKey: promotionKeys.context(reviewId) })
    },
  })
}
