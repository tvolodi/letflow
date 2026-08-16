defmodule Letflow.EventStore.InstanceProjection do
  @moduledoc """
  Ecto schema for the `instance_projections` table. See
  `lib/letflow/design/req023-event-store-schema.md` §3.3 and §5.1.

  ## Scope (REQ-023 acceptance criterion 5)

  This table's *schema* is event-store scope — this requirement (REQ-023)
  owns it, because R-Co's `src/design/event_store.md` "DB tables / columns
  per operation" section shows `Store.append()` reading and writing
  `instance_projections` directly for the ES-01 active-instance guard and
  the DB-03 `last_event_seq` update.

  Its *meaningful population at instance start* is EE-01 / S3 territory
  (`src/engine/`, not built yet). Do not read this migration as
  instance-engine work landing early. The engine-owned columns R-Co's
  `migrations/001_event_store.sql` also carries — `definition_id`,
  `correlation_key`, `current_nodes`, `variables`, `error_detail`,
  `completed_at`, `cancelled_at`, and the `uq_instance_correlation` /
  `idx_proj_definition` indexes that depend on them — are deliberately not
  created here; S3 adds them in its own migration.

  ## Derived state (design INV-EV-9)

  Per `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision C point
  3, this is a projection table: rebuildable at any time from a fold over
  `events`. Its real correctness boundary — "matches a fold over the event
  log" — is a runtime/test concern that no column constraint can express, which
  is why it is migrated with the same DSL and constraint discipline as any
  ordinary CRUD table and why, unlike every other schema in
  `lib/letflow/event_store/`, it legitimately exposes an `update_changeset/2`.

  ## No `@schema_prefix` (design INV-EV-8)

  Like every event-store schema module, this table lives in many Postgres
  schemas — one per tenant — so every read and write must pass
  `prefix: schema_name` explicitly at call time rather than relying on a
  compile-time prefix.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:instance_id, :binary_id, autogenerate: false}
  schema "instance_projections" do
    field(:tenant_id, Ecto.UUID)

    field(:status, Ecto.Enum,
      values: [active: "ACTIVE", completed: "COMPLETED", cancelled: "CANCELLED", error: "ERROR"],
      default: :active
    )

    field(:last_event_seq, :integer, default: 0)

    timestamps(inserted_at: :started_at, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type status :: :active | :completed | :cancelled | :error

  @doc """
  Structural changeset for creating an instance's projection row. Does no I/O.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(projection, attrs) do
    projection
    |> cast(attrs, [:instance_id, :tenant_id, :status, :last_event_seq])
    |> validate_required([:instance_id, :tenant_id, :status])
  end

  @doc """
  Structural changeset for advancing an existing projection row. `instance_id`
  and `tenant_id` are structurally not castable here — a projection never
  changes which instance or tenant it describes.
  """
  @spec update_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def update_changeset(projection, attrs) do
    projection
    |> cast(attrs, [:status, :last_event_seq])
    |> validate_required([:status, :last_event_seq])
    |> validate_number(:last_event_seq, greater_than_or_equal_to: 0)
  end

  @doc """
  Whether a projection status forbids further appends to its instance.

  `true` for `:completed` and `:cancelled` only. `:error` is **not** terminal —
  R-Co's `src/design/event_store.md:292` (Key invariant 10) names exactly
  CANCELLED and COMPLETED. Pure, no I/O. Exists so REQ-025's active-instance
  guard has one authoritative definition of "terminated" (design INV-EV-10).
  """
  @spec terminal?(status()) :: boolean()
  def terminal?(status) when status in [:completed, :cancelled], do: true
  def terminal?(status) when status in [:active, :error], do: false
end
