# 0024 — Entity-column-promotion DDL execution: mechanism, failure semantics, backfill and rollback

Status: decided (2026-09-09, `CODE-DESIGNER`, REQ-295), pending its own
`SECURITY-REVIEWER` and `REVIEWER` gates (sections below, not yet filled in).
Owner: `ORCH` (answers `0023-entity-storage-hybrid.md`'s named open question;
blocks every implementation requirement filed against 0023 until both gates
below pass).

## Question

`0023-entity-storage-hybrid.md` decided the entity-storage shape — per-
entity-type tables, a promoted-column/blob hybrid, additive-only promotion,
demotion forbidden — but named one open question that blocks every
implementation requirement against it, verbatim:

> How a promotion's DDL is executed, per tenant, in a humanless pipeline.

Four sub-questions were named and none was answered:

1. What runs the DDL across every tenant schema — an extension of
   `Letflow.TenantProvisioning`'s manifest, a dedicated migrator, or the
   promotion path itself?
2. What happens to a tenant whose DDL fails midway, when others have
   succeeded? Atomic across tenants, or per-tenant with a repair path?
3. Does a promotion's backfill run inline or as a replay through
   `rebuild_projection/2`, and what serves reads while it runs?
4. What is the rollback story, given that demotion is forbidden?

This record answers all four. It does not reopen anything 0023 already
decided (the storage shape, the promotion rule, additive-only/demotion-
forbidden, the entity-vs-blob test) — see "What this record does not
decide" below.

## Decision

**A promoted attribute moves through six explicit per-`(tenant, entity_type,
attribute)` states, tracked in one new table, driven by new functions added
to `Letflow.TenantProvisioning` (extending that module, not replacing it or
building a second one beside it), with dual-write bridging every window
where a stale read would otherwise be possible.**

### 1. What runs the DDL: `Letflow.TenantProvisioning`, extended — not its
existing manifest, and not a second module

The DDL runs from new functions added to `Letflow.TenantProvisioning`
itself (a new file, `lib/letflow/tenant_provisioning/column_promotion.ex`,
holding a new Ecto schema — same pattern this module already uses for
`Registration`), reusing three things that module already has and that are
already reviewed:

- `schema_name_for_tenant/1`'s validated `tenant_[0-9a-f]{32}` shape and the
  `Registration.schema_name` it produces — the only thing this codebase
  trusts to interpolate into a DDL identifier.
- The per-schema `pg_advisory_xact_lock(hashtext($1))` pattern
  `provision_tenant_schema/1` already takes before touching a schema (see
  `lib/letflow/tenant_provisioning.ex` lines 258–274).
- The module's established `{:ok, _} | {:error, _}` convention
  (`backend_developer_guide.md` §3.5), which `replay_migrations/2` already
  follows for its own DDL-adjacent call.

**It does not reuse `tenant_scoped_migrations/0`'s `@tenant_scoped_migration_manifest`
or `Ecto.Migrator.run/4`.** That mechanism is a fixed, hand-curated list of
`{version, module, filename}` triples, each backed by a compiled `.exs` file
under `priv/repo/migrations/` that a developer or agent adds to the
manifest as a source-code change (`lib/letflow/tenant_provisioning.ex` lines
352–507). A column promotion is triggered by an entity definition being
edited — an arbitrary, tenant-authored event with no compiled migration
file behind it, no version number known ahead of time, and no "run every
pending migration for this schema" semantics that make sense: `all: true`
against the manifest is right when every tenant must converge on one
platform schema, and wrong when the operation in question is "add one
column to one entity type's table," scoped to whichever tenants share that
entity type. `Ecto.Migrator.run/4` also fails at the batch level — the
`try/rescue` around it (lines 330–348) cannot tell which of several pending
migrations raised, and a promotion needs a failure recorded against exactly
one `(tenant, entity_type, attribute)` triple, not "the batch." The new
functions instead build and execute one `ALTER TABLE ... ADD COLUMN ...`
statement per promotion, directly, the same way `provision_tenant_schema/1`
already executes `CREATE SCHEMA IF NOT EXISTS "#{schema_name}"` directly
rather than through the migrator (line 274) — this decision extends that
existing precedent, not the neighbouring one.

**Why not (b), a dedicated migrator module.** A separate module would have
to reimplement the exact same identifier-safety argument
`Letflow.TenantProvisioning`'s design doc §3.1 already makes and
`SECURITY-REVIEWER` has already passed against ISS-0027/GH#85: that
`schema_name` is safe to interpolate *because* it only ever comes from
`schema_name_for_tenant/1`'s output, guarded a second time by
`Registration.changeset/2`'s format validation. A second module asserting
"my `schema_name` input is also safe" independently is the exact failure
shape `docs/anti-patterns.md`'s "documented equality that silently stopped
being true" entry warns about — a safety property that holds only as long
as two places agree, with nothing that re-checks that they still do. Living
inside `Letflow.TenantProvisioning` means there is exactly one place that
is allowed to know what a safe `schema_name` looks like.

**Why not (c), the promotion path itself.** "The promotion path" is
whatever code reacts to one tenant's admin (or a pack install) editing an
entity definition to mark a field `queried: true` or as an `fk_def`. Under
option (c) that single request handler would, inline, open connections
against and run DDL against *every other tenant's* schema that shares the
entity type — a request scoped to tenant A reaching into tenant B..N's
schemas as a side effect of handling A's HTTP request. That is precisely
the "internal path with no exception" INV-1 forbids: the promotion decision
is tenant-A-scoped (it is A's definition edit, or a pack install A
triggered), but its DDL execution is not, and INV-1 does not carve out an
exception for "the path that happens to have decided a promotion is
needed." It also collapses two things 0023 already keeps apart — deciding
*that* an attribute promotes (a Definition-shape fact, evaluated once) and
*executing* that promotion against N independently-lived schemas (an
operational fan-out with its own failure modes) — into one request/response
cycle, with no retry boundary distinct from the definition edit that
triggered it.

### 2. Partial-failure semantics: per-tenant, with a dedicated state table —
not atomic across tenants

A promotion is **not** atomic across tenants. Requiring N independent
Postgres schemas to commit-or-rollback together needs a distributed
transaction this project has never taken on for any other tenant-fanout
operation (`provision_tenant_schema/1` and `replay_migrations/2` are both
already single-tenant, invoked once per tenant, with no cross-tenant
transaction). A promotion is instead a batch of independent per-tenant
attempts, each succeeding or failing on its own.

**New table, `entity_column_promotions`** (global/`public` schema, in the
same trust tier as `tenant_schemas` — column promotions are platform
bookkeeping, not tenant business data), one row per `(tenant_id,
entity_type, attribute)`:

| Column | Type | Notes |
|---|---|---|
| `id` | `binary_id` | PK |
| `tenant_id` | `uuid` | FK to `tenants.id` |
| `entity_type` | `string` | matches the entity definition's type name |
| `attribute` | `string` | the promoted field's name |
| `column_name` | `string` | the physical column name (normally `= attribute`, distinct field in case of a future collision-avoidance rename) |
| `status` | `string`, one of `pending \| ddl_applied \| backfilling \| backfilled \| active \| ddl_failed \| suspended` | see the state machine below |
| `query_eligible` | `boolean`, default `false` until `active` | independent of `status` — see rollback (§4) |
| `last_error` | `string`, nullable | set on `ddl_failed`, cleared on retry |
| `attempted_at`, `ddl_applied_at`, `backfilled_at`, `activated_at` | `naive_datetime`, nullable | one timestamp per state transition actually reached |
| `inserted_at`, `updated_at` | timestamps | standard |

Unique index on `(tenant_id, entity_type, attribute)`.

**What a tenant stuck in `ddl_failed` reads/writes through.** Old,
blob-only path, unconditionally. The physical column may or may not exist
(a failure can occur mid-statement or in a post-DDL verification step);
either way `query_eligible` is `false`, so — per §1 of the decision below —
the query layer never dispatches to it, and the projector's write path
(§3) never targets a column whose promotion row is not at least
`ddl_applied`. That tenant is not "unavailable" — normal reads and writes
against that entity type continue exactly as before the promotion was
attempted; only the promoted attribute's query surface is unaffected by
uncommitted work. Repair is a retry of the same DDL step for that one
`(tenant_id, entity_type, attribute)` row, not a whole-batch re-run.

### 3. Backfill: replay through `rebuild_projection/2`, gated by dual-write
so a filter never sees a partial column

**Backfill runs as a replay through
`Letflow.Entities.Record.Projector.rebuild_projection/2`**
(`lib/letflow/entities/record/projector.ex:181`, scoped with
`entity_type: <the promoted type>` per its own `opts` argument, `prefix:`
the tenant's schema) — not as one inline `UPDATE ... SET`. Three reasons,
not just "replay is the existing mechanism":

- `rebuild_projection/2` re-derives the current-state row from the event
  log, which is authoritative over whatever the current `field_values` blob
  happens to hold (a soft-deleted, corrected, or superseded record is
  handled the same way a fresh projection is) — an inline `UPDATE ... SET
  new_col = field_values->>'attr'` instead trusts the current projection
  row as ground truth, which is exactly the assumption 0023 reasoning §2
  calls out replay as existing to avoid.
- The per-`field_type()` cast/validation logic a new column's value needs
  already lives in the projector's own upsert path
  (`upsert_record_latest/3`, per 0023's Consequences section); an inline
  `UPDATE` would have to reimplement that casting as raw SQL, a second copy
  of type-coercion logic that can drift from the first.
- `rebuild_projection/2` already takes an `entity_type` scope and iterates
  per-instance internally (`resolve_entity_types/2`,
  `rebuild_each_entity_type/2`), which is exactly the boundary a promotion
  needs — replay only the one entity type being promoted, in the one
  tenant currently being backfilled.

**What a concurrent read sees for a record not yet backfilled: the JSONB
value, via dual-write — never a partial column, and never a blocked read.**
This is enforced by construction, not by timing, through the state
machine's ordering:

1. `pending` → `ddl_applied`: the column now exists (nullable) in the
   physical table, but the promotion row is not yet `backfilled`/`active`.
   **From `ddl_applied` onward, the projector's write path for this
   `(tenant, entity_type, attribute)` dual-writes** — every create/update
   through `Letflow.Entities.Records` writes the attribute's value to
   *both* the new column and `field_values` (the blob key is not dropped
   the moment the column exists; that only happens at `active`, step 3
   below). This is the one behavioural change to the write path this
   record requires; it is scoped to exactly the columns currently mid-
   promotion, and it is what makes the JSONB value trustworthy for every
   row written *during* backfill, not only the rows that predate it.
2. `ddl_applied` → `backfilling` → `backfilled`: `rebuild_projection/2`
   replays existing (pre-promotion) records into the new column. Reads
   during this window are unaffected — `query_eligible` is still `false`,
   so `Letflow.Entities.Query.Allowlist`'s per-tenant, per-entity-type
   builder — `typed_columns/0` (`lib/letflow/entities/query/allowlist.ex:62-63`;
   0023's Consequences section: "`typed_columns/0` becomes
   per-entity-type") — continues to report this attribute as a `:json_field`
   entry for this tenant, and `Letflow.Entities.Query.Compiler`'s
   `build_filter_dynamic/2` (`lib/letflow/entities/query/compiler.ex:172`)
   dispatches it through the `:json_field` clause — reading `field_values`,
   which dual-write has kept current for every row, old and new, throughout
   this window. The `:typed_column` clause (`compiler.ex:163`) is never
   reached for this attribute in this tenant until step 3.
3. `backfilled` → `active`: a verification step (row-count parity between
   non-null values in the new column and live, non-deleted records of that
   entity type for that tenant) must pass before this transition is taken.
   Only then does `query_eligible` flip to `true`, which is the single flag
   the extended `Allowlist` builder (REQ-299's scope) must consult before
   including the attribute as a `:typed_column` entry for that tenant. Only
   at this same transition does the projector's write path **stop**
   dual-writing the attribute into `field_values` going forward — existing
   blob keys for already-written rows are left in place, unread, and
   harmless, because `Allowlist`'s already-documented shadowing rule ("a
   typed column always wins over a same-named JSONB key," 0023's
   Consequences section) makes the leftover key inert rather than a second
   source of truth.

There is no window in which a filter compiles against `:typed_column` for a
row whose column value is not yet populated: the compiler cannot see
`:typed_column` for this attribute in this tenant until `query_eligible`
is `true`, which is only set after verified-complete backfill.

**Cost accepted, not hidden.** Full-history replay is more expensive per
promotion than a single `UPDATE`. That cost is accepted for the
correctness property above; batching/chunking `rebuild_projection/2`'s
per-instance loop for very large entity types is left to REQ-296's own
implementation, not re-litigated here.

### 4. Rollback: never a drop or narrow — exclusion from the allowlist,
plus a corrective promotion for the data

Demotion (dropping a promoted column, or narrowing its type) is **not
proposed anywhere in this record**, under any name. If a promoted column is
later found wrong — bad backfill data, or a type choice that should have
been different — the corrective sequence is:

1. **Immediate:** set `query_eligible: false` on that `(tenant_id,
   entity_type, attribute)` row, without touching `status` and without any
   DDL. This is the "excluded from the allowlist until fixed" option named
   in REQ-295's own text, and it is deliberately **not** the same as
   falling back to `:json_field` dispatch: once a column has reached
   `active`, the write path has stopped dual-writing to `field_values`
   (step 3 above), so the blob is stale for every row written after
   cutover and is not a safe fallback. `Allowlist` must therefore simply
   omit the attribute from the allowlist entirely while `query_eligible` is
   `false` and `status` is past `active` — queries against it fail closed
   (`{:error, :field_not_queryable}`, the shape `Allowlist` already uses
   for an unrecognized field) rather than silently reading a stale value.
2. **Corrective:** the actual data fix ships as a **new promotion pass**
   against the *same* column — a second, explicit `backfilling` cycle
   (state transitions `active → backfilling → backfilled → active` are
   permitted to repeat) that re-derives values via a fresh
   `rebuild_projection/2` replay with corrected logic. This is a row-value
   correction, not a schema change — the column's name and type are
   untouched throughout — so it does not conflict with 0023's additive-
   only/demotion-forbidden rule, which governs DDL shape, not row content.
   Only once the corrective backfill re-verifies does `query_eligible`
   return to `true`.

If the defect is in the column's *type* itself (not just its data), the
column is never narrowed or retyped in place — a new, differently-named
attribute/column is promoted instead (an ordinary new promotion under the
existing rule), the old column is left physically in place forever
(`query_eligible` permanently `false`), and the entity definition is
updated to point at the new attribute. This is the "table/column count is
output volume, not a complexity metric" argument 0023 reasoning §4 already
accepts, applied to a mistaken column instead of a superseded one.

### `entity_record_latest`: recommend retirement, not migration

0023 leaves this explicitly open. This record's recommendation: **retire
`entity_record_latest`, do not build a migration path for its rows.**
Reasoning:

- 0023's own "What this record does not decide" section states plainly:
  "No deployment is known to hold entity records today." Building a
  migration/backfill path for a table with zero known production rows is
  speculative work — this project's "no speculation" rule (core-directives)
  argues against designing a migration for data that, as far as any record
  shows, does not exist.
- 0023's decision is unconditional on entity type — *every* entity type
  gets its own per-entity-type table under the new shape, promoted or not
  (the "hybrid" half is orthogonal to and does not gate the "per-type"
  half). There is therefore no entity type for which
  `entity_record_latest` remains the storage target going forward; it has
  no ongoing purpose the moment the first entity type is created under this
  design.
- The concrete retirement mechanism: a future, separately-filed migration
  (not this requirement, not REQ-296 by default — its own requirement)
  drops `entity_record_latest` from the tenant-scoped migration manifest's
  effective schema, guarded the way this codebase already guards
  irreversible migrations (this module's design doc §4's "required guard
  pattern") — specifically, a guard that raises rather than drops if the
  table is found non-empty at migration time, so the "no known rows" premise
  is verified at the moment of deletion, not assumed from this record's
  text.

This is a decision-shaped recommendation with reasoning, per REQ-295's own
instruction that "deciding to explicitly leave the question open a second
time, with a named reason, is an acceptable outcome" — but the reasoning
above does not favor leaving it open; it favors retirement, stated
explicitly so a later reader is not left re-deriving it.

## Reasoning

Summarized above, inline with each sub-answer, because each answer's
justification is specific to that sub-question rather than a shared
argument repeated four times. The one cross-cutting principle: every
correctness property in §3 and every safety property in §1 is enforced by
a single flag or a single module boundary that is checked at the moment of
use (`query_eligible` at allowlist-build time; `schema_name`'s validated
shape at DDL-execution time) rather than by an invariant that must be
independently remembered in two places — the failure shape
`docs/anti-patterns.md` already has one entry about.

## Consequences

- **New table:** `entity_column_promotions` (global schema), per §2.
- **New Ecto schema module:** `Letflow.TenantProvisioning.ColumnPromotion`,
  mirroring `Registration`'s existing pattern.
- **New functions on `Letflow.TenantProvisioning`** (see the companion
  design doc, `lib/letflow/design/req295-entity-promotion-ddl-execution.md`,
  for signatures) — implemented by REQ-296 onward, not this record.
- **`Letflow.Entities.Record.Projector`'s write path gains a dual-write
  branch** for any attribute whose promotion row is `ddl_applied` through
  `backfilled` (inclusive) for the record's tenant — an amendment to
  `upsert_record_latest/3`'s existing two clauses (0023's Consequences
  section), not a new clause shape. Implemented by REQ-296 onward.
- **`Letflow.Entities.Query.Allowlist`'s per-entity-type `typed_columns/0`
  builder (`lib/letflow/entities/query/allowlist.ex:62-63`; REQ-299's scope)
  must additionally consult
  `ColumnPromotion.query_eligible` per tenant** before reporting an
  attribute as a `:typed_column` entry — an added precondition on top of
  REQ-299's own per-entity-type work, not a redesign of it.
- **`docs/agents/instructions/security-invariants.md` INV-1** gains a
  concrete new checkable case once REQ-296 lands: a column-promotion DDL
  run must be traceable to exactly the `tenant_id`/`schema_name` pair on
  its `ColumnPromotion` row, with no code path that can target a
  `schema_name` not derived from `schema_name_for_tenant/1`.
- **A future, separate requirement** drops `entity_record_latest`, guarded
  as described above — not filed here.

## What this record does not decide

- **The storage shape itself, the promotion rule, additive-only/demotion-
  forbidden, and the entity-vs-blob test.** All of 0023 stands unchanged;
  this record answers only the one open question 0023 named.
- **REQ-302's two sub-questions** — `ON DELETE` behavior for promoted FK
  columns, and localized-text plain-text-vs-`tsvector` column strategy.
  Filed and scoped separately per REQ-VALIDATOR's sizing split; this record
  takes no position on either.
- **Implementation.** No `lib/letflow/entities/`, `lib/letflow/tenant_provisioning*`,
  or migration file is touched by this record — REQ-296 onward builds
  against the companion design doc.
- **Batching/chunking strategy for large-entity-type replay**, and the
  exact verification-step SQL for the `backfilled → active` transition
  (row-count parity vs. a stronger check) — left to REQ-296's own design
  detail, within the state-machine contract fixed here.

## SECURITY-REVIEWER sign-off

**Verdict: FAIL.** Invariant assessed: INV-1 (tenant data isolation),
scope test applies — this record proposes new DDL-execution functions on
`Letflow.TenantProvisioning` plus a new global table
(`entity_column_promotions`) that gates cross-tenant DDL fan-out; this is
a design-time review of the proposed mechanism, not a review of shipped
code (none exists yet — REQ-296 onward builds it), per REQ-295's own
framing.

**What is sound.** §1's identifier-safety argument genuinely reuses the
existing, already-reviewed mechanism: `run_column_promotion/2` resolves
`schema_name` via `Repo.get_by(Registration, tenant_id: ...)`, the same
path `replay_migrations/2` uses today (`lib/letflow/tenant_provisioning.ex`),
and `Registration.changeset/2`'s `@schema_name_format` regex
(`~r/^tenant_[0-9a-f]{32}$/`, `lib/letflow/tenant_provisioning/registration.ex`
lines 43, 59) independently re-validates that shape at write time — no new
identifier-construction path is introduced. The `entity_column_promotions`
table's read accessors (`column_promotion_query_eligible?/3`,
`column_promotion_dual_write?/3`) are keyed by `(tenant_id, entity_type,
attribute)`, matching the unique index, so a read is scoped by construction
the same way `Registration` rows are looked up by `tenant_id`. No implicit
human check is relied on anywhere — the whole flow (register → run → backfill
→ activate) is programmatic per the design doc's function contracts.

**The gap (BLOCKER).** The companion design doc's mutating functions —
`run_column_promotion/2`, `retry_failed_column_promotion/2`,
`backfill_column_promotion/2`, `activate_column_promotion/2`,
`suspend_column_promotion/2` (`lib/letflow/design/req295-entity-promotion-ddl-execution.md`
§2) — all take `tenant_id` and `promotion_id` as two **independent**
caller-supplied parameters, with no stated contract that the function must
verify `promotion_id`'s own stored `tenant_id` agrees with the `tenant_id`
argument before acting. `run_column_promotion/2` resolves the DDL target
schema from the `tenant_id` *parameter*, but resolves the column spec
(`entity_type`, `attribute`, `column_name`) from the `ColumnPromotion` row
looked up by `promotion_id` — two independently-sourced values with no
specified cross-check. A caller that passes tenant A's `tenant_id` together
with tenant B's `promotion_id` (a plausible bug in a future admin/API
caller REQ-296 or later builds, not a contrived attack) would run DDL
derived from tenant B's promotion metadata against tenant A's schema — a
promotion intended for one tenant's schema executing against another's,
exactly the failure shape REQ-295 names as a tenant-isolation breach, not a
data-quality bug. This is precisely the "safety property that holds only
as long as two places agree, with nothing that re-checks that they still
do" pattern this same record's §1 reasoning invokes against a *different*
design option (`docs/anti-patterns.md`'s "documented equality that
silently stopped being true") — it reappears here at the argument-pair
level instead of the module-boundary level the record examined.

**What the record must add before this gate can PASS.** For every function
in design doc §2 that takes both `tenant_id` and `promotion_id`: either (a)
drop `tenant_id` as a separate parameter and derive it from the loaded
`ColumnPromotion` row itself, or (b) keep both parameters but specify
explicitly that the function first loads the row by `promotion_id`, compares
its stored `tenant_id` to the argument, and returns an error (e.g.
`{:error, :tenant_mismatch}`) before any DDL/replay/state-transition runs if
they disagree. Either fix must land in the design doc (and/or this record)
before REQ-296 implements against it — this is a design-contract gap, not
an implementation detail left open deliberately.

This is a design-time verdict only: it assesses whether the mechanism, if
built exactly as specified today, would satisfy INV-1 — it does not, and
cannot, verify running code, since none exists yet.

---

**RE-CHECK (2026-09-09, fix commit `a6517ea1`) — supersedes the FAIL above.
Verdict: PASS.**

Re-derived independently against the current text of
`lib/letflow/design/req295-entity-promotion-ddl-execution.md` §2 (not taken
on CODE-DESIGNER's report), invariant INV-1, scope test applies for the
same reason as the original review (new DDL-execution mechanism plus a new
global bookkeeping table gating cross-tenant DDL fan-out).

**Fix verified, Option A as claimed.** Every mutating function in §2 that
previously took an independent `tenant_id` alongside `promotion_id` now
takes only `promotion_id` (plus `reason` on `suspend_column_promotion/2`,
which is not an identifier and carries no cross-tenant risk):
`run_column_promotion/1`, `retry_failed_column_promotion/1`,
`backfill_column_promotion/1`, `activate_column_promotion/1`,
`suspend_column_promotion/2`. Checked the full function list in §2, not
just these five: `register_column_promotion/4` takes an explicit
`tenant_ids :: [Ecto.UUID.t()] | :all` but never a `promotion_id` alongside
it — it *creates* rows rather than acting on a pre-existing one, so there
is no second identifier for a caller-supplied `tenant_id` to disagree
with. `run_column_promotion_for_all_tenants/1` takes only a
`promotion_ref :: {entity_type, attribute}` tuple, no `tenant_id` at all,
and fans out to `run_column_promotion/1` per row it loads itself. The two
read accessors, `column_promotion_query_eligible?/3` and
`column_promotion_dual_write?/3`, take `tenant_id` but no `promotion_id` —
they are keyed directly by the `(tenant_id, entity_type, attribute)`
unique index, not by a DDL-target lookup, so there is no pair of
independently-sourced identifiers to cross-check there either. No function
anywhere in §2 retains the old two-independent-parameter shape.

**Traced `run_column_promotion/1` specifically, as the highest-risk
function.** Per §2's text: it loads the `ColumnPromotion` row by
`promotion_id` first (`{:error, :promotion_not_found}` if absent), then
reads `tenant_id` *off that same row* and resolves `schema_name` from it
via `Repo.get_by(Registration, tenant_id: promotion.tenant_id)` — the same
path `replay_migrations/2` already uses. The column spec (`entity_type`,
`attribute`, `column_name`) driving the `ALTER TABLE ... ADD COLUMN`
statement is read from that identical row. Both the DDL target schema and
the DDL content now derive from one single loaded record; there is no
caller-supplied `tenant_id` parameter left to disagree with it. This
closes the exact gap the prior FAIL identified.

**No remaining path.** Grepped the full design doc for every `tenant_id`
and `promotion_id` occurrence (28 hits) — none pair the two as independent
parameters on any function signature. `0024.md`'s own prose (Decision,
Reasoning, Consequences, "What this record does not decide") was not
touched by fix commit `a6517ea1` (`git show --stat a6517ea1` shows only
the design-doc file changed) and was re-read in full for this re-check:
none of those sections assert or depend on the old two-parameter shape —
the Consequences section's INV-1 note ("a column-promotion DDL run must be
traceable to exactly the `tenant_id`/`schema_name` pair on its
`ColumnPromotion` row") already anticipated exactly this fix and does not
contradict it.

**Sign-off sections intact.** This section (the prior FAIL, left in place
above rather than deleted, with this re-check appended to supersede it)
and the `## REVIEWER sign-off` section below are both untouched by
`a6517ea1` (confirmed via `git show --stat`, which touched only the design
doc) and untouched by this edit except for this appended block.

**Sanity re-pass on the original review's other checks** (unaffected by
this specific fix, confirmed still holding): identifier-safety still
reuses `schema_name_for_tenant/1`/`Registration.changeset/2`'s
`@schema_name_format` regex, no new identifier-construction path added;
`entity_column_promotions` reads/writes are still scoped by the
`(tenant_id, entity_type, attribute)` unique index; no implicit human
check anywhere in the register → run → backfill → activate flow.

One nit, not a security finding: design doc §4 line ~199 still refers to
"`backfill_column_promotion/2`" (stale arity — the function is now `/1`).
Documentation-only inconsistency, does not reintroduce the two-parameter
signature anywhere; not a blocker, worth ELIXIR-DEV fixing opportunistically
when REQ-296 implements against this doc.

This re-check, like the one it supersedes, is a design-time verdict: it
assesses whether the mechanism, if built exactly as specified now, would
satisfy INV-1. It does. REQ-296 onward should implement against the
current §2 text as written.

## REVIEWER sign-off

**Verdict: PASS.**

**Arity nit fixed.** SECURITY-REVIEWER's re-check flagged the companion
design doc's §4 as still referencing `backfill_column_promotion/2` after §2
was fixed to `/1`. Grepped the file: line 129 (§2) defines
`backfill_column_promotion(promotion_id :: Ecto.UUID.t())` — one argument —
and line 199 (§4, "What this design does not fix") still read
`backfill_column_promotion/2`. Confirmed it was really stale (not a second
genuine argument hiding there — §4's sentence is about the verification
query inside the function, not about its signature). Corrected `/2` to `/1`
in `lib/letflow/design/req295-entity-promotion-ddl-execution.md` line 199 as
part of this review pass — a single arity-number correction, not a
substantive change, so it did not need to route back to CODE-DESIGNER.

**Idiom fit: extending `Letflow.TenantProvisioning` is the right shape, no
dedicated supervision review needed.** Read
`lib/letflow/tenant_provisioning.ex` in full structure (module list via
`defmodule`/`def`/`defp` grep) and `lib/letflow/application.ex`'s
supervision tree. `Letflow.TenantProvisioning` is a plain module — no
`use GenServer`/`Supervisor`/`Agent`, no registered process, not listed
anywhere in `Letflow.Application`'s `children` list (which only names
`Letflow.Supervisor.Infrastructure`, `.Pollers`, `.PollersBreaker`, `.Http`).
Its existing functions (`provision_tenant_schema/1`, `replay_migrations/2`,
`schema_name_for_tenant/1`) are ordinary `{:ok, _} | {:error, _}`-returning
functions invoked synchronously by callers, with concurrency arbitrated by
the per-schema `pg_advisory_xact_lock` pattern, not by process isolation.
This is exactly the same shape REQ-045 already settled for
`Letflow.Engine` ("concurrency arbitrated by Postgres row/advisory locks,
not a supervised process per instance" — see `Letflow.Engine`'s own
moduledoc and `Letflow.InstanceSupervisor`'s deliberately-empty one). The
new functions in design doc §2 (`register_column_promotion/4`,
`run_column_promotion/1`, `run_column_promotion_for_all_tenants/1`,
`retry_failed_column_promotion/1`, `backfill_column_promotion/1`,
`activate_column_promotion/1`, `suspend_column_promotion/2`, and the two
read accessors) are all plain functions of the same shape, reusing the same
advisory-lock pattern and the same `{:ok, _} | {:error, _}` convention —
they slot into the existing module without adding a process, a registered
name, or any change to `Letflow.Application`'s children list. There is no
REQ-045-style question here because the record never proposes a process in
the first place; unlike REQ-045 (which had to choose between "process per
instance" and "row locks" for a *new* subsystem), 0024 is extending a
module whose row/lock-based idiom is already fixed precedent, and it
follows that precedent rather than reopening it. No dedicated
supervision/idiom review is needed beyond this confirmation.

**State machine internally consistent, §1–§4 tell one story.** Traced the
diagram in the design doc against the decision record's prose:
`pending -> ddl_applied` (§1, DDL success) gates the dual-write branch
described in §3 ("From `ddl_applied` onward, the projector's write path...
dual-writes"); `ddl_applied -> backfilling -> backfilled` (§1/§3) is exactly
the window `column_promotion_dual_write?/3` returns `true` for (design doc
§2); `backfilled -> active` is the single transition that flips
`query_eligible` (§3 step 3, design doc `activate_column_promotion/1`),
which is the same flag `column_promotion_query_eligible?/3` exposes to
`Allowlist`. §4's rollback (`suspend_column_promotion/2`) sets
`query_eligible: false` while leaving `status` at `"active"` — the design
doc's state diagram calls this out explicitly as not a separate stored
string ("`suspended` is not a `status` transition away from `active`"),
matching §4's own text that this is deliberate so the row's history of
reaching `active` is not lost. The corrective-backfill cycle
(`active -> backfilling -> backfilled -> active`, repeatable) is stated in
both the design doc's diagram and 0024 §4's prose identically. No section
contradicts another; §3's backfill-window reasoning references
`column_promotion_dual_write?/3` and `column_promotion_query_eligible?/3`,
both of which now match the fixed single-argument (`promotion_id`-only)
signatures throughout §2 after `a6517ea1` — confirmed by re-reading the
full design doc, not just the SECURITY-REVIEWER re-check's report of it.

**Decision-record consistency confirmed.** 0023's additive-only/demotion-
forbidden rule (0023 lines 73-79, "Demotion is forbidden. A promoted column
is never dropped...") is respected throughout 0024 §4: rollback is
allowlist-exclusion (`query_eligible := false`) plus a corrective promotion
that re-derives *values*, never a schema change to the existing column, and
a wrong-type column is handled by promoting a new, differently-named column
rather than narrowing/retyping the old one in place — 0024 states this
explicitly does not conflict with 0023's rule "which governs DDL shape, not
row content." 0024 does not reopen the storage shape, the promotion rule,
or the entity-vs-blob test — its own "What this record does not decide"
section names this and the text above it is consistent with that scope
fence. No 0022 bucket/sequencing rule is implicated by this record (0024 is
platform-infrastructure work, not a pack-specific deliverable, and does not
touch bucket assignment). `git diff main...HEAD --stat` shows changes
confined to the two decision docs, the design doc, and
`docs/requirements.yaml` — no `lib/letflow/entities/`,
`lib/letflow/tenant_provisioning.ex`, `lib/letflow/tenant_provisioning/`, or
`priv/repo/migrations/` file is touched, matching REQ-295's own scope fence
("Implementation. No `lib/letflow/entities/`, `lib/letflow/tenant_provisioning*`,
or migration file is touched by this record").

**Format sanity check.** Section shape (Question / Decision / Reasoning /
Consequences / What this record does not decide / sign-off sections) matches
0022's and 0023's established structure; CODE-DESIGN-VALIDATOR already
confirmed this in full, no further re-derivation needed here.

This is a design-time verdict, per REQ-295's own framing: it assesses
whether the proposed mechanism, as now specified (design doc post-fix,
decision record as written), is idiomatically sound and internally
consistent — it is. TEST-DESIGNER may proceed once this requirement's other
gates (if any remain) are satisfied.
