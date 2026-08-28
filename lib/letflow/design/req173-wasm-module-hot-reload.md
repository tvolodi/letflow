# REQ-173 — WASM module hot reload (WASM-14)

Status: draft, for CODE-DESIGN-VALIDATOR review.
Owner: CODE-DESIGNER. Implements: WASM-14 ("When a new version of a module is
activated, in-flight invocations of the prior version MUST complete normally.
New invocations MUST use the new version."). Per decision
`0014-scripting-plugin-runtime-strategy.md`, WASM-14 is on the "satisfiable
substantially as worded" list — no restatement of the requirement's own text
is needed, only a design.

## 0 — Scope and relationship to REQ-166/167/165/171/172

`Letflow.Engine.Wasm.ModuleRegistry` (REQ-166) is **not modified** by this
design. It validates a module's export/instantiation shape and returns an
opaque, single-version `registered_module()` — it has no concept of "the same
module, a later version," activation, or in-flight tracking, and per its own
moduledoc ("this module is fully decoupled from invocation... wiring
registration, capability-gated instantiation, and export dispatch together
into one production call path is a future dispatch-integration requirement's
job") it was never meant to grow that concept itself.

`Letflow.Engine.Wasm.CapabilityGate` (REQ-167/171/172) is **not modified**
either. `build_import_table/2` and `start_instance/2` are used exactly as
they exist today.

`Letflow.Engine.Wasm.PluginHandler` (REQ-165/170/171/172) is **not modified**.
It is one possible future caller of the mechanism this design adds, once a
dispatch-integration requirement wires `PluginInterface.invoke/2,3` to a
registered/versioned module — that wiring remains out of this requirement's
scope, exactly as REQ-166/167's moduledocs already deferred it.

This design adds one new module, **`Letflow.Engine.Wasm.ModuleVersionRegistry`**
(a supervised singleton `GenServer`), that *composes* the three modules above
to add: versioned registration, an explicit activation operation, a minimal
but real `invoke/4` entry point sufficient to exercise and test the hot-reload
property end to end (checkout → instantiate → call → release), and
introspection for tests. Precedent for this "new module, not a graft" shape
is `CapabilityGate` itself (REQ-167 §0/§10: "neither `module_registry.ex` nor
`plugin_handler.ex` is modified by this requirement... a new, third module").

Reusing the existing `ModuleRegistry`/`CapabilityGate` split keeps this
design additive and keeps SECURITY-REVIEWER's re-review surface to one new
file rather than a diff against two already-approved ones.

## 1 — Live-verified facts this design depends on

Per this project's standing discipline (REQ-166→172, sharpest at REQ-172's
two FAILs), the following are read directly from the installed `wasmex`
source (`deps/wasmex/lib/wasmex.ex`, matching the `v0.15.1` pin already used
throughout this design line), not from hexdocs prose:

1. **A host-function callback executes synchronously inside the Wasmex
   instance's own `GenServer` process**, not in the calling process/task.
   `Wasmex.call_function/4` sends `{:call_function, ...}` via
   `GenServer.call/3` to the instance `pid` (`wasmex.ex:419-426`); the
   instance's own `handle_call/3` clause for `{:call_function, ...}`
   (`wasmex.ex:532-539`) calls `Wasmex.Instance.call_exported_function/6` and
   replies `{:noreply, state}` — the actual reply to the original caller is
   sent later, out of band, once execution (including every host callback the
   guest makes along the way) has finished. Each host import's callback is
   invoked from `handle_info({:invoke_callback, namespace_name, import_name,
   context, params, token}, state)` (`wasmex.ex:542-575`), which runs `apply(callback,
   [context | params])` **in the instance process itself** (`context.pid ==
   self()` is set explicitly at `wasmex.ex:552`, matching
   `Letflow.Engine.Wasm.HostApi`'s own `wasmex_callback_context()` moduledoc
   claim that every `do_*` function's `context.pid` is the instance's own
   pid).
   **Consequence load-bearing for this design's test:** if a host callback
   never returns (blocks in a `GenServer.call` to something else, or
   `receive`s forever), it blocks *only that one Wasmex instance's own
   process* — not the calling task, not any other instance, not the BEAM
   scheduler beyond that one process's mailbox. Since every invocation in
   this design gets its own freshly-`start_link`'d instance (§4, no pooling —
   REQ-174's job), one invocation's guest parking in a host call cannot block
   any other invocation, concurrent or not, of any version.
2. **`register/1`'s stage-2 instantiation proof already runs inside its own
   bounded `Task.Supervisor.async_nolink/2` task** (`module_registry.ex:224-251`)
   — reused as-is; this design adds no second instantiation-proving path.
3. **`CapabilityGate.build_import_table/2` is a pure function of
   `(manifest, execution_context)`** (`capability_gate.ex:334-353`) — no
   store, no module, no side effect, no read of any external "current"
   state. This is what makes "capture the manifest once, build the table
   once, forever" a sound mechanism rather than an assumption: there is no
   hidden global the table-builder could read from later.
4. **`do_call_service/8` resolves its downstream caller via
   `Application.get_env(:letflow, :lua_platform_service_caller,
   Platform.NoServiceCaller)` fresh on every call** (`host_api.ex:455-456`,
   REQ-172). This existing test-double seam — already used by REQ-172's own
   parity suite — is reused verbatim by §8's test design below to build a
   controllable, releasable block without adding any new host import, any
   new production capability, or any change to `capability_gate.ex`'s
   `@known_imports`.

## 2 — Data model

```
module_name()       :: String.t()   # admin-assigned logical identity, stable
                                     # across versions; not derived from bytes
version_id()         :: pos_integer()  # assigned by this registry, 1-based,
                                        # monotonically increasing per module_name

version_status() :: :active | :superseded | :released
                   | {:unknown_version, module_name()}
                   | {:unknown_module, module_name()}

version_entry() :: %{
  version_id: version_id(),
  registered_module: ModuleRegistry.registered_module() | nil,  # nil once :released
  manifest: CapabilityGate.manifest() | nil,                    # nil once :released
  ref_count: non_neg_integer(),
  monitors: %{reference() => pid()}   # in-flight checkouts holding this version
}

module_state() :: %{
  current_version_id: version_id() | nil,
  versions: %{version_id() => version_entry()},
  next_version_seq: pos_integer()     # starts at 1
}

registry_state() :: %{optional(module_name()) => module_state()}
```

`version_entry().registered_module`/`.manifest` are set to `nil` at the exact
moment §6's release predicate fires — this is the "resource release" §8's
tests assert the timing of. `ref_count`, `version_id`, and the entry's
continued presence in `versions` are retained after release so
`version_status/2` can still answer `:released` (distinct from
`{:unknown_version, _}` — a version_id that was never issued for this
module_name at all).

A `version_snapshot()` — the immutable value `checkout` hands to an
invocation — is a strict subset of `version_entry()`, copied by value:

```
version_snapshot() :: %{
  module_name: module_name(),
  version_id: version_id(),
  registered_module: ModuleRegistry.registered_module(),
  manifest: CapabilityGate.manifest()
}
```

Because Erlang/Elixir terms handed across a `GenServer.call/3` reply are
copied (no shared mutable memory between the registry process and the
caller), **a `version_snapshot()` cannot be mutated out from under its holder
by any later registry operation, structurally** — not by convention, by the
BEAM's own process-isolation guarantee. This is the concrete answer to the
handoff's "does invocation start capture a version-specific struct/reference
that activation cannot mutate out from under it?": yes, by construction, and
this design does not additionally rely on immutable-data discipline within a
single process — the snapshot crosses a process boundary at checkout, so
even a same-VM-term aliasing bug on the registry's side cannot reach a
snapshot already handed out.

## 3 — Public API

```
start_link(opts :: keyword()) :: GenServer.on_start()
# supervised singleton, registered as Letflow.Engine.Wasm.ModuleVersionRegistry

@spec register_version(module_name(), bytes :: binary(), CapabilityGate.manifest()) ::
        {:ok, version_id()} | {:error, ModuleRegistry.registration_error()}
# Stage 1/2 ABI validation (ModuleRegistry.register/1) runs in the CALLING
# process (see §5) -- never inside this registry's own GenServer loop. Only
# on {:ok, registered_module} does this function make one fast internal call
# to commit the new version_entry() into registry_state(). Does not affect
# current_version_id -- a brand-new module_name has no current version until
# activate/2 is called explicitly; a brand-new version of an existing
# module_name likewise stays inert until activated. No auto-activation of a
# module's first version -- one mechanism (activate/2), always.

@spec activate(module_name(), version_id()) ::
        :ok | {:error, {:unknown_module, module_name()}} | {:error, {:unknown_version, module_name(), version_id()}}
# Sets current_version_id := version_id. The PREVIOUS current version's entry
# (if any) is marked superseded (implicit: it is simply no longer
# current_version_id). If that previous version's ref_count is already 0 at
# this instant, §6's release predicate fires immediately, in the same call.
# A no-op activation (activating the version that is already current) is
# permitted and is idempotent -- it does not reset ref_count or touch
# monitors.

@spec current_version(module_name()) ::
        {:ok, version_id()} | {:error, {:unknown_module, module_name()}} | {:error, {:no_active_version, module_name()}}

@spec version_status(module_name(), version_id()) :: version_status()
# Test/introspection accessor, mirrors CapabilityGate.known_host_functions/0's
# own "exposed for introspection/testing" precedent (capability_gate.ex:296-309).

@spec invoke(module_name(), export :: String.t(), args :: [integer()],
             execution_context :: HostApi.execution_context(), timeout_ms :: pos_integer()) ::
        {:ok, version_id(), [integer()]}
        | {:error, {:unknown_module, module_name()}}
        | {:error, {:no_active_version, module_name()}}
        | {:error, {:instantiation_denied, CapabilityGate.instantiation_defect()}}
        | {:error, {:call_failed, term()}}
        | {:error, {:timeout, timeout_ms :: pos_integer()}}
# The minimal real invocation path this design needs to exercise and test
# the hot-reload property (§4). Deliberately NOT the full future
# dispatch-integration path (no PluginInterface.outcome() mapping, no
# HostApi.take_staged_writes/0 commit step -- both remain a future
# dispatch-integration requirement's job, exactly as ModuleRegistry/
# CapabilityGate's own moduledocs already scope it). It DOES exercise the
# real checkout/instantiate/call/release sequence end to end, which is the
# part WASM-14 is actually about.
```

`checkout/1` and `release/2` are internal (not part of the public API — see
§6): every external caller reaches the mechanism only through `invoke/4`,
which cannot leak a checkout without a matching release (§6's crash-safety
net covers the one way that could otherwise happen).

## 4 — The concurrency mechanism: capture-and-hold, immune to concurrent activation

`invoke/4`'s algorithm, run inside a `Task.Supervisor.async_nolink/2` task
under a new `Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor` (§7 —
per decision 0014 (2), no guest invocation is ever dispatched inline):

1. **Checkout** — `GenServer.call(ModuleVersionRegistry, {:checkout, module_name})`,
   issued from the task process. Inside the registry's `handle_call/3`:
   look up `module_state.current_version_id`; if none, return
   `{:error, {:no_active_version, module_name}}` and stop here. Otherwise:
   increment that version's `ref_count`, `Process.monitor/1` the calling
   task's pid, record `{monitor_ref => task_pid}` in the entry's `monitors`
   map, and reply `{:ok, version_snapshot()}` (§2) — a value copy of that
   version's `registered_module`/`manifest`, tagged with `monitor_ref` so
   the task can quote it back at release time.
   **This is the single instant an in-flight invocation's version is
   decided.** Nothing after this step ever consults `current_version_id`
   again for this invocation.
2. **Build the import table** — `CapabilityGate.build_import_table(snapshot.manifest,
   execution_context)`, a pure function (§1.3) of the *snapshot's* manifest,
   never of "whatever the manifest is now."
3. **Instantiate** — `Wasmex.start_link(%{bytes: snapshot.registered_module.bytes,
   imports: table})`, run inside the same task (already itself inside a
   supervised, `async_nolink` task per decision 0014). On failure, classify
   via the identical `{unresolved_import, _, _} | {:crashed, _} | {:timeout, _}`
   shape `ModuleRegistry`/`CapabilityGate` already use (deliberately
   duplicated again here, not extracted — matching both modules' own stated
   precedent at `capability_gate.ex:196-206`, "each module keeps its own
   private crash classifier").
4. **Call** — `Wasmex.call_function(pid, export, args, timeout_ms)`.
5. **Stop** — `GenServer.stop(pid)` unconditionally (mirrors
   `PluginHandler.run_guest/3`'s "on every path, including the error path").
6. **Release** — `GenServer.call(ModuleVersionRegistry, {:release, module_name,
   version_id, monitor_ref})`, on every path out of steps 2-5 (success,
   instantiation failure, call failure, or an exception caught and
   re-raised after cleanup — same "release always runs" discipline as step
   5's unconditional stop). Inside the registry: `Process.demonitor(monitor_ref,
   [:flush])`, decrement `ref_count`, remove the `monitor_ref` entry from
   `monitors`, then apply §6's release predicate.

**Why a concurrent `activate/2` cannot affect an invocation already past
step 1:** `activate/2` only ever writes `module_state.current_version_id`
and (via §6) a *different* version_entry's `registered_module`/`manifest`
fields (the one being superseded, and only after it is safe to). It never
touches the `version_entry` a live snapshot was already copied from except
to eventually null it out — and by the time that nulling is legal (§6:
`ref_count = 0`), every holder of a snapshot copied from it has already
called release, so nothing is still using the value being nulled. There is
no code path, buggy or not, by which `activate/2` can reach a
`version_snapshot()` already sitting in a task's own stack/heap: it is a
different process's memory, and the registry never holds a reference back
into it (checkout copies data one direction, out, and never keeps a pointer
to the copy).

**Why `activate/2` cannot be blocked by a hung invocation, and vice versa**
(INV-MVR-1): the `ModuleVersionRegistry` `GenServer` process **never calls
`Wasmex.start_link/1`, `Wasmex.call_function/4`, or any function that runs
guest code, or `ModuleRegistry.register/1`'s validating call** (§5 explains
why registration validation is also kept out of this process). Every
`handle_call/3` clause (`:checkout`, `:release`, `:activate`, `:commit_version`,
`:current_version`, `:version_status`) is a pure, O(map-size) state
transition with no I/O and no blocking wait. A guest parked indefinitely in
a host call (§1.1, §8) blocks only its own dedicated Wasmex instance process
and the one task that owns it — the registry itself, and therefore
`activate/2` for the same or any other module_name, is never even briefly
delayed by it.

## 5 — Why registration validation stays out of the registry's `GenServer` loop

`ModuleRegistry.register/1` (unmodified) is itself bounded by an internal
5-second `Task.yield/2` (`module_registry.ex:129,237-250`). If
`register_version/3` ran that call *inside* `ModuleVersionRegistry`'s own
`handle_call/3`, every other call to the SAME registry process —
`activate/2`, `checkout` for an unrelated invocation, `version_status/2` for
an unrelated test assertion — would queue behind it for up to 5 seconds per
registration. That would silently reintroduce exactly the "guest-adjacent
work blocking bookkeeping" hazard §4's INV-MVR-1 is designed to rule out, via
the *registration* path instead of the *invocation* path.

`register_version/3` therefore runs `ModuleRegistry.register(bytes)` in the
**calling process** (whatever process called `register_version/3` — an
admin/dispatch-integration caller, or a test), and only on `{:ok,
registered_module}` does it issue one fast `GenServer.call(ModuleVersionRegistry,
{:commit_version, module_name, registered_module, manifest})` — assign the
next `version_id` for that `module_name` (from `next_version_seq`), insert
the new `version_entry()` (`ref_count: 0`, `monitors: %{}`), and reply
`{:ok, version_id}`. `{:commit_version, ...}` never calls `Wasmex` or
`ModuleRegistry` itself — the validation already happened before this
message was even sent.

## 6 — Reference counting and the release predicate

**Release predicate**, checked at exactly two trigger points and nowhere
else: *a version_entry's `registered_module`/`manifest` are set to `nil`
(and its status becomes `:released`) the instant both of the following are
simultaneously true: (a) it is not `module_state.current_version_id`, and
(b) its `ref_count` is `0`.*

Trigger point 1 — **inside `release`** (§4 step 6): after decrementing
`ref_count`, if the predicate now holds, release fires. This is the ordinary
case: a version is superseded while N invocations are in flight, and the
Nth (last) `release` call is the one that flips it to `:released`. This is
exactly what §8's test asserts by sampling `version_status/2` before and
after the held invocation's release.

Trigger point 2 — **inside `activate`**: after moving `current_version_id`
to the newly-activated version, check the just-superseded version's
`ref_count`. If it is already `0` (no invocations were in flight at the
moment of activation), release fires immediately, in the same `activate`
call. This is the "nothing to wait for" case, and it is why the predicate is
stated once and applied at both trigger points rather than being two
different rules.

**Crash-safety net (why `ref_count` cannot leak forever).** Step 6 requires
release to run on every path out of `invoke/4`'s task, including failure —
but a task killed by `Task.shutdown(task, :brutal_kill)` (the outcome of
`Task.yield/2` timing out, per the process-boundary pattern decision 0014
mandates for every WASM invocation) is killed with **no** opportunity to run
its own cleanup code, so step 6's explicit `release` call would never fire
for a genuinely-hung guest — the checkout hazard §4 exists precisely to
survive one of. This is the same "leaked, not degraded" class of hazard
decision 0014's correction to reasoning (a)(ii)/(iii) and REQ-170 already
found and accepted for the underlying native execution; this design does
**not** re-litigate that (a leaked native computation stays leaked exactly
as REQ-170 found — orthogonal to this registry's own bookkeeping), but it
must not ALSO leak the registry-side `ref_count`, because that bookkeeping
leak is fully within this design's control and would make WASM-14's own
"released only after the last in-flight invocation completes" promise false
in exactly the timeout case it most needs to hold for.

The `Process.monitor/1` set up at checkout time (§4 step 1) is this net: if
the monitored task pid dies for **any** reason — normal return without
having called `release` (a caller bug), an uncaught exception, or a
`:brutal_kill` — the registry's `handle_info({:DOWN, monitor_ref, :process,
_pid, _reason}, state)` clause performs the identical decrement-and-check-
predicate logic §4 step 6 performs explicitly, keyed off the same
`monitor_ref` (looked up in the owning version_entry's `monitors` map, then
removed). An explicit `release` call first calls `Process.demonitor(ref,
[:flush])` specifically so a normal release does not also trigger a
redundant `:DOWN` decrement — release and the `:DOWN` handler are mutually
exclusive for a given `monitor_ref`, by construction (one or the other
fires, never both), so `ref_count` cannot be double-decremented either.

## 7 — New supervision additions (`lib/letflow/application.ex`)

Two new children, added after `CapabilityGateTaskSupervisor` following the
existing list-order convention:

```
{Letflow.Engine.Wasm.ModuleVersionRegistry, name: Letflow.Engine.Wasm.ModuleVersionRegistry}
{Task.Supervisor, name: Letflow.Engine.Wasm.ModuleVersionRegistryTaskSupervisor}
```

The registry process itself should be registered before its task supervisor
(mirroring the existing comment at `application.ex:40-43` about registering
a pool after its task supervisor — here the dependency direction is the
registry being a stable, long-lived name that tasks call into, not the other
way around, so ordering between these two specific children is not
load-bearing, unlike the `SandboxPool`/`SandboxPool.TaskSupervisor` pair —
this note exists so ELIXIR-DEV does not assume it is).

## 8 — Test design: the overlapping-activation scenario

### 8.1 — Why the existing `*_hang.wat` fixtures don't fit, and what does

`req165_hang.wat`/`req169_hang.wat`/`req170_hang.wat`/`req172_write_then_hang.wat`
all use an **unconditional infinite loop** (`(loop $again br $again)`) with no
host call inside it at all, or a host call followed by a loop with no
release path — by design, for testing that a genuinely uncontrollable hang is
bounded/abandoned (WASM-11). That is the wrong shape here: WASM-14's test
needs to **resume** the held invocation and observe it complete against the
*old* version, which an unconditional loop can never do (nothing inside a
`br`-only loop can be released from outside).

Per §1's live-verified finding 4, this design instead reuses
`Letflow.Engine.Wasm.HostApi.do_call_service/8`'s existing test-double seam
(`Application.get_env(:letflow, :lua_platform_service_caller, ...)`,
REQ-172) as the controllable block — **no new host import, no new
`capability_gate.ex` row, no test-only entry anywhere near the production
whitelist.** A test-support module (`test/support/req173_blocking_service_caller.ex`
or similar — test-only, not under `lib/`) implements the same
`Letflow.Engine.Lua.Platform.ServiceCaller`-shaped `call/2` contract
`do_call_service/8` already dispatches to, and:

* signals a well-known test-owned process (e.g. `Agent`/`GenServer`
  registered under a fixed name for the test's lifetime) that a call has
  arrived — so the test can synchronously wait until the guest is
  genuinely parked, never relying on `Process.sleep/1` to approximate it;
* then blocks (e.g. `GenServer.call(gate, :park, :infinity)`) until the test
  calls a `release/0`-shaped function on that same gate, which makes the
  parked `GenServer.call` return, unblocking `do_call_service/8`, which
  returns an ordinary `{:ok, %{}}` envelope back into the guest.

Because `do_call_service/8` runs inside the Wasmex instance's own process
(§1.1), this blocks exactly that one instance and nothing else — the
registry, any concurrent invocation of any other version, and the test
process itself all continue running normally while it is parked.

### 8.2 — The two fixtures

`priv/wasm_fixtures/req173_v1_gated.wat` — imports **only**
`env.platform_call_service` (6-`i32`-param/1-result signature, matching
`capability_gate.ex`'s existing row exactly, unchanged). Its `run` export
calls `platform_call_service` with a fixed `service_id` (e.g. `"gate"`) and
empty payload, discards the result, and unconditionally returns the i32
literal `111`. It does **not** import `write_variable`.

`priv/wasm_fixtures/req173_v2_gated.wat` — imports **only**
`env.write_variable` (4-`i32`-param/1-result signature, matching
`capability_gate.ex`'s existing row exactly, unchanged). Its `run` export
calls `write_variable` with a fixed name/value, discards the result, and
unconditionally returns the i32 literal `222`. It never calls
`platform_call_service` and does not block.

The two versions therefore differ in **three** independent, cross-checkable
ways: which host capability each needs to instantiate at all (WASM-06
enforcement makes this a hard instantiation-time fact, not merely a runtime
behavior difference), whether the invocation parks, and the returned literal
— any one of the three would already distinguish them; using all three means
a version-confusion bug is very unlikely to accidentally pass.

### 8.3 — Manifests

`v1_manifest = %{capabilities: ["service:call"]}` (no `"var:write"`).
`v2_manifest = %{capabilities: ["var:write"]}` (no `"service:call"`).
Deliberately disjoint, not merely different, so a version-confusion bug in
either direction (old invocation silently gaining v2's grant, or new
invocation silently keeping v1's) is guaranteed to surface as an
instantiation failure rather than a subtler behavioral difference.

### 8.4 — Scenario (single test, real overlap — not two sequential calls)

1. Register `req173_v1_gated.wat`'s bytes under a fresh `module_name` with
   `v1_manifest` → `{:ok, v1_id}`. Activate `v1_id`.
2. Configure the test-support blocking service caller (§8.1) and start its
   gate process.
3. Start invocation A: `Task.async(fn -> ModuleVersionRegistry.invoke(module_name,
   "run", [], HostApi.empty_execution_context(), 5_000) end)` — asynchronous,
   because this call will not return until the gate is released.
4. **Synchronously wait** (via the gate, not a sleep) until the gate reports
   a call has arrived — this is the point at which, per §1.1/§4, invocation
   A's checkout, import-table build, and instantiation have already
   completed successfully against `v1_manifest` (if they had not, `run`
   could never have reached the `platform_call_service` call at all).
5. Assert `ModuleVersionRegistry.version_status(module_name, v1_id) == :active`.
6. Register `req173_v2_gated.wat`'s bytes under the **same** `module_name`
   with `v2_manifest` → `{:ok, v2_id}`. Activate `v2_id`.
7. Assert `ModuleVersionRegistry.current_version(module_name) == {:ok, v2_id}`.
8. **Acceptance criterion 4 (release timing).** Assert
   `ModuleVersionRegistry.version_status(module_name, v1_id) == :superseded`
   — NOT `:released` — proving activation alone did not release it while
   invocation A is still parked.
9. **Acceptance criterion 2 (new invocation observes the new version).**
   While invocation A is still parked, run invocation B synchronously:
   `ModuleVersionRegistry.invoke(module_name, "run", [], HostApi.empty_execution_context(),
   5_000)`. Assert it returns `{:ok, v2_id, [222]}` — proving both that a
   new invocation resolves to the new version, and (per §8.2/§8.3's disjoint
   manifests) that it succeeded only because it was instantiated against
   `v2_manifest` (granting `"var:write"`), which it could only have gotten
   from a fresh checkout of `v2_id`, never from any data invocation A is
   holding.
10. Release the gate (test calls the gate's `release/0`).
11. `Task.await/1` invocation A. **Acceptance criterion 1 (held invocation
    completes against the old version).** Assert it returns
    `{:ok, v1_id, [111]}` — the exact literal only `req173_v1_gated.wat`
    returns, and only reachable because instantiation succeeded against
    `v1_manifest`'s grant of `"service:call"` (§8.2's disjoint-capability
    argument again, in the other direction).
12. **Acceptance criterion 4 (release actually happens, not just "not yet").**
    Assert `ModuleVersionRegistry.version_status(module_name, v1_id) == :released`
    — now true, immediately after invocation A's `release` call runs (step
    6 of §4's algorithm), proving the last-in-flight-invocation trigger
    fires and that it does not require any further external action.
13. **Acceptance criterion 3.** Steps 9 and 11 together already show the two
    versions are observably different in output (`222` vs. `111`) for the
    respective invocation each was correctly resolved to — stated as an
    explicit separate assertion (`assert result_a != result_b`) rather than
    left implicit in the two literals chosen.
14. **Acceptance criterion 5 (capability isolation, both directions).**
    Steps 9 and 11's *success* (not merely their return literals) are
    themselves the assertions for this criterion, given §8.3's disjoint
    manifests: invocation A succeeding at all proves it kept
    `"service:call"` (v1's grant) after v2's activation stripped it from
    "current"; invocation B succeeding at all proves it got `"var:write"`
    (v2's grant only) despite invocation A still being in flight on the
    stripped-of-that-grant prior version. Add one more explicit, narrower
    assertion for defence in depth: reuse `CapabilityGate.build_import_table/2`
    directly (already gate-approved, REQ-167/171/172) on each manifest and
    assert `Map.has_key?(table_v1["env"], "platform_call_service")` /
    `not Map.has_key?(table_v1["env"], "write_variable")`, and the converse
    for `table_v2` — pinning that the *manifests themselves* are as disjoint
    as §8.3 claims, independent of this design's own `invoke/4` code.

### 8.5 — A concurrency test that is not sequential in disguise

The mechanical property distinguishing this from "activates between two
sequential invocations" (explicitly called out in REQ-173's own requirement
text as a non-test) is step 4's **synchronous wait on the gate** before step
6's `register_version`/`activate` runs. Nothing about steps 6-9 depends on
timing or `Process.sleep/1` — the gate is what makes the overlap real and
deterministic rather than a race the test happens to usually win.

## 9 — Open questions

**OQ-173-1 — `module_name()`'s source of truth.** This design treats
`module_name()` as an opaque caller-supplied string with no further
validation (uniqueness, format) beyond what the registry's own map keying
naturally enforces. Whether a future dispatch-integration requirement
derives it from a `PluginNode`'s configured module reference, a DB-backed
plugin registration record, or something else is not decided here — this
design's `module_name()` is deliberately as unopinionated as
`ModuleRegistry.registered_module()`'s own `term()`-shaped precedents
(`LuaScriptAudit.Executor.script_ref/0`) were before their own concrete
callers arrived.

**OQ-173-2 — retention of `:released` history forever.** §2's model never
removes a `version_entry()` from `versions`, even after release (only its
heavy fields are nilled) — so `version_status/2` keeps answering correctly
for the life of the node, but a module registered/activated very many times
accumulates one small entry per version forever. Whether this needs a
retention/GC policy is an operational question for whichever future
requirement puts real admin-facing module churn in front of this registry;
not a correctness gap for WASM-14 itself (REQ-173's own acceptance criteria
involve at most two versions).

**OQ-173-3 — interaction with REQ-174 (instance pooling, out of scope
here).** This design never pools a `Wasmex` instance — `invoke/4` always
`start_link`s fresh and `stop`s unconditionally (§4 steps 3/5), so
"the prior version's resources" released in §6 are the compiled
`Wasmex.Module`/bytes/manifest bookkeeping only, never a live instance.
REQ-174, if it adds pooling, will need to key its pool by `version_id` (not
just `module_name`) and must consult `version_status/2 == :active` (or
equivalent) before ever handing a pooled instance to a new invocation — this
design's `current_version_id`/`version_status/2` are the exact hooks
REQ-174's own acceptance criterion ("a pooled instance of a module version
superseded by REQ-173's activation is never handed to a new invocation")
will need; nothing here should need to change for REQ-174 to use them.

## 10 — Acceptance criteria mapping

| REQ-173 acceptance criterion | Where addressed |
|---|---|
| Held invocation, activation during the hold, held invocation completes against the OLD version, overlap is real | §4 (mechanism), §8.4 steps 1-5, 10-11, §8.5 |
| Invocation started AFTER activation observes the NEW version | §8.4 step 9 |
| Two versions observably different in output | §8.2 (three independent differences), §8.4 step 13 |
| Prior version's resources released only after its last in-flight invocation, not at activation | §6 (predicate + two trigger points), §8.4 steps 8, 12 |
| New manifest declares a different capability set; old invocation keeps old set, new gets new set | §5's manifest-immutability-per-version, §6, §8.3, §8.4 steps 9, 11, 14 |
| `mix test` / `mix compile --warnings-as-errors` pass with real output quoted | ELIXIR-DEV's implementation step; not applicable to this design artefact itself |
