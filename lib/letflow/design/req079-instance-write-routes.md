# Design: REQ-079 — Instance write routes (create / cancel / reconstruct)

**Requirement:** REQ-079, stage S4, `depends_on: [REQ-072]`
**Owner (implementer):** ELIXIR-DEV
**Module:** `lib/letflow/routers/instances.ex` (existing file, extended — REQ-078 already added
`POST /:id/rebind-pins` and reserved the rest of the file for this requirement)
**This document produces:** per-route method/path/delegate/permission/response mapping, the full
error-mapping table for all three `_error()` types, request-body validation schemas, moduledoc
content outline, route-ordering placement, changed-file list, traceability, open questions.
**No implementation code** — no function bodies, no `.ex`/`.exs` files.

PROVENANCE (historical, not current decision authority):
R-Co source read in full: `c:/Users/tvolo/dev/ai-dala/R-Co/src/api/routes/instances.zig` lines
30-420 (`handleCreate` L48-233, `handleCancel` L235-284, `handleReconstruct` L286-397).

---

## 1. Scope

Three thin Plug router handlers added to the existing `Letflow.Routers.Instances` module:

| Handler | Method/path | Delegate |
|---|---|---|
| `handle_create` | `POST /instances` | `Letflow.Engine.create/2` |
| `handle_cancel` | `POST /instances/:id/cancel` | `Letflow.Engine.cancel_instance/3` |
| `handle_reconstruct` | `POST /instances/:id/reconstruct` | `Letflow.Engine.Reconstruction.reconstruct_instance/2` (always `write_back: true`) |

No new engine behaviour. No `Repo` call, no transition logic in this module (AC5) — every
handler's job is: parse/validate the HTTP request, resolve tenant scope + actor, call exactly one
`Letflow.Engine*` function, map its result to a response.

---

## 2. Route ordering

Declared in this order inside the router, all before `match _`:

```
post "/"                    (create — no :id segment, no ordering hazard)
post "/:id/rebind-pins"     (REQ-078, unchanged)
post "/:id/cancel"          (REQ-079)
post "/:id/reconstruct"     (REQ-079)
match _
```

`Plug.Router` matches in declaration order. `/:id/cancel` and `/:id/reconstruct` are literal
path suffixes distinct from `/:id/rebind-pins`, so they do not compete with it or with each
other — but per this module's own moduledoc constraint ("MUST precede any future
`POST /instances/:id`"), **no bare `POST "/:id"` route exists in this requirement or may be added
above these three without moving them first.** REQ-080 (read routes, `GET`) does not share this
hazard — `GET` and `POST` are independent dispatch tables in `Plug.Router`. Record this note in
the moduledoc for REQ-080 or any later route addition to inherit correctly.

---

## 3. Permission gating

PROVENANCE (historical, not current decision authority):
| Route | `endpoint_policy_key/2` clause | Existing? |
|---|---|---|
| `POST /instances` | `:InstancesStart` | yes — `authorization.ex:196` |
| `POST /instances/:id/cancel` | `:InstancesCancel` | yes — `authorization.ex:197` |
| `POST /instances/:id/reconstruct` | *(none)* | confirmed — no clause exists, and R-Co's own `authorization.zig` has zero hits for reconstruct (grepped). Same precedent as REQ-078's rebind-pins: no route-local permission check invented here; reconstruct is authenticated + tenant-scoped only. If a permission requirement emerges later it is a REQ-131-class policy decision, not this requirement's to invent. |

**New private helper**, added to the module, reused by `handle_create` and `handle_cancel` only
(mirrors `Letflow.Routers.Tasks`'s `with_authorized_scope/4` shape, adapted — this module has no
`decision`-dependent row-filter branch to thread through, so the callback only needs `opts`):

```
with_permission(conn, permission_key, fun) — conn, Authorization.permission()/endpoint_policy_key(), (Plug.Conn.t(), opts :: keyword() -> Plug.Conn.t()) -> Plug.Conn.t()
```

Sequencing inside it, matching `Letflow.Routers.Tasks`'s own step-1/step-2 preamble ordering
(scope before authorization, no `Repo` call before either has resolved):

1. `scoped_repo_opts(conn)` (the module's existing private wrapper around
   `Context.scoped_repo_opts/1`, already present for rebind-pins) — on error, `Response.internal_error/1`.
2. Build `%Authorization.AccessContext{user_id: conn.assigns.auth_context.user_id, roles: Authorization.roles_from_strings(conn.assigns.auth_context.roles)}`.
3. `Authorization.evaluate_access(ctx, permission_key)` — `:Deny403` → `Response.forbidden(conn, "insufficient permissions")`; any other decision kind → call `fun.(conn, opts)`.

`handle_reconstruct` does **not** go through `with_permission/3` — it calls `scoped_repo_opts/1`
directly (same as the existing rebind-pins handler), skipping step 2/3 entirely.

**AC4 — "absence of state change verified":** this is a test-design obligation (TEST-DESIGNER),
not a route-shape one — `with_permission/3`'s `:Deny403` branch returns before `fun` is ever
invoked, so a denied caller structurally cannot reach `Engine.create/2` or
`Engine.cancel_instance/3`. Flag for TEST-DESIGNER: assert the row/projection is absent
(create) or unchanged (cancel) after a 403, not just the status code.

---

## 4. `POST /instances` — create (EE-01)

### 4.1 Request validation schema (new `@create_schema`, `Letflow.Api.Validation.FieldConstraint` list)

| Field | required | type | notes |
|---|---|---|---|
| `definition_id` | false | `:uuid` | mutually exclusive with `definition_name` — enforced by `Engine.create/2`, NOT by this schema (`FieldConstraint` has no XOR vocabulary; same reasoning `Letflow.Routers.Instances`'s existing `normalise_entries/1` comment gives for per-element checks it can't express) |
| `definition_name` | false | `:string`, `reject_empty_string: true` | Letflow addition over R-Co (REQ-045) — exposed here because `Engine.create/2` already accepts it; restricting the route to `definition_id` only would regress an already-shipped capability |
| `correlation_key` | false | `:string` | absent key and JSON `null` are both treated as "not present" by `Validation.validate_field/2` (documented there) — matches `create_attrs`'s `optional(:correlation_key) => String.t() \| nil` exactly, no extra route logic needed |
| `initial_variables` | true | `:object` | maps to R-Co's `INVALID_INITIAL_VARIABLES` 422 structurally, via `Validation.problem/1`, before `Engine.create/2` is ever called — `Engine.create/2`'s own `:invalid_initial_variables` branch is therefore unreachable through this route (kept in the error table below anyway, marked so) |

`Validation.validate/2` returns `{:ok, Map.take(body, schema_field_names)}` — only declared,
present fields, still **string**-keyed. `handle_create` builds `create_attrs()` (atom-keyed)
explicitly field-by-field via `Map.has_key?/2` + `Map.get/2` on that result — same style as
`handle_rebind_pins`'s `rebind_attrs` construction — never passing the raw validated map through:

- `:definition_id` included iff `"definition_id"` key present in the validated map.
- `:definition_name` included iff `"definition_name"` key present.
- `:correlation_key` included iff `"correlation_key"` key present (value may be `nil`).
- `:initial_variables` always included (required).
- `:actor_id` — from the module's existing `actor_id/1` helper.
- `:idempotency_key` — from the module's existing `idempotency_key/1` helper (the
  `idempotency-key` header convention, reused unchanged per this module's moduledoc).

### 4.2 Response — 201

```
{
  "instance_id": create_result().instance_id,
  "status": status_string(create_result().status),   # :active | :completed -> "ACTIVE" | "COMPLETED"
  "created_at": DateTime.to_iso8601(create_result().started_at)
}
```

Field-name divergence from R-Co, deliberate: `create_result().started_at` (Letflow's field name)
is rendered under the JSON key `"created_at"` (R-Co's wire name) — an allowlisted rename, not a
struct dump, so INV-2 is unaffected. `definition_id`, `current_nodes`, `variables` (also present
on `create_result()`) are **not** echoed — R-Co's own success shape has only three keys, and AC1
only requires "returns 201 with the instance id," so the response stays minimal rather than
inventing an unrequested wider contract.

### 4.3 Error mapping — `Letflow.Engine.create_error/0`

| Error variant | HTTP | Detail (constant, no interpolation — INV-4 style except where noted) | Reachable via this route? |
|---|---|---|---|
| `{:error, :tenant_id_not_accepted}` | 500 (catch-all) | — | **No.** `create_attrs` is built field-by-field from a fixed key set (§4.1); `tenant_id` is never a key this route can produce. Structurally unreachable. |
| `{:error, :invalid_schema_name}` | 500 (catch-all) | — | **No.** `prefix` comes from `Context.scoped_repo_opts/1`, resolved from the caller's authenticated tenant, not from any caller-suppliable request field. |
| `{:error, :missing_definition_reference}` | 422 | `"exactly one of definition_id or definition_name is required"` | Yes — caller omits both. |
| `{:error, :both_definition_id_and_name}` | 422 | `"exactly one of definition_id or definition_name is required"` | Yes — caller supplies both. |
| `{:error, :invalid_initial_variables}` | 422 | `"initial_variables must be a JSON object"` | **No** in practice — `Validation` schema already rejects this before `Engine.create/2` runs (§4.1). Mapped anyway for completeness/defence-in-depth. |
| `{:error, :definition_not_found}` | 404 | plain `not_found/1` (no detail — INV-5 style, matches R-Co's own `DEFINITION_NOT_FOUND`) | Yes — bad `definition_id`/`definition_name`. |
| `{:error, :definition_not_active}` | 409 | `"only an ACTIVE definition can be started"` | Yes. |
| `{:error, :duplicate_correlation_key}` | 409 | `"an active instance with this correlation key already exists"` | Yes — AC2, INV-8: the `uq_instance_correlation` partial unique index surfaces here as a typed error, never a raw constraint violation. |
| `{:error, {:snapshot_failed, _}}` | 500 (catch-all) | — | No caller-triggerable input reaches this; internal snapshot-store failure. |
| `{:error, {:graph_structure_invalid, _}}` | 500 (catch-all) | — | Definition graphs are validated at activation time (REQ-029/definitions activate path), not at instance-create time; not reachable by a create-time caller input. |
| `{:error, {:activation_failed, _}}` | 500 (catch-all) | — | Internal. |
| `{:error, {:event_append_failed, _}}` | 500 (catch-all) | — | Internal. |
| `{:error, {:unresolved_catalog_ref, _ref}}` | 422 | `"a SERVICE_TASK node references a service_id with no resolvable catalog entry"` | Yes — depends on the definition's own pin state, can legitimately fire per-create. `_ref` not echoed (constant detail, matches `Letflow.Routers.Instances`'s established style for `{:unknown_pin_ref, ...}`). |
| `{:error, {:unresolved_module_ref, _ref}}` | 422 | `"a SUB_PROCESS node references a module_ref with no resolvable module version"` | Yes. |
| `{:error, {:unresolved_pin_override, _ref}}` | 422 | `"pin_overrides names a version that does not exist"` | Not reachable via this route today — `create_attrs()` has no `:pin_overrides` key exposed by this route's schema (R-Co's own `handleCreate` request body has none either — confirmed against the read source, L34-40). Mapped for completeness/defence-in-depth against a future `Engine.create/2` caller-supplied path. |
| `{:error, {:variable_schema_violation, _failures}}` | 422 | `"initial_variables violate the definition's registered variable schema"` | Yes. |
| `{:error, {:parent_pin_lookup_failed, _reason}}` | 500 (catch-all) | — | **Not reachable via this route, but for a narrower reason than "internal-only":** `Engine.create/2`'s `parent_pins/2` (`engine.ex:611-634`) reads `attrs[:parent_instance_id]` from the **same** `attrs` map every caller passes — it is not restricted to a separate internal code path. It only fails to fire here because `handle_create` builds `create_attrs()` field-by-field from a fixed, closed key set (§4.1) that does not include `:parent_instance_id` — an undocumented, forward-looking key `create_attrs()`'s own `@type` does not declare, flagged in `engine.ex`'s own comment as unconfirmed against not-yet-built REQ-062. If a future requirement exposes `parent_instance_id` on this route, this row becomes reachable and needs re-mapping then — not this requirement's scope. |
| `{:error, %Ecto.Changeset{}}` | 500 (catch-all) | — | Route-construction-bug class, matches `Letflow.Routers.Instances`'s existing catch-all precedent for rebind. |
| `{:error, term()}` | 500 (catch-all) | — | Same catch-all. |

No 503 branch — matches this module's existing "Deliberate non-port" precedent
(`DBConnection.ConnectionError` is a raise, not a return value, so a 503 clause would be
unreachable dead code).

---

## 5. `POST /instances/:id/cancel` — cancel (EE-08)

No request body fields to validate beyond the path `:id` — `cancel_attrs()` is built entirely
from `actor_id/1` and `idempotency_key/1`, the module's existing helpers.

### 5.1 Response — 200

```
{
  "instance_id": cancel_result().instance_id,
  "status": "CANCELLED"          # cancel_result().status is always :cancelled — literal string, not computed via a general atom->string mapper
}
```

### 5.2 Error mapping — `Letflow.Engine.cancel_error/0`

| Error variant | HTTP | Detail | Reachable via this route? |
|---|---|---|---|
| `{:error, :invalid_instance_id}` | 422 | `"instance_id is not a valid UUID"` | Yes in principle, but the route casts the path `:id` itself via the module's existing `cast_instance_id/1` **before** calling `Engine.cancel_instance/3`, so this branch is defence-in-depth, matching the existing `render_rebind/2` precedent that keeps an identical clause for the same reason. |
| `{:error, :invalid_schema_name}` | 500 (catch-all) | — | No — `prefix` is resolved from the authenticated tenant, not caller input. |
| `{:error, :missing_actor_id}` | 500 (catch-all) | — | No — `actor_id/1` always supplies a value or the handler short-circuits earlier at `{:error, :missing_scope_or_actor}` (before `Engine.cancel_instance/3` is ever called). |
| `{:error, :missing_idempotency_key}` | 500 (catch-all) | — | No — `idempotency_key/1` always generates a UUID fallback, never `nil`. |
| `{:error, :instance_not_found}` | 404 | plain `not_found/1` | Yes — genuinely absent instance **and** cross-tenant instance (INV-5, AC3) both land here, same call, same bytes. |
| `{:error, {:instance_already_terminal, :completed}}` | **409** | `"instance is already completed and cannot be cancelled"` | Yes — AC6, one of the two terminal states under test. |
| `{:error, {:instance_already_terminal, :cancelled}}` | **409** | `"instance is already cancelled"` | Yes — AC6, the other terminal state under test. |
| `{:error, {:event_append_failed, _}}` | 500 (catch-all) | — | Internal. |
| `{:error, %Ecto.Changeset{}}` | 500 (catch-all) | — | Internal. |
| `{:error, term()}` | 500 (catch-all) | — | Catch-all. |

**AC6 — named in the moduledoc.** The moduledoc's route table (§8 below) must state explicitly:
"cancelling an already-`COMPLETED` or already-`CANCELLED` instance returns **409**." The two
`{:instance_already_terminal, status}` clauses render **different detail strings** per status
(unlike the constant-detail style elsewhere in this module) because both states are distinct,
deterministic, and caller-meaningful — this is a considered choice, not an inconsistency with
`render_rebind/2`'s constant-detail precedent (that precedent is about not leaking *internal*
detail, not about collapsing two equally-valid terminal states into one message). Both still map
to the **same status code** (409), so no new response-shape branching is introduced — only the
`detail` string varies, which `Response.conflict/2` already supports as a normal parameter.

No 503 branch — same reasoning as §4.3's closing note; `Letflow.Engine.cancel_instance/3`'s own
`cancel_error()` type carries no pool-exhaustion variant either (confirmed by reading the full
type at `engine.ex:2372-2384` — there is no `:pool_exhausted`/503-shaped member to port).

---

## 6. `POST /instances/:id/reconstruct` — reconstruct (EE-11)

No request body. No permission check (§3). Calls
`Letflow.Engine.Reconstruction.reconstruct_instance(instance_id, prefix: prefix, write_back: true)`
— **always** `write_back: true`, matching R-Co's `handleReconstruct` (`reconstruction_mod.reconstructInstance(..., true)`, L318 of the read source). This is not a caller-controllable option; no request-body field exists for it.

### 6.1 Response — 200

Projected from `reconstruct_result().instance_state` (an `InstanceState.t()`), **not** the outer
`reconstruct_result()` map itself — `event_count`/`last_sequence_number`/`write_back` are
internal bookkeeping fields with no R-Co wire counterpart and are not echoed (INV-2 allowlist):

```
{
  "instance_id": reconstruct_result().instance_id,
  "status": status_string(instance_state.status),   # :active|:completed|:cancelled|:error -> "ACTIVE"|"COMPLETED"|"CANCELLED"|"ERROR"
  "tokens": Enum.map(instance_state.tokens, fn t -> %{"node_id" => t.node_id, "branch_id" => t.branch_id} end),
  "variables": instance_state.variables
}
```

Each `Token.t()` has four fields (`node_id, branch_id, token_id, waiting_child_instance_id`);
only `node_id`/`branch_id` are projected per token, matching R-Co's `{node_id, branch_id}` shape
exactly (§ already confirmed in the task brief) — `token_id`/`waiting_child_instance_id` are
Letflow-internal reconstruction bookkeeping, not echoed.

`status_string/1` (private helper, new — shared in spirit with the equivalent literal-string
mapping in `Engine.Reconstruction`'s own `InstanceProjection`, but implemented locally in the
router since this module owns zero dependency on that schema per its own "no Repo call" rule):
`:active -> "ACTIVE"`, `:completed -> "COMPLETED"`, `:cancelled -> "CANCELLED"`,
`:error -> "ERROR"`. All four are covered — `InstanceState.status/0`'s type is a closed 4-atom
union (confirmed by reading `instance_state.ex`), so this mapping is exhaustive with no
catch-all clause needed (a missing 5th atom would be a compile-time inexhaustive-case warning,
which is the intended safety net, not a runtime 500 path).

### 6.2 Error mapping — `Letflow.Engine.Reconstruction.reconstruct_error/0`

| Error variant | HTTP | Detail | Reachable via this route? |
|---|---|---|---|
| `{:error, :instance_not_found}` | 404 | plain `not_found/1` | Yes — genuinely absent **and** cross-tenant instance (INV-5, AC3), same call, same bytes. |
| `{:error, {:lock_contention, _instance_id}}` | 409 | `"instance is locked by another transaction"` | Yes — matches R-Co's `LOCK_CONTENTION` 409. `_instance_id` not echoed (it's the same id already in the path/response; no new information, constant-detail style). |
| `{:error, {:replay_failed, _reason}}` | 500 (catch-all) | — | Not caller-triggerable through normal input — a corrupt/inconsistent event log is a data-integrity condition, not a request-shape error. Matches R-Co's own catch-all `else =>` 500 branch for every non-`InstanceNotFound`/`LockContention`/`PoolExhausted` reconstruction failure (read source L330-336: `else => errorResult(..., 500, "INTERNAL_ERROR", ...)`), so this is a direct, faithful port of R-Co's own catch-all shape, not a Letflow-only choice. |
| `{:error, :invalid_schema_name}` | 500 (catch-all) | — | No — `prefix` from authenticated tenant, not caller input. |
| `{:error, :invalid_instance_id}` | 422 | `"instance_id is not a valid UUID"` | Yes in principle, defence-in-depth only — the route casts the path `:id` itself via the existing `cast_instance_id/1` before calling `reconstruct_instance/2`, same reasoning as §5.2's identical clause. |

**Verified, not assumed (per the task brief's explicit instruction): does `reconstruct_error()`
have a pool-exhaustion-shaped return path?** No. Read the full type at
`reconstruction.ex:238-243` — its five members are exactly the five rows above; there is no
`:pool_exhausted`/503 variant to port, matching the same "raises, doesn't return" reasoning
`Letflow.Routers.Instances`'s moduledoc already gives for rebind-pins' 503 non-port
(`DBConnection.ConnectionError` is a raised exception in both cases, never a return value this
`with`-chain could pattern-match). No 503 branch in this handler either, for the same reason —
now confirmed against `Reconstruction`'s own type, not inferred by analogy alone.

---

## 7. Cross-cutting: idempotency key, actor id, tenant scope

All three handlers reuse the module's **existing** private helpers, unchanged:

- `idempotency_key/1` (header-or-generate, truncate-to-255-bytes convention) — used by
  `handle_create` and `handle_cancel` (reconstruct has no `idempotency_key` in its `reconstruct_opts()` — confirmed: `reconstruct_opts()` is `[prefix: String.t(), write_back: boolean()]` only, no idempotency field to source one for).
- `actor_id/1` — used by `handle_create` and `handle_cancel` (reconstruct's `reconstruct_opts()`
  also carries no `actor_id` field — not needed, not sourced).
- `scoped_repo_opts/1` (the module's private wrapper around `Context.scoped_repo_opts/1`,
  collapsing both of that function's error atoms to `{:error, :missing_scope_or_actor}`) — used
  by all three handlers, `handle_reconstruct` calling it directly (no `with_permission/3` wrapper,
  per §3).
- `cast_instance_id/1` — used by `handle_cancel` and `handle_reconstruct` for the path `:id`.

No new idempotency/tenant-scope/actor convention is introduced. `handle_create` needs no
`cast_instance_id/1` call — it has no `:id` path segment.

---

## 8. Moduledoc content outline (additions to the existing moduledoc)

The existing moduledoc's route table (currently one row, rebind-pins) gains three rows:

| Handler | Method/path | Delegate | Permission | Response |
|---|---|---|---|---|
| create | `POST /instances` | `Letflow.Engine.create/2` | `InstancesStart` | 201, `{instance_id, status, created_at}` |
| cancel | `POST /instances/:id/cancel` | `Letflow.Engine.cancel_instance/3` | `InstancesCancel` | 200, `{instance_id, status}`; **409 if the instance is already `COMPLETED` or already `CANCELLED`** |
| reconstruct | `POST /instances/:id/reconstruct` | `Letflow.Engine.Reconstruction.reconstruct_instance/2` (`write_back: true`, not caller-controllable) | none (§3 — same precedent as rebind-pins; a future policy decision, not invented here) | 200, `{instance_id, status, tokens: [{node_id, branch_id}], variables}` |

Additional moduledoc sections to add (new `##`-level headings, alongside the existing ones):

1. **"POST /instances — definition_id vs definition_name"** — states the XOR is enforced by
   `Engine.create/2`, not by this router's validation schema, and why (`FieldConstraint` has no
   cross-field vocabulary — same reasoning already given for `normalise_entries/1`'s per-element
   checks).
2. **"Cancelling a terminal instance is 409, not 404 or 500"** — states both `:completed` and
   `:cancelled` map to 409 with a per-status detail string (AC6 — this is the sentence
   CODE-DESIGN-VALIDATOR/AC6 checks for).
3. **"Reconstruct always write-backs"** — states `write_back: true` is hardcoded, not a request
   option, matching R-Co's `handleReconstruct` exactly.
4. **"Reconstruct has no route-local permission check"** — same shape as the existing rebind-pins
   section, cross-referenced rather than duplicated.
5. Route-ordering note (§2 above) — append to the existing "Route ordering" section rather than
   creating a new one, since it is the same constraint extended to two more routes.

---

## 9. Changed files

| File | Change |
|---|---|
| `lib/letflow/routers/instances.ex` | add `handle_create/1`, `handle_cancel/2`, `handle_reconstruct/2` and their private helpers (`with_permission/3`, `@create_schema`, `status_string/1`, response-map builders, error-mapping `case`/multi-clause private functions per §4.3/§5.2/§6.2); add three `post` route declarations (§2); extend moduledoc per §8 |

No migration, no new Ecto schema, no change to `Letflow.Engine`, `Letflow.Engine.Reconstruction`,
or `Letflow.Api.Authorization` — every backing function and permission clause this requirement
needs already exists (confirmed above, `status: done`).

---

## 10. Traceability

| AC | Where satisfied |
|---|---|
| 1 | §4.2 response shape, §4.3 (no unmapped 500 on the success path) |
| 2 | §4.3 `:duplicate_correlation_key` row (409, not 500); cross-tenant-succeeds case is a TEST-DESIGNER-owned test against `Engine.create/2`'s already-`done` per-schema unique index (REQ-043) — no route-level logic needed since the index itself is schema-scoped |
| 3 | §5.2 and §6.2 `:instance_not_found` rows — same call, same response as genuinely-absent, for both cancel and reconstruct (INV-5); "state unchanged" is a TEST-DESIGNER assertion against the row, not a route-shape concern |
| 4 | §3 `with_permission/3` — `:Deny403` returns before `Engine.create/2`/`Engine.cancel_instance/3` is ever called, so no state change is structurally possible; flagged for TEST-DESIGNER to assert absence, not just the 403 |
| 5 | §1 — every handler's body is parse → scope/permission → one `Engine*` call → map result; no `Letflow.Repo` alias, no transition logic anywhere in this module (grep-checkable, same as the existing rebind-pins precedent) |
| 6 | §5.2 two `{:instance_already_terminal, status}` rows (409, distinct per-status detail), §8 item 2 (named in moduledoc) |

---

## 11. Open questions

None. Every acceptance criterion maps to a concrete row above; every error-type variant across
all three `_error()` types is mapped or explicitly marked unreachable-with-reason (§4.3, §5.2,
§6.2) — no variant is left to silently fall through to an unexplained 500.
