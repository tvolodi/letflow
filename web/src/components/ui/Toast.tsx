/** Toast — design-system primitive (REQ-275, docs/frontend/design-system.md §7.4)
 *
 *  ToastContainer subscribes to the useToast.ts module-level store and renders the
 *  current entries top-right, newest first, capped at 4 (enforced by the store).
 *  All colors/spacing/typography are sourced from web/src/styles/tokens.css custom
 *  properties — no hex/rgb/hsl literal appears in this file.
 */

import React, { useSyncExternalStore } from 'react'
import {
  dismissToast,
  getToastSnapshot,
  subscribeToasts,
  type ToastEntry,
  type ToastVariant,
} from '../../hooks/useToast'

interface VariantColors {
  background: string
  text: string
}

const VARIANT_BG: Record<ToastVariant, string> = {
  success: 'var(--color-success-light)',
  error: 'var(--color-error-light)',
  warning: 'var(--color-warning-light)',
}

const VARIANT_TEXT: Record<ToastVariant, string> = {
  success: 'var(--color-success-dark)',
  error: 'var(--color-error-dark)',
  warning: 'var(--color-warning-dark)',
}

function variantColors(variant: ToastVariant): VariantColors {
  return { background: VARIANT_BG[variant], text: VARIANT_TEXT[variant] }
}

interface ToastItemProps {
  entry: ToastEntry
}

function ToastItem({ entry }: ToastItemProps): React.ReactElement {
  const colors = variantColors(entry.variant)

  return (
    <div
      data-testid="toast-item"
      data-variant={entry.variant}
      role="status"
      aria-live={entry.variant === 'error' ? 'assertive' : 'polite'}
      style={{
        background: colors.background,
        borderRadius: 'var(--radius-sm)',
        boxShadow: 'var(--shadow-card)',
        padding: 'var(--space-3) var(--space-4)',
        display: 'flex',
        alignItems: 'flex-start',
        gap: 'var(--space-2)',
        minWidth: '280px',
        maxWidth: '380px',
      }}
    >
      <div style={{ flex: 1 }}>
        <p
          data-testid="toast-message"
          style={{ color: colors.text, fontSize: 'var(--text-sm)', margin: 0 }}
        >
          {entry.message}
        </p>
        {entry.description && (
          <p
            data-testid="toast-description"
            style={{ color: colors.text, fontSize: 'var(--text-sm)', margin: 'var(--space-1) 0 0' }}
          >
            {entry.description}
          </p>
        )}
      </div>
      <button
        data-testid="toast-close"
        type="button"
        aria-label="Dismiss notification"
        onClick={() => dismissToast(entry.id)}
        style={{
          background: 'transparent',
          border: 'none',
          color: 'var(--text-secondary)',
          cursor: 'pointer',
        }}
      >
        ×
      </button>
    </div>
  )
}

export function ToastContainer(): React.ReactElement | null {
  const entries = useSyncExternalStore(subscribeToasts, getToastSnapshot)

  if (entries.length === 0) {
    return null
  }

  return (
    <div
      data-testid="toast-container"
      style={{
        position: 'fixed',
        top: 'var(--space-4)',
        right: 'var(--space-4)',
        display: 'flex',
        flexDirection: 'column',
        gap: 'var(--space-2)',
        zIndex: 700,
      }}
    >
      {entries.map((entry) => (
        <ToastItem key={entry.id} entry={entry} />
      ))}
    </div>
  )
}
