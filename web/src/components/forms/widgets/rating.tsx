/**
 * REQ-284 — `rating` widget.
 *
 * A fixed row of `maximum` selectable segments for a small bounded
 * number/integer scale. `maximum` absent or `> 10` is a registry-population
 * authoring precondition (docs/frontend/x-ui-widget-vocabulary.md §1.4), not
 * a runtime tenant-input check — a schema that omits `maximum` still renders
 * (defaulted here) rather than throwing.
 */

import { useState, type CSSProperties } from 'react'
import type { FieldTypeRenderer, RenderInputArgs } from '../fieldRegistry'

const DEFAULT_MIN = 1
const DEFAULT_MAX = 5

const segmentStyles = (selected: boolean): CSSProperties => ({
  width: '2rem',
  height: '2rem',
  border: '1px solid var(--color-neutral-400)',
  borderRadius: '4px',
  background: selected ? 'var(--color-primary-500, var(--color-neutral-300))' : 'transparent',
  cursor: 'pointer',
  fontSize: '.85rem',
})

function RatingInput({
  fieldName,
  fieldDef,
  register,
  ariaDescribedBy,
  ariaErrorMessage,
  ariaRequired,
}: RenderInputArgs): React.ReactElement {
  const min = fieldDef.minimum ?? DEFAULT_MIN
  const max = fieldDef.maximum ?? DEFAULT_MAX
  const [value, setValue] = useState<number | null>(null)

  const select = (n: number): void => {
    setValue(n)
    void register.onChange({ target: { name: fieldName, value: n }, type: 'change' })
  }

  const segments = []
  for (let n = min; n <= max; n++) segments.push(n)

  return (
    <div
      id={fieldName}
      role="radiogroup"
      aria-required={ariaRequired ? 'true' : undefined}
      aria-describedby={ariaDescribedBy}
      aria-invalid={ariaErrorMessage ? 'true' : undefined}
      aria-errormessage={ariaErrorMessage}
      style={{ display: 'flex', gap: '.35rem' }}
    >
      {segments.map((n) => (
        <button
          key={n}
          type="button"
          role="radio"
          aria-checked={value === n}
          aria-label={`${n} out of ${max}`}
          onClick={() => select(n)}
          style={segmentStyles(value === n)}
        >
          {n}
        </button>
      ))}
      <input type="hidden" name={register.name} ref={register.ref} value={value ?? ''} readOnly />
    </div>
  )
}

export const ratingRenderer: FieldTypeRenderer = {
  renderInput: (args) => <RatingInput {...args} />,
  requiredAriaAttributes: ['aria-required', 'aria-describedby', 'aria-invalid', 'aria-errormessage'],
}
