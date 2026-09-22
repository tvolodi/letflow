defmodule Letflow.EventStore.EventHistoryRetirement do
  @moduledoc """
  `Ecto.Schema` for `event_history_retirements` -- the global (not
  tenant-scoped) bookkeeping row for one platform-wide "retire the oldest
  eligible month of event history, across every provisioned tenant schema"
  operation. See `lib/letflow/design/req377-history-retirement-screen.md`
  §2.2/§6 for the full field list/rationale this schema implements.

  Sibling to `Letflow.Platform.MigrationRollout.Rollout`, same conventions:
  plain `binary_id` primary key, no `belongs_to` association,
  `has_many :outcomes`.

  `requested_by` carries NO foreign-key constraint -- see the owning
  migration's own comment (deviation flagged there) for why: `users` is a
  tenant-scoped table (one per tenant Postgres schema, decision 0006 D1),
  so this deliberately GLOBAL table cannot reference it. `requested_by` is
  an attribution value only (the authenticated actor's id), never
  referential-integrity-enforced.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Letflow.EventStore.EventHistoryRetirementOutcome

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "event_history_retirements" do
    field(:year, :integer)
    field(:month, :integer)
    field(:status, :string, default: "running")
    field(:requested_by, Ecto.UUID)
    field(:started_at, :naive_datetime)
    field(:completed_at, :naive_datetime)

    has_many(:outcomes, EventHistoryRetirementOutcome, foreign_key: :retirement_id)
  end

  @type t :: %__MODULE__{}

  @statuses ~w(running completed failed)

  @cast_fields [:year, :month, :status, :requested_by, :started_at, :completed_at]
  @required_fields [:year, :month, :status, :requested_by, :started_at]

  @doc """
  Structural changeset: casts every field above, requires the identity/
  status/started_at fields, and validates `status` against the closed
  three-value enum. `requested_by` carries no FK constraint fallback --
  see this module's own moduledoc for why.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(retirement, attrs) do
    retirement
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
  end
end
