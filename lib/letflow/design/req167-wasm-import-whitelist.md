# REQ-167 — WASM import whitelist derived from the manifest, and filesystem access denied by default (WASM-06, WASM-07 restated)

**Requirement:** REQ-167 (WASM-06 — import whitelist, MUST; WASM-07 restated — no
filesystem access by default)
**Stage:** S5
**Owner (design):** CODE-DESIGNER; **Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-28
**Depends on:** REQ-166 (done, `lib/letflow/engine/wasm/module_registry.ex`); consumes
`lib/letflow/design/req163-wasm-abi-choice.md` (gate-approved, §4 names the concrete
import-denial surface) and `lib/letflow/design/req166-wasm-module-abi-validation.md`
(gate-approved, §1.5/§2.2 establish the crash-propagation hazard this design reuses).

This is a design artefact — `@spec`/`@type` signatures only, no function bodies. See
`docs/agents/workflows/WF-02_requirement_implementation.md` Step 1.

---

## 0 — What WASM-06/WASM-07 actually require, and why this is a third, distinct concern

**WASM-06 (Import Whitelist, MUST), verbatim:** "The Wasmtime instance MUST provide only
the host functions corresponding to capabilities declared in the module manifest. Imports
outside the whitelist MUST cause INSTANTIATION TO FAIL." Acceptance: "Module declaring
`var:read` only cannot import `platform_call_service`."

**WASM-07 (No Filesystem Access, MUST), verbatim:** "Wasm modules MUST NOT be granted WASI
filesystem capabilities by default. Any future grant MUST be explicit in the capability
manifest." Acceptance (literal, component-model-shaped): "Module attempting to import
`wasi:filesystem/types` is rejected."

**Why this is neither `ModuleRegistry` (REQ-166) nor `PluginHandler` (REQ-165), and is
built as a new, third module.** `ModuleRegistry.register/1` validates a module's *export*
section shape (does this module expose the five required functions with the right
signatures) and, as its own stage 2, proves the module *can* instantiate with **no
imports supplied at all** (`Wasmex.start_link(%{bytes: bytes})`, no `imports:` key) — see
`module_registry.ex`'s `instantiate/2`. It consumes no manifest and has no concept of
"which imports are authorized" — a module that imports nothing passes stage 2 exactly
the same way a module that imports something whitelist-worthy would, because stage 2
supplies zero host functions either way. `PluginHandler.run_guest/2` (REQ-165) dispatches
one already-known fixture's `execute`-equivalent export through the process boundary; it
also supplies no `imports:` map and consumes no manifest — it is a fixed single-purpose
POC, explicitly scoped (per its own moduledoc) to proving the NIF/process-boundary
mechanism, not the plugin ABI or its security boundary.

REQ-167's job is a genuinely different function of a genuinely different input: **given a
manifest (a capability grant set, external to both of the above), build the `imports:` map
`Wasmex.start_link/1` is called with, such that only host functions the manifest grants
are present as keys at all** — then instantiate through that constrained import table.
Neither `ModuleRegistry` nor `PluginHandler` touches a manifest today; grafting
manifest-driven import-table construction onto either would conflate "does this module
have the right export shape" (REQ-166) or "can one fixed guest export be dispatched
through the process boundary" (REQ-165) with "what is this module authorized to reach"
(REQ-167) — three orthogonal questions with three different inputs (bytes only; bytes +
one export name; bytes + a capability grant set). This repository's own precedent is to
give an orthogonal concern its own module and, where instantiation is involved, its own
supervision boundary — `req155-lua-wallclock-kill.md` §4.4 draws exactly this line for
`Letflow.SandboxPool.TaskSupervisor` / `Letflow.Engine.PluginTaskSupervisor` /
`Letflow.Engine.Lua.TaskSupervisor` (one dedicated `Task.Supervisor` per concern, not one
shared supervisor for every supervised task in the application), and
`req166-wasm-module-abi-validation.md` §2.2 already applied the identical reasoning to
justify `ModuleRegistryTaskSupervisor` as a fourth, independent supervisor rather than
reusing `PluginTaskSupervisor`. Capability-gated instantiation is a fifth such concern.

**Decision: new module, `Letflow.Engine.Wasm.CapabilityGate`, plus a new dedicated
`Task.Supervisor` (`Letflow.Engine.Wasm.CapabilityGateTaskSupervisor`).** Neither
`module_registry.ex` nor `plugin_handler.ex` is modified by this design (§7's confirmation
list). See §3 for the module's public surface.

---

## 1 — Real `wasmex` API verified live for this design (not guessed)

Verified this session against the actual installed dependency (`deps/wasmex` v0.15.1,
matching `mix.lock`) by reading `deps/wasmex/lib/wasmex.ex`,
`deps/wasmex/lib/wasmex/instance.ex`, and running a real `MIX_ENV=test mix run` script
(`WASMEX_BUILD=true`, `PATH` including `.asdf/shims` and `.cargo/bin`) against four
constructed WAT fixtures.

### 1.1 `Wasmex.start_link/1`'s `imports:` option is a real, selective host-function grant mechanism

`deps/wasmex/lib/wasmex.ex`'s moduledoc (lines ~57–83) documents `imports:` as "a map of
namespace-name to namespaces[,] [e]ach namespace ... in turn a map of import-name to
import," where one import is a 4-tuple `{:fn, params :: [valtype], results :: [valtype],
callback}`. `init/1` (line 475) stores `Wasmex.Utils.stringify_keys(opts.imports)`
unconditionally as instance state and passes it straight to `Wasmex.Instance.new/4`
(`deps/wasmex/lib/wasmex/instance.ex` line 69, `@spec new(StoreOrCaller.t(), Module.t(),
%{optional(binary()) => (... -> any())}, [...]) :: {:ok, t()} | {:error, binary()}`) — the
imports map is not filtered, merged with a default WASI set, or otherwise transformed
before being handed to the NIF (the only other keys `init/1` recognizes are `:wasi` and
`:links`, both separate map keys). **This confirms `imports:` is a partial, selective
grant by construction: whatever map Elixir code builds is the entire host-function surface
offered to the instance**, with no implicit universal grant layered underneath it (WASI
functions are only added when `wasi:` is separately truthy, per §1.1 of
`req163-wasm-abi-choice.md`, unaffected by this design).

### 1.2 Live confirmation: a host function absent from `imports:` behaves exactly like the wholly-import-less case REQ-166 already reproduced

Four live probes (`mix run`, this session, real installed `wasmex`), each inside a
`Task.Supervisor.async_nolink/2` task per §1.4 below (never inline):

1. **A module importing `"env"`/`"platform_call_service"` `(i32,i32)->i32`, with a
   non-empty `imports:` map that supplies only `"env"/"read_variable"` `(i32)->i32`** (the
   whitelisted function present, the requested one absent) — `Task.yield/2` returned
   `{:exit, {{:badmatch, {:error, "unknown import: \`env::platform_call_service\` has not
   been defined"}}, [...]}}`. **Identical crash shape** to
   `req166-wasm-module-abi-validation.md` §1.5's already-verified unresolved-import crash
   (`{{:badmatch, {:error, message}}, stacktrace}`, `message` matching `"unknown import:
   \`<namespace>::<function>\` has not been defined"`) — confirming `module_registry.ex`'s
   existing `classify_crash/1` regex
   (`~r/unknown import: \`(?<namespace>[^:\`]+)::(?<function>[^\`]+)\` has not been
   defined/`) is not specific to the `wasi_snapshot_preview1` namespace: it matches this
   arbitrary `"env"`-namespace case verbatim, with no changes.
2. **The same module, with `imports:` extended to also supply `"env"/"platform_call_service"`
   `(i32,i32)->i32`** — `Task.yield/2` returned `{:ok, {:ok, #PID<...>}}`: clean success.
   Confirms the harness does not mistake a granted import for a failure, and that adding
   exactly the missing entry (nothing else) is sufficient to instantiate.
3. **A module with no imports at all, given a non-empty `imports:` map holding both
   `read_variable` and `platform_call_service`** — `Task.yield/2` returned
   `{:ok, {:ok, #PID<...>}}`. Confirms an unused whitelist entry is inert: `imports:`
   describes what a module *may* reach, not what it *must* reach — no error results from
   over-supplying relative to what one particular module happens to import.
4. **A module importing `"wasi_snapshot_preview1"`/`"path_open"` (req163 §4's named
   surface, the real 9-parameter/1-result WASI Preview 1 signature), no `wasi:` key
   supplied, alongside the same unrelated non-empty `imports:` map from probe 1** —
   `Task.yield/2` returned `{:exit, {{:badmatch, {:error, "unknown import:
   \`wasi_snapshot_preview1::path_open\` has not been defined"}}, [...]}}`. Confirms
   req163 §4's filesystem-denial mechanism (never supplying `wasi:`) is completely
   independent of, and unaffected by, whatever unrelated `imports:` map this design
   builds — the two denial mechanisms (whitelist absence, WASI omission) compose without
   interaction.

**Conclusion this design relies on:** `imports:` absence and WASI omission both surface
through the exact same crash shape `ModuleRegistry.classify_crash/1` already parses
correctly (§4 records the decision *not* to extract that logic into a shared module,
and why).

### 1.3 There is no live-instance introspection API for "which imports actually resolved" — confirmed absent, not assumed

`Wasmex.instance/1` (`wasmex.ex` line ~468) returns `{:ok, %Wasmex.Instance{resource:
binary(), reference: reference()}}` — an opaque NIF-resource wrapper with no readable
fields (`instance.ex` lines 10–13: exactly `resource`/`reference`, no accessor exposing
resolved imports). `Wasmex.Instance`'s only public functions (`instance.ex`'s full export
list, grepped this session) are `new/4`, `function_export_exists/3`,
`call_exported_function/5,6`, `memory/2`, `get_global_value/4`, `set_global_value/4`, and
`inspect/2` (an `Inspect` protocol implementation for logging, not a data accessor) — none
of them enumerate the host-function imports an already-running instance was given.
`Wasmex.Module.imports/1` (cited, already live-verified in
`req166-wasm-module-abi-validation.md` §1.4, not re-verified here) is a **static**
function of the compiled *module's own declared import section* (what the guest bytes ask
for), not of a running instance's actually-resolved host-function table, and is a
property of the `.wasm` bytes alone — unaffected by whatever `imports:` map a caller
supplies.

**Consequence for AC2's "asserted by INSPECTING the instance (not by invoking and catching
an error)":** because no `wasmex` v0.15.1 API exposes a running instance's resolved
import table, "the instance's imports" in AC2's own wording is necessarily **the
constructed `imports:` map itself** — the plain Elixir data structure `build_import_table/1`
(§5.1) produces and hands to `Wasmex.start_link/1` — not a post-instantiation live query.
This is inspectable directly (`Map.has_key?/2` against the produced map) with no
`wasmex` call at all, which is exactly what makes it distinct from AC1/AC3's
"instantiation fails" tests: AC2 proves the whitelist's *construction* is capability-driven
and exclusionary by examining the data the mechanism is built from, never by triggering
and catching a runtime error. §5.2 states this as the concrete assertion shape TEST-DESIGNER
implements against.

---

## 2 — Manifest representation: minimal shape, no speculative schema

`grep -rn manifest lib/letflow/engine/` (this session) finds exactly one existing manifest
type: `Letflow.Engine.Lua.Manifest` (REQ-158, `lib/letflow/engine/lua/manifest.ex`) — a
Lua-specific struct carrying `script_id`, `capabilities`, a canonical hash algorithm, and
`validate_at_load/3`'s hash-mismatch gate. That module is Lua-specific machinery (script
identity, hash-mismatch detection against a registered value) this requirement has no use
for and does not depend on. No WASM-side manifest type exists anywhere in `lib/letflow/`.

**Decision: define the minimal shape this requirement needs — a bare capability list —
inline in `Letflow.Engine.Wasm.CapabilityGate`, not a new top-level manifest module and
not a port of `Lua.Manifest`'s hash/script-id machinery.**

```
@type capability :: String.t()
@type manifest :: %{capabilities: [capability()]}
```

**Vocabulary decision:** capability tokens are opaque strings, matching
`Letflow.Engine.Lua.Capabilities`'s own documented shape exactly — `"variable:read"`,
`"service:call:billing"`, etc. (`lib/letflow/engine/lua/capabilities.ex`'s moduledoc,
`req157-lua-capability-model.md` §2) — **exact-string membership only, no
wildcard/prefix matching of any kind**, the same discipline
`Letflow.Engine.Lua.Capabilities.has?/2` already establishes (`has?(grants,
"service:call:billing")` is `true` only for that exact string, never for
`"service:call:*"` or a bare `"service:call"`). `CapabilityGate` does **not** import or
depend on `Letflow.Engine.Lua.Capabilities` — the two subsystems (Lua, WASM) stay
decoupled, each with its own capability-set type, per `PluginInterface`'s own
handler-per-runtime shape — but the *string vocabulary and exact-match discipline* is
intentionally the one `req163-wasm-abi-choice.md` §3.1's `get_capabilities` table row
already cites ("the same capability vocabulary `PluginInterface` already uses for
in-process plugins, so REQ-167's capability model does not need a second vocabulary").

**What "the module manifest" is NOT, here.** WASM-06's "capabilities declared in the
module manifest" is the **host/administrative** grant set — analogous to Lua's split
between `Letflow.Engine.Lua.Manifest` (REQ-158, an admin-registered, hash-verified
record) and `Letflow.Engine.Lua.Capabilities` (REQ-157, the actual gate, driven by
whatever grant set is threaded to it). This design's `manifest()` is deliberately the
REQ-157-shaped half (a bare grant set) — it is **not** derived from, and this design
never reads, the WASM guest's own self-declared `get_capabilities` export (req163 §3.1:
a UTF-8 JSON array the guest itself returns). A guest is untrusted; trusting its own
claim of what it needs to determine what it may reach would make the whitelist
vacuous — the guest could simply self-declare needing everything. Reconciling a guest's
self-declared `get_capabilities` payload against the admin-granted `manifest()` here
(e.g., flagging a guest that requests more than it is granted) is explicitly **not**
this requirement's scope — carried forward as an open question (§8), mirroring how
Lua's own manifest **validation** (REQ-158, hash/shape checking) is a distinct
requirement from its capability **gate** (REQ-157).

**Where a `manifest()` value comes from at runtime** (an admin/registration API surface
threading a real grant set to `CapabilityGate.start_instance/2`) is out of this
requirement's scope, exactly as `req166-wasm-module-abi-validation.md` §7 left
"where `registered_module()` values are held/looked-up between registration and
invocation" as an open question for a future dispatch-integration requirement. This
design's own tests construct `manifest()` values as literal test data.

---

## 3 — Public entry point: `Letflow.Engine.Wasm.CapabilityGate`

```
defmodule Letflow.Engine.Wasm.CapabilityGate do
  @typedoc "Per §2 — the minimal grant-set shape this requirement needs."
  @type capability :: String.t()

  @typedoc "Per §2 — a bare capability grant set; not `Lua.Manifest`, not derived from a
  guest's self-declared `get_capabilities` export."
  @type manifest :: %{capabilities: [capability()]}

  @type valtype :: :i32 | :i64 | :v128 | :f32 | :f64

  @typedoc """
  One entry in the placeholder host-function registry (§6). `capability` is the exact
  grant-set token gating this entry (§2's exact-match discipline — no wildcards).
  `namespace`/`name` are the WASM-level import identifiers a guest module's import
  section would name. `params`/`results` are the WASM core-module function type, per
  `req163-wasm-abi-choice.md` §1's five valid primitives.
  """
  @type import_descriptor :: %{
          capability: capability(),
          namespace: String.t(),
          name: String.t(),
          params: [valtype()],
          results: [valtype()]
        }

  @typedoc """
  The exact shape `Wasmex.start_link/1`'s `imports:` option requires (§1.1, verified
  live): namespace -> import name -> a 4-tuple of `(:fn, params, results, callback)`.
  """
  @type import_table :: %{
          String.t() => %{String.t() => {:fn, [valtype()], [valtype()], (... -> term())}}
        }

  @typedoc """
  One concrete way the gated instantiation attempt failed. Deliberately the same shape
  family as `Letflow.Engine.Wasm.ModuleRegistry.instantiation_defect/0` (§4 explains why
  this is a parallel, not a shared, type)."
  """
  @type instantiation_defect ::
          {:unresolved_import, namespace :: String.t(), function :: String.t()}
          | {:crashed, raw_reason :: term()}
          | {:timeout, timeout_ms :: non_neg_integer()}

  @typedoc "The structured rejection reason (AC1/AC3's 'structured error', not a bare string)."
  @type gate_error :: {:instantiation_denied, instantiation_defect()}

  @doc """
  Builds the `imports:` map (§5.1) `start_instance/2` (and any future caller assembling
  its own `Wasmex.start_link/1` options directly) hands to `wasmex`, containing an entry
  for every `import_descriptor()` in the registry (§6) whose `capability` is a member of
  `manifest.capabilities` (exact string match, §2) — and, structurally, no entry for any
  descriptor whose capability is absent. This is a pure function: no store, no module, no
  instantiation, no side effect — the AC2 "inspect rather than invoke" assertion targets
  this function's return value directly.
  """
  @spec build_import_table(manifest()) :: import_table()

  @doc """
  Builds the whitelist (`build_import_table/1`) from `manifest`, then attempts a real
  instantiation of `bytes` against exactly that import table and no `wasi:` option (§2,
  §7 — no filesystem grant path exists today). Runs the attempt inside a monitored
  `Task.Supervisor.async_nolink/2` task under
  `Letflow.Engine.Wasm.CapabilityGateTaskSupervisor` (§4), never inline, for the identical
  crash-propagation reason `req166-wasm-module-abi-validation.md` §1.5 live-reproduced
  and this design's own §1.2 re-confirmed for the whitelist case specifically. On success,
  returns `{:ok, pid}` — a live, running instance the caller owns and must
  `GenServer.stop/1` when done (this function does not stop it, unlike
  `ModuleRegistry.register/1`'s stage-2 proving instance, because this instance is the
  real one a caller intends to invoke against, not a proof-of-instantiability throwaway —
  §4). On any instantiation failure — including an import outside the whitelist, or a
  denied WASI import — returns `{:error, {:instantiation_denied, instantiation_defect()}}`.
  """
  @spec start_instance(bytes :: binary(), manifest()) :: {:ok, pid()} | {:error, gate_error()}
end
```

---

## 4 — Why `instantiation_defect()` is parallel to, not shared with, `ModuleRegistry`'s type

`Letflow.Engine.Wasm.ModuleRegistry.instantiation_defect/0` and this module's
`instantiation_defect/0` are structurally identical three-variant types, and both modules'
crash-classification logic (§1.2's regex) is, by this session's live verification, the
same pattern applied to the same crash shape. **Decision: do not extract a shared helper
module; each module keeps its own private classification function, duplicating the
~10-line regex-match private function.** Justification: `module_registry.ex` is
already-implemented, gate-approved (REVIEWER- and SECURITY-REVIEWER-passed) code
belonging to REQ-166; REQ-167's own scope note lists only what this requirement adds, not
a refactor of REQ-166's shipped implementation, and touching `module_registry.ex` would
put REQ-166's already-passing 20-test suite (`test/specs/REQ-166.md`'s mutation-pass
total) at needless regression risk for a requirement whose own acceptance criteria say
nothing about consolidating that logic. This is flagged as a follow-up cleanup
opportunity (§8), not undertaken here — the duplication is small (one private function,
one regex) and does not affect either module's correctness or its public contract.

**Structural "never granted beyond the whitelist" argument (mirrors
`req166-wasm-module-abi-validation.md` §4's proof shape):**

1. `build_import_table/1` (§3) is a pure function of `manifest.capabilities` and the fixed
   `@known_imports` registry (§6) — it cannot include an entry whose `capability` is not a
   member of `manifest.capabilities`, by construction (a `Enum.filter/2`-then-group
   operation, not an allow-everything-then-remove one).
2. `start_instance/2` (§3) passes `build_import_table/1`'s return value, and *only* that
   value, as `Wasmex.start_link/1`'s `imports:` option — no other code path in this module
   supplies a competing or supplementary imports map, and `wasi:` is never supplied (§2,
   §7), so no WASI-namespace import is ever resolved either, regardless of `manifest`.
3. Per §1.1/§1.2 (live-verified), `wasmex` treats `imports:` as the *entire* host-function
   surface — no implicit universal grant exists underneath it — so a guest module
   importing anything whose `(namespace, name)` pair is not a key in that exact map fails
   **instantiation** (the crash shape §1.2 reproduces), not merely "fails when called."
4. Therefore: the only host functions any instance `start_instance/2` produces can ever
   call are exactly those named by `import_descriptor()`s whose capability the manifest
   granted — and a module naming any import outside that set never reaches a running
   `pid` at all; `start_instance/2`'s only success branch is reached after
   `Wasmex.start_link/1` itself already resolved every import the guest declared, which by
   (1)-(3) is only possible when every one of those imports was whitelist-covered.

---

## 5 — Algorithm (design-level, no implementation)

### 5.1 `build_import_table/1`

1. For each `import_descriptor()` in `@known_imports` (§6), keep it iff
   `descriptor.capability in manifest.capabilities` (exact string equality, §2 — a
   `MapSet.member?/2` check against `MapSet.new(manifest.capabilities)`, or an
   equivalent `Enum.member?/2` — either is a valid ELIXIR-DEV choice since no ordering or
   duplicate-tolerance property is asserted by any AC).
2. Group the surviving descriptors by `namespace`, then by `name`, into
   `%{namespace => %{name => {:fn, params, results, callback}}}` — the exact `imports:`
   shape §1.1 verified live. Two descriptors sharing a `(namespace, name)` pair is a
   registry-authoring error (§6 states the registry has no duplicate namespace/name
   pairs today); this design does not define tie-breaking behavior for that case since no
   AC exercises it and the registry (§6) does not create it.
3. A `manifest` with an empty `capabilities` list produces `%{}` — a wholly closed
   instance, the strictest whitelist state, exercised directly by AC3's filesystem-denial
   test (§5.2 step 3) since no capability the registry defines is filesystem-shaped in
   the first place (§7).

### 5.2 `start_instance/2` and its three AC-facing behaviors

1. `table = build_import_table(manifest)` (§5.1).
2. Spawn `Wasmex.start_link(%{bytes: bytes, imports: table})` — no `wasi:` key, ever
   (§2/§7) — inside `Task.Supervisor.async_nolink/2` under
   `Letflow.Engine.Wasm.CapabilityGateTaskSupervisor`, read back via `Task.yield/2` bounded
   by a fixed timeout (an ELIXIR-DEV implementation constant, mirroring
   `req166-wasm-module-abi-validation.md` §5.1 step 6 — no AC fixes its exact value).
3. **AC1's shape** (module declares a manifest granting only a `var:read`-equivalent
   capability, imports the `platform_call_service`-equivalent import): `table` (built in
   step 1) has no `"platform_call_service"` key under whichever namespace it would live
   in (§6), so `Wasmex.start_link/1` crashes with the unresolved-import shape (§1.2 probe
   1); `Task.yield/2` returns `{:exit, reason}`; classification (this module's own private
   `classify_crash/1`, §4) yields
   `{:error, {:instantiation_denied, {:unresolved_import, namespace, "platform_call_service"}}}`.
4. **AC2's shape**: no instantiation is involved at all — the test calls
   `build_import_table/1` directly (§1.3's conclusion) and asserts
   `refute Map.has_key?(table[namespace] || %{}, "platform_call_service")` (or equivalent)
   for a manifest that does not grant the gating capability, and, symmetrically, asserts
   the key **is** present for a manifest that does — both against the map `build_import_table/1`
   returns, never by starting an instance.
5. **AC3's shape** (filesystem denial, req163 §4's named surface): a module importing
   `"wasi_snapshot_preview1"`/`"path_open"` (or any of req163 §4's other named
   filesystem-shaped functions), against *any* manifest (§6's registry contains no
   filesystem-capability entry at all, so no manifest content changes the outcome) — fails
   identically via `{:error, {:instantiation_denied, {:unresolved_import,
   "wasi_snapshot_preview1", "path_open"}}}`, confirmed live in §1.2 probe 4.
6. `Task.yield/2` returning `{:ok, {:ok, pid}}` → `{:ok, pid}` (live instance, caller-owned,
   §3). `{:ok, {:error, reason}}` (a clean non-crash failure — not observed live for this
   design's cases, defensive per `req166-wasm-module-abi-validation.md` §5.1 step 7's
   identical defensive branch) → `{:error, {:instantiation_denied, {:crashed, reason}}}`.
   `nil` (timeout) → `Task.shutdown(task, :brutal_kill)`, then
   `{:error, {:instantiation_denied, {:timeout, timeout_ms}}}`.

---

## 6 — The placeholder capability→import registry, and why it is explicitly not authoritative

**`@known_imports` is a fixed, small `[import_descriptor()]` list private to
`CapabilityGate`, containing exactly two entries for this requirement's own tests:**

| Capability | Namespace | Import name | Params | Results |
|---|---|---|---|---|
| `"var:read"` | `"env"` | `"read_variable"` | `[:i32, :i32]` | `[:i32]` |
| `"service:call"` | `"env"` | `"platform_call_service"` | `[:i32, :i32]` | `[:i32]` |

**Why these two, and why their signatures are placeholders.** `platform_call_service` is
used verbatim because it is WASM-06's own acceptance-criterion text — the literal import
name a fixture must attempt to import for AC1 to test the exact scenario named. `var:read`
is likewise used **verbatim from WASM-06's own text**, not restated to
`"variable:read"` — unlike WASM-07's `wasi:filesystem/types` (a WASI Preview 2
*component-model interface identifier* that literally does not exist under core modules,
per req163 §4, and therefore *must* be replaced), `var:read` is not an ABI-specific
identifier incompatible with core modules; it is simply an example capability-grant
string, so no structural restatement is required to make the acceptance criterion
testable. **Open question, not resolved here (carried to §8 and to REQ-171/172):**
whether the platform's real WASM capability vocabulary ultimately standardizes on
`Letflow.Engine.Lua.Capabilities`'s exact token spelling (`"variable:read"`) or WASM-06's
own shorthand (`"var:read"`) is a vocabulary-alignment decision belonging to REQ-171/172
— the requirement that defines real, invocable host functions these tokens gate. This
design's registry is a placeholder proving the *mechanism* (whitelist construction and
enforcement) only, not a resolved host-API vocabulary; `read_variable`'s and
`platform_call_service`'s signatures above are likewise illustrative core-module type
shapes (arbitrary `(i32,i32)->i32`, matching the pointer/length descriptor convention
`req163-wasm-abi-choice.md` §3.1 already establishes for `init`/`execute`) chosen only to
be valid, distinguishable WASM function types for fixture-authoring purposes — REQ-171/172
own the real signatures, argument semantics, and callback bodies (a callback here is
never invoked by any of this requirement's own tests: whitelist presence/absence and
instantiation success/failure are observable without ever calling the granted function,
so a trivial stub callback, e.g. one that always returns a constant, suffices wherever a
test needs a working, callable placeholder).

**Neither entry, nor any other entry in this registry, names anything under the
`wasi_snapshot_preview1` namespace, and none ever will unless a future requirement adds
one — see §7.**

---

## 7 — WASM-07 restatement (moduledoc content — AC4/AC5/AC6)

Per this requirement's own text and `req163-wasm-abi-choice.md` §4,
`Letflow.Engine.Wasm.CapabilityGate`'s moduledoc MUST state, verbatim in substance:

1. **(AC5) This module restates WASM-07.** The INTENT — no filesystem capability granted
   by default — is fully implemented: `start_instance/2` never supplies a `wasi:` option
   (§2, §5.2), and §6's registry contains zero filesystem-shaped entries, so no manifest
   content, however permissive, can cause a filesystem import to resolve. The acceptance
   criterion's *concrete interface name*, `wasi:filesystem/types`, is ABI-dependent and
   was replaced per `req163-wasm-abi-choice.md`'s Decision (core modules, not the
   component model).
2. **(AC4) WASM-07's literal name is NOT the surface tested, and why.**
   `wasi:filesystem/types` is a WASI **Preview 2 component-model** interface identifier;
   it has no meaning under wasmtime's core-module linking, where imports are named by a
   flat `(namespace, function)` pair, not a WIT interface path. A test asserting that a
   core-module runtime rejects an import literally named `wasi:filesystem/types` would be
   a **false pass**: any core-module import section referencing that string (which is not
   even syntactically a valid core-module `(namespace, name)` pair in the way this
   platform's tooling would author one) is rejected as *unrecognized*, identically to
   how *any* misspelled or nonexistent import name would be rejected — the test would
   pass regardless of whether real filesystem-shaped imports (`path_open`, `fd_read`,
   etc.) are actually denied. **What is tested instead:** req163 §4's named concrete
   surface — `wasi_snapshot_preview1`/`path_open` (and, by the same non-supplied-`wasi:`
   mechanism, every other function in that namespace: `fd_read`, `fd_write`, `fd_readdir`,
   `path_filestat_get`, `fd_filestat_get`, `path_create_directory`,
   `path_remove_directory`, `path_unlink_file`, `path_rename`, `path_symlink`) — verified
   live in §1.2 probe 4 to fail instantiation via the same unresolved-import mechanism
   AC1's whitelist-absence case uses.
3. **(AC6) No explicit filesystem-grant path exists today.** §6's registry defines
   exactly two entries, neither filesystem-shaped, and nothing in `CapabilityGate`
   inspects `manifest.capabilities` for any filesystem-related token — there is no code
   path today by which any `manifest()` value, however constructed, could cause a
   `wasi_snapshot_preview1` (or any other WASI) function to appear in
   `build_import_table/1`'s output. WASM-07's clause "any future grant MUST be explicit
   in the capability manifest" is **not implemented** by this design: implementing it
   would mean adding a real filesystem-capability registry entry (and, transitively, a
   real WASI-preopen-backed callback or a `wasi:` option wired to a manifest-derived
   `Wasmex.Wasi.WasiOptions`) that nothing in this requirement's scope calls for and no
   AC exercises. The moduledoc must say this plainly rather than imply the clause is
   satisfied by the mere existence of `manifest()`'s generic capability-list shape.

---

## 8 — Open questions carried forward (not resolved here)

- **Capability-vocabulary spelling** (§6) — `"var:read"` vs. `Lua.Capabilities`'s
  `"variable:read"` — left for REQ-171/172 to settle when real host functions and their
  gating tokens are defined.
- **Reconciling a guest's self-declared `get_capabilities()` payload against the
  admin-granted `manifest()`** (§2) — explicitly out of scope, analogous to Lua's
  REQ-157/REQ-158 split; no requirement currently owns this.
- **Where a `manifest()` value is produced/stored for a real module at runtime** (an
  admin/registration API surface) — out of scope, mirrors
  `req166-wasm-module-abi-validation.md` §7's identical open question for
  `registered_module()` storage.
- **Consolidating `ModuleRegistry`'s and `CapabilityGate`'s duplicated crash-classification
  regex** (§4) — flagged as a follow-up cleanup, deliberately not undertaken here to avoid
  touching REQ-166's already gate-approved implementation.
- **`start_instance/2`'s fixed instantiation timeout's exact millisecond value** (§5.2
  step 2) — an ELIXIR-DEV implementation constant, not fixed here, mirroring
  `req166-wasm-module-abi-validation.md`'s identical open question for its own
  timeout.
- **How a future dispatch-integration requirement wires `ModuleRegistry.register/1`'s
  `registered_module()`, `CapabilityGate.start_instance/2`'s manifest-gated
  instantiation, and `PluginHandler`'s (or its successor's) actual export-calling
  sequence together into one production call path** — out of scope for REQ-165, REQ-166,
  and this requirement alike; each of the three is designed to be independently callable
  and independently testable, per each one's own decoupling decision (REQ-166 §2.1, this
  design's §0).
- **Whether `platform_call_service` should be gated by the exact-service-id-scoped tokens
  Lua's `service_capability/1` mints (`"service:call:<svc_id>"`) rather than a single
  coarse `"service:call"` token** (§6) — this design's registry uses the coarse form only
  because no real per-service dispatch exists yet to scope; REQ-171/172 decide the real
  shape.

---

## 9 — Traceability: REQ-167's acceptance criteria (`docs/requirements.yaml`) → design elements

| # | Acceptance criterion (verbatim, `docs/requirements.yaml` REQ-167) | Design element |
|---|---|---|
| 1 | "a test asserts a module declaring only var:read and importing the service-call host function FAILS TO INSTANTIATE, which is WASM-06's own acceptance criterion" | §3 `gate_error()`/`instantiation_defect()`; §5.2 step 3 (live-verified crash shape, §1.2 probe 1); §6 (the exact `var:read`/`platform_call_service` registry entries this test exercises) |
| 2 | "a test asserts the import table is built from the manifest as a whitelist: a host function not named by the manifest is absent from the instance's imports, asserted by inspecting the instance rather than by invoking and catching an error" | §1.3 (why "the instance's imports" resolves to `build_import_table/1`'s return value — no live-instance introspection API exists, confirmed absent); §3 `build_import_table/1`; §5.1; §5.2 step 4 (the direct `Map.has_key?/2`-style assertion shape) |
| 3 | "a test asserts a module attempting filesystem access under the ABI REQ-163 chose is rejected, using the concrete import surface REQ-163's artefact names" | §5.2 step 5 (live-verified via §1.2 probe 4, `wasi_snapshot_preview1`/`path_open`); §7 point 2 |
| 4 | "if the chosen ABI is core modules, the moduledoc states that WASM-07's literal 'wasi:filesystem/types' name is NOT the surface tested, names what is tested instead, and explains that asserting the component-model name under a core-module runtime would be a false pass" | §7 point 2 |
| 5 | "the moduledoc states that this requirement restates WASM-07: the intent ... is implemented, while the acceptance criterion's concrete interface name is ABI-dependent and was replaced per REQ-163" | §7 point 1 |
| 6 | "the moduledoc states whether an explicit filesystem grant path exists today; if none does, it says so rather than implying the 'future grant' clause is implemented" | §7 point 3 |
| 7 | "mix test and mix compile --warnings-as-errors both pass with real output quoted" | Not a design element — an ELIXIR-DEV/CI obligation; §4's structural proof and §3's opaque-free (plain map/tuple) types are chosen so both commands have something meaningful to enforce |

### Handoff-specific meta-criteria (not in `docs/requirements.yaml` itself, from this WF-02 run's own handoff)

| Handoff AC | Design element |
|---|---|
| AC7 — "design states explicitly where the whitelist-building logic lives ... and why, with an explicit manifest-representation decision" | §0 (module-location decision), §2 (manifest-representation decision) |
| "Zero literal Elixir code in the design doc" | §3/§5/§6 use `@type`/`@spec`/`@doc` and prose/tables only — no `def ... do ... end` bodies anywhere in this document |
| "Full traceability table mapping every one of REQ-167's real acceptance criteria ... to a planned test" | This table (rows 1–7) plus `test/specs/REQ-167.md`'s T1–T6 |

---

## 10 — Confirmation: no `lib/letflow/engine/wasm/module_registry.ex` or `plugin_handler.ex` change

This design adds exactly one new file (`lib/letflow/engine/wasm/capability_gate.ex`) and
one new supervision-tree child spec (`{Task.Supervisor, name:
Letflow.Engine.Wasm.CapabilityGateTaskSupervisor}` in `lib/letflow/application.ex`,
alongside `ModuleRegistryTaskSupervisor` and its siblings — order does not matter among
them, per `req166-wasm-module-abi-validation.md` §2.2's identical note). Neither
`module_registry.ex` nor `plugin_handler.ex` is modified — confirmed by `git diff --stat`
scoped to those two paths at ELIXIR-DEV's implementation commit (this design document
itself changes neither file, by construction: §4 documents the duplication decision that
makes this true).
