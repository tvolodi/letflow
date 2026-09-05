# Design: REQ-037 — Promotion review state machine and base promote

**Requirement:** REQ-037 (`docs/requirements.yaml` lines 1716–1776, stage S2,
`depends_on: [REQ-035, REQ-036]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ037-20260817`, WF-02 Step 1
**This document produces:** module/function signatures, struct/type shapes, the full
error taxonomy, the DB access pattern, the state-machine algorithm, and invariants —
**no implementation code**. No function bodies, no `.ex` files. Matches the convention
already validator-approved in `lib/letflow/design/promotion_plan.md` (REQ-036) and
`req033-snapshot-store.md` §0 — ELIXIR-DEV writes the real version.

Domain logic only. No HTTP/Plug layer here (S4 scope, same carve-out REQ-036 used).

**REWORK ITERATION 1 (2026-08-17):** SECURITY-REVIEWER FAILed the original version of
this design at Step 2c (BLOCKER, INV-1/2026-08-17 addendum to Decision 0003 —
`handoffs/WF02-REQ037-20260817/step-02c-security-reviewer.json`) because §2.3
(`insert_review/2`) sourced `tenant_id` from caller-supplied `args.plan.target_tenant_id`
instead of deriving it from `opts[:prefix]`. §2.3 and §2.8 below are revised to fix
this; every other section is unchanged from the original design except two small
downstream corrections (§3.2 step 1's rationale, §8's dependency list) needed to keep
the doc internally consistent with the §2.3 fix.

---

## 0. Sources read for this design

**Letflow project docs, read in full:**

- `docs/requirements.yaml` — REQ-037's full entry (1716–1776); REQ-035 (1639–1716 area,
  `promotion_reviews` schema/migration); REQ-036 (1639–1714, `PromotionPlan`/
  `PromotionConflict`/`PromotionDigest`); REQ-030 (1339–1420ish, `process_definitions`
  CRUD — confirmed **not yet shipped**, see §2 below); REQ-041 (`Letflow.Definitions`
  context module — confirmed it does not yet host any promotion-family function).
- `docs/agents/instructions/core-directives.md`, `docs/anti-patterns.md`,
  `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1.
- `docs/guides/backend_developer_guide.md` — §3.2 (`:gen_statem` only for a real named-
  state machine with process-local data; §3.5 confirms this codebase already treats
  `promotion_reviews` as the "independent-flags/DB-row state machine" category, same as
  `lib/letflow/row_approval.ex` — see §1.1 below for why this design follows that
  precedent, not `:gen_statem`), §3.5 (error shapes), §3.6 (no raw SQL string
  interpolation).
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant isolation via
  `:prefix`, 2026-08-17 addendum on `tenant_id` derivation).
- `lib/letflow/design/promotion_plan.md` (REQ-036's own design doc) — read in full,
  especially §9.1 (the `permission_checker`/`tenant_classifier` opts pattern, no
  built-in default for the former, `default_tenant_classifier/1` always `:test` for the
  latter) and §7 (the explicit forward-reference: *"`PromotionConflict.reject_if_conflicts/4`'s
  `base_version` argument ... fed verbatim ... by REQ-037's caller at approval time --
  the PRM-01/PRM-02 handoff point"*) — this is a load-bearing cross-reference this
  design must resolve, not skip (see §4.2 step 6).

**Letflow shipped code, read directly (not assumed):**

- `lib/letflow/definitions/promotion_review.ex` — full file. Confirmed
  `promotion_reviews` schema fields exactly: `tenant_id, plan_digest, def_type
  (default "process"), def_id, serialised_plan, status (Ecto.Enum, 6 values,
  default :pending_review), requested_by, approved_by, approved_at, superseded_by,
  row_version (default 1)`. Confirmed `insert_changeset/2`'s castable field list
  (`tenant_id, plan_digest, def_type, def_id, serialised_plan, requested_by` — **not**
  `status`/`approved_by`/`approved_at`/`superseded_by`/`row_version`) and its
  `unique_constraint([:tenant_id, :plan_digest], name: :uq_promotion_review_active_digest)`
  declaration. Confirmed the moduledoc's own explicit statement that `row_version` is
  an **optimistic-locking column** (REQ-035 AC3), manipulated only via raw
  `Repo.update_all`-style guarded UPDATEs, never `Ecto.Schema.optimistic_lock/2,3` and
  never a changeset-mediated update (no `update_changeset/2` exists on this module).
  Confirmed the moduledoc's own two open questions (`def_type`'s open-endedness,
  PER_TENANT classification) — neither is this design's concern to resolve.
- `priv/repo/migrations/20260816200001_create_promotion_reviews.exs` — full file.
  Confirmed the exact partial unique index:
  `unique_index(:promotion_reviews, [:tenant_id, :plan_digest], name:
  :uq_promotion_review_active_digest, where: "status IN ('pending_review', 'approved')",
  prefix: prefix())`. This is the constraint `insert_review/2` (§3.2) must map to
  `{:error, :duplicate_review}`. Also confirmed `superseded_by` is a bare `:binary_id`
  column with **no FK** and REQ-035's own migration header states its "exact target row
  is not specified by REQ-035's own text" (design doc OQ-3) — this design resolves that
  open question explicitly (§3.6).
- `lib/letflow/definitions/promotion_plan.ex` — full file. Confirmed `PromotionPlan.t()`
  shape (`source_tenant_id, target_tenant_id, process_key, source_definition_id,
  target_definition_id, base_version, entries`), `promotion_opts()`
  (`permission_checker, tenant_classifier, variable_schema_fetcher`),
  `compute_error()`, `default_permission_checker/2` (always `true`, no real
  enforcement), `default_tenant_classifier/1` (always `:test`). Confirmed
  `compute_promotion_plan/5`'s exact step order (permission check first, before any
  read; tenant-classifier check second, still before any `process_definitions` read).
- `lib/letflow/definitions/promotion_digest.ex` — full file. Confirmed
  `compute_plan_digest/1` hashes `plan.entries` only (not the full envelope) and
  `verify_digest/2`'s two clauses: binary-vs-binary uses `:crypto.hash_equals/2`
  directly; plan-map-vs-binary recomputes first. Both branches always end in
  `:crypto.hash_equals/2`, never `==`/`=:=`.
- `lib/letflow/definitions/process_definition.ex` — full file. Confirmed
  `process_definitions` schema (`tenant_id, name, version, description, status
  (:draft/:active/:deprecated/:archived, lowercase-dumped), stage, graph (:map),
  created_by, archived_at`), `create_changeset/2`'s exact castable fields, and the two
  unique constraints (`uq_definition_version` on `[:name, :version]`,
  `uq_active_definition` on `:name` where active). Confirmed **no CRUD context
  functions exist yet** — `grep -rn "def activate\|def create" lib/letflow/definitions/
  lib/letflow/definitions.ex` returns nothing; REQ-030 (owner of `activate/1`/`create/1`)
  is `status: in_progress` in `docs/requirements.yaml` and not shipped. This directly
  shapes §4's design: `promote_definition/N` cannot call a not-yet-existing
  `activate/1` — it must implement the PD-03 two-step swap itself, inline (§4.2 step 7,
  flagged as a duplication risk in §5 Open Questions).
- `lib/letflow/definitions.ex` — full file (REQ-041). Confirmed it exposes
  `compute_pack_update_plan/5`/`classify_artefact/3` only, no promotion-family
  function — matching REQ-036's own precedent of NOT retrofitting promotion functions
  into this top-level context module. This design follows the same precedent: new
  sibling submodules under `lib/letflow/definitions/`, not `Letflow.Definitions.*`
  additions.
- `lib/letflow/definitions/snapshot_store.ex` + `lib/letflow/definitions/
  instance_definition_snapshot.ex` — read in full for the **schema-module vs.
  context-module split precedent**: `InstanceDefinitionSnapshot` (Ecto schema +
  changesets only) pairs with a separate `SnapshotStore` (context module, "Context
  module for `Store.create`/`Store.get`"). This is the direct precedent §1.2 follows:
  `PromotionReview` (schema, REQ-035, already shipped) pairs with a NEW
  `PromotionReviewStore` (context module, this design), rather than bolting transition
  functions onto the schema module itself.
- `lib/letflow/event_store.ex` — full file. Confirmed `append/2`'s exact contract:
  `opts[:prefix]` required; `attrs[:instance_id]` must resolve to an existing,
  non-terminal `instance_projections` row (M1 `active_instance_guard`) or the call
  fails `{:error, :instance_not_started}` — **`append/2` never originates an
  `instance_projections` row**. Confirmed the three platform sentinel accessors
  (`platform_instance_id/0` etc.) exist but their own doc states `PLATFORM_INSTANCE_ID`
  is "never inserted into `instance_projections`" — so even the sentinel does not give
  `append/2` a working non-instance-scoped path today. This is a real, load-bearing gap
  for `promote_definition/N`'s event-append half — resolved via an injected
  `opts[:event_appender]` with no built-in default, not by pretending `append/2` already
  supports this (§4.2 step 9, §5 OQ-1).
- `lib/letflow/event_store/registry.ex` — full file (`register_type/2` header + doc).
  Confirmed event types are registered **per tenant** (`event_type_registry` is
  tenant-scoped) and nothing in this codebase registers a `DEFINITION_PROMOTED`-shaped
  type anywhere yet (`grep -rn "register_type" lib/` outside `registry.ex` itself finds
  no call sites) — a second, independent confirmation of the OQ-1 gap above.
- `lib/letflow/tenant_provisioning.ex` — full file. Confirmed `schema_name_for_tenant/1`
  is a pure, no-I/O derivation returning `{:error, :invalid_tenant_id}` on a bad UUID —
  used throughout this design to derive `:prefix` from a `tenant_id`.
- `test/letflow/event_store_test.exs` — read the concurrent-append test (lines
  ~360–405): a `Task.async` + `send(parent, {:ready, self()})` / `receive do :go end`
  barrier idiom, already established in this codebase for forcing two calls to race at
  the DB layer. §4.4 below reuses this exact idiom for AC4's concurrent-`approve_review`
  test, rather than inventing a new mechanism.

PROVENANCE (historical, not current decision authority):
**R-Co source** (`src/definition/promotion_review.zig` PRM-04, `src/definition/
promotion.zig` ENV-03, and `src/design/prm-04-promotion-review-state-machine.md`):
**genuinely unreachable on this host**, re-checked fresh for this run:

```
$ find / -maxdepth 4 -iname "R-Co" 2>/dev/null
(no output)
$ find / -iname "promotion_review.zig" -o -iname "prm-04*" 2>/dev/null
(no output)
```

This design therefore works from `docs/requirements.yaml`'s REQ-037 entry (a detailed
paraphrase of PRM-04/ENV-03) plus direct inspection of every Letflow module named
above, exactly as REQ-036's own design doc did. Every place R-Co's source might have
settled a question differently is flagged in §5, not guessed silently.

---

## 1. Scope boundary and two structural decisions

### 1.1 Plain Ecto context module, not `:gen_statem`

`promotion_reviews` is a DB-row state machine with linear status transitions gated by
column values (`status`, `row_version`, `requested_by`) — not a long-lived, in-memory,
one-process-per-entity workflow the way `lib/letflow/process_instance.ex` and
`lib/letflow/parallel_approval.ex` are. Backend guide §3.2's own dividing line
("independent-flags/single-terminal-value convergence → plain Ecto + context module;
named-state-with-ordering-constraints → `:gen_statem`") is ambiguous on its face for a
6-state machine, but the concrete precedent that already resolved this exact class of
problem is `lib/letflow/row_approval.ex` (also DB-row-backed, also has named states with
real ordering constraints, explicitly chosen as "simpler" per that guide section) —
and, more directly, `Letflow.Definitions.ProcessDefinition`'s own `status` column
(`draft → active → deprecated → archived`) is transitioned via guarded
`Repo.update_all`, not a `:gen_statem`. Every transition here is a single request/reply
DB call with no multi-step in-process protocol and no need to survive a process crash
mid-transition (the row itself IS the durable state) — a `:gen_statem` would add a
process lifecycle (start/stop/supervision under some `DynamicSupervisor`) with no
matching requirement anywhere in REQ-037's text. **Design decision, stated explicitly
per backend guide §3.2's instruction to flag this choice:** plain Ecto context module
(`PromotionReviewStore`, §2), guarded raw `Ecto.Query`/`Repo.update_all` transitions —
not `:gen_statem`.

### 1.2 New modules, and the arity/opts resolution that applies to every signature below

Two new sibling submodules under `lib/letflow/definitions/`, following the
`InstanceDefinitionSnapshot`/`SnapshotStore` schema-vs-context split (§0):

PROVENANCE (historical, not current decision authority):
| File | Module | Ported from |
|---|---|---|
| `lib/letflow/definitions/promotion_review_store.ex` | `Letflow.Definitions.PromotionReviewStore` | `promotion_review.zig`, PRM-04 |
| `lib/letflow/definitions/promotion.ex` | `Letflow.Definitions.Promotion` | `promotion.zig`, ENV-03 |

`Letflow.Definitions.PromotionReview` (REQ-035, already shipped) stays schema +
changesets only — untouched by this design, matching its own moduledoc's "do not read
this module as [REQ-037] landing early."

**Arity resolution (applies uniformly, stated once here rather than repeated per
function):** REQ-037's own requirement text and this run's handoff describe the six
transition functions with arities that omit a `:prefix`-carrying `opts` argument for
five of the six (`insert_review/1`, `reject_review/2`, `mark_review_applied/1`,
`mark_review_failed/1`, `supersede_review/2`), while `approve_review/4` explicitly
names `opts` as its counted 4th positional argument. Every one of these functions
writes to `promotion_reviews`, a table with **no `@schema_prefix`** (per its own
moduledoc — schema-per-tenant, `prefix:` required at every call site, same as every
other REQ-022-provisioned table in this codebase). There is no safe way to omit
`:prefix`. This design resolves the inconsistency the same way REQ-036's design doc
resolved its own "5 dimensions" ambiguity (§2.3 there) — as an explicit, stated
decision: **every function below takes `opts` as an additional, mandatory trailing
argument**, incrementing the literal arity named in the requirement text by exactly
one wherever `opts` wasn't already counted. The resulting arities are stated in each
function's own `@spec` below (`insert_review/2`, `reject_review/3`,
`mark_review_applied/2`, `mark_review_failed/2`, `supersede_review/3`,
`approve_review/4` unchanged). Flagged for REVIEWER, not silently diverging from the
requirement's prose without note.

**Explicitly NOT in scope, not silently dropped:**

| Not built here | Owned by |
|---|---|
| `activate/1`/`create/1`/etc. on `process_definitions` | REQ-030 (in progress, not a dependency of this requirement — §4.2 step 7 does NOT call these, since they don't exist) |
| HTTP layer (`POST /api/v1/promotion-reviews/:id/approve` and friends) | S4 |
| Registering a `DEFINITION_PROMOTED`-equivalent event type in `event_type_registry` | Unassigned — §5 OQ-1 |
| The orchestration that calls `promote_definition/N` then `mark_review_applied/1` (or `mark_review_failed/1` on failure) | REQ-040 (per REQ-037's own requirement text: "driven by REQ-040's assertion re-run outcome, called from there") |
| `rollback_definition_version/4` | REQ-038 |

---

## 2. Module 1 — `Letflow.Definitions.PromotionReviewStore`

### 2.1 The state machine — exactly 7 permitted edges

```
                 insert_review/2
                        |
                        v
                 [pending_review]
                   /            \
      approve_review/4      reject_review/3
                 /                  \
                v                    v
          [approved]              [rejected]
           /        \                  \
mark_review_applied/2  mark_review_failed/2   \
         /                    \                \
        v                      v                 \
    [applied]              [failed]                \
        \                      /                     |
         \                    /                      |
          `--- supersede_review/3 (all 3 edges) ------'
                        |
                        v
                  [superseded]
```

| # | Edge (from → to) | Function | Extra gates beyond status+row_version |
|---|---|---|---|
| 1 | `pending_review → approved` | `approve_review/4` | self-approval, digest match |
| 2 | `pending_review → rejected` | `reject_review/3` | none |
| 3 | `approved → applied` | `mark_review_applied/2` | none |
| 4 | `approved → failed` | `mark_review_failed/2` | none |
| 5 | `applied → superseded` | `supersede_review/3` | none |
| 6 | `failed → superseded` | `supersede_review/3` | none |
| 7 | `rejected → superseded` | `supersede_review/3` | none — **the NEW edge** PRM-04 adds; `rejected` is NOT terminal |

`superseded` is the only terminal state. No function transitions out of `superseded`.

**INV-PRM04-1 (invalid-transition catch-all — the explicit invariant the task
demands):** every one of the six transition functions has a hardcoded, closed
`allowed_source_statuses` set (a plain list of 1–3 atoms, never a computed or "default
allow" set):

| Function | `allowed_source_statuses` |
|---|---|
| `approve_review/4` | `[:pending_review]` |
| `reject_review/3` | `[:pending_review]` |
| `mark_review_applied/2` | `[:approved]` |
| `mark_review_failed/2` | `[:approved]` |
| `supersede_review/3` | `[:applied, :failed, :rejected]` |

For **any** call where the row's actual current `status` is not a member of that
function's `allowed_source_statuses` — whether discovered at the pre-read (§2.2 step 2)
or only at the guarded `UPDATE`'s `WHERE` clause (§2.2 step 4, the race case) — the
function returns `{:error, :invalid_transition}`. This is the same error atom for
*every* illegal edge regardless of which one was attempted (`rejected → approved`,
`pending_review → applied`, `superseded → anything`, etc. all collapse to this one
atom) — there is no per-illegal-edge error variant. `insert_review/2` (§2.3) is the
only function that can *originate* a `pending_review` row; no function can move a row
backward into `pending_review`, and no function can move a row out of `superseded` —
both follow structurally from no function listing either as a member of its own
`allowed_source_statuses` set, not from a separate check.

### 2.2 Generic transition algorithm (shared shape — stated once, referenced by §2.4–2.7)

Every transition function except `insert_review/2` (§2.3, an INSERT not an UPDATE)
follows this shape. Function-specific gates (self-approval, digest — `approve_review/4`
only) are inserted between steps 2 and 3, never before step 1 or after step 4:

1. `Repo.get(PromotionReview, review_id, prefix: prefix)`. `nil` →
   `{:error, :review_not_found}`.
2. Pre-check: `row.status in allowed_source_statuses` (this function's fixed set, §2.1
   table). `false` → `{:error, :invalid_transition}` — a fast, non-authoritative
   rejection that avoids issuing a doomed `UPDATE`. (Function-specific gates, when
   present, run here — after this pre-check, before step 4.)
3. *(approve_review/4 only, §2.4)* self-approval gate, then digest gate.
4. **Authoritative step — the only step that can produce a false-positive-avoiding
   `:ok`:** one `Ecto.Query`/`Repo.update_all/3` call —
   `from(p in PromotionReview, where: p.id == ^review_id and p.status == ^row.status
   and p.row_version == ^row.row_version, select: p)` — `[set: [<new columns>,
   row_version: row.row_version + 1]]`, `prefix: prefix`. This is a single SQL
   statement; Postgres's row-level locking under the default READ COMMITTED isolation
   makes its `WHERE` re-evaluate against the row's state **at execution time**, not at
   step 1's read time — this is what makes the race in §4.4 deterministic. `select: p`
   (Postgres `RETURNING`) means a successful call returns `{1, [updated_row]}` — no
   second read needed. Zero rows affected (`{0, []}`) → `{:error, :invalid_transition}`
   — the row changed between step 1 and step 4 (lost the race, or an intervening
   concurrent call already moved it). One row affected → `{:ok, updated_row}`.

No `Repo.transaction/1` wraps steps 1–4: correctness comes entirely from step 4's own
`WHERE` clause, not from steps 1 and 4 being atomic as a pair — this is the standard
optimistic-locking shape (contrast with `InstanceSequence`'s `FOR UPDATE` pessimistic
lock in `EventStore.append/2`, a different mechanism for a different problem). This
also matches `PromotionReview`'s own moduledoc, which specifies the guarded-`UPDATE`
shape exactly this way and explicitly rules out `Ecto.Schema.optimistic_lock/2,3`
(raises `Ecto.StaleEntryError`, not a rows-affected count).

### 2.3 `insert_review/2`

**REWORK ITERATION 1 (this section revised — see `handoffs/WF02-REQ037-20260817/
step-02c-security-reviewer.json`):** the version of this section SECURITY-REVIEWER
FAILed built `attrs.tenant_id` from `args.plan.target_tenant_id` — a field read out of
the caller-supplied `plan` map — while treating `opts[:prefix]` as an independently
trusted, separate value, with nothing tying the two together. That is precisely
rejected option (a) from `docs/migration/decisions/0003-ecto-schema-strategy.md`'s
2026-08-17 addendum ("Caller supplies `tenant_id` as an explicit parameter" —
"a call writing into tenant A's schema could pass `tenant_id = B`, and nothing ...
rejects it"). The addendum's own **adopted** resolution is option (c), "Derive it from
the resolved schema at write time" — not a validate-and-reject variant (that would be a
fourth, never-proposed option; the addendum names exactly three, and only (c) was
accepted). This revision applies (c) directly: `attrs.tenant_id` is now derived from
`opts[:prefix]` via `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, the exact
reverse-mapping function the addendum names for this purpose (already shipped for
REQ-025; confirmed directly against `lib/letflow/tenant_provisioning.ex:100-115` this
session — pure, no I/O, returns `{:ok, tenant_id}` for a schema name shaped like
`"tenant_" <> <32 lowercase hex>`, `{:error, :invalid_schema_name}` for anything else).
`args.plan.target_tenant_id` is **no longer read for this purpose at all** — not
cross-validated against the derived value either, since the addendum's adopted
resolution is derivation, not validation of a caller-supplied value (validating a value
this design then discards would just be dead code). `args.plan.target_tenant_id`
remains part of the JSON envelope persisted into `serialised_plan` (step 4 below,
unchanged) for `promote_definition/N`'s own use of the plan — see §3.2 step 1, which
already reads `target_tenant_id` from `review.tenant_id` (the schema column), not from
the JSON blob, so that downstream trust point is anchored on this section's now-correct
derivation, not on the plan's copy.

This exactly mirrors the shipped precedent the addendum itself produced:
`Letflow.EventStore.append/2`'s moduledoc (`lib/letflow/event_store.ex:9-18`) states
"`tenant_id` is always derived from `opts[:prefix]` via
`Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, never accepted from
`attrs`." `insert_review/2` now follows the identical shape — the only difference is
that `attrs.tenant_id` here is populated by this design's own derivation step rather
than being forbidden from `args` outright (there is no bare `tenant_id` key in
`insert_review/2`'s `args` shape to reject in the first place; `args.plan` is a
`PromotionPlan.t()` struct with `target_tenant_id` as one of several load-bearing
fields the plan needs for its own purposes, not a pass-through attrs map).

```
@type insert_review_error ::
        :duplicate_review
        | :digest_mismatch
        | :invalid_schema_name
        | Ecto.Changeset.t()

@spec insert_review(
        args :: %{
          required(:plan) => PromotionPlan.t(),
          required(:digest) => String.t(),
          required(:requested_by) => Ecto.UUID.t()
        },
        opts :: [prefix: String.t()]
      ) :: {:ok, PromotionReview.t()} | {:error, insert_review_error()}
```

**Algorithm:**

1. **Digest re-verification (design addition, not literally required by REQ-037's
   text — justified below):** `PromotionDigest.verify_digest(args.digest, args.plan)`
   — `false` → `{:error, :digest_mismatch}`. *Why:* `PromotionDigest`'s own INV-PRM-5
   (promotion_plan.md §8) states `verify_digest/2` must be the **only** comparator
   ever used against a `plan_digest`-shaped value anywhere in this codebase; a caller
   that passes a `digest` string not actually derived from `plan` would otherwise let
   a wrong/stale digest persist into `promotion_reviews.plan_digest` with nothing ever
   catching it. Cheap, and closes that gap.
2. Resolve `prefix` from `opts` (`Keyword.fetch!/2` — no default; matches
   `PromotionPlan`'s own no-default stance on required config).
3. **Derive `tenant_id` from `prefix`, not from `args.plan` (the fix this rework
   iteration adds):** `TenantProvisioning.tenant_id_for_schema_name(prefix)` —
   `{:error, :invalid_schema_name}` → return `{:error, :invalid_schema_name}`
   immediately, before any changeset is built or any DB call is attempted (same
   short-circuit-before-I/O placement `promote_definition/N` already uses for its own
   `schema_name_for_tenant/1` calls, §3.2 step 4). `{:ok, tenant_id}` → continue to
   step 4 with this `tenant_id`, not `args.plan.target_tenant_id`.
4. Build changeset attrs: `%{tenant_id: tenant_id, plan_digest:
   args.digest, def_id: args.plan.process_key, serialised_plan: Jason.encode!(args.plan),
   requested_by: args.requested_by}` — `tenant_id` here is step 3's derived value.
   **`def_type` is deliberately omitted** — falls
   through to `PromotionReview`'s own struct default (`"process"`), since
   `PromotionPlan.t()` has no `def_type`-equivalent field (§5 OQ-2 restates this).
   **`serialised_plan` is `Jason.encode!/1` of the FULL `PromotionPlan.t()` envelope
   (`source_tenant_id`, `target_tenant_id`, `process_key`, `source_definition_id`,
   `target_definition_id`, `base_version`, `entries`) — not just `entries`.** This is a
   load-bearing, explicit resolution of an ambiguity in REQ-037's prose (which only
   says "serialised_plan"): `promote_definition/N` (§3.2 step 1) must recover
   `source_tenant_id` and `base_version` from this column later, and neither survives
   if only `entries` is stored. Stated here explicitly, not left for ELIXIR-DEV to
   guess narrower. `target_tenant_id` is stored here as part of the full envelope (for
   any future consumer that needs the plan's own record of its intended target) but is
   never again treated as an attribution-bearing value by this module or by
   `promote_definition/N` (§3.2 step 1) — only `review.tenant_id`, this step's derived
   column, is.
5. `PromotionReview.insert_changeset(%PromotionReview{}, attrs) |> Repo.insert(prefix:
   prefix)`.
6. On `{:error, changeset}`: inspect `changeset.errors` for a `:unique` constraint
   error tagged `constraint_name: "uq_promotion_review_active_digest"` (Ecto's
   `unique_constraint/3` already declares this mapping in `insert_changeset/2` — see
   §0 — so this is a `changeset.errors` pattern match, not a raw
   `Postgrex.Error`/`Ecto.ConstraintError` inspection). Match → `{:error,
   :duplicate_review}` (AC1's explicit demand — never leak the raw changeset for this
   one case). Any other changeset error (missing required field, format mismatch,
   etc.) → `{:error, changeset}`, passed through unchanged.

### 2.4 `approve_review/4`

```
@type approve_review_error ::
        :review_not_found
        | :self_approval_forbidden
        | :digest_mismatch
        | :invalid_transition

@spec approve_review(
        review_id :: Ecto.UUID.t(),
        actor_id :: Ecto.UUID.t(),
        plan_digest :: String.t(),
        opts :: [prefix: String.t()]
      ) :: {:ok, PromotionReview.t()} | {:error, approve_review_error()}
```

Follows §2.2's generic shape with these gates inserted at step 3, **in this exact
order** (per the task's explicit "IN ORDER" instruction — no gate short-circuits past
an earlier one, and no gate is skipped just because a later one would also fail):

- **Gate (a) — self-approval, checked immediately after step 1's read, strictly before
  step 4's `UPDATE` is ever issued (task's explicit "BEFORE any row update"):**
  `row.requested_by == actor_id` → `{:error, :self_approval_forbidden}`. Distinct atom
  from every other gate's error, per AC2's explicit demand.
- **Gate (b) — status, folded into §2.2 step 2's generic pre-check** (`allowed_source_statuses
  = [:pending_review]`, §2.1 table) → `{:error, :invalid_transition}` on mismatch.
- **Gate (c) — digest match:** `PromotionDigest.verify_digest(row.plan_digest,
  plan_digest)` — **note the argument order**: `verify_digest(digest, plan_or_digest)`
  per `PromotionDigest`'s own `@spec` (§0), so the STORED value (`row.plan_digest`) is
  the first argument (`digest`) and the CALLER-SUPPLIED value (`plan_digest`) is the
  second (`plan_or_digest`, binary-vs-binary branch, `:crypto.hash_equals/2`
  internally). `false` → `{:error, :digest_mismatch}`. Distinct atom from gates (a)
  and (d), per AC3's explicit demand.
- **Gate (d) — the guarded `UPDATE` (§2.2 step 4):** `set: [status: :approved,
  approved_by: actor_id, approved_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
  row_version: row.row_version + 1]`. Zero rows affected →
  `{:error, :invalid_transition}` (this is AC4's race outcome — see §4.4). One row →
  `{:ok, updated_row}`.

No `permission_checker`/`tenant_classifier` opt on this function — REQ-037's own text
names only the 3 gates above plus the row_version lock; adding a 4th "does actor hold
promotion.approve" gate here is not requested by any of REQ-037's 6 acceptance
criteria. Flagged as a real, adjacent gap in §5 OQ-3 rather than silently added or
silently ignored.

### 2.5 `reject_review/3`

```
@spec reject_review(
        review_id :: Ecto.UUID.t(),
        actor_id :: Ecto.UUID.t(),
        opts :: [prefix: String.t()]
      ) :: {:ok, PromotionReview.t()} | {:error, :review_not_found | :invalid_transition}
```

Follows §2.2's generic shape verbatim, no extra gates (`allowed_source_statuses =
[:pending_review]`). **No digest check, no self-rejection restriction** — per PRM-05's
explicit "Reject does NOT have the same restriction" as approve, restated in REQ-037's
own text. `set: [status: :rejected, row_version: row.row_version + 1]`.

`actor_id` is accepted (matching the requirement's own named parameter, and kept for
symmetry/future audit use) but **is not persisted anywhere on the row** — the schema
has an `approved_by` column but no `rejected_by` column (confirmed §0), and reusing
`approved_by` to mean "rejecting actor" would corrupt a column whose name specifically
means "who approved." Flagged explicitly in §5 OQ-4, not silently repurposed or
silently dropped from the signature.

### 2.6 `mark_review_applied/2` and `mark_review_failed/2`

```
@spec mark_review_applied(review_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
        {:ok, PromotionReview.t()} | {:error, :review_not_found | :invalid_transition}

@spec mark_review_failed(review_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]) ::
        {:ok, PromotionReview.t()} | {:error, :review_not_found | :invalid_transition}
```

Both follow §2.2's generic shape verbatim, `allowed_source_statuses = [:approved]`,
no extra gates, no `actor_id` parameter (matching the requirement's own literal
signature — and there is no column to persist one anyway: no `applied_by`/`failed_by`
column exists). `mark_review_applied/2` sets `status: :applied`; `mark_review_failed/2`
sets `status: :failed`; both increment `row_version`.

**These two functions do not call `Letflow.Definitions.Promotion.promote_definition/N`
(§3) themselves.** Per REQ-037's own text: `promote_definition/N` is "the operation
`mark_review_applied`'s CALLER invokes" — i.e., some future orchestrator (REQ-040, per
the requirement's own citation) calls `promote_definition/N` first, then calls
`mark_review_applied/2` on success or `mark_review_failed/2` on failure. This design
keeps that decoupling explicit rather than having `mark_review_applied/2` reach out and
call `promote_definition/N` internally, which would make this module depend on
`Letflow.Definitions.Promotion` for no benefit REQ-037's text asks for.

### 2.7 `supersede_review/3`

```
@spec supersede_review(
        review_id :: Ecto.UUID.t(),
        superseded_by_event_id :: Ecto.UUID.t(),
        opts :: [prefix: String.t()]
      ) :: {:ok, PromotionReview.t()} | {:error, :review_not_found | :invalid_transition}
```

Follows §2.2's generic shape verbatim, `allowed_source_statuses = [:applied, :failed,
:rejected]` — **one function for all 3 supersession edges**, per the task's explicit
"not 3 separate functions" instruction; the pre-check (§2.2 step 2) and the guarded
`UPDATE`'s `WHERE p.status == ^row.status` (§2.2 step 4, using whichever of the 3
values was actually read) both work unchanged for any of the 3 source states — no
per-edge branching needed. `set: [status: :superseded, superseded_by:
superseded_by_event_id, row_version: row.row_version + 1]`.

**Resolves REQ-035's own Open Question 3** (`superseded_by`'s target row, left
unspecified by REQ-035's schema/migration — confirmed §0): `superseded_by` stores the
`event_id` of whatever downstream event caused this row to become superseded (e.g. a
later promotion's own applied event, or a future rollback event — REQ-038's concern,
not this one). It is **not** a self-referential `promotion_reviews.id` and **not** a
`users.id` actor reference. This matches the migration's own "NO foreign keys"
rationale (`events` lives in per-tenant event-store tables this schema has no direct FK
path to). This function does **not** validate that `superseded_by_event_id` actually
corresponds to an existing `events` row — no cross-table read-before-write, matching
`PromotionConflict.reject_if_conflicts/4`'s own "plain read, no lock, no cross-
validation beyond what's named" precedent (promotion_plan.md §4.2). Flagged as a
resolved decision, not a silent guess.

### 2.8 2026-08-17 addendum compliance — explicit re-verification, all 6 functions

**Added in this rework iteration**, at the task's explicit request, so this document's
own reasoning is complete and self-contained rather than relying on
SECURITY-REVIEWER's handoff as the only place the "why" is recorded. The addendum to
`docs/migration/decisions/0003-ecto-schema-strategy.md` governs **who computes the
value written into a `tenant_id` column** — it has nothing to say about a function that
never writes that column at all. Checked individually below, against each function's
own `set:`/attrs list stated in its section above:

| Function | Writes `tenant_id`? | `set:`/attrs list (from its own section) | Addendum applies? |
|---|---|---|---|
| `insert_review/2` (§2.3) | **Yes** — the only INSERT in this module, originates the row | `tenant_id, plan_digest, def_id, serialised_plan, requested_by` | **Yes — this is the function the addendum governs.** Fixed in §2.3 above: `tenant_id` is now derived from `opts[:prefix]` via `tenant_id_for_schema_name/1` (addendum resolution (c)), never read from `args.plan.target_tenant_id`. |
| `approve_review/4` (§2.4) | No | `status, approved_by, approved_at, row_version` | Not applicable. `tenant_id` is not in the `set:` list — the column keeps whatever value `insert_review/2` wrote at row-creation time; this function only ever reads it implicitly via the `prefix:`-scoped `Repo.get`/`Repo.update_all` (INV-1(a)/(b) territory, not the addendum). |
| `reject_review/3` (§2.5) | No | `status, row_version` | Not applicable, same reasoning. |
| `mark_review_applied/2` (§2.6) | No | `status, row_version` | Not applicable, same reasoning. |
| `mark_review_failed/2` (§2.6) | No | `status, row_version` | Not applicable, same reasoning. |
| `supersede_review/3` (§2.7) | No | `status, superseded_by, row_version` | Not applicable, same reasoning. |

**Why this table is exhaustive:** §2.2's generic transition algorithm (shared by all
five non-`insert_review/2` functions) issues exactly one `Repo.update_all/3` per call,
with a hardcoded `set:` keyword list stated in full in each function's own section —
none of the five lists includes `tenant_id`, and §2.2 itself never appends a computed
`tenant_id` to any function's `set:` list. There is no code path in any of the five
functions that assigns to the `tenant_id` column, so there is no write-time value for
the addendum to have an opinion about — the addendum's scope ("who computes the value
written into a table's `tenant_id` column") is structurally empty for these five.
This is the same conclusion SECURITY-REVIEWER's Step 2c handoff reached ("the 6
`PromotionReviewStore` transition functions all route through `transition/6` ... a
`review_id` from a different tenant's schema simply does not exist in the queried
schema's table, so no cross-tenant read/mutate via `review_id`") — restated here in
this document's own terms (addendum scope, not INV-1(a)/(b) scope) so a future reader
does not have to cross-reference the handoff to see why the other five were left
unchanged.

---

## 3. Module 2 — `Letflow.Definitions.Promotion`

### 3.1 Types

```
@type promote_opts :: [
        permission_checker: (Ecto.UUID.t(), Ecto.UUID.t() -> boolean()),
        tenant_classifier: (Ecto.UUID.t() -> :production | :test),
        event_appender: (event_attrs :: map(), prefix :: String.t() ->
          {:ok, term()} | {:error, term()})
      ]

@type promote_result :: %{
        source_definition_id: Ecto.UUID.t(),
        target_definition_id: Ecto.UUID.t(),
        process_key: String.t()
      }

@type promote_error ::
        :forbidden
        | :invalid_promotion_source
        | :invalid_tenant_id
        | :source_definition_missing
        | :duplicate_version
        | {:conflicts, [PromotionConflict.conflict_detail()]}
        | Ecto.Changeset.t()
        | term()
```

### 3.2 `promote_definition/3` — reuse of REQ-036's opts shape, stated explicitly

```
@spec promote_definition(
        actor_id :: Ecto.UUID.t(),
        review :: PromotionReview.t(),
        opts :: promote_opts()
      ) :: {:ok, promote_result()} | {:error, promote_error()}
```

**Reuse decision (task's explicit ask, item 3):** `permission_checker` and
`tenant_classifier` are the **exact same shape** as `PromotionPlan.promotion_opts()`
(§0) — same function arities, same semantics (`permission_checker` has **no built-in
default**, `Keyword.fetch!/2`, raises `KeyError` if omitted, for the identical reason
`PromotionPlan`'s moduledoc states: no data path from `actor_id` to a real permission
today, so silently defaulting to "allowed" would be worse than crashing;
`tenant_classifier` defaults by **delegating to
`Letflow.Definitions.PromotionPlan.default_tenant_classifier/1`** — not a duplicated
copy of the same one-line function, an explicit `&PromotionPlan.default_tenant_classifier/1`
reference, so the two modules can never silently drift apart on what "test tenant"
means). This is reuse, not reinvention — no divergence to justify.

`variable_schema_fetcher` is **not** carried over — it has no meaning for
`promote_definition/N` (that opt exists only for `PromotionPlan`'s diff-computation
step, §3.4 there); carrying an unused opt forward would be a false signal that this
function reads variable schemas, which it does not.

`opts[:event_appender]` is a **new** opt this design adds, not present on
`PromotionPlan.promotion_opts()` — justified in step 9 below and §5 OQ-1 (there is no
data path from `promote_definition/N` to a working `EventStore.append/2` call today;
this opt is the injection point, deliberately with no built-in default, same reasoning
as `permission_checker`).

**Algorithm, in order (each step short-circuits on failure):**

1. `plan = Jason.decode!(review.serialised_plan)` (a plain string-keyed map — **not**
   re-hydrated into the atom-keyed `PromotionPlan.t()`/`plan_entry()` shape; this
   function never needs `plan["entries"]` at all, see step 6). Extract
   `source_tenant_id = plan["source_tenant_id"]`, `process_key = plan["process_key"]`,
   `base_version = plan["base_version"]`. `target_tenant_id` is read from
   `review.tenant_id` directly (the schema column), not re-parsed from the JSON blob,
   since it is a trusted, typed value on the struct passed in — trusted specifically
   because §2.3 (revised, this rework iteration) derives it from `opts[:prefix]` via
   `TenantProvisioning.tenant_id_for_schema_name/1` at `insert_review/2` time rather
   than accepting it from caller-supplied `plan.target_tenant_id`; this step never
   reads `plan["target_tenant_id"]` for that reason — the JSON envelope's own copy of
   that field is not attribution-bearing (§2.3 step 4's note).
2. `opts[:permission_checker].(actor_id, source_tenant_id)` — `false` →
   `{:error, :forbidden}`. Decoding step 1's JSON is pure, in-memory, not I/O — running
   the permission check right after it (before any DB read) still satisfies
   `compute_promotion_plan/5`'s own "permission check before any read" invariant in
   substance.
3. `opts[:tenant_classifier].(source_tenant_id) == :production` →
   `{:error, :invalid_promotion_source}`. Still no `process_definitions` read.
4. `TenantProvisioning.schema_name_for_tenant/1` on both `source_tenant_id` and
   `target_tenant_id` → `{:error, :invalid_tenant_id}` on either failure.
5. Fresh read: `Repo.get_by(ProcessDefinition, [name: process_key, status: :active],
   prefix: source_prefix)`. `nil` → `{:error, :source_definition_missing}` — **a new
   error case, not present on `PromotionPlan.compute_error()`**: `compute_promotion_plan/5`
   tolerates a `nil` source row (produces an empty-ish plan), but `promote_definition/N`
   has nothing to copy if the source has since been deactivated/archived between
   plan-compute time and approval time — this must be a hard failure, not a silent
   no-op write.
6. **Conflict re-check — resolves REQ-036's own forward-reference** (promotion_plan.md
   §7: "`base_version` ... fed verbatim into `PromotionConflict.reject_if_conflicts/4`'s
   `base_version` argument by REQ-037's caller at approval time"): call
   `PromotionConflict.reject_if_conflicts(actor_id, target_tenant_id, [process_key],
   [base_version])`. `{:error, {:conflicts, list}}` → propagate unchanged. This is
   deliberately placed in `promote_definition/N`, not in `approve_review/4` (§2.4) —
   REQ-037's own text names only 3 gates for `approve_review/4` and none of its 6
   acceptance criteria test a conflict-rejection path there, so adding a 4th gate to
   `approve_review/4` would contradict AC3's literal 3-distinct-error-atom framing.
   `promote_definition/N` is the natural point instead: it is the function that
   actually performs the write, is called at "approval time" in the sense REQ-036's
   design doc means (i.e. once, right before the real mutation, using a **freshly
   re-read** target state rather than the plan's possibly-stale `base_version`
   snapshot — though `base_version` itself, per the plan, is inherently a snapshot;
   `reject_if_conflicts/4`'s own plain-read re-checks the CURRENT target row against
   it). Stated here as this design's own resolution, flagged for REVIEWER since REQ-037's
   text does not itself name this call site.
7. Build the new target row's attrs from the freshly-read `source_row` (step 5) —
   `%{tenant_id: target_tenant_id, name: process_key, version: source_row.version,
   description: source_row.description, stage: source_row.stage, graph:
   source_row.graph, created_by: actor_id}` — via
   `ProcessDefinition.create_changeset/2`, inside one `Repo.transaction/1` together
   with step 8's swap (matching PD-03's "atomic two-step swap in one transaction," the
   same wording REQ-030's own (not-yet-shipped) `activate/1` uses): `Repo.insert(prefix:
   target_prefix)`. On a `uq_definition_version` unique-constraint violation →
   `{:error, :duplicate_version}` (mapped explicitly, mirroring §2.3 step 5's
   constraint-mapping convention — never leak the raw changeset for this one case).
8. Two-step swap, inside the same transaction as step 7 (PD-03 ordering — deprecate
   before activate): (a) guarded `UPDATE process_definitions SET status = 'deprecated'
   WHERE tenant_id = $target_tenant_id AND name = $process_key AND status = 'active'`
   (0 or 1 row, never more — `uq_active_definition` guarantees at most one); (b) guarded
   `UPDATE process_definitions SET status = 'active' WHERE id = $new_row.id AND status =
   'draft'` (exactly 1 row — the row this function itself just inserted with the
   struct's own default `:draft` status, never overridden by `create_changeset/2`,
   which doesn't cast `:status` — confirmed §0). This is inlined here, not delegated to
   REQ-030's `activate/1`, because that function does not exist yet and is not a
   dependency of REQ-037 (§1.2) — flagged as a duplication risk in §5 OQ-5.
9. **Event-append — the "and event-append" half of ENV-03, and the genuine gap this
   design does not paper over (§0, §5 OQ-1):** after the transaction commits (not
   nested inside it — this function does not assume anything about how an arbitrary
   injected `event_appender` manages its own transactionality), call
   `opts[:event_appender].(%{event_type: "DEFINITION_PROMOTED", actor_id: actor_id,
   review_id: review.id, source_tenant_id: source_tenant_id, target_tenant_id:
   target_tenant_id, source_definition_id: source_row.id, target_definition_id:
   new_row.id, process_key: process_key}, target_prefix)`. This design does **not**
   hardcode a call to `EventStore.append/2` here, because that call would deterministically
   fail today: no `DEFINITION_PROMOTED`-shaped type is registered in any tenant's
   `event_type_registry` (§0), and `append/2`'s `instance_id` must resolve to an
   existing, non-terminal `instance_projections` row — there is no notion of a
   definition-level (non-instance-scoped) event stream in the currently-shipped
   `EventStore`, and even `platform_instance_id()` does not resolve to a real row
   (§0). `opts[:event_appender]` has **no built-in default** — `Keyword.fetch!/2`,
   raises `KeyError` if omitted, same reasoning as `permission_checker` (silently
   skipping the event-append half would look like ENV-03 was fully ported when half of
   it structurally cannot run yet). The caller supplies whatever mechanism is actually
   wired up by the time this function is really invoked (REQ-040 or later).
10. Return `{:ok, %{source_definition_id: source_row.id, target_definition_id:
    new_row.id, process_key: process_key}}` if step 9 succeeds; step 9's own error, if
    any, propagates unchanged (`{:error, event_appender_reason}` — this function does
    not roll back the already-committed transaction from step 7/8 on an event-append
    failure; §5 OQ-1 restates the partial-failure window this creates).

---

## 4. Concurrency test mechanism for AC4 (task's explicit demand — spelled out, not
left for TEST-DESIGNER)

**AC4 (`docs/requirements.yaml` line 1773):** *"two concurrent `approve_review/4` calls
on the same `review_id`: exactly one succeeds (row_version optimistic-lock check), the
other gets the invalid-transition error from the zero-rows-affected `WHERE row_version =
$expected` clause."*

**Why a wall-clock race is unnecessary for correctness, but still the right test
shape:** §2.2 step 4's guarantee ("exactly one of two concurrent `UPDATE`s with an
identical `WHERE row_version = $N` succeeds") is enforced by Postgres row-level locking
regardless of how close in time the two calls' internal reads land — even if one call's
step-1 `Repo.get/3` happens to run to completion before the other's even starts, the
OUTCOME is the same shape (one `:ok`, one `:invalid_transition`; the fast path just
takes it at step 2's pre-check instead of step 4's `WHERE`). The barrier below exists to
make the test **reliably exercise the interesting window** (both calls' step-1 reads
observing the same `row_version`, both proceeding to attempt step 4's `UPDATE`) rather
than the trivial serialized case — not because correctness depends on it.

**Concrete recipe — reuses `test/letflow/event_store_test.exs`'s own established
barrier idiom verbatim (§0), applied to `approve_review/4` instead of `EventStore.append/2`:**

1. Fixture: `insert_review/2` one row (`requested_by: user_a`), confirm via a plain
   `Repo.get` that `status == :pending_review` and `row_version == 1`.
2. `actor_id = user_b` (distinct from `user_a`, so gate (a) passes for both calls).
3. `parent = self()`. Build a closure `run = fn -> send(parent, {:ready, self()});
   receive do :go -> :ok after 5000 -> flunk(...) end; PromotionReviewStore.approve_review(review.id,
   user_b, correct_digest, prefix: schema_name) end` — same shape as
   `event_store_test.exs`'s `run.(attrs)` closure.
4. `task1 = Task.async(run)`, `task2 = Task.async(run)`.
5. `assert_receive {:ready, pid1}, 5000`, `assert_receive {:ready, pid2}, 5000`,
   `assert pid1 != pid2` — both tasks are now parked at the barrier, neither has called
   `approve_review/4` yet. (Sandbox mode `:auto` — each `Task` gets its own real,
   independent Postgres connection, matching `event_store_test.exs`'s own comment on
   this exact point.)
6. `send(pid1, :go)`, `send(pid2, :go)` — release both simultaneously.
7. `result1 = Task.await(task1, 5000)`, `result2 = Task.await(task2, 5000)`.
8. **Deterministic assertions, independent of interleaving:**
   `assert Enum.sort_by([result1, result2], &match?({:ok, _}, &1)) |> then(fn [a, b] ->
   {a, b} == {{:error, :invalid_transition}, elem(b, 0)} end)` — expressed plainly:
   exactly one of `{result1, result2}` matches `{:ok, %PromotionReview{}}` and the
   other matches exactly `{:error, :invalid_transition}` — never `{:ok, :ok}`, never
   `{:error, :error}`.
9. Re-`Repo.get` the row (fresh, outside either task): `assert row.status == :approved`,
   `assert row.row_version == 2` (exactly one increment — proves the loser's `UPDATE`
   truly affected zero rows, not that it succeeded and got silently overwritten),
   `assert row.approved_by == user_b`.

This is fully specified — TEST-DESIGNER needs to translate it into ExUnit, not invent
the mechanism.

---

## 5. Open questions (explicit — not silently resolved)

### OQ-1 — `promote_definition/N`'s event-append half has no working target today

Restated from §0/§3.2 step 9: no `DEFINITION_PROMOTED`-equivalent event type is
registered anywhere, and `EventStore.append/2`'s `instance_id` guard has no
non-instance-scoped path today (even the `platform_instance_id()` sentinel doesn't
resolve to a real `instance_projections` row). This design's resolution —
`opts[:event_appender]` with no built-in default — pushes the decision to whoever
actually wires `promote_definition/N` into a real call site (REQ-040 or later), rather
than inventing either (a) a fake-but-passing default that silently no-ops, or (b) a
default that calls `EventStore.append/2` in a way known to always fail. **Also flagged:**
step 9 runs *after* step 7/8's transaction commits — if `event_appender` fails, the
version-pointer move has already durably happened with no recorded event. This design
does not invent a compensating-transaction/saga mechanism for that window; it is a
real gap, stated here rather than hidden. Whether `promote_definition/N` should instead
require the transaction to encompass the event-append (nesting `event_appender` inside
the same `Repo.transaction/1`) is left for REVIEWER/a later requirement once a concrete
`event_appender` implementation exists to reason about.

### OQ-2 — `def_type` has no source in `PromotionPlan.t()`

`PromotionPlan` is scoped exclusively to `process_definitions` diffs (confirmed §0);
its `t()` shape carries no `def_type`-equivalent field. `insert_review/2` (§2.3 step 3)
relies entirely on `PromotionReview`'s own struct default (`"process"`). If a future
plan-computation path promotes some other definition kind through
`insert_review/2`, `def_type` will need to be threaded through explicitly at that
point — not resolved here, restating REQ-035's own OQ-1 (`def_type`'s open-endedness)
rather than closing it.

### OQ-3 — `approve_review/4` has no `permission_checker`-equivalent gate

REQ-036's design doc (§9.1, quoted §0) explicitly names this same gap for "REQ-037's
`PromotionReview`... own permission checks (`platform.admin`-equivalent)" as not a
special case. REQ-037's own requirement text names only the 3 gates in §2.4 — no 4th
"does `actor_id` hold `promotion.approve`" check, and none of the 6 acceptance criteria
test one. This design does not add a 4th gate to `approve_review/4` (would contradict
AC3's literal framing of exactly 3 distinct gate-error atoms), but this is a real,
adjacent authorization gap of the same shape as `PromotionPlan.promotion_opts()`'s
`permission_checker` — flag to REQ-ANALYST/REVIEWER: should a future requirement add
this gate once `Letflow.Identity`'s permission model exists (per REQ-036 §9.1's own
finding that no such data path exists in Letflow today at all)?

### OQ-4 — `reject_review/3`'s `actor_id` is accepted but not persisted

Restated from §2.5: no `rejected_by` column exists on `promotion_reviews`. `actor_id`
is kept in the signature (matches the requirement's own named parameter) but this
design does not repurpose `approved_by` or invent a migration to add a new column —
flagged for REQ-ANALYST: does a future requirement need `rejected_by` for audit
purposes, matching `approved_by`'s existing role?

### OQ-5 — `promote_definition/N`'s two-step activation swap duplicates PD-03 logic REQ-030 will also implement

§3.2 step 8 inlines the same "deprecate existing active, then activate target" swap
`ProcessDefinition`'s own moduledoc describes as REQ-030's `activate/1` responsibility
(quoted §0). REQ-030 is not a dependency of REQ-037 and has not shipped, so
`promote_definition/N` cannot call it. Once REQ-030 ships, should `promote_definition/N`
be refactored to call the real `activate/1` instead of maintaining its own copy of the
same two-statement swap? Flagged, not resolved — this design's own inline version is
correct on its own terms (same guarded-`UPDATE`-with-`WHERE status = ...` shape as
every other transition in this document), just potentially a near-duplicate once
REQ-030 lands.

### OQ-6 — PER_TENANT classification of `promotion_reviews`, restated from REQ-035

`Letflow.Definitions.PromotionReview`'s own moduledoc (§0) already flags this as
unconfirmed against an explicit source. This design does not re-open or re-resolve it
— restated here only so a reader of this document doesn't need to cross-reference to
know it's still open.

---

## 6. Invariants

- **INV-PRM04-1 (invalid-transition catch-all):** every transition function's
  `allowed_source_statuses` is a fixed, closed set (§2.1 table); any call whose
  current-status doesn't match that set — whether caught at the pre-check or only at
  the guarded `UPDATE`'s `WHERE` — returns `{:error, :invalid_transition}`, the same
  atom regardless of which specific illegal edge was attempted.
- **INV-PRM04-2 (row_version is authoritative, not the pre-read):** correctness of
  every transition depends solely on §2.2 step 4's `UPDATE ... WHERE status = $1 AND
  row_version = $2` clause evaluated by Postgres at execution time — never on the
  pre-read from step 1 remaining valid, and never on a surrounding
  `Repo.transaction/1` for the read+update pair (there is none).
- **INV-PRM04-3 (constant-time digest comparison, inherited from
  `PromotionDigest`'s INV-PRM-5):** `approve_review/4` gate (c) and `insert_review/2`
  step 1 are the only two places in this module that touch a `plan_digest`-shaped
  value, and both go through `PromotionDigest.verify_digest/2` — never `==`/`=:=`
  directly.
- **INV-PRM04-4 (no `Repo.transaction/1` around a bare optimistic-lock UPDATE):**
  §2.2's generic shape (and `approve_review/4`/`reject_review/3`/
  `mark_review_applied/2`/`mark_review_failed/2`/`supersede_review/3` all following
  it) never wraps its read+guarded-UPDATE pair in a transaction — only
  `promote_definition/N`'s multi-statement write (§3.2 steps 7–8) uses
  `Repo.transaction/1`, and only for that pair, never spanning step 9's event-append.
- **INV-PRM04-5 (permission_checker/tenant_classifier reuse, not reinvention):**
  `Letflow.Definitions.Promotion.promote_opts()`'s `permission_checker`/
  `tenant_classifier` are byte-identical in shape to `PromotionPlan.promotion_opts()`'s,
  and `default_tenant_classifier/1` for `Promotion` is a direct delegation to
  `PromotionPlan.default_tenant_classifier/1`, not a duplicated copy — grep-checkable:
  `Letflow.Definitions.Promotion` should contain no second `default_tenant_classifier`
  function body, only a reference to `PromotionPlan`'s.
- **INV-PRM04-6 (`tenant_id` is always derived, never accepted — added this rework
  iteration, closes the SECURITY-REVIEWER BLOCKER):** `insert_review/2` (§2.3, the
  only function in this module that writes the `tenant_id` column) derives it from
  `opts[:prefix]` via `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`;
  `args.plan.target_tenant_id` is never read for this purpose. The other five
  transition functions never assign to `tenant_id` at all (§2.8's table), so this
  invariant is `insert_review/2`-specific by construction, not something the other
  five need to separately satisfy. Matches the project-wide rule
  `docs/migration/decisions/0003-ecto-schema-strategy.md`'s 2026-08-17 addendum
  states and `Letflow.EventStore.append/2` already implements
  (`lib/letflow/event_store.ex:9-18`).

---

## 7. DB access patterns / tables touched

| Table | Module(s) | Access | Notes |
|---|---|---|---|
| `promotion_reviews` (REQ-035) | `PromotionReviewStore` | 1 `Repo.get/3` + 1 `Repo.update_all/3` per transition (§2.2); 1 `Repo.insert/2` for `insert_review/2` | No `Repo.transaction/1` around the read+update pair (INV-PRM04-4). `prefix:` on every call — no `@schema_prefix`. |
| `process_definitions` (REQ-027) | `Promotion` | 1 `Repo.get_by/3` (source, plain read) + 1 `Repo.insert/2` + 2 guarded `Repo.update_all/3` (target, inside 1 `Repo.transaction/1`) | Mirrors PD-03's ordering (deprecate before activate). No `FOR UPDATE`/`lock/2` anywhere — matches `PromotionConflict`'s own "plain read" precedent for the source read; the target writes rely on `uq_active_definition`/`uq_definition_version`'s own constraints as the race backstop, same as REQ-030's own (not yet shipped) `activate/1` is described as doing. |
| `event_type_registry` / `events` | none directly | `opts[:event_appender]`'s concern, not this module's | §5 OQ-1 — no direct `EventStore`/`Registry` call from this design. |

Scoping is via `:prefix` only (INV-1), derived from `TenantProvisioning.schema_name_for_tenant/1`
— never a raw string built by hand, never `tenant_id`-column filtering layered on top
(matching `PromotionPlan`/`PromotionConflict`'s own stated reasoning, promotion_plan.md
§6).

---

## 8. Cross-module dependencies

```
PromotionPlan.compute_promotion_plan/5 --> PromotionPlan.t()
        |
        v
PromotionReviewStore.insert_review/2 (Jason.encode!/1 of the FULL plan envelope,
        |                             verified against `digest` via PromotionDigest.verify_digest/2)
        v
  [pending_review row]
        |
        v (approve_review/4: verify_digest/2 against stored plan_digest)
  [approved row]
        |
        v (mark_review_applied/2 -- called by REQ-040's future orchestrator,
        |  AFTER that orchestrator itself calls Promotion.promote_definition/3)
  [applied row]                                    Promotion.promote_definition/3
                                                         |
                                                         v (Jason.decode!/1 of
                                                            insert_review/2's serialised_plan --
                                                            recovers source_tenant_id/base_version)
                                        PromotionConflict.reject_if_conflicts/4
                                        (base_version handoff REQ-036 §7 names)
                                                         |
                                                         v
                                            process_definitions (target) write
                                                         |
                                                         v
                                        opts[:event_appender] (no default -- §5 OQ-1)
```

`PromotionReviewStore` depends on `Letflow.Definitions.PromotionReview` (schema),
`Letflow.Definitions.PromotionDigest` (`verify_digest/2`), **and, as of this rework
iteration, `Letflow.TenantProvisioning` (`tenant_id_for_schema_name/1`, §2.3 step 3) —
superseding this doc's earlier claim that it had no direct dependency on
`TenantProvisioning`.** `insert_review/2` derives `tenant_id` from `opts[:prefix]` via
that function (INV-PRM04-6); the other five transition functions still only consume
`opts[:prefix]` directly (never `tenant_id_for_schema_name/1` — they never write the
`tenant_id` column, §2.8), so the dependency is real but confined to `insert_review/2`.
`Promotion` derives prefixes from tenant UUIDs the *opposite* direction
(`schema_name_for_tenant/1`, tenant_id → prefix, §3.2 step 4) — the two modules use
`TenantProvisioning`'s two reverse/forward functions for their respective, non-
overlapping needs.

`Promotion` depends on `Letflow.Definitions.ProcessDefinition` (schema),
`Letflow.Definitions.PromotionConflict` (`reject_if_conflicts/4`),
`Letflow.Definitions.PromotionPlan` (`default_tenant_classifier/1` delegation only —
INV-PRM04-5), `Letflow.Definitions.PromotionReview` (the `review` argument's struct
shape), and `Letflow.TenantProvisioning` (`schema_name_for_tenant/1`). It does **not**
depend on `PromotionReviewStore` — the two modules are siblings, not caller/callee
(§2.6 restates why `mark_review_applied/2` doesn't call `promote_definition/3`).

---

## 9. Acceptance-criteria mapping

| # | Acceptance criterion | Concrete design element |
|---|---|---|
| 1 | `insert_review/1` (→ `/2`, §1.2) then a second identical `(tenant_id, plan_digest)` call while the first is still `pending_review` → duplicate-review error, not a second row | §2.3 step 5 — `uq_promotion_review_active_digest` constraint-name match mapped explicitly to `{:error, :duplicate_review}`, never a leaked changeset/`Ecto.ConstraintError`. |
| 2 | `approve_review/4` by the actor recorded as `requested_by` → self-approval error, before any row update | §2.4 gate (a) — checked immediately after §2.2 step 1's read, strictly before §2.2 step 4's `UPDATE`; distinct atom `:self_approval_forbidden`. |
| 3 | `approve_review/4` with a non-matching `plan_digest` → digest-mismatch error, distinct from self-approval and invalid-transition | §2.4 gate (c) — `PromotionDigest.verify_digest/2`, distinct atom `:digest_mismatch`; §2.1 table confirms `:invalid_transition` is reserved for status/row_version failures only, never reused for a digest failure. |
| 4 | Two concurrent `approve_review/4` calls on the same `review_id`: exactly one succeeds, the other gets invalid-transition from the zero-rows-affected `WHERE row_version = $expected` | §2.2 step 4 (the mechanism) + §4 (the exact, reusable test recipe — barrier idiom, deterministic assertions, no reliance on wall-clock interleaving for correctness). |
| 5 | A rejected review can transition to `superseded` via `supersede_review/2` (→ `/3`), demonstrated explicitly | §2.1 edge 7, §2.7 — `allowed_source_statuses = [:applied, :failed, :rejected]` includes `:rejected` as a first-class member, not a special case; §2.7's own text states this is the NEW edge and `rejected` is not terminal. |
| 6 | Every one of the 7 permitted edges has an explicit passing test; ≥2 non-edges (e.g. `rejected → approved`, `pending_review → applied`) have explicit rejecting tests | §2.1 table (7 edges → function mapping) + INV-PRM04-1 (the catch-all every non-edge hits) — §2.1's own prose names `rejected → approved` and `pending_review → applied` explicitly as concrete non-edge examples for TEST-DESIGNER to use verbatim. |

Every one of REQ-037's 6 acceptance criteria maps to a concrete, named design element
above — no "TBD" placeholders. Where this design could not resolve an underlying gap
(event-append's missing target, the adjacent permission-check gap, the
not-yet-existing `activate/1` this design must duplicate), it says so explicitly in §5
with a stated resolution (or the deliberate absence of one) and the reasoning behind
that choice, rather than silently picking one and hiding the assumption — matching
REQ-036's own design doc's established convention for this project.
