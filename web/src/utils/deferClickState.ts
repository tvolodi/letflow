/** deferClickState — ISS-0662
 *
 *  Confirmed empirically (docs/frontend/iss-0662-entity-crud-page-click-freeze-fix.md
 *  tests 12-13): on `/admin/bilimbaga/:entityType` (`EntityCrudPage`), a React
 *  `setState` call that runs synchronously inside the same native
 *  browser event-dispatch turn as a real, UA-trusted click (or keyboard
 *  Enter/Space) freezes the entire tab's main thread. Deferring the exact
 *  same state update by one macrotask eliminates the freeze with no change
 *  to the resulting UI state. The deeper "why" is not understood (see that
 *  design doc's §2) — this is a verified workaround for a verified trigger
 *  condition, not a root-cause fix.
 *
 *  `setTimeout(fn, 0)` is the ONLY deferral mechanism that was tested and
 *  shown to work. Do NOT swap this for `queueMicrotask` or
 *  `Promise.resolve().then(fn)` — a microtask still runs before the
 *  browser's next paint/compositor step and was never verified to break the
 *  same synchronous chain (OQ-2 in the design doc).
 */
export function deferClickState(fn: () => void): void {
  setTimeout(fn, 0)
}
