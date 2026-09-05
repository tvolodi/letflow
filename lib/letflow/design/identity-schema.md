# Design: REQ-015 — Ecto schema/migrations for tenants, users, groups, tenant_role

**Requirement:** REQ-015 (`docs/requirements.yaml`, stage S1)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** migration shape + Ecto.Schema shape only. No implementation
code, no changeset bodies. ELIXIR-DEV writes the actual `.exs`/`.ex` files from this.

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-015 (full entry) and REQ-016 through REQ-021 (to confirm
  none require multi-schema provisioning to exist yet — see §1 below).
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — Decision A (Ecto-idiomatic:
  `binary_id` PK, `Ecto.Enum` for status columns, names preserved where meaningful) and
  Decision B (schema-per-tenant via Ecto `:prefix`/dynamic-repo, `tenant_id` retained as
  an intra-schema column — not the isolation boundary itself).
- `docs/migration/stage-1-identity.md` — confirms S1 inherits 0002/0003 as-is, no new
  stage-specific decision needed unless S1 surfaces something genuinely new (it doesn't,
  for this requirement).
- R-Co `src/design/adp-04-user-tenant-binding.md`, `adp-04a-external-identity-linkage-user.md`,
  `adp-04b-tenant-realm-binding.md` — read in full, cited by section throughout below.
- `lib/letflow/row_approval/approval.ex`, `lib/letflow/events/transition_event.ex`,
  `priv/repo/migrations/20260814000001_create_transition_events.exs`,
  `priv/repo/migrations/20260814000002_create_approvals.exs` — current Letflow
  conventions this design matches (`@primary_key {:id, :binary_id, autogenerate: true}`,
  `primary_key: false` + explicit `add :id, :binary_id, primary_key: true` in migrations,
  `timestamps/1`, index on the FK-like column).
- `docs/guides/backend_developer_guide.md` §3.1 (naming), §3.7 (migration shape), §5
  (multi-tenancy, points at 0003).
- Confirmed by grep: no `groups` module and no tenant-schema-provisioning code exists
  anywhere in `lib/letflow/` today — `priv/repo/migrations/` holds exactly the two
  single-schema migrations cited above. This grounds the deferral decision in §1.

## 1. Schema-per-tenant-provisioning: built now vs. deferred — DECISION: DEFERRED

**Decision: this requirement targets Ecto's single default (`public`) schema. The
`:prefix`/dynamic-repo multi-schema provisioning mechanism itself is NOT built here —
it is flagged as explicit follow-up work.** `tenant_id` is retained as an intra-schema
column on `users` per Decision B either way, so nothing downstream is blocked or
reworked when the provisioning mechanism is eventually added.

**Reasoning:**

1. Decision B (`0003-ecto-schema-strategy.md` Dimension B) states the *target* isolation
   model (schema-per-tenant + intra-schema `tenant_id`) but explicitly scopes the
   provisioning *mechanism* itself out of REQ-012: "This requires a migration-runner
   change beyond a single `mix ecto.migrate` run: a `tenant_schemas`-equivalent registry
   and a provisioning path ... are needed at S2/S3 execution time — this decision names
   the mechanism, it does not build it (out of REQ-012's scope, per this file's own
   Question section and the design artefact's §7)." REQ-015 is not S2/S3; nothing in
   0003 obligates REQ-015 to build the provisioning path either.
2. REQ-015 is S1's first requirement, with `depends_on: []` — nothing yet consumes
   multi-schema behavior. Read in full: REQ-016 (OIDC dependency/supervision wiring),
   REQ-017 (pure claim-mapping function, explicitly "no I/O"), REQ-018 (JIT
   provisioning — operates on `users`, keyed on `(tenant_id, external_realm,
   external_id)`, no mention of schema prefixes), REQ-019 (tenant<->realm binding —
   operates on `tenants`, no schema-prefix requirement), REQ-020 (role registry —
   operates on `tenant_role`/`groups`, no schema-prefix requirement), REQ-021 (Plug
   pipeline wiring — orchestration only). All six require the four tables to *exist and
   be queryable*; none requires a real second Postgres schema to exist, none passes a
   `prefix:` option anywhere in its described contract, and none tests cross-schema
   behavior.
3. R-Co's own migration history (per 0003 Dimension B's Reasoning) *also* started
   tenant-column-only (migrations 001–059, no schema-per-tenant) and only added
   schema-per-tenant provisioning later (migration 060, `SPT-01`) once real
   multi-tenant load existed to justify it — R-Co is direct precedent for "start
   single-schema, add the provisioning mechanism as its own later migration event," not
   evidence that the very first identity migration must include it.
4. Building real `:prefix` plumbing now, with a single tenant (`bpm-default`) and zero
   consumers of a second schema, means either (a) a schema-provisioning
   function/registry with nothing yet exercising it beyond the default schema — dead
   code paths CODE-DESIGN-VALIDATOR and REVIEWER would have nothing concrete to check
   against — or (b) inventing a synthetic second tenant/schema purely to demonstrate the
   mechanism, which is scope creep beyond what REQ-015's acceptance criteria ask for
   ("migrations gains migrations for tenants, users, groups, and tenant_role, all
   applying cleanly via `mix ecto.migrate`" — no acceptance criterion mentions a second
   schema or a provisioning function).
5. Cost of deferring is low and explicit: adding `:prefix` support later means (a) a
   `tenant_schemas` registry table/migration, (b) a provisioning function
   (`create_tenant_schema/1`-equivalent, mirroring R-Co's
   `bpm_provision_tenant_schema`), and (c) re-running `Ecto.Migration`'s `create table`
   calls with a `prefix:` option per tenant schema (Ecto migrations already support
   `prefix:` on `table/2` — this is additive, not a breaking change to the migrations
   this requirement writes). No column or index shape decided in this document needs to
   change when that mechanism lands.

**Alternative considered and rejected:** building `:prefix` provisioning now. Rejected
per points 2 and 4 above — there is no consumer to validate it against yet, and R-Co's
own history supports deferring the provisioning mechanism specifically (as opposed to
the tenant-column layer, which R-Co had from the start and which this requirement does
build, via `tenant_id` on `users`).

**Follow-up work this creates (must be filed, not silently assumed by a later
requirement):** a new requirement — recommend `REQ-02x`, S2 or early S3, whichever
stage first has a real consumer of a second tenant schema — to add: a
`tenant_schemas` registry table, a schema-provisioning function
(`Letflow.Identity.provision_tenant_schema/1`-shaped, mirroring R-Co's
`bpm_provision_tenant_schema`), and a migration-replay mechanism analogous to R-Co's
`runForSchema` (re-apply `priv/repo/migrations/` per registered tenant schema under
Ecto's `prefix:` option). REQ-ANALYST should register this explicitly when S2's
requirements are expanded; CODE-DESIGN-VALIDATOR should not fail this design for
naming it as follow-up rather than building it, since 0003 itself scoped the mechanism
to "S2/S3 execution time," not S1.

**Migration moduledoc requirement:** every migration file below must state this
decision explicitly in its `@moduledoc`-equivalent (a `# `-comment header, since
`Ecto.Migration` modules don't carry `@moduledoc`, matching this project's existing two
migrations which use plain comments) — see §2's per-migration templates, each of which
includes the required comment block verbatim for ELIXIR-DEV to copy.

## 2. Migrations (`priv/repo/migrations/`)

All four in Ecto's default schema (no `prefix:` option — see §1). All follow the
established shape: `primary_key: false` + explicit `add :id, :binary_id, primary_key:
true`, `null: false` on required columns, timestamp-prefixed filenames,
`Letflow.Repo.Migrations.<CamelCase>` module names. Use one file per table (four
files), each independently reversible via plain `change/0` (all operations here are
`Ecto.Migration` primitives Ecto can auto-reverse — no `execute/1` needed for this
requirement, unlike the eventual GIN/full-text index or provisioning-function cases
0003 flags for later).

**Ordering constraint:** `groups` must be created before `tenant_role` (FK reference).
`tenants` has no FK dependency on the others. `users` has no FK dependency on the
others for this requirement (see §2.2's note on why `users.tenant_id` is NOT a DB-level
FK). Recommended filename order (timestamps strictly increasing):

1. `..._create_tenants.exs`
2. `..._create_groups.exs`
3. `..._create_tenant_role.exs`
4. `..._create_users.exs`

### 2.1 `tenants`

Source: adp-04b §"Data model and migration/backfill semantics", §"Core types"
(`Tenant` struct), §"Key invariants" 1–2.

PROVENANCE (historical, not current decision authority):
| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `:binary_id` | `primary_key: true` | Decision A |
| `slug` | `:string` | `null: false` | unique — see index below. adp-04b's `Tenant.slug` |
| `display_name` | `:string` | `null: false` | adp-04b's `Tenant.display_name` |
| `status` | `:string` | `null: false`, `default: "active"` | backing column for `Ecto.Enum` `[:active, :migrating]` — see §3.1. adp-04b doesn't define `TenantStatus`'s values explicitly; `:migrating` is sourced from R-Co's `src/api/middleware/tenant_status.zig`'s write-pause check (also cited in REQ-021's description) which is the concrete consumer of a "migrating" tenant status |
| `idp_realm_id` | `:string` | nullable (no `null: false`) | adp-04b: `tenant.idp_realm_id TEXT NULL`. Non-null-for-non-default-tenant is an **application-level rule** (adp-04b §"Forward constraints (OIDC-enabled mode)": "Non-default tenant insert requires non-empty `idp_realm_id`" — conditional on OIDC-enabled mode, a runtime config value a DB CHECK constraint cannot see), enforced in a later requirement's changeset (REQ-019), NOT a DB CHECK constraint here |

Indexes:
- `create unique_index(:tenants, [:slug])` — global uniqueness (adp-04b doesn't say
  otherwise; slugs are the human-facing tenant identifier, uniqueness is assumed
  baseline, not stated as an open question).
- `create unique_index(:tenants, [:idp_realm_id], where: "idp_realm_id IS NOT NULL", name: :tenants_idp_realm_id_partial_index)`
  — **partial**, per REQ-015's description resolving adp-04b's own OQ-2 ("Should a
  unique index on `tenant.idp_realm_id` be partial ... or full with CHECK constraints
  for empty strings?") explicitly in favor of partial. State this resolution in the
  migration's comment header verbatim — adp-04b leaves it open, Letflow does not.

No DB CHECK constraint enforcing "non-null idp_realm_id for non-default tenant" —
confirmed exclusion, see the `idp_realm_id` row above and the required moduledoc
comment in the template below.

**Required migration file header comment (ELIXIR-DEV: copy verbatim, adapt only the
module name/table per file):**

```
# Letflow.Repo.Migrations.CreateTenants
#
# Ported from R-Co src/design/adp-04b-tenant-realm-binding.md ("Data model and
# migration/backfill semantics", "Key invariants" 1-2).
#
# Schema-per-tenant provisioning (Ecto :prefix/dynamic-repo, per
# docs/migration/decisions/0003-ecto-schema-strategy.md Decision B) is NOT built in
# this migration. This table (and users/groups/tenant_role in their sibling
# migrations) targets Ecto's single default schema. tenant_id is retained as an
# intra-schema column on users per Decision B regardless. Multi-schema provisioning
# is deferred as explicit follow-up work — see lib/letflow/design/identity-schema.md
# section 1 for the full reasoning and the recommended follow-up requirement.
#
# idp_realm_id's unique index is PARTIAL (WHERE idp_realm_id IS NOT NULL) per
# REQ-015, resolving adp-04b's own Open Question OQ-2 explicitly in favor of
# partial (adp-04b leaves this open; Letflow does not).
#
# No DB CHECK constraint enforces "idp_realm_id required for non-default tenants
# in OIDC-enabled mode" (adp-04b's Forward Constraints) -- that rule is conditional
# on runtime OIDC-mode config, which a migration-time CHECK constraint cannot see.
# It is an application-level (changeset) invariant, enforced in REQ-019.
```

### 2.2 `users`

Source: adp-04 §"Data model and migration/backfill semantics", §"Index and constraint
guidance"; adp-04a §"Data model and migration/backfill semantics", §"Unique index
semantics", §"Key invariants".

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `:binary_id` | `primary_key: true` | Decision A |
| `tenant_id` | `:binary_id` | `null: false` | Decision B intra-schema column. **No DB-level foreign-key reference to `tenants.id`** — see rationale below |
| `username` | `:string` | `null: false` | adp-04's `User.username`. Global uniqueness preserved per adp-04's own Open Question 1 answer ("Current design preserves existing global uniqueness for strict backward compatibility") — see index below |
| `display_name` | `:string` | `null: false` | adp-04's `User.display_name` |
| `email` | `:string` | `null: false` | adp-04's `User.email` |
| `password_hash` | `:string` | `null: false` | Not in adp-04's Zig struct (R-Co's `User` struct omits storage-layer fields like password hash from its public interface type), but required for `auth_source: :internal` rows per REQ-015's description; for `auth_source: :oidc` JIT-created rows, REQ-018 sets this to R-Co's fixed marker value `"__OIDC_ONLY__"` — column itself has no CHECK, just `null: false` |
| `status` | `:string` | `null: false`, `default: "active"` | backing column for `Ecto.Enum` `[:active, :inactive]` (adp-04's `UserStatus`) |
| `auth_source` | `:string` | `null: false`, `default: "internal"` | backing column for `Ecto.Enum` `[:internal, :oidc]` (adp-04a's `AuthSource`) |
| `external_id` | `:string` | nullable | adp-04a: `external_id TEXT NULL` (OIDC `sub`) |
| `external_realm` | `:string` | nullable | adp-04a: `external_realm TEXT NULL` |
| — | | | `inserted_at`/`updated_at` via `timestamps()` |

**Why no DB-level FK from `users.tenant_id` to `tenants.id`:** under §1's deferral
decision, both tables live in the same default schema today, so a literal
`references(:tenants)` FK *could* be added without error — but doing so would need to
be dropped or reworked the moment tenant tables move behind per-tenant schema prefixes
(cross-schema FKs are not how Postgres schema-per-tenant isolation is meant to work —
each tenant schema is expected to be self-contained). Since §1 already commits to that
future move, adding a same-schema FK now would be a decision this design would have to
walk back later for no durability benefit today (nothing in REQ-015's acceptance
criteria requires referential-integrity enforcement at the DB level; adp-04's own
repository contract enforces tenant scoping at the service/repository boundary, not via
a SQL FK). ELIXIR-DEV should NOT add `references(:tenants)` on this column — this is a
deliberate omission, not an oversight.

Indexes:
- `create unique_index(:users, [:username])` — global, per adp-04's OQ-1 resolution
  (kept as-is, not tenant-scoped).
- `create unique_index(:users, [:external_realm, :external_id], where: "external_id IS NOT NULL", name: :users_external_identity_partial_index)`
  — **partial**, NULL-collision-safe form per adp-04a §"Unique index semantics":
  "Recommended implementation form for uniqueness to avoid NULL-collision edge cases:
  Unique index over `(external_realm, external_id)` filtered to rows where `external_id
  IS NOT NULL`." This is REQ-015's explicit acceptance criterion — must be partial, not
  a plain unique constraint.
- `create index(:users, [:tenant_id, :status, :inserted_at])` — per adp-04 §"Index and
  constraint guidance": `idx_users_tenant_status_created` on `(tenant_id, status,
  created_at DESC)`. Ecto's plain `index/3` doesn't take a per-column sort direction in
  the simple form; if ELIXIR-DEV wants the `DESC` ordering preserved exactly, use
  `create index(:users, [:tenant_id, :status, "inserted_at DESC"])` (fragment form) —
  either the plain ascending form or the DESC fragment form satisfies REQ-015's
  acceptance criterion, which only requires "an index on (tenant_id, status,
  inserted_at)" without mandating sort direction; note the choice made in the
  migration's comment header either way.

No DB CHECK constraint enforcing auth_source-vs-external-fields consistency (adp-04a's
rule 2: `auth_source = oidc` requires both external fields non-null; `auth_source =
internal` requires both null) — explicit exclusion per REQ-015's description and
acceptance criteria. This is deferred to REQ-018/REQ-019's changeset-level validation.

**Required migration file header comment (ELIXIR-DEV: copy verbatim):**

```
# Letflow.Repo.Migrations.CreateUsers
#
# Ported from R-Co src/design/adp-04-user-tenant-binding.md ("Data model and
# migration/backfill semantics", "Index and constraint guidance") and
# src/design/adp-04a-external-identity-linkage-user.md ("Data model and
# migration/backfill semantics", "Unique index semantics", "Key invariants").
#
# tenant_id has NO database-level foreign-key reference to tenants.id. This is
# deliberate: docs/migration/decisions/0003-ecto-schema-strategy.md Decision B's
# target model is schema-per-tenant (deferred as a follow-up mechanism, see
# lib/letflow/design/identity-schema.md section 1) under which cross-schema FKs
# don't apply the same way same-schema FKs do. tenant scoping is enforced at the
# service/repository boundary (per adp-04's own repository contract), not via a SQL
# FK, so nothing needs reworking when tenant tables eventually move behind
# per-tenant schema prefixes.
#
# The (external_realm, external_id) unique index is PARTIAL (WHERE external_id IS
# NOT NULL), per REQ-015's own acceptance criterion and matching the NULL-safe form
# adp-04a's "Unique index semantics" section recommends. This is not needed to avoid
# NULL-collisions -- Postgres unique indexes already treat each NULL as distinct, so
# a plain index would not falsely collide internal users (external_id = NULL). The
# partial predicate instead scopes the index to exactly the rows adp-04a's
# repository contract queries by (non-null external_id), avoiding an index entry for
# every row that will never be looked up by this key.
#
# NO DB CHECK constraint enforces auth_source-vs-external-fields consistency
# (adp-04a's rule 2). This is an application-level (changeset) invariant --
# implemented in REQ-018/REQ-019, not this migration.
```

### 2.3 `groups`

PROVENANCE (historical, not current decision authority):
Source: REQ-015's description ("if no groups table exists yet in Letflow, add a
minimal groups table too: id, tenant_id, name — `src/identity/role_registry.zig`'s
`upsertRole` checks group existence before writing"); adp-04's `Group` struct
(`group_id`, `tenant_id`, `name`, `created_at_us`) as the shape precedent, since adp-04
already defines a `Group` type for the same purpose even though its own migration scope
doesn't add the table (adp-04's `Group`/`GroupMembership` types exist for group-task
claim authorization, a related but distinct concern REQ-015 doesn't need to build the
full membership model for — only enough for `tenant_role.group_id` to reference).

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `:binary_id` | `primary_key: true` | Decision A |
| `tenant_id` | `:binary_id` | `null: false` | Decision B intra-schema column, same no-DB-FK rationale as `users.tenant_id` (§2.2) |
| `name` | `:string` | `null: false` | adp-04's `Group.name` |
| — | | | `inserted_at`/`updated_at` via `timestamps()` — adp-04's `Group.created_at_us` maps to `inserted_at`; REQ-015 doesn't call for `updated_at` specifically but `timestamps()` is this project's established default (matches `approvals`) and costs nothing to include |

Indexes:
- `create index(:groups, [:tenant_id])` — REQ-015 doesn't spell out an index for
  `groups` explicitly (it's the "minimal" table), but every other tenant-scoped table
  in this batch gets a `tenant_id`-leading index per the established convention
  (`backend_developer_guide.md` §3.7: "an index on the foreign-key-like column"); a bare
  `tenant_id` index is the minimal form consistent with that convention without
  over-building past what REQ-015 asks for.

No uniqueness constraint on `(tenant_id, name)` — REQ-015's description doesn't ask for
one, and adp-04 doesn't specify group-name uniqueness. **Open question, not silently
resolved:** should group names be unique per tenant? Not decided here — flag for
REQ-020 (role registry, which is the first consumer of `groups` existence-checking) to
decide when it writes `upsert_role`'s group-existence check, since REQ-020 is where
group lookups actually happen.

PROVENANCE (historical, not current decision authority):
**Required migration file header comment (ELIXIR-DEV: copy verbatim):**

```
# Letflow.Repo.Migrations.CreateGroups
#
# Minimal groups table added per REQ-015's own description (no pre-existing groups
# table in Letflow) -- shape precedent is R-Co src/design/adp-04-user-tenant-binding.md's
# Group struct (group_id, tenant_id, name, created_at_us), scoped down to exactly
# what REQ-015 (tenant_role.group_id's FK target) and REQ-020 (role_registry.zig's
# upsertRole group-existence check) need. Full group-membership modeling
# (adp-04's GroupMembership, group-task claim authorization) is explicitly out of
# scope for this migration.
#
# tenant_id has NO database-level foreign-key reference to tenants.id, same
# rationale as users.tenant_id -- see the users migration's header comment and
# lib/letflow/design/identity-schema.md section 1/2.2.
```

### 2.4 `tenant_role`

PROVENANCE (historical, not current decision authority):
Source: REQ-015's description ("tenant_role: id (binary_id), name (unique per tenant
schema), group_id (binary_id, references groups), inserted_at ... Schema module should
expose the same shape as `src/identity/role_registry.zig`'s `TenantRoleStore` will need
in REQ-020 (list, upsert-by-name)").

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `:binary_id` | `primary_key: true` | Decision A |
| `name` | `:string` | `null: false` | "unique per tenant schema" — under §1's single-default-schema deferral, this becomes a plain global unique index for now (see below); once the deferred multi-schema mechanism lands, per-schema physical isolation makes a *global* unique index automatically equivalent to "unique per tenant schema" (each schema has its own copy of the table and its own index), so no index rework is needed at that point either — the constraint's meaning is unaffected by the deferral |
| `group_id` | `:binary_id` | `null: false` | references `groups.id` — **this FK IS added at the DB level** (see rationale below) |
| — | | | `inserted_at` only, no `updated_at` — REQ-015's description lists only `inserted_at` for this table, matching `transition_events`' precedent of `timestamps(updated_at: false)` for an insert-oriented table. Note: `tenant_role` is not append-only/event-sourced like `transition_events` (REQ-020's `upsert_role` does update the `group_id` binding), so this is a description-driven choice, not a Decision-C append-only classification — REQ-020 will need `Repo.update/1` or an upsert `on_conflict:` clause on `group_id`/`name` even without an `updated_at` column tracking it. **Open question, not silently resolved:** should `tenant_role` also get `updated_at`? REQ-015's description explicitly lists only `id, name, group_id, inserted_at` — this design follows that literally rather than adding a field the requirement didn't ask for, but flags it since REQ-020's upsert-by-name will change `group_id` without a timestamp recording when. If REQ-020 needs it, add `updated_at` there rather than assuming its absence is permanent. |

**Why `tenant_role.group_id` DOES get a DB-level FK to `groups.id`, unlike
`users.tenant_id`/`groups.tenant_id` to `tenants.id`:** `tenant_role` and `groups` are
both intra-schema siblings that will live in the *same* tenant schema together once the
deferred multi-schema mechanism lands (both are tenant-owned, per-tenant data) — a
`group_id` FK between them stays valid and never needs to be dropped when that mechanism
ships, unlike a `tenant_id` FK pointing at the separate, schema-external `tenants` table
(which under a fully-realized Decision B would live in `public`, outside any given
tenant's own schema). This distinction is worth stating explicitly in the moduledoc so
ELIXIR-DEV doesn't over-generalize "no FKs in this batch" from the `users`/`groups`
case.

Indexes:
- `create unique_index(:tenant_role, [:name])` — see the `name` column note above for
  why global-for-now correctly stands in for "unique per tenant schema" under the §1
  deferral.
- `create index(:tenant_role, [:group_id])` — FK-like column, per the established
  convention.

PROVENANCE (historical, not current decision authority):
**Required migration file header comment (ELIXIR-DEV: copy verbatim):**

```
# Letflow.Repo.Migrations.CreateTenantRole
#
# Ported from REQ-015's own description, shaped to match
# src/identity/role_registry.zig's TenantRoleStore (list_roles, upsert_role),
# which REQ-020 implements against this table.
#
# name's uniqueness is enforced as a plain global unique index for now, standing
# in for "unique per tenant schema" under the single-default-schema deferral (see
# lib/letflow/design/identity-schema.md section 1). Once per-tenant schema
# provisioning lands, each tenant schema carries its own physical copy of this
# table and this same index, which then means unique-per-tenant-schema
# automatically -- no index rework needed at that point.
#
# group_id DOES carry a database-level foreign-key reference to groups.id, unlike
# users.tenant_id/groups.tenant_id's deliberate omission of a tenants.id FK --
# tenant_role and groups are both per-tenant-owned tables that will live in the
# same tenant schema together once schema-per-tenant provisioning lands, so this
# FK stays valid across that future change and never needs to be dropped.
```

## 3. Ecto.Schema modules (`lib/letflow/`)

Match `Letflow.RowApproval.Approval`'s style: `@primary_key {:id, :binary_id,
autogenerate: true}`, plain `use Ecto.Schema`, `@moduledoc` citing the R-Co source.
File placement follows the project's existing pattern of a context-ish subdirectory
per concern (`row_approval/`, `events/`) — this batch introduces the identity concern,
so schemas live under `lib/letflow/identity/` (REQ-018's description already names the
consuming context module `Letflow.Identity`, so this placement anticipates that
context module's directory without creating it — only the four schema files below are
in this requirement's scope).

### 3.1 `Letflow.Identity.Tenant` — `lib/letflow/identity/tenant.ex`

```
@moduledoc cites: R-Co src/design/adp-04b-tenant-realm-binding.md
```

Fields:
| Field | Ecto type | Notes |
|---|---|---|
| `slug` | `:string` | |
| `display_name` | `:string` | |
| `status` | `Ecto.Enum, values: [:active, :migrating]` | default `:active` |
| `idp_realm_id` | `:string` | nullable |
| (timestamps) | — | **not added** — REQ-015's column list for `tenants` (per its own description bullet) doesn't include `inserted_at`/`updated_at` for this table; only `users` explicitly lists them. This is a description-driven omission, not an oversight — flag as an open question below. |

**Open question, not silently resolved:** should `tenants` have `timestamps()`? adp-04b's
`Tenant` Zig struct has `created_at_us: i64` (a creation timestamp), and every other
table in this project's existing convention (`approvals`, `transition_events`) has at
least `inserted_at`. REQ-015's own description bullet for `tenants` lists `id, slug,
display_name, status, idp_realm_id` and does not mention a timestamp column, unlike its
`users` bullet which explicitly lists `inserted_at/updated_at`. This design follows the
literal REQ-015 text (no timestamps column on `tenants`) rather than assuming
adp-04b's `created_at_us` must be ported — but this looks like it may be an
unintentional omission in REQ-015's own text rather than a deliberate choice, given
every sibling table gets at least `inserted_at`. **ELIXIR-DEV should add
`timestamps()` to `tenants` anyway** (matching `approvals`/`groups`/every other table
in this batch, and adp-04b's own `created_at_us` field) **unless CODE-DESIGN-VALIDATOR
or REVIEWER flags a specific reason not to** — the acceptance criteria don't prohibit
an extra column, and consistency with the rest of this batch outweighs a literal
reading of one incomplete-looking bullet list. Stating this explicitly here rather than
silently picking one, per this role's own constraint on open questions.

No changeset function signature is specified for `tenants` in this requirement — REQ-019
owns tenant create/update changesets (per REQ-015's description: "the migration
moduledoc explicitly states whether... "; REQ-019's own description covers realm-binding
changesets specifically). This design does not invent one.

### 3.2 `Letflow.Identity.User` — `lib/letflow/identity/user.ex`

```
@moduledoc cites: R-Co src/design/adp-04-user-tenant-binding.md and
src/design/adp-04a-external-identity-linkage-user.md. Moduledoc must also state (per
REQ-015's acceptance criteria) that auth_source-vs-external-fields consistency is an
application-level (changeset) invariant, implemented in REQ-018/REQ-019, not enforced
by this schema module or its migration.
```

Fields:
| Field | Ecto type | Notes |
|---|---|---|
| `tenant_id` | `:binary_id` | required (`null: false` at migration level; changeset-level `validate_required` is REQ-018/019's concern, not specified here) |
| `username` | `:string` | |
| `display_name` | `:string` | |
| `email` | `:string` | |
| `password_hash` | `:string` | |
| `status` | `Ecto.Enum, values: [:active, :inactive]` | default `:active` |
| `auth_source` | `Ecto.Enum, values: [:internal, :oidc]` | default `:internal` |
| `external_id` | `:string` | nullable |
| `external_realm` | `:string` | nullable |
| (timestamps) | `timestamps()` | per REQ-015's explicit `inserted_at/updated_at` mention for `users` |

No changeset function signature is specified for `User` in this requirement — REQ-018
(JIT provisioning upsert) and REQ-019 (tenant-scoped user operations) own the actual
changeset functions and their validation logic (including the auth_source-vs-external
consistency rule this moduledoc must merely *note*, not implement). This design
deliberately does not name a `changeset/2` signature here, since REQ-015's own
description defers that implementation explicitly to REQ-018/019 — inventing a
signature now risks REQ-018/019 either duplicating it differently or treating an
unowned guess as binding.

### 3.3 `Letflow.Identity.Group` — `lib/letflow/identity/group.ex`

```
@moduledoc cites: R-Co src/design/adp-04-user-tenant-binding.md (Group struct), and
states this is a minimal table added by REQ-015 itself (no prior R-Co migration
file to cite directly, since group full modeling is out of this requirement's scope).
```

Fields:
| Field | Ecto type | Notes |
|---|---|---|
| `tenant_id` | `:binary_id` | required |
| `name` | `:string` | |
| (timestamps) | `timestamps()` | see §2.3 — included per this project's default even though REQ-015's description only lists `id, tenant_id, name` for the minimal groups table; same reasoning as the `tenants` timestamps open question in §3.1, but here the migration section (§2.3) already commits to including it since costs nothing and matches convention — flagging again here for visibility since it's the same category of "requirement text under-specifies, convention fills the gap" choice |

No changeset signature specified — no requirement in this batch (REQ-015 through
REQ-021) owns `groups` CRUD; it exists solely as `tenant_role.group_id`'s and REQ-020's
existence-check target. A future requirement (not yet drafted) owns group management
proper.

PROVENANCE (historical, not current decision authority):
### 3.4 `Letflow.Identity.TenantRole` — `lib/letflow/identity/tenant_role.ex`

```
@moduledoc cites: R-Co src/identity/role_registry.zig (TenantRoleStore) as the
consumer this schema's shape is built for (REQ-020 implements list_roles/upsert_role
against this schema). States that group_id carries a database-level foreign key to
groups.id (unlike tenant_id's deliberate omission of a tenants.id FK elsewhere in
this batch — see the migration's own header comment for the full reasoning).
```

Fields:
| Field | Ecto type | Notes |
|---|---|---|
| `name` | `:string` | unique (see §2.4) |
| `group_id` | `:binary_id` | required; FK to `groups.id` |
| (timestamps) | `timestamps(updated_at: false)` | per REQ-015's explicit `inserted_at`-only mention for this table |

**Function signatures anticipated for REQ-020 (named here only so ELIXIR-DEV building
REQ-015 doesn't accidentally foreclose them — REQ-020 owns the actual implementation,
this is not this requirement's deliverable):**
- `list_roles/0 :: [%TenantRole{}]` (or `/1` taking a `Repo`-equivalent, TBD by REQ-020)
- `upsert_role/2 :: (name :: String.t(), group_id :: Ecto.UUID.t()) :: {:ok, %TenantRole{}} | {:error, Ecto.Changeset.t()}`
- `resolve_role_in_tx/2 :: (name :: String.t(), ...) :: %TenantRole{} | nil` (never raises, per
  REQ-020's acceptance criteria — error-swallowing lookup)

These are REQ-020's contract to finalize, not REQ-015's — listed here purely so this
schema's field shape is legible against its known future consumer, per this role's
instruction to give ELIXIR-DEV enough detail without inventing unowned implementation.

## 4. Cross-module dependencies

- `Letflow.Identity.TenantRole.group_id` → `Letflow.Identity.Group.id` (DB-level FK,
  §2.4).
- `Letflow.Identity.User.tenant_id`, `Letflow.Identity.Group.tenant_id` → conceptually
  scope to `Letflow.Identity.Tenant.id`, but with NO DB-level FK (§2.2/§2.3) — enforced
  at the future service/repository boundary (REQ-018/019/020's context functions), per
  adp-04's own repository contract, not by this schema layer.
- REQ-016 (OIDC dependency wiring) — no dependency on this requirement's schema per its
  own description ("shares no module or config table with it").
- REQ-017 (claim mapping) — no dependency (pure function, no I/O).
- REQ-018, REQ-019, REQ-020 — all directly consume these four schemas; `depends_on:
  [REQ-015, ...]` already reflects this in `docs/requirements.yaml`.
- REQ-021 — indirectly consumes via REQ-018/019/020, no direct schema dependency.

## 5. Invariants this design establishes (for REVIEWER/ELIXIR-DEV to hold)

1. `users.external_realm`/`external_id` uniqueness is enforced via a **partial** index,
   never a plain unique constraint (REQ-015 acceptance criterion — verified explicitly
   in §2.2).
2. No DB CHECK constraint anywhere in this batch encodes
   auth_source-vs-external-fields consistency or idp_realm_id-required-for-non-default
   (both REQ-015 acceptance criteria — verified explicitly in §2.1/§2.2's "no CHECK"
   notes).
3. `tenant_id` columns (`users`, `groups`) carry no DB-level FK to `tenants.id` —
   deliberate, tied to the §1 schema-per-tenant deferral (§2.2's rationale block).
   `tenant_role.group_id` DOES carry a DB-level FK to `groups.id` — the two cases are
   not symmetric, and the distinction must survive into the actual migration files'
   comments (§2.4's rationale block) so a future contributor doesn't "fix" one to match
   the other.
4. All four tables target Ecto's default schema — no `prefix:` option anywhere in this
   batch's migrations or schema modules (§1).

## 6. Acceptance-criteria traceability

| REQ-015 acceptance criterion | Concrete design element |
|---|---|
| "priv/repo/migrations gains migrations for tenants, users, groups, and tenant_role, all applying cleanly via mix ecto.migrate" | §2, four migration files specified with exact column/index shape, ordered to satisfy the `groups`-before-`tenant_role` FK dependency |
| "corresponding lib/letflow/ Ecto.Schema modules exist for all four tables with @moduledoc citing the R-Co adp-04/04a/04b design doc each table's shape is ported from" | §3, four schema modules specified, each with its required `@moduledoc` citation named explicitly (`groups` cites adp-04's `Group` struct as shape precedent even though it's not a 1:1 ported table, per §3.3's own note) |
| "the migration moduledoc explicitly states whether Ecto :prefix/schema-per-tenant provisioning is built in this requirement or deferred, per this requirement's own description" | §1 (decision + reasoning) plus §2's four required verbatim header-comment blocks, each restating the deferral |
| "users has a partial unique index on (external_realm, external_id) WHERE external_id IS NOT NULL, not a plain unique constraint" | §2.2, index list, second bullet — exact `where:` clause specified |
| "no DB-level CHECK constraint enforces auth_source-vs-external-fields consistency; the schema moduledoc states this is deferred to application-level changesets" | §2.2's "No DB CHECK constraint..." paragraph plus §3.2's required moduledoc content note |

## 7. Open questions (explicit, not silently resolved)

1. **`tenants` and `groups` timestamps** — REQ-015's description text lists no
   timestamp column for `tenants`, and only `id, tenant_id, name` for `groups`, while
   every sibling table in this batch and in the existing codebase (`approvals`,
   `transition_events`) has at least `inserted_at`. §3.1/§3.3 recommend ELIXIR-DEV add
   `timestamps()` to both anyway for consistency, but flag this as a literal-reading
   deviation from REQ-015's own bulleted column list rather than silently picking one
   without saying so.
2. **`tenant_role` uniqueness-per-tenant-schema, realized today as a global unique
   index** — correct under the §1 deferral (each future per-tenant schema will carry
   its own copy of the index once multi-schema provisioning lands), but explicitly
   flagged in §2.4 so a later reader doesn't mistake "global unique index" for a
   permanent design choice independent of the deferral.
3. **`groups` name uniqueness per tenant** — not specified by REQ-015 or adp-04;
   left undecided in §2.3, explicitly deferred to REQ-020 (the first real consumer of
   group lookups) to decide when it implements `upsert_role`'s group-existence check.
4. **`tenant_role.updated_at`** — REQ-015's description lists only `inserted_at`; §2.4
   follows that literally but flags that REQ-020's `upsert_role` will mutate
   `group_id` without a timestamp recording when, in case REQ-020 wants to add it.
5. **Follow-up requirement for real schema-per-tenant provisioning** — not filed as a
   formal `docs/issues/` entry by this design step (design artefacts don't file issues;
   that's this handoff's next-routing concern), but named explicitly in §1 as
   something REQ-ANALYST should register when S2's requirements are expanded, with a
   concrete shape (`tenant_schemas` registry, provisioning function, migration-replay
   mechanism) already sketched so it isn't re-derived from scratch later.
