# Design: REQ-023 — Event-store schema & migrations

**Requirement:** REQ-023 (`docs/requirements.yaml`, stage S2, `depends_on: [REQ-022]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ023-20260816`, WF-02 Step 1
**This document produces:** migration shape, table/column/index/constraint detail,
`Ecto.Schema` module shape, `@spec`-style function signatures, invariants, traceability,
open questions. **No implementation code** — no function bodies, no `.ex`/`.exs` files,
no migration files. ELIXIR-DEV writes those from this document at Step 2a.

---

## 0. Sources read in full for this design

Every factual claim below is followed by a `file:line`-level citation. Nothing here is
asserted from memory.

**Letflow project docs**

- `docs/requirements.yaml` — REQ-023's full entry (lines 898–974), the S2 batch header
  comment above REQ-022 (lines 795–840), REQ-022 (842–896), REQ-024 (976–1040),
  REQ-025 (1042–1091), REQ-026 (1093–1139).
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — **read in full** (REQ-023's
  own text requires it). Decision A (lines 29–35), Decision B (37–45), Decision C
  (46–59); Dimension A reasoning (63–112), Dimension B reasoning (114–243) incl. the
  "Concrete Ecto/Postgres mechanics" paragraph (216–227), Dimension C reasoning
  (245–309): point 1 append-only/immutability (254–262), point 2 partitioning
  (264–282) with sub-point **2(a)** PK widening (273–277) and sub-point **2(b)**
  idempotency sidecar (277–282), point 3 projection tables (284–294), and the closing
  tenant-modeling paragraph (296–309).
- `docs/migration/stage-2-event-store-definitions.md` (full, 61 lines).
- `docs/guides/backend_developer_guide.md` — §3.1 naming, §3.5 error shapes, §3.6 SQL
  parameterization, §3.7 migrations, §5 multi-tenancy.
- `docs/anti-patterns.md`, `docs/agents/instructions/core-directives.md`,
  `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1,
  `docs/agents/shared/HANDOFF_PROTOCOL.md`.
- `lib/letflow/design/req022-tenant-schema-provisioning.md` (full) — especially §2
  (migration shape + the "don't port R-Co's redundant duplicate index" precedent, lines
  138–142), §3.2 `replay_migrations/2`, §3.4 `tenant_scoped_migrations/0`, and **§4, the
  required guard pattern for every tenant-scoped migration** (lines 340–395).

**Letflow shipped code (read directly, not assumed)**

- `lib/letflow/tenant_provisioning.ex` (250 lines) — `schema_name_for_tenant/1` (73–78),
  `provision_tenant_schema/1` (99–137), `replay_migrations/2` (160–181),
  `tenant_scoped_migrations/0` (196–198, returned `[]` at the time this reading list was
  compiled — §5.2 below is this same requirement's own edit that changes that; see
  ISS-0017/GH#73, 2026-08-17, for why this snapshot line needed a note rather than being
  read as still-current).
- `lib/letflow/tenant_provisioning/registration.ex`, `lib/letflow/events/transition_event.ex`,
  `lib/letflow/identity/tenant.ex`, `lib/letflow/identity/user.ex`,
  `lib/letflow/identity/group.ex`, `lib/letflow/identity/tenant_role.ex`.
- `priv/repo/migrations/20260816090045_create_tenant_schemas.exs`,
  `priv/repo/migrations/20260816000004_create_users.exs`,
  `priv/repo/migrations/20260814000001_create_transition_events.exs`.
- `test/support/req022_migration_fixture.ex` — the shipped, working example of REQ-022 §4's
  guard pattern (`if prefix() do create table(..., prefix: prefix()) ... end`, lines 24–30).
- `mix.exs` — `elixirc_paths(:test) -> ["lib", "test/support"]`, `elixirc_paths(_) -> ["lib"]`
  (lines 20–21). Load-bearing for §4.3.
- `config/config.exs`, `config/dev.exs` — the repo has **no** `migration_timestamps:`
  setting, so Ecto's default timestamp mapping applies (see §3.1's `created_at` note).

**Ecto / ecto_sql source, read directly from this repo's `deps/`** (this design's
mechanics depend on exact behavior; none of it is asserted from memory)

- `deps/ecto_sql/lib/ecto/migrator.ex:660–673` — `migrations_for/1`: a **binary** element
  of `migration_source` is treated as a *directory* and expanded with
  `Path.join([directory, "**", "*.{ex,exs}"])` (recursive); a `{version, module}` tuple
  becomes `{version, module, module}`.
- `deps/ecto_sql/lib/ecto/migrator.ex:725–731` — `load_migration!/1` for an atom module
  requires `migration?/1` to be true, else raises `Ecto.MigrationError`.
- `deps/ecto_sql/lib/ecto/migrator.ex:744–746` — `migration?(mod)` is
  `Code.ensure_loaded?(mod) and function_exported?(mod, :__migration__, 0)`.
- `deps/ecto_sql/lib/ecto/migrator.ex:733–742` — a **file path** source is loaded with
  `Code.compile_file/1`.
- `deps/ecto_sql/lib/ecto/migrator.ex:647–658` — only *pending* migrations reach
  `load_migration!/1`; already-applied versions are filtered out first.
- `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1872` — a `%Reference{}` with no
  explicit `:prefix` option falls back to **the referencing table's own prefix**
  (`Keyword.get(ref.options, :prefix, table.prefix)`).
- `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1862–1863` — composite foreign
  keys are emitted from `%Reference{}.with`, unzipped as
  `{current_columns, reference_columns}`.
- `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:2058–2074` — type mapping:
  `:binary_id -> uuid`, `:string -> varchar`, `:map -> jsonb` (the
  `:ecto_sql, :postgres_map_type` default), `:bigserial -> bigserial`,
  `:utc_datetime_usec -> timestamp`.
- `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1819–1833` —
  `:utc_datetime_usec` with no `:precision` option emits a bare `timestamp`
  (Postgres default precision = 6, i.e. microseconds); only `:utc_datetime`/
  `:naive_datetime` get a forced `(0)`.
- `deps/ecto_sql/lib/ecto/migration.ex:431–449` — `%Ecto.Migration.Index{}` carries
  `prefix`, `unique`, `where` (partial predicate), `name`, `include`, `nulls_distinct`.
- `deps/ecto/lib/ecto/enum.ex:76–103` — `Ecto.Enum` accepts either a list of atoms
  (dumped as the atom's own string) **or** a keyword list mapping atom → explicit string,
  which is what §3.6 uses to store R-Co's uppercase status values.

**R-Co source of truth (`C:\Users\tvolo\dev\ai-dala\R-Co\`), read directly**

- `src/design/event_store.md` (473 lines) — ES-01..ES-08 coverage (line 3), `StoreError`
  (22–46), `EventRecord` (201–213), `AppendParams` (215–223), Key invariants 1–12
  (274–296), "DB tables / columns per operation" (300–339), "Concurrency design"
  (343–376), Risks (438–445), **Open questions #1** (451–460), traceability (464–472).
- `migrations/001_event_store.sql` — `events` (23–40), `events_global_seq` (43–45),
  `uq_event_idempotency` (48–49), `uq_event_sequence` (52–53), `idx_events_global_seq`
  (56–57), `idx_events_instance_seq` (60–61), `idx_events_instance_time` (63–64),
  `idx_events_type` (67–68), `instance_sequence` (73–76), `instance_projections` (81–95),
  `uq_instance_correlation` (98–100), `idx_proj_status` (102–104), `idx_proj_definition`
  (106–107).
- `migrations/003_event_archive.sql` — `events_archive` (9–21), its three indexes (23–30),
  `event_retention_policies` (35–52).
- `migrations/012_event_retention.sql` — `event_payload_store` (16–22).
- `migrations/013_event_archive_idempotency.sql` — `uq_event_archive_idempotency` (20–21)
  and its header stating the two-phase dedup this design supersedes (1–18).
- `migrations/027_adp01_event_store_tenant.sql` (22 lines) — `tenant_id` added to
  `events`/`events_archive` (4–10).
- `migrations/028_adp02_tenant_scope_persistence.sql` — `tenant_id` added to
  `instance_projections` (18–19).
- `migrations/1147_par01_events_partitioning.sql` (397 lines) — PER_TENANT classification
  of `events`/`events_archive`/`plat_event_idempotency`/`event_payload_store` (31–46,
  98–99), rebuilt `events` with `PRIMARY KEY (event_id, created_at)` (120–134), widened
  `uq_event_sequence` + its C0A000 rationale (136–151), `uq_event_idempotency`
  deliberately not recreated (162–165), rebuilt `events_archive` with the same composite
  PK (167–182), `uq_event_archive_idempotency` likewise not recreated because
  "plat_event_idempotency supersedes its purpose" (192–193), `plat_event_idempotency`
  DDL (200–207), rebuilt `event_payload_store` with the composite FK (215–223).
PROVENANCE (historical, not current decision authority):
- `src/event_store/store.zig` (1619 lines) — sidecar-first append rationale (588–598),
  sidecar INSERT (606–617), the "generate `event_id` exactly once" bug note (623–636),
  duplicate resolution across `events`/`events_ephemeral`/`events_archive` (638–703, table
  list at 675), "no ON CONFLICT on events, `uq_event_idempotency` no longer exists"
  (705–727), payload side-table INSERT keyed on `(event_id, created_at)` (835–854),
  "the SAME created_at" bound into `instance_projections` (856–864), **`Store.archive()`
  retired** (1287–1310).
PROVENANCE (historical, not current decision authority):
- `src/event_store/platform.zig` (12 lines) — the three sentinels; `PLATFORM_INSTANCE_ID`
  is "Never inserted into instance_projections" (line 5).
PROVENANCE (historical, not current decision authority):
- `src/event_store/registry.zig` (583 lines) — read to confirm REQ-024's boundary; it owns
  `event_type_registry`, which this requirement does **not** create.
- `src/design/par-01-monthly-range-partitioning.md:203–209` — the `plat_`-prefix
  convention note (load-bearing for §3.5's table-name decision).

---

## 1. Scope boundary

**In scope (this requirement):** six tables, their migrations, and their `Ecto.Schema`
modules under `lib/letflow/event_store/`, plus the one-function edit to
`Letflow.TenantProvisioning.tenant_scoped_migrations/0` that REQ-022's design §3.4
mandates for every tenant-scoped migration.

**Explicitly NOT in scope, and not silently dropped:**

PROVENANCE (historical, not current decision authority):
| Not built here | Owned by | Citation |
|---|---|---|
| `Letflow.EventStore` context module (`append/1`, `read/2`, `read_global/1`, `point_in_time/3`, `archive/1`) | REQ-025, REQ-026 | `docs/requirements.yaml:1042–1139` |
| `event_type_registry` table + `Letflow.EventStore.Registry` | REQ-024 | `docs/requirements.yaml:976–1040` |
| `event_retention_policies` table | **nobody — see Open Question OQ-1 (§9)** | R-Co `migrations/003_event_archive.sql:35–52`; needed by REQ-026 (`requirements.yaml:1126`) |
| Partitioning (`PARTITION BY RANGE (created_at)`), monthly partitions, `events_ephemeral`, `retention_class` | deferred by 0003 Decision C point 2 | `0003:264–272` |
| Meaningful population of `instance_projections` at instance start | EE-01 / S3 (`src/engine/`) | `requirements.yaml:958–964` |
| The three `platform.zig` sentinel constants | REQ-026 | `requirements.yaml:1103–1112` |

---

## 2. How these migrations reach a tenant schema (REQ-022 mechanism, verified against shipped code)

This section exists because REQ-023 acceptance criterion 1 requires the new migrations to
"apply cleanly against at least one provisioned tenant schema via REQ-022's
migration-replay mechanism". The mechanism was read from the shipped code, not assumed.

### 2.1 What REQ-022 actually shipped

`Letflow.TenantProvisioning.replay_migrations/2`
(`lib/letflow/tenant_provisioning.ex:160–181`) calls

```
Ecto.Migrator.run(Repo, migration_source, :up, all: true, prefix: schema_name, log: false)
```

where `schema_name` is read back from the `tenant_schemas` registry row, and
`migration_source` defaults to `tenant_scoped_migrations/0`
(`lib/letflow/tenant_provisioning.ex:196–198`), which **today returns `[]`**.

So REQ-022 does **not** replay all of `priv/repo/migrations/`. It replays a **designated
per-tenant subset**, expressed as an explicit `[{version, module}]` list. This is the
answer to the question this design was told to check: *a designated subset, not the whole
directory.* The reason is documented in `req022-tenant-schema-provisioning.md:348–367`:
`priv/repo/migrations/` also holds S1's global identity migrations and REQ-022's own
global `CreateTenantSchemas`, none of which may ever be replayed into a tenant schema.

Each distinct `:prefix` gets its own independent `schema_migrations` version-tracking
table (`req022-...md:52–55`, confirmed there from
`deps/ecto_sql/lib/ecto/migration/schema_migration.ex`), so a tenant schema's migration
bookkeeping is independent of `public`'s.

### 2.2 The guard pattern every REQ-023 migration must follow

`Ecto.Migration.prefix/0` returns `nil` when the enclosing Migrator run was given no
`:prefix`, and `create table(:x)` with no explicit `prefix:` **always** targets the
default schema regardless of the run's prefix (`req022-...md:355–367`, confirmed there
from `deps/ecto_sql/lib/ecto/migration.ex`). A plain `mix ecto.migrate` (the ordinary
dev/CI/`mix test` bootstrap) runs *every* `.exs` in `priv/repo/migrations/` with no
prefix. Therefore each of REQ-023's six migrations must be shaped like this — **this is
the shape, not literal code; ELIXIR-DEV writes the real file**:

```
change/0:
  if Ecto.Migration.prefix() is truthy:
      create table(<name>, primary_key: false, prefix: prefix()) with the columns in §3
      create every index in §3 with prefix: prefix()
  else:
      do nothing at all — this migration must have zero effect on the public schema
```

The shipped, working reference for this exact shape is
`test/support/req022_migration_fixture.ex:24–30`.

Consequence to state plainly: a plain `mix ecto.migrate` will record all six versions in
`public.schema_migrations` having created nothing in `public`. That is harmless
bookkeeping, exactly as `req022-...md:384–387` anticipated — **not** a defect for
RELEASE-VALIDATOR to chase.

### 2.3 Index names under `:prefix`

Postgres index and constraint names are schema-scoped, not database-scoped. Two tenant
schemas may therefore each hold an index named `uq_event_sequence` without collision, and
`public` holds none of them (the guard in §2.2 skips the whole `change/0` body there). All
explicit `name:` values in §3 are chosen on that basis.

### 2.4 A real gap in REQ-022's shipped mechanism that REQ-023 is the first to hit

**This is a verified finding, not a hypothetical.** `tenant_scoped_migrations/0` is
specified to return `{version, module}` tuples. `Ecto.Migrator` resolves such a tuple via
`load_migration!/1`, which requires `Code.ensure_loaded?(module)` to be true
(`deps/ecto_sql/lib/ecto/migrator.ex:725–731, 744–746`). But
`priv/repo/migrations/*.exs` files are **not compiled into the application** —
`mix.exs:20–21` sets `elixirc_paths` to `["lib"]` (plus `test/support` in `:test`). There
is no `.beam` file for `Letflow.Repo.Migrations.CreateEvents`, so `Code.ensure_loaded?/1`
returns false and `Ecto.Migrator.run/4` raises
`Ecto.MigrationError: module Letflow.Repo.Migrations.CreateEvents is not an Ecto.Migration`,
which `replay_migrations/2` would surface as `{:error, {:migration_failed, exception}}`.

The failure is **state-dependent, which is why it has not been seen yet**:

- Only *pending* migrations reach `load_migration!/1`
  (`deps/ecto_sql/lib/ecto/migrator.ex:647–658`).
- `mix ecto.migrate` loads a pending migration with `Code.compile_file/1`
  (`:733–742`), which defines the module **in the running BEAM VM**.
- `mix.exs:48` aliases `test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]` —
  all three run in one VM. So against a **fresh** test DB the six migrations are pending,
  get compiled by the `ecto.migrate` step, and are therefore loaded by the time a test
  calls `replay_migrations/2`: it appears to work.
- Against an **already-migrated** DB (the normal second and subsequent run), nothing is
  pending, nothing is compiled, and the same call raises. Likewise in any `iex -S mix`
  session or release, where `mix ecto.migrate` never ran in-process at all.

**Decision (resolved here, not deferred):** REQ-023's edit to
`Letflow.TenantProvisioning.tenant_scoped_migrations/0` must ensure each migration file is
loaded before returning its tuple. Signature and behavior are specified in §5.2. This
keeps REQ-022's shipped `@spec` for both `tenant_scoped_migrations/0` and
`replay_migrations/2` byte-identical — no public-contract change to shipped code.

**Alternative considered and rejected:** pass a *directory* instead (e.g. move the six
files to `priv/repo/migrations/tenant/` and have `tenant_scoped_migrations/0` return
`["<priv>/repo/migrations/tenant"]`), which `migrations_for/1` would expand with
`Code.compile_file/1` and no loading problem
(`deps/ecto_sql/lib/ecto/migrator.ex:660–673, 733–742`). Rejected for two reasons, either
of which carries the decision alone:
(a) it changes the `@spec` of two shipped REQ-022 functions, which REQ-023 has no mandate
to redesign; (b) the directory wildcard is `**`, so a nested `tenant/` subdirectory is
*still* picked up by a plain `mix ecto.migrate`, meaning the §2.2 guard is required either
way — the subdirectory buys no isolation. (A third reason considered — that
`Code.compile_file/1` re-defining the modules on every fresh-tenant replay would trip
`mix compile --warnings-as-errors` — does not actually hold: "redefining module" is a
real compiler warning, emitted by `Code.compile_file/1` itself at `mix ecto.migrate`
time, but outside `mix compile`'s own diagnostic-collection pass — a separate mix task
entirely — so it would not affect that flag's exit status; corrected here per ISS-0020
rather than left to mislead a future reader citing this section, since (a) and (b) are
sufficient on their own.) Recorded here so the road not taken is visible rather than
silently absent.

This gap is also reported as a MINOR issue against `req022-tenant-schema-provisioning.md`
§3.4/§4 in this step's handoff — the shipped design named the mechanism but did not
account for migration modules being uncompiled.

### 2.5 Why only three of the six new tables carry `tenant_id` (ISS-0020)

`events`, `events_archive`, and `instance_projections` carry a `tenant_id` column;
`instance_sequence`, `event_payload_store`, and the idempotency sidecar do not. This is
not an oversight against 0003 Decision B's "`tenant_id` retained inside each schema"
rule — it is that rule applied correctly, because Decision B scopes to "the tables the
adp-0x docs describe" (`0003:37–45`), and R-Co's own `adp-0x` migrations only ever add
`tenant_id` to `events`/`events_archive` (`027_adp01_event_store_tenant.sql:4–6`) and
`instance_projections` (`028_adp02_tenant_scope_persistence.sql:18–19`) — R-Co never adds
it to the other three, and actively **drops** it from `instance_sequence` in four later
migrations (`GBL-116:117`, `GBL-123:91`, `GBL-130:121`, `GBL-131:90`). Every table in this
schema already lives inside one tenant's own Postgres schema (§2.2's guard), so
`tenant_id` here is redundant defense-in-depth for the three tables R-Co decided it was
worth keeping on, not a universal per-row requirement — a future requirement touching
these files should preserve the asymmetry rather than "complete" it by adding the column
to the other three.

---

## 3. Table specifications

Conventions applied throughout, matching `docs/guides/backend_developer_guide.md` §3.1/§3.7
and the shipped S1 migrations:

- `create table(<name>, primary_key: false, prefix: prefix())` with explicit
  `add ..., primary_key: true` columns (shape of
  `priv/repo/migrations/20260816000004_create_users.exs:33–34`).
- `snake_case` table and column names; R-Co's names preserved where they carry meaning
  (0003 Decision A, `0003:98–103`).
- `#`-comment header block above `defmodule` on every migration (shipped convention:
  `20260816000004_create_users.exs:1–28`, `20260816090045_create_tenant_schemas.exs:1–23`).
- **DB type** column below is what the Postgres adapter actually emits, per
  `deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:2058–2074` and `:1819–1833`.
- `Ecto.Migration.timestamps/1` (`deps/ecto_sql/lib/ecto/migration.ex:1366–1376`, read
  directly) defaults to `type: :naive_datetime` and `null: false`, and accepts
  `:inserted_at`/`:updated_at` either renamed to another atom or set to `false` to omit
  the column, plus a `:type` override. Every `timestamps(...)` call specified below relies
  only on those documented options. It adds **no** DB-level default — the values come from
  `Ecto.Schema`'s own autogeneration at insert time, matching every existing Letflow table.

### 3.1 `events`

Migration `20260816120001_create_events.exs` — `Letflow.Repo.Migrations.CreateEvents`.

PROVENANCE (historical, not current decision authority):
| Column | Ecto migration type | DB type | Null / default | Notes & citation |
|---|---|---|---|---|
| `event_id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` (implied by PK) | Component 1 of the composite PK. **No DB default** — REQ-025 must generate it once and bind the same value into `events` and `event_idempotency` (R-Co `store.zig:623–636` documents the live bug caused by two independent `gen_random_uuid()` calls orphaning the sidecar row). |
| `created_at` | `:utc_datetime_usec`, `primary_key: true` | `timestamp` (precision 6 = microseconds) | `NOT NULL`, `default: fragment("(now() AT TIME ZONE 'utc')")` | Component 2 of the composite PK per **0003 Decision C point 2(a)** (`0003:273–277`). Microsecond precision per ES-01 (`event_store.md:209`). REQ-025 binds this explicitly (same value into `event_payload_store` and `event_idempotency`, mirroring `store.zig:835–864`); the default is a safety net only. See the timestamptz note below. |
| `instance_id` | `:binary_id` | `uuid` | `NOT NULL` | R-Co `001_event_store.sql:26`. **No FK** — see §3.1.3. |
| `event_type` | `:string` | `varchar(255)` | `NOT NULL` | R-Co `001:27`. **No FK** to `event_type_registry` — see §3.1.3. |
| `payload` | `:map` | `jsonb` | `NOT NULL`, `default: %{}` | R-Co `001:28`, `1147:125`. Holds either the inline JSON object (≤ 4096 bytes) or the `{"$ref": "<uuid>"}` pointer form (`event_store.md:286`). The 4096 boundary is **not** enforced here — REQ-023's own text assigns it to REQ-025 (`requirements.yaml:913–916`). |
| `actor_id` | `:binary_id` | `uuid` | `NOT NULL` | R-Co `001:29`; ES-01 requires non-nil (`event_store.md:207`). No FK — see §3.1.3. |
| `sequence_number` | `:bigint` | `bigint` | `NOT NULL` | Per-instance monotone, assigned from `instance_sequence` (ES-02, `event_store.md:210`, `001:33`). |
| `idempotency_key` | `:string` | `varchar(255)` | `NOT NULL` | ES-03 bounds it at 1..255 chars (`event_store.md:211`). `varchar(255)` is Ecto's `:string` default and *enforces* that bound, which R-Co's `TEXT` (`001:36`) only documented — a Decision A "comment becomes an enforced type" swap (`0003:104–109`). REQ-025 still validates pre-DB to produce the typed `IdempotencyKeyTooLong` error (`event_store.md:38–39`). **No unique index here** — see §3.1.2. |
| `metadata` | `:map` | `jsonb` | `NOT NULL`, `default: %{}` | ES-08 string→string map, defaults to `{}` (`event_store.md:212`, `001:39`). |
| `global_seq` | `:bigserial` | `bigserial` (`bigint` + owned sequence + `DEFAULT nextval(...)`) | `NOT NULL` (implied by `bigserial`) | ES-04 cross-instance monotone cursor (`event_store.md:213, 278`). See §3.1.1 for why `:bigserial` rather than a hand-written `CREATE SEQUENCE`. |
| `tenant_id` | `:binary_id` | `uuid` | `NOT NULL`, **no default** | 0003 Decision B retains `tenant_id` intra-schema "on the tables the adp-0x docs describe" (`0003:37–45`); `adp-01-tenant-column-event-store.md` is exactly the event-store one, and R-Co implements it at `027_adp01_event_store_tenant.sql:4–6` and keeps it in the rebuilt table at `1147:132`. Unlike R-Co, **no `DEFAULT '00000000-…'`**: that default exists in R-Co only to backfill pre-existing rows, and Letflow has no reserved default-tenant UUID at all (`req022-...md:313–324` established this by reading `lib/letflow/identity/tenant.ex`). REQ-025 supplies it from the request's auth context. |

**Primary key:** `(event_id, created_at)` — composite, **not** a bare `event_id`. This is
REQ-023 acceptance criterion 2 and **0003 Decision C point 2(a)** verbatim: "Letflow's
initial event-store migration should define the primary key as `(event_id, created_at)`
from the start, even before partitioning exists, so the future retrofit isn't also a
primary-key-shape migration" (`0003:273–277`). R-Co paid that cost at
`1147_par01_events_partitioning.sql:133`.

**No `timestamps()` call on this table.** R-Co's `events` has no `inserted_at`/`updated_at`
(`001:23–40`); `created_at` is the only time column, and an `updated_at` on an append-only
table would be actively misleading (§6, INV-EV-1).

#### 3.1.1 `global_seq` allocation — decided, with rationale

R-Co uses an explicitly named sequence: `CREATE SEQUENCE IF NOT EXISTS events_global_seq`
plus `DEFAULT nextval('events_global_seq')` (`001:43–45`, still present at `1147:131`).
Because `001` is replayed once per schema under a `<schema>,public` `search_path`
(`001:9–13` describes exactly this replay model) and the `CREATE SEQUENCE` there is
unqualified, R-Co already ends up with **one sequence per tenant schema**.

**Decision: use Ecto's `:bigserial` column type.** Postgres creates the owning sequence in
the same schema as the table, so it lands inside the tenant schema automatically with no
prefix threading and no `execute/2` raw SQL — and `execute/2` would have required
interpolating the schema name into DDL, which this design otherwise avoids entirely (§8).
Semantics are identical to R-Co's: monotone, transaction-safe, gaps after rollback are
expected and acceptable (`event_store.md:278, 370–372`).

**Stated divergence:** the generated sequence is named `events_global_seq_seq` (Postgres's
`<table>_<column>_seq` rule) rather than R-Co's `events_global_seq`. Nothing in Letflow
references the sequence by name, so this costs nothing; it is recorded so a later
cross-reference against R-Co isn't confused by it.

**Scope note (not an open question — settled by Decision B):** under schema-per-tenant each
tenant schema has its own sequence, so `global_seq` is a cross-*instance* cursor within one
tenant, not a cross-*tenant* one. That is exactly what ES-04 asks for
(`event_store.md:213`: "Cross-instance monotone") and matches R-Co's own per-schema
outcome. See OQ-3 (§9) for the genuinely unsettled part.

#### 3.1.2 Indexes on `events`

| Index name | Columns | Unique | Predicate | Why / citation |
|---|---|---|---|---|
| *(PK)* | `(event_id, created_at)` | yes | — | 0003 Decision C 2(a); `1147:133` |
| `uq_event_sequence` | `(instance_id, sequence_number)` | **yes** | — | ES-02 per-instance uniqueness (`001:52–53`). See the widening note below. |
| `idx_events_global_seq` | `(global_seq)` | no | — | ES-04 global stream cursor (`001:56–57`); REQ-026's `read_global/1` orders and pages on it. |
| `idx_events_instance_time` | `(instance_id, created_at)` | no | — | ES-06 point-in-time filter (`001:63–64`); REQ-026's `up_to_timestamp`. |
| `idx_events_type` | `(event_type)` | no | — | `001:67–68`. |

**Deliberately NOT created, each with its reason** (so their absence is a decision, not an
oversight):

- `idx_events_instance_seq` on `(instance_id, sequence_number)` (`001:60–61`) — byte-for-byte
  the same column list and order as `uq_event_sequence`. Dropping the duplicate follows the
  precedent `req022-tenant-schema-provisioning.md:138–142` already set ("R-Co's SQL adds
  both a UNIQUE constraint *and* a separate plain index on the same column, which is
  redundant. Not porting that redundancy is a Decision-A-consistent simplification").
- `uq_event_idempotency` on `(idempotency_key)` (`001:48–49`) — **superseded by the
  `event_idempotency` sidecar** per 0003 Decision C point 2(b) (`0003:277–282`) and R-Co's
  own `1147:162–165` ("deliberately NOT recreated here — global idempotency now lives in
  plat_event_idempotency"). Creating it here would give Letflow two competing sources of
  truth for the same invariant.
- `idx_events_tenant_instance_seq`, `idx_events_tenant_global_seq`
  (`027_adp01:12–16`, `1147:156–157`) — under Decision B the Postgres schema *is* the
  tenant boundary, so `tenant_id` has (at most) one distinct value per schema and a
  leading-`tenant_id` index degenerates to its non-tenant counterpart at strictly higher
  write cost. R-Co created these while its tables still lived in shared `public`.
- `idx_events_instance_order`, `idx_events_tenant_pipeline_run_seq` (`1147:158–160`) — the
  first is subsumed by `idx_events_instance_time`; the second indexes
  `metadata->>'pipeline_run_id'`, an ADP-06 concern no Letflow requirement references.

**Forward note on `uq_event_sequence` (decision, with the retrofit named):** R-Co widened
this index to `(instance_id, sequence_number, created_at)` at `1147:151`, forced by
Postgres error C0A000 — every unique index on a partitioned table must contain all
partition-key columns (`1147:136–150`). Letflow keeps the **stronger** two-column form now,
because 0003 Decision C 2(a) scopes the up-front shape commitment to the *primary key* and
the idempotency *mechanism* only (`0003:273–282`) — those two are named because changing
them later is breaking (PK shape) or compounding (every idempotency consumer migrating at
partitioning time). Widening a secondary unique index later is a plain index swap with no
application-code change, and the widened form is strictly weaker (it permits two rows
sharing `(instance_id, sequence_number)` at different `created_at`). The partitioning
retrofit must widen it; that is recorded here so it is a planned step, not a surprise.

#### 3.1.3 Foreign keys on `events`: none, deliberately

PROVENANCE (historical, not current decision authority):
- **`instance_id` → `instance_projections.instance_id`: no FK.** R-Co has none
  (`001:23–40`), and `src/event_store/platform.zig:5` states the reason directly:
  `PLATFORM_INSTANCE_ID` is a sentinel that is "Never inserted into instance_projections".
  Platform/scheduler events therefore carry an `instance_id` with no projection row, which
  an FK would reject.
- **`event_type` → `event_type_registry.name`: no FK.** R-Co documents the relationship as
  a comment only (`001:27`: "must exist in event_type_registry") and enforces it at the
  application layer via `Registry.validatePayload()` before any write
  (`event_store.md:288`, invariant 8). REQ-024 owns that table; REQ-025 owns the check.
- **`actor_id` → `users.id`: no FK.** `users` lives in the public/default schema
  (`req022-...md:459–465`) while `events` lives in a tenant schema; and this codebase's own
  convention already omits DB FKs from tenant-scoped rows to identity rows
  (`20260816000004_create_users.exs:8–15`).

#### 3.1.4 Timestamp type: an accurate statement, not a silent divergence

R-Co uses `TIMESTAMPTZ` for `created_at` (`001:30`). Ecto's `:utc_datetime_usec` — the type
REQ-023 names explicitly (`requirements.yaml:917`) — maps to `timestamp` *without* time
zone (`deps/ecto_sql/.../postgres/connection.ex:2071`, `:1823–1833`), and this repo sets no
`migration_timestamps: [type: :timestamptz]` (checked in `config/config.exs` and
`config/dev.exs`). So the emitted DB type is `timestamp(6) without time zone`. This is safe
because `Ecto`'s `:utc_datetime_usec` normalizes every value to UTC on the way in and out,
and the column default is written as `(now() AT TIME ZONE 'utc')` rather than bare `now()`
precisely so an implicit `timestamptz → timestamp` cast can never pick up the session's
local time zone. Whether Letflow should move the whole repo to `timestamptz` is OQ-5 (§9) —
it would affect S1's shipped tables too, so it is not REQ-023's call to make alone.

### 3.2 `instance_sequence`

Migration `20260816120002_create_instance_sequence.exs` —
`Letflow.Repo.Migrations.CreateInstanceSequence`.

| Column | Ecto migration type | DB type | Null / default | Notes & citation |
|---|---|---|---|---|
| `instance_id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` | Natural PK — REQ-023 names it (`requirements.yaml:929`), R-Co `001:74`, `event_store.md:349`. |
| `next_seq` | `:bigint` | `bigint` | `NOT NULL`, `default: 1` | `001:75`, `event_store.md:350`. |

**Indexes:** none beyond the primary key. **No `timestamps()`** — R-Co has none
(`001:73–76`), and this is the hot row every append takes a `SELECT … FOR UPDATE` on
(`event_store.md:353–358`); an `updated_at` would add a write to the most contended row in
the system for no consumer.

**No FK on `instance_id`** — same platform-sentinel reason as §3.1.3, and R-Co's "first
append to a new instance" pattern (`event_store.md:360–367`) inserts this row *before* any
projection row necessarily exists.

### 3.3 `instance_projections`

Migration `20260816120003_create_instance_projections.exs` —
`Letflow.Repo.Migrations.CreateInstanceProjections`.

| Column | Ecto migration type | DB type | Null / default | Notes & citation |
|---|---|---|---|---|
| `instance_id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` | Natural PK per REQ-023 (`requirements.yaml:955`), R-Co `001:82`. |
| `tenant_id` | `:binary_id` | `uuid` | `NOT NULL`, no default | Decision B (`0003:37–45`); R-Co adds it at `028_adp02_tenant_scope_persistence.sql:18–19`. No default, for the same reason as §3.1. |
| `status` | `:string` | `varchar(255)` | `NOT NULL`, `default: "ACTIVE"` | Stored as R-Co's uppercase strings (`001:85–86`: `ACTIVE \| COMPLETED \| CANCELLED \| ERROR`); surfaced as Elixir atoms by `Ecto.Enum`'s keyword-mapping form (§3.6). REQ-023 requires "at minimum ACTIVE/CANCELLED/COMPLETED" (`requirements.yaml:956–957`); `ERROR` is included because R-Co defines it and omitting it would force an enum migration the first time S3 needs it. |
| `last_event_seq` | `:bigint` | `bigint` | `NOT NULL`, `default: 0` | `001:90`; updated in the same transaction as every append (`event_store.md:284`, invariant 6). |
| `started_at` | via `timestamps/1` | `timestamp` (precision 6) | `NOT NULL` | `timestamps(inserted_at: :started_at, type: :utc_datetime_usec)` — reuses the rename idiom REQ-022 already shipped (`20260816090045_create_tenant_schemas.exs:34`) and lands on R-Co's own column name (`001:91`). |
| `updated_at` | via `timestamps/1` | `timestamp` (precision 6) | `NOT NULL` | Named by REQ-023 (`requirements.yaml:958`); `001:94`. Microsecond type chosen because every append touches it (`event_store.md:310`), and second precision would make ordering ties routine. |

**Indexes:**

| Index name | Columns | Unique | Predicate | Why / citation |
|---|---|---|---|---|
| *(PK)* | `(instance_id)` | yes | — | The active-instance guard's own lookup (`event_store.md:305`) |
| `idx_proj_status` | `(status)` | no | `WHERE status = 'ACTIVE'` | R-Co `001:102–104`; partial predicates are supported via `%Index{}.where` (`deps/ecto_sql/lib/ecto/migration.ex:447`) |

**Columns deliberately not created here** (R-Co has them; they are written by the instance
engine, which REQ-023 explicitly says is not built here —
`requirements.yaml:958–964`): `definition_id`, `correlation_key`, `current_nodes`,
`variables`, `error_detail`, `completed_at`, `cancelled_at` (`001:83–93`), plus the
`uq_instance_correlation` and `idx_proj_definition` indexes (`001:98–107`) that depend on
them. Named explicitly so EE-01/S3 knows precisely what its own `ALTER TABLE` migration
must add — see OQ-7 (§9).

### 3.4 `event_payload_store`

Migration `20260816120004_create_event_payload_store.exs` —
`Letflow.Repo.Migrations.CreateEventPayloadStore`. **Must sort after `…120001`** (it
carries a foreign key to `events`).

| Column | Ecto migration type | DB type | Null / default | Notes & citation |
|---|---|---|---|---|
| `id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` | Decision A `binary_id` PK; REQ-023's closing sentence lists the only exceptions and this table is not among them (`requirements.yaml:965–967`). R-Co uses a surrogate `id` here too (`012:17`, `1147:216`). |
| `event_id` | `:binary_id` + composite `references(...)` | `uuid` | `NOT NULL` | `012:18`, `1147:217`. |
| `event_created_at` | `:utc_datetime_usec` | `timestamp` (precision 6) | `NOT NULL` | Second half of the composite FK — mandatory, because `events`' PK is `(event_id, created_at)` and a single-column FK has no unique constraint to reference. R-Co hit exactly this at `1147:209–223`. **Naming divergence, deliberate:** R-Co calls it `created_at` (`1147:218`), colliding with `012:21`'s `created_at DEFAULT NOW()`, which meant *this row's* insert time. `event_created_at` matches the unambiguous name R-Co itself chose for the same purpose on `webhook_deliveries` (`1147:250`). See §10, contradiction C-3. |
| `payload` | `:map` | `jsonb` | `NOT NULL` | `012:19`, `1147:219`. REQ-023 offers "text/bytea" (`requirements.yaml:934`); `jsonb` is chosen to match R-Co's actual type in both revisions and to keep read-time splicing (`event_store.md:286`) type-uniform with `events.payload`. |
| `byte_size` | `:integer` | `integer` | `NOT NULL` | `012:20`, `1147:220`. **Semantics stated explicitly:** this is the byte length of the *original* payload as measured by REQ-025 at append time — the value the 4096 boundary was applied to — not `octet_length(payload::text)` after storage, because `jsonb` normalizes whitespace and key order and can therefore round-trip to a different length. |
| `inserted_at` | via `timestamps(updated_at: false)` | `timestamp(0)` | `NOT NULL` | This row's own creation time — the meaning `012:21`'s `created_at` originally had, kept under an unambiguous name. `updated_at: false` matches `transition_events`' precedent for insert-only rows. |

**`jsonb` is not byte-transparent (ISS-0020).** Beyond `byte_size`'s measurement caveat
above, `jsonb` normalizes its input on write — it cannot round-trip an opaque binary blob
byte-for-byte the way `bytea` could, and key order/whitespace/duplicate keys are not
preserved. Nothing today needs byte-transparency (the payload is documented as JSON
object bytes throughout `event_store.md`), so this is not a defect in the `jsonb` choice
above, only an unrecorded consequence of it. Recorded so that if a future requirement
needs an opaque blob or a hash-stable payload representation — R-Co's
`adp-05-instance-artifact-hash.md` and `adp-09-tamper-evident-audit-chain.md` are the
plausible candidates — the constraint is findable here rather than rediscovered via a
failing hash comparison.

**Foreign key:** composite,
`(event_id, event_created_at) → events(event_id, created_at)`, expressed as
`references(:events, column: :event_id, with: [event_created_at: :created_at], type: :binary_id, on_delete: :restrict)`.
`%Reference{}.with` unzips into exactly this composite form
(`deps/ecto_sql/.../postgres/connection.ex:1862–1863`), and the reference inherits the
table's own `prefix:` automatically because `ref.options` carries no `:prefix`
(`:1872`) — so no extra prefix threading is needed and the FK stays inside the tenant
schema.

PROVENANCE (historical, not current decision authority):
**`on_delete: :restrict`, diverging from R-Co's `ON DELETE CASCADE` (`012:18`, `1147:222`)
— decided, with rationale.** Under `CASCADE`, REQ-026's `archive/1` (which `DELETE`s from
`events` after copying to `events_archive`, `event_store.md:294, 324–329`) would silently
destroy the side-table payload of every archived large event, leaving archived events
unreadable and contradicting `003_event_archive.sql:6–7` ("Archived rows are moved here,
not deleted. Active instance state reconstruction is never affected") and invariant 7's
transparent-splice contract (`event_store.md:286`). R-Co's `CASCADE` is *no longer evidence
about archival behaviour at all*, because `Store.archive()` has been retired there
(`store.zig:1287–1310`, see §10 contradiction C-1) — nothing in current R-Co ever deletes
an `events` row. `:restrict` makes the unresolved question fail loudly at REQ-026's first
integration test instead of silently losing tenant data. The question REQ-026 must then
answer is OQ-2 (§9).

**Indexes:**

| Index name | Columns | Unique | Why / citation |
|---|---|---|---|
| *(PK)* | `(id)` | yes | Decision A |
| `uq_event_payload_event` | `(event_id)` | **yes** | REQ-023 names `event_id` as unique (`requirements.yaml:933`), and `event_store.md:440` relies on it ("`event_payload_store.event_id` has a UNIQUE index; join is O(1) per row"). Chosen over R-Co's later composite `UNIQUE (event_id, created_at)` (`1147:221`) because single-column uniqueness is strictly stronger (one payload row per event, full stop) and the composite form was only ever needed on the *parent* side, which here is already the `events` PK. |

**No CHECK constraint on `byte_size > 4096`** — REQ-023 states the boundary is "enforced at
the append logic layer in REQ-025, not the migration layer"
(`requirements.yaml:913–916`). A DB-level duplicate would create a second source of truth
with a different error shape.

### 3.5 `event_idempotency` (the sidecar)

Migration `20260816120006_create_event_idempotency.exs` —
`Letflow.Repo.Migrations.CreateEventIdempotency`.

**Table-name decision: `event_idempotency`, not `plat_event_idempotency`.** REQ-023 leaves
this to the implementer and asks for a citation either way
(`requirements.yaml:938–940`). R-Co's `plat_` prefix denotes a platform/cross-tenant table,
and R-Co's own design doc flags this specific table as an *exception* to its own prefix
convention: "one new `plat_`-prefixed table that is *itself* per-tenant … this is NOT the
cross-tenant `platform.platform_migrations` case"
(`src/design/par-01-monthly-range-partitioning.md:203–209`), confirmed by
`1147:31–46`'s PER_TENANT classification. Letflow's sidecar is unambiguously per-tenant —
0003's closing paragraph: "a cross-tenant-shared sidecar table would reintroduce exactly
the shared-table blast-radius risk Decision B rejected" (`0003:304–309`). Carrying over a
prefix whose meaning Letflow's design explicitly rejects would import a known misnomer, so
the prefix is dropped and the domain-meaningful part of the name is preserved, which is
exactly what Decision A prescribes (`0003:98–103`).

PROVENANCE (historical, not current decision authority):
| Column | Ecto migration type | DB type | Null / default | Notes & citation |
|---|---|---|---|---|
| `id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` | Decision A; REQ-023's exception list does not include this table (`requirements.yaml:965–967`). This is why the uniqueness of `idempotency_key` is expressed as an explicit unique **index** (REQ-023 acceptance criterion 4) rather than as R-Co's `idempotency_key TEXT PRIMARY KEY` (`1147:201`). |
| `idempotency_key` | `:string` | `varchar(255)` | `NOT NULL` | ES-03's 1..255 bound, DB-enforced (`event_store.md:211`, `:38–39`). |
| `event_id` | `:binary_id` | `uuid` | `NOT NULL` | `1147:202`. Points at the event this key claimed. |
| `event_created_at` | `:utc_datetime_usec` | `timestamp` (precision 6) | `NOT NULL` | `1147:203` (there named `created_at`). Together with `event_id` this is the full `events` PK, which is what lets REQ-025 resolve the original record on a duplicate hit (`store.zig:638–703`). Renamed for the same disambiguation reason as §3.4. |
| `inserted_at` | via `timestamps(updated_at: false)` | `timestamp(0)` | `NOT NULL` | This row's own creation time. R-Co conflates the two into one column; separating them costs one column and removes an ambiguity. |

**Indexes:**

PROVENANCE (historical, not current decision authority):
| Index name | Columns | Unique | Why / citation |
|---|---|---|---|
| *(PK)* | `(id)` | yes | Decision A |
| `uq_event_idempotency_key` | `(idempotency_key)` | **yes** | **REQ-023 acceptance criterion 4.** This single index carries the whole ES-03 global-uniqueness invariant that R-Co previously split across `events.uq_event_idempotency` (`001:48–49`) and `events_archive.uq_event_archive_idempotency` (`013:20–21`). |
| `idx_event_idempotency_event` | `(event_id, event_created_at)` | no | R-Co `1147:206–207`; supports the duplicate-resolution lookup path (`store.zig:654–697`). |

PROVENANCE (historical, not current decision authority):
**No foreign key to `events`, deliberately.** The claimed event may legitimately live in
`events` *or* `events_archive` (R-Co additionally searches `events_ephemeral`;
`store.zig:670–675` enumerates all three), so an FK to `events` alone would break the
moment REQ-026's `archive/1` moves the row. R-Co's sidecar likewise carries no FK
(`1147:200–204`).

PROVENANCE (historical, not current decision authority):
**Why this table exists at all, and what it supersedes** — this is REQ-023 acceptance
criterion 4's second half and §7's moduledoc text. 0003 Decision C point **2(b)**
(`0003:277–282`) resolves `event_store.md`'s Open Question #1 (`event_store.md:451–460`),
which had recommended a two-phase check (insert into `events` with
`ON CONFLICT (idempotency_key) DO NOTHING`, then fall back to
`SELECT … FROM events_archive`). R-Co itself abandoned that recommendation:
`1147:162–165` removes `events`' unique index and `1147:192–193` removes the archive's,
stating "plat_event_idempotency supersedes its purpose"; `store.zig:588–598` writes the
sidecar first, in the same transaction, and never relies on `events`' own uniqueness
(`store.zig:705–727` explains that `ON CONFLICT` on `events` is now a parse error there,
since no arbiter index remains). Letflow adopts the resolved form from day one, which is
precisely what 2(b) instructs.

### 3.6 `events_archive`

Migration `20260816120005_create_events_archive.exs` —
`Letflow.Repo.Migrations.CreateEventsArchive`.

**Columns:** exactly `events`' column list from §3.1 — `event_id`, `created_at`,
`instance_id`, `event_type`, `payload`, `actor_id`, `sequence_number`, `idempotency_key`,
`metadata`, `global_seq`, `tenant_id` — with the same types, nullability and defaults,
**with two differences**:

| Difference | Value | Why / citation |
|---|---|---|
| `global_seq` | `:bigint`, `NOT NULL`, **no sequence, no default** (not `:bigserial`) | The value is *copied* from the `events` row being archived, never freshly allocated. R-Co: `global_seq BIGINT NOT NULL` (`003:19`, `1147:178`). |
| `archived_at` | `:utc_datetime_usec`, `NOT NULL`, `default: fragment("(now() AT TIME ZONE 'utc')")` | REQ-023 names it (`requirements.yaml:936–937`); R-Co `003:20`, `1147:180`. |

**Primary key:** `(event_id, created_at)` — same composite shape as `events`, for the same
0003 Decision C 2(a) reason; R-Co widened this table's PK in the same migration
(`1147:181`, versus the bare `event_id PRIMARY KEY` of `003:10`).

**No `timestamps()`** — `created_at` and `archived_at` are the table's time columns.

**Indexes:**

| Index name | Columns | Unique | Why / citation |
|---|---|---|---|
| *(PK)* | `(event_id, created_at)` | yes | `1147:181` |
| `idx_archive_instance` | `(instance_id, sequence_number)` | no | `003:23–24`, `1147:184` |
| `idx_archive_type` | `(event_type)` | no | `003:26–27`, `1147:185` |
| `idx_archive_time` | `(created_at)` | no | `003:29–30`, `1147:186` |

**Deliberately NOT created:** `uq_event_archive_idempotency` on `(idempotency_key)`
(`013:20–21`) — superseded by §3.5's sidecar, exactly as R-Co did at `1147:192–193`. And
the tenant-prefixed archive indexes (`027:18–22`, `1147:187–190`), for the same
degenerate-selectivity reason as §3.1.2.

**No foreign keys** — same reasons as §3.1.3.

---

## 4. Migration file plan

Six files, one table per file, per 0003 Decision A's "one schema-defining concern per
migration via the `Ecto.Migration` DSL" (`0003:29–35`). All six live in
`priv/repo/migrations/` as REQ-023 acceptance criterion 1 requires, all six use the §2.2
guard, and all six are registered in `tenant_scoped_migrations/0` (§5.2).

| # | Filename | Migration module | Creates | Ordering constraint |
|---|---|---|---|---|
| 1 | `20260816120001_create_events.exs` | `Letflow.Repo.Migrations.CreateEvents` | `events` + 4 indexes (§3.1) | must precede #4 (FK target) |
| 2 | `20260816120002_create_instance_sequence.exs` | `Letflow.Repo.Migrations.CreateInstanceSequence` | `instance_sequence` (§3.2) | none |
| 3 | `20260816120003_create_instance_projections.exs` | `Letflow.Repo.Migrations.CreateInstanceProjections` | `instance_projections` + 1 partial index (§3.3) | none |
| 4 | `20260816120004_create_event_payload_store.exs` | `Letflow.Repo.Migrations.CreateEventPayloadStore` | `event_payload_store` + composite FK + 1 unique index (§3.4) | **after #1** |
| 5 | `20260816120005_create_events_archive.exs` | `Letflow.Repo.Migrations.CreateEventsArchive` | `events_archive` + 3 indexes (§3.6) | none |
| 6 | `20260816120006_create_event_idempotency.exs` | `Letflow.Repo.Migrations.CreateEventIdempotency` | `event_idempotency` + 2 indexes (§3.5) | none |

**Timestamp prefixes:** the six literal values above are the design's proposal; ELIXIR-DEV
may substitute real UTC-clock timestamps generated at implementation time, subject to three
hard constraints: (a) every value sorts strictly after `20260816090045` (REQ-022's shipped
migration); (b) the relative order in the table above is preserved; (c) the **same integers**
appear in `tenant_scoped_migrations/0` (§5.2) — a mismatch there silently changes which
migrations a tenant schema receives.

**`:prefix` threading — exactly where it goes.** In each file's `change/0`:

- `create table(<name>, primary_key: false, prefix: prefix())`
- `create index(...)` / `create unique_index(...)` — **each one** takes its own
  `prefix: prefix()`; the index does not inherit the table's prefix.
- `references(:events, ...)` inside #4 takes **no** `:prefix` option — it inherits the
  referencing table's prefix automatically
  (`deps/ecto_sql/.../postgres/connection.ex:1872`). Passing one explicitly would work too
  but is redundant.
- Everything above sits inside the `if prefix() do … end` guard; the `else` branch does
  nothing whatsoever.

**Reversibility** (`backend_developer_guide.md` §3.7): every operation used is
auto-reversible by `change/0` (`create table`, `create index`, `create unique_index`). No
`execute/1`, no `execute/2`, no raw SQL anywhere in these six files — the `:bigserial`
choice in §3.1.1 is what removes the last reason to reach for `execute/2`.

**Demonstrating acceptance criterion 1** (ELIXIR-DEV at Step 2a / TEST-DESIGNER at Step 3;
this design specifies the method, not the test code): call
`Letflow.TenantProvisioning.provision_tenant_schema/1` for a real tenant id, then
`replay_migrations/1` with the default source, then assert all six tables exist under that
schema and **not** under `public`:

```
SELECT table_name FROM information_schema.tables WHERE table_schema = $1
  -- $1 = the provisioned schema name; expect all six table names present
SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'
  -- expect none of the six present
```

Note the `Ecto.Adapters.SQL.Sandbox` caveat REQ-022's design already flagged for exactly
this kind of test (`req022-...md:446–455`).

---

## 5. Module plan

### 5.1 `Ecto.Schema` modules — `lib/letflow/event_store/`

REQ-023 creates **schema modules only**. No `lib/letflow/event_store.ex` context module is
created here; `Letflow.EventStore` is REQ-025/REQ-026's artefact.

| Module | File | Table |
|---|---|---|
| `Letflow.EventStore.Event` | `lib/letflow/event_store/event.ex` | `events` |
| `Letflow.EventStore.InstanceSequence` | `lib/letflow/event_store/instance_sequence.ex` | `instance_sequence` |
| `Letflow.EventStore.InstanceProjection` | `lib/letflow/event_store/instance_projection.ex` | `instance_projections` |
| `Letflow.EventStore.StoredPayload` | `lib/letflow/event_store/stored_payload.ex` | `event_payload_store` |
| `Letflow.EventStore.ArchivedEvent` | `lib/letflow/event_store/archived_event.ex` | `events_archive` |
| `Letflow.EventStore.IdempotencyRecord` | `lib/letflow/event_store/idempotency_record.ex` | `event_idempotency` |

`StoredPayload` and `IdempotencyRecord` deliberately do not mirror their table names
literally: `EventPayloadStore` would read as a *store* (a context module) rather than a row
struct, the same ambiguity `req022-tenant-schema-provisioning.md:80–92` avoided by naming
the `tenant_schemas` row struct `Registration`. `StoredPayload` and `IdempotencyRecord` name
what a row *is*. The table↔module mapping above is the authoritative one.

**Settings common to all six modules:**

- `@primary_key false` on `Event` and `ArchivedEvent` (composite PK is declared per-field);
  `@primary_key {:id, :binary_id, autogenerate: true}` on `StoredPayload` and
  `IdempotencyRecord` (matching every existing schema in this codebase, e.g.
  `lib/letflow/tenant_provisioning/registration.ex:24`);
  `@primary_key {:instance_id, :binary_id, autogenerate: false}` on `InstanceSequence` and
  `InstanceProjection` (natural, caller-supplied PK — `autogenerate: false` is deliberate:
  the instance id is minted by the engine, never by these rows).
- **No `@foreign_key_type`** — no `belongs_to`/`has_many` association is declared on any of
  the six, matching this codebase's existing convention of a plain `field(:x, Ecto.UUID)`
  even where a DB-level FK exists (`registration.ex:15–18`,
  `lib/letflow/identity/tenant_role.ex:34`).
- **No `@schema_prefix`.** These tables live in *many* schemas, one per tenant; pinning a
  single prefix at compile time would be wrong. Every query and write must pass
  `prefix: schema_name` at call time — REQ-025/REQ-026's responsibility, stated here as
  INV-EV-8 (§6).
- `@type t :: %__MODULE__{}` on each module (precedent: `registration.ex:33`).
- UUID-typed non-primary-key columns are declared `field(:x, Ecto.UUID)`, matching all four
  existing occurrences in this codebase (`registration.ex:26`, `identity/user.ex:33`,
  `identity/group.ex:25`, `identity/tenant_role.ex:34`).

**Field declarations** (declarations only — not code blocks):

`Letflow.EventStore.Event` — `schema "events"`:

```
field(:event_id, Ecto.UUID, primary_key: true)
field(:created_at, :utc_datetime_usec, primary_key: true)
field(:instance_id, Ecto.UUID)
field(:event_type, :string)
field(:payload, :map)
field(:actor_id, Ecto.UUID)
field(:sequence_number, :integer)
field(:idempotency_key, :string)
field(:metadata, :map, default: %{})
field(:global_seq, :integer, read_after_writes: true)
field(:tenant_id, Ecto.UUID)
```

`:integer` is the correct Ecto field type for a `bigint`/`bigserial` column (Ecto has no
separate `:bigint` *schema* type; `:bigint`/`:bigserial` are *migration* types).
`read_after_writes: true` on `global_seq` is required because the value is assigned by the
database sequence, never by the changeset.

PROVENANCE (historical, not current decision authority):
`event_id` and `created_at` carry **no `autogenerate`**. This is deliberate and is the
single most easily-missed detail in this design: REQ-025 must mint `event_id` exactly once
and bind the *same* value into `events`, `event_idempotency` and (for large payloads)
`event_payload_store`, and must bind one `created_at` value into all three as well. R-Co
shipped and then fixed the exact bug this prevents — two independent `gen_random_uuid()`
evaluations orphaning the sidecar row from the event it points at
(`store.zig:623–636`) — and separately documents binding "the SAME created_at" across
statements (`store.zig:856–864`).

`Letflow.EventStore.ArchivedEvent` — `schema "events_archive"`: identical field list to
`Event`, except `global_seq` is `field(:global_seq, :integer)` (no `read_after_writes` —
the value is copied, §3.6) plus `field(:archived_at, :utc_datetime_usec)`.

`Letflow.EventStore.InstanceSequence` — `schema "instance_sequence"`:

```
field(:next_seq, :integer, default: 1)
```

(`instance_id` is the `@primary_key`.)

`Letflow.EventStore.InstanceProjection` — `schema "instance_projections"`:

```
field(:tenant_id, Ecto.UUID)
field(:status, Ecto.Enum,
      values: [active: "ACTIVE", completed: "COMPLETED", cancelled: "CANCELLED", error: "ERROR"],
      default: :active)
field(:last_event_seq, :integer, default: 0)
timestamps(inserted_at: :started_at, type: :utc_datetime_usec)
```

The keyword-list `values:` form is what maps Elixir's idiomatic `:active` atom onto R-Co's
stored `"ACTIVE"` string; `Ecto.Enum` supports exactly this
(`deps/ecto/lib/ecto/enum.ex:85–88`). This is the Decision A "TEXT column with
comment-documented allowed values becomes an `Ecto.Enum`" swap (`0003:104–109`) applied to
`001:85–86`.

`Letflow.EventStore.StoredPayload` — `schema "event_payload_store"`:

```
field(:event_id, Ecto.UUID)
field(:event_created_at, :utc_datetime_usec)
field(:payload, :map)
field(:byte_size, :integer)
timestamps(updated_at: false)
```

`Letflow.EventStore.IdempotencyRecord` — `schema "event_idempotency"`:

```
field(:idempotency_key, :string)
field(:event_id, Ecto.UUID)
field(:event_created_at, :utc_datetime_usec)
timestamps(updated_at: false)
```

**Function signatures — every function that will exist, fully specified.** Error shape is
`Ecto.Changeset.t()` carrying `valid?: false` plus field errors; none of these functions
touch the database, so none of them returns an `{:ok, _} | {:error, _}` tuple — the
`{:ok, struct} | {:error, changeset}` boundary is `Repo.insert/2`'s, inside REQ-025/026's
context module (`backend_developer_guide.md` §3.5).

```
# Letflow.EventStore.Event
@type t :: %Letflow.EventStore.Event{}
@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast:             [:event_id, :created_at, :instance_id, :event_type, :payload,
#                      :actor_id, :sequence_number, :idempotency_key, :metadata, :tenant_id]
#   validate_required:[:event_id, :created_at, :instance_id, :event_type, :payload,
#                      :actor_id, :sequence_number, :idempotency_key, :tenant_id]
#   validate_length(:idempotency_key, min: 1, max: 255)   -- ES-03, event_store.md:211
#   validate_length(:event_type, min: 1, max: 128)        -- ES-05, event_store.md:242
#   unique_constraint([:instance_id, :sequence_number], name: :uq_event_sequence)
#   NOTE: global_seq is NOT castable -- assigned by the database sequence.

# Letflow.EventStore.ArchivedEvent
@type t :: %Letflow.EventStore.ArchivedEvent{}
@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast/validate_required: Event's field list plus :global_seq and :archived_at
#   (global_seq IS castable here -- it is copied from the source events row, §3.6)

# Letflow.EventStore.InstanceSequence
@type t :: %Letflow.EventStore.InstanceSequence{}
@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast: [:instance_id, :next_seq]; validate_required: [:instance_id]
#   validate_number(:next_seq, greater_than: 0)

# Letflow.EventStore.InstanceProjection
@type t :: %Letflow.EventStore.InstanceProjection{}
@type status :: :active | :completed | :cancelled | :error
@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast: [:instance_id, :tenant_id, :status, :last_event_seq]
#   validate_required: [:instance_id, :tenant_id, :status]
@spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast: [:status, :last_event_seq]   -- instance_id/tenant_id structurally not castable
#   validate_required: [:status, :last_event_seq]
#   validate_number(:last_event_seq, greater_than_or_equal_to: 0)
@spec terminal?(status()) :: boolean()
#   true for :completed and :cancelled only; false for :active and :error.
#   Pure, no I/O. Exists so REQ-025's active-instance guard has one authoritative
#   definition of "terminated" (event_store.md:292 names exactly CANCELLED and
#   COMPLETED -- ERROR is NOT terminal for appends).

# Letflow.EventStore.StoredPayload
@type t :: %Letflow.EventStore.StoredPayload{}
@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast: [:event_id, :event_created_at, :payload, :byte_size]
#   validate_required: all four
#   validate_number(:byte_size, greater_than: 0)
#   unique_constraint(:event_id, name: :uq_event_payload_event)
#   foreign_key_constraint(:event_id)

# Letflow.EventStore.IdempotencyRecord
@type t :: %Letflow.EventStore.IdempotencyRecord{}
@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast: [:idempotency_key, :event_id, :event_created_at]
#   validate_required: all three
#   validate_length(:idempotency_key, min: 1, max: 255)
#   unique_constraint(:idempotency_key, name: :uq_event_idempotency_key)
```

**Functions that will deliberately NOT exist** — this list is normative; REVIEWER and
CODE-DESIGN-VALIDATOR should treat any of them appearing in Step 2a's output as a defect:

| Absent function | Module | Why |
|---|---|---|
| `update_changeset/2` | `Event` | **REQ-023 acceptance criterion 3**; 0003 Decision C **point 1** (`0003:254–262`); `event_store.md:274` invariant 1 |
| `changeset/2` (generic) | `Event`, `ArchivedEvent` | A generically-named changeset invites reuse on an update path. The name `insert_changeset/2` makes the single legal use site explicit. |
| `update_changeset/2` | `ArchivedEvent` | The archive is append-only for the same reason `events` is (`003:6–7`). |
| `update_changeset/2` | `IdempotencyRecord` | A claimed idempotency key is never re-pointed; that would break ES-03 durability. |
| `update_changeset/2` | `StoredPayload` | A payload belongs to an immutable event. |
| `update_changeset/2` | `InstanceSequence` | The increment is an atomic single-statement `UPDATE`/upsert inside REQ-025's transaction (`event_store.md:353–367`). A changeset-mediated read-modify-write would reintroduce the lost-update race the `SELECT … FOR UPDATE` protocol exists to prevent. `insert_changeset/2` (first-append row creation) is the only changeset here. |
| any `delete_*`, `Repo.*` call, or query function | all six | REQ-023 is schema-only; querying and writing belong to REQ-025/REQ-026. |

`InstanceProjection.update_changeset/2` **does** exist, and that asymmetry is the point:
0003 Decision C point 3 (`0003:284–294`) classifies projection tables as ordinary mutable
CRUD tables whose correctness invariant ("matches a fold over the event log") is a runtime
concern, not a schema one.

### 5.2 The one edit to `Letflow.TenantProvisioning`

`tenant_scoped_migrations/0` currently returns `[]`
(`lib/letflow/tenant_provisioning.ex:196–198`). REQ-022's design §3.4 requires every
tenant-scoped migration to register itself here. REQ-023 is the first requirement to do so.

```
@spec tenant_scoped_migrations() :: [{version :: pos_integer(), module()}]
```

**The `@spec` is unchanged.** The returned list becomes the six `{version, module}` pairs
from §4's table, in ascending version order. Behavior added (see §2.4 for why it is
required, not optional):

```
tenant_scoped_migrations/0:
  for each {version, module, filename} in a module-attribute manifest:
      unless Code.ensure_loaded?(module):
          Code.require_file(Path.join([Application.app_dir(:letflow, "priv"),
                                       "repo", "migrations", filename]))
  return [{version, module}, ...] in ascending version order
```

Notes ELIXIR-DEV must not lose:

- `Code.require_file/1` is idempotent (it returns `nil` for an already-required file), and
  the `Code.ensure_loaded?/1` guard additionally covers the case where a plain
  `mix ecto.migrate` in the same VM already defined the module via `Code.compile_file/1`
  (`deps/ecto_sql/lib/ecto/migrator.ex:733–742`) — which `require_file` would not know
  about, and would otherwise recompile with a "redefining module" warning.
- `Application.app_dir(:letflow, "priv")` resolves through `_build`, where `priv/` is
  linked, so it works in dev, test and a release alike.
- The manifest's version integers **must** equal the migrations' filename timestamp
  prefixes (§4). `Ecto.Migrator` raises `Ecto.MigrationError` on duplicate versions
  (`deps/ecto_sql/lib/ecto/migrator.ex:708–721`), which catches transcription errors, but
  it cannot catch a *wrong-but-unique* version.
- This function stays free of I/O beyond module loading — no `Repo` call, no query.

---

## 6. Invariants

PROVENANCE (historical, not current decision authority):
| id | Invariant | Enforced where | Source |
|---|---|---|---|
| INV-EV-1 | **Event immutability.** No function anywhere in `lib/letflow/event_store/` may produce an `UPDATE` against a committed `events` row. There is no `update_changeset/2` on `Letflow.EventStore.Event`. This is an application/schema-module-layer invariant; Ecto migrations have no "no updates" DDL primitive. | `Event`'s function list (§5.1) + its moduledoc (§7.1) | 0003 Decision C point 1 (`0003:254–262`); `event_store.md:274` |
| INV-EV-2 | **`events`' primary key is `(event_id, created_at)`** from the first migration, before partitioning exists. | Migration #1 (§3.1) | 0003 Decision C point 2(a) (`0003:273–277`); `1147:133` |
| INV-EV-3 | **Idempotency uniqueness lives in exactly one place** — `event_idempotency.uq_event_idempotency_key`. Neither `events` nor `events_archive` carries a unique index on `idempotency_key`. | Migrations #1, #5, #6 (§3.1.2, §3.5, §3.6) | 0003 Decision C point 2(b) (`0003:277–282`); `1147:162–165, 192–193` |
| INV-EV-4 | **Per-instance sequence uniqueness.** `uq_event_sequence(instance_id, sequence_number)` is unique; the sequence value itself is allocated only under the `instance_sequence` row lock. | Migration #1 index + REQ-025's transaction | ES-02 (`event_store.md:276, 353–368`) |
| INV-EV-5 | **One `event_id` and one `created_at` per append, minted once and bound everywhere.** The `events` row, its `event_idempotency` row, and its optional `event_payload_store` row must carry byte-identical values. Enforced by the deliberate absence of `autogenerate` on `Event.event_id` and by the composite FK in §3.4. | §5.1 field declarations + §3.4 FK; REQ-025 honours it | `store.zig:623–636, 835–864` |
| INV-EV-6 | **Large-payload split is invisible below the append/read layer.** The schema stores `{"$ref": "<uuid>"}` in `events.payload` and the real bytes in `event_payload_store`; nothing in the migration layer enforces the 4096 boundary. | REQ-025 (write) / REQ-026 (read) | `event_store.md:286`; `requirements.yaml:913–916` |
| INV-EV-7 | **`byte_size` is the pre-storage byte length** of the original payload, not `octet_length` of the stored `jsonb`. | `StoredPayload`'s moduledoc + REQ-025 | §3.4 |
| INV-EV-8 | **No `@schema_prefix` on any event-store schema module.** Every read and write must pass `prefix: schema_name` explicitly, where `schema_name` comes from a `tenant_schemas` registry row. | §5.1; REQ-025/026 call sites | 0003 Decision B (`0003:37–45, 216–227`) |
| INV-EV-9 | **`instance_projections` is derived state.** Its correctness boundary is "matches a fold over `events`", which no column constraint expresses; the schema is migrated like any ordinary CRUD table. | Migration #3; a future property test | 0003 Decision C point 3 (`0003:284–294`) |
| INV-EV-10 | **Only `COMPLETED` and `CANCELLED` are terminal for appends.** `ERROR` is not. Codified once as `InstanceProjection.terminal?/1`. | §5.1 | `event_store.md:292` invariant 10 |
| INV-EV-11 | **`global_seq` is monotone but not gap-free.** Rolled-back transactions consume sequence values. Consumers must treat it as a cursor, never as a count. | `Event`'s moduledoc; REQ-026's `read_global/1` | `event_store.md:278, 370–372` |
| INV-EV-12 | **No archived event may become unreadable.** Deleting an `events` row that has a `event_payload_store` row is blocked at the DB level (`on_delete: :restrict`) until REQ-026 decides how payloads travel to the archive (OQ-2). | §3.4 FK | `003:6–7`; `event_store.md:286` |
| INV-EV-13 | **No raw-SQL identifier interpolation is introduced by REQ-023.** All six migrations use the `Ecto.Migration` DSL with `prefix: prefix()`; the prefix value originates from `Registration.schema_name`, which REQ-022 already constrains to `tenant_[0-9a-f]{32}` by construction. | §4; `tenant_provisioning.ex:111–123` | `backend_developer_guide.md` §3.6; INV-7 in `security-invariants.md` |

---

## 7. Required moduledoc text (verbatim)

REQ-023 acceptance criteria 3, 4 and 5 each require a specific claim to appear in a
specific moduledoc. The text below is what must appear, so CODE-DESIGN-VALIDATOR,
REVIEWER and RELEASE-VALIDATOR can check it literally rather than by paraphrase.
ELIXIR-DEV may add surrounding prose but must not weaken or omit these sentences.

### 7.1 `Letflow.EventStore.Event` — acceptance criterion 3

```
This schema is append-only. It deliberately exposes no `update_changeset/2`,
no generic `changeset/2`, and no other function that can issue an UPDATE
against a committed `events` row — this is a deliberate immutability
invariant, per `docs/migration/decisions/0003-ecto-schema-strategy.md`
Decision C point 1 (append-only/immutability, the decision's first
top-level numbered point) and R-Co's `src/design/event_store.md` Key
invariant 1. Ecto's changeset-based `update/2` pattern does not
structurally forbid an update the way a database trigger or a restricted
grant would, so this invariant is enforced at the application/
schema-module layer, not by the migration file — 0003 point 1 states
exactly that. Adding an update path here is a defect, not an enhancement.
```

### 7.2 `Letflow.EventStore.IdempotencyRecord` — acceptance criterion 4

```
This is the dedicated idempotency sidecar table
(`event_idempotency`), built from day one per
`docs/migration/decisions/0003-ecto-schema-strategy.md` Decision C point
2(b) — the partitioning point's second lettered sub-point, distinct from
2(a)'s primary-key-shape concern: "Letflow adopts the sidecar-table
approach for idempotency from the start (not deferred to partitioning
time)."

This table supersedes R-Co's `src/design/event_store.md` "Open Question
#1" recommendation of a two-phase deduplication check (INSERT into
`events` with ON CONFLICT (idempotency_key) DO NOTHING, then a fallback
SELECT against `events_archive`). 0003 already resolved that open
question in favour of the sidecar table, so REQ-025's append and
REQ-026's archive check and write THIS table for idempotency — not a raw
unique index scattered across `events` and `events_archive` separately.
Neither `events` nor `events_archive` carries a unique index on
`idempotency_key`; the unique index `uq_event_idempotency_key` on this
table is the single enforcement point. R-Co reached the same end state:
`migrations/1147_par01_events_partitioning.sql` removes both of those
indexes and states that its `plat_event_idempotency` sidecar "supersedes
their purpose."
```

### 7.3 `Letflow.EventStore.InstanceProjection` — acceptance criterion 5

```
This table's *schema* is event-store scope — this requirement (REQ-023)
owns it, because R-Co's `src/design/event_store.md` "DB tables / columns
per operation" section shows `Store.append()` reading and writing
`instance_projections` directly for the ES-01 active-instance guard and
the DB-03 `last_event_seq` update.

Its *meaningful population at instance start* is EE-01 / S3 territory
(`src/engine/`, not built yet). Do not read this migration as
instance-engine work landing early. The engine-owned columns R-Co's
`migrations/001_event_store.sql` also carries — `definition_id`,
`correlation_key`, `current_nodes`, `variables`, `error_detail`,
`completed_at`, `cancelled_at`, and the `uq_instance_correlation` /
`idx_proj_definition` indexes that depend on them — are deliberately not
created here; S3 adds them in its own migration.
```

### 7.4 Additional moduledoc content (not acceptance-criteria-driven, but required by this design)

- `Letflow.EventStore.ArchivedEvent`: must state that it is append-only for the same reason
  `Event` is, and that it carries no unique index on `idempotency_key` (INV-EV-3).
- `Letflow.EventStore.StoredPayload`: must state INV-EV-7 (`byte_size` semantics) and the
  `on_delete: :restrict` rationale + OQ-2.
- `Letflow.EventStore.InstanceSequence`: must state that the increment is performed by
  REQ-025 as a single atomic statement under a row lock and that no `update_changeset/2`
  exists for that reason (INV-EV-4).
- All six: must state INV-EV-8 (no `@schema_prefix`; callers pass `prefix:`).

---

## 8. Cross-module dependencies

PROVENANCE (historical, not current decision authority):
| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Repo` (`lib/letflow/repo.ex`) | schemas → Repo | Only at REQ-025/026 call time. REQ-023 adds no `Repo` call of its own. |
| `Letflow.TenantProvisioning` | REQ-023 → REQ-022 | **REQ-023 edits `tenant_scoped_migrations/0`** (§5.2) — the one-line-scope edit `req022-...md:441–445` mandates for every tenant-scoped requirement, here plus the module-loading fix of §2.4. No other shipped REQ-022 code changes; both `@spec`s stay identical. |
| `Letflow.TenantProvisioning.Registration` | REQ-025/026 → REQ-022 | Source of the `schema_name` every event-store query must pass as `prefix:` (INV-EV-8). |
| `Ecto.Migrator` | `tenant_scoped_migrations/0` → ecto_sql | Existing runtime dependency introduced by REQ-022; REQ-023 adds the requirement that the listed modules be loadable (§2.4). |
| `priv/repo/migrations/` | REQ-023 → shared directory | Adds six files. Modifies none of the seven existing migrations. |
| REQ-024 (`event_type_registry`, `Letflow.EventStore.Registry`) | REQ-025 → REQ-024 | `events.event_type` has **no DB FK** to it (§3.1.3); the relationship is enforced by `validate_payload/2` before any write. REQ-023 and REQ-024 are independent at the schema level and may proceed in either order. |
| REQ-025 (`Letflow.EventStore.append/1`) | REQ-025 → REQ-023 | Consumes all six tables. Contract points REQ-025 must honour: INV-EV-5 (one `event_id`/`created_at`, bound everywhere), the non-castable `global_seq`, `tenant_id` supplied from auth context, `InstanceProjection.terminal?/1` for the guard, sidecar-first ordering (`store.zig:588–598`). |
| REQ-026 (`read/2`, `read_global/1`, `point_in_time/3`, `archive/1`) | REQ-026 → REQ-023 | Consumes `events`, `event_payload_store`, `events_archive`, `event_idempotency`. Must resolve OQ-1 (missing `event_retention_policies`) and OQ-2 (payload survival across archival). |
| S3 / EE-01 (`src/engine/` port) | S3 → REQ-023 | Owns population of `instance_projections` and the `ALTER TABLE` that adds its engine columns (§3.3, OQ-7). |
| `docs/agents/instructions/security-invariants.md` INV-7 | SECURITY-REVIEWER → REQ-023 | Satisfied by INV-EV-13: REQ-023 introduces zero raw-SQL identifier interpolation. |

---

## 9. Open questions — explicitly listed, not silently resolved

PROVENANCE (historical, not current decision authority):
**OQ-1 (MAJOR, affects REQ-026): `event_retention_policies` has no owning requirement.**
REQ-026's `archive/1` is specified to consult it ("per-event-type policies from
`event_retention_policies` take precedence", `requirements.yaml:1126`), and
`event_store.md:327` lists it as a table the `archive` operation reads. R-Co creates it at
`003_event_archive.sql:35–52` and still writes it from
`Store.upsertRetentionPolicy()` (`store.zig:1240`). But REQ-023's scope is exactly six
tables and this is not one of them, and a grep of `docs/requirements.yaml` for
"retention" returns only REQ-026's own three lines (1125–1127) — **no requirement creates
this table.** This design does **not** create it, because doing so would silently expand
REQ-023's acceptance-criteria-bounded scope. Resolution needed before REQ-026 starts:
either extend REQ-026's scope to create it, or file it as its own requirement. Reported as
an issue in this step's handoff.

PROVENANCE (historical, not current decision authority):
**OQ-2 (MAJOR, addressed to REQ-026): how do large payloads survive archival?**
`event_payload_store` rows are keyed to `events` rows. REQ-026's `archive/1` copies to
`events_archive` and deletes from `events` (`event_store.md:294, 324–329`). Three
candidate resolutions, none of which any source settles: (a) copy the payload bytes inline
into `events_archive.payload` at archive time, dropping the `$ref` indirection for archived
events; (b) add an `events_archive_payload_store` sibling table; (c) re-point the existing
`event_payload_store` row at the archive row (requires relaxing or re-targeting the FK).
R-Co offers **no** precedent, because `Store.archive()` was retired there
(`store.zig:1287–1310`, §10 C-1) — its `ON DELETE CASCADE` was never exercised by archival
and is therefore not evidence for option (a) or any other. This design's `on_delete:
:restrict` (§3.4) deliberately makes the question fail loudly rather than silently deleting
tenant data; it does not answer it.

**OQ-3 (MINOR): is a cross-tenant global event stream ever required?** Under Decision B
each tenant schema owns its own `global_seq` sequence (§3.1.1), so `global_seq` orders
events across *instances* within one tenant — which is all ES-04 asks for
(`event_store.md:213`) and all REQ-026's `read_global/1` specifies
(`requirements.yaml:1119–1122`). Whether a platform-wide, cross-tenant ordered stream
(for a global admin console or an outbox/CDC consumer) is ever needed is not addressed by
0003, `event_store.md`, or any Letflow requirement. Flagged rather than pre-solved,
because solving it later means either a `platform`-schema sequence or an ordering key that
is not a bare integer — a change with real blast radius that should be made deliberately.

PROVENANCE (historical, not current decision authority):
**OQ-4 (MINOR): PAR-03's `retention_class` / `events_ephemeral` machinery is not ported.**
R-Co's current `store.zig` routes appends to either `events` or `events_ephemeral` based on
an event type's retention class (`store.zig:705–770`). No Letflow requirement mentions
either, and 0003 Decision C point 2 defers partitioning (`0003:264–272`), of which PAR-03
is a downstream consequence. Recorded so its absence reads as scoped-out, not overlooked.

**OQ-5 (MINOR): should Letflow's repo move to `timestamptz` project-wide?** R-Co uses
`TIMESTAMPTZ` throughout; Letflow's `:utc_datetime_usec` emits `timestamp` without time
zone (§3.1.4). Changing this means `migration_timestamps: [type: :timestamptz]` in repo
config, which retroactively affects S1's four shipped identity tables — outside REQ-023's
scope and not a decision one requirement should make unilaterally. This design mitigates
the only concrete hazard (an implicit cast picking up a non-UTC session time zone) by
writing the default as `(now() AT TIME ZONE 'utc')`.

**OQ-6 (MINOR): should the `event_type_registry` classification question be re-confirmed
here?** REQ-024 flags it as open (`requirements.yaml:1023–1033`). REQ-023 does not create
that table and takes no position; noted only so REQ-024's designer doesn't assume REQ-023
settled it in passing.

**OQ-7 (INFORMATIONAL): `instance_projections`' engine columns land in an S3 migration.**
§3.3 lists the seven columns and two indexes S3 must add. Not an unresolved design
question — a named forward dependency, recorded so the S3 designer does not have to
re-derive it from `001_event_store.sql`.

---

## 10. Contradictions found between R-Co's design doc and R-Co's actual source

REQ-023 instructed this design to cross-check `event_store.md` against R-Co's real
Zig/SQL and to say so explicitly where they disagree, rather than glossing over it. Four
disagreements were found. All were resolved in favour of the actual source plus 0003,
which is what Letflow ships against.

PROVENANCE (historical, not current decision authority):
**C-1 — `Store.archive()` no longer exists in R-Co.** `event_store.md:115–119` documents
`Store.archive(retention_days) StoreError!u64`, and invariants 11 and 12
(`event_store.md:294–296`) describe its behaviour. `src/event_store/store.zig:1287–1310`
states it has been **removed**: "Store.archive() (ES-07's row-level archival-move
mechanics) has been REMOVED. Its DELETE FROM events … pattern is incompatible with PAR-03's
'No DELETE statement SHALL run against events or events_archive at any point' rule",
superseded by whole-partition `DETACH/ATTACH/DROP` in
`src/scheduler/partition_retention.zig`. **Impact on Letflow:** REQ-026 ports a function
that no longer exists upstream, so it has no current reference implementation — only
`event_store.md`'s prose. It also means R-Co's `ON DELETE CASCADE` on
`event_payload_store` carries no information about archival payload handling (OQ-2). The
`events_archive` *table* is unaffected: `1147:167–190` still creates it.

PROVENANCE (historical, not current decision authority):
**C-2 — `event_store.md`'s idempotency invariants 4 and 5 and Open Question #1 are
obsolete.** Invariant 4 (`event_store.md:280`) asserts a `uq_event_idempotency` UNIQUE
index on `events(idempotency_key)` and an `ON CONFLICT (idempotency_key) DO NOTHING`
append; invariant 5 and Open Question #1 (`:282, :451–460`) recommend adding a matching
index on `events_archive` plus a two-phase check. R-Co's real migrations removed **both**
indexes (`1147:162–165, 192–193`) and `store.zig:705–727` records that `ON CONFLICT` on
`events` is now a parse error there because no arbiter index remains. This is exactly the
supersession 0003 Decision C 2(b) already recorded, and §3.5/§7.2 encode it — so this
contradiction is *resolved by an existing Letflow decision*, not newly decided here.

PROVENANCE (historical, not current decision authority):
**C-3 — `event_payload_store.created_at` means two different things in two R-Co
revisions.** `012_event_retention.sql:21` declares `created_at TIMESTAMPTZ NOT NULL DEFAULT
NOW()` — the side-table row's own insert time. `1147:218` rebuilds the table with
`created_at TIMESTAMPTZ NOT NULL` and `store.zig:843–849` binds the *event's* `created_at`
into it, for the composite FK. Same column name, two meanings, silently swapped. Letflow
splits them: `event_created_at` (FK component) and `inserted_at` (row's own time), matching
the unambiguous name R-Co itself used for the same job on `webhook_deliveries`
(`event_created_at`, `1147:250`).

**C-4 — `event_store.md`'s `event_payload_store.event_id` uniqueness is single-column;
R-Co's shipped table is composite.** `event_store.md:440` says "`event_payload_store.event_id`
has a UNIQUE index"; `012:18` matches. `1147:221` replaced it with
`UNIQUE (event_id, created_at)`, forced by the widened parent PK. Letflow keeps the
**single-column** unique index (§3.4) — it is strictly stronger and matches REQ-023's own
wording (`requirements.yaml:933`), while the composite constraint the FK needs is
satisfied on the parent side by `events`' own primary key.

PROVENANCE (historical, not current decision authority):
*(Additionally, `event_store.md:4` lists the module's files as `store.zig` and
`registry.zig` only, while `src/event_store/` actually contains three files —
`platform.zig` (12 lines) exists too. `docs/migration/stage-2-event-store-definitions.md:7`
already has the corrected count of 3, so Letflow's own stage doc is right and only R-Co's
header is stale. Noted, not acted on; `platform.zig` is REQ-026's scope.)*

---

## 11. Acceptance-criteria traceability

| REQ-023 acceptance criterion | Concrete design element |
|---|---|
| 1. "priv/repo/migrations gains migrations for events, instance_sequence, event_payload_store, events_archive, the idempotency sidecar table, and instance_projections, all using Ecto's `:prefix` option and applying cleanly against at least one provisioned tenant schema via REQ-022's migration-replay mechanism" | §4 — six named files with module names, ordering constraints, and exactly where `prefix: prefix()` goes on `create table`/`create index`/`references`. §2.2 — the mandatory guard pattern, verified against the shipped `test/support/req022_migration_fixture.ex`. §2.4 + §5.2 — the module-loading fix without which the replay raises against an already-migrated DB. §4's closing paragraph — the `information_schema` method for demonstrating the criterion, including the negative check against `public`. |
| 2. "events' migration defines the primary key as (event_id, created_at), not a bare event_id, per 0003 Decision C point 2(a)" | §3.1's table (`event_id` and `created_at` both `primary_key: true`) + the **Primary key** paragraph quoting `0003:273–277`; INV-EV-2. Also applied to `events_archive` (§3.6). |
| 3. "the events Ecto.Schema module has no update_changeset/2 or any function that issues an UPDATE against a committed row; the moduledoc states this is a deliberate immutability invariant per 0003 Decision C point 1" | §5.1's "Functions that will deliberately NOT exist" table (first two rows) and the `Event` signature block, which lists `insert_changeset/2` as the module's only function; §7.1 gives the verbatim moduledoc text; INV-EV-1. |
| 4. "the idempotency sidecar table has a unique index on idempotency_key and its own moduledoc states it supersedes event_store.md's Open Question #1 two-phase-check recommendation per 0003's resolution" | §3.5 — the table, the `id`-PK-plus-`uq_event_idempotency_key`-unique-index shape that makes the required index a real, separately named index; §7.2 gives the verbatim moduledoc text; INV-EV-3 and §10 C-2 supply the supersession evidence from `1147:162–165, 192–193`. |
| 5. "instance_projections' moduledoc explicitly states its schema is event-store scope (this requirement) while its meaningful population is EE-01/S3 scope, not built here" | §7.3 gives the verbatim moduledoc text; §3.3 names the deferred engine columns concretely so the claim is actionable rather than rhetorical; OQ-7. |

**Every clause of REQ-023's `description` mapped:**

| REQ-023 description clause | Where |
|---|---|
| events' ten named columns + types | §3.1 table (all ten, plus `tenant_id` per Decision B with its own citation) |
| "payload (text/jsonb — inline; … over 4096 bytes get a `{"$ref": "<uuid>"}` pointer … enforced at the append logic layer in REQ-025, not the migration layer" | §3.1 `payload` row; §3.4; INV-EV-6; the explicit "no CHECK constraint" decision in §3.4 |
| "created_at (utc_datetime_usec — microsecond precision per ES-01)" | §3.1 `created_at` row + §3.1.4's exact DB-type statement |
| "primary key is (event_id, created_at), NOT a bare event_id PK" | §3.1 Primary key paragraph; INV-EV-2 |
| "No update path is exposed … state this explicitly in the schema moduledoc per Decision C point 1" | §5.1 absent-functions table; §7.1 |
| instance_sequence: instance_id PK, next_seq bigint default 1 | §3.2 |
| event_payload_store: event_id unique, payload, byte_size | §3.4 |
| events_archive: same shape as events plus archived_at | §3.6 |
| idempotency sidecar: naming choice with a citation; unique index on idempotency_key; per-tenant; supersedes Open Question #1 | §3.5 (name decision cited to `par-01…md:203–209` and `0003:304–309`); §7.2 |
| instance_projections: instance_id PK, status enum, last_event_seq, updated_at + the schema-vs-population moduledoc note | §3.3; §7.3 |
| "All tables use binary_id primary keys per Decision A except where noted (events' composite PK, instance_sequence/instance_projections' natural PK)" | §3.4 and §3.5 both take `binary_id` surrogate PKs precisely because they are *not* in that exception list; §3.2/§3.3 take the natural PKs; §3.1/§3.6 take the composite PK |
| "following … Decision C exactly (read in full before starting)" | §0 (read in full, cited by line range); every Decision C point cited at its point of use in §3, §5, §6 |
| "and REQ-022's schema-per-tenant provisioning mechanism (every table below uses Ecto's `:prefix` option, none targets the public default schema)" | §2 in full, including the §2.2 guard that is what actually keeps these tables out of `public` |
