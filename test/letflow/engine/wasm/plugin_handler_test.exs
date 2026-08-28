defmodule Letflow.Engine.Wasm.PluginHandlerTest do
  @moduledoc """
  REQ-165 -- coverage for `Letflow.Engine.Wasm.PluginHandler`, the first
  `wasmex`-backed `Letflow.Engine.PluginInterface` handler. See
  `lib/letflow/design/req165-wasmex-process-boundary.md` (gate-approved) and
  `test/specs/REQ-165.md` for the full rationale and AC traceability.

  `async: false`: this module builds a real Wasmtime instance per test via
  `wasmex`'s NIF and shells out to nothing else, but the AC5 hang test
  deliberately runs a guest that never returns until brutally killed --
  keeping the file serial avoids any risk of two such calls overlapping
  under scheduler pressure across `async: true` test processes.
  """

  use ExUnit.Case, async: false

  alias Letflow.Engine.PluginInterface
  alias Letflow.Engine.PluginInterface.ExecutionContext
  alias Letflow.Engine.Wasm.CallTimeout
  alias Letflow.Engine.Wasm.PluginHandler

  defp context(overrides \\ %{}) do
    %ExecutionContext{
      instance_id: Map.get(overrides, :instance_id, Ecto.UUID.generate()),
      definition_id: Map.get(overrides, :definition_id, Ecto.UUID.generate()),
      node_id: Map.get(overrides, :node_id, "node-1"),
      node_type: Map.get(overrides, :node_type, "SERVICE_TASK"),
      variables: Map.get(overrides, :variables, %{}),
      node_config: Map.get(overrides, :node_config, %{}),
      trace_id: Map.get(overrides, :trace_id, "trace-1")
    }
  end

  # ---------------------------------------------------------------------
  # AC6: plugin_interface.ex is unmodified by this requirement.
  # ---------------------------------------------------------------------

  describe "AC6: plugin_interface.ex is unmodified" do
    test "git diff --stat against plugin_interface.ex is empty" do
      # `main` only exists as a local branch in a dev checkout; CI's checkout
      # of a PR branch has no local `main` ref, only `origin/main`. Try both
      # so this test works in either shape.
      base_ref =
        Enum.find(["origin/main", "main"], fn ref ->
          match?(
            {_, 0},
            System.cmd("git", ["rev-parse", "--verify", ref], stderr_to_stdout: true)
          )
        end)

      assert base_ref, "expected either 'origin/main' or 'main' to resolve as a git ref"

      {output, 0} =
        System.cmd("git", [
          "diff",
          "--stat",
          "#{base_ref}...HEAD",
          "--",
          "lib/letflow/engine/plugin_interface.ex"
        ])

      assert String.trim(output) == "",
             "expected no diff against plugin_interface.ex, got: #{output}"
    end
  end

  # ---------------------------------------------------------------------
  # AC3 / AC4: dispatched via PluginInterface.invoke/2, {:complete, map()},
  # and the guest runs in a different process than the caller.
  # ---------------------------------------------------------------------

  describe "AC3/AC4: trivial guest via PluginInterface.invoke/2" do
    test "returns {:complete, map} and runs in a different process than the caller" do
      test_pid = self()
      # Mutation-testing gap found by TEST-DESIGNER (test/specs/REQ-165.md):
      # `handler_pid != test_pid` alone is satisfied by ANY pre-existing
      # process, including one hardcoded and unrelated to the actual guest
      # call (e.g. `Process.whereis(:application_controller)`) -- that
      # mutation was NOT caught by this assertion. Snapshotting the live
      # process set before the call and asserting `handler_pid` is a
      # process that did not exist yet closes that gap: only a genuinely
      # freshly spawned task pid (Task.Supervisor.async_nolink/2, per the
      # design's §4) can satisfy it.
      pids_before = MapSet.new(Process.list())

      assert {:complete, %{"answer" => 42, "executed_in_pid" => handler_pid}} =
               PluginInterface.invoke(PluginHandler, context())

      assert is_pid(handler_pid)
      assert handler_pid != test_pid

      refute MapSet.member?(pids_before, handler_pid),
             "expected executed_in_pid to be a process freshly spawned for this call, " <>
               "not a pre-existing one"

      assert Process.alive?(test_pid)
    end
  end

  # ---------------------------------------------------------------------
  # Mutation-testing gap found by TEST-DESIGNER (see test/specs/REQ-165.md
  # findings table): removing `run_guest/2`'s `GenServer.stop(pid)` call on
  # the success path was NOT caught by any of the 9 existing tests -- none
  # of them observed the wasmex instance's lifetime, only the outcome map.
  # This test targets that lifetime directly: `Wasmex.start_link/1` starts
  # an ordinary `use GenServer` process (see `deps/wasmex/lib/wasmex.ex`),
  # so a leaked instance is a live process whose `$initial_call` process
  # dictionary entry names the `Wasmex` module. Because `GenServer.stop/1`
  # is synchronous (it blocks the caller until `terminate/2` completes), a
  # correct implementation has already reaped the instance by the time
  # `PluginInterface.invoke/2` returns -- no sleep/wait is needed for this
  # assertion to be deterministic.
  # ---------------------------------------------------------------------

  defp wasmex_pids do
    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          match?({Wasmex, _, _}, Keyword.get(dict, :"$initial_call"))

        _ ->
          false
      end
    end)
  end

  describe "no leaked Wasmex instance after a successful call" do
    test "the wasmex GenServer started for the call is stopped before invoke/2 returns" do
      before_pids = wasmex_pids()

      assert {:complete, %{"answer" => 42}} = PluginInterface.invoke(PluginHandler, context())

      leaked = wasmex_pids() -- before_pids

      assert leaked == [],
             "expected no leaked Wasmex GenServer after a successful call, got: #{inspect(leaked)}"
    end
  end

  # ---------------------------------------------------------------------
  # AC5: a hanging guest is bounded by PluginInterface.invoke/3's own
  # supervised-task timeout, surfacing as {:error, reason}, never an
  # exception/exit into the calling process.
  # ---------------------------------------------------------------------

  describe "AC5: a hanging guest is terminated by the outer task timeout" do
    test "surfaces as {:error, reason} naming the outer timeout, no rescue/catch needed" do
      hang_context =
        context(%{
          node_config: %{"wasm_fixture" => "wasm_fixtures/req165_hang.wat", "export" => "hang"}
        })

      test_pid = self()

      assert {:error, reason} =
               PluginInterface.invoke(PluginHandler, hang_context, timeout_ms: 100)

      assert reason =~ "did not respond within 100ms"
      # Positive check that no exit signal reached the caller.
      assert Process.alive?(test_pid)
    end
  end

  # ---------------------------------------------------------------------
  # AC7: no external Wasm runtime dependency at deploy time -- resolves the
  # design's own OQ-D1 by verifying wasmex's real introspection surface
  # against a compiled build, rather than assuming an API.
  # ---------------------------------------------------------------------

  describe "AC7: the wasmex NIF is a loaded shared library, not an external process" do
    test "Wasmex.Native resolves to a compiled .beam built from Rust NIF sources" do
      beam_path = :code.which(Wasmex.Native)
      refute beam_path in [:non_existing, :cover_compiled, :preloaded]

      external_resources =
        Wasmex.Native.module_info(:attributes)
        |> Keyword.get_values(:external_resource)
        |> List.flatten()

      assert Enum.any?(external_resources, &String.contains?(&1, "native/wasmex/src/")),
             "expected Wasmex.Native's external_resource attributes to name its Rust NIF sources"
    end

    test "the compiled NIF shared library is bundled inside wasmex's own priv/, not fetched at runtime" do
      priv_dir = :code.priv_dir(:wasmex)
      refute priv_dir == {:error, :bad_name}

      so_path = Path.join(priv_dir, "native/wasmex.so")
      assert File.exists?(so_path), "expected #{so_path} to exist as a bundled shared library"
    end

    test "invoking the guest opens no new OS ports (no external process/IPC boundary)" do
      ports_before = :erlang.ports()

      assert {:complete, %{"answer" => 42}} = PluginInterface.invoke(PluginHandler, context())

      ports_after = :erlang.ports()
      assert ports_after -- ports_before == []
    end
  end

  # ---------------------------------------------------------------------
  # AC7 (moduledoc restatement) / AC8 (residual risk disclosure) --
  # moduledoc content-string tests mirroring
  # test/letflow/engine/lua/executor_test.exs's AC-5 technique.
  # ---------------------------------------------------------------------

  describe "moduledoc content" do
    test "AC7: moduledoc restates WASM-01's mechanism clause" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(PluginHandler)

      assert moduledoc =~ "WASM-01"
      assert moduledoc =~ "Rust NIF"
      assert moduledoc =~ "C API"
      normalized = String.replace(moduledoc, ~r/\s+/, " ")
      assert normalized =~ "No external Wasm runtime dependency at deploy time"
    end

    test "AC8: moduledoc discloses the residual native-crash risk uncovered by the boundary" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(PluginHandler)

      assert moduledoc =~ "Residual risk"
      assert moduledoc =~ "NOT covered by the process boundary"
      assert moduledoc =~ "crash the **entire BEAM node**" or moduledoc =~ "crash the"
      assert moduledoc =~ "System.halt/0"

      assert moduledoc =~ "does **not** bound a native crash" or
               moduledoc =~ "does not bound a native crash"
    end
  end

  # ---------------------------------------------------------------------
  # REQ-170 AC1: a guest blocked in a host call is bounded by the
  # configured wasm-level timeout_ms, and the caller receives a structured
  # {:error, reason} within it, not the outer @default_timeout_ms 30_000ms.
  #
  # HONESTY CLAUSE (design doc §5.2 item 3 / §1.1-§1.4): this test does
  # NOT prove the guest's underlying native execution is terminated -- it
  # is not. Live verification (design §1.1-§1.4) found the hung guest's
  # native compute keeps running forever in wasmex's own separate native
  # worker-thread pool; only the CALLER's wait is bounded here, via
  # wasmex's own client-side GenServer.call timeout mechanism crashing the
  # task, which Letflow.Engine.PluginInterface's existing {:exit, reason}
  # handling turns into a clean {:error, reason} for the caller.
  # ---------------------------------------------------------------------

  describe "REQ-170 AC1: configured timeout_ms bounds the caller's wait" do
    test "returns {:error, reason} within the configured timeout_ms, not the outer default" do
      hang_context =
        context(%{
          node_config: %{
            "wasm_fixture" => "wasm_fixtures/req170_hang.wat",
            "export" => "hang",
            "timeout_ms" => 500
          }
        })

      {elapsed_us, result} =
        :timer.tc(fn -> PluginInterface.invoke(PluginHandler, hang_context) end)

      elapsed_ms = System.convert_time_unit(elapsed_us, :microsecond, :millisecond)

      assert {:error, reason} = result
      assert is_binary(reason)
      # Generous upper bound: comfortably bounded by the configured 500ms,
      # nowhere near PluginInterface's own outer 30_000ms default.
      assert elapsed_ms < 10_000,
             "expected the call to be bounded by the configured 500ms timeout_ms, " <>
               "not the outer 30_000ms default; took #{elapsed_ms}ms"

      assert CallTimeout.classify(result) == :wall_clock_timeout
    end
  end

  # ---------------------------------------------------------------------
  # REQ-170 AC3: the outer PluginInterface.invoke/3 supervised-task
  # boundary terminates the invocation independently of a longer (or
  # absent) inner wasmex-level timeout_ms -- design doc §1.6/§5.4.
  # ---------------------------------------------------------------------

  describe "REQ-170 AC3: outer invoke_opts timeout_ms bounds the caller independently of node_config timeout_ms" do
    test "the outer, shorter bound fires and the dispatched task dies shortly after" do
      hang_context =
        context(%{
          node_config: %{
            "wasm_fixture" => "wasm_fixtures/req170_hang.wat",
            "export" => "hang",
            # deliberately LONGER than the outer invoke_opts bound below --
            # proves the outer boundary does not depend on the inner
            # wasmex-level timeout ever firing first.
            "timeout_ms" => 60_000
          }
        })

      # Mirrors PluginInterface.invoke/3's own async_nolink/yield/shutdown
      # shape directly so the dispatched task's pid is observable to this
      # test (invoke/3's own wrapper does not expose it).
      task =
        Task.Supervisor.async_nolink(Letflow.Engine.PluginTaskSupervisor, fn ->
          PluginHandler.handle_node(hang_context)
        end)

      {elapsed_us, yield_result} = :timer.tc(fn -> Task.yield(task, 500) end)
      elapsed_ms = System.convert_time_unit(elapsed_us, :microsecond, :millisecond)

      assert yield_result == nil,
             "expected the outer 500ms bound to fire before the hung guest ever replies"

      assert elapsed_ms < 5_000,
             "expected Task.yield/2 to return around its own 500ms bound, took #{elapsed_ms}ms"

      Task.shutdown(task, :brutal_kill)

      refute Process.alive?(task.pid),
             "expected the dispatched task to be dead shortly after the outer bound fired, " <>
               "independent of the much longer inner timeout_ms"
    end
  end

  # ---------------------------------------------------------------------
  # REQ-170 AC4: timeout_ms is configurable -- two different values drive
  # two different elapsed times, with the shorter one binding sooner.
  # Real wall-clock timing, loose tolerance (design §5.5): not exact
  # millisecond assertions.
  # ---------------------------------------------------------------------

  describe "REQ-170 AC4: the shorter configured timeout_ms binds sooner" do
    test "a 300ms timeout_ms elapses faster than a 2_000ms timeout_ms" do
      build_context = fn timeout_ms ->
        context(%{
          node_config: %{
            "wasm_fixture" => "wasm_fixtures/req170_hang.wat",
            "export" => "hang",
            "timeout_ms" => timeout_ms
          }
        })
      end

      {short_elapsed_us, short_result} =
        :timer.tc(fn -> PluginInterface.invoke(PluginHandler, build_context.(300)) end)

      {long_elapsed_us, long_result} =
        :timer.tc(fn -> PluginInterface.invoke(PluginHandler, build_context.(2_000)) end)

      assert {:error, _} = short_result
      assert {:error, _} = long_result

      short_elapsed_ms = System.convert_time_unit(short_elapsed_us, :microsecond, :millisecond)
      long_elapsed_ms = System.convert_time_unit(long_elapsed_us, :microsecond, :millisecond)

      assert short_elapsed_ms < long_elapsed_ms,
             "expected the 300ms-configured call (#{short_elapsed_ms}ms) to bind sooner than " <>
               "the 2_000ms-configured call (#{long_elapsed_ms}ms)"
    end

    # Mutation-driven strengthening (WF-02 Step 3, REQ-170): the relative-
    # ordering test above only proves a SHORTER configured value binds
    # sooner than a LONGER one -- it does not prove `call_export/3` actually
    # threads `timeout_ms` through to `Wasmex.call_function/4`'s 4th
    # argument at all. Mutating `call_export/3` to silently drop the
    # argument (`Wasmex.call_function(pid, export, [])`, falling back to
    # wasmex's own hardcoded 5_000ms default regardless of what
    # `node_config["timeout_ms"]` says) was NOT caught by that test:
    # confirmed locally, both the 300ms- and 2_000ms-configured calls
    # collapsed to ~5_000ms under the mutation, and since 5_000 < 5_000 is
    # false either way the ordering happened to still be observed as "short
    # < long" by luck of scheduling jitter in one run (26/26 passed against
    # the mutation). This test closes the gap by configuring a `timeout_ms`
    # LONGER than wasmex's own hardcoded 5_000ms default and asserting the
    # elapsed wait exceeds that hardcoded default -- if `timeout_ms` were
    # silently dropped, the call would instead bind at ~5_000ms and this
    # assertion would fail.
    test "timeout_ms longer than wasmex's hardcoded 5_000ms default still governs the wait (guards against timeout_ms being silently dropped)" do
      hang_context =
        context(%{
          node_config: %{
            "wasm_fixture" => "wasm_fixtures/req170_hang.wat",
            "export" => "hang",
            "timeout_ms" => 7_000
          }
        })

      {elapsed_us, result} =
        :timer.tc(fn -> PluginInterface.invoke(PluginHandler, hang_context) end)

      elapsed_ms = System.convert_time_unit(elapsed_us, :microsecond, :millisecond)

      assert {:error, _reason} = result

      assert elapsed_ms > 6_000,
             "expected the call to be bounded by the configured 7_000ms timeout_ms, not " <>
               "wasmex's own hardcoded 5_000ms default; took #{elapsed_ms}ms -- a value near " <>
               "5_000ms means timeout_ms is being silently dropped before reaching " <>
               "Wasmex.call_function/4"

      # Still comfortably below the outer PluginInterface default (30_000ms).
      assert elapsed_ms < 15_000
    end
  end

  # ---------------------------------------------------------------------
  # AC1/AC9 sanity: the trivial guest fixture and handler round-trip.
  # ---------------------------------------------------------------------

  describe "handle_node/1 directly (sanity, not the crash-safety path)" do
    test "the trivial guest fixture answers 42" do
      assert {:complete, %{"answer" => 42, "executed_in_pid" => pid}} =
               PluginHandler.handle_node(context())

      assert pid == self()
    end
  end
end
