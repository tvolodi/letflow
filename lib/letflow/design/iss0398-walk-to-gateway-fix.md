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

**Iteration 2 (this revision):** SECURITY-REVIEWER FAILED iteration 1's design/implementation at
`WF03-ISS0398-20260901` Step 3c on a BLOCKER INV-8 finding
(`handoffs/WF03-ISS0398-20260901/step-03c-security-reviewer.json`) — iteration 1's
`collect_leaf_gateways/3` recursed into every outgoing edge of a branching node with a
per-path-**copied** (not memoized) `visited` set, making total call count exponential (`O(2^k)` for
a chain of `k` reconverging `:EXCLUSIVE_GATEWAY` diamonds) rather than the intended bound on
recursion *depth* the iteration-1 termination argument actually proved. This revision replaces the
per-path-copy scheme with a `node_id`-keyed memoized DFS (§2.2), bounding total work to
`O(nodes + edges)`, and re-verifies both the original AC1–AC6 non-regression argument (§3) and
SECURITY-REVIEWER's own adversarial chained-diamond construction, traced concretely for `k = 3`
(§2.4a). Everything in §2.3 (nested-`PARALLEL_GATEWAY` exclusion), §2.5's agreement-rule semantics,
and §5/§6's conclusions carries forward unchanged in substance — only the plumbing needed to thread
the new `memo` accumulator changed; each section says so explicitly where it applies.

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

### 2.2 `collect_leaf_gateways/4` — replaces `walk_to_gateway/3` (memoized DFS)

**Rework note (iteration 2):** the iteration-1 version of this section specified an unmemoized
per-path traversal (`collect_leaf_gateways/3`, `visited` copied — not shared — across sibling
edges at a branching node). SECURITY-REVIEWER (`handoffs/WF03-ISS0398-20260901/step-03c-security-reviewer.json`,
BLOCKER INV-8) showed that scheme makes total call count exponential in the number of chained,
reconverging branching nodes: a chain of *k* `:EXCLUSIVE_GATEWAY` "diamonds," each reconverging
before the next diamond's own gateway, forces `2^k` independent re-explorations of everything past
diamond *k*, because the same downstream node is re-derived from scratch once per sibling path that
reaches it — well within `@max_nodes 500`/`@max_edges 2000` (`lib/letflow/definitions/graph.ex:158-159`)
at `k ≈ 40`. This section replaces that scheme with a **memoized DFS keyed on `node_id` alone**,
which bounds total work to `O(nodes + edges)`. §2.2.1 justifies the memo key choice; §2.2.2 gives
the traversal; §2.2.3 gives the termination/complexity argument; §2.4a traces a concrete `k = 3`
chain end-to-end to show the call count is now bounded, not exponential.

#### 2.2.1 Why the memo may key on `node_id` alone (not `node_id` + path/ancestor context)

The question this must answer honestly, per this project's design convention: can two different
callers reach the same `node_id` via different ancestor paths and legitimately get *different*
leaf-gateway sets back? If so, a plain `node_id`-keyed cache would silently return a stale/wrong
answer to the second caller.

**Answer: no, once a node's own computation has fully finished — with one specific exception
(cyclic back-edges) that is handled by keeping cycle detection entirely separate from the memo, not
folded into it.** `collect_leaf_gateways/4`'s result for a given `node_id` is defined purely by
following `definition_snapshot.edges` *forward* from `node_id`: which nodes are reachable, and
which of those are `:PARALLEL_GATEWAY` nodes, is a static property of the graph and `node_id` —
"how the caller arrived at `node_id`" plays no role in that forward-looking question. The only way
ancestry could matter is if the traversal loops back into one of its own ancestors mid-computation
(`graph.ex`'s CHK-06 permits a cycle *iff* it passes through a gateway node, so this is a real,
structurally-legal shape, not a hypothetical) — but that is exactly what cycle detection already
exists to handle, and it does not depend on the *finished* value of any node; it depends on whether
that node's computation is **currently still in progress** on this exact call chain. So the design
keeps two separate pieces of state, deliberately not merged into one:

- **`on_path` — a per-active-call-chain "currently in progress" set**, scoped only to the *current*
  live recursion (from a single top-level `collect_leaf_gateways/4` entry down through its still-open
  calls). This is mechanically identical to iteration 1's `visited`: extended by one element per
  recursive step, and — because Elixir's call stack is real, not a shared mutable structure — a
  sibling branch's additions to `on_path` are invisible to the other sibling and automatically
  "pop" back off once that sibling's own call frame returns, exactly as they did under the
  iteration-1 per-path-copy scheme. **This set is never cached and never reused across siblings.**
  It only ever answers "is this node an ancestor of itself on the path that's live right now" —
  a cycle back to an in-progress node correctly still resolves to `:dead_end` for that edge, unchanged
  from iteration 1.
- **`memo` — a `node_id`-keyed cache of *finished* results**, populated only after a node's own
  computation has fully returned (all of its own outgoing edges resolved), and threaded forward —
  not copied — across sibling edges and across sibling top-level branch calls (§2.5). A node is
  never in both `on_path` (for the chain currently computing it) and `memo` (finished) at the same
  time: entry into `memo` happens at the exact moment its call frame is about to return, which is
  also the moment it would otherwise have been "popped" off `on_path`.

Lookup order at every call is therefore: **`memo` first** (an unconditionally safe, context-free
answer — if present, the node's true, fully-resolved leaf-set, return it in O(1) without
recursing), **then `on_path`** (a live self-reference — return `:dead_end` for this edge without
caching that transient answer against the node, since the node itself hasn't finished computing
yet), **then compute fresh** (mark `on_path`, recurse, then — before returning — write the finished
result into `memo`). This ordering is what makes `node_id`-alone a correct memo key: by the time
anything is written to `memo`, it is guaranteed context-free.

#### 2.2.2 Traversal, stated precisely (recursive, no implementation code)

```
@spec collect_leaf_gateways(
        Graph.t(),
        node_id :: String.t(),
        on_path :: MapSet.t(String.t()),
        memo :: %{optional(String.t()) => MapSet.t(branch_leaf())}
      ) :: {MapSet.t(branch_leaf()), memo :: %{optional(String.t()) => MapSet.t(branch_leaf())}}
```

Called as `collect_leaf_gateways(definition_snapshot, node_id, on_path, memo)`, returning a
`{result, updated_memo}` pair (memo is explicit accumulator state, threaded functionally — no
process dictionary, no ETS, matching this codebase's existing pure-recursion style). At each
branch's own `edge.target` (the call site in `find_matching_join/2`, §2.5), `on_path` starts fresh
as `MapSet.new()` — **`memo` does not reset per branch**; it is threaded across all of a split
node's sibling branches (§2.5), so a downstream node shared by two different fork branches is also
only ever computed once.

1. **Memo hit.** If `Map.has_key?(memo, node_id)`: return `{Map.fetch!(memo, node_id), memo}`
   unchanged — O(1), no recursion, no `on_path` involvement. This is the case that collapses
   sibling re-exploration and is the sole mechanical fix for the exponential blowup.
2. **Cycle check (`on_path`, unchanged semantics from iteration 1's `visited`).** Else, if `node_id`
   is a member of `on_path`: return `{MapSet.new([:dead_end]), memo}` **without** writing anything
   into `memo` for `node_id` — this is a transient answer about a live back-edge, not `node_id`'s
   own finished value (its own call frame, further up the stack, hasn't returned yet).
3. **Node lookup.** Else, resolve `node_id` via `find_node(definition_snapshot.nodes, node_id)`. If
   it returns `nil`: `result = MapSet.new([:dead_end])`, `memo' = Map.put(memo, node_id, result)`,
   return `{result, memo'}`.
4. **Gateway terminal.** If the resolved node's `node_type == :PARALLEL_GATEWAY`:
   `result = MapSet.new([{:gateway, node.id}])`, `memo' = Map.put(memo, node.id, result)`, return
   `{result, memo'}` — same short-circuit as iteration 1 (transition.ex:859-860 today), now also
   cached, immediately and permanently, the first time any path reaches this gateway.
5. **Otherwise, branch by out-degree.** Compute `outgoing_edges = Enum.filter(definition_snapshot.edges,
   &(&1.source == node.id))`, and `next_on_path = MapSet.put(on_path, node.id)`.
   - **Zero edges:** `result = MapSet.new([:dead_end])`, cache under `node.id`, return.
   - **Exactly one edge** `single_edge`: `{child_result, memo1} = collect_leaf_gateways(definition_snapshot,
     single_edge.target, next_on_path, memo)`; `result = child_result`; `memo2 = Map.put(memo1, node.id,
     result)`; return `{result, memo2}` — the existing linear chain-following recursion, now also
     threading and updating `memo`.
   - **More than one edge** (an `:EXCLUSIVE_GATEWAY`, or any future non-`:PARALLEL_GATEWAY` node
     type with out-degree > 1 — a `:PARALLEL_GATEWAY` node can never reach this branch, since step 4
     already returned for it): process `outgoing_edges` **sequentially, threading `memo` from one
     edge to the next** (an `Enum.map_reduce`/fold shape, not an independent `Enum.map`): for edge
     `e_1`, compute `{leaves_1, memo_1} = collect_leaf_gateways(definition_snapshot, e_1.target,
     next_on_path, memo)`; for edge `e_2`, compute `{leaves_2, memo_2} = collect_leaf_gateways(
     definition_snapshot, e_2.target, next_on_path, memo_1)` (note: `memo_1`, not the original
     `memo` — this is the one structural change from iteration 1 that fixes the defect); continue
     through all edges this way. Each sibling still gets its **own** `next_on_path` copy (cycle
     detection stays per-path, unchanged from §2.4's reasoning) — only `memo` is threaded/shared.
     `result = ` the union (`MapSet.union/2`, folded) of all siblings' leaf-sets; cache `result`
     under `node.id` in the final threaded memo; return `{result, memo_final}`.

#### 2.2.3 Totality, termination, and the complexity argument

Total (never raises): identical reasoning to iteration 1 — every clause returns a value, no clause
falls through. Terminates: `on_path` strictly grows by one element on every recursive call along
any single live chain, and `definition_snapshot.nodes` is finite, so no live chain can recurse past
`length(definition_snapshot.nodes)` steps before either resolving to a leaf, hitting a memo entry,
or re-hitting an `on_path` entry and returning `:dead_end` — unchanged from iteration 1.

**Complexity bound (the fix itself):** step 5's "otherwise, compute fresh" body — the only branch
that does real recursive work — executes **at most once per distinct `node_id`** across the entire
traversal (a single top-level `collect_leaf_gateways/4` call, or the whole sequence of a split
node's sibling top-level calls under §2.5's shared-memo threading): the very first time any path
reaches `node_id` and it is neither a memo hit nor an in-progress cycle, its fresh computation runs
to completion and writes itself into `memo` before returning; every subsequent reference to that
same `node_id`, from any path, any sibling, or any later top-level branch, is a step-1 memo hit —
O(1), no further recursion. Summing over all `node_id`s: at most `length(definition_snapshot.nodes)`
fresh computations, each of which inspects exactly its own outgoing edges once
(`Enum.filter(definition_snapshot.edges, &(&1.source == node.id))`), so the sum of edges inspected
across all fresh computations is at most `length(definition_snapshot.edges)`. Every other call
(memo hits, cycle hits) is O(1) plus a bounded `MapSet`/`Map` lookup. Total work is therefore
`O(nodes + edges)` map/set operations — polynomial, not exponential in the number of branching
nodes — which directly closes SECURITY-REVIEWER's INV-8 finding. §2.4a traces this concretely for
a `k = 3` chain of reconverging diamonds.

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

### 2.4 Per-path `on_path`, cross-path `memo` — worked example of why both are needed

Consider a branch: `A` (single edge) → `gw` (`:EXCLUSIVE_GATEWAY`, edges to `B` and `C`) → both `B`
and `C` have a single edge to `D` → `D` has a single edge to `join` (`:PARALLEL_GATEWAY`). This is a
legitimate diamond (fork-then-reconverge inside one `PARALLEL_GATEWAY` branch) and must resolve to
`{:ok, "join"}`.

Walking it: `collect_leaf_gateways(g, "A", #{}, %{})` → chain to
`collect_leaf_gateways(g, "gw", #{"A"}, %{})` → out-degree 2, so process sequentially, threading
`memo`:
- Edge to `B`: `collect_leaf_gateways(g, "B", #{"A", "gw"}, %{})` → chain →
  `collect_leaf_gateways(g, "D", #{"A", "gw", "B"}, %{})` → chain →
  `collect_leaf_gateways(g, "join", #{"A", "gw", "B", "D"}, %{})` → gateway terminal →
  `{#{{:gateway, "join"}}, %{"join" => #{{:gateway,"join"}}}}` → unwinding the chain caches `"D"` and
  `"B"` too → returns `{#{{:gateway, "join"}}, memo_1}` where
  `memo_1 = %{"join" => ..., "D" => #{{:gateway,"join"}}, "B" => #{{:gateway,"join"}}}`.
- Edge to `C`, now called with `memo_1` (not `%{}`): `collect_leaf_gateways(g, "C", #{"A", "gw"},
  memo_1)` → chain to `collect_leaf_gateways(g, "D", #{"A", "gw", "C"}, memo_1)` — **`"D"` is already
  in `memo_1`**, so this is a step-1 memo hit: return `{#{{:gateway, "join"}}, memo_1}` immediately,
  **without recursing into `join` a second time**. Unwinding caches `"C"` too.

`on_path` for the `C`-branch (`#{"A", "gw", "C"}`) never contains `"D"` (only the `B`-branch's own
`on_path`, `#{"A", "gw", "B"}`, did) — so even without the memo hit, no false cycle would have
tripped; the memo hit is a pure performance win here, not a correctness requirement, because this
single diamond is shallow. §2.4a shows a *chain* of diamonds where the memo hit becomes a
correctness-for-tractability requirement — without it, this exact "second sibling re-derives
everything past the shared node" step happens again at every subsequent diamond, compounding
geometrically. The union of the two leaf-sets is `MapSet.new([{:gateway, "join"}])` — a singleton,
so §2.5 accepts it, byte-for-byte the same outcome as iteration 1's unmemoized version — the memo
changes performance, never the result. This is the exact distinction ISSUE-FIXER's diagnosis
flagged as "a first-class design decision, not an afterthought," now resolved with both halves
explicit: **`on_path` is threaded down each recursive call chain and independently duplicated (not
shared) across sibling edges — this is what keeps cycle detection correct; `memo` is threaded
forward across sibling edges (and, per §2.5, across sibling top-level branch calls) — this is what
keeps total work bounded.**

A genuine cycle (a path that loops back on *itself*, e.g. `A → B → A`, legal per `graph.ex` CHK-06
when it passes through a gateway node) is still caught correctly: `on_path` grows along that single
live chain (`#{} → #{"A"} → #{"A","B"}`), and the second visit to `A` finds it already present in
that same chain's `on_path` → `:dead_end` for that back-edge, without ever touching `memo` for `A`
(its own frame, further up the stack, hasn't returned yet — see §2.2.1's ordering argument for why
this is exactly what keeps the memo-key-by-`node_id`-alone choice sound).

### 2.4a Diamond-chain adversarial case (SECURITY-REVIEWER's example) — traced for `k = 3`

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

**Under this rework's memoized scheme, traced call-by-call:** top-level call
`collect_leaf_gateways(g, "gw1", #{}, %{})`:

1. `gw1` is fresh (out-degree 2) → process edge to `b1` first, `memo = %{}`:
   - `b1` fresh (single edge) → recurse into `gw2` with `memo = %{}`.
   - `gw2` fresh (out-degree 2) → process edge to `b2` first, `memo = %{}`:
     - `b2` fresh (single edge) → recurse into `gw3` with `memo = %{}`.
     - `gw3` fresh (out-degree 2) → process edge to `b3` first: `b3` fresh (single edge) → recurse
       into `join`; `join` is a `:PARALLEL_GATEWAY` → **fresh compute, terminal**, `result =
       #{{:gateway,"join"}}`, cached: `memo = %{"join" => #{{:gateway,"join"}}}`. `b3` caches the
       same result. `memo` now has 2 entries.
     - Edge to `c3`, called with the **updated** memo: `c3` fresh (single edge) → recurse into
       `join` — **memo hit** (step 1), O(1), no further recursion. `c3` caches the same result.
       `gw3`'s own result (union of `b3`'s and `c3`'s, both `#{{:gateway,"join"}}`) is cached.
   - Edge to `c2`, called with the updated memo (now containing `join`, `b3`, `c3`, `gw3`): `c2`
     fresh (single edge) → recurse into `gw3` — **memo hit**, O(1). `c2` caches the same result.
     `gw2`'s own result is cached.
2. Edge to `c1`, called with the updated memo (now containing everything above plus `gw2`, `b2`):
   `c1` fresh (single edge) → recurse into `gw2` — **memo hit**, O(1). `c1` caches the same result.
   `gw1`'s own result (union, `#{{:gateway,"join"}}`) is cached.

**Fresh computations total: 10** (`gw1, b1, gw2, b2, gw3, b3, join, c3, c2, c1` — every one of the
10 distinct node ids in the graph, computed exactly once) — **not** `2^3 = 8` leaf-level calls
compounding into `2^k` growth; for general `k`, fresh computations total `3k + 1` (three nodes per
diamond stage plus the final join), i.e. `O(k)`, and every non-fresh reference (one per `c_i` edge,
`k` of them) is an O(1) memo hit. For `k = 40`: `121` fresh computations plus `40` O(1) memo hits —
nowhere near `2^40`. Each branch's final leaf-set is still the singleton `#{{:gateway, "join"}}`
(identical to what the unmemoized version would eventually compute, just without the redundant
work), so §2.5's per-branch/cross-branch agreement rule still resolves this branch correctly to
`"join"` — the memoization rework changes performance, not the functional outcome, for this
adversarial case exactly as for the plain diamond in §2.4.

### 2.5 `find_matching_join/2` — the agreement rule (per-branch, then cross-branch)

```
@spec find_matching_join(Graph.t(), Node.t()) ::
        {:ok, join_node_id :: String.t()} | {:error, :no_matching_join}
```

Two agreement checks now compose, where today there was only one. **Rework note:** with
`collect_leaf_gateways` now `/4` and memo-returning, `find_matching_join/2`'s own outer reduction
must thread `memo` across the split node's sibling branches too (not just within one branch's own
internal recursion, §2.2.2) — a further, optional-but-free extension of the same fix, since a
downstream node shared by two *different* top-level fork branches (not just two sibling paths
inside one branch) is equally safe to compute once and reuse, by the identical §2.2.1 argument.

**Per-branch (updated for `/4`):** `find_matching_join/2` folds over the split node's `edges_out`
with an explicit accumulator `{agreement_state, memo}` (`Enum.reduce_while`/`Enum.reduce` composed
with the fold, not a plain `Enum.map`), starting `memo` at `%{}` once per `find_matching_join/2`
call (fresh per split node — not shared across *different* split nodes, e.g. a nested
`PARALLEL_GATEWAY`'s own, separate `find_matching_join/2` call; see §2.3's exclusion boundary for
why those never need to interact). For one split-edge's `edge.target`, call
`{leaves, memo'} = collect_leaf_gateways(definition_snapshot, edge.target, MapSet.new(), memo)` —
`on_path` still starts fresh (`MapSet.new()`) at every branch's own root, exactly as `visited` did
in iteration 1; only `memo` carries forward from the previous branch's fold step. Inspect the
resulting `MapSet.t(branch_leaf())` (`leaves`), then continue the fold with `memo'`:
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
  from iteration 1 — only the plumbing that threads `memo` alongside it.

**Cross-branch (unchanged in substance from today):** the outer fold over the split node's
`edges_out` keeps its existing agreement shape — each branch must resolve (per the rule above) to
some `gateway_id`, and every branch's `gateway_id` must be the same value, or the whole call returns
`{:error, :no_matching_join}`; the only change is that the fold now also threads `memo` forward
between branch iterations instead of being a plain reduce over `{:ok, acc_join_id}` alone.
`dispatch_parallel_split/4`'s call site (transition.ex:772–774,
`{:error, :no_matching_join} -> {:error, {:no_matching_join_found, node.id}}`) is unchanged —
`find_matching_join/2`'s own external signature (`Graph.t(), Node.t() -> {:ok, id} | {:error,
:no_matching_join}`) is unchanged; `memo` is purely an internal accumulator, never surfaced past
`find_matching_join/2`'s own boundary.

### 2.6 Signature/name note for ELIXIR-DEV

`collect_leaf_gateways/4` is a **replacement** for `walk_to_gateway/3` (renamed and re-aritied in
iteration 1 already; this rework changes its arity again, from `/3` to `/4`, and its return shape,
from a bare `MapSet.t(branch_leaf())` to `{MapSet.t(branch_leaf()), memo}`) — not an additional
function alongside it; ELIXIR-DEV should replace the iteration-1 `/3` version in place rather than
keep both. Positional arguments: `Graph.t()`, `node_id :: String.t()`, `on_path ::
MapSet.t(String.t())` (renamed from iteration 1's `visited` — same role, cycle detection only,
never cached), `memo :: %{optional(String.t()) => MapSet.t(branch_leaf())}` (new — the
finished-results cache, §2.2.1). Every call site inside `transition.ex` must be updated to
destructure the `{result, memo}` pair and thread `memo` forward — §2.2.2 step 5's sibling-edge fold
and §2.5's `find_matching_join/2` fold are the two places this threading must actually happen (not
just be pattern-matched and discarded — a call site that unpacks `{result, _memo}` and always
passes a fresh `%{}` to the next call would silently regress back to the exponential-blowup defect
this rework exists to fix; ELIXIR-DEV and TEST-DESIGNER should treat "does memo actually get reused
across siblings" as the load-bearing property to verify, not just "does the function compile and
return the right type"). The private-function moduledoc comment immediately above it
(transition.ex:830–834 today, "Follows single-outgoing-edge chains...") must be rewritten to
describe the memoized-DFS behavior in §2.2.1–§2.2.3 rather than either the pre-ISS-0398 linear-only
description or iteration 1's unmemoized-union description, since either stale version would become
a misleading (and, for iteration 1's version, actively wrong-about-complexity) artifact once this
rework ships.

## 3. Walkthrough: every existing AC1–AC6 test case, confirmed unaffected

All six AC groups in `test/letflow/engine/parallel_gateway_test.exs` build exclusively on
`three_branch_graph/0` (lines 50–64): a `PARALLEL_GATEWAY` "split" with 3 outgoing edges, **each
edge's target is "join" directly** — a `PARALLEL_GATEWAY` node with zero intermediate hops per
branch, and "join" has one outgoing edge to an `:END` node "e".

For each of the 3 branches, `find_matching_join/2` calls
`collect_leaf_gateways(g, "join", MapSet.new(), memo)` (`memo` carried in from the fold over the
previous branch, per §2.5's rework — starts `%{}` for branch 0):
- Step 1 (memo check): `"join"` not yet in `memo` for branch 0 → continue. (Branches 1 and 2 *will*
  find `"join"` already in `memo` from branch 0's own computation — see below.)
- Step 2 (cycle check): `"join"` not in `MapSet.new()` (`on_path`) → continue.
- Step 3 (lookup): resolves to the `"join"` node.
- Step 4 (gateway terminal): `"join"`'s `node_type == :PARALLEL_GATEWAY` → return
  `{MapSet.new([{:gateway, "join"}]), memo'}` immediately, with `memo' = Map.put(memo, "join",
  #{{:gateway,"join"}})`. **Step 5 is never reached for this fixture at all** — the broadened
  out-degree branching logic in step 5's third bullet is dead code for every existing test case,
  since none of them contain a non-`:PARALLEL_GATEWAY` branching node anywhere in a branch.

Branch 0 computes `"join"` fresh and caches it. Branches 1 and 2 each call
`collect_leaf_gateways(g, "join", MapSet.new(), memo)` with `memo` now already containing `"join"`
from branch 0 — each gets a step-1 memo hit, O(1), returning the identical `#{{:gateway,"join"}}`
without recomputing. Each branch's leaf-set is the singleton `#{{:gateway, "join"}}` → per-branch
check passes, resolving to `"join"`. All 3 branches agree → cross-branch check passes →
`{:ok, "join"}`, byte-for-byte the same result `walk_to_gateway/3` produces today for this fixture,
and byte-for-byte the same result iteration 1's unmemoized `collect_leaf_gateways/3` would produce
too — the memo changes only whether branches 1 and 2 recompute `"join"` from scratch (iteration 1)
or reuse branch 0's cached answer (this rework); it does not change the answer. Since
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
`collect_leaf_gateways/4` itself, at a different layer, for a purely cosmetic error-timing
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

**Does the memoization rework (iteration 2) have any knock-on effect on this section's scope
boundary? No — stated explicitly, not left implicit.** §2.3's nested-`PARALLEL_GATEWAY` exclusion
is about which node *type* terminates the traversal (a `:PARALLEL_GATEWAY` node, regardless of
whether its result came from a fresh computation or a memo hit); memoization changes only how many
times a node's result is *computed*, never what that result *is* or which node types are treated as
terminal. The genuinely-unsupported nested-`PARALLEL_GATEWAY`-within-a-branch shape named above is
exactly as unsupported after this rework as it was after iteration 1 — same mechanism (§2.3's step
4 short-circuit, now numbered per §2.2.2), same required follow-up issue, no changes needed to this
section's content beyond the `collect_leaf_gateways/3` → `/4` reference already corrected just
above. Similarly, §5's conclusion (no new `CHK-*` structural-validator rule required) is unaffected
by the complexity fix: iteration 1's `find_matching_join/2` was already total and honest for every
graph shape it can't resolve, and this rework does not change *which* shapes it can/can't resolve —
only how efficiently it resolves the shapes it already could. The one section this rework's
knock-on effects **do** land on is §4 (new test coverage now additionally needs the
`diamond_chain_graph/1` stress fixture, added above) and, naturally, §2 itself and §3's walkthrough,
both already revised.
