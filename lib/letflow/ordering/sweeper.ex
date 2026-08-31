defmodule Letflow.Ordering.Sweeper do
  @moduledoc """
  Gap sweeper for `Letflow.Ordering` (ORD-02 timeout path). See
  `lib/letflow/design/req199-ordering.md` §8 for the full algorithm.

  A correlation is sweep-eligible if AND ONLY IF:
  1. It has at least one `PENDING` row.
  2. Its lowest `sequence_no` among PENDING rows is **strictly greater than**
     `cursor.applied_seq + 1` (not merely `>=` — AC8 explicit test).
  3. The oldest PENDING row in that correlation is older than
     `gap_timeout_seconds` seconds.

  For each eligible correlation, in one transaction: all PENDING rows are
  moved to `DEAD` and exactly one DLQ entry is written naming all unapplied
  sequence numbers (AC8). If the DLQ write fails, the whole transaction rolls
  back — no DEAD rows are committed without a corresponding DLQ entry.
  """

  alias Letflow.Dlq
  alias Letflow.Repo

  @doc """
  Runs the gap sweeper for one schema. Called by
  `Letflow.Scheduler.Poller` via `maybe_run_ordering_sweeper/1`.
  """
  @spec run(schema_name :: String.t(), opts :: keyword()) :: :ok
  def run(schema_name, opts) do
    gap_timeout = gap_timeout_seconds()
    eligible = find_eligible_correlations(schema_name, opts, gap_timeout)
    Enum.each(eligible, &sweep_correlation(&1, opts))
    :ok
  end

  # Finds correlations where min_pending_seq > applied_seq + 1 AND oldest
  # PENDING row is older than gap_timeout_seconds. A missing cursor row is
  # treated as applied_seq = 0 (consistent with M3 upsert-init).
  defp find_eligible_correlations(schema_name, opts, gap_timeout) do
    prefix = Keyword.fetch!(opts, :prefix)

    sql = """
    SELECT
      ec.correlation_id,
      MIN(ec.sequence_no) AS min_pending_seq,
      COALESCE(cc.applied_seq, 0) AS applied_seq,
      EXTRACT(EPOCH FROM (now() - MIN(ec.created_at)))::bigint AS oldest_age_seconds
    FROM "#{schema_name}".effect_completions ec
    LEFT JOIN "#{schema_name}".correlation_cursors cc USING (correlation_id)
    WHERE ec.status = 'PENDING'
    GROUP BY ec.correlation_id, cc.applied_seq
    HAVING MIN(ec.sequence_no) > COALESCE(cc.applied_seq, 0) + 1
       AND EXTRACT(EPOCH FROM (now() - MIN(ec.created_at))) > $1
    """

    case Repo.query(sql, [gap_timeout], prefix: prefix) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [correlation_id, min_seq, applied_seq, oldest_age] ->
          %{
            correlation_id: correlation_id,
            min_pending_seq: min_seq,
            applied_seq: applied_seq,
            oldest_age_seconds: oldest_age
          }
        end)

      {:error, _} ->
        []
    end
  end

  # In one transaction: mark all PENDING rows DEAD, collect sequence_nos,
  # enqueue one DLQ entry. Rolls back entirely if DLQ enqueue fails.
  defp sweep_correlation(
         %{
           correlation_id: correlation_id,
           applied_seq: applied_seq,
           oldest_age_seconds: oldest_age
         },
         opts
       ) do
    prefix = Keyword.fetch!(opts, :prefix)

    Repo.transaction(fn ->
      # UPDATE all PENDING rows to DEAD, collect sequence_nos via RETURNING
      sql = """
      UPDATE "#{prefix}".effect_completions
      SET status = 'DEAD'
      WHERE correlation_id = $1 AND status = 'PENDING'
      RETURNING sequence_no
      """

      case Repo.query!(sql, [correlation_id]) do
        %{rows: rows} when rows != [] ->
          unapplied_sequence_numbers = rows |> List.flatten() |> Enum.sort()

          dlq_attrs = %{
            entry_type: "ordering_gap",
            reference_id: correlation_id,
            reason: "gap timeout — no predecessor",
            context_json: %{
              "correlation_id" => correlation_id,
              "unapplied_sequence_numbers" => unapplied_sequence_numbers,
              "applied_seq" => applied_seq,
              "oldest_pending_age_seconds" => oldest_age
            }
          }

          case Dlq.enqueue(dlq_attrs, opts) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

        %{rows: []} ->
          # Nothing to sweep (rows may have been applied concurrently)
          :ok
      end
    end)

    :ok
  end

  defp gap_timeout_seconds do
    Application.get_env(:letflow, :ordering, [])
    |> Keyword.get(:gap_timeout_seconds, 300)
  end
end
