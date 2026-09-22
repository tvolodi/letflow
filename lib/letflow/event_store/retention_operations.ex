defmodule Letflow.EventStore.RetentionOperations do
  @moduledoc """
  Context module for REQ-377's operator-facing history-retirement screen.
  See `lib/letflow/design/req377-history-retirement-screen.md` §2.1 for the
  full design this module implements.

  ## Process-vs-row decision (design doc §1, mirrors REQ-045 / `Letflow.Engine`
  / `Letflow.Platform.MigrationRollout`)

  A plain transactional context module -- no `gen_statem`, no supervised
  per-operation process. This is a plain async job progressing to
  completion, not a named-state workflow with caller-driven transitions.
  `retire_oldest_eligible_month/1` inserts one durable
  `event_history_retirements` row (the source of truth a second `GET` from
  a different request/process can observe), then dispatches the actual
  fanout work via `Task.Supervisor.async_nolink/3` under the dedicated
  `Letflow.EventStore.RetirementTaskSupervisor` -- not a supervised
  per-operation process, matching
  `Letflow.Platform.MigrationRollout`'s own "DB row is the source of truth"
  precedent (REQ-045's Process-vs-row decision applied the same way again).

  ## Why async (design doc §1)

  `Letflow.EventStore.PartitionMaintenance.retire_month/3`'s
  `ensure_bounds_constraint!/5` step is a full sequential scan of the
  retiring partition's every row, run once per eligible tenant schema. The
  fanout's total cost is unbounded by this design and grows linearly with
  tenant-schema count -- not a shape a synchronous `POST` can safely absorb.
  `retire_oldest_eligible_month/1` returns as soon as the
  `event_history_retirements` row is inserted, before the fanout runs; the
  fanout itself runs out-of-band, tracked by that row plus its
  `event_history_retirement_outcomes` children, polled via
  `retirement_status/1`.

  ## One shared derivation of "oldest eligible month" (design doc §2.1, OQ5)

  `retention_summary/0` and `retire_oldest_eligible_month/1` both call
  `oldest_eligible_month_platform_wide/0` -- there is exactly one code path
  that computes "oldest eligible month across every tenant schema," so the
  two call sites cannot diverge.

  ## Failure isolation (mirrors `Letflow.Platform.MigrationRollout` §5)

  `run_retirement/3` iterates tenant schemas independently via
  `Task.Supervisor.async_stream/4` -- one tenant schema's failure cannot
  block or roll back a sibling schema's already-committed retirement. A
  schema where the target month is already retired, or has aged out of
  eligibility between the summary computation and this run, is recorded
  `"skipped"`, not `"failed"` -- an expected, benign outcome, the same
  tolerance `MigrationRollout` already established for its own
  `already_current` case.

  ## Permission decision

  Reuses the existing `:TenantsManage` permission
  (`Letflow.Api.Authorization`), not a new one -- see
  `Letflow.Routers.EventRetention`'s own moduledoc for the full reasoning.
  """

  import Ecto.Query

  require Logger

  alias Letflow.EventStore.EventHistoryRetirement
  alias Letflow.EventStore.EventHistoryRetirementOutcome
  alias Letflow.EventStore.PartitionMaintenance
  alias Letflow.EventStore.RetentionPolicy
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.Registration

  @type retirement_status :: :running | :completed | :failed

  @type tenant_outcome :: %{
          tenant_id: Ecto.UUID.t(),
          schema_name: String.t(),
          status: :succeeded | :skipped | :failed,
          retired_partition: String.t() | nil,
          protected_rows_relocated: non_neg_integer() | nil,
          resumed_from: PartitionMaintenance.resumed_from() | nil,
          reason: String.t() | nil,
          completed_at: NaiveDateTime.t() | nil
        }

  @type retirement :: %{
          id: Ecto.UUID.t(),
          year: pos_integer() | nil,
          month: 1..12 | nil,
          status: retirement_status(),
          requested_by: Ecto.UUID.t(),
          started_at: NaiveDateTime.t(),
          completed_at: NaiveDateTime.t() | nil
        }

  @type retirement_result :: %{retirement: retirement(), outcomes: [tenant_outcome()]}

  @doc """
  Platform-wide retention summary: the oldest eligible-to-retire month
  (across every provisioned tenant schema), the platform-wide
  `keep_forever`-policy protected-record count, and the number of
  provisioned tenant schemas. Read-only.
  """
  @spec retention_summary() ::
          {:ok,
           %{
             oldest_eligible_month: %{year: pos_integer(), month: 1..12} | nil,
             protected_record_count: non_neg_integer(),
             tenant_schema_count: non_neg_integer(),
             computed_at: NaiveDateTime.t()
           }}
  def retention_summary do
    schemas = provisioned_tenant_schemas()

    oldest =
      case oldest_eligible_month_platform_wide(schemas) do
        {year, month} -> %{year: year, month: month}
        nil -> nil
      end

    {:ok,
     %{
       oldest_eligible_month: oldest,
       protected_record_count: platform_wide_protected_record_count(schemas),
       tenant_schema_count: length(schemas),
       computed_at: naive_now()
     }}
  end

  @doc """
  Computes the platform-wide oldest eligible month (via
  `oldest_eligible_month_platform_wide/0`) and, if one exists, inserts one
  `event_history_retirements` row (`status: "running"`) and dispatches the
  per-tenant-schema fanout asynchronously via
  `Task.Supervisor.async_nolink/3` under
  `Letflow.EventStore.RetirementTaskSupervisor`. Returns as soon as the row
  is inserted -- the fanout itself has not necessarily completed by the
  time this returns; poll `retirement_status/1` for progress.
  """
  @spec retire_oldest_eligible_month(requested_by :: Ecto.UUID.t()) ::
          {:ok, retirement()} | {:error, :no_eligible_month}
  def retire_oldest_eligible_month(requested_by) do
    schemas = provisioned_tenant_schemas()

    case oldest_eligible_month_platform_wide(schemas) do
      nil ->
        {:error, :no_eligible_month}

      {year, month} ->
        attrs = %{
          year: year,
          month: month,
          status: "running",
          requested_by: requested_by,
          started_at: naive_now()
        }

        {:ok, retirement} =
          Repo.insert(EventHistoryRetirement.changeset(%EventHistoryRetirement{}, attrs))

        Task.Supervisor.async_nolink(Letflow.EventStore.RetirementTaskSupervisor, fn ->
          run_retirement(retirement.id, year, month, schemas)
        end)

        {:ok, retirement_map(retirement)}
    end
  end

  @doc """
  Pure read: the `event_history_retirements` row plus every
  `event_history_retirement_outcomes` row for it, ordered by `tenant_id`
  (stable ordering for the screen and for tests) -- this is what the
  frontend polls.
  """
  @spec retirement_status(id :: Ecto.UUID.t()) ::
          {:ok, retirement_result()} | {:error, :retirement_not_found}
  def retirement_status(id) do
    case Repo.get(EventHistoryRetirement, id) do
      nil -> {:error, :retirement_not_found}
      %EventHistoryRetirement{} = retirement -> {:ok, build_retirement_result(retirement)}
    end
  end

  # ---------------------------------------------------------------------
  # run_retirement/4 -- runs inside the spawned Task (design §2.1)
  # ---------------------------------------------------------------------

  defp run_retirement(retirement_id, year, month, schemas) do
    max_concurrency = Letflow.Admission.global_cap()

    Letflow.EventStore.RetirementTaskSupervisor
    |> Task.Supervisor.async_stream(
      schemas,
      fn {tenant_id, schema_name} ->
        retire_one_schema(retirement_id, tenant_id, schema_name, year, month)
      end,
      max_concurrency: max_concurrency,
      timeout: :infinity,
      on_timeout: :kill_task
    )
    |> Stream.run()

    Repo.update!(
      EventHistoryRetirement.changeset(Repo.get!(EventHistoryRetirement, retirement_id), %{
        status: "completed",
        completed_at: naive_now()
      })
    )

    :ok
  rescue
    error ->
      # A crash inside this task's own orchestration (not an individual
      # schema's error, which retire_one_schema/5 already catches) --
      # never left stuck at "running" forever. async_nolink means this
      # rescue clause runs in THIS task, so the crash never propagates to
      # the caller or to RetirementTaskSupervisor itself; logged (mirroring
      # Letflow.Scheduler.Poller's own log_task_raise/4 precedent for an
      # isolated async-task crash) rather than reraised.
      Repo.update!(
        EventHistoryRetirement.changeset(Repo.get!(EventHistoryRetirement, retirement_id), %{
          status: "failed",
          completed_at: naive_now()
        })
      )

      Logger.warning("event history retirement task raised, marked failed",
        retirement_id: retirement_id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  defp retire_one_schema(retirement_id, tenant_id, schema_name, year, month) do
    outcome_attrs = %{
      retirement_id: retirement_id,
      tenant_id: tenant_id,
      status: "pending"
    }

    case PartitionMaintenance.retire_month(schema_name, year, month) do
      {:ok, result} ->
        insert_outcome!(outcome_attrs, %{
          status: "succeeded",
          retired_partition: result.retired_partition,
          protected_rows_relocated: result.protected_rows_relocated,
          resumed_from: to_string(result.resumed_from),
          completed_at: naive_now()
        })

      {:error, reason} when reason in [:partition_not_eligible, :partition_not_found] ->
        insert_outcome!(outcome_attrs, %{
          status: "skipped",
          reason: describe_skip_reason(reason),
          completed_at: naive_now()
        })

      {:error, other} ->
        insert_outcome!(outcome_attrs, %{
          status: "failed",
          reason: inspect(other),
          completed_at: naive_now()
        })
    end
  rescue
    error ->
      insert_outcome!(
        %{retirement_id: retirement_id, tenant_id: tenant_id, status: "pending"},
        %{status: "failed", reason: inspect(error), completed_at: naive_now()}
      )
  end

  defp insert_outcome!(base_attrs, result_attrs) do
    attrs = Map.merge(base_attrs, result_attrs)

    Repo.insert!(EventHistoryRetirementOutcome.changeset(%EventHistoryRetirementOutcome{}, attrs))

    :ok
  end

  defp describe_skip_reason(:partition_not_eligible),
    do: "This month is not yet old enough to retire for this workspace."

  defp describe_skip_reason(:partition_not_found),
    do: "This workspace does not hold this month of event history."

  # ---------------------------------------------------------------------
  # oldest_eligible_month_platform_wide/1 (design §2.1, OQ5) -- the ONE
  # shared derivation retention_summary/0 and retire_oldest_eligible_month/1
  # both call.
  # ---------------------------------------------------------------------

  @spec oldest_eligible_month_platform_wide([{Ecto.UUID.t(), String.t()}]) ::
          {pos_integer(), 1..12} | nil
  defp oldest_eligible_month_platform_wide(schemas) do
    schemas
    |> Enum.map(fn {_tenant_id, schema_name} ->
      PartitionMaintenance.eligible_months(schema_name)
    end)
    |> Enum.map(&List.first/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  # ---------------------------------------------------------------------
  # provisioned_tenant_schemas/0 -- same predicate as
  # Letflow.Scheduler.Poller.tenant_schemas/0, generalized to also select
  # tenant_id (needed to attribute each outcome row).
  # ---------------------------------------------------------------------

  @spec provisioned_tenant_schemas() :: [{Ecto.UUID.t(), String.t()}]
  defp provisioned_tenant_schemas do
    Registration
    |> where([r], not is_nil(r.migrations_applied_at))
    |> select([r], {r.tenant_id, r.schema_name})
    |> Repo.all()
  end

  # ---------------------------------------------------------------------
  # platform_wide_protected_record_count/1 (design §2.1 retention_summary/0)
  # -- one Repo.query!/2 per schema per table, since Postgres has no
  # cross-schema wildcard FROM; mirrors
  # PartitionMaintenance's own count_protected_rows/2 per-schema,
  # per-table query shape, generalized here to the whole `events`/
  # `events_archive` hierarchy rather than one partition.
  # ---------------------------------------------------------------------

  defp platform_wide_protected_record_count(schemas) do
    keep_forever_types = keep_forever_event_types()

    if keep_forever_types == [] do
      0
    else
      schemas
      |> Enum.map(fn {_tenant_id, schema_name} ->
        count_protected_rows_in_schema(schema_name, "events", keep_forever_types) +
          count_protected_rows_in_schema(schema_name, "events_archive", keep_forever_types)
      end)
      |> Enum.sum()
    end
  end

  defp count_protected_rows_in_schema(schema_name, table, keep_forever_types) do
    %Postgrex.Result{rows: [[count]]} =
      Repo.query!(
        ~s{SELECT count(*) FROM "#{schema_name}"."#{table}" WHERE event_type = ANY($1)},
        [keep_forever_types]
      )

    count
  end

  defp keep_forever_event_types do
    RetentionPolicy
    |> where([p], p.policy == :keep_forever)
    |> select([p], p.event_type)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------
  # Result-shaping helpers
  # ---------------------------------------------------------------------

  defp build_retirement_result(%EventHistoryRetirement{} = retirement) do
    # LEFT JOIN, not an inner join: a tenant_schemas row could in principle
    # be deleted after this outcome was recorded -- an outcome must still
    # render (schema_name: nil) rather than silently vanish from the
    # report.
    outcomes =
      from(o in EventHistoryRetirementOutcome,
        left_join: r in Registration,
        on: r.tenant_id == o.tenant_id,
        where: o.retirement_id == ^retirement.id,
        order_by: [asc: o.tenant_id],
        select: {o, r.schema_name}
      )
      |> Repo.all()
      |> Enum.map(fn {outcome, schema_name} -> outcome_map(outcome, schema_name) end)

    %{retirement: retirement_map(retirement), outcomes: outcomes}
  end

  defp retirement_map(%EventHistoryRetirement{} = retirement) do
    %{
      id: retirement.id,
      year: retirement.year,
      month: retirement.month,
      status: retirement.status,
      requested_by: retirement.requested_by,
      started_at: retirement.started_at,
      completed_at: retirement.completed_at
    }
  end

  defp outcome_map(%EventHistoryRetirementOutcome{} = outcome, schema_name) do
    %{
      tenant_id: outcome.tenant_id,
      schema_name: schema_name,
      status: String.to_existing_atom(outcome.status),
      retired_partition: outcome.retired_partition,
      protected_rows_relocated: outcome.protected_rows_relocated,
      resumed_from: outcome.resumed_from,
      reason: outcome.reason,
      completed_at: outcome.completed_at
    }
  end

  defp naive_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
