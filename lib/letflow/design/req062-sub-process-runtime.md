# REQ-062 — SPC-01 sub-process runtime half (design)

PROVENANCE (historical, not current decision authority):
Ports the runtime half of `src/definition/sub_process_interface.zig` /
`src/engine/instance.zig`'s SUB_PROCESS handling that REQ-032 explicitly
deferred to S3: `createWithParentInheritance()` (internal-only child
creation), the `sub_process_start` pending event, the parent-token wait
(`waiting_child_instance_id`), input-filter-on-activation, output-merge-on-
completion, and the four SPC-01 failure modes routed through REQ-061's
`Letflow.Engine.ExecutionError` path.

**The R-Co source tree IS reachable** (`c:\Users\tvolo\dev\ai-dala\R-Co`),
and this disclaimer previously said it was not. REQ-111 audited that claim
and established that **this document makes no R-Co line citations at all**,
so the disclaimer guarded nothing. Measured by REQ-111:

PROVENANCE (historical, not current decision authority):
```bash
grep -oE "(instance|transition)\.zig:[0-9]+" lib/letflow/design/req062-sub-process-runtime.md
# no matches; likewise for any `*.zig:N` pattern
```

PROVENANCE (historical, not current decision authority):
`instance.zig` and `transition.zig` are named in prose only (lines 3, 4 and
12 above). The 55 `file:line` citations this document does carry all point
at **Letflow** files (`sub_process.ex`, `engine.ex`, `execution_error.ex`,
`task_activation.ex`, `transition.ex`, `token.ex`, `reconstruction.ex`,
`service_task.ex`, `plugin_interface.ex` and several `_test.exs`) — note
that `transition.ex` and `transition.zig` differ by one character and are
different trees. Those citations are Letflow-internal and were never in
this disclaimer's scope.

What the disclaimer *did* correctly flag is §9's OQ-1, a substantive
assumption rather than a citation. REQ-111 resolved it against the real
source — see OQ-1 for the finding.

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
   task_id as the anchor), look up the parent's own registered
   variable-type schemas via `VariableSchema.variable_validations/5`
   (`repo, parent_definition_id, seed_state.variables, merge_variables,
   prefix: prefix` — REQ-109's own lookup, reused unchanged; see §9 OQ-2,
   verified/RESOLVED 2026-08-20, GH#329) and merge `merge_variables` into
   it via `VariableMerge.merge/3` using that result (a schema-lookup
   failure or a `:rejected` outcome both route into the same
   `ExecutionError.append_multi/3` path as step 2 above, never a partial
   merge), then `Transition.transition(graph,
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
  optional `interface` attribute is validated today. This design assumed a
  `node.attributes["definition_name"]` string attribute, resolved via
  `Letflow.Definitions.get_active_by_name/2` — the one definition-resolution
  convention already established (`Engine.create/2`'s own
  `attrs[:definition_name]` path), chosen purely for internal consistency,
  and flagged at the time as a guess rather than a verified port.

  **RESOLVED BY REQ-111 against the real R-Co source — disposition:
  `divergent_doc_only`.** R-Co keys a child definition on a different
  attribute, with a different resolution mechanism:

  * PROVENANCE (historical, not current decision authority):
    `R-Co/src/engine/transition.zig:1903` — the SUB_PROCESS node's
    `attributes` JSON is parsed for the key **`child_definition_id`**:
    `parsed.value.object.get("child_definition_id") orelse return
    error.InvalidSubProcessConfig`. `:1904` requires it to be a non-empty
    string. The attribute is therefore **mandatory** in R-Co, not optional.
  * PROVENANCE (historical, not current decision authority):
    `R-Co/src/engine/transition.zig:1448` — that value is carried onto the
    `sub_process_start` event as `.child_definition_id`.
  * PROVENANCE (historical, not current decision authority):
    `R-Co/src/engine/instance.zig:4681` — the consumer parses it as a
    **UUID** (`parseUuid(sp.child_definition_id)`), and `:4707-4712` passes
    it straight to `createWithParentInheritance(... child_definition_id
    ...)`. It is a definition **id**, never a name.

  So the guess was wrong on the attribute name (`definition_name` vs.
  `child_definition_id`), on its type (name string vs. UUID), and on its
  optionality (unvalidated vs. mandatory).

  **Why this is documentation-only and NOT a behavioural issue.** Shipped
  Letflow behaviour is internally consistent and defensible: the graph
  schema here is Letflow's own, no validator or requirement mandates either
  attribute, and reusing `Engine.create/2`'s established
  `definition_name` + `get_active_by_name/2` path is a coherent choice.
  Nothing in Letflow is *incorrect* relative to a Letflow specification, so
  REQ-111 recorded the difference here rather than filing an issue.

  **One semantic consequence worth stating explicitly**, since it is a real
  design difference and not merely a naming one: R-Co pins the exact child
  definition version at design time (an immutable UUID — early binding),
  whereas Letflow resolves *whichever version is currently active* at
  activation time (`get_active_by_name/2` — late binding). Publishing a new
  version of a child definition therefore changes what already-deployed
  parent definitions launch, in Letflow but not in R-Co. That is a
  legitimate product decision either way; it is flagged here so a later
  stage chooses it deliberately rather than inheriting it by accident.

  PROVENANCE (historical, not current decision authority):
  No structural graph validator (CHK-09..19) checks this attribute's
  presence/shape at definition time — §3.2.3's defensive
  `SUB_PROCESS_DEFINITION_NOT_FOUND` code exists because of that gap, not
  despite it. R-Co closes the equivalent gap at `transition.zig:1903-1904`
  by rejecting the config outright.
* PROVENANCE (historical, not current decision authority):
  **OQ-2 — RESOLVED 2026-08-20, GH#329.** Should the parent's own
  registered variable-type schemas (`Letflow.Engine.VariableSchema`, the
  same lookup `complete_task/3`'s `merge_output_variables/7` already uses,
  REQ-109) also apply to a sub-process output merge, the way they already
  apply to a completed task's output merge? Verified against R-Co
  (`R-Co/src/engine/instance.zig`'s `mergeVariables`, called at line 4956
  for the sub-process completion path with the exact same `variable_schemas`
  lookup — keyed only on `definition_id`, via the same function every other
  merge call site uses — as a completed task's own merge at line 1856; the
  `task_id` parameter that call omits is used only to tag the
  overwritten-variable event payload, never to skip or scope schema
  validation). **Yes** — R-Co never special-cases a sub-process output merge
  out of registry validation, so this design's previous `variable_validations:
  nil` was a real divergence, not a deliberate simplification. Fixed: the
  merge in §3.4 step 3 now calls `VariableSchema.variable_validations/5`
  first (`Letflow.Engine.SubProcess.build_completion_multi_from_merge/12`),
  exactly as `merge_output_variables/7` already does for a completed task,
  keyed on the **parent's** `definition_id` (the instance whose variables are
  being merged into, not the child's). A `:rejected` outcome routes into
  `ExecutionError.append_multi/3` with `error_type: :variable_schema_rejected`
  — the same error shape REQ-109 already produces for the task-completion
  path — rather than silently merging a registry-invalid value. Covered by
  `test/letflow/engine_sub_process_test.exs`'s new "OQ-2/GH#329" describe
  block: an output value that passes the interface's own per-output
  `json_schema` (SPC-01) but violates a stricter registry row for the same
  key is still rejected, proving the registry lookup — not just the
  interface's own check — is what fires.
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

## 10. Design amendment — post-escalation fix for issues (i)/(ii)/(iii)

Written after ELIXIR-DEV's WF-02 Step 2a handoff (`handoffs/WF02-REQ062-20260819/step-02a-elixir-dev.json`)
exhausted `max_rework` (3/3) and ESCALATED with a scoped run
(`test/letflow/engine_sub_process_test.exs` + `test/letflow/engine_test.exs`)
standing at 36/42 — `engine_test.exs` itself fully green (32/32, no
regression), all 6 remaining failures inside `EngineSubProcessTest`, tracing
to three distinct root causes. This section reasons from the **actually
committed code** (post rework-iteration-3, commits `d437e299`/`d370849c` on
this branch), not from the original §1–§9 text above where the two diverge —
§1–§9 are otherwise still authoritative and are not restated here.

### 10.1 Issue (i) — `Ecto.Multi` `:task_records` key collision

**Root cause, confirmed against the real code:**
`Letflow.Engine.TaskActivation.append_multi_from_existing_records/6`
(`lib/letflow/engine/task_activation.ex:246`) appends its step via
`Multi.run(multi, :task_records, fn repo, _changes -> ... end)` — a fixed
atom key, identical on every call, regardless of which `instance_id` the
call is for. It has exactly two call sites, both already inside this
requirement's own cascade:

1. `lib/letflow/engine.ex:1735`, inside
   `build_task_activation_and_reconciliation_multi/3` (M6/M7 of
   `complete_task/3`'s own tail, built onto the **same outer Multi**
   `Repo.transaction/1` eventually commits) — called with `task.instance_id`,
   i.e. the completing task's own (child, in the sub-process case) instance.
2. `lib/letflow/engine/sub_process.ex:861`, inside
   `build_completion_write_steps/12` (called from
   `append_completion_multi/6`, §3.4) — called with `parent_instance_id`.

When a child's completion cascades to its parent in the same transaction
(`Letflow.Engine.append_sub_process_completion_cascade_multi/6`,
`engine.ex:1663`, chained via `Multi.merge/2` onto the same outer Multi that
call site 1 already populated), Ecto's own static merge-key-collision check
in `Multi.merge/2` sees `:task_records` present on both sides and raises.

**Fix — key-naming convention.** Namespace the step key by instance_id using
a composite tuple, matching the tuple-key convention this exact call graph
already uses everywhere else it needs per-instance/per-token uniqueness in
the same transaction — precedent already in the codebase, not invented here:
`{:sub_process_parent_token_reconciliation, parent_token.id}`,
`{:sub_process_completed_event, parent_token.id}`,
`{:sub_process_parent_projection, parent_token.id}`,
`{:sub_process_grandparent_lookup, parent_instance_id}` (all in
`sub_process.ex`'s `build_completion_write_steps/12` /
`maybe_cascade_to_grandparent/7`), and `{:sub_process_parent_lookup,
instance_id}` (`engine.ex`'s `append_sub_process_completion_cascade_multi/6`).

**Exact change:** in `append_multi_from_existing_records/6`
(`task_activation.ex:246`) only, change

```
Multi.run(multi, :task_records, fn repo, _changes -> ...
```
to
```
Multi.run(multi, {:task_records, instance_id}, fn repo, _changes -> ...
```

`instance_id` is already this function's own second positional parameter —
**no `@spec`/argument signature change is needed anywhere.** Both existing
call sites (`engine.ex:1735`, `sub_process.ex:861`) already pass the correct,
distinct `instance_id`/`parent_instance_id` value positionally; neither needs
editing beyond this one line inside `task_activation.ex` itself. Confirmed
by `grep -rn "task_records" lib/letflow/`: no other code reads
`changes.task_records` (or `changes[:task_records]`) by the literal atom
key anywhere in the codebase, so no downstream reader needs updating either.

**`append_multi/6`** (`task_activation.ex:165`, the sibling function
`Letflow.Engine.create/2`'s own `persist/8` path calls, still under the
fixed atom key `:task_records`) is **deliberately left unchanged.** It has
exactly one call site per Multi (`create/2`'s own top-level persist), so no
two `append_multi/6` steps ever land on the same Multi in one transaction —
no collision is possible, so namespacing it fixes nothing and only widens
REVIEWER's diff for no reason. This is a stated decision, not an oversight.

**Grandparent-cascade recursion (design §3.4 point 3) — confirmed
self-resolving, no extra plumbing needed.** The real recursion point is
`Letflow.Engine.SubProcess.maybe_cascade_to_grandparent/7`
(`sub_process.ex:908`), which — when the parent instance itself completes
as a side effect of this cascade and has its own waiting grandparent
token — calls `append_completion_multi/6` again with a **freshly resolved**
`grandparent_token` (from `find_waiting_parent_token/3`'s own row lookup),
whose `instance_id` is structurally the grandparent's own, distinct from
both the child's and the parent's. Each recursion depth therefore produces
its own distinct `{:task_records, instance_id}` key automatically, with zero
depth-counter or additional argument needed — the fix is sufficient at
unbounded cascade depth (subject to OQ-3's separate, already-flagged
recursion-depth-guard gap, unrelated to this collision).

**Why the tuple key alone is sufficient (the invariant that makes this
correct, not just a lucky escape):** within one transaction,
`append_multi_from_existing_records/6` is called **at most once per
`instance_id`** — once for the hop chain's own completing instance (call
site 1) and, per cascade level, once for that level's newly-implicated
ancestor instance (call site 2, one call per `maybe_cascade_to_grandparent/7`
recursion). No code path calls it twice for the same `instance_id` within
one transaction, so a per-instance-id key can never itself collide with a
second use of the same key for the same instance.

### 10.2 Issue (ii) — `idempotency_key` collision on the `ExecutionError` event path (completion side)

**Root cause, confirmed against the real code — broader than the escalation
record's own framing.** `Letflow.Engine.SubProcess.to_error_args/6`
(`sub_process.ex:200`) stores whatever `idempotency_key` it is handed
verbatim into `error_args.idempotency_key`, which
`Letflow.Engine.ExecutionError.append_execution_error_event/2`
(`execution_error.ex:192`) then passes straight into
`EventStore.append/2`'s own `idempotency_key` field — the same
schema-wide-unique `event_idempotency.idempotency_key` index the two
already-fixed paths (rework iteration 2) collide against. `to_error_args/6`
is called from **four** sites, all inside `append_completion_multi/6`'s own
call graph (§3.4) — **not just the output-filter-rejection one** the
escalation record named:

| Line | Failure branch |
|---|---|
| `sub_process.ex:709` | `load_parent_context/2` failure (`:definition_not_found`) |
| `sub_process.ex:730` | `build_parent_merge_variables/2` rejection (the escalation's named case — `SUB_PROCESS_MISSING_REQUIRED_OUTPUT`/`SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION`) |
| `sub_process.ex:781` | `Transition.transition/3` failure inside `build_completion_multi_from_merge/10` |
| `sub_process.ex:808` | `advance_until_stable/4` failure inside `build_completion_multi_from_merge/10` |

All four are reachable only after the child's own `TASK_COMPLETED` event has
already claimed the caller's raw `idempotency_key` in the **same**
transaction — confirmed by tracing `engine.ex`'s
`build_complete_task_tail_multi/6` second clause (`engine.ex:1564`): its
`:event` step (`append_task_completed_event/5`, raw `idempotency_key`) runs
*before* `append_sub_process_completion_cascade_multi/6` (`engine.ex:1619`),
which is one of `append_completion_multi/6`'s two callers. Its other caller,
`maybe_chain_synchronous_completion/6` (`sub_process.ex:449`, reached via
`append_start_multi/6`'s own §3.3-step-6 synchronous-completion chaining),
is likewise always reached from `append_sub_process_children_creation_multi/6`
(`engine.ex:1612`), which — inside the same `build_complete_task_tail_multi/6`
tail — also runs *after* that same `:event` step. So every one of the four
`to_error_args/6` call sites needs the same fix, not only the one the
escalation record singled out; leaving the other three unfixed would just
surface the identical "transaction rolling back" failure the next time one
of those specific branches is actually exercised (none of the 6 currently
failing tests happens to hit them, but that is incidental, not a guarantee).

**Fix — derivation formula, mirroring the two already-established
conventions exactly (`sub_process.ex:616-617`'s
`"#{idempotency_key}::sub_process_start::#{child_instance_id}"` and
`sub_process.ex:1109-1110`'s
`"#{idempotency_key}::sub_process_completed::#{parent_instance_id}::#{child_instance_id}"`).**
A third, equally-shaped, equally-distinct suffix for the completion-cascade
error path:

```
"#{idempotency_key}::sub_process_completion_error::#{parent_instance_id}::#{child_instance_id}"
```

Distinct from both existing suffixes (`::sub_process_start::`,
`::sub_process_completed::`) so it can never collide with either of them,
and — like both precedents — derived from `child_instance_id` (always a
freshly-minted or already-durable, and in-scope, UUID at every one of the
four call sites) plus `parent_instance_id`, so it is unique per
child/parent pair even across a multi-level cascade.

**Exact call-site change:** compute this once, as a new local binding
`error_idempotency_key`, near the top of `append_completion_multi/6`
(`sub_process.ex:695`), immediately after the existing
`idempotency_key = Keyword.get(opts, :idempotency_key)` line — `parent_token`
and `child_instance_id` are both already in scope there. Use
`error_idempotency_key` (not the raw `idempotency_key`) as the 6th argument
to `to_error_args/6` at line 709 (this function's own local error branch)
and thread it as one new parameter to `build_completion_multi_from_merge/10`
(`sub_process.ex:756`), which needs it for its own two `to_error_args/6`
calls at lines 781 and 808. **`to_error_args/6`'s own `@spec` is unchanged**
(still a plain `idempotency_key :: String.t()` 6th argument, per §3.2.3) —
only the value passed at each of the four sites changes. The **success**
path (`append_sub_process_completed_event/8`, `sub_process.ex:1080`, whose
own `::sub_process_completed::` derivation already exists and is already
correct) is untouched by this fix — it keeps deriving from the raw
`idempotency_key`, unchanged.

### 10.3 Issue (iii) — input-side interface violations: NOT an implementation bug

**This is the one place this addendum's actual finding diverges from the
escalation record's own framing, not just its file/line detail — the
committed implementation is correct here; the test file is wrong.**

The escalation record states the established convention (attributed to
REQ-050/REQ-056) is that `complete_task/3` itself absorbs an EE-10 routing
outcome into `{:ok, _}`. **Checked directly against the real, already-shipped,
already-passing test for that exact claim
(`test/letflow/engine_execution_error_test.exs:410`, `describe "AC4a --
REQ-050's realistic downstream-gateway no-match"`) and it asserts the
opposite:**

```elixir
assert {:error, {:instance_execution_error, :no_matching_gateway_edge, {:node, "gw"}}} =
         Engine.complete_task(task.id, complete_attrs(), prefix: schema_name)
```

— with that same test file's own comment (line ~406) explaining exactly why:
`interpret_complete_result/1`'s leading clause (`engine.ex:1916-1918`)
`{:ok, %{complete_task_outcome: {:execution_error, error_args}}} -> {:error,
{:instance_execution_error, error_args.error_type, error_args.affected}}` is
the **one, single, uniform** conversion every EE-10-routed
`complete_task/3` call already goes through — REQ-050's gateway-condition
failure included. There is no code path, old or new, that returns `{:ok,
%{instance_status: :error, ...}}` from `complete_task/3`: `complete_result()`'s
own `@spec` (`engine.ex:1005-1012`) restricts `instance_status` to `:active
| :completed`, never `:error`.

The two currently-failing input-side tests in
`test/letflow/engine_sub_process_test.exs` —
`describe "AC3/AC8 -- SUB_PROCESS_MISSING_REQUIRED_INPUT..."` (lines 332–378)
and `describe "AC3/AC8 -- SUB_PROCESS_INPUT_SCHEMA_VIOLATION..."` (lines
380–413) — both assert `{:ok, result} = Engine.complete_task(gate_task.id,
...)` followed by `result.instance_status == :error` (lines 353–359,
404–407), with an inline comment claiming this "still returns `{:ok, _}`"
per "req061's own established channel." That premise is what's wrong, not
the implementation: it contradicts REQ-050's own already-shipped precedent
it claims consistency with.

**AC8's actual wording** ("each of the four SPC-01 failure modes is
demonstrated routing into REQ-061's `set_instance_error` rather than
writing its own ERROR transition, confirmed by inspection and by test")
requires only that the *internal write path* go through
`ExecutionError.append_multi/3` (the same steps `set_instance_error/2`
itself performs) — which the current implementation **already does**,
structurally, for the input-side case: `prepare_sub_process_children_for_completion/7`
(`engine.ex:1469`) converts `SubProcess.prepare_child_activation/4`'s
`{:error, activation_failure()}` into `{:halt, {:execution_error,
error_args}}` (line 1499-1510), which its own outer `case` converts to `{:ok,
{:execution_error, error_args}}` (line 1515) — the exact same tagged shape
REQ-050's gateway-failure path produces (`engine.ex:1424`) — which
`build_complete_task_tail_multi/6`'s first clause (`engine.ex:1549-1562`)
then routes into `ExecutionError.append_multi/3`. AC8 does **not** require
`complete_task/3`'s own external return shape to be `{:ok, _}`.

**Required fix, and its owner:** this is a **test-expectation correction**,
routed to **TEST-DESIGNER** on the next WF-02 cycle, not another
ELIXIR-DEV rework iteration. Both tests' initial assertion should become:

```elixir
assert {:error, {:instance_execution_error, :subprocess_interface_violation, {:field, "amount"}}} =
         Engine.complete_task(gate_task.id, complete_attrs(), prefix: schema_name)
```

— exactly mirroring AC4a's own shape/style — with the `result.`-based
assertions removed (there is no `result` on this branch) and every
following independent-re-fetch assertion (`Repo.get!(InstanceProjection,
...)`, `projection.status == :error`, `projection.error_detail[...]`,
`still_pending.status == :pending`, `execution_error_events(...)`) left
exactly as already written — those already correctly follow AC4a's own
"assert the return, then independently re-fetch and re-verify" pattern and
need no change.

**No change to `lib/letflow/engine.ex`, `lib/letflow/engine/sub_process.ex`,
or `lib/letflow/engine/execution_error.ex` is needed for issue (iii).**

## 11. Design amendment — `execution_error.ex` `error_detail.details` gap

Written after ELIXIR-DEV's §10.1/§10.2 rework brought the scoped run
(`test/letflow/engine_sub_process_test.exs`) from 42 tests/6 failures to
42 tests/4 failures. Two of the four remaining failures are §10.3's
already-routed test-assertion issue (TEST-DESIGNER's scope, untouched by
this section). The other two are a newly discovered gap in **already-shipped
REQ-061 code**, found by ELIXIR-DEV while implementing §10.2 and not covered
by §1–§10 above.

### 11.1 Root cause, confirmed against the real code

`Letflow.Engine.ExecutionError.update_projection_to_error/4`
(`lib/letflow/engine/execution_error.ex:220-231`) builds the `error_detail`
map it writes onto `instance_projections.error_detail` from exactly four
keys — `"error_type"`, `"affected"`, `"reason"`, `"occurred_at"` — and never
reads `error_args.details` at all, even though:

- `error_args()`'s own `@type` (`execution_error.ex:82-91`) already declares
  `optional(:details) => map()`.
- The sibling function on the same `append_multi/3` cascade,
  `append_execution_error_event/2` (`execution_error.ex:192-214`), already
  does copy it into the **event** payload: `details: Map.get(error_args,
  :details, %{})` (line 199).
- `Letflow.Engine.SubProcess.to_error_args/6` (`lib/letflow/engine/sub_process.ex:200-211`,
  §10.3's own subject) is the caller that first populates `error_args.details`
  with content a test asserts on: `%{code: code, failures: failures}` — e.g.
  `%{code: "SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION", failures: [...]}`.

So the `EXECUTION_ERROR` event's payload has always correctly carried
`details` (confirmed: §3.4 point 4 / the AC1 event test at
`test/letflow/engine_execution_error_test.exs:305-327` already asserts
event-payload fields, though not `details` specifically) — it is
specifically the **projection-column copy** inside
`update_projection_to_error/4` that drops it on the floor. This is a gap in
REQ-061's original implementation that had no prior caller supplying
`details`-bearing content a test asserted against on the *projection* side
until REQ-062's `to_error_args/6` did.

**Confirmed failing tests (both already pass through §10.1/§10.2's fixed
event-append path — this is not a re-occurrence of the earlier
transaction-rollback crash):**

- `test/letflow/engine_sub_process_test.exs:459` (`SUB_PROCESS_MISSING_REQUIRED_OUTPUT`
  describe block, lines 421-469) — `parent_projection.error_detail["details"]["code"]`
  reads `nil` instead of `"SUB_PROCESS_MISSING_REQUIRED_OUTPUT"`.
- `test/letflow/engine_sub_process_test.exs:505` (`SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION`
  describe block, lines 471-508) — same assertion shape, `nil` instead of
  `"SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION"`.

Note two *other* assertions of the identical shape already exist and are
**not** in the failing set —
`test/letflow/engine_sub_process_test.exs:364` and `:410`
(`SUB_PROCESS_MISSING_REQUIRED_INPUT` / `SUB_PROCESS_INPUT_SCHEMA_VIOLATION`).
Those two tests fail earlier in the same test body, on the `complete_task/3`
return-value match itself (§10.3's issue) — they never reach the
`error_detail["details"]` assertion line at all under the current code, so
they do not currently exercise this gap. Once §10.3's test-assertion fix
lands (TEST-DESIGNER, separate cycle) and those two tests' leading match is
corrected to the `{:error, {:instance_execution_error, ...}}` shape, they
will reach their own `error_detail["details"]["code"]` assertion
(lines 364, 410) — which requires this §11 fix to pass too. This section's
fix is therefore a prerequisite for §10.3's corrected tests to go green, not
an independent, unrelated change.

### 11.2 Safety check — is copying `details` unconditionally safe for every existing `error_type`? **Yes, confirmed safe.**

`grep -rn "error_detail" test/` (run directly, not inferred) surfaces every
existing assertion against `instance_projections.error_detail` across the
suite:

- `test/letflow/engine_execution_error_test.exs:319-320` — field-level:
  `error_detail["error_type"] == ...`, `error_detail["affected"] == ...`.
  Note this test's own `error_attrs/2` helper (line 213-227) **already
  defaults `details: %{rejected_value: 999_999, failures: []}`** on every
  call unless overridden — i.e. a `details`-bearing `error_args` has already
  been flowing through `update_projection_to_error/4` since REQ-061 shipped,
  silently dropped; this test simply never asserted on the `details` key one
  way or the other, so it was never in a position to catch the drop.
- `test/letflow/engine_execution_error_test.exs:351` —
  `error_detail == nil` (asserts the whole *column* is nil after a rolled-back
  transaction — `details` was never involved, this is the AC2 abort case
  where `error_detail` is never set at all).
- `test/letflow/engine_execution_error_test.exs:415` — `error_detail != nil`
  (existence check only).
- `test/letflow/engine_plugin_error_routing_test.exs:273` — field-level:
  `error_detail["error_type"] == "plugin_error_outcome"`.
- `test/letflow/engine/service_task_routing_test.exs:228,278` — field-level:
  `error_detail["error_type"] == "..."`.
- `test/letflow/engine_sub_process_test.exs:363-364,410,459,505` — field-level,
  including the two `["details"][...]` assertions this section fixes.

**No test anywhere in the suite asserts `error_detail` via exact map
equality** (`assert error_detail == %{...fixed set of keys...}`) — every
existing assertion is field-level (`error_detail["some_key"] == ...`) or a
presence/absence check (`== nil` / `!= nil`) on the column as a whole.
Adding a `"details"` key to the map therefore cannot break any existing
exact-match assertion, because none exists. Three other call sites already
build `error_args.details` today —
`lib/letflow/engine/plugin_interface.ex:252`,
`lib/letflow/engine/service_task.ex:323,477` — and none of their own tests
assert on `error_detail["details"]`, so none of them are relying on its
current absence either.

**Conclusion: this is a strictly additive fix, safe to apply
unconditionally to every `error_type`, not scoped to `:subprocess_interface_violation`.**
Making it conditional (e.g. only for `error_type == :subprocess_interface_violation`)
would be *more* code than the unconditional form for zero additional safety,
and would leave the same gap open for `plugin_error_outcome` /
`service_task_retries_exhausted` / `service_task_url_rendered_empty`'s own
`details` payloads (already built, already silently dropped from the
projection, just not yet asserted on by any test) — an unnecessary and
strictly worse design.

### 11.3 Exact fix

**File:** `lib/letflow/engine/execution_error.ex`.
**Function:** `update_projection_to_error/4` (private, lines 220-231).

Change the `error_detail` map literal to include a `"details"` key, sourced
the same way `append_execution_error_event/2` (line 199) already sources it
— `Map.get(error_args, :details, %{})`, i.e. present-when-supplied,
`%{}`-default when the caller omits it (matches `error_args()`'s own
`optional(:details)`, no caller is required to change). No other field in
the existing map literal changes; no function signature changes; no
`@spec` changes (`error_args()` already declares `optional(:details) =>
map()`, this fix only starts *reading* a field the type already allows).

Resulting `error_detail` shape (four existing keys, `+1` new):

```
%{
  "error_type"  => String.t(),      # unchanged
  "affected"    => map(),           # unchanged, encode_affected/1 shape
  "reason"      => String.t(),      # unchanged
  "occurred_at" => String.t(),      # unchanged, ISO8601
  "details"     => map()            # NEW — error_args.details verbatim, %{} if absent
}
```

The module doc comment immediately above the function (`execution_error.ex:216-219`,
"error_detail (design doc §8) deliberately excludes the variable-map
snapshot...") stays accurate as-is — `details` is not the variable-map
snapshot it is warning against, and the comment does not claim `error_detail`
is limited to exactly four keys, so no comment rewrite is required beyond
what ELIXIR-DEV naturally adds documenting the new key.

**No migration needed** — `instance_projections.error_detail` is already a
`jsonb`/map-typed column (REQ-061, already shipped); this fix changes only
the map's contents, not its column type or the `InstanceProjection` schema's
field list.

**No changes needed to:** `append_execution_error_event/2` (already correct,
§10.2 confirmed the event path works), `SubProcess.to_error_args/6`, or any
other `error_args`-constructing call site (`plugin_interface.ex`,
`service_task.ex`) — this is a single, minimal, additive change at the one
place the copy was missing.

### 11.4 Open question

None — §11.2's grep is exhaustive over `test/` and finds no exact-match
assertion that would be broken; this fix is unconditional and has no
remaining ambiguity for ELIXIR-DEV to resolve.

## 12. Design amendment — `reconstruction.ex` `{:sub_process_start, ...}` replay gap (post rework-3 full-suite run)

Written after TEST-RUNNER's full-suite rework-3 run
(`test/reports/report-20260819-WF02-REQ062-20260819-rework3-fullsuite.yaml`,
5 properties / 1051 tests / 1 failure) found `lib/letflow/engine/reconstruction.ex`
still failing its own already-shipped test —
`test/letflow/engine/reconstruction_test.exs:675` ("req062 — SUB_PROCESS_COMPLETED
replay reconstructs the same state the live completion path produced"), which
this design doc's §1–§9 already named as this requirement's own reconstruction
coverage (§ "Files touched" list, `test/specs/REQ-062.md`'s "`reconstruction_test.exs`'s
new test is REQ-053's own replay contract (EE-11) extended..." line). Not new
scope — `reconstruction.ex` was never actually green on this branch until now
(confirmed by the report's own `git stash` comparison: pre-rework-3 it crashed
earlier, inside its own DB setup, on the unrelated `:task_records` Multi
collision §10.1 already fixes; rework-3's fix let the test run far enough to
reach this separate, pre-existing gap for the first time).

### 12.1 Root cause, confirmed against the real code

`reconstruction.ex`'s `apply_event/3` clause for `"INSTANCE_STARTED"`
(line 457) calls `Engine.advance_until_stable/4` and pipes the result through
`drop_pending_events/1` (line 634), which discards every `pending_event()`
in the returned list unconditionally. When the seeded token's forward drive
reaches a `:SUB_PROCESS` node, `Transition.transition/3`'s
`dispatch_sub_process_entry/4` clause (`transition.ex:479-486`) leaves the
token sitting on that node (`waiting_child_instance_id` still `nil`) and
emits `{:sub_process_start, token_id, node_id}` as a `pending_event()` —
real child-instance creation is a DB write (`Letflow.Engine.SubProcess`'s
own live-path Multi), which `Transition` itself never performs (its own
"Purity" moduledoc section) and which `reconstruction.ex` must never perform
either (INV-RC-1, read-only by default). `drop_pending_events/1` throws this
signal away, so the in-memory token is left looking exactly like an
ordinary, non-waiting token parked on a `:SUB_PROCESS` node.

Later, when replay reaches the parent's own persisted `SUB_PROCESS_COMPLETED`
event, `find_sub_process_completion_token/2` (line 577) filters
`state.tokens` for `waiting_child_instance_id == child_instance_id` (the
payload's own field — no `node_id` is persisted on this event type, per the
moduledoc finding at line 27). Zero tokens carry any `waiting_child_instance_id`
at all (the marking step above never ran), so the filter always returns `[]`,
producing `{:error, {:ambiguous_sub_process_completion, child_instance_id}}`
— exactly the failure the report reproduces.

Two more call sites pipe `Engine.advance_until_stable/4`'s result through the
same `drop_pending_events/1` — `dispatch_task_completion/3` (line 594) and
`dispatch_sub_process_completion/3` (line 614). Both are reachable after a
prior `TASK_COMPLETED`/`SUB_PROCESS_COMPLETED` event has already advanced a
different token to a `:SUB_PROCESS` node later in the same replay (e.g. an
instance with two independent branches, one already past its own child
completion, the other only now reaching its `:SUB_PROCESS` node) — the fix
below applies at all three call sites uniformly, not only the
`"INSTANCE_STARTED"` one the report's stack trace happens to exercise.

### 12.2 Fix — consume `{:sub_process_start, ...}` during replay by parking the token, never by creating a child

Replace `drop_pending_events/1` (line 634) with a new private function,
`resolve_pending_events/1`, at all three of its current call sites
(`apply_event/3`'s `"INSTANCE_STARTED"` clause, `dispatch_task_completion/3`,
`dispatch_sub_process_completion/3`). Same 3-tuple-in/2-tuple-out adapter
shape `drop_pending_events/1` already has (`{:ok, state, pending_events} ->
{:ok, new_state}` / `{:error, _} = error -> error`), except instead of
discarding `pending_events` it folds over the list and, for every
`{:sub_process_start, token_id, _node_id}` entry (ignoring `:parallel_split`
/`:parallel_join_fired`/`:parallel_join_cancelled` entries exactly as
`drop_pending_events/1` already does today — those three stay in-memory-only
per this module's own moduledoc finding and never need replay-time
resolution, since `Transition.transition/3` already fully applies their
token-set change to the returned `InstanceState` before emitting them; only
`:sub_process_start` leaves the graph "unfinished" from replay's point of
view), replaces that `token_id`'s entry in `state.tokens` with a
struct-updated copy: `%Token{token | waiting_child_instance_id:
@replay_pending_child_marker}`.

`@replay_pending_child_marker` is a new private module attribute in
`reconstruction.ex`:

```
@replay_pending_child_marker "reconstruction:pending_child"
```

A short, human-readable, structurally-non-UUID string (contains `:`, which
`Ecto.UUID.generate/0` output never does) — chosen so it can never collide
with a real `child_instance_id` even in principle, not merely in practice.
It is a private implementation detail of this module only: no other module
reads or pattern-matches on it, `Transition`'s own
`dispatch_sub_process_entry/4` guard (`transition.ex:472-477`) only checks
`not is_nil(waiting_child_instance_id)` — never equality against any
specific value — so this marker satisfies that guard exactly the same way a
real live-path `child_instance_id` would, with no `Transition`/`Engine`
change needed anywhere.

**Why parking (setting the field to a marker), not creating a real child:**
`reconstruct_instance/2` must stay read-only by default (INV-RC-1) — it has
no code path that could perform `Letflow.Engine.SubProcess`'s child-creation
Multi even if it wanted to, and doing so would also violate the
already-established finding that replay cannot recover the *original*
`token_id`/`branch_id` bit-for-bit (moduledoc, line 38-45) — inventing a
*new* live child instance during a replay would fabricate a
`child_instance_id` that never existed on the original run, silently
diverging from ground truth instead of surfacing the gap. Parking with a
non-claiming marker is the only option consistent with both invariants: it
records "this token is known to be waiting on some child, identity unknown
until a later event says so" without asserting a specific, possibly-wrong
identity.

### 12.3 Fix — matching a later `SUB_PROCESS_COMPLETED` event against the *correct* parked token (rework — see 12.3.0)

#### 12.3.0 Why the first version of this section was wrong (CODE-DESIGN-VALIDATOR rework 1/3)

The original draft of this section matched purely on `waiting_child_instance_id
== @replay_pending_child_marker` — one **fixed, shared** constant. That
breaks the moment two sibling `:SUB_PROCESS` branches are parked at once
(a real, in-scope shape: §5/AC5's own GH-428 regression test already
exercises a parallel-gateway split with an independent waiting-on-child
token on another branch — a graph with two `:SUB_PROCESS` nodes fed by a
`:PARALLEL_GATEWAY` split is the same shape, just both branches unresolved
simultaneously instead of one). Both parked tokens would carry the
*identical* marker string, so replaying **either** child's
`SUB_PROCESS_COMPLETED` event would filter to two matches and incorrectly
return `{:error, {:ambiguous_sub_process_completion, ...}}`, even though the
event payload's own `child_instance_id` does unambiguously identify one
specific child — the previous draft's `:zero_or_many`-only framing is
correct machinery, but it fires spuriously here because the *matching key*
carries no per-child information at all. The former §12.6 OQ-1 tried to wave
this off ("still exactly one match" / "cannot happen") — both claims were
wrong and mutually contradictory; there is no reachability argument that
rules this case out, so it needed an actual fix, not a deferral.

**The missing piece:** a marker keyed only by "is parked" can never
disambiguate between two parked tokens using information available *on the
parent's own event stream* — the `SUB_PROCESS_COMPLETED` payload carries no
`node_id` (moduledoc finding, line 27) and never will (that payload shape is
already durably persisted by shipped code; this fix cannot retroactively add
a field to it). Disambiguation therefore needs one more, real fact this
module does not currently look at: **which node the child was actually
started from** — durably recorded, once, on the **child's own** stream, not
the parent's.

#### 12.3.1 The correlating fact already exists, durably, one hop away

`Letflow.Engine.SubProcess.append_instance_started_event_for_child/8`
(`sub_process.ex:576-624`) is the code that persists a child's very first
event — its own `"INSTANCE_STARTED"`, on the **child's** `instance_id`
stream — and its payload already includes `parent_node_id` (line 593:
`payload = Jason.encode!(%{..., parent_instance_id: parent_instance_id,
parent_token_id: parent_token_record_id, parent_node_id: parent_node_id})`).
This is the exact node the parent's token was sitting on when it spawned
this specific child — written once, transactionally, at child-creation time,
on the live path only (this fix never writes it; it only reads what the
live path already wrote). Reading it is still reading **the event log**
(one instance's own `INSTANCE_STARTED` event, `events`/`events_archive`,
merged by `sequence_number` exactly like `read_full_log/2` already does) —
it does not touch `instance_projections`, so it does not conflict with
INV-RC-2's literal text ("no function on the replay path ever reads
`instance_projections`"). It *is* however a genuinely new capability this
module has never had before — reading a **different** instance's own event
log during one instance's reconstruction — flagged explicitly as divergence
5 below, for REVIEWER, following this module's own established "deliberate
divergence" cataloguing precedent (moduledoc, divergences 1-4).

#### 12.3.2 New helper: `fetch_child_parent_node_id/2`

```
@spec fetch_child_parent_node_id(child_instance_id :: String.t(), prefix :: String.t()) ::
        {:ok, node_id :: String.t()}
        | {:error, {:child_start_event_missing, child_instance_id :: String.t()}}
        | {:error, {:malformed_payload, event_id :: Ecto.UUID.t(), reason :: term()}}
```

Queries `Event`/`ArchivedEvent` for `instance_id == child_instance_id and
event_type == "INSTANCE_STARTED"` (both tables, same merge-by-sequence
pattern `read_full_log/2` already uses, same `$ref` payload resolution via
the existing `resolve_live_payloads/2`) and expects **exactly one** row —
every instance has exactly one `INSTANCE_STARTED` event by construction,
never zero (once the child exists at all) and never more than one (no code
path appends a second). Zero or more-than-one rows is
`{:error, {:child_start_event_missing, child_instance_id}}` — a new
`replay_failure_reason()` variant, added to the `@type` union
(`reconstruction.ex:194-204`) alongside the existing 9. On exactly one row,
extracts `payload["parent_node_id"]` via the same `fetch_string_field/2`
helper already used elsewhere in this module (malformed/missing field ->
the existing `{:malformed_payload, event_id, reason}` variant, no new type
needed for that case).

#### 12.3.3 `apply_event/3`'s `"SUB_PROCESS_COMPLETED"` clause and `find_sub_process_completion_token/2` — updated shape

`apply_event/3` (and every private helper it calls transitively for this
event type — `find_sub_process_completion_token/2`,
`dispatch_sub_process_completion/3`) gains a `prefix` argument, threaded
from `replay/3` (which already has it in scope) through `fold_events/3`.
This is the one signature change every `apply_event/3` clause picks up
(most clauses ignore the new argument; only `"SUB_PROCESS_COMPLETED"` uses
it) — necessary because `fetch_child_parent_node_id/2` is a `Repo` read and
every `Repo` call in this module is `prefix:`-scoped (tenant isolation,
same discipline as `read_full_log/2`/`write_back/3`).

```
defp apply_event(graph, state, %{event_type: "SUB_PROCESS_COMPLETED"} = event, prefix) do
  with {:ok, child_instance_id} <- fetch_string_field(event, "child_instance_id"),
       {:ok, output_variables} <- fetch_map_field(event, "output_variables"),
       {:ok, parent_node_id} <- fetch_child_parent_node_id(child_instance_id, prefix),
       {:ok, parked_token} <-
         find_sub_process_completion_token(state.tokens, parent_node_id, child_instance_id) do
    ...
```

`find_sub_process_completion_token/3` (arity grows from 2 to 3 — same name,
new disambiguating parameter) now filters on **two** conditions together,
not one shared constant:

```
defp find_sub_process_completion_token(tokens, parent_node_id, child_instance_id) do
  case Enum.filter(tokens, fn token ->
         token.node_id == parent_node_id and
           token.waiting_child_instance_id == @replay_pending_child_marker
       end) do
    [token] -> {:ok, token}
    _zero_or_many -> {:error, {:ambiguous_sub_process_completion, child_instance_id}}
  end
end
```

`token.node_id` is **not** new information this fix invents — every `Token`
already carries its own current `node_id` (`token.ex:11,17`, it is the
field `dispatch_sub_process_entry/4` never changes while a token is parked,
since a parked token's whole point is that it stays put). Combining
"sitting at the specific node the child says it was spawned from" (real,
per-child-unique information, now sourced from the child's own event) with
"still carries the generic parked marker" (rules out an already-resolved or
never-parked token) is what makes this match sound even with N concurrently
parked siblings, each pinned to a distinct `node_id` by construction (two
tokens simultaneously parked at the *same* `node_id` would itself be a
structural anomaly this module has no way to disambiguate — same
irreducible limit `find_task_completion_token/2` already accepts for
`:HUMAN_TASK` position-matching, not new to this fix).

The generic `@replay_pending_child_marker` from §12.2 is therefore **kept,
unchanged** — it still answers "is this token parked at all", which
`node_id` alone cannot (a token could legitimately be sitting at a
`:SUB_PROCESS` node's `node_id` string for reasons unrelated to parking,
e.g. before `resolve_pending_events/1` runs — the two-condition filter is
deliberately conjunctive, not `node_id` alone).

On `{:ok, parked_token}`, exactly as the previous draft: replace that token
in `state.tokens` with `%Token{parked_token | waiting_child_instance_id:
child_instance_id}` (the marker -> real id, both invariants from §12.2's
"why parking" reasoning still hold — this never fabricates a child, it only
records the id the payload already gave us) via the same `replace_token/2`
helper, then continue into `VariableMerge.merge/3` and
`dispatch_sub_process_completion/3` unchanged.

### 12.4 `Letflow.Engine.Token` struct — no shape change

`Token`'s existing `waiting_child_instance_id: String.t() | nil` field
(`token.ex:11,17`) is reused as-is, holding either `nil` (not waiting),
`@replay_pending_child_marker` (replay-only, transiently, between the
`{:sub_process_start, ...}` pending event and the matching
`SUB_PROCESS_COMPLETED` event), or a real `child_instance_id` (both on the
live path, and briefly during replay per §12.3.3). `Token`'s existing
`node_id` field is likewise reused, not added — it is what
`find_sub_process_completion_token/3` now also filters on (§12.3.3), doing
double duty exactly the way it already does for `find_task_completion_token/2`.
No new field, no `@type` widening. Two rejected alternatives:

1. **A second boolean field** (e.g. `replay_parked?: boolean()`) — rejected
   for the same reason the original draft gave: both shared guards
   (`Transition.dispatch_sub_process_entry/4`,
   `dispatch_sub_process_completion/4`) key off
   `not is_nil(waiting_child_instance_id)` alone, so `waiting_child_instance_id`
   must be non-nil regardless; a boolean would be pure duplication.
2. **A node-id-encoded marker string** (e.g. `waiting_child_instance_id =
   "reconstruction:pending_child:" <> node_id`, CODE-DESIGN-VALIDATOR's own
   suggested direction for fixing 12.3's original gap) — considered, and
   rejected in favor of §12.3.3's two-condition filter, because `Token`
   already has a dedicated `node_id` field carrying exactly that
   information natively and type-checked (`String.t()`, no parsing) —
   encoding it into a second string field as a suffix would (a) require a
   parse/strip step everywhere the marker is read back apart from its
   "is-parked" role, (b) still need the *same* cross-instance read
   (§12.3.1/12.3.2) to learn the completing child's own `parent_node_id`
   to compare against, since the `SUB_PROCESS_COMPLETED` payload has no
   `node_id` either way — so it buys no reduction in the read this fix
   already needs, only adds string-encoding risk for no benefit.

### 12.5 Acceptance-criteria mapping — no new scope; one flagged divergence

This section fixes `reconstruction.ex` against `reconstruction_test.exs`'s
own already-existing test (line 674-726), already named in this design
doc's own "files touched" list and in `test/specs/REQ-062.md` as this
requirement's reconstruction coverage — no acceptance criterion is added,
widened, or reinterpreted. TEST-RUNNER's rework-3 report already confirms no
other test (1050 of 1051) regresses; this fix only needs to turn that one
remaining failure green, plus correctly handle the concurrent-siblings case
CODE-DESIGN-VALIDATOR's rework-1 finding surfaced (not itself exercised by
the current test — see §12.6 OQ-1). No migration, no
`Transition`/`Engine`/`SubProcess` change, no API-surface change (§ "Scope
boundary (AC7)" — reconstruction's S4 HTTP wrapper remains out of scope,
unaffected).

**Divergence 5 (moduledoc's own "deliberate divergences" catalogue,
extended by this addendum):** `reconstruct_instance/2`'s replay path reads
a second instance's own event log (the completing child's single
`INSTANCE_STARTED` event, §12.3.1/12.3.2) — previously this module only
ever read the *target* instance's own `events`/`events_archive` rows. Still
compliant with INV-RC-1 (read-only — this is a `Repo.all`, no write) and
with INV-RC-2's literal text (still never reads `instance_projections`),
but it is a genuinely new shape of read this module has not needed before,
so it is called out explicitly here — matching this module's own
established practice (moduledoc divergences 1-4) — rather than left for
REVIEWER to notice unaided in the diff.

### 12.6 Open questions

* **OQ-1 (resolved by this rework, kept as a record of the correction).**
  The previous draft of this section left an open question claiming the
  `:zero_or_many` "many" branch was unreachable ("cannot happen"), while
  simultaneously describing the exact scenario (two sibling `:SUB_PROCESS`
  branches parked at once) that reaches it — a direct contradiction,
  correctly caught by CODE-DESIGN-VALIDATOR (rework 1/3). That scenario
  **is** reachable (§5/AC5's own GH-428 test already proves concurrent
  independent waiting-on-child tokens are a real, in-scope shape) and,
  under the original shared-constant marker, **did** produce a spurious
  `:zero_or_many` on every completion replay once two siblings were parked
  simultaneously, not just on a genuine data anomaly. §12.3's rework fixes
  this structurally (disambiguating by `node_id`, sourced from the
  completing child's own `parent_node_id`), so the two-sibling case now
  resolves to exactly one match, correctly, without hitting `:zero_or_many`
  at all. The `_zero_or_many` branch inside `find_sub_process_completion_token/3`
  is now reachable only by a genuine structural anomaly (two tokens
  simultaneously parked at the *identical* `node_id`, or the marker
  surviving on a token whose child was never actually the one that
  completed) — the same class of "should be unreachable, kept as a typed
  totality guard rather than a `raise`" branch `find_task_completion_token/2`
  already has for its own `node_id`-position match, not a gap specific to
  this fix.
* **OQ-2 (non-blocking, new).** The existing test at
  `reconstruction_test.exs:674-726` exercises exactly one parked child per
  replay. It does not yet exercise the concurrent-siblings case §12.3
  specifically fixes (two `:SUB_PROCESS` branches parked at once via a
  `:PARALLEL_GATEWAY` split, then both `SUB_PROCESS_COMPLETED` events
  replayed in either order) — the scenario CODE-DESIGN-VALIDATOR's finding
  was about. Flagged for TEST-DESIGNER to add as regression coverage on the
  next cycle that touches this test file (mirrors the already-existing
  GH-428 live-path regression test's own graph shape, replayed instead of
  asserted live) — not required to land in the same rework as the
  `reconstruction.ex` fix itself, but strongly recommended given this is
  precisely the case that was silently wrong before this rework.
