// @vitest-environment node
/**
 * Unit tests — ISS-0729 §5: highlightText.tsx correctness property
 *
 * IMPORTANT — read before extending this file: this is a general
 * correctness/robustness test, NOT a "was broken on main, now fixed"
 * regression test. lib/letflow/design/iss-0729-definitionlistpage-search-freeze-fix.md
 * §4 ran an exhaustive brute-force sweep (3,454,347 cases) against the PRIOR
 * implementation (shared global-flagged RegExp + `.test()` re-check per
 * `.split()` segment) and found ZERO mismatches — `String.prototype.split`'s
 * own spec behavior (fresh internal regex clone, `lastIndex` untouched) plus
 * its strict match/non-match alternation made the classic stateful-regex bug
 * unreachable at this specific call site. There is no failing-on-old-code
 * fixture to point at truthfully, so this suite does not attempt to construct
 * one. It instead pins down the *behavior* the fix is expected to preserve
 * (every occurrence highlighted, no characters dropped/duplicated) rather than
 * the mechanism (the index-parity check) — see this file's own tests below,
 * matching the design doc's explicit guidance not to test the mechanism
 * directly.
 */

import { describe, it, expect } from 'vitest'
import type { ReactElement } from 'react'
import { highlightText } from '@/utils/highlightText'

type Part = string | ReactElement

/** Extracts the plain-text content of a highlightText() result element. */
function partText(part: Part): string {
  if (typeof part === 'string') return part
  // <mark key={i}>{part}</mark> — children is a plain string.
  return String((part.props as { children: string }).children)
}

function isMark(part: Part): boolean {
  return typeof part !== 'string' && part.type === 'mark'
}

describe('ISS-0729 §5 — highlightText correctness property', () => {
  it('TC-HL-01: every occurrence of the query is wrapped in <mark>, count matches', () => {
    const text = 'cat catalog cat scatter cat'
    const query = 'cat'
    const result = highlightText(text, query)
    expect(Array.isArray(result)).toBe(true)
    const parts = result as Part[]

    const trueOccurrences = text.split(query).length - 1
    const markedParts = parts.filter(isMark)
    expect(markedParts).toHaveLength(trueOccurrences)
    for (const m of markedParts) {
      expect(partText(m).toLowerCase()).toBe(query.toLowerCase())
    }
  })

  it('TC-HL-02: adjacent/overlapping-looking matches ("aaaa" / "aa") — no characters dropped or duplicated', () => {
    const text = 'aaaa'
    const query = 'aa'
    const result = highlightText(text, query)
    const parts = (Array.isArray(result) ? result : [result]) as Part[]

    const reconstructed = parts.map(partText).join('')
    expect(reconstructed).toBe(text)
  })

  it('TC-HL-03: case-insensitive matching highlights every case variant', () => {
    const text = 'CaT cat CAT'
    const query = 'cat'
    const result = highlightText(text, query)
    const parts = (Array.isArray(result) ? result : [result]) as Part[]

    const markedParts = parts.filter(isMark)
    expect(markedParts).toHaveLength(3)
    expect(markedParts.map(partText)).toEqual(['CaT', 'cat', 'CAT'])

    // Reconstruction guards against a fix that drops or duplicates characters.
    expect(parts.map(partText).join('')).toBe(text)
  })

  it('TC-HL-04: no match in text — returns the original text unchanged', () => {
    const result = highlightText('hello world', 'zzz')
    expect(result).toBe('hello world')
  })

  it('TC-HL-05: empty/whitespace-only query — returns the original text unchanged', () => {
    expect(highlightText('hello world', '')).toBe('hello world')
    expect(highlightText('hello world', '   ')).toBe('hello world')
  })

  it('TC-HL-06: query containing regex metacharacters is treated as a literal substring', () => {
    const text = 'price: $5.00 (discounted)'
    const query = '$5.00'
    const result = highlightText(text, query)
    const parts = (Array.isArray(result) ? result : [result]) as Part[]

    const markedParts = parts.filter(isMark)
    expect(markedParts).toHaveLength(1)
    expect(partText(markedParts[0])).toBe('$5.00')
    expect(parts.map(partText).join('')).toBe(text)
  })
})
