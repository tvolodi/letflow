/** PaginationControls — design-system primitive (REQ-287, docs/frontend/design-system.md §7.8)
 *
 *  Pure derived-value component — it holds no state of its own (no local
 *  mirror of `page`/`pageSize`). Supports both known-total pagination
 *  ("Showing X-Y of Z") and cursor-based pagination where `totalItems` is
 *  `null` and the caller supplies `hasNextPage` instead (see
 *  lib/letflow/design/req287-design-system-primitives-group4.md §1.3 for why
 *  `hasNextPage` exists — neither AuditLogPage nor InstanceBoardPage can
 *  provide a total row count, only a "does another page exist" boolean
 *  derived from their cursor-based API responses).
 */

import React from 'react'
import { Button } from './Button'

export interface PaginationControlsProps {
  page: number // 1-indexed current page
  pageSize: number // one of 25, 50, 100
  totalItems: number | null // null when total is unknown (cursor-based pagination)
  onPageChange: (page: number) => void
  onPageSizeChange?: (pageSize: number) => void // omit to hide the size selector
  hasNextPage?: boolean // consulted only when totalItems is null
}

export const PAGE_SIZE_OPTIONS = [25, 50, 100] as const

export function PaginationControls(props: PaginationControlsProps): React.ReactElement {
  const { page, pageSize, totalItems, onPageChange, onPageSizeChange, hasNextPage } = props

  const start = (page - 1) * pageSize + 1
  const end = totalItems === null ? page * pageSize : Math.min(page * pageSize, totalItems)
  const summaryText =
    totalItems === null ? `Showing ${start}-${end}` : `Showing ${start}-${end} of ${totalItems}`

  const isPrevDisabled = page <= 1
  const isNextDisabled =
    totalItems === null ? hasNextPage !== true : page * pageSize >= totalItems
  const showSizeSelector = onPageSizeChange !== undefined

  return (
    <div
      data-testid="pagination-controls"
      style={{
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'center',
        gap: 'var(--space-4)',
        borderTop: '1px solid var(--border-default)',
        paddingTop: 'var(--space-3)',
      }}
    >
      <span
        data-testid="pagination-summary"
        style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}
      >
        {summaryText}
      </span>
      <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-3)' }}>
        {showSizeSelector && (
          <select
            data-testid="pagination-size-select"
            aria-label="Items per page"
            value={pageSize}
            onChange={(event) => onPageSizeChange?.(Number(event.target.value))}
            style={{
              border: '1px solid var(--border-default)',
              borderRadius: 'var(--radius-sm)',
              padding: 'var(--space-1) var(--space-2)',
              fontSize: 'var(--text-sm)',
              color: 'var(--text-primary)',
              background: 'var(--surface-card)',
            }}
          >
            {PAGE_SIZE_OPTIONS.map((size) => (
              <option key={size} value={size}>
                {size} / page
              </option>
            ))}
          </select>
        )}
        <span data-testid="pagination-prev">
          <Button
            variant="secondary"
            size="sm"
            disabled={isPrevDisabled}
            onClick={() => onPageChange(page - 1)}
          >
            Previous
          </Button>
        </span>
        <span data-testid="pagination-next">
          <Button
            variant="secondary"
            size="sm"
            disabled={isNextDisabled}
            onClick={() => onPageChange(page + 1)}
          >
            Next
          </Button>
        </span>
      </div>
    </div>
  )
}
