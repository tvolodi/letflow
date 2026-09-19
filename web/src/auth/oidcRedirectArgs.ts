import { resolveRealmFromUrl } from './tenantConfig'
import { isSafeRestorePath } from './safeRestorePath'

/**
 * Builds signinRedirect args that embed the current tenant realm slug in the
 * redirect_uri so that OidcCallbackPage can identify the realm without relying
 * on sessionStorage state alone, and optionally captures the pre-redirect path
 * (via oidc-client-ts's `state` option) so it can be restored after the OIDC
 * round trip completes.
 *
 * `capturePath`, when provided and validated safe by `isSafeRestorePath`, is
 * carried as `state` — oidc-client-ts persists it in its stateStore across the
 * full-page navigation to Keycloak and back, and it is available as `user.state`
 * once `signinRedirectCallback()` resolves. An unsafe or omitted `capturePath`
 * results in `state` being omitted entirely from the returned object (not set
 * to `undefined` explicitly) — see
 * lib/letflow/design/iss-0726-oidc-redirect-path-restore.md §2.3.
 *
 * Returns `{ redirect_uri, state? }` when a realm slug is resolvable, or
 * `undefined` to let the UserManager use its configured default redirect_uri.
 */
export function buildRedirectArgs(
  capturePath?: string,
): { redirect_uri: string; state?: string } | undefined {
  const slug = resolveRealmFromUrl()
  if (!slug) return undefined

  const redirect_uri =
    window.location.origin + '/auth/callback?realm=' + encodeURIComponent(slug)

  if (capturePath !== undefined && isSafeRestorePath(capturePath)) {
    return { redirect_uri, state: capturePath }
  }
  return { redirect_uri }
}
