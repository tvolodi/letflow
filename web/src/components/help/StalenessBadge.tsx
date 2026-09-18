/** StalenessBadge — REQ-366 §6, design §2.3
 *
 *  Visible indicator `HelpPanel` renders per §2.3's render order:
 *    content.stale
 *      ? <StalenessBadge kind="stale" />
 *      : <StalenessBadge kind="reviewed" confirmedAt={content.confirmedAt} />
 *
 *  `stale` is server-computed (`Letflow.Routers.Help.compute_stale/2`) —
 *  this component never re-derives it. For non-process help (`stale` is
 *  always `false` server-side, §1.2 step 6), the plain "last reviewed
 *  <date>" reading from `confirmedAt` is what `kind="reviewed"` renders;
 *  `confirmedAt === null` (never yet confirmed) renders no date rather than
 *  inventing one.
 */

import type React from 'react'
import { formatDate } from '@/i18n/format'

export type StalenessBadgeProps =
  | { kind: 'stale' }
  | { kind: 'reviewed'; confirmedAt: string | null }

export function StalenessBadge(props: StalenessBadgeProps): React.ReactElement {
  if (props.kind === 'stale') {
    return (
      <span
        data-testid="help-staleness-badge"
        data-staleness="stale"
        role="status"
        style={{
          display: 'inline-flex',
          alignItems: 'center',
          gap: 'var(--space-1)',
          background: 'var(--color-warning-light)',
          color: 'var(--color-warning-dark)',
          padding: 'var(--space-1) var(--space-2)',
          borderRadius: 'var(--radius-full)',
          fontSize: 'var(--text-xs)',
        }}
      >
        This help content may be outdated
      </span>
    )
  }

  const { confirmedAt } = props

  return (
    <span
      data-testid="help-staleness-badge"
      data-staleness="reviewed"
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--space-1)',
        color: 'var(--text-secondary)',
        fontSize: 'var(--text-xs)',
      }}
    >
      {confirmedAt ? `Last reviewed ${formatDate(confirmedAt)}` : 'Not yet reviewed'}
    </span>
  )
}
