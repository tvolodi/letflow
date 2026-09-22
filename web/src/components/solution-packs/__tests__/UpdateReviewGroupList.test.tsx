// @vitest-environment jsdom
/**
 * Component-level tests — REQ-381 §4.3.
 *
 * TEST-DESIGNER audit note: FRONTEND-DEV's own coverage for this requirement
 * was lib-level (canonicalizeArtefactContent) plus an e2e spec that has never
 * been run against a live instance. There was no component-level test for
 * UpdateReviewGroupList's four-group split / conflict sub-partition / EO-005
 * "already resolved, not re-flagged" display logic — the exact rendering
 * rules design §4.3.1/§4.3.2/§4.3.4 spell out. This file closes that gap,
 * matching the existing `<component>/__tests__/<Name>.test.tsx` +
 * `@vitest-environment jsdom` + Testing Library convention established by
 * `web/src/components/promotions/__tests__/NonSkippableApprovalGate.rehearsal-gate.test.tsx`.
 */

import type { ComponentProps } from 'react'
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, within } from '@testing-library/react'
import { fireEvent } from '@testing-library/react'
import { UpdateReviewGroupList, artefactKey } from '../UpdateReviewGroupList'
import type {
  PackResolutionChoice,
  PackUpdateAppliedEntry,
  PackUpdateReviewEntry,
} from '@/api/solutionPacks'

expect.extend(jestDomMatchers)

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function entry(
  overrides: Partial<PackUpdateReviewEntry> & Pick<PackUpdateReviewEntry, 'artefact_id' | 'classification'>,
): PackUpdateReviewEntry {
  return {
    artefact_type: 'process_definition',
    resolved: false,
    ...overrides,
  }
}

const FOUR_GROUP_ENTRIES: PackUpdateReviewEntry[] = [
  entry({ artefact_id: 'unchanged-proc', classification: 'unchanged', resolved: true }),
  entry({ artefact_id: 'untouched-proc', classification: 'safe_to_update', resolved: false }),
  entry({ artefact_id: 'local-only-proc', classification: 'local_only', resolved: false }),
  entry({ artefact_id: 'adapted-proc', classification: 'both_sides_conflict', resolved: false }),
]

function renderList(props: Partial<ComponentProps<typeof UpdateReviewGroupList>> = {}) {
  const defaultProps: ComponentProps<typeof UpdateReviewGroupList> = {
    entries: FOUR_GROUP_ENTRIES,
    resolutionChoices: new Map<string, PackResolutionChoice>(),
    onChooseResolution: vi.fn(),
    attribution: new Map(),
    appliedEntries: null,
  }
  return render(<UpdateReviewGroupList {...defaultProps} {...props} />)
}

// ── EO-001: four-group display ──────────────────────────────────────────────

describe('UpdateReviewGroupList — EO-001 four-group display', () => {
  it('TC-1: places each supplied artefact under exactly its own classification group', () => {
    renderList()

    expect(
      within(screen.getByTestId('update-review-group-unchanged')).getByText('unchanged-proc'),
    ).toBeInTheDocument()
    expect(
      within(screen.getByTestId('update-review-group-safe_to_update')).getByText('untouched-proc'),
    ).toBeInTheDocument()
    expect(
      within(screen.getByTestId('update-review-group-local_only')).getByText('local-only-proc'),
    ).toBeInTheDocument()
    // adapted-proc is unresolved both_sides_conflict -- rendered inside the
    // conflict group's "needs a decision" sub-partition, not as a plain row.
    expect(
      within(screen.getByTestId('update-review-conflict-needs-decision')).getByText('adapted-proc'),
    ).toBeInTheDocument()
  })

  it('TC-2: group headings show the correct per-group count', () => {
    renderList()

    expect(screen.getByTestId('update-review-group-unchanged')).toHaveTextContent('Unchanged (1)')
    expect(screen.getByTestId('update-review-group-safe_to_update')).toHaveTextContent(
      'Safe to update (1)',
    )
    expect(screen.getByTestId('update-review-group-local_only')).toHaveTextContent(
      "Your own change (1)",
    )
    expect(screen.getByTestId('update-review-group-both_sides_conflict')).toHaveTextContent(
      'Changed on both sides (1)',
    )
  })

  it('TC-3: an artefact never appears in more than one of the four groups', () => {
    renderList()

    // adapted-proc belongs only to both_sides_conflict.
    expect(
      within(screen.getByTestId('update-review-group-unchanged')).queryByText('adapted-proc'),
    ).not.toBeInTheDocument()
    expect(
      within(screen.getByTestId('update-review-group-safe_to_update')).queryByText('adapted-proc'),
    ).not.toBeInTheDocument()
    expect(
      within(screen.getByTestId('update-review-group-local_only')).queryByText('adapted-proc'),
    ).not.toBeInTheDocument()
  })

  it('TC-4: an empty entries list renders all four groups with a zero count, not a crash', () => {
    renderList({ entries: [] })

    expect(screen.getByTestId('update-review-group-unchanged')).toHaveTextContent('Unchanged (0)')
    expect(screen.getByTestId('update-review-group-both_sides_conflict')).toHaveTextContent(
      'Changed on both sides (0)',
    )
  })
})

// ── EO-002/EO-005: both_sides_conflict resolved/unresolved sub-partition ──────

describe('UpdateReviewGroupList — EO-002/EO-005 conflict sub-partition', () => {
  it('TC-5: an unresolved conflict entry renders a resolution control under "Needs a decision"', () => {
    renderList()

    const needsDecision = screen.getByTestId('update-review-conflict-needs-decision')
    expect(within(needsDecision).getByTestId('update-review-resolution-control')).toBeInTheDocument()
    expect(screen.queryByTestId('update-review-resolved-entry')).not.toBeInTheDocument()
  })

  it('TC-6 (EO-005): an already-resolved conflict entry renders under "Already resolved", NOT re-presented as needing a decision', () => {
    const entries = [
      entry({ artefact_id: 'adapted-proc', classification: 'both_sides_conflict', resolved: true }),
    ]
    renderList({ entries })

    expect(screen.getByTestId('update-review-resolved-entry')).toHaveAttribute(
      'data-artefact-id',
      'adapted-proc',
    )
    expect(
      within(screen.getByTestId('update-review-conflict-needs-decision')).queryByTestId(
        'update-review-resolution-control',
      ),
    ).not.toBeInTheDocument()
  })

  it('TC-7: choosing "Keep ours" on an unresolved conflict fires onChooseResolution with keep_local', () => {
    const onChooseResolution = vi.fn()
    const entries = [
      entry({ artefact_id: 'adapted-proc', classification: 'both_sides_conflict', resolved: false }),
    ]
    renderList({ entries, onChooseResolution })

    fireEvent.click(screen.getByTestId('update-review-resolution-keep-local'))

    expect(onChooseResolution).toHaveBeenCalledWith('process_definition', 'adapted-proc', 'keep_local')
  })

  it('TC-8: choosing "Take theirs" fires onChooseResolution with take_incoming', () => {
    const onChooseResolution = vi.fn()
    const entries = [
      entry({ artefact_id: 'adapted-proc', classification: 'both_sides_conflict', resolved: false }),
    ]
    renderList({ entries, onChooseResolution })

    fireEvent.click(screen.getByTestId('update-review-resolution-take-incoming'))

    expect(onChooseResolution).toHaveBeenCalledWith(
      'process_definition',
      'adapted-proc',
      'take_incoming',
    )
  })

  it('TC-9 (EO-003 attribution): a resolved entry with session-local attribution present shows who/when, not the fallback', () => {
    const entries = [
      entry({ artefact_id: 'adapted-proc', classification: 'both_sides_conflict', resolved: true }),
    ]
    const attribution = new Map([
      [artefactKey('process_definition', 'adapted-proc'), { resolvedBy: 'alice', resolvedAt: '2026-09-22T10:00:00Z' }],
    ])
    renderList({ entries, attribution })

    expect(screen.getByTestId('update-review-resolved-attribution')).toHaveTextContent('alice')
    expect(screen.queryByTestId('update-review-resolved-attribution-unavailable')).not.toBeInTheDocument()
  })

  it('TC-10 (OQ-1 disclosed fallback): a resolved entry with NO session-local attribution (e.g. a prior session) shows the disclosed fallback text, not a fabricated who/when', () => {
    const entries = [
      entry({ artefact_id: 'adapted-proc', classification: 'both_sides_conflict', resolved: true }),
    ]
    renderList({ entries, attribution: new Map() })

    expect(screen.getByTestId('update-review-resolved-attribution-unavailable')).toBeInTheDocument()
    expect(screen.queryByTestId('update-review-resolved-attribution')).not.toBeInTheDocument()
  })
})

// ── EO-004: local_only/unchanged groups render read-only, no control ────────

describe('UpdateReviewGroupList — EO-004 untouched groups are read-only', () => {
  it('TC-11: unchanged/local_only/safe_to_update entries never render a resolution control', () => {
    const entries = [
      entry({ artefact_id: 'unchanged-proc', classification: 'unchanged', resolved: true }),
      entry({ artefact_id: 'untouched-proc', classification: 'safe_to_update', resolved: false }),
      entry({ artefact_id: 'local-only-proc', classification: 'local_only', resolved: false }),
    ]
    renderList({ entries })

    expect(screen.queryAllByTestId('update-review-resolution-control')).toHaveLength(0)
  })
})

// ── §4.3.4 UpdateAttributionPanel (EO-003) ──────────────────────────────────

describe('UpdateReviewGroupList — UpdateAttributionPanel (post-apply)', () => {
  it('TC-12: renders nothing when appliedEntries is null (apply has not happened yet)', () => {
    renderList({ appliedEntries: null })

    expect(screen.queryByTestId('update-attribution-panel')).not.toBeInTheDocument()
  })

  it('TC-13: after apply, shows one attribution row per kept-local both_sides_conflict entry', () => {
    const appliedEntries: PackUpdateAppliedEntry[] = [
      {
        artefact_type: 'process_definition',
        artefact_id: 'adapted-proc',
        classification: 'both_sides_conflict',
        action: 'left_unchanged',
      },
      {
        artefact_type: 'process_definition',
        artefact_id: 'untouched-proc',
        classification: 'safe_to_update',
        action: 'advanced_to_incoming',
      },
    ]
    const attribution = new Map([
      [artefactKey('process_definition', 'adapted-proc'), { resolvedBy: 'alice', resolvedAt: '2026-09-22T10:00:00Z' }],
    ])
    renderList({ appliedEntries, attribution })

    const panel = screen.getByTestId('update-attribution-panel')
    // Only the kept-local both_sides_conflict entry gets an attribution row --
    // the advanced_to_incoming entry (untouched-proc) is not a "kept as-is"
    // decision and must not appear here.
    expect(within(panel).getAllByTestId('update-attribution-entry')).toHaveLength(1)
    expect(within(panel).getByTestId('update-attribution-entry')).toHaveTextContent('adapted-proc')
    expect(within(panel).getByTestId('update-attribution-entry')).toHaveTextContent('alice')
  })
})
