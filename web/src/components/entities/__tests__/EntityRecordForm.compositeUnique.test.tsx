// @vitest-environment jsdom
/**
 * REQ-340 -- unique-composite constraint error surfacing, proven as the SAME
 * path REQ-336 built for tag.name's single-column violation
 * (`EntityRecordForm`'s `fieldErrorsFromApiError`/`isFullyFieldAttributed`),
 * with NO new client-side validation or uniqueness-checking logic added.
 *
 * The wire shape asserted below is not client-guessed: it is exactly what
 * `lib/letflow/entities/records.ex`'s `unique_violation_from_constraint/2`
 * (backing `Letflow.Entities.Records.create_record/2`) produces for a
 * composite `constraints` entry, rendered through
 * `lib/letflow/routers/entities.ex`'s existing `violation_map/1`:
 *
 *   %{"code" => "unique", "path" => fields, "message" => "#{Enum.join(fields, ", ")} has already been taken"}
 *
 * `constraint_fields/2`'s own comment names this exact generalization:
 * "generalizes to a composite constraint (REQ-336/REQ-340's
 * `question_tag`-shaped `[question_id, tag_id]` case) for free" -- no router
 * or entity-write code needed changing for this requirement either;
 * `unique_violation_from_constraint/2` already special-cases nothing about
 * arity, it just joins whatever `fields` list the constraint declared.
 *
 * Two of REQ-326/REQ-327's real composite constraints are exercised, per
 * priv/modules/exam/entity_definitions/:
 *   - question_tag.json: uq_question_tag_question_id_tag_id, unique over
 *     ["question_id", "tag_id"]
 *   - exam_section.json: uq_exam_section_exam_id_sort_order, unique over
 *     ["exam_id", "sort_order"]
 *
 * `EntityRecordForm`'s existing `fieldErrorsFromApiError` reads only
 * `path[0]` as the attributed field name -- for a composite violation that
 * means the message is attributed to the FIRST field in the constraint's
 * declared field list. That is the mechanism as REQ-336 built it (no change
 * made here): this test proves that mechanism does not break, crash, or
 * silently drop the message for a multi-element `path`, and that it is
 * still correctly recognised as "fully field-attributed" (both path
 * elements resolve to fields this form actually renders) so no redundant
 * form-level banner appears -- the same outcome
 * EntityRecordForm.errors.test.tsx already asserts for the single-column
 * case.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { IntlProvider } from 'react-intl'
expect.extend(jestDomMatchers)

import { EntityRecordForm } from '../EntityRecordForm'
import type { ApiError, EntityDefinition } from '@/types/api'
import { entitiesMessages } from '@/i18n/entitiesMessages'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

const QUESTION_TAG_DEFINITION: EntityDefinition = {
  id: 'def-question-tag',
  name: 'question_tag',
  display_name: 'Question Tag',
  definition: {
    name: 'question_tag',
    display_name: 'Question Tag',
    fields: [
      { name: 'question_id', type: 'string', required: true, queried: true },
      { name: 'tag_id', type: 'string', required: true, queried: true },
    ],
    constraints: [
      { name: 'uq_question_tag_question_id_tag_id', type: 'unique', fields: ['question_id', 'tag_id'] },
    ],
  },
  content_hash: 'deadbeef',
  logical_shape_version: 'cafebabe',
  artifact_version_id: 'av-1',
  status: 'active',
  inserted_at: '2026-01-01T00:00:00Z',
}

const EXAM_SECTION_DEFINITION: EntityDefinition = {
  id: 'def-exam-section',
  name: 'exam_section',
  display_name: 'Exam Section',
  definition: {
    name: 'exam_section',
    display_name: 'Exam Section',
    fields: [
      { name: 'exam_id', type: 'string', required: true, queried: true },
      { name: 'sort_order', type: 'integer', required: true, queried: true },
    ],
    constraints: [
      { name: 'uq_exam_section_exam_id_sort_order', type: 'unique', fields: ['exam_id', 'sort_order'] },
    ],
  },
  content_hash: 'deadbeef',
  logical_shape_version: 'cafebabe',
  artifact_version_id: 'av-1',
  status: 'active',
  inserted_at: '2026-01-01T00:00:00Z',
}

function renderForm(definition: EntityDefinition, fieldTitles: Record<string, string>, apiError: ApiError | null) {
  return render(
    <IntlProvider locale="en" messages={entitiesMessages.en}>
      <EntityRecordForm
        definition={definition}
        fieldTitles={fieldTitles}
        onSubmit={vi.fn()}
        onCancel={vi.fn()}
        submitLabel="Create"
        cancelLabel="Cancel"
        apiError={apiError}
      />
    </IntlProvider>,
  )
}

describe('REQ-340 -- composite-unique violation surfaces through REQ-336\'s existing error path, no new client mechanism', () => {
  it('question_tag [question_id, tag_id]: the real Records.create_record/2 violation_map/1 shape renders as a field message with no generic banner', () => {
    const apiError: ApiError = {
      status: 422,
      code: 'unprocessable_entity',
      message: 'entity record payload failed validation',
      details: {
        errors: [
          {
            code: 'unique',
            path: ['question_id', 'tag_id'],
            message: 'question_id, tag_id has already been taken',
          },
        ],
      },
    }

    renderForm(
      QUESTION_TAG_DEFINITION,
      { question_id: 'Question', tag_id: 'Tag' },
      apiError,
    )

    // fieldErrorsFromApiError attributes the message to path[0] --
    // 'question_id' -- exactly as it does for a single-column violation.
    expect(screen.getByText('question_id, tag_id has already been taken')).toBeInTheDocument()
    // Both path elements ('question_id', 'tag_id') are real rendered fields,
    // so isFullyFieldAttributed is true and no redundant form-level banner
    // is shown -- same outcome REQ-336's own AC4 test asserts for tag.name.
    expect(screen.queryByTestId('entity-form-error-banner')).not.toBeInTheDocument()
  })

  it('exam_section [exam_id, sort_order]: same path, a second real composite constraint', () => {
    const apiError: ApiError = {
      status: 422,
      code: 'unprocessable_entity',
      message: 'entity record payload failed validation',
      details: {
        errors: [
          {
            code: 'unique',
            path: ['exam_id', 'sort_order'],
            message: 'exam_id, sort_order has already been taken',
          },
        ],
      },
    }

    renderForm(
      EXAM_SECTION_DEFINITION,
      { exam_id: 'Exam', sort_order: 'Sort order' },
      apiError,
    )

    expect(screen.getByText('exam_id, sort_order has already been taken')).toBeInTheDocument()
    expect(screen.queryByTestId('entity-form-error-banner')).not.toBeInTheDocument()
  })
})
