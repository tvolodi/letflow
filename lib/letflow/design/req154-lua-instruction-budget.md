# REQ-154 Design: In-Band Instruction Budget for Lua Script Execution (LUA-08, Layer 1)

**Requirement:** REQ-154 — In-band instruction budget (LUA-08 restated, layer 1 of 2)  
**Stage:** S5 (Scripting & plugins)  
**Related:** REQ-155 (mandatory layer 2), REQ-153 (executor base), REQ-148 (spike), ISS-0350  
**Also in scope:** ISS-0350 — restore `is_binary` guard and `@impl` removed by unreviewed human commit

**Acceptance criteria mapped in §8 below.**

---

## 1. LUA-08 Layer-1 Restatement — Why This Requirement Exists

This requirement **restates LUA-08 as layer 1 of a two-layer pair**. It does NOT satisfy
LUA-08's literal text on its own.

LUA-08 literal: *"Exceeding the limit MUST terminate the script with a structured timeout
error."* LUA-08 acceptance: *"Infinite loop terminates within configured limit."*

**Why `:max_instructions` alone does not satisfy these words:**

`:max_instructions` is an in-band, pcall-catchable budget. When the budget is hit, the
`tv-labs/lua` library raises a Lua runtime error with the message
`"instruction budget exceeded"`. A Lua script may wrap its own loop in `pcall` and
intercept that error:

```
-- a script can do this
local ok, err = pcall(function() while true do end end)
-- ok == false, err == "instruction budget exceeded"
-- script continues running here
```

REQ-148 spike answer OQ-2(a) (see `lib/letflow/design/req148-lua-runtime-spike.md` §3)
confirms: `pcall` returns `[false, "instruction budget exceeded"]`, the inner loop stops,
and `Lua.eval!/2` returns normally. There is no continuation hazard. However, the script
DOES receive control back after `pcall` — a sufficiently hostile script can detect the
budget and act.  LUA-08's literal ("MUST terminate") is therefore not met: a script that
pcalls its exhaustion is not terminated; the outer Elixir process is never involved.

**Layer 2 (REQ-155)** supplies the mandatory host-enforced, non-catchable kill via
`Process.exit/2` on a monitored Task. LUA-08 must not be reported done until REQ-155
has also landed.

---

## 2. What R-Co Had, and Why It Does Not Port

PROVENANCE (historical, not current decision authority):
R-Co's `src/lua/instruction_limiter.zig` (126 lines) built two invariants this codebase
does not have and must not look for:

**INV-2 (registry-stored limiter):** The limiter pointer was stored in
`LUA_REGISTRYINDEX` rather than as a Lua global (`_G.__limiter__`), because a script
could write `_G.__limiter__ = nil` and defeat the counter entirely. There is no
`LUA_REGISTRYINDEX` here. The `tv-labs/lua` library takes `:max_instructions` as an
option to `Lua.new/1` — it is wired into the VM at construction time and not reachable
from Lua script globals. **INV-2 does not port because the threat it guarded against
does not exist in this runtime.**

**INV-4 (one combined `LUA_MASKCOUNT` hook):** R-Co used a single `LUA_MASKCOUNT`
debug hook to carry both the instruction-count check and the elapsed-time check,
because that hook was the only Lua C API mechanism that could interrupt a tight
`while true do end` loop. **INV-4 does not port because this runtime has no hook API
and needs none for the tight-loop interruption problem.** The `tv-labs/lua` library
enforces `:max_instructions` via its own internal VM counter. The tight-loop
interruption that INV-4 existed to solve is REQ-155's problem, solved by preemptive
BEAM scheduling: a Task running a tight Lua loop is scheduled like any other BEAM
process and can be killed with `Process.exit/2` from outside.

**No future reader should look for a hook that was correctly never written.**

---

## 3. Module Location and Ownership

**Primary file:** `lib/letflow/engine/lua/executor.ex`  
(`Letflow.Engine.Lua.Executor` — unchanged from REQ-153)

This design extends REQ-153's module in place. No new module or file is added for the
budget feature.

---

## 4. Public Function Signatures

### 4.1 `execute_with_manifest/2` (behaviour callback, unchanged arity)

```
@impl Letflow.Engine.LuaScriptAudit.Executor
@spec execute_with_manifest(script_source :: binary(), registered_hash :: String.t()) ::
        {:ok, %{manifest_hash: String.t()}}
        | {:error, {:budget_exceeded, limit :: pos_integer()}}
        | {:error, String.t()}
        | {:error, :invalid_script_ref}
```

**Guard:** `when is_binary(script_source)` — restored per ISS-0350 (see §7).

This callback satisfies the `@behaviour Letflow.Engine.LuaScriptAudit.Executor` contract
by delegating to `execute_with_manifest/3` with the Application-configured budget as the
default. It is the path called by `LuaScriptAudit.execute_script_for_audit/6`.

### 4.2 `execute_with_manifest/3` (new overload, not on the behaviour)

```
@spec execute_with_manifest(
        script_source :: binary(),
        registered_hash :: String.t(),
        opts :: keyword()
      ) ::
        {:ok, %{manifest_hash: String.t()}}
        | {:error, {:budget_exceeded, limit :: pos_integer()}}
        | {:error, String.t()}
        | {:error, :invalid_script_ref}
```

**Guard:** `when is_binary(script_source)`

`opts` keys:
| Key | Type | Description |
|---|---|---|
| `:max_instructions` | `pos_integer()` | Instruction budget. **Required** (no sensible default in opts; the 2-arity callback reads it from Application config). |

**Reasoning for a 3-arity overload (not a module-config-only approach):**

The behaviour's arity is fixed at `/2`. The budget must be settable per call-site for
tests (AC-1 requires two different budgets in the same test run; using
`Application.put_env` in tests is fragile and introduces test-order dependencies).
Adding `/3` keeps the budget explicit at test call sites, keeps `/2` clean for the
production (behaviour-based) path, and follows the `Sandbox.new/0` → `Sandbox.new/1`
precedent already established in REQ-151 for the same "extend later" pattern.

### 4.3 `default_budget/0` (private helper, not public API)

```
@spec default_budget() :: pos_integer()
defp default_budget()
```

Reads `Application.fetch_env!(:letflow, :lua_max_instructions)`. Called by the
2-arity callback before delegating to `/3`. ELIXIR-DEV must add
`config :letflow, lua_max_instructions: <N>` to `config/config.exs` (or
`config/test.exs` for tests) and ensure the value is a positive integer.

The key `:lua_max_instructions` is the single authoritative name for the budget across
the entire application. ELIXIR-DEV must not hardcode a literal — the configurable-budget
acceptance criterion (AC-1) is violated by any compile-time constant used directly in
the implementation.

---

## 5. Budget Exhaustion Error Shape

**Chosen form:** `{:error, {:budget_exceeded, limit :: pos_integer()}}`

**Justification:**

Three existing error arms must remain distinguishable by pattern match:

| Error | Pattern | Origin |
|---|---|---|
| Runtime Lua error | `{:error, message}` where `message :: String.t()` | `Lua.RuntimeException` (non-budget) |
| Non-binary script ref | `{:error, :invalid_script_ref}` | `FunctionClauseError` from guard |
| Budget exhaustion | `{:error, {:budget_exceeded, limit}}` | `Lua.RuntimeException` with message `"instruction budget exceeded"` |

The tuple `{:budget_exceeded, limit}` is distinct from a bare atom and from a string:
`{:error, {:budget_exceeded, 1000}}` cannot be confused with `{:error, "some message"}`
or `{:error, :invalid_script_ref}` by any pattern match. Carrying `limit` (the
configured value at the time of exhaustion) makes REQ-162's SCRIPT_ERROR event
self-describing without a separate lookup.

**Detection mechanism:** ELIXIR-DEV rescues `Lua.RuntimeException` and checks whether
`Exception.message(e)` equals `"instruction budget exceeded"` (the exact string
confirmed by the REQ-148 spike). When it matches, return
`{:error, {:budget_exceeded, limit}}` where `limit` is the opts/config value used for
that call. When it does not match, return `{:error, Exception.message(e)}` (unchanged
REQ-153 behavior for all other runtime errors).

---

## 6. Budget Threading via `Sandbox.new/1`

`Sandbox.new/1` already exists (REQ-151 design anticipated REQ-154..156 by adding the
opts parameter). Its current implementation ignores opts (`def new(_opts)`). **ELIXIR-DEV
must update `Sandbox.new/1`** to pass `:max_instructions` from opts to `Lua.new/1`
if present. The exact mechanism: merge the value into the opts passed to `Lua.new/1`
alongside the deny-set.

The executor calls `Sandbox.new(max_instructions: budget)` (passing opts). This keeps
INV-SBX-1 intact: `Lua.new/1` is never called directly from `executor.ex`.

The sandbox update is a dependency of REQ-154's implementation but is in
`lib/letflow/engine/lua/sandbox.ex` — not in the executor's owned_modules list. ELIXIR-DEV
must also modify `sandbox.ex` as part of the same commit, under the same lock (both files
are in the S5 Lua engine namespace, no separate handoff is needed since this is a
mechanical extension of an explicitly anticipated interface).

---

## 7. ISS-0350 Fix — `is_binary` Guard and `@impl` Restoration

An unreviewed human commit removed both from `execute_with_manifest/2`. This design
restores them as part of REQ-154, per ORCH's explicit authorization.

**What is restored:**

1. **`@impl Letflow.Engine.LuaScriptAudit.Executor`** — present on both the 2-arity
   callback. The 3-arity overload is NOT on the behaviour and must NOT carry `@impl`.

2. **`is_binary(script_source)` guard** — present on both the 2-arity and 3-arity
   clauses. This guard is what causes `FunctionClauseError` when a non-binary is passed,
   which the rescue clause converts to `{:error, :invalid_script_ref}`.

**Why the guard matters (ISS-0350 context):** Without the guard, the
`rescue _e in FunctionClauseError -> {:error, :invalid_script_ref}` arm is dead code.
`execute_with_manifest/2` silently passes any term to `Lua.eval!/2`, whose behavior on
a non-binary is undefined at the boundary. This is a type-safety regression on a
tenant-supplied input path.

**`@impl` note:** The removed commit's justification ("@impl+guard breaks
`function_exported?` on Linux CI") is not a real Elixir/Erlang mechanism.
`function_exported?/3` checks the module's export table; it is unaffected by a clause
guard or `@impl`. The underlying intermittent `function_exported?` false-negative is a
separate transient test-order effect (noted in ISS-0350) unrelated to this guard.

---

## 8. Acceptance Criterion Mapping

| AC | Concrete design element |
|---|---|
| **AC-1** — budget configurable, test drives two different budgets | `execute_with_manifest/3` accepts `:max_instructions` opt; test calls it twice with different values (e.g. 500 and 5000) and asserts the 500-instruction run exhausts sooner |
| **AC-2** — `while true do end` under budget terminates rather than hangs | `execute_with_manifest/3` with `:max_instructions` set; test asserts `{:error, {:budget_exceeded, limit}}` is returned rather than the call blocking |
| **AC-3** — budget exhaustion surfaces as structured error distinguishable by pattern match | `{:error, {:budget_exceeded, limit :: pos_integer()}}` — not matchable by `{:error, msg}` (string) or `{:error, :invalid_script_ref}` |
| **AC-4** — test asserts pcall-of-budget behavior per REQ-148 spike answer (a) | Test runs a script containing `pcall(function() while true do end end)` under a budget; asserts `{:ok, %{manifest_hash: _}}` (script completes normally, pcall caught the exhaustion, no continuation hazard). The test documents this as expected layer-1 behavior |
| **AC-5** — moduledoc: LUA-08 layer-1 restatement, `:max_instructions` pcall-catchable, REQ-155 mandatory | Moduledoc (§5 above) states this explicitly |
| **AC-6** — moduledoc: INV-2/INV-4 non-port explanation | Moduledoc (§2 above) explains why neither invariant ports and that no hook was intentionally never written |
| **AC-7** — `mix test` and `mix compile --warnings-as-errors` pass | TEST-RUNNER step produces real output; design does not constrain this outcome but all signatures must compile cleanly |
| **ISS-0350** — `is_binary` guard + `@impl` restored | §7 above; 2-arity clause has `@impl` and `when is_binary` guard; 3-arity clause has `when is_binary` guard only |

---

## 9. Invariants

| Invariant | This module's role |
|---|---|
| INV-SBX-1 — only `Sandbox.new/0|1` calls `Lua.new/1` | Maintained: executor calls `Sandbox.new([max_instructions: budget])`, never `Lua.new/1` directly |
| INV-SBX-4 — sandbox construction never fails | Maintained: `Sandbox.new/1` returns `Lua.t()` unconditionally |
| Per-invocation isolation (LUA-EC-1) | Maintained: fresh `Sandbox.new/1` call on every `execute_with_manifest` invocation |
| Budget non-catchability (layer 1 only) | NOT an invariant of this layer. Layer 1 explicitly allows pcall interception; layer 2 (REQ-155) provides the non-catchable kill |
| `is_binary` guard on tenant input path | Restored by ISS-0350 fix in this requirement |

---

## 10. Cross-Module Dependencies

| Module | Change required in REQ-154 |
|---|---|
| `Letflow.Engine.Lua.Sandbox` | `new/1` must pass `:max_instructions` from opts to `Lua.new/1` (currently ignores opts) |
| `Lua` (tv-labs/lua) | No change — `:max_instructions` is already a `Lua.new/1` option per REQ-148 spike |
| `Application` | Reads `:letflow, :lua_max_instructions` for the 2-arity path |
| `Letflow.Engine.LuaScriptAudit.Executor` (behaviour) | No change to behaviour definition — `execute_with_manifest/2` arity unchanged |
| `:crypto` / `Base` | Unchanged from REQ-153 |

---

## 11. Application Config Schema

```
# config/config.exs (or runtime.exs for runtime-configurable)
config :letflow, lua_max_instructions: 100_000
```

The key is `:lua_max_instructions` (atom), the value is a `pos_integer()`. The exact
default value is ELIXIR-DEV's choice; it must be documented in the config file comment.
Tests that need a specific value call `execute_with_manifest/3` directly with `:max_instructions`
in opts — they do NOT need `Application.put_env`.

---

## 12. Moduledoc Content Outline (for `executor.ex`)

The updated `@moduledoc` for `Letflow.Engine.Lua.Executor` must include:

1. REQ-153 baseline attribution (unchanged from current).
2. **LUA-08 layer-1 restatement section:**
   - This requirement RESTATES LUA-08 as layer 1 of a two-layer pair.
   - `:max_instructions` is in-band and pcall-catchable. LUA-08's literal text is NOT
     met by this requirement alone.
   - REQ-155 supplies the mandatory host-enforced layer 2; LUA-08 is not done until
     REQ-155 lands.
3. **R-Co non-port section:**
   - INV-2 (registry-stored limiter pointer in `LUA_REGISTRYINDEX`) does not port — no
     such registry exists; the budget is a `Lua.new/1` option, not a Lua-visible global.
   - INV-4 (one combined `LUA_MASKCOUNT` hook) does not port — there is no hook API;
     tight-loop interruption is REQ-155's problem, solved by BEAM preemptive scheduling.
   - No future reader should look for a hook that was correctly never written.
4. **ISS-0350 note:** `is_binary(script_source)` guard and `@impl` were removed by an
   unreviewed commit and are restored here.

---

## 13. Open Questions

| ID | Question | Blocks |
|---|---|---|
| OQ-1 | `Sandbox.new/1` currently ignores its opts parameter. ELIXIR-DEV must wire `:max_instructions` into `Lua.new/1` inside `Sandbox.new/1`. If the sandbox has other opts in a future requirement, a merge strategy is needed. For now, pass-through of `:max_instructions` is the only required key. | REQ-154 implementation |
| OQ-2 | The exact value for the production default `lua_max_instructions` in config (100_000 here is illustrative). ELIXIR-DEV should pick a value consistent with expected Letflow flow-step workloads and document it in the config comment. | REQ-154 implementation |
| OQ-3 | If `Lua.RuntimeException.message/1` ever changes its message string from `"instruction budget exceeded"`, the detection logic silently falls through to the generic `{:error, String.t()}` arm. ELIXIR-DEV must add a regression test that directly confirms the string literal matches. This is already recommended by the spike's OQ-2(c) note on internal struct fields, applied here to string messages. | REQ-154 test design |
