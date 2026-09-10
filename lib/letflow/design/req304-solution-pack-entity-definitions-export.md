# REQ-304 design — SolutionPack `entity_definitions` export

Builds the export-only half of `docs/migration/decisions/0026-solution-pack-entity-definitions-section.md`
("0026" below) and its companion design doc,
`lib/letflow/design/req303-solution-pack-entity-definitions.md` ("REQ-303's
doc" below). **Every signature, field list, and error shape below is taken
directly from 0026 and REQ-303's doc — nothing here is a new answer to a
question 0026 already decided.** This doc's only job beyond restating them is
to (a) narrow REQ-303's doc to the export-side subset REQ-304 actually builds,
(b) re-verify each cited signature against the current tree (not assumed from
REQ-303's doc), and (c) flag one real discrepancy found during that
re-verification (§2.3 below) that REQ-303's doc did not get exactly right.

Signatures and type shapes only — no function bodies. ELIXIR-DEV builds
against this doc.

## 0. Re-verification performed (current tree, this branch)

- `lib/letflow/definitions/solution_pack.ex` read in full (moduledoc,
  `pack_document` `@type` at lines 186-195, `export/3` at lines 256-278,
  `pack_each_definition/2` at lines 350-370, `pack_definition/1` at lines
  377-385, `pack_variable_schemas/1` at lines 387-397). Confirmed: exactly
  four content keys in `pack_document` today (`definitions`,
  `service_catalog_entries`, `variable_schemas`, `manifest`) — no
  `entity_definitions` key exists yet, matching 0026's own re-verification.
  `export_error` (lines 216-219) confirmed as
  `{:error, {:definition_not_found, id}} | {:error, :empty_definition_ids} | Definitions.common_error()`
  — no entity-definition-shaped clause exists yet.
- `lib/letflow/entities/definitions.ex`'s `get_definition_by_name/2` read in
  full (lines 192-226) and `list_definitions/2`'s signature confirmed (line
  290). **Discrepancy found, see §2.3.**
- `lib/letflow/entities/entity_definition.ex` read in full — confirmed the
  five fields REQ-303's doc names (`id`, `name`, `display_name`,
  `definition_json`, `logical_shape_version`) are all real persisted columns
  on `Letflow.Entities.EntityDefinition` (lines 42-53), plus `tenant_id`,
  `content_hash`, `artifact_version_id`, `status`, `inserted_at`, none of
  which this design reads or emits (INV-2: hand-built key list, no
  `Jason.Encoder` derivation, same discipline `pack_definition/1` already
  uses — `content_hash`/`artifact_version_id`/`status`/`tenant_id` are
  install-time/storage concerns, not pack-document content).
- `lib/letflow/definitions.ex`: confirmed `opts :: [prefix: String.t()]`
  (line 185) and `common_error :: {:error, :invalid_schema_name} | {:error,
  {:transaction_failed, term()}} | {:error, {:sequence_conflict, term()}}`
  (lines 197-205) — `:invalid_schema_name` is already a member, relevant to
  §2.3/§2.4 below.

## 1. `pack_document` — new type, new key (AC1)

```
@typedoc "One entity definition inside a pack document (0026 §Consequences, REQ-303 doc §1)."
@type packed_entity_definition :: %{
        entity_definition_id: Ecto.UUID.t(),
        name: String.t(),
        display_name: String.t(),
        definition_json: map(),
        logical_shape_version: binary()
      }
```

`pack_document` (`solution_pack.ex:186-195`) gains one field. Field order is
not load-bearing per REQ-303's doc; placed after `variable_schemas`,
matching the existing "list of packed X" grouping:

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

`packed_entity_definition/0`'s `@typedoc` is distinct text from
`packed_definition/0`'s and `packed_variable_schema/0`'s existing typedocs —
satisfies AC1's "own `@typedoc`" requirement literally.

## 2. `export/3` / new `export/4` — parameter, output, error case (AC2, AC3, AC4, AC5)

### 2.1 Arity split — base arity kept byte-for-byte, new arity adds the parameter

`export/3` (existing arity, `solution_pack.ex:256-260`) is **kept
unchanged in its public signature and behavior** — this is what makes AC5
("no entity definitions named still returns `entity_definitions: []` ...
byte-for-byte compatible ... no regression") mechanically true rather than
merely tested-for:

```
@spec export(
        definition_ids :: [String.t()],
        version :: String.t() | nil,
        opts :: Definitions.opts()
      ) :: {:ok, pack_document()} | export_error()
```

Its body becomes a one-line delegation: `export(definition_ids, [], version,
opts)` — i.e. it calls the new 4-arity clause with an empty
`entity_definition_names` list. This is the only body change permitted to
`export/3`; it must not gain any other new logic, so the
process-definitions-only path is provably the same code as before, just
routed through the shared implementation.

New 4-arity function (REQ-303 doc §2):

```
@spec export(
        definition_ids :: [String.t()],
        entity_definition_names :: [String.t()],
        version :: String.t() | nil,
        opts :: Definitions.opts()
      ) :: {:ok, pack_document()} | export_error()
```

`entity_definition_names` is a list of `Letflow.Entities.EntityDefinition`
`name` values (**not** ids) — the human-authored, stable identifier a pack
author references, mirroring why process definitions are looked up by
`definition_ids` at this same call boundary but the *entity*-definition
lookup helper (`get_definition_by_name/2`) is itself keyed by name, not id
(there is no id-keyed export-appropriate lookup on
`Letflow.Entities.Definitions` today).

`export/4`'s body, in order:

1. If `definition_ids == []` **and** `entity_definition_names == []`:
   `{:error, :empty_definition_ids}` — matching `export/3`'s existing
   `export([], _version, _opts)` clause's behavior for the
   zero-`definition_ids` case, extended so naming zero of *both* kinds is
   still rejected the same way (a pack with nothing to export is still
   nothing to export). If `definition_ids == []` but
   `entity_definition_names != []`, export proceeds (an entity-definitions-
   only pack is a legitimate call, per REQ-303 doc's framing of the two
   lists as independent).
2. `pack_each_definition(definition_ids, opts)` — unchanged, existing
   helper, called only if `definition_ids != []`... but to keep this a
   single code path with no branch on emptiness beyond step 1's guard,
   implement `pack_each_definition/2` to keep working correctly when handed
   `[]` (it already does — `Enum.reduce_while([], {:ok, []}, ...)` returns
   `{:ok, []}` trivially; **no change needed to `pack_each_definition/2`
   itself**).
3. `pack_each_entity_definition(entity_definition_names, opts)` — new
   helper, §2.2 below. Same "trivially returns `{:ok, []}` on an empty
   list" property.
4. On both succeeding, build the document exactly as `export/3` does today,
   plus the new `entity_definitions:` key.

### 2.2 New private helper — `pack_each_entity_definition/2` (mirrors `pack_each_definition/2`)

```
@spec pack_each_entity_definition([String.t()], Definitions.opts()) ::
        {:ok, [EntityDefinition.t()]} | export_error()
```

Reads each name via `Letflow.Entities.Definitions.get_definition_by_name/2`
(§2.3 for the exact call shape), in the order given — same "first offending
name wins the error, deterministically" ordering `pack_each_definition/2`
already uses (`Enum.reduce_while` accumulating in reverse, reversed at the
end). On `{:error, :not_found}` for a given name: halt with
`{:error, {:entity_definition_not_found, name}}` (§2.4). On any other error
returned by `get_definition_by_name/2` (`{:error, :invalid_schema_name}` —
see §2.3): halt with that error unchanged, propagating as
`Definitions.common_error()` (already a member of `export_error()` via its
existing `| Definitions.common_error()` clause — no new type member needed
for this case).

New private helper (mirrors `pack_definition/1`, same hand-built-key-list
discipline, INV-2):

```
@spec pack_entity_definition(EntityDefinition.t()) :: packed_entity_definition()
```

Field mapping (all five fields confirmed present on
`Letflow.Entities.EntityDefinition` in §0 above):

| packed field | source |
|---|---|
| `entity_definition_id` | `entity_definition.id` |
| `name` | `entity_definition.name` |
| `display_name` | `entity_definition.display_name` |
| `definition_json` | `entity_definition.definition_json` |
| `logical_shape_version` | `entity_definition.logical_shape_version` |

`export/4`'s body builds `entity_definitions:
Enum.map(entity_definitions, &pack_entity_definition/1)`, in the same order
`pack_each_entity_definition/2` returned them (i.e. the caller's given
order) — mirrors how `definitions:` is built from `pack_each_definition/2`'s
result today.

### 2.3 Discrepancy from REQ-303's doc, found during re-verification — call shape

**REQ-303's doc (§2) describes `pack_each_entity_definition/2` as calling
`get_definition_by_name/2` "under `opts[:prefix]`", the same phrasing used
for every other section's helpers, which take the full `opts` keyword list
as their second argument (e.g. `Definitions.get_by_id(id, opts)`).**
Re-reading `lib/letflow/entities/definitions.ex:208-212` directly shows this
is **not** the actual signature:

```
@spec get_definition_by_name(name :: String.t(), prefix :: String.t()) ::
        {:ok, EntityDefinition.t()}
        | {:error, :not_found}
        | {:error, :invalid_schema_name}
def get_definition_by_name(name, prefix) when is_binary(name) and is_binary(prefix) do
```

Its second argument is the **raw prefix string**, not the `opts` keyword
list — unlike `Definitions.get_by_id/2`. `pack_each_entity_definition/2`
must therefore call it as
`Letflow.Entities.Definitions.get_definition_by_name(name, prefix(opts))`,
reusing `solution_pack.ex`'s own existing private `prefix(opts)` helper
(`solution_pack.ex:343`, `defp prefix(opts), do: Keyword.get(opts, :prefix)`)
to extract the string — **not** `get_definition_by_name(name, opts)`, which
would pass a keyword list where a `String.t()` is expected and fail to
compile (or, worse if the guard were looser, fail at the `is_binary(prefix)`
guard clause at runtime). This is the one place this design doc corrects
REQ-303's doc rather than merely restating it; the underlying tenant-scoping
mechanism (`opts[:prefix]`, ultimately derived from
`scoped_repo_opts/1`/INV-1) is identical either way — only the argument
*shape* passed to this one function differs from every other section's
helper.

### 2.4 New error case (AC4)

```
@type export_error ::
        {:error, {:definition_not_found, definition_id :: String.t()}}
        | {:error, {:entity_definition_not_found, name :: String.t()}}
        | {:error, :empty_definition_ids}
        | Definitions.common_error()
```

`{:error, {:entity_definition_not_found, name}}` is a **new** tuple shape,
added to `solution_pack.ex`'s existing `export_error` type
(`solution_pack.ex:216-219`) as a sibling clause — it must not reuse
`{:definition_not_found, id}` (that shape is keyed by process-definition
`id`; this one is keyed by entity-definition `name`, a different domain and
a different key type). This covers AC4: a nonexistent name (wrong name, or
a name that exists only in another tenant's schema — indistinguishable from
"doesn't exist" per INV-1/INV-5, same reasoning
`pack_each_definition/2`'s moduledoc already states for process
definitions) produces this exact tuple, never leaking whether the name
exists elsewhere.

## 3. Tenant scoping (AC3, INV-1)

Every entity-definition read this design specifies
(`get_definition_by_name/2`) is called with `prefix(opts)` — a string
derived from the caller's own `opts[:prefix]`, itself derived upstream (at
the route/API-context boundary, unchanged by this design) from
`Letflow.Api.Context.scoped_repo_opts/1`, i.e. solely from the authenticated
token's `tenant_id`. Neither `export/4` nor `pack_each_entity_definition/2`
nor `pack_entity_definition/1` introduces a `tenant_id`, `schema_name`, or
`slug` parameter anywhere in its signature. `get_definition_by_name/2`
itself derives `tenant_id` internally via
`TenantProvisioning.tenant_id_for_schema_name/1` from the `prefix` string
alone (`definitions.ex:213`) — no caller-suppliable tenant id reaches it by
any other path. This matches 0026 §5 and its SECURITY-REVIEWER sign-off
verbatim; this design introduces nothing beyond what that sign-off already
assessed.

## 4. Route layer — left untouched (informational)

0026 §"What this record does not decide" and REQ-303's doc §4 both state
route-layer wiring (`lib/letflow/routers/solution_packs.ex`) is deferred to
REQ-304's own choice, not mandated by 0026. **This design does not extend
the route layer.** `export/4` is a new context-module arity, callable
programmatically and by any future route change, but no route currently
calls `export/3`/`export/4` with anything but `definition_ids`/`version`/
`opts` — extending the route's request-body parsing to accept
`entity_definition_names` is out of scope for this design and is left for a
later requirement, consistent with REQ-304's own scope-fence text ("if
0026's design defers the route-layer change to a later requirement, leave
`routers/solution_packs.ex` untouched and say so"). 0026 defers it; this
design accordingly specifies no route change, and ELIXIR-DEV should not
touch `lib/letflow/routers/solution_packs.ex` when implementing this design.

## 5. Invariants

- **INV-1** — no caller-supplied tenant id anywhere in the new
  `entity_definitions` export path. See §3.
- **INV-2** — `pack_entity_definition/1` is a hand-built key list (§2.2's
  table), never a `Jason.Encoder`/struct-derived encoding of
  `%EntityDefinition{}` — matches `pack_definition/1`'s own discipline and
  keeps `tenant_id`/`content_hash`/`artifact_version_id`/`status` (storage-
  only fields) out of the pack document.
- **Backward compatibility** — `export/3`'s public signature, behavior, and
  output shape for a process-definitions-only export are unchanged
  byte-for-byte; the only structural addition to its output is the new
  always-present `entity_definitions: []` key when no entity definitions
  are named (§2.1). This is what makes AC5 true by construction rather than
  by convention.
- **Ordering determinism** — `pack_each_entity_definition/2` reports the
  first offending name in caller-given order, matching
  `pack_each_definition/2`'s existing ordering guarantee for
  `definition_ids`.
- **No schema-version change** — `bpm_export_schema_version` is untouched by
  this design (0026 §1(a)); `export/4` does not read or write it beyond
  what `export/3` already does (`ExportImport.export_schema_version()`,
  unchanged call site).

## 6. Cross-module dependencies

- `Letflow.Entities.Definitions.get_definition_by_name/2` — read-only,
  unchanged signature, called from the new
  `pack_each_entity_definition/2` helper (§2.3 for the exact call shape).
  **No change to `lib/letflow/entities/definitions.ex` is needed for this
  requirement** — the lookup function this design calls already exists with
  the exact signature this design assumes; the scope fence's "small
  read-only addition to `lib/letflow/entities/definitions.ex`... if 0026's
  design calls for it" is **not triggered** — 0026 does not call for a new
  lookup function, `get_definition_by_name/2` already suffices.
- `Letflow.Entities.EntityDefinition` — read-only struct access
  (`.id`, `.name`, `.display_name`, `.definition_json`,
  `.logical_shape_version`) inside `pack_entity_definition/1`. No changeset,
  no write.
- `Letflow.Definitions.opts/0` (`[prefix: String.t()]`) — reused unchanged
  as `export/4`'s `opts` parameter type; no new opts shape.
- `Letflow.Definitions.common_error/0` — reused unchanged as part of
  `export_error/0`; already covers `get_definition_by_name/2`'s
  `{:error, :invalid_schema_name}` case (§2.2), so no new error-type member
  is needed for that branch.

## 7. Acceptance-criteria mapping

| AC | Design element |
|---|---|
| 1 | §1 — `pack_document`'s new `entity_definitions: [packed_entity_definition()]` key, `packed_entity_definition/0`'s own distinct `@typedoc` |
| 2 | §2.1 (`export/4`'s new parameter), §2.2 (`pack_each_entity_definition/2`/`pack_entity_definition/1`, field table with name/display_name/definition_json among the five fields) |
| 3 | §3 — every read via `get_definition_by_name(name, prefix(opts))`, no new tenant-id-shaped parameter anywhere |
| 4 | §2.4 — `{:error, {:entity_definition_not_found, name}}`, added to `export_error/0` |
| 5 | §2.1 — `export/3` delegates to `export/4` with `entity_definition_names: []`, no other body change; `entity_definitions: []` always present when none named |
| 6 | Design uses only `@spec`/`@type`/`@typedoc` and existing, already-compiling helper patterns (`Enum.reduce_while`, existing `prefix/1` helper) — no new dependency, no speculative API; ELIXIR-DEV runs `mix compile --warnings-as-errors` to confirm |
| 7 | §4 — route layer explicitly left untouched; §6 — no change to `lib/letflow/entities/definitions.ex` needed at all; nothing in this design touches `lib/letflow/definitions/solution_pack_install.ex` or any other file |

## 8. Open questions

None blocking. One item flagged for ELIXIR-DEV's attention, not a design
gap: §2.3's discrepancy (`get_definition_by_name/2` takes `prefix ::
String.t()`, not `opts`) is exactly the kind of drift the requirement text
asked this design to re-verify against — it is resolved here, not left
open, but ELIXIR-DEV should still compile-check this call site specifically
since it's the one place this design's call shape differs from every other
`pack_each_*`-style helper in this module.
