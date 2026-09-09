/** format — REQ-285
 *
 *  Locale-aware date/time formatting helpers, built on react-intl's imperative
 *  API (decision 0021: `docs/migration/decisions/0021-web-i18n-library.md`).
 *  Plain functions, not hooks -- callable uniformly from module-scope helper
 *  functions and from inside component bodies/JSX alike, which is why
 *  react-intl's `createIntl()` was chosen over a hook-only API (most of the
 *  call sites this module replaces are module-scope helpers, not JSX-inline
 *  expressions -- see the design doc §d).
 */

import { createIntl, createIntlCache, type IntlShape } from 'react-intl'
import { FALLBACK_LOCALE, getSessionLocale } from './sessionLocale'

const intlCache = createIntlCache()

let memoizedIntl: IntlShape | null = null
let memoizedLocale: string | null = null

/** Returns a memoized `IntlShape` for the current session locale. The session
 *  locale does not change after SPA bootstrap in this requirement's scope (see
 *  sessionLocale.ts), so this is effectively a session-lifetime singleton, not
 *  re-created per call -- but it re-derives if the session locale ever does
 *  change (e.g. under test, across resets), rather than caching once forever. */
export function getIntl(): IntlShape {
  const locale = getSessionLocale()
  if (memoizedIntl && memoizedLocale === locale) {
    return memoizedIntl
  }
  memoizedIntl = createIntl(
    {
      locale,
      defaultLocale: FALLBACK_LOCALE,
      // No translation catalogue exists yet -- REQ-285's scope is date/time
      // formatting only (see docs/frontend/frontend-requirements.md's Locale
      // policy section); none of this module's usage calls formatMessage.
      messages: {},
    },
    intlCache,
  )
  memoizedLocale = locale
  return memoizedIntl
}

/** Test-only: forces the next getIntl() call to rebuild rather than reuse the
 *  memoized shape. Needed because getSessionLocale() is read once and cached;
 *  tests that flip the session locale between assertions call this to avoid
 *  observing a stale cached IntlShape. */
export function _resetIntlCacheForTests(): void {
  memoizedIntl = null
  memoizedLocale = null
}

export function formatDate(
  value: Date | string | number,
  options?: Intl.DateTimeFormatOptions,
): string {
  return getIntl().formatDate(value, options)
}

export function formatTime(
  value: Date | string | number,
  options?: Intl.DateTimeFormatOptions,
): string {
  return getIntl().formatTime(value, options)
}

/** Combines date and time, locale-aware. react-intl's `IntlShape` has no
 *  single combined method the way `Date.prototype.toLocaleString()` does;
 *  this composes a single `formatDate` call carrying both date and time
 *  component options (decision left open by the design doc §d.2 -- either
 *  composition satisfies the behavioural contract). */
export function formatDateTime(
  value: Date | string | number,
  options?: Intl.DateTimeFormatOptions,
): string {
  return getIntl().formatDate(value, {
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
    hour: 'numeric',
    minute: 'numeric',
    second: 'numeric',
    ...options,
  })
}
