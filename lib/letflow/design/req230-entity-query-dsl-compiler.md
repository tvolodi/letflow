# Design: REQ-230 — Entity query DSL: closed-enum operators, per-tenant field allowlist, parameterised SQL compiler (query/types.zig + allowlist.zig + compiler.zig)

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-230's full entry (scope items 1–3, the seven
  acceptance criteria, `depends_on: [REQ-226]`, the explicit NOT-IN-SCOPE note
  on cursor pagination/field-grant redaction (REQ-231) and route/controller),
  and REQ-231's entry (read for boundary/hand-off shape only — REQ-231 is not
  this design's scope).
- `handoffs/WF02-REQ230-20260907/step-00-git-setup.json` — task framing,
  confirms this design precedes CODE-DESIGN-VALIDATOR, ELIXIR-DEV,
  SECURITY-REVIEWER (mandatory), REVIEWER, TEST-RUNNER in that order.
- `lib/letflow/entities/definition.ex` (REQ-225) — `Letflow.Entities.Definition.t()`/
  `field_def()`: `name`, `type` (`field_type() :: :string | :integer | :decimal
  | :boolean | :date | :datetime | :enum | :json`), `required`, `queried`,
  `enum_values`, `decimal_precision`, `decimal_scale`, `default`. The
  moduledoc's Rule 3 note that a `:json`-typed field can never also be
  `queried: true` (enforced by `Letflow.Entities.Definition.Validator`'s
  `queried_json_violations/1`, `lib/letflow/entities/definition/validator.ex`
  lines 296–309).
- `lib/letflow/entities/entity_definition.ex` (REQ-226) — the persisted
  `entity_definitions` row schema (`tenant_id`, `name`, `definition_json`,
  `status`, `artifact_version_id`, …) and its moduledoc's note that
  `Letflow.Entities.Definitions.get_active_definition_by_name/2` is the
  authoritative "give me the currently-active definition for this name" call.
- `lib/letflow/entities/definitions.ex` — `get_active_definition_by_name/2`
  (lines 253–274): resolves via `Repository.Activation.resolve/3` then reads
  the `entity_definitions` row by `artifact_version_id`, returning
  `{:ok, %EntityDefinition{}} | {:error, :not_found} | {:error, :invalid_schema_name}`.
  `entity_definition.definition_json` is the raw map this design decodes into
  a `Letflow.Entities.Definition.t()` (its `fields` list) to build an
  allowlist from.
- `lib/letflow/entities/record/latest.ex` (REQ-228) — `Letflow.Entities.Record.Latest`'s
  actual `entity_record_latest` schema columns: `id` (binary_id PK),
  `entity_type` (`:string`), `record_id` (`Ecto.UUID`), `field_values`
  (`:map`, JSONB), `deleted` (`:boolean`), `entity_def_version` (`:binary`),
  `last_event_global_seq` (`:integer`), `inserted_at`/`updated_at`
  (`:utc_datetime_usec`). This is the actual table a compiled query runs
  against — every entity-definition-declared field (other than the
  container `field_values` itself) lives as a JSONB key inside
  `field_values`, never as its own typed column, **except** the handful of
  structural columns above which are not entity-definition fields at all
  but do share the same string-keyed namespace a caller might plausibly
  (if implausibly) try to name a business field after (`"entity_type"`,
  `"record_id"`, `"deleted"`, `"entity_def_version"`,
  `"last_event_global_seq"`, `"inserted_at"`, `"updated_at"`) — this is
  exactly the shadowing scenario AC3 asks this design to resolve (§4.3).
- `docs/anti-patterns.md`'s "Duplicating an `Ecto.Query.fragment/1` SQL
  literal instead of sharing it via a module attribute" entry (lines
  274–307) — confirms, against a real Ecto compile-time error
  (`Ecto.Query.CompileError`, "to prevent SQL injection attacks,
  `fragment(...)` does not allow strings to be interpolated as the first
  argument via the `^` operator"), that `fragment/1`'s first argument must
  macro-expand to a literal binary known at compile time; a
  `@module_attribute` inlines as such a literal and is the sanctioned way to
  share one fragment SQL-shape string across call sites. This design's
  compiler is built around this exact constraint (§5.2).
- `lib/letflow/definitions.ex` lines 1923–2076 — the codebase's only existing
  `fragment/1` precedent: `fragment("? ILIKE ?", d.name, ^pattern)` (simple
  runtime-value binding) and `@rank_case_sql` (a shared module-attribute
  literal referenced as `fragment(@rank_case_sql, ...)` from three call
  sites) — the direct structural precedent for §5.2's per-operator fragment
  literals.
- `lib/letflow/engine/expr.ex` lines 129–133 — `Letflow.Engine.Expr`'s own
  closed comparison-operator `@type cmp_op :: :eq | :neq | :lt | :lte | :gt
  | :gte`, tokenized from source text into `{:cmp_op, op}` tokens and never
  accepted as a free-form string past the tokenizer. This is the established
  in-repo idiom for "a closed set of comparison operators represented as a
  closed `@type` union of atoms, never a string," which §2's `filter_op()`
  follows directly (extended with membership/string/null-check operators
  `Expr` itself has no need for).
- `lib/letflow/api/pagination.ex` (REQ-067) — read for naming-convention
  precedent only (`Letflow.Api.Pagination`, `Letflow.Api.Pagination.Cursor`/
  `Page` as siblings under one umbrella module) and its moduledoc's explicit
  statement that a decoded cursor carries **no** tenant/schema field —
  confirms the established pattern of stating a "structurally, not just
  conventionally" security guarantee directly in a moduledoc, which §3.1 and
  §5.1 both follow for the allowlist/compiler's own tenant-scoping and
  injection guarantees. REQ-067's actual cursor codec is REQ-231's concern
  (cursor pagination), not this design's — not otherwise used here.
- `lib/letflow/design/iss0438-entity-subsystem-scoping.md`'s "A finding
  ISS-0438 itself missed" section (lines 210–230) — confirms `query/`'s
  original R-Co framing: "a three-layer SQL-injection defence: closed
  operator enum → allowlist-only column resolution → positional-parameter
  binding, plus per-user field-level access control" (the last clause is
  REQ-231's field-grant scope, not this design's).
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant data
  isolation, live now), INV-6 (new data-access paths must state which
  invariants apply and how, live now), INV-7 (no SQL string interpolation —
  all SQL via parameterised Ecto placeholders, BLOCKER severity, live now),
  INV-8 (no unhandled crashes on realistic failure paths, live now). §7
  states this design's compliance with each explicitly, per INV-6.
- Searched `lib/letflow/` for any existing allowlist-based field-filtering
  module, closed filter-operator-atom set used for query filtering (as
  opposed to `Expr`'s expression-evaluator operators), and any existing
  JSONB `fragment/1` query code: **none found**. This design is the first
  allowlist-resolved, JSONB-backed filter/sort compiler in this codebase —
  no existing module to extend, no existing convention this design
  contradicts.
- REQ-230's own cited R-Co source
  (`c:\Users\tvolo\dev\ai-dala\R-Co\src\entities\query\types.zig`,
  `allowlist.zig`, `compiler.zig`) is a Windows path **not reachable from
  this Linux sandbox** — confirmed by attempted lookup. REQ-230's own text
  names "QRY-01..05's operator set" without stating what QRY-01..05 actually
  are, and no QRY-01..05 definition exists anywhere accessible in this repo
  (grepped `docs/` and `lib/` for `QRY-0` — no hits). **§2's operator enum is
  therefore this design's own construction, not a transcription of QRY-01..05
  or of `types.zig`'s actual contents** — stated here explicitly rather than
  silently presented as ported. It is built to satisfy REQ-230's own text's
  named baseline ("equality, comparison, membership, string-prefix/contains,
  null-checks, sort direction") plus the modest extensions §2.1 justifies.

## 1. Scope (from REQ-230's own text, restated)

1. **types.zig-equivalent** (§2): a closed enum of filter operators and a
   closed enum of sort directions. No free-form operator string ever reaches
   the compiler.
2. **allowlist.zig-equivalent** (§3): a per-tenant field allowlist loader
   resolving a query's referenced field names against REQ-225's entity
   definition, with an explicit, moduledoc-stated typed-column-vs-JSONB-key
   shadowing precedence rule. A field absent from the allowlist is rejected
   before reaching the compiler.
3. **compiler.zig-equivalent** (§5): compiles an allowlisted filter/sort
   request into a parameterised `Ecto.Query`. Every caller-supplied VALUE is
   bound positionally; JSONB field access goes through `fragment/1` under the
   literal-vs-runtime-value discipline §0 cites.

**Not in this design** (§8): no cursor pagination, no field-grant redaction
(REQ-231's scope); no route or controller — this compiler backs the deferred
`Letflow.Routers.EntityQuery` router row, unbuilt, per REQ-225/226's own
precedent for deferred consumer contracts.

## 2. `types.zig`-equivalent — the closed operator/direction enums

### 2.1 Operator set — this design's own construction, justified

Since R-Co's `types.zig` is unreachable (§0) and no `QRY-01..05` definition
exists anywhere accessible in this repo, this design defines a closed
operator set covering the six categories REQ-230's own text names
(equality, comparison, membership, string-prefix/contains, null-checks, sort
direction), each restricted to the field types it is meaningful for:

| Operator atom | Category | Meaning | Valid `field_type()`s |
|---|---|---|---|
| `:eq` | equality | `=` | all seven non-`:json` types (`:json` is never `queried: true`, §0, so never allowlisted — §3.2) |
| `:neq` | equality | `<>` | same as `:eq` |
| `:gt` | comparison | `>` | `:integer`, `:decimal`, `:date`, `:datetime` |
| `:gte` | comparison | `>=` | same as `:gt` |
| `:lt` | comparison | `<` | same as `:gt` |
| `:lte` | comparison | `<=` | same as `:gt` |
| `:in` | membership | SQL `IN (…)` against a caller-supplied list | `:string`, `:integer`, `:decimal`, `:enum` |
| `:not_in` | membership | SQL `NOT IN (…)` | same as `:in` |
| `:contains` | string | case-insensitive substring (`ILIKE '%value%'`) | `:string` only |
| `:starts_with` | string | case-insensitive prefix (`ILIKE 'value%'`) | `:string` only |
| `:is_null` | null-check | `IS NULL` (no caller value) | all types |
| `:is_not_null` | null-check | `IS NOT NULL` (no caller value) | all types |

Sort direction is a separate, second closed enum (not folded into the
operator enum — a sort clause has no "value" the way a filter clause does):

| Direction atom | Meaning |
|---|---|
| `:asc` | `ORDER BY … ASC` |
| `:desc` | `ORDER BY … DESC` |

```
@type filter_op ::
        :eq | :neq | :gt | :gte | :lt | :lte
        | :in | :not_in | :contains | :starts_with
        | :is_null | :is_not_null

@type sort_dir :: :asc | :desc
```

Both are plain `@type` unions of atoms — mirroring `Letflow.Engine.Expr.cmp_op()`'s
own closed-union idiom (§0) — never `String.t()`. A caller-supplied operator
arrives as a string (e.g. `"eq"`) from whatever JSON request body a future
router deserialises; §4.1's `parse_filter_op/1`/`parse_sort_dir/1` are the
**only** functions in this design that ever see that raw string, and they
return `{:error, {:unknown_operator, raw}}` / `{:error, {:unknown_sort_dir,
raw}}` for anything outside the two tables above (AC1) rather than passing
an unrecognised atom (or, worse, the raw string) any further. No later
function in this design (allowlist resolution, compilation) ever accepts a
`String.t()` where a `filter_op()`/`sort_dir()` is expected — enforced by
`@spec`, not merely by convention.

### 2.2 Request shape

```
@type filter_clause :: %{
        required(:field) => String.t(),
        required(:op) => filter_op(),
        optional(:value) => term()
      }

@type sort_clause :: %{
        required(:field) => String.t(),
        required(:dir) => sort_dir()
      }

@type query_request :: %{
        required(:entity_type) => String.t(),
        optional(:filters) => [filter_clause()],
        optional(:sort) => [sort_clause()]
      }
```

`:value` is `optional` on `filter_clause()` because `:is_null`/`:is_not_null`
carry no value (§4.2 rejects a value supplied alongside either, and rejects
a missing value for every other operator — both are `{:error,
{:value_arity_mismatch, op, field}}`, not silently tolerated). `filters`/
`sort` both default to `[]` when absent — an entity-type query with neither
is a plain "all non-deleted records of this type" read, still routed
through the allowlist/compiler (both no-op cleanly on an empty list) so
there is exactly one code path, not a fast-path-vs-slow-path split.

`filter_clause().field`/`sort_clause().field` are **raw caller strings** at
this stage — §2's types constrain `op`/`dir` to closed enums but
deliberately do **not** constrain `field` to any enum, since the valid
field set is per-tenant, per-entity-type, and only known once §3's allowlist
is loaded. A `query_request()` value with a syntactically well-typed but
semantically bogus `field` is exactly what §3.4/§4.2 reject — §2 alone
cannot reject it, matching AC2's framing ("a plausible-looking but
non-existent field").

## 3. `allowlist.zig`-equivalent — per-tenant field allowlist

### 3.1 Module and file placement

| Module | File | Role |
|---|---|---|
| `Letflow.Entities.Query.Types` | `lib/letflow/entities/query/types.ex` | §2's `filter_op()`/`sort_dir()`/`query_request()` types, `parse_filter_op/1`, `parse_sort_dir/1` (§4.1). |
| `Letflow.Entities.Query.Allowlist` | `lib/letflow/entities/query/allowlist.ex` | §3.2–§3.4: `load/2`, `resolve_field/2`, the shadowing-precedence rule. |
| `Letflow.Entities.Query.Compiler` | `lib/letflow/entities/query/compiler.ex` | §5: `compile/2`, the `Ecto.Query` output. |

**Why a three-module split, not one module (naming decision, per this
design's own instruction to justify it):** the three modules have distinct
call-time inputs and distinct failure domains — `Types` is pure/stateless
(no `prefix`, no DB), `Allowlist` needs `prefix` and reads
`entity_definitions` once per call, `Compiler` needs both an already-loaded
allowlist and the request and touches no table other than
`entity_record_latest` at query-build time (it issues no query itself —
`compile/2` returns an `Ecto.Query.t()` a caller executes). This mirrors
REQ-228/229's own established `Letflow.Entities.Record.{Validator,Latest,Projector}`
three-way split under one namespace (§0), each owning one facet of "one
entity record" — here each of `Types`/`Allowlist`/`Compiler` owns one layer
of the three-layer SQL-injection defence named in REQ-230's own text (§0's
ISS-0438-scoping citation), which keeps the layer boundary the design itself
must reason about (§7) visible as a **module** boundary, not folded into one
file where a future edit could blur which layer a given line belongs to.
Placed under a new `Letflow.Entities.Query.*` namespace (not `Letflow.Entities.Record.*`)
because a query spans a whole `entity_type`'s records, not one record —
matching `Record.Projector`'s own stated reasoning for why
`rebuild_projection/2` (entity-type/tenant-wide) is a sibling of `Record.Latest`,
not a child of it (§0). `Letflow.Entities.Query` itself is **not** a fourth
module — no code needs a shared parent; the common namespace prefix alone
groups the three files, matching how `Letflow.Entities.Record.*` has no
`Letflow.Entities.Record` module either.

### 3.2 Allowlist shape

```
@type field_source :: :typed_column | :json_field

@type allowlisted_field :: %{
        required(:name) => String.t(),
        required(:source) => field_source(),
        required(:type) => Letflow.Entities.Definition.field_type(),
        required(:enum_values) => [String.t()] | nil
      }

@type allowlist :: %{String.t() => allowlisted_field()}
```

`allowlist()` is keyed by the field name a caller writes in a
`filter_clause()`/`sort_clause()` — one entry per name, already
shadow-resolved (§3.3): a name can never map to two entries, so lookup is a
single `Map.fetch/2`, not a search.

### 3.3 `load/2` — building the allowlist for one entity type

```
@spec load(entity_type :: String.t(), prefix :: String.t()) ::
        {:ok, allowlist()}
        | {:error, :invalid_schema_name}
        | {:error, :entity_type_not_found}
```

Step order:

1. Validate `prefix` resolves to a provisioned tenant schema
   (`TenantProvisioning.tenant_id_for_schema_name/1`, the same guard
   `Letflow.Entities.Record.Latest.get/3`/`Record.Projector` already run,
   §0) — `{:error, :invalid_schema_name}` before any query.
2. `Letflow.Entities.Definitions.get_active_definition_by_name(entity_type,
   prefix)` (§0). `{:error, :not_found}` from that call is remapped to
   `{:error, :entity_type_not_found}` here — this design's own error atom,
   distinct from `Definitions`'s generic `:not_found`, so a caller of
   `Allowlist.load/2` never has to guess whether a bare `:not_found` meant
   "no active definition for this entity type" specifically (AC2's
   "plausible-looking but non-existent field" scenario is about a field
   name, not an entity type, but an entity-type-level not-found is the
   same shape of rejection-before-compiler and gets its own atom for the
   same reason).
3. Decode `entity_definition.definition_json` into a
   `Letflow.Entities.Definition.t()` (already-validated JSON by
   construction — `Letflow.Entities.Definitions.create_definition/2`
   runs `Letflow.Entities.Definition.Validator.validate/1` before a
   definition is ever persisted, so this step performs no re-validation,
   only a plain `Map.get/2`-style read of `:fields`).
4. Build the **typed-column** entries first (§3.4 fixed table), then the
   **JSON-field** entries from `definition.fields |> Enum.filter(& &1.queried)`
   — only `queried: true` fields are ever allowlisted (a field the
   entity-definition author did not mark `queried: true` is invisible to
   this query DSL entirely, matching `Definition.Validator`'s own
   `index_field_coverage_violations/1` precedent that a field must be
   `queried: true` before anything indexes/queries it, §0). `:json`-typed
   fields are structurally excluded without a special case, since
   `Definition.Validator`'s Rule 3 (§0) already forbids `queried: true` on
   a `:json` field at definition-creation time — no `:json` field can ever
   reach this filter with `queried: true` set.
5. Merge: for each JSON-field entry, if its `name` collides with a
   typed-column entry already in the map, **discard the JSON-field entry** —
   the typed-column entry wins and is the only one kept under that name
   (§3.4). No entity-definition field is ever silently dropped from the
   allowlist entirely by this merge — a colliding field's JSON data still
   exists in `field_values` and is still returned in a result row's payload
   (that is REQ-231's row-shaping concern, not this design's); this merge
   only decides which storage location a **query by that name** resolves
   against.
6. Return `{:ok, allowlist}`.

### 3.4 The shadowing-precedence rule — AC3, stated explicitly

**Rule: a field name backed by a real typed column on `entity_record_latest`
takes precedence over the same name found only as a JSONB key inside
`field_values`. A caller writing `field: "deleted"` (say) always resolves to
the typed `entity_record_latest.deleted` boolean column, never to a
same-named key an entity definition happens to declare inside its
`field_values` JSON, even if that entity type's definition includes a
`queried: true` field literally named `"deleted"`.**

This is the literal statement §3.3 step 5's merge implements, and per AC3 is
restated verbatim in `Letflow.Entities.Query.Allowlist`'s own moduledoc, not
left implicit in the merge code alone.

**The fixed typed-column table** (§3.3 step 4's first pass — every entry
present on **every** entity type's allowlist, since these columns exist on
`entity_record_latest` regardless of entity type):

| Name | `field_type()` | Notes |
|---|---|---|
| `"entity_type"` | `:string` | Filterable/sortable, though a query is already scoped to one `entity_type` by `query_request().entity_type` (§2.2) — included for completeness/symmetry, not because a caller commonly needs to re-filter on it. |
| `"record_id"` | `:string` | Compiled as a UUID-typed column comparison (§5.3), not JSONB. |
| `"deleted"` | `:boolean` | |
| `"entity_def_version"` | `:string` | Compared as its hex-string wire representation (matching `Letflow.Entities.Records`'s own encode convention, `Record.Projector` design §0) — never decoded to raw binary for comparison, avoiding a second decode convention. |
| `"last_event_global_seq"` | `:integer` | |
| `"inserted_at"` | `:datetime` | |
| `"updated_at"` | `:datetime` | |

**Justification for typed-column-wins (not an arbitrary pick):** (a) a typed
column is indexed/typed at the Postgres level and a comparison against it is
cheaper and more precise than a JSONB text-cast comparison against a
same-named key would be — there is no scenario where resolving to the JSONB
key instead would be *more* correct, only ambiguous; (b) the typed columns
are structural to every entity record regardless of entity type (§3.3's
table is entity-type-independent), while a JSON field of the same name is
merely one particular tenant's definition choice — the structural, always-
present meaning is the more stable one to bind a shared name to; (c) it
matches this codebase's existing precedent of a fixed/structural shape
overriding a same-named dynamic/tenant-authored one wherever the two could
collide (e.g. `EntityDefinition.status`'s own denormalised-but-authoritative
relationship to `Repository.Activation.resolve/3`, §0, is a different
mechanism but the same "a fixed platform-level concept wins over a
tenant-authored same-named artifact" shape). This is a design decision
this artefact makes and states, not one inherited unstated from R-Co (whose
`allowlist.zig` was unreachable, §0).

### 3.5 `resolve_field/2` — used by the compiler, not the allowlist loader's own caller

```
@spec resolve_field(allowlist(), field_name :: String.t()) ::
        {:ok, allowlisted_field()} | {:error, {:field_not_allowed, String.t()}}
```

A single `Map.fetch/2` against the loaded `allowlist()`, remapped to
`{:error, {:field_not_allowed, field_name}}` on miss. This is the function
§5's compiler calls once per `filter_clause()`/`sort_clause()` field (AC2) —
`Allowlist.load/2` builds the map once per `compile/2` call; `resolve_field/2`
is the cheap per-clause lookup against it, kept as a separate function so
the compiler's own per-clause loop (§5.4) has one clearly-named rejection
point per clause rather than inlining a `Map.fetch/2` at each call site.

## 4. Request-level validation — layer 1 and the field/value arity check

### 4.1 Layer 1: closed-enum parsing (`Types`)

```
@spec parse_filter_op(raw :: String.t()) :: {:ok, filter_op()} | {:error, {:unknown_operator, String.t()}}
@spec parse_sort_dir(raw :: String.t()) :: {:ok, sort_dir()} | {:error, {:unknown_sort_dir, String.t()}}
```

Each is a plain, exhaustive case match against §2.1's two tables (`"eq" ->
{:ok, :eq}`, …, `_ -> {:error, {:unknown_operator, raw}}`). **This is the
entire first defence layer**: no operator string ever reaches §3
(allowlist) or §5 (compiler) without first passing through one of these two
functions and coming back `{:ok, _}`. AC1's "a specific error identifying
the unrecognised operator" is `{:unknown_operator, raw}`'s own `raw` field —
the caller's exact unrecognised string, not a generic "invalid request"
error.

Whether a future router (deferred, §1) accepts operators as raw strings
(`"eq"`) and calls `parse_filter_op/1` itself before constructing a
`query_request()`, or is handed an already-`{:ok, filter_op()}` value by
some earlier deserialisation step, is that router's own concern (unbuilt) —
this design specifies `parse_filter_op/1`/`parse_sort_dir/1` as the two
functions that *must* sit on that boundary, wherever it ends up, so no
future router can bypass them.

### 4.2 Layer-1½: operator/value and operator/field-type arity checks (`Compiler`, pre-allowlist)

Two checks independent of the allowlist (so they run identically regardless
of what `resolve_field/2` would return, and are checked before it):

```
@spec check_value_arity(filter_op(), value_present? :: boolean()) ::
        :ok | {:error, {:value_arity_mismatch, filter_op()}}
```

`:is_null`/`:is_not_null` require **no** `:value` key; every other operator
in §2.1's table requires exactly one. `:in`/`:not_in` additionally require
that `:value`, when present, be a **list** (`{:error, {:invalid_in_value,
field}}` if not a list — checked in the same pass, §5.4).

### 4.3 Field-type compatibility (`Compiler`, post-allowlist, pre-fragment-selection)

```
@spec check_operator_field_type(filter_op(), Letflow.Entities.Definition.field_type()) ::
        :ok | {:error, {:operator_not_valid_for_type, filter_op(), Letflow.Entities.Definition.field_type()}}
```

Enforces §2.1's "valid `field_type()`s" column (e.g. `:contains` against a
`:boolean`-typed field is rejected here, not silently coerced or passed to
Postgres to error on). This check needs the resolved field's `type` (§3.2),
so it necessarily runs *after* `resolve_field/2` succeeds, unlike §4.2's
pure-operator checks.

## 5. `compiler.zig`-equivalent — parameterised SQL compilation

### 5.1 `compile/2` — top-level entry point

```
@spec compile(query_request(), prefix :: String.t()) ::
        {:ok, Ecto.Query.t()}
        | {:error, :invalid_schema_name}
        | {:error, :entity_type_not_found}
        | {:error, {:unknown_operator, String.t()}}
        | {:error, {:unknown_sort_dir, String.t()}}
        | {:error, {:field_not_allowed, String.t()}}
        | {:error, {:value_arity_mismatch, filter_op()}}
        | {:error, {:invalid_in_value, String.t()}}
        | {:error, {:operator_not_valid_for_type, filter_op(), Letflow.Entities.Definition.field_type()}}
```

Returns a **not-yet-executed** `Ecto.Query.t()` — `compile/2` never calls
`Repo.all/2` (or any `Repo.*` function) itself, matching `Record.Projector`'s
own read-only-until-the-caller-decides posture (§0) and keeping this module
free of any `prefix:`-option execution detail; the caller (the deferred
router, or a test) executes the returned query with `Repo.all(query, prefix:
prefix)` itself, same as every other tenant-scoped query in this subsystem
(§0's `Record.Latest.get/3` idiom, restated).

Step order — this is the three-layer defence in its actual call sequence,
each step's failure short-circuiting the rest via `with`:

1. `Allowlist.load(request.entity_type, prefix)` (§3.3) →
   `{:error, :invalid_schema_name}` / `{:error, :entity_type_not_found}` /
   `{:ok, allowlist}`.
2. For each `filter_clause()` in `request.filters` (already `[]` if
   absent, §2.2), independently, in order:
   a. `check_value_arity/2` (§4.2).
   b. `Allowlist.resolve_field(allowlist, clause.field)` (§3.5) →
      `{:error, {:field_not_allowed, clause.field}}` on miss (AC2).
   c. `check_operator_field_type/2` (§4.3) against the resolved field's
      `type`.
   d. `build_filter_dynamic/2` (§5.4) — produces one `Ecto.Query.dynamic/2`
      fragment for this clause.
3. Combine every clause's `dynamic/2` fragment with `Ecto.Query.dynamic/2`'s
   own `and` composition (`Enum.reduce(clauses, true, fn c, acc -> dynamic([r], ^acc and ^c) end)`
   — implicit AND across all filter clauses, no OR/grouping in this design's
   scope; a future requirement adding boolean grouping is out of scope here
   and not silently assumed).
4. For each `sort_clause()` in `request.sort` (already `[]` if absent):
   a. `parse_sort_dir/1` already ran at request-construction time (§4.1) —
      `sort_clause().dir` is already a `sort_dir()` by §2.2's type, not a
      raw string, so no further parsing happens here.
   b. `Allowlist.resolve_field(allowlist, clause.field)` (§3.5) — same
      rejection as step 2b.
   c. `build_order_by/2` (§5.5) — produces one `{dir, dynamic}` order-by
      term.
5. Assemble the final `Ecto.Query.t()`: base query
   `from(r in Letflow.Entities.Record.Latest, where: r.entity_type ==
   ^request.entity_type)`, `where: ^combined_dynamic` from step 3 appended,
   `order_by: [...]` from step 4 appended (empty list is a no-op — no
   `ORDER BY` clause added when `request.sort` was empty; ordering
   stability for pagination in that case is REQ-231's own cursor-codec
   concern, not this design's).
6. Return `{:ok, query}`.

Note step 5's base `where: r.entity_type == ^request.entity_type` uses
`^request.entity_type` as an ordinary bound Ecto value — a plain
`Ecto.Query` `where` on a typed string column needs no `fragment/1` at all;
`fragment/1` is needed only for JSONB key access (§5.2), never for typed
columns (§5.3).

### 5.2 The fragment-literal discipline — AC4's core mechanism

**The constraint (§0, restated precisely): `fragment/1`'s first argument
must be a compile-time-literal binary. This design never attempts to build
that literal string at runtime — not via string interpolation, not via a
helper function pinned with `^`, not via `Kernel.<>/2` — because Ecto's own
compiler rejects exactly that (`Ecto.Query.CompileError`, §0).**

Instead, `build_filter_dynamic/2` is written as a **pattern-matched
function with one clause per `{filter_op(), field_source(), field_type()}`
combination that needs JSONB access**, each clause containing its own
distinct `fragment/1` call whose literal string is fixed at compile time —
chosen by which clause matches at runtime, never assembled at runtime. This
is the same technique `lib/letflow/definitions.ex`'s `select_with_rank/3`/
`order_by_rank/3` already use for their shared `@rank_case_sql` literal
(§0): the *choice* of which literal applies is a runtime decision (which
clause pattern-matches), but each candidate literal itself is a `@doc
false`-invisible, syntactically distinct string written directly into the
source, never computed.

**Per-`field_type()` JSONB access shape** (the compile-time-literal fragment
text `build_filter_dynamic/2` selects among, one module attribute per
row, following `@rank_case_sql`'s own module-attribute-for-a-shared-literal
precedent, §0):

| `field_type()` | Fragment literal (conceptual SQL shape) | Cast applied |
|---|---|---|
| `:string` / `:enum` | `?->>?` | none — compared as text |
| `:integer` | `(?->>?)::bigint` | cast to `bigint` |
| `:decimal` | `(?->>?)::numeric` | cast to `numeric` |
| `:boolean` | `(?->>?)::boolean` | cast to `boolean` |
| `:date` | `(?->>?)::date` | cast to `date` |
| `:datetime` | `(?->>?)::timestamp` | cast to `timestamp` |

Each `?` is an ordinary `fragment/1` positional placeholder, bound (in
order) to `r.field_values` (the JSONB column, an `Ecto.Query` binding
reference, not caller data) and `^field_name` (the **allowlisted** field
name string, resolved by §3.5 — already proven to be one of the finite
names `Allowlist.load/2` enumerated for this entity type, never an arbitrary
caller string at this point). Both are bound as genuine Postgres query
parameters via Ecto's own placeholder mechanism — **the field name is a
bound parameter here too, not spliced into the fragment text**, which is
strictly stronger than REQ-230's own AC4 wording requires (AC4 names the
comparison *value*; this design also parameterises the *key name*, closing
a second, related injection surface — a JSONB key containing `'` or `?`-like
characters — for free, at zero extra cost, since Ecto's `->>` operator
accepts its key operand as an ordinary parameter).

The **comparison value** itself (`clause.value`) is a further, separate
`^`-bound parameter appended after the cast, e.g. conceptually
`fragment("(?->>?)::numeric", r.field_values, ^field_name) > ^value` for
`{:gt, :json_field, :decimal}` — never string-interpolated, never
concatenated into any fragment literal, satisfying AC4 directly: a value
containing `'; DROP TABLE …; --` is bound as one opaque parameter to
Postgres's own numeric (or text, or boolean, …) input path, never parsed as
SQL syntax, regardless of its content.

**Typed-column filters (§5.3) need no `fragment/1` at all** — `field(r,
^column_atom)` (where `column_atom` comes from a fixed, closed
`String.t() -> atom()` table §5.3 defines, never `String.to_atom/1` on
caller input) composes directly with `Ecto.Query.dynamic/2`'s own
operators (`==`, `>`, `<`, `in`, `is_nil`, `ilike`), which Ecto itself
already parameterises without any fragment involved.

### 5.3 Typed-column compilation table

For a `resolve_field/2` result with `source: :typed_column`, the field name
maps to a fixed schema-field atom via this closed table (never a dynamic
`String.to_atom/1`):

| Allowlisted name | Schema field atom |
|---|---|
| `"entity_type"` | `:entity_type` |
| `"record_id"` | `:record_id` |
| `"deleted"` | `:deleted` |
| `"entity_def_version"` | `:entity_def_version` |
| `"last_event_global_seq"` | `:last_event_global_seq` |
| `"inserted_at"` | `:inserted_at` |
| `"updated_at"` | `:updated_at` |

`build_filter_dynamic/2`'s typed-column clauses compose `field(r,
^column_atom)` with the operator via ordinary `Ecto.Query.dynamic/2`
constructs — `:eq` → `field(r, ^col) == ^value`, `:in` → `field(r, ^col) in
^value`, `:contains`/`:starts_with` (only ever reached for `"entity_type"`
or `"entity_def_version"`, the only `:string`-typed entries in this table,
per §4.3's type check) → `ilike(field(r, ^col), ^pattern)` with `pattern`
built as `"%" <> value <> "%"` / `value <> "%"` — the same
`ilike`/pattern-concatenation idiom `lib/letflow/definitions.ex`'s
`where_name/2` already uses (§0), where the pattern string itself is still
passed as one bound `^pattern` value, not interpolated into query text.
`:is_null`/`:is_not_null` → `is_nil(field(r, ^col))` / `not is_nil(field(r,
^col))`.

### 5.4 `build_filter_dynamic/2` — signature

```
@spec build_filter_dynamic(filter_clause(), allowlisted_field()) ::
        {:ok, Ecto.Query.dynamic_expr()}
        | {:error, {:value_arity_mismatch, filter_op()}}
        | {:error, {:invalid_in_value, String.t()}}
        | {:error, {:operator_not_valid_for_type, filter_op(), Letflow.Entities.Definition.field_type()}}
```

Internally dispatches first on `allowlisted_field().source`
(`:typed_column` → §5.3's table, `:json_field` → §5.2's table), then on
`{filter_op(), field_type()}` within that branch — the full dispatch is
`source × op × type`, every combination enumerated in §2.1/§5.2/§5.3's
tables (no default/catch-all `dynamic/2` builder that could silently
assemble an unvetted shape for a combination this design did not think
through).

### 5.5 `build_order_by/2` — signature

```
@spec build_order_by(sort_clause(), allowlisted_field()) :: {sort_dir(), Ecto.Query.dynamic_expr()}
```

For `:typed_column`, `{dir, dynamic([r], field(r, ^column_atom))}`. For
`:json_field`, the same per-`field_type()` cast table as §5.2 (a sort needs
the same type cast a comparison does, so a numeric field sorts numerically
rather than lexicographically as text) — no separate table, §5.2's fragment
literals are reused verbatim for the sort case, just without a trailing
comparison operator/value.

## 6. Error taxonomy — full closed set, none silently mapped to a generic 400

| Error | Layer | Meaning |
|---|---|---|
| `{:error, :invalid_schema_name}` | 0 (tenant) | `prefix` does not resolve to a provisioned tenant schema. |
| `{:error, :entity_type_not_found}` | 0 (allowlist) | No active `entity_definitions` row for `request.entity_type`. |
| `{:error, {:unknown_operator, raw}}` | 1 (types) | AC1 — `raw` string outside §2.1's closed set. |
| `{:error, {:unknown_sort_dir, raw}}` | 1 (types) | Same, for a sort direction. |
| `{:error, {:field_not_allowed, field}}` | 2 (allowlist) | AC2 — `field` absent from the loaded allowlist. |
| `{:error, {:value_arity_mismatch, op}}` | 1½ (compiler, pre-allowlist) | A value present where the operator forbids one, or absent where required. |
| `{:error, {:invalid_in_value, field}}` | 1½ | `:in`/`:not_in`'s value was not a list. |
| `{:error, {:operator_not_valid_for_type, op, type}}` | 3 (compiler, post-allowlist) | e.g. `:contains` against a `:boolean` field. |

Every one of these is returned as a typed tuple, never raised (INV-8, §0) —
`compile/2`'s `with` chain (§5.1) short-circuits to the first failing step's
own error tuple, and no step in this design calls a function that can raise
on realistically-malformed caller input (`Map.fetch/2`/`case`/pattern match
throughout, no bang functions on caller-supplied data).

## 7. Security-invariant compliance (INV-6 — stated explicitly)

- **INV-1 (tenant data isolation).** Every allowlist/compile call takes an
  explicit `prefix :: String.t()` (§3.3, §5.1) and every underlying query
  runs against that tenant's own Postgres schema — no cross-tenant read is
  structurally possible, matching every other tenant-scoped module in this
  subsystem (§0). `query_request()` (§2.2) carries no `tenant_id`/`prefix`
  field of its own — tenant scoping is exclusively the caller's own
  resolved request context, never decoded from caller-supplied request
  content, mirroring `Letflow.Api.Pagination.Cursor`'s own structural
  INV-1 guarantee (§0).
- **INV-6 (new data-access path proves its scoping).** This section is that
  proof, produced at design time per INV-6's own requirement that a new
  data-access path's SECURITY-REVIEWER handoff state which invariants apply
  and how — §7 as a whole is written to be quotable directly into that
  handoff.
- **INV-7 (no SQL string interpolation).** §5.2/§5.3 in full: every
  `fragment/1` call's literal text is a compile-time-fixed string chosen
  from a small closed table (§5.2), never built via interpolation or
  concatenation of caller data; every value that varies per call (JSONB key
  name, comparison value, typed-column value) is a `^`-bound Ecto
  parameter. No `Repo.query/2`/`Repo.query!/2` (raw SQL) appears anywhere in
  this design — `compile/2` returns a composed `Ecto.Query.t()` exclusively.
- **INV-8 (no unhandled crashes).** §6's full closed error taxonomy, all
  typed tuples, no raised exceptions on malformed caller input (restated
  from §6).
- **INV-2 (server-side field authorisation)** is explicitly **not**
  addressed by this design — REQ-230's own scope excludes field-grant
  redaction (REQ-231's job, §0's ISS-0438-scoping citation). This design's
  allowlist (§3) governs which fields a query may **filter/sort by**, not
  which fields a **result row** may expose; the latter is a separate,
  not-yet-built concern this design does not silently assume is covered.

## 8. Confirmed non-goals (scope boundary, AC6)

- **No cursor pagination.** `compile/2` returns an unpaginated `Ecto.Query.t()`
  with no `LIMIT`/keyset `WHERE` clause of its own — REQ-231's cursor codec
  (matching REQ-067's contract, §0) composes with this design's output by
  appending its own keyset `where`/`limit`/`order_by` terms onto the query
  `compile/2` returns, the same way `lib/letflow/definitions.ex`'s
  `filter_by_search_cursor/4` composes onto `where_name/2`'s base query
  (§0) — not designed further here, left to REQ-231's own design.
- **No field-grant redaction.** §7's INV-2 note, restated: which fields a
  result row exposes to a given caller is untouched by this design.
- **No route, no controller, no Plug pipeline entry.** None of §3.1's three
  modules is a route or controller module — confirmed by `git diff --stat`
  showing no `lib/letflow_web/**` (or equivalent router/controller path)
  file touched by this requirement's implementation commits (AC6).

## 9. Open questions (stated explicitly, not silently resolved)

1. **§2.1's operator set is this design's own construction** (restated from
   §0) — if a later requirement surfaces an actual R-Co `QRY-01..05`
   definition (e.g. once a Windows-accessible host can read `types.zig`),
   this operator table should be reconciled against it explicitly rather
   than assumed to already match.
2. **`:in`/`:not_in` against a JSONB field** (§5.2's table has no dedicated
   "IN" fragment row) — this design's §5.4 dispatch handles `:in`/`:not_in`
   for `:json_field` sources by combining the same per-type cast fragment
   with Ecto's `in` operator on the cast expression (e.g. `fragment("(?->>?)::bigint",
   r.field_values, ^field_name) in ^values`), which is a straightforward
   extension of §5.2's existing cast table rather than a new literal shape —
   flagged here only because §5.2's table itself doesn't show it explicitly
   and ELIXIR-DEV should not have to infer the composition silently.
3. **Case sensitivity of `:eq`/`:neq` against `:string`/`:enum` JSONB
   fields.** §5.2's `?->>?` text comparison is case-sensitive by default
   (ordinary Postgres `=`/`<>` on `text`) — this design does not add a
   `lower()` normalisation the way `:contains`/`:starts_with`'s `ILIKE`
   does. Left as-is (case-sensitive equality) since REQ-230's acceptance
   criteria name no case-insensitivity requirement for equality, but noted
   as a candidate default to revisit if a later requirement asks for
   case-insensitive equality matching.

## 10. Traceability — acceptance criteria to design elements

| # | Acceptance criterion (abridged) | Design element |
|---|---|---|
| 1 | Operator outside the closed enum rejected before the compiler, with a specific error naming it | §2.1 (closed `filter_op()`/`sort_dir()`), §4.1 (`parse_filter_op/1`/`parse_sort_dir/1`), §6 (`{:unknown_operator, raw}`) |
| 2 | Plausible-but-nonexistent field name rejected before the compiler | §3.5 (`resolve_field/2`), §5.1 step 2b/4b, §6 (`{:field_not_allowed, field}`) |
| 3 | Typed-column-vs-JSONB-key shadowing precedence stated explicitly in the moduledoc | §3.4 (the rule and its justification); §3.3 step 5 (the merge implementing it); §3.1 note that this is restated verbatim in `Allowlist`'s moduledoc |
| 4 | Every caller-supplied filter VALUE bound positionally, demonstrated against a SQL-metacharacter payload | §5.2 (fragment-literal discipline, compile-time-fixed text + `^`-bound key/value parameters), §5.1 note on `^request.entity_type`, §7's INV-7 restatement |
| 5 | SECURITY-REVIEWER's hard gate applies | §7 (full INV-1/6/7/8 compliance statement, written to be quotable into that gate's handoff) |
| 6 | No route/controller added or modified | §8, third bullet |
| 7 | `mix test`/`mix compile --warnings-as-errors` pass with real output | Implementation-phase verification — ELIXIR-DEV/TEST-RUNNER's job, not a design-time artefact |
