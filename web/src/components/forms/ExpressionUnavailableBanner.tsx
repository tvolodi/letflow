/**
 * REQ-293 — the shared "condition unavailable" banner (design doc §8.4). One
 * component, three call sites: field-row for `visible_when`, input-replacement
 * for `computed`, form-level for `cross_field_validation`. Not a native
 * `<input disabled>` — an `<input>` element, even disabled, is a "visible input"
 * in the DOM-query sense the AC5 tests must distinguish from "not rendered
 * visible."
 */

export type ExpressionKind = 'visible_when' | 'computed' | 'cross_field_validation'

export interface ExpressionUnavailableBannerProps {
  field: string
  kind: ExpressionKind
  reason: string
}

const KIND_LABEL: Record<ExpressionKind, string> = {
  visible_when: 'visibility condition',
  computed: 'computed value',
  cross_field_validation: 'validation rule',
}

export function ExpressionUnavailableBanner(props: ExpressionUnavailableBannerProps) {
  const { field, kind, reason } = props

  return (
    <div
      role="alert"
      data-testid={`expr-unavailable-${field}-${kind}`}
      style={{
        background: 'var(--color-warning-light)',
        border: '1px solid var(--color-warning-border)',
        borderRadius: '4px',
        padding: '.5rem .75rem',
        fontSize: '.85rem',
        color: 'var(--color-warning-dark)',
      }}
    >
      The {KIND_LABEL[kind]} for &ldquo;{field}&rdquo; is currently unavailable ({reason}).
    </div>
  )
}
