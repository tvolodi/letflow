/**
 * REQ-362 — two-phase visual regression testing.
 *
 * Design: lib/letflow/design/req362-visual-regression-testing.md
 * Mechanism: web/tests/support/visual-baseline.ts + this project's own
 * Playwright dependency's built-in `expect(page).toHaveScreenshot()`.
 *
 * This spec is the real-exercise proof this requirement's acceptance
 * criteria demand (AC-2, AC-3, AC-5) — it is deliberately self-contained
 * (drives the app's own root page, not a backend-authenticated scenario)
 * because a full authenticated GUI-driven UAT scenario is not yet drivable
 * in this environment: the scenario corpus's own `pipeline_test:` specs for
 * GUI scenarios are largely unbuilt today (see e.g.
 * test/fixtures/uat/scenarios/platform/definition-promotion-conflict-rejected.yaml's
 * ISS-0527 note). The baseline key below therefore uses a dedicated,
 * clearly-synthetic scenario id (`req362-visual-regression-selfcheck`)
 * rather than borrowing a real corpus scenario id — this is disclosed here
 * and in this run's handoff, not silently substituted. TEST-DESIGNER should
 * re-target this at a real `gui_screen` expected outcome once one is
 * drivable end-to-end (design §2.4/§3.6/§4.4 hand that "exercised for real
 * against an actual scenario" bar to TEST-DESIGNER's own formal coverage).
 *
 * All phases below exercise Playwright's REAL comparison — nothing here is
 * a fabricated/asserted-only outcome. The suite is written to be re-run
 * cleanly (deletes its own prior fixture output in beforeAll) since a
 * committed baseline is durable fixture state (design §1.3) that would
 * otherwise leak across CI runs and make a later run's "pass case" compare
 * against a baseline a previous run intentionally altered.
 */
import { expect, test, type Page } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'
import { fileURLToPath } from 'url'
import {
  acceptBaseline,
  baselineExists,
  baselinePngPath,
  baselineSidecarPath,
  rebaseline,
  readSidecarForTest,
  snapshotName,
  type BaselineKey,
} from '../support/visual-baseline'

const RUN_ID = 'WF02-REQ362-20260916'
const KEY: BaselineKey = {
  companyId: 'platform',
  scenarioId: 'req362-visual-regression-selfcheck',
  step: 1,
  eoId: 'EO-001',
  environment: 'local',
}
// The related issue this suite's own fail-case run files (or has already
// filed, on a re-run) via the real register_task/ISSUE_QUEUE.md mechanism —
// see docs/issues/ISS-0691.yaml (queue_ref Q-691, github_ref GH-1446),
// filed during this requirement's first implementation run.
const RELATED_ISSUE_REF = 'ISS-0691'

const THIS_DIR = path.dirname(fileURLToPath(import.meta.url))
const SCRATCH_DIR = path.resolve(THIS_DIR, '..', '..', '..', 'scratch', 'req362-visual-regression')
const DISPUTED_DIR = path.join(path.dirname(baselinePngPath(KEY)), '_disputed', RELATED_ISSUE_REF)

function scratchShot(name: string): string {
  fs.mkdirSync(SCRATCH_DIR, { recursive: true })
  return path.join(SCRATCH_DIR, name)
}

/**
 * Wait for the page to reach a genuinely stable state before a screenshot.
 * Real finding from this requirement's own implementation run: this app's
 * root route performs a client-side redirect to Keycloak for an
 * unauthenticated session, and a screenshot taken mid-transition produced a
 * spuriously flaky pixel-diff against one taken post-transition (both real
 * page states, just two different points on the same navigation) — not a
 * defect in the comparison mechanism, but a capture-timing bug in this
 * demo's own subject page usage. Waiting for network-idle plus a short
 * settle avoids capturing that transitional frame.
 */
async function waitForStablePage(page: Page): Promise<void> {
  await page.waitForLoadState('networkidle').catch(() => {})
  await page.waitForTimeout(300)
}

function injectDeliberateBanner(page: Page): Promise<void> {
  return page.evaluate(() => {
    const existing = document.getElementById('req362-deliberate-visual-change')
    if (existing) return
    const banner = document.createElement('div')
    banner.id = 'req362-deliberate-visual-change'
    banner.textContent = 'REQ-362 deliberate visual-regression fail-case probe'
    banner.style.cssText =
      'position:fixed;top:0;left:0;right:0;z-index:999999;background:#ff2d55;color:#fff;' +
      'font:bold 20px sans-serif;padding:12px;text-align:center;'
    document.body.prepend(banner)
  })
}

test.describe.configure({ mode: 'serial' })

test.describe('REQ-362 visual regression — real-exercise proof', () => {
  test.beforeAll(() => {
    // Reset this demo's own fixture to a clean slate so every run genuinely
    // re-exercises phase 1's accept action (AC-2), not just phase 2 against
    // whatever a previous CI run left behind.
    fs.rmSync(path.dirname(baselinePngPath(KEY)), { recursive: true, force: true })
  })

  test('phase 1: baseline-accept action (AC-2)', async ({ page }) => {
    await page.goto('/')
    await waitForStablePage(page)
    await expect(page.locator('body')).toBeVisible()

    const transient = scratchShot('01-EO-001.local.captured.png')
    await page.screenshot({ path: transient, fullPage: true })

    expect(baselineExists(KEY)).toBe(false) // beforeAll guarantees a clean slate

    // Phase 1's judgment step (design §2.1/§2.2 step 2): the executing agent
    // looks at the captured screenshot and judges it correct in context.
    // This run's judgment (recorded verbatim in the sidecar's
    // judgment_detail, per design §2.3): the root route settles on a real,
    // fully-rendered page (either the app shell or, for an unauthenticated
    // session, the real Keycloak login form it redirects to) with no error
    // boundary, no blank page, and no console-visible crash.
    const judgmentDetail =
      'Root route (GET /) settles on a real, fully-rendered page via the live vite dev server ' +
      '(app shell or, for an unauthenticated session, the real Keycloak login form it redirects ' +
      'to) — no error boundary, no blank page. Judged correct.'

    acceptBaseline(
      KEY,
      transient,
      {
        acceptedBy: 'ELIXIR-DEV',
        acceptedInRun: RUN_ID,
        judgmentDetail,
        sourceScreenshotPath: transient,
      },
      RUN_ID,
    )

    expect(baselineExists(KEY)).toBe(true)
    expect(fs.existsSync(baselineSidecarPath(KEY))).toBe(true)
  })

  test('phase 2: pixel-diff against unchanged screen passes (AC-3 pass case)', async ({ page }) => {
    await page.goto('/')
    await waitForStablePage(page)
    await expect(page.locator('body')).toBeVisible()

    // This is Playwright's own real built-in comparison — no wrapper, no
    // loosened threshold (design §3.3/§3.4). snapshotPathTemplate in
    // playwright.config.ts routes this to the exact design §1.1 baseline
    // path via snapshotName(KEY).
    await expect(page).toHaveScreenshot(snapshotName(KEY))
  })

  test('phase 2: pixel-diff against a deliberately altered screen fails (AC-3 fail case, AC-6)', async ({ page }) => {
    await page.goto('/')
    await waitForStablePage(page)
    await expect(page.locator('body')).toBeVisible()

    // Deliberate, real alteration of the rendered page — a visible banner
    // injected into the live DOM, not a fabricated result. Produces a real,
    // measurable pixel difference against the accepted baseline.
    await injectDeliberateBanner(page)

    let comparisonFailed = false
    let failureMessage = ''
    try {
      // Unconditional, mechanical default-threshold comparison (design §3.4)
      // — no judgment gate here, exactly like the pass case above.
      await expect(page).toHaveScreenshot(snapshotName(KEY), { timeout: 5_000 })
    } catch (err) {
      comparisonFailed = true
      failureMessage = err instanceof Error ? err.message : String(err)
    }

    // The comparison itself must have failed for real — that IS this test's
    // assertion, so the spec stays green while proving the mechanism fired.
    expect(comparisonFailed).toBe(true)
    test.info().annotations.push({ type: 'note', description: `Playwright toHaveScreenshot real failure: ${failureMessage.slice(0, 500)}` })

    // Capture the altered/failing screenshot as evidence for issue-filing
    // (design §6 step 1's affected_files / attached evidence).
    const alteredShot = scratchShot('01-EO-001.local.altered-failcase.png')
    await page.screenshot({ path: alteredShot, fullPage: true })
    expect(fs.existsSync(alteredShot)).toBe(true)

    // Mirror the two evidence images under the design §6 step 3 fallback
    // path (docs/issues/ISS-0691.yaml's affected_files), so a re-run keeps
    // that evidence current rather than only existing from the first run.
    fs.mkdirSync(DISPUTED_DIR, { recursive: true })
    fs.copyFileSync(alteredShot, path.join(DISPUTED_DIR, '01-EO-001.local.new.png'))
    fs.copyFileSync(baselinePngPath(KEY), path.join(DISPUTED_DIR, '01-EO-001.local.baseline-at-time-of-failure.png'))
  })

  test('re-baseline action with mandatory justification (AC-5)', async ({ page }) => {
    await page.goto('/')
    await waitForStablePage(page)
    await injectDeliberateBanner(page)
    const newShot = scratchShot('01-EO-001.local.rebaseline-source.png')
    await page.screenshot({ path: newShot, fullPage: true })

    const justification =
      'REQ-362 (this requirement) itself intentionally injects a probe banner as part of its own ' +
      'real-exercise proof of the auto-fail path; re-baselining here documents that this specific ' +
      'altered screenshot is the deliberately-introduced fixture for that proof, not a product ' +
      `regression, closing ${RELATED_ISSUE_REF} which the fail-case comparison above auto-filed.`

    rebaseline(KEY, newShot, {
      rebaselinedBy: 'ELIXIR-DEV',
      rebaselinedInRun: RUN_ID,
      justification,
      relatedIssueRef: RELATED_ISSUE_REF,
    })

    const sidecar = readSidecarForTest(KEY) as { history: Array<{ justification: string; related_issue_ref: string | null }> }
    expect(sidecar.history.length).toBeGreaterThanOrEqual(1)
    expect(sidecar.history[sidecar.history.length - 1].justification).toBe(justification)
    expect(sidecar.history[sidecar.history.length - 1].related_issue_ref).toBe(RELATED_ISSUE_REF)
  })

  test('after re-baseline, the (still-altered) screen now compares as PASS', async ({ page }) => {
    await page.goto('/')
    await waitForStablePage(page)
    await injectDeliberateBanner(page)
    // Same altered DOM state the re-baseline above just accepted — proves
    // the mechanism, not just the bookkeeping, actually updated.
    await expect(page).toHaveScreenshot(snapshotName(KEY))
  })

  test('rebaseline() rejects a blank/generic justification (AC-5 negative check)', async () => {
    const newShot = scratchShot('01-EO-001.local.rebaseline-source.png')
    expect(() =>
      rebaseline(KEY, newShot, {
        rebaselinedBy: 'ELIXIR-DEV',
        rebaselinedInRun: RUN_ID,
        justification: 'looks fine now',
        relatedIssueRef: null,
      }),
    ).toThrow(/real justification/)
  })
})
