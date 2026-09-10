# REQ-300 design — joins in `Letflow.Entities.Query.Compiler` over promoted FK columns

Companion to `docs/migration/decisions/0023-entity-storage-hybrid.md` (the
promotion rule, the entity-vs-blob test, the m2m-is-an-ordinary-entity
decision), `lib/letflow/design/req299-allowlist-per-entity-type.md`
(`Allowlist.typed_columns/2`, additive/uncalled-by-`load/2` as of REQ-299),
and `lib/letflow/design/req298-constraint-fk-activation.md`
(`table_name_for_entity_type/1`, real `REFERENCES`-constrained FK columns).
Signatures, types, and prose only — no implementation code, no function
bodies with real logic, per this project's design-doc discipline (two prior
rework rounds on this branch were exactly this: literal Elixir code found
in a design doc and removed).

## 0. Re-verification findings (mandatory step, done fresh this session)

- `lib/letflow/entities/query/compiler.ex` (current, ~360 lines) re-read in
  full. `compile/2` builds `Latest |> where(entity_type == ^entity_type) |>
  where(^combined) |> apply_order_bys(...)` — queries the **shared**
  `entity_record_latest` table via the `Letflow.Entities.Record.Latest`
  Ecto schema. `build_filter_dynamic/2`/`build_order_by/2` resolve a
  `:typed_column` field via `Map.fetch!(Allowlist.typed_columns(), name)`
  (the **zero-arg**, fixed 7-entry map) and reference the column with
  `field(r, ^column_atom)` against the `Latest` struct. **Confirmed: no
  `join`/`left_join` anywhere in this module.**
- `lib/letflow/entities/query/types.ex` re-read in full. `query_request()`
  today is `%{required(:entity_type), optional(:filters), optional(:sort)}`
  — no join-shaped field exists yet.
- `lib/letflow/entities/query/field_grants.ex` re-read in full (117 lines).
  Its own `left_join`/anti-join (`load_restrictions/3`) computes one
  user's per-entity-type redaction *set* against
  `entity_field_restrictions`/`user_entity_grants` — a completely
  different join, over grant-bookkeeping tables, not entity data. Per the
  requirement's own explicit warning, this design does **not** reuse or
  extend that anti-join as the join mechanism for entity relations. It
  **is** reused, unmodified, as the redaction primitive composed with a
  joined read — see §7.
- `lib/letflow/entities/query/allowlist.ex` re-read in full (current form,
  post-REQ-299). `typed_columns/2` (per-entity-type accessor) exists,
  additive, **not yet called by `load/2`** — `load/2`'s `typed_column_entries`
  is still built from the fixed 7 only (REQ-299 §"REWORK ITERATION 1",
  deliberately deferred to this requirement — see the amended AC8 in
  `docs/requirements.yaml`, and §8 below).
- `lib/letflow/entities/definition.ex` `fk_def()` re-read: `%{required(:name),
  required(:field), required(:references_entity), optional(:references_field)}`.
  Full shape used throughout this design (name to disambiguate multiple
  relations between the same two entity types, field to name the promoted
  column, references_entity/references_field to resolve direction and
  target column).
- `docs/migration/decisions/0023-entity-storage-hybrid.md`'s relations/m2m
  section re-read: "a join table is an ordinary entity type whose promoted
  columns happen to be two foreign keys" (e.g. `question_tags`, fields
  `question_id`/`tag_id`, both `fk_def`s); the entity-vs-blob test cites
  `is_correct` redaction as the reason `answer_options` is its own entity
  type. Both confirmed accurate and load-bearing for §4/§7 below.
- `lib/letflow/design/req298-constraint-fk-activation.md` and
  `req299-allowlist-per-entity-type.md` read for interface precedent —
  this design keeps `Allowlist`/`Compiler`/`Cursor` as the only touched
  modules (plus one additive function in `FieldGrants`, §7), matches
  REQ-299's "new arity of an existing name, not a rename" convention, and
  reuses `TenantProvisioning.table_name_for_entity_type/1` verbatim rather
  than re-deriving a table name anywhere.
- No pre-existing `req300-*` design artefact found under `lib/letflow/design/`.
- **Re-verified fresh this rework cycle (the gap CODE-DESIGN-VALIDATOR's
  rework-cycle-1 review found): `lib/letflow/tenant_provisioning.ex`'s
  `ensure_entity_table/2` (private, ~line 1301) and `do_run_column_promotion/2`
  (private, ~line 1208) read in full, not just cited by name/prose.**
  `ensure_entity_table/2` is called from exactly one place —
  `do_run_column_promotion/2`, itself reachable only from
  `run_column_promotion/1` acting on an existing `ColumnPromotion` row —
  and is a no-op (returns `:ok` without creating anything) if the table
  already exists. There is **no** code path that creates a per-entity-type
  table at definition-creation/activation time independent of a promotion
  actually running. Confirms `lib/letflow/entities/record/projector.ex:300-303`'s
  own comment verbatim: "A rebuild for an entity type with no per-entity-type
  table yet (the ordinary case for every entity type that has never had a
  column promoted) does nothing extra." This is the fact rework cycle 1's
  design got wrong by relying on `table_name_for_entity_type/1` and 0023/0024
  prose alone without tracing *when* `ensure_entity_table/2` actually runs —
  see §3 for the corrected mechanism this drives.
- **New fact this design depends on, confirmed by reading
  `lib/letflow/design/req296-entity-table-ddl-generator.md` and
  `docs/migration/decisions/0024-entity-promotion-ddl-execution.md`**: a
  per-entity-type table's structural columns are `id, record_id,
  field_values, deleted, entity_def_version, last_event_global_seq,
  inserted_at, updated_at` — **`entity_type` is dropped** ("a per-type
  table's rows are all one type by construction"), and **a promoted
  attribute's value stays present in `field_values` too, unconditionally
  ("the blob key is not dropped")** — 0024 §3 step 1. That second fact is
  the key simplification this design leans on: a joined row's *payload*
  never needs to read an individual promoted column back out; it always
  reads `field_values`. Promoted columns exist to be filtered/sorted/joined
  on, not to be the read-side value source.

## 1. `Letflow.Entities.Query.Types` — the request-shape extension

One new optional field on the existing `query_request()` map — not a
parallel API, per the requirement's explicit instruction.

```
@type join_type :: :inner | :left

@type join_clause :: %{
        required(:entity_type) => String.t(),
        required(:fk) => String.t(),
        optional(:through) => String.t(),
        optional(:type) => join_type()
      }

@type query_request :: %{
        required(:entity_type) => String.t(),
        optional(:filters) => [filter_clause()],
        optional(:sort) => [sort_clause()],
        optional(:join) => [join_clause()]
      }
```

- `entity_type` — the entity type to bring into the result: the **far**
  side of the relation (e.g. `"answer_option"`, or `"tag"` for an m2m
  reached through `"question_tags"`).
- `fk` — the `fk_def().name` (not `.field`) that names the relation to
  traverse. Naming the `fk_def` by its stable `name`, not its `field`,
  matches how `Allowlist`/`DDL` already key relations and survives a
  column rename that keeps the same relation name.
- `through` — present only for a many-to-many read: the entity type of the
  join entity (e.g. `"question_tags"`). When present, `fk` names the
  join-entity-to-far-entity relation (e.g. the `fk_def` on
  `"question_tags"` pointing at `"tag"`); the near hop
  (join-entity-to-primary) is resolved automatically (§4).
- `type` — `:inner` (default) or `:left`. Default `:inner` is the
  AC2-driving choice: "a matching and a non-matching related row" only
  reads as a real test of join correctness if the non-matching row is
  excluded by default, which is what `:inner` gives for free; `:left` is
  offered for a caller who explicitly wants the primary row even with no
  related rows, without being this requirement's default.

**Scope boundary, stated explicitly (not a TBD, a deliberate cut):** a
`join_clause` only says *which relation to bring into the result*. It does
**not** let a caller filter or sort on a joined entity's own fields in this
requirement — `filters`/`sort` continue to resolve exclusively against the
primary entity type's own `Allowlist.load/2` output, unchanged. Extending
`filter_clause()`/`sort_clause()` field resolution to a namespaced
`"answer_option.text"`-shaped reference against a joined entity is closed
out as an **open question** (§9) for a future requirement — none of
REQ-300's eight ACs require it (all seven concern retrieving/redacting
joined rows and rejecting bad join requests, not filtering *by* a joined
field), and admitting it now would extend `Allowlist`'s single-entity-type
contract in a way that deserves its own design pass rather than riding in
in this one.

## 2. `Letflow.Entities.Query.Allowlist` — one new accessor, `fk_defs/2`

```
@spec fk_defs(entity_type :: String.t(), prefix :: String.t()) ::
        {:ok, [Definition.fk_def()]}
        | {:error, :invalid_schema_name}
        | {:error, :entity_type_not_found}
```

Mirrors `typed_columns/2`'s own three-step shape (validate prefix, fetch
active definition, decode) and reuses the *same* active-definition fetch
(`fetch_active_definition/2`, already private in this module) — no second
lookup path. The only new work is decoding `"foreign_keys"` into the
**full** `fk_def()` shape (`name`, `field`, `references_entity`,
`references_field`) rather than `typed_columns/2`'s internal
`decoded_fk_def :: %{field: String.t()}`, which only ever needed `.field`.
This is a second, separate private decoder
(`full_fk_def_document/1` or similar), not a widening of the existing
`decoded_fk_def` type used by `entity_type_typed_columns/1` — that
function's own contract (§1.3/§1.4 of the REQ-299 design) is unchanged.

Returns `[]` (not an error) for an entity type with no `foreign_keys` —
same "absence is the common case, not an error" convention
`FieldGrants.load_restrictions/3` already uses for zero restricted fields.

## 3. `Letflow.Entities.Query.Compiler` — a per-binding table choice, not an unconditional repoint

**REWORK (CODE-DESIGN-VALIDATOR rework cycle 1): the original version of
this section unconditionally repointed `compile/2`'s base query at a
per-entity-type table for every call, dropping the `entity_type`
where-clause outright. That is wrong and would have been a real
regression: a per-entity-type table is created **only** lazily, on first
column promotion, via `TenantProvisioning.ensure_entity_table/2` (private,
reachable only from `do_run_column_promotion/2` via `run_column_promotion/1`
for an existing `ColumnPromotion` row) — re-confirmed this session by
reading `lib/letflow/tenant_provisioning.ex` lines 1181–1330 in full. An
entity type that has never had a column promoted (the ordinary case for
every entity type — see `lib/letflow/entities/record/projector.ex:300-303`'s
own comment: "the ordinary case for every entity type that has never had a
column promoted") has an active definition and **no** per-type table,
permanently, by design. Unconditionally repointing `compile/2` at a
per-type table would have returned `{:error, :entity_table_not_found}` for
every ordinary filter/sort request against such an entity type — a
regression against REQ-225..231's already-working behavior. The fix below
makes the base-table choice a **per-binding decision**, not a blanket
switch.**

### 3.1 New/changed `compile_error()` members

```
@type compile_error ::
        ... (all current members, unchanged)
        | {:error, :entity_table_not_found}
        | {:error, {:too_many_joins, non_neg_integer()}}
        | {:error, :join_depth_exceeded}
        | {:error, {:no_through_relation, through :: String.t(), primary :: String.t()}}
        | {:error, {:ambiguous_through_relation, through :: String.t()}}
        | {:error, {:duplicate_join_target, entity_type :: String.t()}}
        | {:error, {:relation_column_not_found, entity_type :: String.t(), column :: String.t()}}
```

`{:field_not_allowed, String.t()}` (already in the union) is **reused
verbatim** — see §6 — for both "join names a field that is not an
`fk_def`" and "join names an `fk_def` that does not exist by that name."
No new error shape is introduced for that case, per the requirement's own
instruction to match the existing convention exactly.

`{:relation_column_not_found, entity_type, column}` (new this rework
cycle, §4.0.2) is a distinct third failure mode alongside
`:entity_table_not_found` and `:field_not_allowed`: the relation is valid
and its declaring table exists, but the specific promoted column the
relation names has not physically landed on that table yet (declared in
the active definition, not yet promoted). See §4.0.2 for the full
scenario and why this is not a reuse of either existing tag.

`{:error, :entity_table_not_found}`'s trigger condition **changes** from
the original (flawed) design: it is no longer an unconditional per-call
check. It fires in exactly one place now (§4's join resolution) — see the
"declarer must have a per-type table" rule below. It is never returned for
a plain, non-join request; a plain request's per-binding table choice
(§3.2 step 2) has no error branch — absence of a per-type table simply
means the binding resolves to `Latest`, which is always valid.

### 3.2 `resolve_binding_source/2` — the one new primitive this fix adds

```
@type binding_source :: {:per_type_table, table_name :: String.t()} | :latest

@spec resolve_binding_source(entity_type :: String.t(), prefix :: String.t()) ::
        {:ok, binding_source()} | {:error, :invalid_entity_type}
```

Body: `TenantProvisioning.table_name_for_entity_type(entity_type)` →
`{:ok, table_name}`, then `TenantProvisioning.entity_table_exists?/2`
(already public, `@doc false`, exported) against `prefix`/`table_name` —
`{:ok, {:per_type_table, table_name}}` if it exists, `{:ok, :latest}`
otherwise. `{:error, :invalid_entity_type}` only for an entity-type string
that fails `table_name_for_entity_type/1`'s own identifier check — not
load-bearing in practice, since `entity_type` has already passed
`Allowlist.load/2`'s active-definition lookup by the time this is called,
same "defensive, not load-bearing" framing the original design used for
its (now-removed) unconditional existence check. Called once per distinct
entity-type binding a given `compile/2` invocation needs: once for the
primary, once for each distinct entity type appearing across the
request's resolved join relations (a `through` entity type used by two
hops resolves its binding source once, reused for both).

This is a **query-time existence check**, not a promotion-state cache —
it reflects whatever `entity_table_exists?/2` reports at the moment
`compile/2` runs, same freshness guarantee the original design's check
had.

### 3.3 `compile/2` — revised step order

`compile/2`'s public `@spec` is unchanged (`query_request(), prefix ::
String.t() -> {:ok, Ecto.Query.t()} | compile_error()`); its body's step
order becomes:

1. `Allowlist.load/2` — as today, but see §8: after this requirement,
   `load/2` marks a promoted `queried: true` field (and every `fk_def`
   field) `source: :typed_column` for its own entity type.
2. **New:** `resolve_binding_source(entity_type, prefix)` (§3.2) for the
   **primary** entity type → `primary_source`. No error branch reachable
   here in practice (see §3.2); this step never returns
   `:entity_table_not_found` — that only happens in step 6, for a join's
   declaring side.
3. For each filter clause: value-arity check, field resolution, operator/
   field-type compatibility, `build_filter_dynamic/2` — unchanged in
   shape; see §3.4 for the one behavioral addition (`"entity_type"`
   special-case), which fires **only when `primary_source` is
   `{:per_type_table, _}`** — when `primary_source` is `:latest` (the
   ordinary, non-promoted case, and every existing REQ-225..231 test),
   filter/sort field resolution is **byte-for-byte identical to today**:
   the fixed-name atom path against `Latest`, `entity_type` a genuine
   physical column compared normally, no special-casing at all.
4. Fold every clause's dynamic into one AND-combined expression — unchanged.
5. For each sort clause: field resolution, `build_order_by/2` — unchanged
   in shape, same §3.4 conditional addition.
6. **New — join resolution (§4):** for each `join_clause()` in
   `Map.get(request, :join, [])`, resolve it against `Allowlist.fk_defs/2`
   and `Allowlist.typed_columns/2` for the relevant entity type(s), in
   request order. Width/depth bound enforced first (§5) before resolving
   any individual clause, so an over-wide request fails fast without
   touching the database for its relations. For each resolved relation,
   §4's "declarer must be on a per-type table" rule applies — this is
   where `{:error, :entity_table_not_found}` can now actually fire,
   defensively, if that guarantee is somehow violated.
7. Assemble the base query **conditionally on `primary_source`** (this
   replaces the original design's unconditional repoint):
   - `primary_source == :latest`: `Latest |> where([r], r.entity_type ==
     ^entity_type)` — **exactly today's code**, unchanged, byte-for-byte.
   - `primary_source == {:per_type_table, table_name}`: `from(r in
     {table_name, nil})`, no `entity_type` where-clause (no such column on
     a per-type table — table selection itself is the scoping). This
     branch is only taken when the primary entity type has actually been
     promoted at least once (AC8's own scenario, and/or primary being a
     join's declaring side, §4) — never for an entity type that has never
     had a column promoted.
8. Apply the combined filter dynamic, resolved join clauses (§4, each
   carrying its own binding-source-driven table and ON condition), and
   order-bys, in that order — `join`s are added to the query before
   `where`/`order_by` purely as an Ecto/SQL-generation-order convenience;
   join clauses never reference the `where`/`order_by` dynamics or vice
   versa, so this ordering has no semantic effect.
9. `{:ok, query}` — still never executed, still never calls `Repo.*`,
   matching this module's unchanged moduledoc invariant.

**Provable non-regression for the plain (non-join) case:** when `request`
has no `join` key (or an empty one) *and* the entity type has never been
promoted, steps 2, 6 are no-ops that touch nothing but a boolean
existence check (`primary_source = :latest`, no join relations to
resolve), step 3/5 take the unchanged fixed-name path, and step 7 takes
the `:latest` branch — the exact same `Latest |> where(entity_type) |>
where(combined) |> apply_order_bys(...)` construction
`compiler.ex`'s current `compile/2` (lines ~81-99) already produces today.
No behavior change, no new error branch reachable, for this case. See §10
for the explicit test.

### 3.4 Column-reference mechanism — the two-path split, gated on binding source

**This dispatch only matters for a binding whose `binding_source` (§3.2)
is `{:per_type_table, _}`.** For a binding resolved to `:latest` (the
ordinary primary case, and any join side that isn't a relation's declarer
and whose entity type happens to have no per-type table either),
resolution is **unchanged from today**: `field(r, ^column_atom)`/
`field(binding, ^column_atom)` against the fixed 7, `entity_type` a real
physical column, no fragment path involved at all. The split below is
additive, reached only for a per-type-table binding.

`build_filter_dynamic/2`/`build_order_by/2`'s `:typed_column` clauses
currently do `{column_atom, _type} = Map.fetch!(Allowlist.typed_columns(),
field_name)` then `field(r, ^column_atom)` — this only works for the fixed
7 structural names, whose atoms (`:record_id`, `:deleted`, …) are
hardcoded, closed, and safe. Once `load/2` also marks a **promoted,
per-entity-type, tenant-declared** attribute name `:typed_column` (§8),
that name has no hardcoded atom, and fabricating one via
`String.to_atom/1`/`String.to_existing_atom/1` on caller/tenant-controlled
data is exactly what `Allowlist`'s own moduledoc (INV-C, `typed_columns/2`)
already forbids. This design resolves that with a second, atom-free
column-reference path, not by loosening INV-C. Both paths below apply only
within a per-type-table binding:

- **Fixed-name path (unchanged):** if `field_name` is a key of
  `Allowlist.typed_columns/0`'s own zero-arg 7-entry map **and is not
  `"entity_type"`**, resolve exactly as today — `field(binding,
  ^column_atom)` with the hardcoded atom from that map, where `binding` is
  whichever `Ecto.Query` binding this field resolves against (`r` for the
  primary, the relevant join alias for a joined field) — same atom, same
  mechanism, only the binding it's applied to varies. This path is
  reachable both for a per-type-table binding (a promoted-column table
  still carries the same fixed structural columns, e.g. `record_id`,
  `deleted`) and is the **only** path ever reachable for a `:latest`
  binding.
- **`"entity_type"` special case (new, small, contained, per-type-table
  only):** reachable **only when the binding in question is
  `{:per_type_table, _}`** — for a `:latest` binding (the ordinary primary
  case, and any join side sourced from `Latest`), `"entity_type"` is a
  real physical column and resolves via the fixed-name path above,
  unchanged from today, full stop. For a per-type-table binding,
  `"entity_type"` stays a valid, allowlisted, `:typed_column`-sourced
  field name (§8 does not remove it from `typed_columns/0`), but it is no
  longer a physical column on that table. Since the relevant entity
  type is already known statically at this point (it is either
  `compile/2`'s own `entity_type` argument for the primary, or a
  `join_clause.entity_type`/resolved through-entity string for a joined
  binding), a filter on `"entity_type"` is evaluated **in Elixir, at
  compile time**, against that known value, and folded into the combined
  dynamic as a constant `dynamic(true)`/`dynamic(false)` — never a SQL
  comparison. `build_order_by/2` on `"entity_type"` similarly degrades to
  a no-op ordering term (every row shares the same value; ordering by it
  contributes nothing, so it is dropped rather than emitted as a
  fabricated constant `ORDER BY`). This is a small, fully-contained
  addition to `build_filter_dynamic/2`/`build_order_by/2`'s own dispatch,
  not a new module or mechanism.
- **Promoted-name path (new, per-type-table only):** any other name
  resolved `:typed_column` by `load/2` (i.e., present in
  `Allowlist.typed_columns/2`'s result but not in the fixed 7) is only
  ever reachable for a per-type-table binding (a `:latest` binding has no
  such names in its allowlist output in the first place, since `load/2`
  resolves promoted names only via `typed_columns/2`'s per-entity-type
  set, which is itself only populated by an actual promotion — see §8).
  Referenced via `dynamic([binding], fragment("?",
  literal(^field_name)))` — Ecto's own `literal/1` fragment helper, which
  emits a properly quoted SQL identifier from a runtime string **without**
  ever producing an Elixir atom. `field_name` reaching this branch has
  already passed `Allowlist.resolve_field/2` (§8's per-entity-type
  allowlist), so it is provably one of that entity type's own real,
  promoted, indexed column names — never an arbitrary caller string. This
  is the "no atom fabrication, but the column is genuinely usable" answer
  `req299-allowlist-per-entity-type.md`'s §5 (INV-C) left open for this
  requirement to close.

Both paths dispatch on the same `Types.filter_op()`/`field_type()`
combinations §5.3/§5.4 of the current module already enumerate — the
`literal/1`-fragment path reuses the exact same per-op dynamic-building
logic as the atom path, only the column reference itself changes shape.

## 4. Join resolution — one primitive, used once for a direct join and twice for `through`

Private (module-internal) resolution primitive:

```
@type join_side :: :primary_owns_fk | :target_owns_fk

@type resolved_relation :: %{
        side: join_side(),
        fk_field: String.t(),
        owner_entity_type: String.t(),
        other_entity_type: String.t()
      }

@spec resolve_relation(
        entity_a :: String.t(),
        entity_b :: String.t(),
        fk_name :: String.t() | :any,
        prefix :: String.t()
      ) :: {:ok, resolved_relation()} | {:error, {:field_not_allowed, String.t()}} | Allowlist's own errors
```

Step order: `Allowlist.fk_defs(entity_a, prefix)` — look for an `fk_def`
named `fk_name` (or, when `fk_name == :any`, the unique `fk_def` at all)
whose `references_entity == entity_b` → `{:primary_owns_fk, ...}` match
against `entity_a`. If not found, `Allowlist.fk_defs(entity_b, prefix)` —
same search with `entity_a`/`entity_b` swapped → `{:target_owns_fk, ...}`.
Neither found → `{:error, {:field_not_allowed, fk_name}}` (§6). This one
primitive is reused for every hop.

### 4.0.1 The per-relation binding-source rule (rework cycle 1's fix — table-level only)

Every `resolved_relation()` names an `owner_entity_type` — the entity type
that **declares** the `fk_def` (whichever of `entity_a`/`entity_b` matched
first). That declaring side is the one this design requires to be sourced
from its own per-type table, and it is **guaranteed to have a table** (not
guaranteed to have *this column on that table* — see §4.0.2, rework cycle
2's fix, for why those two are not the same guarantee):
`Allowlist.fk_defs/2` only returns an entry once **the entity's active
`Definition.t()`** declares that `fk_def` (`fk_defs/2` is, like
`typed_columns/2`, purely definition-JSON-derived — it decodes
`"foreign_keys"` off whatever the *current* active definition document
says, via the same `DDL.promotion_trigger/2`-style membership check
`typed_columns/2` itself uses; it does **not** consult
`ColumnPromotion`/`entity_table_exists?/2` at all), and a per-type table,
once created, is a no-op target for `ensure_entity_table/2` from then on
(§0's re-verified finding) — it does **not** get retrofitted with columns
for attributes promoted, or newly declared in the definition, after the
table's first creation. So the real chain is: *some* column promotion
having run for this entity type at some point in the past (any column,
not necessarily the one this `fk_def` names) guarantees a per-type table
*exists*; it does **not** guarantee that *every currently-declared*
`fk_def`'s column physically exists on that table. §4.0.2 is the
column-level check this gap requires.

Concretely, per resolved relation:

- `side == :target_owns_fk` (the join's **target**, i.e. `join_clause.entity_type`
  for a direct join, or the far entity for a `through` hop, declares the
  `fk_def`): the target's binding **must** be `{:per_type_table, table}` —
  computed via `resolve_binding_source/2` (§3.2) and asserted, not merely
  hoped for: if it comes back `:latest` here, that is the "invariant
  violated elsewhere" case the original design's defensive check was
  guarding, and `compile/2` returns `{:error, :entity_table_not_found}`
  (reusing the existing tag verbatim — no new error shape for this,
  matching §6's own "reuse, don't multiply error tags" convention). The
  primary/near side of that same relation follows the **ordinary**
  per-binding rule (§3.2) — `resolve_binding_source/2` for its own entity
  type, `{:per_type_table, _}` if it happens to have one, `:latest`
  otherwise; either is fine, since only its `record_id` (present, as a
  real typed column, on both physical shapes) is needed for the ON
  condition.
- `side == :primary_owns_fk` (the **primary/near** side declares the
  `fk_def` — e.g. the primary itself has an `fk_def` pointing at the join
  target, or a `through` entity's near hop points back at the primary):
  the declaring side's binding **must** be `{:per_type_table, table}`,
  same assertion/defensive-error rule as above. When the *primary itself*
  is the declarer, this is what determines `primary_source` in §3.3 step
  2's terms — i.e., if any resolved relation in the request has
  `owner_entity_type == primary_entity_type`, `primary_source` **is**
  `{:per_type_table, _}` for the whole query (a single physical binding
  serves both the primary's own filters/sorts and every relation's ON
  condition that needs it — per-type tables carry the same fixed
  structural columns, including `record_id`, so this never breaks an
  unrelated relation where the primary is the *non*-declaring side). The
  other (non-declaring) side of that relation follows the ordinary
  per-binding rule.

### 4.0.2 The per-column existence check (this rework cycle's fix)

**The concrete gap:** entity type `"answer_option"` has field `"text"`
(`queried: true`) promoted first — its per-type table is created at that
moment, carrying only the columns promotable as of *that* definition
version (no `fk_def` existed yet). Later, the active definition is updated
additively to add a new `fk_def` (`"question_fk"`, field `"question_id"`,
`references_entity: "question"`). No `ColumnPromotion` has been
registered/run for `"question_id"` specifically. At this point:
`Allowlist.fk_defs/2` reports `"question_fk"` (it is definition-JSON-derived
only, per §4.0.1); `resolve_binding_source/2` reports
`{:per_type_table, "entity_answer_option"}` for `"answer_option"` (the
table exists, from the earlier `"text"` promotion); §4.0.1's assertion
passes (a table *does* exist) — but the table has no `question_id` column.
Without a further check, §3.4's promoted-name path would emit
`fragment("?", literal("question_id"))` against a table lacking that
column, surfacing as a raw, unhandled Postgres "column does not exist"
error at query *execution* time — never reachable from this design's own
test suite (`compile/2` never executes a query), so this would ship
looking green and fail only in production/integration use.

**The fix:** a new private primitive, colocated with `resolve_binding_source/2`
in `Letflow.Entities.Query.Compiler`:

```
@spec relation_column_exists?(
        schema_name :: String.t(),
        table_name :: String.t(),
        column_name :: String.t()
      ) :: boolean()
```

Mechanism: a direct `Repo.query!/2` against `information_schema.columns`,
matching `TenantProvisioning.entity_table_exists?/2`'s own idiom exactly
(same function, same query style — re-read its actual body this session,
`lib/letflow/tenant_provisioning.ex:1111-1122`): parameterized SQL,
`WHERE table_schema = $1 AND table_name = $2 AND column_name = $3`,
`%Postgrex.Result{rows: []} -> false`, `%Postgrex.Result{rows: [_ | _]} ->
true`. Same `Repo` alias this module already has no dependency on today —
this is a genuinely new DB-touching call in `Compiler`, stated explicitly
rather than glossed over: `compile/2`'s moduledoc invariant ("never calls
`Repo.*`, never executes the query it builds") is about the query it
*returns*, not about every step of compiling it — §3.2's `entity_table_exists?/2`
call already touches `Repo` in exactly this same way, so this is
consistent with a check the design already relies on, not a new class of
side effect.

**Where it's called:** inside §4.0.1's per-relation binding-source rule,
immediately after a declaring side is asserted `{:per_type_table, table}`
— for exactly that resolved relation's `fk_field`, i.e. once per resolved
relation, only for the declaring side, only when that side is a per-type
table (never for a `:latest`-sourced side, which has no promoted columns
to check in the first place). Concretely: after `side == :target_owns_fk`
or `side == :primary_owns_fk` asserts `{:per_type_table, table}` for the
declaring side, call `relation_column_exists?(prefix, table,
resolved_relation.fk_field)` before proceeding to build that relation's ON
condition. This runs strictly inside §3.3 step 6 (join resolution) — it is
never reached by a request with an empty/absent `join` list, since step 6
itself is a no-op in that case (re-confirmed below).

**On a `false` result:** `compile/2` returns a new, precisely-named error
tag rather than reusing `:entity_table_not_found` — the table *does*
exist, so that tag would misdescribe the failure and make debugging
harder for whoever sees it. New member:

```
| {:error, {:relation_column_not_found, entity_type :: String.t(), column :: String.t()}}
```

added to `compile_error()` in §3.1, alongside the other join-era members.
Naming both the entity type and the specific column (not just the column)
follows this module's existing convention of naming the offending value in
the tuple (e.g. `{:unknown_operator, raw}`, `{:too_many_joins, count}`,
§5) rather than a bare atom — a caller/log line reading
`{:relation_column_not_found, "answer_option", "question_id"}` says
exactly what's missing and on which entity type, without needing to cross-
reference which relation was being resolved. This is a genuinely new
failure mode (a promoted-column reference to a column that doesn't
physically exist yet, despite being declared), distinct from "no table at
all" (`:entity_table_not_found`) and from "not a valid relation at all"
(`:field_not_allowed`, §6) — three different causes, three different tags,
matching this module's own error-shape convention of one tag per distinct
cause rather than collapsing them.

**Consistency with REQ-297/298's additive-only check-and-reject idiom:**
this is the same shape as those requirements' own "declared but not yet
backfilled" checks — a definition can additively declare something
(a constraint, here an `fk_def`) ahead of the storage-side work
(constraint activation there, column promotion here) actually catching up,
and the query/activation path that depends on the storage-side state
checks that state directly (via a real DB introspection query, not by
trusting the definition JSON) and returns a named, caller-facing error
rather than either crashing or silently proceeding on a stale assumption.

**Non-regression, re-confirmed for this second fix specifically:**
`relation_column_exists?/3` is called from exactly one place — inside join
resolution (§3.3 step 6, itself only reached when `Map.get(request, :join,
[])` is non-empty). A plain, non-join request never enters step 6 at all
(§3.3's own "steps 2, 6 are no-ops" language, unchanged by this fix), so
`relation_column_exists?/3` is never invoked for such a request — the
`Latest`-backed, unconditional-repoint regression rework cycle 1 fixed
stays fixed; this fix only adds a check *inside* the join path that cycle
1's fix already isolated. §10's existing "Regression" test row (plain
filter/sort, never-promoted entity type, asserting the byte-for-byte
`Latest` query) continues to prove this without modification, since it
carries no `join` key at all.

**Superseded by rework cycle 3, below:** the "called from exactly one
place" claim above described the state before §4.0.3's fix. As of rework
cycle 3, the same column-granularity query (now the shared
`TenantProvisioning.entity_column_exists?/3` primitive, with
`relation_column_exists?/3` delegating to it) is also called from
`Letflow.Entities.Query.Allowlist.load/2`, once per candidate promoted
column name, for every request (join or not) — see §4.0.3.

### 4.0.3 Closing the same gap for the ordinary, non-join filter/sort path (rework cycle 3's fix)

**The gap SECURITY-REVIEWER found and reproduced:** §4.0.1/§4.0.2's
table-then-column existence check was wired in only for the join path
(inside §3.3 step 6). The ordinary, non-join filter/sort path never went
through either check — it only had `Allowlist.load/2`'s rework-cycle-2
table-level gate (§ AC8 note in `allowlist.ex`'s own moduledoc), which is
insufficient for the identical reason §4.0.2 already documents for joins:
0023's additive-declare-then-promote rule lets a definition declare a
*second* `queried: true` field after the per-type table already exists
from an earlier, unrelated field's promotion, with no `ColumnPromotion`
ever run for that second field. Concretely reproduced: entity type
`"widget_gap"` promotes field `"sku"` (its per-type table is created);
its definition is then additively amended to also declare `"batch_code"`
(`queried: true`), never promoted. A plain filter
`%{entity_type: "widget_gap", filters: [%{field: "batch_code", op: :eq,
value: "whatever"}]}` (no `join` key at all) reached
`Allowlist.load/2`, which — checking only table existence — classified
`"batch_code"` `source: :typed_column`; `Compiler.build_filter_dynamic/3`
then built `fragment("?", literal(^"batch_code"))` against a table
lacking that column, and `Repo.all/2` raised an unhandled
`Postgrex.Error` (`undefined_column`) with no `{:error, _}` tuple
anywhere in the path — a genuine regression versus pre-REQ-300 behavior,
where this exact filter always resolved safely via `:json_field` (JSONB
extraction) regardless of promotion state.

**The fix:** move the per-column check from being join-path-only into
`Allowlist.load/2` itself (Option A of the two SECURITY-REVIEWER offered,
chosen because it fixes every consumer of `load/2`'s output — filter,
sort, and any future one — in exactly one place, and because it restores
the pre-existing, always-safe `:json_field` fallback for a
declared-but-unpromoted field rather than introducing a new named-error
failure mode for a case that used to just work silently). Concretely:
`load/2` now filters its `promoted_typed_column_names` candidate set
(§ "REQ-300 AC8" note, table existence, rework cycle 2) through a second,
per-name check —
`TenantProvisioning.entity_column_exists?(prefix, table_name, name)` —
before including a name as `source: :typed_column`; a candidate that
fails this check is simply dropped from `promoted_typed_column_names`,
which (by `load/2`'s existing merge order) lets its `json_field_entries`
entry (built unconditionally from every `queried: true` field, regardless
of promotion state) surface instead — the same `:json_field` resolution
that name would have gotten before any column on its entity type was ever
promoted. No new error tag was needed for this path: unlike the join
path's declaring-side check (§4.0.2), which has no safe fallback (a join
cannot silently degrade to a JSONB comparison across a relation), a plain
filter/sort's `:typed_column` classification always has the always-safe
`:json_field` path available as a fallback.

`Compiler.relation_column_exists?/3` (§4.0.2) is now a thin delegate to
the same `TenantProvisioning.entity_column_exists?/3` primitive
`Allowlist.load/2` calls, rather than each holding its own copy of the
`information_schema.columns` query — one implementation, two callers.

**Non-regression:** an entity type with no columns ever promoted is
unaffected (`entity_table_name_if_exists/2` returns `:error`, same as
before, and `promoted_typed_column_names` is `%{}`, same as before). An
entity type where every promoted-and-declared name has actually been
through `ColumnPromotion` is unaffected (every candidate name passes the
new per-column check, so `promoted_typed_column_names` is unchanged from
what rework cycle 2 already computed). Only the previously-broken case —
a declared-but-not-yet-promoted name on an entity type that already has a
table from a *different* field's promotion — changes behavior, and it
changes from "unhandled crash" to "works exactly as it did pre-promotion."

Either way, the **non-declaring** side of a relation may resolve to
`:latest` — in that case its binding is `Latest` filtered by
`entity_type == ^that_entity_type` in the join's own `on:` clause (Latest
is shared across every entity type, so a join against it needs the same
scoping a top-level query would), exactly mirroring §3.3 step 7's primary
construction, just expressed as a join condition instead of a top-level
`where`.

This closes the defect: a **plain, non-join** request never resolves any
relation (step 6 of §3.3 is a no-op), so this rule never triggers, and
`primary_source` is decided purely by §3.2's ordinary per-binding check —
`:latest` for the ordinary (never-promoted) case, unchanged.

Applied to the two join shapes:

- **Direct join** (`join_clause` with no `through`): one call,
  `resolve_relation(primary_entity_type, join_clause.entity_type,
  join_clause.fk, prefix)`. The `"question"` + `"answer_option"` example
  resolves `:target_owns_fk` (`answer_option`'s `fk_def` named e.g.
  `"question_fk"`, `field: "question_id"`, `references_entity:
  "question"`) — `answer_option`'s binding is asserted
  `{:per_type_table, _}` per the rule above; `question`'s (primary) binding
  follows the ordinary rule and may be `:latest` or its own per-type table.
  ON condition: joined table's `question_id` column (promoted-name path,
  §3.4) equals primary's `record_id` (fixed-name path, on whichever
  physical shape the primary resolved to).
- **Many-to-many** (`join_clause` with `through: "question_tags"`,
  `entity_type: "tag"`, `fk: "tag_fk"`): **two** hops, both resolved by
  this same primitive:
  1. Near hop: `resolve_relation(primary_entity_type, through, :any,
     prefix)` — the join entity is expected to own exactly one `fk_def`
     referencing the primary; `:any` finds it without the caller having to
     name it (there is only ever meant to be one such relation on a join
     entity per side, by 0023's own m2m shape). Zero matches →
     `{:error, {:no_through_relation, through, primary_entity_type}}`;
     more than one match → `{:error, {:ambiguous_through_relation,
     through}}` (both new, named, testable errors, §3.1). This hop's
     `owner_entity_type` is `through` (`question_tags` owns the FK
     pointing back at `question`, per 0023's m2m shape), so `through`'s
     binding is asserted `{:per_type_table, _}` here.
  2. Far hop: `resolve_relation(through, join_clause.entity_type,
     join_clause.fk, prefix)` — named explicitly by `fk`, since a join
     entity's *far* side is exactly the thing `fk` disambiguates (a join
     entity could in principle have more than one outgoing relation on
     that side in a richer schema, even though `question_tags` itself
     does not). This hop's `owner_entity_type` is again `through`
     (`question_tags` owns *both* its FK columns, by construction — 0023's
     "a join table is an ordinary entity type whose promoted columns
     happen to be two foreign keys"), so the **same** `through` binding
     resolved for the near hop is reused for the far hop's ON condition
     too — one physical table, one `Ecto.Query` alias, both hops' ON
     conditions reference it. `join_clause.entity_type` (the far/`"tag"`
     side) follows the ordinary per-binding rule, same as the primary does
     in a direct join.

  The compiled query gets **two** SQL joins for a `through` request: `r
  (question) -> j_through (question_tags) -> j_far (tag)`, both `:inner`
  by default (or both `join_clause.type` — a single `type` governs both
  hops of one `join_clause`, since they are one logical relation from the
  caller's point of view). The join-entity's own row (`question_tags`,
  carrying e.g. `sort_order`) is **not** exposed in the result under this
  requirement — only `r` (primary) and `j_far` (the named
  `join_clause.entity_type`) appear in the joined-row shape (§4.1). Making
  the through-entity's own attributes independently selectable is left as
  an **open question** (§9): none of REQ-300's ACs require it (AC3 only
  requires reading "a parent entity together with its many-to-many-related
  entities through the join entity," which this satisfies), and the join
  entity is always independently queryable as its own entity type (0023's
  own point) for a caller who needs its attributes directly.

Every join target's own `entity_type_not_found`/`invalid_schema_name`
error (from the `Allowlist.fk_defs/2`/`typed_columns/2` calls this
primitive makes) propagates as-is — a join naming an entity type with no
active definition fails exactly like a primary query would.

### 4.1 The compiled query's join clauses and result shape

Each resolved relation becomes one `Ecto.Query.join(query, join_type, [r],
j in {target_table, nil}, on: <dynamic ON condition>, as: <fixed alias
atom>)`. Alias atoms are drawn from a **fixed, compile-time-literal,
pre-declared pool** — `:join_0`, `:join_1`, `:join_2`, `:join_3` — selected
positionally by each `join_clause`'s index in the request's `join` list
(bounded by §5's width cap of 4), **never** derived from the caller's
`entity_type`/`through` strings. This closes the same atom-fabrication
door §3.4 closes for column names, applied to join aliases instead.

Result shape — one new type, `Letflow.Entities.Query.Compiler.entity_row()`
and `joined_row()`:

```
@type entity_row :: %{
        record_id: String.t(),
        field_values: map(),
        deleted: boolean(),
        entity_def_version: binary() | nil,
        last_event_global_seq: integer(),
        inserted_at: NaiveDateTime.t(),
        updated_at: NaiveDateTime.t()
      }

@type joined_row :: %{
        required(:primary) => entity_row(),
        optional(String.t()) => entity_row()
      }
```

`compile/2`'s `select` clause, when `join` is non-empty, produces a
`joined_row()` per output row: `:primary` mapped from `r`'s own structural
columns (§0's fixed 7-minus-`entity_type` set — all fixed atoms, no
fabrication) — **the same `entity_row()` shape regardless of whether `r`
resolved to `Latest` or to primary's own per-type table** (§3.2/§3.3): both
physical shapes carry the identical fixed-7 structural columns, so the
`select` projection is one uniform mapping that never needs to branch on
`primary_source` — plus one entry per `join_clause`, keyed by that clause's
**`entity_type` string** (not its positional alias — the alias is an
internal `Ecto.Query` binding name, never surfaced to a caller), mapped
from the corresponding join binding's own structural columns. A request
naming the same `entity_type` twice in `join` is rejected up front with
`{:error, {:duplicate_join_target, entity_type}}` (§3.1) — otherwise two
entries would collide on the same result key. **`field_values` is always
the read-side payload for every attribute, promoted or not** (§0's
"the blob key is not dropped" fact) — no individual promoted column is
ever selected out by name, sidestepping any further atom-fabrication
question at the `select` layer entirely.

When `join` is empty, `compile/2`'s result row shape is **unchanged from
today** in the ordinary (never-promoted) case: `primary_source` is
`:latest` (§3.2/§3.3), the query is the exact same `Latest`-backed query
compile/2 builds today, and every existing test/caller gets exactly the
row shape it got before, from `Latest`, exactly as before — no new
projection, no new row shape, nothing to adapt to. For an entity type that
**has** been promoted (`primary_source == {:per_type_table, _}`, AC8's own
scenario), the row read back is structurally equivalent to today's
`Latest.t()` minus `entity_type` (that column doesn't exist on that
table), still `entity_row()`-shaped — this is new territory (no such
non-join, promoted-entity-type case existed before this requirement), not
a change to any existing caller's behavior.

## 5. Maximum join depth: **1** (2 for the fixed, non-chainable `through`
   case), width capped at **4** join clauses per request

Two independent, both concrete, both testable bounds:

- **Depth = 1.** A `join_clause()` has no field through which a caller
  could request a join *off* an already-joined entity (there is no nested
  `:join` key inside `join_clause()` — the type itself has no such
  member). `through` is a single, fixed 2-hop construct for the m2m case
  specifically (§4) — it is not itself chainable or nestable; a caller
  cannot request `through` of a `through`. This bound is enforced
  **structurally by the request shape**, not by a runtime check against a
  counter — there is no code path that could produce depth 2 from a
  well-typed request. **Defensively**, since a real caller's request
  arrives as caller-controlled, JSON-decoded data (not a value the type
  system already constrains), `compile/2` explicitly rejects any
  `join_clause` map found to carry a `:join` key of its own with
  `{:error, :join_depth_exceeded}` — this is the "named, testable error"
  the requirement's AC4 asks for, exercised by a fixture request whose
  `join` list contains a map with a nested `join: [...]` key.
- **Width = 4.** `length(Map.get(request, :join, []))` is checked before
  any relation is resolved; exceeding it returns `{:error,
  {:too_many_joins, count}}` with the caller's own requested count named
  in the error, matching this module's existing convention of naming the
  offending value rather than returning a bare atom (e.g.
  `{:unknown_operator, raw}`). 4 is chosen as a concrete, generous-enough
  bound for this vertical's worked examples (a question read together
  with answer_options, tags, and up to two more relations) while still
  being a real, enforced ceiling rather than an arbitrary-precision list.

## 6. Rejecting a non-`fk_def` join request

`resolve_relation/4` (§4) is the single point where this is decided: if
neither entity's `fk_defs/2` contains an entry matching the requested
name/direction, the result is `{:error, {:field_not_allowed, fk_name}}` —
**the exact same tagged tuple shape** `Allowlist.resolve_field/2` already
returns for an unallowlisted filter/sort field. `Compiler`'s existing
`compile_error()` union already carries this shape; no new error tag is
added for this case. This also covers the "join names an entity type with
no `foreign_keys` at all" case for free (`fk_defs/2` returns `{:ok, []}`
for such a type, so the search trivially fails and the same
`field_not_allowed` path is taken) — joins do not open any new
unvalidated-field surface, per the requirement's own AC6 wording.

## 7. `FieldGrants` composition — one new function, everything else untouched

**What changes in `lib/letflow/entities/query/field_grants.ex`: exactly one
new public function, `redact_joined_page/3`, plus one new private helper
it calls. `redacted_sentinel/0`, `load_restrictions/3`,
`redact_field_values/2`, `redact_page/2`, and `redact_item/2` are
unmodified — same signatures, same bodies, same tests still green.** The
module's own internal anti-join (`load_restrictions/3`) is reused
**exactly as designed today, for its original purpose** — computing one
`(user_id, entity_type)`'s restriction set — called once per **distinct
entity type present in the joined result** (the primary's own entity type,
plus each join clause's `entity_type`), never repurposed as any part of
the join *mechanism* itself (which lives entirely in `Compiler`, §3–§5).
This is precisely the distinction the requirement's own text draws: don't
reuse/extend `FieldGrants`' anti-join *as the join mechanism*; do keep
reading from/composing with `FieldGrants` for redaction, which is what
this does.

```
@type restriction_sets :: %{String.t() => restriction_set()}

@spec redact_joined_page(
        Pagination.Page.t(Compiler.joined_row()),
        restriction_sets()
      ) :: Pagination.Page.t(Compiler.joined_row())
```

Mechanism: `Enum.map(page.items, &redact_joined_item(&1, restriction_sets))`
where the new private `redact_joined_item/2` walks **every** key of one
`joined_row()` map — `:primary` and every joined `entity_type` string key
alike, with no special-casing of `:primary` over a joined key — and for
each, calls the **existing, unmodified** `redact_field_values/2` on that
entity's own `field_values`, keyed by `Map.fetch!(restriction_sets,
that_entity's_own_entity_type_string)`. This is the direct answer to AC5's
"keyed by entity-type-of-each-field, not just the primary entity type": a
joined entity's own restriction set (loaded via the entity type it
actually is — `"answer_option"`, not `"question"`) governs its own fields;
the primary's redaction never leaks onto a joined entity's fields and vice
versa, because each is resolved and redacted independently against its own
`entity_type`.

Caller-side composition (documented here since there is no HTTP route yet
to host it — S10 gap 1, explicitly out of this requirement's scope
fence): for a joined request, the caller loads
`restriction_sets = %{primary_entity_type => set0, join1_entity_type =>
set1, ...}` via one `load_restrictions/3` call per distinct entity type
present (primary's own `entity_type`, plus each `join_clause.entity_type`
— `through`'s own entity type is not included, per §4's decision not to
expose the through-entity's row in the result at all), then calls
`redact_joined_page/2` instead of `redact_page/2`. For a non-join request
(`join` absent/empty), `redact_page/2` continues to be the right call,
unchanged — `redact_joined_page/2` is additive, not a replacement.

## 8. AC8 — `Allowlist.load/2` repointed at `typed_columns/2`

`load/2`'s public contract (`@spec`, success/error shapes) is unchanged.
Its body's `typed_column_entries` step changes from "the fixed 7 from
`typed_columns/0`" (REQ-299's deliberately-deferred interim state) to "the
full per-entity-type set from `typed_columns/2`" — i.e., `load/2` now
calls `entity_type_typed_columns/1` (already built, tested in isolation,
and exposed via `typed_columns/2` by REQ-299) instead of hand-copying just
the structural 7. Every name `typed_columns/2` reports — structural **and**
promoted (both `queried: true` fields and every `fk_def.field`) — resolves
`source: :typed_column` in `load/2`'s output for that entity type; a
`queried: true` field that is **not** promoted (impossible under 0023's
promotion rule — `queried: true` is itself one of the two promotion
triggers — so this case cannot occur, stated here rather than left
implicit) would otherwise need to fall back to `source: :json_field`, but
since it structurally cannot arise, no such fallback branch exists in
`load/2`.

This is exactly the wiring `req299`'s own "REWORK ITERATION 1" section
named as *this* requirement's job: "REQ-300 ... also repoints `compile/2`
at per-entity-type tables and gives `build_filter_dynamic/2`/
`build_order_by/2` (or their REQ-300-era replacements) a real way to
resolve a promoted atom" — §3.4's `literal/1`-fragment path is that real
way. `Cursor.resolved_sort_term/2`/`read_sort_value/2` (the two call sites
`req299` also names) get the identical two-path split as §3.4 — same
fixed-name-atom / promoted-name-fragment branch, since both functions
receive the same `allowlisted_field()` shape `Compiler`'s functions do.

The end-to-end AC8 test (through the real `Compiler`/`Cursor` pipeline,
not a mocked allowlist) is exactly this: seed an entity type with a
`queried: true`, non-FK promoted field; run a filter on it through
`compile/2`; assert the produced `Ecto.Query.t()`'s `wheres` contain a
`fragment("?", literal(...))`-shaped expression referencing that field's
name, not a `?->>?` JSONB-extraction fragment (`@string_fragment` et al.
from §5.2 of the current module, unchanged and still used for genuinely
non-promoted `field_values` keys).

## 9. Open questions (explicitly not resolved here)

1. **Filtering/sorting on a joined entity's own fields** (`"answer_option.text"`-
   shaped field references in `filters`/`sort`) is not supported by this
   design — §1's scope boundary. Needs its own `Allowlist`-shape extension
   (a per-join-alias allowlist) if a future requirement wants it.
2. **Exposing the `through`-entity's own row/attributes** in a many-to-many
   joined read (e.g. `question_tags.sort_order`) is not supported — §4.
   The join entity remains independently queryable as its own entity type
   in the meantime.
3. **Pagination/cursor semantics over a joined, fanned-out result** —
   `Cursor.paginate/5`'s keyset logic assumes one row per primary entity;
   a join fans out to one row per (primary × joined-entity) pair. This
   design does not extend `Cursor` to keyset-paginate a joined query (no
   AC requires it); a joined `compile/2` result is assumed to be consumed
   without `Cursor.paginate/5` (e.g. `Repo.all/2` directly, or a caller-side
   `LIMIT`) until a future requirement addresses joined pagination
   specifically. Flagged rather than silently handled.
4. **`references_field` other than the target's `record_id`.** `fk_def()`
   carries `optional(:references_field)`; every worked example in this
   design (and in 0023's own text) targets `record_id`. This design's ON
   conditions always join against the target's `record_id` (fixed-name
   atom path) — if `references_field` is ever set to something else, the
   ON condition described here needs revisiting.  No test in this
   design's plan exercises a non-`record_id` `references_field`.

## 10. Test-coverage plan (mapping to every AC)

| AC | Test |
|---|---|
| AC1 (compiled-structure) | Build a `join` request (direct join, e.g. `question` + `answer_option`); assert `{:ok, %Ecto.Query{joins: joins}} = Compiler.compile(request, prefix)` and `joins != []`, with `qual: :inner` (or `:left` if requested) — asserted on the **query struct**, no execution. |
| AC2 (real fixture join) | Seed a `question` record and two `answer_option` records via `Letflow.Entities.Records.create_record/2` — one whose FK field matches the question's `record_id`, one whose FK field points at a different question. Execute the compiled join query; assert exactly the matching row is returned, the non-matching row is absent. |
| AC3 (m2m as relation) | Seed one `question`, one `tag`, one `question_tags` row linking them (plus a second, unrelated `tag`/`question_tags` pair as the non-matching case). Compile a `join_clause` with `through: "question_tags"`; assert the result contains the linked `tag`, not the unrelated one. |
| AC4 (max join depth) | Two tests: (a) a `join` list of 5 clauses → `{:error, {:too_many_joins, 5}}`; (b) a `join_clause` map with a nested `join: [...]` key → `{:error, :join_depth_exceeded}`. |
| AC5 (FieldGrants composition) | Seed a restricted field on `answer_option` (e.g. `is_correct`) via `entity_field_restrictions`, with one user holding a `user_entity_grants` row and one not. Run the same joined query's result through `FieldGrants.redact_joined_page/2` for each user; assert the grant-holder sees the real value and the non-grant-holder sees `FieldGrants.redacted_sentinel/0` on the **joined** entity's field — the primary entity's own fields unaffected either way. |
| AC6 (non-fk field rejection) | A `join_clause` naming a real allowlisted field that is not any `fk_def` (e.g. `fk: "not_a_relation"`) → `{:error, {:field_not_allowed, "not_a_relation"}}`. |
| AC7 (field_grants.ex diff) | Asserted by code review / `git diff` at implementation time, not a runtime test: only `redact_joined_page/2` and its private helper are new; nothing else in the file changes. Completion report states this explicitly. |
| AC8 (`load/2` repointed, real pipeline) | §8's end-to-end test: a `queried: true`, non-FK promoted field, filtered through the real `Compiler.compile/2`, asserting the compiled query's `wheres` reference the real column via the `literal/1`-fragment path, not a `?->>?` JSONB cast. |
| **Regression (rework cycle 1's fix, §3.2/§3.3, not tied to a single AC)** | Seed an entity type that has **never** had a column promoted (no `ColumnPromotion` row ever run for it — the ordinary case, per `projector.ex:300-303`). Run a plain, non-join filter/sort request through `Compiler.compile/2`; assert `{:ok, query}` is returned (not `{:error, :entity_table_not_found}`) and the compiled query's `from` targets `Letflow.Entities.Record.Latest` with the `entity_type` where-clause present — i.e., the exact same query shape `compile/2` produces today, byte-for-byte, proving the defect CODE-DESIGN-VALIDATOR found in rework cycle 1 (an unconditional repoint that would have broken this exact case) is closed. |
| **Regression (rework cycle 2's fix, §4.0.2, not tied to a single AC)** | Seed an entity type (e.g. `"answer_option"`) with one field (e.g. `"text"`) already promoted — its per-type table exists. Additively update its active definition to declare a **new** `fk_def` (e.g. `"question_fk"`, field `"question_id"`, `references_entity: "question"`) **without** registering/running a `ColumnPromotion` for `"question_id"`. Build a direct `join_clause` naming that relation (primary `"question"`, target `"answer_option"`, `fk: "question_fk"`); assert `Compiler.compile/2` returns `{:error, {:relation_column_not_found, "answer_option", "question_id"}}` — a named, testable error — rather than `{:ok, query}` with a query that would raise a raw Postgres "column does not exist" error only at execution time. A second assertion in the same test: a plain, non-join filter/sort request against the same entity type (querying only `"text"`, the column that *does* exist) still returns `{:ok, query}` unaffected — proving this fix's DB check is reached only on the join path, never on a plain request. |
| **Regression (rework cycle 3's fix, §4.0.3, SECURITY-REVIEWER-reported, not tied to a single AC)** | Seed an entity type (e.g. `"widget_gap"`) with one field (e.g. `"sku"`) already promoted — its per-type table exists. Additively update its active definition to declare a **second**, unrelated `queried: true` field (e.g. `"batch_code"`) **without** registering/running a `ColumnPromotion` for it. Insert a record whose `field_values` carries `"batch_code"` only (never promoted/added as a real column). Compile and **execute** (`Repo.all/2`, not just `compile/2`) a **plain, non-join** filter (`%{entity_type: "widget_gap", filters: [%{field: "batch_code", op: :eq, value: "whatever"}]}`); assert it returns a real result (or empty list) rather than raising `Postgrex.Error`/`undefined_column` — proving `Allowlist.load/2` classified `"batch_code"` `source: :json_field` (JSONB fallback), not `:typed_column`, exactly as it would have before `"sku"` was ever promoted. A second assertion in the same test: a filter on `"sku"` (the column that *does* exist) still resolves via the real `:typed_column`/`literal/1`-fragment path, unaffected. |
| (whole-suite gate) | `mix letflow.check` run in full, real output quoted in the completion report, per the requirement's own final acceptance criterion. |
