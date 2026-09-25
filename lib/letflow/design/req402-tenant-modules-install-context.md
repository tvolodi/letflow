# Design: REQ-402 — tenant-scoped `tenant_modules` table, `Letflow.Modules.TenantModule` schema, `Letflow.Modules.Installs` install/list context

**Requirement:** REQ-402 (`docs/requirements.yaml`, search `id: REQ-402`, stage S11,
`depends_on: [REQ-400]`, letflow-queue task 791, GH-1776, owner ELIXIR-DEV)
**Decision record implemented:** `docs/migration/decisions/0039-platform-module-solution-layering.md`
D3 (mechanism files are core, live directly in `lib/letflow/modules/*.ex`) and D5
(per-tenant install, one transaction, 404-on-absence policy — the 404 route logic
itself is REQ-404's job, not this one).
**This document produces:** the migration's exact shape (§1), the `TenantModule`
Ecto schema (§2), `Letflow.Modules.Installs`' exact function signatures and `install/3`'s
transaction structure (§3), the second test fixture module `Letflow.Modules.FixtureDependent`
(§4), test specs per AC1–AC7 (§5), the SECURITY-REVIEWER checklist (§6), out-of-scope
restatement (§7), and an AC traceability map (§8). **No implementation code** — no
function bodies, no real `.ex`/`.exs` code blocks; signatures, type shapes, and
pseudocode only.

---

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-402 entry in full (title, description "BUILDS" 1–3,
  all 8 `acceptance_criteria` bullets, `depends_on: [REQ-400]`).
- `docs/migration/decisions/0039-platform-module-solution-layering.md` in full,
  particularly D3 (file-level split: `lib/letflow/modules/*.ex` one level deep is
  core mechanism — `Module`, `Catalog`, `Installs`, `TenantModule` named explicitly),
  D5 (tenant install semantics, transaction contents, `:ModulesManage` gate — gating
  itself is REQ-403's job, this requirement only needs to not preclude it), and the
  REVIEWER sign-off's R3 (tenant-scoped migration shape precedent).
- `lib/letflow/modules/catalog.ex` — full read of the real public API: `entry_modules/0`,
  `fetch/1` (`{:ok, module()} | {:error, :not_found}`), `permissions/0`, `role_grants/1`,
  `validate/1`/`validate/2`, `all_manifests/0`. `Installs.install/3` calls `fetch/1` to
  resolve an unknown module id and reads the resolved entry module's `manifest/0`
  directly for `depends_on`, `pack`, `version` — it does **not** need `all_manifests/0`.
- `lib/letflow/modules/module.ex` — full read of `Letflow.Modules.Module`'s
  `@callback manifest/0` / `t:manifest/0` (the exact map shape: `:id`, `:version`,
  `:depends_on`, `:pack`, `:permissions`, `:role_grants`, `:required_roles`,
  `:settings_schema`, `:route_policies`) and `@callback on_install/2` (`prefix`,
  `settings` → `:ok | {:error, term()}`, `@optional_callbacks`).
- `priv/repo/migrations/20260923010002_create_user_entity_type_grants.exs` — full
  read; the `if prefix() do` / `schema = prefix()` tenant-scoped guard shape this
  migration must follow exactly (§1 below cites it line-for-line).
- `lib/letflow/tenant_provisioning.ex` — `@tenant_scoped_migration_manifest`
  (list of `{version, module, filename}` triples, last entry
  `{20_260_923_010_002, Letflow.Repo.Migrations.CreateUserEntityTypeGrants,
  "20260923010002_create_user_entity_type_grants.exs"}`) and `tenant_scoped_migrations/0`
  (maps the manifest to `{version, module}`, loading each migration module via
  `ensure_migration_module_loaded!/2` since `priv/repo/migrations/*.exs` is not
  compiled into the app — `mix.exs` `elixirc_paths` is `["lib"]` (+ `test/support`
  under `:test`)). Registration is **both** halves: the manifest entry AND the guard
  pattern in the migration file itself.
- `priv/repo/migrations/` directory listing — latest tenant-scoped-shaped file is
  `20260923010002_create_user_entity_type_grants.exs`; latest of any kind is
  `20260923000001_add_storage_allowance_bytes_to_tenants.exs`. No file with a
  `20260925*` prefix exists yet.
- `test/support/tenant_fixture.ex` — full read. `@expected_tenant_tables` (47-entry
  alphabetically-ish maintained list, comment says "as of REQ-394"), and
  `expected_tenant_tables/0`. The oracle-rot guard test referenced by AC1 (design's
  own comment calls it "C6") lives in `test/letflow/support/tenant_fixture_test.exs`
  (not read in full here — TEST-DESIGNER's job — but its existence and shape is
  confirmed by this module's own moduledoc comments at lines 118–125).
- `lib/letflow/definitions/solution_pack.ex` — `install/3`'s full moduledoc and
  `@spec install(document :: map(), actor_id :: Ecto.UUID.t(), opts :: Definitions.opts()) ::
  {:ok, install_result()} | install_error()`, `Definitions.opts() :: [prefix: String.t()]`,
  `install_result()` (`pack_id, version, install_id, installed_definitions,
  installed_entity_definitions, variable_schemas_written, role_mapping_checklist,
  warnings`), `install_error()` (`{:error, :invalid_pack_document} |
  {:error, {:unknown_schema_version, _}} | {:error, :unsupported_pack_section} |
  {:error, {:malformed_variable_schema, _, _}} | {:error, Definitions.variable_schema_error()}
  | {:error, :duplicate_pack_install} | {:error, :missing_prefix} | Definitions.create_error()`).
  `document` is a **raw decoded-JSON map with string keys** — `install/3` owns the
  structural parse itself.
- `test/support/modules/fixture/fixture.ex`, `router.ex`, `marker_store.ex` — full
  read. `Letflow.Modules.Fixture`'s manifest (`id: "fixture"`, `depends_on: []`,
  `pack: nil`, `permissions: [:FixtureRead]`, `role_grants: %{TASK_WORKER: [:FixtureRead]}`),
  its `on_install/2` (writes to a public named-ETS `MarkerStore`, keyed by `prefix`),
  and `defmanifest/1`'s compile-time literal contract.
- `config/config.exs:60` (`config :letflow, :modules, []`) and `config/test.exs:259`
  (`config :letflow, :modules, [Letflow.Modules.Fixture]`).
- `lib/letflow/tenant_provisioning.ex:241-256` —
  `tenant_id_for_schema_name/1` (`"tenant_" <> hex` → `{:ok, Ecto.UUID.t()}` or
  `{:error, :invalid_schema_name}`) — available if `Installs` ever needs a tenant id,
  not required by this design (see §3.2 — `SolutionPack.install/3` derives it itself).
- `lib/letflow/plugs/authorize.ex:65,122` — confirms `conn.assigns[:scoped_opts]` is
  `[prefix: schema]`, the same `opts` shape `Installs`' functions take (REQ-403 will
  pass this straight through; not this requirement's concern beyond keeping the shape
  compatible).
- `docs/agents/instructions/security-invariants.md` INV-1 — full read of the Rule
  ("every access to tenant business data is scoped to exactly one tenant... a query
  that reaches business data without going through `:prefix`-scoping is a cross-tenant
  leak") and Reference (schema-per-tenant via Ecto `:prefix`).
- `docs/anti-patterns.md` — checked for any entry bearing on migration numbering,
  tenant-scoped fixtures, or transaction rollback shape; none found beyond what is
  already cited above.

---

## 1. Migration: `priv/repo/migrations/20260925000001_create_tenant_modules.exs`

### 1.1 Version and filename

`20_260_925_000_001` — later than every existing entry in
`@tenant_scoped_migration_manifest` (last: `20_260_923_010_002`) and every file in
`priv/repo/migrations/` (last: `20260923010002_...`), and distinct from any global
(non-tenant-scoped) migration version too (last global-shaped:
`20260923000001_add_storage_allowance_bytes_to_tenants.exs`). Filename:
`20260925000001_create_tenant_modules.exs`, module
`Letflow.Repo.Migrations.CreateTenantModules`.

### 1.2 Guard shape (cited exactly from `20260923010002_create_user_entity_type_grants.exs`)

The file opens with a header comment block (module purpose, REQ-402 pointer to this
design doc, and the same three fixed sentences the cited migration uses almost
verbatim):

- "PLACEMENT: per-tenant... `if prefix() do` guard below is MANDATORY, and this
  file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`
  (both halves are mandatory)."
- "No SQL string below interpolates tenant- or user-controlled data (INV-7)." (true
  here: no raw SQL string is used at all — only `Ecto.Migration` DSL calls, so there
  is no interpolation surface in the first place.)

Then, the migration body has exactly this shape (described, not as literal DSL):

The `change/0` callback body is a single `if prefix() do ... end` guard (mandatory
per the header comment above — this migration must never run against the public/root
schema). Inside the guard, bind `schema = prefix()`, then:

1. Create table `:tenant_modules` with `primary_key: false` and `prefix: schema`,
   containing exactly these columns:

   | Column | Type | Null | Default |
   |---|---|---|---|
   | `id` | `:binary_id`, primary key | not null | — |
   | `module_id` | `:string`, size 255 | not null | — |
   | `version` | `:string`, size 255 | not null | — |
   | `installed_at` | `:utc_datetime_usec` | not null | — |
   | `settings` | `:map` | not null | `%{}` |

   No `timestamps/1` call — the requirement's BUILDS §1 names exactly four
   non-id columns: `module_id`, `version`, `installed_at`, `settings`; `id` is the
   standard `binary_id` primary key every other tenant-scoped table in this
   codebase uses, per `@expected_tenant_tables`' sibling tables. `installed_at` is
   a plain column `Installs.install/3` sets explicitly (§3.3 step 5), not an
   autogenerated `inserted_at`.

2. Create a unique index on `:module_id`, named `tenant_modules_module_id_idx`,
   scoped to `prefix: schema`.

ELIXIR-DEV writes the real `.exs` file from this description, not from any
paste-ready block.

### 1.3 Naming-length check (Postgres 63-byte identifier limit)

- Table: `tenant_modules` (14 bytes).
- Unique index: `tenant_modules_module_id_idx` (29 bytes) — well under 63; matches
  the cited migration's own naming convention (`<table>_<cols>_idx`).
- No other named constraint is created (the primary key uses Ecto's default naming,
  `tenant_modules_pkey`, 20 bytes).

### 1.4 Registration into `Letflow.TenantProvisioning.tenant_scoped_migrations/0`

Both halves, in `lib/letflow/tenant_provisioning.ex`:

1. Append to `@tenant_scoped_migration_manifest` (after the existing last entry,
   `{20_260_923_010_002, Letflow.Repo.Migrations.CreateUserEntityTypeGrants, "20260923010002_create_user_entity_type_grants.exs"}`):
   `{20_260_925_000_001, Letflow.Repo.Migrations.CreateTenantModules, "20260925000001_create_tenant_modules.exs"}`.
2. No other code change to `tenant_scoped_migrations/0` itself — it already maps every
   manifest entry uniformly via `ensure_migration_module_loaded!/2`.

### 1.5 `test/support/tenant_fixture.ex` update (same change, per `docs/anti-patterns.md`)

- Add `"tenant_modules"` to `@expected_tenant_tables` (alphabetically, between
  `"tenant_role"` and `"timers"` per the list's existing near-alphabetical order —
  exact insertion point is ELIXIR-DEV's call, the list is not declared sorted by any
  test, but keeping it near-alphabetical matches the file's existing convention and
  eases future scanning).
- Update the running-count comment at line ~119 (`"47 as of REQ-394"`) to `"48 as of
  REQ-402"`, and leave the parenthetical "this list, not that count, is authoritative"
  sentence unchanged (the count is documentation, not itself asserted anywhere per
  the existing comment's own wording — but AC1 requires the oracle-rot guard test
  itself, in `test/letflow/support/tenant_fixture_test.exs`, to keep passing with
  `tenant_modules` now present in a freshly-migrated tenant schema; TEST-DESIGNER
  owns whether that test needs any additional edit — this design's job is only to
  confirm the table's addition does not change that test's *logic*, only its
  expected-value fixture).

---

## 2. `lib/letflow/modules/tenant_module.ex` — `Letflow.Modules.TenantModule`

File placement: `lib/letflow/modules/tenant_module.ex`, one level, no subdirectory —
D3 core mechanism file, named explicitly in the decision record.

The schema targets table `"tenant_modules"` and declares exactly these fields:

| Field | Ecto type | Default |
|---|---|---|
| `module_id` | `:string` | — |
| `version` | `:string` | — |
| `installed_at` | `:utc_datetime_usec` | — |
| `settings` | `:map` | `%{}` |

No other fields, no `timestamps/1`, no associations — a plain record matching the
migration's own column set one-for-one. ELIXIR-DEV writes the real
`use Ecto.Schema`/`schema "tenant_modules" do ... end` block from this table, not
from any paste-ready code.

- `@primary_key {:id, :binary_id, autogenerate: true}` (matches the migration's
  `:binary_id` primary key and every other tenant-scoped schema's convention in this
  codebase, e.g. `Letflow.TenantProvisioning.Registration`-adjacent schemas).
- No `belongs_to`/association fields — `tenant_modules` carries no foreign key (the
  tenant is the schema itself, per INV-1's schema-per-tenant mechanism; there is
  nothing else in the same tenant schema for `module_id` to reference relationally).
- `@type t :: %__MODULE__{id: Ecto.UUID.t() | nil, module_id: String.t(), version: String.t(), installed_at: DateTime.t(), settings: map()}`.
- One changeset function, `insert_changeset/2` (mirrors the naming convention of
  `Letflow.Definitions.SolutionPackInstall.insert_changeset/2`, `Letflow.Identity.Tenant.create_changeset/3`):
  `@spec insert_changeset(%__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()`.
  Casts `[:module_id, :version, :installed_at, :settings]`, `validate_required([:module_id, :version, :installed_at])`
  (`:settings` has a schema-level default and is always supplied by `Installs.install/3`
  anyway, but is not itself required at the changeset level — matches the migration's
  `null: false, default: %{}` column, which Ecto always sends a value for on insert).
  `unique_constraint(:module_id, name: :tenant_modules_module_id_idx)` — the DB-level
  backstop behind `Installs.install/3`'s own already-installed pre-check (§3.3 step 2);
  this is the same "check-then-insert plus a DB unique constraint as the race backstop"
  shape `Letflow.Identity.insert_or_fetch/3` and `SolutionPackInstall`'s
  `uq_solution_pack_install_active` already use elsewhere in this codebase.
- No `EctoStructDump`/`Jason.Encoder` derivation is required by any AC — omitted
  unless a later requirement needs it.

---

## 3. `lib/letflow/modules/installs.ex` — `Letflow.Modules.Installs`

File placement: `lib/letflow/modules/installs.ex`, one level, no subdirectory — D3
core mechanism file, named explicitly in the decision record.

### 3.1 `@type opts`

```
@type opts :: [prefix: String.t()]
```

Same shape as `Letflow.Definitions.opts()` and `conn.assigns[:scoped_opts]`
(`lib/letflow/plugs/authorize.ex:65`). **No function in this module accepts a tenant
id or schema name as a separate positional argument or a differently-named opts key**
— this is AC7's literal grep contract
(`git grep -nE "def (install|list_installed)\(" lib/letflow/modules/installs.ex`
must show no parameter named `tenant_id` or `schema`).

### 3.2 `list_installed/1`

```
@spec list_installed(opts()) :: [TenantModule.t()]
```

- Reads `prefix = Keyword.fetch!(opts, :prefix)` (raises on a missing prefix rather
  than silently defaulting — the same "a tenant-scoped call with no prefix is a
  programmer error, not a runtime `{:error, ...}` case" posture
  `Letflow.Definitions.export/3`'s own `opts[:prefix]` reads use implicitly via
  `TenantProvisioning.tenant_id_for_schema_name/1`'s own `{:error, ...}` path — here
  there is no downstream call that could turn a missing prefix into a typed error, so
  `Keyword.fetch!/2`'s raise is the correct failure shape, not a new error tuple).
- `Repo.all(from(m in TenantModule), prefix: prefix)` — ordered by `:installed_at`
  ascending (deterministic, matches AC2's "returns exactly one entry" expectation
  trivially and gives a stable order once REQ-403/404 list multiple).
- No filtering, no pagination — REQ-402's own BUILDS lists nothing beyond "at least
  `install/3` and `list_installed/1`"; pagination/filtering is out of scope unless a
  later requirement adds it.

### 3.3 `install/3`

```
@spec install(module_id :: String.t(), actor_id :: Ecto.UUID.t(), opts()) ::
        {:ok, TenantModule.t()} | install_error()

@type install_error ::
        {:error, :unknown_module}
        | {:error, :already_installed}
        | {:error, {:dependency_not_installed, module_id :: String.t()}}
        | {:error, {:pack_install_failed, SolutionPack.install_error()}}
        | {:error, {:on_install_failed, term()}}
```

All of the following happens inside **one** `Repo.transaction/1` call (matches the
established shape `SolutionPack.install/3`'s own `run_install/5` uses — steps that
fail return an `{:error, _}`-shaped value from inside the anonymous transaction
function, which `Repo.transaction/1` turns into `Repo.rollback/1` semantics; ELIXIR-DEV
follows that exact idiom, not a new one):

1. **Resolve the module.** `Catalog.fetch(module_id)` — `{:error, :not_found}` from
   `Catalog` is remapped to this module's own `{:error, :unknown_module}` (`Catalog`'s
   `:not_found` atom is Catalog's own public contract; `Installs` does not leak it
   verbatim so `install/3`'s error set stays self-describing without a second module's
   vocabulary bleeding through — ELIXIR-DEV may instead choose to reuse `:not_found`
   directly if `TEST-DESIGNER`/`CODE-DESIGN-VALIDATOR` prefer fewer synonyms; flagged
   as an open, non-blocking naming choice, not a functional ambiguity). This lookup
   needs no `prefix` — it is a Catalog-only, compile-time-config read; it may run
   before or inside the transaction with identical semantics (Catalog is a plain
   module over compiled config, D3), and is placed **before** opening the transaction
   in the pseudocode below since it does zero I/O and a fast-reject shortens the
   common failure path.
2. **Already-installed check.** `Repo.get_by(TenantModule, [module_id: module_id], prefix: prefix)` —
   non-nil → `{:error, :already_installed}` (checked inside the transaction, so it
   is consistent with the row insert in step 5 under the same transaction's
   snapshot; the DB unique index from §1.2/§2 is the concurrent-race backstop, same
   two-layer shape as `SolutionPackInstall`).
3. **`depends_on` check.** For every id in the resolved module's `manifest().depends_on`,
   `Repo.exists?(from(m in TenantModule, where: m.module_id == ^dep_id), prefix: prefix)`
   must be `true`; the first missing dependency (in `depends_on` list order) short-circuits
   with `{:error, {:dependency_not_installed, dep_id}}`. (Transitive/multi-module
   dependency-order installs are explicitly out of scope — BUILDS §"OUT OF SCOPE" and
   REQ-415; this check only asks "is `dep_id` already a row in `tenant_modules`",
   never "is `dep_id` itself installable".)
4. **Conditional pack install.** If `manifest().pack` is non-nil: read that JSON file
   from disk (`File.read!/1` + `Jason.decode!/1`, or the equivalent already-established
   pack-loading idiom used elsewhere for `priv/packs/*.json` — the exact file-read
   helper is ELIXIR-DEV's implementation choice, not a new design decision) and call
   the **existing** `Letflow.Definitions.SolutionPack.install/3` with that decoded
   document, `actor_id`, and `opts` (same `[prefix: prefix]` — `SolutionPack.install/3`
   already accepts exactly this shape). Its `{:error, reason}` is wrapped as
   `{:error, {:pack_install_failed, reason}}` and short-circuits (still inside the
   same transaction — `SolutionPack.install/3` opens its **own** nested
   `Repo.transaction/1` internally per its own moduledoc §5, which Ecto's SQL
   sandbox/adapter treats as a savepoint when already inside an outer transaction;
   this is the same nesting shape any two-context composition in this codebase
   already relies on — not a new pattern this design introduces). If `manifest().pack`
   is `nil` (true for the `fixture` module), this step is skipped entirely — no
   `SolutionPack` call at all.
5. **Insert the `tenant_modules` row.**
   `TenantModule.insert_changeset(%TenantModule{}, %{module_id: module_id, version: manifest().version, installed_at: DateTime.truncate(DateTime.utc_now(), :microsecond), settings: %{}})`
   then `Repo.insert(changeset, prefix: prefix)`. `settings: %{}` — REQ-402's own
   BUILDS explicitly scopes settings *writes* to REQ-414; this insert only satisfies
   the column's `NOT NULL DEFAULT '{}'` shape with the same empty-map value the
   column default already provides (no solution-manifest-provided defaults are
   applied here — that composition is D6/REQ-415's job). A changeset error (should
   the DB unique-index backstop actually fire under a race the step-2 check missed)
   surfaces as `{:error, %Ecto.Changeset{}}`, which is a reachable member of this
   function's error union by virtue of `Repo.insert/2`'s own return type — not
   separately named above since it is the standard Ecto contract every other
   context module in this codebase already exposes the same way.
6. **`on_install/2`, if exported.** `function_exported?(entry_module, :on_install, 2)` —
   if true, call `entry_module.on_install(prefix, row.settings)`. `:ok` → proceed to
   commit. `{:error, reason}` → `{:error, {:on_install_failed, reason}}`, which rolls
   back **everything** written in steps 4–5 (the pack install's own writes included —
   this is the one point AC6 exercises directly: "when `on_install/2` returns an
   error, `list_installed/1` returns no row for that module afterwards"). If
   `on_install/2` is not exported, this step is a no-op and the transaction proceeds
   to commit with steps 4–5's writes intact.
7. **Commit.** Returns `{:ok, %TenantModule{}}` (the row `Repo.insert/2` returned in
   step 5).

### 3.4 Rollback semantics (explicit, since it is AC6's whole point)

Every step from 2 through 6 runs inside the **same** `Repo.transaction/1` call — there
is exactly one commit point (falling off the end of the anonymous function
successfully) and any `{:error, _}` returned from inside it is passed to
`Repo.rollback/1` (or the anonymous function itself returns the error tuple, which
`Repo.transaction/1` treats identically per Ecto's documented contract — ELIXIR-DEV's
choice of `with`-chain-inside-`Repo.transaction/1` vs. explicit `Repo.rollback/1` calls
is an implementation detail, not a design decision). Concretely: a pack install that
succeeds (step 4) followed by an `on_install/2` failure (step 6) undoes the pack's
`solution_pack_installs` row, every `process_definitions`/`entity_definitions` row it
created, and (had the transaction reached that far) the `tenant_modules` row from
step 5 — nothing from this `install/3` call is observable afterward. This is a single
flat transaction, not nested application-level compensation logic — Postgres's own
transactional rollback provides the "all-or-nothing" property; no explicit
undo/compensating-write code is designed or needed here.

### 3.5 Why no separate pack installer

BUILDS explicitly says "no second pack installer" — `install/3` step 4 calls
`Letflow.Definitions.SolutionPack.install/3` directly, passing through the exact
`opts` it already received. `Installs` adds no pack-parsing, pack-validation, or
pack-database-write logic of its own; its only pack-specific responsibility is
reading the manifest's `pack` path off disk and deciding *whether* to call
`SolutionPack.install/3` at all (`manifest().pack == nil` → skip).

---

## 4. Second test fixture module: `Letflow.Modules.FixtureDependent`

Placement: `test/support/modules/fixture_dependent/` (parallel to
`test/support/modules/fixture/`), entry file
`test/support/modules/fixture_dependent/fixture_dependent.ex`, module
`Letflow.Modules.FixtureDependent`. Compiled only under `:test` env (`mix.exs`'s
existing `elixirc_paths(:test)` already includes `test/support`, matching
`Letflow.Modules.Fixture`'s own placement — no `mix.exs` change needed).

Minimal shape — just enough to prove AC4's missing-dependency-rejection test (no
router, no on_install marker; both are optional callbacks and neither AC exercises
them for this second fixture):

The module implements the `Letflow.Modules.Module` behaviour and declares a manifest
with exactly these field values:

| Manifest field | Value |
|---|---|
| `id` | `"fixture_dependent"` |
| `version` | `"0.1.0"` |
| `depends_on` | `["fixture"]` |
| `pack` | `nil` |
| `permissions` | `[]` |
| `role_grants` | `%{}` |
| `required_roles` | `[]` |
| `settings_schema` | `nil` |
| `route_policies` | `[]` |

ELIXIR-DEV writes the real `defmanifest(...)` call from this table, not from a
paste-ready literal. No `router/0`, no `on_install/2` —
both `@optional_callbacks`, and this fixture needs neither: AC4's test installs
`"fixture_dependent"` **without** first installing `"fixture"` and asserts
`{:error, {:dependency_not_installed, "fixture"}}` with no `tenant_modules` row
written; a second test path (not itself required by any AC bullet, but a natural,
cheap extra assertion TEST-DESIGNER may add) installs `"fixture"` first and then
`"fixture_dependent"` successfully. `permissions: []` / `role_grants: %{}` keep
`Catalog.validate/1`'s six rules trivially satisfied for this second fixture (no
permissions declared, so no role-grant/collision/route-policy rule has anything to
check) — this fixture is not itself the subject of any REQ-400/401 permission test,
so keeping its permission surface empty avoids widening `Authorization.permissions/0`
for tests that do not expect it (in particular REQ-401's own closed-set assertions,
which are keyed to the *current* registered-module list and must not need a second,
unrelated edit for REQ-402's sake).

### 4.1 `config/test.exs` registration

`config :letflow, :modules, [Letflow.Modules.Fixture, Letflow.Modules.FixtureDependent]`
— replaces the current single-entry list (AC5's literal requirement). Order matters
only for readability, not correctness (`Catalog.entry_modules/0` preserves config
order but nothing in `Installs`/`Catalog` depends on list order for correctness).

### 4.2 REQ-400's Catalog list test update

REQ-400's own test (its acceptance criterion: "`Letflow.Modules.Catalog` returns
`[Letflow.Modules.Fixture]` as its module list in the test env... REQ-402 and REQ-408
later append to this list and update this test's expectation") is updated in this
requirement to expect `[Letflow.Modules.Fixture, Letflow.Modules.FixtureDependent]` —
REQ-400's own text pre-authorizes this exact edit; TEST-DESIGNER locates that test via
`git grep -n "Catalog.entry_modules" test/`.

---

## 5. Test specs per AC1–AC7 (interfaces/pseudocode only)

**AC8** ("`mix letflow.check` passes") is a whole-suite gate, not a distinct test —
omitted from the per-AC list below; TEST-RUNNER/RELEASE-VALIDATOR verify it by
running the real command and quoting output, same as every other requirement.

- **AC1** (`tenant_modules` exists after real provisioning; C6 oracle-rot guard
  passes with it added): no new test file needed beyond §1.5's
  `@expected_tenant_tables` edit — the existing oracle-rot test in
  `test/letflow/support/tenant_fixture_test.exs` (or wherever the C6 test lives;
  TEST-DESIGNER confirms the exact path) re-provisions a tenant through
  `Letflow.TenantFixture.provisioned_tenant!/1` (`template: :replay` if that test
  already forces a real replay rather than the `:clone` fast path — TEST-DESIGNER's
  call per the fixture's own §"Adoption boundary" note) and re-asserts set equality
  against `information_schema.tables`; with `tenant_modules` added to
  `@expected_tenant_tables` this passes once the migration exists and is registered.
- **AC2** (`install("fixture", actor_id, prefix: p)` → `{:ok, _}`;
  `list_installed(prefix: p)` → one entry; `MarkerStore` marker readable): a test
  provisions one tenant, calls `Installs.install("fixture", actor_id, prefix: prefix)`
  and asserts it returns `{:ok, %TenantModule{module_id: "fixture", version: "0.1.0"}}`;
  then asserts `Installs.list_installed(prefix: prefix)` returns a single-element list
  containing that module; then asserts `Fixture.MarkerStore.get(prefix)` succeeds,
  proving `on_install/2` ran.
- **AC3** (install into tenant A leaves tenant B empty): two `provisioned_tenant!/1`
  calls (prefix `a`, prefix `b`); `install("fixture", actor_id, prefix: a)`; assert
  `list_installed(prefix: a)` has one entry and `list_installed(prefix: b)` is `[]`.
  This is the direct INV-1 regression test §6 requires.
- **AC4** (three rejection cases, no row written): three tests —
  unknown module id (`install("does_not_exist", actor_id, prefix: p)` →
  `{:error, :unknown_module}`, `list_installed(prefix: p) == []`); already installed
  (`install/3` called twice for `"fixture"`, second call →
  `{:error, :already_installed}`, `list_installed/1` still shows exactly one row);
  missing dependency (`install("fixture_dependent", actor_id, prefix: p)` **without**
  installing `"fixture"` first → `{:error, {:dependency_not_installed, "fixture"}}`,
  `list_installed(prefix: p) == []`).
- **AC5** (fixture registered in `config/test.exs`; REQ-400's list test updated):
  covered by §4's config edit plus the updated REQ-400 test itself (a config/test
  assertion, not a new runtime test) — `git grep -n "FixtureDependent" config/test.exs`
  shows one hit per AC5's literal check.
- **AC6** (`on_install/2` error → rollback, no row): a test provisions one tenant,
  installs a module whose `on_install/2` is made to fail (requires a THIRD test
  fixture, or a controllable failure hook on the existing `Fixture` module — open
  question, flagged in §9 below), asserts `Installs.install/3` returns
  `{:error, {:on_install_failed, _reason}}`, and asserts `Installs.list_installed/1`
  for that prefix is still `[]` afterward, proving the whole transaction (including
  the `tenant_modules` row insert) rolled back.
- **AC7** (no `tenant_id`/`schema` param; SECURITY-REVIEWER sign-off): the grep
  itself (`git grep -nE "def (install|list_installed)\(" lib/letflow/modules/installs.ex`)
  is a CI/report-level check, not an ExUnit test; SECURITY-REVIEWER's sign-off is a
  separate gate action (§6), not a test file.

---

## 6. SECURITY-REVIEWER gate (AC7, INV-1)

AC7 already states SECURITY-REVIEWER sign-off is required before merge. Verification
points, all against INV-1 ("every access to tenant business data is scoped to exactly
one tenant... a query that reaches business data without going through
`:prefix`-scoping is a cross-tenant leak"):

1. **Prefix-only tenant identification.** Confirm (via the AC7 grep, and a direct
   read of the merged `installs.ex`) that `install/3` and `list_installed/1` take no
   tenant id / schema-name parameter, and that every `Repo` call inside them passes
   `prefix: prefix` sourced from `opts` (never a hard-coded schema, never a value
   derived from `actor_id` or any other non-`opts` source).
2. **No cross-tenant leakage in `install/3`'s own reads.** Step 2 (already-installed
   check) and step 3 (`depends_on` check, §3.3) must both carry `prefix: prefix` on
   their `Repo` calls — a missing `prefix:` on either would read/write the wrong
   tenant's `tenant_modules` rows (or `public`, unscoped) silently.
3. **`SolutionPack.install/3` call passes the same `opts` through unchanged** — no
   new prefix value is constructed or derived; `Installs` must not attempt its own
   `tenant_id_for_schema_name/1` resolution and hand a raw `tenant_id` to
   `SolutionPack.install/3` (that function already does its own `prefix -> tenant_id`
   resolution internally per its own moduledoc step 1).
4. **`on_install/2`'s `prefix` argument** is the same `prefix` from `opts`, not
   re-derived, not defaulted.
5. **AC3's test is the concrete cross-tenant regression proof** — SECURITY-REVIEWER
   should confirm this test exists and genuinely provisions two distinct tenant
   schemas (not two rows in one schema) before signing off.
6. **The migration itself** (§1) follows the mandatory `if prefix() do` guard —
   SECURITY-REVIEWER additionally confirms the merged migration file matches §1.2's
   shape exactly (no code path creates `tenant_modules` in `public` or unconditionally).

---

## 7. Out of scope (restated from requirement text)

- Installing several modules in dependency order in one request — that is solution
  install, REQ-415.
- Settings writes to an already-installed module's `settings` column — REQ-414.
- Uninstall — explicit stage-file open item per 0039 D5.
- HTTP wiring (`:ModulesManage` route gate, `GET /api/v1/me/modules`) — REQ-403.
- The `/api/v1/modules/<id>/…` 404-on-absence dispatcher — REQ-404.

---

## 8. AC traceability map

| AC | Design element |
|---|---|
| AC1 | §1 (migration + registration), §1.5 (`@expected_tenant_tables` edit), §5 AC1 |
| AC2 | §3.2/§3.3 (`install/3` happy path, `list_installed/1`), §5 AC2 |
| AC3 | §3.1 (`opts` = `[prefix: ...]` only), §5 AC3, §6 point 5 |
| AC4 | §3.3 steps 1–3 (unknown/already-installed/dependency checks), §4 (`FixtureDependent`), §5 AC4 |
| AC5 | §4.1 (`config/test.exs`), §4.2 (REQ-400 test update) |
| AC6 | §3.3 step 6, §3.4 (rollback semantics), §5 AC6 |
| AC7 | §3.1 (no tenant_id/schema param), §6 (SECURITY-REVIEWER checklist) |
| AC8 | whole-suite gate, not a design element |

---

## 9. Open questions (explicit — not silently resolved)

1. **AC6's failing fixture.** The existing `Letflow.Modules.Fixture.on_install/2`
   always returns `:ok` (writes to `MarkerStore` unconditionally). AC6 needs some
   module whose `on_install/2` returns `{:error, reason}`. Two options, neither
   chosen here:
   (a) add a **third** test-only fixture module (e.g.
   `Letflow.Modules.FixtureFailingInstall`, `depends_on: []`, `pack: nil`) whose
   `on_install/2` unconditionally returns `{:error, :boom}`, registered in
   `config/test.exs` alongside the other two; or
   (b) give `Letflow.Modules.Fixture.MarkerStore` a test-controllable "fail next
   `on_install/2`" flag the AC6 test sets before calling `install/3` and clears after.
   (a) is simpler and matches this design's existing "one fixture per distinct
   scenario" pattern (§4 already does this for the dependency case); (b) avoids a
   third module but adds cross-test mutable global state to a `:named_table` ETS
   process, which risks async-test interference. **Recommendation: (a)**, but this is
   left for TEST-DESIGNER/CODE-DESIGN-VALIDATOR to confirm rather than silently
   assumed — if TEST-DESIGNER adds a third fixture module, it must be registered in
   `config/test.exs`'s list alongside `Fixture`/`FixtureDependent` and REQ-400's
   Catalog list-test expectation (§4.2) updated again to include it.
2. **`install/3`'s pack-file read helper.** §3.3 step 4 names `File.read!/1` +
   `Jason.decode!/1` as one option but does not mandate it — if this codebase already
   has a shared "read a `priv/packs/*.json` file by relative path" helper elsewhere
   (not located during this design's research), ELIXIR-DEV should reuse it rather
   than duplicate the read logic; this does not change `install/3`'s public contract
   either way.
3. **Actor id source in tests.** AC2–AC6's tests all need a real `actor_id` —
   whichever existing user-fixture helper this codebase's other tenant-scoped
   ExUnit tests already use (not enumerated here) should be reused; no new user
   fixture is designed by this requirement.

---

## 10. Note to whoever implements next (ELIXIR-DEV / TEST-DESIGNER)

This design doc was written directly into the shared main-repo checkout at
`lib/letflow/design/req402-tenant-modules-install-context.md`, **not** into an
implementation worktree — at design time this session does not know what worktree
path ELIXIR-DEV/TEST-DESIGNER will use. Per the anti-pattern this project documented
twice this session already (dangling commits from a worktree never merged back),
whoever picks up REQ-402's implementation **must**:

1. Confirm this file is present in their own worktree before starting (copy it in if
   it is not — `git log --oneline -- lib/letflow/design/req402-tenant-modules-install-context.md`
   should show it committed on the branch they are building from).
2. Commit this design file as part of (or before) their implementation commit(s), so
   it ships in the same PR/branch as the code it governs.
3. Verify via `git log` (not by trusting this report) that the file is actually
   present in the branch that reaches CODE-DESIGN-VALIDATOR / merges to `main` — a
   design doc that exists only in the main-repo checkout and never reaches the
   worktree branch is, for gate purposes, the same as a design step that was skipped.

No gate PASS on REQ-402 should be trusted until that `git log` check has actually
been run and its output quoted, per this project's "no speculation" core rule.
