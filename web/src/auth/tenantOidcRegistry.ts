/** REQ-384 §5.2 — per-tenant OIDC manager registry.
 *
 *  Holds at most one live `UserManager` instance per tenant the switcher has
 *  resolved this session, keyed by tenant slug — not a single mutable
 *  singleton like `OidcManager.ts`'s own `_resolvedManager`. Retained
 *  separately from that file: a user's *first* sign-in and a
 *  single-membership user (no switcher renders) keep using
 *  `getOidcManager()` unchanged (§5.1).
 */
import { UserManager } from 'oidc-client-ts'
import type { UserManagerSettings } from 'oidc-client-ts'
import { buildOidcSettings } from './OidcManager'
import { fetchTenantConfigForSlug } from './tenantConfig'

const _managersBySlug = new Map<string, UserManager>()

/** Returns the cached `UserManager` for `slug`, building and caching one
 *  (from `fetchTenantConfigForSlug`'s own per-slug-keyed config cache — never
 *  `tenantConfig.ts`'s single-value `_cachedConfig`) if none exists yet. */
export async function getOrCreateManagerForTenant(slug: string): Promise<UserManager> {
  const cached = _managersBySlug.get(slug)
  if (cached) return cached

  const config = await fetchTenantConfigForSlug(slug)
  const settings: UserManagerSettings = buildOidcSettings(config.oidc_authority, config.client_id)
  const manager = new UserManager(settings)
  _managersBySlug.set(slug, manager)
  return manager
}

export type SilentSwitchOutcome =
  | { outcome: 'silent_ok'; user: import('oidc-client-ts').User }
  | { outcome: 'interaction_required' }
  | { outcome: 'error'; reason: unknown }

/** oidc-client-ts's own thrown error shape for a realm with no active
 *  browser session reachable from the silent iframe (OQ-3: only true if
 *  tenant realms share SSO via a federated upstream IdP). */
function isInteractionRequiredError(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false
  const err = error as { error?: unknown }
  return err.error === 'login_required' || err.error === 'interaction_required'
}

/** Attempts a silent (iframe-based, no top-level navigation) auth switch to
 *  `targetSlug` — the concrete mechanism satisfying AC1's "without a
 *  full-page OIDC re-authentication." Falls back to `'interaction_required'`
 *  when the target realm has no active session reachable silently; the
 *  caller (§6.1's `TenantSwitcher`) then offers an explicit, user-initiated
 *  sign-in affordance rather than retrying silently. */
export async function attemptSilentSwitch(targetSlug: string): Promise<SilentSwitchOutcome> {
  try {
    const manager = await getOrCreateManagerForTenant(targetSlug)
    const user = await manager.signinSilent()
    if (!user) return { outcome: 'interaction_required' }
    return { outcome: 'silent_ok', user }
  } catch (error) {
    if (isInteractionRequiredError(error)) return { outcome: 'interaction_required' }
    return { outcome: 'error', reason: error }
  }
}
