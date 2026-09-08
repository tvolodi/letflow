/** JsonEditor — design-system primitive (REQ-275, docs/frontend/design-system.md §7.5)
 *
 *  Fully controlled textarea with JSON syntax validation and pretty-print-on-blur.
 *  Empty string is treated as valid (nothing entered yet, not malformed input).
 *  All colors/spacing/typography are sourced from web/src/styles/tokens.css custom
 *  properties — no hex/rgb/hsl literal appears in this file.
 */

import React from 'react'

export interface JsonEditorProps {
  value: string
  onChange: (value: string, isValid: boolean) => void
  label: string
  height?: number
  readOnly?: boolean
}

function isValidJson(value: string): boolean {
  if (value === '') {
    return true
  }
  try {
    JSON.parse(value)
    return true
  } catch {
    return false
  }
}

export function JsonEditor(props: JsonEditorProps): React.ReactElement {
  const { value, onChange, label, height = 200, readOnly = false } = props

  const isValid = isValidJson(value)

  const handleChange = (event: React.ChangeEvent<HTMLTextAreaElement>): void => {
    const nextValue = event.target.value
    onChange(nextValue, isValidJson(nextValue))
  }

  const handleBlur = (): void => {
    if (!isValid || value === '') {
      return
    }
    const pretty = JSON.stringify(JSON.parse(value), null, 2)
    if (pretty !== value) {
      onChange(pretty, true)
    }
  }

  return (
    <div data-testid="json-editor">
      <label
        data-testid="json-editor-label"
        style={{
          color: 'var(--text-primary)',
          fontSize: 'var(--text-sm)',
          display: 'block',
          marginBottom: 'var(--space-1)',
        }}
      >
        {label}
      </label>
      <textarea
        data-testid="json-editor-textarea"
        value={value}
        readOnly={readOnly}
        onChange={handleChange}
        onBlur={handleBlur}
        style={{
          width: '100%',
          height: `${height}px`,
          fontFamily: 'var(--font-mono)',
          fontSize: 'var(--text-sm)',
          color: readOnly ? 'var(--text-disabled)' : 'var(--text-primary)',
          border: `1px solid ${isValid ? 'var(--border-default)' : 'var(--border-error)'}`,
          borderRadius: 'var(--radius-sm)',
          padding: 'var(--space-2)',
        }}
      />
      {!isValid && (
        <p
          data-testid="json-editor-error"
          style={{ color: 'var(--color-error-dark)', fontSize: 'var(--text-sm)', margin: 'var(--space-1) 0 0' }}
        >
          Invalid JSON
        </p>
      )}
    </div>
  )
}
