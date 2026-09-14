// @vitest-environment jsdom
/**
 * REQ-343 AC4 — the exam-admin landing page carries a visible, one-line
 * note about the exam_assignment gap, pointing at
 * lib/letflow/exam/session.ex's FINDING section and REQ-327's
 * README-constraints.md by path. Also covers: all ten entity types are
 * reachable from the landing page's own nav cards, and no exam_assignment
 * or parent_id workaround renders anywhere on this page.
 *
 * ISS-0655: `tag` was missing from BILIMBAGA_ENTITY_TYPES (nine, not ten)
 * -- this suite's card-count assertion below is the "all wired types show
 * a card" half of that regression's coverage; the config-vs-pack-directory
 * half lives in web/src/config/__tests__/bilimbagaEntities.test.ts.
 */
import { describe, it, expect, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
expect.extend(jestDomMatchers)

import BilimBagaAdminPage from '@/pages/admin/bilimbaga/BilimBagaAdminPage'
import { BILIMBAGA_ENTITY_TYPES } from '@/config/bilimbagaEntities'

afterEach(() => cleanup())

describe('REQ-343 AC4 — exam_assignment gap note', () => {
  it('renders a visible note citing lib/letflow/exam/session.ex and REQ-327/README-constraints.md by path', () => {
    render(
      <MemoryRouter>
        <BilimBagaAdminPage />
      </MemoryRouter>,
    )

    const note = screen.getByTestId('bilimbaga-exam-assignment-gap-note')
    expect(note).toBeInTheDocument()
    expect(note.textContent).toContain('lib/letflow/exam/session.ex')
    expect(note.textContent).toContain('priv/packs/bilimbaga/entity_definitions/README-constraints.md')
  })
})

describe('REQ-343 AC1/AC5 — all ten entity types reachable from this landing page', () => {
  it('renders one nav card per admin-manageable BilimBaga entity type, including tag', () => {
    render(
      <MemoryRouter>
        <BilimBagaAdminPage />
      </MemoryRouter>,
    )

    for (const { entityType } of BILIMBAGA_ENTITY_TYPES) {
      const link = screen.getByTestId(`bilimbaga-nav-${entityType}`)
      expect(link).toBeInTheDocument()
      expect(link.getAttribute('href')).toBe(`/admin/bilimbaga/${entityType}`)
    }
    expect(BILIMBAGA_ENTITY_TYPES).toHaveLength(10)
    expect(screen.getByTestId('bilimbaga-nav-tag')).toBeInTheDocument()
  })
})

describe('REQ-343 AC3 — no exam_assignment or parent_id workaround on this page', () => {
  it('never renders a parent_id field or a fabricated exam_assignment list', () => {
    render(
      <MemoryRouter>
        <BilimBagaAdminPage />
      </MemoryRouter>,
    )

    expect(screen.queryByTestId(/parent_id/)).toBeNull()
    expect(screen.queryByTestId('bilimbaga-nav-exam_assignment')).toBeNull()
  })
})
