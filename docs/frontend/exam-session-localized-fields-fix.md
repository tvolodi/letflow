# ExamSessionPage — localized-text and question-type shape fix

Design record for an Unblock-Everything fix inside REQ-346's run (letflow-queue
task 658). No requirements.yaml entry exists for this fix on its own — it is a
bug found and fixed inline while porting BilimBaga's exam-taking e2e specs
(REQ-346), the same disposition CLAUDE.md's "no human gate" / "correctable via
a later fix run" language covers. **No implementation code appears in this
document** — every change below is described by type shape, fallback rule, and
prose description of which branch changes; ELIXIR-DEV/FRONTEND-DEV convention
is respected (CODE-DESIGNER writes no `.tsx`/`.ts` bodies).

There is no precedent in this repo for a frontend-only bug-fix design note.
`lib/letflow/design/*.md` is the backend convention (Ecto schemas, gen_statem,
`@spec`s — none apply to a pure React/TS rendering fix) and
`docs/frontend/requirements/*.md` is reserved for numbered UI ticket codes
(`ADM-UI-NN`, `IN-UI-NN`, etc.) that this fix isn't one of. This file follows
`docs/frontend/`'s own top-level kebab-case topic-file convention instead
(`contract-gaps.md`, `design-system.md`, `x-ui-widget-vocabulary.md`) as the
closest genuine fit, noted here plainly per this task's own instruction rather
than silently picking one.

## 0. Root cause, re-verified against source (not taken on trust)

- `lib/letflow/exam/session.ex:279`'s `question_state()` type spec already
  admits this: `options: [%{id: String.t(), text: term()}]` — `text` is
  `term()`, not `String.t()`, because `build_option_states/4` (line 413) reads
  it via `fv(option, "text")`, and `fv/2` (line 1104,
  `Map.get(field_values, key)`) returns the entity record's **raw, unresolved
  field value** — for a `:localized_text` field (REQ-301) that value is a map
  like `%{"en" => "...", "ru" => "...", "kk" => "..."}`, never a plain string.
  Same for `stem` (same function, same `fv/2` call, `session.ex`'s own
  moduledoc at line ~308 confirms `stem` is hand-selected the same way as
  `text`).
- `lib/letflow/entities/query/allowlist.ex:117-118` independently confirms
  `stem` is a `:localized_text` field: it documents `stem`'s promoted locale
  columns as `stem_kk`, `stem_ru` (i.e. `stem` is the base `:localized_text`
  field name these columns were promoted from).
- `lib/letflow/routers/exam_sessions.ex`'s `question_state_json/1` (~line 503)
  and its `options` mapper (~line 514) pass `stem` and `text` straight through
  to the JSON body with no locale resolution — confirms the wire shape the
  frontend receives really is `{"en": "..."}`, not a resolved string.
- `lib/letflow/exam/session.ex`'s `question_type_atom/1` (~line 1169) is the
  real enum: `"single" -> :single`, `"multiple" -> :multiple`,
  `"truefalse" -> :true_false`, `"likert" -> :likert`,
  `"shorttext" -> :short_text`. `question_state_json/1` serializes the atom via
  `Atom.to_string/1`, so the wire values are the literal strings `"single"`,
  `"multiple"`, `"true_false"`, `"likert"`, `"short_text"` — none of which is
  `single_choice`/`multi_choice`, the values `web/src/types/exam.ts` currently
  types and `ExamSessionPage.tsx` branches on.
- `lib/mix/tasks/letflow.seed.exam_fixtures.ex`'s moduledoc corroborates both
  findings directly: it seeds questions of type `single`, `multiple`,
  `truefalse`, `likert`, `shorttext` (Go-side/legacy spelling, converted by
  `question_type_atom/1` above) with English-only stems like
  `"REQ-345 Mixed Q1 (single)"` — which only round-trips correctly if the
  frontend reads `stem.en`, not `stem` itself as a string.

## 1. Existing localized-text rendering pattern being reused

`web/src/pages/entities/EntityCrudPage.tsx`'s `formatCellValue` (~line 61) is
the one place in this codebase that already renders a `:localized_text` field
value for display (as opposed to `web/src/components/forms/widgets/
localizedText.tsx`, which is an *editing* widget — a per-locale input group,
not applicable here since the exam-taking screen never edits `stem`/
`option.text`). Its rule, read directly from source:

```
own = byLocale[uiLocale]
if own is a non-empty string -> use it
else -> first value in Object.values(byLocale) that is a non-empty string
else -> '' (empty string)
```

where `uiLocale` comes from `web/src/i18n/entitiesMessages.ts`'s
`resolveUiLocale(candidates?: readonly string[])`, called there as
`resolveUiLocale([intl.locale])` — i.e. it feeds react-intl's OWN active
locale in as the one candidate, rather than reading `navigator.languages`
directly (that direct-navigator path is `resolveUiLocale`'s fallback only when
no `candidates` argument is given at all). `resolveUiLocale` resolves to one
of `'en' | 'ru' | 'kk'` (`ENTITIES_UI_LOCALES`), defaulting to `'en'`
(`ENTITIES_UI_FALLBACK_LOCALE`) whenever `intl.locale`'s base tag isn't one of
those three.

**This fix reuses `resolveUiLocale` from `web/src/i18n/entitiesMessages.ts` by
import** (locale resolution only — not `entitiesMessages` itself, which is an
unrelated message catalog) rather than inventing a new locale-resolution
function. `ExamSessionPage.tsx` already has `intl` in scope
(`useIntl()`, line 97) via its own `ExamIntlProvider`, so the call site is
`resolveUiLocale([intl.locale])`, identical in shape to `EntityCrudPage.tsx`'s
own call.

### Exact fallback rule for this fix

For a localized-text value `v: Record<string, string> | null | undefined` and
`uiLocale = resolveUiLocale([intl.locale])`:

1. If `v` is nullish -> render `''`.
2. Else if `v[uiLocale]` is a non-empty string -> render it.
3. Else if `v['en']` is a non-empty string -> render it (explicit `en`
   fallback, requested by this fix's own brief — a strengthening of
   `EntityCrudPage`'s rule, which folds this case into step 4 by coincidence
   of key order rather than stating it as a named priority).
4. Else -> render the first non-empty string among `Object.values(v)`, in the
   object's own key order.
5. Else (no key has a non-empty string) -> render `''`.

This is a small local helper, not exported/shared, added directly in
`ExamSessionPage.tsx` (mirroring `formatCellValue`'s own placement as a
module-private function in its file — no shared `utils/localizedText.ts`
extraction is proposed here, since only one file needs it and inventing a
shared module both here and in `EntityCrudPage.tsx` at once would be scope
creep beyond this bug fix; leave that consolidation as an explicit open
question below rather than silently doing it or silently skipping it).

Proposed signature (type/shape only, no body):

```
function resolveLocalizedText(value: LocalizedText | null | undefined, uiLocale: string): string
```

## 2. Type corrections — `web/src/types/exam.ts`

### 2a. New shared shape for a localized-text wire value

```
export type LocalizedText = Record<string, string>
```

(No existing exported type for this shape was found anywhere under
`web/src/types/` — `api.ts`'s `EntityFieldDef['type']` union has a
`'localized_text'` string literal for the *field type tag*, but no type alias
for the *value* shape. `EntityCrudPage.tsx` inlines `Record<string, unknown>`
with a cast. This fix introduces the first named alias for the value shape,
scoped to `exam.ts` — not moved into `api.ts`, to avoid touching a file this
fix has no other reason to touch.)

### 2b. `ExamQuestionOption.text` and `ExamQuestionState.stem`

```
export interface ExamQuestionOption {
  id: string
  text: LocalizedText          // was: string
}

export interface ExamQuestionState {
  question_id: string
  sort_order: number
  type: ExamQuestionType
  stem: LocalizedText           // was: string
  options: ExamQuestionOption[]
}
```

### 2c. `ExamQuestionType` — corrected enum

```
export type ExamQuestionType = 'single' | 'multiple' | 'true_false' | 'likert' | 'short_text'
```

(was: `'single_choice' | 'multi_choice' | 'likert' | 'short_text' | string` —
the trailing `| string` widened the union to accept anything, which is why
this mismatch compiled without a type error in the first place; the corrected
union drops that widening so a future drift is a compile error, not a silent
`any`-shaped acceptance. `truefalse`/`true_false` per `question_type_atom/1`'s
literal `"truefalse" -> :true_false` mapping and `Atom.to_string(:true_false)
== "true_false"`.)

`ExamAnswerState`, `ExamSessionStateResponse`, `ExamAutosaveResponse`,
`ExamSubmissionOutcome`, `AntiCheatSignalOutcome`, `SaveAnswerBody` are
unaffected — none of them carries `stem`/`option.text`/question `type`.

## 3. `ExamSessionPage.tsx` — every call site needing a change

1. **Line 359** — `<h3>{currentQuestion.stem}</h3>` ->
   `<h3>{resolveLocalizedText(currentQuestion.stem, uiLocale)}</h3>`.
2. **Line 400** — `{option.text}` (inside the `options.map` render, ~line
   387-403) -> `{resolveLocalizedText(option.text, uiLocale)}`.
3. **Line 205** — `const isMulti = question.type === 'multi_choice'` (inside
   `handleOptionToggle`) -> `question.type === 'multiple'`.
4. **Line 394** — `type={currentQuestion.type === 'multi_choice' ? 'checkbox' : 'radio'}`
   (native input type, inside the option-rendering branch) ->
   `currentQuestion.type === 'multiple' ? 'checkbox' : 'radio'`.
5. **Line 147** and **line 361** — `currentQuestion?.type === 'short_text'` /
   `currentQuestion.type === 'short_text'` — already correct against the real
   enum (`'short_text'` is unchanged), no change needed, listed here only to
   confirm it was checked.
6. New local state/derivation: `const uiLocale = resolveUiLocale([intl.locale])`,
   computed once per render alongside the existing `const intl = useIntl()`
   (line 97) — cheap, pure, no memoization needed (matches
   `EntityCrudPage.tsx`'s own un-memoized call).
7. New import line, alongside the existing `@/types/exam` import block (line
   74-80): `import { resolveUiLocale } from '@/i18n/entitiesMessages'`, plus
   `LocalizedText` added to the `@/types/exam` type-only import list if
   `resolveLocalizedText`'s signature is declared in `ExamSessionPage.tsx`
   itself (see §1's placement decision).

No other line in this file reads `stem`, `.text`, or branches on `.type` —
verified by a full read of the file (`true_false` and `likert` questions both
carry real `options` from the backend per the seed-fixture moduledoc, so they
correctly fall through the existing `isMulti`-false / non-`short_text` else
branch already — no new branch is needed for either, only the `isMulti` fix
in item 3/4 above, since `'multi_choice'` never matches the real
`'multiple'` value and was silently always selecting the single/radio
rendering path for `multiple`-type questions before this fix, which is itself
part of the bug even though it didn't crash).

## 4. Other consumers checked

- `web/src/pages/exam/__tests__/ExamSessionPage.test.tsx` — its own
  `sessionState()`/`shortTextSessionState()` fixtures at the top of the file
  hard-code `stem: 'Question one'` / `stem: 'What is the capital of France?'`
  as plain strings and `type: 'single_choice'` (line 69). These fixtures are
  **stale against the corrected types** and must be updated by FRONTEND-DEV in
  the same change (e.g. `stem: { en: 'Question one' }`,
  `type: 'single'`) — every assertion in that file that reads rendered stem
  text or exercises the option-toggle path depends on this. This design does
  not itself edit that file (out of scope for CODE-DESIGNER; read-only per
  this task's constraints) but flags it as a required, non-optional companion
  edit — FRONTEND-DEV should not treat "tests still reference the old shape"
  as passing coverage.
- No other file under `web/src/` reads `ExamQuestionState`/`ExamQuestionOption`/
  `ExamQuestionType` (confirmed by grep across `web/src` for `.stem`,
  `option.text`, `ExamQuestionType`, `single_choice`, `multi_choice` — the
  only hits are `exam.ts` itself, `ExamSessionPage.tsx`, and the test file
  above; `entitiesMessages.ts`'s hit is an unrelated field named `stem` in a
  wholly different i18n message id, and `searchableSelect.tsx`'s hits are
  unrelated `.text` property reads on a combobox option type). There is no
  exam result/review page that separately renders questions — REQ-338's
  `phase: 'result'` branch (`ExamSessionPage.tsx` lines 291-319) renders only
  `ExamSubmissionOutcome`'s score fields, never a question stem or option
  text, so it needs no change.

## 5. Invariants preserved (explicitly, since this is a correctness-only fix)

- No behavior change to anything already working against real data: the
  countdown re-anchoring, autosave-on-change/on-blur wiring, anti-cheat
  signal wiring, deadline-expired terminal state, and grading-pending-vs-score
  result rendering are all untouched — none of them touch `stem`, `option.text`,
  or branch on `type` beyond the two corrected `'multiple'` comparisons above.
- The short_text draft-flush behavior (ISS-0654) and its `maybeSaveDraft`/
  `flushTextDraftBeforeAntiCheatReport` machinery are untouched — they never
  read `stem`/`option.text` and already compare `currentQuestion.type` only
  against the (correct, unchanged) literal `'short_text'`.

## 6. Open questions (explicitly unresolved, not silently guessed)

- **Q1 — shared helper consolidation.** `EntityCrudPage.tsx`'s
  `formatCellValue` and this fix's new `resolveLocalizedText` now implement
  two independently-maintained copies of nearly the same fallback logic (this
  fix's version adds the explicit `en` step `formatCellValue` doesn't have).
  Whether to extract a single shared `web/src/utils/localizedText.ts` used by
  both, and whether `formatCellValue` should be upgraded to the same explicit
  `en`-fallback-second rule for consistency, is left to a follow-up
  requirement rather than decided here — doing it inside this bug fix would
  touch a file (`EntityCrudPage.tsx`) this fix has no bug in.
- **Q2 — `sort_order`/other numeric-only fields.** Not in scope for this bug
  (unaffected by the localized-text/type-enum mismatch), noted only so
  FRONTEND-DEV doesn't assume this design silently reviewed every field on
  `ExamQuestionState` for correctness beyond the two named in the bug report.
