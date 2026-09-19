/**
 * Type-guard that validates a candidate "restore path" — a client-captured path
 * round-tripped through oidc-client-ts's `state` option and Keycloak — is safe to
 * pass directly to react-router's `navigate()`.
 *
 * Per lib/letflow/design/iss-0726-oidc-redirect-path-restore.md §1.3, `value` is a
 * safe restore path if and only if all of the following hold:
 *   1. typeof value === 'string'
 *   2. 0 < value.length <= 2048
 *   3. value.startsWith('/') — root-relative
 *   4. !value.startsWith('//') — not protocol-relative
 *   5. !value.includes('\\') — no backslash (some browsers normalize /\evil.com as //evil.com)
 *   6. no embedded URL scheme anywhere in the string (javascript:, data:, https:, ...)
 *   7. the path portion (before the first ? or #) matches ^\/[A-Za-z0-9\-_/]*$
 *   8. if present, the query portion (from ? to the first # or end) matches the
 *      RFC 3986 pchar/query safe set plus a second literal '?'
 *   9. if present, the fragment portion (from # to end) matches the same class as (8)
 *
 * This is a plain character-class + scheme/protocol-relative rejection, not a
 * route-table match — see the design doc §1.3's "Decision" for why a route-table
 * match was rejected (avoids a second, drift-prone list of valid routes).
 */
export function isSafeRestorePath(value: unknown): value is string {
  if (typeof value !== 'string') return false
  if (value.length === 0 || value.length > 2048) return false
  if (!value.startsWith('/')) return false
  if (value.startsWith('//')) return false
  if (value.includes('\\')) return false
  if (/[a-zA-Z][a-zA-Z0-9+.-]*:/.test(value)) return false

  const hashIndex = value.indexOf('#')
  const beforeHash = hashIndex === -1 ? value : value.slice(0, hashIndex)
  const fragment = hashIndex === -1 ? '' : value.slice(hashIndex + 1)

  const queryIndex = beforeHash.indexOf('?')
  const path = queryIndex === -1 ? beforeHash : beforeHash.slice(0, queryIndex)
  const query = queryIndex === -1 ? '' : beforeHash.slice(queryIndex + 1)

  if (!/^\/[A-Za-z0-9\-_/]*$/.test(path)) return false

  const queryFragmentPattern = /^[A-Za-z0-9\-_.~%!$&'()*+,;=:@/?]*$/
  if (queryIndex !== -1 && !queryFragmentPattern.test(query)) return false
  if (hashIndex !== -1 && !queryFragmentPattern.test(fragment)) return false

  return true
}
