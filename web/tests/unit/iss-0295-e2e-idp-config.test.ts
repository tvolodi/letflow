// @vitest-environment node
/**
 * Regression test — ISS-0295: web/tests/e2e/*.ts hardcoded a stale Keycloak port
 * (8081) and client_id (bpm-platform-api) across 33 files with no shared constant —
 * any override required editing many files, and the client_id had NO override
 * mechanism at all. Fixed by consolidating into two exported constants in
 * web/tests/e2e/helpers.ts: BPM_IDP_BASE_URL and BPM_IDP_CLIENT_ID, both
 * env-overridable, with all consuming spec files importing from there.
 *
 * This test asserts the INVARIANT the fix establishes, not today's literal values,
 * so staleness of this class cannot silently recur:
 *
 *   TC-1: helpers.ts exports BPM_IDP_CLIENT_ID / BPM_IDP_BASE_URL, both overridable
 *         via process.env — the override mechanism is the part that was previously
 *         impossible for BPM_IDP_CLIENT_ID (it did not exist as an env-derived value
 *         at all, only a hardcoded literal).
 *   TC-2: no spec file under web/tests/e2e/ hardcodes 'bpm-platform-api' or a bare
 *         8081 literal outside of helpers.ts itself — proves the class of staleness
 *         (many files redeclaring the same values) cannot recur.
 *
 * Pre-fix / post-fix proof (see test/specs/ISS-0295.md for the full record):
 *   - Against main (275e9f1, pre-fix): helpers.ts exports neither constant at all
 *     (TC-1 fails to even import them) and TC-2 fails with 49 hardcoded IdP literal(s)
 *     ('bpm-platform-api' / bare 8081) across the e2e spec files.
 *   - Against feature/WF03-ISS0295-20260823 (f7aec1d, post-fix): both pass.
 */

import { describe, it, expect, afterEach, vi } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import fg from 'fast-glob'

const E2E_DIR = join(__dirname, '..', 'e2e')

describe('ISS-0295 — e2e Keycloak config consolidation', () => {
  describe('TC-1: BPM_IDP_CLIENT_ID / BPM_IDP_BASE_URL are exported and env-overridable', () => {
    const ORIGINAL_CLIENT_ID = process.env.BPM_IDP_CLIENT_ID
    const ORIGINAL_BASE_URL = process.env.BPM_IDP_BASE_URL

    afterEach(() => {
      if (ORIGINAL_CLIENT_ID === undefined) delete process.env.BPM_IDP_CLIENT_ID
      else process.env.BPM_IDP_CLIENT_ID = ORIGINAL_CLIENT_ID

      if (ORIGINAL_BASE_URL === undefined) delete process.env.BPM_IDP_BASE_URL
      else process.env.BPM_IDP_BASE_URL = ORIGINAL_BASE_URL

      vi.resetModules()
    })

    it('defaults to letflow-web / http://localhost:8082 with no env override', async () => {
      delete process.env.BPM_IDP_CLIENT_ID
      delete process.env.BPM_IDP_BASE_URL
      vi.resetModules()

      const helpers = await import('../e2e/helpers')
      expect(helpers.BPM_IDP_CLIENT_ID).toBe('letflow-web')
      expect(helpers.BPM_IDP_BASE_URL).toBe('http://localhost:8082')
    })

    it('BPM_IDP_CLIENT_ID is overridable via process.env.BPM_IDP_CLIENT_ID', async () => {
      process.env.BPM_IDP_CLIENT_ID = 'some-other-client'
      vi.resetModules()

      const helpers = await import('../e2e/helpers')
      expect(helpers.BPM_IDP_CLIENT_ID).toBe('some-other-client')
    })

    it('BPM_IDP_BASE_URL is overridable via process.env.BPM_IDP_BASE_URL', async () => {
      process.env.BPM_IDP_BASE_URL = 'http://keycloak.internal:9999'
      vi.resetModules()

      const helpers = await import('../e2e/helpers')
      expect(helpers.BPM_IDP_BASE_URL).toBe('http://keycloak.internal:9999')
    })
  })

  describe('TC-2: no hardcoded IdP literals outside helpers.ts', () => {
    it('no spec file under web/tests/e2e/ hardcodes bpm-platform-api or a bare 8081', async () => {
      const files = await fg('**/*.ts', { cwd: E2E_DIR })
      const offenders: { file: string; line: number; text: string }[] = []

      for (const rel of files) {
        // helpers.ts is the single sanctioned home for these values (and their
        // historical-context comments) — every other file must import from it.
        if (rel === 'helpers.ts') continue

        const abs = join(E2E_DIR, rel)
        const content = readFileSync(abs, 'utf8')
        const lines = content.split('\n')

        lines.forEach((line, idx) => {
          if (line.includes('bpm-platform-api')) {
            offenders.push({ file: rel, line: idx + 1, text: line.trim() })
          }
          if (/\b8081\b/.test(line)) {
            offenders.push({ file: rel, line: idx + 1, text: line.trim() })
          }
        })
      }

      if (offenders.length > 0) {
        const summary = offenders
          .slice(0, 15)
          .map(o => `  ${o.file}:${o.line}: ${o.text}`)
          .join('\n')
        const more = offenders.length > 15 ? `\n  ... and ${offenders.length - 15} more` : ''
        expect.fail(
          `Found ${offenders.length} hardcoded IdP literal(s) outside helpers.ts:\n${summary}${more}`,
        )
      }

      expect(offenders).toHaveLength(0)
    })
  })
})
