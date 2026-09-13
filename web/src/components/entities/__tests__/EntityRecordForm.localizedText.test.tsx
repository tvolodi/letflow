// @vitest-environment jsdom
/**
 * REQ-342 -- the entity-localized-text widget, proven against real
 * `:localized_text` field shapes from priv/packs/bilimbaga/entity_definitions/.
 *
 * CHECK FOR EXISTING COVERAGE (per REQ-342's own instruction, run before any
 * widget code was written for this requirement):
 *
 *   grep -ril localized web/src/components/forms
 *
 * -> no hit anywhere under web/src/components/forms/ before this
 *    requirement. `fieldRegistry.ts` had no `localized_text` entry,
 *    `FieldFactory.tsx`'s builtin switch has no `:localized_text`-aware
 *    branch, and `entityFieldToFormField.ts` (REQ-336) explicitly degraded
 *    `:localized_text` to a plain `'string'` field rather than crash. This
 *    requirement therefore ADDS a new registry entry
 *    (`web/src/components/forms/widgets/localizedText.tsx`,
 *    `ENTITY_LOCALIZED_TEXT_WIDGET`) -- it is not extending an existing one,
 *    because none existed.
 *
 * The three field shapes below are taken verbatim from the actual committed
 * definition documents (not invented):
 *   - priv/packs/bilimbaga/entity_definitions/question.json:
 *       stem: :localized_text, locales ["kk","ru","en"], required
 *   - priv/packs/bilimbaga/entity_definitions/category.json:
 *       name: :localized_text, locales ["kk","ru","en"], required
 *   - priv/packs/bilimbaga/entity_definitions/exam_section.json:
 *       title: :localized_text, locales ["kk","ru","en"], NOT required
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { IntlProvider } from 'react-intl'
expect.extend(jestDomMatchers)

import { EntityRecordForm } from '../EntityRecordForm'
import type { EntityDefinition, EntityFieldDef } from '@/types/api'
import { entitiesMessages } from '@/i18n/entitiesMessages'

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

function renderForField(entityName: string, field: EntityFieldDef, title: string, onSubmit: (v: Record<string, unknown>) => void) {
  return render(
    <IntlProvider locale="en" messages={entitiesMessages.en}>
      <EntityRecordForm
        definition={definitionWithField(entityName, field)}
        fieldTitles={{ [field.name]: title }}
        onSubmit={onSubmit}
        onCancel={vi.fn()}
        submitLabel="Create"
        cancelLabel="Cancel"
      />
    </IntlProvider>,
  )
}

describe('REQ-342 -- entity-localized-text widget posts {"kk":...,"ru":...,"en":...}', () => {
  it('question.stem: real request body shaped exactly as Letflow.Entities.Definition\'s :localized_text value', async () => {
    const user = userEvent.setup()
    const field: EntityFieldDef = {
      name: 'stem',
      type: 'localized_text',
      locales: ['kk', 'ru', 'en'],
      search_strategy: 'fulltext',
      queried: true,
      required: true,
    }
    const onSubmit = vi.fn()
    renderForField('question', field, 'Stem', onSubmit)

    await user.type(screen.getByLabelText('Kazakh'), 'Не?')
    await user.type(screen.getByLabelText('Russian'), 'Что?')
    await user.type(screen.getByLabelText('English'), 'What?')
    await user.click(screen.getByTestId('entity-form-submit'))

    expect(onSubmit).toHaveBeenCalledTimes(1)
    const [fieldValues] = onSubmit.mock.calls[0] as [Record<string, unknown>]
    expect(fieldValues.stem).toEqual({ kk: 'Не?', ru: 'Что?', en: 'What?' })
  })

  it('category.name: a second real :localized_text field, proving no per-entity fork', async () => {
    const user = userEvent.setup()
    const field: EntityFieldDef = {
      name: 'name',
      type: 'localized_text',
      locales: ['kk', 'ru', 'en'],
      search_strategy: 'plain',
      queried: true,
      required: true,
    }
    const onSubmit = vi.fn()
    renderForField('category', field, 'Name', onSubmit)

    await user.type(screen.getByLabelText('Kazakh'), 'Қауіпсіздік')
    await user.type(screen.getByLabelText('Russian'), 'Безопасность')
    await user.type(screen.getByLabelText('English'), 'Safety')
    await user.click(screen.getByTestId('entity-form-submit'))

    const [fieldValues] = onSubmit.mock.calls[0] as [Record<string, unknown>]
    expect(fieldValues.name).toEqual({ kk: 'Қауіпсіздік', ru: 'Безопасность', en: 'Safety' })
  })

  it('exam_section.title: an optional (not required) :localized_text field renders the same three-locale group', () => {
    const field: EntityFieldDef = {
      name: 'title',
      type: 'localized_text',
      locales: ['kk', 'ru', 'en'],
      search_strategy: 'plain',
      queried: false,
      required: false,
    }
    renderForField('exam_section', field, 'Title', vi.fn())

    expect(screen.getByLabelText('Kazakh')).toBeInTheDocument()
    expect(screen.getByLabelText('Russian')).toBeInTheDocument()
    expect(screen.getByLabelText('English')).toBeInTheDocument()
  })
})
