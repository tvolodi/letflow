# REQ-308 — HTTP surface for entity definitions, entity records, and the query DSL (S10 gap 1)

Status: design only. No `lib/` implementation, no route mounted, no test. Implements
none of `Letflow.Entities.Definitions`/`Letflow.Entities.Records`/
`Letflow.Entities.Query.*` — those already exist (REQ-225..REQ-231, REQ-296..REQ-301).
This document specifies the route table, permission vocabulary, HTTP transport of the
query DSL, tenant-scoping/security posture, pagination, error shaping, and the
deferred-routes-table disposition that a future ELIXIR-DEV requirement builds from.

Per decision 0022 rule 1: this document uses no domain-vertical vocabulary. "entity
type", "entity definition", "entity record", "field", "filter", "join" are this
subsystem's own generic nouns (already used by the modules it fronts), not any one
vertical's objects.

## 0. Premises re-verified before designing

```
$ ls lib/letflow/routers/
admin_services.ex  audit.ex  definitions.ex  dlq.ex  identity.ex  instances.ex
metrics_exposition.ex  mobile_tenant_config.ex  onboarding.ex  promotions.ex
services.ex  solution_packs.ex  tasks.ex  tenant_config.ex  tenants.ex  webhooks.ex
```
Sixteen routers, no `entities.ex` — confirmed.

`lib/letflow/router.ex` lines 82-83 (deferred-routes table, still present, still
unowned):
```
| `Letflow.Routers.Entities`          | `entities.zig`            | S5/S6 (entity/data-model subsystem)   |
| `Letflow.Routers.EntityQuery`       | `entity_query.zig`        | S5/S6 (same, plus query compiler)     |
```

`lib/letflow/plugs/api_pipeline.ex`'s forward list (lines 141-153) mounts thirteen
sub-routers under `/api/v1` — `/identity`, `/tenants`, `/instances`, `/definitions`,
`/tasks`, `/promotions`, `/onboarding`, `/solution-packs`, `/audit`, `/dlq`,
`/webhooks`, `/services`, `/admin/services` — no `/entities` entry. Confirmed: the
subsystem is fully built (`Letflow.Entities.Definitions`, `Letflow.Entities.Records`,
`Letflow.Entities.Query.{Compiler,Allowlist,Cursor,FieldGrants,Types}` all exist and are
tested) and entirely unreachable over HTTP.

`lib/letflow/api/authorization.ex`:
```
$ grep -n "Entities" lib/letflow/api/authorization.ex
(no output)
```
Zero `Entities*` permission atoms, zero `Entities*` `endpoint_policy_key/2` clauses.
Confirmed: this design is adding a permission vocabulary, not reusing one.

Delegate functions verified present by grep:
```
$ grep -n "^  def create_definition\|^  def get_definition\|^  def get_definition_by_name\|^  def get_active_definition_by_name\|^  def list_definitions\|^  def activate_definition" lib/letflow/entities/definitions.ex
104:  def create_definition(%{definition: definition, created_by: created_by}, prefix)
183:  def get_definition(id, prefix) when is_binary(prefix) do
212:  def get_definition_by_name(name, prefix) when is_binary(name) and is_binary(prefix) do
253:  def get_active_definition_by_name(name, prefix)
297:  def list_definitions(filters, prefix) when is_map(filters) and is_binary(prefix) do
407:  def activate_definition(name, activator_user_id, rationale, prefix)

$ grep -n "^  def create_record\|^  def update_record\|^  def delete_record" lib/letflow/entities/records.ex
159:  def create_record(%{entity_type: entity_type, field_values: field_values} = attrs, prefix)
191:  def update_record(...) when ...
225:  def delete_record(%{entity_type: entity_type, record_id: record_id} = attrs, prefix)
```

`Letflow.Entities.Records` exposes **no read function** — `create_record/2`,
`update_record/2`, `delete_record/2` only (design §"REQ-228" moduledoc). Reading a
record by id or by any filter is exclusively a query-DSL operation
(`Letflow.Entities.Query.Compiler.compile/2` + `Letflow.Entities.Query.Cursor.paginate/5`).
This governs the route table below: there is no `GET /entities/records/...` route.

## 1. Route surface

**One router**, `Letflow.Routers.Entities`, mounted at `/entities` (justification in
§2). It owns three sub-resources, each under its own literal first-path-segment so a
wildcard `:entity_type` segment can never collide with a literal collection name:
`/entities/definitions/...`, `/entities/records/:entity_type/...`,
`/entities/query`.

`use Letflow.Api.AuthorizedRouter` (the house convention `Letflow.Routers.Definitions`/
`Letflow.Routers.Instances` both use) — every route below is declared with
`authz_get`/`authz_post`/`authz_put`/`authz_delete`, each carrying its policy-key atom
as a compile-time literal, so `Letflow.Plugs.Authorize` gates every route and every
route is enforcement-test-visible via `__authz_routes__/0`. No route in this design is
declared with a plain (`:Unknown`-gated) macro — unlike REQ-077/078's ad-hoc precedent
for a handful of pre-REQ-131 routes, this subsystem is new post-REQ-131 and has no
"no `endpoint_policy_key/2` clause exists yet" gap to inherit.

| Handler | Method/path | Delegate | Permission | Response |
|---|---|---|---|---|
| create_definition | `POST /entities/definitions` | `Letflow.Entities.Definitions.create_definition/2` | `EntitiesDefinitionsWrite` | 201 / 422 / 409 |
| list_definitions | `GET /entities/definitions` | `Letflow.Entities.Definitions.list_definitions/2` | `EntitiesDefinitionsRead` | 200 |
| get_active_definition_by_name | `GET /entities/definitions/active/:name` | `Letflow.Entities.Definitions.get_active_definition_by_name/2` | `EntitiesDefinitionsRead` | 200 / 404 |
| get_definition_by_name | `GET /entities/definitions/by-name/:name` | `Letflow.Entities.Definitions.get_definition_by_name/2` | `EntitiesDefinitionsRead` | 200 / 404 |
| get_definition | `GET /entities/definitions/:id` | `Letflow.Entities.Definitions.get_definition/2` | `EntitiesDefinitionsRead` | 200 / 404 |
| activate_definition | `POST /entities/definitions/:name/activate` | `Letflow.Entities.Definitions.activate_definition/4` | `EntitiesDefinitionsWrite` | 200 / 404 / 422 |
| create_record | `POST /entities/records/:entity_type` | `Letflow.Entities.Records.create_record/2` | `EntitiesRecordsWrite` | 201 / 404 / 422 |
| update_record | `PUT /entities/records/:entity_type/:record_id` | `Letflow.Entities.Records.update_record/2` | `EntitiesRecordsWrite` | 200 / 404 / 409 / 422 |
| delete_record | `DELETE /entities/records/:entity_type/:record_id` | `Letflow.Entities.Records.delete_record/2` | `EntitiesRecordsWrite` | 200 / 404 |
| query | `POST /entities/query` | `Letflow.Entities.Query.Compiler.compile/2` then `Letflow.Entities.Query.Cursor.paginate/5` then `Letflow.Entities.Query.FieldGrants.{load_restrictions/3,redact_page/2}` or `redact_joined_page/2` | `EntitiesQuery` | 200 / 400 / 404 / 422 |

**Route ordering** (same hazard class `Letflow.Routers.Definitions`' own moduledoc
documents for `/active/:name`/`/search` before `/:id`): `GET
/entities/definitions/active/:name` and `GET /entities/definitions/by-name/:name` MUST
be declared above `GET /entities/definitions/:id` — `Plug.Router` is
first-match-wins, so a bare `:id` route declared first would swallow `"active"`/
`"by-name"` as a literal id value. `POST /entities/definitions/:name/activate` is a
three-segment path distinct from the one-segment `POST /entities/definitions`, so it
does not compete with it regardless of order — but see `Letflow.Routers.Definitions`'
own precedent and is declared above it anyway for readability. GET and POST are
independent dispatch tables (same note `Letflow.Routers.Instances`' moduledoc makes),
so the `/definitions/...` GET routes never compete with the `/records/...` POST/PUT/
DELETE routes regardless of declaration order.

**No route reads a record by id or lists records.** That capability is `POST
/entities/query` with a `filters: [%{field: "record_id", op: :eq, value: record_id}]`
clause (or, for a full listing, an empty `filters` list) — there is deliberately no
second, redundant "get one record" route, matching `Letflow.Entities.Records`' own
scope (command-only context module, no read function to delegate to).

**Delegate-vs-handler split for the query route**: unlike every other row above (a
thin handler over one context-module call), `query`'s handler composes three calls in
sequence (`Compiler.compile/2` → `Cursor.paginate/5` → `FieldGrants` redaction) because
that is the existing three-module division of labor REQ-230/231/300 already built —
this design does not introduce a new combining context module, matching the same
"router composes existing context-module calls, never a router-local business-logic
layer" discipline `Letflow.Routers.Instances`' attachment routes already follow for
`Attachments.get_content/2` + the in-handler cross-instance check.

## 2. One router, not two — the deferred table's two module names are an R-Co-filename
   artefact, not two URL prefixes

`lib/letflow/router.ex`'s deferred table names `Letflow.Routers.Entities` (from
`entities.zig`) and `Letflow.Routers.EntityQuery` (from `entity_query.zig`) as two
modules. `Plug.Router.forward/2` is prefix-exclusive (one forward per URL prefix) —
this constraint would only force two router modules if the query DSL needed a
**second, distinct URL prefix**. It does not: the query DSL is a read affordance over
the same `/entities` resource family (it queries entity types' records, the same
records `/entities/records/...` writes), not an unrelated subsystem.

`Letflow.Routers.Definitions`' own moduledoc documents the exact same situation
already resolved once in this codebase: "Two different R-Co files are called
`validation.zig`" — R-Co's `routes/validation.zig` and `src/api/validation.zig` are
unrelated, and a third case, `Letflow.Routers.Validation`, was filed by REQ-070 purely
because it grouped by **Zig filename** rather than URL, then deleted once REQ-078
established the route actually lives on `Letflow.Routers.Definitions`. `entities.zig`
and `entity_query.zig` are the same pattern: two R-Co source-file names for what this
design treats as one URL-addressable resource family. Splitting them into two router
modules would force inventing a second URL prefix (e.g. `/entity-query`) with no
caller-facing benefit and no R-Co URL contract to preserve (R-Co's own file split
reflects Zig module organisation, not necessarily two HTTP mount points — the general
lesson `Letflow.Routers.Definitions`' moduledoc draws from its own validation.zig case).

**Decision: one router, `Letflow.Routers.Entities`, mounted at `/entities`.** Both
deferred rows collapse into this one module (disposition in §7). This also matches
this codebase's dominant precedent: `Letflow.Routers.Definitions` and
`Letflow.Routers.Instances` each own their whole resource family — plain CRUD plus
special sub-actions (`/validate`, `/search`, `/delta`, `/activate` on Definitions;
`/rebind-pins`, `/reconstruct`, `/attachments`, `/advance-timer` on Instances) — under
one router and one prefix, never splitting a "special action" into its own router.

## 3. Permission vocabulary

Four new permission atoms, none reusing an existing one:

| Atom | Gates | Kind |
|---|---|---|
| `:EntitiesDefinitionsRead` | `GET /entities/definitions`, `GET /entities/definitions/:id`, `GET /entities/definitions/active/:name`, `GET /entities/definitions/by-name/:name` | read |
| `:EntitiesDefinitionsWrite` | `POST /entities/definitions`, `POST /entities/definitions/:name/activate` | write |
| `:EntitiesRecordsWrite` | `POST /entities/records/:entity_type`, `PUT .../{entity_type}/{record_id}`, `DELETE .../{entity_type}/{record_id}` | write |
| `:EntitiesQuery` | `POST /entities/query` | read |

**Relationship to `:DefinitionsRead`/`:DefinitionsWrite`/`:DefinitionsCreate`: deliberately not shared.**
`Letflow.Definitions.ProcessDefinition` (process definitions — the workflow-graph
artefact `Letflow.Routers.Definitions` fronts) and `Letflow.Entities.EntityDefinition`
(entity-type schema definitions — this design's artefact) are different persisted
artefacts with different lifecycles, different authors, and no structural relationship
beyond sharing the English word "definition." Reusing `:DefinitionsWrite` would let
any `PROCESS_DESIGNER` (who holds it) silently gain entity-schema-authoring rights the
day this subsystem ships, with no requirement or REVIEWER sign-off ever having decided
that coupling. New, independent atoms keep the two authorization surfaces separable —
a future requirement can grant/withhold entity-schema rights independently of
process-definition rights, which reuse would foreclose. There is no
`:EntitiesRecordsRead` atom — no route needs one, since record reads only happen via
`:EntitiesQuery` (see §1's "no route reads a record by id" note); minting an unused
permission atom would be dead vocabulary.

**`Letflow.Identity.RoleRegistry` — not needed.** That module (verified by reading it
in full) is R-Co's `TenantRoleStore` port: a tenant-scoped, persisted custom-role-name
registry consumed by a future S3 workflow-engine transition-time lookup (role name →
group UUID). It has no coupling to `Letflow.Api.Authorization`'s closed
5-role/permission matrix (`role_allows?/2`) — none of `:AttachmentsManage`,
`:AttachmentsRead`, `:InstancesAdvanceTimer`, or any other permission atom minted since
REQ-069 has a `RoleRegistry` entry, confirmed by grepping `role_registry.ex` for those
names (zero hits). A new permission atom needs entries only in
`Letflow.Api.Authorization`'s `@permissions` list, new `endpoint_policy_key/2` clauses
for the four routes' method/path pairs, and new `role_allows?/2` matrix arms — the
same three edits every prior new-permission requirement (REQ-076, REQ-212, ISS-0389)
made to that one module. `RoleRegistry` is untouched by this design and by its
eventual implementation.

**Role-matrix mapping (judgment call — flagged for REVIEWER, not silently decided,
same discipline `Letflow.Routers.Instances`' own §6.5 role mapping uses):**

| Role | Grants |
|---|---|
| `PLATFORM_ADMIN` | all four (existing catch-all: `role_allows?(:PLATFORM_ADMIN, _permission), do: true` — unchanged) |
| `PROCESS_DESIGNER` | `EntitiesDefinitionsRead`, `EntitiesDefinitionsWrite`, `EntitiesQuery` |
| `PROCESS_OPERATOR` | `EntitiesDefinitionsRead`, `EntitiesRecordsWrite`, `EntitiesQuery` |
| `TASK_WORKER` | `EntitiesDefinitionsRead`, `EntitiesQuery` |
| `AGENT_RUNNER` | none (existing catch-all: `role_allows?(:AGENT_RUNNER, _permission), do: false` — unchanged) |

Reasoning: schema authoring (`EntitiesDefinitionsWrite`) tracks `PROCESS_DESIGNER`'s
existing `DefinitionsWrite` role (both are "author a definition" actions), not
`PROCESS_OPERATOR`'s. Record authoring (`EntitiesRecordsWrite`) tracks
`PROCESS_OPERATOR`'s existing `InstancesStart`/`InstancesCancel`/`AttachmentsManage`
grants (both are "operate on live tenant data" actions), not `PROCESS_DESIGNER`'s.
Every role that can read anything in this subsystem also gets `EntitiesQuery`,
mirroring how every role holding `InstancesRead` in the existing matrix also holds
`AttachmentsRead`.

## 4. The query DSL over HTTP, including joins

**Transport: POST body, not GET query string.** `Letflow.Entities.Query.Types.query_request/0`
is:
```
@type query_request :: %{
        required(:entity_type) => String.t(),
        optional(:filters) => [filter_clause()],
        optional(:sort) => [sort_clause()],
        optional(:join) => [join_clause()]
      }
```
where a `filter_clause()` carries `field`/`op`/`value` and a `join_clause()` carries
`entity_type`/`fk`/optional `through`/optional `type`. This is an unboundedly nested
structure (an `:in` filter's `value` is itself a list; up to four `join_clause()`
entries per `Compiler.@max_joins`, each with its own optional `through`) with no
existing flat query-string encoding in this codebase, and no operator-precedence-free
way to express "AND of N structured clauses, each with a typed value" as repeated
`?field=op:value` pairs without inventing a new mini-language this design explicitly
declines to invent. A POST body carrying the request as one JSON object is the direct,
lossless encoding of the type above.

Using POST for a non-mutating read has an existing precedent in this codebase:
`POST /definitions/:id/validate` (`Letflow.Routers.Definitions`) is authenticated,
tenant-scoped, and non-mutating, declared with `authz_post`/`:DefinitionsRead` (a read
permission on a POST route) for exactly the same reason — the request shape needs a
body. `POST /entities/query` follows that precedent, gated by the read permission
`:EntitiesQuery`.

Request body shape: `{"entity_type": "...", "filters": [...], "sort": [...], "join": [...], "cursor": "...", "page_size": N}`
— `cursor`/`page_size` are `Letflow.Entities.Query.Cursor.paginate/5`'s own
`paginate_opts()` fields, carried at the top level of the same body rather than as a
nested sub-object, matching how every other paginated GET route in this codebase
carries `cursor`/`page_size` as flat, sibling parameters (`Letflow.Routers.Definitions.handle_list/1`,
`Letflow.Routers.Instances.handle_list/1`).

**Router-side pre-parsing, before `compile/2` is ever called.** `filter_clause().op`
and `sort_clause().dir` are typed as the closed atoms `Types.filter_op()`/
`Types.sort_dir()`, not raw strings — `Letflow.Entities.Query.Types`' own moduledoc
states it is "the **only** functions in this subsystem that ever see a caller-supplied
raw operator/direction string." The router's `query` handler therefore calls
`Types.parse_filter_op/1` per filter clause's raw `"op"` string and
`Types.parse_sort_dir/1` per sort clause's raw `"dir"` string **before** constructing
the `query_request()` map handed to `compile/2` — mapping each function's own
`{:error, {:unknown_operator, raw}}`/`{:error, {:unknown_sort_dir, raw}}` to **400**
(a malformed literal in the request body, the same class of error every other 400 in
this codebase represents — an unparseable primitive, not a semantically-invalid but
well-formed request). This is why `compile/2`'s own `compile_error()` union still
lists `{:unknown_operator, _}`/`{:unknown_sort_dir, _}` (quoted below) even though this
router's own pre-parsing makes them practically unreachable through this route: they
remain mapped for completeness, the same "unreachable but mapped" discipline this
codebase's routers already use elsewhere (e.g. `Letflow.Routers.Instances`'
`:tenant_id_not_accepted` clause).

**`compile/2`'s actual `@spec`, quoted verbatim from `lib/letflow/entities/query/compiler.ex`:**
```elixir
@spec compile(Types.query_request(), prefix :: String.t()) ::
        {:ok, Ecto.Query.t()} | compile_error()

@type compile_error ::
        {:error, :invalid_schema_name}
        | {:error, :entity_type_not_found}
        | {:error, {:unknown_operator, String.t()}}
        | {:error, {:unknown_sort_dir, String.t()}}
        | {:error, {:field_not_allowed, String.t()}}
        | {:error, {:value_arity_mismatch, Types.filter_op()}}
        | {:error, {:invalid_in_value, String.t()}}
        | {:error, {:operator_not_valid_for_type, Types.filter_op(), Definition.field_type()}}
        | {:error, :entity_table_not_found}
        | {:error, {:too_many_joins, non_neg_integer()}}
        | {:error, :join_depth_exceeded}
        | {:error, {:no_through_relation, through :: String.t(), primary :: String.t()}}
        | {:error, {:ambiguous_through_relation, through :: String.t()}}
        | {:error, {:duplicate_join_target, entity_type :: String.t()}}
        | {:error, {:relation_column_not_found, entity_type :: String.t(), column :: String.t()}}
```

**HTTP mapping of `compile_error()` (this design's own mapping, not a new error
vocabulary — it names an HTTP status for each of `compile/2`'s existing return
values):**

| `compile_error()` member | Status | Reasoning |
|---|---|---|
| `{:error, :entity_type_not_found}` | 404 | Unknown entity type is a not-found resource, same as an unknown process-definition id (INV-5 posture — see §5) |
| `{:error, {:unknown_operator, _}}` | 400 | Practically unreachable via this route's own pre-parsing (see above); mapped for completeness |
| `{:error, {:unknown_sort_dir, _}}` | 400 | Same as above |
| `{:error, {:field_not_allowed, _}}` | 422 | Well-formed request, disallowed field — semantic rejection |
| `{:error, {:value_arity_mismatch, _}}` | 422 | Well-formed clause, wrong value arity for its operator |
| `{:error, {:invalid_in_value, _}}` | 422 | `:in`/`:not_in` value was not a list |
| `{:error, {:operator_not_valid_for_type, _, _}}` | 422 | Operator/field-type mismatch |
| `{:error, :entity_table_not_found}` | 422 | A join forced the primary onto a per-type table that does not exist yet — a currently-unsatisfiable request given server state, not a caller-input syntax error |
| `{:error, {:too_many_joins, _}}` | 422 | Exceeds `Compiler.@max_joins` |
| `{:error, :join_depth_exceeded}` | 422 | A `through` join nested a second `:join` — not supported |
| `{:error, {:no_through_relation, _, _}}` | 422 | Declared relation does not exist |
| `{:error, {:ambiguous_through_relation, _}}` | 422 | Declared relation resolves to more than one candidate |
| `{:error, {:duplicate_join_target, _}}` | 422 | Same join target named twice in one request |
| `{:error, {:relation_column_not_found, _, _}}` | 422 | Declaring side's FK column not physically promoted yet |
| `{:error, :invalid_schema_name}` | 500 | Unreachable via this route — `prefix` is server-resolved only (INV-1, §5), never caller-supplied; mapped for completeness only |

`Cursor.paginate/5`'s own error union (`:page_size_too_large`, `:invalid_cursor`,
`:wrong_endpoint`, `:expired`, `:resume_key_arity_mismatch`, `{:field_not_allowed, _}`)
maps exactly the way every other paginated route in this codebase already maps it:
`:page_size_too_large`/`:invalid_cursor`/`:wrong_endpoint`/`:resume_key_arity_mismatch`
→ 400 (`Response.bad_request/2`, matching `Letflow.Routers.Definitions.handle_list/1`'s
own `:invalid_cursor`/`:wrong_endpoint` → `bad_request` mapping); `:expired` → the
dedicated `Response.send_problem(conn, Error.cursor_expired())` path every other
cursor-consuming route already uses; `{:field_not_allowed, _}` → 422 (a sort field that
passed `Compiler`'s own allowlist check but fails `Cursor`'s independent
re-resolution — structurally the same "well-formed, semantically rejected" class as
`compile/2`'s own `{:field_not_allowed, _}`).

## 5. Tenant scoping and the security boundary (INV-1, INV-2, INV-5, INV-7)

Per `docs/agents/instructions/security-invariants.md`. This is a tenant-data path and
SECURITY-REVIEWER is a hard gate on it (§"Security review" below records where that
gate's verdict is attached).

**INV-1 (tenant data isolation).** Every delegate this design routes to
(`Definitions.*`, `Records.*`, `Compiler.compile/2`, `Cursor.paginate/5`,
`FieldGrants.*`) already takes an explicit `prefix :: String.t()` argument and derives
`tenant_id` internally via `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` —
confirmed by reading every module in full (§0's premises). No route in the table above
accepts a caller-supplied tenant id, schema name, or slug in its path, query string, or
body. The one and only source of `prefix` on every route is
`Letflow.Api.Context.scoped_repo_opts/1`'s output, read from `conn.assigns.scoped_opts`
after `Letflow.Plugs.AuthPipeline`/`Letflow.Plugs.TenantStatus` (mounted on
`Letflow.Plugs.ApiPipeline`, ahead of every sub-router's `:dispatch`) resolve it from
the authenticated caller's own token — the same mechanism `Letflow.Routers.Definitions`
and `Letflow.Routers.Instances` already use for every one of their routes. This design
introduces no second scoping mechanism and no route-local `Repo.*` call (`INV-RT-1`,
this codebase's own route-layer boundary — every read/write in the table above happens
inside a context/query module, never in the router itself, matching every other
router's discipline).

**INV-2 (server-side field authorisation) — applied on every read path, including the
joined one.** `POST /entities/query`'s handler calls
`Letflow.Entities.Query.FieldGrants.load_restrictions(user_id, entity_type, prefix)`
(`user_id` from `conn.assigns.auth_context.user_id`, the same source every other
router uses for an actor id — never a caller-supplied field) before ever serialising a
result. For a **non-join** request: `load_restrictions/3` once (for the primary entity
type) → `FieldGrants.redact_page/2` on the `Cursor.paginate/5` result, before
`Response.ok/2` builds the JSON body. For a **join** request: one
`load_restrictions/3` call per distinct entity type present in the result — the
primary's own entity type keyed `:primary`, plus each `join_clause().entity_type`
keyed by that string (never the `through` entity's type, whose row is never exposed —
`Compiler.joined_row()`'s own typedoc) — assembled into the `restriction_sets()` map
`FieldGrants.redact_joined_page/2` expects, then that function applied to the paginated
joined result. `redact_joined_page/2` exists specifically because a joined read can
surface a field on the far side of the join that the caller may not see there even if
they can see it on the primary side (`FieldGrants`' own moduledoc, REQ-300 addendum) —
this design never calls `redact_page/2` on a joined result (wrong shape: `joined_row()`
is not `Latest.t()`) and never skips redaction on the joined branch.

**INV-5 (not-found/forbidden indistinguishability).** `{:error, :entity_type_not_found}`
(query) and `{:error, {:definition_not_found, _}}`/`{:error, {:record_not_found, _}}`
(commands) all fold to `Response.not_found/1` — the same zero-detail 404
`Letflow.Routers.Definitions`' `get_by_id`/`Letflow.Routers.Instances`' `get_by_id`
already return for a cross-tenant probe, because the underlying lookup
(`Definitions.get_active_definition_by_name/2`, `Records.*`'s own
`fetch_active_definition/2`/`fetch_existing_record/2`, `Compiler.resolve_binding_source/2`)
is itself scoped to the caller's own tenant schema via `prefix` — an entity type or
record belonging to another tenant is structurally invisible in that schema, not a
distinguishable "yes but forbidden" case. No handler in this design adds a
cross-tenant existence pre-check to produce a different message, matching every
existing router's own INV-5 discipline (`Letflow.Routers.Definitions`' own moduledoc:
"No handler may add a cross-tenant existence check to produce a nicer message").

**INV-7 (no SQL string interpolation).** Every value this design's handlers pass to
`compile/2`/`Records.*` is either a closed atom (`filter_op()`/`sort_dir()`, already
validated by `Types.parse_filter_op/1`/`parse_sort_dir/1` before this router ever sees
them as atoms) or a plain Elixir term bound as a genuine Ecto/Postgres parameter
inside `Compiler`'s own `dynamic/2`/`fragment/1` construction (§ of `compiler.ex`'s own
moduledoc: "every remaining caller-supplied VALUE is bound as a genuine positional
Ecto/Postgres parameter, never string-interpolated or concatenated into any SQL
text"). This router introduces no new `Repo.query/2` call and no string-built SQL of
its own — the one raw-SQL path in this subsystem (`Records.write_entity_table_row/3`'s
`INSERT ... ON CONFLICT`) is entirely inside the existing `Letflow.Entities.Records`
context module, already parameterised (`Repo.query(sql, all_values, prefix: ...)`),
and is not something this router's handlers touch or duplicate.

## 6. Pagination

**Response envelope:** `{"items": [...], "next_cursor": <string or null>}` — no
`"count"` key. This matches `Letflow.Definitions.list_paginated/2`'s response
(`Letflow.Routers.Definitions.render_list_result/2`) and
`Letflow.Repository.Attachments.list/2`'s response
(`Letflow.Routers.Instances.render_list_attachments/2`, whose own comment states it is
"Deliberately NOT `render_page_result/3`" because that shared Instances helper's extra
`"count"` key is Instances-specific, not a codebase-wide convention).
`POST /entities/query`'s response follows the Definitions/Attachments shape, not
Instances' `render_page_result/3` shape, because a query result's row count is already
recoverable as `length(items)` and no acceptance criterion here asks for a duplicate
key — the same reasoning `Letflow.Routers.Instances`' own attachments-list route
already gives for diverging from its sibling routes on the same file.

**Cursor carriage:** request — `cursor` as a body field alongside `entity_type`/
`filters`/`sort`/`join`/`page_size` (§4); response — `next_cursor` at the top level of
the response body, `null` when no further page exists. This mirrors every other
cursor-paginated route in this codebase (`GET /definitions?cursor=...` →
`{"items":[...],"next_cursor":...}`), diverging only in that the cursor arrives in a
JSON body field rather than a query-string parameter — a consequence of §4's POST-body
transport decision, not an independent choice.

**Citing `Cursor.paginate/5`'s actual signature** (`lib/letflow/entities/query/cursor.ex`):
```elixir
@spec paginate(
        request :: Types.query_request(),
        compiled_query :: Ecto.Query.t(),
        allowlist :: Allowlist.allowlist(),
        opts :: paginate_opts(),
        prefix :: String.t()
      ) ::
        {:ok, Pagination.Page.t(Latest.t())}
        | {:error, :page_size_too_large}
        | {:error, :invalid_cursor}
        | {:error, :wrong_endpoint}
        | {:error, :expired}
        | {:error, :resume_key_arity_mismatch}
        | {:error, {:field_not_allowed, String.t()}}
```
Five positional arguments — the router's `query` handler is the caller that assembles
all five: `request` (the parsed body), `compiled_query` (from `Compiler.compile/2`),
`allowlist` (from `Allowlist.load/2`, already computed as a side effect of `compile/2`
— re-loaded once more here rather than threaded out of `compile/2`'s private state,
matching `Compiler`'s own public/private boundary: `Allowlist.load/2` is idempotent and
side-effect-free within one request), `opts` (`%{cursor: ..., page_size: ...}` from the
body), `prefix` (the same `scoped_opts` prefix every other delegate receives).
`Pagination.Page.t(Latest.t())` is the shape `FieldGrants.redact_page/2` consumes for
the non-join branch; for the join branch, `Compiler.joined_row()` replaces `Latest.t()`
as the page's item type and `FieldGrants.redact_joined_page/2` consumes it instead —
both still `Pagination.Page.t/1`, so `paginate/5` itself needs no branch: it is generic
over its `compiled_query`'s own row shape.

## 7. Error shaping

Reuses `Letflow.Api.Response` (`ok/2`, `created/2`, `bad_request/2`, `unprocessable/2`,
`not_found/1`, `conflict/2`, `internal_error/1`, `send_problem/2`) unchanged — the same
module `Letflow.Routers.Definitions` and `Letflow.Routers.Instances` both use for every
response in this codebase (verified by reading both files in full). No second response
convention is invented for this subsystem. Field-shape validation errors (a malformed
JSON body, a missing required field on `create_record`/`create_definition`) go through
`Letflow.Api.Validation`/`FieldConstraint` + `Response.send_problem(conn, Validation.problem(field_errors))`,
the same RFC 9457 path every other router's write routes already use.

**Command error mapping (`Records.command_error()`):**

| Error | Status |
|---|---|
| `{:definition_not_found, _}` | 404 |
| `{:record_payload_invalid, violations}` | 422, `Response.send_problem/2` with `violations` rendered the same way `Letflow.Routers.Definitions.render_validation/2` already renders `Graph.Violation.t()` — one `%{"code" => ..., "message" => ...}` per violation |
| `{:record_not_found, _}` | 404 |
| `{:record_already_deleted, _}` (only reachable via `update_record/2`; `delete_record/2` treats it as a no-op success per that module's own moduledoc) | 409 |
| `:tenant_not_provisioned` / `:invalid_schema_name` | 500 (unreachable — INV-1, §5) |
| `{:payload_validation_failed, _}` | 422 |
| any other `term()` | 500 (`INV-8` no-detail internal error, matching every other router's own catch-all clause) |

**`create_definition/2`'s `create_error()` mapping:**

| Error | Status |
|---|---|
| `{:validation, violations}` | 422, same violation-list rendering as above |
| `{:repository, _reason}` | 500 (internal — the shared REQ-202 create pipeline failing is not a caller-actionable rejection) |
| `{:persistence, %Ecto.Changeset{}}` | 409 (a `(tenant_id, name, logical_shape_version)` UNIQUE-constraint hit is a duplicate, matching `Letflow.Routers.Definitions.render_write/3`'s own `:duplicate_name_version` → 409 precedent) |
| `:invalid_schema_name` | 500 (unreachable — INV-1) |

**`get_definition/2`/`get_definition_by_name/2`/`get_active_definition_by_name/2`:**
`{:error, :not_found}` → 404; `{:error, :invalid_schema_name}` → 500 (unreachable).

**`list_definitions/2`:** `:page_size_too_large`/`:invalid_cursor`/`:wrong_endpoint` →
400 (matching `Letflow.Routers.Definitions.render_list_result/2`'s own identical
mapping for `Letflow.Definitions.list_paginated/2`); `:expired` →
`Response.send_problem(conn, Error.cursor_expired())`; `:invalid_schema_name` → 500
(unreachable).

**`activate_definition/4`:** `:not_found` → 404; `:empty_group` /
`:duplicate_artifact_in_group` → 422; `{:group, _}` / `{:persistence, _}` /
`{atom(), Ecto.Changeset.t()}` → 422 with one generic detail string (collapsing the
internal reason the same way `Letflow.Routers.Definitions.render_activate/2` already
collapses `ServiceScopeValidator.Violation` into one generic 422 detail, logging the
real reason server-side only); `:invalid_schema_name` → 500 (unreachable).

## 8. Deferred-routes table disposition

Both rows —
```
| `Letflow.Routers.Entities`          | `entities.zig`            | S5/S6 (entity/data-model subsystem)   |
| `Letflow.Routers.EntityQuery`       | `entity_query.zig`        | S5/S6 (same, plus query compiler)     |
```
— are **removed**, not annotated, from `lib/letflow/router.ex`'s deferred-routes table
when the implementation lands, because §2 merges both into one module,
`Letflow.Routers.Entities`, actually mounted at `/entities`. A table documenting
"not yet mounted" routes has nothing left to say once the corresponding module exists
and is forwarded from `Letflow.Plugs.ApiPipeline` — the same clean-removal precedent
`Letflow.Plugs.ApiPipeline`'s own "Mount changes made by REQ-078" section already
establishes for a landed mount (`Letflow.Routers.Validation`'s stub, not merely its
deferred-table row, was deleted outright once REQ-078 established where its one real
route actually lives).

**Which requirement performs the edit:** the first ELIXIR-DEV requirement that creates
`lib/letflow/routers/entities.ex` and adds `forward("/entities", to: Letflow.Routers.Entities)`
to `lib/letflow/plugs/api_pipeline.ex`'s forward list — no such requirement is filed
yet (this design is what a future REQ-ANALYST pass files it against, per the reasoning
in REQ-308's own description: "the route shape settled here is what gaps 2, 3 and 12
each attach to"). That same requirement also adds the four new permission atoms to
`lib/letflow/api/authorization.ex` (§3) and the new `endpoint_policy_key/2` clauses for
the ten routes in §1's table.

## 9. What attaches later — named, not designed

- **Gap 2 (aggregation/reporting queries).** `Letflow.Entities.Query.Compiler` has no
  `count`/`sum`/`group_by` vocabulary today (confirmed by reading `compiler.ex` in
  full — every `build_filter_dynamic`/`build_order_by` clause is a row-level
  comparison or ordering term, never an aggregate). This would attach as either a new
  route alongside `POST /entities/query` or a new optional field on the same request
  body, extending `Letflow.Entities.Query.Types`/`Compiler` with an aggregation
  vocabulary that does not exist yet. Not designed here.
- **Gap 3 (attachments on an entity record).** `Letflow.Repository.Attachments`
  (REQ-211/212) is scoped to `instance_attachments` only — confirmed by its own
  moduledoc and by `Letflow.Routers.Instances`' `/instances/:id/attachments...` routes,
  which take an `instance_id`, not a `(entity_type, record_id)` pair. This would attach
  as new routes nested under `/entities/records/:entity_type/:record_id/attachments`,
  mirroring the Instances shape, once a record-scoped sibling to
  `Letflow.Repository.Attachments` exists. Not designed here.
- **Gap 12 (bulk import/export of entity records).** `Letflow.Definitions.ExportImport`
  moves process definitions, and REQ-303/304/305's solution-pack extension moves
  entity **definitions** (schemas), not entity **records** (data) — confirmed by
  reading `Letflow.Entities.Definitions`' own moduledoc, which names no bulk
  record-level operation. This would attach as new routes alongside
  `/entities/definitions/:id/export`-style pairs once a record-level
  ExportImport-equivalent context module exists. Not designed here.

## 10. Does this warrant a `docs/migration/decisions/` record?

**No — the design artefact alone suffices.** The one-router-vs-two question and the
permission-vocabulary question are both ordinary route-table/authorization-matrix
design choices of the same kind `Letflow.Routers.Definitions`/`Letflow.Routers.Instances`/
`Letflow.Routers.Instances`' REQ-212 attachment routes already made and recorded
entirely inside their own router moduledocs and design docs (`req077-*.md`,
`req212-*.md`) — never promoted to a `docs/migration/decisions/` record. Contrast with
0024 (REQ-295's decision record): that record settled a genuinely cross-cutting
architectural question — how a promotion's DDL is executed per tenant, load-bearing for
every future entity-storage requirement's transaction model. Nothing this design
settles is load-bearing in that sense: a future requirement could, in principle, split
`Letflow.Routers.Entities` into two routers later (at the cost of an invented second
URL prefix) or rename a permission atom, without contradicting any architectural
decision recorded elsewhere — it would just be redoing this document's own ordinary
route-design work. No decision record is filed by this requirement.

## 11. For SECURITY-REVIEWER

This design's own tenant-scoping position is §5 in full — INV-1, INV-2 (including the
joined-read case via `redact_joined_page/2`), INV-5, and INV-7 are each addressed by
name with the concrete mechanism, not an assurance. SECURITY-REVIEWER's verdict on this
design should be recorded as this file's own follow-up section (append below this
line once reviewed) or, if this pipeline's convention is a separate handoff artefact
instead, linked here by its location — either way, the four invariants above must be
addressed by name in that verdict per REQ-308's acceptance criteria, not as a general
pass.

*(Space reserved for SECURITY-REVIEWER's recorded verdict.)*
