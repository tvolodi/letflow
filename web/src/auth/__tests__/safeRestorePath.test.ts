// @vitest-environment jsdom
/**
 * Unit tests — ISS-0726: `isSafeRestorePath` (web/src/auth/safeRestorePath.ts).
 *
 * Spec: test/specs/ISS-0726.md
 * Design: lib/letflow/design/iss-0726-oidc-redirect-path-restore.md §1.3, §6.1
 *
 * Table-driven cases mirroring the adversarial payload set SECURITY-REVIEWER
 * already verified by hand for this fix (open-redirect / injection shapes),
 * plus the legitimate-path cases the fix must not regress.
 */

import { describe, expect, it } from 'vitest'
import { isSafeRestorePath } from '../safeRestorePath'

describe('isSafeRestorePath', () => {
  describe('legitimate root-relative paths -> true', () => {
    it.each([
      ['/exam', '/exam'],
      ['/exam/123', '/exam/123'],
      ['/exam/abc-123/session', '/exam/abc-123/session'],
      ['/exam?tab=results&sort=asc', '/exam?tab=results&sort=asc'],
      ['/exam#section-1', '/exam#section-1'],
      ['root path alone', '/'],
    ])('%s -> true', (_label, value) => {
      expect(isSafeRestorePath(value)).toBe(true)
    })
  })

  describe('protocol-relative and scheme-embedded payloads -> false', () => {
    it.each([
      ['//evil.com', '//evil.com'],
      ['//evil.com/path', '//evil.com/path'],
      // No dot, letters only -- isolates the protocol-relative check (item 4)
      // from the path character-class check (item 7), which would otherwise
      // also reject a dotted host and mask a missing item-4 check.
      ['//evilhost (no dot, protocol-relative only)', '//evilhost'],
      ['backslash variant of protocol-relative', '/\\evil.com'],
      ['javascript: scheme, no leading slash', 'javascript:alert(1)'],
      ['javascript: scheme embedded in query', '/x?to=javascript:alert(1)'],
      ['data: URI, no leading slash', 'data:text/html,<script>alert(1)</script>'],
      ['absolute https URL', 'https://evil.com'],
      ['scheme embedded anywhere in string', '/redirect?to=https://evil.com'],
    ])('%s -> false', (_label, value) => {
      expect(isSafeRestorePath(value)).toBe(false)
    })
  })

  describe('path traversal and encoding-bypass payloads -> false', () => {
    it.each([
      ['dot-dot traversal', '/../etc/passwd'],
      ['dot-dot mid-path', '/exam/../admin'],
      ['percent-encoded slash', '/%2F evil.com'],
      ['percent-encoded slash bypass of protocol-relative', '/%2f%2fevil.com'],
      ['literal dot in path portion', '/exam/./session'],
    ])('%s -> false', (_label, value) => {
      expect(isSafeRestorePath(value)).toBe(false)
    })
  })

  describe('unicode homoglyph payloads -> false', () => {
    it.each([
      // Cyrillic 'е' (U+0435) homoglyph substituted for Latin 'e' — not in the
      // path portion's [A-Za-z0-9\-_/] character class, so rejected outright.
      ['cyrillic homoglyph in path', '/еxam'],
      ['fullwidth solidus lookalike', '/exam／..／admin'],
    ])('%s -> false', (_label, value) => {
      expect(isSafeRestorePath(value)).toBe(false)
    })
  })

  describe('injected-markup payloads -> false', () => {
    it.each([
      ['angle brackets in path', '/<script>'],
      ['angle brackets in query', '/exam?x=<script>alert(1)</script>'],
      ['quote in query', '/exam?x="onmouseover=alert(1)'],
      ['backtick in query', '/exam?x=`alert(1)`'],
      ['raw space in query', '/exam?x=hello world'],
    ])('%s -> false', (_label, value) => {
      expect(isSafeRestorePath(value)).toBe(false)
    })
  })

  describe('structural rejects -> false', () => {
    it.each([
      ['empty string', ''],
      ['no leading slash', 'exam'],
      ['no leading slash, relative', 'exam/123'],
    ])('%s -> false', (_label, value) => {
      expect(isSafeRestorePath(value)).toBe(false)
    })
  })

  describe('oversized string boundary (2048 chars)', () => {
    it('exactly 2048 chars -> true (at the boundary, still allowed)', () => {
      const value = '/' + 'a'.repeat(2047)
      expect(value.length).toBe(2048)
      expect(isSafeRestorePath(value)).toBe(true)
    })

    it('2049 chars -> false (one over the boundary)', () => {
      const value = '/' + 'a'.repeat(2048)
      expect(value.length).toBe(2049)
      expect(isSafeRestorePath(value)).toBe(false)
    })
  })

  describe('non-string inputs -> false', () => {
    it.each([
      ['undefined', undefined],
      ['null', null],
      ['number', 42],
      ['plain object', {}],
      ['array', ['/exam']],
      ['boolean', true],
    ])('%s -> false', (_label, value) => {
      expect(isSafeRestorePath(value)).toBe(false)
    })
  })
})
