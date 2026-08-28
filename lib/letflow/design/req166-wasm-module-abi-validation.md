# REQ-166 — WASM module ABI validation and rejection at registration (WASM-02)

**Requirement:** REQ-166 (WASM-02 — module ABI, MUST; registration-time rejection)
**Stage:** S5
**Owner (design):** CODE-DESIGNER; **Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-28
**Depends on:** REQ-165 (done, `lib/letflow/engine/wasm/plugin_handler.ex`); consumes
`lib/letflow/design/req163-wasm-abi-choice.md` (gate-approved) for the export contract.

This is a design artefact — `@spec`/`@type` signatures only, no function bodies. See
`docs/agents/workflows/WF-02_requirement_implementation.md` Step 1.

---

## 0 — Where the 5-export contract comes from (cites, does not re-derive)

Per this requirement's own instruction, the export contract is **not re-derived here**.
It is read verbatim from `lib/letflow/design/req163-wasm-abi-choice.md`:

- **§3.1** (table) — the four WASM-02-named exports and their exact core-module function
  types: `init: (i32, i32) -> i32`, `execute: (i32, i32) -> i32`, `deinit: () -> ()`,
  `get_capabilities: () -> i32`.
- **§3.2** — the fifth, *implicit* required export the descriptor convention forces:
  `alloc: (i32) -> i32`, plus the requirement that every conforming module also export a
  `memory` (a WASM linear-memory export, not a function — checked by export *kind*, not
  function signature).

This design's validator checks exactly these five function exports plus the one memory
export — six export-section entries in total — against req163 §3.1/§3.2. No new export
name or signature is introduced here.

---

## 1 — Real `wasmex` API for export/import introspection (verified live, not guessed)

Verified against the actual installed dependency (`deps/wasmex` v0.15.1, matching
`mix.lock`) by reading `deps/wasmex/lib/wasmex/module.ex` and then **compiling real WAT
fixtures through it in a live `iex`/`mix run` session** (`MIX_ENV=test`, no DB
dependency) to confirm the documented shapes match actual return values, not just
doc-comment prose.

### 1.1 `Wasmex.Store.new/0,2`

```
@spec Wasmex.Store.new() :: {:ok, Wasmex.StoreOrCaller.t()} | {:error, binary()}
```

A store must exist before a module can be compiled. No WASI options are supplied
(`Wasmex.Store.new/0`, not `new_wasi/1..3`) — irrelevant to REQ-166's export check, but
notable because it means the validator never grants any WASI import, consistent with
req163 §4's denial-by-omission posture (REQ-167's concern, not re-decided here).

### 1.2 `Wasmex.Module.compile/2`

```
@spec Wasmex.Module.compile(Wasmex.StoreOrCaller.t(), binary()) ::
        {:ok, Wasmex.Module.t()} | {:error, binary()}
```

Compiles (parses + validates + lowers) the module's bytes **without instantiating it**
— no imports are resolved, no `memory` is allocated, no code runs. Verified live: valid
WAT/`.wasm` bytes yield `{:ok, %Wasmex.Module{}}`; syntactically invalid bytes
(`"not valid wasm"`) yield `{:error, "Error while parsing bytes: expected `(`\n ..."}`
— a plain string reason, not a raised exception. **This is stage 1 of REQ-166's
validator (§5.1)** — a syntactically/structurally invalid module is rejected here,
before stage 2's real instantiation attempt (§2.2/§5.1 stage 2) ever runs; §4 below
explains why the two-stage sequencing (not "compile only, never instantiate" — rework-1's
prior, incorrect framing) is what makes "never invocable" structural rather than
by-convention.

### 1.3 `Wasmex.Module.exports/1` — the export-introspection primitive this design uses

```
@spec Wasmex.Module.exports(Wasmex.Module.t()) :: %{String.t() => export_info()}
```

where (verified live, matching `module.ex`'s moduledoc exactly):

```
@type export_info ::
        {:fn, params :: [wasm_valtype()], results :: [wasm_valtype()]}
        | {:memory, %{shared: boolean(), memory64: boolean(), minimum: non_neg_integer()}}
        | {:global, term()}
        | {:table, term()}

@type wasm_valtype :: :i32 | :i64 | :v128 | :f32 | :f64
```

Live confirmation (this session, `MIX_ENV=test mix run`, a WAT module exporting all six
required entries plus one extra function): `Wasmex.Module.exports/1` returned exactly

```
%{
  "alloc"            => {:fn, [:i32], [:i32]},
  "bad_execute"      => {:fn, [:i32], [:i32]},   # extra export, correctly ignored
  "deinit"           => {:fn, [], []},
  "execute"          => {:fn, [:i32, :i32], [:i32]},
  "get_capabilities" => {:fn, [], [:i32]},
  "init"             => {:fn, [:i32, :i32], [:i32]},
  "memory"           => {:memory, %{shared: false, memory64: false, minimum: 1}}
}
```

Removing an export from the fixture (tested live with `init`-only + `memory`) removes
exactly that key from the returned map — confirming absence is detectable as "key not
present," and a wrong-signature export (tested live: `execute` compiled with
`(param i32) -> i32` instead of `(param i32 i32) -> i32`) is detectable as "key present,
`{:fn, params, results}` value does not equal the required tuple" — both without ever
instantiating the module. This map is a **pure, static function of the compiled bytes**:
no store mutation, no memory, no imports resolved, confirmed by `Wasmex.Module.compile/2`
not accepting or touching any import-providing arguments (§1.2).

### 1.4 `Wasmex.Module.imports/1` — read for context, not used by REQ-166's check

```
@spec Wasmex.Module.imports(Wasmex.Module.t()) :: %{String.t() => %{String.t() => export_info()}}
```

Namespace → name → `export_info()`, same tuple shapes as §1.3. **Static import
*enumeration* is out of REQ-166's scope** (a manifest-driven import *whitelist* — "does
this module only import capabilities its manifest declares" — is REQ-167's job, per
req163 §4) — named here only because it is the same static, pre-instantiation primitive
family as `exports/1`. Note this is a narrower scope boundary than rework-1 drew: REQ-166
does not enumerate or whitelist imports by name, but it DOES (per §2.2/§5.1 stage 2,
F1's fix) attempt real instantiation, which is what actually *fails* on any unresolved
import regardless of name — the mechanism, not the whitelist. `Wasmex.Module.imports/1`
itself remains unused by `register/1`; instantiation failure is detected via
`Wasmex.start_link/1`'s own outcome (§5.1 stage 2), not by pre-inspecting the import
section.

### 1.5 `Wasmex.start_link/1` on an unresolved-import module: real, independently-verified crash behavior (corrects rework-1's false claim)

**This section previously asserted, as an independently live-verified fact, that
`Wasmex.start_link/1`'s init-time crash on an unresolved import is absorbed by
`GenServer.start_link/3`'s `:proc_lib` handshake into a clean `{:error, reason}` value
that "does not leak an `:EXIT` signal to a non-trapping caller." That claim was false.**
CODE-DESIGN-VALIDATOR reproduced the opposite independently, and this rework reproduced
it again from scratch (below) before writing a single word of the redesigned §2/§4 that
depends on getting this right.

**Live reproduction (this session, `MIX_ENV=test mix run`, real installed `wasmex`
v0.15.1), a WAT module importing `wasi_snapshot_preview1`/`path_open` (unresolved —
no WASI options supplied, per §1.1):**

- Calling `Wasmex.start_link(%{bytes: bytes})` **inline, in the calling process itself**,
  wrapped in `try do ... rescue ... catch ...`, does **not** return control to the
  `rescue`/`catch` clauses at all. The calling process itself terminates: the script
  printed `** (EXIT from #PID<...>) an exception was raised: ** (MatchError) no match of
  right hand side value: {:error, "unknown import: `wasi_snapshot_preview1::path_open`
  has not been defined"}` from inside `Wasmex.init/1` (`lib/wasmex.ex:489`, reached via
  `gen_server.erl`'s `init_it/2,6` → `proc_lib.erl`'s `init_p_do_apply/3`), and the whole
  `mix run` process exited with status code 1 — the line after the `try` block never ran.
  This is a **linked `:EXIT` signal propagating to a non-trapping caller**, not a value
  `try/rescue/catch` can intercept, because the failure is delivered as a process signal
  (the newly-`start_link`'d process links to its caller per every `GenServer.start_link/3`
  contract, then dies during `init/1`), not as a raised exception inside the caller's own
  call stack.
- Calling the same `Wasmex.start_link(%{bytes: bytes})` from inside a plain
  `spawn/1`'d (unlinked, unmonitored) process instead: the caller is unaffected (no
  message, no crash) because there is no link — but this discards the failure reason
  entirely, which is useless for a registration path that must report *why* it rejected
  a module.
- Calling it from inside a `Task.Supervisor.async_nolink/2` task (the exact mechanism
  `Letflow.Engine.PluginInterface.invoke/2,3` already uses, per its own moduledoc, and
  the pattern `plugin_handler.ex`'s own residual-risk section names), then reading the
  result via `Task.yield/2`: the calling process survives (confirmed: script completed,
  exit code 0) and `Task.yield/2` returns
  `{:exit, {{:badmatch, {:error, "unknown import: \`wasi_snapshot_preview1::path_open\`
  has not been defined"}}, stacktrace}}` — the crash is delivered as an ordinary task
  outcome, not a signal to the calling process, because `async_nolink/2` explicitly does
  not link the task to its caller (only `Task.Supervisor` itself supervises/traps it).
  The same harness, run against a conforming module instead, returned `{:ok, <task's
  return value>}` with no crash at all — confirming the harness does not mistake a
  clean success for a crash.

**Conclusion:** `Wasmex.start_link/1` is real, working, and instantiates cleanly for a
conforming module — but on an unresolved-import module it crashes a non-trapping caller
via a linked `:EXIT` signal, it does **not** hand back a clean `{:error, reason}` term to
inline `try/rescue/catch` code. Any design (this rework included, per §4) that calls
`start_link/1` as part of registration MUST do so from inside a `Task.Supervisor`-owned,
`async_nolink/2`-started task and read the outcome via `Task.yield/2`/`Task.shutdown/2` —
never inline in `register/1`'s own process — exactly as §2.2/§5.1 below now do.

---

## 2 — Where the validator lives: `Letflow.Engine.Wasm.ModuleRegistry`

**New module: `lib/letflow/engine/wasm/module_registry.ex`.**

Named `ModuleRegistry`, not `AbiValidator`, because its job is broader than a pure
predicate: it is the **one entry point** through which a module's bytes are turned into
something invocable at all (a `Wasmex.Module.t()` a caller may later instantiate) —
"validator" would undersell that it also *produces* the sole artefact invocation is
allowed to consume (§4). `AbiValidator` would suggest a stateless yes/no check that some
other module still has to remember to call before instantiating; naming it
`ModuleRegistry` makes registration the one unavoidable door.

### 2.1 Relationship to REQ-165's `PluginHandler` — fully decoupled, not a pre-check inside invocation

`Letflow.Engine.Wasm.PluginHandler.handle_node/1` (existing, REQ-165) is **not modified
by this design** to call the validator inline. Per the requirement's own text
("registration is a distinct step from invocation, with its own entry point"),
`ModuleRegistry.register/1` (§3) is a separate, earlier call a *registration* caller
(a future admin/API path — out of REQ-166's scope, same as REQ-167/169/170/171/172/173
per the `NOT IN THIS REQUIREMENT` list) makes once, at module-upload/registration time,
before any `PluginHandler`-mediated invocation is ever attempted for that module's bytes.
`PluginHandler.run_guest/2` (existing, §"Runs the named guest export" in
`plugin_handler.ex`) is untouched: it still reads fixture bytes and calls
`Wasmex.start_link/1` directly, because by construction (§4) a `PluginHandler` caller
only ever holds bytes that already passed `ModuleRegistry.register/1` — REQ-166 does not
retrofit that guarantee onto `PluginHandler` itself; a future dispatch-integration
requirement (the same "future requirement" `PluginInterface`'s own moduledoc defers
runtime wiring to) is what makes the registry's approval the only path to a `PluginHandler`
call in production. This mirrors `PluginInterface`'s own documented scope boundary
(§"Scope boundary" in `plugin_interface.ex`): a behaviour/mechanism module is built and
gate-approved before anything wires it into a live call path.

### 2.2 A dedicated `Task.Supervisor` for the instantiation-attempt boundary

**New supervised child: `Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor` — a new,
dedicated `Task.Supervisor`, not a reuse of `Letflow.Engine.PluginTaskSupervisor`.**

Per §1.5, `register/1`'s instantiation attempt (§5.1 step 4a below) must run inside a
`Task.Supervisor.async_nolink/2` task, read back via `Task.yield/2`/`Task.shutdown/2`,
so an unresolved-import crash is delivered as a task outcome rather than a linked
`:EXIT` signal to `register/1`'s own caller. This repo's own precedent (§4.4 of
`lib/letflow/design/req155-lua-wallclock-kill.md`, gate-approved) already establishes
one dedicated `Task.Supervisor` per subsystem/concern rather than one shared supervisor
for every supervised task in the application — `Letflow.SandboxPool.TaskSupervisor`,
`Letflow.Engine.PluginTaskSupervisor` (dedicated to in-process plugin *dispatch*, REQ-057),
and `Letflow.Engine.Lua.TaskSupervisor` (dedicated to Lua script *execution*, REQ-155)
already coexist as separate supervisors for separate concerns. Module *registration* is
a fourth, independent concern from all three: it runs once per module upload, off any
workflow-execution hot path, and its purpose (proving instantiability, then immediately
tearing the instance back down — §3.1) is unrelated to `PluginTaskSupervisor`'s job of
supervising a live guest call's dispatch. Sharing `PluginTaskSupervisor` would conflate
registration-time crash/telemetry activity with invocation-time dispatch activity under
one supervisor's observable child count for no offsetting benefit, the same reasoning
`req155-lua-wallclock-kill.md` §4.4 already applied to justify its own dedicated
supervisor rather than reusing `PluginTaskSupervisor`.

`lib/letflow/application.ex`'s supervision tree gains one new child spec —
`{Task.Supervisor, name: Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor}` — placed
anywhere alongside its sibling `Task.Supervisor` children (order does not matter among
them; none depends on another, unlike `Letflow.SandboxPool.TaskSupervisor`'s documented
start-order dependency). This is the one `lib/letflow/` file this design touches outside
`module_registry.ex` itself, and it is an ELIXIR-DEV implementation change, not something
this design document edits.

### 2.3 Moduledoc content (maps to AC6/AC "moduledoc" bullet)

`Letflow.Engine.Wasm.ModuleRegistry`'s moduledoc must state, verbatim in substance:

- This module implements WASM-02's registration-time rejection.
- The five required exports (`init`, `execute`, `deinit`, `get_capabilities`, `alloc`)
  and the required `memory` export are req163-wasm-abi-choice.md §3.1/§3.2's contract,
  cited by section number — not re-derived here, and this module has no authority to
  change that contract.
- Core modules, not the component model, per req163's Decision — this module never
  calls anything under `Wasmex.Components`.
- Validation is a two-stage gate: (1) static export-section introspection
  (`Wasmex.Module.compile/2` + `Wasmex.Module.exports/1`, §1.2/§1.3), then (2), only if
  (1) passes, a real instantiation attempt (`Wasmex.start_link/1`, run inside a
  monitored `Task.Supervisor.async_nolink/2` task per §1.5/§2.2 — never called inline),
  immediately torn down on success (§3.1). Per req163-wasm-abi-choice.md §4, an
  instantiation failure (including an unresolved import) is rejected identically to a
  missing/malformed export — at registration, not first invocation. Rejection is
  structural (§4) because the only function that can build a `registered_module()`
  value is `register/1`'s own success branch, reached only after *both* stages pass —
  not because `start_link/1` is never called (it is, deliberately, as stage 2).

---

## 3 — Public entry point

```
defmodule Letflow.Engine.Wasm.ModuleRegistry do
  @type export_name :: String.t()

  @type valtype :: :i32 | :i64 | :v128 | :f32 | :f64

  @typedoc "One required export's expected shape, per req163 §3.1/§3.2."
  @type required_export ::
          {:fn, name :: export_name(), params :: [valtype()], results :: [valtype()]}
          | {:memory, name :: export_name()}

  @typedoc """
  One concrete way a required export failed to conform, naming the export by name
  (AC "structured error naming which export(s)").
  """
  @type export_defect ::
          {:missing, export_name()}
          | {:wrong_kind, export_name(), expected :: :fn | :memory, actual :: atom()}
          | {:wrong_signature, export_name(),
             expected: {[valtype()], [valtype()]}, actual: {[valtype()], [valtype()]}}

  @typedoc """
  One concrete way the real instantiation attempt (§2.2/§5.1 step 4) failed. Per
  req163-wasm-abi-choice.md §4, an unresolved-import failure must be named by its
  namespace/function, not returned as an opaque blob, wherever the crash reason is
  shaped to allow it.
  """
  @type instantiation_defect ::
          {:unresolved_import, namespace :: String.t(), function :: export_name()}
          | {:crashed, raw_reason :: term()}
          | {:timeout, timeout_ms :: non_neg_integer()}

  @typedoc """
  The structured rejection reason (AC "structured error", not a bare string).
  `defects` is always non-empty for `:invalid_abi` and lists EVERY defect found in one
  pass, not just the first (§5.2) — the same "one test case per required export" the
  requirement's AC2 implies is only satisfiable by a caller if this shape doesn't stop
  at the first miss. `:instantiation_failed` is reached only when the static check
  (`:invalid_abi`) already passed — see §5.1 step 4 for why the two stages are
  sequential rather than merged into one defect list.
  """
  @type registration_error ::
          {:invalid_abi, defects :: [export_defect()]}
          | {:compile_error, reason :: binary()}
          | {:instantiation_failed, instantiation_defect()}

  @typedoc "Opaque handle to a module that has passed registration. See §4."
  @opaque registered_module :: %__MODULE__.RegisteredModule{
            module: Wasmex.Module.t(),
            bytes: binary()
          }

  @doc """
  The single entry point registration goes through. Two sequential stages (§5.1):
  (1) static export/signature check (`Wasmex.Module.compile/2` + `Wasmex.Module.exports/1`,
  §1.2/§1.3) — on any defect, returns `{:error, {:invalid_abi, defects}}` and stage 2
  never runs; (2) only once stage 1 finds zero defects, a real instantiation attempt
  (`Wasmex.start_link/1`, run inside a monitored `Task.Supervisor.async_nolink/2` task
  under `Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor` — never called inline, per
  §1.5/§2.2) — on any instantiation failure (including an unresolved import, per
  req163-wasm-abi-choice.md §4), returns `{:error, {:instantiation_failed, defect}}`.
  The Wasmex instance stage 2 starts on success is immediately stopped (`GenServer.stop/1`)
  before `register/1` returns — it is not kept running (§3.1). Returns
  `{:ok, registered_module()}` only when both stages pass; otherwise
  `{:error, registration_error()}` naming the specific defect found.
  """
  @spec register(bytes :: binary()) :: {:ok, registered_module()} | {:error, registration_error()}
end
```

### 3.1 The `RegisteredModule` wrapper — how "invocable" and "registered" become the same fact

`RegisteredModule` is an `@opaque` struct (no public constructor other than
`register/1`'s success path) wrapping the already-compiled `Wasmex.Module.t()` (§1.2 —
`register/1` calls `Wasmex.Module.compile/2` itself, once) plus the original `bytes`. A
future invocation path (the dispatch-integration requirement, §2.1) is designed to accept
**only** a `registered_module()` — never raw `binary()` — as the thing it hands to
`Wasmex.start_link/1` (e.g. via `Wasmex.start_link(%{store: ..., module: registered.module})`
or `%{bytes: registered.bytes}`, either is fine since both were already proven to compile
cleanly in §1.2). Because the struct has no public field-less constructor and its fields
are not part of its public contract (`@opaque`), the only way calling code anywhere in
`lib/letflow/` obtains a `registered_module()` value is `register/1`'s `{:ok, _}` branch —
now reached only after stage 2's real instantiation attempt (§5.1 step 4) also succeeded.

**Decision: the instantiation-attempt's `Wasmex` instance is started, then immediately
stopped — never kept running past `register/1`'s return.** `register/1`'s stage-2 task
(§2.2) starts a real instance purely to observe whether `Wasmex.start_link/1` succeeds
or fails; on success it calls `GenServer.stop/1` on that instance from inside the same
task, before the task returns its outcome to `register/1`. A later real invocation (the
dispatch-integration requirement, §2.1) starts its **own, separate, fresh** instance
from the `registered_module()`'s `module`/`bytes` field at call time — it never reuses
the instance registration proved instantiability with.

**Why start-then-stop, not keep-alive:** REQ-165's own `PluginHandler.run_guest/2`
(`plugin_handler.ex`, unchanged by this design per §2.1) already establishes the
project's per-invocation isolation principle for WASM guests — decision 0014 Reasoning
(e): "a fresh Wasmtime instance for this call only" per its own inline comment, stopped
unconditionally (`GenServer.stop/1`) on every path including the error path, so an
instance is never leaked or reused across calls. A `register/1` that kept its
instantiation-proof instance alive and handed it to the *first* future invocation would:
(a) special-case that first call to skip its own fresh-instance step, breaking the
uniform "every call gets a fresh instance" guarantee decision 0014(e) and
`run_guest/2`'s own algorithm both already rely on; (b) hold a live Wasmtime
instance (memory, any resources Wasmtime allocated) for an unbounded, unrelated span of
time between registration and whenever (if ever) the module is first invoked, with no
supervisor tracking its lifetime for that span since `Task.Supervisor.async_nolink/2`'s
task — and the instance it started — both end when stage 2 finishes; and (c) require
`RegisteredModule` to carry a live `pid()` that could die independently of the struct
(the instance's owning process could crash on its own, e.g. via the same NIF-crash
residual risk `plugin_handler.ex`'s moduledoc already discloses), silently invalidating
a "registered" value without `register/1` itself being on the call stack to notice.
Start-then-stop avoids all three: `registered_module()` carries only inert data
(`Wasmex.Module.t()` + `bytes`, both already immutable/serializable-shaped per §1.2),
and every invocation — first or hundredth — goes through the exact same fresh-instance
path `run_guest/2` already implements, with no special case for "the instance
registration happened to still have running."

---

## 4 — Proof: a rejected module is never invocable (re-derived: `register/1` DOES call `start_link/1`)

**This proof no longer rests on "`register/1` never calls `Wasmex.start_link/1`" — per
F1, it does, deliberately, as stage 2 (§2.2/§5.1 step 4). Reconciling req163 §4 (below)
means the proof must instead rest on a narrower, still-sufficient fact: a
`registered_module()` value is only ever constructed after BOTH the static check and a
successful instantiation attempt have passed.**

**Reconciling req163 §4 (F1):** req163-wasm-abi-choice.md §4 states, verbatim, that
"REQ-166's registration-time validation (§3.1) must attempt instantiation as part of
registration and treat that failure identically to a missing required export: rejected
at registration ... not merely at first invocation." Rework-1 of this design
misread that sentence as scoping instantiation-based rejection to REQ-167 and
concluded the opposite of what it says. It does not say "REQ-167 must attempt
instantiation" — it explicitly assigns that duty to **REQ-166's own** registration path,
and only *names* the concrete import surface (`wasi_snapshot_preview1`/`path_open` etc.)
that REQ-167's own test will later exercise against the mechanism this requirement
builds. This rework accepts req163 §4's instruction as binding and folds it into
`register/1` (§2.2, §3, §5.1) rather than overriding it — no amendment to req163 was
needed once the sentence was read correctly.

**Claim:** no code path exists from a failed `register/1` call to `Wasmex.call_function/4`.

**Structural argument, not a prose assertion:**

1. `register/1` (§3) is the only function in `Letflow.Engine.Wasm.ModuleRegistry` that
   constructs a `registered_module()` value, and it does so only on one specific branch:
   stage 1 (static export/signature check, §5.1 steps 1–5) found zero defects **AND**
   stage 2 (the real instantiation attempt, §5.1 step 6) reported success. Either
   stage's failure returns `{:error, registration_error()}` and constructs no struct,
   opaque or otherwise, that wraps the compiled module.
2. `RegisteredModule`'s `@opaque` annotation means no module outside
   `Letflow.Engine.Wasm.ModuleRegistry` may pattern-match or build one directly against
   its fields (Dialyzer/`mix compile --warnings-as-errors` flags an opaque-type violation
   if one tries) — a caller cannot forge a `registered_module()` from raw bytes to route
   around a rejection.
3. The only two functions in the entire `wasmex` dependency that can start a runnable
   instance are `Wasmex.start_link/1` and `Wasmex.Instance.new/3` (per
   `deps/wasmex/lib/wasmex.ex` / `deps/wasmex/lib/wasmex/instance.ex`). `register/1`
   itself calls `Wasmex.start_link/1` exactly once, in stage 2, strictly *after* stage 1
   already found zero export/signature defects — never on a module stage 1 already
   rejected (§5.1 step 4's "only if stage 1 passed" gate) — and, per §1.5/§2.2, always
   from inside a `Task.Supervisor.async_nolink/2` task it owns, never inline. Every
   future invocation call site (§2.1) is committed to accepting only a
   `registered_module()` as its source of bytes/module, never a bare `binary()` sourced
   from outside `ModuleRegistry`.
4. Therefore: the only way `binary()` module bytes reach `Wasmex.start_link/1` anywhere
   `Letflow` owns — whether inside `register/1`'s own stage 2 or inside a later
   invocation call site — is (a) `register/1`'s own stage-2 attempt, which happens
   strictly before any `registered_module()` value exists and whose own instance is
   torn down before `register/1` returns (§3.1), never exposed to a caller; or (b) via a
   `registered_module()` that `register/1` issued, which only happens after both stages
   passed. A module that fails either stage never produces that value, so no downstream
   code — including `PluginHandler`'s own `run_guest/2` once the dispatch-integration
   requirement wires registration in front of it — has anything to call `start_link/1`
   or `call_function/4` with. The one place a *rejected* module's bytes ever reach
   `start_link/1` is `register/1`'s own stage-2 attempt on that same rejected module,
   and that attempt's outcome is exactly what produces the rejection — it does not, and
   structurally cannot, leave behind a `registered_module()` or a live instance a caller
   could reach.

This is provable today at the type level (opaque type + single-constructor-function
discipline, now spanning two sequential gates instead of one) even before the
dispatch-integration requirement exists to wire it in; §2.1 already states
`PluginHandler` itself is not modified by REQ-166, so the "never invocable" property for
THIS requirement's own deliverable concerns the boundary `ModuleRegistry` establishes,
not a claim that `PluginHandler`'s current, pre-registry code path is already gated (it
structurally is not yet, and REQ-166's own scope note says so is not required until the
dispatch-integration requirement exists).

---

## 5 — Validation algorithm (design-level, no implementation)

### 5.1 Steps — two sequential stages, stage 2 gated strictly on stage 1's success

**Stage 1 — static export/signature check (unchanged from rework-1, independently
verified correct by CODE-DESIGN-VALIDATOR):**

1. `Wasmex.Store.new/0` — a fresh store per registration attempt (never reused across
   modules; stores are cheap per §1.1's doc).
2. `Wasmex.Module.compile(store, bytes)` (§1.2). On `{:error, reason}`, return
   `{:error, {:compile_error, reason}}` immediately — a syntactically-invalid module has
   no export section to check, and stage 2 never runs.
3. `Wasmex.Module.exports(module)` (§1.3) — one map, obtained once.
4. For each of the five required function exports (req163 §3.1 + the implicit `alloc`
   of §3.2) and the one required `memory` export (§3.2): look up the export name in the
   map from step 3.
   - Name absent → `{:missing, name}`.
   - Name present but tuple's leading tag doesn't match the expected kind (`:fn` vs.
     `:memory`) → `{:wrong_kind, name, expected, actual_tag}`.
   - Kind matches, `:fn`, but `{params, results}` don't equal the exact list required
     by req163 §3.1 → `{:wrong_signature, name, expected: ..., actual: ...}`.
   - `:memory` kind matching is presence-only (req163 §3.2 states only that a `memory`
     export must exist, with no size/shared/64-bit constraint) — no defect variant
     beyond `:missing`/`:wrong_kind` applies to it.
5. Collect every defect from step 4 into one list (not stop-on-first — AC2's "one test
   case per required export" needs a validator that reports the specific missing one
   even when others are also missing, and reports *multiple* defects when a caller
   constructs a module missing more than one export in a single test). Non-empty list →
   return `{:error, {:invalid_abi, defects}}` immediately; stage 2 never runs (this is
   what "instantiation failure treated identically to a missing export" means in
   practice — both are registration rejections, but a static-check failure is reported
   as such without incurring an instantiation attempt at all, since req163 §4 only
   requires that instantiation failures be rejected at registration, not that every
   rejection path go through instantiation).

**Stage 2 — real instantiation attempt (new, per F1/req163 §4), only reached when stage
1's defect list is empty:**

6. Spawn `Wasmex.start_link(%{bytes: bytes})` inside a `Task.Supervisor.async_nolink/2`
   task under `Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor` (§2.2) — never inline in
   `register/1`'s own process, per §1.5's reproduced crash-propagation hazard. Read the
   outcome via `Task.yield/2` bounded by a fixed registration-instantiation timeout
   (mirroring `req155-lua-wallclock-kill.md`'s wall-clock pattern; the exact millisecond
   value is an ELIXIR-DEV implementation constant, not a value this design fixes, since
   no acceptance criterion depends on its exact magnitude — only that one exists so a
   hung instantiation attempt cannot hang `register/1` forever).
7. Branch on the outcome:
   - `Task.yield/2` returns `{:ok, {:ok, pid}}` (instantiation succeeded) → call
     `GenServer.stop(pid)` (§3.1's start-then-stop decision) inside the task, then
     proceed to step 8.
   - `Task.yield/2` returns `{:ok, {:error, reason}}` (`start_link/1` returned a clean
     error tuple rather than crashing — not observed in this session's live
     reproduction for the unresolved-import case, §1.5, but a defensive branch since
     `wasmex`'s own docs do not guarantee every instantiation failure crashes rather
     than returning `{:error, _}`) → treat identically to the crash branch below, using
     `reason` directly as the `raw_reason` in `{:crashed, raw_reason}` (§3
     `instantiation_defect()`).
   - `Task.yield/2` returns `{:exit, reason}` (the crash case §1.5 live-reproduced) →
     attempt to match `reason` against the shape observed live in §1.5 —
     `{{:badmatch, {:error, message}}, _stacktrace}` where `message` is a binary — and,
     if `message` matches the pattern `"unknown import: `<namespace>::<function>` has
     not been defined"` (the exact wording `wasmex` v0.15.1 produces, per §1.5's live
     reproduction), extract `<namespace>` and `<function>` verbatim and return
     `{:error, {:instantiation_failed, {:unresolved_import, namespace, function}}}` —
     this is req163 §4's "structured error naming the unresolved import (module name,
     function name)" requirement. Any other shape (a crash reason that doesn't match
     that exact pattern) → return
     `{:error, {:instantiation_failed, {:crashed, reason}}}` — never lose the raw
     reason, but do not force every future crash shape through the unresolved-import
     parse.
   - `Task.yield/2` returns `nil` (timeout) → `Task.shutdown(task, :brutal_kill)`, then
     return `{:error, {:instantiation_failed, {:timeout, timeout_ms}}}`.
8. Both stages passed with no defect: `{:ok, %RegisteredModule{module: module, bytes: bytes}}`.

### 5.2 Exact required-export table (restated from req163 §3.1/§3.2 for the implementer's convenience — not a new derivation)

| Export name | Kind | Params | Results |
|---|---|---|---|
| `init` | `:fn` | `[:i32, :i32]` | `[:i32]` |
| `execute` | `:fn` | `[:i32, :i32]` | `[:i32]` |
| `deinit` | `:fn` | `[]` | `[]` |
| `get_capabilities` | `:fn` | `[]` | `[:i32]` |
| `alloc` | `:fn` | `[:i32]` | `[:i32]` |
| `memory` | `:memory` | n/a | n/a |

---

## 6 — Traceability: REQ-166's 6 acceptance criteria → design elements

| # | Acceptance criterion (docs/requirements.yaml REQ-166) | Design element |
|---|---|---|
| 1 | "a test registers a module missing the execute export and asserts registration fails with a structured error naming the missing export" | §3 `registration_error()` / `export_defect() :: {:missing, "execute"}`; §5.1 stage 1 step 4-5 (returns before stage 2 ever runs) |
| 2 | "a test asserts a module missing EACH of the other required exports is likewise rejected — one test case per required export" | §5.2 table (all six required export names); §5.1 stage 1 step 5 (defects collected per-export, not stop-on-first) |
| 3 | "a test asserts rejection happens at REGISTRATION and not at invocation: a non-conforming module is never invocable" | §2.1 (decoupled entry point) + §4 (re-derived structural "never invocable" proof, spanning both stages) — now additionally covers the req163 §4 instantiation-failure case (§5.1 stage 2) rejected at registration too, not merely the export-defect case |
| 4 | "a test asserts a conforming module registers successfully and is then invocable" | §3 `register/1`'s `{:ok, registered_module()}` branch, now reached only after stage 2's real instantiation attempt also succeeds (§5.1 step 7 first bullet); §3.1 (the only path to a value a future invocation call site accepts, and the start-then-stop decision for the proving instance) |
| 5 | "the moduledoc names the export contract implemented and cites REQ-163's artefact as its source" | §2.3 (also now states the two-stage gate and cites req163 §4 for the instantiation-failure rejection) |
| 6 | "mix test and mix compile --warnings-as-errors both pass with real output quoted" | Not a design element — an ELIXIR-DEV implementation/CI obligation; §4's opaque-type discipline is specifically chosen so `--warnings-as-errors` (Dialyzer-adjacent opacity checks) has something to enforce |

---

## 7 — Open questions carried forward (not resolved here)

- **`alloc`'s failure-signalling contract** (req163 §6, first bullet) — out of REQ-166's
  scope per req163's own OQ list; REQ-166 validates `alloc`'s *export signature* only,
  not its runtime failure behavior (that's an invocation-time concern for whichever
  requirement implements `execute`'s full descriptor-read algorithm).
- **Whether `register/1` should also reject on `Wasmex.Module.imports/1` findings**
  (§1.4) — explicitly out of scope (REQ-167), but flagged so REQ-167's own CODE-DESIGNER
  knows `ModuleRegistry.register/1` already holds a compiled `Wasmex.Module.t()` at the
  exact point import-whitelist checking would also want one, and may extend `register/1`
  rather than compiling the module a second time.
- **Where `registered_module()` values are held/looked-up between registration and
  invocation** (a registry table, an ETS store, a `GenServer`'s state) — deliberately
  unspecified here; REQ-166's scope is the validation function and its result type, not
  a storage/lookup mechanism, which belongs to the dispatch-integration requirement
  (§2.1) that also decides how `PluginHandler` obtains a `registered_module()` at
  runtime.
- **Stage 2's registration-instantiation timeout's exact millisecond value** (§5.1 step
  6) — left as an ELIXIR-DEV implementation constant rather than fixed here, since no
  REQ-166 acceptance criterion depends on its magnitude, only that a bound exists.
- **The `{:unresolved_import, namespace, function}` string-parse's fragility** (§5.1
  step 7) — it matches the exact wording `wasmex` v0.15.1 produces live (§1.5); a future
  `wasmex` upgrade that changes that message's wording would silently fall through to
  the `{:crashed, raw_reason}` catch-all instead of the named-import shape (still a
  registration rejection either way — the catch-all is not a soundness gap, only a
  precision one). Flagged for whoever next touches `module_registry.ex` after a `wasmex`
  version bump, not resolved here.
