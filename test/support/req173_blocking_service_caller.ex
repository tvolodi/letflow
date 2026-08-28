defmodule Letflow.Test.Req173BlockingServiceCaller do
  @moduledoc """
  REQ-173 design SS8.1 -- a controllable, releasable gate reused from REQ-172's
  own `do_call_service/8` test-double seam
  (`Application.get_env(:letflow, :lua_platform_service_caller, ...)`,
  `host_api.ex:455-456`). Implements the same `Letflow.Engine.Lua.Platform.
  ServiceCaller`-shaped `call/2` contract `do_call_service/8` already
  dispatches to.

  Because `do_call_service/8` runs INSIDE the Wasmex instance's own process
  (design SS1.1), blocking here blocks exactly that one instance's process and
  nothing else -- the `ModuleVersionRegistry` GenServer, any concurrent
  invocation of any other version, and the test process itself all continue
  running normally while a call is parked here.

  ## Usage

      {:ok, _gate} = Req173BlockingServiceCaller.start_gate()
      previous = Req173BlockingServiceCaller.arm()

      # ... start an invocation whose guest calls platform_call_service ...

      Req173BlockingServiceCaller.await_parked(5_000)
      # ... the guest is now genuinely parked -- do concurrent work here ...
      Req173BlockingServiceCaller.release()

      Req173BlockingServiceCaller.restore(previous)

  `start_gate/0` registers the gate process under this module's own fixed
  name, so `call/2` (which runs inside the Wasmex instance's own, unrelated
  process) can always reach it via `GenServer.call(__MODULE__, ...)` without
  needing the pid passed in explicitly.
  """

  use GenServer

  @behaviour Letflow.Engine.Lua.Platform.ServiceCaller

  @gate_name __MODULE__

  # ── Gate process (test-owned) ───────────────────────────────────────────

  @doc "Starts (or restarts) the gate process under a fixed, well-known name."
  @spec start_gate() :: {:ok, pid()}
  def start_gate do
    case Process.whereis(@gate_name) do
      nil ->
        {:ok, pid} = GenServer.start_link(__MODULE__, :ok, name: @gate_name)
        {:ok, pid}

      pid ->
        :ok = GenServer.stop(pid)
        {:ok, new_pid} = GenServer.start_link(__MODULE__, :ok, name: @gate_name)
        {:ok, new_pid}
    end
  end

  @doc """
  Installs this module as the `:lua_platform_service_caller` test double
  (REQ-172's seam), remembering and restoring whatever was configured before
  via `ExUnit.Callbacks.on_exit/1` semantics -- callers should wrap this in
  their own `on_exit` restore, mirroring `host_api_write_test.exs`'s own
  `with_service_caller/2` helper. Returns the previous value so the caller can
  restore it.
  """
  @spec arm() :: term()
  def arm do
    previous = Application.get_env(:letflow, :lua_platform_service_caller)
    Application.put_env(:letflow, :lua_platform_service_caller, __MODULE__)
    previous
  end

  @spec restore(term()) :: :ok
  def restore(nil), do: Application.delete_env(:letflow, :lua_platform_service_caller)
  def restore(previous), do: Application.put_env(:letflow, :lua_platform_service_caller, previous)

  @doc """
  Synchronously waits (via the gate's own mailbox, never `Process.sleep/1`)
  until a guest call has genuinely arrived and parked. Returns `:ok` or
  `{:error, :timeout}`.
  """
  @spec await_parked(timeout_ms :: pos_integer()) :: :ok | {:error, :timeout}
  def await_parked(timeout_ms \\ 5_000) do
    GenServer.call(@gate_name, :await_parked, timeout_ms)
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, :timeout}
  end

  @doc "Releases the parked call, letting `call/2` return `{:ok, %{}}`."
  @spec release() :: :ok
  def release do
    GenServer.call(@gate_name, :release)
  end

  # ── ServiceCaller behaviour -- runs inside the Wasmex instance's process ──

  @impl Letflow.Engine.Lua.Platform.ServiceCaller
  def call(_service_id, _payload) do
    GenServer.call(@gate_name, :park, :infinity)
    {:ok, %{}}
  end

  # ── GenServer callbacks (gate process) ───────────────────────────────────

  @impl GenServer
  def init(:ok) do
    {:ok, %{parked_from: nil, awaiting_from: nil}}
  end

  @impl GenServer
  def handle_call(:park, from, %{awaiting_from: nil} = state) do
    {:noreply, %{state | parked_from: from}}
  end

  def handle_call(:park, from, %{awaiting_from: awaiting_from} = state) do
    GenServer.reply(awaiting_from, :ok)
    {:noreply, %{state | parked_from: from, awaiting_from: nil}}
  end

  def handle_call(:await_parked, _from, %{parked_from: parked_from} = state)
      when not is_nil(parked_from) do
    {:reply, :ok, state}
  end

  def handle_call(:await_parked, from, state) do
    {:noreply, %{state | awaiting_from: from}}
  end

  def handle_call(:release, _from, %{parked_from: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:release, _from, %{parked_from: parked_from} = state) do
    GenServer.reply(parked_from, :ok)
    {:reply, :ok, %{state | parked_from: nil}}
  end
end
