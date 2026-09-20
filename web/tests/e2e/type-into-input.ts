import type { Page } from '@playwright/test'

/**
 * Sets a text input's value without CDP keyboard-event synthesis.
 *
 * Works around a SANDBOX-LEVEL environment limitation discovered while
 * validating the ISS-0739 fix, unrelated to any application bug:
 * `Locator.fill()`, `.pressSequentially()`, and even `page.keyboard.insertText()`
 * all hang indefinitely (well past their own timeouts) on EVERY text input in
 * this sandbox's Playwright/Chromium build — reproduced on
 * `instance-definition-filter` (unrelated page state, no dialog) and
 * `start-correlation-key` (a plain input with no `list` attribute, wired to a
 * trivial `setStartCorrelationKey` handler untouched by that fix) — proving
 * this sandbox's Chromium cannot complete CDP keyboard-event dispatch at all,
 * independent of which input, which handler, or which fix state is active.
 * Confirmed again for `start-definition-name` while diagnosing REQ-371's
 * `platform-definition-promotion-rollback.pipeline.e2e.spec.ts` step 02 — the
 * hang reproduced with a non-matching value and no app-state cascade, isolating
 * it purely to the `.fill()`/`.pressSequentially()` primitive itself.
 *
 * `Locator.click()` (a pure mouse action) resolves normally in ~100ms, and
 * setting the DOM value via the native input-value setter + a real
 * `bubbles: true` `input` Event (exactly what a real keystroke would
 * dispatch to React) resolves in ~15ms and IS observed by React's
 * `onChange` exactly as a real keystroke would be. This is a keyboard-
 * synthesis workaround for this sandbox only; it changes nothing about how
 * the real trusted-gesture mouse-click assertions elsewhere exercise the app.
 *
 * Kept in a plain (non-`*.e2e.spec.ts`) module deliberately, not inlined in
 * or re-exported across spec files — Playwright's `testMatch` treats every
 * `*.e2e.spec.ts` file as an independent top-level test entry, so importing
 * one spec file from another would re-run its `test()`/`test.describe()`
 * registrations as a side effect of the import. A shared plain module avoids
 * that entirely.
 */
export async function typeIntoTestIdInput(page: Page, testId: string, value: string): Promise<void> {
  const input = page.getByTestId(testId)
  await input.click()
  await page.evaluate(
    ({ testId, text }) => {
      const el = document.querySelector(`[data-testid="${testId}"]`) as HTMLInputElement | HTMLTextAreaElement | null
      if (!el) throw new Error(`typeIntoTestIdInput: no element for testid ${testId}`)
      // The native value setter lives on HTMLInputElement.prototype for
      // <input> and HTMLTextAreaElement.prototype for <textarea> — calling
      // the wrong one throws "Illegal invocation" (confirmed against
      // rollback-reason-input, a <textarea>).
      const proto = el instanceof window.HTMLTextAreaElement ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype
      const setter = Object.getOwnPropertyDescriptor(proto, 'value')!.set!
      setter.call(el, text)
      el.dispatchEvent(new Event('input', { bubbles: true }))
    },
    { testId, text: value },
  )
}
