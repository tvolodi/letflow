# Design: REQ-063 — Identity tables move behind per-tenant schema (Decision 0006 D1)

**Requirement:** REQ-063 (stage S3)
**Owner (implementer):** ELIXIR-DEV
**Executes:** `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md` D1
only. D2 (dropping `tenant_id`) is explicitly out of scope — reserved for REQ-064.
**This document produces:** three new tenant-scoped migration shapes, the
`tenant_scoped_migrations/0` manifest entries for them, the data-copy mechanism's
function signature, the public-table-drop migration, and an explicit scope boundary.

---

## 0. Sources read for this design

- `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md` (full — §3, §4,
  §5, §7 especially)
- `docs/migration/decisions/0003-ecto-schema-strategy.md` Dimension B + its 2026-08-17
  Addendum
- `lib/letflow/design/req022-tenant-schema-provisioning.md` §3.2 (`replay_migrations/2`),
  §3.4 (`tenant_scoped_migrations/0`), §4 (mandatory guard pattern), §7 (this
  requirement's own predecessor open question)
- `priv/repo/migrations/20260816000002_create_groups.exs`,
  `20260816000003_create_tenant_role.exs`, `20260816000004_create_users.exs` (current
  public-schema shape, unchanged column/type list carried forward)
- `lib/letflow/identity/user.ex`, `group.ex`, `tenant_role.ex` (current Ecto schema
  modules — moduledoc/field lists this requirement's implementer must also touch)
- `lib/letflow/identity.ex` (JIT upsert path — `insert_or_fetch/3`,
  `re_select_on_conflict/2`, `get_by_external_identity/2` — none of these signatures
  change under D1, confirmed: they operate on `Repo`/`User` without a `prefix:` today
  because `users` is public; REQ-063 does not touch `identity.ex` itself, since routing
  every identity call through a resolved tenant `:prefix` is deferred, see §6 below)
- `lib/letflow/tenant_provisioning.ex` (`tenant_scoped_migrations/0`'s current 14-entry
  manifest, `tenant_id_for_schema_name/1`, `schema_name_for_tenant/1`,
  `replay_migrations/2`, the `Registration` schema)
- R-Co `migrations/GBL-112_tnt01_drop_legacy_public_business_tables.sql` (guarded-drop
  precedent this design's step 4 migration follows)
- `docs/anti-patterns.md` (no directly-applicable prior finding for this shape; checked
  for the module-name-collision and JSON-round-trip classes — neither applies here)

---

## 1. Scope boundary (stated up front, per the requirement text)

**This design executes Decision 0006 D1 only.** Concretely, in scope:

- Three new tenant-scoped migrations creating `users`, `groups`, `tenant_role` inside
  each tenant's own Postgres schema (§2 below).
- Three new `tenant_scoped_migrations/0` manifest entries (§3).
- A data-copy mechanism moving each public row into the schema its `tenant_id` names
  (§4).
- A separate, guarded migration dropping the three legacy public tables (§5).

**Explicitly out of scope, not designed here:**

- **Dropping `tenant_id` from the per-tenant `users`/`groups` copies.** This is
  Decision 0006 D2, reserved for REQ-064, which must run strictly after this
  requirement ships. The per-tenant copies of `users` and `groups` this design produces
  **still carry `tenant_id`** — its column definition, `NOT NULL`, and its existing
  `index(:groups, [:tenant_id])` (and `users`' composite
  `index(:users, [:tenant_id, :status, :inserted_at])`) are carried into the per-tenant
  migrations unchanged. `tenant_role` has no `tenant_id` column today and gets none
  here (it never had one — see current migration).
- **AuthPipeline step reordering.** Decision 0006 §R5 already verified the existing
  realm → tenant → user order resolves the tenant (and hence the schema `:prefix`)
  before any `users` query runs. No pipeline change is designed here.
- **Decision 0006 D4** (cross-tenant reporting mechanism via `tenant_schemas` union).
  No consumer exists; out of scope.
- **Routing `Letflow.Identity`'s query/write functions through a resolved `:prefix`.**
  This is a necessary follow-up (once `users` moves per-schema, every
  `Repo.get_by(User, ...)`/`Repo.insert(changeset, ...)` call in `identity.ex` must gain
  a `prefix:` option, the same way `definitions.ex` already threads `prefix` through
  every `Repo` call) but it is **implementation work belonging to whichever
  requirement wires `AuthPipeline`/`Identity` calls to pass the resolved tenant schema
  through** — not named as in-scope by REQ-063's own acceptance criteria, which only
  ask for the migrations/manifest/copy/drop shape. Flagged as an **open question** in
  §7 rather than silently assumed either way, since leaving `identity.ex` as-is after
  this migration ships means every `Identity` call would target the *default* Postgres
  search path (`public`) where the tables no longer exist, producing a hard failure the
  moment the public tables are dropped (§5) — this is exactly why §7 below states it
  must be resolved, explicitly, before REQ-063's Step 5 (public-table-drop) is executed
  against a live target, not left for a future requirement to discover as a production
  incident.

---

## 2. Three new tenant-scoped migrations

All three follow `req022-tenant-schema-provisioning.md` §4's mandatory
`prefix()`-truthiness guard exactly: `change/0` creates the table with
`prefix: prefix()` only when `Ecto.Migration.prefix()` is truthy, and no-ops
(does nothing to `public`) otherwise. A plain `mix ecto.migrate` run passes no
`:prefix`, so these three files execute and do nothing; only a
`TenantProvisioning.replay_migrations/2` run (which passes a real tenant schema name)
takes the real branch.

Column/index/constraint shape is **unchanged from the current public-schema
migrations** except for (a) the guard, and (b) the `users` migration's key-shape
correction described in §2.3.

### 2.1 `CreateGroups` (tenant-scoped)

**File:** `priv/repo/migrations/<next-timestamp>_create_groups_tenant_scoped.exs`
**Module:** `Letflow.Repo.Migrations.CreateGroupsTenantScoped`

**Header comment must state:**
- This is Decision 0006 D1's per-tenant copy of `groups`, replacing the legacy public
  `groups` table (dropped separately by §5's migration, not by this one).
- `tenant_id` is **retained** on this per-tenant copy (D2/REQ-064 territory, not this
  migration's job) — carried forward unchanged from the public migration's shape.
- Follows `req022-tenant-schema-provisioning.md` §4's guard pattern; a plain
  `mix ecto.migrate` no-ops on this file.

**Table/columns (unchanged from `20260816000002_create_groups.exs`):**

| Column | Type | Constraints |
|---|---|---|
| `id` | `binary_id` | primary key |
| `tenant_id` | `binary_id` | `null: false` |
| `name` | `string` | `null: false` |
| `inserted_at`/`updated_at` | via `timestamps()` | — |

**Indexes (unchanged):** `index(:groups, [:tenant_id])`.

**No FK to `tenants.id`** — same rationale as today (schema boundary supersedes the
cross-schema FK concern; `tenant_id`'s FK omission was never about schema-per-tenant
readiness, it predates this move).

### 2.2 `CreateTenantRole` (tenant-scoped)

**File:** `priv/repo/migrations/<next-timestamp>_create_tenant_role_tenant_scoped.exs`
**Module:** `Letflow.Repo.Migrations.CreateTenantRoleTenantScoped`

**Header comment must state:**
- Decision 0006 D1's per-tenant copy of `tenant_role`.
- Per Decision 0006 §R4 and the *existing* `20260816000003_create_tenant_role.exs`
  header's own anticipation: `unique_index(:tenant_role, [:name])` becomes
  unique-per-tenant-schema automatically once this table is per-schema — **no index
  redesign**, carried forward byte-identical.
- `group_id`'s `references(:groups, type: :binary_id)` FK **must reference the
  per-tenant `groups` table inside the same schema**, i.e. this migration must run
  with the same `prefix:` as §2.1's `groups` table and Postgres resolves the
  unqualified `references(:groups, ...)` against the current `search_path`/schema —
  confirmed consistent with how `req043`'s `tokens`/`tasks` migrations already
  reference sibling tables inside the same tenant schema (no schema-qualification
  needed; `create table(..., prefix: prefix())` plus an unqualified
  `references(:groups, ...)` resolves within that same prefix, matching Ecto's
  documented `:prefix` semantics for `references/2` inside a prefixed
  `create table` block).
- Follows §4's guard pattern.

**Table/columns (unchanged from `20260816000003_create_tenant_role.exs`):**

| Column | Type | Constraints |
|---|---|---|
| `id` | `binary_id` | primary key |
| `name` | `string` | `null: false` |
| `group_id` | `binary_id` | `null: false`, `references(:groups, type: :binary_id)` |
| `inserted_at` | via `timestamps(updated_at: false)` | — |

**Indexes (unchanged):** `unique_index(:tenant_role, [:name])`,
`index(:tenant_role, [:group_id])`.

**No `tenant_id` column** — `tenant_role` never had one; nothing changes here.

### 2.3 `CreateUsers` (tenant-scoped) — the security-sensitive one

**File:** `priv/repo/migrations/<next-timestamp>_create_users_tenant_scoped.exs`
**Module:** `Letflow.Repo.Migrations.CreateUsersTenantScoped`

**Header comment must state, verbatim in substance (this is the artefact
SECURITY-REVIEWER re-derives its verdict against, not this design doc):**

1. This is Decision 0006 D1's per-tenant copy of `users`, replacing the legacy public
   `users` table (dropped separately by §5's migration).
2. `tenant_id` is **retained** on this per-tenant copy — D2/REQ-064's job to drop it,
   not this migration's.
3. `unique_index(:users, [:username])` — **carried forward unchanged, in shape.**
   Its *meaning* changes from global-unique to per-tenant-unique purely as a
   consequence of the table now living inside a per-tenant schema — no index
   definition edit needed to produce that effect. Decision 0006 §3.1: this is a
   deliberate, adopted change (globally-unique usernames across tenants was a
   multi-tenancy defect), not an incidental side effect to gloss over.
4. `unique_index(:users, [:external_realm, :external_id], where: "external_id IS NOT
   NULL", name: :users_external_identity_partial_index)` — **carried forward
   unchanged, in shape**, same per-tenant reinterpretation as (3). Decision 0006 §3.2:
   the prior *global* one-OIDC-identity-per-user guarantee is not lost, it is relocated
   to `tenants_idp_realm_id_partial_index` (a realm binds to exactly one tenant,
   immutably — enforced on `tenants`, a public-schema table Decision 0006 D3 keeps).
5. **Divergence closed, stated explicitly so it is never mistaken for a new
   weakening:** `docs/migration/decisions/0003-ecto-schema-strategy.md` line 132 and
   `lib/letflow/identity.ex`'s JIT upsert path both describe the upsert key as
   `(tenant_id, external_realm, external_id)`, but the *shipped* index — both in the
   current public migration and unchanged here — is `(external_realm, external_id)`
   without `tenant_id`. Before this move, the database was *stricter* than the
   documented contract (a real gap, not a weakening). This migration's move closes
   that gap: `tenant_id`'s role in that key is now taken over by the schema boundary
   itself — two rows with the same `(external_realm, external_id)` cannot coexist
   *within* one tenant's schema (the index still enforces that), and cannot coexist
   *across* tenant schemas either, by the §3.2 argument in point 4 above. The index
   is not changed by this migration; only its enforcement domain (now one schema
   instead of the whole database) changes, which is exactly what makes the documented
   and shipped keys agree for the first time.
6. Follows §4's guard pattern.

**Table/columns (unchanged from `20260816000004_create_users.exs`):**

| Column | Type | Constraints |
|---|---|---|
| `id` | `binary_id` | primary key |
| `tenant_id` | `binary_id` | `null: false` |
| `username` | `string` | `null: false` |
| `display_name` | `string` | `null: false` |
| `email` | `string` | `null: false` |
| `password_hash` | `string` | `null: false` |
| `status` | `string` | `null: false`, `default: "active"` |
| `auth_source` | `string` | `null: false`, `default: "internal"` |
| `external_id` | `string` | nullable |
| `external_realm` | `string` | nullable |
| `inserted_at`/`updated_at` | via `timestamps()` | — |

**Indexes (unchanged, shape-identical to today):**
- `unique_index(:users, [:username])`
- `unique_index(:users, [:external_realm, :external_id], where: "external_id IS NOT NULL", name: :users_external_identity_partial_index)`
- `index(:users, [:tenant_id, :status, :inserted_at])`

**No DB CHECK constraint** for `auth_source`-vs-external-fields consistency — unchanged,
still an application-level (changeset) invariant.

---

## 3. `tenant_scoped_migrations/0` manifest entries

`lib/letflow/tenant_provisioning.ex`'s `@tenant_scoped_migration_manifest` gains three
new `{version, module, filename}` tuples, **appended after REQ-043's three existing
entries** (the current last entry is `{20_260_818_110_003,
Letflow.Repo.Migrations.CreateTasks, "20260818110003_create_tasks.exs"}`) — REQ-063
ships strictly after REQ-043 in the run sequence, so its migrations' timestamps sort
after REQ-043's by construction, preserving the manifest's documented ascending-version
invariant.

**Ordering within REQ-063's own three entries matters** — `tenant_role.group_id`
carries a DB-level FK to `groups.id` (§2.2), so `groups` must be created before
`tenant_role` within the same `replay_migrations/2` run (`Ecto.Migrator.run/4` applies
migrations in ascending version order, so the manifest's ordering directly controls DDL
ordering). `users` has no FK dependency on either of the other two and no migration
depends on `users`, so it may sort anywhere relative to them; this design places it
last for narrative grouping (least-simple table last), not because ordering requires
it.

```
{20_260_819_0YY_001, Letflow.Repo.Migrations.CreateGroupsTenantScoped,
 "<timestamp>_create_groups_tenant_scoped.exs"},
{20_260_819_0YY_002, Letflow.Repo.Migrations.CreateTenantRoleTenantScoped,
 "<timestamp>_create_tenant_role_tenant_scoped.exs"},
{20_260_819_0YY_003, Letflow.Repo.Migrations.CreateUsersTenantScoped,
 "<timestamp>_create_users_tenant_scoped.exs"}
```

ELIXIR-DEV substitutes real `YYYYMMDDHHMMSS`-shaped timestamps (matching this
project's existing filename convention, strictly increasing and strictly after
`20260818110003`) for `<timestamp>`/`20_260_819_0YY_00N` above — this design fixes the
*relative* ordering (groups → tenant_role → users) and the *manifest-append* position,
not literal digits.

The manifest's own explanatory comment block (currently documenting REQ-023 through
REQ-043's contributions) must gain one more sentence naming REQ-063's three entries, in
the same style as the existing entries — this is a doc-comment edit, not new design
surface.

**`tenant_scoped_migrations/0`'s public `@spec` does not change**
(`[{version :: pos_integer(), module()}]`, per `req022` §3.4) — REQ-063 only grows the
list's contents, exactly as every migration-adding requirement since REQ-023 has done.

---

## 4. Data-copy mechanism (Decision 0006 §4 step 3)

**Shape decision: a Mix task, not a migration and not an ad-hoc script.**

Reasoning: this is a one-time, operator-invoked cutover action, not a schema change —
`Ecto.Migration` modules are for DDL/structural change replayed automatically by
`replay_migrations/2` across every tenant; folding a data-copy loop into a migration
body would run it once per `mix ecto.migrate` invocation with no natural idempotency
guard and no clean per-tenant-schema targeting story (a migration's `prefix()` is
supplied by its caller, but this operation needs to iterate over *every already
provisioned* tenant, which is an application-level query against
`tenant_schemas`/`Repo`, not something a single migration's `change/0` expresses
cleanly). A Mix task matches this project's existing precedent for
operator-invoked-but-not-schema-shaped actions (`mix ecto.migrate` itself, `mix
ecto.setup` per `docs/guides/backend_developer_guide.md`) and can be re-run safely if
built idempotently (see below), unlike a `.exs` script with no `mix` bookkeeping.

**File:** `lib/mix/tasks/letflow.copy_identity_tables.ex`
**Task name:** `mix letflow.copy_identity_tables`
**Module:** `Mix.Tasks.Letflow.CopyIdentityTables`

The task's real logic is delegated to a plain function so it is unit-testable without
going through `Mix.Task.run/1` — same separation-of-concerns convention as this
project's other Mix-task-adjacent modules keep task plumbing thin.

**Delegate module/function:**

```
@spec Letflow.IdentityMigration.copy_all_tenants() ::
        {:ok, %{tenants_processed: non_neg_integer(),
                users_copied: non_neg_integer(),
                groups_copied: non_neg_integer(),
                tenant_roles_copied: non_neg_integer()}}
      | {:error, {:tenant_copy_failed, tenant_id :: Ecto.UUID.t(), reason :: term()}}
```

**Behavior:**

1. Load every registered tenant from `TenantProvisioning.Registration` (`Repo.all/1`,
   no filter — every provisioned tenant is a copy target; a tenant with no
   `Registration` row has no schema to copy into and is out of scope for this
   function, matching `replay_migrations/2`'s own precedent of never provisioning on
   the fly).
2. For each `%Registration{tenant_id: tenant_id, schema_name: schema_name}`, call
   `copy_tenant(tenant_id, schema_name)` (below) inside its own
   `Repo.transaction/1` — one transaction per tenant, not one transaction for the
   whole run, so one tenant's failure does not roll back copies already committed for
   other tenants (matches this migration's low-stakes framing: no production
   deployment exists yet, per `CLAUDE.md`'s humanless-operation note, but the
   per-tenant transaction boundary is still the correct shape for when a real cutover
   eventually runs this for real).
3. On any tenant's failure, **stop and return `{:error, {:tenant_copy_failed,
   tenant_id, reason}}` immediately** — do not silently skip a failed tenant and
   continue, since an incomplete copy for one tenant is exactly the kind of partial
   state Decision 0006 §4's ordering discipline exists to prevent from reaching step
   4 (the drop).
4. On full success, return `{:ok, summary_map}` with the counts named above.

```
@spec Letflow.IdentityMigration.copy_tenant(
        tenant_id :: Ecto.UUID.t(),
        schema_name :: String.t()
      ) :: {:ok, %{users: non_neg_integer(), groups: non_neg_integer(),
                    tenant_roles: non_neg_integer()}}
         | {:error, term()}
```

**Behavior, per tenant, in this order (groups before tenant_role, matching §3's FK
dependency — `tenant_role.group_id` must resolve inside the destination schema):**

1. `Repo.all(from(g in Group, where: g.tenant_id == ^tenant_id))` (queried against
   `public`, the schema these rows still live in at copy time — no `prefix:` option on
   this read) → for each row, `Repo.insert(Group.changeset_from_struct(row), prefix:
   schema_name, on_conflict: :nothing, conflict_target: :id)`. The `:id` primary key is
   preserved verbatim (client-generated `binary_id`, same value in the destination row)
   so any other public-schema data still holding a reference to that `group_id` by
   value continues to resolve correctly during the transition window.
2. `Repo.all(from(u in User, where: u.tenant_id == ^tenant_id))` → same insert pattern
   into the tenant schema, `prefix: schema_name`, `on_conflict: :nothing`,
   `conflict_target: :id`, preserving `id`.
3. **`tenant_role` requires special handling: it carries no `tenant_id` column**, so
   "each row's `tenant_id`" cannot select its rows directly. Decision 0006's own text
   treats `tenant_role` as no-redesign-needed because it was written anticipating this
   move, but does not specify how a *tenant_id-less* table's existing public rows are
   partitioned across tenant schemas during copy. **This is answered here rather than
   left silently unresolved:** `tenant_role.group_id` has a DB-level FK to `groups.id`,
   and every `groups` row does carry `tenant_id` — so `tenant_role`'s rows are copied
   per-tenant by joining through `groups`:
   `Repo.all(from(tr in TenantRole, join: g in Group, on: tr.group_id == g.id, where: g.tenant_id == ^tenant_id, select: tr))`.
   A `tenant_role` row whose `group_id` does not resolve to any `groups` row (an
   orphan — should not exist given the FK constraint on the *current* public schema,
   but the copy function must not silently drop data if one somehow does) is treated
   as a `{:error, {:orphaned_tenant_role, tenant_role_id}}` and aborts that tenant's
   transaction per step 3 above, rather than being silently skipped.
4. Return `{:ok, %{users: N, groups: M, tenant_roles: K}}` with the actual copied
   counts.

**Idempotency:** `on_conflict: :nothing` + `conflict_target: :id` on every insert makes
`copy_tenant/2` (and therefore `copy_all_tenants/0`) safe to re-run after a partial
failure — already-copied rows are silently skipped on re-run, matching the
`on_conflict: :nothing`/re-select idiom this codebase already uses in
`TenantProvisioning.insert_or_fetch_registration/2` and `Identity.insert_or_fetch/3`.
This function does not need a `re_select_on_conflict`-style read-back, unlike those two
callers, because its return value is a count, not an identity the caller needs to act
on further.

**Invocation shape:** `mix letflow.copy_identity_tables` with no arguments, run once
per environment as an explicit operator (or pipeline) step between §3's manifest
landing (migrations replayed across every tenant schema, tables exist and are empty)
and §5's drop migration running. **Not run automatically by `mix ecto.migrate`** — it
is not a migration and must not be added to `tenant_scoped_migrations/0` or any
`priv/repo/migrations/*.exs` file; it depends on `TenantProvisioning.Registration`
data and application code (`Repo`, Ecto schemas) in a way a raw migration deliberately
does not.

---

## 5. Public-table-drop step (Decision 0006 §4 step 4)

**Separate guarded migration, never bundled into §2's per-tenant `create table`
migrations** — follows R-Co's `GBL-112_tnt01_drop_legacy_public_business_tables.sql`
precedent of a guarded, separate cutover step.

**File:** `priv/repo/migrations/<next-timestamp>_drop_legacy_public_identity_tables.exs`
**Module:** `Letflow.Repo.Migrations.DropLegacyPublicIdentityTables`
**NOT added to `tenant_scoped_migrations/0`** — this is a global-schema migration (it
targets `public`, the same category `CreateTenantSchemas` and the four original S1
identity migrations belong to), so it runs exactly once via a plain `mix ecto.migrate`,
the same way every other global migration in `priv/repo/migrations/` already does. It
carries no `prefix()` guard — that guard pattern is exclusively for tenant-scoped
tables (§4 of `req022`'s design); this migration is the opposite case; a plain
`mix ecto.migrate` **must** run it, not skip it.

**Guard condition:** the requirement text names GBL-112's precedent explicitly, so this
migration adopts the same shape: an `execute/1`-driven guard that checks whether the
data copy (§4) has actually completed before dropping, rather than dropping
unconditionally. Concretely — **new open question, stated rather than silently
resolved (see §7 item 3):** GBL-112's own guard checks a
`migration_window_active` flag on a separate `onboarding_registry` table; Letflow has
no equivalent flag today. This design proposes the guard instead check, per table,
that every row present in `public.<table>` also exists (by `id`) in at least one
tenant schema — but the exact mechanism (a literal per-row existence check via
`dblink`/a loop, vs. a simpler row-count parity check against
`copy_all_tenants/0`'s own returned summary persisted somewhere, vs. an operator-set
boolean the migration reads the same way GBL-112 reads `migration_window_active`) is
**not decided by this design** and is listed in §7 as an open question for ELIXIR-DEV
to resolve at implementation time, in consultation with SECURITY-REVIEWER/REVIEWER
given it is the one piece of this design with real data-loss risk if the guard is
wrong. Whatever mechanism is chosen, the migration must:

1. Skip the drop (log a notice, take no action) if the guard condition is not
   satisfied — never drop unconditionally.
2. Use `DROP TABLE IF EXISTS public.<table>` (idempotent, matching GBL-112's own
   `DROP TABLE IF EXISTS ... CASCADE` shape) for all three tables:
   `public.tenant_role`, `public.users`, `public.groups` — **in that order**
   (`tenant_role` first, since it FKs to `groups`; `CASCADE` is not strictly required
   given `IF EXISTS`+explicit ordering, but including it matches GBL-112's own belt-
   and-suspenders precedent and costs nothing since these public tables have no other
   inbound FK from outside this same three-table group, confirmed by grep across
   `priv/repo/migrations/*.exs` for `references(:users` / `references(:groups` /
   `references(:tenant_role` — no hits outside these three tables' own migrations).
3. Carry a header comment naming Decision 0006 §4 step 4 and GBL-112 as the precedent,
   and stating explicitly that this migration must never run before §4's data copy has
   been verified complete for every registered tenant.

---

## 6. Cross-module dependencies

- `Letflow.TenantProvisioning` (`tenant_scoped_migrations/0`, `Registration`,
  `schema_name_for_tenant/1`) — §3's manifest edit is a direct edit to this module;
  §4's copy task reads `Registration` rows from it.
- `Letflow.Identity.{User, Group, TenantRole}` — no schema-module field changes in this
  requirement (D2's `tenant_id` field removal is REQ-064's). Their moduledocs'
  "`tenant_id` is an intra-schema column" framing becomes stale once these tables are
  per-schema rather than public — **moduledoc wording update flagged as
  implementation-detail cleanup for ELIXIR-DEV, not a schema/behavior change**, since
  the field itself doesn't move under this requirement.
- `Letflow.Identity` (`identity.ex`) — **not modified by this requirement's design**
  (see §1's scope boundary) but becomes functionally broken the moment §5's drop
  migration runs, unless something threads a `prefix:` option through its `Repo`
  calls first. This is §7 item 1's open question, restated here as a hard cross-module
  dependency: §5 must not execute in any environment where `identity.ex` still queries
  `users`/`groups` unprefixed.
- `Letflow.Plugs.AuthPipeline` — no code change (Decision 0006 §R5, restated in the
  requirement text); listed here only because it is the caller that would surface
  §7 item 1's gap first, at runtime, if that gap ships unresolved.
- `priv/repo/migrations/` — three new tenant-scoped `create table` migrations (§2), one
  new global `DROP TABLE` migration (§5). Does not modify the four existing S1 global
  migrations (`CreateTenants`, `CreateGroups`, `CreateTenantRole`, `CreateUsers`) — they
  stay on disk as the historical record of what created the now-dropped public tables,
  consistent with how this project has never deleted a superseded migration file
  elsewhere (REQ-043's `AlterInstanceProjectionsAddEngineColumns` pattern: alter/replace
  via a new migration, not an edit to the old one).
- `lib/mix/tasks/letflow.copy_identity_tables.ex` / `Letflow.IdentityMigration` — new
  module and new Mix task, first of their kind in this codebase (no prior
  `lib/mix/tasks/` directory exists); depends on `Letflow.Repo`,
  `Letflow.TenantProvisioning.Registration`, and the three `Letflow.Identity.*` schema
  modules.

---

## 7. Open questions (explicit, per Decision 0006 §7 and this requirement's own
   framing — NOT resolved here)

1. **How does `Letflow.Identity`'s query/write path learn the tenant schema `:prefix`
   once `users`/`groups` move per-schema?** Decision 0006 does not name this — it is a
   gap this design surfaced while checking `identity.ex`'s current call sites (none
   thread a `prefix:` option today, because the tables are public today). Until this is
   resolved, §5's drop migration must not run against any environment where
   `AuthPipeline`/`Identity` are expected to keep working — this is a hard
   precondition, not a nice-to-have, and is the single biggest risk this design
   surfaced that Decision 0006's text does not already flag. A future requirement (or
   an amendment to this one, at ELIXIR-DEV's/REVIEWER's discretion during
   implementation) must design how the resolved tenant schema name reaches
   `Identity`'s functions — e.g. threading it as an explicit argument the way
   `definitions.ex`'s `opts :: [prefix: String.t()]` convention already does, called
   from `AuthPipeline` once the tenant is resolved.
2. **Does `tenants.status == :migrating` gate the D1 cutover?** Restated verbatim from
   Decision 0006 §7 item 2 / `req022` §7's secondary open question — this design does
   not add any check against `Letflow.Identity.Tenant.status` anywhere in §4's copy
   task or §5's drop migration. Whether the cutover should pause for tenants currently
   `:migrating` is left to a future requirement or explicit ELIXIR-DEV/REVIEWER
   decision at implementation time, not silently assumed.
3. **What is the exact guard mechanism for §5's drop migration?** Named above in §5 —
   GBL-112's `onboarding_registry.migration_window_active` flag has no Letflow
   equivalent; the specific mechanism (per-row check, count-parity check, or an
   operator-set flag) is implementation-time ELIXIR-DEV's decision, made in
   consultation with SECURITY-REVIEWER given the data-loss risk if wrong, not resolved
   by this design.
4. **How do existing `AuthPipeline`/`Identity` tests that assume a public-schema
   `users` table need to change their setup?** Flagged explicitly for TEST-DESIGNER at
   Step 3, not resolved here. Every existing test that inserts a `User`/`Group`/
   `TenantRole` fixture directly (no `prefix:` option) currently lands in `public`,
   which after this requirement ships still physically exists as a table until §5's
   drop runs, but is no longer where application code reads from once §7-item-1 is
   resolved and `Identity` starts passing `prefix:`. Test fixtures will need to insert
   into a real provisioned tenant schema (via `TenantProvisioning.provision_tenant_schema/1`
   + `replay_migrations/2`, the same pattern `req022` §3's testing-environment caveat
   already flags for `Ecto.Adapters.SQL.Sandbox`) rather than the bare public table.
   This is TEST-DESIGNER's own concern to resolve at Step 3; named here so it is not a
   surprise discovered mid-test-writing, per this design step's own instruction not to
   silently resolve a downstream concern it doesn't own.

---

## 8. Acceptance-criteria traceability

| REQ-063 acceptance criterion (from handoff `task.acceptance_criteria`) | Concrete design element |
|---|---|
| Every REQ-063 acceptance criterion maps to a concrete design element | This table |
| All three new migrations' full column/index/constraint shape specified, including the users migration's closed tenant_id-key divergence | §2.1 (groups), §2.2 (tenant_role), §2.3 (users, including the point-5 divergence-closure statement) |
| tenant_scoped_migrations/0's new manifest entries specified with exact ordering | §3 — three tuples, appended after REQ-043's entries, groups-before-tenant_role ordering justified by the FK dependency |
| Data-copy mechanism's function signature and invocation shape specified | §4 — `Letflow.IdentityMigration.copy_all_tenants/0` and `copy_tenant/2` @specs, Mix task file/name, idempotency mechanism, invocation instructions |
| Public-table-drop step specified as a separate guarded migration, not bundled into the same migration as the per-tenant tables | §5 — separate migration file, not part of §2's three files, GBL-112 guard precedent, guard mechanism named as an open question (§7 item 3) rather than invented |
| Design explicitly states tenant_id is NOT dropped by this design (reserved for REQ-064) | §1 (scope boundary, top-level statement) and restated in §2.1/§2.3's per-migration header-comment requirements |
| Open questions from decision 0006 section 7 restated and not silently resolved | §7 items 2 (status == :migrating gate) restates Decision 0006 §7 item 2 verbatim in substance; §7 item 4 restates the requirement text's own AuthPipeline/Identity test-fixture question; §7 items 1 and 3 are two *additional* open questions this design surfaced while checking `identity.ex`'s current call sites and GBL-112's guard mechanism, flagged per this role's standing instruction not to silently resolve a newly-found gap either |
