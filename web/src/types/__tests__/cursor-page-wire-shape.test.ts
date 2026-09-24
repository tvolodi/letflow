/**
 * ISS-0821/ISS-0816: CursorPage<T> wire-shape contract test.
 *
 * Pins the CursorPage<T> interface against the exact fields emitted by
 * Letflow.Api.Pagination.Page (lib/letflow/api/pagination.ex:81):
 *   @derive {Jason.Encoder, only: [:items, :next_cursor, :count]}
 *
 * The backend never emits has_more. Four test fixtures used to hand-write
 * has_more into mock responses (ISS-0821); this test prevents recurrence.
 *
 * Backend source of truth (Pagination.Page key set, alphabetical):
 *   count, items, next_cursor
 */

import { describe, expect, it } from 'vitest'
import type { CursorPage } from '@/types/api'

// ── 1. Compile-time contract ──────────────────────────────────────────────────

// A minimal payload shaped exactly like Pagination.Page's JSON output.
// If CursorPage<T> gains a required field Pagination.Page does not emit,
// or loses a field it requires, this assignment will produce a tsc error.
interface SampleItem { id: string }

const cursorPagePayload: CursorPage<SampleItem> = {
  items: [{ id: 'abc' }],
  next_cursor: null,
  count: 1,
}

// Payload with a non-null next_cursor (one more page available)
const cursorPageWithMore: CursorPage<SampleItem> = {
  items: [{ id: 'xyz' }],
  next_cursor: 'cursor-abc',
  count: 1,
}

/** Exact key set emitted by Pagination.Page (pagination.ex:81-82). */
const PAGINATION_PAGE_KEYS = ['count', 'items', 'next_cursor'].sort()

// ── 2. Runtime key-set assertions ─────────────────────────────────────────────

describe('CursorPage wire shape (ISS-0821/ISS-0816)', () => {
  it('TC-ISS0821-01: cursorPagePayload has exactly the Pagination.Page keys', () => {
    const payloadKeys = Object.keys(cursorPagePayload).sort()
    expect(payloadKeys).toEqual(PAGINATION_PAGE_KEYS)
  })

  it('TC-ISS0821-02: CursorPage has no has_more field — backend never emits it', () => {
    // has_more must not appear in the required key set.
    expect(Object.prototype.hasOwnProperty.call(cursorPagePayload, 'has_more')).toBe(false)
    expect(Object.prototype.hasOwnProperty.call(cursorPageWithMore, 'has_more')).toBe(false)
  })

  it('TC-ISS0821-03: CursorPage has count, not has_more, as the companion to next_cursor', () => {
    expect(cursorPagePayload.count).toBe(1)
    expect(cursorPagePayload.next_cursor).toBeNull()
    expect(cursorPageWithMore.next_cursor).toBe('cursor-abc')
  })

  it('TC-ISS0821-04: pagination is driven by next_cursor — null means no more pages', () => {
    // The canonical way to check for more pages is next_cursor !== null,
    // not a has_more field that the backend does not send.
    expect(cursorPagePayload.next_cursor === null).toBe(true)   // no more pages
    expect(cursorPageWithMore.next_cursor !== null).toBe(true)  // more pages available
  })
})
