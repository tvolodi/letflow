defmodule Letflow.Ordering.Consumer do
  @moduledoc """
  Claim-and-apply cycle for `Letflow.Ordering` (ORD-01/02/03). See
  `lib/letflow/design/req199-ordering.md` §7 for the full transaction
  boundary definition this module implements.

  ## Advisory lock (ORD-02)

  `pg_try_advisory_xact_lock/1` serialises consumers on the same correlation
  without blocking consumers on different correlations. Key derivation:
  `:erlang.phash2(correlation_id, 2_147_483_647)` — stable 31-bit hash
  sufficient for expected tenant correlation counts at S6 stage. A collision
  (two different correlations hash to the same key) is safe: they serialise,
  not skip, so correctness is preserved (ORD-02; birthday probability ~50% at
  ~55k concurrent correlations — acceptable for S6).

  ## Connection pool discipline (AC10, GH-654/ISS-0649 fix)

  A Repo connection is acquired at `Repo.transaction/2` open and released at
  commit or rollback. No connection is held between `run_cycle/2` calls
  across the poll sleep.
  """

  import Ecto.Query

  alias Letflow.EventStore
  alias Letflow.Ordering.{Completion, Cursor}
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type claim_result ::
          {:ok, Completion.t()}
          | :no_pending

  @doc """
  Claims the lowest-sequence PENDING row with `FOR UPDATE SKIP LOCKED`,
  ordered by `(correlation_id, sequence_no)` (ORD-01). Returns `:no_pending`
  when the table is empty or all PENDING rows are locked by other consumers.
  """
  @spec claim(opts :: keyword()) :: claim_result()
  def claim(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    query =
      from(c in Completion,
        where: c.status == :pending,
        order_by: [asc: c.correlation_id, asc: c.sequence_no],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    Repo.transaction(fn ->
      case Repo.one(query, prefix: prefix) do
        nil -> Repo.rollback(:no_pending)
        %Completion{} = completion -> completion
      end
    end)
    |> case do
      {:ok, completion} -> {:ok, completion}
      {:error, :no_pending} -> :no_pending
    end
  end

  @doc """
  Executes the full M1–M9 claim-and-apply transaction for the given
  `completion` (design §7.1). All steps run inside ONE `Repo.transaction/2`
  call; no connection is held outside it.

  Returns:
  - `:applied` — committed successfully (AC3)
  - `:not_next` — `sequence_no != applied_seq + 1`, row stays PENDING (AC4)
  - `:lock_contention` — advisory lock held by another consumer (ORD-02)
  - `:cursor_race` — conditional cursor advance found 0 rows (AC5)
  - `{:error, term()}` — unexpected failure
  """
  @spec try_apply(completion :: Completion.t(), opts :: keyword()) ::
          :applied | :not_next | :lock_contention | :cursor_race | {:error, term()}
  def try_apply(%Completion{} = completion, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    Repo.transaction(fn ->
      # M1: re-lock the specific completion inside this transaction
      locked =
        from(c in Completion,
          where: c.completion_id == ^completion.completion_id and c.status == :pending,
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> Repo.one(prefix: prefix)

      case locked do
        nil ->
          # Another consumer applied or swept this row between claim and now
          Repo.rollback(:lock_contention)

        %Completion{} ->
          do_apply(completion, prefix, opts)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, :lock_contention} -> :lock_contention
      {:error, :not_next} -> :not_next
      {:error, :cursor_race} -> :cursor_race
      {:error, reason} -> {:error, reason}
    end
  end

  # Steps M2–M9 inside the open transaction.
  defp do_apply(%Completion{} = completion, prefix, opts) do
    # M2: advisory lock (ORD-02) — non-blocking; false → another consumer holds it
    lock_key = :erlang.phash2(completion.correlation_id, 2_147_483_647)

    %{rows: [[got_lock]]} =
      Repo.query!("SELECT pg_try_advisory_xact_lock($1::bigint)", [lock_key])

    unless got_lock do
      Repo.rollback(:lock_contention)
    end

    # M3: upsert-initialise cursor at applied_seq=0 if not exists
    {:ok, tenant_id} = TenantProvisioning.tenant_id_for_schema_name(prefix)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert(
      %Cursor{
        correlation_id: completion.correlation_id,
        tenant_id: tenant_id,
        applied_seq: 0,
        created_at: now,
        updated_at: now
      },
      prefix: prefix,
      on_conflict: :nothing,
      conflict_target: :correlation_id
    )

    # M4: read the actual cursor
    cursor = Repo.get!(Cursor, completion.correlation_id, prefix: prefix)

    # M5: strict order check — only apply if this is the exact next sequence
    if completion.sequence_no != cursor.applied_seq + 1 do
      Repo.rollback(:not_next)
    end

    # M6: append effect_applied platform event
    payload_json =
      Jason.encode!(%{
        "correlation_id" => completion.correlation_id,
        "sequence_no" => completion.sequence_no,
        "completion_id" => to_string(completion.completion_id)
      })

    case EventStore.append_platform_event(
           %{
             instance_id: EventStore.platform_instance_id(),
             event_type: "effect_applied",
             actor_id: EventStore.platform_actor_id(),
             payload: payload_json,
             idempotency_key: "effect_applied:" <> to_string(completion.completion_id)
           },
           opts
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    # M7: mark completion APPLIED
    applied_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.update_all(
           from(c in Completion,
             where: c.completion_id == ^completion.completion_id and c.status == :pending,
             update: [set: [status: :applied, applied_at: ^applied_at]]
           ),
           [],
           prefix: prefix
         ) do
      {1, _} -> :ok
      {_, _} -> Repo.rollback(:cursor_race)
    end

    # M8: conditional cursor advance — 0 rows means cursor was advanced by another consumer
    case Cursor.advance_conditional(completion.correlation_id, cursor.applied_seq, opts) do
      :ok -> :ok
      :race -> Repo.rollback(:cursor_race)
    end

    # M9: commit → :applied
    :applied
  end
end
