/** entityFieldToFormField — REQ-336
 *
 *  Bridges `Letflow.Entities.Definition.field_def()` (as returned by
 *  `GET /entities/definitions/active/:name`, `EntityFieldDef` in
 *  web/src/types/api.ts) into `TaskFormField` (web/src/types/forms.ts) --
 *  the SAME type `DynamicFormRenderer`/`FieldFactory.renderFormField`
 *  already consume for form_schema-driven task forms. This is the one
 *  translation point; nothing downstream of it is a parallel widget system.
 *  `renderFormField` is called directly with the result, so a `tag.name`
 *  field (`type: "string", required: true`, no `enum_values`) takes the
 *  IDENTICAL `fieldType === 'string' && !fieldDef.widget && !fieldDef.enum`
 *  branch a form_schema `:string` field would.
 */

import type { EntityFieldDef } from '@/types/api'
import type { TaskFormField } from '@/types/forms'

/** `EntityFieldType` -> `TaskFormField['type']`. `:decimal`/`:integer` both
 *  map to `'number'` (TaskFormField has no separate decimal type);
 *  `:datetime` maps to `'date'` (TaskFormField has no `'datetime'` member --
 *  the closest existing builtin renders an `<input type="date">`, same
 *  degrade a form_schema field with no finer-grained widget would take).
 *  `:enum` maps to `'select'` (renders through FieldFactory's
 *  `fieldType === 'select' && fieldDef.enum` branch); `:json` and
 *  `:localized_text` are out of this pilot's scope (tag.json has neither)
 *  and degrade to `'string'` rather than throwing, so a future entity type
 *  with one of these does not crash this bridge before REQ-340/REQ-342 give
 *  it a real widget. */
function mapFieldType(type: EntityFieldDef['type']): TaskFormField['type'] {
  switch (type) {
    case 'string':
      return 'string'
    case 'integer':
    case 'decimal':
      return 'number'
    case 'boolean':
      return 'boolean'
    case 'date':
    case 'datetime':
      return 'date'
    case 'enum':
      return 'select'
    case 'json':
    case 'localized_text':
    default:
      return 'string'
  }
}

/** `title` — `TaskFormField.title`/`FieldFactory`'s label text is required
 *  to come from a react-intl message catalog per this requirement's i18n
 *  rule, so this bridge deliberately leaves `title` undefined rather than
 *  humanising the field's raw `name` into an English label; the composing
 *  component supplies `title` itself, from `entitiesMessages`, after this
 *  mapping runs. */
export function entityFieldToFormField(field: EntityFieldDef): TaskFormField {
  return {
    name: field.name,
    type: mapFieldType(field.type),
    required: Boolean(field.required),
    enum: field.type === 'enum' ? field.enum_values : undefined,
  }
}
