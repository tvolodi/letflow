defmodule Letflow.Engine.Wasm.ModuleRegistry do
  @moduledoc """
  REQ-166 (WASM-02, MUST) — registration-time rejection of a WASM module that
  does not satisfy the platform's plugin ABI.

  The plugin ABI's five required function exports — `init`, `execute`,
  `deinit`, `get_capabilities`, `alloc` — and the required `memory` export
  are `lib/letflow/design/req163-wasm-abi-choice.md`'s contract, cited by
  section number (§3.1 for the four named function exports and their exact
  core-module signatures, §3.2 for the implicit `alloc` export and the
  required `memory` export). That contract is **not re-derived here** and
  this module has no authority to change it — see
  `lib/letflow/design/req166-wasm-module-abi-validation.md` §0/§5.2 for the
  restated table this module's `@required_exports` implements verbatim.

  Per req163's Decision, this module validates **core modules**, not the
  component model — it never calls anything under `Wasmex.Components`.

  ## Two-stage validation gate

  `register/1` is the single entry point through which a module's bytes are
  turned into anything invocable at all. Registration is a two-stage
  sequential gate (design §5.1), stage 2 reached only when stage 1 finds
  zero defects:

    1. **Static export/signature check** — `Wasmex.Module.compile/2` (parses
       and validates the module's bytes without instantiating it: no
       imports are resolved, no memory is allocated, no code runs) followed
       by `Wasmex.Module.exports/1`, a pure static function of the compiled
       bytes. Every required export is checked against `@required_exports`;
       ALL defects are collected in one pass, not just the first. Any
       defect returns `{:error, {:invalid_abi, defects}}` and stage 2 never
       runs.
    2. **Real instantiation attempt**, only once stage 1 is clean —
       `Wasmex.start_link/1`, run inside a monitored
       `Task.Supervisor.async_nolink/2` task under the dedicated
       `Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor` (never called
       inline in `register/1`'s own process — design §1.5 live-reproduced
       that an unresolved-import crash inside `Wasmex.start_link/1`
       delivers a linked `:EXIT` signal to a non-trapping inline caller,
       not a clean `{:error, reason}` term `try`/`rescue` can intercept).
       The outcome is read back via `Task.yield/2`, bounded by a fixed
       timeout so a hung instantiation attempt cannot hang `register/1`
       forever. On success, the proving `Wasmex` instance is stopped
       (`GenServer.stop/1`) before `register/1` returns — it is never kept
       running past registration (design §3.1).

  Per req163-wasm-abi-choice.md §4, an instantiation failure — including an
  unresolved import — is rejected identically to a missing/malformed
  export: at **registration**, not first invocation. Rejection is
  structural, not by-convention: the only function that can build a
  `registered_module()` value is `register/1`'s own success branch, which
  is reached only after *both* stages pass (design §4).

  ## Scope boundary

  This module is fully decoupled from invocation. It does not modify
  `Letflow.Engine.Wasm.PluginHandler` or `Letflow.Engine.PluginInterface` —
  wiring registration in front of an actual invocation call path is a
  future dispatch-integration requirement's job (design §2.1).

  See `lib/letflow/design/req166-wasm-module-abi-validation.md`
  (gate-approved) for the full design this module implements.
  """

  defmodule RegisteredModule do
    @moduledoc false
    @enforce_keys [:module, :bytes]
    defstruct [:module, :bytes]
  end

  @typedoc "One required export's expected shape, per req163 §3.1/§3.2."
  @type export_name :: String.t()

  @type valtype :: :i32 | :i64 | :v128 | :f32 | :f64

  @type required_export ::
          {:fn, name :: export_name(), params :: [valtype()], results :: [valtype()]}
          | {:memory, name :: export_name()}

  @typedoc """
  One concrete way a required export failed to conform, naming the export by
  name.
  """
  @type export_defect ::
          {:missing, export_name()}
          | {:wrong_kind, export_name(), expected :: :fn | :memory, actual :: atom()}
          | {:wrong_signature, export_name(),
             expected: {[valtype()], [valtype()]}, actual: {[valtype()], [valtype()]}}

  @typedoc """
  One concrete way the real instantiation attempt (stage 2) failed. Per
  req163-wasm-abi-choice.md §4, an unresolved-import failure is named by its
  namespace/function wherever the crash reason is shaped to allow it.
  """
  @type instantiation_defect ::
          {:unresolved_import, namespace :: String.t(), function :: export_name()}
          | {:crashed, raw_reason :: term()}
          | {:timeout, timeout_ms :: non_neg_integer()}

  @typedoc """
  The structured rejection reason. `defects` is always non-empty for
  `:invalid_abi` and lists EVERY defect found in one pass, not just the
  first. `:instantiation_failed` is reached only when the static check
  (`:invalid_abi`) already passed.
  """
  @type registration_error ::
          {:invalid_abi, defects :: [export_defect()]}
          | {:compile_error, reason :: binary()}
          | {:instantiation_failed, instantiation_defect()}

  @typedoc "Opaque handle to a module that has passed registration."
  @opaque registered_module :: %RegisteredModule{module: Wasmex.Module.t(), bytes: binary()}

  # design §5.2's restated table (verbatim from req163 §3.1/§3.2) -- order is
  # not significant, every entry is checked and every defect collected.
  @required_exports [
    {:fn, "init", [:i32, :i32], [:i32]},
    {:fn, "execute", [:i32, :i32], [:i32]},
    {:fn, "deinit", [], []},
    {:fn, "get_capabilities", [], [:i32]},
    {:fn, "alloc", [:i32], [:i32]},
    {:memory, "memory"}
  ]

  # design §5.1 step 6 -- "an ELIXIR-DEV implementation constant, not a value
  # this design fixes." Bounds stage 2's real instantiation attempt so a hung
  # Wasmex.start_link/1 cannot hang register/1 forever.
  @instantiation_timeout_ms 5_000

  # design §2.2 -- the new, dedicated Task.Supervisor this design adds to
  # lib/letflow/application.ex's supervision tree.
  @task_supervisor Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor

  # Matches the exact wording wasmex v0.15.1 produces for an unresolved
  # import (design §1.5's live reproduction): "unknown import:
  # `<namespace>::<function>` has not been defined". A future wasmex version
  # bump that changes this wording falls through to the {:crashed, _}
  # catch-all instead (design §7 -- a precision gap, not a soundness one).
  @unresolved_import_pattern ~r/unknown import: `(?<namespace>[^:`]+)::(?<function>[^`]+)` has not been defined/

  @doc """
  The single entry point registration goes through. Two sequential stages
  (design §5.1): (1) static export/signature check
  (`Wasmex.Module.compile/2` + `Wasmex.Module.exports/1`) — on any defect,
  returns `{:error, {:invalid_abi, defects}}` and stage 2 never runs; (2)
  only once stage 1 finds zero defects, a real instantiation attempt
  (`Wasmex.start_link/1`, run inside a monitored
  `Task.Supervisor.async_nolink/2` task under
  `Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor` — never called inline)
  — on any instantiation failure (including an unresolved import, per
  req163-wasm-abi-choice.md §4), returns
  `{:error, {:instantiation_failed, defect}}`. The `Wasmex` instance stage 2
  starts on success is immediately stopped (`GenServer.stop/1`) before
  `register/1` returns — it is not kept running. Returns
  `{:ok, registered_module()}` only when both stages pass; otherwise
  `{:error, registration_error()}` naming the specific defect found.
  """
  @spec register(bytes :: binary()) :: {:ok, registered_module()} | {:error, registration_error()}
  def register(bytes) when is_binary(bytes) do
    with {:ok, store} <- Wasmex.Store.new(),
         {:ok, module} <- compile(store, bytes),
         :ok <- check_exports(module) do
      instantiate(module, bytes)
    end
  end

  # design §5.1 step 2.
  @spec compile(Wasmex.StoreOrCaller.t(), binary()) ::
          {:ok, Wasmex.Module.t()} | {:error, {:compile_error, binary()}}
  defp compile(store, bytes) do
    case Wasmex.Module.compile(store, bytes) do
      {:ok, module} -> {:ok, module}
      {:error, reason} -> {:error, {:compile_error, reason}}
    end
  end

  # design §5.1 steps 3-5 -- collects ALL defects, not stop-on-first.
  @spec check_exports(Wasmex.Module.t()) :: :ok | {:error, {:invalid_abi, [export_defect()]}}
  defp check_exports(module) do
    exports = Wasmex.Module.exports(module)

    defects =
      @required_exports
      |> Enum.map(&defect_for(&1, exports))
      |> Enum.reject(&is_nil/1)

    case defects do
      [] -> :ok
      _ -> {:error, {:invalid_abi, defects}}
    end
  end

  @spec defect_for(required_export(), %{export_name() => term()}) :: export_defect() | nil
  defp defect_for({:fn, name, params, results}, exports) do
    case Map.fetch(exports, name) do
      :error ->
        {:missing, name}

      {:ok, {:fn, ^params, ^results}} ->
        nil

      {:ok, {:fn, actual_params, actual_results}} ->
        {:wrong_signature, name,
         expected: {params, results}, actual: {actual_params, actual_results}}

      {:ok, other} ->
        {:wrong_kind, name, :fn, elem(other, 0)}
    end
  end

  defp defect_for({:memory, name}, exports) do
    case Map.fetch(exports, name) do
      :error -> {:missing, name}
      {:ok, {:memory, _}} -> nil
      {:ok, other} -> {:wrong_kind, name, :memory, elem(other, 0)}
    end
  end

  # design §5.1 steps 6-8, §1.5, §2.2 -- the real instantiation attempt,
  # always run inside a dedicated Task.Supervisor task, never inline.
  @spec instantiate(Wasmex.Module.t(), binary()) ::
          {:ok, registered_module()} | {:error, {:instantiation_failed, instantiation_defect()}}
  defp instantiate(module, bytes) do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        case Wasmex.start_link(%{bytes: bytes}) do
          {:ok, pid} ->
            GenServer.stop(pid)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case Task.yield(task, @instantiation_timeout_ms) do
      {:ok, :ok} ->
        {:ok, %RegisteredModule{module: module, bytes: bytes}}

      {:ok, {:error, reason}} ->
        {:error, {:instantiation_failed, {:crashed, reason}}}

      {:exit, reason} ->
        {:error, {:instantiation_failed, classify_crash(reason)}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:instantiation_failed, {:timeout, @instantiation_timeout_ms}}}
    end
  end

  # design §5.1 step 7 -- match the live-reproduced crash shape
  # ({{:badmatch, {:error, message}}, stacktrace}) and, if `message` names an
  # unresolved import, extract namespace/function verbatim; any other shape
  # falls through to the {:crashed, raw_reason} catch-all without losing the
  # raw reason.
  @spec classify_crash(term()) :: instantiation_defect()
  defp classify_crash({{:badmatch, {:error, message}}, _stacktrace} = reason)
       when is_binary(message) do
    case Regex.named_captures(@unresolved_import_pattern, message) do
      %{"namespace" => namespace, "function" => function} ->
        {:unresolved_import, namespace, function}

      nil ->
        {:crashed, reason}
    end
  end

  defp classify_crash(reason), do: {:crashed, reason}
end
