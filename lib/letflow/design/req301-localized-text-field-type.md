# REQ-301 design — `:localized_text` field type, blob-stored, generated-column-per-locale when `queried: true`

Companion to `docs/migration/decisions/0023-entity-storage-hybrid.md` ("Localized
entity content is blob, and is not an i18n gap"),
`docs/migration/decisions/0025-promoted-fk-ondelete-and-localized-text-search-strategy.md`
(sub-question 2 — plain-vs-`tsvector`, decided, cited not re-derived here),
`lib/letflow/design/req296-entity-table-ddl-generator.md` (the promotion
dispatch this design extends at its own named extension point),
`lib/letflow/design/req297-entity-promotion-executor.md` (the executor this
design wires), and `lib/letflow/design/req299-allowlist-per-entity-type.md`
(the per-entity-type accessor this design extends, including its REWORK
ITERATION 1 finding this design must not silently reopen).

Signatures and shapes only — no implementation code.

## 0. Re-verification findings (per this task's mandatory step 1)

- **REQ-285/react-intl boundary confirmed clean.** `grep -rln "localized_text\|react-intl" web/ docs/frontend/` (run before writing this doc) found no hit under `web/` or `docs/frontend/`. Nothing in this design touches `web/`, react-intl, or UI-string localization. Entity-content localization (this requirement) and UI localization (REQ-285) remain the two separate things 0023 names.
- **REQ-302's decision record is `docs/migration/decisions/0025-promoted-fk-ondelete-and-localized-text-search-strategy.md`**, `status: decided`, both `SECURITY-REVIEWER` and `REVIEWER` sign-offs `PASS`. Sub-question 2's decision (quoted, not re-derived): a per-field, definition-level `search_strategy` attribute, values `:plain` (default) or `:fulltext`, selecting one plain-text or one `tsvector` generated column per supported locale. This design implements that mechanism verbatim.
- **`Letflow.Entities.Definition.t()`, `Validator`, `DDL`, `TenantProvisioning`/`ColumnPromotion`, and `Allowlist` re-read in full** (contents summarized inline below, at each section that touches them). All are `status: done` (REQ-225/296/297/299) as of this design.
- **THE LANDMINE, re-confirmed by direct source read, not by trusting the task brief:** `lib/letflow/entities/query/compiler.ex:165` and `:333`, and `lib/letflow/entities/query/cursor.ex:210` and `:386`, all resolve a `:typed_column` field's column atom via `Map.fetch!(Allowlist.typed_columns(), field_name)` — the **zero-arg**, fixed-7-entry table. `Allowlist.load/2` (REQ-299, REWORK ITERATION 1) deliberately never marks a promoted-but-non-structural field `:typed_column` for exactly this reason — see `req299-allowlist-per-entity-type.md`'s "REWORK ITERATION 1" section, confirmed present and unmodified since. `Allowlist.typed_columns/2` (the per-entity-type accessor) exists and is correct, but is **additive and currently uncalled by `load/2`** — wiring it into `load/2`'s output, and giving `compiler.ex`/`cursor.ex` a real per-entity-type atom-resolution path, is REQ-300's stated job (`depends_on: [REQ-298, REQ-299]`, still `status: pending`). **REQ-301 does not depend_on REQ-300.** This is the identical structural gap REQ-299 hit, not a new one this design introduces on the `:typed_column` side.
- **A second, previously-undiscussed instance of the same class of gap, found by tracing REQ-301's own carve-out through `load/2` and `Compiler` — see §4.6.** Because `:localized_text` (unlike `:json`) is explicitly allowed `queried: true` (AC3, this requirement's whole point), a `:localized_text` field marked `queried: true` would, under `Allowlist.load/2`'s **unmodified** `json_field_entries` step, be allowlisted by its own bare name with `source: :json_field, type: :localized_text`. `Letflow.Entities.Query.Compiler.json_cast_dynamic/2` (`compiler.ex:230-245`) has one pattern-matched clause per `field_type()` that needs JSONB casting (`:string`, `:enum`, `:integer`, `:decimal`, `:boolean`, `:date`, `:datetime`) and **no clause for `:localized_text`** (nor `:json`, which never reaches this function because Validator's Rule 3 already forbids it `queried: true`). Feeding such a resolved field into `Compiler.build_filter_dynamic/2`'s `:json_field` clause raises `FunctionClauseError` — a second crash, on a different code path than the already-known `:typed_column`/`KeyError` one, and one this requirement's own carve-out (AC3) newly makes reachable, where before REQ-301 no field type could ever be both non-`:json` and structurally excluded from JSONB casting. **This design closes this gap directly (§4.6) — it is not optional, because AC5's own literal test would otherwise crash the suite the same way REQ-299's AC4 did, and AC9 (`mix letflow.check` passes) would fail on first contact.**

## 1. `Letflow.Entities.Definition` — `field_type()` and `field_def()` extension

```elixir
@type field_type ::
        :string | :integer | :decimal | :boolean | :date | :datetime | :enum | :json
        | :localized_text
```

`:localized_text` is a new, ninth, closed-set value — not a flag on `:string`,
per the task's own naming instruction ("do not reuse `:json`... a
localized-text field must be promotable"; the same reasoning applies to not
overloading `:string`, which stays a plain scalar type with no locale
concept).

`field_def()` gains two new optional keys, both meaningful only for
`type: :localized_text` (enforced by Validator, §2):

```elixir
@type field_def :: %{
        required(:name) => String.t(),
        required(:type) => field_type(),
        optional(:required) => boolean(),
        optional(:queried) => boolean(),
        optional(:enum_values) => [String.t()],
        optional(:decimal_precision) => pos_integer(),
        optional(:decimal_scale) => non_neg_integer(),
        optional(:default) => term(),
        optional(:locales) => [String.t(), ...],
        optional(:search_strategy) => :plain | :fulltext
      }
```

- **`:locales`** — the per-definition, per-field supported-locale set (task
  item 2). Required (non-empty) when `type == :localized_text`; forbidden
  otherwise — same presence/absence shape already established for
  `enum_values`/`decimal_precision`/`decimal_scale` (Validator Rules 6/7).
  Each entry a lowercase language-subtag string matching `^[a-z]{2,8}$`
  (§2 — deliberately simple: no region subtags, no hyphens, so a locale
  code concatenates directly into a safe SQL identifier as `<field>_<locale>`
  with no separate sanitization step).
- **`:search_strategy`** — cites `0025` sub-question 2 verbatim: `:plain`
  (default when absent) or `:fulltext`. Forbidden when `type !=
  :localized_text` (symmetric absence rule, same shape as above).

This is a **per-definition, per-field** declaration (task item 2's own
wording) — two different entity types (or two different fields on the same
entity type) may declare different `:locales` sets independently; nothing
here is a project-wide constant.

## 2. `Letflow.Entities.Definition.Validator` — new rules, Rule 3 explicitly NOT touched

`@field_types` grows from 8 to 9 entries (adds `:localized_text`). The
moduledoc's "malformed-shape precondition" language ("each field's type is
one of the 8 known atoms") must be updated to 9 — a doc-text change only,
`field_shape_violations/1`'s logic (`type not in @field_types`) needs no
code change since it already checks membership generically.

### Rule 3 (`:queried_json_conflict`) — UNCHANGED, and why that is correct, not an oversight

`queried_json_violations/1`'s guard is `Map.get(field, :type) == :json and
Map.get(field, :queried)`. A `:localized_text` field's `:type` is never
`:json`, so this rule structurally never fires for it — **the carve-out
task item 3 asks for is achieved by `:localized_text` being a distinct
closed-set atom, not by editing Rule 3's condition at all.** This is the
strongest possible guarantee that the carve-out "must NOT weaken Rule 3 for
actual `:json` fields" (task item 3): Rule 3's source text is byte-for-byte
unchanged, so its existing coverage (a `:json` field with `queried: true`
still violates) cannot regress by construction. AC3's second half ("a plain
`:json` field is STILL rejected... re-running/confirming
`queried_json_violations/1` coverage still passes") is satisfied by running
the existing test(s) unmodified against the unmodified function.

### New Rule 10 — `:invalid_localized_text` (locale-set shape)

Added to `validate/1`'s violation-collecting pipeline (append to the
existing `++` chain, after `decimal_violations/1`, before
`cardinality_violations/1` — position is arbitrary, all violations are
collected, not short-circuited).

Fires per `fields` entry, mirroring Rule 6 (`enum_violations/1`)'s
structure exactly, one function covering all four conditions below (not
four separate rule atoms):

- `type == :localized_text` and `:locales` is absent, not a list, or an
  empty list → violation (`"locales must be a non-empty list when type is
  :localized_text"`).
- `type == :localized_text` and `:locales` contains a duplicate entry →
  violation (`"locales must not contain duplicates"`), same shape as Rule
  6's enum-duplicate check.
- `type == :localized_text` and any `:locales` entry does not match
  `^[a-z]{2,8}$` → violation (`"locale \"<value>\" must match
  ^[a-z]{2,8}$"`), one violation per offending entry (or one aggregate
  violation naming every offender — ELIXIR-DEV's choice, both are
  acceptable per-entry-vs-aggregate stylistic variants already present
  elsewhere in this Validator; not load-bearing).
- `type != :localized_text` and `:locales` is present (any value, including
  `[]`) → violation (`"locales must be absent when type is not
  :localized_text"`).

### New Rule 11 — `:invalid_search_strategy`

Same shape, symmetric presence/absence plus a closed-value check:

- `type == :localized_text` and `:search_strategy` is present but not
  `:plain` or `:fulltext` → violation (`"search_strategy must be :plain or
  :fulltext"`).
- `type != :localized_text` and `:search_strategy` is present (any value) →
  violation (`"search_strategy must be absent when type is not
  :localized_text"`).
- `type == :localized_text` and `:search_strategy` absent → **no
  violation** (defaults to `:plain` per `0025` — absence is valid, not an
  error).

### No change needed to Rules 6/7 (enum/decimal) or Rule 5 (FK coverage)

Rules 6 and 7's existing "must be absent when type is not :enum/:decimal"
branches already reject `enum_values`/`decimal_precision`/`decimal_scale`
on a `:localized_text` field with zero code change (their guard is `type !=
:enum`/`type != :decimal`, which `:localized_text` satisfies identically to
every other non-matching type).

**Open question, flagged not silently resolved (§10.4):** Rule 5
(`fk_field_coverage_violations/1`) checks only that an `fk_def.field` names
an existing field — it does not, today, check type-compatibility, and this
design adds no such check. Nothing stops a definition from naming a
`:localized_text` field as an `fk_def.field`, which is semantically
incoherent (a blob-keyed-by-locale map cannot be a foreign key value). This
pre-existing gap already applies to `:json` fields today (also
uncoerced) and is not a regression this requirement introduces — flagged
per this task's own instruction to surface rather than silently work around
an adjacent gap, not something this design fixes.

## 3. `Letflow.Entities.Definition.DDL` — the generated-column-per-locale case, at REQ-296's own named extension point

### 3.1 `column_spec()` — two new optional keys

```elixir
@type column_spec :: %{
        required(:name) => String.t(),
        required(:pg_type) => String.t(),
        required(:nullable) => boolean(),
        optional(:generated_as) => String.t() | nil,
        optional(:source_field) => String.t() | nil
      }
```

- **`:generated_as`** — `nil` for every column this module already produces
  (structural + ordinary promoted). Non-`nil` only for a locale-derived
  generated column: the SQL generation-expression text that goes inside
  `GENERATED ALWAYS AS (<expr>) STORED` (§3.3). Absent/`nil` is the default
  a caller reading an existing `column_spec()` (built before this
  requirement) should assume — `Map.get(column, :generated_as)`, never
  `Map.fetch!/2`, at every consumption site (§3.4).
- **`:source_field`** — `nil` when the column's name already equals its
  originating `field_def().name` (every column this module produced before
  this requirement). Set to the originating field's `:name` only for a
  locale-derived generated column, whose own name (`"stem_kk"`) differs
  from the field name (`"stem"`) that produced it — this is the piece
  `Letflow.Entities.Query.Allowlist` needs (§5) to look up the right
  `Definition.field_type()` context, since a `fields_by_name` lookup keyed
  on the generated column's own name would miss.

`structural_columns/0` and the existing single-column branch of
`promoted_columns/1` are unchanged in the values they produce (both keys
simply absent, which `Map.get/2`-based readers treat as `nil` — no literal
map in this module needs editing to add explicit `generated_as: nil,
source_field: nil` pairs, though doing so is also acceptable if
ELIXIR-DEV prefers explicit literals for readability; not load-bearing
either way).

### 3.2 `field_type_to_pg_type/1` — one new defensive clause

Gains a ninth `case` clause: `:localized_text -> :never_promoted` —
identical defence-in-depth shape to the existing `:json -> :never_promoted`
clause. This keeps `field_type_to_pg_type/1` exhaustive over all 9
`field_type()` values (moduledoc's "never raises on any of the 8" becomes
"9") and keeps a `:localized_text` field structurally excluded from the
**single-column** promotion path — its promotion, when it happens, always
goes through the **N-column** path (§3.3), dispatched before
`field_type_to_pg_type/1` is ever called for such a field (§3.4).

### 3.3 `localized_text_column_specs/1` — NEW, public, pure

```elixir
@spec localized_text_column_specs(Definition.field_def()) :: [column_spec()]
```

Given a `:localized_text` `field_def()` (already `Validator`-passed, so
`:locales` is a non-empty, deduplicated, format-valid list, and
`:search_strategy` is `:plain` or absent-meaning-`:plain`, or `:fulltext`),
returns one `column_spec()` per locale, in `:locales`'s declared order
(stable, deterministic, matching `promoted_columns/1`'s own
already-stated determinism guarantee):

- `name`: `"<field.name>_<locale>"` (0023's own naming example —
  `stem_kk`, `stem_ru`, `stem_en`).
- `pg_type`: `"text"` when `search_strategy` is `:plain` (default);
  `"tsvector"` when `:fulltext`.
- `nullable`: always `true` (a locale may legitimately have no content yet
  for a given record — same "additive, nullable" posture every promoted
  column already has).
- `generated_as`: the SQL expression text (no `GENERATED ALWAYS AS`/
  `STORED` wrapper — that wrapper is added once, at DDL-assembly time,
  §3.4/§3.5, not duplicated per case):
  - **`:plain`**: `` field_values->'<field.name>'->>'<locale>' `` — a plain
    JSONB path-then-text-extract, no cast, matching the blob shape 0023's
    own example gives (`{"stem": {"kk": "...", ...}}`).
  - **`:fulltext`**: `` to_tsvector('simple', coalesce(field_values->'<field.name>'->>'<locale>', '')) `` —
    wrapped in `coalesce(..., '')` because `to_tsvector(NULL)` is `NULL`,
    which would make a record missing that locale's content silently
    invisible to a future `IS NOT NULL`/existence check on the generated
    column rather than correctly reporting "no content, empty tsvector."
    **`'simple'` is a deliberate, stated choice, not silently picked** —
    see §10.1 (open question: no per-locale dictionary/language config is
    named by `0025` or this task; `'simple'` is Postgres's always-available,
    language-neutral text-search configuration, chosen so the mechanism
    exists and is testable now, without this requirement quietly deciding
    a per-language-stemming policy `0025` never asked it to decide).
- `source_field`: `field.name` (§3.1) — always set (never `nil`) for every
  `column_spec()` this function returns.

`field.name`/`locale` interpolation reuses `valid_identifier?/1`-checked
values only at the point they are composed into a column *name* (§3.4's
existing `check_column_identifiers/1` already covers this generically,
since it iterates `columns` — no new identifier-safety code needed here);
interpolation into the **generation-expression text** itself uses the
already-`Validator`-passed `field.name` (name-format-regex-checked,
`^[a-z][a-z0-9_]{0,63}$`) and the already-Rule-10-checked `locale`
(`^[a-z]{2,8}$`) — both closed, regex-validated character sets, so no
additional SQL-string-escaping step is needed beyond what already gates
every other identifier this module emits.

### 3.4 `promoted_columns/1` — dispatch extended at the moduledoc's own named extension point

Per-field dispatch changes from "compute one `column_spec()` via
`field_type_to_pg_type/1`, or none" to "compute a **list** of zero or more
`column_spec()`s per field, via one of two paths chosen by `field.type`":

- `field.type == :localized_text` → `localized_text_column_specs/1` (§3.3),
  which always returns `length(field.locales)` entries (never zero, since
  Rule 10 already guarantees `:locales` is non-empty for a
  `:localized_text` field that reached the DDL generator).
- every other `field.type` → the existing `field_type_to_pg_type/1` branch,
  producing a 0-or-1-element list exactly as today (`{:ok, pg_type} ->` one
  `column_spec()` with `generated_as: nil, source_field: nil`;
  `:never_promoted -> []`).

The outer `Enum.filter(fn field -> promotion_trigger(field, fk_field_names)
!= :not_promoted end)` step is **unchanged** — a `:localized_text` field is
promoted (and therefore contributes its locale columns) under exactly the
same trigger 2 (`queried: true`) `0023`'s own text names ("Same promotion
machinery, different trigger" is 0023's own phrase for this — read
literally: same *trigger*, `queried: true`; different *field type* and
different *column-count* consequence). `promoted_columns/1`'s own `@spec`
and its "stable, deterministic output" guarantee are unchanged in kind —
still `[column_spec()]`, just possibly several entries per originating
field now instead of at most one.

### 3.5 `build_create_table_sql/3`/`column_sql_line/1` — one new branch

`column_sql_line/1` gains a `generated_as`-present branch: when
`Map.get(column, :generated_as)` is non-`nil`, the emitted line is
`` "<name>" <pg_type> GENERATED ALWAYS AS (<generated_as>) STORED `` — no
`NOT NULL`/`DEFAULT` clause at all in this branch (Postgres rejects
`DEFAULT` on a `GENERATED ALWAYS AS` column outright, and this module
already always sets `nullable: true` for these columns, §3.3, so the
existing `nullable`-driven `NOT NULL`/absence logic would produce the
correct "no `NOT NULL`" outcome anyway even without this special-casing —
the branch exists to suppress `default_clause_for/1`, which has no
`:generated_as`-aware clause today and would otherwise need one added
purely to keep returning `""` for these columns; simplest to short-circuit
the whole trailing-clause computation for a generated column in one place).
`enum_check_constraints/2` is unaffected — it filters on `field.type ==
:enum`, never true for a `:localized_text` field's derived columns.

## 4. `Letflow.TenantProvisioning`/`Letflow.TenantProvisioning.ColumnPromotion` — executor wiring

### 4.1 `ColumnPromotion` schema — one new column, additive migration

New field: `generated_as :: String.t() | nil` — nullable, no default
constraint beyond `NULL`, added to `@cast_fields`, **not** added to
`@required_fields` (an ordinary, non-generated promotion's row carries
`generated_as: nil`, exactly like today). A new `priv/repo/migrations/*.exs`
adds this one nullable column to `entity_column_promotions` — additive-only,
consistent with 0023's own rule applied reflexively to this bookkeeping
table (not itself a per-entity-type table, but the same posture).

### 4.2 `register_column_promotion/4` — `column_spec` parameter widened

```elixir
@spec register_column_promotion(
        entity_type :: String.t(),
        attribute :: String.t(),
        column_spec :: %{
          pg_type: String.t(),
          nullable: true,
          optional(:generated_as) => String.t() | nil
        },
        tenant_ids :: [Ecto.UUID.t()] | :all
      ) :: {:ok, [ColumnPromotion.t()]} | {:error, term()}
```

`Map.get(column_spec, :generated_as)` (never `Map.fetch!/2`) — absent means
`nil`, so every existing REQ-297 caller/test passing the old two-key shape
keeps compiling and behaving identically (AC-equivalent to REQ-299's own
"unchanged in shape for existing callers" discipline).

**How a `:localized_text` field's N locale columns register.** No new
public function. The caller (whoever eventually wires a definition's
promotion — REQ-298 or later; no such automatic write-path trigger exists
yet for *any* field type as of this design, confirmed by grep — §10.2) calls
`register_column_promotion/4` **once per `column_spec()`**
`DDL.promoted_columns/1` returns for that field (i.e., once per locale),
using `attribute: column_spec.name` (e.g. `"stem_kk"`) — the same
convention `register_column_promotion/4` already uses today, where
`attribute` and `column_name` are set to the same string. This means one
logical `:localized_text` field with 3 locales produces 3
`ColumnPromotion` rows per tenant, each independently tracked through
`0024`'s per-`(tenant_id, entity_type, attribute)` state machine — this is
`0024`'s own bookkeeping granularity applied unchanged; "attribute" there
already means "one physical column," not "one logical field," so this is
not a new concept, only a new caller pattern (call the existing function
N times instead of once).

### 4.3 `execute_add_column/3` (private) — one new branch for the incremental-promotion path

The `ALTER TABLE ... ADD COLUMN "<name>" <pg_type>` text gains a
`GENERATED ALWAYS AS (<promotion.generated_as>) STORED` suffix whenever
`promotion.generated_as` is non-`nil` — same textual shape §3.5 gives
`DDL`'s own `CREATE TABLE` path, kept consistent across both halves of
table DDL (this module's own moduledoc already states that consistency
goal for the ordinary-column case; this extends it to the generated-column
case). This branch is only ever exercised when a locale column is promoted
**after** the entity's table already exists — a brand-new table's locale
columns are created correctly by `create_and_populate_entity_table/3`'s
existing `DDL.generate_table_ddl/2` call (§3.4/§3.5) without needing this
branch at all, since that path emits the full `CREATE TABLE` text including
every promoted column, generated or not, in one statement.

### 4.4 `@known_fixed_pg_types` — one new entry

Gains `"tsvector"`. `pg_types_equivalent?/4`'s existing default branch
(`{normalized_type, _p, _s} -> existing_data_type == normalized_type`)
already handles `"tsvector"` correctly with no further change —
`information_schema.columns.data_type` reports `"tsvector"` verbatim for
such a column, matching this module's existing non-`numeric` comparison
shape.

### 4.5 Backfill: Postgres's own `GENERATED ALWAYS ... STORED` semantics ARE the backfill, stated as a deliberate consequence

`0024`'s backfill sub-question (replay through
`Letflow.Entities.Record.Projector.rebuild_projection/2`) answers *how a
promoted column's historical values get populated for records that predate
the promotion* for an ordinary promoted column, whose value must be
extracted from event history at promotion time. A `GENERATED ALWAYS AS
(<expr>) STORED` column is different in kind: Postgres computes its value
from `<expr>` (here, a JSONB-path read of the **current** `field_values`
column on the same row) automatically, synchronously, as part of the same
`ALTER TABLE ... ADD COLUMN` statement that adds it — for every existing
row, in one pass, with no separate application-level backfill step, and
again on every future `INSERT`/`UPDATE` of `field_values` for that row.
**This means a locale-derived generated column's `ColumnPromotion` row has
no meaningful `backfilling` interval** — `execute_add_column/3`'s own
success already implies full backfill, for this column shape specifically.
This is stated here explicitly as a deliberate, scoped consequence of this
column shape (not a reopening of `0024`'s general backfill mechanism,
which stays exactly as designed for every other promoted-column shape) —
flagged for REVIEWER per this task's "don't silently re-decide what a
decision record already settled" rule, since it is adjacent to, though not
in conflict with, `0024`'s own backfill answer.

### 4.6 A gap this design closes, not merely flags: `Allowlist.load/2`'s `json_field_entries` step needs one new filter

**Restated from §0's finding.** `load/2`'s existing (REQ-299,
untouched-by-that-requirement) `json_field_entries` construction filters
only on `Map.get(field, :queried) == true` — it applies to **every**
`field_type()` that can legally be `queried: true`. Before this
requirement, that set was `{:string, :integer, :decimal, :boolean, :date,
:datetime, :enum}` — exactly `Compiler.json_cast_dynamic/2`'s 7 existing
clauses, no gap. This requirement adds an 8th type that can be `queried:
true` (`:localized_text`) **without** adding a matching
`json_cast_dynamic/2` clause (correctly — a `:localized_text` value is a
JSON *object* keyed by locale, not a scalar; there is no sensible single
`?->>?` cast for it as a whole). Left unfixed, a `:localized_text` field
with `queried: true` would be allowlisted by `load/2` as `source:
:json_field, type: :localized_text` and crash
`Compiler.build_filter_dynamic/2`'s `:json_field` clause with
`FunctionClauseError` the moment such a resolved field reaches it — the
exact "hit on first contact by the suite's own mainline" failure mode
`req299-allowlist-per-entity-type.md`'s REWORK ITERATION 1 already
documented for the `:typed_column` side.

**Fix, minimal and scoped:** `load/2`'s `json_field_entries` pipeline gains
one additional filter step, immediately alongside its existing
`Enum.filter(&(&1.queried == true))`: also exclude `type == :localized_text`.
Concretely, the filter becomes "`queried == true` **and** `type !=
:localized_text`" (a two-condition `Enum.filter/2`, not a new function).
Every other line of `load/2` — `typed_column_entries`'s construction (still
exactly the structural 7, per REQ-299 REWORK ITERATION 1, untouched by this
requirement), the shadowing merge, the function's contract and error shapes
— is unchanged. This is the smallest change that makes AC9 (`mix
letflow.check` passes) achievable at all once a `:localized_text,
queried: true` fixture exists anywhere in the suite, which AC1/AC3's own
required tests guarantee will happen.

**Consequence, stated plainly:** after this fix, a `:localized_text` field
marked `queried: true` is **not allowlisted by `Allowlist.load/2` under its
own bare name at all** — neither as `:typed_column` (already excluded, per
REQ-299) nor now as `:json_field` (excluded by this fix). Only its
*derived* per-locale generated columns (`stem_kk`, `stem_ru`, ...) are
ever candidate allowlist entries, and only once `Allowlist.load/2` itself
is extended to expose them under REQ-300 (§5, §10.2) — until then, a
`:localized_text` field's locale columns exist in the database (§3, §4)
and are enumerable via `Allowlist.typed_columns/2` (§5), but are not
reachable through `Allowlist.load/2` → `Compiler.compile/2` at all. This is
the same shape of narrowing REQ-299 already applied to ordinary promoted
fields, applied here to a new field type for the identical structural
reason.

## 5. `Letflow.Entities.Query.Allowlist` — exposing the generated columns via `typed_columns/2`

`typed_columns/0` and `load/2`'s **public contracts** are unchanged.
`load/2`'s **body** changes only per §4.6 (one filter condition added, not
a new step). `typed_columns/2` (REQ-299's per-entity-type accessor) and its
private `entity_type_typed_columns/1` helper are extended, additively, to
handle a promoted `column_spec()` whose `:source_field` (§3.1) is
non-`nil`:

- `entity_type_typed_columns/1`'s existing lookup — "for each `%{name:
  promoted_name}` in `promoted`, look up the matching field in
  `definition_document.fields` (by `.name`)" (`req299-*.md` §1.3) — is
  extended to key that lookup on `Map.get(promoted_entry, :source_field) ||
  promoted_entry.name` instead of `promoted_entry.name` unconditionally.
  For every non-locale promoted column this is a no-op (`:source_field` is
  `nil`, so it falls back to `promoted_entry.name`, identical to today).
- **The exposed `Definition.field_type()` for a locale-derived column is
  `:string`, always — never `:localized_text` and never a
  `tsvector`-flavored variant (no such variant exists in the closed
  `field_type()` set, and this design adds none).** Rationale, stated so a
  later reader does not have to re-derive it: both the `:plain`
  (Postgres `text`) and `:fulltext` (Postgres `tsvector`) column shapes
  hold textual content that a `Definition.field_type()`-typed caller should
  treat as string-like at this layer; the ranked/`@@`-operator query
  semantics `:fulltext` actually needs are a `Compiler`-layer concern that
  does not exist yet for *any* field type (REQ-300's job), so this design
  does not invent a place to carry that distinction prematurely — see §10.3
  for the explicit open question this leaves for REQ-300.
- `typed_columns/2`'s own moduledoc gains one sentence stating that a
  `:localized_text` field's promoted locale columns appear in its result
  under their own composed names (`"stem_kk"`, not `"stem"`), typed
  `:string`, alongside — not replacing — the fact that `"stem"` itself
  (the original field name) never appears in `typed_columns/2`'s result at
  all, since `"stem"` is never itself a promoted column name (only its
  locale derivatives are, per `DDL.promoted_columns/1`'s output, §3.4).

No change to `typed_columns/0`, `resolve_field/2`, `allowlist()`,
`allowlisted_field()`, or `field_source()` — all unchanged, matching
REQ-299's own precedent of touching only what a new capability strictly
requires.

## 6. Invariants

- **INV-1 (Rule 3 unweakened).** `queried_json_violations/1`'s source text
  (`compiler.ex`... no, `validator.ex`'s Rule 3) is byte-for-byte unchanged
  by this requirement. Proven by `git diff` showing zero lines changed in
  that function, plus the existing `:json`-rejection test(s) passing
  unmodified (AC3's second half).
- **INV-2 (additive-only DDL, 0023's rule, reflexively applied here).**
  `localized_text_column_specs/1` and the `ColumnPromotion` schema addition
  (§4.1) only ever add columns — no code path in this design drops, renames,
  or narrows a column, including a locale later removed from a
  definition's `:locales` list (removing a locale from `:locales` is
  **not** itself validated as forbidden by this design — see §10.5, an
  explicitly flagged non-decision).
- **INV-3 (no atom fabrication, matching REQ-299's INV-C).** Nothing in
  this design calls `String.to_atom/1`/`String.to_existing_atom/1` on a
  locale code or a composed column name to produce a column *reference*
  atom for query purposes — `typed_columns/2`'s output stays name-keyed
  (`String.t()`), exactly as REQ-299 established, never atom-keyed for a
  promoted/derived column.
- **INV-4 (SQL-injection posture unchanged).** Every string interpolated
  into a `generated_as` expression or a generated column's own name is
  drawn from an already-Validator-passed, regex-format-checked source
  (`field.name`: `^[a-z][a-z0-9_]{0,63}$`; `locale`: `^[a-z]{2,8}$`, new
  Rule 10) — the same "defence-in-depth on top of an already-enforced
  precondition" posture `DDL`'s own moduledoc already states for
  `table_name`/attribute identifiers, extended to this module's one new
  place that builds a SQL *expression* (not just an identifier).
- **INV-5 (AC5's narrowing, restated as an invariant so it is not silently
  reopened).** Neither a `:localized_text` field's own name nor any of its
  derived locale-column names is ever reachable through
  `Allowlist.load/2` → `Compiler.compile/2`/`Cursor.paginate/5` as of this
  requirement (§4.6). This is `load/2`'s provable behavior, not merely a
  documentation claim — the same standard REQ-299's own INV-D held itself
  to.

## 7. DB tables/columns touched

- **Any per-entity-type table** (`entity_<entity_type>`, `0023`/REQ-296):
  gains `N` new generated columns (`text` or `tsvector`) per
  `:localized_text`, `queried: true` field declared on that entity type's
  active definition — via `CREATE TABLE` (new entity type) or `ALTER TABLE
  ... ADD COLUMN ... GENERATED ALWAYS AS (...) STORED` (locale added to an
  existing `:localized_text` field's definition after the table already
  exists). No structural column changes.
- **`entity_column_promotions`** (global, REQ-295/297): one new nullable
  column, `generated_as :: text`. No new table.
- **No change** to `entity_definitions`, `entity_events`, or
  `entity_record_latest` (the pre-0023 shared table, superseded but not
  touched by this or any 0023-lineage requirement).

## 8. Cross-module dependencies

- `Letflow.Entities.Definition.DDL.promoted_columns/1` → `localized_text_column_specs/1`
  (new, same module) → nothing external. Pure, no I/O, unchanged posture.
- `Letflow.TenantProvisioning.register_column_promotion/4`/`run_column_promotion/1`
  → `Letflow.Entities.Definition.DDL.{promoted_columns/1, valid_identifier?/1}` —
  already an existing dependency direction (`DDL` has no dependency back on
  `TenantProvisioning`), unchanged.
- `Letflow.Entities.Query.Allowlist.entity_type_typed_columns/1` →
  `Letflow.Entities.Definition.DDL.promoted_columns/1` — already an
  existing dependency (REQ-299), reused, not duplicated (INV-B from
  `req299-*.md`, unchanged and still honored: this design adds no second,
  independently-maintained enumeration of promoted/generated columns).
- `Letflow.Entities.Query.Compiler`/`Cursor` — **zero new dependency,
  zero diff** (AC5's own "Compiler needs no change to its filter
  compilation" claim from `0023`, and this design's own §4.6 fix lives
  entirely inside `Allowlist.load/2`, not inside `Compiler`/`Cursor`).

## 9. Moduledoc citation requirement (AC6)

`Letflow.Entities.Definition.DDL`'s moduledoc (the module that implements
the mechanism) must state, in its own words, which mechanism this
requirement implements — both plain-text and `tsvector` generated columns,
selected per-field by `search_strategy`, defaulting to `:plain` — and cite
`docs/migration/decisions/0025-promoted-fk-ondelete-and-localized-text-search-strategy.md`,
"Sub-question 2" by name, **without** re-deriving or re-justifying the
choice (that reasoning lives in `0025` alone). The test AC6 asks for is a
single assertion per `search_strategy` value: a `:plain` field's DDL
contains a `GENERATED ALWAYS AS (...) STORED` column of Postgres type
`text` with no `to_tsvector` call in its expression; a `:fulltext` field's
DDL contains one of Postgres type `tsvector` whose expression calls
`to_tsvector('simple', ...)`. Both assertions are directly checkable
against `DDL.generate_table_ddl/2`'s returned SQL text (or against
`localized_text_column_specs/1`'s returned `column_spec()`s directly,
without going through full DDL text — either is acceptable, the latter is
simpler).

## 10. Open questions (not silently resolved)

*(A few inline cross-references elsewhere in this doc were written as
"§6.x" before this section was renumbered to §10 — those refer to
§10.1–§10.5 below. Gathered here for a single scan, alongside items
already flagged inline at §3.3 and §4.5.)*

### 10.1 (AC5) — Is end-to-end filter/sort on a locale's generated column deliverable by REQ-301 alone?

**No. Blocked pending REQ-300, for the identical structural reason
REQ-299's own AC4 was blocked — confirmed by direct source re-read (§0),
not assumed from the task brief.**

`Compiler.build_filter_dynamic/2`'s `:typed_column` clause and
`Cursor`'s two equivalent functions resolve a column atom only via the
zero-arg `Allowlist.typed_columns/0` (the fixed structural 7). A locale
column like `stem_kk` is never in that table, for any entity type, by
construction — `typed_columns/0` cannot become entity-type-aware without
either editing `compiler.ex`/`cursor.ex` (which AC5's own literal wording
for REQ-299 forbade, and which REQ-301 has no more standing than REQ-299
did to unilaterally decide) or resorting to the ambient-state approach
`req299-*.md` §"REWORK ITERATION 1" already explicitly rejected as an
OTP-idiom violation. That rejection's reasoning applies verbatim here; this
design does not re-litigate it.

**What this design delivers instead, narrowing AC5 the same way REQ-299's
own rework narrowed its AC4** (subject to the same REVIEWER sign-off this
requirement's task description explicitly anticipates):

- The generated columns physically exist in the database, correctly typed
  and indexed as ordinary Postgres columns (§3, §4) — a `psql`/direct-SQL
  query against `stem_kk` **already works today**, outside the
  `Allowlist`/`Compiler` stack; this design's DDL/executor halves are fully
  deliverable and fully tested (AC4, AC6, AC7).
- Their existence and naming are correctly, identifiably exposed through
  `Allowlist.typed_columns/2` (§5) — an entity type's locale columns are
  enumerable, per-entity-type, today, via the same mechanism REQ-299 built
  for ordinary promoted columns.
- What is **not** deliverable: a `filter`/`sort` request through
  `Letflow.Entities.Query.Compiler.compile/2`/`Cursor.paginate/5`
  successfully targeting `stem_kk`. That requires REQ-300 to give
  `compiler.ex`/`cursor.ex` (or their REQ-300-era replacements) a real
  per-entity-type atom-resolution path, and to repoint `compile/2` at the
  correct per-entity-type table in the first place (`compile/2` still
  queries `Letflow.Entities.Record.Latest`/`entity_record_latest`, the
  pre-0023 shared table, which has no `stem_kk` column at all — resolving
  the atom is necessary but not sufficient even setting `Allowlist` aside
  entirely, exactly as `req299-*.md` §5.1 already noted for the ordinary-
  promoted-column case).

**Recommended narrowed AC5 test** (for REQ-VALIDATOR/REVIEWER to accept or
reject, same escalation shape as REQ-299's own rework): assert
`Allowlist.typed_columns/2` for an entity type with a `:localized_text,
queried: true, locales: ["kk", "ru"]` field returns a result whose keys
include `"stem_kk"` and `"stem_ru"` (both typed `:string`), and does
**not** include `"stem"` itself — proving the generated columns are
correctly identified per-entity-type — explicitly **not** asserting
anything about a `Compiler.compile/2`-driven filter/sort actually
returning locale-matched records, which is the part this design states
plainly it cannot deliver.

### 10.2 No automatic write-path trigger exists yet for *any* promoted field, not just localized-text

Grepping `lib/` for callers of `register_column_promotion/4` outside
`tenant_provisioning.ex` itself found none — REQ-297 built the executor as
a directly-callable capability; nothing today calls it automatically when
an entity definition is created/updated with a new `queried: true` or FK
field, for *any* field type. This is not a gap this requirement introduces
or is expected to close — REQ-298 (`status: pending`) or a later
requirement owns wiring a definition-save path to
`register_column_promotion/4`/`run_column_promotion/1`. This design's own
tests exercise these functions directly (as REQ-297's own tests already
must, for ordinary promoted columns).

### 10.3 `typed_columns/2`'s output carries no `search_strategy`/plain-vs-tsvector signal

Once REQ-300 gives `Compiler`/`Cursor` a resolution path for promoted
columns generally, filtering a `:fulltext` locale column correctly (`@@
plainto_tsquery(...)`, not `=`/`ILIKE`) will need to know which strategy
produced it — information `typed_columns/2`'s current `%{name =>
field_type()}` return shape has nowhere to carry (§5 exposes both
`:plain` and `:fulltext` columns identically, as bare `:string`). This
design does not extend `typed_columns/2`'s return shape to carry it,
because nothing in this requirement's own scope consumes that information
— flagged explicitly as a known extension REQ-300 will likely need to make
(a new field on the map's value, or a sibling accessor), not something
this design silently defers by omission.

### 10.4 `:localized_text` as an `fk_def.field` — pre-existing gap, not fixed here

See §2's inline note — Rule 5 does not check FK/type compatibility today
for any field type (`:json` included), and this design adds no such check
for `:localized_text` either. Flagged, not fixed, consistent with "surface
adjacent gaps rather than silently expanding this requirement's own scope
to fix them."

### 10.5 Removing a locale from `:locales` after promotion — not validated as forbidden

`0023`'s additive-only rule (§ "Promotion is additive and one-way") speaks
in terms of columns, not of a field's own locale set shrinking on a
*later* definition version. This design does not add a Validator rule
forbidding a new definition version from declaring a narrower `:locales`
list than a prior version already promoted from (which would leave an
orphaned-but-never-dropped generated column, consistent with "demotion is
forbidden," but with no validator guard flagging the now-pointless
column at authoring time). Flagged as a gap for REVIEWER to decide whether
it needs its own rule, or is acceptable as "the column simply becomes
unused going forward, per the same additive-only posture that already
tolerates dead promoted columns in general" — this design takes no
position, per this task's instruction not to silently resolve an
unstated assumption.
