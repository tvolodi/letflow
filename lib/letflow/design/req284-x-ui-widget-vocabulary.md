# REQ-284 — Closed x-ui widget vocabulary + fieldRegistry population

Stage S8. Forms half of decision `0020-frontend-architecture.md` step 6 (D1c in
the requirement title; text below cites D1/D1a/D3 directly, the sub-labels the
decision record actually defines). Two deliverables: (1) a recorded, closed
`x-ui.widget` vocabulary document under `docs/frontend/`, (2) `fieldRegistry`
populated with matching platform renderers. No backend change. No field-logic
widget.

## 0. Re-verification (facts this design depends on, checked against source)

**`web/src/components/forms/fieldRegistry.ts`** — confirmed empty today:

```
export const fieldRegistry: Map<string, FieldTypeRenderer> = new Map()
```

with the comment `Empty registry -- populated by app code (CMP-UI-05 batches
register here)`. Its exact current contract:

```
export interface RenderInputArgs {
  fieldName: string
  fieldDef: TaskFormField
  register: UseFormRegisterReturn
  ariaDescribedBy?: string
  ariaErrorMessage?: string
  ariaRequired?: boolean
}

export type AriaAttributeName =
  | 'aria-required'
  | 'aria-describedby'
  | 'aria-invalid'
  | 'aria-errormessage'

export interface FieldTypeRenderer {
  renderInput: (args: RenderInputArgs) => ReactNode
  requiredAriaAttributes: ReadonlyArray<AriaAttributeName>
}
```

**`web/src/components/forms/FieldFactory.tsx`** — confirmed fall-through
logic, `renderFormField(...)`:

```
const renderer: FieldTypeRenderer | undefined = fieldRegistry.get(fieldType)
if (renderer) {
  const element = renderer.renderInput({ fieldName, fieldDef, register, ariaDescribedBy, ariaErrorMessage, ariaRequired })
  return ( /* label + hint + element + error, decorated by FieldFactory */ )
}
// Default built-in renderer (the existing switch) — unchanged
```

where today `fieldType = fieldDef.type || 'string'` (line 28) — **the lookup
key is currently the JSON-Schema `type`, not a separate widget name**. §1
below records why this requirement must change that one line, and why the
change is in-scope under the requirement's own scope fence.

**A pre-existing gap, verified, not this requirement's to fix:**
`DynamicFormRenderer.tsx` does not import `FieldFactory`/`renderFormField` at
all — it has its own inlined field-type switch (lines 147-233) that never
calls `fieldRegistry`. `renderFormField` is exercised today only from
`web/tests/unit/FieldFactory.aria.test.tsx` /
`FieldFactory.aria.12.test.tsx`, confirmed by
`grep -rn "renderFormField\|FieldFactory" web/src` returning no import from
`DynamicFormRenderer.tsx` or any page. This means the widgets this
requirement registers are reachable today only through `FieldFactory`'s own
render path (exactly what the existing ARIA test suite exercises), not yet
through the task-completion form a tenant actually sees. That reconciliation
(wiring `DynamicFormRenderer` to call `FieldFactory`/`renderFormField`
instead of its own inline switch) is `DynamicFormRenderer`'s compilation
pipeline in the sense the scope fence means, is not required to register a
widget, and is explicitly OUT OF SCOPE here — flagged as **OPEN QUESTION
OQ-1** below, not silently fixed or silently ignored.

**`docs/frontend/design-system.md` §7.6 "DynamicForm"** — confirmed built-in
JSON-Schema-type-to-input table (verbatim):

| JSON Schema type/format | Rendered as |
|---|---|
| `string` | `<input type="text">` |
| `string, format: date` | `<input type="date">` |
| `string, format: date-time` | `<input type="datetime-local">` |
| `string, enum: [...]` | `<select>` |
| `number` / `integer` | `<input type="number">` |
| `boolean` | `<input type="checkbox">` |
| `string, maxLength > 200` | `<textarea>` |

The vocabulary document (§1) states its relationship to this table rather
than duplicating it: an `x-ui.widget` override applies *within* one of these
type buckets, replacing the default input for that JSON-Schema type with a
platform-reviewed widget, never introducing a new JSON-Schema `type`.

**`docs/migration/decisions/0020-frontend-architecture.md`** — confirmed:
- D1 (line ~80-101): tenant customisation is data, never code; screen forms
  customise via "JSON Schema + `x-ui` render hints."
- D1a (line ~134 onward, dated 2026-09-08): permits `visible_when`,
  `computed`, cross-field validation in the existing `Letflow.Engine.Expr`
  grammar, evaluated client-side for interactivity with **mandatory
  server-side re-evaluation on submit** — its own track (sequencing steps
  8-12), gated on D3a, starting with a language-neutral conformance corpus,
  not a widget.
- D3 (line 318 onward): "Custom widgets register in `fieldRegistry` as
  **platform** code, keyed by a `x-ui.widget` name a tenant's schema may
  reference. The tenant names a widget; the platform decides what that
  widget is." Also confirms the three-way split — `tasks.form_schema`
  (rendering payload only), `variable_schemas` (REQ-109, real validation
  authority), `form_schema_registry` (search index, unrelated) — and that
  `form_schema` is a rendering payload, never a validation authority.

**`lib/letflow/engine/variable_schema.ex`** — confirmed (moduledoc, lines
21-33): `tasks.form_schema` is explicitly "R-Co never validates submitted
output against it. OUT OF SCOPE"; `variable_schemas` is the real per-variable
validation authority (REQ-109). This requirement touches neither the engine
nor `variable_schemas` — it is a pure `web/` change to a rendering-only
extension point.

## 1. The closed vocabulary

New document: `docs/frontend/x-ui-widget-vocabulary.md`. Its normative
content (headings/sections FRONTEND-DEV must produce — prose, not code):

### Front matter (required text, near-verbatim obligation)

- States the vocabulary is **closed**: "A tenant selects `x-ui.widget` from
  the set below. A tenant cannot introduce a new widget name; an unrecognised
  name degrades to the built-in renderer for the field's JSON Schema type
  (§4). Extending this vocabulary is a platform change — a new renderer
  registered in `fieldRegistry`, reviewed and tested like any other platform
  code — going through the normal gate chain (CODE-DESIGNER →
  CODE-DESIGN-VALIDATOR → FRONTEND-DEV → REVIEWER → TEST-DESIGNER →
  TEST-DESIGN-VALIDATOR), never a tenant-side extension point." Cites decision
  0020 D1 and D3 by name.
- States the relationship to design-system.md §7.6 explicitly (not a
  duplicated table): "§7.6 is the *default* mapping from a JSON-Schema
  `type`/`format` to an input. `x-ui.widget` is an optional override applied
  on top of that mapping for the same field: the field's JSON-Schema `type`
  still determines what value shape is produced (a string, a number); the
  widget only changes *which control* produces it. A field with no
  `x-ui.widget` (or an unrecognised one) always renders exactly per §7.6."

### The vocabulary itself — five widgets

Chosen deliberately small: five names, each covering an interaction §7.6's
type-mapping structurally cannot express (a type/format pair maps to exactly
one control there), each reachable without any backend dependency (no
upload/storage endpoint, no server-side search), and each excluded from
scripting/logic by construction (no expression evaluation, no visibility
rules — those are D1a's separate track, see §6). A file-upload or
autocomplete-with-remote-search widget was deliberately **not** included:
both would need a backend endpoint this requirement's scope fence forbids
touching (REQ-273/D3's "populate the column" work is the backend
prerequisite, not yet landed) — recording that exclusion here so a later
reader does not treat the omission as an oversight.

1. **`rich-text-lite`**
   - Valid JSON-Schema types: `string`.
   - Renders: a multi-line text editor (visually, a `<textarea>`-equivalent
     surface) with a small fixed toolbar of three toggle buttons — Bold,
     Italic, Bullet list. Each button inserts/removes a constrained
     markdown-lite token pair (`**`/`**`, `*`/`*`, `- ` line prefix) around
     the current selection or at the cursor; the field's value is always the
     plain string containing those literal tokens. There is **no live HTML
     preview and no HTML rendering of the value at all** — the platform
     never interprets the tokens as markup client-side; a future renderer
     (server-side or a dedicated preview surface) is what would ever turn
     the tokens into HTML, and is out of this requirement's scope.
   - Why it earns a slot: §7.6 has exactly one `string` default
     (`<input type="text">`) plus the `maxLength > 200` → `<textarea>`
     upgrade; neither offers inline emphasis, and free-form scripting/HTML
     input is exactly what D1 forbids a tenant from supplying, so a
     platform-reviewed constrained-token toolbar is the only way to offer
     "a little formatting" without opening an injection surface.
   - Accessibility contract: the editing surface carries
     `role="textbox"` and `aria-multiline="true"` (native on a `<textarea>`,
     so no explicit role needed if a real `<textarea>` element is used) plus
     the full `requiredAriaAttributes` set (`aria-required`,
     `aria-describedby`, `aria-invalid`, `aria-errormessage`), applied to
     that same element. Each toolbar button is a real `<button type="button">`
     with a visible label and `aria-label` ("Bold" / "Italic" / "Bullet
     list") and `aria-pressed` reflecting whether the token is present around
     the current selection.

2. **`masked-input`**
   - Valid JSON-Schema types: `string`.
   - Renders: a single-line text input that formats keystrokes against one
     mask, named by a companion closed enum `x-ui.mask` (`"phone-us"` |
     `"postal-us"` | `"currency-usd"`) that this widget alone consumes — the
     mask is a platform-chosen format, never a tenant-supplied pattern or
     regex. Formatting is applied on each keystroke by inserting/removing
     literal separator characters (parens, dash, `$`, comma) at fixed
     positions for the selected mask; the submitted value is always the
     plain string the user has entered including those separators (the
     underlying JSON-Schema `pattern`/`format`, if present, is what a
     platform-authored `variable_schemas` entry would check server-side —
     unaffected by this widget, per §8).
   - Why it earns a slot: §7.6's plain `<input type="text">` has no
     formatting-while-typing behaviour, and a mis-keyed phone number or
     amount is exactly the class of usability gap D3's "custom widgets are
     platform code" clause exists to close without opening tenant-supplied
     format strings (which would be exactly the "code, not data" line D1
     draws).
   - Accessibility contract: the input carries the full
     `requiredAriaAttributes` set plus `inputMode` appropriate to the mask
     (`"tel"` for `phone-us`, `"numeric"` for `postal-us`/`currency-usd`) and
     `aria-describedby` extended (space-joined, via the existing
     `joinHintIds` helper) to also reference a mask-format hint node (e.g.
     "Format: (555) 555-5555") rendered alongside the field's own
     description hint.

3. **`searchable-select`**
   - Valid JSON-Schema types: `string` with a non-empty `enum` (the same
     precondition §7.6 already requires for its own `<select>` default).
   - Renders: a combobox — a text input that filters the field's own
     `enum` list client-side as the user types, plus a listbox of matching
     options the user can navigate and select. No network request is ever
     made; the option universe is exactly the schema's own `enum`, so this
     is strictly a UX upgrade over `<select>` for a long enum, not a new
     data source.
   - Why it earns a slot: §7.6's `<select>` degrades badly once `enum` has
     more than a handful of values (no filtering, awkward keyboard use on
     long lists) — a closed-list filtering combobox is a well-understood,
     reviewable, self-contained widget with no backend dependency.
   - Accessibility contract: implements the WAI-ARIA combobox pattern —
     the text input carries `role="combobox"`, `aria-expanded`,
     `aria-controls` (pointing at the listbox's id), and
     `aria-activedescendant` (updated as the user navigates filtered
     options with the keyboard); the listbox carries `role="listbox"` and
     each option `role="option"` with `aria-selected`. The input also
     carries the full `requiredAriaAttributes` set.

4. **`rating`**
   - Valid JSON-Schema types: `number` or `integer`, with `minimum: 1` and a
     small `maximum` (platform validates this precondition when
     registering/rendering; a `maximum` absent or `> 10` is treated as a
     registry-population precondition failure, not a runtime tenant input —
     see §4's "invariants").
   - Renders: a fixed-size row of `maximum` selectable segments (visually,
     stars or numbered buttons — implementation detail left to
     FRONTEND-DEV, not fixed here), where selecting segment *N* sets the
     field's numeric value to *N*.
   - Why it earns a slot: §7.6's `<input type="number">` default is a poor
     fit for a small bounded satisfaction/severity scale — a discrete
     picker is both more usable and self-documenting about its bounded
     range, and is a genuinely bounded, reviewable widget (no free numeric
     entry to sanitize).
   - Accessibility contract: the row is a `role="radiogroup"` carrying the
     full `requiredAriaAttributes` set (the group, not an individual
     segment, is the field's accessible unit); each segment is a
     `role="radio"` with `aria-checked` and an `aria-label` stating its
     value in context (e.g. `"3 out of 5"`).

5. **`slider`**
   - Valid JSON-Schema types: `number` or `integer`, with `minimum` and
     `maximum` both present (a registry-population precondition, same
     rationale as `rating`).
   - Renders: a native range control (visually a horizontal track and
     thumb) spanning `[minimum, maximum]` in `multipleOf` steps (defaulting
     to `1` when `multipleOf` is absent), with the current numeric value
     displayed as text next to the control.
   - Why it earns a slot: same gap as `rating` for a *continuous* bounded
     range rather than a small discrete scale (e.g. a 0-100 confidence
     score) — direct manipulation communicates the bound in a way a bare
     number input does not.
   - Accessibility contract: implemented as a native
     `<input type="range">`, which the browser already exposes as
     `role="slider"` with `aria-valuemin`/`aria-valuemax`/`aria-valuenow`
     computed from its own `min`/`max`/`value` attributes — the renderer's
     obligation is to set those three native attributes correctly from the
     field's `minimum`/`maximum`/current value (not to hand-author the ARIA
     attributes) and to still apply the full `requiredAriaAttributes` set
     (`aria-required`, `aria-describedby`, `aria-invalid`,
     `aria-errormessage`) on the same `<input>`.

### Closing statement (required text)

"This is the complete `x-ui.widget` vocabulary as of REQ-284. No other
`x-ui.widget` name is platform-supported; `fieldRegistry`'s key set and this
list's name set are identical and mechanically checked (§2)."

## 2. Registry-equality invariant (AC2)

Single source of truth: a new module,
`web/src/components/forms/widgets/vocabulary.ts`, exporting:

```
export const X_UI_WIDGET_NAMES: readonly string[]
```

— the literal five strings above, e.g. `['rich-text-lite', 'masked-input',
'searchable-select', 'rating', 'slider']` (exact array, no computed
derivation). Both the vocabulary document (§1) and the registration module
(§3) are written by hand to match this array; the equality test (owned by
TEST-DESIGNER, not built here) asserts
`Array.from(fieldRegistry.keys()).sort()` equals
`[...X_UI_WIDGET_NAMES].sort()` after registration runs, and separately
asserts (by a fixture or a documented manual-sync comment) that the
vocabulary document lists exactly these five names — satisfying "every
widget name in that document has a corresponding fieldRegistry entry, and
every fieldRegistry entry has a corresponding documented name."

## 3. Registry population mechanism

One new file per widget under `web/src/components/forms/widgets/`, each
exporting one `FieldTypeRenderer` constant (bare signatures only):

```
// web/src/components/forms/widgets/richTextLite.tsx
export const richTextLiteRenderer: FieldTypeRenderer

// web/src/components/forms/widgets/maskedInput.tsx
export const maskedInputRenderer: FieldTypeRenderer

// web/src/components/forms/widgets/searchableSelect.tsx
export const searchableSelectRenderer: FieldTypeRenderer

// web/src/components/forms/widgets/rating.tsx
export const ratingRenderer: FieldTypeRenderer

// web/src/components/forms/widgets/slider.tsx
export const sliderRenderer: FieldTypeRenderer
```

Plus one aggregator, `web/src/components/forms/widgets/index.ts`:

```
export function registerBuiltinWidgets(): void
```

— body (not written here, implementation only) calls
`fieldRegistry.set(name, renderer)` once per pair, using the names from
`X_UI_WIDGET_NAMES` (§2) as the literal keys, so the vocabulary list and the
registration call sites are typo-proof against each other only via that
shared constant, not by separate literals.

`registerBuiltinWidgets()` is called exactly once, at application start
(the app's root entry module, e.g. `web/src/main.tsx`, before the first
render) — a bare call, no return value consumed. This mirrors
`fieldRegistry.ts`'s own moduledoc ("Empty registry — populated by app
code") and matches the existing sentinel-based test harness pattern already
in `FieldFactory.aria.test.tsx` (which calls `fieldRegistry.clear()` in
`afterEach`, confirming tests expect registration to be a distinct,
re-runnable step rather than a module-load side effect baked into
`fieldRegistry.ts` itself — module load order matters less if registration
is an explicit function call than if it were import-time-only).

### Required change to `TaskFormField` and the parser (the one pipeline
change registering these widgets by name requires)

Confirmed gap (§0): today `FieldFactory` keys the registry lookup by
`fieldDef.type` (the JSON-Schema type), and `TaskFormField` has no field
carrying an `x-ui.widget` name — only a narrow `widget?: 'textarea' |
'code-editor' | 'rich-text'` property, and `formSchemaParser.ts` reads a
top-level `schema.widget`, never a nested `schema['x-ui']`. Populating the
registry by `x-ui.widget` name (D3's own wording, and the only way AC4's
"unknown *widget* name still renders the field's JSON-Schema *type*" can be
true — see §7) requires:

- `TaskFormField` gains one new optional field:
  `xUiWidget?: string` — the five vocabulary names, or `undefined`. Left as
  a bare `string` (not a union of the five literals) so an unrecognised
  tenant-supplied value round-trips instead of being coerced/dropped by a
  type cast, which is what makes the degrade-on-miss behaviour (§7)
  observable at all.
- `formSchemaParser.ts`'s `parseField` reads a nested `x-ui` object off the
  raw schema (`schema['x-ui'] as Record<string, unknown> | undefined`)
  and sets `field.xUiWidget = xUi?.widget as string | undefined` — additive,
  no change to any existing field's parsing.
- `FieldFactory.tsx`'s lookup changes from
  `fieldRegistry.get(fieldType)` to `fieldRegistry.get(fieldDef.xUiWidget)`
  (a lookup on `undefined` simply misses, which `Map.get` already handles
  without a guard) — this is the one line the requirement's scope fence
  permits, since without it a widget cannot be "keyed by an x-ui.widget
  name" at all; `fieldType` itself is untouched and still drives every other
  branch in `FieldFactory`'s built-in switch.

**Explicit note for TEST-DESIGNER (not this design's to resolve by
guessing):** the existing `FieldFactory.aria.test.tsx` TC-FF-07/TC-FF-08
fixtures key their custom/unregistered renderer through `fieldDef.type`
(`'org.acme.rating'` / `'org.acme.unregistered'`), which is the *pre-REQ-284*
convention. Once the lookup key changes to `fieldDef.xUiWidget`, those two
fixtures must be updated to set `xUiWidget` instead of (or in addition to) a
non-standard `type` — flagged here as **OPEN QUESTION OQ-2**, resolved by
TEST-DESIGN-VALIDATOR/TEST-DESIGNER, not decided here, because it is a test
fixture change, not a vocabulary or registry design question.

## 4. Invariants

- The registry key set and `X_UI_WIDGET_NAMES` are identical at all times
  (§2) — enforced by test, not by convention alone.
- A widget's `renderInput` never receives or reads anything beyond
  `RenderInputArgs` — no ambient access to the full form schema, no network
  call, no access to other fields' values (ruling out any field-logic
  behaviour from sneaking in through a widget implementation; see §6).
- `rating`/`slider` registration-time precondition (`maximum` present, and
  for `rating` also `<= 10`) is a platform authoring invariant on the
  vocabulary document's own examples/tests, not a runtime check on
  tenant-supplied schemas — a tenant schema that omits `maximum` for a
  `rating`/`slider` field is handled by §7 (falls through to the JSON type's
  built-in control), not by a thrown error.
- No widget's `renderInput` return value is ever passed through
  `dangerouslySetInnerHTML`, `innerHTML`, `eval`, or `new Function` — see §5.

## 5. No code execution (AC5)

Design constraint, binding on every one of the five `renderInput`
implementations and on `registerBuiltinWidgets`: none may call `eval`,
`new Function`, set `dangerouslySetInnerHTML`, or assign to `.innerHTML`.
Every widget's output is built from JSX elements and plain string/number
props only (`rich-text-lite`'s markdown-lite tokens are stored and echoed
back as plain text in a `<textarea>`-equivalent value — never parsed to HTML
by this widget, per §1 item 1). FRONTEND-DEV's own verification step for
this requirement is a literal grep over the files this requirement adds or
changes:

```
grep -nE 'eval\(|new Function|dangerouslySetInnerHTML|innerHTML' \
  web/src/components/forms/widgets/*.tsx \
  web/src/components/forms/fieldRegistry.ts \
  web/src/components/forms/FieldFactory.tsx \
  web/src/utils/formSchemaParser.ts \
  web/src/types/forms.ts
```

quoted with zero hits in the implementation handoff, satisfying AC5 exactly
as worded ("a grep ... over the files this requirement adds or changes
returns zero hits, quoted with the command").

## 6. Field logic is deferred, not rejected (AC6)

The vocabulary document (§1) and this design both state, verbatim in
substance: **"No conditional-visibility or computed-field widget is part of
this vocabulary. This is not a rejection of field logic on principle — the
opposite: decision 0020's clause D1a (added 2026-09-08, on the mobile
offline-forms requirement) *permits* `visible_when`, `computed` fields and
cross-field validation, expressed in the `Letflow.Engine.Expr` grammar,
evaluated client-side for interactivity with mandatory server-side
re-evaluation on submit. Field logic is excluded from REQ-284 only because
D1a's own sequencing (steps 8-12) makes it a separate track whose first
deliverable is a language-neutral conformance corpus (step 9), not a widget.
A later reader must not treat this vocabulary's silence on field logic as
D1a having been re-closed here — it has not."** This sentence (or one
materially identical to it) is a required, literal section of the
vocabulary document, not paraphrased away — AC6 specifically requires the
document to make this unambiguous.

## 7. Unknown-widget-degrades scenario (AC4)

No code change to the *behaviour* — `FieldFactory`'s existing
`fieldRegistry.get(...)` miss → built-in-switch fall-through is already the
designed behaviour and needs no new logic beyond the key-source change in
§3. What AC4 needs is a **test proving it holds for an unknown `x-ui.widget`
name specifically** (not an unknown `type`, which is a different, already
-tested case per the existing TC-FF-08 fixture — see OQ-2): a schema field
with `type: 'string'` and `xUiWidget: 'not-a-real-widget'` must render the
built-in `<input type="text">` for `string` (or whichever §7.6 default
matches its `format`/`enum`/`maxLength`), not an empty render and not a
thrown error. This is the scenario the §3 key-source change makes possible
to state correctly: because `type` is untouched by an unrecognised
`xUiWidget`, the built-in switch always has a real case to fall into,
unlike today's TC-FF-08 fixture where the *type itself* was bogus.

## 8. Client-side validation is UX-only (AC7)

Required literal statement in the vocabulary document, matching decision
0020 D3 and `variable_schema.ex`'s own moduledoc: **"Any client-side
validation derived from `form_schema` (built-in or via an `x-ui.widget`) is
a UX affordance only — it improves the editing experience but proves
nothing to the server. Server-side authority for what a submitted value must
satisfy stays exclusively with `variable_schemas` (REQ-109). A widget that
appears to accept a value client-side does not mean the server will accept
it; no renderer in this vocabulary may be read as a validation boundary."**

## 9. Scope fence confirmation

- `DynamicFormRenderer.tsx`'s compilation pipeline
  (`parseFormSchema`/`compileFormSchemaToZod`) is **not** changed by this
  requirement beyond `formSchemaParser.ts`'s additive `xUiWidget` field
  (§3) — `compileFormSchemaToZod` is untouched; Zod compilation continues to
  validate purely by JSON-Schema `type`/`format`/`enum`/etc., never by
  widget name, consistent with §8 (widgets never become a validation
  boundary).
- `DynamicFormRenderer.tsx`'s own inlined field-rendering switch (its
  duplicate of `FieldFactory`'s logic, confirmed in §0) is **not** touched
  or reconciled with `FieldFactory` by this requirement — that is OQ-1,
  filed as a finding for ORCH to route as its own issue, not fixed here.
- The backend is untouched: no migration, no `lib/letflow/engine/` or
  `lib/letflow/routers/` change. `tasks.form_schema` stays unpopulated
  (REQ-273's job); this requirement only prepares the renderer side for
  when real schemas start arriving.
- No `variable_schemas` change, no `Letflow.Engine.Expr` change — field
  logic (D1a) untouched, per §6.

## Open questions

- **OQ-1** — `DynamicFormRenderer.tsx` renders forms via its own inline
  switch, never via `FieldFactory`/`fieldRegistry`, so the widgets this
  requirement registers are not yet reachable from the actual task-form UI
  a tenant sees; only from `FieldFactory`'s own render path (exercised by
  its ARIA test suite). Reconciling the two is a separate, larger frontend
  requirement (wiring `DynamicFormRenderer` to call `renderFormField`) —
  not decided or silently done here. Report as a finding for ORCH to queue.
- **OQ-2** — `FieldFactory.aria.test.tsx`'s existing TC-FF-07/TC-FF-08
  fixtures key a custom/unregistered renderer via `fieldDef.type`, which
  predates this requirement's `fieldDef.xUiWidget`-keyed lookup (§3). They
  need updating to use `xUiWidget` so they keep testing what they claim to
  test; left to TEST-DESIGNER/TEST-DESIGN-VALIDATOR, not resolved here.
- **OQ-3** — the five widgets' exact visual styling (star icons vs. numbered
  buttons for `rating`, thumb/track styling for `slider`, toolbar icon set
  for `rich-text-lite`) is left to FRONTEND-DEV's implementation judgement;
  this design fixes only the accessible structure (§1's per-widget
  accessibility contracts) and the JSON-Schema-type/x-ui-name/ARIA contract,
  not pixel-level presentation.
