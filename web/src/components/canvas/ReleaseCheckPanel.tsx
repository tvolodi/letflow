/**
 * ReleaseCheckPanel — REQ-431 §6.2: a distinct, freshly-run release-submission
 * re-check surface, deliberately separate from ValidationSummaryBar (the
 * save-time bar). EO-005's whole point is that a release-time check is a
 * NEW event the author can tell apart from a stale save-time result,
 * including the specific case where save-time was clean and release-time is
 * not (AC5) — reusing the save-time bar would risk visually conflating
 * "saved clean a while ago" with "checked again just now and failed".
 */

import type { ValidationError } from './ValidationSummaryBar'

export type ReleaseCheckState =
  | { phase: 'idle' }
  | { phase: 'checking' }
  | { phase: 'clean'; checkedAt: string }
  | { phase: 'blocked'; checkedAt: string; violations: ValidationError[] }
  | { phase: 'error'; checkedAt: string; message: string }

interface ReleaseCheckPanelProps {
  state: ReleaseCheckState
}

export default function ReleaseCheckPanel({ state }: ReleaseCheckPanelProps) {
  if (state.phase === 'idle') return null

  if (state.phase === 'checking') {
    return (
      <div
        data-testid="release-check-panel"
        data-release-check-phase="checking"
        style={{
          padding: '8px 16px',
          background: 'var(--surface-card)',
          color: 'var(--text-secondary)',
          fontSize: 'var(--text-sm)',
          borderBottom: '1px solid var(--border-default)',
        }}
      >
        Re-checking every rule…
      </div>
    )
  }

  if (state.phase === 'clean') {
    return (
      <div
        data-testid="release-check-panel"
        data-release-check-phase="clean"
        style={{
          padding: '8px 16px',
          background: 'var(--color-success-light)',
          color: 'var(--color-success-dark)',
          fontSize: 'var(--text-sm)',
          borderBottom: '1px solid var(--color-success)',
        }}
      >
        All rules passed a fresh check at {state.checkedAt}.
      </div>
    )
  }

  if (state.phase === 'blocked') {
    return (
      <div
        data-testid="release-check-panel"
        data-release-check-phase="blocked"
        style={{
          background: 'var(--color-error-light)',
          borderBottom: '1px solid var(--color-error)',
        }}
      >
        <div
          style={{
            padding: '6px 16px',
            fontWeight: 600,
            fontSize: 'var(--text-sm)',
            color: 'var(--color-error)',
          }}
        >
          Release blocked — {state.violations.length} problem
          {state.violations.length !== 1 ? 's' : ''} found on submission (checked at {state.checkedAt})
        </div>
        <div style={{ padding: '0 16px 8px', maxHeight: 160, overflowY: 'auto' }}>
          {state.violations.map((v, idx) => (
            <div
              key={idx}
              data-testid="release-check-violation"
              style={{
                display: 'flex',
                alignItems: 'flex-start',
                gap: 6,
                padding: '3px 0',
                fontSize: 'var(--text-xs, 0.75rem)',
                color: 'var(--text-primary)',
              }}
            >
              <span style={{ color: 'var(--color-error)', fontWeight: 'bold', flexShrink: 0 }}>✗</span>
              <span>{v.message}</span>
            </div>
          ))}
        </div>
      </div>
    )
  }

  // 'error' — non-violation failure path (e.g. the semantic-validation
  // precondition failed and carried no violation content).
  return (
    <div
      data-testid="release-check-panel"
      data-release-check-phase="error"
      style={{
        padding: '8px 16px',
        background: 'var(--color-error-light)',
        color: 'var(--color-error-dark)',
        fontSize: 'var(--text-sm)',
        borderBottom: '1px solid var(--color-error)',
      }}
    >
      Release check failed: {state.message}
    </div>
  )
}
