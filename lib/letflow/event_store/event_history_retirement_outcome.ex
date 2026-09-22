defmodule Letflow.EventStore.EventHistoryRetirementOutcome do
  @moduledoc """
  `Ecto.Schema` for `event_history_retirement_outcomes` -- the global (not
  tenant-scoped) per-tenant-schema bookkeeping row for one
  `Letflow.EventStore.EventHistoryRetirement`. See
  `lib/letflow/design/req377-history-retirement-screen.md` §2.2/§6 for the
  full field list/rationale this schema implements.

  `resumed_from` mirrors `Letflow.EventStore.PartitionMaintenance.resumed_from/0`'s
  four string values (`"not_started"`, `"pending_detach"`,
  `"detached_standalone"`, `"already_retired"`), stored verbatim as
  informational context, not re-validated against that type here.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "event_history_retirement_outcomes" do
    field(:retirement_id, Ecto.UUID)
    field(:tenant_id, Ecto.UUID)
    field(:status, :string, default: "pending")
    field(:retired_partition, :string)
    field(:protected_rows_relocated, :integer)
    field(:resumed_from, :string)
    field(:reason, :string)
    field(:completed_at, :naive_datetime)
  end

  @type t :: %__MODULE__{}

  @statuses ~w(pending succeeded skipped failed)

  @cast_fields [
    :retirement_id,
    :tenant_id,
    :status,
    :retired_partition,
    :protected_rows_relocated,
    :resumed_from,
    :reason,
    :completed_at
  ]

  @required_fields [:retirement_id, :tenant_id, :status]

  @doc """
  Structural changeset: casts every field above, requires the identity/
  status fields, validates `status` against the closed four-value enum, and
  declares the FK constraint fallbacks for `retirement_id`/`tenant_id`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(outcome, attrs) do
    outcome
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:retirement_id)
    |> foreign_key_constraint(:tenant_id)
  end
end
