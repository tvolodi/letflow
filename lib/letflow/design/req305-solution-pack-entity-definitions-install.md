# REQ-305 design — SolutionPack `entity_definitions` install

Builds the install-only half of
`docs/migration/decisions/0026-solution-pack-entity-definitions-section.md`
("0026" below) and its companion design doc,
`lib/letflow/design/req303-solution-pack-entity-definitions.md` ("REQ-303's
doc" below). REQ-304's already-landed export side
(`lib/letflow/design/req304-solution-pack-entity-definitions-export.md`,
"REQ-304's doc" below) is read here only to confirm the exact
`packed_entity_definition` field shape this install path must consume — this
doc does not restate REQ-304's export-side design and does not touch
`export/3`/`export/4`.

Signatures, type shapes, and prose behavioral contracts only — no function
bodies. ELIXIR-DEV builds against this doc.

Independence note (restated briefly, per 0026's own framing): this design is
unrelated to the 0023/REQ-295..302 entity-storage track. It never references
`Letflow.Entities.Records`, `Record.Projector`, promoted columns, or
`priv/repo/migrations/`.

## 0. Re-verification performed (current tree, branch
`feature/WF02-REQ305-20260910`, main at `6df8faaa`)

- `lib/letflow/definitions/solution_pack.ex` read in full (811 lines).
  Confirmed the **current, post-REQ-304** state — REQ-303's doc's and 0026's
  cited line numbers have drifted because REQ-304 already inserted the
  `packed_entity_definition` type, the `entity_definitions` key on
  `pack_document`, `export/4`, `pack_each_entity_definition/2`, and
  `pack_entity_definition/1`. Current, confirmed line numbers used throughout
  this doc:
  - `packed_entity_definition` `@type`: lines 187-194 (already landed by
    REQ-304, unchanged by this doc).
  - `pack_document` `@type`: lines 196-206 — **already has** the
    `entity_definitions: [packed_entity_definition()]` key (REQ-304). This
    doc does not touch it.
  - `install_result` `@type`: lines 217-225 — **no** `installed_entity_definitions`
    key yet. This doc adds it (§3.4).
  - `install_error` `@type`: lines 233-244 — **no** entity-definition-shaped
    clause yet. This doc adds one (§3.3).
  - `install/3` doc/spec/def: lines 321-380 (`def install/3` at 372-380).
  - `parse_document/1`: lines 479-500 — confirmed it fetches exactly three
    lists today (`definitions`, `variable_schemas`, `service_catalog_entries`
    via `fetch_list/2` at lines 483-485) and builds a `parsed` map with
    **no** `entity_definitions` key. This is the interim gap 0026 §1(c)/§4
    describes: a pack carrying a non-empty `entity_definitions` array
    installs today with that content silently unread. This doc closes it.
  - `fetch_string/2`: lines 504-509. `fetch_list/2`: lines 511-517 (default-
    missing-key-to-`[]`, confirmed unchanged — 0026 §1(b) ratifies this as
    the old-pack/new-installer compatibility stance, zero code change needed
    to this helper itself).
  - `fetch_object/2`: lines 550-555 (accepts any non-struct map, no
    key-by-key filtering — same helper this doc's `parse_entity_definition/1`
    reuses for `definition_json`).
  - `check_unsupported_sections/1`: lines 613-618 — confirmed the current
    single-clause precedent: `%{service_catalog_entries: []} -> :ok`, `_ ->
    {:error, :unsupported_pack_section}`. This doc extends it to a joint,
    two-key AND check (§3.2).
  - `run_install/5`: lines 671-689 — confirmed the `with`/`else` ->
    `Repo.rollback(reason)` shape this doc's new step plugs into unchanged.
  - `create_packed_definitions/3`: lines 720-743 — confirmed the
    `Enum.reduce_while`/halt-on-first-error/`Enum.reverse` shape this doc's
    `create_packed_entity_definitions/3` mirrors exactly.
  - `installed_definition_maps/1`: lines 786-795 — confirmed the shape
    `installed_entity_definition_maps/1` (§3.4) mirrors.
  - `alias`es (lines 155-164): `Letflow.Definitions` is aliased as
    `Definitions` (the **process**-definition context module).
    `Letflow.Entities.Definitions` (the **entity**-definition context module
    this requirement calls) is **not** aliased — `pack_each_entity_definition/2`
    (REQ-304, line 434) already calls it fully-qualified:
    `Letflow.Entities.Definitions.get_definition_by_name(name, prefix(opts))`.
    **This doc's new install-side call must follow the same fully-qualified
    convention** (`Letflow.Entities.Definitions.create_definition/2`, never
    aliased) — aliasing it as `Definitions` would collide with the existing
    `Letflow.Definitions` alias and either fail to compile (redefinition) or
    silently shadow the wrong module.
- `lib/letflow/entities/definitions.ex` read in full (456 lines). Confirmed
  current signatures (both unchanged from 0026's own re-verification):
  - `create_definition/2` (lines 104-141): `@spec create_definition(create_attrs(), prefix :: String.t()) :: {:ok, EntityDefinition.t()} | create_error()`.
    Step 1 (line 108) calls `Letflow.Entities.Definition.Validator.validate/1`
    on `create_attrs.definition` **before any query** — a validation failure
    returns `{:error, {:validation, violations}}` with zero DB writes for
    *this* call. Step 4 (`insert_entity_definition/6`, lines 143-169) hard-codes
    `status: :inactive` (line 159) — confirmed, matching 0026 §2's
    `:inactive`-only stance exactly, no code change needed there.
  - `create_error/0` (lines 68-72): `{:error, {:validation, [Validator.violation()]}} | {:error, {:repository, term()}} | {:error, {:persistence, Ecto.Changeset.t()}} | {:error, :invalid_schema_name}`.
    The name/shape-version collision case (0026 §2) is the third clause,
    `{:error, {:persistence, changeset}}`, confirmed by
    `insert_entity_definition/6`'s own `case` (lines 165-168): a UNIQUE
    violation on `entity_definitions_tenant_name_shape_idx` surfaces here.
  - `activate_definition/4` (lines 393-425): confirmed unrelated, distinct,
    name-keyed call. **Not invoked anywhere by this design** (0026 §2:
    install is `:inactive`-only).
  - `create_attrs/0` (lines 63-66): `%{required(:definition) => Definition.t(), required(:created_by) => Ecto.UUID.t()}`.
- `lib/letflow/entities/definition.ex` read in full (the `Definition.t()`
  document shape, REQ-225). Confirmed `t/0` (lines 22-31) requires
  `:name`, `:display_name`, `:fields` and accepts `:description`,
  `:indexes`, `:foreign_keys`, `:constraints` — **all keys are atoms**, and
  `field_def/0` (lines 33-45), `index_def/0`, `fk_def/0`, `constraint_def/0`
  are likewise atom-keyed maps whose `:type`/`:search_strategy` values are
  themselves atoms drawn from closed sets (`field_type/0`, lines 57-66:
  9 atoms; `Validator`'s `search_strategy` values `:plain | :fulltext`).
- `lib/letflow/entities/definition/validator.ex` read in full (259 lines).
  Confirmed `malformed_violations/1`'s precondition checks
  (`check_required_string/3`, lines 128-134) call `Map.fetch(definition, key)`
  with an **atom** `key` (e.g. `:name`, line 108) — a map with the same
  content under **string** keys fails this check with `{:error, [%Violation{rule: :malformed, ...}]}`,
  not a look-alike success. `field_shape_violations/1` (lines 178-193)
  likewise requires `Map.get(field, :type)` to already be one of the 9
  `field_type()` **atoms** (line 186: `Map.get(field, :type) not in
  @field_types`) — a string value never matches.
- `lib/letflow/entities/entity_definition.ex` (the `Ecto.Schema`): confirmed
  `field(:definition_json, :map)` — Ecto's `:map` type is a bare
  Postgres JSONB round-trip with **no atomization on read**: a row fetched
  via `get_definition_by_name/2` (as `pack_entity_definition/1`, REQ-304,
  already does for export) yields `entity_definition.definition_json` as a
  **string-keyed** map, regardless of what key type was used to *insert* it.
  **This is the gap this doc's §3.1 closes** — see the callout there; it is
  new information neither 0026 nor REQ-303's doc addressed, found during this
  requirement's own mandated re-verification, not assumed from either
  document.
- `docs/migration/decisions/0026-*.md` and
  `lib/letflow/design/req303-solution-pack-entity-definitions.md` read in
  full (already summarized above; this doc does not repeat their reasoning,
  only cites the concrete answers it builds against): §1 (schema versioning:
  no version bump; `fetch_list/2`'s default ratified; new-pack/old-installer
  handled by extending `parse_document/1` so `check_unsupported_sections/1`
  has something to reject), §2 (install semantics: `:inactive`-only, no
  `activate_definition/4` call; collision aborts the whole transaction, keyed
  on `(tenant_id, name, logical_shape_version)`), §4 (parse+reject extension
  assigned to REQ-305, done first, before create-path logic), §5 (INV-1: no
  new caller-supplied tenant identifier).

## 1. Scope fence (restated, enforced by this design)

This design specifies changes to `lib/letflow/definitions/solution_pack.ex`
**only** — its `install/3`-reachable private helpers
(`parse_document/1`, `check_unsupported_sections/1`, `run_install/5`, and new
private helpers). It calls, but never modifies:

- `Letflow.Entities.Definitions.create_definition/2` (fully-qualified, per
  §0's alias note).
- `Letflow.Entities.Definition.t()` (the document shape it constructs a
  conformant value of, per §3.1).

It does not touch `Letflow.Entities.Definitions`, `Letflow.Entities.EntityDefinition`,
any file under `lib/letflow/entities/`, `export/3`/`export/4`, or any
migration.

## 2. Parse extension (0026 §1(c)/§4 — done first, before the create step)

### 2.1 `parse_document/1` — one more `fetch_list/2` + one more parse call

`parse_document/1`'s `with` chain (`solution_pack.ex:480-499`) gains, after
the existing clause that fetches `raw_catalog` via `fetch_list(document,
"service_catalog_entries")` and before the clause that parses `definitions`
via `parse_definitions(raw_definitions)`, one more binding step: fetch
`raw_entity_definitions` from `fetch_list(document, "entity_definitions")`,
following the same fetch-then-bind shape as the existing `raw_catalog` step.

Alongside the existing steps that produce `definitions` via
`parse_definitions(raw_definitions)` and `variable_schemas` via
`parse_variable_schemas(raw_variable_schemas)`, the chain gains a matching
step that produces `entity_definitions` by calling
`parse_entity_definitions(raw_entity_definitions)`.

The returned `parsed` map (currently built at lines 490-498) gains one more
key, `entity_definitions`, bound to the `entity_definitions` value the chain
above produced — mirroring how the existing map already carries
`definitions` and `variable_schemas` under their own same-named keys.

`fetch_list(document, "entity_definitions")` inherits `fetch_list/2`'s
existing default-missing-key-to-`[]` behavior with **zero change to
`fetch_list/2` itself** — an old pack (no `entity_definitions` key) parses
to `raw_entity_definitions == []`, which `parse_entity_definitions([])`
trivially resolves to `{:ok, []}` (per §2.2's `Enum.reduce_while` shape),
exactly mirroring 0026 §1(b).

### 2.2 New parse helpers — `parse_entity_definitions/1`, `parse_entity_definition/1`

Mirror `parse_definitions/1` (lines 519-530) / `parse_definition/1`
(lines 532-546) exactly in control-flow shape:

```
@spec parse_entity_definitions([term()]) ::
        {:ok, [parsed_packed_entity_definition()]} | {:error, :invalid_pack_document}
```

`Enum.reduce_while` over the raw list, `{:cont, {:ok, [entry | acc]}}` on
each `parse_entity_definition/1` success, `{:halt, error}` on the first
failure, `Enum.reverse` the accumulator on overall success — identical
shape to `parse_definitions/1`.

```
@spec parse_entity_definition(term()) ::
        {:ok, parsed_packed_entity_definition()} | {:error, :invalid_pack_document}
```

where (private, undeclared-outside-module type — matches
`parse_definition/1`'s own undeclared-return-shape precedent):

```
# parsed_packed_entity_definition() ::
#   %{
#     entity_definition_id: String.t(),
#     name: String.t(),
#     display_name: String.t(),
#     definition_json: Letflow.Entities.Definition.t(),
#     logical_shape_version: String.t()
#   }
```

Note `definition_json`'s type here is `Letflow.Entities.Definition.t()` —
**atom-keyed**, the conformant document shape, not a bare `map()` — this is
this doc's one departure from REQ-303's doc's `definition_json: map()`
phrasing for the internal parsed shape (REQ-303's doc's `packed_entity_definition/0`
pack-document type, `solution_pack.ex:187-194`, correctly keeps
`definition_json: map()` for the wire/JSON-decoded shape — that type is
unchanged, already landed by REQ-304, and this doc does not touch it; only
the *internal, parsed* shape this doc introduces is atom-keyed, precisely
because it must satisfy `create_definition/2`'s `create_attrs().definition`
requirement, per §3.1 below).

`parse_entity_definition/1` (only accepting `raw` when `is_map(raw) and not
is_struct(raw)`, same guard `parse_definition/1` and `parse_variable_schema/1`
use, with a catch-all `{:error, :invalid_pack_document}` clause for anything
else — same two-clause defensive shape as both):

1. `fetch_string(raw, "entity_definition_id")`.
2. `fetch_string(raw, "name")`.
3. `fetch_string(raw, "display_name")`.
4. `fetch_string(raw, "logical_shape_version")`.
5. `fetch_object(raw, "definition_json")` — structural check only (is a
   non-struct map), same as `parse_definition/1`'s `fetch_object(raw,
   "graph")`.
6. **New step, this doc's own addition, §3.1**: `atomize_definition_json/1`
   on the map `fetch_object` returned — converts it from the string-keyed
   shape a JSON round-trip produces into the atom-keyed
   `Letflow.Entities.Definition.t()` shape `create_definition/2` requires,
   or fails with `{:error, :invalid_pack_document}`.

On all six succeeding, returns
`{:ok, %{entity_definition_id: ..., name: ..., display_name: ..., definition_json: atomized, logical_shape_version: ...}}`.
Any single step failing short-circuits the `with` (same `with`/no-`else`
shape `parse_definition/1` uses) to `{:error, :invalid_pack_document}` — this
satisfies AC3's "missing name, missing definition_json, or wrong type ...
rejected ... before any database write": `parse_document/1` is entirely a
pre-transaction step (§0's confirmation that steps 1-3 of `install/3`, which
include the full parse, issue zero queries), so any `parse_entity_definition/1`
failure aborts before `Repo.transaction/1` (`run_install/5`) is ever called.

### 2.3 New step, this doc's own finding — `atomize_definition_json/1`

**Design decision, found during this requirement's own re-verification (§0),
not present in 0026 or REQ-303's doc: `definition_json`, as it arrives in a
pack document (whether freshly built by REQ-304's `export/4`, which copies
`entity_definition.definition_json` verbatim off a DB row Ecto decoded with
string keys, or hand-authored JSON from any other source), is always a
string-keyed map by the time `parse_entity_definition/1` sees it — Elixir's
`Jason.decode/1` and Ecto's `:map`/JSONB column type never atomize.
`Letflow.Entities.Definition.Validator.validate/1` (called inside
`create_definition/2`, confirmed §0) requires atom keys (`Map.fetch(definition,
:name)`, not `"name"`) and atom-valued `:type`/`:search_strategy` fields
(`Map.get(field, :type) not in @field_types`, where `@field_types` is a list
of atoms). Left unaddressed, every install of every entity definition —
including the straightforward export-then-reinstall round-trip this feature
exists to support — would fail `Validator.validate/1`'s malformed-shape
precondition on `:name` alone, every time. This is a correctness gap this
design must close, not an open question to leave unresolved, because
leaving it unresolved would make the feature non-functional for its primary
use case.**

Resolution: a new private helper, called once by `parse_entity_definition/1`
(§2.2 step 6), converts the fetched `definition_json` map from string keys
to the exact atom-keyed shape `Letflow.Entities.Definition.t()` and its
nested `field_def()`/`index_def()`/`fk_def()`/`constraint_def()` types
require, via an **explicit whitelist translation**, never a dynamic
`String.to_existing_atom/1` over caller-supplied key text:

```
@spec atomize_definition_json(map()) ::
        {:ok, Letflow.Entities.Definition.t()} | {:error, :invalid_pack_document}
```

Behavioral contract (prose, mirrors the other `fetch_*` helpers' totality —
never raises):

- Top-level keys translated via a static `"name" => :name`, `"display_name"
  => :display_name`, `"description" => :description`, `"fields" => :fields`,
  `"indexes" => :indexes`, `"foreign_keys" => :foreign_keys`, `"constraints"
  => :constraints` table. Any key present in the input map that is **not**
  in this table is a rejection (`{:error, :invalid_pack_document}`) — per
  0026 §4's own principle applied here: an unrecognized field is refused
  explicitly, never silently dropped.
- Each entry of `fields` (if present) is itself translated key-by-key via a
  `field_def()`-scoped whitelist (`"name"`, `"type"`, `"required"`,
  `"queried"`, `"enum_values"`, `"decimal_precision"`, `"decimal_scale"`,
  `"default"`, `"locales"`, `"search_strategy"`), with the same
  reject-on-unrecognized-key rule. The `"type"` value is additionally
  translated from its JSON string form to one of the 9 `field_type()` atoms
  via a second static whitelist (`"string" => :string`, ...,
  `"localized_text" => :localized_text`); a `"type"` value outside that
  9-entry whitelist is a rejection. The `"search_strategy"` value, if
  present, is translated the same way against `{"plain" => :plain, "fulltext"
  => :fulltext}`; any other value is a rejection. Every other field value
  (`"name"`, `"required"`, `"enum_values"`, `"decimal_precision"`,
  `"decimal_scale"`, `"default"`, `"locales"`) is carried through unchanged —
  only *keys*, plus the two closed-set enum *values* named above, are ever
  translated; this helper does not otherwise interpret or validate content
  (deep structural rules 1-11 remain `Validator.validate/1`'s job, called
  later, inside the transaction, by `create_definition/2` itself — this
  helper's job is shape/key-type normalization only, not the 11 numbered
  rules).
- `indexes`, `foreign_keys`, `constraints` entries are translated the same
  way, each against its own small, closed key whitelist
  (`index_def()`: `"name"`, `"fields"`, `"unique"`; `fk_def()`: `"name"`,
  `"field"`, `"references_entity"`, `"references_field"`; `constraint_def()`:
  `"name"`, `"type"`, `"fields"`), with `constraint_def()`'s `"type"` value
  translated only when it is exactly `"unique"` (-> `:unique`; anything else
  is a rejection, matching `Validator`'s own `Map.get(constraint, :type) !=
  :unique` check, confirmed §0).
- Any of the above reaching a rejection at any nesting depth halts the whole
  `atomize_definition_json/1` call with `{:error, :invalid_pack_document}` —
  no partial/best-effort atomization is ever returned.

This is a pure, total function over its input (a decoded JSON value) — no
query, no side effect, callable entirely within `parse_document/1`'s
pre-transaction phase, preserving AC3's "zero queries for a malformed entry"
guarantee for every shape defect this helper can detect (missing/renamed/
mistyped key, or a `type`/`search_strategy`/constraint-`type` value outside
its closed set) — the narrower set of *semantic* rules (rules 1-11: name
format, duplicate names, cardinality limits, etc.) remains
`Validator.validate/1`'s job and is reached only once `create_definition/2`
is actually called, inside the transaction (§3.3).

## 3. Unsupported-section check — extended, not replaced (0026 §4)

Per 0026 §4 and REQ-303's doc §3.2, this extension must land **before** the
create-step (§3.3) is wired in, so REQ-305's own implementation sequence
avoids ever compiling/shipping an intermediate state that parses
`entity_definitions` but does not yet reject a non-empty one.

```
@spec check_unsupported_sections(parsed :: map()) :: :ok | {:error, :unsupported_pack_section}
```

Current clause (`solution_pack.ex:617-618`): the passing clause matches only
when `service_catalog_entries` is bound to the empty list; a fallback clause
matches anything else and returns `{:error, :unsupported_pack_section}`.

The passing clause's pattern gains a second key requirement,
`entity_definitions: []`, alongside the existing `service_catalog_entries:
[]` — both must be present and bound to the empty list for the clause to
match. The fallback clause is unchanged and needs no edit — it already
rejects anything the (now two-key) passing clause doesn't match.

This is a **joint AND** check, per REQ-303's doc §3.2's explicit behavioral
contract: `:ok` only when *both* keys are empty lists. A pack with a
populated `entity_definitions` and an empty `service_catalog_entries` (or
vice versa) still falls through to the catch-all
`{:error, :unsupported_pack_section}` clause — there is no way for either
section to "cover" the other's rejection. Because §2.1 always populates
`parsed.entity_definitions` (defaulting to `[]` for an old pack via
`fetch_list/2`), this pattern match never fails to find the key — an old
pack (pre-REQ-305 producer, or any pack omitting the key) parses to
`entity_definitions: []` and passes this check exactly as it does today.

## 4. Install step — new transactional function, `:inactive`-only, all-or-nothing (0026 §2)

### 4.1 `install_error/0` — new clause

Current (`solution_pack.ex:233-244`) already includes
`| Definitions.create_error()` where `Definitions` is the `Letflow.Definitions`
(process-definition) alias — that clause is unrelated to this doc's needs
and is left untouched. This doc adds one new, fully-qualified clause (per
§0's alias-collision note, `Letflow.Entities.Definitions.create_error()`
cannot be referenced via a bare `Definitions.` alias without colliding):

```
@type install_error ::
        {:error, :invalid_pack_document}
        | {:error, {:unknown_schema_version, actual :: String.t()}}
        | {:error, :unsupported_pack_section}
        | {:error,
           {:malformed_variable_schema, variable_key :: String.t(),
            reason :: :invalid_json | :not_a_string}}
        | {:error, Definitions.variable_schema_error()}
        | {:error, :duplicate_pack_install}
        | {:error, :missing_prefix}
        | Definitions.create_error()
        | Letflow.Entities.Definitions.create_error()
        | Definitions.common_error()
```

`Letflow.Entities.Definitions.create_error()` (confirmed §0: `{:error,
{:validation, [Validator.violation()]}} | {:error, {:repository, term()}} |
{:error, {:persistence, Ecto.Changeset.t()}} | {:error, :invalid_schema_name}`)
is folded in as its own union member rather than reusing
`Definitions.create_error()`'s clause — the two are distinct types on
distinct modules with only a superficial name overlap (process-definition
`create/2` errors vs. entity-definition `create_definition/2` errors); they
must not be conflated, and `install_error/0`'s existing member ordering
elsewhere in this union is not load-bearing, so appending it after
`Definitions.create_error()` (as shown) needs no other reordering.

### 4.2 New private helper — `create_packed_entity_definitions/3`

Mirrors `create_packed_definitions/3` (lines 720-743) exactly in
control-flow shape:

```
@spec create_packed_entity_definitions(
        packed_entity_definitions :: [parsed_packed_entity_definition()],
        actor_id :: Ecto.UUID.t(),
        opts :: Definitions.opts()
      ) :: {:ok, [{parsed_packed_entity_definition(), EntityDefinition.t()}]} | install_error()
```

For each packed entry, in order (`Enum.reduce_while`, same halt-on-first-error/
`Enum.reverse`-on-success shape as `create_packed_definitions/3`):

1. Builds a `create_attrs()` value (per `Letflow.Entities.Definitions`'
   own `@type create_attrs`, confirmed §0):
   `%{definition: packed.definition_json, created_by: actor_id}` — `packed.definition_json`
   is already the atom-keyed, `Definition.t()`-conformant map §2.3 produced;
   no further transformation happens here. `created_by` is the install's own
   `actor_id` parameter — the **same** `actor_id` `install/3` already
   threads into `create_packed_definitions/3` today (`solution_pack.ex:674`),
   not a new parameter.
2. Calls `Letflow.Entities.Definitions.create_definition(create_attrs,
   prefix(opts))` — fully-qualified (§0), reusing the module's own existing
   private `prefix(opts)` helper (line 384) to extract the raw string, the
   same call-shape correction REQ-304's doc §2.3 already established for
   `get_definition_by_name/2`. **This is the only tenant-scoping value
   passed** — no `tenant_id`, `schema_name`, or `slug` parameter appears
   anywhere in this helper's signature or body (INV-1, §6 below).
3. On `{:ok, %EntityDefinition{} = created}`: `{:cont, {:ok, [{packed,
   created} | acc]}}`.
4. On `{:error, reason}` (any `create_error()` member — validation failure,
   repository failure, or the persistence/UNIQUE-collision case, 0026 §2):
   `{:halt, {:error, reason}}`.

**No call to `Letflow.Entities.Definitions.activate_definition/4` appears
anywhere in this helper** — per 0026 §2, install is `:inactive`-only, and
`create_definition/2` already defaults every inserted row to `status:
:inactive` (confirmed §0) with no action needed here to achieve that.

### 4.3 Wiring into `run_install/5` (placement)

`run_install/5`'s transactional `with` chain (`solution_pack.ex:672-684`)
gains one more clause, between the existing clause that binds `installed` by
calling `create_packed_definitions(parsed.definitions, actor_id, opts)` and
the clause that binds `written`/`warnings` by calling
`register_packed_schemas(installed, decoded_schemas, opts)`. The new clause
binds `installed_entities` to the result of calling
`create_packed_entity_definitions(parsed.entity_definitions, actor_id,
opts)`, following the same success-tuple-binding shape as the existing
`installed` clause it sits next to.

Placement relative to `register_packed_schemas/3` is not load-bearing (per
REQ-303's doc §3.3: entity definitions and process-definition variable
schemas write disjoint tables with no FK between them) — placed immediately
after `create_packed_definitions` so the two "create the artefacts a pack
carries" steps read together before the schema-registration step. Any
`{:error, reason}` from this new clause flows into the **same** existing
`else {:error, reason} -> Repo.rollback(reason) end` fallback
(`solution_pack.ex:685-687`) the other clauses already share — **no new
`else`/rollback path is added**, and no existing clause's behavior changes.
This is what makes the all-or-nothing guarantee mechanical rather than
merely tested-for: a `create_packed_entity_definitions/3` failure rolls back
the `solution_pack_installs` row insert, every process definition already
created earlier in the same `with` chain, and (since it runs before
`register_packed_schemas/3`) prevents any variable-schema row from being
written at all for this install attempt — zero new rows across every
affected table, satisfying AC2.

### 4.4 `install_result/0` — new field, new type, new response-building step

```
@type installed_entity_definition :: %{
        source_entity_definition_id: String.t(),
        new_entity_definition_id: Ecto.UUID.t(),
        name: String.t(),
        status: String.t()
      }

@type install_result :: %{
        pack_id: String.t(),
        version: String.t(),
        install_id: Ecto.UUID.t(),
        installed_definitions: [installed_definition()],
        installed_entity_definitions: [installed_entity_definition()],
        variable_schemas_written: non_neg_integer(),
        role_mapping_checklist: [role_checklist_entry()],
        warnings: [String.t()]
      }
```

`status` here is always the literal string `"installed"` — mirrors
`installed_definition_maps/1`'s own `status: "installed"` (line 792), and is
a **distinct concept** from the newly-created row's own `status: :inactive`
DB column value (0026 §2's terminology note, restated): the install-result
field reports "was this artefact installed by this call" (always yes, for
every entry that reaches the result map — install is all-or-nothing, so a
partially-failed attempt never produces a result map at all), not the
entity definition's activation state.

New private helper, mirrors `installed_definition_maps/1` (lines 786-795)
exactly:

```
@spec installed_entity_definition_maps(
        [{parsed_packed_entity_definition(), EntityDefinition.t()}]
      ) :: [installed_entity_definition()]
```

Maps each `{packed, created}` pair to
`%{source_entity_definition_id: packed.entity_definition_id, new_entity_definition_id: created.id, name: created.name, status: "installed"}`.

`run_install/5`'s response map (`solution_pack.ex:676-684`) gains one more
key, `installed_entity_definitions`, bound to the result of calling
`installed_entity_definition_maps(installed_entities)` — built the same way
the existing `installed_definitions` key is already bound to the result of
calling `installed_definition_maps/1`.

## 5. Rollback / error taxonomy — summary table

| Failure point | When | Error | Queries issued before this point |
|---|---|---|---|
| `parse_entity_definition/1` (entry-level `fetch_string`/`fetch_object` miss) | Pre-transaction | `{:error, :invalid_pack_document}` | Zero (AC3) |
| `atomize_definition_json/1` (unrecognized key, or `type`/`search_strategy`/constraint-`type` value outside its closed set) | Pre-transaction | `{:error, :invalid_pack_document}` | Zero (AC3) |
| `check_unsupported_sections/1` (non-empty `entity_definitions` against a pack whose installer predates this requirement — N/A once this requirement lands, but the joint check itself) | Pre-transaction | `{:error, :unsupported_pack_section}` | Zero |
| `create_definition/2`'s own `Validator.validate/1` (rules 1-11, semantic — e.g. duplicate field names, bad cardinality) | Inside transaction, before that call's own `Repository.create/2` | `{:error, {:validation, violations}}` -> whole install rolls back | Zero for *this* entity definition's own artifact/entity_definitions rows; any earlier-in-the-loop process definitions/entity definitions from the SAME pack are rolled back too (AC2) |
| `create_definition/2`'s `Repository.create/2` failure | Inside transaction | `{:error, {:repository, reason}}` -> whole install rolls back | As above |
| `create_definition/2`'s UNIQUE-constraint hit on `(tenant_id, name, logical_shape_version)` (0026 §2 "name collision") | Inside transaction, after that entry's own `Repository.create/2` already ran | `{:error, {:persistence, changeset}}` -> whole install rolls back | As above — this is the case AC2 explicitly requires a real test to exercise: zero new rows across every affected table after the failed install |

Every "whole install rolls back" outcome above reaches `Repo.rollback/1`
through `run_install/5`'s single existing `with`/`else` clause — this doc
adds no second rollback path.

## 6. INV-1 tenant scoping — confirmed for this doc's own additions

- `parse_entity_definition/1` and `atomize_definition_json/1` (§2) take no
  tenant-scoped argument at all — they operate purely on the decoded
  document, the same as every existing parse helper in this module.
- `create_packed_entity_definitions/3` (§4.2) takes `opts :: Definitions.opts()`
  (the same `[prefix: String.t()]` shape every other step in this module
  already threads) and passes `prefix(opts)` — the existing private helper,
  unchanged — to `Letflow.Entities.Definitions.create_definition/2`. No
  `tenant_id`, `schema_name`, or `slug` parameter is introduced anywhere in
  this doc's new signatures.
- `Letflow.Entities.Definitions.create_definition/2` itself (confirmed §0,
  unmodified by this doc) derives `tenant_id` solely from that `prefix`
  string via `TenantProvisioning.tenant_id_for_schema_name/1` — the same
  mechanism `install/3`'s own `tenant_id` (used for the
  `solution_pack_installs` row) is already derived by, at line 377.
- The collision constraint `entity_definitions_tenant_name_shape_idx` is
  `(tenant_id, name, logical_shape_version)`-keyed with `tenant_id` leading
  (0026 §"SECURITY-REVIEWER sign-off" point 4, independently re-confirmed
  there against the actual migration) — a same-tenant-only collision surface,
  matching every other write this module makes.

## 7. Cross-module dependencies

- `Letflow.Entities.Definitions.create_definition/2` — called once per
  packed entity definition (§4.2). **Not modified.**
- `Letflow.Entities.Definition.t()` — the document shape
  `atomize_definition_json/1` (§2.3) produces a conformant value of.
  **Not modified.**
- `Letflow.Entities.Definition.Validator` — never called directly by this
  module; reached only indirectly, inside `create_definition/2`. **Not
  modified**, and this doc's §2.3 whitelist tables are derived from reading
  it, not from changing it.
- `Letflow.Entities.EntityDefinition` — read-only struct access (`.id`,
  `.name`) inside `installed_entity_definition_maps/1` (§4.4). **Not
  modified.**
- `Letflow.Definitions.opts/0` — reused unchanged as
  `create_packed_entity_definitions/3`'s `opts` parameter type.
- No new dependency on `Letflow.Entities.Records`, `Record.Projector`, or
  any file under `priv/repo/migrations/` (0023/REQ-295..302 independence,
  restated).

## 8. Acceptance-criteria mapping

| AC | Design element |
|---|---|
| 1 | §4.2 (`create_packed_entity_definitions/3` calling `create_definition/2` under `opts[:prefix]`), §4.4 (`installed_entity_definitions` in the returned `install_result`), §2 (no `activate_definition/4` call anywhere) |
| 2 | §4.3 (single shared `with`/`else` -> `Repo.rollback/1` path, no new rollback path), §5 (rollback table, name-collision row) |
| 3 | §2.2/§2.3 (`parse_entity_definition/1` + `atomize_definition_json/1`, both pure/pre-transaction, `{:error, :invalid_pack_document}` on any entry-level or shape defect, zero queries) |
| 4 | §2.1 (`fetch_list/2`'s existing default, zero code change to it), §3 (joint `check_unsupported_sections/1` still passes `entity_definitions: []` for an old pack) |
| 5 | §4.1 (`install_error/0`'s new `Letflow.Entities.Definitions.create_error()` member), §4.4 (`installed_entity_definition/0` type) — both plain `@type` declarations checkable by `mix compile --warnings-as-errors` |
| 6 (INV-1) | §6 — every new call site traced, no new tenant-identifying parameter anywhere |
| 7 (SECURITY-REVIEWER sign-off) | Not a design-doc element — flagged here as the gate this doc's §4.2 (collision abort) and §6 (INV-1) sections exist to be reviewed against once implemented |
| 8 | §1 (scope fence) — this doc specifies no change under `lib/letflow/entities/` |

## 9. What this design does not fix / open items

- **Route-layer wiring** (`lib/letflow/routers/solution_packs.ex`) for
  accepting a pack document containing `entity_definitions` — REQ-304's own
  scope fence left the route layer untouched for export; this doc similarly
  does not specify any route change for install. `install/3` already
  receives `document` as a raw decoded map regardless of which sections it
  carries, so no route change is structurally required for this doc's
  additions to take effect through the existing install endpoint — but
  ELIXIR-DEV should confirm the route does not itself filter/strip unknown
  top-level document keys before calling `install/3` (nothing in the
  re-verified `install/3` moduledoc suggests it does; this doc does not
  re-verify the route module itself, since the scope fence excludes it).
- **`Letflow.Entities.Definition.Validator`'s 11 semantic rules** are
  unaffected and unre-derived by this doc — a packed entity definition that
  passes §2.3's shape/key-type normalization but fails, say, rule 3 (a
  `:json` field marked `queried: true`) still surfaces as
  `{:error, {:validation, violations}}` from `create_definition/2`, inside
  the transaction, per §5's table — this is existing, correct
  `create_definition/2` behavior this doc does not change.
- **`atomize_definition_json/1`'s whitelist tables are exhaustive for the
  current `Letflow.Entities.Definition.t()` shape (REQ-225, extended by
  REQ-301's `:locales`/`:search_strategy` additions, confirmed present in
  `field_def/0` §0)** — if a future requirement adds a new field to
  `Definition.t()`, this helper's whitelist must be extended in the same
  change, or a pack carrying that new field's key installs successfully but
  silently drops it (this doc's own reject-on-unrecognized-key rule, §2.3,
  actually prevents the "silently drops" failure mode — a future field not
  yet in the whitelist would instead cause every install carrying it to be
  rejected with `{:error, :invalid_pack_document}` until the whitelist is
  updated, which is the safer failure direction but is called out here so a
  future REQ-225/301-successor requirement remembers to touch this file
  too).
