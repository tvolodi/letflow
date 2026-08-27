# REQ-155 Design: Out-of-Band Host-Enforced Wall-Clock Kill for Lua Script Execution (LUA-10, Layer 2)

**Requirement:** REQ-155 — Out-of-band host-enforced wall-clock kill (LUA-10 restated, layer 2 of 2)
**Stage:** S5 (Scripting & plugins)
**Related:** REQ-154 (mandatory layer 1, in-band instruction budget), REQ-153 (executor base),
REQ-057/`plugin_interface.ex` (the async_nolink/yield/shutdown shape this design reuses),
decision 0014 (LUA-08/LUA-10 pairing rationale)
**Also owns:** `test/specs/REQ-155.md` (sibling test-spec skeleton)

**Acceptance criterion mapping is in §9 below.**

---

## 1. LUA-10 Layer-2 Restatement — Why This Requirement Exists

This requirement **restates LUA-10 as layer 2 of the mandatory LUA-08/LUA-10 pair**.
Neither LUA-08 nor LUA-10 is met by REQ-154 (layer 1) alone.

LUA-10 literal: *"Each script execution MUST have a configurable wall clock timeout
enforced BY THE HOST (not relying on Lua to cooperate)."* Acceptance: *"Script that
blocks on a host function MUST still be terminable."*

**Why `:max_instructions` cannot satisfy LUA-10's parenthetical, by construction:**

REQ-154's `:max_instructions` budget is an in-band VM counter. When exhausted, the
`tv-labs/lua` runtime raises a Lua runtime error that a script's own `pcall` can
intercept — the script regains control and may keep running. That is, by definition,
"relying on Lua to cooperate": the script is trusted to either not catch the error, or
to re-raise it, or to stop on its own. LUA-10's parenthetical exists specifically to
forbid depending on that cooperation. No amount of tuning `:max_instructions` changes
this property — it is intrinsic to the mechanism being in-band and catchable.

**Why the two layers are not interchangeable and both are mandatory (decision 0014):**

- REQ-154 (LUA-08, layer 1) answers "how much Lua work may this script do before we
  say it's over budget" — a cooperative, in-band accounting mechanism, useful for
  giving the script a chance to fail gracefully within its own control flow (e.g. a
  script that checks its own budget and exits cleanly).
- REQ-155 (LUA-10, layer 2) answers "no matter what the script does — traps its own
  budget error, ignores it, loops again — how do we guarantee the host regains control
  within a bounded wall-clock time." This is the non-cooperative backstop.

Decision 0014 (a) records why this is cheap on the BEAM where it was expensive in
R-Co: R-Co needed a single combined `LUA_MASKCOUNT` hook (INV-4) because that hook was
"the only mechanism in the codebase that can interrupt a tight `while true do end`
loop" — the instruction-count check and the elapsed-time check had to share the one
interruption point available. The BEAM equivalent is not a hook at all: a
preemptively-scheduled process is interruptible by construction. A supervising process
can terminate a tight loop with no cooperation from the script and no in-VM
instrumentation, via a kill signal delivered from outside the running process. That
external, unconditional kill is what this design implements. Without it, a script that
traps and ignores its own `:max_instructions` error runs forever and neither LUA-08's
"MUST terminate" nor LUA-10's "MUST be terminable" is actually true — REQ-154's own
moduledoc says exactly this ("LUA-08 must not be reported done until REQ-155 has also
landed").

---

## 2. Module Location and Ownership

**Primary file:** `lib/letflow/engine/lua/executor.ex` (`Letflow.Engine.Lua.Executor`)
— extended in place, same module REQ-153/REQ-154 already own. No new public module.

**New supervisor to register:** `Letflow.Engine.Lua.TaskSupervisor` (see §4 for why this
is a dedicated supervisor rather than a reuse of `Letflow.Engine.PluginTaskSupervisor`).
ELIXIR-DEV must add `{Task.Supervisor, name: Letflow.Engine.Lua.TaskSupervisor}` to the
children list in `lib/letflow/application.ex`, ordered anywhere before nothing depends
on start order here (no other child claims it at boot, unlike the
`SandboxPool.TaskSupervisor` / `SandboxPool` ordering constraint already documented at
that file's `# ISS-0224` comment).

---

## 3. Public Function Signatures

### 3.1 `execute_with_manifest/2` (behaviour callback, unchanged arity)

Unchanged arity and unchanged call shape from REQ-154. Internally now delegates to the
3-arity overload with both the default instruction budget and the default wall-clock
timeout.

| Element | Type / shape |
|---|---|
| `@impl` | `Letflow.Engine.LuaScriptAudit.Executor` |
| Params | `script_source :: binary()`, `registered_hash :: String.t()` |
| Guard | `when is_binary(script_source)` (unchanged from REQ-154/ISS-0350) |
| Return | `{:ok, %{manifest_hash: String.t()}}` \| `{:error, {:budget_exceeded, pos_integer()}}` \| `{:error, {:wallclock_timeout, pos_integer()}}` \| `{:error, String.t()}` \| `{:error, :invalid_script_ref}` |

The return union gains exactly one new arm relative to REQ-154:
`{:error, {:wallclock_timeout, timeout_ms :: pos_integer()}}`.

### 3.2 `execute_with_manifest/3` (opts overload, unchanged arity from REQ-154, opts grow)

| Element | Type / shape |
|---|---|
| Params | `script_source :: binary()`, `registered_hash :: String.t()`, `opts :: keyword()` |
| Guard | `when is_binary(script_source)` |
| Return | same 5-arm union as §3.1 |

`opts` keys (REQ-154's `:max_instructions` plus one new required key):

| Key | Type | Required | Description |
|---|---|---|---|
| `:max_instructions` | `pos_integer()` | yes (REQ-154, unchanged) | In-band VM instruction budget. |
| `:timeout_ms` | `pos_integer()` | **yes, new in REQ-155** | Wall-clock timeout, milliseconds, enforced from outside the executing process. **No hardcoded literal is permitted in the implementation** — this is the configurability AC-1 tests. |

Both keys are required on the 3-arity overload for the same reason REQ-154 gave for
`:max_instructions`: AC-1 needs two different configured timeouts driven from the same
test run, and `Application.put_env` round-tripping is fragile/order-dependent. The
2-arity behaviour callback is the only call site that reads either value from
Application config.

### 3.3 `default_timeout_ms/0` (new private helper, mirrors `default_budget/0`)

| Element | Type / shape |
|---|---|
| `@spec` | `default_timeout_ms() :: pos_integer()` |
| Visibility | `defp` |
| Behavior | Reads `Application.fetch_env!(:letflow, :lua_wallclock_timeout_ms)`. Called by the 2-arity callback before delegating to `/3`, exactly parallel to `default_budget/0`. |

The key `:lua_wallclock_timeout_ms` is the single authoritative name for the wall-clock
timeout across the application, distinct from REQ-154's `:lua_max_instructions`. As
with the instruction budget, ELIXIR-DEV must not hardcode a literal timeout anywhere in
`execute_with_manifest/2`'s implementation — the value must come from this helper (which
itself reads Application config, not a module attribute constant).

ELIXIR-DEV must add `config :letflow, lua_wallclock_timeout_ms: <N>` to `config/config.exs`
(and, if a shorter value is useful for fast test runs, `config/test.exs`), following the
same convention REQ-154 §6/§11 established for `:lua_max_instructions`.

### 3.4 `default_budget/0` (unchanged from REQ-154)

No change. Retained as-is.

---

## 4. The Supervised-Task Mechanism

### 4.1 Shape reused verbatim from `plugin_interface.ex`

This design reuses `Letflow.Engine.PluginInterface.invoke/3`'s three-step shape exactly
(§2.4.1 of that module's moduledoc), substituting "run the Lua execution body" for "call
`handler.handle_node/1`":

1. Start the execution body as a supervised, unlinked task via
   `Task.Supervisor.async_nolink/2`, under a named `Task.Supervisor`.
2. `Task.yield/2`, bounded by the configured `timeout_ms` — this observes the task's
   actual termination (normal return, task-process exit, or timeout expiry), the same
   signal class `PluginInterface.invoke/3` observes.
3. On a timeout (a `nil` yield result), call `Task.shutdown(task, :brutal_kill)` — an
   unconditional, non-cooperative kill signal delivered to the task's process from
   outside it, then return the structured timeout error (§5).

This is the identical mechanism decision 0014(a) names as the BEAM's replacement for
R-Co's `LUA_MASKCOUNT` hook: a preemptively-scheduled process is interruptible by
construction, so the brutal-kill shutdown terminates a tight `while true do end` loop
with zero cooperation from the Lua script and no in-VM instrumentation of any kind.
Crucially, the kill fires purely on elapsed wall-clock time observed from outside the
task — it has no dependency on whether the script trapped, ignored, or never triggered
its own `:max_instructions` error inside that process (this is what makes AC-2, §9,
hold).

### 4.2 What the supervised task's body executes

The task's body is the entirety of what REQ-154's `execute_with_manifest/3` currently
does synchronously in the caller's process: constructing the sandbox with the given
instruction budget, evaluating the script, and the existing `Lua.RuntimeException` /
`Lua.CompilerException` / `FunctionClauseError` handling that yields
`{:ok, %{manifest_hash: _}}`, `{:error, {:budget_exceeded, limit}}`,
`{:error, message}`, or `{:error, :invalid_script_ref}`. REQ-154's rescue clauses are
unchanged in substance; they now execute inside the spawned task's process rather than
the caller's process. The task's body returns exactly one of those four outcomes as its
normal (non-exit, non-timeout) result.

### 4.3 Interpreting `Task.yield/2`'s result

The four cases `Task.yield/2` can produce, and the return each maps to, mirror
`PluginInterface`'s `handle_yield_result/4` private clauses (same principle, applied to
this module's five-arm return union instead of `outcome()`):

| `Task.yield/2` result | Meaning | This function's return |
|---|---|---|
| The task finished normally, wrapping one of REQ-154's four existing return shapes | Script completed, or failed in-band, within the timeout | That same shape, unchanged (e.g. `{:ok, %{manifest_hash: _}}`, `{:error, {:budget_exceeded, limit}}`) |
| The task finished normally, wrapping a value outside the expected union | Defensive/unreachable in intended use — an internal contract violation | `{:error, <descriptive string naming the module and the unexpected value>}` |
| The task's process exited abnormally (a signal neither `rescue` clause in the task body converted to a tagged error) | Task crashed for a reason not already handled in-band | `{:error, <descriptive string derived from the exit reason>}` |
| `Task.yield/2` returned nothing within `timeout_ms` | Wall-clock timeout — the case this requirement exists for | `Task.shutdown(task, :brutal_kill)` is invoked, then `{:error, {:wallclock_timeout, timeout_ms}}` is returned (§5) |

### 4.4 Named supervisor and justification for a dedicated one

**Supervisor used: `Letflow.Engine.Lua.TaskSupervisor` — a new, dedicated
`Task.Supervisor`, not a reuse of `Letflow.Engine.PluginTaskSupervisor`.**

Justification (required in the moduledoc verbatim in substance):

`lib/letflow/application.ex` already establishes the convention of one dedicated
`Task.Supervisor` per subsystem rather than one shared supervisor for all supervised
tasks in the application — `Letflow.SandboxPool.TaskSupervisor` (its own dedicated
supervisor, with a documented start-order dependency on `SandboxPool` itself) and
`Letflow.Engine.PluginTaskSupervisor` (dedicated to in-process plugin handler dispatch,
REQ-057) already coexist as two separate supervisors for two separate concerns. Lua
script execution is a third, independent concern: it executes tenant-supplied script
source directly (not an in-process Elixir plugin handler module), it is on the hot path
of workflow execution rather than of ad hoc plugin dispatch, and giving it its own
supervisor keeps its crash/telemetry namespace (child counts, restart/shutdown
observability) separate from plugin-handler task activity. Sharing
`PluginTaskSupervisor` would conflate two independently-reasoned-about subsystems under
one supervisor's observable state for no offsetting benefit — a `Task.Supervisor` does
not provide resource quotas that would make sharing it a capacity optimization, only a
naming convenience, and this repo's own precedent already rejects that convenience
(two supervisors exist for two concerns, not one for all).

---

## 5. Wall-Clock Timeout Error Shape

**Chosen form:** `{:error, {:wallclock_timeout, timeout_ms :: pos_integer()}}`

**Distinguishability from REQ-154's budget error, by pattern match:**

| Error | Pattern | Origin |
|---|---|---|
| Instruction budget exhaustion (REQ-154, layer 1) | `{:error, {:budget_exceeded, limit}}` | In-band `Lua.RuntimeException`, message `"instruction budget exceeded"`, caught inside the task |
| Wall-clock timeout (REQ-155, layer 2) | `{:error, {:wallclock_timeout, timeout_ms}}` | Out-of-band: `Task.yield/2` returned nothing within `timeout_ms`; the task is then killed |
| Other runtime Lua error | `{:error, message}` where `message :: String.t()` | Unchanged from REQ-153/154 |
| Non-binary script ref | `{:error, :invalid_script_ref}` | Unchanged from REQ-153/154 |

The two tagged-tuple error arms carry different leading atoms (`:budget_exceeded` vs.
`:wallclock_timeout`), so `{:error, {:budget_exceeded, _}}` and
`{:error, {:wallclock_timeout, _}}` cannot be confused by any pattern match, and neither
can be confused with the bare-string or bare-atom arms. Carrying `timeout_ms` (the
configured value in effect for that call) makes a future REQ-162 `SCRIPT_ERROR` event
self-describing without a separate lookup, matching REQ-154's rationale for carrying
`limit` on its own error.

**A budget error and a timeout error are mutually exclusive outcomes of a single call.**
A given `execute_with_manifest` invocation returns whichever condition the task
actually hits first: if the task's Lua evaluation raises the in-band budget error and
that exception is not caught by the script itself, the task returns
`{:error, {:budget_exceeded, limit}}` and `Task.yield/2` observes it before the timeout
elapses, so no `:wallclock_timeout` error is produced for that call. If instead the
script traps its own budget error (or the script simply never encounters
`:max_instructions` — e.g. a host-function-blocking wait, per LUA-10's own acceptance
text — "script that blocks on a host function must still be terminable") and keeps
running, the task never returns, `Task.yield/2` exhausts `timeout_ms`, and
`{:error, {:wallclock_timeout, timeout_ms}}` is produced instead. This is exactly the
scenario AC-2 (§9) requires a test for.

---

## 6. Timeout Fires Regardless of In-Band Trapping (the requirement's core guarantee)

The mechanism in §4 is intentionally blind to what happens *inside* the task's Lua
evaluation. `Task.yield/2`'s bound is wall-clock time measured by the calling process,
not an event the task must emit or cooperate with. Concretely:

- A script that lets its own `:max_instructions` exhaustion propagate uncaught: the
  task's existing `rescue` clause converts it to `{:error, {:budget_exceeded, limit}}`
  and the task returns promptly — `Task.yield/2` observes this well within `timeout_ms`
  (assuming `timeout_ms` is configured larger than the time such a budget takes to
  exhaust, which is the intended relationship between the two configured values).
- A script that wraps its own loop in a construct equivalent to Lua's `pcall`, catches
  the `:max_instructions` exhaustion, and re-enters another unbounded loop: nothing
  inside the task signals this to the caller. The task keeps running past the point
  where REQ-154's layer alone would have stopped it. `Task.yield/2` has no visibility
  into Lua-level control flow at all — it only observes whether the task's OS-level
  BEAM process has finished. When `timeout_ms` elapses with no result, the timeout
  branch (§4.3, row 4) fires unconditionally, `Task.shutdown(task, :brutal_kill)`
  terminates the still-running task process, and `{:error, {:wallclock_timeout,
  timeout_ms}}` is returned. This holds **regardless of** how many times the script
  trapped and re-triggered its in-band budget error inside that window — the outer
  kill has no counter of its own to reset or dodge.

This "blindness to in-band state" is precisely why layer 2 satisfies LUA-10's
parenthetical where layer 1 cannot: the host never asks the script whether it is done;
it measures elapsed time from outside and acts unilaterally.

---

## 7. Carried-Forward Limitation Disclosure

The moduledoc must restate, verbatim in substance, the same limitation
`lib/letflow/engine/plugin_interface.ex`'s moduledoc already discloses for its own
supervised-task mechanism:

**Covers:** a script that hangs (an unbounded loop, or a blocking host-function call —
LUA-10's own acceptance example), a script whose evaluation raises, and a task process
that exits for any other reason. All fold into one of this module's `{:error, _}` arms
within `timeout_ms`.

**Does NOT cover:** a hard kill of the BEAM node itself, or `System.halt/0` — no task,
monitor, or supervisor observes either from inside the same node, because both
terminate the node the supervising process itself is running on. This is an accepted,
stated limitation, not a gap this module papers over. The moduledoc must not claim more
than this.

---

## 8. Required Moduledoc Content Outline (for `executor.ex`)

The updated `@moduledoc` for `Letflow.Engine.Lua.Executor` must add, alongside
REQ-153's and REQ-154's existing sections:

1. **LUA-10 layer-2 restatement section:**
   - This requirement RESTATES LUA-10 as layer 2 of the mandatory LUA-08/LUA-10 pair.
   - States LUA-10's "enforced by the host (not relying on Lua to cooperate)" clause
     plainly, and states that this is exactly what `:max_instructions` (an in-band,
     catchable budget) cannot satisfy by construction — not a limitation to be tuned
     away, an intrinsic property of an in-band mechanism.
   - States that neither LUA-08 nor LUA-10 is met until both this requirement and
     REQ-154 have landed together.
2. **Mechanism restated from decision 0014(a):**
   - A preemptively-scheduled BEAM process is interruptible by construction; a
     supervised task killed from outside via `Task.shutdown(task, :brutal_kill)`
     terminates a tight loop with no cooperation from the script and no in-VM
     instrumentation — the BEAM's replacement for R-Co's single `LUA_MASKCOUNT` hook
     (INV-4), which existed only because that hook was "the only mechanism in the
     codebase that can interrupt a tight `while true do end` loop."
3. **Named supervisor and its justification** — `Letflow.Engine.Lua.TaskSupervisor`,
   per §4.4 above, stated rather than left implicit.
4. **Carried-forward limitation disclosure** — §7 above, verbatim in substance.

---

## 9. Acceptance Criterion Mapping

REQ-155's 8 acceptance criteria, from `docs/requirements.yaml`, mapped to concrete
design elements:

| # | Acceptance criterion (paraphrased) | Concrete design element |
|---|---|---|
| 1 | Timeout is configurable (not hardcoded); a test drives two different configured timeouts and asserts the shorter terminates sooner, with real `mix test` output quoted | §3.2's `:timeout_ms` opt (required, no default in `/3`) and §3.3's `default_timeout_ms/0` reading `Application.fetch_env!(:letflow, :lua_wallclock_timeout_ms)` for `/2`; no module attribute or literal constant used in the implementation. Test spec item T1 (`test/specs/REQ-155.md`) |
| 2 | A test runs a script that `pcall`s its own instruction-budget exhaustion and continues looping, and asserts the outer host timeout STILL terminates it — must fail if layer 2 is removed | §6's "blindness to in-band state" guarantee: `Task.yield/2`'s bound has no dependency on Lua-level control flow. Test spec item T2 |
| 3 | A test asserts the script's execution process is dead after a timeout (`Process.alive?/1` on the pid, or the supervisor reporting no child) | §4.1's `Task.shutdown(task, :brutal_kill)` — an unconditional kill of the task's process. §4.4 names `Letflow.Engine.Lua.TaskSupervisor`; recommended assertion mechanism is `Task.Supervisor.children/1` on that supervisor returning no matching child post-shutdown (§10 OQ-2 discusses the alternative pid-exposure mechanism and why it is not required). Test spec item T3 |
| 4 | Timeout termination surfaces as a structured error distinguishable by pattern match from REQ-154's `{:error, {:budget_exceeded, limit}}`, asserted by a test matching each arm specifically | §5's `{:error, {:wallclock_timeout, timeout_ms}}` vs. `{:error, {:budget_exceeded, limit}}` — distinct leading atoms, unconfoundable by pattern match. Test spec items T4/T5 |
| 5 | Execution runs under a supervised task; moduledoc names the supervisor; if not `Letflow.Engine.PluginTaskSupervisor`, moduledoc states why a separate one was added | §4.1 (async_nolink/yield/shutdown shape), §4.4 (named supervisor `Letflow.Engine.Lua.TaskSupervisor` + justification), §8 item 3 (moduledoc requirement) |
| 6 | Moduledoc states this RESTATES LUA-10 as layer 2, that the "enforced by the host / not relying on Lua to cooperate" clause forbids satisfying it with `:max_instructions`, and that neither LUA-08 nor LUA-10 is met without both layers | §1 (rationale), §8 item 1 (moduledoc requirement, verbatim in substance) |
| 7 | Moduledoc carries forward PluginInterface's disclosed limitation verbatim in substance: a hard kill of the BEAM node or `System.halt/0` is NOT covered | §7, §8 item 4 |
| 8 | `mix test` and `mix compile --warnings-as-errors` both pass with real output quoted | TEST-RUNNER step produces real output; this design's signatures and the reused, already-compiling `plugin_interface.ex` shape do not introduce anything that should fail either check on its own |

---

## 10. Cross-Module Dependencies and Invariants

| Module | Change required in REQ-155 |
|---|---|
| `Letflow.Engine.Lua.Executor` | Extend `execute_with_manifest/2,3` per §3; add `default_timeout_ms/0`; wrap the existing evaluation body in the supervised-task shape per §4 |
| `Letflow.Application` | Register `{Task.Supervisor, name: Letflow.Engine.Lua.TaskSupervisor}` per §2 |
| `Letflow.Engine.Lua.Sandbox` | No change beyond REQ-154's `Sandbox.new/1` update — unaffected by this requirement |
| `Letflow.Engine.PluginTaskSupervisor` / `plugin_interface.ex` | No change — read only, as the pattern this design reuses (§4.1); not called into by this module |
| Application config | New key `:letflow, :lua_wallclock_timeout_ms` (`pos_integer()`), alongside REQ-154's `:lua_max_instructions` |

| Invariant | This module's role |
|---|---|
| Per-invocation isolation (LUA-EC-1, carried from REQ-153/154) | Maintained: each call still constructs a fresh sandbox inside a fresh task; no task or sandbox is reused across invocations |
| Budget non-catchability at layer 2 (new, this requirement) | The wall-clock kill is unconditional and has no code path by which a script can intercept, delay, or cancel it — it is enforced entirely outside the task's process |
| `is_binary` guard on tenant input path (ISS-0350, carried from REQ-154) | Unchanged — guard remains on both arities |
| Two-layer completeness (decision 0014) | Neither `Letflow.Engine.Lua.Executor`'s moduledoc nor REQ-154's may claim LUA-08/LUA-10 met independently of this requirement |

---

## 11. Open Questions

| ID | Question | Blocks |
|---|---|---|
| OQ-1 | The exact value for the production default `:lua_wallclock_timeout_ms` is ELIXIR-DEV's choice, to be documented in the config comment, consistent with expected Letflow flow-step script latencies (analogous to REQ-154's OQ-2 on the instruction-budget default). A materially shorter value should be used in `config/test.exs` so timeout-path tests run quickly without weakening what they assert. | REQ-155 implementation |
| OQ-2 | §9 item 3's process-death assertion: this design recommends `Task.Supervisor.children/1` on `Letflow.Engine.Lua.TaskSupervisor` returning no lingering child as the primary mechanism, since the task's pid is not otherwise part of `execute_with_manifest/2,3`'s public return value. If TEST-DESIGNER instead needs the pid directly (e.g. to call `Process.alive?/1`), a test-only mechanism to observe it (such as a telemetry event emitted around task start, or `Task.Supervisor.children/1` combined with `Process.info/1` filtering) must be chosen by TEST-DESIGNER/ELIXIR-DEV rather than adding a production-facing parameter whose only purpose is exposing an implementation-internal pid. This choice is left open rather than silently resolved. | REQ-155 test design |
| OQ-3 | The relationship between a configured `:max_instructions` budget and a configured `:timeout_ms` is not itself validated by this design (e.g. no check that `timeout_ms` is "large enough" for a given budget to plausibly exhaust first under normal, non-adversarial scripts). Both are independently configurable per call site; whether a future requirement should add a sanity check or documentation guidance linking the two values is left open. | Not blocking — informational only |
| OQ-4 | Whether `default_timeout_ms/0` and `default_budget/0` should be consolidated into a single "default execution opts" helper (reducing duplication) is a stylistic choice left to ELIXIR-DEV; this design specifies the two independent helpers for parity with REQ-154's existing structure and does not mandate consolidation. | Not blocking — informational only |
