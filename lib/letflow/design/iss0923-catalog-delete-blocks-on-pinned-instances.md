# WF-03 Fix Design -- ISS-0923 (catalog delete orphans pinned in-flight instances)

Run-id: WF03-ISS0923-20261001
Type: context-module guard + one router clause + one error constructor + test/doc updates.
**Design only -- no implementation code in this document.**
Issue: `docs/issues/ISS-0923.yaml` (queue Q-923, GH-2097, MINOR). Diagnosis:
`handoffs/WF03-ISS0923-20261001/step-01-issue-fixer-diagnose.json` (result.summary).
Origin: `lib/letflow/design/iss0917-catalog-service-task-pinned-dispatch.md` OQ-3 (accepted there as out of scope).
Chain: CODE-DESIGNER -> CODE-DESIGN-VALIDATOR -> ELIXIR-DEV -> SECURITY-REVIEWER (mandatory,
tenant data path) -> REVIEWER -> TEST-DESIGNER -> TEST-RUNNER.

---

## 0. Facts re-verified against code (this branch)

| Claim | Where | Result |
|---|---|---|
| `delete/1` gates only on ACTIVE definitions | `service_catalog.ex` `delete/1` (def ~:880), `referencing_active_definitions/2` (~:940), `query_referencing_definitions/2` (~:960, `p.status == :active`) | CONFIRMED |
| Only caller of `delete/1` in `lib/` is the admin router; its `case` has no catch-all | `routers/admin_services.ex` `handle_delete/2` (~:274-288) | CONFIRMED: an unmapped tuple raises `CaseClauseError` (INV-8). The new clause is mandatory |
| Non-terminal == `:active`, `:error` | `event_store/instance_projection.ex:223-225` (`terminal?/1`: `:completed`, `:cancelled` terminal) | CONFIRMED |
| Projection PK `instance_id`; snapshot PK `instance_id`; both per-tenant schema | `instance_projection.ex:136-137`, `definitions/instance_definition_snapshot.ex:93-94` | CONFIRMED |
| `service_catalog_versions` has no FK to `service_catalog` | migration `20260921000004_add_service_catalog_versioning.exs:70-93` | CONFIRMED |
| `Version` rows are read only via `ServiceCatalog` (resolver and publish/retire paths) | grep `lib/` for `Version` / `service_catalog_versions` | CONFIRMED: no other reader. Deleting a deleted service's version rows cannot break a third module |
| No OpenAPI spec and no `web/src` consumer of the 409 problem type | grep of `web/src`, `docs/`, `priv/` for `referenced-by-active` / `definition_ids` | CONFIRMED: only decision record 0026, `requirements.yaml`, status yaml, and design md files mention it. No machine-readable API doc to update |
| Route is PLATFORM_ADMIN-only | `admin_services.ex` moduledoc lines 33-47 (`:AdminServicesManage` held only by PLATFORM_ADMIN) | CONFIRMED; unchanged by this fix |

---

## 1. Decisions at a glance

| # | Decision | Section |
|---|---|---|
| D-A | BLOCK (not document-only) via a second guard in `ServiceCatalog.delete/1` | 2 |
| D-B | Error shape `{:error, {:referenced_by_active_instances, instance_refs()}}` with a capped, flat id list plus a `truncated` flag; no tenant ids, no totals | 3 |
| D-C | `:error` instances BLOCK (non-terminal == `not InstanceProjection.terminal?/1`) | 4 |
| D-D | Order: not_found, then active-definitions guard, then instances guard | 5 |
| D-E | TOCTOU between guard and delete: ACCEPTED, no lock; documented in `@doc` | 6 |
| D-F | Orphaned `service_catalog_versions` rows: IN SCOPE; deleted atomically with the entry in one transaction | 7 |
| D-G | HTTP: new 409 problem type `service-referenced-by-active-instances`; mandatory `handle_delete` clause | 8 |
| D-H | `@spec`/`@doc` changes | 9 |
| D-I | Acceptance criteria and test seams | 10 |
| D-J | Security notes | 11 |
| D-K | Out of scope / follow-ups | 12 |
| D-L | Open questions | 13 |

---

## 2. D-A -- block vs document: BLOCK

The diagnosis recommendation stands; no reason to reverse it was found. Reasons: (1) the
pinning contract from ISS-0917 is "no fallback, ever": an in-flight instance keeps its pinned
version, and a live-row delete makes every pinned version (live and archived) unresolvable
(`resolve_pinned_version/3` consults the live row first as the visibility authority), turning
a healthy instance into an ERROR instance with `service_task_catalog_unresolved` /
`:version_not_found`; (2) the cost is one extra read-only per-tenant loop; (3) documentation
alone leaves a trap the admin cannot see from the delete response; (4) the cure for the
admin is available and visible (cancel or complete the listed instances, or retire the entry
instead of deleting it; retire keeps pinned resolution working).

Mechanism: a SECOND guard in `Letflow.ServiceCatalog.delete/1`, after the existing
active-definitions guard. A private function, named `referencing_non_terminal_instances/2`
(name binding for tests is not required; the behaviour is), computes the referencing
instance ids across every provisioned tenant schema.

### 2.1 The query (specified as data flow, not code)

Per tenant schema (prefix taken ONLY from `TenantProvisioning.list_registrations/0`'s
`schema_name`, exactly as `referencing_active_definitions/2` does):

- Source: tenant-schema `instance_projections` (`Letflow.EventStore.InstanceProjection`)
  joined on `instance_id` to tenant-schema `instance_definition_snapshots`
  (`Letflow.Definitions.InstanceDefinitionSnapshot`, write-once, one row per instance).
- Filter 1 (status): projection `status` is NOT terminal, i.e. in `[:active, :error]`. The
  filter list is derived from `InstanceProjection` (one authoritative definition of
  terminality, `terminal?/1`) -- the implementer must not hard-code a second copy that can
  drift; a module attribute computed from `terminal?/1` over the status enum values, or a
  literal list pinned by a test that iterates the Ecto.Enum values against `terminal?/1`,
  both satisfy this.
- Filter 2 (reference): the snapshot's `graph` jsonb has a node with `node_type = 'SERVICE_TASK'`
  whose `attributes.service_id` EQUALS the bound `service_id`. Same structural
  `jsonb_array_elements` / `EXISTS` fragment as the existing `@service_task_reference_fragment`
  (`service_catalog.ex` ~:952-958), pointed at the snapshot graph. The existing attribute is
  parameterised on the graph column and the service id, so the implementer SHOULD reuse that
  fragment attribute for both queries (one definition of "references the service", not two).
  Equality on the extracted text, never `LIKE`/substring (a different service id that merely
  contains this one must not match).
- Select: `instance_id` only; ordered by `instance_id` ascending for determinism; per-tenant
  `LIMIT` of `cap + 1` (cap defined in section 3).
- Binding: `service_id` bound as a query parameter. No interpolation of schema name or
  service id into SQL text (INV-7).
- No new index and no migration. `idx_proj_status` (migration `20260816120003`) is a partial
  index; ACTIVE rows are index-assisted, ERROR rows are scanned. Cost is per-tenant-loop,
  the same stated and accepted cost as REQ-191 design OQ-2.

Why a snapshot-graph match is a valid proxy for "pinned to the service": `PinResolver`
extracts `("SERVICE_TASK", "service_id") -> :catalog_entry` refs from the graph at start, so
every referenced service id is pinned; a rebind (`INSTANCE_PINS_REBOUND`) changes the version
of an existing ref, never the ref set. The over-approximation (a node on a branch never
reached still blocks) errs on the safe side. The authoritative pin (event-sourced
`INSTANCE_STARTED.pinned_versions`) is deliberately NOT queried: events have no jsonb index
and no projection column carries pins.

Cross-tenant iteration: reduce across registrations and STOP querying further tenants as soon
as the accumulated id count exceeds the cap (early exit bounds work on a large deployment).

---

## 3. D-B -- typed error shape and what it exposes

### 3.1 Shape

`{:error, {:referenced_by_active_instances, instance_refs}}` where `instance_refs` is a map
with exactly two keys:

- `instance_ids :: [Ecto.UUID.t()]` -- at most `@max_reported_instance_ids` entries (cap = 50,
  a module attribute in `Letflow.ServiceCatalog`), collected tenant by tenant in
  `list_registrations/0` order, ids ascending within a tenant.
- `truncated :: boolean()` -- true when more than the cap exist.

Named type: `instance_refs() :: %{instance_ids: [Ecto.UUID.t()], truncated: boolean()}`,
added beside `reference_conflict()`.

### 3.2 What it deliberately does NOT carry

- No tenant ids and no tenant grouping. The active-definitions guard returns a flat
  `definition_ids` list without tenant ids for delete (tenant ids appear only in the
  update_scope narrowing shape). Matching that, instance ids are the same exposure class:
  opaque UUIDs, visible only to a PLATFORM_ADMIN caller on a route that is explicitly
  cross-tenant. Tenant ids add nothing the admin needs to act (instance ids are UUIDs, the
  admin instance tooling resolves them) and would add a tenant-enumeration surface.
- No total count (would require counting every tenant fully; the `truncated` flag gives the
  admin the one bit they need, and a second delete attempt after cancelling shows progress).
- No instance status, variables, definition ids, process names, or any payload.

### 3.3 Justification against `security-invariants.md`

- INV-1: access is `prefix:`-scoped per registered tenant schema; the prefix comes from
  server-held registrations, never request input; the endpoint is the platform-admin
  cross-tenant surface by design (admin_services moduledoc "Cross-tenant-404").
- INV-2: response exposes only opaque ids plus a boolean; no tenant business data.
- INV-5: this route is not a tenant-visibility boundary (404 means "no such service_id"
  only), so the two-state not-found/blocked distinction is not an enumeration leak.
- INV-7: parameterised query only.
- INV-8: new tuple has a router clause (section 8); no crash path.
- Bounded response size: the cap prevents an unbounded id list in the problem document.

---

## 4. D-C -- do ERROR instances block? YES

Non-terminal is defined as `not InstanceProjection.terminal?(status)`, i.e. `:active` and
`:error`. Reasons: (1) `terminal?/1` is the project's single authoritative notion of "can still
be appended to"; `:error` is explicitly non-terminal there; (2) an instance parked in ERROR for
an unrelated reason is retryable/resumable and would, once resumed, hit the same pinned
resolution failure if the entry is gone; (3) an ERROR instance already stuck on THIS service
(for example a retired-and-unresolvable pin) blocks deletion until an operator cancels it,
which is the intended escape hatch and gives the admin a visible list of what to clean up.
Cost of the choice: a long-parked ERROR instance holds a delete; accepted and documented in
`@doc`. A future "force delete / ignore ERROR" option is a follow-up, not part of this fix.

---

## 5. D-D -- guard ordering

Order inside `delete/1` (normative):

1. `Repo.get(Entry, service_id)` -> nil gives `{:error, :not_found}` (unchanged).
2. Active-definitions guard (unchanged) -> `{:error, {:referenced_by_active_definitions, ids}}`.
3. NEW non-terminal-instances guard -> `{:error, {:referenced_by_active_instances, refs}}`.
4. Transactional delete (section 7).

Only the FIRST failing guard is reported; the two are not merged. Rationale for definitions
first: (a) it is cheaper (one definitions table, no join); (b) an ACTIVE definition is the
only way a NEW instance referencing the service can START, so once guard 2 passes (no ACTIVE
referencing definition at that instant), the set of referencing non-terminal instances can
only shrink (instances complete or are cancelled), which makes guard 3's snapshot of the
world stable apart from the narrow window in section 6; (c) it keeps existing behaviour
(error precedence, existing tests) byte-identical for the ACTIVE-definition case. A caller
who clears the definition conflict and retries may then see the instance conflict; this is
documented in `@doc`.

---

## 6. D-E -- TOCTOU between guard and delete: ACCEPTED, DOCUMENTED, NO LOCK

Window: after guard 3 returns empty and before the transaction deletes the entry, an
instance referencing the service could be created. Preconditions for it: a definition
referencing the service must be (or become) ACTIVE inside that window -- guard 2 just
reported none ACTIVE, so this needs a concurrent definition activation (or activation of an
already-published definition) AND a concurrent `Engine.create/2`, both within the few
milliseconds of one request. Outcome if it happens: that instance goes to ERROR on its next
resolution, which is exactly today's behaviour for the whole class, i.e. a strict
improvement over no guard. It is the same accepted window the existing definitions guard has
(see the comment above `delete_entry/1` about the per-tenant loop window).

Why no lock/transaction around the checks:
- The data being protected lives in N tenant schemas; a row lock on the public
  `service_catalog` entry would not be taken by `Engine.create/2` (which does not read the
  entry at start; resolution happens later through `resolve_pinned_version/3`), so locking
  the entry would not serialize the racing writer. A real fix would require the engine to
  take a shared lock on the catalog row at start, which is an engine change out of scope for
  a MINOR admin-delete guard and would add a hot-path cost to every instance start.
- `pg_advisory_xact_lock` keyed on the service id around both sides would need the same
  engine cooperation.

`delete/1`'s `@doc` MUST state: the check is advisory against concurrently starting
instances; callers needing certainty retire the entry (blocks new publishes/starts of new
versions without breaking pins) before deleting. The existing concurrent-delete-of-same-row
handling (`Ecto.StaleEntryError` mapped to `{:error, :not_found}`) must be preserved; see
section 7.

---

## 7. D-F -- orphaned `service_catalog_versions` rows: IN SCOPE

Decision: delete the service's `service_catalog_versions` rows in the SAME database
transaction as the entry row. Not filed as a follow-up, for two concrete reasons:

1. Correctness trap on re-register: after delete, `service_catalog_versions` rows for
   `(service_id, version)` survive. If the same `service_id` is registered again, a new
   incarnation could publish a version string that collides with a surviving archive row (the
   unique index `idx_service_catalog_versions_service_id_version` on the entry side is
   checked by `check_publishable_version/2`, which counts archived versions), producing
   confusing publish rejections; and a `{:version, v}` pin lookup (rebind path) on the new
   incarnation could resolve to the PREVIOUS incarnation's archived endpoint (wrong service
   contract, silent). That is a data-integrity bug introduced by orphaning, not a cosmetic one.
2. It is safe only because of the new guard: with no non-terminal instance pinned, nothing
   in flight can need an archived row. Terminal instances never dispatch again. Verified that
   no other module reads `Version` rows (section 0).

Specified behaviour:
- A single `Repo.transaction` (or equivalent `Ecto.Multi`) containing: delete of all
  `Version` rows where `service_id` equals the deleted id, then delete of the `Entry`.
- No FK is added and no migration is added (the deliberate no-FK decision of
  `20260921000004_add_service_catalog_versioning.exs:84-90` is respected).
- Failure mapping: if the `Entry` row is already gone (concurrent delete),
  `Ecto.StaleEntryError` / delete error maps to `{:error, :not_found}` exactly as today and
  the whole transaction rolls back (archive rows stay, so a retry or the winning concurrent
  delete handles them). The concurrent-delete test at `test/letflow/service_catalog_test.exs`
  ~:429-460 must keep passing unchanged. The implementer must decide where the rescue sits
  (around the transaction call), but must not let the exception escape `delete/1`.
- Order within the transaction: versions first, entry second, so a failure never leaves a
  live entry without its archive rows.
- A zero-row versions delete is success (a never-published entry has no archive rows).
- `delete/1` return values are otherwise unchanged: `:ok` on success.

Out of this decision: `update_scope/2` narrowing (section 12).

---

## 8. D-G -- HTTP mapping and docs

Only caller of `delete/1` in `lib/` is `Letflow.Routers.AdminServices.handle_delete/2`
(`DELETE /api/v1/admin/services/:service_id`). Changes:

1. `lib/letflow/api/error.ex`: new constructor `Letflow.Api.Error.service_referenced_by_active_instances/1`, placed
   immediately after `service_referenced_by_active_definitions/1`.
   - Input type: `instance_refs()` map (section 3.1), guard: is_map.
   - Result `t()`: `type` = `@problems_base <> "service-referenced-by-active-instances"`;
     `title` = "Service Referenced By Active Instances"; `status` = 409; `detail` = a fixed
     sentence ("the service is pinned by one or more non-terminal process instances"); no
     interpolation of ids into `detail`.
   - `extensions`: string keys only (the serialiser encodes JSON): `"instance_ids"` -> the
     list, `"truncated"` -> the boolean.
   - `@spec` with the exact input map type; `@doc` modeled on the sibling.
2. `lib/letflow/routers/admin_services.ex` `handle_delete/2`: add a clause for
   `{:error, {:referenced_by_active_instances, refs}}` that calls
   `Response.send_problem(conn, Error.service_referenced_by_active_instances(refs))`. The
   clause goes after the definitions clause. This is mandatory: without it the new tuple
   raises `CaseClauseError` (INV-8).
3. Doc updates in the same files: the `admin_services.ex` moduledoc section "409
   problem-details bodies (REQ-066, design section 11)" lists the delete 409; extend it to name
   the new constructor and condition. No other doc names the DELETE 409 problem types
   (verified: no OpenAPI file and no `web/src` consumer; `web/` does not need a change, any
   existing 409 handling is status-based and untouched).
4. Add a short pointer row to `lib/letflow/design/req192-service-catalog-routes.md` section 11/12
   (the delete status table, around the line mapping `referenced_by_active_definitions` to 409 at ~:446): "ISS-0923 adds
   `referenced_by_active_instances` -> 409; see `iss0923-...md`". Also a one-line note under
   `iss0917-...md` OQ-3 row marking it closed by ISS-0923. DOC-UPDATER may do these; they are
   doc-only.

---

## 9. D-H -- `@spec` / `@doc` changes (`Letflow.ServiceCatalog.delete/1`)

`@spec` union becomes: `:ok`, `{:error, :not_found}`,
`{:error, {:referenced_by_active_definitions, [String.t()]}}` (unchanged), and the NEW
`{:error, {:referenced_by_active_instances, instance_refs()}}`.

`@doc` rewritten to state: (a) refused when any tenant's ACTIVE process definition graph
references the service (unchanged); (b) additionally refused when any tenant has a
NON-TERMINAL instance (`:active` or `:error`, i.e. not `terminal?/1`) whose frozen definition
snapshot has a SERVICE_TASK referencing the service, because deleting the live row would make
those instances' pinned catalog resolution fail; (c) precedence of the two guards and that
only the first failing guard is reported; (d) the returned list is capped at 50 ids with a
`truncated` flag and carries no tenant identity; (e) the check is advisory against
concurrently starting instances (section 6) and retire is the safe alternative; (f) on
success the service's archived versions are deleted with it, atomically; (g) the escape hatch:
cancel or complete the listed instances.

Moduledoc / comment updates: the comment block above `referencing_active_definitions/2`
("§4 -- the referential guard") gets a sentence noting a second, instance-level guard shares
the same fragment and tenant loop. `lib/letflow/design/iss0917-...md` is NOT rewritten
(historical); the pointer in section 8 item 4 suffices.

---

## 10. D-I -- acceptance criteria (testable) and test seams

### 10.1 Acceptance criteria

| ID | Criterion |
|---|---|
| AC-1 | With a non-terminal (`:active`) instance whose frozen snapshot has a SERVICE_TASK referencing service S and NO ACTIVE definition referencing S (definition deprecated), `ServiceCatalog.delete(S)` returns `{:error, {:referenced_by_active_instances, %{instance_ids: ids, truncated: false}}}` with `ids` containing the instance id, and performs NO write: the live `service_catalog` row and all `service_catalog_versions` rows are intact |
| AC-2 | The same fixture after the instance reaches `:completed` (or `:cancelled`): `delete(S)` returns `:ok`; the live row AND every `service_catalog_versions` row for S are gone |
| AC-3 | An instance in `:error` status referencing S blocks deletion exactly like `:active` (D-C) |
| AC-4 | A non-terminal instance in a DIFFERENT provisioned tenant than any other fixture is detected (loop covers every registration, not only the first tenant); a `scope: :tenant` service pinned by an instance in its owning tenant is also detected |
| AC-5 | An instance referencing a DIFFERENT service id (including one that has S as a substring) does not block deletion of S (equality match, not substring/`LIKE`) |
| AC-6 | When an ACTIVE definition still references S, `delete(S)` returns `{:error, {:referenced_by_active_definitions, ids}}` exactly as before (precedence, D-D); existing assertions at `test/letflow/service_catalog_test.exs` ~:384 and ~:471 unchanged and passing |
| AC-7 | `delete("nonexistent")` still returns `{:error, :not_found}` (unchanged), and runs before any guard |
| AC-8 | Result bound: with more than 50 referencing non-terminal instances, `instance_ids` has exactly 50 entries and `truncated` is true; with 50 or fewer, `truncated` is false and every id is present |
| AC-9 | The returned map contains no key other than `instance_ids` and `truncated` (no tenant id, no status, no counts) |
| AC-10 | After a successful delete, re-registering the same `service_id` and publishing a version string that the previous incarnation had archived is NOT rejected on account of stale archive rows, and a `{:version, v}` pin lookup does not resolve to the previous incarnation's endpoint (orphan fix, D-F) |
| AC-11 | Concurrent deletion of the same row still yields a benign `{:error, :not_found}` (existing test ~:429-460 unchanged and passing), and an `Entry` stale-error rolls the version-row deletion back |
| AC-12 | HTTP: `DELETE /api/v1/admin/services/:service_id` for the AC-1 fixture returns 409; body `type` ends with `service-referenced-by-active-instances`, `title` "Service Referenced By Active Instances", `status` 409, `detail` contains no instance id, extensions `instance_ids` (list) and `truncated` (boolean) only |
| AC-13 | HTTP: the AC-6 case still returns 409 with type `service-referenced-by-active-definitions`; 404 and 204 paths unchanged; a non-PLATFORM_ADMIN caller still gets 403 |
| AC-14 | The status list used by the guard equals the set of statuses for which `InstanceProjection.terminal?/1` is false (guards against drift if a status is added) |

### 10.2 Test seams and fixtures (for TEST-DESIGNER)

- Fixture basis: `test/letflow/engine_catalog_service_task_test.exs` (ISS-0917): committed-row
  style (`Sandbox.mode :auto`, `async: false`, line ~48), `TenantFixture.provisioned_tenant!`
  (line ~59, use a fresh `slug_prefix` e.g. `"iss0923"`), and its `cleanup_entry!` helper (line
  ~61) which deletes both `Version` and `Entry` rows. Graph: HUMAN_TASK -> SERVICE_TASK(service_id)
  (`graph_human_task_then_service_task/1` in `engine_pin_resolver_catalog_test.exs` ~:133),
  register + (optionally) publish v2 so an archive row exists, activate the definition, `Engine.create/2`,
  then `Definitions.deprecate/…` to clear guard 2. Instance statuses: `:active` straight after
  create; `:completed`/`:cancelled` by completing/cancelling through the engine; `:error` by
  driving the pinned resolution failure or by direct projection status update inside the
  committed-row test (documented as a fixture shortcut).
- For AC-8 (cap): a 51-instance fixture is heavy through `Engine.create/2`. Preferred seam:
  insert minimal projection + snapshot rows directly into the tenant schema via the same
  `prefix:` the production query uses, or make the cap a compile-time module attribute that a
  test reads through a documented, public, read-only accessor rather than overriding config
  (ELIXIR-DEV chooses; TEST-DESIGNER must not rely on an undocumented private).
- Router tests: `test/letflow/routers/admin_services_test.exs` (helpers around lines 94-100
  clean up `Entry` rows; the new tests must also clean `Version` rows and any instance rows,
  see `admin_services_publish_retire_test.exs:90-91` idiom).
- **Shared-DB hazard:** the shared `letflow_test` DB can hold other sessions' committed
  `tenant_template_build_*` registrations whose schemas do not exist; `delete/1` iterates ALL
  registrations and raised Postgrex `42P01` in the step-01 repro (environmental, not this
  issue's defect, not fixed here). Every committed-row delete test in this change MUST be
  run with `MIX_TEST_PARTITION=<n>` (isolated DB), scoped to the touched files only (never the full
  suite on this shared machine). TEST-RUNNER records the partition value in its report.
- Fail-first requirement (WF-03): AC-1, AC-3, AC-4, AC-8, AC-10 and AC-12 MUST fail on the
  current branch (today `delete/1` returns `:ok` for AC-1, measured in step 01) and pass after
  the fix. AC-2, AC-5, AC-6, AC-7 are regression guards.
- Mutants TEST-DESIGNER must kill: (m1) drop the status filter (a terminal instance blocks);
  (m2) restrict to `[:active]` only (AC-3 fails); (m3) substring/`LIKE` match on service id
  (AC-5); (m4) query only the first registered tenant (AC-4); (m5) skip version-row deletion
  (AC-2/AC-10); (m6) swap guard order so instances precede definitions (AC-6 precedence);
  (m7) remove the router clause (AC-12 raises `CaseClauseError`).

---

## 11. D-J -- security notes for SECURITY-REVIEWER

- INV-1: all new reads use `prefix: registration.schema_name` from `TenantProvisioning`
  registrations; no request-derived prefix. The cross-tenant read is by design on a
  PLATFORM_ADMIN-only route.
- INV-2: response carries opaque instance UUIDs and a boolean only; no tenant ids, statuses
  or variables; `detail` has no ids.
- INV-5: n/a for tenant visibility (admin surface), reasoned in section 3.3.
- INV-6: this section is the scoping statement; the route and its role gate are unchanged.
- INV-7: service id is bound; schema names come from the registry, are never concatenated
  into SQL by hand (prefix option only).
- INV-8: new error tuple has a router clause; transaction failure paths map to
  `{:error, :not_found}` and never raise out of `delete/1`.
- Information gain over today: an admin learns instance ids that pin a service. Same class
  and same audience as the definition ids already returned.

---

## 12. D-K -- scope boundaries and follow-ups

- `update_scope/2` narrowing has the same blind spot (only other tenants' ACTIVE definitions,
  not their running instances). NOT in this fix; ORCH should file a follow-up issue.
- Engine-side shared lock on the catalog row at instance start (to close the TOCTOU
  fully): not proposed; would be its own requirement.
- A "force delete ignoring ERROR instances" option: not proposed.
- `retire` already preserves pinned resolution and is the documented safe alternative.
- The shared-DB `42P01` hazard from stale `tenant_template_build_*` registrations: environmental,
  not fixed here.
- No migration, no new index, no change to `web/`.

---

## 13. D-L -- open questions

No open question blocks implementation. Decided here (not left to the implementer): block vs
document, ERROR blocks, error shape and cap (50), guard order, TOCTOU accepted, version rows
deleted in-scope, 409 problem type name. Items for REVIEWER to confirm explicitly:

| ID | Item | Default if REVIEWER does not object |
|---|---|---|
| OQ-1 | Cap of 50 ids is a judgment call (response size vs. usefulness) | Keep 50 |
| OQ-2 | Deleting archive rows widens `delete/1`'s write set from one table to two (atomic, no FK); this is chosen over leaving a re-register trap | Keep, in scope |

---

## 14. Owned files (for ELIXIR-DEV and test authors)

- Modified: `lib/letflow/service_catalog.ex` (guard, transaction, cap attribute, `instance_refs()` type, spec/doc).
- Modified: `lib/letflow/api/error.ex` (new constructor).
- Modified: `lib/letflow/routers/admin_services.ex` (new `handle_delete` clause, moduledoc line).
- Modified (doc-only pointers): `lib/letflow/design/req192-service-catalog-routes.md`, `lib/letflow/design/iss0917-catalog-service-task-pinned-dispatch.md` OQ-3 row.
- New/extended tests: `test/letflow/service_catalog_test.exs` (or a new `service_catalog_delete_instances_test.exs`), `test/letflow/routers/admin_services_test.exs`.
- No migration.
