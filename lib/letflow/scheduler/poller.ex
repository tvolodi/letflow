defmodule Letflow.Scheduler.Poller do
  @moduledoc """
  Supervised `GenServer` ticker implementing REQ-185 §2's Decision 1
  (supervised `GenServer` ticker) and §6's Decision 5 (iterates tenant
  schemas per tick). See `lib/letflow/design/req186-scheduler-core.md` §3
  for the full design this module implements.

  `init/1` schedules its **first** `:tick` message with **zero** delay, so
  a restart catches up on missed timers with no special-cased recovery
  logic.

  ## State (REQ-188 addition — no longer "no meaningful state")

  Prior to REQ-188 this GenServer carried no meaningful state between
  ticks — a pure scheduling loop. REQ-188 widens `state` from `%{}` to
  `%{last_retention_run_at: DateTime.t() | nil}`, the ONE field this
  process now carries, solely to track retention-sweep cadence (see
  `Letflow.Scheduler.retention_due?/1`). It is initialized to `nil` in
  `init/1` and updated only when a retention sweep actually runs. No other
  state is introduced; the timer-poll loop itself remains stateless.

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

  @type state :: %{last_retention_run_at: DateTime.t() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{last_retention_run_at: nil}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :tick, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schemas = tenant_schemas()

    Enum.each(schemas, fn schema_name -> Scheduler.poll_and_fire(schema_name) end)

    new_state = maybe_run_retention_sweep(schemas, state)

    schedule_next_tick()

    {:noreply, new_state}
  end

  # REQ-188 design §2.4 -- runs on this same supervised process, no new
  # child, no new ticker. Reuses the `schemas` list already computed for
  # this tick's timer-poll loop above -- not queried a second time.
  defp maybe_run_retention_sweep(schemas, state) do
    if Scheduler.retention_enabled?() and Scheduler.retention_due?(state.last_retention_run_at) do
      Enum.each(schemas, fn schema_name -> Scheduler.run_retention_sweep(schema_name) end)
      %{state | last_retention_run_at: DateTime.utc_now()}
    else
      state
    end
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
