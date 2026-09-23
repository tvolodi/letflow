/** AttachmentNotFoundScreen — REQ-387 §3.3
 *
 *  ZERO props, zero interpolated data. Fixed heading + fixed body text only
 *  -- no attachment id, instance id, or error detail string from the
 *  response body, and no distinction between "issuance 404" and
 *  "content-fetch 404" (both branches of AttachmentViewerPage's state
 *  machine render this exact component). Since this component takes no
 *  data-bearing props at all, it is structurally impossible for its
 *  rendered output to differ between a foreign-tenant reference and a
 *  never-issued one (AC3/EO-001/EO-002) -- there is no code path by which
 *  per-request information could reach this component's render output.
 *
 *  Do NOT add a prop to this component. Any information that could differ
 *  between callers (attachment id, instance id, which call produced the
 *  404) must never reach this file -- that is the entire guarantee.
 */
import React from 'react'

export function AttachmentNotFoundScreen(): React.ReactElement {
  return (
    <div data-testid="attachment-not-found" style={{ padding: '1.5rem' }}>
      <h2 style={{ marginBottom: '.75rem' }}>Document not found.</h2>
      <p style={{ color: 'var(--text-secondary)' }}>
        This document does not exist or you do not have access to it.
      </p>
    </div>
  )
}
