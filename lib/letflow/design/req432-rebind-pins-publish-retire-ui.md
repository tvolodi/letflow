# REQ-432 design — publish/retire service-version UI, rebind-pins UI, INSTANCE_PINS_REBOUND history rendering, pipeline spec

Status: design (WF-02 Step 1). Owner of build: FRONTEND-DEV. FRONTEND-ONLY: no file under
`lib/letflow/` changes (REQ-432 OUT OF SCOPE list: `Letflow.ServiceCatalog`, `PinResolver`,
`PinRebind`, REQ-373/REQ-399 routes). Every backend contract below was read from source, with
file references. Any mismatch between backend and the requirement text is in §9 and must be
routed to the backend, never shimmed in `web/`.

Sources read: `lib/letflow/routers/admin_services.ex`, `lib/letflow/routers/instances.ex`,
`lib/letflow/engine/pin_rebind.ex`, `lib/letflow/instances.ex` (timeline),
`lib/letflow/design/req373-service-catalog-version-lifecycle.md` §1/§3/§7/§9,
`web/src/api/{client,services,instances}.ts`, `web/src/hooks/useInstancePins.ts`,
`web/src/components/instances/{InstancePinsPanel,EventHistoryPanel,TimelineFeedItem,EventJsonExpandable}.tsx`,
`web/src/pages/instances/{InstanceDetailPage,timelineUtils}.ts(x)`,
`web/src/pages/admin/services/ServicesPage.tsx`,
`test/fixtures/uat/scenarios/platform/instance-pin-survives-catalog-change.yaml`,
`web/tests/e2e/pipelines/platform-migration-partial-failure-resume.pipeline.e2e.spec.ts`,
`web/tests/guards/forbidlist.ts`.

## §0 Acceptance-criterion map

| AC (handoff task.acceptance_criteria) | Section |
|---|---|
| Every REQ-432 build item maps to a concrete element | Build item 1 (publish/retire client + UI) -> §2, §3; item 2 (rebind client + dialog) -> §4, §5; item 3 (history rendering) -> §6; item 4 (pipeline spec) -> §7; unit/component tests -> §8 |
| Client signatures/request/response/error shapes copied from real backend with file refs | §2.1, §2.2, §4.1, §4.2 (each table cites file and function) |
| INSTANCE_PINS_REBOUND history question answered with file evidence | §6 (finding F1-F4 with file/line evidence) |
| Open questions explicit, listed in §10, signatures only | §10; this document contains type/prop signatures only |
| Design committed and pushed | Handoff git_evidence |

## §1 Conventions that apply (web/)

- HTTP only through `client` in `web/src/api/client.ts` (guard `raw-fetch-outside-client`, CMP-UI-02). `client` already prepends `VITE_API_BASE_URL` (`BASE_URL`), so paths passed are `/api/v1/...` literals exactly like `servicesApi` and `instancesApi` do; no hardcoded host.
- No colour literals (guard `literal-colour`): use `var(--...)` tokens only, as existing modals do.
- No MSW / axios-mock-adapter (guards `msw-import`, `http-mock-adapter`, DIRECTIVE T-2). Unit tests mock the `@/api/*` module with `vi.mock` (precedent: `InstancePinsPanel.test.tsx`). Pipeline e2e uses the real backend; no `page.route` (0 hits in both sibling specs read).
- Query keys only via `useTenantScopedQueryKeys()`; `instances.pins(id)`, `instances.detail(id)`, `instances.events`, `instances.timeline`, `instances.all()`, `admin.services()` already exist (`web/src/api/useTenantScopedQueryKeys.ts`). No new query-key factory is needed.
- Strings: the existing `ServicesPage`/`InstancePinsPanel` use inline English literals; `web/src/i18n/` holds only entities messages and date formatting (`formatDateTime`). New strings stay inline English; dates via `formatDateTime`. (OQ-7 records the decision.)
- Permission gating in UI is cosmetic; backend is authoritative. Existing idiom: role arrays from `useAuth().session.roles` (`ServicesPage`: `session.roles.includes('PLATFORM_ADMIN')`; `InstanceDetailPage.tsx:31` `CANCEL_ROLES = ['PROCESS_OPERATOR','PROCESS_ADMIN','PLATFORM_ADMIN']`, used at `:129`). No permission-atom hook exists in `web/`; none is invented.
- Styling/markup for modals: copy the inline fixed-overlay modal pattern already in `ServicesPage.tsx` (overlay + card + `Button` from `@/components/ui/Button`). No new design-system component.

## §2 Service-version client (`web/src/api/services.ts`)

### §2.1 Wire contract (source: `lib/letflow/routers/admin_services.ex`, `handle_publish/2`, `handle_retire/2`, `service_record_json/1`; req373 design §7)

Both routes are declared `authz_post ..., :AdminServicesManage`; that key maps to `:UsersGroupsRolesManage`, held only by `PLATFORM_ADMIN` (moduledoc "Authorization"). Non-`PLATFORM_ADMIN` -> 403 before handler.

| | publish | retire |
|---|---|---|
| Method/path | `POST /api/v1/admin/services/:service_id/versions` | `POST /api/v1/admin/services/:service_id/retire` |
| Request body | JSON object. `version` REQUIRED non-empty string. Optional keys read: `endpoint_url`, `request_schema`, `response_schema`, `auth_method` (mapped to `required_auth`), `timeout_ms`, `retry_policy`. Unknown keys ignored. Per req373 §3.1 `publish_attrs`, `endpoint_url` and `timeout_ms` are required at the changeset level (missing -> 422). | none (handler reads no body) |
| Success | `201` + service record (below) | `200` + service record (below) |
| 400 | body not a JSON object ("request body must be a JSON object"); `version` missing/empty ("version is required") | n/a |
| 404 | `service_id` does not exist (`Response.not_found`) | same |
| 409 | `:duplicate_version` -> "version already exists for this service_id" | `:already_retired` -> "service_id is already retired" |
| 422 | changeset failure -> "validation failed" | n/a |
| 401/403/429 | generic (`client.ts` `throwOnErrorResponse`) | same |

Service record response (`service_record_json/1`): `service_id`, `endpoint_url`, `request_schema`, `response_schema`, `required_auth` (string, atom rendered), `timeout_ms`, `scope`, `owner_tenant_id`, `version`, `version_id`, `status` (`"ACTIVE"` or `"RETIRED"` per `Atom.to_string` of the `:ACTIVE`/`:RETIRED` atoms), `published_at` (ISO-8601), `retired_at` (ISO-8601 or null), `created_at`, `updated_at`. NOTE: there is no `max_retries` and no `retry_policy` key in the response (see §9 M2).

### §2.2 Type and function signatures (added to `services.ts`; existing exports unchanged except the additive `ServiceRecord` fields)

- `ServiceVersionStatus` = string union `'ACTIVE' | 'RETIRED'`.
- `ServiceRecord` gains: `version: string`, `version_id: string`, `status: ServiceVersionStatus`, `published_at: string`, `retired_at: string | null`. `max_retries` stays declared (existing; see §9 M2). These are additive, so `listForTenant` consumers are unaffected; `Routers.Services` (non-admin) emits its own projection, so the new fields are optional-tolerant at render (see §3: render "—" when undefined).
- `PublishServiceVersionBody`: `version: string` (required), `endpoint_url: string` (required), `timeout_ms: number` (required), `auth_method?: string`, `request_schema?: string`, `response_schema?: string`, `retry_policy?: string`. Field names are the wire names (`auth_method`, not `required_auth`), mirroring `RegisterServiceBody`'s existing asymmetry.
- `servicesApi.publishVersion(serviceId: string, body: PublishServiceVersionBody): Promise<ServiceRecord>` -> `client.post('/api/v1/admin/services/${serviceId}/versions', body)`.
- `servicesApi.retire(serviceId: string): Promise<ServiceRecord>` -> `client.post('/api/v1/admin/services/${serviceId}/retire')` (no body argument: `client.post` accepts `body?`; `JSON.stringify(undefined)` yields no body, matching `cancel`-style calls).
- `serviceId` is interpolated exactly as the existing `updateScope`/`delete` do (no `encodeURIComponent` divergence; OQ-8 notes the existing convention).

### §2.3 Error shapes at the client

`client` throws `ApiError` (`@/types/api`): `status`, `message` (problem `title` or `message`, else statusText), `code`, `details`. 409 is special-cased in `throwOnErrorResponse` (`details` contains the parsed body plus `xResourceVersion`). UI branches on `err.status` only (404/409/422/400/other), never on message text; user-facing strings are fixed per status in §3.3.

## §3 ServicesPage controls (`web/src/pages/admin/services/ServicesPage.tsx`)

### §3.1 Gating
Controls render only when the existing `isPlatformAdmin` boolean is true (same gate as Register/Edit scope/Delete). Matches the backend gate exactly (`:AdminServicesManage` = PLATFORM_ADMIN only).

### §3.2 New columns and actions
- Two read-only columns for all viewers: `Version` (`row.version`, monospace) and `Status` (`row.status`); both render "—" when the field is undefined (tolerates the tenant-scoped list).
- In the existing admin Actions cell add two `Button`s (size `sm`): `Publish version` (variant `secondary`) -> opens the publish modal for that row; `Retire` (variant `danger`) -> opens the retire confirmation modal. `Retire` is disabled (not hidden) when `row.status === 'RETIRED'`, mirroring the backend 409.
- Test ids (for unit and pipeline specs): `service-publish-btn-{service_id}`, `service-retire-btn-{service_id}`, `service-publish-modal`, `service-publish-version-input`, `service-publish-endpoint-input`, `service-publish-timeout-input`, `service-publish-auth-select`, `service-publish-request-schema-input`, `service-publish-response-schema-input`, `service-publish-retry-policy-input`, `service-publish-submit`, `service-publish-error`, `service-retire-modal`, `service-retire-confirm`, `service-retire-error`, and row cells `service-version-{service_id}`, `service-status-{service_id}`.

### §3.3 Publish modal
Local state additions: `publishTarget: ServiceRecord | null`. Form fields (uncontrolled `FormData`, same pattern as the register modal): `version` (text, required), `endpoint_url` (text, required, prefilled from the row), `timeout_ms` (number, required, `min=0`, prefilled), `auth_method` (select NONE/API_KEY/OAUTH2/MUTUAL_TLS, prefilled from `row.required_auth`), `request_schema`, `response_schema` (textareas, prefilled), `retry_policy` (text, optional, empty = omit key). Empty optional strings are omitted from the body (backend `maybe_put` passes present keys as-is). Mutation `publishMutation = useMutation(servicesApi.publishVersion)`; `onSuccess`: `invalidateQueries({ queryKey: tenantKeys.admin.services() })` (same key as `listQueryKey`), close modal. Error text by `err.status`: 409 "That version already exists for this service.", 404 "Service not found.", 422 or 400 "The version details are invalid.", else "Failed to publish version." shown in `service-publish-error` with `role="alert"`.

### §3.4 Retire modal
`retireTarget: string | null`. Confirmation copy states the exact backend semantics from req373 §3.2: retiring stops NEW cases from resolving this service until a new version is published; cases already running keep the version they started with. `retireMutation = useMutation(servicesApi.retire)`; `onSuccess` invalidates `tenantKeys.admin.services()` and closes. Error text: 409 "This service is already retired.", 404 "Service not found.", else "Failed to retire service."

## §4 Rebind client (`web/src/api/instances.ts`)

### §4.1 Wire contract (source: `lib/letflow/routers/instances.ex` `@rebind_schema`, `handle_rebind_pins/2`, `render_rebind/2`, `rebind_result_map/1`, `changed_entry_map/1`, `normalise_entries/1`, `idempotency_key/1`; `lib/letflow/engine/pin_rebind.ex` types)

- `POST /api/v1/instances/:id/rebind-pins`.
- Gate: `authz_post "/:id/rebind-pins", :InstancesCancel` (`instances.ex:338`). `:InstancesCancel` is held by `PROCESS_OPERATOR` and `PLATFORM_ADMIN` (`authorization.ex` `core_role_allows?`), the same permission `POST /:id/cancel` requires. The moduledoc paragraph saying the route is "not permission-gated" predates REQ-131 and is stale (route code is authoritative); recorded in §9 M3.
- Request body (JSON object): `reason: string` REQUIRED, non-empty, 1..1024 chars (`@rebind_schema`); `entries: array` REQUIRED, min 1 item; each item exactly `{ kind, ref, version }` where `kind` in `@pin_kinds` (`'catalog_entry' | 'variable_schema' | 'module'`, `EffectivePinKind`), `ref: string`, `version: string`; any other shape -> 422 "request body failed validation".
- Header: `Idempotency-Key` (optional). Backend reads the `idempotency-key` header, truncates to 255 bytes, and generates a UUID itself when absent (`idempotency_key/1`). Not a body field. `rebind_attrs()` requires a key at the engine layer, which the route always satisfies.
- `actor_id` comes from the auth context, never from the body.
- 200 body: `{ instance_id: string, changes: [{ kind, ref, prior_version, new_version }], rebound_at: string (ISO-8601) }`. `changes` may be `[]` (entry already at the requested version: no change, event still appended per pin_rebind design OQ-3).
- Errors: 400 body not a JSON object; 404 instance absent or cross-tenant (same response, INV-5); 409 "instance is in a terminal state and cannot be rebound"; 409 "instance is locked by another transaction"; 422 "instance_id is not a valid UUID"; 422 "a requested entry is not present in the instance's current effective pin set"; 422 "request body failed validation"; 422 field-error problem document from `Validation.problem` for `reason`/`entries` schema failures; 500 no detail; 401/403/429 generic.

### §4.2 Signatures
- `RebindPinEntry`: `{ kind: EffectivePinKind; ref: string; version: string }`.
- `RebindPinsRequest`: `{ reason: string; entries: RebindPinEntry[] }`.
- `RebindPinChange`: `{ kind: EffectivePinKind; ref: string; prior_version: string; new_version: string }`.
- `RebindPinsResponse`: `{ instance_id: string; changes: RebindPinChange[]; rebound_at: string }`.
- All four added to `web/src/types/api.ts` next to `EffectivePin`/`InstancePinsResponse` (REQ-399's types live there).
- `instancesApi.rebindPins(id: string, body: RebindPinsRequest, idempotencyKey: string): Promise<RebindPinsResponse>` -> `client.postWithHeaders('/api/v1/instances/${id}/rebind-pins', body, { 'Idempotency-Key': idempotencyKey })`. `postWithHeaders` already exists in `client.ts` (precedent `web/src/api/onboarding.ts:117`, per-call key injected by caller, not globally). The key argument is required (not optional) so the caller must decide its lifetime (§5.3).

### §4.3 Hook (`web/src/hooks/useRebindPins.ts`, new file)
`useRebindPins(instanceId: string)` returns a TanStack `useMutation` whose variables are `{ body: RebindPinsRequest; idempotencyKey: string }` and whose data is `RebindPinsResponse`. `onSuccess` invalidates, using `useTenantScopedQueryKeys().instances`: `pins(instanceId)` (AC: pins query refetched so the list shows the new version with source `rebound`), `detail(instanceId)`, and the events and timeline query prefixes for the instance so the new `INSTANCE_PINS_REBOUND` row appears (FRONTEND-DEV: if `events`/`timeline` key factories take extra filter/cursor args, invalidate by the shared prefix, as `useCancelInstance` invalidates `instances.all()`; do not construct keys by hand). No optimistic update (server decides `changes`).

## §5 Rebind dialog on `InstancePinsPanel.tsx`

### §5.1 Props and gating
`InstancePinsPanelProps` gains `canRebind?: boolean` (default false) and `instanceActive?: boolean` (default false). `InstanceDetailPage.tsx` passes `canRebind={canCancel}` (existing `CANCEL_ROLES` boolean, line 129; same role set as the backend `:InstancesCancel` holders) and `instanceActive={instance.status === 'ACTIVE'}` (mirrors the cancel button condition at line 240 and the backend 409 for terminal instances). The panel itself does not read `useAuth`, keeping the REQ-399 test mock surface unchanged. Existing callers/tests that omit the props get the unchanged read-only panel (REQ-399 behaviour preserved).

### §5.2 Table change
When `canRebind && instanceActive`, `columns` gains an `Actions` column with one `Button` (`variant="secondary"`, `size="sm"`) per row, label `Rebind`, test id `pin-rebind-btn-{kind}:{ref}` (same key as `PinRow.key`). Shown for all three kinds (the backend accepts all three; OQ-2 records the choice). Nothing else in the read-only display changes (REQ-399 out-of-scope fence).

### §5.3 Dialog
State: `rebindTarget: EffectivePin | null`, `newVersion: string`, `reason: string`, `idempotencyKey: string`. Opening the dialog generates a fresh `idempotencyKey` (one per dialog open); retries of a failed submit from the same open dialog reuse it; closing and reopening generates a new one. Fields: read-only `Dependency` (`pin.ref`) and `Current version` (`pin.version`); `New version` text input (required, trimmed non-empty, must differ from `pin.version` or submit disabled with hint "Choose a different version"); `Reason` textarea (required, trimmed non-empty, max 1024 chars with live counter; submit disabled until valid). Submit calls `useRebindPins(instanceId).mutate({ body: { reason, entries: [{ kind: pin.kind, ref: pin.ref, version: newVersion }] }, idempotencyKey })`. Test ids: `pin-rebind-dialog`, `pin-rebind-new-version-input`, `pin-rebind-reason-input`, `pin-rebind-submit`, `pin-rebind-cancel`, `pin-rebind-error`, `pin-rebind-success`.

Success: dialog closes; the panel shows a `role="status"` line (`pin-rebind-success`) "Moved {ref} from {prior_version} to {new_version}" using `response.changes[0]`, or "No change: already on that version" when `changes` is empty. Error text by `err.status`: 404 "Case not found."; 409 "This case can no longer be rebound (finished, or being modified by someone else). Refresh and try again."; 422 "That version is not valid for this dependency, or the reason is missing."; 403 "You do not have permission to rebind this case."; else "Failed to rebind dependency." in `pin-rebind-error`, `role="alert"`, dialog stays open.

## §6 INSTANCE_PINS_REBOUND history rendering — decided by reading (REQ-432 build item 3)

Evidence:

- F1 Event payload content: `lib/letflow/engine/pin_rebind.ex:460-466` encodes payload `{ entries: [{kind, ref, prior_version, new_version}], actor: <actor_id uuid>, reason }`; event `actor_id` is also set (`:470-474`).
- F2 Timeline tab does NOT show versions or reason: `TimelineFeedItem.tsx` renders `entry.description`, event type, `actor_display_name`, `getTimelineSecondaryContext` (node_id/task_id only, `timelineUtils.ts:9-21`) and `entry.metadata` in a collapsed details. Backend `timeline_item/2` (`lib/letflow/instances.ex:320-335`) sets `metadata: event.metadata` (NOT the payload) and `render_description/3` for this event type returns exactly "Instance pins rebound by #{actor}" (`instances.ex:278-280`), ignoring payload. So the timeline shows the operator's display name and that a rebind happened, but not prior_version, new_version or reason. Generic rendering does not meet EO-005 on this tab.
- F3 History tab carries the data but hides it: `EventHistoryPanel.tsx` renders every event generically with a collapsed `EventJsonExpandable` (raw JSON in `<details>`), so reason and prior/new versions exist only as raw JSON behind a click, and the `actor` inside the payload is a UUID, not a name.
- F4 History tab actor column is broken for every event: backend `history_item_map/1` (`lib/letflow/routers/instances.ex:903-910`) emits only `event_id, event_type, sequence_number, created_at, payload` — no `actor_id` — while `EventRecord` (`web/src/types/api.ts:170-181`) declares `actor_id` and `EventHistoryPanel.tsx` falls back to the literal "system" when absent. So the Actor cell shows "system" for a rebind done by a named operator. Contract mismatch, recorded §9 M1; routed to backend, not shimmed.

Decision: a dedicated case is required (generic rendering is insufficient).

Design (minimal, frontend-only):
- New component `web/src/components/instances/PinsReboundSummary.tsx`. Props: `{ payload: Record<string, unknown>; actorLabel?: string }`. Renders, from `payload.entries` (defensively parsed; malformed -> falls back to the existing `EventJsonExpandable`), one line per entry: `{ref}: {prior_version} -> {new_version}` (kind shown as a muted suffix), and `Reason: {payload.reason}`, and `Changed by: {actorLabel ?? payload.actor}`. An empty `entries` array renders "No version changed".
- `EventHistoryPanel.tsx`: in the Payload cell, when `event.event_type === 'INSTANCE_PINS_REBOUND'` render `PinsReboundSummary` above the existing `EventJsonExpandable` (raw JSON kept for audit, nothing removed). Test ids: `pins-rebound-summary`, `pins-rebound-entry-{ref}` (containing prior and new versions), `pins-rebound-reason`, `pins-rebound-actor`.
- Operator name: `EventHistoryPanel` does not have a display name (F4). The Timeline tab already shows the operator display name in the row description ("Instance pins rebound by {name}", F2). Design decision: `actorLabel` is left undefined by `EventHistoryPanel` in this requirement, so the History tab shows the payload's actor UUID; EO-005's "operator's name" is evidenced by the Timeline tab row (name) plus the History tab summary (versions, reason, actor id). If the product owner wants all three on one tab, that needs a backend change (OQ-1 / §9 M1), not a frontend join.
- `TimelineFeedItem.tsx`/`timelineUtils.ts`: no change (the timeline response has no payload to render; F2).

## §7 Pipeline spec `web/tests/e2e/pipelines/platform-instance-pin-survives-catalog-change.pipeline.e2e.spec.ts`

Conventions (from `platform-migration-partial-failure-resume` and `platform-definition-type-error-blocked`): imports `createPipeline`, `getKeycloakToken`, `loginWithToken`, `navigateSpa`, `resolveTenantContext`, `shot` from `../pipeline`; `assertServiceReadiness`, `resolveCredential` from `../helpers`; `typeIntoTestIdInput` from `../type-into-input`; `test.setTimeout(300_000)`; `API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'`; admin login via Keycloak password grant for `admin-user` (`UAT_QA_ADMIN_PASSWORD`, default `admin-pass`) then `loginWithToken`; real backend, NO `page.route`; `pl.step(...)`, `pl.gate(...)`, `pl.onCleanup(...)`, `pl.runCleanup()`; `s.` typed state interface. API-side setup/system steps use the `request` fixture with `authHeaders(token)`; GUI steps use testids.

State interface `PinSurvivesState`: `adminToken`, `serviceId`, `oldVersion`, `newVersion`, `definitionId`, `longCaseId`, `newCaseId`, `rebindReason`.

Steps and assertion mapping:

| Step | Scenario step | What it does | Asserts | Covers |
|---|---|---|---|---|
| pre | preconditions 1-2 | register a fresh service via `POST /api/v1/admin/services` (unique id `pl_pin_{fixtureId}`, version "1"), create/activate a process definition referencing it (mechanism = OQ-4), choose unique `newVersion` string | gate: ids captured | preconditions |
| 01 | step 1 (gui) | start case A (long-running) via the instances API or GUI and leave it before the service step; open its detail page | Dependency Versions panel lists `{serviceId}` with version "1" | EO-003 (panel content), EO-001 baseline "before" capture |
| 02 | step 2 (gui) | on `/admin/services` click `service-retire-btn-{serviceId}` then confirm, then `service-publish-btn-{serviceId}`, fill `service-publish-version-input` with `newVersion`, submit | row `service-version-{serviceId}` shows `newVersion`, `service-status-{serviceId}` shows ACTIVE | scenario step 2; REQ-432 build item 1 |
| 03 | step 3 (system) | let case A reach the service step (complete the preceding task via API) | case A completes the step without error; its pins panel still shows version "1" (pin unchanged) | EO-001, EO-004 |
| 04 | step 4 (gui) | start case B; open A and B detail pages | B's panel shows `newVersion`; A's shows "1"; both list a source column value | EO-002, EO-003, EO-004 (retire did not break A's pin display) |
| 05 | step 5 (gui) | on A's detail click `pin-rebind-btn-catalog_entry:{serviceId}`, enter `newVersion` and the scenario reason "External system retires the old endpoint at month end.", submit | `pin-rebind-success` visible; pins panel (refetched) shows `newVersion` with source "Changed via rebind" | REQ-432 build item 2 |
| 06 | EO-005 | on A's History tab find the `INSTANCE_PINS_REBOUND` row; on the Timeline tab find the matching row | `pins-rebound-entry-{serviceId}` contains "1" and `newVersion`; `pins-rebound-reason` contains the reason; `pins-rebound-actor` non-empty; Timeline row text contains "Instance pins rebound by" and the admin display name | EO-005 |
| 07 | (negative) | log in as `worker-user` (TASK_WORKER) | `/admin/services` exposes no `service-publish-btn-*`/`service-retire-btn-*`; a case detail shows no `pin-rebind-btn-*` | permission gating (§1) |
| cleanup | cleanup | cancel cases A and B via API; leave the published version (per the scenario's `cleanup.description`) | | cleanup |

Scenario-yaml update: precedent exists (`definition-promotion-approved.yaml`, `definition-promotion-rollback.yaml` replaced the stale "ISS-0527" NOTE with an "ISS-0527 resolved {date}: the spec above now exists..." comment block). Once the spec exists, replace the `# NOTE (ISS-0527)` block (lines 29-35 of `instance-pin-survives-catalog-change.yaml`) with a resolved comment in that style, leaving the `pipeline_test:` line and all ported content byte-identical (file header forbids editing ported content otherwise). Do not touch `pipeline_test:`.

## §8 Frontend unit/component tests (Vitest + Testing Library, `vi.mock('@/api/...')` pattern)

| Test file (new unless noted) | Cases | Maps to |
|---|---|---|
| `web/src/api/__tests__/services.versions.test.ts` | `publishVersion` POSTs to the exact path with the body; `retire` POSTs to exact path with no body (mock `client`) | item 1 client signatures |
| `web/src/pages/admin/services/__tests__/ServicesPage.versions.test.tsx` | admin sees publish/retire buttons; non-admin does not; publish submit calls `publishVersion(serviceId, body)` with `version` and prefilled fields; 409 shows the duplicate-version message; retire confirm calls `retire(serviceId)`; Retire disabled on a RETIRED row; list invalidated after success | item 1 UI, §3 |
| `web/src/api/__tests__/instances.rebind.test.ts` | `rebindPins` POSTs `/api/v1/instances/{id}/rebind-pins` with body and `Idempotency-Key` header | item 2 client |
| extend `web/src/components/instances/__tests__/InstancePinsPanel.test.tsx` (mock gains `rebindPins`) | no Rebind button without `canRebind`; none when `instanceActive` false; dialog blocks submit on empty reason and on unchanged version; submit calls `rebindPins(id, {reason, entries:[{kind,ref,version}]}, key)`; success refetches `getPins` (second call returns the new version) and shows success line; 409/422/404 error texts; reopening the dialog uses a new key while retry reuses the key | item 2 UI, §5 |
| `web/src/components/instances/__tests__/PinsReboundSummary.test.tsx` | renders prior -> new, reason, actor for a realistic payload; empty `entries`; malformed payload falls back without throwing | item 3, EO-005 |
| extend the `EventHistoryPanel` test (existing file if present, else new) | an `INSTANCE_PINS_REBOUND` event renders the summary above the JSON; other event types render unchanged | item 3 |
| Two-case distinct pins (EO-001/EO-002) | `InstancePinsPanel` rendered for two instance ids with `getPins` returning different versions shows each case's own version (component-level proof that the panel reads per-instance data) | EO-001, EO-002 |
| Retire does not break running case's pin display (EO-004) | panel test where `getPins` still returns the old version for the running case after the services page retired it (services and pins data are independent queries) | EO-004 |

## §9 Backend/requirement mismatches found (route to backend; do NOT shim in web/)

- M1 (history actor): `history_item_map/1` (`lib/letflow/routers/instances.ex:903-910`) omits `actor_id`; `EventRecord.actor_id` is declared in the web types and the History tab shows "system" for every event. Also no display-name is offered on the History tab. Backend follow-on: emit `actor_id` (and optionally `actor_display_name`) on history items. REQ-432 does not block on it (§6 decision).
- M2 (service record): `service_record_json/1` (`admin_services.ex` bottom) emits no `max_retries` and no `retry_policy`, while `ServiceRecord.max_retries` is declared in `web/src/api/services.ts` and `ServicesPage` renders a "Retries" column from it (renders blank). Pre-existing; publish accepts `retry_policy` but the response never echoes it. Not fixed here; backend/req-analyst decision.
- M3 (stale moduledoc): `instances.ex` moduledoc says rebind-pins is "not permission-gated"; the route declares `:InstancesCancel` (`instances.ex:338`). UI gating follows the route code (PROCESS_OPERATOR/PLATFORM_ADMIN). Doc-only backend cleanup.
- M4 (scenario step 2 vs real retire semantics): req373 §3.2 shows `retire/1` retires the single current row and accepts no version argument; req373 §3.1 shows `publish/3` archives the current row (stamping `retired_at`) when superseding. The scenario's step 2 "publishes the newer version AND retires the version the running case is using" therefore cannot be done in that order through the UI: calling retire AFTER publish would retire the NEW version and make new cases unresolvable (EO-002 fail). The spec in §7 therefore retires first, then publishes (the old row is archived as retired, the new one is ACTIVE). Requirement text item (1) ("a retire action") is satisfied; the requirement does not assume a per-version retire. No backend change needed unless the product wants per-version retire (OQ-3).

## §10 Open questions (explicit; every AC-mapped element above is fully specified)

- OQ-1: EO-005 says the history shows "the operator's name". Decision taken in §6: name shown on the Timeline tab row, actor id on the History tab summary. Confirm with REQ owner whether one-tab display is required; if yes it needs backend M1 (display name on history items or payload-derived fields on timeline items).
- OQ-2: Rebind action is offered for all three pin kinds (backend accepts all). Confirm it should not be limited to `catalog_entry` (the only kind the scenario exercises; `module` has no version lifecycle per the REQ-373 scope gap).
- OQ-3: The dialog rebinds one entry per submission. Multi-entry rebind in one call is supported by the backend; confirm single-entry is acceptable for this requirement.
- OQ-4: How the pipeline spec obtains a live process definition with a `catalog_entry` pin (preconditions 1-2): whether an existing UAT fixture definition/seed referencing a registrable service exists, or the spec must create and activate one through the definitions API. TEST-DESIGNER/FRONTEND-DEV must resolve by reading the definitions routes and `../db-exec.ts`/sibling specs at build time and report which mechanism; this design does not prescribe it.
- OQ-5: Backend behaviour on a replayed `Idempotency-Key` for rebind (same key, second call): the router delegates to `EventStore.append` with the key; response on replay was not verified by this design. UI only reuses a key within one dialog open and treats any non-2xx as an error; confirm replay semantics (200 with the same body vs 409) before asserting it in a test.
- OQ-6: Whether the new-version field should offer suggestions. Operators (PROCESS_OPERATOR) cannot call `/admin/services`, so the dialog uses free text. Confirm free text is acceptable.
- OQ-7: No i18n catalogue is used for these screens (existing neighbours use inline English); confirm this stays consistent.
- OQ-8: `serviceId`/`id` are interpolated unencoded in URLs as existing `servicesApi`/`instancesApi` functions do; service ids are identifier-like, instance ids UUIDs. Confirm no encoding is wanted.
- OQ-9: Case-history evidence for EO-001/EO-004 "the history entry for the step performed at step 3": the service-task outcome event type is not asserted here; the spec asserts step completion through the case status/pins panel. Confirm whether a specific event type must be asserted.

## §11 Invariants

- No file under `lib/letflow/` is modified; `mix letflow.check` backend gates are unaffected.
- Only `client` performs HTTP; no hardcoded base URL; no colour literals.
- Existing exports in `services.ts` and `instances.ts` keep their signatures; `InstancePinsPanel` without the new props behaves exactly as REQ-399 shipped.
- Gating is UI convenience; 403 from the backend is authoritative and surfaces as an error message.
