# 0003 — Ecto schema/migration strategy

Status: decided (REQ-012). Owner: ELIXIR-DEV.

## Question

R-Co has 146 Postgres migrations under `migrations/`. Does Letflow port
the existing SQL schema as Ecto migrations 1:1 (preserving
table/column names for easier cross-referencing during the port), or
redesign it Ecto-idiomatically? How is multi-tenancy represented at
the schema level? R-Co's own tenant-modeling design is documented in
its `src/design/`:

- `adp-01-tenant-column-event-store.md`
- `adp-02-tenant-columns-definition-instance-audit.md`
- `adp-03-tenant-context-resolution-api.md`
- `adp-04-user-tenant-binding.md`
- `adp-04a-external-identity-linkage-user.md`
- `adp-04b-tenant-realm-binding.md`

Read these before deciding whether Letflow adopts R-Co's tenant-column
approach or diverges from it.

## Decision

Letflow makes three separate decisions, corresponding to the three dimensions this
requirement scopes:

**A — Schema shape: Ecto-idiomatic redesign, not a 1:1 port.** Letflow redesigns the
schema using Ecto's own conventions (`binary_id` primary keys, `Ecto.Enum` for
status-like columns, one schema-defining concern per migration via the `Ecto.Migration`
DSL) rather than porting R-Co's raw-SQL migration files verbatim. Table and column
*names* are preserved where they carry meaning (`process_definitions`,
`instance_projections`, `tokens`, `audit_entries`, `tasks`, ...) for cross-referencing
during the port, but the migration *files themselves* are not a 1:1 copy of R-Co's 146.

**B — Multi-tenancy representation: schema-per-tenant, following R-Co's actual current
implementation — not the adp-0x docs' tenant-column-only description taken in
isolation.** Letflow adopts Postgres schema-per-tenant as the tenant-isolation
mechanism, implemented via Ecto's `:prefix` / dynamic-repo query-prefixing support,
**with `tenant_id` columns retained inside each schema** on the tables the adp-0x docs
describe, kept as an intra-schema invariant/query-predicate discipline rather than as
the isolation boundary itself. This explicitly follows R-Co's actual, current,
two-layer implementation (schema-per-tenant + intra-schema `tenant_id`), not the
adp-0x docs' original, now-superseded tenant-column-only proposal.

**C — Event-store tables get their own migration/schema strategy, distinct from
regular CRUD tables**, on three points: (1) no update-path is exposed for event tables
at the schema/module level — they are modeled as insert-only, (2) partitioning is
deferred, not built in from the start, matching R-Co's own history, but the
primary-key shape and a dedicated idempotency mechanism are chosen up front so the
future partitioning retrofit doesn't force a breaking primary-key change later, and (3)
derived/projection tables (`instance_projections`-equivalent) are migrated with the
same DSL as regular CRUD tables — their rebuildable-from-the-event-log property is a
runtime/application invariant, not a schema-migration concern. Event-store tables use
schema-per-tenant, the same tenant-modeling mechanism Dimension B selects for
everything else — R-Co's `PER_TENANT` classification for `events`/`events_archive` is
adopted as the general rule for all business tables under Decision B, not treated as a
special case.

## Reasoning

### Dimension A — 1:1 port vs. Ecto-idiomatic redesign

R-Co's actual migration count, verified against `C:\Users\tvolo\dev\ai-dala\R-Co\migrations\`
(`ls migrations/*.sql | wc -l`), is **146**. This requirement's own `description` and
this file's Question section originally cited a stale 143 (filed as `ISS-0004`); both
have since been corrected to 146 to match. Of those 146, 31 carry a `GBL-` prefix, meaning they operate on the global `public` schema
only and exist specifically to reconcile R-Co's own two-phase tenant-modeling history —
most concretely, `GBL-112_tnt01_drop_legacy_public_business_tables.sql`, whose own
header states migrations 001–059 created business tables in `public`, migration 060
(`SPT-01`) then added schema-per-tenant provisioning *without* dropping the original
`public` tables, and `GBL-112` is the later cleanup that drops them. That reconciliation
overhead is a byproduct of R-Co evolving its tenant model in place over time; it is not
core schema definition, and Letflow has no reason to replay it. Combined with Decision
B (Letflow starts schema-per-tenant from the first migration, never having a
tenant-column-only phase to reconcile away from), a 1:1 port of the 146 files would
mean porting historical corrective work that Letflow's own starting point makes
unnecessary — a straight argument against 1:1 porting on effort grounds alone, before
even weighing idiom.

Separately, R-Co's regular-table migration shape (sampled directly from
`004_definitions.sql` and `002_event_type_registry.sql`) mixes multiple `CREATE TABLE`
statements, indexes, and inline seed-data `INSERT`s in one hand-written SQL file per
feature slice, `TEXT`-typed status columns with comment-documented allowed values
rather than an enforced type, and `CREATE INDEX IF NOT EXISTS` idempotent-by-convention
DDL. This is a different authoring convention than Ecto's one-migration-per-concern
`Ecto.Migration` DSL, which Letflow's two existing migrations
(`20260814000001_create_transition_events.exs`,
`20260814000002_create_approvals.exs`) already follow per
`docs/guides/backend_developer_guide.md` §3.7 (`binary_id` PK, `null: false`,
`timestamps/1`, an index on the foreign-key-like column). Translating R-Co's
multi-statement raw-SQL files into that DSL is unavoidable regardless of the
naming decision, which removes "preserve the file structure for easier
cross-referencing" as an argument for 1:1 porting — the file structure isn't
preservable across the DSL boundary even if the *names* are.

Table/column **names**, however, are preserved where R-Co's naming already carries
domain meaning (`process_definitions`, `instance_projections`, `tokens`,
`audit_entries`, `audit_log`, `tasks`) — R-Co's SQL columns are already `snake_case`,
so this doesn't conflict with `backend_developer_guide.md` §3.1's Elixir naming
convention, and preserving names keeps R-Co's design docs (adp-0x, stage docs) and any
future side-by-side comparison legible without forcing a parallel renaming effort that
buys nothing. Two concrete abstraction swaps are adopted where they are drop-in
replacements with no behavior change: `UUID PRIMARY KEY DEFAULT gen_random_uuid()`
becomes Ecto's `binary_id` (same underlying Postgres type, same generation semantics),
and `TEXT`-typed status columns with a comment-documented allowed-value set become
`Ecto.Enum` fields (moves the constraint from a comment into an enforced type, which is
a strict improvement, not a behavior change). `execute/1` remains available, as it
always is in Ecto, for anything the DSL can't express directly — e.g. the `to_tsvector`
GIN full-text index seen in `004_definitions.sql`, or the tenant-schema-provisioning
function Decision B implies (see below).

### Dimension B — multi-tenancy representation

**adp-0x docs read (per acceptance criterion 2), all six, in full, this session, at
`C:\Users\tvolo\dev\ai-dala\R-Co\src\design\`:**
`adp-01-tenant-column-event-store.md`, `adp-02-tenant-columns-definition-instance-audit.md`,
`adp-03-tenant-context-resolution-api.md`, `adp-04-user-tenant-binding.md`,
`adp-04a-external-identity-linkage-user.md`, `adp-04b-tenant-realm-binding.md`.

PROVENANCE (historical, not current decision authority):
All six describe the same additive `tenant_id`-column pattern applied to different
table groups: a `tenant_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'`
column, backfilled onto existing tables with a reserved default-tenant UUID, made a
mandatory query/write predicate enforced at the service/repository boundary (never
inferred, never client-supplied per adp-03), with tenant-scoped uniqueness constraints
replacing prior global ones (e.g. adp-02's `uq_definition_version` →
`uq_definition_tenant_version (tenant_id, name, version)`) — except `events`' global
idempotency uniqueness, which adp-01 explicitly keeps global, not tenant-scoped
(ES-03). adp-04/04a/04b apply the identical pattern to identity: `users.tenant_id`,
a single-tenant-per-user-row invariant, `(tenant_id, external_realm, external_id)` as
the JIT-provisioning upsert key (independently corroborated by this project's own
`docs/migration/decisions/0002-oidc-integration.md`, already `decided`, citing the same
key from `src/identity/registry.zig`'s `createOrGetJitOidcUser`), and
`tenant.idp_realm_id`, immutable after tenant creation. None of the six adp-0x
documents mentions schema-per-tenant, a `tenant_schemas` registry, or a
provisioning function anywhere in their text.

**This is not, however, the whole of "R-Co's tenant-column approach" as it actually
exists today, and that gap is the crux of this decision.** Reading R-Co's actual
migration history (not just its design docs) this session found that R-Co's real
implementation diverged from what the adp-0x docs describe:

- Migrations 001–059 create business tables in the shared `public` schema with no
  `tenant_id` column at all (confirmed directly: `001_event_store.sql` and
  `004_definitions.sql` have no `tenant_id` column; `004_definitions.sql`'s
  `uq_definition_version` constraint is still the pre-adp-02 global form).
- The adp-01/02/04/04a/04b tenant-column additions land as later migrations in the
  sequence, confirming the tenant-column layer was implemented, not just designed.
- `060_schema_per_tenant_bootstrap.sql` (tagged `SPT-01`) then adds a **second,
  orthogonal isolation mechanism**: a `public.tenant_schemas` registry and a
  `public.bpm_provision_tenant_schema(p_tenant_id UUID)` function that provisions a
  real Postgres schema per tenant, plus a widened `schema_migrations` primary key
  (`(schema_name, version)`) to track per-schema migration application.
- `GBL-112_tnt01_drop_legacy_public_business_tables.sql` drops 19 named legacy
  `public`-schema business tables outright (guarded by a `migration_window_active`
  flag for production cutover sequencing).
PROVENANCE (historical, not current decision authority):
- `src/db/migrations.zig`'s `runForSchema` replays the migration set once per
  registered tenant schema under a `search_path` of `<schema>,public` — the
  mechanism that actually executes schema-per-tenant, confirmed directly from
  source.
- Independent, catalog-level corroboration: `iss0150-gh482-20260810-adp0x-schema-fix.md`
  documents six R-Co integration tests that broke because they queried
  `information_schema` assuming `table_schema = 'public'` for tables
  (`process_definitions`, `instance_projections`, `tasks`, `tokens`, `audit_entries`,
  `audit_log`, `users`) that actually live under `tenant_default`/per-tenant schemas
  post-`GBL-112` — proof the schema-per-tenant cutover is real and complete for these
  tables, not aspirational or partial.
- `1147_par01_events_partitioning.sql` explicitly classifies `events`/`events_archive`
  as `PER_TENANT` in R-Co's own dual-schema classification scheme, and its comments
  note `GBL-112` "already permanently dropped `public.events`/`public.events_archive`"
  — the event-store tables specifically are schema-per-tenant, not global-shared.
- The `tenant_id` columns were **not** removed when schema-per-tenant was added —
  `uq_definition_tenant_version`-style tenant-scoped constraints are still present as
  of the 2026-08-10 catalog read cited above, now scoped inside `tenant_default`
  rather than `public`. The two mechanisms coexist: schema-per-tenant is the isolation
  boundary, and `tenant_id` is retained as an intra-schema partitioning/query-predicate
  convention (useful for cross-tenant admin/reporting queries against a superuser
  connection, and because removing an established column from every business table
  purely because a second isolation layer was added is not a change R-Co's migration
  history shows it as ever having made).

Given this, three options were available, matching the framing this file's design
research laid out: (a) adopt R-Co's *original*, adp-0x-only tenant-column model,
treating the later schema-per-tenant work as something Letflow simply doesn't need to
repeat; (b) adopt R-Co's *actual, current* two-layer model (schema-per-tenant +
intra-schema `tenant_id`); (c) diverge from both, e.g. staying tenant-column-only
permanently on the theory that R-Co's schema-per-tenant addition solved a problem
Letflow won't have.

**Letflow chooses (b).** The reasoning: R-Co did not add schema-per-tenant
speculatively — migrations 060 and `GBL-112`, read together, describe a real
architectural correction (bootstrap the per-schema mechanism, then later remove the
now-legacy shared tables once the new mechanism was verified safe under a
production-cutover flag), and R-Co is the one concrete precedent this project has for
what a `tenant_id`-column-only model looks like under sustained real use — a project
that started there and moved off it. Nothing in this decision's research surfaced a
stated reason for that move (no adp-0x doc or migration header explains *why* R-Co
added schema-per-tenant on top of the column), so the specific motivating pressure
(compliance/data-residency requirements demanding physical isolation, a noisy-neighbor
performance problem, or simply stronger blast-radius containment against a
missing-`WHERE`-clause bug class) cannot be cited with the same confidence as the fact
of the move itself. Absent that specific rationale, this decision weighs the
architectural shape of the outcome rather than R-Co's original motivation: physical
schema separation gives Letflow the same blast-radius property `docs/agents/instructions/
security-invariants.md`'s tenant-isolation invariants care about — a bug that forgets a
`tenant_id` predicate in a query fails loudly (wrong schema/relation not found, or an
empty result under the connection's own `search_path`) instead of silently leaking rows
across tenants the way a forgotten `WHERE tenant_id = ...` on a shared table would.
Option (a) would mean deliberately walking back onto the weaker isolation model R-Co
itself moved away from, without a documented reason to believe Letflow's risk profile
differs from R-Co's enough to justify that. Option (c) was considered and rejected for
the same reason (a) was: it re-litigates a question R-Co's own migration history has
already answered once, without new evidence pointing the other way.

Concrete Ecto/Postgres mechanics of option (b): schema-per-tenant maps to Ecto's
`Ecto.Repo` query-`:prefix` support (`Repo.all(query, prefix: tenant_schema)`, or a
`prefix/1` callback on affected schemas) — Ecto has first-class support for
Postgres-schema-based multi-tenancy this way, materially different plumbing than a
`tenant_id` `WHERE`-clause library. This requires a migration-runner change beyond a
single `mix ecto.migrate` run: a `tenant_schemas`-equivalent registry and a
provisioning path (Ecto's own `prefix:` option on `Ecto.Migration`'s `create table`
plus a dynamic-per-tenant migration-replay step, echoing `runForSchema`) are needed at
S2/S3 execution time — this decision names the mechanism, it does not build it (out of
REQ-012's scope, per this file's own Question section and the design artefact's §7).
`tenant_id` columns remain plain Ecto fields on schemas that need the intra-schema
predicate, no different from a normal column.

For comparison, the two roads not taken: a `tenant_id`-column-on-shared-tables-only
approach is the operationally lighter option — one Postgres schema and pool for every
tenant, plain `WHERE` scoping enforced by query-composition discipline — but is exactly
the model R-Co itself found insufficient. Database-per-tenant has no precedent
anywhere in R-Co's design docs or migration history (no adp-0x doc or migration
mentions it), makes tenant provisioning the heaviest of the three options (a new
`Ecto.Repo`/connection pool per tenant, no shared-pool efficiency, materially more
operational surface for a project this early in its lifecycle), and is rejected for
lack of any R-Co precedent to reason from combined with its higher operational cost.

`docs/migration/stage-2-event-store-definitions.md` and `stage-3-instance-engine.md`
inherit this decision for their own table shapes (not edited as part of this
requirement, per this file's own scope boundary) — both should read Decision B as
"schema-per-tenant via Ecto prefix/dynamic-repo support, `tenant_id` retained
intra-schema," not "tenant_id column only," when they begin their own schema work.

### Dimension C — event-store vs. regular-table migration strategy

Event-store tables (`events`, `events_archive`, `instance_sequence`,
`instance_projections`, sampled directly from `001_event_store.sql` and
`003_event_archive.sql`) differ from regular CRUD tables (`process_definitions`,
`event_type_registry`, sampled from `004_definitions.sql` and
`002_event_type_registry.sql`) on three structural points this decision treats
separately:

1. **Append-only/immutability.** No migration sampled for `events`/`events_archive`
   exposes an `UPDATE` path, and adp-01's ES-01 invariant states immutability
   explicitly. Ecto's `changeset`-based `update/2` pattern doesn't structurally
   forbid an update the way a database-level trigger or restricted grant would — this
   is a **schema-module-design concern** (don't expose an `update_changeset/2` on the
   event schema module, don't wire an update endpoint to it), not a migration-file
   concern, since Ecto migrations don't have a "no updates" DDL primitive to reach
   for. This decision records the position for S2/S3 to build against: immutability is
   enforced at the application/context-module layer, not the migration layer.

2. **Partitioning: deferred, not built in from day one — but the future retrofit's
   known costs are designed around now.** R-Co itself started `events`/`events_archive`
   unpartitioned and only added `PARTITION BY RANGE (created_at)` later, at
   `1147_par01_events_partitioning.sql`, once row-count pressure justified it. Letflow
   follows the same order (unpartitioned first) rather than speculatively partitioning
   a table with no rows yet. However, `1147`'s retrofit forced two consequences worth
   designing around now rather than being surprised by later: (a) the primary key had
   to widen from `(event_id)` to `(event_id, created_at)`, because Postgres requires
   the partition key to be part of every unique index on a partitioned table — Letflow's
   initial event-store migration should define the primary key as `(event_id,
   created_at)` from the start, even before partitioning exists, so the future retrofit
   isn't also a primary-key-shape migration; (b) the single global `uq_event_idempotency`
   unique index could no longer enforce cross-partition global uniqueness once
   partitioned, so R-Co introduced a sidecar table (`plat_event_idempotency`) to carry
   that invariant instead. Letflow adopts the sidecar-table approach for idempotency
   from the start (not deferred to partitioning time) — it is correct and no more
   costly whether or not the table is yet partitioned, and building it later would mean
   migrating every existing idempotency-key consumer at the same time partitioning
   itself lands, compounding two changes into one migration event instead of one.

3. **Derived/projection tables get the same migration DSL as regular tables; their
   correctness invariant is a runtime concern, not a schema concern.**
   `instance_projections` is schema-shaped like an ordinary CRUD table but is
   documented as rebuildable at any time from a fold over `events` — its real
   correctness boundary is "matches a fold over the event log," which no column
   constraint can express or enforce. This decision draws the line at: migrate it with
   the same `Ecto.Migration` DSL and column-constraint discipline as any regular CRUD
   table (no special migration-file treatment), and treat the fold-consistency
   invariant as an application/test concern for S2/S3 to own (e.g. a property test
   verifying projection state matches a fold over recorded events), not something the
   migration file can or should encode.

**Tenant-modeling interaction:** event-store tables use the same schema-per-tenant
mechanism Decision B selects for every other business table — R-Co's own `PER_TENANT`
classification of `events`/`events_archive` (independently stated in `1147`'s own
comments, not derived from the general adp-0x pattern) turns out to agree with, not
diverge from, what Decision B already picks for regular tables. This decision treats
that agreement as confirmation rather than coincidence: nothing about append-only
semantics, partitioning, or the idempotency sidecar table argues for a *different*
tenant-isolation mechanism for event-store tables specifically, so Letflow does not
special-case them on that dimension. The sidecar idempotency table
(`plat_event_idempotency`-equivalent) itself is schema-per-tenant too, for the same
reason — a per-tenant physical boundary around the idempotency invariant is no weaker
than a per-tenant boundary around the events it guards, and a cross-tenant-shared
sidecar table would reintroduce exactly the shared-table blast-radius risk Decision B
rejected.

### Cross-references

- `docs/migration/decisions/0002-oidc-integration.md` (REQ-011, `decided`) independently
  corroborates the `(tenant_id, external_realm, external_id)` JIT-provisioning key and
  the immutable `tenant.idp_realm_id` binding — both consistent with, and unaffected by,
  this decision's schema-per-tenant conclusion, since neither of 0002's findings
  concerned schema/isolation mechanism.
- `docs/guides/backend_developer_guide.md` §5 ("Multi-tenancy — not decided yet") is now
  superseded by this decision for any future task reading that guide — a follow-up doc
  update (out of this file's own scope) should point §5 at this decision once REQ-012 is
  marked done.
- This decision does not include writing actual migrations, an `Ecto.Repo` `:prefix`
  wiring, or a `mix.exs` dependency change — that is S2 (event store) and S3 (instance
  engine) execution work, which inherit this strategy per their own stage docs.

## Addendum (2026-08-17) — `tenant_id` population on write

**Question left open by Dimension B:** Dimension B retains `tenant_id` columns
"as an intra-schema invariant/query-predicate discipline" but does not say who
computes the value written into them. REQ-027 shipped `process_definitions.tenant_id`
`NOT NULL` with no DB default (correctly, per Dimension B and R-Co's adp-02 mapping —
R-Co's own default comes from a session-GUC mechanism Letflow deliberately does not
have, since Dimension B chose `:prefix`-based schema-per-tenant instead of a
connection-level tenant context). CODE-DESIGNER flagged this gap during REQ-027
(`lib/letflow/design/req027-definition-core-schema.md` OQ-1) and filed it as
[ISS-0025](../../issues/ISS-0025.yaml) (GitHub #83) rather than resolving it
unilaterally, since it is a schema-population *policy* question, not a REQ-027 schema
defect — REQ-027's own five acceptance criteria are unaffected. The same gap applies
to every S2 table carrying a Decision-B `tenant_id` column that isn't populated by
REQ-027 itself: `events`/`events_archive`/`instance_projections` (REQ-023's schema,
REQ-025's writer) and `process_definitions` (REQ-027's schema, REQ-030's writer).

**Decision: the value written into a table's `tenant_id` column is derived by the
writing context module from the Postgres schema (`:prefix`) it is already writing
into for that call — never accepted as a separate, independently-trusted field from
the caller.** Concretely: `Letflow.TenantProvisioning.schema_name_for_tenant/1`
encodes `tenant_id -> "tenant_" <> hex(uuid)` deterministically; a context module
about to write a tenant-scoped row reverses that same encoding from the resolved
schema name to obtain the `tenant_id` it stamps on the row, rather than trusting a
`tenant_id` value passed in alongside (and potentially disagreeing with) the schema
it's about to write to. REQ-025 and REQ-030 (the two requirements this currently
blocks) must build/use this derivation rather than adding a plain `tenant_id` field
to their public create/append parameters.

**Reasoning — this was not an arbitrary pick among the three options ISS-0025
recorded; a security review already ranked them.** During REQ-027's own
SECURITY-REVIEWER pass (WF02-REQ027-20260816 Step 2c), the three candidates were
compared on an axis the original framing missed: attribution integrity.

- *(a) Caller supplies `tenant_id` as an explicit parameter* — rejected. It makes the
  column caller-controlled: a call writing into tenant A's schema could pass
  `tenant_id = B`, and nothing in the shipped schema rejects it (no constraint
  references `tenant_id`), so the row would physically sit in tenant A's schema while
  claiming to belong to B. That is not a tenant-isolation breach (the Postgres schema
  boundary still holds — a query scoped to tenant B's schema never sees the row), but
  it is an attribution defect, and it corrupts exactly the cross-schema
  reporting/audit use case Dimension B retains the column *for*.
- *(b) Build an R-Co-style session-GUC tenant context so a DB default fills the
  column* — rejected for this decision's purposes, not on correctness grounds but
  scope: it is a new cross-cutting mechanism touching every tenant-scoped table, and
  introducing a connection-level tenant context alongside `:prefix` is itself a
  Dimension-B-adjacent architectural choice this addendum is not the place to make
  unilaterally. Nothing rules it out for the future, but it is not needed to unblock
  REQ-025/REQ-030 today.
- *(c) Derive it from the resolved schema at write time* — **adopted**. A derived
  value cannot disagree with the schema it is written into, by construction, which
  structurally closes the attribution gap (a) leaves open, at no cost beyond a small
  pure reverse-mapping function next to `schema_name_for_tenant/1`. The tradeoff
  noted at the time — it couples the writing context module to REQ-022's
  `"tenant_" <> hex` naming convention — is accepted: that convention is
  `Letflow.TenantProvisioning`'s own public encoding (`schema_name_for_tenant/1`),
  not a private implementation detail, so depending on it is depending on a stable
  contract, not reaching into internals.

Also recorded because it cuts the other way and matters for anyone re-litigating this:
the currently-shipped `NOT NULL`-no-default column is strictly *safer* than R-Co's own
arrangement even before this addendum, because an insert that omits `tenant_id`
produces a loud `not_null_violation` rather than R-Co's session-GUC default silently
stamping whatever tenant UUID the connection last had. This addendum improves
attribution integrity further; it was not fixing a silent-corruption bug.

**Scope:** this addendum settles the *population mechanism* only. It does not revisit
Dimension B's choice of `:prefix`-based schema-per-tenant, and it does not build
session-GUC tenant context (option (b)) — a future requirement remains free to add
that mechanism later for other reasons without contradicting this addendum, since (b)
was deferred on scope grounds, not ruled out as wrong.
