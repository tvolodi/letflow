defmodule Letflow.Engine.Wasm.ModuleRegistryTest do
  @moduledoc """
  REQ-166 -- coverage for `Letflow.Engine.Wasm.ModuleRegistry`. See
  `lib/letflow/design/req166-wasm-module-abi-validation.md` (gate-approved)
  for the full two-stage algorithm this suite exercises.

  `async: false`: several tests here build a real Wasmtime instance via
  `wasmex`'s NIF (stage 2's instantiation attempt), including the
  unresolved-import case that deliberately reproduces the crash-propagation
  hazard design §1.5 documents. Keeping the file serial avoids any risk of
  overlapping native-NIF activity across `async: true` test processes,
  mirroring `plugin_handler_test.exs`'s own rationale.
  """

  use ExUnit.Case, async: false

  alias Letflow.Engine.Wasm.ModuleRegistry

  defp fixture(name) do
    Application.app_dir(:letflow, "priv")
    |> Path.join("wasm_fixtures/#{name}")
    |> File.read!()
  end

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

  # ---------------------------------------------------------------------
  # AC1: missing `execute` -> {:error, {:invalid_abi, defects}} naming
  # {:missing, "execute"}.
  # ---------------------------------------------------------------------

  describe "AC1: a module missing the execute export is rejected" do
    test "returns {:error, {:invalid_abi, defects}} naming {:missing, \"execute\"}" do
      bytes = fixture("req166_missing_execute.wat")

      assert {:error, {:invalid_abi, defects}} = ModuleRegistry.register(bytes)
      assert {:missing, "execute"} in defects
    end
  end

  # ---------------------------------------------------------------------
  # AC2: each of the other 5 required exports rejected individually, plus a
  # multiple-simultaneous-missing-exports case.
  # ---------------------------------------------------------------------

  describe "AC2: each other required export is rejected individually" do
    test "missing init" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_init.wat"))

      assert {:missing, "init"} in defects
    end

    test "missing deinit" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_deinit.wat"))

      assert {:missing, "deinit"} in defects
    end

    test "missing get_capabilities" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_get_capabilities.wat"))

      assert {:missing, "get_capabilities"} in defects
    end

    test "missing alloc" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_alloc.wat"))

      assert {:missing, "alloc"} in defects
    end

    test "missing memory" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_memory.wat"))

      assert {:missing, "memory"} in defects
    end

    test "multiple simultaneously-missing exports (init AND get_capabilities) all appear" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_multiple.wat"))

      assert {:missing, "init"} in defects
      assert {:missing, "get_capabilities"} in defects
      assert length(defects) == 2
    end

    test "a wrong-signature execute export is rejected as :wrong_signature, not :missing" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_wrong_signature_execute.wat"))

      assert [
               {:wrong_signature, "execute",
                expected: {[:i32, :i32], [:i32]}, actual: {[:i32], [:i32]}}
             ] =
               defects
    end
  end

  # ---------------------------------------------------------------------
  # AC3: rejection happens at registration, never at invocation; the opaque
  # type means no test can construct a registered_module() for a
  # non-conforming module. Also covers the NEW stage-2 rejection case: an
  # unresolved WASI import in an otherwise export-conforming module.
  # ---------------------------------------------------------------------

  describe "AC3: rejection is structural (registration-time), including stage-2 instantiation failures" do
    test "a non-conforming module never produces a registered_module() value" do
      assert {:error, _} = ModuleRegistry.register(fixture("req166_missing_execute.wat"))
      # No public constructor exists other than register/1's own success
      # branch (@opaque, enforced at compile time by
      # `mix compile --warnings-as-errors`) -- there is no expression this
      # test (or any code outside ModuleRegistry) could write to forge a
      # registered_module() from these bytes instead.
    end

    test "an export-conforming module with an unresolved WASI import is rejected at stage 2" do
      bytes = fixture("req166_unresolved_import.wat")

      assert {:error, {:instantiation_failed, {:unresolved_import, namespace, function}}} =
               ModuleRegistry.register(bytes)

      assert namespace == "wasi_snapshot_preview1"
      assert function == "path_open"
    end
  end

  # ---------------------------------------------------------------------
  # AC4: a conforming module registers successfully, and the proving Wasmex
  # instance is stopped (not leaked) before register/1 returns.
  # ---------------------------------------------------------------------

  describe "AC4: a conforming module registers successfully with no leaked instance" do
    test "returns {:ok, registered_module()}" do
      assert {:ok, _registered} = ModuleRegistry.register(fixture("req166_conforming.wat"))
    end

    test "the proving Wasmex instance started during stage 2 is stopped before register/1 returns" do
      before_pids = wasmex_pids()

      assert {:ok, _registered} = ModuleRegistry.register(fixture("req166_conforming.wat"))

      leaked = wasmex_pids() -- before_pids

      assert leaked == [],
             "expected no leaked Wasmex GenServer after a successful registration, got: #{inspect(leaked)}"
    end
  end

  # ---------------------------------------------------------------------
  # Additional (not a numbered AC, but the single most important test given
  # the whole design's rework): register/1 on an unresolved-import module
  # must NOT crash the calling test process. This directly proves the
  # Task.Supervisor.async_nolink/2 wrapping (design §1.5/§2.2) actually
  # works -- an inline Wasmex.start_link/1 call on this same fixture would
  # deliver a linked :EXIT signal and kill this very test process.
  # ---------------------------------------------------------------------

  describe "the crash-propagation hazard design §1.5 identified is contained" do
    test "register/1 on an unresolved-import module does not crash the calling process" do
      test_pid = self()
      bytes = fixture("req166_unresolved_import.wat")

      assert {:error, {:instantiation_failed, {:unresolved_import, _, _}}} =
               ModuleRegistry.register(bytes)

      assert Process.alive?(test_pid)
      # If register/1 called Wasmex.start_link/1 inline instead of inside a
      # Task.Supervisor.async_nolink/2 task, this whole test process (linked
      # to the crashing instance during init/1) would have exited before
      # reaching this line at all -- there would be no assertion failure to
      # report, the test run itself would abort.
    end
  end

  # ---------------------------------------------------------------------
  # AC5 (moduledoc): names the export contract and cites req163.
  # ---------------------------------------------------------------------

  describe "moduledoc content" do
    test "AC5: names the export contract and cites req163-wasm-abi-choice.md's sections" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(ModuleRegistry)

      assert moduledoc =~ "req163-wasm-abi-choice.md"
      assert moduledoc =~ "§3.1"
      assert moduledoc =~ "§3.2"
      assert moduledoc =~ "§4"
      assert moduledoc =~ "init"
      assert moduledoc =~ "execute"
      assert moduledoc =~ "deinit"
      assert moduledoc =~ "get_capabilities"
      assert moduledoc =~ "alloc"
      assert moduledoc =~ "memory"
      assert moduledoc =~ "two-stage"
      assert moduledoc =~ "Components"
    end
  end

  # ---------------------------------------------------------------------
  # AC6 sanity: a plain syntactically-invalid module is rejected at stage 1's
  # compile step, before any export check.
  # ---------------------------------------------------------------------

  describe "a syntactically-invalid module is rejected at compile" do
    test "returns {:error, {:compile_error, reason}}" do
      assert {:error, {:compile_error, reason}} = ModuleRegistry.register("not valid wasm")
      assert is_binary(reason)
    end
  end
end
