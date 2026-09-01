# ISS-0392 fix design — `Ecto.Multi` `:task_records` key collision on synchronous SUB_PROCESS completion

**Status:** design, no implementation code. Written by CODE-DESIGNER from
ISSUE-FIXER's confirmed diagnosis
(`handoffs/WF03-ISS0392-20260901/step-01-issue-fixer.json`, `result.summary`).

**Revision 2 (2026-09-01, rework iteration 1).** ELIXIR-DEV
(`handoffs/WF03-ISS0392-20260901/step-03-elixir-dev.json`, `result.issues[0]`) found
Revision 1's §2.4 "replace-on-repeat" mechanism mechanically infeasible against real
`Ecto.Multi` semantics: confirmed by reading `deps/ecto/lib/ecto/multi.ex` in full
(`__apply__/4` at :851-858, `apply_operations/5` at :875-881, `apply_operation/5`'s
`:merge` clause at :883-892, `merge_results/3` at :944-955) as part of this revision,
independently of ELIXIR-DEV's own citation, before writing anything below. §2 and §3 are
revised in place to a **build-time skip/defer** mechanism, replacing the previous
runtime-replace mechanism entirely. §1 (root cause), §4 (async path), and §5 (regression
scenario) are carried forward essentially unchanged — this revision does not touch what
collides or why, only how the fix avoids it. §6 (open questions) is re-reviewed: OQ-1
(the `Multi.merge/2` closure-boundary question) and OQ-2 (accumulator representation) are
**dropped** — the new mechanism does not thread a stateful accumulator through
`Multi.merge/2` callbacks at all, so both questions no longer apply. OQ-3 and OQ-4 are
carried forward, renumbered.

## 1. Root cause recap (not re-diagnosed, restated only as the design's starting point)

Two call sites can append `TaskActivation.append_multi_from_existing_records/6` onto the
**same** `Ecto.Multi`, keyed `{:task_records, X}`, for the **same** `X`:

1. `Letflow.Engine.build_task_activation_and_reconciliation_multi/3`
   (`lib/letflow/engine.ex:2572-2592`) — unconditional, once per `complete_task/3` hop
   chain, keyed on `X = task.instance_id` (== `parent_instance_id` at engine.ex:2412).
2. `Letflow.Engine.SubProcess.build_completion_write_steps/12`
   (`lib/letflow/engine/sub_process.ex:944-1011`) — appended only when
   `maybe_chain_synchronous_completion/6`'s `:completed` clause
   (`sub_process.ex:481-508`) fires, i.e. only when a SUB_PROCESS child spawned by (1)'s
   own hop chain reaches `:completed` synchronously inside `prepare_child_activation/4`
   before any Multi step exists for it. Keyed on `X = parent_token.instance_id`, which is
   the **same** parent instance as (1) whenever the completing child's parent token
   belongs to the instance whose task just completed.

`Ecto.Multi.merge_results/3` rejects the duplicate key at apply time
(`RuntimeError: cannot merge Multi; ... [task_records: "<parent_instance_id>"]`).

The multi-level cascade (`maybe_cascade_to_grandparent/6`, `sub_process.ex:1013-1063`)
recurses the exact same shape one instance further: it calls `append_completion_multi/5`
again for the **grandparent's own** `instance_id`, which flows into a **second** call to
`build_completion_write_steps/12` keyed `{:task_records, grandparent_instance_id}`. That
second call's key never collides with (1)'s or (2)'s keys (different `X`), but it **can**
collide with a **third**, independent call for that same grandparent if the grandparent's
own instance is *also* the top-level hop chain's `parent_instance_id` — i.e. the fix must
prevent collision **per ancestor `instance_id`**, not just at one fixed level. See §3 for
how this revision handles that case (unchanged conclusion from Revision 1: it stays an
explicitly-flagged open question, not silently assumed unreachable).

## 2. Fix mechanism (Revision 2 — build-time skip/defer)

### 2.1 Why the previous mechanism (Revision 1) is infeasible — restated as the negative constraint this revision must satisfy

`Ecto.Multi` is a two-phase data structure: **build phase** (`Multi.new/0`,
`Multi.run/3`, `Multi.merge/2`, and every `|>`-chained append onto it) does nothing but
grow the `%Multi{operations: [...]}` list — no callback runs, no database write happens,
until the *entire* Multi has been assembled. **Execution phase**
(`Ecto.Multi.__apply__/4`, invoked once by `Repo.transaction/2`) then walks
`Enum.reverse(multi.operations)` in a single `Enum.reduce/3`
(`apply_operations/5`, `multi.ex:875-881`) and, for each operation in that fixed order,
either runs its callback immediately (a `:run` operation) or — for a `:merge` operation —
recursively applies a **freshly-built, nested** Multi that the merge callback constructs
*at that point in the reduce*, then folds its results back into the accumulator via
`merge_results/3` (`multi.ex:883-892, 944-955`), which raises the instant it finds a key
already present in `names` (the running set of every key resolved so far in this
execution).

Two consequences that make "build call (1) unconditionally, let call (2) replace it"
impossible:

- **There is no operation that removes or replaces an already-composed step.** Every
  `Ecto.Multi` public function (`run/3`, `merge/2`, `insert/3,4`, `update/3,4`,
  `delete/3,4`, `put/3`, `error/2`, `insert_all/4`, `update_all/4`, `delete_all/3`,
  `inspect/2`) **prepends** to `operations` (`Map.update!(multi, :operations, &[... | &1])`
  throughout `multi.ex`) — none pops, filters, or replaces an entry already in the list.
  `Ecto.Multi.delete/2` (an API Revision 1 left unresolved as "an implementation detail")
  does not exist as a step-removal function at all; the only `delete` arities are
  `delete/3,4`, which *append* a struct/changeset-delete write operation, not remove a
  prior step.
- **By the time call (2)'s `Multi.merge/2` callback would run and could detect "this
  `instance_id` is already claimed," call (1)'s `:run` step for that same key has
  already executed** (it is strictly earlier in `operations`' composed order, and
  `apply_operations/5` runs operations in that order without lookahead) — so even if a
  removal primitive existed, call (1)'s `INSERT`s are already committed inside the
  (still-open) transaction by the time call (2) could act on them. "Replace" would have
  to mean "undo call (1)'s writes and redo them differently," which is not what any
  `Multi` primitive does.

**The only mechanically available lever is deciding, before call (1)'s step is ever
composed into the `Multi`, whether to compose it at all.** This is a build-time
predicate over data that must already be known in plain Elixir before
`build_task_activation_and_reconciliation_multi/3` is invoked — not a runtime check
inside any `Multi.run`/`Multi.merge` callback body, and not a check against `changes`
(which does not yet exist at build time either).

### 2.2 The build-time predicate: `prepared_children` already answers the question before call (1) is built

`Letflow.Engine.build_complete_task_tail_multi/6`'s second clause
(`engine.ex:2396-2476`) receives `prepared_children` as part of its own function-head
destructuring of `transition: {:advanced, final_instance_state, prepared_children,
prepared_timers}` (`engine.ex:2399`) — **before** its body calls
`build_task_activation_and_reconciliation_multi/3` at `engine.ex:2415` (call (1)). Each
entry of `prepared_children` is `{parent_token_record_id, prepared}`, where `prepared` is
`SubProcess.prepare_child_activation/4`'s own return shape
(`sub_process.ex:277-295`) — specifically `prepared.child_initial_state :: InstanceState.t()`,
whose `.status` field is either `:active` (the child is left waiting — the async/queued
path, §4) or `:completed` (the child's own graph, e.g. a plain `START -> END` with no
intervening task, ran to completion synchronously inside
`advance_until_stable/4`, `sub_process.ex:330`, before any `Multi` step for that child
exists). This status is computed entirely in plain Elixir, with zero database
interaction (`prepare_child_activation/4`'s own moduledoc: "Runs entirely before any
Multi step for this child is appended"), so it is available, concretely, at the exact
point `build_complete_task_tail_multi/6` is about to build call (1).

**Every `prepared_children` entry that will synchronously complete targets the same
`instance_id` as call (1).** `parent_token_record_id` in each entry is resolved by
`resolve_parent_token_record_id/2` (`engine.ex:2345-2357`) from `original_active_tokens`
— the live token set of the **instance whose task is completing in this hop chain**, i.e.
`parent_instance_id` (`engine.ex:2412`, `= normalized_changes.task.instance_id`). When
`append_start_multi/7` later calls `maybe_chain_synchronous_completion/6→7`'s
`:completed` clause for such a child, that clause resolves `parent_token` from
`changes` at the `parent_token_key` step (`sub_process.ex:490`) — a `TokenRecord` row
belonging to `parent_token_record_id`, whose `instance_id` is, by construction,
`parent_instance_id`. So `append_completion_multi/5`'s downstream
`build_completion_write_steps/12` call at `sub_process.ex:966-972` is always keyed
`{:task_records, parent_instance_id}` — **the identical key call (1) would use** —
whenever any `prepared_children` entry has `child_initial_state.status == :completed`.
This is exactly, and only, the condition under which the collision in §1 can occur at
the first level.

**The predicate, stated precisely (build-time, before call (1) exists), in prose (not
code — the concrete traversal/matching construct is ELIXIR-DEV's to choose):** a boolean,
`defer_first_level_task_activation?`, that is `true` if and only if at least one entry of
`prepared_children` has a `prepared.child_initial_state.status` of `:completed`, and
`false` otherwise (including when `prepared_children` is empty — a hop chain with no
SUB_PROCESS children at all).

### 2.3 Why deferring call (1) (not call (2)) is correct, not merely collision-avoiding

Restated from Revision 1's dominance argument (§2.3 there), unchanged by this revision
because it was never the part ELIXIR-DEV found infeasible — only the *mechanism* for
acting on it changed:

Call (1)'s `new_instance_state` is `final_instance_state` — the state produced by the
*original* completing task's own transition, evaluated **before**
`append_sub_process_children_creation_multi/6` (and therefore before any
synchronous-child-completion cascade) ever runs. Call (2)'s `final_instance_state` (via
`build_completion_multi_from_merge/12`, `sub_process.ex:819-908`) is that same state
advanced **further** — `Transition.transition(..., {:sub_process_completed, ...})`
followed by `advance_until_stable/4` — through whatever hops the parent takes once its
SUB_PROCESS node's child-wait resolves synchronously. Call (2)'s diff (against
`seed_state.pending_task_nodes`, `sub_process.ex:969`, itself a **freshly re-read**
snapshot via `load_parent_context/2`, `sub_process.ex:719`) strictly dominates call (1)'s
diff: every `Token` call (1) would have newly-pended is still present in call (2)'s
*pre*-transition snapshot (unless already consumed by the further advance). So call (2)
is the strictly-more-complete computation, and it is the one that must land whenever
both target the same `instance_id`.

**Under the build-time mechanism, this dominance argument becomes the direct
justification for *never building* call (1)'s step in this case, rather than building
and then replacing it.** There is no ordering subtlety to reason about (Revision 1's
§2.3 needed one, precisely because "which call is textually first" mattered for a
replace-based mechanism) — the predicate in §2.2 is evaluated once, before either call
is composed, and it directly decides which one gets composed at all. Call (2) is always
the one that actually lands when the predicate is true, because call (1) is simply never
appended; there is nothing for call (2) to supersede.

### 2.4 The gatekeeper, revised: a conditional at the call-(1) call site, no new function needed

Revision 1 introduced a new function,
`TaskActivation.append_multi_from_existing_records_once/7`, threading a `MapSet`
accumulator through the entire call chain from `build_complete_task_tail_multi/6` down
to `TaskActivation`. That threading existed to let a **later** call site (call (2), which
could be arbitrarily deep in the pipe by the time it runs) inform an **earlier**-built
step whether to replace itself — a problem that only exists because Revision 1's
mechanism needed cross-call-site runtime coordination. The build-time mechanism needs no
such coordination for the first-level case: the predicate in §2.2 is evaluated with data
already in hand at the single point call (1) would be built, so the decision is entirely
local to `build_complete_task_tail_multi/6`'s own body. **No new function, no new
parameter threaded through `append_sub_process_children_creation_multi/6`,
`SubProcess.append_start_multi/7`, or `maybe_chain_synchronous_completion/6` is needed
for the first-level case** — this is a strictly smaller, more local change than Revision
1's, not merely a different one.

Revised shape of `build_complete_task_tail_multi/6`'s pipe (`engine.ex:2414-2467`,
prose, no implementation code):

- Compute `defer_first_level_task_activation?` (§2.2's predicate) from
  `prepared_children`, immediately after `parent_instance_id` is bound
  (`engine.ex:2412`) and before the pipe that currently starts with
  `normalized_changes |> build_task_activation_and_reconciliation_multi(...)`
  (`engine.ex:2414-2415`).
- If `false` (no synchronously-completing child targets this instance): the pipe is
  **unchanged** from today — `build_task_activation_and_reconciliation_multi/3` runs
  exactly as it does now, unconditionally appending its `{:task_records,
  parent_instance_id}` step. This is the common case (most SUB_PROCESS children are
  either absent or left `:active` pending a task) and this design introduces zero
  behavioral change to it.
- If `true`: `build_task_activation_and_reconciliation_multi/3` must **not** append its
  `{:task_records, parent_instance_id}`-keyed step for this hop chain — call (2) (via
  `maybe_chain_synchronous_completion` → `append_completion_multi` →
  `build_completion_write_steps`, appended later in the same pipe at
  `append_sub_process_children_creation_multi/6`, `engine.ex:2461-2467`) is left as the
  sole appender of that key. Everything else
  `build_task_activation_and_reconciliation_multi/3` does — `reconcile_token_records/5`
  (its own separate `:token_reconciliation` step, a **different** Multi key, unaffected
  by this predicate) — is **unchanged**; only the `{:task_records, parent_instance_id}`
  sub-step within it is conditionally omitted.

### 2.5 Signature changes

Only one function's signature changes for the first-level case (a strictly smaller
surface than Revision 1's five-function chain):

`Letflow.Engine.build_task_activation_and_reconciliation_multi/3` gains one parameter:

```
@spec build_task_activation_and_reconciliation_multi(
        changes :: map(),
        completed_at :: DateTime.t(),
        prefix :: String.t(),
        skip_task_activation? :: boolean()
      ) :: Ecto.Multi.t()
```

(previously `(changes, completed_at, prefix) :: Multi.t()` — return type is **unchanged**,
still a bare `Multi.t()`, since this function no longer needs to communicate anything
back to its caller beyond the `Multi` itself; there is no accumulator to thread out).
Internally: when `skip_task_activation?` is `true`, the pipe omits its call to
`TaskActivation.append_multi_from_existing_records/6` entirely (composes straight from
`Multi.new()` into `reconcile_token_records/5`, i.e. the `:token_reconciliation` step
only); when `false`, behavior is byte-for-byte what the function does today. This
preserves `TaskActivation.append_multi_from_existing_records/6` itself completely
unmodified — Revision 1's §2.2 observation that `Letflow.Engine.create/2`'s own
`append_multi/6` call site is untouched still holds, more directly now: this revision
does not add a sibling entry point to `TaskActivation` at all.

`build_complete_task_tail_multi/6`'s own signature is **unchanged** (still private,
fixed arity, one caller) — the new predicate is computed and consumed entirely inside
its own body, threaded only into its one call to
`build_task_activation_and_reconciliation_multi/3` (now `/4`). No other function in the
chain — `append_sub_process_children_creation_multi/6`, `SubProcess.append_start_multi/7`,
`maybe_chain_synchronous_completion/6`, `append_completion_multi/5`,
`build_completion_write_steps/12` — changes signature for the first-level case. Their
Revision-1-specified `/7`, `/8`, `/7`, `/6`, `/13` arities and `{Multi.t(), MapSet.t()}`
return-pair changes are **withdrawn** in this revision; all five keep their current,
already-implemented signatures (`/7` `/12` etc. as they exist in source today), and
`TaskActivation.append_multi_from_existing_records/6` is called from
`build_completion_write_steps/12` exactly as it is today, with no `_once` variant.

## 3. Multi-level cascade — `maybe_cascade_to_grandparent/6`

`maybe_cascade_to_grandparent/6` (`sub_process.ex:1013-1063`) already recurses by
calling `append_completion_multi/5` again for the **grandparent's own** `instance_id`
when `final_instance_state.status == :completed` at the parent level too.

### 3.1 Why §2's build-time predicate does not, and cannot, extend to the cascade case directly

§2.2's predicate works because `prepared_children` — the data it inspects — is fully
resolved in plain Elixir *before* `build_complete_task_tail_multi/6`'s pipe begins, for
every child this hop chain will spawn. The cascade case is structurally different:
`maybe_cascade_to_grandparent/6` discovers whether a further ancestor exists by calling
`find_waiting_parent_token/3` (`sub_process.ex:697-705`) — a **real, locking database
read** (`lock("FOR UPDATE")`) issued from *inside* a `Multi.run/3` step
(`cascade_lookup_key`, `sub_process.ex:1023-1025`), i.e. at Multi-**execution** time, not
build time. There is no plain-Elixir data available before the outer Multi is built that
tells the pipeline whether a third-level ancestor exists, let alone whether that
ancestor's `instance_id` happens to coincide with `parent_instance_id` (the
self-ancestor edge case, carried forward from Revision 1 as OQ-4 below) — that
coincidence can only be known once `find_waiting_parent_token/3` actually runs.

**This does not reintroduce Revision 1's infeasibility, because the cascade's normal
case needs no gatekeeper at all.** §1's own closing paragraph already establishes that
each ancestor level's own call targets a **distinct** `instance_id`
(`find_waiting_parent_token/3`'s query resolves one specific waiting-token row per child
instance; a grandparent cannot generally be its own parent) — distinct keys never
collide in `Ecto.Multi.merge_results/3` regardless of build order, so no build-time or
run-time decision is needed for the common multi-level case. The only case requiring any
handling is the edge case where a deeper ancestor's `instance_id` coincides with an
`instance_id` already claimed earlier in the same transaction — and per §3.1's own
argument, that coincidence is discoverable only at the point
`find_waiting_parent_token/3` runs for that level, strictly after call (1) (if it was
built at all) already executed for that same `instance_id`. **The same
un-replaceable-step limitation from §2.1 applies here without qualification**: if
`instance_id` reuse as a self-ancestor is a real, reachable case, no build-time skip can
prevent that specific collision, because the colliding earlier step's build-time
predicate (§2.2) only inspects `prepared_children`, not the yet-undiscovered ancestor
chain several `Multi.merge/2` levels deeper.

### 3.2 What this revision concludes for the cascade case

Unchanged from Revision 1's own conclusion, restated precisely under the corrected
mechanism vocabulary: **the always-reachable core bug (ISS-0392's own filed repro) is
the first-level case §2 fixes.** The deeper, self-ancestor-reuse collision is:

- Not eliminated by this design (neither Revision 1's infeasible replace, nor this
  revision's build-time skip, can prevent it — §3.1 shows why no build-time mechanism
  reaches it, and §2.1 shows why no run-time replace mechanism exists in `Ecto.Multi` at
  all, regardless of which case is being solved).
- Not newly introduced by this revision — it existed identically under Revision 1's
  (infeasible) design and exists identically with **zero fix applied** for the cascade
  layer specifically, since §2's change is scoped to the first-level `instance_id`
  (`parent_instance_id`) only and touches nothing in `maybe_cascade_to_grandparent/6`,
  `append_completion_multi/5`, or `build_completion_write_steps/12`.
- Not confirmed reachable through any currently-enforced graph-validation rule (same
  caveat as Revision 1's OQ-4 — REQ-062's design doc is not re-read in full here to
  settle this either way).

Carried forward as OQ-2 below (renumbered from Revision 1's OQ-4), not silently resolved
in either direction.

**No change to `maybe_cascade_to_grandparent/6`'s signature, `append_completion_multi/5`'s
signature, or `build_completion_write_steps/12`'s signature.** All three keep their
current, already-implemented shapes — Revision 1's `/7`, `/6`, `/13` changes for these
three are withdrawn along with the rest of the accumulator-threading mechanism (§2.5).

## 4. Async/queued path — unchanged behavior (ISS-0392 AC3)

The async/queued SUB_PROCESS completion path — a child left `:active` with a pending
`HUMAN_TASK`, per ISSUE-FIXER's diagnosis — never reaches
`maybe_chain_synchronous_completion/6`'s `:completed`-matching clause at all;
`append_start_multi/7`'s call into it hits the second, no-op clause
(`sub_process.ex:510-518`, **entirely unchanged by this revision** — no arity change,
no behavior change, `do: multi` exactly as today). Concretely, under Revision 2:

- Every `prepared_children` entry for a child left `:active` has
  `child_initial_state.status == :active`, so §2.2's predicate
  (`Enum.any?(..., status == :completed)`) is unaffected by that entry's presence — the
  predicate only becomes `true` when at least one entry is `:completed`. A hop chain
  with only async/queued children never sets `skip_task_activation?`, so
  `build_task_activation_and_reconciliation_multi/4` behaves exactly as
  `build_task_activation_and_reconciliation_multi/3` does today for that hop chain.
  `append_completion_multi/5`, `build_completion_write_steps/12`, and
  `TaskActivation.append_multi_from_existing_records/6`'s "second call" shape are never
  invoked on this path within the originating transaction — exactly as today. The async
  completion happens later, when that child's own task is independently completed via
  its own, separate top-level `complete_task/3` call and therefore its own, separate
  `Ecto.Multi`, whose own `prepared_children` (likely empty, or containing only that
  transaction's own newly-prepared children) starts its own fresh predicate evaluation.
- **This is the concrete design element satisfying AC3** ("async/queued path behavior
  unchanged"): the fix's only behavior-affecting code path is the one gated by
  `child_initial_state.status == :completed` appearing anywhere in `prepared_children`;
  every other shape — including a hop chain with zero SUB_PROCESS children at all, where
  `prepared_children == []` and `Enum.any?([], ...)` is trivially `false` — reduces to
  today's unconditional behavior.

## 5. The regression test scenario (for TEST-DESIGNER)

**Unchanged from Revision 1** (the scenario tests observable behavior — the collision no
longer occurring, and which snapshot's diff lands — not the internal mechanism that
prevents it, so nothing about the mechanism revision changes what TEST-DESIGNER needs to
exercise):

**Exact scenario to reproduce, matching ISSUE-FIXER's own repro
(`scratch/iss0392_repro_test.exs`, not committed) so TEST-DESIGNER can build the
permanent version directly from it:**

1. A parent process definition: `START -> HUMAN_TASK("gate") -> SUB_PROCESS("sp") -> END`.
2. A child process definition referenced by the `SUB_PROCESS("sp")` node that is itself
   `START -> END` — **no intervening task**, so `prepare_child_activation/4` drives it to
   `InstanceState.status == :completed` synchronously, before any Multi step exists for
   it (this is what makes `maybe_chain_synchronous_completion/6`'s `:completed` clause
   fire rather than its no-op sibling, and what makes §2.2's predicate evaluate `true`).
3. Start the parent instance (reaches the `HUMAN_TASK("gate")` node, pending).
4. Call `Engine.complete_task/3` on the `"gate"` task. This is the single hop chain that:
   - reaches `SUB_PROCESS("sp")`,
   - spawns the child per step 2, which completes synchronously inside the same
     transaction,
   - chains the child's own completion back into the parent (`sub_process_completed`),
     which — per this design's own dominance argument (§2.3) — itself advances the
     parent to `END`, i.e. `:completed`.
5. **Pre-fix assertion (must FAIL on pre-fix code):** this call raises
   `RuntimeError` with message containing `"cannot merge Multi"` and
   `"task_records: "` — the exact collision named in §1. TEST-DESIGNER states this
   fail-first result explicitly per `WF-03_issue_resolving.md`'s Steps 2-4 procedure.
6. **Post-fix assertion (must PASS on post-fix code):** `Engine.complete_task/3` returns
   `{:ok, _}` (or whatever `complete_task/3`'s own success shape is — CODE-DESIGNER does
   not restate `complete_task/3`'s full contract here, it is unchanged by this fix), the
   parent instance's projection reaches `:completed`, and — this is the collision-fix
   -specific assertion, not just "it didn't crash" — **exactly one `tasks` row history is
   consistent with the *later* (sub-process-completion) snapshot's diff, not the earlier
   (task-completion) snapshot's**, per §2.3's dominance argument: concretely, assert that
   no `tasks` row is created for a `pending_task_nodes` entry that existed only in call
   (1)'s snapshot and was itself consumed by the parent's own further advance past
   `SUB_PROCESS("sp")` to `END` (i.e. the test's own fixture should be constructed so
   `END` is a *terminal* node with no `HUMAN_TASK` immediately after `SUB_PROCESS`,
   precisely so this dominance behavior is observable as "no orphan task row" rather than
   needing a positive-content assertion this design would otherwise have to specify from
   scratch). Under Revision 2's mechanism this is structurally guaranteed rather than
   merely arranged: call (1)'s step for `parent_instance_id` is never built at all when
   this scenario's predicate is `true`, so there is no earlier-snapshot row for it to
   have inserted in the first place — "no orphan row" is not a race outcome to verify,
   it follows directly from the step never existing.
7. **Cascade coverage (multi-level):** a second test variant nests one level deeper — the
   parent process's own `SUB_PROCESS("sp")` is itself invoked from a grandparent process
   (i.e. reuse the fixture from step 1-2 as the "child" of a further outer
   `START -> HUMAN_TASK("outer_gate") -> SUB_PROCESS("outer_sp") -> END` definition,
   with `"outer_sp"` pointing at the step-1 definition as its own child). Completing
   `"outer_gate"`'s task must synchronously cascade through **two** SUB_PROCESS
   completion levels in one transaction, exercising `maybe_cascade_to_grandparent/6`'s
   `:completed` clause once. Same pre-fix-fails / post-fix-passes structure as steps 5-6.
   Per §3.2, this variant's two ancestor `instance_id`s are **distinct** by construction
   (no self-ancestor reuse), so this scenario is expected to pass post-fix purely because
   distinct keys never collide — it is not exercising §2's predicate a second time (only
   the first, outermost `parent_instance_id` step ever needs deferring; the grandparent
   level's own `{:task_records, grandparent_instance_id}` key was never in contention).

## 6. Open questions (explicit — not resolved by guessing)

**Revision 1's OQ-1 (Multi.merge/2 closure-boundary threading) and OQ-2 (MapSet vs. list
accumulator) are dropped in this revision** — both were questions about how to thread a
stateful accumulator through `Multi.merge/2` callback boundaries, and Revision 2's
mechanism (§2.4-§2.5) does not thread any accumulator through any `Multi.merge/2`
callback at all; the predicate is computed once, in plain Elixir, before any Multi step
exists. Neither question has a referent under this revision.

**OQ-1 (renumbered from Revision 1's OQ-3) — whether the build-time predicate (§2.2)
needs its own unit-level test independent of the integration scenario in §5.** §5's
scenario exercises the predicate only indirectly (via its "no orphan task row"
assertion, now structurally guaranteed per §5 point 6's closing note). TEST-DESIGNER/
TEST-DESIGN-VALIDATOR should decide whether a smaller, direct test asserting
`build_task_activation_and_reconciliation_multi/4`'s `Multi.t()` output contains no
`{:task_records, X}` step when called with `skip_task_activation?: true` (vs. contains
exactly one when `false`) is also required for adequate coverage, independent of running
a full `complete_task/3` hop chain, or whether §5's integration-level test is judged
sufficient. Not resolved here because it is a test-design coverage judgment, not a
fix-mechanism question.

**OQ-2 (renumbered from Revision 1's OQ-4) — whether `instance_id` reuse as its own
multi-level SUB_PROCESS ancestor (§3's self-ancestor edge case) is a scenario worth its
own dedicated test, or is out of scope for this fix.** §3.1-§3.2 establish that this
revision's build-time mechanism, like Revision 1's (infeasible) runtime-replace
mechanism before it, does **not** prevent a collision at a deeper cascade level whose
`instance_id` happens to coincide with an `instance_id` already claimed earlier in the
same transaction — this is a genuine, unresolved gap in both revisions' scope, not a
regression this revision introduces. ISSUE-FIXER's diagnosis and ISS-0392's own filed
scope do not mention this case, and constructing a definition where an instance is its
own multi-level SUB_PROCESS ancestor may not be reachable through any
currently-enforced graph-validation rule (REQ-062's own design doc is not re-read in
full here to confirm either way). Flagged rather than assumed either in-scope or
out-of-scope; ORCH/TEST-DESIGNER should decide whether §5's two scenarios are sufficient
for this fix's closure, or whether this gap should be filed as its own follow-up issue
(distinct from ISS-0392, which — per §3.2 — this fix closes for the case ISS-0392's own
repro actually exercises) via `docs/agents/protocols/ISSUE_QUEUE.md`.
