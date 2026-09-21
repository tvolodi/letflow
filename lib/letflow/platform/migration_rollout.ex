defmodule Letflow.Platform.MigrationRollout do
  @moduledoc """
  Context module for REQ-374's platform-wide tenant-migration fanout runner.
  See `lib/letflow/design/req374-tenant-migration-fanout-runner.md` for the
  full design this module implements.

  ## Process-vs-row decision (design doc §1, mirrors REQ-045 / `Letflow.Engine`)

  A plain transactional context module — no `gen_statem`, no supervised
  process, no new supervisor child. There is no multi-step conversation a
  caller holds open across several calls, no timer, no backpressure, no
  external-plugin call: every write this module performs is already
  transactional at the point it happens (one Postgres transaction per
  company, via `Letflow.TenantProvisioning.run_column_promotion/1`, reused
  unchanged). Rollout-level state (which companies are outstanding, which
  succeeded/failed) lives entirely in the two Postgres tables below, not in
  any process's memory — a rollout in progress is a durable row set an
  operator re-queries and re-drives by calling a function again
  (`start_rollout/3`, `resume_rollout/1`), the same shape
  `Letflow.TenantProvisioning.run_column_promotion_for_all_tenants/1`
  already uses for its own narrower single-tenant-DDL fan-out. Concurrency
  is arbitrated by Postgres row/advisory locks (the same per-schema
  advisory lock `run_column_promotion/1` already takes), not a supervised
  process per instance. `Letflow.InstanceSupervisor` is untouched by this
  module.

  ## The one concrete "change" this module knows how to apply (design doc §2)

  This module proves the fanout/resume/idempotent-rerun mechanism against
  exactly **one** real, concrete change: promoting one new column onto one
  entity type, tenant-schema by tenant-schema, reusing
  `Letflow.TenantProvisioning.register_column_promotion/4` and
  `run_column_promotion/1` unchanged. `entity_type`, `attribute`, and
  `column_spec` are the only identifiers `start_rollout/3` accepts — there
  is no dispatch table, no behaviour callback, no "kind" enum beyond this
  one path. A future requirement that needs a second kind of platform-wide
  change extends this module's single apply path or adds a second one at
  that time; it is not pre-built here.

  ## Failure isolation (design doc §5, EO-001/EO-002)

  `apply_outstanding/1` iterates outcome rows independently, one
  `run_column_promotion/1` call (itself one Postgres transaction) per
  company — there is no enclosing transaction across companies, so one
  company's `{:error, _}` cannot roll back or block a sibling company's
  already-committed transaction. The DDL step and the outcome-row write are
  **deliberately separate transactions**: if they were combined and the DDL
  attempt aborted the connection (a genuinely raised Postgres error, not an
  ordinary `{:error, _}` return — see
  `Letflow.TenantProvisioning`'s `mark_ddl_failed_and_return/3` comment on
  this exact hazard), the outcome-row write would be lost along with it.
  Neither of this module's two tables is tenant-schema-prefixed — this
  module introduces no new write path into any tenant's own schema beyond
  the single `ALTER TABLE` `run_column_promotion/1` already issues and
  already rolls back correctly on failure.

  ## Idempotent re-run never touched once succeeded (EO-004/EO-005)

  An outcome row's `completed_at`/`status`/`reason` are never rewritten
  once `status == "succeeded"` — structurally enforced by
  `apply_outstanding/1`'s own query (`WHERE status != "succeeded"`), not by
  an application-level "skip if already done" branch a future edit could
  accidentally weaken. `start_rollout/3`'s repeat-call branch additionally
  separates "already succeeded" (zero writes, reported `already_current:
  true`) from "still outstanding" (apply again) *before* touching any row.

  ## Permission decision (design doc §7)

  Rollout endpoints reuse the existing `:TenantsManage` permission
  (`Letflow.Api.Authorization`), not a new one — see
  `Letflow.Routers.PlatformMigrations`'s own moduledoc for the full
  reasoning.
  """

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.Platform.MigrationRollout.Outcome
  alias Letflow.Platform.MigrationRollout.Rollout
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.TenantProvisioning.Registration

  @type rollout :: %{
          id: Ecto.UUID.t(),
          entity_type: String.t(),
          attribute: String.t(),
          status: String.t(),
          started_at: NaiveDateTime.t(),
          completed_at: NaiveDateTime.t() | nil
        }

  @type outcome :: %{
          tenant_id: Ecto.UUID.t(),
          status: String.t(),
          completed_at: NaiveDateTime.t() | nil,
          reason: String.t() | nil,
          already_current: boolean()
        }

  @type rollout_result :: %{rollout: rollout(), outcomes: [outcome()]}

  @doc """
  Starts (or, for a repeat call against the same `(entity_type,
  attribute)`, continues) a platform-wide column-promotion rollout. See
  design doc §4.1 for the full step-by-step behavior, including the
  repeat-call "already-current" bucketing (EO-005) and the OQ-1 scope-drift
  choice (a newly-active/newly-provisioned company is registered and
  applied even on a repeat call).

  A repeat call supplying a `column_spec` that differs from the one the
  rollout was first started with (design doc §9 OQ-2) is rejected with
  `{:error, :column_spec_conflict}` rather than silently applied — silently
  ignoring a caller-supplied spec change is the more surprising failure
  mode.
  """
  @spec start_rollout(
          entity_type :: String.t(),
          attribute :: String.t(),
          column_spec :: %{
            required(:pg_type) => String.t(),
            required(:nullable) => true,
            optional(:references_entity) => String.t(),
            optional(:generated_as) => String.t() | nil
          }
        ) :: {:ok, rollout_result()} | {:error, term()}
  def start_rollout(entity_type, attribute, column_spec)
      when is_binary(entity_type) and is_binary(attribute) and is_map(column_spec) do
    case Repo.get_by(Rollout, entity_type: entity_type, attribute: attribute) do
      nil -> start_new_rollout(entity_type, attribute, column_spec)
      %Rollout{} = existing -> continue_existing_rollout(existing, column_spec)
    end
  end

  @doc """
  Loads the rollout by id and re-applies the change only to its outcome
  rows currently `"pending"` or `"failed"` — never touches a row whose
  `status == "succeeded"` (EO-004, enforced structurally by
  `apply_outstanding/1`'s own query, not by an app-level skip branch).
  """
  @spec resume_rollout(rollout_id :: Ecto.UUID.t()) ::
          {:ok, rollout_result()} | {:error, :rollout_not_found}
  def resume_rollout(rollout_id) do
    case Repo.get(Rollout, rollout_id) do
      nil ->
        {:error, :rollout_not_found}

      %Rollout{} ->
        apply_outstanding(rollout_id)
        recompute_rollout_completion(rollout_id)
        {:ok, build_rollout_result(rollout_id, MapSet.new())}
    end
  end

  @doc """
  Pure read: the rollout row plus every outcome row for it, ordered by
  `tenant_id` (stable ordering for the screen and for tests) — AC3's
  "queryable per rollout_id".
  """
  @spec rollout_status(rollout_id :: Ecto.UUID.t()) ::
          {:ok, rollout_result()} | {:error, :rollout_not_found}
  def rollout_status(rollout_id) do
    case Repo.get(Rollout, rollout_id) do
      nil -> {:error, :rollout_not_found}
      %Rollout{} -> {:ok, build_rollout_result(rollout_id, MapSet.new())}
    end
  end

  # ---------------------------------------------------------------------
  # start_rollout/3 -- first-call and repeat-call branches (design §4.1)
  # ---------------------------------------------------------------------

  defp start_new_rollout(entity_type, attribute, column_spec) do
    attrs = %{
      entity_type: entity_type,
      attribute: attribute,
      column_spec: column_spec,
      status: "running",
      started_at: naive_now()
    }

    with {:ok, rollout} <- Repo.insert(Rollout.changeset(%Rollout{}, attrs)) do
      active_company_tenant_ids()
      |> Enum.each(
        &register_and_seed_outcome(rollout.id, &1, entity_type, attribute, column_spec)
      )

      apply_outstanding(rollout.id)
      recompute_rollout_completion(rollout.id)
      {:ok, build_rollout_result(rollout.id, MapSet.new())}
    end
  end

  defp continue_existing_rollout(%Rollout{} = rollout, column_spec) do
    if rollout.column_spec == stringify_column_spec(column_spec) do
      apply_to_existing_rollout(rollout, column_spec)
    else
      {:error, :column_spec_conflict}
    end
  end

  defp apply_to_existing_rollout(%Rollout{} = rollout, column_spec) do
    existing_outcomes_by_tenant =
      from(o in Outcome, where: o.rollout_id == ^rollout.id)
      |> Repo.all()
      |> Map.new(&{&1.tenant_id, &1})

    already_current_tenant_ids =
      existing_outcomes_by_tenant
      |> Enum.filter(fn {_tenant_id, outcome} -> outcome.status == "succeeded" end)
      |> Enum.map(fn {tenant_id, _outcome} -> tenant_id end)
      |> MapSet.new()

    active_company_tenant_ids()
    |> Enum.each(fn tenant_id ->
      case Map.get(existing_outcomes_by_tenant, tenant_id) do
        nil ->
          # A company that became active/provisioned after this rollout
          # first started (design §4.1, OQ-1) -- register + apply for it
          # now, extending the rollout's scope.
          register_and_seed_outcome(
            rollout.id,
            tenant_id,
            rollout.entity_type,
            rollout.attribute,
            column_spec
          )

        %Outcome{} ->
          # Already has an outcome row (succeeded, pending, or failed) --
          # never register a second time; apply_outstanding/1 below picks
          # up anything still outstanding via its own query.
          :ok
      end
    end)

    apply_outstanding(rollout.id)
    recompute_rollout_completion(rollout.id)
    {:ok, build_rollout_result(rollout.id, already_current_tenant_ids)}
  end

  # register_column_promotion/4 stores/returns column_spec fields already
  # normalized to string values by Ecto's own :map cast -- comparing the
  # caller-supplied column_spec (atom keys, as this module's own @spec
  # requires) against the persisted, string-keyed value directly would
  # always mismatch. Normalizes both sides the same way Ecto's :map type
  # already would, so a call passing the truly identical spec compares
  # equal.
  defp stringify_column_spec(column_spec) do
    for {key, value} <- column_spec, into: %{}, do: {to_string(key), value}
  end

  defp register_and_seed_outcome(rollout_id, tenant_id, entity_type, attribute, column_spec) do
    case TenantProvisioning.register_column_promotion(
           entity_type,
           attribute,
           column_spec,
           [tenant_id]
         ) do
      {:ok, [promotion]} ->
        outcome_attrs = %{
          rollout_id: rollout_id,
          tenant_id: tenant_id,
          column_promotion_id: promotion.id,
          status: "pending"
        }

        Repo.insert!(Outcome.changeset(%Outcome{}, outcome_attrs))

      {:error, changeset} ->
        record_registration_conflict(rollout_id, tenant_id, entity_type, attribute, changeset)
    end

    :ok
  end

  # register_column_promotion/4's only realistic failure mode for a single,
  # already-validated tenant_id is entity_column_promotions' own
  # (tenant_id, entity_type, attribute) unique-constraint -- a genuinely
  # reachable condition since ColumnPromotion is a public, independently
  # callable row and a tenant could already hold a matching row (from an
  # earlier, non-rollout registration) before this rollout ever targets
  # that pair. Previously this `{:error, _}` fell through a `with`'s
  # missing `else` silently -- the company ended up with NO outcome row at
  # all (not pending, not failed, just absent from rollout_status/1),
  # breaking AC1/EO-001's "the failing company recorded FAILED with a
  # plain reason" contract for this failure class (REVIEWER finding, WF02
  # rework). Fixed here: record the company as "failed" instead.
  #
  # An outcome row's column_promotion_id is NOT NULL + FK, so recording
  # the failure still needs a real promotion row to point at -- the
  # conflicting row IS that promotion (that's exactly why the unique
  # constraint fired), so it is looked up by the same natural key and
  # linked to, not synthesized.
  defp record_registration_conflict(rollout_id, tenant_id, entity_type, attribute, changeset) do
    case Repo.get_by(ColumnPromotion,
           tenant_id: tenant_id,
           entity_type: entity_type,
           attribute: attribute
         ) do
      %ColumnPromotion{} = promotion ->
        outcome_attrs = %{
          rollout_id: rollout_id,
          tenant_id: tenant_id,
          column_promotion_id: promotion.id,
          status: "failed",
          completed_at: naive_now(),
          reason: describe_failure_reason(changeset)
        }

        Repo.insert!(Outcome.changeset(%Outcome{}, outcome_attrs))

      nil ->
        # No conflicting row exists despite register_column_promotion/4
        # returning {:error, _} -- not a condition this module's own
        # single write path can produce. Raised rather than silently
        # dropped, so a genuinely unexpected failure here is never
        # swallowed either.
        raise "Letflow.Platform.MigrationRollout: register_column_promotion/4 failed for " <>
                "tenant #{tenant_id} (#{entity_type}.#{attribute}) with no matching " <>
                "entity_column_promotions row to attribute the failure to: #{inspect(changeset)}"
    end
  end

  # ---------------------------------------------------------------------
  # apply_outstanding/1 (design §4.4) -- shared by start_rollout/3 and
  # resume_rollout/1
  # ---------------------------------------------------------------------

  @spec apply_outstanding(rollout_id :: Ecto.UUID.t()) :: :ok
  defp apply_outstanding(rollout_id) do
    from(o in Outcome, where: o.rollout_id == ^rollout_id and o.status != "succeeded")
    |> Repo.all()
    |> Enum.each(&apply_one_outcome/1)

    :ok
  end

  # Step 1: drive the underlying ColumnPromotion row to a terminal state,
  # branching on its own status -- three branches, not two (design §4.4):
  # the third covers the crash-recovery window (design §5.2) where the DDL
  # already committed but the outcome-row write in a prior call was lost.
  #
  # "suspended" (the seventh, last @statuses value on
  # Letflow.TenantProvisioning.ColumnPromotion) is deliberately NOT a
  # fourth *reachable-value* branch above the catch-all below -- verified
  # directly against source, not taken on trust, that no function anywhere
  # in Letflow.TenantProvisioning ever writes status: "suspended"
  # (suspend_column_promotion/2 requires status == "active" as a
  # precondition and leaves status at "active" by design, per 0024 §4). A
  # ColumnPromotion row reaching this function can structurally never have
  # status == "suspended" today. This mirrors
  # Letflow.TenantProvisioning.checked_table_name/1's real posture on its
  # own unreachable value (tenant_provisioning.ex:1463-1473): an explicit
  # `raise ArgumentError` catch-all with a clear message, never a bare,
  # implicit CaseClauseError left to fall out on its own (corrected here
  # per REVIEWER -- the prior comment cited that function as doing the
  # opposite of what it actually does).
  defp apply_one_outcome(%Outcome{} = outcome) do
    promotion = Repo.get!(ColumnPromotion, outcome.column_promotion_id)

    result =
      case promotion.status do
        "pending" ->
          TenantProvisioning.run_column_promotion(promotion.id)

        "ddl_failed" ->
          TenantProvisioning.retry_failed_column_promotion(promotion.id)

        status when status in ["ddl_applied", "backfilling", "backfilled", "active"] ->
          # The DDL already succeeded -- do not re-enter the advisory-locked
          # DDL path for a column that is already there. Only the
          # outcome-row catch-up (step 2) is needed.
          {:ok, promotion}

        other ->
          raise ArgumentError,
                "ColumnPromotion #{promotion.id} has unexpected status: #{inspect(other)}"
      end

    # Step 2 (design §4.4): a SEPARATE transaction from step 1, deliberately
    # (design §5.2) -- run_column_promotion/1's own Repo.transaction/1 (or,
    # for the crash-recovery branch above, no transaction at all) has
    # already committed/returned by the time this write runs.
    record_outcome_result(outcome, result)
  end

  defp record_outcome_result(%Outcome{} = outcome, {:ok, _column_promotion}) do
    attrs = %{status: "succeeded", completed_at: naive_now(), reason: nil}
    Repo.update!(Outcome.changeset(outcome, attrs))
  end

  defp record_outcome_result(%Outcome{} = outcome, {:error, reason}) do
    attrs = %{
      status: "failed",
      completed_at: naive_now(),
      reason: describe_failure_reason(reason)
    }

    Repo.update!(Outcome.changeset(outcome, attrs))
  end

  # ---------------------------------------------------------------------
  # active_company_tenant_ids/0 (design §4.5)
  # ---------------------------------------------------------------------

  @spec active_company_tenant_ids() :: [Ecto.UUID.t()]
  defp active_company_tenant_ids do
    from(t in Tenant,
      join: r in Registration,
      on: r.tenant_id == t.id,
      where: t.status == :active,
      select: t.id
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------
  # recompute_rollout_completion/1 (design §4.6)
  # ---------------------------------------------------------------------

  @spec recompute_rollout_completion(rollout_id :: Ecto.UUID.t()) :: :ok
  defp recompute_rollout_completion(rollout_id) do
    outstanding_count =
      from(o in Outcome, where: o.rollout_id == ^rollout_id and o.status != "succeeded")
      |> Repo.aggregate(:count, :id)

    rollout = Repo.get!(Rollout, rollout_id)

    if outstanding_count == 0 and is_nil(rollout.completed_at) do
      attrs = %{status: "completed", completed_at: naive_now()}
      Repo.update!(Rollout.changeset(rollout, attrs))
    end

    :ok
  end

  # ---------------------------------------------------------------------
  # describe_failure_reason/1 (design §5.3)
  # ---------------------------------------------------------------------

  @spec describe_failure_reason(term()) :: String.t()
  defp describe_failure_reason({:column_type_conflict, existing, requested}) do
    "Could not apply the change to this workspace: an existing column already has a " <>
      "conflicting type (existing: #{existing}, requested: #{requested})."
  end

  defp describe_failure_reason({:ddl_failed, exception}) do
    "Could not apply the change to this workspace: " <> Exception.message(exception)
  end

  defp describe_failure_reason(:tenant_not_provisioned) do
    "This workspace is not yet provisioned and cannot receive platform changes."
  end

  defp describe_failure_reason(reason) do
    "Could not apply the change to this workspace: " <> inspect(reason)
  end

  # ---------------------------------------------------------------------
  # Result-shaping helper shared by start_rollout/3, resume_rollout/1, and
  # rollout_status/1.
  # ---------------------------------------------------------------------

  defp build_rollout_result(rollout_id, already_current_tenant_ids) do
    rollout = Repo.get!(Rollout, rollout_id)

    outcomes =
      from(o in Outcome, where: o.rollout_id == ^rollout_id, order_by: [asc: o.tenant_id])
      |> Repo.all()
      |> Enum.map(fn outcome ->
        %{
          tenant_id: outcome.tenant_id,
          status: outcome.status,
          completed_at: outcome.completed_at,
          reason: outcome.reason,
          already_current: MapSet.member?(already_current_tenant_ids, outcome.tenant_id)
        }
      end)

    %{rollout: rollout_map(rollout), outcomes: outcomes}
  end

  defp rollout_map(%Rollout{} = rollout) do
    %{
      id: rollout.id,
      entity_type: rollout.entity_type,
      attribute: rollout.attribute,
      status: rollout.status,
      started_at: rollout.started_at,
      completed_at: rollout.completed_at
    }
  end

  defp naive_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
