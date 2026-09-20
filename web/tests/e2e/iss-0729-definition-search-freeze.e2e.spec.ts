/**
 * E2E regression guard — ISS-0729: intermittent main-thread freeze reachable
 * via DefinitionListPage.tsx's debounced search shortly after navigation, in
 * dev/StrictMode only.
 *
 * Fix design: lib/letflow/design/iss-0729-definitionlistpage-search-freeze-fix.md
 *
 * EMPIRICAL TRAIL (per that design's §3 protocol, and this project's No
 * Speculation rule — docs/agents/instructions/core-directives.md):
 *
 * An initial attempt to run §3's protocol produced a false negative: 80
 * repro attempts (raw Playwright-driver script x2, `npx playwright test`
 * sequential x20, 4-worker-concurrent x5, headed-under-Xvfb x15) all came
 * back 0/N hangs. That result was itself wrong, not a real "cannot
 * reproduce" finding — a `VITE_API_BASE_URL` override used to start this
 * environment's dev server got inlined into the client bundle (Vite exposes
 * all `VITE_*` vars to `import.meta.env`), which made the browser call the
 * backend cross-origin instead of through Vite's dev proxy, so every API
 * call was CORS-blocked and the definitions list/search never actually
 * rendered — the freeze's own trigger path was never reached. Once the dev
 * server was restarted without that override (default same-origin proxying,
 * `NODE_OPTIONS=--dns-result-order=ipv4first` only to route around an
 * unrelated `localhost`→`::1` resolution quirk in this sandbox), the freeze
 * reproduced **20/20 (100%)** on the real Playwright-driver harness, each
 * hang confirmed CPU-pegged (106-138%, sampled every second across a 30s
 * window) rather than idle-blocked, matching the issue's own report.
 *
 * Design §3 Step 1 (H1 — defer the search input's `setSearch` call by one
 * macrotask, same mechanism as `deferClickState`, which ISS-0662 confirmed
 * for click/keyboard discrete events) was then applied to
 * `DefinitionListPage.tsx`'s `onChange` handler and re-run against the same
 * N=20 harness: **0/20 hangs**, healthy ~1.6-1.7s interaction time
 * throughout. Per the design's own stopping criterion ("0/20 hangs → H1
 * confirmed as sufficient. Stop here, this is the fix."), H2/H3/H4 were not
 * needed — H1 alone eliminated the freeze. `useDebounce.ts` and `main.tsx`
 * were left unchanged.
 *
 * A naive first version of H1 (calling `deferClickState(() =>
 * setSearch(value))` directly per keystroke, still on a *controlled* input)
 * introduced its own real correctness regression, caught empirically by
 * running this exact test with `--repeat-each`, not by inspection: under
 * fast real typing, React re-syncing the controlled `value` prop to an
 * earlier, shorter `search` state once a deferred flush finally landed could
 * stomp on characters the user had already typed live in the DOM, silently
 * dropping one (observed in 1/5, then 2/10 repeat runs). Coalescing the
 * deferred flushes reduced but did not eliminate this. The shipped fix
 * instead makes the input **uncontrolled** (`defaultValue`, no `value=`
 * prop) — nothing else in this component reads `search` for display, so the
 * DOM is free to be the sole source of truth for what's shown, and the
 * coalesced deferred `setSearch` only ever feeds the downstream debounced
 * query, never the input's own displayed value. Re-verified clean across
 * 20+20+15 repeat-each runs post-fix: 0 freezes, 0 dropped/corrupted
 * characters.
 *
 * This test file is the permanent regression guard per §5's second bullet.
 * Given the pre-fix rate was measured at 100% in this environment (not just
 * the issue's originally-reported 60-80%), a single green run here is
 * unusually strong evidence by this project's own standard, but TEST-RUNNER/
 * whoever re-verifies this fix should still not treat one CI pass as
 * absolute proof — rerun in a loop if a future regression is suspected, same
 * reasoning ISS-0662's own test file states.
 *
 * DELIBERATE EXCEPTION to the general e2e convention: this spec targets
 * `npm run dev` (StrictMode active), not `build && preview`. ISS-0296's own
 * resolution says to prefer build+preview for e2e stability in general; this
 * one test is a commented, deliberate inversion of that rule because
 * ISS-0729 is specifically dev/StrictMode-only — a preview-mode run of this
 * test would prove nothing about this issue's trigger condition. If this
 * test is ever pointed at preview mode "for consistency," it stops testing
 * anything for ISS-0729.
 */

import { test, expect } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

// Generous above the ~1.6-1.7s a healthy post-fix interaction took in this
// environment's own empirical trail above; tight enough that a genuine
// sustained freeze (CPU-pegged, per the issue's own report, and confirmed
// >15s in this investigation's baseline runs) reliably trips it, matching
// the reasoning ISS-0662's own bounded-click test used.
const BOUND_MS = 5_000

test.describe('ISS-0729 — DefinitionListPage debounced-search freeze regression', () => {
  let token: string

  test.beforeAll(async ({ request }) => {
    token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
  })

  test('TC-ISS-0729-01: real per-keystroke typing into the search box, immediately after navigation, does not freeze the renderer', async ({ page }) => {
    await loginWithToken(page, token)
    await page.goto('/definitions', { waitUntil: 'domcontentloaded' })

    const searchInput = page.getByTestId('definition-search')
    await expect(searchInput).toBeVisible({ timeout: 15_000 })

    // Real per-character gesture (NOT .fill()) — matches the design doc's
    // §3 protocol reasoning: a single-shot .fill() dispatches one `input`
    // event rather than one per character, and did not reproduce the
    // per-keystroke race during this investigation's own harness work.
    const start = Date.now()
    await searchInput.click()
    await searchInput.pressSequentially('zzz-no-match-query', { delay: 20, timeout: BOUND_MS })
    await expect(searchInput).toHaveValue('zzz-no-match-query', { timeout: BOUND_MS })

    // Guards against the interaction merely "not throwing" while the debounced
    // effect never actually lands: wait for the debounce (300ms) + fetch to
    // settle into a visible end state (either real results or the empty-state
    // text referencing the typed query), bounded so a genuine freeze here
    // trips this assertion too, not just the typing above.
    const settled = page.getByTestId('empty-state').or(page.locator('[data-testid^="def-name-"]').first())
    await expect(settled).toBeVisible({ timeout: BOUND_MS })

    const deltaMs = Date.now() - start
    expect(deltaMs, `search interaction took ${deltaMs}ms, expected under ${BOUND_MS}ms`).toBeLessThan(BOUND_MS)
  })
})
