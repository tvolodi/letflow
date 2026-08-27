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
      # `function_exported?/3` checks only already-loaded code -- unlike calling a
      # function, it does not implicitly load the module first (see
      # `:erlang.function_exported/3`). Under `mix test --partitions`, ExUnit's
      # random async ordering can make this the very first reference to `Executor`
      # in that partition's VM, so without `Code.ensure_loaded/1` first this
      # assertion is a real, reproduced flake (not a race in the code under test).
      assert {:module, Executor} = Code.ensure_loaded(Executor)
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
                 timeout_ms: 5_000,
                 max_heap_words: nil
               )

      assert {:ok, %{manifest_hash: _}} =
               Executor.execute_with_manifest(loop_script, "h",
                 max_instructions: 50000,
                 timeout_ms: 5_000,
                 max_heap_words: nil
               )
    end

    # AC-2: while true terminates under a budget rather than hanging.
    test "AC-2: while true do end terminates with budget_exceeded rather than hanging" do
      assert {:error, {:budget_exceeded, 1000}} =
               Executor.execute_with_manifest("while true do end", "h",
                 max_instructions: 1000,
                 timeout_ms: 5_000,
                 max_heap_words: nil
               )
    end

    # AC-3: budget exhaustion is distinguishable by pattern match from other error arms.
    test "AC-3: budget_exceeded is a structured error, not a bare string or atom" do
      result =
        Executor.execute_with_manifest("while true do end", "h",
          max_instructions: 500,
          timeout_ms: 5_000,
          max_heap_words: nil
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
                 timeout_ms: 5_000,
                 max_heap_words: nil
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
            timeout_ms: 100,
            max_heap_words: nil
          )
        end)

      {long_elapsed_us, long_result} =
        :timer.tc(fn ->
          Executor.execute_with_manifest(@infinite_loop, "h",
            max_instructions: 1_000_000_000,
            timeout_ms: 600,
            max_heap_words: nil
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
                 timeout_ms: 300,
                 max_heap_words: nil
               )
    end

    # T3/AC-3: the killed task's process is actually dead, not merely abandoned.
    test "AC-3: the task's process is dead and no longer tracked by the supervisor after a timeout" do
      children_before = Task.Supervisor.children(Letflow.Engine.Lua.TaskSupervisor)

      assert {:error, {:wallclock_timeout, 150}} =
               Executor.execute_with_manifest(@infinite_loop, "h",
                 max_instructions: 1_000_000_000,
                 timeout_ms: 150,
                 max_heap_words: nil
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
          timeout_ms: 100,
          max_heap_words: nil
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
          timeout_ms: 5_000,
          max_heap_words: nil
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
            timeout_ms: 300,
            max_heap_words: nil
          )
        end)

      assert_receive :started, 1_000

      # Poll for the in-flight child instead of a single fixed sleep+check: under
      # host load contention a fixed sleep can miss the window entirely (checked
      # too early, before execute_with_manifest/3 has spawned its supervised task,
      # or too late, after scheduler jitter has delayed this process past it).
      # Poll in small increments up to a bound well under the call's own
      # timeout_ms (300) above, so the loop still proves a real in-flight child
      # was observed -- it never falls back to asserting something trivially
      # true, it just gives the spawn more chances to be caught mid-flight.
      children =
        Enum.reduce_while(1..20, [], fn _attempt, _acc ->
          case Task.Supervisor.children(Letflow.Engine.Lua.TaskSupervisor) do
            [] ->
              Process.sleep(10)
              {:cont, []}

            found ->
              {:halt, found}
          end
        end)

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

  # ---------------------------------------------------------------------------------
  # REQ-156 -- configurable memory limit (LUA-09 restated)
  # ---------------------------------------------------------------------------------
  #
  # All tests here target execute_with_manifest/3 so each test drives its own
  # :max_heap_words explicitly (test/specs/REQ-156.md's stated rationale, mirroring
  # REQ-154/155's own pattern) -- no test relies on config/test.exs's
  # :lua_max_heap_words default.
  #
  # Word/byte conversion: :max_heap_words counts BEAM machine words, not bytes.
  # word_size_bytes comes from :erlang.system_info(:wordsize) (typically 8 on a
  # 64-bit BEAM) rather than a hardcoded `8` literal, per design §3, so the
  # conversion stays correct if this ever runs on a different word size.
  describe "configurable memory limit (REQ-156)" do
    @word_size_bytes :erlang.system_info(:wordsize)

    # LUA-09's own acceptance text names "1 GB attempted / 16 MB limit" as the scale
    # to test at -- both are converted from the literal MB/GB figures via
    # @word_size_bytes rather than picked "for convenience". This script is shared by
    # T2 and T3's third arm (per the design's coverage note), but each test below
    # independently asserts its own outcome rather than depending on the other
    # having run first.
    @sixteen_mb_in_words trunc(16 * 1024 * 1024 / @word_size_bytes)
    @gigabyte_allocating_script """
    local t = {}
    for i = 1, 1000000 do
      -- 1000 x 1024-byte chunks per outer iteration isn't needed -- one 1024-byte
      -- string per iteration, times 1,000,000 iterations, targets ~1 GB total
      -- (1_000_000 * 1024 bytes ~= 976 MB), matching LUA-09's own "1 GB" example.
      t[i] = string.rep("x", 1024)
    end
    return #t
    """

    # AC-1 uses a smaller allocating script than AC-2's literal "1 GB" scale, for test
    # speed only -- running @gigabyte_allocating_script to full, unkilled completion
    # (needed for AC-1's "larger limit succeeds" arm) measured ~18s real time in this
    # environment (tv-labs/lua interpreter throughput, not the memory-limit mechanism
    # under test), which is too slow to run twice per `mix test` invocation across
    # dozens of CI/local runs. This script targets ~20 MB (20,000 x 1024-byte
    # strings) -- a 1:20 attempted/limit ratio against @small_alloc_heap_words below
    # (~1 MB), the same order of magnitude as AC-2's own 1 GB : 16 MB (~1:64) ratio,
    # so it still genuinely exercises the same mechanism rather than being a
    # convenience no-op. AC-2 below keeps the literal "1 GB attempted / 16 MB limit"
    # scale LUA-09's own acceptance criterion names, unscaled.
    @small_alloc_heap_words trunc(1 * 1024 * 1024 / @word_size_bytes)
    @moderate_allocating_script """
    local t = {}
    for i = 1, 20000 do
      t[i] = string.rep("x", 1024)
    end
    return #t
    """

    # AC-1/T1: the memory limit is configurable per call (not hardcoded) -- a smaller
    # configured limit halts the same allocating script with a structured error,
    # while a materially larger limit lets the same script run to completion. This
    # demonstrates the configured value is load-bearing (not a no-op), per design
    # §8 AC-1 and test/specs/REQ-156.md T1's "outcome differs" alternative to a pure
    # timing comparison.
    test "AC-1: a smaller configured max_heap_words halts sooner than a larger one on the same allocating script" do
      {small_elapsed_us, small_result} =
        :timer.tc(fn ->
          Executor.execute_with_manifest(@moderate_allocating_script, "h",
            max_instructions: 1_000_000_000,
            timeout_ms: 5_000,
            max_heap_words: @small_alloc_heap_words
          )
        end)

      {large_elapsed_us, large_result} =
        :timer.tc(fn ->
          Executor.execute_with_manifest(@moderate_allocating_script, "h",
            max_instructions: 1_000_000_000,
            timeout_ms: 5_000,
            max_heap_words: trunc(200 * 1024 * 1024 / @word_size_bytes)
          )
        end)

      assert {:error, :memory_limit_exceeded} = small_result
      assert {:ok, %{manifest_hash: _}} = large_result

      small_elapsed_ms = small_elapsed_us / 1_000
      large_elapsed_ms = large_elapsed_us / 1_000

      assert small_elapsed_ms < large_elapsed_ms,
             "the smaller max_heap_words limit (#{small_elapsed_ms}ms) must halt the " <>
               "allocating script sooner than the larger limit's full run " <>
               "(#{large_elapsed_ms}ms)"
    end

    # AC-2/T2: LUA-09's own acceptance criterion, at the scale it names -- a script
    # attempting to allocate ~1 GB under a ~16 MB configured limit fails cleanly with
    # a structured error, rather than hanging, exhausting the test node's memory, or
    # returning success. The outer ExUnit test timeout (default 60s, well above this
    # call's own 5_000ms :timeout_ms) is this test's own safety bound -- if a
    # regression removed the memory-kill path entirely, this call would return
    # {:error, {:wallclock_timeout, 5_000}} instead (still a structured error, not a
    # hang), and the assertion below would fail loudly rather than the suite hanging.
    test "AC-2: a script attempting to allocate 1 GB under a 16 MB configured limit fails cleanly" do
      assert {:error, :memory_limit_exceeded} =
               Executor.execute_with_manifest(@gigabyte_allocating_script, "h",
                 max_instructions: 1_000_000_000,
                 timeout_ms: 5_000,
                 max_heap_words: @sixteen_mb_in_words
               )
    end

    # AC-3/T3: the memory-limit error is pattern-distinguishable from REQ-154's
    # budget_exceeded and REQ-155's wallclock_timeout -- one case/cond construct
    # matches all three arms distinctly, proving no two can unify under one pattern.
    test "AC-3: memory_limit_exceeded is pattern-distinguishable from budget_exceeded and wallclock_timeout" do
      budget_result =
        Executor.execute_with_manifest("while true do end", "h",
          max_instructions: 500,
          timeout_ms: 5_000,
          max_heap_words: nil
        )

      timeout_result =
        Executor.execute_with_manifest("while true do end", "h",
          max_instructions: 1_000_000_000,
          timeout_ms: 200,
          max_heap_words: nil
        )

      memory_result =
        Executor.execute_with_manifest(@gigabyte_allocating_script, "h",
          max_instructions: 1_000_000_000,
          timeout_ms: 5_000,
          max_heap_words: @sixteen_mb_in_words
        )

      classify = fn
        {:error, {:budget_exceeded, _}} -> :budget_exceeded
        {:error, {:wallclock_timeout, _}} -> :wallclock_timeout
        {:error, :memory_limit_exceeded} -> :memory_limit_exceeded
        other -> other
      end

      assert classify.(budget_result) == :budget_exceeded
      assert classify.(timeout_result) == :wallclock_timeout
      assert classify.(memory_result) == :memory_limit_exceeded

      classified = Enum.map([budget_result, timeout_result, memory_result], classify)

      assert Enum.uniq(classified) == classified,
             "all three resource-limit arms must classify distinctly; got #{inspect(classified)}"
    end

    # AC-6/T6: no code path in this module uses :max_instructions as a memory-limit
    # proxy -- static/source-level check, since this is a negative claim about the
    # absence of a code path (design §9, test/specs/REQ-156.md T6 item 1).
    test "AC-6: no code path reads max_heap_words when computing max_instructions, or vice versa" do
      source = File.read!("lib/letflow/engine/lua/executor.ex")

      # Sandbox.new/1 (which applies max_instructions to the Lua VM) is called with
      # only `budget`, never mentioning max_heap_words on the same call.
      assert source =~ "Sandbox.new(max_instructions: budget)"

      # The spawn_opt max_heap_size map is built only from max_heap_words, never from
      # budget/max_instructions.
      assert source =~ "max_heap_size: %{size: max_heap_words"
      refute source =~ "max_heap_size: %{size: budget"
    end

    # AC-5/T5: moduledoc restates LUA-09 and states which clause is met and which is
    # not, in those words.
    test "AC-5: moduledoc restates LUA-09 and states 'terminate' MET / 'fail gracefully' NOT MET" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "LUA-09"
      assert moduledoc =~ ~s("terminate the script" is MET)
      assert moduledoc =~ ~s("fail gracefully" is NOT MET)
    end

    # AC-6/T6: moduledoc records the :max_instructions-as-memory-proxy rejection,
    # citing decision 0014 OQ-1 by name.
    test "AC-6: moduledoc states :max_instructions was rejected as a memory proxy, citing decision 0014 OQ-1" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "rejected as a memory-limit proxy"
      assert moduledoc =~ "decision 0014"
      assert moduledoc =~ "OQ-1"
    end

    # AC-4: moduledoc states the Task.Supervisor.async_nolink/2,3 finding plainly
    # (§7 item 3 of the design) rather than silently resolving it.
    test "AC-4: moduledoc states Task.Supervisor.async_nolink/2,3 cannot carry max_heap_size" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "Task.Supervisor.async_nolink/2,3` cannot carry `:max_heap_size`"
      assert moduledoc =~ ":erlang.spawn_opt/2"
    end

    # A configured max_heap_words of nil keeps the REQ-155 supervised-task path
    # observable exactly as before -- a nil-limit execution still shows up as a
    # Letflow.Engine.Lua.TaskSupervisor child while in flight, unlike a
    # memory-limited execution (design §5.4).
    test "a nil max_heap_words leaves the REQ-155 TaskSupervisor-based path unchanged" do
      test_pid = self()

      task =
        Task.async(fn ->
          send(test_pid, :started)

          Executor.execute_with_manifest("while true do end", "h",
            max_instructions: 1_000_000_000,
            timeout_ms: 300,
            max_heap_words: nil
          )
        end)

      assert_receive :started, 1_000

      children =
        Enum.reduce_while(1..20, [], fn _attempt, _acc ->
          case Task.Supervisor.children(Letflow.Engine.Lua.TaskSupervisor) do
            [] ->
              Process.sleep(10)
              {:cont, []}

            found ->
              {:halt, found}
          end
        end)

      assert children != [],
             "a nil max_heap_words call must still run under Letflow.Engine.Lua.TaskSupervisor"

      assert {:error, {:wallclock_timeout, 300}} = Task.await(task, 1_000)
    end
  end
end
