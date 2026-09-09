# REQ-296 design — per-entity-type table DDL generator

Companion to `docs/migration/decisions/0023-entity-storage-hybrid.md` (the
storage shape) and `docs/migration/decisions/0024-entity-promotion-ddl-execution.md`
plus its companion `lib/letflow/design/req295-entity-promotion-ddl-execution.md`
(the execution mechanism). This doc gives ELIXIR-DEV a concrete interface
for the **pure DDL-generation function** only. No implementation code —
signatures and shapes only.

## 0. Re-verification findings (per this task's mandatory step 1)

- 0024/req295 answer "what runs DDL, how" for **single-column promotions
  applied later to an already-existing table**
  (`Letflow.TenantProvisioning.run_column_promotion/1`). That function
  executes "one `ALTER TABLE ... ADD COLUMN` statement" built from a
  `column_spec :: map()` — req295 §4 explicitly leaves "the exact DDL
  statement builder (mapping a `Definition.field_type()` to a Postgres
  column type for `column_spec`)" **unfixed, deferred to REQ-296**. It also
  states the executor "executes ... directly, the same way
  `provision_tenant_schema/1` already executes `CREATE SCHEMA IF NOT
  EXISTS ...` directly rather than through the migrator" — i.e. **raw SQL
  text**, not an `Ecto.Migration` DSL/AST. Nothing in 0024/req295
  constructs or expects an `Ecto.Migration` macro call list.
- req295 does **not** name a function that generates a whole **new
  table's** DDL (only per-column `ALTER TABLE`). REQ-296's "per-entity-type
  table DDL" is therefore the CREATE-TABLE-time generator: given a full
  `Definition.t()`, produce the DDL for that entity type's table as it
  should look the moment the type is (re)provisioned, with every
  currently-promoted attribute already present as a real column. This is
  consistent with 0023's "the DDL is a pure function of Definition.t()"
  framing (a full recomputation each time, not an incremental diff) and
  with REQ-296's own SCOPE FENCE (no migration file, no execution).
  **Conclusion: this generator returns raw SQL text (a `String.t()`
  `CREATE TABLE` statement), matching the form REQ-295/297's `ALTER TABLE`
  half already commits to** — one representation used consistently across
  both halves of table DDL, not two.
- `Letflow.Entities.Definition.Validator.fk_field_coverage_violations/1`
  (`lib/letflow/entities/definition/validator.ex:351-366`) and
  `queried_json_violations/1` (`validator.ex:298-309`) both confirmed
  present and behaving as described: `fk_field_coverage_violations/1`
  flags any `fk_def.field` not present in `fields`; `queried_json_violations/1`
  flags any field with `type: :json and queried: true`. Both still exist,
  unchanged from the requirement's description.
- `Letflow.Entities.Definition.t()`/`field_def()`/`field_type()`/`fk_def()`
  read in full (`lib/letflow/entities/definition.ex`, 73 lines, unchanged
  from the 8-type closed set the requirement names — no ninth type added).
- `entity_record_latest`'s exact structural column set, from
  `lib/letflow/entities/record/latest.ex` and
  `priv/repo/migrations/20260906010001_create_entity_record_latest.exs`:
  `id :binary_id` (PK), `entity_type :string`, `record_id :binary_id`,
  `field_values :map/jsonb`, `deleted :boolean default false`,
  `entity_def_version :binary`, `last_event_global_seq :bigint`,
  `inserted_at`/`updated_at` (`timestamps(type: :utc_datetime_usec)`).
  Unchanged since the requirement was drafted. See §2 below for how this
  maps onto the new per-entity-type table (the shared `entity_type` column
  is dropped — a per-type table's rows are all one type by construction).
- No pre-existing REQ-296 design artefact found under `lib/letflow/design/`
  (checked, only req291/req295 exist there under a `req29*` glob).

## 1. Module: `Letflow.Entities.Definition.DDL`

**Location:** `lib/letflow/entities/definition/ddl.ex`. Sibling to
`Letflow.Entities.Definition.Shape` (`shape.ex`) and
`Letflow.Entities.Definition.Validator` (`validator.ex`) under
`lib/letflow/entities/definition/` — the existing three-stage pipeline for
a definition document (canonicalise/hash → structurally validate → derive
DDL) gains its third stage in the same directory, same naming convention.
This directory is not `lib/letflow/tenant_provisioning/` and not
`lib/letflow/entities/records.ex`/`record/*` — satisfies the scope fence's
git-diff check.

**Moduledoc responsibilities (content, not literal text):**

- States this module is a pure function of `Definition.t()` — no
  `Repo` call, no tenant/schema awareness, no side effects, matching
  0023's "the DDL is a pure function of Definition.t()" framing.
- States the precondition: the caller must have already run
  `Letflow.Entities.Definition.Validator.validate/1` and gotten `:ok`
  before calling this module — this module does not re-run structural
  validation (fk coverage, `:json`/`queried` conflict, name format), it
  leans on those already-enforced invariants per the requirement's own
  instruction. It performs one defence-in-depth identifier check anyway
  (§4) rather than trusting that precondition for the one property that
  would be a SQL-injection-shaped defect if it silently stopped holding.
- States the extension point for REQ-301 explicitly (§5 below) — this is
  an acceptance criterion, not decoration.
- States the output form: raw SQL text (`String.t()`), one full
  `CREATE TABLE` statement, and why (this doc's §0 finding, tied to
  REQ-295/297's own `ALTER TABLE`-as-raw-SQL precedent).

## 2. Main function

```
@spec generate_table_ddl(Definition.t(), table_name :: String.t()) ::
        {:ok, String.t()} | {:error, ddl_error()}
```

- `table_name` is supplied by the caller (REQ-297/provisioning's job to
  decide the physical table name from `entity_type`, e.g. prefixing or
  sanitizing) — this module does not invent a table-naming convention; it
  validates whatever name it is given (§4) and uses it verbatim in the
  emitted `CREATE TABLE "<table_name>" (...)`. Keeping naming policy out of
  this module is deliberate: REQ-297 already owns per-tenant schema/identifier
  concerns end to end (0024 §1), and this generator should not duplicate or
  pre-empt that.
- Returns `{:ok, sql}` on success. Returns `{:error, ddl_error()}` only for
  the defence-in-depth identifier-shape failures in §4 (never for a
  structurally-invalid `Definition.t()` — that is the Validator's job,
  assumed already passed per the precondition above).

```
@type ddl_error ::
        {:invalid_identifier, field: :table_name | :attribute, value: String.t()}
```

### Column-generation helpers (bare signatures — internal, but part of the contract CODE-DESIGN-VALIDATOR checks for "no TBD")

```
@spec structural_columns() :: [column_spec()]
```
Returns the fixed, definition-independent list of structural columns every
per-entity-type table carries (§3) — a constant-shaped function (no
`Definition.t()` input) so REQ-297/provisioning can also introspect the
structural set independently of generating full DDL (e.g. to confirm a
promoted attribute name never collides with a structural column name).

```
@spec promoted_columns(Definition.t()) :: [column_spec()]
```
Applies the promotion rule (§4 of the requirement, restated in §3 below)
to `definition.fields`, using `definition.foreign_keys` to determine
trigger 1. Returns one `column_spec()` per promoted attribute, in
`definition.fields`'s original order (stable, deterministic output —
required for the exact-output-shape test in the AC's first bullet).

```
@type column_spec :: %{
        name: String.t(),
        pg_type: String.t(),
        nullable: boolean()
      }
```
`nullable` is always `true` for a promoted column — 0023's additive-only
rule requires every promoted column to be backfillable after the fact via
0024's dual-write/replay mechanism, which is only possible if the column
accepts `NULL` until backfilled. This module hard-codes `nullable: true`
for every promoted column; it takes no `required: true` field-level
override, even if `field_def()` declares `required: true` — a structural
"must have a value eventually" constraint on the *attribute* is not the
same as a Postgres `NOT NULL` on the *column* the moment it's created,
and 0024's backfill window depends on the column tolerating `NULL` during
the dual-write phase. (Open question — see §6.)

```
@spec field_type_to_pg_type(Definition.field_type()) :: {:ok, String.t()} | :never_promoted
```
The type-mapping table as a function, exposed publicly so REQ-297's own
`column_spec` construction for a single later promotion (its own,
separate `ALTER TABLE ADD COLUMN`, per req295 §2's `register_column_promotion/4`)
reuses the same mapping rather than re-deriving it — one type-mapping
table, one place. Returns `:never_promoted` for `:json` (§4's defence in
depth); never raises on any of the other 7 `field_type()` values.

## 3. Structural columns (from `entity_record_latest`, minus the now-per-type `entity_type` column)

| Column | Postgres type | Notes |
|---|---|---|
| `id` | `uuid` (`binary_id`), PRIMARY KEY | matches `entity_record_latest`'s `@primary_key {:id, :binary_id, autogenerate: true}` |
| `record_id` | `uuid`, `NOT NULL` | matches `entity_record_latest.record_id :binary_id, null: false` |
| `field_values` | `jsonb`, `NOT NULL DEFAULT '{}'::jsonb` | the blob for every non-promoted attribute (§3 mapping unchanged from `entity_record_latest`'s `field_values :map, null: false, default: %{}`) |
| `deleted` | `boolean`, `NOT NULL DEFAULT false` | matches `entity_record_latest.deleted` |
| `entity_def_version` | `bytea` (Ecto `:binary`) | matches `entity_record_latest.entity_def_version :binary`, nullable (no `null: false` on that column today — carried forward unchanged) |
| `last_event_global_seq` | `bigint`, `NOT NULL` | matches `entity_record_latest.last_event_global_seq :bigint, null: false` |
| `inserted_at` | `timestamp(6) without time zone`, `NOT NULL` | matches `timestamps(type: :utc_datetime_usec)` |
| `updated_at` | `timestamp(6) without time zone`, `NOT NULL` | matches `timestamps(type: :utc_datetime_usec)` |

**`entity_type` is dropped from the structural set.** `entity_record_latest`
carries it because that table is shared across every entity type in a
tenant's schema; a per-entity-type table is, by construction, all one
type, so the column would be a redundant constant on every row. This is a
deliberate structural difference from `entity_record_latest`, not an
oversight — flagged explicitly since the requirement's instruction to
"carry the same structural columns" is read here as "the same *columns
that still make sense once splitting by type*," not byte-for-byte
including a column whose entire reason to exist (disambiguating rows of
different types in one shared table) no longer applies.

A `UNIQUE` index on `record_id` is emitted in the same `CREATE TABLE`
statement (one row per record per type, mirroring `entity_record_latest`'s
own `unique_index([:entity_type, :record_id])` minus the now-redundant
`entity_type` half).

## 4. Type mapping (`field_type_to_pg_type/1`)

| `Definition.field_type()` | Postgres column type | Notes |
|---|---|---|
| `:string` | `text` | no length cap at the DDL layer — length constraints, if any, are `Record.Validator`'s concern, not physical column width |
| `:integer` | `bigint` | matches `last_event_global_seq`'s own precedent of using `bigint` over `integer` for headroom |
| `:decimal` | `numeric(p, s)` — `p`/`s` from `field_def().decimal_precision`/`decimal_scale` when present, else `numeric` (unconstrained) | `promoted_columns/1` reads these two optional keys off the field when the type is `:decimal`; absent keys fall back to bare `numeric` |
| `:boolean` | `boolean` | |
| `:date` | `date` | |
| `:datetime` | `timestamp(6) without time zone` | matches this project's existing convention of naive/UTC timestamps without a tz-aware column type (same choice `entity_record_latest.inserted_at`/`updated_at` already make) |
| `:enum` | `text` with a `CHECK (<column> IN (<enum_values>))` constraint appended to the `CREATE TABLE` statement | no Postgres native `ENUM` type is created — matches this project's general avoidance of DDL-level enum types elsewhere (a `CHECK` constraint is additive-only-compatible: widening the allowed value set later is a constraint replacement, not a column-type change, keeping 0023's additive-only column rule intact even though it doesn't literally apply to a `CHECK` clause) |
| `:json` | **never promoted** — `field_type_to_pg_type/1` returns `:never_promoted` | Validator's Rule 3 (`queried_json_violations/1`) already forbids `type: :json, queried: true`; this module adds its own independent check (§5) so a `:json` field is never promoted even via trigger 1 (FK) — see open question in §6, since 0023/req295 discuss trigger 1 only for non-`:json` fields and never explicitly say "unless the FK field happens to be declared `:json`," but a `:json`-typed FK is nonsensical in Postgres (no equality/index semantics fit for FK-referencing) so this module treats it as `:never_promoted` regardless of which trigger fired |

## 5. Promotion determination (the shape `promoted_columns/1` implements)

```
@spec promotion_trigger(Definition.field_def(), fk_field_names :: MapSet.t(String.t())) ::
        :fk | :queried | :not_promoted
```

Bare decision function (no DDL concerns) so the promotion *rule* is
independently testable from the DDL *text* it produces (per the AC's third
and fourth bullets, which test promotion behavior, not DDL syntax):

- `:fk` — `field_def().name` is a member of `fk_field_names` (the set of
  every `fk_def().field` value from `definition.foreign_keys`), regardless
  of `field_def().queried`.
- `:queried` — not `:fk`, and `field_def().queried == true`.
- `:not_promoted` — neither trigger fires.

`promoted_columns/1` computes `fk_field_names` once
(`MapSet.new(definition.foreign_keys, & &1.field)`), calls
`promotion_trigger/2` per field, keeps fields whose trigger is `:fk` or
`:queried`, and — for each kept field — resolves its `pg_type` via
`field_type_to_pg_type/1`. **A `:json`-typed field that is somehow marked
`queried: true` (Validator bypassed or a future relaxation of Rule 3) is
excluded regardless of `promotion_trigger/2`'s answer** — `promoted_columns/1`
filters on `field_type_to_pg_type/1` returning `{:ok, _}`, not merely on
`promotion_trigger/2`'s result, which is exactly the defence-in-depth the
AC's second bullet requires ("a `:json` field is NEVER promoted to a
column even if a definition somehow marks it `queried: true`").

## 6. `field_values` jsonb column

Emitted unconditionally as one of the structural columns (§3) — every
non-promoted attribute's value lives under its own key inside this blob at
write time (REQ-297/298's write-path concern, not this generator's). This
generator does not enumerate or validate which attribute names end up as
`field_values` keys; it only guarantees that promoted attributes get a
real column and everything else has somewhere to live by virtue of
`field_values` always being present.

## 7. Identifier-safety check (defence in depth, INV-7-adjacent)

Every identifier interpolated into the generated SQL text — `table_name`
and every promoted `column_spec().name` — is checked against the same
format `Letflow.Entities.Definition.Validator` already enforces on names
(`@name_format_regex ~r/^[a-z][a-z0-9_]{0,63}$/`,
`validator.ex:47`) before being interpolated. This module does **not**
import or call the Validator's private regex; it defines its own
equivalent public check:

```
@spec valid_identifier?(String.t()) :: boolean()
```

matching the same pattern, so this module's safety property does not
depend on the Validator's private implementation detail staying
accessible or unchanged — it is a second, independent statement of "what a
safe identifier looks like" checked at the point of use (generation time),
in the same spirit 0024's SECURITY-REVIEWER sign-off praised for
`schema_name` (validated at both write time and DDL-execution time). A
`table_name` or promoted column name failing this check short-circuits
`generate_table_ddl/2` with `{:error, {:invalid_identifier, ...}}` rather
than emitting DDL text with an unchecked identifier in it. This does not
duplicate INV-7 verbatim (INV-7 is about parameterised query values, and a
`CREATE TABLE`'s column/table names cannot be bind-parameters in Postgres
DDL at all) — it is the closest analogous control available for an
identifier that must be textually interpolated.

## 8. Extension point for REQ-301 (generated-column-per-locale)

Stated in the moduledoc (§1) and restated here for the design record:
`promoted_columns/1`'s per-field dispatch (via `field_type_to_pg_type/1`
and `promotion_trigger/2`) is structured as a **closed case dispatch over
`field_type()`**, not a single monolithic `cond`/string-building block.
REQ-301, when it adds a localized-text type (or a `localized: true` flag
on `:string`, whichever REQ-301 itself decides), extends this dispatch
with one more case that emits **N generated columns per configured
locale** instead of the current one-column-per-attribute shape — without
needing to touch `structural_columns/0`, the structural/promoted/blob
split in `generate_table_ddl/2`, or any of the other 7 type-mapping rows.
This requirement does **not** implement that case, add a locale
configuration shape, or reserve a specific field name/flag for it — only
the dispatch shape that makes adding it additive.

## 9. Test-coverage plan (mapped to every AC)

| AC | Test |
|---|---|
| Exact output shape (FK-promoted + queried-promoted) | Fixture `Definition.t()` with one field that is an `fk_def().field` (`queried: false` or absent) and one separate field `queried: true` (not an FK). Assert `generate_table_ddl/2`'s `{:ok, sql}` contains a `CREATE TABLE` with exactly the 8 structural columns (§3) plus both promoted columns, in the exact order `promoted_columns/1` produces, and nothing else. |
| Type-mapping, one test per type | 6 tests (`:string`, `:integer`, `:decimal` — with and without precision/scale as two sub-cases, `:boolean`, `:date`, `:datetime`, `:enum` with a `CHECK` clause) each asserting `field_type_to_pg_type/1`'s returned Postgres type string and that a field of that type, marked `queried: true`, appears in `generate_table_ddl/2`'s output with that exact column type. |
| `:json` never promoted | Test: a `:json` field with `queried: true` forced into the fixture (bypassing Validator, simulating a future relaxation) is asserted absent from `promoted_columns/1`'s result and absent as a column in `generate_table_ddl/2`'s output; `field_type_to_pg_type(:json)` asserted `:never_promoted`. |
| Not promoted unless triggered | Fixture field with `queried: false` (or key absent) and not present in any `fk_def`. Assert `promotion_trigger/2` returns `:not_promoted` and the field is absent from `promoted_columns/1`'s result and from the generated `CREATE TABLE`'s column list (it is only reachable via `field_values`, not asserted further since `field_values`'s runtime contents are a write-path concern). |
| FK-promoted regardless of `queried` | Fixture field that is an `fk_def().field` with `queried: false` explicit. Assert `promotion_trigger/2` returns `:fk` and the field is present in `promoted_columns/1`'s result. |
| Real ephemeral-Postgres DDL execution | `Repo.query!/2` (or a raw `Postgrex` connection, whichever this project's existing test helpers use for ephemeral-schema tests) creates a throwaway schema, runs `generate_table_ddl/2`'s output SQL against it, queries `information_schema.columns` for the created table, and asserts the returned column name/type set matches the definition's structural + promoted columns exactly (order-independent for this one assertion, since `information_schema` ordering is not the same property as the SQL-text-order assertion above), then drops the throwaway schema in the test's `on_exit`. |
| Moduledoc extension-point statement | A test is not the right tool for a prose requirement — covered by CODE-DESIGN-VALIDATOR/REVIEWER reading §1/§8 of this doc and the shipped moduledoc directly, per this project's own convention for moduledoc-content ACs (matching how REQ-295's own AC 7/8 were verified by reading, not by test). |
| `git diff` scope fence | Not a unit test — verified at PR time by `git diff --name-only` against the excluded paths listed in the requirement's own AC, same mechanism REQ-295 used. |
| `mix letflow.check` | Run at PR time with real output quoted, same mechanism every other requirement uses. |

## 10. Open questions (explicit, not silently resolved)

- **`required: true` vs. column `NOT NULL`:** this design hard-codes every
  promoted column as nullable (§2) to keep 0024's backfill window valid.
  Whether a *structurally required* attribute's column should later gain a
  `NOT NULL` constraint once every tenant has finished backfilling (a
  second DDL step, symmetric to promotion) is not decided here — it is not
  named in 0023/0024/req295 either, and REQ-296's scope fence forbids
  inventing new promotion-lifecycle states. Left for whichever later
  requirement (if any) revisits column-level tightening.
- **`:enum` representation:** this design chooses `text` + `CHECK` over a
  native Postgres `ENUM` type (§4) because it composes cleanly with
  0023's additive-only rule for widening the value set later. This is a
  design choice made here, not one 0023/0024 dictates explicitly — flagged
  so ELIXIR-DEV/REVIEWER can confirm it rather than discovering it
  unstated mid-build.
- **`:json`-typed FK fields:** §4 treats a hypothetical `:json`-typed
  `fk_def().field` as `:never_promoted` even though trigger 1 (FK) is
  independent of `:json`/`queried` per the promotion rule's literal text.
  0023/0024/req295 never discuss this combination (a `:json` field
  functioning as a foreign key is not sensible in Postgres). Stated
  explicitly as this module's own defence-in-depth extension of the rule,
  not a silent reinterpretation of it.
- **Table-naming policy** (how `entity_type` becomes a physical
  `table_name`, collision handling across tenants/entity types) is
  explicitly left to REQ-297/the provisioning path, per §2 — this module
  accepts `table_name` as a caller-supplied, pre-decided string.
