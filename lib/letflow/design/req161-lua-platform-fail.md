# Design: REQ-161 — `platform.fail` terminates by a mechanism the script cannot
intercept (LUA-15 restated)

**Requirement:** REQ-161
**Stage:** S5
**Owner (design):** CODE-DESIGNER
**Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-27
**Extends:** `lib/letflow/design/req160-lua-host-api-write.md` (REQ-160, the
`execution_context`/`install/3` closure-capture mechanism, and the same
process-scoped-side-channel idiom `write_variable`'s staging buffer already
established), `lib/letflow/design/req157-lua-capability-model.md` (the capability
matrix — this design edits one row's `stub` tag only, `required` stays `:none`),
`lib/letflow/design/req148-lua-runtime-spike.md` (the empirical evidence this design's
central claim is built on, cited by section, not re-derived).

---

## 0. Sources read for this design

- `handoffs/WF02-REQ161-20260827/step-01-code-designer.json`
  (`context.requirement_text`, `task.acceptance_criteria`)
- `docs/requirements.yaml` REQ-161 entry (full `description` and 7-item
  `acceptance_criteria`)
- `docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md` — the LUA-15
  restatement watchlist reasoning and the "same shape as REQ-154" framing
- `lib/letflow/design/req148-lua-runtime-spike.md` §4 (OQ-2 (b)) — the empirical
  finding this design is built on: cited, not re-run
- `lib/letflow/engine/lua/platform.ex` (full) — the existing 8-row
  `@capability_matrix`, `install/1,2,3`'s fold, `run_stub/5`, and the current
  `:fail` clause (lines 440–452 as of this design), which this design finds
  **incorrect** relative to the restated requirement (§1.2)
- `deps/lua/lib/lua.ex` — `do_call_function/3`'s three `rescue e -> ...` clauses
  (native-func, closure, compiled-closure) and `execute_function/4`'s bare
  `catch thrown_value -> ...` clause (`Lua.API`/`deflua` path, not used by
  `platform.ex`) — read directly to verify what tv-labs/lua's call boundary
  actually intercepts (§2.2)
- `deps/lua/lib/lua/vm/stdlib.ex` `lua_pcall/2`/`lua_xpcall/2` (lines 252–284) — the
  real Lua-visible `pcall`/`xpcall` implementations, both `rescue`-only, no `catch`
  clause of any kind — read directly (§2.2)
- `lib/letflow/engine/lua/executor.ex` (full) — `execute_with_manifest/2,3`'s
  `Task.Supervisor.async_nolink/2` + `Task.yield/2` mechanism (REQ-153/154/155/156,
  unedited by this design), `handle_yield_result/3`'s `{:exit, reason}` clause
  (lines 422–423) and the raw-heap-limit path's `:DOWN` handling (lines 345–382) —
  read to determine exactly how far a task's raw exit reason survives before this
  module's own code collapses it (§4)
- `lib/letflow/engine/plugin_interface.ex` moduledoc, "Crash safety" and "Scope
  boundary" sections — cited for (a) the same `rescue`-does-not-catch-`exit`
  principle already on record elsewhere in this codebase, and (b) the same
  "no engine-side node-dispatch call site exists yet" disclosure pattern this
  design's own moduledoc must restate for SCRIPT_FAILED (§5)
- `lib/letflow/engine/lua_script_audit.ex` moduledoc — "nothing in this codebase
  calls `execute_script_for_audit/6`" — cited as the same category of undispatched
  seam (§5)
- `docs/anti-patterns.md` — no entry applicable to this design's own scope (checked)

---

## 1. Scope boundary

### 1.1 In scope

1. `platform.fail(reason, details)`'s exact termination mechanism, and the proof
   that it is uninterceptable by a script wrapping the call in `pcall` (§2, §3).
2. The structured SCRIPT_FAILED outcome shape, carrying `reason`/`details`
   host-readable, and how it is pattern-match-distinguishable from a future
   SCRIPT_ERROR shape (§3.3, §4).
3. `platform.ex`'s `@capability_matrix` `:fail` row's `stub` tag and `run_stub/5`
   clause, replacing the current (incorrect, §1.2) implementation.
4. An honest statement of how far the SCRIPT_FAILED distinction survives past
   `platform.ex`'s own boundary, through `Letflow.Engine.Lua.Executor`'s existing,
   unedited code (§4) — read, not assumed.

### 1.2 The existing `:fail` stub is the exact hazard this requirement restates

`platform.ex`'s current `run_stub(:fail, ...)` clause (lines 440–452) builds a
message from the call's first argument and then raises `Lua.RuntimeException`
(via `raise/2`, with `scope: [:platform]`, `function: :fail`, that message, and
`reason: :explicit_fail`) — an ordinary `Exception` struct.

`Lua.RuntimeException` is an `Exception` struct raised via `raise/2` — precisely the
shape REQ-148's spike OQ-2 (b) proved is `pcall`-catchable (§2.1). The existing
moduledoc section for REQ-157 even states this outcome as if it were acceptable:
*"REQ-159 and REQ-160 ... `now`/`fail` are untouched by either requirement"* — i.e.
the current `:fail` row was written as a capability-matrix placeholder only, before
this restatement's hazard was worked through. **This design replaces that clause
entirely.** A script today can do exactly what decision 0014 warns about: a Lua
`pcall` wrapped directly around a `platform.fail(...)` call returns `false` plus the
message, and the script's execution continues past that `pcall` block — nothing
about the current stub stops it.

### 1.3 Out of scope (per requirement text)

- The engine-side half of LUA-15 — recording a SCRIPT_FAILED event and
  transitioning the instance per the node's error policy. No file under
  `lib/letflow/engine/` outside `platform.ex` is edited by this requirement. §5
  states plainly that no call site for this exists today.
- REQ-162's SCRIPT_ERROR shape (an uncaught runtime crash) — not built here. §3.3
  only defines the two shapes' *relationship* (never structurally identical), not
  REQ-162's own fields.
- Any change to `Letflow.Engine.Lua.Executor`'s `Task.Supervisor`/`Task.yield`
  mechanism itself — REQ-153/154/155/156's code is read (§4) to state honestly what
  it does with a `platform.fail` exit today, not edited to add new handling for it.

---

## 2. The central technical question — why an ordinary raise fails, and what replaces it

### 2.1 REQ-148 spike §4 (OQ-2 (b)): host-raised errors ARE `pcall`-catchable — cited, not re-derived

REQ-148's spike, §4 ("OQ-2 (b): pcall Interception of Host Function Errors"), ran
this exact experiment against the real, vendored `tv-labs/lua` runtime:

> A `Lua.set!/3`-installed host function calls `raise "host function exploded"`.
> Calling it from inside a Lua `pcall` wrapper. **Actual output:** `pcall ok = false`,
> `pcall err = "host function exploded"`.
> **Verdict:** YES — host function errors ARE catchable via `pcall`.

This is the load-bearing fact this design is built on: **an ordinary `raise/1,2` from
inside a `Lua.set!/3`-installed native function is caught by the script's own
`pcall`, and the script's execution continues past the `pcall` block.** The spike's
own §4 "Implication for S5" text even names `platform.fail` explicitly: *"`platform.fail(msg)`
... can be implemented as a host function that raises, and Lua scripts can catch it
with `pcall` if desired"* — written before decision 0014's LUA-15 restatement made
clear that "catch it if desired" is exactly the defect, not an acceptable feature.
**This design does not re-run this experiment; it treats the verdict as settled.**

### 2.2 Verified directly against `deps/lua`: WHY `raise` is catchable, and what is not

Rather than stopping at "the spike found raise is catchable, so avoid raise" — which
would leave the actual mechanism unproven — this design traces exactly *where* the
interception happens, confirmed by reading the vendored dependency source (the same
rigor REQ-159's design applied to `Lua.encode!/2`'s table-decoding requirement, and
REQ-160's design applied to `deps/lua/lib/lua/vm/value.ex`'s `decode/3`).

**`platform.ex` installs every `platform.*` function via `Lua.set!/3`
(`install/2`/`install/3`'s fold — unedited by this requirement), which resolves to a
`{:native_func, fun}` tuple internally.** `deps/lua/lib/lua.ex`'s
`do_call_function/3` is the call boundary every such function passes through: its
clause for the `{:native_func, fun}` shape (verified directly against the file)
invokes `fun.(args, state)` inside a `try` whose only rescue clause matches `e ->`
unconditionally and returns `{:error, e, recover_state(e, state)}` — i.e. it turns
any raised exception into an ordinary `{:error, _, _}` return value, never letting
it propagate further as a raw exception.

This is the exact mechanism that converts a plain Elixir `raise` inside a
`platform.*` function into a value `lua_pcall/2`
(`deps/lua/lib/lua/vm/stdlib.ex` lines 252–260) can catch: `lua_pcall/2`'s body
calls `Executor.call_function/3` and, on success, returns `[true | results]`; its
`rescue` block has one clause matching `e in [RuntimeError, AssertionError,
TypeError, ArgumentError]` (returning `[false, ProtectedCall.error_value(e)]` plus
unwound state) and a catch-all `e ->` clause (returning `[false,
Exception.message(e)]` plus unwound state) — both are ordinary `rescue` arms with no
`catch` clause anywhere in the function. `lua_xpcall/2` (lines 268–284, same file)
follows the identical two-clause `rescue`-only shape.

Both of these are Elixir `rescue` clauses. **`rescue` in `try/rescue` intercepts
only values raised via `raise/1,2` (`Exception` structs) — it has no clause pattern
that ever matches an `exit/1` call or an externally delivered exit signal.** This is
not an inference from the spike; it is a property of the `rescue`/`catch` split
Elixir's own `try` construct defines, and it is independently corroborated *in this
same codebase*: `lib/letflow/engine/plugin_interface.ex`'s moduledoc states the
identical fact in its own "Crash safety" section — *"`try/rescue` catches a `raise`
... but has no clause that observes ... an `exit/1` call, or an external
`Process.exit(pid, reason)` ... without ever running a `rescue` clause."*

**Grepping every `catch`/`rescue` clause on every call path a `platform.*` function
can reach confirms there is no exception:**
- `do_call_function/3`'s three call-shape clauses (native-func, Lua closure,
  compiled closure) are each `rescue e -> ...` only — no `catch`.
- `lua_pcall/2` and `lua_xpcall/2` are each `rescue e in [...] -> ...` / `rescue e ->
  ...` only — no `catch` clause of any kind, anywhere in either function.
- The one bare `catch thrown_value -> ...` clause that exists anywhere in
  `deps/lua/lib/lua.ex` (`execute_function/4`, its `Lua.API`/`deflua`-macro call
  path) is unreachable from `platform.ex`, which installs every function via
  `Lua.set!/3` directly, never via `use Lua.API`/`deflua`. Even if it were reached,
  a bare `catch pattern -> ...` clause (no `:exit` kind specified) matches only
  `throw/1` values in Elixir, never an `exit/1` signal — a second, independent
  reason this path would not intercept an exit either.

**Conclusion: a `platform.*` host function that calls `exit/1` instead of `raise/1,2`
is not intercepted by `pcall`, `xpcall`, or any other construct anywhere in
`tv-labs/lua`'s call chain — confirmed by reading every `rescue`/`catch` clause on
that chain, not inferred from the raise-only spike result.** This is the mechanism
§3 specifies.

### 2.3 Why `exit/1`, not merely "not `raise`" — what actually terminates the process

Calling `exit(reason)` from inside the process currently evaluating the script (the
one process running `Lua.eval!/2`, per REQ-153 §4/REQ-155 §4.2's confirmed "the
entire script body runs inside one process" invariant) does two things
simultaneously, both load-bearing:

1. **It is not caught anywhere on the call chain (§2.2)**, so it propagates past
   `do_call_function/3`, past `resolve_and_call/3`, past `Lua.eval!/2` itself, and
   past whatever Lua bytecode was executing (including an enclosing `pcall`) with no
   opportunity for any of them to intervene.
2. **It terminates the calling process outright**, per ordinary BEAM/OTP `exit/1`
   semantics — an unhandled `exit/1` (any `reason` other than `:normal`) ends the
   calling process immediately. There is no "resume after `exit`" — nothing in that
   process ever executes again. This is what makes "does not run to completion"
   true in the strongest possible sense: not merely "the `platform.fail` call
   itself is not caught," but the entire process the script was running in ceases
   to exist. A pcall wrapper cannot "continue past" a call that ends the very
   process trying to continue.

This mirrors the same class of mechanism decision 0014 (a) and REQ-155/156 already
rely on for their own out-of-band limits — a "preemptively-scheduled BEAM process,
interruptible by construction" — except here the interruption is **self-initiated at
the exact moment `platform.fail` is called**, rather than externally triggered by a
supervising process on a timeout. `platform.fail` needs no external supervisor to
enforce its termination because it does not wait for one: the call terminates its
own process synchronously, within the same native-function invocation that decided
to fail.

### 2.4 The structured payload rides the exit reason itself — not a process-dictionary side channel

Because the terminating process is the one place the script's own execution lives,
and it is *the same process being destroyed*, `reason`/`details` cannot be recovered
from that process's memory (e.g. a process dictionary, à la REQ-160's
`write_variable` staging buffer, §2.3 of that design) after termination — there is no
process left to read it from. The mechanism must carry the payload out **on the exit
signal itself**, which is how the requirement's own suggested option ("recording the
failure host-side at call time via a side channel the engine reads regardless of
whether the script's own execution continues, or terminating the enclosing process
outright") resolves to a single combined mechanism rather than two alternatives:

```
@type script_failure :: %{reason: String.t(), details: term()}
@type script_failed_exit_reason :: {:script_failed, script_failure()}
```

`platform.fail(reason, details)` calls `exit({:script_failed, %{reason: ...,
details: ...}})`. This is BOTH the "recording at call time" (the structured value is
constructed and attached to the exit signal in the same native-function invocation
that decides to fail — nothing is deferred to a later read) AND "terminating the
enclosing process outright" (the `exit/1` call itself). The two options the
requirement names are, for this specific hazard, the same mechanism seen from two
angles: the payload only ever escapes the process *because* the process's
termination signal is what carries it.

**Why this reaches a reader at all, despite the terminated process's memory being
gone:** ordinary BEAM/OTP `Process.monitor/1` semantics — already the mechanism
REQ-155 §4.2 and REQ-156 §5.1/§5.2 rely on for their own kill observation — deliver
the **exact, unmodified exit `reason` term** on the `:DOWN` message to any process
that set up a monitor, for any reason other than the two BEAM-reserved rewrites:
`:kill` (always rewritten to `:killed` on the receiving end, by design, so that a
forced kill cannot be spoofed) and `:normal` (delivered as `:normal`, meaning no
failure). `{:script_failed, %{reason: ..., details: ...}}` is neither of those two
reserved atoms — it is an arbitrary term, and arbitrary terms are delivered
verbatim. This is standard, unconditional OTP behavior, not something this design
introduces or must verify empirically — it is the same delivery guarantee
`Executor`'s own moduledoc already relies on when it says a task's non-timeout crash
"exits for any other reason" and folds into `handle_yield_result({:exit, reason},
...)` (§4 traces this exact code).

### 2.5 Why this is stronger than, not merely different from, "hope the script doesn't catch it"

The requirement's own framing — "termination CANNOT DEPEND ON THE SCRIPT DECLINING
TO CATCH THE ERROR" — is satisfied structurally, not statistically: there is no
Lua-level construct (`pcall`, `xpcall`, a metatable `__call` handler, a coroutine
wrapper) that operates above the `do_call_function/3`/`rescue` boundary, because
none of them are implemented as anything other than ordinary Elixir functions
running in that same process, subject to the same `exit/1` semantics as every other
line of code in that process. A future addition to `tv-labs/lua`'s stdlib could not
retroactively make `exit/1` interceptable from Lua without Elixir/OTP itself
changing what `rescue` and `catch` mean — this is not a property of the current
library version that could quietly regress; it is baked into the meaning of
`raise`/`rescue` vs. `exit`/monitor in the host language, one level below the
library entirely.

---

## 3. `platform.fail(reason, details)` — real implementation

### 3.1 Capability requirement — unchanged, UNGATED

`@capability_matrix`'s existing `%{name: :fail, required: :none, stub: :fail}` row
is **unedited** by this design (`required: :none` stays exactly as-is — no
capability-matrix row addition, no new gate). Only the `:fail` clause of
`run_stub/5` changes. `Capabilities.check!/3`'s fold-level call for this row
continues to evaluate `:none` to an unconditional pass, per `install/3`'s existing,
unedited three-step wrapper sequence (`platform.ex` moduledoc, "REQ-157" section) —
this design adds no code before that step and does not touch it.

### 3.2 Argument handling

```
@spec do_fail(args :: [term()]) :: no_return()
```

Control flow, in prose (only reached once the fold-level `:none` capability check
has trivially passed, per §3.1 — never actually denies):

1. The Lua call's first argument (`reason`) is coerced to a `String.t()`: if it is
   already a binary, used as-is; otherwise (a number, a table reference, `nil`, or
   anything else) rendered via `inspect/1` after a `Lua.decode!/2` pass if it is a
   table reference (mirrors `do_log/3`'s established `decode_log_context/2`
   handling of an un-decoded `{:tref, id}` argument, REQ-159 moduledoc "A related,
   smaller correction to design §6.1 step 1" — the identical boundary behavior
   applies to any table-shaped argument reaching a `Lua.set!/3` callback). A missing
   `reason` argument (script called `platform.fail()` with no arguments) defaults to
   the literal string `"script called platform.fail with no reason"`.
2. The Lua call's second argument (`details`) is decoded via `Lua.decode!/2` if it
   is a table reference, then normalized through
   `Letflow.Engine.LuaNumberMarshalling.from_lua/1` one level deep on any resulting
   map's values (mirrors `do_call_service/3`'s/`do_emit_event/3`'s own
   `decode_lua_payload/2` + `normalize_from_lua/1` pipeline, REQ-160 §4.4 step 2/§5.3
   step 3, applied here for the same reason: a script-supplied table argument must
   not carry raw VM-internal number representations into a value the host will
   later inspect or persist). A missing `details` argument defaults to `nil`.
3. Constructs `%{reason: reason_string, details: normalized_details}` (the
   `script_failure()` type, §2.4) and calls
   `exit({:script_failed, script_failure})` — **never returns**. No Lua return
   value is ever produced for this call, because the calling process ends before
   any return could occur.

This function raises nothing, in the `raise/1,2` sense, ever — the only signal it
produces is the `exit/1` call in step 3, which (§2.2) no part of `tv-labs/lua`'s call
chain intercepts.

### 3.3 The SCRIPT_FAILED outcome shape, and why it cannot collapse into a future SCRIPT_ERROR shape

```
@type script_failed_exit_reason :: {:script_failed, script_failure()}
@type script_failure :: %{reason: String.t(), details: term()}
```

This tagged tuple is the entirety of what this requirement defines as "the
SCRIPT_FAILED outcome." Its structural distinguishing property, by construction:

| | SCRIPT_FAILED (this requirement) | SCRIPT_ERROR (REQ-162, NOT built here) |
|---|---|---|
| **How it is produced** | A script calls `platform.fail(reason, details)` deliberately; `do_fail/1` (§3.2) calls `exit({:script_failed, script_failure()})` | An uncaught Lua runtime error (a bug, a type error, a sandbox-denied call the script didn't `pcall`) propagates out of `Lua.eval!/2` as a `Lua.RuntimeException` (or, per REQ-153/154/155's existing `rescue` clauses in `executor.ex`, another raised exception) — **not** an `exit/1` |
| **Observed via** | A process exit reason, delivered on a `:DOWN` monitor message (or `Task.yield/2`'s `{:exit, reason}` clause) — the evaluating process is dead | A normal function return from `Lua.eval!/2`/`Executor.execute_with_manifest/2,3`'s existing `rescue`-wrapped call (REQ-153/154 — the process is alive, the call simply returned/raised-and-was-rescued in the ordinary sense) |
| **Elixir-level shape** | A 2-tuple, head atom `:script_failed`, second element a `%{reason: String.t(), details: term()}` map | Whatever REQ-162 specifies — necessarily NOT a 2-tuple headed by `:script_failed` (this design reserves that exact tag), and necessarily carrying REQ-162's own three named LUA-16 fields (stack trace, instruction count consumed, capability state at failure) which `script_failure()` has no fields for at all |
| **Pattern-matchable test** | `{:script_failed, %{reason: _, details: _}}` matches; a plain `Lua.RuntimeException` struct, or any future `%{stack_trace: _, instruction_count: _, capabilities: _}`-shaped SCRIPT_ERROR map, does NOT match this pattern | REQ-162's own future shape, whatever it is, will not match `{:script_failed, _}` unless REQ-162 quotes this exact tag verbatim — which it must not, per this design reserving `:script_failed` to mean "deliberate `platform.fail` call" specifically |

The two are distinguishable **today**, at the raw exit-reason/`:DOWN`-message level,
by a single `case`/pattern match on the reason's shape — `{:script_failed, _}` vs.
anything else (a `Lua.RuntimeException` struct, a `:killed` atom, a
`{:wallclock_timeout, _}` tuple, or any other crash reason `executor.ex` already
produces). No test needs REQ-162 to exist to prove this distinction; REQ-162 needs
only to never choose `:script_failed` as its own tag, which this design states
explicitly so REQ-162's CODE-DESIGNER does not have to re-derive it.

### 3.4 `@capability_matrix`/`run_stub/5` edits, precisely

```
@type stub_spec :: :now | :fail | :read_variable | :get_instance_state | :log
                  | :write_variable | :call_service | :emit_event
```

Unchanged — `:fail` was already a member of this type; no new tag is introduced.

`@capability_matrix`'s `:fail` row (`%{name: :fail, required: :none, stub: :fail}`)
is copied verbatim, unedited (§3.1). The other 7 rows are untouched by this
requirement.

```
@spec run_stub(stub_spec(), atom(), [term()], Platform.execution_context(), Lua.t()) ::
        [term()] | {[term()], Lua.t()} | no_return()
```

The existing `run_stub(:fail, _function_name, args, _execution_context, _lua)`
clause's body is replaced by a call to `do_fail/1` (§3.2) with the call's argument
list — the clause itself keeps ignoring `execution_context` and `lua` (unchanged
from the current stub: `platform.fail` reads no tenant-scoped state and builds no
Lua-encoded return value, since it never returns at all). The function's overall
`@spec` gains `no_return()` to the union, since this is now the one row whose stub
never produces a value in either shape the other seven rows can.

---

## 4. How far the SCRIPT_FAILED distinction survives past `platform.ex` today — read, not assumed

This section states, plainly, exactly what happens if a script calls
`platform.fail` through the full, already-shipped `Executor.execute_with_manifest/2,3`
path — because that path is real, shipped code (REQ-153/154/155/156), and this
design must not silently claim SCRIPT_FAILED reaches a caller of `execute_with_manifest`
in a distinguishable shape when it does not, today.

**The `Task.Supervisor.async_nolink/2` path (`:max_heap_words == nil`,
`execute_with_manifest/2,3`'s default arm):** the task's process, running
`Lua.eval!/2`, calls `exit({:script_failed, script_failure})` from inside
`platform.fail` (§3.2 step 3). `Task.yield/2` observes this as `{:exit, reason}`
with `reason = {:script_failed, script_failure}` — the exact, unmodified term
(§2.4). **But `executor.ex`'s own `handle_yield_result/3` clause for this case**
(lines 422–423, unedited by this requirement) matches `{:exit, reason}` and returns
an `{:error, <string>}` tuple built by prefixing `"#{inspect(__MODULE__)} task
crashed: "` to `format_exit_reason(reason)` — **it stringifies `reason` via
`format_exit_reason/1` (which falls back to `inspect/1`) into a single opaque
string, indistinguishable in shape from any other task crash** — a genuine bug, a
sandbox violation this design does not touch, or any
other `exit/1` reason all produce the identical `{:error, "... task crashed: " <>
<string>"}` shape at `execute_with_manifest/2,3`'s own boundary. **The
`{:script_failed, _}` tag is still present inside that string (as text, via
`inspect/1`), but is no longer pattern-matchable as a term** — a caller of
`execute_with_manifest/2,3` today cannot distinguish a deliberate `platform.fail`
from an arbitrary crash without parsing that string.

**The raw-heap-limit path (`:max_heap_words` configured, `run_with_heap_limit/4`):**
the same collapse happens one level up — the `:DOWN` handling (lines 345–382) has an
explicit clause for `:killed` (line 367) and a catch-all `{:DOWN, ^monitor_ref,
:process, ^pid, reason} -> {:error, "... task crashed: " <> format_exit_reason(reason)}`
(line 370–371) for every other reason, including `{:script_failed, _}` — same
stringified, non-pattern-matchable outcome.

**This is stated here as the honest wiring gap this requirement leaves open —
mirroring REQ-159/160's own OQ-1 precedent for deferred dispatch, and
`plugin_interface.ex`'s and `lua_script_audit.ex`'s own moduledoc disclosures for the
identical category of gap (no call site exists yet for the engine-side half).**
`executor.ex` is not in this requirement's `owned_modules`; this design does not
edit `handle_yield_result/3` or the raw-heap-limit `:DOWN` clauses to special-case
`{:script_failed, _}` ahead of `format_exit_reason/1`. **Consequence for this
requirement's own tests (§9, AC1/AC3):** the pattern-matchability the acceptance
criteria require must be proven at the raw process/monitor level — spawning (or
`Task.async`-ing) a process that runs `Lua.eval!/2` directly against
`Letflow.Engine.Lua.Platform.install/3`'s output, and asserting on the raw
`{:DOWN, _, :process, _, reason}` / `{:exit, reason}` term — **not** through
`Executor.execute_with_manifest/2,3`, whose own `{:error, String.t()}` return shape
does not preserve the distinction today. This is the same layering discipline
REQ-160 §2.5/§9 already used: proving a property at the layer that actually owns it
(`Platform`/the raw task boundary here; `Platform` alone there) rather than through a
layer that does not yet carry it end-to-end.

---

## 5. The engine-side half of LUA-15 — no call site exists today

LUA-15's full text names two engine-side obligations beyond producing the
structured failure: "The engine MUST record a SCRIPT_FAILED event and transition
the instance per the node's error policy." Checked directly, not assumed:

- `lib/letflow/engine/plugin_interface.ex`'s own moduledoc states plainly: *"This
  module also does **not** wire `resolve_*` or `invoke/2,3` into the engine's actual
  node-dispatch path ... that belongs to whichever future requirement builds
  runtime plugin/service-task dispatch (most plausibly REQ-056, `pending`)."* No
  runtime node-dispatch mechanism exists in this codebase yet that a SCRIPT_FAILED
  outcome could be threaded into.
- `lib/letflow/engine/lua_script_audit.ex`'s moduledoc states: *"nothing in this
  codebase calls `execute_script_for_audit/6`."* No caller exists to receive a
  script's outcome (success, SCRIPT_FAILED, or a future SCRIPT_ERROR) and act on it
  at all.
- `Executor.execute_with_manifest/2,3` (§4) is the closest thing to a real caller of
  `Lua.eval!/2` that exists today, and it does not record an event or consult any
  node's error policy — it returns a bare `{:ok, _} | {:error, _}` tuple to whoever
  calls it, and (as of this design) no such caller exists in this codebase either.

**This requirement does not invent a dispatch path, an event-recording call, or an
error-policy transition to close this gap** — doing so would be scoping this
requirement into REQ-056 (pending) or whichever future requirement builds runtime
node dispatch, exactly the invention the task brief prohibits. The moduledoc this
design specifies (§6) states this plainly: the engine-side SCRIPT_FAILED
event-recording-plus-error-policy-transition half of LUA-15 has **no real call site
today**, mirroring REQ-159/160's own OQ-1 precedent for the identical category of
deferred wiring gap.

---

## 6. Moduledoc content this design specifies

`platform.ex`'s existing moduledoc gains a new section, positioned after the
existing "REQ-160" section, covering:

1. **States this requirement restates LUA-15**, quoting LUA-15's literal text and
   decision 0014's watchlist reasoning for why (the pcall-continuation hazard, §1.2,
   §2.1) — the same restatement-disclosure convention every other restated LUA-*
   requirement's moduledoc section in this file already follows (REQ-152's `now`
   section, REQ-153/154/155/156's `executor.ex` sections).
2. **States explicitly that an ordinary raised Lua error (the requirement's own
   "obvious implementation") would let a script `pcall` its own `platform.fail` and
   continue** — citing REQ-148 spike §4/OQ-2(b) by section number (§2.1 of this
   design), not re-deriving it, and citing the exact prior `:fail` stub this design
   replaced (§1.2) as a concrete instance of the hazard, not a hypothetical one.
3. **Names the actual mechanism**: `exit({:script_failed, %{reason:, details:}})`,
   called from inside the `platform.fail` native function itself, terminating the
   calling process outright — with the one-sentence reason it is uninterceptable
   ("`tv-labs/lua`'s entire `pcall`/`xpcall`/native-call boundary is implemented via
   `rescue`, which does not intercept `exit/1`, verified directly against
   `deps/lua/lib/lua.ex` and `deps/lua/lib/lua/vm/stdlib.ex`" — §2.2 of this design,
   cited by section for the full trace).
4. **States plainly whether LUA-15's engine-side half has a real call site**: "No.
   Neither `lib/letflow/engine/plugin_interface.ex` nor
   `lib/letflow/engine/lua_script_audit.ex` has a real caller wiring a script's
   outcome into node-dispatch or an error-policy transition; `Executor.execute_with_manifest/2,3`
   is the closest existing caller of `Lua.eval!/2` and itself has no caller yet
   either. This requirement produces the structured SCRIPT_FAILED outcome only — it
   does not, and cannot yet, wire the event-recording/error-policy-transition half,"
   worded to the same explicitness as `lua_script_audit.ex`'s own "nothing in this
   codebase calls..." sentence — never implying the routing half is met.
5. **States the SCRIPT_FAILED/SCRIPT_ERROR non-collapse property** (§3.3), naming
   the reserved `:script_failed` tag explicitly so REQ-162's own moduledoc section,
   whenever it lands, can cite this one rather than re-deriving the reservation.
6. **States the honest `executor.ex` stringification gap** (§4) — that today, a
   `platform.fail` exit reason IS pattern-matchable at the raw task/monitor level
   but is NOT preserved as a matchable term through `execute_with_manifest/2,3`'s
   own `{:error, String.t()}` return; this requirement's own tests must therefore
   assert the distinction at the raw process boundary, not through `Executor`.

---

## 7. Cross-module dependencies

| Module | Direction | Nature of dependency |
|---|---|---|
| `Letflow.Engine.Lua.Platform` (extended) | → `Letflow.Engine.LuaNumberMarshalling` | `do_fail/1`'s `details` normalization (§3.2 step 2) reuses `from_lua/1`, no new conversion rule |
| `Letflow.Engine.Lua.Platform` (extended) | → BEAM/OTP `exit/1` + `Process.monitor/1` semantics | The entire termination mechanism (§2.3, §2.4) — no Letflow module, no external dependency; this is a language/runtime-level guarantee |
| `deps/lua` (`Lua.set!/3`, `do_call_function/3`, `lua_pcall/2`/`lua_xpcall/2`) | (read, not called by this design) | The call chain whose absence of any `catch :exit` clause is this design's central evidence (§2.2) — verified by reading the vendored source directly |
| `Letflow.Engine.Lua.Executor` (`execute_with_manifest/2,3`, `handle_yield_result/3`) | (read, not edited) | The existing caller whose current stringification behavior on any task exit — including a `platform.fail`-triggered one — is documented honestly in §4, not silently assumed to preserve the SCRIPT_FAILED distinction |
| `lib/letflow/engine/plugin_interface.ex`, `lib/letflow/engine/lua_script_audit.ex` | (read, cited) | Both moduledocs' existing "no call site" disclosures, cited as precedent for this design's own §5/§6 item 4 disclosure — neither file is edited |
| (future, not built here) | → LUA-15's engine-side event recording + error-policy transition | No real caller exists yet (§5) — whichever future requirement builds runtime node dispatch (most plausibly REQ-056) is the first candidate, per `plugin_interface.ex`'s own moduledoc naming it |
| (future, REQ-162, not built here) | → the reserved `:script_failed` tag (§3.3) | REQ-162's own SCRIPT_ERROR shape must not reuse this tag — stated here so REQ-162's design does not have to re-derive the reservation |

---

## 8. Open questions

**OQ-1 (the central deferred wiring gap, §5 — mirrors REQ-159/160's own OQ-1).** No
file under `lib/letflow/engine/` outside `platform.ex` is edited by this
requirement. The engine-side half of LUA-15 (event recording, error-policy
transition) has no real call site in this codebase today, for either
`plugin_interface.ex`'s node-dispatch seam or `lua_script_audit.ex`'s audit-execution
seam. This design states the structured outcome (`{:script_failed,
%{reason:, details:}}`) a future caller would consume, without inventing that
caller.

**OQ-2 (the `executor.ex` stringification gap, §4).** `Executor.execute_with_manifest/2,3`'s
existing `handle_yield_result/3` and raw-heap-limit `:DOWN` handling both collapse
every non-`:killed`, non-timeout exit reason (including a deliberate
`{:script_failed, _}` one) into an opaque, `inspect/1`-rendered string, via code
this requirement does not own or edit. Whether a future requirement should special-case
`{:script_failed, _}`/`{:script_error, _}` (REQ-162) ahead of `format_exit_reason/1`
so the distinction survives to `execute_with_manifest/2,3`'s own callers is left
open — not decided here, and not required by this requirement's own 7 acceptance
criteria (§9), all of which are provable at the raw task/monitor boundary (§4).

**OQ-3.** `do_fail/1`'s `reason` coercion (§3.2 step 1) renders a non-binary,
non-table `reason` argument via `inspect/1`. Whether a future requirement wants a
richer, LUA-16-style structured rendering for a non-string `reason` (e.g. preserving
a Lua table's original shape rather than an `inspect/1` string) is left open; none of
this requirement's own acceptance criteria require one, and REQ-162's own
`capability state at failure`/stack-trace fields are a separate, unrelated concern
this requirement does not touch.

**OQ-4.** Whether a script calling `platform.fail` from inside a Lua coroutine
(`coroutine.wrap`/`coroutine.resume`, if ever exposed — currently denied by the
sandbox's default deny-set per REQ-148 spike §6/LUA-03's restatement) would still
terminate the entire host process the same way, or only the coroutine, is left open
as moot: coroutines are not currently reachable from a sandboxed script at all, so no
test in this requirement's scope exercises that interaction, and this design makes
no claim about it either way.

---

## 9. Traceability — REQ-161's 7 acceptance criteria

| # | Acceptance criterion (`docs/requirements.yaml` REQ-161, verbatim/paraphrased) | Design element |
|---|---|---|
| 1 | A script that wraps its own `platform.fail` in `pcall` and continues STILL yields SCRIPT_FAILED and does NOT run to completion; must fail if the uninterceptable mechanism is removed | §2 (full mechanism trace), §2.3 (process termination, not merely a raise), §3.2 step 3 (`exit/1` call site) — a regression to the old `raise Lua.RuntimeException` clause (§1.2) makes this test observably pass differently (the process survives, `pcall` returns `false`, and script execution continues) |
| 2 | The structured failure carries `reason`/`details` the script passed, readable by the host | §2.4 (`script_failure()` type), §3.2 steps 1–3 (argument coercion into that shape), delivered verbatim via `:DOWN`/`Task.yield`'s `{:exit, reason}` (§2.4's OTP delivery guarantee) |
| 3 | SCRIPT_FAILED is pattern-match-distinguishable from a future SCRIPT_ERROR — the two shapes must not be structurally identical | §3.3 (the full comparison table, the reserved `:script_failed` tag) |
| 4 | `platform.fail` is callable with an EMPTY capability set — ungated by design, no capability_matrix row addition | §3.1 (unedited `required: :none` row, no new gate added) |
| 5 | Moduledoc states this restates LUA-15, explains the pcall-continuation hazard an ordinary raise would create, names the actual mechanism | §6 items 1–3 |
| 6 | Moduledoc states explicitly whether LUA-15's engine-side half has a real call site or none | §5, §6 item 4 |
| 7 | `mix test` and `mix compile --warnings-as-errors` both pass with real output quoted | Not a design-time artifact — ELIXIR-DEV/TEST-RUNNER responsibility at Steps 2/4, same convention as REQ-159 §8/REQ-160 §9's own final row |
