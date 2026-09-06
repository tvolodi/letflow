# Design: REQ-157 — Capability model and capability check at every gated host-function call site (LUA-05, LUA-06)

**Requirement:** REQ-157
**Stage:** S5
**Owner (design):** CODE-DESIGNER
**Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-27
**Extends:** `lib/letflow/design/req152-lua-time-denial.md` (REQ-152) — this design does not
restate REQ-151/REQ-152's deny-set or `platform.now` invariants; it adds to
`Letflow.Engine.Lua.Platform` alongside them. Read REQ-152's design first, in particular
its §5 ("`platform.now` is ungated by design") and §4.2 (composition point), both of
which this design is bound by (AC7 in that design; this requirement must not violate
either).

---

## 0. Sources read for this design

- `handoffs/WF02-REQ157-20260827/step-00-git-setup.json` (`context.requirement_text`,
  `context.owned_modules`, `task.acceptance_criteria`)
- `docs/requirements.yaml` REQ-157 entry (full `description` and 8-item
  `acceptance_criteria`, read directly — quoted verbatim in §7 below)
- `lib/letflow/engine/lua/platform.ex` (the REQ-152 implementation being extended — read
  directly, not assumed from its design doc)
- `lib/letflow/design/req152-lua-time-denial.md` (full — the design being extended;
  its §5 "ungated by design" binding statement and §4.2 composition-point pattern are
  load-bearing constraints on this design, see §5 below)
- `lib/letflow/engine/lua/sandbox.ex` (read to confirm this requirement does NOT need to
  change it — see §1 scope boundary and §4.4)
- `lib/letflow/engine/lua/executor.ex` (read for context only, per this run's explicit
  instruction NOT to touch it — owned/locked by the concurrent WF02-REQ154-20260827 run;
  confirmed this design proposes no change to it, see §8)
- `lib/letflow/engine/lua_script_audit.ex` (read for the existing
  `rescue e in [Lua.RuntimeException, Lua.CompilerException] -> {:error,
  Exception.message(e)}` pattern in `Executor.execute_with_manifest/2`, which is the
  shape this design's raised exception must remain compatible with without requiring an
  edit to that file — see §6.3)
- `deps/lua/lib/lua.ex` — `Lua.set!/3` (lines 332–360, the same installation mechanism
  REQ-152 used) and `Lua.sandbox/2` (lines 266–271, the raise-on-call pattern)
- `deps/lua/lib/lua/runtime_exception.ex` — `exception/1`'s three clauses, in particular
  the keyword-list clause (`exception(list) when is_list(list)`, lines 53–62) that
  validates only `:scope`/`:function`/`:message` are present but stores the **entire**
  list in `:original`, and `message/1`'s list clause (lines 100–102) which renders only
  those three keys into text. This is the mechanism §6 below builds on: extra keys
  (`:capability_required`, `:capabilities_granted`) survive on `:original` unrendered,
  giving a structured, host-readable payload riding the same raise that satisfies LUA-06's
  "MUST raise a Lua error."
- `docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md` — LUA-05/LUA-06 on
  the "satisfiable substantially as worded" list (§502-506), with the "starting position
  to verify, not a clearance" caution (§512-514) this design's own test-traceability table
  (§9) exists to answer
PROVENANCE (historical, not current decision authority):
- `R-Co/src/lua/capabilities.zig`, `R-Co/src/lua/host_api/mod.zig`: **not present in this
  checkout** (confirmed by `find` for both paths — no result). This design proceeds from
  the requirement text's own restatement of both files' substance (quoted in
  `docs/requirements.yaml` REQ-157's `description`, reproduced in §7 below), which is the
  only available source for their content in this environment. Flagged as OQ-1 (§11) —
  not silently assumed equivalent to the original.

---

## 1. Scope boundary

**In scope (per requirement text, restated):**
1. A capability-set representation with `has`/`add` semantics (a string-grant set) and a
   check function producing structured denial details (function, capability required,
   capabilities granted) — `Letflow.Engine.Lua.Capabilities` (new module, §2).
2. A single registration point installing the `platform` Lua table, enforcing a CLOSED
   set of exactly 8 functions — extending `Letflow.Engine.Lua.Platform.install/1,2`
   (§4).
3. Denial raises a Lua error (LUA-06) AND is reportable to the host as a structured
   Elixir-side value (§6).
4. `call_service`'s capability is parameterised by service id
   (`service:call:<svc_id>`), not a blanket `service:call` (§4.2, §6.4).
5. `now` and `fail` are ungated by design, with the rationale stated in the moduledoc
   (§5, §7 AC6).

**Out of scope (explicitly, per requirement text):**
- The real bodies of `read_variable`, `write_variable`, `log`, `emit_event`,
  `get_instance_state`, `call_service`, `fail` — REQ-159/160/161/162+. This design
  specifies only the minimal stub behavior needed to exercise the capability gate (§4.3).
- `platform.now`'s implementation — already shipped, REQ-152. This design does not
  change `Platform.now/0` or `Platform.TimeSource` at all.
- Any change to `Letflow.Engine.Lua.Sandbox` or `Letflow.Engine.Lua.Executor` — see §1.1
  and §8 for why neither file needs to change for this requirement's scope, and why
  `Executor` in particular must not be touched (concurrent locked run).
- Manifest validation (LUA-07) — REQ-158, a separate requirement, depends on this one's
  `Capabilities` grant-set shape but is not built here.

### 1.1 Why `Letflow.Engine.Lua.Sandbox` is unchanged

`Sandbox.new/1`'s existing pipeline calls `Letflow.Engine.Lua.Platform.install(lua)` —
arity 1, no capability argument, because at REQ-152 time `platform` exposed only the
ungated `now`. This design's mechanism (§4) is built specifically so that call does not
need to change: `install/1` becomes a thin wrapper that delegates to the new `install/2`
with an **empty** grant set (`Capabilities.new()`), and `install/2` is the actual single
registration point that installs all 8 functions from one matrix (§4.1). Every
`Lua.t()` produced by `Sandbox.new/0` or `Sandbox.new/1` therefore already exposes all 8
`platform.*` functions today — the 6 gated ones simply deny every call until some future
requirement (REQ-158/159/160, wiring a real manifest's granted capabilities through) calls
`install/2` directly with a non-empty set. This keeps `sandbox.ex` and `executor.ex`
(both outside this run's `owned_modules`, `executor.ex` explicitly locked) untouched
while still letting REQ-157's own acceptance tests exercise the gate against a real
production `Sandbox.new/0` VM (AC1, §9) and, separately, against a hand-built
non-empty grant set via `Platform.install/2` called directly in test code (AC2–AC5, §9).

**File layout:**

| File | Purpose |
|---|---|
| `lib/letflow/engine/lua/capabilities.ex` | New. `Letflow.Engine.Lua.Capabilities` — the grant-set representation, `has?/2`/`add/2`, the `check/3`/`check!/3` gate functions, the structured denial shape, and the `service_capability/1` helper (§2, §6). |
| `lib/letflow/engine/lua/platform.ex` | Extended (not replaced). Gains the 8-function capability matrix (§4.1), `install/2` (the new single registration point), `install/1` reduced to a thin empty-grant-set delegation, and the 6 gated-function stubs (§4.3). REQ-152's `now/0`, `TimeSource`, `SystemClock` are unchanged. |
| `test/letflow/engine/lua/capabilities_test.exs` | New. `Capabilities` unit tests: `has?`/`add`, `check/3`'s three named fields, `service_capability/1`. |
| `test/letflow/engine/lua/platform_test.exs` | Extended. New test cases for the closed-set enumeration, the six denial tests, the `call_service` parameterisation test, the `now`/`fail` empty-grant-set callability test, and the moduledoc content assertion. |

---

## 2. `Letflow.Engine.Lua.Capabilities` — grant-set representation

### 2.1 Data shape

```
@type capability :: String.t()
@type grant_set :: MapSet.t(capability())
```

PROVENANCE (historical, not current decision authority):
A capability is an opaque string token (`"variable:read"`, `"service:call:billing"`,
etc.) — no atom-keyed enum, no struct, matching R-Co's `capabilities.zig` string-grant
set (per the requirement text's restatement — the actual file is not present in this
checkout, §0/§11 OQ-1) and avoiding a fixed Elixir-side enum that would need editing
every time a new capability string is minted downstream (REQ-158's manifest, REQ-159/160's
real bodies).

A bare `MapSet.t()` (not a custom struct) is this design's choice: `has?/2` and `add/2`
below are the entire public surface a caller needs, both trivial `MapSet` operations, and
a struct wrapper would add no invariant a `MapSet` doesn't already hold (uniqueness). Kept
as an opaque `grant_set()` type alias (not documented as "just a `MapSet`") so a caller
depends on `Capabilities`'s functions rather than reaching into the underlying `MapSet.t()`
directly — mirrors `Lua.t()` itself being an opaque struct callers don't pattern-match
into.

### 2.2 Public API

```
@spec new() :: grant_set()
@spec new(capabilities :: [capability()]) :: grant_set()
@spec add(grant_set(), capability()) :: grant_set()
@spec has?(grant_set(), capability()) :: boolean()
```

- `new/0` — the empty grant set (`MapSet.new()`). This is what `Platform.install/1`
  (§4.4) passes to `install/2` for every production `Sandbox.new/0,1` VM until a future
  requirement threads a real manifest's grants through.
- `new/1` — builds a grant set from a list of capability strings (e.g. a manifest's
  declared capabilities, REQ-158). Ports the "has/add" construction shape named in the
  requirement text.
- `add/2` — returns a new grant set with one more capability. Pure, non-mutating (same
  `MapSet` semantics).
- `has?/2` — `true` iff the exact capability string is a member. No prefix/wildcard
  matching of any kind — `has?(grants, "service:call:billing")` is `true` only for that
  exact string, never for `"service:call:*"` or a bare `"service:call"` (this is what
  makes `call_service`'s parameterisation, §4.2, actually enforce per-service grants
  rather than a blanket one — AC5, §9).

### 2.3 The structured denial shape

```
@type denial :: %{
        function: atom(),
        required: capability(),
        granted: [capability()]
      }
```

Exactly the three fields LUA-06's text names, in this order of definition (not
enforced by field order at the map level — Elixir maps are unordered — but stated in
this order because it is the order LUA-06's acceptance text lists them: function,
capability required, capabilities granted).

- `function` — the `atom()` name of the `platform.*` function being called
  (`:call_service`, `:read_variable`, etc.) — matches the atom keys used in the
  capability matrix (§4.1), not a Lua-visible string, so a host-side consumer can
  `case`/`Keyword.get` on it without string comparison.
- `required` — the single capability string that was missing (e.g.
  `"service:call:billing"`, `"variable:read"`). Always exactly one string — this
  requirement's matrix (§4.1) requires exactly one capability per gated function, never a
  set of alternatives.
- `granted` — a plain `[capability()]` list (via `MapSet.to_list/1` — order not
  significant, not part of the contract) of everything the calling script's grant set
  actually held at the moment of the check. Never omitted or elided even when empty
  (`[]` for an ungranted script, not `nil`).

### 2.4 Check functions

```
@spec check(grant_set(), function_name :: atom(), required :: capability() | :none) ::
        :ok | {:error, denial()}
```

- `required = :none` short-circuits to `:ok` unconditionally, without consulting
  `grant_set` at all — this is the mechanism (§4.1, §5) that makes `now`/`fail` ungated
  **by construction** rather than "gated but always granted": there is no capability
  string associated with either function anywhere in the matrix, so `check/3` never
  even looks at the grant set for them.
- `required` a binary capability string: `:ok` if `has?(grant_set, required)`, else
  `{:error, %{function: function_name, required: required, granted: MapSet.to_list(grant_set)}}`
  (§2.3's exact shape).
- This is the one function every gated host-function wrapper (§4.1) calls before doing
  any work — the single call site LUA-06 requires ("every host function MUST check").

```
@spec check!(grant_set(), function_name :: atom(), required :: capability() | :none) :: :ok
```

- Calls `check/3`; on `:ok` returns `:ok`; on `{:error, denial}` raises
  `Lua.RuntimeException` (§6) carrying `denial`'s three fields plus the human-readable
  message, and never returns. This is the function each of the 6 gated-function Lua
  wrappers (§4.1) actually calls — `check/3` (the non-raising form) exists separately so
  a future non-Lua-call-site consumer (e.g. REQ-158's load-time manifest validation, or a
  future admin/introspection endpoint) can inspect a denial as an ordinary `{:error, _}`
  tuple without needing to `rescue` anything.

### 2.5 `service_capability/1` — `call_service`'s parameterisation helper

```
@spec service_capability(svc_id :: String.t()) :: capability()
```

Returns `"service:call:" <> svc_id`, exactly. This is the **one and only** place that
string template is constructed — both the matrix row for `call_service` (§4.1, computing
what capability a given call requires) and any future test/manifest code minting a
`service:call:*` grant string (REQ-158) call this function rather than
string-interpolating `"service:call:" <> svc_id` a second time at a different call site.
A future requirement that needs to grant `call_service` capability for a specific
service ID constructs the grant via this same function
(`Capabilities.add(grants, Capabilities.service_capability("billing"))`), so the format
string exists in exactly one place in the codebase.

---

## 3. Cross-module dependency direction

`Letflow.Engine.Lua.Platform` depends on `Letflow.Engine.Lua.Capabilities` (one
direction only — `Capabilities` has no dependency back on `Platform`, `Lua`, or any
Lua-VM concept; it is pure grant-set/denial-shape logic, independent of how or whether
it is ever wired into a `Lua.t()`). This mirrors REQ-152's `Sandbox` → `Platform`
one-directional shape (`req152-lua-time-denial.md` §8).

---

## 4. `Letflow.Engine.Lua.Platform` — the single registration point

### 4.1 The capability matrix — one constant, iterated once

```
@type required_capability_fun :: (args :: [term()] -> Capabilities.capability() | :none)
@type stub_fun :: (args :: [term()] -> [term()])

@type matrix_row :: %{
        name: atom(),
        required: required_capability_fun(),
        stub: stub_fun()
      }
@type capability_matrix :: [matrix_row()]
```

`@capability_matrix` is a **module attribute, defined exactly once**, listing all 8
`platform.*` functions:

| `name` | `required` (behavior of the row's `required_capability_fun`, given the Lua call's argument list) | Notes |
|---|---|---|
| `:call_service` | Ignores all but the first argument (the `svc_id` the script passed) and returns `Capabilities.service_capability(svc_id)` (§2.5) | Parameterised — required capability depends on the first call argument (§4.2). |
| `:read_variable` | Ignores its arguments and always returns the constant string `"variable:read"` | Constant, ignores args. |
| `:write_variable` | Ignores its arguments and always returns the constant string `"variable:write"` | Constant, ignores args. |
| `:log` | Ignores its arguments and always returns the constant string `"audit:log"` | Constant, ignores args. |
| `:emit_event` | Ignores its arguments and always returns the constant string `"event:emit"` | Constant, ignores args. |
| `:get_instance_state` | Ignores its arguments and always returns the constant string `"instance:read"` | Constant, ignores args. |
| `:now` | Ignores its arguments and always returns `:none` | Ungated by design (§5). |
| `:fail` | Ignores its arguments and always returns `:none` | Ungated by design (§5). |

This is **the entire closed set** — exactly 8 rows, no more, no fewer. Adding a 9th
`platform.*` function means adding a 9th row here; there is no other place in the
codebase a `platform.*` global is ever set (§4.4's `install/2` is the only caller of
`Lua.set!(lua, [:platform, _], _)` anywhere under `lib/`, mirroring `Sandbox`'s
`INV-SBX-1` single-call-site pattern — stated here as `INV-CAP-1`, §10).

`install/2` (§4.4) is written as a **fold over `@capability_matrix`**, not as 8 separate
hand-written `Lua.set!/3` calls — this is what makes "adding a 9th function without a
matrix row" structurally impossible to do by accident: there is no per-function
`Lua.set!` call anywhere in `platform.ex` outside this one fold. A developer wiring a 9th
function has exactly one place to add it (a 9th `matrix_row`), and the closed-set
enumeration test (§9, AC1) fails the moment a `Lua.set!` call is added anywhere else
that creates a `platform.*` path outside this fold, because such a call would not go
through capability-checking at all and would be caught by a second, independent test
this design also specifies: a `Code`-level grep-equivalent assertion (§9, AC1 second
clause) that `Lua.set!` with a `[:platform, _]` first-element path appears exactly once
in `platform.ex`'s source (textually, via `File.read!/1` + pattern count — not a
`Macro`/AST walk, since a simple substring/regex count on `[:platform,` is sufficient and
does not require compiling a second copy of the module).

### 4.2 `call_service`'s parameterised requirement (AC4, AC5)

The matrix row's `required` function for `:call_service` receives the Lua call's
argument list and computes `Capabilities.service_capability(svc_id)` from the **first**
argument (the service id the script is calling — `platform.call_service("billing", ...)`
per the requirement text's own example, `platform.call_service('X')`). This is what
makes a grant for one service not authorise another: `check/3` (§2.4) is called with a
*different* `required` string on every call, depending on what `svc_id` the script
passed — a grant set containing only `"service:call:alpha"` produces `{:error, ...}`
when the required string computed for that call is `"service:call:beta"`, because
`has?/2` (§2.2) does exact string membership, never a prefix match.

### 4.3 Stub bodies (explicitly NOT this requirement's real implementation)

Each matrix row's `stub` function is the placeholder body invoked **only after**
`Capabilities.check!/3` returns `:ok` for that call. Per this requirement's explicit
"NOT IN SCOPE" text, none of these do real work:

- `:read_variable`, `:write_variable`, `:log`, `:emit_event`, `:get_instance_state`,
  `:call_service` — each stub raises `Lua.RuntimeException` with a keyword-list payload
  (§6's shape) whose `:message` states `"<function> is not yet implemented (REQ-159/160)"`
  and whose `:kind`-equivalent marker (a `:stub` key alongside `:scope`/`:function`/
  `:message`) distinguishes this from a capability denial for any test or host code that
  inspects `exception.original`. This lets a test prove "the gate ran and let the stub
  raise its own, different error" (i.e., that a *granted* call reaches past the
  capability check) without this requirement claiming any real host-function behavior.
- `:fail` — the one stub with intentional behavior, since LUA-06's "a script may always
  terminate itself" rationale (§5) is about `fail` actually being callable, not about
  what it does afterward. Stub: raises `Lua.RuntimeException` with `:message` "script
  called platform.fail" (optionally including a caller-supplied message as the first Lua
  argument, if present) — an explicit, script-triggered termination, distinguishable
  from every other raise this module produces by a `:reason` key (e.g. `reason:
  :explicit_fail`) alongside `:scope`/`:function`/`:message`, again inside the same
  keyword-list-exception mechanism (§6). No capability state or manifest concept
  attaches to this stub — that is REQ-162's territory if it needs one.
- `:now` — unchanged from REQ-152; `install/2` (§4.4) reuses the exact existing `now/0`
  behavior, not a new stub — the `now` row's `stub` ignores its argument list and returns
  `Platform.now/0`'s result wrapped as the single-element Lua return list the tv-labs/lua
  calling convention expects for a return value, the same behavior REQ-152's `install/1`
  already built inline. This is a refactor of where that behavior is constructed (into the
  fold, §4.4), not a behavior change — REQ-152's own `platform_test.exs` cases (exact-value
  injection, ISO 8601 parseability) must still pass unmodified after this requirement
  (see §9's regression note).

None of the six non-`now`/`fail` stubs return a usable value on the success path in this
requirement — they raise a distinct (non-capability) error unconditionally once past the
gate. This is a deliberate scope fence, not an oversight: a stub that instead returned,
say, `nil` silently on success would look indistinguishable from "no error, request
succeeded," which is a materially different and untested claim this requirement does not
make. Raising a clearly-labeled "not yet implemented" error on the granted path keeps
what's proven (the gate ran) separate from what isn't (the body works).

### 4.4 `install/2` — the fold, and `install/1`'s reduction to a thin delegate

```
@spec install(lua :: Lua.t(), capabilities :: Capabilities.grant_set()) :: Lua.t()
```

- The single registration point (§1.1, §4.1). Folds over `@capability_matrix`, calling
  `Lua.set!/3` once per `matrix_row` to bind `[:platform, row.name]` to a Lua-callable
  wrapper. Each installed wrapper, when invoked with the Lua call's argument list, must
  perform the following steps, in this order (a description of required behavior, not an
  Elixir expression — the exact closure/accumulator mechanics are ELIXIR-DEV's to write):
  1. Resolve `row` — the matrix entry for the function name being installed (fixed at
     fold time, one `Lua.set!` call per row; no runtime name lookup is needed since each
     wrapper is built for one specific row).
  2. Apply `row.required` to the call's argument list to compute the capability this
     particular call requires — either a `capability()` string (constant for 6 of the 8
     rows, or parameterised by the first argument for `:call_service`, §4.2) or `:none`
     (for `:now`/`:fail`, §5).
  3. Pass that computed value, together with `capabilities` (the grant set closed over
     from this `install/2` call, §4.4 below) and `row.name`, to `Capabilities.check!/3`
     (§2.4) — this is the single gate call every wrapper makes; on denial it raises and
     the wrapper never proceeds to step 4 (§6.1).
  4. Only if `check!/3` returns (i.e. the call was permitted, or `required` was `:none`),
     invoke `row.stub` with the same argument list and return its result as the Lua
     call's return value.
  `capabilities` is captured once per `install/2` call and closed over by every one of
  the 8 installed wrappers — the grant set is fixed for the lifetime of that `Lua.t()`,
  matching `Sandbox.new/0,1`'s "construction never fails, never mutates after" invariant
  style.

```
@spec install(lua :: Lua.t()) :: Lua.t()
```

- Retained for source compatibility with `Sandbox.new/1`'s existing unchanged call site
  (§1.1). Defined as `install(lua, Capabilities.new())` — i.e., installs all 8 functions
  with an empty grant set. Every production `Sandbox.new/0,1` VM therefore has all 8
  `platform.*` names present (satisfying AC1's closed-set enumeration against a real
  production sandbox) with the 6 gated ones permanently denying until some future
  requirement calls `install/2` directly with a populated grant set.

---

## 5. `now` and `fail` are ungated by design — required moduledoc statement (AC6, AC7)

This requirement's matrix (§4.1) gives both `:now` and `:fail` a `required` function that
always returns `:none`, meaning `Capabilities.check/3` (§2.4) never consults the grant
set for either — structurally identical in effect to REQ-152's own `platform.now`
binding statement (`req152-lua-time-denial.md` §5), extended here to `fail`.

**Required moduledoc content (verbatim in substance, both must appear in
`Letflow.Engine.Lua.Platform`'s moduledoc):**

- `now` — restates REQ-152's own text: "a pure time read with no state reach" (LUA-14);
  its absence of a capability requirement is "a POSITIVE design statement, not an
  omission."
- `fail` — new for this requirement: a script may always terminate itself; gating
  self-termination behind a capability would mean a script could be denied the ability
  to stop itself, which serves no isolation purpose (it does not reach any state,
  service, or variable) and would only complicate the one guaranteed way a script has
  of signaling its own failure back to the host.
- **Binding statement (both):** "A test that expects a gate on `now` or `fail` is
  reading the matrix wrong" (R-Co's own doc-comment framing, per the requirement text) —
  carried into the moduledoc so a future capability-matrix edit does not add a row that
  contradicts it.
- The full 8-row matrix (§4.1's table) must appear in the moduledoc in substance — not
  merely cross-referenced to this design doc — so `LUA-06`'s "every host function MUST
  check" is read correctly against the two rows that structurally never do, per AC8 (§7).

---

## 6. Denial is a raised Lua error AND a structured host-reportable value (AC2, AC3)

### 6.1 The raise (LUA-06's "MUST raise")

`Capabilities.check!/3` (§2.4), on denial, raises `Lua.RuntimeException` via its
keyword-list `exception/1` clause (§0). The keyword list passed to `raise` must carry
exactly these five keys (a description of the required shape, not an Elixir expression —
the exact `raise` call is ELIXIR-DEV's to write):

| Key | Value | Validated by the library? |
|---|---|---|
| `:scope` | `[:platform]` — the Lua-side location of the failing call | Yes — required by `exception/1`'s keyword-list clause |
| `:function` | `denial.function` — the atom name of the denied `platform.*` call | Yes — required by `exception/1`'s keyword-list clause |
| `:message` | A human-readable sentence stating which function was denied, the capability it required, and the capabilities the script's grant set actually held (rendering `denial.required` and `denial.granted`) | Yes — required by `exception/1`'s keyword-list clause |
| `:capability_required` | `denial.required` — the single missing capability string | No — not one of the three keys the clause validates or that `message/1` renders |
| `:capabilities_granted` | `denial.granted` — the calling script's full grant list at check time | No — not one of the three keys the clause validates or that `message/1` renders |

Per `deps/lua/lib/lua/runtime_exception.ex`'s keyword-list `exception/1` clause (§0):
only `:scope`, `:function`, `:message` are validated as present, but the **entire**
keyword list is retained, unmodified, as `%Lua.RuntimeException{original: <the list>}`.
`message/1` (used by `Exception.message/1`, what `LuaScriptAudit`'s `Executor` rescue
clause — §0 — already captures as a plain string) renders only the three official keys
into human-readable text; the two extra keys (`:capability_required`,
`:capabilities_granted`) ride along on `:original` unrendered, retrievable by any
caller with access to the raw exception struct (not just its rendered message).

This IS a Lua error observable from inside the script (LUA-06): a `pcall`/uncaught
propagation of this raise looks, from the script's perspective, exactly like any other
Lua runtime error — there is no separate code path or Elixir-only signaling that bypasses
the actual Lua-visible failure.

### 6.2 The structured, host-reportable value (LUA-06's three named fields; REQ-162's future source)

Two independent host-side access paths to the same three fields, deliberately:

1. **Non-raising path:** `Capabilities.check/3` (§2.4) returns `{:error, denial()}`
   directly — for any Elixir-side caller that is not going through a Lua call at all
   (e.g. a future manifest-validation step, REQ-158, or an admin/introspection surface).
2. **Raised-and-caught path:** anything that rescues `Lua.RuntimeException` (as
   `Executor.execute_with_manifest/2` already does today, unmodified — §0, §8) can read
   `exception.original[:capability_required]` and
   `exception.original[:capabilities_granted]` off the caught exception, in addition to
   `exception.original[:function]` (already validated present by the library itself).

This design does not change `Executor`'s current rescue clause (which only calls
`Exception.message/1`, discarding the structured fields) — that widening, if REQ-162
needs it, is REQ-162's own scope, not this requirement's. What this design guarantees is
that the structured data **exists on the exception struct already**, so REQ-162 has
something to read without this requirement needing to guess at REQ-162's own
consumption shape. See §11 OQ-2.

### 6.3 Why the keyword-list form, not a custom exception module

A bespoke `defexception` (e.g. `Letflow.Engine.Lua.Capabilities.DenialError`) was
considered and rejected: `Executor.execute_with_manifest/2`'s existing rescue clause
(§0) only pattern-matches `Lua.RuntimeException` and `Lua.CompilerException` — a custom
exception module would propagate uncaught through that rescue (since neither clause
matches it), crashing the calling process instead of returning `{:error, _}}` as every
other Lua-runtime failure does today. Since `executor.ex` is explicitly locked for this
run (owned by the concurrent WF02-REQ154-20260827 run) and out of this requirement's
`owned_modules`, this design must produce something `Lua.RuntimeException`-shaped
without needing that file to change — the keyword-list form (§6.1) is exactly that: a
real `Lua.RuntimeException`, matched by the existing rescue clause unchanged, carrying
extra data the library's own exception struct already has room for.

### 6.4 `call_service`'s denial names the specific service, not a blanket capability

Per §4.2, `denial.required` for a `call_service` denial is always the *fully
parameterised* string (`"service:call:billing"`), never the bare literal
`"service:call"` — there is no "family" or "prefix" capability anywhere in this design;
each service id is its own, distinct capability string, and a denial always names the
exact one that was missing.

---

## 7. Acceptance-criteria traceability (all 8, verbatim from `docs/requirements.yaml` REQ-157)

PROVENANCE (historical, not current decision authority):
| # | Acceptance criterion (verbatim) | Design element |
|---|---|---|
| 1 | "a test asserts the platform table exposes EXACTLY the eight functions of R-Co's matrix... and no others -- enumerated from inside a script" | §4.1 (8-row `@capability_matrix`, sole fold), §4.4 (`install/1` delegating to `install/2` with empty grant set, wired into every `Sandbox.new/0,1` VM unchanged); test enumerates via `pairs(platform)` from inside a real `Sandbox.new/0` script (§9) |
| 2 | "for EACH of the six gated functions there is a capability-denial test asserting a Lua error is raised when the grant is absent" | §2.4 `check!/3`, §4.1 matrix rows for the 6 gated functions, §6.1 raise mechanism; one test per function calling `Platform.install(lua, Capabilities.new())` then invoking each from a script with an empty grant set (§9) |
| 3 | "a denial's structured details include the function name, the capability required, and the capabilities granted -- all three asserted by test" | §2.3 `denial()` shape, §6.1/§6.2 both access paths; test asserts all three via `exception.original` after rescuing (§9) |
| 4 | "a test asserts platform.call_service('X') without a service:call:X grant produces a structured error" | §4.1 `:call_service` row, §4.2 parameterisation, §6.1/§6.2 (§9) |
| 5 | "a test asserts a service:call:alpha grant does NOT authorise platform.call_service('beta')" | §4.2, §2.2 `has?/2`'s exact-string-only matching (§9) |
| 6 | "a test asserts platform.now and platform.fail are callable with an EMPTY capability set" | §4.1 rows for `:now`/`:fail` (`required` always `:none`), §2.4 `check/3`'s `:none` short-circuit, §4.3 stub bodies (both actually execute past the non-existent gate); test calls both via `Platform.install(lua, Capabilities.new())` (or the production `Sandbox.new/0` path) and asserts no capability-denial raise occurs (§9) |
| 7 | "the moduledoc reproduces R-Co/src/lua/host_api/mod.zig's capability matrix including the stated rationale for now and fail being ungated" | §5 (required moduledoc content), §4.1 (the table to reproduce) |
| 8 | "mix test and mix compile --warnings-as-errors both pass with real output quoted" | Not a design-time artifact — ELIXIR-DEV's Step 2a / TEST-RUNNER's Step 4 responsibility |

---

## 8. Cross-module dependencies (full table)

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Engine.Lua.Capabilities` (new) | `Platform` → `Capabilities` | `Platform.install/2`'s fold calls `Capabilities.check!/3` per gated call; `call_service`'s matrix row calls `Capabilities.service_capability/1`. One-directional — `Capabilities` has no dependency back on `Platform` (§3). |
| `Letflow.Engine.Lua.Platform` (extended) | `Sandbox` → `Platform` (unchanged direction and call site, §1.1) | `Sandbox.new/1` still calls `Platform.install(lua)` (arity 1) exactly as REQ-152 left it; that function's *internal* behavior grows from installing 1 function to installing 8, invisibly to `Sandbox`. |
| `Lua` (`deps/lua`) | `Platform` → `Lua` | `Lua.set!/3` (installation, unchanged mechanism from REQ-152), `Lua.RuntimeException` (raised by `Capabilities.check!/3`, not by `Platform` directly — see §2.4/§6.1: the raise lives in `Capabilities`, since it is the module that knows the denial shape; `Platform`'s matrix rows call `check!/3` and let it raise). |
| `Executor` (REQ-153, locked this run) | consumes `Sandbox`/`Platform` transitively, unchanged | `execute_with_manifest/2`'s existing `rescue e in [Lua.RuntimeException, Lua.CompilerException]` clause requires no edit (§6.3, §8) — a capability denial raised from inside a script it runs propagates and is caught exactly like any other Lua runtime error already is today. |
| REQ-158 (manifest validation, LUA-07) | consumes `Capabilities.grant_set()` | A manifest's declared capabilities become a `grant_set()` via `Capabilities.new/1`, passed to `Platform.install/2` at whatever point REQ-158 wires load-time validation in. Not built here. |
| REQ-159/160 (real host-function bodies) | replace this design's `stub` functions | Each matrix row's `stub` (§4.3) is replaced with a real implementation; the `required` function and the matrix's closed-set shape (§4.1) do not change. |
| REQ-162 (capability state at failure) | reads `exception.original[:capability_required]` / `[:capabilities_granted]` | §6.2 — this design guarantees the fields exist on the raised exception; REQ-162 decides how to surface them, e.g. into an audit/event record. |

---

## 9. Test suite specification additions

| Test | Asserts | Acceptance criterion |
|---|---|---|
| `capabilities_test.exs`: `has?/2`/`add/2` | membership after `add`, `false` before | (supports AC2–AC6, unit-level) |
| `capabilities_test.exs`: `check/3` three-field shape | `{:error, %{function: _, required: _, granted: _}}` on denial, `:ok` on grant, `:ok` unconditionally when `required = :none` | AC3, AC6 |
| `capabilities_test.exs`: `service_capability/1` | `service_capability("billing") == "service:call:billing"` | AC4, AC5 |
| `platform_test.exs`: closed-set enumeration | a script using `pairs(platform)` (or equivalent introspection the runtime supports) against a real `Sandbox.new/0` VM returns exactly the 8 names in §4.1's table, no more, no fewer | AC1 |
| `platform_test.exs`: source-level single-fold guard | `platform.ex`'s source contains exactly one `Lua.set!(lua, [:platform,` occurrence (the fold's own call), guarding against a future hand-added 9th `Lua.set!` call bypassing the matrix | AC1 (structural half) |
| `platform_test.exs`: one denial test per gated function (6 cases) | `Platform.install(lua, Capabilities.new())` then calling each of `read_variable`/`write_variable`/`log`/`emit_event`/`get_instance_state`/`call_service` from a script raises `Lua.RuntimeException` | AC2 |
| `platform_test.exs`: denial structured-field assertions | rescuing the raise from any one of the 6, asserting `exception.original[:function]`, `[:capability_required]`, `[:capabilities_granted]` all present and correct | AC3 |
| `platform_test.exs`: `call_service` denial (no grant) | `platform.call_service("billing")` with an empty grant set raises, `capability_required == "service:call:billing"` | AC4 |
| `platform_test.exs`: `call_service` parameterisation (wrong service) | grant set `Capabilities.new(["service:call:alpha"])`; `platform.call_service("beta")` still raises, `capability_required == "service:call:beta"`, `capabilities_granted == ["service:call:alpha"]` | AC5 |
| `platform_test.exs`: `now`/`fail` callable with empty grant set | `Platform.install(lua, Capabilities.new())` (or plain `Sandbox.new/0`); `platform.now()` returns its normal ISO 8601 value (no raise); `platform.fail()` raises its own stub error (§4.3), NOT a capability-denial error (`exception.original[:capability_required]` is absent/nil, distinguishing the two raise shapes) | AC6 |
| `platform_test.exs`: moduledoc content | `Code.fetch_docs/1` on `Platform`, moduledoc contains the 8-row matrix in substance and the now/fail ungated rationale (§5) | AC7 |
| (regression, not a new acceptance criterion) `platform_test.exs`: REQ-152's existing `now/0` cases still pass unmodified | ISO 8601 parseability, exact-value injection via `TimeSource` | guards §4.3's "refactor, not behavior change" claim for `now` |
| (all of the above) | `mix test` and `mix compile --warnings-as-errors` pass, real output quoted | AC8 |

---

## 10. Invariants (new; extends REQ-151/REQ-152's `INV-SBX-*`/`INV-PLAT-*`)

- **INV-CAP-1:** `Letflow.Engine.Lua.Platform.install/2`'s matrix-driven fold is the
  ONLY call site under `lib/` that ever calls `Lua.set!(lua, [:platform, _], _)` — no
  `platform.*` global is ever installed by any other function, in this module or
  elsewhere. Enforced structurally (single fold) plus a source-level test guard (§9), not
  by a runtime check.
- **INV-CAP-2:** `@capability_matrix` has exactly 8 rows, one per name in §4.1's table,
  and every `platform.*` function's `required` capability (or `:none`) is defined in
  exactly one row — no function has two rows, no row names a function outside the closed
  set.
- **INV-CAP-3:** `Capabilities.check/3` and `check!/3` are the only functions that
  construct a `denial()` value or raise on behalf of a capability check — no gated
  matrix-row `stub` (§4.3) performs its own ad hoc capability comparison; every gate
  passes through these two functions.
- **INV-CAP-4:** `now` and `fail`'s matrix rows' `required` function always returns
  `:none`, unconditionally, regardless of call arguments — no future edit may make either
  conditional on argument values or on any grant-set content (§5's binding statement).

---

## 11. Open questions — not silently resolved

PROVENANCE (historical, not current decision authority):
**OQ-1 (non-blocking, provenance) — `R-Co/src/lua/capabilities.zig` and
`R-Co/src/lua/host_api/mod.zig` are not present in this checkout (§0).** This design's
capability-set shape (`has`/`add` semantics) and the 8-function matrix are both taken
from `docs/requirements.yaml` REQ-157's own restatement of those files' substance, not
from reading the files directly. If a future SECURITY-REVIEWER or REVIEWER pass has
access to the original R-Co source and finds a material difference (e.g. a capability
check ordering invariant, or a grant-set data structure with more operations than
has/add), that difference should be reconciled against this design rather than assumed
absent. Not blocking because the requirement text itself is explicit and detailed enough
to build from; flagged so a future reader does not assume this design was checked
against the original Zig source when it was not.

**OQ-2 (non-blocking, forward-looking) — exact REQ-162 consumption shape of
`exception.original[:capability_required]`/`[:capabilities_granted]` is undecided.**
§6.2 guarantees the fields exist on the raised exception; it does not decide whether
REQ-162's "capability state at failure" field is the denial map verbatim, a rendered
string, or something else Executor-adjacent needs to change to surface (per §6.3,
`Executor`'s own rescue clause would need widening to capture more than
`Exception.message/1` if REQ-162 wants the structured map to reach, say, an audit
record — that widening is not built here). Left for REQ-162 to resolve; not this
requirement's scope per its own "NOT IN THIS REQUIREMENT" text.

**OQ-3 (non-blocking, mechanism choice) — enumeration mechanism for AC1's "enumerated
from inside a script."** §9 proposes `pairs(platform)` (Lua's standard table-iteration
idiom) as the enumeration mechanism; this design does not verify that the installed
`platform` global (built via repeated `Lua.set!(lua, [:platform, name], fn)` calls,
which auto-allocate an intermediate table per `do_set_nested`'s `nil` branch, per
`deps/lua/lib/lua.ex` read in §0) is actually iterable via `pairs` in this specific
Lua runtime (as opposed to, e.g., needing a metatable to iterate function-valued
fields) — a spike ELIXIR-DEV should perform early in Step 2a; if `pairs` does not
enumerate function values on this table as expected, an equivalent mechanism (e.g. an
explicit `platform._known_functions` introspection list installed alongside, or a
purely Elixir-side test reading `Lua.get!/2` for exactly the 8 names) should be
substituted, with the substitution noted in that step's handoff rather than silently
changing AC1's tested claim.

---

## 12. What this design does NOT do (explicit non-goals, matching requirement's "NOT IN THIS REQUIREMENT")

- No real implementation of `read_variable`, `write_variable`, `log`, `emit_event`,
  `get_instance_state`, or `call_service` beyond a stub that proves the gate ran (§4.3) —
  REQ-159/160/161.
- No change to `platform.now`'s implementation, `TimeSource` behaviour, or
  `SystemClock` — REQ-152, unchanged.
- No change to `Letflow.Engine.Lua.Sandbox` or `Letflow.Engine.Lua.Executor` — §1.1, §8.
- No manifest representation, load-time validation, or hash computation — REQ-158.
- No resolution of how REQ-162 ultimately surfaces the structured denial fields beyond
  guaranteeing they exist on the raised exception (§6.2, §11 OQ-2).
