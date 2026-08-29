# REQ-187 — Wire TIMER nodes into the engine (design)

Closes the three named stubs in `lib/letflow/engine/transition.ex` L294,
`lib/letflow/engine/task_activation.ex`'s `cancel_pending_timers/2`, and
`lib/letflow/engine.ex` L234-242's `cancel_instance/3` deferral, and adds the
one piece of genuinely new machinery none of the three stubs cover: the
poller's fire path re-entering the engine to advance the token off the
`:TIMER` node. Depends on REQ-186 (shipped: `lib/letflow/scheduler.ex`,
`lib/letflow/scheduler/timer.ex`) and reuses `Letflow.Engine.Reconstruction`
(REQ-053), `Letflow.Engine.TaskActivation` (REQ-047), and
`Letflow.Engine.SubProcess` (REQ-062) unchanged except where named below.

No fenced Elixir source is reproduced in this document — every shape below
is stated as prose, a table, or a `@spec`-style one-line signature written
as inline code, matching this pipeline's design-doc convention.

## 0. The three named stubs, and the one non-stub addition

| # | Location | What changes |
|---|---|---|
| (a) | `transition.ex` L290-295, the `dispatch_node/4` catch-all | Gains a real `:TIMER` clause above the catch-all; the catch-all itself now only covers `:SERVICE_TASK` and any truly-unknown node type (its own comment, currently "`:SERVICE_TASK`, `:TIMER` ... the 2 remaining variants", is corrected to name only `:SERVICE_TASK`) |
| (b) | `task_activation.ex` L338-339, `cancel_pending_timers/2` | No-op replaced with a real, status-guarded `update_all`; arity widened (see §5) |
| (c) | `engine.ex` L234-242, the `cancel_instance/3` moduledoc deferral | The timer half is implemented; the REQ-056 SERVICE_TASK HTTP-abort half stays deferred, untouched |
| (new) | `scheduler.ex`'s `do_fire/2` + `attempt_fire/2` | One new call into `Letflow.Engine`, one new case clause — the "firing re-enters the engine" mechanism (§7-§8) |

## 1. `transition.ex` — the extended return shape (AC1, AC7)

**Exactly which shape is extended:** `Letflow.Engine.Transition`'s `pending_event()` type — the tagged-union list every `transition/3` call already returns as the third element of its `{:ok, InstanceState.t(), [pending_event()]}` success tuple. This is the SAME mechanism `:SUB_PROCESS` already uses: `dispatch_sub_process_entry/4` leaves the token in place and returns a `{:sub_process_start, token_id, node_id}` pending event instead of writing anything itself; the impure caller (`engine.ex`) is the one that turns that description into real child-instance rows. Arming a timer is designed as the same pattern's fourth variant, not a new mechanism.

### 1.1 New `pending_event()` variant

`{:timer_armed, token_id :: String.t(), node_id :: String.t()}` — deliberately carries no duration and no timestamp. `transition.ex` has the node's `duration_iso8601` attribute available (it is on `Node.attributes`, part of the pure `definition_snapshot` argument), but resolving it into an absolute `fire_at` requires a clock read (`arrival time + parsed duration`), which the purity contract forbids inside this module. So, exactly like `{:sub_process_start, token_id, node_id}` (whose consumer re-fetches the node from `graph.nodes` to read its `interface` attribute), the impure caller re-resolves `node_id` against its own already-loaded `Graph.t()` to read `duration_iso8601` and do the parse-and-add-now step outside this module. `node_id` in the tuple is redundant with `token.node_id` at emission time but is included for the same reason `{:sub_process_start, ...}` includes it — the consumer receives pending events as a flat list, decoupled from any token lookup.

### 1.2 New `transition_event()` variant

`{:timer_fired, token_id :: String.t()}` — mirrors `{:complete_task, token_id}` exactly: the caller's explicit "this token's timer just fired, evaluate its outgoing edge" signal, dispatched through `transition/3`'s outer `case` the same way (`find_token/2`, then `find_node/2`, then a dedicated dispatch function), added to the module's `@type transition_event` union as a fourth constructor alongside the three already documented there.

### 1.3 New `transition_error()` variant

`{:token_not_at_timer, node_type :: atom(), node_id :: String.t()}` — the defensive guard clause paired with the new dispatch function below, mirroring `{:token_not_at_human_task, node_type, node_id}`'s own existing role for `{:complete_task, token_id}`.

### 1.4 New dispatch clauses

* `dispatch_node/4` gains a clause matching `%Node{node_type: :TIMER}`, placed alongside the `:HUMAN_TASK`/`:SUB_PROCESS` clauses and above the catch-all. It calls a new private `dispatch_timer_arrival/3`, which — like `dispatch_human_task/3` — does **not** move the token and does **not** touch `pending_task_nodes` (that list is `:HUMAN_TASK`-specific bookkeeping for `TaskActivation`'s own `tasks` row materialization; a `:TIMER` node needs no `tasks` row). It returns `{:ok, instance_state, [{:timer_armed, token.token_id, node.id}]}` with `instance_state` otherwise unchanged.
* A new private `dispatch_timer_fired/4`, reached from `transition/3`'s new `{:timer_fired, token_id}` outer-case clause (which does the same `find_token/2`/`find_node/2` resolution the `{:complete_task, token_id}` clause already does), handling exactly two cases:
  * `%Node{node_type: :TIMER}` — reuses `advance_off_completed_node/4` unchanged against that node's own outgoing edges (`Enum.filter(definition_snapshot.edges, &(&1.source == node.id))`), the identical shared step `dispatch_task_completion/4` and `dispatch_sub_process_completion/4` already call. A `:TIMER` node is expected to have exactly one outgoing edge with no condition (structurally unenforced today — CHK-12 validates only the duration attribute, not out-degree — so `advance_off_completed_node/4`'s existing declared-order/default-last algorithm is what actually resolves it if more than one edge is ever present, with no `:TIMER`-specific narrowing added).
  * Any other node type (defensive-only, mirrors `dispatch_task_completion/4`'s own second clause) — returns `{:error, {:token_not_at_timer, node_type, node_id}}`.

### 1.5 Purity — no new Repo/clock call

Neither `dispatch_timer_arrival/3` nor `dispatch_timer_fired/4` reads `node.attributes["duration_iso8601"]`'s parsed value, calls `DateTime.utc_now/0`, or touches `Letflow.Repo`/`Letflow.Scheduler` in any form — `dispatch_timer_arrival/3` only reads `token`/`node.id` (already-supplied arguments) and `dispatch_timer_fired/4` only reads `definition_snapshot.edges`. The moduledoc's existing "Purity (AC1)" section gains one sentence naming `pending_event()`'s new `{:timer_armed, ...}` variant as the shape SCH-01's timer-arming description travels through, and the existing grep command (moduledoc, already covering `Repo\.`/`Logger\.`/`DateTime\.`/etc.) is re-run unchanged as this requirement's own AC7 verification — no new pattern needs adding to the grep, since no new forbidden call is introduced.

## 2. `graph.ex` — `parse_iso8601_duration/1` (new, public)

CHK-12's `valid_iso8601_duration?/1` only validates shape; nothing in the tree today converts a valid `duration_iso8601` string into an actual time delta. Rather than a second, independently-written parser living in `engine.ex` (risking silent divergence from CHK-12's own accepted grammar — the exact "two copies diverging" risk this codebase's own `advance_until_stable/4` moduledoc already warns against for a different function), this requirement adds one new public function to `Letflow.Definitions.Graph`, alongside `valid_iso8601_duration?/1`, sharing its token-scanning helpers:

`@spec parse_iso8601_duration(String.t()) :: {:ok, seconds :: non_neg_integer()} | :error`

Only ever called by `engine.ex` (the impure caller), never by `transition.ex` — it is pure (no clock, no I/O) but lives in the `Definitions` layer since it is a definition-format concern, matching `valid_iso8601_duration?/1`'s own placement.

**Unit-to-seconds convention (flagged assumption, not stated by any requirement text read for this design):** `Y` = 365 days, `M` (date part) = 30 days, `W` = 7 days, `D` = 1 day, `H` = 3600 s, `M` (time part) = 60 s, `S` = 1 s — a fixed-length calendar approximation (no real calendar-month/leap-year arithmetic), matching the simplest reading of "duration" for a workflow delay timer and avoiding a `DateTime`/timezone-aware calendar dependency inside a function `graph.ex`'s existing dependency-free module keeps pure. **Flagged for REVIEWER/TEST-DESIGNER sign-off** — if a calendar-accurate `Y`/`M` is actually required (e.g. "P1M" must mean "the same day next month," not "30 days later"), this function's internals change but its `@spec` and every call site stay identical, so the blast radius of getting this wrong is contained to this one function.

## 3. Arming — the impure caller, in one transaction with the state-transition event (AC1, AC2)

**Which module is the impure caller:** `Letflow.Engine` — specifically, both places `pending_events` already flow out of a `Transition.transition/3`/`advance_until_stable/4` call before a `Multi` is built: `start_instance/5`'s `prepare_sub_process_children/5` step, and `complete_task/3`'s `prepare_sub_process_children_for_completion/7` step. Both gain a symmetric, new preparation step for `{:timer_armed, ...}` pending events, run the same way — before the `Multi` opens, since the preparation itself (node lookup + duration parse) needs no DB write and must not silently swallow a malformed graph.

### 3.1 `prepare_timer_arms/4` (new, private, one copy shared by both call sites)

`@spec prepare_timer_arms([Transition.pending_event()], Graph.t(), instance_id :: Ecto.UUID.t(), now :: DateTime.t()) :: {:ok, [{token_id :: String.t(), arm_attrs :: map()}]} | {:error, {:graph_structure_invalid, {:unknown_node_id, String.t()}}} | {:error, {:invalid_timer_duration, node_id :: String.t(), value :: term()}}`

Filters `pending_events` for `{:timer_armed, token_id, node_id}` (matching `prepare_sub_process_children/5`'s own `Enum.filter(&match?({:sub_process_start, _, _}, &1))` precedent exactly), and for each: looks the node up in `graph.nodes`, reads `node.attributes["duration_iso8601"]`, calls `Graph.parse_iso8601_duration/1`, and on success builds `arm_attrs = %{instance_id: instance_id, timer_type: "deadline", node_id: node_id, fire_at: DateTime.add(now, seconds, :second)}` (`token_id` deliberately absent here — filled in once the real `TokenRecord` id is known, §3.2). The `:invalid_timer_duration` error is defensive-only (CHK-12 already rejects an invalid `duration_iso8601` at definition-approval time, so a `:TIMER` node reaching `create/2` with one should be unreachable) — kept for this codebase's "never raise" totality discipline, not a literal AC.

`now` is read exactly once, by the caller, before this function runs — `start_instance/5` and the `complete_task/3` completion tail each already have (or gain) one `DateTime.utc_now() |> DateTime.truncate(:microsecond)` call at their own top level, matching `cancel_instance/3`'s existing `cancelled_at`-precomputed-before-the-transaction precedent — so "the arrival timestamp" (AC1) is one fixed instant per hop-chain, not a fresh clock read per timer.

`timer_type: "deadline"` is a flagged pick among `Letflow.Scheduler.Timer`'s four allowed values (`"deadline"`, `"reminder"`, `"escalation"`, `"scheduled_transition"`, per `timer.ex`'s `@timer_types`) — none of the four is defined by any REQ-186/187 text read for this design. "Deadline" is chosen because a plain intermediate `:TIMER` node blocks flow until a duration elapses, which is what "deadline" most plausibly names; `"escalation"` and `"scheduled_transition"` read as reserved for REQ-188's own escalation-timer and recurrence work. **Flagged for REVIEWER** — if wrong, only this one literal string changes.

### 3.2 Wiring into the `Multi` (one transaction with the event — AC2)

Both `persist/11` (create path) and `build_complete_task_tail_multi/6`'s `:advanced` clause (completion path) gain a new `Multi.merge/2` step, positioned immediately after the step that resolves real `TokenRecord` ids (`:token_record` in `persist/11`; the token-reconciliation step in the completion tail) and before `:event` — matching exactly where `build_sub_process_children_multi/5` and `append_sub_process_children_creation_multi/6` already sit relative to `:event` in each of those two functions. New `build_timer_arms_multi/4`:

`@spec build_timer_arms_multi(Multi.t(), [{token_id :: String.t(), arm_attrs :: map()}], id_map :: %{String.t() => String.t()}, prefix :: String.t()) :: Multi.t()`

For each `{token_id, arm_attrs}`, resolves `token_record_id = Map.fetch!(id_map, token_id)` (the exact same `TaskActivation.token_id_to_record_id/2` map `build_sub_process_children_multi/5` already builds and reuses — no second id-mapping mechanism), and calls `Letflow.Scheduler.create(acc_multi, Map.put(arm_attrs, :token_id, token_record_id), prefix: prefix)` — REQ-186's own documented `Multi.t()`-accepting branch of `create/2`, which appends one named `Multi.insert/4` step and returns the extended, still-unexecuted `Multi.t()`. Because this step and the `:event` step both live in the same `Multi.new() |> ... |> Repo.transaction()` chain, `Ecto.Multi`'s own all-or-nothing semantics is what satisfies AC2 ("a test that forces the event append to fail leaves NO timers row behind") — no special step ordering is required for that guarantee beyond "both steps belong to the same `Multi`," though placing the timer-arm step before `:event` (as specified) keeps this function textually next to its `:sub_process_start` sibling.

No `Ecto.Multi` name collision: each timer-arm step is named `{:scheduler_timer, token_id}`-style via whatever unique name `Scheduler.create/2`'s own `Multi.insert(multi, :scheduler_timer, ...)` call uses today — since REQ-186 hardcodes the literal atom `:scheduler_timer` as the step name, arming **more than one** `:TIMER` node in the same hop-chain would collide inside one `Multi` (`Ecto.Multi` requires unique step names). **Flagged for REVIEWER/ELIXIR-DEV**: either confirm this scenario cannot occur in the acceptance-criteria scope (a single `:advance_token` hop-chain reaching two distinct `:TIMER` nodes in one `create/2`/`complete_task/3` call — e.g. two parallel branches both landing on a `:TIMER` node in the same activation burst), or widen `Scheduler.create/2`'s `Multi` branch to accept a caller-supplied step name instead of the hardcoded `:scheduler_timer` atom before wiring `build_timer_arms_multi/4` to call it more than once per `Multi`. This document does not silently assume single-timer-per-hop-chain to be always true.

## 4. `pending_task_nodes`-style bookkeeping — none needed

Unlike `:HUMAN_TASK`, a `:TIMER` node's "is this position still open" question is answered entirely by the `timers` table's own `status` column — there is no Letflow-side in-memory list of "currently armed timer nodes" analogous to `pending_task_nodes`, and none is added. `Reconstruction`'s replay (§9) does not need one either, for the same reason `TASK_COMPLETED` replay does not need a persisted `token_id` (§9).

## 5. Cancellation on completion (AC4)

### 5.1 `TaskActivation.cancel_pending_timers/2` — arity widened to `/4`

Current: `cancel_pending_timers(instance_id, prefix) :: :ok`, a no-op. New: `@spec cancel_pending_timers(repo :: Ecto.Repo.t(), instance_id :: Ecto.UUID.t(), cancelled_at :: DateTime.t(), cancel_reason :: String.t(), prefix :: String.t()) :: {:ok, non_neg_integer()}` — an additive-arity widening (this codebase's own precedent for this exact move: `Reconstruction.replay/3` became `replay/4` for REQ-054 without breaking its one existing caller's shape, just adding a parameter). Returns `{:ok, count}` (the number of rows actually updated, from `Repo.update_all/3`'s own return shape) rather than bare `:ok`, so a caller/test can assert "at least one row changed" without a second query.

Body: one `Letflow.Scheduler.Timer |> where([t], t.instance_id == ^instance_id and t.status == "pending") |> repo.update_all([set: [status: "cancelled", cancelled_at: cancelled_at, cancel_reason: cancel_reason]], prefix: prefix)` — a single, status-guarded `UPDATE ... WHERE status = 'pending'` statement. This is the "status-guarded UPDATE" the requirement's SCH-03 paragraph asks for (§7 discusses why this is also what makes the concurrency edge case resolve without extra locking): Postgres re-evaluates the `WHERE` predicate against each row's current committed state as it acquires that row's lock, so a row a concurrent `fire_timer/2` has already flipped to `"fired"` (and committed) is simply not touched by this statement — no separate `SELECT ... FOR UPDATE` pass, no extra lock beyond the one `update_all/3` itself takes.

Two known call sites, two `cancel_reason` values (both literal strings, not a shared constant — this function's own `@doc` names both so a future caller doesn't have to guess a third):

* `"instance_completed"` — from `finalize_instance_projection/5` (§5.2).
* `"instance_cancelled"` — from `cancel_instance/3` (§6).

### 5.2 The one call site: `engine.ex`'s `finalize_instance_projection/5`, unmoved

The `:completed` clause (currently `finalize_instance_projection(repo, projection, :completed, prefix, instance_id)`, L1160-1181) keeps its own `repo.update/2` call for the `instance_projections` row exactly where it is, and its existing `:ok = TaskActivation.cancel_pending_timers(instance_id, prefix)` line — immediately after that `repo.update/2` succeeds, still inside the same `Multi.run(:finalize, ...)` step, unmoved per the handoff's explicit instruction — becomes `{:ok, _count} = TaskActivation.cancel_pending_timers(repo, instance_id, attrs.completed_at, "instance_completed", prefix)`, reusing the SAME `completed_at` timestamp the surrounding clause already computed (`attrs = %{status: :completed, completed_at: DateTime.utc_now()}`, one line above) for `cancelled_at` too — no second clock read. `git diff` against this clause shows the call's line position unchanged; only its arity and its right-hand-side pattern change (AC4's own explicit "confirmed by git diff showing the call site itself unmoved").

**Scope note, flagged rather than silently absorbed:** `finalize_instance_projection/5` is reached only from `persist/11` (`create/2`'s own Multi) — `complete_task/3`'s own completion tail uses a different function, `reconcile_projection/5`, which has no equivalent timer-cancellation call and is not given one by this design. The handoff's own text ties AC4 to "the existing `TaskActivation.cancel_pending_timers/2` call site ... which is still called from the same position" (singular, named site) and separately instructs "do not relocate it" — read together as scoping AC4 to this one call site, not as silently requiring a second, new call site inside `complete_task/3`. By construction this is not a live product gap for the common "an instance's last task completes while some other branch still has a pending timer" scenario: `dispatch_end/3`'s own completion rule ("status becomes `:completed` iff no token remains live") means a `:TIMER`-parked token — which, like a `:HUMAN_TASK`-parked one, is never removed by an ordinary hop — keeps `remaining_tokens` non-empty, so an instance cannot reach `:completed` via `complete_task/3` while a `:TIMER` node still holds a live token. If a future requirement changes that invariant (e.g. a `:TIMER` node that does not block completion), `reconcile_projection/5` gaining its own `cancel_pending_timers/4` call is that future requirement's job, not silently done here.

## 6. Cancellation via `cancel_instance/3` (AC5) — and the lock-ordering fix this requires (SCH-03)

### 6.1 New Multi step, and exactly where it sits

`run_cancel_instance/5`'s `Multi` gains one new step, `:timer_cancellations`, calling `TaskActivation.cancel_pending_timers(repo, instance_id, cancelled_at, "instance_cancelled", prefix)`. It is placed **immediately after `:open_tasks` (M1) and before `:instance_projection` (M2)** — not after `:eligibility`/`:task_cancellations` as its topical grouping might suggest. This positioning is load-bearing, not cosmetic (§6.2).

Because it runs before `:eligibility` (M3) has confirmed the instance isn't already terminal, an ineligible `cancel_instance/3` call (already-`:completed`/`:cancelled` instance) still has its own timer-cancellation `update_all` executed — but since `Ecto.Multi` rolls back the **entire** transaction the moment any later step returns `{:error, _}` (here, `:eligibility`'s own `{:error, {:instance_already_terminal, status}}`), that `update_all`'s effects are rolled back too. No row is left changed by an ineligible cancel attempt.

### 6.2 Why this ordering, not the topically-obvious one, avoids a deadlock

`Letflow.Scheduler.fire_timer/2` (REQ-186, unchanged in its own step order) locks a `timers` row first (`fetch_and_lock_timer/2`, its own first action) and only reaches `instance_projections` second — inside the new `advance_after_timer_fired/3` call this requirement adds at the end of `do_fire/2` (§7-§8). If `cancel_instance/3` locked `instance_projections` (M2) **before** touching any `timers` row (the naturally-obvious placement, grouped with the other cancellation steps after `:eligibility`), the two code paths would acquire their two shared locks in opposite global order — `cancel_instance/3`: `instance_projections` then `timers`; `fire_timer/2`: `timers` then `instance_projections` — the textbook precondition for a Postgres deadlock (each transaction holds the lock the other is waiting for). Placing `:timer_cancellations` before `:instance_projection` makes both code paths acquire `timers` before `instance_projections`, uniformly, which is what actually resolves the requirement's own "first transaction to commit wins, the other rolls back" language into ordinary lock-wait-then-proceed behavior instead of a deadlock: whichever of the two transactions reaches the contested `timers` row first makes the other block on that table (not on `instance_projections`) until the first one finishes (commits or rolls back) — at which point the second either finds nothing left to touch (`update_all`'s `WHERE status = 'pending'` silently skips an already-`"fired"` row; `advance_after_timer_fired/3`'s own `instance_projections` lock-and-check, §8.1, finds a now-terminal status and rolls its own transaction back) or proceeds normally.

No new explicit locking is introduced anywhere in this section — the fix is a **step-ordering** change inside an already-existing `Multi`, exactly matching the requirement's own "without any additional locking beyond what already exists" instruction.

### 6.3 The rollback test (AC5)

`cancelled_at` is computed once, before `run_cancel_instance/5`'s `Multi` opens (already true today, unchanged). A test forcing a later step (e.g. `:event`) to fail observes the whole transaction roll back, per `Ecto.Multi`'s existing all-or-nothing semantics — the `:timer_cancellations` step's `update_all` is rolled back along with every other step, leaving any timer this test seeded still `"pending"`.

## 7. Firing — the hook point in `scheduler.ex` (AC3)

**Answering the handoff's own named question directly: `Scheduler.poll_and_fire/1` itself needs no new hook — `do_fire/2` (one level down, already the single place a timer transitions to `"fired"`) gets one new, explicit call into `Letflow.Engine`.** The poller's fire path re-enters the engine's own transition/completion machinery; it does not grow a second, parallel advancement mechanism.

### 7.1 `do_fire/2`'s one new line

Today `do_fire/2`'s `with` chain is: update the timer row to `"fired"`, then `append_timer_fired_event/4`, returning `{:ok, :fired}` on both succeeding. This requirement adds a third `with` clause, run only after `append_timer_fired_event/4` succeeds and before the function returns: `{:ok, :advanced} <- Letflow.Engine.advance_after_timer_fired(timer, Repo, tenant_schema)` (or `{:ok, :instance_not_active}`, see below) — still inside the SAME `Repo.transaction(fn -> ... end)` `fire_timer/2` already opens, so the timer-row flip, the `TIMER_FIRED` event append, and the token's advance off the `:TIMER` node all commit or all roll back together. `Repo` here is `Letflow.Repo` itself (the alias `scheduler.ex` already has) — `advance_after_timer_fired/3` runs as ordinary sequential calls inside an already-open transaction function, not as a `Multi.run/3` callback, so it receives the literal repo module, not an `Ecto.Multi`-injected one; its own internal `Multi` (§8.4) still works correctly nested this way (Ecto transparently uses a `SAVEPOINT` for a `Repo.transaction/1` call issued from inside another already-open transaction).

### 7.2 `attempt_fire/2`'s one new case clause

`advance_after_timer_fired/3` returns `{:error, {:instance_not_active, status}}` (§8.1) when it finds the instance already terminal — a real, named error that makes `do_fire/2`'s `with` chain fail and `fire_timer/2`'s outer `case` call `Repo.rollback({:instance_not_active, status})`, so the whole attempt (including the timer-row flip and event append) rolls back cleanly — this is what actually prevents "a fired timer on a cancelled instance" (SCH-03), not a special case inside `do_fire/2` itself. But this specific reason must **not** be treated as a firing failure by `attempt_fire/2`'s existing `{:error, _reason} -> safe_record_fire_failure(...)` catch-all, or a legitimate SCH-03 race would wrongly increment `fire_error_count` and eventually land the timer in `dlq_entries`. `attempt_fire/2` gains one new clause, matched **before** that catch-all: `{:error, {:instance_not_active, _status}} -> :already_final`. No other part of `attempt_fire/2`, `poll_and_fire/1`, or the failure-accounting path (`record_fire_failure/2`, `land_exhausted_timer/3`) changes.

## 8. `Letflow.Engine.advance_after_timer_fired/3` (new, `@doc false`)

`@spec advance_after_timer_fired(timer :: Letflow.Scheduler.Timer.t(), repo :: Ecto.Repo.t(), prefix :: String.t()) :: {:ok, :advanced} | {:error, {:instance_not_active, atom()}} | {:error, term()}`

`@doc false`, matching `advance_until_stable/4`'s and `build_graph/1`'s own existing precedent for a function that is technically public (cross-module callable — here, from `Letflow.Scheduler`) but not part of `Letflow.Engine`'s documented client API. Lives in `engine.ex` itself (not a new module) so it can freely call the module's own existing private helpers rather than exporting a second copy of them.

### 8.1 Step 1 — lock and check `instance_projections`

Reuses the exact shape of `fetch_and_lock_instance_projection/3` (`complete_task/3`'s own M2: `SELECT ... FOR UPDATE`, `{:error, :instance_not_found}` if missing, `{:error, {:instance_not_active, status}}` if not `:active`) against `timer.instance_id`. This is the defensive, near-unreachable-by-construction check discussed in §6.2 and §5.2's scope note — given the engine's own completion/cancellation invariants, the only realistic way this ever actually fires is the SCH-03 race window itself (a `cancel_instance/3` transaction that has already committed by the time this step's lock acquisition succeeds).

### 8.2 Step 2 — the narrowest `InstanceState.t()` for this one hop-chain

Mirrors `build_snapshot_and_state/4` (`complete_task/3`'s own M3) exactly, keyed by `timer.token_id` instead of a task: `fetch_graph/2` (via `SnapshotStore.get_by_instance_id/2`, the same immutable definition snapshot every other live-dispatch path already reads), `load_active_tokens/3` + `to_pure_token/1` for the full live token set (needed for `dispatch_end/3`'s "zero live tokens" completion check, same reason `build_snapshot_and_state/4` loads every active token and not just the one it's keyed on), then a direct match — not a `node_id` search — for the `TokenRecord` whose `id` equals `timer.token_id`: the live path has the exact persisted id available (unlike `Reconstruction`'s pure event-log replay, §9, which has no such column to read and must fall back to a `node_id` match). A `timer.token_id` with no matching live token is a defensive `{:error, {:unknown_token_id, timer.token_id}}` — should be unreachable (a `TokenRecord` is never deleted, only status-flipped, and a `"pending"` timer's own token is never removed by any code path that leaves the timer `"pending"`), kept for totality.

### 8.3 Step 3 — dispatch and hop-chain

`Transition.transition(graph, seed_instance_state, {:timer_fired, own_token_id})`, then — exactly like `complete_task/3`'s own tail — `advance_until_stable/4` (the same `@doc false`-exported, cross-module-reused worklist loop `Reconstruction` also drives) over whatever `tokens_needing_dispatch/3` reports newly needs a dispatch, so a `:TIMER` node whose outgoing edge leads straight into an `:EXCLUSIVE_GATEWAY`/`:PARALLEL_GATEWAY`/another `:TIMER` node resolves fully in this one call, matching `create/2`'s and `complete_task/3`'s own "resolve the whole stable hop-chain before persisting" behavior. `{:no_matching_edge, ...}` failures from this hop-chain are surfaced as `{:error, {:transition_failed, reason}}` — there is no `Letflow.Engine.ExecutionError` wiring added for the timer-fire path in this requirement (out of the named SCOPE); a hop-chain error here simply rolls back this whole attempt via the same `{:error, _} -> Repo.rollback/1` route as any other failure, which `attempt_fire/2`'s ordinary (not the new `:instance_not_active`) failure-accounting path then counts toward `fire_error_count`/eventual `dlq_entries` — the same outcome an unhandled `EXECUTION_ERROR`-worthy condition gets everywhere else timers are concerned (REQ-186's own dlq_entries precedent).

### 8.4 Step 4 — persist via a small, nested `Ecto.Multi`

Rather than a bespoke sequence of raw `repo.*` calls duplicating logic `persist/11`/`build_complete_task_tail_multi/6` already have, this step builds and runs its own `Ecto.Multi.new() |> ... |> Repo.transaction()` — which Ecto nests as a `SAVEPOINT` inside `fire_timer/2`'s already-open transaction (a standard, safe Ecto pattern: the outer transaction's eventual commit/rollback still governs everything inside the savepoint). It reuses, unmodified, the SAME building blocks the other two call sites use:

* `do_reconcile_token_records/4` (advances/completes `TokenRecord` rows to match the post-hop-chain token positions) — the exact function `reconcile_token_records/5` already wraps for `complete_task/3`.
* `TaskActivation.append_multi_from_existing_records/6` (materializes a fresh `tasks` row if the hop-chain newly reached a `:HUMAN_TASK` node).
* `prepare_timer_arms/4` + `build_timer_arms_multi/4` (§3) — a `:TIMER` node's outgoing edge can lead directly into another `:TIMER` node; this reuses the identical preparation/`Multi`-building pair `create/2`/`complete_task/3` use, not a third copy.
* `prepare_sub_process_children_for_completion/7`'s own node-lookup/`SubProcess.prepare_child_activation/4` step, and `append_sub_process_children_creation_multi/6`, for a `:TIMER` outgoing edge landing on `:SUB_PROCESS` — `actor_id: EventStore.platform_actor_id()` and `idempotency_key: "timer_fired:#{timer.id}"` (the exact same idempotency key `Scheduler.append_timer_fired_event/4` already minted for the `TIMER_FIRED` event itself — deterministic, retry-safe, traceable back to the one domain event that caused this whole hop-chain) stand in for the `actor_id`/`idempotency_key` those two functions otherwise take from a human caller's `attrs`.
* `reconcile_projection/5` (updates `instance_projections.status`/`current_nodes`/`variables`, and `completed_at` if the hop-chain reached `:completed`).

**No new event is appended here.** `TIMER_FIRED` (already appended by `append_timer_fired_event/4`, unchanged, before this function ever runs) is the one domain event that captures this whole state change — exactly the same division of labor `TASK_COMPLETED` already has: one persisted event, and a set of read-model row updates (`tasks`, `tokens`, `instance_projections`) kept in sync with it, on both the live path and `Reconstruction`'s replay of the same event (§9). Adding a second event type here would duplicate what `TIMER_FIRED`'s own `node_id` field already lets replay reconstruct.

No `cancel_pending_timers/4` call is added to this step, for the same structural reason given in §5.2's scope note: reaching `:completed` via a `:TIMER` node's own outgoing edge requires every other token already gone, so no sibling pending timer can coexist with this completion.

## 9. `Reconstruction` — the new `"TIMER_FIRED"` replay clause

Per the moduledoc's own stated contract ("a later persisted event type needs its own replay clause added to `apply_event/3` ... any unrecognized `event_type` string surfaces as `{:replay_failed, {:unrecognized_event_type, ...}}`, never silently skipped"), `TIMER_FIRED` becomes the sixth known `event_type`. Its persisted payload (`Scheduler.append_timer_fired_event/4`, unchanged) carries `node_id` — no `token_id` — so this clause mirrors `TASK_COMPLETED`'s own precedent exactly rather than `SUB_PROCESS_COMPLETED`'s: read `node_id` from the payload, find the one live token in `state.tokens` currently positioned at that `node_id` (the same `find_task_completion_token/2`-shaped lookup, reused or duplicated under a parallel name — a `:TIMER` node holds at most one token by the same "no structural guarantee, informationally always true today" caveat `TASK_COMPLETED`'s own §9 OQ-3 already documents), then dispatch `{:timer_fired, token.token_id}` through `Transition.transition/3` and fold the result the same way `apply_event/3`'s `"TASK_COMPLETED"` clause does (no variable merge step is needed here — a `TIMER_FIRED` payload carries no `output_variables` to merge, unlike `TASK_COMPLETED`/`SUB_PROCESS_COMPLETED`).

This clause is `Reconstruction`'s own addition, independent of `advance_after_timer_fired/3` — the two never call each other; they are two independent derivations of the same post-`TIMER_FIRED` `InstanceState`, exactly as the live `complete_task/3` path and `Reconstruction`'s `TASK_COMPLETED` clause already are two independent derivations of the same post-`TASK_COMPLETED` state.

## 10. SCH-03 concurrency edge case — summary (AC6)

* **A `"fired"` timer is never changed by a later cancellation:** `cancel_pending_timers/4`'s `update_all` is scoped to `WHERE status = 'pending'` (§5.1); a row already `"fired"` fails that predicate and is left untouched, regardless of transaction interleaving.
* **No `"pending"` timer belonging to a `CANCELLED`/`COMPLETED` instance is ever fired by a later poll:** every path that moves an instance to a terminal status (`finalize_instance_projection/5`'s `:completed` clause, `cancel_instance/3`) cancels every one of that instance's `"pending"` timers inside the SAME transaction as the status flip (§5.2, §6.1) — so by the time either transaction commits, no `"pending"` row for that instance remains for `claim_due_timer_ids/2` to ever select. The one interleaving where a poll's `fetch_and_lock_timer/2` and a terminal-status transaction genuinely race concurrently resolves via ordinary Postgres row-lock contention plus the uniform `timers`-before-`instance_projections` lock order (§6.2) — never a deadlock, never a double-write, and the one transaction that loses the race (whichever reaches its second lock second) rolls back entirely via `advance_after_timer_fired/3`'s own `{:error, {:instance_not_active, _}}` path (§8.1) or `cancel_instance/3`'s own `:eligibility` step, with `attempt_fire/2`'s new clause (§7.2) making sure that specific rollback is never miscounted as a firing failure.

## 11. Files touched

| File | Change |
|---|---|
| `lib/letflow/engine/transition.ex` | New `pending_event()`/`transition_event()`/`transition_error()` variants; new `dispatch_timer_arrival/3`, `dispatch_timer_fired/4`; catch-all comment correction; moduledoc note naming the extended shape. No `Repo`/clock call added. |
| `lib/letflow/definitions/graph.ex` | New public `parse_iso8601_duration/1`. |
| `lib/letflow/engine.ex` | New `prepare_timer_arms/4`, `build_timer_arms_multi/4`, `advance_after_timer_fired/3` (+ its own small helpers per §8); `persist/11` and `build_complete_task_tail_multi/6` each gain one `Multi.merge/2` step; `finalize_instance_projection/5`'s `:completed` clause's existing call updated in place (unmoved); `run_cancel_instance/5` gains `:timer_cancellations` between `:open_tasks` and `:instance_projection`. |
| `lib/letflow/engine/task_activation.ex` | `cancel_pending_timers/2` → `/4` (was `/2`; new `repo`/`cancelled_at`/`cancel_reason` params — a `/5` including `prefix`, arity widened from the current 2 total params to 5), real `update_all` body replacing the no-op. |
| `lib/letflow/scheduler.ex` | `do_fire/2` gains one new `with` clause calling `Letflow.Engine.advance_after_timer_fired/3`; `attempt_fire/2` gains one new case clause for `{:error, {:instance_not_active, _}}`. |
| `lib/letflow/engine/reconstruction.ex` | New `apply_event/3` clause for `"TIMER_FIRED"`. |

No route, controller, migration, or `web/` file is touched by any item above (AC8) — `timers`' own table/columns/indexes are entirely REQ-186's, unchanged here.

## 12. Acceptance-criteria map

| AC (abbreviated) | Where satisfied |
|---|---|
| Token reaching a valid `:TIMER` node arms exactly one `"pending"` row, `fire_at = arrival + parsed duration` | §1.4 (`dispatch_timer_arrival/3`), §2 (`parse_iso8601_duration/1`), §3.1-§3.2 |
| Timer row + state-transition event in one transaction | §3.2 (same `Multi`) |
| Firing advances the token off `:TIMER` along its outgoing edge | §1.4 (`dispatch_timer_fired/4`), §7-§8 |
| Completing an instance cancels its `"pending"` timers via the unmoved `cancel_pending_timers/2` call site | §5 |
| `cancel_instance/3` cancels `"pending"` timers in the same transaction; forced rollback leaves them `"pending"` | §6 |
| A `"fired"` timer is untouched by a later cancellation; no `"pending"` timer of a terminal instance is later fired | §10 |
| `transition.ex` gains no `Repo` call; moduledoc names the extended shape | §1.5 |
| No route/controller added or modified | §11 |
| `mix test`/`mix compile --warnings-as-errors` pass | Verified by ELIXIR-DEV at implementation time; not re-derived here |

## 13. Open questions (not silently resolved)

1. **Duration-to-seconds calendar semantics** (§2) — fixed-length approximation chosen; flagged for REVIEWER sign-off.
2. **`timer_type: "deadline"`** (§3.1) — one of four allowed strings picked by elimination, not stated by any requirement text; flagged for REVIEWER.
3. **`:scheduler_timer` `Multi` step-name collision** (§3.2) — unresolved unless REVIEWER/ELIXIR-DEV confirms a single hop-chain can never arm two `:TIMER` nodes at once, or `Scheduler.create/2`'s `Multi` branch is widened to take a caller-supplied step name.
4. **`reconcile_projection/5` has no timer-cancellation call** (§5.2) — argued structurally unreachable today; flagged as a scope boundary, not fixed here, in case a future requirement changes `:TIMER`'s "blocks completion" invariant.
5. **`:TIMER` node out-degree is structurally unenforced** (§1.4) — CHK-12 validates only the duration attribute; a `:TIMER` node with zero or multiple outgoing edges falls through to `advance_off_completed_node/4`'s existing generic behavior (`{:error, {:no_matching_edge, ...}}` for zero; declared-order/default-last for multiple) rather than a `:TIMER`-specific check. No requirement text read for this design asks for a dedicated CHK-1x here; not added speculatively.
