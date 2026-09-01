# Design: ISS-0398 — `walk_to_gateway/3` fails a fork branch containing a
# non-`PARALLEL_GATEWAY` branching node before reaching its join

**Issue:** ISS-0398 (`docs/issues/ISS-0398.yaml`), severity MAJOR, discovered in `WF02-REQ208-20260901`
**Requirement of origin:** REQ-051 (`lib/letflow/design/req051-parallel-gateway-split-join.md`, §3.3, §12.4)
**Owner (implementer):** ELIXIR-DEV
**Owned module:** `lib/letflow/engine/transition.ex` (`find_matching_join/2`, `walk_to_gateway/3`, both
private functions inside `Letflow.Engine.Transition`)
**This document produces:** a replacement traversal for `walk_to_gateway/3` — a per-branch,
per-path reachability search over `definition_snapshot.edges` — and the exact agreement rule
`find_matching_join/2` applies to its result. Signatures, `@spec`/`@type` shapes, and a precise
prose/pseudocode algorithm only. No implementation code, no `defmodule`/`defstruct`, no function
bodies in code fences — matches this project's design-gate convention (REQ-206/207/208's own
validated designs).

## 0. Sources read for this design

- `handoffs/WF03-ISS0398-20260901/step-01-issue-fixer-diagnosis.json` (full) — ISSUE-FIXER's root
  cause, existing-coverage inventory, scoped fix proposal, and the nested-`PARALLEL_GATEWAY`
  false-positive risk this design must resolve.
- `lib/letflow/engine/transition.ex`, full current text of `dispatch_parallel_split/4` (lines
  748–799), `find_matching_join/2` (804–828), `walk_to_gateway/3` (830–862), `gateway_role/2`
  (730–741), read directly from source (not trusted from the diagnosis's line numbers, which are
  confirmed accurate against this reading).
- `lib/letflow/design/req051-parallel-gateway-split-join.md` §3.3 (lines 261–282, the
  gate-approved `find_matching_join/2` algorithm description this design amends) and §12.4 (lines
  631–639, the "block-structured-graph assumption" open question this fix closes for the
  non-`PARALLEL_GATEWAY`-branching-node case only, and explicitly does not close for the
  nested-`PARALLEL_GATEWAY` case).
- `test/letflow/engine/parallel_gateway_test.exs` (full, all AC1–AC6 groups) — every existing
  assertion this fix must continue to satisfy unchanged, walked through in §3 below.
- `docs/issues/ISS-0398.yaml` (full) — the reported scenario (REQ-208's Meridian
  committee-quorum graph, an `EXCLUSIVE_GATEWAY` "kyc-routing" node with 3 outgoing edges inside a
  `PARALLEL_GATEWAY` fork branch).
- `lib/letflow/definitions/graph.ex` lines 63–69, 156, 203–209 — confirms `node_type/0`'s union
  includes both `:EXCLUSIVE_GATEWAY` and `:PARALLEL_GATEWAY` as distinct atoms, and that
  `@gateway_types` already treats them as a pair for CHK-* structural purposes elsewhere in the
  codebase (not reused here, since this fix works at the `dispatch_parallel_split/4` runtime layer,
  not the structural-validator layer — see §5).
- `grep -li` over `docs/issues/*.yaml` for `nested.*parallel|block-structured|internal.*branch` —
  no hits. No existing issue already tracks the nested-`PARALLEL_GATEWAY`-within-a-branch follow-on
  named in §4 below; it does not yet exist in the queue.

## 1. Problem restated precisely

`find_matching_join/2` (transition.ex:806) calls `walk_to_gateway/3` once per outgoing edge of a
`PARALLEL_GATEWAY` split node. `walk_to_gateway/3`'s current clause structure (transition.ex:837–862):

1. If `node_id` is already in `visited` → `:error` (cycle guard).
2. If `node_id` doesn't resolve to a node → `:error`.
3. If the resolved node's `node_type == :PARALLEL_GATEWAY` → `{:ok, gateway_id}` immediately —
   the only success leaf.
4. Otherwise, look at the node's own outgoing edges: exactly one → recurse into its target;
   any other count (zero, i.e. a dead end/`:END`, or more than one, i.e. any branching node
   regardless of type) → `:error`.

Clause 4's exact-one-outgoing-edge requirement is what fails ISS-0398's reported scenario: a fork
branch that passes through an `EXCLUSIVE_GATEWAY` (out-degree > 1) before reaching the
`PARALLEL_GATEWAY` join. `find_matching_join/2`'s `Enum.reduce_while` (transition.ex:810–822) halts
the *entire* reduction the instant any one branch's `walk_to_gateway/3` call returns `:error`, so
one branching sub-node inside one branch fails the whole split at instance-creation time
(`{:error, {:activation_failed, {:no_matching_join_found, split_node_id}}}` from `Engine.create/2`).

Per `lib/letflow/design/req051-parallel-gateway-split-join.md` §12.4, this is a **named, never-closed
open question** ("assumes every branch path... contains no further branching node before reaching
the join... whether Letflow's structural validator *should* reject such graphs upstream... is left
for REQ-028/029's own CODE-DESIGNER to consider... not resolved here"), not an undocumented bug
relative to the gate-approved design. This design closes that gap for the scope ISS-0398 actually
needs: branching via a **non-`PARALLEL_GATEWAY`** node (in practice, `:EXCLUSIVE_GATEWAY`, and any
future non-parallel branching node type) inside a fork branch.

## 2. Replacement algorithm

### 2.1 New leaf-outcome type

```
@type branch_leaf :: {:gateway, gateway_id :: String.t()} | :dead_end
```

A `branch_leaf` is the outcome of following one single path (not a whole branch's subtree) forward
from some starting node until traversal cannot continue in a single, unambiguous way. `:dead_end`
covers every way a path can fail to reach a `PARALLEL_GATEWAY`: reaching a node with **zero**
outgoing edges (an `:END` node, or any other terminal node), reaching a `node_id` that fails to
resolve (`find_node/2` returns `nil`), or the cycle guard tripping (revisiting a `node_id` already
on this path).

### 2.2 `collect_leaf_gateways/3` — replaces `walk_to_gateway/3`

```
@spec collect_leaf_gateways(Graph.t(), String.t(), MapSet.t(String.t())) ::
        MapSet.t(branch_leaf())
```

Called as `collect_leaf_gateways(definition_snapshot, node_id, visited)`, `visited` starting as
`MapSet.new()` at each branch's own `edge.target` (unchanged call site shape from today's
`walk_to_gateway(definition_snapshot, edge.target, MapSet.new())` in `find_matching_join/2`,
transition.ex:811).

**Traversal, stated precisely (recursive, no implementation code):**

1. **Cycle check.** If `node_id` is a member of `visited`: return `MapSet.new([:dead_end])`.
   (Unchanged semantics from today's cycle guard — a cycle is treated exactly like a dead end, an
   honest "this path never reaches a gateway," not a raised error.)
2. **Node lookup.** Resolve `node_id` via `find_node(definition_snapshot.nodes, node_id)`. If it
   returns `nil`: return `MapSet.new([:dead_end])`.
3. **Gateway terminal.** If the resolved node's `node_type == :PARALLEL_GATEWAY`: return
   `MapSet.new([{:gateway, node.id}])` **immediately, without inspecting this node's own outgoing
   edges at all.** This is the exact same short-circuit `walk_to_gateway/3` already has today
   (transition.ex:845–846), preserved unchanged, and it is the mechanism that bounds this fix's
   scope — see §2.3.
4. **Otherwise, branch by out-degree.** Compute `outgoing_edges = Enum.filter(definition_snapshot.edges,
   &(&1.source == node.id))`.
   - **Zero edges:** return `MapSet.new([:dead_end])` (a terminal non-`:PARALLEL_GATEWAY` node,
     most commonly `:END` — unchanged from today's `_other -> :error` catch-all for this case).
   - **Exactly one edge** `single_edge`: return
     `collect_leaf_gateways(definition_snapshot, single_edge.target, MapSet.put(visited, node.id))`
     unchanged — this is the existing linear chain-following recursion, byte-for-byte the same
     traversal step as today's `[single_edge] -> walk_to_gateway(...)` clause (transition.ex:850–855),
     just now expressed as one case of the general rule rather than the only non-error case.
   - **More than one edge** (the new case — an `:EXCLUSIVE_GATEWAY`, or any other future
     non-`:PARALLEL_GATEWAY` node type with out-degree > 1; a `:PARALLEL_GATEWAY` node can never
     reach this branch of the `case`, since step 3 already returned for it): for **every** edge
     `e` in `outgoing_edges`, independently compute
     `collect_leaf_gateways(definition_snapshot, e.target, MapSet.put(visited, node.id))`, each
     call starting from the **same** `visited` set extended by this node's own id (not shared or
     threaded between sibling edges — see §2.4 on why per-path, not global). Return the **union**
     (`MapSet.union/2`, folded) of all `length(outgoing_edges)` resulting leaf-sets.

The whole function is total (never raises) and terminates: `visited` strictly grows by one element
on every recursive call along any single path, and `definition_snapshot.nodes` is finite, so no
path can recurse past `length(definition_snapshot.nodes)` steps before either resolving to a leaf
or re-hitting a visited node and returning `:dead_end`.

### 2.3 The nested-`PARALLEL_GATEWAY` exclusion boundary (the diagnosis's flagged risk)

Step 3 above — "if this node is itself a `:PARALLEL_GATEWAY`, stop and report it as a leaf,
**without** looking at what lies beyond it" — is unchanged from today's existing short-circuit, and
it is precisely what keeps this fix's broadened traversal from silently matching a **nested**
`PARALLEL_GATEWAY` split/join pair that lies fully inside one branch, ahead of the branch's real
(outer) join:

- The broadening in step 4's third bullet only ever fires for a node whose `node_type` is **not**
  `:PARALLEL_GATEWAY` (step 3 already returned for that case). So a nested `PARALLEL_GATEWAY` split
  node reached via any path is *always* reported as a `{:gateway, nested_split_id}` leaf for that
  path — the traversal never continues past it to see the nested split's own branches, its nested
  join, or whatever lies beyond that nested join.
- Consequence: a branch containing a full nested split→join→continuation sequence will, on the path
  that runs through the nested split, report `{:gateway, nested_split_id}` as that path's leaf — a
  value distinct from the branch's (and the outer split's) real intended join id. §2.5's agreement
  rule below then correctly rejects the branch as a whole with `{:error, :no_matching_join}`,
  **not** a silent false-positive match against the wrong gateway.
- The one case this does *not* newly protect against (because it is not new — it is today's
  existing, already-shipped behavior, unchanged by this fix): a branch that is a **plain single-edge
  chain with no branching at all** which happens to run straight into a nested `PARALLEL_GATEWAY`
  split with no `EXCLUSIVE_GATEWAY` or other branching node anywhere before it. That degenerate
  shape already misreports the nested split's id as "the join" under today's shipped
  `walk_to_gateway/3` (its step-3-equivalent clause, transition.ex:845–846, fires identically with
  zero hops or after a pure single-edge chain), independent of anything this fix changes. This
  design does not touch that pre-existing behavior — see §4 for why it is named as a still-open,
  separate follow-on rather than silently fixed here.

**Scope boundary, stated explicitly per this project's honest-disclosure convention:** this fix
supports a fork branch containing any number of `:EXCLUSIVE_GATEWAY`-shaped (or future
non-`:PARALLEL_GATEWAY`) branching nodes before its join, including branches whose internal paths
reconverge (a diamond shape) before reaching the join. It does **not** support — and does not
change today's behavior for — a branch containing a **nested `PARALLEL_GATEWAY` split** anywhere
along any of its paths. That remains a named open question (§4), not silently resolved either way.

### 2.4 Per-path, not global, `visited` — worked example of why

Consider a branch: `A` (single edge) → `gw` (`:EXCLUSIVE_GATEWAY`, edges to `B` and `C`) → both `B`
and `C` have a single edge to `D` → `D` has a single edge to `join` (`:PARALLEL_GATEWAY`). This is a
legitimate diamond (fork-then-reconverge inside one `PARALLEL_GATEWAY` branch) and must resolve to
`{:ok, "join"}`.

Walking it: `collect_leaf_gateways(g, "A", #{})` → chain to `collect_leaf_gateways(g, "gw", #{"A"})`
→ out-degree 2, so union of:
- `collect_leaf_gateways(g, "B", #{"A", "gw"})` → chain → `collect_leaf_gateways(g, "D", #{"A", "gw", "B"})` → chain → `{:gateway, "join"}`
- `collect_leaf_gateways(g, "C", #{"A", "gw"})` → chain → `collect_leaf_gateways(g, "D", #{"A", "gw", "C"})` → chain → `{:gateway, "join"}`

Both sibling calls pass through `D` — each starting from its **own** copy of `visited` extended only
along its own path (`#{"A","gw","B"}` vs. `#{"A","gw","C"}`). Since `visited` is never shared or
merged between the two sibling recursions, neither call's presence in the other's `visited` set ever
matters — `D` is not "already visited" from either path's own perspective, so no false cycle trip.
The union of the two leaf-sets is `MapSet.new([{:gateway, "join"}])` — a singleton, so §2.5 accepts
it. Had `visited` been threaded globally across sibling edges instead (accumulating `D` after the
first sibling visits it), the second sibling's visit to `D` would incorrectly trip the cycle guard
and produce `:dead_end`, wrongly failing this legitimate diamond shape. This is the exact
distinction ISSUE-FIXER's diagnosis flagged as "a first-class design decision, not an afterthought" —
resolved here as: **`visited` is threaded down each recursive call chain (a path-local
accumulator), and independently duplicated — not shared or unioned — across sibling edges at a
branching node.**

A genuine cycle (a path that loops back on *itself*, e.g. `A → B → A`) is still caught correctly:
`visited` grows along that single path (`#{} → #{"A"} → #{"A","B"}`), and the second visit to `A`
finds it already present in that same path's `visited` set → `:dead_end`.

### 2.5 `find_matching_join/2` — the agreement rule (per-branch, then cross-branch)

```
@spec find_matching_join(Graph.t(), Node.t()) ::
        {:ok, join_node_id :: String.t()} | {:error, :no_matching_join}
```

Two agreement checks now compose, where today there was only one:

**Per-branch (new):** for one split-edge's `edge.target`, call `collect_leaf_gateways(definition_snapshot,
edge.target, MapSet.new())`. Inspect the resulting `MapSet.t(branch_leaf())`:
  - If it is **not** a singleton set, **or** its single element is `:dead_end` (not
    `{:gateway, _}`): this branch is ambiguous or dead-ends on at least one internal path — treat
    it exactly as `walk_to_gateway/3`'s old `:error` return, i.e. the branch as a whole fails to
    resolve to a gateway.
  - If it **is** a singleton set whose element is `{:gateway, gateway_id}`: this branch resolves to
    `gateway_id`, exactly as `walk_to_gateway/3`'s old `{:ok, gateway_id}` return.

  This one rule subsumes several concrete outcomes, all correctly landing on "branch fails to
  resolve": one path inside the branch reaches `:END` while a sibling path (from the same
  `:EXCLUSIVE_GATEWAY`) reaches the real join (mixed `{gateway_id}`/`:dead_end` → not a singleton →
  fail); two sibling paths reach two *different* `PARALLEL_GATEWAY` nodes (two distinct
  `{:gateway, _}` elements → not a singleton → fail); every path dead-ends (singleton
  `#{:dead_end}` → fail, its element is not `{:gateway, _}`). Each of these is a genuine structural
  ambiguity in the graph, not a search defect — the fix's job is to search a bigger subtree
  correctly, not to make genuinely ambiguous shapes resolve.

**Cross-branch (unchanged from today):** `find_matching_join/2`'s outer `Enum.reduce_while` over
the split node's `edges_out` keeps its existing shape — each branch must resolve (per the rule
above) to some `gateway_id`, and every branch's `gateway_id` must be the same value, or the whole
call returns `{:error, :no_matching_join}`. `dispatch_parallel_split/4`'s call site
(transition.ex:772–774, `{:error, :no_matching_join} -> {:error, {:no_matching_join_found, node.id}}`)
is unchanged.

### 2.6 Signature/name note for ELIXIR-DEV

`collect_leaf_gateways/3` is a **replacement** for `walk_to_gateway/3` (same arity, same
positional argument shapes — `Graph.t()`, a `node_id :: String.t()`, a `visited :: MapSet.t(String.t())`
accumulator), not an additional function alongside it; ELIXIR-DEV should rename/replace in place
rather than keep both. The private-function moduledoc comment immediately above it
(transition.ex:830–834, "Follows single-outgoing-edge chains...") must be rewritten to describe the
subtree-union behavior in §2.2–2.3 rather than the old linear-only description, since a stale
comment describing the old narrower behavior would itself become a misleading artifact once the
broadened traversal ships.

## 3. Walkthrough: every existing AC1–AC6 test case, confirmed unaffected

All six AC groups in `test/letflow/engine/parallel_gateway_test.exs` build exclusively on
`three_branch_graph/0` (lines 50–64): a `PARALLEL_GATEWAY` "split" with 3 outgoing edges, **each
edge's target is "join" directly** — a `PARALLEL_GATEWAY` node with zero intermediate hops per
branch, and "join" has one outgoing edge to an `:END` node "e".

For each of the 3 branches, `find_matching_join/2` calls `collect_leaf_gateways(g, "join", MapSet.new())`:
- Step 1 (cycle check): `"join"` not in `MapSet.new()` → continue.
- Step 2 (lookup): resolves to the `"join"` node.
- Step 3 (gateway terminal): `"join"`'s `node_type == :PARALLEL_GATEWAY` → return
  `MapSet.new([{:gateway, "join"}])` immediately. **Step 4 is never reached for this fixture at
  all** — the broadened out-degree branching logic in step 4's third bullet is dead code for every
  existing test case, since none of them contain a non-`:PARALLEL_GATEWAY` branching node anywhere
  in a branch.

Each branch's leaf-set is the singleton `#{{:gateway, "join"}}` → per-branch check passes,
resolving to `"join"`. All 3 branches agree → cross-branch check passes → `{:ok, "join"}`, byte-for-byte
the same result `walk_to_gateway/3` produces today for this fixture. Since `find_matching_join/2`'s
return value, `dispatch_parallel_split/4`'s `JoinCounter` construction, and every downstream
`dispatch_parallel_join/4`/`dispatch_cancel_branch/3` behavior AC1–AC6 assert on are all unchanged
by (and causally downstream of, not upstream of) this fix, every existing assertion in AC1
(3 distinct branch_ids, `JoinCounter` shape), AC2 (wait/fire boundary), AC3 (cancelled-branch
exclusion), AC4 (all-cancelled), AC5 (order-independence/exactly-once), and AC6 (`VariableMerge.merge/3`
reuse) continues to hold unchanged. No AC1–AC6 test needs modification.

## 4. New test case design for ISS-0398's reported scenario

Not implemented here (TEST-DESIGNER's job, WF-03's own later step) — specified precisely enough to
implement without further judgment calls, in the same style as `three_branch_graph/0`.

**Fixture — `branch_with_exclusive_gateway_graph/0`:** a `PARALLEL_GATEWAY` "split" with 2 outgoing
edges:
- Branch 0: `split` → `"join"` directly (mirrors `three_branch_graph/0`'s zero-hop shape, kept as a
  control branch in the same fixture).
- Branch 1: `split` → `"gw"` (an `:EXCLUSIVE_GATEWAY` node, out-degree 2) → two edges, `"gw"` →
  `"route-a"` → `"join"`, and `"gw"` → `"route-b"` → `"join"` (both routes reconverge on the same
  join — the diamond shape from §2.4, and the shape ISS-0398.yaml's own kyc-routing scenario has:
  a multi-edge `:EXCLUSIVE_GATEWAY` whose edges all eventually reach the same `PARALLEL_GATEWAY`).
- `"join"` (`:PARALLEL_GATEWAY`) → single edge → `"e"` (`:END`), same as `three_branch_graph/0`.

**Assertions (new `describe` block, mirroring AC1's shape):**
1. `Transition.transition(g, state, {:advance_token, initial_token_id})` on this fixture returns
   `{:ok, new_state, [{:parallel_split, ^initial_token_id, "split", branch_ids}]}` — i.e. it
   **succeeds** where today's shipped code returns `{:error, {:no_matching_join_found, "split"}}`.
   This is the core regression assertion for ISS-0398 itself.
2. `length(branch_ids) == 2`, and `new_state.join_counters["join"]` is a `%JoinCounter{}` whose
   `expected_from_branches == MapSet.new(branch_ids)` — the join cohort is registered against the
   correct (outer, real) `"join"` node id, not against `"gw"` (which is not a `:PARALLEL_GATEWAY`
   and so is never a candidate leaf at all) or any other node.
3. Branch 1's new token lands on `"gw"` (`Enum.map(new_state.tokens, & &1.node_id)` includes
   `"gw"` for that branch) — confirms the split itself still only advances each branch one hop to
   its own `edge.target`, unchanged from today; `find_matching_join/2`'s deeper subtree search is a
   pure lookahead and never advances any token itself.

**Negative case — same `describe` block, a second test, `ambiguous_branch_dead_ends_graph/0`:** a
`PARALLEL_GATEWAY` "split" with one branch identical to Branch 1 above, except `"route-b"`'s edge
targets an `:END` node `"e2"` instead of `"join"` (one of the `:EXCLUSIVE_GATEWAY`'s two paths
dead-ends, the other reaches the real join). Assert
`Transition.transition(g, state, {:advance_token, initial_token_id})` still returns
`{:error, {:no_matching_join_found, "split"}}` — confirms the per-branch singleton-leaf-set rule
(§2.5) correctly still rejects a branch with an internally ambiguous/dead-ending path, rather than
the broadened search over-eagerly accepting any branch containing at least one path to the right
gateway.

## 5. Open question §12.4 revisited — is an upstream structural `CHK-*` rule also needed?

ISSUE-FIXER's diagnosis flagged this for CODE-DESIGNER's judgment (its own `result.issues[0]`).
Resolved here, not deferred further: **no**, not as part of this fix. `find_matching_join/2`
already fails total and honest — `{:error, {:no_matching_join_found, node.id}}` surfaced through
`Engine.create/2` as `{:error, {:activation_failed, {:no_matching_join_found, split_node_id}}}` — for
every graph shape this fix still cannot resolve (a branch with a genuinely ambiguous or dead-ending
internal path, or one containing a nested `PARALLEL_GATEWAY`, §2.3). That error is actionable (it
names the offending split node) even without a dedicated `CHK-*` structural-validator rule catching
it earlier at `create/1` definition-validation time (REQ-030). Adding such a `CHK-*` rule would
require the structural validator to re-implement a graph-shape analysis materially similar to
`collect_leaf_gateways/3` itself, at a different layer, for a purely cosmetic error-timing
improvement (definition-validation time vs. instance-creation time) — not required by ISS-0398's
own acceptance criteria, which are about the *EXCLUSIVE_GATEWAY-in-branch* shape now succeeding, not
about earlier error surfacing for shapes that still fail. Left as a genuinely open, low-priority
"could consider later" item, not a blocking requirement of this fix.

## 6. Scope boundary and required follow-up issue (explicit, not silently dropped)

**In scope for this fix, and fully resolved by §2:** a `PARALLEL_GATEWAY` fork branch containing
any number of non-`PARALLEL_GATEWAY` branching nodes (`:EXCLUSIVE_GATEWAY` today; any future
non-parallel branching node type by the same mechanism, since step 4's broadening is keyed only off
"not a `:PARALLEL_GATEWAY`," not off `:EXCLUSIVE_GATEWAY` specifically) before reaching its join,
including branches whose internal paths reconverge before the join (§2.4's diamond shape).

**Out of scope, genuinely unsupported after this fix ships, named explicitly per this project's
honest-disclosure convention (the same one REQ-206/207/208's own designs use):** a `PARALLEL_GATEWAY`
fork branch containing a **nested `PARALLEL_GATEWAY` split** anywhere along any of its internal
paths, ahead of the branch's real (outer) join. §2.3 explains precisely why: the traversal treats
any `PARALLEL_GATEWAY` node as an immediate terminal leaf and never looks past it, so a nested
split's presence either produces a `{:gateway, nested_split_id}` vs. `{:gateway, outer_join_id}`
disagreement (correctly, safely erroring with `{:error, :no_matching_join}`) or — in the narrow,
already-pre-existing degenerate case of a branch that is a bare single-edge chain straight into the
nested split with no other branching anywhere before it — silently misattributes the nested split as
the branch's join, exactly as today's shipped code already does, unchanged by this fix either way.

**Required action, per ISSUE-FIXER's diagnosis and confirmed here via a fresh
`grep -li` over `docs/issues/*.yaml` for `nested.*parallel|block-structured|internal.*branch`
(no hits):** no existing issue tracks this nested-`PARALLEL_GATEWAY`-within-a-branch gap. ORCH must
file a new issue for it at this run's Step Final (WF-03), distinct from ISS-0398 (which this design
fully resolves) — referencing this document's §2.3/§6 and REQ-051 §12.4 as the design-time
open-question ancestry, tagged `engine`, `parallel-gateway`, `fork-join` like ISS-0398 itself, and
explicitly scoped as "nested `PARALLEL_GATEWAY` split fully or partially contained within a fork
branch, ahead of that branch's own join" so a future ISSUE-FIXER/CODE-DESIGNER pass does not have to
rediscover this analysis from scratch.
