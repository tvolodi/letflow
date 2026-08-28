# REQ-172 — WASM host API 2/2: write path (`write_variable`, `call_service`, `fail`) and the shared Lua/Wasm parity suite (WASM-12 write half + its own acceptance criterion)

**Requirement:** REQ-172 (queue task 324, GH#624)
**Stage:** S5
**Owner (design):** CODE-DESIGNER
**Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-28
**Depends on:** REQ-171 (done), REQ-161 (done)
**Consumes (unmodified):** `lib/letflow/engine/lua/platform.ex` (definition WASM
conforms to, decision 0014 (4)), `Letflow.Engine.Wasm.HostApi` (REQ-171, extended
additively here), `Letflow.Engine.Wasm.CapabilityGate` (REQ-167/171, extended
additively here), `Letflow.Engine.Wasm.MemoryGuard` (REQ-168),
`Letflow.Engine.Wasm.ResourceLimits` (REQ-169), `Letflow.Engine.Wasm.CallTimeout`
(REQ-170), `Letflow.Engine.LuaNumberMarshalling` (REQ-150)
**Extends:** `Letflow.Engine.Wasm.HostApi` (adds `do_write_variable/6`,
`do_call_service/8`, `do_fail/5`), `Letflow.Engine.Wasm.CapabilityGate` (adds
`write_variable`/`fail` rows to `@known_imports`, widens `platform_call_service`'s
declared signature from placeholder to real), `Letflow.Engine.Wasm.PluginHandler`
(REQ-165, existing/shipped — `call_export/3` gains a pre-stop fail-signal check, §2.2;
this is a small, additive change to an already-shipped function, required by this
requirement's own live-verified findings, not a re-scoping of REQ-165)
**Introduces:** the shared parity harness (`test/support/host_api_parity.ex`, test-only,
not `lib/`)

This is a **design artefact only** — no implementation code. Every code sample below is
a type/signature description (`@spec`-shaped), never a function body.

---

## 0 — What this requirement is, restated from the handoff

REQ-171 built the WASM-side read quarter of the host API (`read_variable`, `log`,
`now`, `uuid`) at parity with `platform.ex`. This requirement builds the **write**
quarter (`write_variable`, `call_service`, `fail`) and, distinctly, **WASM-12's own
acceptance criterion**: "Same test scenario passes against Lua implementation and Wasm
implementation of an equivalent script." That is not satisfied by two suites that
happen to assert similar things — REQ-171's own test file drove Lua and WASM
side-by-side *inline*, in each `describe` block, which is closer to "two suites with
matching intent" than "one scenario definition." This requirement replaces that pattern
with a genuine single named scenario registry, executed against both runtimes by one
harness (§8).

Per decision 0014 (4): **the Lua host API is the definition WASM conforms to.** This
design changes nothing under `lib/letflow/engine/lua/`. Every semantic rule below is
read from `lib/letflow/engine/lua/platform.ex` (cited by line number as of the commit
this design was written against) and restated for the WASM ABI, never re-derived. Where
the WASM ABI's own execution model forces a genuine, non-ABI semantic difference, §9
enumerates it explicitly with justification — WASM-12's own text limits differences to
ABI (string encoding, return shape), so an unlisted one means the requirement is not
met.

---

## 1 — The definition being conformed to (restated, not re-derived)

Read directly from `lib/letflow/engine/lua/platform.ex`:

- **`write_variable(name, value)`** (lines 736–755) stages into a **process-dictionary**
  buffer private to the one BEAM process executing the script — never into VM state.
  Malformed (non-string) `name` is a no-op (stages nothing, returns Lua `nil`); a
  well-formed write always succeeds and returns `[]` (nothing). Last-write-wins on a
  duplicate key (`Map.put/3` semantics). Every value crosses
  `LuaNumberMarshalling.from_lua/1`. Discard-on-failure needs **no dedicated
  mechanism** on the Lua side because the four failure arms (guest trap, instruction
  budget, wall-clock kill, heap-limit kill) and `fail` itself all either destroy the
  process outright or never reach a commit call — `take_staged_writes/0` (lines
  424–429) is a pure read-and-clear that nothing in `platform.ex` itself ever calls
  (design §2.5's OQ-1, deliberately unwired).
- **`call_service(service_id, payload)`** (lines 765–786) resolves an injected
  `ServiceCaller` from application env (`:lua_platform_service_caller`, default
  `NoServiceCaller`, read fresh every call). A **service failure** returns
  `[nil, error_table]` — never raises. A **missing `service:call:<id>` capability**
  raises at the fold level (`install/3`'s wrapper, line 477), one step before
  `call_service`'s own body is ever entered — the two are structurally distinct
  (raise-before-body vs. return-from-body), not merely differently worded.
- **`fail(reason, details)`** (lines 549–562, moduledoc "REQ-161") calls
  `exit({:script_failed, %{reason: ..., details: ...}})` from inside the native
  function itself. This is uninterceptable because `tv-labs/lua`'s `pcall`/`xpcall`
  boundary is `rescue`-only, and `rescue` has no clause that ever matches an `exit/1`.
  Ungated (`:none`, same as `now`) — a script may always terminate itself.

Every numeric value crosses `LuaNumberMarshalling.from_lua/1` (write direction) or
`.to_lua/1` (read direction) — no second numeric rule (REQ-150 §2.1/§2.2, reused
verbatim, exactly as REQ-171 §2 already established for the read quarter).

---

## 2 — Live-verification findings this design depends on (binding on ELIXIR-DEV)

### 2.1 — Host-function callbacks run in the Wasmex instance's OWN process, not the caller's; `exit/1` inside a callback does NOT crash that process

Read directly, not assumed: `deps/wasmex/lib/wasmex.ex` lines 542–582, and
`deps/wasmex/native/wasmex/src/environment.rs` lines ~140–250 and
`deps/wasmex/native/wasmex/src/instance.rs` lines ~390–430 (the Rust side of the same
call path — read *below* where CODE-DESIGN-VALIDATOR's rework request stopped, because
the Elixir source alone does not show what happens to a caught `exit/1`'s payload once
it crosses back into the WASM engine).

`Wasmex.call_function/4` is `GenServer.call(pid, {:call_function, ...}, timeout)`
(line 420) against the `pid` returned by `Wasmex.start_link/1`. When the guest calls an
imported host function, the NIF sends `{:invoke_callback, namespace, name, context,
params, token}` (line 543) to that **same `pid`** as a message, handled by
`handle_info/2` (line 542), which does `apply(callback, [context | params])` (line 564)
inside a `try/rescue/catch` (lines 557–578) whose `catch kind, reason ->` clause
(line 577) is **unbound on `kind`** — standard Elixir, and it catches `exit/1` exactly
like `:throw`/`:error`, producing `{false, [Exception.format_banner(kind, reason)]}`,
never re-raising. `handle_info/2` then calls
`Wasmex.Native.instance_receive_callback_result(token, false, results)` (line 580) and
returns `{:noreply, state}` (line 581) — **the Wasmex instance process does not crash,
does not terminate, and is not marked for termination in any way.** This part of
CODE-DESIGN-VALIDATOR's finding (commit bbc9af9's rework request) is independently
confirmed, both by re-reading the source and by a real repro (below).

**What actually happens to a caught `(false, results)` pair — traced into the Rust NIF,
not previously checked by this design or its own SS5.3 (which stopped at the Elixir
boundary):** `environment.rs`'s `link_imported_function/5` builds each host import as an
async Wasmtime host function. It sends the `:invoke_callback` message, then awaits a
`oneshot::channel` that `instance_receive_callback_result/3` (`instance.rs` line ~598)
resolves with the `(success, results)` pair `handle_info/2` computed. On `(false, _)`
(`environment.rs`, the host-function future's final `match`):

```
(false, _) => Err(WasmtimeError::msg("the elixir callback threw an exception"))
```

**The caught `reason`/`results` are discarded entirely** — replaced with this one fixed,
generic message, identical regardless of whether the callback exited, raised, or threw,
and regardless of what payload it carried. This `Err` is returned from the host
function's own Wasmtime call, which Wasmtime treats as the host function's call
**failing** — the surrounding `function.call_async/3` (`instance.rs` line ~416) sees this
as `Err(err)`; since it is a plain `wasmtime::Error` (not a `wasmtime::Trap`),
`err.downcast::<Trap>()` (`instance.rs` line 425) **fails**, so the caller-facing message
takes the *non*-trap branch: `"Error during function excecution: {reason}"` — no
`(<trap-kind>)` parenthetical. A genuine **guest trap** (e.g. an `unreachable`
instruction executed directly by guest bytecode, no host callback involved at all) *does*
downcast to `Trap`, taking the other branch: `"Error during function excecution
(<trap-kind>): {reason}"`.

**Real repro, run against the actual installed `wasmex` 0.15.1** (`mix.lock`; asdf-pinned
Elixir 1.20.3/OTP 29 toolchain, `MIX_ENV=test`, isolated per-workspace test DB — a WASM
module importing one host function, called three ways: the callback does `exit({:script_failed, ...})`, the callback does an ordinary `raise "bug"`, and — a separate call — the
guest itself executes `unreachable` with no callback involved):

```
call_exit (do_fail's own mechanism):
  {:error, "Error during function excecution: error while executing at wasm backtrace:\n    0:     0x67 - <unknown>!call_exit"}
  Process.alive?(pid) => true

call_raise (an ORDINARY bug inside some other callback):
  {:error, "Error during function excecution: error while executing at wasm backtrace:\n    0:     0x6e - <unknown>!call_raise"}
  Process.alive?(pid) => true

guest_trap (real `unreachable`, no callback):
  {:error, "Error during function excecution (wasm trap: wasm `unreachable` instruction executed): error while executing at wasm backtrace:\n    0:     0x7a - <unknown>!guest_trap"}
  Process.alive?(pid) => true
```

Two conclusions, both load-bearing and both replacing this design's prior claims:

1. **`fail` (via `exit/1`) IS distinguishable from a genuine guest trap** by message
   shape alone (absence vs. presence of the `(<trap-kind>)` parenthetical) — but this is
   a fragile, dependency-internal string format, not something this design relies on as
   the *primary* AC5 mechanism (§2.2 gives the real one).
2. **`fail` is BYTE-IDENTICAL, at the `Wasmex.call_function/4` boundary, to an ordinary
   accidental exception inside any other callback** (`do_write_variable`,
   `do_call_service`, or a future host function) — both produce the exact same generic
   string, and `do_fail/5`'s own `reason`/`details` payload is **completely discarded**
   by wasmex before it ever reaches the caller. This is the defect the handoff warned
   was possible ("indistinguishable... exactly the ambiguity AC5 requires you to rule
   out") and it is real: relying on the `Wasmex.call_function/4` return value alone
   cannot satisfy AC5. §2.2 is the mechanism this design uses instead.

### 2.2 — The real uninterceptable-AND-distinguishable mechanism: a process-dictionary signal, read before the instance is stopped

Because §2.1 establishes the Wasmex instance process **survives** a caught `exit/1`,
and because any process may read *another* living process's dictionary via
`Process.info(pid, :dictionary)` (a standard BEAM primitive — no special permission,
scoped to local processes), `do_fail/5` can leave a **positive, deliberate** signal in
its own process's dictionary, under a key nothing else in this module ever writes,
**before** calling `exit/1`. Nothing else can produce this signal by accident (an
ordinary bug in `do_write_variable`/`do_call_service` never touches this key), so its
mere presence — not any parsing of `reason` — is what distinguishes `fail` from both a
guest trap and an accidental callback exception.

```
# module attribute, Letflow.Engine.Wasm.HostApi -- namespaced identically to
# @staged_writes_pdict_key (§3.2), for the same "no ambiguity about which module
# owns this key" reason; a SEPARATE key, never conflated with staged writes.
@fail_signal_pdict_key {Letflow.Engine.Wasm.HostApi, :fail_signal}

@type fail_signal :: %{reason: String.t(), details: term()}
```

`do_fail/5`'s algorithm (§5.1's decoding unchanged) becomes: decode `reason`/`details`
exactly as §5.1 already describes, `Process.put(@fail_signal_pdict_key, %{reason:
reason_string, details: details})`, **then** `exit({:script_failed, %{reason:
reason_string, details: details}})` (the `exit/1` call itself is kept — not because it
crashes anything (§2.1: it doesn't), but because it is what triggers `handle_info/2`'s
`catch` clause, which is what makes Wasmtime treat the host call as failed and abort the
**guest's own `execute` call** uninterceptably (§5.2) — the mechanism's job is aborting
the call, not killing the process).

**Real repro, same toolchain, confirming the signal survives the round trip and reads
back correctly, and that an ordinary bug never produces it:**

```
=== fail path: stash pdict key then exit/1 ===
call_function result: {:error, "Error during function excecution: ..."}
pid alive after call: true
Process.info(pid, :dictionary) BEFORE stop:
  {:dictionary,
   [{{Letflow.Engine.Wasm.HostApi, :fail_signal}, %{reason: "boom", details: %{x: 1}}},
    {:"$initial_call", {Wasmex, :init, 1}}, {:"$ancestors", [...]}]}
fail_key entry found?: {{Letflow.Engine.Wasm.HostApi, :fail_signal}, %{reason: "boom", details: %{x: 1}}}
pid alive after GenServer.stop: false

=== ordinary bug path: callback raises, never stashes the key ===
call_function result: {:error, "Error during function excecution: ..."}   # same shape as above
fail_key entry found? (expect nil): nil

=== reading pdict AFTER stop ===
post-stop Process.info: nil
```

This confirms the signal is present if and only if `do_fail/5` actually ran, is absent
for both a guest trap and an accidental callback bug, and — critically — **disappears
the instant the instance is stopped**: `Process.info(pid, :dictionary)` on an
already-`GenServer.stop`ped `pid` returns `nil`. This is a **hard ordering
requirement**: whatever code observes `Wasmex.call_function/4`'s `{:error, _}` return
must call `Process.info(pid, :dictionary)` **before** any code path stops or otherwise
tears down that `pid` — not after.

**This creates a NEW risk exactly where the handoff flagged it:**
`Letflow.Engine.Wasm.PluginHandler.run_guest/3` (existing, shipped REQ-165 code,
`plugin_handler.ex` lines 121–127) calls `GenServer.stop(pid)`
**unconditionally, immediately after `call_export(pid, export, timeout_ms)` returns**,
on every path where `call_export/3` returns at all. Per §2.1, `fail`'s path now *does*
return normally from `call_export/3` (an ordinary `{:error, _}`, not a crash) —
exactly like a guest trap or `ResourceLimits` fuel exhaustion. Unless the fail-signal
check happens **inside** `call_export/3`, strictly before it returns to `run_guest/3`,
`run_guest/3`'s own `GenServer.stop(pid)` call destroys the process (and the pdict
signal with it) before anything downstream could ever observe it — reproducing, one
layer up, the exact indistinguishability AC5 forbids. **Resolution, required of
ELIXIR-DEV as part of this requirement:** `call_export/3` (`plugin_handler.ex` lines
154–162) gains one additional step on its `{:error, reason}` branch, *before*
returning to `run_guest/3`: read `Process.info(pid, :dictionary)`, look for
`@fail_signal_pdict_key`; if present, return a distinctly-tagged outcome (e.g.
`{:failed, reason, details}`, taken from the stash, not from the parsed message string)
instead of the current generic `{:error, "wasm guest call failed: ..."}`; if absent,
the existing generic-`{:error, _}` behavior is unchanged (covers a guest trap,
`ResourceLimits` fuel exhaustion, and — honestly — an undetected accidental callback
bug alike, since none of those set the key). `run_guest/3`'s own `GenServer.stop(pid)`
call (line 125) is unchanged and still runs on every path — it now simply always runs
*after* the check, never before, because the check is inside the function that returns
before `run_guest/3`'s stop call is reached. No change to `run_guest/3`'s own control
flow is required, only to `call_export/3`'s body.

The parity harness (§8) applies the identical ordering rule directly against a raw
`Wasmex.call_function/4` call it drives itself (§8.2), independent of `PluginHandler` —
this is the one place `PluginHandler` is exercised as production code the mechanism
must not silently break, not the only place the mechanism is tested.

### 2.3 — Discard mechanism per arm, restated now that `fail`'s real mechanism is known

**This simplifies relative to this design's prior (incorrect) claim** — `fail` no
longer has its own unique "process crashes via `exit/1`" story; it now shares the
identical destruction mechanism the guest-trap and fuel-exhaustion arms already have:

- Guest trap / fuel exhaustion / a `memory`-cap-triggered guest-side reactive `fail`
  (§3.4) / `fail` itself: `call_export/3` returns (an ordinary `{:error, _}` or, for
  `fail`, the newly-distinguished `{:failed, _, _}`, §2.2); `GenServer.stop(pid)`
  immediately follows (in `run_guest/3`, or the harness's own equivalent), destroying
  the process (and its staged-writes process dictionary, and — for `fail` specifically —
  the already-read fail-signal entry) before any future caller could read it. **Four**
  arms now share this one mechanism, not three-plus-a-separate-`fail`-story.
- Wall-clock timeout: unchanged from this design's original finding — the Wasmex
  instance process is never explicitly stopped, but it is also never handed to any
  caller that could read its process dictionary — the process leaks, abandoned, exactly
  as `call_timeout.ex` already discloses; the staged write is unreachable, not
  destroyed. The **observable guarantee is identical** (no caller ever commits it) even
  though the **mechanism differs** from the other four arms (explicit `GenServer.stop/1`
  vs. leak). ELIXIR-DEV must not claim "the process is killed" for this arm — say
  "abandoned, unreachable" instead, and the test for this arm (§8, AC2) must assert
  unreachability (no future call ever observes the write), not process death
  (`Process.alive?/1` on a leaked-by-design process is not a claim this design makes
  either way).

No dedicated rollback/undo mechanism is introduced for any of the five arms, exactly
mirroring `platform.ex`'s own "no special discard mechanism needed" conclusion — but
unlike Lua, WASM's proof is not uniform across arms (destruction for four, abandonment
for one) and this design states that plainly rather than asserting one uniform
mechanism that doesn't hold for the wall-clock case.

---

## 3 — `write_variable` (`do_write_variable/6`)

### 3.1 — ABI shape

Two input buffers (name, JSON-encoded value), no output buffer — this is the first
WASM host function this module set adds that receives structured guest→host data
without returning any bytes to the guest.

```
@spec do_write_variable(
        context :: wasmex_callback_context(),
        name_ptr :: integer(),
        name_len :: integer(),
        value_ptr :: integer(),
        value_len :: integer(),
        execution_context :: execution_context()
      ) :: integer()
```

Wire protocol (a **new** one-way protocol, distinct from §5.2's existing shared
string-return-buffer protocol, since there is no output buffer here):

- Both `(name_ptr, name_len)` and `(value_ptr, value_len)` are read via
  `MemoryGuard.read/4` (INV-HOSTAPI-3). Any bounds failure on either → `-2`, no write
  staged.
- `name` bytes must be valid UTF-8 (`validate_utf8/1`, reused from REQ-171) → else `-2`.
  There is no WASM analogue of Lua's "malformed (non-string) name is a silent no-op"
  arm (§9.2): every `name_ptr`/`name_len` pair the ABI accepts is inherently a byte
  sequence, so the only way a "name" can be malformed at this boundary is invalid UTF-8
  or a bad pointer, both already covered by `-2`.
- `value` bytes are `Jason.decode/1`'d (not `decode!/1` — INV-HOSTAPI-2, never raise).
  Decode failure → `-2`, no write staged.
- On success: the decoded value is passed through `LuaNumberMarshalling.from_lua/1`
  (REQ-150 §2.1, identical call-site pattern to `platform.ex`'s own
  `stage_write(name, LuaNumberMarshalling.from_lua(value))`), then staged via
  `stage_write/2` (§3.2) → returns `0`.

Guest-side encoding responsibility (documented, not implemented here): the guest JSON
-encodes its value the same way the host JSON-decodes it — an integer stays an integer,
a float (including a whole-number float, e.g. `3.0`) stays a float, exactly
`LuaNumberMarshalling`'s identity rule, so a guest author who wants `3.0` to remain a
float must emit `3.0` (not `3`) in the JSON bytes it writes — this is a guest-authoring
concern, not a host-side coercion; the host never inspects a decoded number's shape to
"fix" it.

### 3.2 — Staging mechanism

```
# module attribute, private to Letflow.Engine.Wasm.HostApi -- never read or written
# anywhere else under lib/, mirrors platform.ex's own @staged_writes_pdict_key naming
# exactly, but as a SEPARATE key/module: the two runtimes' process-dictionary entries
# can never collide because host-function callbacks execute in physically different
# processes per runtime (Lua: the process running Lua.eval!/2; WASM: the Wasmex
# instance's own GenServer process, per §2) -- a shared key would be harmless but this
# design keeps them namespaced per-module anyway, for the same "no second definition,
# no ambiguity about which module owns this state" reason platform.ex's own key is
# module-qualified.
@staged_writes_pdict_key {Letflow.Engine.Wasm.HostApi, :staged_writes}

@type staged_writes :: %{optional(String.t()) => term()}

@spec stage_write(name :: String.t(), value :: term()) :: :ok
# private -- reads Process.get(@staged_writes_pdict_key, %{}), Map.put/3's the new
# entry (last-write-wins, identical semantics to platform.ex's own stage_write/2),
# Process.put/2's the result back. Runs inside the Wasmex instance process (§2).
```

```
@doc """
Reads and CLEARS the calling process's write-staging buffer (%{} if none was ever
staged) -- the WASM analogue of Platform.take_staged_writes/0, same read-and-clear
contract, same "never called from anywhere in this module itself" discipline (§2.5
OQ-1 equivalent: a future dispatch-integration requirement is the first real caller,
and it MUST call this from inside the SAME Wasmex instance process that ran the guest
call -- i.e. from a callback invoked via handle_info/2, per §2 -- strictly after
Wasmex.call_function/4 has returned a success outcome to the ORIGINAL caller. Calling
it from any other process observes an empty map, by construction (process
dictionaries are per-process, never shared) -- this is the same structural discard
guarantee §2 describes, not a new one.
"""
@spec take_staged_writes() :: staged_writes()
```

### 3.3 — `@known_imports` row (extends `capability_gate.ex`, §6)

`capability: "var:write"` — mirrors `read_variable`'s own `"var:read"` naming
convention (not Lua's `"variable:write"` — §9.3 states this pre-existing token-space
divergence explicitly, inherited from REQ-167/171, not introduced here).
`params: [:i32, :i32, :i32, :i32]`, `results: [:i32]`, `stub: :write_variable`.

### 3.4 — The "memory cap" failure arm, restated honestly (WASM-10's own correction applies here too)

REQ-172's own acceptance criteria name "memory cap (REQ-169)" as one of the five
discard arms to test separately. Per `ResourceLimits`' own live-verified finding
(WASM-10's correction, decision 0014): `memory.grow` beyond the configured cap does
**not** trap — it returns the WebAssembly-standard `-1` growth-failure sentinel as an
ordinary successful call, and guest execution continues normally. There is therefore
**no host-observable failure signal from the cap alone** — a guest that never checks
`memory.grow`'s return value experiences no failure at all from hitting the cap, and
neither does its staged write.

**Restatement, mirroring the discipline decision 0014 already established for
WASM-10/WASM-11 (state the gap, do not fabricate a mechanism that doesn't exist):**
this design does not claim the memory cap itself is a distinct failure signal. The
"memory cap" discard-arm test (§8, scenario `write_then_memory_cap_fail`) exercises a
guest fixture that (a) stages a write, (b) attempts `memory.grow` past the configured
`memory_cap_bytes`, (c) observes the `-1` sentinel, and (d) **deliberately calls
`platform.fail`** in response (the fixture's own authored behavior, not a host
mechanism) — i.e., this arm is mechanically the `fail` arm (§5), triggered specifically
following an observed cap violation, and the test asserts discard via the identical
`fail` mechanism §5 provides. `ResourceLimits.memory_grew_within_cap?/3` (already
shipped, REQ-169) is what a real caller would use to confirm the cap itself held; this
requirement's own test additionally confirms that a guest which *reacts* to a capped
growth by failing leaves no half-applied write, closing the gap between "the security
property holds" (already proven, REQ-169) and "a script's own defensive failure after
observing it still discards cleanly" (this requirement's own scope).

---

## 4 — `call_service` (`do_call_service/8`)

### 4.1 — ABI shape

```
@spec do_call_service(
        context :: wasmex_callback_context(),
        service_id_ptr :: integer(),
        service_id_len :: integer(),
        payload_ptr :: integer(),
        payload_len :: integer(),
        out_ptr :: integer(),
        out_cap :: integer(),
        execution_context :: execution_context()
      ) :: integer()
```

`service_id` and `payload` are read via `MemoryGuard.read/4` and UTF-8/JSON-decoded
identically to `write_variable`'s inputs (§3.1) — `payload` decode failure or a missing
`payload` (guest passes `payload_len = 0`, the WASM analogue of Lua's optional second
argument) both default to `nil`, mirroring `platform.ex`'s own `List.first(rest)`
default. `service_id` must be valid UTF-8 and non-empty; a decode/UTF-8 failure on
`service_id` itself → `-2` (an ABI-level malformed call, not a service-level failure —
distinct from both outcomes below).

### 4.2 — The response envelope (ABI-only difference from Lua's multi-return, per WASM-12's own text)

Lua's `call_service` returns two distinct shapes via multiple return values:
`[response_table]` on success, `[nil, error_table]` on failure. WASM has no
multi-return-value convention over this buffer-based ABI, so the **same two logical
outcomes** are carried in **one** JSON envelope, written via the existing shared
string-return-buffer protocol (`write_buffer_result/4`, reused verbatim from REQ-171):

```
# success: {"ok": true, "value": <response, after convert_map_to_lua/1's WASM
#           analogue -- see §4.4>}
# failure: {"ok": false, "error": {"reason": <string>}}
```

`n >= 0` (the byte length written) is the only success/wrote-something signal, exactly
as `read_variable`/`now`/`uuid` already establish — the envelope's own `"ok"` field is
what the **guest** inspects to distinguish the two logical outcomes, the same
distinction Lua's caller makes by checking whether its second return value is `nil`.
`-2` covers every ABI-level failure (bad pointer, invalid UTF-8, undecodable JSON) —
this is purely a return-shape/encoding difference, not a semantic one (WASM-12's own
text: "differences confined to ABI... string encoding, return shape" — an envelope is a
return-shape choice).

### 4.3 — Service failure vs. missing capability: two structurally distinct outcomes (AC4)

**Service failure** (the injected `ServiceCaller` returns `{:error, reason}`): the
callback returns a well-formed envelope, `n >= 0` — an ordinary, successful host-call
return from Wasmtime's point of view. The guest reads the envelope, sees
`"ok": false`, and reads `error.reason`. This never traps, never crashes the Wasmex
instance process. Directly testable the same way REQ-160's own Lua test proves it
(`FakeServiceCaller`, injected via the exact same application-env key, §4.5).

**Missing `service:call` capability**: per REQ-172's own text ("a MISSING capability
still fails **per REQ-167**"), this is *not* a call-time check inside
`do_call_service`'s body at all — it is REQ-167's existing import-table-membership
mechanism, unchanged: a manifest lacking `"service:call"` produces an import table with
no `"platform_call_service"` entry (§6), so a module that imports it fails
**instantiation** (`{:error, {:instantiation_denied, {:unresolved_import, "env",
"platform_call_service"}}}`, REQ-167's own structured shape) — the guest's `execute`
export never runs at all. This is trivially, structurally distinguishable from a
service failure: one is an `{:error, {:instantiation_denied, _}}` return from
`CapabilityGate.start_instance/2` before any guest code exists as a running instance;
the other is a normal `{:ok, [n]}` return from `Wasmex.call_function/4` against an
already-running instance, carrying a `"ok": false` envelope. §8's parity harness
represents these as two different scenario entries precisely because they are
different call shapes, not merely different string content.

**Why this design does NOT add a call-time, per-service capability check inside the
callback body** (closing the granularity gap named in §9.4 by a different means):
`INV-HOSTAPI-2` (no `do_*` function may ever raise) forbids raising here, and returning
a *second* kind of structured `"ok": false` envelope for "capability missing" would be
indistinguishable, by shape, from an ordinary service failure — defeating this
requirement's own AC4 text ("the two behaviours asserted distinctly"), which is
satisfied *only* because the two outcomes are currently different call shapes
(instantiation failure vs. normal call return). Adding a call-time check would collapse
that distinction rather than sharpen it. §9.4 documents the resulting granularity
difference (WASM's `"service:call"` is an unparameterized, blanket grant; Lua's
`"service:call:<id>"` is parameterized per service) as a justified, non-ABI exception —
not something this design silently fixes.

### 4.4 — Marshalling and `ServiceCaller` reuse (no second injection mechanism)

`payload`'s decoded JSON object crosses `LuaNumberMarshalling.from_lua/1` one level
deep, exactly mirroring `platform.ex`'s own `normalize_from_lua/1` (a plain
`Map.new/2` over a JSON-object-shaped map needs no proplist-shape detection the way
Lua's table-decode does, since JSON objects are already real Elixir maps after
`Jason.decode/1` — one less step than Lua's `object_shaped_proplist?/1`, an ABI/
encoding simplification, not a semantic one). A successful response map crosses
`LuaNumberMarshalling.to_lua/1` the same way, one level deep, before `Jason.encode!/1`.

**`do_call_service/8` resolves the injected caller via the SAME application-env key
`platform.ex` already uses (`:lua_platform_service_caller`), the SAME default
(`Letflow.Engine.Lua.Platform.NoServiceCaller`), and the SAME behaviour
(`Letflow.Engine.Lua.Platform.ServiceCaller`) — no second `ServiceCaller` behaviour or
config key is introduced.** This directly extends the reuse precedent REQ-171 already
established for `now/0` (`do_now/3` calls `Platform.now/0` directly rather than
re-resolving `TimeSource` itself) to `call_service`'s own injection point. This is not
merely convenient: it is what makes §8's shared parity harness able to inject **one**
fake service double and observe both runtimes calling through it in the same test run
— a second, WASM-only config key would force the harness to configure two doubles for
what is supposed to be one shared scenario.

---

## 5 — `fail` (`do_fail/5`)

### 5.1 — ABI shape

```
@spec do_fail(
        context :: wasmex_callback_context(),
        reason_ptr :: integer(),
        reason_len :: integer(),
        details_ptr :: integer(),
        details_len :: integer()
      ) :: no_return()
```

No `execution_context` argument (mirrors `platform.ex`'s own `do_fail/2`, which also
ignores it) and no output buffer — there is no return, ever (§5.2). `reason_len = 0`
defaults to the same fallback string `platform.ex` uses ("script called platform.fail
with no reason"); `details_len = 0` defaults to `nil`. When present, `reason` bytes are
read via `MemoryGuard.read/4` and rendered as a UTF-8 string (invalid UTF-8 is rendered
via `inspect/1` on the raw bytes, mirroring `read_log_field/4`'s established fallback
pattern from REQ-171, rather than aborting differently from every other malformed-input
case in this module). `details` bytes, when present, are `Jason.decode/1`'d (never
`decode!/1`); a decode failure substitutes `nil` rather than changing this function's
uninterceptable-termination behavior in any way — **`do_fail/5` always terminates,
regardless of whether its own inputs are well-formed.** Decoded details cross
`LuaNumberMarshalling.from_lua/1` one level deep on any resulting map's values,
mirroring `platform.ex`'s own `decode_fail_details/2`.

### 5.2 — The uninterceptable-termination mechanism (revised: aborts the call, not the process — live-verified §2.1/§2.2)

```
Process.put(@fail_signal_pdict_key, %{reason: reason_string, details: details})
exit({:script_failed, %{reason: reason_string, details: details}})
```

both called from inside the callback body — which, per §2.1's live-verification
finding, runs inside the Wasmex instance's own GenServer process via `handle_info/2`.
**Corrected claim (this design's prior text was wrong, per CODE-DESIGN-VALIDATOR's
rework request and the live repro in §2.1): the `exit/1` call does NOT terminate that
process.** `handle_info/2`'s own `try/rescue/catch` (`wasmex.ex` line 577, `catch kind,
reason ->`, unbound on `kind`) catches `exit/1` exactly like `:throw`/`:error` — the
process survives, confirmed live (`Process.alive?(pid) == true` immediately after a
`call_exit` round trip, §2.1's repro).

**What `exit/1` actually accomplishes here, correctly stated:** being caught produces
`{false, results}`, which `instance_receive_callback_result/3` forwards into the
Wasmtime host-function future (`environment.rs`), which turns *any* `(false, _)` into
`Err(WasmtimeError::msg("the elixir callback threw an exception"))` — an ordinary
Wasmtime host-function failure, which aborts the **entire guest `execute` call**
(the surrounding `function.call_async/3` returns `Err`, propagated to
`Wasmex.call_function/4`'s caller as `{:error, _}`). This is real and still gives AC5
its uninterceptability: the guest's own `execute` code never resumes past the `fail`
call site — there is no return value for it to receive, inspect, or discard, and core
WebAssembly (the ABI this platform targets per `req163-wasm-abi-choice.md`'s Decision)
has no `pcall`/`catch` construct that could intervene even if there were. What `exit/1`
does **not** accomplish (contrary to this design's prior text) is killing the Wasmex
instance process — that claim is retracted; §2.1/§2.2 state what actually happens and
why it is still sufficient.

**Why the guest cannot "catch or ignore" this and continue (this requirement's own
AC5, the WASM analogue of REQ-161's AC1):** the guest's `execute` call itself never
resumes, for the reason above — not because a process died, but because Wasmtime
treats the host call as failed and aborts the in-flight guest execution before control
would ever return to guest code. `Wasmex.call_function/4`'s caller observes this as an
ordinary `{:error, _}` return (§2.1) — indistinguishable from a guest trap or an
accidental callback bug **by that return value alone**. §2.2 is what makes it
distinguishable: `do_fail/5`'s `Process.put/2` call above, read back via
`Process.info(pid, :dictionary)` strictly before the instance is stopped (§2.2's hard
ordering requirement). §5.3 restates the caller-facing contract this design now
depends on.

### 5.3 — What the calling code must do (live-verified, §2.1/§2.2 — supersedes the retracted `GenServer.call`-crash-wrapping claim)

This design's prior text expected `Wasmex.call_function/4`'s underlying
`GenServer.call/3` to crash and surface a wrapped `{{:script_failed, _}, {GenServer,
:call, _}}` reason via `Task.yield/2`'s `{:exit, reason}` clause. **That expectation was
false** (§2.1: no crash occurs at all; `GenServer.call` returns normally, `{:error, _}`,
same shape whether the underlying cause was `fail`, a guest trap, or an accidental
callback bug). The live-verified contract is instead:

1. `Wasmex.call_function/4` returns `{:error, msg}` for **all three** of: a guest trap,
   an accidental callback exception, and `fail` — `msg`'s text alone does not reliably
   distinguish `fail` from an accidental callback bug (§2.1's repro: byte-identical for
   those two; only a guest trap's message differs, by the presence of a
   `(<trap-kind>)` segment — a real but fragile, dependency-internal distinction this
   design does not rely on as the primary mechanism).
2. Whatever process called `Wasmex.call_function/4` (still holding `pid`, per §2.1 the
   Wasmex instance did not die) must, on `{:error, _}`, call `Process.info(pid,
   :dictionary)` **before** stopping or discarding that `pid`, and look for
   `@fail_signal_pdict_key` (§2.2). Present → this was `fail`; take `reason`/`details`
   from the stashed map (not from `msg`, which never carried them — §2.1). Absent →
   an ordinary `{:error, msg}` (guest trap or accidental bug; this design does not
   further distinguish those two, since AC5 only requires `fail` vs. trap
   distinguishability, and INV-HOSTAPI-2 already forbids any other `do_*` function from
   raising, so an "accidental bug" arm is not expected to occur in practice — only
   `fail`'s own path deliberately produces the signal).
3. `GenServer.stop(pid)` (or any process teardown) must happen strictly **after** step
   2 — reading the pdict of an already-stopped `pid` returns `nil` (§2.2's repro),
   which would silently collapse back into the exact indistinguishability AC5 forbids.

This is a **caller-side contract**, not a `Wasmex`-internal one — every piece of code
that calls `Wasmex.call_function/4` and needs `fail` to be distinguishable (§8's
harness; `PluginHandler.call_export/3`, §2.2) must implement steps 2–3 in this order.
§8.2 states the harness's own application of this contract; §2.2 states
`PluginHandler`'s.

Lua's own `{:script_failed, _}` observation (`platform_test.exs`'s REQ-161 harness,
`Task.yield/2`'s `{:exit, reason}` clause, bare and unwrapped, since `Lua.eval!/2` runs
inline in the calling process with no `GenServer.call` boundary) is a **structurally
different mechanism** from WASM's — not a return-shape variant of the same one, as this
design previously claimed. §9.5 restates this difference precisely.

### 5.4 — `@known_imports` row

`capability: :none` — mirrors `now`/`uuid`'s own `:none` sentinel (§4.1 of REQ-171's
design), for the identical reason `platform.ex` gates `fail` as `:none`: a script may
always terminate itself, and gating self-termination behind a capability would only
complicate the one guaranteed way a script has of signaling its own failure, without
protecting any reachable state. `params: [:i32, :i32, :i32, :i32]`, `results: []`
(never produced, since the callback never returns — declared only because Wasmtime
requires *some* function type for every import; the empty `results: []` matches `log`'s
own already-shipped precedent for a host function that produces no value on its only,
success-shaped path — `fail` has no success-shaped path, so this declared type is never
actually exercised, only present for import-table type-checking at instantiation).

---

## 6 — `capability_gate.ex` changes (additive, same mechanism, no second registry)

### 6.1 — `@known_imports` additions/changes

| `name` | `capability` | `params` | `results` | `stub` | Notes |
|---|---|---|---|---|---|
| `write_variable` | `"var:write"` | `[:i32,:i32,:i32,:i32]` | `[:i32]` | `:write_variable` | **New row.** |
| `fail` | `:none` | `[:i32,:i32,:i32,:i32]` | `[]` | `:fail` | **New row.** |
| `platform_call_service` | `"service:call"` (unchanged) | `[:i32,:i32,:i32,:i32,:i32,:i32]` | `[:i32]` | `:call_service` | **Signature change** from REQ-167's original 2-param placeholder (`params: [:i32,:i32]`) to the real 6-param shape (§4.1) — the same category of change REQ-171 already made to `read_variable` (2-param placeholder → 4-param real shape), same justification: the placeholder was explicitly documented as illustrative pending this requirement. |

`host_fn_spec/0` widens to include `:write_variable` and `:fail` (additive, same
pattern REQ-171 used for `:read_variable`/`:log`/`:now`/`:uuid`).
`build_callback/2` gains two new clauses (`:write_variable`, `:fail`) with the same
arity-matches-declared-params shape §4.7 of REQ-171's own design already established,
and its existing `:call_service` clause changes from `stub_callback/0` to a real
closure of arity 7 (`context` + 6 declared params) calling `HostApi.do_call_service/8`.

### 6.2 — Existing fixture that must be updated (ELIXIR-DEV, flagged explicitly — not a `lib/` change, but load-bearing for REQ-167's own still-passing tests)

`priv/wasm_fixtures/req167_platform_call_only.wat` declares
`(import "env" "platform_call_service" (func $platform_call_service (param i32 i32)
(result i32)))` — the OLD 2-param placeholder shape. `capability_gate_test.exs`'s own
`"granting service:call as well allows the same module to instantiate cleanly"` test
(and its sibling `"the returned pid is alive and usable"` test) instantiate this exact
fixture **with** `"service:call"` granted, expecting success. Once `@known_imports`'
`platform_call_service` row widens to the real 6-param signature (§6.1), the import
table's declared function type for `(env, platform_call_service)` no longer matches
this fixture's own declared import type — Wasmtime's instantiation-time type check
would then fail this fixture where it previously succeeded, which is not this
requirement's intent (the fixture's *purpose*, per its own header comment, is
"a module importing ONLY platform_call_service" — a generic stand-in for "any module
that imports this function," not a pin on the OLD illustrative signature). **ELIXIR-DEV
must update this fixture's declared import signature to the new 6-param shape** as
part of this requirement's implementation, so the pre-existing REQ-167 test continues
to assert what it always meant to assert (this specific import, granted, instantiates
cleanly) rather than accidentally start asserting a signature this design has replaced.
This is a `priv/wasm_fixtures/*.wat` change, not a `lib/letflow/engine/lua/*` change —
outside decision 0014 (4)'s "Lua is the definition" constraint entirely.

---

## 7 — `HostApi` module additions (signatures only)

```
alias Letflow.Engine.Lua.Platform  # already aliased, REQ-171 -- reused for Platform.now/0
                                     # (REQ-171) and, new here, Platform.ServiceCaller /
                                     # Platform.NoServiceCaller (§4.4) -- no new alias needed
                                     # beyond what REQ-171 already introduced.

@staged_writes_pdict_key {Letflow.Engine.Wasm.HostApi, :staged_writes}
@type staged_writes :: %{optional(String.t()) => term()}

@fail_signal_pdict_key {Letflow.Engine.Wasm.HostApi, :fail_signal}  # §2.2/§5.2 -- the
                                                                     # out-of-band
                                                                     # distinguishability
                                                                     # signal, a SEPARATE
                                                                     # key from staged
                                                                     # writes, written
                                                                     # only by do_fail/5.
@type fail_signal :: %{reason: String.t(), details: term()}

@spec do_write_variable(wasmex_callback_context(), integer(), integer(), integer(), integer(), execution_context()) :: integer()

@spec take_staged_writes() :: staged_writes()

@spec do_call_service(wasmex_callback_context(), integer(), integer(), integer(), integer(), integer(), integer(), execution_context()) :: integer()

@spec do_fail(wasmex_callback_context(), integer(), integer(), integer(), integer()) :: no_return()
```

Private helpers mirroring REQ-171's own established shape (`stage_write/2`,
`decode_json_field/2` — a `Jason.decode/1`-based sibling of REQ-171's
`read_log_context/3`, reused for `value`/`payload`/`details`, never `decode!/1`
anywhere in this module per INV-HOSTAPI-2), `build_response_envelope/1`
(`§4.2`'s `{"ok": ..., ...}` construction), `coerce_fail_reason/1`/
`decode_fail_details/1` (mirroring `platform.ex`'s own two eponymous private
functions, §1), and — new, §2.2/§5.2, not present in REQ-171's own helper set —
`stash_fail_signal/2` (`Process.put(@fail_signal_pdict_key, %{reason: ..., details:
...})`, called immediately before `do_fail/5`'s own `exit/1`, private, never called by
any other function in this module).

**Invariants restated (extend REQ-171's four, unchanged in substance):**

- INV-HOSTAPI-1/3/4 (no `Repo` call, all memory access via `MemoryGuard`, no
  `execution_context` from guest bytes) hold unchanged for all three new functions —
  none of `do_write_variable/6`, `do_call_service/8`, `do_fail/5` ever calls
  `Letflow.Repo`, exactly mirroring `platform.ex`'s own write-quarter functions (none of
  which call `Repo` either — only `emit_event`, not in either requirement's scope,
  does).
- INV-HOSTAPI-2 ("no function this module defines raises, ever") is restated with **one
  explicit, permanent exception: `do_fail/5`.** `do_fail/5` is the one function in this
  entire module whose entire purpose is to call `exit/1` on purpose — **corrected from
  this design's prior text (§2.1/§5.2): this does not terminate the Wasmex instance
  process** (`handle_info/2`'s own `catch` clause catches it, live-verified); it aborts
  the guest's in-flight `execute` call via Wasmtime's own host-function-failure
  propagation instead. This is still not a violation of INV-HOSTAPI-2's *intent*
  (INV-HOSTAPI-2 exists so a callback's accidental crash/abort isn't mistaken for a
  deliberate one) — `do_fail/5`'s deliberate `exit/1`, paired with its own
  `stash_fail_signal/2` call (above), is the mechanism that is both named and made
  distinguishable, tested as such (§5, §8), the direct parallel to how `platform.ex`'s
  own `do_fail/2` is the one function on the Lua side that is expected, by design, to
  never return — the parallel now holds at the level of "the one function whose
  `exit/1` is deliberate and load-bearing," not at the level of "the one function that
  crashes its own process," which was never true on the WASM side.

---

## 8 — The shared parity harness (WASM-12's own acceptance criterion)

### 8.1 — Location and shape

`test/support/host_api_parity.ex` (test-only — `test/support/`, not `lib/`, mirroring
this project's existing convention for shared test infrastructure, e.g.
`test/support/data_case.ex`, `test/support/tenant_fixture.ex`). **This is the single
named module the moduledoc-quoting acceptance criterion requires**; every parity test
file (`test/letflow/engine/wasm/host_api_write_test.exs`, this requirement's own file)
requires it and calls it, never re-implements a second copy of the dual-drive logic.

```
defmodule Letflow.Test.HostApiParity do
  @moduledoc \"\"\"
  REQ-172 (WASM-12's own acceptance criterion) -- the ONE scenario registry executed
  against BOTH Letflow.Engine.Lua.Platform (via Lua.eval!/2) and
  Letflow.Engine.Wasm.HostApi (via a running Wasmex instance), asserting identical
  CANONICAL outcomes. A future host function REQ-172 or a later requirement wires into
  BOTH @known_imports (capability_gate.ex) and platform.ex's @capability_matrix is
  structurally forced to add a scenario() entry here -- see the exhaustiveness guard,
  §8.4/AC below -- rather than being able to ship parity-untested.
  \"\"\"

  @typedoc \"The one normalized shape both runtimes' raw results are folded into before
  comparison -- this is what makes 'identical observable outcomes' assertable at all
  across two structurally different ABIs (Lua multi-return vs. WASM buffer-out/status
  code).\"
  @type outcome ::
          {:ok, term()}
          | {:error, reason :: String.t()}
          | {:denied, capability :: String.t()}
          | {:failed, reason :: String.t(), details :: term()}

  @typedoc \"One entry in the fixed scenario registry (§8.4 for the map this type
  populates). `parity` distinguishes a genuinely dual-runtime scenario from a
  documented WASM-only addition (uuid, no Lua counterpart -- REQ-171 §3) which this
  harness still registers, so the exhaustiveness guard covers it, but never drives
  through run_lua/1.\"
  @type scenario :: %{
          required(:host_function) => atom(),
          required(:parity) => :full | :wasm_only,
          required(:run_lua) => (-> outcome()) | nil,
          required(:run_wasm) => (-> outcome())
        }

  @doc \"The fixed, exhaustive registry -- one entry per host function EITHER runtime
  currently implements for real (i.e. every capability_gate.ex @known_imports row whose
  stub is not the REQ-167 placeholder, plus every platform.ex @capability_matrix row
  with a real, non-:not_yet_implemented stub). As of this requirement: read_variable,
  log, now, uuid (:wasm_only), write_variable, call_service, fail -- seven entries.
  get_instance_state and emit_event are Lua-only (no WASM host function implements
  them as of this requirement) and are DELIBERATELY ABSENT -- see the exhaustiveness
  guard's own exclusion list, stated by name, not inferred.\"
  @spec scenarios() :: %{atom() => scenario()}

  @doc \"Runs one scenario's run_wasm/0 (and, when parity: :full, its run_lua/0),
  asserting the two canonical outcomes are equal via ExUnit.Assertions.assert/1 (raises
  ExUnit.AssertionError on mismatch, exactly like any other test assertion -- this
  function is meant to be called FROM inside a test, not as a bare boolean predicate).
  For :wasm_only, only run_wasm/0 is invoked and no comparison is made -- the scenario
  still exists so §8.4's exhaustiveness guard accounts for it.\"
  @spec assert_parity(scenario()) :: :ok
end
```

### 8.2 — Normalizing each runtime's raw result into `outcome()`

Description only (the normalization logic itself belongs in each scenario's
`run_lua`/`run_wasm` closure, built by the real test file, not in the harness module's
own body — the harness enforces the *shape*, not each function's own mapping):

- **Lua**: `{[value], _lua}` from a successful call → `{:ok, value}`;
  `{[nil, err_table], _lua}` → `{:error, err_table["reason"]}`; a raised
  `Lua.RuntimeException` whose `exception.original[:capability_required]` is present →
  `{:denied, exception.original[:capability_required]}`; an observed
  `{:exit, {:script_failed, %{reason: r, details: d}}}` (via `Task.yield/2`, exactly
  `platform_test.exs`'s own REQ-161 harness, §1 above) → `{:failed, r, d}`.
- **WASM**: a successful `Wasmex.call_function/4` call whose decoded envelope/buffer
  represents success → `{:ok, value}`; the `call_service` envelope's `"ok": false`
  arm, or `write_variable`'s/`read_variable`'s numeric error codes mapped back to a
  reason string → `{:error, reason}`; `CapabilityGate.start_instance/2`'s
  `{:error, {:instantiation_denied, {:unresolved_import, _, capability}}}` →
  `{:denied, capability}`; for `fail` specifically — **not** a crash shape (§5.2/§5.3
  retract that claim; live-verified, §2.1) — the scenario's own `run_wasm/0` closure
  must itself hold the raw `pid` it started, observe `Wasmex.call_function/4`'s
  ordinary `{:error, _}` return, call `Process.info(pid, :dictionary)` **before**
  stopping that `pid` (§5.3's caller-side contract), and check for
  `@fail_signal_pdict_key`: present → `{:failed, r, d}` using the stashed `reason`/
  `details`, never the discarded `msg` text; this is the one scenario whose `run_wasm/0`
  closure cannot be a bare `Wasmex.call_function/4` wrapper the way every other
  scenario's can — it must manage its own `pid` lifecycle to honor the ordering
  requirement, and the harness's own moduledoc/§8.1 should note this asymmetry so a
  future scenario author does not copy the simpler pattern for a mechanism that needs
  it.

### 8.3 — What "identical observable outcomes" means here, precisely

Equality is asserted on the **normalized `outcome()` term**, not on the raw runtime
-specific return shape (which differ by construction — Lua multi-return vs. WASM
buffer/status code — an ABI difference WASM-12's own text permits). Two scenarios where
this bites and must be stated: (1) `call_service`'s missing-capability case normalizes
Lua's `:call_service`-scoped denial (`"service:call:billing"`, parameterized) and
WASM's denial (`"service:call"`, unparameterized) to **two different capability
strings** in their respective `{:denied, _}` outcomes — the harness does **not** assert
these are equal to each other for this one scenario (doing so would falsely claim a
parity that §9.4 explicitly documents does not hold); instead this scenario's own
`assert_parity/1` call is scoped to assert *shape* parity (`{:denied, _}` on both
sides, not `{:ok, _}` on one and `{:denied, _}` on the other) — the exact string is
asserted per-runtime, separately, in the surrounding test, not folded into the
cross-runtime equality check. (2) `fail`'s `details` field, when the guest supplies a
table/JSON object, is asserted for key/value equality after JSON round-tripping (both
runtimes decode to a plain Elixir map by the time `assert_parity/1` compares them) —
number *type* (integer vs. float) is asserted equal too, per REQ-150's own identity
rule, the same discipline REQ-160's/REQ-171's own tests already apply.

### 8.4 — The exhaustiveness guard (forces a future host function to add a parity case)

A real test (not part of the harness module itself, in the parity test file) asserts:

```
assert MapSet.new(Map.keys(Letflow.Test.HostApiParity.scenarios())) ==
         MapSet.new([:read_variable, :log, :now, :uuid, :write_variable, :call_service, :fail])
```

against a **second, independently-derived** set read directly from
`Letflow.Engine.Wasm.CapabilityGate`'s own `@known_imports` (via a small, additive,
test-only accessor this requirement adds — `known_host_functions/0`, returning the
`stub` field of every row — mirroring `Letflow.Engine.Lua.Platform.capability_matrix/0`'s
own existing "exposed for introspection/testing" pattern) — **not** a second hand
-written literal list, which a future author could update in one place and forget the
other. A future requirement that adds an 8th `@known_imports` row without adding a
matching `scenarios()` entry fails this specific assertion, by construction, the same
"one fold, one place to add a row" discipline `platform.ex`'s own `@capability_matrix`
and `capability_gate.ex`'s own `@known_imports` already enforce for their own single
-registry invariants (INV-CAP-1/2) — this test is the parity-registry's own analogue of
those.

---

## 9 — Semantic differences enumerated (AC6 — WASM-12 limits differences to ABI; an unlisted one means the requirement is unmet)

**9.1 — Discard mechanism for `write_variable`'s wall-clock-timeout arm is abandonment,
not destruction** (§2). Observable guarantee (no caller ever commits the write) is
identical to Lua's; the underlying mechanism (leaked process vs. killed process) is not.
Justification: inherited from `CallTimeout`'s own already-accepted, already-disclosed
finding (REQ-170, decision 0014's WASM-11 correction) that a wall-clock-timed-out WASM
invocation cannot be terminated by any BEAM-side mechanism at all — this requirement
does not introduce the leak, it only states its consequence for staged-write discard
honestly rather than silently claiming a uniform "process death" story that would be
false for this one arm.

**9.2 — `write_variable`'s "malformed name" arm has no WASM equivalent** (§3.1). Lua's
`do_write_variable/2` has a real "non-binary `name` argument" arm because Lua is
dynamically typed and a script can pass any value as an argument; WASM's ABI only ever
delivers a `(ptr, len)` byte pair for `name`, which is inherently string-shaped —
the only ways it can be malformed are covered by the existing `-2` (bad pointer /
invalid UTF-8) code. This is a consequence of the two languages' own type systems, not
a design choice either side of the boundary controls.

**9.3 — `write_variable`'s capability token is `"var:write"`, not Lua's
`"variable:write"`** (§3.3). Pre-existing token-space divergence, inherited from
REQ-167/171 (`"var:read"` vs. `"variable:read"` already diverged before this
requirement) — not introduced or newly decided here; `CapabilityGate`'s own moduledoc
already states its `manifest()` is "Not `Letflow.Engine.Lua.Manifest`" (two distinct
data structures were already an accepted design fact).

**9.4 — `call_service`'s missing-capability granularity is coarser on WASM than on
Lua** (§4.3). Lua's `"service:call:<id>"` is parameterized per service, checked at
call time against the script's own first argument; WASM's `"service:call"` is a single,
unparameterized capability checked once, at import-table-construction/instantiation
time, before any guest byte is read — once granted, a WASM guest may call
`call_service` for **any** `service_id`, where an equivalently-configured Lua script
would still be denied per-service. **This is accepted, not fixed**, because closing it
via a call-time check inside `do_call_service`'s body would require either raising (
forbidden by INV-HOSTAPI-2, and would make a capability denial indistinguishable from a
guest trap) or returning a second structured-error shape indistinguishable from an
ordinary service failure (defeating this requirement's own AC4, which requires the two
to be assertable distinctly) — both routes make the requirement's own text *harder* to
satisfy, not easier. §8.3 states how the parity harness handles this scenario's
resulting asymmetry rather than silently asserting a false equality.

**9.5 — `fail`'s discard/observation mechanism is structurally different on WASM than on
Lua, not merely differently wrapped** (§2.1, §2.2, §5.2, §5.3 — this design's prior
text here was wrong and is retracted). On Lua, `exit/1` crashes the process actually
running the script — the same process `Task.yield/2` observes dying, directly, with a
bare `{:script_failed, _}` reason; no other mechanism is needed to distinguish `fail`
from any other Lua-side crash because Lua has no comparable "caught and discarded"
layer between the script and its caller. On WASM, `exit/1` inside `do_fail/5` is
**caught internally by `wasmex`'s own `handle_info/2`** (live-verified, §2.1) — the
Wasmex instance process does not crash at all, and `Wasmex.call_function/4` returns an
ordinary `{:error, _}` whose message text is **byte-identical** to what an accidental
exception in any other callback, or in some respects a guest trap, would produce.
WASM's `fail` is distinguishable from a guest trap and from an accidental callback bug
**only** because `do_fail/5` deliberately leaves a positive signal in its own process's
dictionary before calling `exit/1`, read by the caller via `Process.info/2` strictly
before the instance is stopped (§2.2) — a mechanism with no Lua-side analogue at all,
not a wrapping-depth difference in an otherwise-shared mechanism. §8.2's normalization
step is where this is resolved into one shared `outcome()` shape for comparison, but
the underlying mechanisms are genuinely different in kind, not just in return-value
depth, and this section says so plainly rather than understating it as a formatting
difference.

No other semantic difference beyond ABI (string encoding, return-envelope shape) is
known to this design. Any difference ELIXIR-DEV's implementation discovers that is not
listed here, and is not purely ABI, is a defect against this design — fix it or return
to CODE-DESIGNER for an explicit, justified addition to this section, per this
requirement's own text.

---

## 10 — Open questions (explicit, not silently resolved)

**OQ-1 (mirrors REQ-171's own OQ-1/REQ-160's OQ-1 for `take_staged_writes/0`):** no
caller of `Letflow.Engine.Wasm.HostApi.take_staged_writes/0` is wired by this
requirement — a future dispatch-integration requirement is the first real caller, and
must invoke it from inside the same Wasmex instance process that ran the successful
guest call (§3.2), strictly after a `{:complete, _}`-shaped outcome, mirroring
`platform.ex`'s own deferred wiring exactly. Not resolved here; flagged so the future
caller does not have to rediscover the constraint.

**OQ-2 (resolved during this rework, no longer open):** §5.2/§5.3's mechanism is now
live-verified against the actual installed `wasmex` 0.15.1 (asdf-pinned Elixir
1.20.3/OTP 29 toolchain, `MIX_ENV=test`, isolated per-workspace test DB — the sandbox
this design was reworked in does have a usable toolchain via `asdf`, contrary to this
design's own prior assumption that only implementation-time had one). The original
`GenServer.call`-crash-wrapping expectation was false; §2.1/§2.2 state the real,
repro-confirmed mechanism (no process crash; a process-dictionary signal read before
teardown). Left as a note for ELIXIR-DEV, not an open question: re-run an equivalent
probe against whatever `wasmex` version is actually resolved at implementation time if
`mix.lock`'s pin has moved, since this mechanism depends on `wasmex`'s own internal
`catch`/discard behavior (§2.1), which is not part of its public API contract and could
change across versions without a semver-visible break.

**OQ-3:** whether a future 8th/9th WASM host function (`get_instance_state`,
`emit_event`) is ever added is out of this requirement's scope entirely (decision 0014
(4) only requires WASM-12 parity for functions WASM actually implements; nothing
mandates WASM implement all 8 Lua functions). §8.4's exhaustiveness guard is scoped to
"whatever `@known_imports` currently has a real stub for," so it does not, by itself,
force `get_instance_state`/`emit_event` to ever be added — only forces a parity case
once/if they are. Not a gap this requirement needs to close.

---

## 11 — Test strategy and traceability (design-level; TEST-DESIGNER writes the real specs)

| Acceptance criterion | Design element |
|---|---|
| ONE shared scenario definition, both runtimes | §8 (`Letflow.Test.HostApiParity`), §8.4's exhaustiveness guard |
| Discard on every failure arm (trap, fuel, memory cap, wall-clock, fail) | §2 (mechanism per arm), §3.4 (memory-cap arm's honest restatement), §8's `write_then_*` scenario family |
| Success applies all writes, no partial state | §3.2 (`stage_write/2`'s last-write-wins, single-map staging — same "no intermediate call, no partial map" argument `platform.ex`'s own REQ-160 test already establishes, ported verbatim) |
| `call_service` structured error vs. missing capability, distinct | §4.3, §8.3 point (1) |
| `fail` uninterceptable, guest cannot catch/ignore and continue | §5.2, §5.3, §8.2's `{:failed, _, _}` normalization |
| Non-ABI differences enumerated with justification | §9 (five entries) |
| Lua is the definition; no Lua file modified | §1 (restated, not re-derived); this design touches `lib/letflow/engine/wasm/*.ex`, `priv/wasm_fixtures/*.wat`, `test/support/*.ex`, `test/letflow/engine/wasm/*.exs` only — `git diff --stat` scoped to this requirement's commits must show zero files under `lib/letflow/engine/lua/` |
| `mix test` / `mix compile --warnings-as-errors` pass | ELIXIR-DEV/TEST-RUNNER, not a design-time claim |

Scenario families §8's registry must cover, restated as a checklist for
TEST-DESIGNER (not new design content, a traceability index into §§3–5):

1. `write_variable`: single write retrievable; several writes accumulate,
   last-write-wins; empty-buffer-when-never-called; malformed value JSON → `-2`,
   nothing staged; number-type round trip (int and whole-number float, distinctly).
2. `write_then_guest_trap`, `write_then_fuel_exhaustion`, `write_then_memory_cap_fail`
   (§3.4), `write_then_wallclock_timeout`, `write_then_fail` — five distinct scenarios,
   each asserting `take_staged_writes/0` (called from the *test* process, distinct from
   whichever process staged the write, mirroring `platform_test.exs`'s own REQ-160
   cross-process discipline) observes `%{}`.
3. `call_service` success (round trip, number-type both directions), service failure
   (structured, `"ok": false`), missing capability (`{:instantiation_denied, _}`,
   `SpyServiceCaller`-equivalent proving the body is never entered — mirrors
   `platform_test.exs`'s own `SpyServiceCaller` mutation-testing-motivated test).
4. `fail`: default reason/details; explicit reason/details incl. a table-shaped reason
   rendered via the WASM-side `inspect/1`-equivalent; a guest fixture that calls `fail`
   and then contains **unreachable-in-practice** code after it (the WASM analogue of
   Lua's `pcall`-wrapped continuation attempt — since WASM has no `pcall`, the
   equivalent adversarial fixture is one whose `execute` export's own control flow
   would, if `fail` returned normally, proceed to a distinguishable second host call or
   a distinguishable return value; the test asserts that second call/value is never
   observed); a test that drives a genuine guest trap (e.g. an `unreachable` fixture,
   no `fail` involved) through the exact same `run_wasm/0`-style pdict-check path (§2.2,
   §5.3) and asserts it normalizes to `{:error, _}`, never `{:failed, _, _}` — proving
   the two are distinguished by the presence/absence of `@fail_signal_pdict_key`, not
   merely by asserting `fail`'s own path in isolation (mirrors `platform_test.exs`'s own
   AC3 distinguishability discipline, adapted to the mechanism §2.2 actually uses rather
   than a process-crash comparison, which does not apply here — §2.1/§5.2 — since
   neither a guest trap nor `fail` crashes the Wasmex instance process on WASM).
5. `capability_gate_test.exs`/`host_api_write_test.exs` regression coverage for §6's
   `@known_imports` changes (new rows present/absent per grant; widened
   `platform_call_service` signature; the updated `req167_platform_call_only.wat`
   fixture still instantiates cleanly when granted, per §6.2).

---

## Deliverables Summary

- `lib/letflow/engine/wasm/host_api.ex` — extended: `do_write_variable/6`,
  `take_staged_writes/0`, `do_call_service/8`, `do_fail/5`, plus private helpers (§7).
- `lib/letflow/engine/wasm/capability_gate.ex` — extended additively: two new
  `@known_imports` rows (`write_variable`, `fail`), `platform_call_service`'s signature
  widened from placeholder to real, `host_fn_spec/0` widened, `build_callback/2` gains
  two clauses and one changed clause, `known_host_functions/0` (new, test-support
  accessor, §8.4) (§6).
- `priv/wasm_fixtures/req167_platform_call_only.wat` — updated import signature (§6.2),
  plus new fixtures this requirement's own tests need (guest fixtures exercising
  write/call_service/fail — named per TEST-DESIGNER's own convention, not fixed here).
- `lib/letflow/engine/wasm/plugin_handler.ex` — extended additively: `call_export/3`
  (lines 154–162) gains a pre-return, pre-`GenServer.stop/1` check of
  `Process.info(pid, :dictionary)` for `@fail_signal_pdict_key`, producing a distinct
  `{:failed, reason, details}`-shaped outcome instead of the current generic
  `{:error, "wasm guest call failed: ..."}` when the key is present (§2.2). No change
  to `run_guest/3`'s own control flow or its existing unconditional `GenServer.stop/1`
  call.
- `test/support/host_api_parity.ex` — **new**, the shared parity harness (§8).
- `test/letflow/engine/wasm/host_api_write_test.exs` (or equivalent) — new test file
  using the harness, per §11's scenario checklist.
- **No file under `lib/letflow/engine/lua/` is modified** (§1, §11's traceability row).
