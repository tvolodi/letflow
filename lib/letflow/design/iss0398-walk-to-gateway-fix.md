# Design: ISS-0398 — `walk_to_gateway/3` fails a fork branch containing a
# non-`PARALLEL_GATEWAY` branching node before reaching its join

**Issue:** ISS-0398 (`docs/issues/ISS-0398.yaml`), severity MAJOR, discovered in `WF02-REQ208-20260901`
**Requirement of origin:** REQ-051 (`lib/letflow/design/req051-parallel-gateway-split-join.md`, §3.3, §12.4)
**Owner (implementer):** ELIXIR-DEV
**Owned module:** `lib/letflow/engine/transition.ex` (`find_matching_join/2`, `walk_to_gateway/3`, both
private functions inside `Letflow.Engine.Transition`)
**This document produces:** a replacement traversal for `walk_to_gateway/3` — a memoized-DFS
reachability search over `definition_snapshot.edges`, `node_id`-keyed — and the exact agreement rule
`find_matching_join/2` applies to its result. Signatures, `@spec`/`@type` shapes, and a precise
prose/pseudocode algorithm only. No implementation code, no `defmodule`/`defstruct`, no function
bodies in code fences — matches this project's design-gate convention (REQ-206/207/208's own
validated designs).

**Iteration 2:** SECURITY-REVIEWER FAILED iteration 1's design/implementation at
`WF03-ISS0398-20260901` Step 3c on a BLOCKER INV-8 finding
(`handoffs/WF03-ISS0398-20260901/step-03c-security-reviewer.json`) — iteration 1's
`collect_leaf_gateways/3` recursed into every outgoing edge of a branching node with a
per-path-**copied** (not memoized) `visited` set, making total call count exponential (`O(2^k)` for
a chain of `k` reconverging `:EXCLUSIVE_GATEWAY` diamonds) rather than the intended bound on
recursion *depth* the iteration-1 termination argument actually proved. That revision replaced the
per-path-copy scheme with a `node_id`-keyed memoized DFS, bounding total work to `O(nodes + edges)`.

**Iteration 3 (this revision):** CODE-DESIGN-VALIDATOR FAILED iteration 2's design at Step 2b
recheck 1 (`handoffs/WF03-ISS0398-20260901/step-02b-code-design-validator-recheck1.json`) on a
second, distinct BLOCKER — a **correctness** defect in the memoization scheme itself, not a
performance one. Iteration 2's §2.2.1 claimed a plain `node_id`-keyed memo is "context-free" because
`on_path` (live-ancestor cycle detection) and `memo` (finished results) were kept separate. The
validator constructed a concrete, `CHK-01..CHK-19`-legal counterexample — a cycle through a gateway
node that CHK-06 explicitly permits (`graph.ex:552-556, 644-661`) where the cycle's own branching
node (`B`) also has an escape edge out of the cycle — and showed that `memo["GW"]` takes two
*different* values depending on which of two sibling branches sharing `memo` is evaluated first,
directly falsifying the "context-free by construction" claim. Root cause, now understood precisely
(§2.2.1): a node's forward-reachable-leaf-gateway set is genuinely **not** a pure function of
`node_id` alone when the node lies on a cycle with internal branching, because plain DFS cycle
detection makes a back-edge "close" at whichever node of the cycle happens to be the *first*
repeated node on the *current* call chain — and that node differs depending on which cycle member
was the entry point. Fixing this for real (not patching around the one counterexample) requires
memoizing at the granularity of the node's whole **strongly connected component (SCC)**, computed
via a Tarjan-style single-pass DFS augmented to accumulate each SCC's aggregate escape-leaf set as
it closes, so every member of a cycle shares one jointly-computed, provably order-independent value.
This revision replaces §2.2's plain node-keyed memoized DFS with this SCC-aware version, corrects
§2.2.1's soundness proof (this time via the SCC-closure invariant, not an unproven ancestry
disclaimer), adds §2.4b tracing the validator's exact counterexample under both evaluation orders,
and adds two new regression fixtures (§4) for this defect class specifically. §2.1, §2.3, §5, and §6
carry forward unchanged in substance (re-confirmed, not merely re-asserted, in each section below);
§2.5 and §2.6 are updated only for the new state shape.

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
- `handoffs/WF03-ISS0398-20260901/step-02b-code-design-validator-recheck1.json` (full) — the
  BLOCKER memo-key-unsoundness finding this revision exists to fix, including the exact
  counterexample graph traced in §2.4b below.
- `lib/letflow/definitions/graph.ex` lines 552-556 and 644-661 (`check_cycles/1`, `dfs_visit/6`),
  read directly for this revision to confirm CHK-06's rule precisely: a cycle is permitted iff at
  least one endpoint of its closing back-edge is a gateway-typed node (`build_gateway_set/1`); the
  validator's counterexample graph satisfies this with room to spare — both endpoints of the closing
  back-edge `B → GW` (`B` and `GW`, both `:EXCLUSIVE_GATEWAY`) are gateway-typed, though the rule
  only requires one.

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

### 2.2 `collect_leaf_gateways/3` — replaces `walk_to_gateway/3` (memoized Tarjan-SCC DFS)

**Rework note (iteration 3, this revision):** iteration 2 specified a plain `node_id`-keyed
memoized DFS, separating "currently in progress" (`on_path`) from "finished" (`memo`) state.
CODE-DESIGN-VALIDATOR (`handoffs/WF03-ISS0398-20260901/step-02b-code-design-validator-recheck1.json`,
BLOCKER) showed this is unsound whenever the traversal's forward-reachable subgraph contains a
cycle through a gateway node whose branching node also has an escape edge out of the cycle — a
shape `graph.ex`'s CHK-06 explicitly permits. §2.2.1 below explains precisely why plain
node-keyed memoization cannot be made sound for this shape (not just "was buggy this once"), then
gives the corrected construction: compute the traversal's **strongly connected components (SCCs)**
via a single Tarjan-style DFS pass, and memoize the *aggregate escape-leaf set* once per SCC — every
node in a cycle shares one jointly-computed value, finalized only once every node reachable back
into that cycle has been explored, regardless of which member was the entry point. §2.2.2 gives the
traversal; §2.2.3 gives the termination/complexity argument (still `O(nodes + edges)` — Tarjan's
algorithm is linear); §2.4/§2.4a re-confirm the (unaffected, acyclic) diamond and diamond-chain
examples; §2.4b traces the validator's exact counterexample under both evaluation orders.

#### 2.2.1 Why plain `node_id`-keyed memoization is unsound, and why SCC-keyed memoization fixes it

**The question, restated honestly:** can two different callers reach the same `node_id` via
different ancestor paths and legitimately get *different* leaf-gateway sets back? Iteration 2
answered "no" by arguing the forward-reachable question is "a static property of the graph and
`node_id`," with ancestry only mattering for live cycle detection (`on_path`), which it claimed was
kept safely separate from `memo`. **This proof was false, and the falseness is specific and
mechanical, not a vague gap:** plain DFS cycle detection declares a back-edge "closed" at whichever
node of a cycle happens to be the *first* repeated node on the *current* call chain — and if a cycle
member (`B` in the counterexample) has its own extra out-edge *inside* the cycle (`B`'s edges are
`B → GW`, closing the cycle, and `B → D`, escaping it), then which node the cycle "closes at" (and
therefore which node's own out-degree fold gets to see `B`'s escape edge as part of *its own*
subtree) genuinely depends on which cycle member was entered first:

- Entered via a node outside the cycle (or via `GW` itself): the DFS reaches `B` as a *fresh* node
  partway through `GW`'s own subtree, so `B`'s escape edge (`B → D → JOIN`) is folded into `GW`'s own
  computation, and `GW`'s finished value includes it.
- Entered directly at `B`: the DFS immediately marks `B` as on-path, and the chain `B → GW → C → B`
  closes the cycle back onto `B` itself — at the point of re-encountering `B`, the traversal never
  gets to reconsider `B`'s *other* edge (`B → D`) a second time, because `B`'s own out-degree fold
  already happened once, at the top of this exact call.

Iteration 2's node-keyed memo tried to cache "the value of `GW`" and "the value of `B`" as two
independent, separately-finalized quantities — but they are not independent: they are both facets
of one indivisible unit (the cycle `{GW, C, B}`), and a per-node memo entry can only ever capture
whichever partial view the *first* DFS to visit that specific node happened to see. No reordering of
steps *within* the node-keyed scheme fixes this, because the defect is in the unit of memoization
itself, not in the bookkeeping around it.

**The fix: memoize per strongly connected component, not per node.** An SCC is a maximal set of
nodes each reachable from every other — a purely structural graph property, independent of any DFS
starting point (this is a standard graph-theory fact, not asserted without basis: Tarjan's and
Kosaraju's algorithms both compute the *same* SCC partition regardless of which node a DFS starts
from or which order a node's edges are visited in). This design computes SCCs via a single-pass
Tarjan-style DFS (index/lowlink/stack, §2.2.2) and, at the moment an SCC closes, memoizes **one**
aggregate escape-leaf value shared by every member of that SCC — computed as the union of every leaf
contribution found on *any* edge leaving *any* node in the SCC, whether that edge goes to a
terminal (`:PARALLEL_GATEWAY`, `:END`/unresolved) or to another already-finished SCC. A back-edge
from one SCC member to another SCC member (the cycle's own internal edges, including the one that
originally revealed the cycle) contributes **no leaf at all** — not even `:dead_end` — because it is
not evidence of a dead end; it is evidence of "no new information from this specific edge," and the
real informational content of the SCC (its escape edges) is captured by whichever *other* edges its
members have. This is also a semantic correction, not only an order-independence one: iteration 2's
per-edge `:dead_end` contribution from a live cycle back-edge (§2.2.2 step 2, this revision) made
`B`'s own node-keyed value a spurious *two*-element ambiguous set (`#{:dead_end, {:gateway,
"JOIN"}}`) even in the single evaluation order iteration 2's own worked trace used — §2.4b shows
the SCC-level computation instead yields the correct singleton `#{{:gateway, "JOIN"}}` for `GW`,
`C`, and `B` alike, in *both* orders, because Tarjan never closes (and therefore never memoizes) an
SCC until every node reachable back into it has been explored — so the aggregate value written to
`memo` is always the *complete* union of every escape edge in the component, never a partial view
that happened to be visible from one particular entry point.

`on_path` (iteration 1/2's live-ancestor cycle-detection set) is retained in substance, but folded
into Tarjan's `stack`/`stack_set` bookkeeping (§2.2.2) rather than kept as a bare `MapSet` — a node
still on the stack is exactly "currently in progress on this call chain," the same role `on_path`
played before; the difference is that a hit against it now also reports the ancestor's `index` so
the caller can update its own `lowlink`, which is what lets the SCC-closure decision (`lowlink ==
index`) fire correctly regardless of entry point.

#### 2.2.2 Traversal, stated precisely (Tarjan-style DFS, no implementation code)

```
@type leaf_search_state :: %{
        memo: %{optional(String.t()) => MapSet.t(branch_leaf())},
        index: %{optional(String.t()) => non_neg_integer()},
        lowlink: %{optional(String.t()) => non_neg_integer()},
        stack: [String.t()],
        stack_set: MapSet.t(String.t()),
        next_index: non_neg_integer()
      }

@type leaf_search_result :: :finished | {:open, lowlink :: non_neg_integer()}

@spec collect_leaf_gateways(Graph.t(), node_id :: String.t(), leaf_search_state()) ::
        {leaf_search_result(), MapSet.t(branch_leaf()), leaf_search_state()}
```

`memo` is the only field threaded **across** sibling top-level branch calls (§2.5) — `index`,
`lowlink`, `stack`, and `stack_set` reset to empty/`0` at the start of every top-level branch call
(exactly as `on_path` reset to `MapSet.new()` per branch in iteration 1/2), because §2.2.3 proves a
top-level call's own stack is always fully unwound (every SCC it opens, it also closes) by the time
it returns — there is never a dangling "still open" node left behind for the next branch to
inherit, so only the finished-value cache (`memo`) needs to survive between branches.

Called as `collect_leaf_gateways(definition_snapshot, node_id, state)`, returning
`{result_kind, leaves, state'}`. Every call — top-level (§2.5) or recursive — runs the *same* five
steps, in this order:

1. **Memo hit.** If `node_id ∈ state.memo`: return `{:finished, state.memo[node_id], state}`
   unchanged — O(1), no recursion, no stack interaction. A memo hit means this node's SCC has
   already fully closed; its value can never change again.
2. **On-stack (live back-edge).** Else, if `node_id ∈ state.stack_set`: this is a genuine
   still-in-progress ancestor on *this* call chain. Return `{{:open, state.index[node_id]},
   MapSet.new(), state}` — **`leaves` is the empty set, not `:dead_end`** (§2.2.1's semantic
   correction: a live back-edge contributes no new leaf, only a lowlink signal for the caller to
   fold in). No `stack`/`index`/`lowlink` mutation — `node_id`'s own call frame, further up the
   stack, owns that bookkeeping and hasn't returned yet.
3. **Node lookup fails.** Else, resolve `node_id` via `find_node(definition_snapshot.nodes,
   node_id)`. If `nil`: this is a genuine terminal (no cycle involved), so it closes as its own
   trivial one-member SCC immediately: `leaves = MapSet.new([:dead_end])`, `memo' =
   Map.put(state.memo, node_id, leaves)`, return `{:finished, leaves, %{state | memo: memo'}}`.
4. **Gateway terminal.** Else, if the resolved node's `node_type == :PARALLEL_GATEWAY`: same
   immediate-terminal treatment as iteration 1/2 (transition.ex:859-860 today) — `leaves =
   MapSet.new([{:gateway, node_id}])`, `memo' = Map.put(state.memo, node_id, leaves)`, return
   `{:finished, leaves, %{state | memo: memo'}}`. A `:PARALLEL_GATEWAY` node is never pushed onto
   `stack` (it returns here, before step 5's push), so it can never itself be the target of an
   in-progress back-edge — unaffected by, and irrelevant to, the SCC machinery below (§2.3
   re-confirms this boundary is unchanged).
5. **Otherwise (real branching/chaining node).** Assign `index[node_id] = lowlink[node_id] =
   state.next_index`, increment `next_index`, push `node_id` onto `stack`/`stack_set`. Compute
   `outgoing_edges = Enum.filter(definition_snapshot.edges, &(&1.source == node_id))`,
   `next_on_path = MapSet.put(...)` is no longer needed as a separate value — ancestry is now
   carried entirely by `stack_set`. Starting `local_leaves = MapSet.new()` and `local_lowlink =
   index[node_id]`:
   - **Zero edges:** a true terminal (`:END`-shaped dead end, no cycle involved) —
     `local_leaves = MapSet.new([:dead_end])`; `local_lowlink` stays `index[node_id]` (an
     edge-less node can never be part of a larger SCC). Proceed to the closure check below.
   - **One or more edges:** fold sequentially over `outgoing_edges`, threading `state` from one
     edge to the next (`Enum.reduce`, not an independent `Enum.map`): for each edge to `target`,
     recurse `{tag, edge_leaves, state} = collect_leaf_gateways(definition_snapshot, target,
     state)` (this recursive call transparently runs steps 1–5 again for `target`, so it is the
     *same* function that handles "target is a memo hit," "target is on-stack," and "target is
     fresh"):
     - If `tag == :finished`: `local_leaves = MapSet.union(local_leaves, edge_leaves)`;
       `local_lowlink` unchanged (a finished child's SCC is fully self-contained and can never
       loop back into an ancestor of the current node).
     - If `tag == {:open, child_lowlink}`: `local_leaves = MapSet.union(local_leaves,
       edge_leaves)` (this is either the empty set, if `edge_leaves` came from a direct step-2
       back-edge, or a nonempty partial aggregate already bubbled up from a nested still-open SCC
       member — either way, safe to fold in now); `local_lowlink = min(local_lowlink,
       child_lowlink)` — this is the propagation step that lets an SCC's closure decision below
       "see" a back-edge discovered several calls deeper in the stack.
   - **Closure check.** After all edges are processed: if `local_lowlink == index[node_id]`,
     `node_id` is its SCC's root. Pop `stack` (and remove from `stack_set`) down through and
     including `node_id`; for **every** popped member `m`, write `memo[m] = local_leaves` — the
     *same* final aggregate for every member, which is the property that makes this scheme
     genuinely order-independent (§2.2.1). Return `{:finished, local_leaves, state'}` with the
     updated `memo`/`stack`/`stack_set`. Else (`local_lowlink < index[node_id]`), `node_id` is part
     of a larger SCC still being discovered further up the call chain: leave it on `stack`, do not
     write `memo` yet, and return `{{:open, local_lowlink}, local_leaves, state}`.

#### 2.2.3 Totality, termination, and the complexity argument

**Total** (never raises): every step returns a value; steps 1–5 are exhaustive and mutually
exclusive per call (a node_id is in exactly one of: memo, on-stack, unresolvable, a
`:PARALLEL_GATEWAY`, or "otherwise"). **Terminates:** `state.stack` strictly grows by at most one
element per fresh (step-5) call, `definition_snapshot.nodes` is finite, and steps 1–4 never
recurse — so no call chain can make more fresh (step-5) calls than `length(definition_snapshot.nodes)`
before every node on the current chain is either finished, on-stack, or a terminal.

**Every top-level branch call's stack is always fully unwound by the time it returns (the property
that justifies resetting `index`/`lowlink`/`stack`/`stack_set` to empty per branch while keeping
`memo`):** a root call's `node_id` is assigned `index = 0` relative to that call's own fresh
numbering (`next_index` restarts at `0` for every top-level branch, which is safe because index
values are only ever compared *within* one top-level call — no step above compares an `index` or
`lowlink` value that originated from a different top-level call). Every back-edge encountered during
this call can only reference an ancestor that is on *this* call's own `stack`, so `local_lowlink` at
the root can never be pushed below `0` — its floor is exactly the root's own index. Therefore the
root's closure check (`local_lowlink == index[node_id]`) is **always** satisfied once its own fold
completes (whether or not it absorbed any cycles along the way), so the root's own SCC always
closes and the stack always returns to empty. No top-level branch can ever leave a node "open" for
the next branch to inherit.

**Complexity bound:** this is a standard Tarjan SCC traversal, linear by construction. `index` is
assigned at most once per distinct `node_id` per top-level call, but — by the memo-hit short-circuit
(step 1) — a node whose SCC has already closed under an *earlier* top-level branch's call is never
re-visited (not even to re-assign an index) by any later branch; it is an O(1) memo hit instead.
Summing across the whole sequence of a split node's sibling branches (§2.5's shared-memo
threading): at most `length(definition_snapshot.nodes)` fresh (step-5) explorations total, each
inspecting exactly its own outgoing edges once (`Enum.filter(definition_snapshot.edges,
&(&1.source == node_id))`), so the sum of edges inspected is at most `length(definition_snapshot.edges)`;
every stack push/pop happens at most once per node; every memo hit and on-stack check is O(1) plus a
bounded `Map`/`MapSet` lookup. Total work is therefore `O(nodes + edges)` — polynomial, not
exponential — identical asymptotic bound to iteration 2, so this revision does not regress
SECURITY-REVIEWER's INV-8 finding while fixing the new correctness defect. §2.4a re-confirms this
concretely for the `k = 3` diamond chain (unaffected, since it is acyclic); §2.4b traces the
validator's cyclic counterexample.

### 2.3 The nested-`PARALLEL_GATEWAY` exclusion boundary (the diagnosis's flagged risk)

**No knock-on effect from the memoization rework:** this section's boundary is about *which node
types the traversal treats as terminal*, orthogonal to *how many times a node gets computed*. Step
4 of §2.2.2 (renumbered from iteration 1's step 3, same rule) — "if this node is itself a
`:PARALLEL_GATEWAY`, stop and report it as a leaf, **without** looking at what lies beyond it" — is
completely unchanged in substance, and now additionally gets cached (§2.2.2 step 4: the result is
written to `memo` the first time any path reaches that gateway) — caching a terminal decision does
not alter what the decision is. It is precisely what keeps this fix's broadened traversal from
silently matching a **nested** `PARALLEL_GATEWAY` split/join pair that lies fully inside one branch,
ahead of the branch's real (outer) join:

- The broadening in step 5's third bullet only ever fires for a node whose `node_type` is **not**
  `:PARALLEL_GATEWAY` (step 4 already returned for that case). So a nested `PARALLEL_GATEWAY` split
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

### 2.4 Per-path stack, cross-path `memo` — worked example of why both are needed

**Carried forward from iteration 2, re-confirmed unaffected by this revision:** this example is
purely acyclic (paths reconverge but never loop back to an ancestor), so no back-edge (step 2) ever
fires, every node closes as its own trivial one-member SCC (`local_lowlink == index[node_id]`
always holds — nothing ever lowers it), and the trace below is byte-for-byte the sequence of
`:finished` returns iteration 2 described, just re-expressed in this revision's `{tag, leaves,
state}` shape. This is exactly the case the §2.2.1 defect does **not** touch — the defect is
specific to cycles with internal branching, and an acyclic diamond has neither.

Consider a branch: `A` (single edge) → `gw` (`:EXCLUSIVE_GATEWAY`, edges to `B` and `C`) → both `B`
and `C` have a single edge to `D` → `D` has a single edge to `join` (`:PARALLEL_GATEWAY`). This is a
legitimate diamond (fork-then-reconverge inside one `PARALLEL_GATEWAY` branch) and must resolve to
`{:ok, "join"}`.

Walking it: `collect_leaf_gateways(g, "A", state_0)` (fresh state, `memo = %{}`) assigns
`index["A"] = 0`, pushes `"A"`, chains to `collect_leaf_gateways(g, "gw", state_1)` (`index["gw"] =
1`, pushed) → out-degree 2, fold sequentially, threading `state`:
- Edge to `B`: `index["B"] = 2`, pushed → chain to `collect_leaf_gateways(g, "D", state)`
  (`index["D"] = 3`, pushed) → chain to `collect_leaf_gateways(g, "join", state)` → gateway
  terminal (step 4) → `{:finished, #{{:gateway,"join"}}, state}` with `memo["join"]` written
  immediately. Back in `"D"`: `local_leaves = #{{:gateway,"join"}}`, `local_lowlink = index["D"] =
  3` (unchanged — the child was `:finished`, no lowlink propagation) → closure check passes
  (`3 == 3`) → pop `"D"`, `memo["D"] = #{{:gateway,"join"}}`, return `:finished`. Back in `"B"`:
  same reasoning → `local_lowlink = index["B"] = 2` → closes → `memo["B"] = #{{:gateway,"join"}}`,
  return `:finished`.
- Edge to `C`, now called with `state` carrying `memo = %{"join" => ..., "D" => ..., "B" => ...}`:
  `index["C"] = 4`, pushed → chain to `collect_leaf_gateways(g, "D", state)` — **step 1 fires:
  `"D"` is already in `memo`** → `{:finished, #{{:gateway,"join"}}, state}` immediately, **without
  recursing into `join` a second time**, and without touching `stack`/`index`/`lowlink` for `"D"`
  at all (it is finished, not on-stack). Back in `"C"`: `local_lowlink = index["C"] = 4` (a
  `:finished` child never lowers it) → closes → `memo["C"] = #{{:gateway,"join"}}`.

Both `"B"`'s and `"C"`'s own SCCs (each a trivial singleton) close independently the moment their
own fold finishes — no back-edge ever pulled either of them into a shared, still-open component, so
the memo hit on `"D"` is a pure performance win here, not a correctness requirement, exactly as
iteration 2 described. Back in `"gw"`: `local_leaves = union(#{{:gateway,"join"}},
#{{:gateway,"join"}}) = #{{:gateway,"join"}}`, `local_lowlink = index["gw"] = 1` → closes →
`memo["gw"] = #{{:gateway,"join"}}`. Back in `"A"`: closes trivially, `memo["A"] =
#{{:gateway,"join"}}`. The union of the two branch-leaf-sets that `find_matching_join/2` inspects is
`MapSet.new([{:gateway, "join"}])` — a singleton, so §2.5 accepts it, byte-for-byte the same outcome
as iteration 1's unmemoized version and iteration 2's node-keyed version — this revision changes
*how* the memo is keyed and *when* it is safe to write, never the result for an acyclic shape.

§2.4b (new in this revision) traces a genuine cycle through a branching gateway node — the shape
iteration 2's proof got wrong — showing the SCC-closure mechanism resolves it correctly and
identically regardless of entry order.

### 2.4a Diamond-chain adversarial case (SECURITY-REVIEWER's example) — traced for `k = 3`

**Re-confirmed unaffected by this revision:** every edge in this structure points strictly
"forward" in the chain (`gw_i → b_i/c_i → gw_{i+1}`, never backward), so no back-edge ever fires,
every node's SCC is itself alone, and `local_lowlink` never drops below each node's own `index` —
the trace below is identical in substance to iteration 2's, just running through this revision's
`{tag, leaves, state}` return shape and Tarjan bookkeeping instead of the old `on_path`/plain-memo
shape. Complexity conclusion is unchanged: `O(k)` fresh (step-5) explorations, `O(1)` per memo hit.

Structure (matching SECURITY-REVIEWER's ~3-nodes-plus-4-edges-per-stage description, well inside
`@max_nodes 500`/`@max_edges 2000`): a chain of `k` `:EXCLUSIVE_GATEWAY` diamonds, each one's
reconvergence node *is* the next diamond's own gateway, ending in a real `:PARALLEL_GATEWAY` join:

```
gw1 --> b1 --> gw2 --> b2 --> gw3 --> b3 --> join (:PARALLEL_GATEWAY)
gw1 --> c1 --> gw2 --> c2 --> gw3 --> c3 --> join
```

(`gw1`, `gw2`, `gw3` are `:EXCLUSIVE_GATEWAY`, each with 2 outgoing edges; `join` is the branch's
real `:PARALLEL_GATEWAY`.) This is exactly SECURITY-REVIEWER's construction with `k = 3`, and it is
structurally valid under CHK-01..CHK-19 for the same reasons the handoff gives: `join`-of-one-diamond
== `gw`-of-the-next is legal (CHK-04 only requires ≥1 in/out edge per non-terminal node, no cap on
in-degree), the graph stays acyclic (each edge points strictly "forward" in the chain, so CHK-06
never fires), and `:EXCLUSIVE_GATEWAY` edges can carry whatever conditions the tenant likes (CHK-13).

**Under iteration 1's unmemoized per-path-copy scheme:** `collect_leaf_gateways(gw1)` forks into 2
independent calls to `gw2` (via `b1` and `c1`), each of which independently forks into 2 calls to
`gw3` (4 total), each of which independently forks into 2 calls to `join` (8 total) — `2^3 = 8` leaf
calls for `k = 3`; SECURITY-REVIEWER's point is this is `2^k`, so `2^40 ≈ 10^12` for a 40-diamond
chain comfortably inside the node/edge caps.

**Under this revision's SCC-aware scheme, traced call-by-call:** top-level call
`collect_leaf_gateways(g, "gw1", state_0)` (fresh state, `memo = %{}`):

1. `gw1` fresh (`index = 0`, pushed) → out-degree 2, process edge to `b1` first:
   - `b1` fresh (`index = 1`, pushed, single edge) → recurse into `gw2`.
   - `gw2` fresh (`index = 2`, pushed, out-degree 2) → process edge to `b2` first:
     - `b2` fresh (`index = 3`, pushed, single edge) → recurse into `gw3`.
     - `gw3` fresh (`index = 4`, pushed, out-degree 2) → process edge to `b3` first: `b3` fresh
       (`index = 5`, pushed, single edge) → recurse into `join`; `join` is a `:PARALLEL_GATEWAY`
       (step 4) → **immediate terminal**, `leaves = #{{:gateway,"join"}}`, `memo["join"]` written
       immediately, no stack push for `join` at all. `b3`'s own fold sees a `:finished` child →
       `local_lowlink` stays `5` → closes → `memo["b3"] = #{{:gateway,"join"}}`.
     - Edge to `c3`, called with the **updated** state (`memo` now has `join`, `b3`): `c3` fresh
       (`index = 6`, pushed, single edge) → recurse into `join` — **step-1 memo hit**, O(1), no
       further recursion, no stack interaction for `join`. `c3` closes → `memo["c3"] =
       #{{:gateway,"join"}}`. `gw3`'s own fold (both children `:finished`) closes →
       `memo["gw3"] = #{{:gateway,"join"}}` (union of `b3`'s and `c3`'s, both singletons).
   - Edge to `c2`, called with the updated state (`memo` now also has `gw3`, `b3`, `c3`): `c2`
     fresh (`index = 7`, pushed, single edge) → recurse into `gw3` — **memo hit**, O(1). `c2`
     closes → `memo["c2"] = #{{:gateway,"join"}}`. `gw2`'s own fold closes →
     `memo["gw2"] = #{{:gateway,"join"}}`.
2. Edge to `c1`, called with the updated state (`memo` now also has `gw2`, `b2`): `c1` fresh
   (`index = 8`, pushed, single edge) → recurse into `gw2` — **memo hit**, O(1). `c1` closes →
   `memo["c1"] = #{{:gateway,"join"}}`. `gw1`'s own fold closes → `memo["gw1"] =
   #{{:gateway,"join"}}`.

No back-edge ever fires in this structure (every edge points strictly forward, §2.4a's opening
note), so every node's SCC is itself alone and every closure check passes trivially the first time
each node's own fold finishes — the trace above never leaves any node in the `{:open, _}` state.

**Fresh (step-5/step-4) computations total: 10** (`gw1, b1, gw2, b2, gw3, b3, join, c3, c2, c1` —
every one of the 10 distinct node ids in the graph, computed exactly once) — **not** `2^3 = 8`
leaf-level calls compounding into `2^k` growth; for general `k`, fresh computations total `3k + 1`
(three nodes per diamond stage plus the final join), i.e. `O(k)`, and every non-fresh reference (one
per `c_i` edge, `k` of them) is an O(1) memo hit. For `k = 40`: `121` fresh computations plus `40`
O(1) memo hits — nowhere near `2^40`. Each branch's final leaf-set is still the singleton
`#{{:gateway, "join"}}` (identical to what the unmemoized version would eventually compute, just
without the redundant work), so §2.5's per-branch/cross-branch agreement rule still resolves this
branch correctly to `"join"` — this revision's SCC bookkeeping changes performance and correctness
for the *cyclic* case (§2.4b), never the functional outcome for this acyclic adversarial case,
exactly as for the plain diamond in §2.4.

### 2.4b Cyclic-escape counterexample (CODE-DESIGN-VALIDATOR's example) — traced under both entry orders

This is the exact construction from `handoffs/WF03-ISS0398-20260901/step-02b-code-design-validator-recheck1.json`
that falsified iteration 2's soundness proof. Structure: `X` (single edge) → `GW`
(`:EXCLUSIVE_GATEWAY`, single edge) → `C` (single edge) → `B` (`:EXCLUSIVE_GATEWAY`, out-degree 2:
`B → GW`, closing the cycle `GW → C → B → GW`, legal per CHK-06 since both `B` and `GW` are
gateway-typed; and `B → D`, escaping the cycle) → `D` (single edge) → `JOIN`
(`:PARALLEL_GATEWAY`) → `e` (`:END`). A `PARALLEL_GATEWAY` split has two branches: branch 1 enters
at `X` (reaching the cycle from outside), branch 2 enters directly at `B` (a member of the cycle
itself). Both branches must resolve to the same answer (`{:gateway, "JOIN"}`) for
`find_matching_join/2` to return `{:ok, "JOIN"}` — this is the actual regression scenario ISS-0398's
kyc-routing shape generalizes to, and the cyclic variant of it specifically (`docs/issues/ISS-0398.yaml`
itself has no cycle, but §2.3/§6's scope statement commits this fix to handling *any* legal
`:EXCLUSIVE_GATEWAY`-branching shape, cyclic or not, inside a fork branch).

**Order 1 — branch 1 (`X`) evaluated first, fresh `memo = %{}`:**

`collect_leaf_gateways(g, "X", state_0)`: `X` fresh (`index = 0`, pushed, single edge) → recurse
`GW` (`index = 1`, pushed, single edge) → recurse `C` (`index = 2`, pushed, single edge) → recurse
`B` (`index = 3`, pushed, out-degree 2):
- Edge `B → GW`: `GW ∈ stack_set` (yes — `GW` is still open, its own fold hasn't returned) → **step
  2, on-stack**: return `{{:open, index["GW"] = 1}, MapSet.new(), state}` — **no leaf contributed**.
  `B`'s `local_lowlink = min(3, 1) = 1`.
- Edge `B → D`: `D` fresh (`index = 4`, pushed, single edge) → recurse `JOIN` — step 4, immediate
  terminal, `memo["JOIN"] = #{{:gateway,"JOIN"}}`. `D`'s fold sees a `:finished` child →
  `local_lowlink` stays `4` → closes → `memo["D"] = #{{:gateway,"JOIN"}}`. Back in `B`:
  `local_leaves = MapSet.union(∅, #{{:gateway,"JOIN"}}) = #{{:gateway,"JOIN"}}` (the `B → GW` edge
  contributed nothing, per step 2's semantic correction — **not** the `:dead_end` iteration 2 would
  have added here).
- `B`'s closure check: `local_lowlink = 1 ≠ index["B"] = 3` → **not** a root, stays on stack. Return
  `{{:open, 1}, #{{:gateway,"JOIN"}}, state}`.

Back in `C`: child (`B`) is `{:open, 1}` → merge `B`'s leaves in: `local_leaves =
#{{:gateway,"JOIN"}}`; `local_lowlink = min(2, 1) = 1`. Closure check: `1 ≠ 2` → open, return
`{{:open, 1}, #{{:gateway,"JOIN"}}, state}`. Back in `GW`: same merge → `local_leaves =
#{{:gateway,"JOIN"}}`; `local_lowlink = min(1, 1) = 1`. **Closure check: `1 == index["GW"] = 1` →
`GW` is the SCC root.** Pop `stack` (`[X, GW, C, B]`, top = `B`) down through and including `GW`:
pops `B`, `C`, `GW` (three members — `X`, `index = 0`, stays on the stack, correctly excluded: `X`
is not part of the cycle). Write `memo["B"] = memo["C"] = memo["GW"] = #{{:gateway,"JOIN"}}` — **one
shared singleton value for all three**, not the two-element `#{:dead_end, {:gateway,"JOIN"}}`
iteration 2's node-keyed scheme produced for this same shape. Return `:finished` up to `GW`'s
caller.

Back in `X`: child (`GW`) is `:finished` with `#{{:gateway,"JOIN"}}` → `local_leaves =
#{{:gateway,"JOIN"}}`; `local_lowlink` stays `index["X"] = 0` (never touched by a finished child) →
closes trivially → `memo["X"] = #{{:gateway,"JOIN"}}`. **Branch 1 resolves to the singleton
`#{{:gateway,"JOIN"}}`.**

**Order 1 continued — branch 2 (`B`) evaluated second, with `memo` from branch 1
(`{X, GW, C, B, D, JOIN} → #{{:gateway,"JOIN"}}` for every key):** `collect_leaf_gateways(g, "B",
state)` — **step 1 fires immediately: `B ∈ memo`** → return `{:finished, #{{:gateway,"JOIN"}},
state}`, O(1), no recursion at all. **Branch 2 also resolves to `#{{:gateway,"JOIN"}}`.**

**Order 2 — branch 2 (`B`) evaluated first instead, fresh `memo = %{}`:** `collect_leaf_gateways(g,
"B", state_0)`: `B` fresh (`index = 0`, pushed, out-degree 2):
- Edge `B → GW`: `GW` fresh (`index = 1`, pushed, single edge) → recurse `C` (`index = 2`, pushed,
  single edge) → recurse `B` again — **`B ∈ stack_set`** (yes, `B` is the root, still open) → step
  2: return `{{:open, index["B"] = 0}, MapSet.new(), state}` — no leaf. `C`'s `local_lowlink =
  min(2, 0) = 0`; closure check `0 ≠ 2` → open, return `{{:open, 0}, ∅, state}`. Back in `GW`: merge
  → `local_leaves = ∅`; `local_lowlink = min(1, 0) = 0`; closure check `0 ≠ 1` → open, return
  `{{:open, 0}, ∅, state}`.
- Back in `B`: child (`GW`) is `{:open, 0}` → merge `GW`'s (empty) leaves in: `local_leaves = ∅`;
  `local_lowlink = min(0, 0) = 0`.
- Edge `B → D`: `D` fresh, chains to `JOIN` exactly as before → `:finished`,
  `#{{:gateway,"JOIN"}}`, `memo["D"]`/`memo["JOIN"]` written. Back in `B`: merge → `local_leaves =
  MapSet.union(∅, #{{:gateway,"JOIN"}}) = #{{:gateway,"JOIN"}}`.
- `B`'s closure check: `local_lowlink = 0 == index["B"] = 0` → **`B` is the SCC root.** Pop `stack`
  (`[B, GW, C]`) fully: members `{C, GW, B}` (all three — same SCC membership as order 1, confirming
  SCC identity is independent of entry point). Write `memo["C"] = memo["GW"] = memo["B"] =
  #{{:gateway,"JOIN"}}` — **identical value, byte-for-byte, to order 1's result for the same three
  keys.** Return `:finished`.

**Order 2 continued — branch 1 (`X`) evaluated second, with `memo` from branch 2:**
`collect_leaf_gateways(g, "X", state)`: `X` fresh, single edge → recurse `GW` — **step-1 memo hit**
(`GW ∈ memo`) → `{:finished, #{{:gateway,"JOIN"}}, state}`, no recursion into the cycle needed at
all. `X` closes → `memo["X"] = #{{:gateway,"JOIN"}}`. **Branch 1 resolves to
`#{{:gateway,"JOIN"}}`, identical to order 1.**

**Conclusion:** `memo["GW"]`, `memo["C"]`, and `memo["B"]` are the exact same singleton
`#{{:gateway,"JOIN"}}` in both orders — the property iteration 2's proof claimed but that the
validator's trace showed was false for the node-keyed scheme (where `memo["GW"]` was a clean
`:dead_end` singleton under a `B`-first entry but a two-element `#{:dead_end,{:gateway,"JOIN"}}`
set under an `X`-first entry). Both top-level branches agree on `{:gateway, "JOIN"}` in both orders,
so `find_matching_join/2` returns `{:ok, "JOIN"}` regardless of which of the split's sibling edges
is folded first — order-independence is now a property that holds *by construction* (§2.2.1's
SCC-closure argument), not by coincidence of this particular graph's shape, unlike iteration 2's
externally-matching-by-luck outcome that the validator flagged as not generalizing. §4 adds a
regression fixture pair (`cyclic_escape_graph/0` and its edge-order-reversed twin) that exercises
precisely this both-orders property.

### 2.5 `find_matching_join/2` — the agreement rule (per-branch, then cross-branch)

```
@spec find_matching_join(Graph.t(), Node.t()) ::
        {:ok, join_node_id :: String.t()} | {:error, :no_matching_join}
```

Two agreement checks now compose, where today there was only one. **Rework note (iteration 3):**
with `collect_leaf_gateways` now `/3` (taking a single `leaf_search_state()` in place of the old
`on_path`/`memo` pair — §2.2.2), `find_matching_join/2`'s own outer reduction must thread the whole
`state` — not just its `memo` field — across the split node's sibling branches, but reset `index`,
`lowlink`, `stack`, and `stack_set` to empty/`0` between branches (§2.2.2/§2.2.3 prove this reset is
always safe: a top-level call's own stack is always fully unwound by the time it returns, so there
is never anything "open" left for the next branch to inherit) — only `memo` needs to genuinely
survive from one branch's fold step to the next. This is the same cross-branch reuse iteration 2
already established (a downstream node shared by two *different* top-level fork branches, not just
two sibling paths inside one branch, is safe to compute once and reuse), now resting on §2.2.1's
corrected SCC-closure argument instead of the falsified node-keyed one.

**Per-branch (updated for `/3`):** `find_matching_join/2` folds over the split node's `edges_out`
with an explicit accumulator `{agreement_state, state}` (`Enum.reduce_while`/`Enum.reduce` composed
with the fold, not a plain `Enum.map`), starting a **fresh** `leaf_search_state()` (`memo = %{}`,
`index = %{}`, `lowlink = %{}`, `stack = []`, `stack_set = MapSet.new()`, `next_index = 0`) once per
`find_matching_join/2` call (fresh per split node — not shared across *different* split nodes, e.g.
a nested `PARALLEL_GATEWAY`'s own, separate `find_matching_join/2` call; see §2.3's exclusion
boundary for why those never need to interact). For one split-edge's `edge.target`, call
`{_tag, leaves, state'} = collect_leaf_gateways(definition_snapshot, edge.target, state)` — where,
per branch after the first, `state` carries forward the *previous* branch's final `memo` but with
`index`/`lowlink`/`stack`/`stack_set`/`next_index` reset to empty/`0` (a "reset except `memo`"
step the fold must apply between iterations, not a raw pass-through of the previous branch's final
`state'`, since that state's `index`/`lowlink` numbering is meaningless to a new top-level call —
§2.2.2's note on this). Inspect the resulting `MapSet.t(branch_leaf())` (`leaves`), then continue
the fold with the reset-except-memo `state'`:
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
  correctly, not to make genuinely ambiguous shapes resolve. None of this agreement logic changes
  from iteration 1/2 — only the state shape and the SCC-closure mechanics underneath it changed.

**Cross-branch (unchanged in substance from today):** the outer fold over the split node's
`edges_out` keeps its existing agreement shape — each branch must resolve (per the rule above) to
some `gateway_id`, and every branch's `gateway_id` must be the same value, or the whole call returns
`{:error, :no_matching_join}`; the only change is that the fold now also threads `state.memo`
forward between branch iterations instead of being a plain reduce over `{:ok, acc_join_id}` alone.
`dispatch_parallel_split/4`'s call site (transition.ex:772–774,
`{:error, :no_matching_join} -> {:error, {:no_matching_join_found, node.id}}`) is unchanged —
`find_matching_join/2`'s own external signature (`Graph.t(), Node.t() -> {:ok, id} | {:error,
:no_matching_join}`) is unchanged; `leaf_search_state()` is purely an internal accumulator, never
surfaced past `find_matching_join/2`'s own boundary.

### 2.6 Signature/name note for ELIXIR-DEV

`collect_leaf_gateways/3` is a **replacement** for `walk_to_gateway/3` (renamed in iteration 1;
re-aritied to `/4` in iteration 2; **this revision changes both the arity, back to `/3`, and the
shape of its state argument** — the separate `on_path :: MapSet.t()` and `memo :: %{...}` positional
arguments iteration 2 specified are replaced by one `leaf_search_state()` map bundling `memo`,
`index`, `lowlink`, `stack`, `stack_set`, and `next_index`, §2.2.2 — and its return shape changes
from iteration 2's `{MapSet.t(branch_leaf()), memo}` to `{leaf_search_result(), MapSet.t(branch_leaf()),
leaf_search_state()}`) — not an additional function alongside it; ELIXIR-DEV should replace the
iteration-2 `/4` version in place rather than keep both. Positional arguments: `Graph.t()`, `node_id
:: String.t()`, `state :: leaf_search_state()`. Every call site inside `transition.ex` must be
updated to destructure the `{tag, leaves, state}` triple and thread `state` forward — §2.2.2 step
5's sibling-edge fold and §2.5's `find_matching_join/2` fold are the two places this threading must
actually happen, with §2.5's fold additionally responsible for resetting `index`/`lowlink`/`stack`/
`stack_set`/`next_index` to empty/`0` between branches while carrying `memo` forward (not a plain
pass-through of the previous branch's full final `state'` — a call site that fails to reset these
fields between branches would silently make one branch's `index` numbering leak into the next
branch's lowlink comparisons, which is meaningless and could misfire the closure check; a call site
that resets `memo` too, instead of only the four stack-bookkeeping fields, would regress to
re-exploring already-finished nodes and silently reintroduce iteration 1/2's exponential-blowup
defect class — ELIXIR-DEV and TEST-DESIGNER should treat "does `memo` survive across branches while
`index`/`lowlink`/`stack`/`stack_set` reset" as the two load-bearing properties to verify together,
not just "does the function compile and return the right type"). The private-function moduledoc
comment immediately above it (transition.ex:830–834 today, "Follows single-outgoing-edge chains...")
must be rewritten to describe the memoized-Tarjan-SCC-DFS behavior in §2.2.1–§2.2.3 rather than any
prior iteration's stale description, since a stale version would become a misleading (and, for
iteration 1's and iteration 2's own versions, actively wrong-about-correctness-or-complexity)
artifact once this revision ships.

## 3. Walkthrough: every existing AC1–AC6 test case, confirmed unaffected

All six AC groups in `test/letflow/engine/parallel_gateway_test.exs` build exclusively on
`three_branch_graph/0` (lines 50–64): a `PARALLEL_GATEWAY` "split" with 3 outgoing edges, **each
edge's target is "join" directly** — a `PARALLEL_GATEWAY` node with zero intermediate hops per
branch, and "join" has one outgoing edge to an `:END` node "e".

For each of the 3 branches, `find_matching_join/2` calls `collect_leaf_gateways(g, "join", state)`
(`state.memo` carried in from the fold over the previous branch, per §2.5's rework — starts `%{}`
for branch 0, with `index`/`lowlink`/`stack`/`stack_set`/`next_index` reset to empty/`0` for every
branch):
- Step 1 (memo check): `"join"` not yet in `memo` for branch 0 → continue. (Branches 1 and 2 *will*
  find `"join"` already in `memo` from branch 0's own computation — see below.)
- Step 2 (on-stack check): `"join"` not in `stack_set` (`MapSet.new()`, fresh for this branch) →
  continue.
- Step 3 (lookup): resolves to the `"join"` node.
- Step 4 (gateway terminal): `"join"`'s `node_type == :PARALLEL_GATEWAY` → return
  `{:finished, MapSet.new([{:gateway, "join"}]), state'}` immediately, with `state'.memo =
  Map.put(state.memo, "join", #{{:gateway,"join"}})`. **Step 5 is never reached for this fixture at
  all** — the branching fold in step 5's second bullet is dead code for every existing test case,
  since none of them contain a non-`:PARALLEL_GATEWAY` branching node anywhere in a branch, and no
  back-edge (step 2's on-stack case) ever fires either, since this fixture has no cycle at all.

Branch 0 computes `"join"` fresh and caches it. Branches 1 and 2 each call
`collect_leaf_gateways(g, "join", state)` with `state.memo` now already containing `"join"` from
branch 0 — each gets a step-1 memo hit, O(1), returning the identical `#{{:gateway,"join"}}` without
recomputing. Each branch's leaf-set is the singleton `#{{:gateway, "join"}}` → per-branch check
passes, resolving to `"join"`. All 3 branches agree → cross-branch check passes → `{:ok, "join"}`,
byte-for-byte the same result `walk_to_gateway/3` produces today for this fixture, and
byte-for-byte the same result every prior iteration's traversal would produce too — the memo
changes only whether branches 1 and 2 recompute `"join"` from scratch (iteration 1) or reuse branch
0's cached answer (iteration 2 onward); it does not change the answer, and this fixture never
exercises the SCC-closure machinery at all (no cycles, no branching), so it cannot distinguish
iteration 2's defect from this revision's fix — that distinction is exactly what §4's new
`cyclic_escape_graph/0` fixture is for. Since
`find_matching_join/2`'s return value, `dispatch_parallel_split/4`'s `JoinCounter` construction, and
every downstream `dispatch_parallel_join/4`/`dispatch_cancel_branch/3` behavior AC1–AC6 assert on
are all unchanged by (and causally downstream of, not upstream of) this fix, every existing
assertion in AC1 (3 distinct branch_ids, `JoinCounter` shape), AC2 (wait/fire boundary), AC3
(cancelled-branch exclusion), AC4 (all-cancelled), AC5 (order-independence/exactly-once), and AC6
(`VariableMerge.merge/3` reuse) continues to hold unchanged. No AC1–AC6 test needs modification.

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

**New in this rework — regression coverage for the fixed INV-8 defect, `diamond_chain_graph/1`:**
per SECURITY-REVIEWER's explicit recommendation ("a chained-diamond stress fixture... enough to
demonstrate super-linear blowup without literally hanging the test suite"), a parameterized fixture
function `diamond_chain_graph(k)` generating exactly §2.4a's structure for a given chain length
`k` — a `PARALLEL_GATEWAY` "split" whose single branch is a chain of `k` `:EXCLUSIVE_GATEWAY`
diamonds (`gw_1 .. gw_k`, each with two edges to `b_i`/`c_i`, both reconverging on `gw_{i+1}`, or on
the branch's real `"join"` `:PARALLEL_GATEWAY` node for `gw_k`), `"join"` → single edge → `"e"`
(`:END`). Node/edge count for chain length `k`: `3k + 3` nodes (`split`, `k` gateways, `2k`
route nodes, `join`, `e`) and `4k + 2` edges — parameterize `k` so this stays comfortably inside
`@max_nodes 500`/`@max_edges 2000` while still being large enough to prove the point (TEST-DESIGNER's
call on the exact `k`; `k = 20` gives `63` nodes/`82` edges, well inside caps, while `2^20 ≈ 10^6` —
large enough that the old unmemoized algorithm would be markedly, measurably slower or would time
out a reasonable test timeout, while this rework's `O(nodes + edges)` version completes
near-instantly).

**Assertions (new `describe` block):**
1. `Transition.transition(g, state, {:advance_token, initial_token_id})` on `diamond_chain_graph(k)`
   returns `{:ok, new_state, [{:parallel_split, ...}]}` (succeeds, exactly as the single-diamond
   case does) — confirms correctness is unaffected by chain length.
2. The call completes within a small, explicit wall-clock bound (e.g. assert elapsed time under a
   fixed millisecond budget generous enough to avoid CI flakiness but tight enough that an
   accidental reversion to `O(2^k)` behavior would blow past it for the chosen `k` — TEST-DESIGNER's
   call on the exact threshold) — this is the actual regression assertion for the complexity defect
   itself, since a pure correctness assertion alone (assertion 1) would also pass under the old,
   exponentially-slow algorithm for small `k` and would not by itself catch a reversion.
3. `new_state.join_counters["join"]` resolves against `"join"`, not against any intermediate `gw_i`
   node — confirms chain length doesn't change *which* node the branch resolves to, only how much
   work resolving it takes.

**New in this revision — regression coverage for the fixed memo-key-unsoundness defect
(CODE-DESIGN-VALIDATOR's BLOCKER, §2.4b), `cyclic_escape_graph/0` and its edge-order-reversed
twin:** neither `branch_with_exclusive_gateway_graph/0` nor `diamond_chain_graph/1` contains a
cycle, so neither can catch a regression back to iteration 2's node-keyed memo scheme — both would
pass unchanged under the buggy scheme too, for the same reason §3 notes `three_branch_graph/0`
cannot distinguish the two schemes either. This fixture pair exists specifically to close that gap.

**Fixture — `cyclic_escape_graph/0`:** a `PARALLEL_GATEWAY` `"split"` with 2 outgoing edges — edge 0
→ `"X"`, edge 1 → `"B"` — plus, exactly matching §2.4b's counterexample: `"X"` → single edge →
`"GW"` (`:EXCLUSIVE_GATEWAY`) → single edge → `"C"` → single edge → `"B"` (`:EXCLUSIVE_GATEWAY`,
out-degree 2: `"B"` → `"GW"`, closing the cycle, legal per CHK-06 since both `"B"` and `"GW"` are
gateway-typed; and `"B"` → `"D"`) → `"D"` → single edge → `"JOIN"` (`:PARALLEL_GATEWAY`) → single
edge → `"e"` (`:END`).

**Fixture — `cyclic_escape_graph_reversed_edges/0`:** the exact same graph, with the split node's
`edges_out` list order swapped (edge 0 → `"B"`, edge 1 → `"X"`) — this is the literal, mechanical
regression test for order-independence itself: `find_matching_join/2`'s outer fold visits the split
node's edges in list order, so this fixture forces the fold to evaluate the `"B"`-entry branch
*before* the `"X"`-entry branch, the reverse of `cyclic_escape_graph/0` — exactly Order 2 vs. Order
1 in §2.4b's trace.

**Assertions (new `describe` block, applied to both fixtures identically):**
1. `Transition.transition(g, state, {:advance_token, initial_token_id})` returns `{:ok, new_state,
   [{:parallel_split, ^initial_token_id, "split", branch_ids}]}` — succeeds on both fixtures, and
   both fixtures produce **the same outcome as each other** (this is the actual regression
   assertion: a reversion to per-node memoization could plausibly make one of the two edge orders
   fail while the other happens to still pass, exactly as iteration 2's own worked trace showed one
   evaluation order "self-healing" to the right externally-visible answer by coincidence while the
   other did not need to for this particular graph — TEST-DESIGNER should assert both fixtures'
   full result tuples are equal, not just that each independently succeeds).
2. `new_state.join_counters["JOIN"]` is a `%JoinCounter{}` whose `expected_from_branches ==
   MapSet.new(branch_ids)` on both fixtures — the join cohort resolves against the real, outer
   `"JOIN"` node, not against `"GW"` or any other cycle member.
3. Branch entering at `"B"`'s new token lands on `"B"` itself (mirrors assertion 3 of
   `branch_with_exclusive_gateway_graph/0`'s describe block) — confirms the split still only
   advances one hop per branch regardless of what `find_matching_join/2`'s lookahead discovers.

**Fixture — `pure_cycle_no_escape_graph/0` (recommended, not required for ISS-0398's own acceptance
criteria but cheap and closes an adjacent gap named in §2.2.1):** a `PARALLEL_GATEWAY` `"split"`
with one branch: `"A"` (single outgoing edge) → `"B"` (`:EXCLUSIVE_GATEWAY`, single outgoing edge
back to `"A"`, closing a 2-node cycle with no escape edge anywhere in the cycle — legal per CHK-06
since `"B"` is gateway-typed). Per §2.2.1/§2.2.2, this
SCC's aggregate leaves is the **empty set** (no escape edges to contribute anything, and the cycle's
own back-edge contributes nothing per step 2's semantic correction) — a non-singleton, so §2.5's
agreement rule correctly rejects this branch. Assert
`Transition.transition(g, state, {:advance_token, initial_token_id})` returns
`{:error, {:no_matching_join_found, "split"}}` — confirms a pure escape-less cycle fails cleanly
(the same external outcome iteration 2's `:dead_end`-singleton treatment would also have produced
for this specific shape, so this fixture is about confirming the *new* empty-set treatment doesn't
regress this case, not about distinguishing it from iteration 2).

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

**Does the memo-key-unsoundness fix (iteration 3, this revision) have any knock-on effect on this
section's scope boundary? No — stated explicitly, not left implicit.** §2.3's nested-`PARALLEL_GATEWAY`
exclusion is about which node *type* terminates the traversal (a `:PARALLEL_GATEWAY` node, regardless
of whether its result came from a fresh computation, a step-1 memo hit, or an SCC closure);
switching from plain node-keyed memoization to SCC-keyed memoization changes only *how many nodes
share one cached value* and *when that value is safe to write*, never what node types are treated as
terminal, and a `:PARALLEL_GATEWAY` node is (unchanged, §2.2.2 step 4) never pushed onto the SCC
traversal's stack at all — it is exactly as immune to being pulled into a cycle's SCC after this
revision as it was before. The genuinely-unsupported nested-`PARALLEL_GATEWAY`-within-a-branch shape
named above is exactly as unsupported after this revision as it was after iteration 1/2 — same
mechanism (§2.3's step 4 short-circuit, unchanged numbering per §2.2.2), same required follow-up
issue, no changes needed to this section's content beyond the `collect_leaf_gateways/3` arity note
(iteration 2 moved it to `/4`; this revision moves it back to `/3` with a different state shape,
§2.6). Similarly, §5's conclusion (no new `CHK-*` structural-validator rule required) is unaffected:
`find_matching_join/2` was already, and remains, total and honest for every graph shape it can't
resolve, and neither the complexity fix (iteration 2) nor the correctness fix (this revision)
changes *which* shapes it can/can't resolve — only how efficiently, and now how *correctly* under
cycles, it resolves the shapes it already could. The sections this revision's knock-on effects land
on are §2 itself (rewritten), §2.4/§2.4a (re-confirmed unaffected, notation updated), §2.4b (new),
§2.5/§2.6 (state-shape update), §3 (notation update, no substantive change), and §4 (two new
regression fixtures for this defect class, added above).
