/**
 * REQ-343 AC3 — "no screen, field, or client-side workaround for
 * category.parent_id, question.parent_id, or exam_assignment exists
 * anywhere in the diff -- a grep for parent_id and exam_assignment across
 * the new web/ files is quoted, and any hit is inside a comment/copy string
 * describing the gap, never a rendered form field or a mocked entity."
 *
 * This test IS that grep, run programmatically (mirroring
 * web/src/__tests__/entities-i18n-grep.test.ts's own approach to AC7) so it
 * runs the same way under `npm test` on any host rather than living only as
 * a close-out claim. It scans every new/modified file this requirement
 * touches and asserts that every line matching /parent_id|exam_assignment/i
 * is either:
 *   - a comment line (JS/TS `//` or JSDoc `*` line), or
 *   - a quoted copy string inside the message catalog
 *     (web/src/i18n/entitiesMessages.ts) describing the gap in prose,
 * and never:
 *   - a JSX-rendered form field / data-testid naming an actual UI element
 *     for one of these fields (other than the negative assertions the gap
 *     note itself needs, which live only in test files, not in these
 *     runtime files), or
 *   - an entry in BILIMBAGA_ENTITY_TYPES / a field list driving a rendered
 *     screen.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'

const SRC_ROOT = path.resolve(__dirname, '..')

const GAP_PATTERN = /parent_id|exam_assignment/i

// The runtime (non-test) files this requirement added or modified. Test
// files are deliberately excluded -- they are ALLOWED to reference these
// terms directly (asserting their absence), which is not the workaround
// this acceptance criterion prohibits.
const FILES_TO_CHECK = [
  'config/bilimbagaEntities.ts',
  'pages/entities/EntityCrudPage.tsx',
  'pages/admin/bilimbaga/BilimBagaAdminPage.tsx',
  'pages/admin/bilimbaga/BilimBagaEntityRoute.tsx',
  'i18n/entitiesMessages.ts',
  'router.tsx',
  'components/layout/AppShell.tsx',
]

function isCommentLine(line: string): boolean {
  const trimmed = line.trim()
  return trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*')
}

function isCatalogCopyLine(relativePath: string, line: string): boolean {
  // entitiesMessages.ts's hits are the exam_assignment gap note's own
  // translated copy strings (kk/ru/en) -- these are the catalog side of the
  // gap note, not a workaround. Every such line is a quoted string literal.
  if (relativePath !== 'i18n/entitiesMessages.ts') return false
  return /['"`].*['"`],?\s*$/.test(line.trim())
}

describe('REQ-343 AC3 — grep for parent_id/exam_assignment across the new web/ files', () => {
  for (const relativePath of FILES_TO_CHECK) {
    it(`${relativePath}: every parent_id/exam_assignment hit is a comment or catalog copy string, never rendered UI`, () => {
      const contents = readFileSync(path.join(SRC_ROOT, relativePath), 'utf-8')
      const lines = contents.split('\n')
      const offendingLines = lines.filter(
        (line) => GAP_PATTERN.test(line) && !isCommentLine(line) && !isCatalogCopyLine(relativePath, line),
      )
      expect(offendingLines).toEqual([])
    })
  }

  it('BILIMBAGA_ENTITY_TYPES (the nav/route source of truth) never names an exam_assignment entity', async () => {
    const { BILIMBAGA_ENTITY_TYPES } = await import('@/config/bilimbagaEntities')
    expect(BILIMBAGA_ENTITY_TYPES.map((e) => e.entityType)).not.toContain('exam_assignment')
    expect(BILIMBAGA_ENTITY_TYPES).toHaveLength(9)
  })
})
