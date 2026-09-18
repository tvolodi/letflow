/** HelpTrigger — REQ-366 §2.3
 *
 *  The "?" affordance, one per screen. Design choice (§2.3): fixed
 *  position, top-right of the screen's own content header/toolbar region —
 *  rendered into `PageLayout`'s existing `actions` slot at each call site,
 *  not a new global floating-corner element.
 *
 *  §2.2.1 / OQ-4: `useHelpContent` resolving `not-found` (no help authored
 *  for this screen_id yet) renders nothing at all — not an error state, and
 *  not a disabled affordance (OQ-4 leaves this to FRONTEND-DEV's own
 *  judgement; "renders nothing" was chosen since a permanently-disabled "?"
 *  with nothing behind it has no value to a user and this app has no other
 *  precedent for a disabled-and-inert chrome affordance). Loading and error
 *  states likewise render nothing — a transient loading flicker or a failed
 *  fetch of a purely-assistive affordance is not worth surfacing as visible
 *  chrome; the panel appears once `useHelpContent` resolves `ready`.
 */

import type React from 'react'
import { useState } from 'react'
import { HelpCircle } from 'lucide-react'
import { useHelpContent } from '@/hooks/useHelpContent'
import { HelpPanel } from './HelpPanel'

export interface HelpTriggerProps {
  screenId: string
  processDefinitionId?: string
}

export function HelpTrigger(props: HelpTriggerProps): React.ReactElement | null {
  const { screenId, processDefinitionId } = props
  const [open, setOpen] = useState(false)
  const result = useHelpContent(screenId, processDefinitionId)

  if (result.status !== 'ready') return null

  return (
    <>
      <button
        type="button"
        data-testid="help-trigger"
        aria-label="Help"
        onClick={() => setOpen(true)}
        style={{
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          width: '32px',
          height: '32px',
          borderRadius: 'var(--radius-full)',
          border: '1px solid var(--border-default)',
          background: 'var(--surface-card)',
          color: 'var(--text-secondary)',
          cursor: 'pointer',
        }}
      >
        <HelpCircle size={18} aria-hidden="true" />
      </button>
      {open && <HelpPanel content={result.content} onClose={() => setOpen(false)} />}
    </>
  )
}
