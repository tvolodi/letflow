# x-ui.widget vocabulary — closed set

**Requirement:** REQ-284 (forms half of decision
[`0020-frontend-architecture.md`](../migration/decisions/0020-frontend-architecture.md)
step 6). **Stage:** S8. **Owner:** `FRONTEND-DEV`.

## The vocabulary is closed

A tenant selects `x-ui.widget` from the set below. A tenant cannot introduce
a new widget name; an unrecognised name degrades to the built-in renderer
for the field's JSON Schema type (§4). Extending this vocabulary is a
platform change — a new renderer registered in `fieldRegistry`, reviewed and
tested like any other platform code — going through the normal gate chain
(CODE-DESIGNER → CODE-DESIGN-VALIDATOR → FRONTEND-DEV → REVIEWER →
TEST-DESIGNER → TEST-DESIGN-VALIDATOR), never a tenant-side extension point.
This cites decision 0020's clause D1 ("tenant customisation is data, never
code") and clause D3 ("custom widgets register in `fieldRegistry` as
platform code, keyed by an `x-ui.widget` name a tenant's schema may
reference — the tenant names a widget, the platform decides what that
widget is").

## Relationship to design-system.md §7.6

[`design-system.md` §7.6 "DynamicForm"](./design-system.md) is the
**default** mapping from a JSON-Schema `type`/`format` to an input.
`x-ui.widget` is an optional override applied on top of that mapping for the
same field: the field's JSON-Schema `type` still determines what value
shape is produced (a string, a number); the widget only changes *which
control* produces it. A field with no `x-ui.widget` (or an unrecognised
one) always renders exactly per §7.6. This document does not duplicate
§7.6's table.

## §1. The five widgets

Deliberately small: five names, each covering an interaction §7.6's
type-mapping structurally cannot express, each reachable without any
backend dependency (no upload/storage endpoint, no server-side search), and
each excluded from scripting/logic by construction (no expression
evaluation, no visibility rules — see §6, deferred to a separate track). A
file-upload or autocomplete-with-remote-search widget was deliberately
**not** included: both would need a backend endpoint this requirement's
scope fence forbids touching (REQ-273's "populate the column" work is the
backend prerequisite, not yet landed).

### 1.1 `rich-text-lite`

- **Valid JSON-Schema types:** `string`.
- **Renders:** a multi-line text editor (a `<textarea>`) with a small fixed
  toolbar of three toggle buttons — Bold, Italic, Bullet list. Each button
  inserts/removes a constrained markdown-lite token pair (`**`/`**`,
  `*`/`*`, `- ` line prefix) around the current selection or at the cursor;
  the field's value is always the plain string containing those literal
  tokens. There is **no live HTML preview and no HTML rendering of the
  value at all** — the platform never interprets the tokens as markup
  client-side. A future renderer (server-side or a dedicated preview
  surface) is what would ever turn the tokens into HTML, and is out of this
  requirement's scope.
- **Accessibility contract:** the editing surface is a real `<textarea>`
  (native `role="textbox"`/`aria-multiline="true"`, no explicit attributes
  needed) carrying the full `requiredAriaAttributes` set (`aria-required`,
  `aria-describedby`, `aria-invalid`, `aria-errormessage`). Each toolbar
  button is a real `<button type="button">` with a visible label and
  `aria-label` ("Bold" / "Italic" / "Bullet list") and `aria-pressed`
  reflecting whether the token is present around the current selection.

### 1.2 `masked-input`

- **Valid JSON-Schema types:** `string`.
- **Renders:** a single-line text input that formats keystrokes against one
  mask, named by a companion closed enum `x-ui.mask`
  (`"phone-us"` | `"postal-us"` | `"currency-usd"`) that this widget alone
  consumes — the mask is a platform-chosen format, never a tenant-supplied
  pattern or regex. Formatting is applied on each keystroke by
  inserting/removing literal separator characters (parens, dash, `$`,
  comma) at fixed positions for the selected mask; the submitted value is
  always the plain string the user has entered including those separators.
- **Accessibility contract:** the input carries the full
  `requiredAriaAttributes` set plus `inputMode` appropriate to the mask
  (`"tel"` for `phone-us`, `"numeric"` for `postal-us`/`currency-usd`) and
  `aria-describedby` extended (space-joined) to also reference a
  mask-format hint node (e.g. "Format: (555) 555-5555") rendered alongside
  the field's own description hint.

### 1.3 `searchable-select`

- **Valid JSON-Schema types:** `string` with a non-empty `enum` (the same
  precondition §7.6 already requires for its own `<select>` default).
- **Renders:** a combobox — a text input that filters the field's own
  `enum` list client-side as the user types, plus a listbox of matching
  options the user can navigate and select. No network request is ever
  made; the option universe is exactly the schema's own `enum`.
- **Accessibility contract:** implements the WAI-ARIA combobox pattern —
  the text input carries `role="combobox"`, `aria-expanded`,
  `aria-controls` (pointing at the listbox's id), and
  `aria-activedescendant` (updated as the user navigates filtered options
  with the keyboard); the listbox carries `role="listbox"` and each option
  `role="option"` with `aria-selected`. The input also carries the full
  `requiredAriaAttributes` set.

### 1.4 `rating`

- **Valid JSON-Schema types:** `number` or `integer`, with `minimum: 1` and
  a small `maximum` (a `maximum` absent or `> 10` is a registry-population
  authoring precondition, not a runtime tenant-input check).
- **Renders:** a fixed-size row of `maximum` selectable segments, where
  selecting segment *N* sets the field's numeric value to *N*.
- **Accessibility contract:** the row is a `role="radiogroup"` carrying the
  full `requiredAriaAttributes` set (the group, not an individual segment,
  is the field's accessible unit); each segment is a `role="radio"` with
  `aria-checked` and an `aria-label` stating its value in context (e.g.
  `"3 out of 5"`).

### 1.5 `slider`

- **Valid JSON-Schema types:** `number` or `integer`, with `minimum` and
  `maximum` both present (a registry-population precondition, same
  rationale as `rating`).
- **Renders:** a native range control spanning `[minimum, maximum]` in
  `multipleOf` steps (defaulting to `1` when `multipleOf` is absent), with
  the current numeric value displayed as text next to the control.
- **Accessibility contract:** a native `<input type="range">`, which the
  browser already exposes as `role="slider"` with
  `aria-valuemin`/`aria-valuemax`/`aria-valuenow` computed from its own
  `min`/`max`/`value` attributes — the renderer sets those three native
  attributes correctly from the field's `minimum`/`maximum`/current value
  and still applies the full `requiredAriaAttributes` set (`aria-required`,
  `aria-describedby`, `aria-invalid`, `aria-errormessage`) on the same
  `<input>`.

## §2. This is the complete vocabulary

This is the complete `x-ui.widget` vocabulary as of REQ-284. No other
`x-ui.widget` name is platform-supported; `fieldRegistry`'s key set and this
list's name set are identical and mechanically checked by
`web/tests/unit/xUiWidgetVocabulary.test.tsx`.

## §3. Registration

Each widget registers in `fieldRegistry`
(`web/src/components/forms/fieldRegistry.ts`) as platform code, via
`web/src/components/forms/widgets/index.ts`'s `registerBuiltinWidgets()`,
called once at application start
(`web/src/main.tsx`) — never as a tenant-side extension point.

## §4. Unrecognised or absent widget name

`FieldFactory`'s existing `fieldRegistry.get(fieldDef.xUiWidget)` miss →
built-in-switch fall-through (keyed by the field's own JSON-Schema type,
per §7.6) is the designed behaviour for both an absent `x-ui.widget` and an
unrecognised one. The field's JSON-Schema `type` is never affected by an
unrecognised `x-ui.widget` value, so the built-in switch always has a real
case to fall into: the field renders per §7.6's default for its type, it
does not error and does not disappear.

## §5. No code execution

No widget in this vocabulary evaluates a tenant-supplied string as code or
as an expression. None of the five renderers, `fieldRegistry.ts`, or
`FieldFactory.tsx` call `eval`, `new Function`, set
`dangerouslySetInnerHTML`, or assign to `.innerHTML` — verified by grep at
implementation time (see the REQ-284 implementation report). `rich-text-lite`
in particular stores and echoes its markdown-lite tokens as plain text —
never parsed to HTML by this widget (§1.1).

## §6. Field logic is deferred, not rejected

No conditional-visibility or computed-field widget is part of this
vocabulary. **This is not a rejection of field logic on principle — the
opposite: decision 0020's clause D1a (added 2026-09-08, on the mobile
offline-forms requirement) *permits* `visible_when`, `computed` fields and
cross-field validation, expressed in the `Letflow.Engine.Expr` grammar,
evaluated client-side for interactivity with mandatory server-side
re-evaluation on submit. Field logic is excluded from REQ-284 only because
D1a's own sequencing (steps 8-12) makes it a separate track whose first
deliverable is a language-neutral conformance corpus (step 9), not a
widget. A later reader must not treat this vocabulary's silence on field
logic as D1a having been re-closed here — it has not.**

## §7. Client-side validation is a UX affordance only

**Any client-side validation derived from `form_schema` (built-in or via an
`x-ui.widget`) is a UX affordance only — it improves the editing experience
but proves nothing to the server. Server-side authority for what a
submitted value must satisfy stays exclusively with `variable_schemas`
(REQ-109). A widget that appears to accept a value client-side does not
mean the server will accept it; no renderer in this vocabulary may be read
as a validation boundary.**

## §8. Scope fence

- `DynamicFormRenderer.tsx`'s compilation pipeline
  (`parseFormSchema`/`compileFormSchemaToZod`) is not changed by this
  requirement beyond `formSchemaParser.ts`'s additive `xUiWidget`/`xUiMask`
  fields — `compileFormSchemaToZod` continues to validate purely by
  JSON-Schema `type`/`format`/`enum`/etc., never by widget name, consistent
  with §7.
- `DynamicFormRenderer.tsx`'s own inlined field-rendering switch is not
  touched or reconciled with `FieldFactory` by this requirement — a known,
  pre-existing gap (`DynamicFormRenderer.tsx` does not call
  `FieldFactory`/`fieldRegistry` at all), filed as a separate finding for
  ORCH to route, not fixed here.
- No backend change: `tasks.form_schema` stays unpopulated (REQ-273's job);
  this requirement only prepares the renderer side for when real schemas
  start arriving.
