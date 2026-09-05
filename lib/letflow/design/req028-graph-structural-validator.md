PROVENANCE (historical, not current decision authority):
# Design: REQ-028 — Graph structural validator (graph.zig, PD-02)

**Requirement:** REQ-028 (`docs/requirements.yaml`, stage S2)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** module/file layout, plain struct shapes, `@spec`s, the 8
named checks' exact trigger/violation semantics, and the DFS cycle-detection algorithm
— signatures and type shapes only. No implementation code, no function bodies. No
`.ex`/`.exs` file is written by this document; ELIXIR-DEV writes the real module from it.

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-028 (full entry) and REQ-029/030 (full entries, to confirm
  how the first two downstream consumers expect to call/extend this module — REQ-029
  "Extend[s] REQ-028's graph module" in place, REQ-030 wraps it inside a future
  `Letflow.Definitions` context module's `create/1`).
- `docs/guides/backend_developer_guide.md` — §2 (project structure), §3 (naming
  conventions, §3.5 error shapes — and see §8 below for why this module deliberately
  does not follow §3.5's `:ok | {:error, _}` convention).
- `docs/migration/stage-2-event-store-definitions.md` (full) — in particular the
  "Static-typing gap" finding, which this design cites directly in §9's node-type-validity
  open question.
PROVENANCE (historical, not current decision authority):
- **R-Co source, read directly, ported for behavior not code:**
  `C:\Users\tvolo\dev\ai-dala\R-Co\src\definition\graph.zig` — the real `validateGraph()`
  (lines ~191–384), its `dfsVisit` helper (lines ~395–442), `NodeType`/`GraphNode`/
  `GraphEdge`/`DefinitionGraph`/`Violation`/`ValidationResult` type definitions (lines
  ~29–172), and its `nodeExists`/`nodeIndex` linear-scan helpers (lines ~468–480). Note:
  this file's `NodeType` enum has **8** variants (includes `SUB_PROCESS`, added later for
  SPC-02) — REQ-028's own description explicitly overrides this with definition.md's
  **7-variant** PD-05-authoritative set (no `SUB_PROCESS`), so this design follows the
  requirement text, not the literal current `graph.zig` enum (see §3).
  `C:\Users\tvolo\dev\ai-dala\R-Co\src\design\definition.md` — the "graph.zig" section
  (module purpose, public interface, the "Named validation checks (PD-02)" table with
  CHK-01..CHK-08, the CHK-06 algorithm outline), "Key invariants" §4/§5, and the PD-01/
  PD-02 acceptance-criteria traceability table (both consulted for exact wording of
  violation triggers and the self-loop/gateway edge cases).
- Existing `lib/letflow/` conventions read directly: `lib/letflow/design/
  req022-tenant-schema-provisioning.md` (this project's established design-doc depth/style
  — followed here), `lib/letflow/oidc/` (a subdirectory of sibling modules —
  `claim_mapping.ex`, `token_verifier.ex`, etc. — with **no** root `lib/letflow/oidc.ex`
  aggregator file) versus `lib/letflow/identity.ex` + `lib/letflow/identity/*.ex` (a thin
  context module **with** a root file wrapping schema files). Both patterns exist in this
  codebase; §1 below explains which one REQ-028 follows and why.
  `lib/letflow/row_approval.ex` (plain-Ecto/no-process precedent — confirms this codebase
  already has precedent for "not everything is a GenServer/gen_statem," reinforcing that a
  pure stateless module needs no process/supervision entry at all).

## 1. Module naming and file layout

**`Letflow.Definitions.Graph`** — `lib/letflow/definitions/graph.ex`. One file, four
`defmodule` blocks: the primary `Letflow.Definitions.Graph` module (the `DefinitionGraph`
struct itself, `validate_graph/1`, and all 8 check functions), plus three small nested
modules defined in the same file: `Letflow.Definitions.Graph.Node` (`GraphNode`),
`Letflow.Definitions.Graph.Edge` (`GraphEdge`), and `Letflow.Definitions.Graph.Violation`.

PROVENANCE (historical, not current decision authority):
**Why the graph struct and the validator share one module name:** `graph.zig` itself
defines `DefinitionGraph`, `GraphNode`, `GraphEdge`, `Violation`, `ValidationResult`, and
`validateGraph()` all in one file with no further sub-namespacing. Elixir's idiom for "the
module IS the struct" (as every `Ecto.Schema` module in this codebase already does —
`Letflow.Identity.Tenant`, `Letflow.TenantProvisioning.Registration`) extends naturally
here even though this isn't a DB-backed schema: `Letflow.Definitions.Graph` both defines
`defstruct nodes: [], edges: []` (i.e. `%Letflow.Definitions.Graph{}` *is* the
`DefinitionGraph` value) and hosts `validate_graph/1`, which takes a value of its own
struct type. This avoids inventing an artificial second name for the exact same "the graph
being validated" concept the module's own name already denotes.

PROVENANCE (historical, not current decision authority):
**Why one file, not one file per struct:** Unlike `Letflow.Identity.Tenant`/`User`/`Group`
(real, independently-queried DB rows that get reused across many unrelated contexts and
so earn their own files), `Node`/`Edge`/`Violation` have no meaning or reuse outside graph
validation in this stage — they exist purely as the input/output shapes of
`Letflow.Definitions.Graph`'s own functions, exactly mirroring how `graph.zig` scopes them
to itself. REQ-029's own description says it "**Extend[s] REQ-028's graph module**" in
place (adding `validate_node_attributes/1` and the edge-condition checks to this same
file) — not "adds a sibling module" — confirming this file is meant to keep growing as one
unit through at least REQ-029, so splitting the tightly-coupled types out now would just
be undone/fought against by the very next requirement.

**Why no root `lib/letflow/definitions.ex` file yet:** REQ-030's own description names
"a `Letflow.Definitions` context module" as *its* deliverable (wrapping `create/1`,
`get_by_id/1`, `activate/1`, etc. — all of which need `Letflow.Repo`). Adding an empty or
near-empty root `Letflow.Definitions` module now, before there is any actual CRUD
operation to wrap, would either (a) sit unused until REQ-030, or (b) tempt someone to bolt
`validate_graph/1` onto it directly, which would be wrong — this module must stay
I/O-free (§8), and a context module whose job is CRUD is the wrong home for that
invariant to live next to. This mirrors the `lib/letflow/oidc/` precedent exactly: several
sibling modules (`ClaimMapping`, `TokenVerifier`, `IdentityContext`, ...) accumulated
under `oidc/` with no root aggregator file, because no single one of them is "the" OIDC
context — same shape here. `lib/letflow/definitions/` starts the same way; REQ-030 adds
the root file once there's a real context (Repo-backed CRUD) for it to hold.

## 2. Shared types — plain structs, no `Ecto.Schema`

None of the four types below are `Ecto.Schema` modules — they carry no DB table, no
`@primary_key`, no changeset. They are plain `defstruct`-based value types, matching the
requirement's own instruction ("Implement the shared types ... as plain structs/maps").

### 2.1 `Letflow.Definitions.Graph.Node` (ports `GraphNode`)

| Field | Type | Default | Notes |
|---|---|---|---|
| `id` | `String.t()` | *(required)* | Non-empty, expected unique within the definition — uniqueness is CHK-05's job, not enforced at construction. |
| `node_type` | `Letflow.Definitions.Graph.node_type()` (§3) | *(required)* | One of the 7 PD-05-authoritative variants. |
| `label` | `String.t() \| nil` | `nil` | Display label, optional. |
| `attributes` | `map() \| nil` | `nil` | **Provisional typing, flagged open in §9** — see there before treating this as final. |

PROVENANCE (historical, not current decision authority):
`@enforce_keys [:id, :node_type]` — a node with no `id`/`node_type` at all is a
construction-time error (raises), not a value CHK-03/CHK-05's string-equality logic would
otherwise have to silently tolerate as `nil`. `label`/`attributes` are genuinely optional
per `graph.zig`'s own `?[]const u8` typing, so they're plain defaulted fields, not
enforced.

### 2.2 `Letflow.Definitions.Graph.Edge` (ports `GraphEdge`)

PROVENANCE (historical, not current decision authority):
| Field | Type | Default | Notes |
|---|---|---|---|
| `id` | `String.t()` | *(required)* | Non-empty, expected unique within the definition (no named CHK-08-adjacent check validates edge-id uniqueness — `graph.zig` itself has none either; not invented here). |
| `source` | `String.t()` | *(required)* | Expected to reference an existing `Node.id` — CHK-03's job to verify, not enforced at construction. |
| `target` | `String.t()` | *(required)* | Same as `source`. |
| `condition` | `String.t() \| nil` | `nil` | CEL expression for `EXCLUSIVE_GATEWAY` routing (PD-06). **Not read by any of REQ-028's 8 checks** — carried on the struct now because the requirement's own field list names it, consumed starting at REQ-029. |
| `is_default` | `boolean()` | `false` | Same status as `condition`: present on the struct, unread by REQ-028's 8 checks, consumed starting at REQ-029. |

PROVENANCE (historical, not current decision authority):
`@enforce_keys [:id, :source, :target]`. Note this struct deliberately omits R-Co's
`transform` field (EXT-04) — REQ-028's own description lists exactly 5 `GraphEdge` fields
(`id/source/target/condition/is_default`), and `transform` is validated by a separate
`validateEdgeTransforms()` function in `graph.zig` that no REQ-028/029/030/032/036
requirement currently names as in scope. Not an oversight; follow the requirement text's
explicit field list.

### 2.3 `Letflow.Definitions.Graph.Violation`

PROVENANCE (historical, not current decision authority):
| Field | Type | Notes |
|---|---|---|
| `code` | `Letflow.Definitions.Graph.Violation.code()` — `atom()`, one of the 9 values in §5's table | Machine-readable. **Lowercase `snake_case` atom, not the SCREAMING_SNAKE_CASE string `graph.zig` uses** — see rationale below. |
| `message` | `String.t()` | Human-readable, names the offending node/edge ID per the requirement's own text. |

`@enforce_keys [:code, :message]` — both fields are always present together; there is no
partially-built `Violation`.

PROVENANCE (historical, not current decision authority):
**Why lowercase atom codes, diverging from `graph.zig`'s literal `"MISSING_START_NODE"`
string codes:** this is a deliberate Decision-A-style adaptation (Ecto-idiomatic redesign,
not a 1:1 port), stated explicitly rather than left as a silent divergence. Two reasons:
(1) it matches this codebase's own established precedent of lowercase atoms for
enumerated/coded values — REQ-027's `DefinitionStatus` maps `graph.zig`'s
`DRAFT/ACTIVE/DEPRECATED/ARCHIVED` to `:draft/:active/:deprecated/:archived` for exactly
this reason; (2) `atom()` pattern-matches directly in ExUnit assertions
(`assert %Violation{code: :missing_start_node} = ...`) and serializes predictably via
`Atom.to_string/1` for a future HTTP 422 body, without needing a second lookup table to
translate Zig's screaming-case strings into idiomatic Elixir values at every call site.
The exact code list is in §5's table — every code name is the natural `snake_case` of its
`graph.zig` counterpart, so anyone cross-referencing the two sources can still recognize
the mapping on sight.

### 2.4 `Letflow.Definitions.Graph` (ports `DefinitionGraph`)

| Field | Type | Default | Notes |
|---|---|---|---|
| `nodes` | `[Letflow.Definitions.Graph.Node.t()]` | `[]` | |
| `edges` | `[Letflow.Definitions.Graph.Edge.t()]` | `[]` | |

No `@enforce_keys` — an empty graph (`%Letflow.Definitions.Graph{}`, i.e. `nodes: []`,
`edges: []`) is a legal, constructible value; it simply fails CHK-01/CHK-02 when
validated (missing START and END), which is the correct way for "no nodes at all" to
surface, not a construction-time raise.

```
@type t :: %__MODULE__{
        nodes: [Letflow.Definitions.Graph.Node.t()],
        edges: [Letflow.Definitions.Graph.Edge.t()]
      }
```

## 3. `NodeType` — the 7-variant PD-05-authoritative set

```
@type node_type ::
        :START
        | :END
        | :HUMAN_TASK
        | :SERVICE_TASK
        | :EXCLUSIVE_GATEWAY
        | :PARALLEL_GATEWAY
        | :TIMER
```

**Kept as uppercase atoms (`:START`, not `:start`), unlike `Violation.code` in §2.3 —
this is a deliberate, separate choice, not an inconsistency.** REQ-028's own description
quotes these 7 names verbatim as "the authoritative set," directly warning that
`USER_TASK`/`SCRIPT_TASK` are superseded/wrong names R-Co's own docs flag — i.e. the
literal casing/spelling here is itself part of what the requirement is pinning down,
unlike `Violation.code`, which is this design's own internal machine-readable label with
no such external pin. `EXCLUSIVE_GATEWAY`/`PARALLEL_GATEWAY` membership is what CHK-06's
gateway exemption keys off (§6).

A module-level constant for the gateway subset (referenced repeatedly below as
`@gateway_types`) should hold the `MapSet` `#{:EXCLUSIVE_GATEWAY, :PARALLEL_GATEWAY}` —
i.e. exactly the two atoms CHK-06's gateway exemption tests membership against; the exact
mechanism (module attribute built at compile time vs. a private zero-arity function) is
ELIXIR-DEV's implementation choice, not specified further here.

PROVENANCE (historical, not current decision authority):
**Open question on enforcement — see §9.2.** Elixir's `atom()` type has no compile-time
membership check the way Zig's `enum` does; nothing in this design (or in `graph.zig`'s
own 8 checks) rejects a `Node` whose `node_type` is some other atom entirely.

## 4. Public function signature and result shape

```
@type result :: %{valid: boolean(), violations: [Letflow.Definitions.Graph.Violation.t()]}

@spec validate_graph(Letflow.Definitions.Graph.t()) :: Letflow.Definitions.Graph.result()
```

Returns a **bare map**, always — never wrapped in `{:ok, _}` / `{:error, _}`, and this is
a deliberate divergence from `backend_developer_guide.md` §3.5's usual
"functions that can fail return `:ok | {:error, term()}`" convention, stated explicitly
rather than silently ignored:

- `validate_graph/1` **cannot fail** in the Elixir sense of that convention. Given any
  well-typed `t()` input, it always successfully computes a result — either
  `%{valid: true, violations: []}` or `%{valid: false, violations: [%Violation{}, ...]}`.
  A structurally-invalid *input graph* is not a function *failure*; it is exactly the
  legitimate, expected output value the caller asked for.
PROVENANCE (historical, not current decision authority):
- This mirrors `graph.zig`'s own error taxonomy precisely: `GraphError` there has exactly
  one member, `OutOfMemory` — an allocator-failure case with **no Elixir equivalent**
  (Elixir doesn't surface allocation failure as an ordinary function return). `graph.zig`
  itself never treats "the graph is invalid" as the `GraphError!` case — that's always the
  success payload (`ValidationResult{ .valid = false, ... }`). Porting the shape
  faithfully means dropping the error union entirely, not inventing an Elixir-side
  `{:error, _}` case that has nothing real to map to.
- **Invariant, true by construction, not asserted separately at runtime:**
  `result.valid == (result.violations == [])`. §7 shows exactly how this holds.

## 5. The 8 named checks — exact trigger and violation semantics

PROVENANCE (historical, not current decision authority):
Every check reads directly from the raw `graph.nodes`/`graph.edges` lists passed into
`validate_graph/1` — **no check clamps/truncates the input first** (§7.3 explains why,
diverging from `graph.zig`'s `MAX_NODES`/`MAX_EDGES` array-safety clamp).

| # | Check (private fn) | Trigger | Violation code | Message (names the offending ID) |
|---|---|---|---|---|
| CHK-01 | `check_start_node/1` | zero nodes with `node_type == :START` | `:missing_start_node` | `"No START node found in the definition graph"` |
| CHK-01 | (same fn) | more than one node with `node_type == :START` | `:multiple_start_nodes` | `"Found <n> START nodes; exactly one is required"` (n = actual count) |
| CHK-02 | `check_end_node/1` | zero nodes with `node_type == :END` | `:missing_end_node` | `"No END node found in the definition graph"` |
| CHK-03 | `check_dangling_edges/1` | an edge's `source` matches no node's `id` | `:dangling_edge` | `"Edge '<edge_id>' has dangling source reference: node '<source>' does not exist"` |
| CHK-03 | (same fn) | an edge's `target` matches no node's `id` | `:dangling_edge` | `"Edge '<edge_id>' has dangling target reference: node '<target>' does not exist"` |
| CHK-04 | `check_isolated_nodes/1` | see type-specific rule below | `:isolated_node` | `"Node '<node_id>' is isolated (insufficient incoming or outgoing edges for its type)"` |
| CHK-05 | `check_duplicate_node_ids/1` | a node's `id` equals an earlier (lower-index) node's `id` | `:duplicate_node_id` | `"Duplicate node ID '<node_id>'"` |
| CHK-06 | `check_cycles/1` | DFS back-edge where neither endpoint is a gateway node — full algorithm in §6 | `:cycle_without_gateway` | `"Cycle detected: edge from node '<u_id>' to node '<v_id>' creates a cycle not passing through a gateway node"` |
| CHK-07 | `check_node_limit/1` | `length(graph.nodes) > 500` | `:node_limit_exceeded` | `"Node count <n> exceeds the maximum of 500"` |
| CHK-08 | `check_edge_limit/1` | `length(graph.edges) > 2000` | `:edge_limit_exceeded` | `"Edge count <n> exceeds the maximum of 2000"` |

Every private check function's signature: `@spec check_*(Letflow.Definitions.Graph.t()) ::
[Letflow.Definitions.Graph.Violation.t()]` — pure, total, takes the whole graph (even
checks that only look at `nodes` or only at `edges` take the full struct, for a uniform
signature §7's composition relies on), returns a (possibly empty) violation list.

PROVENANCE (historical, not current decision authority):
**CHK-03 detail — both endpoints of one edge can each independently fire:** if an edge has
*both* a dangling `source` and a dangling `target`, that is **two separate violations**,
not one — ported faithfully from `graph.zig`'s two independent `if` checks (not an
`if/else`). This is itself an instance of the never-short-circuit principle, one level
down: even within a single edge's checks, both endpoint checks always run.

PROVENANCE (historical, not current decision authority):
**CHK-04 detail — the exact per-node-type rule** (ported verbatim from `graph.zig`'s
`switch (node.node_type)`), using "has ≥1 incoming edge" / "has ≥1 outgoing edge" computed
only from edges whose *own* endpoints resolve to a real node (a dangling edge contributes
no connectivity to either side — CHK-03 already reports it separately):

PROVENANCE (historical, not current decision authority):
- `:START` → isolated iff it has **no outgoing** edge (incoming edges to a START node are
  never checked for this rule — `graph.zig` explicitly special-cases START to only need
  outgoing).
- `:END` → isolated iff it has **no incoming** edge (outgoing likewise unchecked for END).
- every other type (`:HUMAN_TASK`, `:SERVICE_TASK`, `:EXCLUSIVE_GATEWAY`,
  `:PARALLEL_GATEWAY`, `:TIMER`, and any node whose `node_type` isn't one of the 7 known
  atoms at all — see §9.2) → isolated iff it is **missing incoming OR missing outgoing**
  (both are required).

PROVENANCE (historical, not current decision authority):
**CHK-05 detail — "duplicate" is reported once per repeated occurrence, not once per
distinct ID:** ported from `graph.zig`'s `for (nodes, 0..) |node, i| { for (nodes[0..i])
... break }` — for node at index `i`, compare against every node at a strictly lower
index; on the first match found, emit one violation for node `i` and stop comparing
further back (the `break`). Concretely: if id `"A"` appears at indices 0, 1, and 2, index 0
gets no violation (nothing precedes it), index 1 gets one violation (matched against
index 0), and index 2 gets one violation (matched against index 0 or 1, whichever the
scan reaches first — either way, exactly one). **Three occurrences of the same id produce
two violations, not one and not three.**

PROVENANCE (historical, not current decision authority):
**Node/edge lookup semantics used by CHK-03/CHK-04/CHK-06 — "first match wins":** all
three checks that need to resolve a `node.id` string to "does this node exist" /
"which node is this" use the same linear-scan-returning-first-match semantics as
`graph.zig`'s `nodeExists`/`nodeIndex` helpers. §7.2 gives the exact idiomatic-Elixir
construction (`Map.put_new/3` over an indexed fold) and spells out the one genuinely
subtle corollary this has for CHK-04/CHK-06 when duplicate node IDs are also present.

## 6. CHK-06 — cycle detection (DFS), precisely

This is the check the task explicitly called out as needing to be concrete, not
hand-wavy, so this section spells out the exact traversal rule end to end.

### 6.1 Setup (done once, before any DFS call)

PROVENANCE (historical, not current decision authority):
1. **`node_index` — id → first-occurrence 0-based index map**, built via a left-to-right
   fold over `Enum.with_index(graph.nodes)` inserting with `Map.put_new/3` (which keeps
   the *first* inserted value on a repeated key and silently ignores later ones) — this is
   the precise Elixir construction that reproduces `graph.zig`'s `nodeIndex`'s
   linear-scan-returns-first-match behavior exactly, without needing a literal linear scan
   per lookup.
PROVENANCE (historical, not current decision authority):
2. **`adjacency` — a `%{non_neg_integer() => [non_neg_integer()]}` map** from a node's
   index to the list of target-node indices reachable via one direct outgoing edge, built
   by resolving every edge's `source`/`target` through `node_index` and **excluding any
   edge where either side fails to resolve** (a dangling edge — already reported by CHK-03,
   contributes no adjacency here, exactly matching `graph.zig`'s `nodeIndex(...) orelse
   continue` skip). Edge insertion order within each index's list is preserved
   (`graph.zig` iterates edges in declaration order; this design does too, for
   deterministic violation ordering). **A self-loop edge (`source == target`, both
   resolving to the same index `u`) is included as `u → u`** — this is exactly how §6.3
   catches self-loops; it is not a separate code path.
3. **`gateway_set` — a `MapSet.t(non_neg_integer())`** of every node index whose
   `node_type` is in `@gateway_types` (§3).

### 6.2 Outer driver — visit every component, not just nodes reachable from START

PROVENANCE (historical, not current decision authority):
Fold over node indices `0..(length(graph.nodes) - 1)`, carrying a `visited ::
MapSet.t(non_neg_integer())` accumulator (starts empty) and a `violations ::
[Violation.t()]` accumulator (starts empty) across the fold. For each index `i` **not
already in `visited`**, call `dfs_visit(i, adjacency, gateway_set, graph.nodes, visited,
MapSet.new())` (a **fresh empty `on_stack`** for every new top-level call — `on_stack` is
scoped to one DFS tree's current root-to-leaf path, never shared across disconnected
components), and fold its returned `{visited, violations}` forward as the new
accumulators. Visiting every unvisited node this way (not just a single DFS from every
`:START` node) matters because CHK-06 must also catch a cycle entirely contained in a
disconnected "island" that no START node reaches — `graph.zig`'s own `for (0..n_safe) |i|
{ if (!visited[i]) ... }` driver loop does exactly this, and it's ported unchanged.

### 6.3 `dfs_visit(u, adjacency, gateway_set, nodes, visited, on_stack)`

```
@spec dfs_visit(
        u :: non_neg_integer(),
        adjacency :: %{non_neg_integer() => [non_neg_integer()]},
        gateway_set :: MapSet.t(non_neg_integer()),
        nodes :: [Letflow.Definitions.Graph.Node.t()],
        visited :: MapSet.t(non_neg_integer()),
        on_stack :: MapSet.t(non_neg_integer())
      ) :: {visited :: MapSet.t(non_neg_integer()), violations :: [Letflow.Definitions.Graph.Violation.t()]}
```

Behavior, precisely:

1. `visited' = MapSet.put(visited, u)`, `on_stack' = MapSet.put(on_stack, u)` — mark `u`
   visited (permanently) and on-stack (only for the duration of this call, including every
   nested recursive call it makes).
2. Fold over `Map.get(adjacency, u, [])` (the list of `u`'s direct successor indices, in
   edge-declaration order), threading `{visited, violations}` across the fold (`on_stack'`
   itself does not change within this fold — it only grows/shrinks around the *whole* call
   to `dfs_visit(u, ...)`, not per sibling edge):
   - **If `v` is a member of `on_stack'`:** `v` is an ancestor of `u` on the current path
     (or `v == u`, the self-loop case) — this edge is a **back-edge**, i.e. a cycle.
     - If `u` is **not** in `gateway_set` **and** `v` is **not** in `gateway_set`: append
       one `:cycle_without_gateway` violation naming `Enum.at(nodes, u).id` and
       `Enum.at(nodes, v).id` (source-node id, then target-node id, matching the edge's own
       direction).
     - Otherwise (at least one endpoint is a gateway node): **no violation** — the cycle is
       permitted. This is exactly AC4's "a cycle that passes through an
       EXCLUSIVE_GATEWAY or PARALLEL_GATEWAY node is explicitly permitted" requirement:
       it suffices for **either** endpoint of the closing back-edge to be a gateway.
     - Do **not** recurse into `v` in either case (it's already on the stack).
   - **Else if `v` is not a member of `visited'`:** unvisited — recursively call
     `dfs_visit(v, adjacency, gateway_set, nodes, visited', on_stack')`, and take its
     returned `{visited'', violations''}` forward as this fold step's new accumulator
     (both propagate; the *returned* `on_stack` from the recursive call is discarded —
     see point 3 below for why that's always safe).
   - **Else** (`v` is in `visited'` but not in `on_stack'`): `v` was already fully explored
     via some *other* path — a cross/forward edge in DFS terms, not an ancestor
     relationship, so **not** a cycle regardless of gateway status. No violation, no
     recursion, accumulators pass through unchanged.
PROVENANCE (historical, not current decision authority):
3. Return `{visited_after_fold, violations_after_fold}` — a 2-tuple, not 3. `on_stack`
   never needs to propagate back up to the caller: by the time `dfs_visit(u, ...)` returns
   (after every one of `u`'s outgoing edges has been processed, exactly matching
   `graph.zig`'s `on_stack[node_idx] = false` at the very end of `dfsVisit`), `u`'s
   presence on the recursion path is logically over — the caller's own `on_stack'`
   (from *its* frame) is already correct without needing anything back from this call.

### 6.4 The self-loop / gateway corollary — stated explicitly, not silently resolved

REQ-028's acceptance criterion 4 requires a self-loop to be rejected, tested separately
from the gateway-permits-cycles case. **The algorithm above does not special-case
self-loops as a distinct rule** — a self-loop is simply the case `u == v` inside step 2's
back-edge branch, where `u` is *literally the same node* as `v`. That means:

- A self-loop on a **non-gateway** node (e.g. `:HUMAN_TASK`) → `u` is not a gateway and `v`
  (== `u`) is not a gateway → **rejected**, `:cycle_without_gateway`. **This is the case
  REQ-028's acceptance criterion 4 tests.**
PROVENANCE (historical, not current decision authority):
- A self-loop on an `:EXCLUSIVE_GATEWAY`/`:PARALLEL_GATEWAY` node → both `u` and `v` (== `u`)
  are the same gateway node → by the identical rule, **permitted, no violation** — this
  falls directly out of `graph.zig`'s own literal `dfsVisit` (its `is_gateway[node_idx]`
  and `is_gateway[t]` checks are the same array lookup when `node_idx == t`), not a new
  behavior invented here. **Flagged explicitly because it's a non-obvious corollary of the
  ported algorithm, not because any current acceptance criterion exercises it** — a
  self-loop on a gateway node is a structurally odd graph (a gateway routing only to
  itself) that no requirement currently tests either way. TEST-DESIGNER's self-loop test
  for AC4 must use a non-gateway node type to get the rejection the AC asks for.

## 7. Composition — the never-short-circuit invariant, and check independence

### 7.1 Composition — fixed order, unconditional, concatenated

PROVENANCE (historical, not current decision authority):
`validate_graph/1`'s body calls all 8 check functions **unconditionally, every time**,
against the *same*, unmodified `graph` argument, and concatenates their results in this
fixed order (matching `graph.zig`'s own literal source order, so any hand-traced example
carried over from R-Co lines up the same way):

1. `check_node_limit/1` (CHK-07)
2. `check_edge_limit/1` (CHK-08)
3. `check_duplicate_node_ids/1` (CHK-05)
4. `check_start_node/1` (CHK-01)
5. `check_end_node/1` (CHK-02)
6. `check_dangling_edges/1` (CHK-03)
7. `check_isolated_nodes/1` (CHK-04)
8. `check_cycles/1` (CHK-06)

`violations = Enum.flat_map([&check_node_limit/1, ...], & &1.(graph))` (or the equivalent
`++`-chain) — either is a valid ELIXIR-DEV implementation choice; the requirement on this
design is the **order** and the **unconditional-concatenation** shape, not the specific
combinator. Final result: `%{valid: violations == [], violations: violations}` — this is
exactly how §4's `valid == (violations == [])` invariant holds by construction, with no
separate assertion needed.

### 7.2 Are all 8 checks independent, or does any check need to run first to be meaningful?

**Answer: all 8 checks run fully independently against the raw input `graph` — none is a
hard prerequisite for another to produce a meaningful result.** Specifically:

- CHK-03 (dangling edges) is a pure existence test (`node_index` lookup succeeds or
  doesn't) — unaffected by whether CHK-05 found duplicate IDs elsewhere, since existence
  doesn't care *how many* nodes share an id, only whether *at least one* does.
- CHK-04 and CHK-06 both build their own index/adjacency structures fresh from `graph`
  (§6.1) rather than depending on any other check's output — they do not need CHK-05 or
  CHK-03 to have "cleaned" the input first.
- CHK-01/CHK-02/CHK-07/CHK-08 are simple counts/lengths over the raw lists, trivially
  independent of everything else.

PROVENANCE (historical, not current decision authority):
**The one genuinely subtle interaction, stated explicitly rather than glossed over:**
CHK-04 and CHK-06 both resolve `node.id` strings to indices via the same
first-match-wins `node_index` map (§6.1). If the graph *also* has duplicate node IDs
(a CHK-05 violation, reported independently and additionally), every edge referencing that
repeated id gets attributed to the **first** node carrying it — a later node at a higher
index with the same id can end up looking isolated (CHK-04) or absent from the cycle graph
entirely (CHK-06) even though "the id" it shares has edges, simply because those edges
were credited to the earlier same-id node instead. This is not a bug introduced by this
design — it's `graph.zig`'s own `nodeIndex`/`nodeExists` linear-scan-first-match behavior,
ported faithfully (§6.1) — but it's worth stating plainly here: a graph with duplicate
node IDs will *always* also get flagged by CHK-05 in the same call (that's unconditional,
§7.1), so a duplicate-id graph never silently passes as valid just because CHK-04/CHK-06's
per-node attribution came out oddly for the duplicated id.

### 7.3 Deliberate divergence: no `MAX_NODES`/`MAX_EDGES` clamp-and-continue

PROVENANCE (historical, not current decision authority):
`graph.zig` clamps `nodes`/`edges` to the first `MAX_NODES`/`MAX_EDGES` entries
*after* recording the CHK-07/CHK-08 violation, and every subsequent check in that function
operates only on the clamped slice — driven entirely by Zig's fixed-size stack arrays
(`[MAX_NODES]bool`, `[MAX_EDGES]u16`), a memory-safety mechanism with **no Elixir
equivalent need**: `MapSet`/`Map`/`List` here have no fixed capacity to overflow. This
design's checks (§5's table, §6.1) therefore run against the **full, unclamped**
`graph.nodes`/`graph.edges` every time, even past 500 nodes / 2000 edges — CHK-07/CHK-08
still fire (§5), but CHK-01 through CHK-06 see every node/edge, not just the first 500/
2000. This is a Decision-A-style adaptation (Ecto-idiomatic redesign, not a 1:1 port),
stated explicitly rather than silently diverging: inventing an arbitrary
first-500-nodes-only truncation rule for the pathological over-limit case would add
undocumented, untested behavior with no requirement asking for it, purely to imitate a
Zig memory-safety mechanism Elixir doesn't need.

## 8. Purity / zero-I/O invariant (AC5)

PROVENANCE (historical, not current decision authority):
`Letflow.Definitions.Graph` depends on **Elixir/Erlang stdlib only** — `Enum`, `Map`,
`MapSet`, `String`, `Kernel`. No `alias Letflow.Repo`, no `import Ecto.Query`, no
`Ecto.Changeset` anywhere in the module. No `Logger.*` call. No clock read
(`DateTime.utc_now/0`, `System.os_time/1`, etc.) anywhere — none of the 8 checks or the
DFS helper have any reason to read the time. No `File.*`/`HTTPoison`/`Req.*`/`:httpc`/
process-mailbox call (`GenServer.call`, `send`, etc.) — the whole module is a set of pure
functions over immutable structs, matching `graph.zig`'s own documented purity contract
("no I/O, no DB calls, no logging, no clock reads") verbatim.

**Verification method for REVIEWER/RELEASE-VALIDATOR (grep-checkable, not just
asserted):** `grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|HTTPoison\|Req\.\|File\." lib/letflow/definitions/graph.ex` must return zero matches. `mix xref graph
Letflow.Definitions.Graph` (or an equivalent `mix xref` call graph query) should confirm
`Letflow.Repo` never appears as a callee, direct or transitive, satisfying AC5's "call
sites confirm zero Repo/database calls anywhere in its call graph" literally.

## 9. Open questions — not resolved here

### 9.1 `Node.attributes` typing: raw JSON string vs. decoded map

PROVENANCE (historical, not current decision authority):
`graph.zig`'s `GraphNode.attributes` is `?[]const u8` — a raw JSON-object *string*,
re-parsed on demand by whichever function needs it (`validateNodeAttributes`'s
per-node-type checks, not any of REQ-028's own 8 checks — **none of CHK-01..CHK-08 ever
reads `attributes`**). This design provisionally types it `map() | nil` (§2.1) rather than
`String.t() | nil`, reasoning that Elixir/Jason naturally decodes a `jsonb` column's
contents to a map, and there's no allocator-lifetime reason (unlike Zig) to keep it as an
undecoded string in between. **This is a provisional choice REQ-028 itself never
exercises or tests** — REQ-029 is the first requirement whose `validate_node_attributes/1`
actually reads `attributes`' contents, and REQ-029's own CODE-DESIGNER should confirm or
override this typing at that point rather than this document quietly deciding it by
default.

### 9.2 No 9th check for "node_type is one of the 7 known values"

PROVENANCE (historical, not current decision authority):
Neither `graph.zig`'s 8 checks nor this design's ported 8 checks include a check that
`node.node_type` is actually one of the 7 (or 8, in the current `graph.zig`) valid
enum variants — in Zig this is structurally unnecessary, since the `enum` type system
makes an invalid `NodeType` value impossible to construct at all. **Elixir's `atom()` has
no equivalent compile-time enforcement** — nothing prevents constructing
`%Node{id: "n1", node_type: :BOGUS}`, and none of CHK-01 through CHK-08 would flag it
specifically (it would just fall through CHK-04's generic "neither START nor END nor
gateway" branch, §5, same as any other non-special type). This is directly the kind of gap
`docs/migration/stage-2-event-store-definitions.md`'s own "Static-typing gap" finding
warns to re-check rather than assume is harmless as the schema grows. **Not resolved
here** — flagged for REQ-029 (which is already extending this same module) or a future
requirement to decide whether an explicit `:invalid_node_type`-equivalent 9th check
belongs in this module, or whether that validation is better placed at the JSON-decoding
boundary (§9.3) instead, before a `Node` struct with a bogus `node_type` can ever be
constructed at all.

### 9.3 Who decodes the raw `graph` `jsonb` column into `Graph.t()`/`Node.t()`/`Edge.t()`?

PROVENANCE (historical, not current decision authority):
REQ-027 (schema-only, not yet built) stores `graph` as a raw `jsonb` column
(`{"nodes": [...], "edges": [...]}`). This design's `validate_graph/1` takes an
**already-constructed** `Letflow.Definitions.Graph.t()` struct — it does not parse JSON
itself (staying consistent with `graph.zig`'s own purity contract: no I/O, and JSON
parsing of a raw DB column value isn't this module's concern either). **Nothing in
REQ-028's scope names which function decodes the raw map (from `Jason`/Ecto's `jsonb`
deserialization, which yields string-keyed maps with string `node_type` values, e.g.
`"START"`) into this module's atom-keyed, atom-typed struct.** REQ-030's `create/1` is the
first requirement whose description implies it (calling `validateGraph()` on data that
came from a request body), so REQ-030's CODE-DESIGNER should either name a
`Letflow.Definitions.Graph.from_map/1`-equivalent conversion function explicitly, or
confirm the decoding happens somewhere else in the create path — left open here rather
than silently assumed.

## 10. Cross-module dependencies

- **None** inside `lib/letflow/`. This module is a intentionally leaf node with zero
  dependencies on any other Letflow module — no `Letflow.Repo`, no `Letflow.Identity.*`,
  no `Letflow.Definitions.*` sibling (there are none yet). This is what makes "genuinely
  simple, self-contained" (this handoff's own framing) literally true at the dependency
  level, not just in scope size.
- **Forward dependents (not yet built):** REQ-029 extends this exact file/module with
  `validate_node_attributes/1` and edge-condition checks. REQ-030's future
  `Letflow.Definitions` context module calls `validate_graph/1` (and REQ-029's additions)
  from inside `create/1`'s pre-write validation pipeline (Key invariant 1 from
  `definition.md`: "no bypass path exists" — REQ-030's job to enforce, not this one's).

## 11. Acceptance-criteria traceability

| REQ-028 acceptance criterion | Concrete design element |
|---|---|
| "a graph satisfying all 8 checks returns `{valid: true, violations: []}`" | §4 (`result` type, `valid == (violations == [])` invariant) + §7.1 (unconditional concatenation — all 8 check functions return `[]` when nothing's wrong, so the concatenated list is `[]`, so `valid: true`) |
| "each of the 8 named checks (CHK-01 through CHK-08) has at least one explicit failing-example test demonstrating its specific violation code is returned" | §5's table — every one of the 9 distinct violation codes (CHK-01 alone produces 2) has an exact trigger condition and exact message template TEST-DESIGNER can build a minimal failing fixture from directly, with no further interpretation needed |
| "a graph violating 3 of the 8 checks simultaneously returns all 3 violations in one call, not just the first encountered (Key invariant 5)" | §7.1 (fixed-order, unconditional call to all 8 check functions against the same unmodified input, concatenated — no early return anywhere in the composition) + §7.2 (explicit proof that no check depends on another's outcome to be meaningful, so 3 independently-triggerable violations really do all fire together) |
| "a cycle that passes through an EXCLUSIVE_GATEWAY or PARALLEL_GATEWAY node is explicitly permitted (not flagged as CYCLE_WITHOUT_GATEWAY), and a self-loop is explicitly rejected, each with its own test" | §6.3 step 2's back-edge branch (either endpoint being a gateway suppresses the violation) + §6.4 (self-loop is the same rule with `u == v`; explicit note that TEST-DESIGNER's self-loop test must use a non-gateway node type to get the AC's expected rejection, and the corollary that a gateway self-loop would be permitted by the identical, faithfully-ported rule) |
| "the function signature and its call sites confirm zero Repo/database calls anywhere in its call graph" | §8 (explicit stdlib-only dependency list, zero I/O primitives named, grep/`mix xref` verification method spelled out) + §10 (zero `lib/letflow/` cross-module dependencies at all) |
