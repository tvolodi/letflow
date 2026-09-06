# Design: REQ-226 — `entity_definitions` persistence, CRUD context module, and the `:entity` `ArtifactKind` extension

**Requirement:** REQ-226 (`docs/requirements.yaml`, stage S6, `depends_on: [REQ-225,
REQ-202, REQ-203, REQ-067]`). Slice 2 of the ISS-0438 entity-subsystem port.
**Owner (implementer):** ELIXIR-DEV.
**This document produces:** the `entity_definitions` migration spec, the one-line
`:entity` addition to `lib/letflow/repository/artifact_kind.ex`, the exact module/file
names and function signatures for the CRUD context module, the dedup/uniqueness call
sequence, and a complete error taxonomy. **No implementation code** — no `def ... do
... end` bodies, no literal `Ecto.Migration` DSL, no working Elixir anywhere below;
every fenced block is a `@type`/`@spec` declaration, a column table, or plain-English
rule description. Record-payload validation is REQ-227's job; event
registration/commands are REQ-228's job. Neither is designed here.

---

## 0. Sources read for this design

- `docs/requirements.yaml`'s REQ-226 entry in full (description + all 8 acceptance
  criteria) and REQ-225's entry (read for boundary confirmation).
- `lib/letflow/design/req225-entity-definition-schema-validation.md` in full — the
  `EntityDefinition` document shape, the 11 structural validation rules, and the
  canonicalisation/hashing/logical-shape-versioning contract this design consumes
  as-is.
- `lib/letflow/entities/definition.ex`, `lib/letflow/entities/definition/validator.ex`,
  `lib/letflow/entities/definition/shape.ex` — REQ-225's actual shipped implementation.
  `Validator.validate/1` returns `:ok | {:error, [Violation.t()]}`;
  `Shape.content_hash/1` and `Shape.logical_shape_of/1` each return a raw 32-byte
  SHA-256 digest (`binary()`).
- `lib/letflow/repository/artifact_kind.ex` — confirmed a bare `@artifact_kinds`
  module-attribute list of 7 atoms (`:definition, :form, :schema, :service_catalog,
  :script, :module, :scenario`), a `@type t`, and one `values/0` accessor. No
  structural dependency anywhere else in the module on the list's length or contents
  — genuinely a closed enumeration meant to grow by literal addition (the module's own
  moduledoc states this explicitly: it exists to prevent drift *between* the schemas
  that reference it, not to stay closed forever).
- `lib/letflow/repository.ex` in full — `Letflow.Repository.create/2`'s
  canonicalise → hash → upsert-by-hash (dedup) → resolve/mint `artifact_id` →
  compute `version_number` → insert `artifact_versions` pipeline (design
  `req202-artifact-repository.md` §4), and `list_versions/4`'s REQ-067 cursor
  contract (design §6) — the closest in-repo analog `listDefinitions/2` must match.
- `priv/repo/migrations/20260830030001_create_repository_artifacts.exs` — the
  tenant-scoped migration shape convention (`if prefix() do ... end` guard,
  `primary_key: false` + explicit `binary_id`/`content_hash` PKs, explicit short
  index names, `timestamps(updated_at: false)`) this migration must follow.
- `lib/letflow/repository/artifact_version.ex` — `artifact_versions`' Ecto schema
  (`version_id` primary key, `binary_id`), the FK target `entity_definitions.
  artifact_version_id` references.
- `lib/letflow/repository/activation.ex` — REQ-203's `resolve/3` and
  `activate_group/5`, both keyed purely on `(artifact_kind, artifact_name, prefix)`
  with no schema-level dependency on which kind is passed — confirms `:entity` flows
  through unchanged (§5 below).
- `lib/letflow/definitions.ex`'s `list_paginated/2` and
  `Letflow.Repository.list_versions/4` — the two established
  tenant-scoped-context-module cursor-pagination shapes; this design follows
  `list_versions/4`'s (same subsystem, same `Letflow.Api.Pagination` primitives)
  rather than reinventing a third.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B (schema-per-tenant
  from the first migration; `tenant_id` retained intra-schema as a
  discipline/query-predicate, never a separately-trusted caller-supplied value — its
  2026-08-17 addendum: the writing context module derives `tenant_id` from `prefix`
  via `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, exactly as
  `Letflow.Repository.create/2` and `Letflow.Repository.Activation.resolve/3` already
  do).

---

## 1. The `entity_definitions` migration

### 1.1 Placement — tenant-scoped, per-tenant Postgres schema (confirms REQ-226's own text)

Same placement as `repository_artifacts`/`artifact_versions` (REQ-202),
`artifact_activations`/`artifact_activation_history` (REQ-203), and REQ-211's
attachment addendum: created inside the `if prefix() do ... end` guard, registered in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0` (both halves mandatory, per
that module's own manifest comment). **Not** a shared `public`-schema table — Decision
B's blast-radius-containment rationale applies identically here; nothing about
`entity_definitions` argues for an exception.

### 1.2 Table: `entity_definitions`

| Column | Type | Null | Notes |
|---|---|---|---|
| `id` | `:binary_id` | not null | Primary key (`primary_key: true`), server-generated (`autogenerate: true`, matching `artifact_versions.version_id`'s convention — not client-supplied). |
| `tenant_id` | `:binary_id` | not null | Derived from `prefix` by the context module at write time (§0's Decision-B addendum), never accepted as a separately-trusted caller field. Not itself part of any unique index (schema-per-tenant physical isolation already scopes every row; `tenant_id` here is the same query-predicate/defense-in-depth discipline every other Decision-B table carries, not a second isolation mechanism). |
| `name` | `:string`, `size: 255` | not null | The `entity_definition().name` field (REQ-225 Rule 1: `^[a-z][a-z0-9_]{0,63}$`) — this column's own `size: 255` is a storage ceiling, not a re-validation; REQ-225's regex is the actual enforced format, checked before any DB write. |
| `display_name` | `:string`, `size: 255` | not null | Denormalised straight from the document body — display-only, never used in any uniqueness or lookup predicate (REQ-225 Shape's logical-shape rule already excludes it from the content that determines identity). |
| `definition_json` | `:map` (Postgres `jsonb`) | not null | The full `EntityDefinition.t()` document, stored denormalised for read access without round-tripping through the `repository_artifacts` content-addressed blob on every read. This is a **read-convenience copy**, not the source of truth for dedup — `content_hash` (below) plus `artifact_version_id` is what ties a row back to REQ-202's canonical content. |
| `content_hash` | `:binary` | not null | The raw 32-byte SHA-256 digest from `Letflow.Entities.Definition.Shape.content_hash/1` — identical to the hash `Letflow.Repository.create/2` independently computes over the same canonicalised JSON bytes and stores on the `repository_artifacts`/`artifact_versions` rows it writes (§3 confirms these are the same value, not two independently-derived hashes that happen to usually agree). Indexed (not unique alone — see §1.3) for the "byte-identical content, different name" dedup-tracing story in §4. |
| `logical_shape_version` | `:binary` | not null | The raw 32-byte digest from `Letflow.Entities.Definition.Shape.logical_shape_of/1`. Despite the name echoing "version," this is a **content digest of the definition's logical shape**, not a monotonically increasing integer — two definitions with the same `name` but a structurally different `fields`/`indexes`/`foreign_keys`/`constraints` set produce different digests and are therefore different rows under the unique constraint below; two submissions of the same logical shape (reordered lists, changed `display_name`/`description` only) produce the *same* digest. |
| `artifact_version_id` | `:binary_id` | not null | FK → `artifact_versions.version_id` (`references(:artifact_versions, column: :version_id, type: :binary_id, on_delete: :restrict, prefix: schema)`, same `:restrict` policy `artifact_versions.content_hash`'s own FK into `repository_artifacts` uses — an `entity_definitions` row must never be left pointing at a deleted version). This is the row `Letflow.Repository.Activation.resolve/3` and `activate_group/5` operate on (§5). |
| `status` | `:string` | not null | Free-form status column, `Ecto.Enum`-backed at the schema-module level (not a DB `CHECK` constraint — matches `Letflow.Repository.ArtifactVersion.artifact_kind`'s own `Ecto.Enum`-over-`:string` convention rather than a Postgres enum type). Values: `:active`, `:inactive` — `:active` is set exactly by whichever code path calls `Letflow.Repository.Activation.activate_group/5` for this row's `artifact_version_id` (design §5); a freshly created row starts `:inactive` (REQ-226's own text: "only ACTIVE entity definitions can receive entity command events" implies creation and activation are two separate steps, matching R-Co's and REQ-203's own two-step create-then-activate flow for `:definition`/`:form`). This column is a local read-convenience denormalisation of REQ-203's `artifact_activations` pointer — `Letflow.Repository.Activation.resolve/3` remains the single source of truth for "is this artifact_kind/artifact_name pair currently active"; `entity_definitions.status` must be kept in sync by `activateDefinition/2` (§3.4) but a reader that needs an authoritative answer, not a cached one, still calls `Activation.resolve/3`. |
| `inserted_at` | `:utc_datetime_usec` | not null | Via `timestamps(updated_at: false)` — matching `repository_artifacts`/`artifact_versions`' own immutable-row convention (§1.4 below explains why `entity_definitions` rows are append-only too). |

No `updated_at` column (`timestamps(updated_at: false)`, same call `repository_artifacts`
and `artifact_versions` use) — see §1.4.

### 1.3 Constraints and indexes

- **Primary key:** `id` (`primary_key: false` at the `table/2` level, explicit
  `add :id, :binary_id, primary_key: true`, matching `artifact_versions.version_id`'s
  shape rather than Ecto's default auto-incrementing-integer PK).
- **`UNIQUE (tenant_id, name, logical_shape_version)`** — REQ-226's own text, verbatim.
  Named explicitly (`entity_definitions_tenant_name_shape_idx`, well under Postgres's
  63-byte `NAMEDATALEN`) rather than left to Ecto's default derived name, matching the
  explicit-naming rationale `20260830030001_create_repository_artifacts.exs`'s own
  comment gives for `artifact_versions`' two indexes (default-name collision risk).
  This is the constraint AC4's "same name and same `logical_shape_version` ->
  rejected" half enforces (§4).
- **Index on `(tenant_id, name)`** (non-unique) — supports `getDefinitionByName/2`
  (§3.2) without a full-table scan; the tenant_id, name prefix of the UNIQUE index
  above already covers this access pattern as a leading-column index, so no
  additional index object is created (Postgres can use the UNIQUE index's leading
  columns for an equality lookup on `(tenant_id, name)` alone).
- **Index on `(tenant_id, inserted_at desc, id desc)`** — named
  `entity_definitions_tenant_inserted_id_idx`, supports `listDefinitions/2`'s cursor
  query (§3.3) the same way `artifact_versions_kind_name_number_desc_idx` supports
  `list_versions/4`.
- **Index on `content_hash`** — named `entity_definitions_content_hash_idx`, supports
  the "trace which `entity_definitions` rows share a `repository_artifacts` row"
  query in §4's dedup-tracing story (not used by any CRUD function's WHERE clause on
  the production path; exists for observability/debugging parity with
  `artifact_versions`' own `content_hash` index).
- **FK on `artifact_version_id`** — `:restrict` on delete (§1.2 table).
- No `CHECK` constraint duplicating REQ-225's structural rules — REQ-225's validation
  runs in the application layer, before any row is ever built (§3.1's ordering
  guarantee); the DB layer's only structural enforcement is the UNIQUE constraint and
  the FK, both identity/reference constraints, not content-shape constraints.

### 1.4 Immutability — deliberately NOT a hard DB-trigger-enforced rule here

Unlike `repository_artifacts`/`artifact_versions`, this migration adds **no**
`BEFORE UPDATE`/`BEFORE DELETE` trigger to `entity_definitions`. Reason: REQ-226's own
scope never exposes an `updateDefinition/2` or `deleteDefinition/2` function (§3 lists
only `createDefinition/2`, three read functions, and activation reuse) — so there is no
application-layer update path to structurally forbid yet, and adding a DB trigger now
would block a legitimate future need (e.g., a later requirement editing `status` when
REQ-226's own `activateDefinition` wrapper, if one is needed, needs to write that
column — see §3.4) without that future requirement's design being the one to decide
it. This is flagged as an explicit open question in §6, not silently resolved by
copying `repository_artifacts`' trigger unconditionally.

---

## 2. The `:entity` extension to `artifact_kind.ex`

Confirmed from direct reading (§0): `lib/letflow/repository/artifact_kind.ex` is a
7-element atom list with a `@type t` union and one accessor, with **no** other code in
the codebase depending on its length, its being closed, or any exhaustive `case`
switching over every one of its values (a `case`/`cond` with a catch-all `_ ->` clause
would still compile and run correctly with an 8th value added; nothing in
`Letflow.Repository`, `Letflow.Repository.Activation`, `Letflow.Repository.ArtifactVersion`,
`Letflow.Repository.Activation.ActivationHistory`, or `Letflow.Repository.ActivationGroup`
pattern-matches on a specific finite set of `artifact_kind` atoms rather than treating
the value opaquely). This is genuinely a one-line, non-structural addition.

**Exact change**, `lib/letflow/repository/artifact_kind.ex`:

- `@artifact_kinds` list: append `:entity` as the 8th element —
  `[:definition, :form, :schema, :service_catalog, :script, :module, :scenario, :entity]`.
- `@type t`: append `| :entity` to the union —
  `:definition | :form | :schema | :service_catalog | :script | :module | :scenario | :entity`.
- The module's moduledoc comment "seven-atom value set" becomes stale text ELIXIR-DEV
  must update to "eight-atom value set" in the same change (a doc-accuracy fix riding
  along with the functional one, not a separate requirement).
- `values/0`'s implementation (`def values, do: @artifact_kinds`) is unchanged —
  it already returns whatever the module attribute holds.

No migration change is needed for `Ecto.Enum, values: Letflow.Repository.ArtifactKind.values()`
fields on `Letflow.Repository.ArtifactVersion`, `Letflow.Repository.Activation`, etc. —
those fields already resolve the allowed-values list from this module at compile time,
so they pick up `:entity` automatically once this one file changes (this is exactly the
"prevent drift between the schemas that reference it" property the module's moduledoc
names as its reason to exist).

---

## 3. The CRUD context module

### 3.1 Module and file placement

**`Letflow.Entities.Definitions`** (plural), file
`lib/letflow/entities/definitions.ex` — distinct from REQ-225's singular
`Letflow.Entities.Definition` (`lib/letflow/entities/definition.ex`, the document-shape
module) the same way `Letflow.Repository.Artifact`/`Letflow.Repository.ArtifactVersion`
(schema structs) are distinct from `Letflow.Repository` (the context module that calls
them). `Letflow.Entities.Definitions` is the tenant-scoped context module REQ-226 adds;
it depends on `Letflow.Entities.Definition` (document type), `Letflow.Entities.Definition.Validator`
(structural validation), `Letflow.Entities.Definition.Shape` (hashing), and
`Letflow.Repository`/`Letflow.Repository.Activation` (REQ-202/REQ-203's existing
pipelines) — never the reverse (REQ-225's three modules remain ignorant of persistence,
per their own moduledocs read in §0).

A second new module, **`Letflow.Entities.EntityDefinition`**
(`lib/letflow/entities/entity_definition.ex`), is the `Ecto.Schema` for the
`entity_definitions` table (§1.2's columns as schema fields, `Ecto.Enum` for `status`).
This mirrors the `Letflow.Repository.Artifact`/`Letflow.Repository.ArtifactVersion`
split: `Letflow.Entities.Definition` is a plain document `@type` (REQ-225, no
`Ecto.Schema`), `Letflow.Entities.EntityDefinition` is the persisted-row `Ecto.Schema`
(REQ-226, this design) — two different modules with similar names for a reason
(document shape vs. persisted row), exactly like `Definition`/`EntityDefinition` should
not be confused with each other or with `Letflow.Entities.Definitions` (the context
module, plural, third name in the family). ELIXIR-DEV must not collapse these three
into fewer modules or rename any of them ambiguously — the three-way split (document
shape / persisted schema / context module) is deliberate and mirrors the
`Repository`/`Artifact`/`ArtifactVersion` precedent already in this codebase.

| Name | Kind | File |
|---|---|---|
| `Letflow.Entities.Definition` | document `@type` (REQ-225, unchanged) | `lib/letflow/entities/definition.ex` |
| `Letflow.Entities.Definition.Validator` | structural validation (REQ-225, unchanged) | `lib/letflow/entities/definition/validator.ex` |
| `Letflow.Entities.Definition.Shape` | hashing (REQ-225, unchanged) | `lib/letflow/entities/definition/shape.ex` |
| `Letflow.Entities.EntityDefinition` | `Ecto.Schema` for `entity_definitions` (REQ-226, new) | `lib/letflow/entities/entity_definition.ex` |
| `Letflow.Entities.Definitions` | tenant-scoped CRUD context module (REQ-226, new) | `lib/letflow/entities/definitions.ex` |

### 3.2 `Letflow.Entities.EntityDefinition` — Ecto schema field list

```
@primary_key {:id, :binary_id, autogenerate: true}
schema "entity_definitions" do
  field :tenant_id,             :binary_id
  field :name,                  :string
  field :display_name,          :string
  field :definition_json,       :map
  field :content_hash,          :binary
  field :logical_shape_version, :binary
  field :artifact_version_id,   :binary_id
  field :status, Ecto.Enum, values: [:active, :inactive]

  timestamps(updated_at: false)
end
```

`changeset/2`: casts and requires every field above except `id`/`inserted_at`
(server/DB-assigned); `unique_constraint(:name, name: :entity_definitions_tenant_name_shape_idx)`
translating the `(tenant_id, name, logical_shape_version)` UNIQUE violation into a
changeset error (matching `Letflow.Repository.ArtifactVersion.changeset/2`'s
`unique_constraint/3` idiom for its own `artifact_versions_kind_name_number_idx`);
`foreign_key_constraint(:artifact_version_id)` translating a hypothetical FK violation
into a changeset error (matching `Letflow.Repository.Activation.changeset/2`'s
`foreign_key_constraint/3` idiom).

### 3.3 `Letflow.Entities.Definitions` — public function signatures

```
@type create_attrs :: %{
        required(:definition) => Letflow.Entities.Definition.t(),
        required(:created_by) => Ecto.UUID.t()
      }

@type create_error ::
        {:error, {:validation, [Letflow.Entities.Definition.Validator.violation()]}}
        | {:error, {:repository, term()}}
        | {:error, {:persistence, Ecto.Changeset.t()}}
        | {:error, :invalid_schema_name}

@spec create_definition(create_attrs(), prefix :: String.t()) ::
        {:ok, Letflow.Entities.EntityDefinition.t()} | create_error()
```

Steps, in this exact order (design §4's dedup story depends on this order):

1. `Letflow.Entities.Definition.Validator.validate(attrs.definition)` — if this
   returns `{:error, violations}`, return `{:error, {:validation, violations}}`
   **immediately**. No `Letflow.Repository.create/2` call, no `entity_definitions`
   insert attempt, no DB write of any kind happens on this branch (AC2's own wording,
   verified by inspecting both tables after a rejected call finding zero new rows in
   either).
2. On `:ok`, compute `content_hash = Letflow.Entities.Definition.Shape.content_hash(attrs.definition)`
   and `logical_shape_version = Letflow.Entities.Definition.Shape.logical_shape_of(attrs.definition)`.
3. Call `Letflow.Repository.create/2` with
   `%{artifact_kind: :entity, artifact_name: attrs.definition.name, content_type: "application/json", content: Jason.encode!(attrs.definition), created_by: attrs.created_by}`,
   `prefix`. This is the exact reuse point named in REQ-226's own text — no
   independent canonicalisation, hashing, or dedup logic lives in
   `Letflow.Entities.Definitions`; REQ-202's `create/2` pipeline is called, not
   reimplemented. If this returns `{:error, reason}` (any of `create/2`'s own
   documented error shapes — `:invalid_json`, `:invalid_schema_name`,
   `:version_number_conflict`, or an `Ecto.Changeset.t()`), return
   `{:error, {:repository, reason}}` immediately — no `entity_definitions` row is
   written on this branch either.
4. On `{:ok, %Letflow.Repository.ArtifactVersion{version_id: artifact_version_id}}`,
   insert one `entity_definitions` row via `Letflow.Entities.EntityDefinition.changeset/2`
   with `tenant_id` (derived from `prefix` the same way `Letflow.Repository.create/2`
   itself derives it — never taken from the caller), `name`, `display_name`,
   `definition_json` (the raw document map), `content_hash`, `logical_shape_version`,
   `artifact_version_id`, `status: :inactive`. If this insert fails
   (the UNIQUE constraint fires — AC4's "same name and same `logical_shape_version`"
   case), return `{:error, {:persistence, changeset}}` — note that at this point
   step 3 has already run and may have written or reused a `repository_artifacts`/
   `artifact_versions` row; this is intentional and matches AC4's own wording ("...is
   rejected by the UNIQUE ... constraint..." — the rejection is scoped to the
   `entity_definitions` write, not to the repository write, since two different
   `entity_definitions` rows are allowed to legitimately share one
   `repository_artifacts` row by design, per §4).
5. On success, return `{:ok, %Letflow.Entities.EntityDefinition{}}`.

```
@spec get_definition(id :: Ecto.UUID.t(), prefix :: String.t()) ::
        {:ok, Letflow.Entities.EntityDefinition.t()}
        | {:error, :not_found}
        | {:error, :invalid_schema_name}

@spec get_definition_by_name(name :: String.t(), prefix :: String.t()) ::
        {:ok, Letflow.Entities.EntityDefinition.t()}
        | {:error, :not_found}
        | {:error, :invalid_schema_name}
```

Both: `TenantProvisioning.tenant_id_for_schema_name(prefix)` first (matching every
other function in this family); `Repo.get(EntityDefinition, id, prefix: prefix)` /
a `WHERE name == ^name` query against the `(tenant_id, name)`-covering index (§1.3),
scoped by `prefix`; `nil` result -> `{:error, :not_found}` (never raises `Ecto.NoResultsError`,
matching this codebase's established "tagged tuple, not an exception, for a
caller-triggerable not-found" convention — `Letflow.Repository.Activation.resolve/3`'s
own `{:error, :not_found}`-shaped return, adapted, is the direct precedent, not
`Repo.get!/2`).

```
@type list_definitions_filters :: %{
        optional(:cursor) => String.t() | nil,
        optional(:page_size) => pos_integer() | nil
      }

@spec list_definitions(list_definitions_filters(), prefix :: String.t()) ::
        {:ok, Letflow.Api.Pagination.Page.t(Letflow.Entities.EntityDefinition.t())}
        | {:error, :invalid_schema_name}
        | {:error, :page_size_too_large}
        | {:error, :wrong_endpoint}
        | {:error, :expired}
        | {:error, :invalid_cursor}
```

Matches `Letflow.Repository.list_versions/4`'s contract exactly (REQ-067), adapted to
this table's own sort key:

1. `TenantProvisioning.tenant_id_for_schema_name(prefix)`.
2. `Letflow.Api.Pagination.validate_page_size(filters.page_size)` — rejected, not
   clamped, out of range (same as `list_versions/4`).
3. Decode `filters.cursor` via `Letflow.Api.Pagination.decode_cursor/3` with a
   dedicated prefix tag `"ED:"` (distinct from `list_versions/4`'s `"RV:"` — REQ-067's
   `:wrong_endpoint` check exists precisely so one endpoint's cursor can never be
   replayed against a different endpoint; `entity_definitions` needs its own tag, not
   a reuse of `"RV:"`), decoding to `{inserted_at_us, id}` — the same "mint-time
   timestamp first, domain sort key after" cursor-inner shape `list_versions/4` uses,
   substituting `(inserted_at, id)` for `(version_number, version_id)` since
   `entity_definitions` has no version-number-shaped column.
4. Query: `WHERE tenant_id == ^tenant_id`, `ORDER BY inserted_at DESC, id DESC`,
   `WHERE (inserted_at, id) < (^cursor_inserted_at, ^cursor_id)` when a cursor is
   present (same seek-predicate idiom `filter_by_list_versions_cursor/2` uses),
   `LIMIT page_size + 1`, using the `entity_definitions_tenant_inserted_id_idx` index
   (§1.3).
5. Split into `{page, next_cursor}` the same way `split_list_versions_page/2` does;
   wrap in `Letflow.Api.Pagination.page_response/2`.

Tenant scoping (AC5) is structural here exactly the way `list_versions/4`'s moduledoc
states it for that function: because `entity_definitions` lives in a per-tenant
Postgres schema (§1.1), a query scoped to `prefix` cannot return another tenant's rows
regardless of what a cursor decodes to — `tenant_id` in the WHERE clause is the same
belt-and-suspenders discipline every Decision-B table carries, not the sole isolation
mechanism.

### 3.4 Activation — reuses REQ-203's existing machinery, no new function

REQ-226's own text states this plainly and this design confirms it against
`lib/letflow/repository/activation.ex`'s actual code (§0): `Letflow.Repository.Activation.resolve/3`
and `Letflow.Repository.Activation.activate_group/5` are keyed on
`(artifact_kind, artifact_name, prefix)` alone, with `artifact_kind` typed as
`Letflow.Repository.ArtifactKind.t()` — an opaque value neither function branches on
by specific atom. Once §2's one-line change lands, a caller passes
`artifact_kind: :entity, artifact_name: <definition name>` into
`activate_group/5` exactly the way an existing caller passes `:definition` or `:form`
today, and it works identically: locks/upserts the `artifact_activations` pointer row,
inserts one `artifact_activation_history` row, appends one audit entry, all inside
`activate_group/5`'s existing `Repo.transaction/1`. **No new function is added to
`Letflow.Repository.Activation` by this requirement.**

One thin wrapper is added to `Letflow.Entities.Definitions`, not because REQ-203's API
is insufficient, but to keep `entity_definitions.status` (§1.2's local read-convenience
denormalisation) in sync with the authoritative `artifact_activations` pointer:

```
@spec activate_definition(
        name :: String.t(),
        activator_user_id :: Ecto.UUID.t(),
        rationale :: String.t(),
        prefix :: String.t()
      ) ::
        {:ok, Letflow.Entities.EntityDefinition.t()}
        | {:error, :not_found}
        | {:error, Letflow.Repository.Activation.activate_group_error()}
```

Body-level contract (no implementation code, per this doc's own scope): calls
`Letflow.Repository.Activation.activate_group([%{artifact_kind: :entity, artifact_name: name, version_id: <the entity_definitions row's current artifact_version_id>}], activator_user_id, rationale, prefix)`
unchanged, then — only on that call's own success — updates the matching
`entity_definitions` row's `status` to `:active` (a plain `Ecto.Changeset`/`Repo.update`,
not itself wrapped in `activate_group/5`'s transaction, since REQ-203's own
`artifact_activations` pointer is the durable source of truth and a crash between the
two writes leaves `entity_definitions.status` merely stale, not incorrect in a way that
corrupts any invariant — a reader needing an authoritative answer already calls
`Letflow.Repository.Activation.resolve/3` directly, per §1.2's own note). This wrapper
adds **no new activation table, pointer, or history mechanism** — AC6's own
`git diff --stat` check has nothing new activation-shaped to find beyond this one
context-module function.

---

## 4. Dedup/uniqueness semantics — the two AC4 scenarios traced end-to-end

**Scenario A — byte-identical content twice, different `name` values.**

1. First `create_definition/2` call: validation passes: `Letflow.Repository.create/2`
   canonicalises the JSON, computes `content_hash`, finds no existing
   `repository_artifacts` row for that hash, inserts one, then inserts one
   `artifact_versions` row (`artifact_id` freshly minted for
   `(:entity, name_a)`, `version_number: 1`). `Letflow.Entities.Definitions` inserts
   one `entity_definitions` row: `name = "name_a"`, `artifact_version_id` = that
   version's id.
2. Second call, byte-identical `definition_json` except `name = "name_b"`:
   validation passes independently (REQ-225's rules are per-document, not
   cross-document). `content_hash` is identical to step 1's (same canonical bytes).
   `Letflow.Repository.create/2`'s `upsert_content/6` upsert
   (`on_conflict: :nothing, conflict_target: :content_hash`) finds the existing
   `repository_artifacts` row and writes nothing new (REPO-01's dedup — one
   `repository_artifacts` row total). Because `artifact_name` for this call is
   `"name_b"`, `next_version/3` finds no prior `artifact_versions` row for
   `(:entity, "name_b")` and mints a **new** `artifact_id`/`version_number: 1` —
   `artifact_versions` gets a second row, distinct `artifact_id`, same
   `content_hash` FK target. `Letflow.Entities.Definitions` inserts a second,
   distinct `entity_definitions` row: `name = "name_b"`, a different
   `artifact_version_id`, but the **same** `content_hash` value copied onto the
   `entity_definitions` row (§1.2) as `name_a`'s row — this is the "one
   `repository_artifacts` row, two `entity_definitions` rows" outcome AC4 names.
3. The `(tenant_id, name, logical_shape_version)` UNIQUE constraint never fires here
   — `name` differs between the two rows.

**Scenario B — byte-identical content twice, same `name` and same
`logical_shape_version`.**

1. First call as in Scenario A step 1.
2. Second call, identical `definition_json` (same `name`, hence same
   `logical_shape_version` — `Shape.logical_shape_of/1` is a pure function of the
   document minus `display_name`/`description`, and nothing else changed): validation
   passes; `Letflow.Repository.create/2` runs its full pipeline again — because
   `artifact_name` (`"name_a"`) is unchanged, `next_version/3` finds the existing
   `artifact_versions` row for `(:entity, "name_a")` and mints **version_number: 2**
   (a new `artifact_versions` row is created even though content is byte-identical —
   `create/2` has no "no-op if nothing changed" short-circuit; REQ-202's own dedup is
   scoped to `repository_artifacts`, not to `artifact_versions`). This step succeeds
   and returns `{:ok, version}`.
3. `Letflow.Entities.Definitions` then attempts the `entity_definitions` insert:
   `tenant_id`/`name`/`logical_shape_version` are all identical to the row from step
   1, so the UNIQUE constraint fires. The insert returns
   `{:error, {:persistence, changeset}}` (§3.3 step 4/§5's exact tuple shape).
4. Net effect AC4 describes: the second call is "rejected" at the
   `entity_definitions` layer, but **not** before a second, functionally redundant
   `artifact_versions` row (version_number 2) was created in step 2 — this is a
   known, accepted cost of reusing `create/2` unmodified rather than adding a
   pre-check against `entity_definitions` before calling it (§6 OQ-1 states this
   explicitly rather than silently declaring it a non-issue).

---

## 5. Error taxonomy

| Failure mode | Returned from | Exact shape |
|---|---|---|
| Structural validation failure (REQ-225's 11 rules or the malformed-shape precondition) | `create_definition/2`, step 1 | `{:error, {:validation, [Letflow.Entities.Definition.Validator.violation()]}}` |
| Repository-level failure — invalid JSON, invalid schema name, version-number conflict after retries exhausted, or an `artifact_versions` changeset error | `create_definition/2`, step 3 | `{:error, {:repository, :invalid_json \| :invalid_schema_name \| :version_number_conflict \| Ecto.Changeset.t()}}` (the inner value is exactly whatever `Letflow.Repository.create/2` itself returned as its `{:error, reason}`'s `reason`) |
| `(tenant_id, name, logical_shape_version)` UNIQUE-constraint violation | `create_definition/2`, step 4 | `{:error, {:persistence, Ecto.Changeset.t()}}` — the changeset carries a `:name` error tagged `constraint: :unique, constraint_name: "entity_definitions_tenant_name_shape_idx"` (via `changeset/2`'s `unique_constraint/3` call, §3.2) |
| Invalid `prefix` (unresolvable tenant schema) | any function in `Letflow.Entities.Definitions` | `{:error, :invalid_schema_name}` — from `TenantProvisioning.tenant_id_for_schema_name/1`, propagated unchanged (matches every other function in this codebase that takes `prefix`) |
| Not found (`get_definition/2`, `get_definition_by_name/2`, or `activate_definition/4`'s internal lookup) | those functions | `{:error, :not_found}` |
| `list_definitions/2` page-size out of range | `list_definitions/2` | `{:error, :page_size_too_large}` |
| `list_definitions/2` cursor minted for a different endpoint | `list_definitions/2` | `{:error, :wrong_endpoint}` |
| `list_definitions/2` cursor past its mint-time expiry window | `list_definitions/2` | `{:error, :expired}` |
| `list_definitions/2` cursor otherwise malformed (bad base64, bad inner shape) | `list_definitions/2` | `{:error, :invalid_cursor}` |
| Activation-group-level failure (empty group, duplicate artifact, group/pointer changeset error) | `activate_definition/4` | whatever `Letflow.Repository.Activation.activate_group/5` itself returns, propagated unchanged — `{:error, :empty_group} \| {:error, :duplicate_artifact_in_group} \| {:error, :invalid_schema_name} \| {:error, {:group, Ecto.Changeset.t()}} \| {:error, {atom(), Ecto.Changeset.t()}}` |

No function in `Letflow.Entities.Definitions` raises on a well-typed, caller-triggerable
failure path — every fallible branch above returns a tagged tuple (matching
`Letflow.Api.Pagination`'s INV-8 convention, §0).

---

## 6. Open questions (stated explicitly, not silently resolved)

- **OQ-1 (from §4 Scenario B):** `create_definition/2`'s reuse of `Letflow.Repository.create/2`
  unmodified means a same-name/same-shape resubmission mints a redundant
  `artifact_versions` row before being rejected at the `entity_definitions` layer.
  Whether this is acceptable long-term (vs. adding a pre-check against
  `entity_definitions` before calling `create/2`) is left to REVIEWER/a future
  requirement — REQ-226's own acceptance criteria (AC4) only require the *outcome*
  (dedup at `repository_artifacts`, rejection at `entity_definitions`), not the
  absence of an intermediate redundant version row, so this design does not add a
  pre-check ELIXIR-DEV would have to invent unprompted.
- **OQ-2 (from §1.4):** whether `entity_definitions` should eventually get its own
  `BEFORE UPDATE`/`DELETE` immutability trigger (matching `repository_artifacts`/
  `artifact_versions`) is deferred — no update/delete path exists yet in this
  requirement's own scope, so there is nothing to structurally forbid today, but a
  future requirement adding one should read this note before assuming a trigger is
  either present or absent.
- **OQ-3:** whether `getDefinitionByName/2` should additionally accept a `status`
  filter (e.g., "get the currently active definition named X" as a single call
  instead of `get_definition_by_name/2` + a separate `Activation.resolve/3` call) is
  out of this requirement's own acceptance criteria (which name only
  `getDefinitionByName/2` with no status-filtering language) and is left unresolved
  rather than guessed at.

---

## 7. Traceability — acceptance criteria to design elements

| # | Acceptance criterion (abridged) | Design section |
|---|---|---|
| AC1 | `@artifact_kinds` includes `:entity` as an 8th value; all 7 existing values unmodified | §2 |
| AC2 | `createDefinition/2` rejects a structurally-invalid definition, creating neither an `artifact_versions` nor an `entity_definitions` row | §3.3 step 1 |
| AC3 | `createDefinition/2` for a valid definition calls `Repository.create/2` with `artifact_kind: :entity` and creates one `entity_definitions` row referencing the returned `artifact_version_id` | §3.3 steps 2-5, §3.2 |
| AC4 | Byte-identical content twice: same `repository_artifacts` row; two `entity_definitions` rows if names differ; UNIQUE-constraint rejection if name+shape match | §4 (both scenarios traced end-to-end), §1.3 (constraint), §5 (error shape) |
| AC5 | `listDefinitions/2` is tenant-scoped and paginates via REQ-067's cursor contract | §3.3 (`list_definitions/2`), §1.3 (supporting index) |
| AC6 | Activation reuses REQ-203's existing machinery, no new activation table/mechanism | §3.4, §1.4 |
| AC7 | No route or controller file added or modified | §3 as a whole — only `lib/letflow/entities/entity_definition.ex`, `lib/letflow/entities/definitions.ex`, `lib/letflow/repository/artifact_kind.ex`, and the migration are touched; no `lib/letflow/routers/` file is named anywhere in this design |
| AC8 | `mix test` and `mix compile --warnings-as-errors` both pass with real output quoted | Implementation-phase verification, not a design-time artifact — ELIXIR-DEV/TEST-RUNNER's job; this design imposes no construct (e.g., no unresolvable circular alias, no undefined behaviour) that would make either fail |
