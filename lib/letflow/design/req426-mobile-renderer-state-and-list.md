# Design — REQ-426: MOB-4 (part 1) renderer state framework + list renderer
# (`apps/mobile/lib/renderers/`)

Owner: MOBILE-DEV. Stage: S9. Depends on REQ-424 (pinned form resolution,
done/merged), REQ-425 (`ApiError`/`ApiClient` hardening, done/merged).

No implementation code below — signatures, type/variant shapes, widget
keys, and exact algorithms in prose/pseudocode only.

---

## 0. Current state (read before design, not guessed)

- `apps/mobile/lib/api/api_error.dart` — the sealed `ApiError` (REQ-425,
  landed): `NetworkUnavailableError`, `UnauthorizedError`, `ForbiddenError`,
  `NotFoundError`, `ModuleNotAvailableError`, `BackpressureError
  (retryAfterSeconds)`, `ValidationError (fieldErrors: List<ApiFieldError>)`,
  `ConflictError`, `ServerError (lastStatusCode)`. `classifyError/4` is the
  one place a status code becomes one of these. Every `ApiClient` method
  (`get`, `getUnauthenticated`, `post`) throws one of these, never a raw
  `DioException`.
- `apps/mobile/lib/definitions/pinned_form_resolver.dart` (REQ-424) already
  anticipates this requirement: its `PinnedFormResolution` sealed type's
  `PinnedFormUnavailable` variant's own doc comment says explicitly "Renders
  as `MOB-4`'s `stale-version` state (REQ-426..428's own build surface)."
  This design's `RendererState.staleVersion` is that state.
- `apps/mobile/lib/renderers/renderer_registry.dart` (REQ-419) — a
  `RendererRegistry` keyed by definition-type string (`"form"`, `"list"`,
  `"process"`, `"task"`), already falling back to
  `UnsupportedDefinitionTypeWidget` (keyed `unsupportedDefinitionTypeKey`)
  for an unregistered type. This requirement does not change that fallback;
  it registers the `"list"` builder into this same registry for the first
  time.
- `apps/mobile/lib/renderers/{form,list,process,task}/{form,list,process,task}.dart`
  are placeholder libraries today ("carries no logic yet"). This
  requirement fills in `list/list.dart`'s design only. `form`, `process`,
  `task` stay placeholders (REQ-427/428 build them) — but AC4's guard must
  already be structured so it extends to them without rework.
- Backend contract read directly from `lib/letflow/routers/entities.ex` and
  `lib/letflow/entities/query/types.ex` (not from `web/`'s TypeScript types,
  though `web/src/pages/entities/EntityListBrowserPage.tsx` /
  `EntityFilterBuilder.tsx` confirm the same shape from the SPA's own call
  site — see §4.1).

---

## 1. The shared six-state framework (`lib/renderers/renderer_state.dart`,
new file)

### 1.1 `RendererState<T>` — the sealed type every renderer builds against

A Dart 3 `sealed class RendererState<T>`, generic over the renderer's own
"loaded content" type `T` (e.g. for the list renderer, `T` is the list
renderer's own page-of-records view-model, §4.6). Seven variants — the six
mandatory states plus the one success state a "state wrapper" necessarily
also needs to represent:

| Variant | Fields | Meaning |
|---|---|---|
| `RendererLoading<T>` | (none) | An in-flight fetch with no result yet. |
| `RendererContent<T>` | `data: T` | Success — the renderer's own body is shown. Not one of the six mandatory states; every renderer needs a seventh "it worked" state to have anything to wrap. |
| `RendererFetchFailure<T>` | `cause: Object?` | AC1's "fetch-failure" state. |
| `RendererPermissionDenied<T>` | (none) | AC1's "permission-denied" state. |
| `RendererStaleVersion<T>` | `reason: StaleVersionReason` | AC1's "stale-version" state (§1.3). |
| `RendererValidationError<T>` | `fieldErrors: List<ApiFieldError>` | AC1's "validation-error" state. |
| `RendererBackpressure<T>` | `retryAfterSeconds: int` | AC1's "429-backpressure" state (§1.4/§2). |

Each variant is `@immutable`, a `final class extends RendererState<T>`
(sealed + final, per the same Dart-3-exhaustiveness pattern
`ApiError` already uses — REQ-425 §1.1's precedent). No variant carries a
widget or `BuildContext`; the mapping to a widget is §3's job, kept
separate from this pure state shape so a widget test can construct a
`RendererState` value directly with no `BuildContext` in scope.

### 1.2 `ApiError` → `RendererState` mapping — `rendererStateForError<T>`

`RendererState<T> rendererStateForError<T>(ApiError error)` — the single
function every renderer's error-handling path calls, exhaustive over
`ApiError`'s 9 variants (a `switch` over `ApiError` the analyzer checks is
exhaustive, mirroring `classifyError`'s own switch-like `if` chain in
`api_error.dart` — implemented as a `switch` here since Dart 3 sealed
classes support pattern-matching `switch` expressions). Exact mapping,
first-match order irrelevant since `ApiError` is sealed (each case is a
distinct type):

| `ApiError` variant | `RendererState` variant | Rationale |
|---|---|---|
| `ForbiddenError` | `RendererPermissionDenied` | Direct 403 mapping (AC1 item 3). |
| `BackpressureError(retryAfterSeconds: n)` | `RendererBackpressure(retryAfterSeconds: n)` | Direct 429 mapping (AC1 item 6), carries the header value through unchanged. |
| `ValidationError(fieldErrors: fs)` | `RendererValidationError(fieldErrors: fs)` | Direct 422 mapping (AC1 item 5), carries the parsed field errors through unchanged. |
| `NetworkUnavailableError` | `RendererFetchFailure(cause: error)` | AC1 item 2's "network ApiError" case. |
| `ServerError` | `RendererFetchFailure(cause: error)` | 5xx after `ApiClient`'s own retry/backoff is exhausted — a fetch failure from the renderer's point of view. |
| `ConflictError` | `RendererFetchFailure(cause: error)` | 409 has no dedicated one of the six states; folds into the generic fetch-failure bucket (open question OQ-1). |
| `NotFoundError` | `RendererFetchFailure(cause: error)` | A bare 404 (not a module-scoped one) has no dedicated state either; same bucket as `ConflictError` (OQ-1). |
| `ModuleNotAvailableError` | `RendererFetchFailure(cause: error)` | Not reachable from this requirement's own two calls (`/entities/...` is not a `/api/v1/modules/<id>/...` path), included only for the `switch`'s exhaustiveness. |
| `UnauthorizedError` | `RendererFetchFailure(cause: error)` | **Should not normally reach this function at all** — `ApiClient._handleUnauthorized` already exhausts the refresh-then-retry flow and, on terminal failure, itself calls `LoginRouter` to navigate away before the exception value the caller sees ever reaches a renderer's `catch`. Mapped here only so the `switch` is total; a widget test forcing this case is testing defensive completeness, not a reachable user-visible path (OQ-2). |

### 1.3 `StaleVersionReason` — the definition-layer half (not from `ApiError`
at all)

A second, separate sealed class, `StaleVersionReason` (same file), because
the requirement text is explicit that stale-version is populated "from the
definition layer" as well as from `ApiError` — these causes never arrive as
an HTTP status code:

- `UnknownDefinitionType(definitionType: String)` — a `RendererRegistry`
  lookup miss reachable *inside* a renderer that itself embeds a nested
  definition of unknown type (not the top-level
  `UnsupportedDefinitionTypeWidget` fallback in `renderer_registry.dart`,
  which is a separate, already-shipped REQ-419 mechanism outside this
  state framework's scope — see OQ-3 on how the two relate).
- `UnknownFieldType(fieldName: String, rawType: String)` — an entity/form
  field whose `"type"` string is outside the closed set the client knows
  (for the list renderer: outside `entities.ex`'s nine
  `@field_type_strings`, §4.1).
- `UnevaluableExpression(expression: String, reason: String)` — a
  `Letflow.Engine.Expr`-grammar expression (`computed`/`visible_when`) the
  on-device evaluator cannot evaluate. Not exercised by the list renderer
  (no expressions in an entity definition); reserved for the form renderer
  (REQ-427).
- `PinnedFormUnavailable(reason: PinnedFormUnavailableReason)` — wraps
  REQ-424's own `PinnedFormUnavailableReason` enum
  (`versionMissing`/`fetchFailed`) unchanged, per this requirement's own
  text ("REQ-424's pinned-version-unavailable ... are stale-version"). Not
  exercised by the list renderer either; reserved for the task/form
  renderers (REQ-427/428) that call `PinnedFormResolver`.

A companion function `RendererState<T> staleVersionState<T>(StaleVersionReason
reason)` wraps a reason into a `RendererStaleVersion<T>`.

### 1.4 `Retry-After` countdown mechanism — `BackpressureCountdown`

A plain (non-widget) controller class, `BackpressureCountdown`, owned by
the widget in §3.3, that turns a `RendererBackpressure`'s
`retryAfterSeconds` into a ticking countdown and exactly one retry call at
zero:

- Constructor: `BackpressureCountdown({required int initialSeconds,
  required Future<void> Function() onZero})`.
- Field `secondsRemaining: int`, initialized to `initialSeconds`, exposed
  via a `ValueListenable<int>` (`ValueNotifier<int>` internally) so the
  widget in §3.3 rebuilds only the countdown text, not the whole subtree.
- `void start()` — begins a `Timer.periodic(const Duration(seconds: 1),
  ...)`. Each tick: decrements `secondsRemaining` by 1 and notifies. When
  `secondsRemaining` reaches `0`: **cancels the timer first** (so a slow
  `onZero` can never overlap a second tick), then calls `await onZero()`
  exactly once. `onZero`'s own exceptions are caught internally and
  swallowed after logging (AC2's "the app does not throw" — a retry that
  itself fails must re-enter this same state framework as a new
  `RendererState`, e.g. another `RendererBackpressure` or a
  `RendererFetchFailure`, via the caller's own fetch-wrapping logic in
  §3.2 — not propagate as an uncaught `Future` error).
- `void dispose()` — cancels the timer if still running. Called from the
  owning widget's `State.dispose()`, so navigating away mid-countdown never
  leaves a dangling `Timer` calling `onZero` against an unmounted widget.
- **Exact tick semantics for AC2's "shows 3, 2, 1"**: with
  `initialSeconds: 3`, the countdown text reads `3` immediately on
  `start()` (before the first tick — the initial value, never `4` or a
  pre-decrement value), `2` after the first 1-second tick, `1` after the
  second, and triggers `onZero` (with the text having shown `1` for one
  full second) after the third tick reaches `0` — the text itself never
  visibly shows `0`; the widget transitions to a "retrying" sub-state (an
  implementation choice for MOBILE-DEV — see §3.3) at the same moment
  `onZero` fires. A widget test drives this with `tester.pump(const
  Duration(seconds: 1))` three times (real `Timer`s are intercepted by
  `flutter_test`'s fake clock inside a widget test's zone, needing no
  injected clock/delay-function seam — unlike REQ-425's `ApiClient`, which
  needed one because its retries aren't driven by a widget test's pump
  loop).

---

## 2. Widget contract — `RendererStateView<T>` (`lib/renderers/renderer_state_view.dart`, new file)

### 2.1 Signature

A single reusable `StatefulWidget`:

```
RendererStateView<T>({
  Key? key,
  required RendererState<T> state,
  required Widget Function(BuildContext, T) contentBuilder,
  required Future<void> Function() onRetryBackpressure,
})
```

- `state` — the current `RendererState<T>` (§1.1), supplied by the caller's
  own controller/provider — this widget holds no fetch logic itself, only
  presentation per state.
- `contentBuilder` — builds the renderer's real body for
  `RendererContent<T>.data`.
- `onRetryBackpressure` — invoked by the internal `BackpressureCountdown`
  when its timer reaches zero (§1.4). The caller is responsible for this
  performing exactly one re-fetch and producing a new `RendererState<T>`
  (which flows back into this widget via a rebuild with a new `state`
  value — `RendererStateView` does not call `setState` on its own `state`
  input; it is a controlled/presentational widget, matching
  `RendererRegistry`'s own "renderers are pure functions of their inputs"
  style).

### 2.2 Per-state build output and widget keys (AC1's "assert the state's
dedicated widget by key")

`RendererStateView.build` is a `switch` over `state` (exhaustive, sealed):

| `RendererState` variant | Rendered widget | `Key` |
|---|---|---|
| `RendererLoading` | A centered `CircularProgressIndicator` | `rendererLoadingKey` |
| `RendererContent` | `contentBuilder(context, data)`, wrapped in a `KeyedSubtree` | `rendererContentKey` |
| `RendererFetchFailure` | A centered message + retry affordance (e.g. `Text` + a retry button — exact copy/layout left to MOBILE-DEV, not load-bearing for tests) | `rendererFetchFailureKey` |
| `RendererPermissionDenied` | A centered "you don't have access" message | `rendererPermissionDeniedKey` |
| `RendererStaleVersion` | A centered "this app needs an update" message, optionally showing `reason`'s runtime type/detail for debug builds only (never leaks raw schema content in release) | `rendererStaleVersionKey` |
| `RendererValidationError` | A list of `fieldErrors` messages | `rendererValidationErrorKey` |
| `RendererBackpressure` | The `BackpressureCountdownWidget` (§3.3) | `rendererBackpressureKey` |

Every key above is a top-level `const Key(...)` constant exported from
`renderer_state_view.dart`, so a widget test imports and asserts on it
directly (`expect(find.byKey(rendererFetchFailureKey), findsOneWidget)`)
without needing to know this file's internal widget classes.

### 2.3 `BackpressureCountdownWidget` — internal, backs the `RendererBackpressure` case

A `StatefulWidget` taking `retryAfterSeconds: int` and `onZero: Future<void>
Function()` (forwarded from `RendererStateView.onRetryBackpressure`).
`initState` constructs a `BackpressureCountdown(initialSeconds:
retryAfterSeconds, onZero: onZero)` and calls `start()`; `dispose` calls the
controller's `dispose()`. `build` renders the countdown number inside a
`Text` keyed `backpressureCountdownTextKey` (a second exported constant,
distinct from `rendererBackpressureKey` which keys the *container* —
AC2 needs to assert the number's text content changing across three
frames, which requires locating the `Text` widget specifically, not just
its container), listening to the controller's `ValueListenable<int>` via a
`ValueListenableBuilder<int>`.

**AC2's "exactly one retry request is issued"**: guaranteed structurally by
§1.4's "cancels the timer before calling `onZero`, calls it exactly once" —
there is no retry loop or repeated-call path anywhere in this mechanism.
The widget itself never calls `onZero` a second time on its own (e.g. no
"tap to retry now" button in this requirement's scope — out of scope,
not an acceptance criterion here; the six-state minimum does not require
a manual override, and adding one is an open question, OQ-4, for a later
requirement rather than silently included here).

---

## 3. List renderer (`lib/renderers/list/list.dart`)

### 3.1 Registration

`list.dart` exports a single top-level function,
`Widget buildListRenderer(BuildContext context, Map<String, dynamic>
definition)` — the exact `DefinitionWidgetBuilder` shape
`renderer_registry.dart` already declares (§0). Whichever bootstrap code
wires up the app's one `RendererRegistry` instance (out of this
requirement's scope — REQ-419's registry is already there; wiring a
concrete builder into it for `"list"` is this requirement's one line of
integration) calls `registry.register("list", buildListRenderer)`.

### 3.2 The `"list"` definition's own required shape

Per this requirement's own text — "reads the entity definition ... and
queries records" — a `"list"`-typed definition's JSON payload (the
`definition` parameter above) is a thin pointer, not a duplicate of the
entity's own field list:

```
{ "entity_type": "<string, required>" }
```

`buildListRenderer` reads `definition["entity_type"]` (throws/renders
`RendererStaleVersion(UnknownFieldType(...))` if absent or non-string —
treated the same as any other definition-shape drift, per §1.3). No other
key is read by this requirement. (Open question OQ-5: a future requirement
may add optional keys here — e.g. a fixed display-column list or
default filters — REQ-426 does not need them because AC3 only requires
filtering and pagination to work, not a curated column set; the list
renderer's default column set is "every field the entity definition
reports," mirroring `EntityListBrowserPage.tsx`'s own
`fields.map(...)` fallback, §0.)

### 3.3 The two backend calls — exact contract (read from `entities.ex`, not
guessed)

**Call 1 — `GET /api/v1/entities/definitions/active/:name`**, `:name` =
`definition["entity_type"]`.

- 200 body:
  ```
  { "id": "<uuid>", "name": "<string>", "display_name": "<string>",
    "definition": { "fields": [ { "name": "<string>", "type": "<field-type>",
                                   "queried": <bool>, ... } , ... ] },
    "content_hash": "<hex>", "logical_shape_version": "<hex>",
    "artifact_version_id": "<uuid|null>", "status": "<string>",
    "inserted_at": "<iso8601>" }
  ```
  The list renderer reads only `definition.definition.fields` — a list of
  `EntityFieldDef`-shaped maps (§3.4). Every other top-level key is
  ignored by this requirement (not "TBD" — simply unused; a future
  requirement may read `display_name` for a screen title).
- `field.type` is one of the nine closed strings `entities.ex`'s
  `@field_type_strings` emits: `string`, `integer`, `decimal`, `boolean`,
  `date`, `datetime`, `enum`, `json`, `localized_text`. A field whose
  `type` is outside this set (a client that has drifted from a newer
  server) is this requirement's own `UnknownFieldType` stale-version case
  (§1.3) — the WHOLE list renderer renders `RendererStaleVersion`, not
  just that one field silently dropped, matching the "fails loudly"
  principle (`architecture.md` §5/`requirements.md` MOB-4).
- 404 (entity type nonexistent, or caller lacks `EntitiesDefinitionsRead`
  authorization for it — `entities.ex`'s `render_get_definition/3`
  collapses both to the same zero-detail 404, INV-5) → `ApiClient` throws
  `NotFoundError` → §1.2's mapping → `RendererFetchFailure` (not
  `RendererPermissionDenied` — see §1.2's `NotFoundError` row and OQ-1;
  this call structurally cannot surface `RendererPermissionDenied` for a
  real backend response, only a forced test can).

**Call 2 — `POST /api/v1/entities/query`**, issued only after Call 1
succeeds (never in parallel — the filter UI needs the field list first to
know which fields/operators are valid, matching `EntityListBrowserPage`'s
own sequencing, §0).

- Request body (top-level JSON object):
  ```
  { "entity_type": "<string, same value as definition["entity_type"]>",
    "filters": [ { "field": "<string>", "op": "<filter-op>", "value": <any, omitted for is_null/is_not_null> }, ... ],
    "sort": [ { "field": "<string>", "dir": "asc"|"desc" }, ... ],
    "cursor": "<string, omit/null for page 1>",
    "page_size": <int, omit for server default 50, hard ceiling 200> }
  ```
  `"join"` (a fourth, documented body key on this route) is never sent by
  this requirement's list renderer — no join UI exists at this stage; the
  key is simply omitted, which `parse_joins(nil)` on the server already
  treats as `[]` (§0's read of `build_query_request/1`).
- **`filter-op` is the backend's own closed 12-value set** — `eq`, `neq`,
  `gt`, `gte`, `lt`, `lte`, `in`, `not_in`, `contains`, `starts_with`,
  `is_null`, `is_not_null` (`Letflow.Entities.Query.Types.parse_filter_op/1`,
  §0). **This is deliberately NOT the same 11-value set
  `EntityFilterBuilder.tsx`'s `ALL_OPS` uses** — the SPA's own list has
  `"ne"` where the backend expects `"neq"`, and omits `"starts_with"`
  entirely. Per this requirement's own instruction ("the contract, not the
  React code, is what is mirrored"), the mobile filter builder's operator
  set is the backend's 12 values, not the SPA's 11 — sending `"ne"` to
  this backend is a 400 (`{unknown_operator, "ne"}`), so copying the SPA's
  op set verbatim would ship a request the server rejects. Flagged as
  OQ-6/an anti-pattern candidate: `web/`'s own filter builder appears to
  have this mismatch too, but fixing `web/` is out of this requirement's
  scope (FRONTEND-DEV's file, not `apps/mobile/`).
- `value`'s wire type must match `field.type` the same way `entities.ex`'s
  `Compiler` expects (string for `string`/`enum`/`localized_text`, JSON
  number for `integer`/`decimal`, boolean literal for `boolean`, ISO
  date/datetime string for `date`/`datetime`, a JSON array for
  `in`/`not_in`) — mirrors `EntityFilterBuilder.tsx`'s own `coerceSingle`
  coercion table (§0), which is a client-side UX nicety this design
  requires for the SAME reason the SPA does: a raw string sent for an
  `integer` field mismatches the compiler's cast and 422s.
- 200 body: `{ "items": [ <record>, ... ], "next_cursor": "<string>|null" }`.
  Each `<record>` is `{ "record_id": "<uuid>", "entity_type": "<string>",
  "field_values": { "<field-name>": <any>, ... }, "deleted": <bool>,
  "entity_def_version": "<hex>", "last_event_global_seq": <int> }`.
- **AC3's "stopping when next_cursor is null"**: the list renderer's own
  pagination controller (§3.5) treats a `null` (or absent) `next_cursor` in
  a 200 response as "no more pages" — it stops issuing further-page
  requests on scroll-to-end, permanently, for that committed
  filter/sort set (a fresh Search commits a fresh first page, per §3.5).
- Error statuses actually reachable from this route, per `entities.ex`'s
  own `render_query_error/2` and the REQ-394 override in `run_query/4`
  (§0): a genuinely-nonexistent OR access-denied `entity_type` here
  **does not 404 or 403** — it renders `200 {"items": [], "next_cursor":
  null}` (`render_type_hidden/1`), deliberately indistinguishable from a
  real empty result set. This means: **the list renderer's own `/query`
  call cannot itself trigger `RendererPermissionDenied` for a real
  backend response** — only Call 1 can ever 404, and that maps to
  `RendererFetchFailure` per §1.2, not `RendererPermissionDenied` either.
  AC1's "permission-denied via 403" widget test therefore necessarily uses
  a fake `HttpGateway`/`ApiClient` that throws a bare `ForbiddenError`
  directly — proving the *shared wrapper* handles it, not that this
  specific screen's real endpoints produce it (consistent with AC4's
  framing: the guard is about every renderer being *wrapped*, not about
  every state being naturally reachable per screen). A 400
  (`query_field_invalid` — a malformed cursor/op/field caught server-side
  despite client-side validation) maps via `classifyError`'s catch-all to
  `ServerError` (REQ-425 §1.2 item 10's documented catch-all for an
  unmapped status) → `RendererFetchFailure`.

### 3.4 `EntityFieldDef` — the client-side field-definition shape

A plain immutable value class, `EntityFieldDef`, one field per key read
from Call 1's `fields[]` entries: `name: String`, `type: EntityFieldType`
(an enum over the nine closed strings, §3.3, with a `fromWire(String)`
factory that returns `null` — never throws — for an unrecognized string,
so the caller can distinguish "recognized type" from "drift" and produce
`UnknownFieldType` itself, §1.3), `queried: bool` (defaults `false` if
absent — only `queried == true` fields are offered in the filter UI,
mirroring `EntityFilterBuilder.tsx`'s own `fields.filter((f) => f.queried
=== true)`, §0).

### 3.5 List renderer state/controller shape

A Riverpod-managed controller (mirroring `PinnedFormResolver`'s own
plain-class-behind-a-`Provider` style, §0 — not a `StateNotifier`
subclass mandate, MOBILE-DEV's call which Riverpod primitive), exposing:

- `RendererState<ListPage> state` — where `ListPage` is `{ fields:
  List<EntityFieldDef>, records: List<Map<String, dynamic>>, nextCursor:
  String? }` — the `contentBuilder`'s `T` from §2.1. `records` accumulates
  across pages (infinite scroll, not the SPA's page-replace-on-click
  model, per this requirement's own AC3 wording "on scrolling to the end,
  requests the next page" — appends, never replaces, until a fresh Search
  commits new filters and the accumulated list is cleared back to empty
  first).
- `Future<void> loadFirstPage({required List<FilterClause> filters,
  required List<SortClause> sort})` — sets `state` to `RendererLoading`
  immediately, then: Call 1, then (on success) Call 2 with `cursor: null`,
  clearing any previously accumulated `records`. Any thrown `ApiError` at
  either call maps via §1.2/§3.3's own per-call rules into the
  corresponding `RendererState`; any `StaleVersionReason` detected while
  interpreting Call 1's field list (§3.3's unknown-type case) short-circuits
  before Call 2 is ever issued.
- `Future<void> loadNextPage()` — a no-op (never issues a request) if
  `state` is not currently `RendererContent` or if that content's
  `nextCursor` is `null` (AC3's stop condition, enforced here, not just at
  the UI/scroll-listener level, so a fast double-scroll-to-end cannot fire
  two overlapping next-page requests for the same cursor). Otherwise
  issues Call 2 with the **previous response's own `next_cursor` value**
  verbatim as this call's `cursor` (AC3's exact wording) and the same
  committed `filters`/`sort`, appending the new page's records to the
  existing accumulated list and replacing `nextCursor` with the new
  response's value.
- The `onRetryBackpressure` callback `RendererStateView` needs (§2.1) is
  this controller's own `retryLastOperation()` — re-issues whichever of
  `loadFirstPage`/`loadNextPage` most recently produced the
  `RendererBackpressure` state, with the exact same arguments (never a
  fresh Search's params — a 429 retry is a retry of the SAME request that
  was throttled, not a resubmission of possibly-changed UI state).

---

## 4. AC4's guard — "every renderer under `lib/renderers/{form,list,process,task}/`
is wrapped by the shared state wrapper"

Structural mechanism (not a runtime check, a build-shape convention every
renderer's top-level widget must follow, so a test can assert it
mechanically per renderer): each renderer kind's public entry-point widget
(for `list`, `buildListRenderer`'s returned widget) MUST return, as the
outermost widget of its own `build`, exactly one `RendererStateView<T>`
instance — never nested inside another widget first, never a raw
`FutureBuilder`/`Consumer` that bypasses `RendererStateView`. This is
verifiable per renderer by:

1. A type check: `expect(find.byType(RendererStateView<ListPage>),
   findsOneWidget)` immediately under the renderer's own root widget —
   exactly what AC4 itself suggests ("e.g. by type check in a widget test
   for each"). `list.dart`'s design above satisfies this by construction
   (§3.1's `buildListRenderer` has nothing else in its return tree above
   the controller-fed `RendererStateView`).
2. Because this requirement leaves `form/`, `process/`, `task/` as
   placeholders (§0), the guard, as of REQ-426, has exactly one renderer to
   check (`list`) — TEST-DESIGNER's job is to phrase the guard test so it
   iterates the actual non-placeholder entries in `RendererRegistry`
   (or an explicit list TEST-DESIGNER maintains) rather than hardcoding
   "there are 4 renderers," so REQ-427/428 adding `form`/`process`/`task`
   extends the same test's coverage without this design needing revision.

---

## 5. Function/class signatures — new files, full surface

### `lib/renderers/renderer_state.dart`

- `sealed class RendererState<T>`
- `final class RendererLoading<T> extends RendererState<T>` — no fields.
- `final class RendererContent<T> extends RendererState<T>` — `T data`.
- `final class RendererFetchFailure<T> extends RendererState<T>` —
  `Object? cause`.
- `final class RendererPermissionDenied<T> extends RendererState<T>` — no
  fields.
- `final class RendererStaleVersion<T> extends RendererState<T>` —
  `StaleVersionReason reason`.
- `final class RendererValidationError<T> extends RendererState<T>` —
  `List<ApiFieldError> fieldErrors`.
- `final class RendererBackpressure<T> extends RendererState<T>` — `int
  retryAfterSeconds`.
- `sealed class StaleVersionReason`
- `final class UnknownDefinitionType extends StaleVersionReason` —
  `String definitionType`.
- `final class UnknownFieldType extends StaleVersionReason` — `String
  fieldName`, `String rawType`.
- `final class UnevaluableExpression extends StaleVersionReason` — `String
  expression`, `String reason`.
- `final class PinnedFormUnavailable extends StaleVersionReason` —
  `PinnedFormUnavailableReason reason` (REQ-424's enum, reused, imported
  from `../definitions/pinned_form_resolver.dart`).
- `RendererState<T> rendererStateForError<T>(ApiError error)` — §1.2.
- `RendererState<T> staleVersionState<T>(StaleVersionReason reason)` —
  §1.3.
- `class BackpressureCountdown` — constructor `({required int
  initialSeconds, required Future<void> Function() onZero})`; `ValueListenable<int>
  get secondsRemaining`; `void start()`; `void dispose()`. §1.4.

### `lib/renderers/renderer_state_view.dart`

- `const Key rendererLoadingKey`, `rendererContentKey`,
  `rendererFetchFailureKey`, `rendererPermissionDeniedKey`,
  `rendererStaleVersionKey`, `rendererValidationErrorKey`,
  `rendererBackpressureKey`, `backpressureCountdownTextKey` — §2.2/§2.3.
- `class RendererStateView<T> extends StatefulWidget` — constructor per
  §2.1.

### `lib/renderers/list/list.dart`

- `enum EntityFieldType { string, integer, decimal, boolean, date,
  datetime, enum_, json, localizedText }` (Dart reserves `enum` as a
  keyword — the wire value `"enum"` maps to the Dart identifier `enum_`)
  with `static EntityFieldType? fromWire(String raw)`. §3.4.
- `@immutable class EntityFieldDef` — `String name`, `EntityFieldType?
  type` (nullable — `null` means "drift," §3.4), `String rawType` (the
  original wire string, always kept even when `type` is `null`, so
  `UnknownFieldType`'s `rawType` field has something to report), `bool
  queried`.
- `enum FilterOp { eq, neq, gt, gte, lt, lte, in_, notIn, contains,
  startsWith, isNull, isNotNull }` with a `String get wireValue` mapping
  back to the exact 12 backend strings (`in_`→`"in"`, `notIn`→`"not_in"`,
  etc.). §3.3.
- `@immutable class FilterClause` — `String field`, `FilterOp op`,
  `Object? value` (only serialized when `op` is not `isNull`/`isNotNull`,
  mirroring the server's own `Map.has_key?` arity check, §0's read of
  `parse_filter_clause/1`).
- `@immutable class SortClause` — `String field`, `SortDir dir` (`enum
  SortDir { asc, desc }`).
- `@immutable class ListPage` — `List<EntityFieldDef> fields`,
  `List<Map<String, dynamic>> records`, `String? nextCursor`. §3.5.
- `class ListRendererController` — per §3.5: `RendererState<ListPage>
  state` (exposed via whatever Riverpod primitive MOBILE-DEV picks —
  `StateNotifier<RendererState<ListPage>>` or a plain `Provider` +
  `StateProvider`, left open per §3.5's own note), `Future<void>
  loadFirstPage({required List<FilterClause> filters, required
  List<SortClause> sort})`, `Future<void> loadNextPage()`, `Future<void>
  retryLastOperation()`.
- `Widget buildListRenderer(BuildContext context, Map<String, dynamic>
  definition)` — the `DefinitionWidgetBuilder` registered for `"list"`.

---

## 6. Cross-module dependencies

- `lib/renderers/renderer_state.dart` imports `../api/api_error.dart`
  (`ApiError`, `ApiFieldError`) and
  `../definitions/pinned_form_resolver.dart` (`PinnedFormUnavailableReason`
  only — not the resolver class itself).
- `lib/renderers/renderer_state_view.dart` imports `renderer_state.dart`
  only (plus Flutter material/foundation) — it has no knowledge of `ApiError`
  or any specific renderer.
- `lib/renderers/list/list.dart` imports `../renderer_state.dart`,
  `../renderer_state_view.dart`, `../../api/api_client.dart` (`HttpGateway`),
  `../../api/api_error.dart` (`ApiError`, to catch and pass to
  `rendererStateForError`).
- `lib/renderers/renderer_registry.dart` (REQ-419, existing) is unchanged
  by this requirement except for the one `register("list", ...)` call site
  at app bootstrap (outside `lib/renderers/`, in whatever composition root
  wires providers today — `lib/bootstrap/navigation_bootstrap.dart` per
  the existing pattern for `apiClientProvider` etc., §0).

---

## 7. Invariants

- **INV-1**: `RendererStateView.build`'s `switch` over `RendererState<T>`
  is exhaustive — the analyzer enforces this structurally (sealed class,
  no default/wildcard branch permitted in the implementation). A new
  `RendererState` variant added later without updating this file is a
  compile error, not a silent gap.
- **INV-2**: `rendererStateForError`'s `switch` over `ApiError` is
  likewise exhaustive — a new `ApiError` variant added to `api_error.dart`
  without updating this mapping is a compile error.
- **INV-3**: no renderer under `lib/renderers/` ever calls
  `ApiClient`/`HttpGateway` methods and inspects the thrown `ApiError`
  itself for presentation — every catch site immediately converts to a
  `RendererState` via `rendererStateForError` (or `staleVersionState`) and
  nothing else. This is what AC4's guard is actually checking structurally
  (§4).
- **INV-4**: `BackpressureCountdown.onZero` is invoked **at most once**
  per instance — the timer is cancelled before `onZero` runs, and
  `start()` is not re-entrant (calling it twice on the same instance is a
  programmer error, not defended against — a fresh `RendererBackpressure`
  state always gets a fresh `BackpressureCountdownWidget`/controller
  instance via `Key`-based widget identity, since `retryAfterSeconds`
  changing is itself a new `RendererState` value flowing into
  `RendererStateView`).
- **INV-5**: `ListRendererController.loadNextPage` never issues a second
  in-flight request while one is already outstanding for the same
  controller instance (guards AC3's exactness — "exactly one retry
  request," extended here to "exactly one next-page request per
  scroll-to-end," even though AC3's own wording is about the backpressure
  case specifically). Mechanism left to MOBILE-DEV (e.g. an in-flight
  boolean flag checked at the top of `loadNextPage`), not prescribed
  further since it is ordinary reentrancy guarding, not a novel contract.

---

## 8. Acceptance-criteria resolution map

- **AC1** ("six widget tests, one per state ... assert the state's
  dedicated widget by key"): §2.2's table gives each of the six states
  (plus `RendererContent`) its own `Key` constant. Per-state forcing
  mechanism:
  - *loading*: construct `RendererStateView(state: RendererLoading())`
    directly (§1.1) — "an uncompleted future" in AC1's own wording is
    satisfied at the controller level (§3.5's `loadFirstPage` sets
    `RendererLoading` before awaiting), and at the widget-test level by
    constructing the `Loading` state value directly with no fetch
    involved at all — both are valid per this design; TEST-DESIGNER picks
    one.
  - *fetch-failure*: a fake `HttpGateway` whose `get` throws
    `NetworkUnavailableError` → `ListRendererController.loadFirstPage` →
    `rendererStateForError` → `RendererFetchFailure` (§1.2/§3.3).
  - *permission-denied*: a fake `HttpGateway` throwing `ForbiddenError`
    (§3.3's note that this is necessarily forced, not naturally reachable
    from this screen's real endpoints).
  - *stale-version*: a fake `HttpGateway`'s Call 1 response containing a
    field whose `"type"` is outside the nine known strings (§3.3/§3.4).
  - *validation-error*: a fake `HttpGateway` throwing
    `ValidationError(fieldErrors: [...])` (422) — reachable in principle
    from a future write path; for this read-only list renderer, forced the
    same way as permission-denied, which this design does not treat as a
    defect (AC4/INV-3 are about wrapper coverage, not per-screen
    reachability, §3.3).
  - *429-backpressure*: a fake `HttpGateway` throwing
    `BackpressureError(retryAfterSeconds: 3)` on Call 2 → §1.2 →
    `RendererBackpressure(retryAfterSeconds: 3)` → §2.3's
    `BackpressureCountdownWidget`.
- **AC2** ("advances a fake clock and asserts the countdown shows 3, 2, 1
  ... exactly one retry request ... does not throw"): §1.4's exact tick
  semantics + §2.3's `backpressureCountdownTextKey` + §1.4's "cancel
  before calling `onZero`, call at most once" (INV-4) + §1.4's requirement
  that `onZero`'s own exceptions are caught internally, never left
  uncaught.
- **AC3** ("filter in the POST body ... scrolling to the end ... next
  page with the previous response's next_cursor ... stopping when
  next_cursor is null"): §3.3's exact request-body shape for `filters`,
  §3.5's `loadNextPage` using the previous response's own `nextCursor`
  verbatim and refusing to call again once it is `null`.
- **AC4** ("guard or test asserts every renderer ... is wrapped by the
  shared state wrapper ... by type check"): §4, INV-3.
- **AC5** (`flutter analyze && flutter test` pass): not a design-time
  criterion — MOBILE-DEV/TEST-RUNNER's job at build/verify time; nothing
  in this design conflicts with either (no dynamic/implicit-any surfaces
  introduced; every new public API above is fully typed).

---

## 9. Open questions (explicit — not silently resolved)

- **OQ-1**: `ConflictError` and `NotFoundError` have no dedicated one of
  the six mandatory states and are folded into `RendererFetchFailure`
  (§1.2). If a future requirement wants a distinguishable "not found"
  screen (e.g. for a deleted record deep-link), that is a new, seventh
  UI-level case built *on top of* `RendererFetchFailure`'s `cause`
  (callers can still pattern-match `cause is NotFoundError` inside their
  own `contentBuilder`/failure-widget if they need finer-grained copy) —
  not a new `RendererState` variant, unless REVIEWER/CODE-DESIGN-VALIDATOR
  for that later requirement decides otherwise.
- **OQ-2**: `UnauthorizedError`'s mapping to `RendererFetchFailure` is
  believed unreachable in practice (§1.2's table) given `ApiClient`'s own
  login-routing on terminal 401. If a future audit finds a real path where
  a renderer's `catch` does observe `UnauthorizedError` (e.g. a race
  between `LoginRouter`'s navigation and the renderer's own widget
  lifecycle), this mapping is what fires — flagged here rather than
  asserted as literally dead code.
- **OQ-3**: This design's `StaleVersionReason.UnknownDefinitionType` is
  distinct from `renderer_registry.dart`'s existing top-level
  `UnsupportedDefinitionTypeWidget` fallback (REQ-419) — the registry's
  fallback fires when `RendererRegistry.build` itself is asked for an
  unregistered top-level type (e.g. a definition of type `"chart"` with no
  registered builder at all), while this design's variant is for a nested
  definition-type reference a renderer discovers *while interpreting its
  own definition's content* (not exercised by the list renderer in this
  requirement — reserved for a later renderer that embeds sub-definitions).
  Whether these two mechanisms should be unified (the registry fallback
  itself producing a `RendererStaleVersion` rather than its own bespoke
  widget) is left for REQ-427/428 or a REVIEWER note, not decided here,
  since changing REQ-419's already-shipped fallback is out of this
  requirement's stated scope.
- **OQ-4**: No manual "retry now" affordance is designed for the
  backpressure countdown (§2.3) — only the automatic at-zero retry AC2
  requires. Left for a future requirement if product wants it.
- **OQ-5**: The `"list"` definition's wire shape is specified here as
  exactly `{"entity_type": "<string>"}` (§3.2) because AC3 needs nothing
  more; a curated column/default-filter set is explicitly deferred, not
  designed, per §3.2's own note.
- **OQ-6**: `web/src/components/entities/EntityFilterBuilder.tsx`'s
  operator set appears to diverge from the backend's actual accepted
  operators (`"ne"` vs. the backend's `"neq"`; no `"starts_with"` offered
  at all) — noted for awareness (possibly worth a `docs/anti-patterns.md`
  entry or a FRONTEND-DEV follow-up issue) but out of this requirement's
  scope to fix, since `web/` is not touched by REQ-426.
