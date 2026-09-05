# Design: REQ-022 — Schema-per-tenant provisioning mechanism

**Requirement:** REQ-022 (`docs/requirements.yaml`, stage S2)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** migration shape + module/function signatures + Ecto.Schema
shape only. No implementation code, no function bodies, no changeset bodies. ELIXIR-DEV
writes the actual `.exs`/`.ex` files from this.

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-022 (full entry) and REQ-023 (full entry, to confirm
  exactly how the first downstream consumer expects to call this mechanism).
- `docs/guides/backend_developer_guide.md` — §2 (project structure), §3 (naming/coding
  conventions, esp. §3.5 error shapes, §3.6 SQL parameterization, §3.7 migrations), §5
  (multi-tenancy, points at 0003).
- `docs/migration/stage-2-event-store-definitions.md` (full).
- `docs/migration/decisions/0003-ecto-schema-strategy.md` (full) — Decision A
  (Ecto-idiomatic redesign, not 1:1 port), Decision B (schema-per-tenant via `:prefix`,
  `tenant_id` retained intra-schema — this decision *names* the provisioning mechanism
  and explicitly defers *building* it to S2/S3, which is this requirement), Decision C
  (event-store tables get no special-cased tenant-isolation treatment — they use this
  same mechanism).
- `lib/letflow/design/identity-schema.md` §1 — the original REQ-015 deferral this
  requirement now resolves. §1's "Follow-up work this creates" paragraph is the direct
  ancestor of this requirement's own scope (tenant_schemas registry, provisioning
  function, migration-replay mechanism — all three named there, built here).
- Existing `lib/letflow/` conventions read directly: `lib/letflow/identity.ex` (context
  module + insert/on_conflict/re-select idiom for idempotent upserts — see
  `upsert_by_external_identity/3` there, reused below), `lib/letflow/identity/tenant.ex`
  (schema/changeset style), `priv/repo/migrations/20260816000001_create_tenants.exs` and
  `20260816000003_create_tenant_role.exs` (migration shape: `primary_key: false` +
  explicit `add :id, :binary_id, primary_key: true`, `references(:table, type:
  :binary_id)` FK syntax, required `#`-comment moduledoc header), `lib/letflow/repo.ex`
  (plain `Ecto.Repo`, `Ecto.Adapters.Postgres` — no dynamic-repo/multi-repo setup exists
  today).
PROVENANCE (historical, not current decision authority):
- **R-Co source, read directly, ported for behavior not code (per this requirement's own
  instruction):** `C:\Users\tvolo\dev\ai-dala\R-Co\migrations\060_schema_per_tenant_bootstrap.sql`
  (`public.tenant_schemas` table shape, `public.bpm_provision_tenant_schema(p_tenant_id
  UUID)` function: `CREATE SCHEMA IF NOT EXISTS`, `pg_advisory_xact_lock(hashtext(...))`
  serialization, `INSERT ... ON CONFLICT DO NOTHING`) and
  `src/db/migrations.zig`'s `runForSchema` (schema-name-scoped migration replay via
  `SET search_path`) plus `src/db/pool.zig`'s `schemaNameForTenant` (schema-name
  derivation: `"tenant_" <> hex-without-hyphens`, with a `tenant_default` special case
  for the reserved all-zero UUID).
- **Ecto/ecto_sql source, read directly from `deps/` in this repo** (not from memory —
  this design's central mechanism depends on exact `Ecto.Migrator`/`Ecto.Migration`
  behavior, verified against actual installed source rather than assumed):
  `deps/ecto_sql/lib/ecto/migrator.ex` (`run/4`'s `migration_source` accepts either a
  directory path or an explicit `[{version :: integer, module}]` list; `:prefix` option
  on `run/4`/`up/4`; `run/4`'s `@spec` returns a bare `[integer]` and **raises** on
  failure, it does not return an `{:ok, _} | {:error, _}` tuple),
  `deps/ecto_sql/lib/ecto/migration/schema_migration.ex` (`ensure_schema_migrations_table!/3`
  creates the `schema_migrations` version-tracking table itself scoped to `opts[:prefix]`
  — **each distinct `:prefix` gets its own, fully independent `schema_migrations`
  tracking table**, confirmed directly from source, not assumed), `deps/ecto_sql/lib/ecto/migration/runner.ex`
  (`Ecto.Migration.prefix/0` reads `Process.get(:ecto_migration).prefix`, which is `nil`
  when no `:prefix` option was passed to the Migrator run — confirmed directly),
  `deps/ecto_sql/lib/ecto/migration.ex` (`Ecto.Migration.Table` defaults `prefix: nil`,
  i.e. `create table(:foo)` with no explicit `prefix:` **always** targets the default/
  `public` schema regardless of what `:prefix` the surrounding Migrator run was given —
  a migration must explicitly say `prefix: prefix()` to pick up the run's prefix
  dynamically; `Ecto.Migration.timestamps/1` accepts the same `:inserted_at`/
  `:updated_at`/`:type` renaming options as `Ecto.Schema.timestamps/1`, confirmed
  directly), `deps/ecto_sql/lib/mix/tasks/ecto.migrate.ex` (`mix ecto.migrate` accepts an
  optional `--prefix` flag but has no default — a plain `mix ecto.migrate`/`mix
  ecto.setup` run passes no `:prefix` at all).

These source reads directly produced §4 below, which is the load-bearing section of this
design — see its own opening paragraph for why.

## 1. Module naming

**Context module: `Letflow.TenantProvisioning`** — `lib/letflow/tenant_provisioning.ex`.
Matches REQ-022's own suggested name literally, matches this handoff's
`context.owned_modules` path, and matches the established top-level-context-module
pattern (`Letflow.Identity`, `Letflow.RowApproval`): one context module in `lib/letflow/`
backed by schema file(s) in a same-named subdirectory.

**Ecto schema module: `Letflow.TenantProvisioning.Registration`** —
`lib/letflow/tenant_provisioning/registration.ex`. **Deliberately not named
`TenantSchema`**, even though the DB table is `tenant_schemas` and this project's
convention elsewhere is "singular of the table name" (`Tenant` for `tenants`, `User` for
`users`). Reasoning: this whole feature is about two different things both colloquially
called "schema" — a **Postgres schema** (the physical namespace `CREATE SCHEMA` creates)
and an **Ecto schema** (the `use Ecto.Schema` struct/module system). A struct literally
named `TenantSchema` reads ambiguously in every sentence that also has to talk about the
Postgres schema it maps to ("call `TenantSchema.changeset` to build the schema..." —
which schema?). `Registration` names what the row actually *is* — a registration record
mapping a tenant to its provisioned physical schema — and keeps every subsequent
sentence in this document unambiguous. Everywhere below, **"schema" (unqualified) means
the Postgres namespace**; the Ecto-schema-defining struct is always written as
`Registration`.

## 2. Migration: `tenant_schemas` (`priv/repo/migrations/`)

Public/default schema — **no `prefix:` option anywhere in this migration**, matching
`tenants`/`users`/`groups`/`tenant_role`'s existing convention. This table is
structurally global for the same reason `tenants` is (per REQ-022's own description): a
realm→tenant lookup, and now a tenant→schema lookup, must both resolve before any
tenant's own schema context is known, so the lookup table itself cannot live inside a
tenant schema.

**Filename:** next-in-sequence timestamp after `20260816000004_create_users.exs`, e.g.
`20260816000005_create_tenant_schemas.exs` — or the real UTC-clock timestamp ELIXIR-DEV
generates at implementation time; either is fine as long as it sorts after the four S1
identity migrations. Module name `Letflow.Repo.Migrations.CreateTenantSchemas`.

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `:binary_id` | `primary_key: true` | Decision A convention, matches every other table in this codebase |
| `tenant_id` | `:binary_id` | `references(:tenants, type: :binary_id)`, `null: false` | **DB-level FK to `tenants.id`, unlike `users.tenant_id`/`groups.tenant_id`'s deliberate omission of one** (identity-schema.md §2.2). Reasoning is the same distinction identity-schema.md §2.4 already draws for `tenant_role.group_id`: an FK is safe and kept permanently when both tables are siblings that will never be separated by the schema-per-tenant boundary. `tenant_schemas`, like `tenants`, is structurally global forever (§0 above) — it is never a candidate for moving behind a tenant's own schema prefix, so this FK never needs to be dropped or reworked, unlike `users.tenant_id → tenants.id` (`users` is a real future prefix-migration candidate per this requirement's own Open Question, §7). |
| `schema_name` | `:string` | `null: false` | The derived, validated physical Postgres schema name — see §3.3's `schema_name_for_tenant/1` |
| `migrations_applied_at` | `:naive_datetime` | nullable | **Recommended addition beyond REQ-022's literal minimum** (tenant_id, schema_name, provisioned-at). Mirrors R-Co's own `tenant_schemas.migrations_applied_at` column exactly. `NULL` until `replay_migrations/2` (§3.2) succeeds at least once for this tenant, then stamped with the completion time — gives any future caller a cheap "has this tenant's schema ever had its migrations replayed" signal without querying `information_schema` or a per-tenant `schema_migrations` table directly. Not required by REQ-022's acceptance criteria; costs one nullable column, matches the identity-schema.md precedent of recommending a low-cost convention-consistent addition beyond a requirement's literal bulleted list (see identity-schema.md §3.1/§3.3's `timestamps()` recommendations). |
| — | `:naive_datetime` | `null: false` | `timestamps(inserted_at: :provisioned_at, updated_at: false)` — see note below |

**Why `timestamps(inserted_at: :provisioned_at, updated_at: false)` instead of a bare
`timestamps()` call:** `Ecto.Migration.timestamps/1` (confirmed from
`deps/ecto_sql/lib/ecto/migration.ex`) accepts the same `:inserted_at`/`:updated_at`
renaming options `Ecto.Schema.timestamps/1` does. This gets the column REQ-022's own
description asks for literally ("a provisioned-at timestamp") while keeping the exact
same auto-populated-on-insert mechanics every other table in this codebase already gets
from plain `timestamps()` — no redundant second `inserted_at` column with the same
meaning as `provisioned_at` sitting next to it. `updated_at: false` matches
`transition_events`' precedent for an insert-oriented, not-really-mutated row (this row
*is* mutated once, by `replay_migrations/2` setting `migrations_applied_at` — but that's
its own explicit, meaningfully-named column, not a generic "something changed" timestamp,
so `updated_at` would add no information `migrations_applied_at` doesn't already carry
more specifically).

Indexes:
- `create unique_index(:tenant_schemas, [:tenant_id])` — one schema per tenant. This is
  what makes `provision_tenant_schema/1` idempotent (§3.1): a second insert for the same
  `tenant_id` conflicts on this index rather than creating a duplicate row.
- `create unique_index(:tenant_schemas, [:schema_name])` — matches R-Co's
  `tenant_schemas_schema_name_uq`, defense-in-depth against the (practically
  impossible, since `schema_name` is deterministically derived from `tenant_id`, see
  §3.3) case of two different tenants deriving the same schema name.
- No separate plain `index(:tenant_schemas, [:tenant_id])` — a unique index already
  serves as a lookup index in Postgres; R-Co's SQL adds both a UNIQUE constraint *and* a
  separate plain index on the same column, which is redundant. Not porting that
  redundancy is a Decision-A-consistent simplification (Ecto-idiomatic redesign, not a
  1:1 port), stated explicitly here rather than silently diverging.

**Required migration file header comment (ELIXIR-DEV: copy verbatim, matching this
project's established `#`-comment-header convention on every migration so far):**

```
# Letflow.Repo.Migrations.CreateTenantSchemas
#
# Builds the tenant_schemas registry REQ-022 adds, resolving the deferral
# lib/letflow/design/identity-schema.md section 1 flagged as follow-up work.
# Ported from R-Co migrations/060_schema_per_tenant_bootstrap.sql's
# public.tenant_schemas table shape (behavior ported, not the raw SQL).
#
# This table is structurally global, like tenants -- it must be queryable before
# any tenant's own schema context is known, so it lives in the public/default
# schema like every other migration in this batch (no prefix: option here).
#
# tenant_id DOES carry a database-level foreign-key reference to tenants.id,
# unlike users.tenant_id/groups.tenant_id's deliberate omission of one (see
# identity-schema.md section 2.2) -- tenant_schemas and tenants are both
# structurally-global siblings that are never candidates for moving behind a
# tenant's own schema prefix, so this FK never needs to be dropped later, the
# same reasoning identity-schema.md section 2.4 already applies to
# tenant_role.group_id -> groups.id.
#
# OPEN QUESTION (see lib/letflow/design/req022-tenant-schema-provisioning.md
# section 7, not resolved here): REQ-015's users/groups/tenant_role tables
# currently live in the public default schema. This requirement does not
# retrofit those three tables to live under each tenant's own schema.
```

## 3. Public function signatures (`Letflow.TenantProvisioning`)

### 3.1 `provision_tenant_schema/1`

```
@spec provision_tenant_schema(tenant_id :: Ecto.UUID.t()) ::
        {:ok, Registration.t()}
        | {:error, :invalid_tenant_id}
        | {:error, :tenant_not_found}
        | {:error, term()}
```

**Behavior, in order, all inside a single `Repo.transaction/1`:**

1. `schema_name_for_tenant/1` (§3.3) validates and derives `schema_name` from
   `tenant_id`. On `{:error, :invalid_tenant_id}`, return immediately — no DB round-trip,
   no transaction opened.
2. Acquire a **transaction-scoped** Postgres advisory lock keyed on `schema_name`:
   `Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [schema_name])`. Ports
   R-Co's `PERFORM pg_advisory_xact_lock(hashtext(v_schema_name))` — a normal
   parameterized query (`$1`), no identifier interpolation involved at this step, no
   INV-7 concern here. Serializes concurrent `provision_tenant_schema/1` calls for the
   *same* tenant; different tenants proceed independently (subject to `hashtext`
   collisions, an accepted risk this design inherits unchanged from R-Co's own
   precedent). Must run inside the same `Repo.transaction/1` as steps 3–4 below —
   `pg_advisory_xact_lock` auto-releases at COMMIT/ROLLBACK, which only lines up with
   this function's own atomicity boundary if it shares that transaction's connection.
3. `CREATE SCHEMA IF NOT EXISTS` for the derived `schema_name`. See §3.3's identifier-
   safety note for why interpolating `schema_name` into this DDL statement is safe.
   `IF NOT EXISTS` matches R-Co's own idempotent form (belt-and-suspenders: makes a
   second call safe even in the pathological case where a `Registration` row was
   deleted out-of-band while the physical schema still exists).
4. Insert a `Registration` row (`tenant_id`, `schema_name`) via `Repo.insert/2` with
   `on_conflict: :nothing, conflict_target: :tenant_id, returning: true`, then verify
   via `Repo.get/2` on the freshly-generated `id` — **this reuses the exact idiom
   already established and empirically verified in `lib/letflow/identity.ex`'s
   `insert_or_fetch/3`/`re_select_on_conflict/2`** (client-generated `binary_id` PKs
   make `{:ok, struct}` indistinguishable between "really inserted" and "suppressed by
   ON CONFLICT" without this extra existence check — same caveat, same fix, don't
   reinvent it). If the changeset step fails a `foreign_key_constraint(:tenant_id)`
   check (the `tenant_id` doesn't correspond to any row in `tenants`), call
   `Repo.rollback(:tenant_not_found)`.
5. Return `{:ok, %Registration{}}` — the row found in step 4, whether this call created
   it or a prior call did.

**Idempotency invariant (explicit answer to the question this handoff's task posed —
not left ambiguous):** calling `provision_tenant_schema/1` twice for the same
`tenant_id` is **not an error**. The second call returns `{:ok, %Registration{}}` with
the same row the first call created — `CREATE SCHEMA IF NOT EXISTS` plus the
`unique_index(:tenant_schemas, [:tenant_id])` + on-conflict-and-reselect idiom together
make the whole operation idempotent by construction, exactly matching R-Co's own
`bpm_provision_tenant_schema`'s documented idempotency (its own comment: "Idempotent:
safe to call multiple times for the same tenant_id"). This is a deliberate behavior
port, not a default this design fell into — an alternative design (second call is a
hard `{:error, :already_provisioned}`) was considered and rejected because R-Co's own
precedent already answered this question in favor of idempotent-success, and nothing in
REQ-022's acceptance criteria asks for the stricter behavior.

**Atomicity invariant:** every step above runs inside one `Repo.transaction/1`. A
`tenant_id` that doesn't correspond to an existing `tenants` row rolls back the entire
operation — **including the `CREATE SCHEMA` DDL** (Postgres DDL is transactional) — so a
failed provisioning attempt never leaves an orphan physical schema with no registry row
behind.

**Identifier-injection safety invariant (for SECURITY-REVIEWER's INV-7 check at Step
2c):** the only raw-SQL identifier interpolation in this whole module is the `CREATE
SCHEMA IF NOT EXISTS "#{schema_name}"` statement in step 3, and `schema_name` at that
point is never a value taken directly from an external caller — it is always the output
of `schema_name_for_tenant/1` (§3.3), which only emits strings matching
`tenant_[0-9a-f]{32}` (guaranteed by construction: it only proceeds past
`Ecto.UUID.cast/1`, which normalizes to exactly that character set). No public function
in this module accepts a raw schema-name string from a caller and interpolates it
directly.

### 3.2 `replay_migrations/2`

```
@spec replay_migrations(
        tenant_id :: Ecto.UUID.t(),
        migration_source :: [{version :: pos_integer(), module()}]
      ) ::
        {:ok, applied_versions :: [pos_integer()]}
        | {:error, :tenant_not_provisioned}
        | {:error, {:migration_failed, Exception.t()}}
```

`migration_source` defaults to `tenant_scoped_migrations/0` (§3.4) if omitted — this is
a 2-arity function with a default argument, not two unrelated arities.

**Behavior:**

1. Look up the tenant's registered `schema_name` via `Repo.get_by(Registration,
   tenant_id: tenant_id)`. **This function never provisions on the fly** — if no
   `Registration` row exists, return `{:error, :tenant_not_provisioned}` immediately.
   `replay_migrations/2` only ever migrates a schema `provision_tenant_schema/1` has
   already created and registered; it re-derives nothing about the tenant_id itself
   (no second `schema_name_for_tenant/1` call, no second identifier-safety argument to
   make — the `schema_name` used here was already validated once, at provisioning
   time, and is read back from the project's own registry, never re-taken from a
   caller-supplied string).
2. Call `Ecto.Migrator.run(Letflow.Repo, migration_source, :up, all: true, prefix:
   schema_name, log: false)`. **`Ecto.Migrator.run/4` itself returns a bare `[integer]`
   list on success and *raises* (does not return `{:error, _}`) on failure** — confirmed
   directly from `deps/ecto_sql/lib/ecto/migrator.ex`'s own `@spec`. `replay_migrations/2`
   wraps this call in `try/rescue`, converting any raised exception into `{:error,
   {:migration_failed, exception}}`, to produce this project's established `{:ok, _} |
   {:error, _}` convention (`backend_developer_guide.md` §3.5) at this module's public
   boundary. This is a deliberate wrapping decision to state explicitly, not a mismatch
   for ELIXIR-DEV to "fix" by leaving the raise unhandled.
3. On success, update the `Registration` row's `migrations_applied_at` to the current
   time (`Repo.update_all` or fetch-then-`Repo.update`, ELIXIR-DEV's implementation
   choice — not specified further here since it doesn't affect this function's public
   contract).
4. Return `{:ok, applied_versions}`.

PROVENANCE (historical, not current decision authority):
**No implicit chaining invariant:** `provision_tenant_schema/1` never calls
`replay_migrations/2`, and `replay_migrations/2` never calls `provision_tenant_schema/1`.
They are two separate, composable steps a caller sequences explicitly — this mirrors
R-Co's own design: `bpm_provision_tenant_schema` (schema creation + registry insert) and
`runForSchema` (migration replay) are two separate procedures in R-Co too, invoked from
separate call sites (`src/db/provisioning.zig`'s tenant-onboarding flow calls one, then
the other; `src/platform/migration_fanout.zig` is a distinct orchestration layer that
calls `runForSchema` across *all* registered tenants independently of any single
provisioning event). REQ-022 builds the two primitives; a future requirement owns the
onboarding orchestration that sequences them (not invented here).

**2026-08-22 addendum (ISS-0230/GH#468, run `WF03-ISS0230-20260822`) — what this
invariant hands to that future requirement.** The invariant above is unchanged and was
re-affirmed, not relaxed. But holding the two primitives uncoupled means the *failure
handling* between them is uncoupled too: any caller that sequences them commits the
`tenants` row first, and if a later step fails the tenant is left half-provisioned with
nothing in the codebase that will ever notice or repair it. That consequence is
acceptable **only** because the orchestration requirement is obliged to handle it, so
the obligation is now written down in two places a future implementer will actually be
reading — `Letflow.TenantProvisioning`'s own moduledoc (which carries the first-hand
measurements: `migrations_applied_at IS NULL` is already a sufficient detection
predicate, and re-invoking both primitives converges the state) and `REQ-076`'s
acceptance criteria. A compensating rollback is explicitly **not** the remedy; see the
moduledoc for why deleting the `tenants` row makes the state worse, not better.

### 3.3 `schema_name_for_tenant/1`

```
@spec schema_name_for_tenant(tenant_id :: Ecto.UUID.t()) ::
        {:ok, schema_name :: String.t()} | {:error, :invalid_tenant_id}
```

Pure function (no I/O), public (not `defp`) specifically so TEST-DESIGNER can unit-test
the derivation logic directly without a database. Algorithm: `Ecto.UUID.cast(tenant_id)`
— on `:error`, return `{:error, :invalid_tenant_id}`; on `{:ok, canonical}` (Ecto's
canonical lowercase, hyphenated 8-4-4-4-12 form), return `{:ok, "tenant_" <>
String.replace(canonical, "-", "")}` (39 characters total: 7-char prefix + 32 hex
characters — well under Postgres's 63-byte identifier limit).

**Deliberate divergence from R-Co's `schemaNameForTenant`, stated explicitly:** R-Co
special-cases the all-zero UUID (`00000000-0000-0000-0000-000000000000`) to the literal
name `tenant_default`. Letflow has **no equivalent reserved default-tenant UUID** —
confirmed by reading `lib/letflow/identity/tenant.ex` directly: `@primary_key {:id,
:binary_id, autogenerate: true}` means every tenant, including the one with
`slug == "bpm-default"`, gets a normal randomly-generated `binary_id`, and no seed
script reserving a fixed all-zero UUID exists anywhere in this codebase (confirmed by
grep). This function therefore applies the same `"tenant_" <> hex` derivation
uniformly to every tenant_id, with no special case. This is a legitimate Decision-A-style
adaptation (Ecto-idiomatic redesign, not a 1:1 port) given Letflow's actual tenant-ID
scheme differs from R-Co's, not a silent omission — flagging it here so it isn't
mistaken for one later.

### 3.4 `tenant_scoped_migrations/0`

```
@spec tenant_scoped_migrations() :: [{version :: pos_integer(), module()}]
```

**Starts by returning `[]`.** This is a design commitment about *shape and growth
mechanism*, not a deferred/TBD value: REQ-022 itself contributes zero entries (its own
`CreateTenantSchemas` migration is global-only, per §2, and must never be added here).
Every future tenant-scoped migration (REQ-023 onward) is required to do two things
together, not one: (a) write its migration file following §4's required guard pattern,
and (b) append its own `{version, ModuleName}` tuple to this function's body. See §4 for
why both halves are mandatory and what happens if either is skipped.

**Correction (2026-08-17, ISS-0017/GH#73 -- read before implementing against this
section): a module-loading step is required and this section didn't anticipate it.**
REQ-023 (the first real contributor of entries) found that
`Ecto.Migrator.load_migration!/1` requires `Code.ensure_loaded?(module)`, but
`priv/repo/migrations/*.exs` is never compiled (`mix.exs`'s `elixirc_paths` is
`["lib"]` only) -- so returning bare `{version, module}` tuples, as this section
originally specified with no further step, raises `Ecto.MigrationError` in any VM
where those modules aren't already loaded (masked in `mix test` by the `test:`
alias's own `ecto.migrate` side-compiling them; would fail on a warm test DB or in
`iex -S mix`). The shipped fix (`ensure_migration_module_loaded!/2`, backed by an
internal `{version, module, filename}` manifest whose third element never escapes the
function) explicitly does **not** change the `@spec` above -- it stays exactly
`[{version, module}]`, verified byte-identical against pre-fix `main` at the time.
So the public contract this section documents is still correct; what's missing is the
implementation note that a conforming implementation must also resolve/load each
module before use, not just hold its name.

## 4. Required pattern for every tenant-scoped migration file (REQ-023 onward)

**This section is the load-bearing part of this design** — the task that dispatched this
design explicitly named getting this shape right as blocking ~20 downstream
requirements, and this is the part that is easy to get subtly wrong. Read `mix
ecto.migrate`'s actual behavior in §0's Ecto-source citations before disagreeing with
this section.

**The problem this guards against:** `priv/repo/migrations/` is one shared directory.
REQ-023 onward adds tenant-scoped table migrations (`events`, `instance_sequence`, ...)
*into this same directory*, alongside this requirement's own global-only
`CreateTenantSchemas` and S1's global-only identity migrations — REQ-023's own
acceptance criteria say so explicitly ("priv/repo/migrations gains migrations for
events..."). A plain `mix ecto.migrate`/`mix ecto.setup` run (no `--prefix` flag, the
normal dev/CI bootstrap path) scans and runs **every** `.exs` file in that directory,
including future tenant-scoped ones. Confirmed directly from `deps/ecto_sql` source
(§0): `create table(:foo)` with no explicit `prefix:` option always defaults to
`prefix: nil` (targets `public`), **regardless of whether the surrounding Migrator run
was itself invoked with a `:prefix` option or not** — a migration file only picks up the
run's prefix if it explicitly asks for it via `Ecto.Migration.prefix()`.

If a future tenant-scoped migration file naively wrote `create table(:events, prefix:
prefix())` with no further guard, a plain global `mix ecto.migrate` run (which passes no
`:prefix` at all, so `prefix()` evaluates to `nil` inside that migration) would still
execute the file and pass `prefix: nil` straight through to `create table` — silently
creating an empty, never-queried `public.events` table on every ordinary dev/CI
bootstrap. That is exactly the kind of stray-schema-pollution bug this document exists to
prevent someone from discovering the hard way three requirements from now.

**The required guard — every tenant-scoped migration's `change/0` must look like this in
shape (not literal code, ELIXIR-DEV writes the real version):**

```
change/0:
  if a prefix was supplied to this migration run (Ecto.Migration.prefix() is truthy):
    create the table with prefix: prefix()
  else:
    do nothing — this migration has no effect on the public/default schema at all
```

Concretely: `Ecto.Migration.prefix/0` returns `nil` when no `:prefix` option was passed
to the enclosing `Ecto.Migrator.run`/`mix ecto.migrate` invocation (confirmed directly
from `runner.ex`'s `metadata/2`, §0) — a tenant-scoped migration's `change/0` must
branch on `prefix()`'s truthiness and no-op on the `nil` branch, so a plain global run
safely skips it (the migration gets recorded as "applied" in `public.schema_migrations`
having done nothing there, which is harmless bookkeeping, not a correctness problem) while
a `replay_migrations/2`-driven per-tenant run (which *does* pass a real `:prefix`) takes
the real branch and creates the table inside that tenant's own schema.

**Both halves of §3.4 are mandatory, not either/or:** a migration file that follows this
guard pattern but is *not* added to `tenant_scoped_migrations/0`'s list is inert forever
— `replay_migrations/2` never selects it, so no tenant schema ever gets that table, even
though the file sits harmlessly in `priv/repo/migrations/`. A migration added to that
list *without* the guard pattern actively corrupts `public` on every plain `mix
ecto.migrate` run, per the failure mode described above. REQ-023's own CODE-DESIGNER
should cite this section directly rather than re-deriving it.

## 5. Demonstrating acceptance criteria 2 and 3

**AC2** ("demonstrated against at least one non-default tenant schema name"): call
`provision_tenant_schema/1` with any real `tenant_id` (Letflow has no reserved
default-tenant UUID to contrast against, §3.3 — any real tenant row's id satisfies
"non-default"). Confirm the schema exists via `SELECT schema_name FROM
information_schema.schemata WHERE schema_name = $1`, and confirm the `tenant_schemas`
row via a normal `Repo.get_by/2`.

**AC3** ("confirming at least one table exists under the provisioned schema's own
information_schema"): `tenant_scoped_migrations/0` is `[]` at this point in the
project's history (§3.4 — REQ-023 is the first real contributor), so there is no
permanent production migration yet to replay. ELIXIR-DEV's demonstration of this
criterion should call `replay_migrations/2` with an **explicit override** of the second
argument — a small, test-fixture-only migration module living under `test/support/`
(never under `priv/repo/migrations/`, and never added to `tenant_scoped_migrations/0`'s
real list), following §4's guard pattern, that creates one trivial marker table. This
cleanly separates "prove `replay_migrations/2` correctly threads `:prefix` through
`Ecto.Migrator`" (what AC3 actually asks for) from "REQ-022 invents a permanent, unused
production table just to have something to point at" (scope creep this design
deliberately avoids). Confirm via `SELECT EXISTS (SELECT 1 FROM information_schema.tables
WHERE table_schema = $1 AND table_name = $2)` against the fixture table, scoped to the
provisioned schema name — and confirm the same query is `false` against `public`, to
positively prove the table landed under the tenant's schema and not the default one.

## 6. Cross-module dependencies

- `Letflow.Repo` (`lib/letflow/repo.ex`) — all DB access in this module goes through the
  existing single `Ecto.Repo`; no dynamic-repo/multi-repo config change, no new pool.
- `Ecto.Migrator` (`ecto_sql`, already a dependency — every existing migration already
  depends on it transitively via `mix ecto.migrate`) — `replay_migrations/2` calls
  `Ecto.Migrator.run/4` directly, a new *direct* runtime dependency this module takes on
  a library that until now was only invoked via the `mix ecto.migrate` Mix task, not
  from application code.
- `Letflow.Identity.Tenant` (`lib/letflow/identity/tenant.ex`) — `tenant_schemas.tenant_id`'s
  DB-level FK target (§2). No Elixir-level `belongs_to`/association declared on
  `Registration` — matches this codebase's existing convention of plain `field
  :tenant_id, :binary_id` without an `Ecto.Schema` association even where a DB FK exists
  (see `Letflow.Identity.TenantRole.group_id`, identity-schema.md §3.4).
  `Letflow.TenantProvisioning` does not call into `Letflow.Identity` — the FK is the only
  coupling.
- `priv/repo/migrations/` — this requirement adds one new global migration
  (`CreateTenantSchemas`, §2). It does not modify any of the four existing S1 identity
  migrations.
- **Every REQ-023-onward requirement that adds a tenant-scoped table** — direct forward
  dependency in the other direction: each must (a) place its migration in
  `priv/repo/migrations/` following §4's guard pattern exactly, and (b) append its own
  `{version, module}` entry to `tenant_scoped_migrations/0`'s body (§3.4), i.e. those
  requirements' own implementation work includes a one-line edit to this module.
- **Testing environment caveat (flagged for TEST-DESIGNER at Step 3, not resolved
  here):** `Ecto.Migrator`'s own moduledoc (`deps/ecto_sql/lib/ecto/migrator.ex`, read
  directly, §0) states migrations "cannot run dynamically during test under
  `Ecto.Adapters.SQL.Sandbox`, as the sandbox has to share a single connection across
  processes to guarantee the changes can be reverted." `config/test.exs` configures
  exactly that pool. A test exercising `replay_migrations/2` will likely need
  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` (or an equivalent non-sandboxed
  connection strategy) for that specific test rather than the ambient `:manual`/checkout
  pattern the rest of the suite presumably uses — TEST-DESIGNER's own concern to resolve
  at Step 3, named here so it isn't a surprise discovered mid-test-writing.

## 7. Open question (explicit, per this requirement's own framing — NOT resolved here)

**REQ-015's `users`/`groups`/`tenant_role` tables currently live in the public default
schema** (per `lib/letflow/design/identity-schema.md` §1's deferral). **This requirement
does not retrofit those three tables to live under each tenant's own schema.** Only
`tenants` and this requirement's own `tenant_schemas` registry are structurally global —
a realm→tenant lookup must run before any tenant schema is known, so those two cannot
live inside a tenant schema by construction. Whether `users`/`groups`/`tenant_role`
*should* eventually be retrofitted behind `:prefix` (matching R-Co's own migration
history, where identity tables also moved behind schema-per-tenant post-migration-060,
per `docs/migration/decisions/0003-ecto-schema-strategy.md`'s Dimension B Reasoning) is
left open for a future requirement to decide explicitly — not assumed either way by this
design. This is REQ-022's own acceptance criterion 4; restated here verbatim in
substance because the requirement's own description demands the moduledoc state it as an
open question, not a silent decision (§8's traceability table points at exactly where
that moduledoc content must land).

**Secondary open question this design surfaced (not in REQ-022's original list, flagged
per this role's own instruction not to silently resolve a new one either):** should
`provision_tenant_schema/1` or some other entry point eventually validate that a
tenant's `Letflow.Identity.Tenant.status` is `:active` (not `:migrating`) before
provisioning proceeds? REQ-021's `Letflow.Plugs.TenantStatus` already gates *mutating
requests* on this status for existing tenants; nothing in REQ-022's acceptance criteria
asks `provision_tenant_schema/1` to check it, and this design does not add that check —
flagging it so a future tenant-onboarding-orchestration requirement (§3.2's "no implicit
chaining" note already anticipates such a requirement existing) makes that call
explicitly rather than it being silently absent.

## 8. Acceptance-criteria traceability

| REQ-022 acceptance criterion | Concrete design element |
|---|---|
| "priv/repo/migrations gains a tenant_schemas migration (public/default schema) that applies cleanly via mix ecto.migrate, with columns for at minimum tenant_id and schema_name" | §2 — full migration spec: columns, types, constraints, indexes, required header comment. No `prefix:` option anywhere in this migration (confirmed explicitly). |
| "a provision_tenant_schema/1-equivalent function exists that issues a real CREATE SCHEMA and records the mapping in tenant_schemas, demonstrated against at least one non-default tenant schema name" | §3.1 (full behavior spec, idempotency/atomicity/injection-safety invariants) + §5's demonstration method |
| "a migration-replay function exists that re-applies priv/repo/migrations/ against a specific tenant schema via Ecto's prefix: option, demonstrated by confirming at least one table exists under the provisioned schema's own information_schema, not just under public" | §3.2 (`replay_migrations/2`) + §3.4 (`tenant_scoped_migrations/0`, the "designated per-tenant subset" mechanism REQ-022's own description names as the alternative to a literal whole-directory replay — necessary, not optional, per §4's analysis of why a literal whole-directory replay cannot work against this project's actual migration directory contents) + §4 (the required per-migration guard pattern that makes the subset mechanism safe) + §5's demonstration method |
| "the moduledoc/description explicitly states, as an open question rather than a silent decision, whether REQ-015's users/groups/tenant_role migrations are retrofitted to use :prefix now or remain in public schema" | §7 (stated explicitly, unresolved) — ELIXIR-DEV must carry this into `Letflow.TenantProvisioning`'s actual `@moduledoc` verbatim in substance, matching how `identity-schema.md`'s deferral text was carried into the `CreateTenants`/`CreateUsers` migration header comments |
