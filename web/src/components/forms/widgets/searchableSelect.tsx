/**
 * REQ-284 — `searchable-select` widget, EXTENDED by REQ-342 with a second,
 * network-backed combobox (`entityReferenceSelectRenderer`).
 *
 * `searchableSelectRenderer` (below, unchanged) is a client-side filtering
 * combobox over the field's OWN JSON-Schema `enum`. No network request,
 * ever — the option universe is exactly `fieldDef.enum`
 * (docs/frontend/x-ui-widget-vocabulary.md §1.3). Implements the WAI-ARIA
 * combobox pattern.
 *
 * REQ-342 CHECKED THIS FIRST, per its own instruction, before writing a
 * second implementation: this widget is task-form-shaped in a way that does
 * NOT generalize to an entity fk reference -- its option universe is
 * `fieldDef.enum`, a closed list embedded in the field definition itself,
 * with no network request "ever" (this file's own original comment, now
 * two paragraphs up). A foreign-key reference field's option universe is
 * the REFERENCED ENTITY TYPE'S OWN RECORDS, which do not exist anywhere in
 * `fieldDef` and can only be resolved via `POST /entities/query`
 * (`web/src/api/entities.ts`'s `entitiesApi.queryRecords` -- there is no
 * cheaper list route, see that file's own moduledoc). Forking a second file
 * would duplicate the combobox/listbox WAI-ARIA plumbing below for no
 * benefit; EXTENDING this file with a second exported renderer that reuses
 * the same style tokens and interaction pattern (arrow-key navigation,
 * `aria-activedescendant`, commit-on-Enter/click) is what "extend it rather
 * than forking it" means here -- the two renderers share no runtime state
 * or component, only this file and its styles.
 */

import { useEffect, useId, useMemo, useState, type CSSProperties } from 'react'
import { useIntl } from 'react-intl'
import { entitiesApi } from '@/api/entities'
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

// ── REQ-342: entity-fk-reference (network-backed) ──────────────────────────

/** Reduces a field's raw stored value to one preview string, for BOTH
 *  `:localized_text` label fields (an object keyed by locale -- e.g.
 *  `category.name`, `exam.title`) and plain `:string` label fields (e.g.
 *  `tag.name`) -- the "question.stem's plain-text preview" case this
 *  requirement's own description names. Prefers `preferredLocale`; falls
 *  back to the first non-empty locale value so a record missing the
 *  viewer's own locale still shows something rather than a blank option. */
function extractLabelPreview(value: unknown, preferredLocale: string): string {
  if (value == null) return ''
  if (typeof value === 'string') return value
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  if (typeof value === 'object') {
    const byLocale = value as Record<string, unknown>
    const preferred = byLocale[preferredLocale]
    if (typeof preferred === 'string' && preferred.trim() !== '') return preferred
    for (const candidate of Object.values(byLocale)) {
      if (typeof candidate === 'string' && candidate.trim() !== '') return candidate
    }
  }
  return ''
}

interface ReferenceOption {
  recordId: string
  label: string
}

function EntityReferenceSelectInput({
  fieldName,
  fieldDef,
  register,
  ariaDescribedBy,
  ariaErrorMessage,
  ariaRequired,
}: RenderInputArgs): React.ReactElement {
  const intl = useIntl()
  const listboxId = useId()
  const referencesEntity = fieldDef.referencesEntity

  const [labelField, setLabelField] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [open, setOpen] = useState(false)
  const [activeIndex, setActiveIndex] = useState(-1)
  const [options, setOptions] = useState<ReferenceOption[]>([])
  const [loading, setLoading] = useState(false)

  // Resolve which field of the REFERENCED entity is its human-readable
  // label: its own active definition's first `:localized_text` field, else
  // its first `:string` field, else none (falls back to showing the raw
  // record_id rather than guessing a name that does not exist). This is
  // deliberately dynamic, not a hard-coded per-entity-type map: the
  // referenced entity's OWN definition is the only source of truth for what
  // a "human-readable label" for one of its records looks like.
  useEffect(() => {
    if (!referencesEntity) {
      setLabelField(null)
      return
    }
    let cancelled = false
    entitiesApi
      .getActiveDefinition(referencesEntity)
      .then((definition) => {
        if (cancelled) return
        const fields = definition.definition.fields
        const preferred =
          fields.find((f) => f.type === 'localized_text') ?? fields.find((f) => f.type === 'string')
        setLabelField(preferred?.name ?? null)
      })
      .catch(() => {
        if (!cancelled) setLabelField(null)
      })
    return () => {
      cancelled = true
    }
  }, [referencesEntity])

  // Fetch matching records via the ONLY record-read route
  // (`POST /entities/query`, `web/src/api/entities.ts`) whenever the
  // referenced entity, its resolved label field, or the search term changes.
  useEffect(() => {
    if (!referencesEntity) return
    let cancelled = false
    setLoading(true)
    const filters = labelField && query.trim() !== '' ? [{ field: labelField, op: 'contains' as const, value: query.trim() }] : []
    entitiesApi
      .queryRecords(referencesEntity, { filters, page_size: 20 })
      .then((page) => {
        if (cancelled) return
        setOptions(
          page.items.map((item) => ({
            recordId: item.record_id,
            label:
              (labelField ? extractLabelPreview(item.field_values[labelField], intl.locale) : '') ||
              item.record_id,
          })),
        )
      })
      .catch(() => {
        if (!cancelled) setOptions([])
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [referencesEntity, labelField, query, intl.locale])

  const [selectedRecordId, setSelectedRecordId] = useState('')

  const commit = (option: ReferenceOption): void => {
    setQuery(option.label)
    setSelectedRecordId(option.recordId)
    setOpen(false)
    setActiveIndex(-1)
    void register.onChange({ target: { name: fieldName, value: option.recordId }, type: 'change' })
  }

  const activeDescendant =
    activeIndex >= 0 && activeIndex < options.length ? `${listboxId}-opt-${activeIndex}` : undefined

  return (
    <div style={{ position: 'relative' }}>
      <input type="hidden" name={register.name} ref={register.ref} value={selectedRecordId} readOnly />
      {/*
        This visible input is DELIBERATELY not registered with react-hook-form
        (no `ref`/`name` bound to it) -- it holds the SEARCH TEXT/resolved
        label, which is not the field's real value. Wiring `register.ref`/
        `register.onBlur` here caused a genuine bug during REQ-342's own
        test-writing: react-hook-form's `onBlur` handler re-reads whatever
        `event.target.value` is on the element it fires from, so a blur
        firing on this box (e.g. when focus moves to the form's submit
        button right after picking an option) silently overwrote the
        correctly-submitted `record_id` (set via the manual `register.onChange`
        call in `commit`, below) with the currently DISPLAYED label text.
        The hidden input further down is the ONLY element carrying
        `register.ref`/`register.name` -- it is what react-hook-form actually
        tracks as this field's value, and its own DOM value is never anything
        but the resolved `record_id`.
      */}
      <input
        id={fieldName}
        role="combobox"
        aria-expanded={open}
        aria-controls={listboxId}
        aria-activedescendant={activeDescendant}
        autoComplete="off"
        placeholder={intl.formatMessage({ id: 'entities.widgets.fkReference.searchPlaceholder' })}
        value={query}
        onChange={(e) => {
          setQuery(e.target.value)
          setOpen(true)
          setActiveIndex(-1)
        }}
        onFocus={() => setOpen(true)}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown') {
            e.preventDefault()
            setOpen(true)
            setActiveIndex((i) => Math.min(i + 1, options.length - 1))
          } else if (e.key === 'ArrowUp') {
            e.preventDefault()
            setActiveIndex((i) => Math.max(i - 1, 0))
          } else if (e.key === 'Enter' && activeIndex >= 0 && options[activeIndex]) {
            e.preventDefault()
            commit(options[activeIndex])
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
          {loading && options.length === 0 && (
            <li style={{ padding: '.4rem .6rem', color: 'var(--text-secondary)' }}>
              {intl.formatMessage({ id: 'entities.widgets.fkReference.loading' })}
            </li>
          )}
          {!loading && options.length === 0 && (
            <li style={{ padding: '.4rem .6rem', color: 'var(--text-secondary)' }}>
              {intl.formatMessage({ id: 'entities.widgets.fkReference.noResults' })}
            </li>
          )}
          {options.map((option, index) => (
            <li
              key={option.recordId}
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
              {option.label}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

export const entityReferenceSelectRenderer: FieldTypeRenderer = {
  renderInput: (args) => <EntityReferenceSelectInput {...args} />,
  requiredAriaAttributes: ['aria-required', 'aria-describedby', 'aria-invalid', 'aria-errormessage'],
}
