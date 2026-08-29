defmodule Letflow.Scheduler.Poller do
  @moduledoc """
  Supervised `GenServer` ticker implementing REQ-185 §2's Decision 1
  (supervised `GenServer` ticker) and §6's Decision 5 (iterates tenant
  schemas per tick). See `lib/letflow/design/req186-scheduler-core.md` §3
  for the full design this module implements.

  No meaningful state is carried between ticks — a pure scheduling loop,
  matching REQ-185 §2b's own "no in-memory state to recover" property.
  `init/1` schedules its **first** `:tick` message with **zero** delay, so
  a restart catches up on missed timers with no special-cased recovery
  logic.

  Config (`config :letflow, :scheduler, [...]`, `Letflow.Scheduler`'s own
  accessors) is read fresh on every tick, so a runtime override (e.g. a
  test calling `Application.put_env/3`) takes effect on the very next tick.

  Jitter is applied only to the inter-tick scheduling delay, never to any
  `fire_at` value (SCH-06) -- when `jitter_ms()` is `0`, no random draw is
  made at all, the delay is exactly `poll_interval_ms()`.

  A raise inside one tenant schema's `Letflow.Scheduler.poll_and_fire/1`
  call is not additionally guarded here -- that function's own contract
  (design §2.2) already guarantees it never raises, so a second, redundant
  `try/rescue` around the `Enum.each` below would duplicate an
  already-established isolation boundary for no additional safety
  property.
  """

  use GenServer

  alias Letflow.Scheduler
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  alias Letflow.Repo

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :tick, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    tenant_schemas()
    |> Enum.each(fn schema_name -> Scheduler.poll_and_fire(schema_name) end)

    schedule_next_tick()

    {:noreply, state}
  end

  defp tenant_schemas do
    Registration
    |> where([r], not is_nil(r.migrations_applied_at))
    |> select([r], r.schema_name)
    |> Repo.all()
  end

  defp schedule_next_tick do
    delay = Scheduler.poll_interval_ms() + jitter_extra_ms()
    Process.send_after(self(), :tick, delay)
  end

  defp jitter_extra_ms do
    case Scheduler.jitter_ms() do
      0 -> 0
      jitter_ms -> :rand.uniform(jitter_ms + 1) - 1
    end
  end
end
