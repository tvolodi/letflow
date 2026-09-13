// @vitest-environment jsdom
/**
 * REQ-336 AC4/AC5 — server-error surfacing, against the REAL shapes
 * lib/letflow/routers/entities.ex actually produces (not a client-guessed
 * validation message):
 *
 *  - AC4 (duplicate name -> 422): `handle_create_record`'s
 *    `{:error, {:record_payload_invalid, violations}}` branch
 *    (render_record_command/3) responds 422 with
 *    `{"errors": [{"code": ..., "path": [...], "message": ...}]}` via
 *    `violation_map/1` -- this is the render_record_command's own real
 *    shape, quoted from lib/letflow/routers/entities.ex:1214-1222 and
 *    :2459-2465, not invented for this test.
 *  - AC5 (edit conflict -> 409): client.ts's `request()` already special-
 *    cases 409 (PD-08), building `ApiError.details.xResourceVersion` from
 *    the response's `X-Resource-Version` header. This test constructs that
 *    exact ApiError shape (the one client.ts's own request() builds, per
 *    web/src/api/client.ts:106-125) and asserts EntityRecordForm surfaces a
 *    conflict state from it, not a second detection mechanism.
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

function renderForm(apiError: ApiError | null) {
  return render(
    <IntlProvider locale="en" messages={entitiesMessages.en}>
      <EntityRecordForm
        definition={TAG_DEFINITION}
        fieldTitles={{ name: 'Name' }}
        onSubmit={vi.fn()}
        onCancel={vi.fn()}
        submitLabel="Create"
        cancelLabel="Cancel"
        apiError={apiError}
      />
    </IntlProvider>,
  )
}

describe('REQ-336 AC4 — duplicate-name 422 surfaces as a form-level error, from the real router shape', () => {
  it('maps a {:record_payload_invalid, violations} 422 (violation_map/1 shape) to the name field', () => {
    // The exact wire shape render_record_command/3 builds for
    // {:error, {:record_payload_invalid, violations}} via violation_map/1
    // (lib/letflow/routers/entities.ex:1214-1222, :2459-2465): 422, with
    // "errors" holding {code, path, message} entries, path being the field
    // path list.
    const apiError: ApiError = {
      status: 422,
      code: 'unprocessable_entity',
      message: 'entity record payload failed validation',
      details: {
        errors: [
          { code: 'unique', path: ['name'], message: 'name has already been taken' },
        ],
      },
    }

    renderForm(apiError)

    expect(screen.getByText('name has already been taken')).toBeInTheDocument()
    // Field-attributed -- no redundant generic banner on top of it.
    expect(screen.queryByTestId('entity-form-error-banner')).not.toBeInTheDocument()
  })

  it('falls back to a form-level banner when the violation does not name a rendered field', () => {
    const apiError: ApiError = {
      status: 422,
      code: 'unprocessable_entity',
      message: 'entity record payload failed validation',
      details: { errors: [{ code: 'unknown_field', path: ['unrelated_field'], message: 'bogus' }] },
    }

    renderForm(apiError)

    expect(screen.getByTestId('entity-form-error-banner')).toBeInTheDocument()
  })
})

describe('REQ-336 AC5 — edit conflict surfaces via client.ts\'s existing PD-08 409 handling', () => {
  it('a 409 ApiError carrying details.xResourceVersion (client.ts request()\'s own shape) renders a conflict state', () => {
    const apiError: ApiError = {
      status: 409,
      code: 'STALE_VERSION',
      message: 'Conflict',
      details: { xResourceVersion: 'a1b2c3d4' },
    }

    renderForm(apiError)

    const banner = screen.getByTestId('entity-form-conflict-banner')
    expect(banner).toBeInTheDocument()
    expect(screen.getByTestId('entity-form-conflict-version')).toHaveTextContent('a1b2c3d4')
    // Not the generic 422 banner testid -- a distinct conflict state, not a
    // reuse of the plain-validation-error path.
    expect(screen.queryByTestId('entity-form-error-banner')).not.toBeInTheDocument()
  })
})
