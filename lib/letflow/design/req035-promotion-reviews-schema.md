# Design: REQ-035 — Promotion reviews schema (`promotion_reviews`, PRM-04 Type C part)

**Requirement:** REQ-035 (`docs/requirements.yaml`, stage S2, `depends_on: [REQ-022]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ035-20260817`, WF-02 Step 1
**This document produces:** migration shape, table/column/index/constraint detail,
`Ecto.Schema` module shape, `@spec`-style function signatures, invariants, required
verbatim moduledoc text, cross-module dependencies, open questions, traceability.
**No implementation code** — no function bodies, no `.ex`/`.exs` files, no migration
files. ELIXIR-DEV writes those from this document at Step 2a.

**Convention basis:** this requirement is a small structural sibling of REQ-023 (event
store, PR merged) and REQ-027 (definition core schema, merged). Migration file layout,
the `:prefix` guard pattern, moduledoc structure, changeset naming, the "functions that
will deliberately NOT exist" table, and the traceability table are all reused from
`lib/letflow/design/req027-definition-core-schema.md` rather than reinvented. This
document is deliberately much shorter than those two — one table, no foreign keys, no
cross-table ordering constraint, schema only.

---

## 0. Sources read for this design

- `docs/requirements.yaml` — REQ-035's full entry (`id: REQ-035`, description and all
  four acceptance criteria), read in full, not paraphrased. Also skimmed REQ-036/037/038
  (`promotion_plan`/`promotion_conflict`/`promotion_digest`, the review state machine,
  and rollback) to confirm what REQ-035 must **not** build and what shape those
  requirements expect this table to already have.
- `docs/guides/backend_developer_guide.md` — naming, error-shape and migration
  conventions (same sections REQ-023/027 cite).
PROVENANCE (historical, not current decision authority):
- `docs/migration/stage-2-event-store-definitions.md` — confirms `promotion_review.zig`
  (PRM-04) is in this stage's scope (`src/definition/` file list).
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — read in full. Decision A
  (Ecto-idiomatic redesign), Decision B (schema-per-tenant + intra-schema `tenant_id`),
  Decision C (event-store-specific rules, **not** directly applicable to this table —
  `promotion_reviews` is an ordinary mutable business table, not an append-only
  event-store table). The `PER_TENANT` classification discussion at lines 169–172 and
  296–309 — the precedent this design's §2 open question is measured against, because
  that discussion **names** `events`/`events_archive` explicitly (citing
  `1147_par01_events_partitioning.sql`'s own classification) and nothing in 0003 names
  `promotion_reviews` the same way.
- `docs/anti-patterns.md`, `docs/agents/instructions/core-directives.md`,
  `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1,
  `docs/agents/shared/HANDOFF_PROTOCOL.md`.
- `lib/letflow/design/req022-tenant-schema-provisioning.md` — §2 (migration shape,
  "don't port a redundant duplicate index" precedent), §3.4 (`tenant_scoped_migrations/0`
  design), **§4 (the mandatory two-half guard pattern), read in full.**
- `lib/letflow/design/req027-definition-core-schema.md` — read as the direct structural
  template for this document (§2's guard section, §3's table-spec conventions, §5.1's
  changeset/function-list shape, §6's invariants-table shape, §9's open-questions shape).
  §3.1's `status` `Ecto.Enum` lowercase-dump discussion is directly relevant to §5.1
  below.
- **`src/design/prm-04-promotion-review-state-machine.md` — searched for in this repo
  (`~/letflow`) under `src/design/`, `docs/`, and by filename grep across the whole
  tree; it does not exist here.** It is an R-Co-source-tree document (per REQ-035's own
  citation, `C:\Users\tvolo\dev\ai-dala\R-Co\src\design\prm-04-...md`), not checked into
  this repository, and this agent has no access to that path. This design therefore
  relies entirely on REQ-035's own `description`/`acceptance_criteria` text in
  `docs/requirements.yaml`, which is detailed enough to fully specify the schema (it
  names every column, both indexes, the six enum values, and quotes prm-04's Open
  Question 1 by description). Where REQ-035's text references prm-04 content this
  design cannot independently verify (e.g. the exact wording of "Open Question 1"), the
  citation is repeated from `docs/requirements.yaml` verbatim rather than invented.
  **Flagged explicitly, not silently worked around** — CODE-DESIGN-VALIDATOR and
  REVIEWER should know this design is one level removed from the R-Co source doc REQ-023
  and REQ-027 both had direct access to.

**Letflow shipped code read directly:**

- `lib/letflow/tenant_provisioning.ex` — `@tenant_scoped_migration_manifest` (currently
  nine `{version, module, filename}` entries), `tenant_scoped_migrations/0`'s
  module-loading behavior, `replay_migrations/2`.
- `priv/repo/migrations/20260816193001_create_process_definitions.exs` — the shipped
  reference for the `if prefix() do ... end` guard, a partial-unique-index-via-string-
  predicate, and the required `#`-comment header shape.
- `lib/letflow/definitions/process_definition.ex` — the shipped reference for
  `@primary_key {:id, :binary_id, autogenerate: true}`, bare-atom-list `Ecto.Enum`
  (lowercase dump), `@type t`/`@type status`, `insert`-only changeset naming, and the
  "status is never castable, transitions are guarded UPDATEs" moduledoc pattern this
  design reuses directly (§5.1, §6).
- `lib/letflow/event_store/event.ex` — the shipped reference for a plain `field(:x,
  Ecto.UUID)` with no `belongs_to` association even where a DB relationship exists.

---

## 1. Scope boundary

**In scope (this requirement):** one table (`promotion_reviews`), its migration, its
`Ecto.Schema` module under `lib/letflow/definitions/`, and the one-entry append to
`Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest` that REQ-022 §4
mandates for every tenant-scoped migration.

**Explicitly NOT in scope, and not silently dropped:**

| Not built here | Owned by | Citation |
|---|---|---|
| `insert_review/1`, `approve_review/4`, `reject_review/2`, `mark_review_applied/1`, `mark_review_failed/1`, `supersede_review/2` — the state-machine transition functions | REQ-037 | `docs/requirements.yaml` REQ-037 entry |
| `promote_definition/N` (ENV-03, the underlying version-pointer-move + event-append operation) | REQ-037 | same |
| `compute_promotion_plan/5`, `reject_if_conflicts/4`, `compute_plan_digest/1`, `verify_digest/2` — the plan/conflict/digest computation this table's rows are built from | REQ-036 | `docs/requirements.yaml` REQ-036 entry |
| Any HTTP route / API surface for submitting or approving a promotion | S4 (api-surface, per REQ-036's own scoping note) | REQ-036 entry |
| `rollback_definition_version/4`, which reads this table for its superseded-lookup | REQ-038 | `docs/requirements.yaml` REQ-038 entry |

---

## 2. Tenant-scoping: mandated PER_TENANT by REQ-035's own acceptance criterion — but flagged, not silently endorsed

**What REQ-035 mandates literally:** acceptance criterion 1 requires "a promotion_reviews
migration (schema-per-tenant per REQ-022) applying cleanly" — this is not optional or
left to this design's discretion; the migration **must** use REQ-022's `:prefix`
mechanism, exactly like every other business table built so far
(`process_definitions`, `instance_definition_snapshots`, the six event-store tables).
§3–§4 below build it that way.

**What is genuinely unresolved, and must not be read as settled by the paragraph
above:** REQ-035's own description says this table "carries a tenant_id-shaped scope
per its own schema below, consistent with Decision B's general rule for business
tables" but immediately flags that **neither `0003-ecto-schema-strategy.md` nor any
design doc states PER_TENANT/GLOBAL explicitly for this specific table**, unlike
`events`, which 0003 cites by name against `1147_par01_events_partitioning.sql`'s own
classification comment (§0 above, `0003:169–172, 296–309`). REQ-035's acceptance
criterion 4 requires this exact gap to be flagged in the moduledoc as an open question,
not silently resolved by this design going ahead and building the schema-per-tenant
migration AC1 demands. Both things are true at once: **the migration is built
PER_TENANT because AC1 requires it**, and **the classification is not independently
confirmed against an explicit R-Co source the way `events`' was**, so REVIEWER must
re-confirm it at Step 2d rather than treat CODE-DESIGNER's/ELIXIR-DEV's choice as
settled fact. See §7 for the exact moduledoc text this design requires, and OQ-2 in §9
for the full discussion, including a structural observation this design surfaced that
REQ-035's own text does not mention: `promotion_reviews` has exactly **one** `tenant_id`
column even though a promotion is a cross-tenant operation (REQ-036's
`compute_promotion_plan/5` takes both a `source_tenant_id` and a `target_tenant_id`) —
this design assumes (does not prove) that this single `tenant_id` names the **target**
tenant (the one being promoted into, whose approval gate this table implements), with
`source_tenant_id` presumably folded into `serialised_plan`'s JSON rather than getting
its own column. That assumption is not contradicted by anything in REQ-035's text, but
it is not confirmed by it either — flagged in OQ-2, not assumed silently.

---

## 3. Table specification: `promotion_reviews`

Conventions applied, matching `req022-...md` §4 and `req027-...md` §3 (both read in
full):

- `create table(:promotion_reviews, primary_key: false, prefix: prefix())` with
  explicit `add :id, :binary_id, primary_key: true`.
- `snake_case` column names — all names below are taken verbatim from REQ-035's own
  column list (`docs/requirements.yaml`), which already uses `snake_case`.
- A `#`-comment header block above `defmodule`, matching every migration in this
  project so far.
- DB types below are what the Postgres adapter emits for each Ecto migration type,
  per the same `deps/ecto_sql` mapping REQ-023/027 cited directly
  (`:binary_id -> uuid`, `:string -> varchar(255)`, `:text -> text`,
  `:integer -> integer`, `:utc_datetime_usec -> timestamp` (no time zone, precision 6)).

| Column | Ecto migration type | DB type | Null / default | Notes & citation |
|---|---|---|---|---|
| `id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` (implied by PK) | Decision A surrogate PK, matching every non-composite-PK table in this codebase. REQ-035 names `id (binary_id)` first (`requirements.yaml`, REQ-035 description). No DB-level default — client-generated via `Ecto.Schema`'s `autogenerate: true`, same as `process_definitions.id`. |
| `tenant_id` | `:binary_id` | `uuid` | `NOT NULL`, no default | Decision B's intra-schema `tenant_id` convention, applied to this table per REQ-035's own text (§2 above) and REQ-035's own literal column list. **No DB default** — Letflow has no reserved default-tenant UUID (established by `req022-...md` §3.3); REQ-037's `insert_review/1` supplies it explicitly. See §2's open question on what this single column denotes for a cross-tenant promotion. |
| `plan_digest` | `:string` | `varchar(255)` | `NOT NULL` | REQ-035: "plan_digest (string, 64-char lowercase hex)". `varchar(255)` is Ecto's `:string` migration default; the **64-char lowercase hex** shape is a business-rule bound enforced in the changeset (§5.1: `validate_length(:plan_digest, is: 64)` + `validate_format(:plan_digest, ~r/^[0-9a-f]{64}\z/)`), not a DB-level `CHECK` — matching this project's established "structural checks are a changeset/application concern, not a migration-layer CHECK constraint" pattern (`req027-...md` §3.1.3, applied to `graph`; same reasoning applies here — REQ-036 owns the actual digest **computation**, `compute_plan_digest/1`, and is the authority on the exact hex-alphabet shape, so a migration-layer CHECK here would be a second, possibly-drifting source of truth). This is the field the partial unique index (§3, Indexes) keys on — REQ-036's PRM-03 idempotency anchor, per REQ-035's own description. |
| `def_type` | `:string` | `varchar(255)` | `NOT NULL`, `default: "process"` | REQ-035: "def_type (string, default \"process\" — extensible per prm-04's Open Question 1, no CHECK constraint restricting the value set for now, note this explicitly as an open question in the moduledoc)". Built exactly as instructed: a plain `:string` column with a default and **no** enum, **no** CHECK constraint. This is REQ-035 acceptance criterion 4's first half — see §7 for the required moduledoc text and §9 OQ-1 for the open question itself, stated rather than resolved. |
| `def_id` | `:string` | `varchar(255)` | `NOT NULL` | REQ-035: "def_id (string — process_key)". No additional business-rule length validation beyond the implicit `varchar(255)` DB bound — REQ-035's text names no narrower bound, and `process_definitions.name`/`.version` establish the precedent that `varchar(255)` is this project's default string bound absent a more specific one. |
| `serialised_plan` | `:text` | `text` | `NOT NULL` | REQ-035: "serialised_plan (text, full canonical JSON per PRM-03)". `:text` (unbounded), matching `process_definitions.description`'s precedent for an unbounded free-form column. REQ-036 (PRM-03) is the authority on producing this JSON; REQ-035 stores it opaquely as text, not `jsonb` — REQ-035's text says "text" explicitly (not "map"/"jsonb"), and canonical-JSON byte-stability (PRM-03's whole point, per REQ-036's description: sorted keys, no insignificant whitespace) is exactly the kind of thing `jsonb`'s own re-normalization-on-storage behavior would silently undermine if this column were `:map`/`jsonb` instead — a `text` column preserves the caller's exact canonical bytes, which is what a stored digest-anchor value needs. Not silently divergent from a `:map` default: called out here as a deliberate reading of REQ-035's literal column type. |
| `status` | `Ecto.Enum` | `varchar(255)` | `NOT NULL`, `default: :pending_review` | REQ-035 acceptance criterion 1: "status as an Ecto.Enum over exactly the 6 named values" — `pending_review`, `approved`, `rejected`, `applied`, `failed`, `superseded`. Bare atom-list `Ecto.Enum` form (§5.1), which dumps each atom via `to_string/1` — **already lowercase snake_case**, so (unlike `process_definitions.status`, `req027-...md` §10 C-3) there is no case-mismatch risk between the enum's dumped value and the index predicates below; both are written identically in both places without needing a deliberate divergence-and-citation the way `process_definitions` needed. |
| `requested_by` | `:binary_id` | `uuid` | `NOT NULL` | REQ-035: "requested_by (binary_id)". No FK — see §3.1. |
| `approved_by` | `:binary_id` | `uuid` | **nullable** | REQ-035: "approved_by (binary_id, nullable)". No FK — see §3.1. Set by REQ-037's `approve_review/4`. |
| `approved_at` | `:utc_datetime_usec` | `timestamp` (precision 6) | **nullable** | REQ-035: "approved_at (utc_datetime_usec, nullable)". Microsecond precision matches this project's other event/decision timestamps (`archived_at` on `process_definitions`, `snapshotted_at`). Set by REQ-037's `approve_review/4`. |
| `superseded_by` | `:binary_id` | `uuid` | **nullable** | REQ-035: "superseded_by (binary_id, nullable)". No FK — see §3.1 and §9 OQ-3 (this design does not resolve what row this column identifies beyond REQ-035's bare column-list wording; flagged, not guessed). Set by REQ-037's `supersede_review/2`. |
| `row_version` | `:integer` | `integer` | `NOT NULL`, `default: 1` | **REQ-035 acceptance criterion 3.** See §6 INV-PR-1 and §7 for the required moduledoc text — this is an optimistic-locking column, not a plain audit counter. Incremented by REQ-037's guarded `UPDATE ... WHERE row_version = $expected` transitions, never by a changeset (§5.1). |
| `inserted_at` / `updated_at` | via `timestamps/1` | `timestamp` (precision 6) | `NOT NULL` | `timestamps(type: :utc_datetime_usec)` — plain, unrenamed (unlike `process_definitions`' `inserted_at: :created_at` rename, which exists there to match a specific R-Co column name this table has no equivalent citation for). Microsecond `:utc_datetime_usec` chosen to match this project's prevailing convention on every other business table built so far (`process_definitions`, `instance_definition_snapshots`, the event-store tables) rather than falling back to the repo's unconfigured `:naive_datetime` default — a deliberate consistency choice, not a literal requirement-text mandate (REQ-035's text says only "timestamps()"). |

**Primary key:** `(id)` — single `binary_id` surrogate key. No composite-PK concern
applies (Decision C's `(event_id, created_at)` rule is scoped to event-store tables
only, per `0003`; `promotion_reviews` is an ordinary mutable business table).

### 3.1 Foreign keys: none, deliberately

- **`requested_by`/`approved_by` → `users.id`: no FK.** Same cross-schema reason as
  every other tenant-scoped table's actor columns in this codebase
  (`process_definitions.created_by`, `req027-...md` §3.1.4): `users` lives in the
  public/default schema while `promotion_reviews` lives in a tenant schema (§2), and
  this project's established convention already omits DB FKs from tenant-scoped rows to
  identity rows.
- **`tenant_id` → `tenants.id`: no FK**, same reason, plus the tenant identity is
  already carried structurally by the schema name itself.
- **`superseded_by`: no FK**, not even a same-table self-referential one. REQ-035's
  column list gives no indication of exactly what row this points at (§9 OQ-3), and
  adding a self-referential FK on a guessed target would be inventing a constraint
  REQ-035's text does not ask for — left as a plain `binary_id` field, matching this
  codebase's existing convention of representing a DB relationship as a plain field with
  no Ecto association even where a same-schema FK would be technically possible (e.g.
  `Letflow.EventStore.Event`'s `instance_id`, which also carries no association).

### 3.2 Indexes

| Index name | Columns | Unique | Predicate | Why / citation |
|---|---|---|---|---|
| *(PK)* `promotion_reviews_pkey` | `(id)` | yes | — | Decision A surrogate PK. |
| `uq_promotion_review_active_digest` | `(tenant_id, plan_digest)` | **yes** | `status IN ('pending_review', 'approved')` | **REQ-035 acceptance criterion 2.** "prm-04's 'one live review per digest per tenant' invariant — the idempotency anchor for PRM-03's digest" (REQ-035 description). This is the index REQ-037's `insert_review/1` relies on to surface its distinct duplicate-review error (`docs/requirements.yaml` REQ-037 entry) — a second `pending_review` insert for the same `(tenant_id, plan_digest)` while a first is still `pending_review` or `approved` must violate this index. |
| `idx_promotion_review_rollback_lookup` | `(tenant_id, status)` | no | `status IN ('applied', 'superseded')` | Named in REQ-035's own description (not itself an enumerated acceptance criterion, but explicitly called for): "an index on (tenant_id, status) WHERE status IN ('applied', 'superseded') (for PRM-08 rollback's superseded-lookup queries)". Future consumer: REQ-038's `rollback_definition_version/4` (`docs/requirements.yaml` REQ-038 entry, "operating on REQ-027's process_definitions and REQ-035/037's promotion_reviews tables"). Built here because REQ-035 is this table's only migration-owning requirement; REQ-038 does not get a second migration just to add an index REQ-035's own text already specifies. |

**How Ecto expresses the partial unique index** — verified against the same
`deps/ecto_sql` mechanics `req027-...md` §3.1.2 cited directly (not re-derived here):
`unique_index/3` is `index/3` with `[unique: true]` prepended
(`deps/ecto_sql/lib/ecto/migration.ex:1048-1052`), so `:where`/`:name`/`:prefix` are all
available on it; the predicate string is emitted verbatim after `" WHERE "`
(`deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1344`). A multi-value `IN (...)`
predicate is a single string, so it satisfies the "at most one `:where` per index" rule
(`deps/ecto_sql/lib/ecto/migration.ex:1734-1748`) without needing an `AND`-joined
compound clause.

**Deliberately not created:** a plain (non-partial) index on `(tenant_id, plan_digest)`
or `(tenant_id, status)` alone — the two partial indexes above already serve every
lookup REQ-035's own text names, and an unqualified duplicate would be the same
"redundant index" pattern `req022-...md`/`req023-...md` already establish as something
this project deliberately does not port from R-Co.

---

## 4. Migration file plan

One file, per Decision A's "one schema-defining concern per migration" convention.

| Filename (proposed) | Migration module | Creates |
|---|---|---|
| `20260816200001_create_promotion_reviews.exs` | `Letflow.Repo.Migrations.CreatePromotionReviews` | `promotion_reviews` + 2 indexes (§3.2) |

**Timestamp:** the literal value above is this design's proposal; ELIXIR-DEV may
substitute a real UTC-clock timestamp generated at implementation time, subject to two
hard constraints: (a) it sorts strictly after `20260816193002` (REQ-027's shipped
`instance_definition_snapshots` migration, the current maximum in
`priv/repo/migrations/`); (b) the **same integer** appears in the manifest edit (§5.3) —
a mismatch there silently omits this table from every tenant's schema.

### 4.1 The guard (mandatory, both halves per REQ-022 §4)

Exactly the shape `req022-...md` §4 and `req027-...md` §2.1/§4.2 already establish, with
the shipped reference `20260816193001_create_process_definitions.exs`:

```
change/0:
  if Ecto.Migration.prefix() is truthy:
      create table(:promotion_reviews, primary_key: false, prefix: prefix())
        with the columns in §3
      create unique_index(...) / create index(...) — each with prefix: prefix()
        (§3.2, both indexes)
  else:
      do nothing at all — this migration must have zero effect on the public schema
```

No `references/2` call anywhere in this file (§3.1 — no FKs), so no ordering constraint
against any other migration beyond the bare "sorts after the current maximum" rule
above.

### 4.2 Reversibility

`create table`, `create index`, `create unique_index` are all auto-reversible by
`change/0` (`backend_developer_guide.md` §3.7). No `execute/1`, no `execute/2`, no raw
SQL anywhere in this file — no raw-SQL identifier interpolation is introduced by this
requirement (relevant to SECURITY-REVIEWER's INV-7 check at Step 2c).

### 4.3 Demonstrating acceptance criterion 2

**Method (ELIXIR-DEV at Step 2a / TEST-DESIGNER at Step 3; this design specifies the
method, not the test code):** provision a tenant schema, insert a `promotion_reviews`
row with a given `(tenant_id, plan_digest)` and `status: :pending_review`, then attempt
a second insert with the identical `(tenant_id, plan_digest)` and `status:
:pending_review` (or `:approved`) — assert the second insert fails with a Postgres
`23505` unique-violation surfaced as `{:error, changeset}` via
`unique_constraint([:tenant_id, :plan_digest], name: :uq_promotion_review_active_digest)`
(§5.1). Additionally assert that once the first row's status moves to a value **outside**
`{pending_review, approved}` (e.g. `:rejected` — settable directly via `Repo.update_all`
for this test's own purposes, since REQ-037 does not exist yet at this point in the
project's history), a second insert with the same `(tenant_id, plan_digest)` **succeeds**
— proving the index's `WHERE` predicate, not a bare unconditional unique index, is what's
under test.

---

## 5. Module plan

### 5.1 `Letflow.Definitions.PromotionReview` — `lib/letflow/definitions/promotion_review.ex`

**Naming decision:** placed under `Letflow.Definitions`, alongside
`Letflow.Definitions.ProcessDefinition` and `Letflow.Definitions.InstanceDefinitionSnapshot`,
rather than a new top-level namespace (e.g. `Letflow.Promotions`). Reasoning: every
downstream requirement in this batch that operates on `promotion_reviews` is itself
named as a `Letflow.Definitions.*` function in `docs/requirements.yaml` —
`Letflow.Definitions.rollback_definition_version/4` (REQ-038),
`Letflow.Definitions.apply_promotion_assertion_rerun/6` (REQ-040),
`Letflow.Definitions.compute_pack_update_plan/5` (REQ-043) — so `promotion_reviews`'
row struct is expected to live in, and be manipulated by, the same `Letflow.Definitions`
context REQ-030 owns, not a separate context module this batch's requirements never
name. This is a naming inference from those citations, not a literal instruction in
REQ-035's own text — stated explicitly so ELIXIR-DEV/REVIEWER can correct it if a later
requirement's text contradicts it.

**Settings** (matching `process_definition.ex`'s established shape exactly):

- `@primary_key {:id, :binary_id, autogenerate: true}`.
- No `@foreign_key_type`, no `belongs_to`/`has_many` — every UUID-typed non-PK column is
  a plain `field(:x, Ecto.UUID)` (§3.1's no-FK decisions).
- No `@schema_prefix` — this table lives in many Postgres schemas, one per tenant;
  every read/write passes `prefix: schema_name` at call time (REQ-037/038's
  responsibility). Stated in the moduledoc (§7) as INV-PR-4.
- `@type t :: %__MODULE__{}` and `@type status :: :pending_review | :approved |
  :rejected | :applied | :failed | :superseded`.

**Field declarations** (declarations only, not code):

```
field(:tenant_id, Ecto.UUID)
field(:plan_digest, :string)
field(:def_type, :string, default: "process")
field(:def_id, :string)
field(:serialised_plan, :string)          # :text migration column -> :string Ecto type
field(:status, Ecto.Enum,
      values: [:pending_review, :approved, :rejected, :applied, :failed, :superseded],
      default: :pending_review)
field(:requested_by, Ecto.UUID)
field(:approved_by, Ecto.UUID)
field(:approved_at, :utc_datetime_usec)
field(:superseded_by, Ecto.UUID)
field(:row_version, :integer, default: 1)
timestamps(type: :utc_datetime_usec)
```

`:text` migration columns map to the `:string` Ecto **schema** type (Ecto has no
separate `:text` schema type, the same way it has no separate `:bigint` schema type —
`req023-...md` §5.1 makes the equivalent note for `:integer`/`:bigint`/`:bigserial`).

**Function signatures — every function this module will export, fully specified.**
Error shape is `Ecto.Changeset.t()` carrying `valid?: false` plus field errors; this
function does no I/O, so it does not return an `{:ok, _} | {:error, _}` tuple — that
boundary is `Repo.insert/2`'s, inside REQ-037's `insert_review/1`.

```
@type t :: %Letflow.Definitions.PromotionReview{}
@type status :: :pending_review | :approved | :rejected | :applied | :failed | :superseded

@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast:              [:tenant_id, :plan_digest, :def_type, :def_id,
#                        :serialised_plan, :requested_by]
#   validate_required: [:tenant_id, :plan_digest, :def_id, :serialised_plan,
#                        :requested_by]
#     -- def_type is NOT in validate_required: it carries a non-nil column default
#        ("process") and REQ-035's own text treats an explicit caller-supplied value
#        as optional, extensible free text (see def_type's row in §3 and §9 OQ-1).
#   validate_length(:plan_digest, is: 64)                          -- REQ-035 AC 1
#   validate_format(:plan_digest, ~r/^[0-9a-f]{64}\z/)             -- REQ-035 AC 1
#   validate_length(:def_id, max: 255)
#   unique_constraint([:tenant_id, :plan_digest],
#                      name: :uq_promotion_review_active_digest)   -- REQ-035 AC 2
#   NOTE: status, approved_by, approved_at, superseded_by and row_version are NOT
#   castable here — see the "functions/fields deliberately absent" note below.
```

**Fields deliberately not castable by `insert_changeset/2`, and no `update_changeset/2`
exists at all** — this list is normative; REVIEWER and CODE-DESIGN-VALIDATOR should
treat any of the following appearing in Step 2a's output as a defect:

| Absent | Why |
|---|---|
| `status` in `insert_changeset/2`'s cast list | A newly-inserted review is always `:pending_review` (the column default); REQ-035's own description gives `insert_review/1` no caller-supplied status to insert. Matches `process_definitions.status`'s precedent (`req027-...md` §5.1/INV-DEF-8) of a status column that is never directly castable from external input. |
| `approved_by` / `approved_at` / `superseded_by` in `insert_changeset/2`'s cast list | These are set only by REQ-037's transition functions, never at insert time. |
| `update_changeset/2` (any form) | **REQ-037's every state transition is a guarded single-statement `UPDATE ... WHERE id = $1 AND status = $2 AND row_version = $expected`** (REQ-037's own description: "Every UPDATE includes WHERE row_version = $expected — zero rows affected means the transition failed"), not a changeset-mediated load-then-`Repo.update/2`. A changeset-based update path here would reintroduce exactly the lost-update race that `WHERE row_version = $expected` exists to prevent — same reasoning `process_definitions` already established for its own status movement (`req027-...md` §5.1, "a load-then-update would reintroduce the lost-update race"). REQ-037 issues its guarded updates via `Ecto.Query`/`Repo.update_all`, not this module's changeset API. |
| `Ecto.Schema.optimistic_lock/2,3` (the changeset-integrated macro) | Not used, deliberately. That macro auto-increments a version field on every `Repo.update/2` call using a changeset it built internally — but REQ-037's transitions are raw `WHERE row_version = $expected` guarded updates issued via `Ecto.Query`/`Repo.update_all`, never `Repo.update/2` on a loaded struct+changeset. Using the macro here would create a second, unused optimistic-lock code path alongside the one REQ-037 actually needs, and would not match the "zero rows affected means the transition failed" contract REQ-037's text specifies (the macro raises `Ecto.StaleEntryError` instead of returning a rows-affected count). `row_version` is therefore a **plain** `field(:row_version, :integer, default: 1)`, manually read and compared by REQ-037's own queries — see §6 INV-PR-1 and §7's required moduledoc text (REQ-035 acceptance criterion 3 requires exactly this distinction be documented). |
| any `Repo.*` call, or query function | REQ-035 is schema-only; querying and writing belong to REQ-037 (transitions) and REQ-038 (rollback lookups). |

### 5.2 The one edit to `Letflow.TenantProvisioning`

`@tenant_scoped_migration_manifest` (`lib/letflow/tenant_provisioning.ex`) currently
holds nine `{version, module, filename}` entries. REQ-022 §4 requires every
tenant-scoped migration to register itself here — REQ-035 is the tenth.

```
@spec tenant_scoped_migrations() :: [{version :: pos_integer(), module()}]
```

**The `@spec` is unchanged** (matching every prior tenant-scoped requirement's edit to
this function — `req023-...md` §5.2, `req027-...md` §5.3). The manifest gains one
tenth entry:

```
{20_260_816_200_001, Letflow.Repo.Migrations.CreatePromotionReviews,
 "20260816200001_create_promotion_reviews.exs"}
```

(substituting whatever real timestamp ELIXIR-DEV actually used per §4's note, keeping
the version integer identical between the filename and this tuple).

---

## 6. Invariants

| id | Invariant | Enforced where | Source |
|---|---|---|---|
| INV-PR-1 | **`row_version` is an optimistic-locking column, not a plain audit counter.** Every state transition (REQ-037) reads the current value and issues `UPDATE ... WHERE row_version = $expected`; zero rows affected means the transition lost a race and must return the invalid-transition error, not silently retry or ignore the mismatch. | This schema's field declaration (no `optimistic_lock/2,3` macro, §5.1) + moduledoc (§7) | REQ-035 acceptance criterion 3 |
| INV-PR-2 | **One live review per `(tenant_id, plan_digest)`.** At most one row with the same `(tenant_id, plan_digest)` may be `pending_review` or `approved` at a time — this is the PRM-03 idempotency anchor. | `uq_promotion_review_active_digest` (§3.2) | REQ-035 acceptance criterion 2; REQ-035 description |
| INV-PR-3 | **`status` is never directly castable.** A newly-inserted row is always `:pending_review` (the column default); every subsequent value is set only by REQ-037's guarded `UPDATE` statements, never by a changeset. | `insert_changeset/2`'s cast list (§5.1) — no `update_changeset/2` exists | Matches `process_definitions`' established precedent (`req027-...md` INV-DEF-8) |
| INV-PR-4 | **No `@schema_prefix`.** This table lives in many Postgres schemas, one per tenant (assuming the PER_TENANT classification — see §9 OQ-2); every read/write must pass `prefix: schema_name` explicitly. | §5.1 | Decision B (`0003:37-45`) |
| INV-PR-5 | **`def_type` carries no enum, no CHECK constraint.** It is open-ended text with a `"process"` default, extensible without a schema migration — a deliberate design choice, restated as an explicit open question about whether that remains the right choice long-term. | §3's `def_type` row; §7's required moduledoc text | REQ-035 acceptance criterion 4; §9 OQ-1 |
| INV-PR-6 | **This table's PER_TENANT-vs-GLOBAL classification is not independently confirmed against an explicit R-Co source** the way `events`' classification is confirmed against `1147_par01_events_partitioning.sql`'s own comment (cited in `0003`). The migration is built PER_TENANT because REQ-035 acceptance criterion 1 mandates it, not because this design found and cites an equivalent source-of-truth statement for this specific table. | §2; §7's required moduledoc text | REQ-035 acceptance criterion 4; §9 OQ-2 |

---

## 7. Required moduledoc text (verbatim, per REQ-035 acceptance criteria 3 and 4)

REQ-035 acceptance criteria 3 and 4 each require a specific claim to appear in the
schema module's moduledoc. The text below is what must appear so CODE-DESIGN-VALIDATOR,
REVIEWER and RELEASE-VALIDATOR can check it literally rather than by paraphrase.
ELIXIR-DEV may add surrounding prose but must not weaken or omit these sentences.

### 7.1 Optimistic locking (`row_version`) — acceptance criterion 3

```
`row_version` is an optimistic-locking column, not a plain audit counter. It
starts at 1 on insert and is incremented only as part of a state-transition
UPDATE issued elsewhere (REQ-037), of the shape
`UPDATE promotion_reviews SET ..., row_version = row_version + 1
 WHERE id = $1 AND status = $2 AND row_version = $3`.
Zero rows affected by that statement means the transition lost a concurrency
race (someone else changed this row first) and must be surfaced as the
invalid-transition error, not retried or ignored. This module deliberately
does not use `Ecto.Schema.optimistic_lock/2,3` — that macro is
`Repo.update/2`-oriented and raises `Ecto.StaleEntryError`, whereas every
transition here is a raw `Ecto.Query`/`Repo.update_all` guarded update that
needs a rows-affected count, not a raised exception. There is no
`update_changeset/2` on this module for the same reason.
```

### 7.2 Open questions — acceptance criterion 4

```
Two things this schema deliberately does NOT resolve, stated here as open
questions rather than silent decisions:

1. `def_type` (default "process") carries no enum and no CHECK constraint —
   it is open-ended text, extensible without a schema migration, per prm-04's
   own Open Question 1 (as cited by this table's owning requirement,
   REQ-035, in docs/requirements.yaml -- this module has no direct access to
   R-Co's own src/design/prm-04-promotion-review-state-machine.md, which
   lives outside this repository). Whether a CHECK constraint restricting
   the value set should be added once the set of legal def_types is known
   is left open.

2. This table's PER_TENANT-vs-GLOBAL classification is NOT independently
   confirmed against an explicit source the way `events`/`events_archive`'s
   classification is confirmed against 1147_par01_events_partitioning.sql's
   own comment (cited in docs/migration/decisions/0003-ecto-schema-strategy.md).
   The migration builds this table schema-per-tenant (via REQ-022's :prefix
   mechanism) because REQ-035's acceptance criteria mandate it, consistent
   with Decision B's general rule for business tables -- but neither 0003
   nor any design doc states this table's classification explicitly the way
   0003 does for events. REVIEWER should re-confirm this classification is
   correct rather than treat its presence here as settled fact.
```

---

## 8. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Repo` | schema → Repo | Only at REQ-037/038 call time. REQ-035 adds no `Repo` call of its own. |
| `Letflow.TenantProvisioning` | REQ-035 → REQ-022 | REQ-035 edits `@tenant_scoped_migration_manifest`/`tenant_scoped_migrations/0`'s tenth entry (§5.2), the mandated one-line-scope edit `req022-...md` §4 requires of every tenant-scoped requirement. No other shipped REQ-022 code changes; the `@spec` stays identical. |
| `Letflow.TenantProvisioning.Registration` | REQ-037/038 → REQ-022 | Source of the `schema_name` every `promotion_reviews` query/write must pass as `prefix:` (INV-PR-4). |
| `priv/repo/migrations/` | REQ-035 → shared directory | Adds one file. Modifies none of the existing ten migrations. |
| REQ-036 (`compute_promotion_plan/5`, `compute_plan_digest/1`) | REQ-037 → REQ-036 | REQ-037's `insert_review/1` is the actual consumer of REQ-036's output (`serialised_plan`, `plan_digest`) into this table's columns. REQ-035 itself takes no dependency on REQ-036 beyond matching the column shapes REQ-035's own text already specifies. |
| REQ-037 (state machine) | REQ-037 → REQ-035 | Consumes every column and both indexes; contract points REQ-037 must honour: `row_version`'s manual-optimistic-lock contract (INV-PR-1), `status`'s never-castable-by-changeset contract (INV-PR-3), the partial unique index's exact predicate (INV-PR-2). |
| REQ-038 (rollback) | REQ-038 → REQ-035 | Consumes `idx_promotion_review_rollback_lookup` for its superseded-lookup queries (§3.2). |
| `docs/agents/instructions/security-invariants.md` INV-7 | SECURITY-REVIEWER → REQ-035 | Satisfied by §4.2 — REQ-035 introduces zero raw-SQL identifier interpolation. |

---

## 9. Open questions — explicit, not silently resolved

**OQ-1 (as required by REQ-035 acceptance criterion 4): `def_type`'s open-ended
text-vs-CHECK-constraint choice.** REQ-035's own text instructs building `def_type` as
a plain `:string` with a `"process"` default and explicitly "no CHECK constraint
restricting the value set for now," citing prm-04's own "Open Question 1." This design
follows that instruction literally (§3, §5.1) and restates the question in the
moduledoc per §7.2 rather than resolving it — whether/when a CHECK constraint (or an
`Ecto.Enum`) should be added once the full set of legal `def_type` values is known (this
project has so far only ever promoted `process`-kind definitions; whether sub-processes,
service catalogs, or other definition kinds will ever flow through this same table is
not settled by anything this design has access to) is left for a future requirement.

**OQ-2 (as required by REQ-035 acceptance criterion 4): PER_TENANT-vs-GLOBAL
classification is not independently confirmed.** Discussed in full in §2 and restated
in the required moduledoc text (§7.2). Restated compactly here for the open-questions
list: unlike `events`/`events_archive` (whose PER_TENANT classification `0003` cites
directly against `1147_par01_events_partitioning.sql`'s own comment), no source this
design has access to makes an equivalent explicit statement for `promotion_reviews`.
The migration is built PER_TENANT because REQ-035's own acceptance criterion 1 mandates
it — that part is not in question. What is in question is whether that classification
is *correct* on the merits, given this table's structurally unusual shape for a
per-tenant table (a single `tenant_id` column despite modeling a cross-tenant operation
with both a source and target tenant, per REQ-036's `compute_promotion_plan/5` taking
`source_tenant_id`/`target_tenant_id` as separate arguments). This design's working
assumption — stated as an assumption, not a finding — is that the single `tenant_id`
column names the **target** tenant (the one whose schema this row lives in and whose
approval gate this table implements), with `source_tenant_id` presumably carried inside
`serialised_plan`'s JSON rather than getting its own column. REVIEWER should
re-confirm this at Step 2d, per REQ-035's own instruction that this be flagged rather
than silently treated as settled.

**OQ-3 (MINOR, surfaced by this design, not named in REQ-035's text): what does
`superseded_by` reference?** REQ-035's column list gives `superseded_by (binary_id,
nullable)` with no further specification of what it points at. A plausible reading is
that it is a self-reference to another `promotion_reviews.id` (the review that
superseded this one) — REQ-037's `supersede_review/2` is the function that will
actually populate it — but this design does not assert that reading as fact, and
deliberately does not add a self-referential FK on a guessed target (§3.1). REQ-037's
own design should state this column's semantics explicitly before writing
`supersede_review/2`, rather than inheriting an unstated assumption from this document.

**OQ-4 (MINOR): should `def_id`/`def_type` get a narrower length bound than the implicit
`varchar(255)` default?** REQ-035's text names no bound narrower than the implicit one
Ecto's `:string` migration type already provides. Not extended speculatively — if
REQ-036/037 later need a narrower one (e.g. to match `process_definitions.name`'s
business-rule bound exactly), that is a follow-up changeset edit, not a schema/migration
change.

**OQ-5 (INFORMATIONAL, not unresolved — a stated design choice): `timestamps()`
precision.** REQ-035's text says only "timestamps()," with no type specified. This
design chose `type: :utc_datetime_usec` to match every other business/event-store table
built so far in this project, rather than falling back to the repo's unconfigured
`:naive_datetime` default. Recorded here so it reads as a deliberate consistency choice
if ever questioned, not a gap.

---

## 10. Acceptance-criteria traceability

| REQ-035 acceptance criterion | Concrete design element |
|---|---|
| 1. "priv/repo/migrations gains a promotion_reviews migration (schema-per-tenant per REQ-022) applying cleanly, with status as an Ecto.Enum over exactly the 6 named values" | §3 (full column table, `status` row) + §4 (migration file plan, the mandatory `:prefix` guard) + §5.1 (bare atom-list `Ecto.Enum`, all 6 values named) |
| 2. "the partial unique index on (tenant_id, plan_digest) WHERE status IN ('pending_review', 'approved') exists and is demonstrated to reject a second pending_review insert with the same (tenant_id, plan_digest) while a first is still pending_review or approved" | §3.2 (`uq_promotion_review_active_digest`, exact predicate) + §4.3 (demonstration method) + §5.1 (`unique_constraint/3` mapping the 23505 error) + INV-PR-2 |
| 3. "row_version defaults to 1 and the schema module documents it as an optimistic-locking column, not a plain counter" | §3 (`row_version` row, `default: 1`) + §5.1 (no `optimistic_lock/2,3` macro, no `update_changeset/2`, explained) + §6 INV-PR-1 + §7.1 (required verbatim moduledoc text) |
| 4. "the moduledoc flags def_type's open-ended text-vs-CHECK-constraint choice and the PER_TENANT-vs-GLOBAL classification as explicit open questions, per prm-04's own Open Question 1 and this requirement's description" | §7.2 (required verbatim moduledoc text, both points) + §9 OQ-1 and OQ-2 (full discussion) + §6 INV-PR-5/INV-PR-6 |

**The description's "and an index on (tenant_id, status) WHERE status IN ('applied',
'superseded') (for PRM-08 rollback's superseded-lookup queries)" clause** — named in
REQ-035's description but not itself a numbered acceptance criterion — is built at
§3.2 (`idx_promotion_review_rollback_lookup`) and cross-referenced to its future
consumer (REQ-038) in §8.
