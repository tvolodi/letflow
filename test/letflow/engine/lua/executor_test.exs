defmodule Letflow.Engine.Lua.ExecutorTest do
  @moduledoc """
  Tests for `Letflow.Engine.Lua.Executor` (REQ-153, LUA-02 restated). Covers all 8
  acceptance criteria from the requirement.

  No database access required — the isolation tests exercise only the Lua VM, and the
  INV-LSA-1 / INV-LSA-2 paths short-circuit before any Repo insert. `async: true` is
  safe.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Lua.Executor
  alias Letflow.Engine.LuaScriptAudit

  # ---------------------------------------------------------------------------------
  # AC1 -- module exists and implements the Executor behaviour
  # ---------------------------------------------------------------------------------

  describe "behaviour implementation (AC1)" do
    test "Executor implements the Letflow.Engine.LuaScriptAudit.Executor behaviour" do
      behaviours =
        Executor.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Letflow.Engine.LuaScriptAudit.Executor in behaviours
    end

    test "execute_with_manifest/2 is exported" do
      assert function_exported?(Executor, :execute_with_manifest, 2)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- lua_script_audit.ex does NOT reference the concrete Executor module
  # ---------------------------------------------------------------------------------

  describe "lua_script_audit.ex isolation (AC2)" do
    test "lua_script_audit.ex does not reference Letflow.Engine.Lua.Executor" do
      source = File.read!("lib/letflow/engine/lua_script_audit.ex")

      refute source =~ "Letflow.Engine.Lua.Executor",
             "lua_script_audit.ex must not directly reference the concrete Executor module"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- global isolation: a global set in execution 1 is absent in execution 2
  # ---------------------------------------------------------------------------------

  describe "global isolation (AC3)" do
    test "a global written in execution 1 is absent in execution 2" do
      # Execution 1: set a global
      assert {:ok, _} = Executor.execute_with_manifest("MY_GLOBAL = 42", "any-hash")

      # Execution 2 through the same executor: if MY_GLOBAL leaked, Lua's error() fires
      # and the executor returns {:error, _}. assert {:ok, _} therefore PROVES absence.
      # (Asserting {:ok, _} on `return MY_GLOBAL` would be vacuous because execute_with_manifest
      # discards the Lua return value -- both nil and 42 would yield {:ok, _} there.)
      assert {:ok, _} =
               Executor.execute_with_manifest(
                 "if MY_GLOBAL ~= nil then error('global_leaked: MY_GLOBAL = ' .. tostring(MY_GLOBAL)) end",
                 "any-hash"
               ),
             "MY_GLOBAL must be absent (nil) in a fresh executor invocation"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- distinct state: table mutated in exec 1 is pristine in exec 2
  # ---------------------------------------------------------------------------------

  describe "distinct state (AC4)" do
    test "a table mutated in execution 1 is pristine in execution 2" do
      # Execution 1: create and populate a table
      assert {:ok, _} = Executor.execute_with_manifest("T = {}; T.x = 99", "h1")

      # Execution 2 through the same executor: if T leaked, Lua's error() fires and the
      # executor returns {:error, _}. assert {:ok, _} PROVES T is nil/absent.
      assert {:ok, _} =
               Executor.execute_with_manifest(
                 "if T ~= nil then error('table_T_leaked: T.x = ' .. tostring(T.x)) end",
                 "h2"
               ),
             "table T from execution 1 must not survive into execution 2"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- INV-LSA-1: invalid instance_id short-circuits before executor is invoked
  # ---------------------------------------------------------------------------------

  describe "INV-LSA-1 with real executor (AC5)" do
    test "nil instance_id short-circuits and the real executor is never called" do
      result =
        LuaScriptAudit.execute_script_for_audit(
          Executor,
          nil,
          "return 1",
          "any-hash",
          Ecto.UUID.generate(),
          prefix: "test_schema"
        )

      assert result == {:error, :invalid_instance_id}
    end

    test "malformed instance_id short-circuits and the real executor is never called" do
      result =
        LuaScriptAudit.execute_script_for_audit(
          Executor,
          "not-a-uuid",
          "return 1",
          "any-hash",
          Ecto.UUID.generate(),
          prefix: "test_schema"
        )

      assert result == {:error, :invalid_instance_id}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- INV-LSA-2: manifest hash mismatch with real executor
  # ---------------------------------------------------------------------------------

  describe "INV-LSA-2 with real executor (AC6)" do
    test "a registered_hash that does not match the script's SHA-256 returns mismatch error" do
      script = "return 2 + 2"
      real_hash = :crypto.hash(:sha256, script) |> Base.encode16(case: :lower)
      wrong_hash = "0000000000000000000000000000000000000000000000000000000000000000"

      assert wrong_hash != real_hash

      result =
        LuaScriptAudit.execute_script_for_audit(
          Executor,
          Ecto.UUID.generate(),
          script,
          wrong_hash,
          Ecto.UUID.generate(),
          prefix: "test_schema"
        )

      assert {:error, {:manifest_hash_mismatch, ^wrong_hash, ^real_hash}} = result
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- moduledoc documents the script_ref concrete shape
  # ---------------------------------------------------------------------------------

  describe "moduledoc documents script_ref shape (AC7)" do
    test "the module's @moduledoc mentions that script_ref is a binary (Lua source text)" do
      docs = Code.fetch_docs(Executor)
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = docs

      assert moduledoc =~ "binary",
             "moduledoc must state that script_ref is a binary; got:\n#{moduledoc}"
    end
  end

  # ---------------------------------------------------------------------------------
  # Bonus: successful execution returns the correct SHA-256 manifest hash
  # ---------------------------------------------------------------------------------

  describe "manifest hash correctness" do
    test "execute_with_manifest returns the SHA-256 of the script source on success" do
      script = "return 'hello'"
      expected_hash = :crypto.hash(:sha256, script) |> Base.encode16(case: :lower)

      assert {:ok, %{manifest_hash: ^expected_hash}} =
               Executor.execute_with_manifest(script, "ignored")
    end

    test "a Lua syntax error returns {:error, reason}" do
      assert {:error, _reason} = Executor.execute_with_manifest("this is not lua ===", "h")
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-154 -- instruction budget (LUA-08 layer 1)
  # ---------------------------------------------------------------------------------

  describe "instruction budget (REQ-154)" do
    # AC-1: configurable budget -- two different budgets produce different outcomes
    # for a loop that exceeds 500 instructions but not 5000.
    test "AC-1: smaller budget halts sooner than larger budget on the same loop" do
      # This loop runs many more than 500 instructions but fewer than 50000.
      loop_script = "for i = 1, 5000 do end"

      assert {:error, {:budget_exceeded, 500}} =
               Executor.execute_with_manifest(loop_script, "h",
                 max_instructions: 500,
                 timeout_ms: 5_000
               )

      assert {:ok, %{manifest_hash: _}} =
               Executor.execute_with_manifest(loop_script, "h",
                 max_instructions: 50000,
                 timeout_ms: 5_000
               )
    end

    # AC-2: while true terminates under a budget rather than hanging.
    test "AC-2: while true do end terminates with budget_exceeded rather than hanging" do
      assert {:error, {:budget_exceeded, 1000}} =
               Executor.execute_with_manifest("while true do end", "h",
                 max_instructions: 1000,
                 timeout_ms: 5_000
               )
    end

    # AC-3: budget exhaustion is distinguishable by pattern match from other error arms.
    test "AC-3: budget_exceeded is a structured error, not a bare string or atom" do
      result =
        Executor.execute_with_manifest("while true do end", "h",
          max_instructions: 500,
          timeout_ms: 5_000
        )

      # Must NOT match {:error, msg} (string) or {:error, :invalid_script_ref}
      assert {:error, {:budget_exceeded, _limit}} = result
    end

    # AC-4: REQ-148 spike OQ-2(a) -- pcall catches budget exhaustion inside the script.
    # The inner loop stops, pcall returns {false, "instruction budget exceeded"}, and
    # Lua.eval!/2 returns normally. This is expected layer-1 behavior: the script
    # receives control back after pcall. Layer 2 (REQ-155) provides the non-catchable kill.
    test "AC-4: pcall-caught budget exhaustion returns {:ok, _} -- layer-1 pcall-catchable" do
      script = """
      local ok, err = pcall(function() while true do end end)
      return ok, tostring(err)
      """

      assert {:ok, %{manifest_hash: _}} =
               Executor.execute_with_manifest(script, "h",
                 max_instructions: 1000,
                 timeout_ms: 5_000
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-155 -- host-enforced wall-clock kill (LUA-10 layer 2)
  # ---------------------------------------------------------------------------------
  #
  # All tests here target execute_with_manifest/3 so each test drives its own
  # :timeout_ms independent of Application config (test/specs/REQ-155.md's stated
  # rationale). config/test.exs sets a short :lua_wallclock_timeout_ms (200ms) for
  # any incidental /2-arity default-path use, but no test below relies on it.

  describe "wall-clock timeout (REQ-155)" do
    @infinite_loop "while true do end"

    # T1/AC-1: timeout is configurable -- two different configured timeouts produce
    # measurably different elapsed wall-clock time on the same hanging script, and
    # the shorter one's error carries its own configured value (not a hardcoded
    # constant).
    test "AC-1: a shorter configured timeout terminates measurably sooner than a longer one" do
      {short_elapsed_us, short_result} =
        :timer.tc(fn ->
          Executor.execute_with_manifest(@infinite_loop, "h",
            max_instructions: 1_000_000_000,
            timeout_ms: 100
          )
        end)

      {long_elapsed_us, long_result} =
        :timer.tc(fn ->
          Executor.execute_with_manifest(@infinite_loop, "h",
            max_instructions: 1_000_000_000,
            timeout_ms: 600
          )
        end)

      assert {:error, {:wallclock_timeout, 100}} = short_result
      assert {:error, {:wallclock_timeout, 600}} = long_result

      short_elapsed_ms = short_elapsed_us / 1_000
      long_elapsed_ms = long_elapsed_us / 1_000

      # The short call must not have waited anywhere near as long as the long
      # call's configured timeout -- generous margin to keep this non-flaky under
      # CI scheduling jitter while still proving the configured value (not a fixed
      # constant) drives the elapsed time.
      assert short_elapsed_ms < 400,
             "short-timeout call took #{short_elapsed_ms}ms, expected well under 400ms"

      assert long_elapsed_ms > short_elapsed_ms,
             "long-timeout call (#{long_elapsed_ms}ms) should take longer than the " <>
               "short-timeout call (#{short_elapsed_ms}ms)"
    end

    # T2/AC-2: decision 0014's required two-layer test. A script that traps its own
    # :max_instructions exhaustion (via pcall) and re-enters a second unbounded loop
    # must STILL be terminated by the wall-clock layer -- this must fail if layer 2
    # is removed or bypassed, since the script never lets the in-band budget error
    # propagate.
    #
    # Verified empirically against the tv-labs/lua runtime (not assumed): a *second*
    # `while`/`for` loop after the budget trips is NOT a usable reproduction here --
    # this runtime's :max_instructions counter is permanently exhausted once tripped,
    # so any further `while`/`for` iteration re-raises {:budget_exceeded, _} almost
    # immediately (confirmed via scratch probes against
    # Letflow.Engine.Lua.Sandbox/Lua.eval! directly), which layer 1 alone already
    # terminates -- it would not distinguish "layer 2 present" from "layer 2 removed"
    # and so would not be the test decision 0014 requires. A `goto`-based loop,
    # however, is NOT instrumented by this runtime's instruction-budget check at all
    # (confirmed empirically: it hangs indefinitely with no :max_instructions error),
    # which is precisely LUA-10's own point -- a hostile script can always find an
    # in-band escape hatch the counter does not cover, and only a host-external,
    # non-cooperative kill can bound it. This script traps the first while-loop's
    # budget error via pcall (proving the script observed and ignored it), then
    # continues running via `goto`, invisible to :max_instructions, so only the
    # wall-clock layer can end the call.
    test "AC-2: wall-clock timeout still fires when the script traps its own budget error and loops again via a construct the instruction budget does not instrument" do
      script = """
      local ok, err = pcall(function() while true do end end)
      -- budget error caught and ignored here; script deliberately keeps running
      -- instead of returning, via a construct :max_instructions does not check.
      ::top::
      goto top
      """

      assert {:error, {:wallclock_timeout, 300}} =
               Executor.execute_with_manifest(script, "h",
                 max_instructions: 200,
                 timeout_ms: 300
               )
    end

    # T3/AC-3: the killed task's process is actually dead, not merely abandoned.
    test "AC-3: the task's process is dead and no longer tracked by the supervisor after a timeout" do
      children_before = Task.Supervisor.children(Letflow.Engine.Lua.TaskSupervisor)

      assert {:error, {:wallclock_timeout, 150}} =
               Executor.execute_with_manifest(@infinite_loop, "h",
                 max_instructions: 1_000_000_000,
                 timeout_ms: 150
               )

      # Give the (already brutally-killed) task's DOWN bookkeeping a moment to
      # settle inside the supervisor, then confirm no new child lingers relative
      # to before the call -- the kill removed exactly the child it started, not
      # merely abandoned it while the caller stopped waiting.
      Process.sleep(50)

      children_after = Task.Supervisor.children(Letflow.Engine.Lua.TaskSupervisor)

      assert Enum.sort(children_after) == Enum.sort(children_before),
             "no task started by the timed-out call may remain a child of " <>
               "Letflow.Engine.Lua.TaskSupervisor after the call returns"
    end

    # T4/AC-4: the timeout error is a distinct, pattern-matchable shape.
    test "AC-4: wallclock_timeout does not match budget_exceeded, a bare string, or invalid_script_ref" do
      result =
        Executor.execute_with_manifest(@infinite_loop, "h",
          max_instructions: 1_000_000_000,
          timeout_ms: 100
        )

      assert {:error, {:wallclock_timeout, 100}} = result
      refute match?({:error, {:budget_exceeded, _}}, result)
      refute match?({:error, msg} when is_binary(msg), result)
      refute match?({:error, :invalid_script_ref}, result)
    end

    # T5/AC-4: regression guard -- budget_exceeded remains its own distinct shape
    # and is never confused with wallclock_timeout, even under a generous timeout
    # that plays no role in the outcome.
    test "AC-4 regression guard: budget_exceeded is unaffected by a generous timeout and stays distinct" do
      result =
        Executor.execute_with_manifest(@infinite_loop, "h",
          max_instructions: 500,
          timeout_ms: 5_000
        )

      assert {:error, {:budget_exceeded, 500}} = result
      refute match?({:error, {:wallclock_timeout, _}}, result)
      refute match?({:error, msg} when is_binary(msg), result)
      refute match?({:error, :invalid_script_ref}, result)
    end

    # T6/AC-5: execution runs under the named, dedicated supervisor.
    test "AC-5: the running script is a child of Letflow.Engine.Lua.TaskSupervisor while in flight" do
      test_pid = self()

      task =
        Task.async(fn ->
          send(test_pid, :started)

          Executor.execute_with_manifest(@infinite_loop, "h",
            max_instructions: 1_000_000_000,
            timeout_ms: 300
          )
        end)

      assert_receive :started, 1_000
      # Give execute_with_manifest/3 a moment to actually spawn its own supervised
      # task before checking the supervisor's children.
      Process.sleep(50)

      children = Task.Supervisor.children(Letflow.Engine.Lua.TaskSupervisor)
      assert children != [], "expected at least one in-flight child while the script is running"

      # Let the in-flight call finish (times out on its own) so the test doesn't
      # leak a lingering process.
      assert {:error, {:wallclock_timeout, 300}} = Task.await(task, 1_000)
    end

    test "AC-5: moduledoc names Letflow.Engine.Lua.TaskSupervisor and justifies not reusing PluginTaskSupervisor" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "Letflow.Engine.Lua.TaskSupervisor"
      assert moduledoc =~ "Letflow.Engine.PluginTaskSupervisor"
    end

    # T7/AC-6: moduledoc restates LUA-10 as layer 2 and the non-interchangeability
    # rationale.
    test "AC-6: moduledoc restates LUA-10 as layer 2 of the LUA-08/LUA-10 pair" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "LUA-10"
      assert moduledoc =~ "layer 2"
      assert moduledoc =~ "enforced by the host"
      assert moduledoc =~ "cooperate"
      # AC-6 also requires the moduledoc to state that neither LUA-08 nor LUA-10 is
      # satisfied without both layers landed together -- distinct from merely naming
      # "layer 2", which the four assertions above already cover.
      assert moduledoc =~ "Neither LUA-08 nor LUA-10 is met",
             "moduledoc must state that neither LUA-08 nor LUA-10 is met without both layers"
    end

    # T8/AC-7: moduledoc carries forward the BEAM-node-kill / System.halt/0
    # limitation disclosure.
    test "AC-7: moduledoc discloses the BEAM-node-kill / System.halt/0 limitation" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "System.halt/0"
      assert moduledoc =~ "BEAM node"
      # A bare "NOT" is too weak on its own to prove the disclosure is attached to the
      # right subject -- assert it appears specifically as the negation covering the
      # BEAM-node-kill / System.halt/0 sentence, not merely somewhere unrelated in the
      # moduledoc.
      assert moduledoc =~ "does **NOT** cover a hard kill of the BEAM node",
             "moduledoc must explicitly negate coverage of a BEAM node kill / System.halt/0"
    end
  end
end
