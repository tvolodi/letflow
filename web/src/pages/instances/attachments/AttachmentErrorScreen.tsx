/** AttachmentErrorScreen — REQ-387 §3.3
 *
 *  Catch-all for 422/500/other non-404/410 responses. Deliberately a
 *  SEPARATE component from AttachmentNotFoundScreen -- folding an
 *  unrelated error class into the byte-identical-required not-found
 *  surface would blur AC3's strict "404-only" contract (design §3.3, §9 OQ-2).
 */
import React from 'react'

export function AttachmentErrorScreen(): React.ReactElement {
  return (
    <div data-testid="attachment-error" style={{ padding: '1.5rem' }}>
      <h2 style={{ marginBottom: '.75rem' }}>Something went wrong</h2>
      <p style={{ color: 'var(--text-secondary)' }}>
        Something went wrong loading this document. Try again later.
      </p>
    </div>
  )
}
