# REQ-171 — WASM host API 1/2: read path (`read_variable`, `log`, `now`, `uuid`) at parity with Lua (WASM-12 read half)

**Requirement:** REQ-171 (queue task 323, GH#623)
**Stage:** S5
**Owner (design):** CODE-DESIGNER
**Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-28
**Depends on:** REQ-170 (done), REQ-160 (done), REQ-150 (done)
**Consumes (unmodified):** `lib/letflow/engine/lua/platform.ex` (definition WASM
conforms to, per decision 0014 (4)), `Letflow.Engine.Wasm.ModuleRegistry` (REQ-166),
`Letflow.Engine.Wasm.MemoryGuard` (REQ-168), `Letflow.Engine.Wasm.ResourceLimits`
(REQ-169), `Letflow.Engine.LuaNumberMarshalling` (REQ-150),
`lib/letflow/design/req163-wasm-abi-choice.md` (REQ-163)
**Extends:** `Letflow.Engine.Wasm.CapabilityGate` (REQ-167) — additively, see §6
**Introduces:** `Letflow.Engine.Wasm.HostApi` (new module, this requirement)

This is a **design artefact only** — no implementation code. Every code sample below is
a type/signature description, never a function body.

---

## 0 — What this requirement is, restated from the handoff

REQ-166 through REQ-170 each built one independent WASM-side mechanism
(export/ABI validation, capability whitelisting, memory bounds-checking, fuel/memory
caps, wall-clock timeout) and each explicitly deferred "wiring these into a real host
function dispatch" to a future requirement. This is that requirement, for the **read**
quarter of WASM-12's seven-function host API: `read_variable`, `log`, `now`, `uuid`.
`write_variable`, `call_service`, `fail`, and the cross-runtime parity test suite are
REQ-172's.

Per decision 0014 (4): **the Lua host API is the definition WASM conforms to.** This
design changes nothing under `lib/letflow/engine/lua/`. Every semantic rule below is
read from `lib/letflow/engine/lua/platform.ex` (cited by line number as of commit
`7fd9911`) and restated for the WASM ABI, never re-derived.

---

## 1 — Live verification performed for this design (binding on ELIXIR-DEV)

Run with `export PATH="$HOME/.asdf/shims:$HOME/.cargo/bin:$PATH"` and
`WASMEX_BUILD=true`, `MIX_ENV=test mix run <script>`, against the real installed
`wasmex` v0.15.1 (`deps/wasmex/`, already vendored — `mix.lock` pins it, no network
access needed). Two scratch scripts were run and deleted afterward (not part of this
commit; not referenced by any test) — a temporary fixture
`priv/wasm_fixtures/req171_scratch_import.wat` (memory export + a `"hello"` data
segment + one export calling an imported `env.read_variable(0, 5)`) was used and
removed before commit.

**Finding 1 — the callback argument/context shape.** `deps/wasmex/lib/wasmex.ex`'s
`handle_info({:invoke_callback, ...})` (lines 541–582) is the actual dispatch path (not
the illustrative moduledoc doctest at lines 61–72, which mismatches the real context
map's key names — see Finding 4). Live-confirmed context shape, printed directly from a
running callback:

```
%{
  caller: #Wasmex.StoreOrCaller<...>,
  memory: #Wasmex.Memory<...>,
  pid: #PID<...>,
  instance: #Wasmex.Instance<...>
}
```

The callback is invoked as `apply(callback, [context | params])` — for a
`(param i32 i32)` import, `params` arrives as `[ptr, len]`, two plain Elixir integers
(not tagged, not wrapped) — confirmed live: a callback receiving `(context, ptr, len)`
printed `ptr = 0`, `len = 5` for a guest call passing WASM constants `i32.const 0` /
`i32.const 5`.

**Finding 2 — return shape depends on the declared result arity, and does NOT match
`tv-labs/lua`'s `{[term], lua}` convention.** The same `handle_info` clause
(`deps/wasmex/lib/wasmex.ex` lines 566–571) branches on the import's declared
`result_signature`: a zero-result import's callback return value is discarded
entirely; a **single**-result import's callback return value is wrapped by `wasmex`
itself into a one-element list; a multi-result import's callback must itself already
return a list, which `wasmex` passes through unchanged.

For a **single**-result import (every function this design defines), the callback
returns a **bare** Elixir value (an integer, for every result type this design uses —
all four functions return `:i32`) — `wasmex` itself wraps it in a one-element list.
Live-confirmed: a callback returning the bare integer `99` for a `[:i32]`-result import
produced `Wasmex.call_function/4` → `{:ok, [99]}`. **A callback must never return
`[99]}` itself for a single-result import** — that would be double-wrapped and is not
the shape this codebase's own `capability_gate.ex` stub (`fn _c, _a, _b -> 0 end`,
bare `0`) already uses; this design's real callbacks follow that same existing
convention, not `platform.ex`'s Lua-side `{[term], lua}` shape.

**Finding 3 — a callback that raises, or returns a value not matching the declared
result type, produces a clean `{:error, binary()}` from `Wasmex.call_function/4`, never
a crash, and the owning `Wasmex` GenServer stays alive.** Live-confirmed both cases
(the `handle_info` clause's own `rescue`/`catch` wraps the `apply/2` call):

```
mismatched-return-type result: {:error, "Error during function excecution: error while
  executing at wasm backtrace:\n    0: ... <wasm function 1>"}
raising-callback result: {:error, "Error during function excecution: error while
  executing at wasm backtrace:\n    0: ... <wasm function 1>"}
wasmex genserver still alive after raising callback?: true
```

Both failure modes produce the **same generic message shape** — a raising callback and
a type-mismatched return are **not distinguishable** from this string alone, and both
are indistinguishable from an ordinary in-guest Wasm trap (`unreachable`, out-of-bounds
load). Binding consequence for §5/§7 below: **every `HostApi` function this design
defines must be total and must never raise** — there is no way to signal "this specific
host function's own defect" back to the guest more precisely than an opaque trap, so
correctness must come from the callback body always returning a well-typed value,
never from relying on `wasmex` to surface a distinguishable error.

**Finding 4 — the memory/store handles a callback needs arrive on `context`, not via
closure capture of any store/instance value fixed at import-table-build time.**
`context.caller` (a live-wrapped `Wasmex.StoreOrCaller.t()`) and `context.memory` (a
live-wrapped `Wasmex.Memory.t()`) are exactly the two arguments
`Letflow.Engine.Wasm.MemoryGuard.read/4` and `.write/4` require as their first two
positional arguments. Live-confirmed: `Wasmex.Memory.read_binary(context.caller,
context.memory, 0, 5)` inside a running callback returned `"hello"`, the exact bytes
the guest's `(data (i32.const 0) "hello")` segment declared — and the same call
succeeds when routed through `MemoryGuard.read/4` instead (its own `@spec` accepts
exactly `(Wasmex.StoreOrCaller.t(), Wasmex.Memory.t(), integer(), integer())`, which
`context.caller`/`context.memory` satisfy verbatim). **`context.caller` MUST be used,
never a `store` captured at `build_import_table/2` time** — `wasmex`'s own moduledoc
warns a captured `store` can deadlock the call ("Wasmex might deadlock if the `store`
is used instead of the `caller`... because a Store processes one operation at a time,
and the current operation cannot finish until the imported function returns"). This
design's callbacks never close over a store/memory handle; they read both fresh off
`context` on every invocation, mirroring `MemoryGuard.read/4`/`.write/4`'s own
"caller supplies the live value, never cached" discipline (`req168` §4).

**Finding 5 — `capability_gate.ex`'s moduledoc doctest example (lines 61–72 of
`deps/wasmex/lib/wasmex.ex`) pattern-matches on `%{_memory: ..., _caller: ...}`
(leading-underscore key names), which do not exist on the real context map** (the real
keys are `memory`/`caller`, confirmed above and separately at lines 84–89 of the same
file, which give the correct key names without underscores). This is a `wasmex`
documentation inconsistency, not a Letflow defect — noted here so nobody "fixes"
`HostApi`'s callbacks to match the wrong, underscore-prefixed key names later.

**No re-entrant guest call from inside a host callback was attempted or is used by
this design.** `Wasmex.Instance.call_exported_function/6`
(`deps/wasmex/lib/wasmex.ex:537`) is `GenServer.call`-shaped (`from`, `timeout`,
routed back through the same GenServer's own mailbox) — calling it from inside a
callback already running on that GenServer's message-handling stack risks exactly the
same self-deadlock class `wasmex`'s own docs warn about for a captured `store`. This
design's ABI (§5) is built specifically so no host function ever needs to call a
guest's own `alloc` export mid-call — see §4.

---

## 2 — Number marshalling decision (AC6)

REQ-150 §2.1 (write direction) / §2.2 (read direction) is the one normative rule:
identity conversion for `integer()`/`float()`/`nil`, no subtype coercion, in either
direction. `Letflow.Engine.LuaNumberMarshalling.to_lua/1` (read direction) and
`.from_lua/1` (write direction) are the two named functions (`lib/letflow/engine/
lua_number_marshalling.ex`).

**Decision: `HostApi` reuses `Letflow.Engine.LuaNumberMarshalling.to_lua/1` directly —
no WASM-specific companion module.** Reasoning: `to_lua/1`'s own contract (identity for
numeric/`nil`, pass-through otherwise) is target-encoding-agnostic — it says nothing
about *how* the resulting term is subsequently serialized, only that no value-based
coercion happens on the way there. This design (§4) transports `read_variable`'s value
across the WASM boundary as **JSON bytes** (per `req163-wasm-abi-choice.md` §5's own
stated fallback: "where a value travels as JSON... it follows REQ-150 §2's JSON
encoding rules directly, with no separate WASM-level numeric rule needed" — chosen here
*because* a variable's value is not always numeric, so the bare `:i64`/`:f64`
register convention §5's table describes for a *numeric-only* host function does not
fit `read_variable`'s actual return type). `Jason.encode!/1` is what makes the
integer/float subtype visible on the wire (`Jason.encode!(5)` → `"5"`,
`Jason.encode!(5.0)` → `"5.0"`) — `to_lua/1`'s job is only to guarantee no coercion
happened *before* that encoding step, exactly as it already does for the Lua path's
`Lua.encode!/2` step (`platform.ex` line 599). One function, one call site pattern,
reused verbatim for the second ABI — no second numeric rule is introduced.

`from_lua/1` (write direction) is not exercised by this requirement (read-only); it
stays available, unused by name here, for REQ-172.

---

## 3 — `uuid`'s decision (AC5)

`uuid` has **no counterpart** in `platform.ex`'s 8-row `@capability_matrix` (lines
343–352) — confirmed by inspection: `call_service`, `read_variable`, `write_variable`,
`log`, `emit_event`, `get_instance_state`, `now`, `fail`, and nothing else. WASM-12's
own text names `uuid` as one of its seven WASM-side functions with no Lua analogue to
be "at parity with."

**Decision: implement `uuid` as a documented WASM-side addition, not parity.** Not a
Lua-side gap raised against this requirement's own scope, for three reasons stated
explicitly (not silently resolved):

PROVENANCE (historical, not current decision authority):
1. WASM-12's own acceptance text already scopes `uuid` as WASM-only; R-Co's
   `src/wasm/host_api/uuid.zig` (cited in `docs/requirements.yaml`'s REQ-171 entry) had
   no Lua-side sibling either — this asymmetry predates Letflow's migration, it is not
   something REQ-171 introduces.
2. `uuid` shares `now`'s own capability rationale (§4 below): a pure computation with
   no state reach, no tenant-data touch, no side effect — the same class `platform.ex`'s
   moduledoc gives for why `now`/`fail` are permanently ungated ("A pure time read with
   no state reach").
3. Implementing it does not require touching any Lua-side file (forbidden by the
   handoff) and does not require inventing a new capability vocabulary (§4 reuses the
   same `:none` mechanism `now` already needs).

**Candidate finding for ORCH, not resolved here:** whether Lua scripts should also gain
a `platform.uuid()` some future requirement adds is out of this requirement's scope —
flagged as an observation only, per the handoff's "raise it as a gap... a candidate
issue, not silently absorbed" instruction. This design does not open that issue itself;
it records the observation for ORCH to triage.

`HostApi.do_uuid/0`'s value is generated via `Ecto.UUID.generate/0` (already a
transitive dependency via `Ecto`, no new dependency) — canonical 36-character
hyphenated form, always exactly 36 bytes UTF-8, fixed length (relevant to §5.2's buffer
protocol: a guest can always supply an exactly-36-byte buffer with certainty of
success).

---

## 4 — Capability gating (AC7) — extends REQ-167's mechanism, introduces no second one

Per the handoff: `Letflow.Engine.Wasm.CapabilityGate.build_import_table/1`'s
manifest-derived whitelist is the **only** gating mechanism. Read directly
(`lib/letflow/engine/wasm/capability_gate.ex` lines 194–217): `build_import_table/1`
filters `@known_imports` by `MapSet.member?(granted, descriptor.capability)` and folds
matching descriptors into the `imports:` map `Wasmex.start_link/1` is instantiated
with. An import a guest declares but that is absent from this table fails
**instantiation** (per REQ-166/167's shared, live-verified crash-classification
mechanism) — the guest never runs at all if it imports something ungranted.

### 4.1 — The structural gap this design must close: `now`/`uuid` need to be ungated, but every current `@known_imports` row requires a granted capability to appear at all

`platform.ex`'s Lua-side `now`/`fail` rows use `required: :none` (line 350–351),
resolved by `required_capability/2`'s `defp required_capability(:none, _args), do:
:none` clause (line 490) — `Capabilities.check!/3` treats `:none` as an unconditional
pass, but the function is still **installed** into the Lua VM regardless of grant
state (line 474's `Enum.reduce` installs all 8 rows, always — gating happens per-call,
inside the wrapper, not at installation).

`CapabilityGate.build_import_table/1` has no equivalent: an entry not present in
`manifest.capabilities` is not present in the output map, full stop — there is no
"install unconditionally, gate per-call" mechanism on the WASM side, because WASM's
gate *is* import-table membership (§4.3 states the resulting cross-runtime behavioral
difference this causes; it is inherent to REQ-167's already-approved architecture, not
introduced or fixable by this requirement).

**This design's resolution: extend `@known_imports`' entry shape with the same `:none`
sentinel `platform.ex`'s own `required_capability_spec()` already uses, and make
`build_import_table/1,2`'s fold always include a `:none`-tagged descriptor regardless
of `manifest.capabilities`'s contents.** This is additive to the *same* mechanism
(`@known_imports` + one fold, `capability_gate.ex`'s own docs' words: "no second
capability model") — not a new registry, not a second whitelist. It mirrors
`platform.ex`'s own `:none` case in the *identical* one-matrix, one-fold shape,
applied to the one place WASM's gate actually lives.

### 4.2 — `import_descriptor()` type change (extends REQ-167's type, does not replace it)

```
@type capability_requirement :: capability() | :none
@type import_descriptor :: %{
        capability: capability_requirement(),   # was: capability() — widened, not narrowed
        namespace: String.t(),
        name: String.t(),
        params: [valtype()],
        results: [valtype()],
        stub: host_fn_spec()                     # NEW field — see §4.4
      }
```

`build_import_table/1`'s existing filter step becomes: a descriptor with
`capability: :none` is **always** included; a descriptor with `capability: "..."` is
included only when `MapSet.member?(granted, capability)` — the same rule
`required_capability/2`'s `:none`-vs-string branches already establish on the Lua side,
restated for a filter instead of a per-call check.

### 4.3 — Cross-runtime behavioral difference this causes, stated explicitly (not resolved, not silently absorbed)

An ungranted **Lua** call to a gated function raises `Lua.RuntimeException` at the
moment of that specific call — code before it in the same script has already run.
An ungranted **WASM** import causes the entire module to fail **instantiation** — no
guest code runs at all, not even code that never would have touched the ungranted
function. For any script this design's own tests exercise (one that only calls
functions it holds grants for), the two runtimes' observable behavior is identical.
For a script that imports/calls something it lacks a grant for, the two runtimes
diverge in **when** the denial surfaces (call-time vs. load-time) — this is inherited
from REQ-167's own already-gate-approved architecture (§4.1), not something REQ-171
introduces or is positioned to fix. Flagged for REVIEWER/SECURITY-REVIEWER as a known,
accepted, pre-existing divergence, restated here because this is the first requirement
whose own acceptance criteria (AC1) explicitly compare Lua/WASM behavior side by side.

### 4.4 — `@known_imports` real rows this requirement adds/changes

| `name` | `capability` | `params` | `results` | `stub` | Notes |
|---|---|---|---|---|---|
| `read_variable` | `"var:read"` | `[:i32, :i32, :i32, :i32]` | `[:i32]` | `:read_variable` | **Signature change** from REQ-167's placeholder `[:i32, :i32] -> [:i32]` (`capability_gate.ex` line 178–184, explicitly marked "illustrative... REQ-171/172 own the real ones") to the real 4-param buffer-out shape, §5.1. Capability token `"var:read"` is REQ-167's own existing literal (WASM-06's acceptance text) — reused verbatim, not renamed to Lua's `"variable:read"` (a pre-existing, already-diverged token space between the two runtimes' manifests — see §4.5). |
| `log` | `"audit:log"` | `[:i32, :i32, :i32, :i32, :i32, :i32]` | `[]` | `:log` | New row. Capability token chosen to match Lua's own literal (`platform.ex` line 66) — conceptually the same audit-emitting capability, even though the two runtimes' `manifest()` shapes are distinct data structures (§4.5). |
| `now` | `:none` | `[:i32, :i32]` | `[:i32]` | `:now` | New row, `:none`-gated per §4.1. |
| `uuid` | `:none` | `[:i32, :i32]` | `[:i32]` | `:uuid` | New row, `:none`-gated per §3/§4.1. |
| `platform_call_service` | `"service:call"` | *(unchanged)* | *(unchanged)* | *(unchanged placeholder)* | **Untouched — REQ-172's scope.** |

### 4.5 — Capability token space is per-runtime, not shared, by pre-existing design (not introduced here)

`CapabilityGate`'s own moduledoc (lines 106–113) already states its `manifest()` is
"Not `Letflow.Engine.Lua.Manifest`" — the two runtimes' capability manifests were
already distinct data structures before this requirement, and `@known_imports`' own
pre-existing token `"var:read"` (not `"variable:read"`) already diverged from Lua's
literal string. This design keeps that pre-existing divergence rather than silently
renaming a REQ-167 literal to match Lua — renaming would be an unrequested, out-of-scope
change to already-gate-approved code. `"audit:log"` is chosen to match Lua's literal
string anyway, since it is a *new* token this requirement introduces (no pre-existing
value to diverge from), for readability, not because token-string equality is a
correctness requirement anywhere in this design.

### 4.6 — `build_import_table/1` and the new `build_import_table/2`

Mirrors `platform.ex`'s own `install/1` → `install/2` → `install/3` layering exactly
(cited by name, §"Composition point" of `platform.ex`'s moduledoc), for the same
reason: existing callers must keep compiling unchanged, and the *real* per-function
bodies need a closed-over, caller-supplied context the pure whitelist-filter function
itself has no way to produce.

```
@spec build_import_table(manifest()) :: import_table()
```
Unchanged signature; now defined as
`build_import_table(manifest, HostApi.empty_execution_context())` — every entry's
callback becomes `HostApi`'s real dispatcher, closed over the *empty* context
(mirrors `platform.ex`'s `install/2`'s "existing callers still compile, observe the
empty-context behavior, never crash" property). `Letflow.Engine.Wasm.CapabilityGate`'s
own existing tests (REQ-167, unmodified) exercise only whitelist-membership /
instantiation success-or-failure — never a granted function's actual return value
(REQ-167's own moduledoc, "Placeholder registry" section) — so they continue to pass
against the empty-context dispatcher unchanged.

```
@spec build_import_table(manifest(), HostApi.execution_context()) :: import_table()
```
New. The real entry point this requirement's own tests (and any future
dispatch-integration caller) use — `execution_context` is captured once per call and
closed over by every installed callback for the lifetime of the returned
`import_table()`, exactly mirroring `platform.ex`'s `install/3`'s "closed over once,
fixed for the lifetime of the returned `Lua.t()`" property (moduledoc, "The single
registration point" section).

### 4.7 — Dispatch fold shape (design-level description, not code)

For each `@known_imports` row, `build_import_table/2`'s fold builds one
`{:fn, params, results, callback}` tuple whose `callback` is a closure of arity
`1 + length(params)` (`context`, then one argument per declared param — Finding 1)
that: (a) if `row.stub` names a real function (`:read_variable`/`:log`/`:now`/`:uuid`,
this requirement; `:call_service` stays the REQ-167 placeholder, REQ-172's job), calls
`HostApi`'s corresponding `do_*` function with `context` and the raw argument list,
closing over `execution_context`; (b) otherwise (any row this requirement does not
touch) preserves `CapabilityGate`'s existing `stub_callback/0` behavior unchanged. No
capability check runs inside this callback body — REQ-167's own architecture (§4.1)
already performed the only gating WASM ever gets, at import-table-construction time,
structurally prior to any guest code running at all.

---

## 5 — `HostApi` — the new module (`lib/letflow/engine/wasm/host_api.ex`)

`Letflow.Engine.Wasm.HostApi` is this requirement's equivalent of `platform.ex`'s
`do_read_variable/do_log/now` trio, adapted to the WASM ABI. REQ-172 adds
`do_write_variable`/`do_call_service`/`do_fail` to the same module (mirroring
`platform.ex` hosting both REQ-159's and REQ-160's implementations in one file).

### 5.1 — `execution_context()` — WASM's own, not a reuse of `Platform.execution_context()`

```
@type execution_context :: %{
        instance_id: String.t() | nil,
        prefix: String.t() | nil,
        trace_id: String.t() | nil,
        script_identity: String.t() | nil,
        variables: map()
      }

@spec empty_execution_context() :: execution_context()
```

Same field semantics as `platform.ex`'s `execution_context()` (line 316–323, minus
`actor_id`, not needed until REQ-172's `emit_event`-equivalent, if one is ever added —
open question, §8), but a **separate type**, not an alias or reuse of
`Letflow.Engine.Lua.Platform.execution_context()`. Reasoning: decision 0014 frames Lua
and WASM as two independent handler families (`plugin_interface.ex`'s own moduledoc,
"WASM plugins arrive as a **separate** handler family... not as a change to
`PluginInterface`'s contract") — coupling `HostApi`'s type to a Lua-internal type would
create a cross-runtime dependency decision 0014 does not call for, for a type with no
behavior attached (a bare map shape), where the cost of one duplicate type definition
is far lower than the cost of a load-bearing cross-module coupling.

**Tenant boundary (AC8, decision 0014 (e)):** identical statement to REQ-159's own —
"Host functions receive already-resolved values; the tenant prefix is supplied by the
calling engine code, never derived inside a script" (decision 0014 (e), quoted
verbatim). No function `HostApi` defines calls `Letflow.Repo` at all in this
requirement's scope (none of `read_variable`/`log`/`now`/`uuid` touches persistence —
`read_variable` is a plain lookup on `execution_context.variables`, exactly like
`platform.ex`'s own `do_read_variable`, design line 596's "no `Letflow.Repo` call,
ever"). `execution_context` itself is supplied by whatever future dispatch-integration
requirement calls `build_import_table/2` — never derived from a guest-supplied
argument, never read from guest memory.

### 5.2 — Shared string-return buffer protocol (AC2's "exact not-present representation")

Every WASM-side function that returns a string-shaped value to the guest
(`read_variable`, `now`, `uuid`) shares one protocol, chosen specifically to avoid the
re-entrant-guest-call hazard Finding 5 (§1) identifies: the **guest**, not the host,
owns buffer allocation. The guest supplies `(out_ptr: i32, out_cap: i32)`; the host
never calls the guest's own `alloc` export.

**Return value semantics — one `i32`, three disjoint ranges:**

- **`n >= 0`**: `n` is the exact byte length of the UTF-8-encoded result. If
  `out_cap >= n`, the host has already written those `n` bytes to `out_ptr` (via
  `MemoryGuard.write/4`) and the guest's buffer contains the value. If
  `out_cap < n`, the host has written **nothing** — the guest must call again with a
  buffer of at least `n` bytes. This is a single-channel "tell me how much room you
  need" protocol (the guest can always succeed in exactly two calls: one with
  `out_cap = 0` to learn `n`, one with a buffer of size `n`).
- **`-1`**: **`read_variable`-only.** The variable is not present in
  `execution_context.variables` — this is the chosen not-present representation
  (AC2/AC5's mandatory explicit statement). Never returned by `now`/`uuid` (both
  always have a value). No bytes are written to `out_ptr`.
- **`-2`**: invalid argument — either the *input* pointer/length pair
  (`read_variable`'s `name_ptr`/`name_len`) or the *output* pointer/length pair
  (`out_ptr`/`out_cap`) failed `MemoryGuard`'s bounds check (`{:error,
  {:invalid_pointer, _}}`), or (`read_variable` only) the name bytes read back are not
  valid UTF-8. No bytes are written to `out_ptr`. This is the one case that can occur
  for **every** function in this section (a guest can always pass a malformed
  `out_ptr`/`out_cap`), and it is the only case that surfaces a `MemoryGuard` failure
  to the guest at all — `HostApi`'s own functions never raise on it (Finding 3
  requires this).

When `out_cap = 0` is used as a length-probe, the host still validates `out_ptr`/`0`
via `MemoryGuard` before returning `n` (a zero-length bounds check still requires
`offset <= memory_size`, `MemoryGuard.check_bounds/3` step 3) — a probe call with a
genuinely invalid `out_ptr` still surfaces `-2`, not a silently-accepted `n`.

### 5.3 — `read_variable`

```
Import: env.read_variable
Params: [:i32, :i32, :i32, :i32]   # (name_ptr, name_len, out_ptr, out_cap)
Results: [:i32]                    # §5.2's shared return protocol, plus -1 (not present)
Capability: "var:read"
```

Algorithm (design-level, restates `platform.ex`'s `do_read_variable/3`, lines
596–607, at ABI parity):

1. `MemoryGuard.read(context.caller, context.memory, name_ptr, name_len)` — on
   `{:error, _}`, return `-2`.
2. If the resulting bytes are not valid UTF-8, return `-2` (Lua's own `do_read_variable`
   has no equivalent case — a Lua-side `name` argument is always a genuine Lua string;
   a WASM guest can supply arbitrary bytes, so this is a WASM-ABI-only defect class,
   not a Lua-parity divergence — no Lua call shape can ever produce it, so no parity
   test needs to cover the Lua side of this case).
3. `Map.fetch(execution_context.variables, name)` — `:error` → return `-1` (AC2's
   not-present case, parity with Lua's `nil`).
4. `{:ok, value}` → `value |> LuaNumberMarshalling.to_lua/1 |> Jason.encode!/1` → the
   UTF-8 JSON bytes → apply §5.2's buffer protocol.

**Noted, not tested, not a parity violation:** because the WASM ABI's "not found"
(`-1`) and "found, value is `nil`" (`n = 4`, the JSON text `"null"`) are two distinct
return values, `read_variable`'s WASM ABI can observe a distinction Lua's own
`do_read_variable` cannot (Lua's `nil` return is identical for both cases — line
603/607). This requirement's own AC2 only requires the same **two** outcomes Lua
supports ("current value for a set variable," "not-present... matching nil
semantics") — it does not require WASM to *lose* information it happens to carry as a
byproduct of a length-prefixed encoding. No test in this design's own scope exercises
a variable explicitly set to Elixir `nil` as a third case.

### 5.4 — `log`

```
Import: env.log
Params: [:i32, :i32, :i32, :i32, :i32, :i32]
         # (level_ptr, level_len, message_ptr, message_len, context_ptr, context_len)
Results: []
Capability: "audit:log"
```

Restates `platform.ex`'s `do_log/3` (lines 681–727) at ABI parity. Identity fields
(`script_identity`/`instance_id`/`trace_id`) are sourced **exclusively** from
`execution_context` — never from guest-supplied bytes, identical statement to
`platform.ex`'s own (lines 676–679, "a script controlling its own claimed identity
would defeat the point of an audit trail"). AC3's three fields, asserted individually
by TEST-DESIGNER's tests (§9 T3).

Algorithm:

1. `MemoryGuard.read` for `(level_ptr, level_len)` and `(message_ptr, message_len)`.
   A `MemoryGuard` failure on either **does not raise** — `do_log`'s own contract
   (Lua-side: "Never raises, regardless of argument shape," line 679) is restated
   here as: a bounds failure substitutes a fixed placeholder string
   (`"<invalid level pointer>"` / `"<invalid message pointer>"`) for the offending
   field and proceeds — `log` has no return-value channel to report failure through
   (`results: []`, matching Lua's `[]` return, line 695), so degrading gracefully
   rather than aborting the call is the only option that keeps "never raises" true.
2. `context_len == 0` → no context (mirrors Lua's `split_log_args/1` "fewer than 3
   args" branches, lines 705–708 — a WASM guest signals "no context" via zero length
   rather than a shorter argument list, since WASM's arity is fixed). Otherwise,
   `MemoryGuard.read` the context bytes and `Jason.decode!/1` them — on either a
   `MemoryGuard` failure or malformed JSON, `context` is logged as `nil` with an
   additional `context_decode_error: true` metadata key, never raising (mirrors
   `platform.ex`'s own defensive posture for a malformed argument shape, generalized
   to WASM's "arbitrary guest bytes" input class the Lua side never has to handle).
3. Level/message bytes: if not valid UTF-8, the raw binary is logged via `inspect/1`
   with metadata `raw_encoding: :invalid_utf8` (mirrors `platform.ex`'s own
   `log_text/1` non-binary fallback, line 726–727 — "anything not already a binary is
   rendered via `inspect/1`," generalized the same way as step 2).
4. Level mapping: identical table to `platform.ex`'s `map_log_level/1` (lines
   712–716) — `"debug"`/`"info"`/`"warn"`/`"error"` map as there; anything else maps
   to `:info` with `original_level` metadata (mirrors lines 720–724).
5. `Logger.log/3` with the same four metadata keys `platform.ex`'s `do_log/3` emits
   (`script_identity`, `instance_id`, `trace_id`, `context`), plus whichever of the
   two new degrade-gracefully metadata keys (`raw_encoding`/`context_decode_error`)
   apply.

Never raises, on any input — matches Finding 3's binding requirement and
`platform.ex`'s own stated contract (line 679).

### 5.5 — `now`

```
Import: env.now
Params: [:i32, :i32]   # (out_ptr, out_cap)
Results: [:i32]         # §5.2's protocol, minus the -1 case (always present)
Capability: :none
```

**Decision (AC4): `HostApi.do_now/0` calls `Letflow.Engine.Lua.Platform.now/0`
directly** — not a reimplementation, not a second `TimeSource` resolution. `now/0`
(`platform.ex` lines 361–368) already resolves the injectable `TimeSource` from
application env fresh on every call and formats it as ISO 8601 UTC; calling it
directly from `HostApi.do_now/0` guarantees byte-for-byte identical output between the
Lua and WASM call paths under the same injected clock double, which is the strongest
possible form of the parity AC4 requires ("the same injected clock... parity is
proven against a fixed time rather than two plausible-looking timestamps") — a
reimplementation could only ever prove two *independently correct* clocks agree, not
that they are *the same code path*. This does not modify `platform.ex` (calling its
already-public `now/0` introduces a new caller, not a change to the function) and does
not violate decision 0014's "neither runtime is given database access" boundary (no
`Repo` call anywhere on `now/0`'s path).

Algorithm: `iso8601 = Letflow.Engine.Lua.Platform.now()` → UTF-8 bytes (an ISO 8601
string is ASCII-only, so byte length == char length) → §5.2's buffer protocol
(`-2` only, never `-1`).

**Ungated by design, permanently — restated for WASM (mirrors `platform.ex`'s own
binding statement, lines 21–28).** `:none` is fixed in `@known_imports` (§4.4); no
future requirement should add a capability-gated row for `now` "by symmetry" with the
six gated functions, for the identical reason `platform.ex`'s moduledoc gives.

### 5.6 — `uuid`

```
Import: env.uuid
Params: [:i32, :i32]   # (out_ptr, out_cap)
Results: [:i32]         # §5.2's protocol, minus the -1 case (always present)
Capability: :none
```

Algorithm: `uuid = Ecto.UUID.generate()` (36 bytes, fixed) → UTF-8 bytes → §5.2's
buffer protocol (`-2` only). See §3 for the capability/parity decision.

---

## 6 — Public contract summary (`Letflow.Engine.Wasm.HostApi`)

```
@type execution_context :: %{...}   # §5.1

@spec empty_execution_context() :: execution_context()

@spec do_read_variable(
        context :: wasmex_callback_context(),
        name_ptr :: integer(), name_len :: integer(),
        out_ptr :: integer(), out_cap :: integer(),
        execution_context :: execution_context()
      ) :: integer()   # §5.3's three-range return

@spec do_log(
        context :: wasmex_callback_context(),
        level_ptr :: integer(), level_len :: integer(),
        message_ptr :: integer(), message_len :: integer(),
        context_ptr :: integer(), context_len :: integer(),
        execution_context :: execution_context()
      ) :: nil   # results: [] -- return value is discarded by wasmex regardless

@spec do_now(
        context :: wasmex_callback_context(),
        out_ptr :: integer(), out_cap :: integer()
      ) :: integer()   # §5.2's protocol, no -1 case

@spec do_uuid(
        context :: wasmex_callback_context(),
        out_ptr :: integer(), out_cap :: integer()
      ) :: integer()   # §5.2's protocol, no -1 case

@typedoc "The context map wasmex hands every callback -- Finding 1/4, never
constructed by this module, only pattern-matched."
@type wasmex_callback_context :: %{
        memory: Wasmex.Memory.t(),
        caller: Wasmex.StoreOrCaller.t(),
        pid: pid(),
        instance: Wasmex.Instance.t()
      }
```

Every `do_*` function's first argument is the raw `wasmex_callback_context()` (never
narrowed/renamed) so `MemoryGuard.read/4`/`.write/4` are called with `context.caller`/
`context.memory` directly, matching Finding 4 exactly. `execution_context` is always
the **last** argument (closed over by `CapabilityGate.build_import_table/2`'s fold —
§4.7 — not part of the guest-visible call signature at all; listed here only because
`build_import_table/2`'s generated callback partially-applies it before wasmex ever
sees the resulting arity).

**Cross-module dependency introduced by this requirement:**
`Letflow.Engine.Wasm.CapabilityGate` (REQ-167) gains a compile-time dependency on
`Letflow.Engine.Wasm.HostApi` (this requirement) — the reverse of REQ-167's own
moduledoc ("neither `module_registry.ex` nor `plugin_handler.ex` is modified by this
requirement... wiring... is a future dispatch-integration requirement's job").
`HostApi` has no dependency on `CapabilityGate` (the `do_*` functions take a raw
context + args + execution_context, never a `manifest()` or a `capability()`) — the
dependency is one-directional, `CapabilityGate → HostApi`, so `HostApi` stays testable
in complete isolation from the whitelist mechanism (§9).

**Invariants:**

- INV-HOSTAPI-1: no function this module defines calls `Letflow.Repo`, ever (§5.1).
- INV-HOSTAPI-2: no function this module defines raises, ever (Finding 3, binding).
- INV-HOSTAPI-3: every guest memory access goes through `MemoryGuard.read/4` or
  `.write/4` — never `Wasmex.Memory.*` directly (restates `memory_guard.ex`'s own
  AC1 grep-based invariant, `req168` §4, extended to this module by name).
- INV-HOSTAPI-4: `execution_context` is never constructed from guest-supplied bytes —
  always the value closed over at `build_import_table/2` call time.

---

## 7 — What this design deliberately does NOT do

- Does not modify `lib/letflow/engine/lua/platform.ex` or any file under
  `lib/letflow/engine/lua/` (forbidden by the handoff; no genuine semantic conflict
  surfaced during this design that would have required it — §5.3's "found vs. not
  found vs. found-and-nil" distinction is additive information, not a conflict).
- Does not wire `HostApi`/`CapabilityGate.build_import_table/2` into
  `Letflow.Engine.PluginInterface`'s dispatch path or into a real
  `Letflow.Engine.Wasm.PluginHandler`-equivalent — that remains a future
  dispatch-integration requirement's job (`capability_gate.ex`'s own moduledoc, design
  §8), unchanged by this requirement.
- Does not call `Letflow.Engine.Wasm.ResourceLimits.arm_fuel/2` or `build_store/1` —
  arming fuel/constructing the Engine/Store pair belongs to whatever code calls
  `Wasmex.start_link/1`/`Wasmex.call_function/4` in the first place (the same future
  dispatch-integration requirement), not to a host function's own callback body.
- Does not implement `write_variable`, `call_service`, `fail`, or the cross-runtime
  parity test suite — REQ-172.
- Does not resolve §4.3's cross-runtime instantiation-time-vs-call-time denial timing
  difference — inherited from REQ-167, flagged, not fixed.

---

## 8 — Open questions (explicit, not silently resolved)

- **OQ-1 (inherited from `platform.ex`'s own OQ-1):** no real caller threads a real
  `execution_context` into `build_import_table/2` yet — same "deferred to a future
  dispatch-integration requirement" gap `platform.ex`'s own moduledoc already states
  for the Lua side (`install/3`'s real caller).
- **OQ-2:** whether a future WASM `emit_event`-equivalent (if one is ever added,
  REQ-172 or later) needs `execution_context.actor_id` — not added to `execution_context()`
  here since nothing in this requirement's scope needs it; adding it later is a
  strictly additive map-field change, not a breaking one.
- **OQ-3:** whether `uuid` should ever gain a Lua-side counterpart — explicitly not
  this requirement's decision (§3's "candidate finding for ORCH").
- **OQ-4:** §4.3's instantiation-time-vs-call-time capability-denial timing difference
  is stated, not resolved — whether it ever needs resolving (e.g. a future
  "pre-flight capability check before instantiation, independent of import-table
  membership" mechanism) is left to REVIEWER/SECURITY-REVIEWER to judge, not decided
  here.

---

## 9 — Test strategy and traceability (design-level; TEST-DESIGNER writes the real specs)

**Fixture:** one new `.wat` fixture, `priv/wasm_fixtures/req171_host_api.wat`,
exporting `memory` and one guest function per host function under test (e.g.
`call_read_variable(name_ptr, name_len, out_ptr, out_cap) -> i32`,
`call_log(level_ptr, level_len, message_ptr, message_len, context_ptr, context_len)
-> ()`, `call_now(out_ptr, out_cap) -> i32`, `call_uuid(out_ptr, out_cap) -> i32`),
each a thin guest-side re-export of a call to the corresponding `env.*` import with
the guest's own arguments forwarded verbatim — this lets the Elixir test driver
control every pointer/length pair directly via `Wasmex.call_function/4`, and read the
guest's own linear memory afterward (directly via `Wasmex.Memory.read_binary/4`, from
the *test's own process*, not from inside a host callback — no re-entrancy concern
applies to a test driver) to assert on bytes written by the host.

**Parity mechanism (AC1, AC4):** each of `read_variable`/`log`/`now` is driven
**twice** from the same fixed `execution_context`-equivalent inputs (same `variables`
map / same injected `Platform.TimeSource` double / same `instance_id`/`trace_id`/
`script_identity`) — once through `Letflow.Engine.Lua.Sandbox.new/1` +
`Letflow.Engine.Lua.Platform.install/3` + `Lua.eval!/2` calling `platform.*`, once
through `CapabilityGate.build_import_table/2` + the new `.wat` fixture +
`Wasmex.call_function/4` calling `env.*` — and the two decoded observable outcomes
(Lua's decoded return value; WASM's `Jason.decode!/1`-decoded buffer contents) are
asserted equal.

| REQ-171 acceptance criterion (`docs/requirements.yaml`, verbatim) | Test(s) |
|---|---|
| AC1: "for each of read_variable, log, and now, a test asserts the WASM-side semantic behaviour matches the Lua-side behaviour REQ-159 and REQ-152 established -- same inputs, same observable outcome, differing only in ABI representation" | T1 (read_variable parity), T4 (log parity), T6 (now parity) — dual-drive strategy above |
| AC2: "a test asserts read_variable returns the current value for a set variable and a defined not-present representation for an unset one, matching the Lua side's nil semantics under the chosen ABI's return shape" | T1 (set variable → `n >= 0`, buffer contains correct JSON), T2 (unset variable → `-1`) |
| AC3: "a test asserts log emits a structured entry carrying script/module identity, instance ID, and trace ID -- the same three fields LUA-13 requires, asserted individually" | T3 — capture logged metadata (e.g. via a custom `:logger` handler or `ExUnit.CaptureLog`-equivalent with structured metadata capture), assert `script_identity`/`instance_id`/`trace_id` each individually against the fixed `execution_context` values used |
| AC4: "a test asserts now returns a value parseable as the same ISO 8601 UTC instant the Lua side returns for the same injected clock, so parity is proven against a fixed time rather than two plausible-looking timestamps" | T6 — `Application.put_env(:letflow, :lua_platform_time_source, <fixed double>)`, assert both `platform.now()` (Lua) and `env.now`'s buffer contents (WASM) equal the same exact string |
| AC5: "the moduledoc states that uuid has NO counterpart in R-Co's eight-function Lua host API matrix, and records the explicit decision taken (implemented as a documented WASM-side addition, or raised as a Lua-side gap) rather than presenting it as parity" | T7 — `HostApi`'s moduledoc text assertion (grep/doc-content check) + T8 — `do_uuid` returns a well-formed, unique 36-byte UUID string on two successive calls |
| AC6: "the number conversion is REQ-150's named module and function; the moduledoc cites REQ-150's normative section by number and introduces no second rule, and a test round-trips an integer and a float asserting the subtype matches that rule" | T9 — round-trip: a variable set to an integer and a variable set to a float, each read via `env.read_variable`, `Jason.decode!/1` the returned buffer, assert `is_integer/1`/`is_float/1` matches the original subtype (mirrors REQ-150's own subtype-preservation test shape) |
| AC7: "capability gating for these functions comes from REQ-167's manifest-derived whitelist; no second capability model is introduced, shown by the moduledoc naming REQ-167 as the source" | T10 — a manifest lacking `"var:read"` produces an import table with no `read_variable` entry (or: instantiating a guest that imports it fails, mirroring REQ-167's own AC1/AC3 test shape); T11 — a manifest with **no** capabilities still yields a working `now`/`uuid` (the `:none` rows, §4.1) |
| AC8: "no host function calls Letflow.Repo with a prefix derived from guest-supplied input; the moduledoc states the tenant prefix is supplied by the calling engine code, per decision 0014 (e)" | T12 — `grep -rn 'Letflow.Repo' lib/letflow/engine/wasm/host_api.ex` returns no hits (structural, mirrors `memory_guard.ex`'s own AC1 grep-based test shape) |
| AC9: "mix test and mix compile --warnings-as-errors both pass with real output quoted" | Not a design element — TEST-RUNNER's job once ELIXIR-DEV implements this design |

**Additional design-only test notes:**

- T5: `-2` (invalid argument) case for `read_variable`/`now`/`uuid` — an out-of-bounds
  `out_ptr`/`out_cap` pair (e.g. `out_ptr` beyond the guest's declared memory size)
  returns `-2` and writes nothing (assert via re-reading the guest's own memory at a
  sentinel location unaffected by the call).
- T13 (Finding 3's binding requirement, defensive): no test should ever observe a raw
  Elixir exception or a linked `:EXIT` from any `HostApi.do_*` call driven directly
  (not through `wasmex` at all) with malformed arguments (e.g. a negative offset) —
  every `do_*` function is directly unit-testable without a running `Wasmex` instance
  for its non-memory-touching branches (mirrors `MemoryGuard.check_bounds/3`'s own
  "callable with fabricated integers alone" design, `memory_guard.ex` lines 63–72).

---

## Deliverables Summary

| Item | Result |
|---|---|
| New module | `Letflow.Engine.Wasm.HostApi` (`lib/letflow/engine/wasm/host_api.ex`) |
| Extended module | `Letflow.Engine.Wasm.CapabilityGate` — `@known_imports` real rows, `import_descriptor()` widened, new `build_import_table/2` |
| Unmodified | `lib/letflow/engine/lua/**`, `module_registry.ex`, `plugin_handler.ex`, `plugin_interface.ex`, `resource_limits.ex` |
| `read_variable` not-present representation | `-1` (§5.2) |
| `uuid` decision | WASM-side addition, no Lua twin, `:none`-gated (§3) |
| Number marshalling | Reuses `LuaNumberMarshalling.to_lua/1` directly, REQ-150 §2.2 (§2) |
| Capability source | `CapabilityGate.build_import_table/1,2`, extended with a `:none` sentinel mirroring `platform.ex`'s own (§4) |
| Tenant boundary | Decision 0014 (e); `execution_context` closure-captured at `build_import_table/2` call time, never guest-derived (§5.1) |
| Live-verified `wasmex` findings | §1, Findings 1–5 |
