defmodule Letflow.Engine.Wasm.HostApi do
  @moduledoc """
  REQ-171 (WASM-12 read half) — the WASM ABI's equivalent of
  `Letflow.Engine.Lua.Platform`'s `do_read_variable/do_log/now` trio, for the four
  functions this requirement owns: `read_variable`, `log`, `now`, `uuid`. REQ-172 adds
  `do_write_variable`/`do_call_service`/`do_fail` to this same module (mirroring
  `platform.ex` hosting both REQ-159's and REQ-160's implementations in one file).

  See `lib/letflow/design/req171-wasm-host-api-read.md` (gate-approved) for the full
  design this module implements, in particular §1's live-verified `wasmex` v0.15.1
  callback ABI findings this module's shape depends on.

  ## Per decision 0014 (4): the Lua host API is the definition WASM conforms to

  Every semantic rule this module restates is read from
  `lib/letflow/engine/lua/platform.ex`, never re-derived. This module does not modify
  that file or any file under `lib/letflow/engine/lua/`.

  ## Capability source — REQ-167

  Gating for every function this module defines comes exclusively from
  `Letflow.Engine.Wasm.CapabilityGate`'s manifest-derived import-table whitelist
  (`build_import_table/1,2`) — no second capability model is introduced here.
  `read_variable` requires `"var:read"`, `log` requires `"audit:log"`, `now`/`uuid` are
  `:none`-gated (always installed, never denied) — see `capability_gate.ex`'s
  `@known_imports`. No function in this module performs a capability check itself; by
  the time any `do_*` function below runs, `CapabilityGate`'s import-table membership
  has already been the only gate applied (design §4.7).

  ## Tenant boundary (AC8, decision 0014 (e))

  Identical statement to REQ-159's own: host functions receive already-resolved
  values; the tenant prefix is supplied by the calling engine code, never derived
  inside a script. **No function this module defines calls `Letflow.Repo`, ever** —
  none of `read_variable`/`log`/`now`/`uuid` touches persistence. `execution_context`
  is supplied by whatever future dispatch-integration requirement calls
  `Letflow.Engine.Wasm.CapabilityGate.build_import_table/2` — never derived from a
  guest-supplied argument, never read from guest memory.

  ## Number marshalling (AC6) — REQ-150 §2.2, no second rule

  `read_variable`'s value is routed through
  `Letflow.Engine.LuaNumberMarshalling.to_lua/1` (REQ-150 §2.2, the read-direction
  identity rule for `integer()`/`float()`/`nil`) before being JSON-encoded onto the
  wire — exactly the same call `platform.ex`'s own `do_read_variable/3` makes before
  its `Lua.encode!/2` step. `Jason.encode!/1` is what makes the integer/float subtype
  visible on the wire; `to_lua/1`'s job is only to guarantee no coercion happened
  before that encoding step. One function, one call site pattern, reused verbatim —
  no WASM-specific numeric companion module exists or is needed.

  ## `uuid` has no Lua counterpart (AC5)

  `uuid` does not appear in `platform.ex`'s 8-row `@capability_matrix` — R-Co's own
  `src/wasm/host_api/uuid.zig` had no Lua-side sibling either, an asymmetry that
  predates Letflow's migration. This requirement implements `uuid` as a **documented
  WASM-side addition, not parity**: it shares `now`'s own capability rationale (a pure
  computation with no state reach, no tenant-data touch, no side effect), requires no
  Lua-side file edit, and reuses the existing `:none` gating mechanism. Whether Lua
  scripts should also gain a `platform.uuid()` is flagged as a candidate finding for
  ORCH, not resolved by this requirement.

  ## Callback ABI (Findings 1/4, design §1)

  Every `do_*` function's first argument is the raw `wasmex_callback_context()` map
  `wasmex` hands every callback — never narrowed or renamed — so
  `Letflow.Engine.Wasm.MemoryGuard.read/4`/`.write/4` are called with
  `context.caller`/`context.memory` directly, fetched fresh on every invocation (never
  a store/memory handle captured at import-table-construction time — `wasmex`'s own
  moduledoc warns a captured `store` can deadlock the call). `execution_context` is
  always the last argument, closed over by
  `Letflow.Engine.Wasm.CapabilityGate.build_import_table/2`'s fold — never part of the
  guest-visible call signature.

  ## Shared string-return buffer protocol (§5.2)

  Every function here that returns a string-shaped value to the guest
  (`read_variable`, `now`, `uuid`) shares one protocol: the **guest**, not the host,
  owns buffer allocation (`out_ptr`, `out_cap`), which avoids ever needing to call the
  guest's own `alloc` export mid-callback (a re-entrant-guest-call hazard `wasmex`'s
  `GenServer.call`-shaped dispatch makes dangerous). One `i32` result, three disjoint
  ranges:

    * `n >= 0` — `n` is the exact byte length of the UTF-8-encoded result. If
      `out_cap >= n`, the host has already written those `n` bytes to `out_ptr`. If
      `out_cap < n`, the host has written nothing — the guest must call again with a
      buffer of at least `n` bytes.
    * `-1` — **`read_variable`-only.** The variable is not present in
      `execution_context.variables` (parity with Lua's `nil` for an unset variable).
      Never returned by `now`/`uuid` (both always have a value).
    * `-2` — invalid argument: an input or output pointer/length pair failed
      `MemoryGuard`'s bounds check, or (`read_variable` only) the name bytes read back
      are not valid UTF-8. No bytes are written.

  ## Invariants

    * INV-HOSTAPI-1: no function this module defines calls `Letflow.Repo`, ever.
    * INV-HOSTAPI-2: no function this module defines raises, ever (a callback that
      raises produces the same opaque, indistinguishable-from-a-trap
      `{:error, binary()}` from `Wasmex.call_function/4` as a type-mismatched return —
      design §1 Finding 3 — so correctness must come from every callback body always
      returning a well-typed value).
    * INV-HOSTAPI-3: every guest memory access goes through
      `Letflow.Engine.Wasm.MemoryGuard.read/4` or `.write/4` — never `Wasmex.Memory.*`
      directly.
    * INV-HOSTAPI-4: `execution_context` is never constructed from guest-supplied
      bytes — always the value closed over at
      `Letflow.Engine.Wasm.CapabilityGate.build_import_table/2` call time.
  """

  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.LuaNumberMarshalling
  alias Letflow.Engine.Wasm.MemoryGuard

  require Logger

  @typedoc """
  The context map `wasmex` hands every callback (design §1 Finding 1/4) — never
  constructed by this module, only pattern-matched.
  """
  @type wasmex_callback_context :: %{
          memory: Wasmex.Memory.t(),
          caller: Wasmex.StoreOrCaller.t(),
          pid: pid(),
          instance: Wasmex.Instance.t()
        }

  @typedoc """
  WASM's own execution context (design §5.1) — same field semantics as
  `Letflow.Engine.Lua.Platform.execution_context()` minus `actor_id` (not needed until
  a future `emit_event`-equivalent, if one is ever added), but a **separate type**, not
  an alias or reuse of the Lua-side type — decision 0014 frames Lua and WASM as two
  independent handler families, and this is a bare map shape with no behavior
  attached.
  """
  @type execution_context :: %{
          instance_id: String.t() | nil,
          prefix: String.t() | nil,
          trace_id: String.t() | nil,
          script_identity: String.t() | nil,
          variables: map()
        }

  @doc """
  Returns the empty `execution_context()` sentinel: every field `nil` except
  `variables` (`%{}`). `read_variable` returns `-1` (not present) for every lookup
  against it, `log` still emits an entry with every correlation field `nil`, and
  `now`/`uuid` are unaffected (neither reads `execution_context` at all).
  """
  @spec empty_execution_context() :: execution_context()
  def empty_execution_context do
    %{
      instance_id: nil,
      prefix: nil,
      trace_id: nil,
      script_identity: nil,
      variables: %{}
    }
  end

  # Known log levels (design §5.4 step 4, mirrors platform.ex's map_log_level/1) --
  # declared here, ahead of every function referencing it below.
  @known_log_levels ~w(debug info warn error)

  # ── read_variable (design §5.3) ───────────────────────────────────────────────────
  #
  # Restates platform.ex's do_read_variable/3 (lines 596-607) at ABI parity: a plain
  # lookup on the closed-over, already-resolved execution_context.variables -- no
  # Letflow.Repo call, ever.
  @spec do_read_variable(
          context :: wasmex_callback_context(),
          name_ptr :: integer(),
          name_len :: integer(),
          out_ptr :: integer(),
          out_cap :: integer(),
          execution_context :: execution_context()
        ) :: integer()
  def do_read_variable(context, name_ptr, name_len, out_ptr, out_cap, execution_context) do
    with {:ok, name_bytes} <- MemoryGuard.read(context.caller, context.memory, name_ptr, name_len),
         {:ok, name} <- validate_utf8(name_bytes) do
      case Map.fetch(execution_context.variables, name) do
        {:ok, value} ->
          json_bytes =
            value
            |> LuaNumberMarshalling.to_lua()
            |> Jason.encode!()

          write_buffer_result(context, json_bytes, out_ptr, out_cap)

        :error ->
          -1
      end
    else
      {:error, _reason} -> -2
    end
  end

  # ── log (design §5.4) ─────────────────────────────────────────────────────────────
  #
  # Restates platform.ex's do_log/3 (lines 681-727) at ABI parity. Identity fields are
  # sourced EXCLUSIVELY from execution_context, never from guest-supplied bytes. Never
  # raises, on any input (results: [] -- log has no return-value channel to report a
  # failure through, so degrading gracefully is the only option that keeps "never
  # raises" true).
  @spec do_log(
          context :: wasmex_callback_context(),
          level_ptr :: integer(),
          level_len :: integer(),
          message_ptr :: integer(),
          message_len :: integer(),
          context_ptr :: integer(),
          context_len :: integer(),
          execution_context :: execution_context()
        ) :: nil
  def do_log(
        context,
        level_ptr,
        level_len,
        message_ptr,
        message_len,
        context_ptr,
        context_len,
        execution_context
      ) do
    {level_text, level_invalid_utf8?} =
      read_log_field(context, level_ptr, level_len, "<invalid level pointer>")

    {message_text, message_invalid_utf8?} =
      read_log_field(context, message_ptr, message_len, "<invalid message pointer>")

    {decoded_context, context_decode_error?} =
      read_log_context(context, context_ptr, context_len)

    level = map_log_level(level_text)

    metadata =
      [
        script_identity: execution_context.script_identity,
        instance_id: execution_context.instance_id,
        trace_id: execution_context.trace_id,
        context: decoded_context
      ]
      |> maybe_put(:original_level, level_text, level_text not in @known_log_levels)
      |> maybe_put(:raw_encoding, :invalid_utf8, level_invalid_utf8? or message_invalid_utf8?)
      |> maybe_put(:context_decode_error, true, context_decode_error?)

    Logger.log(level, message_text, metadata)

    nil
  end

  # ── now (design §5.5) ─────────────────────────────────────────────────────────────
  #
  # Calls Letflow.Engine.Lua.Platform.now/0 directly -- not a reimplementation, not a
  # second TimeSource resolution. This guarantees byte-for-byte identical output
  # between the Lua and WASM call paths under the same injected clock double, the
  # strongest possible form of parity. Does not modify platform.ex (a new caller, not
  # a change to the function) and does not violate decision 0014's "neither runtime is
  # given database access" boundary.
  @spec do_now(
          context :: wasmex_callback_context(),
          out_ptr :: integer(),
          out_cap :: integer()
        ) :: integer()
  def do_now(context, out_ptr, out_cap) do
    iso8601 = Platform.now()
    write_buffer_result(context, iso8601, out_ptr, out_cap)
  end

  # ── uuid (design §5.6/§3) ─────────────────────────────────────────────────────────
  #
  # No Lua counterpart -- see moduledoc. Ecto.UUID.generate/0's canonical form is
  # always exactly 36 bytes UTF-8, fixed length.
  @spec do_uuid(
          context :: wasmex_callback_context(),
          out_ptr :: integer(),
          out_cap :: integer()
        ) :: integer()
  def do_uuid(context, out_ptr, out_cap) do
    uuid = Ecto.UUID.generate()
    write_buffer_result(context, uuid, out_ptr, out_cap)
  end

  # ── §5.2's shared buffer protocol ─────────────────────────────────────────────────
  #
  # When out_cap >= byte_size(bytes), writes the full value and returns its length.
  # When out_cap is too small (including the out_cap = 0 length-probe case), writes
  # nothing but still validates out_ptr via a zero-length MemoryGuard.write/4 call
  # (design §5.2: "the host still validates out_ptr/0 via MemoryGuard before
  # returning n... a probe call with a genuinely invalid out_ptr still surfaces -2")
  # -- this keeps every guest memory touch, including the validate-only path, routed
  # through MemoryGuard (INV-HOSTAPI-3), never a direct Wasmex.Memory call.
  @spec write_buffer_result(wasmex_callback_context(), binary(), integer(), integer()) ::
          integer()
  defp write_buffer_result(context, bytes, out_ptr, out_cap) do
    n = byte_size(bytes)

    write_result =
      if out_cap >= n do
        MemoryGuard.write(context.caller, context.memory, out_ptr, bytes)
      else
        MemoryGuard.write(context.caller, context.memory, out_ptr, <<>>)
      end

    case write_result do
      :ok -> n
      {:error, _reason} -> -2
    end
  end

  @spec validate_utf8(binary()) :: {:ok, String.t()} | {:error, :invalid_utf8}
  defp validate_utf8(bytes) do
    if String.valid?(bytes) do
      {:ok, bytes}
    else
      {:error, :invalid_utf8}
    end
  end

  # Reads one log field (level/message). A MemoryGuard failure substitutes the given
  # fixed placeholder string and proceeds (design §5.4 step 1) rather than aborting --
  # log has no return-value channel to report a failure through. Invalid UTF-8 bytes
  # are rendered via inspect/1, mirroring platform.ex's own log_text/1 fallback.
  @spec read_log_field(wasmex_callback_context(), integer(), integer(), String.t()) ::
          {String.t(), boolean()}
  defp read_log_field(context, ptr, len, placeholder) do
    case MemoryGuard.read(context.caller, context.memory, ptr, len) do
      {:ok, bytes} ->
        if String.valid?(bytes) do
          {bytes, false}
        else
          {inspect(bytes), true}
        end

      {:error, _reason} ->
        {placeholder, false}
    end
  end

  # design §5.4 step 2 -- a zero context_len signals "no context" (WASM's arity is
  # fixed, unlike Lua's variable-arity call, so this is how a guest omits the
  # argument). Otherwise reads and JSON-decodes the bytes; either a MemoryGuard
  # failure or malformed JSON logs context as nil with context_decode_error: true,
  # never raising -- Jason.decode/1 (not decode!/1) is used here specifically to keep
  # this call site non-raising (INV-HOSTAPI-2).
  @spec read_log_context(wasmex_callback_context(), integer(), integer()) ::
          {term() | nil, boolean()}
  defp read_log_context(_context, _ptr, 0), do: {nil, false}

  defp read_log_context(context, ptr, len) do
    with {:ok, bytes} <- MemoryGuard.read(context.caller, context.memory, ptr, len),
         {:ok, decoded} <- Jason.decode(bytes) do
      {decoded, false}
    else
      _error -> {nil, true}
    end
  end

  defp map_log_level("debug"), do: :debug
  defp map_log_level("info"), do: :info
  defp map_log_level("warn"), do: :warning
  defp map_log_level("error"), do: :error
  defp map_log_level(_unrecognized), do: :info

  defp maybe_put(keyword, _key, _value, false), do: keyword
  defp maybe_put(keyword, key, value, true), do: keyword ++ [{key, value}]
end
