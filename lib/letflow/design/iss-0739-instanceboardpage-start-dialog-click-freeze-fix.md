# InstanceBoardPage start-instance-button click freeze fix (ISS-0739)

Design record for a MAJOR-severity fix, produced per WF-02 Step 1 /
WF-03 Step 2 conventions (this is a defect fix arising mid-REQ-371, not
a `requirements.yaml`-tracked feature). **No implementation code appears
in this document** — every change is described by call-site location and
prose, per CODE-DESIGNER's mandate (signatures/prose only).

Follows the `docs/frontend/iss-0662-*.md` / `lib/letflow/design/WF03-ISS0737-fix-design.md`
precedent shape for this bug class. Placed in `lib/letflow/design/` (not
`docs/frontend/`) matching this session's ISS-0729 fix
(`lib/letflow/design/iss-0729-definitionlistpage-search-freeze-fix.md`),
the more recent precedent for this exact bug class.

## 0. ISSUE-FIXER's diagnosis, and this step's job

ISSUE-FIXER root-caused, while diagnosing an intermittent (~1/3 hit rate)
hang at step 02 of REQ-371's required e2e spec
(`web/tests/e2e/pipelines/platform-definition-promotion-rollback.pipeline.e2e.spec.ts`,
the `start-instance-button` click at line 184/229):
`InstanceBoardPage.tsx`'s `openStartDialog` (lines 147-155) fires six
synchronous `setState` calls inside the same native click event-dispatch
turn as a real UA-trusted click. This is the identical trigger class
already confirmed for ISS-0662 (`EntityCrudPage.tsx`), ISS-0729
(`DefinitionListPage.tsx` search input), and ISS-0737/ISS-0738
(`DefinitionListPage.tsx` def-name click) — see
`web/src/utils/deferClickState.ts`'s moduledoc for the confirmed
mechanism and its two boundaries (macrotask via `setTimeout(fn, 0)` only;
microtask forms unverified, see that file's OQ-2 pointer).
`grep -rl deferClickState web/src` confirms only `DataTable.tsx`,
`DefinitionListPage.tsx`, and `EntityCrudPage.tsx` currently use the
helper — `InstanceBoardPage.tsx` was never patched.

This step's job: extend the same established fix to every synchronous-
setState click handler in `InstanceBoardPage.tsx`'s start-instance-dialog
flow, using the exact pattern already validated (and already twice
extended) by ISS-0662/ISS-0729/ISS-0737/ISS-0738, plus the double-submit
guard ISS-0662 separately had to add for the same reason (deferring a
mutate() call widens the window for a second click to schedule a second
mutation).

## 1. Handler-by-handler audit of `InstanceBoardPage.tsx`

Read in full (`web/src/pages/instances/InstanceBoardPage.tsx`, current
main). Every handler reachable from a click/interaction inside this
page's render tree:

| Handler | Lines | Sync `setState` calls | Triggered by | Needs `deferClickState`? |
|---|---|---|---|---|
| `openStartDialog` | 147-155 | `setStartDefinitionName`, `setStartDefinitionVersion`, `setStartCorrelationKey`, `setStartVariablesJson`, `setStartError`, `setStartValidationError`, `setShowStart` (7, not 6 — see note below) | `start-instance-button`'s real click (the confirmed culprit, matches the task's framing) | **Yes** |
| `closeStartDialog` | 157-159 | `setShowStart(false)` | Backdrop click (`onClick={closeStartDialog}` on the dialog's outer fixed-position `div`, line 386) AND the dialog's own "Cancel" button (line 478) — both real trusted clicks | **Yes** |
| `submitStartInstance` | 177-212 | `setStartError`, `setStartValidationError` (up to 3 early-return branches), then post-`await` `setShowStart(false)` at 206 | `submit-start-instance` button's real click (line 487, via `onClick={() => void submitStartInstance()}`) | **Partially** — see §2.2: the *pre-await* synchronous branches (182, 190, 195) run in the same click turn and must defer; the *post-await* `setShowStart(false)` at 206 already runs in a microtask/macrotask continuation after `mutateAsync` resolves, not in the native click's own synchronous dispatch turn, so it is not subject to the same trigger condition and needs no change (see §2.2 for the caveat this still leaves open) |
| `onStartDefinitionNameChange` | 161-175 | `setStartDefinitionName`, then conditionally `setSearchParams`/`setStartDefinitionVersion` | The dialog's `start-definition-name` `<input>`'s `onChange` (line 412) | **No** — `onChange` on a text input is not the native-click-dispatch trigger condition ISS-0662/ISS-0729/ISS-0737/ISS-0738 all identified (a synchronous commit inside a real *click's* mousedown→mouseup→click dispatch turn); ISS-0729's `defaultValue`/uncontrolled-input treatment was needed there specifically because deferring a *typed-character* state update by a macrotask visibly dropped fast-typed characters — a distinct concern from this bug class, and not applicable here since this handler is not being deferred at all. Flagged as an explicit judgment call in §5, OQ-1, not silently assumed. |
| Correlation-key `onChange` (line 448) | inline | `setStartCorrelationKey` | text `<input>` `onChange` | **No** — same reasoning |
| Variables-JSON `onChange` (line 466) | inline | `setStartVariablesJson` | `<textarea>` `onChange` | **No** — same reasoning |
| `onStatusToggle`, `onDefinitionInputChange`, `onResolveDefinition`, `onPageChange` | 97-145 | various | checkbox `onChange`, filter-input `onChange`/`onBlur`, pagination click | **Out of scope** — not part of ISSUE-FIXER's reported freeze (start-instance-dialog only) and not touched by this fix; flagged in §5, OQ-2, exactly as ISS-0662's own design flagged `goNext`/`goPrev` as an open scope question rather than silently expanding scope |

Note on `openStartDialog`'s call count: the task description says "6
synchronous setState calls" but the actual source has 7
(`setStartDefinitionName`, `setStartDefinitionVersion`,
`setStartCorrelationKey`, `setStartVariablesJson`, `setStartError`,
`setStartValidationError`, `setShowStart`). This design targets the
verified 7-call body exactly as it stands in source, not the task
description's count — the fix wraps whatever `openStartDialog`'s body
actually contains, not a fixed number.

## 2. The fix

### 2.1 Files and call sites to change

**`web/src/pages/instances/InstanceBoardPage.tsx`**

Add, alongside the existing imports:

```
import { deferClickState } from '@/utils/deferClickState'
```

(matching the exact alias-import form used in
`web/src/pages/entities/EntityCrudPage.tsx` line 49 and
`web/src/pages/definitions/DefinitionListPage.tsx` line 8.)

1. **`openStartDialog`** (lines 147-155) — wrap the entire existing body
   (all 7 `setState` calls, unchanged in content and order) in
   `deferClickState(() => { ... })`. This is the confirmed culprit named
   in the task and mirrors `EntityCrudPage.tsx`'s `openCreate()` exactly
   (a multi-`setState` dialog-opening handler with no async work).

2. **`closeStartDialog`** (lines 157-159) — wrap `setShowStart(false)` in
   `deferClickState(() => { setShowStart(false) })`. This function is
   called from two real-click sites (backdrop `onClick`, line 386; Cancel
   button `onClick`, line 478) — no change needed at either call site
   since both already just reference `closeStartDialog` by name rather
   than inlining its body: the deferral lives entirely inside the shared
   handler, so wrapping it once, in place, covers every caller by
   construction regardless of how many call sites there are.

3. **`submitStartInstance`** (lines 177-212) — defer only the synchronous,
   pre-`await` portion that can run inside the same native click turn.
   Concretely: wrap the function's synchronous prelude — the two
   `setState(null)` resets at 178-179, and each early-return branch's own
   `setState` + `return` (182-183, 190-191, 195-196) — such that the
   validation logic itself is unchanged (same checks, same order, same
   return-vs-continue control flow) but every `setState` call reachable
   before the `await startInstance.mutateAsync(...)` call is scheduled via
   `deferClickState` instead of firing synchronously. Because the function
   is `async` and several of these are early returns, the cleanest shape
   (prose, not code) is: the function's existing statements are unchanged,
   but every bare `setStartError(...)`/`setStartValidationError(...)` call
   that currently executes synchronously before the `await` is replaced
   with `deferClickState(() => setStartError(...))` /
   `deferClickState(() => setStartValidationError(...))` at each of its
   three call sites (178-179 combined into one `deferClickState` wrapping
   both reset calls together, then 182, then 190, then 195) — the early
   `return` statements themselves are NOT deferred (control flow must stay
   synchronous; only the state mutation is deferred). The `await
   startInstance.mutateAsync(...)` call itself, and everything after it
   (206-207's `setShowStart(false)` + `navigate(...)`, and the catch
   block's `setStartError` at 210), are NOT part of this fix — see the
   explicit caveat in §2.2.

4. **`ConfirmDelete`-equivalent double-submit guard.** `submitStartInstance`
   is already guarded against double-submission by React Query's own
   `startInstance.isPending` flag (line 486's `disabled={startInstance.isPending}`
   on `submit-start-instance`), NOT a bespoke `useRef` — unlike
   `EntityCrudPage.tsx`'s `confirmDelete`, this handler never defers the
   `mutateAsync(...)` call itself (only the validation-branch `setState`
   calls before it are deferred, per §2.1.3 above), so the mutate call
   still fires synchronously within the same click turn it always did,
   and `isPending` still flips as soon as the mutation begins exactly as
   it does today. **No new `useRef` in-flight guard is needed for this
   handler** — this is a deliberate difference from ISS-0662, and the
   reasoning must not be silently skipped: ISS-0662's race existed
   specifically because it deferred the `mutate()` call itself, widening
   the window during which `isPending` had not yet flipped true while the
   button remained clickable. This design does NOT defer `mutateAsync`,
   so that window is never widened here, so the button's existing
   `disabled={startInstance.isPending}` remains sufficient. This
   reasoning is called out explicitly (not asserted without justification)
   because REVIEWER should confirm it during idiom review rather than
   this design silently presuming it — see §5, OQ-3.

### 2.2 Explicit caveat: is `submitStartInstance`'s post-await `setShowStart(false)` in scope?

Open per this role's "don't silently resolve an open question by
guessing" mandate: `setShowStart(false)` at line 206 runs after
`await startInstance.mutateAsync(...)` resolves — by the time that
statement executes, the browser's native click-dispatch turn that
triggered the button's `onClick` has long since completed (a full network
round-trip has occurred). None of ISS-0662/ISS-0729/ISS-0737/ISS-0738's
confirmed trigger condition — "a `setState` call running synchronously
**inside** the same native event-dispatch turn as the click" — applies to
a `setState` call that only runs after an `await` on a promise that
itself resolves on a later macrotask/microtask (the fetch's own
resolution). This design's position: line 206 does NOT need
`deferClickState` wrapping, and wrapping it anyway would be inert (it
already isn't in the freezing turn) but harmless. FRONTEND-DEV should
still empirically verify this via the fail-then-pass protocol in §4
before treating it as settled — see §5, OQ-4, since none of this
codebase's four prior fixes for this bug class involved an `async`
handler with an `await` boundary in the middle, so there is no direct
precedent to lean on for this specific shape.

### 2.3 Files NOT changed

`web/src/components/ui/DataTable.tsx`, `web/src/components/ui/Button.tsx`,
`web/src/pages/entities/EntityCrudPage.tsx`,
`web/src/pages/definitions/DefinitionListPage.tsx`,
`web/src/utils/deferClickState.ts` (the helper itself is reused unchanged,
matching its own moduledoc's `setTimeout(fn, 0)`-only contract — no new
deferral mechanism is introduced by this fix).

## 3. Regression test design

New file: `web/tests/e2e/iss-0739-instance-start-dialog-click-freeze.e2e.spec.ts`,
matching this bug class's established file-naming convention
(`iss-0662-entity-crud-click-freeze.e2e.spec.ts`,
`iss-0729-definition-search-freeze.e2e.spec.ts`,
`iss-0737-definition-name-click-freeze.e2e.spec.ts`).

Requirements for TEST-DESIGNER, all matching the established discipline
for this bug class exactly:

- **Real trusted gesture only**: `locator.hover()` + `page.mouse.down()` +
  `page.mouse.up()` on `start-instance-button` (and separately on the
  dialog's Cancel button, and the backdrop) — NOT `.click()`'s
  dispatch-event shortcut and NOT `dispatchEvent('click')`, matching
  ISS-0662 tests 1-13's own finding that only a real UA-trusted gesture
  reproduces the freeze.
- **Setup**: drive the real pipeline flow the task specifies — create and
  activate two process definitions (matching REQ-371's own promotion-
  rollback pipeline setup, reusable from
  `platform-definition-promotion-rollback.pipeline.e2e.spec.ts`'s own
  fixture/setup steps rather than duplicated ad hoc), navigate to
  `/instances`, then perform the real click on `start-instance-button`.
- **Assertion — must fail on pre-fix code**: `page.mouse.up()` (or the
  final step of the trusted-gesture sequence) resolves within a bounded
  timeout (5s, matching ISS-0662/ISS-0737's own chosen bound — generous
  above the ~1-2s a deferred, non-frozen click takes, tight enough that a
  genuine 30-40s-class freeze reliably trips it), AND
  `start-instance-dialog` becomes visible (`waitFor`) within that same
  bound. This directly targets the confirmed bug: the dialog must
  actually open, not merely "the click resolved."
- **Also cover, per §1's audit**: a second real trusted click on the
  dialog's Cancel button (asserting `start-instance-dialog` becomes
  hidden within the same bound) and a real trusted click on the backdrop
  (same assertion) — both share `closeStartDialog`, and both were
  identified in §1 as needing the same fix; ISS-0662's own precedent
  (§4 of that design) explicitly called out under-covering "create only"
  when delete/cancel independently froze too, so this test must not repeat
  that omission.
- **Also cover**: a full `submitStartInstance` real-click path (fill valid
  definition name/version fields via the already-open dialog, click
  `submit-start-instance` with a real gesture, assert the dialog closes
  and navigation to `/instances/:id` occurs within a bounded time) — this
  exercises §2.1.3's deferred validation branches under the "success" path
  where no early return fires, and via a deliberately-invalid case
  (leave `startDefinitionName` unresolved so `definitionId` is undefined)
  to exercise the early-return branch's deferred `setStartValidationError`
  call and assert the validation message appears within the same bound.
- **Mandatory fail-then-pass empirical protocol**, matching this
  project's established discipline for this exact bug class (ISS-0662's
  tests 12-13, ISS-0729's REVIEWER/TEST-RUNNER/RELEASE-VALIDATOR
  independent reproductions, ISS-0737/ISS-0738's identical protocol):
  1. Before landing the fix (or by temporarily reverting it in a
     throwaway, uncommitted local diff), run the new spec against a real
     running dev/build stack and confirm it reproducibly fails (hangs past
     the bound) on `start-instance-button`'s click — given the task's own
     framing of a ~1/3 intermittent hit rate, this must be run enough
     times (at minimum 5-10 real attempts, following ISS-0737's 5/5
     before-fix repro and ISS-0729's 20+ run before-fix baseline as the
     precedent for how many runs establish a real baseline against an
     intermittent bug) to establish a genuine pre-fix failure rate, not a
     single run that could have been a lucky pass given the low hit rate.
  2. Restore/land the fix, and rerun the same spec enough times (matching
     ISS-0729's 55+-run and ISS-0737's 4/4-then-independent-reruns
     discipline) to be confident the freeze is actually gone and not just
     statistically missed given its known non-100% reproducibility — a
     single clean pass is not sufficient evidence for an intermittent bug
     at this task's stated ~1/3 hit rate.
  3. Record the actual run counts and pass/fail tallies in the resulting
     `docs/issues/ISS-0739.yaml` `resolution.empirical_evidence_trail`
     field (see §6), exactly as ISS-0729/ISS-0737/ISS-0738 each did —
     "should pass" or an unquantified single run is not acceptable
     evidence for this bug class per this project's no-speculation rule.

## 4. Sequencing note for downstream roles

This design doc, once CODE-DESIGN-VALIDATOR passes it, hands to
ELIXIR-DEV/FRONTEND-DEV (frontend-only change, so FRONTEND-DEV) for
implementation, then TEST-DESIGNER for the spec in §3 (or FRONTEND-DEV
may author it directly as part of the same empirical fail-then-pass loop,
matching how ISSUE-FIXER validated the fix empirically before this design
was even written, per the task's own description) and TEST-DESIGN-VALIDATOR,
then REVIEWER (idiom check on §2.1.4's "no useRef needed" reasoning is a
specific, named ask — see §5 OQ-3) and TEST-RUNNER, unblocking REQ-371's
own AC6 (its required e2e spec authored AND passing).

## 5. Open questions (explicitly unresolved, not guessed)

- **OQ-1**: Should `onStartDefinitionNameChange` (§1's table, the dialog's
  definition-name `<input>` `onChange`) receive the same
  `defaultValue`/uncontrolled-input treatment ISS-0729 needed for
  `DefinitionListPage.tsx`'s search input? This design's position is NO —
  ISS-0729's freeze was in the debounced *search* input on a *different*
  page under a *different* confirmed mechanism (dev/StrictMode-only,
  60-80% hit rate, tied to `useDebounce`), not the native-click-dispatch
  trigger this task is about; nothing in ISSUE-FIXER's diagnosis for this
  task implicates `onStartDefinitionNameChange`. This is a considered
  scope decision, not an oversight — but it is explicitly flagged here so
  FRONTEND-DEV doesn't assume it was silently rolled in, and so a future
  investigation into this input specifically (if it turns out to freeze
  too) isn't blocked re-discovering context already known here.
- **OQ-2**: `onStatusToggle`, `onDefinitionInputChange`, `onResolveDefinition`,
  and `onPageChange` (§1's table, out of scope) were not verified either
  way by ISSUE-FIXER for this task. Matching ISS-0662's own §5 OQ-1
  precedent (leaving `goNext`/`goPrev` unpatched pending evidence), this
  design does not preemptively patch them. If TEST-DESIGNER's coverage
  independently surfaces a freeze on any of these, that is a new finding
  to route back through this same process, not something to silently fix
  inline here.
- **OQ-3**: §2.1.4's claim that no new `useRef` double-submit guard is
  needed for `submitStartInstance` (because `mutateAsync` itself is never
  deferred, unlike ISS-0662's `confirmDelete`) is this design's own
  reasoning, not independently empirically re-verified against a live
  double-click in this session. REVIEWER should confirm this holds during
  idiom review, and FRONTEND-DEV's own empirical pass (per §3's
  fail-then-pass protocol) should include an explicit double-click/rapid-
  double-Enter check on `submit-start-instance` as a sanity test, even
  though it is not the freeze this design is chartered to fix, given that
  ISS-0662 discovered its own guard need only empirically, after the
  defer was already in place.
- **OQ-4**: §2.2's position that `submitStartInstance`'s post-`await`
  `setShowStart(false)` (line 206) does not need `deferClickState`
  wrapping is reasoned from the other four fixes' shared trigger
  condition, but is the first time this bug class has been applied to an
  `async`/`await`-shaped handler in this codebase — no prior fix
  (ISS-0662, ISS-0729, ISS-0737, ISS-0738) had this exact shape to
  validate against. FRONTEND-DEV's empirical fail-then-pass pass in §3
  should specifically watch for any residual freeze on the
  success-path submit (the case that reaches line 206), not just the
  early-return validation-error paths, to close this out with real
  evidence rather than leaving it as an assumption.

## 6. Filing (ISS-0739.yaml) — for ORCH to complete

Per this session's established "next unused filename slot"
collision-avoidance procedure (documented in ISS-0729.yaml's own trailing
NOTE comment, and matching the queue-id/filename mismatch pattern that
procedure exists for): `docs/issues/ISS-0738.yaml` is the current highest
filed issue number in `docs/issues/`; `ISS-0739.yaml` is confirmed unused
(`ls docs/issues/ISS-0739.yaml` — not found) as of this design's writing.
CODE-DESIGNER does not have `letflow-queue` access and does not call
`register_task` — ORCH (or whichever agent owns queue registration next)
should:

1. Register this defect via `letflow-queue`'s `register_task`, and take
   whatever real, atomically-allocated id it returns.
2. If that id's corresponding `issue_ref` (per letflow-queue's
   id→`ISS-XXXX` mapping rule) collides with an already-filed
   `docs/issues/ISS-XXXX.yaml` (as happened for ISS-0729/ISS-0730 and
   ISS-0738/Q-731 above), file the YAML at the next unused filename slot
   instead (currently `ISS-0739.yaml`, but re-check at filing time since
   other issues may file first) and add the same kind of NOTE-comment
   explaining the mismatch, matching ISS-0729.yaml's precedent exactly.
3. Suggested YAML content (fields this design can supply; `queue_ref` and
   `github_ref` are placeholders for ORCH to fill from the real
   registration):

   - `id: ISS-0739` (or the next confirmed-unused slot)
   - `title`: "InstanceBoardPage start-instance-button click freeze:
     openStartDialog's synchronous multi-setState body freezes on a real
     trusted click"
   - `discovered_by: ISSUE-FIXER`
   - `severity: MAJOR` (blocks REQ-371 AC6, matches ISS-0729/ISS-0738's
     own severity for the identical bug class and identical blocking
     relationship)
   - `tags: [frontend, performance, flake]`
   - `description`: summarize §0-§1 of this document (ISSUE-FIXER's
     diagnosis, the confirmed 7-call `openStartDialog` body, the
     intermittent ~1/3 hit rate, and that this is the same trigger class
     as ISS-0662/ISS-0729/ISS-0737/ISS-0738)
   - `affected_files`: `web/src/pages/instances/InstanceBoardPage.tsx`,
     `web/src/utils/deferClickState.ts`,
     `web/tests/e2e/pipelines/platform-definition-promotion-rollback.pipeline.e2e.spec.ts`,
     new: `web/tests/e2e/iss-0739-instance-start-dialog-click-freeze.e2e.spec.ts`
   - `suggested_fix`: point at this design doc's path
     (`lib/letflow/design/iss-0739-instanceboardpage-start-dialog-click-freeze-fix.md`)
   - `related: [ISS-0662, ISS-0729, ISS-0737, ISS-0738]`
   - `queue_ref: <PLACEHOLDER — fill from register_task's real id>`
   - `github_ref: <PLACEHOLDER, or null if not filed on GitHub yet>`
   - `status: open` (flip to `fixed`/`resolved` by DOC-UPDATER once
     FRONTEND-DEV/TEST-RUNNER/RELEASE-VALIDATOR close the loop, matching
     ISS-0737/ISS-0738's own status lifecycle)

## 7. Acceptance-criteria mapping

| Requirement (from this task's framing / ISSUE-FIXER's diagnosis) | Design element covering it |
|---|---|
| Real click on `start-instance-button` must not freeze | §2.1.1 `openStartDialog` deferral |
| Cancel button and backdrop click must not freeze | §2.1.2 `closeStartDialog` deferral (covers both call sites) |
| `submitStartInstance`'s synchronous validation-branch state updates must not freeze | §2.1.3 |
| Double-submit race the defer could introduce must be assessed (per ISS-0662 precedent) | §2.1.4 — reasoned to be a non-issue here since `mutateAsync` itself is not deferred; flagged as OQ-3 for REVIEWER/FRONTEND-DEV to confirm empirically |
| Controlled-input onChange handlers correctly NOT wrapped (distinguished from ISS-0729's different fix shape) | §1's table + OQ-1 |
| Real trusted-click e2e regression spec, fail-then-pass proven | §3 |
| Issue filed with collision-avoidance procedure followed | §6 |
