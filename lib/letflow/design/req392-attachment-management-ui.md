# Design: REQ-392 — Frontend attach/remove/rejection/quota/history UI for instance attachments

**Status:** design, pending CODE-DESIGN-VALIDATOR.
**Requirement:** REQ-392 (`docs/requirements.yaml`, letflow-queue task 752, GH-1640, stage S8).
**Filed from:** `test/uat-reports/gui-review-2026-09-20-shipment-attach-delivery-note.md` (PW-09),
scenario `test/fixtures/uat/scenarios/swiftroute/shipment-attach-delivery-note.yaml`,
EO-001..EO-005. Fourth of four requirements from that finding.
**Depends on:** REQ-387, REQ-389, REQ-390, REQ-391 — **all four `status: done`**, confirmed
directly against `docs/requirements.yaml` (not assumed) before this design was written.
**Owner (implementer):** FRONTEND-DEV.

**This document produces:** one new backend context function + one new backend route (the
one genuine gap found while reading REQ-390's shipped source — see §1), three new/changed
frontend files (`web/src/components/instances/AttachmentPanel.tsx`, `web/src/api/attachments.ts`,
`web/src/hooks/useAttachments.ts`), one changed page (`web/src/pages/tasks/TaskInboxPage.tsx`),
new types in `web/src/types/api.ts`, and the real Playwright spec
`web/tests/e2e/pipelines/shipment-attach-delivery-note.pipeline.e2e.spec.ts`. **No
implementation code** — signatures, type shapes, component responsibilities, and the e2e
spec's scenario design in prose only. FRONTEND-DEV (and, for §1's small backend addition,
ELIXIR-DEV or FRONTEND-DEV under the same PR per this project's existing "frontend requirement
adds a small route" precedent, e.g. REQ-387/REQ-386) writes the actual code from this
document.

---

## 0. Sources read for this design (confirming shipped state, not the requirement's own
## narrative or any design doc's paraphrase)

- `web/src/components/instances/AttachmentPanel.tsx` (full, REQ-387's shipped widget) —
  upload form + `DataTable` list with a `View` link column. **No remove action, no rejection
  message beyond a generic toast, no storage-usage figure.**
- `web/src/components/instances/__tests__/AttachmentPanel.test.tsx` (full) — confirms exactly
  two tests exist today (list rendering, successful upload); no delete test, no rejection test,
  no quota test.
- `web/src/api/attachments.ts` (full) — `attachmentsApi.delete(instanceId, attachmentId)`
  **already exists** as a typed client function calling
  `DELETE /api/v1/instances/:id/attachments/:attachment_id`, but nothing in the app calls it.
  This requirement wires it up; it does not need to be built.
- `web/src/hooks/useAttachments.ts` (full) — `useAttachments`/`useUploadAttachment` only; no
  delete hook, no storage-usage hook.
- `lib/letflow/routers/instances.ex` — read in full around lines 380-410 (route table) and
  1009-1113 (`handle_upload_attachment/2` + every `render_upload_attachment/3` clause) and
  1471-1486 (`handle_delete_attachment/3`). Confirms:
  - `DELETE /:id/attachments/:attachment_id` (`:AttachmentsManage`) **already exists and is
    fully wired** to `Attachments.delete/3`, returning `204` on success, `404` on a
    cross-tenant/cross-instance/nonexistent id. **This closes the "does DELETE exist" question
    the handoff flagged — it does. REQ-392 builds no new DELETE route.**
  - `render_upload_attachment/3` has a clause for `{:error, :content_type_not_allowed}` → `415`
    (`Response.unsupported_media_type/2`, body `detail` = `"content type \"<rejected>\" is not
    allowed for attachments; allowed types are: <sorted, comma-joined allowlist>"`) and for
    `{:error, :storage_quota_exceeded}` → `409` (`Response.conflict/2`, body `detail` =
    `"tenant storage quota has been reached"`). Both already shipped (REQ-389/390 respectively).
    Exact response body shape confirmed at §2 below.
  - **No route exposes `Attachments.get_storage_usage/1` over HTTP anywhere in this router.**
    Grepped exhaustively for `storage_usage`/`storage-usage`/`:StorageUsage`. REQ-390's own
    `OUT OF SCOPE` note names this exactly: *"the route exposing it (left to REQ-392's own
    scoping...)"*. This is a real, necessary small backend addition — see §1.
- `lib/letflow/repository/attachments.ex` (full) — `upload/2`'s exact `{:error, ...}` union
  (confirmed at §2), `delete/3`'s signature (`id, deleted_by, opts`), `get_storage_usage/1`
  (returns `{:ok, non_neg_integer()}`, computed-on-read `SUM(byte_size)`, tenant-scoped via
  `opts[:prefix]`), `check_storage_quota/3` (private; reads `Tenant.storage_allowance_bytes`
  via `Repo.get(Tenant, tenant_id)`), `record_attachment_attached_event/2` and
  `record_attachment_removed_event/3` (REQ-391, already shipped, post-commit, best-effort
  `ATTACHMENT_ATTACHED`/`ATTACHMENT_REMOVED` events naming `file_name` and the actor).
- `lib/letflow/instances.ex` (full) — `timeline/3`'s `render_description/3` clause list
  (lines 264-312) **already has dedicated clauses for `ATTACHMENT_ATTACHED`/
  `ATTACHMENT_REMOVED`**: `"#{file_name} attached by #{actor}"` /
  `"#{file_name} removed by #{actor}"`, `actor` resolved from the event's `actor_id` via the
  same batched-lookup/fallback chain every other event type gets. **This is a surprising
  finding — see §6, no backend or frontend change is needed for AC4's description text,
  only a test.** `history/3`'s `history_item_map/1` (router) includes the full `payload` map;
  `timeline_item/2`'s response map does **not** include `payload`, only `metadata` (event
  metadata, a different field) — relevant to §7 (the approval screen must read from
  `GET /instances/:id/history`, not `/timeline`, to reach `attachments_at_decision`).
- `lib/letflow/engine.ex` (`append_task_completed_event/5`, lines ~4363-4399, and
  `attachment_snapshot/1`, lines ~4407-4419) — the `TASK_COMPLETED` event's payload carries
  `attachments_at_decision: [%{attachment_id, file_name, content_type, byte_size, uploaded_by,
  created_at}]`, a **snapshot** taken inside the same transaction as task completion (REQ-391's
  own explicit snapshot-vs-live-reference decision — survives a later `delete/2` on the same
  attachment, per that design doc's justification). This is the exact source AC5 must render.
- `web/src/components/instances/TimelineFeedItem.tsx` + `TimelineFeed.tsx` +
  `web/src/pages/instances/timelineUtils.ts` (full) — `TimelineFeedItem` renders
  `entry.description` + `entry.actor_display_name` + `entry.event_type` **generically for any
  event type**, no per-`event_type` switch/allowlist in the frontend at all. Confirms §6's
  finding: nothing here needs to change for `ATTACHMENT_ATTACHED`/`REMOVED` to render
  correctly — they already flow through the same generic path `TASK_COMPLETED`/
  `INSTANCE_STARTED`/etc. use today.
- `web/src/pages/instances/InstanceDetailPage.tsx` (relevant excerpts) — confirms
  `AttachmentPanel` and `TimelineFeed` are both already mounted on the same page (different
  tabs: `attachmentPanel` renders unconditionally above the tab switch, `TimelineFeed` renders
  under the `timeline` tab), so "near the widget" (AC3) and "the instance's history/timeline
  view" (AC4) are the same page, confirmed, not two different screens to locate.
- `web/src/pages/tasks/TaskInboxPage.tsx` (full) — the task detail/complete screen (right-hand
  `TaskDetailPanel`, mounted from `TaskInboxPage`). This is the "approval/decision screen" AC5
  refers to — there is no separate, dedicated "approval" page anywhere in `web/src/pages/`
  (grepped for `Approval`/`Decision`/`Review` page components; the only matches are
  promotion-review and solution-pack-update-review, unrelated domains). Today
  `TaskDetailPanel` renders a `Complete Task` form for a `PENDING` task assigned to the caller,
  but renders **nothing** for an already-`COMPLETED` task beyond its status badge — no decision
  detail, no attachment reference. This is the gap AC5 closes.
- `web/src/api/tasks.ts` / `web/src/hooks/useTasks.ts` — `GET /tasks/:id` (`tasksApi.get`)
  response has no `attachments_at_decision` field (confirmed against `Letflow.Tasks.get_task/2`
  and its `task_json`-equivalent allowlist — that data lives only in the `TASK_COMPLETED`
  event's payload, not on the `tasks` row). The approval screen must fetch it from
  `GET /instances/:id/history?event_type=TASK_COMPLETED`, not from the task record.
- `web/src/api/instances.ts` (full) — `instancesApi.events(id, params)` already calls
  `GET /api/v1/instances/:id/history` with an `event_type` filter param (backend already
  supports this filter, confirmed at `lib/letflow/instances.ex:140`/`filter_by_event_type`).
  Its declared return type (`EventRecord[]`) is a pre-existing mismatch with the router's real
  envelope shape (`{"items": [...], "next_cursor", "count"}` — confirmed at
  `render_page_result/3`); `EventHistoryPanel.tsx` already works around this by treating
  `eventsQuery.data` as `unknown` and pulling `.items` out at runtime. §7 reuses this same
  established workaround rather than "fixing" the mistyped client function, which is out of
  this requirement's scope and would touch `EventHistoryPanel.tsx` too.
- `web/src/utils/classifyError.ts` + `web/src/api/client.ts`'s `throwOnErrorResponse` (full) —
  confirms the RFC 9457 body's `type`/`title`/`detail`/`trace_id` fields are surfaced on the
  thrown `ApiError` as `code`/`message`/`details`, and confirms the important distinguishing
  fact used at §2: `Error.conflict/1` (`lib/letflow/api/error.ex`) sets the **same** `type` URI
  (`<base>/conflict`) for every 409 this codebase ever sends via that constructor — there is no
  per-cause `code` to switch on. Within `AttachmentPanel`'s own upload-mutation error handler,
  however, `upload/2`'s only two rejection paths that reach the frontend as errors with status
  409 or 415 are `:storage_quota_exceeded` (409) and `:content_type_not_allowed` (415)
  respectively — no other `render_upload_attachment/3` clause uses either status code — so
  **HTTP status alone is sufficient to disambiguate the two, scoped to this one mutation**; no
  new backend `code`/`type` value is needed.
- `lib/letflow/identity/tenant.ex` + `priv/repo/migrations/20260923000001_...` — confirms
  `Tenant.storage_allowance_bytes` (`:integer`, DB-defaulted `1_073_741_824` = 1 GiB) is the
  allowance field `check_storage_quota/3` already reads.
- `web/src/components/ui/DataTable.tsx`, `Button.tsx`, `QueryStateBoundary.tsx` — confirms
  `DataTable`'s `accessor` can render arbitrary `ReactNode` per column (already used for the
  existing `View` link), and `Button`'s `variant: 'primary' | 'secondary' | 'danger' | 'ghost'`
  — `danger` is the existing convention for a destructive action (no new variant needed).
- `web/src/components/instances/CancelInstanceDialog.tsx` (structure skim) — the existing
  confirm-before-destructive-action pattern for instance cancellation (focus-trapped modal,
  `Escape` to close). AC1 does **not** require a full modal — see §4's simpler two-click
  in-row confirm decision, justified there — but this file is the precedent if
  CODE-DESIGN-VALIDATOR or REVIEWER prefers modal parity; flagged as an open question (§10).
- `web/src/api/useTenantScopedQueryKeys.ts` + `web/src/api/queryKeys.ts` (relevant excerpts) —
  confirms the existing `instances.attachments(tenantId)` key-builder pattern to extend for a
  new `storageUsage` key (§5) and confirms every tenant-scoped hook already goes through this
  one hook — no second scoping mechanism to invent.
- `web/tests/e2e/pipelines/attachment-cross-tenant.pipeline.e2e.spec.ts` (structure/imports
  read; the file's own extensive top-of-file comments on tenant/realm provisioning, the
  `pool_size`/admission-capacity caveat, and the `createPipeline`/`pl.step`/`pl.gate`/
  `navigateSpa`/`loginWithToken`/`shot` helper set) — the direct structural precedent for §8's
  new spec; both specs are filed from the same PW-09 finding and REQ-392 explicitly depends on
  REQ-387, whose own spec this mirrors.
- `test/fixtures/uat/scenarios/swiftroute/shipment-attach-delivery-note.yaml` (full) — the
  5-step/EO-001..EO-005 scenario this design's e2e spec (§8) and rejection/quota/history/
  approval UI (§2-§7) must satisfy, and the exact `NOTE (ISS-0526)` block §9 removes.
- `test/uat-reports/gui-review-2026-09-20-shipment-attach-delivery-note.md` (full, including
  the 2026-09-23 DOC-UPDATER status-update note) — confirms REQ-387/389/390/391 are now all
  `done` and REQ-392 was the last blocker.
- `test/fixtures/uat/scenarios/platform/attachment-cross-tenant-probe.yaml` (top-of-file) —
  the sibling scenario whose own `NOTE (ISS-0527)` was already removed by REQ-387 (§9's direct
  precedent for exactly how to remove ISS-0526 here: delete the `NOTE` comment block, keep the
  `pipeline_test:` line, keep the "UAT-RUNNER drives this Playwright pipeline test..." lines
  that follow it).

---

## 1. The one real gap: no route exposes `get_storage_usage/1`

**Finding, not assumption:** `Letflow.Repository.Attachments.get_storage_usage/1` (REQ-390,
already shipped) is a context-module function with no HTTP caller anywhere. REQ-390's own
`description` names this precisely: *"a context-module function at minimum; REQ-392's frontend
requirement adds the route/UI that surfaces it"*. This is in scope here, not a separate
requirement — AC3 cannot be built without it.

### 1.1 New context function: `Letflow.Repository.Attachments.storage_summary/1`

```
@spec storage_summary(opts()) ::
        {:ok, %{used_bytes: non_neg_integer(), allowance_bytes: integer()}}
        | {:error, :tenant_not_found}
```

- Composes `get_storage_usage(opts)` (existing, unchanged) with a `Tenant` lookup, mirroring
  `check_storage_quota/3`'s own existing tenant-lookup shape (`TenantProvisioning
  .tenant_id_for_schema_name(prefix)` then `Repo.get(Tenant, tenant_id)`) — not a new pattern,
  reuse of an existing one already private in this same module.
- `{:error, :tenant_not_found}` on the same theoretically-unreachable-but-mapped edge
  `render_upload_attachment/3`'s own `:tenant_not_found` clause already guards (a `prefix` that
  resolves to no `tenants` row) — same "unreachable but mapped" discipline the router already
  uses elsewhere in this file.
- Does **not** take an `instance_id` — this is a per-tenant figure, not per-instance (matches
  EO-003's own wording: "the space each attached document takes up counts against SwiftRoute's
  storage allowance", a company-wide figure, not per-shipment).

### 1.2 New route: `GET /api/v1/instances/storage-usage`

- Mounted on the existing `Letflow.Routers.Instances` router (not a new router file) — the
  natural home for an attachment-adjacent read, matching REQ-212's own choice to put
  `/instances/:id/attachments*` here rather than under `Letflow.Routers.Tenants` (which is
  `:TenantsManage`/`PLATFORM_ADMIN`-gated only — wrong permission class for a dispatcher-level
  read).
- **Must be declared before `authz_get "/:id", :InstancesRead`** in the router body — same
  literal-path-before-`:id`-catch-all ordering hazard this file's own moduledoc already
  documents for `/:id/rebind-pins`/`/:id/cancel`/`/:id/reconstruct` (a bare `/:id` pattern
  matches any single path segment, including the literal string `"storage-usage"`, so
  declaration order decides which route wins).
- Permission: `:AttachmentsRead` (reuse — this is an attachment-adjacent read, not a new
  permission class; no REVIEWER-facing new-permission judgement call needed).
- Handler: `handle_storage_usage/1` (or similar name) — no path param to cast (no `:id`), calls
  `Attachments.storage_summary(conn.assigns.scoped_opts)`, renders:
  - `200 {"used_bytes": <int>, "allowance_bytes": <int>}` on `{:ok, summary}`.
  - `422` (`Response.unprocessable/2`, e.g. `"request tenant does not exist"` — matching
    `render_upload_attachment/3`'s own `:tenant_not_found` wording) on the mapped-but-
    unreachable error branch.
- No request body, no query params, no pagination — a single-object read, matching
  `GET /instances/:id/pins`'s own precedent (REQ-080/399, single-object, no envelope).

---

## 2. Backend error-response shapes AC2 must surface verbatim (confirmed against shipped source)

Both already shipped; this requirement adds no new backend error clause.

| Rejection | Status | RFC 9457 `type` (suffix) | RFC 9457 `title` | RFC 9457 `detail` (exact, from source) |
|---|---|---|---|---|
| `:content_type_not_allowed` (REQ-389) | `415` | `unsupported-media-type` | `Unsupported Media Type` | `"content type \"<rejected content_type>\" is not allowed for attachments; allowed types are: <sorted allowlist, comma-joined>"` |
| `:storage_quota_exceeded` (REQ-390) | `409` | `conflict` | `Conflict` | `"tenant storage quota has been reached"` |
| (existing, unchanged) `:file_too_large` | `413` | `content-too-large` (or equivalent — unchanged by this requirement) | — | `"uploaded file exceeds the maximum allowed size"` |

`client.ts`'s `throwOnErrorResponse` maps `body['title']` → `ApiError.message`,
`body['type']` → `ApiError.code`. The frontend renders `ApiError.message` **directly** — the
backend text is already the "readable explanation naming the limit" EO-002 asks for; the
frontend must not compose its own paraphrase (which would risk drifting from the actual
allowlist/allowance if either changes).

---

## 3. AC2 — Rejection messages in `AttachmentPanel`'s upload flow

### 3.1 `onUpload`'s mutation error handler

Today `upload.mutate(formData, { onError: () => toast.error('Failed to upload attachment.') })`
(§0) discards the actual `ApiError` entirely. Replace with a handler that branches on
`error.status` (the two statuses `upload/2` can uniquely produce per §2/§0's confirmation that
no other clause shares either code within this one mutation):

```
onError: (error: ApiError) => {
  if (error.status === 415) {
    setUploadError({ kind: 'content-type', message: error.message })
  } else if (error.status === 409) {
    setUploadError({ kind: 'quota', message: error.message })
  } else {
    setUploadError({ kind: 'other', message: 'Failed to upload attachment.' })
  }
}
```

`error.message` is `ApiError.message`, sourced from the backend's `title` field per §2's table
— **not** what's rendered (a bare `"Conflict"`/`"Unsupported Media Type"` title is not the
"distinct, readable message naming the specific limit hit" AC2 asks for). The readable text is
the RFC 9457 `detail` field, which `client.ts`'s `throwOnErrorResponse` (§0) puts on
`ApiError.details` for non-409 non-429 errors (the generic `!response.ok` branch spreads the
whole parsed body into `details` when `errors` isn't a key) and, for the 409 branch
specifically, spreads the body directly into `details` too (§0's client.ts excerpt, the 409
branch's own `details: { xResourceVersion: ..., ...body }`). So the design's `onError` handler
must read `error.details?.detail as string | undefined`, falling back to `error.message` only
if `detail` is absent — **flagged as an implementation-time detail to verify against the live
`ApiError` shape** (the exact `details` key name for a plain-object-spread body is confirmed by
reading `client.ts` at implementation time; this design specifies the *field this app already
receives the text on*, not a new backend field).

### 3.2 Rendering

- New local state on `AttachmentPanel`: `uploadError: { kind: 'content-type' | 'quota' | 'other'; message: string } | null`, cleared on a new upload attempt (`onUpload`'s start) and on successful upload.
- Rendered as `<p data-testid="attachment-upload-error" data-error-kind={uploadError.kind}>{uploadError.message}</p>` directly under the upload form, **in addition to** the existing `toast.error(...)` call (kept for consistency with every other mutation on this page) — the inline element exists because AC2 requires the message to be distinctly readable and test-assertable per rejection kind, and a toast that auto-dismisses is a weaker guarantee for both a human re-reading it and a test asserting on it. The `data-error-kind` attribute is what makes "content-type rejection" and "quota rejection" independently assertable by two separate tests (AC2's own "verified by a test for each" wording).
- No change to the existing `attachmentsQuery`/`rendererState`/`QueryStateBoundary` machinery — `uploadError` is upload-mutation-local state, unrelated to the list-fetch error states that machinery already covers.

---

## 4. AC1 — Remove action on `AttachmentPanel`

### 4.1 `web/src/hooks/useAttachments.ts` — new `useDeleteAttachment(instanceId)`

```
export function useDeleteAttachment(instanceId: string): UseMutationResult<
  void, ApiError, string /* attachmentId */
>
```

- `mutationFn: (attachmentId) => attachmentsApi.delete(instanceId, attachmentId)` — the client
  function already exists (§0), this is purely the missing TanStack Query wrapper.
- `onSuccess`: `qc.invalidateQueries({ queryKey: instanceKeys.attachments(instanceId) })` —
  same invalidation target `useUploadAttachment` already uses, so the list re-fetches and
  "updates ... without a full page reload" (AC1's own wording) falls out of the existing
  TanStack Query cache-invalidation mechanism already in use, not a new mechanism.
- Also invalidate the new storage-usage key (§5.2) in the same `onSuccess` — AC3 requires the
  usage figure to reflect a removal too, and this mutation is the one place removal happens.

### 4.2 `AttachmentPanel.tsx` — new `remove` column + confirm affordance

- New `DataTableColumn<AttachmentRow>` entry (alongside the existing `view` column):
  `id: 'remove'`, `header: ''`, `accessor` renders a `Button variant="danger" size="sm"
  data-testid="attachment-remove-button"` per row.
- **Confirm-before-destroy, in-row two-click pattern** (not a modal): clicking `Remove` once
  swaps that row's button to a `data-testid="attachment-remove-confirm-button"` reading
  `"Confirm remove?"` alongside a `Cancel` (ghost) button for ~a component-local `useState`
  window; a second click on `Confirm remove?` calls
  `deleteAttachment.mutate(row.attachment.id, { onSuccess: () => toast.success(...),
  onError: () => toast.error('Failed to remove attachment.') })`. Justification for choosing
  this over `CancelInstanceDialog`'s modal: removing one row from a list is a smaller-blast-
  radius destructive action than cancelling an entire running instance, and every other
  row-level action on this page (`View`) is already inline, not modal-launched — an in-row
  confirm keeps that consistency. **Flagged as an open question (§10)** in case
  CODE-DESIGN-VALIDATOR or REVIEWER prefers modal parity with `CancelInstanceDialog` instead.
- `loading`/`disabled` on the confirm button while `deleteAttachment.isPending`, matching the
  existing `upload.isPending` pattern already on the `Upload` button.

---

## 5. AC3 — Storage-usage figure

### 5.1 `web/src/api/attachments.ts` — new client function

```
storageUsage: (): Promise<{ used_bytes: number; allowance_bytes: number }> =>
  client.get('/api/v1/instances/storage-usage'),
```

New type in `web/src/types/api.ts`: `StorageUsage { used_bytes: number; allowance_bytes:
number }`.

### 5.2 Query key + hook

- `web/src/api/queryKeys.ts`: add `attachments: { storageUsage: (tenantId: string) =>
  ['tenant', tenantId, 'attachments', 'storage-usage'] as const }` — a new top-level group
  (not nested under `instances`), since this is tenant-scoped, not instance-scoped (§1.1).
- `web/src/api/useTenantScopedQueryKeys.ts`: add the corresponding `attachments: { storageUsage:
  queryKeys.attachments.storageUsage.bind(null, tenantId) }` passthrough, same shape every
  other group already uses.
- `web/src/hooks/useAttachments.ts`: new `useStorageUsage()` (no `instanceId` param — tenant-
  scoped): `useQuery({ queryKey: attachmentKeys.storageUsage(), queryFn:
  attachmentsApi.storageUsage })`.
- Both `useUploadAttachment` and `useDeleteAttachment`'s `onSuccess` invalidate
  `attachmentKeys.storageUsage()` in addition to their existing `instances.attachments(...)`
  invalidation (§4.1) — this is what makes "its rendered value changes correctly across an
  accepted upload and a removal" (AC3) hold without a manual refetch.

### 5.3 Rendering, "near the widget"

- `AttachmentPanel.tsx` renders a small `data-testid="attachment-storage-usage"` line above the
  upload form (same section, not a separate panel — "near the widget" per AC3's own wording,
  and §0 already confirmed `AttachmentPanel` and `TimelineFeed` share one page so there is no
  ambiguity about which page): `"<formatByteSize(used_bytes)> of <formatByteSize
  (allowance_bytes)> used"`, reusing the file's own existing `formatByteSize` helper (already
  defined in this file, §0) rather than inventing a second formatter.
- Loading/error states for this one figure use inline text (`"Storage usage unavailable"` on
  error, not `QueryStateBoundary` — that component's `columns`/full-panel-replacement shape is
  built for the main list, not a one-line stat; using it here would blank the whole panel on a
  transient usage-fetch failure while the list itself is fine).

---

## 6. AC4 — Timeline renders attach/remove entries with actor names

**Finding: no frontend or backend code change is required for this acceptance criterion.**
Confirmed at §0: `Letflow.Instances.render_description/3` already has dedicated
`ATTACHMENT_ATTACHED`/`ATTACHMENT_REMOVED` clauses (shipped by REQ-391) producing
`"<file_name> attached by <actor>"` / `"<file_name> removed by <actor>"`, and
`TimelineFeedItem.tsx` already renders any `TimelineEntry`'s `description` +
`actor_display_name` generically, with no per-`event_type` allowlist to extend. The existing
`TimelineFeed`/`useInstanceTimeline` wiring on `InstanceDetailPage.tsx` (§0) already surfaces
whatever the backend returns.

**What AC4 actually requires from this requirement:** a **test** proving this already-working
path, not new production code — per the acceptance criterion's own wording ("verified by a
test"). Add (or extend) a component test for `TimelineFeed`/`TimelineFeedItem` (or an
integration-level `InstanceDetailPage` test) asserting: given a `TimelineEntry` with
`event_type: "ATTACHMENT_ATTACHED"`, `description: "delivery-note.pdf attached by lena"`, the
rendered DOM contains that text; likewise for `ATTACHMENT_REMOVED`. This closes a real coverage
gap (§0 confirmed no existing test exercises either event type through this component) without
requiring any implementation change.

---

## 7. AC5 — Approval/decision screen renders the reviewed attachment's `file_name`

`TaskDetailPanel` (in `web/src/pages/tasks/TaskInboxPage.tsx`, §0) is the approval/decision
screen. Today it renders nothing for a `COMPLETED` task beyond its status badge.

### 7.1 New hook: `useTaskCompletionAttachments(instanceId, taskId)`

```
export function useTaskCompletionAttachments(
  instanceId: string,
  taskId: string,
  enabled: boolean,
): UseQueryResult<Array<{ attachment_id: string; file_name: string }>>
```

- `queryFn`: calls `instancesApi.events(instanceId, { event_type: 'TASK_COMPLETED' })`
  (existing client function, §0), unwraps the response's `.items` array using the same runtime
  pattern `EventHistoryPanel.tsx` already established for this same mistyped-but-working client
  function (§0 — do not "fix" `instancesApi.events`'s return type as part of this change; that
  touches a file outside this requirement's scope), finds the item whose
  `payload.task_id === taskId` (a `TASK_COMPLETED` event's `payload.task_id`, confirmed present
  at `lib/letflow/engine.ex`'s `append_task_completed_event/5`, §0), and returns
  `payload.attachments_at_decision` (an array of `{attachment_id, file_name, content_type,
  byte_size, uploaded_by, created_at}` objects per §0's `attachment_snapshot/1`) mapped down to
  just `{attachment_id, file_name}` — the panel only needs the name (AC5's own wording: "names
  that attachment (file_name at minimum)").
- `enabled: enabled && task.status === 'COMPLETED'` — only fetched for a completed task, not
  fired speculatively for every open `TaskDetailPanel` (avoids an extra request on the far more
  common `PENDING` case).
- A `TASK_COMPLETED` event with an empty `attachments_at_decision` array (no attachment was
  present at decision time) is a valid, distinct state from "still loading" or "fetch failed" —
  render nothing extra in that case, not an error.

### 7.2 `TaskDetailPanel` rendering addition

- New block, placed after the existing "Status badge" section, gated on `task.status ===
  'COMPLETED'`: `<div data-testid="task-decision-attachments">` — if the hook's data is
  non-empty, render `"Reviewed document<s>: <file_name>[, <file_name>...]"`; if empty (fetched
  successfully, zero attachments at decision time), render nothing (no empty-state text — this
  section simply does not appear, matching this page's existing convention of omitting
  optional sections rather than showing a placeholder, e.g. `correlation_key`'s own conditional
  render at line ~326).
- No new mutation, no new write path — this is a pure read addition alongside the existing
  `useTask` call already in `TaskDetailPanel`.

---

## 8. AC6 — Real Playwright spec at `web/tests/e2e/pipelines/shipment-attach-delivery-note.pipeline.e2e.spec.ts`

**Confirmed at §0: this file does not exist yet** (only its sibling
`attachment-cross-tenant.pipeline.e2e.spec.ts` does). It must be authored as a real spec, not a
stub, per AC6's own wording and this project's explicit anti-pattern (never author a spec
against an unbuilt feature — the original 2026-09-20 GUI review deferred exactly this file for
that reason, §0).

### 8.1 Structural precedent

Follows `attachment-cross-tenant.pipeline.e2e.spec.ts`'s own established shape (§0):
`createPipeline`/`pl.step`/`pl.gate`, `navigateSpa`, `loginWithToken`, `shot` for evidence
capture, real tenant/user provisioning via the Keycloak Admin API (no seeded "swiftroute"
fixture tenant exists, confirmed by that sibling spec's own file-header note, §0) — but
**simpler than the cross-tenant spec**: this scenario's actors (dispatcher Lena, ops manager
Marco) are two users of the **same** company, not two different tenants, so only **one**
tenant/realm needs provisioning (mirroring that sibling spec's own `createTenantRealm`/
`createFirstRealmUser`/`createSecondRealmUser` helpers, reused or adapted, not reinvented), with
two users created in it (dispatcher role sufficient for `:AttachmentsManage`, ops-manager role
sufficient for whatever permission gates task completion — reuse `PLATFORM_ADMIN` for both, per
that sibling spec's own "covers every permission without enumerating names" reasoning, §0,
unless this scenario's own process definition requires distinct roles to route the task
correctly — check `proc-swiftroute-shipment-approval`'s actual assignee rule against whatever
process-definition fixture this suite already seeds, or define a small one inline, at
implementation time; not resolved further here since it is an implementation-time lookup, not a
design decision).

### 8.2 Scenario steps → pipeline steps (from the YAML's own 5 steps, §0)

1. **Step 1** (dispatcher): start the shipment-approval instance (`POST /api/v1/instances` or
   through the SPA's own instance-start UI, whichever this suite's existing precedent for
   starting a process instance uses — check `sim-company-onboarding.pipeline.e2e.spec.ts` or
   similar for the established technique) for 8 packages / Hamburg / 320 EUR / standard cargo;
   capture `instance_id`.
2. **Step 2** (dispatcher): navigate to the instance/task detail page, upload
   `delivery-note-hamburg-signed.pdf` (a minimal real PDF, mirroring the sibling spec's own
   `MINIMAL_PDF_BYTES` fixture, §0) via `AttachmentPanel`; assert it appears in the list
   (`attachment-panel` → row with that `file_name`) — **AC1's "list updates without a full page
   reload"** is asserted here by *not* triggering a navigation between upload and assertion.
3. **Step 3** (dispatcher, EO-002): attempt to upload a small video file (any `video/*`
   `content_type`, e.g. `video/mp4`) — assert a `415`-sourced rejection message naming the
   rejected type is shown (§2's exact backend text, or a substring of it); then attempt to
   upload a file whose size exceeds `Tenant.storage_allowance_bytes` minus the tenant's current
   usage (provisioned deliberately close to the allowance for this test, or the allowance
   lowered for this tenant via a direct DB write — same "no HTTP writer exists, direct
   `Letflow.Repo` write" technique the sibling spec's own `bindTenantIdpRealm`/
   `insertTenantMembershipSql` already establish, §0) — assert a distinct `409`-sourced rejection
   message is shown; assert the attachment list still shows only the one document from step 2
   afterward (EO-002's "nothing half-attached" clause).
4. **AC3 checkpoint**: capture the storage-usage figure (`attachment-storage-usage`) before step
   2, after step 2 (risen), and after step 4's removal below (fallen) — matches EO-003's own
   three-screenshot evidence requirement exactly.
5. **Step 4** (dispatcher): click `Remove` (§4.2's two-click confirm) on the step-2 attachment;
   assert it disappears from the list; upload
   `delivery-note-hamburg-signed-corrected.pdf`; assert it now appears. **AC4 checkpoint**:
   switch to the Timeline tab, assert entries containing `"delivery-note-hamburg-signed.pdf
   attached by <Lena's display name>"` and `"... removed by <Lena's display name>"` are present
   (§6's already-working path, now exercised end-to-end for the first time).
6. **Step 5** (ops manager, logged in as the second user): open the task inbox, select Marco's
   review task for this instance, assert the corrected delivery note is visible/clickable from
   the shipment (reuses §0's confirmed `AttachmentPanel`/viewer wiring, unchanged by this
   requirement), then click `Complete Task` (approve) with `ops_notes` in the form. **AC5
   checkpoint**: after completion, re-open (or stay on) the now-`COMPLETED` task's detail panel
   and assert `task-decision-attachments` shows
   `delivery-note-hamburg-signed-corrected.pdf`.
7. **Cleanup**: per the YAML's own `cleanup.cancel_open_instances: true` — cancel the instance
   if a step failed before reaching completion (matches this suite's existing cleanup
   convention on other pipeline specs; the shipment reaches `COMPLETED` via step 6 on the happy
   path, so normally nothing to cancel).

### 8.3 Evidence

`shot()` calls at minimum: after step 2's upload, after each of step 3's two rejections, before/
after the storage-usage checkpoints, after step 4's remove+re-attach, after step 5's approval —
mirroring EO-001..EO-005's own `evidence:` fields in the YAML almost 1:1.

---

## 9. AC7 — Remove the stale `NOTE (ISS-0526)` in the scenario YAML

Once this requirement and REQ-387/389/390/391 have all shipped (REQ-387/389/390/391 already
have, per §0's `depends_on` confirmation), remove exactly the comment block:

```
# NOTE (ISS-0526): this spec file does not exist in R-Co's own web/ tree at the
# pinned commit either -- it is an aspirational forward-reference to a Playwright
# test that was never authored anywhere, gated on the same missing feature this
# scenario's own steps exercise. UAT-RUNNER cannot drive this pipeline_test yet;
# treat any run of this scenario as BLOCKED/UNBUILT_FEATURE on the frontend leg
# until FRONTEND-DEV authors it against a real shipped feature.
```

from `test/fixtures/uat/scenarios/swiftroute/shipment-attach-delivery-note.yaml`, **keeping**
the `pipeline_test:` line immediately above it and the two `# UAT-RUNNER drives this Playwright
pipeline test...` lines immediately below it unchanged — exact same scope of edit REQ-387 (§0)
already made for the sibling `NOTE (ISS-0527)` in `attachment-cross-tenant-probe.yaml`. This is
the only edit permitted to this file under its own top-of-file "do not edit the ported content
... except to keep it byte-identical" rule (the `NOTE` block is explicitly this scenario's own
carve-out for exactly this future removal, not part of the ported R-Co content).

This edit must land **only after** §8's real spec passes against a running instance (AC6's own
"and passes against a running instance" wording) — do not remove the NOTE and then discover the
spec doesn't actually pass; sequence AC6 before AC7 within the same implementation PR.

---

## 10. Open questions (explicitly not resolved here — flag for REVIEWER/CODE-DESIGN-VALIDATOR)

- **§4.2 in-row confirm vs. modal parity**: this design chooses an in-row two-click confirm over
  reusing `CancelInstanceDialog`'s modal pattern, for the reasons stated there. If
  CODE-DESIGN-VALIDATOR or REVIEWER judges destructive-action UX should be consistent
  platform-wide, a modal (`ConfirmRemoveAttachmentDialog`, mirroring `CancelInstanceDialog`'s
  shape) is the alternative — not designed in detail here since it's a straightforward
  structural swap of §4.2 either way.
- **§8.1's role assignment for the ops-manager task**: whether `proc-swiftroute-shipment-
  approval`'s review-task assignee rule requires a distinct role from the dispatcher (vs.
  `PLATFORM_ADMIN` covering both, as the sibling spec does) is a fixture/process-definition
  lookup left to implementation time, not resolved here.
- **§8.2 step 3's quota-exhaustion fixture technique**: exact mechanism for provisioning a
  tenant "close to its allowance" (lowering `storage_allowance_bytes` via direct `Repo` write
  vs. uploading enough filler content to approach the default 1 GiB) is left to implementation
  time; the direct-DB-write technique is recommended (faster, no large fixture upload needed)
  but not mandated.

---

## 11. Acceptance-criteria → section traceability

| AC | Section |
|---|---|
| 1 (remove action, no full reload) | §4 |
| 2 (distinct rejection messages, content-type + quota) | §2, §3, §8.2 step 3 |
| 3 (storage-usage figure, rises/falls) | §1 (backend gap closed), §5, §8.2 step 4 |
| 4 (timeline attach/remove entries, actor names) | §6, §8.2 step 5 |
| 5 (approval screen names reviewed attachment) | §7, §8.2 step 6 |
| 6 (real e2e spec, passes) | §8 |
| 7 (stale NOTE removed) | §9 |
