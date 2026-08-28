# REQ-174 — WASM instance pooling with per-invocation memory reset as a correctness requirement (WASM-13 restated, SHOULD)

**Requirement:** REQ-174 (WASM-13, SHOULD, restated by decision 0014 (e))
**Stage:** S5
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-28
**Depends on:** REQ-173 (`lib/letflow/engine/wasm/module_version_registry.ex`, done),
REQ-165/170/171/172 (`lib/letflow/engine/wasm/plugin_handler.ex`), decision
`0014-scripting-plugin-runtime-strategy.md` point (e).

This is a design artefact — `@spec`/`@type` signatures and prose only, no function
bodies, no implementation code.

---

## 0 — What this requirement restates, and why that matters before any adopt/decline call

WASM-13's original text: "The host SHOULD pool Wasm instances per module to amortise
instantiation cost, WHILE ENSURING PER-INVOCATION ISOLATION (memory reset between
invocations)." Its own acceptance criterion is a p50-latency comparison.

Decision 0014 (e) keeps WASM-13 a SHOULD but **adds a constraint absent from the
original text**: *if* pooling is adopted, per-invocation memory reset is a
**correctness requirement** (cross-invocation, potentially cross-tenant data leak),
not a performance detail — because `wasmex` pooling (where it exists) deliberately
reuses a `Store`, and Letflow is schema-per-tenant (decision 0006). This document
records that restatement explicitly, as required by this requirement's own acceptance
criteria, independent of which way the adopt/decline call below goes.

Because WASM-13 is a SHOULD, decision 0014 (e) states declining is legitimate. §1
below is the live verification this decision must be grounded in, not an abstract
preference. §2 is the decision. §3 is the property that makes the decision safe,
and §4 is the concrete test design for it.

---

## 1 — Live verification (session of 2026-08-28, real installed `wasmex` v0.15.1, `deps/wasmex/`)

### 1.1 `wasmex` v0.15.1 exposes no instance-pooling API at all

```
$ grep -rln "pool" deps/wasmex/lib/
(no output)
```

Every `.ex` file under `deps/wasmex/lib/` — `wasmex.ex`, `wasmex/instance.ex`,
`wasmex/store.ex`, `wasmex/store_or_caller.ex`, `wasmex/store_limits.ex`,
`wasmex/module.ex`, `wasmex/memory.ex`, `wasmex/components*.ex`, the `wasi/`
submodules — was searched. None contains the string `pool` anywhere, in code or
moduledoc. The only "pool" hits anywhere in the dependency tree are (a)
`deps/wasmex/CHANGELOG.md`'s 0.14.0 entry, which describes an internal Tokio **OS
worker-thread pool** backing the async NIF executor (a concurrency implementation
detail with no public API and nothing to do with Wasm *instance* reuse across
invocations), and (b) unrelated native build artefacts (`zstd-sys` object files,
`rayon_core` — a general-purpose Rust thread-pool crate pulled in transitively by
Wasmtime's own dependency graph, not something `wasmex` exposes to Elixir callers).

Decision 0014 (e)'s framing — "`wasmex` pooling deliberately reuses a Store" — is
therefore correct as a statement about a *hypothetical* pooling design one could build
on top of `wasmex`'s primitives (a `Store` can outlive one instantiation — see §1.2),
but there is **no first-party `wasmex` pooling feature to adopt or decline** in the
installed version. Any "instance pool" would have to be Letflow's own code, built from
`Wasmex.Store`/`Wasmex.Instance`/`Wasmex.start_link/1` primitives, with Letflow itself
responsible for every lifecycle guarantee (checkout, memory reset, and superseded-version
exclusion) that decision 0014 (e) worries about.

### 1.2 `Wasmex.start_link/1` allocates a brand-new `Store` (and therefore brand-new
linear memory) on every call unless one is explicitly supplied

```elixir
# deps/wasmex/lib/wasmex.ex
def start_link(%{} = opts) when is_map_key(opts, :module) and not is_map_key(opts, :store),
  do: ...
...
store = Map.get(opts, :store, nil)
...
# init/1, when no :store was supplied:
Wasmex.Store.new_wasi(opts[:wasi])   # or
Wasmex.Store.new()
```

Both existing call sites this requirement is scoped against —
`ModuleVersionRegistry.instantiate/2` (`lib/letflow/engine/wasm/module_version_registry.ex`,
`Wasmex.start_link(%{bytes: bytes, imports: table})`) and `PluginHandler.run_guest/3`'s
`instantiate/1` (`lib/letflow/engine/wasm/plugin_handler.ex`,
`Wasmex.start_link(%{bytes: bytes})`) — call `start_link/1` **without** a `:store` key.
Per the code above, every single invocation therefore gets a freshly allocated
`Wasmex.Store` and a freshly instantiated `Wasmex.Instance` inside it — not a reset of
previously-used linear memory, but linear memory that was never written by any other
invocation in the first place. This is a stronger isolation property than "reset
between invocations": there is no shared object across invocations for residue to
survive in.

### 1.3 Both existing call sites already release the instance unconditionally on
every path, including the failure path

`ModuleVersionRegistry.run_call/6` (design `req173-wasm-module-hot-reload.md` §4 step
5, verified directly in the shipped module):

```elixir
call_result =
  try do
    Wasmex.call_function(pid, export, args, timeout_ms)
  rescue
    exception ->
      GenServer.stop(pid)
      release(snapshot.module_name, snapshot.version_id, monitor_ref)
      reraise exception, __STACKTRACE__
  end

GenServer.stop(pid)
release(snapshot.module_name, snapshot.version_id, monitor_ref)
```

`GenServer.stop(pid)` runs on **both** the exception path and the normal-return path —
the only path that does not reach it explicitly is a `GenServer.call` timeout `exit`
from `Wasmex.call_function/4` itself, which is left to the `Process.monitor`/`:DOWN`
crash-safety net (design §6), not to a leaked, reusable instance. `PluginHandler.run_guest/3`
follows the identical pattern (`GenServer.stop(pid)` unconditionally, "on every path,
including the error path, so a wasmex instance is never leaked" per its own inline
comment). Neither module retains an instance, a `pid`, or a `Store` past a single
invocation under any outcome — success, guest exception, or trap.

### 1.4 Conclusion this design's decision rests on

There is no pooling feature in the installed `wasmex` to adopt, and the two production
call paths this requirement is scoped against (`ModuleVersionRegistry.invoke/4`,
`PluginHandler.run_guest/3`) already give per-invocation isolation **by construction** —
not by resetting a reused `Store`, but by never sharing one across invocations, and by
tearing the instance down unconditionally afterward. Building a Letflow-owned pool on
top of `wasmex`'s primitives would mean introducing the exact shared-`Store` residue
risk decision 0014 (e) flags, purely to recover an amortised-instantiation-cost benefit
that has not been measured, still needing a manual reset step this design would have to
prove is unconditional (§2 explains why that proof is nontrivial). That trade is not
worth taking on speculatively.

---

## 2 — Decision: **DECLINE** instance pooling

**Pooling is declined for this requirement.** Recorded reasons:

1. **No first-party pooling exists to adopt.** §1.1 — `wasmex` v0.15.1 exposes no
   pooling API. "Adopting WASM-13's pooling" would mean designing and building an
   entirely new Letflow-owned subsystem (a pool manager process, a checkout/return
   protocol, a manual memory-reset step run on the return path), not wiring up an
   existing library feature.
2. **Isolation-by-construction already exists and is strictly stronger than
   reset-between-invocations.** §1.2/§1.3 — every invocation today gets a Store that
   was never touched by any other invocation, torn down unconditionally afterward. A
   hand-built pool would *regress* this to "isolation via a reset step that must be
   proven unconditional," which is exactly the correctness burden decision 0014 (e)
   warns about, for a benefit (§3 below) that is currently unmeasured.
3. **The amortisation benefit is speculative, not demonstrated.** WASM-13's own
   acceptance criterion is a p50-latency comparison; no such measurement exists yet for
   Letflow's actual module sizes and invocation cadence (S5's plugin workloads are
   still low-volume — see stage-5 migration doc). Building a stateful pool and its
   attendant reset-correctness proof before the cost it amortises is even quantified
   inverts the order decision 0014 (e) implies: measure first, then decide whether the
   isolation risk is worth taking on.
4. **WASM-13 is a SHOULD**, and decision 0014 (e) explicitly names declining as a
   legitimate outcome, conditioned on recording the reason (this section) and
   asserting the property that makes declining safe (§3/§4).

This decision can be revisited if a future requirement demonstrates (with a real
benchmark per §5) that cold-instantiation cost is an actual bottleneck for a real
Letflow workload — at which point a new requirement should design the pool from
scratch against whatever `wasmex` version is current then, re-verifying its Store-reuse
behaviour live rather than trusting this document's v0.15.1 findings to still hold.

---

## 3 — The property that makes declining safe

**Invariant INV-174-1 (per-invocation isolation, by construction, not by reset):** for
any two invocations of the same registered module — whether via
`ModuleVersionRegistry.invoke/4` or `PluginHandler.run_guest/3` — invocation N+1 never
observes any linear-memory state written by invocation N, because each invocation runs
against a `Wasmex.Instance` created by a call to `Wasmex.start_link/1` that supplied no
`:store` option, so `wasmex` allocates a brand-new `Wasmex.Store` (and therefore
brand-new linear memory, per §1.2) for that call alone, and the instance is
unconditionally stopped (§1.3) before the function returns control to the invoking
process on every outcome (success, guest exception/trap, or the monitor-mediated
timeout path).

This invariant is a statement about the *existing, shipped* code
(`module_version_registry.ex`, `plugin_handler.ex`) — this requirement adds no new
production code to satisfy it, only the test in §4 that proves it holds and will keep
holding (i.e. that a future change cannot silently reintroduce a shared `:store` without
a test failing).

**Invariant INV-174-2 (restatement, recorded regardless of the decision):** this
requirement restates WASM-13 by ADDING the per-invocation memory-reset correctness
constraint that is absent from WASM-13's own original text — per decision 0014 (e), if
pooling is ever adopted in a future requirement, memory reset between invocations must
be enforced unconditionally (including on a failed/trapped invocation) and treated as a
correctness property of that design, not a later performance optimisation. This
document does not itself adopt pooling, so no reset mechanism is designed here; this
invariant is recorded so a future ADOPT decision inherits the constraint rather than
rediscovering it.

---

## 4 — Test design (concrete, deterministic, no implementation code)

All tests below are ExUnit tests to be added to
`test/letflow/engine/wasm/module_version_registry_test.exs` and
`test/letflow/engine/wasm/plugin_handler_test.exs` (one isolation test per call path —
the two paths use different instantiation call sites, so both must be covered
independently; a single test covering only one would leave the other's isolation
unverified). No new production module is introduced by this requirement.

### 4.1 Fixture: a WASM module with an exported, mutable memory cell

A new fixture, `priv/wasm_fixtures/req174_memory_write.wat`, is needed (none of the
existing fixtures both export memory AND expose a guest function that mutates a
specific, host-readable byte). Shape, mirroring `req168_memory.wat`'s precedent of one
exported page of memory plus a minimal export set:

- `(memory (export "memory") 1)` — one page, host-readable via `Wasmex.Memory`.
- an exported function, e.g. `write_marker`, taking no arguments, that writes a fixed,
  non-zero byte value (e.g. `1`) to a fixed offset (e.g. byte `0`) of that memory and
  returns `i32` `0`.
- linear memory is zero-initialized by the Wasm spec at instantiation, so byte `0`
  reads `0` before `write_marker` is ever called on a fresh instance, and `1` after —
  this is the observable signal the test asserts on.

### 4.2 Test — `ModuleVersionRegistry` path: data written in invocation N is not
observable at invocation N+1

Given: a module registered and activated via `register_version/3` + `activate/2` using
`req174_memory_write.wat`'s bytes and a manifest with zero required capabilities.

Steps:
1. Call `ModuleVersionRegistry.invoke/4` with `export: "write_marker"` — invocation N.
   Assert it returns `{:ok, version_id, [0]}` (the function's own return value, proving
   it ran).
2. Call `ModuleVersionRegistry.invoke/4` again with the same `module_name` and a second
   export, `read_marker` (byte `0` returned as `i32`, no mutation) — invocation N+1.
   Assert it returns `{:ok, version_id, [0]}`, **not** `[1]`.

If `[1]` were observed at step 2, that would mean invocation N+1 was handed the same
`Store`/linear memory invocation N wrote to — the exact residue decision 0014 (e)
warns about. Asserting `[0]` is the concrete, deterministic proof that INV-174-1 holds
for this call path; it is not an assumption stated in prose only.

### 4.3 Test — `PluginHandler.run_guest/3` path: same property, independently

Given: `req174_memory_write.wat`'s bytes.

Steps:
1. Call `PluginHandler.run_guest(bytes, "write_marker", timeout_ms)` — invocation N.
   Assert success.
2. Call `PluginHandler.run_guest(bytes, "read_marker", timeout_ms)` — invocation N+1,
   same bytes, same exported module, no state passed between the two calls other than
   the `bytes` binary itself (which is immutable Elixir data, not a live Wasm
   instance).
3. Assert the second call's result reflects byte `0`, not `1`.

### 4.4 Negative control (both paths): a shared-store bug would make 4.2/4.3 fail loud, not silently pass

Both 4.2 and 4.3 are only meaningful if a deliberately-broken build (one that passed an
explicit, invocation-scoped `:store` option shared across two `Wasmex.start_link/1`
calls) would make the assertion in step 2 fail. This is documented here as the design
rationale for why `[0]` at step 2 is a real isolation proof rather than a tautology —
TEST-DESIGNER is not required to ship a mutant/broken build to prove this; the
reasoning is recorded so a reviewer can verify the test's discriminating power by
inspection: if a `:store` were shared, `write_marker`'s byte-0 write from invocation N
would still be present in that shared linear memory when `read_marker` runs in
invocation N+1, and the assertion would fail.

### 4.5 What this requirement does NOT need to test, and why

- **No memory-reset-mechanism test.** §2 declines pooling; there is no reset mechanism
  to test. §4.2/4.3 test the isolation *outcome* directly (no residue observed), which
  is the property that matters — not a specific mechanism.
- **No superseded-version-exclusion test.** That property (a pooled instance of a
  version superseded by REQ-173's `activate/2` must never be handed to a new
  invocation) is only meaningful for an adopted pool that hands out *reused* instances.
  With no pool, `ModuleVersionRegistry.checkout/1` already guarantees a fresh
  instantiation is built from whatever `version_snapshot()` is current at checkout time
  (REQ-173, already tested in `module_version_registry_test.exs`) — there is no
  separate "instance identity" that could outlive an activation, because no instance
  is ever retained past one invocation (§1.3). This requirement adds no new test here;
  REQ-173's existing hot-reload tests already cover the only version-currency property
  that exists in a no-pooling design.
- **No p50-latency benchmark.** WASM-13's own acceptance criterion (reduced p50 latency
  vs cold instantiation) is a property of an *adopted* pool amortising instantiation
  cost against a baseline. With pooling declined, every invocation *is* the baseline
  cold-instantiation cost — there is no "vs" comparison to record. If a future
  requirement adopts pooling, that design must record the p50 comparison as a
  moduledoc/design-artefact benchmark number (methodology: N repeated invocations of
  the same module under the adopted pool vs. N invocations of the current
  fresh-instance-per-call baseline, wall-clock median of each, both run on the same
  fixture and hardware in the same test session), explicitly not as a CI-gated test
  threshold — this document defers that methodology rather than inventing numbers for a
  mechanism that does not exist.

---

## 5 — Acceptance-criteria cross-reference

| Acceptance criterion | Where satisfied |
|---|---|
| Moduledoc records explicit ADOPT/DECLINE decision | §2 |
| Test asserts per-invocation isolation (data written in N not observable in N+1) | §4.2 (`ModuleVersionRegistry`), §4.3 (`PluginHandler`) |
| (adopt-only) reset-by-construction test | N/A — declined, see §4.5 |
| (adopt-only) superseded-version-exclusion test | N/A — declined, see §4.5 |
| (adopt-only) p50 benchmark recorded, not CI-gated | N/A — declined, see §4.5 |
| Moduledoc states this restates WASM-13 by ADDING the memory-reset correctness constraint, cites decision 0014 (e) and wasmex's Store-reuse behaviour | §0, §1.1, §3 (INV-174-2) |
| `mix test` / `mix compile --warnings-as-errors` pass with real output quoted | ELIXIR-DEV/TEST-RUNNER responsibility once §4's tests and fixture are implemented — not satisfiable at the design stage; this design specifies exactly what must pass |

---

## 6 — Open questions

- None blocking. The one deferred item is explicitly out of scope per §4.5/§2's own
  revisit clause: if a future requirement wants to adopt pooling, it must re-verify
  `wasmex`'s pooling/Store-reuse behaviour live against whatever version is current at
  that time — this document's §1 findings are pinned to v0.15.1 and must not be assumed
  to still hold.
