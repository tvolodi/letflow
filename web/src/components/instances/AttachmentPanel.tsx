/** AttachmentPanel — upload/list widget for instance attachments (REQ-212/387)
 *
 *  Mounted inside InstanceDetailPage.tsx alongside EventHistoryPanel/TimelineFeed
 *  -- same "one focused panel component per concern" pattern that page already
 *  follows. See lib/letflow/design/req387-attachment-document-viewer.md §3.1.
 */
import { useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAttachments, useUploadAttachment } from '@/hooks/useAttachments'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { Button } from '@/components/ui/Button'
import { useToast } from '@/hooks/useToast'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { formatDateTime } from '@/i18n/format'
import type { Attachment } from '@/types/api'

interface AttachmentPanelProps {
  instanceId: string
}

interface AttachmentRow {
  key: string
  attachment: Attachment
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
  const toast = useToast()
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [description, setDescription] = useState('')

  const rendererState: RendererState = attachmentsQuery.isLoading
    ? 'loading'
    : attachmentsQuery.isError
      ? classifyError(attachmentsQuery.error)
      : 'success'

  const onUpload = () => {
    const file = fileInputRef.current?.files?.[0]
    if (!file) return

    const formData = new FormData()
    formData.append('file', file)
    if (description.trim() !== '') {
      formData.append('description', description.trim())
    }

    upload.mutate(formData, {
      onSuccess: () => {
        toast.success('Attachment uploaded.')
        setDescription('')
        if (fileInputRef.current) fileInputRef.current.value = ''
      },
      onError: () => {
        toast.error('Failed to upload attachment.')
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
  ]

  const rows: AttachmentRow[] = (attachmentsQuery.data?.items ?? []).map((attachment) => ({
    key: attachment.id,
    attachment,
  }))

  return (
    <section data-testid="attachment-panel">
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
