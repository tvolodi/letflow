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
| Open questions explicit, listed in §10, signatures only | §10 (no open question defers an AC-mapped element); this document contains type/prop signatures only |
| EO-005: one view shows operator name, prior version, new version, reason | §6 (single History-tab view, actor resolved from the timeline query by `event_id`); pipeline step 06 (§7) asserts all four on that one view |
| EO-001/EO-004 in-flight step covered in the pipeline spec | §7 (definition mechanism, service-step execution, exact history event types); §9 M5 states precisely what the real backend can and cannot do at the service step |
| Exact cache invalidation, no conditional instruction | §4.3 (`instances.all()` prefix) |
| Design committed and pushed | Handoff git_evidence |

## §1 Conventions that apply (web/)

- HTTP only through `client` in `web/src/api/client.ts` (guard `raw-fetch-outside-client`, CMP-UI-02). `client` already prepends `VITE_API_BASE_URL` (`BASE_URL`), so paths passed are `/api/v1/...` literals exactly like `servicesApi` and `instancesApi` do; no hardcoded host.
- No colour literals (guard `literal-colour`): use `var(--...)` tokens only, as existing modals do.
- No MSW / axios-mock-adapter (guards `msw-import`, `http-mock-adapter`, DIRECTIVE T-2). Unit tests mock the `@/api/*` module with `vi.mock` (precedent: `InstancePinsPanel.test.tsx`). Pipeline e2e uses the real backend; no `page.route` (0 hits in both sibling specs read).
- Query keys only via `useTenantScopedQueryKeys()`; `instances.pins(id)`, `instances.detail(id)`, `instances.events`, `instances.timeline`, `instances.all()`, `admin.services()` already exist (`web/src/api/useTenantScopedQueryKeys.ts`). This requirement adds NO new query-key factory and does not modify `queryKeys.ts`/`useTenantScopedQueryKeys.ts`; cache invalidation uses the existing prefix-only `instances.all()` (§4.3), because `instances.events(...)` and `instances.timeline(...)` take extra filter/cursor/page-size arguments (`web/src/api/queryKeys.ts:97-100`) and the tenant-scoped wrapper exposes no prefix-only form for them.
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
- `instancesApi.rebindPins(id: string, body: RebindPinsRequest, idempotencyKey: string): Promise<RebindPinsResponse>` -> `client.postWithHeaders('/api/v1/instances/${id}/rebind-pins', body, { 'Idempotency-Key': idempotencyKey })`. `postWithHeaders` already exists in `client.ts` (precedent `web/src/api/onboarding.ts:114`, per-call key injected by caller, not globally). The key argument is required (not optional) so the caller must decide its lifetime (§5.3).

### §4.3 Hook (`web/src/hooks/useRebindPins.ts`, new file)
`useRebindPins(instanceId: string)` returns a TanStack `useMutation` whose variables are `{ body: RebindPinsRequest; idempotencyKey: string }` and whose data is `RebindPinsResponse`. `onSuccess` calls exactly ONE invalidation: `queryClient.invalidateQueries({ queryKey: useTenantScopedQueryKeys().instances.all() })` — the same prefix invalidation `useCancelInstance` performs (`web/src/hooks/useInstances.ts:95`). That prefix is `['tenant', tenantId, 'instances']` (`queryKeys.ts:87`) and is a strict prefix of every key this feature must refresh: `instances.pins(id)` (pins panel shows the new version with source `rebound`), `instances.detail(id)`, `instances.events(id, filters)` (History tab gets the new `INSTANCE_PINS_REBOUND` row), and `instances.timeline(id, cursor, pageSize)` (including the actor-name query of §6.2, which uses this same factory). Nothing else is invalidated and no key is built by hand. No optimistic update (the server decides `changes`). Test obligation (§8): the hook test asserts `invalidateQueries` is called with `{ queryKey: ['tenant', <tenantId>, 'instances'] }`.

## §5 Rebind dialog on `InstancePinsPanel.tsx`

### §5.1 Props and gating
`InstancePinsPanelProps` gains `canRebind?: boolean` (default false) and `instanceActive?: boolean` (default false). `InstanceDetailPage.tsx` passes `canRebind={canCancel}` (existing `CANCEL_ROLES` boolean, line 129; same role set as the backend `:InstancesCancel` holders) and `instanceActive={instance.status === 'ACTIVE'}` (mirrors the cancel button condition at line 240 and the backend 409 for terminal instances). The panel itself does not read `useAuth`, keeping the REQ-399 test mock surface unchanged. Existing callers/tests that omit the props get the unchanged read-only panel (REQ-399 behaviour preserved).

### §5.2 Table change
When `canRebind && instanceActive`, `columns` gains an `Actions` column with one `Button` (`variant="secondary"`, `size="sm"`) per row, label `Rebind`, test id `pin-rebind-btn-{kind}:{ref}` (same key as `PinRow.key`). Shown for all three kinds (the backend accepts all three; OQ-2 records the choice). Nothing else in the read-only display changes (REQ-399 out-of-scope fence).

### §5.3 Dialog
State: `rebindTarget: EffectivePin | null`, `newVersion: string`, `reason: string`, `idempotencyKey: string`. Opening the dialog generates a fresh `idempotencyKey` (one per dialog open, a UUID); closing and reopening generates a new one. A retry of a failed submit from the same open dialog reuses the key. Verified backend behaviour this relies on (and nothing more): the route passes the key to `EventStore.append/2`, which on an already-claimed key returns the ORIGINAL event with `is_duplicate: true` and changes no rows (`lib/letflow/event_store.ex:210-212`, `claim_idempotency`/`resolve_duplicate` at `:649-690`). So a retry after a lost response cannot append a second `INSTANCE_PINS_REBOUND` event. The exact HTTP body of a replayed call is NOT asserted anywhere in this design: the UI treats any 2xx as success and renders from `response.changes` (an empty `changes` renders the "No change" line, below), and treats any non-2xx as an error. Fields: read-only `Dependency` (`pin.ref`) and `Current version` (`pin.version`); `New version` text input (required, trimmed non-empty, must differ from `pin.version` or submit disabled with hint "Choose a different version"); `Reason` textarea (required, trimmed non-empty, max 1024 chars with live counter; submit disabled until valid). Submit calls `useRebindPins(instanceId).mutate({ body: { reason, entries: [{ kind: pin.kind, ref: pin.ref, version: newVersion }] }, idempotencyKey })`. Test ids: `pin-rebind-dialog`, `pin-rebind-new-version-input`, `pin-rebind-reason-input`, `pin-rebind-submit`, `pin-rebind-cancel`, `pin-rebind-error`, `pin-rebind-success`.

Success: dialog closes; the panel shows a `role="status"` line (`pin-rebind-success`) "Moved {ref} from {prior_version} to {new_version}" using `response.changes[0]`, or "No change: already on that version" when `changes` is empty. Error text by `err.status`: 404 "Case not found."; 409 "This case can no longer be rebound (finished, or being modified by someone else). Refresh and try again."; 422 "That version is not valid for this dependency, or the reason is missing."; 403 "You do not have permission to rebind this case."; else "Failed to rebind dependency." in `pin-rebind-error`, `role="alert"`, dialog stays open.

## §6 INSTANCE_PINS_REBOUND history rendering — decided by reading (REQ-432 build item 3)

### §6.1 Evidence

- F1 Event payload content: `lib/letflow/engine/pin_rebind.ex:460-466` encodes payload `{ entries: [{kind, ref, prior_version, new_version}], actor: <actor_id uuid>, reason }`; event `actor_id` is also set (`:470-474`).
- F2 Timeline tab does NOT show versions or reason: `TimelineFeedItem.tsx` renders `entry.description`, event type, `actor_display_name`, `getTimelineSecondaryContext` (node_id/task_id only, `timelineUtils.ts:9-21`) and `entry.metadata`. Backend `timeline_item/2` (`lib/letflow/instances.ex:320-335`) sets `metadata: event.metadata` (NOT the payload) and `render_description/3` for this event type returns exactly "Instance pins rebound by #{actor}" (`instances.ex:278-280`). The timeline feed DOES carry, per entry, `event_id` and `actor_display_name` (`TimelineEntry`, `web/src/types/api.ts:183-194`; `actor_display_name` is resolved server-side from the user table by `resolve_actor_display_name/3`, `instances.ex:225-245`, a total function that falls back to "system").
- F3 History tab carries the payload but hides it: `EventHistoryPanel.tsx` renders each event with a collapsed `EventJsonExpandable` only; `payload.actor` is a UUID, not a name.
- F4 History tab Actor column: backend `history_item_map/1` (`lib/letflow/routers/instances.ex:903-910`) emits only `event_id, event_type, sequence_number, created_at, payload` (no `actor_id`), while `EventRecord` (`web/src/types/api.ts:170-181`) declares `actor_id`, so `EventHistoryPanel.tsx:197-201` renders the literal "system" for every event. Reported as §9 M1.
- F5 Feeding: `InstanceDetailPage.tsx` owns the timeline query (`useInstanceTimeline`, lines 119-123, fed to the Timeline tab) and renders `EventHistoryPanel` (line 344) and `InstancePinsPanel` (line 319). The events query is owned by `EventHistoryPanel` itself (`useInstanceEvents`, line 39). The page's timeline query is enabled only after the Timeline tab was opened (`timelineRequested`, lines 111/131-138); History is the default tab (line 108).

Decision: a dedicated rendering case is required AND the operator name is resolved on the History view itself, frontend-only, by joining the existing timeline feed to the history event on `event_id`. The design does NOT depend on backend change M1 (M1 stays a reported mismatch).

### §6.2 Actor-name resolution (frontend-only)

- Source query: the existing timeline route via the existing hook `useInstanceTimeline(id, { page_size: 200 }, enabled)` (`web/src/hooks/useInstances.ts:51-65`; 200 is the backend maximum page size, `lib/letflow/api/pagination.ex:50`). Its cache key comes from the existing factory `instances.timeline(id, null, 200)`; it is distinct from the Timeline tab's `(id, cursor, 50)` query, so the tab's pagination/merge state in `InstanceDetailPage` is untouched, and both keys sit under `instances.all()` (refreshed by §4.3).
- New page-level derived value in `InstanceDetailPage.tsx`: `actorNamesByEventId: Record<string, string>`, built with `useMemo` from that query's `data.items` as `event_id -> actor_display_name`, only for entries whose `event_type === 'INSTANCE_PINS_REBOUND'` (other event types are deliberately not joined, so every other History row renders exactly as before). The query's `enabled` flag is `activeTab === 'history'`.
- Matching key: `event_id` (present on both `TimelineEntry.event_id` and the history item `event_id` that `EventHistoryPanel` already uses as its React key).
- Delivery: `EventHistoryPanelProps` gains `actorNamesByEventId?: Record<string, string>` (default empty); `InstanceDetailPage` passes it at line 344. `EventHistoryPanel` passes `actorLabel={actorNamesByEventId[event.event_id]}` to `PinsReboundSummary`.
- Fallback when the name is absent (map miss: timeline query still loading or failed, or the rebind event lies beyond the first 200 events of the case): `PinsReboundSummary` shows `payload.actor` (the UUID from F1) in `pins-rebound-actor`, never the literal "system" and never empty; when `payload.actor` is also missing it shows "unknown". A server-resolved "system" name is shown as is (the backend's own fallback for an unresolvable user).
- Stated bound (a specified behaviour, not a deferral): a case with more than 200 events preceding its rebind event falls back to the UUID; no AC or pipeline scenario reaches that size.

### §6.3 Rendering

- New component `web/src/components/instances/PinsReboundSummary.tsx`. Props: `{ payload: Record<string, unknown>; actorLabel?: string }`. From `payload.entries` (defensively parsed; malformed -> the component renders nothing and the existing `EventJsonExpandable` remains the only display) it renders one line per entry: `{ref}: {prior_version} -> {new_version}` (kind as a muted suffix), then `Reason: {payload.reason}`, then `Changed by: {actorLabel ?? payload.actor ?? 'unknown'}`. An empty `entries` array renders "No version changed" (reason and actor still shown).
- `EventHistoryPanel.tsx`, for `event.event_type === 'INSTANCE_PINS_REBOUND'` ONLY:
  - Payload cell: `PinsReboundSummary` rendered above the existing `EventJsonExpandable` (raw JSON kept for audit; nothing removed).
  - Actor cell: shows the resolved operator name (`actorNamesByEventId[event.event_id]`) when present, otherwise the payload actor UUID's first 8 characters (same 8-char convention as `:199`), never "system". All other event types keep the existing Actor cell logic unchanged. This removes the contradictory "system" actor next to a named operator on the rebind row (F4) without waiting for M1.
  - New row test ids on every row (harmless for other types): `event-row-{event_id}` on the `<tr>`, `event-actor-{event_id}` on the Actor `<td>`.
  - Summary test ids: `pins-rebound-summary`, `pins-rebound-entry-{ref}` (text contains prior and new version), `pins-rebound-reason`, `pins-rebound-actor`.
- Result: ONE view (the History tab row for the `INSTANCE_PINS_REBOUND` event) shows the operator name (Actor cell and `pins-rebound-actor`), prior version, new version and reason. The Timeline tab row is unchanged (still "Instance pins rebound by {name}") and is not relied on for EO-005.
- Known non-AC behaviour: the Timeline tab list in `InstanceDetailPage` is merged once per cursor (`lastAppliedCursor` guard, lines 140-150), so a Timeline tab opened before a rebind does not show the new row until the page is reloaded. The EO-005 evidence (History tab) is refreshed by §4.3. No change to the Timeline tab is made.

## §7 Pipeline spec `web/tests/e2e/pipelines/platform-instance-pin-survives-catalog-change.pipeline.e2e.spec.ts`

### §7.1 Conventions

From `platform-migration-partial-failure-resume` and `platform-definition-promotion-approved`: imports `createPipeline`, `getKeycloakToken`, `loginWithToken`, `navigateSpa`, `resolveTenantContext`, `shot`, `authHeaders` from `../pipeline`; `assertServiceReadiness`, `resolveCredential` from `../helpers`; `test.setTimeout(300_000)`; `API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'`; admin login via Keycloak password grant for `admin-user` (`UAT_QA_ADMIN_PASSWORD`, default `admin-pass`) then `loginWithToken`; real backend, NO `page.route`; `pl.step(...)`, `pl.gate(...)`, `pl.onCleanup(...)`, `pl.runCleanup()`; typed state interface. API-side setup steps use the `request` fixture with `authHeaders(token)`; GUI steps use test ids. `web/tests/e2e/db-exec.ts` helpers are NOT used: every precondition below is reachable through real HTTP routes (services, definitions, instances, tasks); `db-exec.ts` (`createActiveDefinitionInSchema`, `createActiveEntityDefinition`, ...) exists only to seed cross-tenant or HTTP-less fixtures.

### §7.2 Definition and service fixture mechanism (resolved from source)

- Service: `POST /api/v1/admin/services` (body = `RegisterServiceBody`, `web/src/api/services.ts:20-30`) with `service_id = pl_pin_{fixtureId}`, `scope: 'global'`, `endpoint_url: 'https://example.invalid/pl-pin'`, `auth_method: 'NONE'`, `timeout_ms: 5000`, `request_schema: '{}'`, `response_schema: '{}'`; this registers version "1" (ACTIVE).
- Definition: `POST /api/v1/definitions` then `POST /api/v1/definitions/{id}/activate` as admin (routes `authz_post "/"` and `"/:id/activate"`, `lib/letflow/routers/definitions.ex:248,258`; create schema `name, version, graph`, `:594-601`; request shape precedent `platform-definition-promotion-approved.pipeline.e2e.spec.ts:117-157`). Graph: `n1 START`; `n2 HUMAN_TASK` (attributes `{role:'admin-user', assignee_type:'user', assignee_ref:'admin-user'}`, as in that precedent); `n3 SERVICE_TASK` (attributes `{service_id: <serviceId>, method: 'POST', timeout_ms: 5000, retry_limit: 0}`; `service_id` is what `ServiceTask.parse_config_from_node_attributes/1` (`service_task.ex:183-222`) and the pin enumeration (`pin_resolver.ex`, `("SERVICE_TASK","service_id") -> :catalog_entry`) read); `n4 END`; edges `n1->n2`, `n2->n3`, `n3->n4`. `activate` runs `ServiceScopeValidator` (`lib/letflow/definitions/service_scope_validator.ex:191-212`), so the service MUST be registered before the definition; the definition name embeds `fixtureId` to avoid collisions.
- Cases: `POST /api/v1/instances` with `{ definition_id }` (`StartInstanceRequest`, `web/src/types/api.ts:129`). Instance start resolves pins through the real catalog-backed `Letflow.ServiceCatalog.PinLookup.build/0` (`lib/letflow/engine.ex:1049-1064`), so a started case records `catalog_entry / {serviceId} / "1"`.
- Reaching the service step: a case parked on `n2` reaches `n3` when `n2`'s task is completed. The task id comes from `GET /api/v1/tasks?status=PENDING&instance_id={id}` (the query `InstanceDetailPage` issues via `useTasks`, line 102) and is completed with `POST /api/v1/tasks/{taskId}/complete` body `{ output_variables: {} }` (`CompleteTaskRequest`, `web/src/types/api.ts:164`; route `authz_post "/:id/complete"`, `lib/letflow/routers/tasks.ex:142`).

### §7.3 What the real backend does at the service step (evidence; drives the step-03 assertion)

- Reaching `n3` makes `Transition.dispatch_service_task/3` (`transition.ex:750-754`) emit a dispatch request; the engine inserts a `service_task_dispatches` row; `ServiceTaskDispatcher.Poller` claims it (`@default_poll_interval_ms 5_000`, `service_task_dispatcher.ex`; the poller runs unless `:start_service_task_dispatcher` is false, which only `config/test.exs:56` sets, so it runs in the `BPM_TEST_URL` backend).
- For `route_kind: :catalog_service` the dispatcher calls `catalog_lookup_stub/2`, which returns `{:error, :not_registered}` UNCONDITIONALLY (`service_task_dispatcher.ex:411-416`, branch `:763-765`), then `handle_failure(..., :request_build_error)`. It never performs the HTTP call and never reads the pinned version, even after REQ-373 shipped the real `PinLookup` (REQ-373 covered pin resolution, not the dispatcher). `:request_build_error` is non-retriable, so on the first poll the dispatcher gives up: `build_service_task_give_up_error_attrs/1` (`service_task.ex:460-486`) -> `Engine.set_instance_error/2` -> event `EXECUTION_ERROR` with payload `{ error_type: "service_task_retries_exhausted", affected, reason: "service task failed (request_build_error): not retriable", variables, details: { last_failure_kind: "request_build_error", attempt_index, retry_limit } }` (`execution_error.ex:296-315`) and projection status `ERROR`.
- Consequence A: a catalog-service step cannot complete successfully end to end through the real backend today, independent of anything REQ-432 builds and independent of retirement (the stub ignores catalog state). The AC half "the in-flight case completes the step without error" is therefore not assertable as a success; it is reported as mismatch §9 M5 (route to backend / REQ-ANALYST; not shimmed, not hidden behind a mock).
- Consequence B: status `ERROR` is not rebindable (`pin_rebind.ex:28-33`, `{:instance_not_rebindable, :error}`), so the case that reaches the service step cannot also be the rebind target. The spec therefore uses separate cases: A (rebind target, stays on `n2`) and C (in-flight step case).

### §7.4 Step 3 assertion (exact history evidence)

For the in-flight case C, the strongest honest assertion the real backend supports, covering "retiring a version does not error or block the already-running case's in-flight step":

1. `POST /tasks/{taskId}/complete` issued AFTER the retire+publish of step 02 returns 2xx: the engine accepted the completion and advanced the case; retirement did not block it.
2. `GET /api/v1/instances/{C}/history` (array or `{items}`) contains an event `TASK_COMPLETED` whose `payload.node_id === 'n2'` (`engine.ex:4434`; the timeline's own `TASK_COMPLETED` description reads the same key), AND, polled up to 45 s at 2 s intervals (dispatcher interval is 5 s), a terminal service-step event that is exactly one of: `SERVICE_TASK_COMPLETED` (payload `{dispatch_id, node_id: 'n3', decoded_body}`, `engine.ex:3225`; the outcome once the stub of M5 is replaced) or `EXECUTION_ERROR` with `payload.error_type === 'service_task_retries_exhausted'` and `payload.details.last_failure_kind === 'request_build_error'` (today's outcome). No other event type and no other `last_failure_kind` is accepted, so a retirement-induced failure (classified differently) fails the spec.
3. The spec logs which of the two occurred (`console.log`) and takes a `shot`; the stub outcome is recorded there as M5, not silently accepted as success.
4. C's detail page `instance-pins-panel` still lists `{serviceId}` with version "1" (pin display unaffected after the service step ran and after retirement).

### §7.5 State and steps

State interface `PinSurvivesState`: `adminToken`, `serviceId`, `oldVersion` ("1"), `newVersion`, `definitionId`, `caseAId` (long-running, rebind target), `caseCId` (in-flight step case), `caseBId` (started after publish), `rebindReason`, `rebindEventId`, `operatorDisplayName`.

| Step | Scenario step | What it does | Asserts | Covers |
|---|---|---|---|---|
| pre | preconditions 1-2 | per §7.2: register service v1, create + activate the definition, choose unique `newVersion` | gate: service v1 ACTIVE, definition active | preconditions |
| 01 | step 1 (gui) | API: start cases A and C (both park on `n2`); GUI: open A's detail page | `instance-pins-panel` lists `{serviceId}` with version "1"; A's Active Tasks shows `n2` | EO-003, EO-001 "before" capture |
| 02 | step 2 (gui) | on `/admin/services`: click `service-retire-btn-{serviceId}`, confirm (`service-retire-confirm`); then `service-publish-btn-{serviceId}`, fill `service-publish-version-input` with `newVersion`, submit | row `service-version-{serviceId}` shows `newVersion`, `service-status-{serviceId}` shows ACTIVE (retire-then-publish order per §9 M4) | scenario step 2; build item 1 |
| 03 | step 3 (system) | complete C's `n2` task via API, per §7.4 | §7.4 assertions 1-4 | EO-001, EO-004 (in-flight step and pin display) |
| 04 | step 4 (gui) | start case B via API; open A's and B's detail pages | B's `instance-pins-panel` shows `newVersion`; A's shows "1"; both list a non-empty "How it was set" value | EO-002, EO-003, EO-004 |
| 05 | step 5 (gui) | on A's detail click `pin-rebind-btn-catalog_entry:{serviceId}`, fill `pin-rebind-new-version-input` with `newVersion` and `pin-rebind-reason-input` with "External system retires the old endpoint at month end.", submit | `pin-rebind-success` visible; `instance-pins-panel` (refetched by §4.3) shows `newVersion` with "Changed via rebind" | build item 2, EO-005 (action) |
| 06 | EO-005 | first read A's timeline via API (`GET /instances/{A}/timeline?page_size=200`) to capture `operatorDisplayName` and `rebindEventId` from the entry with `event_type === 'INSTANCE_PINS_REBOUND'`; then in the GUI stay on the History tab (the default) and locate row `event-row-{rebindEventId}` | ON THAT ONE ROW (History tab, single view): `event-actor-{rebindEventId}` text equals `operatorDisplayName` and is neither "system" nor a UUID prefix; `pins-rebound-actor` text equals `operatorDisplayName`; `pins-rebound-entry-{serviceId}` contains "1" and `newVersion`; `pins-rebound-reason` contains the reason string | EO-005 (name + previous version + new version + reason on one view) |
| 07 | (negative) | log in as `worker-user` (TASK_WORKER) | `/admin/services` exposes no `service-publish-btn-*`/`service-retire-btn-*`; A's detail page shows no `pin-rebind-btn-*` | permission gating (§1) |
| cleanup | cleanup | cancel A and B via API (C is in `ERROR`; cancel attempted, a 409 is tolerated); leave the published version (per the scenario's `cleanup.description`) | | cleanup |

Scenario-yaml update: precedent exists (`definition-promotion-approved.yaml`, `definition-promotion-rollback.yaml` replaced the stale "ISS-0527" NOTE with an "ISS-0527 resolved {date}: the spec above now exists..." comment block). Once the spec exists, replace the `# NOTE (ISS-0527)` block (lines 29-35 of `instance-pin-survives-catalog-change.yaml`) with a resolved comment in that style that also records the M5 limitation on step 3, leaving the `pipeline_test:` line and all ported content byte-identical (the file header forbids editing ported content). Do not touch `pipeline_test:`.

## §8 Frontend unit/component tests (Vitest + Testing Library, `vi.mock('@/api/...')` pattern)

| Test file (new unless noted) | Cases | Maps to |
|---|---|---|
| `web/src/api/__tests__/services.versions.test.ts` | `publishVersion` POSTs to the exact path with the body; `retire` POSTs to exact path with no body (mock `client`) | item 1 client signatures |
| `web/src/pages/admin/services/__tests__/ServicesPage.versions.test.tsx` | admin sees publish/retire buttons; non-admin does not; publish submit calls `publishVersion(serviceId, body)` with `version` and prefilled fields; 409 shows the duplicate-version message; retire confirm calls `retire(serviceId)`; Retire disabled on a RETIRED row; list invalidated after success | item 1 UI, §3 |
| `web/src/api/__tests__/instances.rebind.test.ts` | `rebindPins` POSTs `/api/v1/instances/{id}/rebind-pins` with body and `Idempotency-Key` header | item 2 client |
| extend `web/src/components/instances/__tests__/InstancePinsPanel.test.tsx` (mock gains `rebindPins`) | no Rebind button without `canRebind`; none when `instanceActive` false; dialog blocks submit on empty reason and on unchanged version; submit calls `rebindPins(id, {reason, entries:[{kind,ref,version}]}, key)`; success refetches `getPins` (second call returns the new version) and shows success line; 409/422/404 error texts; reopening the dialog uses a new key while retry reuses the key | item 2 UI, §5 |
| `web/src/components/instances/__tests__/PinsReboundSummary.test.tsx` | renders prior -> new, reason, actor for a realistic payload; empty `entries`; malformed payload falls back without throwing | item 3, EO-005 |
| extend the `EventHistoryPanel` test (existing file if present, else new) | an `INSTANCE_PINS_REBOUND` event renders the summary above the JSON; with `actorNamesByEventId` containing its `event_id` the Actor cell (`event-actor-{event_id}`) and `pins-rebound-actor` both show the name, versions and reason visible in the same row; with an empty map both show the payload actor UUID (8-char prefix in the cell) and never "system"; other event types render unchanged (Actor still "system" when `actor_id` absent) | item 3, EO-005 |
| `web/src/hooks/__tests__/useRebindPins.test.tsx` | success calls `invalidateQueries` with exactly `{ queryKey: ['tenant', <tenantId>, 'instances'] }`; failure does not invalidate | cache invalidation (§4.3) |
| `web/src/pages/instances/__tests__/InstanceDetailPage.actorNames.test.tsx` (extend existing page test if present) | History tab active: timeline hook is called with `page_size: 200` and enabled; the `INSTANCE_PINS_REBOUND` timeline entry's `actor_display_name` reaches the matching history row by `event_id`; non-rebind events are not joined | §6.2 |
| Two-case distinct pins (EO-001/EO-002) | `InstancePinsPanel` rendered for two instance ids with `getPins` returning different versions shows each case's own version (component-level proof that the panel reads per-instance data) | EO-001, EO-002 |
| Retire does not break running case's pin display (EO-004) | panel test where `getPins` still returns the old version for the running case after the services page retired it (services and pins data are independent queries) | EO-004 |

## §9 Backend/requirement mismatches found (route to backend; do NOT shim in web/)

- M1 (history actor): `history_item_map/1` (`lib/letflow/routers/instances.ex:903-910`) omits `actor_id`; `EventRecord.actor_id` is declared in the web types and the History tab shows "system" for every event. Also no display-name is offered on the History tab. Backend follow-on: emit `actor_id` (and optionally `actor_display_name`) on history items. REQ-432 does not block on it (§6 decision).
- M2 (service record): `service_record_json/1` (`admin_services.ex` bottom) emits no `max_retries` and no `retry_policy`, while `ServiceRecord.max_retries` is declared in `web/src/api/services.ts` and `ServicesPage` renders a "Retries" column from it (renders blank). Pre-existing; publish accepts `retry_policy` but the response never echoes it. Not fixed here; backend/req-analyst decision.
- M3 (stale moduledoc): `instances.ex` moduledoc says rebind-pins is "not permission-gated"; the route declares `:InstancesCancel` (`instances.ex:338`). UI gating follows the route code (PROCESS_OPERATOR/PLATFORM_ADMIN). Doc-only backend cleanup.
- M4 (scenario step 2 vs real retire semantics): req373 §3.2 shows `retire/1` retires the single current row and accepts no version argument; req373 §3.1 shows `publish/3` archives the current row (stamping `retired_at`) when superseding. The scenario's step 2 "publishes the newer version AND retires the version the running case is using" therefore cannot be done in that order through the UI: calling retire AFTER publish would retire the NEW version and make new cases unresolvable (EO-002 fail). The spec in §7 therefore retires first, then publishes (the old row is archived as retired, the new one is ACTIVE). Requirement text item (1) ("a retire action") is satisfied; the requirement does not assume a per-version retire. No backend change needed unless the product wants per-version retire (OQ-3).

- M5 (service-step stub, affects EO-001/EO-004 "step performed at step 3"): `ServiceTaskDispatcher.catalog_lookup_stub/2` still returns `{:error, :not_registered}` unconditionally for every catalog `service_id` (`lib/letflow/engine/service_task_dispatcher.ex:411-416`, branch `:763-765`), so a `catalog_service` SERVICE_TASK always gives up with `EXECUTION_ERROR` / `ERROR` status regardless of the pinned or retired version; REQ-373 replaced `PinLookup` but not the dispatcher. The scenario's expectation that the in-flight step completes "without error" cannot be met by the real backend; §7.4 asserts the strongest honest evidence instead and records the outcome. Backend follow-on (dispatcher resolving `service_id` through the pinned catalog version) must be filed by REQ-ANALYST; REQ-432 does not block on it and does not shim it.
- M6 (history items carry no display name): same root as M1; the frontend join of §6.2 is bounded to the first 200 timeline events (stated in §6.2).

## §10 Open questions (explicit; none defers an AC-mapped element; the remaining ones are product preferences with the decision already taken in this design)

- OQ-1 (RESOLVED, no longer open): EO-005 is met on the single History view by §6.2/§6.3.
- OQ-2: Rebind action is offered for all three pin kinds (backend accepts all). Confirm it should not be limited to `catalog_entry` (the only kind the scenario exercises; `module` has no version lifecycle per the REQ-373 scope gap).
- OQ-3: The dialog rebinds one entry per submission. Multi-entry rebind in one call is supported by the backend; confirm single-entry is acceptable for this requirement.
- OQ-4 (RESOLVED, no longer open): definition/service fixture mechanism specified in §7.2 from source.
- OQ-5 (RESOLVED, no longer open): replay behaviour reduced to the verified `EventStore.append` duplicate semantics, §5.3; the design does not depend on the replayed response body.
- OQ-6: Whether the new-version field should offer suggestions. Operators (PROCESS_OPERATOR) cannot call `/admin/services`, so the dialog uses free text. Confirm free text is acceptable.
- OQ-7: No i18n catalogue is used for these screens (existing neighbours use inline English); confirm this stays consistent.
- OQ-8: `serviceId`/`id` are interpolated unencoded in URLs as existing `servicesApi`/`instancesApi` functions do; service ids are identifier-like, instance ids UUIDs. Confirm no encoding is wanted.
- OQ-9 (RESOLVED, no longer open): exact step-3 event types specified in §7.4; the backend limitation is M5.

## §11 Invariants

- No file under `lib/letflow/` is modified; `mix letflow.check` backend gates are unaffected.
- Only `client` performs HTTP; no hardcoded base URL; no colour literals.
- Existing exports in `services.ts` and `instances.ts` keep their signatures; `InstancePinsPanel` without the new props behaves exactly as REQ-399 shipped.
- Gating is UI convenience; 403 from the backend is authoritative and surfaces as an error message.
