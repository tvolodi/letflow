/**
 * REQ-438 -- (1) every user-facing string on the email-first login page comes
 * from the i18n catalogue in every shipped locale (decision 0021; modelled on
 * entities-i18n-grep.test.ts), and (2) nothing in the SPA's login code knows a
 * server-side disclosure mode (BA decision D-A): the page is driven only by the
 * closed discovery response union.
 *
 * The scanners are plain functions so the test can prove they FAIL on a seeded
 * violating fixture, not just pass on the real files.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { ENTITIES_UI_LOCALES } from '@/i18n/entitiesMessages'
import { loginMessages } from '@/i18n/loginMessages'

const SRC_ROOT = path.resolve(__dirname, '..')

const JSX_FILES_TO_CHECK = ['pages/LoginPage.tsx', 'i18n/LoginIntlProvider.tsx']

/** Literal text sitting directly between two tags, on one line or several
 *  (leading/trailing whitespace including newlines is allowed). Requires the
 *  text to start right after a `>` that is not part of `=>` or `->`. */
const JSX_TEXT_NODE = /(?<![=-])>\s*[A-Za-z][A-Za-z '.,\s-]{2,}?\s*</g
/** A user-visible attribute given a literal string rather than a message. */
const LITERAL_ATTRIBUTE = /\s(?:placeholder|aria-label|title|alt)="[^"{]+"/g
/** A bare string literal passed straight to a visible-text sink. */
const LITERAL_FORMAT_ARG = /formatMessage\(\s*['"`]/g

/** Returns every hard-coded user-facing string hit found in `source`. */
export function findHardcodedStrings(source: string): string[] {
  return [
    ...(source.match(JSX_TEXT_NODE) ?? []),
    ...(source.match(LITERAL_ATTRIBUTE) ?? []),
    ...(source.match(LITERAL_FORMAT_ARG) ?? []),
  ]
}

/** The server-side disclosure vocabulary the SPA must never reference. */
const DISCLOSURE_VOCABULARY = /redirect_single|uniform|disclos|tenant[_-]?mode|login[_-]?mode|deployment[_-]?mode/i

const LOGIN_SOURCE_FILES = [
  'pages/LoginPage.tsx',
  'api/loginDiscovery.ts',
  'i18n/loginMessages.ts',
  'i18n/LoginIntlProvider.tsx',
  'auth/emailFirstFlag.ts',
  'auth/ProtectedRoute.tsx',
  'auth/AuthProvider.tsx',
  'auth/oidcRedirectArgs.ts',
]

function read(rel: string): string {
  return readFileSync(path.join(SRC_ROOT, rel), 'utf-8')
}

describe('REQ-438 -- no hard-coded string on the login page', () => {
  for (const rel of JSX_FILES_TO_CHECK) {
    it(`${rel} has no hard-coded user-facing string`, () => {
      expect(findHardcodedStrings(read(rel))).toEqual([])
    })
  }

  it('the scanner FAILS on a seeded hard-coded string fixture', () => {
    const seeded = [
      '<p>Welcome back friend</p>',
      '<input placeholder="Type your email" />',
      "intl.formatMessage('raw string')",
    ].join('\n')
    expect(findHardcodedStrings(seeded).length).toBeGreaterThanOrEqual(3)
    expect(findHardcodedStrings('<p>\n  Welcome back friend\n</p>').length).toBeGreaterThanOrEqual(1)
    expect(findHardcodedStrings('<button>\n  Sign in\n  now please\n</button>').length).toBeGreaterThanOrEqual(1)
    expect(findHardcodedStrings('<p>{intl.formatMessage({ id: "login.title" })}</p>')).toEqual([])
  })

  it('loginMessages carries en, ru and kk for every id, none missing a locale or empty', () => {
    const [first, ...rest] = ENTITIES_UI_LOCALES.map((l) => Object.keys(loginMessages[l]).sort())
    expect(first.length).toBeGreaterThan(0)
    for (const other of rest) expect(other).toEqual(first)
    for (const locale of ENTITIES_UI_LOCALES) {
      for (const [id, text] of Object.entries(loginMessages[locale])) {
        expect(text.trim(), `${locale}:${id}`).not.toBe('')
      }
    }
  })

  it('every message id the page uses exists in the catalogue', () => {
    const used = new Set(
      [...read('pages/LoginPage.tsx').matchAll(/['"](login\.[a-zA-Z.]+)['"]/g)].map((m) => m[1]),
    )
    expect(used.size).toBeGreaterThan(0)
    for (const id of used) expect(loginMessages.en, id).toHaveProperty(id)
  })
})

describe('REQ-438 -- no disclosure-mode knowledge in the SPA login code', () => {
  for (const rel of LOGIN_SOURCE_FILES) {
    it(`${rel} does not reference a disclosure mode`, () => {
      expect(read(rel)).not.toMatch(DISCLOSURE_VOCABULARY)
    })
  }

  it('the detector flags the forbidden vocabulary', () => {
    for (const word of ['redirect_single', 'uniform_plus_email', 'disclosure_mode', 'tenant_mode']) {
      expect(word).toMatch(DISCLOSURE_VOCABULARY)
    }
  })
})
