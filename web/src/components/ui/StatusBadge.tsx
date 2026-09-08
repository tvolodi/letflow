/** StatusBadge — design-system primitive (REQ-272, docs/frontend/design-system.md §5)
 *
 *  Resolves a (domain, status) pair to a background/text/dot token triple per
 *  §5.1 (definition), §5.2 (instance), §5.3 (task — no dot column). `timer`
 *  and `dlq` domains appear in §5.4's API but have no status table anywhere
 *  in design-system.md (spec gap, not an omission here) — any status in
 *  those domains, and any unrecognised status in a domain that does have a
 *  table, falls back to a defined neutral badge rather than throwing or
 *  rendering undefined styles.
 */

import React from 'react'

export type StatusBadgeDomain = 'definition' | 'instance' | 'task' | 'timer' | 'dlq'

export interface StatusBadgeProps {
  status: string
  domain: StatusBadgeDomain
  size?: 'sm' | 'md'
}

interface ResolvedStatus {
  background: string
  text: string
  dot?: string
  pulse?: boolean
}

const FALLBACK: ResolvedStatus = {
  background: 'var(--color-neutral-100)',
  text: 'var(--text-secondary)',
}

const DEFINITION_STATUSES: Record<string, ResolvedStatus> = {
  DRAFT: { background: 'var(--color-neutral-100)', text: 'var(--text-secondary)', dot: 'var(--color-neutral-500)' },
  ACTIVE: { background: 'var(--color-success-light)', text: 'var(--color-success-dark)', dot: 'var(--color-success)' },
  DEPRECATED: { background: 'var(--color-warning-light)', text: 'var(--color-warning-dark)', dot: 'var(--color-warning)' },
  ARCHIVED: { background: 'var(--color-neutral-200)', text: 'var(--color-neutral-600)', dot: 'var(--color-neutral-400)' },
}

const INSTANCE_STATUSES: Record<string, ResolvedStatus> = {
  ACTIVE: { background: 'var(--color-info-light)', text: 'var(--color-info-dark)', dot: 'var(--color-info)', pulse: true },
  COMPLETED: { background: 'var(--color-success-light)', text: 'var(--color-success-dark)', dot: 'var(--color-success)', pulse: false },
  CANCELLED: { background: 'var(--color-neutral-200)', text: 'var(--color-neutral-600)', dot: 'var(--color-neutral-400)', pulse: false },
  ERROR: { background: 'var(--color-error-light)', text: 'var(--color-error-dark)', dot: 'var(--color-error)', pulse: false },
}

// Task domain has no Dot column in §5.3 — entries deliberately omit `dot`.
const TASK_STATUSES: Record<string, ResolvedStatus> = {
  PENDING: { background: 'var(--color-info-light)', text: 'var(--color-info-dark)' },
  COMPLETED: { background: 'var(--color-success-light)', text: 'var(--color-success-dark)' },
  CANCELLED: { background: 'var(--color-neutral-200)', text: 'var(--color-neutral-600)' },
}

// timer/dlq: no status table exists anywhere in design-system.md (spec gap,
// tracked as OQ-3 in lib/letflow/design/req272-design-system-primitives-group1.md).
// Every status in these domains resolves through FALLBACK below.
const STATUS_TABLES: Partial<Record<StatusBadgeDomain, Record<string, ResolvedStatus>>> = {
  definition: DEFINITION_STATUSES,
  instance: INSTANCE_STATUSES,
  task: TASK_STATUSES,
}

function resolveStatus(domain: StatusBadgeDomain, status: string): ResolvedStatus {
  const table = STATUS_TABLES[domain]
  const resolved = table?.[status]
  if (resolved) return resolved

  if (import.meta.env.DEV) {
    console.warn(`StatusBadge: no status table entry for domain="${domain}" status="${status}" — rendering fallback badge.`)
  }
  return FALLBACK
}

interface SizeStyle {
  padding: string
  fontSize: string
  dotDiameter: string
}

const SIZE_STYLES: Record<NonNullable<StatusBadgeProps['size']>, SizeStyle> = {
  sm: { padding: 'var(--space-1) var(--space-2)', fontSize: 'var(--text-xs)', dotDiameter: '6px' },
  md: { padding: 'var(--space-1) var(--space-3)', fontSize: 'var(--text-sm)', dotDiameter: '8px' },
}

export function StatusBadge(props: StatusBadgeProps): React.ReactElement {
  const { status, domain, size = 'md' } = props

  const resolved = resolveStatus(domain, status)
  const sizeStyle = SIZE_STYLES[size]

  return (
    <span
      data-testid="status-badge"
      data-status={status}
      data-domain={domain}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--space-1)',
        background: resolved.background,
        color: resolved.text,
        padding: sizeStyle.padding,
        fontSize: sizeStyle.fontSize,
        borderRadius: 'var(--radius-full)',
      }}
    >
      {resolved.dot && (
        <span
          data-testid="status-badge-dot"
          style={{
            display: 'inline-block',
            width: sizeStyle.dotDiameter,
            height: sizeStyle.dotDiameter,
            borderRadius: 'var(--radius-full)',
            background: resolved.dot,
            animation: resolved.pulse ? 'ds-status-badge-pulse 1.5s ease-in-out infinite' : undefined,
          }}
        />
      )}
      {status}
      <style>
        {`@keyframes ds-status-badge-pulse { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.5; transform: scale(1.25); } }`}
      </style>
    </span>
  )
}
