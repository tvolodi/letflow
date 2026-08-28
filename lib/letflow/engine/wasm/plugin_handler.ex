defmodule Letflow.Engine.Wasm.PluginHandler do
  @moduledoc """
  REQ-165 — the first WASM-backed `Letflow.Engine.PluginInterface` handler.
  Proves three things and nothing more: (1) `wasmex` actually builds its
  native code in this repo (see `.tool-versions`'s `rust` pin and
  `.github/workflows/ci.yml`'s `WASMEX_BUILD: true` step), (2) a guest call
  is dispatched through `PluginInterface.invoke/2,3`'s existing process
  boundary, never inline, and (3) a hanging guest surfaces as
  `{:error, reason}`, never an exception/exit. It does **not** implement the
  full plugin ABI (`init`/`execute`/`deinit`/`get_capabilities`, `alloc`) —
  that is REQ-166's scope, built on REQ-163's ABI decision.

  ## WASM-01 mechanism restatement

  WASM-01's literal text requires the platform to "embed Wasmtime via its C
  API, linked statically into the platform binary." That mechanism clause is
  not satisfiable here: `wasmex` embeds Wasmtime through a **Rust NIF**, not
  the C API, and there is no "platform binary" to link statically into — the
  BEAM loads `wasmex`'s native library as a runtime-loaded shared library.
  WASM-01's own **acceptance criterion** — "No external Wasm runtime
  dependency at deploy time" — is met exactly as literally worded: Wasmtime
  is compiled into the NIF's shared library at build time and loaded
  in-process by the BEAM; no separate Wasmtime binary, daemon, or system
  package is installed, configured, or reached over any IPC/network boundary
  at deploy time. Only the mechanism clause is restated; the acceptance
  criterion is satisfied, not reinterpreted.

  Verified directly against a compiled build (resolving design doc OQ-D1,
  `lib/letflow/design/req165-wasmex-process-boundary.md` §9): the compiled
  `Wasmex.Native` module (`:code.which/1`) resolves to a `.beam` file whose
  own `module_info(:attributes)` lists `external_resource` entries pointing
  at `native/wasmex/src/*.rs` — the Rust NIF source the shared library was
  built from — and the shared library itself
  (`:code.priv_dir(:wasmex)`-relative `native/wasmex.so`) is bundled inside
  the OTP application's own `priv/` directory, not fetched or reached at
  runtime. A guest call opens zero new OS ports (`:erlang.ports/0` before and
  after a call is unchanged) — the call crosses no IPC boundary, confirming
  it is an ordinary in-process NIF call, not a call to an external
  Wasmtime process.

  ## Residual risk — NOT covered by the process boundary

  Per decision 0014 Reasoning (a): a Wasmtime- or NIF-layer crash inside a
  call this module makes does not raise, exit, or trap in the ordinary BEAM
  sense observable by `PluginInterface.invoke/2,3`'s `Task.yield/2` — it can
  crash the **entire BEAM node**, the same disclosed-and-uncovered class
  `Letflow.Engine.PluginInterface`'s own moduledoc already names for "a hard
  kill of the BEAM node itself, or `System.halt/0`": no monitor, task, or
  supervisor observes it from inside the same node, because supervision is a
  process-level mechanism and a NIF segfault is a process-level event only in
  the sense that the OS process *is* the node. The process boundary this
  module relies on (`Task.Supervisor.async_nolink/2` + `Task.yield/2` +
  `Task.shutdown(task, :brutal_kill)`) bounds **hangs and guest traps** —
  both observable as an ordinary task outcome (`nil` from `Task.yield/2`, or
  `{:exit, reason}` for a trap) — it does **not** bound a native crash. This
  is an accepted, stated limitation, not a gap this module papers over.

  See `lib/letflow/design/req165-wasmex-process-boundary.md` (gate-approved)
  for the full design this module implements.

  ## REQ-174 (WASM-13, SHOULD) — instance pooling: DECLINED

  See `Letflow.Engine.Wasm.ModuleVersionRegistry`'s moduledoc for the full
  decision record (pooling declined; no first-party `wasmex` pooling API
  exists; decision `0014-scripting-plugin-runtime-strategy.md` point (e)'s
  restatement of WASM-13; invariants INV-174-1/INV-174-2) and
  `lib/letflow/design/req174-wasm-instance-pooling-or-decline.md`
  (gate-approved) for the live verification it rests on. `run_guest/3` above
  is the second of REQ-174's two scoped call paths: `start_instance/1` calls
  `Wasmex.start_link/1` with no `:store` option (line ~155), so every
  invocation gets a brand-new `Store`/linear memory never touched by any
  other invocation, and `run_guest/3` stops the instance unconditionally on
  every path (comment above, lines 124-131) — INV-174-1's isolation-by-
  construction property holds for this call site exactly as it does for
  `ModuleVersionRegistry.invoke/4`.
  """

  @behaviour Letflow.Engine.PluginInterface

  alias Letflow.Engine.PluginInterface.ExecutionContext

  @default_fixture "wasm_fixtures/req165_trivial.wat"
  @default_export "answer"

  # REQ-170 -- matches wasmex's own documented Wasmex.call_function/4
  # default exactly (deps/wasmex/lib/wasmex.ex), so a caller that never
  # sets "timeout_ms" in node_config sees no behavior change from before
  # this requirement. See lib/letflow/design/req170-wasm-wallclock-timeout.md
  # §4.3/§9 OQ-1.
  @default_wasmex_timeout_ms 5_000

  @doc """
  The sole `@callback` `Letflow.Engine.PluginInterface` requires. Never call
  this directly — always go through
  `Letflow.Engine.PluginInterface.invoke/2,3`, exactly as that module's own
  moduledoc mandates for every handler.

  `context.node_config` may name `"wasm_fixture"` (a path relative to
  `priv/`) and `"export"` (the guest export to call) to point this handler
  at a different fixture than REQ-165's own trivial guest — this is how the
  AC5 hang test below points the same handler at
  `priv/wasm_fixtures/req165_hang.wat`'s `"hang"` export without a second
  handler module. Both default to the trivial guest fixture/export when
  absent, which is what the AC3/AC4 tests exercise.

  REQ-170 — `node_config` may also name `"timeout_ms"`, the wasmex-level
  per-invocation wall-clock bound (see
  `Letflow.Engine.Wasm.CallTimeout.config()`), threaded into
  `Wasmex.call_function/4`'s own explicit 4th argument. Defaults to
  `@default_wasmex_timeout_ms` (5,000ms, matching `wasmex`'s own documented
  default) when absent, so a caller that never sets this key sees no
  behavior change from before this requirement.
  """
  @impl Letflow.Engine.PluginInterface
  @spec handle_node(ExecutionContext.t()) :: Letflow.Engine.PluginInterface.outcome()
  def handle_node(%ExecutionContext{node_config: node_config}) do
    fixture = Map.get(node_config, "wasm_fixture", @default_fixture)
    export = Map.get(node_config, "export", @default_export)
    timeout_ms = Map.get(node_config, "timeout_ms", @default_wasmex_timeout_ms)

    case run_guest(fixture, export, timeout_ms) do
      {:ok, answer} ->
        {:complete, %{"answer" => answer, "executed_in_pid" => self()}}

      {:error, reason} ->
        {:error, reason}

      # REQ-172 -- call_export/3 now distinguishes a guest's own platform.fail call
      # (design §2.2) from an ordinary guest trap/failure. This handler's own
      # @callback contract (Letflow.Engine.PluginInterface.outcome/0) has exactly two
      # shapes, {:complete, _} | {:error, _} -- a future dispatch-integration
      # requirement may surface {:failed, _, _} more richly; until then it maps onto
      # the existing {:error, _} outcome, never silently dropped or crashing this
      # case.
      {:failed, fail_reason, details} ->
        {:error, "wasm guest called platform.fail: #{fail_reason} (details: #{inspect(details)})"}
    end
  end

  # Runs the named guest export to completion, per the design's §3.2
  # algorithm:
  #   1. read the fixture bytes
  #   2. Wasmex.start_link/1 -- a fresh Wasmtime instance for this call only
  #   3. Wasmex.call_function/4 -- the guest's named export
  #   4. GenServer.stop/1 -- on every path, including the error path, so a
  #      wasmex instance is never leaked
  #   5. map the raw i32 result (or any wasmex failure) to {:ok, _} | {:error, _}
  @spec run_guest(String.t(), String.t(), pos_integer()) ::
          {:ok, integer()} | {:error, String.t()} | {:failed, String.t(), term()}
  defp run_guest(fixture, export, timeout_ms) do
    with {:ok, bytes} <- read_fixture(fixture),
         {:ok, pid} <- start_instance(bytes) do
      result = call_export(pid, export, timeout_ms)
      GenServer.stop(pid)
      result
    end
  end

  @spec read_fixture(String.t()) :: {:ok, binary()} | {:error, String.t()}
  defp read_fixture(relative_path) do
    path = Path.join(Application.app_dir(:letflow, "priv"), relative_path)

    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, "could not read wasm fixture #{path}: #{inspect(reason)}"}
    end
  end

  @spec start_instance(binary()) :: {:ok, pid()} | {:error, String.t()}
  defp start_instance(bytes) do
    case Wasmex.start_link(%{bytes: bytes}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, "failed to instantiate wasm guest: #{inspect(reason)}"}
    end
  end

  # REQ-170 -- wasmex's own call-level timeout is now an explicit, caller-
  # configurable argument (see handle_node/1's "timeout_ms" node_config key
  # and Letflow.Engine.Wasm.CallTimeout), passed as
  # Wasmex.call_function/4's explicit 4th argument in place of the implicit
  # 3-arity call that used to silently accept wasmex's own 5,000ms default.
  # See the design doc §4.3.
  #
  # REQ-172 design §2.2 -- on a Wasmex.call_function/4 {:error, _} return, this
  # function now checks Process.info(pid, :dictionary) for
  # Letflow.Engine.Wasm.HostApi's fail-signal key BEFORE returning to run_guest/3 --
  # run_guest/3's own GenServer.stop(pid) call (unchanged, still runs unconditionally
  # on every path) would otherwise destroy the pdict signal before anything could ever
  # observe it (live-verified: Process.info/2 on an already-stopped pid returns nil).
  # Present -> a distinctly-tagged {:failed, reason, details} outcome, taken from the
  # stash, never from the discarded/generic error message. Absent -> the existing
  # generic {:error, _} behavior is unchanged (covers a guest trap, ResourceLimits fuel
  # exhaustion, and an undetected accidental callback bug alike).
  @spec call_export(pid(), String.t(), pos_integer()) ::
          {:ok, integer()} | {:error, String.t()} | {:failed, String.t(), term()}
  defp call_export(pid, export, timeout_ms) do
    case Wasmex.call_function(pid, export, [], timeout_ms) do
      {:ok, [answer]} ->
        {:ok, answer}

      {:ok, other} ->
        {:error, "wasm guest returned an unexpected shape: #{inspect(other)}"}

      {:error, reason} ->
        case fail_signal(pid) do
          {:ok, %{reason: fail_reason, details: details}} -> {:failed, fail_reason, details}
          :none -> {:error, "wasm guest call failed: #{inspect(reason)}"}
        end
    end
  end

  # REQ-172 design §2.2 -- reads the fail-signal key (private to
  # Letflow.Engine.Wasm.HostApi) out of the still-alive Wasmex instance process's own
  # dictionary. Must be called strictly before that pid is stopped or otherwise torn
  # down (run_guest/3's own GenServer.stop(pid) call, immediately after this function
  # returns, satisfies that ordering).
  @spec fail_signal(pid()) :: {:ok, %{reason: String.t(), details: term()}} | :none
  defp fail_signal(pid) do
    fail_signal_key = {Letflow.Engine.Wasm.HostApi, :fail_signal}

    case Process.info(pid, :dictionary) do
      {:dictionary, entries} ->
        case List.keyfind(entries, fail_signal_key, 0) do
          {^fail_signal_key, signal} -> {:ok, signal}
          nil -> :none
        end

      nil ->
        :none
    end
  end
end
