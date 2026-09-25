// @vitest-environment jsdom
/**
 * REQ-340 -- enum-select widget, proven as a REUSE of the registry function
 * form_schema rendering already uses, not a new widget.
 *
 * CHECK FOR EXISTING COVERAGE (per REQ-340's own instruction, run before any
 * code was written for this requirement):
 *
 *   grep -rl "enum\|:enum" web/src/components/forms
 *   -> web/src/components/forms/DynamicFormRenderer.tsx
 *      web/src/components/forms/FieldFactory.tsx
 *      web/src/components/forms/widgets/maskedInput.tsx
 *      web/src/components/forms/widgets/searchableSelect.tsx
 *
 * `fieldRegistry.ts` itself (the x-ui.widget Map REQ-284/CMP-UI-05 added) has
 * NO enum entry and stays untouched -- the enum widget already lives in
 * `FieldFactory.renderFormField`'s builtin switch, in the
 * `fieldType === 'select' && fieldDef.enum` branch (FieldFactory.tsx:236-253),
 * which reads its option list from `fieldDef.enum` with no hard-coded values.
 * `entityFieldToFormField.ts` (REQ-336) already bridges an entity field's
 * `type: "enum"` to `TaskFormField.type: 'select'` with
 * `enum: field.enum_values` copied verbatim from the definition response --
 * so `EntityRecordForm` already renders an entity `:enum` field through the
 * EXACT SAME registry function and switch branch a form_schema `:enum` field
 * would. This is therefore a reuse-and-verify job (per REQ-340's own
 * decision rule), not a new-widget job: no new file was added under
 * `web/src/components/forms/fieldRegistry.ts` or `widgets/`, and this test
 * file is the proof that the existing reuse already produces a correct
 * enum select from real BilimBaga entity field shapes.
 *
 * The three field shapes below are taken verbatim from the actual committed
 * definition documents (not invented):
 *   - priv/modules/exam/entity_definitions/question.json:
 *       difficulty: enum_values ["easy","medium","hard"]
 *   - priv/modules/exam/entity_definitions/exam.json:
 *       show_answers: enum_values ["never","after_completion","after_all_attempts"]
 *   - priv/modules/exam/entity_definitions/exam_question_rule.json:
 *       mode: enum_values ["manual","random"]
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { IntlProvider } from 'react-intl'
expect.extend(jestDomMatchers)

import { EntityRecordForm } from '../EntityRecordForm'
import type { EntityDefinition, EntityFieldDef } from '@/types/api'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function definitionWithField(entityName: string, field: EntityFieldDef): EntityDefinition {
  return {
    id: `def-${entityName}`,
    name: entityName,
    display_name: entityName,
    definition: {
      name: entityName,
      display_name: entityName,
      fields: [field],
    },
    content_hash: 'deadbeef',
    logical_shape_version: 'cafebabe',
    artifact_version_id: 'av-1',
    status: 'active',
    inserted_at: '2026-01-01T00:00:00Z',
  }
}

function renderForField(entityName: string, field: EntityFieldDef, title: string) {
  return render(
    <IntlProvider locale="en" messages={{}}>
      <EntityRecordForm
        definition={definitionWithField(entityName, field)}
        fieldTitles={{ [field.name]: title }}
        onSubmit={vi.fn()}
        onCancel={vi.fn()}
        submitLabel="Create"
        cancelLabel="Cancel"
      />
    </IntlProvider>,
  )
}

function optionValues(select: HTMLSelectElement): string[] {
  // Exclude the leading blank "Select option" placeholder -- that one is not
  // part of the field's own enum_values.
  return Array.from(select.options)
    .map((o) => o.value)
    .filter((v) => v !== '')
}

describe('REQ-340 -- enum widget renders real enum_values from three different entities\' real enum fields, never a hard-coded list', () => {
  it('question.difficulty -> ["easy","medium","hard"]', () => {
    const field: EntityFieldDef = {
      name: 'difficulty',
      type: 'enum',
      enum_values: ['easy', 'medium', 'hard'],
      required: true,
      queried: true,
    }
    renderForField('question', field, 'Difficulty')

    const select = screen.getByLabelText('Difficulty', { exact: false }) as HTMLSelectElement
    expect(select.tagName).toBe('SELECT')
    expect(optionValues(select)).toEqual(['easy', 'medium', 'hard'])
  })

  it('exam.show_answers -> ["never","after_completion","after_all_attempts"]', () => {
    const field: EntityFieldDef = {
      name: 'show_answers',
      type: 'enum',
      enum_values: ['never', 'after_completion', 'after_all_attempts'],
      required: true,
      queried: false,
    }
    renderForField('exam', field, 'Show answers')

    const select = screen.getByLabelText('Show answers', { exact: false }) as HTMLSelectElement
    expect(select.tagName).toBe('SELECT')
    expect(optionValues(select)).toEqual(['never', 'after_completion', 'after_all_attempts'])
  })

  it('exam_question_rule.mode -> ["manual","random"]', () => {
    const field: EntityFieldDef = {
      name: 'mode',
      type: 'enum',
      enum_values: ['manual', 'random'],
      required: true,
      queried: true,
    }
    renderForField('exam_question_rule', field, 'Mode')

    const select = screen.getByLabelText('Mode', { exact: false }) as HTMLSelectElement
    expect(select.tagName).toBe('SELECT')
    expect(optionValues(select)).toEqual(['manual', 'random'])
  })
})

describe('REQ-340 -- rendered options come from the definition\'s own enum_values, not a fork per entity', () => {
  it('changing a mocked definition\'s enum_values changes the rendered options to match', () => {
    const baseField: EntityFieldDef = {
      name: 'status',
      type: 'enum',
      enum_values: ['draft', 'active', 'archived'],
      required: true,
      queried: true,
    }
    const { unmount } = renderForField('exam', baseField, 'Status')
    let select = screen.getByLabelText('Status', { exact: false }) as HTMLSelectElement
    expect(optionValues(select)).toEqual(['draft', 'active', 'archived'])
    unmount()
    cleanup()

    // Same field name, same entity, DIFFERENT enum_values -- proves the
    // widget reads the option list from the field definition each render,
    // rather than caching or hard-coding a per-entity option list.
    const changedField: EntityFieldDef = {
      ...baseField,
      enum_values: ['pending_review', 'published'],
    }
    renderForField('exam', changedField, 'Status')
    select = screen.getByLabelText('Status', { exact: false }) as HTMLSelectElement
    expect(optionValues(select)).toEqual(['pending_review', 'published'])
    expect(optionValues(select)).not.toEqual(['draft', 'active', 'archived'])
  })
})
