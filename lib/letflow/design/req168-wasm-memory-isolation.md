# REQ-168 — WASM linear memory isolation and host-side validation of every guest pointer/length pair (WASM-08)

**Requirement:** REQ-168 (WASM-08, MUST)
**Stage:** S5
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-28
**Depends on:** REQ-166 (`lib/letflow/engine/wasm/module_registry.ex`, gate-approved);
consumes the crash-boundary precedent `req166-wasm-module-abi-validation.md` §1.5 and
`req167-wasm-import-whitelist.md` §1/§4 already established, and the residual-crash
disclosure `req165-wasmex-process-boundary.md` §7.2 (cited verbatim in §6 below, not
re-derived).

This is a design artefact — `@spec`/`@type` signatures and prose only, no function
bodies. See `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1.

---

## 0 — Why this is the single highest-stakes design in the WASM series, and how that changes this document's structure

WASM-08's own failure mode is "host crash," and under decision 0014's chosen runtime
(`wasmex`/Wasmtime via a Rust NIF) a host crash means the **entire BEAM node**, not a
request or a process. Unlike REQ-165/166/167 — where the live verification confirmed a
*hypothesis already stated in decision 0014* (an unresolved-import crash delivers a
linked `:EXIT`, not a clean error) — this design's live verification **found a real,
previously-undocumented, node-killing failure mode** in the dependency this platform
has already adopted. §1 below is therefore unusually long and is the load-bearing
section of this entire document: every other section's safety claim rests on §1's
findings, not on `wasmex`'s published docs or `@spec` annotations (§1.6 shows those are
themselves incomplete).

**Everything below §1 is reproducible.** The probe scripts are preserved at
`scratch/req168_memory_probe.exs`, `scratch/req168_overflow_probe2.exs`, and
`scratch/req168_overflow_probe3.exs` (git-ignored per `core-directives.md`'s scratch
rule, not part of this requirement's shipped artefacts) — ELIXIR-DEV or a future
auditor can re-run them verbatim.

**Rework pass 1 (2026-08-28):** CODE-DESIGN-VALIDATOR found §1.1's original transcript
factually wrong (see the correction inline in §1.1 below). As part of that rework, every
live-call transcript in this section (§1.1 through §1.5, not only the one flagged) was
re-run fresh against the identical installed `wasmex` 0.15.1 dependency —
`scratch/rework1_probe_1_1_to_1_3.exs` (§1.1/1.2/1.3/1.5) and, isolated per the
SIGABRT/hang safety precaution, `scratch/rework1_probe_sigabrt.exs` (§1.4 Shape B) and
`scratch/rework1_probe_hang.exs` (§1.4 Shape A). Only §1.1 required a correction; §1.2,
§1.3, §1.4 (both shapes), and §1.5 all reproduced exactly as originally documented,
confirmed independently in this rework, not merely trusted from the original draft or
from the validator's own spot-checks.

---

## 1 — Live verification findings (session of 2026-08-28, real installed `wasmex` v0.15.1, `WASMEX_BUILD=true`, `PATH` including `.asdf/shims` and `.cargo/bin`)

All probes used a trivial fixture with one exported page of memory:

```
(module
  (memory (export "memory") 1)
  (func (export "answer") (result i32) i32.const 42))
```

Every probe ran the risky call inside a monitored `Task.Supervisor.async_nolink/2` task
under the already-supervised `Letflow.Engine.PluginTaskSupervisor`, bounded by
`Task.yield/2`, exactly matching `module_registry.ex`'s and `capability_gate.ex`'s
already-live-verified pattern for calling into `wasmex` — never inline.

### 1.1 `Wasmex.Memory.size/2` returns **bytes**, not pages — and returns them as a bare
integer, not a tagged tuple

```
Wasmex.Memory.size(store, memory)  #=> 65536     (one 64KB page, bare integer)
```

**Correction (rework pass 1):** an earlier draft of this section mis-transcribed this
call's return as `{:ok, 65536}`. Re-verified live in this rework
(`scratch/rework1_probe_1_1_to_1_3.exs`, same installed `wasmex` 0.15.1): the call
returns the **bare integer** `65536` directly — `{:ok, size} = Wasmex.Memory.size(store,
memory)` would raise a `MatchError`. This matches `size/2`'s own `@spec` in
`deps/wasmex/lib/wasmex/memory.ex:78` (`pos_integer()`, not a tuple type), and matches
how this design's own algorithm already uses the value (§2 step 2: `memory_size =
Wasmex.Memory.size(store, memory)`, a bare assignment, never a tuple destructure) — so
this correction is to this section's transcript only; no other part of this document
assumed the wrong shape.

Confirms the moduledoc's own worked example (`"1114112 # in bytes (17 pages of 64 kB)"`)
is accurate: `size/2`'s return value IS the real byte-length boundary directly — no page
multiplication is needed or should be applied by this design's arithmetic.

### 1.2 In-bounds access round-trips correctly (sanity)

`set_byte(store, memory, 0, 7)` then `get_byte(store, memory, 0)` returns `7`. Baseline
confirmed before probing failure modes.

### 1.3 `wasmex`'s own NIF DOES cleanly bounds-check "moderate" out-of-range offset/length pairs — for all four accessor functions, including a genuine offset+length wraparound shape

| Probe | Call | Real result |
|---|---|---|
| offset beyond size | `get_byte(store, memory, size + 1_000_000)` | `{:error, "out of bounds memory access"}` |
| offset beyond size | `read_binary(store, memory, size + 1000, 10)` | `{:error, "out of bounds memory access"}` |
| length past memory end | `read_binary(store, memory, size - 1, 1000)` | `{:error, "out of bounds memory access"}` |
| offset beyond size (write) | `write_binary(store, memory, size + 1000, "hello")` | `{:error, "out of bounds memory access"}` |
| offset beyond size (write) | `set_byte(store, memory, size + 1, 1)` | `{:error, "out of bounds memory access"}` |
| **classic wraparound shape**: `offset = 2^64 - 10` (fits in a native u64), `length = 20` — under fixed-width wrapping arithmetic, `offset + length` wraps to `10`, which is `<= size` and would falsely appear in-range under a naive fixed-width check | `read_binary(store, memory, 18_446_744_073_709_551_606, 20)` | `{:error, "out of bounds memory access"}` |
| same wraparound-shaped value, single-index form | `get_byte(store, memory, 18_446_744_073_709_551_606)` | `{:error, "out of bounds memory access"}` |
| max-realistic-guest value: `offset = 0, length = 2^32 - 1` (the largest length a genuine WASM32 i32-derived unsigned value could ever be) | `read_binary(store, memory, 0, 4_294_967_295)` | `{:error, "out of bounds memory access"}` |
| both at max realistic-guest value: `offset = length = 2^32 - 1` | `read_binary(store, memory, 4_294_967_295, 4_294_967_295)` | `{:error, "out of bounds memory access"}` |

**Every one of these returns a clean, ordinary Elixir term through the normal call path
— no exception, no exit signal, no hang, no crash.** This directly answers the
handoff's verification item (3): `wasmex`'s NIF-level implementation already performs
bounds-checking, correctly and without the classic wraparound defect, for every offset/
length magnitude a real WASM32 guest's i32-typed pointer/length values could ever
produce (0..2^32-1) and even for a native-word-sized wraparound-shaped pair.

### 1.4 But at a magnitude far beyond anything a real memory region or a real WASM32 guest could produce, `wasmex`'s own bounds-check is bypassed by an earlier, unguarded allocation attempt — with two distinct, both dangerous, failure shapes

**Shape A — an uncatchable hang (not a clean error), at `length = 2^63`:**

```
Wasmex.Memory.read_binary(store, memory, 9_223_372_036_854_775_808, 9_223_372_036_854_775_808)
```

produces, on stderr:
```
thread 'wasmex-async' panicked at .../raw_vec/mod.rs:28:5:
capacity overflow
```

and the calling process's request **never returns a reply** — confirmed by re-running
with a 15-second bound (`scratch/req168_overflow_probe2.exs` Probe C): the task never
completes, `Task.shutdown/2` has to kill it. **Root cause, confirmed by reading
`deps/wasmex/lib/wasmex/utils.ex`:** every `Wasmex.Memory` accessor's underlying
`Wasmex.Utils.native_request/1` does a bare `receive do {^reference, result} -> result
end` with **no timeout of any kind** — if the NIF's async worker thread panics before
sending its reply message, the calling process blocks in that `receive` **forever**,
with no way for the caller to recover short of an external kill. The panic is caught by
Rust's own unwind boundary at the *thread* level (it does not itself take the OS process
down for this magnitude) — but nothing wires that failure back to the waiting Elixir
`receive`.

**Shape B — a full process abort (the actual node-crash class), at `length = 2^40`:**

```
Wasmex.Memory.read_binary(store, memory, 0, 1_099_511_627_776)   # 2^40 bytes
```

produces, on stderr:
```
memory allocation of 1099511627776 bytes failed
```

and the **entire OS process terminates**: running this call from a bare `mix run`
(not wrapped in any test framework) exits with `Aborted (core dumped)`, shell exit code
**134** (`SIGABRT`). This is not a Rust panic that unwinds a thread — it is the Rust
global allocator's `handle_alloc_error` path, which calls `abort()` unconditionally and
cannot be caught by any Elixir-level `try`/`rescue`, any `Task.Supervisor`, or any BEAM
supervision mechanism whatsoever, because the OS process itself is what terminates.
**Under decision 0014's chosen runtime, the OS process IS the BEAM node.** This is
WASM-08's disclosed failure mode, reproduced live, not hypothesized.

**Bisection (`scratch/req168_overflow_probe3.exs` Probe F):** `length = 2^32` still
returned the clean `{:error, "out of bounds memory access"}` string; `length = 2^40`
aborted the process. The exact threshold between "still clean" and "aborts" was not
narrowed further than that four-order-of-magnitude gap — **not needed for this design's
safety argument**, since §2 below rejects on the real memory size (realistically never
more than a few hundred megabytes even after REQ-169's `StoreLimits.memory_size` cap,
and structurally capped at 4 GiB by WASM32's own address space) long before any value
anywhere near `2^32`, let alone `2^40` or `2^63`, could ever reach `Wasmex.Memory`.

### 1.5 Per-instance memory isolation — confirmed live

Two separate `Wasmex.start_link/1` calls against the **identical** module bytes:
`set_byte(store_a, mem_a, 0, 99)` then `get_byte(store_b, mem_b, 0)` on the second,
independent instance returns `0` (`get_byte(store_a, mem_a, 0)` on the first still
returns `99`). **Confirmed: two instances of the same module do not share linear
memory — a write in one is never observable via a read in the other.** This is a
structural property of `wasmex`'s per-instance `Wasmex.Memory` handle (each instance's
`Wasmex.memory/1` call returns a distinct NIF resource bound to that instance's own
Wasmtime `Store`), not something this design's own code needs to implement or enforce —
only to assert with a test (§5.3).

### 1.6 A previously-unstated finding: three of `Wasmex.Memory`'s own published `@spec`s are incomplete — do not trust them as exhaustive

Reading `deps/wasmex/lib/wasmex/memory.ex` (§1 of the handoff's mandatory reading)
against what was actually observed live:

| Function | Declared `@spec` return | Actually observed live (out-of-bounds case) |
|---|---|---|
| `get_byte/3` | `number()` | `{:error, "out of bounds memory access"}` |
| `read_binary/4` | `binary()` | `{:error, "out of bounds memory access"}` |
| `write_binary/4` | `:ok` | `{:error, "out of bounds memory access"}` |
| `set_byte/4` | `:ok \| {:error, binary()}` | `{:error, "out of bounds memory access"}` (this one's `@spec` was already correct) |

Three of the four accessor `@spec`s in the installed dependency **do not declare their
own error return path** — they undersell what the function can actually return, in the
exact direction that matters here (a caller trusting the declared type could pattern-
match only on the "success" shape and crash on the `{:error, _}` tuple with a
`MatchError`, which — per `req166-wasm-module-abi-validation.md` §1.5's identical
finding for a different `wasmex` function — would itself become an unguarded `:EXIT`
if reached outside a monitored task). **Design consequence (§4):** this design's own
`read/4` and `write/4` never assume any `Wasmex.Memory` call's return shape from its
declared `@spec` alone — every call site pattern-matches both the documented success
shape and an `{:error, _}` tuple explicitly, regardless of what that function's `@spec`
claims.

---

## 2 — What this design does with these findings: the bounds-check arithmetic (AC3)

**The requirement's own framing ("a naive `offset + length <= size` check is unsafe
because it can wrap") is written for a fixed-width-integer language.** Stated
precisely, so this is not silently resolved either way: in Rust/C, `offset + length`
computed in native (e.g. 64-bit unsigned) arithmetic can overflow the machine word and
wrap to a small value, which is exactly the class of bug §1.4 shows `wasmex`'s own
Rust-side allocation path does **not** defend against at extreme magnitudes (it doesn't
wrap in a way that produces a false accept — instead it panics/aborts — but the
underlying hazard is the same family: an arithmetic/allocation computation over
attacker-controlled magnitude, performed in native fixed-width code, before any
memory-bounds check completes). **Elixir integers are arbitrary-precision (bignums) —
`offset + length` computed in Elixir cannot wrap, at any magnitude, ever.** This is a
real, load-bearing difference, and it is why this design's own arithmetic is trivially
safe in a way the requirement's cautionary framing (written with `wasmex`'s Rust
internals in mind) does not have to be replicated defensively on the Elixir side.

**What the design does instead of trusting `wasmex`'s own check (§1.3) or worrying
about Elixir-side wraparound (impossible per above):** perform the ENTIRE bounds
decision in Elixir, using the real current memory size fetched fresh via
`Wasmex.Memory.size/2` for every single call (never cached — memory can grow between
calls via `Wasmex.Memory.grow/3`, and a stale cached size would itself be a bounds-check
defect), and reject before ever handing `offset`/`length` to any `Wasmex.Memory`
function — so the pathological magnitudes §1.4 found dangerous are **never presented to
`wasmex` at all**, regardless of whether `wasmex`'s own internal check would have caught
them (§1.3 shows it does, up to at least `2^32`; §1.4 shows it stops being trustworthy
somewhere before `2^40`). Exact algorithm, in order, all using Elixir's exact,
non-wrapping integer arithmetic:

1. **Type/sign guard.** `offset` and `length` must both be integers and both
   non-negative (`>= 0`). Reject a non-integer or negative value immediately as
   `{:invalid_argument, :offset | :length, value}` — Elixir's `@spec non_neg_integer()`
   on the eventual public function is not runtime-enforced, and a raw WASM `i32` guest
   value re-interpreted incorrectly upstream (a REQ-171/172 host-function-layer concern,
   §7) could arrive here as a negative Elixir integer if sign-extension is mishandled
   before this function is called; this guard makes that mistake fail loudly and
   structurally here rather than being silently miscompared later.
2. **Fetch the real, current memory size.** `memory_size = Wasmex.Memory.size(store,
   memory)` (§1.1 — bytes, used directly, no page arithmetic).
3. **Offset-range check.** Reject if `offset > memory_size` as
   `{:offset_out_of_range, offset, memory_size}`. (`offset == memory_size` is not itself
   rejected here — a zero-length access exactly at the end-of-memory boundary is
   well-defined and empty; step 4 rejects any positive `length` at that offset.)
4. **End-of-range check — the step that replaces the "naive `offset+length<=size`"
   framing and is safe here by construction.** Compute `range_end = offset + length`
   (exact, non-wrapping — bignum arithmetic, per above) and reject if `range_end >
   memory_size` as `{:length_exceeds_memory, offset, length, memory_size}`. Because
   `range_end` is computed exactly regardless of how large `offset` or `length` are —
   there is no magnitude at which this comparison becomes wrong — this single check
   correctly handles all three of the requirement's named cases at once: an offset
   beyond memory size (already caught earlier at step 3, but would also be caught here
   independently since `range_end >= offset`), a length running past the memory end
   (offset valid, `offset + length` exceeds `memory_size`), and an offset+length pair
   "that would overflow" in a fixed-width language (here: any `offset`/`length`
   magnitude whatsoever, including the `2^63`/`2^40`/`2^64-10` values §1.3/§1.4 probed —
   `range_end` is still computed exactly and still compared correctly, so no such pair
   can ever appear falsely in-range).
5. Only if steps 1-4 all pass: proceed to the actual `Wasmex.Memory` call (§4). At this
   point `offset >= 0`, `length >= 0`, and `offset + length <= memory_size` are all
   simultaneously guaranteed exactly (not approximately) — the resulting call to
   `Wasmex.Memory.read_binary/4` or `write_binary/4` is therefore always made with a
   value inside the range §1.3 already confirmed `wasmex`'s own NIF also handles
   cleanly, giving this design two independent layers of protection against the
   "moderate out-of-range" class and one exclusive layer (this Elixir-side check)
   against the "extreme magnitude" class §1.4 discovered.

---

## 3 — Module location and why it is a new module, not folded into `ModuleRegistry`/`CapabilityGate`/`PluginHandler`

Per the handoff's instruction and this project's established precedent
(`req155-lua-wallclock-kill.md` §4.4, already applied identically by
`req166-wasm-module-abi-validation.md` §2.2 and `req167-wasm-import-whitelist.md` §0):
one dedicated module per orthogonal concern. `ModuleRegistry` validates export shape and
proves one-time instantiability (REQ-166); `CapabilityGate` builds a manifest-scoped
import table and performs gated instantiation (REQ-167); `PluginHandler` dispatches one
already-known guest export through the process boundary (REQ-165). None of the three
touches **runtime pointer validation on every host-function call** — a concern that
recurs on every single invocation of every host function REQ-171/172 will eventually
define, not once at registration or instantiation time. This is a fourth, orthogonal
concern and gets its own module and its own tests, exactly as the handoff instructs.

**Decision: `Letflow.Engine.Wasm.MemoryGuard`, new file
`lib/letflow/engine/wasm/memory_guard.ex`.** No new `Task.Supervisor` is introduced —
unlike instantiation (REQ-166/167), a memory-guard call never spawns a `wasmex`
instance and never calls `Wasmex.start_link/1`; it operates against an
**already-running** instance's already-obtained `Wasmex.Memory.t()` handle. Per §1's
findings, the calls this module makes (`Wasmex.Memory.size/2` for the real boundary,
then `read_binary/4`/`write_binary/4` only after validation) are themselves the
category §1.3 showed returns cleanly (never a crash, never a hang) for any value this
design's own guard would ever let through — so no additional `Task.Supervisor`/
`Task.yield` wrapper is required around `MemoryGuard`'s own calls for the guard's own
sake. (The **outer** invocation-level task boundary `PluginInterface.invoke/2,3`
already provides — REQ-165 — remains the backstop for any host-function call as a
whole, memory access included; `MemoryGuard` does not need or duplicate that layer.)

---

## 4 — Public contract: `Letflow.Engine.Wasm.MemoryGuard`

```
defmodule Letflow.Engine.Wasm.MemoryGuard do
  @typedoc "One concrete way a pointer/length pair failed validation, or a
  raw Wasmex.Memory call itself reported a clean failure (§1.6 -- never assumed
  absent just because a Wasmex.Memory function's own @spec omits it)."
  @type bounds_defect ::
          {:invalid_argument, field :: :offset | :length, value :: term()}
          | {:offset_out_of_range, offset :: integer(), memory_size :: non_neg_integer()}
          | {:length_exceeds_memory, offset :: integer(), length :: integer(),
             memory_size :: non_neg_integer()}
          | {:memory_access_failed, raw_reason :: term()}

  @typedoc "The structured rejection reason surfaced to every caller -- AC2's
  'structured error outcome', never an exception/exit."
  @type guard_error :: {:invalid_pointer, bounds_defect()}

  @doc """
  The pure arithmetic core (§2's five steps, minus the live Wasmex.Memory.size/2
  fetch) -- takes the real current memory size as an already-known integer
  rather than fetching it, so this function has no Wasmex/NIF dependency at
  all and is callable with fabricated integers alone. This is what makes the
  three named test cases (offset beyond size, length past end, an
  overflow-shaped pair) directly, deterministically testable without a live
  Wasmex.Memory handle -- mirroring req167-wasm-import-whitelist.md section 1.3's
  identical "assert against the pure function's output, not by invoking and
  catching an error" discipline. `read/4` and `write/4` (below) are the only
  callers that also perform the live `Wasmex.Memory.size/2` fetch; every other
  test in this design's suite (the four AC3 arithmetic cases) targets this
  function directly.
  """
  @spec check_bounds(offset :: integer(), length :: integer(), memory_size :: non_neg_integer()) ::
          :ok | {:error, bounds_defect()}

  @doc """
  THE single validation function every host-side READ of guest memory goes
  through (AC1). Fetches the instance's real, current memory size fresh via
  `Wasmex.Memory.size/2` (never cached -- §2 step 2), runs it and the given
  `offset`/`length` through `check_bounds/3`, and only if that returns `:ok`
  calls `Wasmex.Memory.read_binary/4`. Pattern-matches BOTH the documented
  success shape (`binary()`) and an `{:error, _}` tuple on that call's return
  (§1.6 -- never assumes the declared `@spec` is exhaustive). No exception,
  `exit`, or native fault can propagate out of this function on a malformed
  input: every path returns an ordinary tagged tuple.
  """
  @spec read(Wasmex.StoreOrCaller.t(), Wasmex.Memory.t(), offset :: integer(), length :: integer()) ::
          {:ok, binary()} | {:error, guard_error()}

  @doc """
  THE single validation function every host-side WRITE into guest memory goes
  through -- the write-side counterpart AC1's wording names for reads;
  included because the requirement's own scope item 1 covers "every host
  function" resolving a pointer/length pair, and the handoff's verification
  item (4) specifically requires establishing write's behavior, which this
  function's design directly consumes. `length` is implicitly `byte_size(data)`
  for the bounds check (§2's algorithm applied with that substitution).
  Mirrors `read/4`'s defect handling and defensive `{:error, _}` pattern-match
  exactly (§1.6).
  """
  @spec write(Wasmex.StoreOrCaller.t(), Wasmex.Memory.t(), offset :: integer(), data :: binary()) ::
          :ok | {:error, guard_error()}
end
```

**Every future host function (REQ-171/172) MUST call `MemoryGuard.read/4` or
`MemoryGuard.write/4` to touch guest linear memory — never `Wasmex.Memory.read_binary/
write_binary/get_byte/set_byte` directly.** AC1's repo-search check
(`grep -rn 'Wasmex.Memory\.' lib/ --include='*.ex'`) is satisfied by this design if,
after ELIXIR-DEV's implementation, that search's only hits inside `lib/` are the calls
inside `memory_guard.ex` itself (plus, incidentally, `Wasmex.Memory.size/2`/`grow/2`
calls unrelated to pointer/length dereferencing, which are not a "read of guest memory"
in AC1's sense and are out of this design's scope to gate — `grow/2` in particular
belongs to REQ-169's memory-cap concern, not this one).

---

## 5 — Test strategy (no REQ-171/172 host function exists yet — per handoff instruction, tests exercise `MemoryGuard` directly)

### 5.1 A dedicated tiny fixture, not `priv/wasm_fixtures/req165_trivial.wat`

`req165_trivial.wat` (§3.3 of `req165-wasmex-process-boundary.md`) declares no `memory`
export at all (it needed none — no buffer crosses its boundary). This design's tests
need a real `Wasmex.Memory.t()` handle from a real running instance, so a new fixture is
needed: **`priv/wasm_fixtures/req168_memory.wat`**, one exported page of linear memory
and no functions beyond a placeholder export (mirrors this document's own §1 probe
fixture exactly, checked in as a permanent test fixture rather than an ad hoc probe
script):

```wat
(module
  (memory (export "memory") 1)
  (func (export "noop") (result i32) i32.const 0))
```

Test setup obtains a real handle the same way §1's probes did:
`Wasmex.start_link(%{bytes: fixture_bytes})` → `Wasmex.store/1` → `Wasmex.memory/1`.

### 5.2 Pure arithmetic tests against `check_bounds/3` (AC3 — no live Wasmex call, deliberately)

| Case | Input | Expected |
|---|---|---|
| Valid, fully in-bounds | `offset=0, length=10, memory_size=65536` | `:ok` |
| Valid, ends exactly at boundary | `offset=65526, length=10, memory_size=65536` | `:ok` |
| Zero-length at exact end boundary | `offset=65536, length=0, memory_size=65536` | `:ok` |
| **Offset beyond memory size** | `offset=65537, length=1, memory_size=65536` | `{:error, {:offset_out_of_range, 65537, 65536}}` |
| **Length running past the memory end** | `offset=65530, length=100, memory_size=65536` | `{:error, {:length_exceeds_memory, 65530, 100, 65536}}` |
| **Offset+length pair that would overflow a fixed-width check** (mirrors §1.4's `2^63`/`2^64-10` probes, arithmetic only — see §5.4's explicit prohibition on ever live-calling `wasmex` with this magnitude) | `offset=9_223_372_036_854_775_808, length=9_223_372_036_854_775_808, memory_size=65536` | `{:error, {:length_exceeds_memory, ..., 65536}}` (computed exactly, no wraparound — proves Elixir's bignum arithmetic handles the exact magnitude §1.4 found dangerous in `wasmex`'s own Rust layer) |
| Negative offset (defensive — §2 step 1) | `offset=-1, length=1, memory_size=65536` | `{:error, {:invalid_argument, :offset, -1}}` |
| Non-integer length (defensive) | `offset=0, length="10", memory_size=65536` | `{:error, {:invalid_argument, :length, "10"}}` |

### 5.3 Live integration tests against a real `Wasmex.Memory` handle (AC2, AC4)

1. **Valid read/write round-trip.** `write(store, memory, 0, "hi")` returns `:ok`;
   `read(store, memory, 0, 2)` returns `{:ok, "hi"}`.
2. **Malformed pointer → structured error, node stays up (WASM-08's own AC, and this
   handoff's AC2).** Call `read(store, memory, memory_size_fetched_separately + 1000,
   10)` (a "moderate" out-of-range value, well within the range §1.3 confirmed `wasmex`
   itself also rejects cleanly — this test is not the dangerous-magnitude case, see
   §5.4): assert the return is `{:error, {:invalid_pointer, {:offset_out_of_range, _,
   _}}}`, assert `Process.alive?(self())` immediately after (the calling test process
   was never sent an exit signal), and assert
   `Process.whereis(Letflow.Engine.PluginTaskSupervisor) |> Process.alive?/1` (the
   application's supervision tree is untouched — the strongest available proxy, in an
   `ExUnit` test, for "the BEAM node stayed up," short of literally crashing the test
   runner's own node, which no test may do).
3. **Length running past memory end, live.** `read(store, memory, memory_size - 1,
   1000)` → `{:error, {:invalid_pointer, {:length_exceeds_memory, _, _, _}}}`.
4. **Write past memory end, live.** `write(store, memory, memory_size + 1, "x")` →
   `{:error, {:invalid_pointer, {:offset_out_of_range, _, _}}}`.
5. **Memory isolation (AC4).** Start two `Wasmex` instances from the identical fixture
   bytes; obtain each one's own `store`/`memory` handle; `write(store_a, mem_a, 0,
   <<99>>)`; assert `read(store_b, mem_b, 0, 1) == {:ok, <<0>>}` (unwritten instance B
   reads back a zero byte, per §1.5's live confirmation) and
   `read(store_a, mem_a, 0, 1) == {:ok, <<99>>}` (instance A still sees its own write).

### 5.4 A safety instruction for TEST-DESIGNER, stated explicitly so it is not discovered by a crashed CI run

**Never write a test that calls `MemoryGuard.read/4`, `MemoryGuard.write/4`, or any
`Wasmex.Memory` function directly with an `offset`/`length` value at or above roughly
`2^40`.** §1.4 live-reproduced a genuine `SIGABRT` (`Aborted (core dumped)`, process
exit code 134) at exactly that magnitude on this dependency version — a test that
accidentally exercises this path for real (rather than testing `check_bounds/3`'s pure
arithmetic, which is 100% safe at any magnitude per §5.2) would abort the **test
runner's own OS process**, mid-suite, for real. Every test in §5.2 that uses a
`2^63`-scale value tests `check_bounds/3` **only** — never `read/4`/`write/4`, and never
any `Wasmex.Memory` function — for exactly this reason. TEST-DESIGNER must preserve this
separation; TEST-DESIGN-VALIDATOR should check for it explicitly as part of its gate.

---

## 6 — Moduledoc content (AC5)

Required moduledoc content for `Letflow.Engine.Wasm.MemoryGuard`, verbatim in substance
(ELIXIR-DEV may adjust prose flow but must preserve every factual clause):

> This module bounds-checks every `(offset, length)` pair a host function resolves
> against a guest module's linear memory before any dereference, per WASM-08. It
> prevents the **host** from dereferencing a pointer/length pair a guest supplied that
> does not fit within that instance's real, current memory — including a pair whose
> magnitude is far beyond anything the WASM32 address space or this platform's own
> `StoreLimits.memory_size` cap (REQ-169) could ever make legitimate (live-verified,
> `lib/letflow/design/req168-wasm-memory-isolation.md` §1.4: at such a magnitude,
> `wasmex`'s own internal Rust-side buffer allocation fails before its own bounds check
> would run, either hanging the calling process indefinitely or aborting the entire
> BEAM node with `SIGABRT` — this module's arithmetic check, performed in Elixir's
> arbitrary-precision integers before any value reaches `wasmex`, is what prevents that
> class of input from ever being presented to `wasmex` at all).
>
> **This validation does NOT bound a fault occurring inside Wasmtime's own native
> code/runtime itself** — a Wasmtime engine bug, JIT-compiler defect, or hardware fault
> unrelated to pointer/length magnitude remains the disclosed, uncovered class
> `Letflow.Engine.Wasm.PluginHandler`'s own moduledoc already states (per
> `lib/letflow/design/req165-wasmex-process-boundary.md` §7.2, "Residual risk — NOT
> covered by the process boundary": "a Wasmtime- or NIF-layer crash inside a call this
> module makes does not raise, exit, or trap in the ordinary BEAM sense... it can crash
> the entire BEAM node... This is an accepted, stated limitation, not a gap this module
> papers over."). This module closes the specific allocation-abort hazard named above,
> which is a distinct, narrower, and now-understood mechanism; it does not and cannot
> close that broader, already-disclosed class.

Corresponding test (AC5's moduledoc-content check, mirroring
`req165-wasmex-process-boundary.md` §7.2's own `moduledoc =~ ...` technique, itself
citing `test/letflow/engine/lua/executor_test.exs:506`'s precedent): a test asserting
`Letflow.Engine.Wasm.MemoryGuard.__info__(:moduledoc)` (or `Code.fetch_docs/1`) contains
the residual-risk disclosure's key phrases (e.g. "does NOT bound a fault occurring
inside Wasmtime's own native code").

---

## 7 — Open questions this design leaves for ELIXIR-DEV/REQ-171/172, stated rather than guessed

- **OQ-D1 — sign interpretation of a raw guest `i32` pointer/length before it reaches
  `MemoryGuard`.** This design's `check_bounds/3` guards against a negative value
  arriving (§2 step 1, `{:invalid_argument, ...}`), but does not itself decide *how* a
  raw WASM `i32` register value (signed, per the core-module type system) should be
  reinterpreted as an unsigned host-side offset/length before it is passed in —
  that decoding is REQ-171/172's host-function-layer responsibility. This design's
  contract requires callers to have already produced a plain (possibly-invalid, per the
  defensive guard) integer by the time `read/4`/`write/4` is called.
- **OQ-D2 — the exact threshold between `wasmex`'s "still clean" and "aborts" behavior
  (§1.4) was not narrowed below the `2^32`-to-`2^40` gap.** Not needed for this design's
  own correctness (§2's check rejects everything above the real memory size, which is
  always far below `2^32` in practice), but worth a future `wasmex` upstream bug report
  — filed as an issue per `ISSUE_QUEUE.md`, not undertaken as part of this requirement's
  scope (ORCH allocates the id; this design only names the finding).
- **OQ-D3 — whether `MemoryGuard` should also expose single-byte `read_byte/3`/
  `write_byte/4` convenience wrappers around `read/4`/`write/4` (length=1).** Not added
  here since no acceptance criterion names one and REQ-171/172's real host functions do
  not exist yet to demonstrate a need; `read/4`/`write/4` already cover the single-byte
  case via `length: 1` / a 1-byte binary.
- **Where `Wasmex.Memory.grow/2` (REQ-169's cap-enforcement concern) is called from, and
  whether a grow can race with an in-flight `MemoryGuard` call within the same
  invocation** — out of scope here; per §2's design note, `MemoryGuard` always fetches
  size fresh per call, so even if this is possible it cannot produce a false-accept
  (only, at worst, a false-reject of an offset that became valid a moment after the
  check ran, which is a availability concern, not a safety one, and is not observed to
  be reachable within one guest invocation's single-threaded execution model).

None of these open questions block implementation.

---

## 8 — Traceability: REQ-168's 6 real acceptance criteria (`docs/requirements.yaml`) → design elements → planned tests

| # | Acceptance criterion (verbatim) | Design element | Planned test(s) (§5) |
|---|---|---|---|
| 1 | "a single validation function exists that every host-side read of guest memory goes through, and a repo search over lib/ restricted to '\*.ex' shows no other guest-memory read path, with the real output quoted" | §3 (module decision), §4 (`read/4`/`write/4` as the two sanctioned entry points; every other `Wasmex.Memory.*` call site forbidden) | Not an ExUnit test — an ELIXIR-DEV/RELEASE-VALIDATOR `grep -rn 'Wasmex.Memory\.' lib/ --include='*.ex'` demonstration, quoting real output, per §4's exact instruction |
| 2 | "a test asserts a malformed pointer from a guest yields a structured error outcome to the caller and the BEAM node stays up (the test process and the supervisor both survive), which is WASM-08's own acceptance criterion" | §4 `guard_error()`/`bounds_defect()` types; §1.3/§1.4 findings (why "moderate" out-of-range is safe to call live; why extreme magnitude is never reached) | §5.3 test 2 |
| 3 | "tests cover at minimum: an offset beyond the memory size, a length running past the memory end, and an offset+length pair that overflows -- each asserted to be rejected before any dereference" | §2 (exact algorithm, all three cases); §4 `check_bounds/3` (the pure, pre-dereference function these cases target directly) | §5.2 (all three cases, pure); §5.3 tests 3-4 (offset/length cases live, AC1 read/write paths) |
| 4 | "a test asserts two instances of the same module do not share linear memory: a write in one is not observable in the other" | §1.5 (live-verified finding this test restates as a permanent regression test) | §5.3 test 5 |
| 5 | "the moduledoc states that this validation bounds host-side dereferences only and does NOT bound a fault inside Wasmtime's own native code, which remains the residual class REQ-165's moduledoc discloses" | §6 (required moduledoc prose, citing `req165-wasmex-process-boundary.md` §7.2 verbatim) | §6's `moduledoc =~ ...` test |
| 6 | "mix test and mix compile --warnings-as-errors both pass with real output quoted" | Not a design element — an ELIXIR-DEV/TEST-RUNNER obligation; §4's plain tagged-tuple types (no opaque/dynamic typing) give both commands something meaningful to enforce | N/A |

### Handoff-specific meta-criteria (from this WF-02 run's own handoff, not in `docs/requirements.yaml` itself)

| Handoff AC | Design element |
|---|---|
| AC1 (handoff) — exact signature + where callers call it + how this design's own tests exercise it without a real host-function layer | §4 (`read/4`/`write/4` exact specs); §5 (test strategy against a fixture instance's real `Wasmex.Memory` handle, no REQ-171/172 dependency) |
| AC2 (handoff) — live-verification finding stated + exact error shape + no-escape guarantee | §1.3/§1.4 in full; §4 `bounds_defect()`/`guard_error()`; §1.6 (defensive `{:error,_}` pattern-matching regardless of a callee's own `@spec`) |
| AC3 (handoff) — exact arithmetic in words, why naive check is unsafe, what is done instead | §2 in full |
| AC4 (handoff) — isolation test + live-verification finding | §1.5; §5.3 test 5 |
| AC5 (handoff) — moduledoc cites REQ-165's exact section | §6 (quotes `req165-wasmex-process-boundary.md` §7.2 verbatim) |
| AC6 (handoff) — mix test / mix compile obligations | Row 6 above |
| "Zero literal Elixir code in the design doc" | §1/§2/§4/§5 use prose, tables, `@type`/`@spec`/`@doc` blocks, and one WAT fixture (not Elixir) only — no `def ... do ... end` body anywhere in this document |
| "Full traceability table" | This table plus `test/specs/REQ-168.md`'s test-case list |

---

## 9 — Confirmation: no existing WASM module is modified

This design adds exactly two new files: `lib/letflow/engine/wasm/memory_guard.ex` and
`priv/wasm_fixtures/req168_memory.wat`. `module_registry.ex`, `capability_gate.ex`, and
`plugin_handler.ex` are all unmodified — `MemoryGuard` depends on none of them (it
operates on a `Wasmex.StoreOrCaller.t()`/`Wasmex.Memory.t()` pair any caller already
holds, regardless of which of the three produced the underlying instance) and none of
them depends on `MemoryGuard` (wiring memory validation into a real invocation path is
REQ-171/172's job, per §7's open question, mirroring `req166`/`req167`'s identical
"wiring is a future dispatch-integration requirement's job" scope boundary). No new
`Task.Supervisor` or supervision-tree child spec is added (§3).
