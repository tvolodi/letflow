# Design: REQ-047 — Task activation persistence (EE-03)

**Requirement:** REQ-047 (`docs/requirements.yaml`, stage S3, per this run's handoff
`context.requirement_text`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ047-20260818`, WF-02 Step 1
**This document produces:** the `Letflow.Engine.TaskActivation` module's public function
signatures, the extension this requirement makes to `Letflow.Engine`'s already-shipped
`Ecto.Multi` (REQ-045/050/051), the `token_id`-FK resolution mechanism, the
assignee-resolution contract, the named SCH-03 hook, invariants, DB columns touched, and
every acceptance criterion mapped to a concrete design element. No implementation code —
signatures/shapes only, matching `req043`/`req044`/`req045`'s own convention.

---

## 0. Sources read for this design

- This run's handoff (`handoffs/WF02-REQ047-20260818/step-01-code-designer.json`) —
  `context.requirement_text.REQ-047` and `task.acceptance_criteria`, per
  `core-directives.md`'s "Load Scoped Context, Not Whole Files."
- `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1's procedure.
- `docs/migration/stage-3-instance-engine.md` — EE-03 Task Activation's place in the
  EE-01..EE-12 breakdown, the SCH-03/S6 scope exclusion ("SCH-03 timer cancellation ...
  `src/scheduler/` — S6 ... with a named hook left in the affected requirements rather
  than a partial implementation"), and the `tasks`/`tokens` ownership note (REQ-043 builds
  the tables, EE-03/REQ-047 is the write path).
- `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md` — D2: `tenant_id`
  is dropped from `tasks`, `tokens`, `instance_projections`, `events`. **This design adds
  no `tenant_id` column or derivation to any of the three tables it touches** — confirmed
  against the already-shipped schema modules (§1 below), not re-derived.
- `lib/letflow/design/req043-instance-engine-schema.md` — the `tasks`/`tokens`/
  `instance_projections` schema this design writes into (§4 `tasks` column list and
  changesets, §3/§5 `tokens`/`TokenRecord`, §2 `instance_projections` ALTER).
- `lib/letflow/design/req044-transition-kernel.md` — `pending_task_nodes`'s exact
  semantics: §6.3 ("the signal itself is the guard" — only the `:HUMAN_TASK` dispatch
  clause ever appends to it) and §12.3 (explicitly left open: "whether/when an entry is
  removed from `pending_task_nodes` ... left open for REQ-047's CODE-DESIGNER to resolve
  explicitly" — resolved by this design, §5).
- `lib/letflow/design/req045-instance-start-engine-shell.md` — the already-shipped
  `create/2`/`persist/7`/`Ecto.Multi` shape this design extends (§6), and its own OQ-1
  (the `Letflow.Engine.Token` vs `Letflow.Engine.TokenRecord` naming split, load-bearing
  for §3 below).
- `lib/letflow/engine.ex` (full, current `main`) — the actual shipped `create/2`,
  `persist/7`, `insert_token_records/4`, `finalize_instance_projection/4`. Read directly
  rather than assumed, since this design extends this exact code, not a paraphrase of it.
- `lib/letflow/engine/transition.ex` (full) — confirms only `dispatch_human_task/3` ever
  appends to `pending_task_nodes`; `dispatch_start/4`, `dispatch_end/3`,
  `dispatch_exclusive_gateway/4`, `dispatch_parallel_gateway/4` (split/join/pass-through)
  never do, by direct code read (not inferred from the design doc alone).
- `lib/letflow/engine/task.ex`, `lib/letflow/engine/token_record.ex`,
  `lib/letflow/engine/token.ex`, `lib/letflow/engine/instance_state.ex` (full) — the
  shipped `Letflow.Engine.Task`/`TokenRecord`/`Token`/`InstanceState` structs/changesets
  this design reuses without modification.
- `lib/letflow/definitions/graph.ex` (`Node` struct) — confirms `Node.t()` has `label`
  (`String.t() | nil`), **not** a `name` field — load-bearing for §4.2's `node_name`
  mapping and OQ-2.
- `lib/letflow/design/req029-node-attribute-edge-condition-validators.md` §2, §4 — PD-05's
  CHK-09 (`check_human_task_role/1`): the **only** attribute PD-05 validates on a
  `:HUMAN_TASK` node is `attributes["role"]` (`String.t()`, non-empty after `trim/1`). No
  `"assignee_type"` key, or any group/role-kind distinction, is validated anywhere in
  REQ-029 — load-bearing for §4.3's assignee-resolution design and OQ-1.

---

## 1. What already exists, and what this requirement adds

**Already shipped (REQ-045, REQ-050, REQ-051 — read directly in `lib/letflow/engine.ex`,
not re-designed here):** `Letflow.Engine.create/2` runs a pre-transaction phase (§4 of
`req045`'s design), a snapshot phase, a pure `advance_until_stable/4` dispatch loop
(REQ-044's `Transition.transition/3`, one hop per call), then `persist/7`, which opens
**one** `Ecto.Multi` with four steps in this exact order:

| Step key | What it does | Reads from |
|---|---|---|
| `:instance_projection` (M1) | Inserts the `instance_projections` row (`status: :active` always — see M4) | — |
| `:token_record` (M2) | Inserts one `Letflow.Engine.TokenRecord` row per `Token.t()` in `new_instance_state.tokens`, in order, via `insert_token_records/4` | M1 (FK) |
| `:event` (M3) | Appends the `INSTANCE_STARTED` event via `Letflow.EventStore.append/2` | M1 (FK, and `append/2`'s own `active_instance_guard`) |
| `:finalize` (M4) | Flips `instance_projections.status`/`completed_at` to `new_instance_state.status` if it is `:completed`; no-op if still `:active` | M1, M3 |

**What this requirement adds:** a fifth Multi step, `:task_records`, inserting one
`Letflow.Engine.Task` row per **newly** pending `Token.t()` in `new_instance_state.pending_task_nodes`
(§5), positioned after `:token_record` (needs its FK target, §3) and before `:finalize`
(ordering relative to `:event` is not FK-constrained either way; placed before `:event`
below for a stable, documented order). **This design does not touch `persist/7`'s
existing four steps' own internal logic** — M1/M2/M3/M4 are unchanged; only the Multi
chain gains one new link. The pure diff/attrs-building logic that produces the new step's
work lives in a new module, `Letflow.Engine.TaskActivation` (§2), kept separate from
`Letflow.Engine` for two reasons: (a) it is pure/testable in isolation the same way
`Letflow.Engine.Transition`/`VariableMerge` are, and (b) EE-04 (task completion, a future
requirement not built here) is expected to call `transition/3` again against an
already-running instance and will need this exact same diff-and-insert step wired into
its *own* Multi — a standalone module avoids REQ-047's logic being locked inside
`Letflow.Engine`'s private `persist/7` where only `create/2` could reach it.

---

## 2. `Letflow.Engine.TaskActivation` — module and file placement

**New file:** `lib/letflow/engine/task_activation.ex`. Pure/query-helper functions only —
no `Repo` call of its own; every DB write it drives happens inside the `Ecto.Multi` the
*caller* (`Letflow.Engine.persist/7` today; a future EE-04 entrypoint later) already
holds open, exactly the pattern `Letflow.EventStore.append/2` and
`Letflow.Definitions.SnapshotStore.create/3` already establish for "one context module's
write path calls into another's, inside the same transaction."

**Required moduledoc content (verbatim in substance):**

1. The "signal itself is the guard" property (EE-03, quoted in this run's task text):
   this module never inspects a `Graph.Node.t().node_type` to decide whether to create a
   task row — the presence of a `Token.t()` in the *diff* between an `InstanceState`'s
   `pending_task_nodes` before and after one `transition/3`-driven activation is the only
   signal this module acts on, because `Letflow.Engine.Transition`'s own dispatch (REQ-044
   §6.3, confirmed by direct code read, §0) is the single place any entry is ever added to
   `pending_task_nodes`, and it only runs for a `:HUMAN_TASK` node.
2. That this module builds no node-type re-validation, no group-membership check, and no
   assignment-resolution logic of its own (§4.3) — assignment resolution is explicitly
   deferred to runtime per this run's task text, not an activation-time concern.
3. That `Letflow.Engine.persist/7` is this module's first caller (§5), and that a future
   EE-04 (task completion) requirement is expected to reuse `append_multi/6` (§3) against
   its own `Ecto.Multi` rather than duplicating this diff/insert logic a second time.

---

## 3. `token_id_to_record_id` — resolving the `tasks.token_id` FK

**The problem, stated precisely, because it is not obvious from the schema alone:**
`tasks.token_id` (req043 §4.1) is a foreign key to `tokens.id` — the **database-generated**
`Letflow.Engine.TokenRecord` primary key (`@primary_key {:id, :binary_id, autogenerate:
true}`, confirmed by direct read, §0). It is **not** the same value as the pure
`Letflow.Engine.Token.token_id` field (a caller-minted string — for a root token, an
`Ecto.UUID.generate()` value; for a `PARALLEL_GATEWAY` split branch, a derived string like
`"<parent_token_id>/0"`, confirmed by direct read of `dispatch_parallel_split/4` — **not
itself a valid UUID shape**). A `Token.t()` value inside `pending_task_nodes` therefore
carries no field this design can cast directly into `tasks.token_id`; the corresponding
`TokenRecord.id` must be looked up.

**Resolution: build the map from the same Multi step that inserts the token records.**
`Letflow.Engine.persist/7`'s existing `:token_record` step (M2, unchanged, §1) already
calls `insert_token_records(repo, instance_id, new_instance_state.tokens, prefix)`, which
inserts one row per `Token.t()` in `new_instance_state.tokens`, **in the same order**, and
returns `{:ok, records}` with `records` in that same order (confirmed by direct read of
`insert_token_records/4`/`insert_token_record/4`, §0). This design specifies zipping the
two same-order lists:

```
@spec token_id_to_record_id([Token.t()], [TokenRecord.t()]) ::
        %{optional(String.t()) => Ecto.UUID.t()}
```

`Enum.zip(tokens, records)`-shaped, folded into `%{token.token_id => record.id}`. This
function lives on `Letflow.Engine.TaskActivation` (pure, no I/O) and is called by the new
`:task_records` Multi step (§5) with `new_instance_state.tokens` and M2's own
`Multi.run/3` result (already available to a later step via the Multi's `changes` map,
the same mechanism M3/M4 already use to read M1's result).

**Invariant this map's construction depends on (INV-EE47-3, §7):** every `Token.t()` that
is newly present in `pending_task_nodes` must also be present in
`new_instance_state.tokens` at the same call — true today because `dispatch_human_task/3`
appends the token to `pending_task_nodes` **without removing it from `.tokens`**
(confirmed by direct code read, §0: `%InstanceState{instance_state | pending_task_nodes:
new_pending}` — `tokens` is untouched). If a future dispatch clause ever produced a
pending-task entry for a token *not* present in `.tokens` at the same call, this design's
map would have no entry for it — see §5's `:missing_token_record` error path, which
treats that as a genuine, typed activation failure rather than a `KeyError` crash.

---

## 4. Task-row attribute derivation

### 4.1 `instance_id`, `token_id`

`instance_id` — the same `instance_id` value the whole `persist/7` call already threads
through every other Multi step (unchanged). `token_id` — `Map.fetch(token_id_to_record_id,
token.token_id)` (§3); a `:error` result (the invariant violation just described) surfaces
as `{:error, {:missing_token_record, token.token_id}}` from this step, never a raised
`KeyError`.

### 4.2 `node_id`, `node_name`

`node_id` — `token.node_id` (the pure `Token.t()`'s own field; identical to the
`HUMAN_TASK` node's `Graph.Node.t().id`, since `dispatch_human_task/3` never moves the
token). `node_name` — the requirement text's own naming for what `tasks.node_name`
(`null: false`, req043 §4.1) holds; `Graph.Node.t()` has no `name` field, only `label`
(`String.t() | nil`, confirmed §0). This design maps `node_name` from `node.label`, with
an explicit fallback for the nullable case: **if `node.label` is `nil`, `node_name` is
`node.id`** (a node always has an `id`; `label` is the only other identifying string a
`Node.t()` carries). Flagged as this design's own resolution of a real type mismatch
(`Node.t().label :: String.t() | nil` vs `tasks.node_name`'s `null: false`), not silently
left to crash the insert changeset's `validate_required([:node_id, :node_name, ...])` at
runtime — see OQ-2 for why this fallback, rather than a hard activation error, is this
design's chosen behavior.

### 4.3 `assignee_type`, `assignee_ref` — resolved from `node.attributes`, no validation

```
@spec resolve_assignee(node :: Graph.Node.t()) ::
        {assignee_type :: String.t() | nil, assignee_ref :: String.t() | nil}
```

`assignee_ref` — `node.attributes["role"]`, the one attribute PD-05's CHK-09 (REQ-029,
confirmed §0) guarantees is present and a non-empty, trimmed string on every structurally
valid `:HUMAN_TASK` node reaching this code (a definition graph that fails CHK-09 is
rejected at `Letflow.Definitions.create/2` time, upstream of `create/2`/any future EE-04
entrypoint entirely — this design relies on that upstream guarantee rather than
re-validating it, matching REQ-047's task text: "REQ-029's PD-05 rules already guarantee a
HUMAN_TASK carries a non-empty role").

`assignee_type` — **no PD-05/CHK-09 rule constrains this value at all** (§0's own
citation: CHK-09 only inspects `"role"`). This design reads it from
`node.attributes["assignee_type"]` if present (any string value, unvalidated — this
module performs zero membership/existence checking, matching AC4's "a HUMAN_TASK whose
`assignee_ref` names a group with no members still produces a `PENDING` task"); if the key
is absent, `assignee_type` is `nil`. **This design does not invent a default non-`nil`
value** (e.g. always defaulting to `"ROLE"`) because no acceptance criterion or upstream
validator names one — flagged explicitly as OQ-1, not silently resolved. `tasks.assignee_type`
is itself a nullable, unconstrained `:string` column (req043 §4.1: "no `Ecto.Enum`, open
free-text ... no closed-set validation named by any acceptance criterion"), so a `nil`
value is a legal row, not an insert failure.

**No group-membership resolution anywhere in this function or this module (AC4).**
`resolve_assignee/1` returns whatever the two attribute values say, unconditionally — it
never queries a groups/membership table, never fails if `assignee_ref` names a group with
zero current members. This is stated as the concrete design element satisfying AC4, not
merely implied by omission.

### 4.4 `form_schema`

Not named by this run's task text or acceptance criteria as a required field this
requirement populates. `Letflow.Engine.Task.insert_changeset/2`'s cast list includes
`:form_schema` (req043 §4.4), but this design leaves it `nil` (simply omitted from the
attrs map this design builds) — no node attribute or definition-time schema is named as
its source by anything this design has read. Flagged as OQ-3, not silently guessed.

### 4.5 Full `insert_changeset/2` attrs shape

```
@spec insert_attrs(
        instance_id :: Ecto.UUID.t(),
        token_record_id :: Ecto.UUID.t(),
        token :: Token.t(),
        node :: Graph.Node.t()
      ) :: map()
```

Returns `%{instance_id: instance_id, token_id: token_record_id, node_id: token.node_id,
node_name: <§4.2>, assignee_type: <§4.3 first element>, assignee_ref: <§4.3 second
element>}` — exactly the six keys `Letflow.Engine.Task.insert_changeset/2`'s cast list
(req043 §4.4) accepts other than `:form_schema` (§4.4 above). `status` is never included —
`Letflow.Engine.Task`'s schema already defaults it to `:pending` (req043 §4.4,
`default: :pending`), and `insert_changeset/2` never casts `:status` at all (structurally
excluded, req043 §4.4) — so every row this design inserts is `PENDING` by construction,
satisfying AC1's "status PENDING" without this design needing to set it explicitly.

---

## 5. `newly_pending_tokens/2` and `append_multi/6` — the diff and the Multi step

### 5.1 The diff — resolving REQ-044's own open question (§12.3 OQ)

```
@spec newly_pending_tokens(
        previous_pending_task_nodes :: [Token.t()],
        new_pending_task_nodes :: [Token.t()]
      ) :: [Token.t()]
```

Pure, no I/O. Returns every `Token.t()` in `new_pending_task_nodes` whose `token_id` is
**not** present (by `token_id` equality, not full-struct equality) in
`previous_pending_task_nodes` — a plain set-difference keyed on `token_id`, mirroring
`Letflow.Engine.tokens_needing_dispatch/3`'s own established "diff by id, not by value"
shape (confirmed by direct read, §0). **This is the resolution of req044's own explicitly
left-open question (§12.3):** "an entry is removed from `pending_task_nodes`" is *not*
how this design tracks what's already been materialized — nothing is ever removed from
`pending_task_nodes` by this design or by `Transition`. Instead, **the persistence layer
itself remembers what it has already turned into a row**, by diffing against the
`pending_task_nodes` value that was current *immediately before* the `transition/3` call
that produced the new state. For `create/2`'s own call site (§1), "before" is the empty
list every fresh `InstanceState` starts with (`pending_task_nodes: []`,
`instance_state.ex`'s own `defstruct` default) — so **every** entry in a freshly-started
instance's `pending_task_nodes` is "newly pending" by construction, and `create/2` never
needs to pass anything other than `[]` as the "previous" argument. A future EE-04 caller
(re-entering `transition/3` against an *already-running* instance) is expected to pass
that instance's own `pending_task_nodes` value **as read at the start of its own call**
as the "previous" argument — not built by this requirement, flagged for EE-04's own
CODE-DESIGNER as the concrete contract this function establishes (§8 cross-module deps).

### 5.2 The Multi step

```
@spec append_multi(
        multi :: Ecto.Multi.t(),
        instance_id :: Ecto.UUID.t(),
        graph :: Graph.t(),
        previous_pending_task_nodes :: [Token.t()],
        new_instance_state :: InstanceState.t(),
        prefix :: String.t()
      ) :: Ecto.Multi.t()
```

Appends exactly one `Multi.run(:task_records, fn repo, changes -> ... end)` step to the
supplied `multi` (does not open a transaction itself — the caller already has one open,
matching `EventStore.append/2`'s and `SnapshotStore.create/3`'s own "append to the
caller's Multi, or run inside the caller's already-open transaction" precedent). Inside
that one `Multi.run/3` callback (algorithm shape, not literal code):

1. Compute `newly_pending = newly_pending_tokens(previous_pending_task_nodes,
   new_instance_state.pending_task_nodes)` (§5.1). If `newly_pending == []`, return
   `{:ok, []}` immediately — no query, no insert attempted (the common case for every
   `transition/3` hop that isn't a fresh `:HUMAN_TASK` arrival).
2. Otherwise, read `changes.token_record` (M2's already-committed-within-this-transaction
   result — the `Multi.t()` key this design assumes M2 is registered under, matching
   `Letflow.Engine.persist/7`'s own existing `:token_record` key name, §1) and build
   `token_id_to_record_id` (§3) from it, zipped against `new_instance_state.tokens`.
3. For each `token` in `newly_pending`, in order: resolve `node =
   find_node(graph.nodes, token.node_id)` (the same non-bang `Enum.find/2`-shaped lookup
   `Letflow.Engine.Transition.find_node/2` already uses, §0 — a `nil` result here would
   mean a pending token's own node vanished from `graph` between dispatch and this Multi
   step, structurally unreachable within one `create/2`/EE-04 call since `graph` is the
   same value throughout, but handled defensively as `{:error, {:unknown_node_id,
   token.node_id}}` rather than a `MatchError`, matching this codebase's "never raise"
   discipline); resolve `token_record_id = Map.fetch(token_id_to_record_id,
   token.token_id)`, `:error` -> `{:error, {:missing_token_record, token.token_id}}`
   (§3's invariant); build `attrs = insert_attrs(instance_id, token_record_id, token,
   node)` (§4.5); `%Task{} |> Task.insert_changeset(attrs) |> repo.insert(prefix: prefix)`.
4. Short-circuits on the first failure (`Enum.reduce_while/3`-shaped, matching
   `insert_token_records/4`'s own established short-circuit convention, §0), returning
   `{:error, reason}` for that one failure — never partial-inserts the remaining entries
   in `newly_pending` (they are rolled back along with everything else in the Multi when
   any step fails, §6).
5. On full success, returns `{:ok, inserted_task_records}` — the list of inserted
   `Letflow.Engine.Task.t()` rows, available to any later Multi step the same way M2's
   `:token_record` result already is.

---

## 6. Atomicity (EE-03 AC2, DB-03, and this run's task-visibility acceptance criterion)

**No new transaction-management mechanism is introduced.** `append_multi/6` (§5.2) only
ever appends a step to a `Multi.t()` the caller already owns; `Letflow.Engine.persist/7`
already wraps its whole four-(soon five-)step chain in one `Repo.transaction/1` call
(unchanged, §1). Adding `:task_records` as a fifth `Multi.run/3` step means Postgres
commits or rolls back **all five** steps (`instance_projections` insert, `tokens` insert,
`tasks` insert, `events` append, `instance_projections` finalize-update) as one atomic
unit — the same guarantee `Ecto.Multi`/`Repo.transaction/1` already provides for the four
steps REQ-045 shipped, extended to the fifth with no additional code beyond appending one
more `Multi.run/3` link.

**"A task must never be visible to a reader before the transition that created it is
committed" (this run's task text, EE-03 AC5) — how this is actually true, not merely
asserted:** Postgres's default `READ COMMITTED` isolation (this codebase's established
connection default — no `Repo.transaction/2` call anywhere in this design or its
precedents overrides it) means no other connection can observe any row written inside an
open, uncommitted transaction. Since the `tasks` row this design inserts (§5.2 step 3)
lives inside the exact same `Repo.transaction/1` call as every other row this Multi
writes, it becomes visible to any other reader at the exact instant the whole transaction
commits — the same instant the `instance_projections`/`tokens`/`events` rows do, never
before. No additional locking, no `SELECT ... FOR UPDATE`, no application-level "commit
flag" is needed or added — this is the standard guarantee `Ecto.Multi`/`Repo.transaction/1`
already provide, restated here as this design's explicit answer to the acceptance
criterion rather than left implicit.

**Forced event-append-failure demonstration (this run's second acceptance criterion) —
what makes it true:** if `:event` (M3, unchanged) fails (e.g. `EventStore.append/2`
returns `{:error, :unknown_event_type}` because the tenant's `event_type_registry` lacks
an `"INSTANCE_STARTED"` row, per `req045`'s own OQ-3a), `Ecto.Multi`/`Repo.transaction/1`
rolls back the **entire** transaction — `:instance_projection` (M1), `:token_record` (M2),
and the new `:task_records` step (regardless of whether `:task_records` ran before or
after `:event` in the chain, since Postgres transaction rollback is all-or-nothing across
every statement issued inside it, not merely the steps after the failing one) are all
undone together. A test demonstrating this reads `instance_projections`/`tokens`/`tasks`
back for the attempted `instance_id` after the forced failure and asserts zero rows in all
three — this design's contribution is only ensuring `:task_records` is a `Multi.run/3`
step inside the *same* `multi`/`Repo.transaction/1` call as the other four, never a
separate transaction of its own.

---

## 7. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-EE47-1 | A `tasks` row is inserted **only** for a `Token.t()` newly present in `pending_task_nodes` after a `transition/3`-driven activation — no `node.node_type == :HUMAN_TASK` re-check anywhere in this module ("the signal itself is the guard") | §2 point 1, §5.2 step 3 |
| INV-EE47-2 | Every row `append_multi/6` inserts is `PENDING` by construction (`Task`'s schema default; `status` never cast by `insert_changeset/2`) | §4.5 |
| INV-EE47-3 | Every `Token.t()` newly present in `pending_task_nodes` must also be present in `new_instance_state.tokens` at the same call — violated only if a future dispatch clause breaks `dispatch_human_task/3`'s current "append to `pending_task_nodes` without removing from `.tokens`" behavior; surfaces as `{:error, {:missing_token_record, token_id}}`, never a crash | §3, §5.2 step 3 |
| INV-EE47-4 | `assignee_type`/`assignee_ref` are copied from `node.attributes` verbatim, with zero group/role-membership resolution at activation time | §4.3 |
| INV-EE47-5 | `tasks`/`tokens`/`instance_projections`/`events` writes for one activation are one atomic `Repo.transaction/1` — no partial commit, no task row visible before every other row in the same activation is also committed | §6 |
| INV-EE47-6 | No `tenant_id` column or derivation is added to `tasks`, `tokens`, or `instance_projections` by this design (Decision 0006 D2) | §0 |
| INV-EE47-7 | `Letflow.Engine.TaskActivation` performs zero `Repo` calls of its own — every write happens inside the caller's already-open `Ecto.Multi`/transaction | §2 |

---

## 8. The END → COMPLETED path and the named SCH-03 hook

**No new logic needed for "zero tasks created."** `dispatch_end/3` (REQ-044, confirmed
§0) never appends to `pending_task_nodes` — the existing invariant this whole design
relies on (§2 point 1) already guarantees an `:END` transition produces `newly_pending ==
[]` in `append_multi/6`'s own diff (§5.1 step 1), so the `:task_records` Multi step is a
true no-op for this path, with no special-casing required.

**The status flip to `COMPLETED` is already handled** by `persist/7`'s existing `:finalize`
step (M4, unchanged, §1) — `finalize_instance_projection/4`'s `:completed` clause sets
`status: :completed, completed_at: DateTime.utc_now()`. This design adds no new logic
here either.

**The SCH-03 timer-cancellation hook — named, documented, not implemented (this run's
task text; `docs/migration/stage-3-instance-engine.md`'s S6 scope exclusion, §0):**

```
@spec cancel_pending_timers(instance_id :: Ecto.UUID.t(), prefix :: String.t()) :: :ok
```

A new function on `Letflow.Engine.TaskActivation`, called from `Letflow.Engine`'s
`finalize_instance_projection/4`'s `:completed` clause, immediately after the
`instance_projections` row's status is confirmed flipped to `:completed` inside the same
Multi step (still inside the open transaction — so a future S6 implementation that
performs a real DB write here, e.g. marking `TIMER` node rows cancelled, participates in
the same atomic commit/rollback this whole design already establishes, §6). **Its body is
specified as an unconditional `:ok` today** — no scheduler exists in Letflow yet (`S6`,
`src/scheduler/` — R-Co's own module this hook eventually replaces). The function's
`@doc`/moduledoc entry must state, verbatim in substance: *"This is the SCH-03
timer-cancellation hook (`src/scheduler/`, owned by Stage S6 — not yet built in Letflow).
An instance reaching `COMPLETED` should cancel any outstanding TIMER-node waits associated
with it; this function is the single, named call site S6's own CODE-DESIGNER should wire
real cancellation logic into, without touching `Letflow.Engine`'s or
`Letflow.Engine.TaskActivation`'s other call sites."* Naming it now — rather than leaving
the completion path with no call site at all — is this design's concrete answer to this
run's acceptance criterion ("leaves a documented named hook for SCH-03 timer cancellation
with S6 identified as its owning stage").

---

## 9. DB columns/tables touched (no schema change — reuses REQ-043/025 exactly)

| Table | Columns this design writes | Migration/schema (unchanged, cited not re-specified) |
|---|---|---|
| `tasks` | `instance_id`, `token_id`, `node_id`, `node_name`, `assignee_type`, `assignee_ref` (via `insert_changeset/2`); `status`/`id`/timestamps set by schema defaults | `priv/repo/migrations/20260818110003_create_tasks.exs`, `lib/letflow/engine/task.ex` (req043 §4) |
| `tokens` | Unchanged — `:token_record` (M2) already inserts every row this design's `token_id_to_record_id` map (§3) reads back; this design writes no new column to `tokens` | `…110002_create_tokens.exs`, `token_record.ex` (req043 §3, §5) |
| `instance_projections` | Unchanged — `:instance_projection` (M1) and `:finalize` (M4) already own every column this design's END-path reasoning (§8) depends on; this design writes no new column here | `…110001_alter_instance_projections_add_engine_columns.exs`, `instance_projection.ex` |
| `events` | Unchanged — `:event` (M3, `EventStore.append/2`) is untouched by this design | REQ-025 (unchanged) |

**No migration file is added by this requirement.** Every table and column this design
writes to already exists, shipped by REQ-023/025/043.

---

## 10. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Engine.Transition`, `Letflow.Engine.InstanceState`, `Letflow.Engine.Token` (REQ-044/050/051, shipped) | This module → those | Reads `pending_task_nodes`/`tokens` field values only; never calls `transition/3` itself (the caller, `Letflow.Engine`, already has) |
| `Letflow.Engine.TokenRecord` (req043 §5, shipped) | This module → that | `insert_attrs/4`'s `token_id` is a `TokenRecord.id` value, resolved via §3's map |
| `Letflow.Engine.Task` (req043 §4, shipped) | This module → that | `insert_changeset/2` called unchanged; this design adds no new changeset |
| `Letflow.Definitions.Graph`, `Graph.Node` (REQ-028, shipped) | This module → those | `find_node/2`-shaped lookup (§5.2 step 3), `node.attributes`/`node.label` read (§4) |
| `Letflow.Engine.persist/7` (REQ-045, shipped, **extended by this requirement**) | `Letflow.Engine` → `Letflow.Engine.TaskActivation` | Calls `append_multi/6` to append the new `:task_records` step (§5.2); the only call site this requirement adds to already-shipped code |
| Future EE-04 (task completion, not yet built) | That future requirement → `Letflow.Engine.TaskActivation` | Expected to reuse `newly_pending_tokens/2`/`append_multi/6` against its own `Ecto.Multi`, per §5.1's stated contract — not built or presupposed further than that by this design |
| S6 (`src/scheduler/`, not yet built) | S6 → `Letflow.Engine.TaskActivation.cancel_pending_timers/2` | S6's own CODE-DESIGNER replaces this function's `:ok` body; call site is this design's own contribution (§8) |

---

## 11. Open questions — explicitly listed, not silently resolved

**OQ-1 (MAJOR).** `assignee_type`'s source attribute key (`node.attributes["assignee_type"]`)
and its "no default when absent → `nil`" behavior (§4.3) are this design's own reading —
no PD-05/CHK-09 rule or acceptance criterion pins the exact key name or a required
default. Flagged for REVIEWER: should REQ-029's PD-05 gain a CHK-09-sibling check that
validates `"assignee_type"` (e.g. restricting it to `USER`/`GROUP`/`ROLE`, matching
`tasks.assignee_type`'s own column-comment vocabulary, req043 §4.1) before this
requirement ships, or is an unvalidated free-text/`nil` value acceptable at this stage
(consistent with `tasks.assignee_type`'s own column having no `Ecto.Enum`)? This design
does not answer that question — it only specifies what happens with today's validator
coverage.

**OQ-2 (MINOR).** §4.2's `node.label`-nil → `node.id`-fallback for `tasks.node_name` is
this design's own resolution of a genuine `String.t() | nil` vs `null: false` type
mismatch, not a literal instruction from any source read for this design. An alternative
(treat a `nil` label as an activation error, `{:error, {:missing_node_label, node.id}}`)
was considered and rejected here because no upstream validator (REQ-028/029) requires a
`:HUMAN_TASK` node to carry a non-nil `label` — making it a hard activation failure would
reject definition graphs REQ-030's own `create/2` pipeline already accepted as
structurally valid. Flagged for REVIEWER to confirm the fallback (not the hard-error
alternative) is the right choice.

**OQ-3 (MINOR).** `tasks.form_schema` is left `nil`/unset by `insert_attrs/4` (§4.4) —
no source read for this design names where a `:HUMAN_TASK` node's form schema would come
from at activation time (a `node.attributes["form_schema"]` key? a separate
definition-time artifact?). Flagged rather than guessed; a future requirement may need to
extend `insert_attrs/4`'s attrs map once a source is named.

**OQ-4 (MINOR, methodological).** §5.1's "previous `pending_task_nodes` is whatever the
caller passes in, and `create/2` always passes `[]`" contract is a genuine design decision
this requirement makes, not merely observed — an alternative (persisting a
"already-activated token_ids" marker somewhere durable, so a caller doesn't need to
correctly track and pass its own "before" value) was not chosen, because no such marker
exists anywhere in the already-shipped schema (`tasks` itself, keyed by `token_id`, is
arguably that marker in every case except the same-call double-activation this diff
already prevents) and inventing one would be scope beyond this requirement's own EE-01/
EE-03 boundary. Flagged for EE-04's own CODE-DESIGNER to confirm this contract is workable
once that requirement's own call shape (which `InstanceState` does it start from — freshly
reconstructed from the event log via REQ-053, or held some other way?) is known.

**OQ-5 (MINOR, methodological).** The `Letflow.Engine.TaskActivation` module name/namespace
(§2) is this design's own choice, following the `Letflow.Engine.Transition`/
`Letflow.Engine.VariableMerge` sibling-module precedent already established under
`Letflow.Engine`. No prior requirement names this exact module. Flagged for REVIEWER to
confirm or correct before EE-04 builds on top of it, matching req043 §5.1's OQ-5 precedent
for the same class of naming question.

---

## 12. Acceptance-criteria traceability

| This run's acceptance criterion | Concrete design element |
|---|---|
| "a transition that enters a HUMAN_TASK node results in exactly one tasks row with status PENDING carrying instance_id, node_id, node_name, assignee_type and assignee_ref, committed in the same transaction as the instance_projections update and the appended event" | §4.5 (`insert_attrs/4`'s full field mapping), §5.2 (the `:task_records` Multi step), §6 (same-transaction atomicity) |
| "when the event append fails, zero tasks rows and zero instance_projections changes are committed — demonstrated by forcing an append failure and reading all three tables back" | §6's forced-failure paragraph (whole-`Repo.transaction/1` rollback, all five steps together) |
| "transitions entering START, END, EXCLUSIVE_GATEWAY and PARALLEL_GATEWAY nodes create zero tasks rows, each with its own explicit test, verifying (not merely assuming) the transition function's pending_task_nodes guarantee" | §2 point 1 + §7 INV-EE47-1 (no node-type re-check; the diff (§5.1) is empty for these four dispatch clauses because `Transition`'s own code, confirmed §0, never appends to `pending_task_nodes` for them) — TEST-DESIGNER's job (not this design's) is writing the four explicit per-node-type tests this criterion calls for |
| "a HUMAN_TASK whose assignee_ref names a group with no members still produces a PENDING task rather than an activation error" | §4.3 (`resolve_assignee/1`'s explicit "no group-membership resolution anywhere" statement), INV-EE47-4 |
| "a token entering an END node sets the instance to COMPLETED, creates no task, and leaves a documented named hook for SCH-03 timer cancellation with S6 identified as its owning stage" | §8 (full section: zero-task-rows reasoning, existing `:finalize` step, `cancel_pending_timers/2`'s signature + required doc content naming S6) |
| "No implementation code (.ex/.exs bodies) — signatures and type shapes only" | Every code block in this document is a `@spec`, a field-mapping table, or an algorithm-shape description (matching `req043`/`req044`/`req045`'s own established pseudocode convention) — no function body, no `def ... do ... end` with real logic anywhere in this document |
