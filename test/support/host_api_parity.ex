defmodule Letflow.Test.HostApiParity do
  @moduledoc """
  REQ-172 (WASM-12's own acceptance criterion) -- the ONE scenario registry executed
  against BOTH `Letflow.Engine.Lua.Platform` (via `Lua.eval!/2`) and
  `Letflow.Engine.Wasm.HostApi` (via a running Wasmex instance), asserting identical
  CANONICAL outcomes. See
  `lib/letflow/design/req172-wasm-host-api-write-path-and-parity-suite.md` §8
  (gate-approved) for the full design this module implements.

  A future host function a later requirement wires into BOTH `@known_imports`
  (`capability_gate.ex`) and `platform.ex`'s `@capability_matrix` is structurally
  forced to add a `scenario()` entry here -- see `Letflow.Engine.Wasm.CapabilityGate.known_host_functions/0`
  and the exhaustiveness guard TEST-DESIGNER's own test file builds against it (design
  §8.4) -- rather than being able to ship parity-untested.

  This module is test-only support (`test/support/`, not `lib/`), mirroring this
  project's existing convention for shared test infrastructure (e.g.
  `test/support/data_case.ex`, `test/support/tenant_fixture.ex`).
  """

  alias Letflow.Engine.Lua.Capabilities
  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.Lua.Sandbox
  alias Letflow.Engine.Wasm.CapabilityGate
  alias Letflow.Engine.Wasm.HostApi

  @typedoc """
  The one normalized shape both runtimes' raw results are folded into before
  comparison -- this is what makes "identical observable outcomes" assertable at all
  across two structurally different ABIs (Lua multi-return vs. WASM buffer-out/status
  code).
  """
  @type outcome ::
          {:ok, term()}
          | {:error, reason :: String.t()}
          | {:denied, capability :: String.t()}
          | {:failed, reason :: String.t(), details :: term()}

  @typedoc """
  One entry in the fixed scenario registry. `parity` distinguishes a genuinely
  dual-runtime scenario from a documented WASM-only addition (`uuid`, no Lua
  counterpart -- REQ-171 §3) which this harness still registers, so the
  exhaustiveness guard covers it, but never drives through `run_lua`.
  """
  @type scenario :: %{
          required(:host_function) => atom(),
          required(:parity) => :full | :wasm_only,
          required(:run_lua) => (-> outcome()) | nil,
          required(:run_wasm) => (-> outcome())
        }

  # ── Fixed probe inputs, shared by both runtimes' closures for a given scenario ────

  @read_variable_name "parity_probe"
  @read_variable_value "parity-value"
  @write_variable_name "parity_write_probe"
  @write_variable_value "staged-parity-value"
  @call_service_id "parity-service"
  @fail_reason "parity fail reason"
  @fail_details %{"x" => 1}

  @out_ptr 8192
  @out_cap 4096

  defmodule FixedTimeSource do
    @moduledoc false
    @behaviour Platform.TimeSource

    @impl Platform.TimeSource
    def now, do: ~U[2026-08-28 00:00:00.000000Z]
  end

  defmodule FakeServiceCaller do
    @moduledoc false
    @behaviour Platform.ServiceCaller

    @impl Platform.ServiceCaller
    def call(_service_id, _payload), do: {:ok, %{"amount" => 42, "currency" => "usd"}}
  end

  @doc """
  The fixed, exhaustive registry -- one entry per host function EITHER runtime
  currently implements for real (i.e. every `capability_gate.ex` `@known_imports` row
  whose stub is not a placeholder, plus every `platform.ex` `@capability_matrix` row
  with a real, non-`:not_yet_implemented` stub). As of REQ-172: `read_variable`,
  `log`, `now`, `uuid` (`:wasm_only`), `write_variable`, `call_service`, `fail` --
  seven entries. `get_instance_state` and `emit_event` are Lua-only (no WASM host
  function implements them as of this requirement) and are DELIBERATELY ABSENT.
  """
  @spec scenarios() :: %{atom() => scenario()}
  def scenarios do
    %{
      read_variable: read_variable_scenario(),
      log: log_scenario(),
      now: now_scenario(),
      uuid: uuid_scenario(),
      write_variable: write_variable_scenario(),
      call_service: call_service_scenario(),
      fail: fail_scenario()
    }
  end

  @doc """
  Runs one scenario's `run_wasm/0` (and, when `parity: :full`, its `run_lua/0`),
  asserting the two canonical outcomes are equal via `ExUnit.Assertions.assert/1`
  (raises `ExUnit.AssertionError` on mismatch, exactly like any other test assertion
  -- this function is meant to be called FROM inside a test, not as a bare boolean
  predicate). For `:wasm_only`, only `run_wasm/0` is invoked and no comparison is
  made -- the scenario still exists so the exhaustiveness guard accounts for it.
  """
  @spec assert_parity(scenario()) :: :ok
  def assert_parity(%{parity: :wasm_only} = scenario) do
    _wasm_outcome = scenario.run_wasm.()
    :ok
  end

  def assert_parity(%{parity: :full} = scenario) do
    lua_outcome = scenario.run_lua.()
    wasm_outcome = scenario.run_wasm.()

    ExUnit.Assertions.assert(
      lua_outcome == wasm_outcome,
      "parity mismatch for #{inspect(scenario.host_function)}: " <>
        "lua=#{inspect(lua_outcome)} wasm=#{inspect(wasm_outcome)}"
    )

    :ok
  end

  # ── read_variable ──────────────────────────────────────────────────────────────

  defp read_variable_scenario do
    variables = %{@read_variable_name => @read_variable_value}

    run_lua = fn ->
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          lua_execution_context(variables)
        )

      case Lua.eval!(lua, "return platform.read_variable('#{@read_variable_name}')") do
        {[value], _lua} -> {:ok, value}
      end
    end

    run_wasm = fn ->
      {pid, store, memory} =
        start_read_path_instance(wasm_execution_context(variables))

      write_bytes(store, memory, 0, @read_variable_name)

      outcome =
        case call_function(pid, "call_read_variable", [
               0,
               byte_size(@read_variable_name),
               @out_ptr,
               @out_cap
             ]) do
          {:ok, [n]} when n >= 0 ->
            {:ok, Jason.decode!(read_bytes(store, memory, @out_ptr, n))}

          {:ok, [n]} ->
            {:error, "read_variable failed: #{n}"}
        end

      GenServer.stop(pid)
      outcome
    end

    %{host_function: :read_variable, parity: :full, run_lua: run_lua, run_wasm: run_wasm}
  end

  # ── log ────────────────────────────────────────────────────────────────────────
  #
  # log has no return-value channel on either runtime -- the canonical outcome
  # compared here is only "did the call complete without error/denial", not the
  # emitted log entry's own content (Logger side-effects are out of this harness's
  # normalized outcome() shape entirely).

  defp log_scenario do
    run_lua = fn ->
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["audit:log"]),
          lua_execution_context()
        )

      case Lua.eval!(lua, "return platform.log('info', 'parity log message')") do
        {[], _lua} -> {:ok, nil}
      end
    end

    run_wasm = fn ->
      {pid, store, memory} =
        start_read_path_instance(wasm_execution_context())

      message = "parity log message"
      write_bytes(store, memory, 0, "info")
      write_bytes(store, memory, 100, message)

      outcome =
        case call_function(pid, "call_log", [0, 4, 100, byte_size(message), 0, 0]) do
          {:ok, []} -> {:ok, nil}
        end

      GenServer.stop(pid)
      outcome
    end

    %{host_function: :log, parity: :full, run_lua: run_lua, run_wasm: run_wasm}
  end

  # ── now ────────────────────────────────────────────────────────────────────────
  #
  # WASM's do_now/3 calls Platform.now/0 directly (REQ-171 §5.5) -- under the same
  # injected TimeSource double, both runtimes are byte-for-byte identical, the
  # strongest possible form of parity.

  defp now_scenario do
    run_lua = fn ->
      with_time_source(FixedTimeSource, fn ->
        lua = Platform.install(Sandbox.new(), Capabilities.new([]), lua_execution_context())
        {[value], _lua} = Lua.eval!(lua, "return platform.now()")
        {:ok, value}
      end)
    end

    run_wasm = fn ->
      with_time_source(FixedTimeSource, fn ->
        {pid, store, memory} = start_read_path_instance(wasm_execution_context())

        {:ok, [n]} = call_function(pid, "call_now", [@out_ptr, @out_cap])
        outcome = {:ok, read_bytes(store, memory, @out_ptr, n)}

        GenServer.stop(pid)
        outcome
      end)
    end

    %{host_function: :now, parity: :full, run_lua: run_lua, run_wasm: run_wasm}
  end

  # ── uuid (WASM-only, no Lua counterpart -- REQ-171 §3) ────────────────────────

  defp uuid_scenario do
    run_wasm = fn ->
      {pid, store, memory} = start_read_path_instance(wasm_execution_context())

      {:ok, [n]} = call_function(pid, "call_uuid", [@out_ptr, @out_cap])
      outcome = {:ok, read_bytes(store, memory, @out_ptr, n)}

      GenServer.stop(pid)
      outcome
    end

    %{host_function: :uuid, parity: :wasm_only, run_lua: nil, run_wasm: run_wasm}
  end

  # ── write_variable ─────────────────────────────────────────────────────────────
  #
  # The canonical outcome compared here is the call's own success/failure signal,
  # {:ok, nil} on both sides for a well-formed write -- NOT the staged buffer's
  # content (`take_staged_writes/0`/`Platform.take_staged_writes/0` are each a
  # read-and-clear deliberately unwired to any caller by this requirement, design §7
  # OQ-1; asserting staged content is TEST-DESIGNER's own, deeper scenario family,
  # not this fixed 7-entry registry's job).

  defp write_variable_scenario do
    run_lua = fn ->
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:write"]),
          lua_execution_context()
        )

      case Lua.eval!(
             lua,
             "return platform.write_variable('#{@write_variable_name}', '#{@write_variable_value}')"
           ) do
        {[], _lua} -> {:ok, nil}
      end
    end

    run_wasm = fn ->
      {pid, store, memory} =
        start_write_path_instance(wasm_execution_context())

      write_bytes(store, memory, 0, @write_variable_name)
      value_json = Jason.encode!(@write_variable_value)
      write_bytes(store, memory, 2048, value_json)

      outcome =
        case call_function(pid, "call_write_variable", [
               0,
               byte_size(@write_variable_name),
               2048,
               byte_size(value_json)
             ]) do
          {:ok, [0]} -> {:ok, nil}
          {:ok, [n]} -> {:error, "write_variable failed: #{n}"}
        end

      GenServer.stop(pid)
      outcome
    end

    %{host_function: :write_variable, parity: :full, run_lua: run_lua, run_wasm: run_wasm}
  end

  # ── call_service ───────────────────────────────────────────────────────────────

  defp call_service_scenario do
    run_lua = fn ->
      with_service_caller(FakeServiceCaller, fn ->
        lua =
          Platform.install(
            Sandbox.new(),
            Capabilities.new([Capabilities.service_capability(@call_service_id)]),
            lua_execution_context()
          )

        script = """
        local response = platform.call_service('#{@call_service_id}', {amount = 1})
        return response.amount, response.currency
        """

        case Lua.eval!(lua, script) do
          {[amount, currency], _lua} ->
            {:ok, %{"amount" => amount, "currency" => currency}}
        end
      end)
    end

    run_wasm = fn ->
      with_service_caller(FakeServiceCaller, fn ->
        {pid, store, memory} =
          start_write_path_instance(wasm_execution_context())

        service_id = @call_service_id
        payload_json = Jason.encode!(%{"amount" => 1})
        write_bytes(store, memory, 0, service_id)
        write_bytes(store, memory, 2048, payload_json)

        {:ok, [n]} =
          call_function(pid, "call_call_service", [
            0,
            byte_size(service_id),
            2048,
            byte_size(payload_json),
            @out_ptr,
            @out_cap
          ])

        outcome =
          case Jason.decode!(read_bytes(store, memory, @out_ptr, n)) do
            %{"ok" => true, "value" => value} -> {:ok, value}
            %{"ok" => false, "error" => %{"reason" => reason}} -> {:error, reason}
          end

        GenServer.stop(pid)
        outcome
      end)
    end

    %{host_function: :call_service, parity: :full, run_lua: run_lua, run_wasm: run_wasm}
  end

  # ── fail ───────────────────────────────────────────────────────────────────────
  #
  # Lua: `exit/1` crashes the process running the script directly -- observed bare,
  # unwrapped, via `Task.yield/2`'s `{:exit, reason}` clause (mirrors
  # `platform_test.exs`'s own REQ-161 harness). WASM: the mechanism is structurally
  # different (design §9.5) -- `exit/1` inside `do_fail/5` is caught internally by
  # `wasmex`'s own `handle_info/2` (the Wasmex instance process survives), so this
  # closure must hold its own `pid` and apply the design §5.3/§2.2 caller-side
  # contract itself: observe `Wasmex.call_function/4`'s `{:error, _}` return, then
  # read `Process.info(pid, :dictionary)` for the fail-signal key STRICTLY BEFORE
  # stopping that `pid` -- this is the one scenario whose `run_wasm/0` cannot be a
  # bare `Wasmex.call_function/4` wrapper the way every other scenario's can.

  defp fail_scenario do
    run_lua = fn ->
      lua = Platform.install(Sandbox.new(), Capabilities.new([]), lua_execution_context())

      script = """
      platform.fail('#{@fail_reason}', {x = 1})
      """

      task = Task.async(fn -> Lua.eval!(lua, script) end)

      case Task.yield(task, 1_000) do
        {:exit, {:script_failed, %{reason: reason, details: details}}} ->
          {:failed, reason, details}
      end
    end

    run_wasm = fn ->
      {pid, store, memory} =
        start_write_path_instance(wasm_execution_context())

      details_json = Jason.encode!(@fail_details)
      write_bytes(store, memory, 0, @fail_reason)
      write_bytes(store, memory, 2048, details_json)

      result =
        Wasmex.call_function(pid, "call_fail", [
          0,
          byte_size(@fail_reason),
          2048,
          byte_size(details_json)
        ])

      outcome =
        case result do
          {:error, _msg} ->
            case fail_signal(pid) do
              {:ok, %{reason: reason, details: details}} -> {:failed, reason, details}
              :none -> {:error, "expected a fail signal, found none"}
            end

          {:ok, _other} ->
            {:error, "expected platform.fail to abort the call, got a normal return"}
        end

      GenServer.stop(pid)
      outcome
    end

    %{host_function: :fail, parity: :full, run_lua: run_lua, run_wasm: run_wasm}
  end

  # ── shared plumbing ────────────────────────────────────────────────────────────

  defp lua_execution_context(variables \\ %{}) do
    Map.merge(Platform.empty_execution_context(), %{variables: variables})
  end

  defp wasm_execution_context(variables \\ %{}) do
    Map.merge(HostApi.empty_execution_context(), %{variables: variables})
  end

  defp fixture_bytes(name) do
    :letflow
    |> Application.app_dir("priv")
    |> Path.join("wasm_fixtures/#{name}")
    |> File.read!()
  end

  # req171_host_api.wat imports read_variable/log/now/uuid unconditionally --
  # wasmtime requires every DECLARED import to resolve at instantiation time
  # regardless of whether the guest ever calls it, so every scenario using this
  # fixture must grant both "var:read" and "audit:log" (mirrors
  # host_api_test.exs's own identical fixture-driven constraint).
  defp start_read_path_instance(execution_context) do
    manifest = %{capabilities: ["var:read", "audit:log"]}
    table = CapabilityGate.build_import_table(manifest, execution_context)
    {:ok, pid} = Wasmex.start_link(%{bytes: fixture_bytes("req171_host_api.wat"), imports: table})
    {:ok, store} = Wasmex.store(pid)
    {:ok, memory} = Wasmex.memory(pid)
    {pid, store, memory}
  end

  # req172_host_api.wat imports write_variable/platform_call_service/fail
  # unconditionally -- same constraint as above, so every scenario using this
  # fixture must grant both "var:write" and "service:call" ("fail" is :none,
  # always installed regardless of manifest).
  defp start_write_path_instance(execution_context) do
    manifest = %{capabilities: ["var:write", "service:call"]}
    table = CapabilityGate.build_import_table(manifest, execution_context)
    {:ok, pid} = Wasmex.start_link(%{bytes: fixture_bytes("req172_host_api.wat"), imports: table})
    {:ok, store} = Wasmex.store(pid)
    {:ok, memory} = Wasmex.memory(pid)
    {pid, store, memory}
  end

  defp call_function(pid, name, args), do: Wasmex.call_function(pid, name, args)

  defp write_bytes(store, memory, offset, data),
    do: Wasmex.Memory.write_binary(store, memory, offset, data)

  defp read_bytes(store, memory, offset, len),
    do: Wasmex.Memory.read_binary(store, memory, offset, len)

  # design §2.2 -- reads the fail-signal key (private to Letflow.Engine.Wasm.HostApi)
  # out of the still-alive Wasmex instance process's own dictionary. Must be called
  # strictly before that pid is stopped or otherwise torn down -- mirrors
  # PluginHandler.call_export/3's own identical, independently-implemented check
  # (design §2.2: "applies the identical ordering rule directly against a raw
  # Wasmex.call_function/4 call it drives itself... independent of PluginHandler").
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

  defp with_time_source(module, fun) do
    previous = Application.get_env(:letflow, :lua_platform_time_source)
    Application.put_env(:letflow, :lua_platform_time_source, module)

    try do
      fun.()
    after
      restore_env(:lua_platform_time_source, previous)
    end
  end

  defp with_service_caller(module, fun) do
    previous = Application.get_env(:letflow, :lua_platform_service_caller)
    Application.put_env(:letflow, :lua_platform_service_caller, module)

    try do
      fun.()
    after
      restore_env(:lua_platform_service_caller, previous)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:letflow, key)
  defp restore_env(key, value), do: Application.put_env(:letflow, key, value)
end
