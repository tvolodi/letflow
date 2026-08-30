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

  ## REQ-194 addition -- `letflow_active_instances` refresh (design
  `req194-prometheus-metrics.md` §6)

  Each tick, after the timer poll-and-fire loop, sums
  `Letflow.Engine.count_instances_by_status/1`'s `:active` key across the SAME
  `tenant_schemas()` list already computed for that tick (no second query) and
  writes the platform-wide total to `Letflow.Metrics.Registry.set_active_instances/1`
  -- this is the one OBS-02 metric family that is NOT `:telemetry`-driven (see that
  module's moduledoc for why).

  Two failure isolation layers, both required so a database outage degrades this one
  metric rather than crashing the whole scheduler (a crashed Poller stops every
  tenant's timers firing platform-wide, a vastly worse regression than a stale
  gauge):

    * `tenant_schemas/0` itself raising (the DB is unreachable entirely) is caught by
      `fetch_tenant_schemas/0` below -- on failure, this tick's poll-and-fire loop
      AND the active-instances refresh are BOTH skipped (there is nothing to iterate
      either one over), `mark_active_instances_refresh_failed/0` is called, and the
      next tick is still scheduled normally. This is a deliberate, flagged deviation
      from the design's literal "the timer poll-and-fire loop for that tick still
      proceeds normally" wording: that loop's own input (`schemas`) is exactly what
      failed to compute, so "proceeding normally" over an empty/undefined list is not
      meaningfully different from skipping it outright -- flagged for REVIEWER.
    * One individual schema's `count_instances_by_status/1` call raising (a single
      tenant's schema corrupted or mid-migration) is caught per-schema in
      `count_active_for_schema/1` -- that schema contributes `0` to the sum and every
      other schema, plus the timer poll-and-fire loop, is unaffected.
  """

  use GenServer

  alias Letflow.Engine
  alias Letflow.Metrics.Registry, as: MetricsRegistry
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
    new_state =
      case fetch_tenant_schemas() do
        {:ok, schemas} ->
          Enum.each(schemas, fn schema_name -> Scheduler.poll_and_fire(schema_name) end)
          maybe_refresh_active_instances(schemas)
          maybe_run_retention_sweep(schemas, state)

        :error ->
          MetricsRegistry.mark_active_instances_refresh_failed()
          state
      end

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

  # REQ-194 (design §6): wraps tenant_schemas/0 so a fully-unreachable database (a
  # raised DBConnection.ConnectionError, per lib/letflow/routers/metrics.ex's own
  # retired moduledoc note that Ecto/DBConnection surfaces pool exhaustion this way,
  # not as an error tuple) never crashes this GenServer.
  defp fetch_tenant_schemas do
    {:ok, tenant_schemas()}
  rescue
    _error -> :error
  end

  # REQ-194 (design §6): sums count_instances_by_status/1's :active key across every
  # schema already computed for this tick (no second tenant_schemas/0 query) and
  # writes the platform-wide total. Never raises -- each schema's own failure is
  # isolated in count_active_for_schema/1.
  defp maybe_refresh_active_instances(schemas) do
    total =
      Enum.reduce(schemas, 0, fn schema_name, acc ->
        acc + count_active_for_schema(schema_name)
      end)

    MetricsRegistry.set_active_instances(total)
  end

  # A single tenant's schema being corrupted or mid-migration must not zero out (or
  # crash) the platform-wide aggregate -- design §6 judges this acceptable
  # specifically because it is a large, low-precision-tolerant summary gauge, unlike
  # a per-tenant figure a single tenant depends on the exact precision of.
  defp count_active_for_schema(schema_name) do
    case Engine.count_instances_by_status(prefix: schema_name) do
      {:ok, counts} -> Map.get(counts, :active, 0)
      {:error, _reason} -> 0
    end
  rescue
    _error -> 0
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
