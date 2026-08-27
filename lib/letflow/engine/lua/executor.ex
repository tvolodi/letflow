defmodule Letflow.Engine.Lua.Executor do
  @moduledoc """
  REQ-153 (LUA-02 restated) — concrete `Executor` implementation for the tv-labs/lua
  BEAM runtime. Implements `@behaviour Letflow.Engine.LuaScriptAudit.Executor`.

  `script_ref` concrete shape: a binary containing the Lua source text to execute.

  Every call to `execute_with_manifest/2` creates a fresh `Lua.t()` via
  `Letflow.Engine.Lua.Sandbox.new/0` — no state is reused between invocations
  (LUA-02 isolation invariant). The manifest hash is the lowercase hex-encoded
  SHA-256 of the raw script source bytes, computed after execution succeeds.
  """

  @behaviour Letflow.Engine.LuaScriptAudit.Executor

  alias Letflow.Engine.Lua.Sandbox

  @impl Letflow.Engine.LuaScriptAudit.Executor
  @spec execute_with_manifest(binary(), String.t()) ::
          {:ok, %{manifest_hash: String.t()}} | {:error, term()}
  def execute_with_manifest(script_source, _registered_hash) when is_binary(script_source) do
    lua = Sandbox.new()

    try do
      Lua.eval!(lua, script_source)
      manifest_hash = :crypto.hash(:sha256, script_source) |> Base.encode16(case: :lower)
      {:ok, %{manifest_hash: manifest_hash}}
    rescue
      e in [Lua.RuntimeException, Lua.CompilerException] ->
        {:error, Exception.message(e)}
    end
  end
end
