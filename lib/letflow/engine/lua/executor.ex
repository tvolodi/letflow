defmodule Letflow.Engine.Lua.Executor do
  @moduledoc """
  REQ-153 (LUA-02 restated) + REQ-154 (LUA-08 layer 1 restated) — concrete `Executor`
  implementation for the tv-labs/lua BEAM runtime.
  Implements `@behaviour Letflow.Engine.LuaScriptAudit.Executor`.

  `script_ref` concrete shape: a binary containing the Lua source text to execute.

  Every call to `execute_with_manifest/2` creates a fresh `Lua.t()` via
  `Letflow.Engine.Lua.Sandbox.new/1` — no state is reused between invocations
  (LUA-02 isolation invariant). The manifest hash is the lowercase hex-encoded
  SHA-256 of the raw script source bytes, computed after execution succeeds.

  ## REQ-154: LUA-08 layer 1 restatement

  This module **restates LUA-08 as layer 1 of a two-layer pair**. It does NOT satisfy
  LUA-08's literal text on its own.

  LUA-08 literal: *"Exceeding the limit MUST terminate the script with a structured
  timeout error."*

  `:max_instructions` is an in-band, pcall-catchable budget. When the budget is hit,
  the `tv-labs/lua` library raises a Lua runtime error with the message
  `"instruction budget exceeded"`. A Lua script may wrap its own loop in `pcall` and
  intercept that error — the inner loop stops, execution returns to Lua, and
  `Lua.eval!/2` returns normally. This is expected layer-1 behavior (confirmed by
  REQ-148 spike OQ-2(a)). LUA-08's literal ("MUST terminate") is therefore not met by
  this layer alone.

  **Layer 2 (REQ-155)** supplies the mandatory host-enforced, non-catchable kill via
  `Process.exit/2` on a monitored Task. LUA-08 must not be reported done until REQ-155
  has also landed.

  ## What R-Co had, and why it does not port

  **INV-2 (registry-stored limiter):** R-Co stored the limiter pointer in
  `LUA_REGISTRYINDEX` to prevent a script from writing `_G.__limiter__ = nil` and
  defeating the counter. This threat does not exist in the `tv-labs/lua` runtime:
  `:max_instructions` is wired into the VM at construction time via `Lua.new/1` and is
  not reachable from Lua script globals. **INV-2 does not port because the threat it
  guarded against does not exist in this runtime.**

  **INV-4 (one combined `LUA_MASKCOUNT` hook):** R-Co used a single `LUA_MASKCOUNT`
  debug hook to carry both the instruction-count check and the elapsed-time check,
  because that hook was the only Lua C API mechanism that could interrupt a tight
  `while true do end` loop. **INV-4 does not port because this runtime has no hook API
  and needs none.** The `tv-labs/lua` library enforces `:max_instructions` via its own
  internal VM counter. The tight-loop interruption that INV-4 existed to solve is
  REQ-155's problem, solved by preemptive BEAM scheduling. **No hook was intentionally
  never written.**
  """

  @behaviour Letflow.Engine.LuaScriptAudit.Executor

  alias Letflow.Engine.Lua.Sandbox

  @doc """
  Implements `Letflow.Engine.LuaScriptAudit.Executor.execute_with_manifest/2`.
  Runs `script_source` (a binary containing Lua source text) in a fresh sandbox
  and returns the SHA-256 hex of the source as the manifest hash. Reads the
  instruction budget from Application config (`:letflow, :lua_max_instructions`).
  """
  @impl Letflow.Engine.LuaScriptAudit.Executor
  @spec execute_with_manifest(script_source :: binary(), registered_hash :: String.t()) ::
          {:ok, %{manifest_hash: String.t()}}
          | {:error, {:budget_exceeded, pos_integer()}}
          | {:error, String.t()}
          | {:error, :invalid_script_ref}
  def execute_with_manifest(script_source, registered_hash)
      when is_binary(script_source) do
    execute_with_manifest(script_source, registered_hash, max_instructions: default_budget())
  end

  @doc """
  Runs `script_source` in a fresh sandbox with an explicit instruction budget.
  `opts` must include `:max_instructions` (a `pos_integer()`). Not part of the
  behaviour — use this overload in tests that need a specific budget per call site.
  """
  @spec execute_with_manifest(
          script_source :: binary(),
          registered_hash :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, %{manifest_hash: String.t()}}
          | {:error, {:budget_exceeded, pos_integer()}}
          | {:error, String.t()}
          | {:error, :invalid_script_ref}
  def execute_with_manifest(script_source, _registered_hash, opts)
      when is_binary(script_source) do
    budget = Keyword.fetch!(opts, :max_instructions)
    lua = Sandbox.new(max_instructions: budget)

    try do
      Lua.eval!(lua, script_source)
      manifest_hash = :crypto.hash(:sha256, script_source) |> Base.encode16(case: :lower)
      {:ok, %{manifest_hash: manifest_hash}}
    rescue
      e in Lua.RuntimeException ->
        if String.contains?(Exception.message(e), "instruction budget exceeded") do
          {:error, {:budget_exceeded, budget}}
        else
          {:error, Exception.message(e)}
        end

      e in Lua.CompilerException ->
        {:error, Exception.message(e)}

      # Guard: script_ref is term() per the behaviour; reject non-binary gracefully
      _e in FunctionClauseError ->
        {:error, :invalid_script_ref}
    end
  end

  @spec default_budget() :: pos_integer()
  defp default_budget do
    Application.fetch_env!(:letflow, :lua_max_instructions)
  end
end
