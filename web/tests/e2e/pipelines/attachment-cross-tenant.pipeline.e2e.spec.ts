/**
 * Pipeline: attachment-cross-tenant-probe (PW-09)
 *
 * Drives `test/fixtures/uat/scenarios/platform/attachment-cross-tenant-probe.yaml`'s
 * `pipeline_test:` key for UAT-RUNNER. Built per
 * `lib/letflow/design/req387-attachment-document-viewer.md` §4, following the
 * structural precedent `tenant-cache.pipeline.e2e.spec.ts` already established
 * for this suite (createPipeline/pl.step/pl.gate, real second-tenant
 * provisioning, navigateSpa, loginWithToken, shot).
 *
 * Two genuinely separate tenants are provisioned for real (own Keycloak
 * realm, own Postgres schema, real synchronous onboarding) — no seeded
 * "swiftroute"/"vortex" fixture tenant exists anywhere in this repo
 * (grepped `priv/keycloak/realms/*.json` and every existing e2e spec: only
 * `bpm-default` is pre-seeded), so both are onboarded fresh here, uniquely
 * named per run via `fixtureId`.
 *
 * SwiftRoute needs TWO distinct logged-in users (dispatcher + ops, matching
 * the scenario's own two-actor split within one company) — REQ-384's
 * onboarding path provisions exactly one admin user per tenant and ships no
 * HTTP route to add a second Keycloak user to an existing realm, so a second
 * user is created directly via the Keycloak Admin REST API
 * (`POST /admin/realms/:realm/users`), with the SAME realm-role mappings as
 * the onboarded admin user copied onto it (role names are this deployment's
 * own detail, not hard-coded here) so it carries the same `:AttachmentsRead`/
 * `:AttachmentsManage` permissions without needing to know their names.
 *
 * EXPIRY (step 4): REQ-386's `AttachmentLinks.issue/3` `opts[:now]` clock
 * injection is Elixir-internal only — not reachable over HTTP (design §4
 * step 4 / §9 OQ-3) — so this spec pays a real ~300s wait for the shipped
 * `@link_expiry_seconds` to elapse, inside a generous `test.setTimeout`, the
 * same real-time cost class this suite's own tenant-onboarding specs already
 * accept. If that proves too expensive for CI, REQ-386 would need a
 * follow-up test-only expiry override (design §9 OQ-3) — not invented here.
 */

import { test, expect, type APIRequestContext } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  authHeaders,
  jwtSubject,
  shot,
} from '../pipeline'
import { assertServiceReadiness, resolveCredential, BPM_IDP_BASE_URL } from '../helpers'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'

// A minimal, valid single-page PDF — enough for AttachmentSuccessView's
// `contentType.startsWith('application/pdf')` branch to render an <iframe>.
const MINIMAL_PDF_BYTES = Buffer.from(
  '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n' +
  '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF',
  'utf-8',
)
const FIXTURE_FILE_NAME = 'delivery-note-hamburg.pdf'

interface PipelineState {
  fixtureId: string
  masterToken: string

  swiftrouteSlug: string
  swiftrouteTenantId: string
  dispatcherToken: string
  opsToken: string

  vortexSlug: string
  vortexTenantId: string
  vortexToken: string

  processDefName: string
  swiftrouteInstanceId: string
  swiftrouteAttachmentId: string

  expiredLinkUrl: string
}

/** Get a Keycloak master-realm admin token (docker-compose default creds,
 *  same technique tenant-cache.pipeline.e2e.spec.ts's own cleanup uses). */
async function getMasterAdminToken(request: APIRequestContext): Promise<string> {
  const resp = await request.post(`${BPM_IDP_BASE_URL}/realms/master/protocol/openid-connect/token`, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    form: { client_id: 'admin-cli', username: 'admin', password: 'admin', grant_type: 'password' },
  })
  if (!resp.ok()) {
    throw new Error(`Keycloak master token request failed: ${resp.status()} ${await resp.text()}`)
  }
  return ((await resp.json()) as { access_token: string }).access_token
}

/** Onboard a fresh, genuinely separate tenant via the real
 *  `POST /api/v1/onboarding` saga (own Keycloak realm, own Postgres schema,
 *  provisioned+migrated synchronously — same shape tenant-cache.pipeline's
 *  own EO-001 step 02 already established, minus the `tenant_type: 'test'`
 *  branch, which this spec doesn't need). Returns the new tenant's id/slug
 *  and a real Keycloak token for its admin user, obtained the same
 *  reset-password + password-grant technique env04.e2e.spec.ts's
 *  `onboardTestTenantFixture` already established. */
async function onboardTenantWithAdminToken(
  request: APIRequestContext,
  bpmAdminToken: string,
  masterToken: string,
  slug: string,
  displayName: string,
): Promise<{ tenantId: string; adminToken: string; adminUserId: string; adminUsername: string; adminPassword: string }> {
  const adminUsername = `${slug}-admin`
  const adminPassword = `TestPass1!${slug}`

  const onboardResp = await request.post(`${API_BASE_URL}/api/v1/onboarding`, {
    headers: {
      Authorization: `Bearer ${bpmAdminToken}`,
      'Content-Type': 'application/json',
      'Idempotency-Key': randomUUID(),
    },
    data: {
      slug,
      display_name: displayName,
      admin_email: `${adminUsername}@example.com`,
      admin_username: adminUsername,
      admin_display_name: `${displayName} Admin`,
      hostname: `${slug}.example.com`,
    },
  })
  if (!onboardResp.ok()) {
    throw new Error(`onboarding ${slug} failed: ${onboardResp.status()} ${await onboardResp.text()}`)
  }
  // Letflow.Routers.Onboarding.handle_create/1 provisions+migrates
  // SYNCHRONOUSLY within this one POST (confirmed by tenant-cache.pipeline's
  // own step 02 comment, re-checked here) -- no onboarding_id poll needed.
  const onboardBody = (await onboardResp.json()) as { tenant_id?: string; admin_user_id?: string }
  if (!onboardBody.tenant_id) {
    throw new Error(`onboarding ${slug} response missing tenant_id: ${JSON.stringify(onboardBody)}`)
  }
  const tenantId = onboardBody.tenant_id
  const adminUserId = onboardBody.admin_user_id ?? ''

  if (!adminUserId) {
    throw new Error(`onboarding ${slug} response missing admin_user_id, needed for password reset`)
  }

  const resetResp = await request.put(
    `${BPM_IDP_BASE_URL}/admin/realms/${slug}/users/${adminUserId}/reset-password`,
    {
      headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
      data: { type: 'password', value: adminPassword, temporary: false },
    },
  )
  if (resetResp.status() !== 204) {
    throw new Error(`password reset for ${slug} admin failed: ${resetResp.status()} ${await resetResp.text()}`)
  }

  const adminToken = await getKeycloakToken(request, adminUsername, adminPassword, slug)
  return { tenantId, adminToken, adminUserId, adminUsername, adminPassword }
}

/** Create a SECOND Keycloak user in an already-onboarded tenant's realm,
 *  copying the first (admin) user's realm-role mappings verbatim so it
 *  carries the same platform-role permissions (:AttachmentsRead included)
 *  without this file needing to know this deployment's real role names.
 *  No HTTP route in this codebase creates a second user in an existing
 *  tenant realm (REQ-384's onboarding provisions exactly one) -- this is
 *  the Keycloak-admin-API equivalent of tenant-cache.pipeline's own
 *  direct-SQL techniques for a gap with no HTTP writer. */
async function createSecondRealmUser(
  request: APIRequestContext,
  masterToken: string,
  realm: string,
  firstAdminUserId: string,
  username: string,
  password: string,
): Promise<string> {
  const createResp = await request.post(`${BPM_IDP_BASE_URL}/admin/realms/${realm}/users`, {
    headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
    data: {
      username,
      email: `${username}@example.com`,
      enabled: true,
      emailVerified: true,
      firstName: 'Ops',
      lastName: 'User',
    },
  })
  if (!createResp.ok()) {
    throw new Error(`create second realm user ${username} failed: ${createResp.status()} ${await createResp.text()}`)
  }
  const location = createResp.headers()['location'] ?? ''
  const newUserId = location.split('/').pop() ?? ''
  if (!newUserId) {
    throw new Error(`create second realm user ${username}: could not extract user id from Location header`)
  }

  const resetResp = await request.put(`${BPM_IDP_BASE_URL}/admin/realms/${realm}/users/${newUserId}/reset-password`, {
    headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
    data: { type: 'password', value: password, temporary: false },
  })
  if (resetResp.status() !== 204) {
    throw new Error(`password set for ${username} failed: ${resetResp.status()} ${await resetResp.text()}`)
  }

  const roleMappingsResp = await request.get(
    `${BPM_IDP_BASE_URL}/admin/realms/${realm}/users/${firstAdminUserId}/role-mappings/realm`,
    { headers: { Authorization: `Bearer ${masterToken}` } },
  )
  if (roleMappingsResp.ok()) {
    const roles = await roleMappingsResp.json()
    if (Array.isArray(roles) && roles.length > 0) {
      await request.post(`${BPM_IDP_BASE_URL}/admin/realms/${realm}/users/${newUserId}/role-mappings/realm`, {
        headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
        data: roles,
      })
    }
  }

  return newUserId
}

async function deleteRealmBestEffort(request: APIRequestContext, masterToken: string, realm: string): Promise<void> {
  try {
    await request.delete(`${BPM_IDP_BASE_URL}/admin/realms/${realm}`, {
      headers: { Authorization: `Bearer ${masterToken}` },
    })
  } catch { /* best-effort cleanup only */ }
}

test.describe('Pipeline: attachment-cross-tenant-probe (PW-09)', () => {
  test('EO-001..EO-004: cross-tenant not-found folding, expiry, and fresh-link recovery through the real GUI', async ({ page, request }) => {
    // Two real tenant onboardings (own realm + own schema each) plus a real
    // ~300s expiry wait -- generous budget, same class of cost
    // tenant-cache.pipeline.e2e.spec.ts's own EO-001 test already accepts.
    test.setTimeout(600_000)

    await assertServiceReadiness(request, API_BASE_URL)

    const fixtureId = randomUUID().slice(0, 8)
    const pl = createPipeline<PipelineState>('attachment-cross-tenant-probe', { page, request })
    pl.state.fixtureId = fixtureId
    pl.state.swiftrouteSlug = `req387-swiftroute-${fixtureId}`
    pl.state.vortexSlug = `req387-vortex-${fixtureId}`
    pl.state.processDefName = `req387-shipment-approval-${fixtureId}`

    pl.onCleanup(async (s) => {
      if (!s.masterToken) return
      if (s.swiftrouteSlug) await deleteRealmBestEffort(request, s.masterToken, s.swiftrouteSlug)
      if (s.vortexSlug) await deleteRealmBestEffort(request, s.masterToken, s.vortexSlug)
    })

    await pl.step('01: onboard SwiftRoute and Vortex, each a genuinely separate tenant', async (s) => {
      const bpmAdminToken = await getKeycloakToken(
        request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
      )
      s.masterToken = await getMasterAdminToken(request)

      const swiftroute = await onboardTenantWithAdminToken(
        request, bpmAdminToken, s.masterToken, s.swiftrouteSlug, `SwiftRoute Fixture ${fixtureId}`,
      )
      s.swiftrouteTenantId = swiftroute.tenantId
      s.dispatcherToken = swiftroute.adminToken

      const opsUsername = `${s.swiftrouteSlug}-ops`
      const opsPassword = `TestPass1!${s.swiftrouteSlug}ops`
      // sub of the already-obtained dispatcher token -- avoids a second
      // Keycloak admin lookup-by-username round trip just to find the first
      // admin user's id.
      const dispatcherUserId = jwtSubject(s.dispatcherToken)
      await createSecondRealmUser(
        request, s.masterToken, s.swiftrouteSlug, dispatcherUserId, opsUsername, opsPassword,
      )
      s.opsToken = await getKeycloakToken(request, opsUsername, opsPassword, s.swiftrouteSlug)

      const vortex = await onboardTenantWithAdminToken(
        request, bpmAdminToken, s.masterToken, s.vortexSlug, `Vortex Fixture ${fixtureId}`,
      )
      s.vortexTenantId = vortex.tenantId
      s.vortexToken = vortex.adminToken

      pl.gate(!!s.dispatcherToken && !!s.opsToken && !!s.vortexToken, 'all three actor tokens must be obtained')
    })

    await pl.step('02: seed a shipment-approval definition and start an instance in SwiftRoute', async (s) => {
      const defResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.dispatcherToken),
        data: {
          name: s.processDefName,
          version: '1.0.0',
          description: `REQ-387 shipment approval fixture ${s.fixtureId}`,
          graph: {
            nodes: [
              { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
              {
                id: 'n2',
                node_type: 'HUMAN_TASK',
                label: 'Shipment Approval',
                attributes: { role: 'admin-user', assignee_type: 'user', assignee_ref: s.swiftrouteSlug + '-admin' },
              },
              { id: 'n3', node_type: 'END', label: 'End', attributes: null },
            ],
            edges: [
              { id: 'e1', source: 'n1', target: 'n2' },
              { id: 'e2', source: 'n2', target: 'n3' },
            ],
          },
        },
      })
      pl.gate(defResp.ok(), `definition create failed: ${defResp.status()} ${await defResp.text()}`)
      const defBody = (await defResp.json()) as { id: string }

      const startResp = await request.post(`${API_BASE_URL}/api/v1/instances`, {
        headers: authHeaders(s.dispatcherToken),
        data: { definition_id: defBody.id, correlation_key: `req387-${s.fixtureId}` },
      })
      pl.gate(startResp.ok(), `instance start failed: ${startResp.status()} ${await startResp.text()}`)
      const startBody = (await startResp.json()) as { instance_id?: string; id?: string }
      s.swiftrouteInstanceId = startBody.instance_id ?? startBody.id ?? ''
      pl.gate(!!s.swiftrouteInstanceId, 'instance start response must include an id')
    })

    // ── Step 1 (scenario step 1): SwiftRoute dispatcher attaches the
    // delivery note via the real AttachmentPanel UI, captures the reference
    // the screen shows. ──────────────────────────────────────────────────
    await pl.step('03: dispatcher attaches the delivery note via the real upload UI', async (s) => {
      await loginWithToken(page, s.dispatcherToken)
      await navigateSpa(page, `/instances/${s.swiftrouteInstanceId}`)

      await expect(page.getByTestId('attachment-panel')).toBeVisible({ timeout: 15_000 })
      await page.getByTestId('attachment-file-input').setInputFiles({
        name: FIXTURE_FILE_NAME,
        mimeType: 'application/pdf',
        buffer: MINIMAL_PDF_BYTES,
      })
      await page.getByTestId('attachment-upload-button').click()

      const viewLink = page.getByTestId('attachment-view-link').first()
      await expect(viewLink).toBeVisible({ timeout: 15_000 })
      const href = await viewLink.getAttribute('href')
      pl.gate(!!href, 'uploaded attachment row must have a View link href')
      const parts = (href ?? '').split('/').filter(Boolean)
      // .../instances/:id/attachments/:attachmentId
      s.swiftrouteAttachmentId = parts[parts.length - 1]
      pl.gate(!!s.swiftrouteAttachmentId, 'attachment id must be extractable from the View link href')

      await shot(page, 'attachment-cross-tenant-probe', 'dispatcher-uploaded')
    })

    // ── Step 2 (scenario step 2, EO-001/EO-002): Vortex user opens the
    // foreign reference. ─────────────────────────────────────────────────
    let step2Text = ''
    await pl.step('04: Vortex user opens the SwiftRoute reference directly -- sees the not-found screen', async (s) => {
      await loginWithToken(page, s.vortexToken)
      await navigateSpa(page, `/instances/${s.swiftrouteInstanceId}/attachments/${s.swiftrouteAttachmentId}`)

      await expect(page.getByTestId('attachment-not-found')).toBeVisible({ timeout: 15_000 })
      step2Text = (await page.getByTestId('attachment-not-found').innerText()) ?? ''
      await shot(page, 'attachment-cross-tenant-probe', 'foreign-tenant-attachment')

      const bodyText = await page.locator('body').innerText()
      expect(bodyText).not.toContain(FIXTURE_FILE_NAME)
      // byte_size of MINIMAL_PDF_BYTES -- assert its digit sequence never
      // appears anywhere on the page either (EO-002's "no size" clause).
      expect(bodyText).not.toContain(String(MINIMAL_PDF_BYTES.length))
    })

    // ── Step 3 (scenario step 3, EO-001): Vortex user opens a never-issued
    // reference -- byte-identical screen, direct string equality. ──────────
    await pl.step('05: Vortex user opens a never-issued reference -- byte-identical to step 2', async () => {
      await navigateSpa(page, `/instances/${randomUUID()}/attachments/${randomUUID()}`)

      await expect(page.getByTestId('attachment-not-found')).toBeVisible({ timeout: 15_000 })
      const step3Text = (await page.getByTestId('attachment-not-found').innerText()) ?? ''
      await shot(page, 'attachment-cross-tenant-probe', 'never-issued-attachment')

      // The core EO-001 assertion: direct string equality, not "both show an
      // error" (design §5 / AC3's own literal wording).
      expect(step3Text).toBe(step2Text)
    })

    // ── Step 4 (scenario step 4, EO-003/EO-004 first half): SwiftRoute ops
    // opens the real document, then reuses the link after real expiry. ─────
    await pl.step('06: ops opens the real document on first attempt', async (s) => {
      await loginWithToken(page, s.opsToken)
      await navigateSpa(page, `/instances/${s.swiftrouteInstanceId}/attachments/${s.swiftrouteAttachmentId}`)

      await expect(page.getByTestId('attachment-content')).toBeVisible({ timeout: 15_000 })
      await shot(page, 'attachment-cross-tenant-probe', 'ops-first-open')

      const url = page.url()
      pl.gate(url.includes('link_token='), 'the page URL must carry the rewritten link_token query param (design §3.2 step 2)')
      s.expiredLinkUrl = url
    })

    await pl.step('07: wait for the real ~300s link expiry, then reuse the same link', async (s) => {
      // REQ-386's @link_expiry_seconds is 300s (design §0/§2.1); wait a
      // margin past it. No test-only clock injection is reachable over HTTP
      // (design §9 OQ-3) -- this is a real wait, not a mock.
      await page.waitForTimeout(310_000)

      await page.goto(s.expiredLinkUrl, { waitUntil: 'domcontentloaded' })

      await expect(page.getByTestId('attachment-link-expired')).toBeVisible({ timeout: 15_000 })
      await shot(page, 'attachment-cross-tenant-probe', 'ops-expired-link')
      await expect(page.getByTestId('attachment-content')).not.toBeVisible()
    })

    // ── Step 5 (scenario step 5, EO-004 second half): fresh link works. ────
    await pl.step('08: requesting a fresh link succeeds', async () => {
      await page.getByTestId('attachment-request-fresh-link').click()

      await expect(page.getByTestId('attachment-content')).toBeVisible({ timeout: 15_000 })
      await shot(page, 'attachment-cross-tenant-probe', 'ops-fresh-link')
    })

    // EO-005 (audit trail) is NOT re-verified here -- REQ-388 (status: done)
    // already ships and independently tests the audit write on the denied
    // branches server-side; steps 04/05 above incidentally exercise those
    // same denied branches, a reasonable side-confirmation but not this
    // spec's own assertion target (design §4, explicit scope statement).

    await pl.runCleanup()
  })
})
