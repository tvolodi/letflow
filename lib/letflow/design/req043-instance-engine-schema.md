# Design: REQ-043 — Instance-engine schema (`instance_projections` ALTER, `tasks`, `tokens`)

**Requirement:** REQ-043 (`docs/requirements.yaml`, stage S3, per this run's handoff
`context.requirement_text`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ043-20260818`, WF-02 Step 1
**This document produces:** three migration specs, two new `Ecto.Schema` modules
(`Letflow.Engine.Task`, `Letflow.Engine.Token`), the required update to the existing
`Letflow.EventStore.InstanceProjection` schema module, the tenant_id-derivation
contract (reusing an already-shipped function, not inventing a new one), the resolved
tokens-table question, invariants, and open questions — **no implementation code**. No
function bodies, no `.ex` files. Pseudocode/algorithm-shape only, matching the
convention `req025-event-append.md` §0 and `req030-definition-store-crud.md` §0
established — ELIXIR-DEV writes the real version at Step 2a.

---

## 0. Sources read for this design

**Letflow project docs, read in full or by targeted section:**

- This run's handoff (`handoffs/WF02-REQ043-20260818/step-01-code-designer.json`) —
  `context.requirement_text` (REQ-043's full description) and `task.acceptance_criteria`,
  per `core-directives.md`'s "Load Scoped Context, Not Whole Files."
- `docs/agents/workflows/WF-02_requirement_implementation.md`, Step 1's procedure.
- `docs/guides/backend_developer_guide.md` — §2 (project structure), §3.1 (naming),
  §3.7 (migrations: additive/reversible, `binary_id` PK, `null: false`, `timestamps/1`,
  FK-column index), §5 (multi-tenancy, schema-per-tenant, Decision B).
PROVENANCE (historical, not current decision authority):
- `docs/migration/stage-3-instance-engine.md` — full file. Confirms REQ-043's own scope
  boundary ("`tasks`/`tokens` tables ... created by REQ-043 because the engine cannot
  activate or complete a task without them, but `src/tasks/store.zig`'s standalone task
  query/list surface ... is not ported here") and the closing "Decisions" section's
  confirmation that all three REQ-043 tables follow Decision B via REQ-022's `:prefix`
  mechanism, none GLOBAL, none needing REQ-041's flagging.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — Decision B (schema-per-tenant)
  and its 2026-08-17 addendum (tenant_id derivation mechanism: reverse
  `schema_name_for_tenant/1`, never accept a caller-supplied `tenant_id`).
- `priv/repo/migrations/20260816120003_create_instance_projections.exs` — **read in
  full**. Confirms the exact "COLUMNS DELIBERATELY NOT CREATED HERE" list this
  requirement must add, confirms the `if prefix() do` guard shape, confirms the existing
  `idx_proj_status` index (untouched by this requirement), and confirms `status`'s
  `Ecto.Enum` already carries `error: "ERROR"`.
- `lib/letflow/event_store/instance_projection.ex` — **read in full**. Confirms the
  shipped schema's exact field list, `@primary_key {:instance_id, :binary_id,
  autogenerate: false}`, the keyword-mapping `Ecto.Enum` form
  (`values: [active: "ACTIVE", completed: "COMPLETED", cancelled: "CANCELLED", error:
  "ERROR"]`), `insert_changeset/2`/`update_changeset/2`'s exact cast/required lists, and
  `terminal?/1`.
- `lib/letflow/tenant_provisioning.ex` — **read directly**. Confirms
  `tenant_id_for_schema_name/1`'s exact shipped `@spec` and algorithm (lines 100–115:
  total, pure, pattern-matches `"tenant_" <> 32-lowercase-hex`, returns `{:ok,
  tenant_id} | {:error, :invalid_schema_name}`), and the `@tenant_scoped_migration_manifest`
  list (lines 250–273, eleven entries, three-element `{version, module, filename}` form,
  ordered by version — the newest is `20_260_818_090_001`).
- `lib/letflow/design/req025-event-append.md` §3–§4 — the tenant_id-derivation contract
  `Letflow.EventStore.append/2` established: `attrs` never accepts a `:tenant_id` key
  (hard `{:error, :tenant_id_not_accepted}`); tenant_id is derived once, by the *calling
  context module*, from `opts[:prefix]` via `tenant_id_for_schema_name/1`, then merged
  into the changeset's `attrs` before the schema module's own `insert_changeset/2` casts
  it — the schema module itself does not derive anything.
- `lib/letflow/design/req030-definition-store-crud.md` §3 — confirms the identical
  contract reused verbatim by a second context module (`Letflow.Definitions`), including
  the explicit instruction "follow the same shape for consistency across the codebase,
  don't invent a third pattern."
- `lib/letflow/definitions/process_definition.ex` — read directly for a second
  `Ecto.Enum`-on-a-business-table precedent (bare atom-list form, lowercase dump) and its
  moduledoc's "no `@schema_prefix`" / "`status` never castable from caller input"
  sections, used as the shape precedent for this design's own moduledoc requirements.
- `priv/repo/migrations/20260816193002_create_instance_definition_snapshots.exs` and
  `…120004_create_event_payload_store.exs` — **read in full**. Both are the direct
  precedent for: (a) `references/2` with `type: :binary_id` mandatory, `column:`
  explicit, no `:prefix:` option (falls back to the referencing table's own prefix); (b)
  a *deliberate, reasoned* `on_delete:` divergence from R-Co's `ON DELETE CASCADE`,
  written as `:restrict` or `:nothing` with the reasoning stated in the migration header,
  not silently ported; (c) an index on the FK-referencing column even when R-Co's own SQL
  doesn't have one, because "Postgres does not automatically index the REFERENCING side
  of a foreign key" (`…120003`'s own comment, restated at `…193002:109-112`); (d) the
  citation-dense migration-header style this design's own migrations (§4) must follow.

**R-Co source (`C:\Users\tvolo\dev\ai-dala\R-Co\`), reachable this session — read
directly, not assumed:**

- `migrations/005_instances.sql` (full file, 102 lines) — the `tokens` and `tasks` table
  DDL, both index sets, and the Stage-6 `instance_projections` `ALTER TABLE` (out of
  REQ-043's scope — `parent_instance_id`/`parent_token_id`/`result_variables` belong to
  a future sub-process requirement, REQ-062, not this one).
- `migrations/001_event_store.sql:78-107` — the authoritative source for §1's exact
  `instance_projections` column list, both index definitions, and confirmation that
  `definition_id` carries **no** `REFERENCES` clause (bare `UUID NOT NULL`) — read
  directly rather than assumed, because `instance_definition_snapshots.definition_id`
  *does* carry one and this design must not silently harmonize the two.
- `src/design/engine.md` — **Section EE-01** (`## Section EE-01: Start Instance`, full
  read: §1a's column table verbatim-matches `001_event_store.sql`; §1a's "Note on
  `initial_variables`" — `variables` is seeded from the caller-supplied value at INSERT
  time, no separate column; step d's INSERT statement, which seeds `current_nodes` as
  `'[]'` literally at instance-start time), **Section EE-02** (`## Section EE-02: Pure
  Transition Function`, full read: §1 `InstanceState`, §2 `Token` struct — **exactly two
  fields, `node_id` and `branch_id`**, no `token_id`, no `waiting_child_instance_id` on
  the in-memory struct as currently written), **Section EE-03** (`## Section EE-03: Task
  Activation`, full read to line 1494: §1a's `tasks` column table, §3's `Task` struct —
  which *does* carry a `token_id: Uuid` field distinct from the in-memory `Token`'s own
  shape, §5's `TaskStore.createInTx/8` signature, §6's `applyTransition` persistence
  algorithm), and **Section EE-06 / EE-07** (`## Section EE-06: Parallel Gateway —
  Split`, `## Section EE-07: Parallel Gateway — Join`, read through the join's expected-
  branch-set derivation, §3's "Existing `Token` struct — no additions required ...
  BACKEND-DEV SHALL NOT add new fields to `Token` for this requirement").

**A genuine internal inconsistency found in `engine.md` itself, flagged rather than
silently resolved (load-bearing for §5 below):** EE-03 §6 Step f
(`src/design/engine.md:1451-1456`) calls `find_token_on_node(new_state.tokens, node_id)`
and then reads `token.id` to populate `TaskStore.createInTx`'s `token_id` parameter — but
EE-02 §2's `Token` struct (`engine.md:521-533`), which is what `new_state.tokens` is
typed as, has only `node_id` and `branch_id`; it has no `id` field. This is R-Co's own
design document disagreeing with itself across two sections, not a Letflow porting
error — confirmed by reading both sections directly rather than trusting either
secondhand. §5.1 below is where this design resolves what that gap implies for Letflow's
own `tokens` table.

**The requirement text's own parenthetical — "engine.md section EE-02 2 defines Token as
an in-memory value (node_id/branch_id/token_id/waiting_child_instance_id)" — does not
match the primary source as directly read.** `engine.md`'s current EE-02 §2 defines
`Token` with exactly `node_id`/`branch_id` (§0 above). This design flags the mismatch
(§9 OQ-1) rather than silently trusting either account, and treats the *task-brief's*
paraphrase as a signal of what future requirements (REQ-051, REQ-062) will need from a
**persisted** token representation — which is a different question from what the
**in-memory, pure-function** `Token` struct currently carries — and resolves the
persisted-schema question on that basis (§5).

---

## 1. Scope boundary

**In scope (this requirement):**
1. One `ALTER TABLE` migration on `instance_projections` (§2).
2. One new `tokens` table + `Letflow.Engine.Token` Ecto schema module (§3, §5).
3. One new `tasks` table + `Letflow.Engine.Task` Ecto schema module (§4).
4. The corresponding update to `Letflow.EventStore.InstanceProjection` (§2.3) so the
   seven new columns are actually reachable through Ecto, not just present at the DB
   layer with no schema-level access path.
5. Three new entries in `Letflow.TenantProvisioning.@tenant_scoped_migration_manifest`
   (§6).

**Explicitly NOT in scope, not silently dropped:**

PROVENANCE (historical, not current decision authority):
| Not built here | Owned by |
|---|---|
| Any write path that populates these columns/rows (instance start, task activation, task completion, token creation/advance) | REQ-045 (EE-01 instance store), REQ-046 (generalization/rewiring), REQ-051 (EE-06/EE-07 split/join), REQ-062 (SPC-01 sub-process) — all future S3 requirements |
| `src/tasks/store.zig`'s standalone task query/list surface (`TaskStore.list/6`'s equivalent — filtering by `instance_id`/`status`/`assignee_ref`, pagination) | S4's tasks routes, or its own later requirement — per `docs/migration/stage-3-instance-engine.md`'s own scope-boundary paragraph |
| Stage-6 sub-process columns on `instance_projections` (`parent_instance_id`,
  `parent_token_id`, `result_variables`) — R-Co adds these in the *same* `005_instances.sql`
  file, but they are SPC-01/REQ-062 territory per the stage doc's own REQ-062 framing, not
  EE-01's "COLUMNS DELIBERATELY NOT CREATED HERE" list this requirement is scoped to | REQ-062 |
| `TaskStore.createInTx/8`-equivalent, `applyTransition`-equivalent, any join-counter
  logic, any status-transition guard (`PENDING → COMPLETED`, etc.) | REQ-045/051 (context-module functions, not schema) |
| HTTP/Plug route layer (`POST /tasks/:id/complete`, `GET /instances/{id}/pins`, etc.) | S4 |

---

## 2. `instance_projections` — `ALTER TABLE` (EE-01 §1a, `001_event_store.sql:81-95`)

### 2.1 Exact column list

All seven columns are named by REQ-023's migration header (§0) and verified against
`001_event_store.sql:81-95` directly:

| Column | Type | Null | Default | Note |
|---|---|---|---|---|
| `definition_id` | `:binary_id` | `null: false` | none | **No `references/2`** — see §2.2 |
| `correlation_key` | `:string` | nullable | none | |
| `current_nodes` | `:map` | `null: false` | `[]` | jsonb array — §2.4 flags an Ecto-cast nuance |
| `variables` | `:map` | `null: false` | `%{}` | jsonb object, matches `events.payload`'s established `:map, default: %{}` idiom |
| `error_detail` | `:map` | nullable | none | |
| `completed_at` | `:utc_datetime_usec` | nullable | none | |
| `cancelled_at` | `:utc_datetime_usec` | nullable | none | |

**Migration shape** (this is the shape, not literal code — ELIXIR-DEV writes the real
file, following the guard pattern `req023-event-store-schema.md` §2.2 already
establishes for every tenant-scoped migration in this schema):

`change/0`: if `Ecto.Migration.prefix()` is truthy, alter the `instance_projections`
table, scoped to that prefix, adding the seven columns listed in the §2.1 table above —
in order, each with exactly the type/null/default already specified there. Then, still
scoped to that same prefix, create two indexes: a unique index on
`(definition_id, correlation_key)`, named `uq_instance_correlation`, restricted by the
partial-index predicate `correlation_key IS NOT NULL`; and a plain index on
`(definition_id)`, named `idx_proj_definition`. If `Ecto.Migration.prefix()` is falsy
(i.e. this migration is running against the default/public schema), the migration must
do nothing at all — zero effect on `public`, identical to every other tenant-scoped
migration's guard.

Both index names and shapes are copied verbatim from `001_event_store.sql:98-107` — the
existing `idx_proj_status` index (already shipped by REQ-023) is untouched.

### 2.2 No FK on `definition_id`, confirmed rather than assumed

`process_definitions` already exists in Letflow (REQ-027, shipped, and this migration's
version necessarily sorts after it), so a real `references(:process_definitions, ...)`
constraint is *technically* possible here, unlike in R-Co where `001_event_store.sql`
predates `004_definitions.sql` in migration order. **This design does not add one.**
`001_event_store.sql:83` declares `definition_id UUID NOT NULL` with no `REFERENCES`
clause — confirmed by direct read (§0), matching the discipline
`…193002_create_instance_definition_snapshots.exs`'s own header sets ("confirmed
absent, not invented") rather than "completing" an asymmetry R-Co itself left. Unlike
`instance_definition_snapshots.definition_id` (which R-Co's `004:61` genuinely does
reference), `instance_projections.definition_id` has no such reference anywhere in
R-Co's source this design has access to. **Flagged as OQ-2 (§9), not silently added**:
REVIEWER may decide a real FK is a worthwhile Ecto-idiomatic correction (Decision A), but
that is a reasoned divergence this design declines to make unilaterally, matching the
"exactly the columns" framing of REQ-043's own text.

### 2.3 Required update to `Letflow.EventStore.InstanceProjection`

**Not explicitly named as a separate deliverable in REQ-043's acceptance criteria, but
structurally required** — an `ALTER TABLE` that adds columns invisible to the shipped
`Ecto.Schema` module (`lib/letflow/event_store/instance_projection.ex`) would leave the
migration inert: no `Repo.insert`/`Repo.update`/`Repo.get` call anywhere could read or
write these seven columns without the schema module also declaring them. This is the
same "the migration and the schema module are one deliverable" pattern REQ-023 already
followed for its own six migrations. Scoped narrowly here — structural field/changeset
additions only, **no new business logic, no new public function, no validation beyond
`cast`/`validate_required`** (the actual write-path logic belongs to REQ-045/051/062, per
§1's scope table).

**Field additions** (shape, not literal code — added inside the existing
`schema "instance_projections" do` block, after the existing four fields): seven new
fields, one per §2.1 column, each declared with the Ecto type that column's migration
type maps to and the same default where the column has one — `definition_id` as
`Ecto.UUID`; `correlation_key` as a plain string field with no default; `current_nodes`
as a map-typed field defaulting to an empty list; `variables` as a map-typed field
defaulting to an empty map; `error_detail` as a map-typed field with no default;
`completed_at` and `cancelled_at` each as `:utc_datetime_usec` fields with no default.

**Changeset updates:**

- `insert_changeset/2`: cast list grows to `[:instance_id, :tenant_id, :status,
  :last_event_seq, :definition_id, :correlation_key, :current_nodes, :variables]`
  (`error_detail`/`completed_at`/`cancelled_at` are never set at insert time — they are
  ERROR/COMPLETED/CANCELLED-transition-only, matching R-Co's own "set on ERROR status"/
  "set on completion" column comments). `validate_required` grows to include
  `:definition_id` (matches the DB's own `null: false`); `correlation_key`,
  `current_nodes`, `variables` are **not** added to `validate_required` — `current_nodes`/
  `variables` have schema-level defaults (`[]`/`%{}`) that satisfy the DB's own
  `null: false` without the caller supplying them, and `correlation_key` is genuinely
  optional (EE-01's own nullable field).
- `update_changeset/2`: cast list grows to `[:status, :last_event_seq, :current_nodes,
  :variables, :error_detail, :completed_at, :cancelled_at]` — **`definition_id` and
  `correlation_key` are deliberately excluded**, for the identical reason
  `instance_id`/`tenant_id` already are (this module's own moduledoc: "a projection
  never changes which instance or tenant it describes" — extended here to "or which
  definition it was started from, or its correlation key," both immutable after EE-01
  insert).
- `terminal?/1` is unchanged — `req023`'s own module already restricts it to
  `:completed`/`:cancelled`.

**Moduledoc update, required content (not verbatim-mandatory, but every point below must
appear in substance):**

1. Replace the existing "## Scope (REQ-023 acceptance criterion 5)" section's closing
   paragraph (which currently lists the seven columns as "deliberately not created
   here") with a statement that REQ-043 has now added them — the table's *columns* exist
   and are Ecto-accessible, but **meaningful population remains EE-01/S3's write-path
   job** (REQ-045+, not this schema-only requirement) — do not read this schema edit as
   the instance-engine's write logic landing early, the same caution REQ-023's own
   moduledoc already states for the migration itself.
2. State the confirmed absence of a `definition_id` FK constraint (§2.2), so a future
   reader doesn't assume one exists from the field's name alone.
3. State the `current_nodes`/`variables` cast nuance (§2.4) so a future write-path
   author (REQ-045+) doesn't get an unexplained changeset failure.

### 2.4 Open technical nuance — `current_nodes`'s Ecto field type (flagged, not resolved by guessing)

`current_nodes` is a `jsonb` column holding a JSON **array** (`'[]'` default, "active
token positions"), unlike `variables`/`error_detail` which hold JSON **objects**. This
design specifies the schema field as `field(:current_nodes, :map, default: [])`
(matching the migration's `:map` column type, §2.1) because that is what the existing
codebase convention would produce (`process_definitions.graph` is also `:map` despite
containing nested arrays internally) — but this design cannot verify empirically (no
compiler/test run available to CODE-DESIGNER) whether `Ecto.Changeset.cast/3` accepts a
**list** value for a `:map`-typed field. Ecto's built-in `:map` type's `cast/1`
implementation is commonly guarded by `is_map/1`, which a JSON-array value (an Elixir
`list`) would fail — `load/2` (reading already-trusted DB rows back into a struct) does
not carry the same guard, so **reading** `current_nodes` back from the DB is expected to
work regardless. **Flagged for REQ-045's own CODE-DESIGNER/ELIXIR-DEV to verify at
implementation time** (§9 OQ-3): if `cast(attrs, [:current_nodes])` rejects a list value
in practice, the write path must use `Ecto.Changeset.put_change/3` for that one field
instead of routing it through `cast/3` — a normal, established Ecto idiom for this exact
situation, not a defect in this design if it turns out to be needed.

---

## 3. `tokens` table — resolved: **BUILD it**, not dropped, not silently kept

### 3.1 The question, and why it doesn't resolve itself from EE-02 alone

R-Co's own `engine.md` **as currently written** computes join/split logic entirely from
the *in-memory* `Token{node_id, branch_id}` list, persisted as a flat `current_nodes`
JSONB array on `instance_projections` (EE-01 §1a's "active token positions"; EE-06 §3
explicitly states "no additions required" to `Token` and forbids adding fields).
Read in isolation, EE-02/EE-06/EE-07 alone would suggest `current_nodes` is
sufficient and a separate `tokens` table is redundant. **This is not the whole picture**,
for three independently sufficient reasons:

1. **`tasks.token_id` is a mandatory `NOT NULL` column this same requirement must build
   (§4).** A Postgres foreign key must reference a real row with a unique/primary key —
   a JSONB array element inside `instance_projections.current_nodes` cannot serve as an
   FK target. Some physical row-with-an-`id`, addressable by a stable primary key,
   **must exist** for `tasks.token_id` to reference at all, independent of anything
   EE-02/EE-06/EE-07 need. This alone forces the table into existence.
2. **R-Co's own physical schema independently reaches the identical conclusion.**
   `migrations/005_instances.sql:9-31` builds a real `tokens` table with a real `id`
   primary key, specifically because R-Co's own `tasks.token_id` (`005:53`) is `NOT NULL
   REFERENCES tokens(id)` — the exact same structural forcing function as point 1,
   confirmed by direct read rather than inferred. R-Co did not build this table because
   `current_nodes`/the in-memory `Token` were insufficient for split/join logic on their
   own terms; it built it for the FK, then (per §0's flagged inconsistency) its own
   `applyTransition` design leans on a `token.id` field the in-memory `Token` struct
   doesn't actually define — evidence that even R-Co's own design intends a persisted,
   identity-bearing token row distinct from the pure function's transient value.
3. **REQ-051 (EE-06/EE-07) and REQ-062 (SPC-01) both need a durable, queryable,
   lockable per-token record that a flat JSONB array on a different table's row cannot
   provide**, even if the pure `transition/4`-equivalent function itself never touches
   it: R-Co's own `idx_token_active`/`idx_token_waiting` partial indexes
   (`005_instances.sql:36-43`) only make sense against a real table with per-row
   `status`/`gateway_id` columns — you cannot put a partial index predicate on an
   element inside a JSONB array. REQ-051's join-counter persistence layer (not built by
   this requirement, but a real future consumer of this table) and REQ-062's
   parent-instance-wait tracking (`waiting_child_instance_id`, named explicitly in this
   run's task brief) both need exactly this shape.

**Decision: BUILD the `tokens` table.** `instance_projections.current_nodes` remains the
engine's authoritative, fast-read summary of active token positions (unchanged from
EE-01/EE-02's own design — this requirement does not touch how EE-01/EE-02 use it). The
physical `tokens` table this requirement adds is the **identity and lifecycle** side
table that (a) gives `tasks.token_id` a real FK target, and (b) gives REQ-051/REQ-062 a
place to persist per-token status/lineage/lock state if their own designs choose to use
it — this requirement does not decide *how* REQ-051/062 keep the two representations in
sync (§9 OQ-4, explicitly not silently resolved here, since that's a write-path design
question outside REQ-043's schema-only scope).

### 3.2 Column list

Base columns per this run's task text (`id`, `instance_id`, `node_id`, `branch_id`),
plus the columns R-Co's own `tokens` table (`005_instances.sql:9-31`) carries that
REQ-051/REQ-062 will need and that this design can name now without inventing new
requirements-worth of behavior:

| Column | Type | Null | Default | Rationale |
|---|---|---|---|---|
| `id` | `:binary_id` (PK) | `null: false` | none | FK target for `tasks.token_id` (§3.1 point 1) |
| `tenant_id` | `:binary_id` | `null: false` | none, never cast from caller attrs | §5.2; matches `instance_projections`/`events`/`events_archive` — the "adp-02" six-table tenant_id list `…193002`'s own header cites by name includes `tokens` explicitly |
| `instance_id` | `:binary_id` | `null: false` | none | FK → `instance_projections(instance_id)`, §3.3 |
| `node_id` | `:string` | `null: false` | none | Current node the token occupies — matches EE-02's in-memory `Token.node_id` naming (R-Co's own table instead calls this `current_node`; this design uses `node_id` because the task brief names it explicitly and it keeps the DB column name aligned with the in-memory struct's field name for whichever future requirement maps between them) |
| `branch_id` | `:string` | `null: false` | none | Matches EE-02's `Token.branch_id` exactly (root branch = `instance_id` hex; split branch = the deterministic `"<instance_id_hex>/<gateway_node_id>/<edge_index>"` scheme, EE-06 §3) |
| `status` | `Ecto.Enum` | `null: false` | `:active` | `values: [:active, :waiting, :completed, :cancelled]` — bare atom-list form (lowercase dump), matching R-Co's own lowercase `'active'\|'waiting'\|'completed'\|'cancelled'` (`005_instances.sql:16-17`) directly, **not** harmonized with `tasks.status`'s uppercase convention (§4.2) — R-Co itself uses different casing for the two tables in the same migration file, confirmed by direct read, not silently unified |
| `parent_token_id` | `:binary_id` | nullable | none | Self-referencing FK → `tokens(id)`, §3.3 — join/split lineage |
| `gateway_id` | `:string` | nullable | none | The `PARALLEL_GATEWAY` node ID this token was created by or is waiting at — materialized rather than requiring every future query to string-parse `branch_id`'s `/`-delimited segments (EE-07 §1a's own correlation method), matching R-Co's column of the same name and purpose |
| `waiting_child_instance_id` | `:binary_id` | nullable | none | REQ-062/SPC-01's parent-token wait marker — named explicitly in this run's task text; renamed from R-Co's `child_instance_id` (`005:25`) to match the task brief's own naming and to be self-documenting about *why* the field is set (a token parked waiting on a sub-process child, not merely "linked to" one) |
| — | — | — | — | `data JSONB DEFAULT '{}'` (R-Co's generic per-token scratch field, `005:27`) is **deliberately not ported** — no acceptance criterion or named future requirement (REQ-051, REQ-062) has stated a need for it, and adding unused surface now would be exactly the "TBD"/speculative-column pattern this design avoids. If REQ-051/062 need it, that's a small additive `ALTER TABLE` at that point, not a gap. |

`timestamps(type: :utc_datetime_usec)` (`inserted_at`/`updated_at`), plus explicit
`completed_at` and `cancelled_at` (`:utc_datetime_usec`, nullable) — symmetry with
`tasks` (§4.2) and `instance_projections`, and R-Co's own `tokens.completed_at`
(`005:29`); `cancelled_at` is added even though R-Co's `tokens` table lacks one,
because R-Co's `tokens.status` enum already includes `'cancelled'` with no timestamp to
match it — the same completed_at/cancelled_at pairing every other lifecycle table in
this schema already carries (`tasks`, `instance_projections`) is extended here for
consistency, not left asymmetric.

### 3.3 Foreign keys and indexes

**Migration shape** (shape, not literal code — same guard pattern as §2.1/`req023`
§2.2): `change/0`: if `Ecto.Migration.prefix()` is truthy, create the `tokens` table,
scoped to that prefix, with no implicit primary key (the explicit `id` column below
serves as primary key instead), holding the columns from the §3.2 table above in
order: `id` (`:binary_id`, primary key); `tenant_id` (`:binary_id`, `null: false`);
`instance_id` (`:binary_id`, `null: false`, a foreign key to
`instance_projections`'s `instance_id` column, `on_delete: :restrict`); `node_id` and
`branch_id` (both `:string`, `null: false`); `status` (plain `:string` at the migration
layer — the `Ecto.Enum` mapping lives at the schema layer, §3.2 — `null: false`,
defaulting to the string `"active"`); `parent_token_id` (a nullable, self-referencing
foreign key to `tokens`'s own `id` column, `on_delete: :restrict`); `gateway_id`
(nullable `:string`); `waiting_child_instance_id` (nullable `:binary_id`);
`completed_at` and `cancelled_at` (both nullable `:utc_datetime_usec`); and the
standard `inserted_at`/`updated_at` timestamp pair at `:utc_datetime_usec` precision.
Still scoped to the same prefix, create two indexes: a plain index on
`(instance_id)`, named `idx_token_instance`; and a partial index on
`(parent_token_id)`, named `idx_token_parent`, restricted by the predicate
`parent_token_id IS NOT NULL`. If `Ecto.Migration.prefix()` is falsy, the migration
does nothing at all, matching every other tenant-scoped migration's guard.

**`on_delete: :restrict` on both FKs, deliberately diverging from R-Co's `ON DELETE
CASCADE`** (`005_instances.sql:12`, `:20` for `parent_token_id`'s implicit no-action —
actually only `instance_id`'s FK carries R-Co's explicit `CASCADE`; `parent_token_id`
carries none). This design applies `:restrict` uniformly to both, following the exact
reasoning `…120004_create_event_payload_store.exs`'s header already established for this
codebase: no requirement anywhere in Letflow builds a delete path for
`instance_projections` rows, so cascading deletes through `tokens` are presently
unreachable in practice — `:restrict` is the defensively safer default that fails loudly
if a future requirement ever does add instance deletion, rather than silently deleting a
tenant's token history. `idx_token_instance` and `idx_token_parent` are added per
`…193002`'s own stated reasoning ("Postgres does not automatically index the
REFERENCING side of a foreign key") — `idx_token_parent` is partial
(`WHERE parent_token_id IS NOT NULL`) matching `idx_proj_parent`'s identical shape in
`005_instances.sql:99-101` for the same reason (most tokens are root-branch tokens with
no parent).

**R-Co's `idx_token_active`/`idx_token_waiting` (`005:36-43`) are deliberately not
built here** — both are query-optimization indexes for join/cancellation logic this
requirement doesn't implement (REQ-051's own job); adding them now, ahead of the query
shapes REQ-051 will actually issue, risks guessing wrong on the predicate/column order.
Flagged for REQ-051's own CODE-DESIGNER, not silently dropped (§9 OQ-4 covers this).

---

## 4. `tasks` table

### 4.1 Column list

Per this run's task text (b), verified against `engine.md`'s EE-03 §1a
(`engine.md:1116-1144`) and `005_instances.sql:49-77` — both agree exactly:

| Column | Type | Null | Default |
|---|---|---|---|
| `id` | `:binary_id` (PK) | `null: false` | none |
| `tenant_id` | `:binary_id` | `null: false` | none, never cast from caller attrs (§5.2) |
| `instance_id` | `:binary_id` | `null: false` | none — FK → `instance_projections(instance_id)` |
| `token_id` | `:binary_id` | `null: false` | none — FK → `tokens(id)` (§3) |
| `node_id` | `:string` | `null: false` | none |
| `node_name` | `:string` | `null: false` | none |
| `status` | `Ecto.Enum` | `null: false` | `:pending` — `values: [pending: "PENDING", completed: "COMPLETED", cancelled: "CANCELLED"]` (keyword-mapping form, uppercase dump — **mandated literally** by this run's acceptance criteria text) |
| `assignee_type` | `:string` | nullable | none — `USER \| GROUP \| ROLE`, no `Ecto.Enum` (open free-text per EE-03 §1a's own column comment; no closed-set validation named by any acceptance criterion) |
| `assignee_ref` | `:string` | nullable | none |
| `form_schema` | `:map` | nullable | none |
| `output_variables` | `:map` | nullable | none |
| `completed_by` | `:binary_id` | nullable | none — no FK (no `users`/identity table reference named by REQ-043; matches R-Co's own bare `UUID` with no `REFERENCES`, `005:71`) |
| `completed_at` | `:utc_datetime_usec` | nullable | none |
| `cancelled_at` | `:utc_datetime_usec` | nullable | none |

`timestamps(type: :utc_datetime_usec)` — literal `timestamps()` per this run's task
text, with the project's established `utc_datetime_usec` precision (matching every other
lifecycle table in this schema) rather than the bare-`timestamps()` default
`naive_datetime`.

### 4.2 Migration

**Migration shape** (shape, not literal code — same guard pattern as §2.1/§3.3/`req023`
§2.2): `change/0`: if `Ecto.Migration.prefix()` is truthy, create the `tasks` table,
scoped to that prefix, with no implicit primary key (the explicit `id` column serves as
primary key instead), holding the columns from the §4.1 table above in order: `id`
(`:binary_id`, primary key); `tenant_id` (`:binary_id`, `null: false`); `instance_id`
(`:binary_id`, `null: false`, a foreign key to `instance_projections`'s `instance_id`
column, `on_delete: :restrict`); `token_id` (`:binary_id`, `null: false`, a foreign key
to `tokens`'s `id` column, `on_delete: :restrict`); `node_id` and `node_name` (both
`:string`, `null: false`); `status` (plain `:string` at the migration layer — the
`Ecto.Enum` mapping lives at the schema layer, §4.4 — `null: false`, defaulting to the
string `"PENDING"`); `assignee_type` and `assignee_ref` (both nullable `:string`);
`form_schema` and `output_variables` (both nullable `:map`); `completed_by` (nullable
`:binary_id`); `completed_at` and `cancelled_at` (both nullable `:utc_datetime_usec`);
and the standard `inserted_at`/`updated_at` timestamp pair at `:utc_datetime_usec`
precision. Still scoped to the same prefix, create two plain indexes: one on
`(instance_id)`, named `idx_task_instance`, and one on `(token_id)`, named
`idx_task_token`. If `Ecto.Migration.prefix()` is falsy, the migration does nothing at
all, matching every other tenant-scoped migration's guard.

**Must sort after the `tokens` migration** (§3) — `tasks.token_id`'s FK requires the
`tokens` table to already exist. §6 orders the manifest/filenames accordingly.

**R-Co's `idx_task_pending`/`idx_task_status` (`005:83-88`) deliberately not built
here** — both are query-optimization indexes for the task inbox/list surface this
requirement explicitly excludes (§1's scope table: "belongs with S4's tasks routes or
its own later requirement"). `idx_task_instance` and `idx_task_token` are built anyway,
per the same FK-referencing-side-indexing reasoning as §3.3, independent of any query
surface.

### 4.3 `Letflow.Engine.Task` — required moduledoc content (verbatim in substance)

The schema module's `@moduledoc` **must** state, in substance, every point below — this
is the acceptance criterion's own "verbatim enough that ELIXIR-DEV cannot omit the
boundary statement" requirement:

PROVENANCE (historical, not current decision authority):
1. **The `src/tasks/store.zig`-not-ported boundary, stated explicitly:**
   > "This module is the Ecto schema for the `tasks` table only — the table `EE-03`
   > (`src/engine/instance.zig`'s task-activation path) and `EE-04` (task completion)
   > write into. R-Co's own `src/tasks/store.zig` (1202 lines) additionally builds a
   > standalone task query/list/filter surface (`TaskStore.list/6`-equivalent:
   > `instance_id`/`status`/`assignee_ref` filters, pagination) — **that surface is not
   > ported by this module or by REQ-043 at all.** It belongs to S4's tasks routes or its
   > own later requirement, per `docs/migration/stage-3-instance-engine.md`'s explicit
   > scope boundary. Do not read this schema module as `TaskStore`'s functional
   > equivalent — it is schema only, with no query/list/filter functions of its own."
2. That REQ-043 builds only the migration and this schema module — no context-module
   write path (`create/N`, `complete/N`) exists yet; those are REQ-045/051's job.
3. That `status`'s `Ecto.Enum` dumps **uppercase** (`"PENDING"`/`"COMPLETED"`/
   `"CANCELLED"`), matching R-Co's own stored strings exactly (unlike `Letflow.Engine.Token`'s
   `status`, which dumps lowercase — §3.2's own explicit non-harmonization note) — so a
   future reader doesn't "fix" the two tables into matching casings.
4. No `@schema_prefix` — every read/write must pass `prefix: schema_name` explicitly at
   call time (identical framing to `InstanceProjection`'s and `ProcessDefinition`'s own
   moduledocs).
5. `tenant_id` is never populated from caller-supplied attrs directly by this schema's
   own changeset contract — the calling context module (not yet built) derives it via
   `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` first, exactly as
   `Letflow.EventStore.append/2` and `Letflow.Definitions.create/2` already do (§5.2).

### 4.4 `Letflow.Engine.Task` — field/type shape and changesets

**Schema shape** (shape, not literal code): primary key is `id`, `:binary_id`,
client-side autogenerated (matching `ProcessDefinition`'s own convention, §4.4 below).
The `schema "tasks" do ... end` block declares one field per §4.1 column, each with the
matching Ecto type: `tenant_id`, `instance_id`, `token_id`, and `completed_by` all as
`Ecto.UUID`; `node_id`, `node_name`, `assignee_type`, `assignee_ref` all as plain
strings; `form_schema` and `output_variables` as maps; `completed_at` and
`cancelled_at` as `:utc_datetime_usec`; plus the standard `inserted_at`/`updated_at`
timestamp pair at `:utc_datetime_usec` precision. `status` is declared as an
`Ecto.Enum` field using the keyword-mapping form — `pending` maps to the stored string
`"PENDING"`, `completed` to `"COMPLETED"`, `cancelled` to `"CANCELLED"` — defaulting to
`:pending`.

```
@type t :: %__MODULE__{}
@type status :: :pending | :completed | :cancelled
```

**Two structural changesets, mirroring `InstanceProjection`'s
insert/update split** (no business-logic validation — that is REQ-045/051's job, this
requirement builds structure only):

```
@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```
Casts `[:tenant_id, :instance_id, :token_id, :node_id, :node_name, :assignee_type,
:assignee_ref, :form_schema]` (matches EE-03 §1a's "EE-03 writes only: `instance_id`,
`token_id`, `node_id`, `node_name`, `assignee_type`, `assignee_ref`" — `form_schema` is
included because it is sourced from the node definition at activation time, not
caller-supplied, but still populated at insert). `validate_required`:
`[:tenant_id, :instance_id, :token_id, :node_id, :node_name]`. **`id` is deliberately
not in the cast list** — `@primary_key {:id, :binary_id, autogenerate: true}` generates
it client-side at the schema layer, the same convention `ProcessDefinition` already
uses (`process_definition.ex:85`), rather than a DB-level `gen_random_uuid()` default
R-Co's own SQL uses. `status`, `output_variables`, `completed_by`, `completed_at`,
`cancelled_at` are **never** cast by `insert_changeset/2` — all five are
completion-time-only fields (EE-04 scope), and `status` additionally defaults to
`:pending` at the schema layer.

```
@spec complete_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```
Casts `[:status, :output_variables, :completed_by, :completed_at, :cancelled_at]`.
`validate_required`: `[:status]`. **`instance_id`, `token_id`, `node_id`, `node_name`,
`tenant_id` are excluded** — a task never changes which instance/token/node/tenant it
belongs to, the identical immutability pattern `InstanceProjection.update_changeset/2`
and `ProcessDefinition.update_changeset/2` already establish for their own tables. Named
`complete_changeset/2` rather than a generic `update_changeset/2` because REQ-043 builds
no function that calls it yet, and REQ-045/051's own design is free to add
`Ecto.Changeset.validate_inclusion/3`-style guards (e.g. "only `:pending → :completed`")
on top of this structural shape without this requirement pre-guessing that logic.

---

## 5. `Letflow.Engine.Token` — moduledoc, field/type shape, changesets

### 5.1 Module and file placement

**New module, new namespace: `Letflow.Engine`.** No `lib/letflow/engine/` directory or
`Letflow.Engine` context module exists yet (confirmed by direct glob — `lib/letflow/engine*/**`
returns no files). This design creates `lib/letflow/engine/token.ex`
(`Letflow.Engine.Token`) and `lib/letflow/engine/task.ex` (`Letflow.Engine.Task`) as
schema-only modules, following the exact precedent `Letflow.EventStore.Event` and
`Letflow.Definitions.ProcessDefinition` already set: a schema module can exist under a
bounded-context namespace before that namespace's own context module
(`lib/letflow/engine.ex`, `Letflow.Engine.create_instance/2`-equivalent) is built — REQ-045
is expected to add `lib/letflow/engine.ex` later, the same shape REQ-025 added
`lib/letflow/event_store.ex` on top of REQ-023's already-shipped schema modules.
**Flagged explicitly for REVIEWER (§9 OQ-5):** this namespace choice has no prior
Letflow precedent to follow (unlike tenant_id derivation, which does) — it is this
design's own reasoned decision, not a fact read off an existing convention, and
REVIEWER should confirm or correct it before REQ-045 builds on top of it.

### 5.2 Field/type shape and changesets

**Schema shape** (shape, not literal code): primary key is `id`, `:binary_id`,
client-side autogenerated, the same convention §4.4 uses for `Task`. The
`schema "tokens" do ... end` block declares one field per §3.2 column, each with the
matching Ecto type: `tenant_id`, `instance_id`, `parent_token_id`, and
`waiting_child_instance_id` all as `Ecto.UUID`; `node_id`, `branch_id`, and
`gateway_id` as plain strings; `completed_at` and `cancelled_at` as
`:utc_datetime_usec`; plus the standard `inserted_at`/`updated_at` timestamp pair at
`:utc_datetime_usec` precision. `status` is declared as an `Ecto.Enum` field using the
bare atom-list form — `:active`, `:waiting`, `:completed`, `:cancelled`, each dumped
lowercase — defaulting to `:active`.

```
@type t :: %__MODULE__{}
@type status :: :active | :waiting | :completed | :cancelled
```

```
@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```
Casts `[:tenant_id, :instance_id, :node_id, :branch_id, :status, :parent_token_id,
:gateway_id]`. `validate_required`: `[:tenant_id, :instance_id, :node_id, :branch_id]`.
`status` is castable here (unlike `Task.insert_changeset/2` excluding `status`) because
a token's initial status is a genuine per-call decision (`:active` for a fresh root/split
token, `:waiting` for a token parked at a join per EE-07) rather than always one fixed
value — `default: :active` covers the common case when the caller omits it.
`waiting_child_instance_id`/`completed_at`/`cancelled_at` are never cast by
`insert_changeset/2` — all three are set only by a later lifecycle transition
(sub-process wait begins, token completes, token is cancelled).

```
@spec advance_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```
Casts `[:node_id, :status, :waiting_child_instance_id, :completed_at, :cancelled_at]`.
`validate_required`: `[:node_id, :status]`. **`tenant_id`, `instance_id`, `branch_id`,
`parent_token_id`, `gateway_id` are excluded** — a token's tenant, owning instance,
branch identity, and split lineage never change after creation, the same immutability
pattern every other table in this design follows. Named `advance_changeset/2` (not
`update_changeset/2`) because "advancing" (moving `node_id` as the token progresses
through the graph) is the dominant mutation this table exists for — REQ-051/062's own
design is free to add narrower-named changesets on top if a single shared one proves
too permissive once real transition logic exists.

### 5.3 Required moduledoc content

1. The resolution and its reasoning from §3.1 — **verbatim in substance**: "This table
   exists because `Letflow.Engine.Task.token_id` requires a real, FK-referenceable row
   (a JSONB array element inside `instance_projections.current_nodes` cannot serve as a
   foreign-key target), not because `current_nodes` was found insufficient for
   split/join computation on its own terms — R-Co's own `src/design/engine.md` computes
   split/join purely from the in-memory `Token{node_id, branch_id}` list and states
   explicitly that no new fields are needed on that struct for EE-06/EE-07.
   `instance_projections.current_nodes` remains the engine's authoritative summary of
   active token positions; this table is the identity/lifecycle side table `tasks` and
   future sub-process tracking (REQ-062) need."
2. That REQ-043 builds schema only — no `create/N`/`advance/N`/join-counting function
   exists yet (REQ-051/062's job).
3. No `@schema_prefix` — explicit `prefix:` required at every call site.
4. `status` dumps **lowercase** (matching R-Co's own `tokens.status` strings exactly,
   unlike `tasks.status`'s uppercase — §4.3 point 3's cross-reference, stated on both
   modules so neither reader assumes the other's casing).
5. `tenant_id` is never populated from caller-supplied attrs by this schema's own
   changeset contract (§6.2).

---

## 6. `tenant_id` derivation — reuses the existing function, adds no new one

**No new function is added by this requirement.** Per this run's task text ("check
[REQ-025/REQ-030] for the existing convention rather than inventing a new one") and §0's
citations: `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` already exists
(shipped by REQ-025):

```
@spec tenant_id_for_schema_name(schema_name :: String.t()) ::
        {:ok, tenant_id :: Ecto.UUID.t()} | {:error, :invalid_schema_name}
```

Pure, total, no I/O — reverses `schema_name_for_tenant/1`'s `"tenant_" <> hex` encoding.
**This requirement's contribution is ensuring every schema module it builds follows the
same contract shape** `Letflow.EventStore.append/2` and `Letflow.Definitions.create/2`
already established, for whichever future context module (REQ-045's `Letflow.Engine`,
REQ-051, REQ-062) writes through them:

1. **`tenant_id` is a required, cast field on every `insert_changeset/2`** built by this
   design (`Task.insert_changeset/2` §4.4, `Token.insert_changeset/2` §5.2,
   `InstanceProjection.insert_changeset/2` unchanged from REQ-023) — this is
   unavoidable: some value must be cast into the row, and the schema module itself has
   no access to `opts[:prefix]` to derive it locally.
2. **The value the future context module casts into `attrs[:tenant_id]` before calling
   any of these changesets must always be `tenant_id_for_schema_name(opts[:prefix])`'s
   result — never a value taken from the *caller's own* external input.** Concretely:
   whatever future function REQ-045 builds (e.g. an `Letflow.Engine.start_instance/2`
   equivalent) must, like `EventStore.append/2` and `Definitions.create/2` before it,
   reject any external caller-supplied `:tenant_id` key in its own public `attrs`
   parameter (`{:error, :tenant_id_not_accepted}`) and derive the value fresh from
   `opts[:prefix]` — this requirement's schema modules structurally support that
   contract (by requiring `tenant_id` in their cast list) but cannot themselves enforce
   the "never caller-supplied" half, since REQ-043 builds no public function a caller
   could pass attrs into. **Flagged explicitly for REQ-045/051/062's own CODE-DESIGNER
   to carry forward, not silently assumed automatic.**
3. No `tenant_id` column gets a DB-level default (`null: false`, no `default:`) on any
   of the three tables — matching every other tenant_id-bearing table in this schema
   (`events`, `events_archive`, `instance_projections`) and this run's own task text.

---

## 7. Migration manifest additions

Three new entries append to `Letflow.TenantProvisioning.@tenant_scoped_migration_manifest`
(`lib/letflow/tenant_provisioning.ex:250-273`), in version order, **tokens before
tasks** (§4.2's FK dependency):

```
{20_260_818_110_001, Letflow.Repo.Migrations.AlterInstanceProjectionsAddEngineColumns,
 "20260818110001_alter_instance_projections_add_engine_columns.exs"},
{20_260_818_110_002, Letflow.Repo.Migrations.CreateTokens,
 "20260818110002_create_tokens.exs"},
{20_260_818_110_003, Letflow.Repo.Migrations.CreateTasks,
 "20260818110003_create_tasks.exs"}
```

The manifest's own `@doc` (lines 275–329) must also gain one sentence naming REQ-043's
three entries, matching the pattern every prior requirement's addition already followed
(REQ-023 through REQ-040, each named by number and table).

**Migration-safety precondition, stated explicitly (not silently assumed):** §2.1's
`ADD COLUMN definition_id ... null: false` with no `DEFAULT` is only safe to run against
a tenant schema whose `instance_projections` table is currently empty. This holds today
— no shipped requirement populates `instance_projections` rows yet (REQ-025's
`EventStore.append/2` only ever *updates* an existing row, per its own OQ-5 resolution,
and EE-01/REQ-045 hasn't shipped) — but it is a real, load-bearing precondition a future
maintainer must reverify before this migration is ever replayed against a tenant schema
with genuine data. Flagged for REVIEWER (§9 OQ-6).

---

## 8. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-EE43-1 | `instance_projections`'s `status` `Ecto.Enum` already carries `error: "ERROR"` — no enum migration needed by this requirement | Confirmed §0 against the shipped schema module; not re-declared |
| INV-EE43-2 | `uq_instance_correlation` and `idx_proj_definition` are copied verbatim (name, columns, predicate) from `001_event_store.sql:98-107` | §2.1 |
| INV-EE43-3 | `tokens` table exists; `instance_projections.current_nodes` remains the engine's authoritative summary — the two are not redundant, they answer different questions (identity/FK vs. fast-read summary) | §3.1, §5.3 |
| INV-EE43-4 | `tasks.status` dumps uppercase (`"PENDING"`/`"COMPLETED"`/`"CANCELLED"`); `tokens.status` dumps lowercase (`:active`/`:waiting`/`:completed`/`:cancelled`) — deliberately not harmonized, matching R-Co's own inconsistent casing across the two tables in the same source file | §3.2, §4.1 |
| INV-EE43-5 | Every `tenant_id` column (`tasks`, `tokens`) is `null: false`, no DB default, never cast from external caller input by any future write path — only ever the result of `tenant_id_for_schema_name/1` | §6 |
| INV-EE43-6 | `tasks.token_id` and `tokens.parent_token_id`/`instance_id` FKs use `on_delete: :restrict`, deliberately diverging from R-Co's `CASCADE`, because no delete path exists for `instance_projections` anywhere in Letflow yet | §3.3, §4.2 |
| INV-EE43-7 | `tokens` migration sorts before `tasks` migration (FK dependency) | §4.2, §7 |
| INV-EE43-8 | No new public context-module function is added by this requirement — schema and migrations only | §1 |

---

## 9. Open questions — explicitly listed, not silently resolved

**OQ-1 (MAJOR, methodological).** This run's own task text paraphrases `engine.md`
Section EE-02 §2's `Token` struct as carrying `node_id`/`branch_id`/`token_id`/
`waiting_child_instance_id`. Direct reading of the primary source (§0) shows exactly
`node_id`/`branch_id` on the *in-memory* struct, with EE-06 §3 explicitly forbidding
additions to it. This design does not silently trust either account over the other —
it treats the persisted-schema question (§3, §5) as answerable independently of what
the in-memory struct currently carries, and flags the mismatch here for REVIEWER to
confirm this design correctly separated "what the pure transition function's `Token`
value carries" from "what a persisted `tokens` row needs," rather than conflating them.

**OQ-2 (MINOR).** §2.2: `instance_projections.definition_id` carries no FK to
`process_definitions(id)`, matching R-Co's own `001_event_store.sql` exactly. Given
Letflow's Decision A ("Ecto-idiomatic redesign, not a 1:1 SQL port") and that
`process_definitions` already exists at this migration's point in Letflow's own
ordering (unlike in R-Co), REVIEWER may judge adding a real FK here a worthwhile
correction. Not added by this design, since no defect/inconsistency (unlike
`event_payload_store`'s CASCADE correction) motivates the divergence on its own.

**OQ-3 (MINOR, methodological).** §2.4: whether `Ecto.Changeset.cast/3` accepts a
JSON-array (`list()`) value for a `:map`-typed field is stated as a real technical
uncertainty this design cannot verify without a compiler/test run. Flagged for
REQ-045's own implementation to confirm empirically; if `cast/3` rejects it,
`put_change/3` is the documented fallback.

**OQ-4 (MAJOR — affects REQ-051/REQ-062 directly).** This design deliberately does not
specify *how* a future write path keeps `tokens` table rows and
`instance_projections.current_nodes`'s JSONB summary synchronized (write both on every
transition? write `tokens` only at creation/status-change and treat `current_nodes` as
a periodically-rebuilt cache? something else?), nor does it build
`idx_token_active`/`idx_token_waiting`-equivalent indexes ahead of knowing the real
query shapes REQ-051's join-counter logic will issue. This is a genuine, load-bearing
gap left for REQ-051/REQ-062's own CODE-DESIGNER, stated explicitly rather than guessed
at, per this requirement's schema-only scope (§1).

**OQ-5 (MINOR, methodological).** §5.1: the `Letflow.Engine` namespace for
`Letflow.Engine.Task`/`Letflow.Engine.Token` is this design's own reasoned choice, with
no prior Letflow convention to confirm it against (unlike the tenant_id-derivation
pattern, which does have one). Flagged for REVIEWER to confirm before REQ-045 builds
`lib/letflow/engine.ex` on top of it — a REVIEWER-mandated rename at that point would be
a mechanical, low-risk fix, but better caught before three more requirements build on
the namespace.

**OQ-6 (MINOR).** §7's migration-safety precondition (`instance_projections` must be
empty when the ALTER TABLE runs) is true today but is not enforced by any guard in the
migration itself (no `RAISE` if rows exist). Flagged for REVIEWER — whether a defensive
check belongs in the migration or is acceptable to leave as an operational precondition
documented only in the header comment (matching this codebase's general practice of
documenting rather than defensively coding against preconditions the current call graph
already guarantees, e.g. REQ-030's `create/2` P11 note on `uq_active_definition` being
"categorically excluded" rather than separately guarded).

---

## 10. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` | `Letflow.Engine.Task`/`Token`'s future callers → `TenantProvisioning` | Reused unchanged (§6); no new function added |
| `Letflow.TenantProvisioning.@tenant_scoped_migration_manifest` | This requirement → `TenantProvisioning` | **Edited** — three new entries (§7), same forward-edit pattern REQ-023/024/027/030/035/040 already established |
| `Letflow.EventStore.InstanceProjection` | This requirement → REQ-023's schema module | **Edited** — seven new fields, two changesets extended, moduledoc updated (§2.3) |
| `instance_projections(instance_id)` | `tokens.instance_id`, `tasks.instance_id` → `instance_projections` | Real FK, `on_delete: :restrict` (§3.3, §4.2) |
| `tokens(id)` | `tasks.token_id`, `tokens.parent_token_id` (self) → `tokens` | Real FK, `on_delete: :restrict` (§3.3, §4.2) |
| REQ-045 (EE-01 instance store, not yet built) | REQ-045 → this design | Consumes `InstanceProjection`'s extended fields/changesets (§2.3) and is expected to add `lib/letflow/engine.ex` on top of the `Letflow.Engine` namespace this design opens (§5.1, OQ-5) |
| REQ-051 (EE-06/EE-07 split/join, not yet built) | REQ-051 → this design | Consumes `Letflow.Engine.Token`'s schema/changesets; owns the `tokens`/`current_nodes` synchronization question this design leaves open (OQ-4) |
| REQ-062 (SPC-01 sub-process, not yet built) | REQ-062 → this design | Consumes `tokens.waiting_child_instance_id` |
| S4 tasks routes (not yet built) | S4 → this design | Consumes `Letflow.Engine.Task`'s schema; owns the query/list/filter surface this design explicitly excludes (§1, §4.3 point 1) |

---

## 11. Acceptance-criteria traceability

PROVENANCE (historical, not current decision authority):
| REQ-043 acceptance criterion (this run's task text) | Concrete design element |
|---|---|
| "ALTER TABLE spec for instance_projections lists exactly the 7 named columns ... plus both named indexes ... and states explicitly that no enum migration is needed" | §2.1 (column table + migration shape), INV-EE43-1, INV-EE43-2 |
| "tasks table spec is complete: all named columns with types/nullability/defaults, status Ecto.Enum restricted to exactly PENDING/COMPLETED/CANCELLED, and the schema module's moduledoc content is specified verbatim enough that ELIXIR-DEV cannot omit the src/tasks/store.zig-not-ported boundary statement" | §4.1 (columns), §4.4 (Enum values, keyword-mapping uppercase form), §4.3 (moduledoc content, point 1 quotes the boundary statement) |
| "tokens table question resolved: design states whether a tokens table is built or current_nodes subsumes it, with reasoning tied to REQ-051's join counters and REQ-044's tasks FK" | §3.1 (decision: BUILD, three independent reasons, the third naming REQ-051 explicitly); §5.3 point 1 (moduledoc statement) — note: this run's own task text names "REQ-044's tasks FK," which this design reads as this same run's own item (b) `tasks.token_id` FK (§4.1), since no separate REQ-044 deliverable builds a second FK; flagged rather than silently assumed if REQ-044 turns out to mean something else |
| "tenant_id derivation is specified as an internal function (signature + behavior), never a caller-supplied schema field, on every table" | §6 (existing `tenant_id_for_schema_name/1` signature cited; contract restated for `tasks`/`tokens`/`instance_projections`); INV-EE43-5 |
| "No implementation code (.ex/.exs bodies) -- signatures and type shapes only" | Every code block in this document is a schema-field list, a `@spec`, or a migration DSL *shape* description (algorithm-level, matching `req025`/`req030`'s own established pseudocode convention) — no function body, no `def ... do ... end` with real logic anywhere in this document |
