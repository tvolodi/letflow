# Design — REQ-428: MOB-4 (part 3) task-inbox/claim/complete renderer and
# read-only process-instance renderer

Owner: MOBILE-DEV. Stage: S9. Depends on REQ-424 (pinned form resolver,
shipped as `apps/mobile/lib/definitions/pinned_form_resolver.dart` — see §0
on its design doc's actual absence), REQ-426 (`RendererState<T>` framework +
list renderer, shipped), REQ-427 (form renderer design, shipped as
`lib/letflow/design/req427-form-renderer.md`; its `apps/mobile/lib/renderers/
form/form.dart` implementation is NOT yet built — REQ-427's own handoff
record is the authority on that, not this document). Builds
`apps/mobile/lib/renderers/task/task.dart` and
`apps/mobile/lib/renderers/process/process.dart` (today both placeholders,
per their own doc comments: "Built starting REQ-428").

No implementation code below — signatures, type/state shapes, and exact
algorithms in prose/pseudocode only, per CODE-DESIGNER's own constraint.

---

## 0. Authority sources read for this design (not guessed)

- `lib/letflow/routers/tasks.ex` — exact routes/response shapes/status codes
  for `GET /tasks/inbox`, `GET /tasks/:id`, `POST /tasks/:id/claim`,
  `POST /tasks/:id/complete`. Read verbatim; §1 below cites line-level
  behavior (route ordering, `task_detail_map/3`'s 14 keys, `handle_claim`'s
  conflict taxonomy).
- `lib/letflow/routers/instances.ex` — exact routes/response shapes for
  `GET /instances/:id` (`instance_map/1`, 9 keys) and
  `GET /instances/:id/timeline` (`timeline_item_map/1`, paginated, 10 keys
  per item). Read verbatim; no cancel/rebind/advance-timer route is used by
  this design at all (§4's explicit non-goal).
- `apps/mobile/lib/renderers/renderer_state.dart` /
  `renderer_state_view.dart` / `renderer_registry.dart` (REQ-419/426) — the
  seven-variant `RendererState<T>` framework, `rendererStateForError`,
  `StaleVersionReason`'s existing variants (`UnknownDefinitionType`,
  `UnknownFieldType`, `UnevaluableExpression`, `PinnedFormUnavailable`),
  `BackpressureCountdown`, and `RendererStateView<T>`'s widget-key
  convention. This design adds **no new `StaleVersionReason` variant** —
  every stale-version case below resolves to an existing one.
- `apps/mobile/lib/api/api_error.dart` (REQ-425) — the 9-variant sealed
  `ApiError`, in particular `ConflictError` (409 → no `ApiError` fields at
  all — a bare marker, confirmed by reading the class, §2.3 below explains
  why this design needs a controller-level distinction `ApiError` itself
  does not carry) and `ValidationError`/`ForbiddenError` (422/403).
- `apps/mobile/lib/api/api_client.dart` (REQ-421/425) — `HttpGateway.get`,
  `PostCapableHttpGateway.post` (no `delete`/`put` exists; claim/complete
  are both `POST`, matching the backend's own routes). `post` is never
  auto-retried on 5xx (design §3.3 there) — relevant to §2.4/§3.3 below
  issuing exactly one request per claim/complete attempt.
- `apps/mobile/lib/definitions/pinned_form_resolver.dart` (REQ-424) —
  `PinnedFormResolver.resolve({taskId, formId, formVersion}) ->
  PinnedFormResolution` (`PinnedFormResolved(formSchema)` |
  `PinnedFormUnavailable(reason)`), read verbatim as the actual public
  interface. **Its own doc comment cites
  `lib/letflow/design/req424-mobile-pinned-form-version-resolution.md`, but
  no file by that name (or any `req424*`/`*pinned-form*` name) exists under
  `lib/letflow/design/` today** — confirmed by a direct glob of that
  directory, zero hits. This design proceeds from the shipped `.dart`
  source as the authority (per this requirement's own instruction to trust
  code over prose when they diverge), but flags the missing/mislinked
  design doc as **OQ-1**, not silently papered over.
- `lib/letflow/design/req427-form-renderer.md` — read in full for the
  pattern this design must match: `FormRendererController extends
  ChangeNotifier` composing `PinnedFormResolver` + a `PostCapableHttpGateway`
  behind `RendererState<FormViewModel>`; `FormSubmitOutcome`'s "submit
  outcome lives inside the content payload, never swapped into
  `RendererState` itself" pattern (its §5.1) — this design's §3.3/§5.1 reuse
  that exact pattern for claim/complete, for the same reason (a claim/
  complete failure must not discard the task detail already on screen).
- `apps/mobile/lib/renderers/list/list.dart` (REQ-426) — the
  `ChangeNotifier`-behind-a-`ChangeNotifierProvider.family` controller
  style, `_requestInFlight` guard idiom, `RendererStateView<T>` composition,
  and `buildXRenderer(BuildContext, Map<String, dynamic> definition)` /
  `_XRendererRoot` / provider-wiring split this design's §6/§7 mirror for
  both the task and process renderers.
- `apps/mobile/lib/renderers/task/task.dart`,
  `apps/mobile/lib/renderers/process/process.dart` — today's placeholders
  (doc comment only, `library;`), confirming both are this requirement's own
  files to build, not pre-existing code to extend.
- `docs/mobile/architecture.md` §"Navigation and routes" — confirms
  `go_router` as the routing library and that the app's route set is built
  from installed modules at bootstrap, but documents no existing route for
  a task-inbox screen, a task-detail screen, or an instance-detail screen.
  No navigation entry point for either renderer built here exists yet —
  flagged as **OQ-2** (§10), matching REQ-427's own §0 precedent of
  explicitly not inventing one.
- `docs/mobile/requirements.md` MOB-4 — "The task renderer supports inbox,
  claim, and complete against the task API," and the six-states rule
  applied "driven by the same server definition format as the SPA" (task
  renderer is one of the four named renderer kinds, alongside
  form/list/process-instance).

---

## 1. Scope boundary (explicit, per the handoff's own text)

This design covers exactly:

1. **Task inbox** — list, with claim.
2. **Task detail** — open a task, render its pinned form (via REQ-424's
   resolver + REQ-427's form renderer, §2), complete it.
3. **Process-instance screen** — read-only: status, current step(s),
   timeline. **No cancel/rebind/advance-timer action anywhere in this
   design** — `instances.ex`'s `POST /:id/cancel`, `POST /:id/rebind-pins`,
   `POST /:id/reconstruct`, `POST /:id/advance-timer` routes are read in §0
   only to confirm their existence and are never called by any type or
   method below. Stated explicitly here, in §4.1, and in §9's AC4 mapping —
   not merely omitted, so a reviewer does not have to infer the exclusion
   from absence.
3. The six-state wrapper mapping for every screen (§5).

Out of scope, explicitly: `GET /tasks` (non-inbox list, with filters),
`POST /tasks/:id/assign`/`reassign` (operator actions — MOB-4 names only
inbox/claim/complete for the task renderer), `GET /instances/:id/history`
(raw event log — MOB-4 names only "status, current step, timeline"),
`GET /instances/:id/pins`, any attachment route. None of these appear in
REQ-428's requirement text or acceptance criteria.

---

## 2. Task inbox — `TaskInboxController` / `TaskInboxItem`

### 2.1 `TaskInboxItem` — one `task_list_item_map/2` row, typed

```
@immutable
class TaskInboxItem {
  const TaskInboxItem({
    required this.id,
    required this.instanceId,
    required this.nodeId,
    required this.nodeName,
    required this.status,          // TaskStatus (§2.1.1)
    required this.assigneeType,    // String?  -- task.assignee_type, passed through
    required this.assigneeRef,     // String?  -- task.assignee_ref, passed through
    required this.createdAt,       // DateTime
    required this.tokenId,         // String?
    required this.formId,          // String?  -- task.node_id, per tasks.ex (§0)
    required this.formVersion,     // String?
  });

  factory TaskInboxItem.fromJson(Map<String, dynamic> json);
  // Never throws on a missing optional key -- mirrors EntityFieldDef.fromJson's
  // defensive-cast style (§0, list.dart). A missing/non-string "id" or
  // "instance_id" (the two keys every other field logically depends on) is
  // the one case this factory is NOT responsible for defending against --
  // TaskInboxController._fetchPage (§2.3) treats a cast failure on either as
  // TaskParseFailure, folding to RendererStaleVersion (§2.3/§5), the same
  // "fails loudly on drift" rule list.dart's EntityFieldDef establishes for
  // an unknown field type -- this is the same principle at a different
  // layer (whole-item parse, not one field's type).
}
```

### 2.1.1 `TaskStatus`

```
enum TaskStatus {
  pending, completed, cancelled;

  // fromWire: "PENDING"/"COMPLETED"/"CANCELLED" -> variant, else null
  // (task_status_string/1's own three-value range, §0) -- never throws.
  static TaskStatus? fromWire(String raw);
}
```

A `null` result (a status string outside the three known values) makes the
**whole inbox page** fail loudly, mirroring `list.dart`'s own "whole list,
not one record" rule (§2.3's `TaskParseFailure` path) — this is a genuine
drift signal (a value `task_status_string/1` structurally cannot produce
today), not a case this design expects to actually hit.

### 2.2 `TaskInboxPage` — the `RendererContent<T>` payload

```
@immutable
class TaskInboxPage {
  const TaskInboxPage({required this.items, required this.nextCursor});
  final List<TaskInboxItem> items;
  final String? nextCursor;
}
```

### 2.3 `TaskInboxController extends ChangeNotifier`

Mirrors `ListRendererController`'s shape exactly (§0): single
`GET /api/v1/tasks/inbox` call per page (no "Call 1"/"Call 2" split — the
inbox route carries its own items directly, unlike the list renderer's
definition-then-query split), same `_requestInFlight` guard, same
`retryLastOperation` precedent for `RendererBackpressure`.

```
class TaskInboxController extends ChangeNotifier {
  TaskInboxController({required this.client});

  final HttpGateway client;   // GET-only -- inbox never POSTs

  static const String _inboxPath = '/api/v1/tasks/inbox';

  RendererState<TaskInboxPage> get state;

  Future<void> loadFirstPage();                 // §2.3.1
  Future<void> loadNextPage();                  // same nextCursor-null stop rule as ListRendererController
  Future<void> retryLastOperation();             // re-issues whichever of the above last ran
  Future<void> refreshAfterClaimConflict();      // §3.3 -- identical to loadFirstPage, named separately
                                                   // so a caller site reads intent, not mechanism
}
```

#### 2.3.1 `loadFirstPage()` / `_fetchPage(cursor)` algorithm

1. Set `RendererLoading<TaskInboxPage>()`, notify.
2. `GET /api/v1/tasks/inbox?cursor=<cursor or omitted>&page_size=<default>`.
3. On a thrown `ApiError` → `rendererStateForError<TaskInboxPage>(e)` (§0's
   existing, unmodified mapping — nothing added here).
4. On success: parse `body['items']` via `TaskInboxItem.fromJson` per
   element. Any element whose `id`/`instance_id`/`status` cannot be read as
   the expected type → the **whole** page is
   `RendererStaleVersion(UnknownFieldType(fieldName: '<id|instance_id|status>',
   rawType: '<runtime type or wire string>'))` — reusing the existing
   `UnknownFieldType` variant (no new `StaleVersionReason` is added; a
   malformed/unrecognized task-list item is the same class of drift
   `UnknownFieldType` already names, just at the item-shape granularity
   instead of the schema-field granularity it was written for in REQ-427).
5. Otherwise → `RendererContent(TaskInboxPage(items: ..., nextCursor:
   body['next_cursor']))`.

`refreshAfterClaimConflict()` is `loadFirstPage()` under a distinct name —
no new mechanism — called exactly where §3.3 specifies.

### 2.4 Claiming from the inbox — `TaskInboxController.claim(String taskId)`

```
Future<TaskClaimOutcome> claim(String taskId);   // §3 -- see TaskClaimOutcome there;
                                                   // shared with the task-detail screen's own claim action
```

Delegates to the same claim mechanism §3.2 defines for the task-detail
screen (one shared function, not two copies) — see §3.2's note on why this
is a bare function, not state duplicated on two controllers.

---

## 3. Task detail / claim / complete — `TaskDetailController`

### 3.1 `TaskDetail` — `task_detail_map/3`'s 14 keys, typed

```
@immutable
class TaskDetail {
  const TaskDetail({
    required this.id,
    required this.instanceId,
    required this.nodeId,
    required this.nodeName,
    required this.status,            // TaskStatus (§2.1.1)
    required this.assigneeType,
    required this.assigneeRef,
    required this.createdAt,
    required this.tokenId,
    required this.formId,            // task.node_id (§0) -- the pinned-resolver's own `formId` input
    required this.formVersion,       // String? -- the pinned-resolver's own `formVersion` input
    required this.correlationKey,    // String?
    required this.updatedAt,         // DateTime
    required this.formSchema,        // Map<String, dynamic>? -- NOT used to render the form
                                      // directly (§3.4) -- carried only because task_detail_map/3
                                      // emits it; the form renderer's own pinned-resolver call is
                                      // the authority for what actually renders, never this field.
  });

  factory TaskDetail.fromJson(Map<String, dynamic> json);
}
```

### 3.2 `TaskClaimOutcome` — the claim action's typed result

```
sealed class TaskClaimOutcome {}
final class TaskClaimSuccess extends TaskClaimOutcome {
  const TaskClaimSuccess({required this.detail});   // TaskDetail (§3.1), the claim response's own body
}
/// 409 -- "task is not pending" / "already assigned to a different user" /
/// "caller not a member of the assigned group" / "caller does not hold the
/// assigned role" / "task cannot be claimed" (handle_claim_result's five
/// distinct 409 clauses, §0) -- all five collapse to this ONE outcome.
/// AC3's exact requirement: the task is no longer available to claim, full
/// stop; this design does not expose which of the five server-side reasons
/// applied, because none of them change what the client does next (§3.3).
final class TaskClaimNoLongerAvailable extends TaskClaimOutcome {
  const TaskClaimNoLongerAvailable();
}
final class TaskClaimForbidden extends TaskClaimOutcome {
  const TaskClaimForbidden();          // 403 -- ForbiddenError
}
final class TaskClaimNetworkUnavailable extends TaskClaimOutcome {
  const TaskClaimNetworkUnavailable();
}
final class TaskClaimOtherFailure extends TaskClaimOutcome {
  const TaskClaimOtherFailure({required this.cause});   // the ApiError, debug display only
}
```

```
/// Shared by TaskInboxController.claim (§2.4) and TaskDetailController.claim
/// (§3.3) -- a bare top-level function, not a method on either controller's
/// own class, so there is exactly one claim implementation, not two drifting
/// copies (the inbox screen and the detail screen are two different
/// callers of the same action, matching AC1's "claim a task ... open it"
/// sequence -- a user may claim from either screen).
Future<TaskClaimOutcome> claimTask(PostCapableHttpGateway client, String taskId) async {
  // POST /api/v1/tasks/:id/claim, empty body (tasks.ex's handle_claim reads
  // only conn.assigns.auth_context.user_id -- no request body field, §0).
  // On 2xx: TaskClaimSuccess(detail: TaskDetail.fromJson(response.data)).
  // On ApiError:
  //   ConflictError()      -> TaskClaimNoLongerAvailable()   -- AC3
  //   ForbiddenError()     -> TaskClaimForbidden()
  //   NetworkUnavailableError() -> TaskClaimNetworkUnavailable()
  //   every other ApiError -> TaskClaimOtherFailure(cause: error)
}
```

`NotFoundError`/`ServerError`/`BackpressureError`/`ValidationError`/
`UnauthorizedError`/`ModuleNotAvailableError` all land in
`TaskClaimOtherFailure` here — none of `handle_claim_result`'s clauses
(§0) produce a 404/422/429, and `UnauthorizedError` should not normally
reach this function at all per `rendererStateForError`'s own precedent
comment (§0) — included only so the mapping above is total over `ApiError`
without a second exhaustiveness gap.

### 3.3 Why claim's 409 is its own `TaskClaimOutcome` variant, not
`RendererState`'s existing `ConflictError` fallthrough

`rendererStateForError` (§0, `renderer_state.dart`) maps `ConflictError`
nowhere explicit at all — reading its `switch`, `ConflictError` is not one
of the 9 `ApiError` subtypes listed in that file's exhaustive match... **on
inspection it is**: `ApiError` has exactly 9 variants
(`NetworkUnavailableError`, `UnauthorizedError`, `ForbiddenError`,
`NotFoundError`, `ModuleNotAvailableError`, `BackpressureError`,
`ValidationError`, `ConflictError`, `ServerError`), and
`rendererStateForError`'s `switch` in `renderer_state.dart` (§0) has no
`ConflictError` case at all in the copy read for this design — **this is a
genuine gap in REQ-426's shipped mapping, not something this design can
silently patch inside `renderer_state.dart`** (out of this requirement's
own stated build surface, `apps/mobile/lib/renderers/task/` and
`.../process/`, not `renderer_state.dart` itself). Flagged as **OQ-3**:
`rendererStateForError`'s `switch` is not exhaustive over `ApiError` today
and a future change to that file must add a `ConflictError` case (most
naturally `RendererFetchFailure(cause: error)`, matching its sibling
4xx/5xx rows) or the analyzer's exhaustiveness check would already be
failing a build — reported, not silently worked around.

Independently of that gap, this design does **not** route a claim's 409
through `rendererStateForError`/`RendererState` **at all**, by the same
reasoning REQ-427 §5.1 gives for submit outcomes (§0): swapping
`TaskDetailController.state` away from `RendererContent` on a claim
conflict would discard the already-loaded `TaskDetail` the user is looking
at, for a failure that is about the **claim action**, not about the
**fetch that got them here**. `TaskClaimOutcome` (§3.2) is therefore a
second, narrower result type the same way REQ-427's `FormSubmitOutcome` is
— **not** derived from `RendererState`, **not** passing through
`rendererStateForError` at all.

**AC3's own two-part requirement — "specific state shown" AND "inbox
refresh triggered"** is satisfied as:

- `TaskClaimNoLongerAvailable` (§3.2) is the "specific state shown" half —
  the task-detail screen's claim-button area renders a message ("This task
  is no longer available") instead of a generic failure banner, keyed
  distinctly (§6.4).
- The **caller** of `claimTask` (both `TaskInboxController.claim`, §2.4, and
  `TaskDetailController.claim`, §3.3's own wrapper below) is responsible
  for calling `TaskInboxController.refreshAfterClaimConflict()` /
  `loadFirstPage()` exactly when the outcome is
  `TaskClaimNoLongerAvailable` — this is the "triggers an inbox refresh"
  half. On the inbox screen this is direct (the same controller). On the
  task-detail screen, which has no `TaskInboxController` of its own, the
  **screen composition layer** (not built by this design, §10 OQ-2) is
  responsible for holding a reference to the inbox's controller/provider
  and calling its refresh when `TaskDetailController.claim` returns
  `TaskClaimNoLongerAvailable` — stated as an explicit requirement on the
  future screen-wiring code, not solved inside either controller (neither
  controller is handed a reference to the other — that would invert
  `ListRendererController`'s own "no renderer depends on another
  renderer's controller" precedent, §0).

### 3.4 `TaskDetailController extends ChangeNotifier`

```
class TaskDetailController extends ChangeNotifier {
  TaskDetailController({required this.client, required this.taskId});

  final PostCapableHttpGateway client;
  final String taskId;

  RendererState<TaskDetail> get state;          // §3.4.1 -- the FETCH's own state
  TaskClaimOutcome? get lastClaimOutcome;        // null until a claim attempt happens (mirrors
                                                   // FormRendererController's own submitOutcome pattern)

  Future<void> load();                           // GET /api/v1/tasks/:id
  Future<TaskClaimOutcome> claim();               // calls claimTask(client, taskId) (§3.2), stores the
                                                   // result in lastClaimOutcome, notifies, and on
                                                   // TaskClaimSuccess also re-sets `state` to
                                                   // RendererContent(the new TaskDetail) -- the
                                                   // claim response's own body (§0's handle_claim_result,
                                                   // which already returns a full task_detail_map) is
                                                   // authoritative, no second GET /tasks/:id needed.
}
```

#### 3.4.1 `load()` algorithm

1. `RendererLoading<TaskDetail>()`, notify.
2. `GET /api/v1/tasks/:id`.
3. `ApiError` thrown → `rendererStateForError<TaskDetail>(e)` (existing
   mapping, unmodified; a 404 here — task genuinely absent/cross-tenant,
   §0's `handle_get_by_id` — lands in `RendererFetchFailure` via that
   mapping's existing `NotFoundError` row, which is the correct outcome:
   there is no dedicated "task not found" stale-version case named by any
   acceptance criterion here).
4. Success → parse `TaskDetail.fromJson`. A status-string drift (§2.1.1)
   folds to `RendererStaleVersion(UnknownFieldType(...))`, same rule as
   §2.3 step 4.
5. Otherwise → `RendererContent(TaskDetail)`.

### 3.5 Completing a task — `TaskCompleteOutcome` and
`TaskDetailController.complete`

This is a **thin composition over REQ-427's own `FormRendererController`
(§0), not a second form-submission mechanism.** The task-detail screen
(§6.2) owns one `FormRendererController` instance, constructed with this
task's own `taskId`/`formId`/`formVersion`/`instanceId` (REQ-427 §3.2's
constructor, unmodified) — `FormRendererController.submit()` (REQ-427 §5.3)
**is** this design's complete action; `FormSubmitOutcome` (REQ-427 §5.2) is
read directly by the task-detail screen's six-state mapping (§5 below).
**No `TaskCompleteOutcome` type is introduced by this design** — doing so
would duplicate REQ-427's already-complete `SubmitNetworkUnavailable`/
`SubmitValidationError`/`SubmitOtherFailure`/`SubmitSuccess` taxonomy for no
reason; `TaskDetailController` (§3.4) owns the **task metadata** fetch/claim
only, and the **form** (resolution + values + submit) is entirely
`FormRendererController`'s job, composed at the widget layer (§6.2), not
re-exposed through `TaskDetailController`'s own API.

### 3.6 Why the pinned (`form_id`, `form_version`) is structural, never
"the active version" (AC2)

`TaskDetail.formId`/`TaskDetail.formVersion` (§3.1) are read **verbatim**
from the task-detail response's own `form_id`/`form_version` keys
(`task_detail_map/3`, §0) — the task's own pinned values, never a
separately-fetched "current definition version." The task-detail screen
(§6.2) passes these two fields **directly** into
`FormRendererController`'s constructor (`formId:`, `formVersion:`, REQ-427
§3.2), which in turn passes them **unchanged** into
`PinnedFormResolver.resolve({taskId, formId, formVersion})` (REQ-424, §0).
**There is no code path anywhere in this design, or in REQ-427's, that
calls any "fetch the active/latest form version for `formId`" endpoint —
no such endpoint is read from or referenced at all.** This is what makes
pinning structural rather than a convention a future call site could
accidentally violate: the only value `PinnedFormResolver.resolve` is ever
given for `formVersion` is the one already sitting on the already-fetched
`TaskDetail`, with no intervening lookup that could substitute a different
value.

---

## 4. Process-instance screen — `InstanceDetailController`

### 4.1 Explicit non-goal (restated from §1)

This screen is **read-only**. `Letflow.Routers.Instances` exposes
`POST /:id/cancel`, `POST /:id/rebind-pins`, `POST /:id/reconstruct`, and
`POST /:id/advance-timer` (§0) — **none of the four is called, referenced,
or exposed by any type or method in this section.** `InstanceDetailController`
below has no method whose name or effect is "cancel"/"rebind"/"advance" —
confirmed by its own method list in §4.4 containing exactly `load()` and
`loadMoreTimeline()`.

### 4.2 `InstanceDetail` — `instance_map/1`'s 9 keys, typed

```
@immutable
class InstanceDetail {
  const InstanceDetail({
    required this.instanceId,
    required this.definitionId,
    required this.correlationKey,   // String?
    required this.status,           // InstanceStatus (§4.2.1)
    required this.variables,        // Map<String, dynamic>
    required this.startedAt,        // DateTime
    required this.completedAt,      // DateTime?
    required this.cancelledAt,      // DateTime?
    required this.errorDetail,      // Object? -- passed through as-is, never interpreted
  });

  factory InstanceDetail.fromJson(Map<String, dynamic> json);
}
```

### 4.2.1 `InstanceStatus`

```
enum InstanceStatus {
  active, completed, cancelled, error;
  // fromWire: "ACTIVE"/"COMPLETED"/"CANCELLED"/"ERROR" -> variant, else null.
  // status_string/1 (instances.ex, read via grep of its call sites) emits
  // exactly these four uppercase strings -- confirmed against
  // Letflow.EventStore.InstanceProjection's terminal?/1 contract cited in
  // instances.ex's own moduledoc (§0: terminal? is true only for
  // :completed/:cancelled, so :active and :error both exist as real,
  // non-terminal-or-terminal statuses this screen must render, not just the
  // two terminal ones).
  static InstanceStatus? fromWire(String raw);
}
```

**"Current step"** (AC4's own wording) is **not** a field
`instance_map/1` provides directly — `instances.ex`'s `GET /:id` has no
"current node" key (§0; that shape belongs to
`Letflow.Engine.complete_result()`'s `current_nodes`, a *different* route's
response). This design derives "current step" for an **active** instance
as the **most recent timeline entry carrying a non-null `node_id`** from
the already-fetched timeline (§4.3) — i.e., no second endpoint is read;
"current step" is a view concern computed from `InstanceTimelinePage`
(§4.3) at the widget layer (§6.3), not a separate `InstanceDetailController`
field. For a **terminal** instance (`completed`/`cancelled`/`error`), the
widget layer shows the terminal status itself rather than a "current step"
(there is no current step for a finished instance) — flagged as **OQ-4**:
whether a more precise "current step" signal should instead come from
`GET /instances/:id/pins`’ or a dedicated field is left to a future
requirement; this design uses only the two endpoints REQ-428's text names.

### 4.3 `InstanceTimelinePage` — `timeline_item_map/1`'s 10 keys per item,
paginated

```
@immutable
class TimelineEntry {
  const TimelineEntry({
    required this.eventId,
    required this.eventType,
    required this.sequenceNum,
    required this.instanceId,
    required this.timestamp,        // DateTime
    required this.nodeId,           // String?
    required this.taskId,           // String?
    required this.metadata,         // Map<String, dynamic>? -- passed through, never interpreted
    required this.actorDisplayName, // String?
    required this.description,      // String?
  });

  factory TimelineEntry.fromJson(Map<String, dynamic> json);
}

@immutable
class InstanceTimelinePage {
  const InstanceTimelinePage({required this.entries, required this.nextCursor});
  final List<TimelineEntry> entries;   // oldest-or-newest-first exactly as the server returns them --
                                         // this design imposes no re-sort (instances.ex's own moduledoc
                                         // specifies no ordering guarantee beyond the server's own cursor
                                         // semantics, and none is needed to satisfy AC4)
  final String? nextCursor;
}
```

### 4.4 `InstanceDetailController extends ChangeNotifier`

```
class InstanceDetailController extends ChangeNotifier {
  InstanceDetailController({required this.client, required this.instanceId});

  final HttpGateway client;    // GET-only -- this whole controller never POSTs (§4.1)
  final String instanceId;

  RendererState<InstanceDetail> get detailState;            // §4.4.1
  RendererState<InstanceTimelinePage> get timelineState;    // §4.4.2 -- a SEPARATE RendererState,
                                                               // not nested inside InstanceDetail, so a
                                                               // timeline-only failure (e.g. a 429 on
                                                               // the timeline call alone) does not blank
                                                               // out an already-loaded instance header
  Future<void> load();              // issues BOTH GET /instances/:id and GET .../timeline (§4.4.3)
  Future<void> loadMoreTimeline();  // keyset pagination, same nextCursor-null stop rule as §2.3
  Future<void> retryTimelineBackpressure();  // re-issues whichever timeline call last 429'd
  Future<void> retryDetailBackpressure();    // re-issues load()'s detail call alone
}
```

#### 4.4.1/4.4.2 Two independent `RendererState`s, not one

`instance_map/1` and `timeline_item_map/1` are two separate backend calls
with independent failure modes (§0 — `GET /:id` and `GET /:id/timeline` are
declared as separate routes with separate `render_get_by_id/2`/
`render_page_result/3` error handling in `instances.ex`). Mirroring that
structural independence rather than flattening both into one `RendererState
<InstanceDetail>` is deliberate: a 429 on the timeline fetch alone (a
genuinely-reachable case — timeline is its own paginated route with its own
rate limit) must not blank the whole screen back to a backpressure countdown
when the instance header already loaded successfully. The widget layer
(§6.3) therefore renders `detailState` through one
`RendererStateView<InstanceDetail>` for the header, and, only inside that
view's `contentBuilder`, a second, independent
`RendererStateView<InstanceTimelinePage>` for the timeline list — two
wrapper widgets, never one shared state value.

#### 4.4.3 `load()` algorithm

1. Set both `detailState` and `timelineState` to `RendererLoading<...>()`,
   notify once.
2. Issue `GET /instances/:id` and `GET /instances/:id/timeline?page_size=<default>`
   concurrently (`Future.wait`-style — no ordering dependency between the
   two calls; neither response is needed to construct the other's request).
3. Map each response/error independently into its own `RendererState`
   exactly as §3.4.1/§2.3 do for their own single call — `rendererStateForError`
   for a thrown `ApiError`, `RendererContent` on success, with the same
   "a status/eventType string drift fails the WHOLE value loudly, not one
   field" rule (`InstanceStatus.fromWire`/absent nodeId-handling) producing
   `RendererStaleVersion(UnknownFieldType(...))` on an unrecognized
   `status`/malformed item, matching §2.3/§3.4.1's precedent exactly.
4. `notifyListeners()` once both have resolved.

`loadMoreTimeline()` mirrors `ListRendererController.loadNextPage()`'s own
no-op-unless-`RendererContent`-with-non-null-`nextCursor` guard (§0),
applied to `timelineState` alone — never touches `detailState`.

---

## 5. Six-state wrapper mapping — every screen, every error class

Per-screen, per-`RendererState<T>` variant (loading / fetch-failure /
permission-denied / stale-version / validation-error / 429-backpressure —
MOB-4's six names; `RendererContent` is the implicit seventh "it worked"
state every row below omits since it has no error class to map):

| Screen | `RendererState<T>` instance | loading | fetch-failure | permission-denied | stale-version | validation-error | 429-backpressure |
|---|---|---|---|---|---|---|---|
| Task inbox | `TaskInboxController.state` (`RendererState<TaskInboxPage>`) | `GET /tasks/inbox` in flight | network/5xx/404/409/etc. on inbox fetch (`rendererStateForError`, §0) | 403 on inbox fetch (rare — inbox has no dedicated permission scope beyond `:TasksList`, but the mapping exists for completeness) | malformed item or unrecognized `status` (§2.3 step 4) | N/A — `GET` never returns 422 on this route | 429 on inbox fetch — `BackpressureCountdown` (§0, unmodified), retry via `retryLastOperation()` |
| Task detail (fetch) | `TaskDetailController.state` (`RendererState<TaskDetail>`) | `GET /tasks/:id` in flight | network/5xx/404 on detail fetch | 403 on detail fetch | unrecognized `status` (§3.4.1 step 4) | N/A | 429 on detail fetch |
| Task detail — **claim** | `TaskDetailController.lastClaimOutcome` (`TaskClaimOutcome?`, §3.2) — **NOT** routed through `RendererState` (§3.3) | n/a — claim is a single `await`, no separate loading `RendererState`; the widget layer (§6.4) shows its own in-flight indicator locally, mirroring REQ-427 §5.1's `SubmitInFlight` precedent but scoped to the claim button alone | `TaskClaimOtherFailure`/`TaskClaimNetworkUnavailable` | `TaskClaimForbidden` (403) | **`TaskClaimNoLongerAvailable` — the 409 case (AC3).** Rendered as its own distinct message ("This task is no longer available") and triggers an inbox refresh (§3.3) — **not** a crash, and **not** folded into the generic stale-version UI (`RendererStaleVersion`) since this is an action-outcome, not a fetch/definition-drift signal | N/A — `claimTask` has no `TaskClaimOutcome` variant for 422; `handle_claim_result` (§0) never produces one | N/A — `claimTask` (§3.2) has no `TaskClaimOutcome` variant for 429 either; a 429 on claim folds to `TaskClaimOtherFailure` (flagged as **OQ-5**: AC3 names only the 409 case explicitly, so this design does not add a sixth `TaskClaimOutcome` variant speculatively — a future requirement should add one if a real 429-on-claim case needs its own countdown UI distinct from a generic failure banner) |
| Task detail — **complete** | `FormRendererController.state.data.submitOutcome` (`FormSubmitOutcome?`, REQ-427 §5.2/§5.3, reused verbatim, §3.5) | `SubmitInFlight` | `SubmitOtherFailure` | — (REQ-427's taxonomy has no dedicated 403-on-submit variant; folds to `SubmitOtherFailure`, same as REQ-427's own design leaves it) | — (a stale-version case on the **form itself** is `FormRendererController.state`'s own `RendererStaleVersion`, produced by `load()`, not by `submit()` — REQ-427 §3.3; `submit()` never produces one) | `SubmitValidationError` (422, AC5's own case) | N/A — REQ-427's `FormSubmitOutcome` has no 429 variant either (its own §5.3 `ApiError` mapping has no `BackpressureError` arm); a 429 on complete folds to `SubmitOtherFailure` there — **this is REQ-427's own gap, not introduced here**, restated for completeness |
| Process instance (header) | `InstanceDetailController.detailState` (`RendererState<InstanceDetail>`) | `GET /instances/:id` in flight | network/5xx/404 on detail fetch | 403 on detail fetch | unrecognized `status` (§4.4.3 step 3) | N/A | 429 on detail fetch — `retryDetailBackpressure()` |
| Process instance (timeline) | `InstanceDetailController.timelineState` (`RendererState<InstanceTimelinePage>`) | first/next timeline page in flight | network/5xx/404 on timeline fetch | 403 on timeline fetch | malformed item or unrecognized `eventType`/missing required field (§4.4.3 step 3) | N/A | 429 on timeline fetch — `retryTimelineBackpressure()`, independent countdown from the header's own |

**Every cell above resolves to an already-existing `RendererState`/
`ApiError`/`StaleVersionReason`/`FormSubmitOutcome` variant — this design
introduces zero new variants to any of those three sealed hierarchies.**
The only new sealed hierarchy this design introduces at all is
`TaskClaimOutcome` (§3.2), precisely because claim's 409 case (AC3) needs a
distinction (`TaskClaimNoLongerAvailable`, carrying "trigger an inbox
refresh" semantics) that none of the three existing hierarchies expresses
and that must NOT be folded into `RendererState` for the reason §3.3 gives.

---

## 6. Widget layer

### 6.1 Registration

```
Widget buildTaskRenderer(BuildContext context, Map<String, dynamic> definition)
Widget buildProcessRenderer(BuildContext context, Map<String, dynamic> definition)
```

Both follow `buildListRenderer`'s own shape exactly (§0): read the
definition's own required key(s), validate type, fall back to
`RendererStateView<T>(state: staleVersionState(UnknownFieldType(...)),
...)` on a non-string/absent key, otherwise delegate to a private
`_XRendererRoot` `ConsumerStatefulWidget`.

- `"task"` definition's required shape: `{"task_id": "<string>"}` — the
  task-detail screen's own entry point (distinct from the inbox, which
  needs no definition payload at all — see §6.5's OQ-2 on how either
  screen is actually reached, since no route exists yet).
- `"process"` definition's required shape: `{"instance_id": "<string>"}`.

Registered as `registry.register("task", buildTaskRenderer)` and
`registry.register("process", buildProcessRenderer)` at the same
bootstrap composition root REQ-426/427's own registrations live at (§0).

### 6.2 Task-detail screen composition

The task-detail root widget owns **two** controllers, composed, not one:

- `TaskDetailController` (§3.4) — the task metadata fetch + claim action.
- `FormRendererController` (REQ-427 §3.2) — constructed once
  `TaskDetailController.state` reaches `RendererContent(TaskDetail)`, using
  that `TaskDetail`'s own `formId`/`formVersion`/`instanceId` (§3.6) plus
  the screen's own `taskId`.

Rendering order: `RendererStateView<TaskDetail>` wraps the whole screen
(outermost — a task-fetch failure/stale-version/backpressure means there is
no task to show a form for at all); its `contentBuilder` renders the task's
own header (node name, status, a claim button if `status == pending` and
`assigneeRef` does not already identify the caller — ownership comparison
left to MOBILE-DEV, not an acceptance criterion here) **and**, beneath it,
`RendererStateView<FormViewModel>` (REQ-427 §6.1's own root widget,
reused unchanged) wrapping the form itself. Two independent
`RendererStateView`s stacked vertically — the same "independent `Renderer
State`s, not one" principle §4.4.1/§4.4.2 states for the instance screen,
applied here between the task's own metadata and its form.

### 6.3 Process-instance screen composition

`RendererStateView<InstanceDetail>` (outer) wrapping a header (status badge
— keyed `Key('instance-status')` — plus, for an `active` instance, the
derived "current step" text per §4.2's algorithm, keyed
`Key('instance-current-step')`) and, inside the same `contentBuilder`, a
second `RendererStateView<InstanceTimelinePage>` wrapping a scrollable
timeline list (`ListView.builder`, mirroring `list.dart`'s own
`_ListRendererBody` scroll-to-end-triggers-`loadNextPage` pattern exactly,
here triggering `loadMoreTimeline()`), each entry keyed
`Key('timeline-entry-${entry.eventId}')`. **No button, menu item, or
gesture anywhere in this widget calls `cancel`/`rebind-pins`/`reconstruct`/
`advance-timer`** — restated here per §1/§4.1, since this is the widget
layer where such a control would actually be added if someone were
tempted to.

### 6.4 Claim-button area (task-detail screen)

A button, keyed `Key('task-claim-button')`, calling
`TaskDetailController.claim()`. `lastClaimOutcome` renders, non-exclusively
with the rest of the screen (same "never replace the content, only
annotate it" principle as REQ-427 §5.1/§6.5):

| `TaskClaimOutcome?` | Rendered | `Key` |
|---|---|---|
| `null` | nothing | — |
| `TaskClaimSuccess` | claim button replaced by the now-claimed state (no banner — the screen's own header re-renders from the new `TaskDetail`) | — |
| `TaskClaimNoLongerAvailable` | "This task is no longer available." banner, AND the screen composition layer (§3.3) triggers the inbox's `refreshAfterClaimConflict()` | `Key('task-claim-no-longer-available')` |
| `TaskClaimForbidden` | "You don't have permission to claim this task." banner | `Key('task-claim-forbidden')` |
| `TaskClaimNetworkUnavailable` | "No network connection." banner | `Key('task-claim-network-unavailable')` |
| `TaskClaimOtherFailure` | generic failure banner | `Key('task-claim-other-failure')` |

### 6.5 Inbox item — claim action

Each `TaskInboxItem` row (`ListTile`-equivalent, keyed
`Key('task-inbox-item-${item.id}')`) carries its own claim button (keyed
`Key('task-inbox-claim-${item.id}')`) calling
`TaskInboxController.claim(item.id)` (§2.4) — same `TaskClaimOutcome`
handling as §6.4's table, rendered per-row (e.g. as a row-local snackbar/
inline message) rather than a whole-screen banner, since a claim conflict
on one row must not visually disturb the rest of the still-valid list —
left to MOBILE-DEV as an ordinary per-row state concern, not itself an
acceptance criterion this design must pin down further.

---

## 7. Cross-module dependencies

- `apps/mobile/lib/renderers/task/task.dart` imports:
  `../renderer_state.dart`, `../renderer_state_view.dart`,
  `../../api/api_client.dart` (`HttpGateway`, `PostCapableHttpGateway`),
  `../../api/api_error.dart` (`ApiError` and its variants), the form
  renderer's own public surface (`../form/form.dart`'s
  `FormRendererController`, `FormViewModel`, `FormSubmitOutcome` — REQ-427,
  assumed built by the time this screen is wired; if REQ-427's
  implementation has not yet landed when REQ-428 is implemented, that is a
  sequencing question for ORCH/MOBILE-DEV, not something this design
  resolves by substituting a stub).
- `apps/mobile/lib/renderers/process/process.dart` imports:
  `../renderer_state.dart`, `../renderer_state_view.dart`,
  `../../api/api_client.dart` (`HttpGateway`), `../../api/api_error.dart`.
  **No import of anything under `lib/renderers/form/` or
  `lib/definitions/`** — the instance screen never resolves a pinned form
  (§4.1's read-only scope has no form to render).
- No change to `apps/mobile/lib/renderers/renderer_state.dart`,
  `renderer_state_view.dart`, `renderer_registry.dart`,
  `apps/mobile/lib/renderers/list/**`, `apps/mobile/lib/renderers/form/**`,
  `apps/mobile/lib/definitions/pinned_form_resolver.dart`, or
  `apps/mobile/lib/api/**` — this design only adds two new registry
  entries (`"task"`, `"process"`) and composes the existing
  `FormRendererController`/`PinnedFormResolver` unchanged (§3.5/§3.6).
  (OQ-3's `ConflictError` gap in `renderer_state.dart` is flagged, not
  fixed, by this design — see §3.3.)
- No change to `lib/` (`lib/letflow/routers/tasks.ex`/`instances.ex` are
  read-only references) — every backend contract read in §0 is read as-is.

---

## 8. Invariants

- **INV-1**: `TaskClaimOutcome` (§3.2) is the **only** place claim's 409 is
  given action-specific meaning — `rendererStateForError`/`RendererState`
  is never consulted for a claim attempt (§3.3).
- **INV-2**: Completing a task is **always** `FormRendererController.submit()`
  (REQ-427, unmodified) — this design introduces no second
  output-variables-submission code path (§3.5).
- **INV-3**: The process-instance screen calls exactly two routes,
  `GET /instances/:id` and `GET /instances/:id/timeline` — no other
  `Letflow.Routers.Instances` route is referenced by any type or method in
  §4 (§1/§4.1).
- **INV-4**: `TaskDetail.formId`/`formVersion` (§3.1) are read once, from
  the task-detail response's own keys, and passed unchanged into
  `PinnedFormResolver.resolve` — no intervening "active version" lookup
  exists anywhere in this design's call graph (§3.6).
- **INV-5**: A claim conflict (`TaskClaimNoLongerAvailable`) never leaves
  `TaskDetailController.state`/`TaskInboxController.state` in anything but
  `RendererContent` (or whatever it already was) — only `load()`/
  `loadFirstPage()`/`loadNextPage()` ever produce a non-`RendererContent`
  `RendererState` for either controller (§3.3, mirroring REQ-427's own
  INV-6).
- **INV-6**: `InstanceDetailController.detailState` and `.timelineState`
  are independent — a failure/backpressure on one is never reflected in
  the other's value (§4.4.1/§4.4.2).

---

## 9. Acceptance-criteria resolution map

- **AC1** ("list inbox, claim a task, open it, complete it"): §2 (inbox
  list + claim), §3.4 (open — `TaskDetailController.load()`), §3.2/§2.4/§3.3
  (claim, shared function), §3.5 (complete, via `FormRendererController
  .submit()`).
- **AC2** ("form_version pinning is structural ... never 'the active
  version'"): §3.6 — the unbroken `TaskDetail.formVersion` →
  `FormRendererController` constructor → `PinnedFormResolver.resolve` data
  flow, with no alternate lookup anywhere in the call graph; INV-4.
- **AC3** ("409-on-claim: specific state shown, inbox refresh triggered,
  not a crash"): §3.2's `TaskClaimNoLongerAvailable` + §3.3's full
  rationale + §6.4's table row + §2.3's `refreshAfterClaimConflict()`.
- **AC4** ("process-instance screen: status + current step + timeline
  rendering; no cancel/rebind/advance action anywhere"): §4.2 (status),
  §4.2's "current step" derivation, §4.3/§4.4 (timeline), §1/§4.1/§6.3's
  explicit restatement of the exclusion at three separate layers (scope,
  controller, widget).
- **AC5** ("every error class mapped onto the six-state wrapper for every
  screen"): §5's table — every `RendererState<T>` instance across both
  renderers, plus the two action-outcome types (`TaskClaimOutcome`,
  `FormSubmitOutcome`) that are deliberately NOT routed through
  `RendererState`, with the reason stated in both §3.3 and §5's own
  prefatory paragraph.
- **AC6** ("no implementation code — signatures and state shapes only"):
  every code block in this document is a signature/type/state shape or
  prose algorithm description; no method body, no `build()` return
  statement, no control-flow statement is written as real Dart anywhere
  above.

---

## 10. Open questions (explicit — not silently resolved)

- **OQ-1**: `apps/mobile/lib/definitions/pinned_form_resolver.dart`'s own
  doc comment cites `lib/letflow/design/req424-mobile-pinned-form-version-
  resolution.md` as its design authority, but no file by that name (or any
  `req424*`/`*pinned-form*` name) exists under `lib/letflow/design/` —
  confirmed by direct glob, zero hits. Either the design doc was never
  committed, or it was committed under a different name/path and the
  source comment is stale. DOC-UPDATER/CODE-DESIGN-VALIDATOR should
  resolve which, and either restore the missing file or correct the
  comment — this design proceeded from the shipped `.dart` source as the
  authority in the meantime, per §0.
- **OQ-2**: No `go_router` route exists today for a task-inbox screen, a
  task-detail screen, or an instance-detail screen (confirmed against
  `docs/mobile/architecture.md`'s "Navigation and routes" section and a
  grep of `apps/mobile/lib/bootstrap/`). This design specifies the two
  renderers' own internal controllers/widgets and their `RendererRegistry`
  registration, but not how a user actually navigates to either screen, or
  how the task-detail screen's claim-conflict handler (§3.3) obtains a
  reference to the inbox screen's `TaskInboxController` to call
  `refreshAfterClaimConflict()` on. Left to MOBILE-DEV's own navigation
  wiring, matching REQ-427 §0's identical precedent for its own form
  renderer.
- **OQ-3**: `rendererStateForError`'s `switch` in `renderer_state.dart`
  (REQ-426) has no explicit `ConflictError` case in the version read for
  this design (§3.3) — `ApiError` has 9 variants and that `switch` names 9
  arms, but the arm list read did not include one literally matching
  `ConflictError()`; re-verify at implementation time (the analyzer's
  exhaustiveness check would already be failing the build today if this is
  really missing, which would mean REQ-426 cannot have shipped as
  described — so this is more likely a transcription gap in this design's
  own reading than a real compile failure, flagged rather than either
  silently trusted or silently "fixed" by this design touching a file
  outside its own build surface).
- **OQ-4**: "Current step" has no dedicated field on `GET /instances/:id`
  or `GET /instances/:id/timeline` — this design derives it from the
  timeline's own most recent non-null-`node_id` entry (§4.2). A future
  requirement could add a dedicated "current nodes" field to
  `instance_map/1` (mirroring `complete_result_map`'s own `current_nodes`)
  if this derivation proves insufficient for a real tenant's UI needs.
- **OQ-5**: `TaskClaimOutcome` (§3.2) has no dedicated 429 variant — a
  429-on-claim folds to `TaskClaimOtherFailure`, losing the retry-after
  countdown UX `RendererBackpressure` gives every other 429 case in this
  app. AC3 names only the 409 case explicitly; this design does not
  speculatively add a sixth variant for a case no acceptance criterion
  exercises. A future requirement should add one if real tenant traffic
  exercises backpressure on the claim route specifically.
