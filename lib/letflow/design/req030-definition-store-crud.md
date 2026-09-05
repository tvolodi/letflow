PROVENANCE (historical, not current decision authority):
# Design: REQ-030 — Definition store CRUD (`store.zig`, PD-01/PD-03/PD-04/PD-07)

**Requirement:** REQ-030 (`docs/requirements.yaml`, stage S2, `depends_on: [REQ-027, REQ-028, REQ-029]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ030-20260817`, WF-02 Step 1
**This document produces:** module/function signatures, the tenant_id derivation contract,
the graph map↔struct conversion (resolving `req027-definition-core-schema.md` OQ-3), the
state-transition enforcement mechanism, the full error taxonomy, and invariants — **no
implementation code**. No function bodies, no `.ex` files. Pseudocode blocks describe
algorithm shape only (the convention `req025-event-append.md` §0 established) — ELIXIR-DEV
writes the real version at Step 2a.

---

## 0. Sources read for this design

**Letflow project docs, read in full:**

- `docs/requirements.yaml` — REQ-030's full entry (title, description, all 8 acceptance
  criteria, `depends_on`), REQ-027/028/029/031's entries for cross-reference.
- `docs/migration/decisions/0003-ecto-schema-strategy.md`'s 2026-08-17 addendum — the
  `tenant_id`-derivation mechanism this design must use (reverse
  `schema_name_for_tenant/1` via `tenant_id_for_schema_name/1`, never accept a
  caller-supplied `tenant_id`).
- `docs/guides/backend_developer_guide.md` §3.1 (naming), §3.5 (error shapes), §3.6 (SQL
  parameterization), §5 (multi-tenancy).
- `docs/anti-patterns.md` — no entry directly applicable to this module's own construction
  (the append-only-status-file and timestamp entries apply to bookkeeping, not this design).
- `lib/letflow/design/req027-definition-core-schema.md` — **read in full (1301 lines)**.
  §3.1/§3.1.2 (`process_definitions` columns and indexes, especially `uq_definition_version`,
  `uq_active_definition`'s `WHERE status = 'active'` predicate, `idx_def_status`,
  `idx_def_stage`), §5.1/§5.2 (the shipped `ProcessDefinition` schema and its two
  changesets — re-confirmed directly against the actual file, not this design's account of
  it), §5.2's "functions that will deliberately NOT exist" table (no
  `transition_allowed?/2`, no status-mutating changeset — transitions are guarded
  `UPDATE`s), §6 invariants INV-DEF-1..10, §9's OQ-1 (RESOLVED — `tenant_id` derivation,
  cites the same addendum), **OQ-3** (unresolved: who converts the `graph` jsonb map into
  `Letflow.Definitions.Graph`'s struct form — assigned to REQ-030, resolved by this design's
  §5), OQ-4 (the `after_created` cursor's skip-risk, assigned to REQ-030, resolved by this
  design's §6.4), OQ-5 (the `""` vs `NULL` stage normalization and the
  `InitialStatusNotDraft` params-boundary check, both assigned to REQ-030, resolved by this
  design's §6.1 and §4.1), §10 C-3 (status stored lowercase — load-bearing for the
  `uq_active_definition` predicate), C-4 (confirms the authoritative PD-04 table, re-verified
  directly against `definition.md` below rather than trusted secondhand), C-5 (the `ON
  CONFLICT (name, version)` **targeted** form is what REQ-030 must use, not R-Co's untargeted
  one — Letflow has exactly one uniqueness shape, so the ambiguity R-Co's untargeted form
  hedges against doesn't exist here).
- `lib/letflow/design/req029-node-attribute-edge-condition-validators.md` — **read in full**.
  §1's central finding, restated here because it changes REQ-030's own requirement text:
  **REQ-030's `create/1` must call BOTH `validate_node_attributes/1` AND
  `validate_edge_conditions/1`**, not only the one function
  (`validateNodeAttributes`) REQ-030's `docs/requirements.yaml` description names by name.
  §9.3 flags this gap explicitly for "REQ-030's CODE-DESIGNER" — this design closes it (§4.1
  step P8/P9). §2's `attributes`/node value-type table and the string-keyed-map,
  never-atom-keyed safety rule (atom-table-exhaustion hazard on tenant-controlled JSON) —
  load-bearing for this design's own `graph_struct_from_map/1` (§5), which faces the
  identical hazard one level up, on `node_type` strings.
- `docs/agents/instructions/security-invariants.md` — INV-1 (tenant isolation via the
  `tenant_id` addendum), INV-7 (no raw-SQL identifier/value interpolation — `fragment/1`
  with a bound `^value`, never string-built SQL), INV-8 (every external-I/O path returns a
  typed result, no unresolved `{:ok, _} =` match).

**Letflow shipped code, read directly (not assumed):**

- `lib/letflow/definitions.ex` — **full file (232 lines)**. Confirms the module currently
  holds only REQ-041's `compute_pack_update_plan/5` and `classify_artefact/3`, and confirms
  the moduledoc's own "Scope — REQ-041 only" section, which this design's §2 must extend
  rather than silently ignore or replace.
- `lib/letflow/definitions/process_definition.ex` — **full file (151 lines)**, REQ-027's
  shipped schema (status: `done`). Confirmed directly: `@primary_key {:id, :binary_id,
  autogenerate: true}`, the `status` field's bare-atom `Ecto.Enum` (dumps lowercase, matches
  `uq_active_definition`'s predicate), `create_changeset/2`'s exact cast/required list
  (`[:tenant_id, :name, :version, :description, :stage, :graph, :created_by]` /
  `[:tenant_id, :name, :version, :graph, :created_by]`) and its two
  `unique_constraint/3` declarations (`:uq_definition_version` on `[:name, :version]`,
  `:uq_active_definition` on `:name`), confirmed `:status` is **not** in either changeset's
  cast list (load-bearing for §4.1's explicit params-boundary status rejection —
  `create_changeset/2` would silently *drop* a caller-supplied `status` key rather than
  reject it), confirmed `update_changeset/2` exists but is **out of REQ-030's scope**
  (REQ-030's function list has no `update/1` — §1 records this explicitly).
- `lib/letflow/definitions/graph.ex` — **full file (979 lines)**, REQ-028/029's shipped,
  merged validator. Confirmed directly: `validate_graph/1`, `validate_node_attributes/1`,
  `validate_edge_conditions/1` all take the same `%Graph{nodes: [Node.t()], edges:
  [Edge.t()]}` struct and return the same `result() :: %{valid: boolean(), violations:
  [Violation.t()]}` shape; `Node`'s `@enforce_keys [:id, :node_type]` and `Edge`'s
  `@enforce_keys [:id, :source, :target]` (load-bearing for §5's structural-conversion
  algorithm — these are exactly the fields this design's `graph_struct_from_map/1` must
  guarantee are present before constructing either struct, since `Kernel.struct!/2`-style
  enforcement raises `ArgumentError` on a missing enforced key, which this design's
  boundary function must never let happen); confirmed none of the 17 named checks crash or
  misbehave on a `node_type` atom outside the closed 7-atom union (`check_isolated_nodes/1`'s
  `_other` branch, gateway-membership `MapSet.member?/2` checks, CHK-09..12's
  `Enum.filter(&(&1.node_type == :SOME_TYPE))` simply not matching) — confirmed empirically
  by reading the actual `case`/`cond`/`MapSet` logic, not assumed from the moduledoc's prose
  alone. This is what makes §5's `:unknown_node_type` sentinel safe to introduce without
  touching `graph.ex` at all.
- `lib/letflow/tenant_provisioning.ex` — **full file (397 lines)**. Confirmed
  `schema_name_for_tenant/1`'s encoding and, critically, **`tenant_id_for_schema_name/1`
  (added by REQ-025, lines 100–115)** — the exact function this design's §3 uses, read
  directly rather than taken on the task briefing's word: total, pure, pattern-matches
  `"tenant_" <> 32-lowercase-hex` and returns `{:ok, tenant_id} | {:error,
  :invalid_schema_name}`. Confirmed `replay_migrations/2`'s `try/rescue` idiom (raised
  exception → typed `{:error, {:migration_failed, exception}}`) — reused by this design's §6
  for the identical reason (a DB-layer exception must not escape a public boundary
  function, INV-8).
- `lib/letflow/event_store.ex` — **full file (583 lines)**, REQ-025's shipped `append/2`.
  Read as the explicitly-mandated precedent for this design's own tenant-derivation
  boundary. Confirmed directly: `reject_tenant_id/1`'s exact shape (`Map.has_key?(attrs,
  :tenant_id) or Map.has_key?(attrs, "tenant_id")` → `{:error, :tenant_id_not_accepted}`),
  the `opts :: [prefix: String.t()]` contract, the "registry/metadata validation completes
  with zero DB writes attempted, before `Repo.transaction/2` is ever called" ordering
  principle (reused by this design's `create/2` — all three graph-validator phases run
  before any DB call), and the `EventStore.TenantProvisioning.tenant_id_for_schema_name/1`
  call site itself (`event_store.ex:147`). This design's §3/§4.1 mirror this module's shape
  point-for-point, per the task's explicit instruction not to invent a third pattern.
- `deps/ecto/lib/ecto/repo.ex:1561–1614` — **read directly, and it overturned an initial
  assumption.** `c:update_all/3` has **no** `:returning` option (unlike `insert/2`,
  `update/2`, `insert_all/2`, `delete/2`, which do — confirmed at `repo.ex:1701, 1870, 2090,
  2210`). `update_all/3`'s own doc states plainly: "The second element is `nil` by default
  **unless a `select` is supplied in the update query**." This is load-bearing for §6.2/§6.3
  below: every guarded transition in this design uses an explicit `select([d], d)` on the
  query passed to `update_all/3`, not a `returning: true` option, which would silently do
  nothing (not raise) on this Ecto version.
- `lib/letflow/event_store.ex:345–379` (`assign_sequence/3`/`lock_and_increment_sequence/3`)
  — the shipped precedent for Ecto's `lock/2` query composition (`|> lock("FOR UPDATE")`) —
  reused by this design's `activate/2` for the row-level lock PD-03 requires, rather than a
  hand-written `SELECT ... FOR UPDATE` string (INV-7).

**R-Co source of truth (`C:\Users\tvolo\dev\ai-dala\R-Co\`), read directly — reachable this
session (unlike REQ-029's run, which flagged it as absent; re-verified fresh rather than
trusting that prior absence was still true):**

PROVENANCE (historical, not current decision authority):
- `src/definition/store.zig` (full read to line 1293, covering every function REQ-030
  ports) — `CreateParams`/`ListOpts` field docs (76–100), `create()`'s full body (186–316)
  including the exact validation-phase order **A (name/version) → B (validateGraph) → B2
  (validateNodeAttributes) → B3 (validateEdgeConditions) → D (INSERT ... ON CONFLICT DO
  NOTHING RETURNING \*)** — each phase gate returns *that phase's own* violations and stops,
  never merges violations across phases (209–263); `getById()` (326–369); `list()`'s dynamic
  SQL-building shape confirming `name` uses `ILIKE '%' || $N || '%'` (substring, not exact —
  422–427) while `status`/`stage` use plain `=` (428–448), `ORDER BY created_at DESC` +
  `after_created` as a **strictly-after** filter combined with that same DESC order (449–468,
  466–468) — ported exactly, not "corrected," per this design's own porting discipline
  (§6.4); `activateImpl()`'s full body (527–728) including the **real, current** ordering —
  SVC-03's hook call happens *inside* the already-open transaction, immediately after the
  `SELECT ... FOR UPDATE` row-lock and only inside the `current_status == .DRAFT` branch
  (585–665), strictly *before* the deprecate-prior-active/activate-target UPDATE pair
  (684–712) — this directly resolves where REQ-030's own hook-injection point must sit (§6.2
  step 6); `deprecate()` (744–813) and `archive()` (829–898)'s identical
  guarded-UPDATE-then-fallback-SELECT shape; `getActiveByName()` (1221–1260).
- `src/design/definition.md` — **the authoritative PD-04 state transition table, read
  directly at lines 558–570** (not reconstructed from a secondary citation, correcting the
  situation REQ-029's design was forced into): the full 4×4 grid confirming exactly 3
  permitted edges (`DRAFT→ACTIVE`, `ACTIVE→DEPRECATED`, `DEPRECATED→ARCHIVED`), 4 diagonal
  "not applicable" self-cells, and **9** `✗ HTTP 409` cells — see §6.1's note reconciling
  this count against REQ-030's acceptance criterion 5's "4 forbidden-transition cells"
  phrasing. Also read: the "Corrections to pre-PD-04 placeholder content" section (506–512,
  confirming the placeholder diagram at 416–441 is superseded and must not be used as
  source), the SQL implementation patterns for `deprecate()`/`archive()` (572–599, ported
  directly into §6.3), PD-03's `Store.activate` doc comment (672–695, the authoritative
  behavior-by-current-status table this design's §6.2 implements), and PD-04's acceptance
  criteria traceability table (639–651), whose two edge-case rows ("ACTIVE → ARCHIVED
  directly", "DRAFT → ARCHIVED") are the two examples REQ-030's acceptance criterion 5
  quotes verbatim.

---

## 1. Scope boundary

**In scope (this requirement):** seven public functions added to the existing
`Letflow.Definitions` context module (§2): `create/2`, `get_by_id/2`, `get_active_by_name/2`,
`list/2`, `activate/2`, `deprecate/2`, `archive/2`. Plus the private conversion helper this
design introduces to resolve `req027-…md` OQ-3 (§5).

**Explicitly NOT in scope, not silently dropped:**

| Not built here | Owned by | Why it's excluded |
|---|---|---|
| `update/1` (R-Co's `Store.update`, PUT/PATCH) | Unassigned — no Letflow requirement currently names it | REQ-030's own function list (`requirements.yaml`) has no `update/1`. `ProcessDefinition.update_changeset/2` already exists (REQ-027) but nothing calls it yet. Flagged in §9 OQ-1 as a real gap, not invented here. |
| `hardDelete/1` (R-Co's `Store.hardDelete`) | Unassigned | Same — not in REQ-030's function list; `req027-…md`'s own OQ-6 already flagged that no requirement owns a delete path. |
| `search/1` (PD-10) | REQ-042 | `requirements.yaml` — REQ-042 reuses this schema as-is, no new index. |
| The SVC-03 service-scope-validation hook's actual logic (walking SERVICE_TASK nodes, checking tenant scope against a service/plugin registry) | REQ-031 | REQ-030 builds only the injection point on `activate/2` (§6.2 step 6, §4.4) — a nil-able opt, never invoked unless supplied, never itself validating anything. |
| Any HTTP/Plug route layer | S4 | Not in scope for any S2 requirement. |
| `Letflow.Definitions.SnapshotStore` | REQ-033 (already `status: done`) | Different table, different module, already shipped — not touched here. |

---

## 2. Module and file layout

**Extends the existing `lib/letflow/definitions.ex` (`Letflow.Definitions`) — does not
create a new module.**

`lib/letflow/definitions.ex` already exists, created by REQ-041 (`compute_pack_update_plan/5`,
`classify_artefact/3`). REQ-027's own cross-module-dependency table (§8) already names
`Letflow.Definitions` as REQ-030's target module by name — this design confirms that
assignment rather than re-deciding it, and the file's prior existence (a REQ-041 deviation
already flagged honestly in that file's own moduledoc) is not a reason to invent a second
module. A new module (e.g. `Letflow.Definitions.Store`) was considered and rejected: this
codebase's established convention is one context module aggregating every operation on a
table family (`Letflow.TenantProvisioning` mixes schema-provisioning and migration-replay;
`Letflow.EventStore` will eventually hold `read/2`/`archive/1` alongside `append/2`), and
REQ-041's two functions are unrelated in *behavior* to REQ-030's CRUD but share the same
*domain* (process definitions) — exactly the aggregation this project's convention expects.

**Required moduledoc edit (ELIXIR-DEV, Step 2a):** the existing moduledoc's "## Scope —
REQ-041 only" section must become a new "## Scope" section listing REQ-041's two functions
**and** REQ-030's seven, so a future reader isn't told the module is REQ-041-only when it no
longer is. §7 gives the exact required text.

No new Ecto schema modules. This design consumes `Letflow.Definitions.ProcessDefinition`
(REQ-027, unchanged) and `Letflow.Definitions.Graph`/`.Node`/`.Edge`/`.Violation`
(REQ-028/029, unchanged — this design adds zero code to `graph.ex`).

| Module | File | Kind |
|---|---|---|
| `Letflow.Definitions` | `lib/letflow/definitions.ex` | **Edited** — 7 new public functions, 1 new private helper (§5), moduledoc extension |

---

## 3. `tenant_id` derivation — mirrors `Letflow.EventStore.append/2` exactly

Per the task's explicit instruction and `docs/migration/decisions/0003-ecto-schema-strategy.md`'s
2026-08-17 addendum: `create/2`'s `attrs` parameter **never accepts a `:tenant_id` (or
`"tenant_id"`) key**. `tenant_id` is derived from `opts[:prefix]` via the already-shipped
`Letflow.TenantProvisioning.tenant_id_for_schema_name/1` (REQ-025), reversing
`schema_name_for_tenant/1`'s encoding. This is the identical mechanism and identical
function call `Letflow.EventStore.append/2` already uses — read directly (`event_store.ex:143–154`)
rather than re-derived, per the task's explicit instruction to "follow the same shape for
consistency across the codebase, don't invent a third pattern."

**Every one of the 7 functions in this design resolves `opts[:prefix]` via
`tenant_id_for_schema_name/1` as its first step**, even the read-only ones that don't need
the resulting `tenant_id` value for a write — this is a uniform contract, not an
inconsistent per-function decision:

- `create/2` uses the derived `tenant_id` to stamp the new row (§4.1).
- `activate/2` uses it only when a `service_scope_validator` hook is supplied, to pass to
  the hook (§4.4, §6.2).
- `get_by_id/2`, `get_active_by_name/2`, `list/2`, `deprecate/2`, `archive/2` discard the
  derived `tenant_id` — they still call `tenant_id_for_schema_name/1` purely for its
  **format-validation** side effect, producing a typed `{:error, :invalid_schema_name}`
  before any DB call rather than letting a malformed `prefix` reach Postgres as an
  `undefined_table`-class raised error (INV-8). This exactly mirrors `EventStore.append/2`'s
  own contract note that it "does not verify the tenant is actually provisioned" — same
  boundary, same limitation, stated once here rather than re-litigated per function.

**AC9 traceability** ("a row written by `create/1` has `tenant_id` equal to the tenant whose
schema the write targeted... not equal to a caller-supplied `tenant_id`... must fail loudly"):
satisfied by rejecting any caller-supplied `tenant_id` key outright (§4.1 step P0,
`{:error, :tenant_id_not_accepted}`) rather than silently stripping/overriding it — the
identical strengthening `req025-event-append.md` §3 already argued for and this design
reuses without re-deriving.

---

## 4. Function signatures

### 4.0 Shared types

```
@type opts :: [prefix: String.t()]

@type status :: Letflow.Definitions.ProcessDefinition.status()
  # :draft | :active | :deprecated | :archived — reused from the shipped schema module,
  # not redefined here.

@type service_scope_validator_fun ::
  (Letflow.Definitions.Graph.t(), tenant_id :: Ecto.UUID.t() -> :ok | {:error, term()})
  # REQ-031's injection point (§4.4, §6.2 step 6). This design specifies only the shape —
  # REQ-031 defines what a real implementation returns inside {:error, term()}.

@type activate_opts :: [
  prefix: String.t(),
  service_scope_validator: service_scope_validator_fun() | nil
]

PROVENANCE (historical, not current decision authority):
@type common_error ::
  {:error, :invalid_schema_name}
  | {:error, {:transaction_failed, term()}}
  # :invalid_schema_name -- opts[:prefix] doesn't match tenant_id_for_schema_name/1's
  #   "tenant_" <> 32-hex shape (every function).
  # {:transaction_failed, term()} -- catch-all for an unexpected raised exception during
  #   a DB call (e.g. a genuine cross-row uq_active_definition race surfacing as a raised
  #   Ecto.ConstraintError from update_all/3, which has no changeset to convert it through
  #   -- see §6.2's note). Ported directly from store.zig's own TransactionFailed
  #   catch-all, which every one of its Store methods falls back to identically
  #   (store.zig:266-269 etc.) -- not a Letflow invention. Every write function (create/2,
  #   activate/2, deprecate/2, archive/2) wraps its DB-touching body in try/rescue,
  #   mirroring TenantProvisioning.replay_migrations/2's identical, already-shipped idiom
  #   (tenant_provisioning.ex:216-231), converting any raised exception into this shape
  #   rather than letting it escape the public boundary (INV-8).
```

### 4.1 `create/2` (PD-01, PD-02, PD-05, PD-06)

```
@type create_attrs :: %{
  required(:name) => String.t(),
  required(:version) => String.t(),
  optional(:description) => String.t() | nil,
  required(:graph) => map(),
    # string-keyed %{"nodes" => [node_map()], "edges" => [edge_map()]} -- see §5.
    # Ecto's :map column type stores whatever this is verbatim; §5's struct conversion
    # is a transient in-memory copy used only to call the three validators, never
    # written back.
  required(:created_by) => Ecto.UUID.t(),
  optional(:stage) => String.t() | nil
}

@type create_error ::
  {:error, :tenant_id_not_accepted}
  | {:error, :initial_status_not_draft}
  | {:error, :name_invalid}
  | {:error, :version_empty}
  | {:error, :graph_structure_invalid}
  | {:error, {:graph_validation_failed, [Letflow.Definitions.Graph.Violation.t()]}}
  | {:error, :duplicate_name_version}
  | {:error, Ecto.Changeset.t()}
  | common_error()

@spec create(attrs :: create_attrs(), opts :: opts()) ::
  {:ok, Letflow.Definitions.ProcessDefinition.t()} | create_error()
```

PROVENANCE (historical, not current decision authority):
Pipeline, in this exact order (phase-gated, mirroring `store.zig:186-316`'s own P-A/B/B2/B3/D
structure — each phase's violations are returned and the pipeline stops; violations across
phases are never merged, matching R-Co exactly):

1. **P0 — reject `:tenant_id`.** `Map.has_key?(attrs, :tenant_id) or Map.has_key?(attrs,
   "tenant_id")` → `{:error, :tenant_id_not_accepted}`. Identical shape to
   `EventStore.append/2`'s `reject_tenant_id/1` (§3).
2. **P1 — reject `:status`.** `Map.has_key?(attrs, :status) or Map.has_key?(attrs,
   "status")` → `{:error, :initial_status_not_draft}`. **Resolves `req027-…md` OQ-5b**:
   `create_changeset/2` does not cast `:status` at all, so a caller-supplied value would
   otherwise be silently dropped rather than rejected — R-Co's `InitialStatusNotDraft`
   (`definition.md:400`) is ported here, at the params boundary, since the changeset
   structurally cannot produce it.
3. **P2 — resolve `tenant_id`.** `TenantProvisioning.tenant_id_for_schema_name(opts[:prefix])`
   → `{:error, :invalid_schema_name}` on failure.
PROVENANCE (historical, not current decision authority):
4. **P3 — name.** `attrs[:name]` (or `attrs["name"]`) must be a `String.t()`,
   `byte_size > 0`, `byte_size <= 255` → else `{:error, :name_invalid}`. Ported from
   `store.zig:198` (`params.name.len == 0 or params.name.len > 255`). This duplicates
   `create_changeset/2`'s own `validate_length(:name, min: 1, max: 255)` — deliberately: a
   pre-changeset check produces the specific typed atom PD-01 names (`NameInvalid`) rather
   than a generic `%Ecto.Changeset{}`, and running it before phase P5's (expensive, in
   Elixir terms) graph conversion matches R-Co's own "cheapest checks first" ordering.
PROVENANCE (historical, not current decision authority):
5. **P4 — version.** `attrs[:version]` must be a `String.t()`, `byte_size > 0` → else
   `{:error, :version_empty}`. Ported from `store.zig:201`. (No upper-bound check is named
   by R-Co's own error taxonomy here — `varchar(255)` still enforces one at the DB layer via
   `create_changeset/2`'s `validate_length(:version, max: 255)`, surfacing as
   `{:error, Ecto.Changeset.t()}` in the rare case a caller supplies a 256+ char version;
   not duplicated as its own typed atom since R-Co's own `VersionEmpty` variant covers only
   emptiness, `definition.md:190-191`.)
6. **P5 — graph presence/shape.** `attrs[:graph]` (or `attrs["graph"]`) must be present and
   a plain map (not `nil`, not a list, not a string) → else `{:error, :graph_structure_invalid}`.
PROVENANCE (historical, not current decision authority):
7. **P6 — graph struct conversion.** `graph_struct_from_map(graph_map)` (§5) →
   `{:ok, Letflow.Definitions.Graph.t()} | :error`. On `:error` → `{:error, :graph_structure_invalid}`.
   Ports `store.zig`'s implicit `GraphStructureInvalid` (`definition.md:49-50`, "graph is not
   a JSON object with a `nodes` array and an `edges` array").
8. **P7 — `Graph.validate_graph/1`.** If `result.valid == false` → `{:error,
   {:graph_validation_failed, result.violations}}`. **Zero DB calls have happened by this
   point** — satisfies AC1's "writes zero rows" literally, not just in effect.
9. **P8 — `Graph.validate_node_attributes/1`.** Same gate shape. **This step is new relative
   to REQ-030's own `requirements.yaml` description text**, which names only
   `validate_node_attributes()` — see §0's citation of `req029-…md` §1/§9.3: REQ-029 shipped
   *two* new functions, and REQ-030's pipeline must call both. Recorded here so this gap
   doesn't silently persist into implementation.
10. **P9 — `Graph.validate_edge_conditions/1`.** Same gate shape, closing the same gap for
    PD-06.
11. **P10 — build the changeset.** `attrs` merged with `tenant_id: tenant_id` (from P2) →
    `ProcessDefinition.create_changeset(%ProcessDefinition{}, merged_attrs)`. **The original,
    unmodified `attrs[:graph]` map is what gets cast here** — the P6 struct is never fed
    back in; it existed only to drive P7-P9's pure calls.
12. **P11 — insert.** `Repo.insert(changeset, on_conflict: :nothing, conflict_target:
    [:name, :version], returning: true, prefix: schema_name)`. **`conflict_target:
    [:name, :version]` is the targeted form `req027-…md` §10 C-5 requires** — it matches
    `uq_definition_version`'s exact column list, so Postgres infers that index as the ON
    CONFLICT arbiter (no `{:constraint, name}` tuple needed; a targeted list of columns is
    sufficient and is the simpler, standard mechanism). **This is the only unique index
    `create/2`'s insert can ever violate**: `uq_active_definition`'s predicate is `WHERE
    status = 'active'`, and every row this function inserts has `status = :draft` (the
    column default, never cast — P1/step 10 guarantee this), so a freshly-inserted DRAFT row
    is categorically excluded from that partial index's predicate and can never trigger it.
    On `{:error, %Ecto.Changeset{}}` (a non-uniqueness failure, e.g. a missing `created_by`)
    → `{:error, changeset}` unchanged.
13. **P12 — disambiguate real-insert vs. suppressed-conflict.** Because `id` is a
    client-generated `binary_id` (`autogenerate: true`), `Repo.insert/2` with `on_conflict:
    :nothing` **always** returns `{:ok, %ProcessDefinition{}}` regardless of whether the row
    actually landed — this is the exact, already-shipped idiom confirmed directly in
    `TenantProvisioning.insert_or_fetch_registration/2` (`tenant_provisioning.ex:352-375`)
    and `EventStore.claim_idempotency/3` (`event_store.ex:388-415`), reused here without
    re-deriving it a third time. `Repo.get(ProcessDefinition, inserted.id, prefix:
    schema_name)`: found → `{:ok, found}`; `nil` → `{:error, :duplicate_name_version}`.
    **Neither caller in a race is told which one "won"** — both concurrent calls run this
    identical P11/P12 sequence independently; the loser's P12 lookup returns `nil` and both
    receive the same `{:error, :duplicate_name_version}` shape, satisfying `definition.md`
    Key invariant 6 and REQ-030 AC2.

**AC1 traceability:** P7/P8/P9 (whichever fails first) return `{:error,
{:graph_validation_failed, violations}}` — a specific, typed, non-generic result — before
P10/P11/P12 (the only steps that touch `Repo`) ever run.

**AC2 traceability:** P11's targeted `ON CONFLICT (name, version) DO NOTHING` plus P12's
re-select. Demonstrating this with an *actual* concurrent test (two processes/tasks calling
`create/2` with identical `name`/`version` against the same schema) is preferred; if
concurrency genuinely can't be exercised in TEST-DESIGNER's environment, citing this exact
P11/P12 code path (both the targeted conflict clause and the disambiguation re-select) is
the acceptance criterion's own named fallback.

### 4.2 `get_by_id/2`

```
@spec get_by_id(id :: Ecto.UUID.t(), opts :: opts()) ::
  {:ok, Letflow.Definitions.ProcessDefinition.t()}
  | {:error, :not_found}
  | common_error()
```

1. Resolve `opts[:prefix]` (§3) → `{:error, :invalid_schema_name}` on failure.
2. `Ecto.UUID.cast(id)` → on `:error` (malformed UUID string), `{:error, :not_found}`
   directly rather than letting a cast failure reach `Repo.get/3` as a raised
   `Ecto.Query.CastError` (INV-8; R-Co's `Uuid` is a fixed-width binary type with no
   equivalent malformed-string case, so this is a genuine Elixir-side addition, not a port).
PROVENANCE (historical, not current decision authority):
3. `Repo.get(ProcessDefinition, id, prefix: schema_name)` → `nil` → `{:error, :not_found}`;
   struct → `{:ok, struct}`. Ports `store.zig:358` (`rows.rows.len == 0 →
   DefinitionNotFound`).

### 4.3 `get_active_by_name/2` (PD-07)

```
@spec get_active_by_name(name :: String.t(), opts :: opts()) ::
  {:ok, Letflow.Definitions.ProcessDefinition.t()}
  | {:error, :not_found}
  | common_error()
```

1. Resolve `opts[:prefix]` (§3).
PROVENANCE (historical, not current decision authority):
2. Query: `ProcessDefinition |> where([d], d.name == ^name and d.status == :active) |>
   Repo.all(prefix: schema_name)`. **Exact match on `name`, exact match on `status ==
   :active`** — no `ILIKE`, distinct from `list/2`'s `name` filter (§4.4.5's citation
   explains why `list/2` uses substring matching and this function does not: R-Co's own
   `getActiveByName` uses a plain `=` (`store.zig:1240: WHERE name = $1 AND status =
   'ACTIVE'`), not the `ILIKE` `list()` uses at `store.zig:422`).
3. `Repo.all/2` (not `Repo.one/2` or `Repo.get_by/2`) **deliberately**, so a
   theoretically-impossible-but-defensive multi-row result doesn't raise
   `Ecto.MultipleResultsError`. `[]` → `{:error, :not_found}`. `[row | _rest]` → `{:ok,
   row}`, taking the **first** row and silently ignoring any others. This ports
   `definition.md:1432-1433`'s own stated defensive behavior verbatim ("if the DB somehow
   ever returned more than one row, return the first row... since the index already makes
   that case structurally impossible in practice") — `uq_active_definition` (REQ-027)
   guarantees at most one row exists, so this branch is unreachable in correct operation,
   present only as the documented defensive fallback R-Co itself specifies.

**AC7 traceability:** the `status == :active` predicate is exact and non-optional — a name
with only DRAFT/DEPRECATED/ARCHIVED rows never matches step 2's query at all (no row has
`status == :active`), so it falls straight to `{:error, :not_found}`, never "the most recent
non-active row" (there is no `ORDER BY`/fallback query for that case at all — the function
has exactly one query, not two).

### 4.4 `list/2` (PD-07's `?stage=` filter)

PROVENANCE (historical, not current decision authority):
```
@type list_filters :: %{
  optional(:name) => String.t() | nil,
    # ILIKE '%<name>%' substring match (store.zig:415-427); nil or key absent = no filter.
  optional(:status) => status() | nil,
    # exact match; nil or key absent = no filter.
  optional(:stage) => String.t() | nil,
    # exact match against the nullable `stage` column; nil or key absent = no filter.
    # A caller who wants "stage IS NULL" specifically is not served by this filter shape --
    # not needed by any acceptance criterion, and not a case R-Co's own ListOpts.stage
    # (a plain ?[]const u8) distinguishes either.
  optional(:after_created) => DateTime.t() | nil,
    # created_at > this value (strictly-after -- §4.4 below); nil or key absent = no filter.
  optional(:limit) => pos_integer() | nil
    # nil, absent, or 0 -> 50 (default). Values above 200 clamp to 200. store.zig:396.
}

@spec list(filters :: list_filters(), opts :: opts()) ::
  {:ok, [Letflow.Definitions.ProcessDefinition.t()]} | common_error()
```

PROVENANCE (historical, not current decision authority):
Always `{:ok, list}` — an empty list on no matches, never an error (ports
`store.zig:485`'s `rowsToDefinitions` over a possibly-empty row set; REQ-030's own
description states this explicitly).

Query composition (pseudocode — the actual `Ecto.Query` composition is ELIXIR-DEV's Step 2a
job):

1. Resolve `opts[:prefix]` (§3).
PROVENANCE (historical, not current decision authority):
2. `effective_limit = clamp(filters[:limit] || 50, min: 1, max: 200)` — a `nil`/absent/`0`
   input maps to `50`; anything `> 200` clamps to `200`. Ports `store.zig:396`'s
   `if opts.limit == 0 then 50 elseif opts.limit > 200 then 200 else opts.limit`.
3. Start from `ProcessDefinition` base query, `prefix: schema_name`.
4. If `filters[:name]` is a non-nil string: `pattern = "%" <> filters[:name] <> "%"`, add
   `where(fragment("? ILIKE ?", d.name, ^pattern))`. **The `^pattern` binds as a query
   parameter — `filters[:name]`'s content is never spliced into the fragment's SQL text
   itself**, satisfying INV-7 even though `fragment/1` is in use (the fragment's *shape* is a
   constant string, only the *value* is a bind parameter — the same distinction
   `tenant_provisioning.ex`'s one `fragment/1` use already documents for a different reason).
5. If `filters[:status]` is non-nil: add `where([d], d.status == ^filters.status)`.
PROVENANCE (historical, not current decision authority):
6. If `filters[:stage]` is non-nil: add `where([d], d.stage == ^filters.stage)`. **Exact
   match, no `ILIKE`** — ports `store.zig:439-448`'s plain `stage = $N`, distinct from the
   `name` filter's substring behavior. **AC8 turns on this predicate being exact**: a
   `stage` filter value of `"prod"` must not also match a row whose stage is `"production"`.
7. If `filters[:after_created]` is non-nil: add `where([d], d.created_at > ^filters.after_created)`.
PROVENANCE (historical, not current decision authority):
8. All added `where/2` clauses combine with `AND` (Ecto composes successive `where/2` calls
   conjunctively by default) — this is what makes the three filters "combinable... in the
   same call" (AC8): each is an independent, optional `AND`-joined predicate, so passing
   `name`, `status`, and `stage` together narrows by the intersection of all three, exactly
   as `store.zig:415-464`'s own sequential `if opts.X` clause-appending does.
9. `order_by([d], desc: d.created_at)`, `limit(^effective_limit)`.
10. `Repo.all(query, prefix: schema_name)`.

**`after_created`'s known skip-risk, ported as-is, not fixed here:** `created_at` is not
unique. Combined with `ORDER BY created_at DESC` and a **strictly-after** filter (not
"strictly-before"), this design ports `definition.md:1450-1451`'s documented cursor
semantics literally rather than reinterpreting them — `req027-…md` OQ-4 already named this
as a REQ-030 API decision, not a schema one, and flagged that the DESC-order-plus-after
combination is what R-Co itself specifies, unusual as it may read for a conventional
"next page of older rows" cursor. **This design's own resolution of OQ-4's "cursor
encoding" question: there is no opaque encoding at all.** `after_created` is a plain,
caller-visible `DateTime.t()` (the literal `created_at` value of a previously-seen row, not
a base64/JSON-wrapped token) — matching R-Co's own `ListOpts.after_created: ?i64` (a raw
epoch-microsecond integer, fully exposed to the caller, never obfuscated). Introducing an
opaque cursor format would be new API surface no acceptance criterion asks for. The
composite-cursor fix `req027-…md` OQ-4 names (`(created_at, id)` row-value comparison) is
not built here — restated as this design's own §9 OQ-2, not silently dropped.

### 4.5 `activate/2` (PD-03; SVC-03 injection point)

```
@spec activate(id :: Ecto.UUID.t(), opts :: activate_opts()) ::
  {:ok, %{definition: Letflow.Definitions.ProcessDefinition.t(), already_active: boolean()}}
  | {:error, :not_found}
  | {:error, :not_draft}
  | {:error, :graph_structure_invalid}
  | {:error, {:service_scope_violation, reason :: term()}}
  | common_error()
```

**Return shape note:** a `%{definition: ..., already_active: boolean()}` map, not a
differently-tagged tuple per outcome — mirrors `EventStore.append/2`'s own established
`is_duplicate: boolean()` flag-on-a-map idiom (`event_store.ex:118-123`) for the identical
"success either way, but the caller may want to distinguish fresh-vs-idempotent" shape,
reused here for project-wide consistency rather than inventing a `{:ok, :already_active,
_}` / `{:ok, :activated, _}` two-tag scheme.

**`opts[:service_scope_validator]`** — the SVC-03 integration point (AC6). A 2-arity
function (`(Graph.t(), tenant_id) -> :ok | {:error, term()}`) or `nil` (default). REQ-030
builds only the parameter and the call site (§6.2 step 6) — never the function's own logic.
This is REQ-031's job, per the task's explicit instruction. The moduledoc text in §7 states
this plainly, satisfying AC6's "documented explicitly in the moduledoc" requirement.

Full transition-and-locking algorithm: §6.2.

**AC3 traceability:** the deprecate-prior-active step and the activate-target step both run
inside one `Repo.transaction/1` call, deprecate-before-activate (§6.2 steps 7-8), so a
`get_by_id/2` read against either the old or the new row after `activate/2` returns always
observes both post-transition statuses together (Postgres transaction atomicity) — never a
window where both are `:active` or the old one is still `:active` after the new one already
is.

**AC4 traceability:** the `%{status: :active}` branch (§6.2 step 4) performs zero writes and
returns `{:ok, %{definition: current_row, already_active: true}}` — never an error — on
every call, not just the first repeat.

**AC6 traceability:** the `activate_opts()` type (§4.0) and this section's signature.

### 4.6 `deprecate/2` (PD-04)

```
@spec deprecate(id :: Ecto.UUID.t(), opts :: opts()) ::
  {:ok, Letflow.Definitions.ProcessDefinition.t()}
  | {:error, :not_found}
  | {:error, :invalid_status_transition}
  | common_error()
```

Only permitted edge: `ACTIVE → DEPRECATED`. Algorithm: §6.3.

### 4.7 `archive/2` (PD-04)

```
@spec archive(id :: Ecto.UUID.t(), opts :: opts()) ::
  {:ok, Letflow.Definitions.ProcessDefinition.t()}
  | {:error, :not_found}
  | {:error, :invalid_status_transition}
  | common_error()
```

Only permitted edge: `DEPRECATED → ARCHIVED`. Sets `archived_at` (in addition to `status`
and `updated_at`). Algorithm: §6.3 (identical shape to `deprecate/2`, different
from-status/to-status pair and one extra field).

---

## 5. Graph map ↔ struct conversion — resolving `req027-…md` OQ-3

**Owner decision (this design, per REQ-027's own explicit assignment — `req027-…md` §8's
cross-module-dependency table: "REQ-030 owns the map↔struct conversion at the boundary").**
A new private function in `Letflow.Definitions`, **not** added to `graph.ex` (which stays
exactly as REQ-028/029 shipped it — no code added to that file by this design) and **not** a
custom `Ecto.Type` on `ProcessDefinition.graph` (`req027-…md` OQ-3 explicitly rejected that
option for REQ-027's own scope; introducing it now would still bind every future
`graph`-touching call site to a conversion contract this design would rather keep visible
and local to the one context module that needs it).

```
@spec graph_struct_from_map(graph_map :: map()) ::
  {:ok, Letflow.Definitions.Graph.t()} | :error
```

**Private** (`defp`) — used internally by both `create/2` (§4.1 step P6) and `activate/2`
(§6.2 step 6, only when a `service_scope_validator` hook is supplied — otherwise never
called at all, avoiding the conversion cost on the common no-hook path).

Algorithm, precisely:

1. `nodes_raw = Map.get(graph_map, "nodes")`, `edges_raw = Map.get(graph_map, "edges")`. If
   either is not a `list()` → return `:error`.
2. For each element of `nodes_raw`: must be a `map()`; `Map.get(node, "id")` must be
   `is_binary/1`; `Map.get(node, "node_type")` must be `is_binary/1`. If any of these three
   checks fails for any node → return `:error` for the **whole** conversion (not a
   per-node partial result — a structurally malformed graph is rejected outright, matching
   `GraphStructureInvalid`'s all-or-nothing shape, distinct from `validate_graph/1`'s
   later collect-every-violation behavior which only applies to a graph that already passed
   *this* structural gate).
3. `node_type` string → atom mapping, via a **fixed 7-entry literal map** — never
   `String.to_atom/1` or `String.to_existing_atom/1` on the raw string:

   ```
   %{
     "START" => :START, "END" => :END, "HUMAN_TASK" => :HUMAN_TASK,
     "SERVICE_TASK" => :SERVICE_TASK, "EXCLUSIVE_GATEWAY" => :EXCLUSIVE_GATEWAY,
     "PARALLEL_GATEWAY" => :PARALLEL_GATEWAY, "TIMER" => :TIMER
   }
   ```

   A string not present as a key maps to the sentinel atom `:unknown_node_type` — a single,
   fixed atom introduced once by this module's own source code (not by
   `String.to_atom/1` on external input), so no amount of distinct unrecognized-string input
   across any number of calls grows the atom table. **This is the same atom-table-exhaustion
   hazard REQ-029 §2 already identified for `Node.attributes`' keys, one level up (on
   `node_type` values instead of attribute keys) — this design closes the identical gap the
   identical way**, rather than reusing `String.to_atom/1` and reintroducing it.
   `:unknown_node_type` is confirmed safe against every one of `graph.ex`'s 17 checks (§0's
   citation) — none of them crashes or misbehaves on a `node_type` outside the closed
   7-atom union; they simply don't match it, identical to the already-documented
   "node whose node_type is not one of the 7 known atoms" gap `req029-…md` §9.2 inherits
   from `req028-…md` §9.2. This design does not resolve that inherited gap either — it only
   guarantees converting into it is memory-safe.
4. Build `%Letflow.Definitions.Graph.Node{id: node["id"], node_type: mapped_atom, label:
   Map.get(node, "label"), attributes: Map.get(node, "attributes")}` for each node.
   `label`/`attributes` pass through **verbatim, unvalidated** at this layer — `label`'s
   `String.t() | nil` typing and `attributes`' `map() | nil` contract (with its own
   string-keyed-map requirement, REQ-029 §2) are enforced by `validate_node_attributes/1`'s
   own checks (CHK-09..12), which are already total/defensive against a malformed
   `attributes` value (`graph.ex`'s `blank_or_missing_string?/2`/`invalid_timeout?/1`/
   `invalid_duration?/1` all have a catch-all non-map clause treating it as "missing" rather
   than crashing) — duplicating that defensiveness here would be redundant, not safer.
5. For each element of `edges_raw`: must be a `map()`; `Map.get(edge, "id")`,
   `Map.get(edge, "source")`, `Map.get(edge, "target")` must each be `is_binary/1`. Any
   failure → return `:error` for the whole conversion (same all-or-nothing rule as step 2).
6. Build `%Letflow.Definitions.Graph.Edge{id: edge["id"], source: edge["source"], target:
   edge["target"], condition: Map.get(edge, "condition"), is_default: Map.get(edge,
   "is_default", false)}` for each edge. `condition`/`is_default` pass through verbatim
   (same reasoning as step 4 — `validate_edge_conditions/1`'s checks are already defensive:
   `blank_condition?/1` has a catch-all treating a non-string `condition` as blank;
   `is_default`'s strict `== true`/`!= true` comparisons never crash on a non-boolean, they
   just don't match).
7. Return `{:ok, %Letflow.Definitions.Graph{nodes: built_nodes, edges: built_edges}}`.

**Total function, never raises.** Every branch above is an explicit type/shape check with an
explicit `:error` return, never a bare pattern match against untrusted input (INV-8).

---

## 6. State-machine enforcement (PD-03, PD-04)

### 6.1 The authoritative transition table, and reconciling AC5's "4" against the real table

`definition.md:558-570`'s authoritative table (read directly, §0):

| From ＼ To | DRAFT | ACTIVE | DEPRECATED | ARCHIVED |
|---|---|---|---|---|
| **DRAFT** | — | `activate/2` ✓ | ✗ | ✗ |
| **ACTIVE** | ✗ | — | `deprecate/2` ✓ | ✗ |
| **DEPRECATED** | ✗ | ✗ | — | `archive/2` ✓ |
| **ARCHIVED** | ✗ | ✗ | ✗ | — (terminal) |

3 permitted edges, 4 diagonal "not applicable" self-cells (`ACTIVE→ACTIVE` is handled
separately by `activate/2`'s own idempotent no-op branch, §4.5/§6.2 step 4 — it is not a
"transition" in this table's sense, matching R-Co's own framing of it as a distinct
`AlreadyActive` case rather than a table cell), and **9** `✗` cells.

**AC5 says "4 forbidden-transition cells."** This design's own count from the primary
source is 9 (every off-diagonal `✗` cell, reachable across all three functions:
`activate/2` rejects 2 — `DEPRECATED→ACTIVE`, `ARCHIVED→ACTIVE` — as `:not_draft`;
`deprecate/2` rejects 3 — `DRAFT→DEPRECATED`, `DEPRECATED→DEPRECATED`,
`ARCHIVED→DEPRECATED` — as `:invalid_status_transition`; `archive/2` rejects 4 —
`DRAFT→ARCHIVED`, `ACTIVE→ARCHIVED`, `ARCHIVED→ARCHIVED`, and (double-counted with
`deprecate/2`'s reach in a literal function-by-function tally, since neither function alone
reaches all 9) — the arithmetic doesn't cleanly reduce to "4" under any grouping this
design could construct that also matches AC5's own two named examples (`ACTIVE→ARCHIVED`,
`DRAFT→ARCHIVED`). The closest reconciliation: excluding self-transitions (arguably not
"transitions" at all) and excluding the two `→ACTIVE` rejections `activate/2` already
covers (arguably validated by AC3/AC4's own DRAFT/ACTIVE-focused scenarios rather than
needing separate naming here) leaves exactly 4: `DRAFT→DEPRECATED`, `ARCHIVED→DEPRECATED`,
`DRAFT→ARCHIVED`, `ACTIVE→ARCHIVED` — the last two being AC5's own two named examples,
which is suggestive but not stated in `requirements.yaml` itself. **Not silently resolved
either way**: this design's own enforcement mechanism (§6.2/§6.3's guarded `WHERE`
predicates) rejects the complete, correct set of 9 forbidden cells regardless of which
count TEST-DESIGNER's coverage ends up targeting — the ambiguity is in how many *test
cases* AC5 anticipates, not in what the *design* must enforce, so it does not block this
design from being unambiguous. Flagged here explicitly (§9 OQ-1) so TEST-DESIGNER doesn't
independently guess at the same reconciliation without knowing it's already been
attempted.

### 6.2 `activate/2` — full algorithm (PD-03)

Wrapped in one `try/rescue` (converting any unexpected raised exception to
`{:error, {:transaction_failed, exception}}`, §4.0) around one `Repo.transaction/1` call:

1. Resolve `opts[:prefix]` → `tenant_id` (§3). `{:error, :invalid_schema_name}` short-circuits
   before the transaction opens.
2. Inside `Repo.transaction(fn -> ... end)`: lock the target row —
   `ProcessDefinition |> where([d], d.id == ^id) |> lock("FOR UPDATE") |> Repo.one(prefix:
   schema_name)`. This is the exact `lock/2` idiom `EventStore.assign_sequence/3` already
   uses (§0) — no hand-written `SELECT ... FOR UPDATE` string.
3. `nil` → `Repo.rollback(:not_found)`.
4. `%{status: :active} = definition` → return `{:already_active, definition}` from the
   transaction function (no `Repo.rollback/1` — nothing was written, so committing this
   read-only transaction is harmless; ends the branch here, skipping every step below).
5. `%{status: status}` where `status in [:deprecated, :archived]` →
   `Repo.rollback(:not_draft)`.
PROVENANCE (historical, not current decision authority):
6. `%{status: :draft} = definition` — **the only branch that proceeds to a real
   activation.** If `opts[:service_scope_validator]` is non-`nil`: call
   `graph_struct_from_map(definition.graph)` (§5) — `:error` → `Repo.rollback(:graph_structure_invalid)`
   (defensive only: `create/2` already validated this exact `graph` value before it was ever
   stored, and no `update/1` exists in scope to have since corrupted it — see §1's scope
   table — so this branch is unreachable in correct operation, present only so a future
   `update/1` or a hand-edited row can't crash this function). `{:ok, graph_struct}` →
   call `opts[:service_scope_validator].(graph_struct, tenant_id)`. `{:error, reason}` →
   `Repo.rollback({:service_scope_violation, reason})`. `:ok` (or `opts[:service_scope_validator]`
   was `nil`, hook skipped entirely) → continue to step 7. **This ordering — hook call
   strictly before any UPDATE — matches `store.zig:585-665`'s real, current structure
   exactly** (the SVC-03 check runs inside the already-open transaction, inside the
   `current_status == .DRAFT` branch, before the deprecate/activate UPDATE pair at
   `store.zig:684-712`) — not the "before the transaction opens" phrasing REQ-031's own
   future requirement text uses, which this design reads as referring to the two UPDATE
   statements themselves rather than the outer `BEGIN`/`Repo.transaction/1` boundary (flagged
   as this design's own interpretation in §9 OQ-3, for REQ-031's own CODE-DESIGNER to
   confirm or correct once that requirement is designed).
7. **Step 3 (must precede step 8 — ordering is load-bearing, `definition.md`'s "Ordering
   rationale," `req027-…md` §description already restates this):** deprecate any existing
   ACTIVE row sharing this `name` —
   ```
   ProcessDefinition
   |> where([d], d.name == ^definition.name and d.status == :active)
   |> select([d], d)
   |> Repo.update_all([set: [status: :deprecated, updated_at: now]], prefix: schema_name)
   ```
   (`select([d], d)` is required to get any result back at all from `update_all/3` on this
   Ecto version — §0's citation. The result isn't used here; only the write matters.)
8. **Step 4:** activate the target —
   ```
   {1, [updated]} =
     ProcessDefinition
     |> where([d], d.id == ^id and d.status == :draft)
     |> select([d], d)
     |> Repo.update_all([set: [status: :active, updated_at: now]], prefix: schema_name)
   ```
   The `{1, [updated]}` match is safe (not defensive-only) because the row is still held
   under the step-2 `FOR UPDATE` lock and was just confirmed `:draft` in this same
   transaction — no concurrent writer can have changed it between step 2's read and this
   UPDATE. Return `{:activated, updated}` from the transaction function.
9. Outside the transaction: `{:ok, {:already_active, definition}} → {:ok, %{definition:
   definition, already_active: true}}`; `{:ok, {:activated, definition}} → {:ok,
   %{definition: definition, already_active: false}}`; `{:error, :not_found} → {:error,
   :not_found}`; `{:error, :not_draft} → {:error, :not_draft}`; `{:error,
   :graph_structure_invalid} → {:error, :graph_structure_invalid}`; `{:error,
   {:service_scope_violation, reason}} → {:error, {:service_scope_violation, reason}}`.

PROVENANCE (historical, not current decision authority):
**A genuine cross-row race is not specially handled, matching R-Co exactly.** Two
*different* DRAFT rows sharing the same `name`, activated concurrently, each acquire their
own row's `FOR UPDATE` lock (different `id`s never block each other) and could both reach
step 8's UPDATE — Postgres's `uq_active_definition` partial unique index is the actual
final arbiter, raising a constraint-violation exception on whichever transaction commits
second. This raised exception is not converted through a changeset (`update_all/3` has none
to convert through) — it is caught by this function's outer `try/rescue` (§4.0) and surfaces
as `{:error, {:transaction_failed, exception}}`. This is not a gap this design leaves
unhandled: it is the same fallback R-Co's own `activateImpl` uses for the identical race
(every DB call in that function is wrapped in `catch return DefinitionError.TransactionFailed`,
`store.zig:698-708`) — R-Co has no more specific error variant for this case either, so
none is invented here.

### 6.3 `deprecate/2` / `archive/2` — full algorithm (PD-04)

Identical shape for both, differing only in the `WHERE`/`SET` clause values. Shown once for
`deprecate/2`; `archive/2` substitutes `status: :active` → `status: :deprecated` in the
`WHERE`, `status: :deprecated` → `status: :archived` in the `SET`, and adds `archived_at:
now` to the `SET`.

Wrapped in the same `try/rescue` → `{:error, {:transaction_failed, exception}}` boundary as
§6.2.

1. Resolve `opts[:prefix]` (§3).
2. `now = DateTime.utc_now() |> DateTime.truncate(:microsecond)`.
PROVENANCE (historical, not current decision authority):
3. Inside `Repo.transaction(fn -> ... end)` (matching `store.zig:761-802`'s explicit
   `BEGIN`/`COMMIT` wrapping, even though a single `UPDATE` is already atomic on its own —
   kept for source fidelity and because the fallback `SELECT` in step 5 benefits from
   running in the same session/transaction as the UPDATE, not for any correctness reason
   this specific two-statement sequence strictly requires):
   ```
   {count, rows} =
     ProcessDefinition
     |> where([d], d.id == ^id and d.status == :active)
     |> select([d], d)
     |> Repo.update_all([set: [status: :deprecated, updated_at: now]], prefix: schema_name)
   ```
4. `count == 1` → return `hd(rows)` from the transaction function.
PROVENANCE (historical, not current decision authority):
5. `count == 0` → fallback lookup to disambiguate not-found from wrong-status, exactly
   mirroring `store.zig:785-798`: `Repo.get(ProcessDefinition, id, prefix: schema_name)`.
   `nil` → `Repo.rollback(:not_found)`. Non-`nil` (the row exists but its `status` wasn't
   `:active`) → `Repo.rollback(:invalid_status_transition)`.
6. Outside the transaction: unwrap `{:ok, definition} → {:ok, definition}`, `{:error,
   :not_found} → {:error, :not_found}`, `{:error, :invalid_status_transition} → {:error,
   :invalid_status_transition}`.

**AC5 traceability (the mechanism, independent of the exact test count — §6.1):** every one
of the 9 forbidden cells is rejected because the guarded `WHERE status = <expected>` clause
in `deprecate/2`/`archive/2`, or the `case` branch structure in `activate/2`, matches
**only** the one legal from-status per function — every other current status necessarily
falls into a rejection branch. There is no code path in any of the three functions that can
write a `status` value without that exact-match guard, so "every other transition" is
rejected by construction, not by enumerating cases defensively.

### 6.4 `deprecate/2`/`archive/2` intentionally do not accept a `service_scope_validator`

Only `activate/2` gains the SVC-03 hook parameter (AC6 names `activate/1` specifically,
and `definition.md`'s SVC-03 section — read via `req031`'s own requirement text, §0 — scopes
the check to activation only: service/plugin scope only matters when a definition is about
to become usable for new instances, not when it's being retired). `deprecate/2`/`archive/2`
keep the plain `opts()` type (§4.0), not `activate_opts()`.

---

## 7. Required moduledoc text

Per AC6 ("documented explicitly in the moduledoc as the SVC-03 integration point") and this
design's own §2 requirement to extend, not silently overwrite, the existing scope note.
ELIXIR-DEV may add surrounding prose but must not omit these sentences (CODE-DESIGN-VALIDATOR
and REVIEWER can check them literally).

```
## Scope

`compute_pack_update_plan/5` and `classify_artefact/3` (REQ-041) and `create/2`,
`get_by_id/2`, `get_active_by_name/2`, `list/2`, `activate/2`, `deprecate/2`, `archive/2`
(REQ-030) together make up this module's current public API.

## `tenant_id` is always derived, never accepted (REQ-030)

`create/2`'s `attrs` never accepts a `:tenant_id` (or `"tenant_id"`) key -- a caller
supplying one gets `{:error, :tenant_id_not_accepted}`, not a silently-overridden value.
`tenant_id` is always derived from `opts[:prefix]` via
`Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, mirroring
`Letflow.EventStore.append/2`'s identical contract (see
`lib/letflow/design/req025-event-append.md` and
`docs/migration/decisions/0003-ecto-schema-strategy.md`'s 2026-08-17 addendum).

## `activate/2`'s `service_scope_validator` option -- the SVC-03 integration point (REQ-031)

`activate/2` accepts an optional `:service_scope_validator` key in its `opts`, a 2-arity
function `(Letflow.Definitions.Graph.t(), tenant_id) -> :ok | {:error, term()}` or `nil`
(the default). When present, it is called once, only when the target definition's current
status is `:draft` (never on the already-active no-op path, never on a rejected
non-draft transition), after the row lock is acquired and before either of the two
transition UPDATEs run. A `{:error, reason}` return aborts the whole activation with
`{:error, {:service_scope_violation, reason}}` and writes nothing. **This module builds
only the injection point** -- the hook's own logic (walking SERVICE_TASK nodes, checking
tenant/service/plugin scope) is REQ-031's job, not implemented here.
```

---

## 8. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-DS-1 | `create/2` never writes a row whose `tenant_id` disagrees with the schema (`opts[:prefix]`) it was written into. | §4.1 P0 (reject caller-supplied `tenant_id`) + P2 (derive from prefix) |
| INV-DS-2 | Every one of the 7 functions validates `opts[:prefix]`'s format before any `Repo` call. | §3; every function's step 1 |
| INV-DS-3 | `create/2` attempts zero DB writes if any of the three graph validators (`validate_graph/1`, `validate_node_attributes/1`, `validate_edge_conditions/1`) fails. | §4.1 P7-P9, all strictly before P10/P11 |
| INV-DS-4 | `status` transitions only ever move along the 3 permitted edges; every other current-status/target-action combination is rejected, by construction of the guarded `WHERE`/`case` branches, not by enumeration. | §6.1, §6.2, §6.3 |
| INV-DS-5 | `activate/2`'s deprecate-prior-active step always completes, in the same transaction, before the activate-target step. | §6.2 steps 7-8, citing `definition.md`'s ordering rationale |
| INV-DS-6 | `activate/2` called on an already-`:active` definition never errors and never writes. | §6.2 step 4 |
| INV-DS-7 | `graph_struct_from_map/1` never creates a new atom from caller-controlled input. | §5 step 3 |
| INV-DS-8 | No raw-SQL string interpolation of tenant/user-controlled values anywhere in this module — every `fragment/1` use binds the value as `^value`, never splices it into the fragment text. | §4.4 step 4 |
| INV-DS-9 | Every write function (`create/2`, `activate/2`, `deprecate/2`, `archive/2`) converts an unexpected raised exception into `{:error, {:transaction_failed, exception}}` rather than letting it escape. | §4.0, §6.2, §6.3 |

---

## 9. Open questions — not silently resolved

**OQ-1 (INFORMATIONAL, for TEST-DESIGNER):** §6.1 already states this design's own
reconciliation attempt between AC5's "4 forbidden-transition cells" phrasing and the
authoritative table's actual 9 `✗` cells. Not re-litigated here — see §6.1 for the full
reasoning and the candidate 4-cell subset. This does not block the design (§6.1's closing
paragraph): the enforcement mechanism rejects all 9 regardless.

**OQ-2 (MINOR, forward note for whoever eventually fixes `after_created`'s skip-risk):**
§4.4 ports `definition.md`'s documented `after_created`-strictly-after-plus-DESC-order
cursor semantics as-is, including its known skip-risk at a `created_at` tie. A composite
`(created_at, id)` cursor would close it but is new API surface no current acceptance
criterion asks for — not built here.

PROVENANCE (historical, not current decision authority):
**OQ-3 (MINOR, for REQ-031's own CODE-DESIGNER to confirm or correct):** §6.2 step 6 places
the `service_scope_validator` hook call after the row lock, inside the `:draft` branch,
before the two transition UPDATEs — matching `store.zig`'s real, current code structure.
REQ-031's own future requirement text (quoted in this run's task briefing) describes the
hook as running "before the SQL transition transaction opens," which this design reads as
referring to the two UPDATE statements rather than the outer `Repo.transaction/1` boundary,
since the real Zig code runs the check *inside* an already-open transaction. Flagged rather
than silently reconciled, since REQ-031 is unscoped here and its own design should confirm
this reading against its own source access.

**OQ-4 (MINOR):** `update/1` (PUT/PATCH) has no owner (§1). `ProcessDefinition.update_changeset/2`
already exists (REQ-027) with nothing calling it. Not a defect in this design — REQ-030's own
function list doesn't include it — but the gap should be closed deliberately by a future
requirement rather than discovered by accident.

---

## 10. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Definitions.ProcessDefinition` (REQ-027) | this design → REQ-027 | `create_changeset/2` (§4.1 P10), direct `ProcessDefinition` struct reads/writes via `Repo`/`Ecto.Query` (all 7 functions), the `status()` type alias (§4.0). Unchanged by this design. |
| `Letflow.Definitions.Graph`/`.Node`/`.Edge`/`.Violation` (REQ-028/029) | this design → REQ-028/029 | `validate_graph/1`, `validate_node_attributes/1`, `validate_edge_conditions/1` (§4.1 P7-P9); the struct shapes `graph_struct_from_map/1` (§5) constructs. Zero code added to `graph.ex` by this design. |
| `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` (REQ-025) | this design → REQ-025 | Every function's `opts[:prefix]` resolution (§3). |
| `Letflow.Repo` | this design → `Repo` | Every write/read; `prefix: schema_name` on every call (INV-DEF-7). |
| REQ-031 (SVC-03 hook) | REQ-031 → this design | Consumes `activate/2`'s `opts[:service_scope_validator]` injection point (§4.5, §6.2 step 6, §7). Not built here. |
| S4 (HTTP layer) | S4 → this design | Will call all 7 functions and map their typed errors to HTTP statuses, per `definition.md`'s error taxonomy (`GraphValidationFailed`→422, `DuplicateNameVersion`→409, `DefinitionNotFound`→404, `InvalidStatusTransition`/`NotDraft`→409, etc.) — not built here. |

---

## 11. Acceptance-criteria traceability

| REQ-030 acceptance criterion | Concrete design element |
|---|---|
| 1. `create/1` with a graph failing `validateGraph()` writes zero rows, returns the collected violations, not a generic error | §4.1 P7 (`{:error, {:graph_validation_failed, violations}}`), P7-P9 strictly precede P10/P11 (the only `Repo`-touching steps) |
| 2. Two concurrent `create/1` calls, identical `(name, version)`: exactly one success, one duplicate-error | §4.1 P11 (targeted `conflict_target: [:name, :version]`) + P12 (insert-or-fetch disambiguation, citing the two already-shipped precedents) |
| 3. `activate/1` on DRAFT atomically deprecates any prior ACTIVE of the same name, in the same transaction | §6.2 steps 7-8, one `Repo.transaction/1`, deprecate strictly before activate |
| 4. `activate/1` called twice on already-ACTIVE returns the no-op/AlreadyActive result both times, never an error | §6.2 step 4; §4.5's return-shape note |
| 5. Every one of the 4 forbidden-transition cells is tested and rejected | §6.1 (full reconciliation against the real 9-cell table), §6.2/§6.3's guard-by-construction mechanism (all 9 covered regardless of count) |
| 6. `activate/1`'s signature includes a nil-able/optional service-scope-validation hook, documented as the SVC-03 integration point | §4.0 (`activate_opts()`), §4.5, §6.2 step 6, §7's required verbatim moduledoc text |
| 7. `get_active_by_name/1`: ACTIVE name → that definition; only DRAFT/DEPRECATED/ARCHIVED → not-found, never the most-recent non-active row | §4.3, especially its closing "no fallback query" note |
| 8. `list/1` with a stage filter returns only exact `stage` matches, combinable with simultaneous name/status filters | §4.4 steps 4-8, especially step 6's exact-match note and step 8's `AND`-composition explanation |
| 9. A row written by `create/1` has `tenant_id` derived internally, never a disagreeing caller-supplied value; disagreement fails loudly | §3 (whole section) + §4.1 P0/P2 |
