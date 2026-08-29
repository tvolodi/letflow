defmodule Letflow.Scheduler do
  @moduledoc """
  Context module for the `timers` table's SCH-01/02/05/06 lifecycle:
  `create/2` (arming) and the poll-and-fire machinery. See
  `lib/letflow/design/req186-scheduler-core.md` for the full design this
  module implements, and
  `lib/letflow/design/req185-scheduler-firing-architecture.md` for the
  architecture it is bound by (supervised `GenServer` ticker, no Oban,
  `FOR UPDATE SKIP LOCKED` claim, no startup-sweep lock, per-tenant-schema
  iteration, per-timer transaction isolation, exhausted timer →
  `dlq_entries` with `entry_type: "timer"`). Plain Ecto context module, no
  process — same shape as `Letflow.Dlq`/`Letflow.Tasks`.
  `Letflow.Scheduler.Poller` (a separate module) calls into this one; this
  module itself starts no processes and owns no state.

  ## Isolation mechanism (design §0, resolving REQ-185 §3's one open item)

  Each claimed timer fires inside its own `Repo.transaction/1`; a raise
  inside that function is caught by an explicit `try/rescue` before the
  transaction function returns, converting it to an `{:error, _}` tuple so
  `Repo.transaction/1`'s own rollback-on-`{:error, _}` contract applies —
  no process boundary is introduced (no new `Task.Supervisor`).

  ## `TIMER_FIRED`'s `actor_id` — flagged deviation from the design's literal text

  Design §2.4 step 5 / §6 states `actor_id: nil` for the `TIMER_FIRED`
  event append, reasoning that "no human/API actor initiates a timer
  firing." `Letflow.EventStore.append/2` itself, however, requires
  `attrs[:actor_id]` to cast via `Ecto.UUID.cast/1` (its own `fetch_uuid/3`
  helper returns `{:error, :missing_actor_id}` for `nil` — verified
  directly in `event_store.ex`) — a literal `nil` here would make every
  `fire_timer/2` call return `{:error, :missing_actor_id}` and never fire
  a single timer. `Letflow.EventStore.platform_actor_id/0` is this
  codebase's own already-established sentinel for exactly this "no human
  actor" case (`Letflow.EventStore.PlatformEvents`'s own moduledoc, point
  4: "`:actor_id` from the producer's own `event_attrs[:actor_id]` when
  present, else `EventStore.platform_actor_id()`") — used here instead of
  `nil`, without otherwise changing anything the design decided. Flagged
  for SECURITY-REVIEWER/REVIEWER, not silently substituted.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Dlq
  alias Letflow.EventStore
  alias Letflow.Repo
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantProvisioning

  @default_poll_interval_ms 5_000
  @default_jitter_ms 0
  @default_max_timers_per_cycle 64
  @default_max_fire_retries 3

  # ===========================================================================
  # create/2 -- SCH-01 arming (design §2.1)
  # ===========================================================================

  @type arm_attrs :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:timer_type) => String.t(),
          required(:node_id) => String.t(),
          required(:fire_at) => DateTime.t(),
          optional(:token_id) => Ecto.UUID.t() | nil,
          optional(:repeat_expression) => String.t() | nil,
          optional(:repeat_interval_us) => non_neg_integer() | nil,
          optional(:repeat_total) => pos_integer() | nil,
          optional(:fired_count) => non_neg_integer() | nil
        }

  @doc """
  Arms a new timer (design §2.1). Accepts either a caller-supplied
  `Ecto.Multi.t()` — appends one named `Ecto.Multi.insert/4` step and
  returns the extended `Multi.t()` **unexecuted** (this function never
  calls `Repo.transaction/1` and never touches `Repo` directly in this
  branch) — or a bare repo (`Letflow.Repo`), for a caller with no existing
  `Multi`, wrapping the same changeset in `Repo.insert/2` directly.

  `tenant_id` is derived from `opts[:prefix]`, never accepted from `attrs`.
  `id` is generated internally (`Ecto.UUID.generate/0`). `created_at` is
  set internally to the current UTC wall clock, microsecond-truncated.
  `status` is always forced to `"pending"`.
  """
  @spec create(
          multi_or_repo :: Ecto.Multi.t() | Ecto.Repo.t(),
          arm_attrs(),
          opts :: [prefix: String.t()]
        ) :: Ecto.Multi.t() | {:ok, Timer.t()} | {:error, Ecto.Changeset.t()}
  def create(%Multi{} = multi, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    changeset = build_arm_changeset(attrs, prefix)

    Multi.insert(multi, :scheduler_timer, changeset, prefix: prefix)
  end

  def create(Repo, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    changeset = build_arm_changeset(attrs, prefix)

    Repo.insert(changeset, prefix: prefix)
  end

  defp build_arm_changeset(attrs, prefix) do
    {:ok, tenant_id} = TenantProvisioning.tenant_id_for_schema_name(prefix)

    insert_attrs =
      attrs
      |> Map.take([
        :instance_id,
        :token_id,
        :timer_type,
        :node_id,
        :fire_at,
        :repeat_expression,
        :repeat_interval_us,
        :repeat_total,
        :fired_count
      ])
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        status: "pending",
        created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    Timer.arm_changeset(%Timer{}, insert_attrs)
  end

  # ===========================================================================
  # poll_and_fire/1 -- the tick entry point (design §2.2)
  # ===========================================================================

  @type poll_result :: %{
          tenant_schema: String.t(),
          claimed: non_neg_integer(),
          fired: non_neg_integer(),
          errored: non_neg_integer(),
          exhausted: non_neg_integer()
        }

  @doc """
  Called once per tenant schema per tick by `Letflow.Scheduler.Poller`
  (design §3), never by application code directly. Never raises — every
  per-timer failure is caught internally and folded into the returned
  counts (design §2.2, §2.5).
  """
  @spec poll_and_fire(tenant_schema :: String.t()) :: poll_result()
  def poll_and_fire(tenant_schema) when is_binary(tenant_schema) do
    timer_ids = claim_due_timer_ids(tenant_schema, max_timers_per_cycle())

    Enum.reduce(
      timer_ids,
      %{
        tenant_schema: tenant_schema,
        claimed: length(timer_ids),
        fired: 0,
        errored: 0,
        exhausted: 0
      },
      fn timer_id, acc ->
        case attempt_fire(timer_id, tenant_schema) do
          :fired -> %{acc | fired: acc.fired + 1}
          :already_final -> acc
          :errored -> %{acc | errored: acc.errored + 1}
          :exhausted -> %{acc | exhausted: acc.exhausted + 1}
        end
      end
    )
  end

  # ===========================================================================
  # claim_due_timer_ids/2 -- design §2.3
  # ===========================================================================

  @spec claim_due_timer_ids(tenant_schema :: String.t(), limit :: pos_integer()) :: [
          Ecto.UUID.t()
        ]
  def claim_due_timer_ids(tenant_schema, limit)
      when is_binary(tenant_schema) and is_integer(limit) and limit > 0 do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      Timer
      |> where([t], t.status == "pending" and t.fire_at <= ^now)
      |> order_by([t], asc: t.fire_at)
      |> limit(^limit)
      |> select([t], t.id)
      |> lock("FOR UPDATE SKIP LOCKED")

    Repo.all(query, prefix: tenant_schema)
  end

  # ===========================================================================
  # fire_timer/2 -- one timer, one transaction (design §2.4)
  # ===========================================================================

  @spec fire_timer(timer_id :: Ecto.UUID.t(), tenant_schema :: String.t()) ::
          {:ok, :fired} | {:ok, :already_final} | {:error, term()}
  def fire_timer(timer_id, tenant_schema) when is_binary(tenant_schema) do
    Repo.transaction(fn ->
      case fetch_and_lock_timer(timer_id, tenant_schema) do
        nil ->
          {:ok, :already_final}

        %Timer{status: status} when status != "pending" ->
          {:ok, :already_final}

        %Timer{} = timer ->
          do_fire(timer, tenant_schema)
      end
      |> case do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp do_fire(%Timer{} = timer, tenant_schema) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fired_late = DateTime.compare(now, timer.fire_at) == :gt

    with {:ok, _updated} <-
           timer
           |> Timer.fire_changeset(%{status: "fired", fired_at: now})
           |> Repo.update(prefix: tenant_schema),
         {:ok, _append_result} <-
           append_timer_fired_event(timer, now, fired_late, tenant_schema),
         # REQ-187 design doc §7.1 -- the poller's fire path re-entering the
         # engine to advance the token off the :TIMER node, still inside
         # this same Repo.transaction/1 fire_timer/2 already opened (Ecto
         # nests advance_after_timer_fired/3's own internal Multi as a real
         # Postgres SAVEPOINT here). `Repo` is Letflow.Repo itself -- the
         # literal repo module, not an Ecto.Multi-injected one, since this
         # call is an ordinary sequential call inside an already-open
         # transaction function, not a Multi.run/3 callback.
         {:ok, :advanced} <-
           Letflow.Engine.advance_after_timer_fired(timer, Repo, tenant_schema) do
      {:ok, :fired}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_timer_fired_event(%Timer{} = timer, now, fired_late, tenant_schema) do
    payload =
      Jason.encode!(%{
        timer_id: timer.id,
        node_id: timer.node_id,
        timer_type: timer.timer_type,
        fired_late: fired_late,
        scheduled_fire_at: DateTime.to_iso8601(timer.fire_at),
        actual_fired_at: DateTime.to_iso8601(now)
      })

    event_attrs = %{
      instance_id: timer.instance_id,
      event_type: "TIMER_FIRED",
      payload: payload,
      actor_id: EventStore.platform_actor_id(),
      idempotency_key: "timer_fired:#{timer.id}"
    }

    EventStore.append(event_attrs, prefix: tenant_schema)
  end

  defp fetch_and_lock_timer(timer_id, tenant_schema) do
    Timer
    |> where([t], t.id == ^timer_id)
    |> lock("FOR UPDATE")
    |> Repo.one(prefix: tenant_schema)
  end

  # ===========================================================================
  # attempt_fire/2 -- failure accounting, ISS-303/ISS-0618 (design §2.5)
  # ===========================================================================

  @spec attempt_fire(timer_id :: Ecto.UUID.t(), tenant_schema :: String.t()) ::
          :fired | :already_final | :errored | :exhausted
  def attempt_fire(timer_id, tenant_schema) when is_binary(tenant_schema) do
    result =
      try do
        fire_timer(timer_id, tenant_schema)
      rescue
        exception -> {:error, {:raised, exception}}
      end

    case result do
      {:ok, :fired} -> :fired
      {:ok, :already_final} -> :already_final
      # REQ-187 design doc §7.2 -- a real SCH-03 race (the instance became
      # terminal via a concurrent cancel_instance/3/completion between this
      # timer's own claim and advance_after_timer_fired/3's own
      # instance_projections lock+check) is not a firing failure -- matched
      # BEFORE the generic {:error, _reason} catch-all below so it never
      # wrongly increments fire_error_count / eventually lands the timer in
      # dlq_entries.
      {:error, {:instance_not_active, _status}} -> :already_final
      {:error, _reason} -> safe_record_fire_failure(timer_id, tenant_schema)
    end
  end

  # Guards the separate failure-accounting transaction (design §2.5 step 3)
  # the same way attempt_fire/2's own outer try/rescue guards fire_timer/2:
  # a raise here (e.g. a constraint violation on the retry-increment update,
  # or Letflow.Dlq.enqueue/2 itself raising) must not propagate out of
  # poll_and_fire/1's per-tenant loop -- acceptance criterion 6's "remaining
  # due timers in the same poll cycle are still attempted" depends on this
  # function never raising, exactly as it depends on fire_timer/2 never
  # raising.
  defp safe_record_fire_failure(timer_id, tenant_schema) do
    record_fire_failure(timer_id, tenant_schema)
  rescue
    _exception -> :errored
  end

  defp record_fire_failure(timer_id, tenant_schema) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      case fetch_and_lock_timer(timer_id, tenant_schema) do
        nil ->
          :already_final

        %Timer{} = timer ->
          new_count = timer.fire_error_count + 1

          {:ok, updated_timer} =
            timer
            |> Timer.retry_increment_changeset(%{fire_error_count: new_count})
            |> Repo.update(prefix: tenant_schema)

          if new_count >= max_fire_retries() do
            land_exhausted_timer(updated_timer, now, tenant_schema)
            :exhausted
          else
            :errored
          end
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, _reason} -> :errored
    end
  end

  defp land_exhausted_timer(%Timer{} = timer, now, tenant_schema) do
    {:ok, _updated} =
      timer
      |> Timer.fail_changeset(%{status: "failed", failed_at: now})
      |> Repo.update(prefix: tenant_schema)

    dlq_attrs = %{
      entry_type: "timer",
      instance_id: timer.instance_id,
      reference_id: timer.id,
      reason: "Timer #{timer.node_id} exhausted #{max_fire_retries()} fire attempts",
      error_detail: %{
        "timer_id" => timer.id,
        "node_id" => timer.node_id,
        "timer_type" => timer.timer_type,
        "fire_at" => DateTime.to_iso8601(timer.fire_at),
        "fire_error_count" => timer.fire_error_count
      },
      first_failed_at: now,
      last_failed_at: now
    }

    {:ok, _entry} = Dlq.enqueue(dlq_attrs, prefix: tenant_schema)

    :ok
  end

  # ===========================================================================
  # Configuration (design §7)
  # ===========================================================================

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    scheduler_config()[:poll_interval_ms] || @default_poll_interval_ms
  end

  @spec jitter_ms() :: non_neg_integer()
  def jitter_ms do
    scheduler_config()[:jitter_ms] || @default_jitter_ms
  end

  @spec max_timers_per_cycle() :: pos_integer()
  def max_timers_per_cycle do
    scheduler_config()[:max_timers_per_cycle] || @default_max_timers_per_cycle
  end

  @spec max_fire_retries() :: pos_integer()
  def max_fire_retries do
    scheduler_config()[:max_fire_retries] || @default_max_fire_retries
  end

  defp scheduler_config, do: Application.get_env(:letflow, :scheduler, [])
end
