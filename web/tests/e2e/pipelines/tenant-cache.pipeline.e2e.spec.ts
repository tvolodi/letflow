/**
 * Pipeline: tenant-switch-cache-isolation (PW-15 / sys-tenant-scoped-client-cache)
 *
 * Drives `test/fixtures/uat/scenarios/platform/tenant-switch-cache-isolation.yaml`'s
 * `pipeline_test:` key for UAT-RUNNER, following this GUI-review sweep's own process:
 * every real screen was read from source before any test was written (see
 * test/uat-reports/gui-review-2026-09-20-tenant-switch-cache-isolation.md for the
 * full trace this spec's scope decisions come from).
 *
 * What the source investigation found, and why this spec covers what it covers:
 *
 *   - EO-001 (mid-session company switch via a selector, without reload) has NO
 *     underlying feature at all — grepped exhaustively, no in-app tenant/company
 *     switcher exists anywhere in web/src (AppShell.tsx doesn't even display the
 *     tenant name). Tenant identity is fixed for the life of an OIDC session
 *     (`tenant_slug` claim on the JWT); changing company requires a fresh sign-in
 *     against a different Keycloak realm, a full browser navigation that destroys
 *     the JS heap (including the React Query cache) by construction. There is
 *     nothing to click, so EO-001 cannot be driven and is not attempted here —
 *     filed as REQ-384. This is a rare case where the scenario fixture's own
 *     "aspirational, unbuilt" NOTE turns out to be correct, not stale.
 *
 *   - EO-002 (signing out leaves nothing behind) IS the real, supported flow —
 *     and a genuine defect was found and fixed in this same change:
 *     `web/src/auth/tenantConfig.ts`'s `bpm_realm_slug` sessionStorage key
 *     (deliberate, OIDC-F-06) was never cleared by `AuthProvider.logout()`,
 *     letting one tenant's realm selection survive into the next sign-in on the
 *     same browser tab. Fixed via `resetTenantConfigCache()`, filed as ISS-0737.
 *     This spec proves the fix holds through a REAL sign-out click, not just the
 *     unit-level coverage in tenantConfig.test.ts / AuthProvider.logout-clears-realm.test.tsx.
 *
 *   - EO-003 (a task shows the form it was created against, not a later published
 *     version) is already satisfied by construction — REQ-126 (status: done) pins
 *     `form_id`/`form_version` from `instance_definition_snapshots.definition_ver`,
 *     frozen at instance-start time, and `TaskActivation.resolve_form_schema/1`
 *     freezes `form_schema` itself onto the `tasks` row at activation time. What
 *     had NOT been verified anywhere was that the real SPA screen (not just the
 *     JSON body, which test/letflow/routers/tasks_test.exs's REQ-126 AC3 test
 *     already covers) renders the pinned fields rather than the newly-promoted
 *     ones. This spec proves that end to end: create v1, start an instance, open
 *     the real Task Inbox screen, promote v2 with different form fields, reopen
 *     the same task and prove the screen still shows v1's fields only.
 *
 *   - EO-004 (explicit "out of date" fallback when a version can't be confirmed)
 *     has no implementation anywhere — filed as REQ-385, since REQ-126's
 *     frozen-at-creation design has no live version-resolution step that could
 *     even fail to confirm a match. Not attempted here; see REQ-385.
 *
 *   - EO-005 (frequently-changing lists refetch on return) already has working,
 *     independently-verified coverage via `usePolling` (interval + visibility-
 *     change refetch, read from source) — out of scope for this spec's own
 *     regression focus (MINOR severity, `suggested_action: none` in the scenario
 *     itself).
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  authHeaders,
  shot,
} from '../pipeline'
import { assertServiceReadiness, resolveCredential } from '../helpers'

const APP_BASE_URL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:4173'
const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'

interface TenantCachePipelineState {
  adminToken: string
  processKey: string
  v1Label: string
  v2FieldLabel: string
  taskId: string
}

test.describe('Pipeline: tenant-switch-cache-isolation (PW-15)', () => {
  test('EO-002: sign-out clears same-tab tenant-selection residue (bpm_realm_slug)', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )

    // Log in FIRST (loginWithToken registers its session-injecting
    // addInitScript, which survives every later navigation on this page,
    // then does its own goto('/')) — an unauthenticated first load would
    // otherwise race ProtectedRoute's own signinRedirect() against the
    // ?realm= navigation below (net::ERR_ABORTED, confirmed while writing
    // this spec). Order doesn't change what's under test: what matters is
    // that bpm_realm_slug survives into the post-login session and is then
    // cleared by logout.
    await loginWithToken(page, adminToken)

    // Seed the same-tab tenant-selection residue exactly the way a real
    // multi-realm login flow does — resolveRealmFromUrl() writes ?realm=
    // into sessionStorage on load (OIDC-F-06). A full page.goto reruns
    // main.tsx from scratch (fresh fetchTenantConfig() call), same as any
    // real full-page navigation; the addInitScript session survives it.
    await page.goto(`${APP_BASE_URL}/?realm=swiftroute-fixture`, { waitUntil: 'domcontentloaded' })
    await expect.poll(() => page.evaluate(() => sessionStorage.getItem('bpm_realm_slug')))
      .toBe('swiftroute-fixture')
    await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 })

    await expect(page.getByTestId('logout-button')).toBeVisible({ timeout: 15_000 })

    // resetTenantConfigCache() runs synchronously as the first lines of
    // AuthProvider.logout() — strictly before the async
    // getOidcManager().then(m => m.signoutRedirect()) chain that eventually
    // navigates the browser off-origin to Keycloak. Read sessionStorage back
    // with a SINGLE, immediate evaluate right after the click — not a
    // polling/retrying assertion — because the subsequent off-origin
    // navigation destroys this page's JS execution context within a couple
    // of ticks (confirmed: an earlier version of this test used
    // expect.poll() here and intermittently hit "Execution context was
    // destroyed, most likely because of a navigation" once the real
    // signoutRedirect() navigation won the race against a slower retry
    // loop). A single evaluate() immediately after click() reliably lands
    // inside the synchronous window before that navigation begins.
    await page.getByTestId('logout-button').click()
    const realmAfterLogout = await page.evaluate(() => sessionStorage.getItem('bpm_realm_slug'))
    expect(realmAfterLogout, 'bpm_realm_slug must be cleared by AuthProvider.logout() before any next sign-in on this tab').toBeNull()
  })

  test('EO-003: a task shows the form it was created against, not a later published version', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )

    const fixtureId = randomUUID().slice(0, 8)
    const processKey = `pl-tenant-cache-form-pin-${fixtureId}`
    const v1Label = `Review ${fixtureId}`
    const v1FieldName = `reviewNotesV1_${fixtureId}`
    const v2FieldName = `approvalDecisionV2_${fixtureId}`

    const pl = createPipeline<TenantCachePipelineState>('tenant-switch-cache-isolation', { page, request })
    pl.state.adminToken = adminToken
    pl.state.processKey = processKey
    pl.state.v1Label = v1Label
    pl.state.v2FieldLabel = v2FieldName

    const graphWithForm = (formSchema: Record<string, unknown>) => ({
      nodes: [
        { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
        {
          id: 'task',
          node_type: 'HUMAN_TASK',
          label: v1Label,
          attributes: {
            role: 'admin-user',
            assignee_type: 'USER',
            form_schema: formSchema,
          },
        },
        { id: 'n3', node_type: 'END', label: 'End', attributes: null },
      ],
      edges: [
        { id: 'e1', source: 'n1', target: 'task' },
        { id: 'e2', source: 'task', target: 'n3' },
      ],
    })

    // ── Step 01: create + activate v1, with a form field unique to v1 ────────
    await pl.step('01: create + activate v1, start an instance, locate the activated task', async (s) => {
      const createResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: {
          name: processKey,
          version: '1.0.0',
          description: 'tenant-switch-cache-isolation EO-003 pipeline fixture (v1)',
          graph: graphWithForm({
            properties: { [v1FieldName]: { type: 'string', title: 'Review Notes (v1)' } },
            required: [],
          }),
        },
      })
      pl.gate(createResp.ok(), `v1 definition create failed: ${createResp.status()} ${await createResp.text()}`)
      const v1 = await createResp.json() as { id: string }

      const activateResp = await request.post(
        `${API_BASE_URL}/api/v1/definitions/${v1.id}/activate`,
        { headers: authHeaders(s.adminToken) },
      )
      pl.gate(activateResp.ok(), `v1 activate failed: ${activateResp.status()} ${await activateResp.text()}`)

      const startResp = await request.post(`${API_BASE_URL}/api/v1/instances`, {
        headers: authHeaders(s.adminToken),
        data: { definition_name: processKey, initial_variables: {} },
      })
      pl.gate(startResp.ok(), `instance start failed: ${startResp.status()} ${await startResp.text()}`)
      const instance = await startResp.json() as { id?: string; instance_id?: string }
      const instanceId = instance.instance_id ?? instance.id
      pl.gate(!!instanceId, 'instance id must be present after start')

      const tasksResp = await request.get(`${API_BASE_URL}/api/v1/tasks`, {
        headers: authHeaders(s.adminToken),
        params: { instance_id: instanceId as string },
      })
      pl.gate(tasksResp.ok(), `task list failed: ${tasksResp.status()} ${await tasksResp.text()}`)
      const tasksBody = await tasksResp.json() as { items: Array<{ id: string; form_version?: string }> }
      pl.gate(tasksBody.items.length === 1, `expected exactly 1 activated task, got ${tasksBody.items.length}`)
      s.taskId = tasksBody.items[0].id
      pl.gate(tasksBody.items[0].form_version === '1.0.0', `expected form_version "1.0.0" right after v1 start, got "${tasksBody.items[0].form_version}"`)
    })

    // ── Step 02: open the real Task Inbox screen — the v1 field renders ──────
    await pl.step('02: EO-003 (before promotion) — Task Inbox renders the v1 field', async (s) => {
      await loginWithToken(page, s.adminToken)
      await navigateSpa(page, '/tasks')

      const row = page.getByTestId('task-row').filter({ has: page.getByTestId('task-name').getByText(v1Label) })
      await expect(row).toBeVisible({ timeout: 15_000 })
      await row.click()

      await expect(page.getByTestId('task-detail-panel')).toBeVisible()
      await expect(page.getByTestId(`form-field-${v1FieldName}`)).toBeVisible({ timeout: 10_000 })
      await expect(page.getByTestId(`form-field-${v2FieldName}`)).toHaveCount(0)

      await shot(page, 'tenant-switch-cache-isolation', 'eo003-v1-form-before-promotion')
    })

    // ── Step 03: promote v2 under the SAME process name with a DIFFERENT form ──
    await pl.step('03: activate v2 (same process name, different form field)', async (s) => {
      const createV2Resp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: {
          name: processKey,
          version: '2.0.0',
          description: 'tenant-switch-cache-isolation EO-003 pipeline fixture (v2)',
          graph: graphWithForm({
            properties: { [v2FieldName]: { type: 'string', title: 'Approval Decision (v2)' } },
            required: [],
          }),
        },
      })
      pl.gate(createV2Resp.ok(), `v2 definition create failed: ${createV2Resp.status()} ${await createV2Resp.text()}`)
      const v2 = await createV2Resp.json() as { id: string }

      const activateV2Resp = await request.post(
        `${API_BASE_URL}/api/v1/definitions/${v2.id}/activate`,
        { headers: authHeaders(s.adminToken) },
      )
      pl.gate(activateV2Resp.ok(), `v2 activate failed: ${activateV2Resp.status()} ${await activateV2Resp.text()}`)
    })

    // ── Step 04: the SAME already-open task must still show v1's field only ──
    await pl.step('04: EO-003 (after promotion) — the same task still shows only the v1 field', async (s) => {
      // Force a real refetch, not a stale in-memory render — reload the SPA
      // route so useTaskInbox/useTask re-query the backend from scratch.
      await page.reload({ waitUntil: 'domcontentloaded' })

      const row = page.getByTestId('task-row').filter({ has: page.getByTestId('task-name').getByText(v1Label) })
      await expect(row).toBeVisible({ timeout: 15_000 })
      await row.click()

      await expect(page.getByTestId('task-detail-panel')).toBeVisible()
      // The pin must hold: still v1's field, never v2's — proving the SPA
      // renders task.form_schema (frozen at activation) and never silently
      // re-resolves against the now-current process_definitions row.
      await expect(page.getByTestId(`form-field-${v1FieldName}`)).toBeVisible({ timeout: 10_000 })
      await expect(page.getByTestId(`form-field-${v2FieldName}`)).toHaveCount(0)

      // And the API body itself still names v1 — belt-and-braces against the
      // exact regression REQ-126 AC3 exists to prevent.
      const taskResp = await page.request.get(`${API_BASE_URL}/api/v1/tasks/${s.taskId}`, {
        headers: authHeaders(s.adminToken),
      })
      const taskBody = await taskResp.json() as { form_version?: string }
      expect(taskBody.form_version).toBe('1.0.0')

      await shot(page, 'tenant-switch-cache-isolation', 'eo003-v1-form-after-v2-promotion')
    })
  })
})
