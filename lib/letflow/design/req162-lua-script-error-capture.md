# REQ-162 design — uncaught Lua runtime errors captured as structured SCRIPT_ERROR (LUA-16 restated)

`owner: CODE-DESIGNER`, `depends_on: [REQ-161, REQ-157]`. Restates LUA-16 ("Uncaught
Lua errors MUST be captured by the host and converted to structured SCRIPT_ERROR
events with stack trace, instruction count consumed, and capability state at
failure"). This document is design only — no implementation code. `@spec`/`@type`
blocks are the only code in this file.

---

## 1. Where SCRIPT_ERROR capture lives, and why

**It lives in `lib/letflow/engine/lua/executor.ex`'s `run_script/3`, inside the
existing `rescue e in Lua.RuntimeException` clause — not in `platform.ex`.**

Read directly (executor.ex lines 310–332): `run_script/3` already wraps
`Lua.eval!/2` in a `try/rescue`. Today that rescue has exactly two live clauses for
`Lua.RuntimeException`: a string-matched branch for `"instruction budget exceeded"`
(REQ-154's `{:error, {:budget_exceeded, budget}}`), and an else-branch that collapses
every other `Lua.RuntimeException` into a bare `{:error, Exception.message(e)}` —
this else-branch is exactly the "stringification gap" req161-lua-platform-fail.md
§4/OQ-2 names for a *different* exit path (`{:script_failed, _}` via `exit/1`,
observed at `handle_yield_result/3`) but the identical stringification problem exists
here too, for the *raise*-and-rescue path, and it is this requirement's job to close
it for the raise path specifically.

`platform.ex`'s host functions (`platform.now`, `platform.fail`, `platform.read_variable`,
etc., per req161 §3) execute **inside** the `Lua.eval!/2` call — they are call
targets reached from Lua bytecode, not the boundary that observes an error escaping
`eval!/2`. `platform.ex` has no code path that ever sees a `Lua.RuntimeException`;
it either returns normally to Lua or (for `platform.fail`, per REQ-161) calls
`exit/1` directly, bypassing `raise`/`rescue` entirely. The only place in this
codebase that already sits at the `Lua.eval!/2` call boundary and already owns a
`rescue e in Lua.RuntimeException` clause is `run_script/3`. Extending that existing
clause is strictly additive: it does not touch `platform.ex`, `capabilities.ex`, or
`sandbox.ex`.

### 1.1 The new clause structure (prose, not code)

`run_script/3`'s `rescue e in Lua.RuntimeException` branch keeps its existing
budget-exceeded string check FIRST (unchanged — REQ-154's `{:budget_exceeded, _}`
must never be reclassified as a SCRIPT_ERROR). When that check does not match, the
branch now builds a `script_error()` value (§3) from `e` and the sandbox's grant set
(§4), and returns `{:error, {:script_error, script_error()}}` instead of the current
bare `{:error, Exception.message(e)}`. The `rescue e in Lua.CompilerException`
clause is untouched — a compile-time failure (bad syntax) never reaches a runtime
state at all, so it carries no instruction count or capability state to report, and
LUA-16's scope ("uncaught Lua errors" at runtime) does not cover it.

---

## 2. Instruction count on the uncaught-error path — independently verified, not assumed from the spike

REQ-148's spike (`lib/letflow/design/req148-lua-runtime-spike.md` §5, OQ-2(c)) found
that after a **successful** `Lua.eval!/2` return, the consumed instruction count is
readable via `lua_after.state.instruction_count` — an internal, undocumented
`Lua.VM.State` struct field, not a public API. That finding is for the success path
only. This requirement's own scope is the **uncaught-error** path, which returns
control to the caller by `raise`, not by a normal `{results, lua}` return — so
`lua_after` (the post-`eval!` `Lua.t()`) is never constructed on this path at all;
`%{lua | state: new_state}` inside `eval!/2`'s `case` body is skipped entirely when an
exception propagates, per direct reading of `deps/lua/lib/lua.ex` lines 528–572. The
spike's mechanism does not transfer unchanged, and had to be independently checked.

### 2.1 What was read, directly, in `deps/lua`

- `deps/lua/lib/lua.ex` lines 555–572 (the `rescue` clauses of `eval!/2`): every
  clause either re-raises the caught exception unchanged (`e in [Lua.RuntimeException,
  Lua.CompilerException]`) or wraps it into a new `Lua.RuntimeException` via
  `reraise Lua.RuntimeException, e, ...` — `e` (the original VM-level exception term)
  is passed as `Lua.RuntimeException.exception/1`'s argument, never a raw message
  string, specifically (per the module's own comment, line 564–566) "so the
  `Lua.RuntimeException.exception/1` clause for arbitrary exceptions picks up `:line`,
  `:source`, and `:call_stack`."
- `deps/lua/lib/lua/runtime_exception.ex`: `defexception [:original, :kind, :value,
  :state, :line, :source, :call_stack]`. Critically, **none of the four `exception/1`
  clauses (lines 49–89) ever set the outer `:state` field** — it stays `nil` in every
  case. The generic fallback clause (lines 68–89, the one that handles a wrapped VM
  exception) copies `:line`/`:source`/`:call_stack` off the wrapped `error` via
  `extract_context/1`, but does **not** copy `:state`. **A future implementer who
  reads `exception.state` expecting the VM state is reading the wrong field — it is
  always `nil`.**
- `deps/lua/lib/lua/vm/runtime_error.ex`, `.../type_error.ex`, `.../assertion_error.ex`:
  each independently declares its own `:state` field in its `defexception` list
  (`Lua.VM.RuntimeError`, `Lua.VM.TypeError`, `Lua.VM.AssertionError` — verified by
  reading each file's `defexception` line directly). This is the field that
  survives — it lives on `Lua.RuntimeException.original`, the *wrapped* VM exception,
  not on the wrapper's own `:state` field.
- `deps/lua/lib/lua/vm/executor.ex`: grepped every `raise RuntimeError`/`raise
  TypeError`/`raise AssertionError` call site inside the VM's own opcode-execution
  module. Every site found passes `state: state` — including the two sites this
  requirement's own division-by-zero test exercises directly: line 3789
  (`raise RuntimeError, value: "attempt to divide by zero", line: line, source:
  source, state: state`) and line 3816 (`raise RuntimeError, value: "attempt to
  perform 'n%0'", line: line, source: source, state: state`). `deps/lua/lib/lua/vm/state.ex`
  line 154–157 (`tick!/2`, the instruction-budget raise) does the same.

### 2.2 Finding — branch (a) holds, via a different mechanism than the success path

**The consumed instruction count IS retrievable on the uncaught-error path.**
Mechanism: `exception.original.state.instruction_count`, where `exception` is the
`%Lua.RuntimeException{}` caught by `run_script/3`'s `rescue`, `.original` is the
wrapped `%Lua.VM.RuntimeError{}` / `%Lua.VM.TypeError{}` / `%Lua.VM.AssertionError{}`
struct, and `.state` is the `Lua.VM.State.t()` snapshot taken at the exact VM
instruction that raised — the same struct field REQ-148 §5 found on the success
path, reached by a different accessor path because the value now lives one level
deeper (inside the wrapped exception, not the returned `Lua.t()`).

This is the same category of internal, undocumented field REQ-148 §5 already
flagged: no `Lua.VM.RuntimeError.instruction_count/1` function exists; this is a
struct field read, and a future `tv-labs/lua` upgrade that renames or removes
`Lua.VM.State`'s `:instruction_count` field, or stops populating `RuntimeError`'s
`:state` field at a raise site, breaks this silently unless guarded by a test. §7
requires such a regression test.

### 2.3 The narrower fallback — branch (b), retained for exception shapes with no state

Branch (a) is confirmed for the exception types this requirement's own division-by-zero
test exercises (`Lua.VM.RuntimeError`) and, by the same `defexception`/raise-site
pattern, for `Lua.VM.TypeError` and `Lua.VM.AssertionError`. It does **not**
generalize to every possible `Lua.RuntimeException.original` shape:

- `Lua.VM.InternalError` (`deps/lua/lib/lua/vm/internal_error.ex`: `defexception
  [:value]`) declares no `:state` field at all — structurally cannot carry one. This
  is the "library bug, not a Lua program error" path (`eval!/2`'s own rescue comment,
  line 559–561).
- `Lua.VM.ArgumentError` declares a `:state` field (confirmed by reading its
  `defexception` list), but this design did not find every one of its raise sites
  passing `state:` explicitly the way every `executor.ex` VM-opcode site does — so
  its presence is not assumed guaranteed the way it is for `RuntimeError`/`TypeError`/
  `AssertionError` raised from `Lua.VM.Executor`.
- An arbitrary Elixir exception reaching `eval!/2`'s catch-all `e ->` rescue clause
  (line 570–571) has no `:state` field, period — it is not a `Lua.VM.*` struct at all.

**Per-exception-instance rule (this is the precise form LUA-16's restatement takes,
sharper than its own binary "branch (a) or branch (b)" framing):** the SCRIPT_ERROR
builder inspects `exception.original` for a populated `%Lua.VM.State{}` in a `:state`
field. When present, it reports `{:consumed, state.instruction_count}` (branch (a)).
When absent — `.original` has no `:state` field, or the field is `nil` — it reports
`{:configured_budget, budget}` (branch (b)), where `budget` is the same
`:max_instructions` value `run_script/3` already threads through as its own `budget`
parameter. **Never a zero-filled `instruction_count: 0`, and never a silently-omitted
field** — the two-tag union (§3) makes the branch that fired part of the value's own
shape, not an implicit convention a caller has to know separately.

---

## 3. The `script_error()` shape

```
@type lua_frame :: %{source: String.t() | nil, line: pos_integer() | nil, name: String.t() | nil}

@type instruction_count_report :: {:consumed, non_neg_integer()} | {:configured_budget, pos_integer()}

@type script_error :: %{
        message: String.t(),
        stack_trace: [lua_frame()],
        instruction_count: instruction_count_report(),
        capabilities: [Letflow.Engine.Lua.Capabilities.capability()]
      }
```

Returned as `{:error, {:script_error, script_error()}}` from `run_script/3` (and
threaded unchanged through `handle_yield_result/3`'s existing pass-through clause for
`{:ok, {:error, reason}}` shapes — see §5 for why that clause needs no edit).

`lua_frame()` is not invented by this design — it is the exact map shape
`Lua.VM.ErrorFormatter.to_map/3` already documents and builds (`deps/lua/lib/lua/vm/error_formatter.ex`,
the `to_map/3` doc comment: `call_stack: [%{source: ..., line: ..., name: ...}]`),
reached via `Lua.RuntimeException.to_map/2`'s dispatch onto the wrapped exception's
own `to_map/2` (`RuntimeError.to_map/2`, `TypeError.to_map/2`, `AssertionError.to_map/2`
— `runtime_exception.ex` lines 143–151). §6 covers why this is also this design's
sanitization mechanism, not just its data source.

### 3.1 Field-by-field derivation

| Field | Source | Notes |
|---|---|---|
| `message` | Typed case: the wrapped exception's own `Exception.message/1` (via `Lua.RuntimeException`'s `message/1`, which prefixes `"Lua runtime error: "` and appends the `(at source:line)` suffix). Untyped/fallback case: a fixed placeholder string, never the raw exception message (§6.2) | Never the raw Elixir `inspect/1` of an arbitrary term |
| `stack_trace` | Typed case: `Lua.RuntimeException.to_map(exception).call_stack` (§6.1). Untyped/fallback case: `[]` | See §6 for the typed/untyped split |
| `instruction_count` | §2.3's per-instance rule | Two-tag union, never a bare integer, so "consumed" vs. "budget reported instead" is never ambiguous to a pattern match |
| `capabilities` | The `Capabilities.grant_set()` passed into the shaping function, rendered via `MapSet.to_list/1` | §4 — read from REQ-157's real type, not re-derived |

---

## 4. Capability state at failure — read from REQ-157's type, and the wiring gap this inherits

**"Capability state at failure" is not itself the property that raised the error —
it is the grant set the executing sandbox held for the whole run.** It must be read
from `Letflow.Engine.Lua.Capabilities`'s own `grant_set()` type (opaque `MapSet.t()`
per `capabilities.ex`), never reconstructed by walking Lua globals or re-deriving a
list independently.

### 4.1 The value threaded through

The SCRIPT_ERROR shaping function takes the `Capabilities.grant_set()` value as an
explicit parameter and renders it with `MapSet.to_list/1` into the `capabilities`
field. `run_script/3` is the caller that must supply this value — and, read directly,
`run_script/3` today constructs its sandbox via `Sandbox.new(max_instructions:
budget)` (`sandbox.ex` line 262–274), which unconditionally calls
`Letflow.Engine.Lua.Platform.install/1` — the one-argument overload documented in
`capabilities.ex` (lines 56–57) as passing `Letflow.Engine.Lua.Capabilities.new()`
(the **empty** grant set) — "for every production `Sandbox.new/0,1` VM until a future
requirement threads a real manifest's grants through." `platform.ex` itself names
this the same open gap at lines 103–105 (its own "OQ-1").

**This design does not close that gap.** Doing so would mean extending
`Sandbox.new/1`'s options to accept a grant set and changing its call to
`Platform.install/2` — a change to `sandbox.ex`'s own public contract that is outside
this requirement's `depends_on` (`[REQ-161, REQ-157]`, neither of which owns
`sandbox.ex`) and outside its stated scope (capturing SCRIPT_ERROR, not rewiring
capability provisioning). Per the same disclosure discipline
`req161-lua-platform-fail.md` §4/§8-OQ-2 already used for an analogous gap: this is
stated here as an inherited, pre-existing limitation, not silently patched over.

**Consequence, stated plainly:** `run_script/3`'s SCRIPT_ERROR builder is passed
`Letflow.Engine.Lua.Capabilities.new()` — literally the same empty-grant-set value
`Sandbox.new/1` already installs via `Platform.install/1` today, not a
freshly-constructed empty set that merely happens to look the same. The
`capabilities` field is therefore correctly *wired* to REQ-157's real type, but will
report `[]` for every SCRIPT_ERROR produced through the real
`execute_with_manifest/2,3` path today, until whichever future requirement threads
`manifest.capabilities` into `Sandbox.new/1`. Once that wiring lands, this design's
`capabilities` field starts reflecting real grants with zero further change to the
SCRIPT_ERROR shaping logic itself — only the value `run_script/3` passes in changes.

### 4.2 Proving AC6 despite the gap — testing at the layer that owns the property

Acceptance criterion 6 requires "a script granted exactly one capability produces an
event listing exactly that one." Since `execute_with_manifest/2,3`'s real sandbox is
hardwired to the empty grant set (§4.1), this cannot be proven by driving a script
through `execute_with_manifest/2,3` itself today. Mirroring
`req161-lua-platform-fail.md` §4's own precedent (proving a property "at the layer
that actually owns it" rather than through a layer that does not carry it end-to-end
yet): the test constructs a `Lua.t()` directly — `Lua.new/1` with the same
`:sandboxed` deny-set `Sandbox.deny_set/0` exposes, piped through
`Letflow.Engine.Lua.Platform.install/2` with an explicit non-empty
`Capabilities.new(["some:capability"])` grant set (bypassing `Sandbox.new/1`'s
hardcoded call to the 1-arity `install/1`) — runs a script that raises an uncaught
error against that state directly via `Lua.eval!/2`, and asserts the SCRIPT_ERROR
shaping function (called directly with the rescued exception and that same grant
set) produces a `capabilities` field of exactly `["some:capability"]`. This proves
the shaping function's correctness independent of the `Sandbox.new/1` wiring gap; it
does not — and does not claim to — prove that `execute_with_manifest/2,3` passes a
non-empty grant set today, because it does not.

---

## 5. Threading `{:script_error, _}` through `execute_with_manifest/2,3`

`run_script/3`'s new `{:error, {:script_error, script_error()}}` return value needs
no change to `handle_yield_result/3`'s existing clauses to survive: its generic
`{:ok, {:error, reason} = result} when is_binary(reason)` clause does **not** match
(the new reason is a 2-tuple, not a `binary()`), but this design adds one clause,
symmetric to the existing `{:budget_exceeded, _}` clause (lines 399–406), matching
`{:ok, {:error, {:script_error, _}} = result}` and returning `result` unchanged. The
raw-heap-limit path (`run_with_heap_limit/5`) needs no change at all: it calls
`run_script/3` directly and returns its result via `send/2` without going through
`handle_yield_result/3`, so `{:error, {:script_error, _}}` already passes through
that path unmodified today (read directly: `run_with_heap_limit/5`'s `receive` clause
for `{^reply_ref, result}` returns `result` verbatim, with no pattern restricting its
shape).

`execute_with_manifest/2,3`'s `@spec` return union gains one member:
`{:error, {:script_error, script_error()}}`.

---

## 6. Stack-trace sanitization mechanism (SECURITY-REVIEWER gate)

The mechanism is: **never surface an Elixir-level stacktrace (`__STACKTRACE__`,
`Exception.format/3`, `Process.info(pid, :current_stacktrace)`) in `stack_trace` at
all.** The field's only source is the Lua-level `call_stack` the vendored library
itself already builds for exactly this purpose, and only for the subset of exception
shapes it can build cleanly.

### 6.1 Typed case — the library's own clean structured render

When `exception.original` is a `%Lua.VM.RuntimeError{}`, `%Lua.VM.TypeError{}`, or
`%Lua.VM.AssertionError{}` (the shapes this design's §2 confirmed reliably carry
`:state`, and the shapes `Lua.RuntimeException.to_map/2` has a dedicated clause for —
`runtime_exception.ex` lines 143–147), `stack_trace` is `Lua.RuntimeException.to_map(exception).call_stack`
— per `error_formatter.ex`'s own documented shape, a list of
`%{source: String.t() | nil, line: pos_integer() | nil, name: String.t() | nil}`
maps. `build_call_stack/1` (the function that produces this list) has no code path
that can embed an Elixir module atom, a BEAM stacktrace frame, or a host filesystem
path: `source` is the Lua chunk's `:source` name — a host-chosen label
(`run_script/3`'s call to `Lua.eval!(lua, script_source)` passes no `:source` option,
so it defaults to the literal string `"<eval>"`, never a real file path, per
`eval!/2`'s own documented default) — and `name`/`line` are Lua-level function name
and line number, sourced from the VM's own call-frame bookkeeping, not from any
Elixir compilation artifact. This is a structural guarantee, not a best-effort
filter: the shape of `build_call_stack/1`'s output cannot contain what it never
reads.

### 6.2 Untyped/fallback case — a fixed placeholder, not a scrubbed passthrough

When `exception.original` is anything else (`Lua.VM.InternalError`, an arbitrary
Elixir exception reaching `eval!/2`'s catch-all clause), `Lua.RuntimeException.to_map/2`
falls back to `minimal_map/1` (`runtime_exception.ex` lines 151, 160–171), whose
`message` field delegates to `Exception.message/1` on the wrapped exception — for an
arbitrary Elixir exception (e.g. a `FunctionClauseError` surfacing from a library
bug), that message can legitimately embed argument dumps, module names, or other
Elixir-internal detail never meant for a script author. Rather than attempt a
regex-based scrub of an open-ended message format (fragile — a future Elixir/library
version can change message wording and reopen the leak silently), this design
specifies a **fixed, non-leaking placeholder** for this branch: `message` becomes a
constant string (e.g. `"internal script execution error"` — exact wording is an
implementation choice, not load-bearing for this design) and `stack_trace` becomes
`[]`, unconditionally discarding the original message and any stacktrace rather than
passing any part of it through. This is the same posture `eval!/2`'s own rescue
comment already takes toward this exception class ("library bug, not a Lua program
error").

### 6.3 Test obligation

A SECURITY-REVIEWER-verifiable test must assert, for the typed case (the
division-by-zero scenario, §8), that no `stack_trace` frame's `source`/`name` fields
contain a `/` path separator or an `Elixir.` prefix — both structurally impossible
per §6.1's argument, but asserted anyway so a future library change that starts
populating `source` from a real file path is caught by a failing test rather than by
inspection alone.

---

## 7. Regression test for the internal `instruction_count` field (mirrors REQ-148 §5's own warning)

REQ-148 §5 states explicitly: "S5 requirements that read it must document the
mechanism explicitly and include a regression test so a future library upgrade that
removes or renames the field fails loudly." This design's own §2.2 mechanism
(`exception.original.state.instruction_count`) reaches one level deeper than the
spike's own success-path read, so the same obligation applies with the same
sharpness: a dedicated test asserts, independent of the division-by-zero scenario,
that raising *any* uncaught `Lua.RuntimeException` from inside a Lua-level VM opcode
(not a host function) produces an `.original` struct exposing a `:state` field whose
value is a `%Lua.VM.State{}` struct carrying a non-negative `:instruction_count`. If
a future `tv-labs/lua` upgrade removes or renames either field, this test fails with
a `KeyError`/`FunctionClauseError` at the exact point of loss, rather than the
SCRIPT_ERROR silently reporting `{:configured_budget, budget}` (branch (b)) for every
error from then on with no visible signal that branch (a) quietly stopped firing.

---

## 8. Division-by-zero substitution — which form actually raises in Lua 5.3

LUA-16's literal acceptance text — "Division by zero in script yields rich error
report" — is a Lua 5.1 assumption. Confirmed by reading
`deps/lua/lib/lua/vm/executor.ex` directly (§2.1): in this runtime (Lua 5.3, per
REQ-148 spike §7), `1/0` (the `/` float-division operator) raises nothing — it
evaluates to `inf`, matching Lua 5.3 §3.4.1 semantics and the spike's own `3/2 ==
1.5` finding. Only the **integer** floor-division and modulo operators raise:

- `1//0` raises `Lua.RuntimeException` wrapping `%Lua.VM.RuntimeError{value: "attempt
  to divide by zero"}` — `executor.ex` line 3789.
- `1%0` raises `Lua.RuntimeException` wrapping `%Lua.VM.RuntimeError{value: "attempt
  to perform 'n%0'"}` — `executor.ex` line 3816.

**This design substitutes `1//0`** as the test standing in for LUA-16's "division by
zero" acceptance criterion: its raised message text ("attempt to divide by zero")
is the closer literal match to the requirement's own wording, whereas `1%0`'s message
("attempt to perform 'n%0'") reads as a modulo failure, not a division one, even
though both are integer-only, zero-divisor arithmetic errors in this runtime. Both
forms only raise when **both** operands are integers — `1//0.0` yields `inf` without
raising (confirmed by REQ-148 spike's citation of the same `lvm.c` semantics this
design independently re-confirmed against the vendored Elixir port). The moduledoc
(§9) records this substitution and why the literal 5.1-era criterion does not fire as
written.

---

## 9. Distinguishing SCRIPT_ERROR from the 4 other real arms

Read directly in `executor.ex` (current state, before this requirement's edit):

| Arm | Tag/shape | Produced where | Process state when observed |
|---|---|---|---|
| REQ-161 `SCRIPT_FAILED` | `{:script_failed, %{reason: String.t(), details: term()}}` | `platform.ex`'s `do_fail/1`, via `exit/1` — never reaches `run_script/3`'s `rescue` at all | Process is dead — observed via `Task.yield/2`'s `{:exit, reason}` clause or a `:DOWN` message (req161-lua-platform-fail.md §3.3, §4) |
| REQ-154 budget-exceeded | `{:error, {:budget_exceeded, pos_integer()}}` | `run_script/3`'s `rescue e in Lua.RuntimeException`, string-matched branch (unchanged by this design) | Process alive, normal `{:error, _}` return |
| REQ-155 wall-clock timeout | `{:error, {:wallclock_timeout, pos_integer()}}` | `handle_yield_result/3`'s `nil` clause, or `run_with_heap_limit/5`'s `after` clause — never inside `run_script/3` | Process killed by the caller after its own bounded wait expired |
| REQ-156 memory limit | `{:error, :memory_limit_exceeded}` | `run_with_heap_limit/5`'s `:DOWN`-with-`:killed`-observed-early clause — never inside `run_script/3` | Process killed by the BEAM's own `max_heap_size` enforcement |
| REQ-162 `SCRIPT_ERROR` (this design) | `{:error, {:script_error, script_error()}}` | `run_script/3`'s `rescue e in Lua.RuntimeException`, else-branch (§1.1) | Process alive, normal `{:error, _}` return |

Pattern-match distinguishability, five arms in one `case`/`cond`:

1. `{:script_failed, _}` vs. everything else: different top-level shape entirely (an
   `exit` reason vs. an `{:error, _}` return) — already established as disjoint by
   req161 §3.3; this design does not touch or reuse the `:script_failed` tag.
2. `{:error, {:budget_exceeded, pos_integer()}}` vs. `{:error, {:script_error, map()}}`:
   different tag atom heading the inner tuple, and the string-match branch that
   produces `:budget_exceeded` runs strictly before the `:script_error` branch inside
   the same `rescue` clause, so a real budget-exceeded error is structurally
   incapable of also matching the `:script_error` branch.
3. `{:error, {:wallclock_timeout, pos_integer()}}` vs. `{:error, {:script_error,
   map()}}`: different tag atom, and produced by entirely disjoint code (task-level
   `Task.yield`/`after` handling vs. `run_script/3`'s in-process `rescue`) — the two
   can never even race to produce the same value for the same failure.
4. `:memory_limit_exceeded` (bare atom) vs. `{:script_error, map()}`: different Elixir
   term shape outright (atom vs. 2-tuple) — trivially distinct by `is_atom/1` alone,
   let alone pattern match.

---

## 10. Cross-module dependencies

| Module | Direction | Nature of dependency |
|---|---|---|
| `Letflow.Engine.Lua.Executor` (`run_script/3`, `handle_yield_result/3`) | owns the new `{:script_error, _}` construction and pass-through | This design's only edited production module |
| `Lua.RuntimeException`, `Lua.VM.RuntimeError`/`TypeError`/`AssertionError`/`InternalError` (`deps/lua`) | → read, not modified | Source of `.original`, `:state`, `to_map/2`'s `call_stack` (§2, §6) |
| `Letflow.Engine.Lua.Capabilities` (`grant_set()`, `new/0,1`) | → read, not modified | Source of the `capabilities` field's type and the empty-set value `run_script/3` passes today (§4) |
| `Letflow.Engine.Lua.Sandbox` (`new/1`, `deny_set/0`) | → read, cited, not modified | §4.2's test constructs an equivalent `Lua.t()` directly rather than through `Sandbox.new/1`, to bypass its hardcoded empty grant set |
| `lib/letflow/design/req148-lua-runtime-spike.md` §5 | → cited, not re-derived | Success-path `instruction_count` finding this design builds on and diverges from (§2) |
| `lib/letflow/design/req161-lua-platform-fail.md` §3.3, §4 | → cited, not re-derived | `:script_failed` tag reservation; the stringification-gap disclosure pattern this design mirrors for its own §4.1 gap |

---

## 11. Open questions

**OQ-1 (inherited, not created by this requirement — §4.1).** `Sandbox.new/1` always
installs the empty `Capabilities.new()` grant set; no wiring path threads
`manifest.capabilities` into it. This design's `capabilities` field is correctly
wired to REQ-157's type but will report `[]` for every SCRIPT_ERROR produced via the
real `execute_with_manifest/2,3` path until a future requirement closes this —
`platform.ex`'s own moduledoc already names the same gap.

**OQ-2 (branch (b)'s practical frequency).** §2.3's per-instance fallback is
confirmed reachable for `Lua.VM.InternalError` (library-bug path) and unconfirmed
(neither proven present nor proven absent at every raise site) for
`Lua.VM.ArgumentError`. Whether any `ArgumentError` raise site in `deps/lua` omits
`state:` in practice is not exhaustively enumerated here — every `Lua.VM.Executor`
raise site this design read (the ones LUA-16's own division-by-zero scenario and the
general script-runtime-error case exercise) does pass `state:`. If a future test
finds an `ArgumentError` path without `:state`, branch (b) already covers it by
construction; no design change would be needed.

**OQ-3 (placeholder message wording, §6.2).** The exact constant string used for the
untyped/fallback case's `message` field is left as an implementation choice for
ELIXIR-DEV — not load-bearing for any acceptance criterion, since no criterion
inspects that string's exact content, only that it does not leak Elixir/host detail.

---

## 12. Traceability — REQ-162's 8 acceptance criteria (`docs/requirements.yaml`)

| # | Acceptance criterion (verbatim/paraphrased) | Design element |
|---|---|---|
| 1 | A test asserts an uncaught runtime error produces a structured SCRIPT_ERROR carrying a stack trace and capability state at failure, both asserted individually | §3 (`script_error()` shape), §6.1 (stack trace), §4 (capabilities field) |
| 2 | Moduledoc states which restatement branch holds, naming the mechanism and citing REQ-148 by section, or naming what is reported instead | §2.2 (branch (a) confirmed, mechanism named), §2.3 (per-instance branch (b) fallback), §9 item 2 of the moduledoc content this design specifies |
| 3 | If not retrievable, a test asserts the event does NOT carry a zero/omitted-but-implied-present field; absent or explicitly budget-labelled instead | §2.3, §3 (`instruction_count_report()` two-tag union — structurally cannot be a bare zero) |
| 4 | The division-by-zero test uses a form that actually raises in Lua 5.3, with the moduledoc recording the substitution and why | §8 (`1//0` selected, `1%0` also raises but rejected as the less literal match; `1/0` confirmed non-raising) |
| 5 | A test asserts SCRIPT_ERROR is pattern-match-distinguishable from all 4 other arms in one test | §9 (full comparison table and per-pair pattern-match argument) |
| 6 | Capability state is read from REQ-157's capability set, not re-derived; a script granted exactly one capability produces an event listing exactly that one | §4 (grant_set threaded, not reconstructed), §4.2 (test proves this at the layer that owns it, given the inherited OQ-1 wiring gap) |
| 7 | A test asserts the stack trace does not include host filesystem paths or Elixir module internals | §6 (typed-case structural guarantee, untyped-case fixed placeholder), §6.3 (test obligation) |
| 8 | `mix test` and `mix compile --warnings-as-errors` both pass with real output quoted | Not a design-time artifact — ELIXIR-DEV/TEST-RUNNER responsibility at Steps 2/4, same convention as REQ-159/160/161's own final traceability row |

---

## 13. Moduledoc content this design specifies

`executor.ex`'s existing moduledoc gains a new `## REQ-162` section, positioned after
the existing `## REQ-156` section, covering:

1. States this requirement restates LUA-16, quoting its literal text, and states the
   division-by-zero acceptance criterion is a Lua 5.1 assumption that does not fire
   as written in this runtime (§8), naming the substituted form and why.
2. States explicitly that branch (a) of LUA-16's restatement holds (instruction count
   retrievable), names the exact mechanism
   (`exception.original.state.instruction_count`), cites REQ-148 §5/OQ-2(c) by
   section for the success-path finding this diverges from, and states the narrower
   branch-(b) fallback (§2.3) is retained for exception shapes without a populated
   `:state`.
3. States the SCRIPT_ERROR/SCRIPT_FAILED/budget/timeout/memory-limit five-arm
   distinction (§9), citing `req161-lua-platform-fail.md` §3.3 for the
   `:script_failed` tag reservation this design does not reuse.
4. States the inherited capability-wiring gap (§4.1, OQ-1) plainly — that
   `capabilities` in a production SCRIPT_ERROR is `[]` today, and why, mirroring
   `req161-lua-platform-fail.md` §4's own disclosure convention.
5. States the stack-trace sanitization mechanism (§6) and the regression-test
   obligation for the internal `instruction_count` field (§7), so a future reader
   understands why both are structural guarantees rather than best-effort filters.
