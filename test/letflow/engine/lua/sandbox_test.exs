defmodule Letflow.Engine.Lua.SandboxTest do
  @moduledoc """
  Tests for `Letflow.Engine.Lua.Sandbox` (REQ-151, LUA-03/LUA-04 restated). See
  `test/specs/REQ-151.md` for the full test-case rationale and the
  acceptance-criteria mapping.

  Every test constructs its `Lua.t()` exclusively via `Letflow.Engine.Lua.Sandbox.new/0`
  or `new/1` -- never `Lua.new/1` directly -- so each assertion exercises the real
  production construction path.

  Empirical note (see spec for the full explanation, verified directly against a real
  `Sandbox.new/0` VM before writing these assertions, not assumed from the design doc's
  prose): every path in the 28-entry deny-set becomes a real raising function once
  *called*, regardless of whether the library "installs" something there by default --
  `Lua.sandbox/2` always writes a raising callable at the given path. So "referencing" a
  denied path (e.g. `return os.execute`) returns a truthy `NativeFunc`, and only
  *calling* it (e.g. `return os.execute('ls')`) raises `Lua.RuntimeException`. The one
  true exception is `string.dump`, which has no deny-set entry at all and evaluates to
  plain `nil` (nothing exists at that path to override); `coroutine` is the same
  (deliberately not sandboxed, asserted absent instead).

  No database or HTTP access anywhere in this file (pure Lua-VM construction and
  evaluation) -- `async: true` is safe.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Lua.Sandbox

  describe "the only call site (AC1)" do
    test "Lua.new( appears exactly once under lib/, inside sandbox.ex" do
      {output, 0} = System.cmd("grep", ["-rn", "Lua.new(", "lib", "--include=*.ex"])

      lines = output |> String.trim() |> String.split("\n")

      assert length(lines) == 1,
             "expected exactly one `Lua.new(` call site under lib/, got:\n#{output}"

      assert hd(lines) =~ "lib/letflow/engine/lua/sandbox.ex",
             "the single `Lua.new(` call site must be inside sandbox.ex, got:\n#{output}"
    end
  end

  describe "per-path denials (AC2) -- calling raises, except string.dump which is nil" do
    test "io.open raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return io.open('/etc/passwd')")
      end
    end

    test "io.write raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return io.write('x')")
      end
    end

    test "os.execute raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return os.execute('ls')")
      end
    end

    test "os.exit raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return os.exit()")
      end
    end

    test "os.getenv raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return os.getenv('HOME')")
      end
    end

    test "os.remove raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return os.remove('/tmp/x')")
      end
    end

    test "os.rename raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return os.rename('/tmp/x', '/tmp/y')")
      end
    end

    test "os.tmpname raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return os.tmpname()")
      end
    end

    test "load raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return load('return 1')")
      end
    end

    test "loadfile raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return loadfile('/etc/passwd')")
      end
    end

    test "dofile raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return dofile('/etc/passwd')")
      end
    end

    test "require raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return require('os')")
      end
    end

    test "package raises when indexed" do
      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(Sandbox.new(), "return package.path")
      end
    end

    test "debug raises when called" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return debug()")
      end
    end

    test "string.dump is nil (nothing installed at that path, no deny-set entry needed)" do
      {[result], _lua} = Lua.eval!(Sandbox.new(), "return string.dump")
      assert result == nil
    end
  end

  describe "default denials hold -- no custom list narrows them (AC3)" do
    test "os.execute and load remain denied via Sandbox.new/0" do
      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return os.execute('ls')")
      end

      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(Sandbox.new(), "return load('return 1')")
      end
    end

    test "os.execute and load remain denied via Sandbox.new/1 with arbitrary opts" do
      # Sandbox.new/1's opts define no meaningful keys for this requirement (design §3,
      # OQ-3) -- this proves that passing any options keyword list still yields the
      # full, unnarrowed 28-entry deny-set rather than some caller-influenced subset.
      sandbox = Sandbox.new(max_instructions: 1_000_000, some_future_key: :ignored)

      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(sandbox, "return os.execute('ls')")
      end

      assert_raise Lua.RuntimeException, ~r/sandboxed/, fn ->
        Lua.eval!(sandbox, "return load('return 1')")
      end
    end
  end

  describe "debug's metatable/upvalue functions are unreachable (AC2, design §4.2)" do
    test "debug.getmetatable raises" do
      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(Sandbox.new(), "return debug.getmetatable({})")
      end
    end

    test "debug.setmetatable raises" do
      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(Sandbox.new(), "return debug.setmetatable({}, {})")
      end
    end

    test "debug.getupvalue raises" do
      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(Sandbox.new(), "return debug.getupvalue(print, 1)")
      end
    end

    test "debug.setupvalue raises" do
      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(Sandbox.new(), "return debug.setupvalue(print, 1, nil)")
      end
    end
  end

  describe "coroutine is absent, not sandboxed (design §6, INV-SBX-3)" do
    test "coroutine evaluates to nil, not a raising function" do
      {[result], _lua} = Lua.eval!(Sandbox.new(), "return coroutine")
      assert result == nil
    end
  end

  describe "math, string, table remain usable (smoke test, not itself an AC)" do
    test "the MUST-load set works normally inside a Sandbox.new/0 VM" do
      {[floor_result, format_result, insert_result], _lua} =
        Lua.eval!(
          Sandbox.new(),
          """
          local t = {}
          table.insert(t, 42)
          return math.floor(3.7), string.format('%d', 5), t[1]
          """
        )

      assert floor_result == 3
      assert format_result == "5"
      assert insert_result == 42
    end
  end

  describe "moduledoc content (AC4, AC5, AC6)" do
    setup do
      {:docs_v1, _anno, _lang, _fmt, moduledoc, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine.Lua.Sandbox)

      %{"en" => text} = moduledoc
      %{moduledoc: text}
    end

    test "restates LUA-03's loadstring-absent-from-5.3 reason", %{moduledoc: text} do
      assert text =~ "loadstring"
      assert text =~ "Lua 5.1"
      assert text =~ "Lua 5.3"
    end

    test "restates LUA-03's jit/ffi/bit vacuity reason", %{moduledoc: text} do
      assert text =~ "jit"
      assert text =~ "ffi"
      assert text =~ "bit"
      assert text =~ "vacuous"
    end

    test "restates LUA-03's SBX-1 property-not-mechanism reason", %{moduledoc: text} do
      assert text =~ "SBX-1"
      assert text =~ "prune"
    end

    test "restates LUA-04's structural-holds text", %{moduledoc: text} do
      assert text =~ "LUA-04"
      assert text =~ "bytecode"
      assert text =~ "structurally"
    end

    test "records the coroutine decision and its reason", %{moduledoc: text} do
      assert text =~ "coroutine"
      assert text =~ "CREATE a new global"
    end

    test "names REQ-152 as the requirement that adds a custom deny-set list", %{
      moduledoc: text
    } do
      assert text =~ "REQ-152"
    end
  end
end
