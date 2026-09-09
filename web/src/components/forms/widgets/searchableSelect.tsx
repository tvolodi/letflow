/**
 * REQ-284 — `searchable-select` widget.
 *
 * A client-side filtering combobox over the field's OWN JSON-Schema `enum`.
 * No network request, ever — the option universe is exactly `fieldDef.enum`
 * (docs/frontend/x-ui-widget-vocabulary.md §1.3). Implements the WAI-ARIA
 * combobox pattern.
 */

import { useId, useMemo, useState, type CSSProperties } from 'react'
import type { FieldTypeRenderer, RenderInputArgs } from '../fieldRegistry'

const inputStyles: CSSProperties = {
  width: '100%',
  padding: '.5rem .75rem',
  border: '1px solid var(--color-neutral-400)',
  borderRadius: '4px',
  fontSize: '.9rem',
  fontFamily: 'inherit',
  boxSizing: 'border-box',
}

const listboxStyles: CSSProperties = {
  listStyle: 'none',
  margin: '.25rem 0 0 0',
  padding: 0,
  border: '1px solid var(--color-neutral-400)',
  borderRadius: '4px',
  maxHeight: '12rem',
  overflowY: 'auto',
}

function SearchableSelectInput({
  fieldName,
  fieldDef,
  register,
  ariaDescribedBy,
  ariaErrorMessage,
  ariaRequired,
}: RenderInputArgs): React.ReactElement {
  const options = useMemo(
    () => (fieldDef.enum ?? []).map((o) => String(o)),
    [fieldDef.enum],
  )
  const listboxId = useId()
  const [query, setQuery] = useState('')
  const [open, setOpen] = useState(false)
  const [activeIndex, setActiveIndex] = useState(-1)

  const filtered = query.trim() === '' ? options : options.filter((o) => o.toLowerCase().includes(query.toLowerCase()))

  const commit = (option: string): void => {
    setQuery(option)
    setOpen(false)
    setActiveIndex(-1)
    void register.onChange({ target: { name: fieldName, value: option }, type: 'change' })
  }

  const activeDescendant = activeIndex >= 0 && activeIndex < filtered.length ? `${listboxId}-opt-${activeIndex}` : undefined

  return (
    <div style={{ position: 'relative' }}>
      <input
        id={fieldName}
        name={register.name}
        ref={register.ref}
        role="combobox"
        aria-expanded={open}
        aria-controls={listboxId}
        aria-activedescendant={activeDescendant}
        autoComplete="off"
        value={query}
        onChange={(e) => {
          setQuery(e.target.value)
          setOpen(true)
          setActiveIndex(-1)
          void register.onChange(e)
        }}
        onBlur={register.onBlur}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown') {
            e.preventDefault()
            setOpen(true)
            setActiveIndex((i) => Math.min(i + 1, filtered.length - 1))
          } else if (e.key === 'ArrowUp') {
            e.preventDefault()
            setActiveIndex((i) => Math.max(i - 1, 0))
          } else if (e.key === 'Enter' && activeIndex >= 0 && filtered[activeIndex]) {
            e.preventDefault()
            commit(filtered[activeIndex])
          } else if (e.key === 'Escape') {
            setOpen(false)
          }
        }}
        aria-required={ariaRequired ? 'true' : undefined}
        aria-describedby={ariaDescribedBy}
        aria-invalid={ariaErrorMessage ? 'true' : undefined}
        aria-errormessage={ariaErrorMessage}
        style={inputStyles}
      />
      {open && (
        <ul role="listbox" id={listboxId} style={listboxStyles}>
          {filtered.map((option, index) => (
            <li
              key={option}
              id={`${listboxId}-opt-${index}`}
              role="option"
              aria-selected={index === activeIndex}
              onMouseDown={(e) => {
                e.preventDefault()
                commit(option)
              }}
              style={{
                padding: '.4rem .6rem',
                cursor: 'pointer',
                background: index === activeIndex ? 'var(--color-neutral-200)' : 'transparent',
              }}
            >
              {option}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

export const searchableSelectRenderer: FieldTypeRenderer = {
  renderInput: (args) => <SearchableSelectInput {...args} />,
  requiredAriaAttributes: ['aria-required', 'aria-describedby', 'aria-invalid', 'aria-errormessage'],
}
