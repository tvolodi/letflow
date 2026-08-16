defmodule Letflow.EventStore.Registry.EventType do
  @moduledoc """
  Ecto schema for the `event_type_registry` table — one row per registered
  `(name, schema_version)` event type definition, scoped to a tenant's own
  Postgres schema (schema-per-tenant, via REQ-022's `:prefix` mechanism —
  see `lib/letflow/design/req024-event-type-registry.md` section 3 for the
  full column-by-column rationale).

  Named for what the row *is* (an event type definition), matching this
  codebase's `Letflow.Identity.Tenant`/`User` naming convention — not
  literally "the table name singularized" (which would produce an awkward
  `EventTypeRegistry` nested under `Registry`,
  `Letflow.EventStore.Registry.EventTypeRegistry`, doubling "Registry" in the
  fully qualified name for no benefit).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "event_type_registry" do
    field(:name, :string)
    field(:schema_version, :integer)
    field(:json_schema, :map, default: %{})
    field(:description, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Casts and validates `attrs` for a new event type registration. Only
  enforces the record-shape invariants a single row must satisfy on its own
  (name presence/length, schema_version positivity, json_schema presence)
  plus the DB-level `unique_constraint` fallback for the rare race the
  caller's own pre-check can't fully close.

  `schema_version`'s "greater than all existing versions for this name" rule
  and the exact `(name, schema_version)` duplicate check both live in
  `Letflow.EventStore.Registry.register_type/2`, not here — those checks
  need to query existing rows, which a changeset function has no business
  doing.

  R-Co's `InvalidJsonSchema` structural "is this even a JSON object" check is
  subsumed for free by `Ecto.Type.cast/2` on the `:map` field type — a
  non-map `json_schema` value fails `cast/4` itself, landing in the ordinary
  `{:error, %Ecto.Changeset{}}` path with no bespoke error atom needed.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event_type, attrs) do
    event_type
    |> cast(attrs, [:name, :schema_version, :json_schema, :description])
    |> validate_required([:name, :schema_version, :json_schema])
    |> validate_length(:name, min: 1, max: 128)
    |> validate_number(:schema_version, greater_than: 0)
    |> unique_constraint([:name, :schema_version],
      name: :event_type_registry_name_schema_version_index
    )
  end
end
