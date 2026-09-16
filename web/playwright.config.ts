import { defineConfig, devices } from '@playwright/test'

const baseURL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:4173'
// Derive the dev-server port from baseURL so the spawned server and the tests
// always agree — overriding E2E_BASE_URL alone would otherwise start the server
// on the default port while the tests hit the overridden one.
const e2ePort = new URL(baseURL).port || '4173'

export default defineConfig({
  testDir: './tests/e2e',
  testMatch: '**/*.e2e.spec.ts',
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: [['list']],
  // REQ-362: route every expect(page).toHaveScreenshot() reference image to
  // this project's own UAT visual-baseline convention (design §1.1) instead
  // of Playwright's default <test file>-snapshots/ layout (design §3.2's
  // "Chosen" reconciliation option). `{arg}` is whatever name string the
  // call site passes (see tests/support/visual-baseline.ts's snapshotName())
  // and already encodes company/scenario/step/EO/environment, so no further
  // segments are added here. No other spec in this project calls
  // toHaveScreenshot today (verified via `grep -rn toHaveScreenshot
  // tests/e2e` — zero hits before this requirement), so this is a safe,
  // project-wide default rather than a narrowly-scoped override.
  snapshotPathTemplate: '../test/fixtures/uat/visual-baselines/{arg}{ext}',
  use: {
    baseURL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  webServer: {
    command: `npm run dev -- --host 127.0.0.1 --port ${e2ePort}`,
    url: baseURL,
    reuseExistingServer: true,
    timeout: 120_000,
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
})
