# Design: REQ-053 — State reconstruction by event replay

**Requirement:** REQ-053 (stage S3, `depends_on: [REQ-052 (done), REQ-061 (done),
REQ-026 (done)]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ053-20260819`, WF-02 Step 1
**This document produces:** module/function signatures, `@spec`s, error taxonomy, the
events+events_archive merge strategy, the optional write-back locking shape, and
explicit moduledoc content requirements — no implementation code.

---

## 0. Sources read for this design

`docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md`
Step 1, `docs/anti-patterns.md`, `.claude/agents/code-designer.md`,
`docs/guides/backend_developer_guide.md`. Shipped code read in full:
`lib/letflow/event_store.ex` (`read/2`, `archive/1`), `lib/letflow/event_store/event.ex`,
`lib/letflow/event_store/archived_event.ex`, `lib/letflow/event_store/instance_projection.ex`,
`lib/letflow/engine.ex` (`create/2`, `complete_task/3`, `cancel_instance/3`, the
`activate/3`/`advance_until_stable/4`/`tokens_needing_dispatch/3` worklist),
`lib/letflow/engine/transition.ex`, `lib/letflow/engine/instance_state.ex`,
`lib/letflow/engine/execution_error.ex`, `lib/letflow/definitions/snapshot_store.ex`.
Prior gate-approved designs: `req023-event-store-schema.md`, `req026-event-read-archive-platform-sentinels.md`,
`req044-transition-kernel.md`, `req061-execution-error-handling.md`.

## 1. Confirmed against shipped code, not assumed

- **`EventStore.read/2` does NOT span `events_archive`.** `read/2`'s pipeline
  (`query_instance_events/3` → `resolve_payloads/2`) queries only the `Event`
  (`events`) schema — confirmed by direct read of `lib/letflow/event_store.ex:699-709`.
  `events_archive` has its own schema module, `Letflow.EventStore.ArchivedEvent`, with
  no reader function anywhere in `EventStore`. This requirement's own query (§4) is new.
- `Event.t()` and `ArchivedEvent.t()` carry an identical field set relevant to replay:
  `event_id`, `created_at`, `instance_id`, `event_type` (`String.t()`), `payload`
  (`map()`, already-decoded JSON — `resolve_payloads/2` resolves `$ref` pointers before
  returning), `sequence_number` (`pos_integer()`), `actor_id`, `idempotency_key`,
  `metadata`. `sequence_number` is assigned once per instance by `instance_sequence`
  and is carried unchanged when a row moves from `events` to `events_archive`
  (`archive/1`'s own doc, `event_store.ex:789-818`) — the correct, and only
  available, total order for merging the two tables.
- **Currently only four `event_type` values are ever appended for an instance**:
  `"INSTANCE_STARTED"` (`engine.ex:628`), `"TASK_COMPLETED"` (`engine.ex:1428`),
  `"INSTANCE_CANCELLED"` (`engine.ex:1784`), `"EXECUTION_ERROR"`
  (`execution_error.ex:204`). No `PARALLEL_SPLIT`/`PARALLEL_JOIN_*` event type is ever
  persisted — REQ-051's `pending_event()` union stays entirely in-memory, never
  written to `events` (confirmed by grep: no `event_type:` literal for any of the three
  `pending_event` variants anywhere in `lib/letflow/`). §5 below designs replay for
  exactly these four event types; a later `PARALLEL_*` event type, if ever added, needs
  its own replay clause added to §5's dispatch table by whichever requirement adds it.
- **`transition/3` cannot replay from event payload alone.** `transition_event()` is
  `{:advance_token, token_id} | {:cancel_branch, branch_id} | {:complete_task,
  token_id}` — every variant needs a `token_id` string. No persisted event payload
  records the `token_id` `Engine.create/2`/`complete_task/3` minted for that hop
  (`Ecto.UUID.generate/0` calls at `engine.ex:311` and inside `dispatch_parallel_split/4`
  are never echoed into any event payload). Exact `token_id`/`branch_id` values are
  therefore **not reconstructible bit-for-bit** from the event log; only token
  **positions** (`node_id`s) are. §6 states the consequence this has for AC1's
  "same tokens" comparison.
- **`instance_projections.current_nodes` is a list of `node_id` strings, not full
  token records** (`instance_projection.ex` schema: `current_nodes` is the only
  token-adjacent field, typed `Letflow.EventStore.JSONArray`; no `token_id`/`branch_id`
  column exists anywhere on that table). This confirms the field-for-field comparison
  in AC1 is necessarily over `current_nodes` (node-id multiset), `variables`, and
  `status` — the three fields the projection actually carries — not over
  `InstanceState.tokens`'s richer `token_id`/`branch_id` fields, which have no
  projection-side counterpart to compare against at all.
- `Letflow.Definitions.SnapshotStore.get_by_instance_id/2` (`snapshot_store.ex:135-145`)
  reads `instance_definition_snapshots`, a table **independent of both
  `instance_projections` and `events`** — the durable, per-instance-immutable graph
  source this design uses instead of re-resolving the live (possibly since-changed)
  `process_definitions` row. Returns `{:error, :snapshot_not_found}` when absent.

## 2. Module

`Letflow.Engine.Reconstruction` — new module, `lib/letflow/engine/reconstruction.ex`
(mirrors `lib/letflow/engine/*.ex` sibling placement, alongside `transition.ex`,
`instance_state.ex`).

### Moduledoc — required content (verbatim-in-substance, per this design)

PROVENANCE (historical, not current decision authority):
1. Ports `reconstruction.zig`'s `reconstructInstance()` (EE-11,
   `src/design/engine.md` "Section EE-11: State Reconstruction", L5237).
2. States the four confirmed-not-assumed findings of §1 above: `read/2` does not
   span `events_archive`; only 4 event types currently exist; `token_id`/`branch_id`
   are not recoverable from the log, only node positions; the field-for-field
   comparison is against `current_nodes`/`variables`/`status`, not raw
   `InstanceState.tokens` identity.
3. **NFR-04 statement (AC7, verbatim structure required):** "R-Co's EE-11 AC2 states
   a documented performance target — 10,000 events replayed in under 5 seconds
   (NFR-04). Letflow has not adopted an NFR requirement covering reconstruction
   performance, and no benchmark harness exists in this codebase as of this
   requirement. This target is recorded here as R-Co's documented context only; it
   is not a Letflow acceptance criterion, and no code in this module is written,
   tuned, or tested against it."
4. **Scope boundary statement (verbatim structure required):** "`POST
   /api/v1/instances/:id/reconstruct` is S4 (api-surface) scope, not built here. This
   module is the context-module function a future S4 route wraps."

## 3. Public API

```
@type reconstruct_opts :: [
  prefix: String.t(),
  write_back: boolean()   # default false — see §7
]

@type reconstruct_result :: %{
  instance_id: Ecto.UUID.t(),
  instance_state: Letflow.Engine.InstanceState.t(),
  event_count: non_neg_integer(),
  last_sequence_number: non_neg_integer() | nil,
  write_back: :skipped | :written
}

@type reconstruct_error ::
        {:error, :instance_not_found}
        | {:error, {:lock_contention, instance_id :: Ecto.UUID.t()}}
        | {:error, {:replay_failed, replay_failure_reason()}}
        | {:error, :invalid_schema_name}
        | {:error, :invalid_instance_id}

@type replay_failure_reason ::
        {:snapshot_unavailable, :snapshot_not_found}
        | {:graph_build_failed, term()}
        | {:transition_error, Letflow.Engine.Transition.transition_error()}
        | {:activation_failed, term()}
        | {:unrecognized_event_type, event_type :: String.t(), event_id :: Ecto.UUID.t()}
        | {:malformed_payload, event_id :: Ecto.UUID.t(), reason :: term()}

@spec reconstruct_instance(instance_id :: Ecto.UUID.t(), opts :: reconstruct_opts()) ::
        {:ok, reconstruct_result()} | reconstruct_error()
```

`reconstruct_instance/2` is the sole public function. `write_back` defaults to
`false` (opt-in, AC4/AC5's "read-only by default" requirement) — omitting the key
entirely from `opts` is equivalent to `write_back: false`, never treated as an error
or as "unspecified → true".

## 4. Step 1 — read every event, both tables, merged in `sequence_number` order

```
@spec read_full_log(instance_id :: Ecto.UUID.t(), prefix :: String.t()) ::
        {:ok, [merged_event()]} | {:error, term()}

@type merged_event :: %{
  event_id: Ecto.UUID.t(),
  event_type: String.t(),
  payload: map(),
  sequence_number: pos_integer(),
  created_at: DateTime.t()
}
```

- Two queries, same `prefix`: `Event` filtered `instance_id == ^instance_id`, and
  `ArchivedEvent` filtered the same way — each `order_by: [asc: :sequence_number]`.
  Both run inside one `Repo.transaction/2` (§9 OQ-1 states why this only narrows,
  not closes, the race).
- Merge: `sequence_number` partitions the two tables disjointly under normal
  operation (`archive/1` deletes from `events` in the same statement it inserts into
  `events_archive` — INV-AR-1/AR-2, `req026` design §7.3) — the merge is a plain
  `++` of the two already-ascending lists followed by one `Enum.sort_by(&1.sequence_number)`
  defensive re-sort, not a real interleave-merge (no two rows are expected to share a
  `sequence_number` for one `instance_id`). A duplicate `sequence_number` found across
  the two lists at runtime (should be structurally impossible) is **not** silently
  deduplicated — it is a data-integrity condition this design surfaces as
  `{:replay_failed, {:duplicate_sequence_number, sequence_number}}`, added to
  `replay_failure_reason()` above.
- Each row is normalized to the shared `merged_event()` shape (dropping
  table-specific fields — `archived_at`, `global_seq`, `actor_id`, `idempotency_key`,
  `metadata` — none of which replay needs).
- **Existence determination (instance-not-found vs. zero-events, AC4 vs. AC6):**
  neither table having any row for `instance_id` is **not by itself**
  `:instance_not_found` — see §5.1: a zero-event instance whose
  `instance_definition_snapshots` row exists (the snapshot-committed,
  event-append-crashed window `Engine.create/2`'s own moduledoc §9 OQ-4 names) is a
  real, reconstructible instance per AC4. `instance_not_found` is returned only when
  **both** the merged event list is empty **and** `SnapshotStore.get_by_instance_id/2`
  returns `{:error, :snapshot_not_found}` (§5.1) — i.e., nothing anywhere durably
  references this `instance_id`.

## 5. Step 2 — fold the merged log into an `InstanceState`

```
@spec replay(instance_id :: Ecto.UUID.t(), events :: [merged_event()], prefix :: String.t()) ::
        {:ok, Letflow.Engine.InstanceState.t()} | {:error, replay_failure_reason()}
```

### 5.1 Graph resolution (once, before folding)

`SnapshotStore.get_by_instance_id/2` is called once, before any event is folded —
the graph is instance-scoped and immutable once snapshotted (REQ-033, already
shipped), so it never changes mid-fold. `{:error, :snapshot_not_found}` here, given a
**non-empty** merged event list, becomes `{:replay_failed, {:snapshot_unavailable,
:snapshot_not_found}}` (the instance provably exists — it has events — but its graph
is unrecoverable, a genuine corrupt-log condition, never silently treated as
"instance never existed"). Given an **empty** merged event list, `{:error,
:snapshot_not_found}` here is what makes §4's existence determination resolve to
`{:error, :instance_not_found}` instead. The resolved `Letflow.Definitions.Graph.t()`
is built via the same private-in-`engine.ex` `build_graph/1`
(`Letflow.Definitions.Graph.build/1` — confirm exact public entry point at
implementation time; `Engine.build_graph/1` at `engine.ex:415` currently wraps it) —
this design does not re-decide that lookup, only reuses it.

### 5.2 Seed state (zero-events case, AC4)

Before any event is folded, the seed `InstanceState` is derived structurally from the
resolved graph alone — this is the exact same construction `Engine.activate/3`
performs before its first `Transition.transition/3` call
(`engine.ex:314-342`), reused here rather than re-invented: locate the graph's
`:START` node (`find_start_node/1` — reuse, do not re-derive), mint a fresh
`token_id` (`Ecto.UUID.generate/0` — see §6 for why the exact value is immaterial),
place that token on the `:START` node's `node_id`, `variables: %{}`, `status:
:active`, `pending_task_nodes: []`, `join_counters: %{}`. Folding zero events over
this seed returns it unchanged — this **is** AC4's "token on START, empty variables,
ACTIVE" case, produced with no event replay at all when the log is empty.

### 5.3 Per-event-type replay clauses

`replay/3` folds `events` left-to-right over the seed state via one private dispatch
function per `event_type`, matching this table (design doc §1's 4-event-type finding):

| `event_type` | Replay behavior | Reuses |
|---|---|---|
| `"INSTANCE_STARTED"` | Decode `payload.initial_variables`; reseed `variables` to it (payload also carries `definition_id`/`correlation_key`, informational only — not re-validated here, the snapshot already fixes the graph); then run the **same worklist loop** `Engine.activate/3`'s `advance_until_stable/4` runs, starting from the seed token, driven by `Transition.transition/3` — reuse `Engine.advance_until_stable/4`/`tokens_needing_dispatch/3` (export as shared or duplicate verbatim; see §9 OQ-2). A `Transition.transition/3` or hop-limit error here becomes `{:replay_failed, {:transition_error, reason}}` / `{:replay_failed, {:activation_failed, reason}}`. |
| `"TASK_COMPLETED"` | Decode `payload.node_id`/`payload.output_variables`/`payload.merged_variable_events` (informational). Find the token in the **current folded state** whose `node_id == payload.node_id` (§6 — position match, not `token_id` match, since the original `token_id` is unrecoverable). Zero or ≥2 matches is `{:replay_failed, {:ambiguous_task_node, payload.node_id}}` (new `replay_failure_reason()` variant — a documented limitation, §9 OQ-3, not a silent pick). Merge `output_variables` into `variables` via `VariableMerge.merge/3` (reuse, same call `Engine.complete_task/3` makes at `engine.ex:1090`), then `Transition.transition(graph, state, {:complete_task, matched_token.token_id})` followed by the same worklist loop as the `INSTANCE_STARTED` row. |
| `"INSTANCE_CANCELLED"` | Not routed through `Transition.transition/3` — `Engine.cancel_instance/3` itself never calls it (confirmed, `engine.ex:1740-1806`: cancellation is a direct row/status transform, not a graph dispatch). Replay mirrors that: `status: :cancelled`, `tokens: []`, `pending_task_nodes: []`, `join_counters: %{}`; `variables` unchanged. |
| `"EXECUTION_ERROR"` | Also not routed through `Transition.transition/3` — `ExecutionError.append_multi/3` never calls it either (`execution_error.ex`, confirmed above). Decode `payload.variables` (the error-time snapshot `ExecutionError`'s own moduledoc says is durable *only* in this event's payload, `execution_error.ex:` "variable-map snapshot lives in the EXECUTION_ERROR event's own payload"); set `status: :error`, `variables: payload.variables`. `tokens`/`pending_task_nodes`/`join_counters` are left as they were immediately before this event — `setInstanceError`'s own contract never touches token position. |
| any other value | `{:replay_failed, {:unrecognized_event_type, event_type, event_id}}` — never silently skipped, per this codebase's closed-error-taxonomy discipline. |

A `payload` missing a key this table requires, or holding a value of the wrong shape
(e.g. `initial_variables` not a map), is `{:replay_failed, {:malformed_payload,
event_id, reason}}` — decode/shape failures are distinguished from `transition/3`
dispatch failures in the reason tuple, both still surfacing as the one
`{:error, {:replay_failed, _}}` top-level shape AC6 requires.

## 6. What "same tokens" means for AC1 (stated explicitly, not left implicit)

Reconstruction's `InstanceState.tokens` uses freshly-minted `token_id`/`branch_id`
values on every call (§1, §5.2) — these can never be compared byte-for-byte against
either the original run's in-memory tokens (never persisted) or against
`instance_projections` (which has no `token_id`/`branch_id` column at all, only
`current_nodes`). AC1's "same tokens" comparison is therefore defined, for this
design, as: **`Enum.map(instance_state.tokens, & &1.node_id) |> Enum.sort() ==
Enum.sort(projection.current_nodes)`** — a multiset-of-node-id comparison — together
with `instance_state.variables == projection.variables` and
`Atom.to_string(instance_state.status) |> String.upcase() ==` the projection's raw
enum source value (or the equivalent `Ecto.Enum`-decoded-atom comparison,
`instance_state.status == projection.status`). TEST-DESIGNER must write AC1's test
against this definition, not against raw `InstanceState.tokens` struct equality.
"Task set" (AC1's third named field) compares
`instance_state.pending_task_nodes |> Enum.map(& &1.node_id) |> Enum.sort()` against
the `tasks` table's own `:pending`-status rows' `node_id`s for this instance
(`Letflow.Engine.Task`, already shipped) — `instance_projections` itself carries no
task-set column, so this comparison target is the `tasks` table, not the projection
row (a correction to the requirement text's literal "equal to the persisted
instance_projections row" framing for this one field, flagged as such rather than
silently reinterpreted).

## 7. Step 3 — optional write-back (AC4/AC5, opt-in only)

```
@spec write_back(instance_id :: Ecto.UUID.t(), Letflow.Engine.InstanceState.t(), prefix :: String.t()) ::
        {:ok, :written} | {:error, {:lock_contention, Ecto.UUID.t()}} | {:error, term()}
```

Only invoked when `opts[:write_back] == true`; `reconstruct_instance/2` never calls
it otherwise, and a plain reconstruction call performs **zero writes** — no
`Repo.insert`/`update`/`transaction` of any kind on the read-only path (AC5's "byte-
identical before/after" requirement, directly satisfiable since the read-only path
literally issues no write statement).

- Runs inside its own `Repo.transaction/2` (matching `ExecutionError.append_multi/3`'s
  sibling pattern for the fetch, but this function *does* open its own transaction —
  it has no caller-supplied `Multi` to append to, unlike `ExecutionError`).
PROVENANCE (historical, not current decision authority):
- `InstanceProjection |> where(instance_id: ^instance_id) |> lock("FOR UPDATE NOWAIT") |> repo.one(prefix: prefix)`
  — `NOWAIT` (not plain `FOR UPDATE`) is the deliberate mechanism that turns
  contention into an **immediate, distinct error** instead of the transaction
  blocking until the other holder releases (matching `reconstruction.zig`'s own
  `LockContention` error, which the requirement text names as the behavior to match —
  a blocking `FOR UPDATE` would silently defer, never itself producing a
  pattern-matchable `LockContention`-equivalent).
- Postgres surfaces `NOWAIT` contention as SQLSTATE `55P03` (`lock_not_available`),
  raised by `Postgrex` as `%Postgrex.Error{postgres: %{code: :lock_not_available}}`.
  This function rescues that specific error inside the transaction closure and
  returns `{:error, {:lock_contention, instance_id}}` — any other `Postgrex.Error`
  propagates un-rescued (not folded into `:lock_contention`).
- Row absent (`repo.one/2` returns `nil`, e.g. AC2/AC3's "projection deleted"
  scenario): `write_back` **inserts** a fresh row via
  `InstanceProjection.insert_changeset/2` rather than erroring — this is the one
  place this design departs from "update-only", since AC2/AC3 explicitly exercise
  reconstruction with the projection row missing, and write-back must still have a
  defined outcome there rather than an unstated gap.
- Row present: `InstanceProjection.update_changeset/2` (reused unchanged, same
  function `ExecutionError`/`Engine.reconcile_projection/5` already call) with
  `%{status: instance_state.status, current_nodes: Enum.map(instance_state.tokens, & &1.node_id), variables: instance_state.variables}`.
  `last_event_seq` is set to the merged log's own `last_sequence_number` (§3's result
  field) — the one field with no `InstanceState` equivalent, sourced from the event
  read instead.
- `reconstruct_instance/2`'s top-level `write_back: :written` result field is set
  only on this function's `{:ok, :written}`; any error from `write_back/3` propagates
  as `reconstruct_instance/2`'s own return value (the whole call fails, it does not
  return a partial `{:ok, ...}` with a silently-skipped write-back).

## 8. Invariants

- **INV-RC-1 (read-only by default):** `reconstruct_instance(id, prefix: p)` (no
  `write_back` key, or `write_back: false`) performs zero `Repo.insert`/`update`/
  `delete` calls anywhere in its call graph.
- **INV-RC-2 (ground truth is the event log, never the projection):** no function in
  this module ever reads `instance_projections` on the replay path (§5) — only
  `write_back/3` (§7, opt-in) touches that table, and only to write, never to seed
  replay state from it.
- **INV-RC-3 (total event-type coverage):** every `event_type` string this module
  encounters either has a named replay clause (§5.3's table) or produces
  `{:replay_failed, {:unrecognized_event_type, ...}}` — no event is ever silently
  ignored/skipped during a fold.
- **INV-RC-4 (three distinct, pattern-matchable top-level errors):** every error this
  module returns is one of exactly `{:error, :instance_not_found}`,
  `{:error, {:lock_contention, _}}`, `{:error, {:replay_failed, _}}`, or one of the
  two input-validation errors (`:invalid_schema_name`/`:invalid_instance_id`, same
  shape `EventStore.read/2` already establishes for malformed input) — never a bare
  `{:error, term()}` catch-all (AC6).

## 9. Open questions (explicit, not silently resolved)

- **OQ-1 (two-query race):** §4's two reads run inside one `Repo.transaction/2`, but
  Postgres's default `READ COMMITTED` isolation does not give them a shared MVCC
  snapshot the way `REPEATABLE READ` would — a concurrent `archive/1` call landing
  between the `events` query and the `events_archive` query could in principle cause
  one row to be missed by both (moved out of `events` after the first query, not yet
  visible... actually already committed before the second query, so it should still
  be visible — the realistic gap is the reverse ordering, `events_archive` queried
  first, then a row still in `events` at that instant is caught by the second query
  regardless). Net effect: under `READ COMMITTED`, no row is ever lost by this
  ordering (query `events_archive` first is the safer order, since `archive/1` only
  ever moves rows into it, never out), but this design does not upgrade the
  transaction to `REPEATABLE READ`/`SERIALIZABLE` to close the gap formally — flagged
  for REVIEWER to confirm the `READ COMMITTED` argument above is sufficient or
  whether AC3's test needs a stronger isolation level.
- **OQ-2 (worklist-loop reuse mechanism):** `Engine.advance_until_stable/4` and
  `tokens_needing_dispatch/3` are currently `defp` in `lib/letflow/engine.ex`. This
  design assumes they become shared (either exported from `Engine` with `@doc false`,
  or extracted into a small shared helper module both `Engine` and `Reconstruction`
  depend on) rather than duplicated verbatim — ELIXIR-DEV picks the mechanism;
  REVIEWER should confirm no behavioral drift is introduced by whichever refactor is
  chosen (duplication risks the two copies silently diverging over time; exporting
  risks `Engine`'s already-large public surface growing further — both flagged, no
  default recommended here).
- **OQ-3 (ambiguous task-node limitation):** the `TASK_COMPLETED` replay clause's
  "find token by `node_id`" (§5.3) is unsound if two live tokens ever sit on the same
  `node_id` simultaneously (a `PARALLEL_GATEWAY` split whose two branches happen to
  route through a shared `HUMAN_TASK` node id — unusual but not structurally
  forbidden by REQ-028's validators as far as this design confirmed). This is a real,
  named gap in EE-11 replay fidelity for that topology, surfaced as
  `{:replay_failed, {:ambiguous_task_node, node_id}}` rather than silently guessing —
  not fixed by this requirement (no `TASK_COMPLETED` payload field currently
  identifies which token/branch completed; adding one is a future requirement's
  event-schema change, out of REQ-053's scope).
- **OQ-4 (write-back insert-vs-update path has no dedicated AC):** §7's "insert a
  fresh row when absent" behavior is this design's own extension to make write-back
  total over AC2/AC3's "projection deleted" scenario — TEST-DESIGNER should add
  explicit coverage for it even though no acceptance criterion names it verbatim, per
  `core-directives.md`'s general expectation that a design's own necessary additions
  get tested, not only the letter of the AC list.
