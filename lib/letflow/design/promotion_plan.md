# Design: REQ-036 — Promotion plan computation, conflict preflight, and plan digest

**Requirement:** REQ-036 (`docs/requirements.yaml` lines 1639–1714, stage S2,
`depends_on: [REQ-027, REQ-028]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ036-20260817`, WF-02 Step 1
**This document produces:** module/function signatures, struct/type shapes, the full
error taxonomy, the DB access pattern, the canonicalization algorithm, and invariants —
**no implementation code**. No function bodies, no `.ex` files. Pseudocode/spec blocks
below describe type shapes and algorithm steps only, matching the convention already
validator-approved in `lib/letflow/design/req033-snapshot-store.md` §0 and
`req024-event-type-registry.md` §4.4 — ELIXIR-DEV writes the real version.

Domain logic only, per the task briefing: no HTTP/Plug layer here (S4 scope).

---

## 0. Sources read for this design

**Letflow project docs, read in full:**

- `docs/requirements.yaml` — REQ-036's full entry (1639–1714), plus REQ-020 (721–752,
  role registry), REQ-027 (1193–1252, `process_definitions` schema), REQ-030 (activate
  transitions, `get_active_by_name/1`), REQ-031 (service-scope validator, confirms
  `service_id`/`plugin_handler` are node-attribute keys), REQ-035 (`promotion_reviews`
  schema, `def_id` = process key), REQ-037 (`PromotionReview` state machine, confirms
  this design's output is consumed there), REQ-038 (rollback — confirms the same
  permission-check-shape open question recurs there, so REQ-036's treatment of it is
  not a one-off), REQ-039 (sandbox pool — confirms sandbox schemas are NOT rows in
  `tenants`, relevant to the tenant-classification open question below), REQ-041
  (`Letflow.Definitions` — confirms this context module already exists but
  `compute_promotion_plan/5` is **not** added to it; the three modules below are new
  sibling submodules, same pattern as `Letflow.Definitions.Graph`/`SnapshotStore`).
- `docs/guides/backend_developer_guide.md` — §3.5 (error shapes: `:ok | {:error, _}`
  or `{:ok, _} | {:error, _}`, every `@spec` states the error shape), §3.6 (SQL
  parameterization — N/A here, `Ecto.Query`/`Repo.get_by` only, no raw SQL), §5
  (schema-per-tenant via `:prefix`).
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant isolation via
  `:prefix`; the 2026-08-17 addendum's write-time `tenant_id` derivation rule does not
  apply to this design since all three modules are read-only, no writes to any table).
- `docs/migration/stage-2-event-store-definitions.md` — "Early findings" section:
  process-per-instance-vs-row-based-state finding does not apply here — no state is
  held at all; all three modules are pure or read-only, stateless computations, same
  category as `Letflow.Definitions.Graph`.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — Decision B (schema-per-tenant
  via `:prefix`), confirms the isolation mechanism this design's queries use.

**Letflow shipped code, read directly (not assumed):**

- `lib/letflow/definitions/process_definition.ex` — full file. Confirmed schema:
  `id, tenant_id, name, version (string, no numeric constraint anywhere), description,
  status (Ecto.Enum :draft/:active/:deprecated/:archived, lowercase-dumped), stage,
  graph (:map, default %{"nodes" => [], "edges" => []}), created_by, archived_at,
  timestamps`. No `@schema_prefix` — every call must pass `prefix: schema_name`
  explicitly. **No `variable_schema` column of any kind.**
- `lib/letflow/definitions/graph.ex` — full file, read for module-style precedent
  (moduledoc structure, `@spec` conventions, pure-function error-shape divergence
  precedent) and for the `Node`/`Edge` struct shapes (`%Node{id, node_type, label,
  attributes}`, `%Edge{id, source, target, condition, is_default}`) — confirmed these
  structs are **not** how `process_definitions.graph` is stored (that column is a plain
  `:map` with string keys); no `from_map`/`to_struct` conversion function exists
  anywhere in this codebase yet (§2 below explains why this design therefore diffs the
  raw jsonb map directly rather than depending on a `Graph`-struct conversion that
  doesn't exist).
- `lib/letflow/definitions/promotion_review.ex` — full file. Confirmed
  `promotion_reviews` schema: `tenant_id, plan_digest (64 lowercase hex chars,
  validated by format regex), def_type (default "process"), def_id (string —
  this is `process_key`), serialised_plan (string), status, requested_by, approved_by,
  approved_at, superseded_by, row_version`. Confirmed this table's moduledoc states
  REQ-036 (`compute_promotion_plan/5`, `compute_plan_digest/1`, `verify_digest/2`) is
  the producer of the values `insert_review/1` (REQ-037) will later persist into
  `serialised_plan`/`plan_digest` — this design's `PromotionPlan.t()`/digest shapes are
  therefore a load-bearing contract for REQ-037, not just for this requirement's own
  acceptance criteria.
- `lib/letflow/definitions.ex` — full file (REQ-041). Confirmed it exposes
  `compute_pack_update_plan/5`/`classify_artefact/3` only; confirmed its own moduledoc's
  historical note that REQ-036 "would have been this module's first function" but is
  `status: pending` — this design does **not** retrofit REQ-036's functions into
  `Letflow.Definitions` (the task's given module names are `Letflow.Definitions.PromotionPlan`
  /`PromotionConflict`/`PromotionDigest`, sibling submodules, not top-level context
  functions); `definitions.ex`'s own stale note is left uncorrected as an unrelated
  file, not touched by this design.
- `lib/letflow/identity/role_registry.ex` + `lib/letflow/identity/tenant_role.ex` +
  `lib/letflow/identity/group.ex` — full files. Confirmed `Letflow.Identity.RoleRegistry`
  is a `(role name :: String.t()) -> group_id :: Ecto.UUID.t() | nil` binding registry
  and nothing more: `list_roles/0`, `upsert_role/2`, `resolve_role_in_tx/1`. **There is
  no user→role assignment, no group-membership table, and no permission-string concept
  anywhere in this codebase.** `Group` (`lib/letflow/identity/group.ex`) is explicitly
  scoped down to "exactly what `tenant_role.group_id`'s FK target ... need[s]" with
  "full group-membership modeling ... explicitly out of scope." This is the concrete
  finding behind Open Question 1 (§9.1) — read directly, not inferred from the
  requirement text's own warning.
- `lib/letflow/identity/tenant.ex` — full file. Confirmed `tenants` schema:
  `slug, display_name, status (:active | :migrating), idp_realm_id`. **No tenant
  "kind"/"type" column of any sort** — `status` distinguishes only normal-vs-write-paused,
  not production-vs-test. This is the concrete finding behind Open Question 2 (§9.2).
- `lib/letflow/tenant_provisioning.ex` + `lib/letflow/tenant_provisioning/registration.ex`
  — full files. Confirmed `schema_name_for_tenant/1` is a **pure** derivation
  (`"tenant_" <> 32 lowercase hex chars`, from `tenant_id`, no DB round-trip) — this
  design uses it directly to derive `:prefix` for both `source_tenant_id` and
  `target_tenant_id`, since `compute_promotion_plan/5`'s given signature takes tenant
  UUIDs, not a `:prefix`-shaped opt the way `SnapshotStore.create/3` does.
- `lib/letflow/design/req039-sandbox-pool-fixture-loader.md` — read the "Divergence
  from Zig's `{process_definitions, variable_schemas, instances}`" note (line ~506):
  confirms **`variable_schemas` has never been ported** to Letflow — no column, no
  table, "no Letflow equivalent today." Also confirms sandbox-pool schemas
  (`sandbox_<hex>`) are raw ad hoc Postgres schemas with **no corresponding row in
  `tenants`** — relevant to Open Question 2 (§9.2): a "test tenant" in R-Co's sense
  is structurally disjoint from a sandbox-pool schema in Letflow's port.

PROVENANCE (historical, not current decision authority):
**R-Co source (`src/definition/promotion_plan.zig` PRM-01,
`src/definition/promotion_conflict.zig` PRM-02, `src/definition/promotion_digest.zig`
PRM-03, and their `src/design/prm-0{1,2,3}-*.md` design docs): genuinely unreachable on
this host**, re-checked directly per this run's own instructions:

```
$ find / -maxdepth 4 -iname "R-Co" 2>/dev/null
(no output)
$ find / -iname "promotion_plan.zig" -o -iname "prm-01*" 2>/dev/null
(no output)
```

This design therefore works from `docs/requirements.yaml`'s REQ-036 entry (itself a
detailed paraphrase of PRM-01/02/03) plus direct inspection of every Letflow module the
entry names, as listed above. Every place this design had to make a call R-Co's own
source might have settled differently is called out explicitly in §9 (Open questions)
rather than guessed silently.

---

## 1. Scope boundary

**In scope:** three new sibling submodules under `lib/letflow/definitions/`:

PROVENANCE (historical, not current decision authority):
| File | Module | Ported from |
|---|---|---|
| `lib/letflow/definitions/promotion_plan.ex` | `Letflow.Definitions.PromotionPlan` | `promotion_plan.zig`, PRM-01 |
| `lib/letflow/definitions/promotion_conflict.ex` | `Letflow.Definitions.PromotionConflict` | `promotion_conflict.zig`, PRM-02 |
| `lib/letflow/definitions/promotion_digest.ex` | `Letflow.Definitions.PromotionDigest` | `promotion_digest.zig`, PRM-03 |

No migration — this design reads `process_definitions` (REQ-027, already shipped)
unchanged. No writes anywhere: all three modules are pure or read-only.

**Explicitly NOT in scope, not silently dropped:**

| Not built here | Owned by |
|---|---|
| `insert_review/1`, `approve_review/4`, etc. (the `promotion_reviews` state machine) | REQ-037 |
| `promote_definition/N` (the actual version-pointer move + event append) | REQ-037 |
| The `DEFINITION_PROMOTION_REJECTED` event's schema/append call | Unassigned — REQ-036's own PRM-02 Open question 1, restated at §9.4 |
| HTTP layer (`POST /api/v1/promotions` and friends) | S4 |
| Service-catalog / plugin-registry resolution of `service_id` values | Deliberately never — PRM-01's own scoping note (§2.3 below) |
| A `variable_schemas` table/column | Unassigned — no requirement ports this yet (§9.3) |
| A tenant "kind" (production/test) column | Unassigned (§9.2) |
| Real actor→permission resolution for `promotion.submit` | Unassigned — same gap named in REQ-020/037/038 (§9.1) |

---

## 2. Shared types and terminology

### 2.1 `process_key` ≡ `process_definitions.name`

`process_definitions` has no `process_key` column. Every other REQ-036-adjacent
requirement (REQ-030's `get_active_by_name/1`, REQ-038's rollback, REQ-035's
`promotion_reviews.def_id`) uses a process's `name` column as its stable identity
across versions. This design reads `process_key` as `process_definitions.name`
throughout — stated explicitly since it is a terminology mapping, not a literal column
name.

### 2.2 `before`/`after` convention: `before` = target, `after` = source

A `PlanEntry` (§3.1) represents *what changes when promotion is applied to the
target*. `before` is always the **target** tenant's current value for that unit;
`after` is always the **source** tenant's value (the value that would land at the
target once promoted). This is what makes "target has no existing version of
`process_key`" (AC1) mechanically force every entry to `change_kind: :added` with no
special-casing: `before` is `nil` for every dimension in that case (nothing at the
target to diff against), so every dimension where the source has a non-nil value
naturally computes `:added`.

### 2.3 Five diff dimensions (resolving an ambiguity in the requirement prose explicitly)

The requirement text lists "graph nodes/edges (by id: added/modified/removed),
variable_schema, service-catalog bindings ..., module_ref VALUES ..." and separately
states "across 5 dimensions." Read literally, that prose names 4 bullet groups; this
design resolves the count by splitting "graph nodes/edges" into two dimensions (nodes,
edges), which is the only reading that totals 5:

| # | `PlanEntry.type` | Source data | `id` |
|---|---|---|---|
| 1 | `:graph_node` | `graph["nodes"]`, by `"id"` | node id |
| 2 | `:graph_edge` | `graph["edges"]`, by `"id"` | edge id |
| 3 | `:variable_schema` | none today (§9.3) | literal `"variable_schema"` |
| 4 | `:service_binding` | `SERVICE_TASK` node's `attributes["service_id"]` | owning node's id |
| 5 | `:module_ref` | `SUB_PROCESS` node's `attributes["module_ref"]` | owning node's id |

This resolution is stated here as an explicit design decision (not a silent guess) —
flag to REVIEWER if R-Co's own PRM-01 doc, once reachable, counts differently.

### 2.4 Raw jsonb-map diffing, not `Letflow.Definitions.Graph` structs

`process_definitions.graph` is stored (and read back by `Repo`) as a plain
`%{"nodes" => [...], "edges" => [...]}` map with string keys — this is the literal
`Ecto.Schema` field type (`:map`). `Letflow.Definitions.Graph`/`Graph.Node`/`Graph.Edge`
are a *different*, atom-keyed struct representation used only by the REQ-028/029
structural validators, and no conversion function between the two exists anywhere in
this codebase yet (confirmed by direct inspection, §0). This design diffs the raw jsonb
map directly — `node["id"]`, `node["node_type"]`, `node["attributes"]["service_id"]`,
all string-keyed — rather than depending on a `Graph`-struct constructor that would
have to be invented here. `PromotionPlan` has **no** compile-time dependency on
`Letflow.Definitions.Graph`.

### 2.5 Entry ordering is a load-bearing determinism invariant

`entries` (§3.1) is not returned in map/DB iteration order. Every entry across all 5
dimensions is deterministically sorted by `{type_rank(type), id}` before being
returned, where `type_rank/1` is a fixed total order over the 5 dimension atoms
(`:graph_node < :graph_edge < :variable_schema < :service_binding < :module_ref`) and
`id` sorts by Elixir's default (binary/lexicographic) term ordering. This guarantees
`compute_promotion_plan/5` called twice on byte-identical inputs returns
byte-identical `entries` — a necessary precondition for `compute_plan_digest/1`'s own
determinism guarantee (AC5), since `PromotionDigest`'s canonicalization (§5.1) sorts
JSON **object** keys but does **not** reorder JSON **arrays** — `entries` is encoded as
a JSON array, so if its element order were nondeterministic the digest would be too.
State this cross-module dependency explicitly in both `PromotionPlan`'s and
`PromotionDigest`'s moduledocs.

---

## 3. Module 1 — `Letflow.Definitions.PromotionPlan`

### 3.1 Types

```
@type change_kind :: :added | :modified | :removed

@type entry_type :: :graph_node | :graph_edge | :variable_schema
                   | :service_binding | :module_ref

@type plan_entry :: %{
        type: entry_type(),
        id: String.t(),
        change_kind: change_kind(),
        before: map() | String.t() | nil,
        after: map() | String.t() | nil
      }
# before/after are `map()` for :graph_node/:graph_edge (the raw node/edge jsonb
# map), `String.t() | nil` for :variable_schema/:service_binding/:module_ref
# (raw string values; :variable_schema's value shape is itself an open question,
# see §9.3 -- treated as an opaque nullable term until that lands).

@type t :: %{
        source_tenant_id: Ecto.UUID.t(),
        target_tenant_id: Ecto.UUID.t(),
        process_key: String.t(),
        source_definition_id: Ecto.UUID.t() | nil,
        target_definition_id: Ecto.UUID.t() | nil,
        # target's ACTIVE version string at plan-compute time, nil if target has
        # no ACTIVE row for process_key. Fed verbatim into
        # PromotionConflict.reject_if_conflicts/4's base_version argument by
        # REQ-037's caller at approval time -- the PRM-01/PRM-02 handoff point.
        base_version: String.t() | nil,
        entries: [plan_entry()]
      }

@type promotion_opts :: [
        permission_checker: (Ecto.UUID.t(), Ecto.UUID.t() -> boolean()),
        tenant_classifier: (Ecto.UUID.t() -> :production | :test),
        variable_schema_fetcher:
          (Ecto.UUID.t(), String.t() -> map() | String.t() | nil)
      ]

@type compute_error ::
        :forbidden
        | :invalid_promotion_source
        | :empty_plan
        | :invalid_tenant_id
```

`t()`/`plan_entry()` are the shared contract REQ-037's `insert_review/1` serializes
into `promotion_reviews.serialised_plan` (via `Jason.encode!/1` on this exact shape —
not this design's concern how REQ-037 serializes it, only that the shape is stable) and
`PromotionDigest.compute_plan_digest/1` (§5.1) hashes.

### 3.2 `compute_promotion_plan/5`

```
@spec compute_promotion_plan(
        actor_id :: Ecto.UUID.t(),
        source_tenant_id :: Ecto.UUID.t(),
        target_tenant_id :: Ecto.UUID.t(),
        process_key :: String.t(),
        opts :: promotion_opts()
      ) :: {:ok, t()} | {:error, compute_error()}
```

**Algorithm, in order (each step short-circuits on failure — no step after a failing
one runs):**

1. Resolve `opts[:permission_checker]` (no built-in default — §9.1) and call it with
   `(actor_id, source_tenant_id)`. `false` → `{:error, :forbidden}`. No DB read has
   happened yet.
2. Resolve `opts[:tenant_classifier]` (defaults to `default_tenant_classifier/1`, a
   named function in this module — §9.2 states exactly what it does and why) and call
   it with `source_tenant_id`. `:production` → `{:error, :invalid_promotion_source}`.
   Still no `process_definitions` read — satisfies AC3's "before reading any
   process_definitions row" literally, and this ordering also means the
   invalid-promotion-source check never runs `Ecto.UUID.cast/1` on `target_tenant_id`
   before rejecting, only on `source_tenant_id`.
3. `Letflow.TenantProvisioning.schema_name_for_tenant/1` on both `source_tenant_id`
   and `target_tenant_id`. Either returning `{:error, :invalid_tenant_id}` short-circuits
   the whole call with that same tuple.
4. Read the source's ACTIVE definition: `Repo.get_by(ProcessDefinition,
   [name: process_key, status: :active], prefix: source_prefix)`. `nil` is not an
   error here — treated as "source has nothing," §3.3 explains the fallout.
5. Read the target's ACTIVE definition the same way, under `target_prefix`. `nil` is
   likewise not an error — this is the "target has no existing version of
   `process_key`" case AC1 names.
6. Build the 5 dimensions' raw `{before, after}` pairs (§3.4) from whichever of
   source/target rows exist (a `nil` row contributes `nil`/`%{"nodes" => [],
   "edges" => []}` to every dimension it's absent from, per the field's own default).
7. For each dimension, diff by id (§3.4) into `plan_entry()`s, dropping any unit where
   `before == after` (including both-`nil`).
8. Sort all produced entries per §2.5.
9. If `entries == []` → `{:error, :empty_plan}` (AC2). Otherwise →
   `{:ok, %{source_tenant_id: ..., target_tenant_id: ..., process_key: process_key,
   source_definition_id: (source row's id or nil), target_definition_id: (target
   row's id or nil), base_version: (target row's version or nil), entries: entries}}`.

### 3.3 Empty-target fallout (AC1), stated precisely

When the target read (step 5) returns `nil`, every dimension's `before` is `nil`
(graph dimensions: `nil` node/edge map; scalar dimensions: `nil` string) — there is no
special-case branch for this, it falls out of feeding an absent row's defaults through
the same diff logic every other case uses. Every unit present on the source side then
computes `change_kind: :added` by the ordinary rule (`before == nil, after != nil` →
`:added`) — this is what AC1 asserts, and no separate code path needs to exist to make
it true.

### 3.4 Per-dimension diff algorithm (prose, not code)

**`:graph_node` / `:graph_edge`:** index each side's `graph["nodes"]` (respectively
`["edges"]`) list into a `%{id_string => raw_map}` map keyed by `entry["id"]`. Union
the two sides' key sets. For each key: `before` = target-side map or `nil`, `after` =
source-side map or `nil`. `change_kind` per the standard rule (§2.5's ordering feeds
off this, not the other way round): `before == nil` → `:added`; `after == nil` →
`:removed`; `before != after` (deep/structural `==` — the raw maps compared as
ordinary Elixir terms, including nested `"attributes"`) → `:modified`; `before ==
after` → no entry produced.

**`:service_binding`:** filter target/source `graph["nodes"]` to `node_type ==
"SERVICE_TASK"`, index by node id, read `node["attributes"]["service_id"]` (a raw
string or `nil` — **never** resolved against a service catalog; PRM-01's own scoping
note, restated in the requirement text, is that this doesn't need REPO-07/PLC-01 to
exist since it's a byte-value diff, not an identity lookup). Same union/before-after/
change_kind rule as above, but `before`/`after` are the raw string values, not maps. A
node present on only one side that is a `SERVICE_TASK` but carries no `service_id`
attribute contributes `nil` for that side (no entry unless the other side has a
non-nil value).

**`:module_ref`:** identical algorithm to `:service_binding`, filtered to `node_type
== "SUB_PROCESS"`, reading `node["attributes"]["module_ref"]`. Same never-resolved
treatment — flagged in the requirement text itself as PRM-01's own Open question 2 for
a possible future PRM-02 revisit; this design does not resolve it either (§9.5).

**`:variable_schema`:** `before` = `opts[:variable_schema_fetcher].(target_tenant_id,
process_key)`, `after` = the same call with `source_tenant_id`. Single unit, `id`
always the literal string `"variable_schema"`. §9.3 states the default fetcher and why
it currently always contributes zero entries.

---

## 4. Module 2 — `Letflow.Definitions.PromotionConflict`

### 4.1 Types

```
@type conflict_detail :: %{
        process_key: String.t(),
        target_definition_id: Ecto.UUID.t(),
        target_active_version: String.t(),
        base_version: String.t()
      }

@type conflict_error ::
        {:conflicts, [conflict_detail()]}
        | :mismatched_process_key_list
        | :invalid_tenant_id
```

### 4.2 `reject_if_conflicts/4`

```
@spec reject_if_conflicts(
        actor_id :: Ecto.UUID.t(),
        target_tenant_id :: Ecto.UUID.t(),
        process_key :: [String.t()],
        base_version :: [String.t()]
      ) :: :ok | {:error, conflict_error()}
```

**Resolving "supports multiple process_key conflicts as a list" (PRM-02's own Open
question 2) against the task's fixed 4-arity signature:** the task briefing names the
signature `reject_if_conflicts/4(actor_id, target_tenant_id, process_key,
base_version)` with those exact 4 parameter names, but also requires plural support.
This design's explicit resolution: `process_key` and `base_version` are each **lists**,
index-aligned by position — the *i*-th `base_version` element is checked against the
*i*-th `process_key` element. This keeps the literal 4-arity/4-name signature while
satisfying the plural requirement, and is stated here as a deliberate resolution (not
a silent guess) so REVIEWER can weigh it against R-Co's own PRM-02 doc once reachable.
A caller checking a single `process_key` passes 1-element lists.

**Algorithm:**

1. `length(process_key) != length(base_version)` → `{:error, :mismatched_process_key_list}`.
2. `Letflow.TenantProvisioning.schema_name_for_tenant/1` on `target_tenant_id` →
   `{:error, :invalid_tenant_id}` on failure.
3. For each `{key, base}` pair (in input order): `Repo.get_by(ProcessDefinition,
   [name: key, status: :active], prefix: target_prefix)` — **a plain
   `Repo.get_by/3` call, no `lock/2`, no `FOR UPDATE`, no `Repo.transaction/1`**,
   satisfying PRM-02's explicit "plain read" requirement. `nil` (target has zero rows
   for this `process_key`) → no conflict for this pair. A row exists → compare its
   `version` against `base` via `version_greater?/2` (§9.4 — numeric comparison,
   confirmed against R-Co source). `true` → append a `conflict_detail()` for this pair; `false`/`==` →
   no conflict for this pair.
4. Collected conflict list `== []` → `:ok`. Non-empty → `{:error, {:conflicts, list}}`
   (AC4: naming each conflicting definition, as a list, satisfies "with
   `target_active_version <= base_version` (including the target having zero rows)
   returns no conflict" for every pair individually, and the aggregate `:ok` only when
   *no* pair conflicts).

`actor_id` is accepted (per the given signature) but this design does **not** gate it
on a permission check — the requirement text names a permission gate for
`compute_promotion_plan/5` (§3.2 step 1) and for REQ-038's rollback, but not for this
function. Read as deliberate: `reject_if_conflicts/4` is a preflight re-check REQ-037's
already-permission-gated approve/apply flow calls internally, not a fresh entry point.

PROVENANCE (historical, not current decision authority):
**Confirmed against R-Co source (GH#321, ISS-0093):** `R-Co/src/definition/promotion_plan.zig:99-102`
runs the permission check — `checkPermission(allocator, pool, actor_id, "promotion", "submit")`
— as "Step 1" of `computePromotionPlan()` (PRM-01, the `compute_promotion_plan/5` counterpart),
not inside the conflict check. `R-Co/src/design/prm-02-conflict-preflight-rejection.md`'s
`rejectIfConflicts` (PRM-02, this function's R-Co counterpart) has signature
`(allocator, pool, target_tenant_id, process_key, base_version)` — **no `actor_id` parameter
at all** — and its module purpose/data-flow/dependencies sections describe no permission check
of its own; it is a plain read (`SELECT MAX(version::int) ...`) plus a conditional single-event
append, called *after* `computePromotionPlan()` and *before* the `promotion_reviews` insert
(PRM-04). This settles the inference exactly as this design already read it: R-Co gates
`actor_id` once, at plan-computation time, not again in the conflict-preflight step. Letflow's
choice to keep `actor_id` in this function's own signature (unlike R-Co, which omits it
entirely) is solely to satisfy the task briefing's literal 4-arity/4-name signature (§4.2 above)
— it remains an accepted-but-unused parameter, not a divergence in gating behaviour.

This function does **not** call `Letflow.EventStore.append/N` on conflict — no
`DEFINITION_PROMOTION_REJECTED` event is appended here, matching the requirement
text's explicit instruction. §9.6 restates the deferred event-schema open question.

---

## 5. Module 3 — `Letflow.Definitions.PromotionDigest`

### 5.1 `compute_plan_digest/1`

```
@spec compute_plan_digest(plan :: PromotionPlan.t() | %{entries: [PromotionPlan.plan_entry()]}) ::
        digest :: String.t()  # 64-char lowercase hex
```

Hashes **`plan.entries`** (the entries list, not the full plan envelope — the
requirement text is explicit: "SHA-256 over the CANONICAL JSON serialization of a
PromotionPlan's **entries**"). Pure — no I/O, cannot fail on a well-typed input (same
"cannot fail in the usual `:ok`/`:error` sense" divergence `Graph.validate_graph/1`
already establishes as precedent for this codebase, per backend guide §3.5's own
carve-out), so the return type is a bare `String.t()`, not `{:ok, _}`.

**Algorithm, named exactly (per the acceptance criteria's explicit demand):**

1. `canonicalize/1` (private helper) recursively walks `plan.entries`:
   - A map → sort its keys via `Enum.sort/1` on `Map.keys/1` (Elixir/Erlang's default
     term ordering, which for the `String.t()` keys used everywhere in a `plan_entry()`
     is byte-wise lexicographic — noted explicitly since this is the exact ordering the
     acceptance criteria call "key-sorted"), recursively `canonicalize/1` each value in
     that sorted order, and rebuild as a `Jason.OrderedObject.new/1` (Jason `~> 1.4`,
     already a dependency per `mix.exs`/`mix.lock` — `Jason.OrderedObject` preserves
     the exact pair order it's given at encode time, unlike a plain map, which is what
     makes the *sorted* order survive into the emitted JSON text).
   - A list → `Enum.map/2` `canonicalize/1` over elements, **order preserved, not
     sorted** — array order is significant (§2.5's entries-ordering invariant is what
     makes this safe: `entries`' own order is already deterministic before this
     function ever sees it).
   - An atom (e.g. `plan_entry().type`/`.change_kind` values like `:graph_node`,
     `:added`) → `Atom.to_string/1` (JSON has no atom type; the string form is what
     round-trips deterministically).
   - Anything else (`String.t()`, number, boolean, `nil`) → returned unchanged.
     **`nil` values are never dropped** by this step — a map's `nil`-valued key stays
     in the sorted key list and is recursed into like any other value (satisfies "null
     values included not omitted").
2. `Jason.encode!/1` the canonicalized structure — `Jason.encode!/1`'s default output
   already has no insignificant whitespace (no `pretty: true` option is passed),
   satisfying that requirement without extra work.
3. `:crypto.hash(:sha256, canonical_json_binary)` → raw 32-byte digest.
4. `Base.encode16/2` with `case: :lower` → the 64-char lowercase hex string.

**Why an explicit step, not reliance on Erlang's small-map internal ordering:** small
Erlang maps (≤32 associations) happen to store keys in already-sorted internal term
order, which could make `Jason.encode!/1` on a plain map look "already sorted" by
accident for small inputs. The requirement's own CRITICAL note explicitly rejects
relying on this — it is an implementation detail, not a documented contract, doesn't
hold for maps above the 32-key threshold, and is exactly the pitfall PRM-03's own
"Open question 2" flags for Zig's `std.json.stringify` (same risk, different language).
This design's `canonicalize/1` step makes the sort explicit and independent of map
size or the underlying VM's internal representation.

### 5.2 `verify_digest/2`

```
@spec verify_digest(
        digest :: String.t(),
        plan_or_digest :: PromotionPlan.t() | %{entries: [PromotionPlan.plan_entry()]} | String.t()
      ) :: boolean()
```

If `plan_or_digest` is a binary matching the 64-lowercase-hex-char shape, compare it
directly against `digest`. Otherwise (a plan-shaped map with an `:entries` key), call
`compute_plan_digest/1` on it first, then compare. **Comparison is
`:crypto.hash_equals/2`** (OTP 25+'s constant-time binary comparator, per the backend
guide's OTP 26+ baseline) — **never `Kernel.==/2` or `:erlang.=:=/2` directly on the
two strings**, matching PRM-03's own "avoid timing attacks" note. State this exact
function name in the moduledoc, per AC6's explicit demand.

---

## 6. DB access patterns / tables touched

| Table | Module(s) | Access | Notes |
|---|---|---|---|
| `process_definitions` (REQ-027) | `PromotionPlan`, `PromotionConflict` | `Repo.get_by/3`, plain read, `prefix: schema_name` | No `FOR UPDATE`/`lock/2` anywhere in either module — PRM-02's "plain read" requirement (§4.2) applies to `PromotionConflict`; `PromotionPlan`'s own two reads (source/target ACTIVE lookups) are likewise unlocked, matching PRM-01's read-only nature. |
| `promotion_reviews` (REQ-035) | none | none | Not read or written by any of these 3 modules — REQ-037's job. |
| `variable_schemas` | none | none | Does not exist in Letflow (§9.3) — `opts[:variable_schema_fetcher]`'s default performs no query at all. |

Scoping is via `:prefix` only (INV-1), derived from `TenantProvisioning.schema_name_for_tenant/1`
for both `source_tenant_id`/`target_tenant_id` (`PromotionPlan`) and `target_tenant_id`
(`PromotionConflict`) — no additional `tenant_id` equality filter is layered on top,
since the Postgres schema already is the sole isolation boundary for this table (same
reasoning `process_definitions`'s own migration header gives for why a
`tenant_id`-leading index would be redundant under Decision B).

All three modules perform **zero** `INSERT`/`UPDATE`/`DELETE` statements.

---

## 7. Cross-module dependencies

```
PromotionConflict.reject_if_conflicts/4
        ^
        | base_version (from PromotionPlan.t().base_version, REQ-037's job to thread through)
        |
PromotionPlan.compute_promotion_plan/5 --> PromotionPlan.t() --> PromotionDigest.compute_plan_digest/1
                                                              \-> (REQ-037's insert_review/1, serialised_plan)

PromotionDigest.verify_digest/2 <-- plan_digest column (promotion_reviews, REQ-035) + a freshly-recomputed
                                     or freshly-supplied plan (REQ-037's approve_review/4 gate, per
                                     docs/requirements.yaml's PRM-05 "plan_digest matches the stored
                                     value exactly" gate)
```

`PromotionPlan` depends on `Letflow.Definitions.ProcessDefinition` (schema read) and
`Letflow.TenantProvisioning.schema_name_for_tenant/1` (prefix derivation). It does
**not** depend on `Letflow.Definitions.Graph` (§2.4) or `Letflow.Identity.RoleRegistry`
in any load-bearing way (the default `permission_checker` is unresolved, §9.1 — if
ELIXIR-DEV's eventual implementation calls `RoleRegistry` at all, that call cannot by
itself prove actor-level authorization, since group membership isn't modeled; note
this explicitly wherever the default is implemented, don't let the `alias` imply more
than it delivers).

`PromotionConflict` depends on `Letflow.Definitions.ProcessDefinition` and
`Letflow.TenantProvisioning.schema_name_for_tenant/1` only.

`PromotionDigest` depends on nothing but `Jason` and `:crypto`/`Base` (stdlib) — it
takes any `%{entries: [...]}`-shaped map, so it has no compile-time dependency on
`PromotionPlan` itself (structural typing, consistent with `@type t :: %{...}` rather
than a named struct for `PromotionPlan.t()` — see §9.7).

---

## 8. Invariants

- **INV-PRM-1 (pure/read-only):** none of the three modules perform a write. A future
  REVIEWER pass can grep for `Repo.insert`/`Repo.update`/`Repo.delete`/`Repo.update_all`
  across all three files and expect zero hits.
- **INV-PRM-2 (entry-order determinism, §2.5):** `entries` is always sorted by
  `{type_rank, id}` before being returned from `compute_promotion_plan/5` — required
  for `compute_plan_digest/1`'s determinism guarantee (AC5) to hold in practice, since
  digest canonicalization sorts object keys but not array order.
- **INV-PRM-3 (no service/plugin resolution):** `:service_binding`/`:module_ref`
  diffing is always a raw string comparison, never a catalog/registry lookup — REQ-036
  must not gain a dependency on REQ-031's `ServiceCatalog`/`PluginRegistry` gap (itself
  unresolved, per REQ-031's own moduledoc) merely by trying to be "more correct" here.
- **INV-PRM-4 (plain-read conflict check):** `reject_if_conflicts/4` never opens a
  `Repo.transaction/1` and never issues a locking read — any future change that adds a
  lock here is a divergence from PRM-02 requiring REVIEWER sign-off.
- **INV-PRM-5 (constant-time digest verification):** `verify_digest/2` must not be
  reachable via any code path that instead uses `==`/`=:=` on the two digest strings —
  grep-checkable (`:crypto.hash_equals` must be the only comparator against a
  `plan_digest`-shaped value across this module).

---

## 9. Open questions (explicit — not silently resolved)

### 9.1 `promotion.submit`-equivalent permission check does not map onto REQ-020's TenantRole model (flagged per the task's explicit instruction)

Confirmed by direct inspection (§0): `Letflow.Identity.RoleRegistry` is a
`role_name -> group_id` binding registry (`list_roles/0`, `upsert_role/2`,
`resolve_role_in_tx/1`) with **no permission-string concept, no user→role assignment,
and no group-membership table** — `Letflow.Identity.Group`'s own moduledoc states full
group-membership modeling is "explicitly out of scope" for the batch that shipped it
(REQ-015–REQ-021). There is therefore no data path in Letflow today from `actor_id` to
"does this actor hold `promotion.submit`" — not merely an inconvenient one, an
*absent* one. This is the same gap REQ-037's `PromotionReview`/REQ-038's rollback name
for their own permission checks (`platform.admin`-equivalent), so REQ-036 is not a
special case.

**This design does not invent a resolution.** `compute_promotion_plan/5`'s
`opts[:permission_checker]` (§3.1/§3.2 step 1) has **no built-in default** — the
function signature and call-order (checked first, before any DB read) are the concrete
design element satisfying "port the check SHAPE"; the actual authorization logic is
left for ELIXIR-DEV to supply as a named function (e.g. `default_permission_checker/2`)
whose own `@doc` must restate this exact gap, not silently imply real enforcement
exists. TEST-DESIGNER must inject a deterministic `permission_checker` via `opts` for
every test — there is no way to construct a real "actor lacks permission" fixture
against current schema.

### 9.2 "production tenant" vs. "test tenant" has no data-model equivalent

Confirmed by direct inspection (§0): `Letflow.Identity.Tenant` carries `slug,
display_name, status (:active | :migrating), idp_realm_id` — no kind/type/environment
column. Separately, REQ-039's sandbox pool provisions raw `sandbox_<hex>` Postgres
schemas that are **not** rows in `tenants` at all (no `tenant_id`), so "test tenant" in
R-Co's sense and "sandbox schema" in Letflow's port are structurally disjoint concepts,
not the same thing under two names.

**This design does not invent a tenant-kind column** (REQ-036's `depends_on` doesn't
include the identity-schema requirements, and adding one would be scope creep beyond
what this requirement was sized for). `opts[:tenant_classifier]` (§3.1) is the
injection point; this design does supply a concrete placeholder default,
`default_tenant_classifier/1`, specified here explicitly rather than left to ELIXIR-DEV
to guess: **classify every tenant as `:test`** (i.e., the invalid-promotion-source
check never fires under the default). Rationale, stated so REVIEWER can weigh it: since
no tenant can currently be proven "production" under any existing column, defaulting to
reject-nothing is the only default that doesn't fail closed on data that was never
designed to answer this question, and this project has no production deployment yet
(`CLAUDE.md`). AC3 is therefore only exercisable via a test that supplies
`opts[:tenant_classifier]` explicitly (returning `:production` for its fixture tenant)
until a real tenant-kind column exists — this is a limitation, stated here rather than
hidden. Flag to REVIEWER/REQ-ANALYST: a future requirement may need to add the missing
column and this default should be revisited when it lands.

### 9.3 `variable_schema` has no Letflow storage at all

Confirmed by direct inspection (§0, and `req039-sandbox-pool-fixture-loader.md`'s own
"Divergence" note): no `variable_schemas` table, no `process_definitions.variable_schema`
column — "no Letflow equivalent today." `opts[:variable_schema_fetcher]` (§3.1) has a
concrete safe default: `fn _tenant_id, _process_key -> nil end` — always absent on both
sides, so the `:variable_schema` dimension contributes zero entries under the default
until a real store exists. Unlike §9.1/§9.2, this default is not a guessed business
rule — "no data source exists" is an objectively true current fact, not a decision with
security or correctness consequences, so giving a concrete default here (rather than
only flagging) is appropriate.

### 9.4 `version` comparison semantics — RESOLVED (GH#322, ISS-0094, 2026-08-20)

`process_definitions.version` is `:string`/`varchar(255)` with **no numeric or semver
constraint anywhere** in REQ-027's design or migration (confirmed §0) — R-Co's own
`definition.md` names only a non-empty (`VersionEmpty`) constraint. PRM-02 defines
conflict as `target_active_version > base_version`, an ordinal comparison; at the time
this design was written, R-Co's source was unreachable to confirm whether `version`
follows a monotonic-integer-as-string convention (in which case numeric comparison is
correct and `"10" > "9"`) or is genuinely free text (in which case only lexicographic
`>` is well-defined, and `"10" > "9"` would be **false**).

**Confirmed against R-Co source (GH#322, ISS-0094, resolves the open question):** the
R-Co tree is reachable at `c:\Users\tvolo\dev\ai-dala\R-Co`. Both ends of R-Co's own
`version` handling were read directly:

PROVENANCE (historical, not current decision authority):
- **Write path** — `R-Co/src/definition/promotion.zig` L286-318 (`computePromotionPlan`'s
  next-version step): the next version is computed as `SELECT COALESCE(MAX(version::int),
  0)::text AS max_ver` (L295) — a Postgres integer cast/aggregate — then formatted back
  with `std.fmt.allocPrint(allocator, "{d}", .{next_version})` (L313). R-Co is the sole
  writer of `version`, and it **always** assigns the next sequential integer as decimal
  text (`"1"`, `"2"`, `"3"`, …) — never free text, never semver.
- **Read/compare path** — `R-Co/src/definition/promotion_conflict.zig` L50/74-99
  (`rejectIfConflicts`): the query itself casts `(version::int)::text` (L74-76) — a
  non-numeric `version` would make this SQL cast raise, not fall back to a string
  comparison — and both `base_version` and the parsed `target_version` are typed `u32`
  (L22/50), compared with a plain numeric `<=` (L99, `if (target_version <= base_version)
  return null`). R-Co has **no lexicographic fallback anywhere** in this file; a
  non-numeric value is a hard error condition on read, not a second comparison mode.

This settles the open question: `process_definitions.version` follows a
monotonic-integer-as-string convention by construction (R-Co's own write path
guarantees it), and R-Co's own conflict check is a pure numeric comparison, never a
lexicographic one. PRM-02's `target_active_version > base_version` means ordinal-as-integer,
confirmed, not ordinal-as-string.

**Effect on this design's `version_greater?/2`, stated precisely:** no change to the
algorithm was needed. The existing design — `Integer.parse/1` on both strings, numeric
`>` when both parse cleanly — already matches R-Co's confirmed semantics exactly and
remains correct. The lexicographic fallback branch (used when either string fails to
parse as an integer) is **not** matching an R-Co free-text convention — no such
convention exists — it is pure defensive slack for Letflow's own schema, which (unlike
R-Co's read path) has no `varchar(255)`-level numeric constraint or cast-time
enforcement. That branch should not be expected to ever trigger against
R-Co-conformant data; TEST-DESIGNER should still pin its behavior with an explicit
non-numeric-version test, but as a defensive/schema-slack case, not as a modeled R-Co
scenario.

### 9.5 `module_ref` raw-string treatment (inherited from the requirement text's own flag)

Restated, not newly discovered: the requirement text itself flags `module_ref`'s
never-resolved treatment as PRM-01's own "Open question 2 in prm-01 itself for a future
PRM-02 revisit if resolved module identity later turns out to be required." This design
does not resolve it either — `:module_ref` entries are always a raw string diff (§3.4),
matching `:service_binding`'s treatment exactly. No action needed here beyond carrying
the flag forward.

### 9.6 `DEFINITION_PROMOTION_REJECTED` event schema (deferred, per the requirement text)

Restated: `reject_if_conflicts/4` does not append this event (§4.2) — the requirement
text names this as PRM-02's own "Open question 1," left for whichever later requirement
wires this preflight into a real call site that does append events (REQ-024/025 exist
as the event-store primitives, but no event *type* or *payload schema* for this case
is registered by this design). Do not silently invent a payload shape when that later
requirement lands — re-derive it from PRM-02's own doc if reachable then.

### 9.7 `PromotionPlan.t()` is a structural map type, not a named struct

This design specifies `PromotionPlan.t()`/`plan_entry()` as plain map shapes (`@type t
:: %{...}`), not `defstruct`-backed structs, deliberately: `PromotionDigest` needs to
accept "anything with an `:entries` key" without a compile-time dependency on
`PromotionPlan` (§7), and REQ-037's `insert_review/1` needs to `Jason.encode!/1` this
shape directly for `serialised_plan` — a bare struct would carry a `__struct__` key
Jason would need explicit handling for. If ELIXIR-DEV finds a strong reason to use a
real struct instead (e.g. for `Ecto.Type` embedding later), that's a legitimate
divergence to flag to REVIEWER, not something this design mandates against — noted here
as a considered default, not a hard invariant.

---

## 10. Acceptance-criteria mapping

| # | Acceptance criterion | Concrete design element |
|---|---|---|
| 1 | `compute_promotion_plan/5` against a target with no existing version of `process_key` marks every entry `change_kind: :added` | §3.3 — empty-target fallout is a mechanical consequence of §3.4's generic before/after rule with `before = nil` for every dimension, not a special-cased branch. |
| 2 | Byte-identical source/target → empty-plan error, not an empty-entries plan | §3.2 step 9 — `entries == []` (after §3.4's before==after filtering) returns `{:error, :empty_plan}` explicitly, never `{:ok, %{entries: []}}`. |
| 3 | `source_tenant_id` that is a production tenant → invalid-promotion-source error, before any `process_definitions` read | §3.2 steps 1–2 order (`tenant_classifier` check runs before step 4/5's `Repo.get_by` calls); §9.2 states the classifier's injection point and flagged default. |
| 4 | `reject_if_conflicts/4`: `target_active_version > base_version` → rejection detail naming the conflict; `<=` (incl. zero rows) → no conflict | §4.2 algorithm steps 3–4; `conflict_detail()` (§4.1) names `process_key`/`target_definition_id`/`target_active_version`/`base_version` per conflicting pair; §9.4 states the `>` comparison's exact semantics, confirmed numeric against R-Co source (GH#322). |
| 5 | `compute_plan_digest/1` on identical-content, differently-key-ordered plans → identical digest | §5.1 — `canonicalize/1`'s explicit recursive sort-then-`Jason.OrderedObject`-encode step, named precisely, independent of Erlang's incidental small-map ordering (§5.1's closing note). |
| 6 | `verify_digest/2` uses a constant-time comparison, not `==`/`=:=`, stated in the moduledoc | §5.2 — `:crypto.hash_equals/2` named explicitly as the only comparator; INV-PRM-5 (§8) restates it as a grep-checkable invariant; ELIXIR-DEV's moduledoc must restate this per the AC's own wording. |

Every one of REQ-036's 6 acceptance criteria maps to a concrete, named design element
above — no "TBD" placeholders. Where this design could not resolve an underlying data-
model gap (permission mapping, tenant classification, `variable_schema` storage), it
says so explicitly in §9 with a stated default (or the deliberate absence of one) and
the reasoning behind that choice, rather than silently picking one and hiding the
assumption. (`version` comparison semantics, §9.4, was one such gap at authoring time;
it is now resolved against R-Co source — GH#322, ISS-0094.)
