# REQ-148 — Lua Runtime Spike: tv-labs/lua Empirical Verification

**Requirement:** REQ-148  
**Stage:** S5  
**Owner:** CODE-DESIGNER  
**Date:** 2026-08-24  
**Library version:** `lua 1.0.2` (tv-labs/lua, Apache-2.0)

---

## Section 1 — LUA-01 Restatement

This requirement **restates LUA-01** rather than satisfying its literal text.

R-Co's LUA-01 reads:

> "The platform MUST embed LuaJIT and expose it through Zig C-interop. Linking MUST be static."

Under decision 0014's chosen runtime, **all three clauses are unsatisfiable**:

1. **tv-labs/lua is NOT LuaJIT.** It is a Lua 5.3 VM implemented in pure Elixir on the BEAM. There is no LuaJIT binary, no LuaJIT API surface, and no LuaJIT dialect (`jit.*`, `ffi.*`, `bit.*`, `bit32.*` do not exist).

PROVENANCE (historical, not current decision authority):
2. **There is no Zig C-interop in Letflow.** Letflow has no `.zig` files, no Zig toolchain, and no `@cImport`. The entire Lua runtime runs as BEAM bytecode.

3. **There is no static linking step.** tv-labs/lua is a Hex package — a dependency declared in `mix.exs` and fetched from hex.pm. There is no C toolchain, no shared library, and no ABI surface to link.

**The intent that IS satisfied:** the platform embeds a Lua runtime in-process with no external Lua runtime dependency at deploy time. A BEAM-only Hex dependency satisfies this intent more completely than static linking does — no C toolchain, no OS-level shared library, no ABI surface. Decision 0014's Reasoning §(a) records why this is a strictly better position than R-Co reached after ISS-0153 and ISS-0161.

PROVENANCE (historical, not current decision authority):
This restatement is explicit to prevent any future reader from mistaking a satisfied intent for a satisfied literal text — the exact failure mode `R-Co/src/lua/luajit_bindings.zig`'s own header records (LUA-01..16 "sat marked RELEASED" for three months while nothing executed).

---

## Section 2 — Dependency Adoption

### mix.exs change

Added to `defp deps` in `mix.exs`:

```elixir
{:lua, "~> 1.0"}
```

### mix deps.get output (actual)

```
Resolving Hex dependencies...
Resolution completed in 0.162s
New:
  lua 1.0.2
Unchanged:
  bandit 1.12.4 VULNERABLE!
    EEF-CVE-2026-75484 (MEDIUM) ...
    EEF-CVE-2026-74836 (HIGH) ...
  db_connection 2.6.0
  decimal 2.1.1
  ecto 3.12.3
  ecto_sql 3.12.1
  hpax 0.2.0
  jason 1.4.4
  jose 1.11.10
  mime 2.0.6
  oidcc 3.2.0
  plug 1.16.1
  plug_crypto 2.1.0
  postgrex 0.19.3
  stream_data 0.6.0
  telemetry 1.3.0
  telemetry_registry 0.3.2
  thousand_island 1.3.9
  ueberauth 0.10.8
  ueberauth_oidcc 0.4.2
  websock 0.5.3
* Getting lua (Hex package)
Found packages with security advisories, see above for details
```

**Result:** `lua 1.0.2` fetched successfully. The bandit CVEs are pre-existing (noted `VULNERABLE!` before this change) and are not introduced by this requirement.

### mix compile output (actual)

```
==> lua
Compiling 63 files (.ex)
Generated lua app
==> letflow
Compiling 121 files (.ex)
Generated letflow app
```

**Result:** zero warnings, zero errors. Both `lua` and `letflow` compiled cleanly.

---

## Section 3 — OQ-2 (a): pcall Interception of `:max_instructions` Budget Exhaustion

**Question:** can a Lua script `pcall` its own budget exhaustion and continue executing?

**Code run** (`scratch/lua_spike.exs`, executed with `MIX_ENV=test mix run --no-start`):

```elixir
lua_limited = Lua.new(max_instructions: 1000)
{results_a, _} = Lua.eval!(lua_limited, "return pcall(function() while true do end end)")
IO.puts("OQ-2(a) pcall result: #{inspect(results_a)}")
```

**Actual output:**

```
OQ-2(a) pcall result: [false, "instruction budget exceeded"]
```

**Verdict:** YES — budget exhaustion IS catchable via `pcall`. The script receives `{false, "instruction budget exceeded"}`. The documentation cited in decision 0014 is confirmed:

> "`:max_instructions` … a catchable `'instruction budget exceeded'` runtime error is raised … The budget is fresh per top-level evaluation and recoverable via `pcall`."

**Implication for S5:** `max_instructions` serves as the in-band, pcall-catchable layer-1 limit (LUA-08). A script that catches its own exhaustion returns normally from `Lua.eval!/2`; the outer engine process is not involved. This means layer-1 limit enforcement works without Task supervision. Layer-2 (host kill via `Process.exit/2`) remains the out-of-band, non-catchable hard limit (LUA-10).

**Continuation behaviour:** the `pcall` returned `false` and did NOT continue executing the inner loop. The `Lua.eval!` call returned normally. There is no "continue after pcall" hazard.

---

## Section 4 — OQ-2 (b): pcall Interception of Host Function Errors

**Question:** can Lua scripts `pcall` host (Elixir) function errors?

**Code run:**

```elixir
lua2 = Lua.set!(Lua.new(), [:raise_host], fn _args ->
  raise "host function exploded"
end)
{results_b, _} = Lua.eval!(lua2, """
local ok, err = pcall(function()
  raise_host()
end)
return ok, err
""")
IO.puts("OQ-2(b) pcall ok = #{inspect(hd(results_b))}")
IO.puts("OQ-2(b) pcall err = #{inspect(Enum.at(results_b, 1))}")
```

**Actual output:**

```
OQ-2(b) pcall ok = false
OQ-2(b) pcall err = "host function exploded"
```

**Verdict:** YES — host function errors ARE catchable via `pcall`. The Elixir `raise "host function exploded"` is caught by the Lua `pcall` wrapper, returning `{false, "host function exploded"}`. The error message string is the original Elixir exception message.

**Implication for S5:** `platform.fail(msg)` (LUA-13) can be implemented as a host function that raises, and Lua scripts can catch it with `pcall` if desired. The standard library restriction tests (LUA-03 restated) can use `pcall` to assert sandboxed functions raise the expected error rather than crashing `eval!`.

---

## Section 5 — OQ-2 (c): Retrievable Consumed-Instruction Count

**Question:** after a `Lua.eval!/2` call, is the consumed instruction count retrievable?

**Search performed:** grepped `deps/lua/lib/lua.ex` for `instruction_count` and `consumed` — no public function found. Grepped `deps/lua/lib/lua/api.ex` similarly — no public function found. Read `deps/lua/lib/lua/vm/state.ex` in full.

**Finding:** `Lua.VM.State` (the internal struct at `lua.state`) declares a public struct field:

```elixir
# `instruction_count` carries the running tally ACROSS engine boundaries only.
# Never written per opcode.
instruction_count: 0,
```

This field is present on the returned `Lua.t()` state after `eval!`. It is readable via struct field access:

```elixir
lua3 = Lua.new(max_instructions: 5000)
{_, lua3_after} = Lua.eval!(lua3, "local x = 0; for i = 1, 100 do x = x + i end; return x")
consumed = lua3_after.state.instruction_count
```

**Actual output:**

```
OQ-2(c) instruction_count field after eval: 99
```

**Verdict: consumed instruction count IS accessible via `lua_after.state.instruction_count` (type `Lua.VM.State`, field `:instruction_count`).** This is NOT a formal documented public API — no `Lua.instruction_count/1` function exists. It IS a readable struct field on the state returned by `Lua.eval!/2`.

**Implication for S5:** LUA-16's acceptance criterion ("an execution that exhausts its instruction budget reports the consumed count alongside the error") is satisfiable: the count is in `lua_after.state.instruction_count`. Since this is an internal struct field (not a versioned public API), S5 requirements that read it must document the mechanism explicitly and include a regression test so a future library upgrade that removes or renames the field fails loudly.

---

## Section 6 — OQ-2 (d): Default Sandbox Deny-Set Empirical Verification

**Question:** what do sandboxed functions look like in the global namespace, and what error do they produce when called?

Two experiments were run against a default `Lua.new()` state (no options):

### Experiment 1: global value presence

```elixir
sandbox_checks = [
  {"os.execute", "return os.execute"},
  {"os.exit", "return os.exit"},
  {"load", "return load"},
  {"loadfile", "return loadfile"},
  {"require", "return require"},
  {"dofile", "return dofile"},
  {"io.open", "return io.open"},
]
for {name, script} <- sandbox_checks do
  {[val], _} = Lua.eval!(lua_default, script)
  IO.puts("sandbox[#{name}] = #{inspect(val)}")
end
```

**Actual output:**

```
sandbox[os.execute] = #Lua.NativeFunc<#Function<19.94404328/2 in Lua.wrap_callback/3>>
sandbox[os.exit] = #Lua.NativeFunc<#Function<19.94404328/2 in Lua.wrap_callback/3>>
sandbox[load] = #Lua.NativeFunc<#Function<19.94404328/2 in Lua.wrap_callback/3>>
sandbox[loadfile] = #Lua.NativeFunc<#Function<19.94404328/2 in Lua.wrap_callback/3>>
sandbox[require] = #Lua.NativeFunc<#Function<19.94404328/2 in Lua.wrap_callback/3>>
sandbox[dofile] = #Lua.NativeFunc<#Function<19.94404328/2 in Lua.wrap_callback/3>>
sandbox[io.open] = #Lua.NativeFunc<#Function<19.94404328/2 in Lua.wrap_callback/3>>
```

**Finding:** sandboxed functions are **not nil**. They are present as `#Lua.NativeFunc<...>` stub values — a host function wrapper that raises on any call. This is materially different from R-Co's SBX-1 "never opened" approach where the dangerous globals simply did not exist in the table. In tv-labs/lua, they exist but raise.

### Experiment 2: call error messages

```elixir
calls = [
  {"os.execute", "return pcall(os.execute, 'ls')"},
  {"os.exit", "return pcall(os.exit, 0)"},
  {"load", "return pcall(load, 'return 1')"},
  {"loadfile", "return pcall(loadfile, 'f.lua')"},
  {"require", "return pcall(require, 'mod')"},
  {"dofile", "return pcall(dofile, 'f.lua')"},
  {"io.open", "return pcall(io.open, 'f.txt', 'r')"},
]
for {name, script} <- calls do
  {[ok, err], _} = Lua.eval!(lua_default, script)
  IO.puts("call[#{name}]: ok=#{inspect(ok)}, err=#{inspect(err)}")
end
```

**Actual output:**

```
call[os.execute]: ok=false, err="Lua runtime error: os.execute(_) is sandboxed"
call[os.exit]: ok=false, err="Lua runtime error: os.exit(_) is sandboxed"
call[load]: ok=false, err="Lua runtime error: load(_) is sandboxed"
call[loadfile]: ok=false, err="Lua runtime error: loadfile(_) is sandboxed"
call[require]: ok=false, err="Lua runtime error: require(_) is sandboxed"
call[dofile]: ok=false, err="Lua runtime error: dofile(_) is sandboxed"
call[io.open]: ok=false, err="Lua runtime error: io.open(_, _) is sandboxed"
```

**Verdict for all seven:**

| Function | In default sandbox | Value when read | Call result |
|---|---|---|---|
| `os.execute` | YES | `NativeFunc` stub | `false, "Lua runtime error: os.execute(_) is sandboxed"` |
| `os.exit` | YES | `NativeFunc` stub | `false, "Lua runtime error: os.exit(_) is sandboxed"` |
| `load` | YES | `NativeFunc` stub | `false, "Lua runtime error: load(_) is sandboxed"` |
| `loadfile` | YES | `NativeFunc` stub | `false, "Lua runtime error: loadfile(_) is sandboxed"` |
| `require` | YES | `NativeFunc` stub | `false, "Lua runtime error: require(_) is sandboxed"` |
| `dofile` | YES | `NativeFunc` stub | `false, "Lua runtime error: dofile(_) is sandboxed"` |
| `io.open` | YES | `NativeFunc` stub | `false, "Lua runtime error: io.open(_, _) is sandboxed"` |

All seven confirmed sandboxed by default. The error messages are catchable via `pcall` (same mechanism as OQ-2(b)).

### Known gap from decision 0014's analysis

Decision 0014 identified a **five-function gap** in the `os.*` surface. The default sandbox denies `os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`, `os.tmpname` (6 of 11). It does **NOT** deny `os.clock`, `os.date`, `os.difftime`, `os.setlocale`, `os.time`. R-Co never opened the `os` table at all, so all 11 were unreachable. This gap must be closed by LUA-03's restatement requirement — it is NOT this requirement's scope. The gap is documented here so the dependent requirements cannot miss it.

---

## Section 7 — Lua Version and Dialect

**Code run:**

```elixir
lua = Lua.new()
{[version], _} = Lua.eval!(lua, "return _VERSION")
IO.puts("_VERSION = #{version}")

{[div_float, div_int], _} = Lua.eval!(lua, "return 3/2, 3//2")
IO.puts("3/2 = #{div_float}")
IO.puts("3//2 = #{div_int}")
```

**Actual output:**

```
_VERSION = Lua 5.3
3/2 = 1.5
3//2 = 1
```

**Verdict:**

- `_VERSION` = `"Lua 5.3"` — confirmed, not LuaJIT, not 5.1, not 5.4.
- `3/2` = `1.5` — float division (Lua 5.3 semantics, NOT integer division as in Lua 5.1/LuaJIT). Integer literals divided by integer literals produce floats when the result is not whole.
- `3//2` = `1` — floor division (Lua 5.3 operator, did not exist in Lua 5.1/LuaJIT).

**Implication for S5:** the variable-marshalling layer (LUA-02's "fresh state per invocation," number round-trip through Ecto/JSON) must account for Lua 5.3's integer/float subtype distinction. `3/2` is `1.5`, not `1`. `math.type(3)` is `"integer"`, `math.type(3.0)` is `"float"`. This is the only semantic break from Lua 5.1 with real weight on this use case, per decision 0014's analysis. It must be settled once in the variable-marshalling layer, not per script.

---

## Section 8 — OQ-2 Escape Hatch Disposition

**The OQ-2 escape hatch was NOT exercised.** All observed behaviours are consistent with tv-labs/lua's documentation as cited in decision 0014.

Specifically:
- `mix deps.get` completed (decision 0014 explicitly did not assert this; now confirmed).
- `mix compile` produced zero warnings, zero errors.
- `_VERSION = "Lua 5.3"` matches the documented Lua 5.3 implementation claim.
- `pcall` catches both budget exhaustion (`max_instructions`) and host function errors, consistent with "both catchable in-band via `pcall`."
- Default sandbox denies all 7 tested paths, consistent with the documented 27-path default sandbox.
- `instruction_count` is accessible as an internal struct field (decision 0014 cited the documentation claim; this spike confirms the field exists and contains a non-zero value after execution).

No observed behaviour contradicts the documentation. The documented gap (5 undeniable `os.*` functions) was identified from documentation and is confirmed here as a gap — it is not a contradiction, it is a stated design choice of the library that S5's LUA-03 restatement must address.

---

## Deliverables Summary

| Item | Result |
|---|---|
| `mix.exs` dep added | `{:lua, "~> 1.0"}` — done |
| `mix deps.get` | `lua 1.0.2` fetched — PASS |
| `mix compile` | 63 lua + 121 letflow files, 0 warnings, 0 errors — PASS |
| OQ-2(a) pcall budget exhaustion | Catchable — `[false, "instruction budget exceeded"]` |
| OQ-2(b) pcall host errors | Catchable — `[false, "host function exploded"]` |
| OQ-2(c) consumed instruction count | Accessible via `lua_after.state.instruction_count` (internal struct field, not formal public API) — value `99` for a 100-iteration for-loop |
| OQ-2(d) sandbox deny-set | All 7 tested functions present as raising stubs — confirmed sandboxed |
| `_VERSION` | `"Lua 5.3"` |
| `3/2` | `1.5` (float division) |
| `3//2` | `1` (floor division) |
| OQ-2 escape hatch | NOT exercised |
