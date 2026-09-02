# ISS-0408 fix design — persist a real `TokenRecord` for a hop-chain-local join token before task-activation/reconciliation see it

**Status:** design, no implementation code. Written by CODE-DESIGNER from ISSUE-FIXER's
confirmed diagnosis (this run's own handoff, `WF03-ISS0408-20260902`). Source issue:
`docs/issues/ISS-0408.yaml`.

## 1. Root cause recap (not re-diagnosed, restated only as this design's starting point)

`Letflow.Engine.Transition.fire_join/5` (`lib/letflow/engine/transition.ex:1196-1236`)
mints a synthetic, non-UUID `token_id` for the token produced when a `PARALLEL_GATEWAY`
join fires:

```
new_token_id = counter.origin_token_id <> "/" <> node.id <> "/joined"
```

(`transition.ex:1211`). `Letflow.Engine.Transition` is deliberately pure/persistence-agnostic
(no `Ecto`/`Letflow.Repo` dependency — same purity contract `Letflow.Engine.Token`'s own
moduledoc states) — it has no way to consult the database for a real `TokenRecord.id` at
this point, and today it never tries to; it always derives a string id in-process.

This join-produced token is correct and load-bearing as a **pure** `Letflow.Engine.Token.t()`
value — join→`:END` works today (`test/letflow/engine_test.exs`'s
`graph_start_parallel_split_join_end` case) because a token consumed directly by `:END`'s
own dispatch is simply dropped; nothing ever needs to look up a `TokenRecord` row for it.

The gap is downstream, in `lib/letflow/engine.ex`, specifically in the **existing-records**
persistence path used by `complete_task/3` (`build_complete_task_tail_multi/6`,
`engine.ex:2404-2517`) and by `timer_fired` (`persist_timer_fired_advance/6`,
`engine.ex:1975-2048`). Both call sites assume every `token_id` reaching
`TaskActivation.append_multi_from_existing_records/6` and
`do_reconcile_token_records/5` already names a **pre-existing** `TokenRecord` row:

- `TaskActivation.insert_newly_pending_from_existing_records/5`
  (`lib/letflow/engine/task_activation.ex:278-298`) calls `cast_token_record_id/1`
  (`task_activation.ex:304-309`), which does `Ecto.UUID.cast/1` and returns
  `{:error, {:invalid_token_record_id, token_id}}` for anything that isn't UUID-shaped.
  This is documented there as "Defense-in-depth check on top of the caller's own
  token_id-is-a-real-TokenRecord-id reconstruction invariant" — **correct, not the fix
  site**.
- `do_reconcile_token_records/5` (`engine.ex:2706-2728`) independently requires every
  entry of `final_tokens` to already be a member of `original_ids` — the `MapSet` of
  `original_active_tokens`' own (real, DB-loaded) `TokenRecord.id`s
  (`engine.ex:2707`, `MapSet.new(original_tokens, &to_string(&1.id))`) — and returns
  `{:error, {:new_token_during_resume_not_supported, token_id}}` the instant it finds one
  that isn't. This function only ever `UPDATE`s existing rows
  (`reconcile_one_token_record/5`, `engine.ex:2730-...`); it has no insert branch. **Also
  correct, also not the fix site.**

So relaxing either guard alone does not fix anything — it only moves the failure from one
guard to the next (`TaskActivation`'s guard today, `do_reconcile_token_records/5`'s guard
immediately after, since both run in the same `Multi` and both key off the identical
`token_id`). This is exactly what ISSUE-FIXER's diagnosis states and what engine.ex's own
pre-existing comment at `engine.ex:2306-2313` already documents as a **named, known
limitation** for the sibling SUB_PROCESS-after-split/join case (`resolve_parent_token_record_id/2`,
`engine.ex:2368-2380`, `{:error, {:sub_process_after_split_join_not_supported, token_id}}`) —
same underlying gap, different downstream consumer.

**Contrast — why `create/2` doesn't have this problem.** `Letflow.Engine.persist/12`
(`engine.ex:939-1019`) always builds a `:token_record` Multi step
(`Multi.run(:token_record, fn repo, _changes -> insert_token_records(repo, instance_id,
new_instance_state.tokens, prefix) end)`, `engine.ex:977-979`) that INSERTs one
`TokenRecord` row per entry of `new_instance_state.tokens` — **every** token, split-derived
or join-derived or plain, regardless of what string its pure `token_id` currently holds —
before `TaskActivation.append_multi/6` (the *other* public entry point, distinct from
`append_multi_from_existing_records/6`) ever runs. `append_multi/6` then resolves each
`Task.token_id` FK via `token_id_to_record_id/2` (`task_activation.ex:56-69`), a **positional
zip** of `new_instance_state.tokens` against the just-inserted `TokenRecord.t()` list — it
never inspects the pure token's own `token_id` string at all. This is why `create/2`'s own
join→`:END` test (and, structurally, a join→`HUMAN_TASK` scenario, were one to be added to
`create/2`) already works: the insert-then-resolve shape has no built-in assumption that
`token_id` is already a real id.

**The gap, stated precisely:** nothing in the `complete_task/3` or `timer_fired` hop-chain
tail ever inserts a `TokenRecord` for a token that is genuinely new **within that hop
chain** (i.e., present in `final_instance_state.tokens` but absent from
`original_active_tokens`) before task-activation and reconciliation run against it. The
existing-records path was built assuming a `complete_task`/`timer_fired` hop chain never
mints a new token — true for every other transition kernel dispatch (`:advance_token`,
`:HUMAN_TASK` completion, gateway pass-through, split's own branches immediately pending)
except the join-fire case, which is the one dispatch that synthesizes a **merged** token
representing tokens that previously existed as separate rows.

## 2. Decision: `Transition.fire_join/5` keeps minting a derived string id — `engine.ex` gets the fix

**Decision:** `Letflow.Engine.Transition.fire_join/5`'s signature, its pure computation,
and its derived-string `new_token_id` convention (`counter.origin_token_id <> "/" <>
node.id <> "/joined"`) are **unchanged**. The fix is entirely in `lib/letflow/engine.ex`
(the persistence layer), not in `lib/letflow/engine/transition.ex`.

**Why, stated explicitly (this is the open-question ISSUE-FIXER flagged for this design to
settle):**

1. **Purity is load-bearing, not incidental.** `Letflow.Engine.Transition`'s own moduledoc
   and every existing design doc that touches it (REQ-044 "transition kernel") state its
   zero-`Ecto`/zero-`Repo` contract as an explicit property, tested by `create/2`'s own
   flow (`Transition.transition/3` is called and fully resolves an entire hop chain, in
   memory, **before** any `Ecto.Multi` is built — `dispatch_task_completion_hop_chain/7`,
   `persist_timer_fired_advance/6`, and `persist/12` all share this shape). Making
   `fire_join/5` assign a real `TokenRecord.id` would require it to either (a) perform a
   database insert itself (violates purity, and is structurally impossible anyway — `fire_join/5`
   runs inside `advance_until_stable/4`'s pure worklist loop, called from both `create/2`
   pre-Multi and `complete_task/3`/`timer_fired` pre-Multi, with no open transaction or
   `repo` argument threaded to it at all), or (b) generate a random UUID client-side
   (`Ecto.UUID.generate/0`) purely as a **candidate** id, deferring the actual `INSERT`
   to the persistence layer regardless. Option (b) is a real alternative (see the
   rejected-alternative note below) but is not chosen, because it would silently make
   `Transition`'s pure output depend on an `Ecto.UUID`-specific format assumption the
   module has no other reason to know about, for zero benefit over the chosen design
   (§3 achieves the same "real UUID before persistence-sensitive code sees it" outcome
   entirely in `engine.ex`, without threading anything new through `Transition`).
2. **The existing derived-id convention is already exactly how split works, and split
   is not being changed either.** `dispatch_parallel_split/4`
   (`transition.ex:748-...`) mints `derived_id = token.token_id <> "/" <> Integer.to_string(index)`
   for each split branch, same shape, same purity reasoning, and split branches that
   land on a `:HUMAN_TASK` **inside `create/2`** already work today precisely because
   `create/2`'s insert-then-resolve `:token_record` step (§1 above) never depended on
   `token_id`'s string shape. Changing `fire_join/5` alone, while leaving
   `dispatch_parallel_split/4` unchanged, would fix join but leave an equivalent gap for
   a hypothetical `complete_task/3` hop chain that both splits **and** immediately routes
   a branch to a fresh `:HUMAN_TASK` in the same hop chain (not observed today, not part
   of ISS-0408's filed repro, but the same class of gap) — asymmetric and incomplete.
   Fixing this at the `engine.ex` persistence layer instead handles **any** hop-chain-local
   derived token, from either dispatch, uniformly, with no dependency on which pure
   dispatch minted it.
3. **`do_reconcile_token_records/5`'s own docstring context already treats "new token
   during resume" as a `engine.ex`-level concept** (`{:new_token_during_resume_not_supported,
   token_id}`, INV-EE48-8 per its own comment) — the fix that makes a hop-chain-local new
   token *supported* is naturally the same layer that currently forbids it, not the pure
   kernel two layers below.

**Rejected alternative, named for the audit trail:** having `Transition.fire_join/5`
generate a random UUID via `Ecto.UUID.generate/0` as `new_token_id` instead of the derived
string, so every `token_id` a hop chain ever needs to persist already "looks like" a real
id (removing the need for `cast_token_record_id/1` to distinguish real from synthetic —
though it would still need a corresponding **row** to exist, so §3's insert step would
still be required regardless). Rejected because (a) it doesn't remove the actual
persistence gap this design must fix — a real UUID *string* with no backing row still
fails `do_reconcile_token_records/5`'s `original_ids` membership check exactly the same
way, so §3's insert-before-guards mechanism is needed either way; (b) it changes
`Transition`'s pure behavior and its own test suite's fixture assumptions (multiple
existing tests may assert the derived-string shape directly, e.g. via the `.../joined`
suffix) for no corresponding simplification in `engine.ex`; (c) it introduces a
same-transaction id-collision risk of its own (a client-generated random UUID colliding
with a concurrently-inserted row is astronomically unlikely but is a new failure mode this
design doesn't need to introduce when the derived string already uniquely encodes lineage
and is trivially replaced by a real DB-assigned id at insert time, same as `create/2` does
for every token today). **`Transition` module: zero changes.**

## 3. The fix: an INSERT step for hop-chain-local new tokens, before task-activation/reconciliation

### 3.1 Precisely which tokens are "new within this hop chain"

Both call sites already have, in scope, everything needed to compute this set in plain
Elixir, no new database read required:

- `original_active_tokens` — the `[TokenRecord.t()]` list loaded at hop-chain-seed time
  (`build_snapshot_and_state/4`, `engine.ex:1748`, and `persist_timer_fired_advance/6`'s
  own `snapshot_and_state.original_active_tokens`, threaded in from the same shape). This
  is the **same** value `do_reconcile_token_records/5` already uses to build `original_ids`.
- `final_instance_state.tokens` — the `[Token.t()]` (pure struct) list produced by
  `advance_until_stable/4` at the end of the hop chain. This is the **same** value already
  passed to `reconcile_token_records/5`/`do_reconcile_token_records/5` today.

**Definition:** a token is *hop-chain-local-new* iff its `token_id` (a `String.t()`) is
**not** a member of `MapSet.new(original_active_tokens, &to_string(&1.id))` — i.e., the
exact predicate `do_reconcile_token_records/5` already evaluates per-token today
(`engine.ex:2709`), just computed **before** that function runs instead of inside it, and
producing a **set of tokens to insert** rather than an error.

This set can, in principle, contain more than one token per hop chain (e.g. two joins
firing in the same `advance_until_stable/4` worklist run) and is typically empty (the
overwhelmingly common case: no join fired in this hop chain, every token in
`final_instance_state.tokens` is either unchanged or an existing token that merely moved
`node_id`).

### 3.2 New function: `Letflow.Engine.insert_hop_chain_new_token_records/5`

A new **private** function in `lib/letflow/engine.ex`, alongside `insert_token_records/4`
(`engine.ex:1215-1228`, `create/2`'s own insert helper) and `reconcile_token_records/5`.
Not exported — both call sites (`build_task_activation_and_reconciliation_multi/4` and
`persist_timer_fired_advance/6`) live in the same module, so no cross-module boundary is
crossed and no new public surface is needed (unlike the ISS-0392 precedent, whose fix
lived at a `TaskActivation`/`engine.ex` boundary — this one doesn't cross that boundary at
all). Arity is **5**, matching its 5 named parameters below — named
`insert_hop_chain_new_token_records/5` throughout this design; if you find `/4` anywhere
else in this document it is this same function and the arity is 5, not 4.

```
@spec insert_hop_chain_new_token_records(
        repo :: Ecto.Repo.t(),
        instance_id :: Ecto.UUID.t(),
        original_active_tokens :: [TokenRecord.t()],
        final_tokens :: [Token.t()],
        prefix :: String.t()
      ) :: {:ok, %{optional(String.t()) => Ecto.UUID.t()}} | {:error, term()}
```

**Behavior (prose, no implementation code):**

1. Compute `original_ids = MapSet.new(original_active_tokens, &to_string(&1.id))` — same
   computation `do_reconcile_token_records/5` already performs; this design does not
   decide here whether the two call sites literally share one private helper for this
   `MapSet` construction or each compute it inline (ELIXIR-DEV's implementation-level
   choice — both are one line and produce an identical value from the same input, so
   sharing is a style preference, not a correctness question).
2. Filter `final_tokens` to those whose `token_id` is **not** in `original_ids` — this is
   the hop-chain-local-new set from §3.1.
3. If empty: return `{:ok, %{}}` immediately, no `Repo` call. This keeps every hop chain
   that never fires a join (the overwhelming majority) at **zero added queries** — matching
   this project's own precedent of `TaskActivation.append_multi/6`'s `newly_pending ==
   []` fast path (`task_activation.ex:180-182`) and `insert_token_records/4`'s own
   `[]`-clause fast path (`engine.ex:1215`).
4. Otherwise: for each such token, insert one `TokenRecord` row via
   `TokenRecord.insert_changeset/2` (the **same** changeset `insert_token_record/4`
   (`engine.ex:1230-1245`) already uses for `create/2`), with attrs:
   - `instance_id`: the hop chain's own `instance_id` (the function parameter — both call
     sites already have this bound: `parent_instance_id`/`task.instance_id` in
     `build_complete_task_tail_multi/6`, `timer.instance_id` in
     `persist_timer_fired_advance/6`).
   - `node_id`: the token's own `node_id` (its **current**, post-hop-chain position —
     for a join-fired token this is `join_outgoing_edge.target`, i.e. wherever the token
     already sits by the time `final_instance_state` was produced; no special-casing of
     "this came from a join" is needed here, the token's own final `node_id` is already
     correct).
   - `branch_id`: the token's own `branch_id` (per `fire_join/5`, `nil` for a join-merged
     token — `transition.ex:1216`; a split-derived token would carry its own derived
     `branch_id` per `dispatch_parallel_split/4`, unaffected by this design since split
     branches are not what ISS-0408 reports, but the field is copied through uniformly
     either way, matching `insert_token_record/4`'s own existing `branch_id: token.branch_id`
     mapping).
   - `status`: `:active` — schema default, same as `insert_token_record/4`
     (`engine.ex:1235`); a token present in `final_instance_state.tokens` is, by
     construction, still live.
   No `waiting_child_instance_id`, `parent_token_id`, or `gateway_id` is set — none of
   these fields apply to a join-merged token (a join token has no single "parent" token
   in the `TokenRecord` schema's own `parent_token_id` sense — it is a many-to-one merge,
   not a one-to-one lineage edge — and `insert_token_record/4` itself never sets those
   three fields either, for the identical reason on `create/2`'s own split-derived
   tokens). This design does not introduce new schema usage beyond what `create/2`
   already exercises.
5. On success, return `{:ok, id_map}` where `id_map` maps each inserted token's **pure**
   `token_id` string (the synthetic derived id, e.g. `"<origin>/<join_node>/joined"`) to
   its newly-assigned real `TokenRecord.id` (`Ecto.UUID.t()`, stringified or not — see
   §3.4 for the exact string form consumers need). This is the same shape
   `token_id_to_record_id/2` (`task_activation.ex:61-69`) already produces for `create/2`,
   reused conceptually though not by direct call (that function zips two **positional**
   lists; this one has no second list to zip against — the `id_map` here is built directly
   from each `{synthetic_token_id, %TokenRecord{id: new_id}}` pair as each insert
   succeeds).
6. On any single insert's failure (an `Ecto.Changeset` error — structurally not expected,
   since `insert_attrs` here mirrors `insert_token_record/4`'s own always-valid shape, but
   the function still returns a typed error rather than raising): halt and return
   `{:error, {:hop_chain_token_record_insert_failed, changeset}}`, aborting the enclosing
   `Multi` (a `Multi.run/3` step returning `{:error, _}` rolls back the whole transaction —
   standard `Ecto.Multi` behavior already relied on throughout this module).

### 3.3 Where this step is inserted in the `Multi` — key naming, collision-safety, ordering

**Multi step key:** `{:hop_chain_token_records, instance_id}` — namespaced by
`instance_id`, matching `TaskActivation.append_multi_from_existing_records/6`'s own
established `{:task_records, instance_id}` convention (`task_activation.ex:258`,
documented at `task_activation.ex:233-240` as existing specifically because "this
function can be called more than once on the *same* outer `Multi` within one transaction
… and a fixed atom key would collide … via `Ecto.Multi.merge/2`'s own static duplicate-key
check"). The identical collision risk applies here: `persist_timer_fired_advance/6` and
`build_complete_task_tail_multi/6` both call this new step, and — per the ISS-0392
precedent already resolved in this codebase — a SUB_PROCESS completion cascade can append
**further** Multi content for a **different** `instance_id` (a parent/grandparent) inside
the same transaction. A fixed atom key (e.g. plain `:hop_chain_token_records`) would be
safe today (this design's own call sites each add at most one such step per `Multi`,
unlike `TaskActivation`'s two-call-sites-same-key hazard that motivated the tuple key
there) — but namespacing by `instance_id` from the start costs nothing, matches the
established local convention exactly, and forecloses a latent collision if a future
change ever calls this new function twice for different instances in one transaction
(e.g. a hop chain where a join fires in the parent **and** a synchronously-completing
SUB_PROCESS cascade also produces its own hop-chain-local-new token for the child/grandparent
instance — not confirmed reachable today, but the tuple key is free insurance consistent
with this codebase's own stated collision-avoidance rationale, so this design specifies it
outright rather than leaving it as an open question).

**Ordering — inserted immediately before task-activation, which is immediately before
token-reconciliation, both already in that order.** Concretely, inside
`build_task_activation_and_reconciliation_multi/4` (`engine.ex:2619-2645`), the new step
is prepended to the existing pipe:

```
Multi.new()
|> maybe_insert_hop_chain_new_token_records(...)   # NEW — must run first
|> maybe_append_task_activation_multi(...)         # existing (ISS-0392's own conditional)
|> reconcile_token_records(...)                    # existing
```

**Why first, not merged in some other position:** both downstream steps need the mapping
this step produces —

- `maybe_append_task_activation_multi/7` → `TaskActivation.append_multi_from_existing_records/6`
  → `insert_newly_pending_from_existing_records/5` → `cast_token_record_id/1` needs each
  pending token's `token_id` to already resolve to a real UUID **before** it runs
  `Ecto.UUID.cast/1` on it (§3.4 covers exactly how this resolution happens without
  changing `cast_token_record_id/1` itself).
- `reconcile_token_records/5` → `do_reconcile_token_records/5` needs
  `final_instance_state.tokens` to already have real UUIDs for its `original_ids`
  membership check to pass (§3.4, same mechanism).

Both existing functions' own bodies are **unchanged** (§4 confirms this explicitly) — the
new step's job is to make the *data flowing into them* already satisfy what they've always
assumed, not to teach either of them a new case.

**`persist_timer_fired_advance/6`'s own `Multi` pipe** (`engine.ex:2007-2029`) gets the
identical treatment — the new step prepended immediately before its own
`TaskActivation.append_multi_from_existing_records/6` call:

```
Multi.new()
|> maybe_insert_hop_chain_new_token_records(...)                      # NEW — must run first
|> TaskActivation.append_multi_from_existing_records(...)              # existing
|> reconcile_token_records(...)                                        # existing
|> Multi.merge(fn _changes -> build_timer_arms_multi(...) end)          # existing
|> append_sub_process_children_creation_multi(...)                     # existing
|> Multi.run(:projection, ...)                                         # existing
```

### 3.4 How task-activation and reconciliation actually see the resolved ids — `final_instance_state` rewrite, not a `changes`-map lookup

**Decision:** rather than teaching `TaskActivation.append_multi_from_existing_records/6`
or `do_reconcile_token_records/5` to consult a `Multi.run`-produced `changes` map (which
would mean editing both functions — exactly what §0/ISSUE-FIXER's diagnosis says NOT to
do), this design has the **new Multi step itself resolve `final_instance_state` before
either downstream function is ever called**, so both continue to receive a
`final_instance_state` (respectively, `new_instance_state`) whose `.tokens` list already
contains only real-UUID `token_id`s — indistinguishable, from their point of view, from
the case where no join ever fired.

Concretely, `maybe_insert_hop_chain_new_token_records/4` (the conditional wrapper,
mirroring `maybe_append_task_activation_multi/7`'s own existing `true`/`false`-clause
pattern) is not a bare `Multi.run` — it is a `Multi.merge/2` callback (same idiom already
used throughout this module for "a later step's shape depends on an earlier step's
result" — e.g. `engine.ex:980`, `engine.ex:995`, `engine.ex:2458`, `engine.ex:2568`) whose
callback:

1. Runs the `Multi.run({:hop_chain_token_records, instance_id}, ...)` insert step from
   §3.2 as its own nested first step of a fresh `Multi.new()`.
2. Appends a **second**, small `Multi.run` step (still inside the same `Multi.merge/2`
   result) that reads back `changes[{:hop_chain_token_records, instance_id}]` (the `id_map`
   §3.2 produced) and **rewrites** `final_instance_state`/`new_instance_state`'s own
   `.tokens` list, replacing each synthetic `token_id` with its real, just-inserted
   `TokenRecord.id` (stringified, matching `to_pure_token/1`'s own `to_string(record.id)`
   convention, `engine.ex:1783`) — producing an updated `InstanceState.t()` value.

This means `build_task_activation_and_reconciliation_multi/4`'s body needs the rewritten
`final_instance_state` to flow into its own subsequent
`maybe_append_task_activation_multi/7` and `reconcile_token_records/5` calls, which
currently close over `final_instance_state` as a **plain, already-bound** local variable
(not read from `changes`) — per those two functions' own existing `@spec`s and calling
convention (`engine.ex:2636-2644`). **This is the one real structural wrinkle this design
must resolve, stated precisely so ELIXIR-DEV does not have to invent it:**

`build_task_activation_and_reconciliation_multi/4`'s pipe changes from "compute
`final_instance_state` once in plain Elixir, thread it as a closed-over value into two
sibling `Multi` steps" to "the state used by the *second and third* steps must reflect
what the *first* step (an INSERT that only runs inside the transaction) produced." This is
the same category of dependency `Multi.merge/2` exists to solve, and the mechanism is:
**both `maybe_append_task_activation_multi/7`'s call and `reconcile_token_records/5`'s
call move inside the SAME outer `Multi.merge/2` callback that runs the insert step**, so
that callback can thread its own freshly-rewritten `final_instance_state` value directly
into both — as a local variable inside that one callback's own body, not via a second
`changes` read. Restated as the revised pipe shape (prose, not code):

```
Multi.new()
|> Multi.merge(fn _changes ->
     # closure captures: repo-independent inputs already bound in the
     # enclosing function (instance_id, original_active_tokens, graph,
     # seed_state.pending_task_nodes, final_instance_state as originally
     # computed, prefix)
     Multi.new()
     |> Multi.run({:hop_chain_token_records, instance_id}, fn repo, _changes ->
          insert_hop_chain_new_token_records(
            repo, instance_id, original_active_tokens, final_instance_state.tokens, prefix
          )
        end)
     |> Multi.merge(fn changes ->
          id_map = Map.fetch!(changes, {:hop_chain_token_records, instance_id})
          resolved_final_instance_state = rewrite_token_ids(final_instance_state, id_map)

          Multi.new()
          |> maybe_append_task_activation_multi(
               skip_task_activation?, instance_id, graph,
               seed_state.pending_task_nodes, resolved_final_instance_state, prefix
             )
          |> reconcile_token_records(
               original_active_tokens, resolved_final_instance_state, completed_at, prefix
             )
        end)
   end)
```

**`rewrite_token_ids/2`** — a new small pure helper (no `Repo`, no `Multi`), in
`lib/letflow/engine.ex`:

```
@spec rewrite_token_ids(InstanceState.t(), %{optional(String.t()) => Ecto.UUID.t()}) ::
        InstanceState.t()
```

Maps `instance_state.tokens` to a new list where each `%Token{}` whose `token_id` is a key
of `id_map` gets that `token_id` replaced by `id_map`'s value (stringified); every other
token is returned unchanged. When `id_map == %{}` (the common case — no hop-chain-local-new
token this hop chain), this is a no-op rewrite (every token passes through unchanged) —
ELIXIR-DEV may special-case `id_map == %{}` to return `instance_state` unchanged rather
than rebuilding an identical list, as a straightforward efficiency choice that does not
change behavior.

**Why `id_map == %{}` still safely reaches the exact same code path as today:** when no
token needed inserting, `maybe_insert_hop_chain_new_token_records/4`'s own `Multi.run`
step (§3.2 point 3) returns `{:ok, %{}}` immediately with no query, `rewrite_token_ids/2`
is a no-op, and `resolved_final_instance_state` is (behaviorally) identical to
`final_instance_state` — so `maybe_append_task_activation_multi/7` and
`reconcile_token_records/5` run with byte-for-byte the same effective input they receive
today. **Zero behavioral change for every hop chain that never fires a join within
itself** — this is the same "common case unaffected" property the ISS-0392 fix's own §2.4
establishes for its `skip_task_activation?` predicate, and this design preserves it by the
identical mechanism (a build/run-time-computed value that reduces to a no-op when the
triggering condition is absent).

### 3.5 `persist_timer_fired_advance/6` — same restructuring, own local variables

`persist_timer_fired_advance/6`'s own pipe (`engine.ex:2007-2029`) currently closes over
`final_instance_state` from its own `case sub_process_outcome do {:advanced,
final_instance_state, prepared_children} ->` match (`engine.ex:2006`), and both
`TaskActivation.append_multi_from_existing_records/6` and `reconcile_token_records/5` are
called as **sibling, independent** pipe stages today (not nested inside a `Multi.merge/2`
at all — this function's current shape is flatter than
`build_task_activation_and_reconciliation_multi/4`'s).

This design applies the identical restructuring: wrap the insert step
(`{:hop_chain_token_records, timer.instance_id}`) plus a `rewrite_token_ids/2` call in one
leading `Multi.merge/2`, whose callback produces `resolved_final_instance_state` and feeds
it to `TaskActivation.append_multi_from_existing_records/6` and
`reconcile_token_records/5` exactly as `final_instance_state` is used today — the
remainder of the pipe (`build_timer_arms_multi`,
`append_sub_process_children_creation_multi/6`, the `:projection` step) is **unchanged**,
including still closing over the **original** `final_instance_state`/`seed_state` where it
already does today (`prepared_timers`, `prepared_children`, and the final projection write
do not need the rewritten token ids — only the two functions that inspect
`.token_id`-as-a-real-id do).

## 4. Signatures — full list of what changes and what does not

**Changed:**

- `Letflow.Engine.build_task_activation_and_reconciliation_multi/4` — body restructured
  per §3.4 (adds the leading `Multi.merge/2` wrapping the new insert step + the two
  existing sibling calls). **Signature itself is unchanged** — still `(changes,
  completed_at, prefix, skip_task_activation?) :: Ecto.Multi.t()`, same as the ISS-0392
  fix left it. Callers (`build_complete_task_tail_multi/6`) need no changes.
- `Letflow.Engine.persist_timer_fired_advance/6` — body restructured per §3.5. Signature
  **unchanged** (still `(repo, timer, projection, snapshot_and_state_map, advanced_state,
  pending_events, prefix)` — actually `/7` per its current definition at
  `engine.ex:1975-1987`; this design does not alter its arity or parameter list, only its
  internal `Multi`-building body from `advanced_state`/`case sub_process_outcome`
  onward).

**New (both private, `lib/letflow/engine.ex`):**

- `insert_hop_chain_new_token_records/5` — §3.2 (`repo, instance_id,
  original_active_tokens, final_tokens, prefix` — 5 arguments).
- `rewrite_token_ids/2` — §3.4, pure, no `Repo`/`Multi`.
- `maybe_insert_hop_chain_new_token_records/4` or equivalent — the `Multi.merge/2`
  wrapper described in §3.4/§3.5. This design specifies its **behavior** (run the insert,
  then rewrite, then continue the existing pipe inside the same merge callback) rather
  than mandating it be materialized as one single named function versus an inline
  anonymous `Multi.merge(fn _changes -> ... end)` at each of the two call sites —
  ELIXIR-DEV's choice, since the two call sites' surrounding pipes differ enough (§3.3 vs.
  §3.5) that a single shared function would need to take both "what comes after" as
  arguments, which is more indirection than the two call sites (one Multi-merge callback
  each) warrant. **What is not a choice:** the insert step must run, and the rewrite must
  happen, before either `maybe_append_task_activation_multi/7`
  (or `TaskActivation.append_multi_from_existing_records/6` directly, for the timer path)
  or `reconcile_token_records/5` is invoked, at both call sites — that ordering is
  mandatory per §3.3's dependency argument, not a style preference.

**Explicitly UNCHANGED (confirmed, not merely unmentioned):**

- `Letflow.Engine.Transition.fire_join/5` and every other function in
  `lib/letflow/engine/transition.ex` — §2's decision. Zero changes to that module.
- `Letflow.Engine.TaskActivation.append_multi_from_existing_records/6` — receives an
  already-resolved `new_instance_state` (the rewritten one) exactly as it receives one
  today; its own body, including `cast_token_record_id/1`, is untouched.
- `Letflow.Engine.TaskActivation.cast_token_record_id/1` — §5 confirms explicitly this
  guard needs no change; it keeps rejecting any non-UUID `token_id` it ever sees, which
  after this fix should be **never**, for a hop-chain-local-new token specifically (any
  *other* non-UUID `token_id` reaching it would indicate a genuinely different bug this
  fix is not responsible for suppressing the signal on).
- `Letflow.Engine.do_reconcile_token_records/5` and `reconcile_one_token_record/5` — §5
  confirms explicitly. Both keep operating purely on `UPDATE`s against
  `original_active_tokens`' real ids; after this fix, `final_tokens`' ids are always a
  subset of (rewritten-)`original_ids ∪ {ids just inserted by this hop chain}` — but this
  design does **not** ask `do_reconcile_token_records/5` to know about the newly-inserted
  ids at all. See §5.1 for why this still type-checks against its existing guard.
- `Letflow.Engine.TokenRecord` (schema/changesets) — no new field, no new changeset.
  `insert_changeset/2` (`token_record.ex:98-110`) is reused as-is.
- `insert_token_records/4`/`insert_token_record/4` (`create/2`'s own helpers,
  `engine.ex:1215-1245`) — unchanged; `insert_hop_chain_new_token_records/5` is a new,
  separate function (its attrs-shape is deliberately similar, per §3.2 point 4, but it is
  not a call-site reuse of `insert_token_record/4`, because that function's own hard-coded
  `status: :active` and unconditional `attrs` shape is already exactly what's needed here
  too — ELIXIR-DEV may choose to have `insert_hop_chain_new_token_records/5` call
  `insert_token_record/4` directly per-token rather than duplicating its `attrs`
  construction, since the two are functionally identical; this design leaves that as an
  implementation-level DRY choice, not a designed requirement, because `insert_token_record/4`
  is `private` and both live in the same module, so nothing prevents direct reuse).

## 5. Explicit confirmation: neither existing guard changes, and why that is still correct after this fix

### 5.1 `TaskActivation.cast_token_record_id/1` — unchanged, still correct

This guard's own comment (`task_activation.ex:300-303`) already frames itself as
"Defense-in-depth check on top of the caller's own token_id-is-a-real-TokenRecord-id
reconstruction invariant" — i.e., it exists to catch an **upstream violation** of that
invariant, not to be the mechanism that establishes it. After this fix,
`build_task_activation_and_reconciliation_multi/4` and `persist_timer_fired_advance/6`
both establish the invariant correctly (§3.4/§3.5) before calling
`append_multi_from_existing_records/6` — so this guard should simply never fire on the
join-fire path anymore, and continues firing exactly as before on any other, genuinely
unexpected violation (a real defense-in-depth property, preserved, not weakened).

### 5.2 `do_reconcile_token_records/5`'s `original_ids` membership check — unchanged, still correct

This function's own docstring-adjacent comment (`engine.ex:2684-2687`) frames its guard as
"a `token_id` present in `final_instance_state.tokens` with no matching original record is
a typed, rolled-back failure (INV-EE48-8), never a silent mis-insert." That invariant is
about **detecting an unexplained new token_id**, and this fix does not weaken that
detection — it removes the one case (a join-fired token, hop-chain-local, whose "original
record" genuinely doesn't exist *yet* because this is the very hop chain that produces it)
from ever reaching this function in the first place, by inserting the missing record
**before** `reconcile_token_records/5` runs (§3.3's ordering). Every token this function
still sees post-fix has a real, already-existing-as-of-this-function's-own-call
`TokenRecord` row — either because it existed before the hop chain started
(`original_active_tokens`), or because `insert_hop_chain_new_token_records/5` just created
it earlier in the **same** `Multi.merge/2` callback, strictly before this function's own
step runs. **`original_ids` itself is not recomputed or widened** — it remains exactly
`MapSet.new(original_active_tokens, &to_string(&1.id))`, computed from the hop chain's
pre-existing token set only. What changes is that `final_tokens` (post-rewrite) no longer
contains any `token_id` that isn't already a member of that same, unwidened `original_ids`
— because `rewrite_token_ids/2` has replaced every one that wasn't with a real id **whose
own row now genuinely predates this function's own call**, even though it postdates the
hop chain's *start*. This is why no change to `do_reconcile_token_records/5` itself is
needed: it was never wrong about what it checks, only ever starved of an upstream step
that should have run before it.

## 6. Regression scenario (for TEST-DESIGNER)

**Exact scenario, matching ISS-0408's own filed description and its
`WF03-ISS0396-20260902` discovery context:**

1. A process definition: `START -> PARALLEL_GATEWAY(split into 2 branches) -> HUMAN_TASK(a)
   / HUMAN_TASK(b) -> PARALLEL_GATEWAY(join) -> HUMAN_TASK(after_join) -> END` — the
   distinguishing feature versus the already-passing `graph_start_parallel_split_join_end`
   fixture (`test/letflow/engine_test.exs:127`) is that the join's own outgoing edge leads
   to **another `:HUMAN_TASK`**, not directly to `:END`.
2. `Engine.create/2` the instance (reaches `task_a`/`task_b`, both pending — this part
   already works, matching `graph_start_parallel_split_human_tasks`'s own passing test).
3. `Engine.complete_task/3` on `task_a`'s own task id. Per `join_outcome/1`
   (`transition.ex:1172-1189`), one branch arriving alone is `:wait` — this call should
   succeed, leaving `task_b` still pending and the join counter recorded (no join fires
   yet).
4. `Engine.complete_task/3` on `task_b`'s own task id. This is the hop chain that fires
   the join (`fire_join/5`), producing the synthetic `token_id`, immediately continuing to
   `HUMAN_TASK(after_join)`, which is a **newly-pending** task for
   `TaskActivation.append_multi_from_existing_records/6` to activate.
5. **Pre-fix assertion (must FAIL on pre-fix code):** step 4's call raises/returns an
   error whose reason is `{:invalid_token_record_id, token_id}}` (surfaced however
   `complete_task/3`'s own error-mapping wraps a `Multi.run` step failure — TEST-DESIGNER
   confirms the exact wrapping shape empirically rather than this design guessing it) —
   the `TaskActivation` guard from §1, still reachable pre-fix. TEST-DESIGNER states this
   fail-first result explicitly per `WF-03_issue_resolving.md`'s Steps 2-4 procedure.
6. **Post-fix assertion (must PASS on post-fix code):** step 4's call returns success;
   exactly one new `tokens` row exists for the join-merged token (real UUID `id`,
   `node_id == "after_join"`, `branch_id == nil`, `status == :active`); exactly one new
   `tasks` row exists for `HUMAN_TASK(after_join)`, whose `token_id` FK resolves to that
   same newly-inserted `tokens` row; the two original branch tokens
   (`task_a`'s and `task_b`'s own `TokenRecord` rows) are both reconciled to
   `status: :completed` by `do_reconcile_token_records/5` (they are consumed by the join,
   not carried forward) — this is the existing, unchanged reconciliation behavior,
   asserted here to confirm this fix didn't disturb it.
7. **timer_fired variant (covers `persist_timer_fired_advance/6`, §3.5):**
   TEST-DESIGNER additionally constructs (or confirms reachable/unreachable, stating
   which) an equivalent scenario where the *second* join-completing branch arrives via a
   `:TIMER` node's own fire (`Letflow.Scheduler.fire_timer/2` → `advance_after_timer_fired/3`
   → `persist_timer_fired_advance/6`) rather than `complete_task/3` — e.g. one branch a
   `HUMAN_TASK` completed normally, the sibling branch a `:TIMER` node whose fire is the
   event that satisfies the join's last outstanding branch. If constructing this fixture
   is not straightforward within existing test helpers, TEST-DESIGNER states that
   explicitly rather than skipping the call site silently — `persist_timer_fired_advance/6`
   is one of the two call sites this design fixes (task description, "both call sites need
   the fix") and ISSUE-FIXER's diagnosis names it as equally affected, so its own coverage
   is not optional, only its concrete fixture construction is TEST-DESIGNER's to work out.

## 7. Open questions (explicit — not resolved by guessing)

**OQ-1 — should `insert_hop_chain_new_token_records/5`'s `MapSet.new(original_active_tokens,
&to_string(&1.id))` computation be factored into one shared private helper used by both it
and `do_reconcile_token_records/5`, rather than each computing it independently?** Both
now need the identical value from the identical input, in the same `Multi.merge/2`
callback's own lexical scope in most call shapes (§3.4/§3.5) — likely trivial to share as
a single `let`-bound local rather than two separate `MapSet.new/2` calls, but this is a
DRY/style question at the same level as §4's "does `insert_hop_chain_new_token_records/5`
call `insert_token_record/4` directly" question — left to ELIXIR-DEV, not designed here as
a hard requirement, since either shape is behaviorally identical.

**OQ-2 — cross-instance ordering when a hop chain's `Multi.merge/2` (§3.4) wraps BOTH the
new insert step and the existing task-activation/reconciliation steps, and that same hop
chain ALSO reaches `append_sub_process_children_creation_multi/6`
(`engine.ex:2503`/`engine.ex:2023`) for a **different** `instance_id` later in the same
outer pipe.** §3.3 already argues the tuple key forecloses a *literal* key collision even
in that case. This open question is narrower: whether the **relative execution order**
between this design's new insert step (always for the hop chain's own `parent_instance_id`
alone) and any SUB_PROCESS-child-related Multi content appended later in the pipe (for a
child/grandparent `instance_id`) matters for correctness beyond key-collision-avoidance —
e.g., whether a SUB_PROCESS child's own `prepare_child_activation/4` could ever need to
observe the join-merged token's real id before this design's rewrite has happened. Not
found to be reachable by this design's own read of `prepare_sub_process_children_for_completion/8`
(`engine.ex:2314-2366`, which operates on `pending_events`/`advanced_state`, computed
**before** `build_task_activation_and_reconciliation_multi/4` is ever called, per
`dispatch_task_completion_hop_chain/7`'s own call order, `engine.ex:2234-2247` — SUB_PROCESS
preparation is already complete and its own `prepared_children` list already fixed by the
time this design's new step would run) — but flagged rather than silently assumed, since
it was not exhaustively traced through every SUB_PROCESS/join-combination path this fix
does not itself construct a test for.

**OQ-3 — whether a hop chain can fire TWO OR MORE joins in the same `advance_until_stable/4`
run, each producing its own synthetic token_id, and whether `insert_hop_chain_new_token_records/5`'s
own per-token `Enum.reduce_while` (§3.2 point 4, mirroring `insert_token_records/4`'s own
existing reduce shape) correctly handles that without any additional per-token
coordination.** §3.1's definition operates on the **filtered set** of `final_tokens`, not
on "the join that fired" as a unit, so multiple hop-chain-local-new tokens (however many
joins fired) are handled uniformly by the same filter — no per-join special-casing is
needed structurally. Not separately tested by this design's own §6 scenario (single join),
left to TEST-DESIGNER/TEST-DESIGN-VALIDATOR to judge whether a two-join-in-one-hop-chain
scenario is realistically constructible and worth its own coverage, or is adequately
covered by the single-join case's own demonstration that the filter-and-insert mechanism
is not join-count-specific.
