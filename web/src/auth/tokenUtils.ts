import type { JwtPayload } from '@/types/api'

export function decodeTokenPayload(token: string): JwtPayload | null {
  try {
    const parts = token.split('.')
    if (parts.length !== 3) return null
    const payload = parts[1]
    // Pad to multiple of 4 for atob
    const padded = payload + '='.repeat((4 - (payload.length % 4)) % 4)
    const decoded = atob(padded)
    return JSON.parse(decoded) as JwtPayload
  } catch {
    return null
  }
}

export function resolveDisplayName(payload: JwtPayload): string {
  return payload.display_name ?? payload.name ?? payload.preferred_username ?? payload.sub ?? 'Unknown User'
}

/**
 * Extract the tenant slug from the JWT payload.
 * Priority: payload.tenant_id claim → realm segment from payload.iss.
 * The pinned default tenant's realm ("bpm-default") is returned verbatim rather than
 * having its "bpm-" prefix stripped — see the DEFAULT_TENANT_REALM comment below.
 * Returns null if neither is available.
 */

// The seeded default tenant is pinned so that slug === realm === "bpm-default" exactly
// (unlike ordinary tenants, where realm = "bpm-" + slug). This mirrors
// lib/letflow/identity/tenant.ex's `@default_tenant_slug "bpm-default"` module attribute
// and the `validate_default_tenant_pinning/1` changeset invariant, which enforces that
// this tenant's idp_realm_id equals "bpm-default" verbatim. If that backend value ever
// changes, this literal must be updated to match — see tenant.ex's moduledoc.
const DEFAULT_TENANT_REALM = 'bpm-default'

export function resolveTenantSlug(payload: JwtPayload): string | null {
  if (payload.tenant_id) return payload.tenant_id
  if (payload.iss) {
    try {
      const url = new URL(payload.iss)
      const parts = url.pathname.split('/')
      const realmsIdx = parts.indexOf('realms')
      if (realmsIdx !== -1 && parts[realmsIdx + 1]) {
        const realm = parts[realmsIdx + 1]
        if (realm === DEFAULT_TENANT_REALM) return realm
        return realm.startsWith('bpm-') ? realm.slice(4) : realm
      }
    } catch {
      return null
    }
  }
  return null
}
