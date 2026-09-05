defmodule Letflow.Engine.Wasm.HostApiWriteTest do
  @moduledoc """
  REQ-172 (WASM-12 write half + its own parity-suite acceptance criterion) --
  coverage for `Letflow.Engine.Wasm.HostApi`'s `write_variable`/`call_service`/`fail`
  and the shared parity harness (`test/support/host_api_parity.ex`,
  `Letflow.Test.HostApiParity`). See
  `lib/letflow/design/req172-wasm-host-api-write-path-and-parity-suite.md`
  (gate-approved) and `test/specs/REQ-172.md` for the full design/spec this suite
  exercises.

  **The shared parity harness (WASM-12's own acceptance criterion, design §8)**: this
  file does NOT re-implement a second dual-drive mechanism -- `Letflow.Test.
  HostApiParity.scenarios/0` + `assert_parity/1` (already implemented,
  `test/support/host_api_parity.ex`) is the ONE registry driving both the Lua and WASM
  runtimes for all seven currently-real host functions; the describe block below
  simply calls `assert_parity/1` once per scenario plus the exhaustiveness guard.

  **Discard-arm tests (write_variable's five failure arms)** read the Wasmex
  instance's OWN process dictionary directly via `Process.info(pid, :dictionary)`
  (the `staged_writes/1`/`fail_signal/1` helpers below, mirroring
  `Letflow.Engine.Wasm.PluginHandler`'s own identical, independently-implemented
  `fail_signal/1` private function, design §2.2) to confirm a write genuinely reached
  the staging buffer BEFORE asserting `Letflow.Engine.Wasm.HostApi.take_staged_writes/0`
  -- called from THIS (test) process, a process wholly distinct from whichever process
  ran the guest -- observes `%{}`. This mirrors `platform_test.exs`'s own REQ-160
  cross-process discipline exactly: process dictionaries are strictly per-process,
  never inherited/copied/merged by the BEAM, so this is a direct observation of
  discard, not an inference.

  `async: false`: builds real Wasmtime instances via `wasmex`'s NIF, mirroring every
  other WASM-NIF test file in this suite.
  """

  use ExUnit.Case, async: false

  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.Wasm.CapabilityGate
  alias Letflow.Engine.Wasm.HostApi
  alias Letflow.Engine.Wasm.InvocationLease
  alias Letflow.Engine.Wasm.ResourceLimits
  alias Letflow.Test.HostApiParity

  @out_ptr 8192
  @out_cap 4096

  # ── shared plumbing ──────────────────────────────────────────────────────────────

  defp fixture_bytes(name) do
    Application.app_dir(:letflow, "priv")
    |> Path.join("wasm_fixtures/#{name}")
    |> File.read!()
  end

  defp write_bytes(store, memory, offset, data),
    do: Wasmex.Memory.write_binary(store, memory, offset, data)

  defp read_bytes(store, memory, offset, len),
    do: Wasmex.Memory.read_binary(store, memory, offset, len)

  # req172_*.wat fixtures used by this file each import ONLY the host functions their
  # own moduledoc header names -- so the manifest passed here only needs to grant what
  # that specific fixture actually declares (unlike req172_host_api.wat, which
  # unconditionally imports all three write-path functions at once).
  defp start_instance(fixture, capabilities) do
    manifest = %{capabilities: capabilities}
    table = CapabilityGate.build_import_table(manifest, HostApi.empty_execution_context())
    {:ok, pid} = Wasmex.start_link(%{bytes: fixture_bytes(fixture), imports: table})
    {:ok, store} = Wasmex.store(pid)
    {:ok, memory} = Wasmex.memory(pid)
    {pid, store, memory}
  end

  defp start_instance_with_store(fixture, capabilities, resource_config) do
    manifest = %{capabilities: capabilities}
    table = CapabilityGate.build_import_table(manifest, HostApi.empty_execution_context())
    {:ok, {_engine, store}} = ResourceLimits.build_store(resource_config)
    {:ok, pid} = Wasmex.start_link(%{store: store, bytes: fixture_bytes(fixture), imports: table})
    {:ok, memory} = Wasmex.memory(pid)
    {pid, store, memory}
  end

  # Dispatches a guest call under the existing, unmodified
  # Letflow.Engine.PluginTaskSupervisor, mirroring resource_limits_test.exs's own
  # identical dispatch/2 helper and rationale.
  defp dispatch(fun, timeout_ms \\ 10_000) do
    task = Task.Supervisor.async_nolink(Letflow.Engine.PluginTaskSupervisor, fun)

    case Task.yield(task, timeout_ms) do
      {:ok, result} -> result
      {:exit, reason} -> {:exit, reason}
      nil -> Task.shutdown(task, :brutal_kill) && :outer_timeout
    end
  end

  # design §2.2/§7 -- reads the private @staged_writes_pdict_key entry directly out of
  # a still-alive Wasmex instance process's OWN dictionary. Must be called strictly
  # before that pid is stopped/abandoned. Mirrors PluginHandler's own private
  # fail_signal/1 (plugin_handler.ex) and this file's own fail_signal/1 below, applied
  # to the SEPARATE staged-writes key instead of the fail-signal key.
  defp staged_writes(pid) do
    staged_writes_key = {Letflow.Engine.Wasm.HostApi, :staged_writes}

    case Process.info(pid, :dictionary) do
      {:dictionary, entries} ->
        case List.keyfind(entries, staged_writes_key, 0) do
          {^staged_writes_key, writes} -> writes
          nil -> %{}
        end

      nil ->
        %{}
    end
  end

  # design §2.2 -- identical mechanism to PluginHandler.fail_signal/1 and
  # HostApiParity's own private fail_signal/1, independently re-implemented here per
  # the design's own "the harness applies the identical ordering rule directly...
  # independent of PluginHandler" statement (§2.2).
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

  defmodule FakeServiceCaller do
    @moduledoc false
    @behaviour Platform.ServiceCaller

    @impl Platform.ServiceCaller
    def call(_service_id, %{"fail" => true}), do: {:error, "service_unavailable"}
    def call(_service_id, payload), do: {:ok, Map.put(payload, "echoed", true)}
  end

  defmodule SpyServiceCaller do
    @moduledoc false
    @behaviour Platform.ServiceCaller

    @impl Platform.ServiceCaller
    def call(service_id, payload) do
      send(
        Process.whereis(:host_api_write_test_spy_target) || self(),
        {:spy_called, service_id, payload}
      )

      {:ok, %{}}
    end
  end

  defp with_service_caller(module, fun) do
    previous = Application.get_env(:letflow, :lua_platform_service_caller)
    Application.put_env(:letflow, :lua_platform_service_caller, module)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:letflow, :lua_platform_service_caller, previous)
      else
        Application.delete_env(:letflow, :lua_platform_service_caller)
      end
    end
  end

  # ---------------------------------------------------------------------
  # WASM-12's own AC: ONE shared scenario registry drives both runtimes.
  # ---------------------------------------------------------------------

  describe "WASM-12: the shared parity harness (Letflow.Test.HostApiParity) covers all seven current host functions" do
    test "scenario read_variable: assert_parity/1 passes" do
      assert HostApiParity.assert_parity(Map.fetch!(HostApiParity.scenarios(), :read_variable)) ==
               :ok
    end

    test "scenario log: assert_parity/1 passes" do
      assert HostApiParity.assert_parity(Map.fetch!(HostApiParity.scenarios(), :log)) == :ok
    end

    test "scenario now: assert_parity/1 passes" do
      assert HostApiParity.assert_parity(Map.fetch!(HostApiParity.scenarios(), :now)) == :ok
    end

    test "scenario uuid: assert_parity/1 passes" do
      assert HostApiParity.assert_parity(Map.fetch!(HostApiParity.scenarios(), :uuid)) == :ok
    end

    test "scenario write_variable: assert_parity/1 passes" do
      assert HostApiParity.assert_parity(Map.fetch!(HostApiParity.scenarios(), :write_variable)) ==
               :ok
    end

    test "scenario call_service: assert_parity/1 passes" do
      assert HostApiParity.assert_parity(Map.fetch!(HostApiParity.scenarios(), :call_service)) ==
               :ok
    end

    test "scenario fail: assert_parity/1 passes" do
      assert HostApiParity.assert_parity(Map.fetch!(HostApiParity.scenarios(), :fail)) == :ok
    end

    # Design §8.4's exhaustiveness guard: a future 8th @known_imports row without a
    # matching scenarios() entry fails this assertion, by construction -- two
    # INDEPENDENTLY-derived sets, never a second hand-written literal list.
    test "exhaustiveness guard: the parity registry's key set equals CapabilityGate.known_host_functions/0's set, independently derived" do
      registry_keys = HostApiParity.scenarios() |> Map.keys() |> MapSet.new()
      known_functions = CapabilityGate.known_host_functions() |> MapSet.new()

      assert registry_keys == known_functions
    end

    test "the harness module is quoted, by name, in Letflow.Engine.Wasm.HostApi's own moduledoc or its own moduledoc names itself as the one registry" do
      {:docs_v1, _, _, _, %{"en" => harness_moduledoc}, _, _} = Code.fetch_docs(HostApiParity)

      assert harness_moduledoc =~ "ONE scenario registry"
      assert harness_moduledoc =~ "WASM-12"
    end
  end

  # ---------------------------------------------------------------------
  # write_variable: single write, accumulation/last-write-wins, empty buffer,
  # malformed value, number-type round trip -- design §11 checklist item 1.
  # ---------------------------------------------------------------------

  describe "write_variable: staging, accumulation, and the -2 malformed-value case" do
    test "a single write is retrievable from the instance's own process dictionary" do
      {pid, store, memory} = start_instance("req172_host_api.wat", ["var:write", "service:call"])

      write_bytes(store, memory, 0, "x")
      value_json = Jason.encode!(42)
      write_bytes(store, memory, 2048, value_json)

      assert {:ok, [0]} =
               Wasmex.call_function(pid, "call_write_variable", [
                 0,
                 1,
                 2048,
                 byte_size(value_json)
               ])

      assert staged_writes(pid) == %{"x" => 42}

      GenServer.stop(pid)
    end

    test "several writes accumulate, last-write-wins on a duplicate key, no partial state observable mid-sequence" do
      {pid, store, memory} = start_instance("req172_host_api.wat", ["var:write", "service:call"])

      write_bytes(store, memory, 0, "a")
      write_bytes(store, memory, 10, "b")

      write_variable = fn name_ptr, name_len, value ->
        json = Jason.encode!(value)
        write_bytes(store, memory, 2048, json)

        assert {:ok, [0]} =
                 Wasmex.call_function(pid, "call_write_variable", [
                   name_ptr,
                   name_len,
                   2048,
                   byte_size(json)
                 ])
      end

      write_variable.(0, 1, 1)
      write_variable.(10, 1, 2)
      write_variable.(0, 1, 3)

      staged = staged_writes(pid)
      assert map_size(staged) == 2
      assert staged == %{"a" => 3, "b" => 2}

      GenServer.stop(pid)
    end

    test "a script execution that never calls write_variable leaves an empty buffer" do
      {pid, _store, _memory} =
        start_instance("req172_host_api.wat", ["var:write", "service:call"])

      assert staged_writes(pid) == %{}

      GenServer.stop(pid)
    end

    test "malformed value JSON returns -2, nothing staged" do
      {pid, store, memory} = start_instance("req172_host_api.wat", ["var:write", "service:call"])

      write_bytes(store, memory, 0, "x")
      malformed_json = "{not valid json"
      write_bytes(store, memory, 2048, malformed_json)

      assert {:ok, [-2]} =
               Wasmex.call_function(pid, "call_write_variable", [
                 0,
                 1,
                 2048,
                 byte_size(malformed_json)
               ])

      assert staged_writes(pid) == %{}

      GenServer.stop(pid)
    end

    test "round-trips an integer AND a whole-number float distinctly via LuaNumberMarshalling.from_lua/1 (AC6)" do
      {pid, store, memory} = start_instance("req172_host_api.wat", ["var:write", "service:call"])

      write_bytes(store, memory, 0, "int_var")
      int_json = Jason.encode!(3)
      write_bytes(store, memory, 2048, int_json)

      assert {:ok, [0]} =
               Wasmex.call_function(pid, "call_write_variable", [0, 7, 2048, byte_size(int_json)])

      write_bytes(store, memory, 100, "float_var")
      float_json = Jason.encode!(3.0)
      write_bytes(store, memory, 2048, float_json)

      assert {:ok, [0]} =
               Wasmex.call_function(pid, "call_write_variable", [
                 100,
                 9,
                 2048,
                 byte_size(float_json)
               ])

      staged = staged_writes(pid)
      assert %{"int_var" => 3, "float_var" => 3.0} = staged
      assert is_integer(staged["int_var"])
      assert is_float(staged["float_var"])

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # write_variable discard on every failure arm -- design §11 checklist item 2,
  # §2/§2.3/§3.4/§9.1.
  # ---------------------------------------------------------------------

  describe "write_variable: discard on every failure arm (AC per design §2.3)" do
    test "a genuine guest trap discards the staged write" do
      {pid, store, memory} = start_instance("req172_write_then_trap.wat", ["var:write"])

      write_bytes(store, memory, 0, "trap_var")
      value_json = Jason.encode!("trap-value")
      write_bytes(store, memory, 2048, value_json)

      assert {:error, _reason} =
               Wasmex.call_function(pid, "write_then_trap", [
                 0,
                 byte_size("trap_var"),
                 2048,
                 byte_size(value_json)
               ])

      # Confirms the write really reached the staging buffer BEFORE the process is
      # torn down -- a genuine cross-process discard proof, not a script that never
      # staged anything.
      assert staged_writes(pid) == %{"trap_var" => "trap-value"}

      GenServer.stop(pid)

      assert HostApi.take_staged_writes() == %{},
             "this (test) process is a DIFFERENT process from the one that ran the " <>
               "guest -- its own take_staged_writes/0 must never observe the write"
    end

    test "REQ-169's fuel exhaustion discards the staged write" do
      {pid, store, memory} =
        start_instance_with_store("req172_write_then_fuel_exhaustion.wat", ["var:write"], %{
          fuel_budget: 5_000,
          # req172_write_then_fuel_exhaustion.wat declares a 2-page minimum memory --
          # the cap must be >= that or instantiation itself fails.
          memory_cap_bytes: 2 * 65_536
        })

      :ok = ResourceLimits.arm_fuel(store, 5_000)

      write_bytes(store, memory, 0, "fuel_var")
      value_json = Jason.encode!("fuel-value")
      write_bytes(store, memory, 2048, value_json)

      result =
        dispatch(fn ->
          Wasmex.call_function(pid, "write_then_loop_forever", [
            0,
            byte_size("fuel_var"),
            2048,
            byte_size(value_json)
          ])
        end)

      assert ResourceLimits.classify_call_result(result) == :fuel_exhausted
      assert staged_writes(pid) == %{"fuel_var" => "fuel-value"}

      GenServer.stop(pid)

      assert HostApi.take_staged_writes() == %{}
    end

    test "REQ-169's memory cap: a guest's own reactive platform.fail after observing the -1 growth-failure sentinel discards the staged write" do
      {pid, store, memory} =
        start_instance_with_store("req172_write_then_memory_cap_fail.wat", ["var:write"], %{
          fuel_budget: 100_000,
          memory_cap_bytes: 2 * 65_536
        })

      :ok = ResourceLimits.arm_fuel(store, 100_000)

      write_bytes(store, memory, 0, "cap_var")
      value_json = Jason.encode!("cap-value")
      write_bytes(store, memory, 2048, value_json)
      write_bytes(store, memory, 3000, "cap exceeded")

      # grow_delta (50 pages) vastly exceeds the 2-page cap configured above --
      # guaranteed to hit the -1 sentinel (REQ-169's own live-verified finding).
      result =
        dispatch(fn ->
          Wasmex.call_function(pid, "write_then_grow_and_fail", [
            0,
            byte_size("cap_var"),
            2048,
            byte_size(value_json),
            50,
            3000,
            byte_size("cap exceeded"),
            0,
            0
          ])
        end)

      assert {:error, _reason} = result
      assert staged_writes(pid) == %{"cap_var" => "cap-value"}
      assert {:ok, %{reason: "cap exceeded"}} = fail_signal(pid)

      GenServer.stop(pid)

      assert HostApi.take_staged_writes() == %{}
    end

    # ISS-0406/ISS-0352 recurrence mitigation: this test's own internal bound
    # is a fixed 300ms wasmex GenServer.call timeout, so it normally
    # completes in well under 2s. This exact test (host_api_write_test.exs:449)
    # is the one that hit ExUnit's default 60_000ms per-test timeout on the
    # ISS-0352/PR #780 recurrence -- not because the mechanism under test
    # took 60s, but because CI-runner CPU scheduling contention delayed
    # BEAM's own timer/message delivery to the caller. A raised @tag timeout
    # tolerates that jitter without masking a genuine regression: if
    # wasmex's client-side timeout ever stopped firing for real, this test
    # would still eventually hit the (now-later) timeout and fail.
    @tag :wasm_hang
    @tag timeout: 180_000
    test "REQ-170's wall-clock timeout abandons the staged write -- unreachable to any future caller, not process death (design §2.3/§9.1)" do
      # ISS-0418 (design iss0418-wasm-concurrency-cap.md §6.2 Shape C): this lease is
      # TEST-SIDE ONLY -- production dispatch does not acquire one yet (design doc
      # §0/§7). Acquired here, before start_instance/2, since this shape has no
      # Task.shutdown(:brutal_kill) anywhere in its call graph (this test process's
      # own try/catch observes its own exit directly). Released via on_exit/1, not a
      # bare try/after, so a later assertion failure cannot skip the release.
      {:ok, lease} = InvocationLease.try_acquire()
      on_exit(fn -> InvocationLease.release(lease) end)

      {pid, store, memory} = start_instance("req172_write_then_hang.wat", ["var:write"])

      write_bytes(store, memory, 0, "hang_var")
      value_json = Jason.encode!("hang-value")
      write_bytes(store, memory, 2048, value_json)

      result =
        try do
          {:clean_return,
           Wasmex.call_function(
             pid,
             "write_then_hang",
             [0, byte_size("hang_var"), 2048, byte_size(value_json)],
             300
           )}
        catch
          :exit, reason -> {:exit, reason}
        end

      assert {:exit, reason} = result,
             "expected wasmex's own client-side GenServer.call timeout to crash the " <>
               "caller (design §2.3/live-verified REQ-170 finding), not return a clean " <>
               "{:error, _}"

      assert match?({:timeout, {GenServer, :call, _}}, reason)

      # design §2.3/§9.1: this process is ABANDONED, not killed -- no attempt is made
      # (or should be made) to reach into it or stop it. The discard guarantee under
      # test is "no future caller ever observes the write", proven the same way as
      # every other arm: from a wholly distinct process.
      assert HostApi.take_staged_writes() == %{}
    end

    test "platform.fail discards the staged write" do
      {pid, store, memory} = start_instance("req172_write_then_fail.wat", ["var:write"])

      write_bytes(store, memory, 0, "fail_var")
      value_json = Jason.encode!("fail-value")
      write_bytes(store, memory, 2048, value_json)
      write_bytes(store, memory, 3000, "boom")

      assert {:error, _reason} =
               Wasmex.call_function(pid, "write_then_fail", [
                 0,
                 byte_size("fail_var"),
                 2048,
                 byte_size(value_json),
                 3000,
                 byte_size("boom"),
                 0,
                 0
               ])

      assert staged_writes(pid) == %{"fail_var" => "fail-value"}
      assert {:ok, %{reason: "boom"}} = fail_signal(pid)

      GenServer.stop(pid)

      assert HostApi.take_staged_writes() == %{}
    end

    test "a genuine guest trap is distinguishable from fail -- the fail-signal pdict key is ABSENT after a trap" do
      {pid, store, memory} = start_instance("req172_write_then_trap.wat", ["var:write"])

      write_bytes(store, memory, 0, "x")
      value_json = Jason.encode!(1)
      write_bytes(store, memory, 2048, value_json)

      assert {:error, _reason} =
               Wasmex.call_function(pid, "write_then_trap", [0, 1, 2048, byte_size(value_json)])

      assert fail_signal(pid) == :none,
             "a genuine guest trap must never produce the fail-signal pdict key -- " <>
               "only do_fail/5's own stash_fail_signal/2 call ever writes it"

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # call_service: two structurally distinct failure paths (AC4) -- design §4.3, §11
  # checklist item 3.
  # ---------------------------------------------------------------------

  describe "call_service: structured service failure vs. missing-capability instantiation denial, asserted distinctly (AC4)" do
    test "a service-side failure returns a well-formed {\"ok\": false, ...} envelope -- never a trap" do
      with_service_caller(FakeServiceCaller, fn ->
        {pid, store, memory} =
          start_instance("req172_host_api.wat", ["var:write", "service:call"])

        service_id = "billing"
        payload_json = Jason.encode!(%{"fail" => true})
        write_bytes(store, memory, 0, service_id)
        write_bytes(store, memory, 2048, payload_json)

        assert {:ok, [n]} =
                 Wasmex.call_function(pid, "call_call_service", [
                   0,
                   byte_size(service_id),
                   2048,
                   byte_size(payload_json),
                   @out_ptr,
                   @out_cap
                 ])

        assert n >= 0

        assert %{"ok" => false, "error" => %{"reason" => "service_unavailable"}} =
                 Jason.decode!(read_bytes(store, memory, @out_ptr, n))

        GenServer.stop(pid)
      end)
    end

    test "a missing service:call capability fails at instantiation (REQ-167), never invoking the ServiceCaller" do
      Process.register(self(), :host_api_write_test_spy_target)

      with_service_caller(SpyServiceCaller, fn ->
        bytes = fixture_bytes("req172_host_api.wat")

        assert {:error,
                {:instantiation_denied, {:unresolved_import, "env", "platform_call_service"}}} =
                 CapabilityGate.start_instance(bytes, %{capabilities: ["var:write"]})

        refute_received {:spy_called, _service_id, _payload}
      end)

      Process.unregister(:host_api_write_test_spy_target)
    end

    test "call_service makes zero Repo calls" do
      with_service_caller(FakeServiceCaller, fn ->
        {pid, store, memory} =
          start_instance("req172_host_api.wat", ["var:write", "service:call"])

        handler_id = {__MODULE__, :call_service_query_counter, make_ref()}
        counter = :counters.new(1, [])

        :telemetry.attach(
          handler_id,
          [:letflow, :repo, :query],
          fn _event, _measurements, _metadata, _config -> :counters.add(counter, 1, 1) end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        service_id = "billing"
        payload_json = Jason.encode!(%{"amount" => 1})
        write_bytes(store, memory, 0, service_id)
        write_bytes(store, memory, 2048, payload_json)

        assert {:ok, [_n]} =
                 Wasmex.call_function(pid, "call_call_service", [
                   0,
                   byte_size(service_id),
                   2048,
                   byte_size(payload_json),
                   @out_ptr,
                   @out_cap
                 ])

        assert :counters.get(counter, 1) == 0

        GenServer.stop(pid)
      end)
    end
  end

  # ---------------------------------------------------------------------
  # fail: default reason/details, explicit reason/details, invalid-UTF-8 rendering,
  # and AC5's uninterceptability -- design §5, §11 checklist item 4.
  # ---------------------------------------------------------------------

  describe "fail: reason/details decoding" do
    test "a missing reason/details pair (len=0) defaults to the documented fallback string and nil" do
      {pid, _store, _memory} =
        start_instance("req172_host_api.wat", ["var:write", "service:call"])

      assert {:error, _reason} = Wasmex.call_function(pid, "call_fail", [0, 0, 0, 0])

      assert {:ok, %{reason: reason, details: nil}} = fail_signal(pid)
      assert reason == "script called platform.fail with no reason"

      GenServer.stop(pid)
    end

    test "explicit reason/details round-trip, details crossing LuaNumberMarshalling.from_lua/1 one level deep" do
      {pid, store, memory} = start_instance("req172_host_api.wat", ["var:write", "service:call"])

      reason = "custom failure reason"
      details_json = Jason.encode!(%{"code" => 42, "rate" => 2.0})
      write_bytes(store, memory, 0, reason)
      write_bytes(store, memory, 2048, details_json)

      assert {:error, _reason} =
               Wasmex.call_function(pid, "call_fail", [
                 0,
                 byte_size(reason),
                 2048,
                 byte_size(details_json)
               ])

      assert {:ok, %{reason: ^reason, details: details}} = fail_signal(pid)
      assert details["code"] == 42
      assert is_integer(details["code"])
      assert details["rate"] == 2.0
      assert is_float(details["rate"])

      GenServer.stop(pid)
    end

    test "invalid UTF-8 reason bytes are rendered via inspect/1 on the raw bytes, mirroring read_log_field/4's fallback" do
      {pid, store, _memory} = start_instance("req172_host_api.wat", ["var:write", "service:call"])
      {:ok, memory} = Wasmex.memory(pid)

      invalid_utf8 = <<0xFF, 0xFE>>
      write_bytes(store, memory, 0, invalid_utf8)

      assert {:error, _reason} =
               Wasmex.call_function(pid, "call_fail", [0, byte_size(invalid_utf8), 0, 0])

      assert {:ok, %{reason: reason, details: nil}} = fail_signal(pid)
      assert reason == inspect(invalid_utf8)

      GenServer.stop(pid)
    end
  end

  describe "AC5: a guest that attempts to catch or ignore its own fail STILL yields a failed outcome and does not run to completion (WASM analogue of REQ-161's AC1)" do
    test "a guest whose control flow would, if fail returned, stage a second distinguishable write and return a distinguishable literal -- neither is ever observed" do
      {pid, store, memory} = start_instance("req172_fail_then_continue.wat", ["var:write"])

      reason = "uninterceptable"
      write_bytes(store, memory, 0, reason)
      write_bytes(store, memory, 100, "marker_never_written")
      marker_value_json = Jason.encode!("should-never-be-staged")
      write_bytes(store, memory, 2048, marker_value_json)

      result =
        Wasmex.call_function(pid, "fail_then_continue", [
          0,
          byte_size(reason),
          0,
          0,
          100,
          byte_size("marker_never_written"),
          2048,
          byte_size(marker_value_json)
        ])

      # The call must never cleanly return the "continued past fail" literal (777) --
      # if it did, this is a REQ-172 AC5 regression.
      refute match?({:ok, [777]}, result)
      assert {:error, _msg} = result

      assert {:ok, %{reason: ^reason}} = fail_signal(pid)

      # The distinguishable second write must never have been staged either --
      # proves the guest's own execute call never resumed past the fail call site.
      assert staged_writes(pid) == %{},
             "expected the marker write_variable call AFTER platform.fail to never " <>
               "execute -- the guest's execute call must abort at the fail call site"

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # AC7 -- Lua is the definition; this requirement modifies no file under
  # lib/letflow/engine/lua/.
  # ---------------------------------------------------------------------

  describe "AC7: no file under lib/letflow/engine/lua/ is modified by this requirement" do
    # ISS-0413: the git-diff-against-a-live-ref version of this check (`git diff
    # --stat "#{base_ref}...HEAD" -- lib/letflow/engine/lua/`) was removed here.
    # Per docs/anti-patterns.md's "A test embeds `git diff main...HEAD` directly"
    # entry and its ISS-0378/ISS-0404 precedent: even with defensive base_ref
    # resolution (origin/main / main), a live-HEAD diff check is not an evergreen
    # property -- it is permanently unsatisfiable for any later, legitimate PR
    # that needs to touch lib/letflow/engine/lua/ (this suite runs on every future
    # PR's CI, not just REQ-172's own). The structural check below (moduledoc
    # discloses decision 0014 (4) and the "does not modify lib/letflow/engine/lua/"
    # statement) already covers the same intent without depending on git history/
    # ref resolution at test-run time, and is the only one of the two kept, per the
    # same precedent as ISS-0378/ISS-0404's deletions.
    test "moduledoc states decision 0014 (4) and that this module never modifies lib/letflow/engine/lua/" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(HostApi)

      assert moduledoc =~ "decision 0014 (4)"
      assert moduledoc =~ "does not modify"
      assert moduledoc =~ "lib/letflow/engine/lua/"
    end
  end

  # ---------------------------------------------------------------------
  # AC6 -- every non-ABI semantic difference (design §9) enumerated in the moduledoc.
  # ---------------------------------------------------------------------

  describe "AC6: every non-ABI semantic difference is enumerated in the moduledoc (design §9) -- an unlisted one means the requirement is unmet" do
    test "the wall-clock-timeout discard mechanism (abandonment, not destruction) is disclosed" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(HostApi)

      assert moduledoc =~ "abandon",
             "expected the moduledoc to disclose that write_variable's wall-clock-" <>
               "timeout discard arm is an abandoned/leaked process, not a killed one " <>
               "(design §9.1) -- not found"
    end

    test "write_variable's malformed-name arm having no WASM equivalent is disclosed" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(HostApi)

      assert moduledoc =~ "malformed" and moduledoc =~ "name",
             "expected the moduledoc to disclose write_variable's malformed-name arm " <>
               "has no WASM equivalent (design §9.2) -- not found"
    end

    test "the var:write vs. Lua's variable:write capability-token divergence is disclosed" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(HostApi)

      assert moduledoc =~ "var:write" and moduledoc =~ "variable:write",
             "expected the moduledoc to disclose the var:write/variable:write token " <>
               "divergence (design §9.3) -- not found"
    end

    test "call_service's coarser missing-capability granularity on WASM is disclosed" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(HostApi)

      assert moduledoc =~ "granularity" or moduledoc =~ "coarser",
             "expected the moduledoc to disclose call_service's coarser, " <>
               "unparameterized service:call capability vs. Lua's parameterized " <>
               "service:call:<id> (design §9.4) -- not found"
    end

    test "fail's structurally different discard/observation mechanism (pdict signal, not a process crash) is disclosed" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(HostApi)

      assert moduledoc =~ "structurally different",
             "expected the moduledoc to disclose fail's discard/observation " <>
               "mechanism is structurally different from Lua's (design §9.5), not " <>
               "merely a return-shape variant of the same one -- not found"
    end
  end
end
