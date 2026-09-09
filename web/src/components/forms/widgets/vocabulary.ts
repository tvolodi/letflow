/**
 * REQ-284 — single source of truth for the closed `x-ui.widget` vocabulary.
 *
 * This literal array is what the vocabulary document
 * (docs/frontend/x-ui-widget-vocabulary.md), the registration module
 * (./index.ts), and the AC2 registry-equality test all key off of. It is a
 * hand-written literal, not a computed derivation, so a mismatch between any
 * two of those three places shows up as a failing test rather than silently
 * drifting.
 */
export const X_UI_WIDGET_NAMES = [
  'rich-text-lite',
  'masked-input',
  'searchable-select',
  'rating',
  'slider',
] as const

export type XUiWidgetName = (typeof X_UI_WIDGET_NAMES)[number]
