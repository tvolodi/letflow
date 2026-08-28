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
— a plain string reason, not a raised exception. **This is the operation REQ-166's
validator performs — compile, never instantiate** (§4 below explains why that
distinction is what makes "never invocable" structural rather than by-convention).

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

Namespace → name → `export_info()`, same tuple shapes as §1.3. **Out of REQ-166's scope**
(import whitelisting is REQ-167's — see req163 §4) — named here only because it is the
same static, pre-instantiation primitive family as `exports/1`, confirming the general
finding: `wasmex` exposes full export *and* import introspection on a compiled-but-not-
instantiated `Wasmex.Module`, so a registration-time check never needs to instantiate
(start a `Wasmex`/Wasmtime instance) to inspect either.

### 1.5 Why `Wasmex.start_link/1` is deliberately NOT used for validation

Live-tested: calling `Wasmex.start_link/1` on a module with an unresolved import
produces `{:error, {{:badmatch, {:error, "unknown import: ... has not been defined"}},
stacktrace}}` — a real, working `{:error, _}` return (confirmed both with and without
`Process.flag(:trap_exit, true)` in the calling process — `GenServer.start_link/3`'s
`:proc_lib` handshake absorbs the init-time crash into an ordinary `{:error, reason}`
value, it does not leak an `:EXIT` signal to a non-trapping caller). This means
`start_link/1` *could* technically double as an import-resolution check, but REQ-166
does not use it for two reasons: (a) it is REQ-167's concern, not this requirement's
scope (req163 §4 / the `NOT IN THIS REQUIREMENT` list), and (b) using `compile/2` +
`exports/1` (§1.2/§1.3) instead means the validator **never calls `start_link/1` on an
untrusted module at all** — which is the load-bearing fact §4's "never invocable" proof
rests on.

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

### 2.2 Moduledoc content (maps to AC6/AC "moduledoc" bullet)

`Letflow.Engine.Wasm.ModuleRegistry`'s moduledoc must state, verbatim in substance:

- This module implements WASM-02's registration-time rejection.
- The five required exports (`init`, `execute`, `deinit`, `get_capabilities`, `alloc`)
  and the required `memory` export are req163-wasm-abi-choice.md §3.1/§3.2's contract,
  cited by section number — not re-derived here, and this module has no authority to
  change that contract.
- Core modules, not the component model, per req163's Decision — this module never
  calls anything under `Wasmex.Components`.
- Validation is by static export-section introspection (`Wasmex.Module.compile/2` +
  `Wasmex.Module.exports/1`, §1.2/§1.3) — the module is never instantiated
  (`Wasmex.start_link/1` is never called) as part of registration, which is *why*
  rejection is structural rather than conventional (§4).

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
  The structured rejection reason (AC "structured error", not a bare string).
  `defects` is always non-empty for `:invalid_abi` and lists EVERY defect found in one
  pass, not just the first (§5.2) — the same "one test case per required export" the
  requirement's AC2 implies is only satisfiable by a caller if this shape doesn't stop
  at the first miss.
  """
  @type registration_error ::
          {:invalid_abi, defects :: [export_defect()]}
          | {:compile_error, reason :: binary()}

  @typedoc "Opaque handle to a module that has passed registration. See §4."
  @opaque registered_module :: %__MODULE__.RegisteredModule{
            module: Wasmex.Module.t(),
            bytes: binary()
          }

  @doc """
  The single entry point registration goes through. Never instantiates the module
  (never calls `Wasmex.start_link/1`) — see §1.5/§4. Returns `{:ok, registered_module()}`
  only when all five function exports and the `memory` export in req163 §3.1/§3.2 are
  present with exactly the required kind and signature; otherwise
  `{:error, registration_error()}` naming every defect found.
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
`lib/letflow/` obtains a `registered_module()` value is `register/1`'s `{:ok, _}` branch.

---

## 4 — Proof: a rejected module is never invocable

**Claim:** no code path exists from a failed `register/1` call to `Wasmex.call_function/4`
(or `Wasmex.start_link/1`, its necessary predecessor).

**Structural argument, not a prose assertion:**

1. `register/1` (§3) is the only function in `Letflow.Engine.Wasm.ModuleRegistry` that
   constructs a `registered_module()` value, and it does so only on its `{:ok, _}`
   branch — the `{:error, registration_error()}` branch returns no struct, opaque or
   otherwise, that wraps the compiled module.
2. `RegisteredModule`'s `@opaque` annotation means no module outside
   `Letflow.Engine.Wasm.ModuleRegistry` may pattern-match or build one directly against
   its fields (Dialyzer/`mix compile --warnings-as-errors` flags an opaque-type violation
   if one tries) — a caller cannot forge a `registered_module()` from raw bytes to route
   around a rejection.
3. The only two functions in the entire `wasmex` dependency that can start a runnable
   instance are `Wasmex.start_link/1` and `Wasmex.Instance.new/3` (per
   `deps/wasmex/lib/wasmex.ex` / `deps/wasmex/lib/wasmex/instance.ex`) — REQ-166's
   design commits every future invocation call site (§2.1) to accepting only a
   `registered_module()` as its source of bytes/module, never a bare `binary()` sourced
   from outside `ModuleRegistry`. `register/1` itself never calls either function
   (§1.5) — it calls only `Wasmex.Store.new/0` and `Wasmex.Module.compile/2` (§1.1/§1.2),
   neither of which instantiates anything or resolves an import.
4. Therefore: the only way `binary()` module bytes reach `Wasmex.start_link/1` anywhere
   `Letflow` owns is via a `registered_module()` that `register/1` issued — which only
   happens after every §3.1/§3.2 export check passed. A module that fails `register/1`
   never produces that value, so no downstream code — including `PluginHandler`'s own
   `run_guest/2` once the dispatch-integration requirement wires registration in front
   of it — has anything to call `start_link/1` or `call_function/4` with.

This is provable today at the type level (opaque type + single-constructor-function
discipline) even before the dispatch-integration requirement exists to wire it in; §2.1
already states `PluginHandler` itself is not modified by REQ-166, so the "never
invocable" property for THIS requirement's own deliverable concerns the boundary
`ModuleRegistry` establishes, not a claim that `PluginHandler`'s current, pre-registry
code path is already gated (it structurally is not yet, and REQ-166's own scope note
says so is not required until the dispatch-integration requirement exists).

---

## 5 — Validation algorithm (design-level, no implementation)

### 5.1 Steps

1. `Wasmex.Store.new/0` — a fresh store per registration attempt (never reused across
   modules; stores are cheap per §1.1's doc).
2. `Wasmex.Module.compile(store, bytes)` (§1.2). On `{:error, reason}`, return
   `{:error, {:compile_error, reason}}` immediately — a syntactically-invalid module has
   no export section to check.
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
   constructs a module missing more than one export in a single test).
6. Empty defect list → `{:ok, %RegisteredModule{module: module, bytes: bytes}}`.
   Non-empty → `{:error, {:invalid_abi, defects}}`.

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
| 1 | "a test registers a module missing the execute export and asserts registration fails with a structured error naming the missing export" | §3 `registration_error()` / `export_defect() :: {:missing, "execute"}`; §5.1 step 4 |
| 2 | "a test asserts a module missing EACH of the other required exports is likewise rejected — one test case per required export" | §5.2 table (all six required export names); §5.1 step 5 (defects collected per-export, not stop-on-first) |
| 3 | "a test asserts rejection happens at REGISTRATION and not at invocation: a non-conforming module is never invocable" | §2.1 (decoupled entry point) + §4 (structural "never invocable" proof) |
| 4 | "a test asserts a conforming module registers successfully and is then invocable" | §3 `register/1`'s `{:ok, registered_module()}` branch; §3.1 (the only path to a value a future invocation call site accepts) |
| 5 | "the moduledoc names the export contract implemented and cites REQ-163's artefact as its source" | §2.2 |
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
