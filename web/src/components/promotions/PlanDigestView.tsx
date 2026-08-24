/** PlanDigestView — PRM-03: Plan digest display + verification UI
 *
 *  Displays plan_digest in promotion review UI.
 *  Shows digest verification status (matched/mismatched).
 *  Displays the canonical JSON being digested (formatted, human-readable).
 */

import React, { useMemo } from 'react'
import type { PromotionPlan, PlanEntry } from '@/api/promotions'

export interface PlanDigestViewProps {
  /** The stored SHA-256 digest (lowercase hex, 64 chars) */
  planDigest: string
  /** The parsed PromotionPlan (entries array) */
  plan: PromotionPlan
  /** Whether the digest was verified as matching */
  digestVerified: boolean
  /** Optional className */
  className?: string
}

function formatJsonCanonical(plan: PromotionPlan): string {
  // Canonical JSON: keys sorted lexicographically, no insignificant whitespace
  // Re-serialise with sorted keys for display
  const canonical = {
    entries: plan.entries.map((entry) => ({
      // Keys in lexicographic order: after, before, change_kind, id, type
      after: entry.after,
      before: entry.before,
      change_kind: entry.change_kind,
      id: entry.id,
      type: entry.type,
    })),
  }
  return JSON.stringify(canonical)
}

const CHANGE_KIND_COLORS: Record<string, { bg: string; text: string; label: string }> = {
  added: { bg: 'var(--color-success-light)', text: 'var(--color-success-dark)', label: 'Added' },
  modified: { bg: 'var(--color-warning-light)', text: 'var(--color-warning-dark)', label: 'Modified' },
  removed: { bg: 'var(--color-error-light)', text: 'var(--color-error-dark)', label: 'Removed' },
}

export function PlanDigestView(props: PlanDigestViewProps): React.ReactElement {
  const { planDigest, plan, digestVerified, className } = props

  const canonicalJson = useMemo(() => formatJsonCanonical(plan), [plan])

  return (
    <div
      data-testid="plan-digest-view"
      className={className}
      style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}
    >
      {/* Digest + verification status */}
      <div
        style={{
          padding: '.75rem 1rem',
          borderRadius: '8px',
          border: `1px solid ${digestVerified ? 'var(--color-success)' : 'var(--color-error)'}`,
          background: digestVerified ? 'var(--color-success-tint)' : 'var(--color-error-tint)',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '1rem', flexWrap: 'wrap' }}>
          <div>
            <div style={{ fontSize: '.7rem', fontWeight: 600, color: 'var(--text-secondary)', marginBottom: '.2rem', textTransform: 'uppercase', letterSpacing: '.04em' }}>
              Plan Digest (SHA-256)
            </div>
            <code
              data-testid="plan-digest-value"
              style={{
                fontFamily: 'monospace',
                fontSize: '.8rem',
                color: 'var(--color-neutral-800)',
                background: 'var(--color-neutral-100)',
                padding: '.15rem .4rem',
                borderRadius: '4px',
                wordBreak: 'break-all',
              }}
            >
              {planDigest}
            </code>
          </div>

          {/* Verification badge */}
          <div
            data-testid="digest-verification-badge"
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: '.35rem',
              padding: '.3rem .65rem',
              borderRadius: '20px',
              background: digestVerified ? 'var(--color-success-light)' : 'var(--color-error-light)',
              border: `1px solid ${digestVerified ? 'var(--color-success)' : 'var(--color-error)'}`,
            }}
          >
            {digestVerified ? (
              <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="var(--color-success-dark)" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <polyline points="20 6 9 17 4 12" />
              </svg>
            ) : (
              <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="var(--color-error-dark)" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <line x1="18" y1="6" x2="6" y2="18" />
                <line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            )}
            <span style={{ fontSize: '.75rem', fontWeight: 600, color: digestVerified ? 'var(--color-success-dark)' : 'var(--color-error-dark)' }}>
              {digestVerified ? 'Digest Verified' : 'Digest Mismatch'}
            </span>
          </div>
        </div>
      </div>

      {/* Canonical JSON viewer */}
      <div>
        <div style={{ fontSize: '.75rem', fontWeight: 600, color: 'var(--color-neutral-700)', marginBottom: '.4rem', textTransform: 'uppercase', letterSpacing: '.04em' }}>
          Canonical Plan JSON
        </div>
        <pre
          data-testid="canonical-plan-json"
          style={{
            margin: 0,
            padding: '.75rem 1rem',
            background: 'var(--surface-page)',
            border: '1px solid var(--border-default)',
            borderRadius: '6px',
            fontFamily: 'monospace',
            fontSize: '.78rem',
            color: 'var(--color-neutral-800)',
            overflowX: 'auto',
            whiteSpace: 'pre-wrap',
            wordBreak: 'break-word',
            maxHeight: '300px',
            overflowY: 'auto',
          }}
        >
          {canonicalJson}
        </pre>
      </div>

      {/* Plan entries summary */}
      {plan.entries.length > 0 && (
        <div>
          <div style={{ fontSize: '.75rem', fontWeight: 600, color: 'var(--color-neutral-700)', marginBottom: '.4rem', textTransform: 'uppercase', letterSpacing: '.04em' }}>
            Plan Entries ({plan.entries.length})
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '.35rem' }}>
            {plan.entries.map((entry: PlanEntry, index: number) => {
              const ck = CHANGE_KIND_COLORS[entry.change_kind] ?? { bg: 'var(--color-neutral-100)', text: 'var(--color-neutral-700)', label: entry.change_kind }
              return (
                <div
                  key={`${entry.id}-${index}`}
                  data-testid={`plan-entry-${index}`}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: '.5rem',
                    padding: '.4rem .6rem',
                    borderRadius: '5px',
                    background: 'var(--surface-card)',
                    border: '1px solid var(--border-default)',
                  }}
                >
                  <span
                    style={{
                      padding: '.1rem .45rem',
                      borderRadius: '4px',
                      fontSize: '.7rem',
                      fontWeight: 600,
                      background: ck.bg,
                      color: ck.text,
                      flexShrink: 0,
                    }}
                  >
                    {ck.label}
                  </span>
                  <code style={{ fontFamily: 'monospace', fontSize: '.78rem', color: 'var(--color-neutral-800)', flexShrink: 0 }}>
                    {entry.type}:{entry.id}
                  </code>
                  {entry.change_kind === 'modified' && (
                    <span style={{ fontSize: '.75rem', color: 'var(--text-secondary)', marginLeft: 'auto' }}>
                      {entry.before && entry.after ? 'updated' : ''}
                    </span>
                  )}
                </div>
              )
            })}
          </div>
        </div>
      )}
    </div>
  )
}
