defmodule Letflow.Ordering.Metrics do
  @moduledoc """
  ORD-04 lag surface for `Letflow.Ordering`. See
  `lib/letflow/design/req199-ordering.md` §10 for the full design.

  Computes per-correlation lag (`max(sequence_no) - applied_seq`) for each
  tenant, writes platform-wide maximums to the `Letflow.Metrics.Registry`
  ETS table, and emits `ordering_lag_threshold_exceeded` platform events
  when any correlation's lag crosses the configured threshold.

  ## Label allow-list: none (AC16 / tenant-safety invariant)

  Neither `letflow_ordering_correlation_lag` nor
  `letflow_ordering_oldest_pending_age_seconds` carries per-tenant or
  per-correlation labels. `GET /metrics` is a global, unauthenticated
  endpoint — no per-entity identifiers may appear as label values.
  """

  alias Letflow.EventStore
  alias Letflow.Repo

  @table :letflow_metrics

  @type lag_info :: %{
          correlation_id: String.t(),
          lag: non_neg_integer(),
          oldest_pending_age_seconds: non_neg_integer() | nil
        }

  @doc """
  Returns per-correlation lag and oldest-pending age for every correlation in
  the given tenant schema that has PENDING rows. A correlation with no PENDING
  rows contributes `lag = 0` and `oldest_pending_age_seconds: nil` (AC14).
  """
  @spec compute_all_lags(opts :: keyword()) :: [lag_info()]
  def compute_all_lags(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    sql = """
    SELECT
      ec.correlation_id,
      MAX(ec.sequence_no) - COALESCE(cc.applied_seq, 0) AS lag,
      MIN(ec.received_at) AS oldest_pending_age_ref
    FROM "#{prefix}".effect_completions ec
    LEFT JOIN "#{prefix}".correlation_cursors cc USING (correlation_id)
    WHERE ec.status = 'PENDING'
    GROUP BY ec.correlation_id, cc.applied_seq
    """

    case Repo.query(sql, [], prefix: prefix) do
      {:ok, %{rows: rows}} ->
        now = DateTime.utc_now()

        Enum.map(rows, fn [correlation_id, lag, oldest_pending_age_ref] ->
          age =
            case oldest_pending_age_ref do
              nil -> nil
              %DateTime{} = dt -> max(0, DateTime.diff(now, dt, :second))
              _ -> nil
            end

          %{
            correlation_id: correlation_id,
            lag: lag || 0,
            oldest_pending_age_seconds: age
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Writes platform-wide max lag and max oldest-pending-age to
  `Letflow.Metrics.Registry`'s ETS table, and emits
  `ordering_lag_threshold_exceeded` events for any correlation whose lag
  exceeds the configured threshold (AC13–AC15).

  When `lags` is empty (no PENDING rows anywhere), writes `0` for max lag and
  `nil` for max age — `nil` distinguishes "no pending rows" from "fresh row
  at age 0" (AC14).
  """
  @spec write_to_registry(lags :: [lag_info()], opts :: keyword()) :: :ok
  def write_to_registry(lags, opts) do
    {max_lag, max_age} = compute_platform_maximums(lags)

    :ets.insert(@table, {{:gauge, :ordering_correlation_lag, %{}}, max_lag})
    :ets.insert(@table, {{:gauge, :ordering_oldest_pending_age_seconds, %{}}, max_age})

    threshold = lag_threshold()

    Enum.each(lags, fn %{correlation_id: cid, lag: lag, oldest_pending_age_seconds: age} ->
      if lag > threshold do
        emit_threshold_exceeded_event(cid, lag, age, opts)
      end
    end)

    :ok
  end

  defp compute_platform_maximums([]), do: {0, nil}

  defp compute_platform_maximums(lags) do
    max_lag = lags |> Enum.map(& &1.lag) |> Enum.max()

    max_age =
      lags
      |> Enum.map(& &1.oldest_pending_age_seconds)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        ages -> Enum.max(ages)
      end

    {max_lag, max_age}
  end

  defp emit_threshold_exceeded_event(correlation_id, lag, age, opts) do
    payload_json =
      Jason.encode!(%{
        "correlation_id" => correlation_id,
        "lag" => lag,
        "oldest_pending_age_seconds" => age
      })

    idempotency_key =
      "ordering_lag_exceeded:#{correlation_id}:#{System.os_time(:millisecond)}"

    EventStore.append_platform_event(
      %{
        instance_id: EventStore.platform_instance_id(),
        event_type: "ordering_lag_threshold_exceeded",
        actor_id: EventStore.platform_actor_id(),
        payload: payload_json,
        idempotency_key: idempotency_key
      },
      opts
    )

    :ok
  end

  defp lag_threshold do
    Application.get_env(:letflow, :ordering, [])
    |> Keyword.get(:lag_threshold, 10)
  end
end
