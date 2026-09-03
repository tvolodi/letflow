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

  ## REQ-218 addition -- admission-control wiring on the six sequential
  per-tenant operations (design `req218-poller-admission-wiring.md`)

  Each of the six named operations below (the timer poll-and-fire loop
  plus the five `maybe_run_*` sweeps) acquires ONE `:global` admission
  unit via `Letflow.Admission.try_acquire/1` for that operation's own
  single per-schema call, and releases it via an `after` clause on the
  wrapping `try` -- guaranteeing release even if some future edit to the
  wrapped operation let an exception past its own existing rescue. On
  `{:error, :capacity}`, that one schema's turn for that one operation is
  skipped for this tick only (logged at `Logger.warning/1`, matching
  `lib/letflow/tenant_provisioning/backfill.ex:37,44` and
  `lib/letflow/obs/alerts.ex:588`'s skip-and-continue precedent) -- every
  other schema, and every other operation, proceeds independently. Only
  `:global` is ever acquired here, never the per-tenant pool -- Poller already
  iterates every tenant schema once per tick by design (REQ-186), so a
  per-tenant cap would only cause silent, unfair skips rather than bound
  anything meaningful for a background sweep. `maybe_refresh_active_instances/1`
  (REQ-194) is deliberately left UNWRAPPED -- not one of REQ-218's six
  named operations.

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

  require Logger

  alias Letflow.Admission
  alias Letflow.Engine
  alias Letflow.Metrics.Registry, as: MetricsRegistry
  alias Letflow.Obs.Alerts
  alias Letflow.Scheduler
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  alias Letflow.Repo

  @type state :: %{
          last_retention_run_at: DateTime.t() | nil,
          last_tick_started_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(
      __MODULE__,
      %{last_retention_run_at: nil, last_tick_started_at: nil},
      name: __MODULE__
    )
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :tick, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()
    observed_lag_ms = compute_lag(get_last_tick_started_at(state), now)

    new_state =
      case fetch_tenant_schemas() do
        {:ok, schemas} ->
          Enum.each(schemas, fn schema_name ->
            with_admission(schema_name, :poll_and_fire, fn ->
              Scheduler.poll_and_fire(schema_name)
            end)
          end)

          maybe_refresh_active_instances(schemas)
          retention_state = maybe_run_retention_sweep(schemas, state)
          maybe_run_alert_detection(schemas, observed_lag_ms, get_last_tick_started_at(state))
          maybe_run_ordering_cycle(schemas)
          maybe_run_ordering_sweeper(schemas)
          maybe_run_ordering_metrics(schemas)
          Map.put(retention_state, :last_tick_started_at, now)

        :error ->
          MetricsRegistry.mark_active_instances_refresh_failed()
          Map.put(state, :last_tick_started_at, now)
      end

    schedule_next_tick()

    {:noreply, new_state}
  end

  # REQ-218: acquires ONE :global admission unit for `fun`'s single
  # Repo-touching call, releasing it via an `after` clause (guaranteed even
  # if `fun` itself raises past whatever rescue it already establishes --
  # `fun` is responsible for its OWN existing rescue boundary, if any; this
  # wrapper adds admission accounting only, never a rescue of its own). On
  # `{:error, :capacity}`, logs and skips `fun` entirely for this
  # schema/operation this tick -- never raises, never halts the caller's
  # `Enum.each`.
  @spec with_admission(String.t(), atom(), (-> any())) :: :ok
  defp with_admission(schema_name, op, fun) when is_function(fun, 0) do
    case Admission.try_acquire(:global) do
      {:ok, ref} ->
        try do
          fun.()
        after
          Admission.release(ref)
        end

      {:error, :capacity} ->
        Logger.warning("poller admission capacity exhausted, skipping schema/operation",
          schema: schema_name,
          op: op
        )
    end

    :ok
  end

  defp compute_lag(nil, _now), do: nil
  defp compute_lag(last, now), do: DateTime.diff(now, last, :millisecond)

  defp get_last_tick_started_at(state) do
    Map.get(state, :last_tick_started_at)
  end

  # REQ-188 design §2.4 -- runs on this same supervised process, no new
  # child, no new ticker. Reuses the `schemas` list already computed for
  # this tick's timer-poll loop above -- not queried a second time.
  defp maybe_run_retention_sweep(schemas, state) do
    if Scheduler.retention_enabled?() and Scheduler.retention_due?(state.last_retention_run_at) do
      Enum.each(schemas, fn schema_name ->
        with_admission(schema_name, :retention_sweep, fn ->
          Scheduler.run_retention_sweep(schema_name)
        end)
      end)

      %{state | last_retention_run_at: DateTime.utc_now()}
    else
      state
    end
  end

  # REQ-201: alert detection piggybacking on this existing tick, no new child,
  # no application.ex change (design §9.1). Reads alert_hooks config fresh on
  # every call; noop if :alert_hooks is not configured or enabled: false.
  defp maybe_run_alert_detection(schemas, observed_lag_ms, last_tick_started_at) do
    cfg = Application.get_env(:letflow, :alert_hooks, [])

    if Keyword.get(cfg, :enabled, false) do
      Enum.each(schemas, fn schema_name ->
        with_admission(schema_name, :alert_detection, fn ->
          try do
            Alerts.build_context_and_detect(schema_name, observed_lag_ms, last_tick_started_at)
          rescue
            _ -> :ok
          end
        end)
      end)
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

  # REQ-199: ordering consumer cycle, one per schema per tick, no new application.ex child.
  defp maybe_run_ordering_cycle(schemas) do
    cfg = Application.get_env(:letflow, :ordering, [])

    if Keyword.get(cfg, :enabled, true) do
      Enum.each(schemas, fn schema_name ->
        with_admission(schema_name, :ordering_cycle, fn ->
          try do
            Letflow.Ordering.run_cycle(schema_name, prefix: schema_name)
          rescue
            _ -> :ok
          end
        end)
      end)
    end
  end

  # REQ-199: gap sweeper, one per schema per tick.
  defp maybe_run_ordering_sweeper(schemas) do
    cfg = Application.get_env(:letflow, :ordering, [])

    if Keyword.get(cfg, :enabled, true) do
      Enum.each(schemas, fn schema_name ->
        with_admission(schema_name, :ordering_sweeper, fn ->
          try do
            Letflow.Ordering.sweep_gaps(schema_name, prefix: schema_name)
          rescue
            _ -> :ok
          end
        end)
      end)
    end
  end

  # REQ-199: lag metrics surface, one per schema per tick.
  defp maybe_run_ordering_metrics(schemas) do
    cfg = Application.get_env(:letflow, :ordering, [])

    if Keyword.get(cfg, :enabled, true) do
      Enum.each(schemas, fn schema_name ->
        with_admission(schema_name, :ordering_metrics, fn ->
          try do
            Letflow.Ordering.emit_lag_metrics(schema_name, prefix: schema_name)
          rescue
            _ -> :ok
          end
        end)
      end)
    end
  end
end
