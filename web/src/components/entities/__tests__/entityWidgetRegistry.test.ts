// @vitest-environment jsdom
/**
 * REQ-342 -- sanity check that the two new widgets are actually reachable
 * through the SAME fieldRegistry map REQ-284/CMP-UI-05 built (not a parallel
 * registry), under the two internal routing keys entityFieldToFormField.ts
 * assigns (`entity-localized-text`, `entity-fk-reference`) -- deliberately
 * NOT part of the closed, tenant-facing `x-ui.widget` vocabulary
 * (web/src/components/forms/widgets/vocabulary.ts), which this requirement
 * does not touch.
 */
import { describe, it, expect } from 'vitest'
import { fieldRegistry } from '@/components/forms/fieldRegistry'
import {
  registerEntityWidgets,
  ENTITY_LOCALIZED_TEXT_WIDGET,
  ENTITY_FK_REFERENCE_WIDGET,
} from '../entityWidgetRegistry'
import { X_UI_WIDGET_NAMES } from '@/components/forms/widgets/vocabulary'

describe('REQ-342 -- entity widget registry', () => {
  it('registers entity-localized-text and entity-fk-reference into the shared fieldRegistry', () => {
    registerEntityWidgets()
    expect(fieldRegistry.get(ENTITY_LOCALIZED_TEXT_WIDGET)).toBeDefined()
    expect(fieldRegistry.get(ENTITY_FK_REFERENCE_WIDGET)).toBeDefined()
  })

  it('neither new widget key is part of the closed, tenant-facing x-ui.widget vocabulary', () => {
    expect(X_UI_WIDGET_NAMES as readonly string[]).not.toContain(ENTITY_LOCALIZED_TEXT_WIDGET)
    expect(X_UI_WIDGET_NAMES as readonly string[]).not.toContain(ENTITY_FK_REFERENCE_WIDGET)
  })
})
