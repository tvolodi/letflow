/**
 * REQ-284 — `masked-input` widget.
 *
 * A single-line text input that formats keystrokes against ONE mask, named
 * by the closed `x-ui.mask` enum (`'phone-us' | 'postal-us' | 'currency-usd'`).
 * The mask is a platform-chosen format — never a tenant-supplied pattern or
 * regex (docs/frontend/x-ui-widget-vocabulary.md §1.2). Formatting only
 * inserts/removes literal separator characters; the submitted value is
 * always the plain formatted string.
 */

import type { CSSProperties } from 'react'
import type { FieldTypeRenderer, RenderInputArgs } from '../fieldRegistry'
import { joinHintIds } from '../ariaHints'
import type { TaskFormField } from '@/types/forms'

export type MaskName = 'phone-us' | 'postal-us' | 'currency-usd'

const MASK_HINTS: Record<MaskName, { format: string; inputMode: 'tel' | 'numeric' }> = {
  'phone-us': { format: 'Format: (555) 555-5555', inputMode: 'tel' },
  'postal-us': { format: 'Format: 12345 or 12345-6789', inputMode: 'numeric' },
  'currency-usd': { format: 'Format: $1,234.56', inputMode: 'numeric' },
}

function formatPhoneUs(digits: string): string {
  const d = digits.slice(0, 10)
  if (d.length <= 3) return d
  if (d.length <= 6) return `(${d.slice(0, 3)}) ${d.slice(3)}`
  return `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}`
}

function formatPostalUs(digits: string): string {
  const d = digits.slice(0, 9)
  if (d.length <= 5) return d
  return `${d.slice(0, 5)}-${d.slice(5)}`
}

function formatCurrencyUsd(digits: string): string {
  const d = digits.replace(/^0+(?=\d)/, '') || '0'
  const cents = d.slice(-2).padStart(2, '0')
  const wholeRaw = d.length > 2 ? d.slice(0, -2) : '0'
  const whole = wholeRaw.replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  return `$${whole}.${cents}`
}

function applyMask(mask: MaskName, rawValue: string): string {
  const digits = rawValue.replace(/\D/g, '')
  switch (mask) {
    case 'phone-us':
      return formatPhoneUs(digits)
    case 'postal-us':
      return formatPostalUs(digits)
    case 'currency-usd':
      return formatCurrencyUsd(digits)
    default:
      return rawValue
  }
}

const inputStyles: CSSProperties = {
  width: '100%',
  padding: '.5rem .75rem',
  border: '1px solid var(--color-neutral-400)',
  borderRadius: '4px',
  fontSize: '.9rem',
  fontFamily: 'inherit',
  boxSizing: 'border-box',
}

function resolveMask(fieldDef: TaskFormField): MaskName {
  const raw = fieldDef.xUiMask
  if (raw === 'phone-us' || raw === 'postal-us' || raw === 'currency-usd') return raw
  return 'phone-us'
}

export const maskedInputRenderer: FieldTypeRenderer = {
  renderInput: ({ fieldName, fieldDef, register, ariaDescribedBy, ariaErrorMessage, ariaRequired }: RenderInputArgs) => {
    const mask = resolveMask(fieldDef)
    const { format, inputMode } = MASK_HINTS[mask]
    const maskHintId = `${fieldName}-mask-hint`
    const describedBy = joinHintIds([ariaDescribedBy ?? null, maskHintId])

    return (
      <div>
        <input
          id={fieldName}
          name={register.name}
          ref={register.ref}
          inputMode={inputMode}
          onChange={(e) => {
            const formatted = applyMask(mask, e.target.value)
            e.target.value = formatted
            void register.onChange(e)
          }}
          onBlur={register.onBlur}
          aria-required={ariaRequired ? 'true' : undefined}
          aria-describedby={describedBy}
          aria-invalid={ariaErrorMessage ? 'true' : undefined}
          aria-errormessage={ariaErrorMessage}
          style={inputStyles}
        />
        <p id={maskHintId} style={{ margin: '.25rem 0 0 0', fontSize: '.8rem', color: 'var(--text-secondary)' }}>
          {format}
        </p>
      </div>
    )
  },
  requiredAriaAttributes: ['aria-required', 'aria-describedby', 'aria-invalid', 'aria-errormessage'],
}
