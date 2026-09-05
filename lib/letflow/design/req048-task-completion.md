PROVENANCE (historical, not current decision authority):
# Design: REQ-048 — Task completion (`instance.zig` `completeTask`, EE-04)

**Requirement:** REQ-048 (`docs/requirements.yaml`, stage S3, per this run's handoff
`context.requirement_text`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ048-20260818`, WF-02 Step 1
**This document produces:** `Letflow.Engine.complete_task/3`'s public signature, the new
`{:complete_task, token_id}` event constructor and dispatch clause this requirement adds to
the already-shipped `Letflow.Engine.Transition` (REQ-044/050/051), the token-record
reconciliation function this requirement adds to `Letflow.Engine`, the `Ecto.Multi` shape,
the row-level locking protocol, DB columns touched, invariants, cross-module dependencies,
and every acceptance criterion mapped to a concrete design element. No implementation code —
signatures/shapes only, matching `req043`/`req044`/`req045`/`req047`'s own convention.

---

## 0. Sources read for this design

- This run's handoff — `context.requirement_text` (REQ-048's full description) and
  `task.acceptance_criteria`, per `core-directives.md`'s "Load Scoped Context, Not Whole
  Files."
- `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1's procedure.
- `docs/guides/backend_developer_guide.md` — coding conventions (`:gen_statem` vs. plain
  Ecto §3.2, error-shape §3.5, SQL-locking-via-Ecto-not-raw-string §3.6).
- `docs/migration/stage-3-instance-engine.md` — EE-04's place in the EE-01..EE-12
  breakdown, the S4 HTTP/S4-auth scope boundary this requirement's own text restates, and
  confirmation that REQ-048 depends only on REQ-047/REQ-049 (not REQ-053 state
  reconstruction or REQ-054 snapshot persistence, both still `pending` — load-bearing for
  §6/§11 below).
- `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md` — D2: no
  `tenant_id` column/derivation added to `tasks`, `tokens`, `instance_projections`,
  `events` by this design (none of the four tables this design writes gets a new column).
- `lib/letflow/design/req043-instance-engine-schema.md`, `req044-transition-kernel.md`,
  `req045-instance-start-engine-shell.md`, `req047-task-activation-persistence.md`,
  `req049-variable-merge.md`, `req050-exclusive-gateway-cel.md`,
  `req051-parallel-gateway-split-join.md` — the six already-shipped designs this one
  extends or reuses without modification.
- `lib/letflow/engine.ex` (full, current `main`) — `create/2`, `persist/8` (re-verified
  its actual arity directly against the shipped `defp persist(...)` header during rework —
  the first submission of this document mis-cited it as `persist/7`),
  `advance_until_stable/4`, `tokens_needing_dispatch/3`, `insert_token_records/4`,
  `finalize_instance_projection/4`. Read directly, not paraphrased, since this design
  extends this exact code.
- `lib/letflow/engine/transition.ex` (full) — `transition/3`'s dispatch table, the
  `transition_event`/`transition_error` type unions, `dispatch_human_task/3`'s exact
  "arrival, no automatic outgoing traversal" behavior (load-bearing for §2 below —
  confirms `{:advance_token, token_id}` cannot be reused to move a token *off* a
  `:HUMAN_TASK` node, since dispatch routes purely on `node.node_type`), and
  `dispatch_exclusive_gateway/4`'s declared-order/default-last/CEL-condition algorithm
  (reused, not duplicated, by this design's new dispatch clause).
- `lib/letflow/engine/task.ex` — `Task.complete_changeset/2` (already shipped by REQ-043,
  unused until now: casts `:status`, `:output_variables`, `:completed_by`, `:completed_at`,
  `:cancelled_at`; `instance_id`/`token_id`/`node_id`/`node_name` structurally not
  castable).
- `lib/letflow/engine/token_record.ex` — `TokenRecord.advance_changeset/2` (already
  shipped, unused until now: casts `:node_id`, `:status`, `:waiting_child_instance_id`,
  `:completed_at`, `:cancelled_at`).
- `lib/letflow/engine/instance_state.ex`, `token.ex`, `join_counter.ex` — the pure structs
  this design reconstructs a scoped instance of (§6).
- `lib/letflow/engine/variable_merge.ex` — `merge/3`'s exact contract, in particular that
  `variable_validations: nil` makes every key default to `:ok`, so the `:rejected` branch
  is provably unreachable when this design calls it that way (§7).
- `lib/letflow/event_store.ex` — `append/2`'s attrs/opts shape and error taxonomy, reused
  unchanged for the `TASK_COMPLETED` append (§9).
- `lib/letflow/event_store/instance_projection.ex` — `InstanceProjection.update_changeset/2`
  (already shipped, reused for §8's projection reconciliation).
- `lib/letflow/definitions/snapshot_store.ex` — `get_by_instance_id/2` (already shipped,
  not `create/3` — this design reads the immutable snapshot captured at `create/2` time, it
  never creates a new one).
- `lib/letflow/definitions/graph.ex` — `Node`/`Edge` struct shape, `Graph.from_map/1`.
- `docs/agents/instructions/security-invariants.md` (INV-7 no raw-SQL interpolation, INV-8
  no bare `{:ok, _} =` on externally-reachable input) — both load-bearing for §5/§12.

---

## 1. What already exists, and what this requirement adds

**Already shipped, reused unchanged:**

| Module | What this design calls, unchanged |
|---|---|
| `Letflow.Engine.Task` | `complete_changeset/2` (§8) |
| `Letflow.Engine.TokenRecord` | `advance_changeset/2` (§8) |
| `Letflow.Engine.InstanceState`, `Letflow.Engine.Token`, `Letflow.Engine.JoinCounter` | Pure structs this design's reconstruction (§6) builds instances of |
| `Letflow.Engine.VariableMerge` | `merge/3` (§7) |
| `Letflow.Engine.TaskActivation` | `newly_pending_tokens/2` and `insert_attrs/4` (both already public — §9), reused unchanged. **`append_multi/6` itself is NOT reused** — see §9's revised design and §13 OQ-2b for why, re-derived from the shipped code rather than assumed |
| `Letflow.Definitions.SnapshotStore` | `get_by_instance_id/2` (§6.1) |
| `Letflow.EventStore` | `append/2` (§10) |
| `Letflow.EventStore.InstanceProjection` | `update_changeset/2` (§8) |
| `Letflow.TenantProvisioning` | `tenant_id_for_schema_name/1` (§4, same pre-transaction validation `create/2`/`append/2` already perform) |
| `Letflow.Engine.tokens_needing_dispatch/3`, `Letflow.Engine.advance_until_stable/4` | Reused **directly** (both already `Letflow.Engine`-private, and `complete_task/3` is added to that same module, §2) to drive the multi-hop worklist after the first, `complete_task`-specific hop |

**New in this requirement:**

1. `Letflow.Engine.Transition` gains one new `transition_event` constructor,
   `{:complete_task, token_id}`, and one new private dispatch clause,
   `dispatch_task_completion/4` (§5) — exactly the extension point that module's own
   moduledoc names in advance ("every later EE-* requirement that needs its own event
   shape adds its own tagged-tuple constructor to this same union").
2. `Letflow.Engine` gains `complete_task/3` (§3) plus three new private helpers: the
   scoped-reconstruction function (§6), the token-record reconciliation function (§8.2),
   and the projection reconciliation function (§8.3) — all new, none replacing existing
   `create/2` logic.
3. `Letflow.Engine.TaskActivation` gains one new **public** function,
   `append_multi_from_existing_records/6` (§9) — REQ-048's own "newly-pending HUMAN_TASK"
   Multi step. **`append_multi/6` itself is left completely unmodified** — this is an
   addition alongside it, not a change to it or to `create/2`'s own call site. Disclosed
   as a genuine new design decision at §13 OQ-2b (rework of this design's original,
   incorrect "reused exactly unchanged" claim — see that section for the full
   re-derivation against the shipped code).
4. No new migration, no new table, no new column.

---

## 2. Why `complete_task` cannot reuse `{:advance_token, token_id}`

Confirmed by direct read (§0): `dispatch_node/4` routes purely on
`find_node(definition_snapshot.nodes, token.node_id).node_type` — the node the token is
**currently sitting on**. A `PENDING` task's token sits on the `:HUMAN_TASK` node itself
(that is what "pending" means at the token-position level — `dispatch_human_task/3`
already ran once, when the token *arrived*, and left `node_id` unchanged). Calling
`transition(graph, instance_state, {:advance_token, token_id})` again on that same token
would re-dispatch to `dispatch_human_task/3` a second time — re-appending the same token to
`pending_task_nodes` and never moving it. There is no existing event/dispatch path in
`Transition` for "this token's `:HUMAN_TASK` is done, move it along its outgoing edge(s)" —
this is the actual reason EE-04 needs its own event constructor, not merely a design
preference.

---

## 3. `Letflow.Engine.complete_task/3` — public signature

```
@type complete_attrs :: %{
        required(:output_variables) => map(),
        required(:actor_id) => Ecto.UUID.t(),
        required(:idempotency_key) => String.t()
      }

@type complete_opts :: [prefix: String.t()]

@type complete_error ::
        {:error, :invalid_output_variables}
        | {:error, :invalid_schema_name}
        | {:error, :task_not_found}
        | {:error, {:task_not_pending, status :: :completed | :cancelled}}
        | {:error, :instance_not_found}
        | {:error, {:instance_not_active, status :: :completed | :cancelled | :error}}
        | {:error, :snapshot_not_found}
        | {:error, {:graph_structure_invalid, term()}}
        | {:error, {:missing_token_record, token_id :: Ecto.UUID.t()}}
        | {:error, {:transition_failed, Transition.transition_error()}}
        | {:error, {:new_token_during_resume_not_supported, token_id :: String.t()}}
        | {:error, {:task_activation_failed, term()}}
        | {:error, {:event_append_failed, term()}}
        | {:error, :missing_actor_id}
        | {:error, :missing_idempotency_key}
        | {:error, Ecto.Changeset.t()}
        | {:error, term()}

@type complete_result :: %{
        task_id: Ecto.UUID.t(),
        instance_id: Ecto.UUID.t(),
        instance_status: :active | :completed,
        current_nodes: [String.t()],
        variables: map(),
        completed_at: DateTime.t()
      }

@spec complete_task(
        task_id :: Ecto.UUID.t(),
        attrs :: complete_attrs(),
        opts :: complete_opts()
      ) :: {:ok, complete_result()} | complete_error()
```

`task_id` is a separate positional argument (not folded into `attrs`), matching this run's
task text framing ("Accepts a task_id and an output_variables map") — `attrs` carries the
payload (`output_variables`, plus `actor_id`/`idempotency_key`, plumbed straight through to
`EventStore.append/2`'s own identical requirement, same non-pre-validated pass-through
`create/2` already established, §0).

**`output_variables` validation (AC2) — pre-transaction, zero DB writes attempted on
failure**, mirroring `create/2`'s `fetch_initial_variables/1`:

```
@spec fetch_output_variables(complete_attrs()) :: {:ok, map()} | {:error, :invalid_output_variables}
```

`Map.get(attrs, :output_variables)` must be present and a plain map (`is_map/1` and not
`is_struct/1`, same guard shape `EventStore.validate_metadata/1` already uses, §0) — `%{}`
is explicitly valid (AC2, EE-04 AC5). `nil`, a missing key, or a non-map/struct value all
collapse to the same `{:error, :invalid_output_variables}` — this run's acceptance
criteria require `nil` to be **distinct from the not-found/not-pending errors** (AC3), not
distinct from "missing entirely"; collapsing those two sub-cases into one atom is this
design's own choice, flagged as OQ-1 (§13).

---

## 4. Pre-transaction phase (no I/O attempted on failure)

Algorithm shape (matching `create/2`'s own pre-transaction `with` chain, §0), not literal
code: `complete_task/3` first resolves `opts[:prefix]`, then runs two checks in order,
short-circuiting on the first failure, **before** any `Ecto.Multi`/`Repo.transaction/1`
opens —

1. `fetch_output_variables/1` (§3) against `attrs`.
2. `TenantProvisioning.tenant_id_for_schema_name/1` against `prefix` — the same
   schema-name-shape validation `create/2`/`EventStore.append/2` already perform at this
   same point in their own call sequence.

Only once both succeed does the function proceed to open the `Ecto.Multi` (§8). This
mirrors `EventStore.append/2`'s own "registry and metadata validation run before the
transaction opens" discipline (design doc precedent cited in that module's moduledoc,
§0).

---

## 5. `Letflow.Engine.Transition` extension — `{:complete_task, token_id}`

**Extends the already-shipped, gate-approved `transition_event` union** (REQ-044/050/051)
by exactly one constructor, per that module's own stated extension contract (§0):

```
@type transition_event ::
        {:advance_token, token_id :: String.t()}
        | {:cancel_branch, branch_id :: String.t()}
        | {:complete_task, token_id :: String.t()}
```

`transition/3`'s top-level event dispatch gains one new clause, structurally identical in
shape to the existing `{:advance_token, token_id}` clause's own token/node resolution
(look up the token by `token_id` via `find_token/2`, `{:error, {:unknown_token_id, _}}` on
a miss; then look up that token's current node via `find_node/2`,
`{:error, {:unknown_node_id, _}}` on a miss), but on a successful double lookup it
dispatches to a **new** private function instead of the existing `dispatch_node/4`:
`dispatch_task_completion(definition_snapshot, instance_state, token, node)`.

**New private dispatch clause:**

```
@spec dispatch_task_completion(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
        {:ok, InstanceState.t(), [pending_event()]}
        | {:error, {:token_not_at_human_task, node_type :: atom(), node_id :: String.t()}}
        | {:error, {:no_matching_edge, node_id :: String.t(), evaluated_conditions :: [evaluated_condition()]}}
```

Behavior (algorithm shape, not literal code):

1. If `node.node_type != :HUMAN_TASK`, return
   `{:error, {:token_not_at_human_task, node.node_type, node.id}}` — a defensive guard
   against a stale/mismatched `task.token_id`↔`token_record.node_id` pairing (§6.3's own
   invariant should make this unreachable, kept for the same "never raise" totality reason
   `dispatch_start/4`'s own `nil`-edge branch is kept, §0).
2. Otherwise, **reuse `dispatch_exclusive_gateway/4`'s exact declared-order,
   default-last, CEL-condition algorithm** (§0 — the same private helper
   `evaluate_conditioned_edges/2` and the same `advance_token/3` helper `transition.ex`
   already defines), applied to `node`'s own outgoing edges instead of an
   `:EXCLUSIVE_GATEWAY`'s. This is this design's concrete answer to the requirement text's
   "evaluate outgoing edge conditions via REQ-044/REQ-050" bullet — a `:HUMAN_TASK` node's
   own outgoing edges may legitimately carry CEL conditions (no CHK-0x rule in REQ-028/029
   restricts condition-bearing edges to `:EXCLUSIVE_GATEWAY` sources only, confirmed §0),
   modeling a human decision's routing the same way an automated gateway's is modeled. A
   `:HUMAN_TASK` with exactly one, unconditioned outgoing edge (the common case) still
   works correctly: `evaluate_conditioned_edges/2` on an edge list with no `condition`
   value present degrades to "the one default/unconditioned edge wins," matching
   `dispatch_start/4`'s own simpler "first outgoing edge" behavior for that common case.
3. **Never appends to `pending_task_nodes`** — unlike `dispatch_human_task/3`, this clause
   only moves the token (via the reused `advance_token/3`); `pending_task_nodes` is
   untouched by this hop, exactly like `dispatch_start/4`/`dispatch_exclusive_gateway/4`.

`dispatch_task_completion/4` never changes `Transition`'s purity/determinism contract
(§0's moduledoc sections 1-2) — same "no `Repo`, no clock, no randomness" bar, verified by
the same `grep` command that module's moduledoc already documents.

---

## 6. Scoped state reconstruction — the new, load-bearing piece this design contributes

**Why this is needed, and why it is legitimately in scope despite REQ-053 (EE-11, full
event-log reconstruction) and REQ-054 (snapshot persistence) both being `pending`:**
`transition/3` requires a full `InstanceState.t()` to dispatch one hop. REQ-048's own
`depends_on` is `[REQ-047, REQ-049]` only (§0) — it does **not** wait for REQ-053. This
design therefore builds the **narrowest state view sufficient for one dispatch hop-chain
seeded from a single completing task**, directly from the already-durable `tasks`,
`tokens`, and `instance_projections` rows — not a general point-in-time event-log replay
(that remains REQ-053's job). This is a deliberate, narrower capability than REQ-053 will
eventually provide, flagged as MAJOR OQ-2 (§13) for REVIEWER: it is new non-trivial
state-machine logic not spelled out verbatim by the requirement text's own bullet list.

### 6.1 Definition snapshot

```
@spec fetch_graph(instance_id :: Ecto.UUID.t(), prefix :: String.t()) ::
        {:ok, Graph.t()} | {:error, :snapshot_not_found} | {:error, {:graph_structure_invalid, term()}}
```

`SnapshotStore.get_by_instance_id/2` (already shipped, §0) → `Graph.from_map/1` on its
`.graph` field — the **same immutable snapshot** `create/2` captured at instance-start
time, never a live re-read of `process_definitions` (a defined process must not change
shape mid-flight for an already-running instance — this is what `instance_definition_
snapshots` exists for, per REQ-027/033).

### 6.2 Active tokens

```
@spec load_active_tokens(instance_id :: Ecto.UUID.t(), prefix :: String.t()) :: [TokenRecord.t()]
```

Every `TokenRecord` row with `instance_id == instance_id and status == :active`
(`req043` §3.2's own status enum) — **not** filtered to just the completing task's own
token, because `Transition.dispatch_end/3`'s "instance becomes `:completed` iff no token
remains live" check (§0) needs the instance's *full* live token set to decide correctly:
loading only the one completing token would make a `PARALLEL_GATEWAY`-split instance's
still-running sibling branches invisible to this call, wrongly completing the instance the
moment *this* branch reaches `:END`. Mapped 1:1 to pure `Token.t()` values:

```
@spec to_pure_token(TokenRecord.t()) :: Token.t()
```

`token_id: to_string(record.id)` (the `TokenRecord`'s own DB-generated UUID, stringified —
**not** a newly reconstructed "domain" token id; nothing in a later call needs to match a
transient id minted during a different, already-completed `create/2` call, so re-using the
row's own stable primary key as this call's `token_id` is sufficient and simplest),
`node_id: record.node_id`, `branch_id: record.branch_id`,
`waiting_child_instance_id: record.waiting_child_instance_id`.

### 6.3 Locating the completing task's own token

```
@spec find_token_for_task(Task.t(), [Token.t()]) ::
        {:ok, Token.t()} | {:error, {:missing_token_record, Ecto.UUID.t()}}
```

`Enum.find(tokens, &(&1.token_id == to_string(task.token_id)))` — a `nil` result is a
genuine invariant violation (`tasks.token_id` FK-references `tokens.id`, req043 §4.1; a
row this design's own `:task` Multi step (§8.1) just locked and read `PENDING` from must
have a live, `:active` `tokens` row) and surfaces as `{:error, {:missing_token_record,
task.token_id}}`, never a `MatchError` — same defensive-but-typed shape REQ-047's own
`fetch_token_record_id/2` (§0) already establishes for the mirror-image lookup.

### 6.4 Pending-task tokens (for §9's `append_multi_from_existing_records/6`'s "previous" argument)

```
@spec load_pending_task_tokens(instance_id :: Ecto.UUID.t(), prefix :: String.t()) :: [Token.t()]
```

Every `Task` row with `instance_id == instance_id and status == :pending` (including the
one about to be completed by this call — it is still `PENDING` at read time, before this
Multi's own `:task_complete` step, §8.1, runs), mapped to a **minimal** `Token.t()` — only
`token_id: to_string(row.token_id)` is populated (`node_id`/`branch_id` left at their
struct defaults, unused). This is sufficient because `TaskActivation.newly_pending_tokens/2`
diffs **by `token_id` equality only** (§0, req047 §5.1, confirmed by direct code read) —
no other field of these entries is ever read by `newly_pending_tokens/2` or by §9's
`append_multi_from_existing_records/6`.

**Why this "previous" set must include the completing task's own token, not exclude it**
(this design's own resolution of REQ-047 §5.1's forward-looking OQ-4, §0): nothing in
`Transition` or this design removes an entry from `pending_task_nodes` once added (§0,
req047 §5.1's own confirmed invariant) — the completing task's token therefore remains in
`final_instance_state.pending_task_nodes` after this call's hop-chain, unchanged. Passing
it as part of "previous" too means `newly_pending_tokens/2`'s diff correctly excludes it
(present in both sides, by `token_id`), so §9's function never tries to re-insert a
`tasks` row for a task that already has one.

### 6.5 Assembling the seed `InstanceState.t()`

```
@spec build_instance_state(InstanceProjection.t(), [Token.t()], [Token.t()]) :: InstanceState.t()
```

```
%InstanceState{
  instance_id: projection.instance_id,
  status: :active,                      # see §11 OQ — projection.status already
                                         # verified :active by §8.1's own guard
  tokens: active_tokens,                # §6.2
  variables: projection.variables,      # pre-merge; §7 merges into a new value,
                                         # never mutates this struct in place
  pending_task_nodes: pending_task_tokens,  # §6.4
  join_counters: %{}                    # ALWAYS empty — see §11 OQ-3, the known gap
}
```

`join_counters: %{}` is **always** empty in this design, because no table persists
`JoinCounter` state across calls today (REQ-051 only wired split/join into `create/2`'s
own single in-memory pass; REQ-054's `instance_state_snapshots` — the table that would
carry this — is `pending`). **Concrete consequence, stated explicitly rather than
silently accepted:** if this call's hop-chain reaches a `:PARALLEL_GATEWAY` join node,
`dispatch_parallel_join/4`'s `with %JoinCounter{} <- Map.get(instance_state.join_counters,
node.id)` fails (no entry, ever) and `transition/3` returns
`{:error, {:unknown_branch_id, token.branch_id}}` — a typed, non-crashing failure, not
silent data corruption, but also not a supported scenario for this requirement. Flagged as
MAJOR OQ-3 (§13), explicitly deferred to whichever requirement first persists join-counter
state (REQ-053/054 territory).

---

## 7. Variable merge (EE-09, REQ-049)

```
merge_result = VariableMerge.merge(seed_instance_state.variables, output_variables, nil)
```

Called with `variable_validations: nil` — **this design does not wire any schema
validation into `output_variables` before merging** (no acceptance criterion or source
read for this design names one; `Letflow.EventStore.Registry.validate_payload/3` exists
but is not invoked here). Consequence, stated precisely (not left implicit): with
`variable_validations: nil`, `merge/3`'s `find_rejection/2` (§0) always finds `:ok` for
every key, so **the `{:rejected, ...}` branch of `merge_result :: VariableMerge.
merge_result()` is provably unreachable in this design** — `merge/3` always returns
`{:ok, new_variables, merge_events}` when called this way. This design therefore pattern-
matches only that shape; no `complete_error()` variant exists for a rejected merge.
Flagged as MINOR OQ-4 (§13): whether a future requirement should wire real schema
validation into this path (mirroring `EventStore.append/2`'s own registry check) is left
open, not silently decided either way.

`merge_events` (`{:variable_overwritten, key, old, new}` tuples) are **not** persisted as
their own separate event rows — AC1 requires "appends **exactly one** TASK_COMPLETED
event." This design embeds `merge_events` as informational metadata inside the
`TASK_COMPLETED` event's own JSON payload (§10), rather than discarding them or violating
the "exactly one append" acceptance criterion.

---

## 8. The `Ecto.Multi` — one transaction (AC1, AC4)

All of the following run inside **one** `Ecto.Multi` / `Repo.transaction/1` call, matching
`create/2`'s and `EventStore.append/2`'s own established shape (§0):

| Step key | What it does | Reads from |
|---|---|---|
| `:task` (M1) | Row-lock + fetch the `tasks` row by `task_id` (`lock: "FOR UPDATE"`); `nil` → `:task_not_found`; `status != :pending` → `{:task_not_pending, status}` | — |
| `:instance_projection` (M2) | Row-lock + fetch the `instance_projections` row by `M1.instance_id` (`lock: "FOR UPDATE"`); `nil` → `:instance_not_found` (defensive); `status` not `:active` → `{:instance_not_active, status}` (defensive) | M1 |
| `:snapshot_and_state` (M3) | §6.1-§6.5: fetch snapshot/graph, load active tokens, locate this task's own token, load pending-task tokens, assemble seed `InstanceState.t()` | M1, M2 |
| `:merge` (M4) | `VariableMerge.merge/3` (§7) — pure | M2 (`.variables`) |
| `:transition` (M5) | `Transition.transition(graph, seed_state_with_merged_variables, {:complete_task, own_token_id})`, then the **existing** `advance_until_stable/4`/`tokens_needing_dispatch/3` loop (reused unchanged, §1) for every subsequent `{:advance_token, ...}` hop, until the worklist empties or the same defensive hop-limit `create/2` already uses fires | M3, M4 |
| `:task_records` (M6) | `TaskActivation.append_multi_from_existing_records/6` (§9, **new function**) — appends new `tasks` rows for any freshly-reached `:HUMAN_TASK` node(s), reading only its own explicit arguments, not `changes` | M3 (`previous_pending_task_nodes`), M5 (`new_instance_state`) — **not** any preceding Multi step's `changes` (§9) |
| `:token_reconciliation` (M7) | §8.2 — advances/completes existing `tokens` rows to match `M5`'s final token positions | M3 (original active-token map), M5 |
| `:task_complete` (M8) | `Task.complete_changeset/2` on `M1`'s own row: `status: :completed, completed_by: attrs.actor_id, completed_at: <minted once, §8.4>, output_variables: output_variables` (the caller's **original**, unmerged map — the task's own record of what it submitted) | M1, ctx |
| `:event` (M9) | `EventStore.append/2` — `TASK_COMPLETED` (§10) | M1, M4, M5, ctx |
| `:projection` (M10) | §8.3 — updates `instance_projections.status`/`current_nodes`/`variables`/`completed_at` from `M5`'s final state | M2, M5 |

Ordering rationale: `:task`/`:instance_projection` lock first (deterministic order — always
`tasks` before `instance_projections`, never the reverse, across every call site, to avoid
a lock-ordering deadlock between two `complete_task` calls on two different tasks of the
same instance); `:merge`/`:transition` are pure and cannot fail on I/O; `:task_records`
(§9) has **no** ordering dependency on `:token_reconciliation` (M7) or any other step's
`changes` — unlike `persist/8`'s own `:task_records` step, which must run after its
`:token_record` step for the FK zip (§0), this call's `:task_records` step is
self-contained (§9) and is placed here purely to keep this table's step order legible and
comparable to `persist/8`'s own, not because anything requires it; `:event` (M9) needs
`:task`'s `instance_id` and the final merged variables/instance status for its payload;
`:projection` (M10) runs last, mirroring `persist/8`'s `:finalize` step's own "last, after
the event append succeeded" position.

### 8.1 `:task`/`:instance_projection` locking (EE-12, AC4)

```
Task
|> where([t], t.id == ^task_id)
|> lock("FOR UPDATE")
|> Repo.one(prefix: prefix)
```

Ecto's `lock/2` query composition (never a hand-written `SELECT ... FOR UPDATE` string —
INV-7). **This is what serializes two concurrent `complete_task/3` calls on the same
`task_id` (AC4):** the second transaction's `Repo.one/2` on this locked query blocks until
the first transaction commits or rolls back; when it proceeds, it re-reads the row's
`status` **under its own lock**, sees `:completed` (the first call's own `:task_complete`
step already committed), and returns `{:task_not_pending, :completed}` — never a second
`:completed` write, never a torn/interleaved read. `instance_projections` is locked the
same way, by `instance_id`, immediately after — broader than AC4's literal single-task
scenario requires, but necessary for this design's own correctness: `M10` writes
`current_nodes`/`variables` to this row, and without a lock a second `complete_task` call
against a **different** task of the **same** instance, running concurrently, could commit
a lost update. Locking `tokens` rows (M3's read) is **not** added by this design — flagged
as MINOR OQ-5 (§13), left for REQ-055's own general EE-12 concurrency requirement to decide
whether it's needed beyond what `task`/`instance_projections` locking already provides for
this specific call shape.

### 8.2 Token-record reconciliation — new function

```
@spec reconcile_token_records(
        multi :: Ecto.Multi.t(),
        original_active_tokens :: [TokenRecord.t()],
        final_instance_state :: InstanceState.t(),
        prefix :: String.t()
      ) :: Ecto.Multi.t()
```

Appended as its own `Multi.run(:token_reconciliation, ...)` step (§8). Algorithm, keyed by
comparing `original_active_tokens` (§6.2, each already a durable row with `id`/`node_id`)
against `final_instance_state.tokens` (§6.5's `Token.t()` list, post-`transition`, each
`token_id` still `to_string(record.id)` for every token this design's dispatch merely
*moved* — §6.2's own stated invariant):

1. For each `original` record whose `to_string(record.id)` **is** present in
   `final_instance_state.tokens` (by `token_id`) **and** whose `node_id` differs from that
   entry's `node_id` → `TokenRecord.advance_changeset/2` with `node_id: <new value>`
   (an ordinary position advance — the common case for the completing task's own token,
   and for any other already-running branch this hop-chain happens not to touch, which is
   simply absent from this "changed" subset and left alone).
2. For each `original` record whose `to_string(record.id)` is **absent** from
   `final_instance_state.tokens` entirely → `TokenRecord.advance_changeset/2` with
   `status: :completed, completed_at: <same instant minted at §8.4>` (consumed by `:END`
   or by a join firing, §0's `dispatch_end/3`/`dispatch_parallel_join/4`).
3. For each `token_id` present in `final_instance_state.tokens` that does **not** match
   any `original` record's `to_string(id)` → **not implemented by this design.** Returns
   `{:error, {:new_token_during_resume_not_supported, token_id}}`, short-circuiting the
   whole step (and therefore the whole transaction, rolled back). This is the concrete,
   typed answer to "a `:PARALLEL_GATEWAY` split reached during this call's own hop-chain" —
   explicitly flagged as MAJOR OQ-2's companion case (§13), not silently mis-persisted.
4. Every branch short-circuits on the first changeset failure
   (`Enum.reduce_while/3`-shaped, matching `insert_token_records/4`'s own established
   convention, §0).

### 8.3 Projection reconciliation — new function

```
@spec reconcile_instance_projection(
        multi :: Ecto.Multi.t(),
        instance_id :: Ecto.UUID.t(),
        prefix :: String.t()
      ) :: Ecto.Multi.t()
```

`Multi.run(:projection, fn repo, %{instance_projection: projection, transition: final_state} -> ... end)`
— `InstanceProjection.update_changeset/2` (already shipped, §0) with:

```
%{
  status: final_state.status,          # :active or :completed (never :cancelled/:error
                                        # from this call — Transition's dispatch clauses
                                        # this design's hop-chain can reach never produce
                                        # those from a :complete_task-seeded call)
  current_nodes: Enum.map(final_state.tokens, & &1.node_id),
  variables: final_state.variables,    # the merged map (§7)
  completed_at: <set iff status just became :completed, same pattern
                 finalize_instance_projection/4's :completed clause already uses, §0>
}
```

`last_event_seq` is **not** set here — `EventStore.append/2`'s own `M6`
(`update_projection/3`, §0) already advances it as part of the `:event` step (M9, §8), the
same "append/2 owns `last_event_seq`, the engine owns everything else" division `persist/8`
already establishes and this design does not disturb.

### 8.4 `completed_at` — minted once

Exactly one `DateTime.utc_now() |> DateTime.truncate(:microsecond)` call, in the
pre-`Multi` context-building step (mirroring `EventStore.append/2`'s own `ctx.created_at`,
§0) — bound identically into `:task_complete` (M8)'s `completed_at`,
`:token_reconciliation` (M7)'s per-record `completed_at` (where applicable), and
`:projection` (M10)'s `completed_at` (where applicable). Prevents the exact
two-independent-clock-reads class of bug `EventStore.append/2`'s own moduledoc already
documents R-Co having shipped and fixed for `event_id`/`created_at` (§0, INV-EV-5) —
applied here to `completed_at` instead.

---

## 9. Task activation — new adapter function, `TaskActivation.append_multi_from_existing_records/6`

**Correction from this design's first submission (CODE-DESIGN-VALIDATOR rework, iteration
1):** the first submission of this document claimed `TaskActivation.append_multi/6` (§0)
is reused "exactly" and "unmodified" as this Multi's `:task_records` step. Re-verified
directly against the shipped code (`lib/letflow/engine/task_activation.ex:140-165`,
`lib/letflow/engine.ex`'s `persist/8`) rather than re-asserted: that claim is **wrong**,
and reusing `append_multi/6` as-is would crash on REQ-048's own main success path. The
actual shipped body is:

`append_multi/6`'s `Multi.run(:task_records, fn repo, changes -> ... end)` callback, on
the non-empty branch, calls `token_records = Map.fetch!(changes, :token_record)` and then
`token_id_to_record_id(new_instance_state.tokens, token_records)` — a **positional
`Enum.zip/2`** of `new_instance_state.tokens` against a same-order list of freshly
**inserted** `TokenRecord.t()` structs. The `:token_record`-keyed `changes` entry it reads
is produced by exactly one place in the whole codebase: `Letflow.Engine.persist/8`'s own
preceding `Multi.run(:token_record, fn repo, _changes -> insert_token_records(repo,
instance_id, new_instance_state.tokens, prefix) end)` step (`engine.ex`, confirmed §0),
which inserts a **brand-new row per token** — the `create/2` call's own root/branch tokens,
never seen by the database before.

REQ-048's Multi never produces a `:token_record`-keyed step (§8's step table has none), and
structurally can't the way `append_multi/6` needs it: REQ-048's tokens are **pre-existing**
rows being advanced/reconciled by this design's own `:token_reconciliation` step (M7, §8.2)
— never freshly inserted the way `insert_token_records/4` does at instance-start. Calling
`append_multi/6` unmodified from this Multi would hit `Map.fetch!(changes, :token_record)`
against a `changes` map with no such key, raising `KeyError` on the ordinary AC1 success
path (any hop-chain that reaches a newly-pending `:HUMAN_TASK` node) — not an edge case.

**Fix (validator's option (b) — a new, genuinely compatible adapter, not a modification to
the already-shipped `append_multi/6`):** `Letflow.Engine.TaskActivation` gains one new
public function, alongside `append_multi/6` (that function is left completely untouched,
so `create/2`'s own call site is unaffected):

```
@spec append_multi_from_existing_records(
        multi :: Ecto.Multi.t(),
        instance_id :: Ecto.UUID.t(),
        graph :: Graph.t(),
        previous_pending_task_nodes :: [Token.t()],
        new_instance_state :: InstanceState.t(),
        prefix :: String.t()
      ) :: Ecto.Multi.t()
```

**Why no `:token_record`-style FK lookup is needed here at all** (not merely "resolved a
different way" — genuinely unnecessary): every `Token.t()` this design's own `transition`
step (M5) can ever produce already carries, as its `token_id`, the stringified `id` of an
**existing** `TokenRecord` row — §6.2's own reconstruction invariant
(`token_id: to_string(record.id)`), and §8.2 point 3's own explicit refusal to persist any
token this design's dispatch mints fresh mid-resume
(`{:new_token_during_resume_not_supported, _}`). So for every `Token.t()` this new
function is ever asked to materialize a `tasks` row for, `token.token_id` **is already**
the `tasks.token_id` FK value this design needs — no positional zip against a
freshly-inserted list, and therefore no `:token_record`-keyed Multi step, is required.

Algorithm shape (matching `append_multi/6`'s own structure, minus the FK-map step it no
longer needs):

1. Appends one `Multi.run(:task_records, fn repo, _changes -> ... end)` step to `multi` —
   still keyed `:task_records` (same key name `TaskActivation.append_multi/6` uses, so
   REQ-048's own step table (§8) reads identically to `persist/8`'s), but this callback
   reads **nothing** from `changes` — it is now a self-contained computation, so unlike
   the original `:task_records` step this one has **no ordering dependency** on any
   preceding Multi step's output (§8's table note updated accordingly).
2. `newly_pending = newly_pending_tokens(previous_pending_task_nodes,
   new_instance_state.pending_task_nodes)` — `TaskActivation.newly_pending_tokens/2`,
   called exactly as-is, unmodified (§0's pure diff function, reused genuinely unchanged
   this time).
3. `[]` → `{:ok, []}` immediately, same fast path `append_multi/6` already has.
4. Otherwise, for each `token` in `newly_pending`, in order:
   a. `Ecto.UUID.cast(token.token_id)` — a `:error` result here means this design's own
      §6.2/§8.2-point-3 invariant was violated somewhere upstream (a token reached this
      point whose `token_id` is not an existing record's id — e.g. a derived
      split-branch id like `"<parent>/0"`, which is not UUID-shaped and therefore fails
      the cast). Surfaces as `{:error, {:invalid_token_record_id, token.token_id}}`,
      never a raised exception — a second, defense-in-depth check on top of §8.2 point 3,
      not this function's sole guard against that case.
   b. `find_node(graph.nodes, token.node_id)` — the same non-bang lookup
      `TaskActivation`'s own existing private `find_node/2` already provides (§0);
      `nil` → `{:error, {:unknown_node_id, token.node_id}}`.
   c. `insert_attrs(instance_id, token_record_id, token, node)` — `TaskActivation`'s own
      existing **public** `insert_attrs/4` (§0), called exactly as-is, unmodified; its
      signature already takes `token_record_id` as an independent argument (never derived
      internally from a `changes` map), so nothing about that function needed to change
      for this reuse to be genuine.
   d. `%Task{} |> Task.insert_changeset(attrs) |> repo.insert(prefix: prefix)` — same
      insert shape `append_multi/6`'s own private `do_insert/3` already uses (§0).
5. Short-circuits on the first failure (`Enum.reduce_while/3`-shaped, matching
   `insert_newly_pending/6`'s own established convention, §0), returning `{:ok,
   inserted_task_records}` on full success.

**What genuinely is reused unchanged, restated precisely:** `newly_pending_tokens/2` and
`insert_attrs/4` (both already public on `TaskActivation`, called with no signature change)
— the diff algorithm and the six-key attrs-mapping algorithm are the same code REQ-047
shipped. What is **not** reused is `append_multi/6` itself (its `Multi.run/3` wrapper and
its FK-resolution strategy), because that strategy is bound to `persist/8`'s specific
freshly-insert-then-zip shape, which REQ-048's advance/reconcile shape does not produce and
does not need.

Called from REQ-048's own Multi (§8, M6) as:
`TaskActivation.append_multi_from_existing_records(multi, instance_id, graph,
seed_state.pending_task_nodes, final_instance_state, prefix)` — same call-site shape as
the original claim, just naming the new function instead of `append_multi/6`.

---

## 10. `TASK_COMPLETED` event append (EE-04 AC1, REQ-025)

The payload (a JSON object, `Jason.encode!/1`) carries four keys: `task_id` (`task.id`),
`node_id` (`task.node_id`), `output_variables` (the caller's **original**, unmerged map),
and `merged_variable_events` (§7's `merge_events` list — informational, not separately
persisted) plus `activated_nodes` (`Enum.map(final_instance_state.tokens, & &1.node_id)`).
`event_attrs` built from this payload plus `instance_id: task.instance_id`,
`event_type: "TASK_COMPLETED"`, and `actor_id`/`idempotency_key` read straight from
`attrs` (§3), passed to `EventStore.append/2` with `prefix: prefix`.

Same "plumb straight through, let `append/2` return its own typed
`:missing_actor_id`/`:missing_idempotency_key`/`:unknown_event_type`/... errors" pattern
`create/2`'s own `append_instance_started_event/6` already establishes (§0) — this design
does not re-validate `actor_id`/`idempotency_key` itself. **`"TASK_COMPLETED"` must already
be a registered `event_type_registry` row for the tenant, or this step (and therefore the
whole call) fails with `{:error, :unknown_event_type}`** — the same pre-existing,
already-flagged gap `req045`'s own OQ-3a documents for `"INSTANCE_STARTED"` (§0); this
design inherits it rather than re-discovering it, and does not attempt to seed the
registry (out of scope, same as req045).

---

## 11. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-EE48-1 | `complete_task/3` never mutates the `tasks`/`tokens`/`instance_projections`/`events` rows outside one `Ecto.Multi`/`Repo.transaction/1` — all four commit or roll back together | §8 |
| INV-EE48-2 | A `task_id` with no matching row and a `task_id` whose row is not `:pending` return two distinct, separately pattern-matchable error tuples (`{:error, :task_not_found}` vs `{:error, {:task_not_pending, status}}`) | §8, §8.1 |
| INV-EE48-3 | `nil`/absent `output_variables` is rejected before any I/O is attempted; `%{}` is accepted | §3 |
| INV-EE48-4 | Two concurrent `complete_task/3` calls on the same `task_id` are serialized by `SELECT ... FOR UPDATE` on the `tasks` row; exactly one commits `:completed`, the other observes `{:error, {:task_not_pending, :completed}}` | §8.1 |
| INV-EE48-5 | Exactly one `TASK_COMPLETED` event is appended per successful call — per-key `VARIABLE_OVERWRITTEN` outcomes are embedded in that one event's payload, never separately appended | §7, §10 |
| INV-EE48-6 | `dispatch_task_completion/4` never appends to `pending_task_nodes` — only `dispatch_human_task/3` does, unchanged | §5 point 3 |
| INV-EE48-7 | `join_counters` is always `%{}` in this design's reconstructed state; a hop-chain reaching a `:PARALLEL_GATEWAY` join fails with a typed `{:error, {:unknown_branch_id, _}}` from `Transition`, never silently mismerges | §6.5, §11 OQ-3 |
| INV-EE48-8 | A token minted for the first time during this call's own hop-chain (not traceable to a pre-existing `tokens` row) is a typed, rolled-back failure (`{:new_token_during_resume_not_supported, _}`), never a silent mis-insert or a stale/duplicate row | §8.2 point 3 |
| INV-EE48-9 | No `tenant_id` column or derivation is added to any of the four tables this design touches (Decision 0006 D2) | §0 |
| INV-EE48-10 | This module performs zero HTTP status-code mapping and zero assignee-authorization checking (AC5) | §12 |

---

## 12. Scope boundary (AC5) — required moduledoc content

`Letflow.Engine.complete_task/3`'s own `@doc`/the surrounding moduledoc section must state,
verbatim in substance:

> `POST /api/v1/tasks/:id/complete`'s HTTP status-code mapping (404/409/422 for
> `:task_not_found`/`{:task_not_pending, _}`/`:invalid_output_variables` respectively) is
> S4 (api-surface) scope — this function returns tagged tuples only, exactly as
> `Letflow.EventStore.append/2`'s `is_duplicate` boolean already left the 200-vs-201 choice
> to S4. Whether the calling `TASK_WORKER` is the task's own `assignee_ref` (HTTP 403
> otherwise, per IDN-03's role matrix) is **not checked anywhere in this module** — that is
> the S4 auth plug's job, per REQ-021's precedent; `complete_task/3` performs no assignee
> comparison and accepts `attrs.actor_id` as already-authorized by the caller.

Satisfies AC5 directly.

---

## 13. Open questions — explicitly listed, not silently resolved

**OQ-1 (MINOR).** `fetch_output_variables/1` collapses "key absent" and "key present, value
`nil`" into the same `{:error, :invalid_output_variables}` atom (§3). AC2 only requires
`nil` to be distinct from the not-found/conflict errors, not from "absent" — this design's
simplification is a choice, not a literal requirement-text instruction. Flagged for
REVIEWER to confirm, or to require a second, more specific atom if a future caller needs to
tell the two apart.

**OQ-2 (MAJOR).** §6's entire scoped-reconstruction approach (building an `InstanceState.t()`
directly from `tasks`/`tokens`/`instance_projections` rather than from a full REQ-053
event-log replay) is this design's own resolution of a real gap: REQ-048 needs *some*
`InstanceState.t()` to call `transition/3` against, and REQ-053 (the module that would
normally own "reconstruct instance state") is `pending`. This is new, non-trivial
state-machine logic invented for this requirement, not spelled out by the requirement
text's own bullet list — flagged for REVIEWER to confirm this narrower, `tasks`/`tokens`/
`instance_projections`-only reconstruction is the right scope for REQ-048, rather than
REQ-048 depending on (and therefore blocking on) REQ-053 landing first.

**OQ-2b (MAJOR, disclosed at CODE-DESIGN-VALIDATOR's rework request — iteration 1).**
This document's first submission claimed `TaskActivation.append_multi/6` was reused
"exactly" and "unmodified" as this Multi's `:task_records` step. Re-verified directly
against the shipped code during rework (§9): that claim was wrong — `append_multi/6`'s
non-empty branch unconditionally reads `Map.fetch!(changes, :token_record)`, a key only
`persist/8`'s own preceding freshly-insert step (`insert_token_records/4`) ever produces,
which would `KeyError`-crash on REQ-048's own ordinary AC1 success path (a hop-chain
reaching a newly-pending `:HUMAN_TASK` node) since this Multi never inserts fresh
`TokenRecord` rows the way `create/2` does — REQ-048's tokens are pre-existing rows being
advanced/reconciled (M7, §8.2), not newly minted ones. **Fix adopted:** a new public
function, `TaskActivation.append_multi_from_existing_records/6` (§9), added *alongside*
`append_multi/6` (which is left completely unmodified, so `create/2`'s own call site is
unaffected) — it reuses `newly_pending_tokens/2` and `insert_attrs/4` genuinely unchanged,
but skips the FK-zip step entirely because this design's own token-id invariant (§6.2,
§8.2 point 3) already guarantees `token.token_id` **is** the target `TokenRecord.id`,
stringified, with no lookup needed. Flagged as MAJOR (not merely a bugfix note) because it
is a new function added to an already-shipped, gate-approved module (`TaskActivation`,
REQ-047) — the same class of change §5's new `Transition` dispatch clause is, and
REVIEWER should independently confirm the "no FK-zip needed" reasoning (§9) holds, rather
than accepting this rework's own re-derivation on faith.

**OQ-3 (MAJOR).** `join_counters: %{}` always (§6.5) means any `complete_task` call whose
resulting hop-chain reaches an outstanding `:PARALLEL_GATEWAY` join fails with a typed but
functionally-blocking error (`{:unknown_branch_id, _}`) rather than actually joining.
No table persists join-counter state today. Flagged for REVIEWER/ORCH to confirm this is
an acceptable known gap for REQ-048 to ship with (matching REQ-054's own `pending` status
and stated future ownership of `instance_state_snapshots`), rather than blocking REQ-048 on
a REQ-054 dependency this run's own `depends_on` list does not name.

**OQ-4 (MINOR).** §7's choice to call `VariableMerge.merge/3` with `variable_validations:
nil` (no schema validation of `output_variables` before merge) is a scope decision, not a
literal requirement-text instruction — no acceptance criterion names JSON Schema
validation for task output. Flagged for REVIEWER: should a future requirement wire
`Letflow.EventStore.Registry.validate_payload/3`-style validation into this path, the same
way `EventStore.append/2` validates its own payload against `event_type_registry`?

**OQ-5 (MINOR).** §8.1 locks `tasks` and `instance_projections` `FOR UPDATE` but not the
`tokens` rows this call reads (§6.2). Flagged for REQ-055's own general EE-12 concurrency
requirement to confirm whether a concurrent split/join-producing call against the same
instance (not modeled by this requirement's own AC4, which is scoped to same-`task_id`
concurrency) needs `tokens`-row locking too.

**OQ-6 (MINOR, inherited not new).** `"TASK_COMPLETED"` must be a registered
`event_type_registry` row per tenant for `:event` (M9, §10) to succeed — the same
pre-existing, already-flagged gap `req045`'s OQ-3a documents for `"INSTANCE_STARTED"`.
This design does not attempt to seed the registry; whoever resolves req045's OQ-3a
(seeding built-in platform event types) resolves this one identically, for the same event
type row shape.

---

## 14. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Engine.Task`, `Letflow.Engine.TokenRecord` (req043, shipped) | This code → those | `complete_changeset/2`, `advance_changeset/2` (both previously unused, now called) |
| `Letflow.Engine.Transition`, `InstanceState`, `Token` (req044/050/051, shipped, **extended by this requirement**) | Mutual | New `{:complete_task, token_id}` event + `dispatch_task_completion/4` clause added to `Transition`; this design's own reconstruction (§6) builds `InstanceState.t()`/`Token.t()` instances |
| `Letflow.Engine.VariableMerge` (req049, shipped) | This code → that | `merge/3`, called with `variable_validations: nil` (§7) |
| `Letflow.Engine.TaskActivation` (req047, shipped, **gains a new public function, `append_multi_from_existing_records/6`, §9/§13 OQ-2b**) | This code → that | `newly_pending_tokens/2` and `insert_attrs/4` reused genuinely unchanged; `append_multi/6` itself is NOT called by this design (§9) — it remains exclusively `create/2`'s own, untouched |
| `Letflow.Definitions.SnapshotStore` (req027/033, shipped) | This code → that | `get_by_instance_id/2` (read-only; this design never calls `create/3`) |
| `Letflow.EventStore` (req025, shipped) | This code → that | `append/2` for `TASK_COMPLETED` |
| `Letflow.EventStore.InstanceProjection` (req023/043, shipped) | This code → that | `update_changeset/2` (§8.3) |
| `Letflow.TenantProvisioning` (req022, shipped) | This code → that | `tenant_id_for_schema_name/1`, pre-transaction (§4) |
| `Letflow.Engine.advance_until_stable/4`, `tokens_needing_dispatch/3` (req045, shipped, **reused unchanged**) | This code → those (same module) | Drives every hop after the first `{:complete_task, ...}` dispatch (§8, M5) |
| S4 (`POST /api/v1/tasks/:id/complete`, not yet built) | S4 → `Letflow.Engine.complete_task/3` | Status-code mapping + IDN-03 assignee check, both explicitly out of scope here (§12) |
| REQ-053 (state reconstruction, not yet built) | Future, unrelated to this call path | This design's §6 reconstruction is deliberately narrower and does not presuppose or block on REQ-053 (§13 OQ-2) |
| REQ-054 (snapshot/join-counter persistence, not yet built) | Future | §6.5's `join_counters: %{}` gap (§13 OQ-3) is exactly what REQ-054 would close |

---

## 15. DB tables/columns touched (no schema change — reuses REQ-043/023 exactly)

| Table | Columns this design reads | Columns this design writes | Migration/schema (unchanged) |
|---|---|---|---|
| `tasks` | `id`, `instance_id`, `token_id`, `node_id`, `status` (locked `FOR UPDATE`) | `status`, `output_variables`, `completed_by`, `completed_at` (via `complete_changeset/2`); plus any new rows via `TaskActivation.append_multi_from_existing_records/6` (§9, new function) | `…110003_create_tasks.exs`, `task.ex` |
| `tokens` | `id`, `instance_id`, `node_id`, `branch_id`, `status`, `waiting_child_instance_id` for every `:active` row of the instance | `node_id` (advance) or `status`/`completed_at` (consume), via `advance_changeset/2` (§8.2) — **no new rows inserted by this design** (§8.2 point 3, OQ-2) | `…110002_create_tokens.exs`, `token_record.ex` |
| `instance_projections` | Full row (locked `FOR UPDATE`) | `status`, `current_nodes`, `variables`, `completed_at` (§8.3); `last_event_seq` via `EventStore.append/2`'s own existing M6 (§0) | `…110001_alter_instance_projections_add_engine_columns.exs`, `instance_projection.ex` |
| `instance_definition_snapshots` | `graph` (read-only, via `SnapshotStore.get_by_instance_id/2`) | — | Unchanged (req027/033) |
| `events` | — | One `TASK_COMPLETED` row via `EventStore.append/2` (§10), unchanged | REQ-025 (unchanged) |

**No migration file is added by this requirement.** Every table and column this design
writes to already exists.

---

## 16. Acceptance-criteria traceability

| This run's acceptance criterion | Concrete design element |
|---|---|
| "complete_task on a PENDING task merges output_variables, flips the task to COMPLETED with completed_at and completed_by set, activates the next node, and appends exactly one TASK_COMPLETED event -- all verified by reading tasks, instance_projections and events back after one call" | §7 (merge), §8.1/M8 (`:task_complete`), §5/§6 (dispatch + reconstruction = "activates the next node"), §8.3/M10 (`instance_projections` reflects the new `current_nodes`/`variables`/`status`), §10/M9 (exactly one `TASK_COMPLETED` append), §8 (all in one `Multi`) |
| "complete_task with output_variables set to an empty map succeeds; with nil it returns a distinct error -- two explicit tests" | §3's `fetch_output_variables/1` (`%{}` valid per AC2/EE-04 AC5; `nil` → `{:error, :invalid_output_variables}`, pre-transaction) |
| "complete_task against a non-existent task_id and against an already-COMPLETED task return two distinct, separately pattern-matchable errors, not one shared generic error" | §8/M1 (`:task_not_found` vs `{:task_not_pending, status}}`, INV-EE48-2) |
| "two concurrent complete_task calls on the same task_id result in exactly one success and one conflict error, demonstrated with an actual concurrent test or the FOR UPDATE locking code path cited explicitly if concurrency cannot be exercised in this environment" | §8.1 (`lock("FOR UPDATE")` on `tasks`, the exact serialization mechanism; INV-EE48-4) — TEST-DESIGNER's job to demonstrate concretely, per this design's cited code path |
| "the moduledoc states that HTTP status mapping and the IDN-03 assignee authorization check are S4 scope, not implemented here" | §12 (required verbatim-in-substance moduledoc content, INV-EE48-10) |
| "No implementation code (.ex/.exs bodies) — signatures and type shapes only" | Every code block in this document is a `@spec`, a field-mapping table, an algorithm-shape description, or an illustrative `with`/`case` skeleton matching `req045`/`req047`'s own established pseudocode convention — no complete `def ... do ... end` function body with real, runnable logic |
