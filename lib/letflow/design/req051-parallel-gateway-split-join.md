PROVENANCE (historical, not current decision authority):
# Design: REQ-051 — Parallel gateway split and join (transition.zig EE-06/EE-07)

**Requirement:** REQ-051 (`docs/requirements.yaml`, stage S3)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the `Letflow.Engine.JoinCounter` struct, the `cancelled`-branch
representation this requirement itself must introduce (new `InstanceState.join_counters` field —
no representation is deferred to REQ-052), `dispatch_parallel_gateway/4`'s real split/join body
(replacing REQ-044's stub), the new `{:cancel_branch, branch_id}` `transition_event/0` constructor,
the narrowed `pending_event/0` union for EE-06/EE-07, the new `transition_error/0` variants, and
the exact-once/order-independent join-firing mechanism. Signatures and type shapes only — no
implementation code, no function bodies, no `.ex`/`.exs` code block contains real logic.

## 0. Sources read for this design, and an explicit access gap

- This handoff's `context.requirement_text.REQ-051` (quoted in full where load-bearing) and
  `task.acceptance_criteria` — read directly, not via `docs/requirements.yaml`, per
  `core-directives.md`'s "Load Scoped Context, Not Whole Files." One targeted lookup was made
  against `docs/requirements.yaml` to re-read REQ-051's own entry verbatim (confirming
  `depends_on: [REQ-044, REQ-049]`) and REQ-052's own entry (confirming its explicit "that
  token-level rule lives in REQ-051's pure transition logic" scope note), via
  `awk '/^  - id: REQ-051$/,/^  - id: REQ-053$/' docs/requirements.yaml`.
- `lib/letflow/engine/transition.ex`, `instance_state.ex`, `token.ex` (full, current `main`,
  REQ-044, `status: done`) — the shipped dispatch skeleton, `dispatch_parallel_gateway/4`'s stub
  (the exact extension point this design replaces), `Token.branch_id`'s existing `nil`-default
  field (already reserved by REQ-044 §3 "for REQ-051's dispatch body to write to"), and
  `InstanceState`'s existing 5-field struct (`instance_id`, `status`, `tokens`, `variables`,
  `pending_task_nodes`) that this design adds one field to.
- `lib/letflow/design/req044-transition-kernel.md` (full) — the purity/determinism bar (§8, the
  "every id supplied by the caller, never minted here" rule this design must knowingly diverge
  from and justify, §3.2 below), the `pending_event/0`-as-open-extension-point framing (§4, §12.5,
  explicitly naming REQ-051 as the requirement that narrows it), the `{:ok,_,_}|{:error,_}` return
  convention, and the single-hop-per-call contract this design's join/cancel dispatch must also
  respect (one `transition/3` call still processes exactly one event and returns).
- `lib/letflow/design/req049-variable-merge.md` (full, actual filename
  `req049-variable-merge.md` — the handoff's `artifacts_in` names
  `req049-variable-scoping-merge.md`, which does not exist under that name; noted as a stale
  filename in the handoff rather than silently working around it, flagged in `result.issues`) —
  `Letflow.Engine.VariableMerge.merge/3`'s real `@spec`
  (`merge(current_variables :: map(), incoming_variables :: map(), variable_validations :: map() |
  nil) :: merge_result()`), its `:ok`/`:rejected` return shape, and its §9 empty-map no-op case
  (`merge(vars, %{}, nil)` always returns `{:ok, vars, []}`) — load-bearing for §6 below's join-time
  reuse call.
PROVENANCE (historical, not current decision authority):
- `lib/letflow/definitions/graph.ex` (full) — `Graph.Edge.t()`'s `id`/`source`/`target` fields, and
  `lib/letflow/design/req028-graph-structural-validator.md` (targeted read, its Edge field table
  and CHK-01..CHK-08 list) — confirmed **no structural check enforces edge-id uniqueness**
  ("no named CHK-08-adjacent check validates edge-id uniqueness — `graph.zig` itself has none
  either"). This is load-bearing for §3.1's id-derivation design (declaration-order index used
  instead of `edge.id`, precisely to avoid depending on an uniqueness property nothing guarantees).
- `docs/migration/stage-3-instance-engine.md` (full) — confirms REQ-051 (EE-06+EE-07) was
  deliberately kept as one 661-line requirement because "split and join share the Token/JoinCounter
  model and EE-07's cancelled-branch-exclusion rule cannot be stated without the split half
  present," and that `lib/letflow/parallel_approval.ex`'s hand-written two-approver `:gen_statem`
  is superseded by REQ-051+REQ-052 together (REQ-052's own job, not touched here).
- `docs/anti-patterns.md` (current entries) — no entry currently bears on this module.

PROVENANCE (historical, not current decision authority):
**Access gap, stated explicitly, matching REQ-044/REQ-049's design docs' own precedent:** this
environment has no `R-Co/src/engine/transition.zig` or `R-Co/src/design/engine.md` reachable
(re-confirmed: `find / -iname "transition.zig"` and `find / -iname "engine.md" -path "*design*"`
both returned no match). This design is built entirely from `context.requirement_text.REQ-051`'s
own text (already the ORCH-supplied summary of EE-06/EE-07) plus the shipped precedent in
`req044-transition-kernel.md` and `req049-variable-merge.md`. Three genuinely novel mechanisms this
requirement needs — (a) how new token/branch ids are minted inside a purity-constrained kernel that
cannot call `:rand`/`:crypto`, (b) how a split's matching join node is located in a general graph,
(c) whether "variables merging at the join" is a distinct mechanic from ordinary REQ-049 calls
during each branch's own task completions — are **this design's own reasoned constructions**, not
verified against `transition.zig`'s literal source. Each is flagged inline where it matters (§3.2,
§4.3, §6) and again in §12's consolidated open-questions list.

## 1. Module/file layout

**One new file, following REQ-044's per-concept-file convention:**

| File | Module | Contents |
|---|---|---|
| `lib/letflow/engine/join_counter.ex` | `Letflow.Engine.JoinCounter` | The `JoinCounter` struct + `@type t/0` (§2) |
| `lib/letflow/engine/instance_state.ex` | `Letflow.Engine.InstanceState` | **Modified** — one new field, `join_counters` (§2.1) |
| `lib/letflow/engine/transition.ex` | `Letflow.Engine.Transition` | **Modified** — `transition_event/0` gains `{:cancel_branch, _}` (§3.4), `pending_event/0` narrowed (§5), `transition_error/0` gains 4 variants (§7), `dispatch_parallel_gateway/4`'s stub body replaced (§3–§4), top-level `transition/3` event match gains the `{:cancel_branch, branch_id}` clause (§3.4) |

`JoinCounter` earns its own file for the same reason `Token` did in REQ-044 §1: it is a
first-class value type multiple dispatch paths (split, join-arrival, branch-cancellation) construct
and read, not scoped to one function's local logic.

## 2. `Letflow.Engine.JoinCounter` — struct and field types

```elixir
@enforce_keys [:join_node_id, :origin_token_id, :expected_from_branches]
defstruct [
  :join_node_id,
  :origin_token_id,
  expected_from_branches: MapSet.new(),
  received_from_branches: MapSet.new(),
  cancelled_branches: MapSet.new()
]

@type t :: %__MODULE__{
        join_node_id: String.t(),
        origin_token_id: String.t(),
        expected_from_branches: MapSet.t(String.t()),
        received_from_branches: MapSet.t(String.t()),
        cancelled_branches: MapSet.t(String.t())
      }
```

PROVENANCE (historical, not current decision authority):
Ports `transition.zig`'s `JoinCounter` (`received_count`/`expected_from_branches`, "added by
R-Co's ISS-105" per the requirement text) as a **set-based**, not count-based, representation:
`expected_from_branches`/`received_from_branches` are `MapSet.t(String.t())` of `branch_id`s, not
bare integers. This is a deliberate divergence from the literal `received_count` field name,
stated explicitly: EE-07 AC2/AC3's cancelled-branch-exclusion rule requires knowing **which**
specific branches are still outstanding, not merely how many have arrived — a bare
`received_count :: integer()` cannot express "3 expected, 1 arrived, 1 cancelled, still waiting on
1 specific branch" without also tracking identity, so this design carries the full sets instead
of trying to keep a literal `received_count` integer in sync with them. `cancelled_branches` is
this requirement's own addition beyond `transition.zig`'s two named fields — the concrete
cancelled-branch representation the requirement text requires this requirement to invent (see §4.3).

| Field | Type | Notes |
|---|---|---|
| `join_node_id` | `String.t()` | The `PARALLEL_GATEWAY` node id acting as this cohort's join. |
| `origin_token_id` | `String.t()` | The `token_id` of the token that was consumed at the originating split — identifies *which* split occurrence this cohort belongs to (relevant metadata; not used as a lookup key, §2.1). |
| `expected_from_branches` | `MapSet.t(String.t())` | The full set of `branch_id`s produced by the originating split — fixed at split time, never grows or shrinks. |
| `received_from_branches` | `MapSet.t(String.t())` | `branch_id`s of tokens that have already arrived at `join_node_id`. Subset of `expected_from_branches`. |
| `cancelled_branches` | `MapSet.t(String.t())` | `branch_id`s cancelled via `{:cancel_branch, branch_id}` (§3.4) before reaching the join. Subset of `expected_from_branches`, disjoint from `received_from_branches` by construction (§4.2 step 4/§4.3 step 3 both check the union before adding). |

### 2.1 `InstanceState.join_counters` — the new field, and the single-active-cohort-per-join-node decision

```elixir
join_counters: %{optional(String.t()) => Letflow.Engine.JoinCounter.t()}
```

Added to `Letflow.Engine.InstanceState.t()` (default `%{}`), keyed by `join_node_id` alone — **not**
by `{join_node_id, origin_token_id}`. Design decision, stated explicitly: this means at most one
`JoinCounter` cohort can be outstanding per join node at a time. A second split reaching the same
join node while an earlier cohort is still outstanding (e.g. a loop re-entering the same
split/join pair before the first pass finished) would overwrite the earlier cohort's entry —
**out of scope for this requirement, flagged as an open question (§12.1)**, since no acceptance
criterion exercises loop re-entry and the requirement text's own JoinCounter description
("received_count/expected_from_branches") does not mention multi-cohort tracking. `origin_token_id`
is kept on the struct as descriptive metadata (useful for the pending events in §5) even though it
plays no role in the lookup key.

## 3. Determining a `PARALLEL_GATEWAY` node's role: split, join, pass-through, or unsupported

**New private helper, described (not implemented):**

```elixir
@type gateway_role :: :split | :join | :pass_through | :combined_unsupported

@spec gateway_role(Graph.t(), Node.t()) :: gateway_role()
```

Computed from the node's degree in `definition_snapshot.edges`:
- `out_degree` = count of edges whose `source == node.id`.
- `in_degree` = count of edges whose `target == node.id`.
- `out_degree > 1 and in_degree <= 1` → `:split` (this occurrence spawns branches, §3.1).
- `in_degree > 1 and out_degree <= 1` → `:join` (this occurrence synchronizes branches, §4).
- `out_degree <= 1 and in_degree <= 1` → `:pass_through` — a degenerate `PARALLEL_GATEWAY` with
  exactly one in-edge and one out-edge is not itself a split or join; treated as an ordinary
  single-successor advance (same behavior as `:START`'s §6.1 in REQ-044), a defensive addition for
  a structurally-legal-but-semantically-odd graph, not a literal acceptance criterion (parallel to
  REQ-044 §6.1's own "more than one outgoing `:START` edge" defensive note).
- `out_degree > 1 and in_degree > 1` → `:combined_unsupported` — a single `PARALLEL_GATEWAY` node
  acting as both split and join simultaneously. **Not supported by this design, returns a named
  error rather than guessing at a combined semantics** (§7, §12.2 — flagged as an explicit open
  question, not silently resolved).

`dispatch_parallel_gateway/4`'s new top-level body (replacing REQ-044's stub) matches on
`gateway_role/2`'s result and routes to §3.1 (split), §4 (join), the `:pass_through` advance, or a
`{:error, {:combined_split_join_not_supported, node.id}}` result — never raises for any of the 4
cases, total over every possible in/out-degree combination.

### 3.1 SPLIT — `dispatch_parallel_split/4` (EE-06 AC1, AC2, AC3)

```elixir
@spec dispatch_parallel_split(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
        {:ok, InstanceState.t(), [Letflow.Engine.Transition.pending_event()]}
        | {:error, Letflow.Engine.Transition.transition_error()}
```

**Algorithm, described:**

1. `edges_out = Enum.filter(definition_snapshot.edges, &(&1.source == node.id))` — the split
   node's own outgoing edges, in `definition_snapshot.edges`' own declaration order (deterministic,
   same list-order argument REQ-044 §8 already relies on for `:START`).
2. For each `edge` at declaration-order index `i` (0-based) in `edges_out`, construct one child
   `Token.t()`:
   - `token_id = token.token_id <> "/" <> Integer.to_string(i)` — derived deterministically from
     the **parent token's own id plus this edge's declaration-order position**, not from
     `edge.id` (§3.2 explains why `edge.id` is deliberately not used).
   - `branch_id = token_id` — the same derived string doubles as this child token's `branch_id`.
     Stated explicitly as a simplification, not an oversight: nothing in `Token.t()`'s contract
     (REQ-044 §3) requires `token_id` and `branch_id` to differ, and giving them the same value
     removes a second, parallel (no pun intended) derivation formula that would otherwise have to
     independently guarantee its own uniqueness.
   - `node_id = edge.target`.
   - `waiting_child_instance_id = nil`.
3. `branch_ids = MapSet.new(Enum.map(new_tokens, & &1.branch_id))` — always has exactly
   `length(edges_out)` distinct members, since step 2's index `i` is unique per `edges_out`
   position by construction (satisfies AC1's "3 distinct branch_ids" for a 3-edge split).
4. Locate the matching join node via `find_matching_join/2` (§3.3). `{:error, :no_matching_join}` →
   this dispatch returns `{:error, {:no_matching_join_found, node.id}}` (§7) — a defensive,
   never-raising path for a structurally-legal-but-non-block-structured graph, not itself a named
   acceptance criterion (parallel to REQ-044 §6.1/§7.2's precedent for similar defensive additions).
5. On success (`{:ok, join_node_id}`): construct
   `%JoinCounter{join_node_id: join_node_id, origin_token_id: token.token_id,
   expected_from_branches: branch_ids, received_from_branches: MapSet.new(), cancelled_branches:
   MapSet.new()}` and `Map.put(instance_state.join_counters, join_node_id, new_counter)`
   (overwriting any prior cohort at that key — §2.1's flagged simplification).
6. `new_tokens_list = Enum.reject(instance_state.tokens, &(&1.token_id == token.token_id)) ++
   new_tokens` — the parent token is consumed (removed), the `length(edges_out)` children appended,
   in `edges_out`'s own order (deterministic list order, matching REQ-044 §8's precedent for
   `InstanceState.tokens`' order not being semantically meaningful but still deterministic).
7. Returns `{:ok, %InstanceState{instance_state | tokens: new_tokens_list, join_counters:
   updated_join_counters}, [split_pending_event]}` — `split_pending_event` per §5.1 (AC3's "emits a
   PendingEvent recording the split").

**AC2 ("a task completion on one branch never blocks another") is a property of the surrounding
system, not of this one dispatch call — stated explicitly, not silently assumed true by omission:**
each child token is independent list entry in `instance_state.tokens` after step 6; nothing in this
module's dispatch (nor any other REQ-044/REQ-051 dispatch clause) ever requires more than one
token to be present to process a `{:advance_token, some_branch_token_id}` event for any single
branch — the ordinary per-token dispatch (REQ-044 §6) already treats every token in `tokens`
independently. This design adds no cross-branch synchronization anywhere except at the join itself
(§4), so AC2 holds by the *absence* of any coupling mechanism between sibling branch tokens prior
to the join, not by an explicit check this design performs.

**AC4 ("all N tokens created in one transaction at the persistence layer") is explicitly NOT this
dispatch's job — restated from the requirement text, not silently dropped:** `dispatch_parallel_split/4`
returns one `InstanceState.t()` value with all N tokens already present in its `tokens` list — the
atomicity of persisting that value (REQ-047's future orchestration layer wrapping its own
`Repo.transaction/2` around the resulting `InstanceState` write) is REQ-047's scope, per the
requirement text's own "(EE-06 AC4/DB-03 -- the atomicity is REQ-047's orchestration job, the token
production is this requirement's)." This design produces the N-tokens-in-one-return-value shape
that makes REQ-047's later one-transaction persistence possible, and states this boundary
explicitly rather than attempting (out of scope) to design REQ-047's transaction itself.

### 3.2 Why child token/branch ids are derived, not minted — a necessary divergence from REQ-044 §8, stated explicitly

PROVENANCE (historical, not current decision authority):
REQ-044 §8's purity/determinism bar states "every id (`token_id`, `instance_id`) is always
supplied by the caller, never minted here" — true of every dispatch clause REQ-044 itself shipped
(`:START`/`:END`/`:HUMAN_TASK` never create a new token). **This requirement is the first case
where `transition/3` must create tokens that did not exist in its input.** Since `:rand`/`:crypto`/
any UUID-generation call is forbidden by the same purity bar (no non-determinism allowed —
REQ-044 §8's own determinism argument breaks immediately if two `==`-equal calls could produce
different fresh ids), the only purity-compatible option is a **deterministic function of already-
supplied data** — here, `parent_token.token_id <> "/" <> declaration_order_index`. This is stated
as a deliberate, necessary interpretation of "ids supplied by the caller," not a literal quote from
`transition.zig`'s own source (§0's access gap) — flagged again in §12.3 for REVIEWER/
RELEASE-VALIDATOR to re-check if R-Co source ever becomes reachable, matching REQ-044/REQ-049's own
precedent for similarly-reconstructed, similarly-flagged mechanisms.

PROVENANCE (historical, not current decision authority):
**Declaration-order index, not `edge.id`, is the uniqueness source — stated explicitly why:** §0
confirms no structural check (CHK-01..CHK-08) enforces `edge.id` uniqueness, not even within one
node's own outgoing edges ("`graph.zig` itself has none either" per `req028-graph-structural-
validator.md`'s own Edge field table). Using `edge.id` directly as the uniqueness source would
silently produce colliding `branch_id`s on a structurally-legal-but-duplicate-edge-id graph. The
0-based position of each edge within `edges_out` (§3.1 step 1) is unique by construction
regardless of `edge.id` content, and deterministic (same `definition_snapshot.edges` list order on
every call with `==`-equal input, per REQ-044 §8's own determinism argument for list-order-derived
decisions).

### 3.3 `find_matching_join/2` — locating the split's corresponding join node

```elixir
@spec find_matching_join(Graph.t(), Node.t()) :: {:ok, join_node_id :: String.t()} | {:error, :no_matching_join}
```

**Algorithm, described (not implemented):** for each of the split node's `length(edges_out)`
branches, walk forward from `edge.target` along `definition_snapshot.edges` (following each node's
own single outgoing edge — a well-formed single branch path between a split and its join has no
internal branching, §12.4's flagged assumption) until the first node whose `node_type ==
:PARALLEL_GATEWAY` is reached; record that node's `id` as "branch `i`'s first-reached gateway."
`find_matching_join/2` succeeds with `{:ok, join_node_id}` **iff every branch's first-reached
gateway is the same `node_id`** — that common id is the matching join. Any other outcome (a branch
reaches `:END` before any `PARALLEL_GATEWAY`, two branches disagree on which gateway they reach
first, or a branch's forward walk runs into a node with more than one outgoing edge before
reaching a gateway — an internally-branching branch, unsupported by this simple walk) returns
`{:error, :no_matching_join}`. Deterministic and pure: only reads `definition_snapshot.nodes`/
`edges`, no external state.

**This assumes a block-structured graph (one matching join per split, no internal branching within
a single branch) — an assumption this design does not verify is enforced anywhere upstream,
flagged explicitly as an open question (§12.4), not silently relied upon.**

### 3.4 `{:cancel_branch, branch_id}` — the new `transition_event/0` constructor (the cancelled-branch representation itself)

```elixir
@type transition_event ::
        {:advance_token, token_id :: String.t()}
      | {:cancel_branch, branch_id :: String.t()}
```

**This is the concrete, pure representation the requirement text requires this requirement (not
REQ-052) to define.** Handled in `transition/3`'s own top-level event match (REQ-044 §6's
composition step 1), alongside `{:advance_token, token_id}` — not inside `dispatch_node/4`'s
node-type table, since cancelling a branch acts on a token wherever it currently sits, independent
of which node type it currently occupies.

**Algorithm, described:**

1. `token = Enum.find(instance_state.tokens, &(&1.branch_id == branch_id))`. `nil` →
   `{:error, {:unknown_branch_id, branch_id}}` (§7) — covers both "this branch_id never existed"
   and "this branch already arrived at its join or was already cancelled" (both cases leave no
   live token with that `branch_id`, §4.2/this section's own step 5 both remove the token on
   resolution).
2. `tokens_without = Enum.reject(instance_state.tokens, &(&1.token_id == token.token_id))`.
3. `counter = Enum.find(Map.values(instance_state.join_counters), &MapSet.member?(&1.expected_from_branches, branch_id))`.
   `nil` → no cohort currently tracks this branch (defensive — should not occur if every split
   always registers a cohort per §3.1 step 5, but a total function handles it rather than assuming):
   return `{:ok, %InstanceState{instance_state | tokens: tokens_without}, []}` — the token is
   removed, nothing else to update.
4. Found (`counter` belongs to `join_node_id = counter.join_node_id`): `updated_cancelled =
   MapSet.put(counter.cancelled_branches, branch_id)`. Compute `join_outcome/1` (§4.1) against
   `%JoinCounter{counter | cancelled_branches: updated_cancelled}`:
   - `:wait` → store the updated counter back (`Map.put(instance_state.join_counters,
     join_node_id, updated_counter)`), return `{:ok, %InstanceState{instance_state | tokens:
     tokens_without, join_counters: updated_join_counters}, []}`.
   - `:cancel_join` (EE-07 AC4 — every expected branch is now either cancelled or, trivially,
     none ever arrived): remove the cohort (`Map.delete(instance_state.join_counters,
     join_node_id)`), set `instance_state.status = :cancelled`, return
     `{:ok, new_instance_state, [join_cancelled_pending_event]}` (§5.3).
   - `:fire` (a cancellation can be the event that completes the outstanding set when at least one
     sibling branch already arrived — §4.1 explains why this is also a fire trigger, not only an
     arrival): perform the same join-construction steps §4.2 step 6 describes (merge, build the
     outgoing token, delete the cohort), return `{:ok, new_instance_state,
     [join_fired_pending_event]}`.

## 4. JOIN — `dispatch_parallel_join/4` (EE-07 AC1, AC2, AC3, AC5)

```elixir
@spec dispatch_parallel_join(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
        {:ok, InstanceState.t(), [Letflow.Engine.Transition.pending_event()]}
        | {:error, Letflow.Engine.Transition.transition_error()}
```

Invoked when an ordinary `{:advance_token, token_id}` event resolves to a token positioned on a
`PARALLEL_GATEWAY` node whose `gateway_role/2` (§3) is `:join`.

### 4.1 `join_outcome/1` — the single shared fire/wait/cancel decision, used by both §3.4 and §4.2

```elixir
@type join_outcome :: :wait | :fire | :cancel_join

@spec join_outcome(Letflow.Engine.JoinCounter.t()) :: join_outcome()
```

Computed purely from a `JoinCounter`'s three sets:
- `still_outstanding = MapSet.difference(counter.expected_from_branches,
  MapSet.union(counter.received_from_branches, counter.cancelled_branches))`.
- `MapSet.size(still_outstanding) > 0` → `:wait` (EE-07 AC1/AC2: not every active branch has
  arrived yet).
- `still_outstanding` empty and `MapSet.size(counter.received_from_branches) == 0` → `:cancel_join`
  (every expected branch ended up cancelled, none ever arrived — EE-07 AC4).
- `still_outstanding` empty and `received_from_branches` non-empty → `:fire` (every branch that was
  ever going to arrive has arrived; any branches not in that set are cancelled, excluded from the
  wait — EE-07 AC2/AC3's "does not wait for the cancelled branch").

**This single function is the one place both the arrival dispatch (§4.2) and the cancellation
dispatch (§3.4) make the wait/fire/cancel decision — stated explicitly as a shared decision point,
not two independently-maintained copies of the same three-way branch, so a future change to the
rule only has one place to change.**

**Why a cancellation can trigger `:fire`, not only `:cancel_join` — explained, since this is easy
to get wrong:** EE-07 AC1 says the join "waits until all ACTIVE incoming tokens have arrived."
"Active" excludes cancelled branches (EE-07 AC2/AC3). If 3 branches are expected, 2 have already
arrived, and the 3rd is then cancelled (rather than arriving), the set of *active* branches (2) has
now fully arrived — the join should fire at the moment of that cancellation, exactly as it would
have fired had the 3rd branch instead arrived normally. `join_outcome/1`'s `received_from_branches
== ∅` check is precisely what distinguishes this case (`:fire`, since 2 branches did arrive) from
EE-07 AC4's case (`:cancel_join`, since **zero** branches ever arrived before the last cancellation
completed the set).

### 4.2 Arrival algorithm, described

1. `counter = Map.get(instance_state.join_counters, node.id)`. `nil`, or found but
   `not MapSet.member?(counter.expected_from_branches, token.branch_id)` → `{:error,
   {:unknown_branch_id, token.branch_id}}` (§7) — a token with no branch_id (`nil`, e.g. a token
   that was never split) or a stale/already-resolved branch arriving at a join it has no live
   cohort for both fall into this defensive path, matching REQ-044 §7.2/§7.3's precedent for
   naming the offending value rather than crashing.
2. `tokens_without = Enum.reject(instance_state.tokens, &(&1.token_id == token.token_id))` — the
   arriving branch token is consumed regardless of fire/wait outcome (mirrors REQ-044 §6.2's
   `:END` token-removal pattern).
3. `updated_received = MapSet.put(counter.received_from_branches, token.branch_id)`.
4. Compute `join_outcome/1` (§4.1) against `%JoinCounter{counter | received_from_branches:
   updated_received}`. By construction (step 1 already excluded branch_ids that are `nil` or
   outside `expected_from_branches`, and §3.4 never lets a branch be both received and cancelled —
   its own step 4 only proceeds down the `cancel_branch` path for a branch not already resolved),
   this outcome is always `:wait` or `:fire`, never `:cancel_join` (arrival always adds to
   `received`, never triggers the "zero ever arrived" case).
5. `:wait` → `Map.put(instance_state.join_counters, node.id, updated_counter)`, return
   `{:ok, %InstanceState{instance_state | tokens: tokens_without, join_counters:
   updated_join_counters}, []}`.
6. `:fire` → build the merged outgoing token (§4.3), remove the cohort
   (`Map.delete(instance_state.join_counters, node.id)`), return `{:ok, new_instance_state,
   [join_fired_pending_event]}` (§5.2).

### 4.3 Fire construction — the merged outgoing token, and where REQ-049's merge policy is invoked (AC6)

Shared by both fire paths (§3.4's cancellation-triggered fire and §4.2 step 6's arrival-triggered
fire) — described once here, both call sites apply it identically:

1. **Call `Letflow.Engine.VariableMerge.merge(instance_state.variables, %{}, nil)`** (REQ-049's own
   `merge/3`, reused verbatim — no second collision rule is defined anywhere in this module,
   satisfying AC6 at the call-graph level: an actual call into REQ-049's function, confirmable by
   `mix xref`, not merely a comment). Per `req049-variable-merge.md` §9, `merge(vars, %{}, nil)`
   always returns `{:ok, vars, []}` — this call is therefore a **no-op in practice given
   `InstanceState.variables`' current single-global-map shape (no per-branch variable overlay
   exists anywhere in this codebase, §0)**, but is a real function call this dispatch always makes
   at every join-fire, both so REQ-049's policy is the literal, inspectable mechanism (not merely
   asserted equivalent) and so a future requirement that *does* introduce branch-local variable
   scoping has a single call site to extend with real `incoming_variables` rather than having to
   invent one from scratch. **§12.5 states this resolution as an explicit open question** — see
   there for why "collisions between branches merging at the join" may instead require branch-local
   scoping this design does not build (no shipped infrastructure for it exists today).
2. `new_token_id = counter.origin_token_id <> "/" <> node.id <> "/joined"` — deterministic (§3.2's
   same reasoning: derived from already-known ids, never minted via `:rand`/`:crypto`).
3. `join_outgoing_edge = Enum.find(definition_snapshot.edges, &(&1.source == node.id))`. `nil` (a
   join node with no outgoing edge — structurally odd but not excluded by any CHK-01..CHK-08 check,
   §0) → this fire construction instead returns `{:error, {:unknown_node_id, node.id}}`, a
   defensive path mirroring REQ-044 §6.1's own `nil`-branch precedent for `:START`.
4. `new_token = %Token{token_id: new_token_id, node_id: join_outgoing_edge.target, branch_id: nil,
   waiting_child_instance_id: nil}` — `branch_id: nil` marks this token as no longer part of any
   branch: it represents the single, rejoined continuation of the main flow (matches `Token.branch_id`'s
   own existing doc, REQ-044 §3: "`nil` for a token that has never passed through a parallel
   split" — extended here to also mean "has passed through one and rejoined," stated explicitly as
   this design's own reading of that field, not a REQ-044 literal case).
5. `final_tokens = tokens_without ++ [new_token]` (`tokens_without` as computed by whichever caller
   — §3.4 step 2 or §4.2 step 2 — invoked this construction).
6. Result: `%InstanceState{instance_state | tokens: final_tokens, join_counters:
   Map.delete(instance_state.join_counters, node.id), variables: merged_variables}` (`merged_variables`
   from step 1, `== instance_state.variables` in practice per step 1's no-op note).

**Exactly-once firing (AC5) — the concrete mechanism, stated explicitly:** `Map.delete(instance_state.join_counters,
node.id)` happens on every `:fire` and `:cancel_join` outcome (§4.2 step 6, §3.4's `:cancel_join`/
`:fire` branches). Once deleted, any subsequent event referencing a `branch_id` that belonged to
that cohort finds no matching `counter` (§4.2 step 1, §3.4 step 3) and returns `{:error,
{:unknown_branch_id, _}}` rather than re-evaluating `join_outcome/1` — there is no code path that
can construct a second outgoing token from the same cohort, because the cohort's own record no
longer exists after the first fire.

**Order-independence (AC5's other half) — the concrete argument, not merely asserted:**
`join_outcome/1` (§4.1) is a pure function of a `JoinCounter`'s three **sets** — set union/
difference/membership are all commutative and order-independent by definition (Erlang/Elixir
`MapSet` equality does not depend on insertion order). Whichever sequence of `{:advance_token, _}`/
`{:cancel_branch, _}` events the caller feeds through `transition/3` one at a time, the `JoinCounter`
reaches the same final `{expected, received, cancelled}` triple regardless of arrival order, and
§4.3's fire construction reads only `counter.origin_token_id` and `node.id` (never anything
order-dependent, like "which branch arrived last") — so the resulting `new_token_id` and
`new_instance_state` are identical no matter which order the branches resolved in. This is the
same "==-equal input -> ==-equal output" determinism argument REQ-044 §8 already establishes,
applied to a multi-call sequence rather than one call.

## 5. `pending_event/0` — narrowed union (replacing REQ-044's `term()` placeholder)

```elixir
@type pending_event ::
        {:parallel_split, origin_token_id :: String.t(), gateway_node_id :: String.t(),
         branch_ids :: [String.t()]}
      | {:parallel_join_fired, join_node_id :: String.t(), origin_token_id :: String.t(),
         new_token_id :: String.t(), merge_events :: [Letflow.Engine.VariableMerge.merge_event()]}
      | {:parallel_join_cancelled, join_node_id :: String.t(), origin_token_id :: String.t()}
```

REQ-044 §4/§12.5 explicitly named REQ-051 as the requirement that narrows `pending_event/0` from
`term()` to a real closed union for EE-06/EE-07's payloads — this is that narrowing. `transition_event/0`'s
constructor set (§3.4) and `pending_event/0`'s constructor set are two independent unions (an
*input* event this module reacts to vs. an *output* signal it produces); no other requirement's
existing dispatch clause (`:START`/`:END`/`:HUMAN_TASK`/the catch-all) ever constructs any of these
3 new variants, matching REQ-044's own "every non-gateway case returns `pending_events: []`"
precedent unaffected by this addition.

### 5.1 `{:parallel_split, ...}` (EE-06 AC3)

Constructed once per successful `dispatch_parallel_split/4` call (§3.1 step 7): `origin_token_id`
is the consumed parent token's id, `gateway_node_id` is the split node's own id, `branch_ids` lists
the `length(edges_out)` new branch ids in declaration order (§3.1 step 6's own list order).
Satisfies AC3's "emits a `PendingEvent` recording the split" literally — a concrete, closed-union
constructor, not the `term()` placeholder REQ-044 left open.

### 5.2 `{:parallel_join_fired, ...}` (EE-07's successful-fire outcome)

Constructed at every `:fire` outcome (§4.2 step 6, §3.4's `:fire` branch): `join_node_id`/
`origin_token_id` identify which cohort fired, `new_token_id` is the merged continuation token's
id (§4.3 step 2), `merge_events` is whatever `VariableMerge.merge/3` returned in its own event list
(§4.3 step 1 — always `[]` given the current no-op call, but the field exists so a future
branch-local-scoping change (§12.5) has somewhere to carry real `VARIABLE_OVERWRITTEN` events
without changing this pending-event's shape).

### 5.3 `{:parallel_join_cancelled, ...}` (EE-07 AC4)

Constructed at every `:cancel_join` outcome (§3.4's `:cancel_join` branch, the only path that can
ever produce this outcome per §4.1). Names the cancelled join's `join_node_id`/`origin_token_id` —
the companion instance-level effect (`instance_state.status = :cancelled`, §3.4 step 4's
`:cancel_join` branch) is carried on the returned `InstanceState.t()` itself, not duplicated into
this event's own fields.

## 6. Reuse of REQ-049's merge policy — summary (full detail in §4.3)

**No second collision rule is defined anywhere in this module.** The one and only place this
module's dispatch touches `instance_state.variables` is §4.3 step 1's `VariableMerge.merge/3` call
— every other dispatch clause in this design (`dispatch_parallel_split/4`, the `:wait` branches of
§3.4/§4.2) never reads or writes `variables` at all. `Letflow.Engine.VariableMerge` is `alias`ed,
never re-implemented; its `merge_event()` type is reused verbatim inside `pending_event/0`'s
`{:parallel_join_fired, ...}` variant (§5.2) rather than a new event shape being invented for the
same concept.

## 7. `transition_error/0` — 4 new variants

```elixir
@type transition_error ::
        {:unknown_event_type, event :: term()}
      | {:unknown_token_id, token_id :: String.t()}
      | {:unknown_node_id, node_id :: String.t()}
      | {:gateway_not_yet_implemented, node_type :: atom(), node_id :: String.t()}
      | {:node_type_not_yet_implemented, node_type :: atom(), node_id :: String.t()}
      | {:unknown_branch_id, branch_id :: String.t()}
      | {:no_matching_join_found, split_node_id :: String.t()}
      | {:combined_split_join_not_supported, node_id :: String.t()}
```

`{:gateway_not_yet_implemented, :PARALLEL_GATEWAY, _}` is retired from this module's own possible
return values (REQ-044's stub is fully replaced) but stays in the type union unchanged, since
`:EXCLUSIVE_GATEWAY` (REQ-050) still uses it. The 3 new variants: `:unknown_branch_id` (§3.4 step
1, §4.2 step 1 — a `cancel_branch`/join-arrival referencing a branch with no live tracking),
`:no_matching_join_found` (§3.1 step 4 — a split whose branches never structurally reconverge),
`:combined_split_join_not_supported` (§3's `gateway_role/2` — a node acting as both split and join
at once, §12.2).

## 8. Cross-module dependencies

- **`Letflow.Definitions.Graph`, `Node`, `Edge`** (REQ-028, `status: done`) — `gateway_role/2` and
  `find_matching_join/2` (§3, §3.3) read `definition_snapshot.edges`/`nodes` directly; no new
  graph-shaped type is declared.
- **`Letflow.Engine.InstanceState`, `Token`** (REQ-044, `status: done`) — modified (`InstanceState`
  gains `join_counters`, §2.1) and read/written throughout; no redefinition, same structs.
- **`Letflow.Engine.VariableMerge`** (REQ-049, `status: done`) — `merge/3` called once per join-fire
  (§4.3 step 1); `merge_event()` type reused inside `pending_event/0` (§5.2). No direct dependency
  on any REQ-049-internal caller-composition detail (REQ-049 §8's own `Letflow.EventStore.append/2`
  step is *not* this module's concern — appending `PARALLEL_SPLIT`/`PARALLEL_JOIN_FIRED`/
  `PARALLEL_JOIN_CANCELLED`/`VARIABLE_OVERWRITTEN` events from this dispatch's `pending_event()`
  list is REQ-047's future orchestration job, exactly as REQ-044 §11 already scoped
  `pending_task_nodes`' eventual consumption to REQ-047).
- **New: `Letflow.Engine.JoinCounter`** (this requirement) — depended on by `InstanceState`
  (§2.1) and by every dispatch clause in §3/§4.
- **None on REQ-052** — stated per the handoff's explicit scope note: this design defines
  `{:cancel_branch, branch_id}` and its full pure handling (§3.4) entirely within REQ-051's own
  scope. REQ-052 is a **forward dependent**: its future caller-initiated `cancel_instance/N` path
  is expected to eventually emit `{:cancel_branch, branch_id}` events (one per still-open branch of
  an instance being cancelled) into this same `transition/3` entry point — not designed here, since
  REQ-052 does not exist yet and this module must not `alias`/call anything from it (mirrors REQ-044
  §10's REQ-043 non-dependency, REQ-049 §6's REQ-061 non-dependency).
- **None on `Letflow.Repo` or any `Ecto.Schema` module anywhere** — purity contract, §9.
- **Forward dependents (not yet built):** REQ-047 (task activation/completion orchestration —
  consumes the 3 new `pending_event()` variants, persists the N-token split atomically per §3.1's
  AC4 note, and is the natural place `{:cancel_branch, _}` events get driven from once REQ-052
  exists), REQ-052 (instance cancellation — the caller-initiated path that emits `{:cancel_branch,
  _}` events and separately persists the instance-level CANCELLED status this module's pure
  `:cancel_join` outcome already computes in-memory).

## 9. Purity and determinism (matching REQ-044 §8's bar)

**Purity:** `Letflow.Engine.JoinCounter` and every new/modified function in
`Letflow.Engine.Transition`/`InstanceState` depend on Elixir/Erlang stdlib only (`Enum`, `Map`,
`MapSet`, `Kernel`) plus `Letflow.Definitions.Graph`/`Node`/`Edge` (type references only) and
`Letflow.Engine.VariableMerge.merge/3` (itself pure, REQ-049 §10). No `alias Letflow.Repo`, no
`import Ecto.Query`, no `Ecto.Changeset`, no `Logger.*`, no clock read, no `:rand`/`:crypto` call
anywhere in this design's own additions (§3.2 already states explicitly why no id-minting call is
needed or permitted).

**Determinism:** every new decision point (`gateway_role/2`, `find_matching_join/2`, `join_outcome/1`,
the id-derivation formulas in §3.1/§4.3) is a pure function of its typed input alone — no random
tie-break, no wall-clock dependency, no external state read. §4.3's order-independence argument
extends this to sequences of calls, not just single calls.

**Verification method (grep/`mix xref`-checkable, matching REQ-044/REQ-049's precedent):**

```bash
grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\|Req\.\|File\.\|:rand\.\|:crypto\." lib/letflow/engine/join_counter.ex lib/letflow/engine/instance_state.ex lib/letflow/engine/token.ex lib/letflow/engine/transition.ex
```

must return zero matches.

## 10. Single hop per call — unaffected

Every dispatch this design adds (`dispatch_parallel_split/4`, `dispatch_parallel_join/4`, `{:cancel_branch,
_}`'s handling) still processes exactly one event and returns — a split never itself recursively
walks tokens onward past the newly-created branch positions, a join-fire never recursively advances
the newly-created merged token past the join's outgoing edge. Each of those is a separate future
`{:advance_token, _}` call the caller issues, matching REQ-044 §5's existing "single hop per call"
contract unchanged.

## 11. Acceptance-criteria traceability

| REQ-051 task acceptance criterion | Concrete design element |
|---|---|
| "a `PARALLEL_GATEWAY` with 3 outgoing edges produces exactly 3 tokens with 3 distinct `branch_id`s in one transition call" | §3.1 (algorithm, steps 1-3: `length(edges_out)` tokens, `branch_ids` `MapSet` always has that many distinct members) |
| "a join with 3 expected branches does not fire when 2 tokens have arrived and does fire when the 3rd arrives, asserted at both points" | §4.1 (`join_outcome/1`'s `:wait`/`:fire` distinction) + §4.2 (arrival algorithm) |
| "a join whose branch count is 3 but where 1 branch was cancelled via the EE-08 path fires when the remaining 2 active tokens arrive -- it does not wait for the cancelled branch" | §3.4 (`{:cancel_branch, _}` handling) + §4.1 (`still_outstanding` excludes `cancelled_branches`) + §4.2 |
| "when every branch of a split is cancelled before any reaches the join, the join node is cancelled and the instance status becomes CANCELLED" | §3.4 step 4's `:cancel_join` branch + §4.1's `received_from_branches == ∅` distinguishing check + §5.3 |
| "tokens arriving at a join in two different orders produce the identical post-join state, and the join fires exactly once in both orderings" | §4.3's "Exactly-once firing" + "Order-independence" paragraphs (the `Map.delete`-on-fire mechanism and the set-operation-commutativity argument) |
| "a variable key produced with different values on two parallel branches resolves through REQ-049's merge policy with a VARIABLE_OVERWRITTEN event, not through a second collision rule defined in this module" | §4.3 step 1 (the `VariableMerge.merge/3` call site) + §6 (no second rule anywhere in this module) + §12.5 (the honest open-question flag on what "at the join" precisely means given no branch-local scoping exists yet) |
| "REQ-051 itself defines the cancelled-branch/token representation (not deferred to REQ-052)" | §2 (`JoinCounter.cancelled_branches`) + §3.4 (the full `{:cancel_branch, branch_id}` pure event and its handling) — REQ-052 is named only as a forward dependent (§8), never aliased or called |
| "stays within `Transition`'s pure, no-I/O contract" | §9 |

## 12. Open questions — not resolved here

### 12.1 Multiple concurrent cohorts at the same join node (loop re-entry) — not supported

§2.1 states `InstanceState.join_counters` is keyed by `join_node_id` alone, meaning at most one
split/join cohort can be outstanding per join node at a time. A graph where the same split/join
pair sits inside a loop and could be re-entered before the first pass's join fires would have its
earlier `JoinCounter` silently overwritten by `Map.put` in §3.1 step 5. No acceptance criterion
exercises this; left for a future requirement (REQ-051 itself, revisited, or a later loop-support
requirement) to key `join_counters` by cohort instead, if loop re-entry into an unresolved parallel
construct turns out to be a real graph shape Letflow needs to support.

### 12.2 `:combined_split_join_not_supported` — a `PARALLEL_GATEWAY` node with both `in_degree > 1` and `out_degree > 1`

PROVENANCE (historical, not current decision authority):
§3's `gateway_role/2` refuses to guess a semantics for a single node acting as both split and join
simultaneously and returns a named error instead. Not verified against `transition.zig`'s literal
source whether R-Co supports this shape at all (§0's access gap) — flagged for
REVIEWER/RELEASE-VALIDATOR if source ever becomes reachable.

### 12.3 Deterministic id-derivation formula (§3.2, §4.3 step 2) — reasoned necessity, not verified

PROVENANCE (historical, not current decision authority):
The `parent_token_id <> "/" <> index` / `origin_token_id <> "/" <> join_node_id <> "/joined"`
formulas are this design's own resolution of a genuine purity constraint (§3.2), not a literal port
of `transition.zig`'s own id-generation approach (unreachable, §0). If R-Co source becomes
reachable, diff this choice against the real mechanism and flag any divergence to REVIEWER.

### 12.4 `find_matching_join/2`'s block-structured-graph assumption (§3.3)

Assumes every branch path between a split and its join contains no further branching node before
reaching the join, and that exactly one join node is reachable that way from every branch. Not
verified as enforced by any existing CHK-01..CHK-08 structural check (§0) — a graph violating this
assumption causes `dispatch_parallel_split/4` to return `{:error, {:no_matching_join_found, _}}`
rather than silently misbehaving (total, never-raising per §3.1 step 4), but whether Letflow's
structural validator *should* reject such graphs upstream (at `create/1` time, REQ-030) is left
for REQ-028/029's own CODE-DESIGNER to consider adding a check for, not resolved here.

### 12.5 "Variables merging at the join" — honest resolution given no branch-local scoping exists

PROVENANCE (historical, not current decision authority):
§4.3 step 1 calls `VariableMerge.merge/3` with `incoming_variables: %{}`, making it a no-op given
`InstanceState.variables`' current single-global-map shape (no per-branch overlay field exists on
`Token` or `InstanceState` anywhere in this codebase today, §0). Under this design's reading,
variable collisions between two concurrent branches are actually resolved earlier — at whichever
branch's own task-completion call happens to invoke `VariableMerge.merge/3` second, per REQ-049's
ordinary overwrite-plus-`VARIABLE_OVERWRITTEN`-event rule, since all branches already share one
`InstanceState.variables` map throughout their independent execution, not a per-branch-scoped copy
merged only at the join. **An alternative reading — branch-local variable scoping, with a real
merge happening only at join-fire time — was considered and explicitly not adopted**, because it
would require a new field (e.g. `Token.local_variables :: map()`) this design does not have
requirement-text or shipped-precedent grounds to invent (§0's access gap: `instance.zig`'s literal
`mergeVariables()` behavior at a join is unverified). Flagged here for REVIEWER/RELEASE-VALIDATOR
to confirm the adopted reading is correct, and for R-Co source review if it ever becomes reachable.
