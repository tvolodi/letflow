# REQ-170 — WASM per-invocation wall-clock timeout enforced across the process boundary (WASM-11)

**Requirement:** REQ-170 (WASM-11, MUST; adjacent to decision 0014's OQ-5)
**Stage:** S5
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-28
**Depends on:** REQ-169 (`lib/letflow/engine/wasm/resource_limits.ex`, gate-approved,
its `classify_call_result/1`/`call_classification()` convention this design's own
classifier mirrors and must stay textually disjoint from); REQ-165
(`lib/letflow/engine/wasm/plugin_handler.ex`, `lib/letflow/engine/plugin_interface.ex`
— both read directly, in full, this session, not as restated by any later design);
decision 0014's containment argument point (ii) and OQ-5, read directly.

This is a design artefact — `@spec`/`@type` signatures and prose only, no function
bodies. See `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1.

---

## 0 — Why this design's structure is dominated by one finding, and how to read it

The handoff's mandatory live verification found something more severe than REQ-166
through REQ-169's own divergences: **decision 0014's containment-argument point (ii) —
"`wasmex` documents that a timed-out call is interrupted and its Store stays usable,
which is the interruption primitive WASM-11 needs" — is FALSE, live-verified, not
merely imprecisely worded.** A genuinely hanging guest (an unconditional `br`-loop, the
same fixture shape REQ-165/169 already use) does **not** get interrupted by `wasmex`'s
documented timeout mechanism at any bound tested up to 30 seconds. Reading
`wasmex`'s own native source (`deps/wasmex/native/wasmex/src/instance.rs`,
`store_executor.rs`, `engine.rs`) explains why: the interrupt path exists in the code
(`with_deadline`, epoch ticking, `store.epoch_deadline_callback`), but — live-verified,
not merely read — it never actually fires for this fixture, and the guest's native
execution, once dispatched to `wasmex`'s own internal, node-global Tokio worker-thread
pool, **runs forever with no BEAM-side mechanism able to reach or cancel it** — not a
process kill, not a link death, not dropping the owning resource. This is worse than a
"Store becomes unusable" divergence; it is a **permanently leaked, uncancellable native
compute resource per timed-out invocation**, and enough of them exhaust a pool shared
by every tenant's WASM calls on the node. §1 records every live probe. §2 states
plainly what this changes about WASM-11's literal text and about REQ-170's actual
deliverable. §3 answers the handoff's "is this substantially already covered by
REQ-165's `PluginInterface`" question directly: **yes, for the caller-facing half**,
live-verified with zero new code. §4 designs the small amount of code that genuinely is
new. §8 states the OQ-5 evidence for ORCH per AC6's discipline.

**All probes are reproducible** at `scratch/req170_timeout_probe.exs` (git-ignored per
`core-directives.md`'s scratch rule, mirroring REQ-169's `scratch/req169_fuel_memory_probe.exs`
convention) with:

```
export PATH="$HOME/.asdf/shims:$HOME/.cargo/bin:$PATH"
WASMEX_BUILD=true MIX_ENV=test mix run scratch/req170_timeout_probe.exs
```

against the real installed `wasmex` v0.15.1 dependency. The script's six numbered
sections correspond to §1.1–§1.6 below; each finding quoted below is a real value this
session's actual run produced, not a prediction of what the script would show.

---

## 1 — Live verification findings (session of 2026-08-28, real installed `wasmex` v0.15.1)

### 1.1 `Wasmex.call_function/4`'s own documented timeout does NOT deliver a clean `{:error, _}` — it crashes the calling process with an ordinary `GenServer.call` timeout `exit`

Fixture (identical shape to `req165_hang.wat`/`req169_hang.wat`, reused conceptually,
not re-vendored):

```
(module
  (func (export "hang")
    (loop $forever
      br $forever)))
```

```
Wasmex.start_link(%{bytes: hang_wat})  # => {:ok, pid}
Wasmex.call_function(pid, "hang", [], 500)
```

Result: **not** `{:error, _}`. The calling process crashes:

```
** (exit) exited in: GenServer.call(#PID<0.297.0>, {:call_function, "hang", [], 500}, 500)
    ** (EXIT) time out
```

**Root cause, confirmed by reading `Wasmex.call_function/4`'s own source
(`deps/wasmex/lib/wasmex.ex:417-424`):** it always calls `GenServer.call(pid, {:call_function,
name, params, native_timeout(timeout)}, timeout)` — the **same** `timeout` value is used
both as the in-guest interrupt bound passed into the NIF *and* as `GenServer.call`'s own
client-side timeout. If the interrupt does not fire by the time `GenServer.call`'s own
clock runs out, the caller crashes via the ordinary BEAM `GenServer.call` timeout
mechanism — a ordinary `exit`, not a value `wasmex` itself produced or documented.

### 1.2 Decoupling the two timeouts shows the interrupt never fires — at any bound tested up to 30 seconds — and the Store never replies again

Calling the underlying `GenServer.call` directly (bypassing `Wasmex.call_function/4`'s
coupling) with a short interrupt bound (500ms) but a generous client-side timeout
(30,000ms):

```
GenServer.call(pid, {:call_function, "hang", [], 500}, 30_000)
```

Result: takes the **full** 30,000ms, then raises the ordinary `GenServer.call` timeout
`exit` — **no reply of any kind ever arrives**, clean or otherwise, at 500ms, 5,000ms,
15,000ms, or 30,000ms (all four bounds tested live). `Process.alive?(pid)` is `true`
throughout — the *calling* BEAM process and the `wasmex` `GenServer` process are both
fine; the stuck work lives entirely in `wasmex`'s own separate native worker-thread
pool, invisible to ordinary BEAM process introspection.

**A second call on the same `pid`, after the first has already crashed/exited, also
never replies** (re-probed with a fresh 15,000ms client bound) — the `Store`/`pid` is
not merely "not proven usable," it is live-confirmed **permanently wedged**: every
subsequent call queues behind the still-running first command inside `wasmex`'s
per-`Store` executor task (`StoreExecutor`, `store_executor.rs`), which processes one
command to completion before dequeuing the next, and the first command never
completes. **This directly contradicts decision 0014's cited claim ("keeps the Store
available for subsequent calls") and WASM-11's/AC2's own text asking this to be
verified — it does not hold, live-verified, not assumed.**

### 1.3 Why, read from `wasmex`'s own native source: the interrupt mechanism exists but a tight, call-free loop never reaches a working yield point in this build

`deps/wasmex/native/wasmex/src/instance.rs`'s `call_exported_function` submits the
guest call to a per-`Store` async executor (`store_executor.rs`), racing it against a
deadline via `with_deadline/3`. `engine.rs` unconditionally sets `config.epoch_interruption(true)`
(independent of `consume_fuel`), and a background `EpochTicker` increments the engine's
epoch every 10ms on `wasmex`'s own shared, node-global `TOKIO_RUNTIME`
(`std::thread::available_parallelism()` worker OS threads, falling back to 8).
`with_deadline/3`, on deadline expiry, sets an `interrupt_requested` flag and **still
`.await`s the original future to completion** rather than abandoning it — so even in
the mechanism's own designed-to-work path, a reply is only produced once the guest
future itself yields control back to the executor. For a tight `loop $forever br
$forever` with no function calls, whether Wasmtime's epoch check actually preempts
execution at the loop backedge, and whether that preemption is delivered as a
cooperative async yield the executor observes, could not be made to happen inside this
session's probes at any bound up to 30 seconds — this is stated as a live-verified
behavioral fact about this specific `wasmex`/Wasmtime build/fixture combination, **not**
diagnosed to a specific upstream root cause beyond what the source directly shows,
since going further (e.g. bisecting Wasmtime versions) is out of this requirement's
scope.

### 1.4 The underlying native execution is not reachable by ANY BEAM-side termination mechanism — link death, `Process.exit`, and `GenServer.stop` all fail to stop it

`Wasmex.start_link/1` (`deps/wasmex/lib/wasmex.ex:273`) really does call
`GenServer.start_link` — a genuine BEAM process link, confirmed by reading the source,
not assumed from the function's name. Three termination paths were tested live against
a `pid` linked to the calling process exactly as `PluginHandler.run_guest/2` links to it
today (`Wasmex.start_link/1` called from inside the dispatched task):

1. **The calling task crashing on its own `wasmex`-level `GenServer.call` timeout**
   (§1.1's shape, happening naturally inside `Task.Supervisor.async_nolink/2`): the
   task process exits; per ordinary BEAM link semantics this *should* propagate to the
   linked `wasmex` `pid` (which does not appear to trap exits). Whether or not the
   Elixir-side `wasmex` `GenServer` process itself dies from this, **the already-running
   native compute is unaffected** (§1.5's saturation test proves this conclusively,
   independent of whether the link theory holds).
2. **`Task.shutdown(task, :brutal_kill)`** (`PluginInterface.invoke/2,3`'s own existing
   mechanism, §1.1 of `plugin_interface.ex`): confirmed live to kill the *task* process
   promptly (`Process.alive?(task.pid)` is `false` immediately after) and to unblock the
   *caller* within the outer bound regardless of the inner `wasmex` timeout's value —
   even `:infinity` (§3 below). But when the killed task's own `Wasmex.start_link/1`
   call happened *outside* the killed process (this specific isolated probe), the
   `wasmex` `pid` it wasn't linked to obviously survives — an artifact of that probe's
   setup, not evidence either way about the linked case.
3. **Reading `deps/wasmex/native/wasmex/src/store_executor.rs` directly settles why
   none of the above can matter, regardless of link/kill semantics on the Elixir side:**
   the per-`Store` executor task is spawned via
   `crate::engine::TOKIO_RUNTIME.spawn(async move { ... })` with its `JoinHandle`
   **immediately discarded** — nothing in `wasmex` ever holds a handle capable of
   cancelling that spawned task. Even if the owning Elixir `GenServer` process and its
   Rustler resource were fully torn down, dropping the Rust-side resource does not
   preempt an **already-running, already-polled** Tokio task stuck inside a `.await` on
   a future that itself never yields (§1.3) — Tokio cooperative-cancellation only works
   at points the future itself chooses to check for cancellation, and a synchronous,
   non-yielding native loop has no such point. **No mechanism available from the BEAM
   side — link propagation, `Process.exit/2`, `Task.shutdown/2`, or `GenServer.stop/1`
   — can reach or terminate this already-dispatched native execution.** It runs until it
   completes on its own (never, for this class of guest) or the whole BEAM node
   restarts.

### 1.5 At scale: the leaked native compute exhausts `wasmex`'s node-global worker pool and stalls a completely unrelated, non-hanging guest call

`TOKIO_RUNTIME` (`engine.rs`) is a single `LazyLock` — **one runtime, shared by every
`wasmex` `Store` in the entire BEAM node**, sized to
`std::thread::available_parallelism()` (8 on this session's host; the OS reports
`nproc` = 8, `System.schedulers_online()` = 16 BEAM schedulers — a different count,
confirming the wasmex-native pool is a **distinct, smaller, node-global resource** from
BEAM's own scheduler pool).

Live test: dispatch `2 * System.schedulers_online()` (32) concurrent hangs through
`Letflow.Engine.PluginTaskSupervisor`, each exactly mirroring `PluginHandler`'s real
call shape (`Wasmex.start_link/1` then `Wasmex.call_function(pid, "hang", [])` at
`wasmex`'s own 5,000ms default). All 32 tasks crash/exit at ~5,000ms as §1.1 predicts —
confirmed in the supervisor's own error log
(`** (stop) exited in: GenServer.call(..., {:call_function, "hang", [], 5000}, 5000) ** (EXIT) time out`),
repeated once per task. **Two seconds after all 32 tasks had already crashed**, a
completely unrelated, trivial, non-hanging guest (`(func (export "answer") (result i32)
(i32.const 42))`) was dispatched fresh: `Wasmex.call_function(trivial_pid, "answer", [],
10_000)`. **It did not return within the outer script's own 58-second remaining budget**
and the process had to be killed by an external `SIGTERM` at the 60-second mark. A
guest that does nothing hazardous, belonging to no tenant involved in the original
hangs, was starved by resource exhaustion from invocations the caller had *already
received a clean error for and moved on from*.

### 1.6 The outer, already-shipped `PluginInterface.invoke/2,3` boundary DOES independently and reliably protect the caller — this is confirmed, not merely assumed

Isolated from §1.4/§1.5's leak finding: `Task.Supervisor.async_nolink/2` +
`Task.yield/2` + `Task.shutdown(task, :brutal_kill)`, run against a call configured
with `wasmex`'s own timeout at **`:infinity`** (the most adversarial case — no inner
bound at all):

```
task = Task.Supervisor.async_nolink(sup, fn -> Wasmex.call_function(pid, "hang", [], :infinity) end)
Task.yield(task, 500)  # => nil, at 501ms elapsed
Task.shutdown(task, :brutal_kill)
Process.alive?(task.pid)  # => false, immediately
```

**Confirmed:** the caller is reliably unblocked within the outer bound regardless of
the inner `wasmex`-level configuration, `:infinity` included. This is the mechanism
AC3 asks to be proven, and it already exists, unmodified, in
`Letflow.Engine.PluginInterface.invoke/2,3` (REQ-057/165). What §1.4/§1.5 show is the
**honest limit** of what that protection covers: it bounds how long the *caller*
waits; it does not, and by construction of the underlying native runtime cannot,
terminate the guest's *actual execution*.

---

## 2 — What §1 changes about WASM-11, decision 0014, and this requirement's actual deliverable

**WASM-11's literal text: "Exceeding the timeout MUST INTERRUPT EXECUTION." This is NOT
satisfiable against the live-verified behavior of `wasmex` v0.15.1 for a guest that does
not cooperate at a working Wasmtime yield point** (§1.1–§1.4). This design does not
fabricate an interruption that does not occur, and does not silently redefine
"interrupt" to mean "the caller stops waiting" without saying so — mirroring exactly
the discipline `req169-wasm-fuel-and-memory-cap.md` §2/§7 already established for
WASM-10's trap-that-does-not-occur.

**Intent restatement, stated explicitly per this requirement's own text and the
project's established restatement convention (`docs/requirements.yaml`
REQ-167/169's own restatement sections):** what this requirement delivers, and what is
live-verified true, is that **the host (the caller — the engine process, ultimately the
workflow instance dispatching to a plugin-claimed node) genuinely, reliably respects a
configured per-invocation bound and receives a structured error within it** — this is
WASM-11's own **acceptance criterion** text ("Host-blocking call respects timeout"),
which is a claim about the *host's* behavior, and does hold. The body clause "MUST
INTERRUPT EXECUTION" is the part that does not hold against `wasmex`'s real behavior for
a non-cooperating guest, and this design states that divergence here, in the moduledoc
(§6), and to ORCH (§8), rather than working around it silently.

**decision 0014's containment argument point (ii) is itself falsified by this live
verification** — not merely imprecisely worded, as WASM-10's divergence was. This is
recorded here as a finding for ORCH/REVIEWER, not silently absorbed: decision 0014
should be revisited (a follow-up decision-record amendment, not this design's job) to
downgrade point (ii) from "confirmed primitive" to "documented but live-disproven,"
and to weigh whether the residual risk this uncovers (§1.5's node-wide, cross-tenant
exhaustion via leaked native compute — worse than the already-disclosed "NIF crash
takes the whole node" risk, because it requires no crash or bug, just an ordinary
adversarial-by-default guest with a tight loop, exactly WASM-11's own threat model)
changes the WASM containment argument's overall adequacy conclusion. This design does
not decide that question — it states the evidence plainly, per this handoff's explicit
mandate (§8 formalizes it as the OQ-5-adjacent filing).

**What this requirement still delivers, concretely, and why it is a real, valuable
guarantee despite the above:** a **configurable, live-verified, reliable bound on how
long a caller (and by extension, a workflow instance's engine process) ever waits for a
WASM plugin invocation**, with a structured, caller-facing error on breach — via the
mechanism §3/§4 specify. This is not nothing: an adversarial-by-default guest cannot
hang the *calling process*, cannot hang the workflow engine indefinitely, and the
caller can always move on (mark the node failed, retry, alert) within a bound it
controls. What it cannot do — and must not claim to do — is guarantee the underlying
native resource is reclaimed. That gap is §8's filing, not this design's fix.

---

## 3 — Is this substantially already covered by REQ-165's `PluginInterface`, or does it need new code? Answered directly, per the handoff's explicit instruction

**Split answer, stated precisely rather than as one verdict for the whole requirement:**

**AC3 (the outer supervised-task boundary independently terminates the invocation) is
FULLY covered by existing, unmodified code — zero new code needed.**
`Letflow.Engine.PluginInterface.invoke/2,3`'s existing algorithm
(`Task.Supervisor.async_nolink/2` + `Task.yield/2` + `Task.shutdown(task,
:brutal_kill)` on the `nil` branch, `handle_yield_result/4`'s existing `{:exit,
reason}` clause) already does exactly what AC3 asks, live-verified in §1.6 against
this requirement's own hang fixture, with `PluginInterface`, `plugin_interface.ex`
**completely untouched** by this design. The two structured error shapes AC3/AC5 need
(§4 `CallTimeout.classify/1`) are built from strings this existing code **already**
produces (`handle_yield_result/4`'s `nil` clause and `{:exit, reason}` clause, quoted
verbatim in §4) — no change to `plugin_interface.ex` is needed to produce them.

**AC1/AC4 (a configurable per-invocation wall-clock timeout that a caller can drive to
two different values, with the tighter one binding sooner) is NOT yet covered — genuine
new code is needed, but it is small.** `Letflow.Engine.Wasm.PluginHandler.call_export/2`
(REQ-165) currently calls `Wasmex.call_function(pid, export, [])` with **no** explicit
timeout — it silently inherits `wasmex`'s own hardcoded 5,000ms default
(`deps/wasmex/lib/wasmex.ex:419`). There is no configuration surface today. §4 adds
one, following the exact `node_config`-driven convention `PluginHandler` already
established for `"wasm_fixture"`/`"export"` (`plugin_handler.ex` lines 60-77) — this is
a natural extension of an existing pattern, not a new one.

**AC2 (verify the interrupt-and-keep-Store claim) and AC6 (OQ-5 discipline) require no
new production code at all** — they are live-verification-and-disclosure obligations,
discharged by §1/§2/§6/§8 of this document and by the moduledoc content §6 mandates.

**AC5 (distinguishable by pattern match from REQ-169's fuel/memory errors) needs one
small new pure classifier function** (§4 `CallTimeout.classify/1`) — not a change to
`ResourceLimits`, which stays exactly as REQ-169 shipped it.

---

## 4 — What is new: `Letflow.Engine.Wasm.CallTimeout`, plus a small `PluginHandler` extension

### 4.1 Module location and scope boundary

Per the handoff's instruction and this project's established one-module-per-concern
precedent (`req166`/`req167`/`req168`/`req169`'s own §2.2/§0/§3/§3 sections): the
wall-clock timeout's **configuration surface** and its **structured error
classification** are one new, small, orthogonal concern — distinct from
`ResourceLimits`'s fuel/memory concern, `PluginHandler`'s dispatch concern, and
`PluginInterface`'s generic crash-safety concern (which stays entirely unmodified,
per §3).

**Decision: `Letflow.Engine.Wasm.CallTimeout`, new file
`lib/letflow/engine/wasm/call_timeout.ex`.**

**Scope boundary, stated explicitly:** this module owns (a) the `config()` shape a
caller uses to specify the wasmex-level per-invocation timeout, and (b) a pure
classifier over an already-completed `PluginInterface.invoke/2,3` outcome, telling a
caller whether a given `{:error, reason}` is specifically this requirement's
wall-clock-timeout shape. It does **not** dispatch a guest call itself (`PluginHandler`'s
job, extended per §4.3 below) and does **not** touch `PluginInterface`'s crash-safety
algorithm at all (§3 — that algorithm is reused exactly as REQ-165/057 shipped it).

### 4.2 Public contract: `Letflow.Engine.Wasm.CallTimeout`

```
defmodule Letflow.Engine.Wasm.CallTimeout do
  @typedoc "Caller-supplied, per-guest-invocation wall-clock configuration -- AC4's
  required configurability. `timeout_ms` is the value threaded into
  Wasmex.call_function/4's own 4th argument (PluginHandler.call_export/3, S4.3) --
  per S1.1's live finding, THIS is the value that actually, deterministically bounds
  how long a caller waits (via the ordinary GenServer.call client-side timeout
  mechanism), independent of whether wasmex's own internal interrupt ever fires.
  Never :infinity in production use -- a caller wanting no wasmex-level bound at all
  must still rely on PluginInterface's own separate, already-existing outer
  invoke_opts() timeout_ms (REQ-057) as the sole backstop in that case (S1.6's
  live-verified guarantee), which this module does not configure or duplicate."
  @type config :: %{required(:timeout_ms) => pos_integer()}

  @typedoc "AC5's own distinguishing contract: what this module's classify/1 reports
  about a completed Letflow.Engine.PluginInterface.invoke/2,3 outcome (NOT a raw
  Wasmex.call_function/4 return -- that is Letflow.Engine.Wasm.ResourceLimits'
  classify_call_result/1's own, separate input shape, S4.4 states the layering this
  entails).
  :wall_clock_timeout covers BOTH live-verified timeout shapes PluginInterface's own,
  UNMODIFIED handle_yield_result/4 already produces (S1.1/S1.6, quoted verbatim in the
  @doc below): the wasmex-level GenServer.call timeout crashing the task (observed via
  the existing {:exit, reason} clause) and the outer Task.yield/2 bound firing first
  (observed via the existing nil clause). Both are the SAME caller-facing guarantee
  from AC1/AC3's point of view -- the caller's wait was bounded and it received a
  structured error -- so this module does not force a caller to distinguish which
  internal layer actually fired; a future caller needing that distinction can pattern-
  match the underlying reason string further, but no acceptance criterion here asks
  for it.
  :not_timeout covers every other outcome() shape (:complete, or an {:error, reason}
  that does not match either known timeout signature -- e.g. a handler's own
  deliberate {:error, reason}, or a genuine crash unrelated to a timeout)."
  @type classification :: :wall_clock_timeout | :not_timeout

  @doc """
  Classifies an already-completed Letflow.Engine.PluginInterface.outcome() -- never
  calls invoke/2,3 itself, this module does not dispatch guest calls.

  Matches by substring against the two literal shapes
  Letflow.Engine.PluginInterface.handle_yield_result/4 already, unmodified, produces
  (plugin_interface.ex lines 217-224, quoted here verbatim since this module's
  correctness depends on that exact text not silently drifting):

    - the {:exit, reason} clause: `"plugin handler " <> inspect(handler) <> " crashed: " <> format_exit_reason(reason)`
      -- for S1.1's specific timeout shape, format_exit_reason(reason) on
      `{:timeout, {GenServer, :call, [pid, {:call_function, name, params, timeout}, timeout]}}`
      falls to format_exit_reason/1's final `inspect(reason)` clause (the 2-tuple's
      second element is itself a 3-tuple, not a list, so the `{exception, stacktrace}
      when is_list(stacktrace)` clause does not match), producing a string containing
      the literal substring `"{:timeout, {GenServer, :call,"` -- live-confirmed exact
      text, S1.1.
    - the nil clause: `"plugin handler " <> inspect(handler) <> " did not respond within " <> to_string(timeout_ms) <> "ms"`
      -- literal substring `"did not respond within"`.

  A reason string matching EITHER substring classifies as :wall_clock_timeout; every
  other outcome() shape (:complete, or any {:error, reason} not matching either
  substring) classifies as :not_timeout.

  Distinguishability from Letflow.Engine.Wasm.ResourceLimits.classify_call_result/1's
  own :fuel_exhausted / {:trap, raw_message} shapes (REQ-169) holds by TWO independent
  properties, not merely by accident of current string content (S4.4 details the
  layering): (1) type shape -- ResourceLimits' classifier returns an atom or a
  {:trap, binary()} tuple from a RAW Wasmex.call_function/4 return; this classifier
  returns :wall_clock_timeout | :not_timeout from a PluginInterface OUTCOME (a value
  one call-layer higher, produced only after a full invoke/2,3 round-trip, never a
  bare wasmex return); (2) even compared textually, neither of REQ-169's own
  live-verified strings ("all fuel consumed by WebAssembly", any raw Wasmtime trap
  message) contains "did not respond within" or "{:timeout, {GenServer, :call," and
  neither of this module's two substrings appears in a fuel/trap message, confirmed
  by direct inspection of both live-captured string sets (S1 here, REQ-169 S1.1/S1.6).
  """
  @spec classify(Letflow.Engine.PluginInterface.outcome()) :: classification()
end
```

### 4.3 `PluginHandler` extension: threading `CallTimeout.config()`'s `timeout_ms` into the existing `node_config`-driven fixture/export convention

**No new module for this half — a small, additive extension to
`Letflow.Engine.Wasm.PluginHandler` (REQ-165), following the exact pattern already
established for `"wasm_fixture"`/`"export"`** (`plugin_handler.ex` lines 60-77,
`Map.get(node_config, key, default)`).

- `handle_node/1` reads a third `node_config` key, `"timeout_ms"`, defaulting to a new
  module attribute `@default_wasmex_timeout_ms` (recommend `5_000`, matching `wasmex`'s
  own documented default exactly — this design does not invent a new default value out
  of nothing; it makes the existing implicit default explicit and overridable).
- `run_guest/2` gains a third parameter, `timeout_ms :: pos_integer()`, threaded through
  to a `call_export/3` (extending today's `call_export/2`).
- `call_export/3`'s only change from today's `call_export/2`: passes `timeout_ms` as
  `Wasmex.call_function/4`'s explicit 4th argument, in place of today's implicit
  3-arity call that silently accepts `wasmex`'s own default.

```
@spec handle_node(ExecutionContext.t()) :: Letflow.Engine.PluginInterface.outcome()
# unchanged signature/contract -- only its body reads one more node_config key

@spec run_guest(fixture :: String.t(), export :: String.t(), timeout_ms :: pos_integer()) ::
        {:ok, integer()} | {:error, String.t()}
# extends today's run_guest/2 with the new parameter, no other change

@spec call_export(pid(), export :: String.t(), timeout_ms :: pos_integer()) ::
        {:ok, integer()} | {:error, String.t()}
# extends today's call_export/2; internally calls
# Wasmex.call_function(pid, export, [], timeout_ms) instead of
# Wasmex.call_function(pid, export, [])
```

**This is the ONLY change to `plugin_handler.ex` this design specifies.** No change to
`read_fixture/1`, `start_instance/1`, or `handle_node/1`'s outer shape/error handling —
those stay exactly as REQ-165 shipped them. **`plugin_interface.ex` is not modified at
all** (§3).

### 4.4 Why the two classifiers live in different modules, at different layers, and both stay unmodified by each other

`Letflow.Engine.Wasm.ResourceLimits.classify_call_result/1` (REQ-169) classifies a
**raw** `Wasmex.call_function/4` return — it runs *before* any
`PluginInterface.invoke/2,3` round-trip exists, because no REQ-171/172 host function
wires `ResourceLimits` into a real dispatch path yet (REQ-169 §3's own stated
boundary, unchanged here). `Letflow.Engine.Wasm.CallTimeout.classify/1` classifies an
**already-complete** `PluginInterface.outcome()` — a value that can only exist after a
full `invoke/2,3` round-trip, including its own crash-safety handling. **These are
genuinely different values from different layers of the same call, not two competing
classifiers over the same data** — a future dispatch-integration requirement wiring
`ResourceLimits` into `PluginHandler`'s real instantiation call (both REQ-169 §3 and
this design's §3 already name this as future work) will need to compose both: classify
the raw call result with `ResourceLimits.classify_call_result/1` first, and only if
that function never got a raw result to classify at all (i.e., the outer `invoke/2,3`
itself reports an `{:error, _}` because the task crashed or timed out before
`Wasmex.call_function/4` ever returned anything), fall back to
`CallTimeout.classify/1` on the `invoke/2,3` outcome. This design states that future
composition point rather than building it prematurely (mirrors REQ-166–169's own
"wiring is a future requirement's job" boundary) — see Open Questions §9 OQ-2.

---

## 5 — Test strategy

No REQ-171/172 host function exists yet, and `PluginHandler` is (unlike `ResourceLimits`/
`CapabilityGate`/`MemoryGuard`) already wired into a real, dispatchable
`PluginInterface.invoke/2,3` path — so, unlike REQ-166–169, this requirement's tests
CAN and SHOULD exercise the real end-to-end path
(`PluginInterface.invoke/2,3` → `PluginHandler.handle_node/1` → `Wasmex.call_function/4`),
not a bypass of it.

### 5.1 New fixture, `priv/wasm_fixtures/`

- `req170_hang.wat` — identical shape to `req165_hang.wat`/`req169_hang.wat` (an
  unconditional `br` loop), duplicated as a permanent, dedicated fixture per this
  project's established one-fixture-per-requirement convention
  (`req169-wasm-fuel-and-memory-cap.md` §5.1's identical reasoning). No new "mixed"
  fixture is required — `PluginHandler`'s existing `@default_fixture`/`@default_export`
  trivial-guest fixture (`req165_trivial.wat`) already provides the non-hanging
  comparison case AC1/AC4's tests need.

### 5.2 AC1 (requirements.yaml) / handoff AC1 — a guest blocked in a host call is bounded by the configured timeout, caller gets a structured error

1. Build an `ExecutionContext` with `node_config: %{"wasm_fixture" => "wasm_fixtures/req170_hang.wat", "export" => "hang", "timeout_ms" => 500}`.
   Call `Letflow.Engine.PluginInterface.invoke(Letflow.Engine.Wasm.PluginHandler,
   context)` (the real, unmodified, production entry point — no bypass). Assert the
   call returns within a small bound of 500ms (not the outer `@default_timeout_ms`
   30,000ms) and the result is `{:error, reason}` with `reason` a binary.
2. `CallTimeout.classify(result)` on that outcome returns `:wall_clock_timeout` — this
   is AC5's own assertion, proven on the same call as AC1's, since they are the same
   live event.
3. **Honesty clause required in this test's own comment, mirroring
   `req169-wasm-fuel-and-memory-cap.md` §5.4 item 4's precedent:** the test's comment
   must cite this design's §1/§2 finding that the underlying guest execution is NOT
   actually terminated by this mechanism — only the caller's wait is bounded — so a
   future reader does not conclude "terminated by the configured timeout" was verified
   in the WASM-11-literal sense.

### 5.3 AC2 (requirements.yaml) / handoff AC2 — verify the documented interrupt-and-keep-Store claim by running it; record the divergence since it does not hold

A test asserting, directly against `Wasmex.call_function/4` (not through
`PluginHandler`, since this AC is specifically about `wasmex`'s own claim in
isolation): a call that times out returns `{:error, _}`) is expected to FAIL against
real `wasmex` (per §1.1, it crashes with an `exit` instead) — so this test is written
**against the live-verified real behavior**, asserting the `exit` shape via a `catch`,
with a comment citing §1.1/§1.2/§7 explicitly, mirroring `req169`'s §5.4 item 4/§7.4
precedent of testing honestly rather than asserting the un-verified documented claim.
A second assertion in the same test: a subsequent call on the same `pid` (§1.2) also
never replies within a bounded wait — proving the "kept available for subsequent
calls" half of the claim is equally false, live, not merely narrated in prose.

### 5.4 AC3 (requirements.yaml) / handoff AC3 — outer supervised task terminates the invocation independently of `wasmex`'s own timeout

Mirrors §1.6 exactly, through the real `PluginInterface.invoke/2,3` entry point:
`ExecutionContext` with `node_config: %{"wasm_fixture" => "wasm_fixtures/req170_hang.wat", "export" => "hang", "timeout_ms" => 60_000}`
(a `timeout_ms` deliberately **longer** than a short outer bound), calling
`PluginInterface.invoke(Letflow.Engine.Wasm.PluginHandler, context, timeout_ms: 500)`
(REQ-057's own existing `invoke_opts()` mechanism, unmodified, driving the OUTER
bound). Assert: the call returns within ~500ms (not 60,000ms), the result is
`{:error, reason}`, and (proving independence concretely, per the handoff's own
"asserting the task process is dead" instruction) that no BEAM process remains blocked
past the outer bound — captured via the returned task's `pid` becoming
`Process.alive?/1 == false` shortly after `invoke/3` returns (accessible in this test
by calling the lower-level `Task.Supervisor.async_nolink/2` + `Task.yield/2` sequence
directly, exactly as `invoke/3`'s own body does, rather than through the opaque
`invoke/3` wrapper, so the task pid is observable to the test).

### 5.5 AC4 (requirements.yaml) / handoff AC4 — the timeout is configurable, and a test drives two values and asserts the shorter binds sooner

Dispatch `req170_hang.wat`'s `"hang"` export twice through
`PluginInterface.invoke/2,3` → `PluginHandler`, once with `node_config["timeout_ms"] =
300` and once with `node_config["timeout_ms"] = 2_000` (both comfortably inside the
outer `invoke_opts()` default of 30,000ms, so the outer bound never fires in this
test — isolating the inner knob as the thing under test, per §1.1's finding that this
inner value is what genuinely, deterministically governs elapsed time). Assert both
calls return `{:error, _}`, and assert the measured wall-clock elapsed time for the
300ms case is strictly less than for the 2,000ms case, each within a generous
tolerance band (this is real wall-clock timing, not `wasmex`'s own deterministic fuel
accounting — REQ-169 §5.5's "exact-value assertion is acceptable" reasoning does NOT
transfer here; assert the inequality and a loose tolerance window, not exact
millisecond values).

### 5.6 AC5 (requirements.yaml) / handoff AC5 — the timeout error is distinguishable by pattern match from REQ-169's fuel-exhaustion and memory-cap errors

A single test asserting side by side, per §4.4's stated layering: (a)
`CallTimeout.classify/1` on a captured wall-clock-timeout `PluginInterface.outcome()`
(§5.2/§5.4's own captured results) is `:wall_clock_timeout`; (b)
`Letflow.Engine.Wasm.ResourceLimits.classify_call_result/1` on a captured
fuel-exhaustion raw result (REQ-169's own `req169_hang.wat` + `arm_fuel/2` sequence,
reused directly, not re-derived) is `:fuel_exhausted`, and that value can never equal
(`===`) any `CallTimeout.classification()` value by construction (disjoint type
domains, §4.4); (c) the two underlying raw strings (`inspect(reason)`'s
`"{:timeout, {GenServer, :call,"` substring vs. the fuel string's `"all fuel consumed
by WebAssembly"` substring) do not contain each other, asserted by direct `String.contains?/2`
checks in both directions.

### 5.7 AC6 (requirements.yaml) / handoff AC6 — OQ-5 discipline: moduledoc states OQ-5 is not settled here, and any scheduler-stall evidence found is filed, not absorbed

A `moduledoc =~ ...`-style test (mirroring `req165`/`req168`/`req169`'s own precedent)
confirming `Letflow.Engine.Wasm.CallTimeout`'s moduledoc contains: (a) the literal
phrase stating OQ-5 is not settled by this requirement, and (b) a reference to the
node-wide worker-pool-exhaustion finding (§1.5/§8) as filed evidence. This test asserts
the *documentation content requirement* — it is not, and cannot be, a live
reproduction of §1.5's 32-concurrent-hang saturation scenario inside the normal test
suite (that scenario takes over a minute and durably occupies `wasmex`'s shared,
process-wide native thread pool for the remainder of the test run, which would corrupt
every other WASM test's own timing assumptions if run inside `mix test`) — §1.5's
finding is recorded as a **live-verified, one-time, this-design-session** result (§1.5
itself, and the reproducible `scratch/req170_timeout_probe.exs` script), not as an
automated regression test. This is stated here explicitly rather than silently omitted,
per the handoff's own "do not silently absorb" instruction.

### 5.8 AC7 (requirements.yaml) — `mix test` and `mix compile --warnings-as-errors` both pass

Not a design element — an ELIXIR-DEV/TEST-RUNNER obligation. This design's own types
are plain tagged tuples/enumerated atoms throughout (§4.2's `config()`,
`classification()`), giving both commands something meaningful to enforce, per this
project's established convention (`req169` §9 row 8's identical framing).

---

## 6 — Moduledoc content (required for `Letflow.Engine.Wasm.CallTimeout`, AC2/AC6)

Required moduledoc content, verbatim in substance (ELIXIR-DEV may adjust prose flow but
must preserve every factual clause):

> This module configures WASM-11's per-invocation wall-clock timeout and classifies
> `Letflow.Engine.PluginInterface.invoke/2,3` outcomes that resulted from one. See
> `lib/letflow/design/req170-wasm-wallclock-timeout.md` (gate-approved) for the full
> design, including §1's live verification findings this moduledoc summarizes.
>
> **DIVERGENCE FROM DECISION 0014's CONTAINMENT ARGUMENT AND WASM-11's LITERAL
> WORDING, LIVE-VERIFIED, NOT WORKED AROUND SILENTLY.** Decision 0014 cited `wasmex`'s
> documentation that "a timed-out call is interrupted and its Store stays usable" as
> "the interruption primitive WASM-11 needs." Live verification against the real
> installed `wasmex` v0.15.1 dependency (§1.1-§1.4 of the design doc) found this does
> **not** hold: a genuinely hanging guest is never interrupted by `wasmex`'s own
> timeout mechanism at any bound tested up to 30 seconds; the calling process instead
> crashes with an ordinary `GenServer.call` timeout `exit`; the `Store` never becomes
> usable again for subsequent calls; and no BEAM-side mechanism (link death,
> `Process.exit/2`, `Task.shutdown/2`, `GenServer.stop/1`) can reach or terminate the
> already-dispatched native execution once it has started, because `wasmex`'s per-`Store`
> executor task discards its own `JoinHandle` and offers no cancellation point. At
> scale, this leaks `wasmex`'s node-global, CPU-count-sized native worker-thread pool
> one hung invocation at a time, and a saturated pool was live-observed to stall an
> entirely unrelated, non-hanging guest call (§1.5) — filed as OQ-5-adjacent evidence,
> not silently absorbed (see decision 0014's Open Questions, OQ-5).
>
> **What DOES hold, live-verified (§1.6):** `Letflow.Engine.PluginInterface.invoke/2,3`'s
> existing, unmodified supervised-task boundary (REQ-057/165) reliably bounds how long
> the *caller* waits, independent of `wasmex`'s own timeout configuration — including
> when that inner value is `:infinity`. This module's `config().timeout_ms` sets the
> inner, `wasmex`-level bound that (per §1.1's finding) is what actually,
> deterministically governs elapsed wait time in practice, since `wasmex`'s own client-
> side `GenServer.call` timeout mechanism — not its documented interrupt — is what
> fires. `classify/1` distinguishes the resulting caller-facing error from
> `Letflow.Engine.Wasm.ResourceLimits`'s fuel-exhaustion/memory-cap shapes (REQ-169).
>
> **What this module does NOT claim or provide:** termination of the underlying guest
> execution itself. "Exceeding the timeout MUST INTERRUPT EXECUTION" (WASM-11's literal
> body text) is not satisfied by the mechanism available in this dependency version, for
> a guest that does not cooperate at a Wasmtime yield point. What is satisfied,
> live-verified, is WASM-11's own acceptance criterion text: "Host-blocking call
> respects timeout" — the host (caller) does.

---

## 7 — Explicit divergence statement for ORCH (AC2/AC7-style requirement, this handoff's own verification mandate)

**Finding, stated plainly:** decision 0014's containment argument point (ii) — "wasmex
documents that a timed-out call is interrupted and its Store stays usable ... the
interruption primitive WASM-11 needs" — does **not** hold against live-verified
behavior of the real installed `wasmex` v0.15.1 dependency. A genuinely hanging guest
is never interrupted at any bound tested (500ms through 30,000ms); the `Store` becomes
permanently unusable, not merely "not proven usable"; and the underlying native
execution is unreachable by any BEAM-side termination mechanism once dispatched,
because `wasmex`'s own executor task discards its `JoinHandle`. This was found by
direct live verification (`scratch/req170_timeout_probe.exs`, all six sections, §1
above), not assumed from decision 0014's documentation-sourced text — exactly the gap
this handoff instructed closing, and a more severe finding than REQ-166 through
REQ-169's own divergences (those found a crash hazard and a wording mismatch; this one
finds the cited containment primitive itself does not exist in practice).

**What is NOT affected:** `Letflow.Engine.PluginInterface.invoke/2,3`'s existing outer
supervised-task boundary (REQ-057/165) DOES reliably, independently protect the
*caller* — live-confirmed (§1.6) even against an `:infinity` inner timeout. A caller
using this mechanism is never left hanging; it receives a structured error within a
bound it configures. That guarantee, and only that guarantee, is what REQ-170
delivers and is what its own acceptance criteria (§5) test.

**What this design does about it, so ORCH does not need to re-derive the response:**
§2 restates WASM-11's intent honestly (the host respects the timeout; execution
interruption is not claimed); §4 builds the small, genuinely-new configuration and
classification surface AC1/AC4/AC5 need, reusing `PluginInterface`'s existing crash-
safety mechanism unmodified for AC3; §6 requires the divergence be stated in the
shipped module's own moduledoc permanently; §8 formalizes the OQ-5-adjacent filing per
this handoff's own AC6 instruction, rather than letting §1.5's finding be absorbed as
an implementation detail.

---

## 8 — OQ-5 filing: evidence this design's own live verification produced, per AC6's explicit "file, do not absorb" instruction

Decision 0014's OQ-5 asks whether a fuel-bounded guest can still block a BEAM scheduler
long enough to degrade the node, and states this needs a load spike plus S6 thresholds
— explicitly **not** this requirement's deliverable, and this design does not attempt
to settle it.

**What this design's own live verification found, stated plainly, filed here as a
candidate issue against OQ-5 rather than absorbed as a tuning note:**

1. **The specific mechanism OQ-5 named — a BEAM scheduler thread itself blocked — was
   NOT observed.** §1's per-scheduler `:erlang.statistics(:scheduler_wall_time)`
   sampling around a live hang window showed near-zero utilization on every BEAM
   scheduler (values of `0.0` to `0.0007`) — the hung guest's compute lives entirely in
   `wasmex`'s own separate native Tokio worker-thread pool, not a BEAM scheduler. This
   is a real, live-verified, positive finding: **this specific hazard, as OQ-5 literally
   names it, does not occur** for this fixture/scenario.
2. **A different, and arguably more severe, node-wide degradation mechanism WAS
   observed and IS new evidence bearing on OQ-5's underlying concern** ("can a
   fuel/wall-clock-bounded guest still degrade the node"): `wasmex`'s own native
   worker-thread pool (`TOKIO_RUNTIME`, sized to `available_parallelism()`, 8 on this
   session's host) is a **single, node-global, cross-tenant resource**, and a hung
   guest permanently consumes one of its threads with no possible reclamation (§1.4).
   Once enough concurrent hangs exceed that pool's size, **every** subsequent WASM
   invocation on the node — including from completely unrelated tenants and completely
   non-hanging guests — stalls indefinitely (§1.5, live-reproduced: an unrelated
   trivial call did not return within the test's own 58-second remaining budget after
   32 concurrent hangs saturated the pool). This is worse than a per-invocation
   timeout being ineffective; it is a **shared-resource exhaustion attack surface**,
   reachable by nothing more exotic than an ordinary tight loop — exactly WASM-11's own
   named threat model (an adversarial-by-default guest), requiring no bug, crash, or
   unusual guest behavior at all.
3. **This finding is filed here, explicitly, per AC6's instruction, for whoever next
   picks up OQ-5 or S6's operational thresholds to act on** — candidate scope for that
   future work: (a) an operator-configurable cap on concurrently in-flight WASM
   invocations, independent of and in addition to this requirement's per-invocation
   wall-clock bound; (b) investigating whether a newer `wasmex`/Wasmtime release fixes
   §1.3's apparently-non-functional epoch interrupt for this fixture shape (out of this
   session's scope to bisect); (c) revisiting decision 0014's overall WASM containment
   adequacy conclusion in light of this evidence (§2). This design does not implement
   any of (a)-(c) — per this handoff's OQ-5 discipline, that is explicitly out of
   scope here.

---

## 9 — Open questions this design leaves for ELIXIR-DEV, stated rather than guessed

- **OQ-1 — should `@default_wasmex_timeout_ms` be 5,000 (matching `wasmex`'s own
  documented default exactly) or a different, more conservative Letflow-chosen value?**
  This design recommends 5,000 for continuity with `PluginHandler`'s current,
  unconfigured behavior (§4.3) — no caller-visible behavior change for the default
  case, only for a caller that opts into a different value. Not blocking; ELIXIR-DEV
  may choose a tighter default with a one-line justification if S5's broader default
  budget conventions (e.g. `PluginInterface`'s own `@default_timeout_ms 30_000`) argue
  for a different number.
- **OQ-2 — the future composition of `ResourceLimits.classify_call_result/1` and
  `CallTimeout.classify/1` once a real host function wires both together** (§4.4). Not
  built here, per REQ-166-169's identical "wiring is a future requirement's job"
  boundary; named so the future wiring requirement's own CODE-DESIGNER does not have
  to rediscover the layering question.
- **OQ-3 — whether a future requirement should attempt to bound/reject NEW WASM
  invocations once `wasmex`'s native pool is observably saturated** (§8 item 3(a)).
  Explicitly out of THIS requirement's scope (OQ-5 discipline, §8) — named as a
  candidate for whoever picks up OQ-5.
- **OQ-4 — whether a newer `wasmex`/Wasmtime release changes §1.3's finding.** Not
  investigated (out of this session's scope); if a future dependency bump is proposed,
  §1's probes should be re-run against the new version before assuming this design's
  divergence statement still holds, per this project's own "verify, don't assume
  documentation" discipline.

None of these open questions block implementation of §4's actual code.

---

## 10 — Traceability: REQ-170's 7 real acceptance criteria (`docs/requirements.yaml`) → design elements → planned tests

| # | Acceptance criterion (verbatim) | Design element | Planned test(s) (§5) |
|---|---|---|---|
| 1 | "a test asserts a guest blocked in a host call is terminated by the configured timeout and the caller receives a structured error, which is WASM-11's own acceptance criterion" | §1.1-§1.4 (live finding: caller's wait is bounded; execution itself is not terminated, stated honestly per §2); §4.2 `CallTimeout.config()`; §4.3 `PluginHandler` extension | §5.2 |
| 2 | "a test verifies wasmex's documented behaviour by running it: after a timed-out call, a subsequent call on the same Store succeeds -- with the real result quoted; if it does not hold, the divergence from decision 0014's documentation-sourced evidence is recorded and reported" | §1.1/§1.2 (live finding: does NOT hold, at any bound up to 30s); §7 (explicit ORCH-facing statement); §6 (required moduledoc content) | §5.3 |
| 3 | "a test asserts the outer supervised task terminates the invocation independently of the runtime's own timeout, e.g. by asserting the task process is dead and the caller received {:error, reason} -- proving the guarantee does not rest solely on the NIF cooperating" | §1.6 (live finding: confirmed, even against `:infinity`); §3 (zero new code -- `PluginInterface.invoke/2,3` unmodified) | §5.4 |
| 4 | "the timeout is configurable (not a hardcoded literal) and a test drives two values and asserts the shorter binds sooner" | §4.2 `config().timeout_ms`; §4.3 `PluginHandler.handle_node/1`'s new `"timeout_ms"` `node_config` key | §5.5 |
| 5 | "the timeout error is distinguishable by pattern match from REQ-169's fuel-exhaustion and memory-cap errors" | §4.2 `CallTimeout.classification()`; §4.4 (two independent distinguishing properties: type-shape and disjoint substrings) | §5.6 |
| 6 | "the moduledoc states that OQ-5 (scheduler safety under real load) is NOT settled by this requirement and names what would settle it (a load spike plus S6 thresholds); any scheduler-stall evidence observed while building this requirement is filed as an issue against OQ-5 rather than absorbed" | §6 (required moduledoc content); §8 (full filing, including the positive "not a BEAM-scheduler stall" finding and the "is a node-global native-thread-pool exhaustion" finding) | §5.7 |
| 7 | "mix test and mix compile --warnings-as-errors both pass with real output quoted" | Not a design element -- an ELIXIR-DEV/TEST-RUNNER obligation; §4.2's plain tagged-tuple/atom types give both commands something meaningful to enforce | N/A |

### Handoff-specific meta-criteria (from this WF-02 run's own handoff, not verbatim in `docs/requirements.yaml`)

| Handoff item | Design element |
|---|---|
| Live-verify wasmex's interrupt-and-keep-Store claim via a real `MIX_ENV=test mix run` script | §0/§1 (`scratch/req170_timeout_probe.exs`, six sections, all live-run this session) |
| Confirm live whether a host-blocking call with a short timeout returns cleanly, hangs, crashes, or behaves otherwise | §1.1 (crashes -- an ordinary `GenServer.call` timeout `exit`, not a clean return) |
| Confirm live whether the SAME Store/pid can be used for a subsequent call afterward | §1.2 (cannot -- permanently wedged, live-reproduced at 4 different bounds up to 30s) |
| Confirm the outer supervised-task boundary independently terminates an invocation when wrapped around a call with a LONGER (or no) wasmex-level timeout | §1.6 (confirmed, including against `:infinity`) |
| Read `plugin_interface.ex`'s `invoke/2,3`/`handle_yield_result/4` directly; decide whether this requirement needs new code or is substantially already covered by REQ-165's `PluginInterface` plus a wasmex-level timeout configuration point | §3 (split answer: AC3 fully covered, zero new code; AC1/AC4 need the small `PluginHandler` extension in §4.3; AC5 needs the new, small `CallTimeout` classifier in §4.2) |
| Confirm the timeout error shape is distinguishable by pattern match from REQ-169's fuel-exhaustion/memory-cap error shapes | §4.2/§4.4; §5.6 |
| OQ-5 discipline: record any evidence bearing on it as a finding to be filed as a candidate issue, not silently absorbed; state plainly whether any such evidence was observed | §8 (yes -- evidence was observed; both what OQ-5 literally names (not observed) and a related, arguably more severe mechanism (observed) are stated) |
| "Zero literal Elixir code in the design doc" | §1/§2/§3/§4/§5/§6/§7/§8 use prose, tables, `@type`/`@spec`/`@doc` blocks (signatures only, no `def ... do ... end` bodies), and quoted terminal output/raw strings (not Elixir source) throughout |
| "Full traceability table mapping every one of REQ-170's real acceptance criteria ... to a planned test" | This table, plus `test/specs/REQ-170.md`'s test-case list |

---

## 11 — Confirmation: exactly which existing files this design touches, and which it does not

**New files:** `lib/letflow/engine/wasm/call_timeout.ex` (§4.2); one new fixture,
`priv/wasm_fixtures/req170_hang.wat` (§5.1).

**Modified (small, additive extension only):** `lib/letflow/engine/wasm/plugin_handler.ex`
— `handle_node/1` reads one additional `node_config` key; `run_guest/2` becomes
`run_guest/3`; `call_export/2` becomes `call_export/3` and passes an explicit 4th
argument to `Wasmex.call_function/4` (§4.3). No change to `read_fixture/1`,
`start_instance/1`, the module's `@behaviour`, or its documented residual-risk
disclosure (that disclosure is extended, not replaced, by this design's own §6/§7/§8
findings, which are strictly more severe and supersede nothing already stated there).

**Unmodified:** `lib/letflow/engine/plugin_interface.ex` (§3 — confirmed by direct
reading and live testing that its existing algorithm already delivers AC3 exactly);
`lib/letflow/engine/wasm/resource_limits.ex`, `capability_gate.ex`,
`module_registry.ex`, `memory_guard.ex` (REQ-166-169, untouched — §4.4 states the
future composition point without building it).
