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

## 3. `Letflow.Entities.Query.Compiler` — repointing `compile/2` at the per-entity-type table

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
```

`{:field_not_allowed, String.t()}` (already in the union) is **reused
verbatim** — see §6 — for both "join names a field that is not an
`fk_def`" and "join names an `fk_def` that does not exist by that name."
No new error shape is introduced for that case, per the requirement's own
instruction to match the existing convention exactly.

### 3.2 `compile/2` — revised step order

`compile/2`'s public `@spec` is unchanged (`query_request(), prefix ::
String.t() -> {:ok, Ecto.Query.t()} | compile_error()`); its body's step
order becomes:

1. `Allowlist.load/2` — as today, but see §8: after this requirement,
   `load/2` marks a promoted `queried: true` field (and every `fk_def`
   field) `source: :typed_column` for its own entity type.
2. **New:** `TenantProvisioning.table_name_for_entity_type(entity_type)` →
   `{:ok, table_name}`; then `TenantProvisioning.entity_table_exists?/2`
   (already public, `@doc false`, exported) against `prefix`/`table_name`
   — `{:error, :entity_table_not_found}` if absent. (An active definition
   without its table would mean 0024's dual-write/DDL-applied invariant
   was violated elsewhere; this is a defensive, not load-bearing, check.)
3. For each filter clause: value-arity check, field resolution, operator/
   field-type compatibility, `build_filter_dynamic/2` — unchanged in
   shape; see §3.3 for the one behavioral addition (`"entity_type"`
   special-case) `build_filter_dynamic/2`'s typed-column clause needs now
   that the column no longer physically exists.
4. Fold every clause's dynamic into one AND-combined expression — unchanged.
5. For each sort clause: field resolution, `build_order_by/2` — unchanged
   in shape, same §3.3 addition.
6. **New — join resolution (§4):** for each `join_clause()` in
   `Map.get(request, :join, [])`, resolve it against `Allowlist.fk_defs/2`
   and `Allowlist.typed_columns/2` for the relevant entity type(s), in
   request order. Width/depth bound enforced first (§5) before resolving
   any individual clause, so an over-wide request fails fast without
   touching the database for its relations.
7. **New:** assemble the base query as a **schemaless** query against the
   dynamic table name — `from(r in {table_name, nil})` — instead of
   `Latest`. The `where(r.entity_type == ^entity_type)` clause **is
   dropped entirely**: table selection itself is the scoping now (there is
   no `entity_type` column to compare against on a per-entity-type table).
8. Apply the combined filter dynamic, resolved join clauses (§4), and
   order-bys, in that order — `join`s are added to the query before
   `where`/`order_by` purely as an Ecto/SQL-generation-order convenience;
   join clauses never reference the `where`/`order_by` dynamics or vice
   versa, so this ordering has no semantic effect.
9. `{:ok, query}` — still never executed, still never calls `Repo.*`,
   matching this module's unchanged moduledoc invariant.

### 3.3 Column-reference mechanism — the two-path split this repoint requires

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
column-reference path, not by loosening INV-C:

- **Fixed-name path (unchanged):** if `field_name` is a key of
  `Allowlist.typed_columns/0`'s own zero-arg 7-entry map **and is not
  `"entity_type"`**, resolve exactly as today — `field(r, ^column_atom)`
  with the hardcoded atom from that map.
- **`"entity_type"` special case (new, small, contained):** `"entity_type"`
  stays a valid, allowlisted, `:typed_column`-sourced field name (§8 does
  not remove it from `typed_columns/0`), but it is no longer a physical
  column on a per-entity-type table. Since the query's own `entity_type`
  is already known statically (it is `compile/2`'s own `entity_type`
  argument), a filter on `"entity_type"` is evaluated **in Elixir, at
  compile time**, against that known value, and folded into the combined
  dynamic as a constant `dynamic(true)`/`dynamic(false)` — never a SQL
  comparison. `build_order_by/2` on `"entity_type"` similarly degrades to
  a no-op ordering term (every row shares the same value; ordering by it
  contributes nothing, so it is dropped rather than emitted as a
  fabricated constant `ORDER BY`). This is a small, fully-contained
  addition to `build_filter_dynamic/2`/`build_order_by/2`'s own dispatch,
  not a new module or mechanism.
- **Promoted-name path (new):** any other name resolved `:typed_column` by
  `load/2` (i.e., present in `Allowlist.typed_columns/2`'s result but not
  in the fixed 7) is referenced via `dynamic([r], fragment("?",
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
primitive is reused for every hop:

- **Direct join** (`join_clause` with no `through`): one call,
  `resolve_relation(primary_entity_type, join_clause.entity_type,
  join_clause.fk, prefix)`. The `"question"` + `"answer_option"` example
  resolves `:target_owns_fk` (`answer_option`'s `fk_def` named e.g.
  `"question_fk"`, `field: "question_id"`, `references_entity:
  "question"`) — ON condition: joined table's `question_id` column
  (promoted-name path, §3.3) equals primary's `record_id` (fixed-name
  path).
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
     through}}` (both new, named, testable errors, §3.1).
  2. Far hop: `resolve_relation(through, join_clause.entity_type,
     join_clause.fk, prefix)` — named explicitly by `fk`, since a join
     entity's *far* side is exactly the thing `fk` disambiguates (a join
     entity could in principle have more than one outgoing relation on
     that side in a richer schema, even though `question_tags` itself
     does not).

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
door §3.3 closes for column names, applied to join aliases instead.

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
fabrication), plus one entry per `join_clause`, keyed by that clause's
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

When `join` is empty (today's behavior, unchanged), `compile/2`'s result
row shape is **unchanged** — still the plain per-entity-type-table row
shape (structurally equivalent to today's `Latest.t()` minus `entity_type`
and `id`/`.id`, since the query no longer runs against `Latest`). Every
existing test/caller that only ever used the non-join path continues to
get exactly the fields it got before, from the new table instead of the
old one.

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
resolve a promoted atom" — §3.3's `literal/1`-fragment path is that real
way. `Cursor.resolved_sort_term/2`/`read_sort_value/2` (the two call sites
`req299` also names) get the identical two-path split as §3.3 — same
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
| (whole-suite gate) | `mix letflow.check` run in full, real output quoted in the completion report, per the requirement's own final acceptance criterion. |
