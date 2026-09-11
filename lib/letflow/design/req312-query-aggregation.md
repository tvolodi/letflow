# REQ-312 — Aggregation/reporting query capability for entity records (S10 gap 2)

Status: design only. No `lib/` implementation, no route mounted, no migration, no
test. Implements none of `Letflow.Entities.Query.*` — those already exist
(REQ-225..REQ-231, REQ-296..REQ-301, REQ-308..REQ-311). This document specifies the
aggregation vocabulary, route shape, permission vocabulary, tenant-scoping/security
posture, response shape, and out-of-scope boundary that a future ELIXIR-DEV requirement
builds from — mirroring `lib/letflow/design/req308-entity-http-surface.md`'s rigor and
section shape, and extending REQ-311's now-landed HTTP surface (`Letflow.Routers.Entities`)
rather than replacing it.

Per decision 0022 rule 1: this document uses no domain-vertical vocabulary. "entity
type", "entity definition", "entity record", "field", "filter", "join", "aggregate",
"group_by" are this subsystem's own generic nouns (already used, or directly analogous
to nouns already used, by the modules this document fronts), not any one vertical's
objects. §8 below is this document's own textual self-check of that claim.

## 0. Premises re-verified before designing

**`compiler.ex` has no aggregate vocabulary today.** Read `lib/letflow/entities/query/compiler.ex`
in full (1138 lines). Every `build_filter_dynamic/3` clause (lines 300–427) produces a
row-level `==`/`!=`/`>`/`<`/`ilike`/`is_nil` comparison; every `build_order_by/3` clause
(lines 564–586) produces a row-level ordering term. Grep confirms zero hits:

```
$ grep -in "count\|sum\|avg\|min\|max\|group_by" lib/letflow/entities/query/compiler.ex
(no output)
```

`Letflow.Entities.Query.Types.query_request/0` (`lib/letflow/entities/query/types.ex:94-99`)
has three optional fields only — `filters`, `sort`, `join` — no aggregate-shaped field:

```elixir
@type query_request :: %{
        required(:entity_type) => String.t(),
        optional(:filters) => [filter_clause()],
        optional(:sort) => [sort_clause()],
        optional(:join) => [join_clause()]
      }
```

**`/metrics` is unrelated prior art — confirmed, not merely asserted.** Read
`lib/letflow/routers/metrics_exposition.ex` in full. Its own moduledoc states the
governing invariant in capitals: "No metric family emitted by this subsystem EVER
carries a `tenant_id`, `definition_id`, `instance_id`, `task_id`, `actor_id`, or any
other per-tenant or per-entity identifier as a label value" (lines 24-28) — it is
deliberately
**platform-global**, unauthenticated, with zero per-tenant or per-entity-type
branching of any kind (line 22: "Global, platform-wide — one process-wide
`Letflow.Metrics.Registry`, no per-tenant branching of any kind"). It exposes no
per-tenant, per-entity-type aggregate of any kind and is architecturally barred from
ever doing so by its own load-bearing invariant. This design does not cite it as
prior art for anything beyond "this codebase has a separate, unrelated concept of
'aggregate metric' that this design must not be confused with."

**`Allowlist.typed_columns/1` does not exist — corrected against a real grep, and the
actual reuse point named explicitly.** Quoted grep of the file:

```
$ grep -n "typed_columns" lib/letflow/entities/query/allowlist.ex
89:  @spec typed_columns() :: %{String.t() => {atom(), Definition.field_type()}}
90:  def typed_columns do
...
138:  @spec typed_columns(entity_type :: String.t(), prefix :: String.t()) ::
142:  def typed_columns(entity_type, prefix) when is_binary(entity_type) and is_binary(prefix) do
```

Only two arities exist: `typed_columns/0` (the zero-argument fixed-table function,
line 89-90), returning the fixed 7-entry `%{String.t() => {atom(), Definition.field_type()}}`
map every entity type's allowlist always includes; and `typed_columns/2` (the
two-argument, entity-type-and-prefix function, line 138-142), returning that fixed 7
unioned with whatever `Definition.DDL.promoted_columns/1` reports promoted for that
entity type. **There is no `typed_columns/1`.**

Neither existing arity is, in fact, this design's chosen reuse point — this document's
opening claim (an earlier draft, corrected here) was wrong to name `typed_columns/*`
at all as the mechanism a `group_by`/aggregate target field is resolved through.
Calling `typed_columns/0`/`typed_columns/2` directly would only hand back a raw
`{atom(), Definition.field_type()}` or `Definition.field_type()` table — it would
still leave this design to re-implement the exact JSON-field-vs-typed-column shadowing
precedence, the promoted-column existence gating, and the `{:error, {:field_not_allowed, _}}`
rejection shape that `Allowlist.load/2` (line 250) and `Allowlist.resolve_field/2`
(line 386) already fold together into one call. The actual reuse point this design
commits to is that pair — `Allowlist.load/2` then `Allowlist.resolve_field/2` — the
same pair `Compiler.build_one_filter_dynamic/3` (compiler.ex:610-618) already calls for
every filter/sort field today. This is a deliberate refinement of what the
requirement's own text named (`typed_columns/1`, at an arity that does not exist):
`load/2`'s returned `allowlist()` already **is** the per-entity-type, per-tenant closed
set of resolvable names (typed-column fixed 7, promoted typed columns, and
`queried: true` JSON fields, each carrying a `source` and `type`, internally built
from `typed_columns/0` — see `load/2`'s own body, allowlist.ex:271-274, 276-279) —
`resolve_field/2` is the existing, single point where a caller-supplied name either
resolves to an `allowlisted_field()` or is rejected with
`{:error, {:field_not_allowed, field_name}}`. This design invents no second allowlist
and calls no new resolution primitive: a `group_by`/aggregate target field name is
resolved through `Allowlist.resolve_field(allowlist, field_name)` — the exact call
already made for a `filter_clause().field`/`sort_clause().field` today.

**`Compiler.compile/2`'s actual `@spec`, quoted verbatim (`lib/letflow/entities/query/compiler.ex:152-153,92-108`):**
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

**`Letflow.Routers.Entities`' actual route table, quoted verbatim
(`lib/letflow/routers/entities.ex:20-31`):**
```
| Handler | Method/path | Delegate | Permission | Response |
|---|---|---|---|---|
| create_definition | `POST /entities/definitions` | `Letflow.Entities.Definitions.create_definition/2` | `EntitiesDefinitionsWrite` | 201 / 422 / 409 |
| activate_definition | `POST /entities/definitions/:name/activate` | `Letflow.Entities.Definitions.activate_definition/4` | `EntitiesDefinitionsWrite` | 200 / 404 / 422 |
| get_active_definition_by_name | `GET /entities/definitions/active/:name` | `Letflow.Entities.Definitions.get_active_definition_by_name/2` | `EntitiesDefinitionsRead` | 200 / 404 |
| get_definition_by_name | `GET /entities/definitions/by-name/:name` | `Letflow.Entities.Definitions.get_definition_by_name/2` | `EntitiesDefinitionsRead` | 200 / 404 |
| get_definition | `GET /entities/definitions/:id` | `Letflow.Entities.Definitions.get_definition/2` | `EntitiesDefinitionsRead` | 200 / 404 |
| list_definitions | `GET /entities/definitions` | `Letflow.Entities.Definitions.list_definitions/2` | `EntitiesDefinitionsRead` | 200 / 400 |
| create_record | `POST /entities/records/:entity_type` | `Letflow.Entities.Records.create_record/2` | `EntitiesRecordsWrite` | 201 / 404 / 422 |
| update_record | `PUT /entities/records/:entity_type/:record_id` | `Letflow.Entities.Records.update_record/2` | `EntitiesRecordsWrite` | 200 / 404 / 409 / 422 |
| delete_record | `DELETE /entities/records/:entity_type/:record_id` | `Letflow.Entities.Records.delete_record/2` | `EntitiesRecordsWrite` | 200 / 404 |
| query | `POST /entities/query` | `Letflow.Entities.Query.Compiler.compile/2` then `Letflow.Entities.Query.Allowlist.load/2` then `Letflow.Entities.Query.Cursor.paginate/5` then a `Letflow.Entities.Query.FieldGrants` redaction step | `EntitiesQuery` | 200 / 400 / 404 / 422 |
```

The route is declared `authz_post "/query", :EntitiesQuery do handle_query(conn) end`
(`lib/letflow/routers/entities.ex:239`).

**`authorization.ex`'s existing `Entities*` vocabulary, quoted (`lib/letflow/api/authorization.ex`):**
```
$ grep -n "Entities" lib/letflow/api/authorization.ex
64:  ## `Entities*` (REQ-309) — added ahead of their consuming router
...
111:          | :EntitiesDefinitionsRead
112:          | :EntitiesDefinitionsWrite
113:          | :EntitiesRecordsWrite
114:          | :EntitiesQuery
...
473:  def endpoint_policy_key("POST", "/entities/records/:entity_type"), do: :EntitiesRecordsWrite
482:  # needs a body (design §4), so :EntitiesQuery is classified read (design §3)
489:  def endpoint_policy_key("POST", "/entities/query"), do: :EntitiesQuery
584:  def required_permission(:EntitiesDefinitionsRead), do: :EntitiesDefinitionsRead
587:  def required_permission(:EntitiesQuery), do: :EntitiesQuery
```
Four atoms exist today: `:EntitiesDefinitionsRead`, `:EntitiesDefinitionsWrite`,
`:EntitiesRecordsWrite`, `:EntitiesQuery`. No fifth atom exists yet — this design's §3
below states whether one is needed.

**`FieldGrants` re-read in full (`lib/letflow/entities/query/field_grants.ex`, 209
lines, fresh off ISS-0600).** `load_restrictions/3` (line 82) computes, per
`(user_id, entity_type, prefix)`, the `MapSet.t(String.t())` of field names that
user cannot see for that entity type — an anti-join between `entity_field_restrictions`
and `user_entity_grants`, scoped by `prefix`. `redact_field_values/2` (line 112) and
`redact_page/2`/`redact_joined_page/2` (lines 130, 192) redact **after** a page of rows
already exists, replacing a restricted key's value with the sentinel atom
`:__field_redacted__` while the key itself stays present. This mechanism operates on
**already-materialized row data** — it has no notion of "a value derived from, but not
equal to, a restricted field." §4's INV-2 below is exactly the concern this raises for
an aggregate.

## 1. The aggregation vocabulary

**Closed enum of supported aggregate functions**, mirrored on `Types.filter_op()`'s own
closed-atom-enum idiom:

```elixir
@type aggregate_fn :: :count | :sum | :avg | :min | :max
```

Five functions — the four numeric reducers named as this requirement's floor
(`sum`/`avg`/`min`/`max`) plus `count`, which is the one aggregate that needs no target
field at all (`count(*)`-shaped). `min`/`max` are meaningful over any orderable typed
column (`:string`, `:integer`, `:decimal`, `:date`, `:datetime`) exactly the way
`Types.valid_field_types_for/1` already gates `:gt`/`:gte`/`:lt`/`:lte` against a
closed per-operator field-type table (`compiler.ex`'s `check_operator_field_type/2`,
line 255) — `sum`/`avg` are restricted to `:integer`/`:decimal` only, the same
"closed per-function field-type compatibility table" shape, reusing the existing
`Definition.field_type()` enum rather than inventing a parallel one.

**One new closed request shape, additive to `Types`, not a mutation of `query_request()`:**

```elixir
@type aggregate_target :: %{
        required(:fn) => aggregate_fn(),
        optional(:field) => String.t()
      }

@type group_by_clause :: %{required(:field) => String.t()}

@type aggregate_request :: %{
        required(:entity_type) => String.t(),
        required(:aggregates) => [aggregate_target(), ...],
        optional(:group_by) => [group_by_clause()],
        optional(:filters) => [Types.filter_clause()],
        optional(:join) => [Types.join_clause()]
      }
```

`aggregates` is a required, non-empty list (at least one target) — an aggregate
request naming zero aggregate targets is not a meaningful request (it would degenerate
to a plain query, which `POST /entities/query` already serves). `field` on
`aggregate_target()` is required for `:sum`/`:avg`/`:min`/`:max`, forbidden for
`:count` (mirroring `Compiler.check_value_arity/2`'s existing "this operator requires
no value / this operator requires exactly one value" arity-checking idiom, line
233-241, applied here to "this aggregate function requires no field / requires exactly
one field").

**`group_by` targets resolve against the existing allowlist, not a second one.** Each
`group_by_clause().field` and each `aggregate_target().field` is resolved via
`Allowlist.resolve_field(allowlist, field_name)` — the identical call
`Compiler.build_one_filter_dynamic/3` already makes for a `filter_clause().field`
(compiler.ex:614) and `build_all_order_bys/3` already makes for a `sort_clause().field`
(compiler.ex:622). An unresolvable name produces the same
`{:error, {:field_not_allowed, field_name}}` `Allowlist.resolve_field/2` already returns
today — no new error atom for "field not found," reusing the existing one.

**`filters`/`join` compose with aggregation in one `Ecto.Query.t()` — filter first, then
aggregate.** An aggregate request MAY carry `filters` and `join`, with the identical
semantics `POST /entities/query` already gives them: `filters` narrows which rows are
visible before any aggregate function runs over them, and `join` brings in a related
entity's row the same way `Compiler.compile_joined/6` does today (a `group_by`/aggregate
target field, however, is resolved against the **primary** entity type's own allowlist
only — see the scope-boundary note this document inherits directly from
`Types.join_clause()`'s own moduledoc, "`filters`/`sort` continue to resolve
exclusively against the primary entity type's own `Allowlist.load/2` output" — this
design does not lift that restriction for aggregate/group_by targets either, since
lifting it is exactly the kind of open surface area this design's own §6 defers).
Composition into one `Ecto.Query.t()` follows `compile_plain/6`'s own existing shape
byte-for-byte through the `where` stage: build every filter dynamic exactly as today
(`build_all_filter_dynamics/3`), `combine_filters/1` them into one `combined` dynamic,
apply it as a `where` clause to the base query
(`Latest |> where(entity_type) |> where(combined)` for a `:latest`-bound primary, or
the per-type-table equivalent) — then, where `compile_plain/6` would next call
`apply_order_bys/2` and return, this design instead applies a `group_by` clause (for
each resolved `group_by_clause()`, via `Ecto.Query.group_by/3`) and a `select` clause
built from the resolved `aggregate_target()` list (`Ecto.Query.select/3`, one
`count(...)`/`sum(...)`/`avg(...)`/`min(...)`/`max(...)` term per target, plus one term
per `group_by` field so the grouped value is returned alongside each aggregate). This
is one query, compiled in one pass — never two round trips (filter, then aggregate
client-side).

## 2. Route shape

**New sibling route, `POST /entities/query/aggregate` — not a new field on the existing
`POST /entities/query` body.** Justification, against §0's quoted evidence:

`Compiler.compile/2`'s actual `@spec` (quoted above) returns `{:ok, Ecto.Query.t()}` on
success — a **not-yet-executed, row-shaped** query, whose caller (`Letflow.Routers.Entities.handle_query/1`)
threads it through `Cursor.paginate/5` (row-level cursor pagination) and
`FieldGrants.redact_page/2`/`redact_joined_page/2` (row-level redaction). An aggregate
result is not row-shaped in that sense: it produces one row per distinct `group_by`
combination (or exactly one row with no `group_by`), it has no natural "next page" of
rows to cursor through in the same sense (§5 states the actual response shape), and
`FieldGrants.redact_page/2` cannot operate on it at all — it pattern-matches
`%Latest{}`/`%{field_values: _}` shapes (field_grants.ex:138-144), and an aggregate row
has no `field_values` map to redact into. Overloading the same request/response
envelope with a second, structurally incompatible success shape (sometimes a page of
rows, sometimes a table of aggregate values) would force `handle_query/1`'s single
handler to branch its entire post-`compile/2` pipeline on which shape came back — the
same "two structurally different code paths sharing one entry point" problem
`Letflow.Routers.Entities`' own moduledoc already avoids for join-vs-non-join by
keeping both under the *same* route today only because both cases still return
`Pagination.Page.t()`-shaped pages (joined rows are still rows). An aggregate result
is not a page of rows at all — it is a break in kind, not degree, from what
`POST /entities/query` returns, so it gets its own route, matching
`Letflow.Routers.Entities`' own established pattern of one literal path segment per
sub-resource so a route never has to smuggle a second incompatible response shape
through one handler.

**`compile/2` itself does NOT grow an aggregation branch — a new,
`compile_aggregate/2`-shaped function is added alongside it in the same module.**
`compile/2`'s own moduledoc states its returned query is generic and row-shaped
("returns a **not-yet-executed** `Ecto.Query.t()`"); its `compile_error()` union names
exclusively row-query failure modes. Adding aggregation as a fourth internal branch of
`compile/2` (alongside `compile_plain/6`/`compile_joined/6`'s existing dispatch on
`prepared_joins == []`) would require `compile/2`'s own `@spec` to grow a union member
whose success shape is not `Ecto.Query.t()` returning row structs but one returning
scalar/grouped aggregate values — a different return *kind*, not a new case of the same
kind. `compile_plain/6`'s hard non-regression discipline (its own moduledoc note: "a
**plain** (non-join) request ... is **completely unchanged**", REQ-300's own rework
history) is exactly the discipline this design preserves by not touching `compile/2` or
either of its two existing private helpers at all. Instead:

```elixir
@spec compile_aggregate(Types.aggregate_request(), prefix :: String.t()) ::
        {:ok, Ecto.Query.t()} | aggregate_compile_error()

@type aggregate_compile_error ::
        Compiler.compile_error()
        | {:error, {:aggregate_field_required, aggregate_fn()}}
        | {:error, {:aggregate_field_not_allowed, aggregate_fn()}}
        | {:error, {:aggregate_type_not_valid, aggregate_fn(), Definition.field_type()}}
```

`compile_aggregate/2` reuses every existing shared step `compile/2` itself calls
(`check_join_shape/1`, `Allowlist.load/2`, `resolve_binding_source/2`,
`resolve_joins/4`, `build_all_filter_dynamics/3`) — it duplicates none of them — and
adds exactly two new private steps of its own: resolving each `group_by`/aggregate
target field via `Allowlist.resolve_field/2` (§1), and building the `group_by`/`select`
clauses in place of `apply_order_bys/2`. `aggregate_compile_error()`'s three new members
are the aggregate-specific checks with no row-query analogue: a
`sum`/`avg`/`min`/`max` target naming no field, a `count` target naming one anyway, and
an aggregate function applied to a field whose type it does not support (e.g. `:sum`
over a `:string` field).

## 3. Permission vocabulary

**A new atom, `:EntitiesAggregate` — not `:EntitiesQuery` reused.** Grep of
`lib/letflow/api/authorization.ex` (quoted in §0) confirms `:EntitiesQuery` exists
today, classified read, gating exactly one route: `POST /entities/query`
(`endpoint_policy_key("POST", "/entities/query"), do: :EntitiesQuery`, line 489).
Reasoning for a new atom rather than extending `:EntitiesQuery`'s reach to the new
route: REQ-308's own §3 precedent (quoted in that design's own text, reused here as the
governing local convention) explicitly declined to reuse an existing permission atom
across two structurally different capabilities sharing only surface-level similarity
("Reusing `:DefinitionsWrite` would let any `PROCESS_DESIGNER`... silently gain
entity-schema-authoring rights the day this subsystem ships, with no requirement or
REVIEWER sign-off ever having decided that coupling"). The same reasoning applies here
in the opposite direction of severity: an aggregate value can disclose tenant-wide
statistical information about a field (§4's INV-2) that a row-level, cursor-paginated,
individually-redactable `POST /entities/query` read does not disclose in the same way
— a `sum`/`avg` collapses an entire result set's worth of a field's values into one
number, with no per-row granularity for `FieldGrants`' existing per-row sentinel
mechanism to act on (this is precisely §4's hardest point). Coupling that capability to
`:EntitiesQuery`'s existing grant would let every role holding `:EntitiesQuery` today
(every role in REQ-308's own role-matrix table) gain the aggregate capability the
moment this ships, with no independent REVIEWER sign-off on whether that coupling is
correct for a materially riskier read shape. A new atom keeps the two surfaces
independently grantable, the same value REQ-308 §3 states for its own four atoms.

`:EntitiesAggregate` is classified **read**, mirroring `:EntitiesQuery`'s own
classification (an aggregate is non-mutating), and is gated on the same
`POST`-with-a-body transport as `POST /entities/query` for the identical reason (§4 of
REQ-308's design, reused verbatim here): `aggregate_request()`'s `aggregates`/`group_by`/
`filters`/`join` fields are the same class of unboundedly-nested structure `query_request()`
already is, with no flat query-string encoding this design invents.

**Role-matrix mapping (judgment call — flagged for REVIEWER, not silently decided,
same discipline REQ-308's own §3 role table uses):** every role holding `:EntitiesQuery`
in REQ-308's own table (`PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`, plus the
`PLATFORM_ADMIN` catch-all) also gets `:EntitiesAggregate`, on the reasoning that any
role already trusted to read individual rows for an entity type is, at minimum, equally
trusted to read an aggregate over the same rows — the new atom exists to keep the two
*independently revocable* (a future requirement could narrow `:EntitiesAggregate`'s
grant without touching `:EntitiesQuery`'s), not to start them apart. This mapping is
this design's own proposal, not a foreclosed decision — REQUIRING no vertical-specific
reasoning to evaluate, per rule 1.

## 4. Tenant scoping and the security boundary (INV-1, INV-2, INV-5, INV-7)

Per `docs/agents/instructions/security-invariants.md`. This is a tenant-data path;
SECURITY-REVIEWER is a hard gate on it (§9 below is where that verdict is recorded).

**INV-1 (tenant data isolation).** `compile_aggregate/2` takes `prefix :: String.t()`
positionally, exactly as `compile/2` does, and calls the identical `Allowlist.load/2`/
`resolve_binding_source/2`/`resolve_joins/4` primitives that already derive every
physical table/column reference from `prefix` alone (confirmed by §0's reading of
`compiler.ex` in full). The new route, `POST /entities/query/aggregate`, reads `prefix`
from `conn.assigns.scoped_opts` (`Letflow.Api.Context.scoped_repo_opts/1`'s output) —
the same and only source `Letflow.Routers.Entities`' existing moduledoc states for
every route in the module ("No route below accepts a caller-supplied tenant id, schema
name, or slug in its path, query string, or body"). This design introduces no second
scoping mechanism and no route-local `Repo.*` call — the new handler composes
`compile_aggregate/2` then `Repo.all/2` (or `Repo.one/2` for a `group_by`-absent
request, §5), exactly the "router composes existing context/query-module calls, never
executes its own SQL" discipline every other route in this module already follows.

**INV-2, the hard one — a pre-compilation field-access check, not a post-hoc redaction
of an aggregate value.** `FieldGrants`'s existing mechanism (§0's re-read) redacts a
*materialized row's* field value in place, replacing it with a sentinel while the row
still carries every other field. That mechanism does not compose with an aggregate:
`SUM(restricted_field)` never produces a "row" with a `restricted_field` key to
sentinel-redact — the restricted field's information has already been folded into one
opaque number before any row-shaped result exists, and no post-hoc pass over that
number can selectively "un-leak" it while leaving the number meaningful. Redacting the
*whole aggregate result* whenever *any* restricted field is involved is available in
principle but throws away every legitimate aggregate a caller with partial restrictions
could otherwise compute — this design rejects that as needlessly coarse given a more
precise mechanism is available.

**This design's mechanism: reject the request before compilation, at the exact
granularity `FieldGrants.load_restrictions/3` already computes — covering
`aggregates`, `group_by`, AND `filters` fields alike, for this aggregate route only.**
`compile_aggregate/2`'s handler calls `FieldGrants.load_restrictions(user_id, entity_type, prefix)`
— identical call, identical inputs, identical timing relative to compilation as
`POST /entities/query`'s own handler already makes for its own (row-level) redaction —
**before** building the `aggregate_request()` map passed to `compile_aggregate/2`. Every
field named **anywhere** in the request — an aggregate target
(`aggregate_target().field`, when present), a `group_by` target
(`group_by_clause().field`), **and every `filter_clause().field` in the request's own
`filters` list** — is checked against the returned `restriction_set()`: if any such
field is a member, the entire request is rejected —
`{:error, {:aggregate_field_restricted, field_name}}` — mapped to **403** (the field
named exists and is allowlisted, but this caller specifically lacks read access to it —
a `field_name`-carrying variant of the same "you may not act on this named thing" class
REQ-069's own `Letflow.Api.Authorization` already uses 403 for, distinct from 404's "you
cannot even see this exists" and 422's "well-formed but semantically invalid").

**Why `filters` is checked here even though the existing plain `POST /entities/query`
route does not check `filters` this way, and why that is not an inconsistency.** An
earlier draft of this design exempted `filters` fields from this check, reasoning that
`POST /entities/query` already lets a caller filter on a restricted field without that
field's value ever appearing in the (redacted) row-level response — "a pre-existing
boundary, not reopened here." SECURITY-REVIEWER's review of that draft correctly
rejected this reasoning as not holding at this capability's actual strength, and this
revision adopts that finding rather than defending the earlier position:

  - In the **plain row-query path**, filtering on a restricted field and observing
    "empty page vs. non-empty page" is only a weak, single-bit-per-request oracle —
    it costs one request per probed value and reveals only "at least one row
    matches," not a count.
  - **This aggregate route's `count` turns that single bit into an exact integer, and
    `group_by` turns one request into a full per-group breakdown at once.** Composed:
    `filters` on a guessed value of a restricted field, plus `group_by` on an
    unrestricted field, plus `aggregates: [{fn: :count}]`, returns the exact
    per-group row count of every record matching that guessed value in one request.
    Iterating the guess over a small enumerable domain (an `enum_values`-bounded
    `:string` field, a bucketed `:integer`) fully reconstructs the joint distribution
    of the restricted field against every other field, tenant-wide, in a number of
    requests bounded by the enum's cardinality, not by row count — a materially
    stronger channel than the row-query case, not the same one inherited unchanged.
    This is INV-2's rule violated in substance (a restricted field's information
    leaving the server, dressed as a count) even though no response ever carries the
    restricted field's own name as a key.
  - This channel exists **only** because this design pairs `filters` with `count`/
    `group_by` in one request — the plain row-query route has no such pairing and so
    never opens this specific channel. The fix is therefore scoped exactly to where
    the channel is created: `compile_aggregate/2`'s own handler, gating
    `POST /entities/query/aggregate` only. **`POST /entities/query`'s existing
    `filters` behavior is unchanged by this design** — this document does not touch
    `lib/letflow/routers/entities.ex`'s existing `handle_query/1` path, its existing
    `FieldGrants.redact_page/2`/`redact_joined_page/2` calls, or the existing route's
    `filters`-on-a-restricted-field allowance at all; a coarser fix that also
    restricted the plain route's `filters` would be a scope violation this design
    does not commit.

This is deliberately the mechanism the requirement's own text sketches as the shape of
a real answer: "the aggregate target must pass the same allowlist+grant check
`FieldGrants` uses BEFORE compilation, returning a 403/422 if the caller lacks access to
a field named in `sum`/`avg`/`min`/`max`/`group_by`" — extended here, on
SECURITY-REVIEWER's finding, to cover a `filters` field too, since it is this route's
particular composition of `filters` with `count`/`group_by` that creates the leak, not
`filters` alone. This design commits to it, concretely: **check timing** is before
`compile_aggregate/2` is ever called (so no partially-built query referencing a
restricted column is ever constructed); **check scope** is every
`aggregate_target().field`, every `group_by_clause().field`, and every
`filter_clause().field` present anywhere in the `aggregate_request()`, with no
exemption for `filters` on this route; **check source** is
`FieldGrants.load_restrictions/3`, the single existing per-user restriction-set
primitive, called once per request (the primary entity type only — this design does
not extend aggregation across a `join`'s far-side fields at all, since `group_by`/
aggregate/filter targets already resolve against the primary's own allowlist only per
§1); **failure status** is 403, not a silent empty/redacted result, so a caller who
lacks access learns unambiguously that a different request (naming different targets)
is needed, rather than receiving a number they might mistake for a true, if radically
incomplete, aggregate. `count` with no `field` is exempt from the **aggregate-target**
half of this check by construction — it names no field to check there — but a `count`
request's own `filters`/`group_by` fields are checked exactly like any other aggregate
request's; a `sum`/`avg`/`min`/`max` request has no analogous exemption anywhere,
closing the bisection-via-`sum` variant of the same channel SECURITY-REVIEWER's finding
also named (§ "what must change") as a residual if only `count`/`group_by` combinations
were fixed.

**INV-5 (not-found and cross-tenant are the same bytes — one behavior, stated).** An
aggregate request against a nonexistent or another tenant's `entity_type` produces
`{:error, :entity_type_not_found}` from `Allowlist.load/2` (the identical error
`compile/2`'s own `check_join_shape/1`-then-`Allowlist.load/2` sequence already
produces for a plain query against an unknown entity type — `compile_aggregate/2`
calls this same function, unmodified) — mapped to **404**, the same "not-found and
cross-tenant are the same bytes" shape `Letflow.Routers.Entities`' own INV-5 section
already establishes for `POST /entities/query`. This is the "same not-found shape a
plain query would produce" option this requirement's text offers, chosen over the
"same shape as an aggregate over an empty result set" alternative specifically because
an *empty result set* for a real, existing entity type is a materially different case
(a `count` of 0, a `sum` of 0/null) from an entity type that does not exist or belongs
to another tenant at all — collapsing them would mean a caller cannot distinguish
"this entity type has no matching rows" from "you mistyped the entity type" or "this
entity type is not yours," the same detail-loss REQ-308 §5 already rejected for the
row-query case by choosing 404 there too. No handler in this design adds a
cross-tenant existence pre-check to produce a different message (REQ-308 §5's own
stated discipline, inherited verbatim).

**INV-7 (no SQL string interpolation).** Every `group_by`/aggregate target field name
this design's handler passes onward has already been resolved through
`Allowlist.resolve_field/2` (§1) before `compile_aggregate/2` ever builds a `group_by`/
`select` clause from it — the same closed-allowlist gate every filter/sort field passes
through today. `compile_aggregate/2`'s own `group_by`/`select`-building step reuses the
identical `fragment("?", literal(^field_name))` idiom `Compiler.promoted_column_dynamic/3`
(compiler.ex:389-427) and `Compiler.build_order_by/3` (compiler.ex:574-582) already use
for a promoted (non-fixed-7) column reference — Ecto's own parameterized `literal/1`
fragment helper, never string concatenation or interpolation — and the fixed
`field(r, ^column_atom)` reference (compiler.ex:354-376) for a fixed-7 typed column,
with `column_atom` sourced only from `Allowlist.typed_columns/0`'s own closed table,
never `String.to_atom/1` on caller input. No new fragment-building primitive is
introduced by this design; it reuses the two existing ones verbatim.

## 5. Response shape

**Not a `Cursor.paginate/5`-shaped page.** `Cursor.paginate/5`'s own signature
(`lib/letflow/entities/query/cursor.ex`) produces `{:ok, Pagination.Page.t(Latest.t())}`
— a bounded slice of an ordered row set with a `next_cursor` for resuming. An
aggregate result has no such notion: with no `group_by`, the result is exactly one row
(one value per aggregate target); with `group_by`, the result is one row per distinct
grouping-key combination, and "the next page of group combinations" is not a
pagination concept this requirement's scope covers (a future requirement could add
`group_by` result pagination; this design does not, per §6). There is no cursor to
carry and no `next_cursor` field to emit.

**The response envelope is a flat result table, not a page:**
```elixir
@type aggregate_response :: %{
        required(:results) => [aggregate_result_row()]
      }

@type aggregate_result_row :: %{
        optional(:group) => %{String.t() => term()},
        required(:values) => %{String.t() => number() | nil}
      }
```
`results` is always a list — one entry when `group_by` is absent, one entry per
distinct grouping-key combination otherwise (structurally uniform, so the caller never
branches on whether `group_by` was present). `group` is present only when the request
carried `group_by`, keyed by each `group_by_clause().field` name, valued by that
group's own key value. `values` is keyed by a caller-chosen or positional label per
`aggregate_target()` (this design leaves the exact labeling convention — e.g. an
optional `as` field on `aggregate_target()`, or a fixed `"<fn>_<field-or-none>"` string
— as an explicit open item for ELIXIR-DEV to settle at implementation time, since
neither choice touches this design's route/permission/security answers). `:sum`/`:avg`
over zero matching rows yields Postgres's own `NULL` (surfaced as `nil`, never a
fabricated `0`) — `:count` over zero matching rows yields `0`, matching each
function's own SQL-native zero-row behavior rather than this design inventing a
substitute convention.

**Reuses `Letflow.Api.Response` unchanged — no second response envelope module.**
`Response.ok/2` (`lib/letflow/api/response.ex:80`) serializes the `aggregate_response()`
map above exactly as it does any other JSON body; `aggregate_compile_error()`/the 403
field-restriction case map through `Response.bad_request/2`/`Response.unprocessable/2`/
`Response.not_found/1`/a dedicated 403 path (`Letflow.Api.Response` already exposes
status-coded senders for every class this design needs — no new function required on
that module), the same module every other route in `Letflow.Routers.Entities` already
uses (§0's citation of REQ-308 §7).

## 6. Out of scope

Explicitly out of scope for this design and its eventual implementation:

- **No persisted or materialized reporting layer.** Every aggregate is computed
  query-time, in the same request/response cycle, against live data — no summary
  table, no scheduled rollup, no `entity_aggregate_snapshots`-shaped artefact.
- **No dashboard.** This design specifies an HTTP query capability only, consumed
  however a future caller (API client, `web/` UI, a future report-building feature)
  chooses; it does not itself specify or imply any UI.
- **No caching of aggregate results.** Every request recomputes its result from
  current data via the same execution model `compile/2`'s row-query already uses —
  `compile_aggregate/2` returns a not-yet-executed `Ecto.Query.t()`, executed once
  per request, exactly like `compile/2` today. No memoization, no TTL, no
  invalidation-on-write concern is introduced.
- **No aggregation across a `join`'s far-side fields.** `group_by`/aggregate targets
  resolve against the primary entity type's own allowlist only (§1) — extending
  aggregation to a joined entity's own fields (e.g. summing a field on the far side
  of a relation) is not designed here.
- **No pagination of `group_by` result rows.** A `group_by` request producing more
  grouping-key combinations than is reasonable to return in one response is not
  addressed by this design — a future requirement could add a `Cursor`-shaped
  extension for the grouped case specifically; this design commits to none.
- **Not a scope cut: `filters` on a restricted field, for this aggregate route, is
  checked and rejected, not deferred.** An earlier draft of this document mis-filed
  this here as an accepted, pre-existing boundary out of scope for this design.
  SECURITY-REVIEWER found that framing wrong — this route's own composition of
  `filters` with `count`/`group_by` creates a materially stronger information channel
  than the plain row-query route's pre-existing weak oracle (§4's INV-2 section, full
  reasoning). §4 now specifies that check as part of this design's own mechanism, not
  as future work. What remains genuinely out of scope, and unaffected by that fix, is
  narrower: this design does not touch or alter `POST /entities/query`'s own existing
  `filters`-on-a-restricted-field behavior — that route's mechanism is unmodified, per
  §4's own explicit statement of which route the fix is confined to.

## 7. Does this warrant a `docs/migration/decisions/` record?

**No — the design artefact alone suffices**, for the same reasoning REQ-308 §10 gives
for its own, structurally identical route-table/permission-vocabulary/security-boundary
choices: the route-shape choice (§2), the new permission atom (§3), and the
field-access-check-before-compilation mechanism (§4) are all ordinary extensions of
this subsystem's own existing design conventions (REQ-230/231/300/308/311), not a
cross-cutting architectural decision load-bearing for unrelated future work. A future
requirement could, in principle, later add `group_by` pagination or lift the
join-far-side restriction (§6) without contradicting anything this document settles —
it would simply be extending this document's own scope, the same non-foreclosing
relationship REQ-308 §10 describes for its own document.

## 8. Rule 1 self-check — quoted grep, zero hits outside stage bookkeeping

```
$ grep -inE "exam|candidate|question|certificate|score|grade|test-taker|invigilat" \
    lib/letflow/design/req312-query-aggregation.md
535:$ grep -inE "exam|candidate|question|certificate|score|grade|test-taker|invigilat" \
```

One hit, and it is the grep command's own quoted pattern line inside this section —
the pattern text unavoidably matches itself once written into the file it searches
(a trivial self-reference, not a vocabulary leak). Excluding that one self-match line,
there are zero hits in the document's actual prose. The only numeric/bookkeeping token
this document repeats is "S10 gap 2" / "REQ-312", both stage/requirement bookkeeping,
not vertical vocabulary. Every noun this
document uses to describe the mechanism (`entity_type`, `entity record`, `field`,
`filter`, `join`, `aggregate`, `group_by`, `restriction_set`, `allowlist`) is either a
name an already-shipped, already-reviewed generic module in this codebase uses for
itself (`Letflow.Entities.*`), or a direct, domain-neutral extension of one
(`aggregate_target`, `aggregate_request`, `aggregate_response`, `group_by_clause`) coined
by this document for a vocabulary that, by definition (§0), does not exist anywhere in
this codebase yet. This requirement's own title/description/acceptance-criteria text in
`docs/requirements.yaml` was authored by REQ-ANALYST, not this document, and is outside
this document's ability to edit — but a manual read of that entry (performed before
writing this document) found the same zero-hits property already holds there.

## 9. For SECURITY-REVIEWER

This design's own tenant-scoping position is §4 in full — INV-1, INV-2 (the
field-access-check-before-compilation mechanism, the hardest point this design
answers), INV-5, and INV-7 are each addressed by name with a concrete mechanism, not an
assurance. **SECURITY-REVIEWER's recorded verdict is a hard-gate precondition for this
design to proceed to CODE-DESIGN-VALIDATOR sign-off**, per this requirement's own
acceptance criteria — this document does not fabricate one. ORCH should route this
design to SECURITY-REVIEWER next; that agent's verdict should be appended below this
line, addressing INV-1, INV-2, INV-5, and INV-7 by name, exactly as REQ-308's own §11/
its appended verdict do.

## SECURITY-REVIEWER Verdict

**Scope test.** This design introduces a new tenant-data-reading route
(`POST /entities/query/aggregate`), a new permission atom gating it, a new
field-resolution path (`group_by`/aggregate targets through `Allowlist.resolve_field/2`),
and a new pre-compilation authorization check against `FieldGrants.load_restrictions/3`.
It is squarely a tenant-data path. SECURITY-REVIEWER review applies in full.

**Overall verdict: FAIL — BLOCKING.** One applicable invariant (INV-2) has a real
residual gap. Per this role's own governing rule, a single FAIL on an applicable
invariant terminates validation with FAIL regardless of the other three invariants'
individual soundness — there is no partial credit. This design must not proceed to
implementation until §4's mechanism is reworked to close the gap identified below.

### INV-1 (tenant data isolation) — APPLIES, PASS

`compile_aggregate/2` is specified to take `prefix` positionally and to reuse
`Allowlist.load/2` / `resolve_binding_source/2` / `resolve_joins/4` unmodified — the
same primitives that already derive every physical table/column reference from
`prefix` alone in `compile/2`'s existing, shipped row-query path. The new route is
specified to read `prefix` exclusively from `conn.assigns.scoped_opts`
(`Letflow.Api.Context.scoped_repo_opts/1`), with no caller-supplied tenant identifier
anywhere in `aggregate_request()`'s shape (§1's type — `entity_type`, `aggregates`,
`group_by`, `filters`, `join`; no `tenant_id`/`schema`/`prefix` field). No new
`Repo.*` call or second scoping mechanism is introduced; the handler is specified to
compose `compile_aggregate/2` then `Repo.all/2`/`Repo.one/2`, matching every other
route in `Letflow.Routers.Entities`. Confirmed against `lib/letflow/entities/query/allowlist.ex`
(`load/2`, lines ~248-290): every table/column reference `load/2` builds already goes
through `TenantProvisioning.tenant_id_for_schema_name(prefix)` and
`TenantProvisioning.entity_column_exists?(prefix, table_name, name)` — `prefix` is the
only tenant input threaded through, and this design adds no new thread. (a)/(b)/(c) of
INV-1's verification procedure: (a) confirmed — no design element bypasses `:prefix`;
(b) N/A — no migration in this design-only requirement; (c) N/A — no new table/`tenant_id`
column introduced. PASS.

### INV-2 (server-side field authorisation) — APPLIES, **FAIL — residual oracle via `filters` on a restricted field combined with `count`/`group_by`**

The design's core mechanism — reject the whole request with 403 before compilation if
any **aggregate-target or group_by** field is restricted — correctly closes the direct
channel: a restricted field's value can never appear as a `sum`/`avg`/`min`/`max`
result or as a `group` key. That part is sound and is a genuine improvement over "redact
after the fact," which the design correctly identifies as inapplicable to a
already-collapsed scalar.

The gap is the explicit exemption of `filters` fields from that same check, defended in
§4 and §6 solely as "a pre-existing boundary, not reopened here" because
`POST /entities/query` already lets a caller filter on a restricted field without
seeing it in the (redacted) response. That defense does not hold at the strength this
new capability requires, for a reason the design's own text gestures at in the task
prompt this review was assigned but does not itself work through to a conclusion:

- In the **existing row-query path**, filtering on a restricted field and observing
  "empty page vs. non-empty page" is only a **weak, single-bit-per-request** oracle: it
  tells the caller "at least one row matches," and extracting a field's actual value
  (e.g. a numeric salary, a hidden status) via that channel alone requires either many
  requests (bisection over a range) or is bounded by however many distinct values a
  caller can enumerate and probe one at a time. That is a real pre-existing gap, but it
  is throttled by requiring one request per probe.
- **This design's `count` aggregate turns that single bit into an exact integer**, and
  **`group_by` on an unrestricted field turns one request into a full breakdown across
  every group at once.** Concretely: `POST /entities/query/aggregate` with
  `filters: [{field: "restricted_salary_band", op: "eq", value: <guess>}]`,
  `group_by: [{field: "department"}]`, `aggregates: [{fn: :count}]` returns, in one
  request, the exact per-department row count of every record matching the guessed
  value of a field the caller has no read grant on. Iterating `<guess>` over a small
  enumerable domain (a `:string` field with `enum_values`, or a bucketed `:integer`)
  fully reconstructs the joint distribution of the restricted field against every other
  field's values tenant-wide, in a number of requests equal to the enum's cardinality,
  not the row count — a materially stronger channel than the row-query case, not "the
  same boundary." This is precisely INV-2's rule being violated in substance even
  though no response ever carries the restricted field's name as a key: "an
  unauthorised field must never leave the server in the first place" — a caller
  reconstructing a restricted field's distribution via counting is the field's
  information leaving the server, dressed as a count.
- The design's own §1 change of primitives is what makes this materially worse than
  the pre-existing case, so "not reopened here" is not the correct framing — this
  design **is** the thing that reopens it, by adding the first capability
  (`count`/`group_by` composed with `filters`) capable of turning the existing weak
  bit-oracle into a precise counting oracle. §6 lists this as an "open item" alongside
  genuinely deferrable scope cuts (join far-side aggregation, `group_by` pagination) —
  it does not belong in that list; it is a security defect in the mechanism this
  document is supposed to be settling, not a scope boundary.

**What must change (routed back to CODE-DESIGNER, not prescribed here beyond the
requirement):** §4's pre-compilation restriction check must also cover
`filters`-clause fields when the request is an **aggregate** request (this need not,
and per REQ-308/INV-2 scope should not, retroactively change plain
`POST /entities/query` behavior — the risk is specific to aggregation's ability to
collapse many rows into one precise number). Rejecting with the same 403
(`{:error, {:aggregate_field_restricted, field_name}}`) for a restricted `filters`
field on an aggregate request is the minimal fix consistent with the mechanism already
designed; a coarser alternative (e.g. forbidding `filters` on a restricted field only
when combined with `group_by`, or only when the aggregate function is `count`) would
still leave the `sum`/`avg`/`min`/`max`-plus-filter-on-restricted-field channel open
(e.g. bisecting a restricted field's value via whether `sum(unrestricted_field)`
changes) and is not recommended without a specific argument for why that residual is
acceptable. This is CODE-DESIGNER's call to make explicitly, not SECURITY-REVIEWER's
to make for them — but it must be made, and re-reviewed.

FAIL. BLOCKER.

### INV-5 (not-found/forbidden indistinguishability) — APPLIES, PASS

The design specifies that a nonexistent or cross-tenant `entity_type` produces
`{:error, :entity_type_not_found}` from the identical, unmodified `Allowlist.load/2`
call the row-query path already uses, mapped to the identical 404. Confirmed against
`lib/letflow/routers/entities.ex`: `render_query_error(conn, :entity_type_not_found)`
(line 1185) already maps this to `Response.not_found/1` for `POST /entities/query`,
and `Allowlist.load/2`'s own `fetch_active_definition/2` (allowlist.ex) folds both
"never existed" and "exists, belongs to another tenant" into the same
`{:error, :not_found}` → `{:error, :entity_type_not_found}` path via
`Definitions.get_active_definition_by_name/2` — there is no cross-tenant-specific
branch anywhere in that chain to produce a distinguishable response or an extra
round-trip. Because `compile_aggregate/2` is specified to call this same function
unmodified (not a new existence pre-check), there is no timing signal introduced
either. PASS.

### INV-7 (no SQL string interpolation) — APPLIES, PASS

Every `group_by`/aggregate target field name is specified to be resolved through
`Allowlist.resolve_field/2` before any query-building step touches it. Confirmed
against `lib/letflow/entities/query/allowlist.ex`: `resolve_field/2` (the doc block
above `full_fk_def_document/1`) is a single `Map.fetch/2` against the closed
`allowlist()` map built entirely from `typed_columns/0`, `DDL.promoted_columns/1`, and
declared `queried: true` JSON fields — no caller-supplied string reaches a query
builder without first passing through this closed lookup, and a miss short-circuits to
`{:error, {:field_not_allowed, field_name}}` rather than falling through to any
fallback resolution. The design's citation of `fragment("?", literal(^field_name))`
(promoted/JSON columns) and `field(r, ^column_atom)` (fixed-7 typed columns,
`column_atom` sourced only from `typed_columns/0`'s closed table, never
`String.to_atom/1` on caller input) as the two reuse points for building `group_by`/
`select` clauses matches how `compiler.ex` already builds filter/sort clauses today —
no new fragment-building primitive, no string concatenation. PASS.

### Other invariants — scope test

INV-3 (sandboxing): NOT-APPLICABLE — no scripting/plugin surface touched. INV-4
(secrets): NOT-APPLICABLE — no secret material resolved or introduced by this design.
INV-6 (new paths prove scoping): satisfied by this review's own existence and explicit
per-invariant verdicts. INV-8 (no unhandled crashes): the design's error-union style
(`aggregate_compile_error()` as a closed tagged-tuple union, mirroring
`compile_error()`) is consistent with the codebase's existing typed-result idiom; no
bare pattern match on external/tenant input is introduced by anything specified here —
NOT-APPLICABLE-BEYOND-DEFAULT / consistent, no defect to flag at the design level (a
real check requires implementation code, which does not exist yet for this
design-only requirement). INV-9 (outbound URL/SSRF): NOT-APPLICABLE — no outbound HTTP
request of any kind in this design.

### Disposition

Route back to CODE-DESIGNER: rework §4 (and correspondingly §6, which currently
mis-files this as a deferred scope item rather than a defect) to close the
`filters`-on-a-restricted-field channel for aggregate requests specifically, per the
"what must change" note above. Once reworked, this review must be re-run against the
revised §4/§6 before CODE-DESIGN-VALIDATOR/ORCH treat this design as security-cleared —
a narrower follow-up check of the revised mechanism, not a full re-review of §§1-3/5/7-8
which are unaffected by this finding.

---

## SECURITY-REVIEWER Verdict — re-check of the §4/§6 rework (2026-09-11)

**Scope of this re-check.** CODE-DESIGNER's rework touches only §4 (the INV-2
mechanism) and §6 (reclassifying the fix from a deferred scope item to a closed
defect). §§1-3/5/7-8 are unchanged from the version already checked for INV-1/5/7
above; this section re-confirms those three are unaffected and gives a fresh,
final verdict on INV-2.

**INV-2 — re-checked, PASS, gap closed.** The revised §4 now checks every field
named anywhere in the request — `aggregate_target().field`, `group_by_clause().field`,
**and every `filter_clause().field`** — against `FieldGrants.load_restrictions/3`'s
`restriction_set()` before `compile_aggregate/2` is ever called, with no exemption for
`filters` on this route. I checked both variants of the channel this was meant to
close:

- **`count`/`group_by` variant** (the one I originally found): closed. A `filters`
  entry naming a restricted field now 403s outright, so the "guess a value, filter on
  it, read the exact per-group count" oracle can never be submitted in the first
  place — there is no request shape left that pairs a restricted-field filter with an
  aggregate response.
- **`sum`/`avg`/`min`/`max` bisection variant** (the one I flagged as a risk of the fix
  being papered over for `count` alone): also closed, and by the same mechanism, not a
  separate patch — the check is on `filter_clause().field` regardless of which
  `aggregate_fn` the request also carries, so `sum(unrestricted_field)` with a
  `filters` guess on a restricted field 403s exactly the same as a `count` would. §4's
  own text now confirms this explicitly ("`count`'s own `filters`/`group_by` are
  checked... a `sum`/`avg`/`min`/`max` request has no analogous exemption anywhere").
  I re-derived this rather than taking that sentence on faith: `resolve_field/2` and
  the restriction-set check both run against the flat `filter_clause()` list before
  any aggregate-function-specific branching happens, so there is no code path in the
  design where the check could be skipped based on which `aggregate_fn` is present.

**Join side-channel, checked and ruled out.** I looked for a residual gap the rework
doesn't explicitly discuss: could a `filters` entry target a *joined* entity's field
and bypass the primary-entity-only restriction-set check? No — confirmed against
`Letflow.Entities.Query.Types.join_clause()`'s own pre-existing moduledoc scope
boundary (quoted in this design's §1: "a `join_clause` only says *which* entity to
bring in — `filters`/`sort` continue to resolve exclusively against the primary entity
type's own `Allowlist.load/2` output"). This is an existing, load-bearing constraint
of the query DSL predating REQ-312, not something this design introduces or could
relax — `filters` can never name a joined-side field at all, so "primary entity type
only" restriction-set scoping is not a narrowing that misses joined fields; it is
exactly as wide as `filters` can ever legally reach.

**Scoping to the new route only — correct, not a deferred gap.** The plain
`POST /entities/query` route's own `filters`-on-a-restricted-field allowance is
untouched, and rightly so: that route has no `count`/`group_by` composition, so
filtering there still costs one request per probed value and reveals only
page-non-empty/empty — the pre-existing weak oracle this document never claimed to
fix and that is out of this requirement's scope to touch. Confining the new check to
`compile_aggregate/2`'s own handler is the minimal, correctly-targeted fix, not a
narrower-than-needed one — I did not find a way to reach the count/group_by-amplified
channel through the plain route, since that route has no aggregate vocabulary at all.

**INV-1, INV-5, INV-7 — re-confirmed PASS, unchanged from the prior verdict.** Nothing
in this rework touches `prefix` sourcing, the `entity_type_not_found` → 404 path, or
the `Allowlist.resolve_field/2` → `fragment(literal(...))`/`field(r, ^atom)`
field-reference construction — my earlier verification of each (citing
`allowlist.ex`'s `load/2`/`resolve_field/2` and `entities.ex`'s
`render_query_error(conn, :entity_type_not_found)`) stands without re-derivation, since
none of the code or design text those verdicts depended on changed in this rework.

**Final overall verdict: PASS.** All four invariants named in this requirement's own
acceptance criteria — INV-1, INV-2, INV-5, INV-7 — are APPLIES-and-PASS. This design
is security-cleared to proceed to CODE-DESIGN-VALIDATOR / ORCH for the next pipeline
step.
