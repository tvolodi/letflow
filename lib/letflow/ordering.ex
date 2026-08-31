defmodule Letflow.Ordering do
  @moduledoc """
  Public context API for the correlated effect re-entry ordering subsystem
  (REQ-199, ORD-01/02/03/04). See
  `lib/letflow/design/req199-ordering.md` for the full design this module
  implements.

  ## ORD-04 deferral notice

  ORD-04's dynamic consumer-count reduction under contention is deliberately
  deferred and NOT implemented here. R-Co itself left this half unimplemented
  in production (its ordering subsystem was unwired — Letflow corrects that
  gap, but does not add the deferred reduction). The deferred half depends on
  REQ-194's metrics registry being established (which it now is), but the
  reduction algorithm itself (backoff heuristics, consumer-count configuration
  source) requires a separate design. See REQ-199's acceptance criterion 16
  for the exact scope boundary.

  ## Tenant scoping

  `tenant_id` is always derived from `opts[:prefix]`, never accepted from
  caller-supplied attrs — matching `Letflow.EventStore`, `Letflow.Dlq`, and
  every other tenant-scoped context module in this codebase.

  ## Connection pool discipline (AC10, GH-654/ISS-0649 fix)

  Each `run_cycle/2` call acquires a Repo connection at transaction open and
  releases it at commit or rollback. No connection is held across the poll
  sleep between tick invocations.
  """

  alias Letflow.Ordering.{Completion, Consumer, Metrics, Sweeper}
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type opts :: [prefix: String.t()]

  @type insert_error ::
          :invalid_schema_name
          | Ecto.Changeset.t()

  @type cycle_result ::
          :applied
          | :not_next
          | :lock_contention
          | :cursor_race
          | :no_pending
          | {:error, term()}

  @doc """
  Inserts a new `effect_completions` row. Idempotent: a conflict on
  `(correlation_id, sequence_no)` returns `{:ok, existing_row}` rather than
  an error (AC2). `tenant_id` is derived from `opts[:prefix]`, never accepted
  from attrs.
  """
  @spec insert_completion(
          attrs :: %{
            required(:correlation_id) => String.t(),
            required(:sequence_no) => non_neg_integer(),
            optional(:payload) => map(),
            optional(:received_at) => DateTime.t()
          },
          opts()
        ) :: {:ok, Completion.t()} | {:error, insert_error()}
  def insert_completion(attrs, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      insert_attrs = %Completion{
        tenant_id: tenant_id,
        correlation_id: Map.fetch!(attrs, :correlation_id),
        sequence_no: Map.fetch!(attrs, :sequence_no),
        payload: Map.get(attrs, :payload, %{}),
        received_at: Map.get(attrs, :received_at),
        status: :pending,
        created_at: now
      }

      case Repo.insert(insert_attrs,
             prefix: prefix,
             on_conflict: :nothing,
             conflict_target: [:correlation_id, :sequence_no]
           ) do
        {:ok, _} ->
          # Re-read to get actual DB row (on_conflict: :nothing may have been a no-op)
          correlation_id = Map.fetch!(attrs, :correlation_id)
          sequence_no = Map.fetch!(attrs, :sequence_no)

          case Repo.get_by(Completion, [correlation_id: correlation_id, sequence_no: sequence_no],
                 prefix: prefix
               ) do
            %Completion{} = existing -> {:ok, existing}
            nil -> {:error, :insert_failed}
          end

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Executes one claim-and-apply cycle for the given schema. Acquires and
  releases a database connection within this single call — never held across
  the poll sleep (AC10).
  """
  @spec run_cycle(schema_name :: String.t(), opts()) :: cycle_result()
  def run_cycle(_schema_name, opts) do
    case Consumer.claim(opts) do
      :no_pending -> :no_pending
      {:ok, completion} -> Consumer.try_apply(completion, opts)
    end
  end

  @doc """
  Runs the gap sweeper for the given schema. Moves PENDING rows whose
  predecessors have not arrived within `gap_timeout_seconds` to DEAD and
  writes one DLQ entry per correlation (AC8/AC9).
  """
  @spec sweep_gaps(schema_name :: String.t(), opts()) :: :ok
  def sweep_gaps(schema_name, opts) do
    Sweeper.run(schema_name, opts)
  end

  @doc """
  Computes per-correlation lag, writes platform-wide maximums to
  `Letflow.Metrics.Registry`, and emits lag-threshold-exceeded events for
  any correlation crossing the configured threshold (AC13–AC15).
  """
  @spec emit_lag_metrics(schema_name :: String.t(), opts()) :: :ok
  def emit_lag_metrics(_schema_name, opts) do
    lags = Metrics.compute_all_lags(opts)
    Metrics.write_to_registry(lags, opts)
    :ok
  end
end
