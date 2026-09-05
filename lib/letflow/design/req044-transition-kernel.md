PROVENANCE (historical, not current decision authority):
# Design: REQ-044 — Pure transition kernel skeleton (transition.zig EE-02)

**Requirement:** REQ-044 (`docs/requirements.yaml`, stage S3)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the `Letflow.Engine.InstanceState` and `Letflow.Engine.Token`
struct shapes, the `Letflow.Engine.Transition` module's `transition_event/0`/`pending_event/0`/
`transition_error/0` types, `transition/3`'s full `@spec`, the 5-way (+1 catch-all) node-type
dispatch skeleton, the two explicit error paths, and the two verbatim moduledoc-text sections the
handoff calls out by name. Signatures and type shapes only — no implementation code, no function
bodies, no `.ex`/`.exs` code block contains real logic.

## 0. Sources read for this design, and an explicit access gap

- This handoff's `context.requirement_text.REQ-044` (quoted in full where load-bearing) and
  `task.acceptance_criteria` — read directly, not via `docs/requirements.yaml`, per
  `core-directives.md`'s "Load Scoped Context, Not Whole Files." One targeted lookup was made
  against `docs/requirements.yaml` to resolve REQ-043's own text (a `depends_on`-adjacent
  cross-reference the task explicitly asks this design to reconcile — see §10) via
  `awk '/^  - id: REQ-043$/,/^  - id: REQ-044$/' docs/requirements.yaml`, reading only that one
  entry.
- `lib/letflow/definitions/graph.ex` (full, current `main`, REQ-028/REQ-029, both `status: done`)
  — the `Letflow.Definitions.Graph`/`Node`/`Edge`/`Violation` structs and the 8-variant
  `node_type()` union this design reuses directly (§1, §2).
- `docs/migration/stage-3-instance-engine.md` (full) — scope boundaries with S4/S5, the
  EE-01..EE-12 seam breakdown, the "process-vs-row" open question REQ-045 (not REQ-044) owns, and
  the explicit confirmation that HTTP/status-code mapping is S4's job, not this module's.
- `docs/guides/backend_developer_guide.md` (full) — §3.5's usual `:ok | {:error, _}` error-shape
  convention (followed here, unlike `Letflow.Definitions.Graph.validate_graph/1`'s deliberate
  divergence — see §6's note on why this module *does* use the ordinary convention).
- `docs/anti-patterns.md` (current entries) — no entry currently bears on this module.
- `lib/letflow/design/req028-graph-structural-validator.md` and
  `lib/letflow/design/req029-node-attribute-edge-condition-validators.md` (full) — the established
  purity-bar precedent (§8 of both: stdlib-only, zero `Repo`/`Logger`/clock/`File`/HTTP calls,
  grep/`mix xref`-checkable) this design matches, and the exact style/depth this document follows.
- `lib/letflow/event_store/instance_projection.ex` (full, current `main`, REQ-023, `status: done`)
  — read to resolve REQ-044's own instruction to pick `InstanceState.status` values
  "source-compatible with REQ-043's future `Ecto.Enum`." That schema's `status` field already
  declares `values: [active: "ACTIVE", completed: "COMPLETED", cancelled: "CANCELLED",
  error: "ERROR"]` — i.e. the atoms `:active | :completed | :cancelled | :error` are not a guess,
  they are the literal atom set REQ-023 already shipped and REQ-043's ALTER TABLE migration
  confirmed (not re-added) as unchanged. §10 states this as the resolved dependency-ordering note.

PROVENANCE (historical, not current decision authority):
**Access gap, stated explicitly rather than silently worked around:** this environment has no
`R-Co/src/engine/transition.zig` or `R-Co/src/design/engine.md` reachable (searched the whole
filesystem for `transition.zig`/`engine.md`/any `R-Co` directory — no match), the same class of
gap REQ-029's design doc §0 flagged for `graph.zig`/`definition.md`. This design is therefore
built from `context.requirement_text.REQ-044`'s own text (already described by ORCH as containing
the load-bearing quotes from `engine.md` section EE-02) plus the already-shipped precedent in
`lib/letflow/definitions/graph.ex` and `lib/letflow/event_store/instance_projection.ex`.
Consequence, flagged inline at each place it matters rather than glossed over: **the exact
node-dispatch algorithm for `:START` (which outgoing edge is "the" one when more than one exists)
and for `:END` (the precise multi-token completion rule behind "moves the instance toward
COMPLETED")** are this design's own reasoned reconstructions from the requirement text's wording,
not verified against `transition.zig`'s literal source — see §6.1/§6.2 and §12.1/§12.2 for the
explicit reconstruction and its flag.

## 1. Module/file layout, and reuse of REQ-028's graph structs

**Three files, one struct-per-file, mirroring `Letflow.Definitions.Graph`'s "the module IS the
struct" precedent but *not* its single-file convention:**

| File | Module | Contents |
|---|---|---|
| `lib/letflow/engine/instance_state.ex` | `Letflow.Engine.InstanceState` | The `InstanceState` struct + `@type t/0` + `@type status/0` (§2) |
| `lib/letflow/engine/token.ex` | `Letflow.Engine.Token` | The `Token` struct + `@type t/0` (§3) |
| `lib/letflow/engine/transition.ex` | `Letflow.Engine.Transition` | `transition_event/0`, `pending_event/0`, `transition_error/0` types (§4), `transition/3` (§5), the dispatch skeleton (§6), and the two verbatim moduledoc sections (§9, §10) |

**Why three files, not one (diverging from `graph.ex`'s single-file convention, stated
explicitly):** `Letflow.Definitions.Graph.Node`/`Edge`/`Violation` earned a single shared file
because REQ-028's design doc §1 established they "have no meaning or reuse outside graph
validation." `InstanceState` and `Token` are the opposite case — they are the **central value
types of the entire S3 instance engine**, not scoped to `transition/3` alone. `docs/migration/
stage-3-instance-engine.md` names REQ-045 (instance runtime), REQ-047 (task activation), REQ-052
(cancellation), REQ-053 (reconstruction), and REQ-054 (state snapshotting) as later consumers that
will construct, read, and mutate `InstanceState`/`Token` values directly — several of them (e.g.
REQ-053's reconstruction fold, REQ-054's snapshot writer) have no inherent reason to `alias
Letflow.Engine.Transition` at all. Giving `InstanceState`/`Token` their own files, each "the
module IS the struct" (matching every `Ecto.Schema` module in this codebase, and
`Letflow.Definitions.Graph` itself), follows this codebase's other established sibling-files
precedent instead — `lib/letflow/identity.ex` + `lib/letflow/identity/*.ex`'s family of
independently-relevant schema files, cited by REQ-028's own design doc §1 as the alternative
pattern to `graph.ex`'s single-file one. `Letflow.Engine.Transition` itself stays a third,
separate file because *it* — unlike `InstanceState`/`Token` — genuinely is scoped only to the
pure transition kernel's own dispatch logic, the same reasoning `graph.ex` used for
`validate_graph/1` living beside the types it operates on.

**Reuse of REQ-028's graph structs — no redefinition, stated per the task's explicit
instruction:** `Letflow.Engine.Transition.transition/3`'s first parameter is typed exactly
`Letflow.Definitions.Graph.t()` (§5) — the same struct `lib/letflow/definitions/graph.ex` already
defines and REQ-028/029 already shipped. Node lookups inside the dispatch (§6) read
`definition_snapshot.nodes` (a `[Letflow.Definitions.Graph.Node.t()]`) and compare each node's
`node_type` field against `Letflow.Definitions.Graph.node_type()`'s existing 8-variant
`@type` (`:START | :END | :HUMAN_TASK | :SERVICE_TASK | :EXCLUSIVE_GATEWAY | :PARALLEL_GATEWAY |
:TIMER | :SUB_PROCESS`). **No new `DefinitionGraph`/`GraphNode`/`GraphEdge`/`NodeType`-equivalent
type is declared anywhere under `lib/letflow/engine/`** — `alias Letflow.Definitions.Graph` (and,
where a bare `Node.t()` reference is convenient, `alias Letflow.Definitions.Graph.Node`) is the
only cross-module reference this design needs for graph data. This satisfies the task's
acceptance criterion "the module reuses REQ-028's existing graph structs ... rather than defining
a second copy" by construction — there is no second copy to point at.

## 2. `Letflow.Engine.InstanceState` — struct and field types

```elixir
@type status :: :active | :completed | :cancelled | :error

@type t :: %__MODULE__{
        instance_id: String.t(),
        status: status(),
        tokens: [Letflow.Engine.Token.t()],
        variables: map(),
        pending_task_nodes: [Letflow.Engine.Token.t()]
      }
```

| Field | Type | Default | Notes |
|---|---|---|---|
| `instance_id` | `String.t()` | *(required)* | UUID string. No `Ecto.UUID`/DB-column typing here — this module has zero `Ecto` dependency (§8); REQ-043's future schema module is what actually persists this value as `binary_id`. |
| `status` | `status()` | `:active` | Engine.md EE-02 §1's `ACTIVE/COMPLETED/CANCELLED/ERROR` field, mapped to Elixir atoms `:active | :completed | :cancelled | :error`. **This exact 4-atom set is chosen to be source-compatible with `Letflow.EventStore.InstanceProjection`'s already-shipped `status` `Ecto.Enum`** — see §10's verbatim moduledoc note for the full resolved dependency-ordering rationale. |
| `tokens` | `[Letflow.Engine.Token.t()]` | `[]` | Every token currently live in this instance. Order is insertion/creation order — not itself semantically meaningful, but deterministic (§8). |
| `variables` | `map()` | `%{}` | The merged variable map. **Plain Elixir `map()`, not `std.json.ObjectMap`** — see §9's verbatim moduledoc note for the full allocator-ownership divergence. `transition/3` (REQ-044's own scope) never reads or writes `variables` — no non-gateway node type in this requirement's dispatch (§6) touches it. Carried on the struct now because engine.md's EE-02 §1 field list names it and later EE-\* requirements (EE-09 variable scoping, REQ-\* not yet built) need the field to already exist. |
| `pending_task_nodes` | `[Letflow.Engine.Token.t()]` | `[]` | The accumulator a token entering a `HUMAN_TASK` node is appended to (§6.3). **Holds `Token.t()` values, not bare node-id strings** — a design decision, not a literal requirement-text pin, explained in §6.3. |

No `@enforce_keys` beyond `instance_id` — an `InstanceState` with no tokens/no variables/no
pending tasks is a legal, constructible value (e.g. immediately after EE-01 start, before the
first `transition/3` call ever runs). `@enforce_keys [:instance_id]` — every `InstanceState` must
name which instance it describes; nothing else is required at construction time.

## 3. `Letflow.Engine.Token` — struct and field types

```elixir
@type t :: %__MODULE__{
        node_id: String.t(),
        branch_id: String.t() | nil,
        token_id: String.t(),
        waiting_child_instance_id: String.t() | nil
      }
```

| Field | Type | Default | Notes |
|---|---|---|---|
| `node_id` | `String.t()` | *(required)* | The graph node this token currently occupies — must resolve against `Letflow.Definitions.Graph.Node.id` in the `definition_snapshot` passed to `transition/3`, but this struct itself does not enforce that (§6.2 states which layer does). |
| `branch_id` | `String.t() \| nil` | `nil` | Parallel-branch identity, set at a `PARALLEL_GATEWAY` split (REQ-051, EE-06 — out of this requirement's scope; the field exists now so REQ-051's dispatch body has somewhere to write it). `nil` for a token that has never passed through a parallel split. |
| `token_id` | `String.t()` | *(required)* | Stable identity, per engine.md's own note that R-Co's ISS-105 added it. Used by `transition/3`'s dispatch (§5, §6) to locate the affected token inside `instance_state.tokens`, and by `pending_task_nodes` entries to tell REQ-047 which exact token a future `tasks` row's `token_id` column should reference. |
| `waiting_child_instance_id` | `String.t() \| nil` | `nil` | Set when this token has spawned a sub-process child instance and is waiting on it (SPC-01, REQ-062 — out of this requirement's scope; field exists now so REQ-062's dispatch body has somewhere to write it). `nil` for every token this requirement's own dispatch ever produces, since none of `:START`/`:END`/`:HUMAN_TASK` ever set it. |

`@enforce_keys [:node_id, :token_id]` — a `Token` with no position or no stable identity is a
construction-time error, matching `Letflow.Definitions.Graph.Node`'s own `@enforce_keys`
convention for its two truly load-bearing fields (§2.1 of the REQ-028 design doc).

## 4. `Letflow.Engine.Transition` — event, pending-event, and error types

```elixir
@type transition_event :: {:advance_token, token_id :: String.t()}

@type pending_event :: term()

@type transition_error ::
        {:unknown_event_type, event :: term()}
      | {:unknown_token_id, token_id :: String.t()}
      | {:unknown_node_id, node_id :: String.t()}
      | {:gateway_not_yet_implemented, node_type :: atom(), node_id :: String.t()}
      | {:node_type_not_yet_implemented, node_type :: atom(), node_id :: String.t()}
```

**`transition_event/0` — one constructor in this requirement's scope, deliberately not a closed
enumeration.** `{:advance_token, token_id}` is the only event this requirement's own dispatch
needs to demonstrate: "move the token identified by `token_id` one step according to whatever
node type it currently occupies, as recorded on `instance_state.tokens` and resolved against
`definition_snapshot`." Every later EE-\* requirement that needs its own distinct event shape
(EE-04's task-completion event with output variables, EE-08's cancellation event, a future
timer-fired event) adds its own tagged-tuple constructor to this same `@type` union — this is the
requirement's own "SKELETON... gateway bodies are separate requirements... plug into the dispatch
this requirement defines" framing applied to the *event* type, not only the node-type dispatch
(§12.4 flags this explicitly as an open extension point, not a silent design gap).

**Why the event does not itself carry a target `node_id` (an alternative considered and
rejected):** an event shaped `{:token_entered_node, token_id, node_id}` was considered, where the
caller states which node a token is entering and `transition/3` only reacts. Rejected because it
would force every caller (including EE-01's very first `:START` transition) to already know graph
topology (which edge to follow off `:START`) before calling the pure kernel at all — duplicating
knowledge `definition_snapshot` already carries. `{:advance_token, token_id}` keeps the kernel's
contract minimal: the event says *which* token changes, `definition_snapshot` supplies *all* the
topology needed to compute *what* changes, matching the signature's own framing ("all state is
passed in").

PROVENANCE (historical, not current decision authority):
**`pending_event/0` declared as `term()`, not a fabricated tagged-tuple union — stated as a
deliberate placeholder, not a "TBD":** the task names `PendingEvent` as "the tagged union
transition.zig declares for EE-06/EE-07 split/join payloads" — i.e. its real shape is defined by
`engine.md`'s EE-06/EE-07 sections, which this environment cannot read (§0's access gap).
Inventing sample constructors (`{:branch_spawned, ...}`, `{:join_awaiting, ...}`) not backed by
that source text would be exactly the kind of guessed content this project's design discipline
forbids (`core-directives.md`: "Don't silently resolve an open question by guessing"). **None of
this requirement's own dispatch cases (§6) ever construct a `pending_event()` value — every
non-gateway case this requirement implements returns `pending_events: []`.** REQ-050 and REQ-051
narrow `pending_event/0` to a real closed union when they add gateway split/join payloads; §12.3
flags this explicitly as the open item those two requirements' CODE-DESIGNER must resolve, not
silently inherited.

**`transition_error/0` — 5 tagged variants, 2 required by this requirement's acceptance criteria
(§7) plus 3 additional defensive/extension variants (§7, §12.5):**
`:unknown_event_type`/`:unknown_node_id` are AC3's two explicit error paths; `:unknown_token_id`
is this design's own defensive totality addition (§7.3); `:gateway_not_yet_implemented`/
`:node_type_not_yet_implemented` are the stub extension points §6.4/§6.5 use.

## 5. `transition/3` — public function signature

```elixir
@spec transition(
        definition_snapshot :: Letflow.Definitions.Graph.t(),
        instance_state :: Letflow.Engine.InstanceState.t(),
        event :: Letflow.Engine.Transition.transition_event()
      ) ::
        {:ok, Letflow.Engine.InstanceState.t(), [Letflow.Engine.Transition.pending_event()]}
        | {:error, Letflow.Engine.Transition.transition_error()}
```

Matches `backend_developer_guide.md` §3.5's ordinary `{:ok, result} | {:error, reason}` error-shape
convention — **not** `Letflow.Definitions.Graph.validate_graph/1`'s bare-map divergence.
`validate_graph/1` diverges because a structurally-invalid graph is a legitimate *output value*,
never a function *failure* (REQ-028 design doc §4). `transition/3` is the opposite case: an
unknown event type or a token on a missing node id are genuine failures of the caller's own
contract with this pure kernel (a malformed/stale event, a `definition_snapshot` that does not
match the instance's actual definition) — exactly the ordinary `{:error, reason}` case §3.5
describes, so the ordinary convention is followed, not the special-cased one.

**Single hop per call — stated explicitly, not left implicit.** One `transition/3` call processes
exactly one token through exactly one node-type dispatch (§6) and returns; it never recursively
cascades a token through a chain of nodes within one call. A `:START` node whose outgoing edge
leads directly into another pass-through node requires two separate `transition/3` calls (one per
hop), each driven by its own `{:advance_token, token_id}` event from the caller. This keeps the
5-way dispatch testable as 5 independent, isolated cases (AC4's own phrasing: "a token entering
[X] node... each of the five node-type cases has its own explicit test") without requiring a test
fixture to construct a multi-node chain graph just to observe one node type's behavior. Flagged as
this design's own scoping decision in §12.1, since `engine.md`'s real `transition()` could
plausibly cascade internally — not verifiable in this environment (§0).

## 6. The 5-way (+1 catch-all) node-type dispatch

**Composition, at the top of `transition/3`'s body (described, not implemented):**

1. Match `event`'s tag. Anything other than `:advance_token` → `{:error, {:unknown_event_type,
   event}}` (§7.1).
2. `{:advance_token, token_id}`: find the token whose `token_id` field equals `token_id` inside
   `instance_state.tokens`. Not found → `{:error, {:unknown_token_id, token_id}}` (§7.3).
3. Resolve that token's `node_id` against `definition_snapshot.nodes` (an
   `Enum.find(definition_snapshot.nodes, &(&1.id == token.node_id))`-shaped lookup). Not found →
   `{:error, {:unknown_node_id, token.node_id}}` (§7.2).
4. Dispatch on the resolved node's `node_type` field — the table below.

```elixir
@spec dispatch_node(
        Letflow.Definitions.Graph.t(),
        Letflow.Engine.InstanceState.t(),
        Letflow.Engine.Token.t(),
        Letflow.Definitions.Graph.Node.t()
      ) ::
        {:ok, Letflow.Engine.InstanceState.t(), [Letflow.Engine.Transition.pending_event()]}
        | {:error, Letflow.Engine.Transition.transition_error()}
```

| # | `node.node_type` | This requirement's behavior | New token position | `pending_task_nodes` | `status` after |
|---|---|---|---|---|---|
| 1 | `:START` | §6.1 — advance the token onto the target of its (first, declaration-order) outgoing edge | moves to the edge's `target` | unchanged | unchanged |
| 2 | `:END` | §6.2 — token terminates | token removed from `tokens` | unchanged | `:completed` iff `tokens` is now `[]`, else unchanged |
| 3 | `:HUMAN_TASK` | §6.3 — token waits, signal recorded | **unchanged** (stays at the `HUMAN_TASK` node) | this token appended | unchanged |
| 4 | `:EXCLUSIVE_GATEWAY` | §6.4 — stub, out of scope (REQ-050) | n/a — returns `{:error, _}` | n/a | n/a |
| 5 | `:PARALLEL_GATEWAY` | §6.5 — stub, out of scope (REQ-051) | n/a — returns `{:error, _}` | n/a | n/a |
| — | any other `node_type()` value (`:SERVICE_TASK`, `:TIMER`, `:SUB_PROCESS`, or any bogus atom) | §6.6 — catch-all stub | n/a — returns `{:error, _}` | n/a | n/a |

Every clause's own signature is a specialization of `dispatch_node/4`'s `@spec` above — no
per-clause `@spec` is separately declared, matching `graph.ex`'s convention of one `@spec` per
function name even where the implementation has multiple pattern-matched clauses.

### 6.1 `:START` — advance the token

The `:START` node's outgoing edge is resolved as: `Enum.find(definition_snapshot.edges, &(&1.source
== node.id))` — the first edge in `definition_snapshot.edges`' own declaration order whose
`source` equals this `:START` node's `id`. The affected token's `node_id` is updated to that
edge's `target`; every other field on the token (`token_id`, `branch_id`,
`waiting_child_instance_id`) is unchanged. `instance_state.tokens` is updated in place (the one
matching `token_id` replaced, order otherwise preserved). Returns `{:ok, new_instance_state, []}`.

PROVENANCE (historical, not current decision authority):
**Multiple-outgoing-edges assumption, flagged (§12.1):** `Letflow.Definitions.Graph`'s CHK-04
(REQ-028) only requires a `:START` node to have **at least** one outgoing edge, not exactly one —
a structurally-legal graph could give `:START` two or more. This design picks the first in
declaration order, deterministically (§8), rather than raising or erroring on more than one. This
is a reasoned default matching typical BPMN `:START` semantics (unconditional, single successor
by convention), not a verified port of `transition.zig`'s literal behavior — flagged explicitly in
§12.1 since the access gap (§0) prevents confirming it.

### 6.2 `:END` — move the instance toward `COMPLETED`

The affected token is removed from `instance_state.tokens` (it has reached its terminus). If the
resulting `tokens` list is `[]` (no other token is still in flight — relevant once REQ-051's
`PARALLEL_GATEWAY` split can produce more than one live token), `instance_state.status` becomes
`:completed`. If `tokens` is **not** empty after removal, `status` is left unchanged (still
`:active`) — other branches are still executing. Returns `{:ok, new_instance_state, []}`.

PROVENANCE (historical, not current decision authority):
**Multi-token completion rule, flagged (§12.2):** this is this design's own reconstruction of
"moves the instance toward COMPLETED" (deliberately not "sets status to COMPLETED
unconditionally") — the phrasing implies a token reaching `:END` is necessary but not always
sufficient for instance completion, which only makes sense once more than one token can be live at
once (REQ-051's future `PARALLEL_GATEWAY` split). REQ-044's own scope never produces more than one
token (`:START`'s advance and `:HUMAN_TASK`'s wait both preserve exactly the token count they
started with), so this rule is exercised in REQ-044's own tests only via the trivial one-token
case (single token reaches `:END` → `tokens == []` → `:completed`), and its true multi-token
behavior is only verified once REQ-051 exists. Not verified against `transition.zig`'s literal
source (§0) — flagged for REVIEWER/RELEASE-VALIDATOR to re-check once source access is available.

### 6.3 `:HUMAN_TASK` — signal `pending_task_nodes`, token stays put

The affected token's position is **not** changed (a `HUMAN_TASK` node has no automatic outgoing
traversal — a human must act, via a future event this requirement does not implement). The
**same** `Token.t()` value (not a copy with different fields) is appended to
`instance_state.pending_task_nodes`. `instance_state.tokens` is unchanged (the token was already
present there at this `node_id` before this call — this requirement's dispatch does not verify or
enforce "this is the first time this token entered this exact node," see §12.3). Returns
`{:ok, new_instance_state, []}`.

**Why `pending_task_nodes` holds `Token.t()` values, not bare node-id strings — a design decision,
stated explicitly:** the requirement's own text names the field "`pending_task_nodes`" (nodes,
plural) but also says the entries are "the signal REQ-047 turns into a `tasks` row." REQ-043's
future `tasks` table schema (read via the targeted `docs/requirements.yaml` lookup, §0) requires
`token_id` as a not-null column — REQ-047 cannot build a `tasks` row from a bare node-id string
alone if more than one token could ever occupy the same `HUMAN_TASK` node concurrently (a
structurally legal graph shape once parallel branches exist). Carrying the full `Token.t()` (which
already has `node_id` embedded) costs nothing extra and removes the ambiguity — this is this
design's own resolution of an unstated field-content question, not a literal quote from
`engine.md`, flagged again in §12.3 for REQ-047's CODE-DESIGNER to confirm or override.

**"The signal itself is the guard" (engine.md EE-03, quoted in the requirement text) — what this
means concretely:** only this one dispatch clause (`:HUMAN_TASK`) ever appends to
`pending_task_nodes`. `:START`, `:END`, `:EXCLUSIVE_GATEWAY`, and `:PARALLEL_GATEWAY` never do
(the table above states this per-case). Consequently, REQ-047's future persistence code can create
a `tasks` row for every entry present in `pending_task_nodes` **without** separately re-checking
`node.node_type == :HUMAN_TASK` — the entry's mere presence already proves that. AC4's "tokens
entering START, END, EXCLUSIVE_GATEWAY and PARALLEL_GATEWAY nodes do not [add to
`pending_task_nodes`]" is exactly this property, restated as a test requirement.

### 6.4 `:EXCLUSIVE_GATEWAY` — stub, extension point for REQ-050

```elixir
@spec dispatch_exclusive_gateway(
        Letflow.Definitions.Graph.t(),
        Letflow.Engine.InstanceState.t(),
        Letflow.Engine.Token.t(),
        Letflow.Definitions.Graph.Node.t()
      ) :: {:error, {:gateway_not_yet_implemented, :EXCLUSIVE_GATEWAY, node_id :: String.t()}}
```

A **named private function**, not an inline case-branch literal, so REQ-050's ELIXIR-DEV replaces
this one function's body with the real CEL-condition-evaluation dispatch (`stage-3-instance-engine
.md`'s "Gateway condition evaluation is not an open question" note — `evaluateGatewayCondition()`,
`src/expr/` — REQ-050's own scope, not re-litigated here) without touching `dispatch_node/4`'s
outer `case`/pattern-match structure at all. Currently always returns
`{:error, {:gateway_not_yet_implemented, :EXCLUSIVE_GATEWAY, node.id}}` — a clearly-named,
never-silent stub result (never `{:ok, ...}`, so no caller could mistake "not yet implemented" for
"legitimately produced no side effect").

### 6.5 `:PARALLEL_GATEWAY` — stub, extension point for REQ-051

```elixir
@spec dispatch_parallel_gateway(
        Letflow.Definitions.Graph.t(),
        Letflow.Engine.InstanceState.t(),
        Letflow.Engine.Token.t(),
        Letflow.Definitions.Graph.Node.t()
      ) :: {:error, {:gateway_not_yet_implemented, :PARALLEL_GATEWAY, node_id :: String.t()}}
```

Same shape and rationale as §6.4, for REQ-051 (EE-06 split + EE-07 join) to replace instead.
`stage-3-instance-engine.md` notes REQ-051 deliberately keeps split+join in one requirement (they
share the `Token`/`JoinCounter` model) — this single stub function is the one extension point both
halves plug into.

### 6.6 Catch-all — every other `node_type()` value

```elixir
@spec dispatch_node(Letflow.Definitions.Graph.t(), Letflow.Engine.InstanceState.t(),
        Letflow.Engine.Token.t(), Letflow.Definitions.Graph.Node.t()) ::
        {:error, {:node_type_not_yet_implemented, node_type :: atom(), node_id :: String.t()}}
```

Handles `:SERVICE_TASK`, `:TIMER`, `:SUB_PROCESS` (the 3 remaining variants of
`Letflow.Definitions.Graph.node_type()`'s existing 8-variant union that are not part of this
requirement's "5-way dispatch") **and** any node whose `node_type` is not one of the 8 known atoms
at all (the same open gap `graph.ex`'s own design doc §9.2 already flagged and left unresolved).
**Added by this design, not explicitly requested by the task's literal "5-way dispatch" framing —
necessary for `transition/3` to be total (AC3's "never raises" bar) over every value
`Node.t().node_type` can actually hold**, since a partial `case`/pattern match with no catch-all
clause would raise `CaseClauseError`/`FunctionClauseError` on any of these 4 remaining
possibilities, violating the purity contract's "never raise" requirement just as surely as an
unhandled unknown event type would. Flagged again in §12.5 as this design's own totality-completing
addition. `:SERVICE_TASK` (REQ-056), `:TIMER` (a future scheduler-integrated requirement), and
`:SUB_PROCESS` (REQ-062) each get their own real dispatch clause once their owning requirement
lands — this catch-all is deliberately generic (one function, one error shape, `node_type` named
in the returned tuple) rather than three separate near-duplicate stub functions, since none of
these three has a requirement in flight yet the way REQ-050/051 do for the two gateways.

## 7. Error paths — full detail

### 7.1 Unknown event type (AC3, first half)

Any `event` value whose first tuple element is not `:advance_token` — e.g. a bogus atom tag, a
tuple of the wrong arity, a value that isn't a tuple at all — falls through every pattern-matched
clause in `transition/3`'s own top-level dispatch and hits a final catch-all clause returning
`{:error, {:unknown_event_type, event}}`. **Never raises** (no `FunctionClauseError`/`CaseClauseError`
propagates to the caller) — the catch-all clause's pattern is a bare variable
(`event -> {:error, {:unknown_event_type, event}}`), matching any term. Demonstrated by an explicit
test (AC3) passing e.g. `{:bogus_event, "x"}` or a non-tuple value and asserting the exact
`{:error, {:unknown_event_type, _}}` shape, never a crash.

### 7.2 Token on a `node_id` absent from the snapshot graph (AC3, second half)

Once a `token_id` resolves to a real `Token.t()` inside `instance_state.tokens` (§7.3 covers the
case where it doesn't), that token's `node_id` is looked up against
`definition_snapshot.nodes`. If no node in the snapshot has a matching `id`, `transition/3` returns
`{:error, {:unknown_node_id, token.node_id}}` — **naming the offending `node_id`** in the error
tuple's own payload, satisfying AC3's "returns an error result naming the offending
inconsistency" literally (the exact string, not just a generic "node not found" atom). Never
raises — no `Enum.find!`/bang-function/pattern-match-that-can-fail is used for this lookup; the
non-bang `Enum.find/2` (or equivalent) returning `nil` on no match is what routes into this
error branch instead of crashing.

### 7.3 Unknown `token_id` — additional defensive path, not required by an explicit AC

If `event`'s `token_id` does not match any `Token.t()` in `instance_state.tokens`, `transition/3`
returns `{:error, {:unknown_token_id, token_id}}`. **Stated explicitly as going beyond what AC3
literally asks for** (AC3 only names "unknown event type" and "token on a missing node_id" as its
two required cases) — added here because a total, never-raising pure function must handle this
input shape too (a caller passing a stale/nonexistent `token_id` is exactly as plausible as a
stale/nonexistent `node_id`), and leaving it undefined would either force an unhandled-match crash
or silently mis-specify `transition/3`'s domain. TEST-DESIGNER should still write a test for this
case even though it is not literally named by an acceptance criterion, per the general "never
raise" bar AC1/AC3 jointly establish — flagged here rather than silently added with no
documentation trail.

## 8. Determinism (AC2) and purity (AC1)

**Determinism, precisely:** calling `transition(definition_snapshot, instance_state, event)` twice
with `==`-equal (structurally identical) arguments returns `==`-equal results, both times — same
`{:ok, new_instance_state, pending_events}` tuple content or the same `{:error, reason}` tuple
content. ("`==`-equal", not "byte-identical" in the literal binary-representation sense: Elixir/
Erlang terms are compared for structural equality by `==`/`===`, not by memory layout — a map with
the same key-value pairs is `==`-equal to another regardless of internal hashing/bucket order,
which is exactly the guarantee this module needs and Erlang's term-equality semantics already
provide.) This holds because every decision inside the dispatch (§6) is a pure function of its
typed input alone:
- Token/node lookups (§6, §7.2/§7.3) use ordinary linear scans (`Enum.find/2`-shaped) over
  argument-supplied lists — no external state, no randomness, no `:ets`/process-mailbox read.
- `:START`'s "first outgoing edge in declaration order" (§6.1) is a deterministic function of
  `definition_snapshot.edges`'s own list order, which is itself part of the argument, not derived
  from anything external.
- No clock read (`DateTime.utc_now/0`, `System.os_time/1`, `System.system_time/1`, or equivalent)
  appears anywhere in `transition/3`'s call graph — no dispatch case (§6) needs "when" something
  happened, only "what."
- No `:rand`/`:crypto` call, no UUID generation inside `transition/3` itself (token/instance ids
  are always supplied by the caller via `event`/`instance_state`, never minted inside this
  module).

**Purity, precisely (AC1) — stated in the moduledoc, verification method matching `graph.ex`'s own
(REQ-028 design doc §8):** `Letflow.Engine.Transition`, `Letflow.Engine.InstanceState`, and
`Letflow.Engine.Token` depend on Elixir/Erlang stdlib only (`Enum`, `Map`, `Kernel`). No
`alias Letflow.Repo`, no `import Ecto.Query`, no `Ecto.Changeset` anywhere in any of the 3 files.
No `Logger.*` call. No clock read (see above). No `File.*`/`HTTPoison`/`Req.*`/`:httpc`/
process-mailbox call (`GenServer.call`, `send`, `receive`) anywhere in `transition/3`'s call graph,
including every private `dispatch_*` function it calls into.

**Verification method (grep/`mix xref`-checkable, matching the established precedent literally):**

```bash
grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\|Req\.\|File\.\|:rand\.\|:crypto\." lib/letflow/engine/instance_state.ex lib/letflow/engine/token.ex lib/letflow/engine/transition.ex
```

must return zero matches. `mix xref graph Letflow.Engine.Transition` (or an equivalent `mix xref`
call-graph query) should confirm `Letflow.Repo` never appears as a callee, direct or transitive —
satisfying AC1's "confirmed by inspection and stated in the moduledoc" literally.

## 9. Verbatim moduledoc text — Zig `ObjectMap` allocator-ownership divergence

**ELIXIR-DEV copies the following paragraph verbatim into `Letflow.Engine.InstanceState`'s
`@moduledoc`** (or `Letflow.Engine.Transition`'s, wherever `variables`'s typing is documented —
ELIXIR-DEV's placement choice, content is fixed):

```
## Variable storage: no ObjectMap allocator-ownership equivalent (REQ-044)

PROVENANCE (historical, not current decision authority):
`transition.zig`'s `InstanceState.variables` is a `std.json.ObjectMap`, a
mutable hash map whose entries are heap-allocated through an explicit
`std.mem.Allocator` the caller owns and must free — Zig's manual-memory
model requires every map read/write site to reason about who allocated a
given entry and who is responsible for freeing it. This module represents
`variables` as a plain Elixir `map()` instead. Elixir has no allocator to
own: a map value is immutable, garbage-collected, and copied-on-write by
ordinary language semantics, so there is no allocation-ownership discipline
to port and none is invented here — the same divergence REQ-029's design
(`lib/letflow/design/req029-node-attribute-edge-condition-validators.md`
§8) already noted for `GraphError.OutOfMemory`: Zig's allocator-failure
error case has no Elixir equivalent, and this module does not fabricate one.
```

This directly satisfies AC5 ("the moduledoc states explicitly that Zig's `std.json.ObjectMap`
allocator-ownership contract is deliberately not ported... rather than leaving the divergence
unremarked").

## 10. Verbatim moduledoc text — REQ-043 dependency-ordering note

**ELIXIR-DEV copies the following paragraph verbatim into `Letflow.Engine.InstanceState`'s
`@moduledoc`** (co-located with §9's paragraph, or immediately below the `status` field's own
`@type`/doc — ELIXIR-DEV's placement choice, content is fixed):

```
## Dependency ordering: this module does not depend on REQ-043

`InstanceState.status`'s four values (`:active`, `:completed`, `:cancelled`,
`:error`) are chosen to be source-compatible with the `status` `Ecto.Enum`
`Letflow.EventStore.InstanceProjection` (REQ-023, already shipped) already
declares — `values: [active: "ACTIVE", completed: "COMPLETED", cancelled:
"CANCELLED", error: "ERROR"]` — and with what REQ-043's own future ALTER-
TABLE migration and any instance-engine schema modules will reuse. This
module depends on REQ-028 (`Letflow.Definitions.Graph`) and REQ-029, both
`status: done`. It does **not** depend on REQ-043 (`instance_projections`
ALTER, `tasks`, `tokens` tables — `status: pending` at the time this design
was written) or on any not-yet-existing `Ecto.Schema` module REQ-043 will
add. This module is pure (see the purity section above) — it performs zero
`Letflow.Repo` calls and holds no reference, direct or aliased, to any
REQ-043 schema module. `status` is declared here as a plain atom type
(`:active | :completed | :cancelled | :error`), not as `Ecto.Enum` and not
as a call into a REQ-043-owned module that does not yet exist.
```

This is the "resolved dependency-ordering note, not silently [resolved]" the handoff's
IMPORTANT NOTE FROM ORCH asks for — stated as its own explicit design element (this section) and
as its own explicit moduledoc paragraph, not merely implied by the field's `@type`.

## 11. Cross-module dependencies

- **`Letflow.Definitions.Graph`, `Letflow.Definitions.Graph.Node`** (REQ-028, `status: done`) —
  `transition/3`'s first parameter type and every node-type lookup inside the dispatch (§6). No
  other function from that module is called (`validate_graph/1`,
  `validate_node_attributes/1`, `validate_edge_conditions/1`, `valid_cel_syntax?/1` are all
  irrelevant to a pure transition kernel operating on an already-valid, already-persisted
  definition snapshot — validity is REQ-030's `create/1` pipeline's job, upstream of this module
  entirely).
- **None on REQ-043** — stated explicitly in §10's verbatim moduledoc text, not merely by omission.
- **None on `Letflow.Repo` or any `Ecto.Schema` module anywhere** — §8's purity contract.
- **Forward dependents (not yet built):** REQ-050 (`:EXCLUSIVE_GATEWAY`, §6.4's stub), REQ-051
  (`:PARALLEL_GATEWAY`, §6.5's stub), REQ-056 (`:SERVICE_TASK`, §6.6's catch-all), REQ-062
  (`:SUB_PROCESS`, §6.6's catch-all), REQ-047 (task activation — consumes `pending_task_nodes`,
  §6.3), REQ-045 (instance runtime — constructs the very first `InstanceState`/`Token` before any
  `transition/3` call, §12.4), REQ-053 (reconstruction — folds `transition/3` over the event log),
  REQ-054 (snapshotting — persists `InstanceState` values this module produces).

## 12. Open questions — not resolved here

### 12.1 `:START` with more than one outgoing edge — reasoned default, not verified against source

PROVENANCE (historical, not current decision authority):
§6.1's "first edge in declaration order" is this design's own tie-break for a structurally-legal
(per REQ-028's CHK-04) but semantically unusual graph. Not verified against `transition.zig`'s
literal source (§0's access gap). If R-Co source becomes reachable, ELIXIR-DEV should diff this
choice against the real behavior and flag any divergence to REVIEWER rather than silently keeping
the reconstruction if it disagrees.

### 12.2 `:END`'s multi-token completion rule — reconstructed from wording, not verified

§6.2's "`:completed` iff `tokens` is now empty, else unchanged" is this design's own reconstruction
of "moves the instance toward COMPLETED." REQ-044's own scope never exercises the genuinely
multi-token case (no dispatch clause in this requirement can produce more than one live token) —
real verification only becomes possible once REQ-051 (`PARALLEL_GATEWAY` split) exists. Flagged
for REVIEWER/RELEASE-VALIDATOR re-check once source access is available, matching REQ-029 design
doc §9.1's precedent for a similarly-reconstructed, similarly-flagged algorithm.

### 12.3 `pending_task_nodes` clearing/consumption, and re-entry dedup — REQ-047's call

This design does not specify: (a) whether/when an entry is removed from `pending_task_nodes` once
REQ-047 has materialized its `tasks` row (a later `transition/3` event removing it explicitly, or
a mutation REQ-047 performs directly outside `transition/3`), or (b) whether calling `transition/3`
with `{:advance_token, token_id}` against a token that is *already* present in
`pending_task_nodes` should dedup (skip re-appending) or is simply assumed never to happen (the
event represents a fresh arrival, per §6's composition). Both are left open for REQ-047's
CODE-DESIGNER to resolve explicitly, not silently inherited as "whatever the code happens to do."

### 12.4 Initial `InstanceState`/`Token` construction (EE-01) — REQ-045's scope, not REQ-044's

This requirement never constructs an `InstanceState` or `Token` value from scratch — `transition/3`
only ever receives one as an argument. How the very first token (positioned at the graph's
`:START` node) and the very first `InstanceState` come into existence before the first
`transition/3` call is EE-01's job (`stage-3-instance-engine.md` names REQ-045 as the instance
runtime requirement). Flagged here so REQ-045's CODE-DESIGNER does not have to rediscover that
`Letflow.Engine.InstanceState`/`Letflow.Engine.Token` already exist and should be reused, not
redefined.

### 12.5 `transition_event/0` and `pending_event/0` are open extension points, not closed unions

§4 states this inline; repeated here as a standing open item. Every future EE-\* requirement
(REQ-047 EE-04, REQ-050 EE-05, REQ-051 EE-06/07, REQ-052 EE-08) that needs a new event shape adds
its own constructor to `transition_event/0`; REQ-050/051 narrow `pending_event/0` from `term()` to
a real closed union. This module's own design does not attempt to anticipate those shapes.

## 13. Acceptance-criteria traceability

| REQ-044 task acceptance criterion | Concrete design element |
|---|---|
| "`transition/3`'s function signature and its entire call graph contain zero Repo calls, zero HTTP/file access, and zero `DateTime.utc_now`/`System.system_time` reads, confirmed by inspection and stated in the moduledoc" | §8 (full purity contract, stdlib-only dependency list, grep/`mix xref` verification method) |
| "calling `transition/3` twice with the identical (snapshot, state, event) triple returns byte-identical results, demonstrated by an explicit test rather than asserted" | §8's determinism paragraph (every dispatch decision proven to be a pure function of argument-supplied data only, no clock/randomness/external state) |
| "an unknown/unrecognised event type returns an error result... a state whose token sits on a node_id absent from the snapshot graph returns an error result naming the offending node_id — neither raises or crashes" | §7.1 (unknown event type) + §7.2 (unknown node_id, names the offending id) — both explicitly non-raising, non-bang lookups |
| "a token entering a HUMAN_TASK node adds that node to `pending_task_nodes`, while tokens entering START, END, EXCLUSIVE_GATEWAY and PARALLEL_GATEWAY nodes do not — each of the five node-type cases has its own explicit test" | §6's dispatch table (all 5 cases' effect on `pending_task_nodes` stated per row) + §6.1–§6.5 (each case's full behavior) |
| "the moduledoc states explicitly that Zig's `std.json.ObjectMap` allocator-ownership contract is deliberately not ported..., rather than leaving the divergence unremarked" | §9 (verbatim moduledoc text, ready to copy in) |
| "the module reuses REQ-028's existing graph structs from `lib/letflow/definitions/graph.ex` rather than defining a second copy of DefinitionGraph/GraphNode/GraphEdge/NodeType" | §1 (explicit reuse statement, no new type declared) + §5/§6 (`definition_snapshot` typed exactly `Letflow.Definitions.Graph.t()`, node lookups against `Letflow.Definitions.Graph.Node.t()`) |

**Also addressed, per the handoff's own "Key things... you must address explicitly" list beyond
the formal AC table above:**

| Handoff item | Concrete design element |
|---|---|
| "Read `lib/letflow/definitions/graph.ex` first — reuse its structs, do not redefine them" | §1, §5, §6 |
| "REQ-044's own `depends_on` is `[REQ-028, REQ-029]`, NOT REQ-043 — resolve as its own subsection" | §10 (dedicated section + verbatim moduledoc text) |
| "Include the verbatim moduledoc text for the Zig ObjectMap allocator-ownership divergence note" | §9 |
| "Design the 5-way node-type dispatch... gateway bodies out of scope, clear extension point" | §6 (table) + §6.4/§6.5 (named stub functions, not inline literals) |
| "Design the two error paths explicitly" | §7.1, §7.2 |
