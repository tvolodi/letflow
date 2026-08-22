# REQ-126 — Version-pinned form references on task payloads (MOB-3 pinning)

**Requirement:** REQ-126 (`docs/requirements.yaml`, stage S9; full `description` and all
5 `acceptance_criteria` read directly from that entry, per `core-directives.md`'s "Load
Scoped Context, Not Whole Files" — `awk '/^  - id: REQ-126$/,/^  - id: REQ-127$/'
docs/requirements.yaml`).
**Owner (implementer):** `ELIXIR-DEV`.
**Depends on:** REQ-083 (`Letflow.Tasks`/`Letflow.Routers.Tasks` read path).
**No implementation code below** — signatures, `@spec`-style types, and field/shape
tables only, matching REQ-083's/REQ-085's own convention.

---

## 0. Sources read for this design

- REQ-126's own `docs/requirements.yaml` entry (scoped `awk` read).
- `lib/letflow/engine/pin_resolver.ex` (full) — REQ-059's definition-level pin machinery.
- `lib/letflow/definitions/instance_definition_snapshot.ex` (full) — the
  `instance_definition_snapshots` schema, REQ-027.
- `lib/letflow/definitions/snapshot_store.ex` (full) — `create/3`/`get_by_instance_id/2`,
  REQ-033, confirms `graph: source_definition.graph` is copied verbatim (no re-encoding)
  from `process_definitions.graph` into `instance_definition_snapshots.graph` at
  instance-start time, and that this row is fetched today only by primary-key lookup
  (`Repo.get/3`), never yet joined against `tasks`.
- `lib/letflow/engine/task.ex` (full) — the `tasks` schema; `form_schema` field exists but
  is never cast/populated by anything (`insert_changeset/2` casts it, no caller ever
  supplies it).
- `lib/letflow/definitions/graph.ex` (`from_map/1`, `Node` struct) — confirms
  `instance_definition_snapshots.graph` round-trips through JSONB as a **plain map with
  string keys** (`"nodes"`, `"id"`, `"node_type"`, `"attributes"`), not the atom-keyed
  `Graph.Node` struct — `Graph.from_map/1` is the (currently unused-by-this-path)
  converter between the two.
- `lib/letflow/engine.ex` (`create/5` §"create_snapshot", `fetch_graph/2`,
  `TaskActivation`) — confirms `SnapshotStore.create/3` runs before `INSTANCE_STARTED` is
  appended, and confirms `tasks` rows are activated **only** for `:HUMAN_TASK` nodes
  (`lib/letflow/engine/task_activation.ex:17`, `"it only runs for a :HUMAN_TASK node"`) —
  every `tasks.node_id` therefore already names a `HUMAN_TASK` node.
- `lib/letflow/tasks.ex` (full) — `list_tasks/2`, `get_task/2`, the functions this
  requirement extends.
- `lib/letflow/routers/tasks.ex` (full) — `task_list_item_map/1`, `task_detail_map/2`, the
  response allowlists this requirement extends.
- `docs/mobile/requirements.md` MOB-3 (lines 67-90) and `docs/mobile/architecture.md`
  (row 3 of its gap table) — the mobile-side contract this requirement satisfies:
  "The app MUST cache definitions locally keyed by `(type, id, version)` ... A pinned
  interaction — a task payload carrying `{ form_id, form_version }` — MUST render the
  exact pinned version and MUST NOT silently fall back to the active version."
- `docs/agents/instructions/security-invariants.md` INV-4, INV-7, INV-8.
- `docs/anti-patterns.md` (no entry directly on point; scanned in full).
- `web/src/api/tasks.ts`, `web/src/router.tsx` (grep) — confirms the SPA's `RawTask` type
  is a plain TS interface spread with `{ ...(raw as unknown as Task), id, created_at,
  updated_at }` (no exhaustive/`.strict()` key check), and `web/tsconfig.app.json` has no
  `exactOptionalPropertyTypes` — additive unknown response fields cannot fail the SPA's
  type layer or its existing tests.
- `lib/letflow/design/req027-definition-core-schema.md`, `req083-task-routes-read.md`,
  `req059-pin-resolver.md` (for the `PinResolver` contrast, restated in §2 below).

---

## 1. Scope

Add `form_id` and `form_version` to every task payload returned by
`GET /tasks`, `GET /tasks/inbox`, and `GET /tasks/:id` (the three REQ-083 read routes).
No new schema, no new table, no new node attribute. This requirement is a **read-path
extension only** — it adds one join and two response-map keys; it does not touch
`Letflow.Engine`, task activation, or any write path.

**Explicitly out of scope** (do not build, per the requirement's own framing and the
investigation notes above):

- `tasks.form_schema` (REQ-047 §4.4 OQ-3, `Letflow.Engine.VariableSchema`'s "raw
  JSON-schema rendering payload" concern) — a different, still-unbuilt concern (the form's
  *content*, not its *identity*). Not populated by this requirement. Flagged as future
  scope in §8.
- Any new forms catalog, `forms` table, or `form_id` node attribute. See §2's decision.
- `GET /definitions/delta` (the other MOB-3 gap named in `docs/mobile/requirements.md`) —
  a separate, unscoped requirement.

---

## 2. Core design decision — `form_id`/`form_version` derivation

**Decision: `form_id == task.node_id`; `form_version == instance_definition_snapshots.definition_ver`
(looked up by `task.instance_id`). No new node attribute, no graph walk, no new table.**

### 2.1 Why not a new `attributes["form_id"]` node attribute

Letflow has no forms catalog anywhere in `lib/` (confirmed by grep — zero hits for
`form_id`/`form_version` outside `docs/mobile/`). Inventing a new optional
`attributes["form_id"]` on `HUMAN_TASK` nodes would require: a `Graph`/CHK-09 validator
change, a fallback decision for every node that omits it, and a promotion-plan/graph-diff
question about what "changing the form" even means for an attribute nobody writes yet.
None of that is asked for by REQ-126's acceptance criteria, and R-Co's own zig source
carries no `form_id` concept either (confirmed by the same investigation this requirement's
`docs/requirements.yaml` description cites — "neither form_id nor form_version appears
anywhere in lib/").

`tasks.node_id` is a **HUMAN_TASK node id**, always (§0 — `task_activation.ex:17`; no other
node type ever produces a `tasks` row). MOB-3's own client design already caches
"definitions locally keyed by `(type, id, version)`" — a `(node_id, definition_ver)` pair
*is* that same `(id, version)` key shape, with `type` implicitly "form" for this call site.
Reusing the node's own identity as the form identity is not a workaround; it is the most
honest statement of what Letflow's data model actually contains today: **the "form" for a
`HUMAN_TASK` node is that node**, addressed by the id it already has, at the version its
owning process definition already carries. A dedicated forms catalog is very likely
premature — REQ-126's acceptance criteria are satisfiable in full without one — but this is
flagged as **OQ-1** in §9 in case REVIEWER reads the requirement's mobile-side framing as
implying a forms catalog is expected to exist independently of nodes.

### 2.2 Why `instance_definition_snapshots.definition_ver`, not a new pin

`instance_definition_snapshots` is a write-once row (`InstanceDefinitionSnapshot`, no
`update_changeset/2` at all), inserted by `SnapshotStore.create/3` **before**
`INSTANCE_STARTED` is appended (`lib/letflow/engine.ex` — `create_snapshot/3` runs, then
`activate/3`), capturing `definition_ver` and the full `graph` exactly as they existed at
instance-start. Promoting a new `process_definitions` version afterward creates a **new**
row there and never touches an existing instance's snapshot row — the snapshot is already,
structurally, an immutable per-instance record of "which definition version this instance
started from." Every `HUMAN_TASK` node a task was activated from lives inside that
snapshot's own `graph`, at that same frozen version. There is nothing left to pin: the
snapshot already pins it, for a reason (REQ-027/033, S3) that predates this requirement and
predates `PinResolver` (REQ-059) by construction — `instance_definition_snapshots`
shipped before `PinResolver` existed.

Because `form_id == task.node_id` requires no lookup *into* the graph at all (the node id
*is* the task's own `node_id` column — see §4), **the graph walk this requirement's
originating investigation contemplated turns out to be unnecessary**. The only new read
this requirement needs is `instance_definition_snapshots.definition_ver`, keyed by
`instance_id` — a single scalar column, not the `graph` blob. This materially simplifies
§4/§5 below relative to a design that parses `graph["nodes"]` on every task read.

### 2.3 Relationship to `Letflow.Engine.PinResolver` (acceptance criterion 2)

`PinResolver` pins **external, mutable-catalog** references — `catalog_entry`
(`SERVICE_TASK.service_id`) and `module` (`SUB_PROCESS.module_ref`) — things that live
*outside* a process definition's own row and require an active resolution step
(`resolve/4`) against an injectable `Lookup`, recorded into the `INSTANCE_STARTED` event
payload because there is no other durable place to freeze them (`pin_resolver.ex`
moduledoc, "Persistence" section: "No migration, no `Ecto.Schema`, no DB table is added by
this requirement"). A form reference is the opposite case: it is **already inside** the
definition's own snapshot row, which was already immutable and already frozen at
instance-start time for an unrelated reason (REQ-027/033's PD-08 "read-only after
creation" contract, not pin machinery at all). There is no live catalog to resolve a form
version against, no override concept, no inheritance concept, and no
`INSTANCE_PINS_REBOUND`-equivalent rebind event — none of `PinResolver`'s four concerns
(`resolve/4`, `merge_effective_pins/3`, `apply_inheritance/2`, `pin_for/3`) has a form
counterpart to build. This requirement therefore adds **a new read**, not new pinning
machinery, over data that was pinned for other reasons before `PinResolver` (REQ-059)
existed at all. `Letflow.Tasks`'s own moduledoc gets a new section stating this plainly
(§6.4 below) — this satisfies acceptance criterion 2's "state the relationship... reusing
its mechanism where it applies, and saying why where it does not."

---

## 3. Migration — none required

**Conclusion: no new migration.** `tasks.node_id` (existing column, REQ-043) supplies
`form_id` directly. `instance_definition_snapshots.definition_ver` (existing column,
REQ-027) supplies `form_version` via one additional join keyed on the already-existing,
deliberately-FK-less `instance_id` column (`InstanceDefinitionSnapshot`'s own moduledoc:
"bare `UUID PRIMARY KEY` with no `REFERENCES` clause" — joining on it from `tasks` is a
plain equality join on two UUID columns, not a new relationship the schema needs to
declare). No column is added to `tasks`, no column is added to
`instance_definition_snapshots`, and `tasks.form_schema` is left exactly as-is (still
`nil`, still out of scope — §1).

---

## 4. Query/join changes — `Letflow.Tasks`

### 4.1 `get_task/2` — add a second `left_join`

Current query (`lib/letflow/tasks.ex:204-210`) already `left_join`s `InstanceProjection`
for `correlation_key`. Add a second `left_join` against `InstanceDefinitionSnapshot`,
joined on `t.instance_id == s.instance_id` (plain equality, no association — matching
`InstanceDefinitionSnapshot`'s own moduledoc, which deliberately has no
`belongs_to`/association of any kind), selecting `s.definition_ver` alongside the existing
two projections.

**Return type changes** from:

```
{:ok, {Task.t(), correlation_key :: String.t() | nil}}
```

to:

```
{:ok, {Task.t(), correlation_key :: String.t() | nil, form_version :: String.t() | nil}}
```

`form_version` is `String.t() | nil` in the type (never crashes on a missing join row —
INV-8) even though §4.3 states the practical case is always non-nil; see §5 for the
fallback behavior contract.

`left_join`, not `join` — a task whose instance's snapshot row is somehow absent (see §5)
must not make the whole task disappear from `get_task/2`'s result; `correlation_key`
already establishes this precedent for the exact same reason (an instance whose
`InstanceProjection` hasn't been created yet).

### 4.2 `list_tasks/2` — same join, added to the existing query pipeline

The existing `Task |> filter_by_status(...) |> filter_by_instance_id(...) |> ...` pipeline
(`lib/letflow/tasks.ex:163-176`) gets the identical `left_join` on
`t.instance_id == s.instance_id` added to its `from`, and the `select` widened to
`{t, s.definition_ver}` (a 2-tuple; `list_tasks/2` has no `correlation_key` concern —
`get_task/2` is the only one of the three read functions that ever joined
`InstanceProjection`).

**Return type changes** from:

```
{:ok, %{items: [Task.t()], next_cursor: String.t() | nil}}
```

to:

```
{:ok, %{items: [{Task.t(), form_version :: String.t() | nil}], next_cursor: String.t() | nil}}
```

`split_list_page/2` and `build_list_next_cursor/1` (private helpers, `lib/letflow/tasks.ex:589-602`)
keep pagination keyed on the `Task` half of each tuple only (`inserted_at`/`id`) — cursor
encoding does not change shape or content; only the row shape flowing through
`Repo.all/2` → `split_list_page/2` changes from bare `Task.t()` to `{Task.t(), String.t() | nil}`.
`build_list_next_cursor/1`'s pattern match updates from `%Task{id: id, inserted_at: inserted_at}`
to `{%Task{id: id, inserted_at: inserted_at}, _form_version}`.

### 4.3 No graph walk, no new pure function

Per §2.2, `form_id` is `task.node_id` directly — no `Graph.from_map/1` call, no
`graph["nodes"]` walk, no new pure function of the shape the requirement's originating
investigation contemplated (`(graph, node_id) -> form_id`). The only per-task work is
reading `s.definition_ver` off the join. This is a deliberate simplification over that
investigation's framing — flagged explicitly here (not silently) since it changes what
CODE-DESIGN-VALIDATOR should expect to see built: no `Letflow.Definitions.Graph` call
appears anywhere in `Letflow.Tasks` as a result of this requirement.

---

## 5. Fallback behavior — task whose snapshot row is not found (INV-8)

Given a `HUMAN_TASK` node can only produce a `tasks` row via `TaskActivation`, and
`TaskActivation` only ever runs after `SnapshotStore.create/3` has already inserted that
instance's snapshot row (`Letflow.Engine.create/5`'s call order: `create_snapshot/3` before
`activate/3`, before any task is ever activated), a `tasks` row with no matching
`instance_definition_snapshots` row is **structurally near-impossible** in normal
operation — the exact phrasing the requirement's investigation notes anticipated.

**Stated fallback, exercised by the `left_join`'s `nil` case:** `form_id` is still emitted
(`task.node_id` needs no join at all — see §4.3) but `form_version` is `nil` in the
response body. No exception, no 500, no crash (INV-8) — the `left_join`'s `nil` flows
through `{task, nil, nil}` / `{task, nil}` tuples exactly like `correlation_key`'s existing
`nil` case does today for an instance with no `InstanceProjection` row yet. This is a
distinct case from "task whose definition pins a form" (§7.3's acceptance-criterion-5
test, which asserts *presence*, i.e. non-nil, for the normal case) — the null case is
reachable only via direct DB manipulation or a genuine data-integrity gap, and is handled
the same non-crashing way REQ-083 already handles the analogous `correlation_key` gap,
not given a special error path of its own.

---

## 6. Response-map changes — `Letflow.Routers.Tasks`

### 6.1 `task_list_item_map/1` → `task_list_item_map/2`

Signature changes from `task_list_item_map(Letflow.Engine.Task.t()) :: map()` to:

```
task_list_item_map(Letflow.Engine.Task.t(), form_version :: String.t() | nil) :: map()
```

adding exactly two new keys to the existing 9-key map (11 total):

```
"form_id" => task.node_id,
"form_version" => form_version
```

Placement: appended after the existing 9 keys (before `handle_list_result/2`'s
`Enum.map(items, &task_list_item_map/1)` call site is updated to
`Enum.map(items, fn {task, form_version} -> task_list_item_map(task, form_version) end)`,
matching the new `{Task.t(), form_version}` tuple shape `list_tasks/2` now returns —
§4.2).

### 6.2 `task_detail_map/2` → `task_detail_map/3`

Signature changes from
`task_detail_map(Letflow.Engine.Task.t(), String.t() | nil) :: map()` to:

```
task_detail_map(Letflow.Engine.Task.t(), correlation_key :: String.t() | nil, form_version :: String.t() | nil) :: map()
```

Internally still builds on `task_list_item_map/2` (now passing `form_version` through)
before adding `correlation_key`/`updated_at` — 13 keys total (11 from the widened list map
+ `correlation_key` + `updated_at`).

### 6.3 Call-site updates (additive-only, no behavior change to existing keys)

- `handle_get_by_id/3` (`lib/letflow/routers/tasks.ex:334-345`): `Tasks.get_task/2` now
  returns `{:ok, {task, correlation_key, form_version}}` (§4.1) — the `case` clause widens
  to match the 3-tuple and calls `task_detail_map(task, correlation_key, form_version)`.
- `handle_claim_result/2`, `handle_assign_result/2`, `handle_reassign_result/2`
  (`lib/letflow/routers/tasks.ex:423-424`, `:489-490`, `:520-521`): each currently calls
  `task_detail_map(task, nil)` — the literal `nil` for `correlation_key` (these three
  write paths never join `InstanceProjection`). Each becomes
  `task_detail_map(task, nil, form_version)`, where `form_version` is obtained by a
  **new, separate one-row lookup** (`instance_definition_snapshots` by `task.instance_id`)
  — these three functions receive only a bare `Task.t()` back from
  `claim_task/3`/`assign_task/4`/`reassign_task/4` (REQ-085, not REQ-083's own query
  path), so there is no join result already in hand the way there is for
  `handle_get_by_id/3`. This one-row lookup is the same shape as
  `SnapshotStore.get_by_instance_id/2` already exposes (REQ-033) — reusing that existing
  function (selecting only `definition_ver` from its result) rather than adding a second,
  narrower query function is the intended call, flagged as **OQ-2** in §9 for
  CODE-DESIGN-VALIDATOR to confirm this reuse is acceptable versus a purpose-built
  `Letflow.Tasks` helper that selects only the one column.
- **This is additive-only** — every existing key in both maps keeps its name, position
  relative to itself, and value derivation unchanged. The SPA's `RawTask`/`Task` TypeScript
  type (`web/src/types/api.ts`, consumed via `web/src/api/tasks.ts`'s `normalizeTask`) is a
  plain interface spread with `{ ...(raw as unknown as Task), id, created_at, updated_at }`
  — no `.strict()`/exhaustive check anywhere in that boundary, and `web/tsconfig.app.json`
  does not set `exactOptionalPropertyTypes`. Two new, unconsumed response keys cannot fail
  TypeScript compilation or any existing test. Acceptance criterion 4 ("the SPA's existing
  behaviour is unchanged") is satisfied by construction; TEST-DESIGNER's job is to prove it
  by running `web/`'s existing suite unmodified against the new payload shape (a live
  backend/fixture emitting the two new keys), not to add SPA code that reads them.

### 6.4 Moduledoc update (acceptance criterion 2)

`Letflow.Tasks`'s own moduledoc gets a new section (placed near its existing "Why
claim/assign/reassign live here" section) restating §2.3 above in substance: the
`instance_definition_snapshots.definition_ver` read this requirement adds is a **reuse of
an already-immutable, pre-`PinResolver` record**, not a new instance of `PinResolver`'s
resolve/override/inherit/rebind machinery, and why (no external catalog, no override
concept, the snapshot was already frozen for an unrelated write-once reason). This is the
moduledoc acceptance criterion 2 requires — placed on `Letflow.Tasks` (the module
performing the new join), matching `PinResolver`'s own convention of stating the "why" on
the module doing the work, not on every caller. `Letflow.Routers.Tasks`'s "Response
allowlists" section (`lib/letflow/routers/tasks.ex:79-89`) gets a short addition noting the
two new keys exist and forward-referencing `Letflow.Tasks` for the "why."

---

## 7. Test-relevant specifics (for TEST-DESIGNER / CODE-DESIGN-VALIDATOR)

### 7.1 AC1 — payload carries `form_id`/`form_version`

Assert against the actual JSON response body of `GET /tasks/:id` (and at least one of
`GET /tasks`/`GET /tasks/inbox`, per AC1's "task payloads returned by the task read
routes" plural phrasing — not detail-only) that `"form_id"` and `"form_version"` keys are
present, `"form_id"` equals the activated `HUMAN_TASK` node's own id, `"form_version"`
equals the definition version the instance was started from.

### 7.2 AC3 — pinned at creation, not at read time

**Exact test scenario** (this is what "changing the form after task creation" means under
this design — there is no separate form entity to mutate; "changing the form" means
promoting a new `process_definitions` version with a different graph):

1. Create/promote a process definition **v1** whose graph has a `HUMAN_TASK` node
   (e.g. `node_id: "review"`).
2. Start an instance from v1 (`Letflow.Engine.create/5`) — this writes the
   `instance_definition_snapshots` row with `definition_ver: "1"` (or whatever v1's
   version string is) and activates a `tasks` row for the `"review"` node.
3. Promote a **new** process definition version **v2** under the **same process name**,
   with a **different** graph (e.g. the `"review"` node's `label`/`attributes` changed, or
   any graph delta — the specific delta is irrelevant to this test, only that v2 exists
   as a distinct `process_definitions` row).
4. `GET /tasks/:id` for the task created in step 2.
5. Assert `"form_version"` in the response body still equals v1's version string, **not**
   v2's — proving the read derives from `instance_definition_snapshots.definition_ver`
   (frozen at step 2) rather than from a live `process_definitions` lookup (which would
   answer v2, silently substituting — the exact failure MOB-3 forbids).

This test needs no engine-level "rebind" or pin-override concept at all (unlike
`PinResolver`'s own tests) — promoting v2 is ordinary `Letflow.Definitions` promotion-plan
machinery, already shipped; this test only needs to prove the *read* doesn't re-derive
from the now-current `process_definitions` row.

### 7.3 AC5 — presence, not null, for a task whose definition pins a form

Since every `tasks` row is, by construction (§0), activated from a `HUMAN_TASK` node, the
"normal" fixture (any task created via ordinary instance-start + activation) already
satisfies this — assert `response["form_id"] != nil` and `response["form_version"] !=
nil` for such a task, distinct from §5's near-impossible `left_join`-miss fallback case
(which TEST-DESIGNER may cover separately by inserting a `tasks` row with an
`instance_id` that has no matching snapshot row directly via `Repo.insert!/2` in the test
setup, to exercise the `nil`-`form_version` path without crashing — INV-8).

### 7.4 AC4 — SPA suite unmodified

Run `web/`'s existing test suite (`npm test` / project's established `web/` test command)
against a backend emitting the new payload shape and confirm zero failures, zero skips
added. No new SPA test is required by this requirement — REQ-126 does not ask the SPA to
consume the new fields, only to tolerate them.

---

## 8. Future scope (not this requirement)

`tasks.form_schema` (REQ-047 §4.4's still-open OQ-3, the raw JSON-schema rendering
payload) could be populated as a follow-on, now that `form_id`/`form_version` establish
the identity half of "what form." This design deliberately does not attempt it (§1) —
populating it would require reading `node.attributes["form_schema"]` out of the snapshot
graph at *task-activation* time (a write-path change to `TaskActivation`, REQ-047/048
territory, not this read-path requirement) and was explicitly called out as a non-goal by
this run's own scoping notes. Left for a future requirement.

---

## 9. Open questions (not silently resolved)

- **OQ-1** — Whether a genuinely separate forms catalog (distinct `form_id` from
  `node_id`, a dedicated attribute/table) is expected by some future mobile-tier
  requirement not yet written. This design reads REQ-126's own acceptance criteria and
  MOB-3's `(type, id, version)` cache-key framing as satisfied by `node_id`-as-`form_id`,
  and treats a dedicated catalog as premature/out of scope for this requirement — flagged
  for REVIEWER to confirm rather than assumed settled.
- **OQ-2** — Whether `claim_task/3`/`assign_task/4`/`reassign_task/4`'s response path
  (§6.3) should reuse `Letflow.Definitions.SnapshotStore.get_by_instance_id/2` (fetching
  the full snapshot row, including `graph`, to read one field) or whether a new,
  narrower `Letflow.Tasks` helper that `select`s only `definition_ver` is worth adding to
  avoid pulling the (potentially large) `graph` map over the wire from Postgres for a
  write-path response that doesn't need it. This design defaults to the narrower
  `Letflow.Tasks`-owned query (consistent with `Letflow.Tasks`'s own moduledoc: "This
  module never itself decides tenant scope... `prefix` supplied by caller," and its
  existing precedent of not depending on `Letflow.Definitions` internals) but flags the
  choice explicitly for ELIXIR-DEV/REVIEWER rather than picking silently.
