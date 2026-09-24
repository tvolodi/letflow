/** TanStack Query hooks for instance attachments — REQ-212/387/392 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { attachmentsApi } from '@/api/attachments'
import { instancesApi } from '@/api/instances'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type { ApiError, Attachment } from '@/types/api'

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
  const attachmentKeys = useTenantScopedQueryKeys().attachments
  return useMutation<Attachment, ApiError, FormData>({
    mutationFn: (formData: FormData) => attachmentsApi.upload(instanceId, formData),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: instanceKeys.attachments(instanceId) })
      // REQ-392 AC3 — an accepted upload must move the storage-usage figure.
      qc.invalidateQueries({ queryKey: attachmentKeys.storageUsage() })
    },
  })
}

/** REQ-392 §4.1 — the missing TanStack Query wrapper around
 *  `attachmentsApi.delete`, which already existed unused before this
 *  requirement. Invalidates both the attachment list and the storage-usage
 *  figure (AC1 + AC3's "reflects a removal" both depend on this one mutation). */
export function useDeleteAttachment(instanceId: string) {
  const qc = useQueryClient()
  const instanceKeys = useTenantScopedQueryKeys().instances
  const attachmentKeys = useTenantScopedQueryKeys().attachments
  return useMutation<void, ApiError, string>({
    mutationFn: (attachmentId: string) => attachmentsApi.delete(instanceId, attachmentId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: instanceKeys.attachments(instanceId) })
      qc.invalidateQueries({ queryKey: attachmentKeys.storageUsage() })
    },
  })
}

/** REQ-392 §5.2 — the tenant-wide storage-usage figure. Not instance-scoped
 *  (no `instanceId` parameter) -- `Attachments.storage_summary/1` composes a
 *  per-tenant aggregate, matching EO-003's own "company-wide" wording. */
export function useStorageUsage() {
  const attachmentKeys = useTenantScopedQueryKeys().attachments
  return useQuery({
    queryKey: attachmentKeys.storageUsage(),
    queryFn: () => attachmentsApi.storageUsage(),
  })
}

export interface TaskCompletionAttachment {
  attachment_id: string
  file_name: string
}

/** REQ-392 §7.1 — the reviewed attachment(s) a `TASK_COMPLETED` event's
 *  `attachments_at_decision` snapshot names. Reuses the already-shipped
 *  `instancesApi.events` client function and the same `.items`-unwrap
 *  runtime pattern `EventHistoryPanel.tsx` already established for that same
 *  mistyped-but-working return type (design §0/§7.1) -- deliberately not
 *  "fixing" `instancesApi.events`'s declared type here, that touches a file
 *  outside this requirement's scope.
 *
 *  Only fetched for a COMPLETED task (`enabled` param, ANDed with
 *  `task.status === 'COMPLETED'` internally is the caller's job per the
 *  design -- this hook takes the already-computed boolean) -- avoids an
 *  extra request on the far more common PENDING case. */
export function useTaskCompletionAttachments(instanceId: string, taskId: string, enabled: boolean) {
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useQuery({
    queryKey: instanceKeys.events(instanceId, { event_type: 'TASK_COMPLETED' }),
    queryFn: async (): Promise<TaskCompletionAttachment[]> => {
      const raw = (await instancesApi.events(instanceId, { event_type: 'TASK_COMPLETED' })) as unknown
      const items: unknown[] = Array.isArray(raw)
        ? raw
        : raw && typeof raw === 'object' && Array.isArray((raw as { items?: unknown }).items)
          ? ((raw as { items: unknown[] }).items)
          : []

      const match = items.find((item): item is { payload?: Record<string, unknown> } => {
        const payload = (item as { payload?: Record<string, unknown> })?.payload
        return !!payload && payload['task_id'] === taskId
      })

      const snapshot = match?.payload?.['attachments_at_decision']
      if (!Array.isArray(snapshot)) return []

      return snapshot
        .filter((entry): entry is Record<string, unknown> => !!entry && typeof entry === 'object')
        .map((entry) => ({
          attachment_id: String(entry['attachment_id'] ?? ''),
          file_name: String(entry['file_name'] ?? ''),
        }))
    },
    enabled: enabled && !!instanceId && !!taskId,
  })
}
