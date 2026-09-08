/** FilterBar — design-system primitive (REQ-274, docs/frontend/design-system.md §7.7)
 *
 *  Pure layout/chrome component — it holds no filter *values*. Each filter
 *  control inside it (text input, select, date range, etc.) is the composing
 *  page's own responsibility, consistent with PageLayout (§8) also being a
 *  pure layout wrapper. See lib/letflow/design/req274-datatable-filterbar.md
 *  §3 (OQ-3: `onClear`/`activeCount` are this design's inference beyond §8's
 *  bare `<FilterBar>{children}</FilterBar>` usage example).
 */

import React from 'react'
import { Button } from './Button'

export interface FilterBarProps {
  children: React.ReactNode
  onClear?: () => void
  activeCount?: number
}

export function FilterBar(props: FilterBarProps): React.ReactElement {
  const { children, onClear, activeCount = 0 } = props

  const showClear = !!onClear && activeCount > 0

  return (
    <div
      data-testid="filter-bar"
      style={{
        display: 'flex',
        flexWrap: 'wrap',
        alignItems: 'center',
        gap: 'var(--space-3)',
        background: 'var(--surface-card)',
        border: '1px solid var(--border-default)',
        borderRadius: 'var(--radius-sm)',
        padding: 'var(--space-3) var(--space-4)',
      }}
    >
      {children}

      {activeCount > 0 && (
        <span
          data-testid="filter-bar-count"
          style={{
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            minWidth: '1.5rem',
            padding: 'var(--space-1) var(--space-2)',
            background: 'var(--color-neutral-200)',
            color: 'var(--text-secondary)',
            borderRadius: 'var(--radius-full)',
            fontSize: 'var(--text-xs)',
          }}
        >
          {activeCount}
        </span>
      )}

      {showClear && (
        <span style={{ marginLeft: 'auto' }}>
          <Button variant="ghost" size="sm" onClick={onClear} data-testid="filter-bar-clear">
            Clear filters
          </Button>
        </span>
      )}
    </div>
  )
}
