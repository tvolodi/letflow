defmodule Letflow.Engine.ExecutionError do
  @moduledoc """
  EE-10 (REQ-061) — execution error handling. Ports `instance.zig`'s
  `setInstanceError()` (R-Co `instance.zig:3078`, `SetInstanceErrorArgs`
  `instance.zig:289`). Verified directly against R-Co's source (GH#328,
  ISS-0100, 2026-08-20) — field shape matches (§0 of the design doc); the
  `error_type()` union here is deliberately **open**, unlike R-Co's own
  closed 10-variant `ErrorType` enum, because this port collapses R-Co's
  `SUB_PROCESS_*` four variants into one `:subprocess_interface_violation`
  atom pending REQ-062 (design doc §2, §12 OQ-2) — see
  `lib/letflow/design/req061-execution-error-handling.md` §0/§2/§12 OQ-1 for
  the full comparison. This module is **the single, shared path every
  engine-internal failure funnels into** — the one place the
  `instance_projections.status: :error` write, the `EXECUTION_ERROR` event
  append, and the eligibility check are implemented.

  `append_multi/3` matches `Letflow.Engine.TaskActivation`'s own
  `append_multi_from_existing_records/6` composable shape exactly (its own
  INV-EE47-7, copied here as INV-EE61-7): **zero `Repo` calls of its own** —
  every step it appends runs inside the *caller's* already-open
  `Ecto.Multi`/transaction. This module opens no transaction itself.

  ## SCOPE BOUNDARY — OBS-05 dead-letter queue (S6), not built here

  An instance that reaches `ERROR` via this module stays in `ERROR` until an
  **operator** action moves it out — retry (re-attempt the failed step) or
  discard (abandon the instance). That operator action is R-Co's OBS-05
  dead-letter API (`src/dlq/`, S6 operational-cross-cutting, plus S4's own
  route layer to expose it over HTTP) — **neither exists in Letflow yet, and
  this module builds no partial version of either.** No retry-queue table, no
  discard endpoint, no background sweep of `ERROR`-status instances is
  introduced here. The one hook this module leaves for that future work:
  `instance_projections.status == :error` plus its `error_detail` column *is*
  the durable record OBS-05's future dead-letter listing/read path will
  query — no additional table is needed for S6 to find every `ERROR`-halted
  instance once it exists.

  ## `ERROR` is explicitly NOT terminal, unlike `CANCELLED` and `COMPLETED`

  `Letflow.EventStore.InstanceProjection.terminal?/1` (already shipped,
  REQ-023/043) already encodes this — `true` only for
  `:completed`/`:cancelled`, `false` for both `:active` and `:error` — so
  `Letflow.EventStore.append/2`'s own active-instance guard does **not**
  reject a further append attempt against an `ERROR` instance purely because
  of its status. `Letflow.Engine.complete_task/3`'s own `M2` still rejects
  task completion against an `:error` instance for its own, distinct reason
  (a genuine, typed conflict — `{:error, {:instance_not_active, :error}}`,
  already shipped REQ-048 behavior) — that is that call's own business rule,
  not the event store's terminal-state guard. An operator action (once S6
  lands) can still move an instance out of `ERROR`, which is precisely why
  `ERROR` is a fourth, distinct value in REQ-023's status enum rather than
  folded into `CANCELLED`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection

  @typedoc """
  A closed-looking but explicitly **open** union (the trailing `atom()` is
  deliberate, not a typo) — mirrors R-Co's own error-code table being a
  mapping, not a hardcoded case statement. The five named atoms map 1:1 onto
  this requirement's five calling paths (REQ-049, REQ-050, REQ-056, REQ-057,
  REQ-062).
  """
  @type error_type ::
          :variable_schema_rejected
          | :no_matching_gateway_edge
          | :service_task_retries_exhausted
          | :plugin_error_outcome
          | :subprocess_interface_violation
          | atom()

  @typedoc "AC1's 'affected node or field', a two-member tagged union."
  @type affected ::
          {:node, node_id :: String.t()}
          | {:field, field :: String.t()}

  @typedoc """
  The full payload a caller assembles before invoking `append_multi/3` (or
  `Letflow.Engine.set_instance_error/2`). `reason` and `details` are built by
  the caller, not by this module — this module renders no strings of its
  own, it only persists what it is handed. `actor_id`/`idempotency_key` are
  required, not defaulted by this module.
  """
  @type error_args :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:error_type) => error_type(),
          required(:affected) => affected(),
          required(:reason) => String.t(),
          required(:variables) => map(),
          optional(:details) => map(),
          required(:actor_id) => Ecto.UUID.t() | nil,
          required(:idempotency_key) => String.t()
        }

  @type eligibility_error ::
          {:error, {:instance_not_found}}
          | {:error, {:instance_already_error, error_detail :: map()}}
          | {:error, {:instance_terminal, status :: :completed | :cancelled}}

  @doc """
  Appends the EE-10 `ERROR`-transition steps onto `multi` — the shared,
  composable sink every engine-internal failure funnels into
  (`lib/letflow/design/req061-execution-error-handling.md` §3). Steps
  appended, in order:

    * `:execution_error_projection_lock` (only appended when
      `opts[:locked_projection]` is `nil`) — row-locks and fetches
      `instance_projections` by `error_args.instance_id`.
    * `:execution_error_eligibility` — pure check against the locked/passed-in
      projection: `:completed`/`:cancelled` -> `{:error, {:instance_terminal,
      status}}`; already `:error` -> `{:error, {:instance_already_error,
      error_detail}}` (AC5's own conflict shape, the mechanism the row-lock
      queueing establishes); `:active` -> proceeds.
    * `:execution_error_event` — `Letflow.EventStore.append/2`, one
      `EXECUTION_ERROR` event built from `error_args`. Runs **before** the
      projection update, matching `req052`'s own M6-before-M7 ordering
      rationale.
    * `:execution_error_projection_update` — `InstanceProjection.update_changeset/2`
      (reused unchanged) with `%{status: :error, error_detail: <compact
      detail map>}`.

  `opts[:locked_projection]`: when the caller already holds a `SELECT ... FOR
  UPDATE` lock on this instance's `instance_projections` row within the
  *same* transaction, pass the already-fetched struct here to avoid a second,
  redundant lock/fetch. When absent (the default), this function performs its
  own lock+fetch as its first appended step.

  Every write happens inside the *caller's* already-open `Ecto.Multi` — this
  function calls `Repo.transaction/1` nowhere in its own body (INV-EE61-7).
  """
  @spec append_multi(
          Multi.t(),
          error_args :: error_args(),
          opts :: [prefix: String.t(), locked_projection: InstanceProjection.t() | nil]
        ) :: Multi.t()
  def append_multi(%Multi{} = multi, error_args, opts)
      when is_map(error_args) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)
    locked_projection = Keyword.get(opts, :locked_projection)

    multi
    |> maybe_lock_projection(error_args.instance_id, prefix, locked_projection)
    |> Multi.run(:execution_error_eligibility, fn _repo, changes ->
      check_eligibility(
        locked_projection || Map.fetch!(changes, :execution_error_projection_lock)
      )
    end)
    |> Multi.run(:execution_error_event, fn _repo, _changes ->
      append_execution_error_event(error_args, prefix)
    end)
    |> Multi.run(:execution_error_projection_update, fn repo, changes ->
      update_projection_to_error(repo, changes.execution_error_eligibility, error_args, prefix)
    end)
  end

  defp maybe_lock_projection(%Multi{} = multi, _instance_id, _prefix, %InstanceProjection{}) do
    multi
  end

  defp maybe_lock_projection(%Multi{} = multi, instance_id, prefix, nil) do
    Multi.run(multi, :execution_error_projection_lock, fn repo, _changes ->
      fetch_and_lock_projection(repo, instance_id, prefix)
    end)
  end

  # Same lock/fetch shape as complete_task/3's own M2
  # (fetch_and_lock_instance_projection/3) and cancel_instance/3's own M2
  # (fetch_and_lock_instance_projection_for_cancel/3) -- Ecto's lock/2 query
  # composition, never a hand-written SQL string (INV-7).
  defp fetch_and_lock_projection(repo, instance_id, prefix) do
    InstanceProjection
    |> where([p], p.instance_id == ^instance_id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil -> {:error, {:instance_not_found}}
      %InstanceProjection{} = projection -> {:ok, projection}
    end
  end

  @spec check_eligibility(InstanceProjection.t()) ::
          {:ok, InstanceProjection.t()} | eligibility_error()
  defp check_eligibility(%InstanceProjection{status: status} = projection) do
    cond do
      status in [:completed, :cancelled] -> {:error, {:instance_terminal, status}}
      status == :error -> {:error, {:instance_already_error, projection.error_detail}}
      true -> {:ok, projection}
    end
  end

  # AC1's four mandatory fields (error_type, affected, reason, variables),
  # all read back verbatim from this one event's payload
  # (lib/letflow/design/req061-execution-error-handling.md §9).
  defp append_execution_error_event(error_args, prefix) do
    payload =
      Jason.encode!(%{
        error_type: to_string(error_args.error_type),
        affected: encode_affected(error_args.affected),
        reason: error_args.reason,
        variables: error_args.variables,
        details: Map.get(error_args, :details, %{})
      })

    event_attrs = %{
      instance_id: error_args.instance_id,
      event_type: "EXECUTION_ERROR",
      payload: payload,
      actor_id: error_args.actor_id,
      idempotency_key: error_args.idempotency_key
    }

    case EventStore.append(event_attrs, prefix: prefix) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:event_append_failed, reason}}
    end
  end

  # error_detail (design doc §8) deliberately excludes the variable-map
  # snapshot -- that lives in the EXECUTION_ERROR event's own payload above,
  # the durable, append-only audit record. error_detail is a current-state
  # summary column only.
  defp update_projection_to_error(repo, %InstanceProjection{} = projection, error_args, prefix) do
    error_detail = %{
      "error_type" => to_string(error_args.error_type),
      "affected" => encode_affected(error_args.affected),
      "reason" => error_args.reason,
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "details" => Map.get(error_args, :details, %{})
    }

    projection
    |> InstanceProjection.update_changeset(%{status: :error, error_detail: error_detail})
    |> repo.update(prefix: prefix)
  end

  defp encode_affected({:node, node_id}), do: %{"kind" => "node", "node_id" => node_id}
  defp encode_affected({:field, field}), do: %{"kind" => "field", "key" => field}
end
