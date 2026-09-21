# ISS-0767 — `NonSkippableApprovalGate.tsx` must surface the four rehearsal-gate blocked states

Status: DESIGN (pending CODE-DESIGN-VALIDATOR)
Owner files:
- `web/src/components/promotions/NonSkippableApprovalGate.tsx`
- `web/src/api/promotions.ts`
Related, already shipped: `lib/letflow/design/iss0732-promotion-apply-assertion-gate.md` (backend
gate this design surfaces), `lib/letflow/design/req371-rollback-withdrawal-screen.md`
(`classifyRollbackError` — the exact-string-match precedent this design follows).
Scope: **FRONTEND ONLY.** No backend file is touched by this design.

## 0. Correction to the queue's own filing

`docs/issues/ISS-0767.yaml`'s `fix_direction` (and the queue task/GH#1664 description it was
copied from) guesses the backend error shape as roughly "a new error reason" without naming it,
and an earlier draft of this issue guessed at `:assertion_run_required` /
`:assertions_failed` as the atom names. **Both guesses are wrong.** The backend, as actually
shipped by ISS-0732 (`lib/letflow/definitions/promotion.ex` `verify_rehearsed/3`,
confirmed live in that module at the point this design was written, and
`lib/letflow/routers/promotions.ex` `render_apply/2`), returns **four** distinct error reasons,
not one or two, and none is named `:assertion_run_required` or `:assertions_failed`:

| Backend `apply_review/4` reason | HTTP | `detail` string (verbatim, RFC 9457 `detail` field) |
|---|---|---|
| `:assertion_run_missing` | 409 | `no assertion run has been recorded for this review; run assertions before applying` |
| `:assertion_run_digest_mismatch` | 409 | `the most recent assertion run does not match the plan_digest being applied; re-run assertions against the current plan` |
| `:assertion_run_in_progress` | 409 | `the most recent assertion run for this review has not finished yet; wait for it to complete or re-run assertions before applying` |
| `:assertion_run_failed` | 409 | `the most recent assertion run recorded failing assertions; applying is blocked until a rehearsal with zero failures is recorded` |

This design's §5 also amends `docs/issues/ISS-0767.yaml` to record this correction explicitly, so
a future reader of the issue file does not re-trust the original guess.

## 1. Why exact-`detail`-string matching, not HTTP status

All four new reasons — **and** the pre-existing `:digest_mismatch` (top-level, review-vs-caller
digest) — go through `Letflow.Api.Error.conflict/1` (`lib/letflow/api/error.ex:209-216`), which
hard-codes `type: ".../problems/conflict"` and `title: "Conflict"` for every caller. That means,
on the wire, all five of these 409s are **byte-identical** in `status` (409), `type`, and `title`
— the only field that differs between them is `detail`. This is the same situation
`req371-rollback-withdrawal-screen.md` §7 already solved for two 422s sharing an identical
`message`/`title` ("Unprocessable Entity"): status/code alone cannot disambiguate, so the
classifier must read the RFC 9457 `detail` field and exact-match it.

### 1.1 Where `detail` lands in the frontend's `ApiError`

Confirmed by reading `web/src/api/client.ts`'s 409 branch (`request<T>`, the
`response.status === 409` clause, lines ~109-125): on any 409, the full decoded JSON response body
(which includes `detail`, `type`, `title`, `status`, `trace_id`) is spread verbatim into
`ApiError.details`:

```
details: {
  xResourceVersion: xResourceVersion ?? null,
  ...(Object.keys(body).length > 0 ? body : {}),
},
```

So the classifier reads `err.details?.detail` — a `string | undefined` — never `err.message`
(which is `body['title']`, i.e. the literal string `"Conflict"` for every one of these five
reasons, useless for disambiguation) and never `err.code` (which is `body['type']`, also
identical — `".../problems/conflict"` — across all five). This mirrors
`classifyRollbackError`'s own documented reasoning exactly (`req371-...md` line 311: "reads
`err.details.detail` …, **never `err.message`**").

## 2. Design decision: four distinct blocked states, not one generic "rehearsal required"

**Decision: distinguish all four reasons with their own message and `data-testid`, not a single
collapsed "rehearsal required" state.**

Rationale — a real design call, not a default:

- The four `detail` strings describe **different required operator actions**, not variations on
  one theme:
  - `assertion_run_missing` → operator has never run assertions at all → action: go run them.
  - `assertion_run_digest_mismatch` → operator ran assertions, but against a plan that has since
    changed (e.g. the review was resubmitted after amendment) → action: re-run assertions against
    the *current* plan — running the same rehearsal again would not fix it, since the recorded run
    is not stale-in-general, it is stale-*for-this-digest*.
  - `assertion_run_in_progress` → a rehearsal is already running (possibly started by another
    reviewer, or by this same operator moments ago) → action: wait, do not re-trigger — a generic
    "run assertions" message would wrongly invite the operator to kick off a second concurrent
    run.
  - `assertion_run_failed` → a rehearsal completed against the right plan and found real failures
    → action: fix the plan/target and re-rehearse — a materially different, and more urgent,
    situation than "nobody has rehearsed yet."
- Collapsing these into one message ("rehearsal required, run assertions first") would actively
  mislead the operator in the `assertion_run_in_progress` case (told to "run assertions" when one
  is already running — inviting a redundant concurrent run) and in the
  `assertion_run_digest_mismatch` case (an operator who *did* run assertions, correctly, against
  an earlier plan would read "run assertions first" and reasonably conclude the UI is buggy, since
  they already did).
- The backend design (`iss0732-...md` §3) went to explicit, documented effort to keep these four
  reasons as four distinct, greppable atoms specifically "so ISS-0767's frontend design has the
  information available to make that call either way" (`iss0732-...md` §8 OQ-1). Collapsing them
  here would discard information the backend design deliberately preserved for this decision.
- Cost of distinguishing is low: this component already renders one dedicated block per error
  kind (`SelfApprovalError`, `DigestMismatchError`, `PromotionConflictError`, `TransitionError`,
  `ExtraFieldsError`) — adding four more following the exact same shape is mechanical, not a new
  pattern.

This design does **not** invent a fifth, umbrella "rehearsal blocked" wrapper state around the
four — each of the four is its own top-level inline error block, exactly like the five that
already exist, so `handleApply`'s existing flat `if/else if` error-branch shape (see §4) is
extended, not restructured.

## 3. `classifyApplyRehearsalError` — the exact-string-match classifier

New helper, colocated in `NonSkippableApprovalGate.tsx` (small enough not to warrant its own
`utils/` file — same sizing judgment `classifyRollbackError` made, per
`req371-...md` line 295-296; promote it to a shared file only if a second component later needs
it):

```
type RehearsalGateErrorKind =
  | 'assertion_run_missing'
  | 'assertion_run_digest_mismatch'
  | 'assertion_run_in_progress'
  | 'assertion_run_failed'
  | 'not_rehearsal_related'

function classifyApplyRehearsalError(err: { status?: number; details?: Record<string, unknown> }): RehearsalGateErrorKind
```

Input/output contract (signature only — no body):

- Input: the same caught `err` object `handleApply`'s catch clause already has (shape
  `{ status?: number; code?: string; message?: string; details?: {...} }`, per the existing
  `err2` cast at line 249).
- Output: one of the five `RehearsalGateErrorKind` values.
- Behaviour (prose, matching `classifyRollbackError`'s own documented shape 1:1):
  1. If `err.status !== 409`, return `'not_rehearsal_related'` immediately — never inspect
     `detail` on a non-409, since none of the four reasons is ever anything but 409 (per §0's
     table) and a coincidental string match on an unrelated 409 (e.g. a future new conflict kind)
     must not be misclassified.
  2. Read `detail = typeof err.details?.detail === 'string' ? err.details.detail : undefined`.
  3. Exact-match `detail` (`===`, never `.includes()` / substring / regex) against each of the
     four literal strings in §0's table, in any order (the four strings are disjoint — no
     prefix/suffix relationship between them — so match order does not affect correctness), and
     return the corresponding `RehearsalGateErrorKind`.
  4. No match (including `detail === undefined`, or `detail` equal to the pre-existing
     `:digest_mismatch` string, or any other 409 `detail`) → return `'not_rehearsal_related'`.
- Exact-string comparison is deliberate, not substring, for the same reason
  `classifyRollbackError` gives (`req371-...md` lines 314-319): certainty over guessing from a
  partial match, and the four strings are stable literals baked into
  `lib/letflow/routers/promotions.ex`'s `render_apply/2` (§0's table, copied verbatim from
  `iss0732-...md` §5.2/§9.5), not user-influenced text.

### 3.1 Why this does not collide with the existing `:digest_mismatch` / promotion-conflict / invalid-transition branches

`handleApply`'s existing catch clause (lines 248-268) checks, in this exact order:
`code?.endsWith('/promotion-conflict')` → `status === 409 || code === 'PLAN_DIGEST_MISMATCH'` →
`status === 400 || code === 'INVALID_REVIEW_TRANSITION'` → `status === 422` → fallback.
The **new** `classifyApplyRehearsalError` check must run **before** the existing bare
`err2.status === 409` digest-mismatch fallback (see §4.1) — otherwise every one of the four new
409s would be wrongly swallowed by that catch-all `status === 409` branch and rendered as a
misleading "Plan digest mismatch" message, since `PLAN_DIGEST_MISMATCH` code matching is itself
already a fallback behind a bare status check. This is the one place in `handleApply`'s existing
branch order this design must not preserve verbatim — it inserts a new, more specific check ahead
of the existing generic `status === 409` branch, the same way the existing
`code?.endsWith('/promotion-conflict')` check already had to run ahead of it for the same reason
(ISS-0735, same file, comment at lines 250-257).

## 4. `handleApply` — new branch, exact placement

### 4.1 New state

Add one new state slot to the existing flat list at lines 176-181:

```
const [rehearsalGateError, setRehearsalGateError] = useState<RehearsalGateErrorKind | null>(null)
```

(Using the classifier's own return type restricted to the four real kinds — never
`'not_rehearsal_related'`, which is never stored, only branched on.)

### 4.2 `handleApply` catch clause — new ordering

Current order (lines 248-268, prose): `promotion-conflict` → `409/PLAN_DIGEST_MISMATCH` →
`400/INVALID_REVIEW_TRANSITION` → `422` → fallback.

New order — one new branch inserted **between** the `promotion-conflict` check and the existing
`409/PLAN_DIGEST_MISMATCH` check:

1. `err2.status === 409 && err2.code?.endsWith('/promotion-conflict')` → `setPromotionConflict`
   (unchanged, verbatim).
2. **NEW:** `classifyApplyRehearsalError(err2)` returns one of the four real kinds (not
   `'not_rehearsal_related'`) → `setRehearsalGateError(kind)`.
3. `err2.status === 409 || err2.code === 'PLAN_DIGEST_MISMATCH'` → `setDigestError(true)`
   (unchanged, verbatim — reached only when step 2 returned `'not_rehearsal_related'`, so a plain
   `:digest_mismatch` 409 still lands here exactly as it does today).
4. `err2.status === 400 || err2.code === 'INVALID_REVIEW_TRANSITION'` → `setTransitionError(true)`
   (unchanged).
5. `err2.status === 422` → `setExtraFieldsError(true)` (unchanged).
6. fallback → `setGeneralError(...)` (unchanged).

Also add `setRehearsalGateError(null)` to the block of state resets at the **top** of
`handleApply` (alongside the existing `setDigestError(false)` / `setPromotionConflict(null)` /
`setTransitionError(false)` / `setExtraFieldsError(false)` / `setGeneralError(null)` resets at
lines 240-244), so a retried Apply clears a stale rehearsal-blocked message exactly like every
other error kind already does.

`handleApprove` and `handleReject` are **not** touched — `verify_rehearsed/3` is called only from
`apply_review/4`'s own chain (`iss0732-...md` §2), never from the approve or reject paths, so
those two handlers have no new error reason to branch on. This design changes zero lines outside
`handleApply` and the shared state-slot declarations.

## 5. New rendered component — `RehearsalGateError`

One new presentational function, following the exact shape of `DigestMismatchError` /
`TransitionError` (lines 74-117):

```
function RehearsalGateError(props: { kind: RehearsalGateErrorKind }): React.ReactElement | null
```

Renders `null` when `props.kind === 'not_rehearsal_related'` (defensive — never actually reached,
since §4.2 never stores that value, but keeps the component total over its own prop type rather
than assuming the caller never passes it).

For the four real kinds, one `InlineError` each, with its own `testId` and message — table below
(message copy is this design's own wording; it does not need to match the backend `detail` string
verbatim, unlike `classifyApplyRehearsalError`'s matching logic, which must):

| `kind` | `data-testid` | Message shown |
|---|---|---|
| `assertion_run_missing` | `rehearsal-gate-error-missing` | "This plan has not been rehearsed yet. Run assertions before applying — Apply is blocked until a rehearsal is recorded for the current plan." |
| `assertion_run_digest_mismatch` | `rehearsal-gate-error-stale` | "The most recent rehearsal was run against an earlier version of this plan. Re-run assertions against the current plan before applying." |
| `assertion_run_in_progress` | `rehearsal-gate-error-in-progress` | "A rehearsal is currently running for this plan. Wait for it to finish, then try Apply again — do not start a second rehearsal." |
| `assertion_run_failed` | `rehearsal-gate-error-failed` | "The most recent rehearsal recorded failing assertions. Applying is blocked until a rehearsal with zero failures is recorded — fix the plan or target and re-run assertions." |

Wired into the render tree (§ "Inline errors" block, lines 397-402) as one new conditional,
inserted in the same relative position `promotionConflict` occupies today (i.e. among the other
apply-time errors, not mixed into the approve-time `selfApprovalError` slot):

```
{rehearsalGateError && <RehearsalGateError kind={rehearsalGateError} />}
```

Placed immediately after the existing `{promotionConflict && ...}` line and before
`{transitionError && ...}` — ordering among the five apply-time blocks does not matter
functionally (only one is ever set at a time, since each `handleApply` run resets all of them up
front), but keeping it adjacent to `promotionConflict` groups apply-time-only errors together,
away from `selfApprovalError` (approve-only) and `extraFieldsError`/`transitionError` (shared
across approve/reject/apply).

## 6. Apply-button affordance — no new disabled state

`canApply` (line 186: `review.status === 'approved' && !!review.plan_digest`) is **not** changed.
This design deliberately keeps the Apply button clickable whenever the review is `approved` with
a `plan_digest` present, exactly as today — the rehearsal-gate check is a **server-side**
precondition this frontend cannot pre-evaluate (it has no reliable, race-free way to know from
`PromotionContext` alone whether a same-digest, zero-failure, non-`:running` assertion run exists
— `PromotionContext.assertions` per `web/src/api/promotions.ts` `adaptPromotionContext` is
currently always `[]`, per that function's own documented honest-default comment at lines
124-139). Pre-disabling the button on a guess would either be wrong (falsely blocking an operator
whose rehearsal did pass) or require a second network round-trip this design does not introduce.
Surfacing the blocked state only after a real 409 comes back (§4-§5) is consistent with how this
same component already handles `digest_mismatch` and `promotion-conflict` — both are also
apply-time-only, post-click discoveries, not pre-computed disabled states.

## 7. No regression to `digest_mismatch` / `invalid_transition` (AC3)

Explicitly confirmed by §4.2's ordering: `classifyApplyRehearsalError` returns
`'not_rehearsal_related'` for every case that is not one of the four exact `detail` strings in
§0's table — this includes the existing plain `:digest_mismatch` 409 (whose `detail` string,
`Letflow.Api.Error.conflict/1` call site for `:digest_mismatch` in
`lib/letflow/routers/promotions.ex`, is a different literal than all four new ones) and every
`:invalid_transition` 400. When `classifyApplyRehearsalError` returns `'not_rehearsal_related'`,
step 2 of §4.2 does not fire, and control falls through to the unchanged steps 3-6 exactly as
before this design. No existing branch's condition, order relative to the *other pre-existing*
branches, or state-setter is modified — only one new branch is inserted, and only in the one
position (§3.1) where it must sit to avoid being shadowed. `DigestMismatchError` and
`TransitionError`'s own render/message/`data-testid` are untouched.

## 8. Test coverage

**Decision: one test per reason (four tests), not one representative case** — matching this
design's own §2 decision to distinguish the four states. A single representative test would only
prove *one* `detail` string maps correctly; since §1's whole design rests on exact-string matching
across four distinct literals with no structural relationship between them (unlike, say, four
enum-ordinal values), a bug in the classifier's third or fourth `if`/`else if` branch (e.g. a
typo in one of the four literal strings, or two branches accidentally sharing one condition) would
not be caught by testing only the first. This mirrors `req371-...md` §8.1's own choice: "Four
separate tests, one per `classifyRollbackError` branch" for the exact same reason (a future edit
to either backend detail string would silently break this classifier without a test catching it
here — here, four strings, so four tests).

### 8.1 New file: `web/src/components/promotions/__tests__/NonSkippableApprovalGate.rehearsal-gate.test.tsx`

(new `__tests__/` directory alongside the component — this repo has no existing test for
`NonSkippableApprovalGate.tsx` at all per this design's own repo search, so there is no existing
convention to match beyond the general `@vitest-environment jsdom` +
`@testing-library/react` + `vi.mock` shape already used across `web/src/__tests__/router.*.test.tsx`
and `web/src/auth/__tests__/*.test.tsx`.)

Five test cases:

1. **TC-ISS0767-01** `assertion_run_missing`: render `NonSkippableApprovalGate` with a
   `review.status === 'approved'` context and an `onApply` mock that rejects with
   `{ status: 409, details: { detail: 'no assertion run has been recorded for this review; run assertions before applying' } }`.
   Click `apply-btn`. Assert `screen.getByTestId('rehearsal-gate-error-missing')` is present and
   `queryByTestId('digest-mismatch-error')` / `queryByTestId('transition-error')` are absent.
2. **TC-ISS0767-02** `assertion_run_digest_mismatch`: same shape, `onApply` rejects with the
   digest-mismatch `detail` string from §0's table. Assert
   `rehearsal-gate-error-stale` present, `digest-mismatch-error` absent (this is the test that
   most directly guards §3.1's ordering fix — a regression that put the new check *after* the
   existing bare `status === 409` branch would make this exact case wrongly render
   `digest-mismatch-error` instead).
3. **TC-ISS0767-03** `assertion_run_in_progress`: `onApply` rejects with the in-progress `detail`
   string. Assert `rehearsal-gate-error-in-progress` present.
4. **TC-ISS0767-04** `assertion_run_failed`: `onApply` rejects with the failed `detail` string.
   Assert `rehearsal-gate-error-failed` present.
5. **TC-ISS0767-05** (regression guard, AC3) existing `digest_mismatch` case unaffected:
   `onApply` rejects with `{ status: 409, code: 'PLAN_DIGEST_MISMATCH', details: { detail: 'plan digest does not match the stored review' } }`
   (or whatever `:digest_mismatch`'s actual, unchanged `detail` string is — ELIXIR-DEV/
   FRONTEND-DEV confirm the exact literal from `lib/letflow/routers/promotions.ex`'s existing
   `:digest_mismatch` clause when implementing, since this design's own file search did not need
   to re-derive it, only confirm it differs from the four new ones). Assert
   `digest-mismatch-error` present and none of the four `rehearsal-gate-error-*` testids are
   present.

### 8.2 Direct unit coverage of `classifyApplyRehearsalError`

Same rationale as `req371-...md` §8.1 point 6 ("easy to get the `err.details.detail` vs
`err.message` distinction wrong… a rendering-level test alone might pass by accident"): a
colocated `describe('classifyApplyRehearsalError', ...)` block (same test file, or
`web/src/components/promotions/__tests__/classifyApplyRehearsalError.test.ts` if
FRONTEND-DEV prefers a standalone file once the function is exported for testability) with six
cases — the four real kinds, plus `status !== 409` → `'not_rehearsal_related'`, plus
`status === 409` with a `detail` that matches none of the four (e.g. the existing
`:digest_mismatch` string) → `'not_rehearsal_related'`.

### 8.3 Playwright e2e — explicitly out of scope for this design

No new `.pipeline.e2e.spec.ts` is designed here. Exercising all four reasons end-to-end would
require driving `PromotionAssertionRun` into four distinct real states (missing / stale-digest /
`:running` / failed) against a live backend, which is a materially larger fixture-setup lift than
this UI-surfacing issue's own severity (`MINOR`, per `docs/issues/ISS-0767.yaml`) justifies. The
four component-level tests (§8.1) plus the classifier unit tests (§8.2) are this design's full
required coverage; an e2e addition is a candidate for a future issue if UAT finds the
component-level coverage insufficient, not a gap this design silently leaves for FRONTEND-DEV to
notice.

## 9. Cross-module dependencies

- No change to `web/src/api/promotions.ts`'s exported types or `promotionsApi.apply`'s signature
  — `apply` already just forwards to `client.post`, and `client.post`'s existing 409 handling
  (§1.1) already produces the `details.detail` shape this design reads. The only reason
  `promotions.ts` is listed as an owner file at the top of this doc is in case FRONTEND-DEV
  chooses to move `classifyApplyRehearsalError` there instead of colocating it in the component —
  this design's own recommendation (§3) is to colocate, matching `classifyRollbackError`'s
  precedent, but does not forbid the alternative if FRONTEND-DEV finds a concrete reuse need.
- No backend file changes. No migration. No new route.
- No change to `PromotionReviewStateMachine.tsx` or `PlanDigestView.tsx` — neither renders
  apply-time errors.

## 10. Open questions

- **OQ-1**: Should the four `RehearsalGateError` messages (§5's table) surface a direct
  call-to-action, e.g. a "Run assertions" button linking to R8's `run-assertions` endpoint,
  rather than prose alone telling the operator to go do it elsewhere? Not resolved here — this
  design treats the fix as parallel in scope to the existing `DigestMismatchError`/
  `TransitionError`/`PromotionConflictError` blocks, none of which carry an action button today
  (all are prose-only inline alerts); adding one is a UX scope expansion FRONTEND-DEV or a
  follow-up issue can propose, not something this design silently decides either way.
- **OQ-2**: Whether `assertion_run_in_progress` (§5) should also disable the Apply button for a
  short client-side cool-down/poll rather than let the operator immediately retry into the same
  409. Not resolved here, per §6's own reasoning against any new pre-emptive disabled state —
  flagged so FRONTEND-DEV does not silently add polling behavior beyond what this design
  specifies.
