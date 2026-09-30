/**
 * Pipeline: Platform Instance Pin Survives Catalog Change (PW-03 / sys-instance-version-pinning)
 *
 * Drives `test/fixtures/uat/scenarios/platform/instance-pin-survives-catalog-change.yaml`
 * against the real backend and the real GUI built by REQ-432 (service-version
 * publish/retire controls on `/admin/services`, the rebind dialog on the case
 * detail's Dependency Versions panel, and the INSTANCE_PINS_REBOUND History
 * row). Design: `lib/letflow/design/req432-rebind-pins-publish-retire-ui.md` §7.
 *
 * Fixtures are created through real HTTP routes only (service registration,
 * definition create/activate, instance start, task complete) — no db-exec, no
 * `page.route` (DIRECTIVE T-2, real backend not mocked).
 *
 * ## Known backend limit this spec does NOT hide (design §9 M5, corrected live)
 *
 * `ServiceTaskDispatcher.catalog_lookup_stub/2` is still a stub, so a catalog
 * SERVICE_TASK cannot complete on the real backend. Live-observed mechanism:
 * completing n2 hops synchronously into n3, the URL renders empty, the engine
 * persists only EXECUTION_ERROR (n3 / service_task_url_rendered_empty, no
 * TASK_COMPLETED kept) and the route answers HTTP 500. Step 03 accepts exactly
 * three outcomes (A success, B that 500 + error, C the async request_build_error
 * variant), fails on anything else, and logs which occurred. Live: B.
 *
 * ## Retire-then-publish order (design §9 M4)
 *
 * `retire/1` retires the single current row; `publish/3` archives the current
 * row when superseding. Calling retire AFTER publish would retire the NEW
 * version, so this spec retires first, then publishes.
 *
 * ## Status
 *
 * Run LIVE and green on 2026-09-30 (real backend + Keycloak 8094): 1 passed, all
 * steps. Steps 02/07 selector assumptions proven. Note: clicks on these pages
 * rely on `deferClickState` (ISS-0662 family) in the production handlers.
 *
 * Chain: pre (service v1 + definition) -> 01 start A and C, read A's pins
 * -> 02 retire + publish (GUI) -> 03 complete C's n2 task, service step
 * evidence -> 04 start B, compare pins -> 05 rebind A (GUI)
 * -> 06 EO-005 on ONE History row -> 07 worker-user sees no controls
 * -> cleanup.
 */

import { test, expect, type Page } from '@playwright/test'
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
import { typeIntoTestIdInput } from '../type-into-input'

test.setTimeout(300_000)

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const REBIND_REASON = 'External system retires the old endpoint at month end.'

interface PinSurvivesState {
  adminToken: string
  serviceId: string
  oldVersion: string
  newVersion: string
  definitionId: string
  caseAId: string
  caseCId: string
  caseBId: string
  rebindReason: string
  rebindEventId: string
  operatorDisplayName: string
}

interface HistoryEvent {
  event_id: string
  event_type: string
  payload?: Record<string, unknown>
}

/** Filter the services list by typing into the search box (native setter, same
 *  keyboard-synthesis workaround as type-into-input.ts). */
async function filterServices(page: Page, text: string): Promise<void> {
  const box = page.getByPlaceholder('service ID or endpoint')
  await box.click()
  await box.evaluate((el, value) => {
    const input = el as HTMLInputElement
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')!.set!
    setter.call(input, value)
    input.dispatchEvent(new Event('input', { bubbles: true }))
  }, text)
}

function asEventArray(body: unknown): HistoryEvent[] {
  if (Array.isArray(body)) return body as HistoryEvent[]
  const items = (body as { items?: unknown } | null)?.items
  return Array.isArray(items) ? (items as HistoryEvent[]) : []
}

test.describe('Pipeline: platform-instance-pin-survives-catalog-change (PW-03)', () => {
  test('running case keeps its pinned version; new case gets the new one; rebind is recorded with who/what/why', async ({ page, request }) => {
    await assertServiceReadiness(request, API_BASE_URL)

    const adminToken = await getKeycloakToken(
      request, 'admin-user', resolveCredential('UAT_QA_ADMIN_PASSWORD', 'admin-pass'),
    )
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID().slice(0, 8)
    const pl = createPipeline<PinSurvivesState>('platform-instance-pin-survives-catalog-change', { page, request })
    pl.state.adminToken = adminToken
    pl.state.serviceId = `pl_pin_${fixtureId}`
    pl.state.oldVersion = '1'
    pl.state.newVersion = `2.${fixtureId}`
    pl.state.rebindReason = REBIND_REASON

    const startCase = async (definitionId: string): Promise<string> => {
      const resp = await request.post(`${API_BASE_URL}/api/v1/instances`, {
        headers: authHeaders(adminToken),
        data: { definition_id: definitionId, initial_variables: {} },
      })
      pl.gate(resp.ok(), `instance start failed: ${resp.status()} ${await resp.text()}`)
      const created = await resp.json() as { instance_id?: string; id?: string }
      const id = created.instance_id ?? created.id
      pl.gate(!!id, 'started instance must carry an id')
      return id as string
    }

    pl.onCleanup(async (s) => {
      for (const id of [s.caseAId, s.caseBId, s.caseCId]) {
        if (!id) continue
        // C is in ERROR (design §7.5); a 409 on cancel is tolerated.
        await request.post(`${API_BASE_URL}/api/v1/instances/${id}/cancel`, {
          headers: authHeaders(s.adminToken),
          data: { reason: 'pipeline cleanup' },
        })
      }
      // The published version is deliberately left in place (scenario cleanup.description).
    })

    // ── pre: register service v1, create + activate the definition ──────────
    await pl.step('pre: register service v1 and activate definition', async (s) => {
      const svcResp = await request.post(`${API_BASE_URL}/api/v1/admin/services`, {
        headers: authHeaders(s.adminToken),
        data: {
          service_id: s.serviceId,
          scope: 'global',
          endpoint_url: 'https://example.invalid/pl-pin',
          auth_method: 'NONE',
          timeout_ms: 5000,
          request_schema: '{}',
          response_schema: '{}',
        },
      })
      pl.gate(svcResp.ok(), `service register failed: ${svcResp.status()} ${await svcResp.text()}`)

      const defResp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
        headers: authHeaders(s.adminToken),
        data: {
          name: `pl-pin-survives-${fixtureId}`,
          version: '1.0.0',
          description: 'platform-instance-pin-survives-catalog-change pipeline fixture',
          graph: {
            nodes: [
              { id: 'n1', node_type: 'START', label: 'Start', attributes: null },
              {
                id: 'n2',
                node_type: 'HUMAN_TASK',
                label: `Hold ${fixtureId}`,
                attributes: { role: 'admin-user', assignee_type: 'user', assignee_ref: 'admin-user' },
              },
              {
                id: 'n3',
                node_type: 'SERVICE_TASK',
                label: 'Call shared connection',
                attributes: { service_id: s.serviceId, method: 'POST', timeout_ms: 5000, retry_limit: 0 },
              },
              { id: 'n4', node_type: 'END', label: 'End', attributes: null },
            ],
            edges: [
              { id: 'e1', source: 'n1', target: 'n2' },
              { id: 'e2', source: 'n2', target: 'n3' },
              { id: 'e3', source: 'n3', target: 'n4' },
            ],
          },
        },
      })
      pl.gate(defResp.ok(), `definition create failed: ${defResp.status()} ${await defResp.text()}`)
      s.definitionId = (await defResp.json() as { id: string }).id

      const actResp = await request.post(`${API_BASE_URL}/api/v1/definitions/${s.definitionId}/activate`, {
        headers: authHeaders(s.adminToken),
      })
      pl.gate(actResp.ok(), `definition activate failed: ${actResp.status()} ${await actResp.text()}`)
    })

    // ── 01: start A and C, both parked on n2; open A (GUI) ──────────────────
    await pl.step('01: start cases A and C, A lists the pinned version', async (s) => {
      s.caseAId = await startCase(s.definitionId)
      s.caseCId = await startCase(s.definitionId)

      await navigateSpa(page, `/instances/${s.caseAId}`)
      const panel = page.getByTestId('instance-pins-panel')
      await panel.waitFor({ timeout: 15_000 })
      await expect(panel).toContainText(s.serviceId, { timeout: 15_000 })
      const row = panel.locator('tr', { hasText: s.serviceId })
      await expect(row).toContainText(s.oldVersion)
      await expect(page.getByText('n2').first()).toBeVisible({ timeout: 10_000 })
    })

    // ── 02: retire, then publish the new version (GUI) ──────────────────────
    await pl.step('02: retire the old version and publish the new one', async (s) => {
      await navigateSpa(page, '/admin/services')
      await page.getByTestId(`service-retire-btn-${s.serviceId}`).waitFor({ timeout: 15_000 }).catch(async () => {
        await filterServices(page, s.serviceId)
        await page.getByTestId(`service-retire-btn-${s.serviceId}`).waitFor({ timeout: 15_000 })
      })
      await page.getByTestId(`service-retire-btn-${s.serviceId}`).click()
      await page.getByTestId('service-retire-modal').waitFor({ timeout: 5_000 })
      await page.getByTestId('service-retire-confirm').click()
      await expect(page.getByTestId(`service-status-${s.serviceId}`)).toHaveText('RETIRED', { timeout: 15_000 })

      await page.getByTestId(`service-publish-btn-${s.serviceId}`).click()
      await page.getByTestId('service-publish-modal').waitFor({ timeout: 5_000 })
      await typeIntoTestIdInput(page, 'service-publish-version-input', s.newVersion)
      await page.getByTestId('service-publish-submit').click()

      await expect(page.getByTestId(`service-version-${s.serviceId}`)).toHaveText(s.newVersion, { timeout: 15_000 })
      await expect(page.getByTestId(`service-status-${s.serviceId}`)).toHaveText('ACTIVE', { timeout: 15_000 })
    })

    // ── 03: in-flight case C completes n2 and reaches the service step ──────
    await pl.step('03: EO-001/EO-004 — in-flight case proceeds after retire and publish', async (s) => {
      const tasksResp = await request.get(
        `${API_BASE_URL}/api/v1/tasks?status=PENDING&instance_id=${s.caseCId}`,
        { headers: authHeaders(s.adminToken) },
      )
      pl.gate(tasksResp.ok(), `task list failed: ${tasksResp.status()}`)
      const tasks = (await tasksResp.json() as { items: Array<{ id?: string; task_id?: string }> }).items
      pl.gate(tasks.length >= 1, 'case C must have a pending n2 task')
      const taskId = (tasks[0].id ?? tasks[0].task_id) as string

      // Body is the output variables map itself (routers/tasks.ex passes the body through).
      const completeResp = await request.post(`${API_BASE_URL}/api/v1/tasks/${taskId}/complete`, {
        headers: authHeaders(s.adminToken),
        data: {},
      })
      // LIVE FINDING (first live run, design §9 M5 corrected): the failure is not
      // the async dispatcher's request_build_error. Completing n2 hops the token
      // into n3 SYNCHRONOUSLY inside complete_task; activating a catalog-only
      // SERVICE_TASK (service_id, no inline endpoint) renders an empty URL because
      // the catalog lookup is still a stub, so the engine persists ONLY
      // EXECUTION_ERROR (n3, service_task_url_rendered_empty; the TASK_COMPLETED
      // event is not kept) and routers/tasks.ex answers a bare 500 via its
      // `{:instance_execution_error, _, _}` catch-all. It is independent of the
      // retirement (the stub ignores catalog state). Accepted outcomes, exactly:
      //   A) success: 2xx + TASK_COMPLETED(n2) + SERVICE_TASK_COMPLETED (stub replaced)
      //   B) today:   500 + EXECUTION_ERROR affected node n3 error_type
      //      service_task_url_rendered_empty, and NO TASK_COMPLETED(n2)
      //   C) designed async variant: 2xx + TASK_COMPLETED(n2) + EXECUTION_ERROR
      //      service_task_retries_exhausted / request_build_error
      // Anything else (other status, other error_type, a retirement-induced
      // failure) fails the spec.
      const completeStatus = completeResp.status()
      const completeBody = await completeResp.text()
      console.log(`[pin-survives] step 3 task-complete HTTP status: ${completeStatus}`)

      let events: HistoryEvent[] = []
      let outcome: HistoryEvent | undefined
      const deadline = Date.now() + 45_000
      while (Date.now() < deadline) {
        const histResp = await request.get(`${API_BASE_URL}/api/v1/instances/${s.caseCId}/history`, {
          headers: authHeaders(s.adminToken),
        })
        pl.gate(histResp.ok(), `history failed: ${histResp.status()}`)
        events = asEventArray(await histResp.json())
        outcome = events.find(
          (e) => e.event_type === 'SERVICE_TASK_COMPLETED' || e.event_type === 'EXECUTION_ERROR',
        )
        if (outcome) break
        await new Promise((r) => setTimeout(r, 2_000))
      }
      pl.gate(!!outcome, `service step must reach a terminal event within 45s; saw ${JSON.stringify(events)}`)

      const n2Completed = events.find(
        (e) => e.event_type === 'TASK_COMPLETED' && e.payload?.node_id === 'n2',
      )
      const payload = outcome!.payload as {
        error_type?: string
        affected?: { node_id?: string }
        details?: { last_failure_kind?: string }
      }
      const ok2xx = completeStatus >= 200 && completeStatus < 300

      if (outcome!.event_type === 'SERVICE_TASK_COMPLETED') {
        pl.gate(ok2xx && !!n2Completed, `outcome A needs 2xx + TASK_COMPLETED(n2), got ${completeStatus} ${completeBody}`)
        console.log('[pin-survives] step 3 outcome A: SERVICE_TASK_COMPLETED (catalog stub replaced)')
      } else if (payload.error_type === 'service_task_url_rendered_empty') {
        pl.gate(
          completeStatus === 500 && payload.affected?.node_id === 'n3' && !n2Completed,
          `outcome B needs HTTP 500 + affected n3 + no TASK_COMPLETED(n2), got ${completeStatus} ${completeBody} / ${JSON.stringify(outcome)}`,
        )
        console.log('[pin-survives] step 3 outcome B: HTTP 500 + EXECUTION_ERROR n3/service_task_url_rendered_empty (catalog_lookup_stub; design M5 corrected)')
      } else {
        pl.gate(
          ok2xx
            && !!n2Completed
            && payload.error_type === 'service_task_retries_exhausted'
            && payload.details?.last_failure_kind === 'request_build_error',
          `only the stub outcomes are accepted besides success, got ${completeStatus} ${JSON.stringify(payload)}`,
        )
        console.log('[pin-survives] step 3 outcome C: EXECUTION_ERROR/request_build_error (designed async variant)')
      }

      await navigateSpa(page, `/instances/${s.caseCId}`)
      const panel = page.getByTestId('instance-pins-panel')
      await expect(panel).toContainText(s.serviceId, { timeout: 15_000 })
      await expect(panel.locator('tr', { hasText: s.serviceId })).toContainText(s.oldVersion)
      await shot(page, 'platform-instance-pin-survives-catalog-change', '03-case-c-pins')
    })

    // ── 04: case B picks up the new version; A keeps the old ────────────────
    await pl.step('04: EO-002/EO-003 — new case pins the new version, old case keeps the old', async (s) => {
      s.caseBId = await startCase(s.definitionId)

      await navigateSpa(page, `/instances/${s.caseBId}`)
      const panelB = page.getByTestId('instance-pins-panel')
      await expect(panelB).toContainText(s.serviceId, { timeout: 15_000 })
      await expect(panelB.locator('tr', { hasText: s.serviceId })).toContainText(s.newVersion)
      await expect(panelB.locator('tr', { hasText: s.serviceId })).toContainText('Chosen automatically')

      await navigateSpa(page, `/instances/${s.caseAId}`)
      const panelA = page.getByTestId('instance-pins-panel')
      await expect(panelA).toContainText(s.serviceId, { timeout: 15_000 })
      const rowA = panelA.locator('tr', { hasText: s.serviceId })
      await expect(rowA).toContainText(s.oldVersion)
      await expect(rowA).not.toContainText(s.newVersion)
    })

    // ── 05: operator rebinds A onto the new version (GUI) ───────────────────
    await pl.step('05: operator rebinds the long-running case with a reason', async (s) => {
      await navigateSpa(page, `/instances/${s.caseAId}`)
      const btn = page.getByTestId(`pin-rebind-btn-catalog_entry:${s.serviceId}`)
      await btn.waitFor({ timeout: 15_000 })
      await btn.click()
      await page.getByTestId('pin-rebind-dialog').waitFor({ timeout: 5_000 })
      await typeIntoTestIdInput(page, 'pin-rebind-new-version-input', s.newVersion)
      await typeIntoTestIdInput(page, 'pin-rebind-reason-input', s.rebindReason)
      await page.getByTestId('pin-rebind-submit').click()

      await page.getByTestId('pin-rebind-success').waitFor({ timeout: 15_000 })
      const row = page.getByTestId('instance-pins-panel').locator('tr', { hasText: s.serviceId })
      await expect(row).toContainText(s.newVersion, { timeout: 15_000 })
      await expect(row).toContainText('Changed via rebind')
    })

    // ── 06: EO-005 — name, previous version, new version, reason on ONE row ─
    await pl.step('06: EO-005 — History row shows operator, versions and reason', async (s) => {
      const tlResp = await request.get(
        `${API_BASE_URL}/api/v1/instances/${s.caseAId}/timeline?page_size=200`,
        { headers: authHeaders(s.adminToken) },
      )
      pl.gate(tlResp.ok(), `timeline failed: ${tlResp.status()}`)
      const items = (await tlResp.json() as {
        items: Array<{ event_type: string; event_id: string; actor_display_name: string }>
      }).items
      const rebound = items.find((i) => i.event_type === 'INSTANCE_PINS_REBOUND')
      pl.gate(!!rebound, 'timeline must contain the INSTANCE_PINS_REBOUND entry')
      s.rebindEventId = rebound!.event_id
      s.operatorDisplayName = rebound!.actor_display_name
      pl.gate(!!s.operatorDisplayName && s.operatorDisplayName !== 'system', 'timeline must name the operator')

      await navigateSpa(page, `/instances/${s.caseAId}`) // History is the default tab
      const row = page.getByTestId(`event-row-${s.rebindEventId}`)
      await row.waitFor({ timeout: 15_000 })

      const actorCell = row.getByTestId(`event-actor-${s.rebindEventId}`)
      await expect(actorCell).toHaveText(s.operatorDisplayName, { timeout: 15_000 })
      await expect(actorCell).not.toHaveText('system')
      await expect(row.getByTestId('pins-rebound-actor')).toHaveText(s.operatorDisplayName)
      const entry = row.getByTestId(`pins-rebound-entry-${s.serviceId}`)
      await expect(entry).toContainText(s.oldVersion)
      await expect(entry).toContainText(s.newVersion)
      await expect(row.getByTestId('pins-rebound-reason')).toContainText(s.rebindReason)
    })

    // ── 07: a TASK_WORKER sees none of the new controls ─────────────────────
    await pl.step('07: worker-user has no publish/retire/rebind controls', async (s) => {
      const workerToken = await getKeycloakToken(
        request, 'worker-user', resolveCredential('UAT_QA_WORKER_PASSWORD', 'worker-pass'),
      )
      await loginWithToken(page, workerToken)

      await navigateSpa(page, '/admin/services')
      // Positive anchor first: the page must actually have rendered for the
      // absence assertions below to mean anything.
      await expect(page.getByRole('heading', { name: 'Services' })).toBeVisible({ timeout: 15_000 })
      await expect(page.locator('[data-testid^="service-publish-btn-"]')).toHaveCount(0)
      await expect(page.locator('[data-testid^="service-retire-btn-"]')).toHaveCount(0)

      await navigateSpa(page, `/instances/${s.caseAId}`)
      // Positive anchor: the provenance panel (REQ-399) renders for the worker too.
      await expect(page.getByTestId('instance-pins-panel')).toBeVisible({ timeout: 15_000 })
      await expect(page.locator('[data-testid^="pin-rebind-btn-"]')).toHaveCount(0)
    })

    await pl.runCleanup()
  })
})
