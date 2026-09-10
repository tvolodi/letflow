# REQ-298 design — activating `constraint_def` (unique index) and `fk_def.references_entity` (referential integrity)

Extends `Letflow.Entities.Definition.DDL` (REQ-296, `lib/letflow/entities/definition/ddl.ex`)
and `Letflow.TenantProvisioning` (REQ-297's additions, `lib/letflow/tenant_provisioning.ex`).
Implements `docs/migration/decisions/0025-promoted-fk-ondelete-and-localized-text-search-strategy.md`'s
Sub-question 1 answer verbatim: **`ON DELETE RESTRICT`** on every promoted-FK
`REFERENCES` constraint (0025, "Decision" section: *"Every promoted-FK-column
`REFERENCES` constraint uses **`ON DELETE RESTRICT`** (Ecto:
`on_delete: :restrict`)."*). No implementation code below — signatures,
types, and DB schema only.

## 0. Re-verification findings (per this task's mandatory step 1)

- `DDL.generate_table_ddl/2` today takes `(definition, table_name)` and
  returns `{:ok, sql} | {:error, ddl_error()}`; `ddl_error()` is currently
  only `{:invalid_identifier, field: :table_name | :attribute, value: _}`.
  `promoted_columns/1`'s `column_spec()` is currently
  `%{name:, pg_type:, nullable:}` — no FK/constraint awareness at all.
  `build_create_table_sql/3`'s `constraint_lines` are currently a fixed
  `["PRIMARY KEY (\"id\")", "UNIQUE (\"record_id\")"] ++ enum_checks` — no
  `constraints` (`constraint_def()`) or `foreign_keys` (`fk_def()`) input is
  consumed anywhere in this module today.
- `Letflow.Entities.Definition.constraint_def()` is confirmed, read live:
  `%{required(:name) => String.t(), required(:type) => :unique,
  required(:fields) => [String.t(), ...]}` — `:type` is a literal singleton
  `:unique`, not an enum with other members, exactly as REQ-298's own
  description states ("currently always `type: :unique`"). `fk_def()` is
  `%{required(:name), required(:field), required(:references_entity),
  optional(:references_field)}`.
- `Letflow.TenantProvisioning.table_name_for_entity_type/1` is the sole,
  pure, already-shipped `entity_type -> table_name` deriver
  (`"entity_" <> entity_type`, validated via `DDL.valid_identifier?/1`).
  This design resolves an FK target table by calling this exact function
  with `fk_def.references_entity` as input — no new table-naming
  convention, no lookup of the target `Definition.t()` needed, because
  table naming is a pure function of the entity-type string alone (it does
  not depend on any property of the target definition's fields).
- `run_column_promotion/1`'s single-column path
  (`do_run_column_promotion/2` -> `check_additive_only/3` ->
  `add_column_and_mark/3` -> `execute_add_column/3`) issues exactly one
  `ALTER TABLE ... ADD COLUMN "col" pg_type` statement, inside a
  transaction already holding the tenant's advisory lock
  (`run_column_promotion/1`'s own `Repo.transaction/1` wrapping
  `pg_advisory_xact_lock(hashtext(schema_name))`). `create_and_populate_entity_table/3`
  (called from `ensure_entity_table/2`, itself called from
  `do_run_column_promotion/2` before the additive-only check) calls
  `DDL.generate_table_ddl/2` with the **full current** `Definition.t()` — every
  promoted column the entity type has *at that moment*, not just the one
  attribute triggering the current promotion — then `execute_create_table/1`
  (`Repo.query!/1`, rescued into `{:ddl_failed, _}`).
- 0025's exact quote is reproduced in this doc's header above and MUST be
  cited verbatim, unmodified, in `DDL`'s moduledoc per AC3 — this design
  does not re-derive or second-guess it.
- `docs/anti-patterns.md`'s "Modelling many-to-many as an array of
  references on the parent record" entry (read in full) rejects an
  array-of-ids column for three reasons this design must not reproduce:
  unindexed by default, no home for join attributes, invisible to
  `Letflow.Entities.Query.FieldGrants`. This design's mechanism (two
  `fk_def` promoted columns + one `constraint_def` unique-pair index, both
  going through the exact same per-attribute/per-constraint machinery any
  other entity type uses) is precisely the anti-pattern entry's own
  "Correct alternative" — no array type appears anywhere in
  `Definition.field_type()` (`:string | :integer | :decimal | :boolean |
  :date | :datetime | :enum | :json` — no `:array` member exists in this
  closed type at all), so the anti-pattern is structurally unreachable, not
  merely avoided by convention.
- `Letflow.Entities.Records.delete_record/2` (`records.ex:199-219`) issues
  only `UPDATE ... SET deleted = true` (via `upsert_record_latest/3`'s
  `:delete` clause), never a SQL `DELETE` — reconfirmed by re-read, matching
  0025's own citation exactly. This design does not re-derive this; it is
  cited here only as the already-settled reason `ON DELETE RESTRICT` is
  inert on the application's own delete path (0025's reasoning, not
  re-opened here).
- No pre-existing REQ-298-adjacent file exists under `lib/letflow/design/`
  (`ls` shows only `req296-...md` and `req297-...md`).

## 1. Two independent DDL shapes, two different "does it ride the same
   statement" answers

**FK `REFERENCES` (single column) — rides the *same* `ALTER TABLE ADD
COLUMN` statement.** A promoted FK column is always exactly one column
(`fk_def.field`), and Postgres's `ADD COLUMN` syntax accepts a full column
definition including a column-level `REFERENCES ... ON DELETE ...` clause
in one statement:
`ALTER TABLE "<schema>"."<table>" ADD COLUMN "<col>" <pg_type> REFERENCES "<schema>"."<target_table>"("record_id") ON DELETE RESTRICT`.
There is no reason to split this into a second `ALTER TABLE ADD CONSTRAINT`
step — the column and its FK constraint are created together, atomically,
in the transaction already holding the tenant's advisory lock, exactly the
same shape `execute_add_column/3` already uses for a plain column.

**`constraint_def` unique index (potentially multi-column) — needs a
*separate*, follow-up `ALTER TABLE ADD CONSTRAINT` step.** A `constraint_def`
can span N fields (`fields :: [String.t(), ...]`), each of which may be
promoted by an *independent* `ColumnPromotion` row at a *different* time
(the many-to-many worked example's two `fk_def` fields are two separate
promotions). A single-column `ADD COLUMN` statement cannot declare a
multi-column table-level constraint, and even for `N = 1` there is no
guarantee the constraint's one field is being promoted in the same call —
`constraint_def` and `fk_def`/queried-field promotion are declared and
triggered independently in `Definition.t()`. This design therefore
introduces a second, constraint-scoped activation cycle
(`ConstraintActivation`, §4 below) that runs *after* every field a
`constraint_def` references already exists as a real column, and issues
`ALTER TABLE "<schema>"."<table>" ADD CONSTRAINT "<name>" UNIQUE ("f1", "f2", ...)`.

**The `CREATE TABLE` path needs neither split.** `create_and_populate_entity_table/3`
already passes the entity type's *full current* `Definition.t()` to
`DDL.generate_table_ddl/2` — every promoted column and every
`constraint_def`/`fk_def` the entity type has *at that moment* is known
up front, so both the inline column-level `REFERENCES` clauses and the
table-level `UNIQUE (...)` constraint(s) are emitted directly inside the
one `CREATE TABLE` statement, matching how `PRIMARY KEY (\"id\")`/
`UNIQUE (\"record_id\")`/enum `CHECK`s already work today. `ConstraintActivation`
rows exist only for the **retrofit** case: a `constraint_def` added to an
entity type's definition *after* its table already exists.

## 2. `Letflow.Entities.Definition.DDL` changes

### 2.1 `generate_table_ddl/2` gains a third, optional argument

```
@type ddl_error ::
        {:invalid_identifier,
         field: :table_name | :attribute | :constraint_name | :constraint_field,
         value: String.t()}
        | {:missing_fk_target_table, entity_type: String.t()}

@spec generate_table_ddl(
        Definition.t(),
        table_name :: String.t(),
        fk_target_tables :: %{optional(String.t()) => String.t()}
      ) :: {:ok, String.t()} | {:error, ddl_error()}
```

`fk_target_tables` defaults to `%{}` (so every existing call site with the
current 2-arity call keeps compiling and behaving identically for a
definition with no `foreign_keys`). Its keys are `fk_def.references_entity`
values from `definition.foreign_keys`; its values are the already-resolved
physical table name for that target entity type. **This module still does
not invent or apply any table-naming convention itself** — per its own
moduledoc's "pure function, no I/O, no tenant/schema awareness" invariant,
resolving `entity_type -> table_name` (calling
`Letflow.TenantProvisioning.table_name_for_entity_type/1`, §3 below) is the
caller's job, same division of responsibility `table_name` (the entity
type's *own* table name) already has today. If `definition.foreign_keys`
names a `references_entity` with no matching key in `fk_target_tables`,
`generate_table_ddl/2` returns `{:error, {:missing_fk_target_table,
entity_type: that_entity_type}}` rather than silently omitting the
`REFERENCES` clause or guessing a table name.

### 2.2 `column_spec()` gains one field

```
@type column_spec :: %{
        name: String.t(),
        pg_type: String.t(),
        nullable: boolean(),
        references_entity: String.t() | nil
      }
```

`structural_columns/0` sets `references_entity: nil` on every structural
column (none of them are ever FK-promoted). `promoted_columns/1`'s
per-field mapping sets `references_entity` to the matching
`fk_def.references_entity` when `promotion_trigger/2` returned `:fk` for
that field (looked up from `definition.foreign_keys` by `fk_def.field ==
field.name` — the same `fk_field_names` `MapSet` `promoted_columns/1`
already builds is extended to a `field_name -> fk_def` map for this
lookup), and `nil` for a `:queried`-triggered (non-FK) column.
`promoted_columns/1`'s own `@spec` is unchanged (`Definition.t() ->
[column_spec()]`) — only the map shape it returns grows one key.

### 2.3 New private column-line builder step: FK `REFERENCES` clause

`column_sql_line/1` (private) is extended to accept `fk_target_tables` and
emit a `REFERENCES` clause when `column.references_entity` is non-nil:

```
# internal, not part of the module's public contract
@spec column_sql_line(column_spec(), fk_target_tables :: %{String.t() => String.t()}) ::
        {:ok, String.t()} | {:error, ddl_error()}
```

Returns `{:error, {:missing_fk_target_table, entity_type: _}}` (bubbled up
through `build_create_table_sql/3` and `generate_table_ddl/3`, which both
become fallible in the same `with` chain already used for the identifier
checks) when `column.references_entity` has no entry in `fk_target_tables`.
When present, the emitted line is:

```
"<col> <pg_type>[ NOT NULL][ DEFAULT ...] REFERENCES \"<target_table>\"(\"record_id\") ON DELETE RESTRICT"
```

`ON DELETE RESTRICT` is a **fixed literal in this module's source** — never
a caller-supplied or `Definition.t()`-carried value. 0025 names exactly one
policy for every promoted FK; there is no per-field or per-definition
choice to thread through. (Target-table schema-qualification —
`"<schema>"."<target_table>"` vs. bare `"<target_table>"` — is added by
`Letflow.TenantProvisioning`'s `qualify_create_table_sql/3`-style
post-processing at execution time, exactly as it already schema-qualifies
the `CREATE TABLE` statement's own table name today; this module still
emits unqualified SQL text only, per its moduledoc's schema-agnostic
invariant. `Letflow.TenantProvisioning` extends its qualification step, §3
below, to also rewrite the `REFERENCES "..."` target, not just the leading
`CREATE TABLE "..."`.)

### 2.4 New function: `unique_constraint_clauses/1`

```
@spec unique_constraint_clauses(Definition.t()) ::
        {:ok, [String.t()]} | {:error, ddl_error()}
```

Parallel in shape to the existing private `enum_check_constraints/2`, but
public (REQ-297-style reuse: `ConstraintActivation`'s own
`ALTER TABLE ADD CONSTRAINT` text, §4.3, must emit the *identical* clause
body a fresh `CREATE TABLE` would have produced for the same
`constraint_def`, so both paths are built from one shared function, never
two independently-hand-written SQL strings). For each entry in
`Map.get(definition, :constraints, [])` (all currently `type: :unique`):

1. Validate `constraint_def.name` and every entry of `constraint_def.fields`
   via `valid_identifier?/1` — `{:error, {:invalid_identifier, field:
   :constraint_name, value: name}}` or `{:error, {:invalid_identifier,
   field: :constraint_field, value: field_name}}` on the first failure
   found (defence in depth, same posture as `check_column_identifiers/1`;
   `constraint_def` fields are not re-validated against
   `Definition.Validator`'s own rule per this module's stated precondition
   posture, exactly like every other name this module independently
   re-checks).
2. On success, emit
   `~s(CONSTRAINT "#{name}" UNIQUE (#{fields |> Enum.map_join(", ", &~s("#{&1}"))}))`
   — a **named** constraint (not a bare `UNIQUE (...)`), because
   `ConstraintActivation`'s later `ADD CONSTRAINT` for the retrofit case
   must reference the same name for its own idempotent-skip check (§4.3)
   and its `information_schema.table_constraints` existence lookup.

`generate_table_ddl/3`'s `constraint_lines` becomes:
`["PRIMARY KEY (\"id\")", "UNIQUE (\"record_id\")"] ++ enum_checks ++ unique_constraint_lines`,
folded into the same `with` chain that already threads identifier-check
failures and the new `:missing_fk_target_table` failure through to the
function's own `{:error, ddl_error()}` return.

### 2.5 Moduledoc addition (AC3)

`DDL`'s moduledoc gains a new section, `## ON DELETE policy for promoted
FK columns (REQ-298)`, stating the fixed clause and citing
`docs/migration/decisions/0025-promoted-fk-ondelete-and-localized-text-search-strategy.md`,
"Decision" section, "Sub-question 1 — `ON DELETE RESTRICT`" by name and
quoting its one-sentence answer verbatim (reproduced in this design doc's
own header above). The moduledoc explicitly states it does **not**
re-derive or re-justify the choice against `Records.delete_record/2`'s
soft-delete semantics — that reconciliation is 0025's, cited, not repeated.

## 3. `Letflow.TenantProvisioning` changes — FK column promotion

### 3.1 `register_column_promotion/4`'s `column_spec` grows one optional key

```
@spec register_column_promotion(
        entity_type :: String.t(),
        attribute :: String.t(),
        column_spec :: %{
          pg_type: String.t(),
          nullable: true,
          optional(:references_entity) => String.t()
        },
        tenant_ids :: [Ecto.UUID.t()] | :all
      ) :: {:ok, [ColumnPromotion.t()]} | {:error, term()}
```

`references_entity`, when present, is stored verbatim (the **entity-type
string**, e.g. `"tags"` — never a resolved table name) on the new
`ColumnPromotion.references_entity` field (§3.2). Storing the entity type
rather than a pre-resolved table name keeps this row correct even if
`table_name_for_entity_type/1`'s naming convention ever changes — the same
reasoning `entity_type`/`attribute` (not `table_name`/`column_name`
literals baked in ahead of time for the *target*) are already stored as
entity-type-space values elsewhere on this row, resolved to physical names
only at `run_column_promotion/1` time.

### 3.2 `ColumnPromotion` schema: one new nullable field

`lib/letflow/tenant_provisioning/column_promotion.ex` gains one new field:
`references_entity :: String.t() | nil` — the target entity-type string
(not a resolved table name; resolved only at `run_column_promotion/1` time,
§3.3). Added to `@cast_fields` (not `@required_fields` — `nil` for a
`:queried`-triggered, non-FK promotion). `changeset/2`'s validations are
otherwise unchanged.

**New migration** (global table, same placement rules as
`20260909000001_create_entity_column_promotions.exs` — not tenant-scoped,
not added to `test/support/tenant_fixture.ex`'s `@expected_tenant_tables`):
an `alter table(:entity_column_promotions)` adding one nullable
`:references_entity` string column (`size: 255`, matching this table's
other entity-type-space string columns). No index needed on this column
alone — it is only ever read by primary-key (`fetch_column_promotion/1`)
lookup, never queried by its own value.

### 3.3 `run_column_promotion/1`'s internal flow gains one resolution step

`do_run_column_promotion/2` (private) gains, immediately after
`ensure_entity_table/2` succeeds and before `check_additive_only/3`:

```
@spec resolve_fk_target_table(ColumnPromotion.t()) ::
        {:ok, target_table :: String.t() | nil} | {:error, :invalid_fk_target_entity_type}
```

Returns `{:ok, nil}` when `promotion.references_entity` is `nil` (the
common, non-FK case — no behavior change). When non-nil, calls
`table_name_for_entity_type(promotion.references_entity)`; a `{:error,
:invalid_entity_type}` result (only reachable if a row bypassed
`register_column_promotion/4`'s own input, matching this module's existing
"unreachable via this module's own public surface, checked anyway"
defence-in-depth posture for `checked_table_name/1`) is remapped to
`{:error, :invalid_fk_target_entity_type}` and returned directly from
`do_run_column_promotion/2`, short-circuiting before any DDL is attempted
— this is a `with`-chain addition, not a `raise`, since it is reachable
from realistic (if invalid) stored data, unlike `checked_table_name/1`'s
own-entity-type case which is guarded earlier by the same function on
every write path.

`execute_add_column/3` becomes `execute_add_column/4`, taking the resolved
`target_table :: String.t() | nil` as a fourth argument:

```
@spec execute_add_column(
        schema_name :: String.t(),
        table_name :: String.t(),
        promotion :: ColumnPromotion.t(),
        target_table :: String.t() | nil
      ) :: :ok | {:error, {:ddl_failed, Exception.t()}}
```

Identifier/type validation gains, when `target_table` is non-nil: a
`DDL.valid_identifier?/1` re-check on `target_table` (same defence-in-depth
posture as `table_name`/`column_name`/`pg_type` immediately above it in the
existing function), raising `ArgumentError` on failure, same as its
siblings. The emitted SQL becomes conditional:

```
# target_table == nil (no FK):
ALTER TABLE "<schema>"."<table>" ADD COLUMN "<col>" <pg_type>

# target_table != nil (FK-promoted column):
ALTER TABLE "<schema>"."<table>" ADD COLUMN "<col>" <pg_type>
  REFERENCES "<schema>"."<target_table>"("record_id") ON DELETE RESTRICT
```

Both branches still go through the exact same `Repo.query!/1` +
`rescue exception -> {:error, {:ddl_failed, exception}}` shape already
present — **no new per-tenant execution primitive**, only a longer SQL
string built inside the same function.

### 3.4 `create_and_populate_entity_table/3` resolves `fk_target_tables` before generating DDL

New private helper:

```
@spec resolve_fk_target_tables(Definition.t()) ::
        {:ok, %{String.t() => String.t()}} | {:error, {:invalid_entity_type, String.t()}}
```

Iterates `Map.get(document, :foreign_keys, [])`, calling
`table_name_for_entity_type/1` on each distinct `references_entity`,
building the map `DDL.generate_table_ddl/3` needs. `create_and_populate_entity_table/3`'s
`with` chain gains this step before calling `DDL.generate_table_ddl/3`, and
`qualify_create_table_sql/3` (renamed from `/3`'s current two-argument
shape only in the sense of also rewriting `REFERENCES` targets, not a
different name) is extended to additionally schema-qualify every
`REFERENCES "<target_table>"` occurrence the same way it already qualifies
the leading `CREATE TABLE "<table_name>"` — both are plain
`String.replace_prefix`/`String.replace` operations against known,
already-identifier-validated literal substrings, not a general SQL parser.

### 3.5 Additive-only interaction (explicit non-goal, not silently assumed)

`check_additive_only/3` is **unchanged** — it still only compares
`data_type`/`numeric_precision`/`numeric_scale` via
`pg_types_equivalent?/4`. This design does **not** add a check that an
already-`ddl_applied` column's `REFERENCES` constraint matches what a
retried promotion would now request. This is an explicit scope boundary:
the `REFERENCES` clause is applied atomically with the column's *first*
creation (either via `CREATE TABLE` or via this section's `ADD COLUMN`),
never retrofitted onto an already-existing column with no FK constraint by
a later idempotent-skip retry. If this ever needs to change (e.g. a
`fk_def` added to an already-promoted, already-plain column), that is a
**new, undesigned migration path** — flagged in §6's open questions, not
resolved here.

## 4. New mechanism: `ConstraintActivation` — retrofit-only unique-index activation

### 4.1 Why a new tracked row, not a bare function call

Mirrors `ColumnPromotion`'s own reasoning (0024 §2): a `constraint_def`'s
activation against N tenants is not atomic across tenants, and must be
individually retryable per tenant (a constraint's target columns might
exist in tenant A's table already but not yet in tenant B's, if column
promotions for the same `attribute` are still in flight for B). Reusing
`ColumnPromotion`'s own row shape does not fit — a `ColumnPromotion` row
identifies one `(tenant_id, entity_type, attribute)`; a constraint spans
**multiple** attributes and has its own `name`, not an `attribute`. A
parallel, equally-shaped tracked row is the correct fit, not an overload of
an existing one.

**This is not a new per-tenant-execution *mechanism*** (AC6/scope fence):
it is the same module (`Letflow.TenantProvisioning`), the same
`Repo.query!/1` + `rescue` DDL-issuing shape `execute_create_table/1` and
`execute_add_column/4` already use, the same per-tenant advisory-lock
pattern `run_column_promotion/1` and `provision_tenant_schema/1` already
use, and the same `pending -> ddl_applied | ddl_failed` status-row
bookkeeping pattern `ColumnPromotion` already uses — applied to a second
DDL statement *kind* (`ADD CONSTRAINT` vs. `ADD COLUMN`/`CREATE TABLE`),
exactly the way this module already carries two DDL-issuing functions
(`execute_create_table/1`, `execute_add_column/4`) side by side today.

### 4.2 New Ecto schema: `Letflow.TenantProvisioning.ConstraintActivation`

Same file conventions as `ColumnPromotion` (`lib/letflow/tenant_provisioning/constraint_activation.ex`,
sibling to `column_promotion.ex`, `@primary_key {:id, :binary_id,
autogenerate: true}`, no `belongs_to` on `tenant_id`). Field list:
`id :: binary_id`, `tenant_id :: Ecto.UUID.t()`, `entity_type :: String.t()`,
`constraint_name :: String.t()`, `fields :: [String.t()]` (stored as a
Postgres text array), `status :: String.t()` (one of `"pending" |
"ddl_applied" | "ddl_failed"`), `last_error :: String.t() | nil`,
`attempted_at | ddl_applied_at :: NaiveDateTime.t() | nil`,
`inserted_at`/`updated_at` timestamps. `@type t :: %__MODULE__{}`.

`@spec changeset(t(), map()) :: Ecto.Changeset.t()` — casts all fields
above except timestamps; `validate_required([:tenant_id, :entity_type,
:constraint_name, :fields, :status])`; `validate_inclusion(:status, [the
three values above])`; `unique_constraint(:tenant_id, name: <the
(tenant_id, entity_type, constraint_name) index name>)`;
`foreign_key_constraint(:tenant_id)` — same shape as
`ColumnPromotion.changeset/2`, applied to this schema's own field list.

**New migration** (global table, placement identical to
`entity_column_promotions`'s own migration — not tenant-scoped, not added
to `test/support/tenant_fixture.ex`'s `@expected_tenant_tables`): creates
`entity_constraint_activations` with the field list above (`fields` as
`{:array, :string}`, `null: false`; `tenant_id` as a
`references(:tenants, ...)` foreign key, matching
`entity_column_promotions`'s own `tenant_id` column shape exactly), plus a
unique index on `(tenant_id, entity_type, constraint_name)`.

### 4.3 New functions on `Letflow.TenantProvisioning`

```
@spec register_constraint_activation(
        entity_type :: String.t(),
        constraint_def :: Definition.constraint_def(),
        tenant_ids :: [Ecto.UUID.t()] | :all
      ) :: {:ok, [ConstraintActivation.t()]} | {:error, term()}
```

One `pending` row per tenant (`resolve_tenant_ids/1` reused verbatim — no
second tenant-enumeration mechanism). Issues no DDL. Mirrors
`register_column_promotion/4` exactly.

```
@spec run_constraint_activation(activation_id :: Ecto.UUID.t()) ::
        {:ok, ConstraintActivation.t()}
        | {:error,
           :activation_not_found
           | :tenant_not_provisioned
           | {:columns_not_ready, missing_fields :: [String.t()]}
           | {:ddl_failed, Exception.t()}}
```

Single-tenant, single-activation, taking only `activation_id` — same
calling convention as `run_column_promotion/1` (0024 §2's single-`id`
mutating-function rule, re-applied here rather than renegotiated). Steps,
inside the same `pg_advisory_xact_lock(hashtext(schema_name))`-guarded
transaction `run_column_promotion/1` already takes for that tenant (same
lock key — the tenant schema — so a concurrent column promotion and
constraint activation against the same table never interleave):

1. Load the row; resolve `schema_name` via `resolve_schema_name/1`
   (existing private helper, reused).
2. Resolve `table_name` via `table_name_for_entity_type/1`, applied to
   `activation.entity_type` (own type, not a target — no FK-style
   resolution needed here).
3. Query `information_schema.columns` for `activation.fields` against
   `(schema_name, table_name)` (same query shape `fetch_existing_column/3`
   already uses, generalized to a field list). Any field absent ->
   `{:error, {:columns_not_ready, missing_fields}}`, marks the row
   `ddl_failed` with that reason (retryable later — not a terminal
   failure — once the missing column(s)' own promotion(s) land).
4. Query `information_schema.table_constraints` for a constraint named
   `activation.constraint_name` on `(schema_name, table_name)`. If already
   present -> idempotent skip, mark `ddl_applied` (mirrors
   `check_additive_only/3`'s `:idempotent_skip` shape for column
   promotion).
5. Otherwise, build the constraint clause via `DDL.unique_constraint_clauses/1`
   applied to a **synthetic single-constraint `Definition.t()`** built from
   `activation.constraint_name`/`activation.fields` alone (not the live
   entity definition — this row is self-sufficient by design, carrying
   exactly the `constraint_def` shape it needs; no re-fetch of the current
   `entity_definitions` row is needed or performed), re-validating
   identifiers via the exact same function `generate_table_ddl/3`'s
   `CREATE TABLE` path already calls — one shared source of the clause
   text, per §2.4's stated reuse requirement. Issues:
   `ALTER TABLE "<schema>"."<table>" ADD <clause>` where `<clause>` is
   `unique_constraint_clauses/1`'s emitted
   `CONSTRAINT "<name>" UNIQUE ("f1", ...)` text, via `Repo.query!/1`,
   rescued into `{:ddl_failed, exception}` — the same shape as
   `execute_create_table/1`/`execute_add_column/4`.
6. Mark the row `ddl_applied`/`ddl_failed` via the same
   `mark_ddl_applied`/`mark_ddl_failed_and_return`-shaped private helpers
   (new small analogs scoped to `ConstraintActivation`, same body shape).

No `run_constraint_activation_for_all_tenants/1`,
`retry_failed_constraint_activation/1`, or backfill/activate/suspend
analogs are added — `constraint_def`'s unique index has no query-eligible
gate, no dual-write concern (a unique index is not a queryable *value*,
it is an integrity rule enforced by Postgres on every write regardless of
`Allowlist`/`Compiler` involvement, which REQ-299/300 own, out of this
requirement's scope fence), and no backfill step (a `CREATE UNIQUE INDEX`/
`ADD CONSTRAINT UNIQUE` against a table with pre-existing duplicate rows
fails outright at DDL time — Postgres itself surfaces that failure as a
`unique_violation` on the `ALTER TABLE`, correctly bubbling up as
`{:ddl_failed, exception}}`; no separate backfill-verification step is
meaningful for an integrity constraint the way it is for a data column).
A batch-of-tenants convenience wrapper is left as an explicit open
question (§6), not built here, matching REQ-297's own precedent of
building `run_column_promotion_for_all_tenants/1` only because REQ-295's
design named it explicitly — no equivalent naming exists for constraints.

## 5. The many-to-many worked example (0023's `question_tags`-shaped case)

A join entity type `question_tags` with:

- `fields`: `question_id :: string` (or the definition's actual FK-field
  type — `Definition.field_type()` has no dedicated "reference" type; an
  `fk_def.field` is an ordinary `:string`-typed field per 0023, holding a
  `record_id`-shaped UUID string), `tag_id :: string`, and any number of
  ordinary attributes the relationship itself carries (`sort_order ::
  integer`, entirely optional, living in `field_values` unless separately
  `queried: true`).
- `foreign_keys`: two `fk_def()` entries —
  `%{name: "fk_question", field: "question_id", references_entity: "questions"}`,
  `%{name: "fk_tag", field: "tag_id", references_entity: "tags"}`.
- `constraints`: one `constraint_def()` —
  `%{name: "uq_question_tag_pair", type: :unique, fields: ["question_id", "tag_id"]}`.

**Both `question_id` and `tag_id` promote via trigger 1** (`fk` — REQ-296's
existing `promotion_trigger/2`, unchanged by this design) since both names
appear in `fk_field_names`. No special-cased "join table" branch exists
anywhere in `DDL` or `TenantProvisioning` — the generator and executor see
`question_tags` as an entity type like any other, with two of its promoted
columns happening to carry `references_entity` and one `constraint_def`
happening to span both of them. This is the concrete demonstration that
0023's "Many-to-many is not a special case" claim, and the anti-pattern
entry's "Correct alternative," hold under this design.

**Test-shape for this worked example (§7 below expands per-AC):**

1. Build (or fixture-load) `questions` and `tags` entity types, each with a
   provisioned per-entity-type table and at least one real row (a real
   `record_id` each) to reference.
2. Build `question_tags` per the shape above; drive it through both
   activation paths so both are exercised:
   - **Fresh-table path**: a brand-new `question_tags` entity type,
     `create_and_populate_entity_table/3` builds one `CREATE TABLE`
     carrying both `REFERENCES` clauses and the inline `UNIQUE
     ("question_id", "tag_id")` constraint in one statement.
   - **Retrofit path**: `question_tags`'s table already exists with only
     `question_id` promoted (no constraint yet); promote `tag_id` via
     `register_column_promotion/4` + `run_column_promotion/1` (its FK
     `REFERENCES` clause rides that `ADD COLUMN` per §3.3); then
     `register_constraint_activation/3` + `run_constraint_activation/1` adds
     `uq_question_tag_pair` via `ADD CONSTRAINT`.
3. Assertions, against a real Postgres connection (never schema-catalog
   inspection alone) for both paths:
   - Inserting a `(question_id, tag_id)` pair a second time raises a
     `Postgrex.Error` with `postgres.code == :unique_violation`.
   - Inserting a row with a `question_id` that matches no real `questions`
     row's `record_id` raises `Postgrex.Error` with `postgres.code ==
     :foreign_key_violation` (and symmetrically for `tag_id`).
   - Inserting a row with a *distinct* valid pair, plus a `field_values`
     blob carrying `%{"sort_order" => 3}`, succeeds — confirming the
     relationship's own attributes have a real home and are not
     constrained or interpreted by the FK/unique machinery at all.

## 6. Open questions (explicit, not silently resolved)

- **No migration path from a plain promoted column to a later-added
  `fk_def`, or from an unconstrained table to a later-added
  `constraint_def` whose fields already contain duplicate values.** Both
  cases surface as an ordinary `{:ddl_failed, exception}` (a
  `unique_violation` or a Postgres error adding a `REFERENCES` clause to a
  column with non-conforming existing data) with no repair path beyond
  `retry_failed_column_promotion/1`/a hypothetical constraint-activation
  retry after manual data cleanup — left as-is, matching REQ-297's own
  "repair is a retry of exactly this one row" scope, not expanded here.
- **No `run_constraint_activation_for_all_tenants/1`, retry, or suspend
  analog is built.** If REQ-299/300 or a future requirement needs one,
  it is a small, additive follow-on mirroring `ColumnPromotion`'s own
  batch/retry functions — not built speculatively here since nothing in
  REQ-298's acceptance criteria names it.
- **Call-site integration (who invokes `register_column_promotion/4`
  with `references_entity` set, and who invokes
  `register_constraint_activation/3`) is out of this design's scope**,
  exactly as REQ-297 left `register_column_promotion/4`'s own caller
  unbuilt — no production call site exists for either registration
  function today (confirmed by grep: `register_column_promotion` has no
  caller outside its own test file). A future definition-promotion
  orchestration requirement wires this up; this design only builds the
  primitives it will call.
- **`references_field` (`fk_def`'s optional field, defaulting to
  `record_id` implicitly) is not consumed anywhere in this design.** Every
  `REFERENCES` clause this design emits targets `("record_id")`
  unconditionally, matching REQ-298's own acceptance criteria text
  ("pointing at the target entity type's table's `record_id`"). If a
  future need arises for an FK to reference a different column,
  `fk_def.references_field` already exists in the type to carry it, but
  this design does not read or honor it — left exactly as unresolved as
  it already is in the current `Definition` module, not newly introduced
  as a gap by this requirement.

## 7. Test-coverage plan (mapped to every AC)

1. **AC1 (unique index rejects a real duplicate, not a catalog check).**
   Build an entity type with a `constraint_def` over 2 fields via both the
   fresh-`CREATE TABLE` path and the `ConstraintActivation` retrofit path;
   insert a conforming row, then attempt an exact-duplicate insert on both
   paths; assert `Postgrex.Error` with `postgres.code == :unique_violation`
   in both cases. A second test with a single-field `constraint_def`
   confirms `N = 1` works identically (no min-field-count edge case).
2. **AC2 (FK rejects a nonexistent target, not a catalog check).** Build an
   entity type with one `fk_def`, on both paths (fresh table; retrofit via
   `run_column_promotion/1`); attempt an insert whose FK column value is a
   syntactically valid but non-existent `record_id`; assert `Postgrex.Error`
   with `postgres.code == :foreign_key_violation` on both paths.
3. **AC3 (`ON DELETE` behavior, citing 0025 by section).** With a real
   referencing row present, issue a raw hard `DELETE` (via `Repo.query!/1`,
   simulating the "out-of-band" scenario 0025's reasoning names — never
   through `Records.delete_record/2`, which this test explicitly does not
   exercise, per 0025's own scope boundary) against the referenced row's
   table; assert `Postgrex.Error` with `postgres.code ==
   :foreign_key_violation` (RESTRICT's defined behavior) and that the
   referenced row is still present afterward (transaction rolled back /
   statement failed, no partial effect). A second assertion greps
   `DDL`'s moduledoc source for the literal string `"ON DELETE RESTRICT"`
   and for `"0025-promoted-fk-ondelete-and-localized-text-search-strategy.md"`,
   confirming the citation requirement (AC3's second half) is met in the
   shipped moduledoc text, not only in this design doc.
4. **Many-to-many worked example** — exactly the three assertions in §5
   step 3 above (duplicate-pair rejection, nonexistent-target rejection on
   either FK, extra-attribute acceptance via `field_values`), run against
   both the fresh-table and retrofit activation paths.
5. **Array-of-references anti-pattern absence.** A structural test
   asserting `Definition.field_type()`'s documented value set contains no
   `:array` (or `{:array, _}`-shaped) member — since the type is a fixed,
   closed `@type` in source, this is checked by asserting each of the 8
   named atoms is a valid `field_type()` value via a `case`/pattern-match
   exhaustiveness compile check, or equivalently, a `grep -rn "{:array,"
   lib/letflow/entities/definition.ex lib/letflow/entities/definition/ddl.ex
   lib/letflow/tenant_provisioning.ex` run from the test (via
   `System.cmd/3`) asserting zero matching lines — confirming no relation
   in this design's own new code is ever represented as an array column.
6. **AC6 (no new per-tenant-DDL-execution code path).** Not a runtime
   assertion but a documentation/review-time confirmation, stated here for
   REVIEWER: the only functions that ever call `Repo.query!/1` against a
   tenant schema for DDL purposes, before and after this design, are
   `provision_tenant_schema/1`'s `CREATE SCHEMA` call, `execute_create_table/1`,
   `execute_add_column/4` (extended from REQ-297's `execute_add_column/3`
   — same function, one new parameter and a longer SQL string), and this
   design's new `run_constraint_activation/1`'s own `ADD CONSTRAINT` call
   (a new DDL *statement kind*, issued through the identical
   `Repo.query!/1` + `rescue` shape, inside the identical
   `pg_advisory_xact_lock` critical section `run_column_promotion/1`
   already establishes for that tenant) — no new module, no new lock
   mechanism, no new transaction-boundary shape.
