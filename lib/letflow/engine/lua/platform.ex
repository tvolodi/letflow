defmodule Letflow.Engine.Lua.Platform do
  @moduledoc """
  REQ-152 (LUA-14 restated) — implements the `platform.now()` half of LUA-14 ("Time
  Source, MUST"): `platform.now()` MUST return the platform's authoritative time as ISO
  8601 UTC. The other half of LUA-14 (denying `os.time` and its ambient-time siblings) is
  implemented in `Letflow.Engine.Lua.Sandbox`'s deny-set, not here — see that module's
  moduledoc for the restatement of why `os.date`/`os.clock`/`os.difftime`/`os.setlocale`
  are also denied, beyond LUA-14's literal wording.

  This module owns two concerns, deliberately kept together rather than split across
  files: what `platform.now()` returns (`now/0`), and how it becomes reachable from a Lua
  script at all (`install/1`).

  ## `platform.now` is ungated by design — not an omission

  Per decision 0014 / R-Co's `src/lua/host_api/mod.zig` capability matrix: `now` is "a
  pure time read with no state reach," and that matrix entry is "a POSITIVE design
  statement, not an omission ... A test that expects a gate on either is reading the
  matrix wrong."

  **Binding statement for future requirements:** `platform.now/0` has no capability
  check, no gate, no permission lookup, anywhere in its call path — by design,
  permanently, not "not yet implemented." `install/1` wires it unconditionally into every
  `Lua.t()` that `Letflow.Engine.Lua.Sandbox.new/0` or `new/1` produces; there is no
  `Sandbox.new/1` option that can suppress or gate it, and none should ever be added.
  REQ-157's future capability-gating work MUST NOT add a gate to `platform.now` "by
  symmetry" with whatever gating mechanism it introduces for other `platform.*`
  functions.

  ## Time-source injection — behaviour + application-env resolution

  `now/0` never reads `DateTime.utc_now/0` directly. It resolves the configured
  `#{inspect(__MODULE__)}.TimeSource` implementation from application env
  (`Application.get_env(:letflow, :lua_platform_time_source, ...)`), read fresh on every
  call (never cached), and calls that implementation's `now/0` callback. This lets a test
  swap in a fixed-value double via `Application.put_env/3` in `setup`/`on_exit`, without
  recompiling or restarting any supervision tree, and asserts `platform.now()` returns
  one exact, pre-set timestamp rather than merely a well-formed one. The default
  implementation, `#{inspect(__MODULE__)}.SystemClock`, is the one and only production
  call site of `DateTime.utc_now/0` this requirement's module set introduces.

  ## Composition point

  `install/1` is called from `Letflow.Engine.Lua.Sandbox.new/1`'s construction pipeline,
  immediately after the sandboxed VM is constructed — every `Lua.t()` produced by
  `Sandbox.new/0` or `Sandbox.new/1` therefore has `platform.now` available with no
  second call any caller must remember to make. `install/1` never touches the deny-set:
  installing a new global at `[:platform, :now]` and denying paths under `[:os, ...]` are
  independent operations.
  """

  alias Letflow.Engine.Lua.Platform.TimeSource

  @type iso8601_utc :: String.t()

  @default_time_source Letflow.Engine.Lua.Platform.SystemClock

  @doc """
  Returns the current authoritative time as an ISO 8601 UTC string, e.g.
  `"2026-08-26T14:32:07.123456Z"`. Reads the configured `TimeSource` implementation from
  application env on every call (never a direct `DateTime.utc_now/0` read at this call
  site) so the source is injectable for exact-value testing. Never fails: no I/O, no user
  input — reading an injected time source and formatting it cannot fail.
  """
  @spec now() :: iso8601_utc()
  def now do
    source = Application.get_env(:letflow, :lua_platform_time_source, @default_time_source)

    source.now()
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  @doc """
  Installs `platform.now` into `lua` at the Lua-visible path `platform.now`. Additive
  only — never touches the sandbox deny-set. Called once from
  `Letflow.Engine.Lua.Sandbox.new/1`'s construction pipeline; not intended to be called
  directly by any other caller.
  """
  @spec install(lua :: Lua.t()) :: Lua.t()
  def install(%Lua{} = lua) do
    Lua.set!(lua, [:platform, :now], fn _args -> [now()] end)
  end

  defmodule TimeSource do
    @moduledoc """
    Behaviour for `Letflow.Engine.Lua.Platform.now/0`'s injectable time source. A test
    double implements this behaviour and is installed via
    `Application.put_env(:letflow, :lua_platform_time_source, <module>)` to make
    `platform.now()` return one exact, pre-set timestamp.
    """

    @type source_now_result :: DateTime.t()

    @callback now() :: source_now_result()
  end

  defmodule SystemClock do
    @moduledoc """
    Default `TimeSource` implementation. The one and only production call site of
    `DateTime.utc_now/0` this requirement's module set (`platform.ex`) introduces — every
    other read of "now" for Lua-visible time goes through `Platform.now/0`, which
    resolves the configured `TimeSource` rather than reading the system clock directly.
    """

    @behaviour TimeSource

    @impl TimeSource
    @spec now() :: DateTime.t()
    def now, do: DateTime.utc_now()
  end
end
