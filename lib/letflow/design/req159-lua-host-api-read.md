# Design: REQ-159 — Lua host API 1/2, read path (`platform.read_variable`,
`platform.get_instance_state`, `platform.log`) (LUA-11 read half, LUA-13)

**Requirement:** REQ-159
**Stage:** S5
**Owner (design):** CODE-DESIGNER
**Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-27
**Extends:** `lib/letflow/design/req157-lua-capability-model.md` (REQ-157, the capability
matrix and `install/1,2` fold this design adds a new arity to) and
`lib/letflow/design/req150-lua-number-marshalling.md` (REQ-150, whose §2/§3 this design
cites and does not re-derive).

---

## 0. Sources read for this design

- `handoffs/WF02-REQ159-20260827/step-01-code-designer.json` (`context.requirement_text`,
  `task.acceptance_criteria`)
- `docs/requirements.yaml` REQ-159 entry (full `description` and 8-item
  `acceptance_criteria`, quoted verbatim in §8)
- `lib/letflow/engine/lua/platform.ex` (current state — REQ-157's 8-row capability
  matrix, `install/1,2`'s fold, the six gated stubs, all read directly, not assumed)
- `lib/letflow/design/req157-lua-capability-model.md` (`Capabilities.check!/3`'s exact
  signature, the existing matrix rows' `required` values for the 3 functions in scope)
- `lib/letflow/design/req150-lua-number-marshalling.md` §2 (the normative marshalling
  rule) and §3 (the owning module/function this design must create, not reinvent)
- `lib/letflow/engine/lua/capabilities.ex` (confirmed `check!/3`'s raise shape and
  `grant_set()` type match the design doc)
- `lib/letflow/engine/lua/sandbox.ex` (confirmed `Sandbox.new/1`'s pipeline calls
  `Platform.install(lua)` — arity 1, no execution-context argument, unchanged since
  REQ-152; this file is **not** in this requirement's `owned_modules` and this design
  proposes no edit to it — see §2.3)
- `lib/letflow/engine/lua/executor.ex` (confirmed `execute_with_manifest/2,3` and
  `run_script/3` carry no instance/trace/prefix argument today — the execution context
  this design needs does not yet exist anywhere on this call path; also **not** in this
  requirement's `owned_modules`, not touched)
- `lib/letflow/instances.ex` (`Letflow.Instances.get_by_id/2` — the established
  cast-then-`Repo.get(..., prefix: prefix)` pattern this design's `get_instance_state`
  reuses, with `prefix` always an explicit caller-supplied `opts` value, never derived
  from the id argument)
- `lib/letflow/event_store/instance_projection.ex` (confirmed `:variables` is a plain
  `:map`/jsonb field, `:status` is an `Ecto.Enum` with values
  `active/completed/cancelled/error` mapping to uppercase strings, and the schema has
  **no** `@schema_prefix` — every read needs an explicit `prefix`)
- `docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md` (e) — neither
  runtime gets database access directly; host functions receive already-resolved
  values; the tenant prefix is supplied by the calling engine code, never derived
  inside a script

---

## 1. Scope boundary

**In scope:**
1. Real implementations replacing 3 of the 6 `:not_yet_implemented`-stub matrix rows:
   `read_variable`, `get_instance_state`, `log` (§4–§6).
2. `Letflow.Engine.LuaNumberMarshalling` — new module, per REQ-150 §3's naming, created
   here because REQ-159 is the first of the two sibling requirements (REQ-159/160) to
   need it (§3).
3. The execution-context threading mechanism these 3 functions need — a new `install/3`
   arity on `Letflow.Engine.Lua.Platform`, additive to the existing `install/1,2` (§2).

**Out of scope (unchanged, per requirement text):**
- `write_variable`, `call_service`, `emit_event` — REQ-160. Their matrix rows, stub tags,
  and `stub_spec` values are untouched by this design.
- `now`, `fail` — already real (REQ-152) or intentionally stubbed with terminal behavior
  (REQ-157); untouched.
- `required_capability_spec` values for any of the 8 rows — REQ-157's
  `"variable:read"` / `"instance:read"` / `"audit:log"` constants for these 3 functions
  are confirmed correct as-is (§2.4) and are not edited.
- `lib/letflow/engine/lua/sandbox.ex`, `lib/letflow/engine/lua/executor.ex`, and any
  engine-level call site that would invoke `Executor.execute_with_manifest/2,3` with a
  real instance's data — none of these files are in this requirement's `owned_modules`,
  and none is edited by this design. Wiring the production call path so a real
  `execution_context` actually reaches `install/3` at runtime is **explicitly deferred**,
  the same way REQ-158 built `Manifest.to_grant_set/1` but left "whether/when a caller
  actually invokes `Platform.install/2` with this returned grant set... not built here."
  See §2.3 and Open Question OQ-1.

---

## 2. Execution-context threading — the key decision

### 2.1 The problem, restated precisely

`read_variable`, `get_instance_state`, and `log` all need to know, for the *current
script execution*, at least: which tenant schema to query (`prefix`), which instance is
running (`instance_id`), a trace/correlation id, and the identity of the script itself
(`script_identity`) — none of which may come from the Lua call's own arguments, because a
script controls those arguments completely. A `read_variable("x")` call's only
script-supplied argument is `"x"`; a `get_instance_state(id)` call's only script-supplied
argument is `id` (see §5.1 for why that argument is checked against, and must equal,
`execution_context.instance_id` before anything else happens — a script may only ever
name its own instance, never another one, so accepting the argument at all does not widen
scope beyond "self"). `log(level, message, context)`'s three arguments are all
script-authored content, never identity claims.

### 2.2 Two shapes considered

**(a) Closure capture at `install/_` time — CHOSEN.** Exactly the pattern REQ-155/156
already use for `capabilities` (`install/2`'s `capabilities` argument is "captured once
per `install/2` call and closed over by every one of the 8 installed wrappers" — current
moduledoc, §"Composition point"). A new value, `execution_context` (§2.4), is captured
the same way, by a new `install/3` arity, at the exact moment the `Lua.t()` is being
built for one specific script execution. The Lua-callable wrapper functions installed by
the fold read `execution_context` from their closure, never from the Lua call's argument
list. This means there is no code path — not even a malicious or buggy one on the Lua
side — through which a script's own arguments can *become* the `execution_context`: the
value is fixed before the sandbox is ever handed to `Lua.eval!/2`, and Lua code has no
mechanism to reach into or replace a closure captured by a BEAM function referenced from
`_G.platform`.

**(b) Passed as an extra Lua-call argument, host-injected before the script's own
arguments** — REJECTED. Would require either (i) the calling engine code prepending a
hidden first argument to every `platform.*` call, which does not compose with
`tv-labs/lua`'s `Lua.set!/3` wrapper shape (the installed wrapper, per the existing
single-parameter anonymous-function shape at `platform.ex:187`, receives exactly the Lua
call's own argument list as its one parameter — nothing else), or
(ii) a Lua-visible global (e.g. `_G.__execution_context__`) the wrapper reads — which
would put a tenant-boundary-relevant value on a path a sandboxed script can enumerate,
overwrite, or shadow (`_G` is exactly the surface `Letflow.Engine.Lua.Sandbox` exists to
restrict, and adding a new sensitive global there widens the attack surface REQ-151
built to shrink it). Rejected outright — not merely deprioritized — because it reopens a
sandbox-escape-adjacent surface for no benefit over (a).

**(c) A fresh `Letflow.Instances.get_by_id/2` call per `read_variable` invocation,
re-deriving `instance_id`/`prefix` from... something** — REJECTED as `read_variable`'s
mechanism specifically. There is no script-trustworthy source for `instance_id`/`prefix`
to re-derive from at that call site (the whole point of §2.1), and a fresh per-call
`Repo` round trip for a value the calling engine code already holds (the instance's own
`InstanceProjection.variables`, resolved once before the script ever starts) is pure
waste. `read_variable` therefore reads from an already-resolved variables map captured
in the execution context (§4.1), never from a fresh query. `get_instance_state` is
different in kind — see §5 for why it legitimately does perform a `Repo` read, gated
entirely on a context-supplied `prefix`.

### 2.3 What `install/3` gains, exactly

```
@type execution_context :: %{
        instance_id: String.t() | nil,
        prefix: String.t() | nil,
        trace_id: String.t() | nil,
        script_identity: String.t() | nil,
        variables: map()
      }
```

- `instance_id` — the UUID string of the instance the script is running on behalf of.
  Used only for tagging `log` entries and for populating `get_instance_state`'s own
  "self" case if a future caller wants it; **never** used to decide which row
  `get_instance_state` reads (that argument is script-supplied, by design — §5).
- `prefix` — the tenant's Postgres schema name. The **only** value `get_instance_state`
  is permitted to pass to `Repo.get/3`'s `prefix:` option (§5.2). Never derived from any
  Lua-call argument, ever, on any of the 3 functions this design covers.
- `trace_id` — an opaque correlation string threaded onto every `log` entry (§6.1).
- `script_identity` — an opaque string identifying the script/manifest being executed
  (e.g. a manifest's `script_id`, REQ-158), threaded onto every `log` entry (§6.1). Not a
  capability, not consulted by `Capabilities.check!/3` — purely an audit tag.
- `variables` — the instance's already-resolved `InstanceProjection.variables` map
  (native Elixir terms, already JSONB-decoded), exactly as `read_variable` reads from
  (§4.1). Supplied once, at context-construction time, by whatever caller already holds
  the `InstanceProjection` — never re-queried by `read_variable` itself.

`nil` is deliberately permitted on every field except `variables` (which defaults to
`%{}`) so that `install/1`/`install/2`'s existing, unchanged callers (every current test
exercising `now`/`fail`/capability-denial, and any future caller that has no real
instance context available) keep compiling and behaving exactly as before — see below.

```
@spec empty_execution_context() :: execution_context()
```

Returns `%{instance_id: nil, prefix: nil, trace_id: nil, script_identity: nil,
variables: %{}}` — the sentinel used by `install/1` and `install/2` (§2.3.1) and by any
of the 3 real implementations to detect "no execution context was supplied" and fail with
a structured, labeled error rather than crash on a `nil` where a `String.t()` was
expected (§4.2, §5.3, §6.2).

```
@spec install(lua :: Lua.t(), capabilities :: Capabilities.grant_set(),
              execution_context :: execution_context()) :: Lua.t()
```

The single fold (§2.3.1, `install/2`'s existing body, unchanged in structure) gains one
more captured value. Every one of the 8 installed wrappers now closes over
`capabilities` **and** `execution_context`; only the 3 wrappers for `read_variable`,
`get_instance_state`, `log` actually read `execution_context` in their `stub_fun` bodies
— the other 5 (`call_service`, `write_variable`, `emit_event`, `now`, `fail`) ignore it
completely, exactly as they ignore `capabilities` at the `run_stub/3` level today.

#### 2.3.1 Backward compatibility: `install/1` and `install/2` are unchanged in signature

```
@spec install(lua :: Lua.t()) :: Lua.t()
@spec install(lua :: Lua.t(), capabilities :: Capabilities.grant_set()) :: Lua.t()
```

- `install/1` — unchanged definition, `install(lua, Capabilities.new())`, which now
  itself becomes `install(lua, Capabilities.new(), empty_execution_context())` one level
  down. `Sandbox.new/1`'s existing call site (`sandbox.ex`, unedited) is therefore
  unaffected — every production VM still gets `read_variable`/`get_instance_state`/`log`
  installed, but with an empty execution context until some future requirement wires a
  real one through (Open Question OQ-1, below).
- `install/2` — unchanged definition, now `install(lua, capabilities,
  empty_execution_context())`. Every existing REQ-157 test calling `Platform.install(lua,
  Capabilities.new())` (or a non-empty grant set) for **capability-denial** assertions is
  unaffected: `Capabilities.check!/3` runs and raises *before* any of the 3 real bodies
  ever sees the empty execution context (§2.3, fold ordering unchanged from REQ-157 —
  capability check first, function body second). Only a *granted* call to one of the 3
  real functions, made through `install/1` or `install/2` rather than the new `install/3`,
  would observe the empty context and get this design's structured "no execution context"
  error (§4.2/§5.3/§6.2) instead of real behavior — this is intentional: it is the same
  "not wired to production yet" gap REQ-158 left for the capability grant set, made
  equally visible here rather than papered over with a fabricated default `instance_id`.

### 2.4 Why this is sufficient for the tenant-isolation requirement

A script's only way to influence `execution_context` would be to influence what argument
the *caller of `install/3`* passes in — and the caller of `install/3` is trusted engine
code (whatever future requirement wires the production path, per OQ-1), running entirely
outside the sandboxed `Lua.t()`, before the script's own text is ever evaluated. No value
inside `execution_context` is ever assigned from a `Lua.eval!/2` return value, a Lua
table the script constructed, or any of the 3 functions' own Lua-call arguments. This
holds structurally (the closure is built once, before `Lua.eval!/2` runs, and Lua code
has no reflection into the enclosing BEAM closure), not merely as an implementation habit
— matching REQ-155/156's own `capabilities`-closure precedent exactly.

---

## 3. `Letflow.Engine.LuaNumberMarshalling` (REQ-150 §3)

**Module:** `Letflow.Engine.LuaNumberMarshalling`
**File:** `lib/letflow/engine/lua_number_marshalling.ex` (created by this requirement,
per REQ-150 §3's explicit instruction that REQ-159/160 create it rather than each
inventing its own conversion)

```
@spec to_lua(value :: term()) :: term()
@spec from_lua(value :: term()) :: term()
```

- `to_lua/1` — the read-path conversion (REQ-150 §2.2). For every case this rule covers
  (`integer()`, `float()` including whole-number floats, `nil`) this is the **identity
  function** — returns its argument unchanged. Per REQ-150 §2.2/§2.3, no caller may
  inspect a float's fractional part and decide to hand Lua an integer instead; codifying
  identity explicitly (rather than omitting numeric handling) is what REQ-150 §3 states
  keeps a future maintainer from "helpfully" adding a coercion. Non-numeric/non-`nil`
  terms (`String.t()`, `boolean()`, `map()`, `list()`) also pass through unchanged — this
  rule has nothing to say about them, and this function is not the place to add anything
  that would.
- `from_lua/1` — the write-path conversion (REQ-150 §2.1). Identity function for the same
  numeric/`nil` cases, for the same reason, in the reverse direction. Not exercised by
  this requirement's own 3 functions (none of them write a value back — that is REQ-160's
  `write_variable`) but created here per REQ-150 §3's instruction that the module is
  created once, by whichever of REQ-159/160 lands first, with both functions present from
  the start so the sibling requirement only ever adds call sites, never a second
  definition.

`read_variable` (§4.1) is this requirement's own proof that the central rule is applied,
not merely referenced: it calls `to_lua/1` on every value it returns to a script,
including the round-trip acceptance test (REQ-159 AC6, §8) that stores an integer and a
float and asserts the subtype survives.

No other module under `lib/letflow/engine/` is touched to create this one (REQ-150 §6's
own scope note; this module is new, standalone, with no dependency on
`Letflow.Engine.VariableMerge` or any other existing module).

---

## 4. `platform.read_variable(name)` (LUA-11 read half)

### 4.1 Real implementation

```
@spec read_variable(name :: term(), execution_context :: Platform.execution_context()) ::
        [term()]
```

(Internal helper signature — not itself installed via `Lua.set!/3`; `run_stub/3`'s
`:read_variable` clause below is the actual dispatch target, receiving the Lua call's
full argument list plus the closed-over `execution_context`.)

Control flow, in prose:

1. The Lua call's first argument is expected to be a string (`name`). If it is not a
   binary, the function returns Lua `nil` (a malformed call is treated the same as
   reading a variable that does not exist — LUA-11's text names only "current value or
   nil" as the two outcomes, and this design does not introduce a third, raising one for
   a bad argument type).
2. Looks up `name` as a key in `execution_context.variables` (the already-resolved map,
   §2.3) via a plain map lookup with a `nil` default. **No `Letflow.Repo` call is made**
   — the instance's variables were already resolved once, by whatever caller constructed
   `execution_context`, before the script began executing (§2.2(c)).
3. If `execution_context.variables` lookup produces a value, applies
   `Letflow.Engine.LuaNumberMarshalling.to_lua/1` to it (§3) and returns it as the single
   Lua-visible return value.
4. If the key is absent, returns Lua `nil` — the same outcome as step 1's malformed-call
   case, both satisfying LUA-11's "current value or nil" literally.

This function never raises and never touches `Letflow.Repo` — the tenant boundary is
enforced upstream, at whatever point `execution_context.variables` was populated (by
`Letflow.Instances.get_by_id/2` or equivalent, with an explicit `prefix`, before the
script runs), not inside this function.

### 4.2 Missing-context behavior

If `execution_context` is the `empty_execution_context()` sentinel (§2.3.1) —
`variables == %{}` — `read_variable` behaves identically to "variable not set": returns
`nil`. This is a deliberate simplification: an empty variables map is observationally
identical to "no execution context was wired," and LUA-11's contract (current value or
`nil`) has no third outcome to spend on distinguishing them. A caller that needs to tell
the two apart (e.g. a future diagnostic) should inspect `execution_context` directly, not
`read_variable`'s return value.

### 4.3 Capability requirement — unchanged

`required: "variable:read"` (constant, ignores arguments) — confirmed present, unedited,
in the current `@capability_matrix` (`platform.ex:118`). This design changes only the
row's `stub` tag, from `:not_yet_implemented` to a new `:read_variable` tag whose
`run_stub/3` clause calls §4.1's logic — `required_capability/2`'s dispatch for this row
is untouched (a bare capability string still hits the existing private clause that
matches on a binary `required` value and returns it unchanged, `platform.ex:212`).

---

## 5. `platform.get_instance_state(instance_id)`

### 5.1 Default scope: a script may only read its own instance's state (decided)

`get_instance_state`'s script-supplied `instance_id` argument is checked against
`execution_context.instance_id` (§2.3) **before** anything else. The script-supplied
value is accepted only when it is exactly equal to `execution_context.instance_id` —
i.e. a script may read only the state of the instance it is itself running on behalf of,
never any other instance, even one owned by the same tenant. Any other value — whether
or not it names a real instance in this tenant's schema — is rejected uniformly with a
structured `reason: "forbidden"` error (§5.3), and **no `Repo` lookup is attempted** for
that value at all.

This is a default-scope decision (ORCH, REWORK ITERATION 1 of this design), not an open
question: nothing in REQ-159's requirement text, its 8 acceptance criteria
(`docs/requirements.yaml`), LUA-11/LUA-13's text, decision 0014, or REQ-157's capability
matrix asks for — or even mentions — a script reading any instance's state other than its
own. `instance:read` is a capability grant (whether a script may call this function at
all), not an authorization to name an arbitrary instance id; granting the capability does
not by itself widen *which* instance may be read. Least privilege therefore applies:
absent an explicit requirement for broader (e.g. same-tenant cross-instance, or
parent/child) access, the function is scoped to "self" only. No parent/child or
ownership relationship between instances is established anywhere in the artifacts read
for this design (§0) — if a future requirement needs cross-instance reads, it must
introduce and cite that concept explicitly, with its own capability/authorization design,
rather than this design inventing one.

The tenant boundary itself is still enforced exactly as before, independently of this
scope check: the `prefix` the eventual `Repo.get/3` call uses (for the one case that
passes the self-check) is always `execution_context.prefix`, never anything derived from
the `instance_id` argument (§5.2 step 3).

### 5.2 Real implementation

```
@spec get_instance_state(args :: [term()], execution_context :: Platform.execution_context()) ::
        [term()]
```

Control flow, in prose, mirroring `Letflow.Instances.get_by_id/2`'s three-way outcome,
plus the self-scope check from §5.1 applied first:

1. If `execution_context.prefix` is `nil` (the empty-context sentinel, §2.3.1) — returns
   the two-value Lua result `[nil, error_table]` (§5.4) with `reason: "no_execution_context"`,
   without attempting any `Repo` call. This is the "not wired to production yet" case
   (§2.3.1), surfaced as a structured error rather than a `FunctionClauseError` on a `nil`
   prefix reaching `Repo.get/3`.
2. Otherwise, takes the Lua call's first argument as `instance_id`. If it is not a
   binary, or `Ecto.UUID.cast/1` rejects it, returns `[nil, error_table]` with
   `reason: "invalid_id"` — mirrors `Letflow.Instances.get_by_id/2`'s `{:error,
   :invalid_id}` arm, no round trip to the database for a value that cannot be a valid
   id. This check runs before the self-scope check (step 3) so a malformed argument is
   always reported as `"invalid_id"`, never `"forbidden"`.
3. Otherwise, compares `instance_id` (cast) against `execution_context.instance_id`
   (§5.1). If they are not equal — regardless of whether `instance_id` names a real
   instance anywhere in this tenant's schema — returns `[nil, error_table]` with
   `reason: "forbidden"`, and **no `Repo` call is made** for this arm. This is the only
   place this function's outcome depends on anything other than "does this row exist,"
   and it is checked strictly before any database access.
4. Otherwise (`instance_id == execution_context.instance_id`), calls
   `Letflow.Repo.get(Letflow.EventStore.InstanceProjection, instance_id, prefix:
   execution_context.prefix)`. A `nil` result (row absent — e.g. `execution_context` names
   an instance id that was since deleted, or was never a real row; the same INV-5 shape
   `Letflow.Instances.get_by_id/2` already documents) returns `[nil, error_table]` with
   `reason: "not_found"`.
5. Otherwise, builds a Lua table (§5.4, success shape) from the found
   `InstanceProjection`'s `:status` (its `Ecto.Enum` string form, e.g. `"ACTIVE"`) and
   `:variables` (each value passed through `LuaNumberMarshalling.to_lua/1`, §3, same as
   `read_variable`) and returns `[state_table]`.

No arm of this function raises. Steps 1–4's failure arms are ordinary structured returns,
exactly satisfying "MUST return a structured error (not a raise propagating to the Lua
caller as an unhandled exception)."

### 5.3 Structured-error shape

```
@type get_instance_state_error :: %{reason: String.t()}
```

`reason` is one of `"no_execution_context"`, `"invalid_id"`, `"forbidden"`, `"not_found"`
— four distinct strings, each naming a genuinely different failure cause, so a script (or
a test asserting on this function) can distinguish "you gave me garbage" from "that is not
your instance" from "that id does not exist here" from "the host never told me who I am."
`"forbidden"` is returned for any `instance_id` other than
`execution_context.instance_id` (§5.1, §5.2 step 3), independent of whether that other id
exists — a real, existing sibling instance and a fabricated id are indistinguishable in
this function's response, by design, so a script cannot use the error to probe which
other ids exist. No `message` field is added beyond `reason` — LUA-13's structured-entry
requirement (§6) is the function that owns human-readable text; this one's contract is
machine-checkable reason codes.

### 5.4 Lua-visible return shapes

- Success: a single Lua table return value, `[table]`, with keys `status` (string) and
  `variables` (a Lua table produced from the `InstanceProjection.variables` map, each
  leaf value passed through `to_lua/1`).
- Failure: two Lua return values, `[nil, error_table]`, following the common Lua idiom
  `local state, err = platform.get_instance_state(id)` — `error_table` has the single key
  `reason` (§5.3). A script that ignores the second return value simply observes `nil`
  for `state`, consistent with LUA-13-adjacent host functions elsewhere in this codebase's
  design vocabulary (REQ-160's `call_service`, which returns a structured error rather
  than raising, uses the same two-value convention — not duplicated here, cited for
  consistency).

### 5.5 Capability requirement — unchanged

`required: "instance:read"` (constant, ignores arguments) — confirmed present, unedited,
at `platform.ex:122`. Only the row's `stub` tag changes, from `:not_yet_implemented` to a
new `:get_instance_state` tag dispatching to §5.2's logic.

---

## 6. `platform.log(level, message, context)` (LUA-13)

### 6.1 Real implementation

```
@spec log(args :: [term()], execution_context :: Platform.execution_context()) :: [term()]
```

Control flow, in prose:

1. Reads the Lua call's three arguments positionally: `level` (expected string, one of
   `"debug"`, `"info"`, `"warn"`, `"error"`), `message` (expected string), `context`
   (any Lua value — typically a table, already converted to an Elixir term by
   `tv-labs/lua`'s own argument-marshalling at the call boundary, the same mechanism
   every other `platform.*` wrapper's `args` list already benefits from; no additional
   conversion is applied here beyond what the runtime performs on the way in).
2. Maps `level` to the corresponding `Logger` level atom (`"warn"` → `:warning`, matching
   Elixir's own `Logger` naming; the other three map directly). An unrecognized `level`
   string falls back to `:info`, tagged with an extra `original_level` metadata field
   carrying the unrecognized string verbatim — so a malformed level is visible in the
   emitted entry rather than silently dropped or raised on.
3. Emits one structured entry via `Logger.log/3`, with `message` as the log message and a
   metadata keyword list carrying, at minimum: `script_identity:
   execution_context.script_identity`, `instance_id: execution_context.instance_id`,
   `trace_id: execution_context.trace_id`, and `context: context` (the script-supplied
   structured payload, passed through as-is — this function does not apply
   `LuaNumberMarshalling` to `context`'s contents, since `context` is being *written* to a
   log sink, not round-tripped through JSONB variable storage; REQ-150's rule governs
   variable marshalling specifically, not arbitrary log payloads).
4. Returns `[]` (no Lua-visible return value) — `platform.log` is a pure side-effecting
   call in R-Co's own semantics (LUA-13's text names no return value).

This function never raises for any input shape — a non-string `message`/`level` is
coerced to its `inspect/1` form before being handed to `Logger.log/3` rather than
crashing the calling script over a logging call.

### 6.2 Missing-context behavior

When `execution_context` is the empty sentinel (§2.3.1), `script_identity`/`instance_id`/
`trace_id` are all `nil` — the emitted entry still carries all three metadata keys, with
`nil` values, rather than omitting them. This keeps the entry's shape stable (a consumer
can always expect the three keys to be present) while still making the "no real context
was ever wired in" condition visible in the emitted data itself, exactly as §4.2/§5.3
handle the same condition for the other two functions.

### 6.3 Structured-entry requirement, restated against LUA-13's acceptance text

"Log entry appears with correct correlation IDs" (LUA-13's acceptance) is satisfied by
step 3's three metadata keys being sourced exclusively from `execution_context` — never
from the script's own arguments, since a script controlling its own claimed identity or
instance id would defeat the entire point of an audit trail. This mirrors §2's tenant-
boundary discipline applied to auditability rather than data access: the *content*
(`message`, `context`) is script-authored, but the *correlation identity* the entry is
tagged with is host-authored, unconditionally.

### 6.4 Capability requirement — unchanged

`required: "audit:log"` (constant, ignores arguments) — confirmed present, unedited, at
`platform.ex:120`. Only the row's `stub` tag changes, from `:not_yet_implemented` to a
new `:log` tag dispatching to §6.1's logic.

---

## 7. Matrix and fold changes, precisely

### 7.1 `stub_spec` type — three new tags

```
@type stub_spec :: :now | :fail | :read_variable | :get_instance_state | :log
                  | :not_yet_implemented
```

`:not_yet_implemented` is retained (still used by `call_service`, `write_variable`,
`emit_event` — REQ-160's rows, unedited by this design).

### 7.2 `@capability_matrix` — 3 rows edited, `required` unchanged, `stub` tag only

| `name` | `required` (unchanged) | `stub` (before → after) |
|---|---|---|
| `read_variable` | `"variable:read"` | `:not_yet_implemented` → `:read_variable` |
| `get_instance_state` | `"instance:read"` | `:not_yet_implemented` → `:get_instance_state` |
| `log` | `"audit:log"` | `:not_yet_implemented` → `:log` |

The other 5 rows (`call_service`, `write_variable`, `emit_event`, `now`, `fail`) are
copied verbatim, unedited, into the new matrix literal.

### 7.3 `run_stub/3` — signature widens by one argument; INV-CAP-1 unaffected

```
@spec run_stub(stub_spec(), atom(), [term()], Platform.execution_context()) :: [term()]
```

`run_stub/3` becomes `run_stub/4`, adding `execution_context` as a trailing argument
threaded from `install/3`'s fold (§2.3) alongside the existing `capabilities`/`args`
threading. Three new clauses are added:

- `run_stub(:read_variable, _function_name, args, execution_context)` — dispatches to
  §4.1.
- `run_stub(:get_instance_state, _function_name, args, execution_context)` — dispatches
  to §5.2.
- `run_stub(:log, _function_name, args, execution_context)` — dispatches to §6.1.

The existing `:now`, `:fail`, `:not_yet_implemented` clauses gain the same fourth
parameter positionally but ignore it (`_execution_context`), identical in spirit to how
they already ignore `_args` in the `:now` clause today. **INV-CAP-1** (single
registration point) and **INV-CAP-2** (exactly 8 rows) are unaffected — no new
`Lua.set!/3` call site is introduced; the fold in `install/3` still calls it exactly
once per row, same as `install/2` does today.

### 7.4 The fold itself — one line changes

`install/3`'s fold body is `install/2`'s existing fold body with `execution_context`
closed over alongside `capabilities`, and `run_stub/3`'s call site widened to
`run_stub/4`. No other structural change to the `Enum.reduce/3` shape.

---

## 8. Traceability — REQ-159's 8 acceptance criteria

| # | Acceptance criterion (docs/requirements.yaml REQ-159, verbatim/paraphrased) | Design element |
|---|---|---|
| 1 | `read_variable` returns the current value for a set variable and `nil` for an unset one (LUA-11 read-half text) | §4.1 steps 2–4 |
| 2 | `log` emits a structured entry carrying script identity, instance ID, and trace ID — all three asserted individually (LUA-13's own acceptance) | §6.1 step 3, §6.3 |
| 3 | `get_instance_state` returns instance state for a valid instance and a structured error (not a raise) for an invalid one — "valid" scoped to the script's own instance by default (§5.1); any other instance id, real or not, is uniformly `"forbidden"`, never distinguished from a genuinely nonexistent one | §5.1, §5.2 (all 5 steps), §5.3, §5.4 |
| 4 | Each of the 3 functions has a capability-denial test (missing `variable:read`/`instance:read`/`audit:log` each raises a Lua error) | §4.3, §5.5, §6.4 — `required` unchanged, `Capabilities.check!/3` still runs first in the fold (§7.4), unedited ordering from REQ-157 |
| 5 | Number conversion uses REQ-150's named module/function; moduledoc cites REQ-150's normative section by number; no second conversion rule introduced | §3 (module/function creation), §4.1 step 3, §5.2 step 5 (both call sites), moduledoc instruction in §3's closing paragraph |
| 6 | A test round-trips at least one integer and one float through `read_variable`, asserting the subtype matches REQ-150's rule | §3 closing paragraph (the design's own note that this is `read_variable`'s job); §9 test spec names this case explicitly |
| 7 | No host function in this requirement calls `Letflow.Repo` with a prefix derived from script-supplied input; moduledoc states the tenant prefix is supplied by the calling engine code (decision 0014 (e)) | §2 (entire section, in particular §2.4), §4.1 (no `Repo` call at all), §5.1–§5.2 (prefix always `execution_context.prefix`) |
| 8 | `mix test` and `mix compile --warnings-as-errors` both pass with real output quoted | Not a design-time artifact — ELIXIR-DEV/TEST-RUNNER responsibility at Steps 2/4, same convention as REQ-157's own §8 traceability row |

---

## 9. Cross-module dependencies

| Module | Direction | Nature of dependency |
|---|---|---|
| `Letflow.Engine.Lua.Platform` (extended) | → `Letflow.Engine.LuaNumberMarshalling` (new) | `read_variable`/`get_instance_state` call `to_lua/1` on every returned variable value (§4.1, §5.2) |
| `Letflow.Engine.Lua.Platform` (extended) | → `Letflow.EventStore.InstanceProjection`, `Letflow.Repo` | `get_instance_state` only (§5.2) — the sole one of these 3 functions that performs any database read; `read_variable`/`log` touch neither |
| `Letflow.Engine.Lua.Platform` (extended) | → `Letflow.Engine.Lua.Capabilities` | Unchanged from REQ-157 — `check!/3` still the single gate call per wrapper (§7.4) |
| `Letflow.Engine.Lua.Platform` (extended) | → `Logger` (stdlib) | `log`'s only new external dependency (§6.1) |
| (future, not built here) | → `Letflow.Engine.Lua.Platform.install/3` | Whatever requirement wires the production execution context (OQ-1) becomes the first real caller of `install/3` with a non-empty `execution_context` |

---

## 10. Invariants carried forward / added

- **INV-CAP-1, INV-CAP-2** (REQ-157) — unaffected, see §7.3–§7.4.
- **INV-CAP-4** (`now`/`fail` ungated) — unaffected; this design does not touch either
  row.
- **New, this design:** the `execution_context` value installed wrappers close over is
  fixed at `install/3` call time and never reassigned, read from a Lua global, or derived
  from any of the 3 functions' own call arguments (§2.4). A future requirement extending
  `platform.*` must thread any further tenant-boundary-relevant value through this same
  closure-capture mechanism, not through a new Lua-visible global or a script-supplied
  argument — matching REQ-151's `Sandbox.new/0,1`-is-the-only-`Lua.new/1`-call-site
  discipline in spirit.

---

## 11. Open questions

**OQ-1 (not resolved by this design; explicitly deferred, per §1/§2.3.1).** No file in
this requirement's `owned_modules` wires a real, non-empty `execution_context` into
`Sandbox.new/1`'s or `Executor.execute_with_manifest/2,3`'s production call path — both
files are outside `owned_modules` and unedited. Concretely: `Executor.run_script/3` today
calls `Sandbox.new(max_instructions: budget)`, which still ends in `Platform.install(lua)`
(arity 1, §2.3.1), so a script executed through the real production `Executor` today
would see `read_variable`/`get_instance_state`/`log` all real (not raising
"not implemented"), but every one of them will observe the empty execution context (no
variables, no prefix, no trace id) until some future requirement threads a real
`InstanceProjection`-derived `execution_context` through `Executor`'s call chain — a
`Executor.execute_with_manifest/2,3` signature change is the likely shape, but that
signature is owned by the concurrent/future requirement that wires it, not this one. This
design does not silently assume that wiring exists; §2.3.1 makes the interim ("no context
supplied") behavior explicit and structured rather than crashing, but the wiring itself
is a genuine gap this artefact is flagging, not resolving.

**OQ-2.** `log`'s `context` argument (§6.1) is passed through to `Logger.log/3`'s
metadata as-is, with no size bound. If a script can pass an arbitrarily large Lua table
as `context`, this could produce an oversized log entry. This design does not add a size
limit — no requirement text (LUA-13's acceptance criterion, or REQ-159's own acceptance
list) asks for one, and adding an undocumented limit would be inventing a new constraint
outside this requirement's scope. Left open for a future requirement (or REVIEWER) to
decide whether one is needed.
