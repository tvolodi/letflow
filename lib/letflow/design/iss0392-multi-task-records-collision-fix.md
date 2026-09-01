# ISS-0392 fix design — `Ecto.Multi` `:task_records` key collision on synchronous SUB_PROCESS completion

**Status:** design, no implementation code. Written by CODE-DESIGNER from
ISSUE-FIXER's confirmed diagnosis
(`handoffs/WF03-ISS0392-20260901/step-01-issue-fixer.json`, `result.summary`).

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
prevent collision **per ancestor `instance_id`**, not just at one fixed level.

## 2. Fix mechanism

**Core idea: track, inside the `Ecto.Multi` build itself, the set of `instance_id`s a
`:task_records`-family step has already been appended for in this transaction, and make
every call site that wants to append one go through a single gatekeeper function that
appends the step only if that `instance_id` is not already claimed — otherwise it composes
with (does not re-declare) the earlier step.**

This is a **check-before-append**, not a runtime idempotency trick inside the `Multi.run`
callback — `Ecto.Multi.merge_results/3`'s duplicate check happens at the key level before
any callback runs, so the only way to avoid the collision is to never call
`Multi.run/Multi.merge` with a key already present in the accumulating `Multi` for this
transaction.

### 2.1 Why "check-before-append" and not "make the second call idempotent"

The two candidate mechanisms ISSUE-FIXER's diagnosis named are:

- (a) making the second call idempotent/aware of the first's already-applied result, or
- (b) restructuring so only one of the two call sites performs task-activation for a
  given `parent_instance_id` per transaction (check-before-append).

(a) is rejected: `TaskActivation.append_multi_from_existing_records/6`'s own step body
diffs `previous_pending_task_nodes` (a **snapshot value closed over at Multi-build time**,
not read from `changes`) against `new_instance_state.pending_task_nodes`. The two call
sites pass **different** `previous_pending_task_nodes`/`new_instance_state` pairs for the
same `instance_id` — (1) diffs across the *task-completion* transition, (2) diffs across
the *sub-process-completion* transition layered on top of it. Collapsing them into one
`Multi.run` callback would require re-deriving one combined before/after pair, which is a
strictly bigger change than skip-if-present and re-litigates state the two callers already
computed independently and correctly. (b) is the design adopted below: it needs no new
diffing logic, and it matches the shape `append_multi_from_existing_records/6`'s own
moduledoc already documents (namespaced by `instance_id` specifically so multiple distinct
calls can coexist — the fix only has to extend "coexist across distinct instance_ids" to
also cover "coalesce for the same instance_id", not invent a new invariant).

### 2.2 The gatekeeper: a new function, `TaskActivation.append_multi_from_existing_records_once/7`

Replaces both call sites' direct calls to `append_multi_from_existing_records/6` with a
new public function in `Letflow.Engine.TaskActivation` that takes an explicit
already-claimed set and either appends the step or returns the `Multi` unchanged:

```
@spec append_multi_from_existing_records_once(
        multi :: Ecto.Multi.t(),
        claimed_instance_ids :: MapSet.t(Ecto.UUID.t()),
        instance_id :: Ecto.UUID.t(),
        graph :: Graph.t(),
        previous_pending_task_nodes :: [Token.t()],
        new_instance_state :: InstanceState.t(),
        prefix :: String.t()
      ) :: {Ecto.Multi.t(), MapSet.t(Ecto.UUID.t())}
```

Behavior (prose, no body):
- If `instance_id` is **not** a member of `claimed_instance_ids`: call the existing
  `append_multi_from_existing_records/6` unchanged (same key, same diff logic, same
  return shape for the `Multi` step itself) and return `{updated_multi,
  MapSet.put(claimed_instance_ids, instance_id)}`.
- If `instance_id` **is already** a member: return `{multi, claimed_instance_ids}`
  unchanged — no second `Multi.run`/`{:task_records, instance_id}` step is appended.
  **This is the collision-avoidance decision point.** No error, no warning: a second
  call for the same `instance_id` within one transaction is the expected shape on the
  synchronous-completion path (§2.3 states why dropping it is correct, not merely safe).
- `append_multi_from_existing_records/6` itself is **unchanged** — this is a new sibling
  entry point, not a rewrite of the existing one. `Letflow.Engine.create/2`'s own
  `append_multi/6` call site (the freshly-inserted-token path) is untouched; this fix
  only touches the two *existing-records* call sites named in §1.

### 2.3 Why dropping the second call is correct, not merely collision-avoiding

This is the one place this design must justify *silently skipping a step* rather than
merging it, so it is stated explicitly: **the two calls are not doing unrelated work that
both need to land — they are two computations of the same thing, run in the same
transaction, against a strictly earlier and a strictly later snapshot of the same
instance's `pending_task_nodes`.**

`Multi.run/2`'s callback bodies for both calls are lazy (`fn repo, _changes -> ... end`),
evaluated at Multi-**application** time, in the order the steps were composed into the
`Multi`, *not* at Multi-**build** time. So even though call (1)'s step is appended to the
`Multi` before call (2)'s step exists, by the time either callback actually runs, both
have already been resolved to concrete `graph`/`previous_pending_task_nodes`/
`new_instance_state` arguments at Multi-*build* time (closures, not `changes` reads) —
the gatekeeper's job is only to decide, at build time, which one call's already-correct
diff is authoritative for this `instance_id`, not to reconcile two different world-views
at run time.

**Call (1) (`build_task_activation_and_reconciliation_multi/3`) must be the one that
lands, and call (2) must be the one skipped, in every case where both target the same
`instance_id`.** Reasoning: call (1)'s `new_instance_state` is
`final_instance_state` from `build_complete_task_tail_multi/6`'s own `:transition`
match (engine.ex:2399) — the state produced by the *original* completing task's
transition, evaluated **before** `append_sub_process_children_creation_multi/6` (and
therefore before the synchronous-child-completion cascade) ever runs. Call (2)'s
`final_instance_state` is the state produced by `Transition.transition(...,
{:sub_process_completed, ...})` **followed by** `advance_until_stable/4`
(sub_process.ex:846-889) — i.e. it is call (1)'s `new_instance_state` advanced
**further**, through whatever hops the parent takes once its SUB_PROCESS node's
child-wait resolves synchronously. Call (2)'s diff strictly dominates call (1)'s: any
`Token` newly pending after call (1)'s snapshot is still present (unless it was itself
consumed by the further advance) in call (2)'s `previous_pending_task_nodes` argument
(`seed_state.pending_task_nodes`, sub_process.ex:969, which is `state_with_merged`'s
*pre*-`Transition.transition`/`advance_until_stable` snapshot — i.e. it already
**includes** every token call (1) would have newly-pended). So **ordering the
gatekeeper to run call (1) first and skip call (2) on collision would silently drop
`tasks` rows call (1) alone would have inserted** — this is backwards from what must
happen.

**Correction: the design orders this the other way — call (2) is the one that must be
allowed to land, and call (1) must be the one skipped when both target the same
`instance_id`.** Restated precisely: `build_complete_task_tail_multi/6`'s own pipeline
(engine.ex:2414-2467) calls `build_task_activation_and_reconciliation_multi/3` (call 1)
**before** `append_sub_process_children_creation_multi/6` (which is what can trigger call
2) even exists in the pipe chain. Both are built at the same Multi-**build** time, in that
textual order, but call (2)'s `previous_pending_task_nodes` (`seed_state.pending_task_nodes`
at sub_process.ex:969) is a **later** snapshot than call (1)'s
(`seed_state.pending_task_nodes` at engine.ex:2577, i.e. the *original* task-completion's
pre-transition snapshot) — because call (2)'s `seed_state` comes from
`load_parent_context/2` re-reading the parent's *current committed* row state
(sub_process.ex:719, "Performs its own read-only `Letflow.Repo` calls ... before computing
anything"), not from any in-memory value call (1) already had. Call (2)'s diff is
therefore computed against a snapshot that already reflects everything call (1)'s own diff
would have found **plus** whatever advanced further during the synchronous child
completion — so call (2) is the strictly-more-complete one, and **call (1)'s step must be
the one dropped when a collision is detected for the same `instance_id`.**

This has a direct, checkable consequence for the gatekeeper's calling convention (§2.4):
**the claimed-set must be seeded so call (2)'s attempt — which happens later in the
`Multi.merge/2` chain, inside `maybe_chain_synchronous_completion/6` — is the one that
observes the collision and wins**, i.e. the gatekeeper cannot simply be "first writer
wins" if call (1) is textually first; it must specifically let a later call for an
`instance_id` **supersede**, not be suppressed by, an earlier one for the same
`instance_id`, whenever the later one belongs to this same-transaction synchronous
chaining path. See §2.4 for the mechanism that achieves this without inspecting `changes`
(which, per §2.3's opening paragraph, is not available at the point either call is
composed).

### 2.4 Superseding mechanism: build call (1) unconditionally, let call (2) REPLACE it

Given §2.3's ordering requirement, "skip the second attempt" (§2.2's literal behavior) is
the wrong primitive when the first-built call is the one that must yield. The gatekeeper
is therefore specified as **replace-on-repeat, not skip-on-repeat**:

- `append_multi_from_existing_records_once/7`'s membership rule (§2.2) is unchanged in
  shape — build the step, or don't, based on set membership — but what "don't" means is
  refined: when `instance_id` **is** already claimed, the gatekeeper does not silently
  drop the *new* call. It returns a `Multi` in which the **existing**
  `{:task_records, instance_id}` step has been **removed and replaced** with the new
  call's step, via `Ecto.Multi.delete/2`-then-append semantics stated abstractly (the
  concrete Ecto API call is an implementation detail ELIXIR-DEV resolves; the *contract*
  this design fixes is: after the gatekeeper returns, the `Multi` carries exactly one
  `{:task_records, instance_id}` step, and it is the **most recently attempted** one, not
  the first).
- Because call (2) is always attempted strictly after call (1) in the same
  `Multi.merge/2` chain (§2.3), "most recently attempted wins" and "call (2) supersedes
  call (1) when both target the same `instance_id`" are the same rule — no ordering flag
  or priority argument is needed on the gatekeeper itself. This also correctly generalizes
  to the cascade case (§3): at each ancestor level, that level's own
  `build_completion_write_steps/12` call is, by construction, always the most-recently
  attempted call for that level's `instance_id`, so "most recent wins" is exactly "the
  most-advanced snapshot wins" at every level, matching §2.3's dominance argument at
  every level, not just the first.
- Return shape is unchanged from §2.2: `{Ecto.Multi.t(), MapSet.t(Ecto.UUID.t())}`. The
  `MapSet` returned after a replace still contains `instance_id` (no change to
  membership, only to which step's `Multi.run` callback is registered under that key).

### 2.5 Threading `claimed_instance_ids` through the two call sites

The `MapSet.t()` accumulator cannot be a module attribute or process-dictionary global —
this codebase's own conventions (`TaskActivation`'s moduledoc, "Zero `Repo` calls of its
own") and `docs/anti-patterns.md`'s emphasis on explicit, checkable state rule that out —
so it must be threaded explicitly as a value through the same call chain that already
threads the `Multi` itself:

- **`Letflow.Engine.build_complete_task_tail_multi/6`** (engine.ex:2396-2476, signature
  **unchanged** — it is a private function called with a fixed arity from one place, no
  external caller depends on its shape) initializes `claimed_instance_ids = MapSet.new()`
  immediately before its own call to `build_task_activation_and_reconciliation_multi/3`
  (replacing that call's use of `append_multi_from_existing_records/6` internally — see
  next bullet), and threads the **updated** set (not the `Multi` alone) through every
  subsequent step in its pipeline that can itself append a `:task_records`-family step:
  `append_sub_process_children_creation_multi/6` and
  `append_sub_process_completion_cascade_multi/6`.

- **`Letflow.Engine.build_task_activation_and_reconciliation_multi/3` changes signature**
  to accept and return the accumulator:

  ```
  @spec build_task_activation_and_reconciliation_multi(
          changes :: map(),
          completed_at :: DateTime.t(),
          prefix :: String.t(),
          claimed_instance_ids :: MapSet.t(Ecto.UUID.t())
        ) :: {Ecto.Multi.t(), MapSet.t(Ecto.UUID.t())}
  ```

  (previously `(changes, completed_at, prefix) :: Multi.t()`, called as the head of a
  `|>` pipe starting from `normalized_changes` — engine.ex:2414). Internally calls
  `TaskActivation.append_multi_from_existing_records_once/7` in place of
  `append_multi_from_existing_records/6` and returns the resulting `{Multi.t(),
  MapSet.t()}` pair instead of a bare `Multi.t()`. Because this function no longer
  returns a bare `Multi.t()`, `build_complete_task_tail_multi/6`'s own pipe
  (engine.ex:2414-2429, `normalized_changes |> build_task_activation_and_reconciliation_multi(...) |> Multi.merge(...)`)
  can no longer pipe the result directly into `Multi.merge/2` — it must destructure the
  `{multi, claimed_instance_ids}` pair first. This is a **mechanical restructuring of
  `build_complete_task_tail_multi/6`'s body**, not a change to what it computes; its own
  public-facing behavior (the `complete_task/3` result) is unchanged.

- **`Letflow.Engine.append_sub_process_children_creation_multi/6` changes signature** to
  thread the accumulator through the `Enum.reduce/3` that already iterates
  `prepared_children` (engine.ex:2483-2502):

  ```
  @spec append_sub_process_children_creation_multi(
          multi :: Ecto.Multi.t(),
          claimed_instance_ids :: MapSet.t(Ecto.UUID.t()),
          prepared_children :: [{Ecto.UUID.t(), map()}],
          parent_instance_id :: Ecto.UUID.t(),
          actor_id :: Ecto.UUID.t() | nil,
          idempotency_key :: String.t(),
          prefix :: String.t()
        ) :: {Ecto.Multi.t(), MapSet.t(Ecto.UUID.t())}
  ```

  (previously `(multi, prepared_children, parent_instance_id, actor_id, idempotency_key,
  prefix) :: Multi.t()`). The `Enum.reduce/3` accumulator becomes `{acc_multi,
  acc_claimed}` instead of bare `acc_multi`, and each iteration calls
  `SubProcess.append_start_multi/8` (see next bullet) instead of `/7`.

- **`Letflow.Engine.SubProcess.append_start_multi/7` changes signature** to accept and
  return the accumulator, becoming `/8`:

  ```
  @spec append_start_multi(
          Multi.t(),
          claimed_instance_ids :: MapSet.t(Ecto.UUID.t()),
          parent_instance_id :: Ecto.UUID.t(),
          parent_token_record_id :: Ecto.UUID.t(),
          parent_node_id :: String.t(),
          prepared :: map(),
          attrs :: %{actor_id: Ecto.UUID.t() | nil, idempotency_key: String.t()},
          opts :: [prefix: String.t()]
        ) :: {Ecto.Multi.t(), MapSet.t(Ecto.UUID.t())}
  ```

  (previously returned bare `Multi.t()`). `append_start_multi/8`'s own body is otherwise
  unchanged (still builds `projection_key`/`tokens_key`/`tasks_key`/`event_key`/
  `parent_token_key` steps exactly as today) except its tail call to
  `maybe_chain_synchronous_completion/6` becomes `maybe_chain_synchronous_completion/7`,
  threading the accumulator in and returning the pair out.

- **`maybe_chain_synchronous_completion/6` changes to `/7`** (both clauses,
  sub_process.ex:481-518): the `:completed`-matching clause now takes
  `claimed_instance_ids` as an added parameter, threads it into
  `append_completion_multi/5`'s replacement (`/6`, next bullet) inside its
  `Multi.merge/2` callback, and returns `{Multi.t(), MapSet.t()}`. **A closure
  subtlety this design flags explicitly:** `Multi.merge/2`'s callback signature is fixed
  by Ecto (`fn changes -> Multi.t() end` — it returns a bare `Multi.t()`, not a tuple).
  Since `append_completion_multi/6`'s new return shape is a pair (next bullet), the
  `Multi.merge/2` callback body must extract the `Multi.t()` half for the value the
  callback returns to Ecto, while the `MapSet.t()` half is captured via the closure's
  **outer** scope, not returned through `Multi.merge/2` itself — `Multi.merge/2` cannot
  carry a second return channel out of its own callback. Concretely:
  `maybe_chain_synchronous_completion/7` must call `append_completion_multi/6` and
  extract its `Multi.t()` **before** entering `Multi.merge/2`'s callback wherever
  possible, or — because `append_completion_multi/6`'s own inputs
  (`parent_token`) are only resolved from `changes` inside that callback today
  (sub_process.ex:490, `Map.fetch!(changes, parent_token_key)`) — the updated
  `claimed_instance_ids` must be surfaced through a **second, explicit `Multi.run/3`
  step** appended immediately after the `Multi.merge/2` call, whose only job is to record
  (via a fixed, well-known key, e.g. `{:sub_process_claimed_instance_ids, child_instance_id}`)
  what the merge callback computed — mirroring the existing
  `{:sub_process_parent_token, child_instance_id}` step's own role
  (sub_process.ex:463-471) as a `changes`-readable relay. **This is flagged as an open
  question in §5 (OQ-1)** rather than silently resolved, because both options are
  legitimate and the choice affects `append_start_multi/8`'s exact return-value plumbing.

- **`append_completion_multi/5` changes signature to `/6`**
  (sub_process.ex:724-808), adding `claimed_instance_ids` and changing its success return
  from `{:ok, Multi.t()}` to `{:ok, {Multi.t(), MapSet.t(Ecto.UUID.t())}}` (its error
  return, `{:error, ExecutionError.error_args()}`, is unchanged):

  ```
  @spec append_completion_multi(
          Multi.t(),
          claimed_instance_ids :: MapSet.t(Ecto.UUID.t()),
          child_instance_id :: Ecto.UUID.t(),
          child_final_variables :: map(),
          parent_token :: TokenRecord.t(),
          opts :: [prefix: String.t(), actor_id: Ecto.UUID.t() | nil, idempotency_key: String.t()]
        ) :: {:ok, {Ecto.Multi.t(), MapSet.t(Ecto.UUID.t())}} | {:error, ExecutionError.error_args()}
  ```

  Threads the accumulator unchanged through `build_completion_multi_from_merge/12`
  (→ `/13`) into `build_completion_write_steps/12` (→ `/13`, next bullet). Every call
  site of the current `/5` (the two named in §1 — `maybe_chain_synchronous_completion/6`'s
  `:completed` clause and `Engine.append_sub_process_completion_cascade_multi/6`'s
  `Multi.merge/2` callback at engine.ex:2535-2549 — plus `maybe_cascade_to_grandparent/6`'s
  own recursive call, §3) is updated for the new arity and return shape.

- **`build_completion_write_steps/12` changes signature to `/13`**
  (sub_process.ex:944-1011), adding `claimed_instance_ids` as a parameter and returning
  `{Ecto.Multi.t(), MapSet.t(Ecto.UUID.t())}` instead of a bare `Multi.t()`. Its own body
  replaces the direct `TaskActivation.append_multi_from_existing_records/6` call
  (sub_process.ex:966-972) with `TaskActivation.append_multi_from_existing_records_once/7`
  (§2.2/§2.4) — **this replaced call site is the fix's actual collision-prevention
  point**; every other signature change in this section exists only to get
  `claimed_instance_ids` to this call site and back out again. Threads the (possibly
  updated) accumulator into its own tail call to `maybe_cascade_to_grandparent/6`
  (→ `/7`, §3).

**Net shape of the change:** every function on the path from
`build_complete_task_tail_multi/6` down to
`TaskActivation.append_multi_from_existing_records_once/7` gains one added parameter
(`claimed_instance_ids`, a `MapSet.t(Ecto.UUID.t())`) and changes its return type from a
bare `Multi.t()` (or `{:ok, Multi.t()} | {:error, ...}`) to a pair carrying the updated
accumulator alongside the `Multi.t()` (preserving the `{:ok, _} | {:error, _}` wrapping
where it already existed). No function's **error** return shape changes. No function
gains a new failure mode.

## 3. Multi-level cascade — `maybe_cascade_to_grandparent/6`

`maybe_cascade_to_grandparent/6` (sub_process.ex:1013-1063) already recurses by calling
`append_completion_multi/5` again (§1) for the **grandparent's own** `instance_id` when
`final_instance_state.status == :completed` at the parent level too. Under this design:

- **Signature changes to `/7`**, adding `claimed_instance_ids` and returning
  `{Ecto.Multi.t(), MapSet.t(Ecto.UUID.t())}` in place of a bare `Multi.t()` — same shape
  as every other function in the chain (§2.5). Its `:completed`-matching clause threads
  the accumulator into its own `Multi.merge/2` callback's call to
  `append_completion_multi/6` (the new arity), exactly mirroring
  `maybe_chain_synchronous_completion/7`'s own shape (§2.5's closure-surfacing note
  applies identically here — same open question, OQ-1).
- **Why each ancestor's own collision is prevented without suppressing a distinct
  ancestor's legitimate step:** the `claimed_instance_ids` set is keyed by
  `instance_id`, and every ancestor in a nesting chain has a **distinct** `instance_id`
  by construction (`find_waiting_parent_token/3`'s own query, sub_process.ex:695-705,
  resolves one specific waiting token row per child instance; a grandparent cannot be its
  own parent). So `MapSet.member?(claimed_instance_ids, grandparent_instance_id)` is
  `false` on every cascade's first arrival at that level **unless** that same
  `grandparent_instance_id` was independently claimed earlier in the **same**
  transaction by call (1) (`build_task_activation_and_reconciliation_multi/4`) — which
  can only happen if the grandparent instance is *also* the top-level hop chain's own
  `parent_instance_id`, i.e. the completing task's own instance is simultaneously an
  ancestor several SUB_PROCESS levels up from itself. **This is possible in principle**
  (nothing in the graph model forbids a definition from being used as its own descendant
  through separate SUB_PROCESS node instantiations — REQ-062's design doc does not
  exclude it), and is exactly the case §2.4's "most recent call wins, replacing the
  earlier one" rule is built to cover generically: whichever level's `Multi.merge/2`
  attempt reaches that shared `instance_id` **last** in build order provides the
  authoritative (most-advanced-snapshot) step, per §2.3's dominance argument, which
  holds at every level for the same reason it holds at the first: each successive
  cascade level's `seed_state` is `load_parent_context/2`'s **freshly re-read** snapshot
  (sub_process.ex:719), never a value carried over from an earlier level's in-memory
  state, so a later-attempted level always has an equal-or-later view of that instance's
  `pending_task_nodes` than an earlier-attempted level touching the same `instance_id`.
- **A distinct ancestor's legitimate step is never suppressed** because the gatekeeper's
  replace behavior is scoped to the **exact** `instance_id` key — two different
  ancestors (`{:task_records, parent_id}` vs. `{:task_records, grandparent_id}`) are two
  different `MapSet` members and two different `Multi` keys; nothing about handling one
  touches the other's step.
- No new recursion-depth bound is introduced beyond what `maybe_cascade_to_grandparent/6`
  already has today (none — it recurses exactly as many times as
  `find_waiting_parent_token/3` finds a further waiting ancestor, unchanged by this fix).

## 4. Async/queued path — unchanged behavior (ISS-0392 AC3)

The async/queued SUB_PROCESS completion path — a child left `:active` with a pending
`HUMAN_TASK`, per ISSUE-FIXER's diagnosis — never reaches
`maybe_chain_synchronous_completion/7`'s `:completed`-matching clause at all;
`append_start_multi/8`'s call into it hits the **second, no-op clause**
(sub_process.ex:510-518, unchanged by this design except its arity: `/6` → `/7`, still
returning `{multi, claimed_instance_ids}` **unchanged**, mirroring today's `do: multi`).
Concretely:

- `append_completion_multi/6`, `build_completion_write_steps/13`, and
  `TaskActivation.append_multi_from_existing_records_once/7` are **never invoked** on
  this path within the originating transaction — exactly as today, where
  `append_completion_multi/5` is never invoked on this path either. The async
  completion happens later, when that child's own task is independently completed via
  its **own**, separate top-level `complete_task/3` call and therefore its own, separate
  `Ecto.Multi` — which starts its own fresh `claimed_instance_ids = MapSet.new()`
  accumulator at `build_complete_task_tail_multi/6`'s own entry point (§2.5), identical
  in shape to how it starts today with an implicit empty collision history (no
  `:task_records` steps yet appended to that fresh `Multi`).
- Because the no-op clause returns `{multi, claimed_instance_ids}` unchanged, no
  `:task_records` step is added, removed, or replaced for **any** `instance_id` on this
  path relative to today's behavior — `append_start_multi/8`'s five unconditional steps
  (`projection_key`/`tokens_key`/`tasks_key`/`event_key`/`parent_token_key`) are
  untouched by this whole design; only the synchronous-completion tail
  (`maybe_chain_synchronous_completion`) and its downstream calls change shape.
- **This is the concrete design element satisfying AC3** ("async/queued path behavior
  unchanged"): the fix's only behavior-affecting code path is the one gated by
  `child_initial_state.status == :completed`; the no-op sibling clause's contract
  (arity aside) is provably identical before and after.

## 5. The regression test scenario (for TEST-DESIGNER)

**Exact scenario to reproduce, matching ISSUE-FIXER's own repro
(`scratch/iss0392_repro_test.exs`, not committed) so TEST-DESIGNER can build the
permanent version directly from it:**

1. A parent process definition: `START -> HUMAN_TASK("gate") -> SUB_PROCESS("sp") -> END`.
2. A child process definition referenced by the `SUB_PROCESS("sp")` node that is itself
   `START -> END` — **no intervening task**, so `prepare_child_activation/4` drives it to
   `InstanceState.status == :completed` synchronously, before any Multi step exists for
   it (this is what makes `maybe_chain_synchronous_completion/7`'s `:completed` clause
   fire rather than its no-op sibling).
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
   (task-completion) snapshot's**, per §2.3/§2.4's "call (2) supersedes call (1)" rule:
   concretely, assert that no `tasks` row is created for a `pending_task_nodes` entry
   that existed only in call (1)'s snapshot and was itself consumed by the parent's own
   further advance past `SUB_PROCESS("sp")` to `END` (i.e. the test's own fixture should
   be constructed so `END` is a *terminal* node with no `HUMAN_TASK` immediately after
   `SUB_PROCESS`, precisely so this dominance behavior is observable as "no orphan task
   row" rather than needing a positive-content assertion this design would otherwise have
   to specify from scratch).
7. **Cascade coverage (multi-level):** a second test variant nests one level deeper — the
   parent process's own `SUB_PROCESS("sp")` is itself invoked from a grandparent process
   (i.e. reuse the fixture from step 1-2 as the "child" of a further outer
   `START -> HUMAN_TASK("outer_gate") -> SUB_PROCESS("outer_sp") -> END` definition,
   with `"outer_sp"` pointing at the step-1 definition as its own child). Completing
   `"outer_gate"`'s task must synchronously cascade through **two** SUB_PROCESS
   completion levels in one transaction, exercising `maybe_cascade_to_grandparent/7`'s
   `:completed` clause once. Same pre-fix-fails / post-fix-passes structure as steps 5-6,
   asserting the collision does not recur at the second level either.

## 6. Open questions (explicit — not resolved by guessing)

**OQ-1 — how `claimed_instance_ids` crosses a `Multi.merge/2` callback boundary.**
§2.5 flags this inline: `Multi.merge/2`'s callback is constrained by Ecto's own API to
return a bare `Multi.t()`, but this design's threaded accumulator needs to come back out
of `maybe_chain_synchronous_completion/7` and `maybe_cascade_to_grandparent/7` as part of
a pair. Two options are legitimate and this design does not pick one:
  - (a) resolve `append_completion_multi/6`'s tuple result **before** entering
    `Multi.merge/2`'s callback wherever the inputs (`parent_token`) allow it, restructuring
    the surrounding function so the callback closes over an already-known `Multi.t()`
    rather than computing it inline; or
  - (b) keep the `Multi.merge/2` callback shape as-is and surface the updated accumulator
    via a sibling, well-known-keyed `Multi.run/3` step appended immediately after (a
    `changes`-readable relay, mirroring `parent_token_key`'s own existing role).

  ELIXIR-DEV should pick whichever is more idiomatic Ecto once actually writing the
  code; REVIEWER should confirm the choice doesn't reintroduce a step that reads
  `changes` for a value that was actually available at build time (this design's own
  §2.3 opening paragraph explains why that distinction matters here).

**OQ-2 — whether `MapSet.t()` or a plain `[Ecto.UUID.t()]` list is the right
accumulator shape.** This design specifies `MapSet.t(Ecto.UUID.t())` for O(1) membership
checks, but the expected cardinality per transaction (one entry per distinct ancestor
instance touched, typically 1-3) is small enough that a list with `Enum.member?/2` would
be behaviorally identical and marginally simpler to read in `IO.inspect`-style debugging.
Left to ELIXIR-DEV's judgment; either satisfies every acceptance criterion this design
states, since none of them depend on the accumulator's concrete representation.

**OQ-3 — whether `append_multi_from_existing_records_once/7`'s "replace" behavior
(§2.4) needs its own unit-level test independent of the integration scenario in §5.**
This design's regression scenario (§5) exercises the replace path only indirectly (via
its "no orphan task row" assertion). TEST-DESIGNER/TEST-DESIGN-VALIDATOR should decide
whether a smaller, direct unit test against
`TaskActivation.append_multi_from_existing_records_once/7` (feeding it two different
`previous_pending_task_nodes`/`new_instance_state` pairs for the same `instance_id` and
asserting the second's diff is what actually lands) is also required for adequate
coverage, or whether §5's integration-level test is judged sufficient. Not resolved here
because it is a test-design coverage judgment, not a fix-mechanism question.

**OQ-4 — whether `instance_id` reuse as its own ancestor (§3's "possible in principle"
case) is a scenario worth its own dedicated test, or is out of scope for this fix.**
§3 argues the design's replace-by-recency rule handles it correctly if it occurs, but
ISSUE-FIXER's diagnosis and ISS-0392's own filed scope do not mention this case, and
constructing a definition where an instance is its own multi-level SUB_PROCESS ancestor
may not be reachable through any currently-enforced graph-validation rule (REQ-062's own
design doc is not re-read in full here to confirm either way). Flagged rather than
assumed either in-scope or out-of-scope; ORCH/TEST-DESIGNER should decide whether §5's
two scenarios are sufficient or whether a third, self-referential-ancestor scenario must
be added.
