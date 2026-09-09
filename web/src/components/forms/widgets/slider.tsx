/**
 * REQ-284 — `slider` widget.
 *
 * A native `<input type="range">` spanning `[minimum, maximum]` in
 * `multipleOf` steps (default `1`). The browser already exposes a native
 * range input as `role="slider"` with `aria-valuemin`/`aria-valuemax`/
 * `aria-valuenow` computed from `min`/`max`/`value` — this renderer's job is
 * to set those three native attributes correctly and still apply the full
 * `requiredAriaAttributes` set (docs/frontend/x-ui-widget-vocabulary.md
 * §1.5). `minimum`/`maximum` absent is a registry-population authoring
 * precondition, not a runtime tenant-input check — defaulted here so it
 * renders rather than throws.
 */

import { useState, type CSSProperties } from 'react'
import type { FieldTypeRenderer, RenderInputArgs } from '../fieldRegistry'

const DEFAULT_MIN = 0
const DEFAULT_MAX = 100

const rangeStyles: CSSProperties = {
  width: '100%',
}

function SliderInput({
  fieldName,
  fieldDef,
  register,
  ariaDescribedBy,
  ariaErrorMessage,
  ariaRequired,
}: RenderInputArgs): React.ReactElement {
  const min = fieldDef.minimum ?? DEFAULT_MIN
  const max = fieldDef.maximum ?? DEFAULT_MAX
  const step = fieldDef.multipleOf ?? 1
  const [value, setValue] = useState<number>(min)

  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem' }}>
      <input
        id={fieldName}
        name={register.name}
        ref={register.ref}
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => {
          const n = Number(e.target.value)
          setValue(n)
          void register.onChange(e)
        }}
        onBlur={register.onBlur}
        aria-required={ariaRequired ? 'true' : undefined}
        aria-describedby={ariaDescribedBy}
        aria-invalid={ariaErrorMessage ? 'true' : undefined}
        aria-errormessage={ariaErrorMessage}
        style={rangeStyles}
      />
      <span aria-hidden="true" style={{ fontSize: '.85rem', minWidth: '2.5rem', textAlign: 'right' }}>
        {value}
      </span>
    </div>
  )
}

export const sliderRenderer: FieldTypeRenderer = {
  renderInput: (args) => <SliderInput {...args} />,
  requiredAriaAttributes: ['aria-required', 'aria-describedby', 'aria-invalid', 'aria-errormessage'],
}
