defmodule Letflow.Repository.ActivationHistory do
  @moduledoc """
  Ecto schema for `artifact_activation_history` (REQ-203, REPO-10). The
  append-only activation trail -- see
  `lib/letflow/design/req203-artifact-activation.md` §2.2 for the full
  column rationale, §4.2 for how
  `Letflow.Repository.Activation.activate_group/4` inserts one row per
  artifact activated, and §6 for `Letflow.Repository.Activation.list_history/4`'s
  REQ-067 cursor contract over this table.

  Tenant-scoped, same schema-per-tenant placement as
  `Letflow.Repository.Artifact`/`ArtifactVersion` -- see that module's
  moduledoc and design §1 for the full placement reasoning.

  `previous_version_id` is `nil` on an artifact's first-ever activation in a
  tenant, and populated with the prior `artifact_activations.active_version_id`
  on every activation thereafter (AC5). `new_version_id`/`previous_version_id`
  are both `ON DELETE RESTRICT` FKs to `artifact_versions` -- a version that
  appears anywhere in this trail can never be deleted (AC9).

  Append-only by construction (design §5): no `update/1`/`delete/1` function
  is exposed by `Letflow.Repository.Activation`'s context API for this
  table, and no DB-level immutability trigger is installed -- a deliberate
  judgment call, since no acceptance criterion for this table uses the
  "rejected by the DATABASE" framing REQ-202/req195's own DB-trigger tables
  were built for; this table's protection is FK-based (a referenced version
  can never disappear), not tamper-evidence-based (no hash chain -- see this
  module's context module's moduledoc for the full `audit_entries`
  disambiguation, AC10).

  `rationale` carries the same two-layer non-empty enforcement as
  `Letflow.Repository.ActivationGroup` (design §2.4): changeset-level
  `validate_required/2` plus a DB-level `CHECK (rationale <> '')` backstop.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:history_id, :binary_id, autogenerate: true}
  schema "artifact_activation_history" do
    field(:tenant_id, :binary_id)
    field(:artifact_kind, Ecto.Enum, values: Letflow.Repository.ArtifactKind.values())
    field(:artifact_name, :string)
    field(:previous_version_id, :binary_id)
    field(:new_version_id, :binary_id)
    field(:new_version_number, :integer)
    field(:activator_user_id, :binary_id)
    field(:activated_at, :utc_datetime_usec)
    field(:rationale, :string)
    field(:group_id, :binary_id)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required_fields [
    :tenant_id,
    :artifact_kind,
    :artifact_name,
    :new_version_id,
    :new_version_number,
    :activator_user_id,
    :activated_at,
    :rationale
  ]

  @castable_fields [
    :tenant_id,
    :artifact_kind,
    :artifact_name,
    :previous_version_id,
    :new_version_id,
    :new_version_number,
    :activator_user_id,
    :activated_at,
    :rationale,
    :group_id
  ]

  @doc """
  Structural insert changeset -- `Letflow.Repository.Activation.activate_group/4`
  supplies every field itself (`previous_version_id` from the locked prior
  pointer read, `new_version_id`/`new_version_number` from the activated
  version, the group's shared `activated_at`/`rationale`, and the `group_id`
  of the envelope row this history row belongs to). `previous_version_id` is
  deliberately absent from `@required_fields` -- it is `nil` on an
  artifact's first activation (AC5) -- and `group_id` is likewise not
  required, though `activate_group/4` always supplies it (design §4.4: every
  activation, single or multi, belongs to exactly one group).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = history, attrs) do
    history
    |> cast(attrs, @castable_fields)
    |> validate_required(@required_fields)
  end
end
