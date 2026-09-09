/**
 * REQ-284 — `rich-text-lite` widget.
 *
 * A toolbar-based lite editor over a plain string. Each toolbar button
 * inserts/removes a constrained markdown-lite token pair around the current
 * selection (or at the cursor). The field's value is ALWAYS the plain
 * string containing those literal tokens — this widget never parses or
 * renders the tokens as HTML/markup, and never will
 * (docs/frontend/x-ui-widget-vocabulary.md §1.1). This widget never assigns
 * raw markup to the DOM and never will.
 */

import { useRef, useState, type CSSProperties } from 'react'
import type { FieldTypeRenderer, RenderInputArgs } from '../fieldRegistry'

interface TokenSpec {
  label: string
  prefix: string
  suffix: string
  /** True for a line-prefix token (bullet list) instead of a wrap-pair. */
  linePrefix?: boolean
}

const TOKENS: TokenSpec[] = [
  { label: 'Bold', prefix: '**', suffix: '**' },
  { label: 'Italic', prefix: '*', suffix: '*' },
  { label: 'Bullet list', prefix: '- ', suffix: '', linePrefix: true },
]

const commonStyles: CSSProperties = {
  width: '100%',
  padding: '.5rem .75rem',
  border: '1px solid var(--color-neutral-400)',
  borderRadius: '4px',
  fontSize: '.9rem',
  fontFamily: 'inherit',
  boxSizing: 'border-box',
  resize: 'vertical',
}

function isTokenActiveAtSelection(value: string, start: number, end: number, token: TokenSpec): boolean {
  if (token.linePrefix) {
    const lineStart = value.lastIndexOf('\n', Math.max(0, start - 1)) + 1
    return value.slice(lineStart, lineStart + token.prefix.length) === token.prefix
  }
  const before = value.slice(Math.max(0, start - token.prefix.length), start)
  const after = value.slice(end, end + token.suffix.length)
  return before === token.prefix && after === token.suffix
}

function RichTextLiteInput({
  fieldName,
  register,
  ariaDescribedBy,
  ariaErrorMessage,
  ariaRequired,
}: RenderInputArgs): React.ReactElement {
  const elementRef = useRef<HTMLTextAreaElement | null>(null)
  const [value, setValue] = useState('')
  const [, forceRerender] = useState(0)

  const setRefs = (node: HTMLTextAreaElement | null): void => {
    elementRef.current = node
    register.ref(node)
  }

  const applyToken = (token: TokenSpec): void => {
    const el = elementRef.current
    if (!el) return
    const start = el.selectionStart ?? 0
    const end = el.selectionEnd ?? 0
    const current = el.value
    const active = isTokenActiveAtSelection(current, start, end, token)
    let next: string
    let caret: number

    if (token.linePrefix) {
      const lineStart = current.lastIndexOf('\n', Math.max(0, start - 1)) + 1
      if (active) {
        next = current.slice(0, lineStart) + current.slice(lineStart + token.prefix.length)
        caret = Math.max(lineStart, start - token.prefix.length)
      } else {
        next = current.slice(0, lineStart) + token.prefix + current.slice(lineStart)
        caret = start + token.prefix.length
      }
    } else if (active) {
      next =
        current.slice(0, start - token.prefix.length) +
        current.slice(start, end) +
        current.slice(end + token.suffix.length)
      caret = end - token.prefix.length
    } else {
      next =
        current.slice(0, start) + token.prefix + current.slice(start, end) + token.suffix + current.slice(end)
      caret = end + token.prefix.length
    }

    el.value = next
    el.focus()
    el.setSelectionRange(caret, caret)
    setValue(next)
    void register.onChange({ target: { name: fieldName, value: next }, type: 'change' })
    forceRerender((n) => n + 1)
  }

  const selection = {
    start: elementRef.current?.selectionStart ?? 0,
    end: elementRef.current?.selectionEnd ?? 0,
  }

  return (
    <div>
      <div role="toolbar" aria-label="Formatting" style={{ display: 'flex', gap: '.25rem', marginBottom: '.25rem' }}>
        {TOKENS.map((token) => {
          const pressed = isTokenActiveAtSelection(value, selection.start, selection.end, token)
          return (
            <button
              key={token.label}
              type="button"
              aria-label={token.label}
              aria-pressed={pressed}
              onClick={() => applyToken(token)}
              style={{
                padding: '.25rem .5rem',
                border: '1px solid var(--color-neutral-400)',
                borderRadius: '4px',
                background: pressed ? 'var(--color-neutral-200)' : 'transparent',
                cursor: 'pointer',
                fontSize: '.8rem',
              }}
            >
              {token.label}
            </button>
          )
        })}
      </div>
      <textarea
        id={fieldName}
        name={register.name}
        ref={setRefs}
        onChange={(e) => {
          setValue(e.target.value)
          void register.onChange(e)
        }}
        onBlur={register.onBlur}
        onSelect={() => forceRerender((n) => n + 1)}
        rows={4}
        aria-required={ariaRequired ? 'true' : undefined}
        aria-describedby={ariaDescribedBy}
        aria-invalid={ariaErrorMessage ? 'true' : undefined}
        aria-errormessage={ariaErrorMessage}
        style={commonStyles}
      />
    </div>
  )
}

export const richTextLiteRenderer: FieldTypeRenderer = {
  renderInput: (args) => <RichTextLiteInput {...args} />,
  requiredAriaAttributes: ['aria-required', 'aria-describedby', 'aria-invalid', 'aria-errormessage'],
}
