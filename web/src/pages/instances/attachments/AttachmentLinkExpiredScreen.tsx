/** AttachmentLinkExpiredScreen — REQ-387 §3.3
 *
 *  Fixed heading + body text, distinct in wording from AttachmentNotFoundScreen,
 *  plus a "Request new link" affordance wired to §3.4's requestFreshLink. No
 *  document content of any kind is rendered here -- ViewerStatus's 'expired'
 *  and 'success' kinds are mutually exclusive by construction (one status
 *  field), so there is no code path that could render both at once.
 */
import React from 'react'
import { Button } from '@/components/ui/Button'

interface AttachmentLinkExpiredScreenProps {
  onRequestFreshLink: () => void
  requesting: boolean
}

export function AttachmentLinkExpiredScreen({
  onRequestFreshLink,
  requesting,
}: AttachmentLinkExpiredScreenProps): React.ReactElement {
  return (
    <div data-testid="attachment-link-expired" style={{ padding: '1.5rem' }}>
      <h2 style={{ marginBottom: '.75rem' }}>Link expired</h2>
      <p style={{ color: 'var(--text-secondary)', marginBottom: '1rem' }}>
        This link has expired. Request a new link to view this document.
      </p>
      <Button
        variant="primary"
        size="sm"
        data-testid="attachment-request-fresh-link"
        onClick={onRequestFreshLink}
        loading={requesting}
        disabled={requesting}
      >
        Request new link
      </Button>
    </div>
  )
}
