# Design: REQ-012 — decision-record research (0003-ecto-schema-strategy.md)

**Requirement:** REQ-012 (`docs/requirements.yaml`)
**Target artefact ELIXIR-DEV writes into:** `docs/migration/decisions/0003-ecto-schema-strategy.md`
  (Decision + Reasoning sections only — the Question section already exists, do not
  rewrite it)

## What kind of "design" this is

REQ-012 produces a decision record, not application code or actual migrations.
REQ-012's own `description` states explicitly: "Do not write actual migrations yet —
this is the strategy doc S2/S3 requirements will follow." There is no Ecto schema,
`gen_statem` shape, or DB migration in scope here. This document is the structured,
source-verified research ELIXIR-DEV needs so that writing the Decision/Reasoning
sections is transcription against a settled comparison, not open-ended research done
under a content-writing task — matching the precedent set by
`lib/letflow/design/0001-web-framework-decision.md` (REQ-010) and
`lib/letflow/design/0002-oidc-integration-decision.md` (REQ-011).
CODE-DESIGN-VALIDATOR should treat "every acceptance criterion maps to a concrete
design element" as: every acceptance criterion below has a resolved (not "TBD") answer
in this document.

## 1. Ground truth on R-Co's actual `src/design/adp-0x` docs (read directly this session)

All six files REQ-012's `description` and the skeleton's Question section name are
confirmed to exist at `C:\Users\tvolo\dev\ai-dala\R-Co\src\design\` under exactly the
filenames cited — no misattribution this time (unlike REQ-010's route count or
REQ-011's JIT-provisioning file, both wrong in their respective skeletons). Read in
full:

### 1.1 `adp-01-tenant-column-event-store.md`

Defines `tenant_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'`
(reserved default-tenant UUID) as an **additive** column on `events` and
`events_archive`, plus four new tenant-aware indexes
(`idx_events_tenant_instance_seq`, `idx_events_tenant_global_seq`, and the archive
equivalents), while preserving every existing ES-01..ES-06 invariant (immutability,
per-instance ordering, global idempotency-key uniqueness *not* relaxed to per-tenant,
tenant-scoped global stream). Storage entry points (`appendEvent`,
`readInstanceOrdered`, `readGlobalTenantStream`, `readPointInTime`) all require
`tenant_id` explicitly — no inference. Compatibility rule: requests without a
`tenant_id` claim resolve to the default-tenant UUID, so legacy/pre-migration data and
callers keep working unchanged.

### 1.2 `adp-02-tenant-columns-definition-instance-audit.md`

Extends the same additive `tenant_id` pattern to `process_definitions`,
`instance_projections`, `tasks`, `tokens` (the transition/token carrier — the doc's own
"Open questions" §1 notes the requirement text says "transition table" but the actual
schema object is `tokens`), `audit_entries`, and `audit_log`. States the migration
strategy explicitly under its own "Strategy decision" heading: `NOT NULL + DEFAULT
default-tenant UUID`, ordered as (1) add column with default, (2) verify zero nulls,
(3) add tenant-aware indexes, (4) add tenant-aware uniqueness constraints while
temporarily keeping old ones, (5) drop superseded global-uniqueness indexes only after
tenant-aware code is deployed and verified. Uniqueness constraints are rewritten to be
tenant-scoped (e.g. `uq_definition_version (name, version)` →
`uq_definition_tenant_version (tenant_id, name, version)`).

### 1.3 `adp-03-tenant-context-resolution-api.md`

API/middleware-layer document: defines how `tenant_id` is resolved from a bearer
token's optional `tenant_id` claim (present → use it; absent → default tenant;
malformed → reject before any storage call) and propagated through
`ServiceRequestContext`/repository calls. Out of scope for REQ-012's schema question
directly (it's API/middleware, not schema), but it is the contract adp-01/adp-02 assume
supplies `tenant_id` to every storage call — i.e. it confirms the tenant-column
approach is enforced end-to-end, not just at the DB layer.

### 1.4 `adp-04-user-tenant-binding.md`

Same additive pattern applied to `users`: `tenant_id UUID NOT NULL DEFAULT
'00000000-...'`, single-tenant-per-user-row invariant (a human needing multi-tenant
access gets multiple user rows, one per tenant), tenant-aware index
(`idx_users_tenant_status_created`), and an explicit note that this "keeps Stage 6.5
tenant isolation behavior consistent across identity and non-identity tables" —
i.e. adp-04 is explicitly framed as the same ADP-02 pattern applied to identity.

### 1.5 `adp-04a-external-identity-linkage-user.md`

Adds `external_id`, `external_realm`, `auth_source` to `users` for OIDC linkage. This
is the design doc REQ-011's now-`done` decision record (`0002-oidc-integration.md`)
already cross-referenced concretely: its Reasoning cites `createOrGetJitOidcUser` as
"an idempotent upsert keyed on `(tenant_id, external_realm, external_id)`." adp-04a's
own "Repository boundary contracts" confirm this three-part key is enforced at the
query level ("all external-identity queries must include `tenant_id` predicate in
addition to `(external_realm, external_id)`") and its "Cross-tenant collision
boundaries" §3 states provisioning is rejected if the token's tenant context doesn't
match the tenant bound to `external_realm` — a concrete, already-verified example of
`tenant_id` as a mandatory query predicate on a real R-Co table.

### 1.6 `adp-04b-tenant-realm-binding.md`

Adds `tenant.idp_realm_id TEXT NULL` with a one-to-one tenant↔realm invariant
(OIDC-12), default tenant pinned to `idp_realm_id = 'bpm-default'`, immutable after
creation for non-default tenants under OIDC-enabled mode. This is precisely the
`tenant.idp_realm_id` column REQ-011's finished decision record's Reasoning already
described as "immutable after tenant creation" — confirmed here directly from its
owning design doc rather than only from 0002's secondhand citation.

**Summary of what all six actually say:** every one of the six adp-0x docs describes
the **same additive `tenant_id`-column pattern** (adp-02 explicitly names it "the same
additive storage pattern defined by ADP-02" when applied to users in adp-04) — a
default-tenant UUID (`00000000-0000-0000-0000-000000000000`) backfills existing rows,
`tenant_id` becomes a mandatory query/write predicate enforced at the
service/repository boundary (never inferred, never client-supplied), and legacy
callers without tenant context transparently fall back to the default tenant. None of
the six describes schema-per-tenant or database-per-tenant at the design-document
level — that only appears later, at the actual-migration level (see §2 below), which
is a real tension the Reasoning section must address, not paper over.

## 2. Ground truth on R-Co's actual `migrations/` directory (verified this session, not trusted from any prior written source)

### 2.1 The migration count is 146, not 143

`ls migrations/*.sql | wc -l` against `C:\Users\tvolo\dev\ai-dala\R-Co\migrations\`
returns **146** files, not the 143 REQ-012's `description` and the skeleton's Question
section both cite. This is the same class of stale-count discrepancy REQ-010's design
found for R-Co's route count (22 written vs. 24 actual) and REQ-011's design implicitly
worked around for the JIT-provisioning file path — **verify against disk, don't
transcribe a written number.**

Breakdown of the 146:
- 78 files with a plain three-digit numeric prefix (`001_event_store.sql` ...
  `069_retroactive_tenant_schema_provision.sql`, then continuing into four-digit
  prefixes up to `1162_plc01_module_id_unique_per_tenant.sql`).
- 31 files with a `GBL-` prefix (`GBL-073_...` through `GBL-142_...`) — these are
  **not** ordinary per-tenant-replayed migrations; per `GBL-112`'s own header comment,
  the `GBL-` prefix marks a file as operating on the global `public` schema only and
  being exempt from a lint rule (`lint_migration_schema.py`) that otherwise forbids
  non-`GBL` files from referencing `public.<business_table>`.
- The remainder are four-digit-numbered files without a `GBL-` prefix, continuing the
  same per-tenant-replayed numbering scheme into the 1100s (e.g.
  `1147_par01_events_partitioning.sql`).
- Numeric prefixes are **not globally unique**: `050_tenant_hostnames.sql` and
  `050_xc01_trace_id_audit.sql` share prefix 050; `056_onboarding_registry.sql` and
  `056_xc03_configuration_repository_fix.sql` share 056; `1139` and `1154` are each
  used twice as well. R-Co's migration runner evidently orders by full filename, not
  purely by numeric prefix, since prefixes alone don't disambiguate.

**Resolution ELIXIR-DEV must apply, not re-derive:** cite **146** as the actual
migration count (not 143). Recommend filing this as a new `docs/issues/ISS-NNNN.yaml`
entry (see §6) so `docs/requirements.yaml`'s REQ-012 `description` and the skeleton's
Question section get corrected in their own right — do not silently edit either as a
side effect of this design or of writing the Decision/Reasoning sections (same file-
scope boundary REQ-010's and REQ-011's designs drew for their own count corrections).

### 2.2 The real, load-bearing finding: R-Co's schema strategy evolved past what the adp-0x docs alone describe — it is now schema-per-tenant, with `tenant_id` columns retained inside each schema

This is the single most important ground-truth finding this design surfaces, and it
directly affects how the Reasoning section must frame Dimension 2 (tenant-modeling).
The adp-0x docs (§1 above) describe a **pure `tenant_id`-column-in-one-shared-schema**
model. Reading the actual migration timeline shows R-Co did not stop there:

1. **Migrations 001–059** create business tables (`events`, `process_definitions`,
   `instance_projections`, `tasks`, `tokens`, `audit_entries`, `audit_log`, `users`,
   ...) directly in the `public` schema, with no `tenant_id` column yet (verified by
   reading `001_event_store.sql` and `004_definitions.sql` in full — neither has a
   `tenant_id` column; `004_definitions.sql`'s `uq_definition_version` constraint is
   still the pre-adp-02 global `UNIQUE (name, version)`, exactly matching the
   "current schema" adp-02 describes itself as extending).
2. **adp-01/02/04/04a/04b's `tenant_id`-column additions** land as migrations later in
   the numeric sequence (e.g. the tenant-scoped index/constraint names adp-02
   specifies, like `uq_definition_tenant_version`, appear in later migration files, not
   in `004_definitions.sql` itself) — this is the tenant-column layer §1 describes,
   confirmed as an actual migration event, not just a design-doc proposal.
3. **Migration `060_schema_per_tenant_bootstrap.sql`** (tagged `SPT-01` in its own
   header, read in full this session) introduces a **second, orthogonal** isolation
   mechanism on top of the tenant-column layer: a `public.tenant_schemas` registry
   table, and a `public.bpm_provision_tenant_schema(p_tenant_id UUID)` function that
   `CREATE SCHEMA IF NOT EXISTS`s a real Postgres schema per tenant (named
   `tenant_<uuid-no-dashes>`, or `tenant_default` for the reserved default-tenant UUID)
   and registers it. It also widens `public.schema_migrations`'s primary key from
   `(version)` to `(schema_name, version)` so the same migration file's version can be
   tracked as applied independently per tenant schema.
4. **`GBL-112_tnt01_drop_legacy_public_business_tables.sql`** (read in full this
   session; its own header says migrations 001–059 created business tables in `public`
   and migration 060 added schema-per-tenant provisioning "but did NOT drop the legacy
   public tables" — this GBL migration is the cleanup) then `DROP TABLE IF EXISTS
   CASCADE`s 19 named legacy public business tables, including
   `public.audit_entries`, `public.audit_log`, `public.event_retention_policies`,
   `public.event_type_registry`, `public.webhook_subscriptions`, `public.api_tokens`,
   guarded by a `migration_window_active` flag so production cutovers can defer the
   drop.
PROVENANCE (historical, not current decision authority):
5. **`src/db/migrations.zig`'s `runForSchema`** (module doc-comment: "SPT-01: extended
   with `runForSchema` to support schema-per-tenant migrations") is the mechanism that
   replays the same migration file set once per registered tenant schema, under a
   `search_path` of `<schema>,public` — confirmed directly from source, and
   independently corroborated by `iss0150-gh482-20260810-adp0x-schema-fix.md` (read in
   full this session), which found six R-Co integration tests broken because they
   queried `information_schema` for `table_schema = 'public'` on tables
   (`process_definitions`, `instance_projections`, `tasks`, `tokens`, `audit_entries`,
   `audit_log`, `users`) that actually live under `tenant_default`/per-tenant schemas
   post-GBL-112, not `public` — direct catalog-query evidence (§3 of that doc) that the
   schema-per-tenant cutover is real and complete for these tables, not aspirational.
6. **`1147_par01_events_partitioning.sql`** (read in full this session) confirms
   `events`/`events_archive` are explicitly classified `PER_TENANT` in R-Co's own
   "dual-schema classification" scheme (the file's own comments cite
   `docs/anti-patterns.md`'s classification and note `GBL-112` "already permanently
   dropped `public.events`/`public.events_archive`" as part of that classification) —
   i.e. the event-store tables specifically are per-tenant-schema, not global-shared,
   as of the current migration history.

**What this means for Dimension 2 of the eventual Decision:** R-Co's tenant-modeling
approach is not simply "tenant_id column" as the adp-0x docs alone would suggest if
read in isolation — it is **schema-per-tenant for isolation, with `tenant_id` columns
retained as an intra-schema partitioning/query-predicate mechanism inside each
schema** (confirmed: adp-02's tenant-scoped uniqueness constraints like
`uq_definition_tenant_version` are still present as of ISS-0150's 2026-08-10 catalog
read, scoped under `tenant_default`, not dropped when schema-per-tenant was added).
The `tenant_id` column was not superseded by schema-per-tenant; the two layers now
coexist. **The Reasoning section must state this two-layer reality explicitly and
decide against it, not against the adp-0x docs' `tenant_id`-only description in
isolation** — citing only §1's adp-0x summary without §2.2's migration-history finding
would materially misrepresent what "R-Co's tenant-column approach" actually is today.

### 2.3 Regular CRUD table shape, sampled directly

`004_definitions.sql` (`process_definitions`, `instance_definition_snapshots`) and
`002_event_type_registry.sql` (`event_type_registry`, with a built-in
`INSERT ... VALUES` seed of six platform event types baked directly into the migration
file) were read in full. Characteristic shape across regular CRUD tables: `UUID
PRIMARY KEY DEFAULT gen_random_uuid()`, `TEXT`/`JSONB` columns with inline `DEFAULT`s
and comment-documented allowed-value sets (e.g. `status TEXT NOT NULL DEFAULT 'DRAFT'
-- DRAFT | ACTIVE | DEPRECATED | ARCHIVED`, enforced only by application code / a
`CHECK` constraint in some tables, not a Postgres `ENUM` type anywhere sampled),
`created_at`/`updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`, `CREATE INDEX IF NOT
EXISTS` throughout (idempotent by convention), named `CONSTRAINT`s for uniqueness
(`uq_definition_version`), and occasional `GIN`/full-text-search indexes
(`idx_def_fts` via `to_tsvector`). This is materially different from Letflow's own
established Ecto convention (see §4) in one concrete way worth naming: R-Co's raw SQL
files freely mix multiple `CREATE TABLE` statements, indexes, and seed data in one
file per logical feature-slice, where idiomatic Ecto convention is closer to one
schema-defining concern per migration with `Ecto.Migration`'s `create table` DSL
rather than a hand-written multi-statement SQL block per file (though `execute/1` is
always available for anything the DSL can't express, e.g. `to_tsvector` GIN indexes or
the `bpm_provision_tenant_schema` function itself, whichever way the tenant-modeling
Decision resolves).

### 2.4 Event-store table shape, sampled directly

`001_event_store.sql` defines `events` (append-only-by-convention: no `UPDATE`
statement anywhere in the sampled files targets it, `sequence_number`/`global_seq`
monotonic counters, `uq_event_idempotency` a **global** unique index — not per-tenant
even after adp-01 added `tenant_id`, per adp-01's own explicit "ES-03 global
idempotency key uniqueness remains unchanged (not relaxed to per-tenant)" invariant),
`instance_sequence` (a per-instance next-sequence-number counter table, explicitly
there "to avoid `SELECT MAX(sequence_number) + 1` races under concurrent appends" per
its own comment), and `instance_projections` (the derived/rebuildable read-model,
explicitly documented as "re-buildable at any time without loss of ground truth" from
the event log — i.e. `instance_projections` is a materialized projection, not a
source-of-truth table, even though schema-wise it looks like an ordinary CRUD table).
`003_event_archive.sql` defines `events_archive` as **schema-identical to `events`**
plus one additional `archived_at` column — archival is a row-move (`events` →
`events_archive`), not a delete. `1147_par01_events_partitioning.sql` (read the first
~40 lines) later converts both `events` and `events_archive` from unpartitioned tables
to **monthly `PARTITION BY RANGE (created_at)`**, which forced two structural
consequences worth naming for the Reasoning section: (a) the primary key had to widen
from `(event_id)` to `(event_id, created_at)` because Postgres requires the partition
key to be part of every unique index on a partitioned table, and (b) the previously
single global `uq_event_idempotency` unique index could no longer enforce global
uniqueness across partitions, so a separate sidecar table
(`plat_event_idempotency`) was introduced to carry that invariant instead.

**What this means for Dimension 3 (event-store vs. regular-table migration
strategy):** the event-store tables in R-Co are additionally distinguished from
regular CRUD tables by at least three structural properties a straight 1:1 port would
need to reason about even before touching the tenant-modeling question: (1)
append-only/immutable rows (no `UPDATE` path), which is a constraint Ecto's `changeset`
pattern doesn't enforce by default the way a regular CRUD schema's changeset-based
`update/2` would imply is normal; (2) a derived/rebuildable projection table
(`instance_projections`) whose correctness invariant is "matches a fold over `events`,"
not "is the source of truth" — a materially different correctness property than an
ordinary Ecto-schema-backed CRUD table; (3) partition-driven primary-key/uniqueness
restructuring that is specific to very-high-row-count append-only tables and has no
equivalent concern on a low-row-count CRUD table like `event_type_registry` or
`process_definitions`.

## 3. Cross-reference to REQ-011's now-done finding on `tenant_id` usage in a real table

Per this task's own briefing, `docs/migration/decisions/0002-oidc-integration.md`'s
Reasoning (status: decided) already describes two concrete, already-verified facts
about how `tenant_id` is used in at least one real R-Co table today, independent of
this design's own §1/§2 research:

PROVENANCE (historical, not current decision authority):
1. **JIT-provisioning upsert** — `src/identity/registry.zig`'s
   `createOrGetJitOidcUser`, "an idempotent upsert keyed on `(tenant_id,
   external_realm, external_id)` via `INSERT ... ON CONFLICT ... DO NOTHING RETURNING
   ...` with a re-select fallback for concurrent conflicts." This is the concrete
   runtime behavior adp-04a's repository contract (§1.5 above) specifies at the design
   level — 0002 confirms it as implemented, not just designed.
2. **Tenant-realm binding** — a `tenant.idp_realm_id` column, "immutable after tenant
   creation." This matches adp-04b (§1.6 above) exactly and is the same invariant
   #2/#3 in adp-04b's own "Key invariants" section.

Both facts are consistent with, and already corroborate, this design's §1 finding that
adp-04/04a/04b describe an additive `tenant_id`-column pattern — 0002's research did
not surface anything contradicting §1's reading of those three docs. Neither 0002 nor
this design's own research surfaces anything about schema-per-tenant from the identity
side specifically (0002's research scope was OIDC library choice, not schema
provisioning), so §2.2's schema-per-tenant finding is new ground this design
contributes that 0002 had no occasion to touch.

## 4. Letflow's own current Ecto/migration state (read directly, not assumed)

`priv/repo/migrations/` currently holds exactly two migrations:
`20260814000001_create_transition_events.exs` (creates `transition_events`:
`binary_id` primary key, `string` columns, `timestamps(updated_at: false)`, one index
on `instance_id`) and `20260814000002_create_approvals.exs`. Both follow the
`backend_developer_guide.md` §3.7 convention (`binary_id` PK, `null: false` on
required columns, `timestamps/1`, an index on the foreign-key-like column) — this is
the idiomatic-Ecto baseline the Reasoning section's "redesign Ecto-idiomatically"
option would extend, versus the port option that would instead try to preserve
R-Co's raw-SQL table/column names (`UUID PRIMARY KEY DEFAULT gen_random_uuid()`
verbatim rather than Ecto's `binary_id` abstraction, R-Co's `TEXT`-typed enum-like
status columns verbatim rather than an `Ecto.Enum` field, etc.). Neither existing
Letflow migration is tenant-scoped or event-sourced — they predate REQ-012 entirely
(REQ-012 is explicitly what unblocks tenant-scoped/event-store schema decisions per
`backend_developer_guide.md` §5: "don't assume schema-per-tenant, a `tenant_id`
column, or any other specific mechanism until that decision record exists").

## 5. The three dimensions the Decision/Reasoning must weigh

Per REQ-012's acceptance criteria, the Decision must resolve three separate questions.
This design does not pick a winner for any of them — that is ELIXIR-DEV's call to
record, per REQ-012's stated `owner: ELIXIR-DEV`, matching the pattern 0001 and 0002's
designs both used. It specifies what each dimension's Reasoning must address so the
eventual Decision is fully reasoned against source-verified facts rather than
asserted.

### Dimension A — 1:1 port vs. Ecto-idiomatic redesign

What the Reasoning section must state:
- Whether Letflow preserves R-Co's exact table/column names (`process_definitions`,
  `instance_projections`, `tokens`, raw `TEXT`-typed status columns with
  comment-documented allowed values, `UUID PRIMARY KEY DEFAULT gen_random_uuid()`) for
  easier cross-referencing during the port, or redesigns idiomatically (Ecto's
  `binary_id`, `Ecto.Enum` for status fields, Elixir-conventional `snake_case` naming
  per `backend_developer_guide.md` §3.1 — which is already satisfied by R-Co's
  `snake_case` SQL columns, so naming convention alone doesn't force a redesign
  decision either way).
- Whether "port" and "redesign" are actually mutually exclusive, or whether a hybrid is
  viable (e.g. preserve table/column names for cross-referencing but use Ecto's
  `binary_id`/`Ecto.Enum` abstractions where they're a drop-in equivalent with no
  behavior change) — §2.3 found R-Co's regular-table shape (multi-statement raw-SQL
  files, `IF NOT EXISTS` idempotent DDL, inline seed data) is different enough from
  Ecto's one-migration-per-concern DSL convention that some translation is unavoidable
  regardless of the naming decision; the Reasoning section should state whether that
  unavoidable translation effort changes the port-vs-redesign calculus.
- What "146 migrations" (§2.1 — corrected from REQ-012's stated 143) implies about
  1:1-port effort specifically: 31 of the 146 are `GBL-`-prefixed global-schema-only
  migrations (§2.1) that exist *because* of the schema-per-tenant/tenant-column dual
  model (§2.2) — a chunk of R-Co's migration count is corrective/reconciliation work
  for its own two-layer tenant model (e.g. `GBL-112`'s cleanup of tables migrations
  001–059 created before migration 060 added schema-per-tenant), not core schema
  definition. The Reasoning section should state whether a 1:1 port would need to
  replicate that reconciliation history at all (arguably not, if Letflow starts
  schema-per-tenant-or-tenant-column-only from day one rather than evolving through
  R-Co's same two phases).

### Dimension B — multi-tenancy representation: tenant_id column vs. schema-per-tenant vs. database-per-tenant

What the Reasoning section must state, **citing the specific adp-0x doc(s) per
acceptance criterion 2**:
- Which of adp-01, adp-02, adp-03, adp-04, adp-04a, adp-04b (§1 above) the Decision
  cites, and a summary of what they actually specify (an additive `tenant_id`-column
  pattern with default-tenant-UUID backfill, enforced at service/repository
  boundaries — §1's summary paragraph) — not a generic restatement of "R-Co uses
  tenant columns" without citing which document says so.
- **Explicit reconciliation of §2.2's finding**: the adp-0x docs alone describe
  tenant-column-only, but R-Co's actual migration history (migration 060 onward) layers
  schema-per-tenant on top, with `tenant_id` columns retained inside each schema. The
  Reasoning section must state whether Letflow adopts (a) R-Co's original
  tenant-column-only model as the adp-0x docs describe it in isolation, (b) R-Co's
  *current*, actual two-layer model (schema-per-tenant + intra-schema `tenant_id`), or
  (c) diverges from both (e.g. tenant-column-only permanently, accepting that R-Co
  later found this insufficient and added schema-per-tenant — if so, the Reasoning
  should address *why* R-Co added the second layer, per §2.2's evidence, and whether
  that same motivation applies to Letflow or not). Silently citing only the adp-0x docs
  without addressing §2.2's migration-history finding would not satisfy acceptance
  criterion 2's "states whether Letflow adopts or diverges from it, with reasoning" —
  the "it" being cited must be R-Co's actual approach, not an incomplete slice of it.
- Whichever of the three options (tenant_id column / schema-per-tenant /
  database-per-tenant) is chosen, state how it interacts with Ecto/Postgres
  concretely: a plain `tenant_id` column is a normal Ecto field plus a
  query-composition discipline (every query scoped by `where: tenant_id: ^tenant_id`,
  enforced by convention or a library like `ecto_tenancy`-style query prefixing);
  schema-per-tenant in Postgres maps to Ecto's `Ecto.Repo`
  `:prefix`/dynamic-repo-per-schema mechanism (Ecto has first-class support for
  Postgres schema-based multi-tenancy via query prefixes, materially different
  plumbing than a `tenant_id` `WHERE` clause); database-per-tenant would need
  per-tenant `Ecto.Repo` instances or dynamic connection configuration, the heaviest
  operational option of the three. R-Co's own database-per-tenant option was never
  described in any of the six adp-0x docs or the migration history sampled (§1, §2) —
  if the Decision considers it at all, the Reasoning section should note it has no
  R-Co precedent to reason from, unlike the other two.
- `docs/migration/stage-2-event-store-definitions.md` and (implicitly) `stage-3` state
  they inherit `0003-ecto-schema-strategy.md`'s decision for their own table shapes —
  the Reasoning section doesn't need to address S2/S3 execution directly (out of
  REQ-012's scope, see §7 below) but should be written knowing those stages will read
  it as the binding decision for their own schema work.

### Dimension C — event-store vs. regular-table migration strategy

What the Reasoning section must state, per acceptance criterion 3 ("doc distinguishes
event-store migration strategy from regular table migration strategy"):
- Whether Ecto migrations for `events`/`events_archive`-equivalent tables need to
  account for R-Co's append-only convention (§2.4) at the migration-definition level
  (e.g. no `update/2`-oriented changeset path exposed for these schemas at all, even
  though Ecto itself doesn't structurally forbid an `UPDATE`) — this is more a
  schema-module-design concern than a migration-file concern, but the Reasoning
  section should state which it considers this to be, since REQ-012 is scoped to
  "migration strategy" specifically.
- Whether Letflow's event-store migrations should anticipate partitioning
  (`PARTITION BY RANGE`) from the start, mirroring R-Co's eventual `PAR-01` migration
  (§2.4), or add it later the way R-Co did (unpartitioned first, partitioned
  retrofit at `1147_par01_events_partitioning.sql` once row-count pressure justified
  it) — and if deferred, whether the Reasoning section should flag the same
  primary-key-widening and idempotency-sidecar-table consequences (§2.4) as a known
  future migration cost rather than a surprise.
- Whether `instance_projections`-equivalent derived/rebuildable tables get a
  materially different migration-strategy treatment than genuine CRUD tables (e.g.
  regular tables define column constraints as the actual data-integrity boundary,
  while a projection table's real correctness invariant lives in the fold-over-events
  logic, not the schema — the Reasoning section should state whether that changes
  anything about how strictly the migration should encode column constraints, or
  whether it's schema-identical to a regular table regardless).
- Whether the global-uniqueness-across-partitions problem (§2.4's
  `plat_event_idempotency` sidecar) is something Letflow's strategy should proactively
  design around even before partitioning is needed, or is explicitly deferred as a
  "cross that bridge at S2/S3 partitioning time" item — either is defensible, but the
  Reasoning section must say which, not leave it unaddressed.
- How this dimension interacts with Dimension B's tenant-modeling decision: §2.2/§2.4
  found R-Co's event-store tables are specifically `PER_TENANT`-classified (schema-per-
  tenant), separate from whatever Dimension B concludes for regular CRUD tables — the
  Reasoning section should state whether event-store and regular tables are expected
  to use the *same* tenant-modeling mechanism once Dimension B is decided, or whether
  event-store tables specifically warrant the schema-per-tenant treatment regardless
  of what Dimension B picks for everything else (R-Co's own history suggests these
  were not necessarily coupled decisions, since events/events_archive's
  `PER_TENANT` classification is stated independently of the general adp-0x
  tenant-column pattern).

## 6. Acceptance-criteria traceability

| REQ-012 acceptance criterion | Concrete design element addressing it |
|---|---|
| "`docs/migration/decisions/0003-ecto-schema-strategy.md` exists with an explicit decision on 1:1 port vs. redesign" | §5 Dimension A lays out exactly what the Reasoning section must weigh (naming/column strategy, port-vs-redesign effort implied by the corrected 146-migration count, the `GBL-`-migration reconciliation overhead) — this design does not pick the winner (ELIXIR-DEV's call per `owner: ELIXIR-DEV`), but requires the eventual Decision to state one explicitly, not leave it as an open comparison |
| "doc explicitly addresses R-Co's tenant-column approach (cite the specific adp-0x design doc(s) read under R-Co's `src/design/`) and states whether Letflow adopts or diverges from it, with reasoning" | §1 reads and summarizes all six named adp-0x docs individually, confirming all six exist at the cited paths (no misattribution, unlike REQ-010/011's skeletons); §2.2 supplies the critical additional ground truth (R-Co's actual migration history layers schema-per-tenant on top of the adp-0x docs' tenant-column-only description) that the Reasoning section must reconcile, not omit; §5 Dimension B requires the Decision to state explicitly which of R-Co's tenant-column-only design vs. its actual two-layer implementation it is adopting-or-diverging-from, with reasoning tied to §2.2's evidence |
| "doc distinguishes event-store migration strategy from regular table migration strategy" | §2.3 and §2.4 sample and characterize both table shapes directly from source (`process_definitions`/`event_type_registry` for regular CRUD; `events`/`events_archive`/`instance_projections`/`instance_sequence` plus the later `PAR-01` partitioning retrofit for event-store); §5 Dimension C requires the Reasoning section to state a position on append-only/immutability handling, partition timing, derived-table treatment, and the global-uniqueness-under-partitioning problem |

## 7. What NOT to do (scope boundary ELIXIR-DEV must respect)

- REQ-012 and this design produce a **decision record only**. Per REQ-012's own
  `description`: "Do not write actual migrations yet — this is the strategy doc S2/S3
  requirements will follow." No file under `priv/repo/migrations/` may be added or
  changed as part of this requirement.
- No `.ex` file (schema module, context module, anything under `lib/letflow/`) may be
  added or changed. This decision does not implement `Letflow.Repo`'s `:prefix`
  configuration, an `Ecto.Enum` type, or any other mechanism named in §5's discussion —
  naming a mechanism as part of the Reasoning is not the same as wiring it up, and
  wiring it up is S2/S3 execution work.
- No `mix.exs` dependency change (e.g. a schema-per-tenant helper library) belongs to
  this requirement, even if the Decision's Reasoning favors one.
- The only file ELIXIR-DEV should modify for REQ-012 is
  `docs/migration/decisions/0003-ecto-schema-strategy.md` (Decision + Reasoning
  sections), consistent with the skeleton file already in place. This design document
  is the only new file this step produces
  (`lib/letflow/design/0003-ecto-schema-strategy-decision.md`).
- Do not silently correct the 143→146 migration-count discrepancy in
  `docs/requirements.yaml`'s REQ-012 entry or the skeleton's Question section as a side
  effect of this work — that's outside this design step's file scope, same boundary
  0001's and 0002's designs drew for their own count/attribution corrections. Register
  it as an issue instead (§8 below).
- `docs/migration/stage-2-event-store-definitions.md` and `stage-3-instance-engine.md`
  already state they inherit this decision — do not edit either stage file as part of
  REQ-012; they read the finished decision record later, at S2/S3 start.

## 8. Open questions / discrepancies to register, not silently resolve

1. **Migration count mismatch (143 vs. 146).** `docs/requirements.yaml`'s REQ-012
   `description` and the pre-existing `0003-ecto-schema-strategy.md` skeleton's
   Question section both say "143 Postgres migrations." The verified actual count,
   via `ls migrations/*.sql | wc -l` against R-Co's real `migrations/` directory this
   session, is **146**. This design resolves it for the purpose of writing 0003's
   Reasoning section (cite 146, see §2.1) but does **not** edit
   `docs/requirements.yaml` or the skeleton's Question section, since that's outside
   this design step's file scope. Recommend filing a new `docs/issues/ISS-NNNN.yaml`
   entry (per `core-directives.md`'s "No Issue Left Local-Only") — this would be
   `ISS-0004` (the next free number after `ISS-0001`/`ISS-0002`/`ISS-0003` already on
   disk under `docs/issues/`), same pattern REQ-010's `ISS-0001` and REQ-011's
   `ISS-0002` used for their own stale-count/misattribution findings.
2. **R-Co's tenant-modeling approach is not fully captured by the adp-0x docs alone —
   this is the load-bearing finding of this design, not a minor discrepancy.** §2.2
   documents that R-Co's actual migration history adds schema-per-tenant provisioning
   (migration 060, `SPT-01`) and later drops the legacy shared-`public`-schema business
   tables (`GBL-112`, `TNT-01`) entirely, on top of the tenant-column pattern the six
   adp-0x docs describe. The adp-0x docs were seemingly not updated to reflect this
   (none of the six, read in full this session, mentions schema-per-tenant, a
   `tenant_schemas` registry table, or `bpm_provision_tenant_schema` at all) — meaning
   the adp-0x docs describe R-Co's tenant-modeling approach as it stood at an earlier
   point in its evolution, not its current, actual state. This is not something this
   design silently resolves on ELIXIR-DEV's behalf (per this task's own instruction not
   to pre-decide the winner) — §5 Dimension B requires the Reasoning section to state
   explicitly which version of "R-Co's tenant-column approach" the Decision is
   adopting-or-diverging-from. Recommend flagging this as its own issue too (a
   candidate `ISS-0005`) separate from the migration-count issue above, since it's a
   documentation-currency problem in R-Co's own `src/design/` tree, not a Letflow-side
   defect — out of scope for this session to fix in R-Co's repository, but worth
   recording so a future reader of the adp-0x docs isn't misled the same way this
   design's first read nearly was.
3. **Final Decision (1:1 port vs. redesign; tenant_id column vs. schema-per-tenant vs.
   database-per-tenant; event-store vs. regular-table strategy) is intentionally not
   pre-decided here.** This design specifies the three dimensions, the ground truth
   each must reason from (including the schema-per-tenant complication in #2 above,
   which materially changes what "adopt R-Co's approach" even means), and the
   acceptance-criteria traceability the eventual Decision must satisfy — it does not
   assert any of the three winners as settled fact. That synthesis is ELIXIR-DEV's to
   record as `docs/migration/decisions/0003-ecto-schema-strategy.md`'s actual Decision
   section content, per REQ-012's stated `owner: ELIXIR-DEV`. CODE-DESIGN-VALIDATOR
   should not fail this design for not naming winners outright — the design's job is
   to make sure the Decision, once written, is fully reasoned against real,
   source-verified facts (including the schema-per-tenant complication this design
   surfaced), not to pre-empt ELIXIR-DEV's documented ownership of the call.
