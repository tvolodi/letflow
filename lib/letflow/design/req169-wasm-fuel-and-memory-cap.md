# REQ-169 — WASM fuel budget and linear-memory cap per invocation (WASM-09, WASM-10)

**Requirement:** REQ-169 (WASM-09, WASM-10, both MUST)
**Stage:** S5
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-28
**Depends on:** REQ-168 (`lib/letflow/engine/wasm/memory_guard.ex`, gate-approved,
cited in §5's layered-defense argument); consumes REQ-165's process-boundary/
crash-classification precedent (`req165-wasmex-process-boundary.md` §4/§7) and
REQ-166/167's `classify_crash/1` convention (`module_registry.ex`,
`capability_gate.ex`); reads decision 0014's WASM-09/WASM-10 text and its own quoted
`wasmex`/`Wasmtime` evidence directly, not as restated by any later design.

This is a design artefact — `@spec`/`@type` signatures and prose only, no function
bodies. See `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1.

---

## 0 — Why this design's structure is dominated by one finding, and how to read it

The handoff's mandatory live-verification turned up a **second real divergence** in
this project's now-consistent discipline of live-checking every `wasmex` claim
(REQ-165 through REQ-168 already found one node-crashing hazard at REQ-168; this
requirement finds a different kind of divergence — not a crash, but a **silent
behavioral mismatch** between WASM-10's literal acceptance-criterion wording and what
`Wasmtime`/`wasmex` actually do). **§1 records every live probe and is the load-bearing
section**; §2 designs the module around what §1 actually found, not around decision
0014's or WASM-10's un-verified wording. §7 states the divergence explicitly per this
handoff's AC7/verification-item requirement — it is not worked around silently
anywhere in this document.

**All probes are reproducible** at `scratch/req169_fuel_memory_probe.exs` (git-ignored
per `core-directives.md`'s scratch rule, not a shipped artefact) — ELIXIR-DEV or a
future auditor can re-run it verbatim with:

```
export PATH="$HOME/.asdf/shims:$HOME/.cargo/bin:$PATH"
WASMEX_BUILD=true MIX_ENV=test mix run scratch/req169_fuel_memory_probe.exs
```

against the real installed `wasmex` v0.15.1 dependency, no test framework involved,
every risky call wrapped in `Task.Supervisor.async_nolink/2` under the already-running
`Letflow.Engine.PluginTaskSupervisor` bounded by `Task.yield/2`, exactly mirroring
REQ-165/166/167/168's own established live-verification pattern.

---

## 1 — Live verification findings (session of 2026-08-28, real installed `wasmex` v0.15.1)

### 1.1 Fuel metering genuinely bounds an infinite loop, and delivers a clean `{:error, string}` — never a crash, never a hang

Fixture (mirrors `req165_hang.wat`'s unconditional-branch shape exactly):

```
(module
  (func (export "hang")
    (loop $forever
      br $forever)))
```

Enabling fuel via `Wasmex.EngineConfig{consume_fuel: true}`, building a `Store` against
that engine, calling `Wasmex.StoreOrCaller.set_fuel(store, 1_000)`, then
`Wasmex.call_function(pid, "hang", [], 10_000)` (a generous 10s `wasmex`-level timeout,
deliberately never allowed to be the thing that fires):

```
{:ok,
 {:error,
  "Error during function excecution (wasm trap: all fuel consumed by WebAssembly): error while executing at wasm backtrace:\n    0:     0x21 - <unknown>!<wasm function 0>"}}
```

(Outer `{:ok, ...}` is `Probe.run_in_task`'s own `Task.yield` outcome — the task
completed normally; the inner `{:error, "..."}` is `Wasmex.call_function/4`'s return.)
**Confirms:** fuel exhaustion surfaces as an ordinary `{:error, binary()}` return from
`Wasmex.call_function/4` through the normal call path — no exception, no `:exit`
signal, no process crash, and (control probe, same fixture with `consume_fuel: false`
and no `wasmex`-level timeout override, only a short *outer* task timeout) **without**
fuel enabled the identical loop genuinely never returns on its own (outer probe result:
`:timeout`) — so fuel is doing real, load-bearing work, not merely mirroring the outer
task boundary's own timeout.

**Exact distinguishing substring:** `"all fuel consumed by WebAssembly"`, embedded
inside `wasmex`'s own `"Error during function excecution (wasm trap: ...)"` wrapper
string. This is a raw, unstructured Elixir binary — `wasmex` does not return a
tagged/structured error term for a trap, matching the same "wasmex returns bare
strings, never structured terms" finding REQ-166/167/168 already made for other
`wasmex` call sites. This design's own public contract (§4) wraps this into a
structured atom via substring classification, per this project's already-established
`classify_crash/1`-style convention (`module_registry.ex`, `capability_gate.ex`) —
substring-matching a raw string, not inventing a new technique.

### 1.2 A fresh `set_fuel/2` call before each invocation genuinely resets the budget — and, precisely, the omission this AC warns about is itself live-reproduced

Same fixture, same `Store`, three consecutive calls to `"hang"`:

| Step | Action | Result |
|---|---|---|
| 1 | `set_fuel(store, 1_000)`, then call `"hang"` | traps: `"...all fuel consumed by WebAssembly..."` |
| 2 | `get_fuel(store)` immediately after step 1 | `{:ok, 0}` — confirms the budget really was fully consumed, not merely reported as trapped while fuel remained |
| 3 | Call `"hang"` again **without** calling `set_fuel/2` again | traps identically (0 fuel remaining — this invocation was genuinely starved by the previous one, reproducing exactly the failure mode the requirement's own text warns about: "a budget that is not reset between invocations lets invocation N starve invocation N+1") |
| 4 | `set_fuel(store, 1_000)` again, then call `"hang"` a third time | traps identically to step 1 (same backtrace offset `0x21`, i.e. the same number of wasm instructions executed as the very first call) — **the budget was genuinely restored to its full value**, not merely "some fuel," proving the reset is exact, not partial |

**Confirms, precisely and directly (not by assumption):** `wasmex`/`Wasmtime` fuel is
**not** auto-reset per `call_function/4` invocation — omitting `set_fuel/2` before a
call genuinely starves it (step 3), exactly as the requirement's cautionary text
predicts. The mechanism this design mandates (§2/§4) — an explicit `set_fuel/2` call
immediately before every single guest invocation, never once at `Store`-creation time
only — is not optional convenience; it is the only thing standing between this
requirement's AC2 and a real, reproduced starvation bug.

### 1.3 `set_fuel/2` itself cleanly fails, with a distinguishable string, when `consume_fuel` was left at its documented `false` default — this is the mechanism AC5 is built on

```
Wasmex.EngineConfig{consume_fuel: false} → Store.new(nil, engine)
Wasmex.StoreOrCaller.set_fuel(store, 10)
#=> {:error, "Could not set fuel: fuel is not configured in this store"}
Wasmex.StoreOrCaller.get_fuel(store)
#=> {:error, "Could not get fuel: fuel is not configured in this store"}
```

**Confirms:** calling `set_fuel/2` unconditionally before every invocation (§1.2's
mandate) doubles as a **structural configuration-integrity canary** for AC5. If a
future code change accidentally leaves `EngineConfig.consume_fuel` at its `false`
default, `set_fuel/2` itself fails immediately, with a distinguishable string
(`"fuel is not configured in this store"`, never confusable with the exhaustion-trap
string `"all fuel consumed by WebAssembly"`), **before the guest ever runs** — rather
than the guest completing silently unbounded, which is exactly the hazard decision
0014 and this requirement's own text flag ("a configuration that forgets it produces
an unlimited guest with no error anywhere"). §4's public contract makes this failure a
hard `{:error, :fuel_not_configured}` outcome, never swallowed.

### 1.4 A tighter fuel budget measurably and reproducibly binds sooner than a looser one — via a memory counter that survives the trap

`wasmex`'s trap does not return the guest's own last local-variable state (locals are
lost on trap, per ordinary Wasm semantics), so proving "tighter binds sooner" needs an
observable that survives the trap: a guest that writes its own loop counter into linear
memory on every iteration, read back via `Wasmex.Memory.read_binary/4` **after** the
call traps (per REQ-168 §1.5/§1.1's already-established finding that a `Store`/
`Memory` handle remains valid and readable after a call returns, trap included).

Fixture:
```
(module
  (memory (export "memory") 1)
  (func (export "count_forever")
    (local $i i32)
    (local.set $i (i32.const 0))
    (loop $again
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (i32.store (i32.const 0) (local.get $i))
      (br $again))))
```

| Fuel budget | Call result | Iterations completed (memory offset 0, little-endian i32, read after the trap) |
|---|---|---|
| 20 | traps (`"...all fuel consumed..."`) | **3** |
| 2,000 | traps (`"...all fuel consumed..."`) | **250** |

**Confirms AC4's fuel half directly and quantitatively:** a 100x looser budget yields
roughly 83x more completed guest work before trapping (not an exact ratio — `loop`/
`br`/`i32.add`/`i32.store` each cost differing fuel units per Wasmtime's own internal
accounting, which this design does not need to characterize further) — the tighter
value unambiguously binds sooner, live-measured, not assumed.

### 1.5 `StoreLimits.memory_size` genuinely, physically bounds guest memory growth — the SECURITY property WASM-10 cares about is real and confirmed

Fixture:
```
(module
  (memory (export "memory") 1 10)
  (func (export "grow_by") (param $delta i32) (result i32)
    local.get $delta
    memory.grow))
```

With `%Wasmex.StoreLimits{memory_size: 2 * 65_536}` (cap = 2 pages; guest starts at 1
page, its own declared max is 10 pages):

| Call | Result |
|---|---|
| `grow_by(1)` (reaches the cap exactly: 1 → 2 pages) | `{:ok, [1]}` (memory.grow's own convention: returns the *previous* page count on success) |
| `grow_by(5)` immediately after (would reach 7 pages, exceeding the 2-page cap) | `{:ok, [-1]}` |
| Real physical memory size (`Wasmex.Memory.size/2`), measured before and after the *rejected* `grow_by(5)` attempt | **unchanged**, `65536` bytes (1 page) in a fresh instance with only the failing call attempted — the growth attempt left zero trace on real memory size |
| Same `grow_by(5)` call against an **identical fixture with no `StoreLimits` at all** (module's own declared max of 10 pages is the only bound) | `{:ok, [1]}` (succeeds — 1 → 6 pages) |
| A tighter cap (2 pages) vs a looser cap (5 pages), both starting at 1 page, repeatedly calling `grow_by(1)` until failure | tighter cap allows **1** successful additional page; looser cap allows **4** — AC4's memory-cap half, confirmed quantitatively |
| Instantiating a module whose **initial** declared memory (3 pages) already exceeds a 1-page `StoreLimits.memory_size` cap | the `Wasmex.start_link/1` `GenServer.init/1` callback itself fails, and (because nothing wraps this in a monitored task in this design's own probe) surfaces as a **linked `:exit`** — `{:badmatch, {:error, "memory minimum size of 3 pages exceeds memory limits"}}` — matching REQ-166/167's already-documented "unresolved-import-style crash, not a clean return" finding for `Wasmex.start_link/1` failures generally; **the underlying Wasmtime-level message itself is a clean string** (`"memory minimum size of 3 pages exceeds memory limits"`), it is only `Wasmex.start_link/1`'s own `GenServer.init/1` `{:ok, ...}`-only contract that turns any `Store.new`/`Module.compile`/instantiate failure into a crash — an already-known, already-designed-for shape (§3 addresses this explicitly for `ResourceLimits`'s own store-construction responsibility) |

**Confirms:** the cap genuinely, physically binds — a guest cannot make its real linear
memory exceed the configured `memory_size`, regardless of what value it requests or
what its own module-declared maximum says. This is the property WASM-10's *intent*
("Linear memory growth MUST be capped per module instance") needs, and it holds.

### 1.6 THE DIVERGENCE: `memory.grow` beyond the cap does **NOT trap** — it returns a clean, ordinary success with WebAssembly's own `-1` "growth failed" sentinel, and the guest's execution continues completely normally

This is the header row of §1.5's table, stated on its own because it is this
document's central finding. Re-quoted for emphasis: `grow_by(5)` attempted against a
2-page cap (already at 1 page, would need to reach 6) returns

```
{:ok, [-1]}
```

**not** `{:error, ...}`, **not** a wasm trap, **not** any shape resembling §1.1's fuel-
exhaustion error at all. The call **succeeds** from every layer's point of view —
`Wasmex.call_function/4` returns its ordinary `{:ok, [result]}` success shape, the
guest function returns normally (no trap, no abnormal termination), and the guest's
*own* code continues executing exactly as if nothing unusual happened, because
returning `-1` from a failed `memory.grow` **is** WebAssembly's own standard,
specification-defined behavior for that instruction — it is not a `wasmex`/Wasmtime
peculiarity, and it is not something a `StoreLimits` cap changes about `memory.grow`'s
calling convention. Verified further: if the guest's *own* code checks the `-1`
sentinel and deliberately executes `unreachable` on seeing it, **that** produces a real
trap (`"wasm trap: wasm \`unreachable\` instruction executed"`) — but this is a
guest-authored, guest-cooperative behavior, not something the host or the
`StoreLimits` mechanism forces. An adversarial guest — this platform's threat model,
stated explicitly in decision 0014 Reasoning (a) — has no obligation to check `-1` and
can simply ignore it and keep running with its unchanged (correctly capped) memory.

---

## 2 — What §1 changes about this design: two independent mechanisms, one honest contract

**Fuel (§1.1-§1.4): mechanism matches decision 0014's/WASM-09's description exactly.**
Enable `consume_fuel`, call `set_fuel/2` fresh before every invocation, treat a trap
containing `"all fuel consumed by WebAssembly"` as fuel exhaustion, treat
`set_fuel/2`'s own `{:error, "...fuel is not configured..."}` as a hard configuration
failure. No divergence on this half; §1.2/§1.3 sharpen the *exact* mechanism (when to
call `set_fuel/2`, what its own failure means) beyond what decision 0014's prose said,
but nothing here contradicts it.

**Memory cap (§1.5-§1.6): the SECURITY property (a guest's real memory cannot exceed
the cap) holds; the FAILURE-VISIBILITY property WASM-10's literal wording assumes
("Attempt to grow beyond cap MUST TRAP") does NOT hold.** This design does not invent
a trap that does not exist, and does not silently redefine "trap" to mean "returns
-1" without saying so (per the handoff's explicit instruction). Instead:

1. **This design configures and exposes the real, live-verified mechanism** —
   `Wasmex.StoreLimits.memory_size` (and, for parity/completeness, `table_elements`,
   though this requirement's acceptance criteria only test memory) — as a first-class,
   required, configurable part of building the `Store` every guest invocation uses.
2. **This design does NOT claim the cap produces a trap or a structured host-visible
   error merely by being hit.** §4's public contract instead exposes a function that
   lets a caller **observe** whether the cap bound (comparing real `Wasmex.Memory.size/
   2` before and after an invocation, or a lower-level helper wrapping a raw `-1`
   `memory.grow` return into a structured term for any host function that itself calls
   `memory.grow` on the guest's behalf) — but this design does not fabricate detection
   of an event the guest itself did not report and the runtime does not signal.
3. **AC3's test (§5) is written against what actually happens**, not against the
   requirement's un-verified "traps cleanly" wording: it asserts (a) the guest's own
   `grow_by`-style call returns cleanly (`{:ok, [-1]}` — a *success* shape, stated as
   such, not miscast as an error) and (b) the real, physical memory size is unchanged
   before and after, which is the actual, load-bearing guarantee this mechanism
   provides. This is recorded as a deliberate, documented departure from the literal
   AC3 wording, per this handoff's own instruction to name divergences rather than
   quietly design around them — see §7 for the required, ORCH-facing statement.
4. **The layered-defense argument, tying this design to REQ-168's `MemoryGuard`:**
   because real memory size never exceeds the configured cap (§1.5, confirmed), and
   REQ-168's `MemoryGuard.read/4`/`write/4` always fetch the *real, current* memory
   size fresh via `Wasmex.Memory.size/2` on every single host-side access (never
   cached — `req168-wasm-memory-isolation.md` §2 step 2), **any host function that
   later tries to dereference an offset the guest computed under the false assumption
   that its `memory.grow` request succeeded is still caught and cleanly rejected by
   `MemoryGuard`**, regardless of whether the guest itself checked `-1`. WASM-10's
   underlying security intent — a guest cannot make the host touch memory beyond the
   configured cap — is therefore satisfied by the **combination** of this
   requirement's `StoreLimits` cap (bounds what the guest's own linear memory can
   physically become) and REQ-168's already-shipped `MemoryGuard` (bounds what the
   *host* will ever read/write against that memory) — not by this requirement's
   mechanism alone producing a trap it does not, in reality, produce.

---

## 3 — Module location: `Letflow.Engine.Wasm.ResourceLimits`

Per the handoff's instruction and this project's established one-module-per-
orthogonal-concern precedent (`req155-lua-wallclock-kill.md` §4.4;
`req166-wasm-module-abi-validation.md` §2.2; `req167-wasm-import-whitelist.md` §0;
`req168-wasm-memory-isolation.md` §3): fuel/memory-cap configuration at
instantiation time is a distinct concern from `ModuleRegistry`'s export validation,
`CapabilityGate`'s import whitelisting, `PluginHandler`'s dispatch, and
`MemoryGuard`'s per-call pointer validation. None of the four existing modules builds
an `Engine`/`Store` pair with resource limits attached; this is a new, fifth concern.

**Decision: `Letflow.Engine.Wasm.ResourceLimits`, new file
`lib/letflow/engine/wasm/resource_limits.ex`.**

**Scope boundary, stated explicitly:** this module owns *constructing* a correctly
configured `Wasmex.Engine`/`Wasmex.StoreOrCaller` pair (fuel enabled, `StoreLimits`
attached) and *arming* a per-invocation fuel budget (the `set_fuel/2` call §1.2/§1.3
show must happen fresh before every call). It does **not** own dispatching a guest
call (`PluginHandler`'s job, REQ-165), does **not** own building the import table
(`CapabilityGate`'s job, REQ-167), and does **not** own validating pointer/length pairs
against the resulting memory (`MemoryGuard`'s job, REQ-168) — this module produces the
`Store` those other modules' callers pass into `Wasmex.start_link/1` as the `:store`
key (confirmed accepted directly, `deps/wasmex/lib/wasmex.ex:228-248`), it does not
itself call `Wasmex.start_link/1`. **Wiring `ResourceLimits`'s output into
`PluginHandler`'s/`CapabilityGate`'s actual instantiation call is a future
dispatch-integration requirement's job**, mirroring REQ-166/167/168's identical
"wiring is out of this design's scope" boundary — this requirement's own acceptance
criteria are all satisfiable by testing `ResourceLimits` directly against fixtures, per
§5, exactly as REQ-168's `MemoryGuard` was tested directly with no REQ-171/172 host
function existing yet.

---

## 4 — Public contract: `Letflow.Engine.Wasm.ResourceLimits`

```
defmodule Letflow.Engine.Wasm.ResourceLimits do
  @typedoc "Caller-supplied, per-guest-invocation resource configuration -- AC4's
  required configurability. `fuel_budget` and `memory_cap_bytes` are the two
  configurable knobs this requirement names; `table_elements_cap` is included
  for StoreLimits parity (decision 0014's own evidence names it alongside
  memory_size) but is untested by this requirement's own acceptance criteria
  -- see the Open Questions (S7) for its status."
  @type config :: %{
          required(:fuel_budget) => pos_integer(),
          required(:memory_cap_bytes) => pos_integer(),
          optional(:table_elements_cap) => pos_integer()
        }

  @typedoc "Why building the Engine/Store pair itself failed -- distinct from
  any later per-invocation outcome (arm_fuel/2, classify_call_result/1
  below). :store_limits_rejected covers a StoreLimits value Wasmtime itself
  refuses (e.g. an initial declared memory already exceeding memory_cap_bytes
  at instantiation time, S1.5's live-verified crash shape -- surfaced here as
  a classified, structured term per the same classify_crash/1 convention
  module_registry.ex/capability_gate.ex already established, never a bare
  crash escaping this module)."
  @type build_defect ::
          {:engine_build_failed, raw_reason :: term()}
          | {:store_build_failed, raw_reason :: term()}
          | {:store_limits_rejected, {:crashed, raw_reason :: term()}}

  @doc """
  Builds a fresh Wasmex.Engine configured with `consume_fuel: true` (S1.1 --
  never left at its documented `false` default) plus a fresh Wasmex.Store
  built against that engine and the given `Wasmex.StoreLimits` (memory_size
  from config.memory_cap_bytes, table_elements from
  config.table_elements_cap when present). Returns the pair together because
  a Store's fuel/limit behavior is bound to the Engine it was built from
  (S1's probes always build both together, never reused across configs) --
  callers must not build a Store against an unrelated Engine and expect this
  module's other functions' guarantees to hold.

  Per S1.5's crash-shape finding: a StoreLimits value Wasmtime itself
  rejects at instantiation time (e.g. a guest whose declared initial memory
  already exceeds memory_cap_bytes) surfaces as a linked `:exit` from
  whatever process calls the eventual `Wasmex.start_link/1` -- exactly like
  REQ-166/167's already-documented `Wasmex.start_link/1` failure shape. This
  function itself only builds the Engine/Store pair (Wasmex.Engine.new/1,
  Wasmex.Store.new/2), which S1's probes show fail with a clean {:error,
  binary()} on a malformed EngineConfig/StoreLimits, not a crash -- the
  instantiation-time crash risk belongs to whatever later calls
  Wasmex.start_link/1 with the returned store (PluginHandler/CapabilityGate,
  a future wiring requirement's concern, not this function's).
  """
  @spec build_store(config()) ::
          {:ok, {Wasmex.Engine.t(), Wasmex.StoreOrCaller.t()}} | {:error, build_defect()}

  @typedoc "Why arming fuel before an invocation failed -- AC5's own
  mechanism. :fuel_not_configured is S1.3's live-verified finding: set_fuel/2
  itself fails cleanly, with this distinguishable reason, when the Engine
  the Store was built from did not have consume_fuel: true -- this is what
  makes a config that silently leaves fuel metering disabled fail loudly
  here, before any guest code runs, rather than allowing an unbounded guest
  through silently."
  @type arm_fuel_defect :: {:fuel_not_configured, raw_reason :: binary()}

  @doc """
  MUST be called with a fresh `fuel_budget` immediately before every single
  guest invocation against `store` -- never once at Store-creation time only
  (S1.2's live-reproduced starvation finding: omitting this call before
  invocation N+1 genuinely starves it on whatever fuel invocation N left
  behind, down to and including 0). Thin wrapper over
  Wasmex.StoreOrCaller.set_fuel/2, translating its own {:error, binary()}
  return into the structured arm_fuel_defect() shape (S1.3) rather than
  passing the raw wasmex string through -- this project's structured-error
  convention (module_registry.ex, capability_gate.ex, memory_guard.ex) never
  surfaces a bare wasmex string as a caller-facing reason.
  """
  @spec arm_fuel(Wasmex.StoreOrCaller.t(), fuel_budget :: pos_integer()) ::
          :ok | {:error, arm_fuel_defect()}

  @typedoc "The structured, caller-facing classification of a completed
  Wasmex.call_function/4 outcome, distinguishing three shapes this design's
  own live verification confirmed are textually distinct and always will
  be, by construction, since they come from three different wasmex/Wasmtime
  code paths (S1.1's fuel-trap wrapper string; a ordinary Wasm runtime trap
  unrelated to fuel/memory such as `unreachable` or an out-of-bounds
  load/store; and this module's own memory-cap observation, S1.6, which is
  NOT a wasmex-reported error shape at all -- see the doc note below).
  Deliberately does NOT include a timeout/interruption variant: a
  wasmex-level or outer-task-level timeout is a distinct code path this
  module never touches (REQ-165's `handle_yield_result/4` `nil` clause
  produces its own `{:error, \"...did not respond within Nms\"}` shape,
  textually distinguishable from both classifications below by construction
  -- neither string contains the word \"fuel\" or \"trap\"), and REQ-170's
  future wall-clock mechanism is explicitly out of this module's
  classification scope (AC6)."
  @type call_classification ::
          :fuel_exhausted
          | {:trap, raw_message :: binary()}
          | :ok

  @doc """
  Classifies an already-completed `Wasmex.call_function/4` return value
  (never calls it itself -- this module does not dispatch guest calls,
  PluginHandler/CapabilityGate's job) into one of `call_classification()`'s
  three shapes, by substring-matching the raw wasmex string per this
  project's already-established classify_crash/1-style convention
  (module_registry.ex, capability_gate.ex): `{:error, reason}` where
  `reason` contains \"all fuel consumed by WebAssembly\" classifies as
  `:fuel_exhausted` (S1.1's exact string); any other `{:error, reason}`
  classifies as `{:trap, reason}` (a real Wasm trap unrelated to fuel --
  e.g. an unreachable instruction, an out-of-bounds memory access
  MemoryGuard did not itself intercept because it came from guest-internal
  code rather than a host function's pointer/length pair); any other return
  (including `wasmex`'s own success shape, `{:ok, results}`) classifies as
  `:ok`.

  Does NOT classify a memory-cap breach as a distinct case, because S1.6
  live-verified there is nothing in a Wasmex.call_function/4 return to
  classify: memory.grow beyond StoreLimits.memory_size returns a plain
  Wasm-spec-standard `-1` success value, indistinguishable at this
  function's level from any other successful i32 return. A caller needing
  to know whether a memory-cap bound was hit during a call must use
  memory_grew_within_cap?/3 (below) instead, comparing real memory size
  before/after -- this is the honest consequence of S1.6's finding, not an
  omission.
  """
  @spec classify_call_result(term()) :: call_classification()

  @doc """
  The memory-cap observation this design's own honesty (S2 item 2) commits
  to providing in place of a trap that does not exist: compares the real,
  live-fetched `Wasmex.Memory.size/2` value captured by the caller BEFORE
  an invocation against the value captured AFTER, and reports whether the
  growth (if any) stayed within `memory_cap_bytes`. This is a pure
  arithmetic comparison over two already-known integers -- it does not
  itself call `Wasmex.Memory.size/2` (the caller must fetch both, exactly
  the same "caller supplies the live value, this module never caches or
  re-fetches" discipline `MemoryGuard.check_bounds/3` already established,
  req168-wasm-memory-isolation.md S4). Returns `:within_cap` whenever
  `size_after <= memory_cap_bytes` (covers both "did not attempt to grow"
  and "grew, but stayed within the cap"); `:capped` when `size_after ==
  size_before` despite the guest's own code having attempted (from the
  caller's outside knowledge, not observable from these two integers alone)
  a larger grow -- callers that cannot independently confirm an attempt was
  made should treat `:within_cap` as the only fact this function actually
  proves (memory did not exceed the cap), not as proof no attempt occurred.
  """
  @spec memory_grew_within_cap?(
          size_before :: non_neg_integer(),
          size_after :: non_neg_integer(),
          memory_cap_bytes :: pos_integer()
        ) :: :within_cap | :capped
end
```

**Why `arm_fuel/2` and `classify_call_result/1` are separate from `build_store/1`
rather than one do-everything function:** `build_store/1` runs once per `Store`
lifetime (or once per invocation, if a future wiring requirement chooses fresh-Store-
per-call, mirroring `PluginHandler`'s existing per-call `Wasmex.start_link/1` pattern —
this design does not decide that; see §7 OQ-1); `arm_fuel/2` MUST run immediately
before every single invocation regardless of `Store` lifetime (§1.2); and
`classify_call_result/1` runs after a call already completed, on a value this module
never itself produced. Collapsing these into one function would hide the exact
"before every call, not just once" timing requirement §1.2 makes load-bearing.

---

## 5 — Test strategy

No REQ-171/172 host function exists yet — per this project's established precedent
(REQ-168's `MemoryGuard` tests, `req168-wasm-memory-isolation.md` §5), tests exercise
`ResourceLimits` directly against dedicated fixtures.

### 5.1 New fixtures, `priv/wasm_fixtures/`

- `req169_hang.wat` — identical shape to `req165_hang.wat` (an unconditional `br`
  loop), duplicated as a permanent fixture under this requirement's own name rather
  than reaching across into REQ-165's fixture file, mirroring REQ-168's choice to add
  its own dedicated fixture rather than reuse `req165_trivial.wat`.
- `req169_counting.wat` — the §1.4 loop-with-memory-counter fixture, permanent.
- `req169_grow.wat` — the §1.5/§1.6 `grow_by(delta)` fixture, permanent, declaring a
  generous own-module max (10 pages) so every test's binding constraint is
  `ResourceLimits`'s configured cap, never the fixture's own declared ceiling.

### 5.2 AC1/AC5 — fuel metering genuinely bounds an infinite loop and is genuinely enabled

1. `build_store(%{fuel_budget: 1_000, memory_cap_bytes: 65_536})`, `arm_fuel/2` with
   that budget, dispatch `req169_hang.wat`'s `"hang"` export via a supervised task
   (mirroring `PluginHandler`'s own dispatch pattern) bounded by a generous outer
   timeout: assert the guest call itself returns within that bound (not a `:timeout`
   outer-task outcome) and `classify_call_result/1` on the raw result returns
   `:fuel_exhausted` — this is AC1's own "infinite loop terminates within budget" and
   AC5's "fuel metering is actually enabled," proven by the same test (a loop that ran
   to completion under budget rather than hanging IS the proof fuel metering was live).
2. **AC5's negative counterpart:** `build_store/1` with a config this module
   deliberately does NOT allow to skip fuel (per §2 item 1, `consume_fuel: true` is
   never optional/configurable — only the budget's *value* is, per AC4) — so AC5's
   "silently leaves `:consume_fuel` false" scenario is asserted at a different layer:
   a test calls `Wasmex.EngineConfig{consume_fuel: false}` directly (bypassing
   `build_store/1` deliberately, to simulate what a hypothetical regression would
   produce) and confirms `arm_fuel/2` against a `Store` built from THAT engine returns
   `{:error, {:fuel_not_configured, _}}` rather than silently succeeding — proving the
   canary property (§1.3) actually fires if `build_store/1`'s own
   `consume_fuel: true` were ever accidentally dropped in a future edit.

### 5.3 AC2 — fuel resets per invocation

Using one `Store` across two consecutive invocations of `req169_hang.wat`: `arm_fuel/2`
with a fixed budget, dispatch, assert `:fuel_exhausted`; `arm_fuel/2` **again** with the
identical budget, dispatch a second time, assert `:fuel_exhausted` again — and (the
discriminating assertion, since two `:fuel_exhausted` classifications alone do not by
themselves prove the second invocation got a *full* budget rather than a partial
leftover one) using `req169_counting.wat` instead of `req169_hang.wat` for this
specific case: assert the loop-iteration counter (read from memory after each trap,
§1.4's technique) is **equal** across both invocations (within the deterministic
range Wasmtime's own fixed instruction-cost accounting produces — S1.2's live
reproduction found byte-for-byte identical backtrace offsets across repeats, so an
exact equality assertion, not merely "roughly equal," is warranted and should be
asserted as such).

### 5.4 AC3 — memory-cap behavior, tested honestly per §2 item 3

1. `build_store(%{fuel_budget: 100_000, memory_cap_bytes: 2 * 65_536})` (2-page cap;
   `req169_grow.wat` starts at 1 page); dispatch `grow_by(1)`: assert `{:ok, [1]}` and
   `classify_call_result/1` on it returns `:ok` (reaches the cap exactly — a legal
   grow, not a breach).
2. Dispatch `grow_by(5)` (would reach 7 pages against the 2-page cap): assert the raw
   return is `{:ok, [-1]}` — **stated in the test's own assertion/comment as the
   Wasm-spec-standard growth-failure sentinel, explicitly NOT miscast as an error** —
   and `classify_call_result/1` on it still returns `:ok` (per §4's contract: this
   function has nothing else to classify it as, by design, since `wasmex` itself
   reports a clean success).
3. Capture `Wasmex.Memory.size/2` before step 2's call and again after; assert
   `memory_grew_within_cap?/3` on those two values returns `:within_cap`, and assert
   the two raw byte values are **equal** (the real, physical memory did not grow at
   all — the load-bearing security property this requirement actually delivers).
4. **AC3's own wording ("traps cleanly") is not asserted as written** — this test file
   must carry a comment citing this design's §1.6/§7 finding, so a future reader does
   not conclude the omission is an oversight.

### 5.5 AC4 — both knobs are configurable, and the tighter one binds sooner

1. **Fuel:** dispatch `req169_counting.wat` twice under two different `ResourceLimits`
   configs (`fuel_budget: 20` and `fuel_budget: 2_000`); assert both classify as
   `:fuel_exhausted` and the tighter config's surviving memory counter is strictly
   less than the looser config's (§1.4's live values, 3 vs 250, establish the order of
   magnitude to expect — an exact-value assertion is acceptable since Wasmtime's fuel
   accounting is deterministic per §1.2's finding, but the test should assert the
   inequality primarily, with the exact counts as a secondary/regression check).
2. **Memory:** dispatch repeated `grow_by(1)` calls against two different
   `memory_cap_bytes` configs (2 pages and 5 pages) until each first returns `-1`;
   assert the tighter config permits strictly fewer successful grows than the looser
   one (§1.5's live values, 1 vs 4, establish the expected order).

### 5.6 AC6 — three classifications are pattern-match-distinguishable from each other and from a future wall-clock timeout

A single test asserting, side by side: `classify_call_result/1` on a captured
fuel-exhaustion result is `:fuel_exhausted`; on a captured guest-authored
`unreachable`-trap result (a small dedicated fixture, or reuse of §5.4's -1-checking
guest-authored-trap probe pattern from §1.6) is `{:trap, msg}` where `msg` does **not**
contain the substring `"fuel"`; and that neither shape can ever equal (via `===`)
`PluginInterface`'s own `{:error, "...did not respond within " <> _}` timeout string
(REQ-165 `plugin_interface.ex`'s existing, unmodified `handle_yield_result/4` `nil`
clause) — asserted by construction (none of the three strings/atoms can textually
collide) rather than by exercising REQ-170's not-yet-built mechanism.

### 5.7 AC7 — the divergence itself is asserted as documented, not merely narrated in prose

A `moduledoc =~ ...`-style test (mirroring `req165`/`req168`'s own precedent for
asserting disclosure content) confirming `Letflow.Engine.Wasm.ResourceLimits`'s
moduledoc contains the §7 divergence statement's key phrase (e.g. "does NOT trap").

---

## 6 — Moduledoc content (AC7)

Required moduledoc content for `Letflow.Engine.Wasm.ResourceLimits`, verbatim in
substance (ELIXIR-DEV may adjust prose flow but must preserve every factual clause):

> This module configures WASM-09's fuel-based execution limit and WASM-10's
> linear-memory cap, both per `docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md`'s
> direct `wasmex` analogues (`Wasmex.EngineConfig.consume_fuel`,
> `Wasmex.StoreLimits.memory_size`). Both mechanisms were live-verified against the
> real installed dependency, not assumed from documentation
> (`lib/letflow/design/req169-wasm-fuel-and-memory-cap.md` §1).
>
> **Fuel metering behaves as decision 0014 and WASM-09 describe:** an infinite guest
> loop genuinely terminates within its configured budget, surfacing as a clean
> `{:error, "...all fuel consumed by WebAssembly..."}` return — never a crash, never a
> hang (§1.1). The budget is NOT reset automatically between invocations — omitting a
> fresh `arm_fuel/2` call before a call genuinely starves it on whatever fuel the
> previous call left behind, live-reproduced (§1.2) — so this module's contract
> requires `arm_fuel/2` immediately before every single invocation, not once at
> `Store`-creation time.
>
> **DIVERGENCE FROM WASM-10's LITERAL WORDING, LIVE-VERIFIED, NOT WORKED AROUND
> SILENTLY.** WASM-10 reads "Attempt to grow beyond cap MUST TRAP." The real,
> live-verified behavior is that `memory.grow` beyond `StoreLimits.memory_size` does
> **NOT** trap: it returns WebAssembly's own standard `-1` growth-failure sentinel, an
> ordinary successful call return, and the guest's own execution continues completely
> normally (§1.6). The SECURITY property WASM-10 cares about — a guest's real linear
> memory cannot be made to exceed the configured cap — IS live-verified true (§1.5):
> `StoreLimits.memory_size` physically, unconditionally bounds real memory growth
> regardless of what the guest requests or its own module-declared maximum allows.
> Decision 0014's own quoted evidence ("Growing a linear memory beyond this limit will
> fail") was itself accurate; it is WASM-10's own restatement of that as "MUST TRAP"
> that this live verification found does not hold. This module does not fabricate a
> trap that does not occur; `classify_call_result/1` correctly reports a capped-growth
> attempt as an ordinary success, and `memory_grew_within_cap?/3` is the mechanism this
> module provides instead, to let a caller confirm the cap held by comparing real
> memory size directly. Any host function that later dereferences an offset a guest
> computed under a false assumption that its `memory.grow` succeeded is still protected
> — independently — by `Letflow.Engine.Wasm.MemoryGuard`'s own fresh-every-call bounds
> check (REQ-168), which never trusts a guest's own bookkeeping.

---

## 7 — Explicit divergence statement for ORCH (AC7 / handoff verification item)

**Finding, stated plainly:** WASM-10's acceptance criterion ("Module attempting to
allocate beyond cap traps cleanly") and decision 0014's own restatement of it ("MUST
TRAP") do **not** match live-verified `wasmex`/Wasmtime behavior. `memory.grow` beyond
a configured `StoreLimits.memory_size` cap returns WebAssembly's own standard `-1`
failure sentinel — an ordinary, successful call return — and does not trap, crash, or
produce any Wasmex-level `{:error, _}` at all. This was found by direct live
verification (`scratch/req169_fuel_memory_probe.exs`, probes 3/6/10, §1.5-§1.6 above),
not assumed from decision 0014's documentation-sourced text, which is exactly the gap
this handoff instructed closing.

**What is NOT affected:** the underlying security guarantee — a guest cannot make its
real linear memory exceed the configured cap — is independently, separately confirmed
true (§1.5) and is not weakened by this finding. Fuel metering (WASM-09) was also
live-verified and found to match its documented/decision-0014-described behavior
exactly (§1.1-§1.4), with no divergence.

**What this design does about it, so ORCH does not need to re-derive the response:**
this design does not silently redefine "trap" to mean "-1 return," and does not
silently drop AC3's test coverage — §5.4 specifies a test asserting the real, honest
behavior (a clean success return plus an unchanged real memory size), with an explicit
in-test comment citing this finding so a future reader is not left to wonder whether
the divergence from AC3's literal wording is an oversight. §6 requires the same
finding be stated in the shipped module's own moduledoc, permanently, not only in this
design document. No workaround, reinterpretation, or quiet redesign was applied
without stating it here first.

---

## 8 — Open questions this design leaves for ELIXIR-DEV, stated rather than guessed

- **OQ-1 — Store lifetime: per-invocation fresh `Store`, or one long-lived `Store`
  reused across invocations of the same module instance?** `PluginHandler`'s existing
  pattern (REQ-165) is a fresh `Wasmex.start_link/1` per call, implying a fresh
  `Store` per call too — under that pattern `arm_fuel/2`'s "before every invocation"
  requirement is trivially satisfied (a fresh `Store` starts at 0 fuel regardless, so
  it must always be armed before its one and only call anyway). If a future
  performance requirement introduces `Store` reuse/pooling (decision 0014 (e)'s
  named future concern), `arm_fuel/2`'s "immediately before every call, not just
  once" requirement becomes load-bearing rather than automatically satisfied — this
  design's contract is written to hold under either lifetime, but does not itself pick
  one; wiring (a future requirement, per §3) decides.
- **OQ-2 — `table_elements_cap`'s test coverage.** `StoreLimits.table_elements` is
  configurable per `config()`'s optional field (parity with decision 0014's own
  named evidence), but this requirement's acceptance criteria only test the memory
  half; no test in §5 exercises `table_elements_cap`. Not blocking — the field exists
  for forward compatibility, live-verification of table-growth trapping/capping
  behavior is left to whichever future requirement first needs it.
- **OQ-3 — should `classify_call_result/1` special-case the guest-authored
  `unreachable`-on-`-1` pattern (§1.6) as anything other than an ordinary `{:trap,
  msg}`?** Not done here: that trap is guest-authored code choosing to signal its own
  failure, indistinguishable at the host level from any other guest `unreachable`, and
  no acceptance criterion asks for a distinct classification.
- **Where `ResourceLimits.build_store/1`'s output is actually wired into
  `PluginHandler`/`CapabilityGate`'s real `Wasmex.start_link/1` call** — out of scope
  here per §3, mirroring REQ-166/167/168's identical "wiring is a future dispatch-
  integration requirement's job" boundary.

None of these open questions block implementation.

---

## 9 — Traceability: REQ-169's 8 real acceptance criteria (`docs/requirements.yaml`) → design elements → planned tests

| # | Acceptance criterion (verbatim) | Design element | Planned test(s) (§5) |
|---|---|---|---|
| 1 | "a test asserts an infinite-loop guest terminates within its configured fuel budget rather than hanging, which is WASM-09's own acceptance criterion" | §1.1 (live finding); §4 `build_store/1`+`arm_fuel/2`+`classify_call_result/1` | §5.2 test 1 |
| 2 | "a test asserts fuel is reset per invocation: two consecutive invocations of the same module each get the full budget, so the second is not starved by the first" | §1.2 (live finding, including the reproduced starvation-if-omitted case); §4 `arm_fuel/2`'s "before every call" contract | §5.3 |
| 3 | "a test asserts a guest attempting to grow linear memory beyond the configured cap traps cleanly and the caller receives a structured error, which is WASM-10's own acceptance criterion" | §1.5/§1.6 (live finding: does NOT trap); §2 item 3 (honest test design); §4 `memory_grew_within_cap?/3` | §5.4 (tests the real behavior; §7 records the divergence from this criterion's literal wording) |
| 4 | "both the fuel budget and the memory cap are configurable (not hardcoded literals), and a test drives two different values for each and asserts the tighter one binds sooner" | §4 `config()` (`fuel_budget`, `memory_cap_bytes`); §1.4/§1.5 (live-measured tighter-binds-sooner evidence for both) | §5.5 |
| 5 | "a test asserts fuel metering is actually enabled -- e.g. that a guest exceeding the budget errors rather than completing -- so a configuration that silently leaves :consume_fuel at its false default fails the suite" | §1.3 (live finding: `set_fuel/2` itself fails cleanly and distinguishably when `consume_fuel` is false); §4 `arm_fuel/2`'s `:fuel_not_configured` canary | §5.2 tests 1-2 |
| 6 | "fuel exhaustion and memory-cap trap surface as errors distinguishable by pattern match from each other and from REQ-170's wall-clock timeout" | §4 `call_classification()` type; §1.1/§1.6 (live-confirmed distinct string shapes; memory-cap is not an error shape at all, stated honestly) | §5.6 |
| 7 | "if either mechanism does not behave as decision 0014's documentation-sourced evidence describes, the divergence is recorded in the moduledoc and reported, not worked around silently" | §7 (explicit ORCH-facing statement); §6 (required moduledoc content) | §5.7 (moduledoc-content test) |
| 8 | "mix test and mix compile --warnings-as-errors both pass with real output quoted" | Not a design element — an ELIXIR-DEV/TEST-RUNNER obligation; §4's plain tagged-tuple/atom types (no opaque/dynamic typing) give both commands something meaningful to enforce | N/A |

### Handoff-specific meta-criteria (from this WF-02 run's own handoff, not in `docs/requirements.yaml` itself)

| Handoff AC | Design element |
|---|---|
| AC1 (handoff) — exact mechanism + live-verified error/trap shape for fuel exhaustion | §1.1; §4 `call_classification()`'s `:fuel_exhausted` |
| AC2 (handoff) — how/when `set_fuel/2` is called to guarantee per-invocation reset, live-verified | §1.2; §4 `arm_fuel/2`'s contract |
| AC3 (handoff) — exact live-verified error/trap shape for the memory cap | §1.5/§1.6; §2 item 2-3; §7 |
| AC4 (handoff) — exact configuration surface; tighter-binds-sooner test for both | §4 `config()`; §5.5 |
| AC5 (handoff) — exact mechanism for asserting fuel metering is enabled | §1.3; §4 `arm_fuel/2`'s `:fuel_not_configured` |
| AC6 (handoff) — exact distinguishing shapes for fuel/memory-cap/future-timeout, live-verified | §4 `call_classification()`; §5.6 |
| AC7 (handoff) — moduledoc-content section records any divergence found, state plainly whether one was found | §6; §7 (yes — the memory-cap trap divergence was found, stated in full) |
| AC8 (handoff) — types/signatures give `mix test`/`mix compile --warnings-as-errors` something to enforce | §4 (plain, non-`term()`-heavy tagged tuples and enumerated atoms throughout) |
| "Zero literal Elixir code in the design doc" | §1/§2/§4/§5/§6/§7 use prose, tables, `@type`/`@spec`/`@doc` blocks, and WAT fixture text (not Elixir) only — no `def ... do ... end` body anywhere in this document |
| "Full traceability table" | This table plus `test/specs/REQ-169.md`'s test-case list |

---

## 10 — Confirmation: no existing WASM module is modified

This design adds exactly two new production files —
`lib/letflow/engine/wasm/resource_limits.ex` and three new fixtures under
`priv/wasm_fixtures/` (`req169_hang.wat`, `req169_counting.wat`, `req169_grow.wat`).
`module_registry.ex`, `capability_gate.ex`, `plugin_handler.ex`, and `memory_guard.ex`
are all unmodified — `ResourceLimits` depends on none of them (it produces an
`Engine`/`Store` pair any of the other four modules' callers may choose to consume,
per §3's scope boundary) and none of them depends on `ResourceLimits` (wiring is a
future dispatch-integration requirement's job, identical to REQ-166/167/168's own
stated boundary). No new `Task.Supervisor` or supervision-tree child spec is added —
`ResourceLimits` never dispatches a guest call itself and never calls
`Wasmex.start_link/1` (§3); tests that need a running guest instance dispatch through
the existing, unmodified `Letflow.Engine.PluginTaskSupervisor`, mirroring every prior
WASM design's own test-time convention.
