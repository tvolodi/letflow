/** AttachmentViewerPage — document-viewer screen for instance attachments
 *  (REQ-387, wired to REQ-386's signed-link fetch path).
 *
 *  Route: /instances/:id/attachments/:attachmentId
 *
 *  See lib/letflow/design/req387-attachment-document-viewer.md §1/§3.2 for
 *  the full flow rationale. Summary:
 *
 *  1. On mount, if the URL carries no `link_token` query param, issue one
 *     via attachmentsApi.issueLink, then rewrite the URL to carry it
 *     (setSearchParams({ link_token }, { replace: true })) -- D2, a
 *     disclosed, reviewed tradeoff (reload/bookmark reproducibility vs. a
 *     short-lived credential sitting in browser-persisted surfaces).
 *  2. Fetch the attachment bytes via attachmentsApi.fetchLinkContent
 *     (client.getBlob -- D1, never a raw <img src>/<a href>/<iframe src>
 *     pointed at the backend).
 *  3. Branch on the response:
 *       200 -> 'success'   (AttachmentSuccessView)
 *       404 -> 'not-found' (AttachmentNotFoundScreen, zero props)
 *       410 -> 'expired'   (AttachmentLinkExpiredScreen)
 *       any other status -> 'error' (AttachmentErrorScreen)
 *  4. If the URL already carries a `link_token` on mount (reload/bookmark),
 *     skip issuance and fetch content directly with that token.
 */
import { useCallback, useEffect, useRef, useState } from 'react'
import { useParams, useSearchParams } from 'react-router-dom'
import { attachmentsApi } from '@/api/attachments'
import { AttachmentSuccessView } from './attachments/AttachmentSuccessView'
import { AttachmentNotFoundScreen } from './attachments/AttachmentNotFoundScreen'
import { AttachmentLinkExpiredScreen } from './attachments/AttachmentLinkExpiredScreen'
import { AttachmentErrorScreen } from './attachments/AttachmentErrorScreen'
import type { ApiError } from '@/types/api'

type ViewerStatus =
  | { kind: 'loading' }
  | { kind: 'success'; blob: Blob; contentType: string; fileName: string | null }
  | { kind: 'not-found' }
  | { kind: 'expired' }
  | { kind: 'error' }

function errorStatus(err: unknown): number | undefined {
  const apiErr = err as ApiError | undefined
  return apiErr && typeof apiErr.status === 'number' ? apiErr.status : undefined
}

export default function AttachmentViewerPage() {
  const { id, attachmentId } = useParams<{ id: string; attachmentId: string }>()
  const [searchParams, setSearchParams] = useSearchParams()

  const [status, setStatus] = useState<ViewerStatus>({ kind: 'loading' })
  const [requestingFreshLink, setRequestingFreshLink] = useState(false)

  // Guards against a second run of the mount effect under React 18 strict
  // mode / a fast remount from re-rendering with the just-rewritten
  // searchParams -- fetchContentWithToken below is what actually issues the
  // network calls; this ref only prevents double-firing the *initial*
  // mount flow for the same instanceId/attachmentId pair.
  const initialFlowKeyRef = useRef<string | null>(null)

  const fetchContentWithToken = useCallback(
    async (instanceId: string, attId: string, token: string) => {
      try {
        const { blob, contentType } = await attachmentsApi.fetchLinkContent(instanceId, attId, token)
        setStatus({ kind: 'success', blob, contentType, fileName: null })
      } catch (err) {
        const httpStatus = errorStatus(err)
        if (httpStatus === 410) {
          setStatus({ kind: 'expired' })
        } else if (httpStatus === 404) {
          setStatus({ kind: 'not-found' })
        } else {
          setStatus({ kind: 'error' })
        }
      }
    },
    [],
  )

  const issueAndFetch = useCallback(
    async (instanceId: string, attId: string) => {
      try {
        const link = await attachmentsApi.issueLink(instanceId, attId)
        setSearchParams({ link_token: link.token }, { replace: true })
        await fetchContentWithToken(instanceId, attId, link.token)
      } catch (err) {
        const httpStatus = errorStatus(err)
        if (httpStatus === 404) {
          setStatus({ kind: 'not-found' })
        } else {
          setStatus({ kind: 'error' })
        }
      }
    },
    [fetchContentWithToken, setSearchParams],
  )

  useEffect(() => {
    if (!id || !attachmentId) return

    const flowKey = `${id}:${attachmentId}`
    const existingToken = searchParams.get('link_token')

    // Only drive the initial flow once per (instanceId, attachmentId) pair.
    // A reload with an existing link_token still goes straight to step 3
    // (fetchContentWithToken) every time this key changes.
    if (initialFlowKeyRef.current === flowKey) return
    initialFlowKeyRef.current = flowKey

    setStatus({ kind: 'loading' })
    if (existingToken) {
      void fetchContentWithToken(id, attachmentId, existingToken)
    } else {
      void issueAndFetch(id, attachmentId)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, attachmentId])

  const onRequestFreshLink = useCallback(() => {
    if (!id || !attachmentId) return
    setRequestingFreshLink(true)
    setStatus({ kind: 'loading' })
    void issueAndFetch(id, attachmentId).finally(() => setRequestingFreshLink(false))
  }, [id, attachmentId, issueAndFetch])

  switch (status.kind) {
    case 'loading':
      return <div style={{ padding: '1.5rem' }}>Loading document...</div>
    case 'success':
      return <AttachmentSuccessView blob={status.blob} contentType={status.contentType} />
    case 'not-found':
      return <AttachmentNotFoundScreen />
    case 'expired':
      return (
        <AttachmentLinkExpiredScreen
          onRequestFreshLink={onRequestFreshLink}
          requesting={requestingFreshLink}
        />
      )
    case 'error':
      return <AttachmentErrorScreen />
    default: {
      const _exhaustive: never = status
      void _exhaustive
      return null
    }
  }
}
