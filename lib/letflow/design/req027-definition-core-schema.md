# Design: REQ-027 — Definition core schema (`process_definitions` + `instance_definition_snapshots`)

**Requirement:** REQ-027 (`docs/requirements.yaml:1141–1193`, stage S2, `depends_on: [REQ-022]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ027-20260816`, WF-02 Step 1
**This document produces:** migration shape, table/column/index/constraint detail,
`Ecto.Schema` module shape, `@spec`-style function signatures, invariants, verbatim
moduledoc text, traceability, contradictions found, open questions. **No implementation
code** — no function bodies, no `.ex`/`.exs` files, no migration files. ELIXIR-DEV writes
those from this document at Step 2a.

**Convention basis:** this requirement is the structural sibling of REQ-023 (merged as
PR #80). Migration file layout, the guard-pattern expression, moduledoc structure,
changeset naming, the "functions that will deliberately NOT exist" table, the
contradictions section and the traceability table are all reused from
`lib/letflow/design/req023-event-store-schema.md` rather than reinvented. Every place
this design *diverges* from that one is called out explicitly with its reason (§3.2.3,
§5.1's status-enum note, §10 C-3).

---

## 0. Sources read in full for this design

Every factual claim below carries a `file:line`-level citation. Nothing here is asserted
from memory, and nothing about Ecto's behaviour is assumed — every mechanic is cited to
this repo's own `deps/`.

**Letflow project docs**

- `docs/requirements.yaml` — REQ-027 (1141–1193), REQ-028 (1195–1233), REQ-029
  (1235–1285), REQ-030 (1287–1358), REQ-031 (1360–1406), REQ-032 (1408–1452), REQ-033
  (1454–1494), REQ-034 (1496–…), REQ-042 (PD-10 search, 1942–1990), and REQ-023's own
  entry (898–974) for the `tenant_id` precedent.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — **read in full.** Decision A
  (29–35), Decision B (37–45), Decision C (47–59); Dimension A reasoning incl. the two
  named abstraction swaps (98–112), Dimension B reasoning (114–243) incl. adp-02's
  `uq_definition_version` → `uq_definition_tenant_version` note (126–129) and the
  "Concrete Ecto/Postgres mechanics" paragraph (216–227), Dimension C point 3
  (284–294).
- `docs/guides/backend_developer_guide.md` — §3.1 naming (75–82), §3.5 error shapes
  (120–127), §3.6 SQL parameterization (129–133), §3.7 migrations (135–141), §5
  multi-tenancy (163–172).
- `docs/anti-patterns.md`, `docs/agents/instructions/core-directives.md`,
  `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1,
  `docs/agents/shared/HANDOFF_PROTOCOL.md`.
- `lib/letflow/design/req022-tenant-schema-provisioning.md` — §3.4
  `tenant_scoped_migrations/0` (326–338) and **§4, the mandatory guard pattern, read in
  full** (340–395), including its "both halves are mandatory" paragraph (389–395).
- `lib/letflow/design/req023-event-store-schema.md` — **read in full** (1185 lines).
  §2.2 guard shape (191–216), §2.4 the uncompiled-migration-module gap (225–273), §3's
  conventions preamble (277–296), §3.1.2's "deliberately NOT created" index discipline
  (363–383), §3.1.4 timestamp-type statement (413–424), §3.4's FK/`on_delete` reasoning
  (489–509), §4 migration file plan (616–670), §5.1 module plan (676–879), §5.2 the
  manifest edit (881–917), §6 invariants (921–937), §7 verbatim moduledocs (941–1018),
  §9 open questions (1039–1099), §10 contradictions (1103–1154), §11 traceability
  (1158–1185).

**Letflow shipped code (read directly, not assumed)**

- `lib/letflow/tenant_provisioning.ex` (328 lines) — `replay_migrations/2` (160–181),
  the `@tenant_scoped_migration_manifest` module attribute with its **seven** current
  entries (192–207), `tenant_scoped_migrations/0` (255–261), and the private
  `ensure_migration_module_loaded!/2` (266–276).
- `lib/letflow/definitions/graph.ex` — REQ-028's merged pure validator: moduledoc and
  purity statement (2–38), `node_type()` (40–48), nested `Node`/`Edge`/`Violation`
  structs (50–112), the `%Graph{nodes: [], edges: []}` struct and `t()` (122–126),
  `result()` (128), `@spec validate_graph(t()) :: result()` (136).
- `lib/letflow/event_store/instance_projection.ex` — the shipped precedent for
  `@primary_key`, `Ecto.Enum`, `timestamps/1` renaming and moduledoc structure.
- `priv/repo/migrations/20260816120003_create_instance_projections.exs` — the shipped
  guard + partial-index reference (35–56).
- `priv/repo/migrations/20260816120004_create_event_payload_store.exs` — the shipped
  `references/2` reference (60–89).
- `priv/repo/migrations/20260816000004_create_users.exs:33–57` — the shipped
  `add :id, :binary_id, primary_key: true` + `create unique_index(..., where: ...)`
  shape for a **non**-tenant-scoped table.
- `test/letflow/event_store/migrations_test.exs` — the two tests that will
  automatically police this requirement's migrations. See §4.4.
- `mix.exs:20–21` — `elixirc_paths(:test) -> ["lib", "test/support"]`,
  `elixirc_paths(_) -> ["lib"]`. Load-bearing for §5.3.
- `mix.lock:5–6` — the exact vendored versions this design's mechanics were verified
  against: `ecto 3.14.1`, `ecto_sql 3.14.0` (`postgrex 0.22.4` at `mix.lock:14`).

**Ecto / ecto_sql source, read directly from this repo's `deps/`**

- `deps/ecto_sql/lib/ecto/migration.ex:938–948` — the "Partial indexes" section: "The
  subset is defined by a conditional expression using the `:where` option. The `:where`
  option can be an atom or a string; its value is passed to the generated `WHERE` clause
  as-is."
- `deps/ecto_sql/lib/ecto/migration.ex:884–885` — `:where` listed as a supported option
  of `index/3`; `:name` at `:860–861`; `:prefix` at `:862`; `:unique` at `:863`.
- `deps/ecto_sql/lib/ecto/migration.ex:1048–1052` — `unique_index/3` **is** `index/3`
  with `[unique: true] ++ opts` prepended, so every `index/3` option (`:where`, `:name`,
  `:prefix`) is available on a partial *unique* index too. This is the exact mechanism
  §3.1.2's `uq_active_definition` needs.
- `deps/ecto_sql/lib/ecto/migration.ex:1734–1748` — `validate_index_opts!/1`: at most
  **one** `:where` keyword per index ("To specify multiple conditions, write a single
  WHERE clause using AND between them").
- `deps/ecto_sql/lib/ecto/migration.ex:509–520` — `%Ecto.Migration.Reference{}`
  defaults: `column: :id`, `type: :bigserial`, **`on_delete: :nothing`**,
  `on_update: :nothing`, `with: []`, `options: []`. The `type:` default is why §3.2.2's
  `references/2` call must pass `type: :binary_id` explicitly.
- `deps/ecto_sql/lib/ecto/migration.ex:1366–1376` — `timestamps/1`: defaults to
  `type: :naive_datetime` and `null: false`, accepts `:inserted_at`/`:updated_at` either
  renamed to another atom or set to `false`, plus a `:type` override, and merges
  `Runner.repo_config(:migration_timestamps, [])` (this repo sets none). It adds **no**
  DB-level default.
- `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1314–1348` — index DDL
  emission: `"CREATE "`, `if_do(index.unique, "UNIQUE ")`, `"INDEX "`,
  `quote_name(index.name)`, `" ON "`, `quote_name(index.prefix, index.table)`, the
  column list, and finally `if_do(index.where, [" WHERE ", to_string(index.where)])` at
  **:1344**. This is the line that proves a partial index's predicate reaches Postgres
  verbatim, and that `:prefix` is applied to the *table* reference in the `CREATE INDEX`
  statement.
- `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1862–1881` — `reference_expr/3`;
  **:1872** shows a `%Reference{}` with no `:prefix` in `ref.options` falling back to
  `table.prefix`, i.e. the FK target resolves inside the referencing table's own schema.
- `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1895–1896` —
  `reference_name(%Reference{name: nil}, table, column)` is
  `"#{table.name}_#{column}_fkey"`. For §3.2.2 this yields
  `instance_definition_snapshots_definition_id_fkey`, byte-identical to the name R-Co
  uses at `1106_iss0125_instance_definition_snapshots_cascade.sql:80`.
- `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1906–1918` —
  `reference_on_delete/1`: `:delete_all -> " ON DELETE CASCADE"`,
  `:restrict -> " ON DELETE RESTRICT"`, and the catch-all
  **`reference_on_delete(_), do: []`** at **:1918**. So `on_delete: :nothing` (the
  struct default) emits **no `ON DELETE` clause at all** — Postgres's default `NO
  ACTION`. This is REQ-027 acceptance criterion 4's exact mechanism.
- `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1708–1712` —
  `default_type(%{} = map, :map)` JSON-encodes a map default via the configured JSON
  library and single-quotes it. This is what makes §3.1.1's
  `default: %{"nodes" => [], "edges" => []}` legal on a `:map`/jsonb column.
- `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:2058–2075` — type mapping:
  `:binary_id -> uuid` (**:2063**), `:string -> varchar`, `:map -> jsonb` (the
  `:ecto_sql, :postgres_map_type` default), `:utc_datetime_usec -> timestamp`,
  `:naive_datetime -> timestamp`, and `ecto_to_db(atom) -> Atom.to_string(atom)` for
  anything else (so `:text` passes through as `text`, `:bigint` as `bigint`).
- `deps/ecto/lib/ecto/enum.ex:76–103` — `Ecto.Enum.init/1`. **:80–83**: a plain list of
  atoms is validated for uniqueness and mapped as
  `{:string, Enum.map(values, fn atom -> {atom, to_string(atom)} end)}` — i.e. `:active`
  dumps to the **lowercase** string `"active"`. **:85–88**: the keyword-list form maps
  each atom to an explicit stored value. §5.1 and §10 C-3 turn on this distinction.

**R-Co source of truth (`C:\Users\tvolo\dev\ai-dala\R-Co\`), read directly**

- `src/design/definition.md` (3189 lines) — module purpose (10–15), `NodeType` /
  `DefinitionStatus` / `GraphNode` / `GraphEdge` / `DefinitionGraph` / `Definition`
  shared types (23–100), `DefinitionError` set (177–198), `CreateParams` (200–209),
  `ListOpts` (211–221), `Store` interface (223–267), PD-01 data flow incl. the
  `ON CONFLICT (name, version)` note (292–327), **Database mapping** `Definition` ↔
  `process_definitions` (331–346), **Unique constraints table** (348–353),
  `instance_definition_snapshots` DB-mapping table (355–367), concurrency safety note
  (371–391), error taxonomy (394–412), the *placeholder* state-transition diagram
  (416–445), Key invariants 1–6 (469–477), PD-04's "Corrections to pre-PD-04 placeholder
  content" (506–513), PD-04 authoritative state transition table (558–570), the
  `deprecate()`/`archive()` guarded-UPDATE SQL patterns (572–599), PD-03 `Store.activate`
  (672–695), the PD-03 SQL transaction outline + ordering rationale (738–793), PD-07
  module purpose (1388–1395), `Store.getActiveByName` (1399–1433), `ListOpts.stage`
  (1437–1460), **PD-07 schema extension `014_definition_stage.sql` + design rationale**
  (1464–1495), PD-07 traceability (1793–1806) and PD-07 open-questions/downstream notes
  (1810–1823), **PD-08** module-file rationale (1834–1849), `SnapshotError` (1853–1880),
  `Snapshot` struct + DB column mapping (1884–1919), `SnapshotStore` (1923–1968), the
  create/get SQL patterns (1973–2025), **the "Atomicity guarantee" section including the
  `FK without ON DELETE CASCADE` paragraph (2029–2059)**, the EE-01 integration contract
  (2063–2086), PD-08 dependencies (2162–2177), PD-08 traceability (2181–2191), PD-10
  search SQL (2842–2867) and **"No new migration required"** (3008–3022).
- `migrations/004_definitions.sql` (69 lines) — read in full: `process_definitions` DDL
  (8–31) incl. `CONSTRAINT uq_definition_version UNIQUE (name, version)` (30),
  `uq_active_definition` (34–36), `idx_def_name` (38), `idx_def_status` (39),
  `idx_def_fts` (42–44), the `instance_definition_snapshots` header comment about the
  PER_TENANT classification and the unwanted `public` shadow (46–57), the snapshots DDL
  (59–66), `idx_snap_definition` (68–69).
- `migrations/014_definition_stage.sql` (4 lines) — read in full:
  `ADD COLUMN IF NOT EXISTS stage TEXT` (3) and
  `CREATE INDEX ... idx_def_stage ON process_definitions(stage) WHERE stage IS NOT NULL`
  (4).
- `migrations/028_adp02_tenant_scope_persistence.sql` — `tenant_id` added to
  `process_definitions` (15–16) and to five other tables but **not** to
  `instance_definition_snapshots` (15–31), the `bpm_effective_tenant_id()` default
  (4–13, 33), the drop of `uq_definition_version`/`uq_active_definition` (40–43), and
  their tenant-scoped replacements `uq_definition_tenant_version` /
  `uq_active_definition_tenant` / `idx_def_tenant_name_status` / `idx_def_tenant_created`
  (45–56).
- `migrations/1106_iss0125_instance_definition_snapshots_cascade.sql` (91 lines) — read
  in full. Header stating the original FK's "default NO ACTION referential action"
  (4–12), the stated fix and its rationale (14–18), the schema-placement note (20–30),
  and the DDL that drops and re-adds
  `instance_definition_snapshots_definition_id_fkey` **with `ON DELETE CASCADE`**
  (78–88). This is §10 C-1.
PROVENANCE (historical, not current decision authority):
- `src/definition/store.zig` — `CreateParams.stage` "Stored as NULL when omitted"
  (84–85), `ListOpts.stage` (94–95), `UpdateParams` (101–108), the real `create()`
  INSERT with bare `ON CONFLICT DO NOTHING` and its schema-variant comment (283–305),
  the `NULLIF($6, '')` stage binding (292, 303), the `stage = $N` list filter (439–446).
PROVENANCE (historical, not current decision authority):
- `src/definition/snapshot.zig` — the real `INSERT INTO instance_definition_snapshots …
  ON CONFLICT (instance_id) DO NOTHING` (155–184); confirmed it writes **no** tenant
  column.
- `src/design/adp-02-tenant-columns-definition-instance-audit.md` — the module purpose
  (1–5) and the "Table mapping (requirement term -> current schema object)" table
  (**15–21**), whose five rows are `process_definitions` (17), `instance_projections`
  (18), `tasks` (19), `tokens` (20) and `audit_entries`/`audit_log` (21) — it lists
  `process_definitions` (→ add `tenant_id`) and does **not** list
  `instance_definition_snapshots`.
- Verified by search, not assumption: **no** R-Co migration creates a
  `process_instances` table (`grep -rn "CREATE TABLE .*process_instances" migrations/`
  returns nothing, and no migration file mentions the identifier at all). Load-bearing
  for §10 C-7.

---

## 1. Scope boundary

**In scope (this requirement):** two tables, their two migrations, their two
`Ecto.Schema` modules under `lib/letflow/definitions/`, and the two-entry append to
`Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest` that REQ-022 §4
mandates for every tenant-scoped migration.

**Explicitly NOT in scope, and not silently dropped:**

| Not built here | Owned by | Citation |
|---|---|---|
| `Letflow.Definitions.Graph.validate_graph/1` and the 8 structural checks | REQ-028 — **already merged**, `lib/letflow/definitions/graph.ex` | `requirements.yaml:1195–1233` |
| `validate_node_attributes/1`, edge-condition rules, CEL syntax check | REQ-029 | `requirements.yaml:1235–1285` |
| `Letflow.Definitions` context CRUD — `create/1`, `get_by_id/1`, `get_active_by_name/1`, `list/1`, `activate/1`, `deprecate/1`, `archive/1` | REQ-030 | `requirements.yaml:1287–1358` |
| The SVC-03 service-scope activation hook | REQ-031 | `requirements.yaml:1360–1406` |
| Sub-process interface parsing (SPC-02) | REQ-032 | `requirements.yaml:1408–1452` |
| `Letflow.Definitions.SnapshotStore.create/2` and `get_by_instance_id/1`, and the write-once **enforcement** | REQ-033 | `requirements.yaml:1454–1494` |
| Export/import (PD-09) | REQ-034 | `requirements.yaml:1496–…` |
| `search/1` (PD-10) — and, per PD-10's own design, **no new table or index** for it | REQ-042 | `requirements.yaml:1942–1990`; `definition.md:3008–3022` |
| Any HTTP route / API surface | S4 | `requirements.yaml:1978–1981` |
| Instance-engine population of snapshots at instance start (EE-01) | S3 | `definition.md:2063–2086`; `requirements.yaml:1479–1487` |

REQ-027's own closing instruction — "Note explicitly in both moduledocs: this
requirement builds schema only" (`requirements.yaml:1183–1186`) — is discharged by the
verbatim moduledoc text in §7.1 and §7.2.

---

## 2. How these migrations reach a tenant schema (REQ-022 §4, both halves)

REQ-027 acceptance criterion 1 requires both tables to be "schema-per-tenant via
REQ-022's `:prefix` mechanism, applying cleanly" (`requirements.yaml:1188`).
`process_definitions` is a business table under Decision B's general rule — REQ-027 says
so in its own text (`requirements.yaml:1152–1154`), and R-Co independently classifies it
that way (`004_definitions.sql:49–51` classifies `instance_definition_snapshots` as
`PER_TENANT`; `0003:162–168` records the catalog-level proof that
`process_definitions` itself lives under per-tenant schemas in R-Co today).

### 2.1 The guard (half one) — mandatory

`Ecto.Migration.prefix/0` returns `nil` when the enclosing Migrator run was given no
`:prefix`, and `create table(:x)` with no explicit `prefix:` always targets the default
schema regardless of the run's prefix
(`req022-tenant-schema-provisioning.md:355–367`). A plain `mix ecto.migrate` — the
ordinary dev/CI/`mix test` bootstrap — runs *every* `.exs` in `priv/repo/migrations/`
with no prefix. Both of REQ-027's migrations must therefore be shaped like this
(**this is the shape, not literal code**):

```
change/0:
  if Ecto.Migration.prefix() is truthy:
      create table(<name>, primary_key: false, prefix: prefix()) with the columns in §3
      create every index in §3 with prefix: prefix()
  else:
      do nothing at all — this migration must have zero effect on the public schema
```

The shipped, working references for this exact shape are
`priv/repo/migrations/20260816120003_create_instance_projections.exs:38–55` and
`…20260816120004_create_event_payload_store.exs:63–88`.

Consequence, stated plainly so RELEASE-VALIDATOR does not chase it: a plain
`mix ecto.migrate` records both new versions in `public.schema_migrations` having created
nothing in `public`. That is harmless bookkeeping, exactly as
`req022-…md:384–387` anticipated.

### 2.2 The manifest registration (half two) — equally mandatory

`req022-tenant-schema-provisioning.md:389–395`: "a migration file that follows this guard
pattern but is *not* added to `tenant_scoped_migrations/0`'s list is inert forever …
A migration added to that list *without* the guard pattern actively corrupts `public` on
every plain `mix ecto.migrate` run." Both halves, or the requirement is defective. §5.3
specifies the manifest edit.

### 2.3 Index and constraint names under `:prefix`

Postgres index and constraint names are schema-scoped, not database-scoped. Two tenant
schemas may therefore each hold an index named `uq_active_definition` without collision,
and `public` holds none of them (the §2.1 guard skips the whole `change/0` body there).
Every explicit `name:` in §3 is chosen on that basis — R-Co's own names are preserved
verbatim, which Decision A endorses (`0003:98–103`).

---

## 3. Table specifications

Conventions applied throughout, matching `backend_developer_guide.md` §3.1/§3.7, the
shipped S1/REQ-023 migrations, and `req023-event-store-schema.md:277–296`:

- `create table(<name>, primary_key: false, prefix: prefix())` with explicit
  `add …, primary_key: true` columns.
- `snake_case` table and column names; R-Co's names preserved where they carry meaning
  (Decision A, `0003:98–103`).
- A `#`-comment header block above `defmodule` on every migration file (shipped
  convention: `20260816120003_create_instance_projections.exs:1–34`).
- **DB type** below is what the Postgres adapter actually emits, per
  `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:2058–2075`.
- `timestamps/1` (`deps/ecto_sql/lib/ecto/migration.ex:1366–1376`) adds **no** DB-level
  default; values come from `Ecto.Schema`'s autogeneration at insert time, matching every
  existing Letflow table. R-Co's `DEFAULT NOW()` on `created_at`/`updated_at`
  (`004:25–26`) is therefore **not** ported — a deliberate, project-wide convention, not
  an oversight.

### 3.1 `process_definitions`

Migration `20260816193001_create_process_definitions.exs` —
`Letflow.Repo.Migrations.CreateProcessDefinitions`.

| Column | Ecto migration type | DB type | Null / default | Notes & citation |
|---|---|---|---|---|
| `id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` (implied by PK) | Decision A's named swap: `UUID PRIMARY KEY DEFAULT gen_random_uuid()` (`004:9`) becomes Ecto's `binary_id` (`0003:104–107`). **No DB default** — the value is client-generated by `Ecto.Schema`'s `autogenerate: true`, matching every shipped Letflow table (`20260816000004_create_users.exs:34`). REQ-027 names `id (binary_id)` (`requirements.yaml:1155`). |
| `tenant_id` | `:binary_id` | `uuid` | `NOT NULL`, **no default** | 0003 Decision B retains `tenant_id` intra-schema "on the tables the adp-0x docs describe" (`0003:37–45`). `adp-02-tenant-columns-definition-instance-audit.md`'s own table mapping (lines 15–21) lists `process_definitions` as exactly such a table (row at line 17), and R-Co implements it at `028_adp02:15–16`. Unlike R-Co, **no `DEFAULT bpm_effective_tenant_id()`** (`028_adp02:16, 33`): Letflow has no reserved default-tenant UUID at all (`req022-…md`'s §3.3 established this). This is the same call REQ-023's design made for `events.tenant_id` (`req023-…md:314`). **See OQ-1** — REQ-030 must supply it. |
| `name` | `:string` | `varchar(255)` | `NOT NULL` | `004:10` (`TEXT NOT NULL`). REQ-027 says "name (string, <=255 chars)" (`requirements.yaml:1155`). `varchar(255)` is Ecto's `:string` default and *enforces* PD-01's documented bound ("name is empty or longer than 255 characters → HTTP 422", `definition.md:188–189`), which R-Co's `TEXT` only documented — a Decision A "comment becomes an enforced type" swap (`0003:104–109`). REQ-030 still validates pre-DB so the caller gets a typed `NameInvalid`-equivalent, not a Postgrex `22001`. |
| `version` | `:string` | `varchar(255)` | `NOT NULL` | `004:11` (`TEXT NOT NULL`); REQ-027 says "version (string)" (`requirements.yaml:1156`). **Stated divergence:** R-Co documents no upper bound on `version` (`definition.md:190–191` names only `VersionEmpty`), so `varchar(255)` newly bounds it. Accepted because 255 is generous for a version label and because `:string` is the literal reading of REQ-027's text; §5.2's `validate_length(:version, min: 1, max: 255)` turns the bound into a changeset error rather than a raw DB error. |
| `description` | `:text` | `text` | **nullable** | `004:12` (`TEXT`, no `NOT NULL`); REQ-027: "description (text, nullable)" (`requirements.yaml:1156`). `:text` is passed through unchanged by `ecto_to_db(atom)` (`connection.ex:2075`). Unbounded on purpose — PD-10's search matches against it (`definition.md:2863–2864`). |
| `status` | `:string` | `varchar(255)` | `NOT NULL`, `default: "draft"` | `004:15–16` (`TEXT NOT NULL DEFAULT 'DRAFT'`, with the four allowed values in a comment). Surfaced as Elixir atoms by `Ecto.Enum` (§5.1) — Decision A's second named swap (`0003:107–109`). **Stored lowercase**, unlike R-Co: see §10 C-3, which explains why the enum's dumped value and `uq_active_definition`'s predicate must agree or PD-03's invariant is silently unenforced. PD-04's `DefinitionStatus` set is `DRAFT/ACTIVE/DEPRECATED/ARCHIVED` (`definition.md:40–45`); REQ-027 names the lowercase atoms (`requirements.yaml:1156–1158`). |
| `stage` | `:string` | `varchar(255)` | **nullable**, no default | **REQ-027 acceptance criterion 3.** `014_definition_stage.sql:3` (`ADD COLUMN IF NOT EXISTS stage TEXT`). PD-07's rationale for nullability, quoted by REQ-027 itself: "The column is nullable so that existing rows are unaffected (no back-fill required)" (`definition.md:1467–1468, 1483`). **No enum, no validation** — "no enum validation is applied (stage labels are open-ended text per PD-07)" (`definition.md:1486–1487`). Same `varchar(255)` bounding note as `version`. |
| `graph` | `:map` | `jsonb` | `NOT NULL`, `default: %{"nodes" => [], "edges" => []}` | `004:19` (`JSONB NOT NULL DEFAULT '{"nodes":[],"edges":[]}'`). The shape is `definition.md:78–82`'s `DefinitionGraph`. A map default on a `:map` column is JSON-encoded and single-quoted by the adapter (`connection.ex:1708–1712`), so this is expressible without `fragment/1`. **Note:** the emitted JSON's key order comes from the encoder, not from the literal above; `jsonb` normalizes key order on storage regardless, so the stored value is identical to R-Co's. **No CHECK constraint** — see §3.1.3. |
| `created_by` | `:binary_id` | `uuid` | `NOT NULL` | `004:24`; `definition.md:207–208` ("Taken from auth middleware `ctx.actor.user_id`"). **No FK** — see §3.1.4. |
| `archived_at` | `:utc_datetime_usec` | `timestamp` (precision 6) | **nullable**, no default | `004:27` (`TIMESTAMPTZ`, nullable); `definition.md:97–98` ("Null until definition enters ARCHIVED status"); REQ-027: "archived_at (utc_datetime_usec, nullable)" (`requirements.yaml:1165–1166`). Set by REQ-030's `archive/1` (`definition.md:588–591`). |
| `created_at` | via `timestamps/1` | `timestamp` (precision 6) | `NOT NULL` | `timestamps(inserted_at: :created_at, type: :utc_datetime_usec)`. R-Co's column name is `created_at` (`004:25`), and preserving it keeps `ListOpts.after_created`'s cursor semantics legible (`definition.md:1450–1451`: "Cursor: return rows with `created_at` (UTC µs) strictly after this value"). The rename idiom is the one REQ-023 already shipped (`instance_projection.ex`'s `inserted_at: :started_at`). Microsecond type is not cosmetic: second precision would make cursor ties routine — see OQ-4. |
| `updated_at` | via `timestamps/1` | `timestamp` (precision 6) | `NOT NULL` | `004:26`. Every PD-03/PD-04 transition sets it (`definition.md:576, 590, 775, 782`). |

**Primary key:** `(id)` — a single `binary_id` surrogate key. REQ-027 names `id
(binary_id)` first in its column list and states no exception
(`requirements.yaml:1155`). No composite-PK concern applies here: 0003 Decision C point
2(a)'s `(event_id, created_at)` rule is scoped to the *event-store* tables it names
(`0003:264–283`), and `process_definitions` is an ordinary CRUD table under Decision A.

**Column order in the migration:** `id`, `tenant_id`, `name`, `version`, `description`,
`status`, `stage`, `graph`, `created_by`, `archived_at`, then `timestamps/1`. This
groups `stage` with the other definition-metadata columns rather than appending it last
as R-Co's `ALTER TABLE` history forced (`014:3`) — Letflow creates the table in one
statement, so R-Co's append-only column order carries no information.

#### 3.1.1 Timestamp type — an accurate statement, not a silent divergence

R-Co uses `TIMESTAMPTZ` (`004:25–27`). Ecto's `:utc_datetime_usec` maps to `timestamp`
*without* time zone (`connection.ex:2071`), and this repo sets no
`migration_timestamps: [type: :timestamptz]` (`timestamps/1` merges
`Runner.repo_config(:migration_timestamps, [])`, `migration.ex:1367`; the repo config is
empty). So the emitted DB type is `timestamp(6) without time zone`. This is safe because
`:utc_datetime_usec` normalizes every value to UTC on the way in and out. This is the
identical position `req023-event-store-schema.md:413–424` took, and the project-wide
question of moving to `timestamptz` remains that design's OQ-5 — restated here as OQ-7
because these two tables now also depend on it.

#### 3.1.2 Indexes on `process_definitions`

| Index name | Columns | Unique | Predicate | Why / citation |
|---|---|---|---|---|
| *(PK)* `process_definitions_pkey` | `(id)` | yes | — | Decision A surrogate PK; `004:9` |
| `uq_definition_version` | `(name, version)` | **yes** | — | **REQ-027 AC 2, first half.** R-Co declares it as a table constraint, `CONSTRAINT uq_definition_version UNIQUE (name, version)` (`004:30`), and `definition.md:352` names it "PD-01: duplicate rejection". See the constraint-vs-index note below. |
| `uq_active_definition` | `(name)` | **yes** | `WHERE status = 'active'` | **REQ-027 AC 2, second half.** R-Co: `CREATE UNIQUE INDEX … uq_active_definition ON process_definitions(name) WHERE status = 'ACTIVE'` (`004:34–36`); `definition.md:353` names it "PD-03: one active per name". Predicate case: **lowercase**, see §10 C-3. |
| `idx_def_stage` | `(stage)` | no | `WHERE stage IS NOT NULL` | **REQ-027 AC 3.** `014_definition_stage.sql:4`, verbatim. PD-07's rationale: "Partial index `WHERE stage IS NOT NULL` avoids indexing null entries and keeps the index compact" (`definition.md:1484–1485`). |
| `idx_def_status` | `(status)` | no | — | `004:39`. Serves REQ-030's `list/1` `?status=` filter (`requirements.yaml:1319–1322`; `definition.md:1447`). |

**How Ecto expresses each of these — verified against the vendored `ecto_sql 3.14.0`,
not assumed:**

- A **partial unique index** is `create unique_index(<table>, <columns>, name: …, where:
  "<predicate>", prefix: prefix())`. `unique_index/3` is literally `index/3` with
  `[unique: true]` prepended (`migration.ex:1048–1052`), so `:where`, `:name` and
  `:prefix` are all available on it; the predicate string is emitted verbatim after
  `" WHERE "` (`connection.ex:1344`), producing
  `CREATE UNIQUE INDEX "uq_active_definition" ON "<schema>"."process_definitions" (name) WHERE status = 'active'`.
- A **partial plain index** is the same call with `index/3` instead of
  `unique_index/3` — `create index(:process_definitions, [:stage], name: :idx_def_stage,
  where: "stage IS NOT NULL", prefix: prefix())`. The shipped precedent for this exact
  shape is `20260816120003_create_instance_projections.exs:49–53`.
- Only **one** `:where` keyword per index is permitted; multiple conditions must be a
  single `AND`-joined clause (`migration.ex:1739–1746`). Neither index here needs more
  than one.
- Every index takes its **own** `prefix: prefix()`; an index does not inherit the
  table's prefix (`connection.ex:1339` renders `quote_name(index.prefix, index.table)`
  from the `%Index{}`'s own field).

**Constraint vs. index — stated because it changes what a validator will see.** R-Co's
`uq_definition_version` is an `ALTER TABLE`-style table constraint (`004:30`); Ecto's
`create unique_index(...)` emits `CREATE UNIQUE INDEX`, **not**
`ALTER TABLE … ADD CONSTRAINT … UNIQUE`. `test/letflow/event_store/migrations_test.exs`
already documents this for REQ-023 ("the constraint views do not list it at all and a
test written against them would pass vacuously") and queries `pg_indexes` instead. The
practical consequences are all benign and all needed downstream:

1. Uniqueness enforcement is identical.
2. `Ecto.Changeset.unique_constraint/3` maps the 23505 error by **index name**, so
   `name: :uq_definition_version` in §5.2's changeset matches.
3. A unique index is a valid arbiter for `ON CONFLICT (name, version)` inference, which
   is what REQ-030's `create/1` needs (`definition.md:376–381`). See §10 C-5.

**Deliberately NOT created, each with its reason** (so their absence is a decision, not
an oversight — the discipline `req023-event-store-schema.md:363–383` established):

- `idx_def_name` on `(name)` (`004:38`) — **redundant.** `uq_definition_version` is a
  btree on `(name, version)` whose leading column is `name`, which Postgres can use for
  any `name`-only predicate. This follows the precedent
  `req022-tenant-schema-provisioning.md:138–142` set and REQ-023 applied to
  `idx_events_instance_seq` (`req023-…md:366–370`): "Not porting that redundancy is a
  Decision-A-consistent simplification."
- `idx_def_fts` — the GIN index over
  `to_tsvector('english', coalesce(name,'') || ' ' || coalesce(description,''))`
  (`004:42–44`, labelled "PD-10: full-text search"). **Not ported, on R-Co's own
  authority.** PD-10's design section "No new migration required" states "A new SQL
  migration is NOT needed for PD-10 … Correctness does not require a GIN index …
  The index can be introduced as a standalone migration in a future sprint"
  (`definition.md:3008–3022`), and PD-10's actual query is `name ILIKE $2 OR description
  ILIKE $2` (`definition.md:2862–2864`) — an `ILIKE` predicate **cannot use a
  `to_tsvector` GIN index at all**, so `idx_def_fts` is dead weight in R-Co itself.
  Letflow's own REQ-042 confirms the boundary: "this requirement adds no new table,
  reusing REQ-027's schema as-is" (`requirements.yaml:1953–1955`). See §10 C-2 and OQ-6.
- `uq_definition_tenant_version`, `uq_active_definition_tenant`,
  `idx_def_tenant_name_status`, `idx_def_tenant_created` (`028_adp02:45–56`) — **not
  ported.** Under Decision B the Postgres schema *is* the tenant boundary, so `tenant_id`
  has at most one distinct value per schema and a leading-`tenant_id` index degenerates
  to its non-tenant counterpart at strictly higher write cost. R-Co created these while
  its business tables still lived in shared `public` (`0003:144–147`). Crucially this
  loses **no** enforcement: within one tenant schema, `UNIQUE(name, version)` is exactly
  as strong as `UNIQUE(tenant_id, name, version)` would be, and
  `UNIQUE(name) WHERE status='active'` exactly as strong as
  `UNIQUE(tenant_id, name) WHERE status='active'`. REQ-027 AC 2 names the
  non-tenant-prefixed forms explicitly (`requirements.yaml:1189`), so this is also the
  literal reading. Same reasoning REQ-023 applied at `req023-…md:376–380`.

#### 3.1.3 No CHECK constraint on `graph`

REQ-027 builds "schema only … graph/node/edge structural validation (REQ-028/029) …
are separate requirements" (`requirements.yaml:1183–1186`). The 8 PD-02 checks live in
`lib/letflow/definitions/graph.ex`'s `validate_graph/1` as a **pure** function
(`graph.ex:136`, purity stated at `graph.ex:20–28`), and R-Co's Key invariant 1 puts
enforcement on the write path: "`graph.validateGraph()` MUST be called before every
INSERT or UPDATE touching the `graph` column. No bypass path exists"
(`definition.md:471`). A DB-level CHECK would create a second source of truth with a
different error shape and could not express CHK-01…CHK-08 anyway. Same position REQ-023
took on `byte_size > 4096` (`req023-…md:518–521`).

#### 3.1.4 Foreign keys on `process_definitions`: none, deliberately

- **`created_by` → `users.id`: no FK.** R-Co has none (`004:24` is a bare
  `UUID NOT NULL`). `users` lives in the public/default schema while
  `process_definitions` lives in a tenant schema, and this codebase's own convention
  already omits DB FKs from tenant-scoped rows to identity rows
  (`20260816000004_create_users.exs`; `req023-…md:409–411`).
- **`tenant_id` → `tenants.id`: no FK**, for the same cross-schema reason, and because
  the tenant identity is already carried structurally by the schema name.

### 3.2 `instance_definition_snapshots`

Migration `20260816193002_create_instance_definition_snapshots.exs` —
`Letflow.Repo.Migrations.CreateInstanceDefinitionSnapshots`. **Must sort after
`…193001`** (it carries a foreign key to `process_definitions`).

PROVENANCE (historical, not current decision authority):
| Column | Ecto migration type | DB type | Null / default | Notes & citation |
|---|---|---|---|---|
| `instance_id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` (implied by PK) | Natural PK, caller-supplied. `004:60` (`UUID PRIMARY KEY`); `definition.md:1888–1890, 1914`. REQ-027: "instance_id (binary_id, primary key)" (`requirements.yaml:1174`). **No DB default** — the instance id is minted by the engine (S3), never by this row. `ON CONFLICT (instance_id) DO NOTHING` (REQ-033) arbitrates on this PK (`definition.md:1999`; `snapshot.zig:168`). |
| `definition_id` | `:binary_id` + `references(...)` | `uuid` | `NOT NULL` | **REQ-027 AC 4.** `004:61` (`UUID NOT NULL REFERENCES process_definitions(id)`); `definition.md:1891–1892, 1915`. FK detail in §3.2.2. |
| `definition_name` | `:string` | `varchar(255)` | `NOT NULL` | `004:62` (`TEXT NOT NULL`); "Denormalised for human readability in logs/reports" (`definition.md:364`, `1894–1896`). `varchar(255)` mirrors `process_definitions.name`'s own bound — a snapshot copies that column, so a wider type would be unreachable. |
| `definition_ver` | `:string` | `varchar(255)` | `NOT NULL` | `004:63`; `definition.md:365, 1897–1899`. R-Co's abbreviated column name `definition_ver` (not `definition_version`) is preserved verbatim per Decision A (`0003:98–103`) — renaming it would break cross-referencing for zero gain. |
| `graph` | `:map` | `jsonb` | `NOT NULL`, **no default** | `004:64` (`JSONB NOT NULL`, and note: **no** `DEFAULT`, unlike `process_definitions.graph`). Correct and deliberate: a snapshot is always a copy of a real definition's graph, so an empty-graph default would mask a capture bug. `definition.md:1900–1903, 1918`. |
| `snapshotted_at` | `:utc_datetime_usec` | `timestamp` (precision 6) | `NOT NULL`, `default: fragment("(now() AT TIME ZONE 'utc')")` | `004:65` (`TIMESTAMPTZ NOT NULL DEFAULT NOW()`); `definition.md:1904–1906, 1919`. R-Co's `INSERT` omits the column and lets the default fill it, reading it back via `RETURNING` (`definition.md:1995–2006`) — Letflow does the same via `read_after_writes: true` (§5.1). The default is written as `(now() AT TIME ZONE 'utc')` rather than bare `now()` so an implicit `timestamptz → timestamp` cast can never pick up the session's local time zone — the identical mitigation `req023-…md:420–423` applied. |

**Primary key:** `(instance_id)` — natural, caller-supplied.

**No `timestamps/1` on this table, deliberately.** REQ-027: "No `updated_at`/
`timestamps()` beyond `snapshotted_at` — the table is write-once per PD-08"
(`requirements.yaml:1179–1182`). R-Co has no such columns either (`004:59–66`). An
`updated_at` on a write-once table would be actively misleading.

PROVENANCE (historical, not current decision authority):
**No `tenant_id` on this table, deliberately.** Decision B retains `tenant_id` "on the
tables the adp-0x docs describe" (`0003:37–45`). `adp-02`'s own table mapping (lines
15–21) lists `process_definitions`, `instance_projections`, `tasks`, `tokens`,
`audit_entries` and `audit_log` — **not** `instance_definition_snapshots` — and
`028_adp02:15–31` correspondingly adds the column to those six tables and not to this
one. No later R-Co migration adds it either (verified by grep across
`migrations/*.sql`), and `snapshot.zig:155–184`'s real INSERT writes no tenant column.
This is the same selective application REQ-023 made — `events`/`events_archive`/
`instance_projections` got `tenant_id`; `instance_sequence`/`event_payload_store`/
`event_idempotency` did not (`req023-…md:§3.2, §3.4, §3.5`).

#### 3.2.1 Indexes on `instance_definition_snapshots`

| Index name | Columns | Unique | Predicate | Why / citation |
|---|---|---|---|---|
| *(PK)* `instance_definition_snapshots_pkey` | `(instance_id)` | yes | — | `004:60`. Also the `ON CONFLICT (instance_id)` arbiter REQ-033 needs (`definition.md:1999`). |
| `idx_snap_definition` | `(definition_id)` | no | — | `004:68–69`, verbatim. **Load-bearing, not decorative:** Postgres does not automatically index the *referencing* side of a foreign key, and without this index every `DELETE FROM process_definitions` must sequentially scan this table to evaluate the FK's `NO ACTION` check. REQ-033 AC 4 exercises exactly that delete path (`requirements.yaml:1492`). |

No other index. R-Co has none (`004:59–69` in full).

#### 3.2.2 The foreign key — REQ-027 acceptance criterion 4

**Shape:**
`add :definition_id, references(:process_definitions, column: :id, type: :binary_id, on_delete: :nothing), null: false`

Each element, with its verified mechanism:

- `type: :binary_id` is **mandatory, not stylistic**: `%Reference{}`'s default `type` is
  `:bigserial` (`migration.ex:513`), which would emit an `integer`-typed column and fail
  against a `uuid` primary key.
- `column: :id` is the `%Reference{}` default (`migration.ex:512`) but is written
  explicitly, matching the shipped precedent
  (`20260816120004_create_event_payload_store.exs:70`).
- **No `:prefix` option on `references/2`.** A `%Reference{}` whose `options` carry no
  `:prefix` falls back to the referencing table's own prefix
  (`connection.ex:1872`), so the FK resolves to
  `"<tenant_schema>"."process_definitions"` automatically. Passing one explicitly would
  work but is redundant.
- **`on_delete: :nothing`** — this is the whole of acceptance criterion 4.
  `reference_on_delete/1` has explicit clauses only for `:nilify_all`, `:default_all`,
  `:delete_all` (`" ON DELETE CASCADE"`) and `:restrict`
  (`" ON DELETE RESTRICT"`); everything else falls to
  `reference_on_delete(_), do: []` at `connection.ex:1918`. So the emitted DDL carries
  **no `ON DELETE` clause whatsoever**, which is Postgres's default `NO ACTION` — the
  exact referential action R-Co's original `004:61` produced, as R-Co's own later
  migration confirms in its root-cause paragraph: "declared `definition_id UUID NOT NULL
  REFERENCES process_definitions(id)` with the default NO ACTION referential action"
  (`1106_iss0125_…:4–6`).
- `on_delete: :nothing` is also the struct default (`migration.ex:514`), so writing it
  explicitly changes no DDL byte. It is written explicitly **because acceptance
  criterion 4 is precisely about the absence being deliberate** — an omitted option reads
  as an oversight, a written `:nothing` reads as a decision.
- **Constraint name:** left to Ecto's default, which is
  `"#{table.name}_#{column}_fkey"` (`connection.ex:1895–1896`) =
  `instance_definition_snapshots_definition_id_fkey`. That is byte-identical to the name
  R-Co uses (`1106_iss0125_…:80, 85`), so §5.2's `foreign_key_constraint/3` and any
  `information_schema` cross-check line up with R-Co's without a custom `name:`.

#### 3.2.3 Why `:nothing` here and not `:restrict` — divergence from REQ-023, explained

REQ-023's sibling design chose `on_delete: :restrict` for `event_payload_store`, and
that choice was a deliberate **divergence from R-Co**, taken because R-Co's `CASCADE`
there would have silently destroyed archived payloads and because R-Co's own evidence
had gone stale (`req023-…md:498–509`). Neither condition holds here:

- R-Co's *original*, design-doc-endorsed shape for **this** FK is already `NO ACTION`,
  which is already the behaviour PD-08 wants — nothing needs correcting.
- `NO ACTION` and `RESTRICT` both reject a `DELETE` of a referenced parent row. They
  differ only in deferrability (`RESTRICT` is checked immediately and can never be
  deferred; `NO ACTION` can be deferred if the constraint is declared `DEFERRABLE`).
  Nothing in REQ-027, REQ-030 or REQ-033 asks for a deferred check, and choosing the
  strictly less flexible one for no reason would be a gratuitous divergence.
- Choosing `:nothing` makes Letflow's DDL byte-identical to `004:61`, which is what
  REQ-027 asked for ("cross-check every column and index against these rather than
  inventing a shape").

Both options satisfy AC 4's literal text ("no ON DELETE CASCADE"). This design picks the
one that matches the ported source.

#### 3.2.4 No FK on `instance_id`, deliberately

`definition.md:362` claims `instance_id` is an "FK to `process_instances.id`". This is
wrong twice over, verified rather than assumed:

1. `004:60` declares `instance_id UUID PRIMARY KEY` with **no `REFERENCES` clause** at
   all.
2. **No `process_instances` table exists anywhere in R-Co** — a search across all 146
   `migrations/*.sql` returns no `CREATE TABLE` for it and no mention of the identifier.
   R-Co's instance table is `instance_projections` (`001_event_store.sql:81`; REQ-023
   ported it).

Letflow follows the SQL, not the prose. Even setting the missing table aside, an FK to
`instance_projections` would be actively wrong: PD-08's EE-01 contract requires
`SnapshotStore.create()` to run **before** the `InstanceStarted` event is appended
(`definition.md:2069–2081`), so the snapshot row can legitimately precede any projection
row. This is §10 C-7.

---

## 4. Migration file plan

Two files, one table per file, per Decision A's "one schema-defining concern per
migration via the `Ecto.Migration` DSL" (`0003:29–35`). Both live in
`priv/repo/migrations/` as AC 1 requires, both use the §2.1 guard, and both are
registered in the §5.3 manifest.

| # | Filename | Migration module | Creates | Ordering constraint |
|---|---|---|---|---|
| 8 | `20260816193001_create_process_definitions.exs` | `Letflow.Repo.Migrations.CreateProcessDefinitions` | `process_definitions` + 4 indexes (§3.1.2) | must precede #9 (FK target) |
| 9 | `20260816193002_create_instance_definition_snapshots.exs` | `Letflow.Repo.Migrations.CreateInstanceDefinitionSnapshots` | `instance_definition_snapshots` + FK + 1 index (§3.2) | **after #8** |

(The `#` column continues REQ-023's numbering of manifest entries 1–6 and REQ-024's 7 —
see §5.3.)

### 4.1 Filename ↔ module ↔ version: three hard constraints

The two literal timestamp values above are this design's proposal; ELIXIR-DEV may
substitute real UTC-clock timestamps generated at implementation time, subject to:

- **(a)** every value sorts strictly after `20260816163103` (REQ-024's shipped
  migration, the current maximum in `priv/repo/migrations/`);
- **(b)** the relative order in the table above is preserved (#8 before #9);
- **(c)** the **same integers** appear in the §5.3 manifest, **and** each filename's
  non-numeric part equals `Macro.underscore/1` of the module's last segment. This is not
  a style preference — `test/letflow/event_store/migrations_test.exs`'s manifest test
  computes `expected_basename = "#{version}_#{Macro.underscore(List.last(Module.split(module)))}.exs"`
  and asserts both that the module was loaded from that basename and that the file
  exists. `CreateProcessDefinitions` → `create_process_definitions` and
  `CreateInstanceDefinitionSnapshots` → `create_instance_definition_snapshots`, which is
  why the filenames above read exactly as they do.

### 4.2 `:prefix` threading — exactly where it goes

In each file's `change/0`, inside the `if prefix() do … end` guard:

- `create table(<name>, primary_key: false, prefix: prefix())`.
- `create index(...)` / `create unique_index(...)` — **each one** takes its own
  `prefix: prefix()`; an index does not inherit the table's prefix
  (`connection.ex:1339`).
- `references(:process_definitions, ...)` inside #9 takes **no** `:prefix` option — it
  inherits the referencing table's prefix automatically (`connection.ex:1872`).
- The `else` branch does nothing whatsoever.

### 4.3 Reversibility

Every operation used (`create table`, `create index`, `create unique_index`,
`references/2` inside a `create table`) is auto-reversible by `change/0`
(`backend_developer_guide.md:137–141`). **No `execute/1`, no `execute/2`, no raw SQL** in
either file. The one `fragment/1` (`snapshotted_at`'s default, §3.2) is a column-default
expression, not a statement, and is reversible with the table.

### 4.4 Two shipped tests will police these migrations mechanically

Design decisions above were made with both in mind; ELIXIR-DEV must expect them to run
unchanged.

1. **The §4 guard test** —
   `test/letflow/event_store/migrations_test.exs`, describe block
   *"§4 guard pattern — every registered tenant-scoped migration is a real no-op without
   a prefix"*. It iterates `TenantProvisioning.tenant_scoped_migrations()`, runs each
   entry through `Ecto.Migrator.run/4` under a synthetic probe version **with no
   `:prefix`**, and asserts `public_tables() == tables_before`. A missing or broken
   guard on either new migration fails this test the moment §5.3's manifest entries land
   — it needs no edit to cover them.
2. **The manifest version↔filename consistency test** — same file, describe block
   *"`tenant_scoped_migrations/0` manifest consistency"*. It asserts each entry's module
   is loaded, that `module_info(:compile)[:source]`'s basename equals
   `"#{version}_#{Macro.underscore(last_module_segment)}.exs"`, that the file exists in
   `priv/repo/migrations/`, and (second test) that versions are unique and strictly
   ascending. §4.1's three constraints are exactly what this test checks.

Neither test is modified by this requirement. TEST-DESIGNER's own REQ-027 additions are
Step 3's business; the point here is that a guard omission or a version/filename
mismatch now fails the suite mechanically rather than being caught by review.

### 4.5 Demonstrating acceptance criterion 1

(Method only; ELIXIR-DEV at Step 2a and TEST-DESIGNER at Step 3 write the code.) Call
`Letflow.TenantProvisioning.provision_tenant_schema/1` for a real tenant id, then
`replay_migrations/1` with the default source, then assert both tables exist under that
schema and **not** under `public`:

```
SELECT table_name FROM information_schema.tables WHERE table_schema = $1
  -- $1 = the provisioned schema name; expect process_definitions
  --      and instance_definition_snapshots present
SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'
  -- expect neither present
```

Index shape is checked against `pg_indexes` (`indexname`, `indexdef`), **not**
`information_schema.table_constraints` — Ecto emits `CREATE UNIQUE INDEX`, which the
constraint views do not list, so a test written against them would pass vacuously
(§3.1.2; the shipped `indexes_on/2` helper in
`test/letflow/event_store/migrations_test.exs` already does this). The three
partial/unique predicates in AC 2 and AC 3 are verifiable by asserting on `indexdef`'s
`WHERE …` suffix.

---

## 5. Module plan

### 5.1 `Ecto.Schema` modules — `lib/letflow/definitions/`

REQ-027 creates **schema modules only**. No `lib/letflow/definitions.ex` context module
is created here; `Letflow.Definitions` is REQ-030's artefact and
`Letflow.Definitions.SnapshotStore` is REQ-033's (`requirements.yaml:1296, 1463`).

| Module | File | Table |
|---|---|---|
| `Letflow.Definitions.ProcessDefinition` | `lib/letflow/definitions/process_definition.ex` | `process_definitions` |
| `Letflow.Definitions.InstanceDefinitionSnapshot` | `lib/letflow/definitions/instance_definition_snapshot.ex` | `instance_definition_snapshots` |

Both mirror their table names (singularized). **`InstanceDefinitionSnapshot`, not
`Snapshot`** — a reasoned divergence from R-Co's own struct name
(`definition.md:1887`): S2 also contains promotion *digests* and promotion *reviews*
(REQ-035/037), so a bare `Letflow.Definitions.Snapshot` would be ambiguous inside the
same namespace, and REQ-033's context module is already `SnapshotStore`, which would sit
confusingly close to a `Snapshot` row struct. This is the same table↔module naming
judgement `req023-…md:690–694` recorded for `StoredPayload`/`IdempotencyRecord`.

**Settings common to both modules:**

- `@primary_key {:id, :binary_id, autogenerate: true}` on `ProcessDefinition` (matching
  every existing Letflow schema, e.g. `lib/letflow/tenant_provisioning/registration.ex`);
  `@primary_key {:instance_id, :binary_id, autogenerate: false}` on
  `InstanceDefinitionSnapshot` — natural, caller-supplied PK, `autogenerate: false`
  deliberate because the instance id is minted by S3's engine, never by this row (the
  same call REQ-023 made for `InstanceSequence`/`InstanceProjection`,
  `req023-…md:702–704`).
- **No `@foreign_key_type`** — neither module declares a `belongs_to`/`has_many`
  association (see below), so nothing consults it. Declaring it would be inert.
- **No `belongs_to :definition`** on `InstanceDefinitionSnapshot` even though a real DB
  FK exists. This codebase's established convention is a plain `field(:x, Ecto.UUID)`
  even where a DB-level FK is present (`registration.ex`, `identity/tenant_role.ex`;
  `req023-…md:705–707`). An association would also invite `Repo.preload/2` across the
  snapshot→definition edge, which is precisely the coupling PD-08 exists to break: a
  snapshot is meaningful *without* its source definition (`definition.md:2055–2059`).
- **No `@schema_prefix`.** These tables live in *many* schemas, one per tenant; pinning
  a single prefix at compile time would be wrong. Every query and write must pass
  `prefix: schema_name` at call time — REQ-030/REQ-033's responsibility, stated here as
  INV-DEF-7 (§6).
- `@type t :: %__MODULE__{}` on each module.
- UUID-typed non-primary-key columns are declared `field(:x, Ecto.UUID)`, matching every
  existing occurrence in this codebase.

**Field declarations** (declarations only — not code blocks):

`Letflow.Definitions.ProcessDefinition` — `schema "process_definitions"`:

```
field(:tenant_id, Ecto.UUID)
field(:name, :string)
field(:version, :string)
field(:description, :string)
field(:status, Ecto.Enum, values: [:draft, :active, :deprecated, :archived], default: :draft)
field(:stage, :string)
field(:graph, :map, default: %{"nodes" => [], "edges" => []})
field(:created_by, Ecto.UUID)
field(:archived_at, :utc_datetime_usec)
timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
```

Notes ELIXIR-DEV must not lose:

- `description` is `:string` at the *schema* layer even though the *migration* type is
  `:text`. Ecto has no `:text` schema type; `:string` is the correct Elixir-side type for
  any character column. (`:text` is a migration-only type, passed through by
  `connection.ex:2075`.)
- **`Ecto.Enum` uses the bare atom-list form, not REQ-023's keyword-mapping form.** With
  a plain list of atoms, `Ecto.Enum.init/1` maps each atom to `to_string(atom)`
  (`deps/ecto/lib/ecto/enum.ex:80–83`), so `:active` is stored as the lowercase string
  `"active"` — which is what makes `uq_active_definition`'s `WHERE status = 'active'`
  predicate actually match rows. REQ-023's `InstanceProjection.status` uses
  `values: [active: "ACTIVE", …]` to preserve R-Co's uppercase; **this design
  deliberately does not**, and §10 C-3 states why in full. This is the one place REQ-027
  knowingly departs from its sibling design's convention.
- `graph`'s schema-level `default:` mirrors the DB default so a freshly-built
  `%ProcessDefinition{}` struct is already `{"nodes": [], "edges": []}`-shaped, matching
  `definition.md:78–82`. Keys are strings, not atoms — the value round-trips through
  jsonb.
- `timestamps(inserted_at: :created_at, type: :utc_datetime_usec)` — the schema macro
  accepts the same `:inserted_at` rename and `:type` override as the migration macro;
  the shipped precedent is `lib/letflow/event_store/instance_projection.ex`'s
  `timestamps(inserted_at: :started_at, type: :utc_datetime_usec)`.

`Letflow.Definitions.InstanceDefinitionSnapshot` —
`schema "instance_definition_snapshots"`:

```
field(:definition_id, Ecto.UUID)
field(:definition_name, :string)
field(:definition_ver, :string)
field(:graph, :map)
field(:snapshotted_at, :utc_datetime_usec, read_after_writes: true)
```

(`instance_id` is the `@primary_key`.) `read_after_writes: true` on `snapshotted_at`
because the value is assigned by the column's DB default, never by the changeset —
mirroring R-Co, whose INSERT omits the column and reads it back via `RETURNING`
(`definition.md:1995–2006`). This is the same mechanism `req023-…md:738–739` used for
`global_seq`. **No `graph` default here** (§3.2). **No `timestamps/1`.**

### 5.2 Function signatures — every function that will exist, fully specified

Error shape: these are changeset builders. None of them touches the database, so none
returns an `{:ok, _} | {:error, _}` tuple — the `{:ok, struct} | {:error, changeset}`
boundary is `Repo.insert/2`/`Repo.update/2`'s, inside REQ-030's and REQ-033's context
modules (`backend_developer_guide.md:120–127`). Each function below returns an
`Ecto.Changeset.t()` which is either `valid?: true` or carries field errors; a DB
constraint violation surfaces later, at `Repo.insert/2`, as
`{:error, %Ecto.Changeset{}}` **only because** the `unique_constraint`/
`foreign_key_constraint` declarations listed below are present — without them the same
violation raises `Ecto.ConstraintError`. That distinction is the error contract REQ-030
and REQ-033 depend on, so it is stated here rather than left implicit.

```
# Letflow.Definitions.ProcessDefinition
@type t :: %Letflow.Definitions.ProcessDefinition{}
@type status :: :draft | :active | :deprecated | :archived

@spec create_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast:              [:tenant_id, :name, :version, :description, :stage, :graph, :created_by]
#   validate_required: [:tenant_id, :name, :version, :graph, :created_by]
#   validate_length(:name,    min: 1, max: 255)   -- PD-01 NameInvalid, definition.md:188-189
#   validate_length(:version, min: 1, max: 255)   -- PD-01 VersionEmpty + the varchar bound, §3.1
#   validate_length(:stage,   max: 255)           -- the varchar bound, §3.1; no value check (PD-07 open-ended)
#   unique_constraint([:name, :version], name: :uq_definition_version)
#   unique_constraint(:name, name: :uq_active_definition)
#   NOTE: :status is deliberately NOT castable here. PD-01 hard-codes DRAFT
#         ("the `params` struct carries no `status` field", definition.md:472;
#         REQ-030: "hard-codes status: draft (caller cannot override)",
#         requirements.yaml:1304-1305). The typed InitialStatusNotDraft error for a
#         caller who supplies one is REQ-030's params-level check, not this changeset's
#         -- see OQ-5.
#   NOTE: :id, :created_at, :updated_at, :archived_at are not castable.

@spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast:              [:name, :version, :description, :stage, :graph]
#   validate_required: [:name, :version, :graph]
#   same three validate_length calls and the same two unique_constraint declarations
PROVENANCE (historical, not current decision authority):
#   Field list mirrors R-Co's UpdateParams exactly (store.zig:101-108:
#   name/version/description/graph/stage) -- notably NO :status, NO :tenant_id,
#   NO :created_by. Status movement is a guarded UPDATE, not a changeset; see the
#   "will NOT exist" table below.
```

```
# Letflow.Definitions.InstanceDefinitionSnapshot
@type t :: %Letflow.Definitions.InstanceDefinitionSnapshot{}

@spec create_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast:              [:instance_id, :definition_id, :definition_name, :definition_ver, :graph]
#   validate_required: all five
#   validate_length(:definition_name, min: 1, max: 255)
#   validate_length(:definition_ver,  min: 1, max: 255)
#   unique_constraint(:instance_id, name: :instance_definition_snapshots_pkey)
#       -- turns a duplicate-instance_id insert into {:error, changeset} rather than a
#          raised Ecto.ConstraintError, which is what lets REQ-033 return its
#          SnapshotAlreadyExists-equivalent (definition.md:1860-1863). REQ-033 may
#          instead use ON CONFLICT (instance_id) DO NOTHING (definition.md:1991-1999);
#          both paths need this table's PK and this design supplies it either way.
#   foreign_key_constraint(:definition_id, name: :instance_definition_snapshots_definition_id_fkey)
#       -- turns a dangling definition_id into {:error, changeset} rather than a raised
#          error, which is what lets REQ-033 return DefinitionNotFound
#          (definition.md:1857-1859). The constraint name is Ecto's own default for this
#          table/column pair (connection.ex:1895-1896), §3.2.2.
#   NOTE: :snapshotted_at is deliberately NOT castable -- supplied by the column default
#         and read back via read_after_writes (§5.1).
```

**Functions that will deliberately NOT exist** — this list is normative; REVIEWER and
CODE-DESIGN-VALIDATOR should treat any of them appearing in Step 2a's output as a defect.

| Absent function | Module | Why |
|---|---|---|
| `update_changeset/2` | `InstanceDefinitionSnapshot` | **REQ-027's write-once rule.** "The table is write-once per PD-08 (no UPDATE path is exposed at the schema-module layer …)" (`requirements.yaml:1179–1182`); PD-08: "Snapshots read-only after creation; no API endpoint permits modification" (`definition.md:2189`); "Subsequent definition updates MUST NOT modify snapshot … `SnapshotStore` exposes only `create()` and `getByInstanceId()`" (`definition.md:2186`). **Enforcement scope, stated because REQ-027 says so explicitly: the absence of this function is all this requirement provides; runtime enforcement is REQ-033's job, not this migration's** (`requirements.yaml:1180–1182`). Ecto migrations have no "no updates" DDL primitive — the same application-layer-not-migration-layer position 0003 Decision C point 1 records for `events` (`0003:254–262`). |
| `changeset/2` (generic) | both modules | A generically-named changeset invites reuse on the wrong path. `create_changeset/2` / `update_changeset/2` make each legal use site explicit — REQ-023's precedent (`req023-…md:869`). |
| any status-mutating changeset (`activate_changeset/1`, `status_changeset/2`, …) | `ProcessDefinition` | PD-03/PD-04 transitions are **guarded single-statement UPDATEs**, not changeset-mediated read-modify-writes: `UPDATE … SET status='DEPRECATED' WHERE id=$1 AND status='ACTIVE' RETURNING *` (`definition.md:574–581`), `… AND status='DEPRECATED'` for archive (`definition.md:587–595`), and activate's `SELECT … FOR UPDATE` two-step swap (`definition.md:745–788`). The `WHERE status = <expected>` clause **is** the concurrency control; a changeset load-then-update would reintroduce the lost-update race those clauses exist to prevent. This is the identical argument REQ-023 used to omit `InstanceSequence.update_changeset/2` (`req023-…md:873`). REQ-030 owns the transition table (`requirements.yaml:1336–1341`). |
| `transition_allowed?/2` or any transition-table helper | `ProcessDefinition` | REQ-030's explicit scope: "enforce the authoritative state transition table" (`requirements.yaml:1336–1341`). Adding it here would preempt a dependent requirement — scope creep. (Contrast REQ-023's `InstanceProjection.terminal?/1`, which existed because *that* requirement's own text needed one authoritative predicate; REQ-027's text needs none.) |
| `delete_changeset/1`, any `delete_*` | both modules | Nothing in REQ-027 or REQ-030's function list defines a delete path — see OQ-5. |
| any `Repo.*` call or query function | both modules | REQ-027 is schema-only; querying and writing belong to REQ-030 / REQ-033 (`requirements.yaml:1183–1186`). |

`ProcessDefinition.update_changeset/2` **does** exist while
`InstanceDefinitionSnapshot`'s does not, and that asymmetry is the point: a definition is
an ordinary mutable CRUD row (Decision A), a snapshot is immutable by design (PD-08).

### 5.3 The one edit to `Letflow.TenantProvisioning`

`@tenant_scoped_migration_manifest` currently holds **seven** entries
(`lib/letflow/tenant_provisioning.ex:192–207`): REQ-023's six event-store migrations plus
REQ-024's `event_type_registry`. REQ-027 **appends entries eight and nine, preserving all
seven**, in the same `{version, module, filename}` three-element form:

```
{20_260_816_193_001, Letflow.Repo.Migrations.CreateProcessDefinitions,
 "20260816193001_create_process_definitions.exs"},
{20_260_816_193_002, Letflow.Repo.Migrations.CreateInstanceDefinitionSnapshots,
 "20260816193002_create_instance_definition_snapshots.exs"}
```

Constraints on this edit:

- **`tenant_scoped_migrations/0`'s `@spec` is unchanged** —
  `[{version :: pos_integer(), module()}]` (`tenant_provisioning.ex:255`). The manifest's
  third element never escapes the function; it is consumed by the private
  `ensure_migration_module_loaded!/2` (`tenant_provisioning.ex:266–276`) and dropped by
  the `Enum.map/2` at `:257–260`. No shipped public contract changes.
- **The three-element form is mandatory, not decorative.** `Ecto.Migrator` resolves a
  `{version, module}` source through `load_migration!/1`, which requires
  `Code.ensure_loaded?(module)`, but `priv/repo/migrations/*.exs` is never compiled into
  the application (`mix.exs:20–21` sets `elixirc_paths` to `["lib"]`). A bare
  `{version, module}` entry therefore raises `Ecto.MigrationError` against an
  already-migrated database — the real defect REQ-023 found and fixed
  (`req023-…md:225–273`; the full rationale is in `tenant_scoped_migrations/0`'s own
  `@doc` at `tenant_provisioning.ex:224–253`). Adding entries in the bare form would
  reintroduce it.
- Entries stay in **ascending version order** — the manifest's own header comment says so
  (`tenant_provisioning.ex:183–186`) and
  `test/letflow/event_store/migrations_test.exs`'s second manifest test asserts it.
- The manifest's header comment (`tenant_provisioning.ex:188–191`) and
  `tenant_scoped_migrations/0`'s `@doc` (`:209–223`) both enumerate which requirement
  contributes which entries and say "seven entries in total". **Both must be updated to
  nine** — a stale count there is documentation drift that this requirement introduces
  and must therefore fix.

No other shipped REQ-022 code changes.

---

## 6. Invariants

| id | Invariant | Enforced where | Source |
|---|---|---|---|
| INV-DEF-1 | **At most one row per `(name, version)`** within a tenant schema. | `uq_definition_version` (§3.1.2) + `unique_constraint/3` (§5.2) | `004:30`; `definition.md:352`; REQ-027 AC 2 |
| INV-DEF-2 | **At most one `active` row per `name`** within a tenant schema (PD-03's single-active-per-name). Enforced at the *migration* layer as a partial unique index, independent of REQ-030's `activate/1` logic. | `uq_active_definition` (§3.1.2) | `004:34–36`; `definition.md:353, 1403–1404`; REQ-027 AC 2 and its own note that the index is needed "even though `activate()` itself is REQ-030's job, since the index is a migration-level constraint" (`requirements.yaml:1169–1171`) |
| INV-DEF-3 | **The `uq_active_definition` predicate string and the `status` enum's dumped value must be the same literal.** If they ever diverge, the index silently matches zero rows and INV-DEF-2 is unenforced with no error anywhere. Both are `'active'` / `:active` → `"active"`. | §3.1.2 predicate + §5.1's bare-atom `Ecto.Enum` | `deps/ecto/lib/ecto/enum.ex:80–83`; `connection.ex:1344`; §10 C-3 |
| INV-DEF-4 | **`stage` is open-ended free text**; no enum, no allowed-value list, no check constraint. Only a length bound and nullability are enforced. | §3.1 column + §5.2's `validate_length(:stage, max: 255)` only | `definition.md:1486–1487`; `requirements.yaml:1161–1163` |
| INV-DEF-5 | **A snapshot survives its source definition.** `instance_definition_snapshots.definition_id` carries **no** `ON DELETE CASCADE`; deleting a referenced definition is rejected, and the snapshot's captured `graph`/`definition_name`/`definition_ver` are never removed or rewritten by anything that happens to the source row. | §3.2.2 FK (`on_delete: :nothing`) | `004:61`; `definition.md:2051–2059`; `1106_iss0125_…:4–6`; REQ-027 AC 4; REQ-033 AC 4 (`requirements.yaml:1492`) |
| INV-DEF-6 | **Snapshots are write-once at the schema-module layer.** `InstanceDefinitionSnapshot` exposes `create_changeset/2` and nothing else; no update or delete path exists on the module. Runtime enforcement is REQ-033's. | §5.2's absent-functions table | `requirements.yaml:1179–1182`; `definition.md:2186, 2189` |
| INV-DEF-7 | **No `@schema_prefix` on either module.** Every read and write must pass `prefix: schema_name` explicitly, where `schema_name` comes from a `tenant_schemas` registry row. | §5.1; REQ-030/REQ-033 call sites | 0003 Decision B (`0003:37–45, 216–227`) |
| INV-DEF-8 | **`status` is never `cast/4`-able from caller input.** Neither changeset casts it; the column's `draft` default is the only way a row acquires an initial status, and transitions happen only through REQ-030's guarded UPDATEs. | §5.2 | `definition.md:472` (Key invariant 2); `requirements.yaml:1304–1305` |
| INV-DEF-9 | **Graph validation is never bypassed on a write.** No DB constraint expresses it; the invariant is that REQ-030's `create/1`/`update` call `Graph.validate_graph/1` (and REQ-029's attribute validator) before any INSERT/UPDATE touching `graph`. Recorded here because REQ-027 owns the column. | REQ-030's call path; `lib/letflow/definitions/graph.ex:136` | `definition.md:471` (Key invariant 1) |
| INV-DEF-10 | **No raw-SQL identifier interpolation is introduced by REQ-027.** Both migrations use the `Ecto.Migration` DSL with `prefix: prefix()`; the prefix value originates from `Registration.schema_name`, which REQ-022 constrains to `tenant_[0-9a-f]{32}` by construction. The single `fragment/1` is a constant string with no interpolation. | §4; `tenant_provisioning.ex:111–123` | `backend_developer_guide.md:129–133`; INV-7 |

---

## 7. Required moduledoc text (verbatim)

REQ-027 acceptance criteria 4 and 5, plus REQ-027's own "note explicitly in both
moduledocs" instruction (`requirements.yaml:1183–1186`), each require a specific claim in
a specific moduledoc. The text below is what must appear, quoted so
CODE-DESIGN-VALIDATOR, REVIEWER and RELEASE-VALIDATOR can check it **literally** rather
than by paraphrase. ELIXIR-DEV may add surrounding prose but must not weaken or omit
these sentences.

### 7.1 `Letflow.Definitions.ProcessDefinition` — acceptance criterion 5 + the scope note

```
Ported from R-Co's `src/design/definition.md` — the PD-01 sections (module
purpose, `Store.create`, the `Definition` ↔ `process_definitions` database
mapping, and the `uq_definition_version` / `uq_active_definition` unique
constraints table) and the PD-07 section (the nullable free-text `stage`
column and its `idx_def_stage` partial index, whose SQL is R-Co's
`migrations/014_definition_stage.sql`). The table DDL this schema reads is
ported from R-Co's `migrations/004_definitions.sql`.

This requirement (REQ-027) builds schema only. Graph/node/edge structural
validation is REQ-028 (`Letflow.Definitions.Graph`, already merged) and
REQ-029; CRUD operations — `create/1`, `get_by_id/1`, `get_active_by_name/1`,
`list/1`, `activate/1`, `deprecate/1`, `archive/1` — are REQ-030; the
snapshot create/retrieve functions are REQ-033. Those are separate
requirements building on this table. Do not read this module as the
definition store landing early.

`status` is an `Ecto.Enum` over the lowercase atoms `:draft`, `:active`,
`:deprecated` and `:archived`, stored as the lowercase strings `"draft"`,
`"active"`, `"deprecated"` and `"archived"`. This deliberately diverges from
R-Co, which stores the uppercase `DRAFT`/`ACTIVE`/`DEPRECATED`/`ARCHIVED`
(`migrations/004_definitions.sql`). The stored string is load-bearing: the
`uq_active_definition` partial unique index carries PD-03's
single-active-per-name invariant through the predicate
`WHERE status = 'active'`, and if the enum's dumped value and that predicate
ever disagree the index silently matches no rows and the invariant is
unenforced with no error anywhere. Changing either one without the other is a
defect.
```

### 7.2 `Letflow.Definitions.InstanceDefinitionSnapshot` — acceptance criteria 4 and 5

```
Ported from R-Co's `src/design/definition.md` PD-08 section (the definition
snapshot: `SnapshotStore`, the `Snapshot` struct's DB column mapping, and the
"Atomicity guarantee" section), with the table DDL from R-Co's
`migrations/004_definitions.sql`. The PD-01 and PD-07 sections of the same
document are the ported source for `process_definitions`, the table this one
references — see `Letflow.Definitions.ProcessDefinition`.

`definition_id` references `process_definitions.id` with NO ON DELETE
CASCADE. This is deliberate, per PD-08's "FK without `ON DELETE CASCADE`"
paragraph: "Deletion of the source definition does NOT automatically remove
snapshot rows. Snapshot rows persist with their captured `graph`,
`definition_name`, and `definition_ver` regardless of what happens to the
source definition." It is what satisfies PD-08's edge case: "Definition
hard-deleted (DRAFT) after instances were started from it: instances retain
their snapshot and continue normally." Adding `on_delete: :delete_all` here
would destroy exactly the data this table exists to preserve, and would break
REQ-033's fourth acceptance criterion.

R-Co itself later replaced this FK with an ON DELETE CASCADE variant in
`migrations/1106_iss0125_instance_definition_snapshots_cascade.sql`, whose
own header gives the reason as a test-harness cleanup-ordering problem
("bespoke per-test cleanup helpers that swallowed SQL errors"), not a design
change — and that migration directly contradicts the PD-08 design text quoted
above. Letflow follows PD-08's design and does NOT port that migration.

This table is write-once. This module deliberately exposes no
`update_changeset/2`, no generic `changeset/2`, and no delete path — per
PD-08, "Snapshots read-only after creation; no API endpoint permits
modification." The absence of those functions is the whole of what REQ-027
provides; runtime enforcement of the write-once rule is REQ-033's job, not
this migration's.

This requirement (REQ-027) builds schema only. The snapshot create/retrieve
functions (`Letflow.Definitions.SnapshotStore`) are REQ-033, and the EE-01
instance-start integration point that calls them is S3 scope, not built here.
```

### 7.3 Additional moduledoc content (not acceptance-criteria-driven, but required by this design)

- **Both modules** must state INV-DEF-7 (no `@schema_prefix`; callers pass
  `prefix: schema_name` on every read and write).
- `ProcessDefinition` must state INV-DEF-8 (`status` is not castable; `create_changeset/2`
  cannot set it) and name REQ-030 as the owner of the PD-04 transition table.
- `ProcessDefinition` must state that `stage` is open-ended free text with no enum
  validation (INV-DEF-4), citing PD-07.
- `InstanceDefinitionSnapshot` must state that `instance_id` carries **no** foreign key,
  and why (§3.2.4 — R-Co's SQL has none, no `process_instances` table exists, and PD-08's
  EE-01 ordering requires the snapshot to be creatable before any instance row).

---

## 8. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Repo` | schemas → Repo | Only at REQ-030/REQ-033 call time. REQ-027 adds no `Repo` call of its own. |
| `Letflow.TenantProvisioning` | REQ-027 → REQ-022 | **REQ-027 appends two entries to `@tenant_scoped_migration_manifest`** (§5.3) and updates that attribute's header comment and `tenant_scoped_migrations/0`'s `@doc` from "seven entries" to nine. No `@spec` changes. |
| `Letflow.TenantProvisioning.Registration` | REQ-030/033 → REQ-022 | Source of the `schema_name` every definition query must pass as `prefix:` (INV-DEF-7). |
| `priv/repo/migrations/` | REQ-027 → shared directory | Adds two files. Modifies none of the fourteen existing migrations. |
| `test/letflow/event_store/migrations_test.exs` | tests → REQ-027 | Its §4-guard test and its manifest-consistency test begin covering REQ-027's migrations automatically once §5.3's entries land (§4.4). Not modified by this requirement. |
| `Letflow.Definitions.Graph` (REQ-028, merged) | REQ-030 → REQ-028 | Operates on the `graph` column this design defines. Contract point: `Graph.validate_graph/1` takes a `%Letflow.Definitions.Graph{nodes: [Node.t()], edges: [Edge.t()]}` **struct** (`graph.ex:122–136`), while this column stores a plain `:map` with **string** keys. REQ-030 owns the map↔struct conversion at the boundary; REQ-027 deliberately does not introduce an `Ecto.Type` for it (see OQ-3). |
| REQ-029 (node-attribute / edge-condition validators) | REQ-030 → REQ-029 | Same `graph` column; same map↔struct boundary. |
| REQ-030 (`Letflow.Definitions` CRUD) | REQ-030 → REQ-027 | Consumes `process_definitions`. Contract points REQ-030 must honour: **(a)** `tenant_id` is `NOT NULL` with no DB default — REQ-030 must supply it from the auth context (OQ-1); **(b)** `status` is not castable — `create/1` relies on the column default and returns its own `InitialStatusNotDraft`-equivalent (OQ-5); **(c)** transitions are guarded single-statement UPDATEs, not changesets (§5.2); **(d)** `ON CONFLICT (name, version)` infers `uq_definition_version` (§3.1.2, §10 C-5); **(e)** `get_active_by_name/1` may rely on `uq_active_definition` guaranteeing 0-or-1 rows (`definition.md:1403–1404, 1432–1433`); **(f)** the `after_created` cursor runs against `created_at` (OQ-4). |
| REQ-033 (`Letflow.Definitions.SnapshotStore`) | REQ-033 → REQ-027 | Consumes `instance_definition_snapshots` **and** `process_definitions` (its `SELECT … FOR SHARE` read, `definition.md:1978–1986`). Contract points: **(a)** `snapshotted_at` comes from the DB default and is read back (`read_after_writes`); **(b)** the PK is the `ON CONFLICT (instance_id)` arbiter; **(c)** the FK's `NO ACTION` means a delete of a referenced definition is *rejected*, which changes how REQ-033 AC 4 must be demonstrated (OQ-2); **(d)** no update path exists on the schema module, and enforcing that at runtime is REQ-033's. |
| REQ-042 (PD-10 search) | REQ-042 → REQ-027 | Consumes `process_definitions` including `stage`, and adds **no** migration or index — confirmed by both `definition.md:3008–3022` and `requirements.yaml:1953–1955`. §3.1.2 records why `idx_def_fts` is not created here either. |
| S3 / EE-01 (`src/engine/` port) | S3 → REQ-027 | Calls REQ-033's `create/2` at instance start, before any event is appended (`definition.md:2069–2081`). Not built here. |
| `docs/agents/instructions/security-invariants.md` INV-7 | SECURITY-REVIEWER → REQ-027 | Satisfied by INV-DEF-10: REQ-027 introduces zero raw-SQL identifier interpolation. |

---

## 9. Open questions — explicitly listed, not silently resolved

**OQ-1 (MAJOR, addressed to REQ-030) — RESOLVED 2026-08-17, see
[0003's addendum](../../../docs/migration/decisions/0003-ecto-schema-strategy.md#addendum-2026-08-17--tenant_id-population-on-write).**
Originally: nothing in REQ-030's text said who supplies `tenant_id`. This design gives
`process_definitions.tenant_id` `null: false` with **no DB default**, following 0003
Decision B (`0003:37–45`), adp-02's table mapping, and the precedent REQ-023 set for
`events.tenant_id` (`req023-…md:314`). R-Co avoids the question entirely by defaulting
the column to `bpm_effective_tenant_id()`, which reads a session GUC (`028_adp02:4–16,
33`) — a mechanism Letflow has no equivalent of, and `req022-…md`'s §3.3 already recorded
that Letflow has no reserved default-tenant UUID. Filed as
[ISS-0025](../../../docs/issues/ISS-0025.yaml) (GitHub #83) rather than resolved here,
since it is a schema-population *policy* question this design's own scope doesn't own.
**Resolution:** `create/1` does **not** accept `tenant_id` as a plain caller-supplied
field. It derives the value from the Ecto `:prefix` (tenant schema) the write already
targets, reversing REQ-022's `Letflow.TenantProvisioning.schema_name_for_tenant/1`
encoding — chosen over a caller-supplied field specifically because a derived value
cannot disagree with the schema it's written into (a caller-supplied field can, which is
an attribution defect the 0003 addendum's security analysis covers in full). REQ-030's
`docs/requirements.yaml` entry and acceptance criteria were updated accordingly.

**OQ-2 (MAJOR, addressed to REQ-033): its fourth acceptance criterion cannot be
demonstrated the way it is worded.** REQ-033 AC 4 reads: "deleting the source
`process_definitions` row (**where FK rules permit, e.g. a DRAFT definition**) does not
remove or invalidate an existing snapshot row" (`requirements.yaml:1492`). Under the
`NO ACTION` FK this design specifies — which is what REQ-027 AC 4 requires and what R-Co's
`004:61` actually declares — **no** delete of a referenced definition ever succeeds,
DRAFT or otherwise; Postgres raises a `foreign_key_violation` (23503). So the criterion's
parenthetical describes a case that does not exist. The behaviour is still correct and
still satisfies PD-08's intent (the snapshot survives, a fortiori), but REQ-033's test
must assert the delete is **rejected** and the snapshot row still readable afterwards,
not that the delete succeeds. Flagged rather than silently reinterpreted, because a
test written to the criterion's literal wording would fail against a correct schema.

**OQ-3 (MINOR, addressed to REQ-030/REQ-029): who converts the `graph` jsonb map into
`Letflow.Definitions.Graph`'s struct form?** REQ-028 shipped a struct-typed validator —
`validate_graph/1` accepts `%Graph{nodes: [%Node{}], edges: [%Edge{}]}` with atom
`node_type` values (`graph.ex:40–48, 122–136`) — while this column stores a plain map
with string keys (`{"nodes": [...], "edges": [...]}`, `definition.md:78–82`). Three
candidate homes for the conversion: (a) a custom `Ecto.Type` on the `graph` field, so
loading a row yields a `%Graph{}` directly; (b) an explicit `Graph.from_map/1` /
`to_map/1` pair in REQ-029 or REQ-030; (c) inline conversion at each REQ-030 call site.
This design deliberately takes option **none-of-the-above-yet**: it declares the field as
a plain `:map`, because REQ-027 is schema-only and introducing an `Ecto.Type` here would
bind REQ-029/REQ-030 to a conversion contract neither has designed. Naming it so
REQ-030's designer resolves it explicitly rather than discovering it mid-build.

**OQ-4 (MINOR, addressed to REQ-030): the `after_created` cursor can skip rows.**
`ListOpts.after_created` is documented as "return rows with `created_at` (UTC µs)
**strictly after** this value" (`definition.md:1450–1451`), and REQ-030 ports it
(`requirements.yaml:1322–1324`). `created_at` is not unique, so two definitions created in
the same microsecond straddling a page boundary cause the second to be skipped forever.
This design mitigates but does not solve it by choosing `:utc_datetime_usec` rather than
second precision (§3.1), which is also what R-Co does. A real fix is a composite cursor
`(created_at, id)` with a row-value comparison — a REQ-030 API decision (it changes the
opaque cursor's encoding), not a schema one. Recorded, not resolved.

PROVENANCE (historical, not current decision authority):
**OQ-5 (MINOR, addressed to REQ-030): `""` vs `NULL` for `stage`, and the
`InitialStatusNotDraft` path.** Two small semantics R-Co settles in code that this
design does not encode:
(a) R-Co's `create()` binds `params.stage orelse ""` and wraps it in `NULLIF($6, '')`
(`store.zig:292, 303`), so an explicitly-supplied empty-string stage is indistinguishable
from an omitted one and both land as `NULL` — which matters because `idx_def_stage`'s
predicate is `WHERE stage IS NOT NULL` (§3.1.2). Letflow's changesets do **not** perform
that normalization; if REQ-030 wants R-Co's behaviour it must normalize `""` → `nil`
explicitly. (Verified, not assumed: `definition.md:1494` and `store.zig:84–85` both say
"stored as NULL when omitted", and the `NULLIF` is what makes that true — this initially
reads as a contradiction and is not one.)
(b) PD-01 returns `InitialStatusNotDraft` when a caller supplies a status
(`definition.md:186–187, 400`). `create_changeset/2` cannot produce that error because it
does not cast `:status` at all — a supplied status is silently ignored rather than
rejected. REQ-030 must reject it at its own params boundary if the typed error is wanted.

**OQ-6 (MINOR): no requirement owns a hard-delete path for `process_definitions`.**
PD-08's edge case and REQ-033's AC 4 both presuppose that a DRAFT definition can be
hard-deleted (`definition.md:2058–2059`; `requirements.yaml:1492`), and R-Co's own
`1106_iss0125_…:6–12` describes real `DELETE FROM process_definitions` traffic. But
REQ-030's function list (`requirements.yaml:1300–1341`) has no `delete/1`, and no other
Letflow requirement defines one — the lifecycle's terminal state is `archived` with
`archived_at` set, not deletion. So the FK's referential action currently guards a path
no shipped code takes. Not a defect (the constraint is correct either way, and the
schema must be right before a delete path exists), but the gap should be closed
deliberately: either a requirement adds `delete/1`, or REQ-033's AC 4 is restated in
terms of archival rather than deletion.

**OQ-7 (MINOR, inherited): should Letflow's repo move to `timestamptz` project-wide?**
R-Co uses `TIMESTAMPTZ` throughout (`004:25–27`, `004:65`); Letflow's
`:utc_datetime_usec` emits `timestamp` without time zone (§3.1.1). This is
`req023-event-store-schema.md`'s OQ-5, still open and now affecting two more tables. Not
re-filed as a new issue — restated so it is visible to whoever eventually decides it,
since the blast radius grows with every table added under the current setting. This
design applies the same `(now() AT TIME ZONE 'utc')` mitigation REQ-023 used, on the one
column with a timestamp default.

**OQ-8 (INFORMATIONAL): the GIN full-text index is deferred, not forgotten.** §3.1.2
does not create `idx_def_fts`, on PD-10's own instruction. PD-10 also states the index
"can be introduced as a standalone migration in a future sprint … without any change to
the API contract" (`definition.md:3021–3022`) — but only if PD-10's `ILIKE` query is
replaced by a `to_tsvector`/`to_tsquery` one at the same time, since an `ILIKE`
predicate cannot use a tsvector GIN index. Recorded so a future performance change knows
it is a two-part change, not a one-line migration.

---

## 10. Contradictions found between R-Co's design doc and R-Co's actual source

REQ-027 instructed this design to cross-check `definition.md` against R-Co's real SQL and
Zig and to say so explicitly where they disagree, rather than glossing over it. Seven
disagreements were found. Each is resolved in favour of whichever source Letflow's own
requirements and decision records point at, and the reason is stated.

**C-1 (the important one) — R-Co's current SQL contradicts PD-08's central design claim:
the snapshot FK *is* `ON DELETE CASCADE` in R-Co today.**
`definition.md:2051–2059` states the FK "carries no `ON DELETE CASCADE`", that "Deletion
of the source definition does NOT automatically remove snapshot rows", and that this
"directly satisfies the PD-08 edge case: *Definition hard-deleted (DRAFT) after instances
were started from it: instances retain their snapshot and continue normally*"; its
traceability table repeats the claim (`definition.md:2190`). `004:61` matches the prose.
But `migrations/1106_iss0125_instance_definition_snapshots_cascade.sql:78–88` **drops and
re-adds** `instance_definition_snapshots_definition_id_fkey` **with `ON DELETE CASCADE`**,
so R-Co's live schema now destroys snapshots when their definition is deleted — the exact
outcome PD-08 says must not happen. The migration's own header gives the motivation as a
test-cleanup ordering problem — "bespoke per-test cleanup helpers that swallowed SQL
errors could silently proceed to `DELETE FROM process_definitions` after a failed child
delete, producing C23503" (`1106:8–12`) — and rationalizes it with a claim that
*contradicts* PD-08 directly: "The snapshot is an immutable copy of the graph at instance
start, so the parent row's identity has no meaning without its children once the parent
is gone" (`1106:14–18`).
**Letflow follows PD-08's prose and does not port 1106.** This is not a judgement call:
REQ-027 AC 4 mandates no cascade (`requirements.yaml:1191`) and REQ-033 AC 4 mandates the
surviving-snapshot behaviour (`requirements.yaml:1492`). Recorded prominently because a
future agent cross-checking Letflow against R-Co's *live* schema will find a cascade
there and could "fix" Letflow into data loss. §7.2's moduledoc text states this in the
code itself so the divergence is discoverable without reading this file.

**C-2 — `004_definitions.sql` creates a full-text index PD-10 says it doesn't need and
PD-10's own query cannot use.** `004:41–44` creates
`idx_def_fts … USING GIN (to_tsvector('english', coalesce(name,'') || ' ' ||
coalesce(description,'')))` under the comment "PD-10: full-text search on name +
description". PD-10's own design section says the opposite: "A new SQL migration is NOT
needed for PD-10 … Correctness does not require a GIN index … A GIN index … would improve
search performance … but is a performance optimisation, not a correctness requirement"
(`definition.md:3008–3022`) — and PD-10's actual query is
`WHERE name ILIKE $2 OR description ILIKE $2` (`definition.md:2862–2864`), which **cannot
use a `to_tsvector` GIN index at all**. So the index is dead weight in R-Co itself: it is
maintained on every write and read by nothing. Not ported (§3.1.2); Letflow's REQ-042
independently confirms "this requirement adds no new table, reusing REQ-027's schema
as-is" (`requirements.yaml:1953–1955`). See OQ-8.

**C-3 — status case: R-Co stores uppercase, Letflow stores lowercase. Deliberate,
and the one place this design departs from REQ-023's convention.**
R-Co: `status TEXT NOT NULL DEFAULT 'DRAFT'` with `DRAFT | ACTIVE | DEPRECATED |
ARCHIVED` (`004:15–16`), `uq_active_definition … WHERE status = 'ACTIVE'` (`004:36`), and
`DefinitionStatus` as an uppercase Zig enum (`definition.md:40–45`). REQ-023's sibling
design preserved R-Co's uppercase for `instance_projections.status` by using
`Ecto.Enum`'s keyword-mapping form, `values: [active: "ACTIVE", …]`
(`req023-…md:766–777`; shipped at `lib/letflow/event_store/instance_projection.ex`).
REQ-027 goes the other way, for one decisive reason: **REQ-027's own acceptance criterion
2 specifies the predicate literal `WHERE status = 'active'`** (`requirements.yaml:1189`)
and its description names the lowercase atoms "draft/active/deprecated/archived, default
draft" (`requirements.yaml:1156–1158`). The enum's dumped value and the index predicate
must be the same literal or `uq_active_definition` matches zero rows and PD-03's
single-active-per-name invariant is **silently unenforced** — no error, no failing query,
just an index that never fires (INV-DEF-3). Given that constraint, the two are not
independently choosable, and the requirement's own text picks lowercase. The bare
atom-list `Ecto.Enum` form dumps `:active` as `"active"`
(`deps/ecto/lib/ecto/enum.ex:80–83`), so lowercase everywhere is internally consistent.
Consequence for anyone comparing databases: a Letflow `process_definitions` row's
`status` reads `active`, an R-Co one reads `ACTIVE`; the Elixir-side atom is `:active` in
both readings, so no application code differs. §7.1's moduledoc text records this in the
code.

**C-4 — `definition.md` contradicts itself on the permitted state transitions, and
already admits it.** The top-level "State transitions" section lists `DRAFT → ARCHIVED`
and `ACTIVE → ARCHIVED` as permitted (`definition.md:435–441`). PD-04's "Corrections to
pre-PD-04 placeholder content" section says that is wrong — "The placeholder incorrectly
listed `DRAFT→ARCHIVED` and `ACTIVE→ARCHIVED` as permitted transitions. The authoritative
PD-04 rule is: **only DRAFT→ACTIVE, ACTIVE→DEPRECATED, and DEPRECATED→ARCHIVED are
permitted**" (`definition.md:506–512`) — and the authoritative table at
`definition.md:558–570` marks every other cell `✗ HTTP 409`. Nothing in REQ-027 encodes
transitions (no DB constraint expresses them), so this changes nothing here, but it is
recorded because REQ-030 must use the **corrected** table. Letflow's REQ-030 text already
does (`requirements.yaml:1336–1341` lists exactly the three permitted edges), so no
action is needed — only confirmation that the stale diagram is not the source to follow.

PROVENANCE (historical, not current decision authority):
**C-5 — `ON CONFLICT` target: the design doc names one, the code omits it.**
`definition.md:376–381` specifies
`INSERT … ON CONFLICT (name, version) DO NOTHING RETURNING *`. R-Co's actual
`store.zig:290` uses a bare `ON CONFLICT DO NOTHING` with no target, and explains why at
`:283–286`: "schema variants may define uniqueness as either `(name, version)` or
`(tenant_id, name, version)`. Using DO NOTHING without a conflict target keeps behaviour
idempotent across both variants." That ambiguity does not exist in Letflow: §3.1.2 defines
exactly one `(name, version)` uniqueness shape and deliberately does not create the
tenant-prefixed variant. So REQ-030 should use the **targeted** form the design doc
specifies — it names the arbiter explicitly, and a untargeted `DO NOTHING` would also
swallow a `uq_active_definition` conflict, silently returning
`DuplicateNameVersion` for a completely different violation. Forward note for REQ-030;
nothing in REQ-027 changes either way.

PROVENANCE (historical, not current decision authority):
**C-6 — checked and cleared, recorded because it reads like a contradiction.**
`definition.md:1494` and `store.zig:84–85` both say `stage` is "stored as NULL when
omitted", while `store.zig:303` binds `params.stage orelse ""` — an empty string, not
null. The SQL resolves it: `store.zig:292` wraps the parameter in `NULLIF($6, '')`, so the
empty string becomes `NULL` in the column. Not a contradiction. Recorded because it
matters directly to `idx_def_stage`'s `WHERE stage IS NOT NULL` predicate and because the
behavioural detail it *does* imply — an explicitly-supplied `""` is indistinguishable
from an omitted stage — is not carried into Letflow's changesets (OQ-5a).

**C-7 — the snapshot design doc claims an FK to a table that does not exist.**
`definition.md:362` lists `instance_id` as "FK to `process_instances.id`". `004:60`
declares it as a bare `UUID PRIMARY KEY` with no `REFERENCES` clause, and **no
`process_instances` table exists in R-Co at all** — a search across all 146
`migrations/*.sql` finds no `CREATE TABLE` for it and no occurrence of the identifier.
R-Co's instance table is `instance_projections`. Letflow follows the SQL (§3.2.4). Beyond
the missing table, an FK here would be wrong on its own terms: PD-08's EE-01 contract
requires the snapshot to be created **before** the `InstanceStarted` event
(`definition.md:2069–2081`), so a snapshot row can legitimately exist before any instance
row does.

*(Additionally, `004_definitions.sql:46–57`'s own header documents an R-Co operational
bug that Letflow's REQ-022 §4 guard makes structurally impossible: because R-Co's migrator
"has no per-table scope primitive (only whole-file `.public_only` vs `.all_schemas`)",
this file "correctly keeps running in every schema pass to create the `tenant_default`
copy, but that also creates an unwanted public shadow", which needed a separate cleanup
migration `GBL-141_iss0641_drop_dual_schema_shadows.sql` to drop, "idempotent, re-run
after any cold-start replay". Letflow's `if prefix() do … end` guard (§2.1) is exactly the
per-file scope primitive R-Co lacked — no shadow is ever created, so no cleanup migration
is ever needed. Noted as corroboration that the guard is load-bearing, not ceremony.)*

---

## 11. Acceptance-criteria traceability

| REQ-027 acceptance criterion | Concrete design element |
|---|---|
| **1.** "priv/repo/migrations gains `process_definitions` and `instance_definition_snapshots` migrations, both schema-per-tenant via REQ-022's `:prefix` mechanism, applying cleanly" | §4 — two named files with module names, the ordering constraint (#8 before #9), and exactly where `prefix: prefix()` goes on `create table` / `create index` / why `references/2` takes none (§4.2). §2.1 — the mandatory `if prefix() do … end` guard, cited to `req022-…md:340–395` and verified against the shipped `20260816120003_create_instance_projections.exs:38–55`. §2.2 + §5.3 — the manifest registration without which the migrations are inert, in the three-element `{version, module, filename}` form that avoids REQ-023's `Ecto.MigrationError` defect. §4.1 — the three filename/module/version constraints the shipped manifest test enforces. §4.5 — the `information_schema` method for demonstrating the criterion, including the negative check against `public`. §4.3 — reversibility, no raw SQL. |
| **2.** "`process_definitions` has a unique index on `(name, version)` and a partial unique index on `name` WHERE `status = 'active'`" | §3.1.2's index table, rows `uq_definition_version` and `uq_active_definition`, each with its R-Co citation (`004:30`, `004:34–36`) and R-Co's own purpose annotation (`definition.md:352–353`). The "How Ecto expresses each of these" block gives the exact `create unique_index(…, where: "status = 'active'", name: …, prefix: prefix())` call and verifies it against `migration.ex:1048–1052` and `connection.ex:1344`. INV-DEF-1, INV-DEF-2, and **INV-DEF-3** — the last of which states the predicate literal and the `Ecto.Enum` dump must agree, the failure mode if they don't, and is backed by §5.1's bare-atom enum form and §10 C-3. §3.1.2 also records why the tenant-prefixed `028_adp02` variants are deliberately not created and why that loses no enforcement. |
| **3.** "`process_definitions` has a nullable `stage` column and a partial index on `stage` WHERE `stage IS NOT NULL`, per definition.md's PD-07 section (`migrations/014_definition_stage.sql`)" | §3.1's `stage` row: `:string` → `varchar(255)`, **nullable**, no default, citing `014:3` and PD-07's own nullability rationale (`definition.md:1467–1468, 1483`) and its no-enum-validation rule (`definition.md:1486–1487`). §3.1.2's `idx_def_stage` row: `(stage)`, non-unique, `WHERE stage IS NOT NULL`, ported verbatim from `014:4` with PD-07's compactness rationale (`definition.md:1484–1485`). The "partial plain index" bullet gives the exact `create index(…, where: "stage IS NOT NULL", name: :idx_def_stage, prefix: prefix())` call. INV-DEF-4. OQ-5a records the `""`-vs-`NULL` semantic the predicate depends on. |
| **4.** "`instance_definition_snapshots.definition_id` references `process_definitions.id` with no `ON DELETE CASCADE`, and the moduledoc states this is deliberate per PD-08" | §3.2.2 — the full `references(:process_definitions, column: :id, type: :binary_id, on_delete: :nothing)` shape, with `connection.ex:1918` proving `:nothing` emits **no `ON DELETE` clause at all**, `migration.ex:513` proving `type: :binary_id` is mandatory, `connection.ex:1872` proving the FK stays in the tenant schema, and `connection.ex:1895–1896` giving the resulting constraint name. §3.2.3 — why `:nothing` rather than REQ-023's `:restrict`, so the divergence from the sibling design is explained not accidental. **§7.2 gives the verbatim moduledoc text**, which states the deliberateness, quotes PD-08's own two sentences (`definition.md:2055–2059`), names the consequence of changing it, **and** discloses that R-Co itself later added a cascade in `1106_iss0125_…` for a test-harness reason, so the divergence is discoverable from the code. INV-DEF-5; §10 C-1. §3.2.1's `idx_snap_definition` makes the FK's referential check cheap. OQ-2 flags that REQ-033's AC 4 wording assumes a delete that this FK never permits. |
| **5.** "both `Ecto.Schema` modules' `@moduledoc` cite R-Co `src/design/definition.md` (PD-01/PD-07/PD-08 sections) as the ported source" | **§7.1** opens `Letflow.Definitions.ProcessDefinition`'s moduledoc by naming `src/design/definition.md`'s **PD-01** sections (module purpose, `Store.create`, the `Definition` ↔ `process_definitions` database mapping, the unique-constraints table) **and** its **PD-07** section (the `stage` column and `idx_def_stage`, naming `migrations/014_definition_stage.sql`). **§7.2** opens `Letflow.Definitions.InstanceDefinitionSnapshot`'s moduledoc by naming the same document's **PD-08** section (`SnapshotStore`, the `Snapshot` DB column mapping, "Atomicity guarantee") and cross-references PD-01/PD-07 as the source for the table it references. Both quote `migrations/004_definitions.sql` as the DDL source. Both blocks are given verbatim so a validator can match them literally. §7.1 and §7.2 also each carry REQ-027's mandatory "this requirement builds schema only" note (`requirements.yaml:1183–1186`), naming REQ-028/029 (validation), REQ-030 (CRUD) and REQ-033 (snapshot functions). |

**Every clause of REQ-027's `description` mapped:**

| REQ-027 description clause | Where |
|---|---|
| "using REQ-022's schema-per-tenant `:prefix` mechanism (`process_definitions` is a business table under Decision B's general rule)" | §2 in full, incl. the §2.1 guard that is what actually keeps these tables out of `public`, and §2.2's registration half |
| `process_definitions`: `id` (binary_id) | §3.1 `id` row; §5.1 `@primary_key {:id, :binary_id, autogenerate: true}` |
| `name` (string, ≤255 chars) | §3.1 `name` row (`varchar(255)` enforces PD-01's bound); §5.2 `validate_length(:name, min: 1, max: 255)` |
| `version` (string) | §3.1 `version` row, incl. the stated new-bound divergence; §5.2 `validate_length(:version, …)` |
| `description` (text, nullable) | §3.1 `description` row (`:text` in the migration, `:string` at the schema layer — §5.1's note) |
| `status` (Ecto.Enum draft/active/deprecated/archived, default draft — PD-04's `DefinitionStatus`) | §3.1 `status` row; §5.1's bare-atom `Ecto.Enum` declaration; INV-DEF-3, INV-DEF-8; §10 C-3 |
| `stage` (string, nullable — PD-07's free-text label, quoted rationale, no enum validation) | §3.1 `stage` row; §3.1.2 `idx_def_stage`; INV-DEF-4 |
| `graph` (jsonb, default `{"nodes":[],"edges":[]}` — `DefinitionGraph`'s shape) | §3.1 `graph` row incl. the verified map-default mechanism (`connection.ex:1708–1712`); §5.1's schema-level default; §3.1.3's no-CHECK decision; INV-DEF-9 |
| `created_by` (binary_id) | §3.1 `created_by` row; §3.1.4's no-FK decision |
| `archived_at` (utc_datetime_usec, nullable) | §3.1 `archived_at` row |
| `timestamps()` | §3.1's `created_at`/`updated_at` rows — `timestamps(inserted_at: :created_at, type: :utc_datetime_usec)`, with the R-Co-name-preservation and cursor-precision reasons, and §3.1.1's exact DB-type statement |
| "Indexes: a unique index on (name, version) … a partial unique index on name WHERE status='active' … and a partial index on stage WHERE stage IS NOT NULL" | §3.1.2's full table, plus the explicit "deliberately NOT created" list so `idx_def_name`, `idx_def_fts` and the four `028_adp02` tenant variants are absent by decision, each with a citation |
| `instance_definition_snapshots`: `instance_id` (binary_id, primary key) | §3.2 `instance_id` row; §5.1 `@primary_key {:instance_id, :binary_id, autogenerate: false}` |
| `definition_id` (binary_id, references `process_definitions` — NO ON DELETE CASCADE, per PD-08) | §3.2.2 in full; §3.2.3; INV-DEF-5; §7.2; §10 C-1 |
| `definition_name` (string), `definition_ver` (string), `graph` (jsonb), `snapshotted_at` (utc_datetime_usec) | §3.2's column table, incl. why `graph` has no default here and why `snapshotted_at` uses a DB default + `read_after_writes` |
| "No `updated_at`/`timestamps()` beyond `snapshotted_at` — the table is write-once per PD-08 (no UPDATE path is exposed at the schema-module layer, enforced in REQ-033, not this migration)" | §3.2's "No `timestamps/1`" paragraph; §5.2's absent-functions table (first row, which states the REQ-033 enforcement boundary explicitly); INV-DEF-6; §7.2's verbatim text |
| "Note explicitly in both moduledocs: this requirement builds schema only. graph/node/edge structural validation (REQ-028/029), CRUD operations (REQ-030), and the snapshot create/retrieve functions (REQ-033) are separate requirements" | §7.1 paragraph 2 and §7.2 paragraph 5, both verbatim; §1's scope-boundary table |
