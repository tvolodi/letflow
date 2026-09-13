/** entitiesMessages — REQ-336
 *
 *  Message catalog for the generic admin-CRUD screen engine's pilot (the
 *  `tag` entity type). REQ-285 wired react-intl's date/time formatting and
 *  the session-locale concept, and explicitly deferred "shipping actual
 *  translations" to "a separate, later requirement" (see
 *  docs/frontend/frontend-requirements.md's Locale policy section) -- this
 *  is the first requirement to add a real, translated message catalog, so
 *  there is no existing convention to extend; this file establishes one for
 *  the entities screens this requirement and its REQ-340/REQ-342/REQ-343
 *  follow-ons add.
 *
 *  REQ-285's `PLATFORM_SUPPORTED_LOCALES` (web/src/i18n/sessionLocale.ts)
 *  governs `Intl.DateTimeFormat` locale support only and deliberately does
 *  NOT include "kk"/"ru" -- that set is a different concern (date/time
 *  formatting) from this one (UI string translation). `resolveUiLocale`
 *  below is this file's OWN, narrower resolver, over the three locales this
 *  catalog actually carries, and does not read or modify
 *  PLATFORM_SUPPORTED_LOCALES.
 *
 *  KNOWN GAP, recorded rather than silently worked around: with no browser
 *  ever reporting a bare "ru"/"kk" `navigator.language` filtered through
 *  PLATFORM_SUPPORTED_LOCALES (which the session-locale store does, for the
 *  unrelated date-formatting concern), `resolveUiLocale` here reads
 *  `navigator.languages` directly rather than going through
 *  `useSessionLocaleStore` -- so this catalog's kk/ru entries ARE reachable
 *  by an actual kk/ru browser locale, independent of REQ-285's
 *  date-formatting locale set. Flagged to ORCH per core-directives' "No
 *  Issue Left Local-Only": the two locale concepts (date formatting vs. UI
 *  string translation) are on different resolvers, which is a bit of drift
 *  worth reconciling once a second requirement adds a second catalog.
 */

export const ENTITIES_UI_LOCALES = ['en', 'ru', 'kk'] as const
export type EntitiesUiLocale = (typeof ENTITIES_UI_LOCALES)[number]

export const ENTITIES_UI_FALLBACK_LOCALE: EntitiesUiLocale = 'en'

function isEntitiesUiLocale(value: string): value is EntitiesUiLocale {
  return (ENTITIES_UI_LOCALES as readonly string[]).includes(value)
}

/** Resolves the locale this catalog's consumers render in: the first of
 *  `navigator.languages` (or `navigator.language`) whose base language tag
 *  (before any "-REGION" suffix) is one of ENTITIES_UI_LOCALES, else
 *  ENTITIES_UI_FALLBACK_LOCALE. Never throws; safe under SSR/test
 *  environments with no `navigator`. */
export function resolveUiLocale(candidates?: readonly string[]): EntitiesUiLocale {
  const sources =
    candidates ??
    (typeof navigator !== 'undefined'
      ? navigator.languages && navigator.languages.length > 0
        ? navigator.languages
        : navigator.language
          ? [navigator.language]
          : []
      : [])

  for (const raw of sources) {
    const base = raw.split('-')[0].toLowerCase()
    if (isEntitiesUiLocale(base)) return base
  }
  return ENTITIES_UI_FALLBACK_LOCALE
}

/** Message ids used by this requirement's tag list/create/edit/delete
 *  screens. Every id below has all three locales populated -- no id is
 *  English-only. */
export const entitiesMessages: Record<EntitiesUiLocale, Record<string, string>> = {
  en: {
    'entities.tag.list.title': 'Tags',
    'entities.tag.list.createAction': 'New tag',
    'entities.tag.list.emptyMessage': 'No tags found.',
    'entities.tag.list.column.name': 'Name',
    'entities.tag.list.column.actions': 'Actions',
    'entities.tag.field.name': 'Name',
    'entities.tag.list.editAction': 'Edit',
    'entities.tag.list.deleteAction': 'Delete',
    'entities.tag.list.loadError': 'Failed to load tags.',
    'entities.tag.form.createTitle': 'New tag',
    'entities.tag.form.editTitle': 'Edit tag',
    'entities.tag.form.submitCreate': 'Create',
    'entities.tag.form.submitUpdate': 'Save',
    'entities.tag.form.cancel': 'Cancel',
    'entities.tag.form.submitError': 'Could not save this tag.',
    'entities.tag.form.conflictError':
      'This tag was changed by someone else while you were editing. Reload and try again.',
    'entities.tag.delete.confirmTitle': 'Delete this tag?',
    'entities.tag.delete.confirmBody': 'This action cannot be undone.',
    'entities.tag.delete.confirmAction': 'Delete',
    'entities.tag.delete.cancelAction': 'Cancel',
    'entities.tag.delete.error': 'Failed to delete this tag.',
    'entities.pagination.previous': 'Previous',
    'entities.pagination.next': 'Next',
  },
  ru: {
    'entities.tag.list.title': 'Теги',
    'entities.tag.list.createAction': 'Новый тег',
    'entities.tag.list.emptyMessage': 'Теги не найдены.',
    'entities.tag.list.column.name': 'Название',
    'entities.tag.list.column.actions': 'Действия',
    'entities.tag.field.name': 'Название',
    'entities.tag.list.editAction': 'Изменить',
    'entities.tag.list.deleteAction': 'Удалить',
    'entities.tag.list.loadError': 'Не удалось загрузить теги.',
    'entities.tag.form.createTitle': 'Новый тег',
    'entities.tag.form.editTitle': 'Изменить тег',
    'entities.tag.form.submitCreate': 'Создать',
    'entities.tag.form.submitUpdate': 'Сохранить',
    'entities.tag.form.cancel': 'Отмена',
    'entities.tag.form.submitError': 'Не удалось сохранить этот тег.',
    'entities.tag.form.conflictError':
      'Этот тег был изменён кем-то другим, пока вы его редактировали. Обновите страницу и повторите попытку.',
    'entities.tag.delete.confirmTitle': 'Удалить этот тег?',
    'entities.tag.delete.confirmBody': 'Это действие нельзя отменить.',
    'entities.tag.delete.confirmAction': 'Удалить',
    'entities.tag.delete.cancelAction': 'Отмена',
    'entities.tag.delete.error': 'Не удалось удалить этот тег.',
    'entities.pagination.previous': 'Назад',
    'entities.pagination.next': 'Вперёд',
  },
  kk: {
    'entities.tag.list.title': 'Тегтер',
    'entities.tag.list.createAction': 'Жаңа тег',
    'entities.tag.list.emptyMessage': 'Тегтер табылмады.',
    'entities.tag.list.column.name': 'Атауы',
    'entities.tag.list.column.actions': 'Әрекеттер',
    'entities.tag.field.name': 'Атауы',
    'entities.tag.list.editAction': 'Өзгерту',
    'entities.tag.list.deleteAction': 'Жою',
    'entities.tag.list.loadError': 'Тегтерді жүктеу мүмкін болмады.',
    'entities.tag.form.createTitle': 'Жаңа тег',
    'entities.tag.form.editTitle': 'Тегті өзгерту',
    'entities.tag.form.submitCreate': 'Құру',
    'entities.tag.form.submitUpdate': 'Сақтау',
    'entities.tag.form.cancel': 'Бас тарту',
    'entities.tag.form.submitError': 'Бұл тегті сақтау мүмкін болмады.',
    'entities.tag.form.conflictError':
      'Сіз өңдеп жатқан кезде бұл тегті басқа біреу өзгертті. Бетті қайта жүктеп, әрекетті қайталаңыз.',
    'entities.tag.delete.confirmTitle': 'Бұл тегті жоясыз ба?',
    'entities.tag.delete.confirmBody': 'Бұл әрекетті болдырмау мүмкін емес.',
    'entities.tag.delete.confirmAction': 'Жою',
    'entities.tag.delete.cancelAction': 'Бас тарту',
    'entities.tag.delete.error': 'Бұл тегті жою мүмкін болмады.',
    'entities.pagination.previous': 'Артқа',
    'entities.pagination.next': 'Алға',
  },
}
