defmodule Letflow.TenantProvisioning.ConstraintActivation do
  @moduledoc """
  `Ecto.Schema` for `entity_constraint_activations` -- REQ-298's retrofit-only
  activation-tracking table for a `constraint_def`'s (multi-column) unique
  index. See `lib/letflow/design/req298-constraint-fk-activation.md` §4 for
  the full design this schema implements.

  ## Why a new tracked row, not a `ColumnPromotion` overload (design §4.1)

  Mirrors `Letflow.TenantProvisioning.ColumnPromotion`'s own reasoning
  (`docs/migration/decisions/0024-entity-promotion-ddl-execution.md` §2): a
  `constraint_def`'s activation against N tenants is not atomic across
  tenants, and must be individually retryable per tenant -- a constraint's
  target columns might exist in one tenant's table already but not yet in
  another's, since column promotions for the same attribute are triggered
  independently per tenant. A `ColumnPromotion` row identifies one
  `(tenant_id, entity_type, attribute)`; a `constraint_def` spans MULTIPLE
  attributes and carries its own `name`, not a single `attribute` -- this is
  a parallel, equally-shaped tracked row, not an overload of an existing
  one.

  This is **not** a new per-tenant-execution mechanism: it is the same
  module (`Letflow.TenantProvisioning`), the same `Repo.query!/1` +
  `rescue` DDL-issuing shape, and the same per-tenant advisory-lock pattern
  `ColumnPromotion`/`run_column_promotion/1` already use, applied to a
  second DDL statement kind (`ADD CONSTRAINT` vs. `ADD COLUMN`/`CREATE
  TABLE`).

  Sibling to `ColumnPromotion`, same conventions: plain `binary_id` primary
  key, no `belongs_to` association on `tenant_id`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "entity_constraint_activations" do
    field(:tenant_id, Ecto.UUID)
    field(:entity_type, :string)
    field(:constraint_name, :string)
    field(:fields, {:array, :string})
    field(:status, :string)
    field(:last_error, :string)
    field(:attempted_at, :naive_datetime)
    field(:ddl_applied_at, :naive_datetime)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @statuses ~w(pending ddl_applied ddl_failed)

  @cast_fields [
    :tenant_id,
    :entity_type,
    :constraint_name,
    :fields,
    :status,
    :last_error,
    :attempted_at,
    :ddl_applied_at
  ]

  @required_fields [:tenant_id, :entity_type, :constraint_name, :fields, :status]

  @doc """
  Structural changeset: casts every field above except timestamps, requires
  the identity/status fields, validates `status` against the closed
  three-value enum (`pending -> ddl_applied | ddl_failed`, no `backfilling`/
  `backfilled`/`active`/`suspended` states -- a unique index has no
  query-eligible gate and no backfill step, per design §4.3), and declares
  the DB-level constraint fallbacks -- same shape as
  `ColumnPromotion.changeset/2`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(constraint_activation, attrs) do
    constraint_activation
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:tenant_id,
      name: :entity_constraint_activations_tenant_entity_name_idx
    )
    |> foreign_key_constraint(:tenant_id)
  end
end
