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
      {:ok, answer} -> {:complete, %{"answer" => answer, "executed_in_pid" => self()}}
      {:error, reason} -> {:error, reason}
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
          {:ok, integer()} | {:error, String.t()}
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
  @spec call_export(pid(), String.t(), pos_integer()) ::
          {:ok, integer()} | {:error, String.t()}
  defp call_export(pid, export, timeout_ms) do
    case Wasmex.call_function(pid, export, [], timeout_ms) do
      {:ok, [answer]} -> {:ok, answer}
      {:ok, other} -> {:error, "wasm guest returned an unexpected shape: #{inspect(other)}"}
      {:error, reason} -> {:error, "wasm guest call failed: #{inspect(reason)}"}
    end
  end
end
