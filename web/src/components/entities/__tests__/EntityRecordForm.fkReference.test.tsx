// @vitest-environment jsdom
/**
 * REQ-342 -- the entity-fk-reference widget, proven against real foreign-key
 * field shapes from priv/packs/bilimbaga/entity_definitions/. Fetch is
 * mocked at the transport boundary only (window.fetch), exactly as
 * web/src/api/__tests__/entities.test.ts already does for entitiesApi
 * itself -- every call below goes through the REAL entitiesApi.queryRecords
 * / entitiesApi.getActiveDefinition -> client.ts -> fetch path, proving a
 * real POST /entities/query (and a real GET .../definitions/active/:name,
 * used to resolve which field of the referenced entity is its
 * human-readable label) rather than a client-guessed shape.
 *
 * CHECK FOR EXISTING COVERAGE (per REQ-342's own instruction, run before any
 * widget code was written for this requirement):
 *
 *   cat web/src/components/forms/widgets/searchableSelect.tsx
 *
 * -> `searchableSelectRenderer` is a client-side filter over `fieldDef.enum`
 *    with NO network request ever (its own doc comment says so explicitly).
 *    A foreign-key reference field's option universe is the referenced
 *    entity's OWN records, which do not exist in `fieldDef.enum` and can
 *    only be resolved via `POST /entities/query` -- so this widget EXTENDS
 *    that same file with a second exported renderer
 *    (`entityReferenceSelectRenderer`) rather than reusing the existing one
 *    unmodified, and rather than forking a brand-new file.
 *
 * The three foreign-key fields below are taken verbatim from the actual
 * committed definition documents (not invented):
 *   - priv/packs/bilimbaga/entity_definitions/question.json:
 *       category_id -> fk_question_category_id -> references_entity "category"
 *   - priv/packs/bilimbaga/entity_definitions/exam_section.json:
 *       exam_id -> fk_exam_section_exam_id -> references_entity "exam"
 *   - priv/packs/bilimbaga/entity_definitions/exam_question_rule_tag.json:
 *       tag_id -> fk_exam_question_rule_tag_tag_id -> references_entity "tag"
 *
 * The referenced entities' own real field shapes drive the resolved label:
 *   - category.json: name is :localized_text (object-valued label)
 *   - exam.json: title is :localized_text (object-valued label)
 *   - tag.json: name is :string (plain-string label) -- REQ-340's/REQ-336's
 *     own pilot entity, and the one place in this pack that is NOT
 *     localized (tag.json's own description says so).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { IntlProvider } from 'react-intl'
expect.extend(jestDomMatchers)

import { EntityRecordForm } from '../EntityRecordForm'
import type { EntityDefinition } from '@/types/api'
import { entitiesMessages } from '@/i18n/entitiesMessages'
import { setToken, clearToken } from '@/api/client'

const originalFetch = window.fetch

function jsonResponse(body: unknown, init: { status?: number } = {}) {
  return Promise.resolve(
    new Response(JSON.stringify(body), {
      status: init.status ?? 200,
      headers: { 'Content-Type': 'application/json' },
    }),
  )
}

beforeEach(() => {
  setToken('test-token')
})

afterEach(() => {
  window.fetch = originalFetch
  clearToken()
  cleanup()
  vi.restoreAllMocks()
})

const CATEGORY_DEFINITION: EntityDefinition = {
  id: 'def-category',
  name: 'category',
  display_name: 'Category',
  definition: {
    name: 'category',
    display_name: 'Category',
    fields: [
      { name: 'name', type: 'localized_text', locales: ['kk', 'ru', 'en'], queried: true, required: true },
      { name: 'track', type: 'string', queried: true, required: false },
      { name: 'sort_order', type: 'integer', queried: true, required: true },
    ],
  },
  content_hash: 'deadbeef',
  logical_shape_version: 'cafebabe',
  artifact_version_id: 'av-1',
  status: 'active',
  inserted_at: '2026-01-01T00:00:00Z',
}

const EXAM_DEFINITION: EntityDefinition = {
  id: 'def-exam',
  name: 'exam',
  display_name: 'Exam',
  definition: {
    name: 'exam',
    display_name: 'Exam',
    fields: [{ name: 'title', type: 'localized_text', locales: ['kk', 'ru', 'en'], queried: true, required: true }],
  },
  content_hash: 'deadbeef',
  logical_shape_version: 'cafebabe',
  artifact_version_id: 'av-1',
  status: 'active',
  inserted_at: '2026-01-01T00:00:00Z',
}

const TAG_DEFINITION: EntityDefinition = {
  id: 'def-tag',
  name: 'tag',
  display_name: 'Tag',
  definition: {
    name: 'tag',
    display_name: 'Tag',
    fields: [{ name: 'name', type: 'string', queried: true, required: true }],
    constraints: [{ name: 'uq_tag_name', type: 'unique', fields: ['name'] }],
  },
  content_hash: 'deadbeef',
  logical_shape_version: 'cafebabe',
  artifact_version_id: 'av-1',
  status: 'active',
  inserted_at: '2026-01-01T00:00:00Z',
}

function questionCategoryIdForm(onSubmit: (v: Record<string, unknown>) => void) {
  const definition: EntityDefinition = {
    id: 'def-question',
    name: 'question',
    display_name: 'Question',
    definition: {
      name: 'question',
      display_name: 'Question',
      fields: [{ name: 'category_id', type: 'string', queried: true, required: true }],
      foreign_keys: [{ name: 'fk_question_category_id', field: 'category_id', references_entity: 'category' }],
    },
    content_hash: 'deadbeef',
    logical_shape_version: 'cafebabe',
    artifact_version_id: 'av-1',
    status: 'active',
    inserted_at: '2026-01-01T00:00:00Z',
  }
  return render(
    <IntlProvider locale="en" messages={entitiesMessages.en}>
      <EntityRecordForm
        definition={definition}
        fieldTitles={{ category_id: 'Category' }}
        onSubmit={onSubmit}
        onCancel={vi.fn()}
        submitLabel="Create"
        cancelLabel="Cancel"
      />
    </IntlProvider>,
  )
}

function examSectionExamIdForm(onSubmit: (v: Record<string, unknown>) => void) {
  const definition: EntityDefinition = {
    id: 'def-exam-section',
    name: 'exam_section',
    display_name: 'Exam Section',
    definition: {
      name: 'exam_section',
      display_name: 'Exam Section',
      fields: [{ name: 'exam_id', type: 'string', queried: true, required: true }],
      foreign_keys: [{ name: 'fk_exam_section_exam_id', field: 'exam_id', references_entity: 'exam' }],
    },
    content_hash: 'deadbeef',
    logical_shape_version: 'cafebabe',
    artifact_version_id: 'av-1',
    status: 'active',
    inserted_at: '2026-01-01T00:00:00Z',
  }
  return render(
    <IntlProvider locale="en" messages={entitiesMessages.en}>
      <EntityRecordForm
        definition={definition}
        fieldTitles={{ exam_id: 'Exam' }}
        onSubmit={onSubmit}
        onCancel={vi.fn()}
        submitLabel="Create"
        cancelLabel="Cancel"
      />
    </IntlProvider>,
  )
}

function examQuestionRuleTagTagIdForm(onSubmit: (v: Record<string, unknown>) => void) {
  const definition: EntityDefinition = {
    id: 'def-exam-question-rule-tag',
    name: 'exam_question_rule_tag',
    display_name: 'Exam Question Rule Tag',
    definition: {
      name: 'exam_question_rule_tag',
      display_name: 'Exam Question Rule Tag',
      fields: [
        { name: 'rule_id', type: 'string', queried: true, required: true },
        { name: 'tag_id', type: 'string', queried: true, required: true },
      ],
      foreign_keys: [
        { name: 'fk_exam_question_rule_tag_rule_id', field: 'rule_id', references_entity: 'exam_question_rule' },
        { name: 'fk_exam_question_rule_tag_tag_id', field: 'tag_id', references_entity: 'tag' },
      ],
      constraints: [
        { name: 'uq_exam_question_rule_tag_rule_id_tag_id', type: 'unique', fields: ['rule_id', 'tag_id'] },
      ],
    },
    content_hash: 'deadbeef',
    logical_shape_version: 'cafebabe',
    artifact_version_id: 'av-1',
    status: 'active',
    inserted_at: '2026-01-01T00:00:00Z',
  }
  return render(
    <IntlProvider locale="en" messages={entitiesMessages.en}>
      <EntityRecordForm
        definition={definition}
        fieldTitles={{ rule_id: 'Rule', tag_id: 'Tag' }}
        onSubmit={onSubmit}
        onCancel={vi.fn()}
        submitLabel="Create"
        cancelLabel="Cancel"
      />
    </IntlProvider>,
  )
}

describe('REQ-342 -- entity-fk-reference widget resolves a human-readable label via a real POST /entities/query call', () => {
  it('question.category_id -> category: label from category.name (:localized_text), not the raw record_id', async () => {
    const user = userEvent.setup()
    const fetchSpy = vi.fn(async (url: string, init?: RequestInit) => {
      const method = init?.method ?? 'GET'
      if (method === 'GET' && String(url).includes('/entities/definitions/active/category')) {
        return jsonResponse(CATEGORY_DEFINITION)
      }
      if (method === 'POST' && String(url).includes('/entities/query')) {
        const body = JSON.parse(init!.body as string)
        expect(body.entity_type).toBe('category')
        return jsonResponse({
          items: [
            {
              record_id: 'cat-1',
              entity_type: 'category',
              field_values: { name: { kk: 'Қауіпсіздік', ru: 'Безопасность', en: 'Security' }, track: 'security', sort_order: 1 },
              deleted: false,
              entity_def_version: 'v1',
              last_event_global_seq: 1,
            },
          ],
          next_cursor: null,
        })
      }
      return jsonResponse({ error: 'unexpected' }, { status: 404 })
    })
    window.fetch = fetchSpy as unknown as typeof window.fetch

    const onSubmit = vi.fn()
    questionCategoryIdForm(onSubmit)

    const combobox = screen.getByRole('combobox')
    await user.type(combobox, 'sec')

    const option = await screen.findByRole('option', { name: 'Security' })
    // The raw record_id is never shown as option text.
    expect(screen.queryByText('cat-1')).not.toBeInTheDocument()
    await user.click(option)

    await user.click(screen.getByTestId('entity-form-submit'))

    expect(onSubmit).toHaveBeenCalledTimes(1)
    const [fieldValues] = onSubmit.mock.calls[0] as [Record<string, unknown>]
    // The SUBMITTED value is the real record_id (the fk column's actual
    // wire value) -- only the DISPLAYED option text is the resolved label.
    expect(fieldValues.category_id).toBe('cat-1')

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        expect.stringContaining('/entities/definitions/active/category'),
        expect.anything(),
      )
    })
  })

  it('exam_section.exam_id -> exam: label from exam.title (:localized_text)', async () => {
    const user = userEvent.setup()
    const fetchSpy = vi.fn(async (url: string, init?: RequestInit) => {
      const method = init?.method ?? 'GET'
      if (method === 'GET' && String(url).includes('/entities/definitions/active/exam')) {
        return jsonResponse(EXAM_DEFINITION)
      }
      if (method === 'POST' && String(url).includes('/entities/query')) {
        const body = JSON.parse(init!.body as string)
        expect(body.entity_type).toBe('exam')
        return jsonResponse({
          items: [
            {
              record_id: 'exam-1',
              entity_type: 'exam',
              field_values: { title: { kk: 'Емтихан', ru: 'Экзамен', en: 'Midterm Exam' } },
              deleted: false,
              entity_def_version: 'v1',
              last_event_global_seq: 1,
            },
          ],
          next_cursor: null,
        })
      }
      return jsonResponse({ error: 'unexpected' }, { status: 404 })
    })
    window.fetch = fetchSpy as unknown as typeof window.fetch

    const onSubmit = vi.fn()
    examSectionExamIdForm(onSubmit)

    const combobox = screen.getByRole('combobox')
    await user.type(combobox, 'mid')

    const option = await screen.findByRole('option', { name: 'Midterm Exam' })
    await user.click(option)
    await user.click(screen.getByTestId('entity-form-submit'))

    const [fieldValues] = onSubmit.mock.calls[0] as [Record<string, unknown>]
    expect(fieldValues.exam_id).toBe('exam-1')
  })

  it('exam_question_rule_tag.tag_id -> tag: label from tag.name (:string, the one non-localized name field in the pack)', async () => {
    const user = userEvent.setup()
    const fetchSpy = vi.fn(async (url: string, init?: RequestInit) => {
      const method = init?.method ?? 'GET'
      if (method === 'GET' && String(url).includes('/entities/definitions/active/tag')) {
        return jsonResponse(TAG_DEFINITION)
      }
      if (method === 'GET' && String(url).includes('/entities/definitions/active/exam_question_rule')) {
        return jsonResponse({ ...TAG_DEFINITION, name: 'exam_question_rule' })
      }
      if (method === 'POST' && String(url).includes('/entities/query')) {
        const body = JSON.parse(init!.body as string)
        if (body.entity_type === 'tag') {
          return jsonResponse({
            items: [
              {
                record_id: 'tag-1',
                entity_type: 'tag',
                field_values: { name: 'algebra' },
                deleted: false,
                entity_def_version: 'v1',
                last_event_global_seq: 1,
              },
            ],
            next_cursor: null,
          })
        }
        if (body.entity_type === 'exam_question_rule') {
          return jsonResponse({
            items: [
              {
                record_id: 'rule-1',
                entity_type: 'exam_question_rule',
                field_values: { name: 'Rule A' },
                deleted: false,
                entity_def_version: 'v1',
                last_event_global_seq: 1,
              },
            ],
            next_cursor: null,
          })
        }
        return jsonResponse({ items: [], next_cursor: null })
      }
      return jsonResponse({ error: 'unexpected' }, { status: 404 })
    })
    window.fetch = fetchSpy as unknown as typeof window.fetch

    const onSubmit = vi.fn()
    examQuestionRuleTagTagIdForm(onSubmit)

    // Both rule_id and tag_id are `required: true` in the real
    // exam_question_rule_tag.json shape -- both must resolve to a real
    // record_id before the form is submittable.
    const ruleCombobox = screen.getByRole('combobox', { name: /^rule/i })
    await user.type(ruleCombobox, 'rule')
    const ruleOption = await screen.findByRole('option', { name: 'Rule A' })
    await user.click(ruleOption)

    const tagCombobox = screen.getByRole('combobox', { name: /^tag/i })
    await user.type(tagCombobox, 'alg')

    const option = await screen.findByRole('option', { name: 'algebra' })
    await user.click(option)
    await user.click(screen.getByTestId('entity-form-submit'))

    expect(onSubmit).toHaveBeenCalledTimes(1)
    const [fieldValues] = onSubmit.mock.calls[0] as [Record<string, unknown>]
    expect(fieldValues.tag_id).toBe('tag-1')
    expect(fieldValues.rule_id).toBe('rule-1')
  })
})
