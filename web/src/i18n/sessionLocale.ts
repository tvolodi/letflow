/** sessionLocale — REQ-285
 *
 *  The session-locale concept: a single resolved locale string, computed once
 *  per SPA session, held in a Zustand store (`useSessionLocaleStore`, the same
 *  pattern `stores/definitionDraftStore.ts` establishes). See
 *  `lib/letflow/design/req285-i18n-layer-adoption.md` §b/§c for the fallback
 *  chain design this module implements.
 *
 *  Fallback chain precedence:
 *    1. Tenant `default_locale` (when supplied) — wins if it's a member of
 *       PLATFORM_SUPPORTED_LOCALES.
 *    2. Browser preference (`navigator.languages`, or `navigator.language` if
 *       unavailable) — first entry that is a member of PLATFORM_SUPPORTED_LOCALES.
 *    3. FALLBACK_LOCALE ("en") — used when neither of the above yields a member.
 *
 *  KNOWN GAP (design doc §c, not resolved here): no requirement currently wires
 *  a tenant's real `default_locale` to this SPA (`GET /api/tenant-config`,
 *  REQ-281, deliberately excludes locale data). `setTenantDefaultLocale` exists
 *  and is fully testable today via an injected value, but no production call
 *  site invokes it with a non-null argument — the app runs on tiers 2-3 of the
 *  chain in production until a future requirement wires tier 1.
 */

import { create } from 'zustand'

/** The finite, curated set of BCP-47 tags this SPA's date/time formatting
 *  supports. Decoupled from UI string translation (which stays English-only
 *  per REQ-285's scope fence — see docs/frontend/frontend-requirements.md's
 *  Locale policy section). Chosen to cover the language families implied by
 *  `Letflow.Identity.Tenant`'s `@locale_regex` without enumerating every
 *  shape-valid string that regex would accept. */
export const PLATFORM_SUPPORTED_LOCALES = [
  'en',
  'en-US',
  'en-GB',
  'es',
  'es-ES',
  'fr',
  'fr-FR',
  'de',
  'de-DE',
  'pt-BR',
] as const

export type PlatformSupportedLocale = (typeof PLATFORM_SUPPORTED_LOCALES)[number]

/** Terminal fallback. MUST be a member of PLATFORM_SUPPORTED_LOCALES (invariant
 *  maintained by construction below). Deliberately "en", not "en-US" -- the
 *  latter was the defect this requirement removes (AC5). */
export const FALLBACK_LOCALE: PlatformSupportedLocale = 'en'

function isSupportedLocale(value: string | null | undefined): value is PlatformSupportedLocale {
  return (
    value != null &&
    (PLATFORM_SUPPORTED_LOCALES as readonly string[]).includes(value)
  )
}

function readBrowserLocales(): readonly string[] {
  if (typeof navigator === 'undefined') return []
  if (Array.isArray(navigator.languages) && navigator.languages.length > 0) {
    return navigator.languages
  }
  if (typeof navigator.language === 'string' && navigator.language.length > 0) {
    return [navigator.language]
  }
  return []
}

export interface ResolveSessionLocaleInput {
  tenantDefaultLocale?: string | null
  browserLocales?: readonly string[]
}

/** Pure resolver, exported separately so it is unit-testable without a
 *  Zustand/React harness. Never fails -- every input either resolves to a
 *  member of PLATFORM_SUPPORTED_LOCALES or falls through to FALLBACK_LOCALE. */
export function resolveSessionLocale(input: ResolveSessionLocaleInput = {}): PlatformSupportedLocale {
  const { tenantDefaultLocale = null } = input
  const browserLocales = input.browserLocales ?? readBrowserLocales()

  if (isSupportedLocale(tenantDefaultLocale)) {
    return tenantDefaultLocale
  }

  for (const candidate of browserLocales) {
    if (isSupportedLocale(candidate)) {
      return candidate
    }
  }

  return FALLBACK_LOCALE
}

interface SessionLocaleStore {
  locale: PlatformSupportedLocale
  setTenantDefaultLocale: (tenantDefaultLocale: string | null) => void
}

export const useSessionLocaleStore = create<SessionLocaleStore>((set) => ({
  locale: resolveSessionLocale(),
  setTenantDefaultLocale: (tenantDefaultLocale) => {
    // Re-run resolution with the new tenant default, keeping whatever browser
    // preference was captured at store creation (no reactivity to a mid-session
    // navigator.languages change is required by any REQ-285 acceptance criterion).
    set({ locale: resolveSessionLocale({ tenantDefaultLocale }) })
  },
}))

/** Non-hook accessor for use from plain module-scope functions (most of the
 *  `.toLocale*()` call sites this requirement converts are module-scope
 *  helpers, not JSX-inline expressions -- see the design doc §d). */
export function getSessionLocale(): PlatformSupportedLocale {
  return useSessionLocaleStore.getState().locale
}
