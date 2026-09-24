/** AttachmentPanel — upload/list widget for instance attachments (REQ-212/387)
 *
 *  Mounted inside InstanceDetailPage.tsx alongside EventHistoryPanel/TimelineFeed
 *  -- same "one focused panel component per concern" pattern that page already
 *  follows. See lib/letflow/design/req387-attachment-document-viewer.md §3.1.
 */
import { useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAttachments, useDeleteAttachment, useStorageUsage, useUploadAttachment } from '@/hooks/useAttachments'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { Button } from '@/components/ui/Button'
import { useToast } from '@/hooks/useToast'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { formatDateTime } from '@/i18n/format'
import type { ApiError, Attachment } from '@/types/api'

interface AttachmentPanelProps {
  instanceId: string
}

interface AttachmentRow {
  key: string
  attachment: Attachment
}

/** REQ-392 §3.2 — the three distinct rejection kinds AC2 must render, each
 *  independently assertable via `data-error-kind`. */
type UploadErrorKind = 'content-type' | 'quota' | 'other'

interface UploadErrorState {
  kind: UploadErrorKind
  message: string
}

/** REQ-392 §3.1 — `upload/2`'s only two rejection paths that ever reach the
 *  frontend as 409/415 are `:storage_quota_exceeded`/`:content_type_not_allowed`
 *  respectively (confirmed against the shipped router source, design §0/§2) --
 *  HTTP status alone disambiguates them for this one mutation. The readable
 *  text is the RFC 9457 `detail` field, which `client.ts`'s
 *  `throwOnErrorResponse` puts on `ApiError.details.detail` for both the
 *  generic and the 409-specific branches (both spread the parsed body into
 *  `details`) -- fall back to `error.message` (the `title` field) only if
 *  `detail` is absent. */
function classifyUploadError(error: ApiError): UploadErrorState {
  const detail = typeof error.details?.detail === 'string' ? error.details.detail : undefined
  const message = detail ?? error.message
  if (error.status === 415) return { kind: 'content-type', message }
  if (error.status === 409) return { kind: 'quota', message }
  return { kind: 'other', message: 'Failed to upload attachment.' }
}

function formatByteSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '—'
  if (bytes < 1024) return `${bytes} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = bytes / 1024
  let unitIndex = 0
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024
    unitIndex += 1
  }
  return `${value.toFixed(value >= 10 ? 0 : 1)} ${units[unitIndex]}`
}

export function AttachmentPanel({ instanceId }: AttachmentPanelProps) {
  const attachmentsQuery = useAttachments(instanceId)
  const upload = useUploadAttachment(instanceId)
  const deleteAttachment = useDeleteAttachment(instanceId)
  const storageUsageQuery = useStorageUsage()
  const toast = useToast()
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [description, setDescription] = useState('')
  const [uploadError, setUploadError] = useState<UploadErrorState | null>(null)
  // REQ-392 §4.2 -- in-row two-click confirm, keyed by attachment id. Only
  // one row's confirm affordance is ever shown at a time.
  const [pendingRemoveId, setPendingRemoveId] = useState<string | null>(null)

  const rendererState: RendererState = attachmentsQuery.isLoading
    ? 'loading'
    : attachmentsQuery.isError
      ? classifyError(attachmentsQuery.error)
      : 'success'

  const onUpload = () => {
    const file = fileInputRef.current?.files?.[0]
    if (!file) return

    setUploadError(null)

    const formData = new FormData()
    formData.append('file', file)
    if (description.trim() !== '') {
      formData.append('description', description.trim())
    }

    upload.mutate(formData, {
      onSuccess: () => {
        toast.success('Attachment uploaded.')
        setDescription('')
        setUploadError(null)
        if (fileInputRef.current) fileInputRef.current.value = ''
      },
      onError: (error: ApiError) => {
        setUploadError(classifyUploadError(error))
        toast.error('Failed to upload attachment.')
      },
    })
  }

  const onConfirmRemove = (attachmentId: string) => {
    deleteAttachment.mutate(attachmentId, {
      onSuccess: () => {
        toast.success('Attachment removed.')
        setPendingRemoveId(null)
      },
      onError: () => {
        toast.error('Failed to remove attachment.')
      },
    })
  }

  const columns: DataTableColumn<AttachmentRow>[] = [
    { id: 'file_name', header: 'File name', accessor: (row) => row.attachment.file_name },
    { id: 'byte_size', header: 'Size', accessor: (row) => formatByteSize(row.attachment.byte_size) },
    { id: 'uploaded_by', header: 'Uploaded by', accessor: (row) => row.attachment.uploaded_by },
    { id: 'created_at', header: 'Uploaded at', accessor: (row) => formatDateTime(row.attachment.created_at) },
    {
      id: 'view',
      header: '',
      accessor: (row) => (
        <Link
          data-testid="attachment-view-link"
          to={`/instances/${instanceId}/attachments/${row.attachment.id}`}
        >
          View
        </Link>
      ),
    },
    {
      id: 'remove',
      header: '',
      accessor: (row) => {
        const isPending = pendingRemoveId === row.attachment.id
        const isDeleting = deleteAttachment.isPending && isPending
        if (!isPending) {
          return (
            <Button
              variant="danger"
              size="sm"
              data-testid="attachment-remove-button"
              onClick={() => setPendingRemoveId(row.attachment.id)}
            >
              Remove
            </Button>
          )
        }
        return (
          <div style={{ display: 'flex', gap: '.4rem' }}>
            <Button
              variant="danger"
              size="sm"
              data-testid="attachment-remove-confirm-button"
              onClick={() => onConfirmRemove(row.attachment.id)}
              loading={isDeleting}
              disabled={isDeleting}
            >
              Confirm remove?
            </Button>
            <Button
              variant="ghost"
              size="sm"
              data-testid="attachment-remove-cancel-button"
              onClick={() => setPendingRemoveId(null)}
              disabled={isDeleting}
            >
              Cancel
            </Button>
          </div>
        )
      },
    },
  ]

  const rows: AttachmentRow[] = (attachmentsQuery.data?.items ?? []).map((attachment) => ({
    key: attachment.id,
    attachment,
  }))

  return (
    <section data-testid="attachment-panel">
      <div data-testid="attachment-storage-usage" style={{ fontSize: '.82rem', color: 'var(--color-neutral-700)', marginBottom: '.5rem' }}>
        {storageUsageQuery.isLoading
          ? 'Loading storage usage…'
          : storageUsageQuery.isError
            ? 'Storage usage unavailable'
            : storageUsageQuery.data
              ? `${formatByteSize(storageUsageQuery.data.used_bytes)} of ${formatByteSize(storageUsageQuery.data.allowance_bytes)} used`
              : null}
      </div>

      <div style={{ display: 'flex', gap: '.6rem', flexWrap: 'wrap', alignItems: 'end', marginBottom: '.85rem' }}>
        <label style={{ display: 'grid', gap: '.2rem', fontSize: '.82rem', color: 'var(--color-neutral-700)' }}>
          File
          <input ref={fileInputRef} type="file" data-testid="attachment-file-input" />
        </label>
        <label style={{ display: 'grid', gap: '.2rem', fontSize: '.82rem', color: 'var(--color-neutral-700)' }}>
          Description (optional)
          <input
            type="text"
            data-testid="attachment-description-input"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            style={{
              border: '1px solid var(--color-neutral-400)',
              borderRadius: '4px',
              padding: '.35rem .45rem',
              minWidth: '220px',
            }}
          />
        </label>
        <Button
          variant="primary"
          size="sm"
          data-testid="attachment-upload-button"
          onClick={onUpload}
          loading={upload.isPending}
          disabled={upload.isPending}
        >
          Upload
        </Button>
      </div>

      {uploadError && (
        <p
          data-testid="attachment-upload-error"
          data-error-kind={uploadError.kind}
          role="alert"
          style={{ color: 'var(--color-error-dark)', fontSize: '.85rem', marginBottom: '.85rem' }}
        >
          {uploadError.message}
        </p>
      )}

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void attachmentsQuery.refetch() }}
        rateLimitRetryAfter={
          rendererState === 'rate-limit' ? getRetryAfterSeconds(attachmentsQuery.error) : undefined
        }
      >
        <DataTable columns={columns} data={rows} emptyMessage="No attachments yet." />
      </QueryStateBoundary>
    </section>
  )
}
