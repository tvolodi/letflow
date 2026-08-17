# Design: REQ-038 — Promotion rollback (`rollback.zig`, PRM-08)

**Requirement:** REQ-038 (`docs/requirements.yaml`, stage S2, `depends_on: [REQ-030, REQ-037]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ038-20260817`, WF-02 Step 1
**This document produces:** the exact function signature, `@spec`s, the transaction/
locking strategy, the injectable `permission_checker`/`event_appender` shapes, the
`promotion_reviews` supersession mechanism, invariants, cross-module dependencies, and
open questions — **no implementation code**. No function bodies, no `.ex` files.
ELIXIR-DEV writes the real version at Step 2a.

---

## 0. Sources read for this design

**Letflow project docs, read in full:**

- `docs/requirements.yaml` REQ-038 entry (lines 1778–1820) — full description, all 5
  acceptance criteria, `depends_on: [REQ-030, REQ-037]`.
- `docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md`
  Step 1, `docs/agents/shared/HANDOFF_PROTOCOL.md`.
- `docs/guides/backend_developer_guide.md` §3.1 (naming), §3.5 (error shapes), §3.6 (SQL
  parameterization).
- `docs/agents/instructions/security-invariants.md` INV-1 (tenant isolation), INV-7 (no
  raw-SQL interpolation), INV-8 (typed results on external-I/O paths).
- `docs/anti-patterns.md` — no entry directly applicable to this module's own
  construction beyond what's already folded into the citations below.

**Letflow shipped code, read directly (not assumed):**

- `lib/letflow/definitions.ex` — **full file.** Confirmed the exact, already-merged
  conventions this design must fit: `tenant_id` always derived from `opts[:prefix]` via
  `TenantProvisioning.tenant_id_for_schema_name/1` (pure, no I/O); the `common_error()`
  type (`:invalid_schema_name`, `{:transaction_failed, term()}`); `activate/2`'s
  `run_activate_transaction/4` — the `ProcessDefinition |> where(...) |> lock("FOR
  UPDATE") |> Repo.one(prefix: prefix)` row-lock idiom (line 606-611), and
  `activate_draft/2`'s guarded two-`Repo.update_all` swap (line 647-662): deprecate the
  prior active row (`where(status: :active) |> Repo.update_all([set: [status:
  :deprecated, ...]])`), then activate the target row (`where(id: ^id, status: :draft)
  |> Repo.update_all([set: [status: :active, ...]])`) — **this is the ALREADY-SHIPPED
  precedent for "swap the active pointer," directly reused by this design's own swap,
  §5.4.** `deprecate/2`/`archive/2`'s shared `transition/4` → `run_transition/4` →
  `Repo.update_all` inside `Repo.transaction/1`, `{1, [row]}`/`{0, _}` matching idiom.
- `lib/letflow/definitions/process_definition.ex` — **full file.** Confirmed two facts
  load-bearing for this design, neither obvious from `docs/requirements.yaml`'s
  R-Co-derived prose alone:
  1. `status` is `Ecto.Enum, values: [:draft, :active, :deprecated, :archived]` —
     **there is no `:superseded` value in Letflow's shipped schema.** §3 below states
     the mapping this design adopts.
  2. `version` is `field(:version, :string)` — **a free-form string** (e.g. `"3.0.0"`,
     confirmed against `promotion_test.exs`'s own assertion,
     `new_target_row.version == "3.0.0"`), not R-Co's `u32`. `target_version` and
     `rolled_back_from_version` are therefore `String.t()` throughout this design, not
     integers.
  Also confirmed: `name` is the column holding what R-Co calls `process_key` (matches
  `promotion.ex`'s `attrs = %{..., name: process_key, ...}`); `uq_definition_version`
  is `(name, version)` unique; `uq_active_definition` is `(name) WHERE status =
  'active'`; no `@schema_prefix` (every call passes `prefix:` explicitly).
- `lib/letflow/definitions/promotion.ex` — **full file.** The direct precedent for both
  injectable opts this design reuses (§4, §6):
  - `promote_opts()`'s `permission_checker :: (Ecto.UUID.t(), Ecto.UUID.t() ->
    boolean())`, `Keyword.fetch!/2`'d, **no built-in default** — raises `KeyError` if
    omitted (moduledoc: "there is no data path from `actor_id` to a real permission
    today, so silently defaulting to 'allowed' would be worse than crashing").
  - `opts[:event_appender] :: (map(), String.t() -> {:ok, term()} | {:error, term()})`,
    also `Keyword.fetch!/2`'d, **no built-in default**, called **after** the
    version-pointer-move transaction commits, not nested inside it. Moduledoc states
    explicitly why a hardcoded `EventStore.append/2` call would be wrong here: no
    `DEFINITION_PROMOTED`-shaped type is registered in `event_type_registry`, and
    `append/2`'s `instance_id` guard has no non-instance-scoped path — "even the
    `platform_instance_id/0` sentinel doesn't resolve to a real `instance_projections`
    row." **This is the exact same gap REQ-038 faces** — confirmed independently below.
  - Step 8(a)/8(b)'s deprecate-then-activate swap, matching `activate_draft/2`'s shape
    exactly (guarded `Repo.update_all`, no `Repo.transaction`-external locking beyond
    the one transaction both writes share).
- `lib/letflow/definitions/promotion_review_store.ex` — **full file.** Confirmed:
  - `transition/6`'s generic guarded-update mechanism: `Repo.get/3` (unlocked plain
    read) → `pre_gate` → status pre-check against a **hardcoded**
    `allowed_source_statuses` list → `post_gate` → one `Repo.update_all/3` keyed on
    `id AND status AND row_version`, `select: p` for RETURNING; zero rows affected →
    `{:error, :invalid_transition}`.
  - `supersede_review/3`'s current `allowed_source_statuses = [:applied, :failed,
    :rejected]` — **`:approved` is NOT in this list.** The moduledoc states "Exactly 7
    permitted edges, no 8th possible — structural, not just documented" as a
    deliberate, gate-approved invariant (INV-PRM04-1) of this already-merged module.
    §7 below states why REQ-038 needs an 8th edge and how this design proposes to add
    it, flagged explicitly rather than silently bypassed.
  - `row_version` is authoritative, `Repo.transaction/1` never wraps a
    `transition/6` call (INV-PRM04-2/4) — every transition is a single guarded
    statement.
- `lib/letflow/definitions/promotion_review.ex` — **full file.** Confirmed the schema
  fields load-bearing for §6's lookup query: `tenant_id :: Ecto.UUID`, `def_id ::
  :string` — and, critically, **`def_id` stores `plan.process_key` (a string), not a
  `process_definitions.id` UUID** — confirmed directly against `promotion.ex`'s own
  insert-attrs construction (`def_id: plan.process_key` — wait, that specific call site
  is in `promotion_review_store.ex`'s `insert_review/2`, confirmed there:
  `attrs = %{..., def_id: plan.process_key, ...}`). §6 states the consequence of this
  for REQ-038's lookup query. `status` is `Ecto.Enum` over `[:pending_review, :approved,
  :rejected, :applied, :failed, :superseded]` — **`promotion_reviews.status` DOES have
  a `:superseded` value** (unlike `process_definitions.status`) — this is the value
  REQ-038 sets on the matched review row (§7), a completely separate enum from §3's
  `process_definitions.status` discussion; the two must not be conflated.
- `priv/repo/migrations/20260816200001_create_promotion_reviews.exs` +
  `lib/letflow/design/req035-promotion-reviews-schema.md` — confirmed the two indexes:
  `uq_promotion_review_active_digest` on `(tenant_id, plan_digest) WHERE status IN
  ('pending_review', 'approved')`, and — **load-bearing for §6's OQ-2** —
  `idx_promotion_review_rollback_lookup` on `(tenant_id, status) WHERE status IN
  ('applied', 'superseded')`. This index was built by REQ-035 *specifically* "for
  PRM-08 rollback's superseded-lookup queries" (REQ-035's own `docs/requirements.yaml`
  description, quoted verbatim in the migration's own header comment) — but its
  predicate names `'superseded'`, not `'approved'`, while REQ-038's own acceptance
  criterion 4 requires matching `applied` **or** `approved` rows. §6 OQ-2 states this
  mismatch explicitly; it does not block correctness (Postgres still returns correct
  rows for an `status IN ('applied','approved')` filter without this specific partial
  index; it's an index-coverage gap, not a correctness gap) but is flagged rather than
  silently glossed over.
- `lib/letflow/event_store.ex` — confirmed `platform_instance_id/0` (`@platform_instance_id
  "00000000-0000-0000-0000-000000000001"`) exists but — per its own doc citation and
  `promotion_review_state_machine.md`'s independent confirmation (§0 there) — is "never
  inserted into `instance_projections`." Confirms `Letflow.EventStore.append/2`'s M1
  active-instance guard (`lib/letflow/design/req025-event-append.md` §6.2.1) would
  **deterministically fail** with `{:error, :instance_not_started}` for any
  definition-level (non-instance-scoped) event today, including
  `DEFINITION_VERSION_ROLLED_BACK` — there is no registered `event_type_registry` entry
  for it either. This independently reconfirms `promotion.ex`'s own stated gap (§0
  above) applies identically to REQ-038; §4.2 below adopts the same resolution.
- `lib/letflow/design/req031-service-scope-validator.md` and
  `lib/letflow/design/promotion_review_state_machine.md` — read as this codebase's
  nearest structural precedents for design-doc depth (injectable-hook shape,
  algorithm-as-numbered-pseudocode, explicit open-questions section).
- `test/letflow/definitions/promotion_test.exs` — confirmed the exact test-double shape
  future TEST-DESIGNER work will need: `recording_event_appender/1` (`fn event_attrs,
  prefix -> send(test_pid, {:event_appended, event_attrs, prefix}); {:ok, %{event_id:
  Ecto.UUID.generate()}}} end`) and `assert_raise KeyError` when an opt is omitted.

**R-Co source of truth (`C:\Users\tvolo\dev\ai-dala\R-Co\`), read directly:**

- `src/definition/rollback.zig` (full file, 365 lines) — `RollbackResult`,
  `RollbackError`, `rollbackDefinitionVersion/6`'s full body: permission check, `SELECT
  ... FOR UPDATE` row lock, current-ACTIVE lookup with its "any_row" disambiguation
  (both branches return `ProcessKeyNotFound` — §5.2 below preserves this), the
  `AlreadyActive` short-circuit **before** the target-row lookup, the target-row lookup
  (`status IN ('ACTIVE','SUPERSEDED')`) producing `VersionNeverActive` when absent, the
  two-statement swap, the event-insert SQL (with an `idempotency_key` of the shape
  `"rollback:{tenant_id}:{process_key}:{target_version}"` — §8 OQ-4 below), and the
  `promotion_reviews` supersede `UPDATE ... WHERE def_id = $2 AND status IN
  ('applied','approved')` with no `LIMIT`.
- `src/design/prm-batch1-promotion-assertion-rerun.md` §"PRM-08 design — promotion
  rollback" (lines 417-511) — the design doc REQ-038's own `docs/requirements.yaml`
  description cites for the "why `status IN ('ACTIVE','SUPERSEDED')` proves prior
  activation" reasoning (quoted verbatim there: "`process_definitions.status` follows
  the lifecycle `DRAFT → ACTIVE → SUPERSEDED`. A row in `SUPERSEDED` was necessarily
  `ACTIVE` at some prior point. This check requires no additional history table and no
  event log scan."), the HTTP error-code table (out of scope for this S2 requirement,
  no HTTP layer exists yet — noted, not built), and the state-transition diagrams
  (`process_definitions.status`: `DRAFT →[first activation]→ ACTIVE →[new version
  promoted]→ SUPERSEDED →[rollback targets this row]→ ACTIVE`).

---

## 1. Scope boundary

**In scope:** one new public function, `Letflow.Definitions.rollback_definition_version/4`,
added directly to the existing `lib/letflow/definitions.ex` context module — **not** a
new submodule. This placement is not a free choice: REQ-038's own `docs/requirements.yaml`
description names the target literally as `Letflow.Definitions.rollback_definition_version/4`
(the same top-level module `activate/2`/`create/2`/`deprecate/2`/`archive/2` already live
in), unlike `Promotion`/`PromotionReviewStore`, which are separate submodules with their
own top-level names (`Letflow.Definitions.Promotion`, `Letflow.Definitions.PromotionReviewStore`).
Also in scope: one small, explicitly-flagged edit to
`lib/letflow/definitions/promotion_review_store.ex` (§7) — widening
`supersede_review/3`'s `allowed_source_statuses`.

**Explicitly NOT in scope, not silently dropped:**

| Not built here | Owned by |
|---|---|
| Any HTTP/Plug route (`POST /api/v1/definitions/{process_key}/rollback`) | S4 (no HTTP layer exists yet for any S2 requirement — matches every prior S2 design's identical framing) |
| A real, working `event_appender` that actually calls `Letflow.EventStore.append/2` | Whichever future requirement wires a definition-level (non-instance-scoped) event stream into `EventStore` — same gap `promotion.ex`'s OQ-1 already names, not resolved here either (§4.2) |
| Widening `process_definitions.status`'s `Ecto.Enum` to add a literal `:superseded` value, or any migration touching that column | Not requested by REQ-038's acceptance criteria; §3 states the mapping this design uses instead onto the already-shipped 4-value enum |
| REQ-020's role registry → real `platform.admin` permission resolution | Deferred, per REQ-038's own text — §4.1 states the injectable shape only |
| Any change to `Letflow.Definitions.PromotionReview`'s schema | None needed — `status`, `superseded_by` (already `Ecto.UUID`, nullable) already fit §7's needs |

**DB schema:** no new migration. This design writes only to already-existing columns on
already-shipped tables (`process_definitions.status`/`updated_at`,
`promotion_reviews.status`/`superseded_by`/`row_version`).

---

## 2. Function signature

```
@type rollback_opts :: [
  prefix: String.t(),
  permission_checker: (actor_id :: Ecto.UUID.t(), tenant_id :: Ecto.UUID.t() -> boolean()),
  event_appender: (event_attrs :: map(), prefix :: String.t() ->
                     {:ok, %{event_id: Ecto.UUID.t()}} | {:error, term()})
]

@type rollback_result :: %{
  definition_id: Ecto.UUID.t(),          # the now-active (target) row's id
  version: String.t(),                    # = target_version, echoed back
  rolled_back_from_version: String.t(),   # the version that WAS active before this call
  superseded_review_id: Ecto.UUID.t() | nil,
  event_id: Ecto.UUID.t()
}

@type rollback_error ::
        {:error, :forbidden}
        | {:error, :process_key_not_found}
        | {:error, :version_never_active}
        | {:error, :already_active}
        | {:error, term()}              # event_appender's own {:error, reason} propagated
                                          # unchanged (§4.2) -- this function does not
                                          # constrain the injected function's error shape,
                                          # matching promote_definition/3's identical stance
        | Letflow.Definitions.common_error()   # {:invalid_schema_name} |
                                                # {:transaction_failed, term()}

@spec rollback_definition_version(
        process_key :: String.t(),
        target_version :: String.t(),
        actor_id :: Ecto.UUID.t(),
        opts :: rollback_opts()
      ) :: {:ok, rollback_result()} | rollback_error()
```

**Arity note (the requirement's own literal `/4`):** `process_key`, `target_version`,
`actor_id`, `opts` — `tenant_id` is **not** a fifth parameter; it is derived from
`opts[:prefix]` via `TenantProvisioning.tenant_id_for_schema_name/1`, exactly matching
`activate/2`/`create/2`'s existing convention in this same module (§0). `opts` is
`Keyword.fetch!/2`'d for both `:permission_checker` and `:event_appender` — **no
built-in default for either** (§4.1, §4.2) — and `Keyword.get(opts, :prefix)` for
`:prefix` (matching `activate/2`'s own `Keyword.get/2` usage, whose absence surfaces
downstream as `{:error, :invalid_schema_name}` from `tenant_id_for_schema_name/1`
rather than a separate top-level check).

---

## 3. The `process_definitions.status` vocabulary mismatch — R-Co's `SUPERSEDED` maps to Letflow's `:deprecated`

**This is the single most load-bearing translation decision in this design, stated
explicitly because it is not obvious from `docs/requirements.yaml`'s R-Co-derived
prose.** R-Co's rollback design (§0) reasons over a `DRAFT → ACTIVE → SUPERSEDED`
lifecycle with `SUPERSEDED` as its own status value. **Letflow's already-shipped
`ProcessDefinition.status` enum has exactly four values — `:draft`, `:active`,
`:deprecated`, `:archived` — no `:superseded` value exists** (§0, confirmed directly
against `process_definition.ex`). This is not an oversight this design introduces; it
was REQ-027's own settled schema decision, and REQ-037's already-merged
`promote_definition/3` already committed to the same resolution this design adopts:
step 8(a) of `promotion.ex` "deprecates whatever row is currently active" — i.e.
**Letflow already uses `:deprecated` for exactly the "automatically superseded by a
newer version being activated" case**, not only for `Letflow.Definitions.deprecate/2`'s
deliberate admin-initiated transition.

**Why reusing `:deprecated` is sound, not just convenient:** `process_definition.ex`'s
own moduledoc states PD-04's authoritative transition table: only `draft → active`,
`active → deprecated`, and `deprecated → archived` are permitted. The **only** path
into `:deprecated` is from `:active`. This means R-Co's own justification for
`SUPERSEDED` — "a row in `SUPERSEDED` was necessarily `ACTIVE` at some prior point... no
additional history table needed" (§0's citation) — carries over to `:deprecated`
**exactly**, with no loss of soundness: any row Letflow's schema can put into
`:deprecated` was, structurally, `:active` immediately before.

**This design's adopted mapping, used everywhere below:**

| R-Co vocabulary | Letflow `process_definitions.status` value |
|---|---|
| `ACTIVE` | `:active` |
| `SUPERSEDED` | `:deprecated` |
| (rollback swap target) `current ACTIVE → SUPERSEDED` | current active row → `:deprecated` |
| (rollback swap target) `target row → ACTIVE` | target row → `:active` |
| "was ever active" eligible set, `{ACTIVE, SUPERSEDED}` | `{:active, :deprecated}` |

**`:archived` is deliberately excluded from the eligible-target set**, even though
`:archived` is *also* only reachable via `:deprecated` (hence transitively via
`:active`) under PD-04's transition table — so it too "proves prior activation" in the
same structural sense. R-Co's own rollback scopes to exactly two status values
(`{ACTIVE, SUPERSEDED}`), not "any status reachable only via prior activation" — this
design preserves that same two-value exclusivity rather than broadening it, because (a)
nothing in REQ-038's acceptance criteria asks for archived-version resurrection, and (b)
`archive/2`'s own stamping of `archived_at` signals a deliberate, likely-intentional
retirement decision that a version-pointer rollback should not silently undo. Flagged
as this design's own reasoned choice (§8 OQ-1), not a fact read off any source document
this design has access to.

---

## 4. The two injectable opts — reusing `promotion.ex`'s exact precedent

### 4.1 `opts[:permission_checker]` — identical shape to `promotion.ex`, no new pattern

```
@type permission_checker_fun :: (actor_id :: Ecto.UUID.t(), tenant_id :: Ecto.UUID.t() -> boolean())
```

`Keyword.fetch!(opts, :permission_checker)` — **no built-in default**, raises
`KeyError` if omitted. This is the exact same shape and the exact same no-default
stance `promotion.ex`'s `promote_opts()` already established (§0), reused verbatim
rather than reinvented, per this run's own task briefing ("Follow this exact shape for
REQ-038's guard, not invent a new permission model"). There is still no data path from
`actor_id` to a real `platform.admin`-equivalent permission in Letflow today —
REQ-020's role registry exists (`lib/letflow/design/req020-role-registry.md`) but this
design does not wire it in, matching REQ-036/037's identical, already-accepted
disclosure. **Flagged explicitly per the task briefing's own instruction, not silently
resolved (§8 OQ-2):** unlike `promote_definition/3`'s `permission_checker`, which
checks against `source_tenant_id` (a value read out of the review's own serialised
plan), REQ-038's `permission_checker` is checked against the **single tenant this call
operates in** (derived from `opts[:prefix]`, the same `tenant_id` every other function
in this module already derives) — there is no second, cross-tenant `tenant_id` in this
call's shape the way promotion has a source/target pair. This is a simpler case than
`promote_definition/3`'s, not a divergent one; stated here so CODE-DESIGN-VALIDATOR can
confirm the precedent was actually followed rather than superficially matched.

**Call site and ordering (AC5 — "rejected before any row is read or locked"):**
`permission_checker.(actor_id, tenant_id)` is called immediately after `tenant_id` is
derived from `opts[:prefix]` (a pure, no-I/O string transform — not a "row read") and
**before** `Repo.transaction/1` is ever opened, before any `Repo.one`/`Repo.all`/
`lock("FOR UPDATE")` call. A `false` return is `{:error, :forbidden}`, returned
immediately — no transaction opened, no row touched anywhere. Mirrors `promotion.ex`'s
own `cond do not permission_checker.(...) -> {:error, :forbidden}; ... end`, checked
before any `Repo` call in that module too.

### 4.2 `opts[:event_appender]` — same no-default stance, same "call after commit" placement, same stated gap

```
@type event_appender_fun ::
        (event_attrs :: map(), prefix :: String.t() ->
           {:ok, %{event_id: Ecto.UUID.t()}} | {:error, term()})
```

`Keyword.fetch!(opts, :event_appender)` — **no built-in default**, raises `KeyError` if
omitted. **This design does not hardcode a call to `Letflow.EventStore.append/2`
here, for the identical, independently-reconfirmed reason `promotion.ex`'s moduledoc
already states (§0):** `DEFINITION_VERSION_ROLLED_BACK` is not a registered
`event_type_registry` entry in any tenant, and `append/2`'s M1 active-instance guard
(`req025-event-append.md` §6.2.1) requires an existing, non-terminal
`instance_projections` row for whatever `instance_id` is supplied — there is no
notion of a definition-level (non-instance-scoped) event stream in the currently-shipped
`EventStore`, and even `platform_instance_id/0` does not resolve to a real row (§0,
independently re-confirmed against `event_store.ex` directly, not merely cited from
`promotion.ex`'s own claim). A hardcoded `EventStore.append/2` call here would
**deterministically fail** for every caller today, which would make AC1/AC4's
"successful rollback" scenarios permanently unsatisfiable — exactly the outcome
`opts[:event_appender]`'s injectability exists to avoid.

**Call site — after the pointer-swap transaction commits, not nested inside it (§5.5,
deliberately diverging from R-Co's literal single-transaction framing — see §8 OQ-3 for
the full discussion of this divergence):**

```
opts[:event_appender].(
  %{
    event_type: "DEFINITION_VERSION_ROLLED_BACK",
    process_key: process_key,
    from_version: rolled_back_from_version,   # the version that WAS active
    to_version: target_version,
    actor_id: actor_id
  },
  prefix
)
```

matching the payload REQ-038's own `docs/requirements.yaml` description names
verbatim: "process_key, from_version, to_version, actor_id." A `{:error, reason}`
return propagates unchanged as this function's own return — the pointer swap has
**already durably committed** by this point (same partial-failure window
`promotion.ex`'s OQ-1 already discloses for its own event-append step, not
re-invented here, not hidden). A `{:ok, %{event_id: event_id}}` return's `event_id` is
captured and threaded into §7's `promotion_reviews` supersession step and into this
function's own `rollback_result()`.

---

## 5. Algorithm — `rollback_definition_version/4`, in order

**Step 0 (pure, no I/O).** `TenantProvisioning.tenant_id_for_schema_name(opts[:prefix])`
→ `{:error, :invalid_schema_name}` short-circuits immediately (matches
`Letflow.Definitions.common_error()`, §0). On success, bind `tenant_id`.

**Step 1 (AC5 — before any row is read or locked).**
`opts[:permission_checker].(actor_id, tenant_id)` → `false` →
`{:error, :forbidden}`, returned immediately. `true` → continue.

**Step 2 — open one `Repo.transaction/1` (the pointer-swap transaction, "TX1").**
Inside it:

```
2a. rows =
      ProcessDefinition
      |> where([d], d.tenant_id == ^tenant_id and d.name == ^process_key)
      |> lock("FOR UPDATE")
      |> Repo.all(prefix: prefix)
```

Locks **every** version row for this `(tenant_id, process_key)` in one statement,
matching R-Co's own `SELECT ... FOR UPDATE` with no version filter (§0) and this
module's own `run_activate_transaction/4` precedent generalized from one row to the
whole set (§0).

```
2b. current_active = Enum.find(rows, &(&1.status == :active))

    current_active == nil ->
      Repo.rollback(:process_key_not_found)
      # Preserves R-Co's own disambiguation exactly (§0's citation of rollback.zig
      # lines 130-153): whether `rows == []` (process_key genuinely never existed in
      # this tenant) or `rows` is non-empty but nothing in it is currently `:active`
      # (every version has been deprecated/archived, nothing "live" to roll back
      # FROM), both cases return the SAME :process_key_not_found error. This is a
      # faithful, deliberate port of R-Co's own unification, not a Letflow
      # simplification -- R-Co's rationale (rollback.zig's own comment): "No current
      # ACTIVE row -- process_key may simply never have been promoted."

2c. current_active.version == target_version ->
      Repo.rollback(:already_active)
      # Checked BEFORE the target-row lookup below, matching R-Co's literal code
      # order (rollback.zig lines 155-167) exactly. This ordering is a deliberate
      # micro-optimization (skips an unnecessary lookup) with NO observable
      # difference from checking version-never-active first: if target_version ==
      # current_active.version, the "target row" IS current_active itself, whose
      # status (:active) always trivially satisfies the eligible-status set (§3) --
      # so the two orderings can never disagree on which error fires for this
      # specific case. No rows changed by this rollback (Repo.rollback discards
      # every write attempted so far in TX1 -- none were attempted yet at this
      # point, since 2a is a read).

2d. target_row = Enum.find(rows, &(&1.version == target_version and
                                    &1.status in [:active, :deprecated]))
                 # :active | :deprecated per §3's mapping -- :archived excluded.

    target_row == nil ->
      Repo.rollback(:version_never_active)

2e. now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ProcessDefinition
    |> where([d], d.id == ^current_active.id)
    |> select([d], d)
    |> Repo.update_all([set: [status: :deprecated, updated_at: now]], prefix: prefix)
    # {1, [_]} always -- current_active.id was just locked at 2a, cannot have
    # changed under this transaction's own lock.

    {1, [activated_row]} =
      ProcessDefinition
      |> where([d], d.id == ^target_row.id)
      |> select([d], d)
      |> Repo.update_all([set: [status: :active, updated_at: now]], prefix: prefix)
    # Same "guaranteed exactly 1 row" reasoning -- target_row.id was locked at 2a too.

    {:ok, %{activated_row: activated_row, rolled_back_from_version: current_active.version}}
```

Mirrors `activate_draft/2`'s exact two-`Repo.update_all` swap shape (§0), generalized
from "the row matching `name` with `status == :active`" to "the specific already-locked
`current_active.id`" (REQ-038's swap targets a *specific* row identified by the earlier
lock, not a fresh `WHERE name = ... AND status = :active` re-match — avoids a
theoretically-possible, if practically-impossible-under-`FOR UPDATE`, TOCTOU gap between
2b's in-memory identification and the write).

**Step 3 — outside TX1, after it commits.** Call `opts[:event_appender]` per §4.2. A
`{:error, reason}` here returns `{:error, reason}` as this function's own result — TX1's
swap has already committed (§4.2, §8 OQ-3). On `{:ok, %{event_id: event_id}}`, continue.

**Step 4 — outside TX1, after the event-append succeeds.** Supersede any matching
`promotion_reviews` row(s) per §7, using `event_id` from Step 3. This step's own outcome
(§7) never turns an otherwise-successful rollback into an error — "zero matching rows
is acceptable, not an error" (REQ-038's own text, AC4).

**Step 5 — assemble the result:**

```
{:ok, %{
  definition_id: activated_row.id,
  version: target_version,
  rolled_back_from_version: rolled_back_from_version,   # from Step 2
  superseded_review_id: superseded_review_id,           # from Step 4, nil-able
  event_id: event_id                                    # from Step 3
}}
```

**Exception safety.** The whole of Step 2 (`Repo.transaction/1`) is wrapped in a
`try/rescue`, mirroring `activate/2`'s own `try ... rescue exception -> {:error,
{:transaction_failed, exception}}` (§0) — matches `Letflow.Definitions.common_error()`
exactly, no new error shape invented for this case.

---

## 6. `promotion_reviews` lookup — the `def_id = process_key` consequence

**Confirmed fact, not assumed (§0):** `promotion_reviews.def_id` stores
`plan.process_key` — a **string equal to the process key**, not a
`process_definitions.id` UUID. R-Co's own rollback SQL filters `WHERE def_id = $2`
bound to `current_active.id` (a definition UUID, under R-Co's schema where `def_id`
really does mean "definition id"). **Letflow's schema does not support that same
filter** — there is no column on `promotion_reviews` correlating a review to one
*specific* `process_definitions` row/version; the only available correlation is to the
process_key as a whole.

**This design's lookup, given that constraint:**

```
matching_reviews =
  PromotionReview
  |> where([r], r.tenant_id == ^tenant_id and r.def_id == ^process_key and
                r.status in [:applied, :approved])
  |> order_by([r], desc: r.inserted_at)
  |> Repo.all(prefix: prefix)
```

**Practical expectation vs. structural guarantee, stated honestly:** in the common,
expected flow, at most one row matches at any given time (a process_key normally has
at most one "live" applied/approved review). **No DB constraint enforces this** —
`uq_promotion_review_active_digest` scopes its uniqueness to `(tenant_id, plan_digest)`,
not `(tenant_id, def_id)` — so two different promotion plans for the same process_key
(e.g. an approved-but-never-applied review left over from an earlier promotion attempt,
plus the applied review for the version actually rolled back from) could in principle
both match. §8 OQ-5 states this explicitly as an open question this design does not
consider fully closed, rather than asserting a guarantee this codebase's schema does
not actually provide.

**Resolution this design adopts (stated, not left to ELIXIR-DEV to invent):** call §7's
supersede mechanism once **per** matched row, in the `order_by desc: inserted_at` order
above — every matched row ends up `:superseded`, honoring AC4's literal "any
applied/approved... row" wording for however many rows actually match. This function's
own `superseded_review_id` field (§2, singular per REQ-038's own named return shape)
is set to the **first** row processed (i.e. the most-recently-inserted match) if the
list is non-empty, `nil` otherwise. If a specific matched row's `supersede_review/3`
call itself fails with `{:error, :invalid_transition}` (a genuine optimistic-lock race
against some other concurrent caller touching that same review row — not the "zero
matching rows" case AC4 already excuses), this design treats that single row's failure
as **non-fatal to the overall rollback** — TX1's pointer swap and Step 3's event-append
have already durably committed by this point, so aborting the whole
`rollback_definition_version/4` call over a review-bookkeeping race would not undo
either of those; the race is silently absorbed (that specific row is left as-is,
still `:applied`/`:approved`, not retried). Flagged for REVIEWER (§8 OQ-6) since no
acceptance criterion states this specific sub-case's desired behavior.

---

## 7. Superseding a `promotion_reviews` row — the `:approved` edge

`PromotionReviewStore.supersede_review/3` (§0) already implements almost exactly what
this step needs: `Repo.get` → guarded `Repo.update_all` keyed on `id AND status AND
row_version`, setting `status: :superseded, superseded_by: superseded_by_event_id`. The
**one gap**: its `allowed_source_statuses` is currently `[:applied, :failed,
:rejected]` — **`:approved` is not a legal source status for `supersede_review/3` as
shipped.**

**Why REQ-038 genuinely needs the `:approved` edge, not just `:applied` (this is not
this design silently copying R-Co's SQL without checking whether it still applies):**
`promote_definition/3` and `PromotionReviewStore.mark_review_applied/2` are two
*separate* calls, invoked by "some future orchestrator" (`promotion.ex`'s own moduledoc,
§0) — `promote_definition/3` performs the actual version-pointer-activation, and only
*afterwards*, as a distinct call, does that orchestrator flip the review's own
bookkeeping status to `:applied`. This creates a real window where a
`process_definitions` row is already `:active` (because `promote_definition/3`'s own
transaction already committed) while its originating `promotion_reviews` row is still
`:approved` (because the orchestrator's second call, `mark_review_applied/2`, hasn't
run yet — or failed independently). A rollback landing in that window needs to
supersede an `:approved` row, not an `:applied` one. R-Co's own SQL (`status IN
('applied','approved')`, §0) reflects the identical real-world race, ported faithfully.

**This design's proposed resolution (stated concretely, not left as a TBD, per Step 1's
"every acceptance criterion maps to a concrete design element" requirement) — and
flagged for REVIEWER sign-off, per `core-directives.md`'s "don't silently re-decide
what a decision record already settled":**

Widen `PromotionReviewStore.supersede_review/3`'s `allowed_source_statuses` from
`[:applied, :failed, :rejected]` to `[:applied, :approved, :failed, :rejected]`. This
is a **small, explicit, cross-module edit ELIXIR-DEV makes to an already-merged,
gate-approved file** (`lib/letflow/definitions/promotion_review_store.ex`) as part of
REQ-038's Step 2a — not invented silently, and not routed around via a parallel
ad-hoc `Repo.update_all` inside `rollback_definition_version/4` that would bypass
`PromotionReviewStore`'s own stated "single choke point" property (INV-PRM04-1). The
edit's own scope is deliberately minimal:

1. `supersede_review/3`'s call to `transition/6` passes `[:applied, :approved, :failed,
   :rejected]` instead of `[:applied, :failed, :rejected]` as its
   `allowed_source_statuses` argument. No other line in that function changes.
2. `PromotionReviewStore`'s moduledoc's "Exactly 7 permitted edges" section (§0) must be
   updated to state 8 edges, adding the new `approved --[supersede_review/3]--> superseded`
   arrow to its own ASCII diagram — this is a real, deliberate change to a previously-true
   claim about that module, not a drive-by edit; ELIXIR-DEV must not leave the old "7
   permitted edges" text in place next to code that now allows an 8th.
3. No change to `supersede_review/3`'s `@spec`, its `superseded_by_event_id` parameter,
   or its own moduledoc discussion of what `superseded_by` references (`promotion_review_store.ex`'s
   OQ-4-equivalent discussion, §0) — the widening is purely to the status guard.

**Call site in `rollback_definition_version/4`** (§6's loop, once per matched review):

```
PromotionReviewStore.supersede_review(review.id, event_id, prefix: prefix)
```

A `{:ok, updated_review}` result contributes `updated_review.id` as (candidate)
`superseded_review_id`; an `{:error, :invalid_transition}` result is absorbed per §6's
stated resolution; `{:error, :review_not_found}` should not occur in practice (the row
was just read at §6, in the same overall call) but is not treated as fatal either —
same absorption.

---

## 8. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-RB-1 | `opts[:permission_checker]` is checked before any `Repo` call of any kind — no row read, no row locked, no transaction opened, on a `false` result. | §4.1, §5 Step 1 |
| INV-RB-2 | Neither `opts[:permission_checker]` nor `opts[:event_appender]` has a built-in default — both `Keyword.fetch!/2`'d, both raise `KeyError` if omitted. | §4.1, §4.2 |
| INV-RB-3 | `process_definitions.status` transitions only via guarded `Repo.update_all` keyed on an already-`FOR UPDATE`-locked row's `id` — never a changeset-mediated read-then-write, matching `ProcessDefinition`'s own INV-DEF-8. | §5 Step 2e |
| INV-RB-4 | `:archived` is never a legal rollback source **or** target status — only `:active`/`:deprecated` rows participate in the swap. | §3, §5 Step 2d |
| INV-RB-5 | A `:already_active` or `:version_never_active` or `:process_key_not_found` result writes zero rows — every guard in §5 Step 2 fires via `Repo.rollback/1` before either `Repo.update_all` write in Step 2e runs. | §5 Step 2b-2d |
| INV-RB-6 | Exactly one `DEFINITION_VERSION_ROLLED_BACK`-shaped call to `opts[:event_appender]` per successful rollback — never zero, never more than one. | §5 Step 3 |
| INV-RB-7 | The pointer-swap transaction (TX1) commits **before** `opts[:event_appender]` is ever called — this function does not assume anything about the injected function's own transactionality, matching `promote_definition/3`'s identical stance. | §4.2, §5 Step 2/3, §8 OQ-3 |
| INV-RB-8 | Every `promotion_reviews` write goes through `PromotionReviewStore.supersede_review/3` — no ad-hoc `Repo.update_all` against `promotion_reviews` inside `rollback_definition_version/4` itself. | §7 |
| INV-RB-9 | `tenant_id` is always derived from `opts[:prefix]`, never accepted as a separate argument or attrs key — matches every other function in this module (§0). | §2, §5 Step 0 |

---

## 9. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Definitions.ProcessDefinition` (REQ-027) | this design → REQ-027 | Reads/locks/writes `process_definitions` rows via the schema module's fields only — no new changeset, no schema change. |
| `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` (REQ-025/030 precedent) | this design → shared function | Reused unchanged, same as every other function in `definitions.ex`. |
| `Letflow.Definitions.PromotionReview` / `PromotionReviewStore` (REQ-035/037) | this design → REQ-035/037 | Reads via a plain `Repo.all` (new query, §6); writes exclusively via `supersede_review/3` (§7), which itself requires a small, explicitly-flagged widening of that already-merged module. |
| `Letflow.Definitions.Promotion` (REQ-037) | this design ← precedent only | No runtime call — `promote_definition/3` is cited as the structural precedent for both injectable opts (§4) and the deprecate-then-activate swap shape (§5), not invoked by this function. |
| A future `EventStore`-backed `event_appender` implementation | future → this design | Not built here (§4.2) — same deferred-wiring gap `promotion.ex`'s OQ-1 already names, independently reconfirmed for this requirement. |
| S4 (HTTP layer) | future S4 → this design | Would eventually expose `POST /api/v1/definitions/{process_key}/rollback`, mapping `rollback_error()`'s tags to HTTP codes per R-Co's own table (§0) — `Forbidden→403`, `VersionNeverActive→422`, `AlreadyActive→422`, `ProcessKeyNotFound→404`. Not built here. |

---

## 10. Open questions — explicit, not silently resolved

**OQ-1 (MINOR):** §3's exclusion of `:archived` from the eligible rollback-target set is
this design's own reasoned choice (mirrors R-Co's own two-value `{ACTIVE, SUPERSEDED}`
allowlist rather than "any status reachable only via prior activation," which would
also admit `:archived`). Not contradicted by anything in REQ-038's text, but not
confirmed by it either — flagged for REVIEWER.

**OQ-2 (MINOR, per this run's own task briefing's explicit instruction to flag rather
than resolve):** §4.1's `permission_checker` is checked against the single `tenant_id`
this call operates in, unlike `promote_definition/3`'s cross-tenant
(`source_tenant_id`/`target_tenant_id`) check. This is stated as a simplification
consistent with REQ-038's own single-tenant framing (there is no cross-tenant promotion
concept in a rollback), not a deviation CODE-DESIGN-VALIDATOR/REVIEWER should read as
an unexamined gap.

**OQ-3 (MAJOR — a genuine tension between R-Co's literal design and this codebase's
established precedent, methodologically the most significant open question in this
document):** `src/design/prm-batch1-...md`'s own PRM-08 section (§0) states the
version-pointer move, the event append, **and** the `promotion_reviews` supersede all
happen "in a single serialisable transaction." This design does **not** build it that
way — §5 Steps 3/4 run **after** TX1 (the pointer-swap transaction) commits, mirroring
`promote_definition/3`'s own already-established, already-REVIEWER-approved precedent
(§0, §4.2) of never nesting an arbitrary injected closure's own I/O inside a
`Repo.transaction/1` this function itself owns, since the closure's transactional
behavior is opaque to this function by construction. This divergence is *forced*, not
optional: `opts[:event_appender]` is an arbitrary injected function (§4.2) — nesting
its call inside TX1 would require this function to trust that closure to compose
correctly with an already-open Ecto transaction, an assumption `promotion.ex`'s own
design explicitly declined to make. **Consequence, stated plainly:** if
`opts[:event_appender]` fails, the pointer swap has already durably committed with no
recorded event — the identical partial-failure window `promotion.ex`'s OQ-1 already
discloses for `promote_definition/3`, not a new gap this design introduces. REVIEWER
should treat this as the same accepted tradeoff already ratified for
`promote_definition/3`, or reopen both together if the tradeoff is reconsidered.

**OQ-4 (MINOR):** R-Co's own event-insert SQL (`rollback.zig` lines 240-244, §0)
computes an idempotency key of the shape `"rollback:{tenant_id}:{process_key}:{target_version}"`.
REQ-038's own `docs/requirements.yaml` payload list (`process_key, from_version,
to_version, actor_id`) names no idempotency-key field, and this design's
`event_appender_fun` shape (§4.2) carries none either — whatever future real
`event_appender` implementation exists will need to derive its own idempotency key
(if `EventStore.append/2` is what it ultimately calls, `append/2` requires one, per
`req025-event-append.md` §5.2). Not built here; flagged so a future implementer does
not have to rediscover R-Co's own key-shape convention from scratch.

**OQ-5 (MAJOR — a genuine schema-shape gap, not a hypothetical):** §6 states plainly
that `promotion_reviews.def_id == process_key` gives this design no way to scope a
lookup to "the review that specifically produced the now-former-active *version*" —
only to "the process_key as a whole." No DB constraint prevents more than one
`applied`/`approved` row from matching at once for a given `(tenant_id, process_key)`.
§6's resolution (process every match, name only the most-recently-inserted one as
`superseded_review_id`) is this design's own choice, not a fact derived from any
source. If REVIEWER or a later requirement decides `promotion_reviews` needs a real
`process_definitions.id`-scoped column to close this gap properly, that is a schema
change outside REQ-038's own scope (§1) — not attempted here.

**OQ-6 (MINOR):** §6/§7's stance that a per-row `supersede_review/3` race
(`{:error, :invalid_transition}`) is absorbed rather than propagated as this whole
function's own error is this design's own choice, made because TX1 and the
event-append have already durably committed by that point (so failing the whole call
would not undo either). No acceptance criterion states the desired behavior for this
specific sub-case explicitly; flagged for REVIEWER.

---

## 11. Acceptance-criteria traceability

| REQ-038 acceptance criterion | Concrete design element |
|---|---|
| 1. "rolling back to a version with status SUPERSEDED (previously ACTIVE) succeeds and flips the pointer" | §3 (the `:deprecated` mapping) + §5 Step 2d/2e (the swap) + §5 Step 5 (result assembly) |
| 2. "rolling back to a version never ACTIVE/SUPERSEDED... returns version-never-active, no rows changed" | §5 Step 2d (`target_row == nil → Repo.rollback(:version_never_active)`) + INV-RB-5 |
| 3. "rolling back to the currently-ACTIVE version returns already-active, no rows changed, no event appended" | §5 Step 2c (checked before any write, before the event-append step is ever reached) + INV-RB-5 |
| 4. "a successful rollback appends exactly one DEFINITION_VERSION_ROLLED_BACK event and updates any applied/approved promotion_reviews row... to superseded" | §4.2 (event payload + call site) + INV-RB-6 + §6 (the lookup, given `def_id == process_key`) + §7 (the `supersede_review/3` widening this design proposes) |
| 5. "a caller lacking the platform.admin-equivalent permission is rejected before any row is read or locked" | §4.1 (call site ordering) + §5 Step 1 + INV-RB-1 |
