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

  alias Letflow.Engine.Lua.Capabilities
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

  describe "REQ-157: closed-set enumeration (AC1)" do
    test "a script enumerates exactly the 8 platform.* names via pairs(platform), no more, no fewer" do
      script = """
      local names = {}
      for k, _v in pairs(platform) do
        table.insert(names, k)
      end
      table.sort(names)
      return table.concat(names, ",")
      """

      {[result], _lua} = Lua.eval!(Sandbox.new(), script)

      expected =
        ~w(call_service emit_event fail get_instance_state log now read_variable write_variable)
        |> Enum.sort()
        |> Enum.join(",")

      assert result == expected
    end

    test "platform.ex's source contains exactly one Lua.set!(_, [:platform, occurrence (the single fold)" do
      source = File.read!("lib/letflow/engine/lua/platform.ex")

      # Matches only an actual call-site pattern (`Lua.set!(<accumulator>, [:platform,`),
      # not the moduledoc/comment prose describing the invariant in words -- guards
      # against a future hand-added 9th `Lua.set!` call bypassing the matrix fold,
      # regardless of what the fold's own accumulator variable happens to be named.
      occurrences =
        ~r/Lua\.set!\([a-z_]+,\s*\[:platform,/
        |> Regex.scan(source)
        |> length()

      assert occurrences == 1
    end
  end

  describe "REQ-157: per-function capability-denial tests, empty grant set (AC2)" do
    setup do
      lua = Platform.install(Sandbox.new(), Capabilities.new())
      %{lua: lua}
    end

    test "platform.read_variable(...) raises Lua.RuntimeException", %{lua: lua} do
      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(lua, "return platform.read_variable('x')")
      end
    end

    test "platform.write_variable(...) raises Lua.RuntimeException", %{lua: lua} do
      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(lua, "return platform.write_variable('x', 'y')")
      end
    end

    test "platform.log(...) raises Lua.RuntimeException", %{lua: lua} do
      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(lua, "return platform.log('hello')")
      end
    end

    test "platform.emit_event(...) raises Lua.RuntimeException", %{lua: lua} do
      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(lua, "return platform.emit_event('evt')")
      end
    end

    test "platform.get_instance_state(...) raises Lua.RuntimeException", %{lua: lua} do
      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(lua, "return platform.get_instance_state()")
      end
    end

    test "platform.call_service(\"any-service\") raises Lua.RuntimeException", %{lua: lua} do
      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(lua, "return platform.call_service('any-service')")
      end
    end
  end

  describe "REQ-157: structured denial fields (AC3)" do
    test "rescuing read_variable's denial exposes function, required, and granted" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.read_variable('x')")
        end

      assert exception.original[:function] == :read_variable
      assert exception.original[:capability_required] == "variable:read"
      assert exception.original[:capabilities_granted] == []
    end
  end

  describe "REQ-157: call_service denial without any grant (AC4)" do
    test "platform.call_service(\"billing\") without a service:call:billing grant raises with the exact required capability" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.call_service('billing')")
        end

      assert exception.original[:capability_required] == "service:call:billing"
    end
  end

  describe "REQ-157: call_service grant is parameterised, not blanket (AC5)" do
    setup do
      lua = Platform.install(Sandbox.new(), Capabilities.new(["service:call:alpha"]))
      %{lua: lua}
    end

    test "a service:call:alpha grant lets platform.call_service('alpha') pass the gate (reaches the stub's own raise)",
         %{lua: lua} do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.call_service('alpha')")
        end

      # Passed the gate: this is the stub's "not yet implemented" raise, not a capability
      # denial -- no capability_required field on this exception.
      assert exception.original[:capability_required] == nil
      assert exception.original[:stub] == true
    end

    test "the same grant does NOT authorise platform.call_service('beta')", %{lua: lua} do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.call_service('beta')")
        end

      assert exception.original[:capability_required] == "service:call:beta"
      assert exception.original[:capabilities_granted] == ["service:call:alpha"]
    end
  end

  describe "REQ-157: now and fail are callable with an empty capability set (AC6)" do
    test "platform.now() returns its normal value with no raise at all" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      {[result], _lua} = Lua.eval!(lua, "return platform.now()")

      assert is_binary(result)
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(result)
    end

    test "platform.fail() raises the stub's own explicit-failure error, not a capability denial" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.fail()")
        end

      assert exception.original[:reason] == :explicit_fail
      assert exception.original[:capability_required] == nil
    end
  end

  describe "REQ-157: moduledoc content (AC7)" do
    setup do
      {:docs_v1, _anno, _lang, _fmt, moduledoc, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine.Lua.Platform)

      %{"en" => text} = moduledoc
      %{moduledoc: text}
    end

    test "reproduces the 8-row capability matrix in substance", %{moduledoc: text} do
      for name <-
            ~w(call_service read_variable write_variable log emit_event get_instance_state now fail) do
        assert text =~ name
      end

      assert text =~ "service:call:"
      assert text =~ "variable:read"
      assert text =~ "variable:write"
      assert text =~ "audit:log"
      assert text =~ "event:emit"
      assert text =~ "instance:read"
    end

    test "states the now/fail ungated rationale", %{moduledoc: text} do
      assert text =~ "pure time read with no state reach"
      assert text =~ "may always terminate itself"
    end

    test "carries the binding statement guarding against a future gate on now or fail", %{
      moduledoc: text
    } do
      assert text =~ "A test that expects a gate on `now` or `fail` is reading the matrix wrong"
    end
  end
end
