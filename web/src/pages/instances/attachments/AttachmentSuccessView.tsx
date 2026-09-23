/** AttachmentSuccessView — REQ-387 §3.3
 *
 *  D1 (design §1): attachment bytes are fetched via authenticated fetch
 *  (client.getBlob) and rendered through a browser-local
 *  URL.createObjectURL(blob) reference -- NEVER a raw <img src>/<a href>/
 *  <iframe src> pointed directly at the backend, since no bearer token
 *  would be attached to a browser-native resource fetch. The object URL is
 *  created on mount and revoked on unmount (or when the blob changes) to
 *  avoid a memory leak.
 */
import React, { useEffect, useState } from 'react'

interface AttachmentSuccessViewProps {
  blob: Blob
  contentType: string
}

export function AttachmentSuccessView({ blob, contentType }: AttachmentSuccessViewProps): React.ReactElement {
  const [objectUrl, setObjectUrl] = useState<string | null>(null)

  useEffect(() => {
    const url = URL.createObjectURL(blob)
    setObjectUrl(url)
    return () => {
      URL.revokeObjectURL(url)
    }
  }, [blob])

  if (!objectUrl) {
    return <div data-testid="attachment-content" style={{ padding: '1.5rem' }} />
  }

  if (contentType.startsWith('application/pdf')) {
    return (
      <div data-testid="attachment-content" style={{ padding: '1.5rem' }}>
        <iframe
          src={objectUrl}
          title="Attachment"
          style={{ width: '100%', height: '70vh', border: '1px solid var(--border-default)' }}
        />
      </div>
    )
  }

  if (contentType.startsWith('image/')) {
    return (
      <div data-testid="attachment-content" style={{ padding: '1.5rem' }}>
        <img src={objectUrl} alt="attachment" style={{ maxWidth: '100%' }} />
      </div>
    )
  }

  return (
    <div data-testid="attachment-content" style={{ padding: '1.5rem' }}>
      <p style={{ marginBottom: '.75rem', color: 'var(--text-secondary)' }}>
        This document cannot be previewed inline.
      </p>
      <a href={objectUrl} download data-testid="attachment-download-link">
        Download attachment
      </a>
    </div>
  )
}
