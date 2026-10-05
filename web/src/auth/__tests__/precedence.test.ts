// @vitest-environment jsdom
/**
 * REQ-438 (design req434 section 11.2) -- resolveRealmFromUrl precedence at the
 * unit level: an explicit ?realm= wins and overwrites the stored value; with
 * only one present the behaviour is unchanged; buildRedirectArgs' optional
 * login hint is additive. The pre-existing tenantConfig / buildRedirectArgs
 * tests stay unmodified and cover the single-source rows.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { resolveRealmFromUrl } from '../tenantConfig'
import { buildRedirectArgs } from '../oidcRedirectArgs'

beforeEach(() => {
  sessionStorage.clear()
  window.history.pushState({}, '', '/')
})

afterEach(() => {
  sessionStorage.clear()
  window.history.pushState({}, '', '/')
})

describe('resolveRealmFromUrl precedence', () => {
  it('?realm=a with stored b returns a and overwrites the stored value', () => {
    sessionStorage.setItem('bpm_realm_slug', 'realm-b')
    window.history.pushState({}, '', '/?realm=realm-a')
    expect(resolveRealmFromUrl()).toBe('realm-a')
    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('realm-a')
  })

  it('stored only returns the stored slug', () => {
    sessionStorage.setItem('bpm_realm_slug', 'realm-b')
    expect(resolveRealmFromUrl()).toBe('realm-b')
  })

  it('?realm= only returns it and stores it', () => {
    window.history.pushState({}, '', '/?realm=realm-a')
    expect(resolveRealmFromUrl()).toBe('realm-a')
    expect(sessionStorage.getItem('bpm_realm_slug')).toBe('realm-a')
  })

  it('neither returns null', () => {
    expect(resolveRealmFromUrl()).toBeNull()
  })
})

describe('buildRedirectArgs login hint', () => {
  it('adds login_hint only when given, alongside redirect_uri and state', () => {
    sessionStorage.setItem('bpm_realm_slug', 'realm-a')
    const withHint = buildRedirectArgs('/tasks', { loginHint: 'u@example.org' })
    expect(withHint).toEqual({
      redirect_uri: `${window.location.origin}/auth/callback?realm=realm-a`,
      state: '/tasks',
      login_hint: 'u@example.org',
    })
    expect(buildRedirectArgs('/tasks')).not.toHaveProperty('login_hint')
    expect(buildRedirectArgs(undefined, { loginHint: '' })).not.toHaveProperty('login_hint')
  })

  it('still returns undefined with no realm, even with a hint', () => {
    expect(buildRedirectArgs(undefined, { loginHint: 'u@example.org' })).toBeUndefined()
  })
})
