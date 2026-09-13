/**
 * REQ-336 AC7 — every string rendered by a component this requirement adds
 * is sourced from a react-intl message catalog covering kk, ru and en. This
 * test IS the grep the acceptance criterion names, run programmatically (not
 * shelled out, so it runs the same way under `npm test` on any host) against
 * every non-catalog file this requirement added or touched:
 *
 *   grep -nE ">[A-Za-z][A-Za-z '.-]{2,}<" \
 *     web/src/components/entities/EntityRecordForm.tsx \
 *     web/src/pages/entities/TagListPage.tsx \
 *     web/src/i18n/EntitiesIntlProvider.tsx
 *
 * (message-catalog files -- web/src/i18n/entitiesMessages.ts -- are
 * deliberately excluded: THEY are the source of the strings, not a hit.)
 *
 * It also asserts entitiesMessages itself carries all three locales for
 * every id, so the catalog side of the AC is checked, not only the "no
 * inline literal" side.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { ENTITIES_UI_LOCALES, entitiesMessages } from '@/i18n/entitiesMessages'

const SRC_ROOT = path.resolve(__dirname, '..')

// Files this requirement added that render JSX text content. Deliberately
// NOT web/src/i18n/entitiesMessages.ts (the catalog itself) or
// web/src/api/entities.ts / web/src/utils/entityFieldToFormField.ts /
// web/src/types/api.ts (no JSX in any of them).
const JSX_FILES_TO_CHECK = [
  'components/entities/EntityRecordForm.tsx',
  'pages/entities/TagListPage.tsx',
  'i18n/EntitiesIntlProvider.tsx',
]

// Matches a JSX text node: `>` then a capitalised/alphabetic run of 3+ chars
// then `<` -- i.e. literal text sitting directly between two tags. Deliberately
// does NOT match `>{...}<` (a JS expression child), which is how every real
// string in these files is actually rendered (intl.formatMessage/props).
const JSX_TEXT_NODE = />[A-Za-z][A-Za-z '.-]{2,}</g

describe('REQ-336 AC7 — no hard-coded English string literal in JSX text content', () => {
  for (const relativePath of JSX_FILES_TO_CHECK) {
    it(`${relativePath} has no bare JSX text node`, () => {
      const contents = readFileSync(path.join(SRC_ROOT, relativePath), 'utf-8')
      const hits = contents.match(JSX_TEXT_NODE) ?? []
      expect(hits).toEqual([])
    })
  }

  it('entitiesMessages.ts covers kk, ru and en for every message id, with no id missing a locale', () => {
    const idSets = ENTITIES_UI_LOCALES.map((locale) => new Set(Object.keys(entitiesMessages[locale])))
    const [first, ...rest] = idSets
    for (const other of rest) {
      expect([...other].sort()).toEqual([...first].sort())
    }
    // Sanity: the catalog is non-empty (a vacuously-true comparison above
    // would also pass on three empty catalogs).
    expect(first.size).toBeGreaterThan(0)
  })
})
