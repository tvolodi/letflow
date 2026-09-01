# Design: ISS-0400 — `collect_leaf_gateways/3` does not resolve a
# `PARALLEL_GATEWAY` nested inside a fork branch

**Issue:** ISS-0400 (`docs/issues/ISS-0400.yaml`), severity MINOR, discovered in `WF03-ISS0398-20260901`
**Diagnosis:** `handoffs/WF03-ISS0400-20260901/step-01-issue-fixer.json` `result.summary` (ISSUE-FIXER,
this run) — root cause, two reproductions, exact line numbers, read in full and relied on directly below.
**Requirement of origin:** REQ-051 (`lib/letflow/design/req051-parallel-gateway-split-join.md`), extended
by ISS-0398's own fix (`lib/letflow/design/iss0398-walk-to-gateway-fix.md`, whose §2.3/§6 named this
exact gap as out of scope and required the follow-up issue this design now resolves).
**Owner (implementer):** ELIXIR-DEV

**Iteration 2 (this revision):** CODE-DESIGN-VALIDATOR FAILED iteration 1's design at
`WF03-ISS0400-20260901` Step 2b (`handoffs/WF03-ISS0400-20260901/step-02b-code-design-validator.json`)
on a BLOCKER: iteration 1's `resolve_nested_split/3` (§2.3) reset `index`/`lowlink`/`stack`/`stack_set`/
`next_index` before folding over a nested split's own sibling branches — identical reset discipline to
`find_matching_join/2`'s own top-level fold — but `resolve_nested_split/3` is invoked **mid-flight**,
from inside an already-open outer-walk call frame (the node leading into the nested split has not
returned), not between top-level `find_matching_join/2` branches where ISS-0398 design §2.2.3 proves the
reset is safe *because* a top-level call's own stack is always fully unwound before it returns. The
validator constructed a concrete counterexample — `outer_split → A → inner_split` (`:PARALLEL_GATEWAY`,
`:split` role, out-degree 2), one of `inner_split`'s own branches (`inner_split → ia → A`) looping back
to `A`, the still-open ancestor — and traced it step by step to genuine, unbounded infinite recursion:
the reset wipes `A` out of `stack_set` before the nested fold starts, so the live back-edge `ia → A` is
no longer visible to step 2's on-stack check, `A` is re-explored as if fresh, its own edge back into
`inner_split` is followed again, `inner_split` is re-dispatched through `resolve_nested_split/3` again,
which resets again, forever. The validator also found iteration 1's §2.3 (specifies a reset) and §3.3
(claimed `stack`/`stack_set` are "shared across this recursive boundary exactly like `memo` is")
described two different, incompatible algorithms — the reset is what iteration 1 actually specified, and
the trace shows the reset, not the sharing, is what governs.

This revision replaces iteration 1's reset discipline at the `resolve_nested_split/3` boundary with a
genuinely different mechanism (revised §2.3): `resolve_nested_split/3` **never resets `stack`/
`stack_set`/`index`/`lowlink`** — it threads the outer walk's live Tarjan state through its own fold
completely unmodified, exactly the way `fold_outgoing_edges/4`'s own step-5 sibling-edge fold already
threads state across a branching node's own children (ISS-0398 design §2.2.2 step 5). The *only* place
a reset ever happens, in this revision or the last, is `find_matching_join/2`'s own top-level fold
between the *outer* split's own sibling branches (ISS-0398 design §2.2.2/§2.2.3, unchanged, untouched by
this design). §2.3 below re-derives why this is sound, §3.2 replaces iteration 1's worked example with
one that exercises a live nested-to-ancestor back-edge, and §3.3 is rewritten so it no longer contradicts
§2.3 — both now describe the same algorithm: full state sharing, no reset, at the
`resolve_nested_split/3` boundary. §4's fixture 3 is replaced with the validator's own exact
counterexample graph, traced to explicit, correct termination.
**Owned module:** `lib/letflow/engine/transition.ex` (`collect_leaf_gateways/3` and its private helpers
`explore_branching_node/3`, `fold_outgoing_edges/4`, `close_scc_or_defer/5`, `find_matching_join/2` —
all private functions inside `Letflow.Engine.Transition`)
**This document produces:** a replacement for `collect_leaf_gateways/3`'s step-4 `:PARALLEL_GATEWAY`
clause (transition.ex:934-936) that distinguishes a real join/pass-through `PARALLEL_GATEWAY` (keeps
today's immediate-terminal behavior, unchanged) from a nested-split `PARALLEL_GATEWAY` (out_degree > 1 —
resolved via a **recursive, memo-and-SCC-state-sharing** call into the same traversal machinery, before
the outer walk treats the result as a single leaf). Signatures, `@spec`/`@type` shapes, and precise prose
only — no implementation code, no function bodies, matching this project's design-gate convention and
ISS-0398's own design doc.

## 0. Sources read for this design

- `handoffs/WF03-ISS0400-20260901/step-01-issue-fixer.json` `result.summary` (full) — ISSUE-FIXER's root
  cause (transition.ex:934-936's unconditional `:PARALLEL_GATEWAY`-is-terminal clause), two direct
  reproductions (`{:error, {:no_matching_join_found, "outer_split"}}` in both), and the "what a fix needs
  to change" section this design implements.
- `lib/letflow/design/iss0398-walk-to-gateway-fix.md` (full, both pages) — the current SCC-memoized
  traversal this design extends, in particular:
  - §2.2.1 — **why plain node-keyed memoization is unsound under cycles with internal branching**, and
    why SCC-keyed memoization fixes it. This is the exact defect class this design's own §3 below checks
    the nested-resolution proposal against, per the handoff's explicit instruction.
  - §2.2.2 — the precise 5-step traversal (`collect_leaf_gateways/3` today) this design's step 4 replaces.
  - §2.2.3 — the termination/complexity argument (`O(nodes + edges)`) this design's §4 extends rather than
    replaces.
  - §2.3/§6 — the exact scope boundary this design closes: "a nested `PARALLEL_GATEWAY` split anywhere
    along any of a branch's paths... genuinely unsupported... required follow-up issue."
  - §2.5/§2.6 — `find_matching_join/2`'s own per-branch/cross-branch agreement rule and the
    `leaf_search_state()` shape/reset discipline this design's inner resolution reuses rather than
    reinvents.
- `lib/letflow/engine/transition.ex`, full current text of `dispatch_parallel_gateway/4` (694-724),
  `gateway_role/2` (730-741), `find_matching_join/2` (815-843), `collect_leaf_gateways/3` (918-942),
  `explore_branching_node/3` (955-975), `fold_outgoing_edges/4` (981-1004), `close_scc_or_defer/5`
  (1013-1035) — read directly from source, all line numbers confirmed against this reading (not trusted
  from the diagnosis's own numbers alone, though they matched).
- `docs/issues/ISS-0400.yaml` (full) — confirms severity MINOR, `related: [ISS-0398, REQ-051]`, and that
  this is the exact follow-up ISS-0398's design doc required.
- `handoffs/WF03-ISS0400-20260901/step-02b-code-design-validator.json` `result.summary` (full, this
  revision) — the BLOCKER finding this revision exists to fix: iteration 1's `resolve_nested_split/3`
  reset `index`/`lowlink`/`stack`/`stack_set`/`next_index` at a boundary where doing so destroys live
  back-edge detection for a still-open outer-walk ancestor, and the exact counterexample graph
  (`outer_split → A → inner_split`, with `inner_split`'s own branch `ia → A` looping back to `A`) traced
  step by step to genuine infinite recursion. This revision's §2.3, §3.2, §3.3, and §4 fixture 3 are
  rewritten against this trace directly, re-derived rather than re-asserted.
- `test/letflow/engine/parallel_gateway_test.exs` referenced (not re-read in full here — ISS-0398's design
  doc §3 already walked every existing AC1-AC6 assertion against the current traversal; this design's §5
  re-confirms none of that walkthrough is invalidated by the new step-4 clause for the non-nested case).

## 1. Problem restated precisely

`collect_leaf_gateways/3`'s step 4 (transition.ex:934-936):

```
%Node{node_type: :PARALLEL_GATEWAY} ->
  leaves = MapSet.new([{:gateway, node_id}])
  {:finished, leaves, put_leaf_memo(state, node_id, leaves)}
```

treats **any** node whose `node_type == :PARALLEL_GATEWAY` as an immediate terminal leaf, unconditionally
— it never inspects that node's own outgoing edges. This is exactly right when the node reached actually
*is* the branch's join (or a pass-through `PARALLEL_GATEWAY`, `gateway_role/2`'s `:join`/`:pass_through`
roles) — that is what lets `find_matching_join/2`'s cross-branch agreement check (§2.5 of the ISS-0398
design) work at all. It is wrong when the node reached is a **different**, nested `PARALLEL_GATEWAY`
**split** (`gateway_role/2`'s `:split` role, out_degree > 1) that lies inside one branch of the outer
split, ahead of that branch's own real join — the walk reports the nested split's own `node_id` as the
leaf and stops, never traversing into the nested split's own branches, never reaching the nested split's
own join, and never reaching whatever lies beyond it (possibly the outer join itself).

ISSUE-FIXER's two reproductions confirm the observed failure mode is a **hard, honest error** — not a
silent wrong answer: `{:error, {:no_matching_join_found, "outer_split"}}`, surfaced through
`Engine.create/2` as `{:error, {:activation_failed, {:no_matching_join_found, "outer_split"}}}` — because
the branch containing the nested split resolves to `{:gateway, "inner_split"}` while either (a) a sibling
branch resolves to `{:gateway, "outer_join"}` (disagreement) or (b) taken alone, `{:gateway,
"inner_split"}` is simply not the outer join id `find_matching_join/2` needs (ISSUE-FIXER's repro 2,
isolating branch 1). Both reproductions confirm `gateway_role/2`'s existing in/out-degree classification
(transition.ex:730-741, already used by `dispatch_parallel_gateway/4`) is exactly the distinguishing
signal this fix needs — a `:PARALLEL_GATEWAY` node's own `out_degree` computed the same way, reused, not
reinvented.

## 2. Fix shape — recursive, not iterative-unrolled

**Decision, stated explicitly (per the handoff's instruction that this not be waved at):** the inner
resolution is genuinely **recursive** — a nested split reached while resolving branch 1 of the outer split
may itself contain a doubly-nested split, and so on to arbitrary depth. §3 below gives the termination
argument for this; an iterative/worklist reformulation is not chosen because it would have to reimplement
the same call-stack-shaped bookkeeping `explore_branching_node/3`/`close_scc_or_defer/5` already provide
via `state.stack`, buying nothing — Elixir's BEAM has no shallow-recursion-depth hazard `mix` deployments
need to work around here, and `graph.ex`'s own `@max_nodes 500` cap (§3 below) bounds the recursion depth
by construction.

### 2.1 New leaf-outcome type — unchanged in shape, `:dead_end` meaning extended

`branch_leaf :: {:gateway, String.t()} | :dead_end` (transition.ex:845) is reused **unchanged**. This
design does not need a third variant: a nested split whose own resolution fails (§3.3 below) is folded
into `:dead_end`, not given a distinct leaf-outcome constructor — see §3.3's justification for why folding
rather than adding a new tag is the right call here specifically, not merely the convenient one.

### 2.2 Step 4 replacement — the new `:PARALLEL_GATEWAY` clause

Today's single unconditional clause (transition.ex:934-936) is replaced by two clauses, both still inside
`collect_leaf_gateways/3`'s own `case find_node(...)` dispatch (the same position, same `cond`/`case`
nesting level as today — this is not a new outer branch point, just a finer match on the existing
`%Node{node_type: :PARALLEL_GATEWAY}` clause):

```
@spec collect_leaf_gateways(Graph.t(), String.t(), leaf_search_state()) ::
        {leaf_search_result(), MapSet.t(branch_leaf()), leaf_search_state()}
```

(signature **unchanged** from today — same arity, same argument types, same return shape; this fix changes
only what happens *inside* the existing `%Node{node_type: :PARALLEL_GATEWAY}` match arm, not the function's
own contract, so every existing call site — `find_matching_join/2`'s fold, `fold_outgoing_edges/4`'s own
recursive call — needs no change at all.)

Inside that arm, on resolving `node_id` to a `%Node{node_type: :PARALLEL_GATEWAY} = gw_node`:

1. Compute `gw_node`'s role via the **existing** `gateway_role/2` (transition.ex:730-741, unchanged,
   reused verbatim — not reimplemented). This requires passing `definition_snapshot` through to the branch
   (already in scope as `collect_leaf_gateways/3`'s own first argument — no new argument needed).
2. **`gateway_role(definition_snapshot, gw_node) in [:join, :pass_through]`** (out_degree <= 1): this is a
   real candidate join or pass-through node — **keep today's exact behavior, byte-for-byte**: `leaves =
   MapSet.new([{:gateway, node_id}])`, memoize via `put_leaf_memo/3`, return `{:finished, leaves, state'}`.
   No change to this path at all — see §5 for why this is the regression-safety-critical case.
3. **`gateway_role(definition_snapshot, gw_node) == :split`** (out_degree > 1): this is a nested split —
   resolve it recursively via the new `resolve_nested_split/3` (§2.3 below) instead of stopping here.
4. **`gateway_role(definition_snapshot, gw_node) == :combined_unsupported`** (out_degree > 1 **and**
   in_degree > 1): fold this into the `:dead_end` case (§3.3 justifies why, rather than inventing a fourth
   outcome) — `dispatch_parallel_gateway/4` itself already refuses to dispatch through a
   `:combined_unsupported` node at runtime (`{:error, {:combined_split_join_not_supported, node.id}}`,
   transition.ex:721-722), so a branch whose lookahead walk merely *passes through* one during
   `find_matching_join/2`'s search should not succeed either — treating it as `:dead_end` makes the branch
   fail to resolve, which is the same honest, total `{:error, :no_matching_join}` outcome `dispatch_node/4`
   would eventually hit anyway once a token actually reached that node, just surfaced earlier and without a
   separate distinguishable error tag.

### 2.3 `resolve_nested_split/3` — the recursive inner resolution

```
@spec resolve_nested_split(Graph.t(), Node.t(), leaf_search_state()) ::
        {leaf_search_result(), MapSet.t(branch_leaf()), leaf_search_state()}
```

Called as `resolve_nested_split(definition_snapshot, gw_node, state)` from step 4's `:split` arm above,
where `gw_node` is the nested `:PARALLEL_GATEWAY` node just reached (its `node_id` is `gw_node.id`).
**Not** a wrapper around the external-facing `find_matching_join/2` (§2.6 explains why that function's own
signature/contract must stay untouched), and — **stated precisely, this is the mechanism this revision
replaces (see this document's own revision note at the top) — not a re-run of `find_matching_join/2`'s
own per-branch/cross-branch fold with its reset discipline copied over either.** The two folds only
*look* structurally identical (both walk a `:PARALLEL_GATEWAY`'s own outgoing edges and check
singleton/agreement); they differ in exactly the one property this revision turns on: whether the fold's
own call frame is a **top-level** entry point (safe to reset stack bookkeeping — ISS-0398 design §2.2.3's
unwound-stack proof, which applies only to a call that owns its own, freshly-started walk) or a
**mid-flight** continuation of a walk that is already, right now, in the middle of exploring an ancestor's
own outgoing edge (`resolve_nested_split/3`'s actual situation: it is called from inside step 4's `:split`
arm, which is itself inside whatever call frame reached `gw_node` in the first place — that caller has not
returned, and per ISS-0398 §2.2.2 step 5, that caller is sitting on `state.stack`/`state.stack_set` right
now, waiting on this very call to finish before it can compute its own `local_leaves`/`local_lowlink` and
decide whether its own SCC closes). Resetting stack bookkeeping at this boundary would erase exactly the
bookkeeping that caller's own eventual closure check depends on, and — as the validator's trace shows —
erase the mechanism (`stack_set` on-stack membership) that keeps a walk finite when a nested split's own
branch loops back to that caller. So instead, `resolve_nested_split/3`:

- **threads the *same* `state` the outer walk is already carrying, in full** — `state.memo` (§3.1
  restates why this is safe) **and, new in this revision, also `state.index`/`state.lowlink`/`state.stack`/
  `state.stack_set`/`state.next_index`, completely unmodified** — into and through its own fold over
  `gw_node`'s own sibling branches, and back out again. There is no reset step at this boundary at all,
  in either direction (neither before the fold starts nor between `gw_node`'s own sibling branches).
  Concretely: `resolve_nested_split/3`'s own fold over `gw_node`'s outgoing edges is not a second,
  independent Tarjan pass with its own numbering — it is a **direct continuation** of the same Tarjan pass
  the outer walk is already running, using the same `next_index` counter (so each of `gw_node`'s own branch
  nodes gets assigned the *next* unused index in the outer walk's own sequence, not a restarted `0`), the
  same `stack`/`stack_set` (so `gw_node`'s own branch nodes are pushed onto, and popped from, the *same*
  stack every other node on the current call chain — including `gw_node`'s own still-open ancestors like
  `A` — is already on), and the same `lowlink` map. This is precisely what makes a back-edge from inside
  `gw_node`'s own branches to an ancestor still open on the outer walk (§3.2's worked trace) behave
  identically to any other back-edge Tarjan's algorithm already knows how to handle: step 2's on-stack
  check (ISS-0398 design §2.2.2) fires exactly as it would for any other still-open node, because the
  ancestor genuinely still *is* on `stack_set` — nothing wiped it. `resolve_nested_split/3` introduces no
  new bookkeeping and no new case to the underlying step-1..step-5 dispatch at all; it is purely a
  **call-site convention** (§2.3's own fold below, and the continuation-past-the-inner-join step) layered
  on top of the *same* `collect_leaf_gateways/3` steps every other node in this traversal already goes
  through, one full call chain, no boundary in the Tarjan bookkeeping at all;
- **consequence for the SCC a nested split's branch closes into:** because `stack`/`stack_set`/`index`/
  `lowlink` are never reset at this boundary, a nested split's own branch node that loops back to an
  ancestor is treated by the algorithm as exactly what it structurally is — a member of the **same** SCC as
  that ancestor, discovered one level deeper in the call chain, precisely the way ISS-0398 §2.2.2 step 5's
  `local_lowlink = min(local_lowlink, child_lowlink)` propagation already handles a back-edge discovered
  several calls down from any node, nested-split-boundary or not. `resolve_nested_split/3` does not need
  its own closure logic, its own lowlink comparison, or its own notion of "this nested split's own SCC" —
  the ordinary step-5 closure check, running at whichever node turns out to be the SCC's actual root
  (possibly `gw_node` itself, possibly one of its branch nodes, possibly an ancestor several frames further
  up — the algorithm decides this the same way it always does, via `local_lowlink == index[node_id]`),
  closes it correctly without `resolve_nested_split/3` ever being aware that a "nested split boundary" was
  crossed at all. This is the load-bearing property the rest of this section and §3 build on: from the
  Tarjan machinery's own point of view, there is no such thing as a nested-split boundary — only nodes,
  edges, and one continuous stack;
The fold over `gw_node`'s own outgoing edges (§2.2's step-4 `:split` arm hands `gw_node`'s edges to this
fold one at a time, threading `state` from one to the next, exactly as ISS-0398 §2.2.2 step 5's own
sibling-edge fold does for any branching node) produces, per edge, the *same* three-way outcome any
`collect_leaf_gateways/3` call can produce — because each edge's target is resolved via an ordinary
`collect_leaf_gateways(definition_snapshot, edge.target, state)` call, no different in kind from any other
call this traversal makes:

- **a branch's target is `{:finished, #{{:gateway, id}}, state'}`** — an ordinary resolved leaf, folded
  into the agreement check exactly as `find_matching_join/2`'s own per-branch rule does (ISS-0398 §2.5):
  contributes `{:gateway, id}` toward the singleton-agreement question below.
- **a branch's target is `{:finished, #{:dead_end}, state'}` (or a non-singleton set)** — an ordinary
  failed path, folded toward `:dead_end` exactly as §3.3 (below) specifies.
- **a branch's target is `{{:open, child_lowlink}, leaves, state'}`** — a **live back-edge into a node
  still open somewhere on the current call chain** (§2.2.2 step 2's on-stack case, or a propagated
  still-open result from further down, exactly as ISS-0398 §2.2.2 step 5's own `local_lowlink = min(...)`
  propagation already handles for any branching node). This is the case iteration 1 could not reach
  correctly, because iteration 1's reset had already wiped the ancestor out of `stack_set` before this
  fold started. Under this revision, `stack_set` is untouched, so this case fires exactly when it should:
  `gw_node`'s own fold treats this branch's `leaves` (which step 2 guarantees is `MapSet.new()` — a live
  back-edge contributes no leaf of its own, only a lowlink signal, ISS-0398 §2.2.2 step 2) as contributing
  nothing to the agreement question, and — critically — **`resolve_nested_split/3` does not itself decide
  what this means for `gw_node`'s own closure.** It has no closure logic of its own (per the load-bearing
  property stated above): it simply returns `{{:open, child_lowlink}, leaves, state'}` for *this branch*
  up to whichever ordinary step-5 call frame is folding over `gw_node`'s own siblings — which, since
  `resolve_nested_split/3`'s own fold over `gw_node`'s branches is the direct analogue of that same
  step-5 fold, means `gw_node`'s own `local_lowlink` is pulled down by `min(local_lowlink, child_lowlink)`
  exactly as step 5 already specifies, and `gw_node`'s own closure check (`local_lowlink ==
  index[gw_node.id]`) — evaluated the ordinary way, not by `resolve_nested_split/3` specially — decides
  whether `gw_node` is its SCC's root or stays open and propagates `{:open, ...}` one level further up.
  This is not a new rule invented for the nested-split case; it is literally the existing step-5 rule,
  because `resolve_nested_split/3`'s fold over `gw_node`'s branches *is* a step-5 fold over `gw_node`'s
  branches (§3.2's worked trace makes this concrete against the validator's own counterexample).

**On agreement (every branch of `gw_node` either resolves to the *same* single `{:gateway,
inner_join_id}}`, or is a live-back-edge `{:open, _}` contributing no leaf, and at least one branch does
resolve to a finished `{:gateway, inner_join_id}}`):** does **not** stop at `inner_join_id` and report it
as the leaf. Instead, it **continues the walk past the inner join's own outgoing edge** — the diagnosis's
explicit requirement ("continue from that inner join's own outgoing edge, NOT stop and report the inner
split's id as a leaf"). Concretely: resolve `inner_join_id`'s own single outgoing edge
(`Enum.find(definition_snapshot.edges, &(&1.source == inner_join_id))` — a `:PARALLEL_GATEWAY` classified
`:join` or `:pass_through` by `gateway_role/2` has out_degree <= 1 by that classification's own
definition, so "the" outgoing edge is unambiguous when one exists) and recurse
`collect_leaf_gateways(definition_snapshot, edge.target, state)` on **that** edge's target — the result of
*that* recursive call (which may itself be another `:PARALLEL_GATEWAY`, nested split or not, another
`:EXCLUSIVE_GATEWAY` chain, anything `collect_leaf_gateways/3` already handles) becomes
`resolve_nested_split/3`'s own return value for `gw_node`, tagged/threaded exactly as any other
step-4-successor call's result would be — including, if that continuation call itself returns
`{:open, lowlink}` (it recursed into a node still open further up the *outer* walk's own chain, past
`gw_node` entirely), propagating that `{:open, lowlink}` onward unchanged; there is nothing
nested-split-specific about this propagation either. If `inner_join_id` has **zero** outgoing edges (a
`:PARALLEL_GATEWAY` join with no continuation — a legal but unusual shape, e.g. it is itself the graph's
terminal point via some other path): treat as `:dead_end` (same §3.3 folding rationale — there is no leaf
to report past a join that goes nowhere).

**On disagreement or dead end (`gw_node`'s own branches don't singleton-agree among their finished
`{:gateway, _}` values, or every branch is `:dead_end`/non-agreeing with no live back-edge to explain the
gap, or `gw_node`'s own recursive resolution bottoms out in a **deeper** nested split that itself fails to
resolve):** returns `{:finished, MapSet.new([:dead_end]), state'}` for this whole `resolve_nested_split/3`
call — §3.3 states this precisely and justifies folding rather than adding a new error tag. (The
all-branches-are-live-back-edges-with-no-finished-agreement sub-case — every one of `gw_node`'s own
branches resolves to `{:open, _}` and none to a finished `{:gateway, _}}` — is handled by the ordinary
step-5 rule too, not a special case here: `gw_node`'s own `local_leaves` stays `MapSet.new()`, its
`local_lowlink` is pulled down by whichever branch's `child_lowlink` is smallest, and `gw_node` itself
returns `{:open, local_lowlink}` rather than either a `:dead_end` or an agreement outcome — it is not yet
this call's job to decide dead-end-vs-agreement while its own SCC is still open; that decision only
happens once whichever ancestor is the SCC's actual root closes it, per the ordinary step-5 closure check.)

**Not memoized under `gw_node.id` directly as a single MapSet the way step-4's `:join`/`:pass_through`
branch is** (§3.1 explains the memo-key subtlety this requires — memoizing here needs care distinct from
the simple "cache the leaf set under this node's id" scheme used everywhere else in this traversal).

### 2.4 What `resolve_nested_split/3` returns, precisely

Its return shape is **identical** to `collect_leaf_gateways/3`'s own (`{leaf_search_result(),
MapSet.t(branch_leaf()), leaf_search_state()}`), because step 4's `:split` arm (§2.2) simply returns
whatever `resolve_nested_split/3` returns — no repackaging. This is deliberate: the caller of
`collect_leaf_gateways(definition_snapshot, node_id, state)` where `node_id` happens to resolve to a nested
split cannot tell (and does not need to tell) that a recursive inner resolution happened underneath — the
`{tag, leaves, state}` triple it gets back is exactly as if `collect_leaf_gateways/3` had simply "seen
through" the nested split to whatever lies past its own join, which is precisely the desired external
behavior.

## 3. Termination, complexity, and memo-key soundness

The handoff requires this section to explicitly re-examine ISS-0398's own Tarjan-SCC memoization for
compatibility with this recursive extension, addressing the same risk class CODE-DESIGN-VALIDATOR caught
as a BLOCKER on ISS-0398 (a memo-key-unsoundness bug under legal cycles, ISS-0398 design §2.2.1). This
section takes that instruction at face value: it does not merely assert soundness, it re-derives it against
the two specific attacks that broke iteration 2 there.

### 3.1 Does the outer memo compose safely with a recursive inner resolution?

**The concrete risk, stated in ISS-0398's own terms:** ISS-0398 §2.2.1's defect was that a node's
forward-reachable-leaf-gateway set is **not** a pure function of `node_id` alone whenever that node sits on
a cycle with internal branching — because plain per-node memoization caches whichever partial view the
*first* DFS to visit that node happened to see, and different entry points see different partial views.
The fix there was to memoize per-SCC (a purely structural, entry-point-independent unit) instead of
per-node.

**Does introducing a nested nested-split resolution reopen this?** No — and the argument is not "it
probably doesn't," it is a structural one: **`resolve_nested_split/3` never writes to `state.memo` under
the nested split's own `node_id` (`gw_node.id`) directly with its own aggregate.** This is the key design
choice, stated explicitly rather than left implicit:

- Recall step 4's two surviving cases (§2.2): a `:PARALLEL_GATEWAY` reached with `gateway_role ==
  :join`/`:pass_through` is memoized under its own `node_id` exactly as before (transition.ex:934-936,
  unchanged) — that memo entry's soundness is exactly ISS-0398's own (a `:PARALLEL_GATEWAY` is never
  pushed onto `state.stack`, so it can never itself be part of a larger SCC or be visited via a live
  back-edge — ISS-0398 design §2.2.2 step 4's own note, unaffected by this fix).
- A `:PARALLEL_GATEWAY` reached with `gateway_role == :split` (the new case) is **not** given its own
  `memo[gw_node.id]` entry by `resolve_nested_split/3` mapping to "whatever lies past the inner join." The
  reason this matters: unlike a join/pass-through gateway, a nested split's own **correct** leaf-value truly
  is context-independent in the relevant sense (its own branches are resolved via a fresh per-branch Tarjan
  pass exactly like any `find_matching_join/2` call, so *that* part is sound by direct reuse of ISS-0398's
  own already-proven machinery) — but memoizing "the value past `gw_node.id`" under the key `gw_node.id`
  itself would conflate two different questions: "what is `gw_node`'s own SCC-aggregate leaf set" (which,
  if `gw_node` is later reached again as a plain graph node by some *other* path not going through this
  nested-split logic — impossible today, since every reference to a `:PARALLEL_GATEWAY` node id goes
  through step 4 uniformly, but keeping the invariant explicit rather than relying on that coincidence) vs.
  "what does resolving-and-continuing-past `gw_node` yield." Instead:
  - Each of the nested split's own branch destinations (i.e., every node reachable by following one of
    `gw_node`'s own outgoing edges) is memoized individually, under **its own** `node_id`, by the ordinary
    recursive `collect_leaf_gateways/3` calls `resolve_nested_split/3` makes internally to resolve each
    branch — no new memoization machinery, just the existing per-node/per-SCC scheme applied to those
    nodes exactly as it already is for any other subgraph.
  - The inner join's own downstream continuation (the node past `inner_join_id`'s own outgoing edge) is
    likewise memoized under **its own** `node_id`, by the ordinary recursive `collect_leaf_gateways/3` call
    `resolve_nested_split/3` makes to resolve it (§2.3's last bullet).
  - `resolve_nested_split/3` itself is a **pure pass-through of return values already computed and
    memoized by ordinary means** — it introduces no new memo key, so it cannot introduce a new place for
    the ISS-0398 defect class to recur. The only "new" cached state after a call to
    `resolve_nested_split/3` returns is exactly the same kind of state a plain deeper `collect_leaf_gateways/3`
    recursion would have produced if the nested split had not been there at all (i.e., if the graph were
    flattened by removing the nested split/join pair and rewiring its branches' upstream node directly to
    whatever lies past the inner join) — this is the precise sense in which "seeing through" a nested split
    (§2.4) is the correct mental model: memoization behaves exactly as if the nested split were transparent.
- **Consequence for order-independence:** because no new memo key is introduced, the ISS-0398 §2.2.1
  counterexample shape (two different top-level branches entering a shared cycle at different members)
  cannot be reconstructed *at the nested-split boundary* — the nested split's own inner cycle-with-branching
  risk (if `gw_node`'s own branches themselves contain a cycle with internal branching) is handled by
  `resolve_nested_split/3`'s reuse of the *exact same* SCC-closure machinery (§2.2.2/§2.2.3 of the ISS-0398
  design, `explore_branching_node/3`/`fold_outgoing_edges/4`/`close_scc_or_defer/5`, all reused verbatim,
  not reimplemented) — so any cycle-with-branching inside the nested split's own subgraph is already covered
  by ISS-0398's own proof, applied recursively to a smaller subgraph. Nothing about crossing the
  split/resolve/continue boundary this design adds introduces a *new* cycle-detection mechanism that could
  itself be unsound; it is the same mechanism, called one level deeper.

### 3.2 Does sharing `state` in full (memo *and* stack bookkeeping, no reset at all) between outer and inner resolution introduce a new hazard?

**Considered and rejected (iteration 1's own mechanism, FAILED by CODE-DESIGN-VALIDATOR): resetting
`index`/`lowlink`/`stack`/`stack_set`/`next_index` before `resolve_nested_split/3`'s own fold, while
sharing only `memo`.** This is `find_matching_join/2`'s own top-level reset discipline (ISS-0398 §2.2.2/
§2.2.3), and it is sound *there* specifically because ISS-0398 §2.2.3 proves a top-level call's own stack
is always fully unwound by the time it returns — nothing is left "open" for the next top-level branch to
inherit. `resolve_nested_split/3` is not a top-level call: it fires from inside step 4's `:split` arm,
which is itself inside whatever call frame reached `gw_node` in the first place, and that caller's own SCC
may still be open (on `stack`/`stack_set`, not yet closed) at the exact moment `resolve_nested_split/3`
is entered. Resetting `stack`/`stack_set` at that point erases the open caller's own on-stack membership,
so step 2's on-stack check (ISS-0398 §2.2.2) can no longer see it — a live back-edge from inside `gw_node`'s
own branches back to that caller is misread as "fresh, unvisited node" instead of "still-open ancestor,"
and the caller is re-explored, re-recursing back into `gw_node`, forever. CODE-DESIGN-VALIDATOR's own
counterexample (`outer_split → A → inner_split`, `inner_split`'s own branch `ia → A` looping back to `A`,
full trace in `handoffs/WF03-ISS0400-20260901/step-02b-code-design-validator.json` `result.summary`) is
exactly this failure, traced step by step to genuine infinite recursion. This mechanism is rejected.

**Also considered and rejected: giving `resolve_nested_split/3` a fresh, fully isolated
`leaf_search_state()` (fresh `memo` too, not just fresh stack bookkeeping).** This would sidestep the
reset-boundary problem above by never sharing anything, but reopens exactly the exponential-blowup class
ISS-0398's iteration-1-to-2 rework fixed (SECURITY-REVIEWER's BLOCKER INV-8 finding, ISS-0398 design's own
opening note): a diamond-chain-shaped nested split reached independently from `k` different outer branches
(or reached `k` times while resolving one nested split's own diamond-chain-shaped internal branches) would
recompute its entire downstream subgraph from scratch every time. Rejected for the same reason iteration 1
already rejected it (§3.2 there), unchanged by this revision.

**Decision (this revision, replacing iteration 1's reset-except-memo mechanism): `resolve_nested_split/3`
receives and returns the exact same `state` value the caller already holds — `memo`, `index`, `lowlink`,
`stack`, `stack_set`, and `next_index` all included, none of them reset — threading it exactly as
`fold_outgoing_edges/4` already threads `state` across a plain branching node's own sibling edges
(ISS-0398 §2.2.2 step 5, transition.ex:987-1004).** `resolve_nested_split/3`'s own fold over `gw_node`'s
own branches is not a second, independent thing that merely *resembles* a step-5 fold — per §2.3 above, it
*is* one: the same `Enum.reduce` shape, over `gw_node`'s own outgoing edges, threading the same `state`,
assigning indices from the same `next_index` counter, pushing onto and popping from the same `stack`/
`stack_set`. There is exactly one Tarjan pass per top-level `find_matching_join/2` branch call, and it runs
uninterrupted through any number of nested-split boundaries that branch's own walk happens to cross —
`resolve_nested_split/3` is a call-site convention for "then continue past the inner join" layered on top
of that one pass, not a second pass.

**Does sharing everything (no reset at all) across this new recursive boundary reopen ISS-0398 §2.2.1's
counterexample, or introduce a new one?** No — and unlike iteration 1's claim, this is not asserted only
for the memo: **there is nothing left at the `resolve_nested_split/3` boundary that could reopen it,
because there is no longer a boundary in the Tarjan bookkeeping at all.** ISS-0398 §2.2.1's original defect
was specific to plain *node-keyed* memoization conflating two different partial views of one SCC seen from
different entry points — §2.2.2's SCC-closure scheme (unchanged, reused verbatim, not reimplemented by this
design) already closes that gap for every cycle a single continuous Tarjan pass discovers, regardless of
how many nested-split boundaries the pass crosses while discovering it, because the pass does not know or
care that a boundary was crossed (§2.3's load-bearing property, restated: "no such thing as a nested-split
boundary — only nodes, edges, and one continuous stack"). The *new* risk this revision must rule out
instead — the one the reset-except-memo mechanism actually got wrong — is not memo-key soundness, it is
**stack-liveness soundness**: does every node that is genuinely still open on the current call chain stay
visible to step 2's on-stack check for exactly as long as it is genuinely open, with no boundary silently
hiding it? Under this revision's no-reset mechanism, `stack`/`stack_set` are literally the same map/set
values throughout — a node pushed before entering `resolve_nested_split/3` is still on `stack_set` while
`resolve_nested_split/3` runs, and stays there until its own call frame (wherever it is, however many
nested-split boundaries away) actually returns and pops it, exactly as it would if no nested split were
involved at all. There is no operation in this revision's mechanism that ever removes a node from
`stack_set` before its own call frame returns — the only two operations that ever touch `stack`/`stack_set`
are the ordinary step-5 push (on entering a fresh node) and the ordinary step-5 closure-check pop (once a
node's own SCC root closes), both entirely unchanged from ISS-0398's own machinery, both never invoked by
anything `resolve_nested_split/3` itself does beyond making ordinary `collect_leaf_gateways/3` calls.
**What must NOT happen, stated as an explicit invariant for ELIXIR-DEV to preserve, replacing iteration 1's
now-retracted "reset stack bookkeeping between the nested split's own sibling branches" instruction:** a
call site that resets *any* of `state`'s fields — `memo`, `index`, `lowlink`, `stack`, or `stack_set` — on
entry to or between iterations of `resolve_nested_split/3`'s own fold would reopen either the
exponential-blowup class (if `memo` is reset) or this revision's own fixed defect (if any of the four
stack-bookkeeping fields are reset) — `resolve_nested_split/3` must thread `state` through as a single,
untouched value, full stop, the same way an ordinary step-5 sibling-edge fold already does for any other
branching node's own children.

**Worked micro-example (the non-cyclic case, carried forward from iteration 1, re-traced under this
revision's no-reset mechanism), following the diagnosis's own repro 1 shape (`outer_split` → branch 1 →
`pre` → `inner_split` → `{inner_a, inner_b}` → `inner_join` → `post` → `outer_join`; branch 0 →
`outer_join` directly):**

`find_matching_join(definition_snapshot, outer_split_node)` starts `state_0 = fresh_leaf_search_state()`
(`memo = %{}`, `next_index = 0`). Branch 0 (`edge.target = "outer_join"`): `collect_leaf_gateways(g,
"outer_join", state_0)` → step 4, `gateway_role("outer_join") == :join` (in_degree 2: from branch 0
directly and from branch 1's `post` node; out_degree 1, to `"e"`) → immediate terminal (a
`:PARALLEL_GATEWAY` is never pushed onto `stack`, §2.2.2 step 4, so it never consumes an index at all) —
`leaves = #{{:gateway,"outer_join"}}`, `memo["outer_join"]` written. Branch 1 begins: per
`find_matching_join/2`'s own top-level reset (ISS-0398 §2.2.2/§2.2.3, unchanged, the *only* reset that
still exists anywhere in this design) `index`/`lowlink`/`stack`/`stack_set`/`next_index` reset to
empty/`0` — `memo["outer_join"]` survives. `collect_leaf_gateways(g, "pre", state)`: `"pre"` fresh
(`index = 0`, pushed) → ordinary single-edge chain (step 5) → recurse into `"inner_split"`: fresh
(`index = 1`, pushed) → step 4, `gateway_role("inner_split")`: out_degree 2 (to `inner_a`, `inner_b`),
in_degree 1 (from `pre`) → **`:split`** → `resolve_nested_split(g, inner_split_node, state)` fires, with
`state` exactly as `"inner_split"`'s own call frame holds it right now — `stack = ["inner_split", "pre"]`,
`stack_set = #{"inner_split", "pre"}`, `next_index = 2`, **no reset**. That call folds over
`inner_split`'s own 2 edges, continuing the *same* index sequence: edge to `inner_a` → fresh (`index = 2`,
pushed onto the *same* stack, now `["inner_a", "inner_split", "pre"]`) → single-edge chain to
`inner_join` → step 4, `gateway_role("inner_join") == :join` (in_degree 2, out_degree 1) → terminal,
`leaves = #{{:gateway,"inner_join"}}`, `memo["inner_join"]` written (no stack push for a `:PARALLEL_GATEWAY`
terminal, §2.2.2 step 4). Back in `inner_a`: `local_lowlink` stays `2` (finished child) → closure check
`2 == index["inner_a"] = 2` → closes, pop `inner_a`, `memo["inner_a"]` written, `stack` back to
`["inner_split", "pre"]`. Edge to `inner_b` (state now carries `memo["inner_join"]`, `memo["inner_a"]`) →
fresh (`index = 3`, pushed) → single-edge chain to `inner_join` → **step-1 memo hit**, O(1), no recursion,
no stack interaction. `inner_b` closes trivially (`3 == 3`), pop, `stack` back to `["inner_split", "pre"]`.
Both branches singleton-agree on `{:gateway,"inner_join"}}` → `resolve_nested_split/3`'s inner fold
succeeds with `inner_join_id = "inner_join"`. Per §2.3's continuation step: resolve `"inner_join"`'s own
single outgoing edge (target `"post"`) and recurse `collect_leaf_gateways(g, "post", state)` → `"post"`
fresh (`index = 4`, pushed onto `["post", "inner_split", "pre"]`) → single-edge chain → recurse into
`"outer_join"` → **step-1 memo hit** (written by branch 0 above, no stack interaction for a
`:PARALLEL_GATEWAY` terminal regardless) → `{:finished, #{{:gateway,"outer_join"}}, state}`. Back in
`"post"`: closes trivially (`4 == 4`), pop. This becomes `resolve_nested_split/3`'s own return value for
`gw_node = inner_split_node`; back in `"inner_split"`'s own call frame (§2.2's step-4 `:split` arm, a pure
pass-through — `"inner_split"` was pushed at `index = 1` before `resolve_nested_split/3` was ever called,
and is still on `stack` right now): `local_leaves = #{{:gateway,"outer_join"}}`, `local_lowlink` stays `1`
(the continuation's own result was `:finished`, not `:open` — no lowlink propagation needed) → closure
check `1 == index["inner_split"] = 1` → closes, pop, `memo["inner_split"] = #{{:gateway,"outer_join"}}`
(**not** `#{{:gateway,"inner_split"}}`) — correctly "seeing through" the nested split, `stack` back to
`["pre"]`. This propagates back up through `"pre"` unchanged (union of a single finished child, closes at
`0 == 0`, pop, `stack` empty) to branch 1's own top-level result: `#{{:gateway,"outer_join"}}}` — the
**same** singleton branch 0 produced. Cross-branch agreement (§2.5, unchanged) passes → `find_matching_join/2`
returns `{:ok, "outer_join"}`. This is exactly the outcome ISSUE-FIXER's repro 1 shows is currently missing
(today: `{:error, {:no_matching_join_found, "outer_split"}}}`) — and it is produced with `stack` correctly
empty at the end of branch 1's own top-level call, confirming ISS-0398 §2.2.3's unwound-stack property
(needed for the *next* top-level branch's own reset to be safe) still holds even though this branch's own
walk crossed a nested-split boundary partway through — nothing about crossing that boundary left anything
open behind.

**Worked trace against CODE-DESIGN-VALIDATOR's own counterexample (the cyclic, mid-flight-ancestor case —
the shape this revision exists to fix), reproduced exactly as specified in
`handoffs/WF03-ISS0400-20260901/step-02b-code-design-validator.json` `result.summary`:** graph —
`outer_split` (`:PARALLEL_GATEWAY`, out_degree 2): branch 0 direct to `outer_join`; branch 1:
`outer_split → A → inner_split` (`:PARALLEL_GATEWAY`, out_degree 2, `:split` role) → edge a:
`inner_split → ia → A` (back-edge to `A`); edge b: `inner_split → ib → inner_join`
(`:PARALLEL_GATEWAY`, `:join` role) → `post → outer_join`.

`find_matching_join(g, outer_split_node)`, branch 0 as before: `memo["outer_join"]` written, stack empty
again. Branch 1 begins, top-level reset applies (the only reset in this design): `index = %{}`,
`lowlink = %{}`, `stack = []`, `stack_set = #{}`, `next_index = 0`, `memo` carries `"outer_join"` forward.

1. `collect_leaf_gateways(g, "A", state)`: `A` fresh — `index["A"] = 0`, `lowlink["A"] = 0`, pushed,
   `stack = ["A"]`, `stack_set = #{"A"}`, `next_index = 1`.
2. `A`'s single outgoing edge → recurse into `"inner_split"`: fresh — `index["inner_split"] = 1`,
   `lowlink["inner_split"] = 1`, pushed, `stack = ["inner_split", "A"]`, `stack_set = #{"A",
   "inner_split"}`, `next_index = 2`.
3. Step 4: `gateway_role("inner_split")` — out_degree 2 (edges to `ia`, `ib`), in_degree 1 (from `A`) →
   **`:split`** → `resolve_nested_split(g, inner_split_node, state)` fires with `state` exactly as it
   stands right now — **`stack_set` still contains `"A"`, unchanged, because this revision's
   `resolve_nested_split/3` performs no reset of any kind (§2.3, §3.2 above).** This is the exact point
   iteration 1's reset destroyed; this revision does not touch it at all.
4. `resolve_nested_split/3`'s fold over `inner_split`'s own 2 edges, continuing the same index sequence,
   same stack:
   - Edge a, target `ia`: fresh — `index["ia"] = 2`, `lowlink["ia"] = 2`, pushed, `stack = ["ia",
     "inner_split", "A"]`, `stack_set = #{"A", "inner_split", "ia"}`, `next_index = 3`. `ia`'s own single
     outgoing edge → recurse into `"A"`: **step 1, memo hit? No, `"A"` is not in `memo` (its SCC has not
     closed).** **Step 2, on-stack check: is `"A"` in `state.stack_set`? Yes — `stack_set` still contains
     `"A"`, because nothing reset it.** This is the load-bearing difference from iteration 1: return
     `{{:open, index["A"] = 0}, MapSet.new(), state}` — a genuine, correctly-detected live back-edge, not
     a false "fresh node." No new call into `"A"`'s own body, no re-exploration of `"A"`'s own outgoing
     edge, no recursion back into `"inner_split"` a second time. Back in `ia`: `local_leaves = ∅` (the
     back-edge contributed no leaf, §2.2.2 step 2's semantic rule), `local_lowlink = min(2, 0) = 0`.
     Closure check: `0 ≠ index["ia"] = 2` → **not** a root, `ia` stays on `stack`. Return `{{:open, 0},
     ∅, state}` for this branch.
   - Edge b, target `ib` (state carries the same `stack`/`stack_set`/`memo` forward, `ia` still on stack):
     fresh — `index["ib"] = 3`, pushed, `stack = ["ib", "ia", "inner_split", "A"]`, `next_index = 4`.
     `ib`'s single edge → recurse into `"inner_join"` → step 4, `:PARALLEL_GATEWAY`, `:join` role,
     immediate terminal (no stack push) — `leaves = #{{:gateway,"inner_join"}}`, `memo["inner_join"]`
     written. Back in `ib`: `local_lowlink` stays `index["ib"] = 3` (finished child) → closure check
     `3 == 3` → `ib` is its own SCC root, closes, pop, `memo["ib"] = #{{:gateway,"inner_join"}}}`,
     `stack` back to `["ia", "inner_split", "A"]`. Return `{:finished, #{{:gateway,"inner_join"}}, state}`
     for this branch.
5. Back in `resolve_nested_split/3`'s own fold over `gw_node = inner_split`: branch a gave
   `{{:open, 0}, ∅, state}`, branch b gave `{:finished, #{{:gateway,"inner_join"}}, state}`. Per the
   revised §2.3 rule for this exact mix (a live back-edge branch plus an agreeing finished branch): the
   open branch contributes no leaf and folds toward `gw_node`'s own `local_lowlink` via
   `min(local_lowlink, child_lowlink)`; the finished branch supplies the singleton `{:gateway,
   "inner_join"}}` needed for the "on agreement" case to fire. `inner_split`'s own `local_leaves =
   #{{:gateway,"inner_join"}}`, `local_lowlink = min(index["inner_split"] = 1, 0) = 0` (pulled down by
   `ia`'s own propagated `0`). Per §2.3's continuation step, resolve `"inner_join"`'s own outgoing edge
   (target `"post"`) and recurse: `post` fresh — `index["post"] = 4`, pushed, `stack = ["post", "ia",
   "inner_split", "A"]`, `next_index = 5` → single-edge chain → recurse into `"outer_join"` → **step-1
   memo hit** (written by branch 0) → `{:finished, #{{:gateway,"outer_join"}}, state}`. Back in `post`:
   closes trivially (`4 == 4`), pop, `stack` back to `["ia", "inner_split", "A"]`. This continuation
   result (`:finished`, `#{{:gateway,"outer_join"}}}`) becomes `resolve_nested_split/3`'s own return value
   for `inner_split` — **but `inner_split`'s own `local_lowlink` computed one step earlier (`0`, pulled
   down by `ia`'s back-edge to `A`) is what step 4's `:split` arm must propagate, not the continuation
   call's own separate `:finished` tag** — restated precisely so this is not left ambiguous: the tag
   `resolve_nested_split/3` returns for `inner_split`'s own call frame is `{{:open, 0}, #{{:gateway,
   "outer_join"}}}, state}` — `:open` because `inner_split`'s own closure check (`local_lowlink = 0 ≠
   index["inner_split"] = 1`) fails, exactly as any ordinary step-5 node whose fold absorbed a
   still-open child would; the `:finished` continuation call supplies `local_leaves`, but does not by
   itself decide `inner_split`'s own closure — `inner_split`'s own lowlink, not the continuation's, governs.
   `inner_split` stays on `stack` (`["ia", "inner_split", "A"]`), not popped, no memo entry written for it.
6. Back in `"A"`'s own call frame (step 4's `:split` arm is a pure pass-through, §2.4 — `A`'s own fold
   receives whatever `resolve_nested_split/3` returned for `inner_split` as the result of `A`'s single
   outgoing edge): child tag is `{:open, 0}` → `A`'s `local_leaves = MapSet.union(∅, #{{:gateway,
   "outer_join"}}}) = #{{:gateway,"outer_join"}}}`; `local_lowlink = min(index["A"] = 0, 0) = 0`. Closure
   check: `0 == index["A"] = 0` → **`A` is its own SCC's root.** Pop `stack` (`["ia", "inner_split", "A"]`)
   down through and including `A`: pops `ia`, `inner_split`, `A` (three members — the genuine SCC this
   graph contains, `{A, inner_split, ia}`, closed correctly, in one pass, the *first* time any node on it
   is fully explored). Write `memo["ia"] = memo["inner_split"] = memo["A"] = #{{:gateway,"outer_join"}}}`
   — one shared, correct aggregate for every member. Return `{:finished, #{{:gateway,"outer_join"}}},
   state}` up to `A`'s own caller (`outer_split`'s branch-1 fold).
7. Branch 1's own top-level result: `#{{:gateway,"outer_join"}}}` — the **same** singleton branch 0
   produced. `stack` is empty (`A`, `inner_split`, and `ia` were all popped in step 6; `ib`, `post` were
   popped earlier in steps 4–5) — ISS-0398 §2.2.3's unwound-stack property holds for this branch too,
   confirming the *next* top-level branch's own reset (if there were one) would still be safe. Cross-branch
   agreement passes → `find_matching_join/2` returns `{:ok, "outer_join"}`.

**Explicit termination and correctness conclusion:** the walk visits `A`, `inner_split`, `ia`, `ib`,
`inner_join`, `post`, `outer_join` — **each exactly once as a fresh (step-5 or step-4) exploration** — and
`resolve_nested_split/3` is entered **exactly once**, for `inner_split`, never re-entered. The back-edge
`ia → A` is detected correctly on its first (and only) encounter via the ordinary step-2 on-stack check,
because `stack_set` was never reset and genuinely still contained `"A"` at the moment `ia`'s own edge was
followed. No node is ever re-explored as "fresh" after having already been pushed, so no unbounded regress
of the kind iteration 1's trace demonstrated can occur — this is not merely "did not happen in this
trace," it follows from the same structural argument §3.4 below restates: every fresh exploration consumes
one previously-unused `node_id`, `definition_snapshot.nodes` is finite, and this revision's mechanism adds
no operation that could ever cause a previously-pushed, not-yet-popped node to be pushed a second time (the
only way to be re-explored as "fresh" is to be neither in `memo` nor in `stack_set`, and this revision never
removes a node from `stack_set` before its own call frame pops it).

### 3.3 Nested-split resolution failure: propagation as `:dead_end`, not a new error reason

**Decision, made explicitly (per the handoff's requirement that this not be left ambiguous): a nested
split's own resolution failure (no singleton agreement among `gw_node`'s own branches — e.g. one of
`inner_a`/`inner_b` dead-ends without reaching `inner_join`, or `inner_split`'s own branches disagree on
which gateway they reach, or `inner_join`'s own continuation itself hits a `:dead_end` or a further-failing
doubly-nested split) is folded into the existing `:dead_end` `branch_leaf()` variant — it does *not* get
its own distinct error-reason constructor.**

**Why folding is correct here, not merely convenient — three reasons:**

1. **`branch_leaf()`'s own purpose is "what did following this one path forward from the split ultimately
   yield," and `find_matching_join/2`'s agreement rule (ISS-0398 design §2.5) already treats every non-`{:gateway,
   _}` outcome uniformly** — a plain dead end (`:END`, unresolved `node_id`, zero-outgoing-edges node) and
   an ambiguous/failed sub-resolution are both, from the outer branch's perspective, "this path did not
   yield a usable single gateway id." Distinguishing *why* a path failed to resolve is not information
   `find_matching_join/2`'s own caller (`dispatch_parallel_split/4`, transition.ex:772-774) currently
   surfaces for **any** failure mode — it already collapses every internal disagreement/dead-end shape into
   one external `{:error, {:no_matching_join_found, node.id}}`, naming only the *outer* split node, never
   the specific internal path or node that caused the failure. A new nested-split-specific error reason
   would be strictly more information than every other failure mode in this same function already provides,
   which is inconsistent rather than an improvement.
2. **A distinct new reason would need to survive being unioned with sibling paths' plain `:dead_end`
   results inside the *same* `MapSet.t(branch_leaf())`** (step 5/`fold_outgoing_edges/4`'s `MapSet.union`
   over a branching node's own multiple children) — e.g. if `inner_split` is reached via one path of an
   `:EXCLUSIVE_GATEWAY` while a sibling path of that same `:EXCLUSIVE_GATEWAY` hits a plain `:END`, both
   outcomes need to combine into one non-singleton set that correctly fails the branch either way. Reusing
   `:dead_end` for both means the *existing* non-singleton-or-not-`{:gateway,_}` check (§2.5, unchanged)
   handles this automatically, with no new case to add to that rule.
3. **No acceptance criterion or existing caller needs the distinction.** `dispatch_parallel_split/4`'s own
   `case find_matching_join(...)` (transition.ex:772-774) only ever branches on `{:ok, join_node_id}` vs.
   `{:error, :no_matching_join}` — it has no shape today that could carry "which internal node caused the
   failure," and this design does not propose adding one (that would be a `find_matching_join/2`
   signature change, out of scope for a MINOR-severity nested-resolution fix, and not requested by
   ISS-0400's own acceptance criteria).

**What this means concretely for `resolve_nested_split/3`'s own contract — restated to agree with §2.3
exactly, not merely alongside it (this paragraph is the fix for the internal §2.3/§3.3 contradiction
CODE-DESIGN-VALIDATOR found in iteration 1, where §2.3 specified a reset and this section separately
claimed sharing — this revision's §2.3 and this section now describe the one mechanism):** two genuinely
different outcomes must be kept distinct, and §2.3 above already draws the line precisely:

- **Whenever `gw_node`'s own fold reaches a clean verdict with nothing left open** — every branch is
  either a finished `{:gateway, _}}` (with singleton agreement among them) or a finished `:dead_end`/
  non-agreeing value, and *none* of `gw_node`'s own branches returned `{:open, _}}` — and that verdict is
  disagreement/dead-end (not agreement): `resolve_nested_split/3` returns `{:finished, MapSet.new([:dead_end]),
  state'}` for `gw_node`, exactly as before — **memoized under nothing new** (§3.1 — no `memo[gw_node.id]`
  entry is written for this failure case either; the nodes that *were* successfully resolved along the way
  keep their own individually-correct memo entries, since a node's own SCC-aggregate leaf value is
  unaffected by what a *different*, sibling branch does with it). This is an ordinary, fully-closed-SCC
  failure — `gw_node`'s own closure check passed (`local_lowlink == index[gw_node.id]`), so there is
  nothing left open for any caller further up to account for.
- **Whenever any of `gw_node`'s own branches returns `{:open, lowlink}}` (a live back-edge into a node
  still open somewhere on the *current* call chain — possibly an outer-walk ancestor like `A` in §3.2's
  cyclic trace, possibly a node inside `gw_node`'s own subgraph that itself loops back further):**
  `resolve_nested_split/3` does **not** force a premature `:finished`/`:dead_end` verdict — it cannot,
  because `gw_node`'s own SCC has not actually closed yet (its true root is still further up the call
  chain, not yet known to this call frame). Per §2.3's rule, `gw_node`'s own `local_lowlink` is pulled down
  by `min(local_lowlink, child_lowlink)` exactly as ISS-0398 §2.2.2 step 5 already specifies for any
  branching node, and `resolve_nested_split/3` returns `{{:open, gw_node's own local_lowlink}, gw_node's own
  local_leaves, state'}` for `gw_node`'s own call frame — propagated through step 4's `:split` arm and up
  through whichever ancestor eventually turns out to own the closure check, exactly as any other still-open
  SCC result already propagates through any other node's own fold (nothing about crossing a nested-split
  boundary changes how `{:open, _}}` propagates). This is not a special case bolted onto `resolve_nested_split/3`
  — it is the *same* rule §2.3's fold description already gives, restated here so this section's own account
  of failure propagation cannot be read as contradicting it (the way iteration 1's did). §3.2's worked trace
  against CODE-DESIGN-VALIDATOR's own counterexample shows this concretely: `inner_split`'s own call returns
  `{:open, 0}}`, not `:dead_end` and not a forced `:finished`, and that `{:open, 0}}` is what lets `A`'s own
  closure check — the *actual* SCC root here — correctly absorb `inner_split`, `ia`, and `A` itself into one
  closed SCC once `A`'s own fold completes. §4's fixture 3 below exercises this shape end-to-end through
  `Transition.transition/3`.

### 3.4 Termination for arbitrary nesting depth

**Extends, rather than replaces, ISS-0398 design §2.2.3's termination argument.** That argument bounds
total *fresh* (step-5) explorations by `length(definition_snapshot.nodes)` and total edges inspected by
`length(definition_snapshot.edges)`, for one top-level branch call's own single, continuous Tarjan pass.
This design's recursion through `resolve_nested_split/3` makes **no new kind of call and starts no new
Tarjan pass** — every call `resolve_nested_split/3` makes, directly or via the nodes it resolves, is an
ordinary `collect_leaf_gateways/3` call (or one of its existing helpers), consuming the *same* single
`state` value (all six fields — `memo`, `index`, `lowlink`, `stack`, `stack_set`, `next_index` — per this
revision's §2.3/§3.2, with no reset anywhere except `find_matching_join/2`'s own top-level per-branch
reset, unchanged from ISS-0398). So the existing argument's own bound already covers every call this
design adds, **without amendment to the counting argument itself** — restated precisely:

- **Totality (never raises):** `resolve_nested_split/3`'s own body is a finite, bounded composition of
  calls already proven total (`gateway_role/2` — a `cond` over `Enum.count`, total; the per-branch fold —
  a finite `Enum.reduce`/`reduce_while` over `gw_node`'s own finite outgoing-edge list, each iteration
  calling the already-total `collect_leaf_gateways/3`; the continuation step — one more already-total
  `collect_leaf_gateways/3` call, or a `nil`-checked `Enum.find` that folds to `:dead_end` on failure, never
  raising). Propagating a `{:open, lowlink}}` result (§3.3's second bullet, this revision) is a plain return
  of an already-computed value plus one `min/2` comparison — no new possibility of a raise, and no new
  possibility of non-termination either: unlike iteration 1's rejected mechanism (§3.2), this revision
  introduces no operation that removes a node from `stack_set` before its own call frame returns, which is
  the one property that would have been needed to cause a node to be explored fresh more than once (see the
  explicit termination conclusion at the end of §3.2's cyclic worked trace).
- **The bound on fresh (step-5) explorations is unchanged, and here is why nesting depth does not add a
  new multiplicative or exponential factor:** every node the recursion through `resolve_nested_split/3`
  ever visits — whether it is one of `gw_node`'s own branch nodes, `gw_node`'s own inner join, or the
  continuation past that inner join — is a `node_id` drawn from the *same* finite
  `definition_snapshot.nodes` list the outer walk already draws from, and is subject to the *same*
  step-1 memo-hit short-circuit **and the same step-2 on-stack short-circuit** (both unchanged, both now
  correctly reachable across a nested-split boundary per this revision) before any fresh exploration
  happens. Two different nested splits (at any depth) can never both freshly explore the same downstream
  node twice — whichever reaches it first either computes and memoizes it (step 1, once its SCC closes) or
  leaves it correctly visible as still-open on `stack_set` (step 2, while its SCC is still open); every
  other path (nested or not, at any depth) gets an O(1) memo hit or an O(1) on-stack detection, never a
  fresh re-exploration. This is the *same* mechanism ISS-0398 §2.2.3 already relies on to bound the outer
  walk's own sibling-branch reuse (the diamond-chain adversarial case, ISS-0398 design §2.4a) — nesting
  depth is not a new dimension the memo/stack machinery has to reason about differently; a nested split's
  branch node and an outer split's branch node are, to both the memo and the stack, indistinguishable —
  both are just `node_id` keys in the same map / entries in the same set.
- **What DOES bound nesting depth itself, concretely, so this is not merely "the memo saves us":**
  `graph.ex`'s own structural validator caps `@max_nodes 500` (confirmed live in the codebase; ISS-0398
  design §2.4a cites this same constant for its own adversarial-case sizing) — since each additional level
  of nesting requires at least 3 additional distinct nodes (a nested split node, at least one of its own
  branch nodes, and its own inner join node — `gateway_role/2`'s own `:split` classification requires
  out_degree > 1, so at least 2 branches, plus the join), nesting depth is bounded above by
  `⌊(@max_nodes - 1) / 3⌋` — a small constant (166) for any graph that passes CHK-01..CHK-19 structural
  validation at all, regardless of how deeply an adversarial tenant tries to nest splits. Recursion depth
  through `resolve_nested_split/3` therefore cannot exceed this same bound: each recursive
  `resolve_nested_split/3` call corresponds to one additional `:PARALLEL_GATEWAY`-with-`:split`-role node
  on the current call chain, and no node can be revisited fresh (previous bullet), so the chain of nested
  `resolve_nested_split/3` calls is itself no longer than the graph's own nesting depth, which is itself
  bounded by node count.
- **Complexity bound, restated:** total work remains `O(nodes + edges)` — identical asymptotic bound to
  ISS-0398's own fix, because this design adds no new per-node work beyond a `gateway_role/2` check (an
  `O(edges)` scan, but performed **once per node**, exactly as `explore_branching_node/3` already performs
  its own `Enum.filter` over `definition_snapshot.edges` once per fresh node — this is not a new
  asymptotic contribution, it is the same `O(out_degree)`-per-node cost the traversal already pays
  everywhere) and one continuation-edge lookup per resolved nested join (again `O(out_degree)`, paid once
  per join node, already within the existing per-node edge-scan budget). No path through this design's new
  code performs a per-*path* (as opposed to per-*node*) computation, which is precisely the property whose
  absence caused iteration 1's `O(2^k)` blowup (ISS-0398 design's own opening note) — so this design does
  not reintroduce that defect class either.

## 4. Worked fixtures (for TEST-DESIGNER's later step, not implemented here)

Specified precisely enough to build without further judgment calls, mirroring ISS-0398 design §4's own
style.

**Fixture 1 — `nested_parallel_split_graph/0`, ISSUE-FIXER's own repro 1 shape:** `outer_split`
(`:PARALLEL_GATEWAY`, out_degree 2) → branch 0: `outer_split` → `outer_join` directly (zero-hop control,
mirrors ISS-0398's own `three_branch_graph/0` branch shape). Branch 1: `outer_split` → `pre` (plain
single-edge chain node) → `inner_split` (`:PARALLEL_GATEWAY`, out_degree 2) → `inner_a`/`inner_b` (each a
single-edge chain node) → `inner_join` (`:PARALLEL_GATEWAY`, in_degree 2, out_degree 1) → `post` (plain
single-edge chain node) → `outer_join` (`:PARALLEL_GATEWAY`, in_degree 2 — from branch 0 and from `post`;
out_degree 1) → `e` (`:END`).
**Assertions:** `Transition.transition(g, state, {:advance_token, initial_token_id})` returns `{:ok,
new_state, [{:parallel_split, ^initial_token_id, "outer_split", branch_ids}]}` (succeeds, where today's
shipped code returns `{:error, {:no_matching_join_found, "outer_split"}}}` — this is the core regression
assertion for ISS-0400 itself, matching ISSUE-FIXER's own repro 1 exactly). `new_state.join_counters["outer_join"]`
is a `%JoinCounter{}` whose `expected_from_branches == MapSet.new(branch_ids)` — resolves against the real
**outer** join, never against `"inner_split"` or `"inner_join"`. A *separate* assertion (or a follow-up
`{:advance_token, ...}` sequence) confirms branch 1's token, once it reaches `inner_split`, independently
triggers its *own* `dispatch_parallel_split/4`/`find_matching_join/2` call that resolves to `"inner_join"` —
i.e., the inner split still functions as a real, independently-dispatchable `PARALLEL_GATEWAY` split at
runtime (this design's fix is scoped to the **lookahead search** `find_matching_join/2` performs; it must
not be confused with, or accidentally change, `dispatch_parallel_gateway/4`'s own runtime dispatch of the
inner split when a token actually reaches it — §5 confirms this boundary explicitly).

**Fixture 2 — `nested_split_dead_end_graph/0` (negative case):** identical to fixture 1's branch 1, except
`inner_b`'s edge targets an `:END` node `e2` instead of `inner_join` (one of the nested split's own two
branches dead-ends). **Assertion:** `Transition.transition/3` still returns `{:error,
{:no_matching_join_found, "outer_split"}}}` — confirms a nested split whose own inner resolution fails
propagates as `:dead_end` (§3.3) and correctly fails the outer branch, rather than partially succeeding or
crashing.

**Fixture 3 — `nested_split_ancestor_back_edge_graph/0` (replaces iteration 1's fixture 3; this is
CODE-DESIGN-VALIDATOR's own counterexample graph, reproduced exactly, per its handoff's requirement that
this exact shape be exercised and shown to terminate correctly — see §3.2's worked trace above for the
full step-by-step derivation this fixture's assertions rest on):** `outer_split` (`:PARALLEL_GATEWAY`,
out_degree 2) → branch 0: direct to `outer_join`. Branch 1: `outer_split` → `A` (plain single-edge chain
node) → `inner_split` (`:PARALLEL_GATEWAY`, out_degree 2, `:split` role) → edge a: `inner_split` → `ia`
(plain single-edge chain node) → `A` (**back-edge directly to `A`**, the node leading into `inner_split`
itself — `A` is still on the outer walk's own `stack`/`stack_set`, its own call frame not yet returned,
when `inner_split`'s own fold reaches this edge; legal per `graph.ex` CHK-06 since `inner_split` is
gateway-typed); edge b: `inner_split` → `ib` (plain single-edge chain node) → `inner_join`
(`:PARALLEL_GATEWAY`, `:join` role, out_degree 1) → `post` (plain single-edge chain node) → `outer_join`
(`:PARALLEL_GATEWAY`, in_degree 2 — from branch 0 and from `post`; out_degree 1) → `e` (`:END`).
**Assertions:**
1. `Transition.transition(g, state, {:advance_token, initial_token_id})` returns `{:ok, new_state,
   [{:parallel_split, ^initial_token_id, "outer_split", branch_ids}]}` — **succeeds**, resolving to
   `"outer_join"`. Per §3.2's trace: the SCC `{A, inner_split, ia}` closes as one unit at `A` (the actual
   SCC root — `A`'s own `local_lowlink` is pulled down to `0` by `ia`'s back-edge, and `A`'s own closure
   check `0 == index["A"]` passes), and edge b's escape path (`ib → inner_join → post → outer_join`)
   supplies the real leaf value that becomes every member's shared, correct memo entry — so the branch's
   aggregate resolves to the singleton `#{{:gateway,"outer_join"}}}`, matching branch 0. This is the
   **positive** counterpart to iteration 1's fixture 3 (which only asserted a pure-cycle-no-escape failure
   case, §5 below shows why that alone is insufficient): a legal graph where the nested split's own branch
   genuinely does loop back to a still-open ancestor, and the correct behavior is to resolve successfully,
   not merely to fail without crashing.
2. **Explicit non-regression requirement, stated as its own assertion, not left implicit:** this test must
   complete within an ordinary CI test timeout (no explicit wall-clock budget needed the way
   `diamond_chain_graph/1`'s ISS-0398 fixture needs one — this fixture's node count is small and the defect
   class being guarded against is non-termination, not slowness; any completion at all, in bounded time,
   already falsifies the failure mode iteration 1's design would have produced). This is the direct
   regression assertion for the BLOCKER CODE-DESIGN-VALIDATOR found: under iteration 1's rejected
   reset-based mechanism (§3.2), this exact fixture would never return at all.
3. `new_state.join_counters["outer_join"]` is a `%JoinCounter{}` whose `expected_from_branches ==
   MapSet.new(branch_ids)` — resolves against the real outer join, never against `"inner_split"` or
   `"inner_join"`, confirming the SCC-closure detour through the cycle did not corrupt which node the
   branch is ultimately understood to resolve to.

**Fixture 3b — `nested_split_ancestor_back_edge_no_escape_graph/0` (negative twin, retains iteration 1's
pure-cycle-no-escape coverage):** identical to fixture 3, except edge b (`inner_split → ib → inner_join →
post → outer_join`) is removed entirely — `inner_split` has only its single edge to `ia`, making it
`gateway_role/2`-classified `:pass_through` (out_degree 1), not `:split`, so this fixture instead needs
`inner_split` to keep out_degree 2 to stay `:split`-classified: edge b is replaced with `inner_split` →
`ib` → `A` as well (a **second**, independent back-edge into `A`, rather than removing edge b outright —
this keeps `inner_split` genuinely `:split`-classified while removing every escape from the cycle). **Assertion:**
`Transition.transition/3` returns `{:error, {:no_matching_join_found, "outer_split"}}}` — the SCC
`{A, inner_split, ia, ib}` closes with an empty aggregate leaf set (no edge anywhere in the SCC reaches a
`:PARALLEL_GATEWAY` terminal), a non-singleton-agreement (empty-set) failure per §2.5's unchanged rule,
correctly failing the branch without crashing or hanging — same non-regression timeout requirement as
fixture 3's assertion 2.

**Fixture 4 — `doubly_nested_parallel_split_graph/0` (arbitrary-depth confirmation):** fixture 1's branch 1,
except `inner_a` itself leads to a *second* nested split/join pair before reaching `inner_join` — confirms
§3.4's termination/recursion argument holds for depth 2, not only depth 1, and that memoization correctly
threads through two levels of `resolve_nested_split/3` recursion.

## 5. Confirms the non-nested path is unchanged (no regression of ISS-0398's own fix)

**Explicit confirmation, per the handoff's acceptance criteria:** step 4's `:join`/`:pass_through` arm
(§2.2 point 2) is **byte-for-byte identical** to today's shipped clause (transition.ex:934-936) — same
match pattern (`%Node{node_type: :PARALLEL_GATEWAY}`), same `leaves = MapSet.new([{:gateway, node_id}])`
construction, same `put_leaf_memo/3` call, same `{:finished, leaves, state'}` return. The only change is
that this arm is now reached via an added `gateway_role/2` dispatch rather than unconditionally — and
`gateway_role/2` itself is untouched (transition.ex:730-741, reused verbatim, not modified). Concretely:

- Every fixture in ISS-0398's own design §3/§4 (`three_branch_graph/0`,
  `branch_with_exclusive_gateway_graph/0`, `ambiguous_branch_dead_ends_graph/0`, `diamond_chain_graph/1`,
  `cyclic_escape_graph/0` and its reversed-edges twin, `pure_cycle_no_escape_graph/0`) contains **no**
  `:PARALLEL_GATEWAY` node whose own `gateway_role/2` classification is `:split` or `:combined_unsupported`
  — every `:PARALLEL_GATEWAY` node in every one of those fixtures is the branch's own real join (in_degree
  > 1, out_degree 1) or, for the outer `"split"`/`"outer_split"` node itself, is never reached a *second*
  time from inside its own branch (it is the traversal's own starting point, never revisited as a target
  node_id in any of those graphs). So for every existing fixture, step 4's new `gateway_role/2` dispatch
  evaluates to the `:join`/`:pass_through` arm on every single `:PARALLEL_GATEWAY` node encountered,
  identically to today's unconditional behavior — **zero behavioral difference**, not merely "probably
  unaffected."
- `dispatch_parallel_gateway/4`'s own **runtime** dispatch (transition.ex:694-724, `gateway_role/2`'s
  original call site) is completely untouched by this design — this fix is scoped entirely to
  `collect_leaf_gateways/3`'s own **lookahead search**, called only from `find_matching_join/2`
  (transition.ex:772, at split-node activation time). When a token later actually *arrives* at a nested
  split node (fixture 1's `inner_split`, once branch 1's token physically reaches it), `dispatch_node/4`
  dispatches it through the ordinary `dispatch_parallel_gateway/4` → `gateway_role/2` → `:split` →
  `dispatch_parallel_split/4` path exactly as any other `:PARALLEL_GATEWAY` split would be — this design
  does not change, wrap, or special-case that runtime path at all. Fixture 1's own assertions (§4) confirm
  this explicitly rather than leaving it assumed.
- `find_matching_join/2`'s own external signature and its cross-branch agreement rule (ISS-0398 design
  §2.5, transition.ex:815-843) are **unchanged** — this design's new logic lives entirely inside
  `collect_leaf_gateways/3`'s own step 4 and the new `resolve_nested_split/3` helper it calls;
  `find_matching_join/2`'s own `Enum.reduce_while` fold, its singleton-and-agreement check, and its
  `{:ok, id} | {:error, :no_matching_join}` return shape are not touched by this design at all.

## 6. Signature/name summary for ELIXIR-DEV

- `collect_leaf_gateways/3` — **signature unchanged** (`Graph.t(), String.t(), leaf_search_state() ::
  {leaf_search_result(), MapSet.t(branch_leaf()), leaf_search_state()}`). Only its step-4
  `%Node{node_type: :PARALLEL_GATEWAY}` match arm's body changes, per §2.2 — split into a `gateway_role/2`
  dispatch with two (really three, `:combined_unsupported` folded into the `:dead_end` arm per §2.2 point
  4) outcomes in place of today's single unconditional body. The private-function moduledoc comment
  immediately above it (transition.ex:885-917 today) must be extended (not replaced — ISS-0398's own
  SCC-machinery description stays fully accurate and load-bearing) with a new paragraph describing the
  nested-split dispatch and its "sees through to the inner join's continuation" behavior, referencing this
  design doc.
- **New function, `resolve_nested_split/3`** (§2.3, revised this iteration): `@spec resolve_nested_split(Graph.t(), Node.t(),
  leaf_search_state()) :: {leaf_search_result(), MapSet.t(branch_leaf()), leaf_search_state()}`. Called
  only from `collect_leaf_gateways/3`'s own step-4 `:split` arm. Internally: a fold over `gw_node`'s own
  outgoing edges structurally identical to `fold_outgoing_edges/4`'s own step-5 sibling-edge fold
  (transition.ex:987-1004, threading `state` from one edge to the next, `local_leaves`/`local_lowlink`
  accumulation) — **not** `find_matching_join/2`'s own top-level fold (transition.ex:820-837) and,
  critically, **does NOT call `reset_stack_bookkeeping/1`** at any point — no reset of `index`, `lowlink`,
  `stack`, or `stack_set` before, during, or after this fold. `resolve_nested_split/3` threads the
  **exact, unmodified incoming `state`** (all six `leaf_search_state()` fields) into and back out of its
  own fold, exactly as `fold_outgoing_edges/4` already threads `state` across any other branching node's
  own children. `reset_stack_bookkeeping/1` remains reserved exclusively for `find_matching_join/2`'s own
  top-level per-branch reset (ISS-0398 §2.2.2/§2.5, unchanged) — **ELIXIR-DEV must not call it, or
  reimplement its effect inline, anywhere inside `resolve_nested_split/3` or the call chain it drives**;
  doing so would reintroduce the exact BLOCKER CODE-DESIGN-VALIDATOR found in iteration 1 (full trace,
  `handoffs/WF03-ISS0400-20260901/step-02b-code-design-validator.json`). After the branch fold, on
  agreement, one more `collect_leaf_gateways/3` call on the inner join's own single outgoing edge's target
  (or `:dead_end` if that edge does not exist), with the resulting tag/leaves/state — `:finished` or
  `{:open, _}}` alike, per §3.3's reconciled rule — returned as-is for `gw_node`'s own call frame (no
  repackaging, §2.4).
- `gateway_role/2`, `find_matching_join/2`, `explore_branching_node/3`, `fold_outgoing_edges/4`,
  `close_scc_or_defer/5`, `fresh_leaf_search_state/0`, `put_leaf_memo/3` — all **unchanged**, reused
  verbatim. `reset_stack_bookkeeping/1` — **unchanged**, but its only call site remains
  `find_matching_join/2`'s own top-level per-branch fold; `resolve_nested_split/3` must not call it (see
  above).
- `branch_leaf()`, `leaf_search_state()`, `leaf_search_result()` — all **unchanged** (§2.1, §2.4).

## 7. Open questions (explicitly listed, not silently resolved)

1. **Whether `resolve_nested_split/3`'s own inner per-branch fold should itself be extracted into a
   shared helper with `fold_outgoing_edges/4`'s own step-5 sibling-edge fold**, since this revision's §2.3
   makes the two structurally identical in substance (both thread the incoming `state` through unmodified,
   with no reset) — the only remaining difference between `resolve_nested_split/3`'s fold and
   `find_matching_join/2`'s own top-level fold is that the latter resets stack bookkeeping between branches
   and the former never does. Left to ELIXIR-DEV's implementation judgment — this design specifies the
   required *behavior* precisely (§2.3, §2.6) but does not mandate a particular code-sharing structure,
   since that is an implementation-code decision, not a design one.
2. **Whether a `:combined_unsupported` nested gateway (§2.2 point 4, folded into `:dead_end`) should instead
   surface as a distinct, more diagnosable outcome** given that it represents a genuinely different failure
   mode (a structurally-confused node, not merely an unresolved path) — this design chooses the
   simpler/more-consistent-with-existing-behavior folding (§3.3's reasoning) but flags this as a judgment
   call REVIEWER may want to revisit, since `:combined_unsupported` is rare enough in practice (requires
   both in_degree > 1 and out_degree > 1 on one `PARALLEL_GATEWAY`) that either choice is defensible.
3. **Whether fixtures 3/3b (§4, the ancestor-back-edge-through-a-nested-split shapes) are worth their own
   dedicated unit-level test of `resolve_nested_split/3` in isolation**, versus only exercising them
   end-to-end through `Transition.transition/3` as specified — left to TEST-DESIGNER's judgment at Step 4,
   since `collect_leaf_gateways/3` and its helpers are all private functions today (no direct unit-test
   access without `@compile {:no_warn_undefined, ...}`-style private-function testing, which ISS-0398's own
   test design did not use either — end-to-end fixtures through `Transition.transition/3` are this
   codebase's established convention for this module, per ISS-0398 design §3/§4).
4. **New in this revision:** whether `resolve_nested_split/3`'s fold should be implemented as a literal
   call into the *same* private helper `fold_outgoing_edges/4` already provides for step 5's own
   sibling-edge fold (rather than a structurally-identical-but-separate `Enum.reduce`), now that this
   revision's §2.3 has made the two behaviorally identical (no reset, same threading discipline) — left to
   ELIXIR-DEV's implementation judgment, same rationale as open question 1.
