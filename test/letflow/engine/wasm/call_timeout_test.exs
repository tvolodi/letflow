defmodule Letflow.Engine.Wasm.CallTimeoutTest do
  @moduledoc """
  REQ-170 -- coverage for `Letflow.Engine.Wasm.CallTimeout`. See
  `lib/letflow/design/req170-wasm-wallclock-timeout.md` (gate-approved) for
  the full rationale, live-verification findings, and AC traceability
  these tests exercise.

  SAFETY NOTE (design doc §1.5/§5.7): this file deliberately does NOT
  reproduce the design's 32-concurrent-hang worker-pool-saturation
  scenario -- that scenario durably occupies `wasmex`'s shared,
  node-global native thread pool for the remainder of any test run it is
  part of, corrupting every other WASM test's own timing assumptions.
  That finding is recorded as a one-time, this-design-session live result
  only (design §1.5, §8), not an automated regression test here.

  `async: false`: every test here builds a real Wasmtime instance via
  `wasmex`'s NIF, mirroring `plugin_handler_test.exs`'s and
  `resource_limits_test.exs`'s identical rationale for keeping WASM-NIF
  tests serial.
  """

  use ExUnit.Case, async: false

  alias Letflow.Engine.PluginInterface
  alias Letflow.Engine.PluginInterface.ExecutionContext
  alias Letflow.Engine.Wasm.CallTimeout
  alias Letflow.Engine.Wasm.PluginHandler
  alias Letflow.Engine.Wasm.ResourceLimits

  defp fixture_bytes(name) do
    Application.app_dir(:letflow, "priv")
    |> Path.join("wasm_fixtures/#{name}")
    |> File.read!()
  end

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
  # AC2 (design §1.1/§1.2/§5.3): verify wasmex's documented
  # interrupt-and-keep-Store claim by running it DIRECTLY against
  # Wasmex.call_function/4 (not through PluginHandler) -- and assert the
  # REAL, live-verified behavior: a crash/exit, not a clean {:error, _};
  # a second call on the same pid also never replies.
  # ---------------------------------------------------------------------

  describe "AC2: wasmex's documented interrupt-and-keep-Store claim, tested directly against Wasmex.call_function/4" do
    test "a timed-out call crashes the caller with an ordinary GenServer.call exit, not a clean {:error, _}" do
      {:ok, pid} = Wasmex.start_link(%{bytes: fixture_bytes("req170_hang.wat")})

      first_result =
        try do
          {:clean_return, Wasmex.call_function(pid, "hang", [], 500)}
        catch
          :exit, reason -> {:exit, reason}
        end

      assert {:exit, reason} = first_result,
             "expected wasmex's documented timeout to interrupt cleanly with {:error, _}, but " <>
               "live verification (design §1.1) found it crashes the caller instead with an " <>
               "ordinary GenServer.call exit -- this test asserts the REAL behavior, not the " <>
               "documented claim"

      # {:timeout, {GenServer, :call, [...]}} -- design §1.1's exact shape.
      assert match?({:timeout, {GenServer, :call, _}}, reason)

      # Second half of the documented claim ("keeps the Store available for
      # subsequent calls"): live-verified FALSE (design §1.2) -- a second
      # call on the same pid also never replies, it queues behind the
      # still-running first command inside wasmex's own per-Store executor
      # and never completes.
      second_result =
        try do
          {:clean_return, Wasmex.call_function(pid, "hang", [], 1_000)}
        catch
          :exit, reason2 -> {:exit, reason2}
        end

      assert {:exit, _} = second_result,
             "expected the Store to remain permanently wedged after the first timeout " <>
               "(design §1.2), not become usable again for a subsequent call"
    end
  end

  # ---------------------------------------------------------------------
  # AC5 (design §4.2/§4.4/§5.6): classify/1 distinguishes a
  # wall-clock-timeout outcome from ResourceLimits.classify_call_result/1's
  # fuel-exhaustion/trap outcomes, both by type-shape and by disjoint
  # substring.
  # ---------------------------------------------------------------------

  describe "AC5: classify/1 is distinguishable from ResourceLimits.classify_call_result/1" do
    test "a real captured wall-clock-timeout PluginInterface outcome classifies as :wall_clock_timeout" do
      hang_context =
        context(%{
          node_config: %{
            "wasm_fixture" => "wasm_fixtures/req170_hang.wat",
            "export" => "hang",
            "timeout_ms" => 300
          }
        })

      assert {:error, _reason} = outcome = PluginInterface.invoke(PluginHandler, hang_context)
      assert CallTimeout.classify(outcome) == :wall_clock_timeout
    end

    test "the outer Task.yield/2 timeout shape also classifies as :wall_clock_timeout" do
      hang_context =
        context(%{
          node_config: %{"wasm_fixture" => "wasm_fixtures/req170_hang.wat", "export" => "hang"}
        })

      assert {:error, _reason} =
               outcome = PluginInterface.invoke(PluginHandler, hang_context, timeout_ms: 200)

      assert CallTimeout.classify(outcome) == :wall_clock_timeout
    end

    test "a successful outcome classifies as :not_timeout" do
      assert {:complete, _} = outcome = PluginInterface.invoke(PluginHandler, context())
      assert CallTimeout.classify(outcome) == :not_timeout
    end

    test "a real captured fuel-exhaustion ResourceLimits classification is a disjoint type and disjoint substring from :wall_clock_timeout" do
      {:ok, {_engine, store}} =
        ResourceLimits.build_store(%{fuel_budget: 1_000, memory_cap_bytes: 65_536})

      {:ok, pid} = Wasmex.start_link(%{store: store, bytes: fixture_bytes("req169_hang.wat")})
      :ok = ResourceLimits.arm_fuel(store, 1_000)

      task =
        Task.Supervisor.async_nolink(Letflow.Engine.PluginTaskSupervisor, fn ->
          Wasmex.call_function(pid, "hang", [])
        end)

      raw_result =
        case Task.yield(task, 5_000) do
          {:ok, result} -> result
          nil -> Task.shutdown(task, :brutal_kill) && flunk("expected fuel to exhaust, not hang")
        end

      fuel_classification = ResourceLimits.classify_call_result(raw_result)
      assert fuel_classification == :fuel_exhausted

      # (1) type-shape: an atom from a RAW Wasmex.call_function/4 return,
      # never equal to a CallTimeout.classification() value by construction.
      refute fuel_classification in [:wall_clock_timeout, :not_timeout]

      # (2) disjoint substrings, checked in both directions (design §4.4).
      {:error, fuel_reason} = raw_result
      assert String.contains?(fuel_reason, "all fuel consumed by WebAssembly")
      refute String.contains?(fuel_reason, "did not respond within")
      refute String.contains?(fuel_reason, "{:timeout, {GenServer, :call,")
    end

    test "classify/1's own two substrings never appear in a fuel-exhaustion reason string (pure, no live call needed)" do
      fuel_reason = "wasm guest call failed: {:error, \"all fuel consumed by WebAssembly\"}"
      refute String.contains?(fuel_reason, "did not respond within")
      refute String.contains?(fuel_reason, "{:timeout, {GenServer, :call,")
      assert CallTimeout.classify({:error, fuel_reason}) == :not_timeout
    end
  end

  # ---------------------------------------------------------------------
  # AC6 (design §6/§5.7): moduledoc states OQ-5 is not settled by this
  # requirement (naming what would settle it), and files the node-wide
  # worker-pool-exhaustion finding rather than silently absorbing it.
  # ---------------------------------------------------------------------

  describe "AC6: moduledoc content -- OQ-5 discipline" do
    test "moduledoc states OQ-5 is not settled here and names what would settle it" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(CallTimeout)

      assert moduledoc =~ "OQ-5"
      normalized = String.replace(moduledoc, ~r/\s+/, " ")
      assert normalized =~ "NOT settled by this requirement"
      assert normalized =~ "load spike"
      assert normalized =~ "S6"
    end

    test "moduledoc files the node-wide worker-pool-exhaustion finding, not silently absorbed" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(CallTimeout)

      assert moduledoc =~ "worker-pool-exhaustion" or moduledoc =~ "worker-thread pool"
      assert moduledoc =~ "node-global"
      assert moduledoc =~ "filed"
    end

    test "moduledoc states the decision 0014 divergence and that execution itself is not terminated" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(CallTimeout)

      assert moduledoc =~ "DIVERGENCE"
      assert moduledoc =~ "decision 0014"
      normalized = String.replace(moduledoc, ~r/\s+/, " ")
      assert normalized =~ "does **not** hold" or normalized =~ "does not hold"
    end
  end

  # ---------------------------------------------------------------------
  # classify/1 pure unit coverage.
  # ---------------------------------------------------------------------

  describe "classify/1 pure unit coverage" do
    test "classifies the {:exit, reason} GenServer.call-timeout shape as :wall_clock_timeout" do
      reason =
        "plugin handler Elixir.Foo crashed: " <>
          inspect(
            {:timeout, {GenServer, :call, [self(), {:call_function, "hang", [], 500}, 500]}}
          )

      assert CallTimeout.classify({:error, reason}) == :wall_clock_timeout
    end

    test "classifies the nil/outer-timeout shape as :wall_clock_timeout" do
      reason = "plugin handler Elixir.Foo did not respond within 100ms"
      assert CallTimeout.classify({:error, reason}) == :wall_clock_timeout
    end

    test "classifies an unrelated {:error, reason} as :not_timeout" do
      assert CallTimeout.classify({:error, "wasm guest call failed: some other reason"}) ==
               :not_timeout
    end

    test "classifies {:complete, _} as :not_timeout" do
      assert CallTimeout.classify({:complete, %{}}) == :not_timeout
    end
  end
end
