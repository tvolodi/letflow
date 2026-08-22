// @vitest-environment node
/**
 * REQ-129 — proves AppShell's nav-gating `Role` union never names a role the
 * authorization matrix (`Letflow.Api.Authorization.roles/0`) does not define.
 *
 * This check is deliberately ONE-DIRECTIONAL: matrix roles may exist that are
 * absent from AppShell's `Role` union, and that is not a failure. Per
 * decisions/0013-authorization-role-set.md, `AGENT_RUNNER` is exactly such a
 * role -- a machine role for the deferred runtime-agent subsystem, present in
 * the matrix and the realm, but never gated on in the SPA nav because no human
 * session ever carries it. An equality check would break on that expected,
 * permanent asymmetry; do not "fix" this into one. What this test forbids is
 * the other direction -- a role appearing in the SPA that the matrix does not
 * know about, which is the shape of drift that ships a nav entry no token can
 * ever unlock.
 *
 * The matrix's role list is read directly out of
 * lib/letflow/api/authorization.ex's `@roles` module attribute (not
 * hand-copied here) so this check can't itself drift from the Elixir source
 * of truth. The Elixir-side equivalent -- realm vs. matrix, checked for exact
 * equality since no asymmetry is expected there -- lives in
 * test/letflow/api/authorization_role_realm_test.exs.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const REPO_ROOT = join(__dirname, '..', '..', '..')
const AUTHORIZATION_EX_PATH = join(REPO_ROOT, 'lib', 'letflow', 'api', 'authorization.ex')
const APP_SHELL_PATH = join(REPO_ROOT, 'web', 'src', 'components', 'layout', 'AppShell.tsx')

function extractMatrixRoles(source: string): string[] {
  const match = source.match(/@roles \[([^\]]+)\]/)
  if (!match) {
    throw new Error(
      `Could not find "@roles [...]" in ${AUTHORIZATION_EX_PATH} -- has Letflow.Api.Authorization been restructured? Update this guard's extraction to match.`,
    )
  }
  return match[1]
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0)
    .map((entry) => entry.replace(/^:/, ''))
}

function extractAppShellRoles(source: string): string[] {
  const match = source.match(/type Role = ([^\n]+)/)
  if (!match) {
    throw new Error(
      `Could not find "type Role = ..." in ${APP_SHELL_PATH} -- has the Role union been renamed or restructured? Update this guard's extraction to match.`,
    )
  }
  return match[1]
    .split('|')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0)
    .map((entry) => entry.replace(/^['"]|['"]$/g, ''))
}

describe('role-set: AppShell Role union has no role absent from the authorization matrix', () => {
  it(
    'every role in AppShell.tsx\'s Role union exists in Letflow.Api.Authorization.roles/0 ' +
      '(one-directional: AGENT_RUNNER is expected in the matrix but NOT in this union, and that is not a violation)',
    () => {
      const matrixSource = readFileSync(AUTHORIZATION_EX_PATH, 'utf8')
      const appShellSource = readFileSync(APP_SHELL_PATH, 'utf8')

      const matrixRoles = extractMatrixRoles(matrixSource)
      const appShellRoles = extractAppShellRoles(appShellSource)

      expect(matrixRoles.length).toBeGreaterThan(0)
      expect(appShellRoles.length).toBeGreaterThan(0)

      const unknownRoles = appShellRoles.filter((role) => !matrixRoles.includes(role))

      expect(
        unknownRoles,
        `AppShell.tsx's Role union names role(s) the authorization matrix does not define: ${JSON.stringify(unknownRoles)}. ` +
          `Matrix roles (lib/letflow/api/authorization.ex): ${JSON.stringify(matrixRoles)}. ` +
          `AppShell roles (web/src/components/layout/AppShell.tsx): ${JSON.stringify(appShellRoles)}. ` +
          'Per decisions/0013-authorization-role-set.md, do not resolve this by editing this guard -- ' +
          'fix whichever source is wrong, or write a new decision record if the role set itself is changing.',
      ).toEqual([])
    },
  )
})
