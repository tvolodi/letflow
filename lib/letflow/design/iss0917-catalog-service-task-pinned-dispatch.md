# WF-03 Fix Design -- ISS-0917 (catalog-pinned SERVICE_TASK cannot execute)

Run-id: WF03-ISS0917-20261001
Type: engine behaviour fix (activation-time catalog resolution) + one router status clause
+ test/doc updates. **Design only -- no implementation code in this document.**
Issue: `docs/issues/ISS-0917.yaml` (queue Q-907, GH-2057). Diagnosis:
`handoffs/WF03-ISS0917-20261001/step-01-issue-fixer-diagnose.json` (result.summary).
Chain: CODE-DESIGNER -> CODE-DESIGN-VALIDATOR -> ELIXIR-DEV -> SECURITY-REVIEWER (mandatory,
tenant data path) -> REVIEWER -> TEST-DESIGNER -> TEST-RUNNER -> FRONTEND-DEV (e2e spec only).

---

## 0. Diagnosis claims re-verified against code (HANDOFF_PROTOCOL 1.1)

Verified on this branch (HEAD 5fa01c94) by reading the code, not by trusting the report.

| Claim | Verified at | Result |
|---|---|---|
| Failure is at activation, not at the stub | `lib/letflow/engine.ex:906-907` (`:catalog_service` arm calls `finish_service_task_arm_attrs/5` with `rendered_url` = `nil`), `engine.ex:911-914` (`validate_rendered_url(nil)` -> `{:empty_url_error, node_id}`) | CONFIRMED |
| create/2 turns it into `{:activation_failed, {:service_task_url_rendered_empty, node_id}}` | `engine.ex:582-599` | CONFIRMED |
| completion hop turns it into an `EXECUTION_ERROR` via the tagged tuple channel | `engine.ex:3586-3620` (`prepare_service_task_dispatch_for_completion/7`), `engine.ex:3531` | CONFIRMED |
| The stub is unreachable today | `service_task_dispatcher.ex:411-416` (definition), `service_task_dispatcher.ex:763-766` (only call site, poll-time branch on a `:catalog_service` snapshot row) | CONFIRMED -- activation never inserts such a row |
| Snapshot carries no pinned version id | `engine.ex:936-948` (`config_snapshot_map/2`: route_kind, url_template, service_id, method, body_template, headers, timeout_ms, retry_limit, rendered_url) | CONFIRMED |
| `PinLookup.catalog_lookup/1` is untenanted and refuses RETIRED | `lib/letflow/service_catalog/pin_lookup.ex:57-68` | CONFIRMED (this is a START-time resolver; it must NOT be reused for dispatch -- see D1) |
| `PinResolver.pin_for/3` is pure; `reconstruct_effective_pins/2` honours INSTANCE_PINS_REBOUND | `pin_resolver.ex:766-773`, `pin_resolver.ex:636-668`, `merge_effective_pins/3` `pin_resolver.ex:545-602` | CONFIRMED |
| 500 comes from the req085 5.5.1 catch-all row | `lib/letflow/design/req085-task-routes-write.md:555`; router catch-all `lib/letflow/routers/tasks.ex:367-369` (branch) | CONFIRMED |

### 0.1 Corrections and additions to the diagnosis (found while re-verifying)

1. **Rebound pins carry no `resolved_id`.** `PinResolver.merge_effective_pins/3`
   (`pin_resolver.ex:566-602`) sets `resolved_id: nil` and `source: :rebound` for every pin
   moved by `INSTANCE_PINS_REBOUND` (decision recorded in
   `lib/letflow/design/iss-0078-pin-rebind-provenance.md`; `PinRebind` never re-verifies a
   rebind against the catalog). The diagnosis' "fetch by `version_id`" is therefore
   insufficient: after a rebind the only identity left is `(service_id, version)`. The
   resolver in D1 takes either identity. Without this, REQ-432's "rebind long-running case
   onto v2" would leave the case unable to dispatch.
2. **Five call sites, not four.** The diagnosis lists create, completion hop and "timer sites
   2463, 2684, 3088". Actually: create (`engine.ex:550`), completion hop (`engine.ex:3500`),
   timer-fire (`engine.ex:2463`), escalation-timer-fire (`engine.ex:2684`) and
   `advance_after_service_task_outcome` -- the poller re-entry after ANOTHER SERVICE_TASK
   resolves (`engine.ex:3088`, a SERVICE_TASK -> SERVICE_TASK chain). All five call
   `prepare_service_task_dispatch/5` (`engine.ex:851`) either directly or through a wrapper.
3. **PR #2087 is already merged to `origin/main`** (commit 0b1931d3, merged 2026-10-01T12:10:16Z)
   but is NOT in this branch (`git merge-base --is-ancestor` negative). On `origin/main`
   `routers/tasks.ex` `handle_complete_result/2` already has three 403 clauses
   (`:assigned_to_other_user`, `:assignee_group_not_member`, `:assignee_role_not_held`)
   inserted immediately before the catch-all (main:378-402). **ELIXIR-DEV must start from
   `origin/main` merged into this branch** (ORCH action, see D8). All `routers/tasks.ex` line
   numbers in this doc are branch line numbers; anchor by function name, not by line.
4. **ISS-0933 is a different error tuple.** ISS-0933 ("complete on an instance in ERROR
   returns 500") concerns `{:instance_not_active, status}` returned BEFORE any transition,
   not `{:instance_execution_error, _, _}` which is returned AFTER the Multi commits. The two
   share only the catch-all clause, not the cause. This matters for D4.
5. **The Engine already depends on `Letflow.ServiceCatalog.PinLookup`** (`engine.ex:1064`), so
   calling `Letflow.ServiceCatalog` from the Engine adds no new module-level dependency edge.
6. **UrlValidator requires scheme `https`** (see `lib/letflow/design/iss0930-seed-service-task-endpoints.md`
   section 0). Any catalog `endpoint_url` that is not a public https URL gives
   `{:request_build_error, :target_url_not_allowed}` at dispatch -- relevant to the e2e (section 6.4).
7. **Decision record 0027 anticipated this change** and left a live INV-9 question for the
   requirement that replaces the stub (see section 7 item 4).

---

## 1. Decisions at a glance

| # | Decision | Section |
|---|---|---|
| D1 | New `Letflow.ServiceCatalog.resolve_pinned_version/3`: resolve by pinned `version_id`, or by `(service_id, version)` when the pin has no `resolved_id` (rebound); live row (incl. RETIRED current) first, else `service_catalog_versions`; tenant visibility via the same three-way scope/owner rule as `get_for_tenant/2`; invisible == not found | 2 |
| D2 | Resolve at ACTIVATION in `Letflow.Engine` for `route_kind: :catalog_service`; pins passed in (create) or lazily reconstructed (all other sites); render `endpoint_url` with `render_service_task_url/2`; freeze URL + audit keys in `config_snapshot`; typed errors, NEVER a fall-back to the live current row | 3 |
| D3 | Retire `catalog_lookup_stub/2`; the dispatcher's `:catalog_service` branch becomes snapshot-driven and shares the inline transport (and its SSRF gate); enumerated test/doc changes | 4 |
| D4 | Add ONE dedicated router clause: `{:instance_execution_error, error_type, _affected}` -> 409 (detail names only the error_type atom). Explicit amendment to req085 5.5.1 -- REVIEWER sign-off required. ISS-0933 untouched | 5 |
| D5 | Fail-first test plan: ExUnit (resolver, engine, dispatcher, router), e2e spec extension (extra in-flight case + new step), scenario annotation | 6 |
| D6 | Security notes; `required_auth != NONE` is OUT of scope and **fails closed** with a typed error | 7 |
| D7 | No migration | 8 |
| D8 | Owned files and coordination (PR #2087 merged, PR #2089 open) | 9 |

---

## 2. D1 -- `Letflow.ServiceCatalog.resolve_pinned_version/3`  (acceptance point 1)

### 2.1 Why a new function

- `PinLookup.catalog_lookup/1` answers "what is the current ACTIVE version of this service
  today" (a START-time question). It is untenanted, refuses RETIRED, and returns only
  `{resolved_id, version}`. Dispatch needs the opposite: "what exactly did THIS instance pin,
  even if it has since been superseded or retired", plus the technical fields.
- `ServiceCatalog.get_for_tenant/2` returns only the live row and has no by-version form.
- No existing function fetches a `service_catalog_versions` row by primary key.

### 2.2 Public signature (types only)

- Function: `Letflow.ServiceCatalog.resolve_pinned_version(service_id, pin_identity, tenant_id)`
- Types:
  - `service_id :: String.t()`
  - `pin_identity :: {:version_id, Ecto.UUID.t()} | {:version, String.t()}`
  - `tenant_id :: Ecto.UUID.t()` (guard: binary, mirrors `get_for_tenant/2`)
  - Return: `{:ok, resolved_service_version()} | {:error, :not_found}`
- `resolved_service_version()` -- plain map (not an Ecto struct, so the engine never holds a
  schema struct from two different tables):
  - `service_id :: String.t()`
  - `version_id :: Ecto.UUID.t()`
  - `version :: String.t()`
  - `endpoint_url :: String.t()`
  - `timeout_ms :: pos_integer()`
  - `retry_policy :: String.t() | nil`  (informational, see section 3.8)
  - `required_auth :: :NONE | :API_KEY | :OAUTH2 | :MUTUAL_TLS`
  - `source :: :live | :archived`  (for audit/test only; not persisted)
- Error shape: exactly ONE error atom, `:not_found`. Never `:forbidden`, never a reason
  that distinguishes "no such service", "service invisible to this tenant", "version does not
  exist", "version belongs to a different service". (INV-5; `get_for_tenant/2` doc.)

### 2.3 Resolution order (normative)

1. Fetch the live `Entry` by `service_id` (single PK read). This row is the **scope/owner
   authority** for the whole service: `service_catalog_versions` has no `scope` or
   `owner_tenant_id` column (`lib/letflow/service_catalog/version.ex`), so visibility of an
   archived version is decided by the live row of the same `service_id`.
2. Apply the three-way visibility rule to that live row, factored into one private predicate
   shared with `get_for_tenant/2` so the two cannot drift: no row -> not found; `scope: :global`
   -> visible; `scope: :tenant` and `owner_tenant_id == tenant_id` -> visible; any other
   `scope: :tenant` -> not found. (The existing `get_for_tenant/2` behaviour and its tests
   must stay byte-identical.)
3. If visible, locate the pinned version:
   - `{:version_id, id}`: if live `entry.version_id == id` -> live data (status ACTIVE **or
     RETIRED** -- a retired current version is exactly the REQ-373/432 case and MUST resolve).
     Otherwise `Repo.get(Version, id)` and require `version.service_id == service_id`
     (a version id belonging to another service is `:not_found`, not an error leak).
   - `{:version, v}`: if live `entry.version == v` -> live data (ACTIVE or RETIRED).
     Otherwise one query on `service_catalog_versions` for `(service_id, version)`;
     `check_publishable_version/2` (`service_catalog.ex:347`) guarantees at most one row.
4. Anything else -> `{:error, :not_found}`.

### 2.4 Properties the implementation must have

- Read-only. No write, no event, no lock. At most two PK-or-unique-key reads.
- Does not consult `status` as a filter. (The live-row-only `status: :ACTIVE` check lives in
  `PinLookup` and is a START-time rule; it MUST NOT be copied here.)
- Pure of side effects on the pin: it never changes which version an instance is pinned to.
- Does not call `PinLookup.catalog_lookup/1`.
- `version_id` / `version` arguments are only ever supplied by `Letflow.Engine` from the
  instance's own event-sourced pins (section 3.3). The function is not exposed through any router and
  accepts no request-derived input.

### 2.5 Edge cases (decided, not open)

| Case | Result |
|---|---|
| Entry `scope` narrowed after the instance pinned (`update_scope/2` global -> tenant of another owner) | `:not_found` -> instance ERROR. Fail-closed; correct (tenant lost access) |
| Entry deleted (`ServiceCatalog.delete/1` removes only the live row; archive rows remain) | `:not_found` (cannot prove visibility). Instance ERROR. See open question OQ-3 |
| Pin `version_id` equals live version_id but entry RETIRED | `{:ok, ...}` with live data |
| Pin `version_id` found in archive, live row ACTIVE at a later version | `{:ok, ...}` archive data, `source: :archived` |

---

## 3. D2 -- activation-time resolution in `Letflow.Engine`  (acceptance point 2)

### 3.1 Where

`resolve_service_task_arm_attrs/5` (`engine.ex:897-909`), called from
`prepare_service_task_dispatch/5` (`engine.ex:851`). The `:inline_url` arm is unchanged. The
`:catalog_service` arm stops passing `nil` and instead runs the pipeline below. Resolution at
activation (not at poll time) is deliberate: (a) the engine already freezes the rendered URL at
INSERT (`service_task_dispatcher.ex` moduledoc OQ-3 "freeze-at-INSERT / never-re-render"),
(b) the instance's pins are in scope here, the poller has no pin context, and (c) a failure
here is routed into the instance's error path atomically with the completion, rather than as a
poll-time retry loop against a deterministic failure.

### 3.2 New engine-private shapes (types only)

- `catalog_pin_source`: `{:pins, [PinResolver.pinned_version() | PinResolver.effective_pin()]}`
  or `{:reconstruct, instance_id :: Ecto.UUID.t(), prefix :: String.t() | nil}`.
- `catalog_dispatch_ctx`: map with `pin_source :: catalog_pin_source()` and
  `tenant_id :: Ecto.UUID.t()`.
- `prepare_service_task_dispatch/5` becomes `/6`, taking `catalog_dispatch_ctx` as an extra
  argument; its wrappers (`prepare_service_task_dispatch_for_create/5`,
  `_for_completion/7`, `_abort_on_empty_url/5`) gain the same context and pass it through.
- New outcome tuple from `prepare_service_task_dispatch` (alongside the existing
  `{:ok, _}`, `{:error, _}`, `{:empty_url_error, node_id, variables}`):
  `{:catalog_resolution_error, node_id, reason, variables}`.
- `catalog_resolution_reason` (closed set, atoms or 2-tuples; all safe to render):
  - `{:pin_missing, :catalog_entry, service_id}` -- passthrough of `PinResolver.pin_for/3`'s error
  - `:pin_has_no_identity` -- pin present but both `resolved_id` and `version` are nil/blank (defensive)
  - `:pins_unavailable` -- `reconstruct_effective_pins/2` failed (details carry only the atom class, no payload)
  - `:version_not_found` -- D1 returned `:not_found` (covers non-existent AND invisible)
  - `{:required_auth_unsupported, auth}` -- `auth` in `:API_KEY | :OAUTH2 | :MUTUAL_TLS` (see section 7 item 1)
  - The existing empty-URL case keeps its own existing channel (`{:empty_url_error, ...}`), e.g.
    when the pinned `endpoint_url` renders to an empty string from `{{variables.KEY}}`.

### 3.3 Effective pins per call site (normative)

| Call site | Pin source | Tenant id |
|---|---|---|
| `start_instance` -> `prepare_service_task_dispatch_for_create` (`engine.ex:550`) | `{:pins, pins}` -- the merged own+inherited pin list already bound in the `with` chain (`engine.ex:535`). No event-log read (the INSTANCE_STARTED event is not yet written) | the `tenant_id` already in `start_instance/6` arguments |
| completion hop (`engine.ex:3500` via `prepare_service_task_dispatch_for_completion/7`) | `{:reconstruct, projection.instance_id, prefix}` -> `PinResolver.reconstruct_effective_pins/2` | `TenantProvisioning.tenant_id_for_schema_name(prefix)` (already used at the other sites; must not come from caller input) |
| timer-fire (`engine.ex:2463`) | `{:reconstruct, timer.instance_id, prefix}` | same derivation (already in the surrounding `with`) |
| escalation-timer-fire (`engine.ex:2684`) | `{:reconstruct, timer.instance_id, prefix}` | same |
| service-task outcome advance (`engine.ex:3088`) | `{:reconstruct, dispatch.instance_id, prefix}` | same |

Reconstruction is **lazy and at most once per `prepare_service_task_dispatch` call**: it runs
only if at least one requested dispatch node parses to `route_kind: :catalog_service`. An
inline-only (or no-SERVICE_TASK) hop chain performs zero additional reads -- its behaviour and
cost are byte-identical to today. The completion hop already holds the instance row lock (M2),
so the read sees every committed `INSTANCE_PINS_REBOUND` and cannot race a concurrent rebind
(`rebind_pins/3` takes the same instance lock -- verify, OQ-4).

### 3.4 Pipeline for one `:catalog_service` node (normative order)

1. `ServiceTask.parse_config_from_node_attributes/1` (unchanged) yields `config` with
   `service_id`.
2. Obtain pins (per 3.3). Failure -> `:pins_unavailable`.
3. `PinResolver.pin_for(pins, :catalog_entry, config.service_id)`. Missing ->
   `{:pin_missing, :catalog_entry, service_id}`. **No fall-back to the live current row on
   ANY error in steps 2-5. This is the central invariant (INV-PD-1).**
4. Build `pin_identity`: `{:version_id, pin.resolved_id}` if non-blank, else
   `{:version, pin.version}` if non-blank, else `:pin_has_no_identity`.
5. `ServiceCatalog.resolve_pinned_version(config.service_id, pin_identity, tenant_id)`.
   `:not_found` -> `:version_not_found`.
6. If `required_auth` is anything other than `:NONE` -> `{:required_auth_unsupported, auth}`
   (section 7 item 1). Checked BEFORE building a URL so no row is inserted.
7. `rendered_url = render_service_task_url(resolved.endpoint_url, variables)` (the existing
   `{{variables.KEY}}` renderer; `endpoint_url` is therefore a template exactly like an inline
   `url_template`). Empty result -> the existing `{:empty_url_error, node_id}` path.
8. Build `arm_attrs` via the existing `finish_service_task_arm_attrs/5` with the snapshot below.

### 3.5 `config_snapshot` content for a catalog row (backward compatible)

Existing keys keep their meaning; `config_snapshot` is a `:map` column
(`priv/repo/migrations/20260902010001_create_service_task_dispatches.exs:80`, `null: false`),
extra keys need no migration.

| Key | Value for `route_kind: "catalog_service"` |
|---|---|
| `"route_kind"` | `"catalog_service"` (unchanged -- audit truth of how the node was configured) |
| `"service_id"` | unchanged |
| `"url_template"` | `nil` (unchanged; node has none) |
| `"rendered_url"` | **the rendered pinned `endpoint_url`** (was `nil`) |
| `"method"`, `"body_template"`, `"headers"`, `"retry_limit"` | unchanged (node attributes; the catalog supplies none of these) |
| `"timeout_ms"` | `min(node config.timeout_ms, resolved.timeout_ms)` -- the workflow author's bound can only be tightened by the service's declared bound, never extended |
| `"catalog_version_id"` | NEW, `resolved.version_id` (audit) |
| `"catalog_version"` | NEW, `resolved.version` (audit) |
| `"catalog_retry_policy"` | NEW, `resolved.retry_policy` -- stored for audit ONLY, deliberately NOT interpreted (see section 3.8) |

`config_snapshot_map/2` is extended with an optional third argument (catalog audit map) rather
than a second function, so the inline path's snapshot stays byte-identical (no new keys at all
for `:inline_url`). `ServiceTaskDispatcher.config_from_snapshot/1` ignores unknown keys, so
existing readers are unaffected.

### 3.6 Failure routing per call site (reuses the empty-URL precedent exactly)

| Site | `{:catalog_resolution_error, node_id, reason, variables}` becomes |
|---|---|
| create | `{:error, {:activation_failed, {:service_task_catalog_unresolved, node_id, reason}}}` -- nothing persisted for the instance (snapshot orphan row behaviour unchanged, see `engine_test.exs` comment at 1243-1246) |
| completion hop | `{:ok, {:execution_error, error_args}}` through the existing `{:error, {:empty_url_error, error_args}}`-style channel: a **sibling** channel `{:error, {:catalog_resolution_error, error_args}}` handled at `engine.ex:3531` next to the empty-url one. `error_args.error_type = :service_task_catalog_unresolved` (the `error_type` union is open: `execution_error.ex:99-107`); `affected = {:node, node_id}`; `reason` a fixed sentence per reason class (no interpolation of variables, headers or URLs); `details = %{reason: <atom class>}` only; `variables` as the existing empty-url builder does. Instance goes to ERROR, no `service_task_dispatches` row, no TASK_COMPLETED -- identical shape to today's failure but now ONLY for genuine resolution failures |
| timer-fire, escalation-timer-fire, service-outcome advance | `{:error, {:service_task_catalog_unresolved_not_supported_for_timer_fire, node_id, reason}}` -- same "roll back this attempt, no ExecutionError wiring on these paths" scope boundary as the existing `_abort_on_empty_url` wrapper (`engine.ex:2842-2867`). Not widened here (OQ-5) |

A new builder `ServiceTask.build_catalog_unresolved_error_attrs/1` (pure, beside
`build_empty_url_error_attrs/1`, `service_task.ex:315`) produces the `standalone_error_attrs()`;
it must satisfy the same purity contract as its sibling (no Repo, no Logger, no clock).

### 3.7 `create/2` ordering note

For the create path, resolution happens inside `prepare_service_task_dispatch_for_create` which
runs before `persist/14`. A catalog failure therefore writes no projection/event rows (same as
today's empty-URL create failure). The new typed error replaces the old
`{:service_task_url_rendered_empty, "svc"}` for this case.

### 3.8 section 3.8 -- `retry_policy` and PR #2089

`retry_policy` is a free string on the catalog. PR #2089 (ISS-0918, open) is still shaping
how it is surfaced (`max_retries`/`retry_policy` in `service_record_json`). This fix does NOT
interpret it: retry behaviour stays `config.retry_limit` from the node, as for inline tasks.
Storing it in the snapshot is audit-only and costs nothing.

---

## 4. D3 -- the stub, the dispatcher branch, tests and doc claims  (acceptance point 3)

### 4.1 Decision: retire the stub; keep the branch, make it snapshot-driven

- **Delete** `ServiceTaskDispatcher.catalog_lookup_stub/2` (`service_task_dispatcher.ex:400-416`).
  It has no production caller other than line 764; it is public but only referenced by tests
  and docs (grep-verified: `lib/`, `test/`, decision records 0027/0029 historically). A stub
  that can only answer "not registered" would now be an actively misleading second source of
  truth next to the real resolver.
- **Keep the `:catalog_service` `case` arm** in `do_attempt_dispatch/2`
  (`service_task_dispatcher.ex:739-785`) but change its meaning: it no longer looks anything up.
  It is **snapshot-driven**: read `row.config_snapshot["rendered_url"]` exactly as the
  `:inline_url` arm does, and run the same `http_transport/3` -> `classify_failure_kind` ->
  `handle_success/handle_failure` sequence. The two arms may be merged into one clause
  guarded on `route_kind in [:inline_url, :catalog_service]`; the audit value
  `"catalog_service"` stays in the snapshot.
- Defensive rule (new, tested): a `:catalog_service` row whose `rendered_url` is nil, empty or
  non-binary is classified `:request_build_error` and given up, with **zero** `:httpc` calls --
  the same fail-closed outcome the stub produced for a malformed row.
- `http_transport/3` is **not modified**. The SSRF gate (`UrlValidator.validate/2`, immediately
  before `:httpc.request/4`, `service_task_dispatcher.ex:335-343`) is therefore applied to every
  catalog dispatch, on every attempt, by construction (INV-9, INV-STD-1).
- `ServiceTaskDispatcher` still never calls `Letflow.Engine.*` or the catalog (scope boundary
  preserved): the catalog is consulted only at activation, by the engine.

### 4.2 Existing tests that MUST change

| File:lines | Today | Required change |
|---|---|---|
| `test/letflow/engine_test.exs:1220-1250` | expects `{:activation_failed, {:service_task_url_rendered_empty, "svc"}}` for a fixture whose const `pin_lookup` returns `resolved_id: "sid"` but NO catalog row exists | Flip to `{:activation_failed, {:service_task_catalog_unresolved, "svc", :version_not_found}}`; rewrite the long explanatory comment (it documents the removed limitation). Count assertions (projection 0, event 0, snapshot 1) stay |
| `test/letflow/engine/service_task_dispatcher_test.exs` ~201-212 (`describe "catalog_lookup_stub/2"`) | asserts the stub's unconditional error | Delete the describe block. Do NOT replace it with a `function_exported?`/grep-shaped "stub is gone" assertion (`docs/anti-patterns.md`, "A grep-shaped acceptance criterion can be tripped by the module's own moduledoc"); the behaviour tests in the next row prove the stub's effect is gone |
| same file ~216-300 (`describe "route_kind: :catalog_service is routed to catalog_lookup_stub/2..."`) | proves a `:catalog_service` row gives up without HTTP | Replace with: (a) row with allowed https `rendered_url` and SSRF gate ON -> dispatch goes through the gate (blocked/unresolvable host -> `:request_build_error`/network class, never the old unconditional give-up); (b) gate OFF (existing `:service_task_ssrf_validation_enabled` seam) + local test server -> `{:advance, decoded_body}`; (c) `rendered_url` nil/empty -> give up with zero requests (the live-listener "nothing ever connects" technique at ~32-76 is reusable); (d) a blocked-range URL (e.g. 169.254.169.254) is rejected before any `:httpc` call (INV-STD-1 for catalog rows) |
| `test/letflow/engine_pin_resolver_catalog_test.exs:127-131` comment | says catalog SERVICE_TASK "always fails validate_rendered_url/1 today" | Update the comment only (the HUMAN_TASK-first fixture remains valid and becomes the basis of the new engine tests) |

Tests that do NOT change: `service_task_wiring_test.exs:500,539` and
`service_task_routing_test.exs:231` use an INLINE `{{variables.missing}}` template (verified),
so they keep passing.

### 4.3 Doc claims that MUST change (DOC-UPDATER / ELIXIR-DEV)

| Location | Change |
|---|---|
| `service_task_dispatcher.ex` moduledoc lines 24-43 ("`route_kind: :catalog_service` -- stub only"), 36-43 BLOCKER paragraph, 50-52 and 77-84 mentions | Rewrite: catalog resolution happens at activation in `Letflow.Engine`; this module dispatches the frozen `rendered_url` for both route kinds |
| `service_task_dispatcher.ex:755-766` inline comment | Remove/replace |
| `lib/letflow/design/service_task_dispatcher.md` section 5.3 and **INV-STD-8** (line 798) and AC row 3 (line 927) | INV-STD-8 is superseded: restate as "a `:catalog_service` row is dispatched only from a URL frozen at activation from the instance's pinned catalog version; a row without a usable `rendered_url` gives up as `:request_build_error` with zero transport calls". Add a dated "superseded by ISS-0917" note rather than silently rewriting history |
| `lib/letflow/design/service_task.md` line ~96 (table row deferring the real lookup to S6) and `service_task.ex:17,130-132` (`catalog_lookup_fun()` type, "no concrete DB-backed catalog exists") | Update/annotate: the type is now unused by the dispatcher; keep or delete the type (OQ-6 -- delete only if no remaining reference) |
| `lib/letflow/design/req373-service-catalog-version-lifecycle.md` (~32-45, 92, 233) and `req432-rebind-pins-publish-retire-ui.md` (M5) | Add a one-line pointer: "dispatch scope gap closed by ISS-0917 (`iss0917-...md`)" |
| `lib/letflow/service_catalog/pin_lookup.ex` moduledoc, `lib/letflow/service_catalog.ex:~109-113`, `entry.ex:~56`, `pin_resolver.ex` moduledoc "SCOPE GAP -- service_catalog (S6)" section | Sentences saying dispatch is not built must be corrected |
| `engine.ex` comment `engine.ex:886-896` ("A route_kind: :catalog_service config reaches step 4 with rendered_url: nil -- deliberately") | Replace with the D2 pipeline description. The anti-pattern "A grep-shaped acceptance criterion can be tripped by the module's own moduledoc" applies: do not word new docs so that a grep for the removed stub name fails |
| `docs/migration/decisions/0027-...md` ("What this record does not decide", sec. 7 point 2, SECURITY-REVIEWER sign-off point 3) | Records are historical and are NOT edited. DOC-UPDATER adds nothing there; the trigger condition ("once the stub is replaced") is handled in section 7 item 4 of this design |
| `docs/issues/ISS-0917.yaml` | Standard close-out by DOC-UPDATER/ISSUE-FIXER |

---

## 5. D4 -- `POST /api/v1/tasks/:id/complete` and `{:instance_execution_error, _, _}`  (acceptance point 4)

### 5.1 Facts

- Source of the 500: `req085-task-routes-write.md` section 5.5.1 last row (line 555) -- a
  catch-all that lists `{:instance_execution_error, _, _}` among "genuine data-integrity /
  downstream failure this caller cannot fix by retrying". No decision record and no
  anti-pattern bears on it (checked `docs/migration/decisions/`, `docs/anti-patterns.md`).
- The tuple is produced by `interpret_complete_result/1` (`engine.ex:~4540-4549`) AFTER the
  Multi commits: the instance is durably in `ERROR` (req061 section 5.4), visible to operators.
  It is not an unhandled exception and not a transient fault.
- No existing router test asserts 500 for this tuple (grep of `test/` for
  `instance_execution_error` found only Engine-level assertions).

### 5.2 Decision: INCLUDE a dedicated minimal clause (not defer)

Add in `Letflow.Routers.Tasks.handle_complete_result/2`, **after** the three 403 clauses that
PR #2087 added and **before** the catch-all, one clause matching
`{:error, {:instance_execution_error, error_type, _affected}}` when `error_type` is an atom and
answering **409 Conflict** via `Response.conflict/2` with a `detail` string built from a fixed
prefix plus only `Atom.to_string(error_type)` (for example "instance entered ERROR status:
service_task_catalog_unresolved"). `affected`, `variables`, `reason` text and `details` are
never echoed (INV-2).

Why include rather than defer to ISS-0933:

1. This fix **creates new, operator-reachable causes** of this tuple on the very endpoint the
   issue names (`service_task_catalog_unresolved`, plus the existing `service_task_url_rendered_empty`
   which the report measured as a 500). Shipping new failure modes behind an unreviewed 500
   that the issue title explicitly calls out would be a known gap in the fix's own scope.
2. It is three lines, no new dependency, no behavioural change to any success path, and no
   existing test pins the 500.
3. Semantics: the request was well-formed and authorised; the resource state (a process whose
   next automatic step cannot be activated) conflicts with completing the task. That is the
   same class the router already answers 409 for `{:task_not_pending, _}`. A 5xx instructs
   clients/alerting that the platform malfunctioned; here the platform behaved as designed and
   the instance is parked in ERROR for an operator -- a 4xx is the correct signal.
4. It does NOT widen into ISS-0933: that issue's tuple (`{:instance_not_active, _}` on an
   already-ERROR instance) is left on the catch-all. This design neither fixes nor blocks it.
   (The same 409 treatment is the natural fix for ISS-0933 and can reuse this clause's
   pattern, but is explicitly out of scope here.)

Scope of the clause: **all** `error_type` values of the tuple, not only `service_task_*`
(no_matching_gateway_edge, variable_schema_rejected, form_*, subprocess_interface_violation
share the identical cause class "committed, instance now ERROR"). Narrowing to service-task
types would give one tuple shape two different statuses for no principled reason. Consequence:
those paths also move 500 -> 409; they have no router-level tests today, so no existing test
breaks. Flagged for REVIEWER as an intentional, bounded widening (OQ-1 asks whether
`variable_schema_rejected` should instead be 422).

### 5.3 REVIEWER sign-off required -- amendment to req085 5.5.1

This **diverges from a design table**. Required amendment text for
`lib/letflow/design/req085-task-routes-write.md` section 5.5.1: add a table row before the
catch-all row: "`{:error, {:instance_execution_error, error_type, _}}` -> 409,
`Response.conflict(conn, "instance entered ERROR status: <error_type>")` -- ISS-0917 amendment;
instance state persisted by design (req061 5.4); detail names only the error_type atom (INV-2)"
and remove `{:instance_execution_error, _, _}` from the catch-all row's member list and from the
router's catch-all comment (the comment block above the catch-all clause lists it; if left, it
becomes a stale claim). REVIEWER must explicitly record approval in its handoff. **Fallback if
REVIEWER rejects:** drop D4 entirely (no router change); every other part of this design stands
unchanged, the happy path is 200, and the unresolved-pin failure remains a 500 documented as
ISS-0933-adjacent. The acceptance tests for the clause (section 6.3) are separable for exactly this reason.

### 5.4 Happy path

With D1-D3 in place, `complete_task/3` for HUMAN_TASK -> catalog SERVICE_TASK returns
`{:ok, %{instance_status: :active, ...}}` (the SERVICE_TASK dispatch is asynchronous via the
poller, so the instance is still `:active` with the SERVICE_TASK token current). The router
already maps this to 200 (`handle_complete_result({:ok, _}, _)`); no change needed.

---

## 6. D5 -- acceptance criteria and test plan  (acceptance point 5)

### 6.1 Acceptance criteria for the fix (derived from the issue + this design)

| ID | Criterion | Element |
|---|---|---|
| AC-1 | Completing a HUMAN_TASK whose successor is a catalog-referencing SERVICE_TASK does not produce `EXECUTION_ERROR`; a `TASK_COMPLETED` event exists; the instance stays `:active`; exactly one `service_task_dispatches` row (`status: "pending"`) is created for the node | D2 |
| AC-2 | That row's `config_snapshot["rendered_url"]` equals the **pinned** version's `endpoint_url` (rendered) and `catalog_version_id`/`catalog_version` equal the pin | section 3.5 |
| AC-3 | After the catalog entry is retired and/or a newer version published, an instance pinned to v1 still dispatches v1's endpoint (v1 now RETIRED-current, or archived) | section 2.3 |
| AC-4 | A rebound pin (`INSTANCE_PINS_REBOUND`, `resolved_id` nil) dispatches the rebound version's endpoint (resolved by `(service_id, version)`); a rebind to a non-existent version yields the typed error, not the live row | D1/D2 |
| AC-5 | Missing pin for the node's `service_id` -> typed error, no row, and the live ACTIVE entry is NOT used | INV-PD-1 |
| AC-6 | Entry owned by another tenant (`scope: :tenant`) or non-existent -> the identical `:version_not_found` outcome (no disclosure) | section 2.3 / INV-5 |
| AC-7 | `required_auth != NONE` -> typed error, no row, no outbound request | section 7 item 1 |
| AC-8 | create/2 with the SERVICE_TASK reachable straight from START behaves per AC-1/AC-2 | section 3.3 |
| AC-9 | Dispatch of the catalog row goes through the SSRF gate; blocked URL -> zero `:httpc` calls | D3 |
| AC-10 | `POST /api/v1/tasks/:id/complete` returns 200 on the AC-1 path | section 5.4 |
| AC-11 | `{:instance_execution_error, error_type, _}` -> 409 with detail naming only `error_type`; no variables/affected echoed (separable, D4) | D4 |
| AC-12 | Inline `:inline_url` behaviour and snapshot shape unchanged (no new keys); other 500 mappings unchanged | regression |
| AC-13 | e2e: see 6.4 | |

### 6.2 ExUnit -- fail-first regression (TEST-DESIGNER implements; keep `describe`/`test` names short, ExUnit's 255-char combined limit is a recorded anti-pattern)

New file `test/letflow/engine_catalog_service_task_test.exs` (basis: the existing
`graph_human_task_then_service_task/1` fixture in `engine_pin_resolver_catalog_test.exs:133`
and its tenant/schema helpers). **Fail-first definition:** T1-T3 and T8 must FAIL on the
current branch with the measured behaviour recorded in the diagnosis (`complete_task` returns
`{:error, {:instance_execution_error, :service_task_url_rendered_empty, {:node, "svc"}}}`,
events `["EXECUTION_ERROR","INSTANCE_STARTED"]`, projection `:error`, zero dispatch rows) and
PASS after the fix. TEST-RUNNER must record the pre-fix failure.

| # | Scenario | Assertions |
|---|---|---|
| T1 | Register global entry v1 (https endpoint), active def START -> HUMAN_TASK -> SERVICE_TASK(service_id) -> END, `Engine.create`, complete the task | `{:ok, %{instance_status: :active}}`; no `EXECUTION_ERROR` event; `TASK_COMPLETED` present; exactly 1 dispatch row `pending`, `route_kind "catalog_service"`, `rendered_url == v1.endpoint_url`, `catalog_version_id == entry.version_id` (AC-1, AC-2) |
| T2 | T1 setup, then **retire** v1 and **publish** v2 (different endpoint) BEFORE completing the task | dispatch row `rendered_url` is v1's endpoint, never v2's; `"timeout_ms"` per `min` rule (AC-3). Variant T2b: retire only (no republish) -> still v1 |
| T3 | create/2 path: START -> SERVICE_TASK(service_id) -> END | `create` returns `{:ok, _}` with 1 dispatch row targeting the pinned endpoint (AC-8) |
| T4 | Rebind: `PinRebind` moves the pin to v2 (published, so it exists in the live row) then complete | dispatch targets v2's endpoint via `{:version, "2"}` (AC-4). T4b: rebind to a version string that does not exist -> `{:instance_execution_error, :service_task_catalog_unresolved, {:node, "svc"}}`, projection `:error`, `details.reason == :version_not_found`, live ACTIVE entry unused |
| T5 | Missing pin: instance whose recorded pins lack the catalog pin (build via an injected `pin_lookup` / crafted INSTANCE_STARTED payload, per the existing `const_pin_lookup` idiom at `engine_test.exs:1220`), live ACTIVE entry exists | typed error `{:pin_missing, :catalog_entry, service_id}` class; zero dispatch rows; **mutant: replacing the error with a live-row lookup must make this test fail** (AC-5) |
| T6 | Tenant isolation: entry `scope: :tenant` owned by tenant A; an instance in tenant B whose pin references it (injected pin_lookup) | outcome identical (same reason atom, same shape) to a pin referencing a non-existent service_id (AC-6). **Mutant: removing the visibility check must make this fail** |
| T7 | `required_auth: :API_KEY` entry | typed error `{:required_auth_unsupported, :API_KEY}` class; zero rows; no transport call (AC-7) |
| T8 | Chained sites: (a) SERVICE_TASK(inline) -> SERVICE_TASK(catalog) resolved through `advance_after_service_task_outcome` (forces the `:reconstruct` path with pins from the event log); (b) TIMER -> SERVICE_TASK(catalog) through the timer-fire site | row created with the pinned endpoint in each (section 3.3 table rows 3-5). Where a site's harness is disproportionate, TEST-DESIGNER documents which site is covered by T1's completion-hop path only and why |
| T9 | Regression: inline SERVICE_TASK snapshot has NO `catalog_*` keys and identical other keys | AC-12 |

`test/letflow/service_catalog_resolve_pinned_version_test.exs` (new; resolver unit matrix,
section 2.3/2.5): live current ACTIVE by `version_id`; live RETIRED current by `version_id`; archived
by `version_id`; by `(service_id, version)` live and archived; version_id belonging to a
different service -> `:not_found`; global visible to any tenant; `scope: :tenant` owner ok;
`scope: :tenant` other tenant -> `:not_found`, **indistinguishable** (`==`) from a missing
service; deleted live row -> `:not_found`; unknown version -> `:not_found`. Also assert
`get_for_tenant/2` behaviour unchanged (shared predicate).

`test/letflow/engine/service_task_dispatcher_test.exs` -- replaced blocks per D3 (section 4.2) above.

### 6.3 Router tests (`test/letflow/routers/tasks_test.exs`)

- **R1 (AC-10, fail-first):** full stack through the router: HUMAN_TASK -> catalog SERVICE_TASK,
  `POST /api/v1/tasks/:id/complete` -> **200** and body `instance_status` `"active"`. Pre-fix:
  500 (measured by the report).
- **R2 (AC-11, separable):** same graph but the pin resolves to a non-existent version (injected
  pin_lookup) -> **409** problem document; `detail` contains `service_task_catalog_unresolved`
  and does NOT contain the node id's variables, any variable value, the service_id, or the URL.
- **R3:** a different catch-all member (for example a forced `{:graph_structure_invalid, _}`
  where the harness allows, otherwise left to the existing unit coverage) still maps to 500.
- Because PR #2087 is merged on main, R1/R2 must use an actor that passes
  `Tasks.authorize_completion/3` (unassigned HUMAN_TASK is permissive; or assign to the actor).

### 6.4 e2e pipeline spec -- `web/tests/e2e/pipelines/platform-instance-pin-survives-catalog-change.pipeline.e2e.spec.ts` (FRONTEND-DEV)

Current state: header "Scope note (deliberately not exercised)" lines ~49-61; step 03 (line
243) retires v1 then publishes v2 (asserts version "2"/ACTIVE); step 04 (line 296) asserts the
pins panel still shows v1; the HUMAN_TASK is never completed; seeded endpoints are
`https://example.test/...` (not resolvable).

Design constraints discovered:
- Step 06 rebinds the long-running case and needs it non-terminal; completing its task would
  put it on a path that reaches END. **Do not complete the existing `longRunningCaseId`.**
- No HTTP API exposes `service_task_dispatches` (grep of `routers/` is empty); the e2e cannot
  read `rendered_url` directly. `GET /api/v1/instances/:id/history` (`routers/instances.ex:367`)
  and `GET /api/v1/instances/:id` expose events/status.
- The SSRF gate blocks localhost and non-https; `example.test` does not resolve.

Decision:
1. **State addition.** Add `pinDispatchCaseId` (a *second* in-flight case, started in step 02
   from the same definition via the existing `startInstanceViaGui`, so it pins v1 exactly like
   the long-running case). Add it to the cleanup list.
2. **Controllable endpoints (ISS-0930 precedent).** Read `process.env.SERVICE_TASK_MOCK_BASE_URL`
   with the same default the QA seed uses (httpbin.org family, see `docs/issues/ISS-0930.yaml`
   residual_risk and `lib/letflow/design/iss0930-seed-service-task-endpoints.md`). In step 01
   register v1 with `endpoint_url = <mock>/anything/shared-connection/v1` (2xx + JSON object
   body, which `classify_failure_kind/1` requires); in step 03 publish v2 with
   `endpoint_url = <mock>/status/503` (a deliberate trap: if the dispatch wrongly used the live
   v2 it would fail/retry and the case would not advance). The URL values are not asserted
   anywhere else in the spec today (verified: only lines 178 and 275 set them), so changing
   them is safe. Both must be https and public.
3. **New step "04b" (placed after step 04 and before step 05, so existing step numbers and
   the 05-07 rebind flow are untouched):** via API, find the pending task of
   `pinDispatchCaseId` (`GET /api/v1/tasks?instance_id=...&status=...`, router
   `routers/tasks.ex:165-191`), complete it with `POST /api/v1/tasks/:id/complete`, and assert:
   (a) HTTP **200** (the ISS-0917 acceptance), body `instance_status` `active`;
   (b) the instance does not reach `ERROR`: poll `GET /api/v1/instances/:id` with a bounded
   timeout (>= 3 poller intervals + one backoff; the dispatcher poll interval default is 5 s)
   until `status` is `COMPLETED` (the endpoint returned 2xx JSON, so the SERVICE_TASK advanced
   to END) -- fail with a clear message if it is `ERROR` or times out;
   (c) `GET .../history` contains no `EXECUTION_ERROR` event.
   Because v2's endpoint is a failing trap, reaching COMPLETED proves the dispatch used v1's
   pinned endpoint (this is the e2e's substitute for observing `rendered_url` directly).
4. **Honest limits to state in the spec header (replace the "Scope note"):** (b) depends on the
   poller running in the target environment and on outbound access to the mock host. If the
   target cannot satisfy that, the spec must NOT silently weaken: it fails the step when the
   poller is expected (`assertServiceReadiness` already gates the environment), and the
   endpoint-identity assertion remains covered at the ExUnit level (T1/T2). If the
   mock host/poller is unavailable the (b)-(c) assertions are the only part allowed to be
   skipped via an explicit, loudly-logged `test.skip` keyed on an env var, never an empty
   assertion (OQ-7 asks the orchestrator whether the e2e environment runs the poller).
5. Assertions (a) and (c)'s "no EXECUTION_ERROR at the moment of completion" need no network
   and no poller and are unconditional.
6. Authorization: PR #2087 (merged) makes the completing actor subject to
   `Tasks.authorize_completion/3`. The fixture's HUMAN_TASK attrs are `assignee_type: 'user',
   assignee_ref: 'admin-user'` (spec line 204); the completing token must be that user, or the
   fixture assignee adjusted (FRONTEND-DEV verifies against `Tasks.authorize_completion/3`;
   do not weaken the check).

### 6.5 Scenario `test/fixtures/uat/scenarios/platform/instance-pin-survives-catalog-change.yaml`

The file header says it is "byte-identical" to R-Co's commit except the comment block and the
`pipeline_test` annotation; **EO-001/EO-004's prose and step 3 are NOT edited** (they already
state the target behaviour: "The case ... carries on, using the version it was given", "completes
the step that uses the retired version without error"). Only the header comment block is
extended, by DOC-UPDATER: a note that step 3 / EO-001 / EO-004 are now verified by the pipeline
spec's new step 04b (HTTP 200 + case reaches COMPLETED via the pinned v1 endpoint) and by
ExUnit T1/T2, replacing the "unverified" gap recorded by ISS-0917.

---

## 7. D6 -- security notes for SECURITY-REVIEWER  (acceptance point 6)

Tenant data path: yes (global catalog read on behalf of a tenant instance; outbound request
whose URL is tenant-authored for `scope: :tenant` entries).

1. **`required_auth` -- OUT OF SCOPE; FAILS CLOSED.** `http_transport/3` (`service_task_dispatcher.ex:304-358`)
   implements no authentication, and there is no per-tenant secret-reference mechanism wired
   into the dispatcher (INV-4: secrets by reference only; none would be in the snapshot).
   For `required_auth` in `:API_KEY | :OAUTH2 | :MUTUAL_TLS` the activation step returns
   `{:required_auth_unsupported, auth}` (section 3.4 step 6): instance ERROR (completion path) /
   activation failure (create path), no dispatch row, no outbound request. Justification:
   silently sending an unauthenticated request to a service that declares it requires auth
   (a) is wrong by the catalog's own contract, (b) wastes the retry budget on a deterministic
   401/403, (c) for MUTUAL_TLS may disclose request bodies to an endpoint that would never
   accept them, and (d) hides the gap from operators. Fail-closed gives an immediate,
   visible, non-disclosing error. Cost: auth'd catalog entries still cannot execute -- exactly
   today's behaviour, so no regression. Implementing auth is a separate requirement; record as
   a follow-up issue (ORCH files it). The e2e/fixtures use `auth_method: 'NONE'` (spec line 180).
2. **Tenant scoping (INV-1, INV-5, INV-6).** `service_catalog` / `service_catalog_versions` are
   GLOBAL tables (public schema; decision 0003 B deviation, `entry.ex` moduledoc). Visibility
   is app-level: D1 applies the `get_for_tenant/2` three-way rule through a shared predicate;
   `tenant_id` is derived by the Engine from the tenant schema prefix
   (`TenantProvisioning.tenant_id_for_schema_name/1`), never from request/attrs/variables.
   `version_id` / `version` come only from the instance's own event-sourced pins in the
   tenant schema (`create/2` `pins`, or `reconstruct_effective_pins/2`). Invisible == not
   found, single atom `:not_found`, and the Engine maps it to the single reason
   `:version_not_found` -- the HTTP layer additionally exposes only the error_type atom (D4).
   Archive rows have no scope/owner: visibility is inherited from the live row of the same
   `service_id`, and a `version_id` is bound to its `service_id` (cross-service id -> not found).
   INV-6: new data-access path -> the resolver unit matrix (6.2) is the scoping proof.
3. **SSRF (INV-9).** No change to `http_transport/3`; the URL is validated by
   `UrlValidator.validate/2` immediately before `:httpc.request/4` on every attempt, for
   catalog rows exactly as for inline rows (section 4.1, test AC-9). The rendered URL is frozen at
   INSERT (no re-render, no re-resolve at attempt time), so a catalog edit after activation
   cannot redirect an in-flight dispatch.
4. **Decision record 0027 trigger.** 0027's SECURITY-REVIEWER sign-off (point 3) recorded that
   `POST /service-catalog` (`admin_services.ex` `handle_register/1`, `Entry` changeset) performs
   NO URL/SSRF check at registration (only `validate_length max 2048`) and that "once
   `catalog_lookup_stub/2` is replaced with a real lookup ... [it] becomes a live INV-9
   question that requirement will need to answer". **This is that requirement.** The answer in
   this design: the dispatch-time gate (section 4.1) is the control; registration-time validation is
   NOT added here (separate surface, different owner `ELIXIR-DEV` admin route). SECURITY-REVIEWER
   must either accept the dispatch-time gate as sufficient or require a follow-up issue for
   registration-time validation; the design flags it explicitly so it is decided, not assumed.
   Packed `service_catalog_entries` stay rejected (0027 unchanged).
5. **No logging / echo (INV-2, INV-8).** The new code must not `Logger` or place into error
   `reason`/`details`/HTTP detail: `variables`, `headers`, `body_template`, the rendered URL,
   the endpoint, or `service_id`. `details` carries the reason atom class only. The existing
   `variables` field of `error_args` is persisted by the existing empty-URL precedent
   (`build_service_task_empty_url_error/5`) into the tenant's own ERROR record; the new builder
   does the same and no more.
6. **Crash safety (INV-8).** The new resolution path runs inside the completion Multi's
   pre-flight; every failure is a typed tuple. `resolve_pinned_version/3` must not raise on
   malformed pin data (a non-UUID `resolved_id` string: use `Ecto.UUID.cast/1`-style validation
   and return `:not_found`, not a cast exception).
7. **No new secrets, no SQL interpolation (INV-7):** Ecto queries with bound parameters only.

---

## 8. D7 -- migration  (acceptance point 7)

**None.** Confirmed: `service_catalog` and `service_catalog_versions` already hold every field
used (`entry.ex:93-117`, `version.ex:22-36`); `service_task_dispatches.config_snapshot` is a
`:map` (jsonb) column and gains keys only. No new index is required: both new reads are by
primary key (`service_catalog.service_id`, `service_catalog_versions.version_id`) except the
rebound `(service_id, version)` lookup on the archive -- **verify** that
`service_catalog_versions` has a unique index covering `(service_id, version)`
(`check_publishable_version/2` queries it); if the table lacks one the lookup is still correct
(tiny table), and adding an index is explicitly deferred (OQ-8), not part of this fix.

---

## 9. D8 -- owned files and coordination  (acceptance point 8)

### 9.1 Files ELIXIR-DEV may change

| File | Change |
|---|---|
| `lib/letflow/service_catalog.ex` | add `resolve_pinned_version/3`; extract shared visibility predicate used by `get_for_tenant/2` |
| `lib/letflow/engine.ex` | D2: `resolve_service_task_arm_attrs`, `prepare_service_task_dispatch` (/6), `config_snapshot_map` optional audit arg, wrappers at the five call sites, new error channel at the completion hop and the `_abort_` wrapper, comment at 886-896 |
| `lib/letflow/engine/service_task.ex` | `build_catalog_unresolved_error_attrs/1`; annotate/remove `catalog_lookup_fun()` type (OQ-6) |
| `lib/letflow/engine/service_task_dispatcher.ex` | delete stub, snapshot-driven `:catalog_service` arm, moduledoc |
| `lib/letflow/routers/tasks.ex` | D4 clause + catch-all comment edit (only if D4 approved) |
| `lib/letflow/design/req085-task-routes-write.md` | 5.5.1 amendment (section 5.3) |
| `lib/letflow/design/service_task_dispatcher.md`, `service_task.md`, `req373-...md`, `req432-...md` | doc updates per section 4.3 |
| `test/letflow/engine_catalog_service_task_test.exs` (new), `test/letflow/service_catalog_resolve_pinned_version_test.exs` (new), `test/letflow/engine/service_task_dispatcher_test.exs`, `test/letflow/engine_test.exs`, `test/letflow/engine_pin_resolver_catalog_test.exs` (comment), `test/letflow/routers/tasks_test.exs` | per section 6 (TEST-DESIGNER owns test code) |
| `web/tests/e2e/pipelines/platform-instance-pin-survives-catalog-change.pipeline.e2e.spec.ts` | FRONTEND-DEV, section 6.4 |
| `test/fixtures/uat/scenarios/platform/instance-pin-survives-catalog-change.yaml` | header comment only (6.5) |

Not touched: `priv/repo/migrations/`, `lib/letflow/service_catalog/pin_lookup.ex` (behaviour
unchanged; moduledoc sentence only), `lib/letflow/engine/pin_resolver.ex` (no change -- used
read-only), `lib/letflow/engine/transition.ex`, `http_transport/3`.

### 9.2 Coordination

- **PR #2087 (ISS-0942) -- MERGED on origin/main (0b1931d3), not in this branch.** It rewrote
  `Routers.Tasks.handle_complete/3` (calls `Tasks.authorize_completion/3`), added three 403
  clauses immediately before the catch-all (the exact insertion point of D4's clause), and edited
  doc-comment hunks in `engine.ex` (moduledoc ~120-135, ~1931; no overlap with activation code).
  **ORCH action:** merge/rebase `origin/main` into `feature/WF03-ISS0917-20261001` BEFORE
  dispatching ELIXIR-DEV (branch line numbers in this doc shift in `routers/tasks.ex` and
  `engine.ex` comments only). The D4 clause goes AFTER the three 403 clauses.
- **PR #2089 (ISS-0918, open)** touches `instances.ex`, `routers/instances.ex`,
  `routers/admin_services.ex`, tests, `docs/issues/ISS-0918.yaml`. No file overlap with this
  design (`gh pr diff 2089 --name-only`). Semantic overlap only on `retry_policy` surfacing:
  this fix stores it audit-only and does not interpret it (section 3.8). If #2089 changes the
  `retry_policy` representation, only the audit key's value changes.
- **ISS-0933 (open, GH-2067):** untouched by this design (D4 point 4).
- Other in-flight work in `engine.ex`: the activation region (lines ~851-970) is a hot file;
  ELIXIR-DEV should rebase immediately before merge (see memory/anti-pattern on merge races).

---

## 10. Invariants

| ID | Invariant |
|---|---|
| INV-PD-1 | A catalog SERVICE_TASK dispatch is resolved ONLY from the instance's own effective pin. Any failure to read/resolve the pin is a typed error; the live current catalog row is never a fall-back |
| INV-PD-2 | Resolution happens at activation and is frozen: `config_snapshot["rendered_url"]` is the only URL the dispatcher ever uses for the row; the dispatcher never calls the catalog |
| INV-PD-3 | A RETIRED current version and an archived version both resolve for an instance pinned to them |
| INV-PD-4 | Invisible-to-tenant is indistinguishable from non-existent at every layer (resolver atom, engine reason, HTTP) |
| INV-PD-5 | `required_auth != NONE` never produces an outbound request or a dispatch row |
| INV-PD-6 | The inline SERVICE_TASK path (route_kind `:inline_url`) is behaviourally and structurally unchanged |
| INV-PD-7 | `tenant_id` used for visibility is derived from the tenant schema prefix, never from caller input |

---

## 11. Acceptance-criteria map (handoff criteria -> design elements)

| Handoff acceptance criterion | Where satisfied |
|---|---|
| Design file exists, no implementation code | this file; only types/tables/prose, no fenced code |
| Every point (1)-(8) addressed with decision and rationale | (1) section 2; (2) section 3; (3) section 4; (4) section 5; (5) section 6; (6) section 7; (7) section 8; (8) section 9; binding docs check: section 0.1 item 7, section 4.3, section 7.4 |
| Fail-first regression test plan with concrete scenarios | section 6.2 (T1-T9 + resolver matrix), 6.3 (R1-R3), 6.4 (e2e) |
| 500-mapping decision explicit with REVIEWER-signoff note if diverging | section 5.2 (decision), 5.3 (amendment text, REVIEWER sign-off, fallback) |

---

## 12. Open questions (not silently resolved)

| ID | Question | Default if unanswered |
|---|---|---|
| OQ-1 | Should `variable_schema_rejected` (a data-validation cause) map to 422 rather than the uniform 409 for `{:instance_execution_error, _, _}`? | Uniform 409; REVIEWER may split |
| OQ-2 | Is `min(node timeout_ms, catalog timeout_ms)` the desired merge, versus catalog-wins? | `min` (conservative; bounded by both parties) |
| OQ-3 | Should `ServiceCatalog.delete/1` be blocked while non-terminal instances are pinned to the service (today it checks only ACTIVE definitions)? Out of scope here; a deleted entry makes pinned instances ERROR with `:version_not_found` | File a follow-up issue; not part of this fix |
| OQ-4 | Confirm `PinRebind.rebind_pins/3` takes the same instance row lock the completion hop holds (so reconstruct-in-hop cannot race a rebind) | If it does not, the worst case is dispatching the pre-rebind version for one hop -- still a valid pin; ELIXIR-DEV verifies and notes |
| OQ-5 | Timer-fire / escalation / service-outcome sites do not route catalog errors into ExecutionError (they roll back the attempt). Should they? | No -- same scope boundary as the existing empty-URL wrapper; separate issue if desired |
| OQ-6 | Delete the now-unused `ServiceTask.catalog_lookup_fun()` type or keep it? | Delete if no remaining reference after the stub is removed; otherwise keep with a note |
| OQ-7 | Does the e2e target environment run the SERVICE_TASK dispatcher poller (`:start_service_task_dispatcher`) and have outbound HTTPS to the mock host? Determines whether step 04b's COMPLETED assertion is enforceable or must be the loud-skip variant | ORCH confirms before FRONTEND-DEV starts |
| OQ-8 | Is there a unique index on `service_catalog_versions (service_id, version)`? Needed only for efficiency of rebound lookups | Not added by this fix |
| OQ-9 | Child instances started by SUB_PROCESS do not call `prepare_service_task_dispatch` from `sub_process.ex` (grep-verified: no SERVICE_TASK handling there); a child whose first node after START is a SERVICE_TASK is unchanged by this fix | Out of scope; unchanged pre-existing behaviour |
| OQ-10 | `PinLookup.catalog_lookup/1` is untenanted (diagnosis side-finding). Not changed here | ORCH files a separate issue |
