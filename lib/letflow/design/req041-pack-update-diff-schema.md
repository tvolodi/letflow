PROVENANCE (historical, not current decision authority):
# Design: REQ-041 — Solution-pack update three-way diff (`pack_update.zig`, PRM-09)

**Requirement:** REQ-041 (`docs/requirements.yaml:1939-1998`, stage S2, `depends_on: [REQ-015]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ041-20260817`, WF-02 Step 1
**This document produces:** three migrations' full column/index/constraint detail, two
`Ecto.Schema` module shapes plus one lightweight computed-result struct,
`Letflow.Definitions.compute_pack_update_plan/5`'s full `@spec` and reasoning for its
5 parameters, invariants, required moduledoc text, cross-module dependencies, open
questions, traceability. **No implementation code** — no function bodies, no
`.ex`/`.exs` files, no migration files. ELIXIR-DEV writes those from this document at
Step 2a.

**Convention basis:** structural sibling of `req035-promotion-reviews-schema.md`
(same design-doc rigor, comparable scope) and `req027-definition-core-schema.md`
(migration guard pattern, table-spec table shape, "functions deliberately NOT built"
table, traceability table). Diverges from both in one structural way: **these three
tables are GLOBAL (public/default schema, no `:prefix`)**, per REQ-041's own text —
the first S2 requirement in this batch to use the public schema instead of REQ-022's
schema-per-tenant mechanism. `lib/letflow/design/identity-schema.md` §2 and the shipped
`priv/repo/migrations/20260816090045_create_tenant_schemas.exs` (REQ-022's own
`tenant_schemas` registry) are this design's direct GLOBAL-table precedents, not
`req027`/`req035`'s per-tenant ones.

---

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-041's full entry (lines 1939-1998), read in full, not
  paraphrased — description and all 5 acceptance criteria.
- `docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md`
  Step 1, `docs/anti-patterns.md`.
- `docs/guides/backend_developer_guide.md` — §3.1 naming, §3.5 error shapes, §3.6 SQL
  parameterization, §3.7 migrations.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — Decision A (Ecto-idiomatic
  redesign), Decision B (schema-per-tenant + intra-schema `tenant_id`, **the default
  this requirement's tables are the stated exception to**), Decision C (event-store
  composite-PK rules, not applicable here — these are ordinary mutable/append tables,
  not event-store partitions).
PROVENANCE (historical, not current decision authority):
- **Searched this repo for `src/definition/pack_update.zig` and `prm-batch1`'s design
  doc — confirmed absent.** `find . -iname "*pack_update*"`, `find . -iname
  "*prm-batch1*"`, and `find . -path "*src/definition*"` all returned zero matches
  under `~/letflow`. These are R-Co-source-tree-only references (per REQ-041's own
  citation, `prm-batch1`'s "PRM-09 design" section and "4. solution_pack_* table
  schemas" section, both outside this repository) — this agent has no access to them.
  This design therefore relies entirely on REQ-041's own `description`/
  `acceptance_criteria` text in `docs/requirements.yaml`, the same situation
  `req035-promotion-reviews-schema.md` §0 documents for `prm-04`. **Flagged explicitly,
  not silently worked around** — CODE-DESIGN-VALIDATOR and REVIEWER should know this
  design is one level removed from the R-Co source doc, same caveat as req035.
- **REQ-036 (`compute_promotion_plan/5` + `compute_plan_digest/1`, PRM-01/02/03)
  checked — status `pending`, not yet implemented** (`docs/requirements.yaml:1639`,
  `status: pending`). REQ-041's description says its classification algorithm uses
  "byte-level canonical-JSON comparison, same normalization as REQ-036's plan digest,"
  but no `Letflow.Definitions.compute_plan_digest/1` or shared canonicalization helper
  exists in `lib/letflow/` yet to call. This design resolves that gap explicitly in §5.2
  rather than inventing a call to code that doesn't exist — see OQ-1.
- `lib/letflow/design/req035-promotion-reviews-schema.md` — read in full as the direct
  structural template (§0's citation discipline, §3's table-spec table shape, §5.1's
  field-declaration/changeset-list shape, §6's invariants-table shape, §7's
  verbatim-moduledoc-text requirement, §9's open-questions shape, §10's traceability
  table).
- `lib/letflow/design/req027-definition-core-schema.md` — read for the migration guard
  pattern and "functions deliberately NOT built" table conventions (both reused here).
- `lib/letflow/design/identity-schema.md` §2 — GLOBAL-vs-PER_TENANT precedent for
  `tenants`/`users`/`groups`/`tenant_role`, all public/default schema.
- **Letflow shipped code read directly (GLOBAL-table FK precedent):**
  - `priv/repo/migrations/20260816090045_create_tenant_schemas.exs` — **the direct
    precedent for a real DB-level FK from a GLOBAL table's `tenant_id` to
    `tenants.id`**, its comment block (lines 8-18) reasoning that `tenant_schemas` and
    `tenants` are "both structurally-global siblings... never candidates for moving
    behind a tenant's own schema prefix, so this FK never needs to be dropped later."
    The FK is `references(:tenants, type: :binary_id), null: false` with **no explicit
    `on_delete:`** (Ecto/Postgres default `ON DELETE NO ACTION`). This design's
    `solution_pack_installs.tenant_id` FK (§3.1) copies this shape exactly, for the
    same reasoning: `solution_pack_installs` and `tenants` are both GLOBAL and neither
    is a candidate for later per-tenant-schema migration.
  - `lib/letflow/identity/tenant.ex` — confirms `tenants` has no `@schema_prefix`, lives
    in Ecto's single default schema, `@primary_key {:id, :binary_id, autogenerate:
    true}`.
  - `priv/repo/migrations/20260816120004_create_event_payload_store.exs` — read for its
    `on_delete: :restrict`-with-rationale comment pattern (lines 25-34), the style this
    design's §3.1 FK-choice citations follow, though the FK itself is PER_TENANT there
    (different applicability — cited for citation-writing convention only).
  - `mix.exs:38` — confirms `{:jason, "~> 1.4"}` is a project dependency, available for
    any future canonicalization helper (§5.2, OQ-1) — not used directly by this
    requirement's own migrations/schemas, which store pre-canonicalized text (§3
    `base_content`/`theirs`/`incoming` shape).

---

## 1. Scope boundary

**In scope (this requirement):** three migrations (`solution_pack_installs`,
`solution_pack_artefact_bases`, `pack_update_resolutions`), all GLOBAL (public/default
schema); two `Ecto.Schema` modules under `lib/letflow/definitions/` for the first two
tables plus one changeset-only module for the third; the pure classification algorithm;
`Letflow.Definitions.compute_pack_update_plan/5`, the read-only diff/plan computation.

**Explicitly NOT in scope, and not silently dropped:**

| Not built here | Owned by | Citation |
|---|---|---|
| The actual solution-pack export/install path that populates `solution_pack_installs`/`solution_pack_artefact_bases` from a real install event | SOL-01/02/03 (`src/solution/`, not scoped to any stage yet) | REQ-041 description: "this requirement's tables have no real installs to compare against until whichever future requirement builds SOL-01/02/03's install path" |
| Rejecting an *apply* attempt when `has_unresolved_conflicts` is true | A later requirement | REQ-041 description: "a plan with unresolved conflicts is rejected at apply time (a later requirement's job to enforce — this requirement computes and exposes the flag)" |
| Writing/inserting `pack_update_resolutions` rows (the actual conflict-resolution UI/API flow) | A later requirement | Not named in REQ-041's acceptance criteria — this requirement only *reads* resolutions to compute `has_unresolved_conflicts` (§5.3) |
| `compute_plan_digest/1`, the shared canonical-JSON normalization helper | REQ-036 (not yet implemented, `status: pending`) | §0 above; §5.2, OQ-1 |
| Any HTTP route / API surface | S4 (api-surface), by this batch's established pattern (REQ-036/037's own scoping notes) | Not named anywhere in REQ-041's text |

---

## 2. Tenant-scoping classification: GLOBAL, per REQ-041's own text — and the open question this does NOT resolve

**What REQ-041 mandates literally (acceptance criterion 1):** all three migrations
"land in public/default schema (not `:prefix`-scoped), applying cleanly." This is not
this design's discretion — built that way in §3-§4 below, using **no** `if prefix() do
... end` guard at all (contrast every PER_TENANT migration in this batch, e.g.
`req035`'s, which the guard exists specifically to gate).

**Why GLOBAL, per REQ-041's own description:** "install records are cross-tenant
infrastructure" (prm-batch1's stated classification, quoted in REQ-041's
`docs/requirements.yaml` entry) — the same *kind* of classification R-Co's own
`service_catalog` carries (per `svc-01-04-service-scope.md`, cited in REQ-041's text:
"service_catalog is a public-schema routing/registry table (TNT-01 confirmed)"). This
requirement follows prm-batch1's stated classification for these three tables
specifically, since it is explicit for them (unlike `req035`'s `promotion_reviews`,
where no equivalent explicit source exists — see `req035` §2/§9 OQ-2, a different,
already-flagged gap in a different requirement).

**What is genuinely unresolved, per REQ-041's own instruction (acceptance criterion
5) — flagged, not silently endorsed:** neither `0003-ecto-schema-strategy.md` nor any
other Letflow decision record states a *general* rule for when a table gets this
GLOBAL exception versus Decision B's schema-per-tenant default. REQ-041's own text
states this explicitly and instructs this design to "flag the underlying general
question as unresolved and worth a REVIEWER/decision-record follow-up rather than
something each future requirement re-derives ad hoc." This design does exactly that —
see §7's required moduledoc text and §9 OQ-2 — and does **not** attempt to derive or
propose the general rule itself (that would be silently resolving what REQ-041
explicitly says must stay open).

**Downstream note:** `req035-promotion-reviews-schema.md` §9 OQ-2 already flags the
*opposite* problem for `promotion_reviews` (a table built PER_TENANT with no explicit
GLOBAL/PER_TENANT source either way). REQ-041 and REQ-035 are thus two independent
data points on the same unresolved general question — REVIEWER should read both
open-questions sections together when this follow-up decision record eventually gets
written, not treat either in isolation.

---

## 3. Table specification

Conventions applied, matching `req022-...md` §4 (baseline migration shape) and
`priv/repo/migrations/20260816090045_create_tenant_schemas.exs` (the GLOBAL-table
precedent, §0 above) rather than `req027`/`req035`'s PER_TENANT guard pattern:

- `create table(:<name>, primary_key: false)` — **no `prefix:` option anywhere in any
  of the three migrations.** This is the acceptance-criterion-1-mandated structural
  difference from every other table this S2 batch has added.
- Explicit `add :id, :binary_id, primary_key: true` (Decision A surrogate PK,
  matching every table in this codebase).
- `snake_case` column names.
- A `#`-comment header block above `defmodule`, matching every migration in this
  project, explicitly stating "GLOBAL — no prefix:, see REQ-041" so a future reader
  scanning `priv/repo/migrations/` does not mistake the absence of a guard for an
  oversight.
- DB types below are what the Postgres adapter emits for each Ecto migration type,
  per the same `deps/ecto_sql` mapping `req023`/`req027`/`req035` all cite directly
  (`:binary_id -> uuid`, `:string -> varchar(255)`, `:text -> text`,
  `:utc_datetime_usec -> timestamp` (no time zone, precision 6)).

### 3.1 `solution_pack_installs`

One row per `(tenant_id, pack_id)` install record — the tenant's current (or most
recent) installed state of a given solution pack, at whatever version it was last
successfully installed/updated to (`installed_version`, this is "Vb" for the next
update's diff).

PROVENANCE (historical, not current decision authority):
| Column | Ecto migration type | DB type | Null / default | Notes & citation |
|---|---|---|---|---|
| `id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` (implied by PK) | Decision A surrogate PK. |
| `tenant_id` | `references(:tenants, type: :binary_id)` | `uuid` | `NOT NULL`, no default | **Real DB-level FK to `tenants.id`, no explicit `on_delete:`** (Ecto/Postgres default `ON DELETE NO ACTION`) — copied directly from `tenant_schemas.tenant_id`'s shape (§0), same reasoning: both `solution_pack_installs` and `tenants` are GLOBAL and neither table is a candidate for later per-tenant-schema migration, so this FK never needs to be dropped. This is the FK REQ-041's own description calls out as "possible here, unlike the deliberate no-cross-schema-FK omission this batch's other per-tenant tables use" — because both tables now live in the same public/default schema. |
| `pack_id` | `:string` | `varchar(255)` | `NOT NULL` | The solution pack's identifying key (equivalent to `process_definitions.name`'s role for process defs — a stable human/system identifier, not the surrogate `id`). **Confirmed against R-Co source (GH#323, ISS-0095):** `R-Co/src/design/sol-batch1-solution-pack.md:107` documents `pack_id: string // generated UUID at export time`; `R-Co/src/solution/store.zig:249,673` (`newUuidStr` → `uuid_util.newUuidV4`) confirms this is a canonical UUID v4 string (36 hyphenated hex chars), assigned once at export and carried unchanged through install. R-Co's own column (`R-Co/migrations/1158_sol02_solution_pack_installs.sql`) is `TEXT` (unbounded), not length-bound like Letflow's `varchar(255)` — a `divergent_doc_only` finding: the two DDLs differ, but since the identifier shape is always a fixed 36-char UUID, `varchar(255)` never truncates or rejects a valid R-Co `pack_id`, so shipped Letflow behaviour is unaffected. No R-Co source enforces any narrower shape than "UUID v4 string" (no fixed-format regex or length check found in `solution_packs.zig`'s JSON parsing path), so `varchar(255)` (this project's default string bound, matching `process_definitions.name`/`def_id`'s precedent, `req027`/`req035`) remains the correct choice — retained, not narrowed to a UUID-specific type, since R-Co itself stores/transmits it as an opaque string rather than a typed UUID column. |
| `installed_version` | `:string` | `varchar(255)` | `NOT NULL` | "Vb" — the pack version this tenant last successfully installed/updated to. String, not integer: R-Co pack versions are not assumed to be a bare integer sequence (no source confirms either way — flagged, not guessed, OQ-3). |
| `status` | `Ecto.Enum` | `varchar(255)` | `NOT NULL`, `default: :active` | Bare atom-list `Ecto.Enum` over `[:active, :uninstalled]`, matching `process_definitions.status`/`tenants.status`'s established bare-atom-list pattern (`req027` §5.1, `identity-schema.md`). Dumps lowercase, no case-mismatch risk against the partial-index predicate below (same reasoning `req035` §3 gives for `promotion_reviews.status`). |
| `installed_at` | `:utc_datetime_usec` | `timestamp` (precision 6) | `NOT NULL` | When this row's `installed_version` was last set (initial install or a completed update) — distinct from `inserted_at` (this *row's* creation time, which for an update-in-place row predates the current `installed_version`). |
| `uninstalled_at` | `:utc_datetime_usec` | `timestamp` (precision 6) | **nullable** | Set when `status` moves to `:uninstalled`. No transition function is built by this requirement (§1) — this column exists so a future requirement's uninstall path has somewhere to write, per this table's own natural lifecycle; left nullable and unenforced by any CHECK, matching `promotion_reviews.approved_at`'s nullable-until-set precedent (`req035` §3). |
| `inserted_at` / `updated_at` | via `timestamps/1` | `timestamp` (precision 6) | `NOT NULL` | `timestamps(type: :utc_datetime_usec)`, matching this project's prevailing convention on every business table built so far. |

**Primary key:** `(id)` — single `binary_id` surrogate key.

**Indexes:**

| Index name | Columns | Unique | Predicate | Why |
|---|---|---|---|---|
| *(PK)* `solution_pack_installs_pkey` | `(id)` | yes | — | Decision A surrogate PK. |
| `uq_solution_pack_install_active` | `(tenant_id, pack_id)` | **yes** | `status = 'active'` | At most one active install per `(tenant_id, pack_id)` — mirrors `req035`'s `uq_promotion_review_active_digest` partial-unique pattern for the same reason (one *live* state per natural key, historical/uninstalled rows don't block a fresh reinstall). |

### 3.2 `solution_pack_artefact_bases`

One row per `(tenant_id, pack_id, artefact_type, artefact_id)` — the base (installed-at-Vb)
content snapshot for one artefact within one tenant's install of one pack. This is the
`base` side of the three-way diff.

| Column | Ecto migration type | DB type | Null / default | Notes & citation |
|---|---|---|---|---|
| `id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` (implied by PK) | Decision A surrogate PK. |
| `tenant_id` | `references(:tenants, type: :binary_id)` | `uuid` | `NOT NULL`, no default | Same FK shape and reasoning as §3.1's `tenant_id`. Present here (not just derivable via a join to `solution_pack_installs`) so a base lookup by `compute_pack_update_plan/5` (§5.3) is a direct single-table indexed query, matching this project's general preference for a flat indexed lookup over a join for a hot read path. |
| `pack_id` | `:string` | `varchar(255)` | `NOT NULL` | Same shape as §3.1's `pack_id` — deliberately **not** a foreign key to `solution_pack_installs.id`; see §3.2.1 for why. |
| `artefact_type` | `:string` | `varchar(255)` | `NOT NULL` | E.g. (illustrative, not enumerated by any source available to this design) a process-graph node, a variable-schema entry, a service-catalog binding — mirrors REQ-036's own `PlanEntry.type` dimension list, but REQ-041's text names no closed set. Plain `:string`, no `Ecto.Enum`, no CHECK constraint — same open-ended-text treatment `req035` gives `def_type` (§3 there), flagged the same way here (§9 OQ-4). |
| `artefact_id` | `:string` | `varchar(255)` | `NOT NULL` | The artefact's identifying key within its `artefact_type` (e.g. a graph node id) — opaque string, no further shape asserted. |
| `base_version` | `:string` | `varchar(255)` | `NOT NULL` | "Vb" at the artefact level — normally equal to the owning `solution_pack_installs.installed_version` at the time this base was captured, but stored redundantly per-row (not FK'd, see §3.2.1) so a base snapshot remains meaningful even if the parent install row's `installed_version` later moves forward without this specific artefact's base being refreshed (e.g. a pack update that only touches some artefacts). |
| `base_content` | `:text` | `text` | `NOT NULL` | The full canonical-JSON content of this artefact **as it stood at install/last-update time**. `:text`, not `:map`/`jsonb` — same reasoning `req035` gives `promotion_reviews.serialised_plan` (§3 there, §5.2 here): canonical-JSON byte-stability (sorted keys, no insignificant whitespace) is exactly what `jsonb`'s storage-time re-normalization would silently undermine. **Caller contract:** this column's value MUST already be canonical-JSON text by the time it is written — this requirement does not itself provide the canonicalization step (§5.2, OQ-1). |
| `captured_at` | `:utc_datetime_usec` | `timestamp` (precision 6) | `NOT NULL` | When this specific artefact's base snapshot was captured (may differ from the owning install's `installed_at` for a partial/incremental update — see `base_version`'s note above). |
| `inserted_at` / `updated_at` | via `timestamps/1` | `timestamp` (precision 6) | `NOT NULL` | Same convention as §3.1. |

**Primary key:** `(id)`.

**Indexes:**

| Index name | Columns | Unique | Predicate | Why |
|---|---|---|---|---|
| *(PK)* `solution_pack_artefact_bases_pkey` | `(id)` | yes | — | Decision A surrogate PK. |
| `uq_solution_pack_artefact_base` | `(tenant_id, pack_id, artefact_type, artefact_id)` | **yes** | — | Exactly one current base per artefact per tenant+pack — this is the lookup key `compute_pack_update_plan/5` (§5.3) queries by, and it is also the row whose *absence* AC2 requires be classified `conflict` (§6, INV-PU-2). |

#### 3.2.1 Why `solution_pack_artefact_bases` has NO foreign key to `solution_pack_installs`

Deliberate, not an oversight — this is the one place this design diverges from a
"child table FKs to its natural parent" default, for a reason specific to this
requirement's own acceptance criteria:

**AC2 requires that an artefact with no matching `solution_pack_artefact_bases` row
classify as `conflict`, and REQ-041's description further says `conflict` covers the
case where "base is NULL/no install record exists"** — i.e. `compute_pack_update_plan/5`
must handle a `(tenant_id, pack_id)` pair that has **no `solution_pack_installs` row at
all**. If `solution_pack_artefact_bases` (or, symmetrically, `pack_update_resolutions`,
§3.3.1) carried a mandatory FK to `solution_pack_installs.id`, no base or resolution row
could ever exist for that exact no-install-record scenario, which is precisely the
scenario AC2 asks this function to classify correctly rather than reject as invalid
input. Keying both child tables directly by `(tenant_id, pack_id, ...)` — the same
natural key `solution_pack_installs` itself uses, rather than its surrogate `id` — keeps
all three tables independently insertable, which is also what REQ-041's own text
requires for testability ("the diff algorithm itself is fully testable today via
directly-inserted fixture rows" — fixture rows can populate `solution_pack_artefact_bases`
directly without first constructing a `solution_pack_installs` row, exercising the
literal "no install record" AC2 case).

### 3.3 `pack_update_resolutions`

One row per `(tenant_id, pack_id, target_version, artefact_type, artefact_id)` — a
human/system decision resolving one conflicting artefact for one specific update
attempt (identified by the incoming version being resolved against, `target_version`).
Scoped per-attempt (not a permanent resolution) because a *later* update to a *different*
incoming version is a new conflict-preflight, not automatically pre-resolved by an
earlier decision — REQ-041's text gives no indication resolutions should carry forward
across different incoming versions, and carrying them forward silently would be
inventing a persistence/reuse policy REQ-041 never asked for (§9 OQ-5).

PROVENANCE (historical, not current decision authority):
| Column | Ecto migration type | DB type | Null / default | Notes & citation |
|---|---|---|---|---|
| `id` | `:binary_id`, `primary_key: true` | `uuid` | `NOT NULL` (implied by PK) | Decision A surrogate PK. |
| `tenant_id` | `references(:tenants, type: :binary_id)` | `uuid` | `NOT NULL`, no default | Same FK shape and reasoning as §3.1. |
| `pack_id` | `:string` | `varchar(255)` | `NOT NULL` | Same shape as §3.1/§3.2. No FK to `solution_pack_installs` — same reasoning as §3.2.1 (a resolution must be insertable even when no install row exists, matching the same no-install-record conflict case). |
| `target_version` | `:string` | `varchar(255)` | `NOT NULL` | "Vn" — the incoming version this resolution applies to (matches `compute_pack_update_plan/5`'s `incoming_version` argument, §5.3). |
| `artefact_type` | `:string` | `varchar(255)` | `NOT NULL` | Same shape as §3.2's `artefact_type`. |
| `artefact_id` | `:string` | `varchar(255)` | `NOT NULL` | Same shape as §3.2's `artefact_id`. |
| `resolution` | `Ecto.Enum` | `varchar(255)` | `NOT NULL` | Bare atom-list `Ecto.Enum` over `[:keep_local, :take_incoming, :merged]` — the three ways a human/system can resolve a conflicting artefact. Matches R-Co's `ResolutionKind` enum (`pack_update.zig:25-29`); renamed from the original `[:keep_theirs, :take_incoming, :custom]` by REQ-147 (see §9 OQ-6). |
| `resolved_content` | `:text` | `text` | **nullable** | Only meaningful when `resolution == :merged` (the merged/overridden content, same canonical-JSON-text contract as `base_content`, §3.2). `NULL` for `:keep_local`/`:take_incoming`, where the resolved content is unambiguously `local`/`incoming` respectively and does not need to be duplicated into this table. Not CHECK-constrained to enforce that nullability-vs-`resolution` correlation — same "structural checks are an application/changeset concern" precedent `req027`/`req035` already establish (§3 there). |
| `resolved_by` | `:binary_id` | `uuid` | `NOT NULL` | Actor who made the resolution decision. No FK — same cross-schema-adjacent reasoning `req035` gives `requested_by`/`approved_by` (§3.1 there): `users` and this table are technically both GLOBAL here (unlike `req035`'s case), but this design still omits the FK, deliberately, because REQ-041 names no requirement that this column be validated against a real `users.id` and inventing one is unasserted scope — flagged as a design choice in §9 OQ-7, not silently matched to `req035`'s different-reasoned precedent. |
| `resolved_at` | `:utc_datetime_usec` | `timestamp` (precision 6) | `NOT NULL` | When the resolution was recorded. |
| `inserted_at` / `updated_at` | via `timestamps/1` | `timestamp` (precision 6) | `NOT NULL` | Same convention as §3.1/§3.2. |

**Primary key:** `(id)`.

**Indexes:**

| Index name | Columns | Unique | Predicate | Why |
|---|---|---|---|---|
| *(PK)* `pack_update_resolutions_pkey` | `(id)` | yes | — | Decision A surrogate PK. |
| `uq_pack_update_resolution` | `(tenant_id, pack_id, target_version, artefact_type, artefact_id)` | **yes** | — | Exactly one resolution per conflicting artefact per update attempt — this is the lookup key `compute_pack_update_plan/5`'s `has_unresolved_conflicts` computation (§5.3, AC4) queries by. |

#### 3.3.1 Why no FK to `solution_pack_artefact_bases` either

A resolution's `(artefact_type, artefact_id)` may be the exact "no matching base row"
case AC2 requires classify as `conflict` (§3.2.1) — a resolution must be insertable
for that artefact regardless of whether a base row exists, so no FK is added here for
the same reason §3.2.1 gives.

---

## 4. Migration file plan

Three files, one table each, per Decision A's "one schema-defining concern per
migration" convention. Must sort after `20260816200001_create_promotion_reviews.exs`
(REQ-035's shipped migration, currently the latest in `priv/repo/migrations/`).

| Filename (proposed) | Migration module | Creates |
|---|---|---|
| `20260816210001_create_solution_pack_installs.exs` | `Letflow.Repo.Migrations.CreateSolutionPackInstalls` | `solution_pack_installs` + 1 partial unique index (§3.1) |
| `20260816210002_create_solution_pack_artefact_bases.exs` | `Letflow.Repo.Migrations.CreateSolutionPackArtefactBases` | `solution_pack_artefact_bases` + 1 unique index (§3.2) |
| `20260816210003_create_pack_update_resolutions.exs` | `Letflow.Repo.Migrations.CreatePackUpdateResolutions` | `pack_update_resolutions` + 1 unique index (§3.3) |

**Ordering constraint:** `.._installs` MUST sort before the other two — not because
either later migration carries a real FK to it (neither does, §3.2.1/§3.3.1), but so a
reader scanning `priv/repo/migrations/` sees the parent-shaped table defined before its
two natural-key children, matching this table's own conceptual ownership order. This is
a readability convention, not an Ecto/Postgres requirement.

**Timestamps:** the literal values above are this design's proposal; ELIXIR-DEV may
substitute real UTC-clock timestamps generated at implementation time, subject to: (a)
each sorts strictly after `20260816200001`; (b) `.._installs` sorts before the other
two; (c) none needs any entry in `Letflow.TenantProvisioning`'s
`@tenant_scoped_migration_manifest` — see §4.1.

### 4.1 No guard, deliberately — and no manifest edit

**Unlike every other S2 migration in this batch, none of these three files gets an
`if prefix() do ... end` guard, and none is added to
`Letflow.TenantProvisioning.@tenant_scoped_migration_manifest`.** Both are PER_TENANT
mechanisms (REQ-022 §4) that these GLOBAL tables must not use — adding either would
directly contradict acceptance criterion 1 ("not `:prefix`-scoped"). This design states
this explicitly (rather than leaving ELIXIR-DEV to notice the omission on their own)
because every other S2 design document up to this one has *mandated* the guard +
manifest edit — an ELIXIR-DEV following pattern-match muscle memory from
`req023`/`req027`/`req035` could otherwise add one by habit. **Do not add either.**

Each migration's `change/0` is unconditional: `create table(...)` (no `prefix:`) +
`create unique_index(...)` (no `prefix:`), matching
`20260816090045_create_tenant_schemas.exs`'s exact shape (no `if prefix() do` wrapper
anywhere in that file either).

### 4.2 Reversibility

`create table`, `create unique_index` are auto-reversible by `change/0`
(`backend_developer_guide.md` §3.7). No `execute/1`, no `execute/2`, no raw SQL
anywhere in any of the three files — no raw-SQL identifier interpolation introduced
(relevant to SECURITY-REVIEWER's INV-7 check at Step 2c).

### 4.3 Demonstrating acceptance criterion 2

**Method (ELIXIR-DEV at Step 2a / TEST-DESIGNER at Step 3; this design specifies the
method, not the test code):** insert a `solution_pack_installs` fixture row (or, to
exercise the "no install record" half of AC2's OR condition literally, insert none at
all), a `theirs_artefacts`/`incoming_artefacts` pair passed directly as
`compute_pack_update_plan/5` arguments (§5.3) naming an `artefact_id` that has **no**
corresponding `solution_pack_artefact_bases` row, then assert the returned plan's entry
for that artefact has `classification: :conflict` — not `:unchanged`, not an
`{:error, _}` return.

---

## 5. Module plan

### 5.1 `Letflow.Definitions.SolutionPackInstall` — `lib/letflow/definitions/solution_pack_install.ex`

**Naming decision:** placed under `Letflow.Definitions`, matching REQ-041's own
function name (`Letflow.Definitions.compute_pack_update_plan/5`) and every other
schema this S2 batch has added under that same context module (`ProcessDefinition`,
`InstanceDefinitionSnapshot`, `PromotionReview`) — same reasoning `req035` §5.1 gives
for its own naming choice.

**Settings:**

- `@primary_key {:id, :binary_id, autogenerate: true}`.
- No `@foreign_key_type`. `tenant_id` is declared as `belongs_to(:tenant,
  Letflow.Identity.Tenant, foreign_key: :tenant_id, type: :binary_id)` — **unlike every
  PER_TENANT table's plain `field(:tenant_id, Ecto.UUID)`** (`req027`/`req035`'s no-FK
  convention), because this table's `tenant_id` carries a real DB-level FK (§3.1) and
  `Letflow.Identity.Tenant` is itself a schema in this same public/default schema
  (`lib/letflow/identity/tenant.ex`) — an Ecto association is idiomatic here in a way it
  is not for a cross-schema reference. This is the one schema-declaration place this
  design diverges from `req035`'s "plain field, no association" precedent, and the
  divergence is justified by the underlying DB shape actually differing (§3.1), not by
  stylistic preference.
- `@type t :: %__MODULE__{}` and `@type status :: :active | :uninstalled`.

**Field declarations** (declarations only, not code):

```
belongs_to(:tenant, Letflow.Identity.Tenant, foreign_key: :tenant_id, type: :binary_id)
field(:pack_id, :string)
field(:installed_version, :string)
field(:status, Ecto.Enum, values: [:active, :uninstalled], default: :active)
field(:installed_at, :utc_datetime_usec)
field(:uninstalled_at, :utc_datetime_usec)
timestamps(type: :utc_datetime_usec)
```

**Function signatures — every function this module exports.** Error shape is
`Ecto.Changeset.t()` carrying `valid?: false` plus field errors; no I/O, so no
`{:ok, _} | {:error, _}` tuple here (that boundary belongs to whichever future
requirement's `Repo.insert/2` call consumes this changeset — not built by REQ-041, §1).

```
@type t :: %Letflow.Definitions.SolutionPackInstall{}
@type status :: :active | :uninstalled

@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast:              [:tenant_id, :pack_id, :installed_version, :installed_at]
#   validate_required: [:tenant_id, :pack_id, :installed_version, :installed_at]
#   validate_length(:pack_id, max: 255)
#   validate_length(:installed_version, max: 255)
#   unique_constraint([:tenant_id, :pack_id],
#                      name: :uq_solution_pack_install_active)
#   NOTE: status and uninstalled_at are NOT castable here -- a newly-inserted install
#   is always :active (the column default); no update_changeset/2 exists in this
#   module for the same "not this requirement's scope" reason req035 gives its own
#   unbuilt transition functions (§1 above).
```

### 5.2 `Letflow.Definitions.SolutionPackArtefactBase` — `lib/letflow/definitions/solution_pack_artefact_base.ex`

**Settings:**

- `@primary_key {:id, :binary_id, autogenerate: true}`.
- `field(:tenant_id, Ecto.UUID)` — **plain field, no `belongs_to`**, deliberately
  inconsistent with §5.1's choice: this table's FK target is `tenants.id` (§3.2), same
  real FK as §5.1, so a `belongs_to(:tenant, ...)` would be equally valid here — but
  this design does not add one, because nothing in REQ-041's text or this table's own
  query pattern (§5.3: always looked up by the composite `(tenant_id, pack_id,
  artefact_type, artefact_id)` key, never traversed via a `Tenant` struct) benefits from
  the association, and an unused `belongs_to` per table is inconsistent scope-padding.
  Flagged here as a stylistic asymmetry with §5.1, not an oversight (§9 OQ-8).
- `@type t :: %__MODULE__{}`.

**Field declarations:**

```
field(:tenant_id, Ecto.UUID)
field(:pack_id, :string)
field(:artefact_type, :string)
field(:artefact_id, :string)
field(:base_version, :string)
field(:base_content, :string)      # :text migration column -> :string Ecto schema type
field(:captured_at, :utc_datetime_usec)
timestamps(type: :utc_datetime_usec)
```

**Function signatures:**

```
@type t :: %Letflow.Definitions.SolutionPackArtefactBase{}

@spec upsert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
#   cast:              [:tenant_id, :pack_id, :artefact_type, :artefact_id,
#                        :base_version, :base_content, :captured_at]
#   validate_required: [:tenant_id, :pack_id, :artefact_type, :artefact_id,
#                        :base_version, :base_content, :captured_at]
#   validate_length(:artefact_type, max: 255)
#   validate_length(:artefact_id, max: 255)
#   unique_constraint([:tenant_id, :pack_id, :artefact_type, :artefact_id],
#                      name: :uq_solution_pack_artefact_base)
#   NOTE: named upsert_changeset/2, not insert_changeset/2 -- unlike the other two
#   schemas in this design, this row's whole reason for existing is to be replaced
#   wholesale (new base_content/base_version/captured_at) each time a future
#   install/update-application requirement completes; REQ-041 does not build that
#   write path (§1), this changeset only specifies the field shape such a future
#   Repo.insert/2-with-on_conflict-replace call would use.
```

### 5.3 `Letflow.Definitions.compute_pack_update_plan/5` — the core function

**Where it lives:** `Letflow.Definitions` (the existing context module this batch's
functions all attach to — `req035` §5.1 already establishes this as the expected home
for `compute_pack_update_plan/5` by name).

**Reasoning for the 5 parameters — REQ-041's text does not literally spell these out,
so this design states the shape and the reasoning explicitly, per this task's
instruction not to silently guess without documenting:**

REQ-041's description names three things to compare per artefact — `base` (DB-sourced,
from `solution_pack_artefact_bases`), `theirs` (current tenant content), and `incoming`
(offered Vn content) — plus notes that no real install/export path exists yet
(§1: SOL-01/02/03 unbuilt) to *source* `theirs`/`incoming` from. Since there is no live
table or process this function could query for "the tenant's current artefact content"
or "the pack publisher's offered content," both must be **supplied by the caller as
data**, the same way `req035`/`req036` treat "domain logic only, not wired to a real
data source yet" computation functions. `base`, by contrast, **is** backed by a real
table this requirement itself creates (`solution_pack_artefact_bases`) and REQ-041's
text explicitly frames it as DB-sourced ("from solution_pack_artefact_bases") — so
`base` is looked up inside the function via `(tenant_id, pack_id, artefact_type,
artefact_id)`, not passed in. That yields:

1. `tenant_id` — identifies whose install/bases/resolutions to look up.
2. `pack_id` — identifies which pack's install/bases/resolutions to look up.
3. `incoming_version` — "Vn," the version being offered; also the `target_version` key
   `pack_update_resolutions` is looked up by (AC4's per-attempt resolution scoping,
   §3.3).
4. `theirs_artefacts` — the tenant's current content per artefact, caller-supplied
   (no live source exists yet, §1).
5. `incoming_artefacts` — the offered Vn content per artefact, caller-supplied (same
   reason).

`base` is deliberately **not** a 6th parameter — it is always looked up from
`solution_pack_artefact_bases` by this function itself (never caller-supplied), because
unlike `theirs`/`incoming` there IS a real table for it, and AC2's core assertion (an
artefact with no matching base row classifies `conflict`) is specifically a statement
about this function's own DB-lookup behavior, not about a value the caller chooses to
omit. Making `base` caller-suppliable would let a test simulate "no base" by passing
`nil` instead of by leaving the DB row absent — weaker coverage of the actual acceptance
criterion, which is about the table lookup, not the function's parameter-handling.

```
@type artefact_key :: %{artefact_type: String.t(), artefact_id: String.t()}
@type artefact_input :: %{
        artefact_type: String.t(),
        artefact_id: String.t(),
        content: String.t()          # canonical-JSON text, caller's responsibility (§5.2 OQ-1)
      }
@type classification :: :unchanged | :clean_update | :local_only | :conflict

@type plan_entry :: %{
        artefact_type: String.t(),
        artefact_id: String.t(),
        classification: classification(),
        base: String.t() | nil,      # nil iff no solution_pack_artefact_bases row -- AC2
        theirs: String.t() | nil,    # nil iff artefact absent from theirs_artefacts
        incoming: String.t() | nil,  # nil iff artefact absent from incoming_artefacts
        resolved: boolean()          # only meaningful when classification == :conflict;
                                      # true iff a matching pack_update_resolutions row
                                      # exists (AC4) -- always false for non-conflict entries
      }

@type plan :: %{
        tenant_id: Ecto.UUID.t(),
        pack_id: String.t(),
        incoming_version: String.t(),
        entries: [plan_entry()],
        has_unresolved_conflicts: boolean()
      }

@spec compute_pack_update_plan(
        tenant_id :: Ecto.UUID.t(),
        pack_id :: String.t(),
        incoming_version :: String.t(),
        theirs_artefacts :: [artefact_input()],
        incoming_artefacts :: [artefact_input()]
      ) :: {:ok, plan()} | {:error, :empty_artefact_set}
```

**Return shape decision — plain map, not a defstruct.** `plan`/`plan_entry` are
specified as typed maps (`@type`, not `defstruct`), unlike `PromotionReview`/
`ProcessDefinition` which are `Ecto.Schema` structs backed by a table. This computed
result has no backing table of its own (it's a read-side composition of three other
tables' data plus caller input) — matching REQ-036's `PromotionPlan`/`PlanEntry`
precedent, which REQ-036's own description also frames as plain computed types, not
schemas (`docs/requirements.yaml` REQ-036 entry, "PlanEntry/PromotionPlan types").
ELIXIR-DEV may implement `plan()`/`plan_entry()` as a `@type` over a bare map (as
specified above) or promote them to a lightweight non-Ecto `defstruct` purely for
field-access safety — this design does not mandate one over the other (§9 OQ-9),
since REQ-041's acceptance criteria test the returned *values*, not the return type's
concrete representation.

**Error case:** `{:error, :empty_artefact_set}` when both `theirs_artefacts` and
`incoming_artefacts` are `[]` — mirrors REQ-036's `compute_promotion_plan/5`'s explicit
empty-plan error for the same reasoning (an empty result is ambiguous between "nothing
changed" and "caller passed no data by mistake"). **Not directly required by any of
REQ-041's 5 acceptance criteria** — stated here as a design decision, not a literal
requirement-text mandate, so REVIEWER/CODE-DESIGN-VALIDATOR can strike it if it's judged
out of scope; documented explicitly rather than silently added (§9 OQ-10).

### Classification algorithm — pure helper, independently testable

Exposed as its own public function so AC3's three named patterns
(`clean_update`/`local_only`/`unchanged`) and AC2's `conflict`-on-missing-base case can
each get a direct unit test without needing DB fixtures or the full 5-argument
orchestration:

```
@spec classify_artefact(
        base :: String.t() | nil,
        theirs :: String.t() | nil,
        incoming :: String.t() | nil
      ) :: classification()
```

Truth table (byte-level string equality on already-canonical-JSON text, §5.2 below —
`nil` is never treated as equal to any non-nil value, including another `nil` compared
against a third non-nil value):

| `base` | `base == theirs` | `base == incoming` | Result | AC citation |
|---|---|---|---|---|
| non-nil | true | true | `:unchanged` | AC3 |
| non-nil | true | false | `:clean_update` | AC3 |
| non-nil | false | true | `:local_only` | AC3 |
| non-nil | false | false | `:conflict` | REQ-041 description ("both sides changed") |
| `nil` | — | — | `:conflict` (always, regardless of `theirs`/`incoming`) | **AC2** — "cannot prove no modification" (PRM-09 AC5, quoted in REQ-041's own text) |

### `has_unresolved_conflicts` computation

For each `plan_entry` with `classification == :conflict`, query
`pack_update_resolutions` for a row matching `(tenant_id, pack_id, target_version:
incoming_version, artefact_type, artefact_id)` (the unique index, §3.3). Set that
entry's `resolved: true` iff found. `plan.has_unresolved_conflicts = Enum.any?(entries,
&(&1.classification == :conflict and not &1.resolved))` — true iff at least one
conflict entry has no matching resolution row, false once every conflict entry has one
(including the trivial case of zero conflict entries — `has_unresolved_conflicts:
false`). This is **AC4**, stated exactly to REQ-041's own wording.

### 5.4 The one thing this design does NOT specify: canonical-JSON normalization itself

**Explicit open question, not silently resolved — see OQ-1.** REQ-041's description
says the comparison is "byte-level canonical-JSON comparison, same normalization as
REQ-036's plan digest" — but REQ-036 (`compute_plan_digest/1`) is `status: pending`,
not yet implemented (§0), so there is no shared canonicalization function to call yet.
This design resolves the *immediate* gap by making `classify_artefact/3` a **pure
string-equality comparison over already-canonical text** (§5.3's truth table) — i.e.
this requirement's contract is that `base_content` (§3.2), and every `content` value in
`theirs_artefacts`/`incoming_artefacts` (§5.3), MUST already be canonical JSON by the
time they reach this function/table; `compute_pack_update_plan/5` does not itself parse,
re-serialize, or sort-and-normalize anything. It does **not** independently reimplement
REQ-036's canonicalization logic (which would risk drifting from REQ-036's real
implementation once REQ-036 ships) and it does **not** block on REQ-036 (REQ-041's own
`depends_on: [REQ-015]` confirms no dependency on REQ-036 is declared). This is a
deliberate, stated scope boundary, not a silently-dropped requirement — flagged fully
in OQ-1 for REVIEWER/a future requirement to extract a shared canonicalization helper
both REQ-036 and REQ-041's callers use.

---

## 6. Invariants

| id | Invariant | Enforced where | Source |
|---|---|---|---|
| INV-PU-1 | **All three tables are GLOBAL** — no `:prefix`, no `if prefix() do` guard, no `@tenant_scoped_migration_manifest` entry. | §4.1 | REQ-041 acceptance criterion 1 |
| INV-PU-2 | **No matching `solution_pack_artefact_bases` row classifies `conflict`, never `:unchanged` and never an error.** | `classify_artefact/3`'s truth table (§5.3) | REQ-041 acceptance criterion 2 (PRM-09 AC5) |
| INV-PU-3 | **The three non-`conflict` comparison outcomes are exhaustively determined by `base == theirs` and `base == incoming` when `base` is non-nil** — `clean_update` (`base==theirs, base!=incoming`), `local_only` (`base==incoming, base!=theirs`), `unchanged` (all three equal). | `classify_artefact/3`'s truth table (§5.3) | REQ-041 acceptance criterion 3 |
| INV-PU-4 | **`has_unresolved_conflicts` is true iff at least one `:conflict`-classified entry lacks a matching `pack_update_resolutions` row**, false once every conflict entry has one (including vacuously, zero conflicts). | §5.3 "`has_unresolved_conflicts` computation" | REQ-041 acceptance criterion 4 |
| INV-PU-5 | **`compute_pack_update_plan/5` performs no mutation** — read-only across all three tables (queries `solution_pack_artefact_bases` and `pack_update_resolutions`; writes neither those nor `solution_pack_installs`). | §5.3's `@spec` (no `Repo.insert`/`update`/`delete` in this function's contract) | REQ-041 description: "this requirement computes and exposes the flag" (does not apply/reject) |
| INV-PU-6 | **`solution_pack_artefact_bases`/`pack_update_resolutions` carry no FK to `solution_pack_installs`**, deliberately, so the "no install record" conflict case (INV-PU-2) remains representable and independently fixture-insertable. | §3.2.1, §3.3.1 | REQ-041 description; REQ-041 acceptance criterion 2 |
| INV-PU-7 | **This GLOBAL-vs-PER_TENANT classification is REQ-041-specific, not a general rule** — the underlying general question (when does a table earn the GLOBAL exception?) is explicitly unresolved beyond this requirement's own scope. | §2; §7's required moduledoc text | REQ-041 acceptance criterion 5; §9 OQ-2 |

---

## 7. Required moduledoc text (verbatim, per REQ-041 acceptance criterion 5)

REQ-041 acceptance criterion 5 requires the moduledoc to "explicitly flag the
GLOBAL-vs-PER_TENANT classification question as unresolved beyond this requirement's
own scope." The text below is what must appear (in
`Letflow.Definitions.SolutionPackInstall`'s moduledoc, as the natural home — the first
of the three schemas — with a cross-reference from the other two modules' moduledocs
rather than duplicating the full text three times) so CODE-DESIGN-VALIDATOR, REVIEWER
and RELEASE-VALIDATOR can check it literally rather than by paraphrase. ELIXIR-DEV may
add surrounding prose but must not weaken or omit this text.

```
This table, `solution_pack_artefact_bases`, and `pack_update_resolutions` are all
GLOBAL (public/default schema, no schema-per-tenant `:prefix`) -- prm-batch1's
explicit classification for these three specifically ("install records are
cross-tenant infrastructure"), the same kind of classification R-Co's own
service_catalog carries (per svc-01-04-service-scope.md, cited by REQ-041 in
docs/requirements.yaml: "service_catalog is a public-schema routing/registry
table (TNT-01 confirmed)").

OPEN QUESTION, explicitly not resolved here: neither
docs/migration/decisions/0003-ecto-schema-strategy.md nor any other Letflow
decision record states a GENERAL rule for when a table earns this GLOBAL
exception versus Decision B's schema-per-tenant default for ordinary business
tables. This module follows prm-batch1's stated classification for these three
tables specifically -- that part is settled -- but the underlying general
question is left open, flagged here as worth a future REVIEWER/decision-record
follow-up rather than something each later requirement re-derives ad hoc.
```

---

## 8. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Identity.Tenant` | `SolutionPackInstall` → `Letflow.Identity` | `belongs_to(:tenant, ...)` association (§5.1) — the only schema in this design with a real Ecto association to another module, enabled by both living in the public/default schema. |
| `Letflow.Repo` | schema modules → Repo | Only at whichever future requirement's call time (§1) — REQ-041 adds no `Repo` call of its own beyond `compute_pack_update_plan/5`'s own read queries against `solution_pack_artefact_bases`/`pack_update_resolutions`. |
| REQ-015 (`tenants`) | REQ-041 → REQ-015 | `depends_on: [REQ-015]` per `docs/requirements.yaml` — the real FK target (§3.1). |
| REQ-022 (tenant schema provisioning) | REQ-041 explicitly does NOT depend on this | REQ-041's tables are GLOBAL; no `:prefix` mechanism, no manifest entry (§4.1). Named here specifically to make the *absence* of this usual S2 dependency explicit, not overlooked. |
| REQ-036 (`compute_plan_digest/1`, canonical JSON) | REQ-041 references REQ-036's stated normalization convention textually, no code dependency | `depends_on` does NOT list REQ-036 (`docs/requirements.yaml:1998`); REQ-036 is `status: pending` (§0). §5.4/OQ-1 states this gap explicitly. |
| SOL-01/02/03 (`src/solution/`, unscoped) | Future requirement → REQ-041 | Will be the real writer of `solution_pack_installs`/`solution_pack_artefact_bases`, and the real caller of `compute_pack_update_plan/5` with live `theirs_artefacts`/`incoming_artefacts` rather than test fixtures (§1). |
| A later requirement (apply-time enforcement) | Future requirement → REQ-041 | Will read `plan.has_unresolved_conflicts` to reject an apply attempt (§1) — REQ-041 only computes and exposes the flag. |
| `docs/agents/instructions/security-invariants.md` INV-7 | SECURITY-REVIEWER → REQ-041 | Satisfied by §4.2 — zero raw-SQL identifier interpolation introduced. |

---

## 9. Open questions — explicit, not silently resolved

**OQ-1 (MAJOR — flagged per this task's own instruction): canonical-JSON normalization
has no shared implementation to call yet.** REQ-041's text says the comparison uses
"same normalization as REQ-036's plan digest," but REQ-036 is unimplemented
(`status: pending`, §0). This design's resolution (§5.4): `classify_artefact/3` is a
pure byte-equality comparison over content that MUST already be canonical JSON by the
time it reaches this function — the canonicalization step itself (sort keys, strip
insignificant whitespace, per REQ-036's own description) is **not** built by this
requirement, and is **not** reimplemented here as a private duplicate of what REQ-036
will eventually provide. Left open: whether a future requirement should extract a
shared `Letflow.Definitions.CanonicalJson`-shaped helper both REQ-036's
`compute_plan_digest/1` and this requirement's callers (whoever eventually writes
`base_content`/`theirs_artefacts`/`incoming_artefacts`) call, rather than each
independently trusting its caller to have canonicalized first. REVIEWER should
re-confirm this scope boundary is acceptable rather than treat it as settled.

**OQ-2 (as required by REQ-041 acceptance criterion 5): the general
GLOBAL-vs-PER_TENANT rule.** Discussed in full in §2 and restated in the required
moduledoc text (§7). Restated compactly here: this design does not propose what the
general rule should be — that is explicitly REQ-041's own instruction to leave open,
not this design's judgment call to make. See §2's cross-reference to `req035` §9 OQ-2
for the sibling data point on the same still-open question.

PROVENANCE (historical, not current decision authority):
**OQ-3 (RESOLVED, verified against R-Co GH#325): `installed_version`/`base_version`/
`target_version` are `:string`, not `:integer` — confirmed.** R-Co's
`migrations/1157_prm09_solution_pack_update.sql` declares
`solution_pack_installs.installed_version` as `TEXT NOT NULL`, and
`src/definition/pack_update.zig` carries `base_pack_version`/`incoming_pack_version`
as `[]const u8` (a byte-string slice, not a numeric type) throughout the diff
pipeline. No integer parsing or numeric comparison of version values occurs anywhere
in `pack_update.zig`. `:string` is confirmed as the correct shape, not merely the
least-assuming one.

**OQ-4 (MINOR): `artefact_type` carries no enum, no CHECK constraint** — same
open-ended-text treatment `req035` §9 OQ-1 gives `def_type`, for the same reason (no
source available names the closed set of legal values). Whether a CHECK/`Ecto.Enum`
should be added once the real artefact-type set is known (via SOL-01/02/03) is left
for a future requirement.

**OQ-5 (MINOR): `pack_update_resolutions` is scoped per `target_version`, not
permanent.** This design's own choice (§3.3), not literally mandated by REQ-041's
text — a resolution made against one incoming version does not automatically carry
forward to a later, different incoming version's preflight. Flagged as a design
decision a future requirement could revisit if it turns out resolutions should persist
across update attempts.

**OQ-6 (MINOR): `resolution`'s three-value enum was originally this design's own enumeration**, not sourced from R-Co (§0 — no access to
prm-batch1's actual schema at design time).

PROVENANCE (historical, not current decision authority):
**RESOLVED by REQ-147 (2026-08-24).** `R-Co/src/definition/pack_update.zig:25-29` defines
`pub const ResolutionKind = enum { keep_local, take_incoming, merged };`. Two of the three
original atom names diverged (`keep_theirs` vs. R-Co's `keep_local`; `custom` vs. R-Co's
`merged`). REQ-147 renamed both: the Ecto.Enum values in
`lib/letflow/definitions/pack_update_resolution.ex` are now exactly `[:keep_local,
:take_incoming, :merged]`, and migration
`priv/repo/migrations/20260824143417_rename_resolution_enum_values.exs` handles any
in-flight rows (none existed — the write path was never built per REQ-041 scope note).

**OQ-7 (MINOR): `pack_update_resolutions.resolved_by` has no FK to `users.id`**, even
though both tables are GLOBAL here (unlike `req035`'s cross-schema reason for omitting
the same FK on `promotion_reviews`). This design omits it anyway because REQ-041 names
no requirement that this column be validated referentially, and adding one is
unrequested scope — but unlike `req035`'s omission (forced by a real cross-schema
constraint), this one is a pure judgment call and could reasonably go the other way.
Flagged explicitly so REVIEWER can override it if a real FK is preferred here.

**OQ-8 (INFORMATIONAL): `SolutionPackInstall` uses `belongs_to(:tenant, ...)`;
`SolutionPackArtefactBase`/`pack_update_resolutions`' schema does not**, despite both
having the identical real FK to `tenants.id` (§3.1/§3.2/§3.3). Reasoning given in §5.2 —
recorded here so the asymmetry reads as a deliberate choice if ever questioned, not an
inconsistency.

**OQ-9 (INFORMATIONAL): `plan()`/`plan_entry()` are specified as `@type`-over-map, not
`defstruct`.** ELIXIR-DEV may promote either to a lightweight non-Ecto `defstruct` at
implementation time without contradicting this design — §5.3 states this is not
mandated either way.

**OQ-10 (MINOR): the `{:error, :empty_artefact_set}` case is this design's own
addition**, mirroring REQ-036's empty-plan error but not literally required by any of
REQ-041's 5 acceptance criteria. Flagged so CODE-DESIGN-VALIDATOR/REVIEWER can strike
it if judged out of scope for this requirement specifically.

---

## 10. Acceptance-criteria traceability

| REQ-041 acceptance criterion | Concrete design element |
|---|---|
| 1. "priv/repo/migrations gains solution_pack_installs, solution_pack_artefact_bases, and pack_update_resolutions migrations in the public/default schema (not :prefix-scoped), applying cleanly" | §3 (all three table specs) + §4 (migration file plan) + §4.1 (explicit no-guard, no-manifest-edit instruction) + INV-PU-1 |
| 2. "compute_pack_update_plan/5 against an artefact with no matching solution_pack_artefact_bases row classifies it as conflict, not unchanged or an error, per PRM-09 AC5" | §5.3 `classify_artefact/3` truth table (`base = nil` row) + §3.2.1 (why no FK forces this case to stay representable) + §4.3 (demonstration method) + INV-PU-2 |
| 3. "compute_pack_update_plan/5 against base==theirs!=incoming classifies clean_update; base==incoming!=theirs classifies local_only; base==theirs==incoming classifies unchanged -- each with an explicit test" | §5.3 `classify_artefact/3`'s full truth table (all three non-nil-base rows named explicitly) + INV-PU-3 |
| 4. "has_unresolved_conflicts is true when at least one conflict-classified artefact has no matching pack_update_resolutions row, and false once every conflict artefact has one" | §3.3 (table + unique index) + §5.3 "has_unresolved_conflicts computation" (exact formula) + INV-PU-4 |
| 5. "the moduledoc explicitly flags the GLOBAL-vs-PER_TENANT classification question as unresolved beyond this requirement's own scope, per this requirement's description" | §7 (required verbatim moduledoc text) + §2 (full discussion) + §9 OQ-2 + INV-PU-7 |
