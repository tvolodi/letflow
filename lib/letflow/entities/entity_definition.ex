defmodule Letflow.Entities.EntityDefinition do
  @moduledoc """
  `Ecto.Schema` for the persisted `entity_definitions` table (REQ-226). See
  `lib/letflow/design/req226-entity-definitions-persistence-crud.md` §1
  (migration schema) and §3.2 (this schema's field list) for the full design
  this module implements.

  This is the **persisted-row** half of the document/persistence split named
  in the design's §3.1: `Letflow.Entities.Definition` (REQ-225) is a plain
  document `@type` describing the shape of the JSON blob stored in this
  schema's `definition_json` column; this module is the `Ecto.Schema` for
  the denormalised row referencing that blob's `Letflow.Repository`-owned
  `artifact_version_id`. `Letflow.Entities.Definitions` (plural, the CRUD
  context module) is the third, distinct member of this family -- see that
  module's moduledoc.

  `status` is a local read-convenience denormalisation of REQ-203's
  `artifact_activations` pointer, kept in sync by
  `Letflow.Entities.Definitions.activate_definition/4`; a reader needing an
  authoritative "is this currently active" answer still calls
  `Letflow.Repository.Activation.resolve/3` directly (design §1.2).

  No `updated_at` column (`timestamps(updated_at: false)`) -- this table has
  no update path in REQ-226's own scope beyond `status` (design §1.4).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "entity_definitions" do
    field(:tenant_id, :binary_id)
    field(:name, :string)
    field(:display_name, :string)
    field(:definition_json, :map)
    field(:content_hash, :binary)
    field(:logical_shape_version, :binary)
    field(:artifact_version_id, :binary_id)
    field(:status, Ecto.Enum, values: [:active, :inactive])

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required_fields [
    :tenant_id,
    :name,
    :display_name,
    :definition_json,
    :content_hash,
    :logical_shape_version,
    :artifact_version_id,
    :status
  ]

  # Must match the explicit `:name` given to `unique_index/3` in
  # priv/repo/migrations/20260906000001_create_entity_definitions.exs
  # exactly, same reasoning as `Letflow.Repository.ArtifactVersion.changeset/2`'s
  # own `@unique_version_number_constraint_name`.
  @unique_tenant_name_shape_constraint_name :entity_definitions_tenant_name_shape_idx

  @doc """
  Structural insert/update changeset. `unique_constraint/3` translates the
  `(tenant_id, name, logical_shape_version)` UNIQUE violation
  (design §1.3/§5) into a changeset error on `:name`;
  `foreign_key_constraint/3` translates a hypothetical `artifact_version_id`
  FK violation into a changeset error -- matching
  `Letflow.Repository.Activation.changeset/2`'s own `foreign_key_constraint/3`
  idiom.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = entity_definition, attrs) do
    entity_definition
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name, name: @unique_tenant_name_shape_constraint_name)
    |> foreign_key_constraint(:artifact_version_id)
  end
end
