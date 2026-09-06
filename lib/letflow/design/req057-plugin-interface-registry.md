PROVENANCE (historical, not current decision authority):
# Design: REQ-057 — Plugin handler interface and registry contract (`plugin_interface.zig` +
`plugin_registry.zig`, EXT-03)

**Requirement:** REQ-057 (this run's handoff `context.requirement_text`, stage S3)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ057-20260819`, WF-02 Step 1
**This document produces:** `Letflow.Engine.PluginInterface` (the behaviour, its
`ExecutionContext` struct, the crash-safety `invoke/2,3` wrapper, and the pure
`build_error_args/3` mapper) and `Letflow.Engine.PluginRegistry` (the registration/freeze/
resolution contract), the registry's storage-mechanism decision (with reasoning, resolving the
tension the handoff explicitly left open), the exact wiring into REQ-061's EE-10 error routing
and REQ-049's variable merge, an in-scope test-sequence demonstration closing AC8's own
previously-deferred obligation, and the REQ-031 injectable plugin-lookup adapter this
requirement's own text names as a missing dependency. Signatures and type shapes only — no
implementation code, no function bodies.

**Rework iteration 1 note:** CODE-DESIGN-VALIDATOR's FAIL identified two gaps in the first
version — AC8 (`docs/requirements.yaml`'s 8th acceptance criterion) was missing from this
document entirely, and §4.2's ETS table type (`:set`) contradicted §6.1's own reasoning (which
required `:bag`). §2.5 and §7.1 are new in this iteration, closing AC8 with a concrete, in-scope
demonstration mechanism; §4.2 is corrected to state `:bag`, matching §6.1. Everything else is
unchanged from the version CODE-DESIGN-VALIDATOR reviewed.

---

## 0. Sources read for this design, and an explicit access gap

- This run's handoff — full `context.requirement_text` (REQ-057, all bullets including the
  SCOPE BOUNDARY and OPEN QUESTION paragraphs) and `task.acceptance_criteria` — per
  `core-directives.md`'s "Load Scoped Context, Not Whole Files."
- `docs/agents/instructions/core-directives.md` (full).
- `docs/guides/backend_developer_guide.md` (full) — naming, error-shape, and self-review
  conventions this design's signatures follow.
- `docs/migration/stage-3-instance-engine.md` (full) — the two "Early findings" this run's own
  text points at directly: (1) "real per-state callbacks, real supervised isolation, not a
  `GenServer` simulating a state machine by hand"; (2) "[process value is] strongest
  specifically where this stage's actual scope lives: service task dispatch, **plugin
  registries**, and anything with expensive-to-reconstruct in-memory state" — plus its own later
  citation that "REQ-052 and REQ-057 additionally inherit REQ-040's crash-safety note: `try/after`
  does not cover a process exit" and its "Decisions" section naming "the plugin-registry storage
  mechanism (REQ-057)" as one of exactly two open design questions this stage flagged for
  possible escalation to a decision record.
- `docs/migration/decisions/` (listing) — `0001`-`0004`, `0006`. **None currently commits this
  project to `:persistent_term`/`GenServer`/ETS for a registry-shaped problem** — confirmed by
  `grep -rl "persistent_term\|GenServer\|ETS" docs/migration/decisions/`, which returned only
  `0002-oidc-integration.md` (a different, OIDC-provider-config concern, not a registry
  precedent). This design's own storage decision (§4) is therefore free to choose, not
  constrained by an existing record — and is written up with enough reasoning that if REVIEWER
  judges it stage-setting, it can be lifted into a `decisions/000x-*.md` record verbatim, per
  this stage doc's own "may escalate... if CODE-DESIGNER's resolution introduces a new
  dependency or a platform-wide rule" framing.
- `lib/letflow/design/req061-execution-error-handling.md` (full, 862 lines) — read in full,
  not paraphrased, since this design's own §7/§8 below wire directly into it. Confirmed
  directly: `Letflow.Engine.ExecutionError.error_type()` **already includes**
  `:plugin_error_outcome` in its 5-named-atom union (its own §2) — REQ-061's own CODE-DESIGNER
  anticipated this requirement's call site by name, so this design reuses that exact atom rather
  than inventing a new one. Also confirmed: `ExecutionError.append_multi/3`'s `error_args()`
  shape (`instance_id`, `error_type`, `affected`, `reason`, `variables`, `details`, `actor_id`,
  `idempotency_key`) and `Letflow.Engine.set_instance_error/2`'s standalone entry point (for a
  caller not already inside another function's open `Ecto.Multi`) — both reused unchanged by
  this design's §7. `REQ-061`'s own status is `done` (confirmed via `stage-3-instance-engine.md`
  §0's own requirements list) — this is a real, already-shipped dependency, not a forward one.
- `lib/letflow/design/req049-variable-merge.md` (full, 579 lines) — confirmed
  `Letflow.Engine.VariableMerge.merge/3`'s signature
  (`current_variables :: map(), incoming_variables :: map(), variable_validations :: ... | nil`)
  and its `merge_result()` union — this design's §8 states precisely how a plugin's `COMPLETE`
  output-variables map is exactly the shape `merge/3`'s `incoming_variables` parameter expects,
  with no adapter needed.
- `lib/letflow/design/req031-service-scope-validator.md` (full, 550 lines) — confirmed the real,
  already-shipped `Letflow.Definitions.ServiceScopeValidator.Lookup` struct and its
  `plugin_lookup_fun :: (plugin_handler :: String.t(), tenant_id :: Ecto.UUID.t() ->
  plugin_lookup_result())` type (`plugin_lookup_result :: {:ok, lookup_record()} | {:error,
  :not_registered}`, `lookup_record :: %{scope: scope(), owner_tenant_id: Ecto.UUID.t() | nil}`)
  — the exact injectable-callback shape this requirement's own text says was left unfulfilled
  ("this requirement should also wire REQ-031's injectable plugin-lookup callback to this real
  registry"). §5 below is this design's literal fulfillment of that gap, including the naming
  reconciliation it required (§5.1).
- `lib/letflow/definitions/graph.ex` (grepped, targeted read) — confirmed
  `Letflow.Definitions.Graph.node_type()`'s 8-atom union (`:START`, `:END`, `:HUMAN_TASK`,
  `:EXCLUSIVE_GATEWAY`, `:PARALLEL_GATEWAY`, `:SERVICE_TASK`, `:TIMER`, `:SUB_PROCESS`) and
  `@node_type_map`'s string→atom translation (an unrecognized string maps to
  `:unknown_node_type`).
- `lib/letflow/engine/transition.ex` (targeted read, lines 218–268) — confirmed directly, not
  assumed: `dispatch_node/4` has **real** dispatch clauses for exactly `:START`, `:END`,
  `:HUMAN_TASK`, `:EXCLUSIVE_GATEWAY`, `:PARALLEL_GATEWAY` (5 of the 8 node types); the other 3
  (`:SERVICE_TASK`, `:TIMER`, `:SUB_PROCESS`) plus any unrecognized type fall through one
  catch-all clause returning `{:error, {:node_type_not_yet_implemented, node_type, node_id}}`.
  **Load-bearing for §6**: `:SERVICE_TASK` has **no real built-in handler today** — a plugin
  registered for `:SERVICE_TASK` is not "shadowing" anything yet, it is the *first* real handler
  for that type. AC6's shadowing demonstration therefore needs a node type from the 5-member
  implemented set (e.g. `:HUMAN_TASK`), not `:SERVICE_TASK`, to actually exercise "an existing
  built-in gets shadowed" rather than "a previously-unimplemented type gets its first handler."
  Both are legitimate `resolve_node_handler_kind/1` outcomes (§6), but only the first is AC6's
  literal scenario.
- `lib/letflow/sandbox_pool.ex` (targeted read, `Process.monitor`/`handle_info({:DOWN, ...})`
  sections) — the codebase's own existing "GenServer owns a monitor, observes a linked/monitored
  process's abnormal exit via a `:DOWN` message rather than a `try/rescue`" precedent, cited
  directly by this design's §3 crash-safety mechanism (a different primitive — `Task.Supervisor`
  + `Task.yield/2`, not a bare `Process.monitor`/`handle_info` — but the same underlying
  principle: **observe an exit via a monitor-based signal, not a `rescue` clause**, since
  `SandboxPool`'s own moduledoc and `definitions.ex`'s promotion-assertion-rerun moduledoc (§0
  next item) both independently confirm `try/rescue` alone does not see a process exit).
- `lib/letflow/definitions.ex` (targeted read, lines 55–80) — confirmed the exact prose this
  run's own text points at ("the same gap REQ-040 already documented for sandbox teardown"):
  *"Crash safety: the claim → load-fixtures → replay → release → record-outcome span is wrapped
  in a single `try/rescue`. This covers three exit classes — normal completion, a typed error
  return... and a raised exception... It does **not** cover a hard process kill
  (`Process.exit(pid, :kill)`), a BEAM node crash, or `System.halt/0` — none of these run a
  `rescue` clause."* This design's §3 crash-safety wrapper is built specifically so this
  requirement's own handler-crash case (AC3) is **not** left in that same gap — see §3.3's
  explicit statement of exactly what this design's mechanism does and does not cover, matching
  the disclosure discipline that precedent set.
- `lib/letflow/application.ex` (full, 45 lines) — confirmed the current supervision tree
  (`Letflow.Repo`, migrator, OIDC provider worker, `Letflow.Registry`, `Letflow.InstanceSupervisor`,
  `Letflow.SandboxPool`, HTTP) — this design's §4 adds two new children here, following
  `Letflow.SandboxPool`'s own "named singleton `GenServer`, started once, unrelated to the
  per-instance `DynamicSupervisor`" precedent directly.
- `lib/letflow/instance_supervisor.ex` (full, 27 lines) — confirmed this is a `DynamicSupervisor`
  reserved for **per-process-instance** children (currently empty, "reserved for whichever of
  REQ-056/REQ-057 needs a supervised process"). **This design does not use it** — see §4.2's
  explicit reasoning for why a plugin registry (one global, non-per-instance singleton) does not
  belong under a *dynamic, per-instance* supervisor, even though this stage's own text cites
  REQ-057 as a candidate for "a supervised process."
- `docs/anti-patterns.md` (current entries) — no entry bears directly on this module's own
  construction.

PROVENANCE (historical, not current decision authority):
**Access gap at time of writing — since resolved for OQ-2 (GH#327, ISS-0099):** this environment
had no `R-Co/src/engine/plugin_interface.zig`, `R-Co/src/engine/plugin_registry.zig`, or
`R-Co/src/design/engine.md` reachable — confirmed via `find / -iname "plugin_*.zig"` and
`find / -maxdepth 4 -iname "R-Co*"`, both returning no match, the same negative result every
other S3 design in this repository (`req049`, `req052`, `req061`) already recorded. This design
was therefore built from this run's own `context.requirement_text` (which already summarizes
`plugin_interface.zig`'s 79-line handler contract and `plugin_registry.zig`'s 232-line
registration/resolution table) plus the shipped-code precedent above — not verified at the time
against either `.zig` file's literal source. The tree is reachable in the current environment
(`c:\Users\tvolo\dev\ai-dala\R-Co`); §3.2's `handler_key` reconciliation (OQ-2) has since been
read directly against it and confirmed — see §3.2 and §10 OQ-2. §10's remaining open questions
(OQ-1, OQ-4, OQ-6) are unaffected and still flagged.

---

## 1. Scope boundary (restated from the handoff, made concrete)

**In scope:** the handler *contract* (the behaviour + execution context + crash-safety
invocation wrapper + the pure `build_error_args/3` mapper, §2–§3) and the
registration/freeze/resolution *table* (§4–§6) — i.e., the two R-Co files this requirement
names, ported as their stable interface, nothing more. **Also in scope, and not the same thing
as the row below:** AC8's own routing demonstration (§7.1) — calling `invoke/2` →
`build_error_args/3` → the real, already-shipped `set_instance_error/2` in a test, proving this
requirement's own code has no independent ERROR-write path. This does **not** require the
node-dispatch wiring the next row excludes; `set_instance_error/2` is a standalone entry point
that needs no live graph-node execution to call, §7.1 states precisely why.

**Explicitly NOT built here:**

| Not built here | Belongs to |
|---|---|
| The WASM plugin host that actually executes third-party plugin code (R-Co `src/wasm/`, 19 files) | **S5** (scripting-and-plugins) — needs its own build-vs-bind decision record first, per `docs/migration/stage-5-scripting-plugins.md` |
| Any wiring of `resolve_node_handler_kind/1` / `resolve_plugin_handler_for_tenant/2` / `PluginInterface.invoke/2,3` into the engine's actual node-dispatch path (i.e., the call site inside whatever function ends up executing a `:SERVICE_TASK` or plugin-claimed node at runtime) | Whichever future requirement builds runtime plugin-node/service-task dispatch (most plausibly REQ-056, "service task dispatch", not yet built — `pending` per `stage-3-instance-engine.md`'s own status list, §0) |
| Any real, third-party-authored plugin module | N/A — this requirement supports **only** in-process Elixir modules implementing `Letflow.Engine.PluginInterface` directly; there is no dynamic code-loading, no WASM sandboxing, no network-fetched plugin of any kind in S3's scope |
| A real `ServiceCatalog`/full plugin-execution runtime for REQ-031's own SVC-03 validator | Still S6/S3-runtime as `req031`'s own design already scoped it — this requirement supplies the **registry itself** (§5), closing exactly the gap `req031`'s moduledoc named, but does not touch `definitions.ex`/`graph.ex` at all |

**In-process Elixir modules implementing the `PluginInterface` behaviour are the only handlers
S3 supports.** No handler is ever loaded, compiled, or fetched at runtime — every handler module
must already be compiled into the running release, matching AC4/"startup-only, no dynamic
loading."

---

## 2. `Letflow.Engine.PluginInterface` — the behaviour and execution context

### 2.1 File

`lib/letflow/engine/plugin_interface.ex` — `Letflow.Engine.PluginInterface`, following the
codebase's own `lib/letflow/engine/*.ex` one-concern-per-file convention (`variable_merge.ex`,
`transition.ex`, `execution_error.ex`).

### 2.2 `ExecutionContext` — the context every handler receives

```
defmodule Letflow.Engine.PluginInterface.ExecutionContext do
  @enforce_keys [:instance_id, :definition_id, :node_id, :node_type, :variables, :node_config,
                 :trace_id]
  defstruct [:instance_id, :definition_id, :node_id, :node_type, :variables, :node_config,
             :trace_id]

  @type t :: %__MODULE__{
    instance_id: Ecto.UUID.t(),
    definition_id: Ecto.UUID.t(),
    node_id: String.t(),
    node_type: String.t(),
    variables: map(),
    node_config: map(),
    trace_id: String.t()
  }
end
```

Field-by-field, matching this run's own text's list exactly:

- `instance_id` / `definition_id` — the running instance and its definition, `Ecto.UUID.t()`
  strings (matching every other REQ-04x/05x/06x context-module convention already established).
- `node_id` — the specific graph node this invocation is executing, `Graph.Node.id`'s own type.
- `node_type` — **`String.t()`, not `Graph.node_type()`'s atom union** — deliberately, so the
  same value a caller reads off `node.attributes`/the raw definition JSON can be threaded through
  unchanged, and so this struct never needs a dependency on `Graph`'s atom-mapping module. A
  future dispatch-integration caller (out of scope here, §1) converts `Graph.Node.node_type()`
  to its string form (`to_string/1`) when building this struct — this design's own choice,
  flagged at §10 OQ-2 alongside the related `PluginRegistry` key-typing decision (§5.1), since
  both stem from the same reconciliation.
- `variables` — the instance's variable map **as it stood immediately before this handler
  call** (`InstanceState.variables`, REQ-044) — `map()`, matching `VariableMerge.merge/3`'s own
  `current_variables` type exactly, so a future caller passes it through unchanged.
- `node_config` — the node's own `attributes` map (`Graph.Node.attributes`, REQ-028/029) —
  `map()`, matching the codebase's established "verbatim, unvalidated, string-keyed" convention
  for that field (confirmed by `req031`'s own §0 read of `graph_struct_from_map/1`).
- `trace_id` — a caller-supplied correlation identifier (`String.t()`) for cross-system tracing
  of one logical execution; this module neither generates nor validates it, only carries it
  through to the handler and, on an error outcome, into `ExecutionError`'s `details` (§7).

### 2.3 The `@callback` — the stable handler type

```
@type outcome :: {:complete, output_variables :: map()} | {:error, reason :: String.t()}

@callback handle_node(context :: ExecutionContext.t()) :: outcome()
```

PROVENANCE (historical, not current decision authority):
**Mapping note (required moduledoc content, per this run's own text — "note that mapping in the
moduledoc"):** R-Co's `plugin_interface.zig` expresses a handler as a function-pointer union
type (a C-ABI-shaped tagged union distinguishing a `COMPLETE`/`ERROR` result at the type level).
The idiomatic BEAM equivalent used here is a `@behaviour` with one `@callback` returning a plain
two-member tagged tuple — Elixir has no function-pointer/union-type primitive, so a behaviour
callback (dispatched via `apply/3`, resolved to a concrete implementing module by the caller,
§6) is the closest structural analogue: exactly one required entry point, exactly one of two
possible tagged outcomes, no third "did not respond" state representable at the type level
(that third state — crash/timeout — is handled entirely outside the type system, by §3's
invocation wrapper, never by adding a third tuple member to `outcome()`).

`output_variables` — a plain `map()`, the shape `VariableMerge.merge/3`'s `incoming_variables`
parameter already expects verbatim (§8). `reason` — a human-readable `String.t()`, the shape
`ExecutionError.error_args().reason` already expects verbatim (§7) — a handler author writes one
string, no structured error code is required by this contract (a handler MAY encode more detail
into the string; this behaviour does not define a machine-parsable sub-format).

### 2.4 `invoke/2,3` — the crash-safety wrapper (AC3, EXT-03 AC3)

```
@type invoke_opts :: [timeout_ms: pos_integer()]

@spec invoke(handler :: module(), context :: ExecutionContext.t()) :: outcome()
@spec invoke(handler :: module(), context :: ExecutionContext.t(), opts :: invoke_opts()) ::
        outcome()
```

**This is the single function every future dispatch call site (§1's named out-of-scope future
caller) must use to call a handler — never `handler.handle_node(context)` directly.** Its own
contract: `invoke/2,3` **always** returns `outcome()` — `{:complete, _}` or `{:error, _}` — and
**never** raises, never exits, never times out silently. A handler returning `{:error, reason}`
on purpose, a handler that `raise`s, a handler that calls `exit/1` (or is itself killed for any
reason), and a handler that simply never returns within `opts[:timeout_ms]` are all folded into
the same `{:error, reason}` shape by this function — `reason` differs (the handler's own string
vs. this wrapper's own generated description of what went wrong) but the **outcome tag** never
does. This is the concrete design element behind this run's own AC3 requirement that a raise and
an exit are "BOTH treated as ERROR outcomes rather than propagating."

**Why a bare `try/rescue` is insufficient — stated per this run's own explicit instruction not
to silently assume it is enough (§0's `req040`/`definitions.ex` citation):** `try/rescue` catches
a `raise` (an exception) but has no clause that observes a linked/monitored process's abnormal
`exit` — `rescue` runs inside the *same* process as the code that raised; an `exit/1` call, or an
external `Process.exit(pid, reason)`, terminates the *calling* process (or, if the handler runs
in a separate process, propagates via linking unless that link is deliberately absent) without
ever running a `rescue` clause in the caller. The mechanism below is chosen specifically because
it observes exit **as a message**, not by hoping a `rescue` clause runs.

### 2.4.1 Algorithm, described (not implemented)

1. Start the handler call as a **supervised, unlinked** task:
   `Task.Supervisor.async_nolink(Letflow.Engine.PluginTaskSupervisor, fn -> handler.handle_node(context) end)`
   — `async_nolink/2` deliberately does **not** link the new task process to the caller (unlike
   plain `Task.async/1`), so a handler crash cannot propagate an `:EXIT` signal into the caller's
   own process at all; it is supervised by a dedicated `Task.Supervisor` (§4.3) purely so an
   orphaned task (caller crashes first) is still cleaned up, not left running.
2. `Task.yield(task, opts[:timeout_ms] || @default_timeout_ms)` — internally monitors the task
   process and blocks the caller until either the task returns a value, the task process exits
   (any reason — normal `raise`-turned-exit, an explicit `exit/1` call, or a kill), or the
   timeout elapses. This is the load-bearing call: `Task.yield/2`'s own contract is that it
   observes the monitored process's actual termination, the same class of signal
   `SandboxPool`'s own `handle_info({:DOWN, ...})` (§0) observes for a different purpose — not a
   `rescue` clause.
3. **Branch on `Task.yield/2`'s return:**
   - `{:ok, {:complete, output_variables}}` when `is_map(output_variables)` → return
     `{:complete, output_variables}` unchanged (the handler's own success outcome, AC1).
   - `{:ok, {:error, reason}}` when `is_binary(reason)` → return `{:error, reason}` unchanged
     (the handler's own deliberate error outcome, AC2 — `reason` preserved byte-for-byte, per
     this run's own "the handler's reason string preserved in the EXECUTION_ERROR event").
   - `{:ok, other}` (any value not matching `outcome()`'s two shapes — a handler that violates
     its own `@callback` contract, e.g. returns `:ok` or a 3-tuple) → return
     `{:error, "plugin handler <handler> returned a value outside its outcome() contract: "
     <> inspect(other)}` — a **defensive** branch, not one of this run's own named ACs, added
     because `outcome()` is not statically enforced across an `apply/3`-style behaviour
     dispatch (§10 OQ-3 flags this as a design addition, not silently smuggled in as if the
     requirement asked for it).
   - `{:exit, reason}` → return `{:error, "plugin handler <handler> crashed: " <>
     format_exit_reason(reason)}` — **this is the branch that covers both `raise` and `exit`**
     (AC3): `Task`'s own documented behavior converts an uncaught exception inside the task
     function into an `:exit` with a `{exception, stacktrace}`-shaped reason, and an explicit
     `exit(reason)` call inside the task function surfaces here with that literal `reason` — both
     arrive through the **same** `{:exit, reason}` tuple, which is exactly why one function
     (this one) can present a single, uniform `{:error, _}` outcome to its own caller regardless
     of which of the two crash shapes actually happened, without needing two different-looking
     branches the caller would have to reconcile itself.
   - `nil` (the task neither returned nor exited within `opts[:timeout_ms]`) →
     `Task.shutdown(task, :brutal_kill)` (release the still-running task's resources, matching
     `Task.yield/2`'s own documented "you are responsible for shutting down the task if it
     didn't reply" contract), then return `{:error, "plugin handler <handler> did not respond
     within #{timeout_ms}ms"}` — a timeout is folded into the same `{:error, _}` outcome shape
     too, not a third tag, matching AC3's own framing that ERROR is the uniform non-COMPLETE
     outcome.
4. `format_exit_reason/1` (a small private helper, not part of the public contract) renders a
   `{exception, stacktrace}` reason as `Exception.format/3`-style text, and any other exit reason
   (an atom, a term from an explicit `exit/1` call) via `inspect/1` — described here only so
   ELIXIR-DEV knows a raw, unreadable term is never embedded verbatim into the persisted
   `EXECUTION_ERROR` event's `reason` string (§7).

### 2.4.2 What this mechanism does and does not cover (disclosed, matching `req040`'s own precedent)

**Covers:** a handler's own deliberate `{:error, _}` return, an uncaught `raise` anywhere in the
handler's call graph, an explicit `exit/1` call, a handler process being sent `Process.exit(pid,
:kill)` by something else, and a handler that simply hangs past `opts[:timeout_ms]`. All five
surface as `{:error, reason}` from `invoke/2,3` — never as an exception or exit propagating into
the caller.

**Does NOT cover, disclosed rather than silently assumed:** a hard kill of the **BEAM node
itself**, or `System.halt/0` — no monitor, task, or supervisor observes either from inside the
same node (the same residual class `req040`'s own moduledoc discloses for sandbox teardown,
§0). This is an accepted, stated limitation, not a gap this design papers over — a plugin
invocation caught mid-flight by a node crash leaves whatever transaction state existed before
the call (this function itself performs zero `Repo`/`EventStore` I/O, §2.4.3) exactly as robust
or fragile as any other in-flight BEAM computation at the moment of a node crash, which is an
existing, platform-wide property this one function cannot change.

### 2.4.3 `invoke/2,3` is I/O-free with respect to Letflow's own persistence layer

`Letflow.Engine.PluginInterface` (both the behaviour and `invoke/2,3`) makes **no** `Letflow.Repo`
call, no `Letflow.EventStore.append/2` call, and opens no `Ecto.Multi`/transaction of its own —
it is a pure dispatch-and-observe mechanism over whatever the handler itself does (a handler MAY
perform its own I/O inside `handle_node/1`, entirely outside this module's visibility; that I/O
is the handler author's own responsibility and is not this module's concern to sandbox, since the
handler is by definition an in-process Elixir module, not untrusted WASM, §1). Persisting the
outcome (a merge on `{:complete, _}`, an `EXECUTION_ERROR` append on `{:error, _}`) is the
future dispatch-integration caller's own job (§7, §8) — matching `TaskActivation`/`ExecutionError`'s
own "zero `Repo` calls of its own" convention (`req061` §0's own citation of that pattern).

### 2.5 `build_error_args/3` — the pure `outcome() → ExecutionError.error_args()` mapper (AC8)

```
@type error_meta :: %{
        required(:actor_id) => Ecto.UUID.t() | nil,
        required(:idempotency_key) => String.t()
      }

@spec build_error_args(
        context :: ExecutionContext.t(),
        reason :: String.t(),
        meta :: error_meta()
      ) :: Letflow.Engine.ExecutionError.error_args()
```

**This is §7's `error_args` construction (previously stated only as prose there), promoted to a
real, named, in-scope function this requirement itself builds and ships** — added specifically
to close AC8 (§7.1), not merely to restate §7. A pure function, no `Repo`/`EventStore` call
(matching §2.4.3's own bar): given the `ExecutionContext` a handler was invoked with, the
`reason` string `invoke/2,3` returned on an `{:error, reason}` outcome, and the caller's own
`actor_id`/`idempotency_key`, it returns exactly the `error_args()` map §7 already specifies —
`error_type: :plugin_error_outcome`, `affected: {:node, context.node_id}`, `reason` unchanged,
`variables: context.variables`, `details: %{node_type: context.node_type, trace_id:
context.trace_id}` — with no other logic. Its own existence is what makes AC8's "demonstrated by
inspection" half checkable: a reviewer can read `build_error_args/3`'s body and confirm it is the
**only** place this requirement constructs an `ExecutionError.error_args()` value, and that no
other function anywhere in `PluginInterface`/`PluginRegistry` writes `instance_projections.status`
or appends an event directly — i.e., this requirement genuinely has no ERROR-transition logic of
its own outside what routes into REQ-061's shared sink.

---

## 3. `Letflow.Engine.PluginRegistry` — types

### 3.1 File

`lib/letflow/engine/plugin_registry.ex` — `Letflow.Engine.PluginRegistry`.

### 3.2 Scope and key type — the REQ-031 reconciliation, stated explicitly (§10 OQ-2)

PROVENANCE (historical, not current decision authority):
This run's own text asks this registry to be keyed by "node_type" (registration rejects "a
duplicate node_type, an invalid node_type"; `resolve_node_handler_kind` operates on node types)
**and** to wire in REQ-031's already-shipped `plugin_lookup_fun :: (plugin_handler :: String.t(),
tenant_id :: Ecto.UUID.t() -> plugin_lookup_result())` (§0) — whose first argument is named
`plugin_handler`, a plugin **identifier** string, not literally `Graph.node_type()`'s 8-atom
enum. **This design's own reconciliation, not silently guessed either way:** the registry's
single key type is `handler_key :: String.t()` — an open string, not restricted to
`Graph.node_type()`'s atom union — and the *same* key namespace serves both roles this
requirement names: it is what a caller passes to `resolve_node_handler_kind/1` /
`resolve_plugin_handler_for_tenant/2` (naming it "node_type" throughout, matching this
requirement's own vocabulary and `plugin_registry.zig`'s own field name) **and** it is exactly
the string a `SERVICE_TASK` node's `attributes["plugin_handler"]` value would hold and REQ-031's
`Lookup.plugin_lookup` would be called with — one namespace, two names for the same thing
depending on which requirement's vocabulary is talking about it. §5.3 states the adapter that
makes this literal, not merely analogous.

PROVENANCE (historical, not current decision authority):
**Confirmed against R-Co source (GH#327, ISS-0099, resolves OQ-2):**
`R-Co/src/engine/plugin_registry.zig` was read directly. `RegisterPluginHandlerInput.node_type`
and `PluginRegistration.node_type` (L23–41) are both typed `[]const u8` — Zig's string-slice
type, i.e. an **open string**, not a fixed enum of node kinds; `PluginRegistry.entries` is
`std.StringHashMap(PluginRegistration)` (L51), keyed by that same raw string. R-Co's own
`registerPluginHandler/3` (L88–131) validates only that the string is non-empty
(`input.node_type.len == 0` → `error.InvalidNodeType`, L94) — no membership check against any
closed set of node-type values exists in R-Co. `R-Co/src/design/ext-03-plugin-interface.md`
(L31, L63, L129, L213) uses the identical `node_type: []const u8` shape throughout. This
settles the reconciliation this design made without being able to check it: `handler_key ::
String.t()` (open, not `Graph.node_type()`'s 8-atom union) is exactly R-Co's own shape, not a
departure from it. The two-separate-registries alternative this design considered and rejected
(§10 OQ-2) is confirmed wrong — R-Co has exactly one registry, one open-string key namespace,
matching this design's choice. No change to this design's types or algorithm was needed; §10
OQ-2 is now closed.

```
@type scope :: :global | :tenant

@type registration :: %{
  handler_key: String.t(),
  handler: module(),
  scope: scope(),
  owner_tenant_id: Ecto.UUID.t() | nil,
  api_version: pos_integer(),
  registered_at: DateTime.t()
}
```

`owner_tenant_id` is `nil` **iff** `scope == :global` (SVC-02, enforced at registration time,
§6). `api_version` — see §6's `incompatible_api_version` check; this design's own choice for
what "the registry's currently supported API version" means is stated at §10 OQ-4.

### 3.3 Registration attrs and the registration-error union

```
@type registration_attrs :: %{
  required(:handler_key) => String.t(),
  required(:handler) => module() | nil,
  required(:scope) => scope() | term(),
  optional(:owner_tenant_id) => Ecto.UUID.t() | nil,
  optional(:api_version) => pos_integer()
}

@type registration_error ::
        {:error, :registry_frozen}
      | {:error, :nil_handler}
      | {:error, :invalid_node_type}
      | {:error, :incompatible_api_version}
      | {:error, :tenant_scoped_plugin_requires_owner_id}
      | {:error, :global_plugin_must_not_have_owner_id}
      | {:error, :duplicate_node_type}
```

PROVENANCE (historical, not current decision authority):
**Seven distinct, pattern-matchable errors** — the five this run's own text names for
`register_plugin_handler/1` itself (`duplicate_node_type`, `invalid_node_type`, `nil_handler`,
`incompatible_api_version`, `registry_frozen`) plus the two SVC-02 scoping errors this run's own
text separately names (`tenant_scoped_plugin_requires_owner_id`,
`global_plugin_must_not_have_owner_id`) — all seven live in the **same** union so a caller
pattern-matches on `register_plugin_handler/1`'s return with one `case`, not two.

**Error names deliberately mirror `plugin_registry.zig`'s own `PluginRegistrationError` set's
naming, per this run's own text ("matching plugin_registry.zig's PluginRegistrationError set")**
— `:tenant_scoped_plugin_requires_owner_id` / `:global_plugin_must_not_have_owner_id` read as
direct Elixir-cased translations of the `.zig` identifiers this run's own text quotes verbatim
(`TenantScopedPluginRequiresOwnerId` / `GlobalPluginMustNotHaveOwnerId`) — not independently
invented names.

---

## 4. Registry storage mechanism — the decision this design must make (resolving the handoff's own open tension)

### 4.1 The tension, restated precisely

The handoff names two readings that point different ways and explicitly declines to pre-decide
between them:

1. R-Co's own shape (a process-local struct + a global singleton,
   `registerGlobalPluginHandler`/`resolveGlobalPluginHandler`) plus "a frozen, startup-populated,
   read-mostly lookup table is a textbook fit for `:persistent_term` or a compile-time module."
2. `stage-3-instance-engine.md`'s own second Early finding naming "service task dispatch, plugin
   registries" as exactly where a supervised process's value is strongest.

### 4.2 This design's decision: a supervised `GenServer` that owns a private ETS table, with reads bypassing the process entirely

**Concretely:** `Letflow.Engine.PluginRegistry` is a `GenServer`, started once as a named
singleton child of `Letflow.Supervisor` (`lib/letflow/application.ex`, §4.4) — matching
`Letflow.SandboxPool`'s own precedent exactly (a single, always-running, supervised process; not
a per-instance `DynamicSupervisor` child, §4.5). In `init/1` it creates a **private** ETS table
it alone owns (`:ets.new(..., [:bag, :protected, :named_table, read_concurrency: true])`) —
**`:bag`, not `:set`, required** so multiple co-existing registrations under one `handler_key`
(a `:global` registration plus one or more `:tenant`-scoped registrations for different owners,
§5.2/§6.1 step 7's own reasoning) are each independently retrievable by one
`:ets.lookup(@table, handler_key)`; a `:set` table would silently let a later insert under the
same `handler_key` overwrite an earlier one, which would break AC5's "both a tenant-scoped and a
global registration under the same node_type coexist and resolve independently" requirement.
`register_plugin_handler/1` and `freeze_plugin_registry/1` are ordinary `GenServer.call/2`
requests (serialized writes — registration only happens at startup, low volume, correctness over
throughput). `resolve_node_handler_kind/1` and `resolve_plugin_handler_for_tenant/2` — the
**hot, read-mostly path** any future runtime dispatch call site (§1) would call on every
plugin-eligible node execution — perform a **direct `:ets.lookup/2` call from the caller's own
process**, never a `GenServer.call/2`, using the table's `:protected` access mode (readable by
any process, writable only by the owning `GenServer`).

**Why this satisfies both readings at once, rather than picking one and ignoring the other:**

- **It IS a supervised process** (finding 2): registered under `Letflow.Supervisor`'s ordinary
  `:one_for_one` strategy, restarted on crash like every other top-level singleton in this
  codebase (`Letflow.SandboxPool`, the OIDC provider worker), giving the registry the same
  "real, correctly-supervised OTP" bar `stage-3-instance-engine.md`'s own first Early finding
  requires — not a bare `:persistent_term` write with no supervision tree entry at all, no crash
  visibility, and no restart semantics if something ever needs to re-seed it.
- **Reads are exactly as cheap as `:persistent_term`'s own "textbook fit" case for a frozen,
  read-mostly table** (finding 1): once `freeze_plugin_registry/1` returns, every subsequent
  `resolve_*` call is a **direct ETS read** in the calling process — no message send, no
  `GenServer` mailbox contention, no serialization through one process for a hot path that
  (post-freeze) never writes again. `:ets.lookup/2` on a `:protected`, `read_concurrency: true`
  table is the same order of read cost `:persistent_term` offers for this exact "read very often,
  write essentially never" shape.
- **`:persistent_term` was considered and rejected, not merely not chosen:** every
  `:persistent_term.put/2` triggers a full sweep of every process's `Process.info(:message_queue_len)`-adjacent
  global term table (a documented, VM-wide cost proportional to the number of processes,
  regardless of how small the written term is) — acceptable for a genuinely one-time write at
  boot, but this design's own registration flow (§6, one `put`-equivalent write per registered
  handler, potentially several handlers per boot, §6.4) would pay that VM-wide sweep cost once
  per handler rather than once per boot. An ETS table sidesteps this entirely: writes during the
  registration phase are ordinary `:ets.insert/2` calls inside the owning `GenServer`, no
  VM-wide cost at all, and the *read* side is exactly as cheap once frozen.
- **A compile-time module (the third reading's option) was also considered and rejected:**
  registration attrs include `handler: module()` values resolved from runtime configuration
  (§6.4's `Application.get_env/2`-sourced seed list) — a compile-time module would require every
  registered handler to be known at `mix compile` time, contradicting AC4/this run's own
  "startup-only, no dynamic loading **at runtime**" framing, which still permits — indeed
  requires — the seed list itself to be read once at *boot*, not baked into source.

This is this design's own reasoned decision, citing the stage doc's own finding by name as
instructed rather than silently picking a mechanism — **flagged for REVIEWER at Step 2d to
confirm, and a candidate for promotion to a `docs/migration/decisions/000x-*.md` record** per
`stage-3-instance-engine.md`'s own "may escalate... if CODE-DESIGNER's resolution introduces a
new dependency or a platform-wide rule" framing (§10 OQ-1 restates this as an explicit open
item for ORCH/REVIEWER to decide whether to escalate).

### 4.3 The `Task.Supervisor` for `PluginInterface.invoke/2,3`

A second, small new child: `{Task.Supervisor, name: Letflow.Engine.PluginTaskSupervisor}` —
required by §2.4.1 step 1's `Task.Supervisor.async_nolink/2` call. This is a standard-library
supervisor (no new file, no new module — `Task.Supervisor` itself), started once, supervising
every in-flight plugin-handler invocation across the whole node. A handler task that outlives its
own `invoke/2,3` caller (the caller crashed before `Task.shutdown/2` ran) is still owned and
eventually reaped by this supervisor rather than becoming an orphan — the same "supervised
isolation, not a bare unsupervised spawn" bar the stage's own first Early finding sets.

### 4.4 `lib/letflow/application.ex` — the two lines this design adds

```
children =
  [
    Letflow.Repo,
    {Ecto.Migrator, ...},
    {Oidcc.ProviderConfiguration.Worker, ...},
    {Registry, keys: :unique, name: Letflow.Registry},
    Letflow.InstanceSupervisor,
    {Letflow.SandboxPool, []},
    {Task.Supervisor, name: Letflow.Engine.PluginTaskSupervisor},          # new
    {Letflow.Engine.PluginRegistry, plugin_registrations_from_config()}    # new
  ] ++ http_child()
```

`Letflow.Engine.PluginRegistry`'s `start_link/1` receives the full seed list of
`registration_attrs()` to register at boot (§6.4) — the mechanism by which "startup-only, no
dynamic loading" (AC4) is an actual operational property, not merely a docstring claim: nothing
in this design exposes a way to call `register_plugin_handler/1` from outside the boot sequence
except by an application module explicitly choosing to (§6.4 flags this as a soft, not hard,
enforcement boundary — §10 OQ-5).

### 4.5 Why not `Letflow.InstanceSupervisor`

`Letflow.InstanceSupervisor` (§0) is a `DynamicSupervisor` — its whole purpose is starting and
stopping **one child per running process instance**, dynamically, over the instance's lifetime.
`Letflow.Engine.PluginRegistry` is the opposite shape: exactly one process, for the whole node's
lifetime, holding no per-instance state whatsoever. Placing a singleton registry under a
`DynamicSupervisor` designed for per-instance children would be a category mismatch — this
design instead follows `Letflow.SandboxPool`'s own precedent (a plain, named, top-level
`GenServer` child of `Letflow.Supervisor` itself), not `Letflow.InstanceSupervisor`'s. The stage
doc's own citation of REQ-057 as a "supervised process" candidate is read here as "REQ-057's own
state deserves real OTP supervision" (satisfied by §4.2), not as "REQ-057's process must live
under `InstanceSupervisor` specifically" (that supervisor's own moduledoc, §0, frames its
reservation for REQ-056/057 generically, without mandating which of the two — or whether either
— actually uses it; this design states explicitly that REQ-057's registry does not).

---

## 5. `resolve_node_handler_kind/1` and `resolve_plugin_handler_for_tenant/2` — resolution

### 5.1 `resolve_node_handler_kind/1` — precedence/shadowing (AC6, EXT-03 edge case)

```
@spec resolve_node_handler_kind(handler_key :: String.t()) :: :builtin | :plugin
```

**Deliberately built-in-agnostic — this function does not know or care which node types
`Letflow.Engine.Transition` actually implements today (§0's confirmed 5-of-8 set).** Its own
rule is exactly this run's own text, read literally: "a plugin registered for a node_type that
also has a built-in handler takes PRECEDENCE" — restated by this design as "**any** registration
under `handler_key`, in **any** scope, makes this function return `:plugin`; **no** registration
under `handler_key` makes it return `:builtin`." Whether `:builtin` for that particular
`handler_key` actually means "`Transition.dispatch_node/4` has a real clause for it" or "falls
through to `:node_type_not_yet_implemented`" is entirely `Transition`'s own business, invisible
to and untouched by this function — the future runtime dispatch caller (§1) is the one that
reads `:builtin` and decides what running the built-in path means. This keeps
`Letflow.Engine.PluginRegistry` fully decoupled from `Transition`'s own implemented-set, which
may grow (e.g. once `:SERVICE_TASK` gets a real built-in dispatch clause) without requiring any
change here.

**Implementation shape (described, not implemented):** `:ets.lookup(@table, handler_key)` —
`[]` → `:builtin`; any non-empty result (one or more registrations under that key, across
scopes) → `:plugin`. AC6's own demonstration: register a plugin under `"HUMAN_TASK"` (one of the
5 types `Transition` genuinely implements, §0) and assert `resolve_node_handler_kind("HUMAN_TASK")
== :plugin` — proving precedence over a **real** built-in, not merely over an
unimplemented-fallback type.

### 5.2 `resolve_plugin_handler_for_tenant/2` — SVC-02 scoping (AC5)

```
@spec resolve_plugin_handler_for_tenant(handler_key :: String.t(), tenant_id :: Ecto.UUID.t()) ::
        {:ok, registration()} | {:error, :not_registered}
```

PROVENANCE (historical, not current decision authority):
**Resolution order (this design's own explicit rule, since `plugin_registry.zig`'s literal
precedence is unverifiable, §10 OQ-1):**

1. A `:tenant`-scoped registration under `handler_key` whose `owner_tenant_id == tenant_id` —
   if present, return it (`{:ok, registration}`). Tenant-specific wins over global when both
   exist for the same `handler_key`, matching this run's own text's framing of tenant scoping as
   a narrowing, not merely an alternative.
2. Else, a `:global`-scoped registration under `handler_key` — if present, return it.
3. Else — no registration visible to this `tenant_id` under `handler_key` (either nothing is
   registered at all, or only a `:tenant`-scoped registration owned by a **different** tenant
   exists) — `{:error, :not_registered}`.

**AC5's own "resolution for tenant B does not return tenant A's tenant-scoped handler"** falls
directly out of step 1's exact-match requirement (`owner_tenant_id == tenant_id`) and step 3's
catch-all: tenant A's registration is never inspected as a candidate for tenant B's lookup at
all, and there is no fallback path from "found but owned by someone else" to "return it anyway."
**Implementation shape:** `:ets.lookup(@table, handler_key)` returns the (possibly multi-element,
one per scope/owner combination registered under that key) list of `registration()` maps for
that `handler_key`; this function filters/selects per the two-step order above entirely in the
caller's own process (no `GenServer.call/2`), matching §4.2's read-path design.

### 5.3 `as_plugin_lookup_fun/0` — the literal REQ-031 wiring (closes the named gap)

```
@spec as_plugin_lookup_fun() :: Letflow.Definitions.ServiceScopeValidator.plugin_lookup_fun()
```

Returns the 2-arity function value `req031`'s own `Lookup.plugin_lookup` field requires
(`(plugin_handler :: String.t(), tenant_id :: Ecto.UUID.t()) -> {:ok, %{scope: scope(),
owner_tenant_id: Ecto.UUID.t() | nil}} | {:error, :not_registered}`, §0) — built by calling
`resolve_plugin_handler_for_tenant(plugin_handler, tenant_id)` and, on `{:ok, registration}`,
projecting it down to exactly the two fields `req031`'s own `lookup_record()` type needs
(`%{scope: registration.scope, owner_tenant_id: registration.owner_tenant_id}}`) — dropping
`handler`, `api_version`, `registered_at`, none of which `req031`'s validator needs or should
see. `{:error, :not_registered}` passes through unchanged (the two error unions match exactly,
§0's confirmed `req031` type).

**This is this requirement's literal fulfillment of its own named obligation** ("this
requirement should also wire REQ-031's injectable plugin-lookup callback to this real
registry"). What this design does **not** do: it does not itself edit `definitions.ex` or any
`activate/2` call site to pass `Lookup.plugin_lookup: PluginRegistry.as_plugin_lookup_fun()` —
no such wiring call exists anywhere in the shipped codebase yet (`req031`'s own design confirms
`activate/2` has no current caller at all, since S4's route layer is not built, §0's `req031`
citation). `as_plugin_lookup_fun/0` is the value **ready** to be passed the moment some future
caller constructs a real `Lookup` — named here as the closed gap, not a still-open one, but the
act of actually threading it into a live `activate/2` call is deferred to whichever S4/S3-runtime
requirement first constructs a real `Lookup.service_lookup` too (a `ServiceCatalog` still does
not exist, per `req031`'s own §1 table — a `Lookup` needs both fields, `@enforce_keys`, §0).

---

## 6. `register_plugin_handler/1` and `freeze_plugin_registry/1` — algorithm

```
@spec register_plugin_handler(registration_attrs()) :: {:ok, registration()} | registration_error()

@type freeze_opts :: []
@spec freeze_plugin_registry(opts :: freeze_opts()) :: :ok | {:error, :already_frozen}
```

`freeze_plugin_registry/1` takes an (currently empty, `[]`-typed) `opts` list purely to match
this run's own text's literal `/1` arity — reserved for a future flag (e.g. a `force: true`
re-freeze-for-testing escape hatch) this design does not need and does not add speculatively.

### 6.1 `register_plugin_handler/1` — check order (this design's own explicit precedence, not left ambiguous)

A `GenServer.call/2` request, evaluated by the owning process in this exact order — stated
explicitly since a single call to `register_plugin_handler/1` could technically violate more
than one rule at once (e.g. a `nil` handler AND a duplicate key), and the caller needs a
deterministic single error, not an unspecified "whichever the implementation happens to check
first":

1. **`registry_frozen`** — is `state.frozen? == true`? If so, `{:error, :registry_frozen}`
   immediately, before inspecting `attrs` at all (AC4's "registration after the registry is
   frozen" — the cheapest, most fundamental rejection, checked first so every other error below
   is only ever returned pre-freeze).
2. **`nil_handler`** — `attrs.handler == nil` (or not a `module()`/atom at all) →
   `{:error, :nil_handler}`.
3. **`invalid_node_type`** — `attrs.handler_key` is not a non-empty `String.t()` (missing, `nil`,
   `""`, or non-binary) → `{:error, :invalid_node_type}`. **This design's own validity rule is
   structural only** (non-blank string), not a closed enum against `Graph.node_type()`'s 8 atoms
   — since §3.2 deliberately opens `handler_key` beyond that enum for the REQ-031 reconciliation,
   restricting it back to exactly 8 values here would silently re-close the very door §3.2 opens.
   Flagged at §10 OQ-2 alongside the rest of that reconciliation.
4. **Scope validity (SVC-02):**
   - `attrs.scope == :tenant` and `attrs.owner_tenant_id` is `nil`/absent →
     `{:error, :tenant_scoped_plugin_requires_owner_id}`.
   - `attrs.scope == :global` and `attrs.owner_tenant_id` is present (non-`nil`) →
     `{:error, :global_plugin_must_not_have_owner_id}`.
   - `attrs.scope` is neither `:global` nor `:tenant` → treated as `invalid_node_type`'s own
     sibling case, folded into `{:error, :invalid_node_type}` too (this design does not add an
     eighth error atom for "invalid scope value" — not one of the five/seven this run's own
     text names, and a malformed `scope` is exactly the same class of "caller supplied a
     structurally wrong attrs map" as a malformed `handler_key`).
5. **`incompatible_api_version`** — `attrs.api_version` (defaulting to `1` if omitted, §10 OQ-4)
   does not equal `Letflow.Engine.PluginRegistry.supported_api_version/0`'s own fixed value
   (a module attribute, `@supported_api_version 1`) → `{:error, :incompatible_api_version}`.
6. **`duplicate_node_type`** — a registration already exists under the **exact same** key triple
   `{handler_key, scope, owner_tenant_id}` (i.e., re-registering `"HUMAN_TASK"` as `:global` a
   second time is a duplicate; registering `"HUMAN_TASK"` as `:global` **and then** as `:tenant`
   for tenant A is **not** a duplicate — those are two legitimately co-existing registrations
   under one `handler_key`, resolved between by §5.2's own precedence rule) →
   `{:error, :duplicate_node_type}`. Checked last, since it is the only check requiring an ETS
   read against already-committed state, and every earlier check is a pure `attrs`-shape
   validation that should short-circuit first.
7. **On passing every check:** `:ets.insert(@table, {handler_key, registration})` (ETS `:set`
   tables permit multiple distinct keys but not two identical `{key, ...}` tuples under the same
   literal key — this design uses a **bag**-style table in practice, storing one ETS row per
   `{handler_key, scope, owner_tenant_id}` combination via a composite key or a `:bag` table
   type, so multiple co-existing registrations under one `handler_key` — global + several
   tenant-scoped — are all retrievable by a single `:ets.lookup(@table, handler_key)` when the
   table is declared `:bag` rather than `:set`; flagged here as an implementation-detail choice
   ELIXIR-DEV must apply, not left ambiguous: **use `:bag`, keyed by `handler_key` alone**, so
   step 6's duplicate check and §5's resolution both work against the same natural key). Returns
   `{:ok, registration}` with `registered_at: DateTime.utc_now()`.

### 6.2 `freeze_plugin_registry/1`

`GenServer.call/2` → if `state.frozen? == true` already, `{:error, :already_frozen}` (idempotent
re-freeze is rejected, not silently accepted, so a caller cannot mistake "I asked twice and both
said :ok" for "nothing changed the second time"); else sets `state.frozen? = true` and returns
`:ok`. **Irreversible for the lifetime of the running node** — no `unfreeze` function exists
anywhere in this module's public contract (AC4's "immutable" is total, not merely
default-on).

### 6.3 Post-freeze read guarantee

Once `freeze_plugin_registry/1` returns `:ok`, `resolve_node_handler_kind/1` and
`resolve_plugin_handler_for_tenant/2`'s own ETS reads (§5) observe a table that will **never**
change again for the life of the process — no torn reads, no read racing a concurrent write, are
possible from that point forward, since every write path (`register_plugin_handler/1`) itself
checks `state.frozen?` first (§6.1 step 1) and refuses before ever reaching `:ets.insert/2`.

### 6.4 Boot-time seeding (AC4's "startup-only" as an actual operational property)

`Letflow.Engine.PluginRegistry.start_link/1` receives, as its init argument, the full list of
`registration_attrs()` to seed — sourced by `lib/letflow/application.ex`'s
`plugin_registrations_from_config/0` (§4.4) from `Application.get_env(:letflow, :plugin_handlers,
[])`, i.e. ordinary `config/*.exs` (or `runtime.exs`) data, matching the codebase's existing
`Application.fetch_env!(:letflow, :oidc)`/`Application.get_env(:letflow, :start_http, true)`
convention (`application.ex`, §0). `init/1` calls `register_plugin_handler/1` once per seed
entry (each already unfrozen at that point) and then, once every seed entry is processed,
**calls `freeze_plugin_registry/1` on itself, automatically, before `init/1` returns** — so a
freshly-booted node's registry is frozen the instant the supervision tree finishes starting, with
no separate manual freeze step an operator or a later boot phase could forget to run. Any seed
entry that itself fails registration (a malformed config entry) causes `init/1` to return
`{:stop, {:invalid_plugin_registration, reason}}` — a misconfigured seed list fails the whole
node's boot loudly, rather than silently starting with a partially-seeded, already-frozen,
now-permanently-incomplete registry.

---

## 7. Wiring into REQ-061 — EE-10 error routing (AC2)

**Not this requirement's own call site** (§1) — this section states the exact shape a future
runtime dispatch caller (§1's named future requirement) must use, mirroring `req049`/`req050`'s
own §5 precedent inside `req061`'s design (§0's citation) exactly, so no ambiguity is left for
that future CODE-DESIGNER to invent independently.

On `PluginInterface.invoke/2,3` returning `{:error, reason}` (§2.4, covering a handler's own
deliberate `ERROR`, a raise, an exit, or a timeout — all indistinguishable from the caller's own
perspective, by design, §2.4.1 step 3), the caller calls `PluginInterface.build_error_args/3`
(§2.5):

```
error_args = PluginInterface.build_error_args(context, reason, %{actor_id: actor_id,
  idempotency_key: idempotency_key})
# => %{
#      instance_id: context.instance_id,
#      error_type: :plugin_error_outcome,  # already named in ExecutionError.error_type()'s union
#      affected: {:node, context.node_id},
#      reason: reason,                     # the exact string invoke/2,3 returned, byte-for-byte
#      variables: context.variables,       # the instance variable snapshot as of the call, AC2/AC1
#      details: %{node_type: context.node_type, trace_id: context.trace_id},
#      actor_id: actor_id,
#      idempotency_key: idempotency_key
#    }
```

then either `Letflow.Engine.set_instance_error/2` (a standalone call, if the plugin invocation
happens outside any other open `Ecto.Multi`) or `Letflow.Engine.ExecutionError.append_multi/3`
(if it happens inside one, e.g. as part of a larger `complete_task/3`-shaped transaction) —
**exactly the same two-shaped choice `req061` §4 already documents for every other future
caller**, not a new mechanism this design invents. `error_type: :plugin_error_outcome` reusing
`ExecutionError`'s own already-shipped atom (§0) means **zero changes to `ExecutionError` or
`execution_error.ex`** are required by this requirement — the shared sink already anticipated
this exact call site's name.

**AC2's "reason string preserved in the EXECUTION_ERROR event" is satisfied end-to-end:** §2.4's
`invoke/2,3` never truncates, re-wraps, or reformats a handler's own `{:error, reason}` string
(step 3's first `{:ok, {:error, reason}}` branch returns it unchanged); `build_error_args/3`
carries that same value unchanged into `error_args.reason`, which flows into `ExecutionError`'s
own `:execution_error_event` step (`req061` §9), which persists it verbatim in the
`EXECUTION_ERROR` event's `reason` field. No intermediate step in this chain rewrites it.

### 7.1 AC8 — demonstrating the routing NOW, inside REQ-057's own scope, not deferred a second time

**AC8, quoted in full:** *"a handler ERROR outcome is demonstrated routing into REQ-061's
set_instance_error rather than writing its own ERROR transition, confirmed by inspection and by
test — this closes REQ-061's own AC obligation, deferred forward because REQ-057 did not exist
when REQ-061 was built."* Unlike §1/§7's own "not this requirement's own call site" framing for
the *runtime node-dispatch* wiring (which genuinely does need a future requirement's
Transition/task-completion integration, §1), **AC8 does not require that integration to exist.**
It only requires a handler's `{:error, _}` outcome to be shown reaching `set_instance_error/2` —
and `set_instance_error/2` (`req061` §4) is already a standalone, self-contained entry point
requiring nothing beyond `instance_id` + the `error_args()` fields (§2.5): no live task, no
in-flight `Transition`/`complete_task/3` call, no node-dispatch wiring of any kind. That
independence is exactly what makes AC8 closeable **inside** this requirement, not merely a
promise about REQ-057's own future caller.

**The concrete demonstration mechanism this design commits to (a real, in-scope, non-speculative
call sequence — TEST-DESIGNER writes this as an ExUnit test, not a hypothetical):**

1. Start a real instance via the already-shipped `Letflow.Engine.create/2` (REQ-045) against any
   minimal valid definition — this instance is a genuine, `:active`, persisted
   `instance_projections` row, not a stub.
2. Define a test-fixture handler module implementing `PluginInterface` whose `handle_node/1`
   returns `{:error, "a deliberately deterministic reason string"}` (and, in the sibling AC3
   tests, one that `raise`s and one that `exit/1`s instead — §2.4's own outcomes, reused here).
3. Build an `ExecutionContext.t()` by hand, `instance_id` set to step 1's real instance
   (`node_id`/`node_type`/`node_config`/`trace_id` are test-fixture literals — nothing about them
   needs to correspond to a real graph node, since neither `invoke/2,3` nor `build_error_args/3`
   nor `set_instance_error/2` reads the graph at all).
4. `outcome = PluginInterface.invoke(FixtureHandler, context)` → asserts `{:error, reason}`
   (AC2/AC3's own assertions reused).
5. `error_args = PluginInterface.build_error_args(context, reason, %{actor_id: ..., idempotency_key: ...})`.
6. `Letflow.Engine.set_instance_error(error_args, [])` — a **real call into the real, already-shipped
   REQ-061 function**, not a hand-rolled write. Assert `{:ok, %{status: :error, error_type:
   :plugin_error_outcome, ...}}`.
7. Re-fetch the instance (`Letflow.Repo.get(InstanceProjection, instance_id)`) and assert
   `status == :error`; re-read the appended event and assert `event_type == "EXECUTION_ERROR"`
   and its payload's `reason` equals step 2's exact fixture string, verbatim.

**Why this satisfies AC8's own two-part bar:**

- **"Confirmed by inspection"** — `build_error_args/3` (§2.5) is the **only** function this
  requirement defines that constructs an `ExecutionError.error_args()` value, and neither
  `PluginInterface` nor `PluginRegistry` contains any other write to `instance_projections` or
  any other event append anywhere in this design (§2.4.3/§9's own "zero `Repo`/`EventStore` calls"
  invariant, INV-PR-8) — a reviewer reading this requirement's shipped code can directly confirm
  there is no second, ad-hoc ERROR-transition path a plugin outcome could take.
- **"Confirmed by test"** — step 6 above is a **real** call to `Letflow.Engine.set_instance_error/2`,
  the actual REQ-061 function, exercised end-to-end (real transaction, real event append, real
  projection read-back) — not a mock, not an assertion on `build_error_args/3`'s return shape
  alone. This is the literal test AC8 asks for, buildable today because `set_instance_error/2`'s
  own standalone-entry-point design (`req061` §4) never required a node-dispatch caller to exist
  first — the exact independence AC8's own text is written to exploit ("deferred forward because
  REQ-057 did not exist when REQ-061 was built" reads as "once REQ-057 exists, close the loop,"
  not "once REQ-057's own future runtime dispatch caller exists").

**What this does NOT close, stated so it isn't conflated with AC8:** this demonstration proves a
plugin `{:error, _}` outcome reaches `set_instance_error/2` when a caller follows §7's documented
`invoke → build_error_args → set_instance_error` sequence. It does **not** prove any *real* graph
node's execution actually invokes a plugin handler at runtime — that remains §1's own
out-of-scope future wiring (REQ-056 or equivalent), unchanged by this addition. AC8's own wording
("rather than writing its own ERROR transition") is about this requirement not inventing a
second, competing ERROR-write path, which §2.5/INV-PR-8 establish structurally, not about
runtime dispatch existing yet.

---

## 8. Wiring into REQ-049 — variable merge (AC1)

On `PluginInterface.invoke/2,3` returning `{:complete, output_variables}` (§2.4), the future
runtime dispatch caller merges it exactly as `req049` §8 already documents for its own two named
future callers (task completion, service task response):

```
Letflow.Engine.VariableMerge.merge(context.variables, output_variables, variable_validations)
```

— `output_variables` (this design's `outcome()` member, §2.3) **is** `merge/3`'s
`incoming_variables :: map()` parameter, with no adapter, no re-keying, no type coercion: both
are plain `map()` values by construction (§2.3's own `@type outcome`). On `merge/3`'s own
`{:ok, new_variables, events}` result, the caller sets the live instance's variable state to
`new_variables` and appends any `VARIABLE_OVERWRITTEN` events exactly as `req049` §8 step 4
already specifies; on `merge/3`'s own `{:rejected, unchanged_variables, [execution_error_event]}`
result (a schema-rejected plugin output — a **second**, independent way a plugin-originated
completion can still end in `ERROR`, distinct from `invoke/2,3` itself returning `{:error, _}`),
the caller follows `req049` §8 step 5's own already-documented path into `ExecutionError`
(REQ-049's own `:variable_schema_rejected` error type, not this requirement's
`:plugin_error_outcome` — the two error types are genuinely different failure classes: "the
plugin crashed/errored" vs. "the plugin's output didn't pass variable-schema validation," and
this design does not conflate them). **This requirement adds nothing new to `VariableMerge`
itself** — `merge/3`'s existing signature, unmodified, is the entire integration point.

---

## 9. DB tables/columns touched — none

`Letflow.Engine.PluginInterface` and `Letflow.Engine.PluginRegistry` are both entirely in-memory
(ETS + `GenServer` state, §4) — **no new `Ecto.Schema`, no migration, no persisted table.**
Registration is sourced from application configuration (§6.4), not a database row; resolution
reads never touch `Letflow.Repo`. The only persistence this design's own wiring sections (§7, §8)
touch is `events`/`instance_projections`, both via already-shipped REQ-025/043/049/061 machinery,
unmodified by this requirement.

---

## 10. Open questions — explicitly listed, not silently resolved

PROVENANCE (historical, not current decision authority):
**OQ-1 (MAJOR).** §4's storage-mechanism decision (`GenServer` + private ETS, reads bypassing
the process) is this design's own resolution of the handoff's own explicitly-left-open tension,
reasoned from `stage-3-instance-engine.md`'s own cited finding — **not verified against
`plugin_registry.zig`'s literal source** (§0's access gap). Flagged for REVIEWER at Step 2d to
confirm, and named as a candidate for promotion to a `docs/migration/decisions/000x-*.md` record
per the stage doc's own escalation framing, since a plugin-registry storage choice is exactly
the kind of "introduces a new dependency or a platform-wide rule" decision that doc anticipates
might need one.

PROVENANCE (historical, not current decision authority):
**OQ-2 — RESOLVED (GH#327, ISS-0099, 2026-08-20).** §3.2's reconciliation — treating this
registry's `handler_key` as an open `String.t()` (not `Graph.node_type()`'s 8-atom enum)
specifically so the same namespace serves both this requirement's own "node_type" vocabulary
and REQ-031's `plugin_handler` identifier string — was this design's own judgment call, not
verified against R-Co source at the time. `R-Co/src/engine/plugin_registry.zig` (L23–41, L51,
L88–131) and `R-Co/src/design/ext-03-plugin-interface.md` (L31, L63, L129, L213) have since been
read directly (see §3.2): R-Co itself keys its one plugin registry by `node_type: []const u8`,
an open string with only a non-empty-string validity check, not a closed enum — confirming this
design's `handler_key :: String.t()` choice matches R-Co's own shape exactly, and that the
two-separate-registries alternative considered and rejected here was the correct rejection. No
further action for REVIEWER on this item.

**OQ-3 (MINOR).** §2.4.1's `{:ok, other}` defensive branch (a handler returning a value outside
its own `@callback` contract) is a design addition beyond this run's own five/seven named ACs —
included because `outcome()` is not statically enforced across a behaviour dispatch, but flagged
so REVIEWER can confirm it is a legitimate defensive addition, not undisclosed scope creep.

PROVENANCE (historical, not current decision authority):
**OQ-4 (MINOR).** `supported_api_version/0`'s own fixed value (`1`, §6.1 step 5) and the default
`api_version` applied when a registration omits it (also `1`) are this design's own choice —
`plugin_registry.zig`'s real versioning scheme (what values are "compatible," whether it is a
single integer or a range) is unverified (§0's access gap). Flagged for whichever future
requirement first needs `api_version` to mean something more than "must equal 1 today."

**OQ-5 (MINOR).** §4.4/§6.4's "startup-only, no dynamic loading" is enforced **operationally**
(nothing outside the boot sequence calls `register_plugin_handler/1` in practice, and
`freeze_plugin_registry/1` runs automatically at the end of `init/1`) but is not enforced as a
**hard, structural** guarantee — any code with a reference to the running
`Letflow.Engine.PluginRegistry` process could, in principle, call `register_plugin_handler/1`
directly before the automatic freeze completes (a narrow window during `init/1` itself, before
`start_link/1` returns and the process becomes reachable via its registered name — in practice
unreachable from outside, since no other process can send it a message before `Supervisor`
finishes starting it, but stated here rather than asserted as impossible without tracing it).
Flagged for REVIEWER to confirm this operational guarantee is sufficient for AC4's own wording.

PROVENANCE (historical, not current decision authority):
**OQ-6 (MINOR).** `@default_timeout_ms`'s own value (§2.4.1 step 2) is not fixed by this design
— left as an implementation constant ELIXIR-DEV chooses (a reasonable default, e.g. in the
low-tens-of-seconds range, matching typical HTTP-call-shaped SERVICE_TASK/plugin latencies this
codebase's other timeout-bearing code — none currently exists to cite as precedent, §0 found no
comparable existing timeout constant in `lib/letflow/`) — not verified against
`plugin_interface.zig`'s own default, if it has one.

---

## 11. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-PR-1 | `PluginInterface.invoke/2,3` never raises, never exits, and never lets a handler's raise/exit propagate into its own caller — every path returns `outcome()` | §2.4.1 |
| INV-PR-2 | A handler's own `{:error, reason}` string is never rewritten, truncated, or reformatted between `invoke/2,3`'s return and the persisted `EXECUTION_ERROR` event's `reason` field | §2.4.1 step 3, §7 |
| INV-PR-3 | Once `freeze_plugin_registry/1` returns `:ok`, no subsequent `register_plugin_handler/1` call ever succeeds, for the remaining lifetime of that process | §6.1 step 1, §6.2 |
| INV-PR-4 | A `:tenant`-scoped registration always carries a non-nil `owner_tenant_id`; a `:global`-scoped registration never does | §6.1 step 4, `registration()`'s own type comment §3.2 |
| INV-PR-5 | `resolve_plugin_handler_for_tenant/2` never returns a `:tenant`-scoped registration whose `owner_tenant_id` differs from the requested `tenant_id` | §5.2 |
| INV-PR-6 | `resolve_node_handler_kind/1` returns `:plugin` whenever any registration exists under a `handler_key`, regardless of whether `Transition` itself has a real dispatch clause for that type | §5.1 |
| INV-PR-7 | `Letflow.Engine.PluginRegistry`'s read path (`resolve_node_handler_kind/1`, `resolve_plugin_handler_for_tenant/2`) never calls `GenServer.call/2` — always a direct ETS read from the calling process | §4.2, §5 |
| INV-PR-8 | `PluginInterface`/`PluginRegistry` perform zero `Letflow.Repo`/`Letflow.EventStore` calls of their own | §2.4.3, §9 |
| INV-PR-9 | No `tenant_id` column or table is introduced by this requirement (Decision 0006 D2's own no-`tenant_id`-sprawl spirit, though this requirement adds no DB table at all so the invariant is vacuous but stated for consistency with every other S3 design's own invariant table) | §9 |
| INV-PR-10 | `build_error_args/3` is the only function this requirement defines that constructs an `ExecutionError.error_args()` value — no other ERROR-transition path exists anywhere in `PluginInterface`/`PluginRegistry` | §2.5, §7.1 |

---

## 12. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Definitions.Graph`/`.Node` (REQ-028/029) | loose, string-only | `ExecutionContext.node_type`/`PluginRegistry`'s `handler_key` are both `String.t()`, deliberately not coupled to `Graph.node_type()`'s atom type (§2.2, §3.2) — no `alias`, no direct reference |
| `Letflow.Engine.VariableMerge` (REQ-049, shipped) | this design → that | `merge/3` consumes a plugin's `{:complete, output_variables}` unchanged (§8) — `VariableMerge` itself is not modified |
| `Letflow.Engine.ExecutionError` / `Letflow.Engine.set_instance_error/2` (REQ-061, shipped) | this design → that | `:plugin_error_outcome` (already in `ExecutionError.error_type()`'s union) consumed unchanged (§7); `build_error_args/3` (§2.5) produces `set_instance_error/2`'s own input shape directly, and §7.1's test calls `set_instance_error/2` for real to close AC8 — `ExecutionError` itself is not modified |
| `Letflow.Definitions.ServiceScopeValidator.Lookup`/`plugin_lookup_fun` (REQ-031, shipped) | this design → that | `as_plugin_lookup_fun/0` produces the exact function value that type requires (§5.3) — `ServiceScopeValidator` itself is not modified, and no live call site wires it in yet (§5.3's own scope note) |
| `Letflow.SandboxPool` (shipped) | pattern precedent only, not called | The `Process.monitor`/exit-observation *shape* this design's `Task.yield/2` mechanism mirrors (§0, §2.4.1) — not invoked by this design |
| `Letflow.Application`/`Letflow.Supervisor` (shipped) | this design edits | Two new children added: `Task.Supervisor` (named `Letflow.Engine.PluginTaskSupervisor`) and `Letflow.Engine.PluginRegistry` (§4.3, §4.4) |
| `Letflow.InstanceSupervisor` (shipped) | **not used** | §4.5 states explicitly why this requirement's registry does not live under it |
| Future runtime plugin/service-task dispatch (most plausibly REQ-056, not yet built) | future caller | The entire integration this requirement makes possible but does not itself perform — §1, §7, §8 name the exact call shapes that future requirement's own CODE-DESIGNER should reuse rather than reinvent |
| S5 (WASM plugin host, `src/wasm/`, not yet built, needs its own decision record) | future, out of scope | §1 — this requirement supports only in-process Elixir `PluginInterface` implementations; S5 would supply a WASM-hosted implementation of the same behaviour, not built here |

---

## 13. Acceptance-criteria traceability

| This run's acceptance criterion | Concrete design element |
|---|---|
| 1. A registered handler is invoked with a context carrying all seven named fields, and `COMPLETE` with output variables merges via REQ-049's merge | §2.2 (`ExecutionContext`, all seven fields), §2.4 (`invoke/2,3`'s `{:complete, _}` branch), §8 (the exact `VariableMerge.merge/3` call shape, no adapter) |
| 2. A handler returning `ERROR` routes the instance to REQ-061's EE-10 path with the reason string preserved | §2.4.1 step 3 (`{:ok, {:error, reason}}` branch, unchanged), §7 (`error_args.reason` byte-for-byte, `:plugin_error_outcome` reusing `ExecutionError`'s already-shipped atom) |
| 3. A handler that raises AND a handler that exits are both treated as `ERROR` — two explicit tests, since a bare try/rescue passes the first and fails the second | §2.4 (why `try/rescue` is insufficient, stated explicitly), §2.4.1 step 3's `{:exit, reason}` branch (covers both, via `Task.yield/2`'s own monitor-based observation, §2.4.2's disclosed does/doesn't-cover boundary) |
| 4. Each of the five registration errors is distinct and pattern-matchable, with its own test | §3.3 (`registration_error()`'s 7-member union), §6.1 (explicit check order, one atom per rule) |
| 5. A tenant-scoped registration without an owner and a global registration with one are both rejected distinctly; resolution for tenant B never returns tenant A's handler | §6.1 step 4 (two distinct errors), §5.2 (resolution order + AC5's own non-leak guarantee) |
| 6. A plugin registered for a node_type with a built-in handler shadows the built-in, demonstrated by a test | §5.1 (built-in-agnostic precedence rule + the `"HUMAN_TASK"`-not-`"SERVICE_TASK"` test-shape note, since only the former has a real built-in today per §0) |
| 7. The moduledoc states the S5/WASM scope boundary, the in-process-only support statement, and names the registry-storage mechanism as this design's own resolved decision | §1 (scope boundary table, required moduledoc content for both new files), §4 (the resolved decision + its reasoning, ready to be copied into `PluginRegistry`'s own moduledoc almost verbatim) |
| 8. A handler `ERROR` outcome is demonstrated routing into REQ-061's `set_instance_error` rather than writing its own ERROR transition, confirmed by inspection and by test — closing REQ-061's own AC obligation deferred forward to this requirement | §2.5 (`build_error_args/3`, the single, in-scope, inspectable mapping function), §7.1 (the full in-scope 7-step test sequence — real `create/2` instance, fixture handler, `invoke/2` → `build_error_args/3` → real `set_instance_error/2` call, real read-back — that TEST-DESIGNER runs without needing REQ-056's future node-dispatch wiring), INV-PR-10 |
