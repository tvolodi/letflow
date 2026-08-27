# Design: REQ-160 — Lua host API 2/2, write path (`platform.write_variable`,
`platform.call_service`, `platform.emit_event`) (LUA-11 write half, LUA-12)

**Requirement:** REQ-160
**Stage:** S5
**Owner (design):** CODE-DESIGNER
**Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-27
**Extends:** `lib/letflow/design/req159-lua-host-api-read.md` (REQ-159, the
`execution_context`/`install/3` closure-capture mechanism this design reuses and
extends), `lib/letflow/design/req157-lua-capability-model.md` (the capability matrix
and `Capabilities.check!/3` gate), `lib/letflow/design/req150-lua-number-marshalling.md`
(the marshalling rule, cited by section number, not re-derived).

---

## 0. Sources read for this design

- `handoffs/WF02-REQ160-20260827/step-01-code-designer.json`
  (`context.requirement_text`, `task.acceptance_criteria`)
- `docs/requirements.yaml` REQ-160 entry (full `description` and 8-item
  `acceptance_criteria`, quoted in §9)
- `lib/letflow/engine/lua/platform.ex` — REQ-159's now-merged state: the 8-row
  `@capability_matrix`, `install/1,2,3`'s fold, `run_stub/5` (not `/4` — see REQ-159's
  moduledoc "Deviation from the design's literal `run_stub/4`"), the `execution_context`
  shape, and the three `:not_yet_implemented` rows this requirement replaces
  (`write_variable`, `call_service`, `emit_event`)
- `lib/letflow/design/req155-lua-wallclock-kill.md` (full) — the wall-clock kill
  mechanism: `Task.Supervisor.async_nolink/2`, `Task.yield/2`, `Task.shutdown(task,
  :brutal_kill)` on timeout
- `lib/letflow/design/req156-lua-memory-limit-impl.md` (full) — the memory-limit kill
  mechanism: for `max_heap_words == nil`, unchanged REQ-155 path; for a configured
  limit, a direct `:erlang.spawn_opt/2` process with `max_heap_size: %{kill: true, ...}`,
  monitored, observed via a `:DOWN` message
- `lib/letflow/design/req159-lua-host-api-read.md` (full) — the `execution_context`
  closure-capture precedent, the tenant-prefix-never-from-script framing, the
  two-Lua-return-value error convention
- `lib/letflow/design/req150-lua-number-marshalling.md` §2, §3 — the normative
  marshalling rule and the owning module/function this design cites, not re-derives
- `lib/letflow/engine/variable_merge.ex` (full) — `VariableMerge.merge/3`'s exact
  signature, purity, and atomicity properties (§2 below)
- `lib/letflow/engine/service_task.ex` (full) — confirmed `ServiceTask`/`Config` is a
  BPMN-node HTTP-dispatch configuration parser, unrelated to a Lua-callable service
  registry; its `transport_fun`/`catalog_lookup_fun` injected-function pattern is noted
  as a precedent for injected behaviour, but no shared code or type is reused from it
- `lib/letflow/engine/lua/capabilities.ex` — confirmed `check!/3`'s raise shape,
  `service_capability/1`'s exact signature (`"service:call:" <> svc_id`)
- `lib/letflow/engine/lua_script_audit.ex` — the `Executor` injected-behaviour pattern
  (REQ-058) this design mirrors for `call_service`'s minimal service-caller behaviour
- `lib/letflow/event_store.ex` — grepped and read `append/2` (line 214) and
  `append_platform_event/2` (line 269); confirmed `Letflow.EventStore.append/2` is a
  real, already-shipped, tenant-scoped event-append mechanism this design's
  `emit_event` hooks into (§5)
- `docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md` (e) — the tenant
  prefix is supplied by the calling engine code, never derived inside a script; and
  the crash-isolation section (a) confirming a preemptively-scheduled BEAM process,
  killed from outside, is the whole mechanism REQ-155/156 rely on
- `docs/anti-patterns.md` — no entry applicable to this design's own scope (checked)

---

## 1. Scope boundary

**In scope:**
1. Real implementations replacing the 3 remaining `:not_yet_implemented` matrix rows:
   `write_variable`, `call_service`, `emit_event` (§3, §4, §5).
2. `write_variable`'s staging mechanism and its interaction with REQ-155/156's kill
   paths — the requirement's central question (§2).
3. A minimal injected `ServiceCaller` behaviour for `call_service` (§4.2) — no real
   dispatch mechanism is built here (§4.1 explains why none exists to reuse).
4. Extending `execution_context` with two new fields, `service_caller` is NOT one of
   them (resolved via `Application` env, §4.2, mirroring `TimeSource`) — the new fields
   are `actor_id` (for `emit_event`, §5.1) only. `write_variable`/`call_service` add no
   new `execution_context` field.
5. A new public `Platform` function, `take_staged_writes/0` (§2.4), that some future,
   out-of-scope caller must invoke — see §2.5's explicit deferral, mirroring REQ-159's
   OQ-1.

**Out of scope (unchanged, per requirement text):**
- `platform.fail` — REQ-161.
- `read_variable`, `get_instance_state`, `log`, `now` — already real (REQ-159/REQ-152),
  untouched.
- `lib/letflow/engine/lua/executor.ex`, `lib/letflow/engine/lua/sandbox.ex` — neither
  file is in this requirement's `owned_modules`. This design identifies, but does not
  implement, the wiring gap by which `Executor`'s return shape must eventually carry a
  script's staged writes back to a caller that performs the actual `VariableMerge.merge/3`
  call and its own durable persistence (§2.5, OQ-1) — the identical category of gap
  REQ-159 §11 OQ-1 already left open for `execution_context`'s production wiring.
- Any real `VariableMerge.merge/3` caller, any real `Letflow.EventStore.append/2`
  event-type registration, any real `ServiceCaller` implementation — all three are
  consumed by this design's functions but none is built or edited here.

---

## 2. The central architectural question — where a staged write lives, and why it survives a kill

### 2.1 Restating the hypothesis to verify

The task brief's hypothesis: because REQ-155/156's kill mechanisms terminate the
**script-executing process itself**, and the caller only ever learns the outcome
through that process's own normal return value (success) or a `:DOWN` monitor message
(any kill/crash), a staged-writes buffer that lives **entirely inside that process's own
memory** is automatically and unconditionally discarded by any kill of that process —
with no special discard mechanism required. On success, the buffer only needs to reach
the caller via the *same* normal-return channel the process already uses, then gets
merged in a single `VariableMerge.merge/3`-shaped call.

### 2.2 Verifying against the actual REQ-155/156 kill code paths

Read directly, not assumed, from the two named design documents (both already merged,
per this requirement's `depends_on: [REQ-159, REQ-156, REQ-155]`):

- **REQ-155 §4.2**: "The task's body is the entirety of what REQ-154's
  `execute_with_manifest/3` currently does synchronously... constructing the sandbox
  with the given instruction budget, evaluating the script." This confirms the Lua VM
  construction (`Sandbox.new/1`, which calls `Platform.install/1`) **and** `Lua.eval!/2`
  both run inside the one supervised task's process — the same process whose kill this
  design must survive.
- **REQ-155 §4.1/§4.3**: on a timeout, `Task.shutdown(task, :brutal_kill)` is the only
  way the caller acts on that process; the caller's only observation channel is
  `Task.yield/2`'s return value (a wrapped normal result, or `nil` on timeout).
- **REQ-156 §5**: when `max_heap_words` is `nil`, the `nil` path is REQ-155's, verbatim,
  unchanged. When a limit is configured, §5.1 states "the spawned process's body is the
  same script-evaluation logic REQ-154/155 already specify... with one addition: on
  completion, the process sends its result back to the calling process" — i.e. still
  the same one process running the whole script body, still observed by the caller only
  via a message it sends on its own normal completion, or a `:DOWN` message on kill.
  REQ-156 §5.1's outcome table has exactly one row for the BEAM's own `max_heap_size`
  kill: `{:DOWN, ref, :process, pid, :killed}` — this fires as an OS-scheduler-level
  event with **no cooperation from, and no return value produced by,** the killed
  process. Nothing the process attempted to hold, compute, or accumulate in its own
  memory before the kill is ever observed by the caller through this channel.

**Conclusion: the hypothesis holds, verified rather than assumed.** Both kill
mechanisms — REQ-155's `Task.shutdown(:brutal_kill)` and REQ-156's `max_heap_size`
scheduler kill — terminate the exact one process in which the entire script body
(sandbox construction through `Lua.eval!/2`'s return) executes, and in both cases the
caller's *only* channels into that process's outcome are (a) the process's own normal
return/message, reachable only if the process finishes running, or (b) a `:DOWN`
message that carries no payload from the process's own memory. There is no third
channel — no shared ETS table, no message sent *during* execution, no side-channel read
of the process's state — through which a value inside that process's memory could
escape independently of its normal termination. Therefore: **a value that exists only
in that process's own memory (heap, or process dictionary) for the whole duration of
the script's execution is discarded by construction on every kill arm**, with zero
additional code required to make that true. The design obligation is the *converse* one
the task brief names: making sure nothing escapes the process except through that one
normal-return channel.

This also covers the failure arms REQ-160's own text names beyond the two kills: a
sandbox violation or REQ-154's instruction-budget exhaustion both raise inside the same
process, are caught by the existing `rescue` clauses (REQ-153/154, unedited), and the
process still returns an `{:error, _}` tuple **normally** — the write-staging design
below (§2.4) never lets that `{:error, _}` return path carry the staged-writes buffer
out, so these "soft" failures discard staged writes exactly the same way a kill does:
by never reading the buffer out of the process at all.

### 2.3 Why a process-dictionary buffer, not a `Lua.t()`-encoded one

Two candidate locations for the staging buffer, both "inside the process's own memory"
per §2.2, were considered:

| Location | Assessment |
|---|---|
| **Process dictionary (`Process.put/2`/`Process.get/1`), keyed under this module — CHOSEN** | Ordinary BEAM per-process key/value storage, invisible to any other process, invisible to the Lua VM (Lua code cannot call `Process.*` — the sandbox denies the `os.*` table entirely, and `Process` is not a Lua-reachable name to begin with, so this is not a sandbox-adjacent surface at all). Trivially mutable across multiple separate `write_variable` calls within one script execution, which a value closed over at `install/3` time (immutable per REQ-159 §2.2(a)) cannot be, without introducing a second, mutable carrier. |
| Encoding the pending-writes map into the `Lua.t()`'s own state (e.g. a Lua-encoded table under a private key on `_G`, or threaded as an extra element of the tuple `run_stub/5`'s callers already return) | REJECTED. Requires a `Lua.encode!/2` round trip on every `write_variable` call purely to store a value the host itself produced and will read back with no Lua-side involvement at all — the `Lua.t()` state exists to hold values a *script* can see; using it as an Elixir-to-Elixir scratch channel is solving an already-solved problem (the process dictionary) with the wrong tool, and risks the value becoming reachable from `_G` by accident if a future maintainer connects the wrong key. |

The process dictionary is scoped to, and destroyed with, the exact one process this
design needs it destroyed with (§2.2) — no additional isolation mechanism is needed
beyond "this is Elixir process-local state," which every one of REQ-153/154/155/156's
per-invocation-isolation invariants already guarantees is a fresh process per script
execution (no process, and therefore no process dictionary, is ever reused across two
different script executions).

### 2.4 The staging data structure and accumulation across multiple writes

```
@type staged_writes :: %{optional(String.t()) => term()}
```

- Key: the variable name, exactly as the script's first `write_variable` argument
  (a `String.t()`; a non-`String.t()` name is rejected, §3.2, and never staged).
- Value: the write's second argument, after `Letflow.Engine.LuaNumberMarshalling.from_lua/1`
  (REQ-150 §2.1, the write-direction identity rule for numeric/`nil` cases) has been
  applied — the buffer always holds values already in the canonical Elixir shape
  `VariableMerge.merge/3`'s `incoming_variables` argument expects, never a raw
  Lua-VM-internal term.
- **Last write wins.** A second `write_variable("x", v2)` call after an earlier
  `write_variable("x", v1)` call, within the same script execution, replaces `v1` with
  `v2` in the buffer — `Map.put/3` semantics, no history kept, no error. This mirrors
  ordinary Lua local-variable reassignment semantics a script author would expect and
  matches `VariableMerge.merge/3`'s own single-value-per-key contract (it has no
  concept of "which of several values for this key was submitted", only one final
  value per key, §2.6).

```
@spec stage_write(name :: term(), value :: term()) :: :ok
```

The private helper `write_variable`'s `run_stub/5` clause calls. Reads the current
buffer from the process dictionary (defaulting to `%{}` if unset — the first write of a
given execution), applies `LuaNumberMarshalling.from_lua/1` to `value`, and writes the
updated map back to the same process-dictionary key via `Process.put/2`. A non-binary
`name` is a no-op (§3.2) — `stage_write/2` is never called for a malformed name.

```
@spec take_staged_writes() :: staged_writes()
```

**New public function on `Letflow.Engine.Lua.Platform`.** Reads the current process's
staged-writes buffer (`%{}` if none was ever staged — including every script execution
that never calls `write_variable` at all) and **clears** the process-dictionary entry
(`Process.delete/1`) before returning it, so a hypothetical second call in the same
process observes an empty buffer rather than a stale one. This is the one function a
future caller — the same "future requirement" REQ-159 §11 OQ-1 already anticipates for
wiring `execution_context` — must invoke, **from inside the same process that ran the
script**, strictly *after* `Lua.eval!/2` has returned normally (not after a rescued
error, not after a kill — see §2.5), to retrieve what the script staged. This function
performs no `Letflow.Repo` call, no `VariableMerge.merge/3` call, and no persistence of
any kind — it is a pure read-and-clear of process-local state, nothing more.

### 2.5 The normal-return channel and the deferred wiring gap (mirrors REQ-159 §11 OQ-1)

This design's obligation ends at making the staged-writes buffer (a) accumulate
correctly across multiple `write_variable` calls (§2.4) and (b) be retrievable, once,
by `take_staged_writes/0`, from inside the same process, only after a normal
(non-raising, non-killed) completion of `Lua.eval!/2`.

**What this design does NOT build, and explicitly flags as an open gap (OQ-1, §10):**
`Letflow.Engine.Lua.Executor.execute_with_manifest/2,3`'s current return shape is
`{:ok, %{manifest_hash: String.t()}}` on success (REQ-153/154/155/156, unedited by this
design) — it has **no field carrying staged variable writes today**, and `executor.ex`
is not in this requirement's `owned_modules`. For `take_staged_writes/0` to ever have an
effect, some future change (to `executor.ex`, outside this requirement) must:

1. call `Letflow.Engine.Lua.Platform.take_staged_writes/0` from inside the task's own
   process, immediately after `Lua.eval!/2` returns its success value and before the
   task's body returns to `Task.yield/2`/the monitor-message send (i.e. as part of
   constructing the `{:ok, _}` result the task sends out) — reachable this early
   because `take_staged_writes/0` executes in the same process, at a point still before
   any kill arm could apply (evaluation already finished normally);
2. extend the success return shape to carry the result, e.g.
   `{:ok, %{manifest_hash: String.t(), staged_variables: staged_writes()}}`;
3. at whatever call site later holds both the instance's `current_variables` and this
   returned `staged_variables` map, call `Letflow.Engine.VariableMerge.merge/3` exactly
   once (§2.6) and route its result into the same durable-persistence path every other
   variable-mutation caller in this codebase already uses (REQ-044/REQ-049's existing
   convention — not reinvented here).

Steps 1–3 are **not implemented by this requirement** — `executor.ex` is out of scope,
and no caller of `execute_with_manifest/2,3` that holds real instance state exists yet
(the same "not wired to production" gap REQ-159 §11 OQ-1 already documents for
`execution_context`). This design states the exact shape the future wiring must take
(rather than leaving it undiscoverable) without pre-empting whichever requirement
implements it, matching REQ-158's own precedent of building a capability-grant-set
function with "whether/when a caller actually invokes [it]… not built here."

**Consequence for the acceptance criteria this requirement's OWN tests can prove
(§9, row 1–2):** with `take_staged_writes/0` unwired to any real `Executor`/persistence
call site, TEST-DESIGNER's tests for AC1/AC2 must exercise `write_variable` and
`take_staged_writes/0` directly against `Platform.install/3`, asserting the buffer's
accumulation/discard behaviour at the `Platform` layer (which this requirement fully
owns and fully specifies), rather than through a real end-to-end `Executor` call whose
persistence step does not exist yet. This is sufficient to prove LUA-11's own
acceptance text ("failed script does not leave partial variable writes in instance
state") **once instance state is defined as "whatever `take_staged_writes/0` would
report back"** — the process-local buffer *is* the only state a failed script could
possibly have contributed, per §2.2's proof that nothing else escapes the process.

### 2.6 `VariableMerge.merge/3`'s atomicity — confirmed, not assumed

Read directly from `lib/letflow/engine/variable_merge.ex`:

```
@spec merge(current_variables :: map(), incoming_variables :: map(),
            variable_validations :: variable_validations() | nil) :: merge_result()
```

`merge/3` is a **pure, single-invocation function** (moduledoc: "no `alias
Letflow.Repo`... no clock read... determinism" section) — it performs no I/O, no
yielding, no message passing, and returns exactly one of two whole outcomes:
`{:ok, new_variables, events}` (every incoming key applied) or `{:rejected,
current_variables, [execution_error_event]}` (**nothing** applied, not even
otherwise-valid keys — the moduledoc's own words: "nothing from this call is merged
(not even otherwise-unproblematic inserts of other keys)"). Because it is one ordinary
function call with no internal suspension point, there is no instant during its
execution at which a caller — or anything else — could observe a partially-applied
`new_variables` map; the function either has not returned yet (nothing observable
changed) or has returned (the whole result is available at once). **This confirms a
single `merge/3` call already provides in-memory atomicity with no additional
mechanism needed at that layer** — exactly the property §2.5 step 3 relies on.

One caveat, stated precisely rather than glossed: `merge/3` returning
`{:ok, new_variables, events}` is atomicity of the **computation**, not yet of
**durable storage** — writing `new_variables` to the `instance_projections.variables`
jsonb column still requires whatever transactional persistence mechanism the eventual
`Executor`-adjacent caller uses (the same boundary every other variable-mutation path
in this codebase already crosses, e.g. `Letflow.Engine`'s existing
`complete_task/3`-family callers). This design does not need to build that
persistence step to satisfy REQ-160's own acceptance criteria (§9 row 2 tests the
`merge/3`-shaped, in-memory atomicity this section confirms; it does not test Postgres
transaction semantics, which are not this requirement's concern and are not newly
introduced by it).

---

## 3. `platform.write_variable(name, value)` (LUA-11 write half)

### 3.1 Capability requirement — unchanged

`required: "variable:write"` (constant, ignores arguments) — already present in
`@capability_matrix` (`platform.ex`, unedited row). Only the row's `stub` tag changes
from `:not_yet_implemented` to a new `:write_variable` tag.

### 3.2 Real implementation

```
@spec write_variable(args :: [term()], execution_context :: Platform.execution_context()) ::
        [term()]
```

Control flow, in prose:

1. The Lua call's first argument is expected to be a `String.t()` (`name`). If it is
   not a binary, the function is a no-op with respect to staging (`stage_write/2`,
   §2.4, is never called) and returns Lua `nil` — malformed input is not an error
   condition for this function, mirroring `read_variable`'s own treatment of a
   malformed argument (REQ-159 §4.1 step 1).
2. Otherwise, applies `LuaNumberMarshalling.from_lua/1` (REQ-150 §2.1) to the second
   argument (`value` — `nil` if the script omitted it) and calls `stage_write(name,
   converted_value)` (§2.4), updating the current process's staged-writes buffer.
3. Returns `[]` — `write_variable` has no Lua-visible return value (LUA-11's text
   names no return value for the write half, mirroring `platform.log`'s `[]` return,
   REQ-159 §6.1 step 4).

This function performs **no `Letflow.Repo` call**, ever — staging is entirely a
process-local, in-memory operation (§2). It never raises for any argument shape.

### 3.3 Missing-context behaviour

`write_variable` reads no field of `execution_context` at all (unlike
`read_variable`/`get_instance_state`/`log`) — staging is process-scoped, not
tenant-scoped, so there is no "no execution context" case to special-case here. The
empty-context sentinel (REQ-159 §2.3.1) behaves identically to a populated one for this
function.

---

## 4. `platform.call_service(service_id, payload)` (LUA-12)

### 4.1 No registered-service abstraction exists in this codebase — confirmed, not assumed

Grepped for `ServiceRegistry`, `register_service`, and any service-dispatch-by-id
concept outside `Letflow.Engine.ServiceTask` (read in full, §0): `ServiceTask.Config`
parses a SERVICE_TASK **BPMN node's** HTTP-dispatch configuration (`route_kind`,
`url_template`/`service_id`, `method`, retry/backoff) — a *graph-authoring-time*
concept entirely orthogonal to "a Lua script calling a named service synchronously at
execution time." `ServiceTask`'s own moduledoc names its `transport_fun`/
`catalog_lookup_fun` as injected and unimplemented ("no concrete HTTP client... no
concrete, DB-backed catalog exists in this codebase yet"), which if anything reinforces
that no service-lookup infrastructure exists anywhere in this codebase for either
caller to share. **No "registered service" abstraction callable from Lua by a
`service_id` exists.** This confirms the ORCH pre-dispatch search's own finding.

### 4.2 Minimal injected `ServiceCaller` behaviour — an honest scope decision

Mirrors `Letflow.Engine.LuaScriptAudit.Executor`'s injected-behaviour pattern (REQ-058):
an interface a real implementation plugs into later, not built here.

```
@callback call(service_id :: String.t(), payload :: term()) ::
            {:ok, response :: map()} | {:error, reason :: term()}
```

(nested as `Letflow.Engine.Lua.Platform.ServiceCaller`, alongside the existing
`TimeSource` nested behaviour module in the same file)

Resolution follows `now/0`'s own `TimeSource` precedent exactly (`platform.ex`'s
existing moduledoc, "Time-source injection"): resolved fresh from
`Application.get_env(:letflow, :lua_platform_service_caller, <default>)` on every
`call_service` invocation, never cached, so a test can swap in a double via
`Application.put_env/3` without touching supervision. The default implementation,
`Letflow.Engine.Lua.Platform.NoServiceCaller`, always returns
`{:error, :service_caller_not_configured}` — a structured, honest "nothing is wired
yet" outcome (this design's own analogue of REQ-157's `:not_yet_implemented` stub
raise, but returned rather than raised, per §4.3's raise/return discipline), never a
crash. **No concrete `ServiceCaller` implementation is built by this requirement** —
this is stated as an explicit scope decision, not a silently assumed piece of
infrastructure.

`execution_context` gains **no** new field for this: the resolved implementation
module is not tenant-boundary-relevant data (it is code, injected the same way
`TimeSource` already is), so it does not need the closure-capture treatment REQ-159 §2
reserves for tenant-boundary-relevant values.

### 4.3 The LUA-12 vs LUA-06 asymmetry as two genuinely different code paths

This is the distinction this design must make unambiguously different, not merely
described differently:

| | Missing capability (LUA-06) | Service call failure (LUA-12) |
|---|---|---|
| **Where it happens** | Inside `install/3`'s fold wrapper, at `Capabilities.check!/3` — step 2 of the wrapper's three-step sequence documented in `platform.ex`'s own moduledoc, **before `run_stub/5` is ever invoked for this call** | Inside `run_stub/5`'s `:call_service` clause, i.e. only reachable *after* `check!/3` has already returned normally for this specific call |
| **What triggers it** | `required_capability(:call_service_arg0, args)` (unchanged from REQ-157, `Capabilities.service_capability(svc_id)`) is absent from the script's grant set | The resolved `ServiceCaller.call/2` callback returns `{:error, reason}` for a call the script *was* authorised to make |
| **Outcome** | Raises `Lua.RuntimeException` (unchanged REQ-157 mechanism — this design edits nothing about how or where that raise happens) | Returns a two-value Lua result, `[nil, error_table]` (§4.5) — **never raises** |
| **Can the two be confused by a test?** | No — a capability-denial test never reaches `run_stub/5`'s body at all (the call raises one fold-step earlier); a service-failure test only exercises `run_stub/5`'s body, reachable only when the gate already passed | |

Because the raise (LUA-06) happens strictly *before* `run_stub/5`'s `:call_service`
clause is ever entered, and every code path inside that clause (§4.4) returns a value
rather than raising, there is no code path in this module through which a granted call
can raise and no code path through which a denied call can reach the structured-error
return. The two are structurally, not just behaviourally, distinct.

### 4.4 Real implementation

```
@spec call_service(args :: [term()], execution_context :: Platform.execution_context(),
                    lua :: Lua.t()) :: {[term()], Lua.t()}
```

Control flow, in prose (only reached once `Capabilities.check!/3` has already passed,
per §4.3):

1. The Lua call's first two arguments are expected as `service_id :: String.t()` and
   `payload` (any Lua value, typically a table). If `service_id` is not a binary,
   returns `[nil, error_table(reason: "invalid_arguments")]` (§4.5) — no
   `ServiceCaller` call attempted. This is a structured return, not a raise, keeping
   the "never raise inside this clause" property from §4.3 total.
2. Decodes `payload` via `Lua.decode!/2` if it is a table reference (mirrors
   `do_log/3`'s established handling of an un-decoded `{:tref, id}` argument, REQ-159
   moduledoc "A related, smaller correction to design §6.1 step 1" — the same
   correction applies here for the same reason), then applies
   `LuaNumberMarshalling.from_lua/1` (REQ-150 §2.1) to every numeric leaf — the write
   direction, since this payload is host-bound content the script produced.
3. Resolves the configured `ServiceCaller` implementation (§4.2) and calls its
   `call/2` callback with `service_id` and the decoded/converted payload.
4. On `{:ok, response}` (a `map()`): applies `LuaNumberMarshalling.to_lua/1` (REQ-150
   §2.2) to every numeric leaf of `response` — the read direction, since this value is
   about to be handed back into the script — encodes it via `Lua.encode!/2`, and
   returns `[encoded_response]` (a single Lua table, per LUA-12's "Response MUST be
   returned as Lua table").
5. On `{:error, reason}`: builds `error_table(reason)` (§4.5) and returns
   `[nil, error_table]` — **never raises**, satisfying LUA-12's "Service call failures
   MUST RETURN A STRUCTURED ERROR, NOT RAISE" literally.

No arm of this function, once entered, raises for any reason — the only raise on this
entire call path is the capability gate at the fold level (§4.3), structurally prior to
this function ever running.

### 4.5 Structured-error shape

```
@type call_service_error :: %{reason: String.t()}
```

`reason` is one of `"invalid_arguments"` (malformed `service_id`, §4.4 step 1),
`"service_caller_not_configured"` (the default `NoServiceCaller`'s literal error atom,
stringified — §4.2), or whatever string a real, future `ServiceCaller` implementation's
`{:error, reason}` term stringifies to (`to_string/1` applied to an atom, or the term
passed through `inspect/1` if it is not already a binary/atom — this design does not
constrain a future `ServiceCaller`'s error-reason shape beyond "must be convertible to
a Lua-encodable string," since no real implementation is specified here to observe a
richer contract from).

### 4.6 Tenant-prefix discipline

`call_service`'s implementation never calls `Letflow.Repo` at all (§4.4) — there is no
tenant-prefix question at this layer for this function. If a future real
`ServiceCaller` implementation needs the tenant's schema, that implementation must
resolve it from data the calling engine code supplies to it directly (mirroring
decision 0014 (e) and REQ-159 §2's discipline), never from a script-supplied argument;
this design's `ServiceCaller.call/2` callback signature deliberately takes only
`service_id`/`payload` (script-controlled content) and no execution-context value,
which forecloses a future implementation from being tempted to accept a
script-supplied tenant identifier in place of one.

---

## 5. `platform.emit_event(event_type, payload, idempotency_key)`

### 5.1 An existing event-emission mechanism is found and cited: `Letflow.EventStore.append/2`

Grepped for `EventStore` across `lib/` (§0): `Letflow.EventStore.append/2`
(`lib/letflow/event_store.ex:214`) is the real, already-shipped, tenant-scoped
mechanism every other event-producing path in this codebase already uses (REQ-025's own
design, `VariableMerge`'s own `VARIABLE_OVERWRITTEN`/`EXECUTION_ERROR` events,
`Letflow.EventStore.PlatformEvents`'s producers). Its signature:

```
@spec append(attrs :: append_attrs(), opts :: [prefix: String.t()]) ::
        {:ok, append_result()} | append_error()
```

with `attrs` requiring `:instance_id`, `:event_type`, `:payload` (a JSON-encoded
`String.t()`), `:actor_id`, `:idempotency_key`, and an optional `:metadata` map. This
design hooks `emit_event` directly into this existing function — no new event-store
mechanism is introduced.

**What this reuse requires, stated plainly:** `append/2` validates `event_type` against
`Letflow.EventStore.Registry` (an already-registered, schema-checked event type per
tenant) — a script-supplied `event_type` string that has no registered schema produces
`{:error, :unknown_event_type}` from `append/2` itself, which this design's `emit_event`
turns into a structured Lua-visible error (§5.4), never a raise. This requirement does
not register any event type, and does not extend `Registry` — a script can only ever
successfully emit an event whose type some other, out-of-scope mechanism already
registered for that tenant. This is stated as a real, load-bearing precondition, not
silently assumed to already be satisfied for every event a script might name.

### 5.2 `execution_context` gains one new field: `actor_id`

```
@type execution_context :: %{
        instance_id: String.t() | nil,
        prefix: String.t() | nil,
        trace_id: String.t() | nil,
        script_identity: String.t() | nil,
        actor_id: String.t() | nil,
        variables: map()
      }
```

`actor_id` — the UUID string of the actor `Letflow.EventStore.append/2` should record
as the emitted event's author (an already-existing required field on every `append/2`
call, `attrs[:actor_id]`). Host-authored, exactly like `trace_id`/`script_identity`
(REQ-159 §2.3) — **never** taken from a script argument, for the identical reason
`log`'s correlation fields are host-authored only (REQ-159 §6.3: "a script controlling
its own claimed identity... would defeat the entire point of an audit trail" — applies
equally to an event's recorded author). `nil` is permitted (defaults via
`empty_execution_context/0`, extended to include `actor_id: nil`), so `install/1`/
`install/2`'s existing callers keep compiling unchanged (REQ-159 §2.3.1's same
backward-compatibility discipline, extended to this one new field).

### 5.3 Real implementation

```
@spec emit_event(args :: [term()], execution_context :: Platform.execution_context(),
                  lua :: Lua.t()) :: {[term()], Lua.t()}
```

Control flow, in prose:

1. If any of `execution_context.prefix`, `.instance_id`, or `.actor_id` is `nil` (the
   empty-context sentinel, or a caller-populated context missing one of these three) —
   returns `[nil, error_table(reason: "no_execution_context")]` (§5.4), attempting no
   `EventStore` call. Mirrors `get_instance_state`'s step-1 pattern (REQ-159 §5.2 step
   1) exactly, extended to three required fields instead of one.
2. Reads the Lua call's three arguments positionally: `event_type` and
   `idempotency_key` (both expected `String.t()`), `payload` (any Lua value, typically
   a table). If either `event_type` or `idempotency_key` is not a binary, returns
   `[nil, error_table(reason: "invalid_arguments")]` — no `EventStore` call attempted.
3. Decodes `payload` via `Lua.decode!/2` if it is a table reference (same handling as
   `call_service`'s payload, §4.4 step 2, and `log`'s `context`, REQ-159 §6.1 step 1's
   corrected form), applies `LuaNumberMarshalling.from_lua/1` (REQ-150 §2.1, write
   direction) to every numeric leaf, and `Jason.encode!/1`s the resulting map to the
   `String.t()` `append/2`'s `:payload` key requires.
4. Calls `Letflow.EventStore.append(%{instance_id: execution_context.instance_id,
   event_type: event_type, payload: json_payload, actor_id: execution_context.actor_id,
   idempotency_key: idempotency_key}, prefix: execution_context.prefix)` — `prefix` is
   **always** `execution_context.prefix`, never anything derived from any of this
   call's three script-supplied arguments (§6).
5. On `{:ok, _append_result}`: returns `[true]` — a single Lua boolean `true`
   indicating the event was accepted; LUA-12/LUA-11's own text does not ask
   `emit_event` to hand back a structured success value, and none of this
   requirement's own acceptance criteria (§9 row 5) test one, so this design does not
   invent a richer success shape than "did it work."
6. On any `{:error, reason}` from `append/2` (including `:unknown_event_type`,
   `:tenant_not_provisioned`, or any of the other tagged errors `append/2`'s own
   `@type append_error` enumerates): returns `[nil, error_table(reason: <string tag>)]`
   — **never raises**. This mirrors `call_service`'s own raise/return discipline
   (§4.3): the only raise on `emit_event`'s entire call path is the capability gate
   (missing `event:emit`, LUA-06, at the fold level, structurally prior to this
   function ever running), identical in kind to `call_service`'s own capability/failure
   split.

### 5.4 Structured-error shape

```
@type emit_event_error :: %{reason: String.t()}
```

`reason` is one of `"no_execution_context"`, `"invalid_arguments"`, or a stringified
tag derived from `Letflow.EventStore.append/2`'s own `@type append_error` union (e.g.
`"unknown_event_type"`, `"tenant_not_provisioned"` — the atom itself, or the head atom
of a tagged tuple, stringified via `to_string/1`; a non-atom error term, e.g. an
`Ecto.Changeset.t()`, is not stringified further by this design and is left as an open
question, §10 OQ-3).

---

## 6. Tenant-prefix-never-from-script — consistent with REQ-159's precedent

Every one of this requirement's three functions is checked against decision 0014 (e)
individually:

- `write_variable` — makes **no** `Letflow.Repo` call at all (§3.2); there is no prefix
  argument anywhere in its call path.
- `call_service` — makes **no** `Letflow.Repo` call at all (§4.4); the injected
  `ServiceCaller.call/2` callback (§4.2) receives only `service_id`/`payload`, neither a
  tenant prefix nor `execution_context` itself, foreclosing a future implementation
  from being handed a script-influenced value in place of one (§4.6).
- `emit_event` — the **one** function in this requirement that calls `Letflow.Repo`
  (transitively, via `Letflow.EventStore.append/2`), and its `prefix:` option is always
  `execution_context.prefix` (§5.3 step 4) — never `event_type`, never `payload`, never
  `idempotency_key`, the three script-supplied arguments. This is the identical
  discipline REQ-159 §5.2 step 4 already established for `get_instance_state`'s one
  `Repo` call site: "only ever with `execution_context.prefix`... never anything derived
  from the argument."

The moduledoc's REQ-160 section must state this plainly, in those words, exactly as
REQ-159's own moduledoc section does for its three functions.

---

## 7. Matrix and fold changes, precisely

### 7.1 `stub_spec` type — three new tags, `:not_yet_implemented` retired entirely

```
@type stub_spec :: :now | :fail | :read_variable | :get_instance_state | :log
                  | :write_variable | :call_service | :emit_event
```

`:not_yet_implemented` is removed from the type — after this requirement, every one of
the 8 rows has a real `stub` tag; no row is ever `:not_yet_implemented` again in
production code (the `run_stub/5` clause implementing it, §7.3, is deleted, not merely
left unreachable).

### 7.2 `@capability_matrix` — 3 rows edited, `required` unchanged, `stub` tag only

| `name` | `required` (unchanged) | `stub` (before → after) |
|---|---|---|
| `write_variable` | `"variable:write"` | `:not_yet_implemented` → `:write_variable` |
| `call_service` | `:call_service_arg0` | `:not_yet_implemented` → `:call_service` |
| `emit_event` | `"event:emit"` | `:not_yet_implemented` → `:emit_event` |

The other 5 rows (`read_variable`, `get_instance_state`, `log`, `now`, `fail`) are
copied verbatim, unedited.

### 7.3 `run_stub/5` — three new clauses, one clause deleted

Building on REQ-159's shipped `run_stub/5` (not the design-literal `run_stub/4` — see
REQ-159 moduledoc's deviation note, §0):

```
@spec run_stub(stub_spec(), atom(), [term()], Platform.execution_context(), Lua.t()) ::
        [term()] | {[term()], Lua.t()}
```

Three new clauses dispatch `:write_variable`/`:call_service`/`:emit_event` to §3.2/§4.4/
§5.3 respectively. The existing `:not_yet_implemented` clause (raising "is not yet
implemented (REQ-159/160)") is **deleted** — after this requirement no row ever
resolves to that tag, so the clause has no caller and its presence would be dead code
misdescribing REQ-160 as still-pending. `INV-CAP-1`/`INV-CAP-2` are unaffected — no new
`Lua.set!/3` call site is introduced, still exactly 8 rows, still one fold.

### 7.4 `empty_execution_context/0` gains `actor_id: nil`

```
@spec empty_execution_context() :: execution_context()
```

Extended to `%{instance_id: nil, prefix: nil, trace_id: nil, script_identity: nil,
actor_id: nil, variables: %{}}` (§5.2). `install/1`/`install/2`'s existing behaviour is
unaffected in substance: `emit_event` reached through either arity observes
`actor_id: nil` and returns the "no_execution_context" structured error (§5.3 step 1),
the same category of "not wired to production yet" outcome REQ-159 §2.3.1 already
established for its own three functions.

---

## 8. Cross-module dependencies

| Module | Direction | Nature of dependency |
|---|---|---|
| `Letflow.Engine.Lua.Platform` (extended) | → `Letflow.Engine.LuaNumberMarshalling` (REQ-159, unedited) | `write_variable`/`call_service`/`emit_event` each call `from_lua/1` on script-bound-to-host values; `call_service` also calls `to_lua/1` on the host-bound-to-script response |
| `Letflow.Engine.Lua.Platform` (extended) | → `Letflow.EventStore` | `emit_event`'s one `append/2` call site (§5.3) — the only `Letflow.Repo`-touching function this requirement adds |
| `Letflow.Engine.Lua.Platform` (extended) | → `Letflow.Engine.Lua.Platform.ServiceCaller` (new, nested, injected) | `call_service`'s only dependency for actually reaching a service; no concrete implementation ships with this requirement (§4.2) |
| `Letflow.Engine.Lua.Platform` (extended) | → `Letflow.Engine.Lua.Capabilities` | Unchanged from REQ-157/159 — `check!/3` remains the single gate call per wrapper, structurally prior to any of this requirement's three function bodies (§4.3) |
| (future, not built here) | → `Letflow.Engine.Lua.Platform.take_staged_writes/0` | Whatever requirement extends `executor.ex`'s return shape (§2.5 OQ-1) becomes the first real caller |
| (future, not built here) | → `Letflow.Engine.VariableMerge.merge/3` | The same future caller, once it holds both `current_variables` and a `staged_variables` map from `take_staged_writes/0` |

---

## 9. Traceability — REQ-160's 8 acceptance criteria

| # | Acceptance criterion (`docs/requirements.yaml` REQ-160, verbatim/paraphrased) | Design element |
|---|---|---|
| 1 | A script that writes a variable and then FAILS leaves instance variable state unchanged, asserted separately for: a raised script error, REQ-154's instruction budget, REQ-155's wall-clock kill, REQ-156's memory limit | §2.2 (the verified kill-path proof), §2.3 (process-dictionary buffer location), §2.4 (`take_staged_writes/0` never called on any non-normal-return path), §2.5 (why this is provable at the `Platform` layer even before `executor.ex`'s wiring lands) |
| 2 | A script that writes several variables and succeeds applies ALL of them; no intermediate partially-applied state is observable | §2.4 (`staged_writes()` accumulates every write in one map before any merge), §2.6 (`VariableMerge.merge/3`'s single-invocation atomicity, confirmed against the real module) |
| 3 | `platform.call_service` round-trips through the host to a registered service, response returned as a Lua table readable from inside the script | §4.2 (injected `ServiceCaller` behaviour), §4.4 steps 3–4 (the `{:ok, response}` path, `Lua.encode!/2`'d and returned as `[encoded_response]`) |
| 4 | A service call FAILURE returns a structured error (not raise); a MISSING `service:call:<id>` capability DOES raise; the two asserted distinctly | §4.3 (the full genuinely-different-code-paths table), §4.4 step 5 (structured return), §4.5 (error shape) |
| 5 | `platform.emit_event` without `event:emit` raises; with the grant, emits an event observable by the host | §7.2 (`required: "event:emit"`, unchanged, still gates via the same fold-level `check!/3`), §5.1 (the real, cited `Letflow.EventStore.append/2` hook — "observable by the host" is exactly what a real `events` row is), §5.3 |
| 6 | Number conversion uses REQ-150's named module/function; moduledoc cites REQ-150's section by number; no second rule introduced | §3.2 step 2, §4.4 steps 2/4, §5.3 step 3 — every numeric-touching step cites `LuaNumberMarshalling.from_lua/1`/`to_lua/1` and REQ-150 §2.1/§2.2 by number; no alternate conversion logic appears anywhere in this design |
| 7 | No host function in this requirement calls `Letflow.Repo` with a prefix derived from script-supplied input; moduledoc states the tenant prefix is supplied by the calling engine code, per decision 0014 (e) | §6 (per-function accounting: `write_variable`/`call_service` make no `Repo` call at all; `emit_event`'s one call always uses `execution_context.prefix`) |
| 8 | `mix test` and `mix compile --warnings-as-errors` both pass with real output quoted | Not a design-time artifact — ELIXIR-DEV/TEST-RUNNER responsibility at Steps 2/4, same convention as REQ-159 §8's own final row |

---

## 10. Open questions

**OQ-1 (the central deferred wiring gap, §2.5 — not resolved by this design, explicitly
deferred, mirrors REQ-159 §11 OQ-1).** No file in this requirement's `owned_modules`
extends `Letflow.Engine.Lua.Executor.execute_with_manifest/2,3`'s return shape to carry
`take_staged_writes/0`'s result, and no file wires a real `VariableMerge.merge/3` call
plus durable persistence at whatever call site eventually holds both a script's staged
writes and the instance's current variables. `executor.ex` is not in this requirement's
`owned_modules`. §2.5 states the exact three-step shape that future wiring must take.
This is a genuine, real gap this design flags rather than silently assumes closed —
`write_variable`'s staging mechanism is fully specified and independently testable at
the `Platform` layer (§9 row 1's testing note), but produces no observable effect on
any real instance's persisted state until that future requirement lands.

**OQ-2.** No concrete `ServiceCaller` implementation exists or is built by this
requirement (§4.2) — `platform.call_service` is real and fully specified, but every
production call returns `{:error, :service_caller_not_configured}` until some future
requirement configures `Application.put_env(:letflow, :lua_platform_service_caller,
<real module>)`. This mirrors `NoServiceCaller`'s own honest-stub role deliberately;
whether that future requirement is itself S5 or a later stage is not decided here.

**OQ-3.** `emit_event`'s structured-error `reason` field (§5.4) is specified as a
stringified atom/tag for every `Letflow.EventStore.append/2` error this design
anticipates by name. `append/2`'s error union also includes non-atom shapes (e.g.
`{:error, Ecto.Changeset.t()}`, `{:error, {:invalid_metadata, metadata_violation()}}`)
this design does not specify a stringification rule for beyond "not further
stringified by this design." Left open for ELIXIR-DEV/TEST-DESIGNER to pick a concrete,
lossless-enough rendering (e.g. `inspect/1`) if a test needs to exercise one of those
arms specifically; none of REQ-160's own 8 acceptance criteria (§9) require it.

**OQ-4.** Whether a script may call `platform.emit_event` more than once per script
execution, and whether doing so with the same `idempotency_key` twice should surface
`append/2`'s existing `is_duplicate: true` outcome back to the script in some way, is
not addressed — this design's §5.3 step 5 treats any `{:ok, _}` result identically
(`[true]`), including the duplicate-idempotency-key case, since neither LUA-12's text
nor REQ-160's 8 acceptance criteria ask for the two to be distinguished from inside a
script. Left open for a future requirement if that distinction is ever needed.

**OQ-5.** §2.3's process-dictionary choice is explicitly not the only mechanism that
would satisfy §2.2's proof (an ETS table keyed by `self()`, cleaned up via a
`Process.monitor/1`-triggered sweep elsewhere, would equally "live only in the killed
process's reachable state" in the relevant sense before that sweep fires) — this design
picks the process dictionary specifically for its simplicity (no separate cleanup
process, no table to leak) and because REQ-153/154/155/156's own per-invocation
isolation invariant already guarantees no process, and therefore no process-dictionary
entry, outlives one script execution. Whether ELIXIR-DEV finds an idiomatic reason to
prefer a different mechanism at implementation time is left open as a stylistic choice,
not a substantive one — §9 row 1/2's acceptance criteria are satisfied by either
mechanism equally, as long as the chosen one is verified to be scoped to the one
process for the one execution, per §2.2.
