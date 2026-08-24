import type { CSSProperties } from 'react'
import type { WebhookDeliveryAttempt } from '@/types/api'

interface WebhookDeliveryAttemptsTableProps {
  attempts: WebhookDeliveryAttempt[]
}

function formatTimestamp(value: string): string {
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toLocaleString()
}

function statusStyles(status: WebhookDeliveryAttempt['status']): { badge: CSSProperties; row: CSSProperties } {
  if (status === 'FAILED') {
    return {
      badge: {
        display: 'inline-flex',
        alignItems: 'center',
        gap: '.35rem',
        borderRadius: '999px',
        padding: '.2rem .55rem',
        background: 'var(--color-error-light)',
        color: 'var(--color-error-dark)',
        fontWeight: 700,
        fontSize: '.75rem',
      },
      row: {
        background: 'var(--color-error-tint)',
      },
    }
  }

  return {
    badge: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: '.35rem',
      borderRadius: '999px',
      padding: '.2rem .55rem',
      background: 'var(--color-success-light)',
      color: 'var(--color-success-dark)',
      fontWeight: 700,
      fontSize: '.75rem',
    },
    row: {
      background: 'var(--surface-card)',
    },
  }
}

export function WebhookDeliveryAttemptsTable({ attempts }: WebhookDeliveryAttemptsTableProps) {
  return (
    <table
      data-testid="webhook-delivery-attempts-table"
      style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}
    >
      <thead>
        <tr style={{ background: 'var(--surface-page)', textAlign: 'left' }}>
          <th style={{ padding: '.6rem .7rem' }}>Status</th>
          <th style={{ padding: '.6rem .7rem' }}>HTTP code</th>
          <th style={{ padding: '.6rem .7rem' }}>Timestamp</th>
          <th style={{ padding: '.6rem .7rem' }}>Event type</th>
          <th style={{ padding: '.6rem .7rem' }}>Attempt</th>
        </tr>
      </thead>
      <tbody>
        {attempts.map((attempt) => {
          const style = statusStyles(attempt.status)

          return (
            <tr
              key={attempt.delivery_id}
              data-testid={attempt.status === 'FAILED' ? 'webhook-delivery-row-failed' : 'webhook-delivery-row-success'}
              style={{ borderBottom: '1px solid var(--border-default)', ...style.row }}
            >
              <td style={{ padding: '.7rem', verticalAlign: 'top' }}>
                <span style={style.badge}>{attempt.status}</span>
                {attempt.last_error ? (
                  <div style={{ marginTop: '.35rem', color: 'var(--color-error-dark)', fontSize: '.75rem' }}>{attempt.last_error}</div>
                ) : null}
              </td>
              <td style={{ padding: '.7rem', verticalAlign: 'top', fontFamily: 'monospace' }}>
                {attempt.http_status_code ?? '—'}
              </td>
              <td style={{ padding: '.7rem', verticalAlign: 'top', color: 'var(--color-neutral-700)' }}>
                {formatTimestamp(attempt.attempted_at)}
              </td>
              <td style={{ padding: '.7rem', verticalAlign: 'top', color: 'var(--color-neutral-700)' }}>{attempt.event_type}</td>
              <td style={{ padding: '.7rem', verticalAlign: 'top', color: 'var(--color-neutral-700)' }}>
                {attempt.attempt_count} / {attempt.max_attempts}
              </td>
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}