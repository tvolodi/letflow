defmodule Letflow.Engine.ServiceTaskDispatcher.Poller do
  @moduledoc """
  Supervised `GenServer` ticker for REQ-214's SERVICE_TASK dispatch
  orchestration. Mirrors `Letflow.Scheduler.Poller`'s shape (design
  `lib/letflow/design/service_task_dispatcher.md` §7) at the scope this
  requirement needs — no REQ-188/194/199/201-style feature accretion
  (retention, metrics, alerts, ordering all belong to
  `Letflow.Scheduler.Poller` specifically and are not duplicated here).

  `init/1` schedules its first `:tick` message with ZERO delay, so a
  restart catches up on missed dispatches with no special-cased recovery
  logic — identical rationale to `Letflow.Scheduler.Poller`.

  ## Boot-gating (design §8, INV-STD-7)

  This `GenServer`'s own first tick queries `Letflow.Repo` from a process
  no test process is an ancestor of — under `Ecto.Adapters.SQL.Sandbox`'s
  default `:manual` mode (this project's test mode) that raises
  `DBConnection.OwnershipError` on every tick, repeatedly, until the
  supervisor's restart intensity is exceeded and `Letflow.Supervisor` (and
  everything under it, including `Letflow.Repo`) shuts down — the exact
  same hazard `Letflow.Scheduler.Poller`'s own `:start_scheduler` gate
  exists to prevent (`lib/letflow/application.ex`'s `scheduler_children/0`
  comment). This module carries the identical hazard and MUST use the
  identical gating convention — but a NEW, distinct config key,
  `:start_service_task_dispatcher`, not a reuse of `:start_scheduler` (the
  two pollers are independent concerns with independent poll cadences,
  per REQ-214's own text — `lib/letflow/application.ex`'s
  `service_task_dispatcher_children/0`).

  `config :letflow, :service_task_dispatcher, [...]`
  (`Letflow.Engine.ServiceTaskDispatcher`'s own accessors) is read fresh on
  every tick, so a runtime override takes effect on the very next tick.
  Jitter is applied only to the inter-tick scheduling delay, never to any
  `next_attempt_at` value.
  """

  use GenServer

  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  @type state :: %{last_tick_started_at: DateTime.t() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{last_tick_started_at: nil}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :tick, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()

    new_state =
      case fetch_tenant_schemas() do
        {:ok, schemas} ->
          Enum.each(schemas, fn schema_name ->
            ServiceTaskDispatcher.poll_and_dispatch(schema_name)
          end)

          %{state | last_tick_started_at: now}

        :error ->
          %{state | last_tick_started_at: now}
      end

    schedule_next_tick()

    {:noreply, new_state}
  end

  defp tenant_schemas do
    Registration
    |> where([r], not is_nil(r.migrations_applied_at))
    |> select([r], r.schema_name)
    |> Repo.all()
  end

  # Mirrors Letflow.Scheduler.Poller's own fetch_tenant_schemas/0 -- a
  # fully-unreachable database must not crash this GenServer.
  defp fetch_tenant_schemas do
    {:ok, tenant_schemas()}
  rescue
    _error -> :error
  end

  defp schedule_next_tick do
    delay = ServiceTaskDispatcher.poll_interval_ms() + jitter_extra_ms()
    Process.send_after(self(), :tick, delay)
  end

  defp jitter_extra_ms do
    case ServiceTaskDispatcher.jitter_ms() do
      0 -> 0
      jitter_ms -> :rand.uniform(jitter_ms + 1) - 1
    end
  end
end
