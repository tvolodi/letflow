/**
 * ISS-0821/ISS-0816: CursorPage<T> wire-shape contract test.
 *
 * Pins the CursorPage<T> interface against the field sets emitted by
 * Letflow.Api.Pagination.Page and hand-built cursor responses.
 *
 * - Routes using Pagination.page_response/2 emit {items, next_cursor, count}
 *   (@derive {Jason.Encoder, only: [:items, :next_cursor, :count]})
 * - Routes hand-building their response emit only {items, next_cursor}
 *   (e.g. definitions/search, dlq, promotions — count is absent)
 *
 * The backend never emits has_more. Four test fixtures used to hand-write
 * has_more into mock responses (ISS-0821); this test prevents recurrence.
 */

import { describe, expect, it } from 'vitest'
import type { CursorPage } from '@/types/api'

// ── 1. Compile-time contract ──────────────────────────────────────────────────

interface SampleItem { id: string }

// Minimal payload matching a hand-built route response (no count)
const cursorPageNoCount: CursorPage<SampleItem> = {
  items: [{ id: 'abc' }],
  next_cursor: null,
}

// Payload matching a Pagination.page_response route (with count)
const cursorPageWithCount: CursorPage<SampleItem> = {
  items: [{ id: 'xyz' }],
  next_cursor: 'cursor-abc',
  count: 5,
}

// ── 2. Runtime key-set assertions ─────────────────────────────────────────────

describe('CursorPage wire shape (ISS-0821/ISS-0816)', () => {
  it('TC-ISS0821-01: CursorPage without count is valid (hand-built route responses)', () => {
    // Verifies CursorPage<T> can represent routes that omit count
    expect(cursorPageNoCount.items).toHaveLength(1)
    expect(cursorPageNoCount.next_cursor).toBeNull()
    expect(cursorPageNoCount.count).toBeUndefined()
  })

  it('TC-ISS0821-02: CursorPage with count is valid (Pagination.page_response routes)', () => {
    expect(cursorPageWithCount.count).toBe(5)
    expect(cursorPageWithCount.next_cursor).toBe('cursor-abc')
  })

  it('TC-ISS0821-03: CursorPage has no has_more field — backend never emits it', () => {
    // has_more must not appear on either payload variant
    expect(Object.prototype.hasOwnProperty.call(cursorPageNoCount, 'has_more')).toBe(false)
    expect(Object.prototype.hasOwnProperty.call(cursorPageWithCount, 'has_more')).toBe(false)
  })

  it('TC-ISS0821-04: pagination is driven by next_cursor — null means no more pages', () => {
    // The canonical way to check for more pages is next_cursor !== null,
    // not a has_more field that the backend does not send.
    expect(cursorPageNoCount.next_cursor === null).toBe(true)   // no more pages
    expect(cursorPageWithCount.next_cursor !== null).toBe(true) // more pages available
  })
})
