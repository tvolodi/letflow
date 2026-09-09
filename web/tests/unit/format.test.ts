/**
 * Unit tests — REQ-285: locale-aware date/time formatting helpers
 * (`web/src/i18n/format.ts`), built on react-intl's imperative `createIntl()`
 * API per decision 0021.
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { formatDate, formatTime, formatDateTime, _resetIntlCacheForTests } from '@/i18n/format'
import { useSessionLocaleStore, resolveSessionLocale } from '@/i18n/sessionLocale'

function setLocale(locale: string) {
  useSessionLocaleStore.setState({ locale: locale as never })
  _resetIntlCacheForTests()
}

describe('REQ-285 — formatDate/formatTime/formatDateTime', () => {
  beforeEach(() => {
    useSessionLocaleStore.setState({ locale: resolveSessionLocale({ browserLocales: [] }) })
    _resetIntlCacheForTests()
  })

  const sample = new Date(Date.UTC(2026, 0, 15, 13, 30, 0)) // 2026-01-15T13:30:00Z

  it('formatDate renders a locale-aware date string (en)', () => {
    setLocale('en')
    const result = formatDate(sample)
    expect(typeof result).toBe('string')
    expect(result.length).toBeGreaterThan(0)
  })

  it('formatTime renders a locale-aware time string (en)', () => {
    setLocale('en')
    const result = formatTime(sample)
    expect(typeof result).toBe('string')
    expect(result.length).toBeGreaterThan(0)
  })

  it('formatDateTime renders both date and time components', () => {
    setLocale('en')
    const dateOnly = formatDate(sample)
    const timeOnly = formatTime(sample)
    const combined = formatDateTime(sample)
    // The combined output should carry more information than either alone --
    // concretely, it is not identical to just the date or just the time.
    expect(combined).not.toBe(dateOnly)
    expect(combined).not.toBe(timeOnly)
  })

  it('formatting is driven by the session locale -- different locales can format differently', () => {
    setLocale('en-US')
    const us = formatDate(sample)
    setLocale('fr-FR')
    const fr = formatDate(sample)
    // en-US and fr-FR use different date component orders/separators for the
    // same instant; this is what "locale-aware" means concretely.
    expect(us).not.toBe(fr)
  })

  it('accepts string and numeric timestamp inputs, not just Date objects', () => {
    setLocale('en')
    const iso = '2026-01-15T13:30:00.000Z'
    expect(() => formatDate(iso)).not.toThrow()
    expect(() => formatDateTime(sample.getTime())).not.toThrow()
  })

  it('no call in this module ever hardcodes a locale (AC5) -- formatting follows getSessionLocale()', () => {
    setLocale('es-ES')
    const es = formatDate(sample)
    setLocale('de-DE')
    const de = formatDate(sample)
    expect(es).not.toBe(de)
  })
})
