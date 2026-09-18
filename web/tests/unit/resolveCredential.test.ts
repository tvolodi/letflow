// @vitest-environment node
/**
 * Unit tests — ISS-0712 fix: `resolveCredential` (web/tests/e2e/helpers.ts)
 *
 * ISS-0712's fix_direction asked helpers.ts to gain an env-var credential
 * path so a real-environment E2E run never needs an ad-hoc, reverted source
 * edit to supply a real credential (see ISS-0712.yaml's secondary finding).
 * `resolveCredential` is the pure function that implements that path; this
 * suite covers it directly since it is the only part of the ISS-0712 fix
 * that is unit-testable in this environment (no live Keycloak/browser
 * stack — see this run's handoff for why `loginViaRealOidcRedirect` and the
 * spec-file change are NOT covered here).
 *
 *   TC-RC-01: env var set, non-empty -> returns it (trimmed)
 *   TC-RC-02: env var unset -> returns fallback
 *   TC-RC-03: env var set but empty string -> returns fallback
 *   TC-RC-04: env var set but whitespace-only -> returns fallback
 *   TC-RC-05: env var value has surrounding whitespace -> returns it trimmed
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { resolveCredential } from '../e2e/helpers'

const ENV_VAR = 'ISS0712_TEST_CREDENTIAL_VAR'

describe('ISS-0712 — resolveCredential', () => {
  const originalValue = process.env[ENV_VAR]

  beforeEach(() => {
    delete process.env[ENV_VAR]
  })

  afterEach(() => {
    if (originalValue === undefined) {
      delete process.env[ENV_VAR]
    } else {
      process.env[ENV_VAR] = originalValue
    }
  })

  it('TC-RC-01: env var set and non-empty -> returns it', () => {
    process.env[ENV_VAR] = 'real-secret'
    expect(resolveCredential(ENV_VAR, 'local-fallback')).toBe('real-secret')
  })

  it('TC-RC-02: env var unset -> returns fallback', () => {
    expect(resolveCredential(ENV_VAR, 'local-fallback')).toBe('local-fallback')
  })

  it('TC-RC-03: env var set to empty string -> returns fallback', () => {
    process.env[ENV_VAR] = ''
    expect(resolveCredential(ENV_VAR, 'local-fallback')).toBe('local-fallback')
  })

  it('TC-RC-04: env var set to whitespace-only -> returns fallback', () => {
    process.env[ENV_VAR] = '   \t  '
    expect(resolveCredential(ENV_VAR, 'local-fallback')).toBe('local-fallback')
  })

  it('TC-RC-05: env var value has surrounding whitespace -> returns it trimmed', () => {
    process.env[ENV_VAR] = '  real-secret  '
    expect(resolveCredential(ENV_VAR, 'local-fallback')).toBe('real-secret')
  })
})
