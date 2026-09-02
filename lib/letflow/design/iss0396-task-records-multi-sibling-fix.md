# ISS-0396 — disambiguating `{:task_records, instance_id}` per sibling SUB_PROCESS completion cascade

Status: design (Step 2, WF03-ISS0396-20260902). Fixes the call(2)-vs-call(2)
`Ecto.Multi` key collision left open by ISS-0392 (which fixed only the
call(1)-vs-call(2) case). Builds on
`lib/letflow/design/iss0392-multi-task-records-collision-fix.md` and
`handoffs/WF03-ISS0396-20260902/step-01-issue-fixer-diagnosis.json` — this
document re-derives every claim in that diagnosis directly from the current
`lib/letflow/engine.ex`, `lib/letflow/engine/sub_process.ex`, and
`lib/letflow/engine/task_activation.ex`, and corrects one part of it (§1
below) rather than repeating it uncritically.

## 1. Re-verified defect mechanism, and a correction to the Step-1 diagnosis's call-site framing

The colliding step is confirmed exactly as diagnosed:
`TaskActivation.append_multi_from_existing_records/6` (task_activation.ex:258)
appends `Multi.run(multi, {:task_records, instance_id}, ...)`, keyed only on
`instance_id`. It is called from `build_completion_write_steps/12`
(sub_process.ex:966-972), which is reached once per synchronously-completing
SUB_PROCESS child via `maybe_chain_synchronous_completion/6`
(sub_process.ex:481-508) → `append_completion_multi/5` (sub_process.ex:731-808)
→ `build_completion_multi_from_merge/12` (sub_process.ex:819-942) →
`build_completion_write_steps/12`. When 2+ sibling children of the *same*
parent `instance_id` each complete synchronously in one transaction, each
sibling's own call appends the *same* `{:task_records, parent_instance_id}`
key onto the *same* accumulating `Multi`, and `Ecto.Multi.merge_results/3`
raises `RuntimeError: cannot merge Multi` at execution time. This part of the
Step-1 diagnosis is confirmed correct by direct reading.

**Correction**: the Step-1 diagnosis frames the reachable trigger as
`Letflow.Engine.append_sub_process_children_creation_multi/6` (engine.ex:
2525-2545, the `complete_task/3` hop-chain's own appender) receiving 2+
`prepared_children` entries from a PARALLEL_GATEWAY split "in the same hop
chain." Re-deriving this path independently (not assumed from the docs table)
shows it cannot actually produce 2+ entries in one `complete_task/3` call
today:

- `prepared_children` for the `complete_task/3` path is built by
  `prepare_sub_process_children_for_completion/8` (engine.ex:2314-2366), which
  filters `pending_events` — the events produced by advancing **one**
  already-completing token's own transition/`advance_until_stable` chain
  (engine.ex `build_snapshot_and_state/4`, `dispatch_task_completion_hop_chain`)
  — for `{:sub_process_start, token_id, node_id}`.
- Each such `token_id` is validated by `resolve_parent_token_record_id/2`
  (engine.ex:2368-2380) against `persisted_token_ids` — TokenRecord ids that
  already existed in the DB **before this hop-chain began**
  (`build_snapshot_and_state/4`'s `active_token_records`, loaded once per
  `complete_task/3` call, engine.ex:1737-1748). A token minted **during** this
  hop-chain (a PARALLEL_GATEWAY split's own derived branch id, e.g.
  `"#{token.id}/0"`) fails that membership check and is rejected with
  `{:sub_process_after_split_join_not_supported, token_id}` — proven live by
  `test/letflow/engine_sub_process_test.exs`'s own
  `"a SUB_PROCESS node off a PARALLEL_GATEWAY split, within the completing hop
  chain, is rejected"` test (ISS-0067, line 923), which asserts *zero*
  children are created and the whole transaction rolls back.
- Because a `complete_task/3` call's hop-chain only ever advances the tokens
  causally reachable from the one completing token's own transition, and any
  split *within* that hop-chain produces exactly the derived, rejected ids
  above, **the `complete_task/3` path cannot currently place 2+ entries in
  `prepared_children` at all** — it can place at most one (a single
  pre-existing token advancing directly onto one SUB_PROCESS node, the
  already-tested ISS-0067/ISS-0392 shape).

The genuinely reachable trigger, confirmed by reading `Engine.create/2`'s own
root-activation path, is different:

- `start_instance/5` → `activate/3` (engine.ex:764-…) dispatches the brand-new
  instance's **first** hop-chain from its single root token, through
  `advance_until_stable`, with **no** `resolve_parent_token_record_id`-style
  membership check anywhere on this path — every token in a newly-created
  instance is by definition "new," so there is no "must already be
  persisted" concept to violate.
- `prepare_sub_process_children/5` (engine.ex:572-605), this path's own
  preparer, filters `pending_events` for `{:sub_process_start, token_id,
  node_id}` and calls `SubProcess.prepare_child_activation/4` for **every**
  match unconditionally — no rejection of split-derived ids.
- `persist/8` (engine.ex:939-1109) → `build_sub_process_children_multi/6`
  (engine.ex:1085-1109) then does exactly the same
  `Enum.reduce(prepared_children, Multi.new(), fn {token_id, prepared},
  acc_multi -> SubProcess.append_start_multi(...) end)` shape as the
  `complete_task/3` path's `append_sub_process_children_creation_multi/6` —
  chaining `maybe_chain_synchronous_completion/6` per child onto the *same*
  Multi.

So a definition whose graph is (for example) `START → PARALLEL_GATEWAY(split)
→ {SUB_PROCESS(sp1), SUB_PROCESS(sp2)} → PARALLEL_GATEWAY(join) → END`, with
sp1/sp2 both pointing at a synchronously-completing (`START → END`) child
definition, reproduces ISS-0396 **at `Engine.create/2` time**, via
`build_sub_process_children_multi/6`, not via `complete_task/3`'s
`append_sub_process_children_creation_multi/6`. Both functions funnel into the
identical `maybe_chain_synchronous_completion/6` →
`build_completion_write_steps/12` chain, so **the fix below is correct and
sufficient for both call sites** regardless of which one is actually
reachable today — but §5 (test design) targets the create-time path
specifically, since that is the one independently confirmed reachable. This
correction does not change the fix's shape; it changes which regression test
actually exercises it. Flag for ORCH/TEST-DESIGNER: the `complete_task/3`
path may become reachable in the future if ISS-0067's guard is ever relaxed
(e.g. to support split→join-wrapped SUB_PROCESS branches mid-hop-chain,
already excluded today) — the fix in this document covers that case too by
construction, with no further change needed.

## 2. Key disambiguation

`TaskActivation.append_multi_from_existing_records/6` gains one new,
**optional, last** parameter:

```
@spec append_multi_from_existing_records(
        multi :: Ecto.Multi.t(),
        instance_id :: Ecto.UUID.t(),
        graph :: Letflow.Engine.Graph.t(),
        previous_pending_task_nodes :: [Letflow.Engine.Token.t()],
        new_instance_state :: Letflow.Engine.InstanceState.t(),
        prefix :: String.t(),
        key_disambiguator :: term() | nil
      ) :: Ecto.Multi.t()
```

- `key_disambiguator` defaults to `nil` (declared with `\\ nil` in the
  function head, so all existing 6-argument call sites keep compiling
  unchanged).
- Key computation: when `key_disambiguator` is `nil`, the appended step's key
  is `{:task_records, instance_id}` — byte-identical to today. When
  `key_disambiguator` is non-`nil`, the key is `{:task_records, instance_id,
  key_disambiguator}`.
- **Only one call site passes a non-nil value**: `build_completion_write_steps/12`
  (sub_process.ex:966-972), which already has `parent_token` in scope (it is
  this function's own second parameter). It changes from:
  `TaskActivation.append_multi_from_existing_records(parent_instance_id, graph,
  seed_state.pending_task_nodes, final_instance_state, prefix)` to the same
  call with a 6th argument, `parent_token.id`, appended.
- The other two call sites — `maybe_append_task_activation_multi/7`
  (engine.ex:2674-2682, the `complete_task/3` "call (1)" path, already gated by
  ISS-0392's `skip_task_activation?`) and `persist_timer_fired_advance/7`'s own
  inline call (engine.ex:2009-2015, the TIMER-fire path) — are **not
  modified**. They keep calling the 6-argument form, which resolves to
  `key_disambiguator: nil` by default, preserving their exact current key
  shape and behavior.

Resulting key shape per call site, post-fix:

| Call site | Key |
|---|---|
| `maybe_append_task_activation_multi/7` (engine.ex:2674) | `{:task_records, instance_id}` (unchanged) |
| `persist_timer_fired_advance/7` (engine.ex:2009) | `{:task_records, instance_id}` (unchanged) |
| `build_completion_write_steps/12` (sub_process.ex:966), one call per synchronously-completing SUB_PROCESS child | `{:task_records, instance_id, parent_token.id}` (new) |

`append_multi/6` (task_activation.ex:168-193, the fixed-atom `:task_records`
key used by `Engine.create/2`'s own `:token_record`-based insertion and by
`persist/8`'s own root path) is a completely separate function with a
completely separate key namespace (a bare atom, never a tuple) — untouched,
not discussed further.

### Why `parent_token.id` and not `child_instance_id`

`parent_token.id` is chosen over the diagnosis's other candidate,
`child_instance_id`, for consistency with `build_completion_write_steps/12`'s
own four sibling-safe keys already built off it in the same function
(`reconciliation_key`, `event_key`, `projection_key` — all `{_, parent_token.id}`
— and `cascade_lookup_key`, `{_, parent_instance_id}`, sub_process.ex:960-963):
every other per-invocation-unique key in this function already uses
`parent_token.id` as its disambiguator, and none of those four have ever
collided across siblings — this fix brings the fifth (and last) key in the
same function in line with the other four, rather than introducing a second,
inconsistent disambiguation convention. `child_instance_id` was available too
(also in scope, sub_process.ex:944-947) and would have worked equally well for
uniqueness, but was not chosen, to keep this function's five keys uniform.

### Uniqueness proof for `parent_token.id` across siblings

Re-derived from `prepare_sub_process_children_for_completion/8`
(engine.ex:2314-2366) and `prepare_sub_process_children/5` (engine.ex:572-605),
whichever path is in play (§1): each `{parent_token_record_id, prepared}` (or
`{token_id, prepared}`) tuple in `prepared_children` originates from a
**distinct** `{:sub_process_start, token_id, node_id}` pending event, and
distinct pending events for distinct SUB_PROCESS nodes carry distinct
`token_id`s by construction of `Transition.dispatch_parallel_split/4` (each
split branch mints its own token). `append_start_multi/7`
(sub_process.ex:398-479) resolves that `parent_token_record_id`/`token_id`
into a real `%TokenRecord{}` via `update_parent_token_waiting/5`
(sub_process.ex:662-682, `repo.get(TokenRecord, parent_token_record_id, ...)`
followed by `repo.update/2`) — so the `parent_token` later read out of
`changes[parent_token_key]` in `maybe_chain_synchronous_completion/6`
(sub_process.ex:489-490) has `.id == parent_token_record_id` exactly. TokenRecord
`id`s are UUID primary keys, globally unique. Therefore, for any set of
siblings processed within one `Enum.reduce` (`append_sub_process_children_creation_multi/6`
or `build_sub_process_children_multi/6`), their `parent_token.id` values are
pairwise distinct, and so are the resulting 3-tuple keys — even though every
sibling shares the same `instance_id` (2nd tuple element).

### Tuple-shape safety (no accidental re-collision)

`Ecto.Multi` keys are compared by plain Erlang term equality
(`Ecto.Multi.merge_results/3` builds the running `names` `MapSet` and checks
membership by `==`/hashing). A 2-tuple `{:task_records, id}` and a 3-tuple
`{:task_records, id, disambiguator}` are never `==` regardless of their
contents — Erlang tuple equality requires equal arity first. This means:

- The disambiguated per-sibling keys can never collide with either unmodified
  call site's `{:task_records, instance_id}` key (different arity).
- A deeper cascade level's own call (`maybe_cascade_to_grandparent/6`,
  sub_process.ex:1013-…, recursing into `append_completion_multi/5` with a
  **different** `grandparent_token`) produces `{:task_records,
  grandparent_instance_id, grandparent_token.id}` — both tuple components
  differ from any sibling-level key at the level below it (different
  `instance_id` *and* a different, distinct TokenRecord's `.id`), so no
  collision there either, matching ISS-0392's own already-tested §3.1
  multi-level-cascade case.

## 3. Other readers of the `:task_records` key — grep-confirmed

```
grep -rn ":task_records" lib/ test/
```

found exactly two production call sites (task_activation.ex:176 for the
fixed-atom `append_multi/6`, and task_activation.ex:258 for
`append_multi_from_existing_records/6`/`7`, the one this fix touches) and no
other production code reading either key by literal match — no `Map.fetch!`,
`Map.get`, or `case`/pattern-match anywhere else in `lib/` names
`{:task_records, _}` or `{:task_records, _, _}`. Every other reference is a
code comment or a test-file comment describing the collision (test files:
`engine_sub_process_test.exs` lines 1011/1022/1078/1086/1155/1160, and
`simulation/req207_vortex_test.exs` line 218 — all prose, not pattern
matches). No downstream Multi step in `build_completion_write_steps/12`
(`reconciliation_key`, `event_key`, `projection_key`,
`maybe_cascade_to_grandparent`) reads the `:task_records` step's own return
value from `changes` — confirmed by re-reading sub_process.ex:944-1063: none
of those four steps' callbacks reference `changes` for anything task-related.
**Conclusion: no other reader depends on the old 2-tuple shape; changing this
one call site's key to a 3-tuple is safe with no other file to update.**

## 4. Correctness argument: siblings' writes are independent and order-independent

Re-verified by reading `load_parent_context/2` (sub_process.ex:1070-1111)
directly, not by trusting its docstring: it issues fresh, unlocked
`Repo.get(InstanceProjection, parent_token.instance_id, ...)`,
`Repo.all(TokenRecord where instance_id == ... and status in [:active,
:waiting])`, and `Repo.all(Task where instance_id == ... and status ==
:pending)` queries **at the moment it is called** — i.e. inside sibling N's own
`Multi.merge/2` callback (`maybe_chain_synchronous_completion/6`,
sub_process.ex:489), which `Ecto.Multi` invokes in the same left-to-right
order the reduce built the Multi in, on the same connection/transaction as
every prior sibling's already-applied steps. Postgres (and every SQL database
Ecto targets) makes a transaction's own prior writes on its own connection
visible to its own later reads by default (no special isolation-level
concession needed for read-your-own-writes within one transaction) — so
sibling 2's `seed_state` (built from these fresh reads) already reflects
sibling 1's inserted task rows, updated token rows, and updated projection
row. `Transition.transition/3` (sub_process.ex:846-849) then computes sibling
2's *own* diff (`newly_pending`, via `Letflow.Engine.tokens_needing_dispatch/3`)
against that already-advanced snapshot, not against a stale pre-sibling-1
snapshot — each sibling's insert set is disjoint from every other's by
construction (each diffs against the other's own already-applied result), so
no sibling's write is redundant or overwrites another's.

**Disambiguating the key changes nothing about this.** The key is purely an
`Ecto.Multi` internal name for referencing a step's *result* from a later
step; it has no bearing on *when* a step runs (that is fixed by the Multi's
insertion order, unchanged by this fix) or on what a step's callback *reads*
(governed by `load_parent_context/2`'s own live queries, also unchanged by
this fix — its call signature and body are not modified). The fix is
additive-only: it changes the label under which sibling N's insert-result is
recorded in the transaction's `changes` map, not the query, the transaction,
the ordering, or the inserted rows themselves.

## 5. Test design (specification, not implementation)

New `describe` block in `test/letflow/engine_sub_process_test.exs`, e.g.
`"ISS-0396 -- 2+ sibling SUB_PROCESS children completing synchronously in one transaction no longer collide on {:task_records, instance_id}"`.

**Fixture graphs** (two new private helpers, following this file's existing
naming/shape conventions):

- A child definition graph identical in shape to the existing
  `graph_child_immediate/0` (`START → END`, synchronous) — reuse it directly,
  no new helper needed.
- A new root/parent graph helper, e.g. `graph_root_split_into_two_subprocesses/1`,
  taking the child definition name and producing: `START → PARALLEL_GATEWAY("split")
  → {SUB_PROCESS("sp1"), SUB_PROCESS("sp2")} → PARALLEL_GATEWAY("join") →
  END`, both `sp1`/`sp2` pointing at the given child definition name via
  `"attributes" => %{"definition_name" => child_definition_name}` — same
  edge/node JSON shape as `graph_parent_split_then_subprocess/1`
  (engine_sub_process_test.exs:223-252) but with `"start"` feeding directly
  into `"split"` (no intervening `HUMAN_TASK("gate")`), since this scenario is
  exercised via `Engine.create/2`'s own root activation (§1), not via a
  completing task.

**Test body** (single test, mirroring the existing ISS-0392
single-level test's structure):

1. `provisioned_tenant()` for `schema_name`.
2. `active_definition!(schema_name, graph_child_immediate())` for the shared
   child definition (both branches point at the same child definition name —
   deliberately, since ISS-0396 is about the *Multi key*, keyed on the
   *parent's* `instance_id`/`parent_token.id`, not on the child definition
   used).
3. `active_definition!(schema_name, graph_root_split_into_two_subprocesses(child_def.name))`
   for the root/parent definition.
4. Pre-fix baseline note (comment, not a separate test — matching this file's
   existing "pre-fix raised / post-fix does not" documentation style): before
   this fix, `Engine.create(start_attrs(parent_def), prefix: schema_name)`
   itself raises `RuntimeError "cannot merge Multi; ... [task_records:
   \"<...>\"]"` at the `build_sub_process_children_multi/6` step, since both
   sp1's and sp2's own synchronous-completion cascades append the identical
   `{:task_records, parent_instance_id}` key. Assert instead, post-fix:
   `assert {:ok, created} = Engine.create(start_attrs(parent_def), prefix: schema_name)`
   — no raise.
5. Assert the parent's own `InstanceProjection` reached `:completed` — both
   branches complete synchronously and the join immediately admits both,
   advancing the root instance straight through `"join"` to `"end"` within
   this same `create/2` transaction (no external `complete_task/3` call
   needed at all, unlike the ISS-0392 single-level test, since nothing here
   is gated behind a `HUMAN_TASK`).
6. Assert `child_projections(schema_name, created.instance_id)` has length 2
   — both sp1's and sp2's child instances were created (proves neither
   sibling's own children-creation multi step was silently dropped/skipped by
   the fix — this is the assertion that would have failed under a "just skip
   the second sibling" style fix the diagnosis explicitly rejected in favor of
   the key-disambiguation approach in §1 of the Step-1 diagnosis).
7. For each of the two child projections: assert `parent_instance_id ==
   created.instance_id`, and that its own definition name matches the shared
   child definition (both children are real, independent instances of it, not
   one masquerading as the other).
8. Assert `sub_process_completed_events(schema_name, created.instance_id)`
   has length 2 (one `SUB_PROCESS_COMPLETED` event per sibling — proves both
   siblings' own `event_key` step, sub_process.ex:961, ran to completion, not
   just one).
9. Assert `all_tasks_for_instance(schema_name, created.instance_id)` is `[]`
   (or asserts on its length matching the expected pre-join-completion task
   count for this specific graph — this graph has no `HUMAN_TASK` node
   anywhere, so the root instance itself should have inserted zero `tasks`
   rows across the whole hop chain; this is the direct "both sibling
   `{:task_records, instance_id, parent_token.id}` steps ran, inserted
   nothing extra, and did not orphan/duplicate any row" assertion, the
   `:task_records` step's own `newly_pending == []` short-circuit case,
   engine/task_activation.ex:262-264).
10. Cross-reference to ISS-0397 (per the Step-1 diagnosis's own flag,
    confirmed still accurate — ISS-0397 touches `reconcile_projection/5`
    /`reconcile_parent_projection/5` and the `instance_projections.join_counters`
    column, a different write path than this fix's `:task_records` step):
    this test's root instance projection row is written/updated sequentially
    by each sibling's own `projection_key` step (sub_process.ex:994-1002,
    `reconcile_parent_projection/5`) before the join admits the second
    sibling — assert (as a secondary, not primary, assertion) that the final
    `InstanceProjection.join_counters` value reflects both branches having
    joined (non-empty/zeroed-out for `"join"`, per whatever shape
    `SnapshotWriter.deserialize_join_counters/1` exposes) — worth asserting
    since it is exercised "for free" by this same scenario, not because this
    fix changes that column's behavior.

**What this test does NOT need to cover** (explicitly out of scope, not a
silent gap): a `complete_task/3`-triggered variant of this same collision.
Per §1, that path cannot currently produce 2+ `prepared_children` entries
(ISS-0067 forecloses it), so no such test can be written today without first
changing ISS-0067's own guard — which this design does not propose.

## 6. Files this fix touches

- `lib/letflow/engine/task_activation.ex` — `append_multi_from_existing_records/6`
  gains the optional `key_disambiguator` parameter (→ effectively `/7` with a
  default), and its `@doc`/`@spec` are updated to describe the new key shape.
  No other function in this module changes.
- `lib/letflow/engine/sub_process.ex` — `build_completion_write_steps/12`'s
  one call to `TaskActivation.append_multi_from_existing_records/...` gains
  the `parent_token.id` argument. No other line in this file changes.
- `lib/letflow/engine.ex` — **no changes**. Both of its call sites
  (`maybe_append_task_activation_multi/7`, `persist_timer_fired_advance/7`)
  keep calling the existing 6-argument form and are unaffected.
- `test/letflow/engine_sub_process_test.exs` — new describe block and two new
  private graph-fixture helpers per §5 (TEST-DESIGNER's own responsibility to
  write; specified, not implemented, here).

## 7. Open questions (explicitly unresolved, not silently assumed)

- **OQ-1**: whether a hypothetical future relaxation of ISS-0067's
  `resolve_parent_token_record_id/2` guard (to support a SUB_PROCESS reached
  mid-hop-chain from a split, e.g. behind an intervening non-blocking node)
  could let the `complete_task/3` path reach this same collision. This design
  and fix already cover that case by construction (§2's key shape applies
  identically regardless of which of the three call sites reaches
  `build_completion_write_steps/12`), so no design change would be needed if
  ISS-0067's guard is ever relaxed — flagging only so a future change to that
  guard doesn't re-open a "is ISS-0396 still fixed" question that this
  document already answers "yes."
- **OQ-2**: whether a *no-join* variant of the split-then-2-subprocesses shape
  (both branches leading independently straight to their own `END`, with no
  `PARALLEL_GATEWAY("join")` reconciling them, i.e. an unbalanced/non-block-
  structured split) could cause **both** siblings to independently observe
  `final_instance_state.status == :completed` and **both** call
  `maybe_cascade_to_grandparent/6` for what would then need to be the *same*
  grandparent-waiting token in a nested (child-of-child) scenario — which
  would reintroduce a two-siblings-same-key collision one level up, this time
  on `grandparent_token.id` itself being shared rather than distinct. Not
  reachable in this design's own root-level test (§5) because a root instance
  has no grandparent to cascade to. Left unresolved here: CODE-DESIGN-VALIDATOR
  and/or a follow-up issue should confirm whether Letflow's PARALLEL_GATEWAY
  split/join validation (REQ-051's own block-structure requirement,
  referenced in the ISS-0067 test comment at engine_sub_process_test.exs:210-222,
  "single-hop, so `find_matching_join/2`'s `walk_to_gateway/3` accepts this as
  a legal block-structured split") already forecloses an unbalanced,
  join-less split from validating at all — if it does, OQ-2 is moot; if not,
  it names a genuinely separate, deeper-nested variant of this same defect
  class, out of this fix's scope to address.
