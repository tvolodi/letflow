/** bilimbagaEntities — REQ-343
 *
 *  The nine remaining BilimBaga entity types this requirement wires screens
 *  for (REQ-326: category, question, answer_option, question_tag; REQ-327:
 *  exam, exam_section, exam_question_rule, exam_question_rule_tag,
 *  exam_manual_question). This is DATA, not a tenth hand-written screen: one
 *  generic component (`web/src/pages/entities/EntityCrudPage.tsx`, itself a
 *  direct descendant of REQ-336's `TagListPage.tsx` pilot) is parameterized
 *  by `entityType` from this list, rather than duplicating the pilot's
 *  ~280-line list/create/edit/delete screen nine times. A single dynamic
 *  route (`/admin/bilimbaga/:entityType` in web/src/router.tsx) renders it.
 *
 *  GAP NOTE — self-referential parent_id (see this requirement's own
 *  close-out for the full statement). category.parent_id and
 *  question.parent_id do NOT exist on either entity definition today
 *  (priv/packs/bilimbaga/entity_definitions/category.json and question.json
 *  — see each definition document's own description field, and
 *  priv/packs/bilimbaga/entity_definitions/README-constraints.md). Because
 *  neither field is declared, `EntityCrudPage` — which renders exactly the
 *  fields `GET /entities/definitions/active/:name` returns — cannot and
 *  does not render a parent/tree field for either entity. No client-side
 *  tree-picker, no fake `parent_id` field, no workaround of any kind is
 *  added here or anywhere else in this requirement's diff. The category
 *  tree / question-version-lineage UI is blocked on REQ-324's follow-on
 *  definition change, not on anything this requirement controls.
 */

export interface BilimBagaEntityConfig {
  /** The entity_type string exactly as declared in
   *  priv/packs/bilimbaga/entity_definitions/<entityType>.json's `name`. */
  entityType: string
}

export const BILIMBAGA_ENTITY_TYPES: BilimBagaEntityConfig[] = [
  { entityType: 'category' },
  { entityType: 'question' },
  { entityType: 'answer_option' },
  { entityType: 'question_tag' },
  { entityType: 'exam' },
  { entityType: 'exam_section' },
  { entityType: 'exam_question_rule' },
  { entityType: 'exam_question_rule_tag' },
  { entityType: 'exam_manual_question' },
]

export function isBilimBagaEntityType(entityType: string | undefined): boolean {
  return BILIMBAGA_ENTITY_TYPES.some((e) => e.entityType === entityType)
}
