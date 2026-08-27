# REQ-153 Design: `Letflow.Engine.Lua.Executor`

**Requirement:** REQ-153 — Per-invocation Lua state isolation and concrete
`LuaScriptAudit.Executor` implementation.

**Stage:** S5 (Scripting & plugins)

**Acceptance criteria mapped below:**
- LUA-EC-1: Fresh `Lua.t()` per invocation — state never reused between calls.
- LUA-EC-2: `execute_with_manifest/2` returns `{:ok, %{manifest_hash: hex_string}}` on
  success and `{:error, reason}` on failure.
- LUA-EC-3: `manifest_hash` is the SHA-256 hex digest of the script source.

---

## 1. Module location

`Letflow.Engine.Lua.Executor` at `lib/letflow/engine/lua/executor.ex`.

This name follows the existing `lib/letflow/engine/lua/` namespace (alongside
`sandbox.ex`, `platform.ex`) and the `@behaviour
Letflow.Engine.LuaScriptAudit.Executor` it satisfies. No alternative location is
justified.

---

## 2. `script_ref` concrete shape (decision)

**Choice: `script_ref` is a plain binary — the UTF-8 Lua source text itself.**

```
@type script_ref :: binary()
```

**Reasoning:**

- REQ-153's scope is execution isolation and hash reporting. No manifest structure, no
  compiled bytecode, no file path exists yet — the behaviour's own `@typedoc` explicitly
  defers "the concrete script-ref shape … to the Executor module."
- Using the source binary keeps the surface minimal: `execute_with_manifest/2` receives
  the text, runs it, and hashes it from the same value — no intermediate representation
  to keep synchronized.
- REQ-158 (manifest validation) will define a manifest structure when it ships. At that
  point, the manifest can carry the script source as one of its fields, or `script_ref`
  can be redefined to a richer struct. That change is local to this module; the
  `LuaScriptAudit.Executor` behaviour's `@type script_ref :: term()` stays opaque and
  does not need to change.
- A struct now would add fields REQ-153 cannot use and would preempt REQ-158's own
  manifest-shape decisions.

**Open question OQ-1 (for REQ-158):** When REQ-158 defines a real manifest hash for
validation, `script_ref` should be revisited. At that point the hash in the manifest
will be the `manifest_hash` returned; the SHA-256-of-source placeholder below is
superseded.

---

## 3. Behaviour implementation

`Letflow.Engine.Lua.Executor` implements:

```
@behaviour Letflow.Engine.LuaScriptAudit.Executor
```

It provides exactly one public callback implementation:

### `execute_with_manifest/2`

**Signature (callback):**
```
@spec execute_with_manifest(script_ref :: binary(), registered_hash :: String.t()) ::
        {:ok, %{manifest_hash: String.t()}} | {:error, term()}
```

**`registered_hash` parameter:** The behaviour contract requires the parameter to be
accepted; this module receives it but does not use it to gate or validate execution.
`LuaScriptAudit.execute_script_for_audit/6` independently performs the mismatch check
after this callback returns (INV-LSA-2). The Executor has no invariant responsibility
for hash comparison.

---

## 4. `execute_with_manifest/2` logic (prose)

1. **Construct a fresh sandbox.** Call `Letflow.Engine.Lua.Sandbox.new/0` to obtain a
   new `Lua.t()`. This is the only permitted construction path (INV-SBX-1). The
   resulting state has the full deny-set applied (LUA-03/04 restated, REQ-151), all
   `os.time`-family functions denied, and `platform.now` installed (REQ-152). The state
   is local to this invocation; it is never stored, never passed out of this function,
   and never reused.

2. **Execute the script.** Call `Lua.eval!(state, script_source)` — or the equivalent
   two-step `Lua.load!/2` + `Lua.call!/3` if the library's eval path does not exist —
   passing the binary `script_ref` directly as source text. The sandbox state is used
   exactly once.

3. **On success:** Compute `manifest_hash` (see §5) and return
   `{:ok, %{manifest_hash: manifest_hash}}`.

4. **On error:** Any exception or `{:error, _}` from `Lua.eval!/2` is caught and
   returned as `{:error, reason}`. The `reason` is whatever the `tv-labs/lua` runtime
   surfaces — typically a string describing the Lua error. No wrapping or re-raising.

5. **No state leaks.** The `Lua.t()` value produced in step 1 goes out of scope when
   the function returns. There is no module-level state, no ETS, no Agent, no GenServer
   involved in this module.

---

## 5. `manifest_hash` computation

```
manifest_hash = :crypto.hash(:sha256, script_source) |> Base.encode16(case: :lower)
```

- Input: the raw binary `script_ref` (the Lua source text).
- Output: a 64-character lowercase hex string.
- Algorithm: SHA-256 via Erlang's `:crypto` (part of OTP; no additional dependency).
- Encoding: `Base.encode16/2` with `case: :lower` produces the conventional lowercase
  hex representation.

**REQ-158 supersession note:** This hash is a placeholder. When REQ-158 ships, manifest
validation will use the hash embedded in the manifest structure (which covers script
content, capability declarations, and schema version together). At that point, the value
returned here either comes from parsing the manifest or is dropped in favour of a real
manifest hash. The placeholder does not constrain REQ-158's design.

---

## 6. Invariants maintained

| Invariant | Who owns it | Executor's role |
|---|---|---|
| INV-LSA-1 — `instance_id` validated before executor called | `LuaScriptAudit.execute_script_for_audit/6` | None; Executor never sees `instance_id` |
| INV-LSA-2 — manifest hash mismatch aborts insert | `LuaScriptAudit.execute_script_for_audit/6` | None; Executor returns the hash, caller compares |
| INV-SBX-1 — only `Sandbox.new/0|1` may call `Lua.new/1` | `Letflow.Engine.Lua.Sandbox` | Maintained: Executor calls `Sandbox.new/0`, never `Lua.new/1` directly |
| INV-SBX-4 — sandbox construction never fails | `Letflow.Engine.Lua.Sandbox` | Maintained: `Sandbox.new/0` returns a `Lua.t()`, not `{:ok, _} | {:error, _}` |
| Per-invocation isolation (LUA-EC-1) | **This module** | A new `Lua.t()` is created on every call; no state is reused |

---

## 7. Cross-module dependencies

| Dependency | Why |
|---|---|
| `Letflow.Engine.Lua.Sandbox` | `new/0` is the only construction entry point |
| `Lua` (tv-labs/lua) | `Lua.eval!/2` (or equivalent) to run script source |
| `:crypto` (OTP) | `hash(:sha256, _)` for manifest hash |
| `Base` (Elixir stdlib) | `encode16/2` to hex-encode the digest |

No new `mix.exs` dependency. `tv-labs/lua` is already present (added in REQ-148 spike
scope; confirmed present for S5 implementation).

---

## 8. Out of scope (explicitly excluded from REQ-153)

- Resource limits (`:max_instructions`, `:max_call_depth`) — REQ-154, REQ-155, REQ-156.
- Capability enforcement (`platform.*` gating) — REQ-157.
- Manifest validation (comparing manifest-declared hash against script content) — REQ-158.
- Any change to `lua_script_audit.ex` or its `Executor` behaviour definition.
- SERVICE_TASK integration — explicitly out of scope per `lua_script_audit.ex` moduledoc.

---

## 9. Open questions

| ID | Question | Blocks |
|---|---|---|
| OQ-1 | When REQ-158 defines a real manifest structure, `script_ref` shape and `manifest_hash` computation should be revisited together in a single change. | REQ-158 |
| OQ-2 | `Lua.eval!/2` vs. `Lua.load!/2` + `Lua.call!/3` — the spike (REQ-148) should have confirmed which call path the `tv-labs/lua` API exposes for single-shot source execution. ELIXIR-DEV must verify before implementing. | REQ-153 implementation |
