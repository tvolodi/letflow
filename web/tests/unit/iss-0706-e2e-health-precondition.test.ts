// @vitest-environment node
/**
 * Regression test — ISS-0706: 10 web/tests/e2e/*.ts specs polled the
 * never-mounted `GET /health/ready` as a precondition, throwing on every run
 * before reaching their own assertions (lib/letflow/router.ex deliberately
 * never ports R-Co's readiness route — see that router's moduledoc). Fixed by
 * adding shared `assertBackendHealthy`/`assertServiceReadiness` to
 * web/tests/e2e/helpers.ts, pointed at the real `GET /health` liveness
 * endpoint, and having all 10 affected files import from there instead of
 * each keeping its own copy-pasted, wrongly-URLed local function.
 *
 * TC-1/TC-2: assertBackendHealthy — hits `${apiBaseUrl}/health` (never
 *   `/health/ready`), resolves silently on a 2xx response, throws with the
 *   real status + URL on a non-2xx response.
 * TC-3/TC-4: assertServiceReadiness — checks backend liveness first, and
 *   short-circuits (propagating the backend's own error, never reaching the
 *   Keycloak check) if that throws; checks Keycloak discovery second and
 *   throws with its own message if that's unreachable.
 * TC-5: none of the 10 files this fix touched contain a local, hardcoded
 *   `/health/ready` precondition against the Letflow backend any more — all
 *   import the shared helper instead. Scoped to exactly the 10 files ISS-0706
 *   claims to have fixed (not repo-wide): a broader recurrence of this exact
 *   bug class in other e2e files, outside ISS-0706's own stated scope, was
 *   found during this coverage assessment and is tracked separately as
 *   ISS-0707 (docs/issues/ISS-0707.yaml) — conflating that into this file's
 *   assertion would make an unrelated, already-filed gap look like a failure
 *   of this fix.
 *
 * Pre-fix / post-fix proof (see test/specs/ISS-0706.md for the full record):
 *   - Against a6b5e5ac^ (pre-fix): helpers.ts exports neither
 *     assertBackendHealthy nor assertServiceReadiness at all (TC-1..TC-4 fail
 *     to even import them) and TC-5 fails — none of the 10 files import a
 *     shared helper; each still has its own local /health/ready-based
 *     function.
 *   - Against a6b5e5ac (post-fix, this branch's tip): all pass.
 */

import { describe, it, expect, vi } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { APIRequestContext } from '@playwright/test'

const E2E_DIR = join(__dirname, '..', 'e2e')

// The exact 10 files ISS-0706's own commit (a6b5e5ac) claims to have fixed —
// see that commit's message. sh05-06.shell.e2e.spec.ts is deliberately
// excluded: it was already fixed under ISS-0532 and untouched here.
const FIXED_FILES = [
  'env04.e2e.spec.ts',
  'f5-admin-observability.e2e.spec.ts',
  'f6-webhooks.e2e.spec.ts',
  'tenants.e2e.spec.ts',
  'f5-admin-groups-tokens.e2e.spec.ts',
  'f5-admin-users.e2e.spec.ts',
  'f6-dlq.e2e.spec.ts',
  'tenant-dashboard.e2e.spec.ts',
  'iss-0063-oidc-redirect-loop.e2e.spec.ts',
  'uat-tenant-url.e2e.spec.ts',
]

/** Minimal fake APIRequestContext — only the `.fetch(url)` method these two
 * helpers actually call. Casts through `unknown` since a real
 * APIRequestContext carries many more methods this test never needs.
 */
function fakeRequest(responses: Record<string, { ok: boolean; status: number }>): APIRequestContext {
  const fetch = vi.fn(async (url: string) => {
    const entry = responses[url]
    if (!entry) throw new Error(`fakeRequest: no stubbed response for ${url}`)
    return { ok: () => entry.ok, status: () => entry.status }
  })
  return { fetch } as unknown as APIRequestContext
}

describe('ISS-0706 — e2e health-precondition fix', () => {
  describe('TC-1/TC-2: assertBackendHealthy', () => {
    it('resolves without throwing when GET /health is 2xx, and never polls /health/ready', async () => {
      const { assertBackendHealthy } = await import('../e2e/helpers')
      const request = fakeRequest({
        'http://api.test/health': { ok: true, status: 200 },
      })

      await expect(assertBackendHealthy(request, 'http://api.test')).resolves.toBeUndefined()
      expect((request.fetch as ReturnType<typeof vi.fn>)).toHaveBeenCalledWith('http://api.test/health')
      expect((request.fetch as ReturnType<typeof vi.fn>)).not.toHaveBeenCalledWith('http://api.test/health/ready')
    })

    it('throws, including the real status and URL, when GET /health is non-2xx', async () => {
      const { assertBackendHealthy } = await import('../e2e/helpers')
      const request = fakeRequest({
        'http://api.test/health': { ok: false, status: 503 },
      })

      await expect(assertBackendHealthy(request, 'http://api.test'))
        .rejects.toThrow(/Backend not live \(503\) at http:\/\/api\.test\/health/)
    })
  })

  describe('TC-3/TC-4: assertServiceReadiness', () => {
    it('checks backend liveness, then Keycloak discovery, resolving when both are healthy', async () => {
      const { assertServiceReadiness, BPM_IDP_BASE_URL } = await import('../e2e/helpers')
      const discoveryUrl = `${BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`
      const request = fakeRequest({
        'http://api.test/health': { ok: true, status: 200 },
        [discoveryUrl]: { ok: true, status: 200 },
      })

      await expect(assertServiceReadiness(request, 'http://api.test')).resolves.toBeUndefined()
    })

    it('short-circuits on backend failure — never reaches the Keycloak check', async () => {
      const { assertServiceReadiness, BPM_IDP_BASE_URL } = await import('../e2e/helpers')
      const discoveryUrl = `${BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`
      const request = fakeRequest({
        'http://api.test/health': { ok: false, status: 500 },
        [discoveryUrl]: { ok: true, status: 200 },
      })

      await expect(assertServiceReadiness(request, 'http://api.test'))
        .rejects.toThrow(/Backend not live \(500\)/)
      // The Keycloak URL must never have been fetched — the backend error
      // propagates unchanged, per assertServiceReadiness's own doc comment.
      expect((request.fetch as ReturnType<typeof vi.fn>)).not.toHaveBeenCalledWith(discoveryUrl)
    })

    it('throws with a Keycloak-specific message when backend is healthy but Keycloak is not', async () => {
      const { assertServiceReadiness, BPM_IDP_BASE_URL } = await import('../e2e/helpers')
      const discoveryUrl = `${BPM_IDP_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`
      const request = fakeRequest({
        'http://api.test/health': { ok: true, status: 200 },
        [discoveryUrl]: { ok: false, status: 404 },
      })

      await expect(assertServiceReadiness(request, 'http://api.test'))
        .rejects.toThrow(/Keycloak not ready \(404\)/)
    })
  })

  describe('TC-5: none of the 10 ISS-0706-fixed files reintroduce a local /health/ready precondition', () => {
    it('every fixed file imports assertBackendHealthy or assertServiceReadiness from ./helpers, and hardcodes no Letflow-backend /health/ready call', () => {
      const offenders: { file: string; reason: string }[] = []

      for (const file of FIXED_FILES) {
        const content = readFileSync(join(E2E_DIR, file), 'utf8')

        const importsHelper =
          /from '\.\/helpers'/.test(content) &&
          (content.includes('assertBackendHealthy') || content.includes('assertServiceReadiness'))
        if (!importsHelper) {
          offenders.push({ file, reason: 'does not import assertBackendHealthy/assertServiceReadiness from ./helpers' })
        }

        // A Letflow-backend health/ready call is built from the file's own
        // API_BASE_URL-shaped variable, never BPM_IDP_BASE_URL/idpBaseUrl/
        // keycloakBaseUrl (Keycloak legitimately keeps its own /health/ready
        // probe — e.g. uat-tenant-url.e2e.spec.ts's requireIdpReady — that is
        // not this bug and must not be flagged).
        const lines = content.split('\n')
        lines.forEach((line, idx) => {
          if (!/health\/ready/.test(line)) return
          if (/idp|Idp|IDP|keycloak|Keycloak/.test(line)) return
          // Only flag it as a Letflow-backend precondition call — a
          // `request`/`fetch(` call against this literal. This intentionally
          // does NOT flag f5-admin-observability.e2e.spec.ts's own
          // `response.url().includes('/health/ready')` page-response
          // listener, which asserts on network calls the app-under-test's
          // health dashboard makes — that is the feature being tested, not a
          // test precondition, and is unrelated to this bug class.
          // Only flag it when it's actually a URL being built (a template
          // literal ending `.../health/ready`), never a call like
          // `response.request().method()` / `response.url().includes(...)`
          // that merely mentions the string while inspecting a captured
          // network response.
          if (!/\$\{[^}]*\}\/health\/ready/.test(line)) return
          offenders.push({ file, reason: `line ${idx + 1} still references a non-Keycloak /health/ready: ${line.trim()}` })
        })
      }

      if (offenders.length > 0) {
        const summary = offenders.map(o => `  ${o.file}: ${o.reason}`).join('\n')
        expect.fail(`Found ${offenders.length} ISS-0706 regression(s):\n${summary}`)
      }

      expect(offenders).toHaveLength(0)
    })
  })
})
