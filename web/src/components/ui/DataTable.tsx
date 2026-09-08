/** DataTable — design-system primitive (REQ-274, docs/frontend/design-system.md §7.2)
 *
 *  Public prop surface is intentionally the small, project-owned shape named
 *  by §7.2 (`columns, data, isLoading, emptyMessage, onRowClick`) — no
 *  `sortState`/`onSortChange` pair, since §7.2's API doesn't name one. Sort
 *  state lives inside the component (component-local asc/desc toggle) and is
 *  translated into a `@tanstack/react-table` `state.sorting` array at the
 *  TanStack boundary: TanStack Table (headless, no rendered markup of its
 *  own) supplies the row/column/sort *models*; this file renders all markup
 *  using this project's own tokens. See lib/letflow/design/req274-datatable-filterbar.md
 *  §1 for the full design rationale (OQ-1: `columns` is this project-owned
 *  shape, not TanStack's raw `ColumnDef<TRow>[]`; OQ-2: semantic `<table>`
 *  chosen for accessibility).
 */

import React, { useMemo, useState } from 'react'
import {
  useReactTable,
  getCoreRowModel,
  getSortedRowModel,
  type ColumnDef,
  type SortingState,
} from '@tanstack/react-table'
import { ChevronUp, ChevronDown, Inbox } from 'lucide-react'
import { SkeletonLayout } from './SkeletonLayout'

export interface DataTableColumn<TRow> {
  id: string
  header: string
  accessor: (row: TRow) => React.ReactNode
  sortable?: boolean
  sortValue?: (row: TRow) => string | number
}

export interface DataTableProps<TRow> {
  columns: DataTableColumn<TRow>[]
  data: TRow[]
  isLoading?: boolean
  emptyMessage: string
  onRowClick?: (row: TRow) => void
}

interface SortState {
  columnId: string | null
  direction: 'asc' | 'desc'
}

function toColumnDefs<TRow>(columns: DataTableColumn<TRow>[]): ColumnDef<TRow>[] {
  return columns.map((col) => ({
    id: col.id,
    header: col.header,
    accessorFn: (row: TRow) => (col.sortValue ? col.sortValue(row) : col.accessor(row)),
    enableSorting: !!col.sortable,
  }))
}

export function DataTable<TRow>(props: DataTableProps<TRow>): React.ReactElement {
  const { columns, data, isLoading = false, emptyMessage, onRowClick } = props

  const [sortState, setSortState] = useState<SortState>({ columnId: null, direction: 'asc' })

  const columnDefs = useMemo(() => toColumnDefs(columns), [columns])

  const sorting: SortingState = sortState.columnId
    ? [{ id: sortState.columnId, desc: sortState.direction === 'desc' }]
    : []

  const table = useReactTable({
    data,
    columns: columnDefs,
    state: { sorting },
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  })

  // `table` is a stable ref returned by useReactTable (mutated in place via
  // setOptions, not replaced), so memoizing on its identity would never
  // recompute after a sort-state change — call the row model directly instead;
  // it is already internally memoized against the options/state passed above.
  const sortedRows = table.getSortedRowModel().rows

  function handleHeaderClick(col: DataTableColumn<TRow>): void {
    if (!col.sortable) return
    setSortState((prev) => {
      if (prev.columnId !== col.id) {
        return { columnId: col.id, direction: 'asc' }
      }
      return { columnId: col.id, direction: prev.direction === 'asc' ? 'desc' : 'asc' }
    })
  }

  const isEmpty = !isLoading && data.length === 0

  return (
    <div data-testid="data-table" style={{ width: '100%' }}>
      <div
        data-testid="datatable-scroll-container"
        style={{ overflowY: 'auto', maxHeight: '32rem' }}
      >
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead
            data-testid="datatable-header"
            style={{
              position: 'sticky',
              top: 0,
              zIndex: 1,
              background: 'var(--surface-card)',
            }}
          >
            <tr>
              {columns.map((col) => {
                const isActive = sortState.columnId === col.id
                return (
                  <th
                    key={col.id}
                    data-testid={`datatable-header-${col.id}`}
                    onClick={() => handleHeaderClick(col)}
                    style={{
                      textAlign: 'left',
                      padding: 'var(--space-2) var(--space-4)',
                      borderBottom: '1px solid var(--border-default)',
                      color: isActive ? 'var(--text-primary)' : 'var(--text-secondary)',
                      fontSize: 'var(--text-sm)',
                      fontWeight: 'var(--font-medium)',
                      cursor: col.sortable ? 'pointer' : 'default',
                      userSelect: 'none',
                    }}
                  >
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 'var(--space-1)' }}>
                      {col.header}
                      {col.sortable && isActive && (
                        <span
                          data-testid={`datatable-sort-indicator-${col.id}`}
                          style={{ color: 'var(--text-primary)', display: 'inline-flex' }}
                        >
                          {sortState.direction === 'asc' ? (
                            <ChevronUp size={14} />
                          ) : (
                            <ChevronDown size={14} />
                          )}
                        </span>
                      )}
                    </span>
                  </th>
                )
              })}
            </tr>
          </thead>
          <tbody data-testid="datatable-body">
            {isLoading ? (
              <tr>
                <td colSpan={columns.length} style={{ padding: 0 }}>
                  <SkeletonLayout
                    columns={columns.map(() => ({ widthPercent: 100 / columns.length }))}
                  />
                </td>
              </tr>
            ) : isEmpty ? (
              <tr>
                <td colSpan={columns.length} style={{ padding: 0 }}>
                  <div
                    data-testid="datatable-empty-state"
                    style={{
                      display: 'flex',
                      flexDirection: 'column',
                      alignItems: 'center',
                      justifyContent: 'center',
                      gap: 'var(--space-2)',
                      padding: 'var(--space-12) 0',
                    }}
                  >
                    <Inbox size={32} color="var(--color-neutral-400)" />
                    <span style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-base)' }}>
                      {emptyMessage}
                    </span>
                  </div>
                </td>
              </tr>
            ) : (
              sortedRows.map((row) => {
                const rawRow = row.original
                return (
                  <tr
                    key={row.id}
                    data-testid="datatable-row"
                    onClick={onRowClick ? () => onRowClick(rawRow) : undefined}
                    style={{
                      cursor: onRowClick ? 'pointer' : 'default',
                      borderBottom: '1px solid var(--border-default)',
                    }}
                    onMouseEnter={(e) => {
                      if (onRowClick) {
                        e.currentTarget.style.background = 'var(--color-neutral-50)'
                      }
                    }}
                    onMouseLeave={(e) => {
                      if (onRowClick) {
                        e.currentTarget.style.background = 'transparent'
                      }
                    }}
                  >
                    {columns.map((col) => (
                      <td
                        key={col.id}
                        data-testid={`datatable-cell-${col.id}`}
                        style={{
                          padding: 'var(--space-2) var(--space-4)',
                          color: 'var(--text-primary)',
                          fontSize: 'var(--text-sm)',
                        }}
                      >
                        {col.accessor(rawRow)}
                      </td>
                    ))}
                  </tr>
                )
              })
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
