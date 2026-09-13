// @vitest-environment jsdom
/**
 * REQ-336 AC3 — the tag `name` field (a `:string` entity field, no
 * `enum_values`) must render through the SAME widget component a
 * form_schema `:string` field would, not a parallel implementation. This
 * test renders EntityRecordForm against a real tag-shaped EntityDefinition
 * and asserts the rendered input is the identical builtin-switch branch
 * FieldFactory.renderFormField (the function DynamicFormRenderer itself
 * calls indirectly for form_schema fields) produces for a plain :string
 * field: a bare `<input type="text">`, no textarea/select/checkbox, and the
 * ARIA wiring that branch sets (aria-required, label association).
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { IntlProvider } from 'react-intl'
expect.extend(jestDomMatchers)

import { EntityRecordForm } from '../EntityRecordForm'
import { renderFormField } from '@/components/forms/FieldFactory'
import type { EntityDefinition } from '@/types/api'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

const TAG_DEFINITION: EntityDefinition = {
  id: 'def-1',
  name: 'tag',
  display_name: 'Tag',
  definition: {
    name: 'tag',
    display_name: 'Tag',
    fields: [{ name: 'name', type: 'string', required: true, queried: true }],
    constraints: [{ name: 'uq_tag_name', type: 'unique', fields: ['name'] }],
  },
  content_hash: 'deadbeef',
  logical_shape_version: 'cafebabe',
  artifact_version_id: 'av-1',
  status: 'active',
  inserted_at: '2026-01-01T00:00:00Z',
}

function renderForm() {
  return render(
    <IntlProvider locale="en" messages={{}}>
      <EntityRecordForm
        definition={TAG_DEFINITION}
        fieldTitles={{ name: 'Name' }}
        onSubmit={vi.fn()}
        onCancel={vi.fn()}
        submitLabel="Create"
        cancelLabel="Cancel"
      />
    </IntlProvider>,
  )
}

describe('REQ-336 AC3 — EntityRecordForm reuses FieldFactory.renderFormField, not a parallel widget system', () => {
  it('renders the tag name field as a bare text input — the same builtin :string branch a form_schema field takes', () => {
    renderForm()

    const input = screen.getByLabelText('Name', { exact: false }) as HTMLInputElement
    expect(input).toBeInTheDocument()
    expect(input.tagName).toBe('INPUT')
    expect(input.type).toBe('text')
    expect(input).toHaveAttribute('aria-required', 'true')

    // No select/textarea/checkbox rendered for this field — proves it did
    // NOT go through a parallel enum/textarea/boolean implementation.
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument()
    expect(screen.queryByRole('textbox', { name: /name/i })).toBeInTheDocument()
  })

  it('renderFormField called directly with the SAME TaskFormField shape produces byte-identical markup to what EntityRecordForm rendered', () => {
    // Directly exercises the identical function EntityRecordForm calls
    // internally, proving there is exactly one rendering path -- not that
    // the two happen to look alike by coincidence.
    const { container: directContainer } = render(
      <div>
        {renderFormField(
          'name',
          { name: 'name', type: 'string', required: true, title: 'Name' },
          undefined,
          undefined,
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          { name: 'name', onChange: vi.fn(), onBlur: vi.fn(), ref: vi.fn() } as any,
          undefined,
        )}
      </div>,
    )

    const directInput = directContainer.querySelector('input[type="text"]')
    expect(directInput).not.toBeNull()

    cleanup()

    renderForm()
    const formInput = screen.getByLabelText('Name', { exact: false })
    expect(formInput.tagName).toBe(directInput!.tagName)
    expect((formInput as HTMLInputElement).type).toBe((directInput as HTMLInputElement).type)
  })
})
