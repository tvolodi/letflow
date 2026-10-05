/** REQ-438 -- client for the public email-first discovery route
 *  (`POST /api/login-discovery`, REQ-437; design req434 sections 5 and 10).
 *
 *  Wire contract (lib/letflow/routers/login_discovery.ex): body `{"email"}`;
 *  `200 {"result":"tenant","tenant":{"slug","display_name"}}` for one matching
 *  match; `202 {"result":"accepted"}` for everything else; `429`. The response
 *  union is CLOSED: anything else is the malformed class.
 *
 *  The function never throws. Every outcome is a member of
 *  `LoginDiscoveryOutcome`, and none carries the address or any server text, so
 *  nothing here can leak whether an address exists.
 */
import { client } from './client'

export interface DiscoveredTenant {
  slug: string
  display_name: string
}

/** The two bodies the server may send, as a closed union. */
export type LoginDiscoveryResponse =
  | { result: 'accepted' }
  | { result: 'tenant'; tenant: DiscoveredTenant }

/** Everything the caller can observe: the closed response union plus the three
 *  failure classes (rate limited, network/API failure, malformed response). */
export type LoginDiscoveryOutcome =
  | { kind: 'tenant'; tenant: DiscoveredTenant }
  | { kind: 'accepted' }
  | { kind: 'rate_limited' }
  | { kind: 'network_error' }
  | { kind: 'malformed' }

const SAFE_SLUG = /^[A-Za-z0-9._-]{1,255}$/

/** Conservative slug check applied before a server slug is stored or put in a
 *  URL. All-dot values ('.', '..') match the charset but are path-ish: rejected. */
function isSafeSlug(slug: unknown): slug is string {
  return typeof slug === 'string' && SAFE_SLUG.test(slug) && !/^\.+$/.test(slug)
}

/** Narrows an unknown parsed body to the closed response union, else null. */
export function parseLoginDiscoveryResponse(body: unknown): LoginDiscoveryResponse | null {
  if (typeof body !== 'object' || body === null) return null
  const record = body as Record<string, unknown>

  if (record.result === 'accepted') return { result: 'accepted' }

  if (record.result === 'tenant') {
    const tenant = record.tenant
    if (typeof tenant !== 'object' || tenant === null) return null
    const { slug, display_name } = tenant as Record<string, unknown>
    if (!isSafeSlug(slug)) return null
    if (typeof display_name !== 'string') return null
    return { result: 'tenant', tenant: { slug, display_name } }
  }

  return null
}

function httpStatusOf(error: unknown): number | null {
  if (typeof error === 'object' && error !== null && 'status' in error) {
    const status = (error as { status: unknown }).status
    if (typeof status === 'number') return status
  }
  return null
}

export const loginDiscoveryApi = {
  async lookup(email: string): Promise<LoginDiscoveryOutcome> {
    let body: unknown
    try {
      body = await client.post<unknown>('/api/login-discovery', { email })
    } catch (error) {
      const status = httpStatusOf(error)
      if (status === 429) return { kind: 'rate_limited' }
      // A numeric status is an HTTP-level failure (404 when the mount is off,
      // 5xx, ...); a thrown TypeError is the network failing. A 200/202 whose
      // body is not JSON surfaces as a SyntaxError from response.json().
      if (status !== null) return { kind: 'network_error' }
      if (error instanceof SyntaxError) return { kind: 'malformed' }
      return { kind: 'network_error' }
    }

    const parsed = parseLoginDiscoveryResponse(body)
    if (parsed === null) return { kind: 'malformed' }
    if (parsed.result === 'accepted') return { kind: 'accepted' }
    return { kind: 'tenant', tenant: parsed.tenant }
  },
}
