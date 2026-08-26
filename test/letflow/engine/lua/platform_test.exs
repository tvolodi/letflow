defmodule Letflow.Engine.Lua.PlatformTest do
  @moduledoc """
  Tests for `Letflow.Engine.Lua.Platform` (REQ-152, LUA-14 restated). See
  `test/specs/REQ-152.md` for the full test-case rationale and the acceptance-criteria
  mapping.

  Every script-visible assertion constructs its `Lua.t()` exclusively via
  `Letflow.Engine.Lua.Sandbox.new/0` (never `Lua.new/1` directly, never
  `Letflow.Engine.Lua.Platform.install/1` called by hand) so each assertion exercises
  the real production composition path -- `platform.now` is reachable from a script only
  because `Sandbox.new/1` calls `Platform.install/1` itself.

  The `Application.put_env(:letflow, :lua_platform_time_source, ...)` swap used below
  is reverted in `on_exit` in every test that sets it, so tests remain order-independent
  and never leak a fixed clock into an unrelated test. `async: false` because these
  tests mutate a shared, process-independent piece of state (application env) that
  `Platform.now/0` reads fresh on every call -- running them concurrently with each
  other (or with any other test that happens to call `Platform.now/0` while a swap is
  active) would race.
  """

  use ExUnit.Case, async: false

  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.Lua.Sandbox

  defmodule FixedTimeSource do
    @moduledoc false
    @behaviour Platform.TimeSource

    @impl Platform.TimeSource
    def now, do: ~U[2026-01-01 00:00:00.000000Z]
  end

  describe "platform.now() returns an ISO 8601 UTC string parseable by DateTime.from_iso8601/1 (AC4)" do
    test "called from inside a script" do
      {[result], _lua} = Lua.eval!(Sandbox.new(), "return platform.now()")

      assert is_binary(result)
      assert {:ok, %DateTime{} = dt, 0} = DateTime.from_iso8601(result)
      assert dt.time_zone == "Etc/UTC"
    end

    test "Platform.now/0 called directly also returns a DateTime.from_iso8601/1-parseable string" do
      result = Platform.now()

      assert is_binary(result)
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(result)
    end
  end

  describe "the time source is injectable -- exact pre-set timestamp, not merely well-formed (AC5)" do
    setup do
      previous = Application.get_env(:letflow, :lua_platform_time_source)
      Application.put_env(:letflow, :lua_platform_time_source, FixedTimeSource)

      on_exit(fn ->
        if previous do
          Application.put_env(:letflow, :lua_platform_time_source, previous)
        else
          Application.delete_env(:letflow, :lua_platform_time_source)
        end
      end)

      :ok
    end

    test "Platform.now/0 returns the exact fixed timestamp, not a merely well-formed one" do
      expected = DateTime.to_iso8601(~U[2026-01-01 00:00:00.000000Z])

      assert Platform.now() == expected
    end

    test "platform.now() called from inside a script also returns the exact fixed timestamp" do
      expected = DateTime.to_iso8601(~U[2026-01-01 00:00:00.000000Z])

      {[result], _lua} = Lua.eval!(Sandbox.new(), "return platform.now()")

      assert result == expected
    end

    test "swapping the fixed source back out restores real, non-fixed values" do
      fixed = Platform.now()

      Application.put_env(:letflow, :lua_platform_time_source, Platform.SystemClock)

      real = Platform.now()

      refute real == fixed
    end
  end

  describe "moduledoc content (AC7)" do
    setup do
      {:docs_v1, _anno, _lang, _fmt, moduledoc, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine.Lua.Platform)

      %{"en" => text} = moduledoc
      %{moduledoc: text}
    end

    test "states platform.now is ungated by design, not an omission", %{moduledoc: text} do
      assert text =~ "ungated by design"
      assert text =~ "not an omission"
    end

    test "states no capability check, gate, or permission lookup exists in now's call path", %{
      moduledoc: text
    } do
      assert text =~ "no capability"
      assert text =~ "gate"
    end

    test "states a future requirement adding a capability gate to platform.now by symmetry is wrong",
         %{moduledoc: text} do
      assert text =~ "REQ-157"
      assert text =~ "symmetry"
    end

    test "states the injection mechanism -- behaviour + application-env resolution", %{
      moduledoc: text
    } do
      assert text =~ "TimeSource"
      assert text =~ "application env"
    end

    test "states install/1's composition point -- Sandbox.new calls it", %{moduledoc: text} do
      assert text =~ "Sandbox.new"
      assert text =~ "install"
    end
  end
end
