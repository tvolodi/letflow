// @vitest-environment jsdom
/**
 * REQ-438 -- typed client for POST /api/login-discovery. Runs the real api
 * client against a stubbed network layer (the layer directly beneath the unit),
 * asserting the wire request and the closed outcome mapping.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { loginDiscoveryApi, parseLoginDiscoveryResponse } from '../loginDiscovery'

function stubNetwork(response: {
  status: number
  ok: boolean
  json?: () => Promise<unknown>
  headers?: Record<string, string>
}) {
  const impl = vi.fn().mockResolvedValue({
    status: response.status,
    ok: response.ok,
    statusText: 'x',
    json: response.json ?? (async () => ({})),
    headers: { get: (name: string) => response.headers?.[name] ?? null },
  })
  vi.stubGlobal('fetch', impl)
  return impl
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('loginDiscoveryApi.lookup', () => {
  it('POSTs {email} as JSON to /api/login-discovery', async () => {
    const net = stubNetwork({ status: 202, ok: true, json: async () => ({ result: 'accepted' }) })
    await loginDiscoveryApi.lookup('a@b.example')
    const [url, init] = net.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/login-discovery')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({ email: 'a@b.example' })
  })

  it('maps a 200 tenant body to the tenant outcome', async () => {
    stubNetwork({
      status: 200,
      ok: true,
      json: async () => ({ result: 'tenant', tenant: { slug: 'bilimbaga', display_name: 'BilimBaga' } }),
    })
    expect(await loginDiscoveryApi.lookup('a@b.example')).toEqual({
      kind: 'tenant',
      tenant: { slug: 'bilimbaga', display_name: 'BilimBaga' },
    })
  })

  it('maps a 202 accepted body to the accepted outcome', async () => {
    stubNetwork({ status: 202, ok: true, json: async () => ({ result: 'accepted' }) })
    expect(await loginDiscoveryApi.lookup('a@b.example')).toEqual({ kind: 'accepted' })
  })

  it('maps 429 to rate_limited', async () => {
    stubNetwork({ status: 429, ok: false })
    expect(await loginDiscoveryApi.lookup('a@b.example')).toEqual({ kind: 'rate_limited' })
  })

  it('maps a thrown network failure and non-429 HTTP failures to network_error', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to load')))
    expect(await loginDiscoveryApi.lookup('a@b.example')).toEqual({ kind: 'network_error' })

    stubNetwork({ status: 503, ok: false })
    expect(await loginDiscoveryApi.lookup('a@b.example')).toEqual({ kind: 'network_error' })
    stubNetwork({ status: 404, ok: false })
    expect(await loginDiscoveryApi.lookup('a@b.example')).toEqual({ kind: 'network_error' })
  })

  it('maps an unparsable body and any body outside the closed union to malformed', async () => {
    stubNetwork({
      status: 200,
      ok: true,
      json: async () => {
        throw new SyntaxError('Unexpected token')
      },
    })
    expect(await loginDiscoveryApi.lookup('a@b.example')).toEqual({ kind: 'malformed' })

    for (const body of [
      {},
      null,
      'accepted',
      { result: 'other' },
      { result: 'tenant' },
      { result: 'tenant', tenant: { slug: '', display_name: 'x' } },
      { result: 'tenant', tenant: { slug: 'x' } },
      { result: 'tenant', tenant: ['x'] },
    ]) {
      stubNetwork({ status: 200, ok: true, json: async () => body })
      expect(await loginDiscoveryApi.lookup('a@b.example')).toEqual({ kind: 'malformed' })
    }
  })
})

describe('slug charset/length validation', () => {
  const badSlugs = [
    '',
    'a'.repeat(256),
    'a/b',
    'a?b',
    'a#b',
    'a&b',
    'a b',
    '<script>',
    'café',
    'билим',
    '..',
    '.',
    '../x',
  ]

  for (const slug of badSlugs) {
    it(`maps out-of-pattern slug ${JSON.stringify(slug.slice(0, 20))} (len ${slug.length}) to malformed`, async () => {
      stubNetwork({
        status: 200,
        ok: true,
        json: async () => ({ result: 'tenant', tenant: { slug, display_name: 'D' } }),
      })
      expect(await loginDiscoveryApi.lookup('a@b.example')).toEqual({ kind: 'malformed' })
      expect(parseLoginDiscoveryResponse({ result: 'tenant', tenant: { slug, display_name: 'D' } })).toBeNull()
    })
  }

  it('still accepts normal slugs, including the 255-char boundary', async () => {
    for (const slug of ['bilimbaga', 'Acme_Corp-1.eu', 'a'.repeat(255)]) {
      stubNetwork({
        status: 200,
        ok: true,
        json: async () => ({ result: 'tenant', tenant: { slug, display_name: 'D' } }),
      })
      expect(await loginDiscoveryApi.lookup('a@b.example')).toEqual({
        kind: 'tenant',
        tenant: { slug, display_name: 'D' },
      })
    }
  })
})

describe('parseLoginDiscoveryResponse', () => {
  it('drops unknown extra fields so nothing outside the closed union is carried', () => {
    expect(
      parseLoginDiscoveryResponse({ result: 'tenant', tenant: { slug: 's', display_name: 'D', extra: 1 }, more: 2 }),
    ).toEqual({ result: 'tenant', tenant: { slug: 's', display_name: 'D' } })
  })
})
