/**
 * REQ-284 — registers the closed x-ui.widget vocabulary's renderers into
 * fieldRegistry. Called exactly once, at application start
 * (web/src/main.tsx, before the first render). A bare call, no return value
 * consumed — mirrors fieldRegistry.ts's own moduledoc ("Empty registry —
 * populated by app code") and matches the existing sentinel-based test
 * harness pattern (fieldRegistry.clear() in afterEach across the ARIA test
 * suites, which expects registration to be a distinct, re-runnable step).
 */

import { fieldRegistry } from '../fieldRegistry'
import { X_UI_WIDGET_NAMES } from './vocabulary'
import { richTextLiteRenderer } from './richTextLite'
import { maskedInputRenderer } from './maskedInput'
import { searchableSelectRenderer } from './searchableSelect'
import { ratingRenderer } from './rating'
import { sliderRenderer } from './slider'

const RENDERERS_BY_NAME = {
  'rich-text-lite': richTextLiteRenderer,
  'masked-input': maskedInputRenderer,
  'searchable-select': searchableSelectRenderer,
  rating: ratingRenderer,
  slider: sliderRenderer,
} as const

export function registerBuiltinWidgets(): void {
  for (const name of X_UI_WIDGET_NAMES) {
    fieldRegistry.set(name, RENDERERS_BY_NAME[name])
  }
}
