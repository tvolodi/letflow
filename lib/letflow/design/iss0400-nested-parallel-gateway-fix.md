# Design: ISS-0400 — `collect_leaf_gateways/3` does not resolve a
# `PARALLEL_GATEWAY` nested inside a fork branch

**Issue:** ISS-0400 (`docs/issues/ISS-0400.yaml`), severity MINOR, discovered in `WF03-ISS0398-20260901`
**Diagnosis:** `handoffs/WF03-ISS0400-20260901/step-01-issue-fixer.json` `result.summary` (ISSUE-FIXER,
this run) — root cause, two reproductions, exact line numbers, read in full and relied on directly below.
**Requirement of origin:** REQ-051 (`lib/letflow/design/req051-parallel-gateway-split-join.md`), extended
by ISS-0398's own fix (`lib/letflow/design/iss0398-walk-to-gateway-fix.md`, whose §2.3/§6 named this
exact gap as out of scope and required the follow-up issue this design now resolves).
**Owner (implementer):** ELIXIR-DEV
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
signature/contract must stay untouched) — instead, it performs the **same per-branch/cross-branch
agreement fold** `find_matching_join/2` performs (ISS-0398 design §2.5), inline, but:

- **threads the *same* `state` the outer walk is already carrying** (in particular `state.memo` — see §3.1
  for why this is the load-bearing choice, not an incidental one) into and out of the fold, rather than
  starting a `fresh_leaf_search_state()` the way `find_matching_join/2`'s own top-level call does;
- resets only `index`/`lowlink`/`stack`/`stack_set`/`next_index` between the nested split's own sibling
  branches (via the **existing** `reset_stack_bookkeeping/1`, transition.ex:880-883, reused verbatim) —
  identical reset discipline to `find_matching_join/2`'s own fold (ISS-0398 design §2.5), for the identical
  reason: a previous branch's Tarjan index numbering is meaningless to a fresh per-branch call, but `memo`
  entries remain globally valid regardless of which split (outer or nested) discovered them first;
- on success (every branch of `gw_node` resolves to the *same* single `{:gateway, inner_join_id}}`, per the
  identical singleton-and-agreement rule `find_matching_join/2` already applies): does **not** stop at
  `inner_join_id` and report it as the leaf. Instead, it **continues the walk past the inner join's own
  outgoing edge** — the diagnosis's explicit requirement ("continue from that inner join's own outgoing
  edge, NOT stop and report the inner split's id as a leaf"). Concretely: resolve `inner_join_id`'s own
  single outgoing edge (`Enum.find(definition_snapshot.edges, &(&1.source == inner_join_id))` — a
  `:PARALLEL_GATEWAY` classified `:join` or `:pass_through` by `gateway_role/2` has out_degree <= 1 by that
  classification's own definition, so "the" outgoing edge is unambiguous when one exists) and recurse
  `collect_leaf_gateways(definition_snapshot, edge.target, state)` on **that** edge's target — the result
  of *that* recursive call (which may itself be another `:PARALLEL_GATEWAY`, nested split or not, another
  `:EXCLUSIVE_GATEWAY` chain, anything `collect_leaf_gateways/3` already handles) becomes
  `resolve_nested_split/3`'s own return value, tagged/threaded exactly as any other step-4-successor call's
  result would be. If `inner_join_id` has **zero** outgoing edges (a `:PARALLEL_GATEWAY` join with no
  continuation — a legal but unusual shape, e.g. it is itself the graph's terminal point via some other
  path): treat as `:dead_end` (same §3.3 folding rationale — there is no leaf to report past a join that
  goes nowhere).
- on failure (`gw_node`'s own branches don't singleton-agree, or any branch itself resolves to `:dead_end`,
  or `gw_node`'s own recursive resolution bottoms out in a **deeper** nested split that itself fails to
  resolve): returns `:dead_end` for this whole `resolve_nested_split/3` call — §3.3 states this
  precisely and justifies folding rather than adding a new error tag.

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

### 3.2 Does sharing `state` (in particular `state.memo`) between outer and inner resolution introduce a new hazard?

**Considered and rejected: giving `resolve_nested_split/3` a fresh, isolated `leaf_search_state()`
(fresh `memo` too, not just fresh stack bookkeeping).** This would be simpler to reason about in isolation
but reopens exactly the exponential-blowup class ISS-0398's iteration-1-to-2 rework fixed (SECURITY-REVIEWER's
BLOCKER INV-8 finding, ISS-0398 design's own opening note): a diamond-chain-shaped nested split reached
independently from `k` different outer branches (or reached `k` times while resolving one nested split's
own diamond-chain-shaped internal branches) would recompute its entire downstream subgraph from scratch
every time, rather than reusing memo entries the outer walk (or a sibling nested-split branch) already
computed. **Decision: `resolve_nested_split/3` must receive and return the *same* `state` value — in
particular the *same* `memo` map — the caller already holds, threading it exactly as `fold_outgoing_edges/4`
already threads `state` across a plain branching node's own sibling edges (transition.ex:987-1004).** This is
not a new sharing discipline; it is the same one `find_matching_join/2`'s own fold already uses across
*outer* sibling branches (ISS-0398 design §2.5) applied one level deeper, across the *nested split's* own
sibling branches, and further still across the boundary between "resolving the nested split" and
"continuing past its inner join."

**Does sharing `memo` (but resetting `index`/`lowlink`/`stack`/`stack_set`/`next_index`) across this new
recursive boundary reopen ISS-0398 §2.2.1's counterexample?** No, for the same structural reason §3.1 gives:
`memo` entries are keyed by `node_id`, and the SCC-closure invariant that makes a `memo[node_id]` entry safe
to reuse (ISS-0398 design §2.2.2's closure check: an entry is written only once its entire SCC has fully
closed, and a closed SCC's aggregate value is provably the same regardless of entry point) depends only on
**how that entry was computed**, never on **which caller** (outer top-level branch, or a nested split's own
inner branch, or the continuation past an inner join) triggered the computation. The reset-per-top-level-call
discipline (`index`/`lowlink`/`stack`/`stack_set`/`next_index` back to empty/`0`) is what keeps two
*unrelated* top-level Tarjan passes from having their index numbering collide — and `resolve_nested_split/3`
resets exactly this same set of fields before folding over `gw_node`'s own sibling branches, for the
identical reason `find_matching_join/2` already does. **What must NOT happen, stated as an explicit
invariant for ELIXIR-DEV to preserve:** a call site that resets `memo` too (instead of only the four
stack-bookkeeping fields) when entering `resolve_nested_split/3` would silently reintroduce the
exponential-blowup defect class (§3.2's opening paragraph) — this is the same warning ISS-0398's own design
doc §2.6 already gives ELIXIR-DEV for the ordinary outer-branch case, and it applies identically here, one
level deeper.

**Worked micro-example, following the diagnosis's own repro 1 shape (`outer_split` → branch 1 → `pre` →
`inner_split` → `{inner_a, inner_b}` → `inner_join` → `post` → `outer_join`; branch 0 → `outer_join`
directly):**

`find_matching_join(definition_snapshot, outer_split_node)` starts `state_0 = fresh_leaf_search_state()`
(`memo = %{}`). Branch 0 (`edge.target = "outer_join"`): `collect_leaf_gateways(g, "outer_join", state_0)`
→ step 4, `gateway_role("outer_join") == :join` (in_degree 2: from branch 0 directly and from branch 1's
`post` node; out_degree 1, to `"e"`) → immediate terminal, `leaves = #{{:gateway,"outer_join"}}`,
`memo["outer_join"]` written. Branch 1 (`edge.target = "pre"`, with `state` reset-except-memo, so
`memo["outer_join"]` survives): `collect_leaf_gateways(g, "pre", state)` → `"pre"` is an ordinary
single-edge chaining node (step 5/`explore_branching_node/3`) → recurse into `"inner_split"` →
`collect_leaf_gateways(g, "inner_split", state)` → step 4, resolves to `%Node{node_type:
:PARALLEL_GATEWAY}` → `gateway_role("inner_split")`: out_degree 2 (to `inner_a`, `inner_b`), in_degree 1
(from `pre`) → **`:split`** → this design's new arm fires: `resolve_nested_split(g, inner_split_node,
state)`. That call folds over `inner_split`'s own 2 edges with the **same incoming `state.memo`** (already
containing `"outer_join"`, irrelevant to this inner fold but harmlessly present) and freshly reset
stack bookkeeping: edge to `inner_a` → single-edge chain to `inner_join` → step 4, `gateway_role("inner_join")
== :join` (in_degree 2, out_degree 1) → terminal, `leaves = #{{:gateway,"inner_join"}}`,
`memo["inner_join"]` written, `memo["inner_a"]` written by the closure of `inner_a`'s own trivial SCC. Edge
to `inner_b` (state now carries `memo["inner_join"]`, `memo["inner_a"]`) → single-edge chain to
`inner_join` → **step-1 memo hit**, O(1), no recursion. Both branches singleton-agree on
`{:gateway,"inner_join"}}` → `resolve_nested_split/3`'s inner fold succeeds with `inner_join_id =
"inner_join"`. Per §2.3's continuation step: resolve `"inner_join"`'s own single outgoing edge (target
`"post"`) and recurse `collect_leaf_gateways(g, "post", state)` → single-edge chain → recurse into
`"outer_join"` → **step-1 memo hit** (written by branch 0 above) → `{:finished, #{{:gateway,"outer_join"}},
state}`. This becomes `"post"`'s own finished value, then `resolve_nested_split/3`'s own return value, then
(via §2.2's step-4 `:split` arm, a pure pass-through) `"inner_split"`'s own finished value — **not**
`#{{:gateway,"inner_split"}}`, but `#{{:gateway,"outer_join"}}`, correctly "seeing through" the nested split.
This propagates back up through `"pre"` unchanged (union of a single finished child) to branch 1's own
top-level result: `#{{:gateway,"outer_join"}}}` — the **same** singleton branch 0 produced. Cross-branch
agreement (§2.5, unchanged) passes → `find_matching_join/2` returns `{:ok, "outer_join"}`. This is exactly
the outcome ISSUE-FIXER's repro 1 shows is currently missing (today: `{:error, {:no_matching_join_found,
"outer_split"}}}`).

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

**What this means concretely for `resolve_nested_split/3`'s own contract:** whenever the nested split's own
per-branch/cross-branch fold does not produce a clean singleton `{:gateway, inner_join_id}}` agreement, OR
the subsequent continuation-past-the-inner-join step (§2.3's last bullet) itself yields anything other than
a clean `:finished`-with-singleton-`{:gateway,_}}` result propagated all the way through, `resolve_nested_split/3`
returns `{:finished, MapSet.new([:dead_end]), state'}` — **memoized under nothing new** (§3.1 — no
`memo[gw_node.id]` entry is written for this failure case either; the nodes that *were* successfully
resolved along the way keep their own individually-correct memo entries, since a node's own SCC-aggregate
leaf value is unaffected by what a *different*, sibling branch does with it). One exception worth stating
explicitly: if the nested split's own fold produces `{:open, lowlink}` for one of its branches (i.e. a live
back-edge reaches back out of the nested split's own resolution into an ancestor still on the *outer*
walk's shared `stack` — possible in principle since `state.stack`/`stack_set` are shared across this
recursive boundary exactly like `memo` is, per §3.2), that `{:open, lowlink}` tag is propagated through
`resolve_nested_split/3` and up through step 4's `:split` arm exactly as any other still-open SCC result
would be (not forced to `:finished`/`:dead_end` prematurely) — this is required for §3.1's order-independence
argument to keep holding when a nested split's own branch reaches back into a cycle that also involves nodes
outside the nested split; §4's fixture 3 below exercises this shape directly.

### 3.4 Termination for arbitrary nesting depth

**Extends, rather than replaces, ISS-0398 design §2.2.3's termination argument.** That argument bounds
total *fresh* (step-5) explorations by `length(definition_snapshot.nodes)` and total edges inspected by
`length(definition_snapshot.edges)`, for the *outer* walk's own calls. This design's recursion through
`resolve_nested_split/3` makes **no new kind of call** — every call `resolve_nested_split/3` makes,
directly or via the nodes it resolves, is an ordinary `collect_leaf_gateways/3` call (or one of its
existing helpers), consuming the *same* shared `state.memo`/`state.index`(-per-top-level-reset). So the
existing argument's own bound already covers every call this design adds, **without amendment to the
counting argument itself** — restated precisely:

- **Totality (never raises):** `resolve_nested_split/3`'s own body is a finite, bounded composition of
  calls already proven total (`gateway_role/2` — a `cond` over `Enum.count`, total; the per-branch fold —
  a finite `Enum.reduce`/`reduce_while` over `gw_node`'s own finite outgoing-edge list, each iteration
  calling the already-total `collect_leaf_gateways/3`; the continuation step — one more already-total
  `collect_leaf_gateways/3` call, or a `nil`-checked `Enum.find` that folds to `:dead_end` on failure, never
  raising). No new possibility of a raise is introduced.
- **The bound on fresh (step-5) explorations is unchanged, and here is why nesting depth does not add a
  new multiplicative or exponential factor:** every node the recursion through `resolve_nested_split/3`
  ever visits — whether it is one of `gw_node`'s own branch nodes, `gw_node`'s own inner join, or the
  continuation past that inner join — is a `node_id` drawn from the *same* finite
  `definition_snapshot.nodes` list the outer walk already draws from, and is subject to the *same*
  step-1 memo-hit short-circuit (transition.ex:922-923, unchanged) before any fresh exploration happens.
  Two different nested splits (at any depth) can never both freshly explore the same downstream node twice
  — whichever reaches it first computes and memoizes it; every other path (nested or not, at any depth)
  gets an O(1) memo hit. This is the *same* mechanism ISS-0398 §2.2.3 already relies on to bound the outer
  walk's own sibling-branch reuse (the diamond-chain adversarial case, ISS-0398 design §2.4a) — nesting
  depth is not a new dimension the memo has to reason about differently; a nested split's branch node and an
  outer split's branch node are, to the memo, indistinguishable — both are just `node_id` keys in the same
  map.
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

**Fixture 3 — `nested_split_reentrant_cycle_graph/0` (exercises §3.3's `{:open, lowlink}`-propagation
exception):** `outer_split` (out_degree 2) → branch 0: direct to `outer_join`. Branch 1: `outer_split` →
`X` → `inner_split` (`:PARALLEL_GATEWAY`, out_degree 2) → edge a: `inner_a` → `inner_join`
(`:PARALLEL_GATEWAY`, out_degree 1) → `post` → `outer_join`; edge b: `inner_b` → `back` (`:EXCLUSIVE_GATEWAY`,
out_degree 1) → `X` (closing a cycle `X → inner_split → inner_b → back → X`, legal per `graph.ex`'s CHK-06
since `inner_split` is gateway-typed). **Assertion:** `Transition.transition/3` returns `{:error,
{:no_matching_join_found, "outer_split"}}}` — the cycle has no escape edge that reaches `outer_join`
independent of the cycle itself reconverging on `X`, so this branch's own aggregate leaf set is the empty
set (ISS-0398 design §2.2.1's "pure cycle, no escape" case, propagated up through the nested-split boundary
this design adds) — a non-singleton (empty), correctly failing. This fixture's purpose is specifically to
confirm `resolve_nested_split/3` does not mishandle a live back-edge that reaches back out past the nested
split's own boundary into an outer-walk ancestor (`X`) — TEST-DESIGNER should also verify (via a smaller,
targeted unit-level check on `resolve_nested_split/3` if the test module structure allows it, or by
tracing) that this does not raise or infinite-loop, only that it correctly reports no matching join.

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
- **New function, `resolve_nested_split/3`** (§2.3): `@spec resolve_nested_split(Graph.t(), Node.t(),
  leaf_search_state()) :: {leaf_search_result(), MapSet.t(branch_leaf()), leaf_search_state()}`. Called
  only from `collect_leaf_gateways/3`'s own step-4 `:split` arm. Internally: a per-branch/cross-branch fold
  over `gw_node`'s own outgoing edges (structurally identical to `find_matching_join/2`'s own fold,
  transition.ex:820-837, reusing `reset_stack_bookkeeping/1` between the nested split's own sibling
  branches, threading the **same incoming `state`**, never a `fresh_leaf_search_state()`), followed by,
  on success, one more `collect_leaf_gateways/3` call on the inner join's own single outgoing edge's target
  (or `:dead_end` if that edge does not exist), returned as-is (no repackaging, §2.4).
- `gateway_role/2`, `find_matching_join/2`, `explore_branching_node/3`, `fold_outgoing_edges/4`,
  `close_scc_or_defer/5`, `reset_stack_bookkeeping/1`, `fresh_leaf_search_state/0`, `put_leaf_memo/3` — all
  **unchanged**, reused verbatim.
- `branch_leaf()`, `leaf_search_state()`, `leaf_search_result()` — all **unchanged** (§2.1, §2.4).

## 7. Open questions (explicitly listed, not silently resolved)

1. **Whether `resolve_nested_split/3`'s own inner per-branch fold should itself be extracted into a
   shared helper with `find_matching_join/2`'s fold**, since the two are structurally identical apart from
   "start fresh state" vs. "thread incoming state." Left to ELIXIR-DEV's implementation judgment — this
   design specifies both folds' required *behavior* precisely (§2.3, §2.6) but does not mandate a
   particular code-sharing structure between them, since that is an implementation-code decision, not a
   design one.
2. **Whether a `:combined_unsupported` nested gateway (§2.2 point 4, folded into `:dead_end`) should instead
   surface as a distinct, more diagnosable outcome** given that it represents a genuinely different failure
   mode (a structurally-confused node, not merely an unresolved path) — this design chooses the
   simpler/more-consistent-with-existing-behavior folding (§3.3's reasoning) but flags this as a judgment
   call REVIEWER may want to revisit, since `:combined_unsupported` is rare enough in practice (requires
   both in_degree > 1 and out_degree > 1 on one `PARALLEL_GATEWAY`) that either choice is defensible.
3. **Whether fixture 3 (§4, the reentrant-cycle-through-a-nested-split shape) is worth its own dedicated
   unit-level test of `resolve_nested_split/3` in isolation**, versus only exercising it end-to-end through
   `Transition.transition/3` as specified — left to TEST-DESIGNER's judgment at Step 4, since
   `collect_leaf_gateways/3` and its helpers are all private functions today (no direct unit-test access
   without `@compile {:no_warn_undefined, ...}`-style private-function testing, which ISS-0398's own test
   design did not use either — end-to-end fixtures through `Transition.transition/3` are this codebase's
   established convention for this module, per ISS-0398 design §3/§4).
