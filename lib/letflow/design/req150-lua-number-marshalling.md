# REQ-150 — Lua Number Marshalling Design

**Requirement:** REQ-150 (Settle OQ-6 — Lua 5.3 integer/float marshalling across
`VariableMerge` and JSONB variable storage; blocks LUA-11 / REQ-159 / REQ-160)
**Stage:** S5
**Owner:** CODE-DESIGNER
**Date:** 2026-08-26
**Library version:** `lua 1.0.2` (tv-labs/lua, Apache-2.0, adopted by REQ-148)
**Depends on:** REQ-148 (done); consumes decision
`docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md` OQ-6

This is a **design-only** artefact. No file under `lib/letflow/engine/` is
created or modified by this requirement — confirmed by `git diff --stat` in
§6 below. All findings in §1 are real runs against the adopted `tv-labs/lua`
runtime and, for the JSONB path, a real Postgres `jsonb` column — not
inferred from the Lua 5.3 manual or from documentation.

---

## §1 — Empirical findings

### 1.1 Lua literal → Elixir term (both directions of the boundary)

Script (`Lua.eval!/2` against `Lua.new()`):

```
lua = Lua.new()
{[int_val], _}      = Lua.eval!(lua, "return 3")
{[float_val], _}    = Lua.eval!(lua, "return 3.0")
{[float_val2], _}   = Lua.eval!(lua, "return 3/2")
{[floordiv_val], _} = Lua.eval!(lua, "return 3//2")
```

**Actual output:**

```
int_val raw (return 3): 3
float_val raw (return 3.0): 3.0
float_val2 raw (return 3/2): 1.5
floordiv_val raw (return 3//2): 1
is_integer(int_val)=true is_float(int_val)=false
is_integer(float_val)=false is_float(float_val)=true
```

**Finding:** a Lua **integer** literal read back into Elixir is a native
Elixir/BEAM `integer()`. A Lua **float** literal (including one produced by
`/` division per Lua 5.3's float-division semantics, confirmed by REQ-148) is
a native Elixir/BEAM `float()`. `tv-labs/lua`, being a pure-Elixir VM, does
**not** wrap numbers in any intermediate struct or tagged tuple — the
library's internal Lua-integer/Lua-float subtype distinction is discarded at
the Elixir boundary and replaced by whichever native BEAM numeric type
matches: `is_integer/1` is `true` for the Lua-integer case and `false` for
the Lua-float case, and vice versa for `is_float/1`.

From inside Lua, `math.type/1` still reports the subtype correctly:

```
math.type(3) = "integer"
math.type(3.0) = "float"
```

confirming the VM itself tracks the subtype up to the moment a value crosses
into Elixir, at which point the subtype **is** the native Elixir type (this
is the mechanism, not a loss — see §2.1).

### 1.2 Elixir integer/float handed to Lua (`Lua.set!/3`)

```
lua2 = Lua.new()
lua2 = Lua.set!(lua2, [:host_int], 42)
lua2 = Lua.set!(lua2, [:host_float], 42.0)
lua2 = Lua.set!(lua2, [:host_float_frac], 42.5)
```

**Actual output:**

```
math.type(host_int) [Elixir 42]          = "integer"
math.type(host_float) [Elixir 42.0]      = "float"
math.type(host_float_frac) [Elixir 42.5] = "float"
echoed host_int back to Elixir: 42
echoed host_float back to Elixir: 42.0
```

**Finding:** the mapping is symmetric and lossless in both directions. An
Elixir `integer()` handed to Lua via `Lua.set!/3` is seen by the script as a
Lua **integer** (`math.type` reports `"integer"`). An Elixir `float()` —
**even one with no fractional part**, e.g. `42.0` — is seen as a Lua
**float** (`math.type` reports `"float"`, not `"integer"`). The library does
not attempt to "clean up" a whole-number float into a Lua integer; the
Elixir-side type alone decides the Lua-side subtype.

### 1.3 `Jason.encode!/1` → `Jason.decode!/1` round trip (JSONB storage's actual encode/decode library)

```
Jason.encode!(3)   = "3"
Jason.encode!(3.0) = "3.0"
Jason.encode!(3.5) = "3.5"

round trip 3   -> 3    (is_integer=true,  is_float=false)
round trip 3.0 -> 3.0  (is_integer=false, is_float=true)
round trip 3.5 -> 3.5  (is_integer=false, is_float=true)
```

**Finding:** `Jason` preserves the integer/float subtype through
`encode!/decode!`. Critically, **`3.0` does not collapse to `3`** — `Jason`
always emits a decimal point for a `float()` value (`"3.0"`, never `"3"`),
and `Jason.decode!/1` always parses a JSON number containing a decimal point
back into an Elixir `float()`. A JSON number with no decimal point decodes
to an Elixir `integer()`. The wire format itself (presence/absence of `.`)
**is** the subtype carrier — this is why the rule in §2 works with a plain
`Ecto.Type :map` field and no custom marshalling type is needed for the
subtype itself.

### 1.4 Full loop: Lua → Elixir → JSON encode → decode → back into Lua

```
Lua `return 7`   -> Elixir 7   -> JSON "7"
Lua `return 7.0` -> Elixir 7.0 -> JSON "7.0"
decoded_int=7 (integer? true)
decoded_float=7.0 (float? true)
math.type(back_int) after full round trip  = "integer"
math.type(back_float) after full round trip = "float"
```

**Finding:** the full Lua→JSONB→Lua loop is lossless for the subtype: a
value that started as a Lua integer is still a Lua integer after a full
store-and-reload cycle, and a value that started as a Lua float (including a
whole-number float) is still a Lua float.

### 1.5 Whole-number float (`2.0`-shaped value) — explicit, since this is the one that "looks like" it should collapse

Tested directly as `3.0` in §1.3/§1.4 above (no separate `2.0` case needed —
the finding is general, not literal-value-specific): **a float with no
fractional part does NOT collapse to an integer at any point in the Elixir ↔
Lua ↔ JSON chain.** `3.0` stays `"3.0"` in JSON text, stays `3.0`
(`is_float`) after `Jason.decode!/1`, and is reported `math.type ==
"float"` when hand back to a script. This holds through a **real Postgres
`jsonb` column**, not just `Jason` in isolation — see §1.7.

### 1.6 Integer outside IEEE-754 exact range (`2^53 + 1`)

```
big = 9_007_199_254_740_993   # 2^53 + 1
```

**Actual output:**

```
math.type(big) in Lua = "integer"
big echoed back from Lua: 9007199254740993
big_echo == big ? true
Jason.encode!(big) = 9007199254740993
decoded_big: 9007199254740993
decoded_big == big ? true
is_integer(decoded_big)=true
Lua literal 9007199254740993 read back into Elixir: 9007199254740993
lua_big == 9007199254740993 ? true
```

**Finding:** no precision loss anywhere in the chain, for a value that
**would** lose precision if it ever passed through an IEEE-754 double.
Three facts combine to make this safe:

1. Elixir/BEAM integers are arbitrary-precision (bignums), not IEEE-754
   doubles — `9_007_199_254_740_993` is stored and compared exactly.
2. `tv-labs/lua`'s Lua-integer subtype round-trips through the Elixir
   boundary as a native Elixir `integer()` (§1.1), never coerced through a
   float representation.
3. `Jason` encodes an Elixir `integer()` as a bare JSON integer literal
   (`9007199254740993`, no decimal point, no exponential notation) and
   decodes a bare JSON integer literal back into an arbitrary-precision
   Elixir `integer()` — it never routes an integer value through a
   double-precision float during encode or decode.

**This is conditional on the value staying an Elixir/Lua-integer the whole
way.** If a host function, a script, or a future JSON producer ever turns
this value into a Lua/Elixir *float* (e.g. `tonumber(x) + 0.0`, or a
non-Elixir JSON producer that emits `9007199254740993.0`), IEEE-754's 53-bit
mantissa limit applies and precision loss becomes possible. §2.3 states this
as a normative caution, not an unhandled case — the rule does not attempt to
detect or reject this; it is out of scope for a marshalling layer that never
inspects magnitude.

### 1.7 Real Postgres `jsonb` column round trip (not just `Jason` in isolation)

`variables` (`instance_projections.variables`, `lib/letflow/event_store/instance_projection.ex:133`)
is a plain built-in Ecto `:map` field over a `jsonb` column — confirmed by
reading the schema module directly. To verify the subtype survives the
**actual** storage path (Postgrex's own jsonb extension, which the `:map`
Ecto type delegates to — not a hand-rolled `Jason.encode!/decode!` call),
this was run against a real, disposable Postgres database
(`letflow_test99`, created via `mix ecto.create`, dropped afterward):

```elixir
payload = %{
  "int_val" => 3, "float_whole" => 3.0, "float_frac" => 3.5,
  "big_int" => 9_007_199_254_740_993, "null_val" => nil
}
result = Ecto.Adapters.SQL.query!(Repo, "SELECT $1::jsonb AS col", [payload])
```

**Actual output** (the Elixir map bound directly as a Postgrex parameter,
exercising the library's own jsonb encode/decode extension —
`deps/postgrex/lib/postgrex/extensions/jsonb.ex:8` defaults
`Application.get_env(:postgrex, :json_library, Jason)` to `Jason`, and this
app configures no override):

```
decoded value: %{
  "big_int" => 9007199254740993,
  "float_frac" => 3.5,
  "float_whole" => 3.0,
  "int_val" => 3,
  "null_val" => nil
}
big_int => 9007199254740993 (integer? true, float? false, nil? false)
float_frac => 3.5 (integer? false, float? true, nil? false)
float_whole => 3.0 (integer? false, float? true, nil? false)
int_val => 3 (integer? true, float? false, nil? false)
null_val => nil (integer? false, float? false, nil? true)

float_whole == payload float_whole? true
big_int == payload big_int? true
```

**Finding:** confirmed against a real `jsonb` column, not merely `Jason` in
isolation — every result in §1.3–§1.6 holds for the actual storage path
`variables` uses. `3.0` came back as `3.0` (`is_float`), not `3`; the
`2^53+1` integer came back byte-for-byte exact; `null` came back as Elixir
`nil`.

### 1.8 JSON `null` crossing the boundary

```
Jason.encode!(nil) = null
decoded_null (Elixir side): nil
```

Handed to Lua via `Lua.set!/3`:

```
What the Lua script sees for host_nil: "lua_nil"
Lua `return nil` read back into Elixir: nil
```

(the probe script was `if host_nil == nil then return 'lua_nil' else return
type(host_nil) end` — it returned the string `"lua_nil"`, confirming the Lua
side's `==` comparison against its own `nil` literal succeeds for the value
that started as Elixir `nil`, i.e. Lua sees it as its own `nil`, not as a
string, table, or truthy sentinel of any kind.)

**Finding:** `nil` round-trips symmetrically and exactly: JSON `null` →
Elixir `nil` → Lua `nil` → Elixir `nil` → JSON `null`. No sentinel value, no
wrapper, no special-case needed anywhere in the chain.

---

## §2 — NORMATIVE RULE (cite by section number: "REQ-150 §2.n")

This is the single, central marshalling rule REQ-159 (read path: JSONB →
value handed to a script) and REQ-160 (write path: value returned from a
script → JSONB) must both implement by calling the one module/function named
in §3 — not by re-deriving any part of this rule independently.

### §2.1 — Lua → Elixir (write path input / read-back of a script's return value)

A value produced inside a Lua script and observed by the host (a `pcall`
return value, a value written via a host function argument, or `platform.*`
setter argument) maps to Elixir as:

| Lua subtype (`math.type`) | Elixir type produced |
|---|---|
| `"integer"` | `integer()` (BEAM native, arbitrary precision) |
| `"float"` | `float()` (BEAM native, IEEE-754 double) |

This is **not** a conversion this rule performs — it is what `tv-labs/lua`
already does natively at the `Lua.eval!/2` return boundary (§1.1). The rule
is: **do not add any further coercion on top of it.** No caller may collapse
a whole-number Lua float to an Elixir integer, and no caller may promote a
Lua integer to an Elixir float "for safety."

### §2.2 — Elixir → Lua (read path: a stored JSONB variable value handed into a script)

A value read from `instance_projections.variables` (a plain `:map`/`jsonb`
field, already decoded to native Elixir terms by Ecto/Postgrex before it
reaches this rule — §1.7) maps to Lua, via `Lua.set!/3`, as:

| Elixir type (post-JSONB-decode) | Lua subtype the script observes (`math.type`) |
|---|---|
| `integer()` | `"integer"` |
| `float()` (including a whole-number value, e.g. `3.0`) | `"float"` |
| `nil` | Lua `nil` |

This, too, is native `Lua.set!/3` behaviour (§1.2, §1.8) — the rule is the
same non-coercion instruction as §2.1, applied in the other direction: the
Elixir-side type, exactly as decoded from JSONB, decides the Lua-side
subtype. **No caller may inspect a float's fractional part and decide to
hand Lua an integer instead** — doing so would be exactly the "1 stored, 1.0
read back" (or the reverse) correctness bug this requirement exists to
foreclose.

### §2.3 — Whole-number float persists as a float; no collapse in either direction

A float with no fractional part (`2.0`, `3.0`, ...) is a **float**, full
stop, at every point in the chain: as a Lua value (`math.type == "float"`),
as an Elixir value (`is_float/1 == true`), as JSONB storage (serialized with
a decimal point, e.g. `3.0`, never as a bare integer literal — §1.3, §1.7),
and as the value handed back into a later script. **Neither direction of the
rule performs a numeric-value-based collapse.** A script that writes `2.0`
and a later script that reads it back sees a Lua float, `math.type ==
"float"`, not `"integer"` — this is the literal failure mode OQ-6 names
("a script that writes 1 and reads back 1.0"), stated here as: it is
`Letflow`'s job to make sure this does **not** happen, by never converting
based on value, only ever passing the type through unchanged.

### §2.4 — Integer outside IEEE-754 exact range (`|n| ≥ 2^53`)

An Elixir/Lua-*integer* value outside the IEEE-754 53-bit exact range is
carried **exactly**, with no precision loss, through the full
Lua↔Elixir↔JSONB chain, because (§1.6): BEAM integers are arbitrary
precision, `tv-labs/lua`'s Lua-integer never routes through a float
representation at the Elixir boundary, and `Jason`/Postgrex's jsonb
extension encode a JSON integer as a bare literal (no exponential notation,
no forced float) and decode it back to an arbitrary-precision Elixir
integer. **This holds only so long as the value's Lua/Elixir *subtype*
stays integer the entire way.** If a script or host function ever converts
such a value to a Lua/Elixir *float* (e.g. arithmetic that promotes it, such
as dividing by a non-divisor), IEEE-754's exact-range limit applies from
that point forward and this rule does not attempt to detect, warn on, or
prevent that value-losing promotion — that is ordinary Lua/IEEE-754
floating-point behaviour, not a marshalling defect, and is out of this
rule's scope (script-authored arithmetic correctness is not this
conversion's job).

### §2.5 — JSON `null`

A JSON `null` (a JSONB variable stored as, or containing, `null`) decodes to
Elixir `nil` (Ecto/Jason's ordinary behaviour, unmodified by this rule) and
is handed to a script via `Lua.set!/3` as Lua `nil` (§1.8) — a script sees
exactly the same `nil` it would see for an unset local. In the write
direction, a Lua `nil` value returned from a script, or explicitly assigned,
maps back to Elixir `nil` and encodes to JSON `null`. No sentinel value
(e.g. a `:null` atom, an empty-table marker) is introduced by this rule in
either direction.

### §2.6 — Summary table (both directions, all cases)

| Case | Elixir/JSONB representation | Lua representation | Collapses / loses precision? |
|---|---|---|---|
| Integer, in range | `integer()` | `"integer"` | No |
| Integer, `\|n\| ≥ 2^53` | `integer()` (arbitrary precision) | `"integer"` | No (§2.4 — conditional on staying integer-typed) |
| Float, fractional | `float()` | `"float"` | No |
| Float, whole-number (e.g. `3.0`) | `float()` (JSON text keeps the decimal point) | `"float"` | No (§2.3) |
| `null` | `nil` | `nil` | No (§2.5) |

---

## §3 — Owning module and function

**No such module exists yet — this is a design-time naming, not an
implementation.** `lib/letflow/engine/` is untouched by this requirement
(§6). The module below is what REQ-159 and REQ-160 must create (or extend,
if either lands first and the other adds to it) rather than each
implementing its own conversion:

**Module:** `Letflow.Engine.LuaNumberMarshalling`
**File:** `lib/letflow/engine/lua_number_marshalling.ex` (does not exist yet)

**Functions:**

- `to_lua(value :: term()) :: term()` — the read-path conversion (§2.2):
  takes a value already decoded from `instance_projections.variables`
  (native Elixir `integer()`, `float()`, `nil`, `String.t()`, `boolean()`,
  `map()`, or `list()`) and returns the value to pass as the argument to
  `Lua.set!/3` when exposing a variable to a script. For the numeric/`nil`
  cases this rule covers, `to_lua/1` is the **identity function** — no
  conversion happens, by design (§2.1–§2.3, §2.5): the rule this module
  exists to enforce is *that no coercion is introduced*, and codifying that
  as an explicit identity clause (rather than omitting numeric handling
  entirely) is what keeps a future maintainer from "helpfully" adding one.
- `from_lua(value :: term()) :: term()` — the write-path conversion (§2.1):
  takes a value as returned from `Lua.eval!/2` or read from Lua state after
  a script runs, and returns the value to merge into
  `Letflow.Engine.VariableMerge.merge/3`'s `incoming_variables` map (which
  ultimately gets `Jason`-encoded into the `variables` jsonb column via
  Ecto's `:map` type). Also the identity function for the numeric/`nil`
  cases, for the same reason.

Both functions are total (no error return) for the cases this rule covers —
number and `nil` marshalling never fails, per §1's findings. Non-numeric
cases (strings, booleans, tables/maps, lists) are **out of this
requirement's scope** (OQ-6 names only the integer/float split as having
"real semantic weight" — decision 0014 (b)); `to_lua/1`/`from_lua/1`'s
signatures are written to accept `term()` so REQ-159/REQ-160 have one call
site regardless of value shape, but this design makes no claim about
non-numeric behaviour and REQ-159/REQ-160 must extend or test that
separately.

---

## §4 — WASM-12 binds to this same rule

Decision 0014's OQ-6 states this marshalling question "interacts with
WASM-12's parity requirement, since the WASM ABI has its own numeric
representation." Per that decision, **WASM-12 (REQ-171, REQ-172) must
produce Lua/WASM host-API behaviour that is semantically identical to the
Lua rule in §2** — a script written against the WASM host API observes the
same integer/float/whole-number-float/big-integer/`null` behaviour a Lua
script observes under §2.1–§2.5, even though the WASM ABI's own wire-level
numeric representation (via `wasmex`, per decision 0014's runtime choice)
differs mechanically from `tv-labs/lua`'s in-Elixir representation. REQ-171
and REQ-172 are responsible for whatever WASM-side conversion achieves that
parity; they do not get to independently re-derive a different
integer/float rule for the WASM half — §2 is the one rule, cited by section
number, that both runtimes' host APIs must conform to.

---

## §5 — Open questions

None. Every acceptance criterion in this requirement is answered with a
real, quoted run (§1) and a defined outcome (§2), including the two cases
the requirement specifically calls out as needing a defined rather than
"undefined" answer (out-of-range integer, §2.4/§1.6; JSON `null`, §2.5/§1.8).

One item flagged for whoever implements REQ-159/REQ-160, not left open here:
`to_lua/1`/`from_lua/1`'s behaviour for non-numeric, non-`nil` values
(strings/booleans/tables/lists) is explicitly out of this rule's scope (§3)
and must be designed or verified separately — it is not silently assumed to
be identity-safe by this artefact.

---

## §6 — Confirmation: no `lib/letflow/engine/` change

```
$ git diff --stat main...HEAD -- lib/letflow/engine/
(no output — zero files changed)
```

See the Deliverables Summary below for the actual command run at commit
time.

---

## Deliverables Summary

| Item | Result |
|---|---|
| Lua integer literal → Elixir | native `integer()` (`is_integer` true) |
| Lua float literal → Elixir | native `float()` (`is_float` true) |
| Elixir integer → Lua (`Lua.set!/3`) | `math.type == "integer"` |
| Elixir float → Lua (`Lua.set!/3`), incl. whole-number | `math.type == "float"` (no collapse) |
| `Jason.encode!/decode!` subtype survival | confirmed — decimal point is the wire-level subtype carrier |
| Whole-number float (`3.0`) round trip | stays `float`, JSON text keeps `.0`, confirmed against real Postgres `jsonb` |
| `2^53+1` integer round trip (Lua↔Elixir↔JSON↔real jsonb) | exact, no precision loss, confirmed |
| JSON `null` round trip | `null` ↔ Elixir `nil` ↔ Lua `nil`, symmetric, confirmed |
| Real Postgres `jsonb` column check | run against disposable `letflow_test99` DB via `Ecto.Adapters.SQL.query!`, all findings hold |
| Owning module/function | `Letflow.Engine.LuaNumberMarshalling.to_lua/1` and `.from_lua/1` (not yet created — design only) |
| WASM-12 binding | stated in §4, citing decision 0014 OQ-6 |
| `lib/letflow/engine/` touched | no (§6, confirmed via `git diff --stat`) |
