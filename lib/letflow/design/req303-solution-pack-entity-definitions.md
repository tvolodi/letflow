# REQ-303 design — SolutionPack `entity_definitions` section

Companion design doc to `docs/migration/decisions/0026-solution-pack-entity-definitions-section.md`
("0026" below) — read 0026 first; this doc only gives the concrete
signatures/types 0026's answers imply. Signatures and type shapes only, no
function bodies — REQ-304 (export) and REQ-305 (install) implement against
this doc.

Independence note (restated from 0026, briefly, so a reader of only this
file still sees it): this design is unrelated to the 0023/REQ-295..302
entity-storage track. It never references `Letflow.Entities.Records`,
`Record.Projector`, promoted columns, or `priv/repo/migrations/`.

## 1. `lib/letflow/definitions/solution_pack.ex` — new/changed types

```
@typedoc "One entity definition inside a pack document (0026 §Consequences)."
@type packed_entity_definition :: %{
        entity_definition_id: Ecto.UUID.t(),
        name: String.t(),
        display_name: String.t(),
        definition_json: map(),
        logical_shape_version: binary()
      }
```

`pack_document/0` gains one field, inserted after `variable_schemas` (order
is not load-bearing, but keeps every "list of packed X" key grouped):

```
@type pack_document :: %{
        pack_id: String.t(),
        version: String.t(),
        bpm_export_schema_version: String.t(),
        exported_at: String.t(),
        definitions: [packed_definition()],
        service_catalog_entries: [],
        variable_schemas: [packed_variable_schema()],
        entity_definitions: [packed_entity_definition()],
        manifest: %{required_roles: [String.t()]}
      }
```

The internal `parsed` map `parse_document/1` builds (private, no `@type`
today, but referenced by `install/3`'s `with` chain) gains a matching
`entity_definitions: [parsed_packed_entity_definition()]` key — see §3.

## 2. `export/3` — new arity, new parameter, new error case

0026 §1(a)/(b)/(c) fixes the version-string and compatibility behavior;
this section fixes the parameter and read shape REQ-304 builds.

```
@spec export(
        definition_ids :: [String.t()],
        version :: String.t() | nil,
        opts :: Definitions.opts()
      ) :: {:ok, pack_document()} | export_error()
```

stays as the base arity for backward compatibility (a caller naming zero
entity definitions must still work byte-for-byte, per REQ-304's own AC5).
REQ-304 adds a 4-arity sibling:

```
@spec export(
        definition_ids :: [String.t()],
        entity_definition_names :: [String.t()],
        version :: String.t() | nil,
        opts :: Definitions.opts()
      ) :: {:ok, pack_document()} | export_error()
```

`export/3` (the existing arity) delegates to `export/4` with
`entity_definition_names: []` — this keeps one implementation, not two
parallel pipelines, mirroring how `pack_each_definition/2` is already the
single shared helper for the `definitions` list.

`entity_definition_names :: [String.t()]` — each is a `name` value passed to
`Letflow.Entities.Definitions.get_definition_by_name/2` (NOT an
`entity_definition_id` — names are the stable, human-authored identifier a
pack author would reference; ids are per-tenant/per-install and would not
resolve across tenants the way a name-based lookup already does for process
definitions in `pack_each_definition/2`'s `Definitions.get_by_id/2` call —
note that one takes an id while this one takes a name, an intentional
divergence because `Letflow.Entities.Definitions` has no bare
`create_definition`-paired `get_by_id`-style export entry point today;
`get_definition_by_name/2` is the export-appropriate one, since it already
exists and is read-only).

```
@type export_error ::
        {:error, {:definition_not_found, definition_id :: String.t()}}
        | {:error, {:entity_definition_not_found, name :: String.t()}}
        | {:error, :empty_definition_ids}
        | Definitions.common_error()
```

`{:error, {:entity_definition_not_found, name}}` is the new error tuple for
a named entity definition that does not exist in the caller's tenant (0026
§Decision, INV-1: this is the cross-tenant case too — an id/name owned by
another tenant is invisible in this prefix, same reasoning
`pack_each_definition/2`'s moduledoc already states for process
definitions). This is a NEW tuple shape, distinct from
`{:definition_not_found, id}}` (which is keyed by id, for process
definitions) because entity definitions are named by `name`, not `id`, in
this export parameter — REQ-304 must not reuse the process-definition tuple
shape for an entity-definition miss.

New private helper (mirrors `pack_each_definition/2`):

```
@spec pack_each_entity_definition([String.t()], Definitions.opts()) ::
        {:ok, [EntityDefinition.t()]} | export_error()
```

reads each name via `Letflow.Entities.Definitions.get_definition_by_name/2`
under `opts[:prefix]`, in the order given (same "first offending name wins
the error" ordering `pack_each_definition/2` already uses), halting on
`{:error, :not_found}` -> `{:halt, {:error, {:entity_definition_not_found, name}}}`.

New private helper (mirrors `pack_definition/1`):

```
@spec pack_entity_definition(EntityDefinition.t()) :: packed_entity_definition()
```

hand-built key list (INV-2, matching `pack_definition/1`'s own
"never a `Jason.Encoder` derivation" discipline):
`entity_definition_id: entity_definition.id`,
`name: entity_definition.name`,
`display_name: entity_definition.display_name`,
`definition_json: entity_definition.definition_json`,
`logical_shape_version: entity_definition.logical_shape_version`.

`export/4`'s body builds `entity_definitions:
Enum.map(entity_definitions, &pack_entity_definition/1)` the same way
`definitions:` is built today, and an empty `entity_definition_names` list
produces `entity_definitions: []` — matching `service_catalog_entries`'s
own always-`[]`-when-absent shape, and matching REQ-304's AC5 (no
regression for a process-definitions-only export).

## 3. `install/3` — parse, unsupported-section check, create step

0026 §1(c)/§4 require `parse_document/1` and `check_unsupported_sections/1`
to be extended as ONE atomic step, done first within REQ-305 (before any
create-path logic), so no interim window silently drops tenant-supplied
`entity_definitions` content.

### 3.1 Parse

`parse_document/1`'s `with` chain gains one more `fetch_list/2` call,
alongside the existing three (`definitions`, `variable_schemas`,
`service_catalog_entries`): fetch the raw `"entity_definitions"` list the
same way (`fetch_list(document, "entity_definitions")`), then run it through
the new `parse_entity_definitions/1` helper (see below) exactly as
`raw_definitions` is run through `parse_definitions/1` today. The returned
map gains one more key, `entity_definitions:`, holding that parsed list.

New parse helpers (mirror `parse_definitions/1` / `parse_definition/1`):

```
@spec parse_entity_definitions([term()]) ::
        {:ok, [parsed_packed_entity_definition()]} | {:error, :invalid_pack_document}

@spec parse_entity_definition(term()) ::
        {:ok, parsed_packed_entity_definition()} | {:error, :invalid_pack_document}
```

where (private type, doc comment only, no `@type` needed outside the
module — matches how `parse_definition/1`'s return shape is undeclared
today):

```
# parsed_packed_entity_definition() ::
#   %{
#     entity_definition_id: String.t(),
#     name: String.t(),
#     display_name: String.t(),
#     definition_json: map(),
#     logical_shape_version: String.t()
#   }
```

`parse_entity_definition/1` requires (`fetch_string/2`) `entity_definition_id`,
`name`, `display_name`, `logical_shape_version`, and (`fetch_object/2`)
`definition_json` — same total/never-raise style as `parse_definition/1`,
`{:error, :invalid_pack_document}` on any missing/wrong-typed field.

### 3.2 Unsupported-section check — extended, not replaced

`check_unsupported_sections/1` gains an entity_definitions clause. Per 0026
§4, this landing (in REQ-305) happens BEFORE the create-step (§3.3 below) is
wired in — i.e. REQ-305's own implementation order should extend
parse+reject first, verify it rejects a non-empty `entity_definitions`
correctly, and only then add the create step, so there is no intermediate
commit within REQ-305 itself that parses `entity_definitions` but does not
yet reject or install it silently.

```
@spec check_unsupported_sections(parsed :: map()) :: :ok | {:error, :unsupported_pack_section}
```

Behavioral contract (prose, not literal clauses — REQ-305 implements
this): the function must return `:ok` only when BOTH
`service_catalog_entries` and `entity_definitions` are empty lists, and
`{:error, :unsupported_pack_section}` otherwise — i.e. the two sections
are checked jointly, as a single AND condition, not as two independent
checks where one could short-circuit past the other. This is the same
two-way (now three-way, counting `service_catalog_entries` +
`entity_definitions`) reject pattern already governing
`service_catalog_entries` alone today (`solution_pack.ex:539-540`) —
0026 §4 requires `entity_definitions` be folded into the SAME joint check,
not a separate, independently-satisfiable one, so a pack cannot slip a
non-empty `entity_definitions` through by virtue of
`service_catalog_entries` alone being empty, or vice versa.

### 3.3 Install step — new transactional function, `:inactive`-only, all-or-nothing

New private helper (mirrors `create_packed_definitions/3`):

```
@spec create_packed_entity_definitions(
        packed_entity_definitions :: [parsed_packed_entity_definition()],
        actor_id :: Ecto.UUID.t(),
        opts :: Definitions.opts()
      ) :: {:ok, [{parsed_packed_entity_definition(), EntityDefinition.t()}]} | install_error()
```

Calls `Letflow.Entities.Definitions.create_definition/2` once per packed
entity definition, in order, via `Enum.reduce_while` (same shape as
`create_packed_definitions/3`). For each packed entry, builds a
`create_attrs()` value (per `Letflow.Entities.Definitions`' own `@type
create_attrs`) whose `:definition` field is a conformant
`Letflow.Entities.Definition.t()` populated from the packed entry's `name`,
`display_name`, and `definition_json` (REQ-225's own document `@type` is
not re-derived here — REQ-305 constructs a value that satisfies it) and
whose `:created_by` field is the install's `actor_id`, then calls
`create_definition/2` with that `create_attrs()` value and `prefix:
opts[:prefix]`. On `{:error, reason}` (which includes `{:error,
{:persistence, changeset}}` for the name/shape-version collision case,
0026 §2), the reduce halts with `{:error, reason}` — propagating up through
`run_install/5`'s existing `with`/`else` -> `Repo.rollback/1` path,
unchanged. **No call to `Letflow.Entities.Definitions.activate_definition/4`
appears anywhere in this function or in `run_install/5`** — per 0026 §2,
install is `:inactive`-only.

`install_error/0` gains no new tuple beyond what `create_definition/2`
already returns (`Definitions.create_error()`-shaped values are already a
subtype consideration — REQ-305 confirms `create_definition/2`'s
`create_error()` type is folded into `install_error()`'s existing
`Definitions.create_error()` clause or added as its own
`Letflow.Entities.Definitions.create_error()` clause, whichever
`install_error()`'s current `@type` composition makes cleaner — a
type-declaration decision left to REQ-305, not a semantic one this doc
needs to pin further).

`run_install/5`'s transactional `with` chain gains one more clause calling
`create_packed_entity_definitions/3` with `parsed.entity_definitions`,
`actor_id`, and `opts`, binding its `{:ok, installed_entities}` result.
Placement: between the existing `create_packed_definitions/3` clause and
the `register_packed_schemas/3` clause (or after it — ordering relative to
`variable_schemas`/process-definition creation is not load-bearing, since
entity definitions and process-definition variable schemas write disjoint
tables with no FK between them). Any `{:error, _}` from the new clause
flows into the same `with`/`else` -> `Repo.rollback/1` fallback the
existing clauses already share, unchanged.

`install_result/0`'s response map gains a field reporting what was
installed — mirrors `installed_definition_maps/1`:

```
@type installed_entity_definition :: %{
        source_entity_definition_id: String.t(),
        new_entity_definition_id: Ecto.UUID.t(),
        name: String.t(),
        status: String.t()   # always "installed", matching installed_definition's own field
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

```
@spec installed_entity_definition_maps(
        [{parsed_packed_entity_definition(), EntityDefinition.t()}]
      ) :: [installed_entity_definition()]
```

mirrors `installed_definition_maps/1` exactly (map over pairs, `status:
"installed"` always, per 0026 §2's `:inactive`-status-row/`"installed"`-
response-status distinction — note these are two different "status"
concepts: the DB row's `status: :inactive` column value vs. the install
result's `status: "installed"` string, exactly the same distinction
`installed_definition_maps/1` already draws for process definitions).

## 4. Route-layer note (informational only — not this doc's scope to fix)

REQ-304's own `docs/requirements.yaml` scope fence defers route-layer
wiring (`lib/letflow/routers/solution_packs.ex`) unless REQ-304 itself
chooses to pass the new `entity_definition_names` parameter through. This
design doc does not specify a route/request-body shape — that is
REQ-304's/the route owner's decision at implementation time, informed by
this doc's `export/4` signature.

## 5. What this design does not fix

- Does not specify `Letflow.Entities.Definition.t()`'s exact field set
  (owned by REQ-225's own design) — §3.3 above assumes REQ-305 constructs
  a conformant value from `packed`'s fields, not that this doc restates
  REQ-225's type.
- Does not specify `install_error()`'s exact type-union syntax for folding
  in `Letflow.Entities.Definitions.create_error()` — a mechanical type
  authoring choice left to REQ-305.
- Does not touch `priv/repo/migrations/`, `Letflow.Entities.Records`, or
  any promoted-column concept — see 0026's Independence section.
