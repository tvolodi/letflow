/**
 * Unit tests — REQ-285: session-locale fallback chain (AC3, AC6)
 *
 * AC3 requires at least 3 cases: a supported locale, an unsupported locale
 * falling back, and no locale preference at all. AC6 requires a case where a
 * tenant default wins over browser preference, and a case where browser
 * preference is used when no tenant default is supplied. This file covers
 * all 5 cases the design doc lists in §b.
 */

import { describe, it, expect, beforeEach } from 'vitest'
import {
  resolveSessionLocale,
  useSessionLocaleStore,
  getSessionLocale,
  PLATFORM_SUPPORTED_LOCALES,
  FALLBACK_LOCALE,
} from '@/i18n/sessionLocale'

describe('REQ-285 — PLATFORM_SUPPORTED_LOCALES / FALLBACK_LOCALE invariants', () => {
  it('FALLBACK_LOCALE is a member of PLATFORM_SUPPORTED_LOCALES', () => {
    expect(PLATFORM_SUPPORTED_LOCALES).toContain(FALLBACK_LOCALE)
  })

  it('FALLBACK_LOCALE is "en", not "en-US" (AC5 -- the terminal fallback must not reintroduce the removed US-region bias)', () => {
    expect(FALLBACK_LOCALE).toBe('en')
  })
})

describe('REQ-285 AC3 — resolveSessionLocale fallback chain (at least 3 cases)', () => {
  it('TC-1: supported locale case -- browser preference ["es-ES", "en"], no tenant default -> "es-ES"', () => {
    expect(
      resolveSessionLocale({ tenantDefaultLocale: null, browserLocales: ['es-ES', 'en'] }),
    ).toBe('es-ES')
  })

  it('TC-2: unsupported locale falling back -- browser preference ["xx-XX", "ja"], no tenant default -> FALLBACK_LOCALE', () => {
    expect(
      resolveSessionLocale({ tenantDefaultLocale: null, browserLocales: ['xx-XX', 'ja'] }),
    ).toBe(FALLBACK_LOCALE)
  })

  it('TC-3: no locale preference at all -- empty browser locales, no tenant default -> FALLBACK_LOCALE', () => {
    expect(resolveSessionLocale({ tenantDefaultLocale: null, browserLocales: [] })).toBe(
      FALLBACK_LOCALE,
    )
  })
})

describe('REQ-285 AC6 — tenant default vs. browser preference precedence', () => {
  it('TC-4: tenant default wins over browser preference when supplied -- tenant "fr-FR", browser ["de-DE"] -> "fr-FR"', () => {
    expect(
      resolveSessionLocale({ tenantDefaultLocale: 'fr-FR', browserLocales: ['de-DE'] }),
    ).toBe('fr-FR')
  })

  it('TC-5: browser preference is used when no tenant default is supplied -- tenant null, browser ["de-DE"] -> "de-DE"', () => {
    expect(
      resolveSessionLocale({ tenantDefaultLocale: null, browserLocales: ['de-DE'] }),
    ).toBe('de-DE')
  })

  it('an unsupported tenant default does not win -- falls through to browser preference', () => {
    expect(
      resolveSessionLocale({ tenantDefaultLocale: 'xx-XX', browserLocales: ['de-DE'] }),
    ).toBe('de-DE')
  })
})

describe('REQ-285 — useSessionLocaleStore / getSessionLocale (session-locale concept)', () => {
  beforeEach(() => {
    useSessionLocaleStore.setState({ locale: resolveSessionLocale() })
  })

  it('getSessionLocale reads the store state via getState(), not the hook', () => {
    expect(getSessionLocale()).toBe(useSessionLocaleStore.getState().locale)
  })

  it('setTenantDefaultLocale re-resolves and updates locale (tested via a supplied tenant default -- AC6)', () => {
    useSessionLocaleStore.getState().setTenantDefaultLocale('pt-BR')
    expect(useSessionLocaleStore.getState().locale).toBe('pt-BR')
    expect(getSessionLocale()).toBe('pt-BR')
  })

  it('setTenantDefaultLocale(null) falls back to browser/terminal resolution', () => {
    useSessionLocaleStore.getState().setTenantDefaultLocale('pt-BR')
    useSessionLocaleStore.getState().setTenantDefaultLocale(null)
    expect(PLATFORM_SUPPORTED_LOCALES).toContain(useSessionLocaleStore.getState().locale)
  })

  it('locale is always a member of PLATFORM_SUPPORTED_LOCALES (invariant)', () => {
    expect(PLATFORM_SUPPORTED_LOCALES).toContain(useSessionLocaleStore.getState().locale)
  })
})
