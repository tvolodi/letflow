import type { ReactNode } from 'react'

/**
 * Wraps matching substrings of `query` in `<mark>` tags with yellow background.
 * Case-insensitive matching. Returns a ReactNode array with plain text and <mark> elements.
 *
 * ISS-0729 (lib/letflow/design/iss-0729-definitionlistpage-search-freeze-fix.md
 * §4): the prior implementation re-checked each `.split()` segment against a
 * shared, global-flagged (`g`) `RegExp` via `.test()`. That specific reuse
 * pattern is a well-known stateful-`lastIndex` hazard when independent
 * candidates are tested one by one against the same global regex — but this
 * call site never actually hit it, because `String.prototype.split`'s own
 * spec-defined behavior (a fresh internal regex clone, `lastIndex` untouched)
 * combined with `.split()`'s strict `[non-match, match, non-match, ...]`
 * segment alternation made the bug unreachable here (verified by exhaustive
 * brute-force sweep, 3,454,347 cases, zero mismatches — see the design doc).
 * Fixed anyway per that doc's §4 reasoning: it is still a shared-mutable-state
 * anti-pattern that only happened to be safe due to an invisible implementation
 * detail, and it redundantly re-derives information `.split()` already gave
 * for free. Dropped the `g` flag (not needed by `.split()`) and replaced the
 * `.test()` re-check with the index-parity fact `.split()` with a single
 * capturing group guarantees: odd indices are always the matched substrings,
 * even indices are always the non-matched segments.
 */
export function highlightText(text: string, query: string): ReactNode {
  if (!query.trim()) return text

  const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const regex = new RegExp(`(${escaped})`, 'i')
  const parts = text.split(regex)

  if (parts.length === 1) return text

  return parts.map((part, i) =>
    i % 2 === 1
      ? <mark key={i} style={{ background: 'var(--color-warning-banner)', borderRadius: 2, padding: '0 1px' }}>{part}</mark>
      : part,
  )
}
