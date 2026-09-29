// @vitest-environment node
/**
 * Unit tests — ISS-0896 fix: `getMasterAdminToken` (web/tests/e2e/helpers.ts)
 *
 * ISS-0896's fix introduced `getMasterAdminToken`, a shared helper that
 * obtains a JWT from Keycloak's MASTER realm via the built-in `admin-cli`
 * client (password grant), replacing 5 e2e specs' own copy-pasted versions.
 * Username/password resolve via `resolveCredential('KC_ADMIN_USER', 'admin')`
 * / `resolveCredential('KC_ADMIN_PASSWORD', 'admin')` — env var if set and
 * non-empty, else the literal 'admin'/'admin' fallback — and the function
 * must throw (never return a boolean/undefined) on a non-2xx response,
 * without leaking the attempted username/password into the thrown message
 * (SECURITY-REVIEWER's own PASS finding for this fix).
 *
 * This is a NEW function — there is no pre-fix version to run these tests
 * against, so the fail-then-pass proof for these tests comes from mutation,
 * not from a literal pre-fix/post-fix run (see this run's handoff and
 * docs/agents/workflows/WF-03_issue_resolving.md, "When the pre-fix failure
 * is code under test does not exist"). The mutation record lives in this
 * run's handoff (handoffs/WF03-ISS0896-20260929/step-04-test-designer.json),
 * not in this file — a mutant is a temporary probe, never committed here.
 *
 *   TC-1: KC_ADMIN_USER/KC_ADMIN_PASSWORD unset -> POST body username/password
 *         are the fallback 'admin'/'admin'.
 *   TC-2: both env vars set -> POST body username/password match the env
 *         values, not the fallback.
 *   TC-3: non-ok response -> throws, and the thrown message does not contain
 *         the attempted username or password.
 *   TC-4: ok response -> returns access_token from the JSON body.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import type { APIRequestContext } from '@playwright/test'

const ENV_USER = 'KC_ADMIN_USER'
const ENV_PASSWORD = 'KC_ADMIN_PASSWORD'

/** Minimal fake APIRequestContext — only the `.post(url, options)` method
 * `getMasterAdminToken` actually calls. Casts through `unknown` since a real
 * APIRequestContext carries many more methods this test never needs.
 */
function fakeRequest(response: { ok: boolean; status: number; json?: unknown; text?: string }): {
  request: APIRequestContext
  post: ReturnType<typeof vi.fn>
} {
  const post = vi.fn(async () => ({
    ok: () => response.ok,
    status: () => response.status,
    json: async () => response.json,
    text: async () => response.text ?? '',
  }))
  return { request: { post } as unknown as APIRequestContext, post }
}

describe('ISS-0896 — getMasterAdminToken', () => {
  const originalUser = process.env[ENV_USER]
  const originalPassword = process.env[ENV_PASSWORD]

  beforeEach(() => {
    delete process.env[ENV_USER]
    delete process.env[ENV_PASSWORD]
  })

  afterEach(() => {
    if (originalUser === undefined) delete process.env[ENV_USER]
    else process.env[ENV_USER] = originalUser

    if (originalPassword === undefined) delete process.env[ENV_PASSWORD]
    else process.env[ENV_PASSWORD] = originalPassword
  })

  it('TC-1: env vars unset -> POSTs the admin/admin fallback credentials', async () => {
    const { getMasterAdminToken } = await import('../../e2e/helpers')
    const { request, post } = fakeRequest({ ok: true, status: 200, json: { access_token: 'tok' } })

    await getMasterAdminToken(request)

    expect(post).toHaveBeenCalledTimes(1)
    const [, options] = post.mock.calls[0]
    expect(options.form).toMatchObject({
      client_id: 'admin-cli',
      username: 'admin',
      password: 'admin',
      grant_type: 'password',
    })
  })

  it('TC-2: env vars set -> POSTs the env-var credentials, not the fallback', async () => {
    process.env[ENV_USER] = 'real-master-admin'
    process.env[ENV_PASSWORD] = 'real-master-secret'
    const { getMasterAdminToken } = await import('../../e2e/helpers')
    const { request, post } = fakeRequest({ ok: true, status: 200, json: { access_token: 'tok' } })

    await getMasterAdminToken(request)

    const [, options] = post.mock.calls[0]
    expect(options.form.username).toBe('real-master-admin')
    expect(options.form.password).toBe('real-master-secret')
  })

  it('TC-3: non-ok response -> throws, without leaking the attempted username/password', async () => {
    process.env[ENV_USER] = 'leaky-user-marker'
    process.env[ENV_PASSWORD] = 'leaky-password-marker'
    const { getMasterAdminToken } = await import('../../e2e/helpers')
    const { request } = fakeRequest({ ok: false, status: 401, text: 'invalid_grant' })

    let thrown: unknown
    try {
      await getMasterAdminToken(request)
    } catch (err) {
      thrown = err
    }

    expect(thrown).toBeInstanceOf(Error)
    const message = (thrown as Error).message
    expect(message).toContain('401')
    expect(message).not.toContain('leaky-user-marker')
    expect(message).not.toContain('leaky-password-marker')
  })

  it('TC-4: ok response -> returns access_token from the JSON body', async () => {
    const { getMasterAdminToken } = await import('../../e2e/helpers')
    const { request } = fakeRequest({ ok: true, status: 200, json: { access_token: 'the-real-token' } })

    const token = await getMasterAdminToken(request)

    expect(token).toBe('the-real-token')
  })
})
