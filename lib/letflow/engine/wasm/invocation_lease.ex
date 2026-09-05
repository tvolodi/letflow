defmodule Letflow.Engine.Wasm.InvocationLease do
  @moduledoc """
  Bounds how many WASM guest invocations MAY be simultaneously dispatched through
  `Letflow.Engine.Wasm.PluginHandler.run_guest/3`, admitted via a global counting
  semaphore (`try_acquire/0`/`release/1`) — **for whichever caller actually acquires a
  lease before dispatching.** Filed against decision 0014's OQ-5 and
  `docs/issues/ISS-0418.yaml` (eleven-plus recurrences of a CI flake caused by the
  mechanism this module bounds). See
  `lib/letflow/design/iss0418-wasm-concurrency-cap.md` for the full design and its live
  diagnosis (`handoffs/WF03-ISS0418-20260905/step-01-issue-fixer-diagnosis.json`).

  **PRODUCTION WASM DISPATCH DOES NOT CALL THIS MODULE YET, STATED AS PLAINLY AS THE
  NATIVE-LEAK LIMITATION BELOW.** As of this module's introduction, the only callers
  wired to `try_acquire/0`/`release/1` are the `:wasm_hang`-tagged tests in
  `test/letflow/engine/wasm/` (design doc §6) — added specifically to make those tests'
  own admission deterministic and close a documented CI flake. `PluginInterface.invoke/2,3`
  and `Letflow.Engine.Wasm.PluginHandler` are NOT modified by this module's introduction
  and do not call `try_acquire/0` anywhere in their own bodies. **A real WASM guest
  invocation reached by production dispatch is therefore admitted with NO cap of any
  kind today** — this module exists as a primitive and a contract (design doc §8.1) for
  a future dispatch-integration requirement to wire into the real call path; until that
  requirement ships, this module protects only the test suite that explicitly calls it,
  never live traffic.

  **WHAT THIS MODULE DOES NOT GUARANTEE, STATED PLAINLY.** `wasmex` (Wasmtime via a Rust
  NIF) permanently leaks one native worker-thread-pool slot (`TOKIO_RUNTIME`, node-global,
  sized to `available_parallelism()`) per genuinely-hanging guest invocation, with no
  BEAM-side mechanism able to reclaim it, live-verified up to a 90-second observation
  window with zero recovery. This module bounds how many invocations may be
  **simultaneously in flight** — it does **not**, and cannot, reclaim an already-leaked
  thread, observe how many threads are currently leaked, or prevent eventual pool
  exhaustion if hangs keep occurring over a long enough time window at any nonzero rate.
  Every hang, admitted one at a time or many at once, permanently consumes one pool slot
  forever; this module changes the RATE and worst-case INSTANTANEOUS blast radius of
  exhaustion, not whether exhaustion can ultimately occur on a sufficiently
  long-lived, sufficiently abused node. The only mechanisms that reclaim a leaked
  thread are killing the OS process it lives in or restarting the BEAM node — both
  outside this module's scope; see the design doc §4 for named, unbuilt follow-up
  options (subprocess-per-invocation isolation; a periodic health-probe-triggered
  restart).

  **What this module DOES guarantee:** no more than the configured cap
  (`try_acquire/0`) of WASM invocations are ever simultaneously dispatched through
  `PluginHandler.run_guest/3`, admitted synchronously with no queue
  (`{:error, :capacity}` immediately on exhaustion, mirroring `Letflow.Admission`'s own
  non-queuing precedent) — bounding simultaneous worst-case damage from a burst of
  concurrent hangs to at most `cap` leaked slots at a time, rather than unboundedly many.

  **Why this is a new module, not an extension of `Letflow.Admission` (REQ-216):** see
  design doc §3. In short — `Letflow.Admission`'s documented crash semantics assume a
  caller that either cooperates (calls `release/2` itself) or crashes as a whole
  process; `PluginInterface.invoke/2,3`'s own brutal-kill-on-timeout mechanism kills
  only an INNER task while the outer caller survives, so this module acquires/releases
  its lease from that surviving outer caller and additionally monitors it, automatically
  releasing on that caller's own death — a shape `Letflow.Admission` does not have and
  was not built for. This module also has no per-tenant fair-share dimension, since the
  underlying leaked resource (`TOKIO_RUNTIME`) has no per-tenant partition at all.

  ## Supervision-tree placement — no ordering dependency

  A single supervised `GenServer`, added as a child of `Letflow.Supervisor.Infrastructure`
  alongside `Letflow.Engine.PluginTaskSupervisor` (both are WASM/plugin-dispatch
  infrastructure with no start-order dependency on each other or on `Repo` — mirrors
  `Letflow.Admission`'s own "no ordering dependency" precedent: `init/1` reads only
  static application config, makes no `Repo` call, no `Registry` lookup, and no call to
  any other supervised process).

  ## Crash/restart semantics

  On this `GenServer`'s own crash/restart, `init/1` starts fresh (`in_use: 0`,
  `leases: %{}`) — same safe-failure direction as `Letflow.Admission`'s own documented
  crash semantics: can only under-count (transiently widen admission after a restart),
  never over-count (permanently wedge admission shut). A restart of this GenServer does
  not, and cannot, affect any already-leaked `wasmex` native thread either way — this
  GenServer's own state has never had any relationship to native pool occupancy beyond
  bounding how many NEW invocations may be dispatched at once.
  """

  use GenServer

  @typedoc "An opaque lease handle returned by try_acquire/0. Callers must not
  pattern-match on or construct this struct directly -- only release/1 (or the
  automatic monitor-triggered release) consumes it."
  @type lease :: %__MODULE__.Lease{id: reference()}

  defmodule Lease do
    @moduledoc """
    An opaque lease handle returned by `Letflow.Engine.Wasm.InvocationLease.try_acquire/0`.
    Callers must not pattern-match on or construct this struct directly — only
    `release/1` (or the automatic monitor-triggered release) consumes it.
    """

    @enforce_keys [:id]
    defstruct [:id]

    @type t :: %__MODULE__{id: reference()}
  end

  # Default: max(div(System.schedulers_online(), 2), 1) -- see the design doc §5.5 for
  # the full justification (a fixed FRACTION, not a fixed subtraction, of
  # schedulers_online(), chosen because it degrades gracefully as
  # schedulers_online()/available_parallelism() diverge, unlike a fixed subtraction).
  # THIS IS A HEURISTIC OVER AN UNMEASURABLE QUANTITY, NOT A GUARANTEE -- no BEAM-side
  # API reads wasmex's own native TOKIO_RUNTIME pool size directly (design §5.5). An
  # operator whose BEAM scheduler count is set (via +S/+SDcpu) to significantly exceed
  # the host's actual logical core count must override :cap manually to a value measured
  # against that host's real available_parallelism() (e.g. `nproc` on Linux).
  defp default_cap, do: max(div(System.schedulers_online(), 2), 1)

  # Client API

  @doc """
  Starts the invocation-lease server. `opts` accepts `:name` (default `__MODULE__`) and
  a `:cap` override for test isolation (mirrors `Letflow.Admission.start_link/1`'s own
  `:pool_size`/`:reserved_headroom` overrides). Absent an override, `cap` is read once
  from `Application.get_env(:letflow, :invocation_lease, [])[:cap]`, falling back to
  `default_cap/0` (design doc §5.5) if unset.
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    cap =
      Keyword.get_lazy(opts, :cap, fn ->
        Application.get_env(:letflow, :invocation_lease, [])[:cap] || default_cap()
      end)

    GenServer.start_link(__MODULE__, %{cap: cap}, name: name)
  end

  @doc """
  Attempts to acquire one lease against the global WASM-invocation cap
  (see moduledoc/`start_link/1`). Monitors `self()` at acquire time so the lease
  is automatically released if the calling process dies before an explicit
  `release/1` call. Never parks the caller -- returns `{:error, :capacity}`
  immediately if the cap is already fully leased, mirroring
  `Letflow.Admission.try_acquire/2`'s own non-queuing precedent: the caller already has
  `PluginInterface.invoke/2,3`'s own outer `timeout_ms`-bounded wait as its existing
  "don't wait forever" mechanism; this gate does not duplicate that decision.

  `server` defaults to `__MODULE__`, mirroring `Letflow.Admission`'s own convention, so
  tests can start an isolated instance under a distinct name.
  """
  @spec try_acquire(server :: GenServer.server()) :: {:ok, lease()} | {:error, :capacity}
  def try_acquire(server \\ __MODULE__) do
    GenServer.call(server, :try_acquire)
  end

  @doc """
  Releases a previously-acquired lease. Idempotent: releasing an unknown,
  already-released, or hand-constructed lease is a documented no-op --
  always `:ok`, never a raise (mirrors `Letflow.Admission.release/2`'s own
  idempotency contract). Safe to call from the same process that
  acquired the lease (the expected, primary path) -- calling it from
  a different process is not a supported usage and is not guaranteed to
  behave sensibly, since the automatic monitor-based release is keyed
  to the ACQUIRING process's pid, not the caller of `release/1`.

  `server` defaults to `__MODULE__`.
  """
  @spec release(lease(), server :: GenServer.server()) :: :ok
  def release(%Lease{} = lease, server \\ __MODULE__) do
    GenServer.call(server, {:release, lease})
  end

  @doc """
  Returns the currently configured global cap, live from GenServer state
  -- for observability/tests, mirroring `Letflow.Admission.global_cap/1`'s
  own precedent.

  `server` defaults to `__MODULE__`.
  """
  @spec cap(server :: GenServer.server()) :: pos_integer()
  def cap(server \\ __MODULE__) do
    GenServer.call(server, :cap)
  end

  # GenServer callbacks

  # State shape (design doc §5.3):
  #
  #   %{
  #     cap:     pos_integer(),                          # fixed at init/1, from config
  #     in_use:  non_neg_integer(),
  #     leases:  %{optional(reference()) => %{monitor_ref: reference(), pid: pid()}}
  #   }
  @impl true
  def init(%{cap: cap}) do
    {:ok, %{cap: cap, in_use: 0, leases: %{}}}
  end

  @impl true
  def handle_call(:try_acquire, from, state) do
    if state.in_use < state.cap do
      owner_pid = elem(from, 0)
      monitor_ref = Process.monitor(owner_pid)
      id = make_ref()

      new_state = %{
        state
        | in_use: state.in_use + 1,
          leases: Map.put(state.leases, id, %{monitor_ref: monitor_ref, pid: owner_pid})
      }

      {:reply, {:ok, %Lease{id: id}}, new_state}
    else
      {:reply, {:error, :capacity}, state}
    end
  end

  def handle_call({:release, %Lease{id: id}}, _from, state) do
    case Map.pop(state.leases, id) do
      {nil, _leases} ->
        # Already released, never acquired, or a hand-constructed lease --
        # documented idempotent no-op (moduledoc's "release/1").
        {:reply, :ok, state}

      {%{monitor_ref: monitor_ref}, leases} ->
        # Flush so a normally-releasing holder never ALSO delivers a stale :DOWN
        # for this same monitor (mirrors Letflow.SandboxPool's own documented
        # "flush so a normally-returning worker never ALSO delivers a :DOWN"
        # precedent, sandbox_pool.ex:407).
        Process.demonitor(monitor_ref, [:flush])

        new_state = %{state | in_use: state.in_use - 1, leases: leases}
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:cap, _from, state) do
    {:reply, state.cap, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    # O(map-size) scan over `leases`, bounded by `cap` and therefore small -- the same
    # tradeoff Letflow.SandboxPool/Letflow.Supervisor.PollersBreaker already accept for
    # their own bounded-size :DOWN-keyed lookups (design doc §5.4).
    case Enum.find(state.leases, fn {_id, entry} -> entry.monitor_ref == monitor_ref end) do
      nil ->
        # Stale :DOWN for a monitor ref no longer present (already explicitly
        # released and demonitored) -- documented no-op, matching the "stale ref"
        # precedent pollers_breaker.ex:167 already establishes for the identical
        # race shape.
        {:noreply, state}

      {id, _entry} ->
        new_state = %{
          state
          | in_use: state.in_use - 1,
            leases: Map.delete(state.leases, id)
        }

        {:noreply, new_state}
    end
  end
end
