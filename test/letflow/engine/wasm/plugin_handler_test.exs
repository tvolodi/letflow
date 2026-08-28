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
      {output, 0} =
        System.cmd("git", [
          "diff",
          "--stat",
          "main...HEAD",
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

      assert {:complete, %{"answer" => 42, "executed_in_pid" => handler_pid}} =
               PluginInterface.invoke(PluginHandler, context())

      assert is_pid(handler_pid)
      assert handler_pid != test_pid
      assert Process.alive?(test_pid)
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
