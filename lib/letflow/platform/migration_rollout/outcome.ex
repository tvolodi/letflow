defmodule Letflow.Platform.MigrationRollout.Outcome do
  @moduledoc """
  `Ecto.Schema` for `platform_migration_rollout_outcomes` -- the global
  (not tenant-scoped) per-company bookkeeping row for one
  `Letflow.Platform.MigrationRollout.Rollout`. See
  `lib/letflow/design/req374-tenant-migration-fanout-runner.md` §3.2 for
  the full field list/rationale this schema implements.

  `column_promotion_id` is the underlying `Letflow.TenantProvisioning.ColumnPromotion`
  row this outcome wraps -- the rollout layer never duplicates DDL-execution
  state, only summarizes it (REQ-297/298's own machinery remains the sole
  source of truth for whether the DDL itself succeeded).

  `completed_at` is set the instant `status` transitions away from
  `"pending"` and **never written again once set** -- the literal mechanism
  behind EO-004's "original completion timestamp is unchanged" and EO-005's
  "zero writes on an identical re-run": every read path that drives writes
  (`Letflow.Platform.MigrationRollout.apply_outstanding/1`) structurally
  excludes rows with `status == "succeeded"` via its own query, not via an
  application-level "skip if already done" branch.

  `(rollout_id, tenant_id)` carries a DB-level unique index -- one outcome
  row per company per rollout.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "platform_migration_rollout_outcomes" do
    field(:rollout_id, Ecto.UUID)
    field(:tenant_id, Ecto.UUID)
    field(:column_promotion_id, Ecto.UUID)
    field(:status, :string, default: "pending")
    field(:completed_at, :naive_datetime)
    field(:reason, :string)
  end

  @type t :: %__MODULE__{}

  @statuses ~w(pending succeeded failed)

  @cast_fields [
    :rollout_id,
    :tenant_id,
    :column_promotion_id,
    :status,
    :completed_at,
    :reason
  ]

  @required_fields [:rollout_id, :tenant_id, :column_promotion_id, :status]

  @doc """
  Structural changeset: casts every field above, requires the identity/
  status fields, validates `status` against the closed three-value enum,
  and declares the DB-level constraint fallbacks (`unique_constraint/2` for
  `(rollout_id, tenant_id)`, `foreign_key_constraint/2` for `rollout_id`,
  `tenant_id`, and `column_promotion_id`).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(outcome, attrs) do
    outcome
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:rollout_id, :tenant_id],
      name: :platform_migration_rollout_outcomes_rollout_id_tenant_id_idx
    )
    |> foreign_key_constraint(:rollout_id)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:column_promotion_id)
  end
end
