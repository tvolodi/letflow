/** TanStack Query hooks for instance attachments — REQ-212/387 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { attachmentsApi } from '@/api/attachments'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export function useAttachments(instanceId: string) {
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useQuery({
    queryKey: instanceKeys.attachments(instanceId),
    queryFn: () => attachmentsApi.list(instanceId),
    enabled: !!instanceId,
  })
}

export function useUploadAttachment(instanceId: string) {
  const qc = useQueryClient()
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useMutation({
    mutationFn: (formData: FormData) => attachmentsApi.upload(instanceId, formData),
    onSuccess: () => qc.invalidateQueries({ queryKey: instanceKeys.attachments(instanceId) }),
  })
}
