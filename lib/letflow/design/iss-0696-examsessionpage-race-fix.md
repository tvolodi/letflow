# ISS-0696 fix design — `ExamSessionPage.tsx` `textDraft` effect-ordering race

Queue task 696 / GitHub #1457. Root cause already diagnosed by ISSUE-FIXER (see the
handoff/task context this design was dispatched with) — this document does not
re-diagnose, it specifies the fix.

## Decision: component-side fix only, not a test-side change

**Chosen direction: ISSUE-FIXER's option 2** (eliminate the extra render-cycle gap in
`ExamSessionPage.tsx`), applied alone. Option 1 (add a `waitFor` in the test before
dispatching the forced blur) is **not** adopted, for a reason specific to this race, not
as a general preference: option 1 would only cover the two tests that already know to
wait for it. The underlying defect — `textDraft` visibly existing as `''` in the DOM for
one extra commit before syncing to the real answer — is a real bug for actual candidates
too, e.g. a screen reader or a screenshot-based UI test landing on that transient empty
state, or (more concretely) any future test/interaction that reads the textarea's value
immediately after it mounts without knowing it must wait. Fixing the component removes
the race at its source for every caller, current and future, whereas a `waitFor` in one
test file only suppresses the flake in the two call sites it's added to. Since the
component fix, done correctly, makes `findByTestId('exam-short-text-input')` resolve
already carrying the synced value (see "Why this closes the race" below), **no test file
change is required to satisfy this issue** — `ExamSessionPage.test.tsx` is unmodified by
this design.

## Fix location

`web/src/pages/exam/ExamSessionPage.tsx`, `ExamSessionPageInner`, current lines 161-172
(the `textDraft` state declaration and its syncing `useEffect`). No other file changes.

## Current shape (for reference — this is what is being replaced)

- `const [textDraft, setTextDraft] = useState<string>('')`
- A `useEffect` with dependency array `[currentQuestion?.question_id]` that, only when
  `currentQuestion?.type === 'short_text'`, calls `setTextDraft(answers[currentQuestion.question_id]?.text_answer ?? '')`.

This effect runs **after** the render that first puts the `<textarea data-testid="exam-short-text-input">`
in the DOM commits — one render/commit cycle later. Between those two commits, the
textarea exists with `value={textDraft}` still at its previous value (`''` on first mount
of a short_text question). Under scheduler jitter, an external event (the forced-blur
`window.dispatchEvent`) can land inside that gap.

## New shape: derive `textDraft` synchronously during render

Replace the state-plus-effect pair with React's documented "adjusting state during
render" pattern (store the key last computed *for*, and recompute inline in the render
body when that key changes) instead of an effect. Two pieces of state instead of one:

- `textDraft: string` — unchanged in type and meaning (the uncommitted, editable draft).
- `textDraftQuestionId: string | undefined` — new. Tracks which question's data
  `textDraft` was last synced from. Not rendered, not exposed outside this component.

Render-body logic, placed after `currentQuestion` is computed and before the JSX return
(replacing the removed `useEffect` at the same point in the function body):

- Condition: `currentQuestion?.question_id !== textDraftQuestionId`.
- When true (the visible question just changed from whatever it was — including the
  very first render, where `textDraftQuestionId` starts `undefined`):
  - Call `setTextDraftQuestionId(currentQuestion?.question_id)` unconditionally.
  - Call `setTextDraft(...)` **only when** `currentQuestion?.type === 'short_text'`,
    with the exact same source expression the old effect used:
    `answers[currentQuestion.question_id]?.text_answer ?? ''`. When the new question is
    not `short_text`, `textDraft` is left as whatever it already was (matching the old
    effect's behavior exactly, since the old effect's inner `if` guarded the same way —
    it never reset `textDraft` when the newly-focused question wasn't `short_text`
    either).
- When false (same question as last render): no-op, same as the old effect not firing
  because its dependency didn't change.

Both `setState` calls happen inside the render body, guarded by the identity check, which
is the specific pattern React supports for exactly this purpose — React detects the state
change, throws away the just-rendered output, and re-renders the component immediately
with the new state *before* committing anything to the DOM or running browser paint.
There is no intermediate commit where the textarea exists with a stale `textDraft`
value — the gap the race lived in is structurally gone, not just narrowed.

`onChange`/`onBlur` on the textarea (`setTextDraft(e.target.value)` /
`handleTextAnswerBlur`) are unchanged.

## Why this closes the race for real users too

The old effect's dependency array was `[currentQuestion?.question_id]` — the same
question-identity key this design uses for the render-time guard — so the *triggering
condition* is unchanged. What changes is only *when* the resulting `setTextDraft` takes
effect relative to commit: previously, one commit after the question became visible; now,
in the same commit that makes the question (and its textarea) visible. A real candidate
switching questions never sees (and no test can any longer observe) a short_text
textarea whose value has not yet caught up to the question it's showing.

## Multi-question navigation — checked for regressions

Existing navigation controls (`prevQuestion`/`nextQuestion`, lines ~410-427) only change
`questionIndex`, which changes `currentQuestion` via the existing
`session?.questions[questionIndex]` derivation — unchanged by this design. Walked the
three navigation cases the old effect handled, confirming the new logic reproduces each:

1. **short_text → different short_text question.** `question_id` changes ⇒ guard fires ⇒
   `textDraft` resets to that question's saved `text_answer` (or `''` if unanswered).
   Same outcome as before.
2. **short_text → non-short_text question.** `question_id` changes ⇒ guard fires ⇒
   `textDraftQuestionId` updates to the new id, but `textDraft` is left untouched (type
   guard fails) — same as before; harmless either way since no textarea is rendered for
   a non-short_text question.
3. **Navigate away from a short_text question and back to the same one.** Case 2 happens
   on the way out (updates `textDraftQuestionId` to the intermediate question's id
   without touching `textDraft`), then case 1 happens on the way back (id differs again
   from the intermediate one) ⇒ `textDraft` re-syncs from `answers` again, discarding any
   edited-but-unblurred text exactly as the old effect did (this was already the existing,
   intentional behavior — an uncommitted draft is not preserved across a question switch
   away and back; only the last *saved* value is restored). No behavior change.

No new dependency on `answers` or `saveAnswer` is introduced; `maybeSaveDraft`,
`handleTextAnswerBlur`, and `flushTextDraftBeforeAntiCheatReport` (lines 210-262) all read
`textDraft` and call `saveAnswer`/`maybeSaveDraft` exactly as before — none of them are
touched by this design.

## Acceptance criteria mapping

- Root cause identified → done by ISSUE-FIXER (see task context); this document does not
  redo it.
- A fix is made so the failure does not recur under full-suite parallel execution → the
  derived-state replacement above (component fix), which removes the inter-commit gap the
  race requires, structurally rather than by narrowing a timing window.
- Confirmed non-flaky across ≥10 consecutive full-suite `npm test` runs → verification
  step, owned by TEST-RUNNER/RELEASE-VALIDATOR after FRONTEND-DEV implements this design;
  not something CODE-DESIGNER can satisfy directly, noted here so the next role does not
  skip it.

## Open questions for REVIEWER

None. This is a self-contained, single-component fix with no new module dependency, no
schema change, and no decision-record interaction — REVIEWER's OTP-idiom/scope-creep
checks are not applicable to this file (`web/`), but REVIEWER should still confirm the
"adjusting state during render" pattern (two `setState` calls guarded by an identity
check, inside the render body rather than an effect) is an acceptable idiom for this
codebase's React conventions, since it is a pattern this file has not used elsewhere yet
(the file's other effects follow the more common effect-based sync style, e.g. lines
133-138's original `textDraft` effect being replaced, and the countdown-tick effect at
lines 151-157 which is unrelated and untouched).
