defmodule Letflow.Repository.ActivationGroup do
  @moduledoc """
  Ecto schema for `artifact_activation_groups` (REQ-203, REPO-08). The
  envelope that makes a multi-artifact activation one observable unit -- see
  `lib/letflow/design/req203-artifact-activation.md` §2.3 for the full column
  rationale, and §4 for how `Letflow.Repository.Activation.activate_group/4`
  builds and inserts this row as the first step of its `Ecto.Multi` pipeline.

  Tenant-scoped, same schema-per-tenant placement as
  `Letflow.Repository.Artifact`/`ArtifactVersion` -- see that module's
  moduledoc and design §1 for the full placement reasoning.

  Append-only by construction (design §5): no `update/1`/`delete/1` function
  is exposed by `Letflow.Repository.Activation`'s context API for this
  table. No DB-level immutability trigger is installed -- a deliberate
  judgment call (design §5), since no acceptance criterion for this table
  uses the "rejected by the DATABASE" framing REQ-202/req195's own
  DB-trigger tables were built for.

  `rationale` carries a two-layer non-empty enforcement (design §2.4):
  `validate_required/2` at the changeset level (rejects `nil`, `""`, and any
  whitespace-only string, since `cast/4`'s default trim-leading pipeline
  collapses all three to `nil`), and a DB-level `CHECK (rationale <> '')`
  constraint installed by this table's migration as the backstop for any
  write path that bypasses this changeset entirely.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:group_id, :binary_id, autogenerate: true}
  schema "artifact_activation_groups" do
    field(:tenant_id, :binary_id)
    field(:activated_at, :utc_datetime_usec)
    field(:activator_user_id, :binary_id)
    field(:rationale, :string)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required_fields [:group_id, :tenant_id, :activated_at, :activator_user_id, :rationale]
  @castable_fields [:group_id, :tenant_id, :activated_at, :activator_user_id, :rationale]

  @doc """
  Structural insert changeset -- `Letflow.Repository.Activation.activate_group/4`
  supplies every field itself (the minted `group_id`, the resolved
  `tenant_id`, the group's shared `activated_at` timestamp, the caller's
  `activator_user_id`, and the caller's `rationale`). `validate_required/2`
  is what rejects a blank/whitespace-only `rationale` at the application
  layer (design §2.4 point 1); the DB `CHECK` is the migration-level
  backstop (design §2.4 point 2), not enforced here.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = group, attrs) do
    group
    |> cast(attrs, @castable_fields)
    |> validate_required(@required_fields)
  end
end
