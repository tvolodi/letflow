defmodule Letflow.EventStore.ArchivedEvent do
  @moduledoc """
  Ecto schema for the `events_archive` table — the destination REQ-026's
  archive operation moves aged `events` rows into. See
  `lib/letflow/design/req023-event-store-schema.md` §3.6 and §5.1.

  Nothing in REQ-023 writes to this table; the schema exists so REQ-026 has a
  typed row struct to build against.

  ## Append-only, for the same reason `Letflow.EventStore.Event` is

  This schema exposes no `update_changeset/2` and no generic `changeset/2`.
  R-Co's `migrations/003_event_archive.sql:6-7` states the contract directly:
  "Archived rows are moved here, not deleted. Active instance state
  reconstruction is never affected." An archived event is the same immutable
  fact the original event was, so the immutability invariant
  (`docs/migration/decisions/0003-ecto-schema-strategy.md` Decision C point 1)
  applies here unchanged.

  ## Idempotency lives elsewhere (design INV-EV-3)

  This table carries **no** unique index on `idempotency_key`. R-Co's
  `migrations/013_event_archive_idempotency.sql`'s
  `uq_event_archive_idempotency` is deliberately not ported — superseded by
  `Letflow.EventStore.IdempotencyRecord`, exactly as R-Co itself did at
  `migrations/1147_par01_events_partitioning.sql:192-193`
  ("plat_event_idempotency supersedes its purpose"). Together with
  `Letflow.EventStore.Event` carrying no such index either, that leaves
  `uq_event_idempotency_key` on the sidecar as the single enforcement point.

  ## Differences from `Letflow.EventStore.Event`'s field list

  * `global_seq` is a plain castable integer with no `read_after_writes` — the
    value is *copied* from the source `events` row, never freshly allocated by
    a sequence.
  * `created_at` likewise carries no database default (unlike `events`'), so an
    archive insert that forgot to copy it fails loudly instead of silently
    stamping *archive* time into half the primary key.
  * `archived_at` is added.

  ## No `@schema_prefix` (design INV-EV-8)

  Like every event-store schema module, this table lives in many Postgres
  schemas — one per tenant — so every read and write must pass
  `prefix: schema_name` explicitly at call time rather than relying on a
  compile-time prefix.

  ## `tenant_id` (design §2.5)

  This table is one of three (with `events` and `instance_projections`) that
  carry `tenant_id`, matching R-Co's own settled `adp-0x` state exactly — not
  every event-store table needs it, since every table here already lives
  inside one tenant's own Postgres schema. See the design doc §2.5 for the
  full asymmetry rationale before "completing" it on another table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "events_archive" do
    field(:event_id, Ecto.UUID, primary_key: true)
    field(:created_at, :utc_datetime_usec, primary_key: true)
    field(:instance_id, Ecto.UUID)
    field(:event_type, :string)
    field(:payload, :map)
    field(:actor_id, Ecto.UUID)
    field(:sequence_number, :integer)
    field(:idempotency_key, :string)
    field(:metadata, :map, default: %{})
    field(:global_seq, :integer)
    field(:tenant_id, Ecto.UUID)
    field(:archived_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @cast_fields [
    :event_id,
    :created_at,
    :instance_id,
    :event_type,
    :payload,
    :actor_id,
    :sequence_number,
    :idempotency_key,
    :metadata,
    :global_seq,
    :tenant_id,
    :archived_at
  ]

  @required_fields [
    :event_id,
    :created_at,
    :instance_id,
    :event_type,
    :payload,
    :actor_id,
    :sequence_number,
    :idempotency_key,
    :global_seq,
    :tenant_id
  ]

  @doc """
  The only changeset this module exposes — structural validation for copying
  one committed `events` row into the archive. Does no I/O.

  Unlike `Letflow.EventStore.Event.insert_changeset/2`, `global_seq` **is**
  castable and required here: it is copied from the source row rather than
  allocated by a sequence.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(archived_event, attrs) do
    archived_event
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> validate_length(:event_type, min: 1, max: 128)
  end
end
