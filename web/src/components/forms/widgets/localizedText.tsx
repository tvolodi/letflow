/**
 * REQ-342 — `entity-localized-text` widget.
 *
 * CHECKED FIRST, per this requirement's own instruction ("CHECK
 * web/src/components/forms/widgets/ first for existing localized_text
 * support before adding a new registry entry"): `grep -ril localized
 * web/src/components/forms` before this file was added returned no hit --
 * `fieldRegistry.ts` had no `localized_text`/`localized-text` entry,
 * `FieldFactory.tsx`'s builtin switch has no `:localized_text`-aware branch,
 * and `entityFieldToFormField.ts` (REQ-336) explicitly degraded
 * `:localized_text` to a plain `'string'` field rather than crash, pending
 * "REQ-340/REQ-342 give it a real widget". This IS that widget -- a new
 * registry entry, not an extension of an existing one, because none existed.
 *
 * A per-locale stacked-field group (one plain text input per locale in
 * `fieldDef.locales`, defaulting to REQ-285's `["kk","ru","en"]` set when a
 * field carries none) editing ONE field value shaped as
 * `{"kk": "...", "ru": "...", "en": "..."}` -- `Letflow.Entities.Definition`'s
 * `:localized_text` wire shape (REQ-301) -- posted as the field's single
 * value via `register.onChange`, exactly as `searchableSelect.tsx`'s
 * client-only combobox already posts its own single resolved value instead
 * of relying on an uncontrolled native input.
 */

import { useId, useState, type CSSProperties } from 'react'
import { useIntl } from 'react-intl'
import type { FieldTypeRenderer, RenderInputArgs } from '../fieldRegistry'

export const DEFAULT_LOCALIZED_TEXT_LOCALES = ['kk', 'ru', 'en'] as const

const groupStyles: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '.6rem',
}

const localeRowStyles: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '.25rem',
}

const localeLabelStyles: CSSProperties = {
  fontSize: '.78rem',
  fontWeight: 500,
  color: 'var(--text-secondary)',
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

/** Locale-name message id, keyed by locale code. Falls back to a generic
 *  "other locale" message for any locale beyond REQ-285's kk/ru/en set, so
 *  an entity definition declaring a wider `locales` list never renders an
 *  untranslated raw code as if it were a label. */
function localeNameMessageId(locale: string): string {
  switch (locale) {
    case 'kk':
      return 'entities.widgets.localizedText.locale.kk'
    case 'ru':
      return 'entities.widgets.localizedText.locale.ru'
    case 'en':
      return 'entities.widgets.localizedText.locale.en'
    default:
      return 'entities.widgets.localizedText.locale.other'
  }
}

function LocalizedTextInput({
  fieldName,
  fieldDef,
  register,
  ariaDescribedBy,
  ariaErrorMessage,
  ariaRequired,
}: RenderInputArgs): React.ReactElement {
  const intl = useIntl()
  const groupId = useId()
  const locales =
    fieldDef.locales && fieldDef.locales.length > 0 ? fieldDef.locales : [...DEFAULT_LOCALIZED_TEXT_LOCALES]

  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(locales.map((locale) => [locale, ''])),
  )

  const commit = (locale: string, text: string): void => {
    const next = { ...values, [locale]: text }
    setValues(next)
    void register.onChange({ target: { name: fieldName, value: next }, type: 'change' })
  }

  return (
    <div
      role="group"
      aria-labelledby={groupId}
      aria-describedby={ariaDescribedBy}
      aria-invalid={ariaErrorMessage ? 'true' : undefined}
      aria-errormessage={ariaErrorMessage}
      style={groupStyles}
    >
      <span id={groupId} style={{ display: 'none' }}>
        {intl.formatMessage({ id: 'entities.widgets.localizedText.groupLabel' })}
      </span>
      {locales.map((locale) => {
        const inputId = `${fieldName}-${locale}`
        const localeLabel = intl.formatMessage({ id: localeNameMessageId(locale) })
        return (
          <div key={locale} style={localeRowStyles}>
            <label htmlFor={inputId} style={localeLabelStyles}>
              {localeLabel}
            </label>
            <input
              id={inputId}
              value={values[locale] ?? ''}
              onChange={(e) => commit(locale, e.target.value)}
              aria-required={ariaRequired ? 'true' : undefined}
              style={inputStyles}
            />
          </div>
        )
      })}
    </div>
  )
}

export const localizedTextRenderer: FieldTypeRenderer = {
  renderInput: (args) => <LocalizedTextInput {...args} />,
  requiredAriaAttributes: ['aria-required', 'aria-describedby', 'aria-invalid', 'aria-errormessage'],
}
