# Design: ISS-0397 — durable, always-current `join_counters` persistence

**Issue:** ISS-0397 (`docs/issues/ISS-0397.yaml`), stage S7, closes REQ-048 design doc's
own MAJOR OQ-3 / INV-EE48-7 gap.
**Run:** `WF03-ISS0397-20260901`, WF-03 Step 2
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the exact `instance_projections` column this fix adds, which
functions must read/write it and in what lock scope, the migration, the correctness
argument for concurrent sibling-branch completions, and the test shapes TEST-DESIGNER
must implement. No implementation code — signatures/shapes/algorithm descriptions only.

---

## 0. Sources read for this design

- `handoffs/WF03-ISS0397-20260901/step-01-issue-fixer-diagnosis.json` (full) — ISSUE-FIXER's
  diagnosis, re-verified rather than trusted verbatim (§1 below re-derives every load-bearing
  claim against the real code).
- `lib/letflow/engine.ex` (re-read directly): `complete_task/3` (~1481), `run_complete_task/6`
  (~1537), `fetch_and_lock_task/3` (~1689, M1), `fetch_and_lock_instance_projection/3` (~1704,
  M2), `build_snapshot_and_state/4` (~1721, M3), `build_instance_state/3` (~1813, the hardcoded
  `join_counters: %{}` site), `build_complete_task_tail_multi/6` (~2381-2495, both clauses),
  `reconcile_projection/5` (~2821, the M10 `:projection` write site — confirmed **shared**
  between `complete_task/3`'s success tail and `advance_after_timer_fired/3`, see below),
  `advance_after_timer_fired/3` (~1844) and `persist_timer_fired_advance/7` (~1935-2025, its
  own `Multi.run(:projection, ...)` at ~2007 calls `reconcile_projection/5` too — the exact
  same function, not a separate copy), `run_cancel_instance/5` (~3002-3064, its own `:projection`
  step at ~3056 calls a **different** function, `cancel_instance_projection/4` — confirmed
  `cancel_instance/3` never calls `Transition.transition/3` at all, see §6 below).
- `lib/letflow/engine/transition.ex`: `dispatch_parallel_split/4` (~748-796, writes
  `join_counters` via `Map.put`), `dispatch_parallel_join/4` (~1042-1057, updates
  `received_from_branches` via `Map.put`), `fire_join/5` (~1095-1129, removes the cohort via
  `Map.delete` once it fires), `dispatch_cancel_branch/3` (~1145-1182, updates
  `cancelled_branches` or deletes the cohort). Confirmed: **every** mutation of
  `InstanceState.join_counters` happens inside `Transition.transition/3`'s single pure call,
  in memory, on the `InstanceState.t()` passed in — `Transition` never touches `Letflow.Repo`
  (module purity contract, its own moduledoc). This means the durability gap is entirely a
  matter of what `Letflow.Engine` reads before calling `transition/3` and what it writes back
  after.
- `lib/letflow/engine/snapshot_writer.ex` (full, already read for the task prompt) —
  `serialize_state/1` / `join_counter_entry_to_map/1` (~233-261) and
  `deserialize_state/2` / `join_counter_entry_from_map/1` (~263-306): the existing,
  already-reviewed (REQ-054) `JoinCounter.t() <-> plain-map` codec. Confirmed **not** wired
  into any per-call read path — `latest_snapshot/2` is only ever called from
  `Letflow.Engine.Reconstruction.replay/3` (REQ-053's full/incremental event-log replay), never
  from `build_snapshot_and_state/4`.
- `lib/letflow/engine/join_counter.ex`, `lib/letflow/engine/instance_state.ex` — struct shapes.
- `lib/letflow/event_store/instance_projection.ex` (full) — `insert_changeset/2`,
  `update_changeset/2`, existing column list, the `current_nodes`/`variables` jsonb-column
  precedent (`Letflow.EventStore.JSONArray` for the list-shaped column vs. plain `:map` for the
  object-shaped ones).
- `lib/letflow/design/req048-task-completion.md` (full) — §6.5 (`build_instance_state/3`'s
  hardcoded `join_counters: %{}`), §8 (the M1-M10 Multi step table and its lock-ordering
  rationale), §8.1 (exact `tasks`-before-`instance_projections` lock-ordering rule and why),
  §8.3 (`reconcile_instance_projection`, now shipped as `reconcile_projection/5`), INV-EE48-4
  (concurrency serialization via `tasks` `FOR UPDATE`), INV-EE48-7 and OQ-3 (the exact gap this
  issue closes).
- `lib/letflow/design/req054-instance-state-snapshots.md` (full) — confirms
  `instance_state_snapshots` is a **periodic** (default every-1000-event), crash-recovery
  artifact (INV-ISS-2: insert-or-select only, never read on any hot write path), and that its
  `join_counters` serialization (§2.2) is the exact shape `SnapshotWriter`'s private codec
  functions already implement — the format this design reuses, not the table.
- `lib/letflow/design/req051-parallel-gateway-split-join.md` §3.4, §12.1 — `JoinCounter`'s own
  "keyed by `join_node_id` alone, not `{join_node_id, origin_token_id}`" limitation (pre-existing,
  unrelated to this fix, restated at §7 OQ-1 below since it interacts with this fix's read/write
  contract).
- `lib/letflow/design/req052-instance-cancellation.md` §4, §"OQ-2 (MAJOR) — RESOLVED
  2026-08-22, GH#326" — **load-bearing finding for §6 below**: REQ-052's own design explicitly
  decided **not** to drive `{:cancel_branch, branch_id}` through `Transition` from
  `cancel_instance/3`, and states its reason as "the join-counters persistence gap makes driving
  `{:cancel_branch, _}` here a no-op today." This fix removes exactly that persistence gap —
  flagged as a coordination note, not silently re-decided (§6).
- `priv/repo/migrations/20260818110001_alter_instance_projections_add_engine_columns.exs` (full)
  — the `add :variables, :map, null: false, default: %{}` idiom this design's migration reuses
  verbatim, and its own now-stale "table is empty, no DEFAULT needed" precondition note —
  **does not apply here**: `instance_projections` has had live writers (`create/2`,
  `complete_task/3`, `cancel_instance/3`) since REQ-045 shipped, so this design's migration
  **must** carry a real DB-level default (§4).
- `priv/repo/migrations/20260901000001_add_content_to_repository_artifacts.exs` (full) — the
  current house style for an ALTER-only addendum migration file (moduledoc-as-comment-block,
  tenant-scoped guard, manifest-registration reminder).
- `lib/letflow/tenant_provisioning.ex` — `@tenant_scoped_migration_manifest` /
  `tenant_scoped_migrations/0` registration mechanism (both halves mandatory, confirmed).
- `test/letflow/engine_cancel_instance_test.exs` (full) — `provisioned_tenant/0`'s
  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` setup and its "AC4 — cancel_instance/3
  racing complete_task/3, run concurrently" `Task.async`/`Task.await_many` shape — the exact
  precedent this design's own concurrent test (§5) follows for a genuine two-connection race
  (not serialized by shared sandbox ownership).
- `test/letflow/engine/reconstruction_test.exs` `with_locked_projection/3` (~540-574) — a second
  precedent for holding a real `FOR UPDATE` lock on `instance_projections` from one `Task` while
  asserting the caller blocks/serializes correctly from another.
- `test/letflow/engine_test.exs` `graph_start_parallel_split_human_tasks/0` (~154-196) — the
  existing fixture shape (`START -> PARALLEL_GATEWAY(split) -> HUMAN_TASK(a) / HUMAN_TASK(b) ->
  PARALLEL_GATEWAY(join) -> END`) already used for real `Engine.create/2`-driven split/join
  scenarios — reused by reference, not duplicated, in §5.
- `test/letflow/engine/parallel_gateway_test.exs` moduledoc — confirmed (per ISSUE-FIXER's own
  diagnosis, re-checked) this file is pure/in-memory `Transition`-only, zero `Letflow.Repo`
  dependency, and therefore cannot and does not exercise this issue's actual cross-call defect.
- `test/letflow/simulation/req208_meridian_test.exs` — confirmed (not re-derived, ISSUE-FIXER's
  finding accepted as read) the two loan-origination scenarios currently assert the *broken*
  behavior (an HTTP 500 on the second, separate `complete_task` call) as their disposition.
- `docs/issues/ISS-0396.yaml` — read in full to confirm the non-overlap claim in §8 independently
  rather than relying solely on ISSUE-FIXER's summary.
- `docs/anti-patterns.md` — checked for join-counter/locking-related entries; none present.

---

## 1. Restating the defect precisely (re-verified, not re-quoted)

`Letflow.Engine.build_instance_state/3` (engine.ex ~1813) is called from
`build_snapshot_and_state/4` (M3 of `complete_task/3`'s Multi, and also — via
`build_snapshot_and_state_for_timer/4`, the timer-fire path's own M3-equivalent — from
`advance_after_timer_fired/3`). It assembles the `InstanceState.t()` seed that
`Transition.transition/3` dispatches against, and **always** sets `join_counters: %{}`,
regardless of any join cohort a *previous*, already-committed `complete_task/3` call opened via
`dispatch_parallel_split/4`. Consequence: a hop-chain reaching an outstanding
`:PARALLEL_GATEWAY` join whose split happened in an earlier, separate call always fails with
`{:error, {:unknown_branch_id, token.branch_id}}` (`dispatch_parallel_join/4`'s `with %JoinCounter{}
<- Map.get(...)` guard has nothing to match) — a *cross-call* join can never fire, only a
same-hop-chain (single-call) join can, which happens to work today only because
`build_instance_state/3`'s hardcoded `%{}` is irrelevant when the split and the join are both
reached within the same `transition`/`advance_until_stable` pass.

Confirmed **not** fixable by reading `SnapshotWriter.latest_snapshot/2`: that table is written
by `maybe_take_snapshot/4` only every `interval` (default 1000) events (`snapshot_writer.ex`
~173-198), so reading it back on every `complete_task/3` call would return a `join_counters`
value current as of up to 999 events ago on most calls — silently wrong (stale
`expected_from_branches`/`received_from_branches`/`cancelled_branches`), which is strictly worse
than today's loud, typed `{:unknown_branch_id, _}` failure and would itself violate INV-EE48-7
("never silently mismerges").

---

## 2. Fix strategy — one new column on the already-locked `instance_projections` row

### 2.1 Why `instance_projections`, not a new table

`complete_task/3`'s M2 step (`fetch_and_lock_instance_projection/3`) already takes
`SELECT ... FOR UPDATE` on exactly the row this design needs to make `join_counters` durable
against — the same row `build_instance_state/3` already reads `variables`/`status` from (§6.5 of
the REQ-048 design) and the same row `reconcile_projection/5` (M10) already writes
`status`/`current_nodes`/`variables` back to. Adding `join_counters` as one more column on this
row means:

- **No new lock, no new lock-ordering rule.** `complete_task/3`'s existing `tasks`-before-
  `instance_projections` global lock order (REQ-048 design §8.1, unchanged by this fix) already
  serializes every access to the row this design reads/writes.
- **No new table, no new FK, no new index** — a `SELECT`/`UPDATE` this design needs is already
  happening on this exact row in this exact transaction, for reasons unrelated to this fix.
- Matches ISSUE-FIXER's own option (a) (handoff §8), the option ISSUE-FIXER itself judged
  simpler and lock-ordering-compatible "for free" — this design adopts it, not option (b) (a
  second table needing its own lock-ordering argument), because nothing in the read/write
  pattern below needs a table with its own primary key or its own accumulating history:
  `join_counters` is definitionally *current-state*, one value per instance, exactly like
  `variables`/`current_nodes`, and REQ-054's own `instance_state_snapshots` table already
  demonstrates what an *accumulating-history* need would look like — this is not that need.

### 2.2 New column

`instance_projections.join_counters` — `:map` (jsonb), `null: false`, DB-level default `%{}`,
same type and same `add :field, :map, null: false, default: %{}` idiom as the already-shipped
`variables` column (`20260818110001_alter_instance_projections_add_engine_columns.exs`, cited
§0). No custom `Ecto.Type` needed (unlike `current_nodes`): the serialized shape (§2.3 below) is
a JSON **object** keyed by `join_node_id` strings, not a bare list, so it does not hit the
`Letflow.EventStore.JSONArray`-requiring empty-list-default problem `current_nodes` had.

`Letflow.EventStore.InstanceProjection` (schema module) changes:

```
field(:join_counters, :map, default: %{})
```

added to the schema block, alongside `:variables`. Cast in **both** changesets:

```
@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```
— `:join_counters` added to `insert_changeset/2`'s cast list, **not** to its
`validate_required/2` list (every instance starts with no outstanding join cohort — DB default
`%{}` covers `create/2`'s own call site, which never passes this key and should not have to).

```
@spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```
— `:join_counters` added to `update_changeset/2`'s cast list (this is the changeset
`reconcile_projection/5` calls, §2.4 below), **not** added to `validate_required/2` (a call that
does not touch join state — e.g. a hop-chain with no gateway involvement — should not be forced
to pass this key; the column's own existing value is left unchanged by Ecto's `cast/3` when the
key is absent from `attrs`, matching how `error_detail`/`completed_at`/`cancelled_at` already
behave in that same changeset today).

### 2.3 Serialization shape — reuse `SnapshotWriter`'s codec, not the table

`SnapshotWriter.serialize_state/1` / `deserialize_state/2` (snapshot_writer.ex ~233-306) already
implement, as **private** functions, exactly the `JoinCounter.t() <-> plain-map` round-trip this
design needs (`join_counter_entry_to_map/1`, `join_counter_entry_from_map/1`) — the map/MapSet
key names (`"join_node_id"`, `"origin_token_id"`, `"expected_from_branches"`,
`"received_from_branches"`, `"cancelled_branches"`, each `MapSet` sorted to a list for JSON) are
an already-REQ-054-reviewed format. **Duplicating this format via a second, independent
implementation risks silent drift** (e.g. a future REQ-054 rework changing the map shape without
this fix's copy noticing) — this design instead promotes the join-counters half of that codec to
two new **public** functions on `Letflow.Engine.SnapshotWriter`:

```
@spec serialize_join_counters(%{optional(String.t()) => JoinCounter.t()}) :: map()
@spec deserialize_join_counters(map()) :: %{optional(String.t()) => JoinCounter.t()}
```

implemented by extracting the existing `Map.new(instance_state.join_counters,
&join_counter_entry_to_map/1)` / `Map.new(Map.fetch!(state, "join_counters"),
&join_counter_entry_from_map/1)` expressions (currently inlined in `serialize_state/1` /
`deserialize_state/2`) into these two named, exported functions, then calling them from both
`serialize_state/1`/`deserialize_state/2` (unchanged behavior, now delegating) **and** from
`Letflow.Engine`'s new read/write sites (§2.4). This is a **refactor of `SnapshotWriter`, not a
new dependency of `Letflow.Engine` on `SnapshotWriter`'s table-reading behavior** —
`Letflow.Engine` calls only these two pure map-shape functions, never
`SnapshotWriter.latest_snapshot/2`/`take_snapshot/4`/`maybe_take_snapshot/4`; the periodic
snapshot table is not read or written by anything this fix adds. State this distinction
explicitly in both call sites' code comments (so a future reader does not mistake "calls
`SnapshotWriter`" for "reads the periodic snapshot" — precisely the confusion §1 shows would be a
correctness bug).

**Why reuse via `SnapshotWriter` rather than moving the codec onto `JoinCounter` itself:**
`JoinCounter` is a deliberately dependency-free plain struct (its own moduledoc: "Plain struct,
not an `Ecto.Schema`... zero `Ecto`/`Letflow.Repo` dependency"); the serialize/deserialize
functions are pure and have no `Ecto`/`Repo` dependency either, so placing them on `JoinCounter`
directly (e.g. `JoinCounter.to_map/1`/`from_map/1`) would arguably be the more conventional home
and would let both `SnapshotWriter` and `Letflow.Engine` depend on `JoinCounter` symmetrically
instead of `Letflow.Engine` gaining a new-looking dependency on a REQ-054 module for an
unrelated reason. **Flagged as OQ-2 (§7)** — this design picks the `SnapshotWriter`-hosted
option because it requires touching one existing module instead of introducing a public API
surface on a struct module three other requirements (REQ-051/053/054) already treat as
"fields only," but does not treat that choice as obviously superior; REVIEWER should confirm.

### 2.4 Write site — `reconcile_projection/5` (M10), the one function, two call sites

Confirmed shared (§0): `reconcile_projection/5` (engine.ex ~2821) is called from **both**
`build_complete_task_tail_multi/6`'s success clause (`complete_task/3`'s own M10, ~2471-2479) and
`persist_timer_fired_advance/7`'s own `:projection` Ecto.Multi step (~2007-2009,
`advance_after_timer_fired/3`'s tail). Both call sites already pass the fully-dispatched
`final_instance_state :: InstanceState.t()` — the same struct whose `.join_counters` field
`Transition.transition/3`'s hop-chain may have just mutated (opened a cohort via
`dispatch_parallel_split/4`, updated one via `dispatch_parallel_join/4`, or removed one via
`fire_join/5`). Fixing `reconcile_projection/5` alone therefore covers **both** call sites with
one change:

```
@spec reconcile_projection(
        repo :: Ecto.Repo.t(),
        InstanceProjection.t(),
        InstanceState.t(),
        completed_at :: DateTime.t(),
        prefix :: String.t()
      ) :: {:ok, InstanceProjection.t()} | {:error, Ecto.Changeset.t()}
```

(signature unchanged — this is an internal-body change only). The `attrs` map this function
builds (currently `status`/`current_nodes`/`variables`, plus conditional `completed_at`) gains
one more key:

```
join_counters: SnapshotWriter.serialize_join_counters(final_instance_state.join_counters)
```

unconditionally (every call, not just ones that touched a gateway — a hop-chain with no
outstanding cohort serializes an empty map, which is both correct and idempotent against the
column's own `%{}` default). This `attrs` map is passed to `InstanceProjection.update_changeset/2`
(§2.2) and `repo.update/2`'d against the **same** `projection` struct this function already
received as an argument — the one `fetch_and_lock_instance_projection/3` (M2) locked and
returned earlier in this same transaction. No new `Repo` call, no new lock acquisition: this is
an additional field on an `UPDATE` this transaction was already going to issue against this row.

**`cancel_instance/3`'s own `:projection` step is deliberately NOT changed by this fix** — see
§6: it calls a different function (`cancel_instance_projection/4`), which is out of this fix's
scope because `cancel_instance/3` never calls `Transition.transition/3` and therefore never
mutates `join_counters` in memory in the first place (confirmed §0). Flagged there as a
coordination note, not silently left inconsistent.

### 2.5 Read site — `build_instance_state/3` (M3), reading from the SAME locked row

```
@spec build_instance_state(InstanceProjection.t(), [Token.t()], [Token.t()]) :: InstanceState.t()
```

(signature unchanged.) Body change — the hardcoded `join_counters: %{}` (engine.ex ~1824)
becomes:

```
join_counters: SnapshotWriter.deserialize_join_counters(projection.join_counters)
```

`projection` here is the **exact same `%InstanceProjection{}` struct** `build_snapshot_and_state/4`
received as its own argument (engine.ex ~1721, `%{task: task, instance_projection: projection}`
from the Multi's `changes` map) — i.e. the struct `fetch_and_lock_instance_projection/3` (M2)
returned from its `SELECT ... FOR UPDATE ... Repo.one/2` call earlier in this **same**
transaction. This is not a second, independent, unlocked `Repo` read of `instance_projections` —
it is the identical in-memory value `build_instance_state/3` already reads `projection.variables`
from one line below (§6.5 of the REQ-048 design, unchanged) and `status`-guards against in M2
itself. This is exactly the "must be read from the same locked row" requirement this issue's own
task description names, satisfied structurally (there is no code path by which
`build_instance_state/3` could read a *different* row's `join_counters` than the one M2 locked —
it has no `Repo`/`repo` argument at all, confirmed by its current signature).

**Confirmed by direct read (not assumed): there is only one change site, not two.**
`build_snapshot_and_state/4` (engine.ex ~1721, `complete_task/3`'s own M3) and
`build_snapshot_and_state_for_timer/4` (engine.ex ~1869, `advance_after_timer_fired/3`'s
M3-equivalent) both call the **same shared** private function, `build_instance_state/3`
(~1728 and ~1881 respectively, identical call shape:
`build_instance_state(projection, active_tokens, pending_task_tokens)`). The single body change
in §2.5 above therefore fixes the read side for both `complete_task/3` and
`advance_after_timer_fired/3` at once — no second function to locate or change.

---

## 3. Correctness argument — no new race, and proof for concurrent sibling completions

### 3.1 What already serializes concurrent `complete_task/3` calls on the same instance

INV-EE48-4 (REQ-048 design, unchanged by this fix): `fetch_and_lock_instance_projection/3` (M2)
takes `SELECT ... FOR UPDATE` on the `instance_projections` row by `instance_id`. Two concurrent
`complete_task/3` calls against **different tasks of the same instance** (the exact shape a
2-branch parallel split produces — each branch's `HUMAN_TASK` is a distinct `task_id`, both
owned by the same `instance_id`) both attempt this same M2 lock. Postgres serializes them: the
second transaction's `Repo.one/2` on this locked query **blocks** until the first transaction
commits or rolls back.

### 3.2 Why this fix introduces no new race distinct from the one it fixes

This fix adds a **read** of `join_counters` at M3 (from the M2-locked struct, already in memory,
no new I/O) and a **write** of `join_counters` at M10 (part of the M2-locked row's existing
`UPDATE`, no new I/O, no new lock). Both are inside the lock window M2 already opens and M10's
own `UPDATE` already closes (the lock is held for the row's entire transaction lifetime under
`FOR UPDATE`, released only at commit/rollback). Concretely:

- The read (§2.5) happens **after** M2 has acquired the lock and **before** this transaction
  commits — it cannot observe a value written by a transaction that has not yet committed
  (Postgres MVCC: `FOR UPDATE` both blocks a concurrent writer and, once acquired, reads the
  latest committed value as of lock acquisition — no snapshot-isolation staleness within a
  `READ COMMITTED` transaction re-reading a row it holds locked).
- The write (§2.4) happens as part of the **same** `UPDATE` statement M10 was already issuing —
  no separate transaction, no separate lock, no window where another transaction could
  interleave between "read join_counters" and "write join_counters" within one call, because
  both happen under the one M2-acquired lock this call holds for its entire duration.

No new lock is acquired, no existing lock's scope is widened beyond the row it already covered,
and no new I/O happens outside the transaction M2/M10 already bracket. The fix is therefore
**exactly as safe as INV-EE48-4 already is** for `variables`/`current_nodes` (both already
read-at-M3/write-at-M10 through this identical mechanism, unchanged by this fix) — `join_counters`
becomes the third field following that established pattern, not a new one.

### 3.3 Concrete two-branch-completing-in-parallel walkthrough

Instance `I` has an active `:PARALLEL_GATEWAY` split with two outstanding branches, `A` and `B`
(each ending in its own `HUMAN_TASK`, `task_A`/`task_B`), a `JoinCounter` for join node `J` with
`expected_from_branches = #{"A", "B"}`, `received_from_branches = #{}` — this cohort was opened
by an earlier, already-committed `complete_task/3` call (the split itself), and is now durably
readable via `instance_projections.join_counters` per §2.4.

Two `Task.async`-spawned processes call `Engine.complete_task(task_A.id, ..., prefix: p)` and
`Engine.complete_task(task_B.id, ..., prefix: p)` at genuinely the same wall-clock instant, real
separate Postgres connections (no shared sandbox ownership):

1. **M1** (`tasks` lock): each transaction locks its **own distinct** `task_id` row
   (`task_A`/`task_B` are different rows) — no contention at M1, both proceed immediately.
2. **M2** (`instance_projections` lock): both transactions target the **same** `instance_id`
   row. Postgres grants the lock to whichever transaction's `SELECT ... FOR UPDATE` arrives
   first at the row-lock manager — call it transaction $T_1$ (arbitrarily, $A$ or $B$); the other,
   $T_2$, **blocks** here until $T_1$ commits or rolls back.
3. $T_1$ proceeds through M3 (§2.5: reads `join_counters = {J: {expected: #{A,B}, received:
   #{}}}` from its own locked row), M4 (merge), M5 (`Transition.transition(graph, seed_state,
   {:complete_task, own_token_id})` — dispatches through `:HUMAN_TASK` to `J`'s
   `dispatch_parallel_join/4`, which finds branch $T_1$'s own branch id (say `A`) present in
   `expected_from_branches` and **not already** in `received_from_branches`, so
   `join_outcome/1` returns `:wait` — `received_from_branches` becomes `#{"A"}`, the cohort
   stays outstanding, `join_counters` in the returned `InstanceState.t()` is `{J: {expected:
   #{A,B}, received: #{A}}}`), M6-M9 (task activation/reconciliation/event append, none
   touching join state), M10 (§2.4: writes `join_counters = {J: {expected: #{A,B}, received:
   #{A}}}` back to the row it holds locked). $T_1$ **commits**, releasing the M2 lock.
4. $T_2$'s blocked `SELECT ... FOR UPDATE` now proceeds, acquiring the lock and reading the
   row **as $T_1$ just committed it** (MVCC: a lock-waiter's subsequent read sees the winner's
   committed data, not a stale pre-commit snapshot) — `join_counters = {J: {expected: #{A,B},
   received: #{A}}}`. $T_2$'s own M3 (§2.5) deserializes exactly this value. M5 dispatches
   $T_2$'s own branch (`B`) through `dispatch_parallel_join/4`: `B` is in `expected_from_branches`
   and not yet in `received_from_branches` — `received_from_branches` becomes `#{"A","B"}`,
   `join_outcome/1` now returns `:fire` (the full expected set has arrived, per REQ-051's design),
   `fire_join/5` runs (advances/produces the post-join token(s), `Map.delete`s `J`'s cohort from
   `join_counters` — the join has resolved, no cohort remains outstanding). M10 writes
   `join_counters = %{}` (or whatever cohorts remain from unrelated concurrent gateways, none in
   this scenario) back to the row. $T_2$ **commits**.
5. **Result:** the join fires exactly once, on whichever branch happens to complete second under
   real wall-clock ordering — never zero times (both branches' completions are eventually
   observed, since neither transaction can commit without acquiring and releasing the M2 lock in
   turn) and never twice (the cohort is `Map.delete`d by the transaction that fires it, and no
   transaction can read a stale, not-yet-updated `join_counters` value because M2's lock
   forecloses any read of the row while a conflicting write is in flight). This is the same
   "exactly one success, serialized by row lock" property INV-EE48-4 already guarantees for
   same-`task_id` racing, now shown to hold for same-`instance_id`-different-`task_id`,
   join-relevant racing too — a strictly weaker requirement, but one this fix's design must (and
   does) uphold since `complete_task/3`'s AC4 scope (REQ-048) never claimed *this* shape of
   concurrency, and OQ-5 of that design explicitly left broader same-instance concurrency to "a
   future EE-12 concurrency requirement" (never named as REQ-055's own separate deliverable
   status) — this design closes that gap for the `join_counters` field specifically, without
   claiming to close it for every field.

### 3.4 What is *not* proven here

This design does not add row-locking on `tokens` (REQ-048's own OQ-5, unchanged, still open) —
a concurrent split/join-producing call that also needs to observe another call's `tokens`-row
changes beyond what `instance_projections.join_counters`/`variables`/`current_nodes` already
expose is out of this fix's scope, restated as OQ-3 (§7) rather than silently assumed safe.

---

## 4. Migration

New file, e.g. `priv/repo/migrations/20260901030001_add_join_counters_to_instance_projections.exs`
(exact timestamp ELIXIR-DEV's choice; must sort after
`20260818110001_alter_instance_projections_add_engine_columns.exs`, the migration that created
the table's engine-owned columns this one extends). Tenant-scoped `if prefix() do` guard
mandatory (REQ-022 §4), matching `20260901000001_add_content_to_repository_artifacts.exs`'s
addendum style (§0) — moduledoc-as-header-comment stating: what requirement/issue this closes,
that it is an addendum to the already-`done` REQ-043 table (not a new table, does not alter that
requirement's own acceptance criteria), and — **unlike** the `repository_artifacts` addendum,
whose header could truthfully claim "no rows exist yet" — this migration's header must state
explicitly that `instance_projections` **does** carry live rows in every provisioned tenant by
this point (every `create/2` call since REQ-045 shipped inserts one), which is exactly why this
column needs a real DB-level default rather than relying on "table is empty" as
`20260901000001`'s header did:

```
add :join_counters, :map, null: false, default: %{}
```

— the identical idiom `20260818110001`'s own `:variables` column already uses and that
migration's header comment (§0) confirms is accepted by Ecto's migration DSL for a bare map
literal (unlike the `current_nodes` list-shaped case, which needed `fragment("'[]'::jsonb")`).
No index is added — `join_counters` is never queried/filtered on by column value anywhere in this
design (always read/written by `instance_id` primary-key lookup, which `instance_projections`
already has via its own `@primary_key {:instance_id, ...}`), unlike `instance_state_snapshots`'s
composite index (REQ-054), which exists to serve a "latest row for this instance" query this
table's single-row-per-instance shape has no equivalent need for.

**Registration (mandatory, both halves):** the migration file's own `if prefix() do` guard, **and**
a new entry appended to `Letflow.TenantProvisioning.@tenant_scoped_migration_manifest` (plus
`tenant_scoped_migrations/0` picks it up automatically, unchanged) — a migration with one but not
the other is either inert or corrupts `public` on a plain `mix ecto.migrate`, per every prior
tenant-scoped migration's own header warning (confirmed §0).

---

## 5. Test design (TEST-DESIGNER's job to implement; specified, not implemented, here)

ISSUE-FIXER's own diagnosis (handoff §6) confirmed **zero** existing coverage exercises this
defect's actual cross-call path — `parallel_gateway_test.exs` is pure/in-memory,
`req208_meridian_test.exs`'s two scenarios currently assert the *broken* behavior. TEST-DESIGNER
needs at minimum:

### 5.1 Serial cross-call happy path (baseline — must exist before the concurrent test)

Using `graph_start_parallel_split_human_tasks/0`'s fixture shape (`test/letflow/engine_test.exs`
~154-196, reused/duplicated into the new test file per that file's own local-fixture
convention — confirm at implementation time whether it is exported or must be copied):

1. Real `Engine.create/2` call — produces an instance with two `PENDING` tasks, one per branch
   (`task_a`, `task_b`), and (post-fix) a durably persisted `join_counters` row entry for the
   join node with both branches in `expected_from_branches`, `received_from_branches: #{}`.
2. **First, separate** `Engine.complete_task(task_a.id, ..., prefix: schema_name)` call. Assert:
   `{:ok, _}` with `instance_status: :active` (the join has not fired — one branch outstanding);
   read `instance_projections` back via `Repo.get!/3` and assert its `join_counters` column
   contains the join node's entry with `received_from_branches` now including branch `a`'s id
   and the join node still present (not deleted).
3. **Second, separate** `Engine.complete_task(task_b.id, ..., prefix: schema_name)` call (a
   genuinely distinct top-level function invocation from step 2 — this is the exact case
   `build_instance_state/3`'s hardcoded `%{}` broke). Assert: `{:ok, _}` with `instance_status:
   :completed` (or `:active` with `current_nodes` past the join, depending on what follows `J` in
   the fixture graph — whichever the fixture graph's own topology implies), and that
   `instance_projections.join_counters` no longer contains an entry for `J` (the cohort fired and
   was deleted).
4. **Negative control (pre-fix behavior, regression-locking):** this same two-call sequence,
   run against the pre-fix code, must have failed step 3 with
   `{:error, {:transition_failed, {:unknown_branch_id, _}}}` — TEST-DESIGNER should note this in
   the test's own comment (mirroring `req208_meridian_test.exs`'s own now-superseded assertions)
   so a future reader understands what regression this test locks in, without needing to check
   out the pre-fix revision to find out.

### 5.2 Concurrent sibling-branch completion (the test that actually stresses the locking argument, §3.3)

Following `engine_cancel_instance_test.exs`'s own "AC4 — run concurrently, not sequentially"
precedent (§0) — `provisioned_tenant/0` with `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo,
:auto)` (real, separate Postgres connections; **not** the default shared-sandbox-per-test-process
mode, which would artificially serialize what this test needs to be a genuine race):

1. Real `Engine.create/2` call, same fixture as §5.1, producing `task_a`/`task_b` both `PENDING`.
2. Two `Elixir.Task.async/1` calls, each independently invoking
   `Engine.complete_task(task_a.id, ..., prefix: schema_name)` and
   `Engine.complete_task(task_b.id, ..., prefix: schema_name)` respectively, **started as close
   to simultaneously as the test can arrange** (no artificial delay between the two `Task.async`
   calls) — real concurrent execution via two independent BEAM processes and two independent
   Postgres connections, not two sequential calls dressed up as concurrent.
3. `Elixir.Task.await_many/2` both, then assert on the **pair** of results jointly (order
   unknown, per §3.3's "whichever happens to complete second" — the test must not assume which
   of the two `Task.async` calls is the one that observes `:fire`):
   - Exactly one of the two results has `instance_status` reflecting the post-join state
     (`:completed`, or `current_nodes` past `J`) and the other has `instance_status: :active`
     with `current_nodes` still resting on its own now-consumed branch's node — i.e. exactly one
     call's hop-chain is the one that actually fired the join, not both (double-fire) and not
     neither (join never fires, e.g. a lost-update bug where the second call overwrites the
     first's `received_from_branches` entry instead of merging with it).
   - Reading `instance_projections` back once both calls have committed: `join_counters` contains
     **no** entry for `J` (fired and deleted) — not a corrupted/partial entry from a lost update.
   - Reading both `tasks` rows back: both `task_a` and `task_b` are `:completed` — no lost update
     dropped one branch's own completion despite the join-counter race.
4. **Explicit non-goal, stated so TEST-DESIGNER does not over-fit:** this test does not assert
   *which* of the two `Task.async` calls "wins" the M2 lock race (genuinely non-deterministic,
   real wall-clock/scheduler dependent) — only that the **outcome** is correct regardless of which
   one does, matching §3.3's own walkthrough framing ("whichever happens to complete second").

### 5.3 Timer-fire path parity (smaller, but required — same write function is shared)

Since §2.4 confirms `reconcile_projection/5` is shared between `complete_task/3` and
`advance_after_timer_fired/3`, at least one test should confirm a hop-chain reached via a fired
timer (not a completed task) also durably persists/reads `join_counters` correctly across two
separate `advance_after_timer_fired/3` calls (or one `complete_task/3` call opening the cohort and
one `advance_after_timer_fired/3` call closing it, if the fixture graph makes a timer-driven
branch arrival more natural to construct) — the existing `test/letflow/engine/timer_wiring_test.exs`
(confirmed §0 to already use `PARALLEL_GATEWAY` fixtures) is the natural home, or a new
`describe` block there, rather than a wholly separate file.

### 5.4 Round-trip / codec unit test

A narrower, single-process test for `SnapshotWriter.serialize_join_counters/1` /
`deserialize_join_counters/1` (§2.3) round-tripping a `%{join_node_id => %JoinCounter{...}}` map
with non-empty `expected_from_branches`/`received_from_branches`/`cancelled_branches`
`MapSet`s — confirms the promoted-to-public functions behave identically to the
already-`SnapshotWriter`-tested inline logic they replace (a pure, `Repo`-free test, sibling to
whatever existing `SnapshotWriter` test module covers `serialize_state/1`/`deserialize_state/2`
today — TEST-DESIGNER should locate and extend that file rather than create a new one, per this
codebase's stated preference against duplicate test files for one module).

---

## 6. Coordination note — REQ-052's `cancel_instance/3` decision (found during this design, not asked for by the task prompt, but load-bearing)

`docs/migration/decisions/`-adjacent design doc `req052-instance-cancellation.md` §4 and its own
"OQ-2 (MAJOR) — RESOLVED 2026-08-22, GH#326" section state, as their own load-bearing rationale
for **not** driving `{:cancel_branch, branch_id}` through `Transition.transition/3` from
`cancel_instance/3`: *"the join-counters persistence gap makes driving `{:cancel_branch, _}` here
a no-op today."* This fix **removes exactly that gap** for the `complete_task/3`/
`advance_after_timer_fired/3` paths (§2). `cancel_instance/3` itself is **not** touched by this
design (§2.4) — it still never calls `Transition.transition/3`, still uses its own
`cancel_instance_projection/4` write path, and still does not durably record cancelled branches
in any `JoinCounter.cancelled_branches` set.

This is **not** silently re-deciding REQ-052's own recorded decision — this design does not
change `cancel_instance/3`'s behavior at all. But the stated *reason* for that decision (no
persistence existed to make wiring `{:cancel_branch, _}` meaningful) is no longer fully true once
this fix ships: `join_counters` is now durable, so a future requirement *could* wire
`{:cancel_branch, _}` through `cancel_instance/3` meaningfully, where REQ-052's own text says
today it could not. **Flagged explicitly for REVIEWER/ORCH**, not resolved here: whether
REQ-052's OQ-2 resolution should be revisited now that its own cited blocker is gone is a
decision-record question this design does not have the authority or the requirement text scope
to make unilaterally (per `core-directives.md`'s "don't silently re-decide what a decision record
already settled" — this cuts the other way here: the decision's own *premise* changed, which is
exactly the kind of drift that rule exists to surface, not to auto-resolve). No code in this
fix's own scope depends on this note being acted on.

---

## 7. Open questions — explicitly listed, not silently resolved

**OQ-1 (MINOR, inherited not new).** `JoinCounter` is keyed by `join_node_id` alone
(`req051-parallel-gateway-split-join.md` §12.1's own pre-existing open question, restated here
because this fix makes it durable rather than transient): a second split reaching the same join
node while an earlier cohort is still outstanding (loop re-entry) overwrites the earlier entry in
memory today, and this fix makes that overwrite durable too, in exactly the same way. This fix
neither introduces nor worsens this limitation — it was already true of the in-memory-only
behavior within a single hop-chain; flagged for REVIEWER only as "still true, now durable" context.

**OQ-2 (MINOR).** §2.3's choice to host `serialize_join_counters/1`/`deserialize_join_counters/1`
on `Letflow.Engine.SnapshotWriter` (refactored out of its existing private codec) rather than on
`Letflow.Engine.JoinCounter` itself (a `to_map/1`/`from_map/1` pair, symmetric with how
`SnapshotWriter` would then depend on `JoinCounter` rather than `Letflow.Engine` depending on
`SnapshotWriter`). This design's reasoning (touch one existing module vs. add public API to a
struct three requirements already treat as fields-only) is a judgment call, not dictated by any
cited source — REVIEWER should confirm or direct the alternative.

**OQ-3 (MINOR, inherited not new — restated for this fix's own scope).** REQ-048 design's own
OQ-5 (`tokens` rows not locked by `complete_task/3`, only `tasks`/`instance_projections`) remains
open and is not addressed by this fix. §3.4 states explicitly that this fix's correctness
argument does not depend on resolving OQ-5, but a future, broader same-instance concurrency
requirement (REQ-048's own text names a possible "REQ-055" successor that does not appear to have
shipped under that number) should re-examine whether `tokens`-row locking is needed for
correctness this fix's narrower argument does not need to claim.

**OQ-4 (MINOR).** §5.3's timer-fire parity test placement (existing `timer_wiring_test.exs` vs. a
new file) is left to TEST-DESIGNER's judgment based on that file's current size/organization at
implementation time — not dictated here.

---

## 8. Interaction with ISS-0396 — confirmed no overlap (independently re-derived, not just cited)

Read `docs/issues/ISS-0396.yaml` directly (§0): its defect is an `Ecto.Multi` `:task_records`
step-key collision inside `build_complete_task_tail_multi/6`'s SUB_PROCESS-child-completion
cascade branch (`append_sub_process_children_creation_multi/6` /
`append_sub_process_completion_cascade_multi/6`, engine.ex ~2497-2570), triggered when two or
more `SUB_PROCESS` children spawned from the same hop chain both complete synchronously inside
the same parent transaction. This fix's own changes are confined to:

- `build_instance_state/3` (~1813) — a different function, read-only concern (§2.5).
- `reconcile_projection/5` (~2821) — a different function than any of ISS-0396's named functions,
  called from a different position in the Multi (M10, `:projection`) than ISS-0396's `:task_records`
  step.
- `Letflow.Engine.SnapshotWriter` (new public functions, §2.3) and
  `Letflow.EventStore.InstanceProjection` (new column/changeset field, §2.2) — neither touched by
  ISS-0396's own fix scope at all.

No function this fix modifies is named in ISS-0396's own diagnosis, and no function ISS-0396
would modify is named in this design. **Genuinely safe to land in either order** — restated (not
merely trusted) after independently re-reading ISS-0396's own issue text, per this task's
explicit instruction not to take ISSUE-FIXER's non-overlap claim on faith. If ISS-0396's fix
lands first and touches `build_complete_task_tail_multi/6`'s structure in a way that moves or
restructures the `:projection` `Multi.run/3` step's position (unlikely, since ISS-0396's own
scope is the SUB_PROCESS cascade steps that already run *after* `:projection` in the current step
table, §0's `build_complete_task_tail_multi/6` excerpt), whichever fix lands second should
re-verify `reconcile_projection/5`'s call site is still reached with the same `final_instance_state`
argument this design's §2.4 change assumes.
