defmodule Letflow.Platform.MigrationRollout.Rollout do
  @moduledoc """
  `Ecto.Schema` for `platform_migration_rollouts` -- the global (not
  tenant-scoped) bookkeeping row for one platform-wide "promote this column
  onto this entity type, across every active company" rollout. See
  `lib/letflow/design/req374-tenant-migration-fanout-runner.md` §3.1 for the
  full field list/rationale this schema implements.

  Sibling to `Letflow.TenantProvisioning.Registration` and
  `Letflow.TenantProvisioning.ColumnPromotion`, same conventions: plain
  `binary_id` primary key, no `belongs_to` association.

  `column_spec` is stored verbatim -- the exact map `start_rollout/3` was
  first called with -- so a repeat call for the same `(entity_type,
  attribute)` pair can detect a caller supplying a different spec (design
  doc §9 OQ-2) and so `resume_rollout/1` never needs the caller to resupply
  it.

  `(entity_type, attribute)` carries a DB-level unique index -- this is the
  natural key that makes "starting the identical rollout again" resolve to
  the same row instead of creating a duplicate one (EO-005).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "platform_migration_rollouts" do
    field(:entity_type, :string)
    field(:attribute, :string)
    field(:column_spec, :map)
    field(:status, :string, default: "running")
    field(:started_at, :naive_datetime)
    field(:completed_at, :naive_datetime)
  end

  @type t :: %__MODULE__{}

  @statuses ~w(running completed)

  @cast_fields [:entity_type, :attribute, :column_spec, :status, :started_at, :completed_at]
  @required_fields [:entity_type, :attribute, :column_spec, :status, :started_at]

  @doc """
  Structural changeset: casts every field above, requires the identity/
  status/started_at fields, validates `status` against the closed
  two-value enum, and declares the DB-level unique-constraint fallback for
  `(entity_type, attribute)`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rollout, attrs) do
    rollout
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:entity_type, :attribute],
      name: :platform_migration_rollouts_entity_type_attribute_idx
    )
  end
end
