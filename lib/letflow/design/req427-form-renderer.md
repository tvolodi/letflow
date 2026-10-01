# Design — REQ-427: MOB-4 (part 2) form renderer

Owner: MOBILE-DEV. Stage: S9. Depends on REQ-294 (Dart `Letflow.Engine.Expr`
evaluator, done), REQ-426 (renderer-state framework + list renderer, done).
Builds `apps/mobile/lib/renderers/form/form.dart` (today a placeholder).

No implementation code below — signatures, type/variant shapes, widget keys,
and exact algorithms in prose/pseudocode only, per CODE-DESIGNER's own
constraint.

---

## 0. Authority sources read for this design (not guessed)

- `web/src/utils/formSchemaParser.ts`, `web/src/types/forms.ts` —
  `TaskFormField`'s actual shape and `normalizeType`'s actual JSON-Schema
  `type` → `TaskFormField.type` mapping. **This is the wire-format authority
  for a task's `form_schema`, per this requirement's own instruction** — not
  `docs/mobile/requirements.md`'s MOB-4 prose. §1 below documents where the
  two disagree.
- `web/src/components/forms/FieldFactory.tsx`, `DynamicFormRenderer.tsx` —
  which `(type, format, enum)` combination produces which control, and the
  exact ARIA/`data-testid` conventions.
- `web/src/components/forms/useFormExpressions.ts`,
  `ExpressionUnavailableBanner.tsx` — the three-way
  `ExpressionFieldState`/`unevaluable` pattern, and the "false is not the
  same as unevaluable" distinction AC3 requires.
- `docs/migration/decisions/0020-frontend-architecture.md` clause D1a — the
  client-evaluates/server-re-evaluates-and-wins rule, the offline-fillable /
  not-offline-submittable boundary (MOB-8), and the "a client-supplied value
  for a computed or hidden field is an input to be checked, never a value to
  be stored on trust" rule.
- `docs/frontend/x-ui-widget-vocabulary.md` — the **closed** 5-name
  `x-ui.widget` vocabulary (`rich-text-lite`, `masked-input`,
  `searchable-select`, `rating`, `slider`), which explicitly does **not**
  include a file-upload or reference/autocomplete widget ("deliberately not
  included... would need a backend endpoint"), and §6's exact
  visible_when/computed/cross_field_validation semantics (flat sibling
  scope, no `"variables."` prefix, evaluation order, submit-disposition
  rule quoted above).
- `apps/mobile/lib/expr/` (REQ-294) — `evaluateVisibility`,
  `evaluateComputed`, `evaluateExpression`, `FieldExpressionOutcome`
  (`DefaultVisible`/`DefaultHidden`/`Blank`/`StaleVersion`),
  `evaluatorCompatibility`/`ManifestCompatibility` — read verbatim, not
  guessed; §4 below is a thin composition over these, adding no expression
  logic of its own (D1a's "neither client may extend the grammar locally").
- `apps/mobile/lib/renderers/renderer_state.dart` /
  `renderer_state_view.dart` / `renderer_registry.dart` (REQ-419/426) — the
  six/seven-state `RendererState<T>` framework this design builds on
  unchanged, including the `UnevaluableExpression`/`UnknownFieldType`/
  `PinnedFormUnavailable` `StaleVersionReason` variants **already reserved
  in that file's own doc comments for REQ-427**.
- `apps/mobile/lib/definitions/pinned_form_resolver.dart` (REQ-424) —
  `PinnedFormResolver.resolve({taskId, formId, formVersion})` →
  `PinnedFormResolved(formSchema)` | `PinnedFormUnavailable(reason)`.
- `apps/mobile/lib/api/api_client.dart` / `api_error.dart` (REQ-421/425) —
  `PostCapableHttpGateway.post(path, {data})`, the sealed `ApiError` (9
  variants, `NetworkUnavailableError` among them), `ApiFieldError`.
- `lib/letflow/routers/tasks.ex` — `POST /api/v1/tasks/:id/complete`'s exact
  contract: request body is `conn.body_params` **directly** (no wrapper
  key — the POST body *is* the output-variables map); success (200) body is
  `complete_result_map/1`'s 6 keys (`task_id`, `instance_id`,
  `instance_status`, `current_nodes`, `variables`, `completed_at`) — read
  verbatim, confirming AC5's premise that the response carries no per-field
  value list to re-derive authority from.
- `lib/letflow/routers/instances.ex` — `POST /instances/:id/attachments`
  (multipart, REQ-211/212) — the only file-upload endpoint that exists
  anywhere in this codebase today; §1.3/§6 below wire the `file` field kind
  to it, since neither the SPA nor the closed `x-ui.widget` vocabulary has
  any file-field mechanism to mirror (§1 explains why this is the design's
  own addition, flagged as OQ-2).
- `docs/frontend/design-system.md` was not re-read in full; its §7.6 table
  is already subsumed by reading `FieldFactory.tsx`/`formSchemaParser.ts`
  directly, per this requirement's own instruction to trust the code over
  prose.

---

## 1. Field-type reconciliation — MOB-4's eleven names vs. the SPA's actual set

**Finding, stated plainly per this requirement's own instruction: MOB-4's
eleven-name list (`text, number, boolean, date, datetime, select,
multi-select, reference, file, computed, hidden`) does not match what the
SPA actually implements.** The SPA's wire-format authority
(`TaskFormField.type` in `web/src/types/forms.ts`, populated by
`formSchemaParser.ts`'s `normalizeType`) is a **7-member closed union**:
`'string' | 'number' | 'boolean' | 'date' | 'select' | 'object' | 'array'`.
`computed`/`hidden` are not members of this union at all — they are
orthogonal boolean/expression *flags* (`field.computed`, and visibility
driven by `field.visibleWhen`) that can be set on a field of **any** of the
7 types. `datetime` is not a member either — it is `type: 'string'` with
`format: 'date-time'`, a format modifier, not a type. `multi-select` and
`reference` have **zero wire representation anywhere in this codebase** —
not in `TaskFormField`, not in `fieldRegistry` (which holds exactly the 5
closed `x-ui.widget` names plus REQ-342's 2 *entity-record-only* internal
keys, `entity-localized-text`/`entity-fk-reference` — explicitly **not**
part of the tenant-facing vocabulary and not reachable from a task's
`form_schema` at all), and not in any backend route. `file` similarly has no
`TaskFormField`/`fieldRegistry` representation — `x-ui-widget-vocabulary.md`
§1 states explicitly that a file-upload widget "was deliberately not
included" because it "would need a backend endpoint this requirement's
scope fence forbids touching."

Per this requirement's own instruction ("the SPA's set wins and the
difference is reported ... never papered over"), this design:

1. Implements the renderer against the **SPA's real 7-type union**, not
   MOB-4's list, as the field-kind vocabulary's base.
2. Derives `datetime` as a format modifier on `string` (§1.2), matching the
   SPA exactly rather than inventing a sibling type.
3. Maps MOB-4's `computed` and `hidden` names onto the SPA's real
   orthogonal-flag mechanism (§1.2/§4), not a type.
4. **Adds exactly one field kind the SPA does not have: `file`** (§1.3),
   because this requirement's own acceptance-criteria text explicitly
   assigns it concrete behavior ("uploads through the API client only") —
   unlike `multi-select`/`reference`, which get no such elaboration anywhere
   in this requirement, MOB-4, or 0020. This is a **new wire-format
   addition** this design is making, not mirroring — flagged as **OQ-2**,
   not silently decided, because it means a `form_schema` authored with
   `"type": "file"` renders a real upload control on mobile but — per
   `formSchemaParser.ts`'s `normalizeType` default branch — **silently
   degrades to a plain text input on the web SPA today** (the `default:
   return 'string'` case). That inconsistency is real and belongs to
   FRONTEND-DEV/DOC-UPDATER to resolve (give the SPA a real file widget, or
   make its parser fail loudly on an unrecognized type the same way this
   design does at §1.4) — not something REQ-427 can fix by itself, since
   `web/` is out of this requirement's scope (AC6).
5. Treats `multi-select` and `reference` as **not implementable against any
   existing wire encoding** (§1.4) — a schema field attempting either is,
   correctly, this renderer's **unknown-field-type stale-version case**,
   the same outcome an actually-unknown type gets. This satisfies AC1's "at
   minimum the eleven MOB-4 names" requirement for these two names
   specifically via the *unknown-type* test case, not via a dedicated
   working widget — because no dedicated working widget can exist for a
   type the platform has never defined a wire encoding for. Reported as
   **OQ-1**: a future requirement must decide the real wire encoding before
   either name can get a real widget (e.g., `multi-select` as `type:
   "array", items: {type: "string", enum: [...]}` plus a dedicated
   `fieldRegistry` widget; `reference` as extending the closed
   `x-ui.widget` vocabulary to include `entity-fk-reference` for task forms,
   which `docs/frontend/x-ui-widget-vocabulary.md` §1 explicitly did not do).

### 1.1 `FormFieldKind` — this renderer's closed field-kind enum

```
enum FormFieldKind {
  text,        // wire: type == "string" (no format:"date-time", no enum, no x-ui.widget override changing shape)
  number,      // wire: type == "number" (json "number" or "integer", matching normalizeType's collapse of both)
  boolean,     // wire: type == "boolean"
  date,        // wire: type == "date"  OR  type == "string" && format == "date"  (SPA accepts both spellings — see §1.2)
  datetime,    // wire: type == "string" && format == "date-time"                (derived, not a top-level type — see §1.2)
  select,      // wire: type == "select"  OR  type == "string" && non-empty enum (SPA accepts both spellings — see §1.2)
  object,      // wire: type == "object"  — recognized, NOT rendered by this requirement (§1.5, out of scope, OQ-3)
  array,       // wire: type == "array"   — recognized, NOT rendered by this requirement (§1.5, out of scope, OQ-3)
  file,        // wire: type == "file"    — this design's own addition (§1.3/OQ-2), not in the SPA
}
```

`FormFieldKind.fromFieldSchema(Map<String, dynamic> fieldSchema) ->
FormFieldKind?` — returns `null` (never throws) for any `type` string
outside the 9 wire spellings resolved above, so the caller (§2) can
distinguish "recognized kind" from "drift" and produce `UnknownFieldType`
itself, mirroring `EntityFieldType.fromWire`'s exact null-on-miss
convention (REQ-426 §3.4).

### 1.2 Exact per-kind wire resolution (ported from `normalizeType` +
`FieldFactory.tsx`'s branch conditions, not re-derived from scratch)

| `FormFieldKind` | Wire condition (checked in this order) |
|---|---|
| `boolean` | `type == "boolean"` |
| `select` | `type == "select"`, **or** `type == "string"` and `enum` is a non-empty array |
| `date` | `type == "date"`, **or** `type == "string"` and `format == "date"` |
| `datetime` | `type == "string"` and `format == "date-time"` |
| `number` | `type == "number"` or `type == "integer"` |
| `object` | `type == "object"` |
| `array` | `type == "array"` |
| `file` | `type == "file"` (§1.3, this design's own addition) |
| `text` | `type == "string"`, none of the above `string` sub-conditions matched |

Every other `type` value (including the literal strings `"multi-select"`,
`"reference"`, `"hidden"`, `"computed"`, or any other unrecognized token)
→ `FormFieldKind.fromFieldSchema` returns `null` (§1.4/§2.2).

**`computed` and `hidden` are never checked here at all** — they are read
independently, off the same `x-ui` object every other `x-ui` key comes from
(`x-ui.computed`, a string expression; visibility comes from
`x-ui.visible_when`, also a string expression — there is no `x-ui.hidden`
key anywhere in the vocabulary), exactly mirroring `formSchemaParser.ts`'s
own `field.computed`/`field.visibleWhen` being set independently of
`field.type` (§0, §4).

### 1.3 `file` — this design's own wire-format addition (OQ-2)

- Wire shape: `{"type": "file", "title": "...", ...}` — no `x-ui.widget`
  needed (there is no closed-vocabulary widget for it; `type: "file"` is
  itself the signal, unlike every other kind which is layered under
  `type: "string"`/`"number"`/etc.).
- Rendered control: a button ("Choose file" / "Replace file") plus, once a
  file is picked, the picked file's name and an upload-progress/outcome
  indicator (§6.3).
- **The field's *value*, once uploaded, is the attachment's `id` (a UUID
  string)** returned by `POST /instances/:id/attachments` (§6.3) — never
  raw bytes, and never the attachment's full JSON metadata object. This is
  the literal meaning of "uploads through the API client only": the file
  content leaves the device exactly once, via the existing attachment
  endpoint, and the task-completion payload (§5.2) carries only a
  reference to it, the same shape every other field's value takes (a JSON
  scalar).
- Until upload completes, the field's value is absent from the
  in-memory form-values map (§3) — not `null`, not a placeholder string —
  so a premature submit attempt before an in-flight upload finishes
  surfaces as a normal "required field missing" client-side check if the
  field is `required`, or is simply omitted if not, rather than smuggling
  a local file path or blob reference into `output_variables`.

### 1.4 Unknown kind — `UnknownFieldType` (AC1's "unknown field type" case)

Any field whose `FormFieldKind.fromFieldSchema` returns `null` (§1.1/§1.2)
makes the **whole form** render `RendererStaleVersion(UnknownFieldType(
fieldName: <name>, rawType: <the raw "type" string, or "" if absent/non-string>))`
— never just that one field skipped or defaulted, matching REQ-426 §3.3's
"fails loudly" precedent exactly (`entities.ex`'s nine-type list there;
this requirement's 9-wire-spelling list here, §1.2's table). This is how
AC1's "`multi-select`"/"`reference`" cases are exercised (§1's point 5) as
well as a genuinely-future, not-yet-invented type string.

### 1.5 `object`/`array` — recognized but not rendered (OQ-3)

`FormFieldKind.object`/`.array` are **not** `null` (they are recognized,
real SPA types — rendering one is simply out of MOB-4's stated scope, which
names none of the SPA's structural types). This design's own top-level form
loop (§3) only ever iterates the pinned schema's **top-level `properties`**
keys, mirroring `DynamicFormRenderer.tsx`'s own `Object.entries(formFields)`
loop over `parsed.properties` exactly (never recursing into `.properties`/
`.items` of a nested field) — consistent with
`x-ui-widget-vocabulary.md` §6's own scope fence ("the set of names a field
expression may reference is *exactly* the top-level keys," "a multi-segment
dotted path is always out of scope"). A top-level field of kind
`object`/`array` is therefore recognized (not stale-version) but rendered
as a fixed, non-editable placeholder row stating "this field type is not
yet editable on mobile" (a real `Key('form-field-<name>')`-keyed widget,
distinct from both the six-state stale-version screen and a normal editable
input) — **not submitted** (omitted from `output_variables`, since there is
no editing UI to have produced a value for it). Flagged as OQ-3 for a
future requirement if a real tenant schema needs a nested object/array task
field on mobile.

---

## 2. Schema parsing — `FormFieldDef` / `FormSchema.parse`

### 2.1 `FormFieldDef` — one field's fully-resolved definition

```
@immutable
class FormFieldDef {
  const FormFieldDef({
    required this.name,
    required this.kind,          // FormFieldKind, never null (a null kind short-circuits parsing, §2.2)
    required this.title,         // String — field.title ?? name, matching FieldFactory.tsx's fallback
    required this.required,      // bool
    this.description,            // String?
    this.enumValues,             // List<String>?  — only for FormFieldKind.select
    this.visibleWhenExpr,        // String?        — raw x-ui.visible_when
    this.computedExpr,           // String?         — raw x-ui.computed
    this.crossFieldValidation,   // ({String expression, String message})? — raw x-ui.cross_field_validation
  });
}
```

One `FormFieldDef` per top-level `properties` entry, in the same iteration
order the raw JSON object's keys appear in (Dart's `Map` from
`jsonDecode` preserves insertion order, matching
`Object.entries()`'s own ES2015+ guarantee the SPA relies on).

### 2.2 `FormSchema.parse`

```
sealed class FormParseResult {}
final class FormParseOk extends FormParseResult {
  const FormParseOk(this.fields);
  final List<FormFieldDef> fields;
}
final class FormParseUnknownFieldType extends FormParseResult {
  const FormParseUnknownFieldType({required this.fieldName, required this.rawType});
  final String fieldName;
  final String rawType;
}

FormParseResult parseFormSchema(Map<String, dynamic>? formSchema)
```

- `formSchema == null` or missing/non-map `"properties"` → `FormParseOk(
  fields: [])` — an empty form is valid (mirrors `parseFormSchema`'s own
  "no properties → `{}`" branch), not an error.
- Each `properties` entry: read `type` (string), `x-ui` (map, all four keys
  optional per §0's schema-authority precedent), `enum` (only consulted
  when relevant per §1.2's table), `required` via the schema's own
  top-level `required: [...]` array (a field name's presence there sets
  `FormFieldDef.required = true`), exactly mirroring `parseField`'s
  `requiredFields` `Set` handling.
- `FormFieldKind.fromFieldSchema` returning `null` for any entry
  short-circuits the **whole** parse: returns
  `FormParseUnknownFieldType(fieldName, rawType)` immediately — not a
  partial `FormParseOk` with that one field dropped (§1.4's "whole form,
  not one field" rule applies at parse time, before any rendering begins).
- **Never throws.** A malformed `formSchema` (not a map, `properties` not a
  map, etc.) is read as leniently as `parseFormSchema`'s own defensive
  casts, defaulting to the same "empty form" `FormParseOk([])` rather than
  crashing — consistent with `PinnedFormResolver`'s own "a `null`
  `form_schema` is a resolved result, not an unavailable one" precedent (a
  malformed-but-present schema is treated the same permissive way, since no
  acceptance criterion here asks for a dedicated "malformed schema" state
  beyond the per-field unknown-type case already covered).

---

## 3. `FormViewModel` / `FormRendererController` — the renderer's own state

### 3.1 `FormViewModel` — the `RendererContent<T>` payload (§2.1's `T`)

```
@immutable
class FormViewModel {
  const FormViewModel({
    required this.fields,              // List<FormFieldDef>  (§2.1)
    required this.values,              // Map<String, Object?> — current live form values, top-level keys only
    required this.visibility,          // Map<String, FieldExpressionOutcome> — keyed by field name carrying visible_when
    required this.computedValues,      // Map<String, FieldExpressionOutcome> — keyed by field name carrying computed
    required this.crossFieldMessages,  // Map<String, String?> — keyed by field name carrying cross_field_validation; null = passes
    required this.crossFieldUnevaluable, // Map<String, String> — field name -> reason, for an unevaluable cross-field rule
    required this.fileUploads,         // Map<String, FileUploadOutcome> — §6.3, keyed by file-kind field name
    required this.submitOutcome,       // FormSubmitOutcome? — §5.3, null until a submit attempt happens
  });
}
```

`RendererState<FormViewModel>` is this requirement's `T` everywhere
`RendererStateView<FormViewModel>` (REQ-426, unchanged) is used.

### 3.2 `FormRendererController` — owns the above, mirrors
`ListRendererController`'s `ChangeNotifier` + explicit-methods style

```
class FormRendererController extends ChangeNotifier {
  FormRendererController({
    required this.client,            // PostCapableHttpGateway
    required this.pinnedFormResolver,// PinnedFormResolver (REQ-424)
    required this.manifestCapabilities, // List<String> — the shipped expr manifest's capability tags (§4.1)
    required this.taskId,
    required this.formId,
    required this.formVersion,       // String? — per PinnedFormResolver.resolve's own signature
    required this.instanceId,        // needed for file-field upload calls (§6.3)
  });

  RendererState<FormViewModel> get state;

  Future<void> load();                                   // §3.3
  void updateFieldValue(String fieldName, Object? value); // §4.2 — recomputes visibility/computed/cross-field synchronously
  Future<void> pickAndUploadFile(String fieldName, {required String fileName, required String contentType, required List<int> bytes});
                                                           // §6.3
  Future<void> submit();                                  // §5
}
```

### 3.3 `load()` — resolving the pinned schema into the first `RendererContent`

1. `pinnedFormResolver.resolve(taskId: taskId, formId: formId, formVersion:
   formVersion)`.
2. `PinnedFormUnavailable(reason)` → `staleVersionState<FormViewModel>(
   PinnedFormUnavailable(reason: reason))` (the `StaleVersionReason`
   variant `renderer_state.dart` already reserves for this, wrapping
   REQ-424's own `PinnedFormUnavailableReason` unchanged, exactly as
   `renderer_state.dart`'s own doc comment anticipates).
3. `PinnedFormResolved(formSchema)` → `parseFormSchema(formSchema)` (§2.2):
   - `FormParseUnknownFieldType(fieldName, rawType)` →
     `staleVersionState<FormViewModel>(UnknownFieldType(fieldName:
     fieldName, rawType: rawType))`.
   - `FormParseOk(fields)` → build the initial `FormViewModel` with
     `values: {}` (empty — no field has a user-entered value yet; a
     `computed` field's *displayed* value comes from `computedValues`,
     never pre-seeded into `values` itself, mirroring
     `DynamicFormRenderer.tsx`'s own `useEffect` that writes a computed
     result into the form's live state only as a derived side effect, §4.3),
     run §4's expression pass once against these empty `values` to populate
     `visibility`/`computedValues`/`crossFieldMessages`/
     `crossFieldUnevaluable`, `fileUploads: {}`, `submitOutcome: null` — and
     set `state` to `RendererContent(data: thatViewModel)`.

No network call beyond the resolver's own (already-designed, REQ-424) fetch
is made by `load()` — this satisfies the offline-fillable requirement
directly: a cache-hit `PinnedFormResolved` (§0's `PinnedFormResolver`
contract, step 2) requires **zero** network calls, so `load()` succeeds
fully offline whenever the schema is already cached (AC2's premise).

---

## 4. On-device expression evaluation (D1a) — composition only, no new logic

### 4.1 Manifest-compatibility gate, once per `load()`

`evaluatorCompatibility(manifestCapabilities) -> ManifestCompatibility`
(REQ-294, verbatim) is called once inside `load()`, before the first
expression pass. If `!compatible`: every field carrying
`visibleWhenExpr`/`computedExpr`/`crossFieldValidation` gets
`FieldExpressionOutcome.StaleVersion(expression: <that field's own
expression string>, reason: 'this client cannot evaluate an expression
this form requires (manifest incompatible)')` in the corresponding map,
**without** attempting `evaluateVisibility`/`evaluateComputed`/
`evaluateExpression` at all — mirrors `useFormExpressions`'s own
`manifestCompatibility.compatible` early-return branch exactly (`§0`'s TS
source), including reusing the same fixed, field-agnostic reason string
class rather than a per-expression parse attempt that cannot succeed
anyway.

### 4.2 Per-change recomputation — `_recomputeExpressions(values)`

A private controller method, called by `load()` once and by
`updateFieldValue` on every call (never debounced — matches
`useFormExpressions`'s own `useMemo`-per-render semantics, which
recomputes on every keystroke that changes `watchedValues`):

1. **`computed` fields first**, in the schema's own declared order (no
   separate topological sort is designed here — §4.4/OQ-4 explains why,
   unlike REQ-293's TypeScript port). For each field with `computedExpr`:
   `evaluateComputed(computedExpr, values)` (REQ-294, verbatim) →
   `FieldExpressionOutcome`. A `Blank` outcome's *displayed* value is
   simply absent/empty (§3.1's `computedValues` map entry is `Blank`
   itself, not a separate nullable value field) — the widget layer (§6)
   renders an empty read-only control for `Blank`, matching
   `DynamicFormRenderer.tsx`'s own `compState?.kind === 'evaluated' ?
   String(compState.value ?? '') : ''` fallback-to-empty-string behavior.
   A computed field's successfully-evaluated **non-null** value (there is
   no dedicated `FieldExpressionOutcome` variant for this today — REQ-294
   §0's own `evaluateComputed` doc comment names this exact gap, "left to a
   future REQ-426/427... a future requirement may extend this sealed
   hierarchy," design §11 OQ-2 there) is resolved here, not deferred
   further: **this design extends the mapping, not the sealed hierarchy
   itself** — `_recomputeExpressions` keeps a **second**, parallel map
   outside `FieldExpressionOutcome` entirely,
   `Map<String, Object?> _resolvedComputedDisplayValues`, populated only
   when `evaluateComputed`'s underlying `evaluateExpression` call (which
   `evaluateComputed` itself does not expose — §4.4 resolves this by
   calling `evaluateExpression` directly here rather than through
   `evaluateComputed`, see §4.4) returns a successful non-null value. This
   avoids modifying REQ-294's shipped, already-tested sealed class (out of
   this requirement's stated scope to touch `apps/mobile/lib/expr/`) while
   still giving the widget layer a real value to show.
2. **`visible_when` fields next**, against `values` extended with the
   resolved computed values from step 1 (so a `visible_when` may reference
   a `computed` field's result, matching §0's vocabulary doc "evaluate
   after every computed field has produced its value"): `evaluateVisibility(
   visibleWhenExpr, extendedValues)` → `FieldExpressionOutcome` (`
   DefaultVisible`/`DefaultHidden`/`StaleVersion` only — `evaluateVisibility`
   never returns `Blank`, per REQ-294's own source, §0).
3. **`cross_field_validation` fields last**, same extended `values`,
   directly via `evaluateExpression` (not `evaluateVisibility`/
   `evaluateComputed`, neither of which fits this shape) — mirrors
   `useFormExpressions`'s own inlined cross-field loop exactly:
   - `EvaluateOk(value: true)` → `crossFieldMessages[name] = null` (passes).
   - `EvaluateOk(value: false)` → `crossFieldMessages[name] =
     field.crossFieldValidation.message`.
   - `EvaluateOk(value: <non-boolean>)` → `crossFieldUnevaluable[name] =
     'expression did not evaluate to a boolean'`.
   - Any translate/parse/eval failure → `crossFieldUnevaluable[name] =
     describeFailure(result)` (REQ-294's own function, reused verbatim).
4. A fresh `FormViewModel` is built from the updated maps and
   `notifyListeners()`'d — the same `ChangeNotifier` pattern
   `ListRendererController` already uses, so `RendererStateView`'s
   `ref.watch` rebuild story is unchanged.

### 4.3 Displaying a computed value — `FormViewModel.computedValues` +
`_resolvedComputedDisplayValues`

The widget layer (§6.2) reads, in order: if `computedValues[name]` is
`StaleVersion` → render the unevaluable banner (§6.4); else if
`_resolvedComputedDisplayValues` has an entry for `name` → render it
read-only; else (the `Blank` case) render an empty read-only control. This
two-map design is called out explicitly as **OQ-4**: a cleaner fix is
REQ-294 itself gaining a `Evaluated(value)` variant on
`FieldExpressionOutcome` (removing the need for this design's own
parallel map) — left to a future requirement since amending REQ-294's
already-shipped, already-tested file is out of THIS requirement's stated
scope (REQ-427 builds `lib/renderers/form/`, not `lib/expr/`).

### 4.4 Why `visible_when`/cross-field-validation/computed-display call
`evaluateExpression` directly here instead of only through
`evaluateVisibility`/`evaluateComputed`

`evaluateVisibility`/`evaluateComputed` (REQ-294) are convenience wrappers
already scoped to exactly the `FieldExpressionOutcome` 4-variant shape,
which (per §4.3/OQ-4) cannot represent "a computed value **and** what it
is." This design calls `evaluateVisibility` as-is for visibility (its
4-variant output is sufficient there — a visibility flag needs no
"and here is the value" companion), but for a `computed` field's actual
**display value**, and for the 3-way boolean/message/unevaluable shape
cross-field validation needs, it composes `evaluateExpression` (REQ-294's
own lower-level, always-available composed entry point, §0) directly,
exactly mirroring `useFormExpressions.ts`'s own choice to inline its
cross-field loop against `evalAst`/`parseFieldExpression rather than a
`useFormExpressions`-specific wrapper. No new expression-evaluation logic
is written — every branch above is a direct, mechanical translation of
already-shipped REQ-294 functions' documented return shapes into this
controller's own three output maps.

### 4.5 Computed-field dependency order — no topological sort (OQ-5)

Unlike `useFormExpressions.ts`'s `topoSortComputed` (REQ-293, web), this
design evaluates `computed` fields in **declaration order** (§4.2 step 1),
not a dependency-topological order. This is a deliberate, narrower scope
for REQ-427, not an oversight: MOB-4/REQ-427's acceptance criteria name
exactly one `visible_when` + one `computed` field (AC2) and never a
computed-field-referencing-another-computed-field case. Declaration order
is correct whenever no computed field references another; it silently
produces a wrong (stale, pre-update) value for a computed field that
depends on an *earlier-declared* computed field when the later one's own
dependency hasn't been recomputed yet in the SAME pass, and is simply
undefined/order-dependent for one declared *before* its dependency.
Flagged as **OQ-5**: a future requirement should port `topoSortComputed`'s
same algorithm (already proven server-side and in the TS client, §0's
`useFormExpressions.ts` reading) if/when a real tenant schema exercises
computed-on-computed on mobile — reported rather than silently built to
look complete.

---

## 5. Submit — `FormRendererController.submit()`

### 5.1 Why submit outcomes are **not** routed through `RendererState`

REQ-426's `rendererStateForError`/`RendererState` swap (§1.2 there) is
correct for a **fetch** — there is no user-entered content to protect when
a read fails. A form **submit** failure is categorically different: AC4
requires the typed values to survive a failed submit untouched. Swapping
the controller's `RendererState<FormViewModel>` to, say,
`RendererFetchFailure` on a network error during submit would discard the
in-progress `FormViewModel` (and therefore every typed value) entirely,
since `RendererState<T>`'s variants are mutually exclusive by design (§0,
REQ-426 §1.1). **This design therefore keeps `state` at
`RendererContent(FormViewModel)` for the entire submit lifecycle** and
tracks the submit's own outcome in a second, narrower sealed type living
*inside* `FormViewModel` (`submitOutcome`, §3.1) — a banner the widget
layer (§6.5) renders alongside the still-fully-rendered, still-editable
form, never replacing it.

### 5.2 `FormSubmitOutcome`

```
sealed class FormSubmitOutcome {}
final class SubmitInFlight extends FormSubmitOutcome {}
final class SubmitSuccess extends FormSubmitOutcome {
  const SubmitSuccess({required this.taskId, required this.instanceId,
    required this.instanceStatus, required this.currentNodes,
    required this.completedAt});
    // Deliberately NOT `variables` (complete_result_map's 5th key) -- see
    // §5.4's invariant: this design's own type does not even expose a slot
    // for it, so no future caller can be tempted to read it as "the
    // corrected field values."
}
final class SubmitNetworkUnavailable extends FormSubmitOutcome {}
final class SubmitValidationError extends FormSubmitOutcome {
  const SubmitValidationError({required this.fieldErrors}); // List<ApiFieldError>
}
final class SubmitOtherFailure extends FormSubmitOutcome {
  const SubmitOtherFailure({required this.cause}); // the ApiError, for debug display only
}
```

### 5.3 `submit()` algorithm

1. Build `outputVariables = Map<String, Object?>` from the current
   `FormViewModel.values`, **plus** every `computed` field's resolved
   display value from `_resolvedComputedDisplayValues` (§4.3) for any
   `computed` field not already present in `values` — this is the direct
   implementation of `x-ui-widget-vocabulary.md` §6's "both a hidden
   field's value and a computed field's value are submitted, not dropped."
   A field currently `DefaultHidden` (visibility false) is **still**
   included if it has any value in `values` — visibility is never used to
   filter the submit payload (same citation).
2. Set `submitOutcome = SubmitInFlight()`, `notifyListeners()`.
3. `client.post('/api/v1/tasks/$taskId/complete', data: outputVariables)`.
4. On success (2xx — `ApiClient.post` throws on any non-2xx, per §0's
   `ApiClient.post` reading): parse `complete_result_map`'s 6 keys;
   `submitOutcome = SubmitSuccess(...)` (§5.2's 5-field shape, `variables`
   deliberately dropped, §5.4).
5. On a thrown `ApiError`:
   - `NetworkUnavailableError` → `submitOutcome =
     SubmitNetworkUnavailable()` (AC4).
   - `ValidationError(fieldErrors: fs)` → `submitOutcome =
     SubmitValidationError(fieldErrors: fs)` (AC5's 422 case).
   - every other `ApiError` variant → `submitOutcome =
     SubmitOtherFailure(cause: error)` (not one of AC4/AC5's named cases;
     included only for the caller's own exhaustive `switch`, same
     "included for completeness" discipline REQ-426 §1.2 already
     established for its own unreachable rows).
6. **`values` is never mutated, never cleared, and nothing under this
   controller is ever persisted to any local store** at any step above —
   this is the entire mechanism behind AC4's "keeps the typed values...
   persists nothing to any store (no write queue)": there simply is no
   write-queue/cache-write code path in this design for a submit, matching
   MOB-8's scope fence exactly (§0). A second `submit()` call after a
   failed one re-sends the **current** `values`/`_resolvedComputedDisplayValues`
   (which may have changed since the failed attempt, if the user kept
   typing) — never a stale snapshot from the failed attempt.

### 5.4 Invariant: the client never re-derives authority from its own
computed values (AC5's closing clause)

`complete_result_map`'s 6th key, `"variables"` (§0), is the **instance's**
full post-merge variable set — not a per-submitted-field echo or
correction list. **This design's `SubmitSuccess` type (§5.2) has no field
for it at all** — a structural guarantee, not a code-review convention,
that a future caller cannot read `"variables"` back and use it to
overwrite/"correct" the form's own just-submitted values, silently
smuggling server-authoritative values back into a form the user believes
they already completed. On `SubmitSuccess`, the form's job is done (the
widget layer, §6.5, shows a success state and expects its caller — a
future task-detail/inbox screen, not built by this requirement — to
navigate away); it never re-renders the form body from any part of the
success response body.

---

## 6. Widget layer (`lib/renderers/form/form.dart`)

### 6.1 Registration

`Widget buildFormRenderer(BuildContext context, Map<String, dynamic>
definition)` — the `DefinitionWidgetBuilder` shape (REQ-419,
`renderer_registry.dart`, unchanged), registered as `registry.register(
"form", buildFormRenderer)` at the same bootstrap composition root
REQ-426's `"list"` registration already lives at (§0).

`definition`'s required shape, matching REQ-426 §3.2's "thin pointer, not a
duplicate" precedent: `{"task_id": "<string>", "form_id": "<string>",
"form_version": "<string, nullable>", "instance_id": "<string>"}`. Absent
or non-string `task_id`/`form_id`/`instance_id` → `RendererStaleVersion(
UnknownFieldType(fieldName: '<whichever key>', rawType: '<runtime type>'))`,
same defensive pattern `buildListRenderer` already uses for its own
`entity_type` key (§0's reading of `list.dart`).

The root widget returned is always exactly one
`RendererStateView<FormViewModel>` (AC4's structural guard from REQ-426
§4, extended here with zero rework needed — this design adds a second
registry entry to the exact same mechanism, not a parallel one).

### 6.2 Per-`FormFieldKind` input widget + key convention

`Key formFieldInputKey(String fieldName) => Key('form-field-$fieldName')` —
exported top-level, mirroring REQ-426's exported `Key` constants exactly
(one function here instead of a fixed list, since keys are per-field-name,
not per-fixed-state).

| `FormFieldKind` | Widget | Notes |
|---|---|---|
| `text` | single-line text field | |
| `number` | numeric text field | |
| `boolean` | checkbox/switch | |
| `date` | a date-picker-backed text field | |
| `datetime` | a date+time-picker-backed text field | |
| `select` | a dropdown over `enumValues` | |
| `file` | upload button + outcome indicator (§6.3) | |
| `object`/`array` | fixed non-editable placeholder row (§1.5) | not submitted |

Every widget above (except the `object`/`array` placeholder) carries
`Key(formFieldInputKey(fieldName))` on its own primary interactive element
— the element AC1's widget test asserts by key.

### 6.3 `file` field — upload flow and `FileUploadOutcome`

```
sealed class FileUploadOutcome {}
final class FileUploadInFlight extends FileUploadOutcome {}
final class FileUploadSuccess extends FileUploadOutcome {
  const FileUploadSuccess({required this.attachmentId, required this.fileName});
}
final class FileUploadNetworkUnavailable extends FileUploadOutcome {}
final class FileUploadOtherFailure extends FileUploadOutcome {
  const FileUploadOtherFailure({required this.cause});
}
```

`pickAndUploadFile(fieldName, {fileName, contentType, bytes})` (§3.2):
1. `fileUploads[fieldName] = FileUploadInFlight()`, notify.
2. `client.post('/instances/$instanceId/attachments', data: <multipart
   form-data body carrying the "file" part with fileName/contentType/bytes,
   matching `handle_upload_attachment`'s exact required-part-name
   contract, §0>)`.
3. Success (201) → parse `attachment_json/1`'s shape (§0) for `id`;
   `fileUploads[fieldName] = FileUploadSuccess(attachmentId: id, fileName:
   fileName)`; **and** `updateFieldValue(fieldName, id)` — this is the
   single point where a `file` field's entry ever appears in
   `FormViewModel.values` (§1.3).
4. `NetworkUnavailableError` → `fileUploads[fieldName] =
   FileUploadNetworkUnavailable()`; `values` untouched (no entry for
   `fieldName` at all — same "absent, not blank" rule as §1.3).
5. Any other thrown `ApiError` → `FileUploadOtherFailure(cause: error)`;
   same "values untouched" rule.

This mirrors §5's "never swap `RendererState`, never persist, never lose
what the user already has" design exactly, at the single-field scope
instead of the whole-form scope — a file-upload failure does not invalidate
any other field's already-typed value, and is retryable by calling
`pickAndUploadFile` again for the same field.

### 6.4 Visibility / computed / cross-field rendering

Directly mirrors `DynamicFormRenderer.tsx`'s own per-field branch (§0),
field row by field row:

- `visibility[name]` is `DefaultHidden` → the field's entire row is
  omitted from the widget tree (not rendered, not merely visually hidden —
  same `return null` semantics the TSX uses, so a widget test's
  `find.byKey(...)` genuinely finds nothing, distinguishing this from a
  disabled-but-present input per `ExpressionUnavailableBanner.tsx`'s own
  doc-comment distinction, §0).
- `visibility[name]` is `StaleVersion` (an unevaluable `visible_when`) →
  render `ExpressionUnavailableBanner`-equivalent (§6.4.1) **instead of**
  the field's normal input, and **the field's value from any prior successful
  evaluation is never used** — AC3's exact requirement ("not rendered
  visible, not silently hidden, not rendered blank"): this is a fourth,
  distinct visual state from "visible normal input" / "omitted (hidden)" /
  "visible but shows nothing" — a banner explicitly saying the condition is
  unavailable, keyed `Key('expr-unavailable-$name-visible_when')`.
- `computedValues[name]` is `StaleVersion` → same banner treatment, keyed
  `Key('expr-unavailable-$name-computed')`, replacing the read-only
  computed-value display (§4.3) entirely.
- `crossFieldUnevaluable[name]` non-empty → same banner treatment at the
  form level (above the field list, matching `DynamicFormRenderer.tsx`'s
  own placement), keyed `Key('expr-unavailable-$name-cross_field_validation')`.
- `crossFieldMessages[name]` non-null (a `false` cross-field result) →
  an alert row with that message, keyed `Key('cross-field-error-$name')` —
  advisory only, never wired to block `submit()` (§5.3 step 1 always
  builds and sends `outputVariables` regardless of `crossFieldMessages`'
  contents, mirroring `DynamicFormRenderer.tsx`'s own documented choice,
  §0, that this is UX feedback with no gating authority — D1a's "no
  authority whatsoever" rule applied literally).

#### 6.4.1 `ExpressionUnavailableBannerWidget`

A small reusable widget, `ExpressionUnavailableBannerWidget({required
String field, required String kind, required String reason})` where
`kind` is one of `'visible_when' | 'computed' | 'cross_field_validation'`
(mirrors `ExpressionUnavailableBanner.tsx`'s own three call sites, §0) —
renders a visible (non-dismissible) message naming the field and reason,
keyed `Key('expr-unavailable-$field-$kind')` on its own root, exactly
parallel to the TSX's own `data-testid` convention so a widget test's
assertion reads almost identically to the existing web test's selector.

### 6.5 Submit UI

A submit button, keyed `Key('form-submit-button')`, calling `submit()`.
`submitOutcome` renders, non-exclusively with the form body (§5.1):

| `FormSubmitOutcome` | Rendered | `Key` |
|---|---|---|
| `null` | nothing | — |
| `SubmitInFlight` | disabled button + spinner | `Key('form-submit-in-flight')` |
| `SubmitSuccess` | a success banner | `Key('form-submit-success')` |
| `SubmitNetworkUnavailable` | "No network connection — your answers are still here" banner | `Key('form-submit-network-unavailable')` |
| `SubmitValidationError` | a list of `fieldErrors` messages | `Key('form-submit-validation-error')` |
| `SubmitOtherFailure` | a generic failure banner | `Key('form-submit-other-failure')` |

The form's own input widgets (§6.2) are never removed or disabled by a
`submitOutcome` other than `SubmitInFlight` (which disables only the
submit button itself, not the fields) — AC4's "keeps the typed values in
the form" is therefore also a **visual** guarantee, not only a data one.

---

## 7. Cross-module dependencies

- `lib/renderers/form/form.dart` imports: `../renderer_state.dart`,
  `../renderer_state_view.dart`, `../../api/api_client.dart`
  (`PostCapableHttpGateway`), `../../api/api_error.dart` (`ApiError`,
  `ApiFieldError`), `../../definitions/pinned_form_resolver.dart`
  (`PinnedFormResolver`, `PinnedFormResolution`,
  `PinnedFormUnavailableReason`), `../../expr/expr.dart` (barrel —
  `evaluateVisibility`, `evaluateComputed`, `evaluateExpression`,
  `evaluatorCompatibility`, `FieldExpressionOutcome` and its variants,
  `describeFailure`).
- No change to `apps/mobile/lib/expr/**` (REQ-294's shipped, tested
  surface — §4.3/§4.5's open questions are explicitly deferred rather than
  patched in-place here).
- No change to `apps/mobile/lib/renderers/renderer_state.dart`,
  `renderer_state_view.dart`, `renderer_registry.dart`, or
  `apps/mobile/lib/renderers/list/**` — this requirement only adds a
  second registrant (`"form"`) alongside REQ-426's `"list"`.
- No change to `lib/` or `web/` (AC6) — every backend contract read in §0
  (`tasks.ex`'s complete route, `instances.ex`'s attachment route) is read
  as-is, unmodified.

---

## 8. Invariants

- **INV-1**: `FormFieldKind.fromFieldSchema`'s resolution table (§1.2) is
  the **only** place a wire `type`/`format`/`enum` combination is mapped to
  a rendering kind — no second, divergent switch exists elsewhere in this
  design.
- **INV-2**: An unknown field type (§1.4) always stale-versions the
  **whole** form before any partial `RendererContent` is ever constructed
  — never a per-field silent skip, matching REQ-426 §3.3's list-renderer
  precedent and MOB-4's own "fails loudly" doctrine.
- **INV-3**: `values`/`_resolvedComputedDisplayValues` are the **only**
  place user/computed data lives in this design — there is no cache
  table, no local database row, no write-queue entry, anywhere a submit or
  upload failure could leave orphaned state behind (the structural basis
  for AC4's "persists nothing to any store").
- **INV-4**: `submit()` (§5.3) always sends the request once client-side
  checks (Zod-equivalent/required-field checks, left to MOBILE-DEV as
  ordinary form-level validation, not itself an expression-evaluation
  concern) pass, **regardless of** `crossFieldMessages`'/
  `crossFieldUnevaluable`'s contents — D1a's "client evaluation carries no
  authority" applied literally to the one place this design could have
  been tempted to gate on it.
- **INV-5**: `SubmitSuccess` (§5.2) structurally cannot expose
  `complete_result_map`'s `"variables"` key — enforced by the type's own
  field list having no slot for it, not by caller discipline alone (§5.4).
- **INV-6**: `RendererState<FormViewModel>` is never swapped away from
  `RendererContent` by a submit-time or file-upload-time failure — only
  `load()` (§3.3) ever produces `RendererStaleVersion`/other non-content
  states for this controller.

---

## 9. Acceptance-criteria resolution map

- **AC1** ("one widget test per field type ... at minimum the eleven
  MOB-4 names ... an unknown field type yields stale-version"): §1's
  reconciliation table + §1.1's `FormFieldKind` + §1.4/§6.2's Key
  convention give every one of the 7 SPA-real kinds (`text`, `number`,
  `boolean`, `date`(+`datetime`), `select`) plus this design's own `file`
  addition a dedicated, keyed widget; `multi-select`/`reference` are
  satisfied via the unknown-type case (§1's point 5, explicitly not a
  dedicated widget, and explained why); `computed`/`hidden` are satisfied
  via §4.3's read-only display and §6.4's DOM-omission respectively
  (neither is a `FormFieldKind`, both are real, tested behaviors). The
  unknown-type test itself: a schema with a field whose `type` is a
  fabricated string (or `"multi-select"`/`"reference"` literally) →
  `RendererStaleVersion(UnknownFieldType(...))` (§1.4).
- **AC2** ("cached schema with visible_when + computed, network
  unavailable, change an input, dependent field's visibility/computed
  value update"): §3.3's zero-network `load()` on a cache hit +
  §4.2/§4.3's synchronous, offline-capable `_recomputeExpressions` on
  every `updateFieldValue` call — no network call anywhere in this path
  (§0's `PinnedFormResolver` cache-hit contract + REQ-294's evaluator being
  a pure function with no I/O, §0).
- **AC3** ("expression the evaluator rejects → stale-version, field not
  rendered visible / not silently hidden / not rendered blank"): §6.4's
  explicit fourth visual state (`ExpressionUnavailableBannerWidget`,
  keyed distinctly from both "omitted" and "visible normal input") + §4.2
  step 2's `StaleVersion` outcome from `evaluateVisibility`, never
  silently coerced to `DefaultHidden`/`DefaultVisible`.
- **AC4** ("submit, network unavailable → shows network-unavailable, keeps
  typed values, persists nothing"): §5.1's whole rationale + §5.2's
  `SubmitNetworkUnavailable` + §5.3 step 6 + §6.5's table + INV-3/INV-6.
- **AC5** ("on-device validation passes → submit still sent with
  user-entered values; server 422 → validation-error state even though
  client passed; client never re-derives authority from its own computed
  values since the complete response carries no field values"): INV-4 (the
  request is always sent once client checks pass) + §5.2's
  `SubmitValidationError` (from a real `ValidationError` `ApiError`, itself
  from a real 422, §0) + §5.4/INV-5 (the structural guarantee
  `SubmitSuccess` cannot carry `"variables"` back into the form).
- **AC6** (`git diff origin/main --stat -- lib/ web/` empty): §7 — every
  backend contract is read, never modified; confirmed empty at design
  time (§0).
- **AC7** (`flutter analyze && flutter test` pass): not a design-time
  criterion — MOBILE-DEV/TEST-RUNNER's job at build/verify time; every
  new public surface above is fully typed, and no dynamic/`Object?`-typed
  value crosses an API boundary without an explicit cast/check already
  specified (matching REQ-426 §8's own closing note).

---

## 10. Open questions (explicit — not silently resolved)

- **OQ-1**: `multi-select` and `reference` have no real wire encoding
  anywhere in the platform today (§1's point 5). A future requirement must
  invent one (and, for `reference`, decide whether it extends the closed
  `x-ui.widget` vocabulary or introduces a separate mechanism) before
  either can get a real widget on any client, not only mobile.
- **OQ-2**: This design's own `type: "file"` wire-format addition (§1.3)
  is not mirrored by the SPA, which silently defaults an unrecognized
  `type` to `'string'` (`normalizeType`'s default branch, §0) rather than
  rendering an upload control or failing loudly. Flagged for
  FRONTEND-DEV/DOC-UPDATER: either give the SPA a real file-field
  implementation reusing the same `type: "file"` convention, or make its
  parser fail loudly on an unrecognized type too, so a cross-platform
  tenant schema does not silently behave differently per client.
- **OQ-3**: Top-level `object`/`array` fields are recognized but rendered
  as a fixed non-editable placeholder and never submitted (§1.5). No
  acceptance criterion here requires a real nested editor; a future
  requirement may add one.
- **OQ-4**: `FieldExpressionOutcome` (REQ-294) has no variant for "a
  computed expression evaluated successfully to a non-null value" — this
  design works around it with a second, parallel
  `_resolvedComputedDisplayValues` map (§4.3) rather than amending
  REQ-294's shipped sealed class. A future requirement could add an
  `Evaluated(value)` variant there instead, removing this design's
  workaround.
- **OQ-5**: Computed-field evaluation order is declaration order, not a
  dependency-topological sort (§4.5) — correct for every case this
  requirement's acceptance criteria actually exercise, wrong for a
  computed-field-referencing-computed-field schema in general. A future
  requirement should port `useFormExpressions.ts`'s `topoSortComputed`
  algorithm if that case is ever authored for a mobile-rendered form.
- **OQ-6**: `docs/mobile/requirements.md`'s MOB-4 acceptance-criteria
  prose ("text, number, boolean, date, datetime, select, multi-select,
  reference, file, computed, hidden") should be corrected by
  DOC-UPDATER to reflect §1's reconciliation (7 real SPA types + 2
  orthogonal flags + this requirement's own `file` addition, with
  `multi-select`/`reference` named as not-yet-encoded rather than
  implied-supported) — reported here per this task's own instruction,
  not silently left standing.
