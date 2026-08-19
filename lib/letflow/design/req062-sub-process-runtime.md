# REQ-062 — SPC-01 sub-process runtime half (design)

Ports the runtime half of `src/definition/sub_process_interface.zig` /
`src/engine/instance.zig`'s SUB_PROCESS handling that REQ-032 explicitly
deferred to S3: `createWithParentInheritance()` (internal-only child
creation), the `sub_process_start` pending event, the parent-token wait
(`waiting_child_instance_id`), input-filter-on-activation, output-merge-on-
completion, and the four SPC-01 failure modes routed through REQ-061's
`Letflow.Engine.ExecutionError` path.

**No R-Co source tree is reachable in this environment.** Every citation to
`instance.zig`/`transition.zig` line numbers below is taken verbatim from
this run's own handoff text (which the requirement author verified directly
against those files); this design reasons from that text plus the already-
shipped Letflow code, not from a second independent read of R-Co.

## 0. Scope boundary (stated up front, restated in the eventual moduledoc)

* **No HTTP surface.** Sub-processes are started by the engine's own
  dispatch of a `:SUB_PROCESS` node, never by a route. There is no
  `POST /api/v1/.../sub-process` endpoint deferred to S4 — none is planned,
  ever, because none exists in R-Co's own SPC-01 either. A later reader
  finding no such route in S4 is not a gap.
* **`createWithParentInheritance()`'s shape is internal-only**, exactly as
  its own R-Co comment states ("called only from
  `startSubProcessesForPendingEventsInTx()` — never exposed on the public
  API surface"). This design adds no second entry point beside
  `Letflow.Engine.create/2` (REQ-045) — AC6.
* **EE-08 (parent cancel doesn't cascade to child) needs no new code.**
  `Letflow.Engine.cancel_instance/3`'s existing `tasks`/`tokens` queries are
  already filtered `where t.instance_id == ^instance_id` (the *caller's own*
  instance id) — a child instance has its own, different `instance_id`, so
  it is structurally unreachable from a parent's `cancel_instance/3` call
  without this requirement changing a single line there. §7 states this
  explicitly so REVIEWER can confirm "no change" is the correct diff, and
  TEST-DESIGNER still owes AC7 an explicit test (a scope guarantee is not
  self-evidently true without one).
* **REQ-059 (PIN-04 AC2/AC3, pin inheritance) is NOT this requirement's
  job.** This design's child-creation path is the seam REQ-059 hangs off —
  see §8 — but this design does not compute, merge, or record a pin set.

## 1. New/changed pure data shapes

### 1.1 `Letflow.Engine.Token` — unchanged

Already carries `waiting_child_instance_id: String.t() | nil` (REQ-044).
No field addition. **Invariant (GH-428 regression guard, AC5):** every
dispatch clause that repositions an *existing* token (as opposed to minting
a brand-new `token_id` at a split/join) must use struct-update syntax
(`%Token{token | node_id: ...}`), never a fresh `%Token{...}` literal that
omits `waiting_child_instance_id` — Elixir's struct-update copies every
field not explicitly overridden, so this is a static, mechanically-checkable
discipline, not a runtime bug class the way R-Co's manual Zig struct copy
was. `advance_token/3`, `dispatch_start/4`, and the new
`dispatch_sub_process_completion/4` (§2.3) MUST all follow this; a fresh
`%Token{token_id: ..., node_id: ...}` literal anywhere in this call graph
that drops `waiting_child_instance_id` is the exact defect this AC's
regression test exists to catch.

### 1.2 `Letflow.Engine.InstanceState` — unchanged

No new field. `pending_task_nodes` is HUMAN_TASK-only, by design (REQ-047's
"the signal itself is the guard," INV-EE47-1) — SUB_PROCESS activation does
**not** reuse or extend it. Instead, the signal for "this hop created (or
needs) a sub-process child" is carried entirely through the returned
`pending_event()` list (§2.2) — mirroring `:PARALLEL_GATEWAY`'s own
`{:parallel_split, ...}`/`{:parallel_join_fired, ...}` precedent rather than
`:HUMAN_TASK`'s state-diff precedent, because unlike a task row (which is
always insertable once the diff is known), a sub-process child's creation
can itself fail two distinct, typed ways (§4) that must short-circuit
*before* any DB write — a diff-based signal has no natural place to carry
that pre-computed failure back to the caller, a `pending_event` does.

### 1.3 `Letflow.Definitions.SubProcessInterface` — reused unchanged

`parse_interface/2` and `validate_schema_shape/2` (already shipped, REQ-032)
are called as-is. This design adds no second parser. Value-against-schema
validation (distinct from schema-*shape* validation) reuses
`Letflow.EventStore.Registry.JsonSchema.validate/2` (already shipped,
REQ-024) — also unmodified.

## 2. `Letflow.Engine.Transition` changes

### 2.1 `transition_event()` — one new variant

```
@type transition_event ::
        {:advance_token, token_id :: String.t()}
        | {:cancel_branch, branch_id :: String.t()}
        | {:complete_task, token_id :: String.t()}
        | {:sub_process_completed, token_id :: String.t(), output_variables :: map()}
```

`{:sub_process_completed, token_id, output_variables}` is the caller's
explicit "this token's child instance finished, and here is its
already-filtered (interface.outputs-only, or full-map under EXT-05) output
map" signal — parallel to `{:complete_task, token_id}`'s own "this token's
human task finished" signal. `output_variables` arrives pre-filtered:
`Letflow.Engine.Transition` never reads `interface.outputs` or calls
`SubProcessInterface`/`JsonSchema` itself (purity contract, §"Purity" in
the existing moduledoc) — filtering and the two output failure modes (§4)
are entirely an `Letflow.Engine`-layer concern, exactly as
`merge_output_variables/5` already keeps schema rejection out of
`Transition` for `complete_task/3`.

### 2.2 `pending_event()` — one new variant

```
@type pending_event ::
        {:parallel_split, ...}
        | {:parallel_join_fired, ...}
        | {:parallel_join_cancelled, ...}
        | {:sub_process_start, token_id :: String.t(), node_id :: String.t()}
```

Emitted by the new SUB_PROCESS dispatch clause (§2.3) the first time a token
lands on a `:SUB_PROCESS` node with no child yet running. **This is the one
`pending_event()` variant this requirement's own Engine-layer code actually
consumes** — `{:parallel_split, ...}`/`{:parallel_join_fired, ...}`/
`{:parallel_join_cancelled, ...}` remain informationally discarded exactly
as today (`Letflow.Engine`'s two existing `{:ok, _, _pending_events}`
match sites, REQ-051); fixing that pre-existing gap is explicitly **not**
in this requirement's scope and this design does not touch it.

### 2.3 New `dispatch_node/4` clause: `:SUB_PROCESS`

Replaces `:SUB_PROCESS` as one of the 3 catch-all-covered types (the
catch-all at the existing `defp dispatch_node(_, _, _, %Node{node_type:
node_type, id: node_id})` clause) with its own clause, inserted before that
catch-all — `:SERVICE_TASK`/`:TIMER` remain caught by the (now 2-type,
comment updated) catch-all.

```
@spec dispatch_sub_process_entry(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
        {:ok, InstanceState.t(), [pending_event()]}
```

Behavior (ports `processNodeEntry`'s SUB_PROCESS branch, per the handoff's
own citation):

* `token.waiting_child_instance_id != nil` → **early return**: `{:ok,
  instance_state, []}` unchanged, no pending event. Guards a caller
  re-dispatching a token that already has a child running (defensive —
  `tokens_needing_dispatch/3` should never re-select this token_id anyway
  since its `node_id` never changes, but this clause does not rely on that
  caller discipline).
* `token.waiting_child_instance_id == nil` → token position is **not**
  changed (same "stays at its own node" contract as `:HUMAN_TASK`) — no
  `advance_token`/`replace_token` call, `instance_state` returned as-is —
  plus `{:ok, instance_state, [{:sub_process_start, token.token_id,
  node.id}]}`.

This clause performs **zero I/O and zero child creation** — it is exactly
as pure as every other `dispatch_*` clause. Child creation is a DB write,
which `Letflow.Engine.Transition` may never perform (moduledoc's "Purity"
section, unmodified, still enforced by the existing grep check). All actual
child-instance work happens at the `Letflow.Engine` layer (§3), triggered by
this pending event.

### 2.4 New `transition/3` dispatch case: `{:sub_process_completed, token_id, output_variables}`

Added as a fourth `case event do` clause, structurally identical to
`{:complete_task, token_id}`'s existing clause (find token → find node →
dispatch), calling a new private function:

```
@spec dispatch_sub_process_completion(Graph.t(), InstanceState.t(), Token.t(), Node.t(), map()) ::
        {:ok, InstanceState.t(), [pending_event()]}
        | {:error, {:token_not_waiting_on_child, node_type :: atom(), node_id :: String.t()}}
        | {:error, {:no_matching_edge, node_id :: String.t(), evaluated_conditions :: [evaluated_condition()]}}
```

Behavior:

* Defensive guard (mirrors `dispatch_task_completion/4`'s own defensive
  clause): `token.waiting_child_instance_id == nil` or `node.node_type !=
  :SUB_PROCESS` → `{:error, {:token_not_waiting_on_child, node.node_type,
  node.id}}`. Should be unreachable given `Letflow.Engine`'s own lookup
  invariant (§3.4), kept for this codebase's "never raise" totality
  discipline, same framing as the existing defensive clause it mirrors.
* Otherwise: (a) merges `output_variables` into `instance_state.variables`
  — **not** via a second call into `VariableMerge.merge/3` inside this
  module (that would break the purity/no-Repo-dependency-adjacent
  convention of keeping merge-then-dispatch two separate steps the way
  `complete_task/3` already does at the `Letflow.Engine` layer); instead
  the *caller* (`Letflow.Engine`, §3.4) has already run
  `VariableMerge.merge/3` before constructing this event, and passes the
  **already-merged** `InstanceState.variables` in via a parameter — see the
  corrected signature note below. (b) clears the token's wait:
  `new_token = %Token{token | waiting_child_instance_id: nil}` (struct
  update, §1.1's invariant). (c) evaluates the node's own outgoing edges
  using the **exact same** edge-partition algorithm
  `dispatch_task_completion/4` already uses (`really_conditioned?/1`,
  default-candidate fallback) — a completed SUB_PROCESS node has no
  automatic single outgoing edge any more than a completed HUMAN_TASK does,
  so it reuses that logic verbatim via a shared private helper extracted
  from `dispatch_task_completion/4` (`advance_off_completed_node/4`, taking
  `(definition_snapshot, instance_state, token_with_cleared_wait,
  outgoing_edges)`), rather than a second copy of the partition rule.

**Correction to the type above** (flagged so ELIXIR-DEV does not
implement the misleading literal signature): `output_variables` is not
threaded through `transition/3` — since `dispatch_sub_process_completion/5`
needs to *both* merge and advance, and this codebase's established
convention (`complete_task/3`) keeps merge outside `Transition` entirely,
the actual event constructor is:

```
{:sub_process_completed, token_id :: String.t()}
```

and `Letflow.Engine` (§3.4) merges the filtered child output into
`instance_state.variables` **before** calling `Transition.transition/3`,
exactly mirroring `complete_task/3`'s own `merge_output_variables/5` →
`Transition.transition(graph, state_with_merged_variables, {:complete_task,
token_id})` sequencing. `dispatch_sub_process_completion/4`'s only job is
then: clear the wait, evaluate outgoing edges, advance. This keeps
`Transition` a single, uniform "state already reflects the merge, event
just says which token moves" contract for both `:complete_task` and
`:sub_process_completed` — no special-cased merge parameter. §2.2's
`pending_event()` and §2.4's earlier draft signature above are corrected to
match: **`transition_event()`'s new variant is `{:sub_process_completed,
token_id :: String.t()}`**, no `output_variables` argument.

## 3. `Letflow.Engine` changes

### 3.1 `advance_until_stable/4` — return type widened

```
@spec advance_until_stable(Graph.t(), InstanceState.t(), [String.t()], integer()) ::
        {:ok, InstanceState.t(), [Transition.pending_event()]}
        | {:error, {:activation_failed, term()}}
```

Currently discards `_pending_events` per hop and returns only
`{:ok, InstanceState.t()}`. Widened to **accumulate every hop's
`pending_event()` list** (order preserved, hop order) and return it as a
third tuple element. Every existing call site
(`activate/3`'s own call, `dispatch_task_completion_hop_chain/5`'s own
call) is updated to bind and use the third element — for now, only
`{:sub_process_start, ...}` entries are actually consumed (§3.3); every
other variant continues to be structurally received but not acted on,
identical to today's behavior, just no longer silently dropped one hop at
a time.

This is the one non-additive signature change this design makes to
already-shipped code — flagged explicitly for REVIEWER: it is the minimum
change that lets a *pure* activation loop still report "creation of a child
instance is needed here" back to an I/O-capable caller without the loop
itself performing I/O.

### 3.2 New module `Letflow.Engine.SubProcess`

Internal support module (not part of any public HTTP-facing contract),
`@moduledoc false`-eligible, mirroring `Letflow.Engine.TaskActivation`'s
"zero `Repo` calls of its own where possible, Multi-composable" shape where
it can, and `Letflow.Engine.ExecutionError`'s "shared sink" shape for the
four failure modes.

#### 3.2.1 Input filtering (activation-time, EXT-05 + interface-filtered)

```
@type activation_failure ::
        {:missing_required_input, entry_name :: String.t()}
        | {:input_schema_violation, entry_name :: String.t(), failures :: [Letflow.EventStore.Registry.ValidationFailure.t()]}

@spec build_child_initial_variables(
        interface :: SubProcessInterface.parsed_interface() | nil,
        parent_variables :: map()
      ) :: {:ok, child_initial_variables :: map()} | {:error, activation_failure()}
```

Pure, no I/O (`JsonSchema.validate/2` is pure). Algorithm:

* `interface == nil` → `{:ok, parent_variables}` (EXT-05, full copy,
  AC "no declared interface").
* `interface != nil` → for each `entry` in `interface.inputs` (declared
  order): `Map.fetch(parent_variables, entry.name)` →
  * `:error` and `entry.required == true` →
    `{:error, {:missing_required_input, entry.name}}` (**first** such
    entry, declared order — deterministic, matching `VariableMerge`'s own
    sorted-first-failure convention adapted to declared order since inputs
    are already an ordered list, not a map).
  * `:error` and `entry.required == false` → key omitted from the result,
    no error.
  * `{:ok, value}` → `JsonSchema.validate(%{entry.name => value}, %{
    "type" => "object", "properties" => %{entry.name => entry.json_schema},
    "required" => [entry.name]})` — **wrapped as a one-field object schema**
    (not called on the bare value) since `JsonSchema.validate/2` requires
    both arguments to be maps (`is_map(payload) and is_map(schema)` guard);
    wrapping is the deliberate adapter this design introduces, not a
    departure from `JsonSchema`'s own contract. `[] `→ include
    `entry.name => value` in the result. Non-empty → `{:error,
    {:input_schema_violation, entry.name, failures}}`.
* An interface declared with `inputs: []` → result is `%{}` (an explicit,
  intentional reading of "ONLY the named inputs are copied" — zero declared
  means zero copied, not a fallback to EXT-05).

#### 3.2.2 Output filtering (completion-time, EXT-05 + interface-filtered)

```
@type completion_failure ::
        {:missing_required_output, entry_name :: String.t()}
        | {:output_schema_violation, entry_name :: String.t(), failures :: [Letflow.EventStore.Registry.ValidationFailure.t()]}

@spec build_parent_merge_variables(
        interface :: SubProcessInterface.parsed_interface() | nil,
        child_variables :: map()
      ) :: {:ok, merge_variables :: map()} | {:error, completion_failure()}
```

Same shape/algorithm as §3.2.1, over `interface.outputs` against
`child_variables` instead of `interface.inputs` against
`parent_variables`. `interface == nil` → full `child_variables` map
(EXT-05). The returned `merge_variables` is what the caller passes as
`incoming_variables` to `VariableMerge.merge/3` (§3.4) — a child variable
not named in `outputs` is never in this map, so it is structurally absent
from the parent afterward (the AC's own wording), not filtered post-merge.

#### 3.2.3 Failure → `ExecutionError.error_args()` mapping

```
@spec to_error_args(
        activation_failure() | completion_failure(),
        instance_id :: Ecto.UUID.t(),
        node_id :: String.t(),
        variables :: map(),
        actor_id :: Ecto.UUID.t() | nil,
        idempotency_key :: String.t()
      ) :: ExecutionError.error_args()
```

Every one of the 4 failure shapes maps to
`error_type: :subprocess_interface_violation` (the atom REQ-061 already
reserves in its `error_type()` open union, named for exactly this
requirement), `affected: {:field, entry_name}`, and a `details.code` naming
which of the 4 R-Co-named codes applies:

| failure() | `details.code` |
|---|---|
| `{:missing_required_input, name}` | `"SUB_PROCESS_MISSING_REQUIRED_INPUT"` |
| `{:input_schema_violation, name, failures}` | `"SUB_PROCESS_INPUT_SCHEMA_VIOLATION"` |
| `{:missing_required_output, name}` | `"SUB_PROCESS_MISSING_REQUIRED_OUTPUT"` |
| `{:output_schema_violation, name, failures}` | `"SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION"` |

`details.failures` carries the `JsonSchema.validate/2` violation list for
the two `_SCHEMA_VIOLATION` codes (`[]`/absent for the two `_MISSING_*`
codes). This satisfies AC "each of the four SPC-01 failure modes ... its
own distinct error" via the `details.code` discriminator — `error_type`
itself stays the single reserved atom, matching how `:no_matching_edge`
already carries its own node/condition detail inside one `error_type`
rather than minting 4 new top-level atoms; a future reader can `grep
details.code` for the exact R-Co-named string.

**Defensive 5th case, flagged explicitly (not one of the requirement's 4
named codes):** a `:SUB_PROCESS` node whose definition reference (§8's
open question) cannot be resolved at all (unknown/blank reference) is
**not** silently ignored or allowed to raise — it routes through this same
`ExecutionError.append_multi` sink with `details.code:
"SUB_PROCESS_DEFINITION_NOT_FOUND"`, same `error_type`, same "zero child
instances created" guarantee. Named here so REVIEWER can see it was a
deliberate defensive addition, not scope creep smuggled into the 4-code
table above (it is a 5th, additional `details.code` value, not a 5th
`error_type`).

### 3.3 Consuming `{:sub_process_start, token_id, node_id}` (activation-time)

New private `Letflow.Engine` function, called once per
`{:sub_process_start, ...}` entry found in `advance_until_stable/4`'s
accumulated pending-events list (§3.1), from **both** call sites that drive
that loop (`activate/3`'s root-token activation, and
`dispatch_task_completion_hop_chain/5`'s post-task-completion hop chain):

```
@spec prepare_child_activation(
        parent_instance_id :: Ecto.UUID.t(),
        parent_variables :: map(),
        node :: Graph.Node.t(),
        opts :: [prefix: String.t()]
      ) ::
        {:ok,
         %{
           child_instance_id: Ecto.UUID.t(),
           definition: ProcessDefinition.t(),
           graph: Graph.t(),
           interface: SubProcessInterface.parsed_interface() | nil,
           child_initial_state: InstanceState.t()
         }}
        | {:error, activation_failure() | {:definition_not_found, term()} | {:graph_structure_invalid, term()} | {:activation_failed, term()}}
```

Runs entirely **before** any Multi step for this child is appended — same
"pure/pre-transaction phase" discipline `Engine.create/2`'s own
`start_instance/5` already established (design doc §4/§5 of
`req045-instance-start-engine-shell.md`), for the same reason: a failed
resolution or a failed input filter must write nothing (AC "ZERO child
instances created"). Steps: resolve the child's definition (§8), build its
`Graph.t()` (`build_graph/1`, reused), parse its `interface` attribute off
`node.attributes["interface"]` via
`SubProcessInterface.parse_interface/2` (reused, §1.3), filter inputs
(§3.2.1), mint `child_instance_id = Ecto.UUID.generate()`, create its
`SnapshotStore` snapshot (own transaction, mirrors
`Engine.create_snapshot/3` exactly), then run the child's own
`advance_until_stable/4` from its `:START` node with the filtered initial
variables — **this can itself recurse** into `prepare_child_activation/4`
again for a nested `:SUB_PROCESS` node inside the child's own graph; see
§9 OQ-3 for the (currently unbounded) recursion-depth question this opens.

```
@spec append_start_multi(
        Multi.t(),
        parent_instance_id :: Ecto.UUID.t(),
        parent_token_id :: String.t(),
        prepared :: <success map from prepare_child_activation/4>,
        attrs :: %{actor_id: Ecto.UUID.t() | nil, idempotency_key: String.t()},
        opts :: [prefix: String.t()]
      ) :: Multi.t()
```

Appends, onto the **caller's already-open** `Multi.t()` (never opens its
own `Repo.transaction/1` — same `INV-EE47-7`/`INV-EE61-7` convention every
sibling module in this package already follows):

1. `instance_projections` insert for `child_instance_id` — same shape as
   `Engine.insert_instance_projection/8`, plus the two new columns from
   §6.1 (`parent_instance_id`, `parent_token_id`).
2. `tokens` row insert(s) for the child's own root token(s)
   (`insert_token_records/4`, reused unchanged) — empty when the child's
   own activation already reached `:END` (mirrors `create/2`'s own
   already-established "an empty token list means the root token already
   reached `:END`" case).
3. `TaskActivation.append_multi/6` for any freshly-`:HUMAN_TASK`-pending
   node(s) the child's own activation produced (reused unchanged).
4. One `INSTANCE_STARTED` event on the **child's** stream
   (`append_instance_started_event/6`-shaped, reused, `payload` additionally
   carrying `parent_instance_id`/`parent_token_id`/`parent_node_id` — the
   only durable record of the parent↔child link besides the
   `parent_instance_id` column itself, load-bearing for §8's pin-inheritance
   seam and for any future audit/observability reader).
5. One `TokenRecord.advance_changeset/2` update on the **parent's** own
   token row: `%{status: :waiting, waiting_child_instance_id:
   child_instance_id}`.
6. **If** `prepared.child_initial_state.status == :completed` (the child's
   graph completed synchronously, e.g. `:START -> :END` with no
   `:HUMAN_TASK`) — immediately chain `append_completion_multi/6` (§3.4)
   for this same `child_instance_id`/`parent_token_id` pair, inside this
   same Multi, before returning. This is what makes "child finishes
   instantly" and "child finishes later via its own `complete_task/3`"
   converge on one completion code path (§3.4) rather than two.

Failure routing (§3.2.3): when `prepare_child_activation/4` returns
`{:error, failure}`, the **caller** (`activate/3` /
`dispatch_task_completion_hop_chain/5`) does **not** call
`append_start_multi/6` at all — it instead returns
`{:execution_error, to_error_args(failure, parent_instance_id, node.id,
parent_variables, actor_id, idempotency_key)}` up through the same
`{:execution_error, error_args}` tagged-tuple channel
`merge_output_variables/5`/`dispatch_task_completion_hop_chain/5` already
use for `complete_task/3`'s own EE-09/EE-05 rejections (req061 §5.2/§5.3),
which the existing `Multi.merge/2` branch point
(`build_complete_task_tail_multi/6`, and its `create/2`-side equivalent to
be added analogously in `persist/8`) already knows how to route into
`ExecutionError.append_multi/3` instead of committing the normal-path
tail. **No child Multi step is ever appended on this path** — AC's "ZERO
child instances created" is structural, not a rollback: `append_start_multi/6`
is simply never called.

### 3.4 Consuming child completion (`append_completion_multi/6`)

```
@spec find_waiting_parent_token(repo :: Ecto.Repo.t(), child_instance_id :: Ecto.UUID.t(), prefix :: String.t() | nil) ::
        {:ok, TokenRecord.t() | nil}

@spec append_completion_multi(
        Multi.t(),
        child_instance_id :: Ecto.UUID.t(),
        child_final_variables :: map(),
        parent_token :: TokenRecord.t(),
        opts :: [prefix: String.t(), actor_id: Ecto.UUID.t() | nil, idempotency_key: String.t()]
      ) :: {:ok, Multi.t()} | {:error, ExecutionError.error_args()}
```

`find_waiting_parent_token/3` — `SELECT ... FOR UPDATE` on `tokens WHERE
waiting_child_instance_id == ^child_instance_id AND status == 'waiting'`
(index §6.2), locked so a concurrent second completion attempt on the same
child can't double-fire the parent cascade. Called from exactly two sites:

* §3.3 step 6 (child completed synchronously at creation time) — here the
  caller already holds `parent_token` in hand from the same Multi's own
  step 5 update, so `find_waiting_parent_token/3` is **not** called a
  second time; `append_completion_multi/6` is invoked directly with that
  already-locked/updated record.
* `Engine.complete_task/3`'s tail-multi builder (`build_complete_task_tail_multi/6`,
  `{:merged, _}, {:advanced, final_instance_state}` clause) — **new**
  step added after `final_instance_state` is known: call
  `find_waiting_parent_token/3` keyed on `task.instance_id` (the instance
  whose task just completed — i.e. this call only ever matters when that
  instance is itself a sub-process child). `nil` → no-op, existing tail
  unchanged. Non-nil **and** `final_instance_state.status == :completed` →
  call `append_completion_multi/6`. Non-nil but `final_instance_state.status
  != :completed` → no-op (the child is still running; the wait persists).

`append_completion_multi/6`'s own body:

1. Re-fetch the **parent's** own graph/node: `SnapshotStore.get_by_instance_id(parent_token.instance_id, ...)`
   → `build_graph/1` → `find_node(graph.nodes, parent_token.node_id)` to
   recover the SUB_PROCESS node's `attributes["interface"]`.
2. `build_parent_merge_variables/2` (§3.2.2). `{:error, failure}` →
   `{:error, to_error_args(failure, parent_token.instance_id, parent_token.node_id, <parent's current variables, unread/unmodified>, actor_id, idempotency_key)}`
   — returned to the caller, which routes it into
   `ExecutionError.append_multi/3` against the **parent's** locked
   projection. **No `Multi` step from this function has been appended
   yet at this point** — the merge-variable computation happens before any
   write, so "the merge is not applied, not partially applied" (AC) is
   again structural: this function simply never builds the merge/advance
   steps below.
3. Success → load the parent's seed `InstanceState` (same
   `build_snapshot_and_state/4`-style reconstruction `complete_task/3`
   already performs, reused/generalized to accept a token_id instead of a
   task_id as the anchor), merge `merge_variables` into it via
   `VariableMerge.merge/3` (`variable_validations: nil` — see §9 OQ-2 on
   why this design does not also re-check the parent's own registered
   variable-type schemas here), then `Transition.transition(graph,
   state_with_merged_variables, {:sub_process_completed,
   parent_token.token_id |> to_string()})` (§2.4), then
   `advance_until_stable/4` for any further hops — which may itself surface
   **another** `{:sub_process_start, ...}` pending event (a SUB_PROCESS
   node immediately following another one) or, recursively, complete the
   **parent** instance too, in which case (if the parent itself has its own
   waiting grandparent token) this function calls itself again,
   grandparent-ward. §9 OQ-3 names the same unbounded-recursion caveat as
   §3.3.
4. Appends, onto the Multi: task-activation + token-reconciliation for the
   parent's own newly-reached nodes (reusing
   `build_task_activation_and_reconciliation_multi/3`'s shape, generalized
   off a token-anchor instead of a task-anchor), one new
   `SUB_PROCESS_COMPLETED` event on the **parent's** stream (payload:
   `child_instance_id`, the filtered `merge_variables`, `merged_variable_events`,
   `activated_nodes` — same shape as `TASK_COMPLETED`'s own payload,
   §9's note on why this event exists), and a `reconcile_projection/5`-style
   update of the parent's own `instance_projections` row. Returns `{:ok,
   multi}`.

## 4. The four SPC-01 failure modes — summary table

| Code | Trigger | When | Child instances created | Parent effect |
|---|---|---|---|---|
| `SUB_PROCESS_MISSING_REQUIRED_INPUT` | required `interface.inputs` entry absent from parent variables | activation (§3.2.1) | zero | `ERROR` via `ExecutionError` |
| `SUB_PROCESS_INPUT_SCHEMA_VIOLATION` | present input fails its `json_schema` | activation (§3.2.1) | zero | `ERROR` via `ExecutionError` |
| `SUB_PROCESS_MISSING_REQUIRED_OUTPUT` | required `interface.outputs` entry absent from child variables | completion (§3.2.2) | (child already exists — this fires *after* it completed) | `ERROR` via `ExecutionError`, merge NOT applied |
| `SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION` | present output fails its `json_schema` | completion (§3.2.2) | (child already exists) | `ERROR` via `ExecutionError`, merge NOT applied |

Every row routes through `Letflow.Engine.ExecutionError.append_multi/3` —
none constructs its own `ERROR` transition (AC's own final bullet, closing
REQ-061's own deferred obligation).

## 5. `waiting_child_instance_id` set/clear/preserve invariant (AC5)

* **Set**: §3.3 step 5, the instant a child instance is durably created
  (same Multi, same transaction — never set on a token whose child creation
  might still roll back).
* **Cleared**: §3.4 step 3, inside `dispatch_sub_process_completion/4`
  (§2.4), via struct-update (`%Token{token | waiting_child_instance_id:
  nil}`) — same transaction that also advances the token off the node,
  never a separate, later write.
* **Preserved across an unrelated token copy**: §1.1's invariant — every
  existing/new dispatch clause that repositions a token via struct-update
  syntax carries the field forward automatically; the GH-428 regression
  test (AC5) exercises this by driving a `:PARALLEL_GATEWAY` split/join (an
  *unrelated* transition) on an instance that also has an independent
  waiting-on-child token, and asserting that token's
  `waiting_child_instance_id` is unchanged afterward.

## 6. DB schema changes

### 6.1 `instance_projections` — two new nullable columns

New migration `priv/repo/migrations/<ts>_add_sub_process_parent_columns.exs`
(tenant-scoped, `if prefix() do` guard, per every other migration in this
schema):

```
alter table(:instance_projections, prefix: prefix()) do
  add :parent_instance_id, references(:instance_projections, column: :instance_id, type: :binary_id, on_delete: :restrict)
  add :parent_token_id, references(:tokens, column: :id, type: :binary_id, on_delete: :restrict)
end

create index(:instance_projections, [:parent_instance_id],
         name: :idx_instance_projections_parent,
         where: "parent_instance_id IS NOT NULL",
         prefix: prefix())
```

Both nullable — `nil` for every top-level (non-child) instance, which is
every instance created today (AC6: `create/2` never sets these). Chosen
over relying solely on the `tokens.waiting_child_instance_id`
parent→child pointer because that pointer is one-directional and transient
(cleared on completion, §5) — `parent_instance_id` is the durable,
permanent child→parent link REQ-059's pin inheritance (§8) and any future
audit/observability read need, and it is available strictly cheaper as a
column than by replaying the child's own `INSTANCE_STARTED` event payload
every time. `on_delete: :restrict` on both FKs, matching this schema's
existing precedent (`tokens.instance_id`/`tokens.parent_token_id`,
`20260818110002_create_tokens.exs`'s own stated reasoning) — no requirement
in Letflow yet deletes an `instance_projections` row.

### 6.2 `tokens` — one new partial index

```
create index(:tokens, [:waiting_child_instance_id],
         name: :idx_token_waiting_child_instance,
         where: "waiting_child_instance_id IS NOT NULL",
         prefix: prefix())
```

Backs `find_waiting_parent_token/3`'s (§3.4) `WHERE waiting_child_instance_id
== ^child_instance_id` lookup. No column addition — `waiting_child_instance_id`
already exists on `tokens` (REQ-043).

### 6.3 No new table

No `sub_process_links`/similar side table. The parent↔child relationship is
fully represented by `instance_projections.parent_instance_id` (durable) and
`tokens.waiting_child_instance_id` (transient, while-running), matching this
schema's established "no redundant side table" discipline
(`tokens` itself exists only because a JSONB array element can't be an FK
target — the same reasoning does not apply here, since both new columns are
plain scalar FKs on already-existing rows).

## 7. `EE-08` (parent cancel) — confirmation, not a change

`Letflow.Engine.cancel_instance/3`'s `fetch_and_lock_open_tasks/3` and
`fetch_and_lock_live_tokens/3` (both already shipped, REQ-052) filter
`where t.instance_id == ^instance_id` — the instance_id **passed to
`cancel_instance/3`**, i.e. the parent's own id. A child's `tasks`/`tokens`
rows carry the **child's** `instance_id` (§3.3 step 1-3), so they are never
selected by a `cancel_instance/3` call scoped to the parent. The parent's
own **waiting** token (status `:waiting`, §5) *is* included in
`fetch_and_lock_live_tokens/3`'s `status in [:active, :waiting]` filter and
so is itself cancelled — correct: the parent's own token stops waiting, but
nothing about that write touches the child's rows. **Zero code change to
`cancel_instance/3` is needed or made by this requirement** — AC7's test
exists precisely because this is a property of pre-existing code, not
obviously true without a test exercising it.

## 8. REQ-059 (pin inheritance) seam — stated, not implemented

`createWithParentInheritance()`'s own R-Co name is the load-bearing hint:
child creation is *the* function pin inheritance hangs off. This design's
seam: `prepare_child_activation/4` (§3.3) receives `parent_instance_id` and
threads it through to wherever the child's `INSTANCE_STARTED` event is
built (§3.3 step 4) — once REQ-059 lands, that same call site is where
`Letflow.Engine.PinResolver.resolve/N` (not yet built) is expected to be
invoked for the child, given `parent_instance_id` as an extra input it uses
to look up the parent's own recorded pin set (from the parent's
`INSTANCE_STARTED`/`INSTANCE_PINS_REBOUND` events, per REQ-059's own PIN-04
description) and compute `source: inherited` entries. **This design does
not call `PinResolver`, does not compute a pin set, and does not add a
`pinned_versions` field anywhere** — REQ-059 owns what a pin entry
contains and how a conflict is recorded; this requirement owns only that
`parent_instance_id` is available, non-optionally, at the exact call site
REQ-059 needs it. Conversely: `Letflow.Engine.create/2`'s own top-level path
(REQ-045) has no `parent_instance_id` to give REQ-059 (root instances have
none) — REQ-059's own resolver must treat a `nil` parent as "no inheritance,
resolve fresh," which is REQ-059's own concern to state, not this one's.

## 9. Open questions (not silently resolved)

* **OQ-1 — SUB_PROCESS node's own definition reference is unspecified
  anywhere in the shipped codebase.** Neither `Letflow.Definitions.Graph`'s
  node-attribute validators (CHK-09..19) nor `SubProcessInterface` name or
  validate any "which definition does this child run" attribute — only the
  optional `interface` attribute is validated today. This design assumes
  (but does **not** verify against unreachable R-Co source) a
  `node.attributes["definition_name"]` string attribute, resolved via
  `Letflow.Definitions.get_active_by_name/2` — the one definition-resolution
  convention already established (`Engine.create/2`'s own
  `attrs[:definition_name]` path), chosen purely for internal consistency.
  **This is a guess, flagged as such, not a verified port.** If the real
  R-Co attribute name/shape differs (e.g. a `definition_id` reference, or a
  nested object), ELIXIR-DEV/REVIEWER must correct this design's §3.3 before
  implementing against it — do not silently build against this assumption
  without re-confirming. No structural graph validator (CHK-09..19) checks
  this attribute's presence/shape at definition time either — §3.2.3's
  defensive `SUB_PROCESS_DEFINITION_NOT_FOUND` code exists because of this
  gap, not despite it.
* **OQ-2 — Should the parent's own registered variable-type schemas
  (`Letflow.EventStore.Registry`, the schemas `complete_task/3`'s
  `variable_validations` argument checks) also apply to a sub-process
  output merge, the way they already apply to a completed task's output
  merge?** This design passes `variable_validations: nil` to
  `VariableMerge.merge/3` in §3.4 step 3 (skip), reasoning that the
  requirement text's "output schema violation" names only the interface's
  own declared `json_schema`, not the registry's separate per-variable-name
  schemas. Not verified against R-Co; a future requirement may need to
  revisit this if a merged sub-process output value should also have been
  registry-rejected.
* **OQ-3 — Recursion depth for nested sub-processes (§3.3, §3.4) is
  unbounded** beyond the existing per-hop `hop_limit` (which bounds a
  *single* instance's own worklist, not the depth of a child-of-child-of-
  child chain). A structural graph cycle within one definition is already
  rejected by REQ-028's validators, but nothing prevents definition A's
  SUB_PROCESS node from referencing definition B, whose own SUB_PROCESS node
  references A again — an infinite creation/completion recursion across
  *different* definitions. Not solved here; flagged for whichever
  future requirement (or a small follow-up to this one) adds a
  cross-definition recursion-depth guard analogous to `hop_limit`.
* **OQ-4 — A child cancelled directly (`Engine.cancel_instance/3` called
  on the child's own `instance_id`) leaves the parent's token permanently
  `:waiting`.** No requirement in this batch specifies a
  cancellation-cascade-to-parent notification (only the reverse, EE-08, is
  named) — this is a known, honestly-flagged gap parallel to R-Co's own
  documented SCH-03/timer gaps elsewhere in this engine, not silently
  patched over here.
