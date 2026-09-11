// @vitest-environment jsdom
/**
 * REQ-293 AC5 — 3 separate assertions proving the unevaluable state's three
 * distinguishable outcomes: not-visible-by-default (visible_when), not-hidden-
 * by-default (also visible_when — the row still occupies its place), and
 * computed-not-blank (computed). Each fixture uses an expression this
 * evaluator cannot handle (`has(...)`, a CEL macro rejected at translation) so
 * the field is provably `unevaluable`, never silently defaulted.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
expect.extend(jestDomMatchers)

import { DynamicFormRenderer } from '../DynamicFormRenderer'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-293 AC5 — unevaluable expression state, three distinguishable outcomes', () => {
  it('visible_when unevaluable: the field is neither rendered as a normal visible input NOR omitted/hidden — a banner occupies its row', async () => {
    const schema = {
      type: 'object',
      properties: {
        note: {
          type: 'string',
          title: 'Note',
          'x-ui': { visible_when: 'has(x.y)' },
        },
      },
    }

    render(<DynamicFormRenderer formSchema={schema} onSubmit={vi.fn()} />)

    await waitFor(() => {
      // Outcome 1: not "visible" in the usable-input sense — no normal <input> rendered.
      expect(screen.queryByLabelText('Note')).not.toBeInTheDocument()
      // Outcome 2: not "hidden" either — the banner for this field's row IS present.
      expect(screen.getByTestId('expr-unavailable-note-visible_when')).toBeInTheDocument()
    })
  })

  it('computed unevaluable: the input is replaced by the banner, never left as an empty/blank input', async () => {
    const schema = {
      type: 'object',
      properties: {
        total: {
          type: 'number',
          title: 'Total',
          'x-ui': { computed: 'has(x.y)' },
        },
      },
    }

    render(<DynamicFormRenderer formSchema={schema} onSubmit={vi.fn()} />)

    await waitFor(() => {
      // Outcome 3: no ordinary (even empty) read-only input exists for this field —
      // the banner is a distinct node, not an empty-string input.
      expect(screen.queryByTestId('computed-field-total')).not.toBeInTheDocument()
      expect(screen.getByTestId('expr-unavailable-total-computed')).toBeInTheDocument()
    })
  })

  it('cross_field_validation unevaluable: a distinct "validation unavailable" banner, never silently treated as passing', async () => {
    const schema = {
      type: 'object',
      properties: {
        startDate: { type: 'number', title: 'Start' },
        endDate: {
          type: 'number',
          title: 'End',
          'x-ui': {
            cross_field_validation: { expression: 'has(x.y)', message: 'unreachable message' },
          },
        },
      },
    }

    render(<DynamicFormRenderer formSchema={schema} onSubmit={vi.fn()} />)

    await waitFor(() => {
      expect(screen.getByTestId('expr-unavailable-endDate-cross_field_validation')).toBeInTheDocument()
      // Never silently "no error" — the ordinary evaluated-error testid is absent
      // because the rule never reached a boolean result, not because it passed.
      expect(screen.queryByTestId('cross-field-error-endDate')).not.toBeInTheDocument()
    })
  })
})
