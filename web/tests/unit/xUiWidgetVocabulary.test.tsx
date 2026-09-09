// @vitest-environment jsdom
/**
 * Unit tests — REQ-284: closed x-ui.widget vocabulary + fieldRegistry
 * population.
 *
 *   AC2: fieldRegistry's key set equals the documented vocabulary's name
 *        set, both directions.
 *   AC3: each registered widget renders its output AND its
 *        requiredAriaAttributes are actually applied.
 *   AC4: an unknown x-ui.widget name falls through to the built-in
 *        renderer for the field's JSON Schema type.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, fireEvent } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)

import { renderFormField } from '@/components/forms/FieldFactory'
import { fieldRegistry } from '@/components/forms/fieldRegistry'
import { registerBuiltinWidgets } from '@/components/forms/widgets'
import { X_UI_WIDGET_NAMES } from '@/components/forms/widgets/vocabulary'

// Vocabulary document's own documented name set (docs/frontend/x-ui-widget-vocabulary.md
// §1) — hand-copied here deliberately, per the design's "manual-sync
// comment" allowance (REQ-284 design §2), so a drift between the doc and
// X_UI_WIDGET_NAMES shows up as a failing assertion rather than trusting a
// single source to check itself.
const DOCUMENTED_WIDGET_NAMES = [
  'rich-text-lite',
  'masked-input',
  'searchable-select',
  'rating',
  'slider',
]

function fakeRegister(fieldName: string) {
  return {
    name: fieldName,
    onChange: vi.fn(() => undefined),
    onBlur: vi.fn(() => undefined),
    ref: () => undefined,
  }
}

function renderField(fieldName: string, fieldDef: Record<string, unknown>): void {
  render(
    <>
      {renderFormField(
        fieldName,
        fieldDef as never,
        undefined,
        undefined,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        fakeRegister(fieldName) as any,
      )}
    </>,
  )
}

describe('REQ-284 — AC2: registry/vocabulary equality', () => {
  beforeEach(() => {
    fieldRegistry.clear()
    registerBuiltinWidgets()
  })
  afterEach(() => {
    fieldRegistry.clear()
  })

  it('X_UI_WIDGET_NAMES matches the vocabulary document exactly', () => {
    expect([...X_UI_WIDGET_NAMES].sort()).toEqual([...DOCUMENTED_WIDGET_NAMES].sort())
  })

  it('fieldRegistry keys equal X_UI_WIDGET_NAMES after registration — no undocumented widget, no unimplemented one', () => {
    const registryKeys = Array.from(fieldRegistry.keys()).sort()
    expect(registryKeys).toEqual([...X_UI_WIDGET_NAMES].sort())
    expect(registryKeys).toEqual([...DOCUMENTED_WIDGET_NAMES].sort())
  })
})

describe('REQ-284 — AC3: per-widget rendering + ARIA contract', () => {
  beforeEach(() => {
    fieldRegistry.clear()
    registerBuiltinWidgets()
  })
  afterEach(() => {
    cleanup()
    fieldRegistry.clear()
    vi.restoreAllMocks()
  })

  it('rich-text-lite: renders a textarea with toolbar buttons and the full aria set', () => {
    renderField('bio', {
      type: 'string',
      xUiWidget: 'rich-text-lite',
      title: 'Bio',
      required: true,
      description: 'Tell us about yourself',
    })
    const textarea = screen.getByLabelText(/Bio/) as HTMLTextAreaElement
    expect(textarea.tagName).toBe('TEXTAREA')
    expect(textarea).toHaveAttribute('aria-required', 'true')
    expect(textarea).toHaveAttribute('aria-describedby', 'bio-hint')

    const bold = screen.getByRole('button', { name: 'Bold' })
    const italic = screen.getByRole('button', { name: 'Italic' })
    const bullet = screen.getByRole('button', { name: 'Bullet list' })
    expect(bold).toHaveAttribute('aria-pressed', 'false')
    expect(italic).toHaveAttribute('aria-pressed', 'false')
    expect(bullet).toHaveAttribute('aria-pressed', 'false')
  })

  it('masked-input: renders a text input with mask inputMode and a mask-format hint', () => {
    renderField('phone', {
      type: 'string',
      xUiWidget: 'masked-input',
      xUiMask: 'phone-us',
      title: 'Phone',
      required: true,
    })
    const input = screen.getByLabelText(/Phone/) as HTMLInputElement
    expect(input).toHaveAttribute('aria-required', 'true')
    expect(input).toHaveAttribute('inputMode', 'tel')
    expect(input.getAttribute('aria-describedby')).toContain('phone-mask-hint')
    expect(screen.getByText(/Format: \(555\) 555-5555/)).toBeInTheDocument()

    fireEvent.change(input, { target: { value: '5551234567' } })
    expect(input.value).toBe('(555) 123-4567')
  })

  it('searchable-select: renders a combobox filtering the field enum client-side', () => {
    renderField('country', {
      type: 'string',
      xUiWidget: 'searchable-select',
      title: 'Country',
      required: true,
      enum: ['Canada', 'France', 'Germany'],
    })
    const input = screen.getByLabelText(/Country/) as HTMLInputElement
    expect(input).toHaveAttribute('role', 'combobox')
    expect(input).toHaveAttribute('aria-expanded', 'false')
    expect(input).toHaveAttribute('aria-required', 'true')

    fireEvent.change(input, { target: { value: 'fr' } })
    expect(input).toHaveAttribute('aria-expanded', 'true')
    const options = screen.getAllByRole('option')
    expect(options).toHaveLength(1)
    expect(options[0]).toHaveTextContent('France')
    expect(options[0]).toHaveAttribute('role', 'option')

    const listbox = screen.getByRole('listbox')
    expect(input).toHaveAttribute('aria-controls', listbox.id)
  })

  it('rating: renders a radiogroup of bounded segments', () => {
    renderField('satisfaction', {
      type: 'number',
      xUiWidget: 'rating',
      title: 'Satisfaction',
      required: true,
      minimum: 1,
      maximum: 5,
    })
    const group = screen.getByRole('radiogroup')
    expect(group).toHaveAttribute('aria-required', 'true')
    const radios = screen.getAllByRole('radio')
    expect(radios).toHaveLength(5)
    expect(radios[2]).toHaveAttribute('aria-label', '3 out of 5')
    expect(radios[2]).toHaveAttribute('aria-checked', 'false')

    fireEvent.click(radios[2])
    expect(radios[2]).toHaveAttribute('aria-checked', 'true')
  })

  it('slider: renders a native range input with min/max/value set from the field', () => {
    renderField('confidence', {
      type: 'number',
      xUiWidget: 'slider',
      title: 'Confidence',
      required: true,
      minimum: 0,
      maximum: 100,
    })
    const input = screen.getByLabelText(/Confidence/) as HTMLInputElement
    expect(input).toHaveAttribute('type', 'range')
    expect(input).toHaveAttribute('min', '0')
    expect(input).toHaveAttribute('max', '100')
    expect(input).toHaveAttribute('aria-required', 'true')
  })
})

describe('REQ-284 — AC4: unknown x-ui.widget degrades to the built-in renderer for the field type', () => {
  beforeEach(() => {
    fieldRegistry.clear()
    registerBuiltinWidgets()
  })
  afterEach(() => {
    cleanup()
    fieldRegistry.clear()
  })

  it('string field with an unrecognised xUiWidget still renders the built-in text input', () => {
    renderField('nickname', {
      type: 'string',
      xUiWidget: 'not-a-real-widget',
      title: 'Nickname',
      required: true,
    })
    const input = screen.getByLabelText(/Nickname/) as HTMLInputElement
    expect(input.tagName).toBe('INPUT')
    expect(input).toHaveAttribute('type', 'text')
    expect(input).toHaveAttribute('aria-required', 'true')
  })

  it('number field with an unrecognised xUiWidget still renders the built-in number input, not an error', () => {
    renderField('age', {
      type: 'number',
      xUiWidget: 'not-a-real-widget',
      title: 'Age',
    })
    const input = screen.getByLabelText(/Age/) as HTMLInputElement
    expect(input).toHaveAttribute('type', 'number')
  })

  it('a field with no xUiWidget at all renders per the default builtin mapping', () => {
    renderField('untouched', { type: 'boolean', title: 'Untouched' })
    const input = screen.getByLabelText(/Untouched/) as HTMLInputElement
    expect(input).toHaveAttribute('type', 'checkbox')
  })
})
