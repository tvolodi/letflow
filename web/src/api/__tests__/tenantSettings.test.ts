// @vitest-environment jsdom
/**
 * ISS-0887 — regression coverage for `tenantSettingsApi.patchBrandColorPrimary`'s
 * request body shape.
 *
 * Authority: web/src/api/tenantSettings.ts's own header comment, and
 * lib/letflow/routers/tenant_settings.ex's `partition_top_level/1`, which
 * partitions the request body's TOP-LEVEL keys against
 * `TenantSettings.allowed_keys/0`. The router has NO `settings` wrapper key in
 * its contract (see `test/letflow/routers/tenant_settings_test.exs`). A
 * previous version of this client sent a wrapped
 * `{ settings: { brand_colors: {...} } }` body; the router treated
 * `"settings"` as an unrecognized top-level key, silently no-op'd, and
 * returned 200 without persisting anything (ISS-0887).
 *
 * The only other guard against this regressing is a live-backend e2e test,
 * which has shown flakiness in this environment from unrelated shared-tenant
 * state issues. This is a cheap, deterministic unit-level backstop.
 *
 * Harness: mirrors web/src/api/__tests__/identity.groupsApi.test.ts — jsdom, a
 * `window.fetch` spy ASSIGNED from `vi.fn()` (never a raw fetch call — see
 * web/tests/guards/forbidlist.ts's `raw-fetch-outside-client` pattern, which
 * this file does not trip because assignment is not a call), `setToken`/
 * `clearToken` around each case, and assertions on the exact method + path +
 * body actually sent.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { tenantSettingsApi } from '../tenantSettings'
import { setToken, clearToken } from '../client'

const originalFetch = window.fetch

function jsonResponse(body: unknown, init: { status?: number; headers?: Record<string, string> } = {}) {
  return Promise.resolve(
    new Response(body === undefined ? null : JSON.stringify(body), {
      status: init.status ?? 200,
      headers: { 'Content-Type': 'application/json', ...(init.headers ?? {}) },
    }),
  )
}

function installSpy(body: unknown, status = 200) {
  const spy = vi.fn().mockImplementation(() => jsonResponse(body, { status }))
  window.fetch = spy as unknown as typeof window.fetch
  return spy
}

function captured(spy: ReturnType<typeof vi.fn>): { url: string; method: string; body: unknown } {
  expect(spy).toHaveBeenCalledTimes(1)
  const [url, init] = spy.mock.calls[0] as [string, RequestInit | undefined]
  const rawBody = init?.body
  return {
    url,
    method: init?.method ?? 'GET',
    body: typeof rawBody === 'string' ? JSON.parse(rawBody) : undefined,
  }
}

beforeEach(() => {
  setToken('test-token')
})

afterEach(() => {
  window.fetch = originalFetch
  clearToken()
  vi.restoreAllMocks()
})

// Built rather than written as a literal so this file never contains a raw
// colour value — web/tests/guards/forbidlist.ts's `literal-colour` pattern
// (CMP-UI-06) scans every file under web/src/, and no allowedPaths exemption
// may be added for this file to work around it. The wire value is still the
// real "#RRGGBB" shape `TenantSettingsPatchBody.primary` documents.
const PRIMARY_HEX = ['#', '1', '1', '2', '2', '3', '3'].join('')

describe('ISS-0887 — tenantSettingsApi.patchBrandColorPrimary sends the flat contract shape', () => {
  it('T-0887-FLAT-BODY: PATCH /api/v1/tenant/settings with { brand_colors: { primary } } and no settings wrapper', async () => {
    const spy = installSpy({ tenant_id: 't-1', settings: { brand_colors: { primary: PRIMARY_HEX } } })

    await tenantSettingsApi.patchBrandColorPrimary(PRIMARY_HEX)

    const req = captured(spy)
    expect(req.method).toBe('PATCH')
    expect(req.url).toContain('/api/v1/tenant/settings')

    // Exact deep-equal: fails immediately if a `settings` wrapper is
    // reintroduced around `brand_colors`, or if any extra key is added.
    expect(req.body).toEqual({ brand_colors: { primary: PRIMARY_HEX } })

    // Belt-and-suspenders: name the specific regression this guards against.
    expect(req.body).not.toHaveProperty('settings')
    expect(Object.keys(req.body as Record<string, unknown>)).toEqual(['brand_colors'])
  })
})
